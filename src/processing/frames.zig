const std = @import("std");
const builtin = @import("builtin");

const numeric = @import("numeric_fixture.zig");
const parallelism = @import("parallelism.zig");
const clahe_ops = @import("clahe.zig");
const film_formats = @import("film_formats.zig");
const rotation = @import("rotation.zig");

pub const FilmFormat = film_formats.FilmFormat;
pub const format_35mm = film_formats.format_35mm;
pub const format_645 = film_formats.format_645;
pub const format_6x6 = film_formats.format_6x6;
pub const format_6x7 = film_formats.format_6x7;
pub const format_6x9 = film_formats.format_6x9;
pub const formats = film_formats.formats;
pub const formatByName = film_formats.formatByName;
pub const detectFramesAspect = film_formats.detectFramesAspect;

pub const ClaheOptions = clahe_ops.ClaheOptions;
pub const applyClahe8 = clahe_ops.applyClahe8;

pub const FrameRect = rotation.FrameRect;
pub const AffineTransform = rotation.AffineTransform;
pub const ExpandedRotation = rotation.ExpandedRotation;
pub const RotatedCrop = rotation.RotatedCrop;
pub const expandedRotationTransform = rotation.expandedRotationTransform;
pub const transformFramesFromRotatedToOriginal = rotation.transformFramesFromRotatedToOriginal;
pub const rotateImageExpandedReplicate = rotation.rotateImageExpandedReplicate;
pub const cropRotatedRect = rotation.cropRotatedRect;

const workerCountForItems = parallelism.workerCountForItems;
const sampleToU16 = rotation.sampleToU16;
const sampleToPythonGray8 = rotation.sampleToPythonGray8;
const writeRoundedSample = rotation.writeRoundedSample;
const reflect101Index = clahe_ops.reflect101Index;
const tiff_available = builtin.is_test and @import("build_options").native_libs;
const tiff = if (tiff_available) @import("../tiff.zig") else struct {};

const angle_gradient_parallel_min_work: usize = 1_000_000;
const component_runs_min_pixels: usize = 1_000_000;
const conversion_parallel_min_items: usize = 1_000_000;
const grayscale_simd_width: usize = 8;
const byte_simd_width: usize = 32;
const f64_simd_width: usize = 4;

const u8_to_unit_f64 = initU8ToUnitF64();

fn initU8ToUnitF64() [256]f64 {
    var table: [256]f64 = undefined;
    for (&table, 0..) |*value, index| {
        value.* = @as(f64, @floatFromInt(index)) / 255.0;
    }
    return table;
}

pub const StripProfiles = struct {
    profile_a: []f64,
    profile_b: []f64,
    profile_c: []f64,
    cross_profile: []f64,

    pub fn deinit(self: *StripProfiles, allocator: std.mem.Allocator) void {
        allocator.free(self.profile_a);
        allocator.free(self.profile_b);
        allocator.free(self.profile_c);
        allocator.free(self.cross_profile);
        self.* = undefined;
    }
};

pub const DtwOptions = struct {
    max_len: usize = 1000,
};

pub const DtwAlignment = struct {
    edge_positions: []usize,
    dtw_scale: f64,
    template_len: usize,
    effective_frame_dim: usize,
    effective_gap: usize,
    band: usize,
    end_j: usize,

    pub fn deinit(self: *DtwAlignment, allocator: std.mem.Allocator) void {
        allocator.free(self.edge_positions);
        self.* = undefined;
    }
};

pub const CrossStripMeasurement = struct {
    left_t: f64,
    right_t: f64,
    cross_w: f64,
    cross_center_offset: f64,
    hw_idx: usize,
    coarse_k: usize,
};

pub const EdgePeakPoint = struct {
    x: f64,
    y: f64,
};

const Point2 = struct {
    x: f64,
    y: f64,
};

pub const TheilSenAngle = struct {
    median_slope: f64,
    angle: f64,
};

pub const FilmExtent = struct {
    strip_narrow_px: f64,
    strip_long_px: f64,
    strip_angle: f64 = 0.0,
};

pub const StripAnalysis = struct {
    n_frames: usize,
    frame_w: f64,
    frame_h: f64,
    pitch_px: f64,
    is_vertical: bool,
};

pub const DetectFramesOptions = struct {
    frame_count_override: ?usize = null,
    film_extent: ?FilmExtent = null,
    strip_angle: f64 = 0.0,
    cross_gray_raw: ?[]const f64 = null,
    dtw_options: DtwOptions = .{},
};

pub const DetectFramesImageOptions = struct {
    frame_count_override: ?usize = null,
    detect_film_extent: bool = true,
    film_extent_override: ?FilmExtent = null,
    apply_clahe: bool = true,
    dtw_options: DtwOptions = .{},
};

pub const DetectFramesResult = struct {
    frames: []FrameRect,
    strip_info: StripAnalysis,
    aspect: []const u8,

    pub fn deinit(self: *DetectFramesResult, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
        self.* = undefined;
    }
};

pub const DetectFramesBreakdown = struct {
    result: DetectFramesResult = undefined,
    prepare_gray_ns: u64 = 0,
    film_extent_ns: u64 = 0,
    film_otsu_ns: u64 = 0,
    film_mask_ns: u64 = 0,
    film_close_ns: u64 = 0,
    film_component_ns: u64 = 0,
    film_geometry_ns: u64 = 0,
    rotate_ns: u64 = 0,
    clahe_ns: u64 = 0,
    axis_total_ns: u64 = 0,
    analyze_ns: u64 = 0,
    profiles_ns: u64 = 0,
    gradients_ns: u64 = 0,
    dtw_ns: u64 = 0,
    snap_repair_ns: u64 = 0,
    frames_from_edges_ns: u64 = 0,
    angle_ns: u64 = 0,
    cross_strip_ns: u64 = 0,
    transform_back_ns: u64 = 0,
    rotated: bool = false,

    pub fn deinit(self: *DetectFramesBreakdown, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const DetectionGrayOptions = struct {
    invert: bool = false,
};

const DetectionGrayImage = struct {
    gray: []f64,
    gray_u8: []u8,

    fn deinit(self: *DetectionGrayImage, allocator: std.mem.Allocator) void {
        allocator.free(self.gray);
        allocator.free(self.gray_u8);
        self.* = undefined;
    }
};

const DetectionGrayImageRangeContext = struct {
    data: []const u8,
    gray: []f64,
    gray_u8: []u8,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    options: DetectionGrayOptions,
    start: usize,
    end: usize,
};

const FilmExtentBreakdown = struct {
    extent: ?FilmExtent,
    otsu_ns: u64 = 0,
    mask_ns: u64 = 0,
    close_ns: u64 = 0,
    component_ns: u64 = 0,
    geometry_ns: u64 = 0,
};

const GrayToInvertedU8RangeContext = struct {
    input: []const f64,
    output: []u8,
    start: usize,
    end: usize,
};

const U8InvertRangeContext = struct {
    input: []const u8,
    output: []u8,
    start: usize,
    end: usize,
};

const U8ToF64RangeContext = struct {
    input: []const u8,
    output: []f64,
    start: usize,
    end: usize,
};

const AngleGradientStripsContext = struct {
    gray: []const f64,
    width: usize,
    height: usize,
    is_vertical: bool,
    strip_len: usize,
    cross_dim: usize,
    angle_band_width: usize,
    half_band: usize,
    profile_storage: []f64,
    scratch_storage: []f64,
    gradient_storage: []f64,
    gradients: [][]f64,
    positions: []f64,
    profile_kernel: []const f64,
    gradient_kernel: []const f64,
    strip_start: usize,
    strip_end: usize,
};

pub const RebateMaskRect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const RebateRect = struct {
    cx: f64,
    cy: f64,
    w: f64,
    h: f64,
    angle: f64 = 0.0,
};

pub const RebateOriginRect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    angle: f64 = 0.0,
};

pub const PreviewGeometry = struct {
    full_width: usize,
    full_height: usize,
    preview_width: usize,
    preview_height: usize,
    preview_scale: f64,
};

pub const PreviewSelection = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    angle: f64 = 0.0,
};

pub fn prepareDetectionGray(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: usize,
    height: usize,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    options: DetectionGrayOptions,
) ![]f64 {
    if (width == 0 or height == 0) return error.InvalidDetectionGrayInput;
    if (samples_per_pixel != 1 and samples_per_pixel != 3) return error.InvalidDetectionGrayInput;
    if (bits_per_sample != 8 and bits_per_sample != 16) return error.InvalidDetectionGrayInput;
    const bytes_per_sample: usize = bits_per_sample / 8;
    const pixel_count = try std.math.mul(usize, width, height);
    const sample_count = try std.math.mul(usize, pixel_count, samples_per_pixel);
    const expected_len = try std.math.mul(usize, sample_count, bytes_per_sample);
    if (data.len != expected_len) return error.InvalidDetectionGrayInput;

    const gray = try allocator.alloc(f64, pixel_count);
    errdefer allocator.free(gray);
    for (gray, 0..) |*value, pixel_index| {
        const sample_index = pixel_index * samples_per_pixel;
        var gray_u8: u8 = 0;
        if (samples_per_pixel == 1) {
            gray_u8 = sampleToPythonGray8(data, sample_index, bits_per_sample);
        } else if (bits_per_sample == 16) {
            const r = @as(u32, sampleToU16(data, sample_index, bits_per_sample));
            const g = @as(u32, sampleToU16(data, sample_index + 1, bits_per_sample));
            const b = @as(u32, sampleToU16(data, sample_index + 2, bits_per_sample));
            gray_u8 = @intCast((r + g + b) / (3 * 256));
        } else {
            const r = @as(f64, @floatFromInt(sampleToU16(data, sample_index, bits_per_sample)));
            const g = @as(f64, @floatFromInt(sampleToU16(data, sample_index + 1, bits_per_sample)));
            const b = @as(f64, @floatFromInt(sampleToU16(data, sample_index + 2, bits_per_sample)));
            gray_u8 = @intFromFloat(@floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5));
        }
        const prepared = if (options.invert) 255 - gray_u8 else gray_u8;
        value.* = u8_to_unit_f64[prepared];
    }
    return gray;
}

fn prepareDetectionGrayImage(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: usize,
    height: usize,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    options: DetectionGrayOptions,
) !DetectionGrayImage {
    if (width == 0 or height == 0) return error.InvalidDetectionGrayInput;
    if (samples_per_pixel != 1 and samples_per_pixel != 3) return error.InvalidDetectionGrayInput;
    if (bits_per_sample != 8 and bits_per_sample != 16) return error.InvalidDetectionGrayInput;
    const bytes_per_sample: usize = bits_per_sample / 8;
    const pixel_count = try std.math.mul(usize, width, height);
    const sample_count = try std.math.mul(usize, pixel_count, samples_per_pixel);
    const expected_len = try std.math.mul(usize, sample_count, bytes_per_sample);
    if (data.len != expected_len) return error.InvalidDetectionGrayInput;

    const gray = try allocator.alloc(f64, pixel_count);
    errdefer allocator.free(gray);
    const gray_u8 = try allocator.alloc(u8, pixel_count);
    var image = DetectionGrayImage{
        .gray = gray,
        .gray_u8 = gray_u8,
    };
    errdefer image.deinit(allocator);

    const worker_count = workerCountForItems(pixel_count, conversion_parallel_min_items);
    if (parallelism.enabled and worker_count > 1) {
        try prepareDetectionGrayImageParallel(allocator, data, image.gray, image.gray_u8, samples_per_pixel, bits_per_sample, options, worker_count);
    } else {
        fillDetectionGrayImageRange(data, image.gray, image.gray_u8, samples_per_pixel, bits_per_sample, options, 0, pixel_count);
    }
    return image;
}

fn prepareDetectionGrayImageParallel(
    allocator: std.mem.Allocator,
    data: []const u8,
    gray: []f64,
    gray_u8: []u8,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    options: DetectionGrayOptions,
    worker_count: usize,
) !void {
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(DetectionGrayImageRangeContext, worker_count);
    defer allocator.free(contexts);
    var started: usize = 0;
    errdefer {
        for (threads[0..started]) |thread| {
            thread.join();
        }
    }
    for (0..worker_count) |worker_index| {
        const start = gray.len * worker_index / worker_count;
        const end = gray.len * (worker_index + 1) / worker_count;
        contexts[worker_index] = .{
            .data = data,
            .gray = gray,
            .gray_u8 = gray_u8,
            .samples_per_pixel = samples_per_pixel,
            .bits_per_sample = bits_per_sample,
            .options = options,
            .start = start,
            .end = end,
        };
        threads[worker_index] = try std.Thread.spawn(.{}, prepareDetectionGrayImageWorker, .{&contexts[worker_index]});
        started += 1;
    }
    for (threads) |thread| {
        thread.join();
    }
}

fn prepareDetectionGrayImageWorker(context: *const DetectionGrayImageRangeContext) void {
    fillDetectionGrayImageRange(
        context.data,
        context.gray,
        context.gray_u8,
        context.samples_per_pixel,
        context.bits_per_sample,
        context.options,
        context.start,
        context.end,
    );
}

fn fillDetectionGrayImageRange(
    data: []const u8,
    gray: []f64,
    gray_u8: []u8,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    options: DetectionGrayOptions,
    start: usize,
    end: usize,
) void {
    var pixel_index = start;
    if (samples_per_pixel == 3 and bits_per_sample == 16) {
        pixel_index = fillDetectionGrayImageRangeRgb16Simd(data, gray, gray_u8, options, start, end);
    }
    while (pixel_index < end) : (pixel_index += 1) {
        const sample_index = pixel_index * samples_per_pixel;
        var gray_byte: u8 = 0;
        if (samples_per_pixel == 1) {
            gray_byte = sampleToPythonGray8(data, sample_index, bits_per_sample);
        } else if (bits_per_sample == 16) {
            const r = @as(u32, sampleToU16(data, sample_index, bits_per_sample));
            const g = @as(u32, sampleToU16(data, sample_index + 1, bits_per_sample));
            const b = @as(u32, sampleToU16(data, sample_index + 2, bits_per_sample));
            gray_byte = @intCast((r + g + b) / (3 * 256));
        } else {
            const r = @as(f64, @floatFromInt(sampleToU16(data, sample_index, bits_per_sample)));
            const g = @as(f64, @floatFromInt(sampleToU16(data, sample_index + 1, bits_per_sample)));
            const b = @as(f64, @floatFromInt(sampleToU16(data, sample_index + 2, bits_per_sample)));
            gray_byte = @intFromFloat(@floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5));
        }
        const prepared = if (options.invert) 255 - gray_byte else gray_byte;
        gray_u8[pixel_index] = prepared;
        gray[pixel_index] = u8_to_unit_f64[prepared];
    }
}

fn fillDetectionGrayImageRangeRgb16Simd(
    data: []const u8,
    gray: []f64,
    gray_u8: []u8,
    options: DetectionGrayOptions,
    start: usize,
    end: usize,
) usize {
    const VecU32 = @Vector(grayscale_simd_width, u32);
    const divisor: VecU32 = @splat(3 * 256);
    const max_u8: VecU32 = @splat(255);
    var pixel_index = start;
    while (pixel_index + grayscale_simd_width <= end) : (pixel_index += grayscale_simd_width) {
        var r: VecU32 = undefined;
        var g: VecU32 = undefined;
        var b: VecU32 = undefined;
        inline for (0..grayscale_simd_width) |lane| {
            const byte_index = (pixel_index + lane) * 6;
            r[lane] = std.mem.readInt(u16, data[byte_index..][0..2], .little);
            g[lane] = std.mem.readInt(u16, data[byte_index + 2 ..][0..2], .little);
            b[lane] = std.mem.readInt(u16, data[byte_index + 4 ..][0..2], .little);
        }
        const gray_values = (r + g + b) / divisor;
        const prepared_values = if (options.invert) max_u8 - gray_values else gray_values;
        inline for (0..grayscale_simd_width) |lane| {
            const prepared: u8 = @intCast(prepared_values[lane]);
            gray_u8[pixel_index + lane] = prepared;
            gray[pixel_index + lane] = u8_to_unit_f64[prepared];
        }
    }
    return pixel_index;
}

pub fn resizeImageArea(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: usize,
    height: usize,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    target_width: usize,
    target_height: usize,
) ![]u8 {
    if (width == 0 or height == 0 or target_width == 0 or target_height == 0) return error.InvalidAreaResizeInput;
    if (samples_per_pixel != 1 and samples_per_pixel != 3) return error.InvalidAreaResizeInput;
    if (bits_per_sample != 8 and bits_per_sample != 16) return error.InvalidAreaResizeInput;
    if (target_width > width or target_height > height) return error.InvalidAreaResizeInput;
    const bytes_per_sample: usize = bits_per_sample / 8;
    const input_sample_count = try std.math.mul(usize, try std.math.mul(usize, width, height), samples_per_pixel);
    if (data.len != try std.math.mul(usize, input_sample_count, bytes_per_sample)) return error.InvalidAreaResizeInput;
    if (target_width == width and target_height == height) return allocator.dupe(u8, data);

    var x_weights = try buildAreaWeights(allocator, width, target_width);
    defer x_weights.deinit(allocator);
    var y_weights = try buildAreaWeights(allocator, height, target_height);
    defer y_weights.deinit(allocator);

    const output_sample_count = try std.math.mul(usize, try std.math.mul(usize, target_width, target_height), samples_per_pixel);
    const output = try allocator.alloc(u8, try std.math.mul(usize, output_sample_count, bytes_per_sample));
    errdefer allocator.free(output);

    for (0..target_height) |y| {
        const y_slice = y_weights.forOutput(y);
        for (0..target_width) |x| {
            const x_slice = x_weights.forOutput(x);
            for (0..samples_per_pixel) |channel| {
                var sum: f64 = 0.0;
                for (y_slice) |yw| {
                    for (x_slice) |xw| {
                        const sample_index = (yw.index * width + xw.index) * samples_per_pixel + channel;
                        sum += @as(f64, @floatFromInt(sampleToU16(data, sample_index, bits_per_sample))) * yw.weight * xw.weight;
                    }
                }
                writeRoundedSample(output, (y * target_width + x) * samples_per_pixel + channel, bits_per_sample, sum);
            }
        }
    }
    return output;
}

pub fn detectFilmExtentAxisAligned(
    allocator: std.mem.Allocator,
    raw_gray: []const f64,
    width: usize,
    height: usize,
) !?FilmExtent {
    if (width == 0 or height == 0 or raw_gray.len != width * height) return error.InvalidFilmExtentInput;
    const threshold = otsuThreshold(raw_gray);
    const pixel_count = try std.math.mul(usize, width, height);
    const mask = try allocator.alloc(bool, pixel_count);
    defer allocator.free(mask);
    for (mask, raw_gray) |*value, pixel| {
        value.* = grayToU8(pixel) <= threshold;
    }

    var kernel = @max(@as(usize, 3), @min(width, height) / 20);
    kernel |= 1;
    try closeBinaryMask(allocator, mask, width, height, kernel);

    const component_mask = try allocator.alloc(bool, pixel_count);
    defer allocator.free(component_mask);
    const component = try largestComponentBounds(allocator, mask, width, height, component_mask);
    const bounds = component orelse return null;
    if (@as(f64, @floatFromInt(bounds.area)) < @as(f64, @floatFromInt(pixel_count)) * 0.10) {
        return null;
    }
    return try componentRotatedExtent(allocator, component_mask, width, height, bounds);
}

pub fn detectFilmExtentAxisAlignedU8(
    allocator: std.mem.Allocator,
    raw_gray: []const u8,
    width: usize,
    height: usize,
) !?FilmExtent {
    if (width == 0 or height == 0 or raw_gray.len != width * height) return error.InvalidFilmExtentInput;
    const threshold = otsuThresholdU8(raw_gray);
    const pixel_count = try std.math.mul(usize, width, height);
    const mask = try allocator.alloc(bool, pixel_count);
    defer allocator.free(mask);
    for (mask, raw_gray) |*value, pixel| {
        value.* = pixel <= threshold;
    }

    var kernel = @max(@as(usize, 3), @min(width, height) / 20);
    kernel |= 1;
    try closeBinaryMask(allocator, mask, width, height, kernel);

    const component_mask = try allocator.alloc(bool, pixel_count);
    defer allocator.free(component_mask);
    const component = try largestComponentBounds(allocator, mask, width, height, component_mask);
    const bounds = component orelse return null;
    if (@as(f64, @floatFromInt(bounds.area)) < @as(f64, @floatFromInt(pixel_count)) * 0.10) {
        return null;
    }
    return try componentRotatedExtent(allocator, component_mask, width, height, bounds);
}

fn detectFilmExtentAxisAlignedU8Breakdown(
    allocator: std.mem.Allocator,
    raw_gray: []const u8,
    width: usize,
    height: usize,
) !FilmExtentBreakdown {
    if (width == 0 or height == 0 or raw_gray.len != width * height) return error.InvalidFilmExtentInput;
    var breakdown = FilmExtentBreakdown{ .extent = null };

    const otsu_started = monotonicNowNs();
    const threshold = otsuThresholdU8(raw_gray);
    breakdown.otsu_ns = monotonicNowNs() - otsu_started;

    const mask_started = monotonicNowNs();
    const pixel_count = try std.math.mul(usize, width, height);
    const mask = try allocator.alloc(bool, pixel_count);
    defer allocator.free(mask);
    for (mask, raw_gray) |*value, pixel| {
        value.* = pixel <= threshold;
    }
    breakdown.mask_ns = monotonicNowNs() - mask_started;

    const close_started = monotonicNowNs();
    var kernel = @max(@as(usize, 3), @min(width, height) / 20);
    kernel |= 1;
    try closeBinaryMask(allocator, mask, width, height, kernel);
    breakdown.close_ns = monotonicNowNs() - close_started;

    const component_started = monotonicNowNs();
    const component_mask = try allocator.alloc(bool, pixel_count);
    defer allocator.free(component_mask);
    const component = try largestComponentBounds(allocator, mask, width, height, component_mask);
    const bounds = component orelse {
        breakdown.component_ns = monotonicNowNs() - component_started;
        return breakdown;
    };
    if (@as(f64, @floatFromInt(bounds.area)) < @as(f64, @floatFromInt(pixel_count)) * 0.10) {
        breakdown.component_ns = monotonicNowNs() - component_started;
        return breakdown;
    }
    breakdown.component_ns = monotonicNowNs() - component_started;

    const geometry_started = monotonicNowNs();
    breakdown.extent = try componentRotatedExtent(allocator, component_mask, width, height, bounds);
    breakdown.geometry_ns = monotonicNowNs() - geometry_started;
    return breakdown;
}

pub fn detectFramesFromImage(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: usize,
    height: usize,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    format: FilmFormat,
    options: DetectFramesImageOptions,
) !DetectFramesResult {
    var raw_gray = try prepareDetectionGrayImage(
        allocator,
        data,
        width,
        height,
        samples_per_pixel,
        bits_per_sample,
        .{ .invert = false },
    );
    defer raw_gray.deinit(allocator);

    const film_extent = if (options.film_extent_override) |extent|
        extent
    else if (options.detect_film_extent)
        try detectFilmExtentAxisAlignedU8(allocator, raw_gray.gray_u8, width, height)
    else
        null;

    const rotation_threshold_rad = 0.1 * std.math.pi / 180.0;
    if (film_extent) |extent| {
        if (@abs(extent.strip_angle) > rotation_threshold_rad) {
            const transform = try expandedRotationTransform(width, height, extent.strip_angle);
            var rotated_raw = try rotateImageExpandedReplicate(allocator, raw_gray.gray, width, height, extent.strip_angle);
            defer rotated_raw.deinit(allocator);
            const rotated_strip = if (options.apply_clahe)
                try prepareClaheStripGray(allocator, rotated_raw.pixels, rotated_raw.width, rotated_raw.height)
            else
                try allocator.dupe(f64, rotated_raw.pixels);
            defer allocator.free(rotated_strip);

            var detected = try detectFramesAxisAlignedPrepared(allocator, rotated_strip, rotated_raw.width, rotated_raw.height, format, .{
                .frame_count_override = options.frame_count_override,
                .film_extent = extent,
                .cross_gray_raw = rotated_raw.pixels,
                .dtw_options = options.dtw_options,
            });
            errdefer detected.deinit(allocator);
            try transformFramesFromRotatedToOriginal(detected.frames, transform.inverse, extent.strip_angle);
            return detected;
        }
    }

    const strip_gray = if (options.apply_clahe)
        try prepareClaheStripGrayU8(allocator, raw_gray.gray_u8, width, height)
    else
        try allocator.dupe(f64, raw_gray.gray);
    defer allocator.free(strip_gray);

    return detectFramesAxisAlignedPrepared(allocator, strip_gray, width, height, format, .{
        .frame_count_override = options.frame_count_override,
        .film_extent = film_extent,
        .cross_gray_raw = raw_gray.gray,
        .dtw_options = options.dtw_options,
    });
}

