const std = @import("std");
const builtin = @import("builtin");

const film_stocks = @import("../processing/film_stocks.zig");
const frames = @import("../processing/frames.zig");
const inversion = @import("../processing/inversion.zig");
const ir_processing = @import("../processing/ir.zig");
const ir_pure = @import("../processing/ir_pure.zig");
const render = @import("../processing/render.zig");

const allocation_alignment = std.mem.Alignment.@"16";

// Sanity ceiling far above any real dust-ROI padding; keeps the downstream
// usize -> i32 radius casts safe in the ReleaseFast Wasm artifact.
const max_ir_inpaint_padding: u32 = 4096;

pub const Status = enum(i32) {
    ok = 0,
    invalid_buffer = 1,
    invalid_dimensions = 2,
    invalid_stock = 3,
    out_of_memory = 4,
    processing_error = 5,
};

pub const StockId = enum(u32) {
    identity = 0,
    kodak_gold = 1,
    kodak_portra = 2,
};

pub const PreviewOptions = extern struct {
    width: u32,
    height: u32,
    stock: u32,
    dmin_r: f32,
    dmin_g: f32,
    dmin_b: f32,
    default_light: f32,
    contrast: f32,
    curve_k: f32,
    percentile_lo: f32,
    percentile_hi: f32,
    exposure_compensation: f32,
    color_temp: f32,
    color_tint: f32,
    percentile_sample_limit: u32,
};

pub const IrMaskOptions = extern struct {
    width: u32,
    height: u32,
    threshold: f32,
    hair_sensitivity: f32,
    min_area: u32,
    dilate_radius: u32,
    close_radius: u32,
    blur_size: u32,
    max_coverage: f32,
};

pub const IrMaskResizeOptions = extern struct {
    ir_width: u32,
    ir_height: u32,
    rgb_width: u32,
    rgb_height: u32,
};

pub const IrInpaintOptions = extern struct {
    width: u32,
    height: u32,
};

pub const IrInpaintGrainOptions = extern struct {
    width: u32,
    height: u32,
    padding: u32,
    grain_padding: u32,
    /// Gaussian sigma separating picture from grain; 0 means 2.5.
    grain_sigma: f32,
};

pub const IrAlignOptions = extern struct {
    width: u32,
    height: u32,
    tx: f32,
    ty: f32,
};

pub const IrEstimateOptions = extern struct {
    rgb_width: u32,
    rgb_height: u32,
    ir_width: u32,
    ir_height: u32,
    max_iterations: u32,
    ecc_scale: f32,
    epsilon: f32,
    reserved: u32 = 0,
};

pub const IrEstimateResult = extern struct {
    tx: f32,
    ty: f32,
    rho: f32,
    iterations: u32,
    shifted: u32,
    reserved: u32 = 0,
};

pub const FrameDetectOptions = extern struct {
    width: u32,
    height: u32,
    format: u32,
    frame_count_override: u32,
    detect_film_extent: u32,
    apply_clahe: u32,
    reserved0: u32 = 0,
    reserved1: u32 = 0,
};

pub const FrameDetectRect = extern struct {
    cx: f64,
    cy: f64,
    w: f64,
    h: f64,
    angle: f64,
};

pub const FrameDetectResult = extern struct {
    frame_count: u32,
    aspect: u32,
    has_rebate: u32,
    reserved: u32 = 0,
    rebate_cx: f64 = 0.0,
    rebate_cy: f64 = 0.0,
    rebate_w: f64 = 0.0,
    rebate_h: f64 = 0.0,
    rebate_angle: f64 = 0.0,
};

fn allocatorForCore() std.mem.Allocator {
    if (builtin.cpu.arch.isWasm()) return std.heap.wasm_allocator;
    return std.heap.page_allocator;
}

pub fn v600_wasm_alloc(len: usize) callconv(.c) usize {
    if (len == 0) return 0;
    const ptr = allocatorForCore().rawAlloc(len, allocation_alignment, @returnAddress()) orelse return 0;
    return @intFromPtr(ptr);
}

pub fn v600_wasm_free(ptr_addr: usize, len: usize) callconv(.c) void {
    if (ptr_addr == 0 or len == 0) return;
    const ptr: [*]u8 = @ptrFromInt(ptr_addr);
    allocatorForCore().rawFree(ptr[0..len], allocation_alignment, @returnAddress());
}

pub fn v600_preview_invert_u16_to_u8(
    raw_ptr: [*]const u16,
    raw_len: usize,
    output_ptr: [*]u8,
    output_len: usize,
    options_ptr: *const PreviewOptions,
) callconv(.c) i32 {
    const raw = raw_ptr[0..raw_len];
    const output = output_ptr[0..output_len];
    previewInvertProvidedDminU16ToU8(allocatorForCore(), raw, output, options_ptr.*) catch |err| {
        return @intFromEnum(statusFromError(err));
    };
    return @intFromEnum(Status.ok);
}

