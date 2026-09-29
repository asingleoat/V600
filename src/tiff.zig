const std = @import("std");

const c = @cImport({
    @cInclude("tiffio.h");
    @cInclude("time.h");
});

pub const scanner_custom_lut_tag: u32 = 50000;
pub const scanner_custom_lut_name: [:0]const u8 = "CustomFilmLUTs";
pub const scanner_custom_lut_marker = "Custom film LUTs applied";
pub const export_metadata_tag: u32 = 65000;
pub const export_metadata_name: [:0]const u8 = "ScratchNDentMetadata";

var custom_tags_installed = false;
var previous_tag_extender: c.TIFFExtendProc = null;
var custom_field_infos = [_]c.TIFFFieldInfo{
    asciiFieldInfo(scanner_custom_lut_tag, scanner_custom_lut_name),
    asciiFieldInfo(export_metadata_tag, export_metadata_name),
};

pub const Image = struct {
    width: u32,
    height: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    data: []u8,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const PageInfo = struct {
    width: u32,
    height: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
};

pub const RgbIrPageInfo = struct {
    rgb: PageInfo,
    ir: ?PageInfo = null,
};

pub const ImageView = struct {
    width: u32,
    height: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    data: []const u8,
};

pub const RgbIrPages = struct {
    rgb: Image,
    ir: ?Image = null,

    pub fn deinit(self: RgbIrPages, allocator: std.mem.Allocator) void {
        self.rgb.deinit(allocator);
        if (self.ir) |ir| ir.deinit(allocator);
    }
};

pub const RgbPageWithMetadata = struct {
    rgb: Image,
    dpi: ?u32 = null,
    ir: ?PageInfo = null,

    pub fn deinit(self: RgbPageWithMetadata, allocator: std.mem.Allocator) void {
        self.rgb.deinit(allocator);
    }
};

pub const RgbPageMetadataTimings = struct {
    open_ifd_ns: u64 = 0,
    rgb_read_ns: u64 = 0,
    ir_info_ns: u64 = 0,
};

pub const ImageList = struct {
    paths: [][]u8,

    pub fn deinit(self: ImageList, allocator: std.mem.Allocator) void {
        for (self.paths) |path| allocator.free(path);
        allocator.free(self.paths);
    }
};

pub const ScannerMetadata = struct {
    make: []const u8 = "EPSON",
    model: []const u8 = "Epson Scanner",
    software: []const u8 = "epdaughter-sane",
    dpi: ?u32 = null,
    datetime: ?[]const u8 = null,
    custom_luts_applied: bool = false,
};

pub const WriteImageOptions = struct {
    metadata_json: ?[]const u8 = null,
    big_tiff: bool = false,
};

pub fn readDpi(allocator: std.mem.Allocator, path: []const u8) !?u32 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const tiff = c.TIFFOpen(path_z.ptr, "r") orelse return null;
    defer c.TIFFClose(tiff);

    if (c.TIFFSetDirectory(tiff, 0) == 0) return null;
    return readCurrentDpi(tiff);
}

fn readCurrentDpi(tiff: *c.TIFF) ?u32 {
    var x_resolution: f32 = 0;
    if (c.TIFFGetField(tiff, c.TIFFTAG_XRESOLUTION, &x_resolution) == 0) {
        return null;
    }
    if (!std.math.isFinite(x_resolution) or x_resolution <= 0) return null;
    if (x_resolution > @as(f32, @floatFromInt(std.math.maxInt(u32)))) return null;
    return @intFromFloat(x_resolution);
}

pub fn writeScannerMetadata(allocator: std.mem.Allocator, path: []const u8, metadata: ScannerMetadata) !void {
    return writeScannerPageMetadata(allocator, path, 0, metadata);
}

pub fn writeScannerPageMetadata(allocator: std.mem.Allocator, path: []const u8, page: u16, metadata: ScannerMetadata) !void {
    if (metadata.custom_luts_applied) ensureCustomTagsRegistered();

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const tiff = c.TIFFOpen(path_z.ptr, "r+") orelse return error.TiffOpenFailed;
    defer c.TIFFClose(tiff);

    if (c.TIFFSetDirectory(tiff, page) == 0) return error.MissingTiffPage;
    try setScannerMetadataFields(allocator, tiff, metadata);
    if (c.TIFFRewriteDirectory(tiff) == 0) return error.TiffMetadataFailed;
}

fn setScannerMetadataFields(allocator: std.mem.Allocator, tiff: *c.TIFF, metadata: ScannerMetadata) !void {
    const make_z = try allocator.dupeZ(u8, metadata.make);
    defer allocator.free(make_z);
    const model_z = try allocator.dupeZ(u8, metadata.model);
    defer allocator.free(model_z);
    const software_z = try allocator.dupeZ(u8, metadata.software);
    defer allocator.free(software_z);

    try setAsciiField(tiff, c.TIFFTAG_MAKE, make_z.ptr);
    try setAsciiField(tiff, c.TIFFTAG_MODEL, model_z.ptr);
    try setAsciiField(tiff, c.TIFFTAG_SOFTWARE, software_z.ptr);

    var datetime_buffer: [20]u8 = undefined;
    if (metadata.datetime orelse currentTiffDateTime(&datetime_buffer)) |datetime| {
        const datetime_z = try allocator.dupeZ(u8, datetime);
        defer allocator.free(datetime_z);
        try setAsciiField(tiff, c.TIFFTAG_DATETIME, datetime_z.ptr);
    }

    if (metadata.dpi) |dpi| {
        const dpi_f: f32 = @floatFromInt(dpi);
        try setFloatField(tiff, c.TIFFTAG_XRESOLUTION, dpi_f);
        try setFloatField(tiff, c.TIFFTAG_YRESOLUTION, dpi_f);
        try setShortField(tiff, c.TIFFTAG_RESOLUTIONUNIT, c.RESUNIT_INCH);
    }

    if (metadata.custom_luts_applied) {
        const marker_z = try allocator.dupeZ(u8, scanner_custom_lut_marker);
        defer allocator.free(marker_z);
        try setAsciiField(tiff, scanner_custom_lut_tag, marker_z.ptr);
    }
}