pub fn detectFramesFromImageBreakdown(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: usize,
    height: usize,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    format: FilmFormat,
    options: DetectFramesImageOptions,
) !DetectFramesBreakdown {
    var breakdown: DetectFramesBreakdown = .{};

    const prepare_started = monotonicNowNs();
    var raw_gray = try prepareDetectionGrayImage(
        allocator,
        data,
        width,
        height,
        samples_per_pixel,
        bits_per_sample,
        .{ .invert = false },
    );
    breakdown.prepare_gray_ns = monotonicNowNs() - prepare_started;
    defer raw_gray.deinit(allocator);

    const film_extent_started = monotonicNowNs();
    const film_extent = if (options.film_extent_override) |extent| extent else if (options.detect_film_extent) extent: {
        const extent_breakdown = try detectFilmExtentAxisAlignedU8Breakdown(allocator, raw_gray.gray_u8, width, height);
        breakdown.film_otsu_ns = extent_breakdown.otsu_ns;
        breakdown.film_mask_ns = extent_breakdown.mask_ns;
        breakdown.film_close_ns = extent_breakdown.close_ns;
        breakdown.film_component_ns = extent_breakdown.component_ns;
        breakdown.film_geometry_ns = extent_breakdown.geometry_ns;
        break :extent extent_breakdown.extent;
    } else null;
    breakdown.film_extent_ns = monotonicNowNs() - film_extent_started;

    const rotation_threshold_rad = 0.1 * std.math.pi / 180.0;
    if (film_extent) |extent| {
        if (@abs(extent.strip_angle) > rotation_threshold_rad) {
            const rotate_started = monotonicNowNs();
            const transform = try expandedRotationTransform(width, height, extent.strip_angle);
            var rotated_raw = try rotateImageExpandedReplicate(allocator, raw_gray.gray, width, height, extent.strip_angle);
            breakdown.rotate_ns = monotonicNowNs() - rotate_started;
            defer rotated_raw.deinit(allocator);

            const clahe_started = monotonicNowNs();
            const rotated_strip = if (options.apply_clahe)
                try prepareClaheStripGray(allocator, rotated_raw.pixels, rotated_raw.width, rotated_raw.height)
            else
                try allocator.dupe(f64, rotated_raw.pixels);
            breakdown.clahe_ns = monotonicNowNs() - clahe_started;
            defer allocator.free(rotated_strip);

            var axis_breakdown = try detectFramesAxisAlignedPreparedBreakdown(allocator, rotated_strip, rotated_raw.width, rotated_raw.height, format, .{
                .frame_count_override = options.frame_count_override,
                .film_extent = extent,
                .cross_gray_raw = rotated_raw.pixels,
                .dtw_options = options.dtw_options,
            });
            errdefer axis_breakdown.deinit(allocator);
            copyAxisBreakdown(&breakdown, axis_breakdown);
            breakdown.result = axis_breakdown.result;
            breakdown.rotated = true;

            const transform_started = monotonicNowNs();
            try transformFramesFromRotatedToOriginal(breakdown.result.frames, transform.inverse, extent.strip_angle);
            breakdown.transform_back_ns = monotonicNowNs() - transform_started;
            return breakdown;
        }
    }

    const clahe_started = monotonicNowNs();
    const strip_gray = if (options.apply_clahe)
        try prepareClaheStripGrayU8(allocator, raw_gray.gray_u8, width, height)
    else
        try allocator.dupe(f64, raw_gray.gray);
    breakdown.clahe_ns = monotonicNowNs() - clahe_started;
    defer allocator.free(strip_gray);

    const axis_breakdown = try detectFramesAxisAlignedPreparedBreakdown(allocator, strip_gray, width, height, format, .{
        .frame_count_override = options.frame_count_override,
        .film_extent = film_extent,
        .cross_gray_raw = raw_gray.gray,
        .dtw_options = options.dtw_options,
    });
    copyAxisBreakdown(&breakdown, axis_breakdown);
    breakdown.result = axis_breakdown.result;
    return breakdown;
}

fn copyAxisBreakdown(target: *DetectFramesBreakdown, source: DetectFramesBreakdown) void {
    target.axis_total_ns = source.axis_total_ns;
    target.analyze_ns = source.analyze_ns;
    target.profiles_ns = source.profiles_ns;
    target.gradients_ns = source.gradients_ns;
    target.dtw_ns = source.dtw_ns;
    target.snap_repair_ns = source.snap_repair_ns;
    target.frames_from_edges_ns = source.frames_from_edges_ns;
    target.angle_ns = source.angle_ns;
    target.cross_strip_ns = source.cross_strip_ns;
}

pub fn detectFramesWorkScale(width: usize, height: usize) !f64 {
    if (width == 0 or height == 0) return error.InvalidDetectFramesInput;
    const work_size = @max(width, height);
    const scale = @as(f64, @floatFromInt(work_size)) / @as(f64, @floatFromInt(@max(width, height)));
    return @min(scale, 1.0);
}

fn prepareClaheStripGray(allocator: std.mem.Allocator, raw_gray: []const f64, width: usize, height: usize) ![]f64 {
    if (width == 0 or height == 0 or raw_gray.len != width * height) return error.InvalidDetectionGrayInput;
    const inverted = try grayImageToInvertedU8Bytes(allocator, raw_gray);
    defer allocator.free(inverted);
    const clahe = try applyClahe8(allocator, inverted, width, height, .{ .clip_limit = 3.0, .tiles_x = 8, .tiles_y = 8 });
    defer allocator.free(clahe);
    return u8ImageToF64(allocator, clahe);
}

fn prepareClaheStripGrayU8(allocator: std.mem.Allocator, raw_gray: []const u8, width: usize, height: usize) ![]f64 {
    if (width == 0 or height == 0 or raw_gray.len != width * height) return error.InvalidDetectionGrayInput;
    const inverted = try allocator.alloc(u8, raw_gray.len);
    defer allocator.free(inverted);
    try fillInvertedU8(allocator, raw_gray, inverted);
    const clahe = try applyClahe8(allocator, inverted, width, height, .{ .clip_limit = 3.0, .tiles_x = 8, .tiles_y = 8 });
    defer allocator.free(clahe);
    return u8ImageToF64(allocator, clahe);
}

pub fn analyzeStrip(
    img_width: usize,
    img_height: usize,
    format: FilmFormat,
    film_extent: ?FilmExtent,
) !StripAnalysis {
    if (img_width == 0 or img_height == 0) return error.InvalidStripAnalysisInput;
    const is_vertical = img_height > img_width;
    const strip_narrow_px, const strip_long_px = if (film_extent) |extent|
        .{ extent.strip_narrow_px, extent.strip_long_px }
    else if (is_vertical)
        .{ @as(f64, @floatFromInt(img_width)), @as(f64, @floatFromInt(img_height)) }
    else
        .{ @as(f64, @floatFromInt(img_height)), @as(f64, @floatFromInt(img_width)) };
    if (!std.math.isFinite(strip_narrow_px) or !std.math.isFinite(strip_long_px) or strip_narrow_px <= 0.0 or strip_long_px <= 0.0) {
        return error.InvalidStripAnalysisInput;
    }

    const px_per_mm = strip_narrow_px / format.strip_width_mm;
    const narrow_mm = format.narrowMm();
    const wide_mm = format.wideMm();
    const frame_w_px = if (is_vertical) narrow_mm * px_per_mm else wide_mm * px_per_mm;
    const frame_h_px = if (is_vertical) wide_mm * px_per_mm else narrow_mm * px_per_mm;
    const pitch_px = format.pitch_mm * px_per_mm;
    const n_float = format.pitchRatio() * strip_long_px / strip_narrow_px;
    const n_frames = @max(@as(usize, 1), @as(usize, @intFromFloat(n_float)));
    return .{
        .n_frames = n_frames,
        .frame_w = frame_w_px,
        .frame_h = frame_h_px,
        .pitch_px = pitch_px,
        .is_vertical = is_vertical,
    };
}

pub fn initialPlacement(
    allocator: std.mem.Allocator,
    img_width: usize,
    img_height: usize,
    n_frames: usize,
    strip_info: StripAnalysis,
    strip_angle: f64,
) ![]FrameRect {
    if (img_width == 0 or img_height == 0 or n_frames == 0 or !std.math.isFinite(strip_angle)) {
        return error.InvalidInitialPlacementInput;
    }
    if (!std.math.isFinite(strip_info.frame_w) or !std.math.isFinite(strip_info.frame_h) or !std.math.isFinite(strip_info.pitch_px) or
        strip_info.frame_w <= 0.0 or strip_info.frame_h <= 0.0 or strip_info.pitch_px <= 0.0)
    {
        return error.InvalidInitialPlacementInput;
    }

    const frames = try allocator.alloc(FrameRect, n_frames);
    errdefer allocator.free(frames);
    if (strip_info.is_vertical) {
        const cx = @as(f64, @floatFromInt(img_width)) / 2.0;
        const total_span = strip_info.pitch_px * @as(f64, @floatFromInt(n_frames));
        const y_offset = (@as(f64, @floatFromInt(img_height)) - total_span) / 2.0 + strip_info.pitch_px / 2.0;
        for (frames, 0..) |*frame, i| {
            frame.* = .{
                .cx = cx,
                .cy = y_offset + @as(f64, @floatFromInt(i)) * strip_info.pitch_px,
                .w = strip_info.frame_w,
                .h = strip_info.frame_h,
                .angle = strip_angle,
            };
        }
    } else {
        const cy = @as(f64, @floatFromInt(img_height)) / 2.0;
        const total_span = strip_info.pitch_px * @as(f64, @floatFromInt(n_frames));
        const x_offset = (@as(f64, @floatFromInt(img_width)) - total_span) / 2.0 + strip_info.pitch_px / 2.0;
        for (frames, 0..) |*frame, i| {
            frame.* = .{
                .cx = x_offset + @as(f64, @floatFromInt(i)) * strip_info.pitch_px,
                .cy = cy,
                .w = strip_info.frame_w,
                .h = strip_info.frame_h,
                .angle = strip_angle,
            };
        }
    }
    return frames;
}

pub fn detectFramesAxisAlignedPrepared(
    allocator: std.mem.Allocator,
    gray: []const f64,
    width: usize,
    height: usize,
    format: FilmFormat,
    options: DetectFramesOptions,
) !DetectFramesResult {
    if (width == 0 or height == 0 or gray.len != width * height) return error.InvalidDetectFramesInput;
    var strip_info = try analyzeStrip(width, height, format, options.film_extent);
    if (options.frame_count_override) |override| {
        if (override == 0) return error.InvalidDetectFramesInput;
        strip_info.n_frames = override;
    }

    var profiles = try computeStripProfiles(allocator, gray, width, height, strip_info.is_vertical);
    defer profiles.deinit(allocator);

    const grad_a = try computeAbsGradientBlurred(allocator, profiles.profile_a);
    defer allocator.free(grad_a);
    const grad_b = try computeAbsGradientBlurred(allocator, profiles.profile_b);
    defer allocator.free(grad_b);
    const grad_c = try computeAbsGradientBlurred(allocator, profiles.profile_c);
    defer allocator.free(grad_c);
    const grad_avg = try averageGradients(allocator, grad_a, grad_b, grad_c);
    defer allocator.free(grad_avg);

    const strip_len = if (strip_info.is_vertical) height else width;
    const frame_strip_dim = if (strip_info.is_vertical) strip_info.frame_h else strip_info.frame_w;
    var alignment = try alignPitchDtw(allocator, grad_avg, strip_len, format, strip_info.n_frames, options.dtw_options);
    defer alignment.deinit(allocator);

    const edges = try allocator.alloc(usize, alignment.edge_positions.len);
    errdefer allocator.free(edges);
    try snapEdgesToGradients(grad_avg, alignment.edge_positions, edges, frame_strip_dim);
    try applySizeConsistencyCorrection(grad_avg, edges, strip_info.n_frames, frame_strip_dim);
    try repairTerminalFrames(
        allocator,
        grad_avg,
        edges,
        strip_info.n_frames,
        frame_strip_dim,
        @intFromFloat(frame_strip_dim * 0.15),
        strip_info.pitch_px,
    );
    const frames = try framesFromStripEdges(allocator, edges, width, height, format, strip_info, options.strip_angle);
    errdefer allocator.free(frames);
    try estimateFrameAnglesAxisAligned(allocator, gray, width, height, strip_info, frame_strip_dim, edges, frames);
    try refineCrossStripAxisAligned(allocator, options.cross_gray_raw orelse gray, width, height, format, strip_info, frames);
    allocator.free(edges);
    return .{ .frames = frames, .strip_info = strip_info, .aspect = detectFramesAspect(format, strip_info.is_vertical) };
}

pub fn detectFramesAxisAlignedPreparedBreakdown(
    allocator: std.mem.Allocator,
    gray: []const f64,
    width: usize,
    height: usize,
    format: FilmFormat,
    options: DetectFramesOptions,
) !DetectFramesBreakdown {
    if (width == 0 or height == 0 or gray.len != width * height) return error.InvalidDetectFramesInput;
    const total_started = monotonicNowNs();
    var breakdown: DetectFramesBreakdown = .{};

    const analyze_started = monotonicNowNs();
    var strip_info = try analyzeStrip(width, height, format, options.film_extent);
    if (options.frame_count_override) |override| {
        if (override == 0) return error.InvalidDetectFramesInput;
        strip_info.n_frames = override;
    }
    breakdown.analyze_ns = monotonicNowNs() - analyze_started;

    const profiles_started = monotonicNowNs();
    var profiles = try computeStripProfiles(allocator, gray, width, height, strip_info.is_vertical);
    breakdown.profiles_ns = monotonicNowNs() - profiles_started;
    defer profiles.deinit(allocator);

    const gradients_started = monotonicNowNs();
    const grad_a = try computeAbsGradientBlurred(allocator, profiles.profile_a);
    defer allocator.free(grad_a);
    const grad_b = try computeAbsGradientBlurred(allocator, profiles.profile_b);
    defer allocator.free(grad_b);
    const grad_c = try computeAbsGradientBlurred(allocator, profiles.profile_c);
    defer allocator.free(grad_c);
    const grad_avg = try averageGradients(allocator, grad_a, grad_b, grad_c);
    defer allocator.free(grad_avg);
    breakdown.gradients_ns = monotonicNowNs() - gradients_started;

    const strip_len = if (strip_info.is_vertical) height else width;
    const frame_strip_dim = if (strip_info.is_vertical) strip_info.frame_h else strip_info.frame_w;

    const dtw_started = monotonicNowNs();
    var alignment = try alignPitchDtw(allocator, grad_avg, strip_len, format, strip_info.n_frames, options.dtw_options);
    breakdown.dtw_ns = monotonicNowNs() - dtw_started;
    defer alignment.deinit(allocator);

    const snap_repair_started = monotonicNowNs();
    const edges = try allocator.alloc(usize, alignment.edge_positions.len);
    errdefer allocator.free(edges);
    try snapEdgesToGradients(grad_avg, alignment.edge_positions, edges, frame_strip_dim);
    try applySizeConsistencyCorrection(grad_avg, edges, strip_info.n_frames, frame_strip_dim);
    try repairTerminalFrames(
        allocator,
        grad_avg,
        edges,
        strip_info.n_frames,
        frame_strip_dim,
        @intFromFloat(frame_strip_dim * 0.15),
        strip_info.pitch_px,
    );
    breakdown.snap_repair_ns = monotonicNowNs() - snap_repair_started;

    const frames_started = monotonicNowNs();
    const frame_rects = try framesFromStripEdges(allocator, edges, width, height, format, strip_info, options.strip_angle);
    breakdown.frames_from_edges_ns = monotonicNowNs() - frames_started;
    errdefer allocator.free(frame_rects);

    const angle_started = monotonicNowNs();
    try estimateFrameAnglesAxisAligned(allocator, gray, width, height, strip_info, frame_strip_dim, edges, frame_rects);
    breakdown.angle_ns = monotonicNowNs() - angle_started;

    const cross_strip_started = monotonicNowNs();
    try refineCrossStripAxisAligned(allocator, options.cross_gray_raw orelse gray, width, height, format, strip_info, frame_rects);
    breakdown.cross_strip_ns = monotonicNowNs() - cross_strip_started;

    allocator.free(edges);
    breakdown.axis_total_ns = monotonicNowNs() - total_started;
    breakdown.result = .{
        .frames = frame_rects,
        .strip_info = strip_info,
        .aspect = detectFramesAspect(format, strip_info.is_vertical),
    };
    return breakdown;
}

pub fn computeStripProfiles(
    allocator: std.mem.Allocator,
    gray: []const f64,
    width: usize,
    height: usize,
    is_vertical: bool,
) !StripProfiles {
    if (width == 0 or height == 0 or gray.len != width * height) return error.InvalidFrameProfileBuffer;

    const profile_len = if (is_vertical) height else width;
    const cross_len = if (is_vertical) width else height;
    var result = StripProfiles{
        .profile_a = try allocator.alloc(f64, profile_len),
        .profile_b = try allocator.alloc(f64, profile_len),
        .profile_c = try allocator.alloc(f64, profile_len),
        .cross_profile = try allocator.alloc(f64, cross_len),
    };
    errdefer result.deinit(allocator);

    const cross_dim = if (is_vertical) width else height;
    const band_width = @max(@as(usize, 1), cross_dim / 15);
    const bands = [_]Band{
        try profileBand(cross_dim, band_width, 0.30),
        try profileBand(cross_dim, band_width, 0.50),
        try profileBand(cross_dim, band_width, 0.70),
    };

    if (is_vertical and bands[0].end <= bands[1].start and bands[1].end <= bands[2].start) {
        try computeVerticalStripProfilesSegmented(gray, width, height, bands, &result);
    } else {
        try computeBandProfile(gray, width, height, is_vertical, bands[0], result.profile_a);
        try computeBandProfile(gray, width, height, is_vertical, bands[1], result.profile_b);
        try computeBandProfile(gray, width, height, is_vertical, bands[2], result.profile_c);
        try computeCrossProfile(gray, width, height, is_vertical, result.cross_profile);
    }

    const scratch = try allocator.alloc(f64, @max(profile_len, cross_len));
    defer allocator.free(scratch);
    const profile_kernel = try gaussianKernel(allocator, profileBlurKernelSize(profile_len));
    defer allocator.free(profile_kernel);
    const cross_kernel = try gaussianKernel(allocator, profileBlurKernelSize(cross_len));
    defer allocator.free(cross_kernel);
    try gaussianBlur1dInPlacePrepared(result.profile_a, scratch, profile_kernel);
    try gaussianBlur1dInPlacePrepared(result.profile_b, scratch, profile_kernel);
    try gaussianBlur1dInPlacePrepared(result.profile_c, scratch, profile_kernel);
    try gaussianBlur1dInPlacePrepared(result.cross_profile, scratch, cross_kernel);
    return result;
}

pub fn alignPitchDtw(
    allocator: std.mem.Allocator,
    gradient: []const f64,
    strip_len: usize,
    format: FilmFormat,
    frame_count: usize,
    options: DtwOptions,
) !DtwAlignment {
    if (gradient.len == 0 or strip_len == 0 or frame_count == 0) return error.InvalidDtwInput;
    if (options.max_len == 0) return error.InvalidDtwInput;

    const dtw_scale = @min(@as(f64, @floatFromInt(options.max_len)) / @as(f64, @floatFromInt(gradient.len)), 1.0);
    const obs = if (dtw_scale < 1.0)
        try resizeArea1d(allocator, gradient, @max(@as(usize, 1), @as(usize, @intFromFloat(@as(f64, @floatFromInt(gradient.len)) * dtw_scale))))
    else
        try allocator.dupe(f64, gradient);
    defer allocator.free(obs);
    normalizeMax(obs);

    const total_mm = @as(f64, @floatFromInt(frame_count)) * format.pitch_mm;
    const template_len_target = @min(obs.len, @as(usize, 1000));
    const samples_per_mm = @as(f64, @floatFromInt(template_len_target)) / total_mm;
    const effective_frame_dim = @max(@as(usize, 1), @as(usize, @intFromFloat(format.wideMm() * samples_per_mm)));
    const effective_gap = @max(@as(usize, 1), @as(usize, @intFromFloat(format.gapMm() * samples_per_mm)));

    const template = try buildDtwTemplate(allocator, frame_count, effective_frame_dim, effective_gap);
    defer allocator.free(template);

    const n_t = template.len;
    const n_o = obs.len;
    const scale_ratio = @as(f64, @floatFromInt(n_o)) / @as(f64, @floatFromInt(n_t));
    const band = @as(usize, @intFromFloat(@max(
        @as(f64, @floatFromInt(n_o)) * 0.1,
        @as(f64, @floatFromInt(effective_frame_dim)) * 0.5,
    )));
    const columns = n_o + 1;
    const cost = try allocator.alloc(f64, (n_t + 1) * columns);
    defer allocator.free(cost);
    @memset(cost, dtw_inf);
    for (0..columns) |j| {
        cost[j] = 0.0;
    }

    const parent = try allocator.alloc(DtwParent, (n_t + 1) * columns);
    defer allocator.free(parent);
    @memset(parent, .{});

    for (1..n_t + 1) |i| {
        const expected_j: usize = @intFromFloat(@as(f64, @floatFromInt(i)) * scale_ratio);
        const j_lo = if (expected_j > band) expected_j - band else 1;
        const j_hi = @min(n_o, expected_j + band);
        if (j_hi < j_lo) continue;
        for (j_lo..j_hi + 1) |j| {
            const diff = template[i - 1] - obs[j - 1];
            const d = diff * diff;
            var best_cost = dtw_inf;
            var best_parent = DtwParent{};
            const diag = cost[dtwIndex(i - 1, j - 1, columns)];
            if (diag < dtw_inf) {
                best_cost = diag + d;
                best_parent = .{ .i = i - 1, .j = j - 1 };
            }
            const left = cost[dtwIndex(i, j - 1, columns)];
            if (left < dtw_inf and left + d * 0.5 < best_cost) {
                best_cost = left + d * 0.5;
                best_parent = .{ .i = i, .j = j - 1 };
            }
            const up = cost[dtwIndex(i - 1, j, columns)];
            if (up < dtw_inf and up + d * 0.5 < best_cost) {
                best_cost = up + d * 0.5;
                best_parent = .{ .i = i - 1, .j = j };
            }
            const index = dtwIndex(i, j, columns);
            if (best_cost < cost[index]) {
                cost[index] = best_cost;
                parent[index] = best_parent;
            }
        }
    }

    var end_j: usize = 0;
    var end_cost = cost[dtwIndex(n_t, 0, columns)];
    for (1..n_o + 1) |j| {
        const value = cost[dtwIndex(n_t, j, columns)];
        if (value < end_cost) {
            end_cost = value;
            end_j = j;
        }
    }
    if (end_cost >= dtw_inf) return error.InvalidDtwAlignment;

    const alignment = try allocator.alloc(?usize, n_t);
    defer allocator.free(alignment);
    @memset(alignment, null);
    var i = n_t;
    var j = end_j;
    while (i > 0 and j > 0) {
        alignment[i - 1] = j - 1;
        const previous = parent[dtwIndex(i, j, columns)];
        i = previous.i;
        j = previous.j;
    }

    const edge_positions = try allocator.alloc(usize, frame_count * 2);
    errdefer allocator.free(edge_positions);
    var edge_index: usize = 0;
    for (template, 0..) |value, template_index| {
        if (value != 1.0) continue;
        const pos_dtw = alignment[template_index] orelse try nearestAlignedIndex(alignment, template_index);
        edge_positions[edge_index] = pythonRoundToUsize(@as(f64, @floatFromInt(pos_dtw)) / dtw_scale);
        edge_index += 1;
    }
    if (edge_index != frame_count * 2) return error.InvalidDtwAlignment;

    return .{
        .edge_positions = edge_positions,
        .dtw_scale = dtw_scale,
        .template_len = template.len,
        .effective_frame_dim = effective_frame_dim,
        .effective_gap = effective_gap,
        .band = band,
        .end_j = end_j,
    };
}

pub fn snapEdgesToGradients(
    gradient: []const f64,
    edge_positions: []const usize,
    output: []usize,
    frame_strip_dim: f64,
) !void {
    if (gradient.len == 0 or edge_positions.len == 0 or output.len != edge_positions.len) return error.InvalidGradientSnapInput;
    if (!std.math.isFinite(frame_strip_dim) or frame_strip_dim <= 0.0) return error.InvalidGradientSnapInput;

    const snap_radius: usize = @intFromFloat(frame_strip_dim * 0.15);
    const n_edges = edge_positions.len;
    for (edge_positions, 0..) |pos, edge_index| {
        const is_frame_end = edge_index % 2 == 1;
        const is_internal = edge_index > 0 and edge_index < n_edges - 1;
        const min_pos = if (edge_index > 0) output[edge_index - 1] + 3 else 0;
        const radius_lo = if (pos > snap_radius) pos - snap_radius else 0;
        const lo = @max(min_pos, radius_lo);
        const hi = @min(gradient.len, pos + snap_radius + 1);

        if (hi > lo) {
            const window = gradient[lo..hi];
            const best = if (is_internal and is_frame_end)
                lo + (firstProminentPeak(window) orelse argMax(window))
            else if (is_internal and !is_frame_end)
                lo + (lastProminentPeak(window) orelse argMax(window))
            else
                lo + argMax(window);
            output[edge_index] = best;
        } else {
            output[edge_index] = @max(min_pos, pos);
        }
    }
}

pub fn snapToWeightedPeak(gradient: []const f64, target: usize, radius: usize, sigma: f64) !usize {
    if (gradient.len == 0) return error.InvalidWeightedPeakInput;
    if (!std.math.isFinite(sigma) or sigma <= 0.0) return error.InvalidWeightedPeakInput;
    const lo = if (target > radius) target - radius else 0;
    const hi = @min(gradient.len, target + radius + 1);
    if (hi <= lo) return target;

    var best_index = lo;
    var best_value = weightedPeakValue(gradient[lo], lo, target, sigma);
    for (gradient[lo + 1 .. hi], lo + 1..) |value, index| {
        const weighted = weightedPeakValue(value, index, target, sigma);
        if (weighted > best_value) {
            best_value = weighted;
            best_index = index;
        }
    }
    return best_index;
}