pub fn v600_export_invert_u16_to_u16(
    raw_ptr: [*]const u16,
    raw_len: usize,
    output_ptr: [*]u16,
    output_len: usize,
    options_ptr: *const PreviewOptions,
) callconv(.c) i32 {
    const raw = raw_ptr[0..raw_len];
    const output = output_ptr[0..output_len];
    exportInvertProvidedDminU16ToU16(allocatorForCore(), raw, output, options_ptr.*) catch |err| {
        return @intFromEnum(statusFromError(err));
    };
    return @intFromEnum(Status.ok);
}

pub fn v600_ir_make_defect_mask_u8(
    ir_ptr: [*]const u8,
    ir_len: usize,
    output_ptr: [*]u8,
    output_len: usize,
    options_ptr: *const IrMaskOptions,
) callconv(.c) i32 {
    const ir = ir_ptr[0..ir_len];
    const output = output_ptr[0..output_len];
    makeIrDefectMaskU8(allocatorForCore(), ir, output, options_ptr.*) catch |err| {
        return @intFromEnum(statusFromError(err));
    };
    return @intFromEnum(Status.ok);
}

pub fn v600_ir_make_defect_mask_f32(
    ir_ptr: [*]const f32,
    ir_len: usize,
    output_ptr: [*]u8,
    output_len: usize,
    options_ptr: *const IrMaskOptions,
) callconv(.c) i32 {
    const ir = ir_ptr[0..ir_len];
    const output = output_ptr[0..output_len];
    makeIrDefectMaskF32(allocatorForCore(), ir, output, options_ptr.*) catch |err| {
        return @intFromEnum(statusFromError(err));
    };
    return @intFromEnum(Status.ok);
}

pub fn v600_ir_resize_mask_to_rgb_u8(
    ir_mask_ptr: [*]const u8,
    ir_mask_len: usize,
    output_ptr: [*]u8,
    output_len: usize,
    options_ptr: *const IrMaskResizeOptions,
) callconv(.c) i32 {
    const ir_mask = ir_mask_ptr[0..ir_mask_len];
    const output = output_ptr[0..output_len];
    resizeIrMaskToRgbU8(allocatorForCore(), ir_mask, output, options_ptr.*) catch |err| {
        return @intFromEnum(statusFromError(err));
    };
    return @intFromEnum(Status.ok);
}

pub fn v600_ir_biharmonic_inpaint_u16(
    rgb_ptr: [*]const u16,
    rgb_len: usize,
    mask_ptr: [*]const u8,
    mask_len: usize,
    output_ptr: [*]u16,
    output_len: usize,
    options_ptr: *const IrInpaintOptions,
) callconv(.c) i32 {
    const rgb = rgb_ptr[0..rgb_len];
    const mask = mask_ptr[0..mask_len];
    const output = output_ptr[0..output_len];
    biharmonicInpaintRgb16(allocatorForCore(), rgb, mask, output, options_ptr.*) catch |err| {
        return @intFromEnum(statusFromError(err));
    };
    return @intFromEnum(Status.ok);
}

pub fn v600_ir_inpaint_grain_u16_with_noise(
    rgb_ptr: [*]const u16,
    rgb_len: usize,
    mask_ptr: [*]const u8,
    mask_len: usize,
    noise_ptr: [*]const f64,
    noise_len: usize,
    output_ptr: [*]u16,
    output_len: usize,
    options_ptr: *const IrInpaintGrainOptions,
) callconv(.c) i32 {
    const rgb = rgb_ptr[0..rgb_len];
    const mask = mask_ptr[0..mask_len];
    const noise = noise_ptr[0..noise_len];
    const output = output_ptr[0..output_len];
    _ = inpaintGrainRgb16WithNoise(allocatorForCore(), rgb, mask, noise, output, options_ptr.*) catch |err| {
        return @intFromEnum(statusFromError(err));
    };
    return @intFromEnum(Status.ok);
}

pub fn v600_ir_apply_translation_f32(
    ir_ptr: [*]const f32,
    ir_len: usize,
    output_ptr: [*]f32,
    output_len: usize,
    options_ptr: *const IrAlignOptions,
) callconv(.c) i32 {
    const ir = ir_ptr[0..ir_len];
    const output = output_ptr[0..output_len];
    applyIrTranslationF32(ir, output, options_ptr.*) catch |err| {
        return @intFromEnum(statusFromError(err));
    };
    return @intFromEnum(Status.ok);
}

pub fn v600_ir_estimate_translation_f32(
    rgb_ptr: [*]const f32,
    rgb_len: usize,
    ir_ptr: [*]const f32,
    ir_len: usize,
    result_ptr: *IrEstimateResult,
    options_ptr: *const IrEstimateOptions,
) callconv(.c) i32 {
    const rgb = rgb_ptr[0..rgb_len];
    const ir = ir_ptr[0..ir_len];
    estimateIrTranslationF32(allocatorForCore(), rgb, ir, result_ptr, options_ptr.*) catch |err| {
        return @intFromEnum(statusFromError(err));
    };
    return @intFromEnum(Status.ok);
}

