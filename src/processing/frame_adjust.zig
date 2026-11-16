//! A frame's own look: overrides, for one frame, of the render settings in
//! processing.toml (contrast, exposure, colour balance, colour contrast).
//! An image's frames keep theirs beside it in `<image>.adjust.json`, by the
//! frames' order; frames without any take the config's settings.

const std = @import("std");

const config = @import("config.zig");

/// The settings a frame may override, named as in processing.toml.
pub const Key = enum {
    render_contrast,
    dye_crosstalk,
    render_percentile_lo,
    render_percentile_hi,
    exposure_compensation,
    render_highlight_target,
    auto_white_balance,
    neutral_white_balance,
    film_gamma,
    film_toe,
    color_temp,
    color_tint,
    color_contrast,
    color_contrast_families,
    color_contrast_target,
    color_contrast_gain,
    color_contrast_boost,
    color_contrast_radius,
    color_cohesion_hue,
    color_cohesion_chroma,
    /// How strongly the frame's own look applies, 0 (the default look) to
    /// 1 (its own): a frame setting only, not one of processing.toml's.
    look_mix,
};

pub const key_count = @typeInfo(Key).@"enum".fields.len;
pub const suffix = ".adjust.json";

pub const Adjustments = struct {
    values: [key_count]?f64 = @splat(null),

    pub fn get(self: *const Adjustments, key: Key) ?f64 {
        return self.values[@intFromEnum(key)];
    }

    pub fn set(self: *Adjustments, key: Key, value: ?f64) void {
        self.values[@intFromEnum(key)] = value;
    }

    /// The look's strength, 1 unless set.
    pub fn mix(self: *const Adjustments) f64 {
        return std.math.clamp(self.get(.look_mix) orelse 1.0, 0.0, 1.0);
    }

    pub fn isEmpty(self: *const Adjustments) bool {
        for (self.values) |value| if (value != null) return false;
        return true;
    }

    /// `base` (the config's overrides) with this frame's in front, which
    /// win, in `out`.
    pub fn overrides(self: *const Adjustments, base: []const config.Override, out: []config.Override) []const config.Override {
        var count: usize = 0;
        for (self.values, 0..) |maybe, index| {
            const value = maybe orelse continue;
            const key: Key = @enumFromInt(index);
            if (key == .look_mix) continue;
            out[count] = .{ .name = @tagName(key), .value = configValue(key, value) };
            count += 1;
        }
        const kept = @min(base.len, out.len - count);
        @memcpy(out[count..][0..kept], base[0..kept]);
        return out[0 .. count + kept];
    }
};

/// Room for a frame's overrides in front of a config's.
pub const max_overrides = key_count + config.max_entries;

fn configValue(key: Key, value: f64) config.Value {
    return switch (key) {
        .color_contrast => .{ .boolean = value != 0.0 },
        .color_contrast_families => .{ .integer = @intFromFloat(@round(value)) },
        else => .{ .float = value },
    };
}

pub fn keyNamed(name: []const u8) ?Key {
    return std.meta.stringToEnum(Key, name);
}

/// The adjustments of an image's frames, by index; empty when it has none.
pub fn load(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) ![]Adjustments {
    const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ image_path, suffix });
    defer allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(Adjustments, 0),
        else => return err,
    };
    defer allocator.free(text);
    return parse(allocator, text);
}

/// Unknown names and values of the wrong kind are skipped.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ![]Adjustments {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.InvalidFrameAdjustments;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidFrameAdjustments,
    };
    const list = switch (root.get("frames") orelse return error.InvalidFrameAdjustments) {
        .array => |array| array,
        else => return error.InvalidFrameAdjustments,
    };
    const result = try allocator.alloc(Adjustments, list.items.len);
    errdefer allocator.free(result);
    for (list.items, result) |item, *adjustments| {
        adjustments.* = .{};
        const object = switch (item) {
            .object => |object| object,
            else => continue,
        };
        var it = object.iterator();
        while (it.next()) |entry| {
            const key = keyNamed(entry.key_ptr.*) orelse continue;
            const value: f64 = switch (entry.value_ptr.*) {
                .float => |float| float,
                .integer => |integer| @floatFromInt(integer),
                .bool => |boolean| if (boolean) 1.0 else 0.0,
                else => continue,
            };
            if (std.math.isFinite(value)) adjustments.set(key, value);
        }
    }
    return result;
}

