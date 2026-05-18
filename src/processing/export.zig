const std = @import("std");

const film_stocks = @import("film_stocks.zig");
const frames = @import("frames.zig");
const inversion = @import("inversion.zig");
const ir_processing = @import("ir.zig");
const numeric = @import("numeric_fixture.zig");
const render = @import("render.zig");
const tiff = @import("../tiff.zig");
const webgpu = @import("webgpu.zig");

pub const ExportVariant = enum {
    ir_neg,
    ir_inv,
    inv_only,

    pub fn suffix(self: ExportVariant) []const u8 {
        return switch (self) {
            .ir_neg => "_ir",
            .ir_inv => "",
            .inv_only => "_inv",
        };
    }

    pub fn metadataVariant(self: ExportVariant) []const u8 {
        return switch (self) {
            .ir_neg => "ir_cleaned",
            .ir_inv => "ir_cleaned_inverted",
            .inv_only => "inverted",
        };
    }
};

pub const OutputSelection = struct {
    ir_neg: bool = false,
    ir_inv: bool = true,
    inv_only: bool = false,

    pub fn any(self: OutputSelection) bool {
        return self.ir_neg or self.ir_inv or self.inv_only;
    }

    pub fn needIr(self: OutputSelection) bool {
        return self.ir_neg or self.ir_inv;
    }

    pub fn needInvert(self: OutputSelection) bool {
        return self.ir_inv or self.inv_only;
    }

    pub fn enabled(self: OutputSelection, variant: ExportVariant) bool {
        return switch (variant) {
            .ir_neg => self.ir_neg,
            .ir_inv => self.ir_inv,
            .inv_only => self.inv_only,
        };
    }

    pub fn enabledVariants(self: OutputSelection, buffer: *[3]ExportVariant) []ExportVariant {
        var len: usize = 0;
        const order = [_]ExportVariant{ .ir_neg, .ir_inv, .inv_only };
        for (order) |variant| {
            if (!self.enabled(variant)) continue;
            buffer[len] = variant;
            len += 1;
        }
        return buffer[0..len];
    }
};

pub const FrameRect = struct {
    cx: f64,
    cy: f64,
    w: f64,
    h: f64,
    angle: f64 = 0.0,
    rotation: i32 = 0,
};

pub const ExportRequest = struct {
    basename: []const u8,
    rects: []const FrameRect,
    outputs: OutputSelection = .{},
};

pub const OutputPaths = struct {
    ir_neg: ?[]const u8 = null,
    ir_inv: ?[]const u8 = null,
    inv_only: ?[]const u8 = null,

    pub fn path(self: OutputPaths, variant: ExportVariant) ![]const u8 {
        return switch (variant) {
            .ir_neg => self.ir_neg orelse error.MissingExportPath,
            .ir_inv => self.ir_inv orelse error.MissingExportPath,
            .inv_only => self.inv_only orelse error.MissingExportPath,
        };
    }
};

pub const BaseMetadata = struct {
    source: []const u8,
    rebate_rect: ?frames.RebateOriginRect = null,
    crop: FrameRect,
};

pub const ProcessFrameOptions = struct {
    outputs: OutputSelection = .{},
    paths: OutputPaths,
    base_meta: BaseMetadata,
    film_stock: ?[]const u8 = null,
    stock_coeffs: ?film_stocks.Coefficients = null,
    dmin: ?[3]f64 = null,
    render_options: render.RenderToDisplayOptions = .{},
    ir_clean_options: ir_processing.IrCleanOptions = .{},
    invert_request: webgpu.Request = .{},
    captured_noise: ?[]const f64 = null,
    random: ?std.Random = null,
};

pub const ProcessFrameResult = struct {
    written: [][]u8,
    shape_width: usize,
    shape_height: usize,

    pub fn deinit(self: ProcessFrameResult, allocator: std.mem.Allocator) void {
        for (self.written) |name| allocator.free(name);
        allocator.free(self.written);
    }
};

