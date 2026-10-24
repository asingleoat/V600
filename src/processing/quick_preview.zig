//! The quick preview a scan opens with: the scan scaled down by area
//! averaging, then, for display, inverted, stretched between the film's 1st
//! and 99th percentiles, and contrast-equalized (CLAHE) per channel. The
//! scaling reproduces OpenCV's INTER_AREA, which made the preview before, so
//! frame detection sees the same pixels.

const std = @import("std");
const clahe = @import("clahe.zig");
const monotonicNowNs = @import("../clock.zig").monotonicNowNs;

pub const Timings = struct {
    total_ns: u64 = 0,
    resize_ns: u64 = 0,
    convert_ns: u64 = 0,
    content_mask_ns: u64 = 0,
    invert_stretch_ns: u64 = 0,
    clahe_ns: u64 = 0,
};

pub const Source = struct {
    data: []const u8,
    width: usize,
    height: usize,
    /// 1 (grey) or 3 (RGB).
    channels: usize,
    /// 8 or 16.
    bits_per_sample: u16,
};

/// Scales `source` to `width` x `height` (no larger than it) into `raw`, as
/// 16-bit RGB, and makes the display preview from that in `rgb8`; both hold
/// `width * height * 3` samples.
pub fn build(
    allocator: std.mem.Allocator,
    source: Source,
    width: usize,
    height: usize,
    raw: []u16,
    rgb8: []u8,
    timings: ?*Timings,
) !void {
    if (source.channels != 1 and source.channels != 3) return error.UnsupportedPreviewSource;
    if (source.bits_per_sample != 8 and source.bits_per_sample != 16) return error.UnsupportedPreviewSource;
    if (width == 0 or height == 0 or width > source.width or height > source.height) return error.InvalidPreviewSize;
    const pixel_count = width * height;
    if (raw.len != pixel_count * 3 or rgb8.len != pixel_count * 3) return error.InvalidPreviewSize;
    const bytes_per_sample: usize = source.bits_per_sample / 8;
    if (source.data.len != source.width * source.height * source.channels * bytes_per_sample) return error.InvalidPreviewSource;

    var stage = monotonicNowNs();
    const small = try allocator.alloc(u16, pixel_count * source.channels);
    defer allocator.free(small);
    if (source.bits_per_sample == 16) {
        const samples = std.mem.bytesAsSlice(u16, @as([]align(2) const u8, @alignCast(source.data)));
        try resizeArea(u16, allocator, samples, source.width, source.height, source.channels, small, width, height);
    } else {
        const small8 = try allocator.alloc(u8, pixel_count * source.channels);
        defer allocator.free(small8);
        try resizeArea(u8, allocator, source.data, source.width, source.height, source.channels, small8, width, height);
        // 8-bit scans keep 8-bit display values; the raw preview spreads
        // them over 16 bits.
        for (small8, small) |value, *out| out.* = @as(u16, value) * 257;
    }
    if (timings) |t| t.resize_ns += monotonicNowNs() - stage;

    stage = monotonicNowNs();
    for (0..pixel_count) |pixel| {
        for (0..3) |channel| {
            const value = small[pixel * source.channels + if (source.channels == 1) 0 else channel];
            raw[pixel * 3 + channel] = value;
            rgb8[pixel * 3 + channel] = @intCast(value >> 8);
        }
    }
    if (timings) |t| t.convert_ns += monotonicNowNs() - stage;

    stage = monotonicNowNs();
    const content = try allocator.alloc(bool, pixel_count);
    defer allocator.free(content);
    var content_count: usize = 0;
    for (content, 0..) |*is_content, pixel| {
        const r: u32 = rgb8[pixel * 3];
        const g: u32 = rgb8[pixel * 3 + 1];
        const b: u32 = rgb8[pixel * 3 + 2];
        // OpenCV's fixed-point Rec.601 luma, so the mask matches its gray.
        const gray = (r * 4899 + g * 9617 + b * 1868 + (1 << 13)) >> 14;
        is_content.* = gray < 240;
        if (is_content.*) content_count += 1;
    }
    if (timings) |t| t.content_mask_ns += monotonicNowNs() - stage;

    stage = monotonicNowNs();
    for (rgb8) |*value| value.* = 255 - value.*;
    stretchContentPercentiles(rgb8, content, content_count);
    if (timings) |t| t.invert_stretch_ns += monotonicNowNs() - stage;

    stage = monotonicNowNs();
    try clahe.claheOpenCvInPlace(allocator, rgb8, width, height, 3, 2.0, 8, 8);
    if (timings) |t| t.clahe_ns += monotonicNowNs() - stage;
}