pub fn v600_detect_frames_rgb16(
    raw_ptr: [*]const u16,
    raw_len: usize,
    frames_ptr: [*]FrameDetectRect,
    frames_len: usize,
    result_ptr: *FrameDetectResult,
    options_ptr: *const FrameDetectOptions,
) callconv(.c) i32 {
    const raw = raw_ptr[0..raw_len];
    const output_frames = frames_ptr[0..frames_len];
    detectFramesRgb16(allocatorForCore(), raw, output_frames, result_ptr, options_ptr.*) catch |err| {
        return @intFromEnum(statusFromError(err));
    };
    return @intFromEnum(Status.ok);
}

pub fn previewInvertProvidedDminU16ToU8(
    allocator: std.mem.Allocator,
    raw_rgb: []const u16,
    output: []u8,
    options: PreviewOptions,
) !void {
    try validatePreviewRequest(raw_rgb.len, output.len, options);
    const coeffs = stockCoefficients(options.stock) orelse return error.InvalidStock;
    const default_light: f32 = if (options.default_light > 0.0) options.default_light else 65535.0;

    const scene = try allocator.alloc(f32, raw_rgb.len);
    defer allocator.free(scene);
    const lut = try inversion.DensityLutF32.initF32(allocator, .{
        options.dmin_r,
        options.dmin_g,
        options.dmin_b,
    }, default_light);
    defer lut.deinit(allocator);

    try inversion.invertNegativeProvidedDminU16WithDensityLutF32OutputF32(
        raw_rgb,
        scene,
        lut,
        coeffs,
    );
    try render.renderToDisplayU8F32(allocator, scene, output, .{
        .contrast = if (options.contrast > 0.0) options.contrast else 1.4,
        .curve_k = if (options.curve_k > 0.0) options.curve_k else 5.0,
        .percentile_lo = options.percentile_lo,
        .percentile_hi = options.percentile_hi,
        .exposure_compensation = options.exposure_compensation,
        .color_temp = options.color_temp,
        .color_tint = options.color_tint,
        .percentile_sample_limit = if (options.percentile_sample_limit == 0)
            render.default_percentile_sample_limit
        else
            options.percentile_sample_limit,
    });
}

pub fn exportInvertProvidedDminU16ToU16(
    allocator: std.mem.Allocator,
    raw_rgb: []const u16,
    output: []u16,
    options: PreviewOptions,
) !void {
    try validatePreviewRequest(raw_rgb.len, output.len, options);
    const coeffs = stockCoefficients(options.stock) orelse return error.InvalidStock;
    const default_light: f32 = if (options.default_light > 0.0) options.default_light else 65535.0;

    const scene = try allocator.alloc(f32, raw_rgb.len);
    defer allocator.free(scene);
    const lut = try inversion.DensityLutF32.initF32(allocator, .{
        options.dmin_r,
        options.dmin_g,
        options.dmin_b,
    }, default_light);
    defer lut.deinit(allocator);

    try inversion.invertNegativeProvidedDminU16WithDensityLutF32OutputF32(
        raw_rgb,
        scene,
        lut,
        coeffs,
    );
    try render.renderToDisplayU16F32(allocator, scene, output, .{
        .contrast = if (options.contrast > 0.0) options.contrast else 1.4,
        .curve_k = if (options.curve_k > 0.0) options.curve_k else 5.0,
        .percentile_lo = options.percentile_lo,
        .percentile_hi = options.percentile_hi,
        .exposure_compensation = options.exposure_compensation,
        .color_temp = options.color_temp,
        .color_tint = options.color_tint,
        .percentile_sample_limit = if (options.percentile_sample_limit == 0)
            render.default_percentile_sample_limit
        else
            options.percentile_sample_limit,
    });
}

pub fn detectFramesRgb16(
    allocator: std.mem.Allocator,
    raw_rgb: []const u16,
    output_frames: []FrameDetectRect,
    result_out: *FrameDetectResult,
    options: FrameDetectOptions,
) !void {
    const width: usize = options.width;
    const height: usize = options.height;
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const pixel_count = try std.math.mul(usize, width, height);
    const expected_samples = try std.math.mul(usize, pixel_count, 3);
    if (raw_rgb.len != expected_samples) return error.InvalidDimensions;

    const format = frameFormatById(options.format) orelse return error.InvalidFilmFormat;
    var detected = try frames.detectFramesFromImage(
        allocator,
        std.mem.sliceAsBytes(raw_rgb),
        width,
        height,
        3,
        16,
        format,
        .{
            .frame_count_override = if (options.frame_count_override == 0) null else @intCast(options.frame_count_override),
            .detect_film_extent = options.detect_film_extent != 0,
            .apply_clahe = options.apply_clahe != 0,
        },
    );
    defer detected.deinit(allocator);

    var rebate: ?frames.RebateRect = null;
    if (detected.frames.len == 1) {
        if (try frames.singleFrameFallback(
            1,
            detected.frames[0],
            @floatFromInt(width),
            @floatFromInt(height),
        )) |fallback| {
            detected.frames[0] = fallback;
        }
    } else {
        rebate = frames.computeInterFrameRebate(detected.frames);
    }

    if (detected.frames.len > output_frames.len) return error.InvalidBuffer;
    result_out.* = .{
        .frame_count = @intCast(detected.frames.len),
        .aspect = aspectCode(detected.aspect),
        .has_rebate = if (rebate != null) 1 else 0,
    };
    if (rebate) |rect| {
        result_out.rebate_cx = rect.cx;
        result_out.rebate_cy = rect.cy;
        result_out.rebate_w = rect.w;
        result_out.rebate_h = rect.h;
        result_out.rebate_angle = rect.angle;
    }
    for (detected.frames, output_frames[0..detected.frames.len]) |source, *dest| {
        dest.* = .{
            .cx = source.cx,
            .cy = source.cy,
            .w = source.w,
            .h = source.h,
            .angle = source.angle,
        };
    }
}