pub const Image = struct {
    width: usize,
    height: usize,
    channels: usize,
    pixels: []f64,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const ImageU16 = struct {
    width: usize,
    height: usize,
    channels: usize,
    pixels: []u16,

    pub fn deinit(self: ImageU16, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const GalleryFileList = struct {
    files: [][]u8,

    pub fn deinit(self: GalleryFileList, allocator: std.mem.Allocator) void {
        for (self.files) |file| allocator.free(file);
        allocator.free(self.files);
    }
};

pub const GalleryMutation = struct {
    file_name: []u8,
    message: []u8,

    pub fn deinit(self: GalleryMutation, allocator: std.mem.Allocator) void {
        allocator.free(self.file_name);
        allocator.free(self.message);
    }
};

pub const ExportProgressKind = enum {
    preparing,
    aligning_ir,
    processing,
    wrote_file,
    complete,
};

pub const ExportProgressEvent = struct {
    kind: ExportProgressKind,
    message: []u8,
    file_name: ?[]u8 = null,
};

pub const ExportProgressList = struct {
    events: []ExportProgressEvent,

    pub fn deinit(self: ExportProgressList, allocator: std.mem.Allocator) void {
        for (self.events) |event| {
            allocator.free(event.message);
            if (event.file_name) |name| allocator.free(name);
        }
        allocator.free(self.events);
    }
};

pub fn activeStockForExport(outputs: OutputSelection, active_stock: ?[]const u8) ?[]const u8 {
    return if (outputs.needInvert()) active_stock else null;
}

pub fn cropFrame(
    allocator: std.mem.Allocator,
    image: []const f64,
    width: usize,
    height: usize,
    channels: usize,
    rect: FrameRect,
) !Image {
    if (width == 0 or height == 0 or channels == 0 or image.len != width * height * channels) {
        return error.InvalidExportImage;
    }

    const out_width: usize = @intFromFloat(rect.w);
    const out_height: usize = @intFromFloat(rect.h);
    if (out_width == 0 or out_height == 0) return error.InvalidExportImage;

    const output = try allocator.alloc(f64, out_width * out_height * channels);
    errdefer allocator.free(output);
    const plane = try allocator.alloc(f64, width * height);
    defer allocator.free(plane);

    for (0..channels) |channel| {
        for (0..height) |y| {
            for (0..width) |x| {
                plane[y * width + x] = image[(y * width + x) * channels + channel];
            }
        }
        var cropped = try frames.cropRotatedRect(allocator, plane, width, height, rect.cx, rect.cy, rect.w, rect.h, rect.angle);
        defer cropped.deinit(allocator);
        if (cropped.width != out_width or cropped.height != out_height) return error.InvalidExportImage;
        for (0..out_height) |y| {
            for (0..out_width) |x| {
                output[(y * out_width + x) * channels + channel] = cropped.pixels[y * out_width + x];
            }
        }
    }

    return .{ .width = out_width, .height = out_height, .channels = channels, .pixels = output };
}

pub fn applyRotation(
    allocator: std.mem.Allocator,
    image: []const f64,
    width: usize,
    height: usize,
    channels: usize,
    rotation: i32,
) !Image {
    if (width == 0 or height == 0 or channels == 0 or image.len != width * height * channels) {
        return error.InvalidExportImage;
    }

    const out_width = if (rotation == 90 or rotation == 270) height else width;
    const out_height = if (rotation == 90 or rotation == 270) width else height;
    const output = try allocator.alloc(f64, out_width * out_height * channels);
    errdefer allocator.free(output);

    const Point = struct { x: usize, y: usize };
    for (0..out_height) |y| {
        for (0..out_width) |x| {
            const src: Point = switch (rotation) {
                0 => .{ .x = x, .y = y },
                90 => .{ .x = y, .y = height - 1 - x },
                180 => .{ .x = width - 1 - x, .y = height - 1 - y },
                270 => .{ .x = width - 1 - y, .y = x },
                else => .{ .x = x, .y = y },
            };
            for (0..channels) |channel| {
                output[(y * out_width + x) * channels + channel] = image[(src.y * width + src.x) * channels + channel];
            }
        }
    }

    return .{ .width = out_width, .height = out_height, .channels = channels, .pixels = output };
}

pub fn applyRotationU16(
    allocator: std.mem.Allocator,
    image: []const u16,
    width: usize,
    height: usize,
    channels: usize,
    rotation: i32,
) !ImageU16 {
    if (width == 0 or height == 0 or channels == 0 or image.len != width * height * channels) {
        return error.InvalidExportImage;
    }

    const out_width = if (rotation == 90 or rotation == 270) height else width;
    const out_height = if (rotation == 90 or rotation == 270) width else height;
    const output = try allocator.alloc(u16, out_width * out_height * channels);
    errdefer allocator.free(output);

    const Point = struct { x: usize, y: usize };
    for (0..out_height) |y| {
        for (0..out_width) |x| {
            const src: Point = switch (rotation) {
                0 => .{ .x = x, .y = y },
                90 => .{ .x = y, .y = height - 1 - x },
                180 => .{ .x = width - 1 - x, .y = height - 1 - y },
                270 => .{ .x = width - 1 - y, .y = x },
                else => .{ .x = x, .y = y },
            };
            for (0..channels) |channel| {
                output[(y * out_width + x) * channels + channel] = image[(src.y * width + src.x) * channels + channel];
            }
        }
    }

    return .{ .width = out_width, .height = out_height, .channels = channels, .pixels = output };
}

pub fn prepareRgbNegativeOutput(allocator: std.mem.Allocator, raw_crop: Image, rotation: i32) !Image {
    return applyRotation(allocator, raw_crop.pixels, raw_crop.width, raw_crop.height, raw_crop.channels, rotation);
}

pub fn prepareIrCleanedNegativeOutput(
    allocator: std.mem.Allocator,
    raw_crop: Image,
    ir_cleaned: ?Image,
    rotation: i32,
) !Image {
    const source = ir_cleaned orelse raw_crop;
    return applyRotation(allocator, source.pixels, source.width, source.height, source.channels, rotation);
}

pub fn prepareIrCleanedRegionWithNoise(
    allocator: std.mem.Allocator,
    raw_crop: Image,
    ir_crop: Image,
    captured_noise: []const f64,
    options: ir_processing.IrCleanOptions,
) !Image {
    if (raw_crop.channels != 3 or ir_crop.channels != 1) return error.InvalidExportImage;
    const output = try allocator.alloc(f64, raw_crop.pixels.len);
    errdefer allocator.free(output);
    _ = try ir_processing.irCleanRegionWithNoise(
        allocator,
        raw_crop.pixels,
        raw_crop.width,
        raw_crop.height,
        ir_crop.pixels,
        ir_crop.width,
        ir_crop.height,
        output,
        null,
        captured_noise,
        options,
    );
    return .{
        .width = raw_crop.width,
        .height = raw_crop.height,
        .channels = raw_crop.channels,
        .pixels = output,
    };
}

pub fn prepareIrCleanedRegion(
    allocator: std.mem.Allocator,
    random: std.Random,
    raw_crop: Image,
    ir_crop: Image,
    options: ir_processing.IrCleanOptions,
) !Image {
    if (raw_crop.channels != 3 or ir_crop.channels != 1) return error.InvalidExportImage;
    const output = try allocator.alloc(f64, raw_crop.pixels.len);
    errdefer allocator.free(output);
    _ = try ir_processing.irCleanRegion(
        allocator,
        random,
        raw_crop.pixels,
        raw_crop.width,
        raw_crop.height,
        ir_crop.pixels,
        ir_crop.width,
        ir_crop.height,
        output,
        null,
        options,
    );
    return .{
        .width = raw_crop.width,
        .height = raw_crop.height,
        .channels = raw_crop.channels,
        .pixels = output,
    };
}

pub fn prepareInvertedPositiveOutput(
    allocator: std.mem.Allocator,
    crop: Image,
    invert_options: inversion.InvertOptions,
    render_options: render.RenderToDisplayOptions,
    rotation: i32,
) !Image {
    if (crop.channels != 3) return error.InvalidExportImage;

    const scene_linear = try allocator.alloc(f64, crop.pixels.len);
    defer allocator.free(scene_linear);
    _ = try inversion.invertNegative(allocator, crop.pixels, scene_linear, invert_options);

    const rendered_u16 = try allocator.alloc(u16, crop.pixels.len);
    defer allocator.free(rendered_u16);
    try render.renderToDisplay(allocator, scene_linear, rendered_u16, render_options);

    const rendered = try allocator.alloc(f64, crop.pixels.len);
    defer allocator.free(rendered);
    for (rendered_u16, rendered) |value, *out| {
        out.* = @floatFromInt(value);
    }

    return applyRotation(allocator, rendered, crop.width, crop.height, crop.channels, rotation);
}

pub fn prepareInvertedPositiveOutputU16(
    allocator: std.mem.Allocator,
    crop: Image,
    invert_options: inversion.InvertOptions,
    render_options: render.RenderToDisplayOptions,
    rotation: i32,
) !ImageU16 {
    if (crop.channels != 3) return error.InvalidExportImage;

    const scene_linear = try allocator.alloc(f64, crop.pixels.len);
    defer allocator.free(scene_linear);
    _ = try inversion.invertNegative(allocator, crop.pixels, scene_linear, invert_options);

    const rendered_u16 = try allocator.alloc(u16, crop.pixels.len);
    defer allocator.free(rendered_u16);
    try render.renderToDisplay(allocator, scene_linear, rendered_u16, render_options);

    return applyRotationU16(allocator, rendered_u16, crop.width, crop.height, crop.channels, rotation);
}

pub fn processFrame(
    allocator: std.mem.Allocator,
    frame_index: usize,
    rect: FrameRect,
    rgb_img: Image,
    aligned_ir: ?Image,
    ir_scale_x: f64,
    ir_scale_y: f64,
    options: ProcessFrameOptions,
) !ProcessFrameResult {
    _ = frame_index;
    if (rgb_img.channels != 3) return error.InvalidExportImage;
    if (aligned_ir) |ir| {
        if (ir.channels != 1) return error.InvalidExportImage;
    }

    var written = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (written.items) |name| allocator.free(name);
        written.deinit();
    }

    const raw_crop = try cropFrame(allocator, rgb_img.pixels, rgb_img.width, rgb_img.height, rgb_img.channels, rect);
    defer raw_crop.deinit(allocator);

    var cleaned_crop: ?Image = null;
    defer if (cleaned_crop) |image| image.deinit(allocator);

    if (options.outputs.needIr()) {
        if (aligned_ir) |ir| {
            const ir_rect = FrameRect{
                .cx = rect.cx * ir_scale_x,
                .cy = rect.cy * ir_scale_y,
                .w = rect.w * ir_scale_x,
                .h = rect.h * ir_scale_y,
                .angle = rect.angle,
                .rotation = rect.rotation,
            };
            const ir_crop = try cropFrame(allocator, ir.pixels, ir.width, ir.height, ir.channels, ir_rect);
            defer ir_crop.deinit(allocator);
            cleaned_crop = if (options.captured_noise) |noise|
                try prepareIrCleanedRegionWithNoise(allocator, raw_crop, ir_crop, noise, options.ir_clean_options)
            else if (options.random) |random|
                try prepareIrCleanedRegion(allocator, random, raw_crop, ir_crop, options.ir_clean_options)
            else
                return error.MissingIrInpaintNoise;
        }
    }

    if (options.outputs.ir_neg) {
        const out = try prepareIrCleanedNegativeOutput(allocator, raw_crop, cleaned_crop, rect.rotation);
        defer out.deinit(allocator);
        const metadata = try exportMetadataJson(allocator, options.base_meta, .ir_neg, options.film_stock, options.render_options.contrast, options.dmin);
        defer allocator.free(metadata);
        const path = try options.paths.path(.ir_neg);
        try writeU16Tiff(allocator, path, out, metadata);
        try written.append(try allocator.dupe(u8, std.fs.path.basename(path)));
    }

    if (options.outputs.ir_inv and options.outputs.needIr()) {
        const source = cleaned_crop orelse raw_crop;
        const out = try prepareInvertedPositiveOutputU16(allocator, source, .{
            .dmin = options.dmin,
            .coeffs = options.stock_coeffs,
            .stock = options.film_stock orelse "kodak_gold",
            .request = options.invert_request,
        }, options.render_options, rect.rotation);
        defer out.deinit(allocator);
        const metadata = try exportMetadataJson(allocator, options.base_meta, .ir_inv, options.film_stock, options.render_options.contrast, options.dmin);
        defer allocator.free(metadata);
        const path = try options.paths.path(.ir_inv);
        try writeU16TiffSamples(allocator, path, out, metadata);
        try written.append(try allocator.dupe(u8, std.fs.path.basename(path)));
    }

    if (options.outputs.inv_only) {
        const out = try prepareInvertedPositiveOutputU16(allocator, raw_crop, .{
            .dmin = options.dmin,
            .coeffs = options.stock_coeffs,
            .stock = options.film_stock orelse "kodak_gold",
            .request = options.invert_request,
        }, options.render_options, rect.rotation);
        defer out.deinit(allocator);
        const metadata = try exportMetadataJson(allocator, options.base_meta, .inv_only, options.film_stock, options.render_options.contrast, options.dmin);
        defer allocator.free(metadata);
        const path = try options.paths.path(.inv_only);
        try writeU16TiffSamples(allocator, path, out, metadata);
        try written.append(try allocator.dupe(u8, std.fs.path.basename(path)));
    }

    return .{
        .written = try written.toOwnedSlice(),
        .shape_width = raw_crop.width,
        .shape_height = raw_crop.height,
    };
}

fn writeU16Tiff(
    allocator: std.mem.Allocator,
    path: []const u8,
    image: Image,
    metadata_json: []const u8,
) !void {
    const samples = try allocator.alloc(u16, image.pixels.len);
    defer allocator.free(samples);
    for (image.pixels, samples) |value, *sample| {
        const clipped = @min(@max(value, 0.0), 65535.0);
        sample.* = @intFromFloat(@round(clipped));
    }
    try tiff.writeImage(allocator, path, .{
        .width = @intCast(image.width),
        .height = @intCast(image.height),
        .samples_per_pixel = @intCast(image.channels),
        .bits_per_sample = 16,
        .data = std.mem.sliceAsBytes(samples),
    }, .{ .metadata_json = metadata_json });
}

fn writeU16TiffSamples(
    allocator: std.mem.Allocator,
    path: []const u8,
    image: ImageU16,
    metadata_json: []const u8,
) !void {
    try tiff.writeImage(allocator, path, .{
        .width = @intCast(image.width),
        .height = @intCast(image.height),
        .samples_per_pixel = @intCast(image.channels),
        .bits_per_sample = 16,
        .data = std.mem.sliceAsBytes(image.pixels),
    }, .{ .metadata_json = metadata_json });
}

fn exportMetadataJson(
    allocator: std.mem.Allocator,
    base_meta: BaseMetadata,
    variant: ExportVariant,
    film_stock: ?[]const u8,
    contrast: f64,
    dmin: ?[3]f64,
) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("{\"source\":");
    try appendJsonString(&out, base_meta.source);
    try out.appendSlice(",\"rebate_rect\":");
    if (base_meta.rebate_rect) |rebate| {
        try appendRebateRectJson(allocator, &out, rebate);
    } else {
        try out.appendSlice("null");
    }
    try out.appendSlice(",\"crop\":{");
    try out.appendSlice("\"cx\":");
    try appendJsonFloat(allocator, &out, base_meta.crop.cx);
    try out.appendSlice(",\"cy\":");
    try appendJsonFloat(allocator, &out, base_meta.crop.cy);
    try out.appendSlice(",\"w\":");
    try appendJsonFloat(allocator, &out, base_meta.crop.w);
    try out.appendSlice(",\"h\":");
    try appendJsonFloat(allocator, &out, base_meta.crop.h);
    try out.appendSlice(",\"angle\":");
    try appendJsonFloat(allocator, &out, base_meta.crop.angle);
    try out.appendSlice("},\"variant\":");
    try appendJsonString(&out, variant.metadataVariant());

    if (variant != .ir_neg) {
        try out.appendSlice(",\"stock\":");
        if (film_stock) |stock| {
            try appendJsonString(&out, stock);
        } else {
            try out.appendSlice("null");
        }
        try out.appendSlice(",\"contrast\":");
        try appendJsonFloat(allocator, &out, contrast);
        try out.appendSlice(",\"dmin\":");
        if (dmin) |values| {
            try out.append('[');
            for (values, 0..) |value, index| {
                if (index != 0) try out.append(',');
                try appendJsonFloat(allocator, &out, value);
            }
            try out.append(']');
        } else {
            try out.appendSlice("null");
        }
    }

    try out.append('}');
    return out.toOwnedSlice();
}

fn appendJsonFloat(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(u8),
    value: f64,
) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try out.appendSlice(text);
}