pub fn loadRgbIrPages(allocator: std.mem.Allocator, path: []const u8) !RgbIrPages {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const tiff = c.TIFFOpen(path_z.ptr, "r") orelse return error.TiffOpenFailed;
    defer c.TIFFClose(tiff);

    if (c.TIFFSetDirectory(tiff, 0) == 0) return error.MissingRgbPage;
    const rgb = try readCurrentPage(allocator, tiff);
    errdefer rgb.deinit(allocator);

    var ir: ?Image = null;
    errdefer if (ir) |page| page.deinit(allocator);
    if (c.TIFFSetDirectory(tiff, 2) != 0) {
        ir = try readCurrentPage(allocator, tiff);
    }

    return .{ .rgb = rgb, .ir = ir };
}

pub fn readRgbIrPageInfo(allocator: std.mem.Allocator, path: []const u8) !RgbIrPageInfo {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const tiff = c.TIFFOpen(path_z.ptr, "r") orelse return error.TiffOpenFailed;
    defer c.TIFFClose(tiff);

    if (c.TIFFSetDirectory(tiff, 0) == 0) return error.MissingRgbPage;
    const rgb = try readCurrentPageInfo(tiff);

    const ir = if (c.TIFFSetDirectory(tiff, 2) != 0)
        try readCurrentPageInfo(tiff)
    else
        null;

    return .{ .rgb = rgb, .ir = ir };
}

pub fn readIrPageInfo(allocator: std.mem.Allocator, path: []const u8) !?PageInfo {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const tiff = c.TIFFOpen(path_z.ptr, "r") orelse return error.TiffOpenFailed;
    defer c.TIFFClose(tiff);

    if (c.TIFFSetDirectory(tiff, 2) == 0) return null;
    return try readCurrentPageInfo(tiff);
}

pub fn loadRgbPage(allocator: std.mem.Allocator, path: []const u8) !Image {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const tiff = c.TIFFOpen(path_z.ptr, "r") orelse return error.TiffOpenFailed;
    defer c.TIFFClose(tiff);

    if (c.TIFFSetDirectory(tiff, 0) == 0) return error.MissingRgbPage;
    return readCurrentPage(allocator, tiff);
}

pub fn loadRgbPageWithMetadata(allocator: std.mem.Allocator, path: []const u8) !RgbPageWithMetadata {
    return loadRgbPageWithMetadataTimed(allocator, path, null);
}

pub fn loadRgbPageWithMetadataTimed(
    allocator: std.mem.Allocator,
    path: []const u8,
    timings: ?*RgbPageMetadataTimings,
) !RgbPageWithMetadata {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const open_started = monotonicNowNs();
    const tiff = c.TIFFOpen(path_z.ptr, "r") orelse return error.TiffOpenFailed;
    defer c.TIFFClose(tiff);

    if (c.TIFFSetDirectory(tiff, 0) == 0) return error.MissingRgbPage;
    const dpi = readCurrentDpi(tiff);
    const rgb_info = try readCurrentPageInfo(tiff);
    if (timings) |target| target.open_ifd_ns = monotonicNowNs() - open_started;

    const rgb_started = monotonicNowNs();
    const rgb = try readCurrentPageWithInfo(allocator, tiff, rgb_info);
    errdefer rgb.deinit(allocator);
    if (timings) |target| target.rgb_read_ns = monotonicNowNs() - rgb_started;

    const ir_started = monotonicNowNs();
    const ir = if (c.TIFFSetDirectory(tiff, 2) != 0)
        try readCurrentPageInfo(tiff)
    else
        null;
    if (timings) |target| target.ir_info_ns = monotonicNowNs() - ir_started;

    return .{ .rgb = rgb, .dpi = dpi, .ir = ir };
}

pub fn writeImage(
    allocator: std.mem.Allocator,
    path: []const u8,
    image: ImageView,
    options: WriteImageOptions,
) !void {
    if (options.metadata_json != null) ensureCustomTagsRegistered();

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const mode = if (options.big_tiff) "w8" else "w";

    const tiff = c.TIFFOpen(path_z.ptr, mode) orelse return error.TiffOpenFailed;
    defer c.TIFFClose(tiff);

    try writeImageDirectory(allocator, tiff, image, options.metadata_json);
}

pub const ScanPage = struct {
    image: ImageView,
    metadata: ?ScannerMetadata = null,
};

