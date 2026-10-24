//! Where the app writes its exports, as the UI shows it, and opening that
//! folder in the file manager. The app works in its data folder (the
//! checkout, `~/Pictures/CerealGrain` for the app bundle, or
//! `CEREALGRAIN_DATA_DIR`), so the folders it names are relative to it.

const std = @import("std");
const builtin = @import("builtin");

/// `relative` (under the data folder) as an absolute path, the home folder
/// shown as `~`.
pub fn displayPath(buffer: []u8, relative: []const u8) []const u8 {
    var cwd_buffer: [std.c.PATH_MAX]u8 = undefined;
    const cwd = if (std.c.realpath(".", &cwd_buffer)) |resolved| std.mem.span(resolved) else ".";
    const home: []const u8 = if (std.c.getenv("HOME")) |value| std.mem.span(value) else "";
    const joined = std.fmt.bufPrint(buffer, "{s}/{s}", .{ cwd, relative }) catch return relative;
    if (home.len > 1 and std.mem.startsWith(u8, joined, home) and (joined.len == home.len or joined[home.len] == '/')) {
        const rest = joined[home.len..];
        std.mem.copyForwards(u8, buffer[1..], rest);
        buffer[0] = '~';
        return buffer[0 .. rest.len + 1];
    }
    return joined;
}

/// Opens `relative` (under the data folder) in Finder or the desktop's file
/// manager, making it first if no export has yet.
pub fn open(allocator: std.mem.Allocator, io: std.Io, relative: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, relative);
    const opener = if (builtin.os.tag == .macos) "open" else "xdg-open";
    const result = try std.process.run(allocator, io, .{ .argv = &.{ opener, relative } });
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

test "the data folder's path shows the home folder as ~" {
    var buffer: [std.c.PATH_MAX + 64]u8 = undefined;
    const shown = displayPath(&buffer, "frames");
    try std.testing.expect(std.mem.endsWith(u8, shown, "/frames"));
    const home: []const u8 = if (std.c.getenv("HOME")) |value| std.mem.span(value) else "";
    if (home.len > 1) try std.testing.expect(!std.mem.startsWith(u8, shown, home));
}
