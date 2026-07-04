const std = @import("std");
const builtin = @import("builtin");

const numeric = @import("numeric_fixture.zig");
const ir_pure = @import("ir_pure.zig");

const use_native_ir_helpers = !builtin.cpu.arch.isWasm() and builtin.link_libc;

extern fn v600_align_ir_find_ecc_translation(
    rgb: [*]const f64,
    rgb_width: c_int,
    rgb_height: c_int,
    ir: [*]const f64,
    ir_width: c_int,
    ir_height: c_int,
    tx: *f64,
    ty: *f64,
) c_int;

// Matches the opencv_ecc.cpp constants so the pure-Zig fallback estimates the
// same translation shape as the native OpenCV helper.
const pure_ecc_scale: f64 = 0.125;
const pure_ecc_max_iterations: u32 = 200;
const pure_ecc_epsilon: f64 = 1.0e-6;

fn estimateTranslationEccPure(
    allocator: std.mem.Allocator,
    rgb: []const f64,
    rgb_width: usize,
    rgb_height: usize,
    ir: []const f64,
    ir_width: usize,
    ir_height: usize,
) !ir_pure.TranslationEstimate {
    const rgb_f32 = try allocator.alloc(f32, rgb.len);
    defer allocator.free(rgb_f32);
    for (rgb, rgb_f32) |value, *out| out.* = @floatCast(value);
    const ir_f32 = try allocator.alloc(f32, ir.len);
    defer allocator.free(ir_f32);
    for (ir, ir_f32) |value, *out| out.* = @floatCast(value);
    return ir_pure.estimateTranslationEccF32(
        allocator,
        rgb_f32,
        rgb_width,
        rgb_height,
        ir_f32,
        ir_width,
        ir_height,
        pure_ecc_scale,
        pure_ecc_max_iterations,
        pure_ecc_epsilon,
    );
}

extern fn v600_estimate_local_grain(
    roi_rgb: [*]const f64,
    roi_mask: [*]const u8,
    width: c_int,
    height: c_int,
    grain_padding: c_int,
    grain_std: [*]f64,
    signal_out: [*]f64,
    spectrum_out: [*]f64,
    spectrum_capacity: c_int,
    spectrum_len: *c_int,
    has_spectrum: *c_int,
) c_int;

extern fn v600_synthesize_grain_from_noise(
    noise: [*]const f64,
    width: c_int,
    height: c_int,
    grain_std: [*]const f64,
    grain_spectrum: ?[*]const f64,
    spectrum_len: c_int,
    channels: c_int,
    output: [*]f64,
) c_int;

extern fn v600_solve_sparse_lu(
    n: usize,
    row_offsets: [*]const usize,
    columns: [*]const usize,
    values: [*]const f64,
    nnz: usize,
    channels: usize,
    rhs: [*]const f64,
    output: [*]f64,
) c_int;

fn fallback_solve_sparse_lu(
    n: usize,
    row_offsets: [*]const usize,
    columns: [*]const usize,
    values: [*]const f64,
    nnz: usize,
    channels: usize,
    rhs: [*]const f64,
    output: [*]f64,
) c_int {
    _ = n;
    _ = row_offsets;
    _ = columns;
    _ = values;
    _ = nnz;
    _ = channels;
    _ = rhs;
    _ = output;
    return 1;
}

fn callSolveSparseLu(
    n: usize,
    row_offsets: [*]const usize,
    columns: [*]const usize,
    values: [*]const f64,
    nnz: usize,
    channels: usize,
    rhs: [*]const f64,
    output: [*]f64,
) c_int {
    if (use_native_ir_helpers) {
        return v600_solve_sparse_lu(n, row_offsets, columns, values, nnz, channels, rhs, output);
    }
    return fallback_solve_sparse_lu(n, row_offsets, columns, values, nnz, channels, rhs, output);
}

pub const AlignOptions = struct {
    max_offset: i32 = 8,
};

pub const AlignResult = struct {
    tx: f64,
    ty: f64,
    shifted: bool,
};

pub const AdaptiveDustPrecision = enum {
    f64,
    f32,
    f32_box3,
    f32_box4,
    f32_box6,
    f32_box8,
    f32_down2,
    f32_down3,
    f32_down4,
    f32_down6,
    f32_down8,
    f32_down4_coarse,
    f32_down4_final,
};

const gaussian_parallel_min_pixels_per_worker: usize = 1_000_000;
const gaussian_parallel_min_rows_per_worker: usize = 128;
const gaussian_simd_width: usize = 4;
const gaussian_simd_width_f32: usize = 8;
const GaussianVecF64 = @Vector(gaussian_simd_width, f64);
const GaussianVecF32 = @Vector(gaussian_simd_width_f32, f32);

const AdaptiveF32BlurMode = union(enum) {
    gaussian,
    box_cascade: usize,
    downsampled_gaussian: usize,
};

const AdaptiveF32BlurPlan = struct {
    coarse: AdaptiveF32BlurMode,
    final: AdaptiveF32BlurMode,
};

pub const ThresholdOptions = struct {
    threshold: f64 = 0.10,
    blur_size: usize = 301,
    precision: AdaptiveDustPrecision = .f32,
    worker_count: usize = 1,
};

pub const LineDetectionOptions = struct {
    threshold: f64 = 0.10,
    hair_sensitivity: f64 = 0.10,
    scale: f64 = 0.25,
    sigma_min: usize = 1,
    sigma_max: usize = 8,
};

pub const MorphologyOptions = struct {
    close_radius: usize = 6,
    dilate_radius: usize = 4,
};

pub const DefectMaskOptions = struct {
    threshold: f64 = 0.10,
    hair_sensitivity: f64 = 0.10,
    min_area: usize = 3,
    dilate_radius: usize = 4,
    close_radius: usize = 6,
    blur_size: usize = 301,
    max_coverage: f64 = 0.03,
    adaptive_precision: AdaptiveDustPrecision = .f32,
    adaptive_worker_count: usize = 1,
};

pub const LocalGrainEstimate = ir_pure.LocalGrainEstimate;

pub const InpaintValueKind = enum {
    float32,
    uint16,
};

pub const InpaintOptions = struct {
    padding: usize = 16,
    grain_padding: usize = 8,
    value_kind: InpaintValueKind = .uint16,
};

pub const IrCleanOptions = struct {
    defect_mask: DefectMaskOptions = .{},
    inpaint: InpaintOptions = .{},
};

pub const IrCleanResult = struct {
    defect_pixels_ir: usize,
    defect_pixels_rgb: usize,
    cleared_by_coverage: bool,
    inpainted_regions: usize,
};

pub const IrCleanTimings = struct {
    defect_mask_ns: u64 = 0,
    adaptive_dust_ns: u64 = 0,
    adaptive_norm_ns: u64 = 0,
    adaptive_background1_ns: u64 = 0,
    adaptive_square1_ns: u64 = 0,
    adaptive_blurred_square1_ns: u64 = 0,
    adaptive_coarse_ns: u64 = 0,
    adaptive_background2_ns: u64 = 0,
    adaptive_square2_ns: u64 = 0,
    adaptive_blurred_square2_ns: u64 = 0,
    adaptive_final_ns: u64 = 0,
    line_detection_ns: u64 = 0,
    line_resize_ns: u64 = 0,
    line_percentile_ns: u64 = 0,
    meijering_ns: u64 = 0,
    line_gate_ns: u64 = 0,
    close_ns: u64 = 0,
    component_filter_ns: u64 = 0,
    dilate_ns: u64 = 0,
    coverage_ns: u64 = 0,
    mask_resize_ns: u64 = 0,
    inpaint_total_ns: u64 = 0,
    inpaint_noise_ns: u64 = 0,
    inpaint_label_ns: u64 = 0,
    inpaint_roi_extract_ns: u64 = 0,
    local_grain_ns: u64 = 0,
    biharmonic_ns: u64 = 0,
    grain_synthesis_ns: u64 = 0,
    masked_writeback_ns: u64 = 0,

    pub fn add(self: *IrCleanTimings, other: IrCleanTimings) void {
        inline for (std.meta.fields(IrCleanTimings)) |field| {
            @field(self, field.name) += @field(other, field.name);
        }
    }
};

pub fn alignIr(
    allocator: std.mem.Allocator,
    rgb: []const f64,
    rgb_width: usize,
    rgb_height: usize,
    ir: []const f64,
    ir_width: usize,
    ir_height: usize,
    output: []f64,
    options: AlignOptions,
) !AlignResult {
    try validateAlignmentInputs(rgb, rgb_width, rgb_height, ir, ir_width, ir_height, output);
    if (options.max_offset < 0) return error.InvalidIrAlignmentOffset;

    if (rgb_width > @as(usize, @intCast(std.math.maxInt(c_int))) or
        rgb_height > @as(usize, @intCast(std.math.maxInt(c_int))) or
        ir_width > @as(usize, @intCast(std.math.maxInt(c_int))) or
        ir_height > @as(usize, @intCast(std.math.maxInt(c_int))))
    {
        return error.InvalidIrAlignmentBuffer;
    }

    var tx: f64 = 0.0;
    var ty: f64 = 0.0;
    if (use_native_ir_helpers) {
        const ecc_status = v600_align_ir_find_ecc_translation(
            rgb.ptr,
            @intCast(rgb_width),
            @intCast(rgb_height),
            ir.ptr,
            @intCast(ir_width),
            @intCast(ir_height),
            &tx,
            &ty,
        );
        if (ecc_status != 0) {
            @memcpy(output, ir);
            return .{ .tx = 0.0, .ty = 0.0, .shifted = false };
        }
    } else {
        const estimate = estimateTranslationEccPure(allocator, rgb, rgb_width, rgb_height, ir, ir_width, ir_height) catch {
            @memcpy(output, ir);
            return .{ .tx = 0.0, .ty = 0.0, .shifted = false };
        };
        tx = estimate.tx;
        ty = estimate.ty;
    }

    if (@abs(tx) < 0.5 and @abs(ty) < 0.5) {
        @memcpy(output, ir);
        return .{ .tx = tx, .ty = ty, .shifted = false };
    }

    applyTranslation(f64, ir, ir_width, ir_height, output, tx, ty);
    return .{
        .tx = tx,
        .ty = ty,
        .shifted = true,
    };
}

pub fn thresholdIrDefects(
    allocator: std.mem.Allocator,
    ir: []const f64,
    width: usize,
    height: usize,
    output: []u8,
    options: ThresholdOptions,
) !void {
    if (width == 0 or height == 0 or ir.len != width * height or output.len != ir.len) {
        return error.InvalidIrThresholdBuffer;
    }
    if (options.blur_size == 0 or options.blur_size % 2 == 0) return error.InvalidIrThresholdBlur;
    if (!std.math.isFinite(options.threshold) or options.threshold <= 0.0) return error.InvalidIrThresholdValue;

    const n_sigma2 = try allocator.alloc(f64, ir.len);
    defer allocator.free(n_sigma2);
    try adaptiveDustMaskAndSigma(allocator, ir, width, height, output, n_sigma2, options, null);
}

pub fn makeDefectMask(
    allocator: std.mem.Allocator,
    ir: []const f64,
    width: usize,
    height: usize,
    output: []u8,
    options: DefectMaskOptions,
) !bool {
    return makeDefectMaskTimed(allocator, ir, width, height, output, options, null);
}

pub fn makeDefectMaskTimed(
    allocator: std.mem.Allocator,
    ir: []const f64,
    width: usize,
    height: usize,
    output: []u8,
    options: DefectMaskOptions,
    timings: ?*IrCleanTimings,
) !bool {
    return makeDefectMaskTimedWithLineBackend(allocator, ir, width, height, output, options, timings, false);
}

pub fn makeDefectMaskScalarLineReference(
    allocator: std.mem.Allocator,
    ir: []const f64,
    width: usize,
    height: usize,
    output: []u8,
    options: DefectMaskOptions,
    timings: ?*IrCleanTimings,
) !bool {
    return makeDefectMaskTimedWithLineBackend(allocator, ir, width, height, output, options, timings, true);
}

fn makeDefectMaskTimedWithLineBackend(
    allocator: std.mem.Allocator,
    ir: []const f64,
    width: usize,
    height: usize,
    output: []u8,
    options: DefectMaskOptions,
    timings: ?*IrCleanTimings,
    scalar_line: bool,
) !bool {
    if (width == 0 or height == 0 or ir.len != width * height or output.len != ir.len) {
        return error.InvalidIrDefectMaskBuffer;
    }
    if (options.blur_size == 0 or options.blur_size % 2 == 0) return error.InvalidIrThresholdBlur;
    if (!std.math.isFinite(options.threshold) or options.threshold <= 0.0) return error.InvalidIrThresholdValue;
    if (!std.math.isFinite(options.hair_sensitivity) or options.hair_sensitivity < 0.0) return error.InvalidIrLineOption;
    if (!std.math.isFinite(options.max_coverage) or options.max_coverage < 0.0) return error.InvalidIrCoverageValue;

    const n_sigma2 = try allocator.alloc(f64, ir.len);
    defer allocator.free(n_sigma2);
    const dust_mask = try allocator.alloc(u8, ir.len);
    defer allocator.free(dust_mask);
    const adaptive_started = monotonicNowNs();
    try adaptiveDustMaskAndSigma(allocator, ir, width, height, dust_mask, n_sigma2, .{
        .threshold = options.threshold,
        .blur_size = options.blur_size,
        .precision = options.adaptive_precision,
        .worker_count = options.adaptive_worker_count,
    }, timings);
    if (timings) |out| out.adaptive_dust_ns += monotonicNowNs() - adaptive_started;

    const line_mask = try allocator.alloc(u8, ir.len);
    defer allocator.free(line_mask);
    const line_started = monotonicNowNs();
    try detectLineDefectsTimedWithMeijering(allocator, n_sigma2, width, height, line_mask, .{
        .threshold = options.threshold,
        .hair_sensitivity = options.hair_sensitivity,
    }, timings, scalar_line);
    if (timings) |out| out.line_detection_ns += monotonicNowNs() - line_started;

    for (dust_mask, line_mask, output) |dust, line, *mask| {
        mask.* = if (dust != 0) 255 else line;
    }

    if (options.close_radius > 0) {
        const closed = try allocator.alloc(u8, output.len);
        defer allocator.free(closed);
        const close_started = monotonicNowNs();
        try applyMaskMorphology(allocator, output, width, height, closed, .{
            .close_radius = options.close_radius,
            .dilate_radius = 0,
        });
        @memcpy(output, closed);
        if (timings) |out| out.close_ns += monotonicNowNs() - close_started;
    }

    if (options.min_area > 0) {
        const filtered = try allocator.alloc(u8, output.len);
        defer allocator.free(filtered);
        const filter_started = monotonicNowNs();
        try filterSmallComponents(allocator, output, width, height, filtered, options.min_area);
        @memcpy(output, filtered);
        if (timings) |out| out.component_filter_ns += monotonicNowNs() - filter_started;
    }

    if (options.dilate_radius > 0) {
        const dilated = try allocator.alloc(u8, output.len);
        defer allocator.free(dilated);
        const dilate_started = monotonicNowNs();
        try applyMaskMorphology(allocator, output, width, height, dilated, .{
            .close_radius = 0,
            .dilate_radius = options.dilate_radius,
        });
        @memcpy(output, dilated);
        if (timings) |out| out.dilate_ns += monotonicNowNs() - dilate_started;
    }

    const coverage_started = monotonicNowNs();
    const coverage = @as(f64, @floatFromInt(countNonZeroMask(output))) / @as(f64, @floatFromInt(output.len));
    if (timings) |out| out.coverage_ns += monotonicNowNs() - coverage_started;
    if (coverage > options.max_coverage) {
        @memset(output, 0);
        return true;
    }
    return false;
}

fn adaptiveDustMaskAndSigma(
    allocator: std.mem.Allocator,
    ir: []const f64,
    width: usize,
    height: usize,
    dust_mask: []u8,
    n_sigma2_out: []f64,
    options: ThresholdOptions,
    timings: ?*IrCleanTimings,
) !void {
    return switch (options.precision) {
        .f64 => adaptiveDustMaskAndSigmaF64(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings),
        .f32 => adaptiveDustMaskAndSigmaF32(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings),
        .f32_box3 => adaptiveDustMaskAndSigmaF32WithBlur(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings, singleF32BlurPlan(.{ .box_cascade = 3 })),
        .f32_box4 => adaptiveDustMaskAndSigmaF32WithBlur(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings, singleF32BlurPlan(.{ .box_cascade = 4 })),
        .f32_box6 => adaptiveDustMaskAndSigmaF32WithBlur(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings, singleF32BlurPlan(.{ .box_cascade = 6 })),
        .f32_box8 => adaptiveDustMaskAndSigmaF32WithBlur(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings, singleF32BlurPlan(.{ .box_cascade = 8 })),
        .f32_down2 => adaptiveDustMaskAndSigmaF32WithBlur(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings, singleF32BlurPlan(.{ .downsampled_gaussian = 2 })),
        .f32_down3 => adaptiveDustMaskAndSigmaF32WithBlur(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings, singleF32BlurPlan(.{ .downsampled_gaussian = 3 })),
        .f32_down4 => adaptiveDustMaskAndSigmaF32WithBlur(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings, singleF32BlurPlan(.{ .downsampled_gaussian = 4 })),
        .f32_down6 => adaptiveDustMaskAndSigmaF32WithBlur(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings, singleF32BlurPlan(.{ .downsampled_gaussian = 6 })),
        .f32_down8 => adaptiveDustMaskAndSigmaF32WithBlur(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings, singleF32BlurPlan(.{ .downsampled_gaussian = 8 })),
        .f32_down4_coarse => adaptiveDustMaskAndSigmaF32WithBlur(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings, .{
            .coarse = .{ .downsampled_gaussian = 4 },
            .final = .gaussian,
        }),
        .f32_down4_final => adaptiveDustMaskAndSigmaF32WithBlur(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings, .{
            .coarse = .gaussian,
            .final = .{ .downsampled_gaussian = 4 },
        }),
    };
}

fn singleF32BlurPlan(mode: AdaptiveF32BlurMode) AdaptiveF32BlurPlan {
    return .{
        .coarse = mode,
        .final = mode,
    };
}

fn adaptiveDustMaskAndSigmaF64(
    allocator: std.mem.Allocator,
    ir: []const f64,
    width: usize,
    height: usize,
    dust_mask: []u8,
    n_sigma2_out: []f64,
    options: ThresholdOptions,
    timings: ?*IrCleanTimings,
) !void {
    if (ir.len != width * height or dust_mask.len != ir.len or n_sigma2_out.len != ir.len) {
        return error.InvalidIrThresholdBuffer;
    }

    const norm_started = monotonicNowNs();
    const ir_f = try allocator.alloc(f64, ir.len);
    defer allocator.free(ir_f);
    const ir_max = blk: {
        var max_value: f64 = 0.0;
        for (ir) |value| max_value = @max(max_value, value);
        break :blk if (max_value > 0.0) max_value else 1.0;
    };
    for (ir, ir_f) |value, *out| {
        out.* = value / ir_max;
    }
    if (timings) |out| out.adaptive_norm_ns += monotonicNowNs() - norm_started;

    const background_started = monotonicNowNs();
    const background = try gaussianBlur(allocator, ir_f, width, height, options.blur_size, options.worker_count);
    defer allocator.free(background);
    if (timings) |out| out.adaptive_background1_ns += monotonicNowNs() - background_started;

    const square_started = monotonicNowNs();
    const ir_sq = try allocator.alloc(f64, ir.len);
    defer allocator.free(ir_sq);
    for (ir_f, ir_sq) |value, *out| {
        out.* = value * value;
    }
    if (timings) |out| out.adaptive_square1_ns += monotonicNowNs() - square_started;

    const blurred_sq_started = monotonicNowNs();
    const blurred_sq = try gaussianBlur(allocator, ir_sq, width, height, options.blur_size, options.worker_count);
    defer allocator.free(blurred_sq);
    if (timings) |out| out.adaptive_blurred_square1_ns += monotonicNowNs() - blurred_sq_started;

    const coarse_started = monotonicNowNs();
    const ir_cleaned = try allocator.alloc(f64, ir.len);
    defer allocator.free(ir_cleaned);
    const sigma_threshold = 2.5 / options.threshold;
    for (ir_f, background, blurred_sq, ir_cleaned) |ir_value, bg, sq, *cleaned| {
        const local_std = @sqrt(@max(sq - bg * bg, 0.0));
        const deficit = bg - ir_value;
        const n_sigma = if (local_std > 1e-4) deficit / local_std else 0.0;
        const ratio = if (bg > 0.01) ir_value / bg else 1.0;
        cleaned.* = if (n_sigma > sigma_threshold and ratio < (1.0 - options.threshold * 0.7)) bg else ir_value;
    }
    if (timings) |out| out.adaptive_coarse_ns += monotonicNowNs() - coarse_started;

    const background2_started = monotonicNowNs();
    const background2 = try gaussianBlur(allocator, ir_cleaned, width, height, options.blur_size, options.worker_count);
    defer allocator.free(background2);
    if (timings) |out| out.adaptive_background2_ns += monotonicNowNs() - background2_started;

    const square2_started = monotonicNowNs();
    for (ir_cleaned, ir_sq) |value, *out| {
        out.* = value * value;
    }
    if (timings) |out| out.adaptive_square2_ns += monotonicNowNs() - square2_started;

    const blurred_sq2_started = monotonicNowNs();
    const blurred_sq2 = try gaussianBlur(allocator, ir_sq, width, height, options.blur_size, options.worker_count);
    defer allocator.free(blurred_sq2);
    if (timings) |out| out.adaptive_blurred_square2_ns += monotonicNowNs() - blurred_sq2_started;

    const final_started = monotonicNowNs();
    for (ir_f, background2, blurred_sq2, dust_mask, n_sigma2_out) |ir_value, bg, sq, *mask, *sigma_out| {
        const local_std = @sqrt(@max(sq - bg * bg, 0.0));
        const deficit = bg - ir_value;
        const n_sigma = if (local_std > 1e-4) deficit / local_std else 0.0;
        const ratio = if (bg > 0.01) ir_value / bg else 1.0;
        sigma_out.* = n_sigma;
        mask.* = if (n_sigma > sigma_threshold and ratio < (1.0 - options.threshold * 0.7)) 255 else 0;
    }
    if (timings) |out| out.adaptive_final_ns += monotonicNowNs() - final_started;
}

fn adaptiveDustMaskAndSigmaF32(
    allocator: std.mem.Allocator,
    ir: []const f64,
    width: usize,
    height: usize,
    dust_mask: []u8,
    n_sigma2_out: []f64,
    options: ThresholdOptions,
    timings: ?*IrCleanTimings,
) !void {
    try adaptiveDustMaskAndSigmaF32WithBlur(allocator, ir, width, height, dust_mask, n_sigma2_out, options, timings, singleF32BlurPlan(.gaussian));
}

