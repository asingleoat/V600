const std = @import("std");

const color = @import("color.zig");
const numeric = @import("numeric_fixture.zig");
const parallelism = @import("parallelism.zig");

pub const exact_percentile_sample_limit: usize = 0;
pub const default_percentile_sample_limit: usize = 16_384;

pub const SigmoidTonemapOptions = struct {
    mid_grey: f64 = 0.18,
    white_point: f64 = 1.0,
    black_point: f64 = 0.0,
    contrast: f64 = 1.4,
};

pub const RenderToDisplayOptions = struct {
    /// Contrast of the display curve, a log-logistic through 18% grey: its
    /// exponent, so 1 is gentle and higher is punchier.
    contrast: f64 = 1.8,
    percentile_lo: f64 = 0.5,
    percentile_hi: f64 = 99.5,
    /// Exposure in stops on top of the automatic exposure.
    exposure_compensation: f64 = 0.0,
    /// Warmer (positive) or cooler: about half a stop per unit, red against
    /// blue.
    color_temp: f64 = 0.0,
    /// Magenta (positive) or green: about half a stop per unit on green.
    color_tint: f64 = 0.0,
    /// Automatic white balance, 0 (off) to 1: how far red and blue move from
    /// the stock's average balance onto green's density scale through their
    /// own black and white points, so neutral shadows and highlights render
    /// neutral whatever the light or the lab left in the negative.
    auto_white_balance: f64 = 1.0,
    /// The film's contrast: net density per decade of exposure on the
    /// straight part of its characteristic curve.
    film_gamma: f64 = 0.55,
    /// Width of the film's toe, in decades of exposure.
    film_toe: f64 = 0.25,
    /// Dye crosstalk the scan sees, from 0: colour differences in log
    /// exposure grow by 1 / (1 - dye_crosstalk).
    dye_crosstalk: f64 = 0.2,
    percentile_sample_limit: usize = default_percentile_sample_limit,
    /// The width of the frame being rendered, when the image is one frame:
    /// the white balance and exposure are then measured inside it, leaving
    /// out the slivers of film border a frame crop takes in. 0 measures the
    /// whole image.
    frame_width: usize = 0,
};

/// The share of a frame's width and height left out on each side when
/// measuring it (`RenderToDisplayOptions.frame_width`): enough for the film
/// border slivers of real crops; more starts to drop picture (5% shifted a
/// Portra frame's balance as much as its edge lettering did).
const frame_measure_inset: f64 = 0.025;

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
    try renderPixels(f64, u16, allocator, input, output, options);
}

pub fn renderToDisplayU8(
    allocator: std.mem.Allocator,
    input: []const f64,
    output: []u8,
    options: RenderToDisplayOptions,
) !void {
    try renderPixels(f64, u8, allocator, input, output, options);
}

pub fn renderToDisplayU8F32(
    allocator: std.mem.Allocator,
    input: []const f32,
    output: []u8,
    options: RenderToDisplayOptions,
) !void {
    try renderPixels(f32, u8, allocator, input, output, options);
}

pub fn renderToDisplayU16F32(
    allocator: std.mem.Allocator,
    input: []const f32,
    output: []u16,
    options: RenderToDisplayOptions,
) !void {
    try renderPixels(f32, u16, allocator, input, output, options);
}

// The display transform, for the net density the inversion leaves (after
// Dmin and the stock's channel balance), per pixel:
//   1. red and blue onto green's density scale (automatic white balance);
//   2. the film's characteristic curve inverted, a straight line of slope
//      film_gamma with a softplus toe: log10 exposure;
//   3. dye crosstalk undone: colour differences around the pixel's mean log
//      exposure grow by 1 / (1 - dye_crosstalk);
//   4. exposure (automatic, to an 18% log-average, plus compensation) and
//      temperature/tint as log offsets, so gains on scene-linear light;
//   5. a log-logistic display curve through 18% grey, then sRGB encoding,
//      from a table over log exposure.

const display_table_entries: usize = 8192;
// The curve inversion is near-logarithmic at low density, so the table
// starts above it; densities outside the table are computed exactly.
const curve_table_entries: usize = 16384;
const curve_table_lo: f64 = 1.0 / 64.0;
const curve_table_hi: f64 = 4.0;
// Below the table (film base, and the thin negative of deep shadows; over a
// third of a strip preview) a second table steps through density by its
// floating-point bits: 256 cells per octave, linear within each, from 2^-30
// (under the exact inversion's 1e-9 floor) up to curve_table_lo = 2^-6.
const low_curve_octaves: u6 = 24;
const low_curve_cell_bits: u6 = 8;
const low_curve_entries: usize = (@as(usize, low_curve_octaves) << low_curve_cell_bits) + 1;
const low_curve_min_exponent: i32 = -30;
const low_curve_fraction_bits: u6 = 52 - low_curve_cell_bits;
const low_curve_floor: f64 = 1e-9;
const display_table_lo: f64 = -8.0;
const display_table_hi: f64 = 4.0;
const mid_grey: f64 = 0.18;
const temp_tint_decades: f64 = 0.15;
const render_pixels_per_worker: usize = 1 << 18;

