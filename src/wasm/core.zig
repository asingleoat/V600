const std = @import("std");
const builtin = @import("builtin");

const film_stocks = @import("../processing/film_stocks.zig");
const frames = @import("../processing/frames.zig");
const inversion = @import("../processing/inversion.zig");
const ir_processing = @import("../processing/ir.zig");
const render = @import("../processing/render.zig");

const allocation_alignment = std.mem.Alignment.@"16";

// Sanity ceiling far above any real dust-ROI padding; keeps the downstream
// usize -> i32 radius casts safe in the ReleaseFast Wasm artifact.
const max_ir_inpaint_padding: u32 = 4096;

const roundF32 = ir_processing.roundF32;
const addClampedLimit = ir_processing.addClampedLimit;

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

pub fn v600_wasm_alloc(len: usize) usize {
    if (len == 0) return 0;
    const ptr = allocatorForCore().rawAlloc(len, allocation_alignment, @returnAddress()) orelse return 0;
    return @intFromPtr(ptr);
}

pub fn v600_wasm_free(ptr_addr: usize, len: usize) void {
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
) i32 {
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
) i32 {
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
) i32 {
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
) i32 {
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
) i32 {
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
) i32 {
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
) i32 {
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
) i32 {
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
) i32 {
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
) i32 {
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
        .min_area = if (options.min_area == 0) 3 else @intCast(options.min_area),
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
    const padding: usize = @intCast(options.padding);
    const grain_padding: usize = @intCast(options.grain_padding);
    const channels: usize = 3;

    @memcpy(output, rgb);

    const labels = try allocator.alloc(usize, mask.len);
    defer allocator.free(labels);
    var components = try ir_processing.labelMaskComponents8(allocator, mask, width, height, labels);
    defer components.deinit(allocator);

    if (components.items.len == 0) {
        if (captured_noise.len != 0) return error.InvalidIrInpaintNoise;
        return 0;
    }

    var noise_offset: usize = 0;
    for (components.items) |component| {
        const x0 = component.left -| padding;
        const y0 = component.top -| padding;
        const x1 = addClampedLimit(component.right, padding, width);
        const y1 = addClampedLimit(component.bottom, padding, height);
        const roi_width = x1 - x0;
        const roi_height = y1 - y0;
        const roi_pixels = roi_width * roi_height;
        const roi_values = roi_pixels * channels;
        if (captured_noise.len - noise_offset < roi_values) return error.InvalidIrInpaintNoise;

        const roi_rgb = try allocator.alloc(f64, roi_values);
        defer allocator.free(roi_rgb);
        const roi_mask = try allocator.alloc(u8, roi_pixels);
        defer allocator.free(roi_mask);

        for (0..roi_height) |ry| {
            for (0..roi_width) |rx| {
                const source_pixel = (y0 + ry) * width + (x0 + rx);
                const roi_pixel = ry * roi_width + rx;
                roi_mask[roi_pixel] = if (labels[source_pixel] == component.label) 255 else 0;
                for (0..channels) |channel| {
                    roi_rgb[roi_pixel * channels + channel] = roundF32(
                        @as(f64, @floatFromInt(output[source_pixel * channels + channel])) / 65535.0,
                    );
                }
            }
        }

        const estimate = try estimateLocalGrainWasm(allocator, roi_rgb, roi_mask, roi_width, roi_height, grain_padding);
        defer estimate.deinit(allocator);

        const repaired_signal = try allocator.alloc(f64, roi_values);
        defer allocator.free(repaired_signal);
        try ir_processing.biharmonicInpaint(allocator, estimate.signal, roi_mask, roi_width, roi_height, channels, repaired_signal);
        for (repaired_signal) |*value| {
            value.* = roundF32(value.*);
        }

        const grain = try allocator.alloc(f64, roi_values);
        defer allocator.free(grain);
        const component_noise = captured_noise[noise_offset..][0..roi_values];
        noise_offset += roi_values;
        try synthesizeGrainFromNoiseWasm(
            allocator,
            component_noise,
            roi_width,
            roi_height,
            estimate.grain_std[0..],
            estimate.spectrum,
            channels,
            grain,
        );

        for (0..roi_height) |ry| {
            for (0..roi_width) |rx| {
                const roi_pixel = ry * roi_width + rx;
                if (roi_mask[roi_pixel] == 0) continue;
                const dest_pixel = (y0 + ry) * width + (x0 + rx);
                for (0..channels) |channel| {
                    const index = roi_pixel * channels + channel;
                    const repaired_with_grain = roundF32(repaired_signal[index] + grain[index]);
                    const scaled = roundF32(repaired_with_grain * 65535.0);
                    output[dest_pixel * channels + channel] = clippedStorageU16(scaled);
                }
            }
        }
    }

    if (noise_offset != captured_noise.len) return error.InvalidIrInpaintNoise;
    return components.items.len;
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
    const rgb_width: usize = @intCast(options.rgb_width);
    const rgb_height: usize = @intCast(options.rgb_height);
    const ir_width: usize = @intCast(options.ir_width);
    const ir_height: usize = @intCast(options.ir_height);
    const ir_pixels = ir_width * ir_height;
    const ecc_scale = if (options.ecc_scale > 0.0) options.ecc_scale else 0.125;
    const max_iterations = if (options.max_iterations == 0) 200 else options.max_iterations;
    const epsilon = if (options.epsilon > 0.0) @as(f64, @floatCast(options.epsilon)) else 1.0e-6;

    const gray_ir = try allocator.alloc(u8, ir_pixels);
    defer allocator.free(gray_ir);
    try rgbToIrGrayU8(allocator, rgb_f32, rgb_width, rgb_height, gray_ir, ir_width, ir_height);

    const ir_u8 = try allocator.alloc(u8, ir_pixels);
    defer allocator.free(ir_u8);
    try samplesToU8(ir_f32, ir_u8);

    const small_width = @max(@as(usize, 1), @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(ir_width)) * @as(f64, @floatCast(ecc_scale))))));
    const small_height = @max(@as(usize, 1), @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(ir_height)) * @as(f64, @floatCast(ecc_scale))))));
    if (small_width < 2 or small_height < 2) return error.InvalidDimensions;
    const small_pixels = small_width * small_height;

    const template_u8 = try allocator.alloc(u8, small_pixels);
    defer allocator.free(template_u8);
    const image_u8 = try allocator.alloc(u8, small_pixels);
    defer allocator.free(image_u8);
    areaResizeU8(gray_ir, ir_width, ir_height, template_u8, small_width, small_height);
    areaResizeU8(ir_u8, ir_width, ir_height, image_u8, small_width, small_height);

    const template_f = try allocator.alloc(f32, small_pixels);
    defer allocator.free(template_f);
    const image_f = try allocator.alloc(f32, small_pixels);
    defer allocator.free(image_f);
    for (template_u8, template_f) |sample, *out| out.* = @floatFromInt(sample);
    for (image_u8, image_f) |sample, *out| out.* = @floatFromInt(sample);
    gaussianBlur5Reflect101InPlace(allocator, template_f, small_width, small_height) catch |err| return err;
    gaussianBlur5Reflect101InPlace(allocator, image_f, small_width, small_height) catch |err| return err;

    const gradient_x = try allocator.alloc(f32, small_pixels);
    defer allocator.free(gradient_x);
    const gradient_y = try allocator.alloc(f32, small_pixels);
    defer allocator.free(gradient_y);
    gradientCentralReflect101(image_f, small_width, small_height, gradient_x, gradient_y);

    const work = try EccWork.init(allocator, small_pixels);
    defer work.deinit(allocator);

    var tx: f64 = 0.0;
    var ty: f64 = 0.0;
    var rho: f64 = -1.0;
    var last_rho: f64 = -epsilon;
    var iterations: u32 = 0;
    while (iterations < max_iterations and @abs(rho - last_rho) >= epsilon) {
        iterations += 1;
        try eccTranslationIteration(template_f, image_f, gradient_x, gradient_y, small_width, small_height, &tx, &ty, &rho, &last_rho, work);
    }

    const full_tx = tx / @as(f64, @floatCast(ecc_scale));
    const full_ty = ty / @as(f64, @floatCast(ecc_scale));
    result.* = .{
        .tx = @floatCast(full_tx),
        .ty = @floatCast(full_ty),
        .rho = @floatCast(rho),
        .iterations = iterations,
        .shifted = if (@abs(full_tx) >= 0.5 or @abs(full_ty) >= 0.5) 1 else 0,
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
        .min_area = if (options.min_area == 0) 3 else @intCast(options.min_area),
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

fn rgbToIrGrayU8(
    allocator: std.mem.Allocator,
    rgb_f32: []const f32,
    rgb_width: usize,
    rgb_height: usize,
    output: []u8,
    ir_width: usize,
    ir_height: usize,
) !void {
    const rgb_pixels = rgb_width * rgb_height;
    const gray_rgb = try allocator.alloc(u8, rgb_pixels);
    defer allocator.free(gray_rgb);
    var max_value: f32 = 0.0;
    for (rgb_f32) |sample| {
        if (!std.math.isFinite(sample)) return error.InvalidBuffer;
        if (sample > max_value) max_value = sample;
    }
    const denominator = @as(f64, @floatCast(max_value)) / 255.0 + 1.0e-10;
    for (0..rgb_pixels) |pixel| {
        const base = pixel * 3;
        const r = scaledU8(rgb_f32[base], denominator);
        const g = scaledU8(rgb_f32[base + 1], denominator);
        const b = scaledU8(rgb_f32[base + 2], denominator);
        const gray = (@as(u32, r) * 77 + @as(u32, g) * 150 + @as(u32, b) * 29 + 128) >> 8;
        gray_rgb[pixel] = @intCast(gray);
    }
    if (rgb_width == ir_width and rgb_height == ir_height) {
        @memcpy(output, gray_rgb);
    } else {
        areaResizeU8(gray_rgb, rgb_width, rgb_height, output, ir_width, ir_height);
    }
}

fn samplesToU8(input: []const f32, output: []u8) !void {
    var max_value: f32 = 0.0;
    for (input) |sample| {
        if (!std.math.isFinite(sample)) return error.InvalidBuffer;
        if (sample > max_value) max_value = sample;
    }
    const denominator = @as(f64, @floatCast(max_value)) / 255.0 + 1.0e-10;
    for (input, output) |sample, *out| {
        out.* = scaledU8(sample, denominator);
    }
}

fn scaledU8(sample: f32, denominator: f64) u8 {
    if (sample <= 0.0 or denominator <= 0.0) return 0;
    const scaled = @as(f64, @floatCast(sample)) / denominator;
    if (scaled >= 255.0) return 255;
    return @intFromFloat(@floor(scaled));
}

fn normalizedF64ToU16(value: f64) u16 {
    if (!std.math.isFinite(value) or value <= 0.0) return 0;
    if (value >= 1.0) return 65535;
    return @intFromFloat(@floor(value * 65535.0 + 0.5));
}

fn clippedStorageU16(value: f64) u16 {
    if (!std.math.isFinite(value) or value <= 0.0) return 0;
    if (value >= 65535.0) return 65535;
    return @intFromFloat(value);
}

fn areaResizeU8(input: []const u8, in_width: usize, in_height: usize, output: []u8, out_width: usize, out_height: usize) void {
    const scale_x = @as(f64, @floatFromInt(in_width)) / @as(f64, @floatFromInt(out_width));
    const scale_y = @as(f64, @floatFromInt(in_height)) / @as(f64, @floatFromInt(out_height));
    for (0..out_height) |out_y| {
        const y0: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(out_y)) * scale_y));
        const y1: usize = @max(y0 + 1, @as(usize, @intFromFloat(@floor(@as(f64, @floatFromInt(out_y + 1)) * scale_y))));
        for (0..out_width) |out_x| {
            const x0: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(out_x)) * scale_x));
            const x1: usize = @max(x0 + 1, @as(usize, @intFromFloat(@floor(@as(f64, @floatFromInt(out_x + 1)) * scale_x))));
            var sum: u64 = 0;
            var count: u64 = 0;
            for (y0..@min(y1, in_height)) |src_y| {
                for (x0..@min(x1, in_width)) |src_x| {
                    sum += input[src_y * in_width + src_x];
                    count += 1;
                }
            }
            output[out_y * out_width + out_x] = @intCast((sum + count / 2) / count);
        }
    }
}

