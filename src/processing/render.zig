const std = @import("std");

const color = @import("color.zig");
const numeric = @import("numeric_fixture.zig");

pub const SigmoidTonemapOptions = struct {
    mid_grey: f64 = 0.18,
    white_point: f64 = 1.0,
    black_point: f64 = 0.0,
    contrast: f64 = 1.4,
};

pub const RenderToDisplayOptions = struct {
    contrast: f64 = 1.4,
    black_point: f64 = 0.0,
    curve_k: f64 = 5.0,
    percentile_lo: f64 = 0.5,
    percentile_hi: f64 = 99.5,
    exposure_compensation: f64 = 0.0,
    color_temp: f64 = 0.0,
    color_tint: f64 = 0.0,
};

pub fn sigmoidTonemapValue(value: f64, options: SigmoidTonemapOptions) f64 {
    if (value <= 0.0) return options.black_point;
    const xp = std.math.pow(f64, value, options.contrast);
    const mp = std.math.pow(f64, options.mid_grey, options.contrast);
    const sigmoid = xp / (xp + mp);
    return options.black_point + (options.white_point - options.black_point) * sigmoid;
}

pub fn sigmoidTonemap(input: []const f64, output: []f64, options: SigmoidTonemapOptions) !void {
    try validateRgbBuffers(input, output);
    for (input, output) |value, *out| {
        out.* = sigmoidTonemapValue(value, options);
    }
}

pub fn applySrgbGamma(input: []const f64, output: []f64) !void {
    try validateRgbBuffers(input, output);
    for (input, output) |value, *out| {
        out.* = color.linearToSrgbValue(value);
    }
}

pub fn renderToDisplay(
    allocator: std.mem.Allocator,
    input: []const f64,
    output: []u16,
    options: RenderToDisplayOptions,
) !void {
    try validateRgbInput(input);
    if (input.len != output.len) return error.InvalidRenderBuffer;
    try validatePercentile(options.percentile_lo);
    try validatePercentile(options.percentile_hi);

    const range = try robustLuminanceRange(allocator, input, options.percentile_lo, options.percentile_hi);
    const denominator = range.hi - range.lo;

    var multipliers = [_]f64{ 1.0, 1.0, 1.0 };
    const apply_color_balance = @abs(options.color_temp) > 0.001 or @abs(options.color_tint) > 0.001;
    if (apply_color_balance) {
        multipliers = colorBalanceMultipliers(options.color_temp, options.color_tint);
    }

    const apply_exposure = @abs(options.exposure_compensation) > 0.001;
    const exposure_gamma = if (apply_exposure) 1.0 / (1.0 + options.exposure_compensation) else 1.0;

    const apply_contrast = options.contrast > 1.001 and (options.contrast - 1.0) * options.curve_k > 0.1;
    const contrast_k = (options.contrast - 1.0) * options.curve_k;
    const curve: ContrastCurveConstants = if (apply_contrast) contrastCurveConstants(contrast_k) else .{ .lo = 0.0, .hi = 1.0 };

    _ = options.black_point;

    for (input, output, 0..) |value, *out, index| {
        var display = clamp((value - range.lo) / denominator, 0.0, 1.0);
        if (apply_color_balance) {
            display = @max(display * multipliers[index % 3], 0.0);
        }
        if (apply_exposure) {
            display = std.math.pow(f64, display, exposure_gamma);
        }
        if (apply_contrast) {
            const raw = logistic(contrast_k, display);
            display = (raw - curve.lo) / (curve.hi - curve.lo);
        }
        display = clamp(display, 0.0, 1.0);
        out.* = @as(u16, @intFromFloat(clamp(display * 65535.0, 0.0, 65535.0)));
    }
}

fn validateRgbBuffers(input: []const f64, output: []const f64) !void {
    try validateRgbInput(input);
    if (input.len != output.len) return error.InvalidRenderBuffer;
}

fn validateRgbInput(input: []const f64) !void {
    if (input.len == 0) return error.InvalidRenderBuffer;
    if (input.len % 3 != 0) return error.InvalidRenderBuffer;
}

fn validatePercentile(percentile: f64) !void {
    if (!std.math.isFinite(percentile) or percentile < 0.0 or percentile > 100.0) {
        return error.InvalidRenderPercentile;
    }
}

const LuminanceRange = struct {
    lo: f64,
    hi: f64,
};

fn robustLuminanceRange(
    allocator: std.mem.Allocator,
    input: []const f64,
    percentile_lo: f64,
    percentile_hi: f64,
) !LuminanceRange {
    const pixel_count = input.len / 3;
    const positive = try allocator.alloc(f64, pixel_count);
    defer allocator.free(positive);

    var count: usize = 0;
    var index: usize = 0;
    while (index < input.len) : (index += 3) {
        const luminance = 0.2126 * input[index] + 0.7152 * input[index + 1] + 0.0722 * input[index + 2];
        if (luminance > 0.001) {
            positive[count] = luminance;
            count += 1;
        }
    }

    if (count == 0) return .{ .lo = 0.0, .hi = 1.0 };

    const values = positive[0..count];
    std.sort.pdq(f64, values, {}, lessThanF64);
    const lo = percentileSorted(values, percentile_lo);
    var hi = percentileSorted(values, percentile_hi);
    if (hi <= lo) {
        hi = lo + 1.0;
    }
    return .{ .lo = lo, .hi = hi };
}