const DisplayTransform = struct {
    scale: [3]f64,
    offset: [3]f64,
    inv_gamma_toe: f64,
    toe: f64,
    chroma_gain: f64,
    log_offset: [3]f64,
    table: [display_table_entries]f32,
    curve_table: [curve_table_entries]f32,
    low_curve_table: [low_curve_entries]f32,
};

fn renderPixels(
    comptime In: type,
    comptime Out: type,
    allocator: std.mem.Allocator,
    input: []const In,
    output: []Out,
    options: RenderToDisplayOptions,
) !void {
    if (input.len == 0 or input.len % 3 != 0 or input.len != output.len) return error.InvalidRenderBuffer;
    try validateRenderOptions(options);
    const transform = try allocator.create(DisplayTransform);
    defer allocator.destroy(transform);
    try buildDisplayTransform(In, allocator, input, options, transform);

    const pixel_count = input.len / 3;
    const worker_count = if (comptime parallelism.enabled) workerCountForPixels(pixel_count, render_pixels_per_worker) else 1;
    if (worker_count <= 1) {
        renderRange(In, Out, input, output, transform, 0, pixel_count);
        return;
    }
    const Context = RenderContext(In, Out);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(Context, worker_count);
    defer allocator.free(contexts);
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (0..worker_count) |worker_index| {
        contexts[worker_index] = .{
            .input = input,
            .output = output,
            .transform = transform,
            .pixel_start = pixel_count * worker_index / worker_count,
            .pixel_end = pixel_count * (worker_index + 1) / worker_count,
        };
        threads[worker_index] = try std.Thread.spawn(.{}, Context.run, .{&contexts[worker_index]});
        started += 1;
    }
    for (threads) |thread| thread.join();
}

fn RenderContext(comptime In: type, comptime Out: type) type {
    return struct {
        input: []const In,
        output: []Out,
        transform: *const DisplayTransform,
        pixel_start: usize,
        pixel_end: usize,

        fn run(context: *const @This()) void {
            renderRange(In, Out, context.input, context.output, context.transform, context.pixel_start, context.pixel_end);
        }
    };
}

fn renderRange(
    comptime In: type,
    comptime Out: type,
    input: []const In,
    output: []Out,
    transform: *const DisplayTransform,
    pixel_start: usize,
    pixel_end: usize,
) void {
    for (pixel_start..pixel_end) |pixel| {
        const index = pixel * 3;
        const x = displayLogExposure(transform, .{ input[index], input[index + 1], input[index + 2] });
        inline for (0..3) |channel| {
            const display = displayLookup(transform, x[channel] + transform.log_offset[channel]);
            output[index + channel] = switch (Out) {
                u16 => displayToU16(display),
                u8 => @intCast(displayToU16(display) >> 8),
                else => @compileError("render output must be u8 or u16"),
            };
        }
    }
}

/// Log10 exposure of one pixel after channel alignment, curve inversion,
/// and crosstalk, before exposure and temperature/tint.
inline fn displayLogExposure(transform: *const DisplayTransform, rgb: anytype) [3]f64 {
    var x: [3]f64 = undefined;
    inline for (0..3) |channel| {
        const density = @as(f64, rgb[channel]) * transform.scale[channel] + transform.offset[channel];
        x[channel] = curveLookup(transform, density);
    }
    const mean = (x[0] + x[1] + x[2]) / 3.0;
    inline for (0..3) |channel| {
        x[channel] = mean + transform.chroma_gain * (x[channel] - mean);
    }
    return x;
}

/// Inverts density = gamma * toe * ln(1 + exp(x / toe)): a straight line of
/// slope gamma with a smooth toe at the film base.
fn filmLogExposure(density: f64, inv_gamma_toe: f64, toe: f64) f64 {
    const z = @min(@max(density, low_curve_floor) * inv_gamma_toe, 50.0);
    return toe * @log(std.math.expm1(z));
}

inline fn curveLookup(transform: *const DisplayTransform, density: f64) f64 {
    if (density < curve_table_lo) return lowCurveLookup(transform, density);
    const steps = @as(f64, @floatFromInt(curve_table_entries - 1));
    const position = (density - curve_table_lo) * (steps / (curve_table_hi - curve_table_lo));
    if (!(position >= 0.0) or position >= steps) return filmLogExposure(density, transform.inv_gamma_toe, transform.toe);
    const lower: usize = @intFromFloat(position);
    const fraction = position - @as(f64, @floatFromInt(lower));
    const lo: f64 = transform.curve_table[lower];
    const hi: f64 = transform.curve_table[lower + 1];
    return lo + (hi - lo) * fraction;
}

