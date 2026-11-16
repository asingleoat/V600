//! The print system, through libcups loaded at run time (macOS ships it in
//! the system; Linux has it with CUPS installed), so builds need no CUPS to
//! link against: the queues, their PPDs, and submitting and following jobs.

const std = @import("std");
const builtin = @import("builtin");

const Option = extern struct {
    name: [*:0]const u8,
    value: [*:0]const u8,
};

const Dest = extern struct {
    name: [*:0]const u8,
    instance: ?[*:0]const u8,
    is_default: c_int,
    num_options: c_int,
    options: ?[*]Option,
};

const Job = extern struct {
    id: c_int,
    dest: ?[*:0]const u8,
    title: ?[*:0]const u8,
    user: ?[*:0]const u8,
    format: ?[*:0]const u8,
    state: c_int,
    size: c_int,
    priority: c_int,
    completed_time: i64,
    creation_time: i64,
    processing_time: i64,
};

const http_continue: c_int = 100;
const which_jobs_all: c_int = -1;

const Functions = struct {
    cupsGetDests2: *const fn (?*anyopaque, *?[*]Dest) callconv(.c) c_int,
    cupsFreeDests: *const fn (c_int, ?[*]Dest) callconv(.c) void,
    cupsGetPPD: *const fn ([*:0]const u8) callconv(.c) ?[*:0]const u8,
    cupsCreateJob: *const fn (?*anyopaque, [*:0]const u8, [*:0]const u8, c_int, ?[*]const Option) callconv(.c) c_int,
    cupsStartDocument: *const fn (?*anyopaque, [*:0]const u8, c_int, [*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int,
    cupsWriteRequestData: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int,
    cupsFinishDocument: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) c_int,
    cupsCancelJob2: *const fn (?*anyopaque, [*:0]const u8, c_int, c_int) callconv(.c) c_int,
    cupsGetJobs2: *const fn (?*anyopaque, *?[*]Job, [*:0]const u8, c_int, c_int) callconv(.c) c_int,
    cupsFreeJobs: *const fn (c_int, ?[*]Job) callconv(.c) void,
    cupsLastErrorString: *const fn () callconv(.c) ?[*:0]const u8,
};

const library_paths = switch (builtin.os.tag) {
    .macos => [_][:0]const u8{"/usr/lib/libcups.2.dylib"},
    else => [_][:0]const u8{ "libcups.so.2", "libcups.so" },
};

var loaded: ?Functions = null;
var load_failed = false;
var load_mutex: std.atomic.Mutex = .unlocked;

/// The library, loaded once; error.CupsUnavailable without one.
fn functions() !*const Functions {
    while (!load_mutex.tryLock()) std.atomic.spinLoopHint();
    defer load_mutex.unlock();
    if (loaded) |*f| return f;
    if (load_failed) return error.CupsUnavailable;
    for (library_paths) |path| {
        var lib = std.DynLib.open(path) catch continue;
        var f: Functions = undefined;
        var complete = true;
        inline for (@typeInfo(Functions).@"struct".fields) |field| {
            if (lib.lookup(field.type, field.name)) |symbol| {
                @field(f, field.name) = symbol;
            } else complete = false;
        }
        if (!complete) {
            lib.close();
            continue;
        }
        // Kept open for the life of the program.
        loaded = f;
        return &loaded.?;
    }
    load_failed = true;
    return error.CupsUnavailable;
}

pub fn available() bool {
    _ = functions() catch return false;
    return true;
}

pub fn lastError() []const u8 {
    const f = functions() catch return "CUPS is not available";
    return std.mem.span(f.cupsLastErrorString() orelse return "unknown CUPS error");
}

pub const Destination = struct {
    name: []const u8,
    /// The queue's description (printer-info), or its name.
    info: []const u8,
    make_and_model: []const u8,
    is_default: bool,
};

/// The print queues, default first; strings are owned by `allocator`'s
/// arena (free with `freeDestinations`).
pub fn destinations(allocator: std.mem.Allocator) ![]Destination {
    const f = try functions();
    var list: ?[*]Dest = null;
    const count = f.cupsGetDests2(null, &list);
    defer f.cupsFreeDests(count, list);
    const n: usize = @intCast(@max(count, 0));
    const out = try allocator.alloc(Destination, n);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |d| freeDestination(allocator, d);
        allocator.free(out);
    }
    for (0..n) |i| {
        const dest = list.?[i];
        var info: []const u8 = std.mem.span(dest.name);
        var model: []const u8 = "";
        if (dest.options) |options| {
            for (options[0..@intCast(dest.num_options)]) |option| {
                const name = std.mem.span(option.name);
                if (std.mem.eql(u8, name, "printer-info")) info = std.mem.span(option.value);
                if (std.mem.eql(u8, name, "printer-make-and-model")) model = std.mem.span(option.value);
            }
        }
        out[filled] = .{
            .name = try allocator.dupe(u8, std.mem.span(dest.name)),
            .info = try allocator.dupe(u8, info),
            .make_and_model = try allocator.dupe(u8, model),
            .is_default = dest.is_default != 0,
        };
        filled += 1;
    }
    std.mem.sort(Destination, out, {}, struct {
        fn less(_: void, a: Destination, b: Destination) bool {
            if (a.is_default != b.is_default) return a.is_default;
            return std.mem.lessThan(u8, a.info, b.info);
        }
    }.less);
    return out;
}