/// Writes the frames' adjustments, or removes the file when none has any.
pub fn save(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8, frames: []const Adjustments) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ image_path, suffix });
    defer allocator.free(path);
    var last: usize = 0;
    for (frames, 0..) |*adjustments, index| {
        if (!adjustments.isEmpty()) last = index + 1;
    }
    if (last == 0) {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }
    const text = try format(allocator, frames[0..last]);
    defer allocator.free(text);
    const partial = try std.fmt.allocPrint(allocator, "{s}.partial", .{path});
    defer allocator.free(partial);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = partial, .data = text, .flags = .{ .truncate = true } });
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(partial, cwd, path, io);
}

pub fn format(allocator: std.mem.Allocator, frames: []const Adjustments) ![]u8 {
    var out: std.array_list.Managed(u8) = .init(allocator);
    errdefer out.deinit();
    try out.appendSlice("{\n  \"frames\": [");
    for (frames, 0..) |*adjustments, index| {
        try out.appendSlice(if (index == 0) "\n    {" else ",\n    {");
        var first = true;
        for (adjustments.values, 0..) |maybe, key_index| {
            const value = maybe orelse continue;
            const key: Key = @enumFromInt(key_index);
            try out.appendSlice(if (first) "" else ", ");
            first = false;
            switch (configValue(key, value)) {
                .boolean => |boolean| try out.print("\"{s}\": {}", .{ @tagName(key), boolean }),
                .integer => |integer| try out.print("\"{s}\": {d}", .{ @tagName(key), integer }),
                else => try out.print("\"{s}\": {d}", .{ @tagName(key), value }),
            }
        }
        try out.append('}');
    }
    try out.appendSlice("\n  ]\n}\n");
    return out.toOwnedSlice();
}

test "a frame's adjustments win over the config's and round-trip through their file" {
    const allocator = std.testing.allocator;
    var frames = [_]Adjustments{ .{}, .{}, .{} };
    frames[1].set(.exposure_compensation, 0.5);
    frames[1].set(.color_contrast, 1.0);
    frames[1].set(.color_contrast_families, 3.0);
    const text = try format(allocator, &frames);
    defer allocator.free(text);
    const loaded = try parse(allocator, text);
    defer allocator.free(loaded);
    try std.testing.expectEqual(@as(usize, 3), loaded.len);
    try std.testing.expect(loaded[0].isEmpty());
    try std.testing.expectEqual(@as(?f64, 0.5), loaded[1].get(.exposure_compensation));
    try std.testing.expectEqual(@as(?f64, 1.0), loaded[1].get(.color_contrast));

    const base = [_]config.Override{
        .{ .name = "exposure_compensation", .value = .{ .float = -1.0 } },
        .{ .name = "render_contrast", .value = .{ .float = 1.4 } },
    };
    var out: [max_overrides]config.Override = undefined;
    const merged = loaded[1].overrides(&base, &out);
    try config.getParam("exposure_compensation", null, merged).?.expectEqual(.{ .float = 0.5 });
    try config.getParam("render_contrast", null, merged).?.expectEqual(.{ .float = 1.4 });
    try config.getParam("color_contrast_families", null, merged).?.expectEqual(.{ .integer = 3 });
    // The look's strength is the frame's alone: it never reaches the config.
    var strong = loaded[1];
    strong.set(.look_mix, 0.4);
    try std.testing.expectEqual(merged.len, strong.overrides(&base, &out).len);
    try std.testing.expectEqual(@as(f64, 0.4), strong.mix());
    try std.testing.expectEqual(@as(f64, 1.0), loaded[0].mix());
    try std.testing.expectError(error.InvalidFrameAdjustments, parse(allocator, "[]"));
}