/// For densities below curve_table_lo: the biased exponent and the top
/// mantissa bits pick the cell, the rest of the mantissa is the fraction.
inline fn lowCurveLookup(transform: *const DisplayTransform, density: f64) f64 {
    const bits: u64 = @bitCast(@max(density, low_curve_floor));
    const first_cell = @as(u64, @intCast(1023 + low_curve_min_exponent)) << low_curve_cell_bits;
    const cell: usize = @intCast((bits >> low_curve_fraction_bits) - first_cell);
    const fraction_mask = (@as(u64, 1) << low_curve_fraction_bits) - 1;
    const fraction = @as(f64, @floatFromInt(bits & fraction_mask)) * (1.0 / @as(f64, @floatFromInt(@as(u64, 1) << low_curve_fraction_bits)));
    const lo: f64 = transform.low_curve_table[cell];
    const hi: f64 = transform.low_curve_table[cell + 1];
    return lo + (hi - lo) * fraction;
}

/// The density at the start of `cell` of the low curve table.
fn lowCurveCellDensity(cell: usize) f64 {
    const octave: i32 = @intCast(cell >> low_curve_cell_bits);
    const step = cell & ((@as(usize, 1) << low_curve_cell_bits) - 1);
    const base = std.math.ldexp(@as(f64, 1.0), octave + low_curve_min_exponent);
    return base * (1.0 + @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(@as(usize, 1) << low_curve_cell_bits)));
}

inline fn displayLookup(transform: *const DisplayTransform, log_exposure: f64) f64 {
    const steps = @as(f64, @floatFromInt(display_table_entries - 1));
    const position = (log_exposure - display_table_lo) * (steps / (display_table_hi - display_table_lo));
    if (!(position > 0.0)) return transform.table[0];
    if (position >= steps) return transform.table[display_table_entries - 1];
    const lower: usize = @intFromFloat(position);
    const fraction = position - @as(f64, @floatFromInt(lower));
    const lo: f64 = transform.table[lower];
    const hi: f64 = transform.table[lower + 1];
    return lo + (hi - lo) * fraction;
}

/// Display value (sRGB-encoded, 0 to 1) for scene-linear exposure `exposure`,
/// with 18% grey at 18% display light.
fn displayCurve(exposure: f64, contrast: f64) f64 {
    return displayCurveWithKey(exposure, contrast, displayCurveKeyPower(contrast));
}

/// K^p of the display curve, the same for every exposure.
fn displayCurveKeyPower(contrast: f64) f64 {
    const k = mid_grey * std.math.pow(f64, 1.0 / mid_grey - 1.0, 1.0 / contrast);
    return std.math.pow(f64, k, contrast);
}

fn displayCurveWithKey(exposure: f64, contrast: f64, key_power: f64) f64 {
    const ep = std.math.pow(f64, @max(exposure, 0.0), contrast);
    return color.linearToSrgbValue(ep / (ep + key_power));
}

