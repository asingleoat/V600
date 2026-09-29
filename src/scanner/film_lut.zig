const std = @import("std");

pub const Mode = enum {
    affine,
    linear,
};

pub const Options = struct {
    lo_pct: f64 = 0.1,
    hi_pct: f64 = 99.9,
    /// The black point is `footroom` times the low percentile and the white
    /// point `headroom` times the high one, so full-resolution grain and the
    /// 8-bit preview's rounding stay inside the stretched range. Measured on
    /// a Gold 200 strip, the film base lands at about 80-85% of full scale.
    footroom: f64 = 0.75,
    headroom: f64 = 1.05,
    bg_threshold: f64 = 0.7,
    mode: Mode = .affine,
};

pub const Selection = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

pub const ComputedLuts = struct {
    red: ?[256]u8 = null,
    green: ?[256]u8 = null,
    blue: ?[256]u8 = null,
    threshold: f64 = 0.0,
    film_pixels: usize = 0,
    black: [3]?f64 = .{ null, null, null },
    white: [3]?f64 = .{ null, null, null },
};

pub const Error = error{
    InvalidFilmLutImage,
    InvalidFilmLutSelection,
};

pub fn computeFilmLuts(
    allocator: std.mem.Allocator,
    preview: []const u8,
    width: usize,
    height: usize,
    channels: usize,
    selection: Selection,
    options: Options,
) !ComputedLuts {
    if (width == 0 or height == 0 or channels < 3 or preview.len < width * height * channels) {
        return Error.InvalidFilmLutImage;
    }
    if (selection.x < 0.0 or selection.y < 0.0 or selection.w < 0.0 or selection.h < 0.0) {
        return Error.InvalidFilmLutSelection;
    }

    const x0: usize = @intFromFloat(selection.x);
    const y0: usize = @intFromFloat(selection.y);
    const sel_w: usize = @intFromFloat(selection.w);
    const sel_h: usize = @intFromFloat(selection.h);
    if (x0 >= width or y0 >= height or sel_w == 0 or sel_h == 0) return .{};
    const x1 = @min(width, x0 + sel_w);
    const y1 = @min(height, y0 + sel_h);
    if (x1 <= x0 or y1 <= y0) return .{};

    var hist = [_]usize{0} ** 256;
    var total: usize = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const gray = grayAt(preview, width, channels, x, y);
            hist[histogramBin(gray)] += 1;
            total += 1;
        }
    }
    if (total == 0) return .{};

    const threshold = otsuThreshold(&hist, total, options.bg_threshold);
    var result = ComputedLuts{ .threshold = threshold };

    // Film pixels are below the Otsu threshold, eroded by one pixel so the
    // blurred edges of sprocket holes and of the strip do not count as film.
    const crop_w = x1 - x0;
    const crop_h = y1 - y0;
    const below = try allocator.alloc(bool, crop_w * crop_h);
    defer allocator.free(below);
    for (0..crop_h) |row| {
        for (0..crop_w) |col| {
            below[row * crop_w + col] = grayAt(preview, width, channels, x0 + col, y0 + row) < threshold;
        }
    }
    const film = try allocator.alloc(bool, crop_w * crop_h);
    defer allocator.free(film);
    for (0..crop_h) |row| {
        for (0..crop_w) |col| {
            const index = row * crop_w + col;
            film[index] = below[index] and row > 0 and col > 0 and row + 1 < crop_h and col + 1 < crop_w and
                below[index - 1] and below[index + 1] and below[index - crop_w] and below[index + crop_w];
            if (film[index]) result.film_pixels += 1;
        }
    }
    if (result.film_pixels < 100) return result;

    var channel_data: [3][]f64 = undefined;
    for (&channel_data) |*data| data.* = try allocator.alloc(f64, result.film_pixels);
    defer for (channel_data) |data| allocator.free(data);

    var cursor: usize = 0;
    for (0..crop_h) |row| {
        for (0..crop_w) |col| {
            if (!film[row * crop_w + col]) continue;
            const offset = ((y0 + row) * width + x0 + col) * channels;
            channel_data[0][cursor] = @floatFromInt(preview[offset]);
            channel_data[1][cursor] = @floatFromInt(preview[offset + 1]);
            channel_data[2][cursor] = @floatFromInt(preview[offset + 2]);
            cursor += 1;
        }
    }

    for (0..3) |channel| {
        std.mem.sort(f64, channel_data[channel], {}, lessThanF64);
        const black = percentileSorted(channel_data[channel], options.lo_pct) * options.footroom;
        const white = @min(255.0, percentileSorted(channel_data[channel], options.hi_pct) * options.headroom);
        result.black[channel] = black;
        result.white[channel] = white;
        if (white <= black + 1.0) continue;
        const lut = buildChannelLut(black, white, options.mode);
        switch (channel) {
            0 => result.red = lut,
            1 => result.green = lut,
            2 => result.blue = lut,
            else => unreachable,
        }
    }
    return result;
}

