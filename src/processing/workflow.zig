const std = @import("std");

const config = @import("config.zig");
const export_pipeline = @import("export.zig");
const film_stocks = @import("film_stocks.zig");
const frames = @import("frames.zig");
const inversion = @import("inversion.zig");
const ir_processing = @import("ir.zig");
const render = @import("render.zig");
const tiff = @import("../tiff.zig");
const webgpu = @import("webgpu.zig");

const export_parallel_min_system_reserve_bytes: usize = 512 * 1024 * 1024;
const export_parallel_memory_budget_numerator: usize = 3;
const export_parallel_memory_budget_denominator: usize = 4;
const export_parallel_estimate_safety_numerator: usize = 3;
const export_parallel_estimate_safety_denominator: usize = 2;

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

extern fn v600_process_quick_preview(
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

extern fn v600_decode_jpeg_rgb(
    jpeg: [*]const u8,
    jpeg_len: c_int,
    rgb_out: ?[*]u8,
    rgb_capacity: c_int,
    out_width: *c_int,
    out_height: *c_int,
) c_int;

extern fn v600_encode_rgb_jpeg(
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
};

pub const AutoDetectResult = struct {
    frames: []frames.FrameRect,
    aspect: []const u8,
    rebate: ?frames.RebateRect,

    pub fn deinit(self: *AutoDetectResult, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
        self.* = undefined;
    }
};

pub const RebateWorkflowResult = struct {
    dmin: [3]f64,
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
    parallel_cpu_count_override: ?usize = null,
    parallel_available_memory_override: ?usize = null,
    total_seconds_override: ?f64 = null,
    progress_sink: ?ExportProgressSink = null,
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
    progress: export_pipeline.ExportProgressList,

    pub fn deinit(self: ExportWorkflowResult, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        for (self.files) |file| allocator.free(file);
        allocator.free(self.files);
        self.progress.deinit(allocator);
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
    const pages = try tiff.loadRgbIrPages(allocator, path);
    defer pages.deinit(allocator);

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
    const dpi = try tiff.readDpi(allocator, path);
    const pages = try tiff.loadRgbIrPages(allocator, path);
    defer pages.deinit(allocator);
    var result = try generateQuickPreview(allocator, pages.rgb, preview_size);
    result.info.dpi = dpi;
    result.info.has_ir = if (pages.ir) |ir| ir.samples_per_pixel == 1 else false;
    result.info.ir_samples_per_pixel = if (pages.ir) |ir| ir.samples_per_pixel else null;
    result.info.ir_bits_per_sample = if (pages.ir) |ir| ir.bits_per_sample else null;
    return result;
}

pub fn generateQuickPreview(
    allocator: std.mem.Allocator,
    image: tiff.Image,
    preview_size: i64,
) !QuickPreview {
    const width = try toCInt(image.width);
    const height = try toCInt(image.height);
    const channels = try toCInt(image.samples_per_pixel);
    const bits = try toCInt(image.bits_per_sample);
    const preview_size_c = if (preview_size <= 0) 0 else try toCInt(preview_size);

    var out_width: c_int = 0;
    var out_height: c_int = 0;
    var out_scale: f64 = 1.0;
    var jpeg_len: c_int = 0;
    const first = v600_process_quick_preview(
        image.data.ptr,
        width,
        height,
        channels,
        bits,
        preview_size_c,
        &out_width,
        &out_height,
        &out_scale,
        null,
        0,
        null,
        0,
        null,
        0,
        &jpeg_len,
    );
    if (first < 0) return error.QuickPreviewFailed;
    if (out_width <= 0 or out_height <= 0 or jpeg_len <= 0) return error.QuickPreviewFailed;

    const preview_width: usize = @intCast(out_width);
    const preview_height: usize = @intCast(out_height);
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, preview_width, preview_height), 3);
    const preview_raw = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(preview_raw);
    const preview_rgb8 = try allocator.alloc(u8, sample_count);
    errdefer allocator.free(preview_rgb8);
    const jpeg = try allocator.alloc(u8, @intCast(jpeg_len));
    errdefer allocator.free(jpeg);

    var second_jpeg_len: c_int = 0;
    const second = v600_process_quick_preview(
        image.data.ptr,
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
        &second_jpeg_len,
    );
    if (second != 0 or second_jpeg_len <= 0 or @as(usize, @intCast(second_jpeg_len)) != jpeg.len or
        out_width <= 0 or out_height <= 0)
    {
        return error.QuickPreviewFailed;
    }

    return .{
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
    };
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
    const status = v600_decode_jpeg_rgb(
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
            const density_lut = try inversion.DensityLutF32.init(allocator, options.dmin.?, 65535.0);
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
        },
    );
    errdefer detected.deinit(allocator);
    return try autoDetectDetectedFrames(&detected, preview.preview_width, preview.preview_height);
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
    const pages = try tiff.loadRgbIrPages(allocator, path);
    defer pages.deinit(allocator);
    return tiffImageToF64(allocator, pages.rgb);
}