fn buildDisplayTransform(
    comptime In: type,
    allocator: std.mem.Allocator,
    input: []const In,
    options: RenderToDisplayOptions,
    transform: *DisplayTransform,
) !void {
    transform.scale = .{ 1.0, 1.0, 1.0 };
    transform.offset = .{ 0.0, 0.0, 0.0 };
    transform.inv_gamma_toe = 1.0 / (options.film_gamma * options.film_toe);
    transform.toe = options.film_toe;
    transform.chroma_gain = 1.0 / (1.0 - options.dye_crosstalk);
    transform.log_offset = .{ 0.0, 0.0, 0.0 };
    for (&transform.curve_table, 0..) |*entry, index| {
        const fraction = @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(curve_table_entries - 1));
        entry.* = @floatCast(filmLogExposure(curve_table_lo + fraction * (curve_table_hi - curve_table_lo), transform.inv_gamma_toe, transform.toe));
    }
    // Unclamped: the cell holding the floor starts just below it.
    for (&transform.low_curve_table, 0..) |*entry, cell| {
        entry.* = @floatCast(transform.toe * @log(std.math.expm1(lowCurveCellDensity(cell) * transform.inv_gamma_toe)));
    }
    const key_power = displayCurveKeyPower(options.contrast);
    for (&transform.table, 0..) |*entry, index| {
        const fraction = @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(display_table_entries - 1));
        const log_exposure = display_table_lo + fraction * (display_table_hi - display_table_lo);
        entry.* = @floatCast(displayCurveWithKey(std.math.pow(f64, 10.0, log_exposure), options.contrast, key_power));
    }

    const region = measureRegion(input.len / 3, options.frame_width);
    const region_count = region.width * region.height;
    const sample_count = percentileSampleCount(region_count, options.percentile_sample_limit);
    const values = try allocator.alloc(f32, sample_count * 3);
    defer allocator.free(values);
    const pixels = try allocator.alloc(usize, sample_count);
    defer allocator.free(pixels);
    var count: usize = 0;
    for (0..sample_count) |sample_index| {
        const region_index = if (sample_count == region_count) sample_index else stratifiedPixelIndex(region_count, sample_count, sample_index);
        const pixel = (region.y + region_index / region.width) * region.stride + region.x + region_index % region.width;
        const index = pixel * 3;
        const r: f64 = @as(f64, input[index]);
        const g: f64 = @as(f64, input[index + 1]);
        const b: f64 = @as(f64, input[index + 2]);
        if (!(pixelLuminance(r, g, b) > 0.001)) continue;
        values[count] = @floatCast(r);
        values[sample_count + count] = @floatCast(g);
        values[2 * sample_count + count] = @floatCast(b);
        pixels[count] = pixel;
        count += 1;
    }

    // Automatic white balance: red and blue onto green's density scale
    // through each channel's own black and white point.
    if (count > 0 and options.auto_white_balance > 0.0) {
        var lo: [3]f64 = undefined;
        var hi: [3]f64 = undefined;
        for (0..3) |channel| {
            const channel_values = values[channel * sample_count ..][0..count];
            const sorted = try allocator.dupe(f32, channel_values);
            defer allocator.free(sorted);
            std.sort.pdq(f32, sorted, {}, lessThanF32);
            lo[channel] = percentileSortedF32(sorted, options.percentile_lo);
            hi[channel] = percentileSortedF32(sorted, options.percentile_hi);
        }
        const green_span = hi[1] - lo[1];
        for ([_]usize{ 0, 2 }) |channel| {
            const span = hi[channel] - lo[channel];
            if (!(span > 1e-9) or !(green_span > 1e-9)) continue;
            const scale = green_span / span;
            const offset = lo[1] - scale * lo[channel];
            transform.scale[channel] = 1.0 + options.auto_white_balance * (scale - 1.0);
            transform.offset[channel] = options.auto_white_balance * offset;
        }
    }

    // Automatic exposure: the log-average luminance of scene-linear light
    // goes to 18%.
    var log_sum: f64 = 0.0;
    var log_count: usize = 0;
    for (pixels[0..count]) |pixel| {
        const index = pixel * 3;
        const x = displayLogExposure(transform, .{ input[index], input[index + 1], input[index + 2] });
        const luminance = pixelLuminance(
            std.math.pow(f64, 10.0, x[0]),
            std.math.pow(f64, 10.0, x[1]),
            std.math.pow(f64, 10.0, x[2]),
        );
        if (!(luminance > 0.0) or !std.math.isFinite(luminance)) continue;
        log_sum += @log10(luminance);
        log_count += 1;
    }
    const key_log = if (log_count > 0) log_sum / @as(f64, @floatFromInt(log_count)) else @log10(mid_grey);
    const exposure = @log10(mid_grey) - key_log + options.exposure_compensation * @log10(2.0);

    const temp = temp_tint_decades * options.color_temp;
    const tint = temp_tint_decades * options.color_tint;
    const shifts = [3]f64{ temp, -tint, -temp };
    const shift_mean = pixelLuminance(shifts[0], shifts[1], shifts[2]);
    for (&transform.log_offset, shifts) |*offset, shift| {
        offset.* = exposure + shift - shift_mean;
    }
}

const MeasureRegion = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    stride: usize,
};

fn measureRegion(pixel_count: usize, frame_width: usize) MeasureRegion {
    if (frame_width == 0 or pixel_count % frame_width != 0) {
        return .{ .x = 0, .y = 0, .width = pixel_count, .height = 1, .stride = pixel_count };
    }
    const frame_height = pixel_count / frame_width;
    const inset_x: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(frame_width)) * frame_measure_inset));
    const inset_y: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(frame_height)) * frame_measure_inset));
    if (2 * inset_x >= frame_width or 2 * inset_y >= frame_height) {
        return .{ .x = 0, .y = 0, .width = frame_width, .height = frame_height, .stride = frame_width };
    }
    return .{
        .x = inset_x,
        .y = inset_y,
        .width = frame_width - 2 * inset_x,
        .height = frame_height - 2 * inset_y,
        .stride = frame_width,
    };
}

fn validateRenderOptions(options: RenderToDisplayOptions) !void {
    try validatePercentile(options.percentile_lo);
    try validatePercentile(options.percentile_hi);
    try validateWhiteBalance(options.auto_white_balance);
    const finite = std.math.isFinite;
    if (!finite(options.contrast) or options.contrast <= 0.0) return error.InvalidRenderContrast;
    if (!finite(options.exposure_compensation) or !finite(options.color_temp) or !finite(options.color_tint)) return error.InvalidRenderAdjustment;
    if (!finite(options.film_gamma) or options.film_gamma <= 0.0 or !finite(options.film_toe) or options.film_toe <= 0.0) return error.InvalidRenderFilmCurve;
    if (!finite(options.dye_crosstalk) or options.dye_crosstalk < 0.0 or options.dye_crosstalk >= 0.95) return error.InvalidRenderCrosstalk;
}

fn workerCountForPixels(pixel_count: usize, min_pixels: usize) usize {
    if (pixel_count < min_pixels) return 1;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    if (cpu_count <= 1) return 1;
    return @min(cpu_count - 1, pixel_count / min_pixels);
}

fn displayToU16(display: f64) u16 {
    return @intFromFloat(clamp(display * 65535.0, 0.0, 65535.0));
}

fn validateRgbBuffers(input: []const f64, output: []const f64) !void {
    try validateRgbInput(input);
    if (input.len != output.len) return error.InvalidRenderBuffer;
}

