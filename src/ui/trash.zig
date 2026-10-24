//! Moving files to the system Trash, where they can be got back: on macOS
//! through NSFileManager (Finder's Put Back restores them), elsewhere into
//! the freedesktop.org trash that Linux file managers share.

const std = @import("std");
const builtin = @import("builtin");

/// How the UI trashes a file; tests and smokes swap in `moveBeside`.
pub const Mover = *const fn (allocator: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!void;

pub fn moveToTrash(allocator: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!void {
    if (builtin.os.tag == .macos) return macos.trash(allocator, path);
    const home = try homeTrash(allocator);
    defer allocator.free(home);
    trashInto(allocator, io, path, home) catch |err| switch (err) {
        // The home trash is on another drive: use that drive's own.
        error.CrossDevice => {
            const top = try topTrash(allocator, path);
            defer allocator.free(top);
            return trashInto(allocator, io, path, top);
        },
        else => return err,
    };
}

/// For tests and smokes: a `.trash` folder beside the file instead of the
/// system Trash.
pub fn moveBeside(allocator: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!void {
    const trash_dir = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(path) orelse ".", ".trash" });
    defer allocator.free(trash_dir);
    try std.Io.Dir.cwd().createDirPath(io, trash_dir);
    const name = std.fs.path.basename(path);
    var candidate = try allocator.dupe(u8, name);
    defer allocator.free(candidate);
    var counter: usize = 1;
    while (true) : (counter += 1) {
        const destination = try std.fs.path.join(allocator, &.{ trash_dir, candidate });
        defer allocator.free(destination);
        std.Io.Dir.cwd().access(io, destination, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const cwd = std.Io.Dir.cwd();
                return cwd.rename(path, cwd, destination, io);
            },
            else => return err,
        };
        allocator.free(candidate);
        candidate = try numberedName(allocator, name, counter);
    }
}

fn numberedName(allocator: std.mem.Allocator, name: []const u8, number: usize) ![]u8 {
    const extension = std.fs.path.extension(name);
    return std.fmt.allocPrint(allocator, "{s}_{d}{s}", .{ name[0 .. name.len - extension.len], number, extension });
}

/// NSFileManager through the Objective-C runtime, with Foundation loaded at
/// run time: it is on every Mac, and nothing then links against the SDK.
const macos = struct {
    const Id = ?*anyopaque;
    const Sel = ?*anyopaque;

    fn trash(allocator: std.mem.Allocator, path: []const u8) !void {
        const foundation = std.c.dlopen("/System/Library/Frameworks/Foundation.framework/Foundation", .{ .LAZY = true }) orelse
            return error.TrashFailed;
        const getClass: *const fn ([*:0]const u8) callconv(.c) Id = @ptrCast(@alignCast(std.c.dlsym(foundation, "objc_getClass") orelse return error.TrashFailed));
        const registerName: *const fn ([*:0]const u8) callconv(.c) Sel = @ptrCast(@alignCast(std.c.dlsym(foundation, "sel_registerName") orelse return error.TrashFailed));
        const poolPush: *const fn () callconv(.c) ?*anyopaque = @ptrCast(@alignCast(std.c.dlsym(foundation, "objc_autoreleasePoolPush") orelse return error.TrashFailed));
        const poolPop: *const fn (?*anyopaque) callconv(.c) void = @ptrCast(@alignCast(std.c.dlsym(foundation, "objc_autoreleasePoolPop") orelse return error.TrashFailed));
        const send = std.c.dlsym(foundation, "objc_msgSend") orelse return error.TrashFailed;
        const withString: *const fn (Id, Sel, [*:0]const u8) callconv(.c) Id = @ptrCast(@alignCast(send));
        const withObject: *const fn (Id, Sel, Id) callconv(.c) Id = @ptrCast(@alignCast(send));
        const plain: *const fn (Id, Sel) callconv(.c) Id = @ptrCast(@alignCast(send));
        const trashItem: *const fn (Id, Sel, Id, ?*Id, ?*Id) callconv(.c) u8 = @ptrCast(@alignCast(send));

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const pool = poolPush();
        defer poolPop(pool);
        const string = withString(getClass("NSString"), registerName("stringWithUTF8String:"), path_z) orelse return error.TrashFailed;
        const url = withObject(getClass("NSURL"), registerName("fileURLWithPath:"), string) orelse return error.TrashFailed;
        const manager = plain(getClass("NSFileManager"), registerName("defaultManager")) orelse return error.TrashFailed;
        if (trashItem(manager, registerName("trashItemAtURL:resultingItemURL:error:"), url, null, null) == 0) {
            return error.TrashFailed;
        }
    }
};

fn homeTrash(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |data_home| {
        const value = std.mem.span(data_home);
        if (std.fs.path.isAbsolute(value)) return std.fs.path.join(allocator, &.{ value, "Trash" });
    }
    const home = std.c.getenv("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(allocator, &.{ std.mem.span(home), ".local/share/Trash" });
}

/// `$topdir/.Trash-$uid` on the drive the file is on, `$topdir` being where
/// that drive is mounted.
fn topTrash(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const absolute = try absolutePath(allocator, path);
    defer allocator.free(absolute);
    var top: []const u8 = std.fs.path.dirname(absolute) orelse "/";
    const device = try deviceOf(allocator, top);
    while (std.fs.path.dirname(top)) |up| {
        if (try deviceOf(allocator, up) != device) break;
        top = up;
    }
    const name = try std.fmt.allocPrint(allocator, ".Trash-{d}", .{std.c.getuid()});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ top, name });
}

fn deviceOf(allocator: std.mem.Allocator, path: []const u8) !u64 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var status: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, path_z, 0, .{}, &status)) != .SUCCESS) return error.FileNotFound;
        return @as(u64, status.dev_major) << 32 | status.dev_minor;
    }
    var stat: std.c.Stat = undefined;
    if (std.c.stat(path_z, &stat) != 0) return error.FileNotFound;
    return @intCast(stat.dev);
}