fn grayAt(preview: []const u8, width: usize, channels: usize, x: usize, y: usize) f64 {
    const offset = (y * width + x) * channels;
    return (@as(f64, @floatFromInt(preview[offset])) +
        @as(f64, @floatFromInt(preview[offset + 1])) +
        @as(f64, @floatFromInt(preview[offset + 2]))) / 3.0;
}

fn histogramBin(value: f64) usize {
    const scaled = @floor(value * 256.0 / 255.0);
    if (scaled <= 0.0) return 0;
    if (scaled >= 255.0) return 255;
    return @intFromFloat(scaled);
}

fn binCenter(index: usize) f64 {
    return (@as(f64, @floatFromInt(index)) + 0.5) * 255.0 / 256.0;
}

fn otsuThreshold(hist: *const [256]usize, total: usize, bg_threshold: f64) f64 {
    const total_f: f64 = @floatFromInt(total);
    var weighted_sum: f64 = 0.0;
    for (hist, 0..) |count, index| {
        weighted_sum += @as(f64, @floatFromInt(count)) * binCenter(index);
    }
    const global_mean = weighted_sum / total_f;

    var best_thresh = 255.0 * bg_threshold;
    var best_var: f64 = -1.0;
    var cum_sum: f64 = 0.0;
    var cum_mean: f64 = 0.0;
    for (1..256) |index| {
        const previous_count: f64 = @floatFromInt(hist[index - 1]);
        cum_sum += previous_count;
        cum_mean += previous_count * binCenter(index - 1);
        if (cum_sum == 0.0 or cum_sum == total_f) continue;
        const w0 = cum_sum / total_f;
        const w1 = 1.0 - w0;
        const m0 = cum_mean / cum_sum;
        const m1 = (global_mean * total_f - cum_mean) / (total_f - cum_sum);
        const variance = w0 * w1 * std.math.pow(f64, m0 - m1, 2.0);
        if (variance > best_var) {
            best_var = variance;
            best_thresh = binCenter(index);
        }
    }
    return best_thresh;
}

fn percentileSorted(data: []const f64, percentile: f64) f64 {
    if (data.len == 0) return 0.0;
    if (data.len == 1) return data[0];
    const position = (@as(f64, @floatFromInt(data.len - 1)) * percentile) / 100.0;
    const lower: usize = @intFromFloat(@floor(position));
    const upper: usize = @intFromFloat(@ceil(position));
    if (lower == upper) return data[lower];
    const fraction = position - @as(f64, @floatFromInt(lower));
    return data[lower] * (1.0 - fraction) + data[upper] * fraction;
}

fn buildChannelLut(black: f64, white: f64, mode: Mode) [256]u8 {
    var lut: [256]u8 = undefined;
    const scale = switch (mode) {
        .affine => 255.0 / (white - black),
        .linear => 255.0 / white,
    };
    for (&lut, 0..) |*value, index| {
        const input: f64 = @floatFromInt(index);
        const mapped = switch (mode) {
            .affine => (input - black) * scale,
            .linear => input * scale,
        };
        value.* = clampToU8(mapped);
    }
    return lut;
}

fn clampToU8(value: f64) u8 {
    const rounded = @round(value);
    if (rounded <= 0.0) return 0;
    if (rounded >= 255.0) return 255;
    return @intFromFloat(rounded);
}

fn lessThanF64(_: void, lhs: f64, rhs: f64) bool {
    return lhs < rhs;
}