fn appendJsonString(out: *std.array_list.Managed(u8), value: []const u8) !void {
    try out.append('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => try out.append(byte),
        }
    }
    try out.append('"');
}

fn appendRebateRectJson(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(u8),
    rect: frames.RebateOriginRect,
) !void {
    try out.appendSlice("{\"x\":");
    try appendJsonFloat(allocator, out, rect.x);
    try out.appendSlice(",\"y\":");
    try appendJsonFloat(allocator, out, rect.y);
    try out.appendSlice(",\"w\":");
    try appendJsonFloat(allocator, out, rect.w);
    try out.appendSlice(",\"h\":");
    try appendJsonFloat(allocator, out, rect.h);
    try out.appendSlice(",\"angle\":");
    try appendJsonFloat(allocator, out, rect.angle);
    try out.append('}');
}

pub fn frameFileName(
    allocator: std.mem.Allocator,
    basename: []const u8,
    frame_index: usize,
    variant: ExportVariant,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}_{d:0>2}{s}.tif", .{ basename, frame_index + 1, variant.suffix() });
}

pub fn frameOutputPath(
    allocator: std.mem.Allocator,
    output_dir: []const u8,
    basename: []const u8,
    frame_index: usize,
    variant: ExportVariant,
) ![]u8 {
    const name = try frameFileName(allocator, basename, frame_index, variant);
    defer allocator.free(name);
    if (output_dir.len == 0 or std.mem.eql(u8, output_dir, ".")) {
        return allocator.dupe(u8, name);
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, name });
}