const LocalGrainEstimateWasm = struct {
    grain_std: [3]f64,
    signal: []f64,
    spectrum: ?[]f64,

    fn deinit(self: LocalGrainEstimateWasm, allocator: std.mem.Allocator) void {
        if (self.spectrum) |spectrum| allocator.free(spectrum);
        allocator.free(self.signal);
    }
};

fn estimateLocalGrainWasm(
    allocator: std.mem.Allocator,
    roi_rgb: []const f64,
    roi_mask: []const u8,
    width: usize,
    height: usize,
    grain_padding: usize,
) !LocalGrainEstimateWasm {
    if (width == 0 or height == 0 or roi_rgb.len != width * height * 3 or roi_mask.len != width * height) {
        return error.InvalidIrLocalGrainBuffer;
    }

    const rgb_f32 = try allocator.alloc(f32, roi_rgb.len);
    defer allocator.free(rgb_f32);
    for (roi_rgb, rgb_f32) |value, *out| {
        if (!std.math.isFinite(value)) return error.InvalidIrLocalGrainBuffer;
        out.* = @floatCast(value);
    }

    const signal_f32 = try allocator.alloc(f32, roi_rgb.len);
    defer allocator.free(signal_f32);
    try gaussianBlurRgbSigmaF32(allocator, rgb_f32, width, height, 2.5, signal_f32);

    const signal = try allocator.alloc(f64, roi_rgb.len);
    errdefer allocator.free(signal);
    for (signal_f32, signal) |value, *out| {
        out.* = @floatCast(value);
    }

    const dilated = try allocator.alloc(u8, roi_mask.len);
    defer allocator.free(dilated);
    try dilateMaskOpenCvEllipse(allocator, roi_mask, width, height, grain_padding, dilated);

    var surround_count: usize = 0;
    var clean_count: usize = 0;
    for (roi_mask, dilated) |mask_value, dilated_value| {
        const masked = mask_value != 0;
        if (!masked) clean_count += 1;
        if (dilated_value != 0 and !masked) surround_count += 1;
    }

    var grain_std = [_]f64{ 0.0, 0.0, 0.0 };
    if (surround_count > 10) {
        var sum = [_]f64{ 0.0, 0.0, 0.0 };
        var sum_sq = [_]f64{ 0.0, 0.0, 0.0 };
        for (0..height) |y| {
            for (0..width) |x| {
                const pixel = y * width + x;
                if (dilated[pixel] == 0 or roi_mask[pixel] != 0) continue;
                for (0..3) |channel| {
                    const index = pixel * 3 + channel;
                    const grain = rgb_f32[index] - signal_f32[index];
                    const grain_f64: f64 = @floatCast(grain);
                    sum[channel] += grain_f64;
                    sum_sq[channel] += grain_f64 * grain_f64;
                }
            }
        }
        const count_f = @as(f64, @floatFromInt(surround_count));
        for (0..3) |channel| {
            const mean = sum[channel] / count_f;
            var variance = sum_sq[channel] / count_f - mean * mean;
            if (variance < 0.0) variance = 0.0;
            grain_std[channel] = roundF32(@sqrt(variance));
        }
    }

    const spectrum = try estimateGrainSpectrumWasm(
        allocator,
        rgb_f32,
        signal_f32,
        roi_mask,
        width,
        height,
        surround_count,
        clean_count,
    );
    errdefer if (spectrum) |values| allocator.free(values);

    return .{
        .grain_std = grain_std,
        .signal = signal,
        .spectrum = spectrum,
    };
}

