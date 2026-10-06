const std = @import("std");

const config = @import("config.zig");
const export_pipeline = @import("export.zig");
const film_stocks = @import("film_stocks.zig");
const frames = @import("frames.zig");
const inversion = @import("inversion.zig");
const ir_processing = @import("ir.zig");
const newton_rings = @import("newton_rings.zig");
const print = @import("print.zig");
const render = @import("render.zig");
const tiff = @import("../tiff.zig");
const webgpu = @import("webgpu.zig");

const export_parallel_min_system_reserve_bytes: usize = 512 * 1024 * 1024;
const export_parallel_memory_budget_numerator: usize = 3;
const export_parallel_memory_budget_denominator: usize = 4;
const export_parallel_estimate_safety_numerator: usize = 3;
const export_parallel_estimate_safety_denominator: usize = 2;
const tiff_to_f64_parallel_min_samples: usize = 4_000_000;

pub const ExportImageShape = struct {
    width: usize,
    height: usize,
    channels: usize,
};

pub const ExportParallelismRequest = struct {
    rects: []const export_pipeline.FrameRect,
    outputs: export_pipeline.OutputSelection,
    rgb_shape: ExportImageShape,
    aligned_ir_shape: ?ExportImageShape = null,
    render_options: render.RenderToDisplayOptions = .{},
    cpu_count: usize,
    available_memory_bytes: ?usize = null,
};

pub const ExportParallelismDecision = struct {
    worker_count: usize,
    cpu_count: usize,
    cpu_worker_limit: usize,
    memory_worker_limit: ?usize,
    available_memory_bytes: ?usize,
    memory_budget_bytes: ?usize,
    estimated_worker_peak_bytes: usize,
    adjusted_worker_peak_bytes: usize,
    memory_limited: bool,
};

extern fn cerealgrain_process_quick_preview(
    input: [*]const u8,
    width: c_int,
    height: c_int,
    channels: c_int,
    bits_per_sample: c_int,
    preview_size: c_int,
    out_width: *c_int,
    out_height: *c_int,
    out_preview_scale: *f64,
    preview_raw: ?[*]u16,
    preview_raw_len: c_int,
    preview_rgb8: ?[*]u8,
    preview_rgb8_len: c_int,
    jpeg_buffer: ?[*]u8,
    jpeg_capacity: c_int,
    jpeg_len: *c_int,
) c_int;

extern fn cerealgrain_process_quick_preview_breakdown(
    input: [*]const u8,
    width: c_int,
    height: c_int,
    channels: c_int,
    bits_per_sample: c_int,
    preview_size: c_int,
    out_width: *c_int,
    out_height: *c_int,
    out_preview_scale: *f64,
    preview_raw: ?[*]u16,
    preview_raw_len: c_int,
    preview_rgb8: ?[*]u8,
    preview_rgb8_len: c_int,
    jpeg_buffer: ?[*]u8,
    jpeg_capacity: c_int,
    jpeg_len: *c_int,
    geometry_ns: *u64,
    resize_ns: *u64,
    convert_ns: *u64,
    content_mask_ns: *u64,
    invert_stretch_ns: *u64,
    clahe_ns: *u64,
    raw_copy_ns: *u64,
    rgb_copy_ns: *u64,
    jpeg_encode_ns: *u64,
    jpeg_copy_ns: *u64,
) c_int;

extern fn cerealgrain_decode_jpeg_rgb(
    jpeg: [*]const u8,
    jpeg_len: c_int,
    rgb_out: ?[*]u8,
    rgb_capacity: c_int,
    out_width: *c_int,
    out_height: *c_int,
) c_int;

extern fn cerealgrain_encode_rgb_jpeg(
    rgb: [*]const u8,
    width: c_int,
    height: c_int,
    quality: c_int,
    jpeg_buffer: ?[*]u8,
    jpeg_capacity: c_int,
    jpeg_len: *c_int,
) c_int;

pub const ImageLoadInfo = struct {
    width: usize,
    height: usize,
    has_ir: bool,
    is_grayscale: bool,
    dpi: ?u32,
    preview_scale: f64,
    rgb_samples_per_pixel: u16,
    rgb_bits_per_sample: u16,
    ir_samples_per_pixel: ?u16 = null,
    ir_bits_per_sample: ?u16 = null,
};

pub const QuickPreview = struct {
    info: ImageLoadInfo,
    preview_width: usize,
    preview_height: usize,
    preview_raw: []u16,
    preview_rgb8: []u8,
    jpeg: []u8,

    pub fn deinit(self: QuickPreview, allocator: std.mem.Allocator) void {
        allocator.free(self.preview_raw);
        allocator.free(self.preview_rgb8);
        allocator.free(self.jpeg);
    }
};

pub const QuickPreviewProcessingTimings = struct {
    total_ns: u64 = 0,
    geometry_ns: u64 = 0,
    resize_ns: u64 = 0,
    convert_ns: u64 = 0,
    content_mask_ns: u64 = 0,
    invert_stretch_ns: u64 = 0,
    clahe_ns: u64 = 0,
    raw_copy_ns: u64 = 0,
    rgb_copy_ns: u64 = 0,
    jpeg_encode_ns: u64 = 0,
    jpeg_copy_ns: u64 = 0,
};

pub const QuickPreviewLoadBreakdown = struct {
    preview: QuickPreview,
    total_ns: u64 = 0,
    tiff_open_ifd_ns: u64 = 0,
    rgb_read_ns: u64 = 0,
    ir_info_ns: u64 = 0,
    quick_preview: QuickPreviewProcessingTimings = .{},

    pub fn deinit(self: QuickPreviewLoadBreakdown, allocator: std.mem.Allocator) void {
        self.preview.deinit(allocator);
    }
};

pub const InvertedPreviewCache = struct {
    scene_linear: ?[]f64 = null,
    scene_linear_f32: ?[]f32 = null,

    pub fn deinit(self: *InvertedPreviewCache, allocator: std.mem.Allocator) void {
        if (self.scene_linear) |scene| {
            allocator.free(scene);
            self.scene_linear = null;
        }
        if (self.scene_linear_f32) |scene| {
            allocator.free(scene);
            self.scene_linear_f32 = null;
        }
    }

    pub fn invalidate(self: *InvertedPreviewCache, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
    }
};

pub const InvertedPreviewOptions = struct {
    stock: ?[]const u8 = null,
    dmin: ?[3]f64 = null,
    render_options: render.RenderToDisplayOptions = .{},
    invert_request: webgpu.Request = .{},
};

pub const AutoDetectOptions = struct {
    format: ?[]const u8 = null,
    n_frames: ?usize = null,
    detect_film_extent: bool = true,
    apply_clahe: bool = true,
    /// Trim each detected frame to the format's exact aspect (for prints)
    /// instead of the frame the camera exposed.
    exact_aspect: bool = false,
};

pub const AutoDetectResult = struct {
    frames: []frames.FrameRect,
    aspect: []const u8,
    rebate: ?frames.RebateRect,
    /// Detection failed and the one frame is the whole image.
    full_image_fallback: bool = false,

    pub fn deinit(self: *AutoDetectResult, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
        self.* = undefined;
    }
};

pub const RebateWorkflowResult = struct {
    dmin: [3]f64,
};

pub const ExportWorkflowTimings = struct {
    total_ns: u64 = 0,
    create_output_dir_ns: u64 = 0,
    load_full_image_ns: u64 = 0,
    dmin_ns: u64 = 0,
    ir_align_ns: u64 = 0,
    path_setup_ns: u64 = 0,
    plan_parallel_ns: u64 = 0,
    frame_processing_ns: u64 = 0,
    worker_setup_ns: u64 = 0,
    scheduler_wait_ns: u64 = 0,
    result_merge_ns: u64 = 0,
    progress_build_ns: u64 = 0,
    final_message_ns: u64 = 0,
    frame_timings: export_pipeline.ProcessFrameTimings = .{},
};

pub const FullImage = struct {
    rgb: export_pipeline.Image,
    ir: ?export_pipeline.Image = null,
    dpi: ?u32 = null,

    pub fn deinit(self: FullImage, allocator: std.mem.Allocator) void {
        self.rgb.deinit(allocator);
        if (self.ir) |ir| ir.deinit(allocator);
    }
};

pub const ExportWorkflowOptions = struct {
    input_path: []const u8,
    output_dir: []const u8,
    basename: ?[]const u8 = null,
    rects: []const export_pipeline.FrameRect,
    outputs: export_pipeline.OutputSelection = .{},
    active_stock: ?[]const u8 = null,
    stock_coeffs: ?film_stocks.Coefficients = null,
    dmin: ?[3]f64 = null,
    rebate_rect: ?frames.RebateOriginRect = null,
    current_dpi: ?u32 = null,
    config_overrides: []const config.Override = &.{},
    align_ir: bool = true,
    invert_request: webgpu.Request = .{},
    parallel_frames: bool = true,
    allow_direct_rgb_crop: bool = true,
    parallel_cpu_count_override: ?usize = null,
    parallel_available_memory_override: ?usize = null,
    adaptive_dust_precision_override: ?ir_processing.AdaptiveDustPrecision = null,
    adaptive_dust_worker_count_override: ?usize = null,
    total_seconds_override: ?f64 = null,
    progress_sink: ?ExportProgressSink = null,
    timings: ?*ExportWorkflowTimings = null,
};

pub const ExportProgressNotice = struct {
    kind: export_pipeline.ExportProgressKind,
    message: []const u8,
    file_name: ?[]const u8 = null,
};

pub const ExportProgressSink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, ExportProgressNotice) void,
};

pub const ExportWorkflowResult = struct {
    message: []u8,
    files: [][]u8,
    dmin: ?[3]f64 = null,
    parallelism: ?ExportParallelismDecision = null,
    ir_adaptive_worker_count: usize = 1,
    progress: export_pipeline.ExportProgressList,
    /// Frames, numbered from 1, showing strong Newton's rings (scans with IR).
    ring_frames: []usize = &.{},

    pub fn deinit(self: ExportWorkflowResult, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        for (self.files) |file| allocator.free(file);
        allocator.free(self.files);
        self.progress.deinit(allocator);
        allocator.free(self.ring_frames);
    }
};

pub fn findImages(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !tiff.ImageList {
    const directory = imageSearchDirectory(io, path);
    return tiff.findImages(allocator, io, directory);
}

pub fn retainedImageIndex(old_paths: []const []const u8, old_index: usize, new_paths: []const []const u8) usize {
    const old_current: ?[]const u8 = if (old_index < old_paths.len) old_paths[old_index] else null;
    if (old_current) |current| {
        for (new_paths, 0..) |path, index| {
            if (std.mem.eql(u8, current, path)) return index;
        }
    }
    if (old_index >= new_paths.len) {
        return if (new_paths.len == 0) 0 else new_paths.len - 1;
    }
    return old_index;
}

pub fn loadImageInfo(
    allocator: std.mem.Allocator,
    path: []const u8,
    preview_size: i64,
) !ImageLoadInfo {
    const dpi = try tiff.readDpi(allocator, path);
    const pages = try tiff.readRgbIrPageInfo(allocator, path);

    const has_ir = if (pages.ir) |ir| ir.samples_per_pixel == 1 else false;
    return .{
        .width = pages.rgb.width,
        .height = pages.rgb.height,
        .has_ir = has_ir,
        .is_grayscale = pages.rgb.samples_per_pixel == 1,
        .dpi = dpi,
        .preview_scale = previewScale(pages.rgb.width, pages.rgb.height, preview_size),
        .rgb_samples_per_pixel = pages.rgb.samples_per_pixel,
        .rgb_bits_per_sample = pages.rgb.bits_per_sample,
        .ir_samples_per_pixel = if (pages.ir) |ir| ir.samples_per_pixel else null,
        .ir_bits_per_sample = if (pages.ir) |ir| ir.bits_per_sample else null,
    };
}

pub fn loadQuickPreview(
    allocator: std.mem.Allocator,
    path: []const u8,
    preview_size: i64,
) !QuickPreview {
    const loaded = try tiff.loadRgbPageWithMetadata(allocator, path);
    defer loaded.deinit(allocator);
    return quickPreviewFromLoadedRgbPage(allocator, loaded, preview_size);
}

pub fn quickPreviewFromLoadedRgbPage(
    allocator: std.mem.Allocator,
    loaded: tiff.RgbPageWithMetadata,
    preview_size: i64,
) !QuickPreview {
    var result = try generateQuickPreview(allocator, loaded.rgb, preview_size);
    result.info.dpi = loaded.dpi;
    result.info.has_ir = if (loaded.ir) |ir| ir.samples_per_pixel == 1 else false;
    result.info.ir_samples_per_pixel = if (loaded.ir) |ir| ir.samples_per_pixel else null;
    result.info.ir_bits_per_sample = if (loaded.ir) |ir| ir.bits_per_sample else null;
    return result;
}

pub fn loadQuickPreviewBreakdown(
    allocator: std.mem.Allocator,
    path: []const u8,
    preview_size: i64,
) !QuickPreviewLoadBreakdown {
    const total_started = monotonicNowNs();
    var tiff_timings = tiff.RgbPageMetadataTimings{};
    const loaded = try tiff.loadRgbPageWithMetadataTimed(allocator, path, &tiff_timings);
    defer loaded.deinit(allocator);

    var generated = try generateQuickPreviewBreakdown(allocator, loaded.rgb, preview_size);
    errdefer generated.preview.deinit(allocator);
    generated.preview.info.dpi = loaded.dpi;
    generated.preview.info.has_ir = if (loaded.ir) |ir| ir.samples_per_pixel == 1 else false;
    generated.preview.info.ir_samples_per_pixel = if (loaded.ir) |ir| ir.samples_per_pixel else null;
    generated.preview.info.ir_bits_per_sample = if (loaded.ir) |ir| ir.bits_per_sample else null;

    return .{
        .preview = generated.preview,
        .total_ns = monotonicNowNs() - total_started,
        .tiff_open_ifd_ns = tiff_timings.open_ifd_ns,
        .rgb_read_ns = tiff_timings.rgb_read_ns,
        .ir_info_ns = tiff_timings.ir_info_ns,
        .quick_preview = generated.timings,
    };
}

const GeneratedQuickPreviewBreakdown = struct {
    preview: QuickPreview,
    timings: QuickPreviewProcessingTimings,
};

pub fn generateQuickPreview(
    allocator: std.mem.Allocator,
    image: tiff.Image,
    preview_size: i64,
) !QuickPreview {
    return (try generateQuickPreviewInternal(allocator, image, preview_size, false)).preview;
}

pub fn generateQuickPreviewBreakdown(
    allocator: std.mem.Allocator,
    image: tiff.Image,
    preview_size: i64,
) !GeneratedQuickPreviewBreakdown {
    return generateQuickPreviewInternal(allocator, image, preview_size, true);
}

fn generateQuickPreviewInternal(
    allocator: std.mem.Allocator,
    image: tiff.Image,
    preview_size: i64,
    collect_timings: bool,
) !GeneratedQuickPreviewBreakdown {
    const total_started = monotonicNowNs();
    const width = try toCInt(image.width);
    const height = try toCInt(image.height);
    const channels = try toCInt(image.samples_per_pixel);
    const bits = try toCInt(image.bits_per_sample);
    const preview_size_c = if (preview_size <= 0) 0 else try toCInt(preview_size);
    const expected = quickPreviewGeometry(image.width, image.height, preview_size);

    const preview_width = expected.width;
    const preview_height = expected.height;
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, preview_width, preview_height), 3);
    const preview_raw = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(preview_raw);
    const preview_rgb8 = try allocator.alloc(u8, sample_count);
    errdefer allocator.free(preview_rgb8);
    var jpeg = try allocator.alloc(u8, sample_count);
    errdefer allocator.free(jpeg);

    var out_width: c_int = 0;
    var out_height: c_int = 0;
    var out_scale: f64 = 1.0;
    var jpeg_len: c_int = 0;
    var timings = QuickPreviewProcessingTimings{};
    var status = quickPreviewCall(
        image,
        width,
        height,
        channels,
        bits,
        preview_size_c,
        &out_width,
        &out_height,
        &out_scale,
        preview_raw.ptr,
        try toCInt(sample_count),
        preview_rgb8.ptr,
        try toCInt(preview_rgb8.len),
        jpeg.ptr,
        try toCInt(jpeg.len),
        &jpeg_len,
        collect_timings,
        &timings,
    );

    if (status == 1 and jpeg_len > 0 and @as(usize, @intCast(jpeg_len)) > jpeg.len) {
        jpeg = try allocator.realloc(jpeg, @intCast(jpeg_len));
        jpeg_len = 0;
        status = quickPreviewCall(
            image,
            width,
            height,
            channels,
            bits,
            preview_size_c,
            &out_width,
            &out_height,
            &out_scale,
            preview_raw.ptr,
            try toCInt(sample_count),
            preview_rgb8.ptr,
            try toCInt(preview_rgb8.len),
            jpeg.ptr,
            try toCInt(jpeg.len),
            &jpeg_len,
            collect_timings,
            &timings,
        );
    }

    if (status != 0 or jpeg_len <= 0 or @as(usize, @intCast(jpeg_len)) > jpeg.len or
        out_width <= 0 or out_height <= 0)
    {
        return error.QuickPreviewFailed;
    }

    if (out_width != try toCInt(preview_width) or out_height != try toCInt(preview_height)) {
        return error.QuickPreviewFailed;
    }
    if (@as(usize, @intCast(jpeg_len)) != jpeg.len) {
        jpeg = try allocator.realloc(jpeg, @intCast(jpeg_len));
    }

    timings.total_ns = monotonicNowNs() - total_started;
    return .{ .preview = .{
        .info = .{
            .width = image.width,
            .height = image.height,
            .has_ir = false,
            .is_grayscale = image.samples_per_pixel == 1,
            .dpi = null,
            .preview_scale = out_scale,
            .rgb_samples_per_pixel = image.samples_per_pixel,
            .rgb_bits_per_sample = image.bits_per_sample,
        },
        .preview_width = preview_width,
        .preview_height = preview_height,
        .preview_raw = preview_raw,
        .preview_rgb8 = preview_rgb8,
        .jpeg = jpeg,
    }, .timings = timings };
}