/// Writes scanner pages (for example RGB, thumbnail, IR) into one TIFF,
/// switching to BigTIFF when the pixel data would not fit a classic TIFF.
pub fn writeScanPages(allocator: std.mem.Allocator, path: []const u8, pages: []const ScanPage) !void {
    var total_bytes: u64 = 0;
    for (pages) |page| {
        total_bytes += page.image.data.len;
        if (page.metadata) |metadata| {
            if (metadata.custom_luts_applied) ensureCustomTagsRegistered();
        }
    }
    const classic_limit: u64 = 0xF000_0000;

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const tiff = c.TIFFOpen(path_z.ptr, if (total_bytes > classic_limit) "w8" else "w") orelse return error.TiffOpenFailed;
    defer c.TIFFClose(tiff);

    for (pages) |page| {
        const scanline = try expectedScanlineSize(page.image.width, page.image.samples_per_pixel, page.image.bits_per_sample);
        const rows_per_strip: u32 = @intCast(@max(1, @min(page.image.height, scan_strip_bytes / @max(scanline, 1))));
        try setImageFields(tiff, page.image, rows_per_strip);
        if (page.metadata) |metadata| try setScannerMetadataFields(allocator, tiff, metadata);
        try writeImageData(tiff, page.image, rows_per_strip);
    }
}

const scan_strip_bytes: usize = 4 * 1024 * 1024;

pub fn readAsciiTag(allocator: std.mem.Allocator, path: []const u8, tag: u32, name: []const u8) !?[]u8 {
    _ = name;
    if (isPrivateTag(tag) and !isKnownPrivateTag(tag)) return null;
    if (isPrivateTag(tag)) ensureCustomTagsRegistered();

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const tiff = c.TIFFOpen(path_z.ptr, "r") orelse return null;
    defer c.TIFFClose(tiff);

    if (c.TIFFSetDirectory(tiff, 0) == 0) return null;

    var value_ptr: [*c]const u8 = null;
    if (c.TIFFGetField(tiff, tag, &value_ptr) == 0 or value_ptr == null) return null;
    return try allocator.dupe(u8, std.mem.sliceTo(value_ptr, 0));
}

pub fn readExportMetadataJson(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    return readAsciiTag(allocator, path, export_metadata_tag, export_metadata_name);
}

pub fn findImages(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !ImageList {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch {
        return .{ .paths = &.{} };
    };
    defer dir.close(io);

    var paths = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isTiffFileName(entry.name)) continue;
        const full_path = try joinPath(allocator, directory, entry.name);
        try paths.append(full_path);
    }

    std.mem.sort([]u8, paths.items, {}, lessThanBasenameIgnoreCase);
    return .{ .paths = try paths.toOwnedSlice() };
}

pub fn generateUniquePath(allocator: std.mem.Allocator, io: std.Io, base_path: []const u8) ![]u8 {
    if (!pathExists(io, base_path)) return allocator.dupe(u8, base_path);

    const dir = std.fs.path.dirname(base_path);
    const base_name = std.fs.path.basename(base_path);
    const stem = std.fs.path.stem(base_name);
    const suffix = std.fs.path.extension(base_name);

    var counter: u32 = 2;
    while (counter <= 999) : (counter += 1) {
        const candidate_name = try std.fmt.allocPrint(allocator, "{s}_{d:0>3}{s}", .{ stem, counter, suffix });
        defer allocator.free(candidate_name);
        const candidate = if (dir) |dir_name|
            try joinPath(allocator, dir_name, candidate_name)
        else
            try allocator.dupe(u8, candidate_name);
        if (!pathExists(io, candidate)) return candidate;
        allocator.free(candidate);
    }
    return error.NoUniquePath;
}

pub fn nextScanNumber(io: std.Io, directory: []const u8, prefix: []const u8) !usize {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch return 1;
    defer dir.close(io);

    var highest: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isTiffFileName(entry.name) or !std.mem.startsWith(u8, entry.name, prefix)) continue;
        const rest = entry.name[prefix.len..];
        const digits_end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
        const number = std.fmt.parseInt(usize, rest[0..digits_end], 10) catch continue;
        highest = @max(highest, number);
    }
    return highest + 1;
}

pub fn isTiffFileName(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".tif") or std.ascii.endsWithIgnoreCase(name, ".tiff");
}

fn writeImageDirectory(
    allocator: std.mem.Allocator,
    tiff: *c.TIFF,
    image: ImageView,
    metadata_json: ?[]const u8,
) !void {
    try setImageFields(tiff, image, image.height);

    if (metadata_json) |json| {
        const json_z = try allocator.dupeZ(u8, json);
        defer allocator.free(json_z);
        try setAsciiField(tiff, export_metadata_tag, json_z.ptr);
    }

    try writeImageData(tiff, image, image.height);
}

fn setImageFields(tiff: *c.TIFF, image: ImageView, rows_per_strip: u32) !void {
    const expected_len = try std.math.mul(
        usize,
        image.height,
        try expectedScanlineSize(image.width, image.samples_per_pixel, image.bits_per_sample),
    );
    if (expected_len != image.data.len) return error.UnsupportedTiff;

    _ = c.TIFFSetField(tiff, c.TIFFTAG_IMAGEWIDTH, @as(u32, image.width));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_IMAGELENGTH, @as(u32, image.height));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_SAMPLESPERPIXEL, @as(u16, image.samples_per_pixel));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_BITSPERSAMPLE, @as(u16, image.bits_per_sample));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_COMPRESSION, @as(u16, c.COMPRESSION_NONE));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_PLANARCONFIG, @as(u16, c.PLANARCONFIG_CONTIG));
    _ = c.TIFFSetField(tiff, c.TIFFTAG_ROWSPERSTRIP, rows_per_strip);
    const photometric: u16 = if (image.samples_per_pixel == 3) c.PHOTOMETRIC_RGB else c.PHOTOMETRIC_MINISBLACK;
    _ = c.TIFFSetField(tiff, c.TIFFTAG_PHOTOMETRIC, photometric);
}