fn estimateGrainSpectrumWasm(
    allocator: std.mem.Allocator,
    rgb_f32: []const f32,
    signal_f32: []const f32,
    mask: []const u8,
    width: usize,
    height: usize,
    surround_count: usize,
    clean_count: usize,
) !?[]f64 {
    const r_max = @min(width, height) / 2;
    if (surround_count <= 64 or r_max == 0) return null;

    const spectrum_sum = try allocator.alloc(f64, r_max);
    errdefer allocator.free(spectrum_sum);
    @memset(spectrum_sum, 0.0);

    const ring_count = try allocator.alloc(usize, r_max);
    defer allocator.free(ring_count);
    @memset(ring_count, 0);

    const dft_input = try allocator.alloc(f64, width * height);
    defer allocator.free(dft_input);

    const cy = height / 2;
    const cx = width / 2;
    const y_shift = (height + 1) / 2;
    const x_shift = (width + 1) / 2;

    for (0..3) |channel| {
        for (0..height) |y| {
            const wy = if (height > 1)
                0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(height - 1)))
            else
                1.0;
            for (0..width) |x| {
                const wx = if (width > 1)
                    0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(width - 1)))
                else
                    1.0;
                const pixel = y * width + x;
                var grain = @as(f64, @floatCast(rgb_f32[pixel * 3 + channel] - signal_f32[pixel * 3 + channel]));
                if (mask[pixel] != 0) grain = 0.0;
                dft_input[pixel] = grain * wy * wx;
            }
        }

        const dft_output = try dft2RealToComplex(allocator, dft_input, width, height);
        defer allocator.free(dft_output);
        for (0..height) |y| {
            const src_y = (y + y_shift) % height;
            const dy = @as(f64, @floatFromInt(@as(isize, @intCast(y)) - @as(isize, @intCast(cy))));
            for (0..width) |x| {
                const src_x = (x + x_shift) % width;
                const dx = @as(f64, @floatFromInt(@as(isize, @intCast(x)) - @as(isize, @intCast(cx))));
                const ri: usize = @intFromFloat(@sqrt(dx * dx + dy * dy));
                if (ri >= r_max) continue;
                const value = dft_output[src_y * width + src_x];
                spectrum_sum[ri] += (value.re * value.re + value.im * value.im) / 3.0;
                if (channel == 0) ring_count[ri] += 1;
            }
        }
    }

    var spectrum_total: f64 = 0.0;
    const clean_fraction = @as(f64, @floatFromInt(clean_count)) / @as(f64, @floatFromInt(width * height));
    for (0..r_max) |r| {
        if (ring_count[r] > 0) {
            spectrum_sum[r] /= @floatFromInt(ring_count[r]);
        }
        if (clean_fraction > 0.1) {
            spectrum_sum[r] /= clean_fraction * clean_fraction;
        }
        spectrum_total += spectrum_sum[r];
    }

    if (spectrum_total <= 0.0) {
        allocator.free(spectrum_sum);
        return null;
    }
    for (spectrum_sum) |*value| {
        value.* /= spectrum_total;
    }
    return spectrum_sum;
}