fn quickPreviewCall(
    image: tiff.Image,
    width: c_int,
    height: c_int,
    channels: c_int,
    bits: c_int,
    preview_size_c: c_int,
    out_width: *c_int,
    out_height: *c_int,
    out_scale: *f64,
    preview_raw: [*]u16,
    preview_raw_len: c_int,
    preview_rgb8: [*]u8,
    preview_rgb8_len: c_int,
    jpeg: [*]u8,
    jpeg_len_capacity: c_int,
    jpeg_len: *c_int,
    collect_timings: bool,
    timings: *QuickPreviewProcessingTimings,
) c_int {
    if (!collect_timings) {
        return cerealgrain_process_quick_preview(
            image.data.ptr,
            width,
            height,
            channels,
            bits,
            preview_size_c,
            out_width,
            out_height,
            out_scale,
            preview_raw,
            preview_raw_len,
            preview_rgb8,
            preview_rgb8_len,
            jpeg,
            jpeg_len_capacity,
            jpeg_len,
        );
    }
    return cerealgrain_process_quick_preview_breakdown(
        image.data.ptr,
        width,
        height,
        channels,
        bits,
        preview_size_c,
        out_width,
        out_height,
        out_scale,
        preview_raw,
        preview_raw_len,
        preview_rgb8,
        preview_rgb8_len,
        jpeg,
        jpeg_len_capacity,
        jpeg_len,
        &timings.geometry_ns,
        &timings.resize_ns,
        &timings.convert_ns,
        &timings.content_mask_ns,
        &timings.invert_stretch_ns,
        &timings.clahe_ns,
        &timings.raw_copy_ns,
        &timings.rgb_copy_ns,
        &timings.jpeg_encode_ns,
        &timings.jpeg_copy_ns,
    );
}

pub fn decodeJpegRgb(
    allocator: std.mem.Allocator,
    jpeg: []const u8,
    expected_width: usize,
    expected_height: usize,
) ![]u8 {
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, expected_width, expected_height), 3);
    const decoded = try allocator.alloc(u8, sample_count);
    errdefer allocator.free(decoded);
    var out_width: c_int = 0;
    var out_height: c_int = 0;
    const expected_width_c = try toCInt(expected_width);
    const expected_height_c = try toCInt(expected_height);
    const status = cerealgrain_decode_jpeg_rgb(
        jpeg.ptr,
        try toCInt(jpeg.len),
        decoded.ptr,
        try toCInt(decoded.len),
        &out_width,
        &out_height,
    );
    if (status != 0 or out_width != expected_width_c or out_height != expected_height_c) {
        return error.JpegDecodeFailed;
    }
    return decoded;
}

pub fn renderInvertedPreviewJpeg(
    allocator: std.mem.Allocator,
    preview: QuickPreview,
    cache: *InvertedPreviewCache,
    options: InvertedPreviewOptions,
) !?[]u8 {
    const display8 = (try renderInvertedPreviewRgb8(allocator, preview, cache, options)) orelse return null;
    defer allocator.free(display8);
    return try encodeRgbJpeg(allocator, display8, preview.preview_width, preview.preview_height, 90);
}

pub fn renderInvertedPreviewRgb8(
    allocator: std.mem.Allocator,
    preview: QuickPreview,
    cache: *InvertedPreviewCache,
    options: InvertedPreviewOptions,
) !?[]u8 {
    const stock = options.stock orelse return null;
    if (preview.info.is_grayscale) return null;
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, preview.preview_width, preview.preview_height), 3);
    if (preview.preview_raw.len != sample_count) return error.InvalidPreviewBuffer;

    if (cache.scene_linear == null and cache.scene_linear_f32 == null) {
        const coeffs = if (film_stocks.builtinStock(stock)) |profile|
            profile.coeffs
        else
            return error.UnknownFilmStock;
        const use_cpu = try webgpu.shouldUseCpu(options.invert_request);
        if (use_cpu and options.dmin != null and film_stocks.usesOnlyLinearTerms(coeffs)) {
            const scene = try allocator.alloc(f32, preview.preview_raw.len);
            errdefer allocator.free(scene);
            const density_lut = try inversion.DensityLutF32.initF32(allocator, dminToF32(options.dmin.?), 65535.0);
            defer density_lut.deinit(allocator);
            try inversion.invertNegativeProvidedDminU16WithDensityLutF32OutputF32(preview.preview_raw, scene, density_lut, coeffs);
            cache.scene_linear_f32 = scene;
        } else {
            const scene = try allocator.alloc(f64, preview.preview_raw.len);
            errdefer allocator.free(scene);
            if (use_cpu) {
                if (options.dmin) |dmin| {
                    const density_lut = try inversion.DensityLutF64.init(allocator, dmin, 65535.0);
                    defer density_lut.deinit(allocator);
                    try inversion.invertNegativeProvidedDminU16WithDensityLutF64(preview.preview_raw, scene, density_lut, coeffs);
                } else {
                    const raw_f64 = try previewRawToF64(allocator, preview.preview_raw);
                    defer allocator.free(raw_f64);
                    _ = try inversion.invertNegative(allocator, raw_f64, scene, .{
                        .coeffs = coeffs,
                    });
                }
            } else {
                const raw_f64 = try previewRawToF64(allocator, preview.preview_raw);
                defer allocator.free(raw_f64);
                _ = try inversion.invertNegative(allocator, raw_f64, scene, .{
                    .dmin = options.dmin,
                    .coeffs = coeffs,
                    .request = options.invert_request,
                });
            }
            cache.scene_linear = scene;
        }
    }

    const display8 = try allocator.alloc(u8, sample_count);
    errdefer allocator.free(display8);
    if (cache.scene_linear_f32) |scene| {
        try render.renderToDisplayU8F32(allocator, scene, display8, options.render_options);
    } else {
        try render.renderToDisplayU8(allocator, cache.scene_linear.?, display8, options.render_options);
    }
    return display8;
}

fn dminToF32(dmin: [3]f64) [3]f32 {
    return .{
        @floatCast(dmin[0]),
        @floatCast(dmin[1]),
        @floatCast(dmin[2]),
    };
}

fn previewRawToF64(allocator: std.mem.Allocator, preview_raw: []const u16) ![]f64 {
    const raw_f64 = try allocator.alloc(f64, preview_raw.len);
    errdefer allocator.free(raw_f64);
    for (preview_raw, raw_f64) |sample, *out| {
        out.* = @floatFromInt(sample);
    }
    return raw_f64;
}

pub fn autoDetectPreview(
    allocator: std.mem.Allocator,
    preview: QuickPreview,
    options: AutoDetectOptions,
) !AutoDetectResult {
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, preview.preview_width, preview.preview_height), 3);
    if (preview.preview_raw.len != sample_count) return error.InvalidPreviewBuffer;

    const format_name = options.format orelse "35mm_strip_6";
    const format = frames.formatByName(format_name) orelse return error.InvalidFilmFormat;
    var detected = try frames.detectFramesFromImage(
        allocator,
        std.mem.sliceAsBytes(preview.preview_raw),
        preview.preview_width,
        preview.preview_height,
        3,
        16,
        format,
        .{
            .frame_count_override = options.n_frames,
            .detect_film_extent = options.detect_film_extent,
            .apply_clahe = options.apply_clahe,
            .px_per_mm = if (preview.info.dpi) |dpi| @as(f64, @floatFromInt(dpi)) / 25.4 * preview.info.preview_scale else null,
        },
    );
    errdefer detected.deinit(allocator);
    const is_vertical = detected.strip_info.is_vertical;
    const result = try autoDetectDetectedFrames(&detected, preview.preview_width, preview.preview_height);
    // After the rebate is placed, from the frames as exposed.
    if (options.exact_aspect and !result.full_image_fallback) {
        for (result.frames) |*frame| frame.* = frames.exactAspectFrame(frame.*, format, is_vertical);
    }
    return result;
}

/// The rebate auto-detect suggests, converted from preview center form to a
/// full-resolution rectangle with its origin at the top-left corner.
pub fn fullResolutionRebate(rebate: frames.RebateRect, preview_scale: f64) !frames.RebateOriginRect {
    return frames.previewRebateToFullResolution(.{
        .x = rebate.cx - rebate.w / 2.0,
        .y = rebate.cy - rebate.h / 2.0,
        .w = rebate.w,
        .h = rebate.h,
        .angle = rebate.angle,
    }, preview_scale);
}

pub fn autoDetectDetectedFrames(
    detected: *frames.DetectFramesResult,
    preview_width: usize,
    preview_height: usize,
) !AutoDetectResult {
    if (detected.frames.len == 1) {
        if (try frames.singleFrameFallback(
            1,
            detected.frames[0],
            @floatFromInt(preview_width),
            @floatFromInt(preview_height),
        )) |fallback| {
            detected.frames[0] = fallback;
            const owned_frames = detected.frames;
            detected.frames = detected.frames[0..0];
            return .{
                .frames = owned_frames,
                .aspect = detected.aspect,
                .rebate = null,
                .full_image_fallback = true,
            };
        }
    }

    const owned_frames = detected.frames;
    detected.frames = detected.frames[0..0];
    return .{
        .frames = owned_frames,
        .aspect = detected.aspect,
        .rebate = frames.computeInterFrameRebate(owned_frames),
    };
}

pub fn loadRgbImageAsF64(allocator: std.mem.Allocator, path: []const u8) !export_pipeline.Image {
    const image = try tiff.loadRgbPage(allocator, path);
    defer image.deinit(allocator);
    return tiffImageToF64(allocator, image);
}

pub fn loadFullImageAsF64(
    allocator: std.mem.Allocator,
    path: []const u8,
    include_ir: bool,
) !FullImage {
    const dpi = try tiff.readDpi(allocator, path);
    if (!include_ir) {
        const rgb_page = try tiff.loadRgbPage(allocator, path);
        defer rgb_page.deinit(allocator);
        const rgb = try tiffImageToF64(allocator, rgb_page);
        return .{ .rgb = rgb, .ir = null, .dpi = dpi };
    }

    const pages = try tiff.loadRgbIrPages(allocator, path);
    defer pages.deinit(allocator);
    const rgb = try tiffImageToF64(allocator, pages.rgb);
    errdefer rgb.deinit(allocator);
    var ir: ?export_pipeline.Image = null;
    errdefer if (ir) |image| image.deinit(allocator);
    if (include_ir) {
        if (pages.ir) |ir_page| {
            ir = try tiffImageToF64(allocator, ir_page);
        }
    }
    return .{ .rgb = rgb, .ir = ir, .dpi = dpi };
}

pub fn computeRebateDminFromImage(
    allocator: std.mem.Allocator,
    image: export_pipeline.Image,
    rect: frames.RebateOriginRect,
) ![3]f64 {
    if (image.channels != 3) return error.UnsupportedProcessingImage;
    const crop = try export_pipeline.cropFrame(allocator, image.pixels, image.width, image.height, image.channels, .{
        .cx = rect.x + rect.w / 2.0,
        .cy = rect.y + rect.h / 2.0,
        .w = rect.w,
        .h = rect.h,
        .angle = rect.angle * 180.0 / std.math.pi,
    });
    defer crop.deinit(allocator);
    return inversion.computeDmin(allocator, crop.pixels, null, .{});
}

/// Reads only the rows the rebate covers: a rebate is a sliver of a scan
/// that can run to gigabytes, and this runs on every rebate edit.
pub fn computeRebateDminFromTiff(
    allocator: std.mem.Allocator,
    path: []const u8,
    rect: frames.RebateOriginRect,
) ![3]f64 {
    const center_y = rect.y + rect.h / 2.0;
    const half_height = @abs(rect.w / 2.0 * @sin(rect.angle)) + @abs(rect.h / 2.0 * @cos(rect.angle));
    // Two rows of margin for the crop's interpolation.
    const top = @floor(center_y - half_height) - 2.0;
    const bottom = @ceil(center_y + half_height) + 2.0;
    if (!std.math.isFinite(top) or !std.math.isFinite(bottom)) return error.InvalidRebateRect;
    const first_row: u32 = @intFromFloat(std.math.clamp(top, 0.0, @as(f64, std.math.maxInt(u32))));
    const row_count: u32 = @intFromFloat(std.math.clamp(bottom - @as(f64, @floatFromInt(first_row)) + 1.0, 1.0, @as(f64, std.math.maxInt(u32))));
    const rows = try tiff.loadRgbPageRows(allocator, path, first_row, row_count);
    defer rows.deinit(allocator);
    var shifted = rect;
    shifted.y -= @floatFromInt(first_row);
    return computeRebateDminFromTiffImage(allocator, rows, shifted);
}

pub fn computeRebateDminFromTiffImage(
    allocator: std.mem.Allocator,
    image: tiff.Image,
    rect: frames.RebateOriginRect,
) ![3]f64 {
    const crop = try cropRgbFrameFromTiffImage(allocator, image, .{
        .cx = rect.x + rect.w / 2.0,
        .cy = rect.y + rect.h / 2.0,
        .w = rect.w,
        .h = rect.h,
        .angle = rect.angle * 180.0 / std.math.pi,
    });
    defer crop.deinit(allocator);
    return inversion.computeDmin(allocator, crop.pixels, null, .{});
}

pub fn saveRebateDmin(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    dmin: [3]f64,
) !void {
    const list = try config.FloatList.init(&dmin);
    try config.saveFile(allocator, io, config_path, &.{
        .{ .name = "dmin", .value = .{ .list = list } },
    });
}

pub fn processRebateFromTiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_path: []const u8,
    config_path: []const u8,
    rect: frames.RebateOriginRect,
    save: bool,
) !RebateWorkflowResult {
    const dmin = try computeRebateDminFromTiff(allocator, input_path, rect);
    if (save) try saveRebateDmin(allocator, io, config_path, dmin);
    return .{ .dmin = dmin };
}

