const std = @import("std");

const color = @import("color.zig");
const numeric = @import("numeric_fixture.zig");
const parallelism = @import("parallelism.zig");

pub const exact_percentile_sample_limit: usize = 0;
pub const default_percentile_sample_limit: usize = 16_384;
pub const preview_display_lut_entries: usize = 256;
pub const export_display_lut_entries: usize = 1024;
const render_u8_f32_parallel_min_pixels: usize = 1_000_000;

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
    percentile_sample_limit: usize = default_percentile_sample_limit,
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

    const state = try displayRenderState(allocator, input, options);
    if (shouldUseExactDisplayCurve(input, options)) {
        for (input, output, 0..) |value, *out, index| {
            out.* = displayToU16(displayUnitValue(value, index, state));
        }
        return;
    }
    renderToDisplayU16Lut(input, output, state);
}

pub fn renderToDisplayU8(
    allocator: std.mem.Allocator,
    input: []const f64,
    output: []u8,
    options: RenderToDisplayOptions,
) !void {
    try validateRgbInput(input);
    if (input.len != output.len) return error.InvalidRenderBuffer;
    try validatePercentile(options.percentile_lo);
    try validatePercentile(options.percentile_hi);

    const state = try displayRenderState(allocator, input, options);
    if (shouldUseExactDisplayCurve(input, options)) {
        for (input, output, 0..) |value, *out, index| {
            out.* = @intCast(displayToU16(displayUnitValue(value, index, state)) >> 8);
        }
        return;
    }
    renderToDisplayU8Lut(input, output, state);
}

pub fn renderToDisplayU8F32(
    allocator: std.mem.Allocator,
    input: []const f32,
    output: []u8,
    options: RenderToDisplayOptions,
) !void {
    try validateRgbInputF32(input);
    if (input.len != output.len) return error.InvalidRenderBuffer;
    try validatePercentile(options.percentile_lo);
    try validatePercentile(options.percentile_hi);

    const state = try displayRenderStateF32(allocator, input, options);
    if (shouldUseExactDisplayCurveF32(input, options)) {
        for (input, output, 0..) |value, *out, index| {
            out.* = @intCast(displayToU16(displayUnitValue(@floatCast(value), index, state)) >> 8);
        }
        return;
    }
    try renderToDisplayU8LutF32(allocator, input, output, state);
}

pub fn renderToDisplayU16F32(
    allocator: std.mem.Allocator,
    input: []const f32,
    output: []u16,
    options: RenderToDisplayOptions,
) !void {
    try validateRgbInputF32(input);
    if (input.len != output.len) return error.InvalidRenderBuffer;
    try validatePercentile(options.percentile_lo);
    try validatePercentile(options.percentile_hi);

    const state = try displayRenderStateF32(allocator, input, options);
    if (shouldUseExactDisplayCurveF32(input, options)) {
        for (input, output, 0..) |value, *out, index| {
            out.* = displayToU16(displayUnitValue(@floatCast(value), index, state));
        }
        return;
    }
    renderToDisplayU16LutF32(input, output, state);
}

const DisplayRenderState = struct {
    range: LuminanceRange,
    denominator: f64,
    multipliers: [3]f64,
    apply_color_balance: bool,
    apply_exposure: bool,
    exposure_gamma: f64,
    apply_contrast: bool,
    contrast_k: f64,
    curve: ContrastCurveConstants,
};

fn displayRenderState(
    allocator: std.mem.Allocator,
    input: []const f64,
    options: RenderToDisplayOptions,
) !DisplayRenderState {
    const range = try estimateDisplayLuminanceRange(allocator, input, options);

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
    return .{
        .range = range,
        .denominator = range.hi - range.lo,
        .multipliers = multipliers,
        .apply_color_balance = apply_color_balance,
        .apply_exposure = apply_exposure,
        .exposure_gamma = exposure_gamma,
        .apply_contrast = apply_contrast,
        .contrast_k = contrast_k,
        .curve = curve,
    };
}

fn displayRenderStateF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    options: RenderToDisplayOptions,
) !DisplayRenderState {
    const range = try estimateDisplayLuminanceRangeF32(allocator, input, options);

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
    return .{
        .range = range,
        .denominator = range.hi - range.lo,
        .multipliers = multipliers,
        .apply_color_balance = apply_color_balance,
        .apply_exposure = apply_exposure,
        .exposure_gamma = exposure_gamma,
        .apply_contrast = apply_contrast,
        .contrast_k = contrast_k,
        .curve = curve,
    };
}

fn displayUnitValue(value: f64, index: usize, state: DisplayRenderState) f64 {
    const display = normalizedDisplayValue(value, state);
    return displayCurveValue(display, index % 3, state);
}

fn normalizedDisplayValue(value: f64, state: DisplayRenderState) f64 {
    return clamp((value - state.range.lo) / state.denominator, 0.0, 1.0);
}