fn synthesizeFilmLutImage() [24 * 24 * 3]u8 {
    var image = [_]u8{230} ** (24 * 24 * 3);
    var y: usize = 4;
    while (y < 20) : (y += 1) {
        var x: usize = 4;
        while (x < 20) : (x += 1) {
            const offset = (y * 24 + x) * 3;
            image[offset] = @intCast(30 + x * 3 + y);
            image[offset + 1] = @intCast(20 + x * 2 + y * 2);
            image[offset + 2] = @intCast(10 + x + y * 3);
        }
        x = 18;
        while (x < 20) : (x += 1) {
            const offset = (y * 24 + x) * 3;
            image[offset] = 245;
            image[offset + 1] = 245;
            image[offset + 2] = 245;
        }
    }
    return image;
}

test "affine film LUTs take both points from eroded film pixels" {
    const image = synthesizeFilmLutImage();
    const result = try computeFilmLuts(std.testing.allocator, &image, 24, 24, 3, .{
        .x = 0,
        .y = 0,
        .w = 24,
        .h = 24,
    }, .{});
    // The film block spans columns 4-17 and rows 4-19 (columns 18-19 are a
    // bright hole); one pixel of erosion leaves columns 5-16 and rows 5-18.
    try std.testing.expectEqual(@as(usize, 12 * 14), result.film_pixels);
    // Red there is 30 + 3x + y: 50 at the densest pixel, 96 at the thinnest.
    try std.testing.expectApproxEqAbs(0.75 * 50.0, result.black[0].?, 0.2);
    try std.testing.expectApproxEqAbs(1.05 * 96.0, result.white[0].?, 0.2);

    const red = result.red.?;
    const black = result.black[0].?;
    const white = result.white[0].?;
    try std.testing.expectEqual(@as(u8, 0), red[@intFromFloat(@floor(black))]);
    try std.testing.expectEqual(@as(u8, 255), red[@intFromFloat(@ceil(white))]);
    try std.testing.expectEqual(@as(u8, @intFromFloat(@round((70.0 - black) * 255.0 / (white - black)))), red[70]);
    for (red[1..], red[0..255]) |next, previous| try std.testing.expect(next >= previous);
    // The bright hole and the background never set a white point.
    for ([_]usize{ 1, 2 }) |channel| try std.testing.expect(result.white[channel].? < 100.0);
}

test "linear film LUTs keep zero and stretch to the film white point" {
    const image = synthesizeFilmLutImage();
    const result = try computeFilmLuts(std.testing.allocator, &image, 24, 24, 3, .{
        .x = 0,
        .y = 0,
        .w = 24,
        .h = 24,
    }, .{ .mode = .linear });
    const blue = result.blue.?;
    const white = result.white[2].?;
    try std.testing.expectEqual(@as(u8, 0), blue[0]);
    try std.testing.expectEqual(@as(u8, @intFromFloat(@round(40.0 * 255.0 / white))), blue[40]);
    try std.testing.expectEqual(@as(u8, 255), blue[@intFromFloat(@ceil(white))]);
}

test "compute film LUTs returns identity fallback for insufficient film pixels" {
    var image = [_]u8{230} ** (12 * 12 * 3);
    var y: usize = 4;
    while (y < 10) : (y += 1) {
        var x: usize = 4;
        while (x < 10) : (x += 1) {
            const offset = (y * 12 + x) * 3;
            image[offset] = 40;
            image[offset + 1] = 40;
            image[offset + 2] = 40;
        }
    }
    const result = try computeFilmLuts(std.testing.allocator, &image, 12, 12, 3, .{
        .x = 0,
        .y = 0,
        .w = 12,
        .h = 12,
    }, .{ .mode = .linear });
    // A 6 x 6 block erodes to 4 x 4, too few pixels to trust.
    try std.testing.expectEqual(@as(usize, 16), result.film_pixels);
    try std.testing.expect(result.red == null);
    try std.testing.expect(result.green == null);
    try std.testing.expect(result.blue == null);
}

test "compute film LUTs validates image and selection bounds" {
    const image = [_]u8{0} ** (2 * 2 * 3);
    try std.testing.expectError(Error.InvalidFilmLutImage, computeFilmLuts(std.testing.allocator, &image, 2, 2, 2, .{
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
    }, .{}));
    try std.testing.expectError(Error.InvalidFilmLutSelection, computeFilmLuts(std.testing.allocator, &image, 2, 2, 3, .{
        .x = -1,
        .y = 0,
        .w = 1,
        .h = 1,
    }, .{}));
    const empty = try computeFilmLuts(std.testing.allocator, &image, 2, 2, 3, .{
        .x = 2,
        .y = 0,
        .w = 1,
        .h = 1,
    }, .{});
    try std.testing.expect(empty.red == null);
}