fn synthesizeGrainFromNoiseWasm(
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

    const plane = try allocator.alloc(f64, width * height);
    defer allocator.free(plane);
    for (0..channels) |channel| {
        for (0..height) |y| {
            for (0..width) |x| {
                plane[y * width + x] = noise[(channel * height + y) * width + x];
            }
        }

        const dft = try dft2RealToComplex(allocator, plane, width, height);
        defer allocator.free(dft);
        shapeSpectrumInPlace(dft, width, height, grain_spectrum);

        try inverseDft2ComplexToReal(allocator, dft, width, height, plane);
        var sum: f64 = 0.0;
        var sum_sq: f64 = 0.0;
        for (plane) |value| {
            sum += value;
            sum_sq += value * value;
        }
        const count = @as(f64, @floatFromInt(plane.len));
        const mean = sum / count;
        var variance = sum_sq / count - mean * mean;
        if (variance < 0.0) variance = 0.0;
        const noise_std = @sqrt(variance);

        for (0..height) |y| {
            for (0..width) |x| {
                const pixel = y * width + x;
                var shaped = plane[pixel];
                if (noise_std > 0.0) shaped /= noise_std;
                output[pixel * channels + channel] = roundF32(shaped * grain_std[channel]);
            }
        }
    }
}

fn gaussianBlurRgbSigmaF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    width: usize,
    height: usize,
    sigma: f64,
    output: []f32,
) !void {
    if (input.len != width * height * 3 or output.len != input.len) return error.InvalidIrLocalGrainBuffer;
    const kernel_size = openCvGaussianKernelSizeForF32(sigma);
    const kernel = try gaussianKernelSigmaF32(allocator, sigma, kernel_size);
    defer allocator.free(kernel);

    const temp = try allocator.alloc(f32, input.len);
    defer allocator.free(temp);
    const radius: i32 = @intCast(kernel_size / 2);
    for (0..height) |y| {
        for (0..width) |x| {
            for (0..3) |channel| {
                var sum: f32 = 0.0;
                for (kernel, 0..) |weight, k| {
                    const offset = @as(i32, @intCast(k)) - radius;
                    const sx = reflect101Index(@as(i32, @intCast(x)) + offset, width);
                    sum += input[(y * width + sx) * 3 + channel] * weight;
                }
                temp[(y * width + x) * 3 + channel] = sum;
            }
        }
    }
    for (0..height) |y| {
        for (0..width) |x| {
            for (0..3) |channel| {
                var sum: f32 = 0.0;
                for (kernel, 0..) |weight, k| {
                    const offset = @as(i32, @intCast(k)) - radius;
                    const sy = reflect101Index(@as(i32, @intCast(y)) + offset, height);
                    sum += temp[(sy * width + x) * 3 + channel] * weight;
                }
                output[(y * width + x) * 3 + channel] = sum;
            }
        }
    }
}