/// The file's absolute path, its folder resolved but not the file itself, so
/// a link is trashed as the link.
fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const folder = std.fs.path.dirname(path) orelse ".";
    const folder_z = try allocator.dupeZ(u8, folder);
    defer allocator.free(folder_z);
    var buffer: [std.c.PATH_MAX]u8 = undefined;
    const resolved = std.c.realpath(folder_z, &buffer) orelse return error.FileNotFound;
    return std.fs.path.join(allocator, &.{ std.mem.span(resolved), std.fs.path.basename(path) });
}

/// The freedesktop.org trash layout: the file in `files/`, and in `info/` a
/// `.trashinfo` with where it came from and when, created first so the name
/// is ours.
fn trashInto(allocator: std.mem.Allocator, io: std.Io, path: []const u8, trash_root: []const u8) !void {
    const absolute = try absolutePath(allocator, path);
    defer allocator.free(absolute);
    const files = try std.fs.path.join(allocator, &.{ trash_root, "files" });
    defer allocator.free(files);
    const info = try std.fs.path.join(allocator, &.{ trash_root, "info" });
    defer allocator.free(info);
    const private: std.Io.File.Permissions = @enumFromInt(0o700);
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, files, private);
    _ = try cwd.createDirPathStatus(io, info, private);

    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(allocator);
    try contents.appendSlice(allocator, "[Trash Info]\nPath=");
    for (absolute) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-_.~", byte) != null) {
            try contents.append(allocator, byte);
        } else {
            try contents.print(allocator, "%{X:0>2}", .{byte});
        }
    }
    try contents.appendSlice(allocator, "\nDeletionDate=");
    try appendLocalTime(allocator, &contents);
    try contents.append(allocator, '\n');

    const name = std.fs.path.basename(path);
    var number: usize = 1;
    while (true) : (number += 1) {
        const candidate = if (number == 1) try allocator.dupe(u8, name) else try numberedName(allocator, name, number);
        defer allocator.free(candidate);
        const info_name = try std.fmt.allocPrint(allocator, "{s}.trashinfo", .{candidate});
        defer allocator.free(info_name);
        const info_path = try std.fs.path.join(allocator, &.{ info, info_name });
        defer allocator.free(info_path);
        const file_path = try std.fs.path.join(allocator, &.{ files, candidate });
        defer allocator.free(file_path);

        const info_file = cwd.createFile(io, info_path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        const written = info_file.writeStreamingAll(io, contents.items);
        info_file.close(io);
        written catch |err| {
            cwd.deleteFile(io, info_path) catch {};
            return err;
        };
        if (cwd.access(io, file_path, .{})) |_| {
            cwd.deleteFile(io, info_path) catch {};
            continue;
        } else |_| {}
        cwd.rename(path, cwd, file_path, io) catch |err| {
            cwd.deleteFile(io, info_path) catch {};
            return err;
        };
        return;
    }
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(time: *const std.c.time_t, result: *Tm) ?*Tm;
extern "c" fn time(out: ?*std.c.time_t) std.c.time_t;

fn appendLocalTime(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    const now = time(null);
    var tm: Tm = undefined;
    _ = localtime_r(&now, &tm) orelse return error.NoLocalTime;
    try out.print(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.year + 1900)), @as(u32, @intCast(tm.mon + 1)), @as(u32, @intCast(tm.mday)),
        @as(u32, @intCast(tm.hour)),        @as(u32, @intCast(tm.min)),     @as(u32, @intCast(tm.sec)),
    });
}

test "trash follows the freedesktop layout, numbering names already taken" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "scans");
    try tmp.dir.writeFile(io, .{ .sub_path = "scans/a b.tif", .data = "scan" });
    try tmp.dir.createDirPath(io, "Trash/info");
    try tmp.dir.writeFile(io, .{ .sub_path = "Trash/info/a b.tif.trashinfo", .data = "" });

    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const scan = try std.fs.path.join(allocator, &.{ root, "scans/a b.tif" });
    defer allocator.free(scan);
    const trash_root = try std.fs.path.join(allocator, &.{ root, "Trash" });
    defer allocator.free(trash_root);
    try trashInto(allocator, io, scan, trash_root);

    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "scans/a b.tif", .{}));
    try tmp.dir.access(io, "Trash/files/a b_2.tif", .{});
    const info = try tmp.dir.readFileAlloc(io, "Trash/info/a b_2.tif.trashinfo", allocator, .limited(4096));
    defer allocator.free(info);
    try std.testing.expect(std.mem.startsWith(u8, info, "[Trash Info]\nPath=/"));
    try std.testing.expect(std.mem.indexOf(u8, info, "/scans/a%20b.tif\nDeletionDate=") != null);
    try std.testing.expectEqual(@as(usize, "[Trash Info]\nPath=".len), std.mem.indexOfScalar(u8, info, '/').?);
    try std.testing.expectEqual(@as(usize, "YYYY-MM-DDThh:mm:ss\n".len), info.len - (std.mem.indexOf(u8, info, "DeletionDate=").? + "DeletionDate=".len));
}

test "tests and smokes trash beside the file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "scan.tif", .data = "scan" });
    try tmp.dir.createDirPath(io, ".trash");
    try tmp.dir.writeFile(io, .{ .sub_path = ".trash/scan.tif", .data = "" });
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const scan = try std.fs.path.join(allocator, &.{ root, "scan.tif" });
    defer allocator.free(scan);
    try moveBeside(allocator, io, scan);
    try tmp.dir.access(io, ".trash/scan_1.tif", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "scan.tif", .{}));
}