pub fn uniqueFrameOutputPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
    basename: []const u8,
    frame_index: usize,
    variant: ExportVariant,
) ![]u8 {
    const base_path = try frameOutputPath(allocator, output_dir, basename, frame_index, variant);
    defer allocator.free(base_path);
    return tiff.generateUniquePath(allocator, io, base_path);
}

pub fn listGalleryFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
) !GalleryFileList {
    var dir = std.Io.Dir.cwd().openDir(io, output_dir, .{ .iterate = true }) catch {
        return .{ .files = try allocator.alloc([]u8, 0) };
    };
    defer dir.close(io);

    var files = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (files.items) |file| allocator.free(file);
        files.deinit();
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!tiff.isTiffFileName(entry.name)) continue;
        try files.append(try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]u8, files.items, {}, lessThanString);
    return .{ .files = try files.toOwnedSlice() };
}

pub fn trashGalleryFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
    name: []const u8,
) !GalleryMutation {
    const path = try galleryPath(allocator, output_dir, name);
    defer allocator.free(path);
    try requireGalleryFile(io, path);

    const trash_dir = try std.fs.path.join(allocator, &.{ output_dir, ".trash" });
    defer allocator.free(trash_dir);
    try std.Io.Dir.cwd().createDirPath(io, trash_dir);

    const original_name = std.fs.path.basename(path);
    const stem = std.fs.path.stem(original_name);
    const suffix = std.fs.path.extension(original_name);

    var dest_name = try allocator.dupe(u8, original_name);
    errdefer allocator.free(dest_name);
    var counter: usize = 1;
    while (true) : (counter += 1) {
        const dest_path = try std.fs.path.join(allocator, &.{ trash_dir, dest_name });
        if (!galleryPathExists(io, dest_path)) {
            const cwd = std.Io.Dir.cwd();
            try cwd.rename(path, cwd, dest_path, io);
            allocator.free(dest_path);
            const message = try std.fmt.allocPrint(allocator, "Moved {s} to trash", .{original_name});
            return .{
                .file_name = dest_name,
                .message = message,
            };
        }
        allocator.free(dest_path);
        allocator.free(dest_name);
        dest_name = try std.fmt.allocPrint(allocator, "{s}_{d}{s}", .{ stem, counter, suffix });
    }
}

pub fn deleteGalleryFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
    name: []const u8,
) !GalleryMutation {
    const path = try galleryPath(allocator, output_dir, name);
    defer allocator.free(path);
    try requireGalleryFile(io, path);

    const original_name = try allocator.dupe(u8, std.fs.path.basename(path));
    errdefer allocator.free(original_name);
    try std.Io.Dir.cwd().deleteFile(io, path);
    const message = try std.fmt.allocPrint(allocator, "Deleted {s}", .{original_name});
    return .{
        .file_name = original_name,
        .message = message,
    };
}

fn galleryPath(allocator: std.mem.Allocator, output_dir: []const u8, name: []const u8) ![]u8 {
    if (name.len == 0 or std.fs.path.isAbsolute(name) or
        std.mem.indexOfScalar(u8, name, '/') != null or
        std.mem.indexOfScalar(u8, name, '\\') != null)
    {
        return error.AccessDenied;
    }
    return std.fs.path.join(allocator, &.{ output_dir, name });
}

fn requireGalleryFile(io: std.Io, path: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file) return error.FileNotFound;
}

fn galleryPathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