fn openCvGaussianKernelSizeForF32(sigma: f64) usize {
    const raw = @floor(sigma * 8.0 + 1.0 + 0.5);
    var size: usize = @intFromFloat(raw);
    size |= 1;
    return @max(size, 3);
}

fn gaussianKernelSigmaF32(allocator: std.mem.Allocator, sigma: f64, kernel_size: usize) ![]f32 {
    const kernel = try allocator.alloc(f32, kernel_size);
    errdefer allocator.free(kernel);
    const half = (@as(f64, @floatFromInt(kernel_size)) - 1.0) * 0.5;
    var sum: f64 = 0.0;
    for (kernel, 0..) |*weight, index| {
        const x = @as(f64, @floatFromInt(index)) - half;
        const value = @exp(-(x * x) / (2.0 * sigma * sigma));
        weight.* = @floatCast(value);
        sum += value;
    }
    const inv_sum: f32 = @floatCast(1.0 / sum);
    for (kernel) |*weight| {
        weight.* *= inv_sum;
    }
    return kernel;
}

fn dilateMaskOpenCvEllipse(
    allocator: std.mem.Allocator,
    input: []const u8,
    width: usize,
    height: usize,
    radius: usize,
    output: []u8,
) !void {
    if (input.len != width * height or output.len != input.len) return error.InvalidIrLocalGrainBuffer;
    const spans = try openCvEllipseSpans(allocator, radius);
    defer allocator.free(spans);
    const height_i: i32 = @intCast(height);
    const width_i: i32 = @intCast(width);
    @memset(output, 0);
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

const EllipseSpan = struct {
    y_offset: i32,
    x_min: i32,
    x_max: i32,
};

// Matches cv::getStructuringElement(MORPH_ELLIPSE); for radius >= 2 this
// differs from the skimage-style disk in ir.zig ellipseKernelRowSpans, so the
// two must not be deduplicated.
fn openCvEllipseSpans(allocator: std.mem.Allocator, radius: usize) ![]EllipseSpan {
    const diameter = radius * 2 + 1;
    const spans = try allocator.alloc(EllipseSpan, diameter);
    errdefer allocator.free(spans);
    if (radius == 0) {
        spans[0] = .{ .y_offset = 0, .x_min = 0, .x_max = 0 };
        return spans;
    }
    const r_i: i32 = @intCast(radius);
    const r = @as(f64, @floatFromInt(radius));
    const r_sq = r * r;
    for (0..diameter) |y| {
        const dy_i = @as(i32, @intCast(y)) - r_i;
        const dy = @as(f64, @floatFromInt(dy_i));
        const dx_f = r * @sqrt(@max(0.0, (r_sq - dy * dy) / r_sq));
        const dx_i: i32 = @intFromFloat(@floor(dx_f + 0.5));
        spans[y] = .{
            .y_offset = dy_i,
            .x_min = -dx_i,
            .x_max = dx_i,
        };
    }
    return spans;
}

const Complex = struct {
    re: f64,
    im: f64,
};

fn dft2RealToComplex(
    allocator: std.mem.Allocator,
    input: []const f64,
    width: usize,
    height: usize,
) ![]Complex {
    if (input.len != width * height) return error.InvalidBuffer;
    const temp = try allocator.alloc(Complex, input.len);
    defer allocator.free(temp);
    const output = try allocator.alloc(Complex, input.len);
    errdefer allocator.free(output);

    const tau = 2.0 * std.math.pi;
    for (0..height) |y| {
        for (0..width) |u| {
            var sum = Complex{ .re = 0.0, .im = 0.0 };
            for (0..width) |x| {
                const angle = -tau * @as(f64, @floatFromInt(u * x)) / @as(f64, @floatFromInt(width));
                const value = input[y * width + x];
                sum.re += value * @cos(angle);
                sum.im += value * @sin(angle);
            }
            temp[y * width + u] = sum;
        }
    }

    for (0..height) |v| {
        for (0..width) |u| {
            var sum = Complex{ .re = 0.0, .im = 0.0 };
            for (0..height) |y| {
                const angle = -tau * @as(f64, @floatFromInt(v * y)) / @as(f64, @floatFromInt(height));
                const twiddle = Complex{ .re = @cos(angle), .im = @sin(angle) };
                const value = temp[y * width + u];
                sum.re += value.re * twiddle.re - value.im * twiddle.im;
                sum.im += value.re * twiddle.im + value.im * twiddle.re;
            }
            output[v * width + u] = sum;
        }
    }
    return output;
}

fn inverseDft2ComplexToReal(
    allocator: std.mem.Allocator,
    input: []const Complex,
    width: usize,
    height: usize,
    output: []f64,
) !void {
    if (input.len != width * height or output.len != input.len) return error.InvalidBuffer;
    const temp = try allocator.alloc(Complex, input.len);
    defer allocator.free(temp);
    const tau = 2.0 * std.math.pi;

    for (0..height) |v| {
        for (0..width) |x| {
            var sum = Complex{ .re = 0.0, .im = 0.0 };
            for (0..width) |u| {
                const angle = tau * @as(f64, @floatFromInt(u * x)) / @as(f64, @floatFromInt(width));
                const twiddle = Complex{ .re = @cos(angle), .im = @sin(angle) };
                const value = input[v * width + u];
                sum.re += value.re * twiddle.re - value.im * twiddle.im;
                sum.im += value.re * twiddle.im + value.im * twiddle.re;
            }
            temp[v * width + x] = sum;
        }
    }

    const scale = 1.0 / @as(f64, @floatFromInt(width * height));
    for (0..height) |y| {
        for (0..width) |x| {
            var sum = Complex{ .re = 0.0, .im = 0.0 };
            for (0..height) |v| {
                const angle = tau * @as(f64, @floatFromInt(v * y)) / @as(f64, @floatFromInt(height));
                const twiddle = Complex{ .re = @cos(angle), .im = @sin(angle) };
                const value = temp[v * width + x];
                sum.re += value.re * twiddle.re - value.im * twiddle.im;
                sum.im += value.re * twiddle.im + value.im * twiddle.re;
            }
            output[y * width + x] = sum.re * scale;
        }
    }
}

fn shapeSpectrumInPlace(values: []Complex, width: usize, height: usize, grain_spectrum: ?[]const f64) void {
    const cy = height / 2;
    const cx = width / 2;
    const y_shift = height / 2;
    const x_shift = width / 2;
    const spectrum_len = if (grain_spectrum) |spectrum| spectrum.len else 0;

    for (0..height) |y| {
        const centered_y = (y + y_shift) % height;
        const dy = @as(f64, @floatFromInt(@as(isize, @intCast(centered_y)) - @as(isize, @intCast(cy))));
        for (0..width) |x| {
            const centered_x = (x + x_shift) % width;
            const dx = @as(f64, @floatFromInt(@as(isize, @intCast(centered_x)) - @as(isize, @intCast(cx))));
            const radius = @sqrt(dx * dx + dy * dy);
            var amp: f64 = 1.0;
            if (grain_spectrum != null and spectrum_len > 4) {
                const spectrum = grain_spectrum.?;
                if (radius >= @as(f64, @floatFromInt(spectrum_len - 1))) {
                    amp = @sqrt(@max(spectrum[spectrum_len - 1], 0.0));
                } else {
                    const lower: usize = @intFromFloat(@floor(radius));
                    const upper = lower + 1;
                    const t = radius - @as(f64, @floatFromInt(lower));
                    const low = @sqrt(@max(spectrum[lower], 0.0));
                    const high = @sqrt(@max(spectrum[upper], 0.0));
                    amp = low * (1.0 - t) + high * t;
                }
            } else {
                const safe_radius = if (radius > 0.0) radius else 1.0;
                amp = 1.0 / safe_radius;
            }
            const index = y * width + x;
            values[index].re *= amp;
            values[index].im *= amp;
        }
    }
}

fn gaussianBlur5Reflect101InPlace(allocator: std.mem.Allocator, values: []f32, width: usize, height: usize) !void {
    const temp = try allocator.alloc(f32, values.len);
    defer allocator.free(temp);
    const weights = [_]f32{ 0.0625, 0.25, 0.375, 0.25, 0.0625 };
    for (0..height) |y| {
        for (0..width) |x| {
            var sum: f32 = 0.0;
            inline for (0..5) |k| {
                const offset: i32 = @as(i32, @intCast(k)) - 2;
                const src_x = reflect101Index(@as(i32, @intCast(x)) + offset, width);
                sum += values[y * width + src_x] * weights[k];
            }
            temp[y * width + x] = sum;
        }
    }
    for (0..height) |y| {
        for (0..width) |x| {
            var sum: f32 = 0.0;
            inline for (0..5) |k| {
                const offset: i32 = @as(i32, @intCast(k)) - 2;
                const src_y = reflect101Index(@as(i32, @intCast(y)) + offset, height);
                sum += temp[src_y * width + x] * weights[k];
            }
            values[y * width + x] = sum;
        }
    }
}

fn gradientCentralReflect101(input: []const f32, width: usize, height: usize, output_x: []f32, output_y: []f32) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const x_i: i32 = @intCast(x);
            const y_i: i32 = @intCast(y);
            const left = input[y * width + reflect101Index(x_i - 1, width)];
            const right = input[y * width + reflect101Index(x_i + 1, width)];
            const up = input[reflect101Index(y_i - 1, height) * width + x];
            const down = input[reflect101Index(y_i + 1, height) * width + x];
            output_x[y * width + x] = (right - left) * 0.5;
            output_y[y * width + x] = (down - up) * 0.5;
        }
    }
}

