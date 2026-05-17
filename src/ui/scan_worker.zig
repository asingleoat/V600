const std = @import("std");

const film_lut = @import("../scanner/film_lut.zig");
const scanner_events = @import("../scanner/events.zig");
const scanner_linux = @import("../scanner/linux.zig");
const scanner_lut = @import("../scanner/lut.zig");
const preview_worker = @import("preview_worker.zig");
const ui_state = @import("state.zig");

pub const ExecuteFn = *const fn (*Context) anyerror!void;

const max_queued_events = 64;

const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

const EventQueue = struct {
    lock_state: SpinLock = .{},
    events: [max_queued_events]ui_state.ScannerBackendEvent = undefined,
    len: usize = 0,

    fn clear(self: *EventQueue) void {
        self.lock_state.lock();
        defer self.lock_state.unlock();
        self.len = 0;
    }

    fn push(self: *EventQueue, event: ui_state.ScannerBackendEvent) void {
        self.lock_state.lock();
        defer self.lock_state.unlock();
        if (self.len < self.events.len) {
            self.events[self.len] = event;
            self.len += 1;
        } else {
            self.events[self.events.len - 1] = event;
        }
    }

    fn drain(self: *EventQueue, model: *ui_state.State) void {
        var local: [max_queued_events]ui_state.ScannerBackendEvent = undefined;
        self.lock_state.lock();
        const count = self.len;
        for (0..count) |index| local[index] = self.events[index];
        self.len = 0;
        self.lock_state.unlock();

        for (local[0..count]) |event| {
            model.applyScannerBackendEvent(event);
        }
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    request: ui_state.ScanStartPlan,
    output_path: []u8,
    cancel_file_path: ?[]u8,
    lut_file_path: ?[]u8 = null,
    metadata_path: ?[]u8 = null,
    error_detail: []const u8 = "",
    done: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    cancelled: *std.atomic.Value(bool),
    event_queue: *EventQueue,
    execute: ExecuteFn,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    execute: ExecuteFn = runScannerScan,
    thread: ?std.Thread = null,
    context: ?*Context = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    event_queue: EventQueue = .{},
    cancel_file_written: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *std.process.Environ.Map,
    ) Worker {
        return .{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
        };
    }

    pub fn initWithExecutor(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *std.process.Environ.Map,
        execute: ExecuteFn,
    ) Worker {
        var worker = init(allocator, io, environ_map);
        worker.execute = execute;
        return worker;
    }

    pub fn deinit(self: *Worker) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.cleanupContext();
    }

    pub fn isRunning(self: Worker) bool {
        return self.context != null and !self.done.load(.acquire);
    }

    pub fn startQueued(self: *Worker, model: *ui_state.State, preview_buffer: ?preview_worker.PreviewBuffer) !bool {
        if (self.context != null) return false;
        const command = model.takeCommand() orelse return false;
        switch (command) {
            .preview_scan => {
                model.pending_command = command;
                return false;
            },
            .scan_start => |plan| try self.startScan(plan, preview_buffer),
        }
        return true;
    }

    pub fn startScan(self: *Worker, plan: ui_state.ScanStartPlan, preview_buffer: ?preview_worker.PreviewBuffer) !void {
        if (self.context != null) return error.ScanWorkerBusy;

        self.done.store(false, .release);
        self.failed.store(false, .release);
        self.cancelled.store(false, .release);
        self.event_queue.clear();
        self.cancel_file_written = false;

        const output_path = try self.allocator.dupe(u8, plan.output_path);
        errdefer self.allocator.free(output_path);
        const cancel_file_path = if (plan.cancel_file_path) |path| try self.allocator.dupe(u8, path) else null;
        errdefer if (cancel_file_path) |path| self.allocator.free(path);
        const lut_file_path = try self.prepareLutFile(plan, output_path, preview_buffer);
        errdefer if (lut_file_path) |path| {
            deleteIfExists(self.io, path);
            self.allocator.free(path);
        };

        if (cancel_file_path) |path| deleteIfExists(self.io, path);

        const context = try self.allocator.create(Context);
        errdefer self.allocator.destroy(context);

        var owned_plan = plan;
        owned_plan.output_path = output_path;
        owned_plan.request.output_path = output_path;
        owned_plan.cancel_file_path = cancel_file_path;
        owned_plan.request.lut_file_path = lut_file_path;
        context.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .environ_map = self.environ_map,
            .request = owned_plan,
            .output_path = output_path,
            .cancel_file_path = cancel_file_path,
            .lut_file_path = lut_file_path,
            .done = &self.done,
            .failed = &self.failed,
            .cancelled = &self.cancelled,
            .event_queue = &self.event_queue,
            .execute = self.execute,
        };

        self.thread = try std.Thread.spawn(.{}, threadMain, .{context});
        self.context = context;
    }

    fn prepareLutFile(
        self: *Worker,
        plan: ui_state.ScanStartPlan,
        output_path: []const u8,
        preview_buffer: ?preview_worker.PreviewBuffer,
    ) !?[]u8 {
        if (plan.request.kind == .ir) return null;
        const preview = preview_buffer orelse return null;
        if (preview.samples_per_pixel < 3 or preview.bits_per_sample != 8) return null;
        const selection = plan.preview_selection orelse return null;
        const computed = try film_lut.computeFilmLuts(
            self.allocator,
            preview.data,
            @intCast(preview.width),
            @intCast(preview.height),
            @intCast(preview.samples_per_pixel),
            .{ .x = selection.x, .y = selection.y, .w = selection.w, .h = selection.h },
            .{ .mode = exposureMode(plan.exposure) },
        );
        if (computed.red == null and computed.green == null and computed.blue == null) return null;

        const path = try std.fmt.allocPrint(self.allocator, "{s}.lut.bin", .{output_path});
        errdefer self.allocator.free(path);
        try scanner_lut.writeRgbFile(
            self.io,
            path,
            if (computed.red) |*lut| lut else null,
            if (computed.green) |*lut| lut else null,
            if (computed.blue) |*lut| lut else null,
        );
        return path;
    }

    pub fn requestCancelIfNeeded(self: *Worker, model: *ui_state.State) !void {
        if (!model.scanner.cancel_requested or self.cancel_file_written) return;
        const context = self.context orelse return;
        const path = context.cancel_file_path orelse return;
        try writeCancelFile(self.io, path);
        self.cancel_file_written = true;
    }

    pub fn poll(self: *Worker, model: *ui_state.State) bool {
        self.requestCancelIfNeeded(model) catch {
            model.applyScannerBackendEvent(.{ .scan_error = .{
                .kind = .backend_failure,
                .detail = "failed to write scanner cancel file",
            } });
            return false;
        };

        self.event_queue.drain(model);
        const context = self.context orelse return false;
        if (!context.done.load(.acquire)) return false;

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.event_queue.drain(model);

        if (context.cancelled.load(.acquire)) {
            model.applyScannerBackendEvent(.{ .scan_cancelled = .{
                .kind = .cancelled,
                .detail = "cancel file observed",
            } });
        } else if (context.failed.load(.acquire)) {
            model.applyScannerBackendEvent(.{ .scan_error = .{
                .kind = .backend_failure,
                .detail = if (context.error_detail.len == 0) "scan failed" else context.error_detail,
            } });
        } else {
            model.applyScannerBackendEvent(.{ .scan_complete = .{
                .output = context.output_path,
                .metadata = context.metadata_path orelse context.output_path,
            } });
        }

        self.cleanupContext();
        return true;
    }

    fn cleanupContext(self: *Worker) void {
        if (self.context) |context| {
            if (context.cancel_file_path) |path| {
                deleteIfExists(self.io, path);
                self.allocator.free(path);
            }
            if (context.lut_file_path) |path| {
                deleteIfExists(self.io, path);
                self.allocator.free(path);
            }
            if (context.metadata_path) |path| self.allocator.free(path);
            self.allocator.free(context.output_path);
            self.allocator.destroy(context);
            self.context = null;
        }
        self.done.store(false, .release);
        self.failed.store(false, .release);
        self.cancelled.store(false, .release);
        self.event_queue.clear();
        self.cancel_file_written = false;
    }
};