fn freeDestination(allocator: std.mem.Allocator, d: Destination) void {
    allocator.free(d.name);
    allocator.free(d.info);
    allocator.free(d.make_and_model);
}

pub fn freeDestinations(allocator: std.mem.Allocator, list: []Destination) void {
    for (list) |d| freeDestination(allocator, d);
    allocator.free(list);
}

/// A copy of the queue's PPD, in a temporary file the caller deletes.
pub fn ppdPath(allocator: std.mem.Allocator, queue: []const u8) ![]u8 {
    const f = try functions();
    const name = try allocator.dupeZ(u8, queue);
    defer allocator.free(name);
    const path = f.cupsGetPPD(name) orelse return error.CupsNoPpd;
    return allocator.dupe(u8, std.mem.span(path));
}

pub const JobOption = struct {
    name: []const u8,
    value: []const u8,
};

/// A job sent in pieces: `create`, `write` the document as it is made,
/// then `finish`. All from one thread (libcups keeps the connection per
/// thread).
pub const Submission = struct {
    queue: [:0]u8,
    id: c_int,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, queue: []const u8, title: []const u8, options: []const JobOption, format: [:0]const u8) !Submission {
        const f = try functions();
        const queue_z = try allocator.dupeZ(u8, queue);
        errdefer allocator.free(queue_z);
        const title_z = try allocator.dupeZ(u8, title);
        defer allocator.free(title_z);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const list = try arena.allocator().alloc(Option, options.len);
        for (options, list) |option, *out| out.* = .{
            .name = try arena.allocator().dupeZ(u8, option.name),
            .value = try arena.allocator().dupeZ(u8, option.value),
        };
        const id = f.cupsCreateJob(null, queue_z, title_z, @intCast(list.len), list.ptr);
        if (id <= 0) return error.CupsCreateJobFailed;
        errdefer _ = f.cupsCancelJob2(null, queue_z, id, 0);
        if (f.cupsStartDocument(null, queue_z, id, title_z, format, 1) != http_continue) return error.CupsStartDocumentFailed;
        return .{ .queue = queue_z, .id = id, .allocator = allocator };
    }

    pub fn write(_: *Submission, bytes: []const u8) !void {
        const f = try functions();
        if (f.cupsWriteRequestData(null, bytes.ptr, bytes.len) != http_continue) return error.CupsWriteFailed;
    }

    /// Ends the document; the job then queues. Frees the submission.
    pub fn finish(self: *Submission) !i32 {
        defer self.allocator.free(self.queue);
        const f = try functions();
        const status = f.cupsFinishDocument(null, self.queue);
        // IPP successful-ok statuses are below 0x0100.
        if (status >= 0x0100) return error.CupsFinishFailed;
        return self.id;
    }

    /// Abandons the job. Frees the submission.
    pub fn cancel(self: *Submission) void {
        defer self.allocator.free(self.queue);
        const f = functions() catch return;
        _ = f.cupsCancelJob2(null, self.queue, self.id, 0);
    }
};

pub const JobState = enum { pending, held, processing, stopped, canceled, aborted, completed, unknown };

/// A job's state, or null once the queue no longer lists it.
pub fn jobState(allocator: std.mem.Allocator, queue: []const u8, id: i32) !?JobState {
    const f = try functions();
    const queue_z = try allocator.dupeZ(u8, queue);
    defer allocator.free(queue_z);
    var jobs: ?[*]Job = null;
    const count = f.cupsGetJobs2(null, &jobs, queue_z, 0, which_jobs_all);
    defer f.cupsFreeJobs(count, jobs);
    if (count <= 0) return null;
    for (jobs.?[0..@intCast(count)]) |job| {
        if (job.id != id) continue;
        return switch (job.state) {
            3 => .pending,
            4 => .held,
            5 => .processing,
            6 => .stopped,
            7 => .canceled,
            8 => .aborted,
            9 => .completed,
            else => .unknown,
        };
    }
    return null;
}

pub fn cancelJob(allocator: std.mem.Allocator, queue: []const u8, id: i32) !void {
    const f = try functions();
    const queue_z = try allocator.dupeZ(u8, queue);
    defer allocator.free(queue_z);
    if (f.cupsCancelJob2(null, queue_z, id, 0) == 0) return error.CupsCancelFailed;
}