pub fn processExportFromTiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExportWorkflowOptions,
) !ExportWorkflowResult {
    if (options.timings) |timings| timings.* = .{};
    if (!options.outputs.any()) {
        return noOutputExportResult(allocator);
    }

    const start = monotonicNowNs();
    defer if (options.timings) |timings| {
        timings.total_ns = monotonicNowNs() - start;
    };
    const create_dir_started = monotonicNowNs();
    try std.Io.Dir.cwd().createDirPath(io, options.output_dir);
    if (options.timings) |timings| timings.create_output_dir_ns += monotonicNowNs() - create_dir_started;
    const need_ir = options.outputs.needIr();
    const need_invert = options.outputs.needInvert();
    try emitExportProgressFmt(
        allocator,
        options.progress_sink,
        .preparing,
        "Preparing export ({d} frame{s})...",
        .{ options.rects.len, if (options.rects.len == 1) "" else "s" },
        null,
    );

    if (canUseDirectRgbCropExport(options, need_ir, need_invert)) {
        return processExportDirectRgbCropFromTiff(allocator, io, options, start, need_ir, need_invert);
    }

    const load_started = monotonicNowNs();
    var full = try loadFullImageAsF64(allocator, options.input_path, need_ir);
    if (options.timings) |timings| timings.load_full_image_ns += monotonicNowNs() - load_started;
    defer full.deinit(allocator);
    const current_dpi = options.current_dpi orelse full.dpi;
    const scan_datetime = try tiff.readDateTime(allocator, options.input_path);
    defer if (scan_datetime) |datetime| allocator.free(datetime);

    var dmin = options.dmin;
    if (options.active_stock != null and dmin == null) {
        const dmin_started = monotonicNowNs();
        if (options.rebate_rect) |rebate| {
            if (frames.rebateInBounds(full.rgb.width, full.rgb.height, rebate)) {
                dmin = try computeRebateDminFromImage(allocator, full.rgb, rebate);
            }
        }
        if (dmin == null) {
            dmin = try inversion.computeDmin(allocator, full.rgb.pixels, null, .{});
        }
        if (options.timings) |timings| timings.dmin_ns += monotonicNowNs() - dmin_started;
    }

    var aligned_ir: ?export_pipeline.Image = null;
    defer if (aligned_ir) |image| image.deinit(allocator);
    if (need_ir and options.align_ir) {
        if (full.ir) |ir| {
            emitExportProgress(options.progress_sink, .{
                .kind = .aligning_ir,
                .message = "Aligning IR channel...",
            });
            const aligned = try allocator.alloc(f64, ir.pixels.len);
            errdefer allocator.free(aligned);
            const align_started = monotonicNowNs();
            _ = try ir_processing.alignIr(
                allocator,
                full.rgb.pixels,
                full.rgb.width,
                full.rgb.height,
                ir.pixels,
                ir.width,
                ir.height,
                aligned,
                .{},
            );
            if (options.timings) |timings| timings.ir_align_ns += monotonicNowNs() - align_started;
            aligned_ir = .{ .width = ir.width, .height = ir.height, .channels = 1, .pixels = aligned };
        }
    }

    const basename = options.basename orelse std.fs.path.stem(std.fs.path.basename(options.input_path));
    const film_stock = if (need_invert) options.active_stock else null;
    const stock_coeffs = if (need_invert) options.stock_coeffs else null;
    var written = std.array_list.Managed([]u8).init(allocator);
    defer written.deinit();
    errdefer {
        for (written.items) |name| allocator.free(name);
    }
    try emitExportProgressFmt(
        allocator,
        options.progress_sink,
        .processing,
        "Processing {d} frame{s}...",
        .{ options.rects.len, if (options.rects.len == 1) "" else "s" },
        null,
    );

    const ir_scale_x = if (aligned_ir) |ir| @as(f64, @floatFromInt(ir.width)) / @as(f64, @floatFromInt(full.rgb.width)) else 1.0;
    const ir_scale_y = if (aligned_ir) |ir| @as(f64, @floatFromInt(ir.height)) / @as(f64, @floatFromInt(full.rgb.height)) else 1.0;
    const render_options = renderOptionsForConfig(current_dpi, options.config_overrides);
    const print_spec = print.specForConfig(options.config_overrides);
    var ir_clean_options = irCleanOptionsForConfig(current_dpi, irDpi(current_dpi, ir_scale_x), options.config_overrides);
    if (options.adaptive_dust_precision_override) |precision| {
        ir_clean_options.defect_mask.adaptive_precision = precision;
    }

    const path_setup_started = monotonicNowNs();
    const jobs = try allocator.alloc(FrameExportJob, options.rects.len);
    var jobs_len: usize = 0;
    errdefer {
        for (jobs[0..jobs_len]) |*job| job.paths.deinit(allocator);
        allocator.free(jobs);
    }
    defer {
        for (jobs[0..jobs_len]) |*job| job.paths.deinit(allocator);
        allocator.free(jobs);
    }
    for (options.rects, 0..) |rect, frame_index| {
        jobs[jobs_len] = .{
            .frame_index = frame_index,
            .rect = rect,
            .paths = try outputPathsForFrame(allocator, io, options.output_dir, basename, frame_index, options.outputs, print_spec),
        };
        jobs_len += 1;
    }
    if (options.timings) |timings| timings.path_setup_ns += monotonicNowNs() - path_setup_started;

    const plan_started = monotonicNowNs();
    const parallel_decision: ExportParallelismDecision = if (jobs.len > 1 and options.parallel_frames)
        planExportParallelism(.{
            .rects = options.rects,
            .outputs = options.outputs,
            .rgb_shape = exportImageShape(full.rgb),
            .aligned_ir_shape = if (aligned_ir) |ir| exportImageShape(ir) else null,
            .render_options = render_options,
            .cpu_count = options.parallel_cpu_count_override orelse (std.Thread.getCpuCount() catch 1),
            .available_memory_bytes = options.parallel_available_memory_override orelse availableSystemMemoryBytes(io),
        })
    else
        .{
            .worker_count = if (jobs.len == 0) 0 else 1,
            .cpu_count = options.parallel_cpu_count_override orelse 1,
            .cpu_worker_limit = 1,
            .memory_worker_limit = null,
            .available_memory_bytes = options.parallel_available_memory_override,
            .memory_budget_bytes = null,
            .estimated_worker_peak_bytes = 0,
            .adjusted_worker_peak_bytes = 0,
            .memory_limited = false,
        };
    if (options.timings) |timings| timings.plan_parallel_ns += monotonicNowNs() - plan_started;
    const ir_adaptive_worker_count = adaptiveDustWorkerCountForOptions(options, parallel_decision);
    ir_clean_options.defect_mask.adaptive_worker_count = ir_adaptive_worker_count;
    ir_clean_options.inpaint.worker_count = ir_adaptive_worker_count;

    const frame_processing_started = monotonicNowNs();
    if (jobs.len <= 1 or !options.parallel_frames or parallel_decision.worker_count <= 1) {
        for (jobs) |job| {
            var prng = std.Random.DefaultPrng.init(frameExportSeed(job.frame_index));
            var frame_timings = export_pipeline.ProcessFrameTimings{};
            const result = try export_pipeline.processFrame(
                allocator,
                job.frame_index,
                job.rect,
                full.rgb,
                aligned_ir,
                ir_scale_x,
                ir_scale_y,
                .{
                    .outputs = options.outputs,
                    .paths = job.paths.paths,
                    .base_meta = .{
                        .source = std.fs.path.basename(options.input_path),
                        .rebate_rect = options.rebate_rect,
                        .crop = job.rect,
                        .dpi = current_dpi,
                        .datetime = scan_datetime,
                    },
                    .film_stock = film_stock,
                    .stock_coeffs = stock_coeffs,
                    .dmin = dmin,
                    .render_options = render_options,
                    .ir_clean_options = ir_clean_options,
                    .invert_request = options.invert_request,
                    .random = prng.random(),
                    .timings = &frame_timings,
                },
            );
            if (options.timings) |timings| timings.frame_timings.add(frame_timings);
            defer result.deinit(allocator);
            for (result.written) |name| {
                try written.append(try allocator.dupe(u8, name));
                try emitExportProgressFmt(
                    allocator,
                    options.progress_sink,
                    .wrote_file,
                    "Wrote {s}",
                    .{name},
                    name,
                );
            }
        }
    } else {
        try processExportFramesParallel(allocator, &written, jobs, parallel_decision.worker_count, .{
            .rgb = full.rgb,
            .aligned_ir = aligned_ir,
            .ir_scale_x = ir_scale_x,
            .ir_scale_y = ir_scale_y,
            .source = std.fs.path.basename(options.input_path),
            .dpi = current_dpi,
            .datetime = scan_datetime,
            .rebate_rect = options.rebate_rect,
            .outputs = options.outputs,
            .film_stock = film_stock,
            .stock_coeffs = stock_coeffs,
            .dmin = dmin,
            .render_options = render_options,
            .ir_clean_options = ir_clean_options,
            .invert_request = options.invert_request,
            .progress_sink = options.progress_sink,
        }, options.timings);
    }
    if (options.timings) |timings| timings.frame_processing_ns += monotonicNowNs() - frame_processing_started;

    const ring_frames = try newtonRingFrames(allocator, options.progress_sink, options.rects, full.rgb, aligned_ir orelse full.ir, current_dpi);
    errdefer allocator.free(ring_frames);

    const files = try written.toOwnedSlice();
    errdefer {
        for (files) |file| allocator.free(file);
        allocator.free(files);
    }
    const total_seconds = options.total_seconds_override orelse
        @as(f64, @floatFromInt(monotonicNowNs() - start)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    const progress_started = monotonicNowNs();
    var progress = try export_pipeline.buildBatchExportProgress(
        allocator,
        options.rects.len,
        need_ir,
        full.ir != null,
        files,
        options.output_dir,
        total_seconds,
    );
    if (options.timings) |timings| timings.progress_build_ns += monotonicNowNs() - progress_started;
    errdefer progress.deinit(allocator);
    const message_started = monotonicNowNs();
    const rings_note = if (ring_frames.len == 0) try allocator.dupe(u8, "") else blk: {
        const text = try newton_rings.warningText(allocator, ring_frames);
        defer allocator.free(text);
        break :blk try std.fmt.allocPrint(allocator, ". {s}", .{text});
    };
    defer allocator.free(rings_note);
    const message = try std.fmt.allocPrint(allocator, "Exported {d} file{s} to {s}/ ({d:.1}s){s}", .{
        files.len,
        if (files.len == 1) "" else "s",
        options.output_dir,
        total_seconds,
        rings_note,
    });
    if (options.timings) |timings| timings.final_message_ns += monotonicNowNs() - message_started;
    errdefer allocator.free(message);
    emitExportProgress(options.progress_sink, .{
        .kind = .complete,
        .message = message,
    });

    return .{
        .message = message,
        .files = files,
        .dmin = dmin,
        .parallelism = parallel_decision,
        .ir_adaptive_worker_count = ir_adaptive_worker_count,
        .progress = progress,
        .ring_frames = ring_frames,
    };
}

/// Frames, numbered from 1, that show strong Newton's rings; none without IR
/// or a DPI.
pub fn newtonRingFrames(
    allocator: std.mem.Allocator,
    sink: ?ExportProgressSink,
    rects: []const export_pipeline.FrameRect,
    rgb: export_pipeline.Image,
    ir: ?export_pipeline.Image,
    dpi: ?u32,
) ![]usize {
    const ir_image = ir orelse return allocator.alloc(usize, 0);
    const scan_dpi = dpi orelse return allocator.alloc(usize, 0);
    emitExportProgress(sink, .{ .kind = .processing, .message = "Checking for Newton's rings..." });
    var found = std.array_list.Managed(usize).init(allocator);
    errdefer found.deinit();
    for (rects, 0..) |rect, index| {
        const score = try newton_rings.ringScore(
            f64,
            f64,
            allocator,
            .{ .pixels = rgb.pixels, .width = rgb.width, .height = rgb.height, .channels = rgb.channels },
            .{},
            .{ .pixels = ir_image.pixels, .width = ir_image.width, .height = ir_image.height, .channels = ir_image.channels },
            .{ .cx = rect.cx, .cy = rect.cy, .w = rect.w, .h = rect.h },
            scan_dpi,
        );
        if (newton_rings.warns(score)) try found.append(index + 1);
    }
    return found.toOwnedSlice();
}

pub fn processExportFromCachedRgbPage(
    allocator: std.mem.Allocator,
    io: std.Io,
    loaded: tiff.RgbPageWithMetadata,
    options: ExportWorkflowOptions,
) !ExportWorkflowResult {
    if (options.timings) |timings| timings.* = .{};
    if (!options.outputs.any()) {
        return noOutputExportResult(allocator);
    }

    const start = monotonicNowNs();
    defer if (options.timings) |timings| {
        timings.total_ns = monotonicNowNs() - start;
    };
    const create_dir_started = monotonicNowNs();
    try std.Io.Dir.cwd().createDirPath(io, options.output_dir);
    if (options.timings) |timings| timings.create_output_dir_ns += monotonicNowNs() - create_dir_started;
    const need_ir = options.outputs.needIr();
    const need_invert = options.outputs.needInvert();
    if (!canUseDirectRgbCropExport(options, need_ir, need_invert)) return error.UnsupportedCachedRgbExport;

    try emitExportProgressFmt(
        allocator,
        options.progress_sink,
        .preparing,
        "Preparing export ({d} frame{s})...",
        .{ options.rects.len, if (options.rects.len == 1) "" else "s" },
        null,
    );

    return processExportDirectRgbCropFromLoadedPage(allocator, io, options, start, loaded, need_ir, need_invert);
}

fn canUseDirectRgbCropExport(options: ExportWorkflowOptions, need_ir: bool, need_invert: bool) bool {
    return options.allow_direct_rgb_crop and
        !need_ir and
        need_invert and
        options.dmin != null and
        options.outputs.inv_only and
        !options.outputs.ir_inv and
        !options.outputs.ir_neg;
}

fn processExportDirectRgbCropFromTiff(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExportWorkflowOptions,
    workflow_start_ns: u64,
    need_ir: bool,
    need_invert: bool,
) !ExportWorkflowResult {
    std.debug.assert(!need_ir);
    std.debug.assert(need_invert);

    const load_started = monotonicNowNs();
    const loaded = try tiff.loadRgbPageWithMetadata(allocator, options.input_path);
    if (options.timings) |timings| timings.load_full_image_ns += monotonicNowNs() - load_started;
    defer loaded.deinit(allocator);
    return processExportDirectRgbCropFromLoadedPage(allocator, io, options, workflow_start_ns, loaded, need_ir, need_invert);
}

fn processExportDirectRgbCropFromLoadedPage(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExportWorkflowOptions,
    workflow_start_ns: u64,
    loaded: tiff.RgbPageWithMetadata,
    need_ir: bool,
    need_invert: bool,
) !ExportWorkflowResult {
    std.debug.assert(!need_ir);
    std.debug.assert(need_invert);
    const dmin = options.dmin.?;

    const current_dpi = options.current_dpi orelse loaded.dpi;
    const scan_datetime = try tiff.readDateTime(allocator, options.input_path);
    defer if (scan_datetime) |datetime| allocator.free(datetime);

    const basename = options.basename orelse std.fs.path.stem(std.fs.path.basename(options.input_path));
    const film_stock = options.active_stock;
    const stock_coeffs = options.stock_coeffs;
    var written = std.array_list.Managed([]u8).init(allocator);
    defer written.deinit();
    errdefer {
        for (written.items) |name| allocator.free(name);
    }
    try emitExportProgressFmt(
        allocator,
        options.progress_sink,
        .processing,
        "Processing {d} frame{s}...",
        .{ options.rects.len, if (options.rects.len == 1) "" else "s" },
        null,
    );

    const render_options = renderOptionsForConfig(current_dpi, options.config_overrides);
    const print_spec = print.specForConfig(options.config_overrides);
    // This path never cleans with IR.
    var ir_clean_options = irCleanOptionsForConfig(current_dpi, current_dpi, options.config_overrides);
    if (options.adaptive_dust_precision_override) |precision| {
        ir_clean_options.defect_mask.adaptive_precision = precision;
    }

    const path_setup_started = monotonicNowNs();
    const jobs = try allocator.alloc(FrameExportJob, options.rects.len);
    var jobs_len: usize = 0;
    errdefer {
        for (jobs[0..jobs_len]) |*job| job.paths.deinit(allocator);
        allocator.free(jobs);
    }
    defer {
        for (jobs[0..jobs_len]) |*job| job.paths.deinit(allocator);
        allocator.free(jobs);
    }
    for (options.rects, 0..) |rect, frame_index| {
        jobs[jobs_len] = .{
            .frame_index = frame_index,
            .rect = rect,
            .paths = try outputPathsForFrame(allocator, io, options.output_dir, basename, frame_index, options.outputs, print_spec),
        };
        jobs_len += 1;
    }
    if (options.timings) |timings| timings.path_setup_ns += monotonicNowNs() - path_setup_started;

    const plan_started = monotonicNowNs();
    const parallel_decision: ExportParallelismDecision = if (jobs.len > 1 and options.parallel_frames)
        planExportParallelism(.{
            .rects = options.rects,
            .outputs = options.outputs,
            .rgb_shape = exportTiffImageShape(loaded.rgb),
            .aligned_ir_shape = null,
            .render_options = render_options,
            .cpu_count = options.parallel_cpu_count_override orelse (std.Thread.getCpuCount() catch 1),
            .available_memory_bytes = options.parallel_available_memory_override orelse availableSystemMemoryBytes(io),
        })
    else
        .{
            .worker_count = if (jobs.len == 0) 0 else 1,
            .cpu_count = options.parallel_cpu_count_override orelse 1,
            .cpu_worker_limit = 1,
            .memory_worker_limit = null,
            .available_memory_bytes = options.parallel_available_memory_override,
            .memory_budget_bytes = null,
            .estimated_worker_peak_bytes = 0,
            .adjusted_worker_peak_bytes = 0,
            .memory_limited = false,
        };
    if (options.timings) |timings| timings.plan_parallel_ns += monotonicNowNs() - plan_started;
    const ir_adaptive_worker_count = adaptiveDustWorkerCountForOptions(options, parallel_decision);
    ir_clean_options.defect_mask.adaptive_worker_count = ir_adaptive_worker_count;
    ir_clean_options.inpaint.worker_count = ir_adaptive_worker_count;

    const shared = DirectRgbFrameExportShared{
        .rgb_page = loaded.rgb,
        .source = std.fs.path.basename(options.input_path),
        .dpi = current_dpi,
        .datetime = scan_datetime,
        .rebate_rect = options.rebate_rect,
        .outputs = options.outputs,
        .film_stock = film_stock,
        .stock_coeffs = stock_coeffs,
        .dmin = dmin,
        .render_options = render_options,
        .ir_clean_options = ir_clean_options,
        .invert_request = options.invert_request,
        .inner_scene_worker_count = innerSceneWorkerCount(parallel_decision),
        .progress_sink = options.progress_sink,
    };

    const frame_processing_started = monotonicNowNs();
    if (jobs.len <= 1 or !options.parallel_frames or parallel_decision.worker_count <= 1) {
        for (jobs) |job| {
            var frame_timings = export_pipeline.ProcessFrameTimings{};
            const result = try processDirectRgbFrameJob(allocator, job, shared, &frame_timings);
            if (options.timings) |timings| timings.frame_timings.add(frame_timings);
            defer result.deinit(allocator);
            for (result.written) |name| {
                try written.append(try allocator.dupe(u8, name));
                try emitExportProgressFmt(
                    allocator,
                    options.progress_sink,
                    .wrote_file,
                    "Wrote {s}",
                    .{name},
                    name,
                );
            }
        }
    } else {
        try processDirectRgbFramesParallel(allocator, &written, jobs, parallel_decision.worker_count, shared, options.timings);
    }
    if (options.timings) |timings| timings.frame_processing_ns += monotonicNowNs() - frame_processing_started;

    const files = try written.toOwnedSlice();
    errdefer {
        for (files) |file| allocator.free(file);
        allocator.free(files);
    }
    const total_seconds = options.total_seconds_override orelse
        @as(f64, @floatFromInt(monotonicNowNs() - workflow_start_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    const progress_started = monotonicNowNs();
    var progress = try export_pipeline.buildBatchExportProgress(
        allocator,
        options.rects.len,
        need_ir,
        loaded.ir != null,
        files,
        options.output_dir,
        total_seconds,
    );
    if (options.timings) |timings| timings.progress_build_ns += monotonicNowNs() - progress_started;
    errdefer progress.deinit(allocator);
    const message_started = monotonicNowNs();
    const message = try std.fmt.allocPrint(allocator, "Exported {d} file{s} to {s}/ ({d:.1}s)", .{
        files.len,
        if (files.len == 1) "" else "s",
        options.output_dir,
        total_seconds,
    });
    if (options.timings) |timings| timings.final_message_ns += monotonicNowNs() - message_started;
    errdefer allocator.free(message);
    emitExportProgress(options.progress_sink, .{
        .kind = .complete,
        .message = message,
    });

    return .{
        .message = message,
        .files = files,
        .dmin = dmin,
        .parallelism = parallel_decision,
        .ir_adaptive_worker_count = ir_adaptive_worker_count,
        .progress = progress,
    };
}

pub fn planExportParallelism(request: ExportParallelismRequest) ExportParallelismDecision {
    const frame_count = request.rects.len;
    const cpu_count = @max(request.cpu_count, 1);
    const cpu_worker_limit = if (cpu_count <= 1) 1 else cpu_count - 1;
    const estimated_worker_peak_bytes = estimateMaxExportWorkerPeakBytes(
        request.rgb_shape,
        request.aligned_ir_shape,
        request.outputs,
        request.render_options,
        request.rects,
    );
    const adjusted_worker_peak_bytes = applyExportMemorySafetyFactor(estimated_worker_peak_bytes);
    const memory_budget_bytes = if (request.available_memory_bytes) |available| exportParallelMemoryBudget(available) else null;
    const memory_worker_limit = if (memory_budget_bytes) |budget| memoryWorkerLimit(budget, adjusted_worker_peak_bytes) else null;

    var worker_count = @min(frame_count, cpu_worker_limit);
    var memory_limited = false;
    if (memory_worker_limit) |limit| {
        if (limit < worker_count) memory_limited = true;
        worker_count = @min(worker_count, limit);
    }
    if (frame_count > 0) worker_count = @max(worker_count, 1);

    return .{
        .worker_count = worker_count,
        .cpu_count = cpu_count,
        .cpu_worker_limit = cpu_worker_limit,
        .memory_worker_limit = memory_worker_limit,
        .available_memory_bytes = request.available_memory_bytes,
        .memory_budget_bytes = memory_budget_bytes,
        .estimated_worker_peak_bytes = estimated_worker_peak_bytes,
        .adjusted_worker_peak_bytes = adjusted_worker_peak_bytes,
        .memory_limited = memory_limited,
    };
}

pub fn estimateMaxExportWorkerPeakBytes(
    rgb_shape: ExportImageShape,
    aligned_ir_shape: ?ExportImageShape,
    outputs: export_pipeline.OutputSelection,
    render_options: render.RenderToDisplayOptions,
    rects: []const export_pipeline.FrameRect,
) usize {
    var peak: usize = 0;
    for (rects) |rect| {
        peak = @max(peak, estimateFrameExportPeakBytes(rgb_shape, aligned_ir_shape, outputs, render_options, rect));
    }
    return peak;
}

pub fn estimateFrameExportPeakBytes(
    rgb_shape: ExportImageShape,
    aligned_ir_shape: ?ExportImageShape,
    outputs: export_pipeline.OutputSelection,
    render_options: render.RenderToDisplayOptions,
    rect: export_pipeline.FrameRect,
) usize {
    const crop_pixels = rectPixelCount(rect);
    if (crop_pixels == 0 or rgb_shape.channels == 0) return 0;
    const raw_samples = satMul(crop_pixels, rgb_shape.channels);
    const raw_crop_bytes = bytesFor(f64, raw_samples);
    const crop_channel_bytes = bytesFor(f64, crop_pixels);
    const rgb_plane_bytes = bytesFor(f64, shapePixels(rgb_shape));

    var retained_bytes = raw_crop_bytes;
    var peak = satAdd(satAdd(raw_crop_bytes, rgb_plane_bytes), crop_channel_bytes);
    var cleaned_crop_bytes: usize = 0;

    if (outputs.needIr()) {
        if (aligned_ir_shape) |ir_shape| {
            const ir_crop_pixels = scaledIrCropPixels(rgb_shape, ir_shape, rect);
            const ir_samples = satMul(ir_crop_pixels, ir_shape.channels);
            const ir_crop_bytes = bytesFor(f64, ir_samples);
            const ir_plane_bytes = bytesFor(f64, shapePixels(ir_shape));
            const ir_crop_channel_bytes = bytesFor(f64, ir_crop_pixels);
            peak = @max(peak, satAdd(retained_bytes, satAdd(satAdd(ir_crop_bytes, ir_plane_bytes), ir_crop_channel_bytes)));

            cleaned_crop_bytes = raw_crop_bytes;
            const ir_clean_peak = satAdd(
                retained_bytes,
                satAdd(ir_crop_bytes, satAdd(cleaned_crop_bytes, estimateIrCleanScratchBytes(crop_pixels, ir_crop_pixels))),
            );
            peak = @max(peak, ir_clean_peak);
            retained_bytes = satAdd(raw_crop_bytes, cleaned_crop_bytes);
        }
    }

    if (outputs.ir_neg) {
        const source_bytes = if (cleaned_crop_bytes != 0) cleaned_crop_bytes else raw_crop_bytes;
        peak = @max(peak, satAdd(retained_bytes, satAdd(source_bytes, bytesFor(u16, raw_samples))));
    }

    if (outputs.ir_inv) {
        peak = @max(peak, estimateInvertedOutputPeakBytes(retained_bytes, crop_pixels, raw_samples, render_options));
    }
    if (outputs.inv_only) {
        peak = @max(peak, estimateInvertedOutputPeakBytes(retained_bytes, crop_pixels, raw_samples, render_options));
    }

    return peak;
}

fn estimateInvertedOutputPeakBytes(
    retained_bytes: usize,
    crop_pixels: usize,
    rgb_samples: usize,
    render_options: render.RenderToDisplayOptions,
) usize {
    const scene_linear_bytes = bytesFor(f64, rgb_samples);
    const rendered_u16_bytes = bytesFor(u16, rgb_samples);
    const rotated_u16_bytes = bytesFor(u16, rgb_samples);
    const percentile_samples = render.percentileScratchSampleCount(crop_pixels, render_options.percentile_sample_limit);
    const percentile_sample_bytes: usize = if (percentile_samples == crop_pixels) @sizeOf(f64) else @sizeOf(f32);
    const percentile_scratch_bytes = satMul(percentile_samples, percentile_sample_bytes);
    const render_peak = satAdd(scene_linear_bytes, satAdd(rendered_u16_bytes, percentile_scratch_bytes));
    const rotation_peak = satAdd(scene_linear_bytes, satAdd(rendered_u16_bytes, rotated_u16_bytes));
    return satAdd(retained_bytes, @max(render_peak, rotation_peak));
}

fn estimateIrCleanScratchBytes(rgb_crop_pixels: usize, ir_crop_pixels: usize) usize {
    const rgb_samples = satMul(rgb_crop_pixels, 3);
    const defect_mask_peak = satAdd(
        bytesFor(f64, satMul(ir_crop_pixels, 8)),
        satAdd(bytesFor(u8, satMul(ir_crop_pixels, 6)), satAdd(bytesFor(bool, ir_crop_pixels), bytesFor(usize, satMul(ir_crop_pixels, 2)))),
    );
    const inpaint_peak = satAdd(bytesFor(f64, satMul(rgb_samples, 3)), bytesFor(u8, satMul(rgb_crop_pixels, 2)));
    return satAdd(defect_mask_peak, inpaint_peak);
}

fn exportImageShape(image: export_pipeline.Image) ExportImageShape {
    return .{ .width = image.width, .height = image.height, .channels = image.channels };
}

fn exportTiffImageShape(image: tiff.Image) ExportImageShape {
    return .{
        .width = @intCast(image.width),
        .height = @intCast(image.height),
        .channels = @intCast(image.samples_per_pixel),
    };
}

fn availableSystemMemoryBytes(io: std.Io) ?usize {
    if (linuxMemAvailableBytes(io)) |available| return available;
    const total = std.process.totalSystemMemory() catch return null;
    return std.math.cast(usize, total / 2) orelse null;
}

fn linuxMemAvailableBytes(io: std.Io) ?usize {
    var file = std.Io.Dir.openFileAbsolute(io, "/proc/meminfo", .{
        .mode = .read_only,
        .allow_directory = false,
    }) catch return null;
    defer file.close(io);

    var buffer: [64 * 1024]u8 = undefined;
    var len: usize = 0;
    var reader = file.readerStreaming(io, &.{});
    while (len < buffer.len) {
        const read_len = reader.interface.readSliceShort(buffer[len..]) catch return null;
        if (read_len == 0) break;
        len += read_len;
    }
    return parseLinuxMemAvailableBytes(buffer[0..len]);
}

fn parseLinuxMemAvailableBytes(text: []const u8) ?usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const key = "MemAvailable:";
        if (!std.mem.startsWith(u8, line, key)) continue;
        var fields = std.mem.tokenizeAny(u8, line[key.len..], " \t");
        const value_text = fields.next() orelse return null;
        const kb = std.fmt.parseInt(u64, value_text, 10) catch return null;
        const bytes = std.math.mul(u64, kb, 1024) catch return null;
        return std.math.cast(usize, bytes) orelse null;
    }
    return null;
}

fn exportParallelMemoryBudget(available_memory_bytes: usize) usize {
    if (available_memory_bytes <= export_parallel_min_system_reserve_bytes) return 0;
    const after_reserve = available_memory_bytes - export_parallel_min_system_reserve_bytes;
    return satMul(after_reserve, export_parallel_memory_budget_numerator) / export_parallel_memory_budget_denominator;
}

fn memoryWorkerLimit(memory_budget_bytes: usize, adjusted_worker_peak_bytes: usize) usize {
    if (adjusted_worker_peak_bytes == 0) return 1;
    return @max(@as(usize, 1), memory_budget_bytes / adjusted_worker_peak_bytes);
}

fn applyExportMemorySafetyFactor(estimated_bytes: usize) usize {
    if (estimated_bytes == 0) return 0;
    return satAdd(
        satMul(estimated_bytes, export_parallel_estimate_safety_numerator),
        export_parallel_estimate_safety_denominator - 1,
    ) / export_parallel_estimate_safety_denominator;
}

fn shapePixels(shape: ExportImageShape) usize {
    return satMul(shape.width, shape.height);
}

fn rectPixelCount(rect: export_pipeline.FrameRect) usize {
    return satMul(finitePositiveToUsize(rect.w), finitePositiveToUsize(rect.h));
}

fn scaledIrCropPixels(rgb_shape: ExportImageShape, ir_shape: ExportImageShape, rect: export_pipeline.FrameRect) usize {
    if (rgb_shape.width == 0 or rgb_shape.height == 0) return rectPixelCount(rect);
    const scale_x = @as(f64, @floatFromInt(ir_shape.width)) / @as(f64, @floatFromInt(rgb_shape.width));
    const scale_y = @as(f64, @floatFromInt(ir_shape.height)) / @as(f64, @floatFromInt(rgb_shape.height));
    return satMul(finitePositiveToUsize(rect.w * scale_x), finitePositiveToUsize(rect.h * scale_y));
}

fn finitePositiveToUsize(value: f64) usize {
    if (!std.math.isFinite(value) or value <= 0.0) return 0;
    const max_value: f64 = @floatFromInt(std.math.maxInt(usize));
    if (value >= max_value) return std.math.maxInt(usize);
    return @intFromFloat(value);
}

fn bytesFor(comptime T: type, element_count: usize) usize {
    return satMul(element_count, @sizeOf(T));
}

fn satAdd(lhs: usize, rhs: usize) usize {
    return std.math.add(usize, lhs, rhs) catch std.math.maxInt(usize);
}

fn satMul(lhs: usize, rhs: usize) usize {
    return std.math.mul(usize, lhs, rhs) catch std.math.maxInt(usize);
}

const FrameExportJob = struct {
    frame_index: usize,
    rect: export_pipeline.FrameRect,
    paths: OwnedOutputPaths,
};

const FrameExportShared = struct {
    rgb: export_pipeline.Image,
    aligned_ir: ?export_pipeline.Image,
    ir_scale_x: f64,
    ir_scale_y: f64,
    source: []const u8,
    dpi: ?u32,
    datetime: ?[]const u8,
    rebate_rect: ?frames.RebateOriginRect,
    outputs: export_pipeline.OutputSelection,
    film_stock: ?[]const u8,
    stock_coeffs: ?film_stocks.Coefficients,
    dmin: ?[3]f64,
    render_options: render.RenderToDisplayOptions,
    ir_clean_options: ir_processing.IrCleanOptions,
    invert_request: webgpu.Request,
    progress_sink: ?ExportProgressSink,
};

const DirectRgbFrameExportShared = struct {
    rgb_page: tiff.Image,
    source: []const u8,
    dpi: ?u32,
    datetime: ?[]const u8,
    rebate_rect: ?frames.RebateOriginRect,
    outputs: export_pipeline.OutputSelection,
    film_stock: ?[]const u8,
    stock_coeffs: ?film_stocks.Coefficients,
    dmin: [3]f64,
    render_options: render.RenderToDisplayOptions,
    ir_clean_options: ir_processing.IrCleanOptions,
    invert_request: webgpu.Request,
    inner_scene_worker_count: usize,
    progress_sink: ?ExportProgressSink,
};

const FrameExportOutcome = struct {
    backing_allocator: std.mem.Allocator = std.heap.smp_allocator,
    result: ?export_pipeline.ProcessFrameResult = null,
    err: ?anyerror = null,
    timings: export_pipeline.ProcessFrameTimings = .{},

    fn allocator(self: *FrameExportOutcome) std.mem.Allocator {
        return self.backing_allocator;
    }

    fn deinit(self: *FrameExportOutcome) void {
        const local_allocator = self.allocator();
        if (self.result) |result| result.deinit(local_allocator);
    }
};

const FrameExportQueue = struct {
    next_job: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    completed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    jobs: []const FrameExportJob,
    shared: FrameExportShared,
    outcomes: []FrameExportOutcome,
    completion_order: []usize,
};

const DirectRgbFrameExportQueue = struct {
    next_job: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    completed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    jobs: []const FrameExportJob,
    shared: DirectRgbFrameExportShared,
    outcomes: []FrameExportOutcome,
    completion_order: []usize,
};

fn processDirectRgbFrameJob(
    allocator: std.mem.Allocator,
    job: FrameExportJob,
    shared: DirectRgbFrameExportShared,
    timings: ?*export_pipeline.ProcessFrameTimings,
) !export_pipeline.ProcessFrameResult {
    const total_started = monotonicNowNs();
    var local_timings = export_pipeline.ProcessFrameTimings{};

    const invert_options = inversion.InvertOptions{
        .dmin = shared.dmin,
        .coeffs = shared.stock_coeffs,
        .stock = shared.film_stock orelse "kodak_gold",
        .request = shared.invert_request,
    };
    if (export_pipeline.f32DensityLutExportCoeffs(invert_options)) |coeffs| {
        const invert_started = monotonicNowNs();
        const density_lut = try inversion.DensityLutF32.initF32(allocator, f64TripleToF32(shared.dmin), @floatCast(invert_options.default_light));
        defer density_lut.deinit(allocator);
        const scene_linear = try cropRgbFrameFromTiffImageInvertedSceneF32(
            allocator,
            shared.rgb_page,
            job.rect,
            density_lut,
            coeffs,
            shared.inner_scene_worker_count,
        );
        local_timings.inversion_ns += monotonicNowNs() - invert_started;
        defer scene_linear.deinit(allocator);

        var body_timings = export_pipeline.ProcessFrameTimings{};
        const result = try export_pipeline.processInvertedSceneF32Frame(
            allocator,
            job.frame_index,
            scene_linear,
            .{
                .outputs = shared.outputs,
                .paths = job.paths.paths,
                .base_meta = .{
                    .source = shared.source,
                    .rebate_rect = shared.rebate_rect,
                    .crop = job.rect,
                    .dpi = shared.dpi,
                    .datetime = shared.datetime,
                },
                .film_stock = shared.film_stock,
                .stock_coeffs = shared.stock_coeffs,
                .dmin = shared.dmin,
                .render_options = shared.render_options,
                .ir_clean_options = shared.ir_clean_options,
                .invert_request = shared.invert_request,
                .timings = &body_timings,
            },
        );
        local_timings.add(body_timings);
        local_timings.total_ns = monotonicNowNs() - total_started;
        if (timings) |out| out.* = local_timings;
        return result;
    }

    const crop_started = monotonicNowNs();
    const raw_crop = try cropRgbFrameFromTiffImage(allocator, shared.rgb_page, job.rect);
    local_timings.rgb_crop_ns += monotonicNowNs() - crop_started;
    defer raw_crop.deinit(allocator);

    var body_timings = export_pipeline.ProcessFrameTimings{};
    const result = try export_pipeline.processCroppedFrame(
        allocator,
        job.frame_index,
        raw_crop,
        .{
            .outputs = shared.outputs,
            .paths = job.paths.paths,
            .base_meta = .{
                .source = shared.source,
                .rebate_rect = shared.rebate_rect,
                .crop = job.rect,
                .dpi = shared.dpi,
                .datetime = shared.datetime,
            },
            .film_stock = shared.film_stock,
            .stock_coeffs = shared.stock_coeffs,
            .dmin = shared.dmin,
            .render_options = shared.render_options,
            .ir_clean_options = shared.ir_clean_options,
            .invert_request = shared.invert_request,
            .timings = &body_timings,
        },
    );
    local_timings.add(body_timings);
    local_timings.total_ns = monotonicNowNs() - total_started;
    if (timings) |out| out.* = local_timings;
    return result;
}

fn processDirectRgbFramesParallel(
    allocator: std.mem.Allocator,
    written: *std.array_list.Managed([]u8),
    jobs: []const FrameExportJob,
    worker_count: usize,
    shared: DirectRgbFrameExportShared,
    timings: ?*ExportWorkflowTimings,
) !void {
    std.debug.assert(jobs.len > 1);
    std.debug.assert(worker_count > 1);
    std.debug.assert(worker_count <= jobs.len);

    const setup_started = monotonicNowNs();
    const outcomes = try allocator.alloc(FrameExportOutcome, jobs.len);
    defer allocator.free(outcomes);
    for (outcomes) |*outcome| outcome.* = .{};
    defer for (outcomes) |*outcome| outcome.deinit();

    const completion_order = try allocator.alloc(usize, jobs.len);
    defer allocator.free(completion_order);

    var queue = DirectRgbFrameExportQueue{
        .jobs = jobs,
        .shared = shared,
        .outcomes = outcomes,
        .completion_order = completion_order,
    };

    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    var thread_count: usize = 0;
    errdefer for (threads[0..thread_count]) |thread| thread.join();
    if (timings) |out| out.worker_setup_ns += monotonicNowNs() - setup_started;
    const scheduler_started = monotonicNowNs();
    while (thread_count < worker_count) : (thread_count += 1) {
        threads[thread_count] = try std.Thread.spawn(.{}, directRgbFrameExportWorker, .{&queue});
    }
    for (threads[0..thread_count]) |thread| thread.join();
    if (timings) |out| out.scheduler_wait_ns += monotonicNowNs() - scheduler_started;

    const completed = queue.completed.load(.seq_cst);
    if (completed != jobs.len) return error.ExportFrameWorkerIncomplete;

    const merge_started = monotonicNowNs();
    for (completion_order[0..completed]) |job_index| {
        const outcome = &outcomes[job_index];
        if (outcome.err) |err| return err;
        const result = outcome.result orelse return error.ExportFrameWorkerIncomplete;
        if (timings) |out| out.frame_timings.add(outcome.timings);
        for (result.written) |name| {
            try written.append(try allocator.dupe(u8, name));
        }
    }
    if (timings) |out| out.result_merge_ns += monotonicNowNs() - merge_started;
}

fn directRgbFrameExportWorker(queue: *DirectRgbFrameExportQueue) void {
    while (true) {
        const job_index = queue.next_job.fetchAdd(1, .seq_cst);
        if (job_index >= queue.jobs.len) return;

        const job = queue.jobs[job_index];
        const outcome = &queue.outcomes[job_index];
        const local_allocator = outcome.allocator();
        outcome.result = processDirectRgbFrameJob(
            local_allocator,
            job,
            queue.shared,
            &outcome.timings,
        ) catch |err| {
            outcome.err = err;
            const slot = queue.completed.fetchAdd(1, .seq_cst);
            queue.completion_order[slot] = job_index;
            return;
        };

        if (outcome.result) |result| {
            for (result.written) |name| {
                emitExportProgressFmt(
                    local_allocator,
                    queue.shared.progress_sink,
                    .wrote_file,
                    "Wrote {s}",
                    .{name},
                    name,
                ) catch {};
            }
        }
        const slot = queue.completed.fetchAdd(1, .seq_cst);
        queue.completion_order[slot] = job_index;
    }
}

fn processExportFramesParallel(
    allocator: std.mem.Allocator,
    written: *std.array_list.Managed([]u8),
    jobs: []const FrameExportJob,
    worker_count: usize,
    shared: FrameExportShared,
    timings: ?*ExportWorkflowTimings,
) !void {
    std.debug.assert(jobs.len > 1);
    std.debug.assert(worker_count > 1);
    std.debug.assert(worker_count <= jobs.len);

    const setup_started = monotonicNowNs();
    const outcomes = try allocator.alloc(FrameExportOutcome, jobs.len);
    defer allocator.free(outcomes);
    for (outcomes) |*outcome| outcome.* = .{};
    defer for (outcomes) |*outcome| outcome.deinit();

    const completion_order = try allocator.alloc(usize, jobs.len);
    defer allocator.free(completion_order);

    var queue = FrameExportQueue{
        .jobs = jobs,
        .shared = shared,
        .outcomes = outcomes,
        .completion_order = completion_order,
    };

    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    var thread_count: usize = 0;
    errdefer for (threads[0..thread_count]) |thread| thread.join();
    if (timings) |out| out.worker_setup_ns += monotonicNowNs() - setup_started;
    const scheduler_started = monotonicNowNs();
    while (thread_count < worker_count) : (thread_count += 1) {
        threads[thread_count] = try std.Thread.spawn(.{}, frameExportWorker, .{&queue});
    }
    for (threads[0..thread_count]) |thread| thread.join();
    if (timings) |out| out.scheduler_wait_ns += monotonicNowNs() - scheduler_started;

    const completed = queue.completed.load(.seq_cst);
    if (completed != jobs.len) return error.ExportFrameWorkerIncomplete;

    const merge_started = monotonicNowNs();
    for (completion_order[0..completed]) |job_index| {
        const outcome = &outcomes[job_index];
        if (outcome.err) |err| return err;
        const result = outcome.result orelse return error.ExportFrameWorkerIncomplete;
        if (timings) |out| out.frame_timings.add(outcome.timings);
        for (result.written) |name| {
            try written.append(try allocator.dupe(u8, name));
        }
    }
    if (timings) |out| out.result_merge_ns += monotonicNowNs() - merge_started;
}

fn frameExportWorker(queue: *FrameExportQueue) void {
    while (true) {
        const job_index = queue.next_job.fetchAdd(1, .seq_cst);
        if (job_index >= queue.jobs.len) return;

        const job = queue.jobs[job_index];
        const outcome = &queue.outcomes[job_index];
        const local_allocator = outcome.allocator();
        var prng = std.Random.DefaultPrng.init(frameExportSeed(job.frame_index));
        outcome.result = export_pipeline.processFrame(
            local_allocator,
            job.frame_index,
            job.rect,
            queue.shared.rgb,
            queue.shared.aligned_ir,
            queue.shared.ir_scale_x,
            queue.shared.ir_scale_y,
            .{
                .outputs = queue.shared.outputs,
                .paths = job.paths.paths,
                .base_meta = .{
                    .source = queue.shared.source,
                    .rebate_rect = queue.shared.rebate_rect,
                    .crop = job.rect,
                    .dpi = queue.shared.dpi,
                    .datetime = queue.shared.datetime,
                },
                .film_stock = queue.shared.film_stock,
                .stock_coeffs = queue.shared.stock_coeffs,
                .dmin = queue.shared.dmin,
                .render_options = queue.shared.render_options,
                .ir_clean_options = queue.shared.ir_clean_options,
                .invert_request = queue.shared.invert_request,
                .random = prng.random(),
                .timings = &outcome.timings,
            },
        ) catch |err| {
            outcome.err = err;
            const slot = queue.completed.fetchAdd(1, .seq_cst);
            queue.completion_order[slot] = job_index;
            return;
        };

        if (outcome.result) |result| {
            for (result.written) |name| {
                emitExportProgressFmt(
                    local_allocator,
                    queue.shared.progress_sink,
                    .wrote_file,
                    "Wrote {s}",
                    .{name},
                    name,
                ) catch {};
            }
        }
        const slot = queue.completed.fetchAdd(1, .seq_cst);
        queue.completion_order[slot] = job_index;
    }
}

pub fn frameExportSeed(frame_index: usize) u64 {
    return 0x563030 + @as(u64, @intCast(frame_index));
}

fn emitExportProgress(sink: ?ExportProgressSink, notice: ExportProgressNotice) void {
    if (sink) |target| target.emit(target.context, notice);
}

fn emitExportProgressFmt(
    allocator: std.mem.Allocator,
    sink: ?ExportProgressSink,
    kind: export_pipeline.ExportProgressKind,
    comptime fmt: []const u8,
    args: anytype,
    file_name: ?[]const u8,
) !void {
    if (sink == null) return;
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    emitExportProgress(sink, .{
        .kind = kind,
        .message = message,
        .file_name = file_name,
    });
}

pub fn encodeRgbJpeg(
    allocator: std.mem.Allocator,
    rgb: []const u8,
    width: usize,
    height: usize,
    quality: u8,
) ![]u8 {
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, width, height), 3);
    if (rgb.len != sample_count) return error.InvalidPreviewBuffer;
    var jpeg_len: c_int = 0;
    const first = cerealgrain_encode_rgb_jpeg(
        rgb.ptr,
        try toCInt(width),
        try toCInt(height),
        try toCInt(quality),
        null,
        0,
        &jpeg_len,
    );
    if (first < 0 or jpeg_len <= 0) return error.JpegEncodeFailed;
    const jpeg = try allocator.alloc(u8, @intCast(jpeg_len));
    errdefer allocator.free(jpeg);
    var second_len: c_int = 0;
    const second = cerealgrain_encode_rgb_jpeg(
        rgb.ptr,
        try toCInt(width),
        try toCInt(height),
        try toCInt(quality),
        jpeg.ptr,
        try toCInt(jpeg.len),
        &second_len,
    );
    if (second != 0 or second_len <= 0 or @as(usize, @intCast(second_len)) != jpeg.len) {
        return error.JpegEncodeFailed;
    }
    return jpeg;
}