pub fn applySizeConsistencyCorrection(
    gradient: []const f64,
    edge_positions: []usize,
    frame_count: usize,
    frame_strip_dim: f64,
) !void {
    if (gradient.len == 0 or edge_positions.len == 0) return error.InvalidSizeCorrectionInput;
    if (!std.math.isFinite(frame_strip_dim) or frame_strip_dim <= 0.0) return error.InvalidSizeCorrectionInput;
    if (frame_count < 2 or edge_positions.len != frame_count * 2) return;

    for (0..frame_count) |frame_index| {
        const start_index = 2 * frame_index;
        const end_index = start_index + 1;
        const start = edge_positions[start_index];
        const end = edge_positions[end_index];
        const dim_i = @as(f64, @floatFromInt(end)) - @as(f64, @floatFromInt(start));
        const ratio = dim_i / frame_strip_dim;
        if (ratio >= 0.7 and ratio <= 1.3) continue;

        const end_target = start + pythonRoundToUsize(frame_strip_dim);
        const end_radius = @max(@as(usize, @intFromFloat(frame_strip_dim * 0.05)), @as(usize, 4));
        const half_dim: usize = @intFromFloat(frame_strip_dim * 0.5);
        const min_end = start + half_dim;
        const target_lo = if (end_target > end_radius) end_target - end_radius else 0;
        const end_lo = @max(min_end, target_lo);
        const end_hi = @min(gradient.len, end_target + end_radius + 1);
        edge_positions[end_index] = if (end_hi > end_lo)
            end_lo + argMax(gradient[end_lo..end_hi])
        else
            end_target;
    }
}

pub fn repairTerminalFrames(
    allocator: std.mem.Allocator,
    gradient: []const f64,
    edge_positions: []usize,
    frame_count: usize,
    frame_strip_dim: f64,
    snap_radius: usize,
    work_pitch_px: f64,
) !void {
    if (gradient.len == 0 or edge_positions.len == 0) return error.InvalidTerminalRepairInput;
    if (!std.math.isFinite(frame_strip_dim) or frame_strip_dim <= 0.0) return error.InvalidTerminalRepairInput;
    if (!std.math.isFinite(work_pitch_px) or work_pitch_px <= 0.0) return error.InvalidTerminalRepairInput;
    if (edge_positions.len != frame_count * 2) return;

    var run_last_frame_fix = false;
    if (frame_count >= 3) {
        run_last_frame_fix = true;
    } else if (frame_count == 2) {
        const last_dim = edge_positions[edge_positions.len - 1] - edge_positions[edge_positions.len - 2];
        const last_dim_ratio = @as(f64, @floatFromInt(last_dim)) / frame_strip_dim;
        run_last_frame_fix = last_dim_ratio < 0.85 or last_dim_ratio > 1.15;
    }

    if (run_last_frame_fix) {
        const starts = try frameStarts(allocator, edge_positions, frame_count);
        defer allocator.free(starts);
        const dims = try frameDimsRange(allocator, edge_positions, 0, frame_count - 1);
        defer allocator.free(dims);
        const pitches = try framePitchesRange(allocator, starts, 0, if (frame_count >= 2) frame_count - 2 else 0);
        defer allocator.free(pitches);

        const median_pitch = if (pitches.len > 0) try medianTrunc(allocator, pitches) else pythonRoundToUsize(work_pitch_px);
        const expected_dim = try medianTrunc(allocator, dims);
        const expected_start = starts[frame_count - 2] + median_pitch;
        const wide_radius = @max(snap_radius, expected_dim / 4);
        var new_start = try snapToWeightedPeak(gradient, expected_start, wide_radius, @max(@as(f64, @floatFromInt(expected_dim)) * 0.01, 1.0));
        new_start = @max(new_start, edge_positions[edge_positions.len - 3] + 3);

        const end_target = new_start + expected_dim;
        const dim_std = if (dims.len > 1) stdDevUsize(dims) else 3.0;
        const end_radius = @max(@as(usize, @intFromFloat(dim_std * 1.5)) + 2, @as(usize, 4));
        const end_lo = @max(new_start + expected_dim / 2, if (end_target > end_radius) end_target - end_radius else 0);
        const end_hi = @min(gradient.len, end_target + end_radius + 1);
        const new_end = if (end_hi > end_lo)
            end_lo + argMax(gradient[end_lo..end_hi])
        else
            end_target;
        edge_positions[edge_positions.len - 2] = new_start;
        edge_positions[edge_positions.len - 1] = new_end;
    }

    if (frame_count >= 3) {
        const starts = try frameStarts(allocator, edge_positions, frame_count);
        defer allocator.free(starts);
        const dims = try frameDimsRange(allocator, edge_positions, 1, frame_count);
        defer allocator.free(dims);
        const pitches = try framePitchesRange(allocator, starts, 1, frame_count - 1);
        defer allocator.free(pitches);

        const median_pitch = if (pitches.len > 0) try medianTrunc(allocator, pitches) else pythonRoundToUsize(work_pitch_px);
        const expected_dim = try medianTrunc(allocator, dims);
        const expected_end = starts[1] -| (median_pitch -| expected_dim);
        const expected_start = expected_end -| expected_dim;
        const wide_radius = @max(snap_radius, expected_dim / 4);
        const new_start = try snapToWeightedPeak(gradient, expected_start, wide_radius, @max(@as(f64, @floatFromInt(expected_dim)) * 0.01, 1.0));

        const end_target = new_start + expected_dim;
        const dim_std = if (dims.len > 1) stdDevUsize(dims) else 3.0;
        const end_radius = @max(@as(usize, @intFromFloat(dim_std * 1.5)) + 2, @as(usize, 4));
        const second_start_limit = if (edge_positions[2] > 3) edge_positions[2] - 3 else 0;
        const end_lo = @max(new_start + expected_dim / 2, if (end_target > end_radius) end_target - end_radius else 0);
        const end_hi = @min(second_start_limit, end_target + end_radius + 1);
        const new_end = if (end_hi > end_lo)
            end_lo + argMax(gradient[end_lo..end_hi])
        else
            end_target;
        edge_positions[0] = new_start;
        edge_positions[1] = new_end;
    }
}

pub fn measureCrossStripEdges(
    allocator: std.mem.Allocator,
    gradient_signed: []const f64,
    cross_dim_est: f64,
    cross_search_r: usize,
) !?CrossStripMeasurement {
    if (gradient_signed.len < 3) return error.InvalidCrossStripInput;
    if (!std.math.isFinite(cross_dim_est) or cross_dim_est <= 0.0) return error.InvalidCrossStripInput;

    const g_pos = try allocator.alloc(f64, gradient_signed.len);
    defer allocator.free(g_pos);
    const g_neg = try allocator.alloc(f64, gradient_signed.len);
    defer allocator.free(g_neg);
    for (gradient_signed, g_pos, g_neg) |value, *pos, *neg| {
        pos.* = @max(value, 0.0);
        neg.* = @max(-value, 0.0);
    }

    const n_pts = gradient_signed.len;
    const denominator = @as(f64, @floatFromInt(n_pts - 1));
    const half_w = cross_dim_est / 2.0;
    const hw_idx = pythonRoundToUsize(half_w * denominator / denominator);
    if (!(hw_idx > 0 and hw_idx < g_pos.len / 2)) return null;

    const lo_c = hw_idx;
    const hi_c = g_pos.len - hw_idx;
    const paired_len = hi_c - lo_c;
    const paired = try allocator.alloc(f64, paired_len);
    defer allocator.free(paired);
    for (paired, 0..) |*score, index| {
        score.* = g_pos[index] * g_neg[index + 2 * hw_idx];
    }

    const center_target_idx = pythonRoundToUsize(@as(f64, @floatFromInt(n_pts - 1)) / 2.0) - lo_c;
    const search_lo = if (center_target_idx > cross_search_r) center_target_idx - cross_search_r else 0;
    const search_hi = @min(paired.len, center_target_idx + cross_search_r + 1);
    if (search_hi <= search_lo) return null;
    const search = paired[search_lo..search_hi];
    if (maxSlice(search) <= 0.0) return null;

    const coarse_k = search_lo + argMax(search);
    const left_img_idx = coarse_k;
    const right_img_idx = coarse_k + 2 * hw_idx;
    const left_f = subpixelPeak(g_pos, if (left_img_idx > 2) left_img_idx - 2 else 0, @min(g_pos.len, left_img_idx + 3));
    const right_f = subpixelPeak(g_neg, if (right_img_idx > 2) right_img_idx - 2 else 0, @min(g_neg.len, right_img_idx + 3));
    const center = @as(f64, @floatFromInt(n_pts - 1)) / 2.0;
    const left_t = left_f + 1.0 - center;
    const right_t = right_f + 1.0 - center;
    return .{
        .left_t = left_t,
        .right_t = right_t,
        .cross_w = right_t - left_t,
        .cross_center_offset = (left_t + right_t) / 2.0,
        .hw_idx = hw_idx,
        .coarse_k = coarse_k,
    };
}

pub fn estimateAngleTheilSen(
    allocator: std.mem.Allocator,
    points: []const EdgePeakPoint,
    max_angle_rad: f64,
) !?TheilSenAngle {
    if (!std.math.isFinite(max_angle_rad) or max_angle_rad <= 0.0) return error.InvalidTheilSenInput;
    if (points.len < 2) return null;
    const slopes = try allocator.alloc(f64, points.len * (points.len - 1) / 2);
    defer allocator.free(slopes);
    var slope_count: usize = 0;
    for (0..points.len) |j| {
        for (j + 1..points.len) |k| {
            const dx = points[k].x - points[j].x;
            if (@abs(dx) <= 1.0) continue;
            slopes[slope_count] = (points[k].y - points[j].y) / dx;
            slope_count += 1;
        }
    }
    if (slope_count == 0) return null;
    const values = slopes[0..slope_count];
    std.sort.pdq(f64, values, {}, lessThanF64);
    const median_slope = medianSortedF64(values);
    const unclamped = std.math.atan(median_slope);
    return .{
        .median_slope = median_slope,
        .angle = @max(-max_angle_rad, @min(max_angle_rad, unclamped)),
    };
}

pub fn singleFrameFallback(frame_count: usize, frame: FrameRect, preview_width: f64, preview_height: f64) !?FrameRect {
    if (!std.math.isFinite(preview_width) or !std.math.isFinite(preview_height) or preview_width <= 0.0 or preview_height <= 0.0) {
        return error.InvalidSingleFrameFallbackInput;
    }
    if (frame_count != 1) return null;
    const area_ratio = (frame.w * frame.h) / (preview_width * preview_height);
    if (area_ratio < 0.3) {
        return .{
            .cx = preview_width / 2.0,
            .cy = preview_height / 2.0,
            .w = preview_width,
            .h = preview_height,
            .angle = 0.0,
        };
    }
    return null;
}

pub fn computePreviewGeometry(full_width: usize, full_height: usize, preview_size: usize) !PreviewGeometry {
    if (full_width == 0 or full_height == 0) return error.InvalidPreviewGeometry;
    const max_dim = @max(full_width, full_height);
    const preview_scale = if (preview_size > 0)
        @min(@as(f64, @floatFromInt(preview_size)) / @as(f64, @floatFromInt(max_dim)), 1.0)
    else
        1.0;
    const preview_width = if (preview_scale < 1.0)
        @as(usize, @intFromFloat(@as(f64, @floatFromInt(full_width)) * preview_scale))
    else
        full_width;
    const preview_height = if (preview_scale < 1.0)
        @as(usize, @intFromFloat(@as(f64, @floatFromInt(full_height)) * preview_scale))
    else
        full_height;
    if (preview_width == 0 or preview_height == 0) return error.InvalidPreviewGeometry;
    return .{
        .full_width = full_width,
        .full_height = full_height,
        .preview_width = preview_width,
        .preview_height = preview_height,
        .preview_scale = preview_scale,
    };
}

pub fn previewFrameToFullResolution(frame: FrameRect, preview_scale: f64) !FrameRect {
    try validatePreviewScale(preview_scale);
    return .{
        .cx = frame.cx / preview_scale,
        .cy = frame.cy / preview_scale,
        .w = frame.w / preview_scale,
        .h = frame.h / preview_scale,
        .angle = frame.angle,
    };
}

pub fn previewSelectionToFullResolution(selection: PreviewSelection, preview_scale: f64) !FrameRect {
    try validatePreviewScale(preview_scale);
    return .{
        .cx = (selection.x + selection.w / 2.0) / preview_scale,
        .cy = (selection.y + selection.h / 2.0) / preview_scale,
        .w = selection.w / preview_scale,
        .h = selection.h / preview_scale,
        .angle = selection.angle,
    };
}

pub fn previewRebateToFullResolution(rect: RebateOriginRect, preview_scale: f64) !RebateOriginRect {
    try validatePreviewScale(preview_scale);
    return .{
        .x = rect.x / preview_scale,
        .y = rect.y / preview_scale,
        .w = rect.w / preview_scale,
        .h = rect.h / preview_scale,
        .angle = rect.angle,
    };
}

pub fn frameRmsError(detected_full: FrameRect, ground_truth_full: FrameRect) f64 {
    const dx = detected_full.cx - ground_truth_full.cx;
    const dy = detected_full.cy - ground_truth_full.cy;
    const dw = detected_full.w - ground_truth_full.w;
    const dh = detected_full.h - ground_truth_full.h;
    return @sqrt(dx * dx + dy * dy + dw * dw + dh * dh);
}

pub fn frameAngleErrorRadians(detected_angle: f64, ground_truth_angle: f64) f64 {
    return detected_angle - ground_truth_angle;
}

pub fn makeRebateMask(
    allocator: std.mem.Allocator,
    height: usize,
    width: usize,
    rect: ?RebateMaskRect,
) !?[]bool {
    if (height == 0 or width == 0) return error.InvalidRebateMaskInput;
    const rebate = rect orelse return null;
    if (rebate.width <= 0.0) return null;

    const mask = try allocator.alloc(bool, height * width);
    errdefer allocator.free(mask);
    @memset(mask, false);

    var x0: i64 = @intFromFloat(rebate.x);
    var y0: i64 = @intFromFloat(rebate.y);
    var x1: i64 = x0 + @as(i64, @intFromFloat(rebate.width));
    var y1: i64 = y0 + @as(i64, @intFromFloat(rebate.height));
    x0 = @max(0, x0);
    y0 = @max(0, y0);
    x1 = @min(@as(i64, @intCast(width)), x1);
    y1 = @min(@as(i64, @intCast(height)), y1);
    if (x1 > x0 and y1 > y0) {
        for (@as(usize, @intCast(y0))..@as(usize, @intCast(y1))) |y| {
            for (@as(usize, @intCast(x0))..@as(usize, @intCast(x1))) |x| {
                mask[y * width + x] = true;
            }
        }
    }
    return mask;
}

pub fn rebateInBounds(image_width: usize, image_height: usize, rect: RebateOriginRect) bool {
    const cx = rect.x + rect.w / 2.0;
    const cy = rect.y + rect.h / 2.0;
    return cx >= 0.0 and cy >= 0.0 and cx < @as(f64, @floatFromInt(image_width)) and cy < @as(f64, @floatFromInt(image_height));
}

pub fn extractRebatePixels(
    allocator: std.mem.Allocator,
    image: []const f64,
    image_width: usize,
    image_height: usize,
    rect: RebateOriginRect,
) !RotatedCrop {
    const cx = rect.x + rect.w / 2.0;
    const cy = rect.y + rect.h / 2.0;
    return cropRotatedRect(
        allocator,
        image,
        image_width,
        image_height,
        cx,
        cy,
        rect.w,
        rect.h,
        rect.angle * 180.0 / std.math.pi,
    );
}

pub fn computeInterFrameRebate(frames: []const FrameRect) ?RebateRect {
    if (frames.len < 2) return null;
    const gap_idx = (frames.len - 1) / 2;
    const f0 = frames[gap_idx];
    const f1 = frames[gap_idx + 1];
    const dcx = f1.cx - f0.cx;
    const dcy = f1.cy - f0.cy;
    const is_vertical = @abs(dcy) > @abs(dcx);
    const gap_cx = (f0.cx + f1.cx) / 2.0;
    const gap_cy = (f0.cy + f1.cy) / 2.0;
    const pitch = @sqrt(dcx * dcx + dcy * dcy);
    const f_strip_dim = if (is_vertical) (f0.h + f1.h) / 2.0 else (f0.w + f1.w) / 2.0;
    const f_cross_dim = if (is_vertical) (f0.w + f1.w) / 2.0 else (f0.h + f1.h) / 2.0;
    const gap_strip_size = pitch - f_strip_dim;
    if (gap_strip_size <= 0.0) return null;

    const strip_margin = @max(gap_strip_size * 0.2, 2.0);
    const cross_margin = f_cross_dim * 0.1;
    const rebate_strip_dim = @max(gap_strip_size - 2.0 * strip_margin, 1.0);
    const rebate_cross_dim = @max(f_cross_dim - 2.0 * cross_margin, 1.0);
    const angle = (f0.angle + f1.angle) / 2.0;

    return if (is_vertical)
        .{ .cx = gap_cx, .cy = gap_cy, .w = rebate_cross_dim, .h = rebate_strip_dim, .angle = angle }
    else
        .{ .cx = gap_cx, .cy = gap_cy, .w = rebate_strip_dim, .h = rebate_cross_dim, .angle = angle };
}

const Band = struct {
    start: usize,
    end: usize,
};

const AreaWeight = struct {
    index: usize,
    weight: f64,
};

const AreaWeights = struct {
    offsets: []usize,
    weights: []AreaWeight,

    fn deinit(self: *AreaWeights, allocator: std.mem.Allocator) void {
        allocator.free(self.offsets);
        allocator.free(self.weights);
        self.* = undefined;
    }

    fn forOutput(self: AreaWeights, output_index: usize) []const AreaWeight {
        return self.weights[self.offsets[output_index]..self.offsets[output_index + 1]];
    }
};

fn profileBand(cross_dim: usize, band_width: usize, fraction: f64) !Band {
    const center: usize = @intFromFloat(@as(f64, @floatFromInt(cross_dim)) * fraction);
    const half = band_width / 2;
    if (center < half) return error.InvalidFrameProfileBand;
    const start = center - half;
    const end = center + half;
    if (end <= start or end > cross_dim) return error.InvalidFrameProfileBand;
    return .{ .start = start, .end = end };
}

fn buildAreaWeights(allocator: std.mem.Allocator, source_len: usize, target_len: usize) !AreaWeights {
    if (source_len == 0 or target_len == 0 or target_len > source_len) return error.InvalidAreaResizeInput;
    const offsets = try allocator.alloc(usize, target_len + 1);
    errdefer allocator.free(offsets);
    var weights: std.ArrayList(AreaWeight) = .empty;
    errdefer weights.deinit(allocator);
    const scale = @as(f64, @floatFromInt(source_len)) / @as(f64, @floatFromInt(target_len));
    for (0..target_len) |out_index| {
        offsets[out_index] = weights.items.len;
        const start = @as(f64, @floatFromInt(out_index)) * scale;
        const end = @as(f64, @floatFromInt(out_index + 1)) * scale;
        const first: usize = @intFromFloat(@floor(start));
        const last_exclusive: usize = @min(source_len, @as(usize, @intFromFloat(@ceil(end))));
        for (first..last_exclusive) |source_index| {
            const source_start = @as(f64, @floatFromInt(source_index));
            const source_end = source_start + 1.0;
            const overlap = @min(end, source_end) - @max(start, source_start);
            if (overlap > 0.0) {
                try weights.append(allocator, .{ .index = source_index, .weight = overlap / scale });
            }
        }
    }
    offsets[target_len] = weights.items.len;
    return .{ .offsets = offsets, .weights = try weights.toOwnedSlice(allocator) };
}

fn computeBandProfile(
    gray: []const f64,
    width: usize,
    height: usize,
    is_vertical: bool,
    band: Band,
    output: []f64,
) !void {
    const count = band.end - band.start;
    if (count == 0) return error.InvalidFrameProfileBand;

    if (is_vertical) {
        if (output.len != height) return error.InvalidFrameProfileBuffer;
        for (0..height) |y| {
            var sum: f64 = 0.0;
            for (band.start..band.end) |x| {
                sum += gray[y * width + x];
            }
            output[y] = sum / @as(f64, @floatFromInt(count));
        }
    } else {
        if (output.len != width) return error.InvalidFrameProfileBuffer;
        for (0..width) |x| {
            var sum: f64 = 0.0;
            for (band.start..band.end) |y| {
                sum += gray[y * width + x];
            }
            output[x] = sum / @as(f64, @floatFromInt(count));
        }
    }
}

fn computeVerticalStripProfilesSegmented(
    gray: []const f64,
    width: usize,
    height: usize,
    bands: [3]Band,
    result: *StripProfiles,
) !void {
    if (result.profile_a.len != height or result.profile_b.len != height or result.profile_c.len != height or result.cross_profile.len != width) {
        return error.InvalidFrameProfileBuffer;
    }
    const count_a = bands[0].end - bands[0].start;
    const count_b = bands[1].end - bands[1].start;
    const count_c = bands[2].end - bands[2].start;
    if (count_a == 0 or count_b == 0 or count_c == 0) return error.InvalidFrameProfileBand;

    @memset(result.cross_profile, 0.0);
    const denom_a = @as(f64, @floatFromInt(count_a));
    const denom_b = @as(f64, @floatFromInt(count_b));
    const denom_c = @as(f64, @floatFromInt(count_c));
    for (0..height) |y| {
        const row = gray[y * width ..][0..width];
        var sum_a: f64 = 0.0;
        var sum_b: f64 = 0.0;
        var sum_c: f64 = 0.0;

        var x: usize = 0;
        while (x < bands[0].start) : (x += 1) {
            result.cross_profile[x] += row[x];
        }
        while (x < bands[0].end) : (x += 1) {
            const value = row[x];
            result.cross_profile[x] += value;
            sum_a += value;
        }
        while (x < bands[1].start) : (x += 1) {
            result.cross_profile[x] += row[x];
        }
        while (x < bands[1].end) : (x += 1) {
            const value = row[x];
            result.cross_profile[x] += value;
            sum_b += value;
        }
        while (x < bands[2].start) : (x += 1) {
            result.cross_profile[x] += row[x];
        }
        while (x < bands[2].end) : (x += 1) {
            const value = row[x];
            result.cross_profile[x] += value;
            sum_c += value;
        }
        while (x < width) : (x += 1) {
            result.cross_profile[x] += row[x];
        }

        result.profile_a[y] = sum_a / denom_a;
        result.profile_b[y] = sum_b / denom_b;
        result.profile_c[y] = sum_c / denom_c;
    }
    const inv_height = 1.0 / @as(f64, @floatFromInt(height));
    for (result.cross_profile) |*value| {
        value.* *= inv_height;
    }
}

fn computeCrossProfile(
    gray: []const f64,
    width: usize,
    height: usize,
    is_vertical: bool,
    output: []f64,
) !void {
    if (is_vertical) {
        if (output.len != width) return error.InvalidFrameProfileBuffer;
        @memset(output, 0.0);
        for (0..height) |y| {
            const row = gray[y * width ..][0..width];
            for (row, output) |value, *sum| {
                sum.* += value;
            }
        }
        const inv_height = 1.0 / @as(f64, @floatFromInt(height));
        for (output) |*value| {
            value.* *= inv_height;
        }
    } else {
        if (output.len != height) return error.InvalidFrameProfileBuffer;
        for (0..height) |y| {
            var sum: f64 = 0.0;
            for (0..width) |x| {
                sum += gray[y * width + x];
            }
            output[y] = sum / @as(f64, @floatFromInt(width));
        }
    }
}

fn gaussianBlur1dInPlace(allocator: std.mem.Allocator, values: []f64) !void {
    if (values.len == 0) return error.InvalidFrameProfileBuffer;
    try gaussianBlur1dInPlaceWithKernel(allocator, values, profileBlurKernelSize(values.len));
}

fn gaussianBlur1dInPlaceWithKernel(allocator: std.mem.Allocator, values: []f64, kernel_size: usize) !void {
    if (values.len == 0 or kernel_size == 0 or kernel_size % 2 == 0) return error.InvalidFrameProfileBuffer;
    const kernel = try gaussianKernel(allocator, kernel_size);
    defer allocator.free(kernel);
    const input = try allocator.dupe(f64, values);
    defer allocator.free(input);
    try gaussianBlur1dTo(input, values, kernel);
}

fn gaussianBlur1dTo(input: []const f64, output: []f64, kernel: []const f64) !void {
    if (input.len == 0 or input.len != output.len or kernel.len == 0 or kernel.len % 2 == 0) return error.InvalidFrameProfileBuffer;
    const radius = kernel.len / 2;
    const left_end = @min(input.len, radius);
    const right_start = if (input.len > radius) input.len - radius else input.len;
    for (0..left_end) |index| {
        output[index] = gaussianBlur1dEdgeValue(input, kernel, index, radius);
    }
    if (right_start > left_end) {
        for (left_end..right_start) |index| {
            output[index] = gaussianBlur1dInteriorValueSimd(input, kernel, index - radius);
        }
    }
    for (right_start..input.len) |index| {
        output[index] = gaussianBlur1dEdgeValue(input, kernel, index, radius);
    }
}