fn writeImageData(tiff: *c.TIFF, image: ImageView, rows_per_strip: u32) !void {
    const strip_bytes = @as(usize, rows_per_strip) * (image.data.len / @max(image.height, 1));
    var strip: u32 = 0;
    var offset: usize = 0;
    while (offset < image.data.len) : (strip += 1) {
        const len = @min(strip_bytes, image.data.len - offset);
        if (c.TIFFWriteEncodedStrip(tiff, strip, @constCast(image.data[offset..].ptr), @intCast(len)) < 0) {
            return error.TiffWriteFailed;
        }
        offset += len;
    }
    if (c.TIFFWriteDirectory(tiff) == 0) return error.TiffWriteFailed;
}

fn isPrivateTag(tag: u32) bool {
    return tag >= 32768;
}

fn isKnownPrivateTag(tag: u32) bool {
    return tag == scanner_custom_lut_tag or tag == export_metadata_tag;
}

fn asciiFieldInfo(tag: u32, name: [:0]const u8) c.TIFFFieldInfo {
    return .{
        .field_tag = tag,
        .field_readcount = c.TIFF_VARIABLE,
        .field_writecount = c.TIFF_VARIABLE,
        .field_type = c.TIFF_ASCII,
        .field_bit = c.FIELD_CUSTOM,
        .field_oktochange = 1,
        .field_passcount = 0,
        .field_name = @constCast(name.ptr),
    };
}

fn ensureCustomTagsRegistered() void {
    if (custom_tags_installed) return;
    previous_tag_extender = c.TIFFSetTagExtender(customTagExtender);
    custom_tags_installed = true;
}

fn customTagExtender(tiff: ?*c.TIFF) callconv(.c) void {
    const handle = tiff orelse return;
    _ = c.TIFFMergeFieldInfo(handle, &custom_field_infos, custom_field_infos.len);
    if (previous_tag_extender) |callback| callback(handle);
}

fn setAsciiField(tiff: *c.TIFF, tag: u32, value: [*:0]const u8) !void {
    if (c.TIFFSetField(tiff, tag, value) == 0) return error.TiffMetadataFailed;
}

fn setFloatField(tiff: *c.TIFF, tag: u32, value: f32) !void {
    if (c.TIFFSetField(tiff, tag, value) == 0) return error.TiffMetadataFailed;
}

fn setShortField(tiff: *c.TIFF, tag: u32, value: u16) !void {
    if (c.TIFFSetField(tiff, tag, value) == 0) return error.TiffMetadataFailed;
}

fn currentTiffDateTime(buffer: *[20]u8) ?[]const u8 {
    var now = c.time(null);
    var tm_storage: c.struct_tm = undefined;
    if (c.localtime_r(&now, &tm_storage) == null) return null;
    const written = c.strftime(buffer.ptr, buffer.len, "%Y:%m:%d %H:%M:%S", &tm_storage);
    if (written != 19) return null;
    return buffer[0..19];
}

fn readCurrentPage(allocator: std.mem.Allocator, tiff: *c.TIFF) !Image {
    const info = try readCurrentPageInfo(tiff);
    return readCurrentPageWithInfo(allocator, tiff, info);
}

fn readCurrentPageWithInfo(allocator: std.mem.Allocator, tiff: *c.TIFF, info: PageInfo) !Image {
    const scanline_size_raw = c.TIFFScanlineSize(tiff);
    if (scanline_size_raw <= 0) return error.UnsupportedTiff;
    const scanline_size: usize = @intCast(scanline_size_raw);
    const expected_scanline = try expectedScanlineSize(info.width, info.samples_per_pixel, info.bits_per_sample);
    if (scanline_size != expected_scanline) return error.UnsupportedTiff;

    const data_len = try std.math.mul(usize, scanline_size, info.height);
    const data = try allocator.alloc(u8, data_len);
    errdefer allocator.free(data);

    var row: u32 = 0;
    while (row < info.height) : (row += 1) {
        const offset = @as(usize, row) * scanline_size;
        if (c.TIFFReadScanline(tiff, data[offset .. offset + scanline_size].ptr, row, 0) < 0) {
            return error.TiffReadFailed;
        }
    }

    return .{
        .width = info.width,
        .height = info.height,
        .samples_per_pixel = info.samples_per_pixel,
        .bits_per_sample = info.bits_per_sample,
        .data = data,
    };
}

fn readCurrentPageInfo(tiff: *c.TIFF) !PageInfo {
    var width: u32 = 0;
    var height: u32 = 0;
    var samples_per_pixel: u16 = 1;
    var bits_per_sample: u16 = 1;
    var planar_config: u16 = c.PLANARCONFIG_CONTIG;

    if (c.TIFFGetField(tiff, c.TIFFTAG_IMAGEWIDTH, &width) == 0) return error.UnsupportedTiff;
    if (c.TIFFGetField(tiff, c.TIFFTAG_IMAGELENGTH, &height) == 0) return error.UnsupportedTiff;
    _ = c.TIFFGetField(tiff, c.TIFFTAG_SAMPLESPERPIXEL, &samples_per_pixel);
    _ = c.TIFFGetField(tiff, c.TIFFTAG_BITSPERSAMPLE, &bits_per_sample);
    _ = c.TIFFGetField(tiff, c.TIFFTAG_PLANARCONFIG, &planar_config);
    if (planar_config != c.PLANARCONFIG_CONTIG) return error.UnsupportedTiff;
    if (bits_per_sample != 8 and bits_per_sample != 16) return error.UnsupportedTiff;
    if (samples_per_pixel != 1 and samples_per_pixel != 3) return error.UnsupportedTiff;

    return .{
        .width = width,
        .height = height,
        .samples_per_pixel = samples_per_pixel,
        .bits_per_sample = bits_per_sample,
    };
}