pub fn makeIrDefectMaskU8(
    allocator: std.mem.Allocator,
    ir_u8: []const u8,
    output: []u8,
    options: IrMaskOptions,
) !void {
    try validateIrMaskRequest(ir_u8.len, output.len, options);
    const ir_f = try allocator.alloc(f64, ir_u8.len);
    defer allocator.free(ir_f);
    for (ir_u8, ir_f) |sample, *out| {
        out.* = @floatFromInt(sample);
    }
    const threshold = if (options.threshold > 0.0) @as(f64, @floatCast(options.threshold)) else 0.10;
    const hair_sensitivity = if (options.hair_sensitivity >= 0.0) @as(f64, @floatCast(options.hair_sensitivity)) else 0.10;
    const max_coverage = if (options.max_coverage >= 0.0) @as(f64, @floatCast(options.max_coverage)) else 0.03;
    _ = try ir_processing.makeDefectMask(allocator, ir_f, @intCast(options.width), @intCast(options.height), output, .{
        .threshold = threshold,
        .hair_sensitivity = hair_sensitivity,
        .min_area = @intCast(options.min_area),
        .dilate_radius = @intCast(options.dilate_radius),
        .close_radius = @intCast(options.close_radius),
        .blur_size = if (options.blur_size == 0) 301 else @intCast(options.blur_size),
        .max_coverage = max_coverage,
        .adaptive_precision = .f32,
        .adaptive_worker_count = 1,
    });
}

pub fn makeIrDefectMaskF32(
    allocator: std.mem.Allocator,
    ir_f32: []const f32,
    output: []u8,
    options: IrMaskOptions,
) !void {
    try validateIrMaskRequest(ir_f32.len, output.len, options);
    const ir_f = try allocator.alloc(f64, ir_f32.len);
    defer allocator.free(ir_f);
    for (ir_f32, ir_f) |sample, *out| {
        if (!std.math.isFinite(sample)) return error.InvalidBuffer;
        out.* = @floatCast(sample);
    }
    try makeIrDefectMaskF64(allocator, ir_f, output, options);
}

pub fn resizeIrMaskToRgbU8(
    allocator: std.mem.Allocator,
    ir_mask: []const u8,
    output: []u8,
    options: IrMaskResizeOptions,
) !void {
    try validateIrMaskResizeRequest(ir_mask.len, output.len, options);
    const ir_width: usize = @intCast(options.ir_width);
    const ir_height: usize = @intCast(options.ir_height);
    const rgb_width: usize = @intCast(options.rgb_width);
    const rgb_height: usize = @intCast(options.rgb_height);

    try ir_processing.resizeMaskToRgb(allocator, ir_mask, ir_width, ir_height, output, rgb_width, rgb_height);
}

pub fn biharmonicInpaintRgb16(
    allocator: std.mem.Allocator,
    rgb: []const u16,
    mask: []const u8,
    output: []u16,
    options: IrInpaintOptions,
) !void {
    try validateIrInpaintRequest(rgb.len, mask.len, output.len, options);
    const width: usize = @intCast(options.width);
    const height: usize = @intCast(options.height);
    const normalized = try allocator.alloc(f64, rgb.len);
    defer allocator.free(normalized);
    const repaired = try allocator.alloc(f64, rgb.len);
    defer allocator.free(repaired);
    for (rgb, normalized) |sample, *out| {
        out.* = @as(f64, @floatFromInt(sample)) / 65535.0;
    }
    try ir_processing.biharmonicInpaint(allocator, normalized, mask, width, height, 3, repaired);
    for (repaired, output) |value, *out| {
        out.* = normalizedF64ToU16(value);
    }
}

pub fn inpaintGrainRgb16WithNoise(
    allocator: std.mem.Allocator,
    rgb: []const u16,
    mask: []const u8,
    captured_noise: []const f64,
    output: []u16,
    options: IrInpaintGrainOptions,
) !usize {
    try validateIrInpaintGrainRequest(rgb.len, mask.len, output.len, options);
    const width: usize = @intCast(options.width);
    const height: usize = @intCast(options.height);

    const raw = try allocator.alloc(f64, rgb.len);
    defer allocator.free(raw);
    for (rgb, raw) |sample, *out| {
        out.* = @floatFromInt(sample);
    }
    const repaired = try allocator.alloc(f64, rgb.len);
    defer allocator.free(repaired);
    const inpainted_regions = try ir_processing.inpaintBiharmonicWithGrainFromNoise(
        allocator,
        raw,
        mask,
        width,
        height,
        repaired,
        captured_noise,
        .{
            .padding = @intCast(options.padding),
            .grain_padding = @intCast(options.grain_padding),
            .grain_sigma = if (options.grain_sigma > 0.0) options.grain_sigma else 2.5,
            .value_kind = .uint16,
        },
    );
    for (repaired, output) |value, *out| {
        out.* = @intFromFloat(value);
    }
    return inpainted_regions;
}