pub fn previewScale(width: usize, height: usize, preview_size: i64) f64 {
    if (preview_size <= 0) return 1.0;
    const max_dim = @max(width, height);
    if (max_dim == 0) return 1.0;
    const scale = @as(f64, @floatFromInt(preview_size)) / @as(f64, @floatFromInt(max_dim));
    return @min(scale, 1.0);
}

const QuickPreviewGeometry = struct {
    width: usize,
    height: usize,
    scale: f64,
};

fn quickPreviewGeometry(width: usize, height: usize, preview_size: i64) QuickPreviewGeometry {
    const scale = previewScale(width, height, preview_size);
    if (scale >= 1.0) {
        return .{ .width = width, .height = height, .scale = 1.0 };
    }
    return .{
        .width = @intFromFloat(@as(f64, @floatFromInt(width)) * scale),
        .height = @intFromFloat(@as(f64, @floatFromInt(height)) * scale),
        .scale = scale,
    };
}

pub fn dpiScale(dpi: ?u32) f64 {
    const value = dpi orelse return 1.0;
    const scale = @as(f64, @floatFromInt(value)) / @as(f64, @floatFromInt(config.reference_dpi));
    return @round(scale * 100.0) / 100.0;
}

fn imageSearchDirectory(io: std.Io, path: []const u8) []const u8 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return path;
    if (stat.kind != .file) return path;
    return std.fs.path.dirname(path) orelse ".";
}