fn expectedScanlineSize(width: u32, samples_per_pixel: u16, bits_per_sample: u16) !usize {
    const bytes_per_sample = bits_per_sample / 8;
    return std.math.mul(usize, width, try std.math.mul(usize, samples_per_pixel, bytes_per_sample));
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn joinPath(allocator: std.mem.Allocator, directory: []const u8, name: []const u8) ![]u8 {
    if (directory.len == 0 or std.mem.eql(u8, directory, ".")) {
        return allocator.dupe(u8, name);
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
}

fn lessThanBasenameIgnoreCase(_: void, a: []const u8, b: []const u8) bool {
    return asciiLessThanIgnoreCase(std.fs.path.basename(a), std.fs.path.basename(b));
}

fn asciiLessThanIgnoreCase(a: []const u8, b: []const u8) bool {
    const len = @min(a.len, b.len);
    for (a[0..len], b[0..len]) |a_ch, b_ch| {
        const lower_a = std.ascii.toLower(a_ch);
        const lower_b = std.ascii.toLower(b_ch);
        if (lower_a < lower_b) return true;
        if (lower_a > lower_b) return false;
    }
    return a.len < b.len;
}

test "reads page zero DPI from normal TIFF XResolution" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/normal-dpi.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(path);
    try writeMinimalTiff(allocator, path, .{ .numerator = 300, .denominator = 1 });

    try std.testing.expectEqual(@as(?u32, 300), try readDpi(allocator, path));
}

test "returns null when TIFF XResolution is missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/missing-dpi.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(path);
    try writeMinimalTiff(allocator, path, null);

    try std.testing.expectEqual(@as(?u32, null), try readDpi(allocator, path));
}

test "returns null when TIFF XResolution denominator is zero" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/zero-denominator-dpi.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(path);
    try writeMinimalTiff(allocator, path, .{ .numerator = 300, .denominator = 0 });

    try std.testing.expectEqual(@as(?u32, null), try readDpi(allocator, path));
}

test "loads RGB page zero and IR page two while skipping thumbnail page one" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/rgb-ir-pages.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(path);
    try writePageFixture(allocator, path, &.{
        .{ .width = 2, .height = 1, .samples_per_pixel = 3, .bits_per_sample = 8, .data = &.{ 1, 2, 3, 4, 5, 6 } },
        .{ .width = 1, .height = 1, .samples_per_pixel = 3, .bits_per_sample = 8, .data = &.{ 99, 98, 97 } },
        .{ .width = 1, .height = 2, .samples_per_pixel = 1, .bits_per_sample = 8, .data = &.{ 7, 8 } },
    });

    const pages = try loadRgbIrPages(allocator, path);
    defer pages.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), pages.rgb.width);
    try std.testing.expectEqual(@as(u32, 1), pages.rgb.height);
    try std.testing.expectEqual(@as(u16, 3), pages.rgb.samples_per_pixel);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, pages.rgb.data);
    try std.testing.expect(pages.ir != null);
    try std.testing.expectEqual(@as(u32, 1), pages.ir.?.width);
    try std.testing.expectEqual(@as(u32, 2), pages.ir.?.height);
    try std.testing.expectEqual(@as(u16, 1), pages.ir.?.samples_per_pixel);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8 }, pages.ir.?.data);
}

test "loads committed Python tifffile RGB thumbnail IR fixture" {
    const allocator = std.testing.allocator;
    const path = "test/fixtures/tiff/rgb-thumb-ir.tiff";

    try std.testing.expectEqual(@as(?u32, 800), try readDpi(allocator, path));

    const pages = try loadRgbIrPages(allocator, path);
    defer pages.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), pages.rgb.width);
    try std.testing.expectEqual(@as(u32, 2), pages.rgb.height);
    try std.testing.expectEqual(@as(u16, 3), pages.rgb.samples_per_pixel);
    try std.testing.expectEqual(@as(u16, 16), pages.rgb.bits_per_sample);
    try std.testing.expectEqualSlices(u8, &.{
        232, 3, 233, 3, 234, 3,
        242, 3, 243, 3, 244, 3,
        252, 3, 253, 3, 254, 3,
        6,   4, 7,   4, 8,   4,
    }, pages.rgb.data);

    try std.testing.expect(pages.ir != null);
    try std.testing.expectEqual(@as(u32, 3), pages.ir.?.width);
    try std.testing.expectEqual(@as(u32, 2), pages.ir.?.height);
    try std.testing.expectEqual(@as(u16, 1), pages.ir.?.samples_per_pixel);
    try std.testing.expectEqual(@as(u16, 8), pages.ir.?.bits_per_sample);
    try std.testing.expectEqualSlices(u8, &.{ 31, 32, 33, 34, 35, 36 }, pages.ir.?.data);

    const rgb_with_metadata = try loadRgbPageWithMetadata(allocator, path);
    defer rgb_with_metadata.deinit(allocator);
    try std.testing.expectEqual(@as(?u32, 800), rgb_with_metadata.dpi);
    try std.testing.expectEqual(@as(u32, 2), rgb_with_metadata.rgb.width);
    try std.testing.expectEqual(@as(u16, 3), rgb_with_metadata.rgb.samples_per_pixel);
    try std.testing.expectEqualSlices(u8, pages.rgb.data, rgb_with_metadata.rgb.data);
    try std.testing.expect(rgb_with_metadata.ir != null);
    try std.testing.expectEqual(@as(u32, 3), rgb_with_metadata.ir.?.width);
    try std.testing.expectEqual(@as(u16, 1), rgb_with_metadata.ir.?.samples_per_pixel);
}