fn gaussianBlur1dInteriorValueSimd(input: []const f64, kernel: []const f64, source_start: usize) f64 {
    const VecF64 = @Vector(f64_simd_width, f64);
    var accumulator: VecF64 = @splat(0.0);
    var k: usize = 0;
    while (k + f64_simd_width <= kernel.len) : (k += f64_simd_width) {
        const values: VecF64 = .{
            input[source_start + k],
            input[source_start + k + 1],
            input[source_start + k + 2],
            input[source_start + k + 3],
        };
        const weights: VecF64 = .{
            kernel[k],
            kernel[k + 1],
            kernel[k + 2],
            kernel[k + 3],
        };
        accumulator += values * weights;
    }
    var sum = @reduce(.Add, accumulator);
    while (k < kernel.len) : (k += 1) {
        sum += input[source_start + k] * kernel[k];
    }
    return sum;
}

fn gaussianBlur1dEdgeValue(input: []const f64, kernel: []const f64, index: usize, radius: usize) f64 {
    var sum: f64 = 0.0;
    const index_i32: i32 = @intCast(index);
    const radius_i32: i32 = @intCast(radius);
    for (kernel, 0..) |weight, k| {
        const offset = @as(i32, @intCast(k)) - radius_i32;
        const source = reflect101Index(index_i32 + offset, input.len);
        sum += input[source] * weight;
    }
    return sum;
}

fn gaussianBlur1dInPlacePrepared(values: []f64, scratch: []f64, kernel: []const f64) !void {
    if (scratch.len < values.len) return error.InvalidFrameProfileBuffer;
    const output = scratch[0..values.len];
    try gaussianBlur1dTo(values, output, kernel);
    @memcpy(values, output);
}

fn profileBlurKernelSize(len: usize) usize {
    var kernel_size = @max(@as(usize, 3), len / 100);
    kernel_size |= 1;
    return kernel_size;
}

fn gradientBlurKernelSize(len: usize) usize {
    var kernel_size = @max(@as(usize, 3), len / 200);
    kernel_size |= 1;
    return kernel_size;
}

fn computeAbsGradientBlurred(allocator: std.mem.Allocator, profile: []const f64) ![]f64 {
    if (profile.len == 0) return error.InvalidDetectFramesInput;
    const gradient = try allocator.alloc(f64, profile.len);
    errdefer allocator.free(gradient);
    if (profile.len == 1) {
        gradient[0] = 0.0;
        return gradient;
    }
    gradient[0] = 0.0;
    for (1..profile.len - 1) |index| {
        gradient[index] = @abs((profile[index + 1] - profile[index - 1]) / 2.0);
    }
    gradient[profile.len - 1] = 0.0;
    try gaussianBlur1dInPlaceWithKernel(allocator, gradient, gradientBlurKernelSize(profile.len));
    return gradient;
}

fn computeAbsGradient(profile: []const f64, output: []f64) void {
    if (profile.len == 1) {
        output[0] = 0.0;
        return;
    }
    output[0] = 0.0;
    for (1..profile.len - 1) |index| {
        output[index] = @abs((profile[index + 1] - profile[index - 1]) / 2.0);
    }
    output[profile.len - 1] = 0.0;
}

fn averageGradients(allocator: std.mem.Allocator, a: []const f64, b: []const f64, c: []const f64) ![]f64 {
    if (a.len == 0 or a.len != b.len or a.len != c.len) return error.InvalidDetectFramesInput;
    const out = try allocator.alloc(f64, a.len);
    errdefer allocator.free(out);
    for (out, a, b, c) |*value, av, bv, cv| {
        value.* = (av + bv + cv) / 3.0;
    }
    return out;
}

const AngleGradientSet = struct {
    gradients: [][]f64,
    positions: []f64,
    gradient_storage: ?[]f64 = null,

    fn deinit(self: *AngleGradientSet, allocator: std.mem.Allocator) void {
        if (self.gradient_storage) |storage| {
            allocator.free(storage);
        } else {
            for (self.gradients) |gradient| {
                allocator.free(gradient);
            }
        }
        allocator.free(self.gradients);
        allocator.free(self.positions);
        self.* = undefined;
    }
};

fn estimateFrameAnglesAxisAligned(
    allocator: std.mem.Allocator,
    gray: []const f64,
    width: usize,
    height: usize,
    strip_info: StripAnalysis,
    frame_strip_dim: f64,
    edge_positions: []const usize,
    frames: []FrameRect,
) !void {
    if (gray.len != width * height or edge_positions.len != strip_info.n_frames * 2 or frames.len != strip_info.n_frames) {
        return error.InvalidDetectFramesInput;
    }
    if (!std.math.isFinite(frame_strip_dim) or frame_strip_dim <= 0.0) return error.InvalidDetectFramesInput;

    var angle_set = try computeAngleGradientSet(allocator, gray, width, height, strip_info.is_vertical);
    defer angle_set.deinit(allocator);

    const search_r = @max(@as(usize, 5), @as(usize, @intFromFloat(frame_strip_dim * 0.025)));
    const max_angle = 5.0 * std.math.pi / 180.0;
    const points = try allocator.alloc(EdgePeakPoint, angle_set.gradients.len * 2);
    defer allocator.free(points);

    for (frames, 0..) |*frame, frame_index| {
        var edge_indices = [_]usize{ 2 * frame_index, 2 * frame_index + 1 };
        var edge_count: usize = 2;
        if (strip_info.n_frames >= 3) {
            if (frame_index == 0) {
                edge_indices[0] = 2 * frame_index + 1;
                edge_count = 1;
            } else if (frame_index == strip_info.n_frames - 1) {
                edge_indices[0] = 2 * frame_index;
                edge_count = 1;
            }
        }

        var point_count: usize = 0;
        for (edge_indices[0..edge_count]) |edge_index| {
            if (edge_index >= edge_positions.len) continue;
            const pos = edge_positions[edge_index];
            const gradient_len = angle_set.gradients[0].len;
            const lo = if (pos > search_r) pos - search_r else 0;
            const hi = @min(gradient_len, pos + search_r + 1);
            if (hi <= lo) continue;

            for (angle_set.gradients, angle_set.positions) |gradient, x_position| {
                points[point_count] = .{
                    .x = x_position,
                    .y = subpixelPeak(gradient, lo, hi),
                };
                point_count += 1;
            }
        }

        if (point_count >= 4) {
            if (try estimateAngleTheilSen(allocator, points[0..point_count], max_angle)) |angle| {
                frame.angle = angle.angle;
            }
        }
    }
}

fn computeAngleGradientSet(
    allocator: std.mem.Allocator,
    gray: []const f64,
    width: usize,
    height: usize,
    is_vertical: bool,
) !AngleGradientSet {
    if (width == 0 or height == 0 or gray.len != width * height) return error.InvalidDetectFramesInput;
    const strip_len = if (is_vertical) height else width;
    const cross_dim = if (is_vertical) width else height;
    if (strip_len < 3 or cross_dim == 0) return error.InvalidDetectFramesInput;

    const angle_strip_count: usize = 20;
    const gradients = try allocator.alloc([]f64, angle_strip_count);
    errdefer allocator.free(gradients);
    const gradient_storage = try allocator.alloc(f64, angle_strip_count * strip_len);
    errdefer allocator.free(gradient_storage);
    const positions = try allocator.alloc(f64, angle_strip_count);
    errdefer allocator.free(positions);
    const profile_storage = try allocator.alloc(f64, angle_strip_count * strip_len);
    defer allocator.free(profile_storage);
    const scratch_storage = try allocator.alloc(f64, angle_strip_count * strip_len);
    defer allocator.free(scratch_storage);
    const profile_kernel = try gaussianKernel(allocator, profileBlurKernelSize(strip_len));
    defer allocator.free(profile_kernel);
    const gradient_kernel = try gaussianKernel(allocator, gradientBlurKernelSize(strip_len));
    defer allocator.free(gradient_kernel);

    const angle_band_width = @max(@as(usize, 1), cross_dim / 20);
    const half_band = angle_band_width / 2;
    const work_items = angle_strip_count * strip_len * angle_band_width;
    const worker_count = workerCountForItems(work_items, angle_gradient_parallel_min_work);
    if (parallelism.enabled and worker_count > 1) {
        try computeAngleGradientSetParallel(
            allocator,
            gray,
            width,
            height,
            is_vertical,
            strip_len,
            cross_dim,
            angle_band_width,
            half_band,
            profile_storage,
            scratch_storage,
            gradient_storage,
            gradients,
            positions,
            profile_kernel,
            gradient_kernel,
            @min(worker_count, angle_strip_count),
        );
    } else {
        computeAngleGradientStrips(.{
            .gray = gray,
            .width = width,
            .height = height,
            .is_vertical = is_vertical,
            .strip_len = strip_len,
            .cross_dim = cross_dim,
            .angle_band_width = angle_band_width,
            .half_band = half_band,
            .profile_storage = profile_storage,
            .scratch_storage = scratch_storage,
            .gradient_storage = gradient_storage,
            .gradients = gradients,
            .positions = positions,
            .profile_kernel = profile_kernel,
            .gradient_kernel = gradient_kernel,
            .strip_start = 0,
            .strip_end = angle_strip_count,
        });
    }

    return .{ .gradients = gradients, .positions = positions, .gradient_storage = gradient_storage };
}

fn computeAngleGradientSetParallel(
    allocator: std.mem.Allocator,
    gray: []const f64,
    width: usize,
    height: usize,
    is_vertical: bool,
    strip_len: usize,
    cross_dim: usize,
    angle_band_width: usize,
    half_band: usize,
    profile_storage: []f64,
    scratch_storage: []f64,
    gradient_storage: []f64,
    gradients: [][]f64,
    positions: []f64,
    profile_kernel: []const f64,
    gradient_kernel: []const f64,
    worker_count: usize,
) !void {
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(AngleGradientStripsContext, worker_count);
    defer allocator.free(contexts);
    var started: usize = 0;
    errdefer {
        for (threads[0..started]) |thread| {
            thread.join();
        }
    }
    for (0..worker_count) |worker_index| {
        const strip_start = gradients.len * worker_index / worker_count;
        const strip_end = gradients.len * (worker_index + 1) / worker_count;
        contexts[worker_index] = .{
            .gray = gray,
            .width = width,
            .height = height,
            .is_vertical = is_vertical,
            .strip_len = strip_len,
            .cross_dim = cross_dim,
            .angle_band_width = angle_band_width,
            .half_band = half_band,
            .profile_storage = profile_storage,
            .scratch_storage = scratch_storage,
            .gradient_storage = gradient_storage,
            .gradients = gradients,
            .positions = positions,
            .profile_kernel = profile_kernel,
            .gradient_kernel = gradient_kernel,
            .strip_start = strip_start,
            .strip_end = strip_end,
        };
        threads[worker_index] = try std.Thread.spawn(.{}, computeAngleGradientStripsWorker, .{&contexts[worker_index]});
        started += 1;
    }
    for (threads) |thread| {
        thread.join();
    }
}

fn computeAngleGradientStripsWorker(context: *const AngleGradientStripsContext) void {
    computeAngleGradientStrips(context.*);
}

fn computeAngleGradientStrips(context: AngleGradientStripsContext) void {
    for (context.strip_start..context.strip_end) |strip_index| {
        const profile = context.profile_storage[strip_index * context.strip_len ..][0..context.strip_len];
        const scratch = context.scratch_storage[strip_index * context.strip_len ..][0..context.strip_len];
        const fraction = 0.20 + 0.60 * @as(f64, @floatFromInt(strip_index)) / @as(f64, @floatFromInt(context.gradients.len - 1));
        var center: usize = @intFromFloat(@as(f64, @floatFromInt(context.cross_dim)) * fraction);
        center = @min(center, context.cross_dim - 1);
        var start = if (center > context.half_band) center - context.half_band else 0;
        var end = @min(context.cross_dim, center + context.half_band);
        if (end <= start) {
            end = @min(context.cross_dim, start + 1);
        }
        if (end <= start and start > 0) {
            start -= 1;
        }
        const count = end - start;
        std.debug.assert(count > 0);

        if (context.is_vertical) {
            for (0..context.height) |y| {
                var sum: f64 = 0.0;
                for (start..end) |x| {
                    sum += context.gray[y * context.width + x];
                }
                profile[y] = sum / @as(f64, @floatFromInt(count));
            }
        } else {
            for (0..context.width) |x| {
                var sum: f64 = 0.0;
                for (start..end) |y| {
                    sum += context.gray[y * context.width + x];
                }
                profile[x] = sum / @as(f64, @floatFromInt(count));
            }
        }

        gaussianBlur1dTo(profile, scratch, context.profile_kernel) catch unreachable;
        context.gradients[strip_index] = context.gradient_storage[strip_index * context.strip_len ..][0..context.strip_len];
        computeAbsGradient(scratch, context.gradients[strip_index]);
        gaussianBlur1dTo(context.gradients[strip_index], scratch, context.gradient_kernel) catch unreachable;
        @memcpy(context.gradients[strip_index], scratch);
        context.positions[strip_index] = @floatFromInt(center);
    }
}

fn framesFromStripEdges(
    allocator: std.mem.Allocator,
    edge_positions: []const usize,
    width: usize,
    height: usize,
    format: FilmFormat,
    strip_info: StripAnalysis,
    angle: f64,
) ![]FrameRect {
    if (edge_positions.len != strip_info.n_frames * 2) return error.InvalidDetectFramesInput;
    const frames = try allocator.alloc(FrameRect, strip_info.n_frames);
    errdefer allocator.free(frames);
    const cross_center = if (strip_info.is_vertical)
        @as(f64, @floatFromInt(width)) / 2.0
    else
        @as(f64, @floatFromInt(height)) / 2.0;
    const narrow_mm = format.narrowMm();
    const wide_mm = format.wideMm();
    for (frames, 0..) |*frame, frame_index| {
        const e_start = edge_positions[2 * frame_index];
        const e_end = edge_positions[2 * frame_index + 1];
        if (e_end <= e_start) return error.InvalidDetectFramesInput;
        const strip_center = (@as(f64, @floatFromInt(e_start)) + @as(f64, @floatFromInt(e_end))) / 2.0;
        const strip_dim = @as(f64, @floatFromInt(e_end - e_start));
        const cross_dim = strip_dim * narrow_mm / wide_mm;
        frame.* = if (strip_info.is_vertical)
            .{ .cx = cross_center, .cy = strip_center, .w = cross_dim, .h = strip_dim, .angle = angle }
        else
            .{ .cx = strip_center, .cy = cross_center, .w = strip_dim, .h = cross_dim, .angle = angle };
    }
    return frames;
}

fn refineCrossStripAxisAligned(
    allocator: std.mem.Allocator,
    gray: []const f64,
    width: usize,
    height: usize,
    format: FilmFormat,
    strip_info: StripAnalysis,
    frames: []FrameRect,
) !void {
    if (gray.len != width * height or frames.len != strip_info.n_frames) return error.InvalidDetectFramesInput;
    const line_len = if (strip_info.is_vertical) width else height;
    if (line_len < 3) return error.InvalidDetectFramesInput;

    const narrow_mm = format.narrowMm();
    const wide_mm = format.wideMm();
    const cross_search_r = @max(@as(usize, 3), @as(usize, @intFromFloat(@as(f64, @floatFromInt(line_len)) * 0.04)));
    const sample_count: usize = 15;
    const margin_frac = 0.2;

    const line = try allocator.alloc(f64, line_len);
    defer allocator.free(line);
    const left_edges = try allocator.alloc(f64, sample_count);
    defer allocator.free(left_edges);
    const right_edges = try allocator.alloc(f64, sample_count);
    defer allocator.free(right_edges);

    for (frames) |*frame| {
        const cx = frame.cx;
        const cy = frame.cy;
        const angle = frame.angle;
        const cos_a = std.math.cos(angle);
        const sin_a = std.math.sin(angle);
        const strip_dim = if (strip_info.is_vertical) frame.h else frame.w;
        if (!std.math.isFinite(strip_dim) or strip_dim <= 0.0) continue;
        const cross_dim_est = strip_dim * narrow_mm / wide_mm;
        const start_offset = -strip_dim / 2.0 * (1.0 - margin_frac);
        const end_offset = strip_dim / 2.0 * (1.0 - margin_frac);
        var edge_count: usize = 0;

        for (0..sample_count) |sample_index| {
            const fraction = if (sample_count == 1)
                0.0
            else
                @as(f64, @floatFromInt(sample_index)) / @as(f64, @floatFromInt(sample_count - 1));
            const offset = start_offset + (end_offset - start_offset) * fraction;
            const center_t = @as(f64, @floatFromInt(line_len - 1)) / 2.0;
            var valid_count: usize = 0;
            if (strip_info.is_vertical) {
                const sample_y = cy + offset * cos_a;
                const sample_x_base = cx + offset * sin_a;
                for (line, 0..) |*value, index| {
                    const t = @as(f64, @floatFromInt(index)) - center_t;
                    const x = sample_x_base + t * cos_a;
                    const y = sample_y - t * sin_a;
                    if (isValidBilinearCoordinate(x, y, width, height)) valid_count += 1;
                    value.* = sampleInvertedConstantBilinear(gray, width, height, x, y);
                }
            } else {
                const sample_x_base = cx + offset * cos_a;
                const sample_y = cy + offset * sin_a;
                for (line, 0..) |*value, index| {
                    const t = @as(f64, @floatFromInt(index)) - center_t;
                    const x = sample_x_base - t * sin_a;
                    const y = sample_y + t * cos_a;
                    if (isValidBilinearCoordinate(x, y, width, height)) valid_count += 1;
                    value.* = sampleInvertedConstantBilinear(gray, width, height, x, y);
                }
            }
            if (@as(f64, @floatFromInt(valid_count)) < @as(f64, @floatFromInt(line_len)) * 0.5) continue;

            var gradient = try signedGradientForCrossLine(allocator, line);
            defer gradient.deinit(allocator);
            if (try measureCrossStripEdges(allocator, gradient.values, cross_dim_est, cross_search_r)) |measurement| {
                if (measurement.cross_w > 0.0 and edge_count < sample_count) {
                    left_edges[edge_count] = measurement.left_t;
                    right_edges[edge_count] = measurement.right_t;
                    edge_count += 1;
                }
            }
        }

        if (edge_count == 0) continue;
        const left_offset = try medianF64(allocator, left_edges[0..edge_count]);
        const right_offset = try medianF64(allocator, right_edges[0..edge_count]);
        const cross_w = right_offset - left_offset;
        const cross_center_offset = (left_offset + right_offset) / 2.0;
        if (cross_w <= 0.0) continue;
        if (strip_info.is_vertical) {
            frame.cx = cx + cross_center_offset * cos_a;
            frame.w = cross_w;
        } else {
            frame.cy = cy + cross_center_offset * cos_a;
            frame.h = cross_w;
        }
    }
}

const CrossLineGradient = struct {
    values: []f64,

    fn deinit(self: *CrossLineGradient, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
        self.* = undefined;
    }
};

fn signedGradientForCrossLine(allocator: std.mem.Allocator, line: []const f64) !CrossLineGradient {
    if (line.len < 3) return error.InvalidDetectFramesInput;
    const smoothed = try allocator.dupe(f64, line);
    defer allocator.free(smoothed);
    var smooth_kernel = @max(@as(usize, 3), line.len / 50);
    smooth_kernel |= 1;
    try gaussianBlur1dInPlaceWithKernel(allocator, smoothed, smooth_kernel);

    const gradient = try allocator.alloc(f64, line.len);
    errdefer allocator.free(gradient);
    @memset(gradient, 0.0);
    if (line.len > 4) {
        for (2..line.len - 2) |index| {
            gradient[index] = (smoothed[index + 1] - smoothed[index - 1]) / 2.0;
        }
    }
    return .{ .values = gradient };
}

fn medianF64(allocator: std.mem.Allocator, values: []const f64) !f64 {
    if (values.len == 0) return error.InvalidDetectFramesInput;
    const sorted = try allocator.dupe(f64, values);
    defer allocator.free(sorted);
    std.sort.pdq(f64, sorted, {}, lessThanF64);
    return medianSortedF64(sorted);
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
    var total: f64 = 0.0;
    for (kernel, 0..) |*weight, index| {
        const x = @as(f64, @floatFromInt(index)) - half;
        weight.* = std.math.exp(-(x * x) / (2.0 * sigma * sigma));
        total += weight.*;
    }
    for (kernel) |*weight| {
        weight.* /= total;
    }
    return kernel;
}

const dtw_inf: f64 = 1e18;

const DtwParent = struct {
    i: usize = 0,
    j: usize = 0,
};

fn dtwIndex(i: usize, j: usize, columns: usize) usize {
    return i * columns + j;
}

fn resizeArea1d(allocator: std.mem.Allocator, input: []const f64, output_len: usize) ![]f64 {
    if (input.len == 0 or output_len == 0) return error.InvalidDtwInput;
    const output = try allocator.alloc(f64, output_len);
    errdefer allocator.free(output);
    const scale = @as(f64, @floatFromInt(output_len)) / @as(f64, @floatFromInt(input.len));
    for (output, 0..) |*out, out_index| {
        const start = @as(f64, @floatFromInt(out_index)) / scale;
        const end = @as(f64, @floatFromInt(out_index + 1)) / scale;
        const first: usize = @intFromFloat(@floor(start));
        const last_exclusive: usize = @min(input.len, @as(usize, @intFromFloat(@ceil(end))));
        var total: f64 = 0.0;
        var weight_total: f64 = 0.0;
        for (first..last_exclusive) |source| {
            const source_start = @as(f64, @floatFromInt(source));
            const source_end = source_start + 1.0;
            const weight = @max(0.0, @min(end, source_end) - @max(start, source_start));
            total += input[source] * weight;
            weight_total += weight;
        }
        out.* = if (weight_total > 0.0) total / weight_total else input[@min(first, input.len - 1)];
    }
    return output;
}

fn normalizeMax(values: []f64) void {
    var max_value: f64 = 0.0;
    for (values) |value| {
        max_value = @max(max_value, value);
    }
    if (max_value <= 0.0) return;
    for (values) |*value| {
        value.* /= max_value;
    }
}

fn buildDtwTemplate(allocator: std.mem.Allocator, frame_count: usize, frame_dim: usize, gap: usize) ![]f64 {
    const len = frame_count * (frame_dim + 2) + if (frame_count > 0) (frame_count - 1) * gap else 0;
    const template = try allocator.alloc(f64, len);
    errdefer allocator.free(template);
    var index: usize = 0;
    for (0..frame_count) |frame_index| {
        template[index] = 1.0;
        index += 1;
        @memset(template[index .. index + frame_dim], 0.0);
        index += frame_dim;
        template[index] = 1.0;
        index += 1;
        if (frame_index < frame_count - 1) {
            @memset(template[index .. index + gap], 0.0);
            index += gap;
        }
    }
    return template;
}