pub fn loadFullImageAsF64(
    allocator: std.mem.Allocator,
    path: []const u8,
    include_ir: bool,
) !FullImage {
    const dpi = try tiff.readDpi(allocator, path);
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

pub fn computeRebateDminFromTiff(
    allocator: std.mem.Allocator,
    path: []const u8,
    rect: frames.RebateOriginRect,
) ![3]f64 {
    const image = try loadRgbImageAsF64(allocator, path);
    defer image.deinit(allocator);
    return computeRebateDminFromImage(allocator, image, rect);
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
    if (!options.outputs.any()) {
        return noOutputExportResult(allocator);
    }

    const start = monotonicNowNs();
    try std.Io.Dir.cwd().createDirPath(io, options.output_dir);
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

    var full = try loadFullImageAsF64(allocator, options.input_path, need_ir);
    defer full.deinit(allocator);
    const current_dpi = options.current_dpi orelse full.dpi;

    var dmin = options.dmin;
    if (options.active_stock != null and dmin == null) {
        if (options.rebate_rect) |rebate| {
            if (frames.rebateInBounds(full.rgb.width, full.rgb.height, rebate)) {
                dmin = try computeRebateDminFromImage(allocator, full.rgb, rebate);
            }
        }
        if (dmin == null) {
            dmin = try inversion.computeDmin(allocator, full.rgb.pixels, null, .{});
        }
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
    const ir_clean_options = irCleanOptionsForConfig(current_dpi, options.config_overrides);

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
            .paths = try outputPathsForFrame(allocator, io, options.output_dir, basename, frame_index, options.outputs),
        };
        jobs_len += 1;
    }

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

    if (jobs.len <= 1 or !options.parallel_frames or parallel_decision.worker_count <= 1) {
        for (jobs) |job| {
            var prng = std.Random.DefaultPrng.init(frameExportSeed(job.frame_index));
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
                    },
                    .film_stock = film_stock,
                    .stock_coeffs = stock_coeffs,
                    .dmin = dmin,
                    .render_options = render_options,
                    .ir_clean_options = ir_clean_options,
                    .invert_request = options.invert_request,
                    .random = prng.random(),
                },
            );
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
            .rebate_rect = options.rebate_rect,
            .outputs = options.outputs,
            .film_stock = film_stock,
            .stock_coeffs = stock_coeffs,
            .dmin = dmin,
            .render_options = render_options,
            .ir_clean_options = ir_clean_options,
            .invert_request = options.invert_request,
            .progress_sink = options.progress_sink,
        });
    }

    const files = try written.toOwnedSlice();
    errdefer {
        for (files) |file| allocator.free(file);
        allocator.free(files);
    }
    const total_seconds = options.total_seconds_override orelse
        @as(f64, @floatFromInt(monotonicNowNs() - start)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    var progress = try export_pipeline.buildBatchExportProgress(
        allocator,
        options.rects.len,
        need_ir,
        full.ir != null,
        files,
        options.output_dir,
        total_seconds,
    );
    errdefer progress.deinit(allocator);
    const message = try std.fmt.allocPrint(allocator, "Exported {d} file{s} to {s}/ ({d:.1}s)", .{
        files.len,
        if (files.len == 1) "" else "s",
        options.output_dir,
        total_seconds,
    });
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

const FrameExportOutcome = struct {
    backing_allocator: std.mem.Allocator = std.heap.smp_allocator,
    result: ?export_pipeline.ProcessFrameResult = null,
    err: ?anyerror = null,

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

fn processExportFramesParallel(
    allocator: std.mem.Allocator,
    written: *std.array_list.Managed([]u8),
    jobs: []const FrameExportJob,
    worker_count: usize,
    shared: FrameExportShared,
) !void {
    std.debug.assert(jobs.len > 1);
    std.debug.assert(worker_count > 1);
    std.debug.assert(worker_count <= jobs.len);

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
    while (thread_count < worker_count) : (thread_count += 1) {
        threads[thread_count] = try std.Thread.spawn(.{}, frameExportWorker, .{&queue});
    }
    for (threads[0..thread_count]) |thread| thread.join();

    const completed = queue.completed.load(.seq_cst);
    if (completed != jobs.len) return error.ExportFrameWorkerIncomplete;

    for (completion_order[0..completed]) |job_index| {
        const outcome = &outcomes[job_index];
        if (outcome.err) |err| return err;
        const result = outcome.result orelse return error.ExportFrameWorkerIncomplete;
        for (result.written) |name| {
            try written.append(try allocator.dupe(u8, name));
        }
    }
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
                },
                .film_stock = queue.shared.film_stock,
                .stock_coeffs = queue.shared.stock_coeffs,
                .dmin = queue.shared.dmin,
                .render_options = queue.shared.render_options,
                .ir_clean_options = queue.shared.ir_clean_options,
                .invert_request = queue.shared.invert_request,
                .random = prng.random(),
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

fn frameExportSeed(frame_index: usize) u64 {
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
    const first = v600_encode_rgb_jpeg(
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
    const second = v600_encode_rgb_jpeg(
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
            for (image.data, pixels) |sample, *out| out.* = @floatFromInt(sample);
        },
        16 => {
            if (image.data.len != sample_count * 2) return error.UnsupportedProcessingImage;
            for (pixels, 0..) |*out, index| {
                out.* = @floatFromInt(std.mem.readInt(u16, image.data[index * 2 ..][0..2], .little));
            }
        },
        else => return error.UnsupportedProcessingImage,
    }
    return .{ .width = width, .height = height, .channels = channels, .pixels = pixels };
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
) !OwnedOutputPaths {
    var result = OwnedOutputPaths{ .paths = .{} };
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

fn renderOptionsForConfig(current_dpi: ?u32, overrides: []const config.Override) render.RenderToDisplayOptions {
    return .{
        .contrast = config.getParam("render_contrast", current_dpi, overrides).?.asFloat(),
        .curve_k = config.getParam("render_curve_k", current_dpi, overrides).?.asFloat(),
        .percentile_lo = config.getParam("render_percentile_lo", current_dpi, overrides).?.asFloat(),
        .percentile_hi = config.getParam("render_percentile_hi", current_dpi, overrides).?.asFloat(),
        .exposure_compensation = config.getParam("exposure_compensation", current_dpi, overrides).?.asFloat(),
        .color_temp = config.getParam("color_temp", current_dpi, overrides).?.asFloat(),
        .color_tint = config.getParam("color_tint", current_dpi, overrides).?.asFloat(),
    };
}

fn irCleanOptionsForConfig(current_dpi: ?u32, overrides: []const config.Override) ir_processing.IrCleanOptions {
    return .{
        .defect_mask = .{
            .threshold = config.getParam("ir_threshold", current_dpi, overrides).?.asFloat(),
            .hair_sensitivity = config.getParam("ir_hair_sensitivity", current_dpi, overrides).?.asFloat(),
            .min_area = @intFromFloat(config.getParam("ir_min_area", current_dpi, overrides).?.asFloat()),
            .dilate_radius = @intFromFloat(config.getParam("ir_dilate_radius", current_dpi, overrides).?.asFloat()),
            .close_radius = @intFromFloat(config.getParam("ir_close_radius", current_dpi, overrides).?.asFloat()),
            .blur_size = @intFromFloat(config.getParam("ir_blur_size", current_dpi, overrides).?.asFloat()),
            .max_coverage = config.getParam("ir_max_coverage", current_dpi, overrides).?.asFloat(),
        },
        .inpaint = .{
            .padding = @intFromFloat(config.getParam("inpaint_padding", current_dpi, overrides).?.asFloat()),
            .grain_padding = 8,
            .value_kind = .uint16,
        },
    };
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
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

test "process auto-detect preview mirrors route detector composition" {
    const allocator = std.testing.allocator;
    const preview = try syntheticAutoDetectPreview(allocator);
    defer preview.deinit(allocator);

    try std.testing.expectError(error.InvalidFilmFormat, autoDetectPreview(allocator, preview, .{}));

    var detected = try autoDetectPreview(allocator, preview, .{
        .format = "35mm",
        .n_frames = 3,
        .detect_film_extent = false,
        .apply_clahe = false,
    });
    defer detected.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), detected.frames.len);
    try std.testing.expectEqualStrings("24:36", detected.aspect);
    try expectFrameRectApprox(.{ .cx = 95.0, .cy = 130.0, .w = 100.0, .h = 150.0, .angle = 0.0 }, detected.frames[0], 12.0);
    try expectFrameRectApprox(.{ .cx = 95.0, .cy = 310.0, .w = 100.0, .h = 150.0, .angle = 0.0 }, detected.frames[1], 12.0);
    try expectFrameRectApprox(.{ .cx = 95.0, .cy = 490.0, .w = 100.0, .h = 150.0, .angle = 0.0 }, detected.frames[2], 12.0);
    const rebate = detected.rebate orelse return error.MissingAutoDetectRebate;
    try std.testing.expectApproxEqAbs(95.0, rebate.cx, 16.0);
    try std.testing.expectApproxEqAbs(400.0, rebate.cy, 16.0);
    try std.testing.expect(rebate.w > 40.0);
    try std.testing.expect(rebate.h > 1.0);
}

test "process auto-detect postprocess applies single-frame fallback before rebate" {
    const allocator = std.testing.allocator;
    const source = [_]frames.FrameRect{
        .{ .cx = 200.0, .cy = 150.0, .w = 200.0, .h = 300.0, .angle = 0.12 },
    };
    var detected = frames.DetectFramesResult{
        .frames = try allocator.dupe(frames.FrameRect, &source),
        .strip_info = .{ .n_frames = 1, .frame_w = 200.0, .frame_h = 300.0, .pitch_px = 0.0, .is_vertical = false },
        .aspect = "36:24",
    };
    errdefer detected.deinit(allocator);

    var result = try autoDetectDetectedFrames(&detected, 1000, 500);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), detected.frames.len);
    try std.testing.expectEqual(@as(usize, 1), result.frames.len);
    try std.testing.expect(result.rebate == null);
    try expectFrameRectApprox(.{ .cx = 500.0, .cy = 250.0, .w = 1000.0, .h = 500.0, .angle = 0.0 }, result.frames[0], 0.0);
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
    const config_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/scratchndent_config.toml", .{tmp.sub_path[0..]});
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

fn syntheticAutoDetectPreview(allocator: std.mem.Allocator) !QuickPreview {
    const width: usize = 180;
    const height: usize = 620;
    const sample_count = width * height * 3;
    const raw = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(raw);
    const preview_rgb8 = try allocator.alloc(u8, 0);
    errdefer allocator.free(preview_rgb8);
    const jpeg = try allocator.alloc(u8, 0);
    errdefer allocator.free(jpeg);

    for (0..height) |y| {
        for (0..width) |x| {
            var level: f64 = 0.92;
            if (x >= 30 and x < 170 and y >= 20 and y < 600) level = 0.65;
            if (x >= 45 and x < 145 and
                ((y >= 55 and y < 205) or (y >= 235 and y < 385) or (y >= 415 and y < 565)))
            {
                level = 0.18;
            }
            const sample: u16 = @intFromFloat(@floor(level * 65535.0 + 0.5));
            const base = (y * width + x) * 3;
            raw[base] = sample;
            raw[base + 1] = sample;
            raw[base + 2] = sample;
        }
    }

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