pub fn applyIrTranslationF32(
    ir_f32: []const f32,
    output: []f32,
    options: IrAlignOptions,
) !void {
    try validateIrAlignRequest(ir_f32.len, output.len, options);
    const width: usize = @intCast(options.width);
    const height: usize = @intCast(options.height);
    if (!std.math.isFinite(options.tx) or !std.math.isFinite(options.ty)) return error.InvalidBuffer;
    const tx: f64 = @floatCast(options.tx);
    const ty: f64 = @floatCast(options.ty);
    ir_processing.applyTranslation(f32, ir_f32, width, height, output, tx, ty);
}

pub fn estimateIrTranslationF32(
    allocator: std.mem.Allocator,
    rgb_f32: []const f32,
    ir_f32: []const f32,
    result: *IrEstimateResult,
    options: IrEstimateOptions,
) !void {
    try validateIrEstimateRequest(rgb_f32.len, ir_f32.len, options);
    const ecc_scale = if (options.ecc_scale > 0.0) options.ecc_scale else 0.125;
    const max_iterations = if (options.max_iterations == 0) 200 else options.max_iterations;
    const epsilon = if (options.epsilon > 0.0) @as(f64, @floatCast(options.epsilon)) else 1.0e-6;

    const estimate = try ir_pure.estimateTranslationEccF32(
        allocator,
        rgb_f32,
        @intCast(options.rgb_width),
        @intCast(options.rgb_height),
        ir_f32,
        @intCast(options.ir_width),
        @intCast(options.ir_height),
        @floatCast(ecc_scale),
        max_iterations,
        epsilon,
    );
    result.* = .{
        .tx = @floatCast(estimate.tx),
        .ty = @floatCast(estimate.ty),
        .rho = @floatCast(estimate.rho),
        .iterations = estimate.iterations,
        .shifted = if (@abs(estimate.tx) >= 0.5 or @abs(estimate.ty) >= 0.5) 1 else 0,
        .reserved = 0,
    };
}

fn makeIrDefectMaskF64(
    allocator: std.mem.Allocator,
    ir_f: []const f64,
    output: []u8,
    options: IrMaskOptions,
) !void {
    const threshold = if (options.threshold > 0.0) @as(f64, @floatCast(options.threshold)) else 0.10;
    const hair_sensitivity = if (options.hair_sensitivity >= 0.0) @as(f64, @floatCast(options.hair_sensitivity)) else 0.10;
    const max_coverage = if (options.max_coverage >= 0.0) @as(f64, @floatCast(options.max_coverage)) else 0.03;
    _ = try ir_processing.makeDefectMask(allocator, ir_f, @intCast(options.width), @intCast(options.height), output, .{
        .threshold = threshold,
        .hair_sensitivity = hair_sensitivity,
        .min_area = @intCast(options.min_area),
        .dilate_radius = @intCast(options.dilate_radius),
        .close_radius = @intCast(options.close_radius),
        .blur_size = if (options.blur_size == 0) 301 else @intCast(options.blur_size),
        .max_coverage = max_coverage,
        .adaptive_precision = .f32,
        .adaptive_worker_count = 1,
    });
}

fn validatePreviewRequest(raw_len: usize, output_len: usize, options: PreviewOptions) !void {
    if (raw_len == 0 or raw_len != output_len or raw_len % 3 != 0) return error.InvalidBuffer;
    if (options.width == 0 or options.height == 0) return error.InvalidDimensions;
    const pixel_count = try std.math.mul(usize, @as(usize, options.width), @as(usize, options.height));
    const expected_samples = try std.math.mul(usize, pixel_count, 3);
    if (expected_samples != raw_len) return error.InvalidDimensions;
    if (!std.math.isFinite(options.dmin_r) or !std.math.isFinite(options.dmin_g) or !std.math.isFinite(options.dmin_b)) {
        return error.InvalidBuffer;
    }
    if (options.default_light < 0.0 or !std.math.isFinite(options.default_light)) return error.InvalidBuffer;
}

fn validateIrMaskRequest(ir_len: usize, output_len: usize, options: IrMaskOptions) !void {
    if (ir_len == 0 or ir_len != output_len) return error.InvalidBuffer;
    if (options.width == 0 or options.height == 0) return error.InvalidDimensions;
    const pixel_count = try std.math.mul(usize, @as(usize, options.width), @as(usize, options.height));
    if (pixel_count != ir_len) return error.InvalidDimensions;
    if (!std.math.isFinite(options.threshold) or
        !std.math.isFinite(options.hair_sensitivity) or
        !std.math.isFinite(options.max_coverage))
    {
        return error.InvalidBuffer;
    }
}