fn threadMain(context: *Context) void {
    context.execute(context) catch |err| {
        if (err == error.ScanCancelled) {
            context.cancelled.store(true, .release);
        } else {
            context.error_detail = @errorName(err);
            context.failed.store(true, .release);
        }
    };
    context.done.store(true, .release);
}

fn runScannerScan(context: *Context) !void {
    const runtime = scanner_linux.Runtime{
        .allocator = context.allocator,
        .io = context.io,
        .environ_map = context.environ_map,
        .event_sink = .{
            .context = context,
            .emit = enqueueRuntimeEvent,
        },
    };
    var request = context.request.request;
    request.output_path = context.output_path;
    try runtime.scan(.{
        .request = request,
        .output_path = context.output_path,
        .cancel_file = context.cancel_file_path,
    });
    context.metadata_path = try std.fmt.allocPrint(context.allocator, "{s}.json", .{context.output_path});
}

fn enqueueRuntimeEvent(raw_context: *anyopaque, event: scanner_events.Event) void {
    const context: *Context = @ptrCast(@alignCast(raw_context));
    switch (event) {
        .scan_start => |scan_start| context.event_queue.push(.{ .scan_start = .{
            .device = "",
            .output = "",
            .source = scan_start.source,
            .kind = scan_start.kind,
            .requested_dpi = scan_start.requested_dpi,
            .effective_dpi = scan_start.effective_dpi,
        } }),
        .progress => |progress| context.event_queue.push(.{ .progress = progress }),
        else => {},
    }
}