fn toCInt(value: anytype) !c_int {
    return std.math.cast(c_int, value) orelse error.ValueTooLarge;
}

fn tiffImageToF64(allocator: std.mem.Allocator, image: tiff.Image) !export_pipeline.Image {
    const width: usize = image.width;
    const height: usize = image.height;
    const channels: usize = image.samples_per_pixel;
    if (channels != 1 and channels != 3) return error.UnsupportedProcessingImage;
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, width, height), channels);
    const pixels = try allocator.alloc(f64, sample_count);
    errdefer allocator.free(pixels);
    switch (image.bits_per_sample) {
        8 => {
            if (image.data.len != sample_count) return error.UnsupportedProcessingImage;
            try fillTiffF64Samples(allocator, image.data, pixels, 8);
        },
        16 => {
            if (image.data.len != sample_count * 2) return error.UnsupportedProcessingImage;
            try fillTiffF64Samples(allocator, image.data, pixels, 16);
        },
        else => return error.UnsupportedProcessingImage,
    }
    return .{ .width = width, .height = height, .channels = channels, .pixels = pixels };
}

const TiffF64RangeContext = struct {
    data: []const u8,
    pixels: []f64,
    bits_per_sample: u16,
    start: usize,
    end: usize,
};

fn fillTiffF64Samples(
    allocator: std.mem.Allocator,
    data: []const u8,
    pixels: []f64,
    bits_per_sample: u16,
) !void {
    const worker_count = workerCountForItems(pixels.len, tiff_to_f64_parallel_min_samples);
    if (worker_count <= 1) {
        fillTiffF64SamplesRange(data, pixels, bits_per_sample, 0, pixels.len);
        return;
    }

    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(TiffF64RangeContext, worker_count);
    defer allocator.free(contexts);
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (0..worker_count) |worker_index| {
        const start = pixels.len * worker_index / worker_count;
        const end = pixels.len * (worker_index + 1) / worker_count;
        contexts[worker_index] = .{
            .data = data,
            .pixels = pixels,
            .bits_per_sample = bits_per_sample,
            .start = start,
            .end = end,
        };
        threads[worker_index] = try std.Thread.spawn(.{}, fillTiffF64SamplesWorker, .{&contexts[worker_index]});
        started += 1;
    }
    for (threads) |thread| thread.join();
}

fn fillTiffF64SamplesWorker(context: *const TiffF64RangeContext) void {
    fillTiffF64SamplesRange(context.data, context.pixels, context.bits_per_sample, context.start, context.end);
}