/// Stretches each channel of the inverted preview so that its film content
/// runs from the 1st to the 99th percentile, as the OpenCV preview did.
fn stretchContentPercentiles(rgb8: []u8, content: []const bool, content_count: usize) void {
    if (content_count <= 100) return;
    var hist = [_][256]u32{[_]u32{0} ** 256} ** 3;
    for (content, 0..) |is_content, pixel| {
        if (!is_content) continue;
        for (0..3) |channel| hist[channel][rgb8[pixel * 3 + channel]] += 1;
    }
    var lo = [_]f32{0.0} ** 3;
    var scale = [_]f32{0.0} ** 3;
    var active = [_]bool{false} ** 3;
    for (0..3) |channel| {
        const low = percentileFromHistogram(&hist[channel], content_count, 1.0);
        const high = percentileFromHistogram(&hist[channel], content_count, 99.0);
        if (high <= low) continue;
        lo[channel] = @floatCast(low);
        scale[channel] = 255.0 / @as(f32, @floatCast(high - low));
        active[channel] = true;
    }
    for (0..rgb8.len / 3) |pixel| {
        for (0..3) |channel| {
            if (!active[channel]) continue;
            const sample = &rgb8[pixel * 3 + channel];
            const value = (@as(f32, @floatFromInt(sample.*)) - lo[channel]) * scale[channel];
            sample.* = @intFromFloat(std.math.clamp(value, 0.0, 255.0));
        }
    }
}

fn percentileFromHistogram(hist: *const [256]u32, count: usize, percent: f64) f64 {
    const rank = @as(f64, @floatFromInt(count - 1)) * percent / 100.0;
    const lower: usize = @intFromFloat(@floor(rank));
    const upper: usize = @intFromFloat(@ceil(rank));
    const lower_value: f64 = @floatFromInt(histogramSelect(hist, lower));
    if (lower == upper) return lower_value;
    const upper_value: f64 = @floatFromInt(histogramSelect(hist, upper));
    const weight = rank - @as(f64, @floatFromInt(lower));
    return lower_value * (1.0 - weight) + upper_value * weight;
}

fn histogramSelect(hist: *const [256]u32, target: usize) usize {
    var seen: usize = 0;
    for (hist, 0..) |count, value| {
        seen += count;
        if (target < seen) return value;
    }
    return 255;
}

/// OpenCV's `resize` with INTER_AREA when shrinking: whole-number scales on
/// both axes average blocks; any other scale weighs each source pixel by
/// the part of it under the output pixel, in f32 as OpenCV does.
pub fn resizeArea(
    comptime T: type,
    allocator: std.mem.Allocator,
    src: []const T,
    src_width: usize,
    src_height: usize,
    channels: usize,
    dst: []T,
    dst_width: usize,
    dst_height: usize,
) !void {
    const scale_x = 1.0 / (@as(f64, @floatFromInt(dst_width)) / @as(f64, @floatFromInt(src_width)));
    const scale_y = 1.0 / (@as(f64, @floatFromInt(dst_height)) / @as(f64, @floatFromInt(src_height)));
    const whole_x = roundHalfEven(f64, scale_x);
    const whole_y = roundHalfEven(f64, scale_y);
    if (@abs(scale_x - whole_x) < std.math.floatEps(f64) and @abs(scale_y - whole_y) < std.math.floatEps(f64)) {
        resizeAreaWhole(T, src, src_width, channels, dst, dst_width, dst_height, @intFromFloat(whole_x), @intFromFloat(whole_y));
        return;
    }

    var x_table = try areaTable(allocator, src_width, dst_width, scale_x);
    defer x_table.deinit(allocator);
    var y_table = try areaTable(allocator, src_height, dst_height, scale_y);
    defer y_table.deinit(allocator);

    const row_len = dst_width * channels;
    const context = AreaContext(T){
        .src = src,
        .src_row_len = src_width * channels,
        .channels = channels,
        .dst = dst,
        .row_len = row_len,
        .x = x_table,
        .y = y_table,
    };
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const band_count = @max(1, @min(cpu_count -| 1, dst_height / 16));
    const scratch = try allocator.alloc(f32, band_count * row_len * 2);
    defer allocator.free(scratch);
    if (band_count == 1) {
        context.rows(scratch, 0, dst_height);
        return;
    }
    const threads = try allocator.alloc(std.Thread, band_count);
    defer allocator.free(threads);
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (0..band_count) |band| {
        threads[band] = try std.Thread.spawn(.{}, AreaContext(T).rows, .{
            context,
            scratch[band * row_len * 2 ..][0 .. row_len * 2],
            dst_height * band / band_count,
            dst_height * (band + 1) / band_count,
        });
        started += 1;
    }
}