fn adaptiveDustMaskAndSigmaF32WithBlur(
    allocator: std.mem.Allocator,
    ir: []const f64,
    width: usize,
    height: usize,
    dust_mask: []u8,
    n_sigma2_out: []f64,
    options: ThresholdOptions,
    timings: ?*IrCleanTimings,
    blur_plan: AdaptiveF32BlurPlan,
) !void {
    if (ir.len != width * height or dust_mask.len != ir.len or n_sigma2_out.len != ir.len) {
        return error.InvalidIrThresholdBuffer;
    }

    const norm_started = monotonicNowNs();
    const ir_f = try allocator.alloc(f32, ir.len);
    defer allocator.free(ir_f);
    const ir_max = blk: {
        var max_value: f64 = 0.0;
        for (ir) |value| max_value = @max(max_value, value);
        break :blk if (max_value > 0.0) max_value else 1.0;
    };
    for (ir, ir_f) |value, *out| {
        out.* = @floatCast(value / ir_max);
    }
    if (timings) |out| out.adaptive_norm_ns += monotonicNowNs() - norm_started;

    const background_started = monotonicNowNs();
    const background = try adaptiveBlurF32(allocator, ir_f, width, height, options.blur_size, options.worker_count, blur_plan.coarse);
    defer allocator.free(background);
    if (timings) |out| out.adaptive_background1_ns += monotonicNowNs() - background_started;

    const square_started = monotonicNowNs();
    const ir_sq = try allocator.alloc(f32, ir.len);
    defer allocator.free(ir_sq);
    for (ir_f, ir_sq) |value, *out| {
        out.* = value * value;
    }
    if (timings) |out| out.adaptive_square1_ns += monotonicNowNs() - square_started;

    const blurred_sq_started = monotonicNowNs();
    const blurred_sq = try adaptiveBlurF32(allocator, ir_sq, width, height, options.blur_size, options.worker_count, blur_plan.coarse);
    defer allocator.free(blurred_sq);
    if (timings) |out| out.adaptive_blurred_square1_ns += monotonicNowNs() - blurred_sq_started;

    const coarse_started = monotonicNowNs();
    const ir_cleaned = try allocator.alloc(f32, ir.len);
    defer allocator.free(ir_cleaned);
    const sigma_threshold: f32 = @floatCast(2.5 / options.threshold);
    const ratio_threshold: f32 = @floatCast(1.0 - options.threshold * 0.7);
    for (ir_f, background, blurred_sq, ir_cleaned) |ir_value, bg, sq, *cleaned| {
        const local_std = @sqrt(@max(sq - bg * bg, @as(f32, 0.0)));
        const deficit = bg - ir_value;
        const n_sigma = if (local_std > 1e-4) deficit / local_std else 0.0;
        const ratio = if (bg > 0.01) ir_value / bg else 1.0;
        cleaned.* = if (n_sigma > sigma_threshold and ratio < ratio_threshold) bg else ir_value;
    }
    if (timings) |out| out.adaptive_coarse_ns += monotonicNowNs() - coarse_started;

    const background2_started = monotonicNowNs();
    const background2 = try adaptiveBlurF32(allocator, ir_cleaned, width, height, options.blur_size, options.worker_count, blur_plan.final);
    defer allocator.free(background2);
    if (timings) |out| out.adaptive_background2_ns += monotonicNowNs() - background2_started;

    const square2_started = monotonicNowNs();
    for (ir_cleaned, ir_sq) |value, *out| {
        out.* = value * value;
    }
    if (timings) |out| out.adaptive_square2_ns += monotonicNowNs() - square2_started;

    const blurred_sq2_started = monotonicNowNs();
    const blurred_sq2 = try adaptiveBlurF32(allocator, ir_sq, width, height, options.blur_size, options.worker_count, blur_plan.final);
    defer allocator.free(blurred_sq2);
    if (timings) |out| out.adaptive_blurred_square2_ns += monotonicNowNs() - blurred_sq2_started;

    const final_started = monotonicNowNs();
    for (ir_f, background2, blurred_sq2, dust_mask, n_sigma2_out) |ir_value, bg, sq, *mask, *sigma_out| {
        const local_std = @sqrt(@max(sq - bg * bg, @as(f32, 0.0)));
        const deficit = bg - ir_value;
        const n_sigma = if (local_std > 1e-4) deficit / local_std else 0.0;
        const ratio = if (bg > 0.01) ir_value / bg else 1.0;
        sigma_out.* = @floatCast(n_sigma);
        mask.* = if (n_sigma > sigma_threshold and ratio < ratio_threshold) 255 else 0;
    }
    if (timings) |out| out.adaptive_final_ns += monotonicNowNs() - final_started;
}

pub fn detectLineDefects(
    allocator: std.mem.Allocator,
    n_sigma: []const f64,
    width: usize,
    height: usize,
    output: []u8,
    options: LineDetectionOptions,
) !void {
    try detectLineDefectsTimed(allocator, n_sigma, width, height, output, options, null);
}

pub fn detectLineDefectsTimed(
    allocator: std.mem.Allocator,
    n_sigma: []const f64,
    width: usize,
    height: usize,
    output: []u8,
    options: LineDetectionOptions,
    timings: ?*IrCleanTimings,
) !void {
    try detectLineDefectsTimedWithMeijering(allocator, n_sigma, width, height, output, options, timings, false);
}

pub fn detectLineDefectsScalarReference(
    allocator: std.mem.Allocator,
    n_sigma: []const f64,
    width: usize,
    height: usize,
    output: []u8,
    options: LineDetectionOptions,
) !void {
    try detectLineDefectsTimedWithMeijering(allocator, n_sigma, width, height, output, options, null, true);
}

fn detectLineDefectsTimedWithMeijering(
    allocator: std.mem.Allocator,
    n_sigma: []const f64,
    width: usize,
    height: usize,
    output: []u8,
    options: LineDetectionOptions,
    timings: ?*IrCleanTimings,
    scalar_meijering: bool,
) !void {
    if (width == 0 or height == 0 or n_sigma.len != width * height or output.len != n_sigma.len) {
        return error.InvalidIrLineBuffer;
    }
    if (!std.math.isFinite(options.threshold) or options.threshold <= 0.0) return error.InvalidIrLineOption;
    if (!std.math.isFinite(options.hair_sensitivity) or options.hair_sensitivity < 0.0) return error.InvalidIrLineOption;
    if (!std.math.isFinite(options.scale) or options.scale <= 0.0 or options.scale > 1.0) return error.InvalidIrLineOption;
    if (options.sigma_min == 0 or options.sigma_max < options.sigma_min) return error.InvalidIrLineOption;

    const small_width = @max(@as(usize, 1), @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(width)) * options.scale))));
    const small_height = @max(@as(usize, 1), @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(height)) * options.scale))));

    const resize_started = monotonicNowNs();
    const small = try resizeAreaPositive(allocator, n_sigma, width, height, small_width, small_height);
    defer allocator.free(small);
    if (timings) |out| out.line_resize_ns += monotonicNowNs() - resize_started;

    const percentile_started = monotonicNowNs();
    const nsig_max = try percentile(allocator, small, 99.9);
    if (nsig_max > 0.0) {
        for (small) |*value| {
            value.* = @min(@max(value.* / nsig_max, 0.0), 1.0);
        }
    }
    if (timings) |out| out.line_percentile_ns += monotonicNowNs() - percentile_started;

    const response = try allocator.alloc(f64, small.len);
    defer allocator.free(response);
    const meijering_started = monotonicNowNs();
    if (scalar_meijering) {
        try meijeringLineResponseScalar(allocator, small, small_width, small_height, response, options.sigma_min, options.sigma_max, false);
    } else {
        try meijeringLineResponse(allocator, small, small_width, small_height, response, options.sigma_min, options.sigma_max, false);
    }
    if (timings) |out| out.meijering_ns += monotonicNowNs() - meijering_started;

    const gate_started = monotonicNowNs();
    const small_mask = try allocator.alloc(u8, small.len);
    defer allocator.free(small_mask);
    for (response, small_mask) |value, *mask| {
        mask.* = if (value > options.hair_sensitivity) 255 else 0;
    }

    resizeNearestMask(small_mask, small_width, small_height, output, width, height);

    const gate_threshold = (2.5 / options.threshold) * 0.2;
    for (n_sigma, output) |sigma, *mask| {
        if (sigma < gate_threshold) mask.* = 0;
    }
    if (timings) |out| out.line_gate_ns += monotonicNowNs() - gate_started;
}

pub fn meijeringLineResponse(
    allocator: std.mem.Allocator,
    image: []const f64,
    width: usize,
    height: usize,
    output: []f64,
    sigma_min: usize,
    sigma_max: usize,
    black_ridges: bool,
) !void {
    try meijeringLineResponseWithBackend(allocator, image, width, height, output, sigma_min, sigma_max, black_ridges, false);
}

fn meijeringLineResponseScalar(
    allocator: std.mem.Allocator,
    image: []const f64,
    width: usize,
    height: usize,
    output: []f64,
    sigma_min: usize,
    sigma_max: usize,
    black_ridges: bool,
) !void {
    try meijeringLineResponseWithBackend(allocator, image, width, height, output, sigma_min, sigma_max, black_ridges, true);
}

fn meijeringLineResponseWithBackend(
    allocator: std.mem.Allocator,
    image: []const f64,
    width: usize,
    height: usize,
    output: []f64,
    sigma_min: usize,
    sigma_max: usize,
    black_ridges: bool,
    scalar_hessian: bool,
) !void {
    if (width == 0 or height == 0 or image.len != width * height or output.len != image.len) {
        return error.InvalidIrLineBuffer;
    }
    if (sigma_min == 0 or sigma_max < sigma_min) return error.InvalidIrLineOption;

    const source = try allocator.alloc(f64, image.len);
    defer allocator.free(source);
    if (black_ridges) {
        @memcpy(source, image);
    } else {
        for (image, source) |value, *out| out.* = -value;
    }

    @memset(output, 0.0);
    const hrr = try allocator.alloc(f64, image.len);
    defer allocator.free(hrr);
    const hrc = try allocator.alloc(f64, image.len);
    defer allocator.free(hrc);
    const hcc = try allocator.alloc(f64, image.len);
    defer allocator.free(hcc);
    const values = try allocator.alloc(f64, image.len);
    defer allocator.free(values);

    var sigma = sigma_min;
    while (sigma <= sigma_max) : (sigma += 1) {
        if (scalar_hessian) {
            try hessianGaussianScalar(allocator, source, width, height, @floatFromInt(sigma), hrr, hrc, hcc);
        } else {
            try hessianGaussian(allocator, source, width, height, @floatFromInt(sigma), hrr, hrc, hcc);
        }
        var max_value: f64 = 0.0;
        for (0..image.len) |index| {
            const trace_half = (hrr[index] + hcc[index]) * 0.5;
            const delta_half = (hrr[index] - hcc[index]) * 0.5;
            const root = @sqrt(hrc[index] * hrc[index] + delta_half * delta_half);
            const eig0 = trace_half + root;
            const eig1 = trace_half - root;
            const alpha = 1.0 / 3.0;
            const val0 = eig0 + alpha * eig1;
            const val1 = alpha * eig0 + eig1;
            const selected = if (@abs(val0) >= @abs(val1)) val0 else val1;
            const value = @max(selected, 0.0);
            values[index] = value;
            max_value = @max(max_value, value);
        }
        if (max_value > 0.0) {
            for (values, output) |value, *out| {
                out.* = @max(out.*, value / max_value);
            }
        }
    }
}

pub fn applyMaskMorphology(
    allocator: std.mem.Allocator,
    input: []const u8,
    width: usize,
    height: usize,
    output: []u8,
    options: MorphologyOptions,
) !void {
    if (width == 0 or height == 0 or input.len != width * height or output.len != input.len) {
        return error.InvalidIrMorphologyBuffer;
    }

    const work = try allocator.alloc(u8, input.len);
    defer allocator.free(work);
    @memcpy(work, input);

    if (options.close_radius > 0) {
        const closed = try allocator.alloc(u8, input.len);
        defer allocator.free(closed);
        try dilateMask(allocator, work, width, height, closed, options.close_radius);
        try erodeMask(allocator, closed, width, height, work, options.close_radius);
    }

    if (options.dilate_radius > 0) {
        try dilateMask(allocator, work, width, height, output, options.dilate_radius);
    } else {
        @memcpy(output, work);
    }
}

pub fn filterSmallComponents(
    allocator: std.mem.Allocator,
    input: []const u8,
    width: usize,
    height: usize,
    output: []u8,
    min_area: usize,
) !void {
    if (width == 0 or height == 0 or input.len != width * height or output.len != input.len) {
        return error.InvalidIrComponentBuffer;
    }
    if (min_area == 0) {
        @memcpy(output, input);
        return;
    }

    @memset(output, 0);
    const visited = try allocator.alloc(bool, input.len);
    defer allocator.free(visited);
    @memset(visited, false);

    const stack = try allocator.alloc(usize, input.len);
    defer allocator.free(stack);
    const component = try allocator.alloc(usize, input.len);
    defer allocator.free(component);

    for (0..input.len) |start| {
        if (visited[start] or input[start] == 0) continue;

        var stack_len: usize = 1;
        var component_len: usize = 0;
        stack[0] = start;
        visited[start] = true;

        while (stack_len > 0) {
            stack_len -= 1;
            const index = stack[stack_len];
            component[component_len] = index;
            component_len += 1;

            const x = index % width;
            const y = index / width;
            const x_i: i32 = @intCast(x);
            const y_i: i32 = @intCast(y);
            const deltas = [_]i32{ -1, 0, 1 };
            for (&deltas) |dy| {
                for (&deltas) |dx| {
                    if (dx == 0 and dy == 0) continue;
                    const nx = x_i + dx;
                    const ny = y_i + dy;
                    if (nx < 0 or ny < 0 or nx >= @as(i32, @intCast(width)) or ny >= @as(i32, @intCast(height))) continue;
                    const next = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
                    if (visited[next] or input[next] == 0) continue;
                    visited[next] = true;
                    stack[stack_len] = next;
                    stack_len += 1;
                }
            }
        }

        if (component_len >= min_area) {
            for (component[0..component_len]) |index| {
                output[index] = 255;
            }
        }
    }
}

pub fn applyMaxCoverageGuard(input: []const u8, output: []u8, max_coverage: f64) !bool {
    if (input.len == 0 or output.len != input.len) return error.InvalidIrCoverageBuffer;
    if (!std.math.isFinite(max_coverage) or max_coverage < 0.0) return error.InvalidIrCoverageValue;
    var count: usize = 0;
    for (input) |value| {
        if (value != 0) count += 1;
    }
    const coverage = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(input.len));
    if (coverage > max_coverage) {
        @memset(output, 0);
        return true;
    }
    @memcpy(output, input);
    return false;
}

pub fn estimateLocalGrain(
    allocator: std.mem.Allocator,
    roi_rgb: []const f64,
    roi_mask: []const u8,
    width: usize,
    height: usize,
    grain_padding: usize,
) !LocalGrainEstimate {
    if (width == 0 or height == 0 or roi_rgb.len != width * height * 3 or roi_mask.len != width * height) {
        return error.InvalidIrLocalGrainBuffer;
    }
    if (!use_native_ir_helpers) {
        return ir_pure.estimateLocalGrain(allocator, roi_rgb, roi_mask, width, height, grain_padding);
    }
    if (width > @as(usize, @intCast(std.math.maxInt(c_int))) or
        height > @as(usize, @intCast(std.math.maxInt(c_int))) or
        grain_padding > @as(usize, @intCast(std.math.maxInt(c_int))))
    {
        return error.InvalidIrLocalGrainBuffer;
    }

    const signal = try allocator.alloc(f64, roi_rgb.len);
    errdefer allocator.free(signal);

    const spectrum_capacity = @min(width, height) / 2;
    var spectrum_buffer = try allocator.alloc(f64, spectrum_capacity);
    errdefer allocator.free(spectrum_buffer);

    var grain_std = [_]f64{ 0.0, 0.0, 0.0 };
    var spectrum_len: c_int = 0;
    var has_spectrum: c_int = 0;
    const status = v600_estimate_local_grain(
        roi_rgb.ptr,
        roi_mask.ptr,
        @intCast(width),
        @intCast(height),
        @intCast(grain_padding),
        grain_std[0..].ptr,
        signal.ptr,
        if (spectrum_buffer.len > 0) spectrum_buffer.ptr else signal.ptr,
        @intCast(spectrum_capacity),
        &spectrum_len,
        &has_spectrum,
    );
    if (status != 0) return error.InvalidIrLocalGrainBuffer;

    var spectrum: ?[]f64 = null;
    if (has_spectrum != 0) {
        const len: usize = @intCast(spectrum_len);
        if (len > spectrum_buffer.len) return error.InvalidIrLocalGrainBuffer;
        spectrum_buffer = try allocator.realloc(spectrum_buffer, len);
        spectrum = spectrum_buffer;
    } else {
        allocator.free(spectrum_buffer);
    }

    return .{
        .grain_std = grain_std,
        .signal = signal,
        .spectrum = spectrum,
    };
}

pub fn synthesizeGrainFromNoise(
    allocator: std.mem.Allocator,
    noise: []const f64,
    width: usize,
    height: usize,
    grain_std: []const f64,
    grain_spectrum: ?[]const f64,
    channels: usize,
    output: []f64,
) !void {
    if (width == 0 or height == 0 or channels == 0 or
        noise.len != width * height * channels or
        output.len != noise.len or
        grain_std.len < channels)
    {
        return error.InvalidIrGrainSynthesisBuffer;
    }
    if (!use_native_ir_helpers) {
        return ir_pure.synthesizeGrainFromNoise(allocator, noise, width, height, grain_std, grain_spectrum, channels, output);
    }
    if (width > @as(usize, @intCast(std.math.maxInt(c_int))) or
        height > @as(usize, @intCast(std.math.maxInt(c_int))) or
        channels > @as(usize, @intCast(std.math.maxInt(c_int))))
    {
        return error.InvalidIrGrainSynthesisBuffer;
    }
    const spectrum_len = if (grain_spectrum) |spectrum| spectrum.len else 0;
    if (spectrum_len > @as(usize, @intCast(std.math.maxInt(c_int)))) return error.InvalidIrGrainSynthesisBuffer;

    const status = v600_synthesize_grain_from_noise(
        noise.ptr,
        @intCast(width),
        @intCast(height),
        grain_std.ptr,
        if (grain_spectrum) |spectrum| spectrum.ptr else null,
        @intCast(spectrum_len),
        @intCast(channels),
        output.ptr,
    );
    if (status != 0) return error.InvalidIrGrainSynthesisBuffer;
}

pub fn biharmonicInpaint(
    allocator: std.mem.Allocator,
    image: []const f64,
    mask: []const u8,
    width: usize,
    height: usize,
    channels: usize,
    output: []f64,
) !void {
    if (width == 0 or height == 0 or channels == 0 or
        image.len != width * height * channels or
        mask.len != width * height or
        output.len != image.len)
    {
        return error.InvalidIrBiharmonicBuffer;
    }

    @memcpy(output, image);

    var mask_count: usize = 0;
    var known_count: usize = 0;
    for (mask) |value| {
        if (value != 0) {
            mask_count += 1;
        } else {
            known_count += 1;
        }
    }
    if (mask_count == 0) return;
    if (known_count == 0) return error.InvalidIrBiharmonicBuffer;

    const mins = try allocator.alloc(f64, channels);
    defer allocator.free(mins);
    const maxs = try allocator.alloc(f64, channels);
    defer allocator.free(maxs);
    @memset(mins, std.math.inf(f64));
    @memset(maxs, -std.math.inf(f64));
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = y * width + x;
            if (mask[pixel] != 0) continue;
            for (0..channels) |channel| {
                const value = image[pixel * channels + channel];
                mins[channel] = @min(mins[channel], value);
                maxs[channel] = @max(maxs[channel], value);
            }
        }
    }

    const radius: usize = 2;
    const mask_order = try allocator.alloc(usize, mask_count);
    defer allocator.free(mask_order);
    const col_for_pixel = try allocator.alloc(usize, mask.len);
    defer allocator.free(col_for_pixel);
    @memset(col_for_pixel, std.math.maxInt(usize));

    var order_len: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = y * width + x;
            if (mask[pixel] == 0 or !isBiharmonicBoundaryPixel(x, y, width, height, radius)) continue;
            col_for_pixel[pixel] = order_len;
            mask_order[order_len] = pixel;
            order_len += 1;
        }
    }
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = y * width + x;
            if (mask[pixel] == 0 or isBiharmonicBoundaryPixel(x, y, width, height, radius)) continue;
            col_for_pixel[pixel] = order_len;
            mask_order[order_len] = pixel;
            order_len += 1;
        }
    }

    var matrix = try SparseMatrixBuilder.init(allocator, mask_count);
    defer matrix.deinit();
    const rhs = try allocator.alloc(f64, mask_count * channels);
    defer allocator.free(rhs);
    @memset(rhs, 0.0);

    const interior_coefs = try biharmonicCoefficients(allocator, radius * 2 + 1, radius * 2 + 1, radius, radius);
    defer allocator.free(interior_coefs);

    for (mask_order, 0..) |pixel, row| {
        const x = pixel % width;
        const y = pixel / width;
        const y0 = y -| radius;
        const x0 = x -| radius;
        const y1 = @min(height, y + radius + 1);
        const x1 = @min(width, x + radius + 1);
        const coef_width = x1 - x0;
        const coef_height = y1 - y0;
        const center_x = x - x0;
        const center_y = y - y0;
        var allocated_coefs: ?[]f64 = null;
        defer if (allocated_coefs) |coefs| allocator.free(coefs);
        const coefs = if (coef_width == radius * 2 + 1 and coef_height == radius * 2 + 1 and center_x == radius and center_y == radius)
            interior_coefs
        else blk: {
            allocated_coefs = try biharmonicCoefficients(allocator, coef_width, coef_height, center_x, center_y);
            break :blk allocated_coefs.?;
        };

        for (0..coef_height) |cy| {
            for (0..coef_width) |cx| {
                const coef = coefs[cy * coef_width + cx];
                if (coef == 0.0) continue;
                const neighbor = (y0 + cy) * width + (x0 + cx);
                if (mask[neighbor] != 0) {
                    try matrix.append(row, col_for_pixel[neighbor], coef);
                } else {
                    for (0..channels) |channel| {
                        rhs[row * channels + channel] -= coef * output[neighbor * channels + channel];
                    }
                }
            }
        }
    }

    const sparse = try matrix.finish();
    defer allocator.free(sparse.row_offsets);

    if (mask_count <= dense_biharmonic_threshold) {
        const rhs_work = try allocator.alloc(f64, mask_count);
        defer allocator.free(rhs_work);
        const solution = try allocator.alloc(f64, mask_count);
        defer allocator.free(solution);

        for (0..channels) |channel| {
            for (0..mask_count) |row| {
                rhs_work[row] = rhs[row * channels + channel];
            }
            try solveSparseLinearSystem(allocator, sparse, rhs_work, solution);
            for (mask_order, 0..) |pixel, row| {
                output[pixel * channels + channel] = solution[row];
            }
        }
    } else {
        const solutions = try allocator.alloc(f64, mask_count * channels);
        defer allocator.free(solutions);
        try solveSparseLinearSystemChannels(allocator, sparse, rhs, channels, solutions);
        for (mask_order, 0..) |pixel, row| {
            for (0..channels) |channel| {
                output[pixel * channels + channel] = solutions[row * channels + channel];
            }
        }
    }

    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = y * width + x;
            for (0..channels) |channel| {
                const index = pixel * channels + channel;
                output[index] = @min(@max(output[index], mins[channel]), maxs[channel]);
            }
        }
    }
}