fn nearestAlignedIndex(alignment: []const ?usize, target: usize) !usize {
    var best_distance: usize = std.math.maxInt(usize);
    var best_value: ?usize = null;
    for (alignment, 0..) |maybe_value, index| {
        const value = maybe_value orelse continue;
        const distance = if (index > target) index - target else target - index;
        if (distance < best_distance) {
            best_distance = distance;
            best_value = value;
        }
    }
    return best_value orelse error.InvalidDtwAlignment;
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn grayToU8(value: f64) u8 {
    if (!std.math.isFinite(value) or value <= 0.0) return 0;
    if (value >= 1.0) return 255;
    return @intFromFloat(@floor(value * 255.0 + 0.5));
}

fn otsuThreshold(raw_gray: []const f64) u8 {
    var hist = [_]usize{0} ** 256;
    for (raw_gray) |value| {
        hist[grayToU8(value)] += 1;
    }
    return otsuThresholdFromHist(hist);
}

fn otsuThresholdU8(raw_gray: []const u8) u8 {
    var hist0 = [_]usize{0} ** 256;
    var hist1 = [_]usize{0} ** 256;
    var hist2 = [_]usize{0} ** 256;
    var hist3 = [_]usize{0} ** 256;
    var index: usize = 0;
    while (index + 4 <= raw_gray.len) : (index += 4) {
        hist0[raw_gray[index]] += 1;
        hist1[raw_gray[index + 1]] += 1;
        hist2[raw_gray[index + 2]] += 1;
        hist3[raw_gray[index + 3]] += 1;
    }
    while (index < raw_gray.len) : (index += 1) {
        hist0[raw_gray[index]] += 1;
    }
    var hist = [_]usize{0} ** 256;
    for (&hist, 0..) |*count, bin| {
        count.* = hist0[bin] + hist1[bin] + hist2[bin] + hist3[bin];
    }
    return otsuThresholdFromHist(hist);
}

/// Gray level at or below which a pixel counts as film. Scans exposed for
/// the film alone (scanner gamma LUTs) clip every clear pixel to white while
/// the film base sits not far below, where Otsu would split the film itself.
/// When at least 2% of pixels are clipped, everything short of clipping is
/// film.
fn otsuThresholdFromHist(hist: [256]usize) u8 {
    var pixel_count: usize = 0;
    for (hist) |count| pixel_count += count;
    if (pixel_count != 0 and hist[255] * 50 >= pixel_count) return 254;

    var total_sum: f64 = 0.0;
    var total_count: usize = 0;
    for (hist, 0..) |count, index| {
        total_sum += @as(f64, @floatFromInt(index * count));
        total_count += count;
    }

    var background_count: usize = 0;
    var background_sum: f64 = 0.0;
    var best_score: f64 = -1.0;
    var best_threshold: u8 = 0;
    for (hist, 0..) |count, index| {
        background_count += count;
        if (background_count == 0) continue;
        const foreground_count = total_count - background_count;
        if (foreground_count == 0) break;
        background_sum += @as(f64, @floatFromInt(index * count));
        const background_mean = background_sum / @as(f64, @floatFromInt(background_count));
        const foreground_mean = (total_sum - background_sum) / @as(f64, @floatFromInt(foreground_count));
        const delta = background_mean - foreground_mean;
        const score = @as(f64, @floatFromInt(background_count)) * @as(f64, @floatFromInt(foreground_count)) * delta * delta;
        if (score > best_score) {
            best_score = score;
            best_threshold = @intCast(index);
        }
    }
    return best_threshold;
}

fn closeBinaryMask(allocator: std.mem.Allocator, mask: []bool, width: usize, height: usize, kernel_size: usize) !void {
    if (kernel_size == 0 or kernel_size % 2 == 0 or mask.len != width * height) return error.InvalidFilmExtentInput;
    const radius = kernel_size / 2;
    const scratch_a = try allocator.alloc(bool, mask.len);
    defer allocator.free(scratch_a);
    const scratch_b = try allocator.alloc(bool, mask.len);
    defer allocator.free(scratch_b);
    const prefix = try allocator.alloc(usize, @max(width, height) + 1);
    defer allocator.free(prefix);

    try horizontalWindowAny(mask, scratch_a, width, height, radius, prefix);
    try verticalWindowAny(scratch_a, scratch_b, width, height, radius, prefix);
    try horizontalWindowAll(scratch_b, scratch_a, width, height, radius, prefix);
    try verticalWindowAll(scratch_a, mask, width, height, radius, prefix);
}

fn dilateBinaryMask(allocator: std.mem.Allocator, input: []const bool, output: []bool, width: usize, height: usize, kernel_size: usize) !void {
    if (input.len != output.len or input.len != width * height) return error.InvalidFilmExtentInput;
    const radius = kernel_size / 2;
    const temp = try allocator.alloc(bool, input.len);
    defer allocator.free(temp);
    const prefix = try allocator.alloc(usize, @max(width, height) + 1);
    defer allocator.free(prefix);
    try horizontalWindowAny(input, temp, width, height, radius, prefix);
    try verticalWindowAny(temp, output, width, height, radius, prefix);
}

fn erodeBinaryMask(allocator: std.mem.Allocator, input: []const bool, output: []bool, width: usize, height: usize, kernel_size: usize) !void {
    if (input.len != output.len or input.len != width * height) return error.InvalidFilmExtentInput;
    const radius = kernel_size / 2;
    const temp = try allocator.alloc(bool, input.len);
    defer allocator.free(temp);
    const prefix = try allocator.alloc(usize, @max(width, height) + 1);
    defer allocator.free(prefix);
    try horizontalWindowAll(input, temp, width, height, radius, prefix);
    try verticalWindowAll(temp, output, width, height, radius, prefix);
}

fn horizontalWindowAny(input: []const bool, output: []bool, width: usize, height: usize, radius: usize, prefix: []usize) !void {
    if (input.len != output.len or input.len != width * height or prefix.len < width) return error.InvalidFilmExtentInput;
    for (0..height) |y| {
        const input_row = input[y * width ..][0..width];
        const output_row = output[y * width ..][0..width];
        @memset(output_row, false);
        var x: usize = 0;
        while (x < width) {
            while (x < width and !input_row[x]) : (x += 1) {}
            if (x == width) break;
            const run_start = x;
            while (x < width and input_row[x]) : (x += 1) {}
            const run_end = x - 1;
            const fill_start = run_start -| radius;
            const fill_end = @min(width, run_end + radius + 1);
            @memset(output_row[fill_start..fill_end], true);
        }
    }
}

fn verticalWindowAny(input: []const bool, output: []bool, width: usize, height: usize, radius: usize, prefix: []usize) !void {
    if (input.len != output.len or input.len != width * height or prefix.len < width) return error.InvalidFilmExtentInput;
    const counts = prefix[0..width];
    @memset(counts, 0);
    const initial_hi = @min(height, radius + 1);
    for (0..initial_hi) |y| {
        const row = input[y * width ..][0..width];
        for (row, counts) |value, *count| {
            count.* += @intFromBool(value);
        }
    }

    for (0..height) |y| {
        const output_row = output[y * width ..][0..width];
        for (output_row, counts) |*value, count| {
            value.* = count > 0;
        }
        if (y >= radius) {
            const remove_row = input[(y - radius) * width ..][0..width];
            for (remove_row, counts) |value, *count| {
                count.* -= @intFromBool(value);
            }
        }
        const add_y = y + radius + 1;
        if (add_y < height) {
            const add_row = input[add_y * width ..][0..width];
            for (add_row, counts) |value, *count| {
                count.* += @intFromBool(value);
            }
        }
    }
}

fn horizontalWindowAll(input: []const bool, output: []bool, width: usize, height: usize, radius: usize, prefix: []usize) !void {
    if (input.len != output.len or input.len != width * height or prefix.len < width) return error.InvalidFilmExtentInput;
    for (0..height) |y| {
        const input_row = input[y * width ..][0..width];
        const output_row = output[y * width ..][0..width];
        @memset(output_row, false);
        var x: usize = 0;
        while (x < width) {
            while (x < width and !input_row[x]) : (x += 1) {}
            if (x == width) break;
            const run_start = x;
            while (x < width and input_row[x]) : (x += 1) {}
            const run_end = x - 1;
            const fill_start = if (run_start == 0) 0 else run_start + radius;
            const fill_end = if (run_end + 1 == width) width else if (run_end >= radius) run_end - radius + 1 else 0;
            if (fill_end > fill_start) {
                @memset(output_row[fill_start..fill_end], true);
            }
        }
    }
}

fn verticalWindowAll(input: []const bool, output: []bool, width: usize, height: usize, radius: usize, prefix: []usize) !void {
    if (input.len != output.len or input.len != width * height or prefix.len < width) return error.InvalidFilmExtentInput;
    const counts = prefix[0..width];
    @memset(counts, 0);
    const initial_hi = @min(height, radius + 1);
    for (0..initial_hi) |y| {
        const row = input[y * width ..][0..width];
        for (row, counts) |value, *count| {
            count.* += @intFromBool(value);
        }
    }

    for (0..height) |y| {
        const y0 = if (y > radius) y - radius else 0;
        const y1 = @min(height, y + radius + 1);
        const window_len = y1 - y0;
        const output_row = output[y * width ..][0..width];
        for (output_row, counts) |*value, count| {
            value.* = count == window_len;
        }
        if (y >= radius) {
            const remove_row = input[(y - radius) * width ..][0..width];
            for (remove_row, counts) |value, *count| {
                count.* -= @intFromBool(value);
            }
        }
        const add_y = y + radius + 1;
        if (add_y < height) {
            const add_row = input[add_y * width ..][0..width];
            for (add_row, counts) |value, *count| {
                count.* += @intFromBool(value);
            }
        }
    }
}

const ComponentBounds = struct {
    area: usize,
    min_x: usize,
    min_y: usize,
    max_x: usize,
    max_y: usize,
};

const ComponentRun = struct {
    y: usize,
    x0: usize,
    x1: usize,
    label: usize,
};

const RunComponentStats = struct {
    parent: usize,
    area: usize,
    min_x: usize,
    min_y: usize,
    max_x: usize,
    max_y: usize,
    first_index: usize,
};

fn largestComponentBounds(allocator: std.mem.Allocator, mask: []bool, width: usize, height: usize, component_mask: []bool) !?ComponentBounds {
    if (mask.len >= component_runs_min_pixels) {
        return largestComponentBoundsRuns(allocator, mask, width, height, component_mask);
    }
    return largestComponentBoundsBfs(allocator, mask, width, height, component_mask);
}

fn largestComponentBoundsBfs(allocator: std.mem.Allocator, mask: []bool, width: usize, height: usize, component_mask: []bool) !?ComponentBounds {
    if (mask.len <= std.math.maxInt(u32)) {
        return largestComponentBoundsTyped(u32, allocator, mask, width, height, component_mask);
    }
    return largestComponentBoundsTyped(usize, allocator, mask, width, height, component_mask);
}

fn largestComponentBoundsRuns(
    allocator: std.mem.Allocator,
    mask: []bool,
    width: usize,
    height: usize,
    component_mask: []bool,
) !?ComponentBounds {
    if (mask.len != width * height or component_mask.len != mask.len) return error.InvalidFilmExtentInput;

    var runs: std.ArrayList(ComponentRun) = .empty;
    defer runs.deinit(allocator);
    var stats: std.ArrayList(RunComponentStats) = .empty;
    defer stats.deinit(allocator);

    var previous_start: usize = 0;
    var previous_end: usize = 0;
    for (0..height) |y| {
        const current_start = runs.items.len;
        const row = mask[y * width ..][0..width];
        var x: usize = 0;
        var previous_scan = previous_start;
        while (x < width) {
            while (x < width and !row[x]) : (x += 1) {}
            if (x == width) break;
            const x0 = x;
            while (x < width and row[x]) : (x += 1) {}
            const x1 = x - 1;
            const label = stats.items.len;
            try stats.append(allocator, .{
                .parent = label,
                .area = x1 - x0 + 1,
                .min_x = x0,
                .min_y = y,
                .max_x = x1,
                .max_y = y,
                .first_index = y * width + x0,
            });
            try runs.append(allocator, .{
                .y = y,
                .x0 = x0,
                .x1 = x1,
                .label = label,
            });

            while (previous_scan < previous_end and runs.items[previous_scan].x1 + 1 < x0) {
                previous_scan += 1;
            }
            var overlap_index = previous_scan;
            while (overlap_index < previous_end and runs.items[overlap_index].x0 <= x1 + 1) : (overlap_index += 1) {
                unionRunComponents(stats.items, label, runs.items[overlap_index].label);
            }
        }
        previous_start = current_start;
        previous_end = runs.items.len;
    }

    if (runs.items.len == 0) return null;

    var best_root: ?usize = null;
    for (0..stats.items.len) |label| {
        const root = findRunComponentRoot(stats.items, label);
        if (root != label) continue;
        if (best_root) |best| {
            const candidate = stats.items[root];
            const current = stats.items[best];
            if (candidate.area > current.area or
                (candidate.area == current.area and candidate.first_index < current.first_index))
            {
                best_root = root;
            }
        } else {
            best_root = root;
        }
    }
    const root = best_root orelse return null;
    const best = stats.items[root];

    @memset(component_mask, false);
    for (runs.items) |run| {
        if (findRunComponentRoot(stats.items, run.label) != root) continue;
        const row_start = run.y * width + run.x0;
        @memset(component_mask[row_start..][0 .. run.x1 - run.x0 + 1], true);
    }

    return .{
        .area = best.area,
        .min_x = best.min_x,
        .min_y = best.min_y,
        .max_x = best.max_x,
        .max_y = best.max_y,
    };
}

fn findRunComponentRoot(stats: []RunComponentStats, label: usize) usize {
    var root = label;
    while (stats[root].parent != root) {
        root = stats[root].parent;
    }
    var current = label;
    while (stats[current].parent != root) {
        const parent = stats[current].parent;
        stats[current].parent = root;
        current = parent;
    }
    return root;
}

fn unionRunComponents(stats: []RunComponentStats, a: usize, b: usize) void {
    var root_a = findRunComponentRoot(stats, a);
    var root_b = findRunComponentRoot(stats, b);
    if (root_a == root_b) return;
    if (stats[root_b].first_index < stats[root_a].first_index) {
        std.mem.swap(usize, &root_a, &root_b);
    }
    stats[root_b].parent = root_a;
    stats[root_a].area += stats[root_b].area;
    stats[root_a].min_x = @min(stats[root_a].min_x, stats[root_b].min_x);
    stats[root_a].min_y = @min(stats[root_a].min_y, stats[root_b].min_y);
    stats[root_a].max_x = @max(stats[root_a].max_x, stats[root_b].max_x);
    stats[root_a].max_y = @max(stats[root_a].max_y, stats[root_b].max_y);
}

fn largestComponentBoundsTyped(
    comptime QueueIndex: type,
    allocator: std.mem.Allocator,
    mask: []bool,
    width: usize,
    height: usize,
    component_mask: []bool,
) !?ComponentBounds {
    if (mask.len != width * height or component_mask.len != mask.len) return error.InvalidFilmExtentInput;
    const queue = try allocator.alloc(QueueIndex, mask.len);
    defer allocator.free(queue);

    var best: ?ComponentBounds = null;
    for (0..mask.len) |start_index| {
        if (!mask[start_index]) continue;
        var head: usize = 0;
        var tail: usize = 0;
        queue[tail] = @intCast(start_index);
        tail += 1;
        mask[start_index] = false;

        var bounds = ComponentBounds{
            .area = 0,
            .min_x = width,
            .min_y = height,
            .max_x = 0,
            .max_y = 0,
        };

        while (head < tail) {
            const index: usize = @intCast(queue[head]);
            head += 1;
            const x = index % width;
            const y = index / width;
            bounds.area += 1;
            bounds.min_x = @min(bounds.min_x, x);
            bounds.min_y = @min(bounds.min_y, y);
            bounds.max_x = @max(bounds.max_x, x);
            bounds.max_y = @max(bounds.max_y, y);

            const has_left = x > 0;
            const has_right = x + 1 < width;
            if (y > 0) {
                const up = index - width;
                if (has_left) enqueueComponentNeighbor(QueueIndex, mask, queue, &tail, up - 1);
                enqueueComponentNeighbor(QueueIndex, mask, queue, &tail, up);
                if (has_right) enqueueComponentNeighbor(QueueIndex, mask, queue, &tail, up + 1);
            }
            if (has_left) enqueueComponentNeighbor(QueueIndex, mask, queue, &tail, index - 1);
            if (has_right) enqueueComponentNeighbor(QueueIndex, mask, queue, &tail, index + 1);
            if (y + 1 < height) {
                const down = index + width;
                if (has_left) enqueueComponentNeighbor(QueueIndex, mask, queue, &tail, down - 1);
                enqueueComponentNeighbor(QueueIndex, mask, queue, &tail, down);
                if (has_right) enqueueComponentNeighbor(QueueIndex, mask, queue, &tail, down + 1);
            }
        }

        if (best == null or bounds.area > best.?.area) {
            best = bounds;
            @memset(component_mask, false);
            for (queue[0..tail]) |index| {
                component_mask[@intCast(index)] = true;
            }
        }
    }
    return best;
}

fn enqueueComponentNeighbor(
    comptime QueueIndex: type,
    mask: []bool,
    queue: []QueueIndex,
    tail: *usize,
    neighbor: usize,
) void {
    if (!mask[neighbor]) return;
    mask[neighbor] = false;
    queue[tail.*] = @intCast(neighbor);
    tail.* += 1;
}

fn componentRotatedExtent(allocator: std.mem.Allocator, component_mask: []const bool, width: usize, height: usize, bounds: ComponentBounds) !?FilmExtent {
    if (component_mask.len != width * height or bounds.area == 0) return error.InvalidFilmExtentInput;
    const boundary = try componentBoundaryPoints(allocator, component_mask, width, height, bounds);
    defer allocator.free(boundary);
    if (boundary.len < 3) return null;
    const hull = try convexHull(allocator, boundary);
    defer allocator.free(hull);
    if (hull.len < 3) return null;

    const rect = minAreaRectFromHull(hull) orelse return null;
    const long_dim = rect.long_dim;
    const cross_dim = rect.cross_dim;
    const long_x = rect.long_x;
    const long_y = rect.long_y;
    if (long_dim < 1.0 or cross_dim < 1.0) return null;

    var dx = long_x;
    var dy = long_y;
    const is_vertical_image = height > width;
    const strip_angle = if (is_vertical_image) angle: {
        if (dy < 0.0) {
            dx = -dx;
            dy = -dy;
        }
        break :angle -std.math.atan2(dx, dy);
    } else angle: {
        if (dx < 0.0) {
            dx = -dx;
            dy = -dy;
        }
        break :angle -std.math.atan2(dy, dx);
    };

    return .{
        .strip_narrow_px = cross_dim,
        .strip_long_px = long_dim,
        .strip_angle = strip_angle,
    };
}

const MinAreaRect = struct {
    long_dim: f64,
    cross_dim: f64,
    long_x: f64,
    long_y: f64,
};

fn componentBoundaryPoints(allocator: std.mem.Allocator, component_mask: []const bool, width: usize, height: usize, bounds: ComponentBounds) ![]Point2 {
    var points: std.ArrayList(Point2) = .empty;
    errdefer points.deinit(allocator);
    const bounds_width = bounds.max_x - bounds.min_x + 1;
    const bounds_height = bounds.max_y - bounds.min_y + 1;
    const estimated_perimeter = 2 * (bounds_width + bounds_height);
    try points.ensureTotalCapacity(allocator, @min(bounds.area, estimated_perimeter));
    for (bounds.min_y..bounds.max_y + 1) |y| {
        for (bounds.min_x..bounds.max_x + 1) |x| {
            if (!component_mask[y * width + x]) continue;
            if (isComponentBoundary(component_mask, width, height, x, y)) {
                try points.append(allocator, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) });
            }
        }
    }
    return points.toOwnedSlice(allocator);
}

fn isComponentBoundary(component_mask: []const bool, width: usize, height: usize, x: usize, y: usize) bool {
    if (x == 0 or y == 0 or x + 1 >= width or y + 1 >= height) return true;
    return !component_mask[y * width + x - 1] or
        !component_mask[y * width + x + 1] or
        !component_mask[(y - 1) * width + x] or
        !component_mask[(y + 1) * width + x];
}

fn convexHull(allocator: std.mem.Allocator, input_points: []const Point2) ![]Point2 {
    if (input_points.len < 3) return allocator.dupe(Point2, input_points);
    const points = try allocator.dupe(Point2, input_points);
    defer allocator.free(points);
    std.sort.heap(Point2, points, {}, pointLessThan);

    const hull = try allocator.alloc(Point2, points.len * 2);
    errdefer allocator.free(hull);
    var count: usize = 0;
    for (points) |point| {
        while (count >= 2 and crossPoints(hull[count - 2], hull[count - 1], point) <= 0.0) {
            count -= 1;
        }
        hull[count] = point;
        count += 1;
    }
    const lower_count = count;
    if (points.len > 1) {
        var index = points.len - 1;
        while (index > 0) {
            index -= 1;
            const point = points[index];
            while (count > lower_count and crossPoints(hull[count - 2], hull[count - 1], point) <= 0.0) {
                count -= 1;
            }
            hull[count] = point;
            count += 1;
        }
    }
    if (count > 1) count -= 1;
    const result = try allocator.dupe(Point2, hull[0..count]);
    allocator.free(hull);
    return result;
}

fn minAreaRectFromHull(hull: []const Point2) ?MinAreaRect {
    if (hull.len < 3) return null;
    var best_area = std.math.inf(f64);
    var best: ?MinAreaRect = null;
    for (hull, 0..) |point, index| {
        const next = hull[(index + 1) % hull.len];
        const edge_x = next.x - point.x;
        const edge_y = next.y - point.y;
        const edge_len = @sqrt(edge_x * edge_x + edge_y * edge_y);
        if (edge_len <= 0.0) continue;
        var axis_x = edge_x / edge_len;
        var axis_y = edge_y / edge_len;
        var cross_x = -axis_y;
        var cross_y = axis_x;
        var min_axis = std.math.inf(f64);
        var max_axis = -std.math.inf(f64);
        var min_cross = std.math.inf(f64);
        var max_cross = -std.math.inf(f64);
        for (hull) |candidate| {
            const p_axis = candidate.x * axis_x + candidate.y * axis_y;
            const p_cross = candidate.x * cross_x + candidate.y * cross_y;
            min_axis = @min(min_axis, p_axis);
            max_axis = @max(max_axis, p_axis);
            min_cross = @min(min_cross, p_cross);
            max_cross = @max(max_cross, p_cross);
        }
        var axis_dim = max_axis - min_axis;
        var cross_dim = max_cross - min_cross;
        if (axis_dim <= 0.0 or cross_dim <= 0.0) continue;
        if (axis_dim < cross_dim) {
            std.mem.swap(f64, &axis_dim, &cross_dim);
            axis_x = cross_x;
            axis_y = cross_y;
            cross_x = -axis_y;
            cross_y = axis_x;
        }
        const area = axis_dim * cross_dim;
        if (area < best_area) {
            best_area = area;
            best = .{ .long_dim = axis_dim, .cross_dim = cross_dim, .long_x = axis_x, .long_y = axis_y };
        }
    }
    return best;
}

fn pointLessThan(_: void, lhs: Point2, rhs: Point2) bool {
    if (lhs.x == rhs.x) return lhs.y < rhs.y;
    return lhs.x < rhs.x;
}

fn crossPoints(origin: Point2, a: Point2, b: Point2) f64 {
    return (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x);
}

fn pythonRoundToUsize(value: f64) usize {
    const floor_value = @floor(value);
    const fraction = value - floor_value;
    if (fraction < 0.5) return @intFromFloat(floor_value);
    if (fraction > 0.5) return @intFromFloat(floor_value + 1.0);
    const floor_int: usize = @intFromFloat(floor_value);
    return if (floor_int % 2 == 0) floor_int else floor_int + 1;
}

fn argMax(values: []const f64) usize {
    var best_index: usize = 0;
    var best_value = values[0];
    for (values[1..], 1..) |value, index| {
        if (value > best_value) {
            best_value = value;
            best_index = index;
        }
    }
    return best_index;
}

fn firstProminentPeak(values: []const f64) ?usize {
    if (values.len < 3) return null;
    const threshold = maxSlice(values) * 0.3;
    for (1..values.len - 1) |index| {
        if (isProminentPeak(values, index, threshold)) return index;
    }
    return null;
}

fn lastProminentPeak(values: []const f64) ?usize {
    if (values.len < 3) return null;
    const threshold = maxSlice(values) * 0.3;
    var result: ?usize = null;
    for (1..values.len - 1) |index| {
        if (isProminentPeak(values, index, threshold)) result = index;
    }
    return result;
}

fn isProminentPeak(values: []const f64, index: usize, threshold: f64) bool {
    if (!(values[index] > values[index - 1] and values[index] > values[index + 1])) return false;
    const height = values[index];

    var left_bound: usize = 0;
    var left_scan = index;
    while (left_scan > 0) {
        left_scan -= 1;
        if (values[left_scan] > height) {
            left_bound = left_scan + 1;
            break;
        }
    }
    var left_min = height;
    for (values[left_bound..index]) |value| {
        left_min = @min(left_min, value);
    }

    var right_bound: usize = values.len - 1;
    var right_scan = index + 1;
    while (right_scan < values.len) : (right_scan += 1) {
        if (values[right_scan] > height) {
            right_bound = right_scan - 1;
            break;
        }
    }
    var right_min = height;
    for (values[index + 1 .. right_bound + 1]) |value| {
        right_min = @min(right_min, value);
    }

    const prominence = height - @max(left_min, right_min);
    return prominence >= threshold;
}

fn maxSlice(values: []const f64) f64 {
    var result = values[0];
    for (values[1..]) |value| {
        result = @max(result, value);
    }
    return result;
}

fn subpixelPeak(values: []const f64, lo: usize, hi: usize) f64 {
    const index = lo + argMax(values[lo..hi]);
    if (index > lo and index - lo < hi - lo - 1) {
        const a = values[index - 1];
        const b = values[index];
        const c = values[index + 1];
        const denom = a - 2.0 * b + c;
        if (@abs(denom) > 1e-10) {
            return @as(f64, @floatFromInt(index)) + 0.5 * (a - c) / denom;
        }
    }
    return @floatFromInt(index);
}

fn weightedPeakValue(value: f64, index: usize, target: usize, sigma: f64) f64 {
    const distance = if (index > target)
        @as(f64, @floatFromInt(index - target))
    else
        @as(f64, @floatFromInt(target - index));
    return value * std.math.exp(-0.5 * std.math.pow(f64, distance / sigma, 2.0));
}

fn frameStarts(allocator: std.mem.Allocator, edge_positions: []const usize, frame_count: usize) ![]usize {
    const starts = try allocator.alloc(usize, frame_count);
    errdefer allocator.free(starts);
    for (starts, 0..) |*start, frame_index| {
        start.* = edge_positions[2 * frame_index];
    }
    return starts;
}

fn frameDimsRange(
    allocator: std.mem.Allocator,
    edge_positions: []const usize,
    start_frame: usize,
    end_frame_exclusive: usize,
) ![]usize {
    const count = end_frame_exclusive - start_frame;
    const dims = try allocator.alloc(usize, count);
    errdefer allocator.free(dims);
    for (dims, start_frame..) |*dim, frame_index| {
        const start = edge_positions[2 * frame_index];
        const end = edge_positions[2 * frame_index + 1];
        dim.* = end - start;
    }
    return dims;
}

fn framePitchesRange(
    allocator: std.mem.Allocator,
    starts: []const usize,
    start_index: usize,
    end_index_exclusive: usize,
) ![]usize {
    const count = end_index_exclusive - start_index;
    const pitches = try allocator.alloc(usize, count);
    errdefer allocator.free(pitches);
    for (pitches, start_index..) |*pitch, index| {
        pitch.* = starts[index + 1] - starts[index];
    }
    return pitches;
}

fn medianTrunc(allocator: std.mem.Allocator, values: []const usize) !usize {
    if (values.len == 0) return error.InvalidTerminalRepairInput;
    const sorted = try allocator.dupe(usize, values);
    defer allocator.free(sorted);
    std.sort.pdq(usize, sorted, {}, lessThanUsize);
    const mid = sorted.len / 2;
    if (sorted.len % 2 == 1) return sorted[mid];
    const median = (@as(f64, @floatFromInt(sorted[mid - 1])) + @as(f64, @floatFromInt(sorted[mid]))) / 2.0;
    return @intFromFloat(median);
}