fn validateRgbInput(input: []const f64) !void {
    if (input.len == 0) return error.InvalidRenderBuffer;
    if (input.len % 3 != 0) return error.InvalidRenderBuffer;
}

fn validateRgbInputF32(input: []const f32) !void {
    if (input.len == 0) return error.InvalidRenderBuffer;
    if (input.len % 3 != 0) return error.InvalidRenderBuffer;
}

fn validateWhiteBalance(strength: f64) !void {
    if (!std.math.isFinite(strength) or strength < 0.0 or strength > 1.0) return error.InvalidRenderWhiteBalance;
}

fn validatePercentile(percentile: f64) !void {
    if (!std.math.isFinite(percentile) or percentile < 0.0 or percentile > 100.0) {
        return error.InvalidRenderPercentile;
    }
}

pub const LuminanceRange = struct {
    lo: f64,
    hi: f64,
};

pub fn estimateDisplayLuminanceRange(
    allocator: std.mem.Allocator,
    input: []const f64,
    options: RenderToDisplayOptions,
) !LuminanceRange {
    try validateRgbInput(input);
    try validatePercentile(options.percentile_lo);
    try validatePercentile(options.percentile_hi);
    return robustLuminanceRange(allocator, input, options.percentile_lo, options.percentile_hi, options.percentile_sample_limit);
}

pub fn estimateDisplayLuminanceRangeF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    options: RenderToDisplayOptions,
) !LuminanceRange {
    try validateRgbInputF32(input);
    try validatePercentile(options.percentile_lo);
    try validatePercentile(options.percentile_hi);
    return robustLuminanceRangeF32(allocator, input, options.percentile_lo, options.percentile_hi, options.percentile_sample_limit);
}

fn robustLuminanceRange(
    allocator: std.mem.Allocator,
    input: []const f64,
    percentile_lo: f64,
    percentile_hi: f64,
    sample_limit: usize,
) !LuminanceRange {
    const pixel_count = input.len / 3;
    const sample_count = percentileSampleCount(pixel_count, sample_limit);
    if (sample_count == pixel_count) {
        return robustLuminanceRangeExact(allocator, input, percentile_lo, percentile_hi);
    }

    return robustLuminanceRangeSampled(allocator, input, percentile_lo, percentile_hi, sample_count);
}

fn robustLuminanceRangeF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    percentile_lo: f64,
    percentile_hi: f64,
    sample_limit: usize,
) !LuminanceRange {
    const pixel_count = input.len / 3;
    const sample_count = percentileSampleCount(pixel_count, sample_limit);
    if (sample_count == pixel_count) {
        return robustLuminanceRangeExactF32(allocator, input, percentile_lo, percentile_hi);
    }

    return robustLuminanceRangeSampledF32(allocator, input, percentile_lo, percentile_hi, sample_count);
}

fn robustLuminanceRangeExact(
    allocator: std.mem.Allocator,
    input: []const f64,
    percentile_lo: f64,
    percentile_hi: f64,
) !LuminanceRange {
    const pixel_count = input.len / 3;
    const positive = try allocator.alloc(f64, pixel_count);
    defer allocator.free(positive);

    const count = collectPositiveLuminanceExact(input, positive);

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

fn robustLuminanceRangeExactF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    percentile_lo: f64,
    percentile_hi: f64,
) !LuminanceRange {
    const pixel_count = input.len / 3;
    const positive = try allocator.alloc(f64, pixel_count);
    defer allocator.free(positive);

    const count = collectPositiveLuminanceExactF32(input, positive);

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

fn robustLuminanceRangeSampled(
    allocator: std.mem.Allocator,
    input: []const f64,
    percentile_lo: f64,
    percentile_hi: f64,
    sample_count: usize,
) !LuminanceRange {
    const positive = try allocator.alloc(f32, sample_count);
    defer allocator.free(positive);

    const count = collectPositiveLuminanceSampled(input, positive, sample_count);
    if (count == 0) {
        return robustLuminanceRangeExact(allocator, input, percentile_lo, percentile_hi);
    }

    const values = positive[0..count];
    std.sort.pdq(f32, values, {}, lessThanF32);
    const lo = percentileSortedF32(values, percentile_lo);
    var hi = percentileSortedF32(values, percentile_hi);
    if (hi <= lo) {
        hi = lo + 1.0;
    }
    return .{ .lo = lo, .hi = hi };
}

fn robustLuminanceRangeSampledF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    percentile_lo: f64,
    percentile_hi: f64,
    sample_count: usize,
) !LuminanceRange {
    const positive = try allocator.alloc(f32, sample_count);
    defer allocator.free(positive);

    const count = collectPositiveLuminanceSampledF32(input, positive, sample_count);
    if (count == 0) {
        return robustLuminanceRangeExactF32(allocator, input, percentile_lo, percentile_hi);
    }

    const values = positive[0..count];
    std.sort.pdq(f32, values, {}, lessThanF32);
    const lo = percentileSortedF32(values, percentile_lo);
    var hi = percentileSortedF32(values, percentile_hi);
    if (hi <= lo) {
        hi = lo + 1.0;
    }
    return .{ .lo = lo, .hi = hi };
}