pub fn inpaintBiharmonicWithGrainFromNoise(
    allocator: std.mem.Allocator,
    rgb: []const f64,
    mask: []const u8,
    width: usize,
    height: usize,
    output: []f64,
    captured_noise: []const f64,
    options: InpaintOptions,
) !usize {
    return inpaintBiharmonicWithGrainFromNoiseTimed(allocator, rgb, mask, width, height, output, captured_noise, options, null);
}

pub fn inpaintBiharmonicWithGrainFromNoiseTimed(
    allocator: std.mem.Allocator,
    rgb: []const f64,
    mask: []const u8,
    width: usize,
    height: usize,
    output: []f64,
    captured_noise: []const f64,
    options: InpaintOptions,
    timings: ?*IrCleanTimings,
) !usize {
    const total_started = monotonicNowNs();
    defer {
        if (timings) |out| out.inpaint_total_ns += monotonicNowNs() - total_started;
    }

    const channels: usize = 3;
    if (width == 0 or height == 0 or
        mask.len != width * height or
        rgb.len != width * height * channels or
        output.len != rgb.len)
    {
        return error.InvalidIrInpaintBuffer;
    }

    for (rgb, output) |value, *out| {
        out.* = castInputStorageValue(value, options.value_kind);
    }

    const labels = try allocator.alloc(usize, mask.len);
    defer allocator.free(labels);
    const label_started = monotonicNowNs();
    var components = try labelMaskComponents8(allocator, mask, width, height, labels);
    if (timings) |out| out.inpaint_label_ns += monotonicNowNs() - label_started;
    defer components.deinit(allocator);

    if (components.items.len == 0) {
        if (captured_noise.len != 0) return error.InvalidIrInpaintNoise;
        return 0;
    }

    var noise_offset: usize = 0;
    for (components.items) |component| {
        const x0 = component.left -| options.padding;
        const y0 = component.top -| options.padding;
        const x1 = addClampedLimit(component.right, options.padding, width);
        const y1 = addClampedLimit(component.bottom, options.padding, height);
        const roi_width = x1 - x0;
        const roi_height = y1 - y0;
        const roi_pixels = roi_width * roi_height;
        const roi_values = roi_pixels * channels;
        if (captured_noise.len - noise_offset < roi_values) return error.InvalidIrInpaintNoise;

        const roi_rgb = try allocator.alloc(f64, roi_values);
        defer allocator.free(roi_rgb);
        const roi_mask = try allocator.alloc(u8, roi_pixels);
        defer allocator.free(roi_mask);

        const roi_started = monotonicNowNs();
        for (0..roi_height) |ry| {
            for (0..roi_width) |rx| {
                const source_pixel = (y0 + ry) * width + (x0 + rx);
                const roi_pixel = ry * roi_width + rx;
                roi_mask[roi_pixel] = if (labels[source_pixel] == component.label) 255 else 0;
                for (0..channels) |channel| {
                    roi_rgb[roi_pixel * channels + channel] = normalizedStorageValue(
                        output[source_pixel * channels + channel],
                        options.value_kind,
                    );
                }
            }
        }
        if (timings) |out| out.inpaint_roi_extract_ns += monotonicNowNs() - roi_started;

        const grain_started = monotonicNowNs();
        const estimate = try estimateLocalGrain(allocator, roi_rgb, roi_mask, roi_width, roi_height, options.grain_padding);
        if (timings) |out| out.local_grain_ns += monotonicNowNs() - grain_started;
        defer estimate.deinit(allocator);

        const repaired_signal = try allocator.alloc(f64, roi_values);
        defer allocator.free(repaired_signal);
        const biharmonic_started = monotonicNowNs();
        try biharmonicInpaint(allocator, estimate.signal, roi_mask, roi_width, roi_height, channels, repaired_signal);
        for (repaired_signal) |*value| {
            value.* = roundF32(value.*);
        }
        if (timings) |out| out.biharmonic_ns += monotonicNowNs() - biharmonic_started;

        const grain = try allocator.alloc(f64, roi_values);
        defer allocator.free(grain);
        const component_noise = captured_noise[noise_offset..][0..roi_values];
        noise_offset += roi_values;
        const synth_started = monotonicNowNs();
        try synthesizeGrainFromNoise(
            allocator,
            component_noise,
            roi_width,
            roi_height,
            estimate.grain_std[0..],
            estimate.spectrum,
            channels,
            grain,
        );
        if (timings) |out| out.grain_synthesis_ns += monotonicNowNs() - synth_started;

        const writeback_started = monotonicNowNs();
        for (0..roi_height) |ry| {
            for (0..roi_width) |rx| {
                const roi_pixel = ry * roi_width + rx;
                if (roi_mask[roi_pixel] == 0) continue;
                const dest_pixel = (y0 + ry) * width + (x0 + rx);
                for (0..channels) |channel| {
                    const index = roi_pixel * channels + channel;
                    const repaired_with_grain = roundF32(repaired_signal[index] + grain[index]);
                    const scaled = roundF32(repaired_with_grain * storageMax(options.value_kind));
                    output[dest_pixel * channels + channel] = castClippedStorageValue(scaled, options.value_kind);
                }
            }
        }
        if (timings) |out| out.masked_writeback_ns += monotonicNowNs() - writeback_started;
    }

    if (noise_offset != captured_noise.len) return error.InvalidIrInpaintNoise;
    return components.items.len;
}

pub fn inpaintBiharmonicWithGrain(
    allocator: std.mem.Allocator,
    random: std.Random,
    rgb: []const f64,
    mask: []const u8,
    width: usize,
    height: usize,
    output: []f64,
    options: InpaintOptions,
) !usize {
    return inpaintBiharmonicWithGrainTimed(allocator, random, rgb, mask, width, height, output, options, null);
}

pub fn inpaintBiharmonicWithGrainTimed(
    allocator: std.mem.Allocator,
    random: std.Random,
    rgb: []const f64,
    mask: []const u8,
    width: usize,
    height: usize,
    output: []f64,
    options: InpaintOptions,
    timings: ?*IrCleanTimings,
) !usize {
    const noise_len = try requiredInpaintNoiseLen(allocator, mask, width, height, options.padding);
    const noise = try allocator.alloc(f64, noise_len);
    defer allocator.free(noise);
    const noise_started = monotonicNowNs();
    for (noise) |*value| {
        value.* = random.floatNorm(f64);
    }
    if (timings) |out| out.inpaint_noise_ns += monotonicNowNs() - noise_started;
    return inpaintBiharmonicWithGrainFromNoiseTimed(
        allocator,
        rgb,
        mask,
        width,
        height,
        output,
        noise,
        options,
        timings,
    );
}

pub fn irCleanRegionWithNoise(
    allocator: std.mem.Allocator,
    rgb: []const f64,
    rgb_width: usize,
    rgb_height: usize,
    ir_channel: []const f64,
    ir_width: usize,
    ir_height: usize,
    output: []f64,
    rgb_mask_output: ?[]u8,
    captured_noise: []const f64,
    options: IrCleanOptions,
) !IrCleanResult {
    return irCleanRegionWithNoiseTimed(allocator, rgb, rgb_width, rgb_height, ir_channel, ir_width, ir_height, output, rgb_mask_output, captured_noise, options, null);
}

pub fn irCleanRegionWithNoiseTimed(
    allocator: std.mem.Allocator,
    rgb: []const f64,
    rgb_width: usize,
    rgb_height: usize,
    ir_channel: []const f64,
    ir_width: usize,
    ir_height: usize,
    output: []f64,
    rgb_mask_output: ?[]u8,
    captured_noise: []const f64,
    options: IrCleanOptions,
    timings: ?*IrCleanTimings,
) !IrCleanResult {
    const channels: usize = 3;
    if (rgb_width == 0 or rgb_height == 0 or ir_width == 0 or ir_height == 0 or
        rgb.len != rgb_width * rgb_height * channels or
        output.len != rgb.len or
        ir_channel.len != ir_width * ir_height)
    {
        return error.InvalidIrCleanBuffer;
    }
    if (rgb_mask_output) |mask_out| {
        if (mask_out.len != rgb_width * rgb_height) return error.InvalidIrCleanBuffer;
    }

    const mask_ir = try allocator.alloc(u8, ir_channel.len);
    defer allocator.free(mask_ir);
    const defect_started = monotonicNowNs();
    const cleared_by_coverage = try makeDefectMaskTimed(allocator, ir_channel, ir_width, ir_height, mask_ir, options.defect_mask, timings);
    if (timings) |out| out.defect_mask_ns += monotonicNowNs() - defect_started;
    const defect_pixels_ir = countNonZeroMask(mask_ir);
    if (defect_pixels_ir == 0) {
        @memcpy(output, rgb);
        if (rgb_mask_output) |mask_out| @memset(mask_out, 0);
        if (captured_noise.len != 0) return error.InvalidIrInpaintNoise;
        return .{
            .defect_pixels_ir = 0,
            .defect_pixels_rgb = 0,
            .cleared_by_coverage = cleared_by_coverage,
            .inpainted_regions = 0,
        };
    }

    const mask_rgb = try allocator.alloc(u8, rgb_width * rgb_height);
    defer allocator.free(mask_rgb);
    const resize_started = monotonicNowNs();
    try resizeMaskToRgb(allocator, mask_ir, ir_width, ir_height, mask_rgb, rgb_width, rgb_height);
    if (rgb_mask_output) |mask_out| @memcpy(mask_out, mask_rgb);
    if (timings) |out| out.mask_resize_ns += monotonicNowNs() - resize_started;

    const defect_pixels_rgb = countNonZeroMask(mask_rgb);
    if (defect_pixels_rgb == 0) {
        @memcpy(output, rgb);
        if (captured_noise.len != 0) return error.InvalidIrInpaintNoise;
        return .{
            .defect_pixels_ir = defect_pixels_ir,
            .defect_pixels_rgb = 0,
            .cleared_by_coverage = cleared_by_coverage,
            .inpainted_regions = 0,
        };
    }

    const inpainted_regions = try inpaintBiharmonicWithGrainFromNoiseTimed(
        allocator,
        rgb,
        mask_rgb,
        rgb_width,
        rgb_height,
        output,
        captured_noise,
        options.inpaint,
        timings,
    );
    return .{
        .defect_pixels_ir = defect_pixels_ir,
        .defect_pixels_rgb = defect_pixels_rgb,
        .cleared_by_coverage = cleared_by_coverage,
        .inpainted_regions = inpainted_regions,
    };
}

pub fn irCleanRegion(
    allocator: std.mem.Allocator,
    random: std.Random,
    rgb: []const f64,
    rgb_width: usize,
    rgb_height: usize,
    ir_channel: []const f64,
    ir_width: usize,
    ir_height: usize,
    output: []f64,
    rgb_mask_output: ?[]u8,
    options: IrCleanOptions,
) !IrCleanResult {
    return irCleanRegionTimed(allocator, random, rgb, rgb_width, rgb_height, ir_channel, ir_width, ir_height, output, rgb_mask_output, options, null);
}

pub fn irCleanRegionTimed(
    allocator: std.mem.Allocator,
    random: std.Random,
    rgb: []const f64,
    rgb_width: usize,
    rgb_height: usize,
    ir_channel: []const f64,
    ir_width: usize,
    ir_height: usize,
    output: []f64,
    rgb_mask_output: ?[]u8,
    options: IrCleanOptions,
    timings: ?*IrCleanTimings,
) !IrCleanResult {
    const channels: usize = 3;
    if (rgb_width == 0 or rgb_height == 0 or ir_width == 0 or ir_height == 0 or
        rgb.len != rgb_width * rgb_height * channels or
        output.len != rgb.len or
        ir_channel.len != ir_width * ir_height)
    {
        return error.InvalidIrCleanBuffer;
    }
    if (rgb_mask_output) |mask_out| {
        if (mask_out.len != rgb_width * rgb_height) return error.InvalidIrCleanBuffer;
    }

    const mask_ir = try allocator.alloc(u8, ir_channel.len);
    defer allocator.free(mask_ir);
    const defect_started = monotonicNowNs();
    const cleared_by_coverage = try makeDefectMaskTimed(allocator, ir_channel, ir_width, ir_height, mask_ir, options.defect_mask, timings);
    if (timings) |out| out.defect_mask_ns += monotonicNowNs() - defect_started;
    const defect_pixels_ir = countNonZeroMask(mask_ir);
    if (defect_pixels_ir == 0) {
        @memcpy(output, rgb);
        if (rgb_mask_output) |mask_out| @memset(mask_out, 0);
        return .{
            .defect_pixels_ir = 0,
            .defect_pixels_rgb = 0,
            .cleared_by_coverage = cleared_by_coverage,
            .inpainted_regions = 0,
        };
    }

    const mask_rgb = try allocator.alloc(u8, rgb_width * rgb_height);
    defer allocator.free(mask_rgb);
    const resize_started = monotonicNowNs();
    try resizeMaskToRgb(allocator, mask_ir, ir_width, ir_height, mask_rgb, rgb_width, rgb_height);
    if (rgb_mask_output) |mask_out| @memcpy(mask_out, mask_rgb);
    if (timings) |out| out.mask_resize_ns += monotonicNowNs() - resize_started;

    const defect_pixels_rgb = countNonZeroMask(mask_rgb);
    if (defect_pixels_rgb == 0) {
        @memcpy(output, rgb);
        return .{
            .defect_pixels_ir = defect_pixels_ir,
            .defect_pixels_rgb = 0,
            .cleared_by_coverage = cleared_by_coverage,
            .inpainted_regions = 0,
        };
    }

    const inpainted_regions = try inpaintBiharmonicWithGrainTimed(
        allocator,
        random,
        rgb,
        mask_rgb,
        rgb_width,
        rgb_height,
        output,
        options.inpaint,
        timings,
    );
    return .{
        .defect_pixels_ir = defect_pixels_ir,
        .defect_pixels_rgb = defect_pixels_rgb,
        .cleared_by_coverage = cleared_by_coverage,
        .inpainted_regions = inpainted_regions,
    };
}

pub const MaskComponent = struct {
    label: usize,
    left: usize,
    top: usize,
    right: usize,
    bottom: usize,
    area: usize,
};

pub fn labelMaskComponents8(
    allocator: std.mem.Allocator,
    mask: []const u8,
    width: usize,
    height: usize,
    labels: []usize,
) !std.ArrayList(MaskComponent) {
    if (labels.len != mask.len) return error.InvalidIrInpaintBuffer;
    @memset(labels, 0);

    var components: std.ArrayList(MaskComponent) = .empty;
    errdefer components.deinit(allocator);
    const stack = try allocator.alloc(usize, mask.len);
    defer allocator.free(stack);

    for (0..mask.len) |start| {
        if (mask[start] == 0 or labels[start] != 0) continue;

        const label = components.items.len + 1;
        var stack_len: usize = 1;
        stack[0] = start;
        labels[start] = label;

        var left = start % width;
        var right = left + 1;
        var top = start / width;
        var bottom = top + 1;
        var area: usize = 0;

        while (stack_len > 0) {
            stack_len -= 1;
            const index = stack[stack_len];
            area += 1;

            const x = index % width;
            const y = index / width;
            left = @min(left, x);
            right = @max(right, x + 1);
            top = @min(top, y);
            bottom = @max(bottom, y + 1);

            const x_i: i32 = @intCast(x);
            const y_i: i32 = @intCast(y);
            const deltas = [_]i32{ -1, 0, 1 };
            for (&deltas) |dy| {
                for (&deltas) |dx| {
                    if (dx == 0 and dy == 0) continue;
                    const nx = x_i + dx;
                    const ny = y_i + dy;
                    if (nx < 0 or ny < 0 or nx >= @as(i32, @intCast(width)) or ny >= @as(i32, @intCast(height))) continue;
                    const next = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
                    if (mask[next] == 0 or labels[next] != 0) continue;
                    labels[next] = label;
                    stack[stack_len] = next;
                    stack_len += 1;
                }
            }
        }

        try components.append(allocator, .{
            .label = label,
            .left = left,
            .top = top,
            .right = right,
            .bottom = bottom,
            .area = area,
        });
    }

    return components;
}

fn requiredInpaintNoiseLen(
    allocator: std.mem.Allocator,
    mask: []const u8,
    width: usize,
    height: usize,
    padding: usize,
) !usize {
    if (width == 0 or height == 0 or mask.len != width * height) return error.InvalidIrInpaintBuffer;
    const labels = try allocator.alloc(usize, mask.len);
    defer allocator.free(labels);
    var components = try labelMaskComponents8(allocator, mask, width, height, labels);
    defer components.deinit(allocator);

    var total: usize = 0;
    for (components.items) |component| {
        const x0 = component.left -| padding;
        const y0 = component.top -| padding;
        const x1 = addClampedLimit(component.right, padding, width);
        const y1 = addClampedLimit(component.bottom, padding, height);
        total += (x1 - x0) * (y1 - y0) * 3;
    }
    return total;
}

pub fn addClampedLimit(value: usize, amount: usize, limit: usize) usize {
    if (value >= limit) return limit;
    const remaining = limit - value;
    return if (amount >= remaining) limit else value + amount;
}

fn countNonZeroMask(mask: []const u8) usize {
    var count: usize = 0;
    for (mask) |value| {
        if (value != 0) count += 1;
    }
    return count;
}

fn storageMax(value_kind: InpaintValueKind) f64 {
    return switch (value_kind) {
        .float32 => 1.0,
        .uint16 => 65535.0,
    };
}

fn castInputStorageValue(value: f64, value_kind: InpaintValueKind) f64 {
    return switch (value_kind) {
        .float32 => roundF32(value),
        .uint16 => castClippedStorageValue(value, .uint16),
    };
}

fn normalizedStorageValue(value: f64, value_kind: InpaintValueKind) f64 {
    return roundF32(value / storageMax(value_kind));
}

fn castClippedStorageValue(value: f64, value_kind: InpaintValueKind) f64 {
    const max_value = storageMax(value_kind);
    const clipped = roundF32(@min(@max(value, 0.0), max_value));
    return switch (value_kind) {
        .float32 => clipped,
        .uint16 => blk: {
            const stored: u16 = @intFromFloat(clipped);
            break :blk @floatFromInt(stored);
        },
    };
}

pub const roundF32 = ir_pure.roundF32;

fn monotonicNowNs() u64 {
    if (builtin.cpu.arch.isWasm() or !builtin.link_libc) return 0;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn validateAlignmentInputs(
    rgb: []const f64,
    rgb_width: usize,
    rgb_height: usize,
    ir: []const f64,
    ir_width: usize,
    ir_height: usize,
    output: []const f64,
) !void {
    if (rgb_width == 0 or rgb_height == 0 or ir_width == 0 or ir_height == 0) return error.InvalidIrAlignmentBuffer;
    if (rgb.len != rgb_width * rgb_height * 3) return error.InvalidIrAlignmentBuffer;
    if (ir.len != ir_width * ir_height) return error.InvalidIrAlignmentBuffer;
    if (output.len != ir.len) return error.InvalidIrAlignmentBuffer;
}

pub fn applyTranslation(comptime T: type, ir: []const T, width: usize, height: usize, output: []T, tx: f64, ty: f64) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const sample_x = @as(f64, @floatFromInt(x)) + tx;
            const sample_y = @as(f64, @floatFromInt(y)) + ty;
            output[y * width + x] = @floatCast(sampleReflectBilinear(T, ir, width, height, sample_x, sample_y));
        }
    }
}

pub fn sampleReflectNearest(comptime T: type, values: []const T, width: usize, height: usize, x: i32, y: i32) f64 {
    const reflected_x = reflectIndex(x, width);
    const reflected_y = reflectIndex(y, height);
    return @floatCast(values[reflected_y * width + reflected_x]);
}

pub fn sampleReflectBilinear(comptime T: type, values: []const T, width: usize, height: usize, x: f64, y: f64) f64 {
    const x0f = @floor(x);
    const y0f = @floor(y);
    const x0: i32 = @intFromFloat(x0f);
    const y0: i32 = @intFromFloat(y0f);
    const x_frac = x - x0f;
    const y_frac = y - y0f;

    const v00 = sampleReflectNearest(T, values, width, height, x0, y0);
    const v10 = sampleReflectNearest(T, values, width, height, x0 + 1, y0);
    const v01 = sampleReflectNearest(T, values, width, height, x0, y0 + 1);
    const v11 = sampleReflectNearest(T, values, width, height, x0 + 1, y0 + 1);
    const top = v00 * (1.0 - x_frac) + v10 * x_frac;
    const bottom = v01 * (1.0 - x_frac) + v11 * x_frac;
    return top * (1.0 - y_frac) + bottom * y_frac;
}

pub fn reflectIndex(index: i32, len: usize) usize {
    var reflected = index;
    const n: i32 = @intCast(len);
    while (reflected < 0 or reflected >= n) {
        if (reflected < 0) {
            reflected = -reflected - 1;
        } else {
            reflected = 2 * n - reflected - 1;
        }
    }
    return @intCast(reflected);
}

fn gaussianBlur(
    allocator: std.mem.Allocator,
    input: []const f64,
    width: usize,
    height: usize,
    kernel_size: usize,
    requested_worker_count: usize,
) ![]f64 {
    const kernel = try gaussianKernel(allocator, kernel_size);
    defer allocator.free(kernel);

    const temp = try allocator.alloc(f64, input.len);
    errdefer allocator.free(temp);
    const radius_usize = kernel_size / 2;
    const center_weight = kernel[radius_usize];
    const pair_weights = kernel[radius_usize + 1 ..][0..radius_usize];

    const worker_count = gaussianWorkerCount(input.len, height, requested_worker_count);
    if (builtin.cpu.arch.isWasm() or worker_count <= 1) {
        gaussianHorizontalRows(input, temp, width, radius_usize, center_weight, pair_weights, 0, height);
    } else {
        try gaussianHorizontalRowsParallel(allocator, input, temp, width, height, radius_usize, center_weight, pair_weights, worker_count);
    }

    const output = try allocator.alloc(f64, input.len);
    errdefer allocator.free(output);

    if (builtin.cpu.arch.isWasm() or worker_count <= 1) {
        gaussianVerticalRows(temp, output, width, height, radius_usize, center_weight, pair_weights, 0, height);
    } else {
        try gaussianVerticalRowsParallel(allocator, temp, output, width, height, radius_usize, center_weight, pair_weights, worker_count);
    }
    allocator.free(temp);
    return output;
}