const EccWork = struct {
    image: []f32,
    gradient_x: []f32,
    gradient_y: []f32,
    mask: []u8,
    template_zm: []f32,

    fn init(allocator: std.mem.Allocator, len: usize) !EccWork {
        const image = try allocator.alloc(f32, len);
        errdefer allocator.free(image);
        const gradient_x = try allocator.alloc(f32, len);
        errdefer allocator.free(gradient_x);
        const gradient_y = try allocator.alloc(f32, len);
        errdefer allocator.free(gradient_y);
        const mask = try allocator.alloc(u8, len);
        errdefer allocator.free(mask);
        const template_zm = try allocator.alloc(f32, len);
        return .{
            .image = image,
            .gradient_x = gradient_x,
            .gradient_y = gradient_y,
            .mask = mask,
            .template_zm = template_zm,
        };
    }

    fn deinit(self: EccWork, allocator: std.mem.Allocator) void {
        allocator.free(self.template_zm);
        allocator.free(self.mask);
        allocator.free(self.gradient_y);
        allocator.free(self.gradient_x);
        allocator.free(self.image);
    }
};

fn eccTranslationIteration(
    template_f: []const f32,
    image_f: []const f32,
    gradient_x: []const f32,
    gradient_y: []const f32,
    width: usize,
    height: usize,
    tx: *f64,
    ty: *f64,
    rho: *f64,
    last_rho: *f64,
    work: EccWork,
) !void {
    var valid_pixels: u32 = 0;
    var image_sum: f64 = 0.0;
    var template_sum: f64 = 0.0;
    for (0..height) |y| {
        for (0..width) |x| {
            const index = y * width + x;
            const sample_x = @as(f64, @floatFromInt(x)) + tx.*;
            const sample_y = @as(f64, @floatFromInt(y)) + ty.*;
            const valid = nearestInBounds(sample_x, width) and nearestInBounds(sample_y, height);
            work.mask[index] = if (valid) 1 else 0;
            work.image[index] = sampleConstantLinearOpenCv(image_f, width, height, sample_x, sample_y);
            work.gradient_x[index] = sampleConstantLinearOpenCv(gradient_x, width, height, sample_x, sample_y);
            work.gradient_y[index] = sampleConstantLinearOpenCv(gradient_y, width, height, sample_x, sample_y);
            if (valid) {
                valid_pixels += 1;
                image_sum += work.image[index];
                template_sum += template_f[index];
            }
        }
    }
    if (valid_pixels == 0) return error.InvalidBuffer;
    const inv_valid = 1.0 / @as(f64, @floatFromInt(valid_pixels));
    const image_mean = image_sum * inv_valid;
    const template_mean = template_sum * inv_valid;

    var image_norm_sq: f64 = 0.0;
    var template_norm_sq: f64 = 0.0;
    var h00: f64 = 0.0;
    var h01: f64 = 0.0;
    var h11: f64 = 0.0;
    var correlation: f64 = 0.0;
    var image_projection_x: f64 = 0.0;
    var image_projection_y: f64 = 0.0;
    var template_projection_x: f64 = 0.0;
    var template_projection_y: f64 = 0.0;
    for (0..template_f.len) |index| {
        const gx = @as(f64, @floatCast(work.gradient_x[index]));
        const gy = @as(f64, @floatCast(work.gradient_y[index]));
        const image_zero_mean = if (work.mask[index] != 0)
            @as(f64, @floatCast(work.image[index])) - image_mean
        else
            @as(f64, @floatCast(work.image[index]));
        const template_zero_mean = if (work.mask[index] != 0)
            @as(f64, @floatCast(template_f[index])) - template_mean
        else
            0.0;
        work.template_zm[index] = @floatCast(template_zero_mean);
        if (work.mask[index] != 0) image_norm_sq += image_zero_mean * image_zero_mean;
        template_norm_sq += template_zero_mean * template_zero_mean;
        correlation += template_zero_mean * image_zero_mean;
        h00 += gx * gx;
        h01 += gx * gy;
        h11 += gy * gy;
        image_projection_x += gx * image_zero_mean;
        image_projection_y += gy * image_zero_mean;
        template_projection_x += gx * template_zero_mean;
        template_projection_y += gy * template_zero_mean;
    }
    if (image_norm_sq <= 0.0 or template_norm_sq <= 0.0) return error.InvalidBuffer;
    const det = h00 * h11 - h01 * h01;
    if (@abs(det) < 1.0e-20) return error.InvalidBuffer;
    const inv00 = h11 / det;
    const inv01 = -h01 / det;
    const inv11 = h00 / det;

    last_rho.* = rho.*;
    rho.* = correlation / @sqrt(image_norm_sq * template_norm_sq);
    if (!std.math.isFinite(rho.*)) return error.InvalidBuffer;

    const image_projection_hessian_x = inv00 * image_projection_x + inv01 * image_projection_y;
    const image_projection_hessian_y = inv01 * image_projection_x + inv11 * image_projection_y;
    const lambda_n = image_norm_sq - (image_projection_x * image_projection_hessian_x + image_projection_y * image_projection_hessian_y);
    const lambda_d = correlation - (template_projection_x * image_projection_hessian_x + template_projection_y * image_projection_hessian_y);
    if (lambda_d <= 0.0 or !std.math.isFinite(lambda_d)) return error.InvalidBuffer;
    const lambda = lambda_n / lambda_d;

    var error_projection_x: f64 = 0.0;
    var error_projection_y: f64 = 0.0;
    for (0..template_f.len) |index| {
        const gx = @as(f64, @floatCast(work.gradient_x[index]));
        const gy = @as(f64, @floatCast(work.gradient_y[index]));
        const image_zero_mean = if (work.mask[index] != 0)
            @as(f64, @floatCast(work.image[index])) - image_mean
        else
            @as(f64, @floatCast(work.image[index]));
        const err = lambda * @as(f64, @floatCast(work.template_zm[index])) - image_zero_mean;
        error_projection_x += gx * err;
        error_projection_y += gy * err;
    }
    tx.* += inv00 * error_projection_x + inv01 * error_projection_y;
    ty.* += inv01 * error_projection_x + inv11 * error_projection_y;
}