test "loads single-page TIFF without IR page" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/single-page.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(path);
    try writePageFixture(allocator, path, &.{
        .{ .width = 2, .height = 1, .samples_per_pixel = 1, .bits_per_sample = 16, .data = &.{ 1, 0, 2, 0 } },
    });

    const pages = try loadRgbIrPages(allocator, path);
    defer pages.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), pages.rgb.width);
    try std.testing.expectEqual(@as(u16, 16), pages.rgb.bits_per_sample);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, pages.rgb.data);
    try std.testing.expect(pages.ir == null);
}

test "writes scanner TIFF metadata including DPI and custom LUT marker" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/scanner-metadata.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(path);
    try writePageFixture(allocator, path, &.{
        .{ .width = 1, .height = 1, .samples_per_pixel = 3, .bits_per_sample = 16, .data = &.{ 1, 0, 2, 0, 3, 0 } },
    });

    try writeScannerMetadata(allocator, path, .{
        .model = "Epson Perfection V600 Photo",
        .software = "epdaughter-sane",
        .dpi = 2400,
        .datetime = "2026:05:15 12:34:56",
        .custom_luts_applied = true,
    });

    const make = (try readAsciiTag(allocator, path, c.TIFFTAG_MAKE, "Make")).?;
    defer allocator.free(make);
    try std.testing.expectEqualStrings("EPSON", make);
    const model = (try readAsciiTag(allocator, path, c.TIFFTAG_MODEL, "Model")).?;
    defer allocator.free(model);
    try std.testing.expectEqualStrings("Epson Perfection V600 Photo", model);
    const software = (try readAsciiTag(allocator, path, c.TIFFTAG_SOFTWARE, "Software")).?;
    defer allocator.free(software);
    try std.testing.expectEqualStrings("epdaughter-sane", software);
    const datetime = (try readAsciiTag(allocator, path, c.TIFFTAG_DATETIME, "DateTime")).?;
    defer allocator.free(datetime);
    try std.testing.expectEqualStrings("2026:05:15 12:34:56", datetime);
    const marker = (try readAsciiTag(allocator, path, scanner_custom_lut_tag, scanner_custom_lut_name)).?;
    defer allocator.free(marker);
    try std.testing.expectEqualStrings(scanner_custom_lut_marker, marker);
    try std.testing.expectEqual(@as(?u32, 2400), try readDpi(allocator, path));
}

test "writes scanner metadata on the IR page of a combined RGB+IR file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/rgb-ir-metadata.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(path);
    try writePageFixture(allocator, path, &.{
        .{ .width = 1, .height = 1, .samples_per_pixel = 3, .bits_per_sample = 16, .data = &.{ 1, 0, 2, 0, 3, 0 } },
        .{ .width = 1, .height = 1, .samples_per_pixel = 3, .bits_per_sample = 8, .data = &.{ 1, 2, 3 } },
        .{ .width = 1, .height = 1, .samples_per_pixel = 1, .bits_per_sample = 8, .data = &.{7} },
    });

    try writeScannerMetadata(allocator, path, .{ .model = "Epson Perfection V600 Photo", .dpi = 6400, .datetime = "2026:09:28 10:00:00" });
    try writeScannerPageMetadata(allocator, path, 2, .{ .model = "Epson Perfection V600 Photo", .dpi = 3200, .datetime = "2026:09:28 10:00:00" });
    try std.testing.expectError(error.MissingTiffPage, writeScannerPageMetadata(allocator, path, 3, .{}));

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const handle = c.TIFFOpen(path_z.ptr, "r") orelse return error.TiffOpenFailed;
    defer c.TIFFClose(handle);
    try std.testing.expect(c.TIFFSetDirectory(handle, 2) != 0);
    var model: [*c]const u8 = null;
    try std.testing.expect(c.TIFFGetField(handle, c.TIFFTAG_MODEL, &model) != 0);
    try std.testing.expectEqualStrings("Epson Perfection V600 Photo", std.mem.span(model));
    var datetime: [*c]const u8 = null;
    try std.testing.expect(c.TIFFGetField(handle, c.TIFFTAG_DATETIME, &datetime) != 0);
    try std.testing.expectEqualStrings("2026:09:28 10:00:00", std.mem.span(datetime));
    try std.testing.expectEqual(@as(?u32, 3200), readCurrentDpi(handle));
    try std.testing.expectEqual(@as(?u32, 6400), try readDpi(allocator, path));
}