fn percentileSampleCount(pixel_count: usize, sample_limit: usize) usize {
    if (sample_limit == exact_percentile_sample_limit or sample_limit >= pixel_count) return pixel_count;
    return @max(sample_limit, 1);
}

pub fn percentileScratchSampleCount(pixel_count: usize, sample_limit: usize) usize {
    return percentileSampleCount(pixel_count, sample_limit);
}

fn collectPositiveLuminanceExact(input: []const f64, output: []f64) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < input.len) : (index += 3) {
        const luminance = pixelLuminance(input[index], input[index + 1], input[index + 2]);
        if (luminance > 0.001) {
            output[count] = luminance;
            count += 1;
        }
    }
    return count;
}

fn collectPositiveLuminanceExactF32(input: []const f32, output: []f64) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < input.len) : (index += 3) {
        const luminance = pixelLuminance(@floatCast(input[index]), @floatCast(input[index + 1]), @floatCast(input[index + 2]));
        if (luminance > 0.001) {
            output[count] = luminance;
            count += 1;
        }
    }
    return count;
}

fn collectPositiveLuminanceSampled(input: []const f64, output: []f32, sample_count: usize) usize {
    const pixel_count = input.len / 3;
    var count: usize = 0;
    for (0..sample_count) |sample_index| {
        const pixel_index = stratifiedPixelIndex(pixel_count, sample_count, sample_index);
        const index = pixel_index * 3;
        const luminance = pixelLuminance(input[index], input[index + 1], input[index + 2]);
        if (luminance > 0.001) {
            output[count] = @floatCast(luminance);
            count += 1;
        }
    }
    return count;
}

fn collectPositiveLuminanceSampledF32(input: []const f32, output: []f32, sample_count: usize) usize {
    const pixel_count = input.len / 3;
    var count: usize = 0;
    for (0..sample_count) |sample_index| {
        const pixel_index = stratifiedPixelIndex(pixel_count, sample_count, sample_index);
        const index = pixel_index * 3;
        const luminance = pixelLuminance(@floatCast(input[index]), @floatCast(input[index + 1]), @floatCast(input[index + 2]));
        if (luminance > 0.001) {
            output[count] = @floatCast(luminance);
            count += 1;
        }
    }
    return count;
}

fn stratifiedPixelIndex(pixel_count: usize, sample_count: usize, sample_index: usize) usize {
    const start: usize = @intCast((@as(u128, sample_index) * @as(u128, pixel_count)) / @as(u128, sample_count));
    const end: usize = @intCast((@as(u128, sample_index + 1) * @as(u128, pixel_count)) / @as(u128, sample_count));
    const width = @max(end - start, 1);
    const offset: usize = @intCast(splitmix64(@intCast(sample_index)) % @as(u64, @intCast(width)));
    return @min(start + offset, pixel_count - 1);
}

fn splitmix64(seed: u64) u64 {
    var value = seed +% 0x9E3779B97F4A7C15;
    value = (value ^ (value >> 30)) *% 0xBF58476D1CE4E5B9;
    value = (value ^ (value >> 27)) *% 0x94D049BB133111EB;
    return value ^ (value >> 31);
}