fn exposureMode(mode: ui_state.ExposureMode) film_lut.Mode {
    return switch (mode) {
        .affine => .affine,
        .linear => .linear,
    };
}

fn writeCancelFile(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len != 0) std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    file.close(io);
}

fn deleteIfExists(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn fakeScanSuccess(context: *Context) !void {
    if (context.request.request.source != .tpu) return error.BadSource;
    if (context.request.request.output_path == null) return error.MissingOutputPath;
    if (!std.mem.eql(u8, context.request.request.output_path.?, context.output_path)) return error.BadOutputPath;
    if (context.lut_file_path) |path| {
        if (context.request.request.lut_file_path == null) return error.MissingRequestLutPath;
        if (!std.mem.eql(u8, context.request.request.lut_file_path.?, path)) return error.BadRequestLutPath;
    }
    context.metadata_path = try std.fmt.allocPrint(context.allocator, "{s}.json", .{context.output_path});
}

fn fakeScanFailure(_: *Context) !void {
    return error.FakeScanFailure;
}

fn fakeScanWaitForCancel(context: *Context) !void {
    const path = context.cancel_file_path orelse return error.MissingCancelFile;
    for (0..10_000) |_| {
        if (fileExists(context.io, path)) return error.ScanCancelled;
        try std.Thread.yield();
    }
    return error.CancelFileNotObserved;
}

fn fakeScanEmitLiveEventsWaitForCancel(context: *Context) !void {
    context.event_queue.push(.{ .scan_start = .{
        .device = "",
        .output = "",
        .source = .tpu,
        .kind = .rgb,
        .requested_dpi = context.request.request.dpi,
        .effective_dpi = context.request.request.dpi,
    } });
    context.event_queue.push(.{ .progress = .{ .percent = 37 } });
    context.event_queue.push(.{ .scan_start = .{
        .device = "",
        .output = "",
        .source = .tpu,
        .kind = .ir,
        .requested_dpi = @min(context.request.request.dpi, 3200),
        .effective_dpi = @min(context.request.request.dpi, 3200),
    } });
    context.event_queue.push(.{ .progress = .{ .percent = 82 } });

    const path = context.cancel_file_path orelse return error.MissingCancelFile;
    for (0..10_000) |_| {
        if (fileExists(context.io, path)) return error.ScanCancelled;
        try std.Thread.yield();
    }
    return error.CancelFileNotObserved;
}

fn previewBufferWithPythonLutOracleImage(allocator: std.mem.Allocator) !preview_worker.PreviewBuffer {
    const data = try allocator.alloc(u8, 24 * 24 * 3);
    errdefer allocator.free(data);
    @memset(data, 230);
    var y: usize = 4;
    while (y < 20) : (y += 1) {
        var x: usize = 4;
        while (x < 20) : (x += 1) {
            const offset = (y * 24 + x) * 3;
            data[offset] = @intCast(30 + x * 3 + y);
            data[offset + 1] = @intCast(20 + x * 2 + y * 2);
            data[offset + 2] = @intCast(10 + x + y * 3);
        }
        x = 18;
        while (x < 20) : (x += 1) {
            const offset = (y * 24 + x) * 3;
            data[offset] = 245;
            data[offset + 1] = 245;
            data[offset + 2] = 245;
        }
    }
    const output_path = try allocator.dupe(u8, "python-lut-oracle-preview");
    errdefer allocator.free(output_path);
    return .{
        .output_path = output_path,
        .width = 24,
        .height = 24,
        .samples_per_pixel = 3,
        .bits_per_sample = 8,
        .data = data,
    };
}

test "scan worker consumes queued scan command without blocking UI state" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(1000, 500, 10.0, 5.0);
    model.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(model.queueScanStart(".zig-cache/v600-scan.cancel"));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, null));
    try std.testing.expect(model.pending_command == null);

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(!worker.isRunning());
    try std.testing.expect(!model.scanner.scanning);
    try std.testing.expectEqual(@as(usize, 2), model.scanner.scan_counter);
    try std.testing.expectEqualStrings("Saved: scan_0001_rgbir_3200dpi.tiff", model.status);
}