fn validateIrMaskResizeRequest(ir_len: usize, output_len: usize, options: IrMaskResizeOptions) !void {
    if (ir_len == 0 or output_len == 0) return error.InvalidBuffer;
    if (options.ir_width == 0 or options.ir_height == 0 or options.rgb_width == 0 or options.rgb_height == 0) {
        return error.InvalidDimensions;
    }
    const ir_pixels = try std.math.mul(usize, @as(usize, options.ir_width), @as(usize, options.ir_height));
    if (ir_pixels != ir_len) return error.InvalidDimensions;
    const rgb_pixels = try std.math.mul(usize, @as(usize, options.rgb_width), @as(usize, options.rgb_height));
    if (rgb_pixels != output_len) return error.InvalidDimensions;
}

fn validateIrInpaintRequest(rgb_len: usize, mask_len: usize, output_len: usize, options: IrInpaintOptions) !void {
    if (rgb_len == 0 or mask_len == 0 or output_len == 0) return error.InvalidBuffer;
    if (options.width == 0 or options.height == 0) return error.InvalidDimensions;
    const pixels = try std.math.mul(usize, @as(usize, options.width), @as(usize, options.height));
    if (pixels != mask_len) return error.InvalidDimensions;
    const rgb_samples = try std.math.mul(usize, pixels, 3);
    if (rgb_samples != rgb_len or rgb_samples != output_len) return error.InvalidDimensions;
}

fn validateIrInpaintGrainRequest(rgb_len: usize, mask_len: usize, output_len: usize, options: IrInpaintGrainOptions) !void {
    if (rgb_len == 0 or mask_len == 0 or output_len == 0) return error.InvalidBuffer;
    if (options.width == 0 or options.height == 0) return error.InvalidDimensions;
    if (options.padding > max_ir_inpaint_padding or options.grain_padding > max_ir_inpaint_padding) return error.InvalidDimensions;
    if (!std.math.isFinite(options.grain_sigma) or options.grain_sigma < 0.0) return error.InvalidDimensions;
    const pixels = try std.math.mul(usize, @as(usize, options.width), @as(usize, options.height));
    if (pixels != mask_len) return error.InvalidDimensions;
    const rgb_samples = try std.math.mul(usize, pixels, 3);
    if (rgb_samples != rgb_len or rgb_samples != output_len) return error.InvalidDimensions;
}

fn validateIrAlignRequest(ir_len: usize, output_len: usize, options: IrAlignOptions) !void {
    if (ir_len == 0 or ir_len != output_len) return error.InvalidBuffer;
    if (options.width == 0 or options.height == 0) return error.InvalidDimensions;
    const pixel_count = try std.math.mul(usize, @as(usize, options.width), @as(usize, options.height));
    if (pixel_count != ir_len) return error.InvalidDimensions;
    if (!std.math.isFinite(options.tx) or !std.math.isFinite(options.ty)) return error.InvalidBuffer;
}

fn validateIrEstimateRequest(rgb_len: usize, ir_len: usize, options: IrEstimateOptions) !void {
    if (options.rgb_width == 0 or options.rgb_height == 0 or options.ir_width == 0 or options.ir_height == 0) {
        return error.InvalidDimensions;
    }
    const rgb_pixels = try std.math.mul(usize, @as(usize, options.rgb_width), @as(usize, options.rgb_height));
    const rgb_samples = try std.math.mul(usize, rgb_pixels, 3);
    if (rgb_len == 0 or rgb_len != rgb_samples) return error.InvalidBuffer;
    const ir_pixels = try std.math.mul(usize, @as(usize, options.ir_width), @as(usize, options.ir_height));
    if (ir_len == 0 or ir_len != ir_pixels) return error.InvalidBuffer;
    if (!std.math.isFinite(options.ecc_scale) or !std.math.isFinite(options.epsilon)) return error.InvalidBuffer;
    if (options.ecc_scale < 0.0 or options.epsilon < 0.0) return error.InvalidBuffer;
    if (options.ecc_scale > 1.0) return error.InvalidBuffer;
}

fn normalizedF64ToU16(value: f64) u16 {
    if (!std.math.isFinite(value) or value <= 0.0) return 0;
    if (value >= 1.0) return 65535;
    return @intFromFloat(@floor(value * 65535.0 + 0.5));
}

fn stockCoefficients(stock: u32) ?film_stocks.Coefficients {
    return switch (stock) {
        @intFromEnum(StockId.identity) => film_stocks.identity_coeffs,
        @intFromEnum(StockId.kodak_gold) => film_stocks.kodak_gold_coeffs,
        @intFromEnum(StockId.kodak_portra) => film_stocks.kodak_portra_coeffs,
        else => null,
    };
}