test "writes RGB, thumbnail, and IR scan pages with per-page metadata" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/scan-pages.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(path);

    // Tall enough that the 4 MiB strip size splits the RGB page.
    const width: u32 = 512;
    const height: u32 = 1400;
    const rgb = try allocator.alloc(u8, @as(usize, width) * height * 6);
    defer allocator.free(rgb);
    for (rgb, 0..) |*byte, i| byte.* = @truncate(i *% 7);
    const ir = try allocator.alloc(u8, @as(usize, width) * height);
    defer allocator.free(ir);
    for (ir, 0..) |*byte, i| byte.* = @truncate(i *% 3);

    try writeScanPages(allocator, path, &.{
        .{
            .image = .{ .width = width, .height = height, .samples_per_pixel = 3, .bits_per_sample = 16, .data = rgb },
            .metadata = .{ .model = "Perfection V600", .dpi = 1600, .datetime = "2026:09:28 10:00:00", .custom_luts_applied = true },
        },
        .{ .image = .{ .width = 1, .height = 1, .samples_per_pixel = 3, .bits_per_sample = 8, .data = &.{ 1, 2, 3 } } },
        .{
            .image = .{ .width = width, .height = height, .samples_per_pixel = 1, .bits_per_sample = 8, .data = ir },
            .metadata = .{ .model = "Perfection V600", .dpi = 800, .datetime = "2026:09:28 10:00:00" },
        },
    });

    var pages = try loadRgbIrPages(allocator, path);
    defer pages.deinit(allocator);
    try std.testing.expectEqualSlices(u8, rgb, pages.rgb.data);
    try std.testing.expectEqualSlices(u8, ir, pages.ir.?.data);
    try std.testing.expectEqual(@as(?u32, 1600), try readDpi(allocator, path));
    const marker = (try readAsciiTag(allocator, path, scanner_custom_lut_tag, scanner_custom_lut_name)).?;
    defer allocator.free(marker);
    try std.testing.expectEqualStrings(scanner_custom_lut_marker, marker);

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const handle = c.TIFFOpen(path_z.ptr, "r") orelse return error.TiffOpenFailed;
    defer c.TIFFClose(handle);
    try std.testing.expect(c.TIFFNumberOfStrips(handle) > 1);
    try std.testing.expect(c.TIFFSetDirectory(handle, 2) != 0);
    try std.testing.expectEqual(@as(?u32, 800), readCurrentDpi(handle));
}

test "writes export TIFF with private JSON metadata tag" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/export-metadata.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(path);
    const json =
        \\{"frame":2,"variant":"ir_cleaned_inverted","stock":"kodak_gold"}
    ;
    try writeImage(allocator, path, .{
        .width = 2,
        .height = 1,
        .samples_per_pixel = 3,
        .bits_per_sample = 8,
        .data = &.{ 1, 2, 3, 4, 5, 6 },
    }, .{ .metadata_json = json });

    const pages = try loadRgbIrPages(allocator, path);
    defer pages.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), pages.rgb.width);
    try std.testing.expectEqual(@as(u16, 8), pages.rgb.bits_per_sample);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, pages.rgb.data);

    const written_json = (try readExportMetadataJson(allocator, path)).?;
    defer allocator.free(written_json);
    try std.testing.expectEqualStrings(json, written_json);
}

test "reads Python write_tiff exported frame metadata fixture" {
    const allocator = std.testing.allocator;
    const path = "test/fixtures/tiff/export-metadata.tiff";
    const expected_json =
        \\{"source": "scan_0001_rgbir_3200dpi.tiff", "rebate_rect": null, "crop": {"cx": 12.5, "cy": 16.25, "w": 20.0, "h": 8.0, "angle": -1.5}, "variant": "ir_cleaned_inverted", "stock": "kodak_gold", "contrast": 1.15, "dmin": [0.1, 0.2, 0.3]}
    ;

    const metadata = (try readExportMetadataJson(allocator, path)).?;
    defer allocator.free(metadata);
    try std.testing.expectEqualStrings(expected_json, metadata);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, metadata, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("scan_0001_rgbir_3200dpi.tiff", object.get("source").?.string);
    try std.testing.expectEqualStrings("ir_cleaned_inverted", object.get("variant").?.string);
    try std.testing.expectEqualStrings("kodak_gold", object.get("stock").?.string);
    try std.testing.expectEqual(@as(usize, 3), object.get("dmin").?.array.items.len);

    const image = try loadRgbPage(allocator, path);
    defer image.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqual(@as(u16, 3), image.samples_per_pixel);
    try std.testing.expectEqual(@as(u16, 8), image.bits_per_sample);
    try std.testing.expectEqualSlices(u8, &.{
        10,  20,  30,
        40,  50,  60,
        70,  80,  90,
        100, 110, 120,
    }, image.data);
}

test "finds TIFF images sorted by case-insensitive file name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.TIFF", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "A.tif", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan.png", .data = "" });

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    const images = try findImages(allocator, std.testing.io, dir_path);
    defer images.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), images.paths.len);
    try std.testing.expect(std.mem.endsWith(u8, images.paths[0], "/A.tif"));
    try std.testing.expect(std.mem.endsWith(u8, images.paths[1], "/b.TIFF"));

    const missing = try findImages(allocator, std.testing.io, ".zig-cache/tmp/does-not-exist-v600");
    defer missing.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), missing.paths.len);
}