pub fn buildBatchExportProgress(
    allocator: std.mem.Allocator,
    frame_count: usize,
    need_ir: bool,
    has_ir: bool,
    written_files: []const []const u8,
    output_dir: []const u8,
    total_seconds: f64,
) !ExportProgressList {
    var events = std.array_list.Managed(ExportProgressEvent).init(allocator);
    errdefer {
        for (events.items) |event| {
            allocator.free(event.message);
            if (event.file_name) |name| allocator.free(name);
        }
        events.deinit();
    }

    try events.append(.{
        .kind = .preparing,
        .message = try std.fmt.allocPrint(allocator, "Preparing export ({d} frame{s})...", .{ frame_count, if (frame_count == 1) "" else "s" }),
    });
    if (need_ir and has_ir) {
        try events.append(.{
            .kind = .aligning_ir,
            .message = try allocator.dupe(u8, "Aligning IR channel..."),
        });
    }
    try events.append(.{
        .kind = .processing,
        .message = try std.fmt.allocPrint(allocator, "Processing {d} frame{s}...", .{ frame_count, if (frame_count == 1) "" else "s" }),
    });
    for (written_files) |name| {
        try events.append(.{
            .kind = .wrote_file,
            .message = try std.fmt.allocPrint(allocator, "Wrote {s}", .{name}),
            .file_name = try allocator.dupe(u8, name),
        });
    }
    try events.append(.{
        .kind = .complete,
        .message = try std.fmt.allocPrint(allocator, "Exported {d} file{s} to {s}/ ({d:.1}s)", .{
            written_files.len,
            if (written_files.len == 1) "" else "s",
            output_dir,
            total_seconds,
        }),
    });

    return .{ .events = try events.toOwnedSlice() };
}

const ProcessFrameFixture = struct {
    rgb_shape: []const usize,
    rgb: []const u16,
    rect: FrameRect,
    outputs: OutputSelection,
    film_stock: []const u8,
    dmin: ?[3]f64 = null,
    base_meta: FixtureBaseMetadata,
    render_options: render.RenderToDisplayOptions,
    result: ProcessFrameResultFixture,
    files: ProcessFrameFilesFixture,
};

const FixtureBaseMetadata = struct {
    source: []const u8,
    crop: FrameRect,
};

const ProcessFrameResultFixture = struct {
    written: []const []const u8,
    shape: []const usize,
    timing_keys: []const []const u8,
};

const ProcessFrameFilesFixture = struct {
    ir_neg: ProcessFrameFileFixture,
    ir_inv: ProcessFrameFileFixture,
    inv_only: ProcessFrameFileFixture,
};

const ProcessFrameFileFixture = struct {
    name: []const u8,
    shape: []const usize,
    dtype: []const u8,
    pixels: []const u16,
    metadata_json: []const u8,
};

const ExportMetadataFixture = struct {
    source: []const u8,
    rebate_rect: ?std.json.Value = null,
    crop: ExportMetadataCrop,
    variant: []const u8,
    stock: ?[]const u8 = null,
    contrast: ?f64 = null,
    dmin: ?[]const f64 = null,
};

const ExportMetadataCrop = struct {
    cx: f64,
    cy: f64,
    w: f64,
    h: f64,
    angle: f64,
};

fn expectProcessFrameFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: ProcessFrameFileFixture,
) !void {
    try std.testing.expectEqualStrings("uint16", expected.dtype);
    if (expected.shape.len != 3) return error.InvalidExportFixture;
    const image = try tiff.loadRgbPage(allocator, path);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, @intCast(expected.shape[1])), image.width);
    try std.testing.expectEqual(@as(u32, @intCast(expected.shape[0])), image.height);
    try std.testing.expectEqual(@as(u16, @intCast(expected.shape[2])), image.samples_per_pixel);
    try std.testing.expectEqual(@as(u16, 16), image.bits_per_sample);
    try std.testing.expectEqual(expected.pixels.len * 2, image.data.len);

    var expected_metadata = try std.json.parseFromSlice(ExportMetadataFixture, allocator, expected.metadata_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer expected_metadata.deinit();
    const pixel_tolerance: u16 = if (std.mem.eql(u8, expected_metadata.value.variant, "ir_cleaned")) 0 else 2;

    for (expected.pixels, 0..) |sample, index| {
        const actual = std.mem.readInt(u16, image.data[index * 2 ..][0..2], .little);
        if (pixel_tolerance == 0) {
            try std.testing.expectEqual(sample, actual);
        } else {
            const delta = if (sample > actual) sample - actual else actual - sample;
            try std.testing.expect(delta <= pixel_tolerance);
        }
    }

    const metadata = (try tiff.readExportMetadataJson(allocator, path)).?;
    defer allocator.free(metadata);
    try expectMetadataEquivalent(allocator, expected.metadata_json, metadata);
}