/// OpenCV's computeResizeAreaTab along one axis: for each output pixel, in
/// order, the source pixels it covers and the share of the output cell each
/// one fills.
const AreaTable = struct {
    /// Per output pixel, its entries in `source` and `alpha`.
    spans: []Span,
    source: []u32,
    alpha: []f32,

    const Span = struct { start: u32, len: u32 };

    fn deinit(self: *AreaTable, allocator: std.mem.Allocator) void {
        allocator.free(self.spans);
        allocator.free(self.source);
        allocator.free(self.alpha);
    }

    fn entries(self: AreaTable, index: usize) struct { []const u32, []const f32 } {
        const span = self.spans[index];
        return .{ self.source[span.start..][0..span.len], self.alpha[span.start..][0..span.len] };
    }
};

fn areaTable(allocator: std.mem.Allocator, src_len: usize, dst_len: usize, scale: f64) !AreaTable {
    var source: std.ArrayList(u32) = .empty;
    errdefer source.deinit(allocator);
    var alpha: std.ArrayList(f32) = .empty;
    errdefer alpha.deinit(allocator);
    try source.ensureTotalCapacity(allocator, src_len * 2);
    try alpha.ensureTotalCapacity(allocator, src_len * 2);
    const spans = try allocator.alloc(AreaTable.Span, dst_len);
    errdefer allocator.free(spans);
    const src_len_f: f64 = @floatFromInt(src_len);
    for (spans, 0..) |*span, dx| {
        const start = source.items.len;
        const fsx1 = @as(f64, @floatFromInt(dx)) * scale;
        const fsx2 = fsx1 + scale;
        const cell_width = @min(scale, src_len_f - fsx1);
        var sx1: i64 = @intFromFloat(@ceil(fsx1));
        var sx2: i64 = @intFromFloat(@floor(fsx2));
        sx2 = @min(sx2, @as(i64, @intCast(src_len)) - 1);
        sx1 = @min(sx1, sx2);
        const sx1_f: f64 = @floatFromInt(sx1);
        const sx2_f: f64 = @floatFromInt(sx2);
        if (sx1_f - fsx1 > 1e-3) {
            try source.append(allocator, @intCast(sx1 - 1));
            try alpha.append(allocator, @floatCast((sx1_f - fsx1) / cell_width));
        }
        var sx = sx1;
        while (sx < sx2) : (sx += 1) {
            try source.append(allocator, @intCast(sx));
            try alpha.append(allocator, @floatCast(1.0 / cell_width));
        }
        if (fsx2 - sx2_f > 1e-3) {
            try source.append(allocator, @intCast(sx2));
            try alpha.append(allocator, @floatCast(@min(@min(fsx2 - sx2_f, 1.0), cell_width) / cell_width));
        }
        span.* = .{ .start = @intCast(start), .len = @intCast(source.items.len - start) };
    }
    return .{
        .spans = spans,
        .source = try source.toOwnedSlice(allocator),
        .alpha = try alpha.toOwnedSlice(allocator),
    };
}

fn AreaContext(comptime T: type) type {
    return struct {
        src: []const T,
        src_row_len: usize,
        channels: usize,
        dst: []T,
        row_len: usize,
        x: AreaTable,
        y: AreaTable,

        /// Output rows [row_start, row_end), each the weighted sum of its
        /// source rows, each of those first summed across in f32: OpenCV's
        /// ResizeArea_Invoker, adding in the same order (each output
        /// pixel's sum starts from zero, so it is kept in registers here).
        fn rows(self: @This(), scratch: []f32, row_start: usize, row_end: usize) void {
            const buf = scratch[0..self.row_len];
            const sum = scratch[self.row_len..][0..self.row_len];
            for (row_start..row_end) |dy| {
                const source_rows, const betas = self.y.entries(dy);
                for (source_rows, betas, 0..) |sy, beta, index| {
                    const source_row = self.src[sy * self.src_row_len ..][0..self.src_row_len];
                    if (self.channels == 3) {
                        for (0..self.x.spans.len) |dx| {
                            const columns, const alphas = self.x.entries(dx);
                            var r: f32 = 0.0;
                            var g: f32 = 0.0;
                            var b: f32 = 0.0;
                            for (columns, alphas) |sx, alpha| {
                                const pixel = source_row[sx * 3 ..][0..3];
                                r += @as(f32, @floatFromInt(pixel[0])) * alpha;
                                g += @as(f32, @floatFromInt(pixel[1])) * alpha;
                                b += @as(f32, @floatFromInt(pixel[2])) * alpha;
                            }
                            buf[dx * 3] = r;
                            buf[dx * 3 + 1] = g;
                            buf[dx * 3 + 2] = b;
                        }
                    } else {
                        for (buf, 0..) |*out, dx| {
                            const columns, const alphas = self.x.entries(dx);
                            var value: f32 = 0.0;
                            for (columns, alphas) |sx, alpha| value += @as(f32, @floatFromInt(source_row[sx])) * alpha;
                            out.* = value;
                        }
                    }
                    if (index == 0) {
                        for (sum, buf) |*total, value| total.* = beta * value;
                    } else {
                        for (sum, buf) |*total, value| total.* += beta * value;
                    }
                }
                const out = self.dst[dy * self.row_len ..][0..self.row_len];
                for (out, sum) |*value, total| value.* = saturateRound(T, total);
            }
        }
    };
}