fn fillTiffF64SamplesRange(
    data: []const u8,
    pixels: []f64,
    bits_per_sample: u16,
    start: usize,
    end: usize,
) void {
    switch (bits_per_sample) {
        8 => {
            for (start..end) |index| pixels[index] = @floatFromInt(data[index]);
        },
        16 => {
            for (start..end) |index| {
                pixels[index] = @floatFromInt(std.mem.readInt(u16, data[index * 2 ..][0..2], .little));
            }
        },
        else => unreachable,
    }
}

fn workerCountForItems(item_count: usize, min_items: usize) usize {
    if (item_count < min_items) return 1;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    if (cpu_count <= 1) return 1;
    return @min(cpu_count - 1, item_count / min_items);
}

fn innerSceneWorkerCount(decision: ExportParallelismDecision) usize {
    if (decision.worker_count == 0 or decision.cpu_worker_limit <= decision.worker_count) return 1;
    return @max(@as(usize, 1), decision.cpu_worker_limit / decision.worker_count);
}

fn innerAdaptiveDustWorkerCount(decision: ExportParallelismDecision) usize {
    return innerSceneWorkerCount(decision);
}

fn adaptiveDustWorkerCountForOptions(options: ExportWorkflowOptions, decision: ExportParallelismDecision) usize {
    if (options.adaptive_dust_worker_count_override) |worker_count| return @max(@as(usize, 1), worker_count);
    return innerAdaptiveDustWorkerCount(decision);
}

fn cropRgbFrameFromTiffImage(
    allocator: std.mem.Allocator,
    image: tiff.Image,
    rect: export_pipeline.FrameRect,
) !export_pipeline.Image {
    const width: usize = image.width;
    const height: usize = image.height;
    if (width == 0 or height == 0 or image.samples_per_pixel != 3) return error.UnsupportedProcessingImage;
    if (image.bits_per_sample != 8 and image.bits_per_sample != 16) return error.UnsupportedProcessingImage;
    const bytes_per_sample: usize = image.bits_per_sample / 8;
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, width, height), 3);
    if (image.data.len != try std.math.mul(usize, sample_count, bytes_per_sample)) return error.UnsupportedProcessingImage;
    if (!std.math.isFinite(rect.cx) or !std.math.isFinite(rect.cy) or !std.math.isFinite(rect.w) or !std.math.isFinite(rect.h) or !std.math.isFinite(rect.angle)) {
        return error.InvalidRotatedCropInput;
    }
    if (rect.w <= 0.0 or rect.h <= 0.0) return error.InvalidRotatedCropInput;

    const final_w: usize = @intFromFloat(rect.w);
    const final_h: usize = @intFromFloat(rect.h);
    if (final_w == 0 or final_h == 0) return error.InvalidRotatedCropInput;

    const diag = @sqrt(rect.w * rect.w + rect.h * rect.h) / 2.0;
    const margin: i64 = @as(i64, @intFromFloat(@ceil(diag))) + 4;
    const cx_i: i64 = @intFromFloat(rect.cx);
    const cy_i: i64 = @intFromFloat(rect.cy);
    const x0_i = @max(cx_i - margin, 0);
    const y0_i = @max(cy_i - margin, 0);
    const x1_i = @min(cx_i + margin, @as(i64, @intCast(width)));
    const y1_i = @min(cy_i + margin, @as(i64, @intCast(height)));
    if (x1_i <= x0_i or y1_i <= y0_i) return error.InvalidRotatedCropInput;

    const x0: usize = @intCast(x0_i);
    const y0: usize = @intCast(y0_i);
    const sub_w: usize = @intCast(x1_i - x0_i);
    const sub_h: usize = @intCast(y1_i - y0_i);
    const local_cx = rect.cx - @as(f64, @floatFromInt(x0));
    const local_cy = rect.cy - @as(f64, @floatFromInt(y0));

    const pad: usize = 2;
    const out_w: usize = @as(usize, @intFromFloat(@ceil(rect.w))) + pad * 2;
    const out_h: usize = @as(usize, @intFromFloat(@ceil(rect.h))) + pad * 2;
    const radians = rect.angle * std.math.pi / 180.0;
    const alpha = @cos(radians);
    const beta = @sin(radians);
    const m00 = alpha;
    const m01 = beta;
    var m02 = (1.0 - alpha) * local_cx - beta * local_cy;
    const m10 = -beta;
    const m11 = alpha;
    var m12 = beta * local_cx + (1.0 - alpha) * local_cy;
    m02 += @as(f64, @floatFromInt(out_w)) / 2.0 - local_cx;
    m12 += @as(f64, @floatFromInt(out_h)) / 2.0 - local_cy;

    const det = m00 * m11 - m01 * m10;
    if (@abs(det) < 1e-12) return error.InvalidRotatedCropInput;
    const inv00 = m11 / det;
    const inv01 = -m01 / det;
    const inv10 = -m10 / det;
    const inv11 = m00 / det;

    const output = try allocator.alloc(f64, final_w * final_h * 3);
    errdefer allocator.free(output);
    for (0..final_h) |out_y| {
        for (0..final_w) |out_x| {
            const dst_x = @as(f64, @floatFromInt(out_x + pad));
            const dst_y = @as(f64, @floatFromInt(out_y + pad));
            const tx = dst_x - m02;
            const ty = dst_y - m12;
            const src_x = inv00 * tx + inv01 * ty;
            const src_y = inv10 * tx + inv11 * ty;
            const out_base = (out_y * final_w + out_x) * 3;
            sampleTiffReflectBilinearRgb(
                image,
                x0,
                y0,
                sub_w,
                sub_h,
                src_x,
                src_y,
                output[out_base..][0..3],
            );
        }
    }

    return .{ .width = final_w, .height = final_h, .channels = 3, .pixels = output };
}

fn cropRgbFrameFromTiffImageInvertedSceneF32(
    allocator: std.mem.Allocator,
    image: tiff.Image,
    rect: export_pipeline.FrameRect,
    density_lut: inversion.DensityLutF32,
    coeffs: film_stocks.Coefficients,
    max_workers: usize,
) !export_pipeline.ImageF32 {
    const width: usize = image.width;
    const height: usize = image.height;
    if (width == 0 or height == 0 or image.samples_per_pixel != 3) return error.UnsupportedProcessingImage;
    if (image.bits_per_sample != 8 and image.bits_per_sample != 16) return error.UnsupportedProcessingImage;
    const bytes_per_sample: usize = image.bits_per_sample / 8;
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, width, height), 3);
    if (image.data.len != try std.math.mul(usize, sample_count, bytes_per_sample)) return error.UnsupportedProcessingImage;
    if (!std.math.isFinite(rect.cx) or !std.math.isFinite(rect.cy) or !std.math.isFinite(rect.w) or !std.math.isFinite(rect.h) or !std.math.isFinite(rect.angle)) {
        return error.InvalidRotatedCropInput;
    }
    if (rect.w <= 0.0 or rect.h <= 0.0) return error.InvalidRotatedCropInput;

    const final_w: usize = @intFromFloat(rect.w);
    const final_h: usize = @intFromFloat(rect.h);
    if (final_w == 0 or final_h == 0) return error.InvalidRotatedCropInput;

    const diag = @sqrt(rect.w * rect.w + rect.h * rect.h) / 2.0;
    const margin: i64 = @as(i64, @intFromFloat(@ceil(diag))) + 4;
    const cx_i: i64 = @intFromFloat(rect.cx);
    const cy_i: i64 = @intFromFloat(rect.cy);
    const x0_i = @max(cx_i - margin, 0);
    const y0_i = @max(cy_i - margin, 0);
    const x1_i = @min(cx_i + margin, @as(i64, @intCast(width)));
    const y1_i = @min(cy_i + margin, @as(i64, @intCast(height)));
    if (x1_i <= x0_i or y1_i <= y0_i) return error.InvalidRotatedCropInput;

    const x0: usize = @intCast(x0_i);
    const y0: usize = @intCast(y0_i);
    const sub_w: usize = @intCast(x1_i - x0_i);
    const sub_h: usize = @intCast(y1_i - y0_i);
    const local_cx = rect.cx - @as(f64, @floatFromInt(x0));
    const local_cy = rect.cy - @as(f64, @floatFromInt(y0));

    const pad: usize = 2;
    const out_w: usize = @as(usize, @intFromFloat(@ceil(rect.w))) + pad * 2;
    const out_h: usize = @as(usize, @intFromFloat(@ceil(rect.h))) + pad * 2;
    const radians = rect.angle * std.math.pi / 180.0;
    const alpha = @cos(radians);
    const beta = @sin(radians);
    const m00 = alpha;
    const m01 = beta;
    var m02 = (1.0 - alpha) * local_cx - beta * local_cy;
    const m10 = -beta;
    const m11 = alpha;
    var m12 = beta * local_cx + (1.0 - alpha) * local_cy;
    m02 += @as(f64, @floatFromInt(out_w)) / 2.0 - local_cx;
    m12 += @as(f64, @floatFromInt(out_h)) / 2.0 - local_cy;

    const det = m00 * m11 - m01 * m10;
    if (@abs(det) < 1e-12) return error.InvalidRotatedCropInput;
    const inv00 = m11 / det;
    const inv01 = -m01 / det;
    const inv10 = -m10 / det;
    const inv11 = m00 / det;

    const output = try allocator.alloc(f32, final_w * final_h * 3);
    errdefer allocator.free(output);
    const linear_coeffs = linearF32Coeffs(coeffs);
    const worker_count = @min(max_workers, final_h);
    if (worker_count <= 1 or final_h < 64) {
        var context = FusedCropSceneWorkerContext{
            .image = image,
            .x0 = x0,
            .y0 = y0,
            .sub_w = sub_w,
            .sub_h = sub_h,
            .final_w = final_w,
            .row_start = 0,
            .row_end = final_h,
            .pad = pad,
            .m02 = m02,
            .m12 = m12,
            .inv00 = inv00,
            .inv01 = inv01,
            .inv10 = inv10,
            .inv11 = inv11,
            .density_lut = density_lut,
            .coeffs = linear_coeffs,
            .output = output,
        };
        fusedCropSceneWorker(&context);
    } else {
        const contexts = try allocator.alloc(FusedCropSceneWorkerContext, worker_count);
        defer allocator.free(contexts);
        const threads = try allocator.alloc(std.Thread, worker_count - 1);
        defer allocator.free(threads);
        var spawned_len: usize = 0;
        errdefer {
            for (threads[0..spawned_len]) |thread| thread.join();
        }

        for (0..worker_count) |index| {
            const row_start = index * final_h / worker_count;
            const row_end = (index + 1) * final_h / worker_count;
            contexts[index] = .{
                .image = image,
                .x0 = x0,
                .y0 = y0,
                .sub_w = sub_w,
                .sub_h = sub_h,
                .final_w = final_w,
                .row_start = row_start,
                .row_end = row_end,
                .pad = pad,
                .m02 = m02,
                .m12 = m12,
                .inv00 = inv00,
                .inv01 = inv01,
                .inv10 = inv10,
                .inv11 = inv11,
                .density_lut = density_lut,
                .coeffs = linear_coeffs,
                .output = output,
            };
        }

        for (1..worker_count) |index| {
            threads[spawned_len] = try std.Thread.spawn(.{}, fusedCropSceneWorker, .{&contexts[index]});
            spawned_len += 1;
        }
        fusedCropSceneWorker(&contexts[0]);
        for (threads[0..spawned_len]) |thread| thread.join();
    }

    return .{ .width = final_w, .height = final_h, .channels = 3, .pixels = output };
}

fn sampleTiffReflectBilinearRgb(
    image: tiff.Image,
    x0: usize,
    y0: usize,
    sub_w: usize,
    sub_h: usize,
    x: f64,
    y: f64,
    out: []f64,
) void {
    const x_floor = @floor(x);
    const y_floor = @floor(y);
    const xi: i64 = @intFromFloat(x_floor);
    const yi: i64 = @intFromFloat(y_floor);
    const fx = x - x_floor;
    const fy = y - y_floor;
    const x_a = reflectIndex(xi, sub_w);
    const x_b = reflectIndex(xi + 1, sub_w);
    const y_a = reflectIndex(yi, sub_h);
    const y_b = reflectIndex(yi + 1, sub_h);
    const img_width: usize = @intCast(image.width);
    const offset00 = ((y0 + y_a) * img_width + x0 + x_a) * 3;
    const offset10 = ((y0 + y_a) * img_width + x0 + x_b) * 3;
    const offset01 = ((y0 + y_b) * img_width + x0 + x_a) * 3;
    const offset11 = ((y0 + y_b) * img_width + x0 + x_b) * 3;
    for (0..3) |channel| {
        const p00 = tiffSampleIndexAsF64(image, offset00 + channel);
        const p10 = tiffSampleIndexAsF64(image, offset10 + channel);
        const p01 = tiffSampleIndexAsF64(image, offset01 + channel);
        const p11 = tiffSampleIndexAsF64(image, offset11 + channel);
        const top = p00 * (1.0 - fx) + p10 * fx;
        const bottom = p01 * (1.0 - fx) + p11 * fx;
        out[channel] = top * (1.0 - fy) + bottom * fy;
    }
}

const LinearF32Coeffs = struct {
    c00: f32,
    c01: f32,
    c02: f32,
    c10: f32,
    c11: f32,
    c12: f32,
    c20: f32,
    c21: f32,
    c22: f32,
};

const FusedCropSceneWorkerContext = struct {
    image: tiff.Image,
    x0: usize,
    y0: usize,
    sub_w: usize,
    sub_h: usize,
    final_w: usize,
    row_start: usize,
    row_end: usize,
    pad: usize,
    m02: f64,
    m12: f64,
    inv00: f64,
    inv01: f64,
    inv10: f64,
    inv11: f64,
    density_lut: inversion.DensityLutF32,
    coeffs: LinearF32Coeffs,
    output: []f32,
};

fn linearF32Coeffs(coeffs: film_stocks.Coefficients) LinearF32Coeffs {
    return .{
        .c00 = @floatCast(coeffs[0][0]),
        .c01 = @floatCast(coeffs[0][1]),
        .c02 = @floatCast(coeffs[0][2]),
        .c10 = @floatCast(coeffs[1][0]),
        .c11 = @floatCast(coeffs[1][1]),
        .c12 = @floatCast(coeffs[1][2]),
        .c20 = @floatCast(coeffs[2][0]),
        .c21 = @floatCast(coeffs[2][1]),
        .c22 = @floatCast(coeffs[2][2]),
    };
}

fn fusedCropSceneWorker(context: *const FusedCropSceneWorkerContext) void {
    for (context.row_start..context.row_end) |out_y| {
        for (0..context.final_w) |out_x| {
            const dst_x = @as(f64, @floatFromInt(out_x + context.pad));
            const dst_y = @as(f64, @floatFromInt(out_y + context.pad));
            const tx = dst_x - context.m02;
            const ty = dst_y - context.m12;
            const src_x = context.inv00 * tx + context.inv01 * ty;
            const src_y = context.inv10 * tx + context.inv11 * ty;
            const out_base = (out_y * context.final_w + out_x) * 3;
            sampleTiffReflectBilinearRgbInvertedSceneF32(
                context.image,
                context.x0,
                context.y0,
                context.sub_w,
                context.sub_h,
                src_x,
                src_y,
                context.density_lut,
                context.coeffs,
                context.output[out_base..][0..3],
            );
        }
    }
}

fn sampleTiffReflectBilinearRgbInvertedSceneF32(
    image: tiff.Image,
    x0: usize,
    y0: usize,
    sub_w: usize,
    sub_h: usize,
    x: f64,
    y: f64,
    density_lut: inversion.DensityLutF32,
    coeffs: LinearF32Coeffs,
    out: []f32,
) void {
    var raw: [3]f64 = undefined;
    sampleTiffReflectBilinearRgb(image, x0, y0, sub_w, sub_h, x, y, raw[0..]);
    const dr = density_lut.lookupSampleF64(0, raw[0]);
    const dg = density_lut.lookupSampleF64(1, raw[1]);
    const db = density_lut.lookupSampleF64(2, raw[2]);
    out[0] = @max(dr * coeffs.c00 + dg * coeffs.c10 + db * coeffs.c20, 0.0);
    out[1] = @max(dr * coeffs.c01 + dg * coeffs.c11 + db * coeffs.c21, 0.0);
    out[2] = @max(dr * coeffs.c02 + dg * coeffs.c12 + db * coeffs.c22, 0.0);
}

fn tiffSampleIndexAsF64(image: tiff.Image, sample_index: usize) f64 {
    return switch (image.bits_per_sample) {
        8 => @floatFromInt(image.data[sample_index]),
        16 => @floatFromInt(std.mem.readInt(u16, image.data[sample_index * 2 ..][0..2], .little)),
        else => unreachable,
    };
}