fn reflect101Index(index: i32, len: usize) usize {
    if (len <= 1) return 0;
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

fn nearestInBounds(value: f64, len: usize) bool {
    const rounded: i32 = @intFromFloat(@floor(value + 0.5));
    return rounded >= 0 and rounded < @as(i32, @intCast(len));
}

fn sampleConstantLinearOpenCv(values: []const f32, width: usize, height: usize, x: f64, y: f64) f32 {
    var x0: i32 = @intFromFloat(@floor(x));
    var y0: i32 = @intFromFloat(@floor(y));
    var ix: i32 = @intFromFloat(@floor((x - @floor(x)) * 32.0 + 0.5));
    var iy: i32 = @intFromFloat(@floor((y - @floor(y)) * 32.0 + 0.5));
    if (ix == 32) {
        x0 += 1;
        ix = 0;
    }
    if (iy == 32) {
        y0 += 1;
        iy = 0;
    }
    const xf = @as(f32, @floatFromInt(ix)) / 32.0;
    const yf = @as(f32, @floatFromInt(iy)) / 32.0;
    const v00 = sampleConstantNearest(values, width, height, x0, y0);
    const v10 = sampleConstantNearest(values, width, height, x0 + 1, y0);
    const v01 = sampleConstantNearest(values, width, height, x0, y0 + 1);
    const v11 = sampleConstantNearest(values, width, height, x0 + 1, y0 + 1);
    const top = v00 * (1.0 - xf) + v10 * xf;
    const bottom = v01 * (1.0 - xf) + v11 * xf;
    return top * (1.0 - yf) + bottom * yf;
}

fn sampleConstantNearest(values: []const f32, width: usize, height: usize, x: i32, y: i32) f32 {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(width)) or y >= @as(i32, @intCast(height))) return 0.0;
    return values[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))];
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
        0,   5,   141,
        18,  39,  222,
        122, 133, 255,
        242, 243, 255,
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