const GaussianRowsContext = struct {
    input: []const f64,
    output: []f64,
    width: usize,
    height: usize,
    radius: usize,
    center_weight: f64,
    pair_weights: []const f64,
    row_start: usize,
    row_end: usize,
};

fn loadGaussianVec(input: []const f64, start: usize) GaussianVecF64 {
    return .{
        input[start],
        input[start + 1],
        input[start + 2],
        input[start + 3],
    };
}

fn storeGaussianVec(output: []f64, start: usize, value: GaussianVecF64) void {
    inline for (0..gaussian_simd_width) |lane| {
        output[start + lane] = value[lane];
    }
}

fn gaussianWorkerCount(pixel_count: usize, height: usize, requested_worker_count: usize) usize {
    if (requested_worker_count <= 1 or pixel_count < gaussian_parallel_min_pixels_per_worker or height < gaussian_parallel_min_rows_per_worker) {
        return 1;
    }
    const by_pixels = @max(@as(usize, 1), pixel_count / gaussian_parallel_min_pixels_per_worker);
    const by_rows = @max(@as(usize, 1), height / gaussian_parallel_min_rows_per_worker);
    return @max(@as(usize, 1), @min(@min(requested_worker_count, height), @min(by_pixels, by_rows)));
}

fn gaussianHorizontalRows(
    input: []const f64,
    output: []f64,
    width: usize,
    radius: usize,
    center_weight: f64,
    pair_weights: []const f64,
    row_start: usize,
    row_end: usize,
) void {
    const x_interior_end = if (width > radius) width - radius else 0;
    for (row_start..row_end) |y| {
        const row = y * width;
        var x: usize = 0;
        while (x < @min(radius, width)) : (x += 1) {
            var sum: f64 = input[row + x] * center_weight;
            var d: usize = 1;
            while (d <= radius) : (d += 1) {
                const delta: i32 = @intCast(d);
                const sx_left = reflect101Index(@as(i32, @intCast(x)) - delta, width);
                const sx_right = reflect101Index(@as(i32, @intCast(x)) + delta, width);
                sum += (input[row + sx_left] + input[row + sx_right]) * pair_weights[d - 1];
            }
            output[row + x] = sum;
        }
        while (x + gaussian_simd_width <= x_interior_end) : (x += gaussian_simd_width) {
            const base = row + x;
            var sum = loadGaussianVec(input, base) * @as(GaussianVecF64, @splat(center_weight));
            var d: usize = 1;
            while (d <= radius) : (d += 1) {
                const pair = loadGaussianVec(input, base - d) + loadGaussianVec(input, base + d);
                sum += pair * @as(GaussianVecF64, @splat(pair_weights[d - 1]));
            }
            storeGaussianVec(output, base, sum);
        }
        while (x < x_interior_end) : (x += 1) {
            var sum: f64 = input[row + x] * center_weight;
            var d: usize = 1;
            while (d <= radius) : (d += 1) {
                sum += (input[row + x - d] + input[row + x + d]) * pair_weights[d - 1];
            }
            output[row + x] = sum;
        }
        while (x < width) : (x += 1) {
            var sum: f64 = input[row + x] * center_weight;
            var d: usize = 1;
            while (d <= radius) : (d += 1) {
                const delta: i32 = @intCast(d);
                const sx_left = reflect101Index(@as(i32, @intCast(x)) - delta, width);
                const sx_right = reflect101Index(@as(i32, @intCast(x)) + delta, width);
                sum += (input[row + sx_left] + input[row + sx_right]) * pair_weights[d - 1];
            }
            output[row + x] = sum;
        }
    }
}

fn gaussianVerticalRows(
    input: []const f64,
    output: []f64,
    width: usize,
    height: usize,
    radius: usize,
    center_weight: f64,
    pair_weights: []const f64,
    row_start: usize,
    row_end: usize,
) void {
    const y_interior_end = if (height > radius) height - radius else 0;
    for (row_start..row_end) |y| {
        const row = y * width;
        if (y < @min(radius, height) or y >= y_interior_end) {
            var x: usize = 0;
            while (x + gaussian_simd_width <= width) : (x += gaussian_simd_width) {
                var sum = loadGaussianVec(input, row + x) * @as(GaussianVecF64, @splat(center_weight));
                var d: usize = 1;
                while (d <= radius) : (d += 1) {
                    const delta: i32 = @intCast(d);
                    const sy_top = reflect101Index(@as(i32, @intCast(y)) - delta, height);
                    const sy_bottom = reflect101Index(@as(i32, @intCast(y)) + delta, height);
                    const pair = loadGaussianVec(input, sy_top * width + x) + loadGaussianVec(input, sy_bottom * width + x);
                    sum += pair * @as(GaussianVecF64, @splat(pair_weights[d - 1]));
                }
                storeGaussianVec(output, row + x, sum);
            }
            while (x < width) : (x += 1) {
                var sum: f64 = input[row + x] * center_weight;
                var d: usize = 1;
                while (d <= radius) : (d += 1) {
                    const delta: i32 = @intCast(d);
                    const sy_top = reflect101Index(@as(i32, @intCast(y)) - delta, height);
                    const sy_bottom = reflect101Index(@as(i32, @intCast(y)) + delta, height);
                    sum += (input[sy_top * width + x] + input[sy_bottom * width + x]) * pair_weights[d - 1];
                }
                output[row + x] = sum;
            }
        } else {
            var x: usize = 0;
            while (x + gaussian_simd_width <= width) : (x += gaussian_simd_width) {
                var sum = loadGaussianVec(input, row + x) * @as(GaussianVecF64, @splat(center_weight));
                var d: usize = 1;
                while (d <= radius) : (d += 1) {
                    const pair = loadGaussianVec(input, (y - d) * width + x) + loadGaussianVec(input, (y + d) * width + x);
                    sum += pair * @as(GaussianVecF64, @splat(pair_weights[d - 1]));
                }
                storeGaussianVec(output, row + x, sum);
            }
            while (x < width) : (x += 1) {
                var sum: f64 = input[row + x] * center_weight;
                var d: usize = 1;
                while (d <= radius) : (d += 1) {
                    sum += (input[(y - d) * width + x] + input[(y + d) * width + x]) * pair_weights[d - 1];
                }
                output[row + x] = sum;
            }
        }
    }
}

fn gaussianHorizontalRowsParallel(
    allocator: std.mem.Allocator,
    input: []const f64,
    output: []f64,
    width: usize,
    height: usize,
    radius: usize,
    center_weight: f64,
    pair_weights: []const f64,
    worker_count: usize,
) !void {
    const contexts = try allocator.alloc(GaussianRowsContext, worker_count);
    defer allocator.free(contexts);
    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);

    for (0..worker_count) |index| {
        contexts[index] = .{
            .input = input,
            .output = output,
            .width = width,
            .height = height,
            .radius = radius,
            .center_weight = center_weight,
            .pair_weights = pair_weights,
            .row_start = height * index / worker_count,
            .row_end = height * (index + 1) / worker_count,
        };
    }

    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (1..worker_count) |index| {
        threads[started] = try std.Thread.spawn(.{}, gaussianHorizontalWorker, .{&contexts[index]});
        started += 1;
    }
    gaussianHorizontalWorker(&contexts[0]);
    for (threads[0..started]) |thread| thread.join();
}

fn gaussianVerticalRowsParallel(
    allocator: std.mem.Allocator,
    input: []const f64,
    output: []f64,
    width: usize,
    height: usize,
    radius: usize,
    center_weight: f64,
    pair_weights: []const f64,
    worker_count: usize,
) !void {
    const contexts = try allocator.alloc(GaussianRowsContext, worker_count);
    defer allocator.free(contexts);
    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);

    for (0..worker_count) |index| {
        contexts[index] = .{
            .input = input,
            .output = output,
            .width = width,
            .height = height,
            .radius = radius,
            .center_weight = center_weight,
            .pair_weights = pair_weights,
            .row_start = height * index / worker_count,
            .row_end = height * (index + 1) / worker_count,
        };
    }

    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (1..worker_count) |index| {
        threads[started] = try std.Thread.spawn(.{}, gaussianVerticalWorker, .{&contexts[index]});
        started += 1;
    }
    gaussianVerticalWorker(&contexts[0]);
    for (threads[0..started]) |thread| thread.join();
}

fn gaussianHorizontalWorker(context: *const GaussianRowsContext) void {
    gaussianHorizontalRows(
        context.input,
        context.output,
        context.width,
        context.radius,
        context.center_weight,
        context.pair_weights,
        context.row_start,
        context.row_end,
    );
}

fn gaussianVerticalWorker(context: *const GaussianRowsContext) void {
    gaussianVerticalRows(
        context.input,
        context.output,
        context.width,
        context.height,
        context.radius,
        context.center_weight,
        context.pair_weights,
        context.row_start,
        context.row_end,
    );
}

fn gaussianBlurF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    width: usize,
    height: usize,
    kernel_size: usize,
    requested_worker_count: usize,
) ![]f32 {
    const kernel = try gaussianKernelF32(allocator, kernel_size);
    defer allocator.free(kernel);

    const temp = try allocator.alloc(f32, input.len);
    errdefer allocator.free(temp);
    const radius_usize = kernel_size / 2;
    const center_weight = kernel[radius_usize];
    const pair_weights = kernel[radius_usize + 1 ..][0..radius_usize];

    const worker_count = gaussianWorkerCount(input.len, height, requested_worker_count);
    if (builtin.cpu.arch.isWasm() or worker_count <= 1) {
        gaussianHorizontalRowsF32(input, temp, width, radius_usize, center_weight, pair_weights, 0, height);
    } else {
        try gaussianHorizontalRowsParallelF32(allocator, input, temp, width, height, radius_usize, center_weight, pair_weights, worker_count);
    }

    const output = try allocator.alloc(f32, input.len);
    errdefer allocator.free(output);

    if (builtin.cpu.arch.isWasm() or worker_count <= 1) {
        gaussianVerticalRowsF32(temp, output, width, height, radius_usize, center_weight, pair_weights, 0, height);
    } else {
        try gaussianVerticalRowsParallelF32(allocator, temp, output, width, height, radius_usize, center_weight, pair_weights, worker_count);
    }
    allocator.free(temp);
    return output;
}

fn adaptiveBlurF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    width: usize,
    height: usize,
    kernel_size: usize,
    requested_worker_count: usize,
    mode: AdaptiveF32BlurMode,
) ![]f32 {
    return switch (mode) {
        .gaussian => gaussianBlurF32(allocator, input, width, height, kernel_size, requested_worker_count),
        .box_cascade => |box_count| boxCascadeGaussianApproxBlurF32(allocator, input, width, height, kernel_size, box_count, requested_worker_count),
        .downsampled_gaussian => |scale| downsampledGaussianBlurF32(allocator, input, width, height, kernel_size, scale, requested_worker_count),
    };
}

fn downsampledGaussianBlurF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    width: usize,
    height: usize,
    kernel_size: usize,
    scale: usize,
    requested_worker_count: usize,
) ![]f32 {
    if (input.len != width * height or scale == 0) {
        return error.InvalidIrThresholdBuffer;
    }
    if (scale == 1) return gaussianBlurF32(allocator, input, width, height, kernel_size, requested_worker_count);

    const small_width = (width + scale - 1) / scale;
    const small_height = (height + scale - 1) / scale;
    const small = try allocator.alloc(f32, small_width * small_height);
    defer allocator.free(small);
    downsampleAverageF32(input, small, width, height, small_width, small_height, scale);

    const small_kernel = scaledGaussianKernelSize(kernel_size, scale);
    const blurred_small = try gaussianBlurF32(allocator, small, small_width, small_height, small_kernel, requested_worker_count);
    defer allocator.free(blurred_small);

    const output = try allocator.alloc(f32, input.len);
    errdefer allocator.free(output);
    upsampleBilinearF32(blurred_small, output, small_width, small_height, width, height, scale);
    return output;
}

fn scaledGaussianKernelSize(kernel_size: usize, scale: usize) usize {
    var scaled = (kernel_size + scale - 1) / scale;
    if (scaled < 3) scaled = 3;
    if (scaled % 2 == 0) scaled += 1;
    return scaled;
}

fn downsampleAverageF32(
    input: []const f32,
    output: []f32,
    width: usize,
    height: usize,
    small_width: usize,
    small_height: usize,
    scale: usize,
) void {
    for (0..small_height) |small_y| {
        const y0 = small_y * scale;
        const y1 = @min(y0 + scale, height);
        for (0..small_width) |small_x| {
            const x0 = small_x * scale;
            const x1 = @min(x0 + scale, width);
            var sum: f32 = 0.0;
            var count: usize = 0;
            for (y0..y1) |y| {
                for (x0..x1) |x| {
                    sum += input[y * width + x];
                    count += 1;
                }
            }
            output[small_y * small_width + small_x] = sum / @as(f32, @floatFromInt(count));
        }
    }
}

fn upsampleBilinearF32(
    input: []const f32,
    output: []f32,
    small_width: usize,
    small_height: usize,
    width: usize,
    height: usize,
    scale: usize,
) void {
    const scale_f: f32 = @floatFromInt(scale);
    for (0..height) |y| {
        const sample_y = (@as(f32, @floatFromInt(y)) + 0.5) / scale_f - 0.5;
        const y_pair = bilinearSamplePair(sample_y, small_height);
        for (0..width) |x| {
            const sample_x = (@as(f32, @floatFromInt(x)) + 0.5) / scale_f - 0.5;
            const x_pair = bilinearSamplePair(sample_x, small_width);
            const top = lerpF32(
                input[y_pair.lower * small_width + x_pair.lower],
                input[y_pair.lower * small_width + x_pair.upper],
                x_pair.fraction,
            );
            const bottom = lerpF32(
                input[y_pair.upper * small_width + x_pair.lower],
                input[y_pair.upper * small_width + x_pair.upper],
                x_pair.fraction,
            );
            output[y * width + x] = lerpF32(top, bottom, y_pair.fraction);
        }
    }
}

const BilinearSamplePair = struct {
    lower: usize,
    upper: usize,
    fraction: f32,
};

fn bilinearSamplePair(sample: f32, len: usize) BilinearSamplePair {
    if (len <= 1 or sample <= 0.0) return .{ .lower = 0, .upper = 0, .fraction = 0.0 };
    const max_index = len - 1;
    const max_sample: f32 = @floatFromInt(max_index);
    if (sample >= max_sample) return .{ .lower = max_index, .upper = max_index, .fraction = 0.0 };
    const lower_float = @floor(sample);
    const lower: usize = @intFromFloat(lower_float);
    return .{
        .lower = lower,
        .upper = lower + 1,
        .fraction = sample - lower_float,
    };
}

fn lerpF32(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn boxCascadeGaussianApproxBlurF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    width: usize,
    height: usize,
    kernel_size: usize,
    box_count: usize,
    requested_worker_count: usize,
) ![]f32 {
    if (input.len != width * height or box_count == 0 or box_count > max_gaussian_approx_boxes) {
        return error.InvalidIrThresholdBuffer;
    }

    const widths = gaussianApproxBoxWidths(kernel_size, box_count);
    const temp = try allocator.alloc(f32, input.len);
    defer allocator.free(temp);

    const ping = try allocator.alloc(f32, input.len);
    errdefer allocator.free(ping);
    const pong = try allocator.alloc(f32, input.len);
    errdefer allocator.free(pong);

    var current = input;
    for (widths[0..box_count], 0..) |box_width, index| {
        const destination = if (index % 2 == 0) ping else pong;
        try boxBlurF32Into(allocator, current, destination, temp, width, height, box_width / 2, requested_worker_count);
        current = destination;
    }

    if (box_count % 2 == 1) {
        allocator.free(pong);
        return ping;
    }

    allocator.free(ping);
    return pong;
}

const max_gaussian_approx_boxes: usize = 8;

fn gaussianApproxBoxWidths(kernel_size: usize, box_count: usize) [max_gaussian_approx_boxes]usize {
    var widths = [_]usize{1} ** max_gaussian_approx_boxes;
    const sigma = gaussianApproxSigmaF32(kernel_size);
    const n: f32 = @floatFromInt(box_count);
    const ideal = @sqrt((12.0 * sigma * sigma / n) + 1.0);
    var lower: usize = @intFromFloat(@floor(ideal));
    if (lower < 1) lower = 1;
    if (lower % 2 == 0) lower -= 1;
    const upper = lower + 2;
    const lower_f: f32 = @floatFromInt(lower);
    const lower_count_float = (12.0 * sigma * sigma - n * lower_f * lower_f - 4.0 * n * lower_f - 3.0 * n) / (-4.0 * lower_f - 4.0);
    var lower_count: isize = @intFromFloat(@round(lower_count_float));
    lower_count = @max(@as(isize, 0), @min(lower_count, @as(isize, @intCast(box_count))));
    for (0..box_count) |index| {
        widths[index] = if (index < @as(usize, @intCast(lower_count))) lower else upper;
    }
    return widths;
}

fn gaussianApproxSigmaF32(kernel_size: usize) f32 {
    if (kernel_size == 3) return @sqrt(@as(f32, 0.5));
    if (kernel_size == 5) return 1.0;
    if (kernel_size == 7) return @sqrt(@as(f32, 7.0 / 4.0));
    const half = (@as(f32, @floatFromInt(kernel_size)) - 1.0) * 0.5;
    return 0.3 * (half - 1.0) + 0.8;
}

fn boxBlurF32Into(
    allocator: std.mem.Allocator,
    input: []const f32,
    output: []f32,
    temp: []f32,
    width: usize,
    height: usize,
    radius: usize,
    requested_worker_count: usize,
) !void {
    if (input.len != width * height or output.len != input.len or temp.len != input.len) {
        return error.InvalidIrThresholdBuffer;
    }
    if (radius == 0) {
        @memcpy(output, input);
        return;
    }

    const worker_count = gaussianWorkerCount(input.len, height, requested_worker_count);
    if (builtin.cpu.arch.isWasm() or worker_count <= 1) {
        boxHorizontalRowsF32(input, temp, width, radius, 0, height);
        boxVerticalColumnsF32(temp, output, width, height, radius, 0, width);
    } else {
        try boxHorizontalRowsParallelF32(allocator, input, temp, width, height, radius, worker_count);
        try boxVerticalColumnsParallelF32(allocator, temp, output, width, height, radius, @min(worker_count, width));
    }
}

const BoxHorizontalRowsF32Context = struct {
    input: []const f32,
    output: []f32,
    width: usize,
    radius: usize,
    row_start: usize,
    row_end: usize,
};

const BoxVerticalColumnsF32Context = struct {
    input: []const f32,
    output: []f32,
    width: usize,
    height: usize,
    radius: usize,
    column_start: usize,
    column_end: usize,
};

fn boxHorizontalRowsF32(
    input: []const f32,
    output: []f32,
    width: usize,
    radius: usize,
    row_start: usize,
    row_end: usize,
) void {
    const radius_i: i32 = @intCast(radius);
    const inv_window = 1.0 / @as(f32, @floatFromInt(radius * 2 + 1));
    for (row_start..row_end) |y| {
        const row = y * width;
        var sum: f32 = 0.0;
        var offset: i32 = -radius_i;
        while (offset <= radius_i) : (offset += 1) {
            sum += input[row + reflect101Index(offset, width)];
        }
        for (0..width) |x| {
            output[row + x] = sum * inv_window;
            if (x + 1 < width) {
                const x_i: i32 = @intCast(x);
                const remove_x = reflect101Index(x_i - radius_i, width);
                const add_x = reflect101Index(x_i + radius_i + 1, width);
                sum += input[row + add_x] - input[row + remove_x];
            }
        }
    }
}

fn boxVerticalColumnsF32(
    input: []const f32,
    output: []f32,
    width: usize,
    height: usize,
    radius: usize,
    column_start: usize,
    column_end: usize,
) void {
    const radius_i: i32 = @intCast(radius);
    const inv_window = 1.0 / @as(f32, @floatFromInt(radius * 2 + 1));
    for (column_start..column_end) |x| {
        var sum: f32 = 0.0;
        var offset: i32 = -radius_i;
        while (offset <= radius_i) : (offset += 1) {
            sum += input[reflect101Index(offset, height) * width + x];
        }
        for (0..height) |y| {
            output[y * width + x] = sum * inv_window;
            if (y + 1 < height) {
                const y_i: i32 = @intCast(y);
                const remove_y = reflect101Index(y_i - radius_i, height);
                const add_y = reflect101Index(y_i + radius_i + 1, height);
                sum += input[add_y * width + x] - input[remove_y * width + x];
            }
        }
    }
}

fn boxHorizontalRowsParallelF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    output: []f32,
    width: usize,
    height: usize,
    radius: usize,
    worker_count: usize,
) !void {
    var threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);
    var contexts = try allocator.alloc(BoxHorizontalRowsF32Context, worker_count);
    defer allocator.free(contexts);
    for (0..worker_count) |index| {
        contexts[index] = .{
            .input = input,
            .output = output,
            .width = width,
            .radius = radius,
            .row_start = height * index / worker_count,
            .row_end = height * (index + 1) / worker_count,
        };
    }

    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (1..worker_count) |index| {
        threads[started] = try std.Thread.spawn(.{}, boxHorizontalRowsF32Worker, .{&contexts[index]});
        started += 1;
    }
    boxHorizontalRowsF32Worker(&contexts[0]);
    for (threads[0..started]) |thread| thread.join();
}

fn boxVerticalColumnsParallelF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    output: []f32,
    width: usize,
    height: usize,
    radius: usize,
    worker_count: usize,
) !void {
    var threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);
    var contexts = try allocator.alloc(BoxVerticalColumnsF32Context, worker_count);
    defer allocator.free(contexts);
    for (0..worker_count) |index| {
        contexts[index] = .{
            .input = input,
            .output = output,
            .width = width,
            .height = height,
            .radius = radius,
            .column_start = width * index / worker_count,
            .column_end = width * (index + 1) / worker_count,
        };
    }

    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (1..worker_count) |index| {
        threads[started] = try std.Thread.spawn(.{}, boxVerticalColumnsF32Worker, .{&contexts[index]});
        started += 1;
    }
    boxVerticalColumnsF32Worker(&contexts[0]);
    for (threads[0..started]) |thread| thread.join();
}