fn stdDevUsize(values: []const usize) f64 {
    var total: f64 = 0.0;
    for (values) |value| {
        total += @floatFromInt(value);
    }
    const mean = total / @as(f64, @floatFromInt(values.len));
    var sum_sq: f64 = 0.0;
    for (values) |value| {
        const diff = @as(f64, @floatFromInt(value)) - mean;
        sum_sq += diff * diff;
    }
    return @sqrt(sum_sq / @as(f64, @floatFromInt(values.len)));
}

fn lessThanUsize(_: void, lhs: usize, rhs: usize) bool {
    return lhs < rhs;
}

fn medianSortedF64(values: []const f64) f64 {
    const mid = values.len / 2;
    if (values.len % 2 == 1) return values[mid];
    return (values[mid - 1] + values[mid]) / 2.0;
}

fn lessThanF64(_: void, lhs: f64, rhs: f64) bool {
    return lhs < rhs;
}

fn isValidBilinearCoordinate(x: f64, y: f64, width: usize, height: usize) bool {
    return x >= 0.0 and y >= 0.0 and
        x < @as(f64, @floatFromInt(width - 1)) and
        y < @as(f64, @floatFromInt(height - 1));
}

fn sampleInvertedConstantBilinear(image: []const f64, width: usize, height: usize, x: f64, y: f64) f64 {
    if (!isValidBilinearCoordinate(x, y, width, height)) return 0.0;
    const x_floor = @floor(x);
    const y_floor = @floor(y);
    const xi: usize = @intFromFloat(x_floor);
    const yi: usize = @intFromFloat(y_floor);
    const fx = x - x_floor;
    const fy = y - y_floor;
    const p00 = image[yi * width + xi];
    const p10 = image[yi * width + xi + 1];
    const p01 = image[(yi + 1) * width + xi];
    const p11 = image[(yi + 1) * width + xi + 1];
    const top = p00 * (1.0 - fx) + p10 * fx;
    const bottom = p01 * (1.0 - fx) + p11 * fx;
    return 1.0 - (top * (1.0 - fy) + bottom * fy);
}

fn validatePreviewScale(preview_scale: f64) !void {
    if (!std.math.isFinite(preview_scale) or preview_scale <= 0.0) return error.InvalidPreviewScale;
}

const StripProfileFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    shape: []const usize,
    is_vertical: bool,
    tolerance: numeric.Tolerance,
    expected_profile_a: []const f64,
    expected_profile_b: []const f64,
    expected_profile_c: []const f64,
    expected_cross_profile: []const f64,
};

const DtwFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    format: []const u8,
    frame_count: usize,
    strip_len: usize,
    dtw_max_len: usize,
    tolerance: numeric.Tolerance,
    gradient: []const f64,
    expected_edges: []const usize,
    dtw_scale: f64,
    template_len: usize,
    effective_frame_dim: usize,
    effective_gap: usize,
    band: usize,
    end_j: usize,
};

const GradientSnapFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    frame_strip_dim: f64,
    gradient: []const f64,
    edge_positions: []const usize,
    expected: []const usize,
    tolerance: numeric.Tolerance,
};

const WeightedPeakFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    gradient: []const f64,
    cases: []const WeightedPeakCase,
    tolerance: numeric.Tolerance,
};

const WeightedPeakCase = struct {
    target: usize,
    radius: usize,
    sigma: f64,
    expected: usize,
};

const SizeCorrectionFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    actual_n: usize,
    frame_strip_dim: f64,
    gradient: []const f64,
    edge_positions: []const usize,
    expected: []const usize,
    tolerance: numeric.Tolerance,
};

const TerminalRepairFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    actual_n: usize,
    frame_strip_dim: f64,
    snap_radius: usize,
    work_pitch_px: f64,
    gradient: []const f64,
    edge_positions: []const usize,
    expected: []const usize,
    tolerance: numeric.Tolerance,
};

const CrossStripFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    cross_dim_est: f64,
    cross_search_r: usize,
    gradient_signed: []const f64,
    expected: CrossStripMeasurement,
    tolerance: numeric.Tolerance,
};

const TheilSenFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    points: []const EdgePeakPoint,
    expected_angle: f64,
    expected_median_slope: f64,
    max_angle_degrees: f64,
    tolerance: numeric.Tolerance,
};

const SingleFrameFallbackFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    preview_width: f64,
    preview_height: f64,
    frame: FrameRect,
    expected: FrameRect,
    tolerance: numeric.Tolerance,
};

const RotatedCropFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    shape: []const usize,
    cx: f64,
    cy: f64,
    w: f64,
    h: f64,
    angle_deg: f64,
    input: []const f64,
    expected_shape: []const usize,
    expected: []const f64,
    tolerance: numeric.Tolerance,
};

const RebateHelpersFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    mask_shape: []const usize,
    mask_rect: RebateMaskRect,
    expected_mask: []const bool,
    bounds_shape: []const usize,
    bounds_rect: RebateOriginRect,
    expected_bounds: bool,
    inter_frames: []const FrameRect,
    expected_inter_rebate: RebateRect,
    tolerance: numeric.Tolerance,
};

const PreviewScalingFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    full_width: usize,
    full_height: usize,
    preview_size: usize,
    expected_preview_scale: f64,
    expected_preview_width: usize,
    expected_preview_height: usize,
    frame_preview: FrameRect,
    expected_frame_full: FrameRect,
    selection_preview: PreviewSelection,
    expected_selection_full_frame: FrameRect,
    rebate_preview: RebateOriginRect,
    expected_rebate_full: RebateOriginRect,
    no_downscale_full_width: usize,
    no_downscale_full_height: usize,
    no_downscale_preview_size: usize,
    tolerance: numeric.Tolerance,
};

const TestDetectGroundTruthFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    case_count: usize,
    total_frames: usize,
    cases: []const TestDetectGroundTruthCase,
    rms_acceptance_px: f64,
    tolerance: numeric.Tolerance,
};

const TestDetectGroundTruthCase = struct {
    name: []const u8,
    scan: []const u8,
    format: []const u8,
    n_frames: usize,
    preview_scale: f64,
    ground_truth: []const PreviewSelection,
    expected_full: []const FrameRect,
};

const TestDetectPythonOutputFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    cases: []const TestDetectPythonOutputCase,
    tolerance: numeric.Tolerance,
    angle_tolerance_radians: f64,
    geometry_tolerance: numeric.Tolerance,
};

const TestDetectPythonOutputCase = struct {
    name: []const u8,
    scan: []const u8,
    format: []const u8,
    n_frames: usize,
    preview_width: usize,
    preview_height: usize,
    preview_scale: f64,
    aspect: []const u8,
    elapsed_seconds: ?f64 = null,
    frames: []const FrameRect,
};

const SyntheticDetectionFixture = struct {
    name: []const u8,
    operation: []const u8,
    generated_by: []const u8,
    cases: []const SyntheticDetectionCase,
    tolerance: numeric.Tolerance,
};

const AxisAlignedDetectionFixture = struct {
    name: []const u8,
    operation: []const u8,
    generated_by: []const u8,
    cases: []const SyntheticDetectionCase,
    rms_acceptance_px: f64,
    tolerance: numeric.Tolerance,
};

const SyntheticDetectionCase = struct {
    name: []const u8,
    format: []const u8,
    orientation: []const u8,
    width: usize,
    height: usize,
    preview_scale: f64,
    background_level: f64,
    strip_rect: RebateOriginRect,
    strip_level: f64,
    frame_level: f64,
    expected_frames: []const PreviewSelection,
    expected_full: []const FrameRect,
    expected_frame_pixel_count: usize,
    cross_center_tolerance: ?f64 = null,
    cross_size_tolerance: ?f64 = null,
    angle_tolerance: ?f64 = null,
    expected_aspect: ?[]const u8 = null,
};

const DetectionGrayFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    cases: []const DetectionGrayCase,
    tolerance: numeric.Tolerance,
};

const DetectionGrayCase = struct {
    name: []const u8,
    width: usize,
    height: usize,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    invert: bool,
    sample_values: []const u16,
    expected: []const f64,
};

const AreaResizeFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    cases: []const AreaResizeCase,
};

const AreaResizeCase = struct {
    name: []const u8,
    width: usize,
    height: usize,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    target_width: usize,
    target_height: usize,
    sample_values: []const u16,
    expected: []const u16,
};

const ClaheFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    cases: []const ClaheCase,
};

const ClaheCase = struct {
    name: []const u8,
    width: usize,
    height: usize,
    tiles_x: usize,
    tiles_y: usize,
    clip_limit: f64,
    sample_values: []const u8,
    expected: []const u8,
};

const RotationBackFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    orig_width: usize,
    orig_height: usize,
    strip_angle: f64,
    expected_rotated_width: usize,
    expected_rotated_height: usize,
    forward_matrix: []const f64,
    inverse_matrix: []const f64,
    rotated_frames: []const FrameRect,
    expected_original_frames: []const FrameRect,
    tolerance: numeric.Tolerance,
};

const ExpandedRotationResampleFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    width: usize,
    height: usize,
    strip_angle: f64,
    input: []const f64,
    expected_width: usize,
    expected_height: usize,
    expected: []const f64,
    tolerance: numeric.Tolerance,
};

const FilmExtentFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    cases: []const FilmExtentCase,
    tolerance: numeric.Tolerance,
};

const BinaryCloseFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    cases: []const BinaryCloseCase,
};

const BinaryCloseCase = struct {
    name: []const u8,
    width: usize,
    height: usize,
    kernel_size: usize,
    input: []const bool,
    expected: []const bool,
};

const FilmExtentCase = struct {
    name: []const u8,
    width: usize,
    height: usize,
    background_level: f64,
    film_rect: ?RebateOriginRect = null,
    film_level: f64 = 0.2,
    expected_extent: ?FilmExtent = null,
};

const StripAnalysisFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    cases: []const StripAnalysisCase,
    tolerance: numeric.Tolerance,
};

const StripAnalysisCase = struct {
    name: []const u8,
    format: []const u8,
    width: usize,
    height: usize,
    film_extent: ?FilmExtent = null,
    strip_angle: f64,
    expected_analysis: StripAnalysis,
    expected_initial_frames: []const FrameRect,
};

fn fillProfilePattern(gray: []f64, width: usize, height: usize) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const product_mod = (x * y) % 11;
            gray[y * width + x] = @as(f64, @floatFromInt(y)) * 3.0 +
                @as(f64, @floatFromInt(x)) * 7.0 +
                @as(f64, @floatFromInt(product_mod)) * 0.5;
        }
    }
}

fn expectStripProfileFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(StripProfileFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidStripProfileFixture;
    }
    if (fixture.shape.len != 2) return error.InvalidStripProfileFixture;
    const height = fixture.shape[0];
    const width = fixture.shape[1];
    const profile_len = if (fixture.is_vertical) height else width;
    const cross_len = if (fixture.is_vertical) width else height;
    if (fixture.expected_profile_a.len != profile_len or
        fixture.expected_profile_b.len != profile_len or
        fixture.expected_profile_c.len != profile_len or
        fixture.expected_cross_profile.len != cross_len)
    {
        return error.InvalidStripProfileFixture;
    }

    const gray = try allocator.alloc(f64, width * height);
    defer allocator.free(gray);
    fillProfilePattern(gray, width, height);

    var profiles = try computeStripProfiles(allocator, gray, width, height, fixture.is_vertical);
    defer profiles.deinit(allocator);
    try numeric.assertCloseSlices(fixture.expected_profile_a, profiles.profile_a, fixture.tolerance);
    try numeric.assertCloseSlices(fixture.expected_profile_b, profiles.profile_b, fixture.tolerance);
    try numeric.assertCloseSlices(fixture.expected_profile_c, profiles.profile_c, fixture.tolerance);
    try numeric.assertCloseSlices(fixture.expected_cross_profile, profiles.cross_profile, fixture.tolerance);
}

fn expectDtwFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(DtwFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidDtwFixture;
    }
    if (fixture.expected_edges.len != fixture.frame_count * 2) return error.InvalidDtwFixture;
    const format = formatByName(fixture.format) orelse return error.InvalidDtwFixture;
    var alignment = try alignPitchDtw(allocator, fixture.gradient, fixture.strip_len, format, fixture.frame_count, .{
        .max_len = fixture.dtw_max_len,
    });
    defer alignment.deinit(allocator);

    try std.testing.expectEqualSlices(usize, fixture.expected_edges, alignment.edge_positions);
    try std.testing.expectApproxEqAbs(fixture.dtw_scale, alignment.dtw_scale, fixture.tolerance.abs);
    try std.testing.expectEqual(fixture.template_len, alignment.template_len);
    try std.testing.expectEqual(fixture.effective_frame_dim, alignment.effective_frame_dim);
    try std.testing.expectEqual(fixture.effective_gap, alignment.effective_gap);
    try std.testing.expectEqual(fixture.band, alignment.band);
    try std.testing.expectEqual(fixture.end_j, alignment.end_j);
}

fn expectGradientSnapFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(GradientSnapFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidGradientSnapFixture;
    }
    if (fixture.edge_positions.len != fixture.expected.len) return error.InvalidGradientSnapFixture;

    const output = try allocator.alloc(usize, fixture.expected.len);
    defer allocator.free(output);
    try snapEdgesToGradients(fixture.gradient, fixture.edge_positions, output, fixture.frame_strip_dim);
    try std.testing.expectEqualSlices(usize, fixture.expected, output);
    _ = fixture.tolerance;
}

fn expectWeightedPeakFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(WeightedPeakFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidWeightedPeakFixture;
    }
    if (fixture.cases.len == 0) return error.InvalidWeightedPeakFixture;
    for (fixture.cases) |case| {
        const actual = try snapToWeightedPeak(fixture.gradient, case.target, case.radius, case.sigma);
        try std.testing.expectEqual(case.expected, actual);
    }
    _ = fixture.tolerance;
}

fn expectSizeCorrectionFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(SizeCorrectionFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidSizeCorrectionFixture;
    }
    if (fixture.edge_positions.len != fixture.expected.len) return error.InvalidSizeCorrectionFixture;

    const positions = try allocator.dupe(usize, fixture.edge_positions);
    defer allocator.free(positions);
    try applySizeConsistencyCorrection(fixture.gradient, positions, fixture.actual_n, fixture.frame_strip_dim);
    try std.testing.expectEqualSlices(usize, fixture.expected, positions);
    _ = fixture.tolerance;
}

fn expectTerminalRepairFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(TerminalRepairFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidTerminalRepairFixture;
    }
    if (fixture.edge_positions.len != fixture.expected.len) return error.InvalidTerminalRepairFixture;

    const positions = try allocator.dupe(usize, fixture.edge_positions);
    defer allocator.free(positions);
    try repairTerminalFrames(
        allocator,
        fixture.gradient,
        positions,
        fixture.actual_n,
        fixture.frame_strip_dim,
        fixture.snap_radius,
        fixture.work_pitch_px,
    );
    try std.testing.expectEqualSlices(usize, fixture.expected, positions);
    _ = fixture.tolerance;
}

fn expectCrossStripFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(CrossStripFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidCrossStripFixture;
    }

    const actual = (try measureCrossStripEdges(allocator, fixture.gradient_signed, fixture.cross_dim_est, fixture.cross_search_r)) orelse return error.InvalidCrossStripFixture;
    try std.testing.expectApproxEqAbs(fixture.expected.left_t, actual.left_t, fixture.tolerance.abs);
    try std.testing.expectApproxEqAbs(fixture.expected.right_t, actual.right_t, fixture.tolerance.abs);
    try std.testing.expectApproxEqAbs(fixture.expected.cross_w, actual.cross_w, fixture.tolerance.abs);
    try std.testing.expectApproxEqAbs(fixture.expected.cross_center_offset, actual.cross_center_offset, fixture.tolerance.abs);
    try std.testing.expectEqual(fixture.expected.hw_idx, actual.hw_idx);
    try std.testing.expectEqual(fixture.expected.coarse_k, actual.coarse_k);
}

fn expectTheilSenFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(TheilSenFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidTheilSenFixture;
    }

    const max_angle = fixture.max_angle_degrees * std.math.pi / 180.0;
    const actual = (try estimateAngleTheilSen(allocator, fixture.points, max_angle)) orelse return error.InvalidTheilSenFixture;
    try std.testing.expectApproxEqAbs(fixture.expected_median_slope, actual.median_slope, fixture.tolerance.abs);
    try std.testing.expectApproxEqAbs(fixture.expected_angle, actual.angle, fixture.tolerance.abs);
}

fn expectSingleFrameFallbackFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(SingleFrameFallbackFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidSingleFrameFallbackFixture;
    }

    const actual = (try singleFrameFallback(1, fixture.frame, fixture.preview_width, fixture.preview_height)) orelse return error.InvalidSingleFrameFallbackFixture;
    try expectFrameRect(fixture.expected, actual, fixture.tolerance.abs);
}

fn expectFrameRect(expected: FrameRect, actual: FrameRect, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected.cx, actual.cx, tolerance);
    try std.testing.expectApproxEqAbs(expected.cy, actual.cy, tolerance);
    try std.testing.expectApproxEqAbs(expected.w, actual.w, tolerance);
    try std.testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
    try std.testing.expectApproxEqAbs(expected.angle, actual.angle, tolerance);
}

fn expectRotatedCropFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(RotatedCropFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidRotatedCropFixture;
    }
    if (fixture.shape.len != 2 or fixture.expected_shape.len != 2) return error.InvalidRotatedCropFixture;
    const height = fixture.shape[0];
    const width = fixture.shape[1];
    if (fixture.input.len != width * height) return error.InvalidRotatedCropFixture;

    var crop = try cropRotatedRect(allocator, fixture.input, width, height, fixture.cx, fixture.cy, fixture.w, fixture.h, fixture.angle_deg);
    defer crop.deinit(allocator);
    try std.testing.expectEqual(fixture.expected_shape[1], crop.width);
    try std.testing.expectEqual(fixture.expected_shape[0], crop.height);
    try numeric.assertCloseSlices(fixture.expected, crop.pixels, fixture.tolerance);
}

fn expectRebateHelpersFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(RebateHelpersFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidRebateFixture;
    }
    if (fixture.mask_shape.len != 2 or fixture.bounds_shape.len != 2) return error.InvalidRebateFixture;
    const mask_h = fixture.mask_shape[0];
    const mask_w = fixture.mask_shape[1];
    const mask = (try makeRebateMask(allocator, mask_h, mask_w, fixture.mask_rect)) orelse return error.InvalidRebateFixture;
    defer allocator.free(mask);
    try std.testing.expectEqualSlices(bool, fixture.expected_mask, mask);

    const bounds_h = fixture.bounds_shape[0];
    const bounds_w = fixture.bounds_shape[1];
    try std.testing.expectEqual(fixture.expected_bounds, rebateInBounds(bounds_w, bounds_h, fixture.bounds_rect));

    const actual_rebate = computeInterFrameRebate(fixture.inter_frames) orelse return error.InvalidRebateFixture;
    try expectRebateRect(fixture.expected_inter_rebate, actual_rebate, fixture.tolerance.abs);
}

fn expectRebateRect(expected: RebateRect, actual: RebateRect, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected.cx, actual.cx, tolerance);
    try std.testing.expectApproxEqAbs(expected.cy, actual.cy, tolerance);
    try std.testing.expectApproxEqAbs(expected.w, actual.w, tolerance);
    try std.testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
    try std.testing.expectApproxEqAbs(expected.angle, actual.angle, tolerance);
}

fn expectPreviewScalingFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(PreviewScalingFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidPreviewScalingFixture;
    }

    const geometry = try computePreviewGeometry(fixture.full_width, fixture.full_height, fixture.preview_size);
    try std.testing.expectEqual(fixture.full_width, geometry.full_width);
    try std.testing.expectEqual(fixture.full_height, geometry.full_height);
    try std.testing.expectEqual(fixture.expected_preview_width, geometry.preview_width);
    try std.testing.expectEqual(fixture.expected_preview_height, geometry.preview_height);
    try std.testing.expectApproxEqAbs(fixture.expected_preview_scale, geometry.preview_scale, fixture.tolerance.abs);

    try expectFrameRect(fixture.expected_frame_full, try previewFrameToFullResolution(fixture.frame_preview, geometry.preview_scale), fixture.tolerance.abs);
    try expectFrameRect(
        fixture.expected_selection_full_frame,
        try previewSelectionToFullResolution(fixture.selection_preview, geometry.preview_scale),
        fixture.tolerance.abs,
    );
    try expectRebateOriginRect(fixture.expected_rebate_full, try previewRebateToFullResolution(fixture.rebate_preview, geometry.preview_scale), fixture.tolerance.abs);

    const no_downscale = try computePreviewGeometry(
        fixture.no_downscale_full_width,
        fixture.no_downscale_full_height,
        fixture.no_downscale_preview_size,
    );
    try std.testing.expectEqual(fixture.no_downscale_full_width, no_downscale.preview_width);
    try std.testing.expectEqual(fixture.no_downscale_full_height, no_downscale.preview_height);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), no_downscale.preview_scale, fixture.tolerance.abs);
}

fn expectTestDetectGroundTruthFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(512 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(TestDetectGroundTruthFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidTestDetectGroundTruthFixture;
    }
    try std.testing.expectEqual(fixture.case_count, fixture.cases.len);
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), fixture.rms_acceptance_px, fixture.tolerance.abs);

    var total_frames: usize = 0;
    for (fixture.cases) |test_case| {
        if (test_case.name.len == 0 or test_case.scan.len == 0 or test_case.format.len == 0) {
            return error.InvalidTestDetectGroundTruthFixture;
        }
        _ = formatByName(test_case.format) orelse return error.InvalidTestDetectGroundTruthFixture;
        if (!std.math.isFinite(test_case.preview_scale) or test_case.preview_scale <= 0.0) {
            return error.InvalidTestDetectGroundTruthFixture;
        }
        if (test_case.n_frames != test_case.ground_truth.len or test_case.expected_full.len != test_case.ground_truth.len) {
            return error.InvalidTestDetectGroundTruthFixture;
        }

        total_frames += test_case.ground_truth.len;
        for (test_case.ground_truth, test_case.expected_full) |ground_truth_preview, expected_full| {
            const actual_full = try previewSelectionToFullResolution(ground_truth_preview, test_case.preview_scale);
            try expectFrameRect(expected_full, actual_full, fixture.tolerance.abs);
            try std.testing.expectApproxEqAbs(@as(f64, 0.0), frameRmsError(actual_full, expected_full), fixture.tolerance.abs);
            try std.testing.expectApproxEqAbs(
                @as(f64, 0.0),
                frameAngleErrorRadians(actual_full.angle, ground_truth_preview.angle),
                fixture.tolerance.abs,
            );
        }
    }
    try std.testing.expectEqual(fixture.total_frames, total_frames);
}