fn expectMetadataEquivalent(
    allocator: std.mem.Allocator,
    expected_json: []const u8,
    actual_json: []const u8,
) !void {
    var expected = try std.json.parseFromSlice(ExportMetadataFixture, allocator, expected_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer expected.deinit();
    var actual = try std.json.parseFromSlice(ExportMetadataFixture, allocator, actual_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer actual.deinit();

    try std.testing.expectEqualStrings(expected.value.source, actual.value.source);
    try std.testing.expectEqualStrings(expected.value.variant, actual.value.variant);
    try std.testing.expectApproxEqAbs(expected.value.crop.cx, actual.value.crop.cx, 0.0);
    try std.testing.expectApproxEqAbs(expected.value.crop.cy, actual.value.crop.cy, 0.0);
    try std.testing.expectApproxEqAbs(expected.value.crop.w, actual.value.crop.w, 0.0);
    try std.testing.expectApproxEqAbs(expected.value.crop.h, actual.value.crop.h, 0.0);
    try std.testing.expectApproxEqAbs(expected.value.crop.angle, actual.value.crop.angle, 0.0);
    try std.testing.expect(actual.value.rebate_rect == null);

    if (expected.value.stock) |stock| {
        try std.testing.expect(actual.value.stock != null);
        try std.testing.expectEqualStrings(stock, actual.value.stock.?);
    } else {
        try std.testing.expect(actual.value.stock == null);
    }
    if (expected.value.contrast) |contrast| {
        try std.testing.expect(actual.value.contrast != null);
        try std.testing.expectApproxEqAbs(contrast, actual.value.contrast.?, 0.0);
    } else {
        try std.testing.expect(actual.value.contrast == null);
    }
    if (expected.value.dmin) |dmin| {
        try std.testing.expect(actual.value.dmin != null);
        try std.testing.expectEqual(dmin.len, actual.value.dmin.?.len);
        for (dmin, actual.value.dmin.?) |expected_value, actual_value| {
            try std.testing.expectApproxEqAbs(expected_value, actual_value, 0.0);
        }
    } else {
        try std.testing.expect(actual.value.dmin == null);
    }
}

test "export output defaults match Python handle_export" {
    const outputs = OutputSelection{};
    try std.testing.expect(outputs.any());
    try std.testing.expect(outputs.needIr());
    try std.testing.expect(outputs.needInvert());
    try std.testing.expect(!outputs.ir_neg);
    try std.testing.expect(outputs.ir_inv);
    try std.testing.expect(!outputs.inv_only);
}

test "export output selection preserves Python variant order and derived needs" {
    const outputs = OutputSelection{ .ir_neg = true, .ir_inv = false, .inv_only = true };
    try std.testing.expect(outputs.any());
    try std.testing.expect(outputs.needIr());
    try std.testing.expect(outputs.needInvert());

    var variants_buffer: [3]ExportVariant = undefined;
    const variants = outputs.enabledVariants(&variants_buffer);
    try std.testing.expectEqual(@as(usize, 2), variants.len);
    try std.testing.expectEqual(ExportVariant.ir_neg, variants[0]);
    try std.testing.expectEqual(ExportVariant.inv_only, variants[1]);
}

test "export variants preserve Python suffixes and metadata names" {
    try std.testing.expectEqualStrings("_ir", ExportVariant.ir_neg.suffix());
    try std.testing.expectEqualStrings("", ExportVariant.ir_inv.suffix());
    try std.testing.expectEqualStrings("_inv", ExportVariant.inv_only.suffix());
    try std.testing.expectEqualStrings("ir_cleaned", ExportVariant.ir_neg.metadataVariant());
    try std.testing.expectEqualStrings("ir_cleaned_inverted", ExportVariant.ir_inv.metadataVariant());
    try std.testing.expectEqualStrings("inverted", ExportVariant.inv_only.metadataVariant());
}

test "export model handles no-output and stock lookup semantics" {
    const none = OutputSelection{ .ir_neg = false, .ir_inv = false, .inv_only = false };
    try std.testing.expect(!none.any());
    try std.testing.expect(!none.needIr());
    try std.testing.expect(!none.needInvert());
    try std.testing.expect(activeStockForExport(none, "kodak_gold") == null);

    const raw_ir_only = OutputSelection{ .ir_neg = true, .ir_inv = false, .inv_only = false };
    try std.testing.expect(raw_ir_only.needIr());
    try std.testing.expect(!raw_ir_only.needInvert());
    try std.testing.expect(activeStockForExport(raw_ir_only, "kodak_gold") == null);

    const inverted = OutputSelection{ .ir_neg = false, .ir_inv = false, .inv_only = true };
    try std.testing.expectEqualStrings("kodak_gold", activeStockForExport(inverted, "kodak_gold").?);
}

test "batch export progress messages match Python handle_export plural flow" {
    const allocator = std.testing.allocator;
    const written = [_][]const u8{
        "roll_01_ir.tif",
        "roll_01.tif",
        "roll_02.tif",
    };
    const progress = try buildBatchExportProgress(allocator, 2, true, true, &written, "frames", 1.24);
    defer progress.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 7), progress.events.len);
    try std.testing.expectEqual(ExportProgressKind.preparing, progress.events[0].kind);
    try std.testing.expectEqualStrings("Preparing export (2 frames)...", progress.events[0].message);
    try std.testing.expectEqual(ExportProgressKind.aligning_ir, progress.events[1].kind);
    try std.testing.expectEqualStrings("Aligning IR channel...", progress.events[1].message);
    try std.testing.expectEqual(ExportProgressKind.processing, progress.events[2].kind);
    try std.testing.expectEqualStrings("Processing 2 frames...", progress.events[2].message);
    try std.testing.expectEqual(ExportProgressKind.wrote_file, progress.events[3].kind);
    try std.testing.expectEqualStrings("roll_01_ir.tif", progress.events[3].file_name.?);
    try std.testing.expectEqualStrings("Wrote roll_01_ir.tif", progress.events[3].message);
    try std.testing.expectEqualStrings("Wrote roll_01.tif", progress.events[4].message);
    try std.testing.expectEqualStrings("Wrote roll_02.tif", progress.events[5].message);
    try std.testing.expectEqual(ExportProgressKind.complete, progress.events[6].kind);
    try std.testing.expectEqualStrings("Exported 3 files to frames/ (1.2s)", progress.events[6].message);
}

test "batch export progress messages match Python singular no-IR flow" {
    const allocator = std.testing.allocator;
    const written = [_][]const u8{"roll_01.tif"};
    const progress = try buildBatchExportProgress(allocator, 1, true, false, &written, "frames", 0.04);
    defer progress.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), progress.events.len);
    try std.testing.expectEqualStrings("Preparing export (1 frame)...", progress.events[0].message);
    try std.testing.expectEqual(ExportProgressKind.processing, progress.events[1].kind);
    try std.testing.expectEqualStrings("Processing 1 frame...", progress.events[1].message);
    try std.testing.expectEqualStrings("Wrote roll_01.tif", progress.events[2].message);
    try std.testing.expectEqualStrings("Exported 1 file to frames/ (0.0s)", progress.events[3].message);
}

test "export crop applies rotated crop helper per channel" {
    const allocator = std.testing.allocator;
    const image = [_]f64{
        0,  100, 1,  101, 2,  102, 3,  103,
        4,  104, 5,  105, 6,  106, 7,  107,
        8,  108, 9,  109, 10, 110, 11, 111,
        12, 112, 13, 113, 14, 114, 15, 115,
    };
    const cropped = try cropFrame(allocator, &image, 4, 4, 2, .{
        .cx = 1.5,
        .cy = 1.5,
        .w = 2.0,
        .h = 2.0,
        .angle = 0.0,
    });
    defer cropped.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), cropped.width);
    try std.testing.expectEqual(@as(usize, 2), cropped.height);
    try std.testing.expectEqual(@as(usize, 2), cropped.channels);
    try std.testing.expectEqualSlices(f64, &.{
        2.5, 102.5, 3.5, 103.5,
        6.5, 106.5, 7.5, 107.5,
    }, cropped.pixels);
}