fn percentileSorted(values: []const f64, percentile: f64) f64 {
    const rank = (@as(f64, @floatFromInt(values.len - 1)) * percentile) / 100.0;
    const lower: usize = @intFromFloat(@floor(rank));
    const upper: usize = @intFromFloat(@ceil(rank));
    const fraction = rank - @as(f64, @floatFromInt(lower));
    return values[lower] * (1.0 - fraction) + values[upper] * fraction;
}

fn lessThanF64(_: void, lhs: f64, rhs: f64) bool {
    return lhs < rhs;
}

fn colorBalanceMultipliers(color_temp: f64, color_tint: f64) [3]f64 {
    var r_mul = 1.0 + color_temp * 0.5;
    var b_mul = 1.0 - color_temp * 0.5;
    var g_mul = 1.0 - color_tint * 0.5;
    const lum_scale = 0.2126 * r_mul + 0.7152 * g_mul + 0.0722 * b_mul;
    r_mul /= lum_scale;
    g_mul /= lum_scale;
    b_mul /= lum_scale;
    return .{ r_mul, g_mul, b_mul };
}

const ContrastCurveConstants = struct {
    lo: f64,
    hi: f64,
};

fn contrastCurveConstants(k: f64) ContrastCurveConstants {
    return .{
        .lo = logistic(k, 0.0),
        .hi = logistic(k, 1.0),
    };
}

fn logistic(k: f64, value: f64) f64 {
    return 1.0 / (1.0 + @exp(-k * (value - 0.5)));
}

fn clamp(value: f64, lo: f64, hi: f64) f64 {
    return @min(@max(value, lo), hi);
}

fn expectRenderDisplayFixture(path: []const u8, options: RenderToDisplayOptions) !void {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, path);
    defer fixture.deinit();

    const value = fixture.value();
    const actual_u16 = try allocator.alloc(u16, value.expected.len);
    defer allocator.free(actual_u16);
    try renderToDisplay(allocator, value.input, actual_u16, options);

    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    for (actual_u16, actual) |sample, *out| {
        out.* = @floatFromInt(sample);
    }
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "sigmoid tone map matches Python fixture" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/sigmoid-tonemap.json");
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try sigmoidTonemap(value.input, actual, .{
        .mid_grey = 0.18,
        .white_point = 0.9,
        .black_point = 0.02,
        .contrast = 1.4,
    });
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "sigmoid tone map rejects non-RGB flat buffers" {
    var out: [2]f64 = undefined;
    try std.testing.expectError(error.InvalidRenderBuffer, sigmoidTonemap(&.{ 0.1, 0.2 }, &out, .{}));
}

test "apply sRGB gamma matches Python render fixture" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/apply-srgb-gamma.json");
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try applySrgbGamma(value.input, actual);
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "render to display baseline matches Python fixture" {
    try expectRenderDisplayFixture("test/fixtures/processing/numeric/render-to-display-baseline.json", .{
        .contrast = 1.4,
        .black_point = 0.0,
        .curve_k = 5.0,
        .percentile_lo = 10.0,
        .percentile_hi = 90.0,
        .exposure_compensation = 0.0,
        .color_temp = 0.0,
        .color_tint = 0.0,
    });
}

test "render to display adjustments match Python fixture" {
    try expectRenderDisplayFixture("test/fixtures/processing/numeric/render-to-display-adjusted.json", .{
        .contrast = 1.25,
        .black_point = 0.1,
        .curve_k = 4.0,
        .percentile_lo = 5.0,
        .percentile_hi = 95.0,
        .exposure_compensation = 0.35,
        .color_temp = 0.4,
        .color_tint = -0.25,
    });
}

test "render to display handles no positive luminance like Python" {
    try expectRenderDisplayFixture("test/fixtures/processing/numeric/render-to-display-no-positive-luminance.json", .{
        .contrast = 1.4,
        .curve_k = 5.0,
        .percentile_lo = 0.5,
        .percentile_hi = 99.5,
        .exposure_compensation = 0.0,
        .color_temp = 0.0,
        .color_tint = 0.0,
    });
}

test "render to display validates buffers and percentiles" {
    var out: [3]u16 = undefined;
    try std.testing.expectError(error.InvalidRenderBuffer, renderToDisplay(std.testing.allocator, &.{ 0.1, 0.2 }, &out, .{}));
    try std.testing.expectError(error.InvalidRenderPercentile, renderToDisplay(std.testing.allocator, &.{ 0.1, 0.2, 0.3 }, &out, .{ .percentile_lo = -1.0 }));
}