test "generates Python-style unique paths with three-digit suffixes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    const base_path = try std.fmt.allocPrint(allocator, "{s}/scan.tiff", .{dir_path});
    defer allocator.free(base_path);
    const first_available = try generateUniquePath(allocator, std.testing.io, base_path);
    defer allocator.free(first_available);
    try std.testing.expectEqualStrings(base_path, first_available);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan.tiff", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan_002.tiff", .data = "" });
    const next = try generateUniquePath(allocator, std.testing.io, base_path);
    defer allocator.free(next);
    try std.testing.expect(std.mem.endsWith(u8, next, "/scan_003.tiff"));
}

test "continues scan numbering after the highest existing numbered TIFF" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    try std.testing.expectEqual(@as(usize, 1), try nextScanNumber(std.testing.io, dir_path, "scan_"));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan_0003_rgb_800dpi.tiff", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan_0012_rgbir_3200dpi.tiff", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan_0040_rgb_800dpi.tiff.json", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan_preview.tiff", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "companion_scan_0099.tiff", .data = "" });
    try std.testing.expectEqual(@as(usize, 13), try nextScanNumber(std.testing.io, dir_path, "scan_"));
    try std.testing.expectEqual(@as(usize, 100), try nextScanNumber(std.testing.io, dir_path, "companion_scan_"));
    try std.testing.expectEqual(@as(usize, 1), try nextScanNumber(std.testing.io, ".zig-cache/tmp/does-not-exist-v600", "scan_"));
}

const Rational = struct {
    numerator: u32,
    denominator: u32,
};

const IfdEntry = struct {
    tag: u16,
    field_type: u16,
    count: u32,
    value_or_offset: u32,
};

const PageSpec = struct {
    width: u32,
    height: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    data: []const u8,
};

fn writeMinimalTiff(allocator: std.mem.Allocator, path: []const u8, dpi: ?Rational) !void {
    const data = try minimalTiffBytes(allocator, dpi);
    defer allocator.free(data);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

fn writePageFixture(allocator: std.mem.Allocator, path: []const u8, pages: []const PageSpec) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const tiff = c.TIFFOpen(path_z.ptr, "w") orelse return error.TiffOpenFailed;
    defer c.TIFFClose(tiff);

    for (pages) |page| {
        try writeImageDirectory(allocator, tiff, .{
            .width = page.width,
            .height = page.height,
            .samples_per_pixel = page.samples_per_pixel,
            .bits_per_sample = page.bits_per_sample,
            .data = page.data,
        }, null);
    }
}

fn minimalTiffBytes(allocator: std.mem.Allocator, dpi: ?Rational) ![]u8 {
    const has_dpi = dpi != null;
    const entry_count: u16 = if (has_dpi) 12 else 9;
    const ifd_offset: u32 = 8;
    const ifd_end: u32 = ifd_offset + 2 + @as(u32, entry_count) * 12 + 4;
    const x_resolution_offset: u32 = ifd_end;
    const y_resolution_offset: u32 = ifd_end + 8;
    const pixel_offset: u32 = if (has_dpi) ifd_end + 16 else ifd_end;

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("II");
    try appendU16(&out, 42);
    try appendU32(&out, ifd_offset);
    try appendU16(&out, entry_count);

    try appendEntry(&out, .{ .tag = 256, .field_type = 4, .count = 1, .value_or_offset = 1 });
    try appendEntry(&out, .{ .tag = 257, .field_type = 4, .count = 1, .value_or_offset = 1 });
    try appendEntry(&out, .{ .tag = 258, .field_type = 3, .count = 1, .value_or_offset = 8 });
    try appendEntry(&out, .{ .tag = 259, .field_type = 3, .count = 1, .value_or_offset = 1 });
    try appendEntry(&out, .{ .tag = 262, .field_type = 3, .count = 1, .value_or_offset = 1 });
    try appendEntry(&out, .{ .tag = 273, .field_type = 4, .count = 1, .value_or_offset = pixel_offset });
    try appendEntry(&out, .{ .tag = 277, .field_type = 3, .count = 1, .value_or_offset = 1 });
    try appendEntry(&out, .{ .tag = 278, .field_type = 4, .count = 1, .value_or_offset = 1 });
    try appendEntry(&out, .{ .tag = 279, .field_type = 4, .count = 1, .value_or_offset = 1 });

    if (dpi) |_| {
        try appendEntry(&out, .{ .tag = 282, .field_type = 5, .count = 1, .value_or_offset = x_resolution_offset });
        try appendEntry(&out, .{ .tag = 283, .field_type = 5, .count = 1, .value_or_offset = y_resolution_offset });
        try appendEntry(&out, .{ .tag = 296, .field_type = 3, .count = 1, .value_or_offset = 2 });
    }

    try appendU32(&out, 0);
    if (dpi) |value| {
        try appendRational(&out, value);
        try appendRational(&out, value);
    }
    try out.append(0);
    return out.toOwnedSlice();
}

fn appendEntry(out: *std.array_list.Managed(u8), entry: IfdEntry) !void {
    try appendU16(out, entry.tag);
    try appendU16(out, entry.field_type);
    try appendU32(out, entry.count);
    try appendU32(out, entry.value_or_offset);
}

fn appendRational(out: *std.array_list.Managed(u8), value: Rational) !void {
    try appendU32(out, value.numerator);
    try appendU32(out, value.denominator);
}

fn appendU16(out: *std.array_list.Managed(u8), value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try out.appendSlice(&bytes);
}

fn appendU32(out: *std.array_list.Managed(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(&bytes);
}