/// OpenCV's resizeAreaFast: each output pixel averages a whole block. Its
/// 2x2 path rounds halves up in integers; the others round the f32 mean.
fn resizeAreaWhole(
    comptime T: type,
    src: []const T,
    src_width: usize,
    channels: usize,
    dst: []T,
    dst_width: usize,
    dst_height: usize,
    block_x: usize,
    block_y: usize,
) void {
    const src_row_len = src_width * channels;
    const area_scale: f32 = 1.0 / @as(f32, @floatFromInt(block_x * block_y));
    for (0..dst_height) |dy| {
        for (0..dst_width) |dx| {
            for (0..channels) |channel| {
                const origin = dy * block_y * src_row_len + dx * block_x * channels + channel;
                const out = &dst[(dy * dst_width + dx) * channels + channel];
                if (block_x == 2 and block_y == 2) {
                    const total = @as(u32, src[origin]) + src[origin + channels] + src[origin + src_row_len] + src[origin + src_row_len + channels];
                    out.* = @intCast((total + 2) >> 2);
                } else {
                    var total: u64 = 0;
                    for (0..block_y) |by| {
                        for (0..block_x) |bx| total += src[origin + by * src_row_len + bx * channels];
                    }
                    out.* = saturateRound(T, @as(f32, @floatFromInt(total)) * area_scale);
                }
            }
        }
    }
}

/// OpenCV's saturate_cast from float: round half to even, then clamp.
fn saturateRound(comptime T: type, value: f32) T {
    if (value <= 0.0) return 0;
    if (value >= @as(f32, @floatFromInt(std.math.maxInt(T)))) return std.math.maxInt(T);
    const floor = @floor(value);
    const fraction = value - floor;
    const whole: T = @intFromFloat(floor);
    if (fraction > 0.5 or (fraction == 0.5 and whole & 1 == 1)) return whole + 1;
    return whole;
}

fn roundHalfEven(comptime F: type, value: F) F {
    const floor = @floor(value);
    const fraction = value - floor;
    if (fraction > 0.5) return floor + 1.0;
    if (fraction < 0.5) return floor;
    return if (@mod(floor, 2.0) == 0.0) floor else floor + 1.0;
}

test "area resize keeps a flat image flat at whole and fractional scales" {
    const allocator = std.testing.allocator;
    const src = try allocator.alloc(u16, 37 * 23 * 3);
    defer allocator.free(src);
    @memset(src, 40000);
    for ([_][2]usize{ .{ 18, 11 }, .{ 12, 9 }, .{ 37, 7 }, .{ 5, 23 } }) |size| {
        const dst = try allocator.alloc(u16, size[0] * size[1] * 3);
        defer allocator.free(dst);
        try resizeArea(u16, allocator, src, 37, 23, 3, dst, size[0], size[1]);
        for (dst) |value| try std.testing.expectEqual(@as(u16, 40000), value);
    }
}

test "area resize at 2x rounds halves up, at 4x to even" {
    const allocator = std.testing.allocator;
    var out = [_]u8{0};
    // Mean 0.5: the 2x2 path's integer rounding gives 1.
    const two = [_]u8{ 1, 0, 0, 1 };
    try resizeArea(u8, allocator, &two, 2, 2, 1, &out, 1, 1);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    // Mean 2.5 over a 4x4 block rounds to the even 2.
    const four = [_]u8{ 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3 };
    try resizeArea(u8, allocator, &four, 4, 4, 1, &out, 1, 1);
    try std.testing.expectEqual(@as(u8, 2), out[0]);
}

test "area weights cover each output cell once" {
    const allocator = std.testing.allocator;
    var table = try areaTable(allocator, 17, 12, 17.0 / 12.0);
    defer table.deinit(allocator);
    for (0..12) |dx| {
        _, const alphas = table.entries(dx);
        var total: f64 = 0.0;
        for (alphas) |alpha| total += alpha;
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), total, 1e-6);
    }
}