fn displayCurveValue(input: f64, channel: usize, state: DisplayRenderState) f64 {
    var display = input;
    if (state.apply_color_balance) {
        display = @max(display * state.multipliers[channel], 0.0);
    }
    if (state.apply_exposure) {
        display = std.math.pow(f64, display, state.exposure_gamma);
    }
    if (state.apply_contrast) {
        const raw = logistic(state.contrast_k, display);
        display = (raw - state.curve.lo) / (state.curve.hi - state.curve.lo);
    }
    return clamp(display, 0.0, 1.0);
}

fn shouldUseExactDisplayCurve(input: []const f64, options: RenderToDisplayOptions) bool {
    const pixel_count = input.len / 3;
    return percentileSampleCount(pixel_count, options.percentile_sample_limit) == pixel_count;
}

fn shouldUseExactDisplayCurveF32(input: []const f32, options: RenderToDisplayOptions) bool {
    const pixel_count = input.len / 3;
    return percentileSampleCount(pixel_count, options.percentile_sample_limit) == pixel_count;
}

fn renderToDisplayU8Lut(input: []const f64, output: []u8, state: DisplayRenderState) void {
    var table: [3][preview_display_lut_entries]u8 = undefined;
    fillDisplayLutU8(&table, state);
    const scale = @as(f64, @floatFromInt(preview_display_lut_entries - 1));
    var index: usize = 0;
    while (index < input.len) : (index += 3) {
        output[index] = previewDisplayTableLookupF64(input[index], &table[0], state, scale);
        output[index + 1] = previewDisplayTableLookupF64(input[index + 1], &table[1], state, scale);
        output[index + 2] = previewDisplayTableLookupF64(input[index + 2], &table[2], state, scale);
    }
}

fn renderToDisplayU8LutF32(allocator: std.mem.Allocator, input: []const f32, output: []u8, state: DisplayRenderState) !void {
    var table: [3][preview_display_lut_entries]u8 = undefined;
    fillDisplayLutU8(&table, state);
    const lookup = PreviewDisplayF32LookupState{
        .lo = @floatCast(state.range.lo),
        .inv_denominator = @floatCast(1.0 / state.denominator),
        .scale = @floatFromInt(preview_display_lut_entries - 1),
    };
    const pixel_count = input.len / 3;
    if (comptime !parallelism.enabled) {
        renderToDisplayU8LutF32Range(input, output, &table, lookup, 0, pixel_count);
        return;
    }
    const worker_count = workerCountForPixels(pixel_count, render_u8_f32_parallel_min_pixels);
    if (worker_count > 1) {
        try renderToDisplayU8LutF32Parallel(allocator, input, output, &table, lookup, worker_count);
    } else {
        renderToDisplayU8LutF32Range(input, output, &table, lookup, 0, pixel_count);
    }
}

const RenderU8F32RangeContext = struct {
    input: []const f32,
    output: []u8,
    table: *const [3][preview_display_lut_entries]u8,
    lookup: PreviewDisplayF32LookupState,
    pixel_start: usize,
    pixel_end: usize,
};

fn renderToDisplayU8LutF32Parallel(
    allocator: std.mem.Allocator,
    input: []const f32,
    output: []u8,
    table: *const [3][preview_display_lut_entries]u8,
    lookup: PreviewDisplayF32LookupState,
    worker_count: usize,
) !void {
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(RenderU8F32RangeContext, worker_count);
    defer allocator.free(contexts);
    const pixel_count = input.len / 3;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (0..worker_count) |worker_index| {
        contexts[worker_index] = .{
            .input = input,
            .output = output,
            .table = table,
            .lookup = lookup,
            .pixel_start = pixel_count * worker_index / worker_count,
            .pixel_end = pixel_count * (worker_index + 1) / worker_count,
        };
        threads[worker_index] = try std.Thread.spawn(.{}, renderToDisplayU8LutF32Worker, .{&contexts[worker_index]});
        started += 1;
    }
    for (threads) |thread| thread.join();
}

fn renderToDisplayU8LutF32Worker(context: *const RenderU8F32RangeContext) void {
    renderToDisplayU8LutF32Range(context.input, context.output, context.table, context.lookup, context.pixel_start, context.pixel_end);
}

fn renderToDisplayU8LutF32Range(
    input: []const f32,
    output: []u8,
    table: *const [3][preview_display_lut_entries]u8,
    lookup: PreviewDisplayF32LookupState,
    pixel_start: usize,
    pixel_end: usize,
) void {
    var pixel_index = pixel_start;
    while (pixel_index < pixel_end) : (pixel_index += 1) {
        const index = pixel_index * 3;
        output[index] = previewDisplayTableLookupF32(input[index], &table[0], lookup);
        output[index + 1] = previewDisplayTableLookupF32(input[index + 1], &table[1], lookup);
        output[index + 2] = previewDisplayTableLookupF32(input[index + 2], &table[2], lookup);
    }
}

fn workerCountForPixels(pixel_count: usize, min_pixels: usize) usize {
    if (pixel_count < min_pixels) return 1;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    if (cpu_count <= 1) return 1;
    return @min(cpu_count - 1, pixel_count / min_pixels);
}

inline fn previewDisplayTableLookupF64(
    value: f64,
    table: *const [preview_display_lut_entries]u8,
    state: DisplayRenderState,
    scale: f64,
) u8 {
    const normalized = normalizedDisplayValue(value, state);
    const table_index: usize = @intFromFloat(@round(normalized * scale));
    return table.*[@min(table_index, preview_display_lut_entries - 1)];
}