fn statusFromError(err: anyerror) Status {
    return switch (err) {
        error.InvalidBuffer,
        error.InvalidInversionBuffer,
        error.InvalidRenderBuffer,
        error.InvalidDensityLut,
        error.InvalidNormalizeReference,
        error.InvalidRenderPercentile,
        error.InvalidIrThresholdBuffer,
        error.InvalidIrThresholdBlur,
        error.InvalidIrThresholdValue,
        error.InvalidIrDefectMaskBuffer,
        error.InvalidIrLineBuffer,
        error.InvalidIrLineOption,
        error.InvalidIrMorphologyBuffer,
        error.InvalidIrComponentBuffer,
        error.InvalidIrCoverageBuffer,
        error.InvalidIrCoverageValue,
        error.InvalidIrAlignmentBuffer,
        error.InvalidIrAlignmentOffset,
        error.InvalidIrBiharmonicBuffer,
        error.InvalidIrInpaintBuffer,
        error.InvalidIrInpaintNoise,
        error.InvalidIrLocalGrainBuffer,
        error.InvalidIrGrainSynthesisBuffer,
        error.InvalidDetectFramesInput,
        error.InvalidDetectionGrayInput,
        error.InvalidFrameProfileBuffer,
        error.InvalidFrameProfileBand,
        error.InvalidStripAnalysisInput,
        error.InvalidDtwInput,
        error.InvalidGradientSnapInput,
        error.InvalidWeightedPeakInput,
        error.InvalidSizeCorrectionInput,
        error.InvalidTerminalRepairInput,
        error.InvalidCrossStripInput,
        error.InvalidTheilSenInput,
        error.InvalidSingleFrameFallbackInput,
        error.InvalidFilmExtentInput,
        error.InvalidClaheInput,
        error.InvalidRotationTransformInput,
        => .invalid_buffer,
        error.InvalidDimensions,
        error.Overflow,
        => .invalid_dimensions,
        error.InvalidStock,
        error.InvalidFilmFormat,
        error.UnsupportedDensityLutOutput,
        => .invalid_stock,
        error.OutOfMemory => .out_of_memory,
        else => .processing_error,
    };
}

fn frameFormatById(id: u32) ?frames.FilmFormat {
    return switch (id) {
        // 0 is the unset-field default; JS format ids start at 1 (35mm).
        0, 1 => frames.format_35mm,
        2 => frames.format_645,
        3 => frames.format_6x6,
        4 => frames.format_6x7,
        5 => frames.format_6x9,
        else => null,
    };
}

fn aspectCode(aspect: []const u8) u32 {
    if (std.mem.eql(u8, aspect, "24:36")) return 1;
    if (std.mem.eql(u8, aspect, "36:24")) return 2;
    if (std.mem.eql(u8, aspect, "41.5:56")) return 3;
    if (std.mem.eql(u8, aspect, "56:41.5")) return 4;
    if (std.mem.eql(u8, aspect, "56:56")) return 5;
    if (std.mem.eql(u8, aspect, "56:69")) return 6;
    if (std.mem.eql(u8, aspect, "69:56")) return 7;
    if (std.mem.eql(u8, aspect, "56:84")) return 8;
    if (std.mem.eql(u8, aspect, "84:56")) return 9;
    return 0;
}

fn defaultPreviewOptions(width: u32, height: u32) PreviewOptions {
    return .{
        .width = width,
        .height = height,
        .stock = @intFromEnum(StockId.kodak_gold),
        .dmin_r = 0.05,
        .dmin_g = 0.06,
        .dmin_b = 0.07,
        .default_light = 65535.0,
        .contrast = 1.4,
        .curve_k = 5.0,
        .percentile_lo = 0.5,
        .percentile_hi = 99.5,
        .exposure_compensation = 0.0,
        .color_temp = 0.0,
        .color_tint = 0.0,
        .percentile_sample_limit = render.default_percentile_sample_limit,
    };
}

test "wasm preview core writes deterministic final u8 output" {
    const allocator = std.testing.allocator;
    const raw = [_]u16{
        51000, 42000, 35000,
        45000, 39000, 31000,
        39000, 33000, 26000,
        33000, 27000, 21000,
    };
    var output_a: [raw.len]u8 = undefined;
    var output_b: [raw.len]u8 = undefined;
    const options = defaultPreviewOptions(2, 2);
    const expected = [_]u8{
        0,   8,   116,
        12,  44,  193,
        111, 141, 255,
        229, 251, 255,
    };

    try previewInvertProvidedDminU16ToU8(allocator, &raw, &output_a, options);
    try previewInvertProvidedDminU16ToU8(allocator, &raw, &output_b, options);
    try std.testing.expectEqualSlices(u8, &expected, &output_a);
    try std.testing.expectEqualSlices(u8, &output_a, &output_b);
}

test "wasm export core writes deterministic final u16 output" {
    const allocator = std.testing.allocator;
    const raw = [_]u16{
        51000, 42000, 35000,
        45000, 39000, 31000,
        39000, 33000, 26000,
        33000, 27000, 21000,
    };
    var preview: [raw.len]u8 = undefined;
    var output_a: [raw.len]u16 = undefined;
    var output_b: [raw.len]u16 = undefined;
    const options = defaultPreviewOptions(2, 2);

    try previewInvertProvidedDminU16ToU8(allocator, &raw, &preview, options);
    try exportInvertProvidedDminU16ToU16(allocator, &raw, &output_a, options);
    try exportInvertProvidedDminU16ToU16(allocator, &raw, &output_b, options);
    try std.testing.expectEqualSlices(u16, &output_a, &output_b);
    for (output_a, preview) |sample, preview_sample| {
        try std.testing.expectEqual(preview_sample, @as(u8, @intCast(sample >> 8)));
    }
}