fn expectScanDetectorParity(path: []const u8, scan_path: []const u8) !void {
    if (!tiff_available) {
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(512 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(TestDetectPythonOutputFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0 or fixture.cases.len == 0) {
        return error.InvalidTestDetectPythonOutputFixture;
    }

    var selected: ?TestDetectPythonOutputCase = null;
    for (fixture.cases) |test_case| {
        if (std.mem.eql(u8, test_case.scan, scan_path)) {
            selected = test_case;
            break;
        }
    }
    const test_case = selected orelse return error.InvalidTestDetectPythonOutputFixture;
    std.Io.Dir.cwd().access(std.testing.io, test_case.scan, .{}) catch return error.SkipZigTest;

    const format = formatByName(test_case.format) orelse return error.InvalidTestDetectPythonOutputFixture;
    if (test_case.name.len == 0 or test_case.scan.len == 0 or test_case.format.len == 0 or test_case.aspect.len == 0) {
        return error.InvalidTestDetectPythonOutputFixture;
    }
    if (test_case.frames.len != test_case.n_frames or fixture.angle_tolerance_radians <= 0.0) {
        return error.InvalidTestDetectPythonOutputFixture;
    }
    const rgb = try tiff.loadRgbPage(allocator, test_case.scan);
    defer rgb.deinit(allocator);
    const geometry = try computePreviewGeometry(@intCast(rgb.width), @intCast(rgb.height), 8192);
    try std.testing.expectEqual(test_case.preview_width, geometry.preview_width);
    try std.testing.expectEqual(test_case.preview_height, geometry.preview_height);
    try std.testing.expectApproxEqAbs(test_case.preview_scale, geometry.preview_scale, fixture.geometry_tolerance.abs);

    const preview_data = try resizeImageArea(
        allocator,
        rgb.data,
        @intCast(rgb.width),
        @intCast(rgb.height),
        rgb.samples_per_pixel,
        rgb.bits_per_sample,
        geometry.preview_width,
        geometry.preview_height,
    );
    defer allocator.free(preview_data);
    var detected = try detectFramesFromImage(
        allocator,
        preview_data,
        geometry.preview_width,
        geometry.preview_height,
        rgb.samples_per_pixel,
        rgb.bits_per_sample,
        format,
        .{
            .frame_count_override = test_case.n_frames,
            .detect_film_extent = true,
            .apply_clahe = true,
        },
    );
    defer detected.deinit(allocator);

    try std.testing.expectEqualStrings(test_case.aspect, detected.aspect);
    try std.testing.expectEqual(test_case.frames.len, detected.frames.len);
    var all_frames_match = true;
    for (test_case.frames, detected.frames, 0..) |expected, actual, frame_index| {
        const max_spatial_delta = @max(
            @max(@abs(actual.cx - expected.cx), @abs(actual.cy - expected.cy)),
            @max(@abs(actual.w - expected.w), @abs(actual.h - expected.h)),
        );
        const angle_delta = @abs(frameAngleErrorRadians(actual.angle, expected.angle));
        if (max_spatial_delta > fixture.tolerance.abs or angle_delta > fixture.angle_tolerance_radians) {
            all_frames_match = false;
            std.debug.print("{s} frame {d}: expected ({d:.3},{d:.3},{d:.3},{d:.3},{d:.6}) actual ({d:.3},{d:.3},{d:.3},{d:.3},{d:.6}) max_delta {d:.3} angle_delta {d:.6}\n", .{
                test_case.scan,
                frame_index + 1,
                expected.cx,
                expected.cy,
                expected.w,
                expected.h,
                expected.angle,
                actual.cx,
                actual.cy,
                actual.w,
                actual.h,
                actual.angle,
                max_spatial_delta,
                angle_delta,
            });
        }
    }
    try std.testing.expect(all_frames_match);
}

fn expectSyntheticDetectionFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(SyntheticDetectionFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidSyntheticDetectionFixture;
    }
    if (fixture.cases.len == 0) return error.InvalidSyntheticDetectionFixture;

    for (fixture.cases) |test_case| {
        if (test_case.name.len == 0 or test_case.format.len == 0 or test_case.orientation.len == 0) {
            return error.InvalidSyntheticDetectionFixture;
        }
        _ = formatByName(test_case.format) orelse return error.InvalidSyntheticDetectionFixture;
        const is_vertical = if (std.mem.eql(u8, test_case.orientation, "vertical"))
            true
        else if (std.mem.eql(u8, test_case.orientation, "horizontal"))
            false
        else
            return error.InvalidSyntheticDetectionFixture;
        if (test_case.width == 0 or test_case.height == 0 or test_case.expected_frames.len == 0) {
            return error.InvalidSyntheticDetectionFixture;
        }
        if (test_case.expected_full.len != test_case.expected_frames.len) {
            return error.InvalidSyntheticDetectionFixture;
        }

        const image = try synthesizeDetectionImage(allocator, test_case);
        defer allocator.free(image);
        try std.testing.expectEqual(test_case.expected_frame_pixel_count, countExactPixels(image, test_case.frame_level));

        for (test_case.expected_frames, test_case.expected_full) |frame_preview, expected_full| {
            try expectFrameRect(expected_full, try previewSelectionToFullResolution(frame_preview, test_case.preview_scale), fixture.tolerance.abs);
        }

        var profiles = try computeStripProfiles(allocator, image, test_case.width, test_case.height, is_vertical);
        defer profiles.deinit(allocator);
        try std.testing.expectEqual(if (is_vertical) test_case.height else test_case.width, profiles.profile_a.len);
        try std.testing.expectEqual(if (is_vertical) test_case.width else test_case.height, profiles.cross_profile.len);
    }
}

fn expectAxisAlignedDetectionFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(AxisAlignedDetectionFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.generated_by.len == 0 or fixture.cases.len == 0) {
        return error.InvalidSyntheticDetectionFixture;
    }
    if (!std.math.isFinite(fixture.rms_acceptance_px) or fixture.rms_acceptance_px <= 0.0) {
        return error.InvalidSyntheticDetectionFixture;
    }

    for (fixture.cases) |test_case| {
        const format = formatByName(test_case.format) orelse return error.InvalidSyntheticDetectionFixture;
        const image = try synthesizeDetectionImage(allocator, test_case);
        defer allocator.free(image);
        var detected = try detectFramesAxisAlignedPrepared(allocator, image, test_case.width, test_case.height, format, .{
            .frame_count_override = test_case.expected_frames.len,
        });
        defer detected.deinit(allocator);
        try std.testing.expectEqual(test_case.expected_full.len, detected.frames.len);
        if (test_case.expected_aspect) |expected_aspect| {
            try std.testing.expectEqualStrings(expected_aspect, detected.aspect);
        }
        for (test_case.expected_full, detected.frames) |expected, actual| {
            try std.testing.expect(frameRmsError(actual, expected) <= fixture.rms_acceptance_px);
            try expectFrameRect(expected, actual, fixture.tolerance.abs);
            if (test_case.cross_center_tolerance) |cross_tolerance| {
                if (detected.strip_info.is_vertical) {
                    try std.testing.expectApproxEqAbs(expected.cx, actual.cx, cross_tolerance);
                } else {
                    try std.testing.expectApproxEqAbs(expected.cy, actual.cy, cross_tolerance);
                }
            }
            if (test_case.cross_size_tolerance) |cross_tolerance| {
                if (detected.strip_info.is_vertical) {
                    try std.testing.expectApproxEqAbs(expected.w, actual.w, cross_tolerance);
                } else {
                    try std.testing.expectApproxEqAbs(expected.h, actual.h, cross_tolerance);
                }
            }
            if (test_case.angle_tolerance) |angle_tolerance| {
                try std.testing.expectApproxEqAbs(expected.angle, actual.angle, angle_tolerance);
            }
        }

        const image_bytes = try grayImageToU8Bytes(allocator, image);
        defer allocator.free(image_bytes);
        var detected_from_image = try detectFramesFromImage(
            allocator,
            image_bytes,
            test_case.width,
            test_case.height,
            1,
            8,
            format,
            .{
                .frame_count_override = test_case.expected_frames.len,
                .detect_film_extent = false,
                .apply_clahe = false,
            },
        );
        defer detected_from_image.deinit(allocator);
        try std.testing.expectEqual(test_case.expected_full.len, detected_from_image.frames.len);
        if (test_case.expected_aspect) |expected_aspect| {
            try std.testing.expectEqualStrings(expected_aspect, detected_from_image.aspect);
        }
        for (test_case.expected_full, detected_from_image.frames) |expected, actual| {
            try std.testing.expect(frameRmsError(actual, expected) <= fixture.rms_acceptance_px);
            try expectFrameRect(expected, actual, fixture.tolerance.abs);
        }

        var detected_with_clahe = try detectFramesFromImage(
            allocator,
            image_bytes,
            test_case.width,
            test_case.height,
            1,
            8,
            format,
            .{
                .frame_count_override = test_case.expected_frames.len,
                .detect_film_extent = false,
                .apply_clahe = true,
            },
        );
        defer detected_with_clahe.deinit(allocator);
        try std.testing.expectEqual(test_case.expected_full.len, detected_with_clahe.frames.len);
        if (test_case.expected_aspect) |expected_aspect| {
            try std.testing.expectEqualStrings(expected_aspect, detected_with_clahe.aspect);
        }
    }
}

fn expectRotatedWrapperDetectionFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(AxisAlignedDetectionFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.generated_by.len == 0 or fixture.cases.len == 0) {
        return error.InvalidSyntheticDetectionFixture;
    }
    if (!std.math.isFinite(fixture.rms_acceptance_px) or fixture.rms_acceptance_px <= 0.0) {
        return error.InvalidSyntheticDetectionFixture;
    }

    for (fixture.cases) |test_case| {
        const format = formatByName(test_case.format) orelse return error.InvalidSyntheticDetectionFixture;
        const image = try synthesizeDetectionImage(allocator, test_case);
        defer allocator.free(image);
        const extent = FilmExtent{
            .strip_narrow_px = @min(test_case.strip_rect.w, test_case.strip_rect.h),
            .strip_long_px = @max(test_case.strip_rect.w, test_case.strip_rect.h),
            .strip_angle = test_case.strip_rect.angle,
        };
        try std.testing.expect(@abs(extent.strip_angle) > 0.1 * std.math.pi / 180.0);

        const image_bytes = try grayImageToU8Bytes(allocator, image);
        defer allocator.free(image_bytes);
        var detected = try detectFramesFromImage(
            allocator,
            image_bytes,
            test_case.width,
            test_case.height,
            1,
            8,
            format,
            .{
                .frame_count_override = test_case.expected_full.len,
                .detect_film_extent = false,
                .film_extent_override = extent,
                .apply_clahe = false,
            },
        );
        defer detected.deinit(allocator);

        try std.testing.expectEqual(test_case.expected_full.len, detected.frames.len);
        if (test_case.expected_aspect) |expected_aspect| {
            try std.testing.expectEqualStrings(expected_aspect, detected.aspect);
        }
        const angle_tolerance = test_case.angle_tolerance orelse fixture.tolerance.abs;
        for (test_case.expected_full, detected.frames) |expected, actual| {
            const rms = frameRmsError(actual, expected);
            try std.testing.expect(rms <= fixture.rms_acceptance_px);
            try std.testing.expectApproxEqAbs(expected.cx, actual.cx, fixture.tolerance.abs);
            try std.testing.expectApproxEqAbs(expected.cy, actual.cy, fixture.tolerance.abs);
            try std.testing.expectApproxEqAbs(expected.w, actual.w, fixture.tolerance.abs);
            try std.testing.expectApproxEqAbs(expected.h, actual.h, fixture.tolerance.abs);
            try std.testing.expectApproxEqAbs(expected.angle, actual.angle, angle_tolerance);
        }
    }
}

fn expectDetectionGrayFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(128 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(DetectionGrayFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0 or fixture.cases.len == 0) {
        return error.InvalidDetectionGrayFixture;
    }

    for (fixture.cases) |test_case| {
        if (test_case.name.len == 0 or test_case.width == 0 or test_case.height == 0) return error.InvalidDetectionGrayFixture;
        const pixel_count = try std.math.mul(usize, test_case.width, test_case.height);
        const sample_count = try std.math.mul(usize, pixel_count, test_case.samples_per_pixel);
        if (test_case.sample_values.len != sample_count or test_case.expected.len != pixel_count) {
            return error.InvalidDetectionGrayFixture;
        }
        const data = try sampleValuesToBytes(allocator, test_case.sample_values, test_case.bits_per_sample);
        defer allocator.free(data);
        const actual = try prepareDetectionGray(
            allocator,
            data,
            test_case.width,
            test_case.height,
            test_case.samples_per_pixel,
            test_case.bits_per_sample,
            .{ .invert = test_case.invert },
        );
        defer allocator.free(actual);
        for (test_case.expected, actual) |expected, value| {
            try std.testing.expectApproxEqAbs(expected, value, fixture.tolerance.abs);
        }
    }
}

fn expectAreaResizeFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(128 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(AreaResizeFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0 or fixture.cases.len == 0) {
        return error.InvalidAreaResizeInput;
    }

    for (fixture.cases) |test_case| {
        if (test_case.name.len == 0 or test_case.width == 0 or test_case.height == 0 or test_case.target_width == 0 or test_case.target_height == 0) {
            return error.InvalidAreaResizeInput;
        }
        const input_sample_count = try std.math.mul(usize, try std.math.mul(usize, test_case.width, test_case.height), test_case.samples_per_pixel);
        const output_sample_count = try std.math.mul(usize, try std.math.mul(usize, test_case.target_width, test_case.target_height), test_case.samples_per_pixel);
        if (test_case.sample_values.len != input_sample_count or test_case.expected.len != output_sample_count) {
            return error.InvalidAreaResizeInput;
        }
        const data = try sampleValuesToBytes(allocator, test_case.sample_values, test_case.bits_per_sample);
        defer allocator.free(data);
        const actual_bytes = try resizeImageArea(
            allocator,
            data,
            test_case.width,
            test_case.height,
            test_case.samples_per_pixel,
            test_case.bits_per_sample,
            test_case.target_width,
            test_case.target_height,
        );
        defer allocator.free(actual_bytes);
        for (test_case.expected, 0..) |expected, sample_index| {
            try std.testing.expectEqual(expected, sampleToU16(actual_bytes, sample_index, test_case.bits_per_sample));
        }
    }
}

fn expectClaheFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(ClaheFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0 or fixture.cases.len == 0) {
        return error.InvalidClaheFixture;
    }
    for (fixture.cases) |test_case| {
        if (test_case.name.len == 0 or test_case.width == 0 or test_case.height == 0) return error.InvalidClaheFixture;
        const pixel_count = try std.math.mul(usize, test_case.width, test_case.height);
        if (test_case.sample_values.len != pixel_count or test_case.expected.len != pixel_count) {
            return error.InvalidClaheFixture;
        }
        const actual = try applyClahe8(allocator, test_case.sample_values, test_case.width, test_case.height, .{
            .clip_limit = test_case.clip_limit,
            .tiles_x = test_case.tiles_x,
            .tiles_y = test_case.tiles_y,
        });
        defer allocator.free(actual);
        try std.testing.expectEqualSlices(u8, test_case.expected, actual);
    }
}

fn expectRotationBackFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(128 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(RotationBackFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidRotationTransformFixture;
    }
    if (fixture.forward_matrix.len != 6 or fixture.inverse_matrix.len != 6 or fixture.rotated_frames.len != fixture.expected_original_frames.len) {
        return error.InvalidRotationTransformFixture;
    }

    const transform = try expandedRotationTransform(fixture.orig_width, fixture.orig_height, fixture.strip_angle);
    try std.testing.expectEqual(fixture.expected_rotated_width, transform.rotated_width);
    try std.testing.expectEqual(fixture.expected_rotated_height, transform.rotated_height);
    for (fixture.forward_matrix, transform.forward.values) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, fixture.tolerance.abs);
    }
    for (fixture.inverse_matrix, transform.inverse.values) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, fixture.tolerance.abs);
    }

    const frames = try allocator.dupe(FrameRect, fixture.rotated_frames);
    defer allocator.free(frames);
    try transformFramesFromRotatedToOriginal(frames, transform.inverse, fixture.strip_angle);
    for (fixture.expected_original_frames, frames) |expected, actual| {
        try expectFrameRect(expected, actual, fixture.tolerance.abs);
    }
}

fn expectExpandedRotationResampleFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(128 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(ExpandedRotationResampleFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidRotationTransformFixture;
    }
    if (fixture.input.len != fixture.width * fixture.height or fixture.expected.len != fixture.expected_width * fixture.expected_height) {
        return error.InvalidRotationTransformFixture;
    }

    var actual = try rotateImageExpandedReplicate(allocator, fixture.input, fixture.width, fixture.height, fixture.strip_angle);
    defer actual.deinit(allocator);
    try std.testing.expectEqual(fixture.expected_width, actual.width);
    try std.testing.expectEqual(fixture.expected_height, actual.height);
    for (fixture.expected, actual.pixels) |expected, value| {
        try std.testing.expectApproxEqAbs(expected, value, fixture.tolerance.abs);
    }
}

fn expectFilmExtentFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(128 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(FilmExtentFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0 or fixture.cases.len == 0) {
        return error.InvalidFilmExtentFixture;
    }

    for (fixture.cases) |test_case| {
        if (test_case.name.len == 0 or test_case.width == 0 or test_case.height == 0) return error.InvalidFilmExtentFixture;
        const image = try synthesizeFilmExtentImage(allocator, test_case);
        defer allocator.free(image);
        const actual = try detectFilmExtentAxisAligned(allocator, image, test_case.width, test_case.height);
        const image_u8 = try grayImageToU8Bytes(allocator, image);
        defer allocator.free(image_u8);
        const actual_u8 = try detectFilmExtentAxisAlignedU8(allocator, image_u8, test_case.width, test_case.height);
        if (test_case.expected_extent) |expected| {
            const extent = actual orelse return error.InvalidFilmExtentFixture;
            const extent_u8 = actual_u8 orelse return error.InvalidFilmExtentFixture;
            try std.testing.expectApproxEqAbs(expected.strip_narrow_px, extent.strip_narrow_px, fixture.tolerance.abs);
            try std.testing.expectApproxEqAbs(expected.strip_long_px, extent.strip_long_px, fixture.tolerance.abs);
            try std.testing.expectApproxEqAbs(expected.strip_angle, extent.strip_angle, fixture.tolerance.abs);
            try std.testing.expectApproxEqAbs(extent.strip_narrow_px, extent_u8.strip_narrow_px, 1e-9);
            try std.testing.expectApproxEqAbs(extent.strip_long_px, extent_u8.strip_long_px, 1e-9);
            try std.testing.expectApproxEqAbs(extent.strip_angle, extent_u8.strip_angle, 1e-12);
        } else {
            try std.testing.expect(actual == null);
            try std.testing.expect(actual_u8 == null);
        }
    }
}

fn expectBinaryCloseFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(128 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(BinaryCloseFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0 or fixture.cases.len == 0) {
        return error.InvalidFilmExtentFixture;
    }

    for (fixture.cases) |test_case| {
        if (test_case.name.len == 0 or test_case.input.len != test_case.width * test_case.height or test_case.expected.len != test_case.input.len) {
            return error.InvalidFilmExtentFixture;
        }
        const mask = try allocator.dupe(bool, test_case.input);
        defer allocator.free(mask);
        try closeBinaryMask(allocator, mask, test_case.width, test_case.height, test_case.kernel_size);
        try std.testing.expectEqualSlices(bool, test_case.expected, mask);
    }
}

fn expectStripAnalysisFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(StripAnalysisFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.name.len == 0 or fixture.operation.len == 0 or fixture.python_oracle.len == 0 or fixture.generated_by.len == 0) {
        return error.InvalidStripAnalysisFixture;
    }

    for (fixture.cases) |test_case| {
        if (test_case.name.len == 0 or test_case.format.len == 0) return error.InvalidStripAnalysisFixture;
        const format = formatByName(test_case.format) orelse return error.InvalidStripAnalysisFixture;
        const analysis = try analyzeStrip(test_case.width, test_case.height, format, test_case.film_extent);
        try expectStripAnalysis(test_case.expected_analysis, analysis, fixture.tolerance.abs);
        try std.testing.expectEqual(test_case.expected_analysis.n_frames, test_case.expected_initial_frames.len);
        const frames = try initialPlacement(
            allocator,
            test_case.width,
            test_case.height,
            analysis.n_frames,
            analysis,
            test_case.strip_angle,
        );
        defer allocator.free(frames);
        try std.testing.expectEqual(test_case.expected_initial_frames.len, frames.len);
        for (test_case.expected_initial_frames, frames) |expected, actual| {
            try expectFrameRect(expected, actual, fixture.tolerance.abs);
        }
    }
}

fn expectStripAnalysis(expected: StripAnalysis, actual: StripAnalysis, tolerance: f64) !void {
    try std.testing.expectEqual(expected.n_frames, actual.n_frames);
    try std.testing.expectApproxEqAbs(expected.frame_w, actual.frame_w, tolerance);
    try std.testing.expectApproxEqAbs(expected.frame_h, actual.frame_h, tolerance);
    try std.testing.expectApproxEqAbs(expected.pitch_px, actual.pitch_px, tolerance);
    try std.testing.expectEqual(expected.is_vertical, actual.is_vertical);
}

fn synthesizeDetectionImage(allocator: std.mem.Allocator, test_case: SyntheticDetectionCase) ![]f64 {
    if (test_case.width == 0 or test_case.height == 0) return error.InvalidSyntheticDetectionFixture;
    const image = try allocator.alloc(f64, test_case.width * test_case.height);
    errdefer allocator.free(image);
    @memset(image, test_case.background_level);
    fillRect(image, test_case.width, test_case.height, .{
        .x = test_case.strip_rect.x,
        .y = test_case.strip_rect.y,
        .width = test_case.strip_rect.w,
        .height = test_case.strip_rect.h,
    }, test_case.strip_level);
    for (test_case.expected_frames) |frame| {
        fillSyntheticFrame(image, test_case.width, test_case.height, frame, test_case.frame_level);
    }
    return image;
}

fn synthesizeFilmExtentImage(allocator: std.mem.Allocator, test_case: FilmExtentCase) ![]f64 {
    const image = try allocator.alloc(f64, test_case.width * test_case.height);
    errdefer allocator.free(image);
    @memset(image, test_case.background_level);
    if (test_case.film_rect) |rect| {
        fillSyntheticFrame(image, test_case.width, test_case.height, .{
            .x = rect.x,
            .y = rect.y,
            .w = rect.w,
            .h = rect.h,
            .angle = rect.angle,
        }, test_case.film_level);
    }
    return image;
}

fn sampleValuesToBytes(allocator: std.mem.Allocator, values: []const u16, bits_per_sample: u16) ![]u8 {
    if (bits_per_sample != 8 and bits_per_sample != 16) return error.InvalidDetectionGrayFixture;
    const bytes_per_sample: usize = bits_per_sample / 8;
    const data = try allocator.alloc(u8, values.len * bytes_per_sample);
    errdefer allocator.free(data);
    if (bits_per_sample == 8) {
        for (values, data) |value, *byte| {
            if (value > 255) return error.InvalidDetectionGrayFixture;
            byte.* = @intCast(value);
        }
    } else {
        for (values, 0..) |value, index| {
            std.mem.writeInt(u16, data[index * 2 ..][0..2], value, .little);
        }
    }
    return data;
}

fn grayImageToU8Bytes(allocator: std.mem.Allocator, image: []const f64) ![]u8 {
    const data = try allocator.alloc(u8, image.len);
    errdefer allocator.free(data);
    for (image, data) |value, *byte| {
        byte.* = grayToU8(value);
    }
    return data;
}

fn grayImageToInvertedU8Bytes(allocator: std.mem.Allocator, image: []const f64) ![]u8 {
    const data = try allocator.alloc(u8, image.len);
    errdefer allocator.free(data);
    const worker_count = workerCountForItems(image.len, conversion_parallel_min_items);
    if (parallelism.enabled and worker_count > 1) {
        try grayImageToInvertedU8BytesParallel(allocator, image, data, worker_count);
    } else {
        fillGrayToInvertedU8Range(image, data, 0, image.len);
    }
    return data;
}

fn grayImageToInvertedU8BytesParallel(
    allocator: std.mem.Allocator,
    input: []const f64,
    output: []u8,
    worker_count: usize,
) !void {
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(GrayToInvertedU8RangeContext, worker_count);
    defer allocator.free(contexts);
    var started: usize = 0;
    errdefer {
        for (threads[0..started]) |thread| {
            thread.join();
        }
    }
    for (0..worker_count) |worker_index| {
        const start = input.len * worker_index / worker_count;
        const end = input.len * (worker_index + 1) / worker_count;
        contexts[worker_index] = .{
            .input = input,
            .output = output,
            .start = start,
            .end = end,
        };
        threads[worker_index] = try std.Thread.spawn(.{}, grayImageToInvertedU8BytesWorker, .{&contexts[worker_index]});
        started += 1;
    }
    for (threads) |thread| {
        thread.join();
    }
}

fn grayImageToInvertedU8BytesWorker(context: *const GrayToInvertedU8RangeContext) void {
    fillGrayToInvertedU8Range(context.input, context.output, context.start, context.end);
}

fn fillGrayToInvertedU8Range(input: []const f64, output: []u8, start: usize, end: usize) void {
    for (input[start..end], output[start..end]) |value, *byte| {
        byte.* = 255 - grayToU8(value);
    }
}

fn fillInvertedU8(allocator: std.mem.Allocator, input: []const u8, output: []u8) !void {
    const worker_count = workerCountForItems(input.len, conversion_parallel_min_items);
    if (parallelism.enabled and worker_count > 1) {
        try fillInvertedU8Parallel(allocator, input, output, worker_count);
    } else {
        fillInvertedU8Range(input, output, 0, input.len);
    }
}

fn fillInvertedU8Parallel(
    allocator: std.mem.Allocator,
    input: []const u8,
    output: []u8,
    worker_count: usize,
) !void {
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(U8InvertRangeContext, worker_count);
    defer allocator.free(contexts);
    var started: usize = 0;
    errdefer {
        for (threads[0..started]) |thread| {
            thread.join();
        }
    }
    for (0..worker_count) |worker_index| {
        const start = input.len * worker_index / worker_count;
        const end = input.len * (worker_index + 1) / worker_count;
        contexts[worker_index] = .{
            .input = input,
            .output = output,
            .start = start,
            .end = end,
        };
        threads[worker_index] = try std.Thread.spawn(.{}, fillInvertedU8Worker, .{&contexts[worker_index]});
        started += 1;
    }
    for (threads) |thread| {
        thread.join();
    }
}

fn fillInvertedU8Worker(context: *const U8InvertRangeContext) void {
    fillInvertedU8Range(context.input, context.output, context.start, context.end);
}

fn fillInvertedU8Range(input: []const u8, output: []u8, start: usize, end: usize) void {
    const VecU8 = @Vector(byte_simd_width, u8);
    const max_u8: VecU8 = @splat(255);
    var index = start;
    while (index + byte_simd_width <= end) : (index += byte_simd_width) {
        const values: VecU8 = @bitCast(input[index..][0..byte_simd_width].*);
        const inverted = max_u8 - values;
        const inverted_bytes: [byte_simd_width]u8 = @bitCast(inverted);
        @memcpy(output[index..][0..byte_simd_width], &inverted_bytes);
    }
    for (input[index..end], output[index..end]) |value, *out| {
        out.* = 255 - value;
    }
}

fn u8ImageToF64(allocator: std.mem.Allocator, image: []const u8) ![]f64 {
    const data = try allocator.alloc(f64, image.len);
    errdefer allocator.free(data);
    const worker_count = workerCountForItems(image.len, conversion_parallel_min_items);
    if (parallelism.enabled and worker_count > 1) {
        try u8ImageToF64Parallel(allocator, image, data, worker_count);
    } else {
        fillU8ToF64Range(image, data, 0, image.len);
    }
    return data;
}