inline fn previewDisplayTableLookupF32(
    value: f32,
    table: *const [preview_display_lut_entries]u8,
    state: PreviewDisplayF32LookupState,
) u8 {
    const normalized = @min(@max((value - state.lo) * state.inv_denominator, 0.0), 1.0);
    const table_index: usize = @intFromFloat(@round(normalized * state.scale));
    return table.*[@min(table_index, preview_display_lut_entries - 1)];
}

const PreviewDisplayF32LookupState = struct {
    lo: f32,
    inv_denominator: f32,
    scale: f32,
};

fn renderToDisplayU16Lut(input: []const f64, output: []u16, state: DisplayRenderState) void {
    var table: [3][export_display_lut_entries]f32 = undefined;
    fillDisplayLutF32(&table, state);
    const scale = @as(f64, @floatFromInt(export_display_lut_entries - 1));
    for (input, output, 0..) |value, *out, index| {
        const normalized = normalizedDisplayValue(value, state);
        const position = normalized * scale;
        const lower: usize = @intFromFloat(@floor(position));
        const upper = @min(lower + 1, export_display_lut_entries - 1);
        const fraction = position - @as(f64, @floatFromInt(lower));
        const channel = index % 3;
        const lo: f64 = @floatCast(table[channel][lower]);
        const hi: f64 = @floatCast(table[channel][upper]);
        out.* = displayToU16(lo * (1.0 - fraction) + hi * fraction);
    }
}

fn renderToDisplayU16LutF32(input: []const f32, output: []u16, state: DisplayRenderState) void {
    var table: [3][export_display_lut_entries]f32 = undefined;
    fillDisplayLutF32(&table, state);
    const lookup = ExportDisplayF32LookupState{
        .lo = @floatCast(state.range.lo),
        .inv_denominator = @floatCast(1.0 / state.denominator),
        .scale = @floatFromInt(export_display_lut_entries - 1),
    };
    var index: usize = 0;
    while (index < input.len) : (index += 3) {
        output[index] = exportDisplayTableLookupF32(input[index], &table[0], lookup);
        output[index + 1] = exportDisplayTableLookupF32(input[index + 1], &table[1], lookup);
        output[index + 2] = exportDisplayTableLookupF32(input[index + 2], &table[2], lookup);
    }
}

const ExportDisplayF32LookupState = struct {
    lo: f32,
    inv_denominator: f32,
    scale: f32,
};

inline fn exportDisplayTableLookupF32(
    value: f32,
    table: *const [export_display_lut_entries]f32,
    state: ExportDisplayF32LookupState,
) u16 {
    const normalized = @min(@max((value - state.lo) * state.inv_denominator, 0.0), 1.0);
    const position = normalized * state.scale;
    const lower: usize = @intFromFloat(@floor(position));
    const upper = @min(lower + 1, export_display_lut_entries - 1);
    const fraction = position - @as(f32, @floatFromInt(lower));
    const lo = table.*[lower];
    const hi = table.*[upper];
    return displayToU16(@floatCast(lo * (1.0 - fraction) + hi * fraction));
}

fn fillDisplayLutU8(table: *[3][preview_display_lut_entries]u8, state: DisplayRenderState) void {
    const denominator = @as(f64, @floatFromInt(preview_display_lut_entries - 1));
    for (0..3) |channel| {
        for (&table[channel], 0..) |*entry, index| {
            const input = @as(f64, @floatFromInt(index)) / denominator;
            entry.* = @intCast(displayToU16(displayCurveValue(input, channel, state)) >> 8);
        }
    }
}

fn fillDisplayLutF32(table: *[3][export_display_lut_entries]f32, state: DisplayRenderState) void {
    const denominator = @as(f64, @floatFromInt(export_display_lut_entries - 1));
    for (0..3) |channel| {
        for (&table[channel], 0..) |*entry, index| {
            const input = @as(f64, @floatFromInt(index)) / denominator;
            entry.* = @floatCast(displayCurveValue(input, channel, state));
        }
    }
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

test "render to display u8 matches shifted u16 preview output" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/render-to-display-adjusted.json");
    defer fixture.deinit();

    const value = fixture.value();
    const options = RenderToDisplayOptions{
        .contrast = 1.25,
        .black_point = 0.1,
        .curve_k = 4.0,
        .percentile_lo = 5.0,
        .percentile_hi = 95.0,
        .exposure_compensation = 0.35,
        .color_temp = 0.4,
        .color_tint = -0.25,
    };
    const expected_u16 = try allocator.alloc(u16, value.expected.len);
    defer allocator.free(expected_u16);
    try renderToDisplay(allocator, value.input, expected_u16, options);

    const actual = try allocator.alloc(u8, value.expected.len);
    defer allocator.free(actual);
    try renderToDisplayU8(allocator, value.input, actual, options);

    for (expected_u16, actual) |sample, preview| {
        try std.testing.expectEqual(@as(u8, @intCast(sample >> 8)), preview);
    }
}