test "export apply rotation matches Python cv2.rotate orientations" {
    const allocator = std.testing.allocator;
    const image = [_]f64{
        1, 2, 3,
        4, 5, 6,
    };

    const cw = try applyRotation(allocator, &image, 3, 2, 1, 90);
    defer cw.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), cw.width);
    try std.testing.expectEqual(@as(usize, 3), cw.height);
    try std.testing.expectEqualSlices(f64, &.{ 4, 1, 5, 2, 6, 3 }, cw.pixels);

    const half = try applyRotation(allocator, &image, 3, 2, 1, 180);
    defer half.deinit(allocator);
    try std.testing.expectEqualSlices(f64, &.{ 6, 5, 4, 3, 2, 1 }, half.pixels);

    const ccw = try applyRotation(allocator, &image, 3, 2, 1, 270);
    defer ccw.deinit(allocator);
    try std.testing.expectEqualSlices(f64, &.{ 3, 6, 2, 5, 1, 4 }, ccw.pixels);

    const unchanged = try applyRotation(allocator, &image, 3, 2, 1, 360);
    defer unchanged.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), unchanged.width);
    try std.testing.expectEqual(@as(usize, 2), unchanged.height);
    try std.testing.expectEqualSlices(f64, &image, unchanged.pixels);
}

test "export u16 rotation matches Python cv2.rotate orientations" {
    const allocator = std.testing.allocator;
    const image = [_]u16{
        1, 2, 3,
        4, 5, 6,
    };

    const cw = try applyRotationU16(allocator, &image, 3, 2, 1, 90);
    defer cw.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), cw.width);
    try std.testing.expectEqual(@as(usize, 3), cw.height);
    try std.testing.expectEqualSlices(u16, &.{ 4, 1, 5, 2, 6, 3 }, cw.pixels);

    const half = try applyRotationU16(allocator, &image, 3, 2, 1, 180);
    defer half.deinit(allocator);
    try std.testing.expectEqualSlices(u16, &.{ 6, 5, 4, 3, 2, 1 }, half.pixels);

    const ccw = try applyRotationU16(allocator, &image, 3, 2, 1, 270);
    defer ccw.deinit(allocator);
    try std.testing.expectEqualSlices(u16, &.{ 3, 6, 2, 5, 1, 4 }, ccw.pixels);

    const unchanged = try applyRotationU16(allocator, &image, 3, 2, 1, 360);
    defer unchanged.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), unchanged.width);
    try std.testing.expectEqual(@as(usize, 2), unchanged.height);
    try std.testing.expectEqualSlices(u16, &image, unchanged.pixels);
}

test "export crop and rotation validate inputs" {
    var out = [_]f64{1};
    try std.testing.expectError(error.InvalidExportImage, cropFrame(std.testing.allocator, &out, 1, 1, 0, .{
        .cx = 0.0,
        .cy = 0.0,
        .w = 1.0,
        .h = 1.0,
    }));
    try std.testing.expectError(error.InvalidExportImage, applyRotation(std.testing.allocator, &out, 1, 1, 0, 45));
}

test "RGB negative output uses raw crop plus Python rotation fallback" {
    const allocator = std.testing.allocator;
    var raw_pixels = [_]f64{
        1, 2, 3, 4,  5,  6,
        7, 8, 9, 10, 11, 12,
    };
    const raw = Image{
        .width = 2,
        .height = 2,
        .channels = 3,
        .pixels = &raw_pixels,
    };

    const rotated = try prepareRgbNegativeOutput(allocator, raw, 90);
    defer rotated.deinit(allocator);
    try std.testing.expectEqualSlices(f64, &.{
        7,  8,  9,  1, 2, 3,
        10, 11, 12, 4, 5, 6,
    }, rotated.pixels);

    const unchanged = try prepareRgbNegativeOutput(allocator, raw, 45);
    defer unchanged.deinit(allocator);
    try std.testing.expectEqualSlices(f64, raw.pixels, unchanged.pixels);
}

test "IR-cleaned negative output prefers cleaned crop and falls back to raw crop" {
    const allocator = std.testing.allocator;
    var raw_pixels = [_]f64{
        1, 2, 3, 4,  5,  6,
        7, 8, 9, 10, 11, 12,
    };
    var cleaned_pixels = [_]f64{
        21, 22, 23, 24, 25, 26,
        27, 28, 29, 30, 31, 32,
    };
    const raw = Image{ .width = 2, .height = 2, .channels = 3, .pixels = &raw_pixels };
    const cleaned = Image{ .width = 2, .height = 2, .channels = 3, .pixels = &cleaned_pixels };

    const output = try prepareIrCleanedNegativeOutput(allocator, raw, cleaned, 0);
    defer output.deinit(allocator);
    try std.testing.expectEqualSlices(f64, cleaned.pixels, output.pixels);

    const fallback = try prepareIrCleanedNegativeOutput(allocator, raw, null, 0);
    defer fallback.deinit(allocator);
    try std.testing.expectEqualSlices(f64, raw.pixels, fallback.pixels);
}

test "export IR-cleaned region helper runs no-defect dust-removal path" {
    const allocator = std.testing.allocator;
    var raw_pixels = [_]f64{
        10, 20, 30, 11, 21, 31,
        12, 22, 32, 13, 23, 33,
    };
    var ir_pixels = [_]f64{
        100, 100,
        100, 100,
    };
    const raw = Image{ .width = 2, .height = 2, .channels = 3, .pixels = &raw_pixels };
    const ir_crop = Image{ .width = 2, .height = 2, .channels = 1, .pixels = &ir_pixels };
    const output = try prepareIrCleanedRegionWithNoise(allocator, raw, ir_crop, &.{}, .{
        .defect_mask = .{ .blur_size = 3, .max_coverage = 1.0 },
    });
    defer output.deinit(allocator);
    try std.testing.expectEqualSlices(f64, raw.pixels, output.pixels);

    var prng = std.Random.DefaultPrng.init(99);
    const random_output = try prepareIrCleanedRegion(allocator, prng.random(), raw, ir_crop, .{
        .defect_mask = .{ .blur_size = 3, .max_coverage = 1.0 },
    });
    defer random_output.deinit(allocator);
    try std.testing.expectEqualSlices(f64, raw.pixels, random_output.pixels);
}

test "inverted positive output matches real-scan Python oracle fixture" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(
        allocator,
        std.testing.io,
        "test/fixtures/processing/numeric/real-scan-negative-to-positive-scan-0006-crop.json",
    );
    defer fixture.deinit();
    const value = fixture.value();
    if (value.shape.len != 3) return error.InvalidExportFixture;

    const crop = Image{
        .width = value.shape[1],
        .height = value.shape[0],
        .channels = value.shape[2],
        .pixels = @constCast(value.input),
    };
    const output = try prepareInvertedPositiveOutput(allocator, crop, .{
        .stock = "kodak_gold",
    }, .{
        .contrast = 1.4,
        .curve_k = 5.0,
        .percentile_lo = 0.5,
        .percentile_hi = 99.5,
        .exposure_compensation = 0.0,
        .color_temp = 0.0,
        .color_tint = 0.0,
    }, 0);
    defer output.deinit(allocator);

    try numeric.assertCloseSlices(value.expected, output.pixels, value.tolerance);

    const direct_u16 = try prepareInvertedPositiveOutputU16(allocator, crop, .{
        .stock = "kodak_gold",
    }, .{
        .contrast = 1.4,
        .curve_k = 5.0,
        .percentile_lo = 0.5,
        .percentile_hi = 99.5,
        .exposure_compensation = 0.0,
        .color_temp = 0.0,
        .color_tint = 0.0,
    }, 0);
    defer direct_u16.deinit(allocator);

    try std.testing.expectEqual(output.pixels.len, direct_u16.pixels.len);
    for (output.pixels, direct_u16.pixels) |old_value, direct_value| {
        const clipped = @min(@max(old_value, 0.0), 65535.0);
        try std.testing.expectEqual(@as(u16, @intFromFloat(@round(clipped))), direct_value);
    }
}