fn f64TripleToF32(values: [3]f64) [3]f32 {
    return .{ @floatCast(values[0]), @floatCast(values[1]), @floatCast(values[2]) };
}

fn reflectIndex(index: i64, len: usize) usize {
    if (len <= 1) return 0;
    const n: i64 = @intCast(len);
    var reflected = index;
    while (reflected < 0 or reflected >= n) {
        if (reflected < 0) {
            reflected = -reflected - 1;
        } else {
            reflected = 2 * n - reflected - 1;
        }
    }
    return @intCast(reflected);
}

const OwnedOutputPaths = struct {
    paths: export_pipeline.OutputPaths,

    fn deinit(self: OwnedOutputPaths, allocator: std.mem.Allocator) void {
        if (self.paths.ir_neg) |path| allocator.free(path);
        if (self.paths.ir_inv) |path| allocator.free(path);
        if (self.paths.inv_only) |path| allocator.free(path);
    }
};

fn outputPathsForFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
    basename: []const u8,
    frame_index: usize,
    outputs: export_pipeline.OutputSelection,
    print_spec: ?print.Spec,
) !OwnedOutputPaths {
    var result = OwnedOutputPaths{ .paths = .{ .print = print_spec } };
    errdefer result.deinit(allocator);
    if (outputs.ir_neg) result.paths.ir_neg = try export_pipeline.uniqueFrameOutputPath(allocator, io, output_dir, basename, frame_index, .ir_neg);
    if (outputs.ir_inv) result.paths.ir_inv = try export_pipeline.uniqueFrameOutputPath(allocator, io, output_dir, basename, frame_index, .ir_inv);
    if (outputs.inv_only) result.paths.inv_only = try export_pipeline.uniqueFrameOutputPath(allocator, io, output_dir, basename, frame_index, .inv_only);
    return result;
}

fn noOutputExportResult(allocator: std.mem.Allocator) !ExportWorkflowResult {
    return .{
        .message = try allocator.dupe(u8, "No output variants selected"),
        .files = try allocator.alloc([]u8, 0),
        .progress = .{ .events = try allocator.alloc(export_pipeline.ExportProgressEvent, 0) },
    };
}

pub fn renderOptionsForConfig(current_dpi: ?u32, overrides: []const config.Override) render.RenderToDisplayOptions {
    return .{
        .contrast = config.getParam("render_contrast", current_dpi, overrides).?.asFloat(),
        .percentile_lo = config.getParam("render_percentile_lo", current_dpi, overrides).?.asFloat(),
        .percentile_hi = config.getParam("render_percentile_hi", current_dpi, overrides).?.asFloat(),
        .exposure_compensation = config.getParam("exposure_compensation", current_dpi, overrides).?.asFloat(),
        .color_temp = config.getParam("color_temp", current_dpi, overrides).?.asFloat(),
        .color_tint = config.getParam("color_tint", current_dpi, overrides).?.asFloat(),
        .auto_white_balance = config.getParam("auto_white_balance", current_dpi, overrides).?.asFloat(),
        .film_gamma = config.getParam("film_gamma", current_dpi, overrides).?.asFloat(),
        .film_toe = config.getParam("film_toe", current_dpi, overrides).?.asFloat(),
        .dye_crosstalk = config.getParam("dye_crosstalk", current_dpi, overrides).?.asFloat(),
    };
}

/// The defect mask is built on the IR page, which is often scanned at a
/// lower resolution than the RGB (6400 dpi RGB has a 3200 dpi IR pass), so
/// its sizes scale with the IR's dpi; inpainting runs on the RGB, so its
/// padding scales with the RGB's.
pub fn irCleanOptionsForConfig(rgb_dpi: ?u32, ir_dpi: ?u32, overrides: []const config.Override) ir_processing.IrCleanOptions {
    return .{
        .defect_mask = .{
            .threshold = config.getParam("ir_threshold", ir_dpi, overrides).?.asFloat(),
            .hair_sensitivity = config.getParam("ir_hair_sensitivity", ir_dpi, overrides).?.asFloat(),
            .min_area = @intFromFloat(config.getParam("ir_min_area", ir_dpi, overrides).?.asFloat()),
            .dilate_radius = @intFromFloat(config.getParam("ir_dilate_radius", ir_dpi, overrides).?.asFloat()),
            .close_radius = @intFromFloat(config.getParam("ir_close_radius", ir_dpi, overrides).?.asFloat()),
            .blur_size = @intFromFloat(config.getParam("ir_blur_size", ir_dpi, overrides).?.asFloat()),
            .max_coverage = config.getParam("ir_max_coverage", ir_dpi, overrides).?.asFloat(),
            .adaptive_precision = .f32,
        },
        .inpaint = .{
            .padding = @intFromFloat(config.getParam("inpaint_padding", rgb_dpi, overrides).?.asFloat()),
            .grain_padding = 8,
            .value_kind = .uint16,
        },
    };
}

/// The IR page's dpi: the RGB's, scaled by the IR's width over the RGB's.
pub fn irDpi(rgb_dpi: ?u32, ir_scale: f64) ?u32 {
    const dpi = rgb_dpi orelse return null;
    return @intFromFloat(@round(@as(f64, @floatFromInt(dpi)) * ir_scale));
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "IR clean options size the mask by the IR's dpi and the inpaint by the RGB's" {
    // 6400 dpi RGB with its 3200 dpi IR pass (5031 of 10063 columns).
    const ir_dpi = irDpi(6400, 5031.0 / 10063.0);
    try std.testing.expectEqual(@as(?u32, 3200), ir_dpi);
    const options = irCleanOptionsForConfig(6400, ir_dpi, &.{});
    try std.testing.expectEqual(@as(usize, 16), options.defect_mask.dilate_radius);
    try std.testing.expectEqual(@as(usize, 24), options.defect_mask.close_radius);
    try std.testing.expectEqual(@as(usize, 48), options.defect_mask.min_area);
    try std.testing.expectEqual(@as(usize, 1205), options.defect_mask.blur_size);
    try std.testing.expectEqual(@as(usize, 128), options.inpaint.padding);
    try std.testing.expectEqual(@as(?u32, null), irDpi(null, 0.5));
}

test "process image search uses parent directory for file inputs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.TIFF", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "A.tif", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "current.tiff", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan.png", .data = "" });

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/current.tiff", .{dir_path});
    defer allocator.free(file_path);

    const images = try findImages(allocator, std.testing.io, file_path);
    defer images.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), images.paths.len);
    try std.testing.expect(std.mem.endsWith(u8, images.paths[0], "/A.tif"));
    try std.testing.expect(std.mem.endsWith(u8, images.paths[1], "/b.TIFF"));
    try std.testing.expect(std.mem.endsWith(u8, images.paths[2], "/current.tiff"));
}

test "process image rescan retains current image or clamps like process_handlers" {
    const old_paths = [_][]const u8{ "scans/a.tiff", "scans/b.tiff", "scans/c.tiff" };
    const retained = [_][]const u8{ "scans/c.tiff", "scans/b.tiff" };
    try std.testing.expectEqual(@as(usize, 1), retainedImageIndex(&old_paths, 1, &retained));

    const missing_current = [_][]const u8{ "scans/a.tiff", "scans/d.tiff" };
    try std.testing.expectEqual(@as(usize, 1), retainedImageIndex(&old_paths, 1, &missing_current));

    const shorter = [_][]const u8{"scans/a.tiff"};
    try std.testing.expectEqual(@as(usize, 0), retainedImageIndex(&old_paths, 4, &shorter));

    const empty = [_][]const u8{};
    try std.testing.expectEqual(@as(usize, 0), retainedImageIndex(&old_paths, 4, &empty));
}

test "process image load info mirrors switch_to_image TIFF metadata rules" {
    const info = try loadImageInfo(
        std.testing.allocator,
        "test/fixtures/tiff/rgb-thumb-ir.tiff",
        8192,
    );
    try std.testing.expectEqual(@as(usize, 2), info.width);
    try std.testing.expectEqual(@as(usize, 2), info.height);
    try std.testing.expect(info.has_ir);
    try std.testing.expect(!info.is_grayscale);
    try std.testing.expectEqual(@as(?u32, 800), info.dpi);
    try std.testing.expectApproxEqAbs(1.0, info.preview_scale, 0.0);
    try std.testing.expectEqual(@as(u16, 3), info.rgb_samples_per_pixel);
    try std.testing.expectEqual(@as(u16, 16), info.rgb_bits_per_sample);
    try std.testing.expectEqual(@as(?u16, 1), info.ir_samples_per_pixel);
    try std.testing.expectEqual(@as(?u16, 8), info.ir_bits_per_sample);
}

test "process preview and dpi scale match process_handlers arithmetic" {
    try std.testing.expectApproxEqAbs(1.0, previewScale(4000, 2000, 8192), 0.0);
    try std.testing.expectApproxEqAbs(0.5, previewScale(20000, 10000, 10000), 0.0);
    try std.testing.expectApproxEqAbs(1.0, previewScale(20000, 10000, 0), 0.0);
    try std.testing.expectApproxEqAbs(1.0, dpiScale(null), 0.0);
    try std.testing.expectApproxEqAbs(1.5, dpiScale(1200), 0.0);
    try std.testing.expectApproxEqAbs(3.12, dpiScale(2496), 0.0);
}

test "process quick preview mirrors Python switch_to_image preview block" {
    try expectQuickPreviewFixture("test/fixtures/processing/preview/quick-preview-rgb16-resize.json");
}

test "process inverted preview mirrors render_inverted_preview cache guards" {
    try expectInvertedPreviewFixture("test/fixtures/processing/preview/inverted-preview-kodak-gold-defaults.json");
}

test "auto-detect needs a film format" {
    const allocator = std.testing.allocator;
    const preview = try uniformPreview(allocator);
    defer preview.deinit(allocator);
    try std.testing.expectError(error.InvalidFilmFormat, autoDetectPreview(allocator, preview, .{}));
}

test "process rebate Dmin workflow mirrors route crop and save" {
    const allocator = std.testing.allocator;
    const pixels = [_]f64{
        1000.0,  2000.0,  3000.0,  4000.0,  5000.0,  6000.0,  7000.0,  8000.0,  9000.0,
        10000.0, 11000.0, 12000.0, 13000.0, 14000.0, 15000.0, 16000.0, 17000.0, 18000.0,
    };
    const image = export_pipeline.Image{
        .width = 3,
        .height = 2,
        .channels = 3,
        .pixels = @constCast(&pixels),
    };
    const expected_crop = [_]f64{
        4000.0,  5000.0,  6000.0,  7000.0,  8000.0,  9000.0,
        13000.0, 14000.0, 15000.0, 16000.0, 17000.0, 18000.0,
    };
    const expected = try inversion.computeDmin(allocator, &expected_crop, null, .{});
    const actual = try computeRebateDminFromImage(allocator, image, .{
        .x = 1.0,
        .y = 0.0,
        .w = 2.0,
        .h = 2.0,
        .angle = 0.0,
    });
    try expectDminApprox(expected, actual, 0.0);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/processing.toml", .{tmp.sub_path[0..]});
    defer allocator.free(config_path);
    const route_result = try processRebateFromTiff(
        allocator,
        std.testing.io,
        "test/fixtures/tiff/rgb-thumb-ir.tiff",
        config_path,
        .{ .x = 0.0, .y = 0.0, .w = 2.0, .h = 2.0, .angle = 0.0 },
        true,
    );
    const saved = try config.loadFile(allocator, std.testing.io, config_path);
    try saved.value("dmin").?.expectEqual(.{ .list = try config.FloatList.init(&route_result.dmin) });
}

test "rebate TIFF crop avoids full f64 image materialization with crop parity" {
    const allocator = std.testing.allocator;
    var bytes: [6 * 5 * 3 * 2]u8 = undefined;
    for (0..6 * 5 * 3) |index| {
        const value: u16 = @intCast((index * 379 + 1000) % 65535);
        std.mem.writeInt(u16, bytes[index * 2 ..][0..2], value, .little);
    }
    const tiff_image = tiff.Image{
        .width = 6,
        .height = 5,
        .samples_per_pixel = 3,
        .bits_per_sample = 16,
        .data = &bytes,
    };
    const full = try tiffImageToF64(allocator, tiff_image);
    defer full.deinit(allocator);
    const rect: export_pipeline.FrameRect = .{
        .cx = 3.1,
        .cy = 2.4,
        .w = 3.0,
        .h = 2.0,
        .angle = 7.0,
    };
    const expected = try export_pipeline.cropFrame(allocator, full.pixels, full.width, full.height, full.channels, rect);
    defer expected.deinit(allocator);
    const actual = try cropRgbFrameFromTiffImage(allocator, tiff_image, rect);
    defer actual.deinit(allocator);

    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
    try std.testing.expectEqual(expected.channels, actual.channels);
    for (expected.pixels, actual.pixels) |left, right| {
        try std.testing.expectApproxEqAbs(left, right, 0.0);
    }
}

test "rebate Dmin read from the rebate's rows matches the full page" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/rebate-rows.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(path);
    const width: u32 = 40;
    const height: u32 = 30;
    const bytes = try allocator.alloc(u8, width * height * 3 * 2);
    defer allocator.free(bytes);
    for (0..width * height * 3) |index| {
        const value: u16 = @intCast((index * 7919 + 20000) % 50000 + 10000);
        std.mem.writeInt(u16, bytes[index * 2 ..][0..2], value, .little);
    }
    try tiff.writeImage(allocator, path, .{ .width = width, .height = height, .samples_per_pixel = 3, .bits_per_sample = 16, .data = bytes }, .{});
    const full = try tiff.loadRgbPage(allocator, path);
    defer full.deinit(allocator);

    const rects = [_]frames.RebateOriginRect{
        .{ .x = 6.3, .y = 11.6, .w = 24.0, .h = 3.5, .angle = 0.03 },
        // Running off the bottom of the page.
        .{ .x = 2.0, .y = 27.2, .w = 30.0, .h = 6.0, .angle = -0.05 },
    };
    for (rects) |rect| {
        const expected = try computeRebateDminFromTiffImage(allocator, full, rect);
        const actual = try computeRebateDminFromTiff(allocator, path, rect);
        // The same samples from a different crop origin: equal to rounding.
        for (expected, actual) |left, right| try std.testing.expectApproxEqAbs(left, right, 1e-12);
    }
}

test "process export workflow mirrors handle_export no-output short circuit" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/unused", .{tmp.sub_path[0..]});
    defer allocator.free(output_dir);

    const result = try processExportFromTiff(allocator, std.testing.io, .{
        .input_path = "missing-input-should-not-be-read.tiff",
        .output_dir = output_dir,
        .rects = &.{},
        .outputs = .{ .ir_neg = false, .ir_inv = false, .inv_only = false },
    });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("No output variants selected", result.message);
    try std.testing.expectEqual(@as(usize, 0), result.files.len);
    try std.testing.expectEqual(@as(usize, 0), result.progress.events.len);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, output_dir, .{}));
}

test "process export workflow computes Dmin and writes route-shaped result" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/frames", .{tmp.sub_path[0..]});
    defer allocator.free(output_dir);
    const input_path = "test/fixtures/tiff/rgb-thumb-ir.tiff";
    const rebate: frames.RebateOriginRect = .{ .x = 0.0, .y = 0.0, .w = 2.0, .h = 2.0, .angle = 0.0 };
    const rects = [_]export_pipeline.FrameRect{
        .{ .cx = 1.0, .cy = 1.0, .w = 2.0, .h = 2.0, .angle = 0.0, .rotation = 0 },
    };
    const expected_dmin = try computeRebateDminFromTiff(allocator, input_path, rebate);

    const result = try processExportFromTiff(allocator, std.testing.io, .{
        .input_path = input_path,
        .output_dir = output_dir,
        .basename = "roll",
        .rects = &rects,
        .outputs = .{ .ir_neg = false, .ir_inv = false, .inv_only = true },
        .active_stock = "kodak_gold",
        .stock_coeffs = film_stocks.kodak_gold_coeffs,
        .rebate_rect = rebate,
        .total_seconds_override = 1.24,
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.dmin != null);
    try expectDminApprox(expected_dmin, result.dmin.?, 0.0);
    try std.testing.expectEqual(@as(usize, 1), result.files.len);
    try std.testing.expectEqualStrings("roll_01_inv.tif", result.files[0]);
    const expected_message = try std.fmt.allocPrint(allocator, "Exported 1 file to {s}/ (1.2s)", .{output_dir});
    defer allocator.free(expected_message);
    try std.testing.expectEqualStrings(expected_message, result.message);
    try std.testing.expectEqual(@as(usize, 4), result.progress.events.len);
    try std.testing.expectEqualStrings("Preparing export (1 frame)...", result.progress.events[0].message);
    try std.testing.expectEqualStrings("Processing 1 frame...", result.progress.events[1].message);
    try std.testing.expectEqualStrings("Wrote roll_01_inv.tif", result.progress.events[2].message);

    const output_path = try std.fs.path.join(allocator, &.{ output_dir, result.files[0] });
    defer allocator.free(output_path);
    try std.Io.Dir.cwd().access(std.testing.io, output_path, .{});
    const metadata = (try tiff.readExportMetadataJson(allocator, output_path)).?;
    defer allocator.free(metadata);
    try std.testing.expect(std.mem.indexOf(u8, metadata, "\"rebate_rect\":{\"x\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, metadata, "\"variant\":\"inverted\"") != null);
}