fn boxHorizontalRowsF32Worker(context: *const BoxHorizontalRowsF32Context) void {
    boxHorizontalRowsF32(
        context.input,
        context.output,
        context.width,
        context.radius,
        context.row_start,
        context.row_end,
    );
}

fn boxVerticalColumnsF32Worker(context: *const BoxVerticalColumnsF32Context) void {
    boxVerticalColumnsF32(
        context.input,
        context.output,
        context.width,
        context.height,
        context.radius,
        context.column_start,
        context.column_end,
    );
}

const GaussianRowsF32Context = struct {
    input: []const f32,
    output: []f32,
    width: usize,
    height: usize,
    radius: usize,
    center_weight: f32,
    pair_weights: []const f32,
    row_start: usize,
    row_end: usize,
};

fn loadGaussianVecF32(input: []const f32, start: usize) GaussianVecF32 {
    var result: GaussianVecF32 = undefined;
    inline for (0..gaussian_simd_width_f32) |lane| {
        result[lane] = input[start + lane];
    }
    return result;
}

fn storeGaussianVecF32(output: []f32, start: usize, value: GaussianVecF32) void {
    inline for (0..gaussian_simd_width_f32) |lane| {
        output[start + lane] = value[lane];
    }
}

fn gaussianHorizontalRowsF32(
    input: []const f32,
    output: []f32,
    width: usize,
    radius: usize,
    center_weight: f32,
    pair_weights: []const f32,
    row_start: usize,
    row_end: usize,
) void {
    const x_interior_end = if (width > radius) width - radius else 0;
    for (row_start..row_end) |y| {
        const row = y * width;
        var x: usize = 0;
        while (x < @min(radius, width)) : (x += 1) {
            var sum: f32 = input[row + x] * center_weight;
            var d: usize = 1;
            while (d <= radius) : (d += 1) {
                const delta: i32 = @intCast(d);
                const sx_left = reflect101Index(@as(i32, @intCast(x)) - delta, width);
                const sx_right = reflect101Index(@as(i32, @intCast(x)) + delta, width);
                sum += (input[row + sx_left] + input[row + sx_right]) * pair_weights[d - 1];
            }
            output[row + x] = sum;
        }
        while (x + gaussian_simd_width_f32 <= x_interior_end) : (x += gaussian_simd_width_f32) {
            const base = row + x;
            var sum = loadGaussianVecF32(input, base) * @as(GaussianVecF32, @splat(center_weight));
            var d: usize = 1;
            while (d <= radius) : (d += 1) {
                const pair = loadGaussianVecF32(input, base - d) + loadGaussianVecF32(input, base + d);
                sum += pair * @as(GaussianVecF32, @splat(pair_weights[d - 1]));
            }
            storeGaussianVecF32(output, base, sum);
        }
        while (x < x_interior_end) : (x += 1) {
            var sum: f32 = input[row + x] * center_weight;
            var d: usize = 1;
            while (d <= radius) : (d += 1) {
                sum += (input[row + x - d] + input[row + x + d]) * pair_weights[d - 1];
            }
            output[row + x] = sum;
        }
        while (x < width) : (x += 1) {
            var sum: f32 = input[row + x] * center_weight;
            var d: usize = 1;
            while (d <= radius) : (d += 1) {
                const delta: i32 = @intCast(d);
                const sx_left = reflect101Index(@as(i32, @intCast(x)) - delta, width);
                const sx_right = reflect101Index(@as(i32, @intCast(x)) + delta, width);
                sum += (input[row + sx_left] + input[row + sx_right]) * pair_weights[d - 1];
            }
            output[row + x] = sum;
        }
    }
}

fn gaussianVerticalRowsF32(
    input: []const f32,
    output: []f32,
    width: usize,
    height: usize,
    radius: usize,
    center_weight: f32,
    pair_weights: []const f32,
    row_start: usize,
    row_end: usize,
) void {
    const y_interior_end = if (height > radius) height - radius else 0;
    for (row_start..row_end) |y| {
        const row = y * width;
        if (y < @min(radius, height) or y >= y_interior_end) {
            var x: usize = 0;
            while (x + gaussian_simd_width_f32 <= width) : (x += gaussian_simd_width_f32) {
                var sum = loadGaussianVecF32(input, row + x) * @as(GaussianVecF32, @splat(center_weight));
                var d: usize = 1;
                while (d <= radius) : (d += 1) {
                    const delta: i32 = @intCast(d);
                    const sy_top = reflect101Index(@as(i32, @intCast(y)) - delta, height);
                    const sy_bottom = reflect101Index(@as(i32, @intCast(y)) + delta, height);
                    const pair = loadGaussianVecF32(input, sy_top * width + x) + loadGaussianVecF32(input, sy_bottom * width + x);
                    sum += pair * @as(GaussianVecF32, @splat(pair_weights[d - 1]));
                }
                storeGaussianVecF32(output, row + x, sum);
            }
            while (x < width) : (x += 1) {
                var sum: f32 = input[row + x] * center_weight;
                var d: usize = 1;
                while (d <= radius) : (d += 1) {
                    const delta: i32 = @intCast(d);
                    const sy_top = reflect101Index(@as(i32, @intCast(y)) - delta, height);
                    const sy_bottom = reflect101Index(@as(i32, @intCast(y)) + delta, height);
                    sum += (input[sy_top * width + x] + input[sy_bottom * width + x]) * pair_weights[d - 1];
                }
                output[row + x] = sum;
            }
        } else {
            var x: usize = 0;
            while (x + gaussian_simd_width_f32 <= width) : (x += gaussian_simd_width_f32) {
                var sum = loadGaussianVecF32(input, row + x) * @as(GaussianVecF32, @splat(center_weight));
                var d: usize = 1;
                while (d <= radius) : (d += 1) {
                    const pair = loadGaussianVecF32(input, (y - d) * width + x) + loadGaussianVecF32(input, (y + d) * width + x);
                    sum += pair * @as(GaussianVecF32, @splat(pair_weights[d - 1]));
                }
                storeGaussianVecF32(output, row + x, sum);
            }
            while (x < width) : (x += 1) {
                var sum: f32 = input[row + x] * center_weight;
                var d: usize = 1;
                while (d <= radius) : (d += 1) {
                    sum += (input[(y - d) * width + x] + input[(y + d) * width + x]) * pair_weights[d - 1];
                }
                output[row + x] = sum;
            }
        }
    }
}

fn gaussianHorizontalRowsParallelF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    output: []f32,
    width: usize,
    height: usize,
    radius: usize,
    center_weight: f32,
    pair_weights: []const f32,
    worker_count: usize,
) !void {
    const contexts = try allocator.alloc(GaussianRowsF32Context, worker_count);
    defer allocator.free(contexts);
    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);

    for (0..worker_count) |index| {
        contexts[index] = .{
            .input = input,
            .output = output,
            .width = width,
            .height = height,
            .radius = radius,
            .center_weight = center_weight,
            .pair_weights = pair_weights,
            .row_start = height * index / worker_count,
            .row_end = height * (index + 1) / worker_count,
        };
    }

    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (1..worker_count) |index| {
        threads[started] = try std.Thread.spawn(.{}, gaussianHorizontalWorkerF32, .{&contexts[index]});
        started += 1;
    }
    gaussianHorizontalWorkerF32(&contexts[0]);
    for (threads[0..started]) |thread| thread.join();
}

fn gaussianVerticalRowsParallelF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    output: []f32,
    width: usize,
    height: usize,
    radius: usize,
    center_weight: f32,
    pair_weights: []const f32,
    worker_count: usize,
) !void {
    const contexts = try allocator.alloc(GaussianRowsF32Context, worker_count);
    defer allocator.free(contexts);
    const threads = try allocator.alloc(std.Thread, worker_count - 1);
    defer allocator.free(threads);

    for (0..worker_count) |index| {
        contexts[index] = .{
            .input = input,
            .output = output,
            .width = width,
            .height = height,
            .radius = radius,
            .center_weight = center_weight,
            .pair_weights = pair_weights,
            .row_start = height * index / worker_count,
            .row_end = height * (index + 1) / worker_count,
        };
    }

    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (1..worker_count) |index| {
        threads[started] = try std.Thread.spawn(.{}, gaussianVerticalWorkerF32, .{&contexts[index]});
        started += 1;
    }
    gaussianVerticalWorkerF32(&contexts[0]);
    for (threads[0..started]) |thread| thread.join();
}

fn gaussianHorizontalWorkerF32(context: *const GaussianRowsF32Context) void {
    gaussianHorizontalRowsF32(
        context.input,
        context.output,
        context.width,
        context.radius,
        context.center_weight,
        context.pair_weights,
        context.row_start,
        context.row_end,
    );
}

fn gaussianVerticalWorkerF32(context: *const GaussianRowsF32Context) void {
    gaussianVerticalRowsF32(
        context.input,
        context.output,
        context.width,
        context.height,
        context.radius,
        context.center_weight,
        context.pair_weights,
        context.row_start,
        context.row_end,
    );
}

fn hessianGaussian(
    allocator: std.mem.Allocator,
    image: []const f64,
    width: usize,
    height: usize,
    sigma: f64,
    hrr: []f64,
    hrc: []f64,
    hcc: []f64,
) !void {
    const sigma_scaled = sigma / @sqrt(2.0);
    const truncate: f64 = if (sigma > 1.0) 8.0 else 100.0;

    const grad_r = try allocator.alloc(f64, image.len);
    defer allocator.free(grad_r);
    const grad_c = try allocator.alloc(f64, image.len);
    defer allocator.free(grad_c);

    try gaussianFilterOrder(allocator, image, width, height, grad_r, sigma_scaled, truncate, 1, 0);
    try gaussianFilterOrder(allocator, image, width, height, grad_c, sigma_scaled, truncate, 0, 1);
    try gaussianFilterOrder(allocator, grad_r, width, height, hrr, sigma_scaled, truncate, 1, 0);
    try gaussianFilterOrder(allocator, grad_r, width, height, hrc, sigma_scaled, truncate, 0, 1);
    try gaussianFilterOrder(allocator, grad_c, width, height, hcc, sigma_scaled, truncate, 0, 1);
}

fn hessianGaussianScalar(
    allocator: std.mem.Allocator,
    image: []const f64,
    width: usize,
    height: usize,
    sigma: f64,
    hrr: []f64,
    hrc: []f64,
    hcc: []f64,
) !void {
    const sigma_scaled = sigma / @sqrt(2.0);
    const truncate: f64 = if (sigma > 1.0) 8.0 else 100.0;

    const grad_r = try allocator.alloc(f64, image.len);
    defer allocator.free(grad_r);
    const grad_c = try allocator.alloc(f64, image.len);
    defer allocator.free(grad_c);

    try gaussianFilterOrderScalar(allocator, image, width, height, grad_r, sigma_scaled, truncate, 1, 0);
    try gaussianFilterOrderScalar(allocator, image, width, height, grad_c, sigma_scaled, truncate, 0, 1);
    try gaussianFilterOrderScalar(allocator, grad_r, width, height, hrr, sigma_scaled, truncate, 1, 0);
    try gaussianFilterOrderScalar(allocator, grad_r, width, height, hrc, sigma_scaled, truncate, 0, 1);
    try gaussianFilterOrderScalar(allocator, grad_c, width, height, hcc, sigma_scaled, truncate, 0, 1);
}

fn gaussianFilterOrder(
    allocator: std.mem.Allocator,
    input: []const f64,
    width: usize,
    height: usize,
    output: []f64,
    sigma: f64,
    truncate: f64,
    order_y: usize,
    order_x: usize,
) !void {
    const temp = try allocator.alloc(f64, input.len);
    defer allocator.free(temp);
    try gaussianFilterAxis(allocator, input, width, height, temp, sigma, truncate, order_y, .y);
    try gaussianFilterAxis(allocator, temp, width, height, output, sigma, truncate, order_x, .x);
}

fn gaussianFilterOrderScalar(
    allocator: std.mem.Allocator,
    input: []const f64,
    width: usize,
    height: usize,
    output: []f64,
    sigma: f64,
    truncate: f64,
    order_y: usize,
    order_x: usize,
) !void {
    const temp = try allocator.alloc(f64, input.len);
    defer allocator.free(temp);
    try gaussianFilterAxisScalar(allocator, input, width, height, temp, sigma, truncate, order_y, .y);
    try gaussianFilterAxisScalar(allocator, temp, width, height, output, sigma, truncate, order_x, .x);
}

const Axis = enum { x, y };

fn gaussianFilterAxis(
    allocator: std.mem.Allocator,
    input: []const f64,
    width: usize,
    height: usize,
    output: []f64,
    sigma: f64,
    truncate: f64,
    order: usize,
    axis: Axis,
) !void {
    const kernel = try scipyGaussianCorrelateKernel(allocator, sigma, truncate, order);
    defer allocator.free(kernel);
    const radius: usize = kernel.len / 2;

    switch (axis) {
        .x => gaussianFilterAxisX(input, width, height, output, kernel, radius),
        .y => gaussianFilterAxisY(input, width, height, output, kernel, radius),
    }
}

fn gaussianFilterAxisScalar(
    allocator: std.mem.Allocator,
    input: []const f64,
    width: usize,
    height: usize,
    output: []f64,
    sigma: f64,
    truncate: f64,
    order: usize,
    axis: Axis,
) !void {
    const kernel = try scipyGaussianCorrelateKernel(allocator, sigma, truncate, order);
    defer allocator.free(kernel);
    const radius: usize = kernel.len / 2;
    gaussianFilterAxisScalarWithKernel(input, width, height, output, kernel, radius, axis);
}

fn gaussianFilterAxisScalarWithKernel(
    input: []const f64,
    width: usize,
    height: usize,
    output: []f64,
    kernel: []const f64,
    radius: usize,
    axis: Axis,
) void {
    for (0..height) |y| {
        for (0..width) |x| {
            output[y * width + x] = gaussianFilterAxisScalarPixel(input, width, height, kernel, radius, axis, x, y);
        }
    }
}

fn gaussianFilterAxisScalarPixel(
    input: []const f64,
    width: usize,
    height: usize,
    kernel: []const f64,
    radius: usize,
    axis: Axis,
    x: usize,
    y: usize,
) f64 {
    const radius_i: i32 = @intCast(radius);
    var sum: f64 = 0.0;
    for (kernel, 0..) |weight, k| {
        const offset = @as(i32, @intCast(k)) - radius_i;
        const sx = switch (axis) {
            .x => reflectIndex(@as(i32, @intCast(x)) + offset, width),
            .y => x,
        };
        const sy = switch (axis) {
            .x => y,
            .y => reflectIndex(@as(i32, @intCast(y)) + offset, height),
        };
        sum += input[sy * width + sx] * weight;
    }
    return sum;
}

fn gaussianFilterAxisX(
    input: []const f64,
    width: usize,
    height: usize,
    output: []f64,
    kernel: []const f64,
    radius: usize,
) void {
    const left_end = @min(radius, width);
    const interior_end = if (width > radius) width - radius else 0;
    for (0..height) |y| {
        const row = y * width;
        var x: usize = 0;
        while (x < left_end) : (x += 1) {
            output[row + x] = gaussianFilterAxisScalarPixel(input, width, height, kernel, radius, .x, x, y);
        }
        while (x + gaussian_simd_width <= interior_end) : (x += gaussian_simd_width) {
            var sum: GaussianVecF64 = @splat(0.0);
            for (kernel, 0..) |weight, k| {
                const start = row + x + k - radius;
                sum += loadGaussianVec(input, start) * @as(GaussianVecF64, @splat(weight));
            }
            storeGaussianVec(output, row + x, sum);
        }
        while (x < width) : (x += 1) {
            output[row + x] = gaussianFilterAxisScalarPixel(input, width, height, kernel, radius, .x, x, y);
        }
    }
}

fn gaussianFilterAxisY(
    input: []const f64,
    width: usize,
    height: usize,
    output: []f64,
    kernel: []const f64,
    radius: usize,
) void {
    const radius_i: i32 = @intCast(radius);
    for (0..height) |y| {
        const out_row = y * width;
        var x: usize = 0;
        while (x + gaussian_simd_width <= width) : (x += gaussian_simd_width) {
            var sum: GaussianVecF64 = @splat(0.0);
            for (kernel, 0..) |weight, k| {
                const offset = @as(i32, @intCast(k)) - radius_i;
                const sy = reflectIndex(@as(i32, @intCast(y)) + offset, height);
                sum += loadGaussianVec(input, sy * width + x) * @as(GaussianVecF64, @splat(weight));
            }
            storeGaussianVec(output, out_row + x, sum);
        }
        while (x < width) : (x += 1) {
            output[out_row + x] = gaussianFilterAxisScalarPixel(input, width, height, kernel, radius, .y, x, y);
        }
    }
}

fn scipyGaussianCorrelateKernel(allocator: std.mem.Allocator, sigma: f64, truncate: f64, order: usize) ![]f64 {
    if (sigma <= 0.0 or (order != 0 and order != 1)) return error.InvalidIrLineOption;
    const radius: usize = @intFromFloat(@floor(truncate * sigma + 0.5));
    const len = radius * 2 + 1;
    const kernel = try allocator.alloc(f64, len);
    errdefer allocator.free(kernel);

    const sigma2 = sigma * sigma;
    var phi_sum: f64 = 0.0;
    for (kernel, 0..) |*weight, index| {
        const x = @as(f64, @floatFromInt(index)) - @as(f64, @floatFromInt(radius));
        weight.* = @exp(-0.5 / sigma2 * x * x);
        phi_sum += weight.*;
    }

    for (kernel, 0..) |*weight, index| {
        const x = @as(f64, @floatFromInt(index)) - @as(f64, @floatFromInt(radius));
        const phi = weight.* / phi_sum;
        weight.* = switch (order) {
            0 => phi,
            1 => x / sigma2 * phi,
            else => unreachable,
        };
    }
    return kernel;
}

fn resizeAreaPositive(
    allocator: std.mem.Allocator,
    input: []const f64,
    width: usize,
    height: usize,
    out_width: usize,
    out_height: usize,
) ![]f64 {
    const output = try allocator.alloc(f64, out_width * out_height);
    errdefer allocator.free(output);
    const scale_x = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(out_width));
    const scale_y = @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(out_height));
    for (0..out_height) |oy| {
        const y0: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(oy)) * scale_y));
        const y1 = @min(height, @max(y0 + 1, @as(usize, @intFromFloat(@ceil(@as(f64, @floatFromInt(oy + 1)) * scale_y)))));
        for (0..out_width) |ox| {
            const x0: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(ox)) * scale_x));
            const x1 = @min(width, @max(x0 + 1, @as(usize, @intFromFloat(@ceil(@as(f64, @floatFromInt(ox + 1)) * scale_x)))));
            var sum: f64 = 0.0;
            var count: usize = 0;
            for (y0..y1) |y| {
                for (x0..x1) |x| {
                    sum += @max(input[y * width + x], 0.0);
                    count += 1;
                }
            }
            output[oy * out_width + ox] = sum / @as(f64, @floatFromInt(count));
        }
    }
    return output;
}

pub fn resizeMaskToRgb(
    allocator: std.mem.Allocator,
    mask_ir: []const u8,
    ir_width: usize,
    ir_height: usize,
    mask_rgb: []u8,
    rgb_width: usize,
    rgb_height: usize,
) !void {
    if (rgb_width != ir_width or rgb_height != ir_height) {
        resizeNearestMask(mask_ir, ir_width, ir_height, mask_rgb, rgb_width, rgb_height);
        const dilated = try allocator.alloc(u8, mask_rgb.len);
        defer allocator.free(dilated);
        try dilateMask(allocator, mask_rgb, rgb_width, rgb_height, dilated, 1);
        @memcpy(mask_rgb, dilated);
    } else {
        @memcpy(mask_rgb, mask_ir);
    }
}

pub fn resizeNearestMask(input: []const u8, width: usize, height: usize, output: []u8, out_width: usize, out_height: usize) void {
    for (0..out_height) |y| {
        const sy = @min(height - 1, y * height / out_height);
        for (0..out_width) |x| {
            const sx = @min(width - 1, x * width / out_width);
            output[y * out_width + x] = input[sy * width + sx];
        }
    }
}

fn percentile(allocator: std.mem.Allocator, values: []const f64, pct: f64) !f64 {
    if (values.len == 0 or !std.math.isFinite(pct) or pct < 0.0 or pct > 100.0) return error.InvalidIrLineOption;
    const sorted = try allocator.dupe(f64, values);
    defer allocator.free(sorted);
    std.sort.pdq(f64, sorted, {}, lessThanF64);
    const rank = (@as(f64, @floatFromInt(sorted.len - 1)) * pct) / 100.0;
    const lower: usize = @intFromFloat(@floor(rank));
    const upper: usize = @intFromFloat(@ceil(rank));
    const fraction = rank - @as(f64, @floatFromInt(lower));
    return sorted[lower] * (1.0 - fraction) + sorted[upper] * fraction;
}

fn lessThanF64(_: void, lhs: f64, rhs: f64) bool {
    return lhs < rhs;
}

fn gaussianKernel(allocator: std.mem.Allocator, kernel_size: usize) ![]f64 {
    const kernel = try allocator.alloc(f64, kernel_size);
    errdefer allocator.free(kernel);
    if (kernel_size == 3) {
        @memcpy(kernel, &[_]f64{ 0.25, 0.5, 0.25 });
        return kernel;
    }
    if (kernel_size == 5) {
        @memcpy(kernel, &[_]f64{ 0.0625, 0.25, 0.375, 0.25, 0.0625 });
        return kernel;
    }
    if (kernel_size == 7) {
        @memcpy(kernel, &[_]f64{ 0.03125, 0.109375, 0.21875, 0.28125, 0.21875, 0.109375, 0.03125 });
        return kernel;
    }

    const half = (@as(f64, @floatFromInt(kernel_size)) - 1.0) * 0.5;
    const sigma = 0.3 * (half - 1.0) + 0.8;
    var sum: f64 = 0.0;
    for (kernel, 0..) |*weight, index| {
        const x = @as(f64, @floatFromInt(index)) - half;
        weight.* = @exp(-(x * x) / (2.0 * sigma * sigma));
        sum += weight.*;
    }
    for (kernel) |*weight| {
        weight.* /= sum;
    }
    return kernel;
}