test "wasm IR defect mask core writes deterministic u8 mask" {
    const allocator = std.testing.allocator;
    var ir = [_]u8{255} ** 81;
    ir[40] = 0;
    var mask: [ir.len]u8 = undefined;
    try makeIrDefectMaskU8(allocator, &ir, &mask, .{
        .width = 9,
        .height = 9,
        .threshold = 1.0,
        .hair_sensitivity = 2.0,
        .min_area = 1,
        .dilate_radius = 0,
        .close_radius = 0,
        .blur_size = 7,
        .max_coverage = 1.0,
    });
    var non_zero: usize = 0;
    for (mask) |value| {
        if (value != 0) non_zero += 1;
    }
    try std.testing.expectEqual(@as(u8, 255), mask[40]);
    try std.testing.expectEqual(@as(usize, 1), non_zero);
}

test "wasm IR mask resize matches native RGB mask branch" {
    const allocator = std.testing.allocator;
    const ir_mask = [_]u8{
        255, 0,
        0,   0,
    };
    var output: [16]u8 = undefined;
    try resizeIrMaskToRgbU8(allocator, &ir_mask, &output, .{
        .ir_width = 2,
        .ir_height = 2,
        .rgb_width = 4,
        .rgb_height = 4,
    });
    const expected = [_]u8{
        255, 255, 255, 0,
        255, 255, 255, 0,
        255, 255, 0,   0,
        0,   0,   0,   0,
    };
    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "wasm biharmonic RGB16 inpaint preserves unmasked pixels" {
    const allocator = std.testing.allocator;
    const rgb = [_]u16{
        0,     1000,  2000,
        10000, 11000, 12000,
        20000, 21000, 22000,
        30000, 31000, 32000,
    };
    const mask = [_]u8{
        0, 0,
        0, 255,
    };
    var output: [rgb.len]u16 = undefined;
    try biharmonicInpaintRgb16(allocator, &rgb, &mask, &output, .{
        .width = 2,
        .height = 2,
    });
    try std.testing.expectEqualSlices(u16, rgb[0..9], output[0..9]);
}

test "wasm preview core validates shape and stock id" {
    const allocator = std.testing.allocator;
    const raw = [_]u16{ 1, 2, 3 };
    var output: [raw.len]u8 = undefined;

    const bad_dimensions = defaultPreviewOptions(2, 1);
    try std.testing.expectError(error.InvalidDimensions, previewInvertProvidedDminU16ToU8(allocator, &raw, &output, bad_dimensions));

    var bad_stock = defaultPreviewOptions(1, 1);
    bad_stock.stock = 99;
    try std.testing.expectError(error.InvalidStock, previewInvertProvidedDminU16ToU8(allocator, &raw, &output, bad_stock));
}

test "wasm frame detect fills the result ABI" {
    // Where frames land is judged only on real scans with owner-verified
    // frames; this checks the call returns the requested frames.
    const allocator = std.testing.allocator;
    const width: usize = 140;
    const height: usize = 620;
    const raw = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(raw);
    fillTestRgb16Level(raw, width, height, 0, 0, width, height, 0.92);
    fillTestRgb16Level(raw, width, height, 0, 20, 140, 580, 0.65);
    fillTestRgb16Level(raw, width, height, 22, 86, 96, 144, 0.18);
    fillTestRgb16Level(raw, width, height, 22, 238, 96, 144, 0.18);
    fillTestRgb16Level(raw, width, height, 22, 390, 96, 144, 0.18);

    var frames_out: [8]FrameDetectRect = undefined;
    var result: FrameDetectResult = undefined;
    try detectFramesRgb16(allocator, raw, &frames_out, &result, .{
        .width = 140,
        .height = 620,
        .format = 1,
        .frame_count_override = 3,
        .detect_film_extent = 0,
        .apply_clahe = 0,
    });

    try std.testing.expectEqual(@as(u32, 3), result.frame_count);
    try std.testing.expectEqual(@as(u32, 1), result.aspect);
    for (frames_out[0..3]) |frame| {
        try std.testing.expect(std.math.isFinite(frame.cx) and std.math.isFinite(frame.cy) and std.math.isFinite(frame.angle));
        try std.testing.expect(frame.w > 0.0 and frame.h > 0.0);
    }
}

fn fillTestRgb16Level(pixels: []u16, image_width: usize, image_height: usize, x: usize, y: usize, w: usize, h: usize, level: f64) void {
    const sample: u16 = @intFromFloat(@min(65535.0, @max(0.0, @round(level * 65535.0))));
    const x1 = @min(image_width, x + w);
    const y1 = @min(image_height, y + h);
    for (y..y1) |yy| {
        for (x..x1) |xx| {
            const index = (yy * image_width + xx) * 3;
            pixels[index] = sample;
            pixels[index + 1] = sample;
            pixels[index + 2] = sample;
        }
    }
}