fn u8ImageToF64Parallel(
    allocator: std.mem.Allocator,
    input: []const u8,
    output: []f64,
    worker_count: usize,
) !void {
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(U8ToF64RangeContext, worker_count);
    defer allocator.free(contexts);
    var started: usize = 0;
    errdefer {
        for (threads[0..started]) |thread| {
            thread.join();
        }
    }
    for (0..worker_count) |worker_index| {
        const start = input.len * worker_index / worker_count;
        const end = input.len * (worker_index + 1) / worker_count;
        contexts[worker_index] = .{
            .input = input,
            .output = output,
            .start = start,
            .end = end,
        };
        threads[worker_index] = try std.Thread.spawn(.{}, u8ImageToF64Worker, .{&contexts[worker_index]});
        started += 1;
    }
    for (threads) |thread| {
        thread.join();
    }
}

fn u8ImageToF64Worker(context: *const U8ToF64RangeContext) void {
    fillU8ToF64Range(context.input, context.output, context.start, context.end);
}

fn fillU8ToF64Range(input: []const u8, output: []f64, start: usize, end: usize) void {
    const VecU32 = @Vector(f64_simd_width, u32);
    const VecF64 = @Vector(f64_simd_width, f64);
    const inv_255: VecF64 = @splat(1.0 / 255.0);
    var index = start;
    while (index + f64_simd_width <= end) : (index += f64_simd_width) {
        const values_u32: VecU32 = .{
            input[index],
            input[index + 1],
            input[index + 2],
            input[index + 3],
        };
        const values_f64: VecF64 = @floatFromInt(values_u32);
        const scaled = values_f64 * inv_255;
        inline for (0..f64_simd_width) |lane| {
            output[index + lane] = scaled[lane];
        }
    }
    for (input[index..end], output[index..end]) |value, *out| {
        out.* = u8_to_unit_f64[value];
    }
}

fn fillSyntheticFrame(image: []f64, width: usize, height: usize, frame: PreviewSelection, value: f64) void {
    if (@abs(frame.angle) <= 1e-12) {
        fillRect(image, width, height, .{
            .x = frame.x,
            .y = frame.y,
            .width = frame.w,
            .height = frame.h,
        }, value);
        return;
    }

    const cx = frame.x + frame.w / 2.0;
    const cy = frame.y + frame.h / 2.0;
    const half_w = frame.w / 2.0;
    const half_h = frame.h / 2.0;
    const cos_a = std.math.cos(frame.angle);
    const sin_a = std.math.sin(frame.angle);
    const extent_x = @abs(half_w * cos_a) + @abs(half_h * sin_a) + 2.0;
    const extent_y = @abs(half_w * sin_a) + @abs(half_h * cos_a) + 2.0;

    var x0: i64 = @intFromFloat(@floor(cx - extent_x));
    var x1: i64 = @intFromFloat(@ceil(cx + extent_x));
    var y0: i64 = @intFromFloat(@floor(cy - extent_y));
    var y1: i64 = @intFromFloat(@ceil(cy + extent_y));
    x0 = @max(0, x0);
    y0 = @max(0, y0);
    x1 = @min(@as(i64, @intCast(width)), x1);
    y1 = @min(@as(i64, @intCast(height)), y1);
    if (x1 <= x0 or y1 <= y0) return;

    for (@as(usize, @intCast(y0))..@as(usize, @intCast(y1))) |y| {
        const py = @as(f64, @floatFromInt(y)) + 0.5;
        for (@as(usize, @intCast(x0))..@as(usize, @intCast(x1))) |x| {
            const px = @as(f64, @floatFromInt(x)) + 0.5;
            const dx = px - cx;
            const dy = py - cy;
            const local_x = dx * cos_a + dy * sin_a;
            const local_y = -dx * sin_a + dy * cos_a;
            if (@abs(local_x) <= half_w and @abs(local_y) <= half_h) {
                image[y * width + x] = value;
            }
        }
    }
}

fn fillRect(image: []f64, width: usize, height: usize, rect: RebateMaskRect, value: f64) void {
    var x0: i64 = @intFromFloat(rect.x);
    var y0: i64 = @intFromFloat(rect.y);
    var x1: i64 = x0 + @as(i64, @intFromFloat(rect.width));
    var y1: i64 = y0 + @as(i64, @intFromFloat(rect.height));
    x0 = @max(0, x0);
    y0 = @max(0, y0);
    x1 = @min(@as(i64, @intCast(width)), x1);
    y1 = @min(@as(i64, @intCast(height)), y1);
    if (x1 <= x0 or y1 <= y0) return;
    for (@as(usize, @intCast(y0))..@as(usize, @intCast(y1))) |y| {
        for (@as(usize, @intCast(x0))..@as(usize, @intCast(x1))) |x| {
            image[y * width + x] = value;
        }
    }
}

fn countExactPixels(image: []const f64, value: f64) usize {
    var count: usize = 0;
    for (image) |pixel| {
        if (pixel == value) count += 1;
    }
    return count;
}

fn expectRebateOriginRect(expected: RebateOriginRect, actual: RebateOriginRect, tolerance: f64) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, tolerance);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, tolerance);
    try std.testing.expectApproxEqAbs(expected.w, actual.w, tolerance);
    try std.testing.expectApproxEqAbs(expected.h, actual.h, tolerance);
    try std.testing.expectApproxEqAbs(expected.angle, actual.angle, tolerance);
}

fn expectFormat(
    actual: FilmFormat,
    name: []const u8,
    frame_mm: [2]f64,
    pitch_mm: f64,
    strip_width_mm: f64,
    description: []const u8,
) !void {
    try std.testing.expectEqualStrings(name, actual.name);
    try std.testing.expectEqual(frame_mm[0], actual.frame_mm[0]);
    try std.testing.expectEqual(frame_mm[1], actual.frame_mm[1]);
    try std.testing.expectEqual(pitch_mm, actual.pitch_mm);
    try std.testing.expectEqual(strip_width_mm, actual.strip_width_mm);
    try std.testing.expectEqualStrings(description, actual.description);
}

test "ports Python frame format constants" {
    try std.testing.expectEqual(@as(usize, 5), formats.len);
    try expectFormat(formats[0], "35mm", .{ 36.0, 24.0 }, 38.0, 35.0, "35mm (135 film)");
    try expectFormat(formats[1], "645", .{ 56.0, 41.5 }, 60.0, 61.5, "645 medium format");
    try expectFormat(formats[2], "6x6", .{ 56.0, 56.0 }, 60.0, 61.5, "6x6 medium format");
    try expectFormat(formats[3], "6x7", .{ 56.0, 69.0 }, 73.0, 61.5, "6x7 medium format");
    try expectFormat(formats[4], "6x9", .{ 56.0, 84.0 }, 88.0, 61.5, "6x9 medium format");
}

test "looks up frame formats by Python key" {
    const medium_square = formatByName("6x6").?;
    try std.testing.expectEqualStrings("6x6 medium format", medium_square.description);
    try std.testing.expect(formatByName("35_mm") == null);
}

test "computes strip-analysis format ratios" {
    const f35 = formatByName("35mm").?;
    try std.testing.expectEqual(@as(f64, 24.0), f35.narrowMm());
    try std.testing.expectEqual(@as(f64, 36.0), f35.wideMm());
    try std.testing.expectEqual(@as(f64, 2.0), f35.gapMm());
    try std.testing.expectApproxEqAbs(@as(f64, 35.0 / 36.0), f35.pitchRatio(), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), f35.physicalAspect(), 1e-12);

    const f645 = formatByName("645").?;
    try std.testing.expectEqual(@as(f64, 41.5), f645.narrowMm());
    try std.testing.expectEqual(@as(f64, 56.0), f645.wideMm());
    try std.testing.expectEqual(@as(f64, 4.0), f645.gapMm());
    try std.testing.expectApproxEqAbs(@as(f64, 61.5 / 56.0), f645.pitchRatio(), 1e-12);

    const f6x9 = formatByName("6x9").?;
    try std.testing.expectEqual(@as(f64, 56.0), f6x9.narrowMm());
    try std.testing.expectEqual(@as(f64, 84.0), f6x9.wideMm());
    try std.testing.expectEqual(@as(f64, 4.0), f6x9.gapMm());
    try std.testing.expectApproxEqAbs(@as(f64, 61.5 / 84.0), f6x9.pitchRatio(), 1e-12);
}

test "prepares detection grayscale inputs against Python fixture" {
    try expectDetectionGrayFixture("test/fixtures/processing/frames/detection-gray-preprocess-smoke.json");
}

test "resizes preview images with OpenCV INTER_AREA parity" {
    try expectAreaResizeFixture("test/fixtures/processing/frames/area-resize-smoke.json");
}

test "rejects invalid detection grayscale inputs" {
    var data = [_]u8{ 0, 1, 2 };
    try std.testing.expectError(error.InvalidDetectionGrayInput, prepareDetectionGray(std.testing.allocator, &data, 0, 1, 1, 8, .{}));
    try std.testing.expectError(error.InvalidDetectionGrayInput, prepareDetectionGray(std.testing.allocator, &data, 1, 1, 2, 8, .{}));
    try std.testing.expectError(error.InvalidDetectionGrayInput, prepareDetectionGray(std.testing.allocator, &data, 1, 1, 1, 12, .{}));
    try std.testing.expectError(error.InvalidDetectionGrayInput, prepareDetectionGray(std.testing.allocator, &data, 2, 1, 1, 8, .{}));
}

test "rejects invalid area resize inputs" {
    var data = [_]u8{0};
    try std.testing.expectError(error.InvalidAreaResizeInput, resizeImageArea(std.testing.allocator, &data, 0, 1, 1, 8, 1, 1));
    try std.testing.expectError(error.InvalidAreaResizeInput, resizeImageArea(std.testing.allocator, &data, 1, 1, 4, 8, 1, 1));
    try std.testing.expectError(error.InvalidAreaResizeInput, resizeImageArea(std.testing.allocator, &data, 1, 1, 1, 12, 1, 1));
    try std.testing.expectError(error.InvalidAreaResizeInput, resizeImageArea(std.testing.allocator, &data, 1, 1, 1, 8, 2, 1));
    try std.testing.expectError(error.InvalidAreaResizeInput, resizeImageArea(std.testing.allocator, &data, 2, 1, 1, 8, 1, 1));
}

test "applies OpenCV-style CLAHE against Python fixture" {
    try expectClaheFixture("test/fixtures/processing/frames/clahe-8bit-smoke.json");
}

test "rejects invalid CLAHE inputs" {
    var data = [_]u8{0};
    try std.testing.expectError(error.InvalidClaheInput, applyClahe8(std.testing.allocator, &data, 0, 1, .{}));
    try std.testing.expectError(error.InvalidClaheInput, applyClahe8(std.testing.allocator, &data, 1, 1, .{ .tiles_x = 0 }));
    try std.testing.expectError(error.InvalidClaheInput, applyClahe8(std.testing.allocator, &data, 1, 1, .{ .tiles_y = 0 }));
    try std.testing.expectError(error.InvalidClaheInput, applyClahe8(std.testing.allocator, &data, 2, 1, .{}));
}

test "applies detect_frames rotation-back transform against Python fixture" {
    try expectRotationBackFixture("test/fixtures/processing/frames/rotation-back-transform-smoke.json");
}

test "rejects invalid rotation-back transform inputs" {
    try std.testing.expectError(error.InvalidRotationTransformInput, expandedRotationTransform(0, 10, 0.1));
    try std.testing.expectError(error.InvalidRotationTransformInput, expandedRotationTransform(10, 10, std.math.nan(f64)));
    var frames = [_]FrameRect{.{ .cx = std.math.inf(f64), .cy = 1.0, .w = 1.0, .h = 1.0, .angle = 0.0 }};
    try std.testing.expectError(error.InvalidRotationTransformInput, transformFramesFromRotatedToOriginal(&frames, .{ .values = .{ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0 } }, 0.0));
}

test "rotates image into expanded replicate-border canvas against Python fixture" {
    try expectExpandedRotationResampleFixture("test/fixtures/processing/frames/expanded-rotation-resample-smoke.json");
}

test "matches OpenCV square binary close used by film extent detection" {
    try expectBinaryCloseFixture("test/fixtures/processing/frames/film-extent-close-binary-smoke.json");
}

test "detects axis-aligned film extent against synthetic fixture" {
    try expectFilmExtentFixture("test/fixtures/processing/frames/film-extent-axis-aligned-smoke.json");
}

test "detects rotated film extent angle against synthetic fixture" {
    try expectFilmExtentFixture("test/fixtures/processing/frames/film-extent-rotated-smoke.json");
}

test "detects rotated image-buffer frames and transforms them back" {
    try expectRotatedWrapperDetectionFixture("test/fixtures/processing/frames/rotated-wrapper-detect-smoke.json");
}

test "pins frozen detect_frames work scale as no-op" {
    try std.testing.expectEqual(@as(f64, 1.0), try detectFramesWorkScale(100, 300));
    try std.testing.expectEqual(@as(f64, 1.0), try detectFramesWorkScale(300, 100));
    try std.testing.expectEqual(@as(f64, 1.0), try detectFramesWorkScale(4000, 6000));
    try std.testing.expectError(error.InvalidDetectFramesInput, detectFramesWorkScale(0, 10));
}

test "formats detect_frames aspect string like Python result" {
    try std.testing.expectEqualStrings("24:36", detectFramesAspect(format_35mm, true));
    try std.testing.expectEqualStrings("36:24", detectFramesAspect(format_35mm, false));
    try std.testing.expectEqualStrings("41.5:56", detectFramesAspect(format_645, true));
    try std.testing.expectEqualStrings("56:41.5", detectFramesAspect(format_645, false));
    try std.testing.expectEqualStrings("56:56", detectFramesAspect(format_6x6, true));
    try std.testing.expectEqualStrings("56:56", detectFramesAspect(format_6x6, false));
    try std.testing.expectEqualStrings("56:69", detectFramesAspect(format_6x7, true));
    try std.testing.expectEqualStrings("84:56", detectFramesAspect(format_6x9, false));
}

test "computes vertical strip profiles against Python fixture" {
    try expectStripProfileFixture("test/fixtures/processing/frames/strip-profiles-vertical.json");
}

test "computes horizontal strip profiles against Python fixture" {
    try expectStripProfileFixture("test/fixtures/processing/frames/strip-profiles-horizontal.json");
}

test "rejects invalid strip profile inputs" {
    var pixel = [_]f64{1.0};
    try std.testing.expectError(error.InvalidFrameProfileBuffer, computeStripProfiles(std.testing.allocator, &pixel, 0, 1, true));
    try std.testing.expectError(error.InvalidFrameProfileBuffer, computeStripProfiles(std.testing.allocator, &pixel, 2, 1, true));
    try std.testing.expectError(error.InvalidFrameProfileBand, computeStripProfiles(std.testing.allocator, &pixel, 1, 1, true));
}

test "aligns frame pitch with subsequence DTW against Python fixture" {
    try expectDtwFixture("test/fixtures/processing/frames/dtw-pitch-35mm-two-frame.json");
}

test "rejects invalid DTW inputs" {
    try std.testing.expectError(error.InvalidDtwInput, alignPitchDtw(std.testing.allocator, &.{}, 1, format_35mm, 1, .{}));
    try std.testing.expectError(error.InvalidDtwInput, alignPitchDtw(std.testing.allocator, &.{1.0}, 0, format_35mm, 1, .{}));
    try std.testing.expectError(error.InvalidDtwInput, alignPitchDtw(std.testing.allocator, &.{1.0}, 1, format_35mm, 0, .{}));
    try std.testing.expectError(error.InvalidDtwInput, alignPitchDtw(std.testing.allocator, &.{1.0}, 1, format_35mm, 1, .{ .max_len = 0 }));
}

test "snaps DTW edges to gradient peaks against Python fixture" {
    try expectGradientSnapFixture("test/fixtures/processing/frames/gradient-snap-internal-peaks.json");
    try expectGradientSnapFixture("test/fixtures/processing/frames/gradient-snap-scipy-prominence-bounds.json");
}

test "rejects invalid gradient snap inputs" {
    var out = [_]usize{0};
    try std.testing.expectError(error.InvalidGradientSnapInput, snapEdgesToGradients(&.{}, &.{1}, &out, 10.0));
    try std.testing.expectError(error.InvalidGradientSnapInput, snapEdgesToGradients(&.{1.0}, &.{1}, &.{}, 10.0));
    try std.testing.expectError(error.InvalidGradientSnapInput, snapEdgesToGradients(&.{1.0}, &.{1}, &out, 0.0));
}

test "selects Gaussian-weighted peaks against Python fixture" {
    try expectWeightedPeakFixture("test/fixtures/processing/frames/gaussian-weighted-peak-smoke.json");
}

test "rejects invalid weighted peak inputs" {
    try std.testing.expectError(error.InvalidWeightedPeakInput, snapToWeightedPeak(&.{}, 0, 1, 1.0));
    try std.testing.expectError(error.InvalidWeightedPeakInput, snapToWeightedPeak(&.{1.0}, 0, 1, 0.0));
}

test "repairs inconsistent frame sizes against Python fixture" {
    try expectSizeCorrectionFixture("test/fixtures/processing/frames/size-consistency-correction-smoke.json");
}

test "rejects invalid size correction inputs" {
    var positions = [_]usize{ 0, 1 };
    try std.testing.expectError(error.InvalidSizeCorrectionInput, applySizeConsistencyCorrection(&.{}, &positions, 1, 10.0));
    try std.testing.expectError(error.InvalidSizeCorrectionInput, applySizeConsistencyCorrection(&.{1.0}, &positions, 1, 0.0));
}

test "repairs first and last frame edges against Python fixture" {
    try expectTerminalRepairFixture("test/fixtures/processing/frames/terminal-frame-repair-smoke.json");
}

test "rejects invalid terminal frame repair inputs" {
    var positions = [_]usize{ 0, 1 };
    try std.testing.expectError(error.InvalidTerminalRepairInput, repairTerminalFrames(std.testing.allocator, &.{}, &positions, 1, 10.0, 1, 10.0));
    try std.testing.expectError(error.InvalidTerminalRepairInput, repairTerminalFrames(std.testing.allocator, &.{1.0}, &positions, 1, 0.0, 1, 10.0));
    try std.testing.expectError(error.InvalidTerminalRepairInput, repairTerminalFrames(std.testing.allocator, &.{1.0}, &positions, 1, 10.0, 1, 0.0));
}

test "measures cross-strip paired-gradient edges against Python fixture" {
    try expectCrossStripFixture("test/fixtures/processing/frames/cross-strip-paired-gradient-smoke.json");
}

test "rejects invalid cross-strip inputs" {
    try std.testing.expectError(error.InvalidCrossStripInput, measureCrossStripEdges(std.testing.allocator, &.{ 0.0, 1.0 }, 10.0, 1));
    try std.testing.expectError(error.InvalidCrossStripInput, measureCrossStripEdges(std.testing.allocator, &.{ 0.0, 1.0, 0.0 }, 0.0, 1));
}

test "estimates Theil-Sen frame angle against Python fixture" {
    try expectTheilSenFixture("test/fixtures/processing/frames/theil-sen-angle-smoke.json");
}

test "handles missing Theil-Sen slopes and invalid options" {
    try std.testing.expect((try estimateAngleTheilSen(std.testing.allocator, &.{}, 0.1)) == null);
    try std.testing.expect((try estimateAngleTheilSen(std.testing.allocator, &.{ .{ .x = 1.0, .y = 1.0 }, .{ .x = 1.5, .y = 2.0 } }, 0.1)) == null);
    try std.testing.expectError(error.InvalidTheilSenInput, estimateAngleTheilSen(std.testing.allocator, &.{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 2.0, .y = 1.0 } }, 0.0));
}

test "applies single-frame fallback guard against Python fixture" {
    try expectSingleFrameFallbackFixture("test/fixtures/processing/frames/single-frame-fallback-smoke.json");
}

test "preserves single-frame fallback boundaries" {
    const preview_w = 100.0;
    const preview_h = 100.0;
    try std.testing.expect((try singleFrameFallback(2, .{ .cx = 0.0, .cy = 0.0, .w = 10.0, .h = 10.0, .angle = 0.0 }, preview_w, preview_h)) == null);
    try std.testing.expect((try singleFrameFallback(1, .{ .cx = 0.0, .cy = 0.0, .w = 30.0, .h = 100.0, .angle = 0.0 }, preview_w, preview_h)) == null);
    try std.testing.expectError(error.InvalidSingleFrameFallbackInput, singleFrameFallback(1, .{ .cx = 0.0, .cy = 0.0, .w = 1.0, .h = 1.0, .angle = 0.0 }, 0.0, preview_h));
}

test "crops rotated rectangle against Python fixture" {
    try expectRotatedCropFixture("test/fixtures/processing/frames/rotated-rect-crop-smoke.json");
}

test "rejects invalid rotated crop inputs" {
    try std.testing.expectError(error.InvalidRotatedCropInput, cropRotatedRect(std.testing.allocator, &.{}, 0, 1, 0.0, 0.0, 1.0, 1.0, 0.0));
    try std.testing.expectError(error.InvalidRotatedCropInput, cropRotatedRect(std.testing.allocator, &.{1.0}, 1, 1, 0.0, 0.0, 0.0, 1.0, 0.0));
}

test "ports rebate helper behavior against fixture" {
    try expectRebateHelpersFixture("test/fixtures/processing/frames/rebate-helpers-smoke.json");
}

test "handles empty rebate helper cases" {
    try std.testing.expect((try makeRebateMask(std.testing.allocator, 4, 4, null)) == null);
    try std.testing.expect((try makeRebateMask(std.testing.allocator, 4, 4, .{ .x = 0.0, .y = 0.0, .width = 0.0, .height = 2.0 })) == null);
    try std.testing.expect(!rebateInBounds(10, 10, .{ .x = -20.0, .y = 0.0, .w = 2.0, .h = 2.0 }));
    try std.testing.expect(computeInterFrameRebate(&.{}) == null);
    try std.testing.expect(computeInterFrameRebate(&.{
        .{ .cx = 0.0, .cy = 0.0, .w = 10.0, .h = 10.0, .angle = 0.0 },
        .{ .cx = 0.0, .cy = 5.0, .w = 10.0, .h = 10.0, .angle = 0.0 },
    }) == null);
}

test "ports preview-to-full coordinate scaling against Python fixture" {
    try expectPreviewScalingFixture("test/fixtures/processing/frames/preview-coordinate-scaling-smoke.json");
}

test "rejects invalid preview coordinate scaling inputs" {
    try std.testing.expectError(error.InvalidPreviewGeometry, computePreviewGeometry(0, 1, 8192));
    try std.testing.expectError(error.InvalidPreviewGeometry, computePreviewGeometry(1, 0, 8192));
    try std.testing.expectError(error.InvalidPreviewScale, previewFrameToFullResolution(.{ .cx = 1.0, .cy = 1.0, .w = 1.0, .h = 1.0, .angle = 0.0 }, 0.0));
    try std.testing.expectError(error.InvalidPreviewScale, previewSelectionToFullResolution(.{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0, .angle = 0.0 }, -1.0));
    try std.testing.expectError(error.InvalidPreviewScale, previewRebateToFullResolution(.{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0, .angle = 0.0 }, std.math.nan(f64)));
}

test "pins test_detect ground truth conversion and scoring semantics" {
    try expectTestDetectGroundTruthFixture("test/fixtures/processing/frames/test-detect-ground-truth.json");
}

test "matches test_detect scan_0006 detector parity when local scan fixture exists" {
    try expectScanDetectorParity("test/fixtures/processing/frames/test-detect-python-output.json", "scans/scan_0006_rgbir_800dpi.tiff");
}

test "matches test_detect scan_0001 detector parity when local scan fixture exists" {
    try expectScanDetectorParity("test/fixtures/processing/frames/test-detect-python-output.json", "scans/scan_0001_rgbir_3200dpi.tiff");
}

test "matches test_detect scan_0003 detector parity when local scan fixture exists" {
    try expectScanDetectorParity("test/fixtures/processing/frames/test-detect-python-output.json", "scans/scan_0003_rgbir_3200dpi.tiff");
}

test "matches test_detect scan_0004 detector parity when local scan fixture exists" {
    try expectScanDetectorParity("test/fixtures/processing/frames/test-detect-python-output.json", "scans/scan_0004_rgbir_3200dpi.tiff");
}

test "validates synthetic frame detection fixtures without scan TIFFs" {
    try expectSyntheticDetectionFixture("test/fixtures/processing/frames/synthetic-detection-fixtures.json");
}

test "runs axis-aligned detector wiring on synthetic fixtures" {
    try expectAxisAlignedDetectionFixture("test/fixtures/processing/frames/axis-aligned-detect-smoke.json");
}

test "ports strip analysis and initial placement against Python fixture" {
    try expectStripAnalysisFixture("test/fixtures/processing/frames/strip-analysis-initial-placement-smoke.json");
}

test "rejects invalid strip analysis and initial placement inputs" {
    try std.testing.expectError(error.InvalidStripAnalysisInput, analyzeStrip(0, 1, format_35mm, null));
    try std.testing.expectError(error.InvalidStripAnalysisInput, analyzeStrip(1, 0, format_35mm, null));
    try std.testing.expectError(error.InvalidStripAnalysisInput, analyzeStrip(1, 1, format_35mm, .{ .strip_narrow_px = 0.0, .strip_long_px = 10.0, .strip_angle = 0.0 }));
    try std.testing.expectError(error.InvalidInitialPlacementInput, initialPlacement(std.testing.allocator, 1, 1, 0, .{
        .n_frames = 1,
        .frame_w = 1.0,
        .frame_h = 1.0,
        .pitch_px = 1.0,
        .is_vertical = true,
    }, 0.0));
}