fn gaussianKernelF32(allocator: std.mem.Allocator, kernel_size: usize) ![]f32 {
    const kernel = try allocator.alloc(f32, kernel_size);
    errdefer allocator.free(kernel);
    if (kernel_size == 3) {
        @memcpy(kernel, &[_]f32{ 0.25, 0.5, 0.25 });
        return kernel;
    }
    if (kernel_size == 5) {
        @memcpy(kernel, &[_]f32{ 0.0625, 0.25, 0.375, 0.25, 0.0625 });
        return kernel;
    }
    if (kernel_size == 7) {
        @memcpy(kernel, &[_]f32{ 0.03125, 0.109375, 0.21875, 0.28125, 0.21875, 0.109375, 0.03125 });
        return kernel;
    }

    const half = (@as(f32, @floatFromInt(kernel_size)) - 1.0) * 0.5;
    const sigma = 0.3 * (half - 1.0) + 0.8;
    var sum: f32 = 0.0;
    for (kernel, 0..) |*weight, index| {
        const x = @as(f32, @floatFromInt(index)) - half;
        weight.* = @exp(-(x * x) / (2.0 * sigma * sigma));
        sum += weight.*;
    }
    for (kernel) |*weight| {
        weight.* /= sum;
    }
    return kernel;
}

fn reflect101Index(index: i32, len: usize) usize {
    if (len == 1) return 0;
    var reflected = index;
    const n: i32 = @intCast(len);
    while (reflected < 0 or reflected >= n) {
        if (reflected < 0) {
            reflected = -reflected;
        } else {
            reflected = 2 * n - reflected - 2;
        }
    }
    return @intCast(reflected);
}

fn dilateMask(allocator: std.mem.Allocator, input: []const u8, width: usize, height: usize, output: []u8, radius: usize) !void {
    const spans = try ellipseKernelRowSpans(allocator, radius);
    defer allocator.free(spans);
    const height_i: i32 = @intCast(height);
    @memset(output, 0);
    for (0..height) |y| {
        const y_i: i32 = @intCast(y);
        const out_row = output[y * width ..][0..width];
        for (spans) |span| {
            const sy = y_i + span.y_offset;
            if (sy < 0 or sy >= height_i) continue;
            applyDilationSpan(input[@as(usize, @intCast(sy)) * width ..][0..width], out_row, span.x_min, span.x_max);
        }
    }
}

fn erodeMask(allocator: std.mem.Allocator, input: []const u8, width: usize, height: usize, output: []u8, radius: usize) !void {
    const spans = try ellipseKernelRowSpans(allocator, radius);
    defer allocator.free(spans);
    const height_i: i32 = @intCast(height);
    @memset(output, 255);
    for (0..height) |y| {
        const y_i: i32 = @intCast(y);
        const out_row = output[y * width ..][0..width];
        for (spans) |span| {
            const sy = y_i + span.y_offset;
            if (sy < 0 or sy >= height_i) continue;
            applyErosionSpan(input[@as(usize, @intCast(sy)) * width ..][0..width], out_row, span.x_min, span.x_max);
        }
    }
}

const MorphologyWindow = struct {
    start: usize,
    end: usize,
};

fn clippedMorphologyWindow(x: usize, width: usize, x_min: i32, x_max: i32) ?MorphologyWindow {
    const x_i: i32 = @intCast(x);
    const width_i: i32 = @intCast(width);
    const start_i = @max(x_i + x_min, 0);
    const end_i = @min(x_i + x_max, width_i - 1);
    if (start_i > end_i) return null;
    return .{
        .start = @intCast(start_i),
        .end = @intCast(end_i),
    };
}

fn countNonZeroWindow(row: []const u8, window: MorphologyWindow) usize {
    var count: usize = 0;
    var index = window.start;
    while (index <= window.end) : (index += 1) {
        if (row[index] != 0) count += 1;
    }
    return count;
}

fn updateNonZeroWindow(row: []const u8, current: *MorphologyWindow, next: MorphologyWindow, count: *usize) void {
    while (current.start < next.start) : (current.start += 1) {
        if (row[current.start] != 0) count.* -= 1;
    }
    while (current.start > next.start) {
        current.start -= 1;
        if (row[current.start] != 0) count.* += 1;
    }
    while (current.end < next.end) {
        current.end += 1;
        if (row[current.end] != 0) count.* += 1;
    }
    while (current.end > next.end) : (current.end -= 1) {
        if (row[current.end] != 0) count.* -= 1;
    }
}

fn applyDilationSpan(input_row: []const u8, output_row: []u8, x_min: i32, x_max: i32) void {
    var active = false;
    var window = MorphologyWindow{ .start = 0, .end = 0 };
    var non_zero_count: usize = 0;
    for (0..output_row.len) |x| {
        if (clippedMorphologyWindow(x, output_row.len, x_min, x_max)) |next| {
            if (active) {
                updateNonZeroWindow(input_row, &window, next, &non_zero_count);
            } else {
                window = next;
                non_zero_count = countNonZeroWindow(input_row, window);
                active = true;
            }
            if (non_zero_count > 0) output_row[x] = 255;
        } else {
            active = false;
            non_zero_count = 0;
        }
    }
}

fn applyErosionSpan(input_row: []const u8, output_row: []u8, x_min: i32, x_max: i32) void {
    var active = false;
    var window = MorphologyWindow{ .start = 0, .end = 0 };
    var non_zero_count: usize = 0;
    for (0..output_row.len) |x| {
        if (clippedMorphologyWindow(x, output_row.len, x_min, x_max)) |next| {
            if (active) {
                updateNonZeroWindow(input_row, &window, next, &non_zero_count);
            } else {
                window = next;
                non_zero_count = countNonZeroWindow(input_row, window);
                active = true;
            }
            const window_len = window.end - window.start + 1;
            if (non_zero_count != window_len) output_row[x] = 0;
        } else {
            active = false;
            non_zero_count = 0;
        }
    }
}

fn dilateMaskReference(allocator: std.mem.Allocator, input: []const u8, width: usize, height: usize, output: []u8, radius: usize) !void {
    const spans = try ellipseKernelRowSpans(allocator, radius);
    defer allocator.free(spans);
    const width_i: i32 = @intCast(width);
    const height_i: i32 = @intCast(height);
    for (0..height) |y| {
        const y_i: i32 = @intCast(y);
        for (0..width) |x| {
            const x_i: i32 = @intCast(x);
            var set = false;
            for (spans) |span| {
                const sy = y_i + span.y_offset;
                if (sy < 0 or sy >= height_i) continue;
                const start_i = @max(x_i + span.x_min, 0);
                const end_i = @min(x_i + span.x_max, width_i - 1);
                if (start_i > end_i) continue;
                const row = @as(usize, @intCast(sy)) * width;
                var sx: usize = @intCast(start_i);
                const end: usize = @intCast(end_i);
                while (sx <= end) : (sx += 1) {
                    if (input[row + sx] != 0) {
                        set = true;
                        break;
                    }
                }
                if (set) break;
            }
            output[y * width + x] = if (set) 255 else 0;
        }
    }
}

fn erodeMaskReference(allocator: std.mem.Allocator, input: []const u8, width: usize, height: usize, output: []u8, radius: usize) !void {
    const spans = try ellipseKernelRowSpans(allocator, radius);
    defer allocator.free(spans);
    const width_i: i32 = @intCast(width);
    const height_i: i32 = @intCast(height);
    for (0..height) |y| {
        const y_i: i32 = @intCast(y);
        for (0..width) |x| {
            const x_i: i32 = @intCast(x);
            var keep = true;
            for (spans) |span| {
                const sy = y_i + span.y_offset;
                if (sy < 0 or sy >= height_i) continue;
                const start_i = @max(x_i + span.x_min, 0);
                const end_i = @min(x_i + span.x_max, width_i - 1);
                if (start_i > end_i) continue;
                const row = @as(usize, @intCast(sy)) * width;
                var sx: usize = @intCast(start_i);
                const end: usize = @intCast(end_i);
                while (sx <= end) : (sx += 1) {
                    if (input[row + sx] == 0) {
                        keep = false;
                        break;
                    }
                }
                if (!keep) break;
            }
            output[y * width + x] = if (keep) 255 else 0;
        }
    }
}

const KernelRowSpan = struct {
    y_offset: i32,
    x_min: i32,
    x_max: i32,
};

fn ellipseKernelRowSpans(allocator: std.mem.Allocator, radius: usize) ![]KernelRowSpan {
    if (radius == 0) {
        const spans = try allocator.alloc(KernelRowSpan, 1);
        spans[0] = .{ .y_offset = 0, .x_min = 0, .x_max = 0 };
        return spans;
    }

    const diameter = radius * 2 + 1;
    const spans = try allocator.alloc(KernelRowSpan, diameter);
    errdefer allocator.free(spans);
    if (radius == 1) {
        spans[0] = .{ .y_offset = -1, .x_min = 0, .x_max = 0 };
        spans[1] = .{ .y_offset = 0, .x_min = -1, .x_max = 1 };
        spans[2] = .{ .y_offset = 1, .x_min = 0, .x_max = 0 };
        return spans;
    }

    const r_i: i32 = @intCast(radius);
    const r = @as(f64, @floatFromInt(radius));
    for (0..diameter) |y| {
        var first: ?i32 = null;
        var last: i32 = 0;
        for (0..diameter) |x| {
            const dx = (@as(f64, @floatFromInt(x)) - r) / r;
            const dy = (@as(f64, @floatFromInt(y)) - r) / r;
            if (dx * dx + dy * dy <= 1.0) {
                const offset = @as(i32, @intCast(x)) - r_i;
                if (first == null) first = offset;
                last = offset;
            }
        }
        spans[y] = .{
            .y_offset = @as(i32, @intCast(y)) - r_i,
            .x_min = first orelse 0,
            .x_max = last,
        };
    }
    return spans;
}

fn ellipseKernel(allocator: std.mem.Allocator, radius: usize) ![]bool {
    const diameter = radius * 2 + 1;
    const kernel = try allocator.alloc(bool, diameter * diameter);
    errdefer allocator.free(kernel);
    if (radius == 0) {
        kernel[0] = true;
        return kernel;
    }
    if (radius == 1) {
        @memcpy(kernel, &[_]bool{
            false, true, false,
            true,  true, true,
            false, true, false,
        });
        return kernel;
    }

    const r = @as(f64, @floatFromInt(radius));
    for (0..diameter) |y| {
        for (0..diameter) |x| {
            const dx = (@as(f64, @floatFromInt(x)) - r) / r;
            const dy = (@as(f64, @floatFromInt(y)) - r) / r;
            kernel[y * diameter + x] = dx * dx + dy * dy <= 1.0;
        }
    }
    return kernel;
}

fn isBiharmonicBoundaryPixel(x: usize, y: usize, width: usize, height: usize, radius: usize) bool {
    return x < radius or y < radius or x >= width -| radius or y >= height -| radius;
}

fn biharmonicCoefficients(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    center_x: usize,
    center_y: usize,
) ![]f64 {
    const delta = try allocator.alloc(f64, width * height);
    defer allocator.free(delta);
    @memset(delta, 0.0);
    delta[center_y * width + center_x] = 1.0;

    const first = try allocator.alloc(f64, width * height);
    defer allocator.free(first);
    laplaceReflect2d(delta, width, height, first);

    const second = try allocator.alloc(f64, width * height);
    errdefer allocator.free(second);
    laplaceReflect2d(first, width, height, second);
    return second;
}

fn laplaceReflect2d(input: []const f64, width: usize, height: usize, output: []f64) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const x_i: i32 = @intCast(x);
            const y_i: i32 = @intCast(y);
            const center = input[y * width + x];
            const left = input[y * width + reflectIndex(x_i - 1, width)];
            const right = input[y * width + reflectIndex(x_i + 1, width)];
            const up = input[reflectIndex(y_i - 1, height) * width + x];
            const down = input[reflectIndex(y_i + 1, height) * width + x];
            output[y * width + x] = left + right + up + down - 4.0 * center;
        }
    }
}

const dense_biharmonic_threshold: usize = 384;

const SparseMatrix = struct {
    n: usize,
    row_offsets: []usize,
    columns: []usize,
    values: []f64,

    fn matVec(self: SparseMatrix, x: []const f64, y: []f64) void {
        @memset(y, 0.0);
        for (0..self.n) |row| {
            var sum: f64 = 0.0;
            for (self.row_offsets[row]..self.row_offsets[row + 1]) |index| {
                sum += self.values[index] * x[self.columns[index]];
            }
            y[row] = sum;
        }
    }

    fn matVecChannels(self: SparseMatrix, x: []const f64, y: []f64, channels: usize) void {
        @memset(y, 0.0);
        for (0..self.n) |row| {
            for (self.row_offsets[row]..self.row_offsets[row + 1]) |index| {
                const column = self.columns[index];
                const value = self.values[index];
                for (0..channels) |channel| {
                    y[row * channels + channel] += value * x[column * channels + channel];
                }
            }
        }
    }

    fn diagonal(self: SparseMatrix, diagonal_out: []f64) !void {
        if (diagonal_out.len != self.n) return error.InvalidIrBiharmonicBuffer;
        @memset(diagonal_out, 0.0);
        for (0..self.n) |row| {
            for (self.row_offsets[row]..self.row_offsets[row + 1]) |index| {
                if (self.columns[index] == row) {
                    diagonal_out[row] += self.values[index];
                }
            }
        }
    }
};

const SparseMatrixBuilder = struct {
    allocator: std.mem.Allocator,
    n: usize,
    row_counts: []usize,
    columns: std.ArrayList(usize),
    values: std.ArrayList(f64),
    row: usize,

    fn init(allocator: std.mem.Allocator, n: usize) !SparseMatrixBuilder {
        const row_counts = try allocator.alloc(usize, n);
        @memset(row_counts, 0);
        return .{
            .allocator = allocator,
            .n = n,
            .row_counts = row_counts,
            .columns = .empty,
            .values = .empty,
            .row = 0,
        };
    }

    fn deinit(self: *SparseMatrixBuilder) void {
        self.allocator.free(self.row_counts);
        self.columns.deinit(self.allocator);
        self.values.deinit(self.allocator);
    }

    fn append(self: *SparseMatrixBuilder, row: usize, column: usize, value: f64) !void {
        if (row >= self.n or column >= self.n) return error.InvalidIrBiharmonicBuffer;
        if (value == 0.0) return;
        try self.columns.append(self.allocator, column);
        try self.values.append(self.allocator, value);
        self.row_counts[row] += 1;
    }

    fn finish(self: *SparseMatrixBuilder) !SparseMatrix {
        const row_offsets = try self.allocator.alloc(usize, self.n + 1);
        row_offsets[0] = 0;
        for (0..self.n) |row| {
            row_offsets[row + 1] = row_offsets[row] + self.row_counts[row];
        }
        if (row_offsets[self.n] != self.columns.items.len or self.columns.items.len != self.values.items.len) {
            self.allocator.free(row_offsets);
            return error.InvalidIrBiharmonicBuffer;
        }
        return .{
            .n = self.n,
            .row_offsets = row_offsets,
            .columns = self.columns.items,
            .values = self.values.items,
        };
    }
};

fn solveSparseLinearSystem(
    allocator: std.mem.Allocator,
    matrix: SparseMatrix,
    rhs: []const f64,
    solution: []f64,
) !void {
    const n = matrix.n;
    if (rhs.len != n or solution.len != n or matrix.row_offsets.len != n + 1) {
        return error.InvalidIrBiharmonicBuffer;
    }

    if (n <= dense_biharmonic_threshold) {
        const dense = try allocator.alloc(f64, n * n);
        defer allocator.free(dense);
        @memset(dense, 0.0);
        for (0..n) |row| {
            for (matrix.row_offsets[row]..matrix.row_offsets[row + 1]) |index| {
                dense[row * n + matrix.columns[index]] += matrix.values[index];
            }
        }
        const rhs_work = try allocator.dupe(f64, rhs);
        defer allocator.free(rhs_work);
        try solveDenseLinearSystem(dense, rhs_work, solution, n);
        return;
    }

    solveSparseConjugateGradient(allocator, matrix, rhs, solution) catch |err| switch (err) {
        error.IrBiharmonicDidNotConverge, error.SingularIrBiharmonicSystem => try solveSparseBiCgStab(allocator, matrix, rhs, solution),
        else => return err,
    };
}

fn solveSparseLinearSystemChannels(
    allocator: std.mem.Allocator,
    matrix: SparseMatrix,
    rhs: []const f64,
    channels: usize,
    solution: []f64,
) !void {
    if (channels == 0 or rhs.len != matrix.n * channels or solution.len != rhs.len) {
        return error.InvalidIrBiharmonicBuffer;
    }
    const direct_status = callSolveSparseLu(
        matrix.n,
        matrix.row_offsets.ptr,
        matrix.columns.ptr,
        matrix.values.ptr,
        matrix.values.len,
        channels,
        rhs.ptr,
        solution.ptr,
    );
    if (direct_status == 0) return;
    if (direct_status < 0) return error.InvalidIrBiharmonicBuffer;

    solveSparseConjugateGradientChannels(allocator, matrix, rhs, channels, solution) catch |err| switch (err) {
        error.IrBiharmonicDidNotConverge, error.SingularIrBiharmonicSystem => {
            const rhs_work = try allocator.alloc(f64, matrix.n);
            defer allocator.free(rhs_work);
            const solution_work = try allocator.alloc(f64, matrix.n);
            defer allocator.free(solution_work);
            for (0..channels) |channel| {
                for (0..matrix.n) |row| {
                    rhs_work[row] = rhs[row * channels + channel];
                }
                try solveSparseBiCgStab(allocator, matrix, rhs_work, solution_work);
                for (0..matrix.n) |row| {
                    solution[row * channels + channel] = solution_work[row];
                }
            }
        },
        else => return err,
    };
}

fn solveSparseConjugateGradient(
    allocator: std.mem.Allocator,
    matrix: SparseMatrix,
    rhs: []const f64,
    solution: []f64,
) !void {
    const n = matrix.n;
    const inverse_diagonal = try allocator.alloc(f64, n);
    defer allocator.free(inverse_diagonal);
    try matrix.diagonal(inverse_diagonal);
    for (inverse_diagonal) |*value| {
        if (@abs(value.*) <= 1e-14) return error.SingularIrBiharmonicSystem;
        value.* = 1.0 / value.*;
    }

    const r = try allocator.alloc(f64, n);
    defer allocator.free(r);
    const z = try allocator.alloc(f64, n);
    defer allocator.free(z);
    const p = try allocator.alloc(f64, n);
    defer allocator.free(p);
    const ap = try allocator.alloc(f64, n);
    defer allocator.free(ap);

    @memset(solution, 0.0);
    @memcpy(r, rhs);
    const rhs_norm = vectorNorm(rhs);
    if (rhs_norm == 0.0) return;
    const tolerance = @max(1e-10 * rhs_norm, 1e-12);

    applyJacobi(inverse_diagonal, r, z);
    @memcpy(p, z);
    var rz_old = dot(r, z);
    if (@abs(rz_old) <= 1e-30) return error.SingularIrBiharmonicSystem;

    const max_iterations = @max(@as(usize, 1000), n * 4);
    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        matrix.matVec(p, ap);
        const denom = dot(p, ap);
        if (denom <= 1e-30 or !std.math.isFinite(denom)) return error.SingularIrBiharmonicSystem;
        const alpha = rz_old / denom;
        for (0..n) |i| {
            solution[i] += alpha * p[i];
            r[i] -= alpha * ap[i];
        }
        if (vectorNorm(r) <= tolerance) return;

        applyJacobi(inverse_diagonal, r, z);
        const rz_new = dot(r, z);
        if (@abs(rz_new) <= 1e-30 or !std.math.isFinite(rz_new)) return error.SingularIrBiharmonicSystem;
        const beta = rz_new / rz_old;
        for (0..n) |i| {
            p[i] = z[i] + beta * p[i];
        }
        rz_old = rz_new;
    }
    return error.IrBiharmonicDidNotConverge;
}

fn solveSparseConjugateGradientChannels(
    allocator: std.mem.Allocator,
    matrix: SparseMatrix,
    rhs: []const f64,
    channels: usize,
    solution: []f64,
) !void {
    const n = matrix.n;
    const inverse_diagonal = try allocator.alloc(f64, n);
    defer allocator.free(inverse_diagonal);
    try matrix.diagonal(inverse_diagonal);
    for (inverse_diagonal) |*value| {
        if (@abs(value.*) <= 1e-14) return error.SingularIrBiharmonicSystem;
        value.* = 1.0 / value.*;
    }

    const values_len = n * channels;
    const r = try allocator.alloc(f64, values_len);
    defer allocator.free(r);
    const z = try allocator.alloc(f64, values_len);
    defer allocator.free(z);
    const p = try allocator.alloc(f64, values_len);
    defer allocator.free(p);
    const ap = try allocator.alloc(f64, values_len);
    defer allocator.free(ap);
    const rhs_norm = try allocator.alloc(f64, channels);
    defer allocator.free(rhs_norm);
    const tolerance = try allocator.alloc(f64, channels);
    defer allocator.free(tolerance);
    const rz_old = try allocator.alloc(f64, channels);
    defer allocator.free(rz_old);
    const done = try allocator.alloc(bool, channels);
    defer allocator.free(done);

    @memset(solution, 0.0);
    @memcpy(r, rhs);
    @memset(done, false);
    var active_channels: usize = 0;
    for (0..channels) |channel| {
        rhs_norm[channel] = channelNorm(rhs, channels, channel);
        tolerance[channel] = @max(1e-10 * rhs_norm[channel], 1e-12);
        if (rhs_norm[channel] == 0.0) {
            done[channel] = true;
        } else {
            active_channels += 1;
        }
    }
    if (active_channels == 0) return;

    applyJacobiChannels(inverse_diagonal, r, z, channels);
    @memcpy(p, z);
    for (0..channels) |channel| {
        if (done[channel]) continue;
        rz_old[channel] = dotChannel(r, z, channels, channel);
        if (@abs(rz_old[channel]) <= 1e-30) return error.SingularIrBiharmonicSystem;
    }

    const max_iterations = @max(@as(usize, 1000), n * 4);
    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        matrix.matVecChannels(p, ap, channels);
        for (0..channels) |channel| {
            if (done[channel]) continue;
            const denom = dotChannel(p, ap, channels, channel);
            if (denom <= 1e-30 or !std.math.isFinite(denom)) return error.SingularIrBiharmonicSystem;
            const alpha = rz_old[channel] / denom;
            for (0..n) |row| {
                const index = row * channels + channel;
                solution[index] += alpha * p[index];
                r[index] -= alpha * ap[index];
            }
            if (channelNorm(r, channels, channel) <= tolerance[channel]) {
                done[channel] = true;
                active_channels -= 1;
                continue;
            }
            for (0..n) |row| {
                z[row * channels + channel] = inverse_diagonal[row] * r[row * channels + channel];
            }
            const rz_new = dotChannel(r, z, channels, channel);
            if (@abs(rz_new) <= 1e-30 or !std.math.isFinite(rz_new)) return error.SingularIrBiharmonicSystem;
            const beta = rz_new / rz_old[channel];
            for (0..n) |row| {
                const index = row * channels + channel;
                p[index] = z[index] + beta * p[index];
            }
            rz_old[channel] = rz_new;
        }
        if (active_channels == 0) return;
    }
    return error.IrBiharmonicDidNotConverge;
}

