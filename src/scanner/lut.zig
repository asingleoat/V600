const std = @import("std");

pub const serialized_len: usize = 256 * 3;

pub const Error = error{
    InvalidLutLength,
};

pub fn serializeRgb(out: *[serialized_len]u8, red: ?[]const u8, green: ?[]const u8, blue: ?[]const u8) Error!void {
    try writeChannel(out[0..256], red);
    try writeChannel(out[256..512], green);
    try writeChannel(out[512..768], blue);
}

pub fn writeRgbFile(io: std.Io, path: []const u8, red: ?[]const u8, green: ?[]const u8, blue: ?[]const u8) !void {
    var data: [serialized_len]u8 = undefined;
    try serializeRgb(&data, red, green, blue);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &data });
}

fn writeChannel(dst: []u8, maybe_lut: ?[]const u8) Error!void {
    if (maybe_lut) |lut| {
        if (lut.len != 256) return Error.InvalidLutLength;
        @memcpy(dst, lut);
    } else {
        for (dst, 0..) |*value, i| {
            value.* = @intCast(i);
        }
    }
}

test "serializes R then G then B with identity fallback" {
    var out: [serialized_len]u8 = undefined;
    var red: [256]u8 = undefined;
    var blue: [256]u8 = undefined;
    for (0..256) |i| {
        red[i] = @intCast(255 - i);
        blue[i] = @intCast(i / 2);
    }

    try serializeRgb(&out, &red, null, &blue);
    try std.testing.expectEqual(@as(u8, 255), out[0]);
    try std.testing.expectEqual(@as(u8, 127), out[128]);
    try std.testing.expectEqual(@as(u8, 0), out[255]);
    try std.testing.expectEqual(@as(u8, 0), out[256]);
    try std.testing.expectEqual(@as(u8, 128), out[384]);
    try std.testing.expectEqual(@as(u8, 255), out[511]);
    try std.testing.expectEqual(@as(u8, 0), out[512]);
    try std.testing.expectEqual(@as(u8, 64), out[640]);
    try std.testing.expectEqual(@as(u8, 127), out[767]);
}

test "rejects malformed channel length" {
    var out: [serialized_len]u8 = undefined;
    try std.testing.expectError(Error.InvalidLutLength, serializeRgb(&out, &[_]u8{ 1, 2, 3 }, null, null));
}

test "writes RGB LUT file in Python-compatible layout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var red: [256]u8 = undefined;
    for (&red, 0..) |*value, i| value.* = @intCast(255 - i);

    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/lut.bin", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(path);

    try writeRgbFile(std.testing.io, path, &red, null, null);
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(serialized_len + 1));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(usize, serialized_len), data.len);
    try std.testing.expectEqual(@as(u8, 255), data[0]);
    try std.testing.expectEqual(@as(u8, 0), data[255]);
    try std.testing.expectEqual(@as(u8, 0), data[256]);
    try std.testing.expectEqual(@as(u8, 255), data[511]);
    try std.testing.expectEqual(@as(u8, 0), data[512]);
    try std.testing.expectEqual(@as(u8, 255), data[767]);
}