fn pixelLuminance(r: f64, g: f64, b: f64) f64 {
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

fn percentileSorted(values: []const f64, percentile: f64) f64 {
    const rank = (@as(f64, @floatFromInt(values.len - 1)) * percentile) / 100.0;
    const lower: usize = @intFromFloat(@floor(rank));
    const upper: usize = @intFromFloat(@ceil(rank));
    const fraction = rank - @as(f64, @floatFromInt(lower));
    return values[lower] * (1.0 - fraction) + values[upper] * fraction;
}

fn percentileSortedF32(values: []const f32, percentile: f64) f64 {
    const rank = (@as(f64, @floatFromInt(values.len - 1)) * percentile) / 100.0;
    const lower: usize = @intFromFloat(@floor(rank));
    const upper: usize = @intFromFloat(@ceil(rank));
    const fraction = rank - @as(f64, @floatFromInt(lower));
    const lower_value: f64 = @floatCast(values[lower]);
    const upper_value: f64 = @floatCast(values[upper]);
    return lower_value * (1.0 - fraction) + upper_value * fraction;
}

fn lessThanF64(_: void, lhs: f64, rhs: f64) bool {
    return lhs < rhs;
}

fn lessThanF32(_: void, lhs: f32, rhs: f32) bool {
    return lhs < rhs;
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

const fixture_adjusted_options = RenderToDisplayOptions{
    .contrast = 1.25,
    .percentile_lo = 5.0,
    .percentile_hi = 95.0,
    .exposure_compensation = 0.35,
    .color_temp = 0.4,
    .color_tint = -0.25,
};

test "render to display baseline matches its regression fixture" {
    try expectRenderDisplayFixture("test/fixtures/processing/numeric/render-to-display-baseline.json", .{
        .percentile_lo = 10.0,
        .percentile_hi = 90.0,
    });
}

test "render to display adjustments match their regression fixture" {
    try expectRenderDisplayFixture("test/fixtures/processing/numeric/render-to-display-adjusted.json", fixture_adjusted_options);
}

test "render to display handles no positive luminance" {
    try expectRenderDisplayFixture("test/fixtures/processing/numeric/render-to-display-no-positive-luminance.json", .{});
}

test "render to display validates buffers and options" {
    var out: [3]u16 = undefined;
    const allocator = std.testing.allocator;
    const rgb = [_]f64{ 0.1, 0.2, 0.3 };
    try std.testing.expectError(error.InvalidRenderBuffer, renderToDisplay(allocator, &.{ 0.1, 0.2 }, &out, .{}));
    try std.testing.expectError(error.InvalidRenderPercentile, renderToDisplay(allocator, &rgb, &out, .{ .percentile_lo = -1.0 }));
    try std.testing.expectError(error.InvalidRenderContrast, renderToDisplay(allocator, &rgb, &out, .{ .contrast = 0.0 }));
    try std.testing.expectError(error.InvalidRenderFilmCurve, renderToDisplay(allocator, &rgb, &out, .{ .film_gamma = 0.0 }));
    try std.testing.expectError(error.InvalidRenderCrosstalk, renderToDisplay(allocator, &rgb, &out, .{ .dye_crosstalk = 0.95 }));
    try std.testing.expectError(error.InvalidRenderWhiteBalance, renderToDisplay(allocator, &rgb, &out, .{ .auto_white_balance = 1.5 }));
}

fn greyRamp(comptime count: usize, red_scale: f64, red_offset: f64, blue_scale: f64, blue_offset: f64) [count * 3]f64 {
    var rgb: [count * 3]f64 = undefined;
    for (0..count) |pixel| {
        const density = 0.05 + 1.2 * @as(f64, @floatFromInt(pixel)) / @as(f64, @floatFromInt(count - 1));
        rgb[pixel * 3] = red_scale * density + red_offset;
        rgb[pixel * 3 + 1] = density;
        rgb[pixel * 3 + 2] = blue_scale * density + blue_offset;
    }
    return rgb;
}

fn maxChannelSpread(rgb: []const u16) u16 {
    var spread: u16 = 0;
    var index: usize = 0;
    while (index < rgb.len) : (index += 3) {
        const lo = @min(rgb[index], @min(rgb[index + 1], rgb[index + 2]));
        const hi = @max(rgb[index], @max(rgb[index + 1], rgb[index + 2]));
        spread = @max(spread, hi - lo);
    }
    return spread;
}

test "a neutral density ramp renders neutral" {
    const rgb = greyRamp(64, 1.0, 0.0, 1.0, 0.0);
    var out: [rgb.len]u16 = undefined;
    try renderToDisplay(std.testing.allocator, &rgb, &out, .{});
    try std.testing.expectEqual(@as(u16, 0), maxChannelSpread(&out));
}

test "automatic white balance removes a per-channel density scale and offset" {
    // Red at a lower contrast and blue at a higher one than green, each with
    // its own offset: what the scanner and the light do to a grey scene.
    const rgb = greyRamp(256, 0.77, 0.03, 1.22, -0.02);
    var balanced: [rgb.len]u16 = undefined;
    var unbalanced: [rgb.len]u16 = undefined;
    try renderToDisplay(std.testing.allocator, &rgb, &balanced, .{ .percentile_lo = 0.0, .percentile_hi = 100.0 });
    try renderToDisplay(std.testing.allocator, &rgb, &unbalanced, .{ .percentile_lo = 0.0, .percentile_hi = 100.0, .auto_white_balance = 0.0 });
    try std.testing.expect(maxChannelSpread(&balanced) <= 2);
    try std.testing.expect(maxChannelSpread(&unbalanced) > 2000);
}

test "automatic exposure renders a uniform grey at 18 percent and compensation in stops" {
    var rgb: [12]f64 = undefined;
    @memset(&rgb, 0.6);
    var out: [12]u16 = undefined;
    try renderToDisplay(std.testing.allocator, &rgb, &out, .{});
    const grey = displayToU16(color.linearToSrgbValue(mid_grey));
    for (out) |sample| try std.testing.expect(@abs(@as(i32, sample) - @as(i32, grey)) <= 1);

    try renderToDisplay(std.testing.allocator, &rgb, &out, .{ .exposure_compensation = 1.0 });
    const brighter = displayToU16(displayCurve(2.0 * mid_grey, 1.8));
    for (out) |sample| try std.testing.expect(@abs(@as(i32, sample) - @as(i32, brighter)) <= 1);
}

test "crosstalk grows colour differences in log exposure by one over one minus it" {
    const transform = try std.testing.allocator.create(DisplayTransform);
    defer std.testing.allocator.destroy(transform);
    var neutral = [_]f64{ 0.5, 0.5, 0.5 };
    try buildDisplayTransform(f64, std.testing.allocator, &neutral, .{ .dye_crosstalk = 0.0 }, transform);
    const pixel = [3]f64{ 0.9, 0.6, 0.4 };
    const plain = displayLogExposure(transform, pixel);
    transform.chroma_gain = 1.0 / (1.0 - 0.2);
    const unmixed = displayLogExposure(transform, pixel);
    const mean = (plain[0] + plain[1] + plain[2]) / 3.0;
    for (plain, unmixed) |before, after| {
        try std.testing.expectApproxEqAbs((before - mean) / 0.8, after - mean, 1e-12);
    }
    // Far above the toe the curve is a straight line of slope gamma.
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), filmLogExposure(1.1, transform.inv_gamma_toe, transform.toe), 1e-3);
}