fn solveSparseBiCgStab(
    allocator: std.mem.Allocator,
    matrix: SparseMatrix,
    rhs: []const f64,
    solution: []f64,
) !void {
    const n = matrix.n;
    const diagonal_values = try allocator.alloc(f64, n);
    defer allocator.free(diagonal_values);
    try matrix.diagonal(diagonal_values);
    for (diagonal_values) |*value| {
        if (@abs(value.*) <= 1e-14) return error.SingularIrBiharmonicSystem;
        value.* = 1.0 / value.*;
    }

    const r = try allocator.alloc(f64, n);
    defer allocator.free(r);
    const r_hat = try allocator.alloc(f64, n);
    defer allocator.free(r_hat);
    const p = try allocator.alloc(f64, n);
    defer allocator.free(p);
    const v = try allocator.alloc(f64, n);
    defer allocator.free(v);
    const s = try allocator.alloc(f64, n);
    defer allocator.free(s);
    const t = try allocator.alloc(f64, n);
    defer allocator.free(t);
    const y = try allocator.alloc(f64, n);
    defer allocator.free(y);
    const z = try allocator.alloc(f64, n);
    defer allocator.free(z);

    @memset(solution, 0.0);
    @memcpy(r, rhs);
    @memcpy(r_hat, rhs);
    @memset(p, 0.0);
    @memset(v, 0.0);

    const rhs_norm = vectorNorm(rhs);
    if (rhs_norm == 0.0) return;
    const tolerance = @max(1e-10 * rhs_norm, 1e-12);

    var rho_prev: f64 = 1.0;
    var alpha: f64 = 1.0;
    var omega: f64 = 1.0;
    const max_iterations = @max(@as(usize, 1000), n * 8);
    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        const rho = dot(r_hat, r);
        if (@abs(rho) <= 1e-30) return error.SingularIrBiharmonicSystem;

        if (iteration == 0) {
            @memcpy(p, r);
        } else {
            if (@abs(omega) <= 1e-30) return error.SingularIrBiharmonicSystem;
            const beta = (rho / rho_prev) * (alpha / omega);
            for (0..n) |i| {
                p[i] = r[i] + beta * (p[i] - omega * v[i]);
            }
        }

        applyJacobi(diagonal_values, p, y);
        matrix.matVec(y, v);
        const alpha_denom = dot(r_hat, v);
        if (@abs(alpha_denom) <= 1e-30) return error.SingularIrBiharmonicSystem;
        alpha = rho / alpha_denom;

        for (0..n) |i| {
            s[i] = r[i] - alpha * v[i];
        }
        if (vectorNorm(s) <= tolerance) {
            for (0..n) |i| {
                solution[i] += alpha * y[i];
            }
            return;
        }

        applyJacobi(diagonal_values, s, z);
        matrix.matVec(z, t);
        const tt = dot(t, t);
        if (tt <= 1e-30) return error.SingularIrBiharmonicSystem;
        omega = dot(t, s) / tt;

        for (0..n) |i| {
            solution[i] += alpha * y[i] + omega * z[i];
            r[i] = s[i] - omega * t[i];
        }
        if (vectorNorm(r) <= tolerance) return;
        rho_prev = rho;
    }
    return error.IrBiharmonicDidNotConverge;
}

fn applyJacobi(inverse_diagonal: []const f64, input: []const f64, output: []f64) void {
    for (input, output, inverse_diagonal) |value, *out, diagonal| {
        out.* = diagonal * value;
    }
}

fn applyJacobiChannels(inverse_diagonal: []const f64, input: []const f64, output: []f64, channels: usize) void {
    for (0..inverse_diagonal.len) |row| {
        for (0..channels) |channel| {
            const index = row * channels + channel;
            output[index] = inverse_diagonal[row] * input[index];
        }
    }
}

fn dot(a: []const f64, b: []const f64) f64 {
    var sum: f64 = 0.0;
    for (a, b) |av, bv| {
        sum += av * bv;
    }
    return sum;
}

fn dotChannel(a: []const f64, b: []const f64, channels: usize, channel: usize) f64 {
    var sum: f64 = 0.0;
    var index = channel;
    while (index < a.len) : (index += channels) {
        sum += a[index] * b[index];
    }
    return sum;
}

fn vectorNorm(values: []const f64) f64 {
    return @sqrt(dot(values, values));
}

fn channelNorm(values: []const f64, channels: usize, channel: usize) f64 {
    return @sqrt(dotChannel(values, values, channels, channel));
}

fn solveDenseLinearSystem(matrix: []f64, rhs: []f64, solution: []f64, n: usize) !void {
    if (matrix.len != n * n or rhs.len != n or solution.len != n) return error.InvalidIrBiharmonicBuffer;

    for (0..n) |pivot_index| {
        var best_row = pivot_index;
        var best_abs = @abs(matrix[pivot_index * n + pivot_index]);
        var row = pivot_index + 1;
        while (row < n) : (row += 1) {
            const candidate = @abs(matrix[row * n + pivot_index]);
            if (candidate > best_abs) {
                best_abs = candidate;
                best_row = row;
            }
        }
        if (best_abs <= 1e-12) return error.SingularIrBiharmonicSystem;

        if (best_row != pivot_index) {
            for (0..n) |col| {
                std.mem.swap(f64, &matrix[pivot_index * n + col], &matrix[best_row * n + col]);
            }
            std.mem.swap(f64, &rhs[pivot_index], &rhs[best_row]);
        }

        const pivot = matrix[pivot_index * n + pivot_index];
        var eliminate_row = pivot_index + 1;
        while (eliminate_row < n) : (eliminate_row += 1) {
            const factor = matrix[eliminate_row * n + pivot_index] / pivot;
            matrix[eliminate_row * n + pivot_index] = 0.0;
            var col = pivot_index + 1;
            while (col < n) : (col += 1) {
                matrix[eliminate_row * n + col] -= factor * matrix[pivot_index * n + col];
            }
            rhs[eliminate_row] -= factor * rhs[pivot_index];
        }
    }

    var row_rev = n;
    while (row_rev > 0) {
        row_rev -= 1;
        var sum = rhs[row_rev];
        var col = row_rev + 1;
        while (col < n) : (col += 1) {
            sum -= matrix[row_rev * n + col] * solution[col];
        }
        solution[row_rev] = sum / matrix[row_rev * n + row_rev];
    }
}

const AlignmentFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    ratio: usize,
    ir_shape: []const usize,
    expected_offset: []const f64,
    tolerance: numeric.Tolerance,
    ir: []const f64,
    expected: []const f64,
};

const ThresholdFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    ir_shape: []const usize,
    threshold: f64,
    blur_size: usize,
    tolerance: numeric.Tolerance,
    ir: []const f64,
    expected: []const f64,
};

const LineDetectionFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    shape: []const usize,
    threshold: f64,
    hair_sensitivity: f64,
    scale: f64,
    sigma_min: usize,
    sigma_max: usize,
    tolerance: numeric.Tolerance,
    input: []const f64,
    expected: []const f64,
};

const MorphologyFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    shape: []const usize,
    close_radius: usize,
    dilate_radius: usize,
    tolerance: numeric.Tolerance,
    input: []const f64,
    expected: []const f64,
};

const ComponentFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    shape: []const usize,
    min_area: usize,
    tolerance: numeric.Tolerance,
    input: []const f64,
    expected: []const f64,
};

const CoverageFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    shape: []const usize,
    max_coverage: f64,
    tolerance: numeric.Tolerance,
    input: []const f64,
    expected: []const f64,
};

const LocalGrainFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    shape: []const usize,
    grain_padding: usize,
    tolerance: numeric.Tolerance,
    input: []const f64,
    mask: []const f64,
    expected_grain_std: []const f64,
    expected_signal: []const f64,
    expected_spectrum: []const f64,
};

const GrainSynthesisFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    shape: []const usize,
    tolerance: numeric.Tolerance,
    grain_std: []const f64,
    grain_spectrum: []const f64,
    noise: []const f64,
    expected: []const f64,
};

const BiharmonicFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    shape: []const usize,
    tolerance: numeric.Tolerance,
    input: []const f64,
    mask: []const f64,
    expected: []const f64,
};

const PythonInpaintFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    shape: []const usize,
    padding: usize,
    grain_padding: usize,
    value_kind: []const u8,
    tolerance: numeric.Tolerance,
    input: []const f64,
    mask: []const f64,
    noise: []const f64,
    expected: []const f64,
};

const IrCleanFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    rgb_shape: []const usize,
    ir_shape: []const usize,
    threshold: f64,
    hair_sensitivity: f64,
    min_area: usize,
    dilate_radius: usize,
    close_radius: usize,
    blur_size: usize,
    max_coverage: f64,
    inpaint_padding: usize,
    grain_padding: usize,
    value_kind: []const u8,
    expected_defect_pixels_ir: usize,
    expected_defect_pixels_rgb: usize,
    expected_inpainted_regions: usize,
    tolerance: numeric.Tolerance,
    rgb: []const f64,
    ir: []const f64,
    expected_ir_mask: []const f64 = &.{},
    expected_mask: []const f64,
    noise: []const f64,
    expected: []const f64,
};

fn loadAlignmentFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !std.json.Parsed(AlignmentFixture) {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(AlignmentFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidIrAlignmentFixture;
    }
    if (fixture.ir_shape.len != 2 or fixture.expected_offset.len != 2) return error.InvalidIrAlignmentFixture;
    if (fixture.ratio == 0) return error.InvalidIrAlignmentFixture;
    const ir_len = fixture.ir_shape[0] * fixture.ir_shape[1];
    if (fixture.ir.len != ir_len or fixture.expected.len != ir_len) return error.InvalidIrAlignmentFixture;
    return parsed;
}

fn expectAlignmentFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    var parsed = try loadAlignmentFixture(allocator, std.testing.io, path);
    defer parsed.deinit();
    const fixture = parsed.value;

    const ir_height = fixture.ir_shape[0];
    const ir_width = fixture.ir_shape[1];
    const rgb_height = ir_height * fixture.ratio;
    const rgb_width = ir_width * fixture.ratio;
    const rgb = try allocator.alloc(f64, rgb_width * rgb_height * 3);
    defer allocator.free(rgb);
    fillPatternRgb(rgb, rgb_width, rgb_height, fixture.ratio);

    const output = try allocator.alloc(f64, fixture.expected.len);
    defer allocator.free(output);
    const result = try alignIr(allocator, rgb, rgb_width, rgb_height, fixture.ir, ir_width, ir_height, output, .{ .max_offset = 4 });
    if (use_native_ir_helpers) {
        try std.testing.expectApproxEqAbs(fixture.expected_offset[0], result.tx, 1e-5);
        try std.testing.expectApproxEqAbs(fixture.expected_offset[1], result.ty, 1e-5);
        try std.testing.expect(result.shifted);
        try numeric.assertCloseSlices(fixture.expected, output, fixture.tolerance);
    } else {
        // The pure-Zig translation ECC is not OpenCV-bit-exact. Hold it to the
        // 0.05 px offset envelope accepted for the browser estimate path and
        // skip the sample comparison, which bakes in the exact OpenCV offset.
        try std.testing.expectApproxEqAbs(fixture.expected_offset[0], result.tx, 0.05);
        try std.testing.expectApproxEqAbs(fixture.expected_offset[1], result.ty, 0.05);
        try std.testing.expect(result.shifted);
    }
}

fn expectThresholdFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(ThresholdFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.ir_shape.len != 2) return error.InvalidIrThresholdFixture;
    const height = fixture.ir_shape[0];
    const width = fixture.ir_shape[1];
    if (fixture.ir.len != width * height or fixture.expected.len != fixture.ir.len) return error.InvalidIrThresholdFixture;

    const output = try allocator.alloc(u8, fixture.expected.len);
    defer allocator.free(output);
    try thresholdIrDefects(allocator, fixture.ir, width, height, output, .{
        .threshold = fixture.threshold,
        .blur_size = fixture.blur_size,
    });

    const actual = try allocator.alloc(f64, output.len);
    defer allocator.free(actual);
    for (output, actual) |value, *out| {
        out.* = @floatFromInt(value);
    }
    try numeric.assertCloseSlices(fixture.expected, actual, fixture.tolerance);
}

fn expectLineDetectionFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(LineDetectionFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.shape.len != 2) return error.InvalidIrLineFixture;
    const height = fixture.shape[0];
    const width = fixture.shape[1];
    if (fixture.input.len != width * height or fixture.expected.len != fixture.input.len) return error.InvalidIrLineFixture;

    const output = try allocator.alloc(u8, fixture.expected.len);
    defer allocator.free(output);
    try detectLineDefects(allocator, fixture.input, width, height, output, .{
        .threshold = fixture.threshold,
        .hair_sensitivity = fixture.hair_sensitivity,
        .scale = fixture.scale,
        .sigma_min = fixture.sigma_min,
        .sigma_max = fixture.sigma_max,
    });

    const actual = try allocator.alloc(f64, output.len);
    defer allocator.free(actual);
    for (output, actual) |value, *out| {
        out.* = @floatFromInt(value);
    }
    try numeric.assertCloseSlices(fixture.expected, actual, fixture.tolerance);
}

fn expectMorphologyFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(MorphologyFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.shape.len != 2) return error.InvalidIrMorphologyFixture;
    const height = fixture.shape[0];
    const width = fixture.shape[1];
    if (fixture.input.len != width * height or fixture.expected.len != fixture.input.len) return error.InvalidIrMorphologyFixture;

    const input = try allocator.alloc(u8, fixture.input.len);
    defer allocator.free(input);
    for (fixture.input, input) |value, *out| {
        out.* = @intFromFloat(value);
    }

    const output = try allocator.alloc(u8, fixture.expected.len);
    defer allocator.free(output);
    try applyMaskMorphology(allocator, input, width, height, output, .{
        .close_radius = fixture.close_radius,
        .dilate_radius = fixture.dilate_radius,
    });

    const actual = try allocator.alloc(f64, output.len);
    defer allocator.free(actual);
    for (output, actual) |value, *out| {
        out.* = @floatFromInt(value);
    }
    try numeric.assertCloseSlices(fixture.expected, actual, fixture.tolerance);
}

fn expectComponentFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(ComponentFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.shape.len != 2) return error.InvalidIrComponentFixture;
    const height = fixture.shape[0];
    const width = fixture.shape[1];
    if (fixture.input.len != width * height or fixture.expected.len != fixture.input.len) return error.InvalidIrComponentFixture;

    const input = try allocator.alloc(u8, fixture.input.len);
    defer allocator.free(input);
    for (fixture.input, input) |value, *out| {
        out.* = @intFromFloat(value);
    }

    const output = try allocator.alloc(u8, fixture.expected.len);
    defer allocator.free(output);
    try filterSmallComponents(allocator, input, width, height, output, fixture.min_area);

    const actual = try allocator.alloc(f64, output.len);
    defer allocator.free(actual);
    for (output, actual) |value, *out| {
        out.* = @floatFromInt(value);
    }
    try numeric.assertCloseSlices(fixture.expected, actual, fixture.tolerance);
}

fn expectCoverageFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(CoverageFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.shape.len != 2) return error.InvalidIrCoverageFixture;
    const expected_len = fixture.shape[0] * fixture.shape[1];
    if (fixture.input.len != expected_len or fixture.expected.len != expected_len) return error.InvalidIrCoverageFixture;

    const input = try allocator.alloc(u8, fixture.input.len);
    defer allocator.free(input);
    for (fixture.input, input) |value, *out| {
        out.* = @intFromFloat(value);
    }
    const output = try allocator.alloc(u8, fixture.expected.len);
    defer allocator.free(output);
    _ = try applyMaxCoverageGuard(input, output, fixture.max_coverage);

    const actual = try allocator.alloc(f64, output.len);
    defer allocator.free(actual);
    for (output, actual) |value, *out| {
        out.* = @floatFromInt(value);
    }
    try numeric.assertCloseSlices(fixture.expected, actual, fixture.tolerance);
}

fn expectLocalGrainFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(LocalGrainFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.shape.len != 3 or fixture.shape[2] != 3) return error.InvalidIrLocalGrainFixture;
    const height = fixture.shape[0];
    const width = fixture.shape[1];
    const expected_len = width * height * 3;
    if (fixture.input.len != expected_len or fixture.expected_signal.len != expected_len or
        fixture.mask.len != width * height or fixture.expected_grain_std.len != 3)
    {
        return error.InvalidIrLocalGrainFixture;
    }

    const mask = try allocator.alloc(u8, fixture.mask.len);
    defer allocator.free(mask);
    for (fixture.mask, mask) |value, *out| {
        out.* = if (value != 0.0) 255 else 0;
    }

    const estimate = try estimateLocalGrain(allocator, fixture.input, mask, width, height, fixture.grain_padding);
    defer estimate.deinit(allocator);

    try numeric.assertCloseSlices(fixture.expected_grain_std, estimate.grain_std[0..], fixture.tolerance);
    try numeric.assertCloseSlices(fixture.expected_signal, estimate.signal, fixture.tolerance);
    if (fixture.expected_spectrum.len == 0) {
        try std.testing.expect(estimate.spectrum == null);
    } else {
        try std.testing.expect(estimate.spectrum != null);
        try numeric.assertCloseSlices(fixture.expected_spectrum, estimate.spectrum.?, fixture.tolerance);
    }
}

fn expectGrainSynthesisFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(GrainSynthesisFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.shape.len != 3) return error.InvalidIrGrainSynthesisFixture;
    const height = fixture.shape[0];
    const width = fixture.shape[1];
    const channels = fixture.shape[2];
    const expected_len = width * height * channels;
    if (fixture.noise.len != expected_len or fixture.expected.len != expected_len or fixture.grain_std.len < channels) {
        return error.InvalidIrGrainSynthesisFixture;
    }

    const output = try allocator.alloc(f64, expected_len);
    defer allocator.free(output);
    try synthesizeGrainFromNoise(
        allocator,
        fixture.noise,
        width,
        height,
        fixture.grain_std,
        if (fixture.grain_spectrum.len > 0) fixture.grain_spectrum else null,
        channels,
        output,
    );
    try numeric.assertCloseSlices(fixture.expected, output, fixture.tolerance);
}

fn expectBiharmonicFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(BiharmonicFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.shape.len != 3) return error.InvalidIrBiharmonicFixture;
    const height = fixture.shape[0];
    const width = fixture.shape[1];
    const channels = fixture.shape[2];
    const expected_len = width * height * channels;
    if (fixture.input.len != expected_len or fixture.expected.len != expected_len or fixture.mask.len != width * height) {
        return error.InvalidIrBiharmonicFixture;
    }

    const mask = try allocator.alloc(u8, fixture.mask.len);
    defer allocator.free(mask);
    for (fixture.mask, mask) |value, *out| {
        out.* = if (value != 0.0) 255 else 0;
    }
    const output = try allocator.alloc(f64, expected_len);
    defer allocator.free(output);
    try biharmonicInpaint(allocator, fixture.input, mask, width, height, channels, output);
    try numeric.assertCloseSlices(fixture.expected, output, fixture.tolerance);
}

fn expectPythonInpaintFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(512 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(PythonInpaintFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.shape.len != 3 or fixture.shape[2] != 3) return error.InvalidIrInpaintFixture;
    const height = fixture.shape[0];
    const width = fixture.shape[1];
    const channels = fixture.shape[2];
    if (fixture.input.len != width * height * channels or
        fixture.expected.len != fixture.input.len or
        fixture.mask.len != width * height)
    {
        return error.InvalidIrInpaintFixture;
    }

    const mask = try allocator.alloc(u8, fixture.mask.len);
    defer allocator.free(mask);
    for (fixture.mask, mask) |value, *out| {
        out.* = @intFromFloat(value);
    }
    const output = try allocator.alloc(f64, fixture.expected.len);
    defer allocator.free(output);
    _ = try inpaintBiharmonicWithGrainFromNoise(
        allocator,
        fixture.input,
        mask,
        width,
        height,
        output,
        fixture.noise,
        .{
            .padding = fixture.padding,
            .grain_padding = fixture.grain_padding,
            .value_kind = try parseInpaintValueKind(fixture.value_kind),
        },
    );
    try numeric.assertCloseSlices(fixture.expected, output, fixture.tolerance);
}

fn expectIrCleanFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(IrCleanFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.rgb_shape.len != 3 or fixture.rgb_shape[2] != 3 or fixture.ir_shape.len != 2) return error.InvalidIrCleanFixture;
    const rgb_height = fixture.rgb_shape[0];
    const rgb_width = fixture.rgb_shape[1];
    const ir_height = fixture.ir_shape[0];
    const ir_width = fixture.ir_shape[1];
    if (fixture.rgb.len != rgb_width * rgb_height * 3 or
        fixture.ir.len != ir_width * ir_height or
        fixture.expected.len != fixture.rgb.len or
        fixture.expected_mask.len != rgb_width * rgb_height)
    {
        return error.InvalidIrCleanFixture;
    }

    const options = IrCleanOptions{
        .defect_mask = .{
            .threshold = fixture.threshold,
            .hair_sensitivity = fixture.hair_sensitivity,
            .min_area = fixture.min_area,
            .dilate_radius = fixture.dilate_radius,
            .close_radius = fixture.close_radius,
            .blur_size = fixture.blur_size,
            .max_coverage = fixture.max_coverage,
        },
        .inpaint = .{
            .padding = fixture.inpaint_padding,
            .grain_padding = fixture.grain_padding,
            .value_kind = try parseInpaintValueKind(fixture.value_kind),
        },
    };

    const mask_ir = try allocator.alloc(u8, fixture.ir.len);
    defer allocator.free(mask_ir);
    _ = try makeDefectMask(allocator, fixture.ir, ir_width, ir_height, mask_ir, options.defect_mask);
    const expected_ir_mask = if (fixture.expected_ir_mask.len > 0) fixture.expected_ir_mask else fixture.expected_mask;
    if (expected_ir_mask.len != ir_width * ir_height) return error.InvalidIrCleanFixture;
    const actual_mask = try allocator.alloc(f64, mask_ir.len);
    defer allocator.free(actual_mask);
    for (mask_ir, actual_mask) |value, *out| {
        out.* = @floatFromInt(value);
    }
    try numeric.assertCloseSlices(expected_ir_mask, actual_mask, .{
        .abs = 0.0,
        .rel = 0.0,
        .reason = "binary mask must match Python exactly",
    });

    const output = try allocator.alloc(f64, fixture.expected.len);
    defer allocator.free(output);
    const rgb_mask = try allocator.alloc(u8, rgb_width * rgb_height);
    defer allocator.free(rgb_mask);
    const result = try irCleanRegionWithNoise(
        allocator,
        fixture.rgb,
        rgb_width,
        rgb_height,
        fixture.ir,
        ir_width,
        ir_height,
        output,
        rgb_mask,
        fixture.noise,
        options,
    );
    try std.testing.expectEqual(fixture.expected_defect_pixels_ir, result.defect_pixels_ir);
    try std.testing.expectEqual(fixture.expected_defect_pixels_rgb, result.defect_pixels_rgb);
    try std.testing.expectEqual(fixture.expected_inpainted_regions, result.inpainted_regions);
    const actual_rgb_mask = try allocator.alloc(f64, rgb_mask.len);
    defer allocator.free(actual_rgb_mask);
    for (rgb_mask, actual_rgb_mask) |value, *out| {
        out.* = @floatFromInt(value);
    }
    try numeric.assertCloseSlices(fixture.expected_mask, actual_rgb_mask, .{
        .abs = 0.0,
        .rel = 0.0,
        .reason = "RGB binary mask must match Python exactly",
    });
    try numeric.assertCloseSlices(fixture.expected, output, fixture.tolerance);
}