test "process export workflow runs multi-frame exports through Python-shaped parallel jobs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/frames", .{tmp.sub_path[0..]});
    defer allocator.free(output_dir);
    const rects = [_]export_pipeline.FrameRect{
        .{ .cx = 1.0, .cy = 1.0, .w = 2.0, .h = 2.0, .angle = 0.0, .rotation = 0 },
        .{ .cx = 1.0, .cy = 1.0, .w = 2.0, .h = 2.0, .angle = 0.0, .rotation = 180 },
    };

    const result = try processExportFromTiff(allocator, std.testing.io, .{
        .input_path = "test/fixtures/tiff/rgb-thumb-ir.tiff",
        .output_dir = output_dir,
        .basename = "roll",
        .rects = &rects,
        .outputs = .{ .ir_neg = false, .ir_inv = false, .inv_only = true },
        .active_stock = "kodak_gold",
        .stock_coeffs = film_stocks.kodak_gold_coeffs,
        .dmin = .{ 0.0, 0.0, 0.0 },
        .parallel_cpu_count_override = 4,
        .parallel_available_memory_override = export_parallel_min_system_reserve_bytes + 64 * 1024 * 1024,
        .total_seconds_override = 1.24,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.files.len);
    try expectStringSetContains(result.files, "roll_01_inv.tif");
    try expectStringSetContains(result.files, "roll_02_inv.tif");
    for (result.files) |file| {
        const output_path = try std.fs.path.join(allocator, &.{ output_dir, file });
        defer allocator.free(output_path);
        try std.Io.Dir.cwd().access(std.testing.io, output_path, .{});
    }
    try std.testing.expectEqualStrings("Processing 2 frames...", result.progress.events[1].message);
    const expected_complete = try std.fmt.allocPrint(allocator, "Exported 2 files to {s}/ (1.2s)", .{output_dir});
    defer allocator.free(expected_complete);
    try std.testing.expectEqualStrings(expected_complete, result.progress.events[result.progress.events.len - 1].message);
}

test "export parallelism planner leaves one cpu free" {
    const rects = [_]export_pipeline.FrameRect{
        .{ .cx = 50.0, .cy = 50.0, .w = 32.0, .h = 24.0 },
        .{ .cx = 150.0, .cy = 50.0, .w = 32.0, .h = 24.0 },
        .{ .cx = 250.0, .cy = 50.0, .w = 32.0, .h = 24.0 },
        .{ .cx = 350.0, .cy = 50.0, .w = 32.0, .h = 24.0 },
    };
    const decision = planExportParallelism(.{
        .rects = &rects,
        .outputs = .{ .ir_neg = false, .ir_inv = false, .inv_only = true },
        .rgb_shape = .{ .width = 512, .height = 512, .channels = 3 },
        .cpu_count = 4,
        .available_memory_bytes = export_parallel_min_system_reserve_bytes + 1024 * 1024 * 1024,
    });
    try std.testing.expectEqual(@as(usize, 4), decision.cpu_count);
    try std.testing.expectEqual(@as(usize, 3), decision.cpu_worker_limit);
    try std.testing.expectEqual(@as(usize, 3), decision.worker_count);
    try std.testing.expect(!decision.memory_limited);
}

test "adaptive dust worker override preserves dynamic default and clamps to one" {
    const rects = [_]export_pipeline.FrameRect{};
    const decision = ExportParallelismDecision{
        .worker_count = 5,
        .cpu_count = 32,
        .cpu_worker_limit = 31,
        .memory_worker_limit = null,
        .available_memory_bytes = null,
        .memory_budget_bytes = null,
        .estimated_worker_peak_bytes = 0,
        .adjusted_worker_peak_bytes = 0,
        .memory_limited = false,
    };
    const base_options = ExportWorkflowOptions{
        .input_path = "input.tiff",
        .output_dir = "frames",
        .rects = &rects,
    };

    try std.testing.expectEqual(@as(usize, 6), adaptiveDustWorkerCountForOptions(base_options, decision));
    var override_options = base_options;
    override_options.adaptive_dust_worker_count_override = 3;
    try std.testing.expectEqual(@as(usize, 3), adaptiveDustWorkerCountForOptions(override_options, decision));
    override_options.adaptive_dust_worker_count_override = 0;
    try std.testing.expectEqual(@as(usize, 1), adaptiveDustWorkerCountForOptions(override_options, decision));
}

test "export parallelism planner limits workers by predicted memory" {
    const rects = [_]export_pipeline.FrameRect{
        .{ .cx = 50.0, .cy = 50.0, .w = 64.0, .h = 64.0 },
        .{ .cx = 150.0, .cy = 50.0, .w = 64.0, .h = 64.0 },
        .{ .cx = 250.0, .cy = 50.0, .w = 64.0, .h = 64.0 },
        .{ .cx = 350.0, .cy = 50.0, .w = 64.0, .h = 64.0 },
    };
    const estimated = estimateMaxExportWorkerPeakBytes(
        .{ .width = 1024, .height = 1024, .channels = 3 },
        null,
        .{ .ir_neg = false, .ir_inv = false, .inv_only = true },
        .{},
        &rects,
    );
    const adjusted = applyExportMemorySafetyFactor(estimated);
    const target_budget = adjusted * 2 + adjusted / 4;
    const after_reserve = (target_budget * export_parallel_memory_budget_denominator + export_parallel_memory_budget_numerator - 1) /
        export_parallel_memory_budget_numerator;
    const decision = planExportParallelism(.{
        .rects = &rects,
        .outputs = .{ .ir_neg = false, .ir_inv = false, .inv_only = true },
        .rgb_shape = .{ .width = 1024, .height = 1024, .channels = 3 },
        .cpu_count = 8,
        .available_memory_bytes = export_parallel_min_system_reserve_bytes + after_reserve,
    });
    try std.testing.expectEqual(@as(usize, 2), decision.memory_worker_limit.?);
    try std.testing.expectEqual(@as(usize, 2), decision.worker_count);
    try std.testing.expect(decision.memory_limited);
}

test "export memory estimate is comptime evaluable and includes crop scratch" {
    const estimated = comptime estimateFrameExportPeakBytes(
        .{ .width = 400, .height = 300, .channels = 3 },
        null,
        .{ .ir_neg = false, .ir_inv = false, .inv_only = true },
        .{},
        .{ .cx = 100.0, .cy = 100.0, .w = 80.0, .h = 60.0 },
    );
    const raw_crop_bytes = comptime bytesFor(f64, 80 * 60 * 3);
    try std.testing.expect(estimated > raw_crop_bytes);
}

test "linux MemAvailable parser reads kB values" {
    const text =
        \\MemTotal:       32768000 kB
        \\MemFree:         1024000 kB
        \\MemAvailable:    2048000 kB
        \\Buffers:          100000 kB
        \\
    ;
    try std.testing.expectEqual(@as(?usize, 2048000 * 1024), parseLinuxMemAvailableBytes(text));
}

const QuickPreviewFixture = struct {
    name: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    input: QuickPreviewInputFixture,
    expected: QuickPreviewExpectedFixture,
};

const QuickPreviewInputFixture = struct {
    width: usize,
    height: usize,
    channels: u16,
    bits_per_sample: u16,
    preview_size: i64,
    formula: []const u8,
};

const QuickPreviewExpectedFixture = struct {
    preview_width: usize,
    preview_height: usize,
    preview_scale: f64,
    content_pixels: usize,
    jpeg_len: usize,
    preview_raw: []u16,
    preview_rgb8: []u8,
    jpeg_decoded_rgb: []u8,
    jpeg_decoded_abs_tolerance: u8,
};

const InvertedPreviewFixture = struct {
    name: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    input: InvertedPreviewInputFixture,
    expected: InvertedPreviewExpectedFixture,
};

const InvertedPreviewInputFixture = struct {
    source_fixture: []const u8,
    stock: []const u8,
    dmin: ?[3]f64 = null,
    render_defaults: bool,
};

const InvertedPreviewExpectedFixture = struct {
    jpeg_len: usize,
    jpeg_decoded_rgb: []u8,
    jpeg_decoded_abs_tolerance: u8,
    scene_linear_first_12: []f64,
};

fn expectQuickPreviewFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const preview = try quickPreviewFromFixture(allocator, path);
    defer preview.deinit(allocator);

    var parsed = try loadQuickPreviewFixture(allocator, path);
    defer parsed.deinit();
    const fixture = parsed.value;
    try std.testing.expectEqual(fixture.input.width, preview.info.width);
    try std.testing.expectEqual(fixture.input.height, preview.info.height);
    try std.testing.expectEqual(fixture.expected.preview_width, preview.preview_width);
    try std.testing.expectEqual(fixture.expected.preview_height, preview.preview_height);
    try std.testing.expectApproxEqAbs(fixture.expected.preview_scale, preview.info.preview_scale, 1e-12);
    try std.testing.expectEqualSlices(u16, fixture.expected.preview_raw, preview.preview_raw);
    try std.testing.expectEqualSlices(u8, fixture.expected.preview_rgb8, preview.preview_rgb8);
    try std.testing.expectEqual(fixture.expected.jpeg_len, preview.jpeg.len);
    try std.testing.expectEqual(@as(u8, 0xff), preview.jpeg[0]);
    try std.testing.expectEqual(@as(u8, 0xd8), preview.jpeg[1]);
    try std.testing.expectEqual(@as(u8, 0xff), preview.jpeg[preview.jpeg.len - 2]);
    try std.testing.expectEqual(@as(u8, 0xd9), preview.jpeg[preview.jpeg.len - 1]);

    const decoded = try decodeJpegRgb(
        allocator,
        preview.jpeg,
        fixture.expected.preview_width,
        fixture.expected.preview_height,
    );
    defer allocator.free(decoded);
    try expectMaxAbsDiff(decoded, fixture.expected.jpeg_decoded_rgb, fixture.expected.jpeg_decoded_abs_tolerance);
}

fn expectInvertedPreviewFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(InvertedPreviewFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0 or
        fixture.input.stock.len == 0 or !fixture.input.render_defaults)
    {
        return error.InvalidQuickPreviewFixture;
    }

    const preview = try quickPreviewFromFixture(allocator, fixture.input.source_fixture);
    defer preview.deinit(allocator);

    var empty_cache = InvertedPreviewCache{};
    defer empty_cache.deinit(allocator);
    try std.testing.expect((try renderInvertedPreviewJpeg(allocator, preview, &empty_cache, .{})) == null);
    try std.testing.expect(empty_cache.scene_linear == null);

    var grayscale_preview = preview;
    grayscale_preview.info.is_grayscale = true;
    try std.testing.expect((try renderInvertedPreviewJpeg(allocator, grayscale_preview, &empty_cache, .{
        .stock = fixture.input.stock,
    })) == null);
    try std.testing.expect(empty_cache.scene_linear == null);

    var cache = InvertedPreviewCache{};
    defer cache.deinit(allocator);
    const jpeg = (try renderInvertedPreviewJpeg(allocator, preview, &cache, .{
        .stock = fixture.input.stock,
        .dmin = fixture.input.dmin,
    })).?;
    defer allocator.free(jpeg);
    try std.testing.expect(cache.scene_linear != null);
    try std.testing.expectEqual(fixture.expected.jpeg_len, jpeg.len);
    for (fixture.expected.scene_linear_first_12, cache.scene_linear.?[0..fixture.expected.scene_linear_first_12.len]) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.000002);
    }

    const decoded = try decodeJpegRgb(allocator, jpeg, preview.preview_width, preview.preview_height);
    defer allocator.free(decoded);
    try expectMaxAbsDiff(decoded, fixture.expected.jpeg_decoded_rgb, fixture.expected.jpeg_decoded_abs_tolerance);

    const cached_scene_ptr = cache.scene_linear.?.ptr;
    const rerendered = (try renderInvertedPreviewJpeg(allocator, preview, &cache, .{
        .stock = fixture.input.stock,
        .render_options = .{ .exposure_compensation = 0.1 },
    })).?;
    defer allocator.free(rerendered);
    try std.testing.expectEqual(cached_scene_ptr, cache.scene_linear.?.ptr);
    cache.invalidate(allocator);
    try std.testing.expect(cache.scene_linear == null);
}

fn quickPreviewFromFixture(allocator: std.mem.Allocator, path: []const u8) !QuickPreview {
    var parsed = try loadQuickPreviewFixture(allocator, path);
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidQuickPreviewFixture;
    }
    if (!std.mem.eql(u8, fixture.input.formula, "uint16(700 + y*997 + x*431 + c*83)")) {
        return error.InvalidQuickPreviewFixture;
    }
    if (fixture.expected.content_pixels <= 100) return error.InvalidQuickPreviewFixture;

    const image = try fixtureImage(allocator, fixture.input);
    defer image.deinit(allocator);
    return generateQuickPreview(allocator, image, fixture.input.preview_size);
}

fn loadQuickPreviewFixture(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(QuickPreviewFixture) {
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    errdefer allocator.free(text);
    const parsed = try std.json.parseFromSlice(QuickPreviewFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    allocator.free(text);
    return parsed;
}

fn fixtureImage(allocator: std.mem.Allocator, input: QuickPreviewInputFixture) !tiff.Image {
    if (input.channels != 1 and input.channels != 3) return error.InvalidQuickPreviewFixture;
    if (input.bits_per_sample != 16) return error.InvalidQuickPreviewFixture;
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, input.width, input.height), input.channels);
    const data = try allocator.alloc(u8, sample_count * 2);
    errdefer allocator.free(data);
    var sample_index: usize = 0;
    for (0..input.height) |y| {
        for (0..input.width) |x| {
            for (0..input.channels) |channel| {
                const value: u16 = @intCast(700 + y * 997 + x * 431 + channel * 83);
                std.mem.writeInt(u16, data[sample_index * 2 ..][0..2], value, .little);
                sample_index += 1;
            }
        }
    }
    return .{
        .width = @intCast(input.width),
        .height = @intCast(input.height),
        .samples_per_pixel = input.channels,
        .bits_per_sample = input.bits_per_sample,
        .data = data,
    };
}

fn expectMaxAbsDiff(actual: []const u8, expected: []const u8, tolerance: u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |a, e| {
        const ai: i16 = a;
        const ei: i16 = e;
        try std.testing.expect(@abs(ai - ei) <= tolerance);
    }
}

fn uniformPreview(allocator: std.mem.Allocator) !QuickPreview {
    const width: usize = 140;
    const height: usize = 620;
    const sample_count = width * height * 3;
    const raw = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(raw);
    const preview_rgb8 = try allocator.alloc(u8, 0);
    errdefer allocator.free(preview_rgb8);
    const jpeg = try allocator.alloc(u8, 0);
    errdefer allocator.free(jpeg);

    @memset(raw, 40000);

    return .{
        .info = .{
            .width = width,
            .height = height,
            .has_ir = false,
            .is_grayscale = false,
            .dpi = null,
            .preview_scale = 1.0,
            .rgb_samples_per_pixel = 3,
            .rgb_bits_per_sample = 16,
        },
        .preview_width = width,
        .preview_height = height,
        .preview_raw = raw,
        .preview_rgb8 = preview_rgb8,
        .jpeg = jpeg,
    };
}

fn expectFrameRectApprox(expected: frames.FrameRect, actual: frames.FrameRect, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected.cx, actual.cx, tolerance);
    try std.testing.expectApproxEqAbs(expected.cy, actual.cy, tolerance);
    try std.testing.expectApproxEqAbs(expected.w, actual.w, tolerance);
    try std.testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
    try std.testing.expectApproxEqAbs(expected.angle, actual.angle, tolerance);
}

fn expectDminApprox(expected: [3]f64, actual: [3]f64, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected[0], actual[0], tolerance);
    try std.testing.expectApproxEqAbs(expected[1], actual[1], tolerance);
    try std.testing.expectApproxEqAbs(expected[2], actual[2], tolerance);
}

fn expectStringSetContains(values: []const []const u8, expected: []const u8) !void {
    for (values) |value| {
        if (std.mem.eql(u8, value, expected)) return;
    }
    return error.MissingExpectedString;
}