test "a frame's colour is measured inside it, not on the film border" {
    // A 200x100 neutral ramp with a strongly coloured 2 px border all round.
    const width = 200;
    const height = 100;
    var rgb: [width * height * 3]f64 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const index = (y * width + x) * 3;
            const density = 0.05 + 1.2 * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(width - 1));
            const border = x < 2 or y < 2 or x >= width - 2 or y >= height - 2;
            rgb[index] = if (border) 2.5 else density;
            rgb[index + 1] = if (border) 0.01 else density;
            rgb[index + 2] = if (border) 0.01 else density;
        }
    }
    var whole: [rgb.len]u16 = undefined;
    var framed: [rgb.len]u16 = undefined;
    try renderToDisplay(std.testing.allocator, &rgb, &whole, .{ .percentile_lo = 0.0, .percentile_hi = 100.0 });
    try renderToDisplay(std.testing.allocator, &rgb, &framed, .{ .percentile_lo = 0.0, .percentile_hi = 100.0, .frame_width = width });
    // Inside the border the measured frame stays neutral; measured whole, the
    // border's red tilts it.
    const inner_spread = struct {
        fn of(out: []const u16) u16 {
            var spread: u16 = 0;
            for (2..height - 2) |y| spread = @max(spread, maxChannelSpread(out[(y * width + 2) * 3 .. (y * width + width - 2) * 3]));
            return spread;
        }
    }.of;
    try std.testing.expect(inner_spread(&framed) <= 2);
    try std.testing.expect(inner_spread(&whole) > 2000);
}

test "the curve table follows the exact curve inversion" {
    const transform = try std.testing.allocator.create(DisplayTransform);
    defer std.testing.allocator.destroy(transform);
    var rgb = [_]f64{ 0.1, 0.5, 0.9 };
    try buildDisplayTransform(f64, std.testing.allocator, &rgb, .{}, transform);
    var density: f64 = 0.0;
    while (density < 4.5) : (density += 0.0003) {
        const exact = filmLogExposure(density, transform.inv_gamma_toe, transform.toe);
        try std.testing.expectApproxEqAbs(exact, curveLookup(transform, density), 1e-4);
    }
    // Below the main table, density by density ratio down past the floor,
    // and at and below zero.
    try std.testing.expectEqual(lowCurveCellDensity(low_curve_entries - 1), curve_table_lo);
    density = curve_table_lo;
    while (density > 1e-12) : (density *= 0.9993) {
        const exact = filmLogExposure(density, transform.inv_gamma_toe, transform.toe);
        try std.testing.expectApproxEqAbs(exact, curveLookup(transform, density), 2e-6);
    }
    const just_below = std.math.nextAfter(f64, curve_table_lo, 0.0);
    try std.testing.expectApproxEqAbs(filmLogExposure(just_below, transform.inv_gamma_toe, transform.toe), curveLookup(transform, just_below), 2e-6);
    for ([_]f64{ 0.0, -0.0, -0.3, -50.0 }) |below| {
        const floor_value = filmLogExposure(below, transform.inv_gamma_toe, transform.toe);
        try std.testing.expectApproxEqAbs(floor_value, curveLookup(transform, below), 2e-6);
    }
}

test "render paths agree: u8 is the u16 output shifted, f32 within one level" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/render-to-display-adjusted.json");
    defer fixture.deinit();
    const value = fixture.value();

    const expected_u16 = try allocator.alloc(u16, value.expected.len);
    defer allocator.free(expected_u16);
    try renderToDisplay(allocator, value.input, expected_u16, fixture_adjusted_options);

    const preview = try allocator.alloc(u8, value.expected.len);
    defer allocator.free(preview);
    try renderToDisplayU8(allocator, value.input, preview, fixture_adjusted_options);
    for (expected_u16, preview) |sample, byte| try std.testing.expectEqual(@as(u8, @intCast(sample >> 8)), byte);

    const input_f32 = try allocator.alloc(f32, value.input.len);
    defer allocator.free(input_f32);
    for (value.input, input_f32) |sample, *out| out.* = @floatCast(sample);
    const from_f32 = try allocator.alloc(u16, value.expected.len);
    defer allocator.free(from_f32);
    try renderToDisplayU16F32(allocator, input_f32, from_f32, fixture_adjusted_options);
    for (expected_u16, from_f32) |a, b| try std.testing.expect(@abs(@as(i32, a) - @as(i32, b)) <= 1);
}