fn parseInpaintValueKind(value: []const u8) !InpaintValueKind {
    if (std.mem.eql(u8, value, "float32")) return .float32;
    if (std.mem.eql(u8, value, "uint16")) return .uint16;
    return error.InvalidIrInpaintFixture;
}

fn fillPatternRgb(rgb: []f64, rgb_width: usize, rgb_height: usize, ratio: usize) void {
    const base_width = rgb_width / ratio;
    const base_height = rgb_height / ratio;
    const width = @as(f64, @floatFromInt(base_width));
    const height = @as(f64, @floatFromInt(base_height));
    var min_value = std.math.inf(f64);
    var max_value = -std.math.inf(f64);
    for (0..base_height) |base_y| {
        const y = @as(f64, @floatFromInt(base_y));
        for (0..base_width) |base_x| {
            const x = @as(f64, @floatFromInt(base_x));
            const value = alignmentPatternValue(x, y, width, height);
            min_value = @min(min_value, value);
            max_value = @max(max_value, value);
        }
    }

    for (0..rgb_height) |rgb_y| {
        const y = @as(f64, @floatFromInt(rgb_y / ratio));
        for (0..rgb_width) |rgb_x| {
            const x = @as(f64, @floatFromInt(rgb_x / ratio));
            const value = alignmentPatternValue(x, y, width, height);
            const normalized = (value - min_value) / (max_value - min_value);
            const base_value = 1000.0 + normalized * 50000.0;
            const index = (rgb_y * rgb_width + rgb_x) * 3;
            rgb[index] = base_value;
            rgb[index + 1] = base_value * 0.9 + 500.0;
            rgb[index + 2] = base_value * 1.1;
        }
    }
}

fn alignmentPatternValue(x: f64, y: f64, width: f64, height: f64) f64 {
    var value =
        0.42 * @sin(x / 7.0) +
        0.31 * @cos(y / 9.0) +
        0.27 * @sin((x + y) / 13.0) +
        0.21 * @cos((2.0 * x - y) / 17.0);
    value += 1.7 * gaussianBlob(x, y, 0.22 * width, 0.3 * height, 0.11 * width);
    value += -1.2 * gaussianBlob(x, y, 0.68 * width, 0.55 * height, 0.16 * width);
    value += 1.4 * gaussianBlob(x, y, 0.48 * width, 0.78 * height, 0.09 * width);
    return value;
}

fn gaussianBlob(x: f64, y: f64, cx: f64, cy: f64, sigma: f64) f64 {
    const dx = x - cx;
    const dy = y - cy;
    return @exp(-((dx * dx + dy * dy) / (2.0 * sigma * sigma)));
}

test "aligns IR with 1:2 RGB to IR dimensions" {
    try expectAlignmentFixture("test/fixtures/processing/ir/align-ratio-1-to-2.json");
}

test "aligns IR with 1:4 RGB to IR dimensions" {
    try expectAlignmentFixture("test/fixtures/processing/ir/align-ratio-1-to-4.json");
}

test "thresholds IR defects with adaptive two-pass Python subset" {
    try expectThresholdFixture("test/fixtures/processing/ir/threshold-smoke.json");
}

test "detects line defects with Meijering branch like Python fixture" {
    try expectLineDetectionFixture("test/fixtures/processing/ir/meijering-line-detection-smoke.json");
}

test "applies IR close and dilation morphology like Python fixture" {
    try expectMorphologyFixture("test/fixtures/processing/ir/morphology-close-dilate.json");
}

test "ellipse row spans match dense ellipse kernels" {
    const allocator = std.testing.allocator;
    const radii = [_]usize{ 0, 1, 2, 4, 16, 24 };
    for (radii) |radius| {
        const kernel = try ellipseKernel(allocator, radius);
        defer allocator.free(kernel);
        const spans = try ellipseKernelRowSpans(allocator, radius);
        defer allocator.free(spans);
        const diameter = radius * 2 + 1;
        const r_i: i32 = @intCast(radius);
        for (0..diameter) |y| {
            for (0..diameter) |x| {
                const y_offset = @as(i32, @intCast(y)) - r_i;
                const x_offset = @as(i32, @intCast(x)) - r_i;
                var in_span = false;
                for (spans) |span| {
                    if (span.y_offset == y_offset and x_offset >= span.x_min and x_offset <= span.x_max) {
                        in_span = true;
                        break;
                    }
                }
                try std.testing.expectEqual(kernel[y * diameter + x], in_span);
            }
        }
    }
}

test "optimized morphology spans match scalar row-span reference" {
    const allocator = std.testing.allocator;
    const width = 19;
    const height = 13;
    const input = try allocator.alloc(u8, width * height);
    defer allocator.free(input);
    for (input, 0..) |*value, index| {
        const x = index % width;
        const y = index / width;
        value.* = if ((x == 0 and y % 3 == 0) or
            (x + 1 == width and y % 4 == 0) or
            ((index * 37 + y * 11) % 23 == 0))
            255
        else
            0;
    }

    const fast = try allocator.alloc(u8, input.len);
    defer allocator.free(fast);
    const reference = try allocator.alloc(u8, input.len);
    defer allocator.free(reference);
    const radii = [_]usize{ 0, 1, 2, 4, 6 };
    for (radii) |radius| {
        try dilateMask(allocator, input, width, height, fast, radius);
        try dilateMaskReference(allocator, input, width, height, reference, radius);
        try std.testing.expectEqualSlices(u8, reference, fast);

        try erodeMask(allocator, input, width, height, fast, radius);
        try erodeMaskReference(allocator, input, width, height, reference, radius);
        try std.testing.expectEqualSlices(u8, reference, fast);
    }
}

test "gaussian filter axis SIMD matches scalar reference" {
    const allocator = std.testing.allocator;
    const width = 23;
    const height = 17;
    const input = try allocator.alloc(f64, width * height);
    defer allocator.free(input);
    for (input, 0..) |*value, index| {
        const x = index % width;
        const y = index / width;
        value.* = @sin(@as(f64, @floatFromInt(x)) * 0.17) +
            @cos(@as(f64, @floatFromInt(y)) * 0.23) +
            @as(f64, @floatFromInt((index * 13) % 19)) * 0.01;
    }
    const simd = try allocator.alloc(f64, input.len);
    defer allocator.free(simd);
    const reference = try allocator.alloc(f64, input.len);
    defer allocator.free(reference);
    const cases = [_]struct {
        sigma: f64,
        truncate: f64,
        order: usize,
        axis: Axis,
    }{
        .{ .sigma = 1.0 / @sqrt(2.0), .truncate = 100.0, .order = 0, .axis = .x },
        .{ .sigma = 1.0 / @sqrt(2.0), .truncate = 100.0, .order = 1, .axis = .y },
        .{ .sigma = 3.0 / @sqrt(2.0), .truncate = 8.0, .order = 0, .axis = .y },
        .{ .sigma = 5.0 / @sqrt(2.0), .truncate = 8.0, .order = 1, .axis = .x },
    };
    for (cases) |case| {
        try gaussianFilterAxis(allocator, input, width, height, simd, case.sigma, case.truncate, case.order, case.axis);
        try gaussianFilterAxisScalar(allocator, input, width, height, reference, case.sigma, case.truncate, case.order, case.axis);
        try std.testing.expectEqualSlices(f64, reference, simd);
    }
}

test "line defect SIMD Meijering matches scalar reference mask" {
    const allocator = std.testing.allocator;
    const width = 64;
    const height = 48;
    const n_sigma = try allocator.alloc(f64, width * height);
    defer allocator.free(n_sigma);
    for (n_sigma, 0..) |*value, index| {
        const x = index % width;
        const y = index / width;
        const diagonal: f64 = if (x > y and x - y < 3) 8.0 else 0.0;
        const vertical: f64 = if (x == 17 or x == 18) 7.0 else 0.0;
        const background = @as(f64, @floatFromInt((index * 31 + y * 7) % 11)) * 0.07;
        value.* = background + diagonal + vertical;
    }

    const simd = try allocator.alloc(u8, n_sigma.len);
    defer allocator.free(simd);
    const reference = try allocator.alloc(u8, n_sigma.len);
    defer allocator.free(reference);
    const options = LineDetectionOptions{
        .threshold = 0.10,
        .hair_sensitivity = 0.05,
        .scale = 0.5,
        .sigma_min = 1,
        .sigma_max = 3,
    };
    try detectLineDefects(allocator, n_sigma, width, height, simd, options);
    try detectLineDefectsScalarReference(allocator, n_sigma, width, height, reference, options);
    try std.testing.expectEqualSlices(u8, reference, simd);
}

test "filters connected components below minimum area like Python fixture" {
    try expectComponentFixture("test/fixtures/processing/ir/area-filter.json");
}

test "applies max coverage guard like Python fixture" {
    try expectCoverageFixture("test/fixtures/processing/ir/max-coverage-guard.json");
}

test "estimates local grain statistics and spectrum like Python fixture" {
    try expectLocalGrainFixture("test/fixtures/processing/ir/estimate-local-grain-smoke.json");
}

test "synthesizes grain from captured noise like Python fixture" {
    try expectGrainSynthesisFixture("test/fixtures/processing/ir/synthesize-grain-from-noise-smoke.json");
}

test "synthesizes fallback grain from captured noise like Python fixture" {
    try expectGrainSynthesisFixture("test/fixtures/processing/ir/synthesize-grain-fallback-from-noise-smoke.json");
}

test "solves biharmonic inpainting like scikit-image fixture" {
    try expectBiharmonicFixture("test/fixtures/processing/ir/biharmonic-inpaint-smoke.json");
}

test "applies Python biharmonic plus grain inpaint loop fixture" {
    try expectPythonInpaintFixture("test/fixtures/processing/ir/inpaint-biharmonic-grain-uint16-smoke.json");
}

test "cleans RGB region from IR mask like Python full dust-removal fixture" {
    try expectIrCleanFixture("test/fixtures/processing/ir/ir-clean-region-uint16-smoke.json");
}

test "cleans RGB region from resized IR mask like Python fixture" {
    try expectIrCleanFixture("test/fixtures/processing/ir/ir-clean-region-resize-uint16-smoke.json");
}

test "IR alignment validates dimensions" {
    var out: [1]f64 = undefined;
    try std.testing.expectError(error.InvalidIrAlignmentBuffer, alignIr(std.testing.allocator, &.{ 1.0, 2.0 }, 1, 1, &.{1.0}, 1, 1, &out, .{}));
    try std.testing.expectError(error.InvalidIrAlignmentOffset, alignIr(std.testing.allocator, &.{ 1.0, 1.0, 1.0 }, 1, 1, &.{1.0}, 1, 1, &out, .{ .max_offset = -1 }));
}

test "IR alignment returns unaligned image when ECC cannot run" {
    const rgb = [_]f64{
        10.0, 10.0, 10.0, 20.0, 20.0, 20.0,
        30.0, 30.0, 30.0, 40.0, 40.0, 40.0,
    };
    const ir = [_]f64{42.0};
    var out = [_]f64{0.0};
    const result = try alignIr(std.testing.allocator, &rgb, 2, 2, &ir, 1, 1, &out, .{});
    try std.testing.expectEqual(@as(f64, 0.0), result.tx);
    try std.testing.expectEqual(@as(f64, 0.0), result.ty);
    try std.testing.expect(!result.shifted);
    try std.testing.expectEqualSlices(f64, &ir, &out);
}

test "IR thresholding validates options" {
    var out: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidIrThresholdBuffer, thresholdIrDefects(std.testing.allocator, &.{ 1.0, 2.0 }, 1, 1, &out, .{}));
    try std.testing.expectError(error.InvalidIrThresholdBlur, thresholdIrDefects(std.testing.allocator, &.{1.0}, 1, 1, &out, .{ .blur_size = 4 }));
    try std.testing.expectError(error.InvalidIrThresholdValue, thresholdIrDefects(std.testing.allocator, &.{1.0}, 1, 1, &out, .{ .threshold = 0.0 }));
}

test "f64 gaussian blur parallel row ranges match single threaded output" {
    const width: usize = 2048;
    const height: usize = 1024;
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(f64, width * height);
    defer allocator.free(input);

    for (0..height) |y| {
        for (0..width) |x| {
            input[y * width + x] = @as(f64, @floatFromInt((x * 17 + y * 31) % 65535)) / 65535.0;
        }
    }

    const single = try gaussianBlur(allocator, input, width, height, 7, 1);
    defer allocator.free(single);
    const parallel = try gaussianBlur(allocator, input, width, height, 7, 4);
    defer allocator.free(parallel);

    try std.testing.expectEqual(@as(usize, 2), gaussianWorkerCount(input.len, height, 4));
    try std.testing.expectEqualSlices(f64, single, parallel);
}

test "f32 gaussian blur parallel row ranges match single threaded output" {
    const width: usize = 2048;
    const height: usize = 1024;
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(f32, width * height);
    defer allocator.free(input);

    for (0..height) |y| {
        for (0..width) |x| {
            input[y * width + x] = @as(f32, @floatFromInt((x * 19 + y * 23) % 65535)) / 65535.0;
        }
    }

    const single = try gaussianBlurF32(allocator, input, width, height, 7, 1);
    defer allocator.free(single);
    const parallel = try gaussianBlurF32(allocator, input, width, height, 7, 4);
    defer allocator.free(parallel);

    try std.testing.expectEqual(@as(usize, 2), gaussianWorkerCount(input.len, height, 4));
    try std.testing.expectEqualSlices(f32, single, parallel);
}

test "f32 box cascade gaussian approximation preserves constant images" {
    const width: usize = 17;
    const height: usize = 11;
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(f32, width * height);
    defer allocator.free(input);
    @memset(input, 0.375);

    const output = try boxCascadeGaussianApproxBlurF32(allocator, input, width, height, 31, 3, 1);
    defer allocator.free(output);

    for (output) |value| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.375), value, 0.000001);
    }
}

test "f32 box cascade gaussian approximation parallel ranges match single threaded output" {
    const width: usize = 2048;
    const height: usize = 1024;
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(f32, width * height);
    defer allocator.free(input);

    for (0..height) |y| {
        for (0..width) |x| {
            input[y * width + x] = @as(f32, @floatFromInt((x * 11 + y * 37) % 65535)) / 65535.0;
        }
    }

    const single = try boxCascadeGaussianApproxBlurF32(allocator, input, width, height, 301, 3, 1);
    defer allocator.free(single);
    const parallel = try boxCascadeGaussianApproxBlurF32(allocator, input, width, height, 301, 3, 4);
    defer allocator.free(parallel);

    try std.testing.expectEqual(@as(usize, 2), gaussianWorkerCount(input.len, height, 4));
    try std.testing.expectEqualSlices(f32, single, parallel);
}

test "f32 downsampled gaussian approximation preserves constant images" {
    const width: usize = 19;
    const height: usize = 13;
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(f32, width * height);
    defer allocator.free(input);
    @memset(input, 0.625);

    const output = try downsampledGaussianBlurF32(allocator, input, width, height, 31, 2, 1);
    defer allocator.free(output);

    for (output) |value| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.625), value, 0.000001);
    }
}

test "IR line detection validates options" {
    var out: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidIrLineBuffer, detectLineDefects(std.testing.allocator, &.{ 1.0, 2.0 }, 1, 1, &out, .{}));
    try std.testing.expectError(error.InvalidIrLineOption, detectLineDefects(std.testing.allocator, &.{1.0}, 1, 1, &out, .{ .threshold = 0.0 }));
    try std.testing.expectError(error.InvalidIrLineOption, detectLineDefects(std.testing.allocator, &.{1.0}, 1, 1, &out, .{ .scale = 2.0 }));
}

test "IR morphology validates dimensions" {
    var out: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidIrMorphologyBuffer, applyMaskMorphology(std.testing.allocator, &.{ 0, 255 }, 1, 1, &out, .{}));
}

test "IR component filtering validates dimensions and min-area zero copies" {
    var out = [_]u8{0};
    try std.testing.expectError(error.InvalidIrComponentBuffer, filterSmallComponents(std.testing.allocator, &.{ 0, 255 }, 1, 1, &out, 1));
    try filterSmallComponents(std.testing.allocator, &.{255}, 1, 1, &out, 0);
    try std.testing.expectEqual(@as(u8, 255), out[0]);
}

test "IR coverage guard validates values and preserves masks under cap" {
    var out = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidIrCoverageBuffer, applyMaxCoverageGuard(&.{}, &out, 0.5));
    try std.testing.expectError(error.InvalidIrCoverageValue, applyMaxCoverageGuard(&.{ 255, 0, 0, 0 }, &out, -0.1));
    const cleared = try applyMaxCoverageGuard(&.{ 255, 0, 0, 0 }, &out, 0.25);
    try std.testing.expect(!cleared);
    try std.testing.expectEqual(@as(u8, 255), out[0]);
}

test "IR local grain estimation validates dimensions" {
    var mask = [_]u8{0};
    try std.testing.expectError(error.InvalidIrLocalGrainBuffer, estimateLocalGrain(std.testing.allocator, &.{ 1.0, 2.0 }, &mask, 1, 1, 1));
}

test "IR grain synthesis validates dimensions" {
    var output = [_]f64{0};
    try std.testing.expectError(error.InvalidIrGrainSynthesisBuffer, synthesizeGrainFromNoise(std.testing.allocator, &.{ 1.0, 2.0 }, 1, 1, &.{1.0}, null, 1, &output));
}

test "IR biharmonic inpaint validates dimensions and no-mask copy" {
    var output = [_]f64{0.0};
    try std.testing.expectError(error.InvalidIrBiharmonicBuffer, biharmonicInpaint(std.testing.allocator, &.{ 1.0, 2.0 }, &.{0}, 1, 1, 1, &output));
    try biharmonicInpaint(std.testing.allocator, &.{1.25}, &.{0}, 1, 1, 1, &output);
    try std.testing.expectEqual(@as(f64, 1.25), output[0]);
}

test "IR sparse biharmonic branch preserves an affine plane" {
    const width: usize = 32;
    const height: usize = 32;
    const channels: usize = 3;
    const pixels = width * height;
    const allocator = std.testing.allocator;
    const image = try allocator.alloc(f64, pixels * channels);
    defer allocator.free(image);
    const mask = try allocator.alloc(u8, pixels);
    defer allocator.free(mask);
    const output = try allocator.alloc(f64, image.len);
    defer allocator.free(output);

    @memset(mask, 0);
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = y * width + x;
            const xf: f64 = @floatFromInt(x);
            const yf: f64 = @floatFromInt(y);
            image[pixel * channels] = 0.1 + xf * 0.007 + yf * 0.003;
            image[pixel * channels + 1] = 0.2 + xf * 0.002 + yf * 0.005;
            image[pixel * channels + 2] = 0.3 + xf * 0.004 - yf * 0.001;
            if (x >= 6 and x < 26 and y >= 6 and y < 26) {
                mask[pixel] = 255;
            }
        }
    }

    try biharmonicInpaint(allocator, image, mask, width, height, channels, output);
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = y * width + x;
            if (mask[pixel] == 0) continue;
            for (0..channels) |channel| {
                try std.testing.expectApproxEqAbs(image[pixel * channels + channel], output[pixel * channels + channel], 1e-6);
            }
        }
    }
}

test "IR Python inpaint validates dimensions and no-mask copy" {
    var out = [_]f64{ 0.0, 0.0, 0.0 };
    try std.testing.expectError(error.InvalidIrInpaintBuffer, inpaintBiharmonicWithGrainFromNoise(std.testing.allocator, &.{ 1.0, 2.0 }, &.{0}, 1, 1, &out, &.{}, .{}));
    const count = try inpaintBiharmonicWithGrainFromNoise(std.testing.allocator, &.{ 1.0, 2.0, 3.0 }, &.{0}, 1, 1, &out, &.{}, .{ .value_kind = .uint16 });
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqualSlices(f64, &.{ 1.0, 2.0, 3.0 }, &out);
    try std.testing.expectError(error.InvalidIrInpaintNoise, inpaintBiharmonicWithGrainFromNoise(std.testing.allocator, &.{ 1.0, 2.0, 3.0 }, &.{0}, 1, 1, &out, &.{1.0}, .{}));

    var prng = std.Random.DefaultPrng.init(42);
    const random_count = try inpaintBiharmonicWithGrain(std.testing.allocator, prng.random(), &.{ 4.0, 5.0, 6.0 }, &.{0}, 1, 1, &out, .{ .value_kind = .uint16 });
    try std.testing.expectEqual(@as(usize, 0), random_count);
    try std.testing.expectEqualSlices(f64, &.{ 4.0, 5.0, 6.0 }, &out);
}

test "IR clean region validates dimensions and no-mask copy" {
    var out = [_]f64{ 0.0, 0.0, 0.0 };
    try std.testing.expectError(error.InvalidIrCleanBuffer, irCleanRegionWithNoise(std.testing.allocator, &.{ 1.0, 2.0 }, 1, 1, &.{1.0}, 1, 1, &out, null, &.{}, .{}));
    const result = try irCleanRegionWithNoise(std.testing.allocator, &.{ 1.0, 2.0, 3.0 }, 1, 1, &.{1.0}, 1, 1, &out, null, &.{}, .{
        .defect_mask = .{ .max_coverage = 1.0, .blur_size = 3 },
    });
    try std.testing.expectEqual(@as(usize, 0), result.defect_pixels_ir);
    try std.testing.expectEqualSlices(f64, &.{ 1.0, 2.0, 3.0 }, &out);

    var prng = std.Random.DefaultPrng.init(84);
    const random_result = try irCleanRegion(std.testing.allocator, prng.random(), &.{ 7.0, 8.0, 9.0 }, 1, 1, &.{1.0}, 1, 1, &out, null, .{
        .defect_mask = .{ .max_coverage = 1.0, .blur_size = 3 },
    });
    try std.testing.expectEqual(@as(usize, 0), random_result.defect_pixels_ir);
    try std.testing.expectEqualSlices(f64, &.{ 7.0, 8.0, 9.0 }, &out);
}