test "processFrame writes all fallback variants like Python real-scan fixture" {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test/fixtures/processing/export/process-frame-scan-0006-patch.json",
        allocator,
        .limited(128 * 1024),
    );
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(ProcessFrameFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    if (fixture.rgb_shape.len != 3) return error.InvalidExportFixture;
    if (fixture.rgb.len != fixture.rgb_shape[0] * fixture.rgb_shape[1] * fixture.rgb_shape[2]) {
        return error.InvalidExportFixture;
    }

    const rgb_pixels = try allocator.alloc(f64, fixture.rgb.len);
    defer allocator.free(rgb_pixels);
    for (fixture.rgb, rgb_pixels) |sample, *out| {
        out.* = @floatFromInt(sample);
    }
    const rgb = Image{
        .width = fixture.rgb_shape[1],
        .height = fixture.rgb_shape[0],
        .channels = fixture.rgb_shape[2],
        .pixels = rgb_pixels,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    const ir_neg_path = try std.fs.path.join(allocator, &.{ dir_path, fixture.files.ir_neg.name });
    defer allocator.free(ir_neg_path);
    const ir_inv_path = try std.fs.path.join(allocator, &.{ dir_path, fixture.files.ir_inv.name });
    defer allocator.free(ir_inv_path);
    const inv_only_path = try std.fs.path.join(allocator, &.{ dir_path, fixture.files.inv_only.name });
    defer allocator.free(inv_only_path);

    const result = try processFrame(allocator, 0, fixture.rect, rgb, null, 1.0, 1.0, .{
        .outputs = fixture.outputs,
        .paths = .{
            .ir_neg = ir_neg_path,
            .ir_inv = ir_inv_path,
            .inv_only = inv_only_path,
        },
        .base_meta = .{
            .source = fixture.base_meta.source,
            .crop = fixture.base_meta.crop,
        },
        .film_stock = fixture.film_stock,
        .stock_coeffs = film_stocks.kodak_gold_coeffs,
        .dmin = fixture.dmin,
        .render_options = fixture.render_options,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(fixture.result.written.len, result.written.len);
    for (fixture.result.written, result.written) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expectEqual(fixture.result.shape[0], result.shape_width);
    try std.testing.expectEqual(fixture.result.shape[1], result.shape_height);
    try std.testing.expectEqual(@as(usize, 6), fixture.result.timing_keys.len);

    try expectProcessFrameFile(allocator, ir_neg_path, fixture.files.ir_neg);
    try expectProcessFrameFile(allocator, ir_inv_path, fixture.files.ir_inv);
    try expectProcessFrameFile(allocator, inv_only_path, fixture.files.inv_only);
}

test "frame naming preserves Python suffix and two-digit frame rules" {
    const allocator = std.testing.allocator;
    const ir_name = try frameFileName(allocator, "roll_a", 0, .ir_neg);
    defer allocator.free(ir_name);
    try std.testing.expectEqualStrings("roll_a_01_ir.tif", ir_name);

    const inv_clean_name = try frameFileName(allocator, "roll_a", 0, .ir_inv);
    defer allocator.free(inv_clean_name);
    try std.testing.expectEqualStrings("roll_a_01.tif", inv_clean_name);

    const inv_raw_name = try frameFileName(allocator, "roll_a", 11, .inv_only);
    defer allocator.free(inv_raw_name);
    try std.testing.expectEqualStrings("roll_a_12_inv.tif", inv_raw_name);

    const path = try frameOutputPath(allocator, "frames", "roll_a", 2, .ir_inv);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("frames/roll_a_03.tif", path);
}

test "frame output paths use Python unique path suffixes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "roll_a_01.tif", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "roll_a_01_002.tif", .data = "" });
    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);

    const path = try uniqueFrameOutputPath(allocator, std.testing.io, dir_path, "roll_a", 0, .ir_inv);
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/roll_a_01_003.tif"));
}

test "gallery file listing returns sorted TIFF basenames only" {
    const allocator = std.testing.allocator;
    const missing = try listGalleryFiles(allocator, std.testing.io, ".zig-cache/tmp/v600-gallery-missing");
    defer missing.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), missing.files.len);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.tif", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "A.TIFF", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "" });
    try tmp.dir.createDir(std.testing.io, "nested", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/c.tif", .data = "" });

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    const files = try listGalleryFiles(allocator, std.testing.io, dir_path);
    defer files.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), files.files.len);
    try std.testing.expectEqualStrings("A.TIFF", files.files[0]);
    try std.testing.expectEqualStrings("b.tif", files.files[1]);
}

test "gallery trash preserves Python collision suffix semantics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan.tif", .data = "scan" });
    try tmp.dir.createDir(std.testing.io, ".trash", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".trash/scan.tif", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".trash/scan_1.tif", .data = "" });

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    const result = try trashGalleryFile(allocator, std.testing.io, dir_path, "scan.tif");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("scan_2.tif", result.file_name);
    try std.testing.expectEqualStrings("Moved scan.tif to trash", result.message);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "scan.tif", .{}));
    try tmp.dir.access(std.testing.io, ".trash/scan_2.tif", .{});
    try std.testing.expectError(error.AccessDenied, trashGalleryFile(allocator, std.testing.io, dir_path, "../scan.tif"));
}

test "gallery delete removes file and reports Python message" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "delete_me.tiff", .data = "" });

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    const result = try deleteGalleryFile(allocator, std.testing.io, dir_path, "delete_me.tiff");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("delete_me.tiff", result.file_name);
    try std.testing.expectEqualStrings("Deleted delete_me.tiff", result.message);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "delete_me.tiff", .{}));
    try std.testing.expectError(error.AccessDenied, deleteGalleryFile(allocator, std.testing.io, dir_path, "/tmp/delete_me.tiff"));
}