test "scan worker writes temporary LUT file from preview pixels" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scan_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(scan_dir);

    var preview = try previewBufferWithPythonLutOracleImage(std.testing.allocator);
    defer preview.deinit(std.testing.allocator);

    var model = ui_state.State.init(scan_dir, "frames", 0);
    model.scannerConnected(24, 24, 1.0, 1.0);
    model.scan_controls.exposure = .linear;
    model.scan_controls.setSelection(.{ .x = 0.0, .y = 0.0, .w = 24.0, .h = 24.0 });
    try std.testing.expect(model.queueScanStart(null));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, preview));
    const lut_path = try std.testing.allocator.dupe(u8, worker.context.?.lut_file_path.?);
    defer std.testing.allocator.free(lut_path);
    try std.testing.expectEqualStrings(worker.context.?.request.request.lut_file_path.?, lut_path);

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, lut_path, std.testing.allocator, .limited(scanner_lut.serialized_len + 1));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(usize, scanner_lut.serialized_len), data.len);
    try std.testing.expectEqual(@as(u8, 123), data[48]);
    try std.testing.expectEqual(@as(u8, 136), data[256 + 48]);
    try std.testing.expectEqual(@as(u8, 147), data[512 + 48]);

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, lut_path, .{}));
}

test "scan worker keeps IR-only scans on identity LUT policy" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scan_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(scan_dir);

    var preview = try previewBufferWithPythonLutOracleImage(std.testing.allocator);
    defer preview.deinit(std.testing.allocator);

    var model = ui_state.State.init(scan_dir, "frames", 0);
    model.scannerConnected(24, 24, 1.0, 1.0);
    model.scan_controls.setMode(.ir);
    model.scan_controls.setSelection(.{ .x = 0.0, .y = 0.0, .w = 24.0, .h = 24.0 });
    try std.testing.expect(model.queueScanStart(null));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, preview));
    try std.testing.expect(worker.context.?.lut_file_path == null);
    try std.testing.expect(worker.context.?.request.request.lut_file_path == null);
}

test "scan worker leaves preview command for preview worker" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(0, 0, 2.7, 9.54);
    try std.testing.expect(model.queuePreviewScan("/tmp/v600-native-preview.tiff"));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanSuccess);
    defer worker.deinit();
    try std.testing.expect(!(try worker.startQueued(&model, null)));
    try std.testing.expect(model.pending_command != null);
    switch (model.pending_command.?) {
        .preview_scan => |plan| try std.testing.expectEqualStrings("/tmp/v600-native-preview.tiff", plan.output_path),
        .scan_start => unreachable,
    }
}

test "scan worker writes cancel file and reports cancellation" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cancel_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/native-scan.cancel", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(cancel_path);

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(1000, 500, 10.0, 5.0);
    model.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(model.queueScanStart(cancel_path));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanWaitForCancel);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, null));

    model.requestScannerCancel();
    try worker.requestCancelIfNeeded(&model);
    try std.Io.Dir.cwd().access(std.testing.io, cancel_path, .{});

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(!model.scanner.scanning);
    try std.testing.expectEqualStrings("cancel file observed", model.status);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, cancel_path, .{}));
}

test "scan worker drains live backend scan events while running" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cancel_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/native-live-events.cancel", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(cancel_path);

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(1000, 500, 10.0, 5.0);
    model.scan_controls.setDpi(6400);
    model.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(model.queueScanStart(cancel_path));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanEmitLiveEventsWaitForCancel);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, null));

    var observed_live = false;
    for (0..1000) |_| {
        _ = worker.poll(&model);
        if (model.scanner_progress_percent == 82 and
            std.mem.eql(u8, model.scanner.scan_status, "Pass 2/2: Scanning IR at 3200 DPI..."))
        {
            observed_live = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(observed_live);
    try std.testing.expect(model.scanner.scanning);

    model.requestScannerCancel();
    try worker.requestCancelIfNeeded(&model);

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(!model.scanner.scanning);
    try std.testing.expectEqualStrings("cancel file observed", model.status);
}

test "scan worker surfaces execution failure to UI state" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(1000, 500, 10.0, 5.0);
    model.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(model.queueScanStart(null));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanFailure);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, null));

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(!model.scanner.scanning);
    try std.testing.expectEqualStrings("Error: FakeScanFailure", model.status);
}
