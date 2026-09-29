//! Rolls: the strips of one film roll, scanned into `<scans>/<roll>/` with
//! the settings they share (film stock, format, resolution, mode) in
//! `roll.json`. The first strip's preview fixes one gamma LUT for the whole
//! roll (`roll.lut.bin`), so every strip gets the same exposure and a Dmin
//! from one strip holds for the others. Processing a strip detects its
//! frames, exports them to `<frames>/<roll>/`, records the result next to
//! the scan, and redraws the roll's review page.

const std = @import("std");

const contracts = @import("scanner/contracts.zig");
const film_lut = @import("scanner/film_lut.zig");
const scanner_lut = @import("scanner/lut.zig");
const processing_config = @import("processing/config.zig");
const export_pipeline = @import("processing/export.zig");
const film_formats = @import("processing/film_formats.zig");
const frames = @import("processing/frames.zig");
const webgpu = @import("processing/webgpu.zig");
const workflow = @import("processing/workflow.zig");
const tiff = @import("tiff.zig");
const scanner_host = @import("scanner.zig").host;

pub const manifest_name = "roll.json";
pub const lut_name = "roll.lut.bin";
pub const review_dir_name = "review";
pub const strip_prefix = "strip_";
pub const processed_suffix = ".processed.json";
const schema = "v600.roll.v1";
const max_name_len = 64;

/// LUT margins for a whole roll, wider than one strip's (0.75, 1.05) so the
/// denser highlights of later strips still fit.
pub const lut_options = film_lut.Options{ .footroom = 0.5, .headroom = 1.08 };

/// Options for measuring a strip's own film range against the roll LUT.
pub const fit_options = film_lut.Options{ .footroom = 1.0, .headroom = 1.0 };

pub const Settings = struct {
    stock: []const u8 = "kodak_gold",
    format: []const u8 = "35mm",
    dpi: u32 = 3200,
    kind: contracts.ScanKind = .rgb_ir,
    /// Clockwise degrees applied to every exported frame; null takes the
    /// format's default (`defaultRotation`).
    rotation: ?i32 = null,
};

/// Turns frames to landscape. 35mm, 6x7, and 6x9 frames have their long side
/// along the strip, so they are portrait in the scan; with strips loaded as
/// on the V600 holder so far, picture tops face the scan's right edge, and a
/// quarter turn counter-clockwise (270) puts them upright. 645 frames are
/// already landscape and 6x6 is square.
pub fn defaultRotation(format: []const u8) i32 {
    for ([_][]const u8{ "35mm", "6x7", "6x9" }) |portrait| {
        if (std.mem.eql(u8, format, portrait)) return 270;
    }
    return 0;
}

fn validRotation(rotation: i32) bool {
    return rotation == 0 or rotation == 90 or rotation == 180 or rotation == 270;
}

pub const Error = error{
    InvalidRollName,
    InvalidRollSettings,
    RollExists,
    RollNotFound,
    InvalidRollManifest,
};

pub const Roll = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    dir: []u8,
    frames_dir: []u8,
    stock: []u8,
    format: []u8,
    dpi: u32,
    kind: contracts.ScanKind,
    /// Clockwise degrees applied to exported frames.
    rotation: i32,
    /// Dmin from the first strip with a detected rebate; the fallback for
    /// strips without one.
    dmin: ?[3]f64 = null,
    lut_black: ?[3]f64 = null,
    lut_white: ?[3]f64 = null,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        scans_root: []const u8,
        frames_root: []const u8,
        name: []const u8,
        settings: Settings,
    ) !Roll {
        try validateName(name);
        try validateSettings(settings);
        var roll = try init(allocator, scans_root, frames_root, name, settings);
        errdefer roll.deinit();
        const manifest = try roll.path(allocator, manifest_name);
        defer allocator.free(manifest);
        if (fileExists(io, manifest)) return Error.RollExists;
        try std.Io.Dir.cwd().createDirPath(io, roll.dir);
        try roll.save(io);
        return roll;
    }

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        scans_root: []const u8,
        frames_root: []const u8,
        name: []const u8,
    ) !Roll {
        try validateName(name);
        const dir = try std.fs.path.join(allocator, &.{ scans_root, name });
        defer allocator.free(dir);
        const manifest_path = try std.fs.path.join(allocator, &.{ dir, manifest_name });
        defer allocator.free(manifest_path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return Error.RollNotFound,
            else => return err,
        };
        defer allocator.free(text);
        const parsed = std.json.parseFromSlice(ManifestJson, allocator, text, .{ .ignore_unknown_fields = true }) catch
            return Error.InvalidRollManifest;
        defer parsed.deinit();
        const m = parsed.value;
        if (!std.mem.eql(u8, m.schema, schema)) return Error.InvalidRollManifest;
        const kind = kindFromName(m.kind) orelse return Error.InvalidRollManifest;
        if (m.rotation) |rotation| {
            if (!validRotation(rotation)) return Error.InvalidRollManifest;
        }
        var roll = try init(allocator, scans_root, frames_root, name, .{
            .stock = m.stock,
            .format = m.format,
            .dpi = m.dpi,
            .kind = kind,
            .rotation = m.rotation,
        });
        roll.dmin = m.dmin;
        roll.lut_black = m.lut_black;
        roll.lut_white = m.lut_white;
        return roll;
    }

    fn init(
        allocator: std.mem.Allocator,
        scans_root: []const u8,
        frames_root: []const u8,
        name: []const u8,
        settings: Settings,
    ) !Roll {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const dir = try std.fs.path.join(allocator, &.{ scans_root, name });
        errdefer allocator.free(dir);
        const frames_dir = try std.fs.path.join(allocator, &.{ frames_root, name });
        errdefer allocator.free(frames_dir);
        const stock = try allocator.dupe(u8, settings.stock);
        errdefer allocator.free(stock);
        const format = try allocator.dupe(u8, settings.format);
        return .{
            .allocator = allocator,
            .name = owned_name,
            .dir = dir,
            .frames_dir = frames_dir,
            .stock = stock,
            .format = format,
            .dpi = settings.dpi,
            .kind = settings.kind,
            .rotation = settings.rotation orelse defaultRotation(settings.format),
        };
    }

    pub fn deinit(self: *Roll) void {
        self.allocator.free(self.name);
        self.allocator.free(self.dir);
        self.allocator.free(self.frames_dir);
        self.allocator.free(self.stock);
        self.allocator.free(self.format);
        self.* = undefined;
    }

    /// `<roll dir>/<name>`; the caller frees it.
    pub fn path(self: *const Roll, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.dir, name });
    }

    pub fn save(self: *const Roll, io: std.Io) !void {
        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();
        try out.print("{{\n  \"schema\": \"{s}\",\n  \"name\": \"{s}\",\n  \"stock\": \"{s}\",\n  \"format\": \"{s}\",\n  \"dpi\": {d},\n  \"kind\": \"{s}\",\n  \"rotation\": {d}", .{
            schema,
            self.name,
            self.stock,
            self.format,
            self.dpi,
            kindName(self.kind),
            self.rotation,
        });
        try appendTriple(&out, "dmin", self.dmin);
        try appendTriple(&out, "lut_black", self.lut_black);
        try appendTriple(&out, "lut_white", self.lut_white);
        try out.appendSlice("\n}\n");
        const manifest = try self.path(self.allocator, manifest_name);
        defer self.allocator.free(manifest);
        try writeFileAtomic(self.allocator, io, manifest, out.items);
    }

    /// The roll's gamma LUT, or null before the first strip sets it.
    pub fn loadLut(self: *const Roll, io: std.Io) !?[scanner_lut.serialized_len]u8 {
        const lut_path = try self.path(self.allocator, lut_name);
        defer self.allocator.free(lut_path);
        var lut: [scanner_lut.serialized_len]u8 = undefined;
        const data = std.Io.Dir.cwd().readFile(io, lut_path, &lut) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        if (data.len != lut.len) return Error.InvalidRollManifest;
        return lut;
    }

    /// Returns the roll LUT, creating it from `computed` (built with
    /// `lut_options`) when this is the roll's first strip.
    pub fn adoptLut(self: *Roll, io: std.Io, computed: film_lut.ComputedLuts) !?[scanner_lut.serialized_len]u8 {
        if (try self.loadLut(io)) |existing| return existing;
        if (computed.red == null and computed.green == null and computed.blue == null) return null;
        var lut: [scanner_lut.serialized_len]u8 = undefined;
        try scanner_lut.serializeRgb(
            &lut,
            if (computed.red) |*table| table else null,
            if (computed.green) |*table| table else null,
            if (computed.blue) |*table| table else null,
        );
        const lut_path = try self.path(self.allocator, lut_name);
        defer self.allocator.free(lut_path);
        try writeFileAtomic(self.allocator, io, lut_path, &lut);
        self.lut_black = .{ computed.black[0] orelse 0.0, computed.black[1] orelse 0.0, computed.black[2] orelse 0.0 };
        self.lut_white = .{ computed.white[0] orelse 255.0, computed.white[1] orelse 255.0, computed.white[2] orelse 255.0 };
        try self.save(io);
        return lut;
    }

    /// Which channels of a strip, measured with `fit_options`, fall outside
    /// the roll LUT's range and would clip.
    pub fn checkLutFit(self: *const Roll, strip: film_lut.ComputedLuts) LutFit {
        var fit = LutFit{};
        const black = self.lut_black orelse return fit;
        const white = self.lut_white orelse return fit;
        for (0..3) |channel| {
            if (strip.black[channel]) |value| fit.dense_clipped[channel] = value < black[channel];
            if (strip.white[channel]) |value| fit.base_clipped[channel] = value > white[channel];
        }
        return fit;
    }

    /// Path for the next strip scan; the caller frees it.
    pub fn nextStripPath(self: *const Roll, io: std.Io) ![]u8 {
        const number = try tiff.nextScanNumber(io, self.dir, strip_prefix);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}{d:0>2}_{s}_{d}dpi.tiff", .{
            self.dir,
            strip_prefix,
            number,
            if (self.kind == .rgb_ir) "rgbir" else "rgb",
            self.dpi,
        });
    }

    /// Strip scans in order; the caller deinits the list.
    pub fn listStrips(self: *const Roll, io: std.Io) !tiff.ImageList {
        var all = try tiff.findImages(self.allocator, io, self.dir);
        var kept: usize = 0;
        for (all.paths) |strip_path| {
            if (std.mem.startsWith(u8, std.fs.path.basename(strip_path), strip_prefix)) {
                all.paths[kept] = strip_path;
                kept += 1;
            } else {
                self.allocator.free(strip_path);
            }
        }
        all.paths = try shrink(self.allocator, all.paths, kept);
        return all;
    }

    pub fn isProcessed(self: *const Roll, io: std.Io, strip_path: []const u8) bool {
        const marker = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ strip_path, processed_suffix }) catch return false;
        defer self.allocator.free(marker);
        return fileExists(io, marker);
    }

    /// Detects the strip's frames, exports them, records the outcome next to
    /// the scan, and redraws the review page.
    pub fn processStrip(self: *Roll, io: std.Io, strip_path: []const u8, options: ProcessOptions) !StripOutcome {
        const allocator = self.allocator;
        const loaded_config = try processing_config.loadFile(allocator, io, options.processing_config_path);
        var override_buffer: [32]processing_config.Override = undefined;
        const overrides = loaded_config.overrides(&override_buffer);
        const stock = loaded_config.availableStock(self.stock) orelse return error.UnknownFilmStock;

        const preview = try workflow.loadQuickPreview(allocator, strip_path, options.preview_size);
        defer preview.deinit(allocator);
        try self.removePreviousExports(io, strip_path);
        var detected = try workflow.autoDetectPreview(allocator, preview, .{ .format = self.format });
        defer detected.deinit(allocator);
        const to_full = 1.0 / preview.info.preview_scale;

        const rects = try allocator.alloc(export_pipeline.FrameRect, detected.frames.len);
        defer allocator.free(rects);
        for (detected.frames, rects) |frame, *rect| {
            rect.* = .{
                .cx = frame.cx * to_full,
                .cy = frame.cy * to_full,
                .w = frame.w * to_full,
                .h = frame.h * to_full,
                .angle = std.math.radiansToDegrees(frame.angle),
                .rotation = self.rotation,
            };
        }
        const rebate_rect = if (detected.rebate) |rebate| try workflow.fullResolutionRebate(rebate, preview.info.preview_scale) else null;
        const use_roll_dmin = rebate_rect == null and self.dmin != null;

        const basename = try self.stripBasename(strip_path);
        defer allocator.free(basename);
        var outcome = StripOutcome{
            .frames = rects.len,
            .dmin_source = if (rebate_rect != null) "rebate" else if (use_roll_dmin) "roll" else "image",
            .files = &.{},
        };
        errdefer outcome.deinit(allocator);
        if (rects.len != 0) {
            const result = try workflow.processExportFromTiff(allocator, io, .{
                .input_path = strip_path,
                .output_dir = self.frames_dir,
                .basename = basename,
                .rects = rects,
                .outputs = options.outputs,
                .active_stock = self.stock,
                .stock_coeffs = stock.coeffs,
                .dmin = if (use_roll_dmin) self.dmin else null,
                .rebate_rect = rebate_rect,
                .config_overrides = overrides,
                .invert_request = options.invert_request,
            });
            defer result.deinit(allocator);
            outcome.dmin = result.dmin;
            outcome.files = try allocator.alloc([]u8, result.files.len);
            for (outcome.files) |*file| file.* = &.{};
            for (result.files, outcome.files) |file, *copy| copy.* = try allocator.dupe(u8, file);
            // Frames export in parallel and finish in any order.
            std.mem.sort([]u8, outcome.files, {}, lessThanString);
        }
        if (rebate_rect != null and self.dmin == null and outcome.dmin != null) {
            self.dmin = outcome.dmin;
            try self.save(io);
        }

        try self.writeReviewImage(io, strip_path, preview, detected);
        try self.writeMarker(io, strip_path, outcome);
        try self.writeReviewIndex(io);
        return outcome;
    }

    /// Deletes the files an earlier run exported for this strip, as listed
    /// in its result file, so reprocessing replaces them.
    fn removePreviousExports(self: *const Roll, io: std.Io, strip_path: []const u8) !void {
        const marker = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ strip_path, processed_suffix });
        defer self.allocator.free(marker);
        const text = std.Io.Dir.cwd().readFileAlloc(io, marker, self.allocator, .limited(64 * 1024)) catch return;
        defer self.allocator.free(text);
        const parsed = std.json.parseFromSlice(MarkerJson, self.allocator, text, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        for (parsed.value.files) |file| {
            if (std.mem.indexOfScalar(u8, file, '/') != null) continue;
            const file_path = try std.fs.path.join(self.allocator, &.{ self.frames_dir, file });
            defer self.allocator.free(file_path);
            std.Io.Dir.cwd().deleteFile(io, file_path) catch {};
        }
        std.Io.Dir.cwd().deleteFile(io, marker) catch {};
    }

    /// `<roll>_sNN`, the export basename for a strip.
    fn stripBasename(self: *const Roll, strip_path: []const u8) ![]u8 {
        const number = stripNumber(strip_path) orelse return error.InvalidStripName;
        return std.fmt.allocPrint(self.allocator, "{s}_s{d:0>2}", .{ self.name, number });
    }

    fn writeMarker(self: *const Roll, io: std.Io, strip_path: []const u8, outcome: StripOutcome) !void {
        var out = std.array_list.Managed(u8).init(self.allocator);
        defer out.deinit();
        try out.print("{{\n  \"frames\": {d},\n  \"dmin_source\": \"{s}\"", .{ outcome.frames, outcome.dmin_source });
        try appendTriple(&out, "dmin", outcome.dmin);
        try out.appendSlice(",\n  \"files\": [");
        for (outcome.files, 0..) |file, index| {
            try out.print("{s}\"{s}\"", .{ if (index == 0) "" else ", ", std.fs.path.basename(file) });
        }
        try out.appendSlice("]\n}\n");
        const marker = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ strip_path, processed_suffix });
        defer self.allocator.free(marker);
        try writeFileAtomic(self.allocator, io, marker, out.items);
    }

    fn reviewImagePath(self: *const Roll, strip_path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}.jpg", .{
            self.dir,
            review_dir_name,
            std.fs.path.stem(std.fs.path.basename(strip_path)),
        });
    }

    /// The strip as the detector saw it, frames and rebate outlined.
    fn writeReviewImage(
        self: *const Roll,
        io: std.Io,
        strip_path: []const u8,
        preview: workflow.QuickPreview,
        detected: workflow.AutoDetectResult,
    ) !void {
        const allocator = self.allocator;
        const long_side = @max(preview.preview_width, preview.preview_height);
        const factor = @max(@as(usize, 1), (long_side + review_long_side - 1) / review_long_side);
        var image = try downscaleRgb8(allocator, preview.preview_rgb8, preview.preview_width, preview.preview_height, factor);
        defer allocator.free(image.pixels);
        const scale = 1.0 / @as(f64, @floatFromInt(factor));
        for (detected.frames, 0..) |frame, index| {
            drawRotatedRect(&image, frame.cx * scale, frame.cy * scale, frame.w * scale, frame.h * scale, frame.angle, frame_colors[index % frame_colors.len]);
        }
        if (detected.rebate) |rebate| {
            drawRotatedRect(&image, rebate.cx * scale, rebate.cy * scale, rebate.w * scale, rebate.h * scale, rebate.angle, rebate_color);
        }
        const jpeg = try workflow.encodeRgbJpeg(allocator, image.pixels, image.width, image.height, 85);
        defer allocator.free(jpeg);
        const review_dir = try self.path(allocator, review_dir_name);
        defer allocator.free(review_dir);
        try std.Io.Dir.cwd().createDirPath(io, review_dir);
        const out_path = try self.reviewImagePath(strip_path);
        defer allocator.free(out_path);
        try writeFileAtomic(allocator, io, out_path, jpeg);
    }

    /// `<roll dir>/review/index.html`: every strip with its detected frames,
    /// Dmin, and exported files.
    pub fn writeReviewIndex(self: *const Roll, io: std.Io) !void {
        const allocator = self.allocator;
        var strips = try self.listStrips(io);
        defer strips.deinit(allocator);

        const has_image = try allocator.alloc(bool, strips.paths.len);
        defer allocator.free(has_image);
        var waiting = strips.paths.len == 0;
        for (strips.paths, has_image) |strip_path, *exists| {
            const image_path = try self.reviewImagePath(strip_path);
            defer allocator.free(image_path);
            exists.* = fileExists(io, image_path);
            if (!exists.*) waiting = true;
        }

        var out = std.array_list.Managed(u8).init(allocator);
        defer out.deinit();
        // Reload while strips are still to come, so an open page catches up.
        const refresh = if (waiting) "<meta http-equiv=refresh content=30>" else "";
        try out.print(review_head, .{ refresh, self.name, self.name, self.stock, self.format, self.dpi, kindName(self.kind) });
        if (self.dmin) |dmin| {
            try out.print("<p class=meta>Roll Dmin {d:.3} / {d:.3} / {d:.3}</p>\n", .{ dmin[0], dmin[1], dmin[2] });
        }
        try out.appendSlice("<p class=meta>Frame outlines, top to bottom:");
        for (frame_colors, 0..) |color, index| {
            try out.print(" <span class=swatch style=\"background:rgb({d},{d},{d})\"></span>{d}", .{ color[0], color[1], color[2], index + 1 });
        }
        try out.print(" <span class=swatch style=\"background:rgb({d},{d},{d})\"></span>rebate (Dmin)</p>\n<div class=strips>\n", .{ rebate_color[0], rebate_color[1], rebate_color[2] });
        if (strips.paths.len == 0) {
            try out.appendSlice("<p class=meta>No strips yet. A strip appears here when its scan finishes.</p>\n");
        }
        for (strips.paths, has_image) |strip_path, exists| {
            const stem = std.fs.path.stem(std.fs.path.basename(strip_path));
            if (exists) {
                try out.print("<figure><img src=\"{s}.jpg\" alt=\"\"><figcaption><b>{s}</b><br>", .{ stem, stem });
            } else {
                try out.print("<figure><figcaption><b>{s}</b><br>", .{stem});
            }
            const marker = try std.fmt.allocPrint(allocator, "{s}{s}", .{ strip_path, processed_suffix });
            defer allocator.free(marker);
            const text = std.Io.Dir.cwd().readFileAlloc(io, marker, allocator, .limited(64 * 1024)) catch null;
            if (text) |marker_text| {
                defer allocator.free(marker_text);
                if (std.json.parseFromSlice(MarkerJson, allocator, marker_text, .{ .ignore_unknown_fields = true })) |parsed| {
                    defer parsed.deinit();
                    const m = parsed.value;
                    try out.print("{d} frame{s}, Dmin from {s}", .{ m.frames, if (m.frames == 1) "" else "s", m.dmin_source });
                    if (m.dmin) |dmin| try out.print(" ({d:.3} / {d:.3} / {d:.3})", .{ dmin[0], dmin[1], dmin[2] });
                    try out.appendSlice("<br><span class=files>");
                    for (m.files) |file| try out.print("{s}<br>", .{file});
                    try out.appendSlice("</span>");
                } else |_| {
                    try out.appendSlice("unreadable result");
                }
            } else {
                try out.appendSlice("scanned; the picture appears when its export finishes");
            }
            try out.appendSlice("</figcaption></figure>\n");
        }
        try out.appendSlice("</div>\n</main></body></html>\n");

        const review_dir = try self.path(allocator, review_dir_name);
        defer allocator.free(review_dir);
        try std.Io.Dir.cwd().createDirPath(io, review_dir);
        const index_path = try std.fs.path.join(allocator, &.{ review_dir, "index.html" });
        defer allocator.free(index_path);
        try writeFileAtomic(allocator, io, index_path, out.items);
    }
};

/// Processes finished strips of one roll, one at a time, on a background
/// thread, so the next strip can scan meanwhile. Uses the thread-safe
/// `std.heap.smp_allocator` for everything it owns.
pub const Processor = struct {
    const allocator = std.heap.smp_allocator;

    pub const Done = struct {
        strip: []const u8,
        outcome: ?StripOutcome,
        err: ?anyerror,
        seconds: i64,
    };

    io: std.Io,
    scans_root: []u8,
    frames_root: []u8,
    roll_name: []u8,
    options: ProcessOptions,
    on_done: ?*const fn (context: ?*anyopaque, done: Done) void,
    context: ?*anyopaque,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: std.array_list.Managed([]u8),
    closing: bool = false,
    busy: bool = false,
    thread: std.Thread = undefined,

    pub fn start(
        io: std.Io,
        scans_root: []const u8,
        frames_root: []const u8,
        roll_name: []const u8,
        options: ProcessOptions,
        on_done: ?*const fn (context: ?*anyopaque, done: Done) void,
        context: ?*anyopaque,
    ) !*Processor {
        const self = try allocator.create(Processor);
        errdefer allocator.destroy(self);
        self.* = .{
            .io = io,
            .scans_root = try allocator.dupe(u8, scans_root),
            .frames_root = try allocator.dupe(u8, frames_root),
            .roll_name = try allocator.dupe(u8, roll_name),
            .options = options,
            .on_done = on_done,
            .context = context,
            .queue = std.array_list.Managed([]u8).init(allocator),
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn enqueue(self: *Processor, strip_path: []const u8) !void {
        const owned = try allocator.dupe(u8, strip_path);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.queue.append(owned) catch |err| {
            allocator.free(owned);
            return err;
        };
        self.condition.signal(self.io);
    }

    /// Strips queued or in progress.
    pub fn pending(self: *Processor) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.queue.items.len + @intFromBool(self.busy);
    }

    /// Drops strips not yet started; the one in progress still finishes.
    pub fn dropPending(self: *Processor) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.queue.items) |strip| allocator.free(strip);
        self.queue.clearRetainingCapacity();
    }

    /// Finishes the queued strips, then stops the thread and frees `self`.
    pub fn finish(self: *Processor) void {
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        self.thread.join();
        for (self.queue.items) |strip| allocator.free(strip);
        self.queue.deinit();
        allocator.free(self.scans_root);
        allocator.free(self.frames_root);
        allocator.free(self.roll_name);
        allocator.destroy(self);
    }

    fn run(self: *Processor) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.queue.items.len == 0 and !self.closing) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.queue.items.len == 0) {
                self.mutex.unlock(self.io);
                return;
            }
            const strip = self.queue.orderedRemove(0);
            self.busy = true;
            self.mutex.unlock(self.io);

            self.process(strip);
            allocator.free(strip);

            self.mutex.lockUncancelable(self.io);
            self.busy = false;
            self.mutex.unlock(self.io);
        }
    }

    fn process(self: *Processor, strip: []const u8) void {
        const started = std.Io.Clock.real.now(self.io).toSeconds();
        // A fresh Roll per strip picks up the Dmin earlier strips recorded.
        var roll = Roll.open(allocator, self.io, self.scans_root, self.frames_root, self.roll_name) catch |err| {
            self.report(.{ .strip = strip, .outcome = null, .err = err, .seconds = 0 });
            return;
        };
        defer roll.deinit();
        const outcome = roll.processStrip(self.io, strip, self.options) catch |err| {
            self.report(.{ .strip = strip, .outcome = null, .err = err, .seconds = std.Io.Clock.real.now(self.io).toSeconds() - started });
            return;
        };
        defer outcome.deinit(allocator);
        self.report(.{ .strip = strip, .outcome = outcome, .err = null, .seconds = std.Io.Clock.real.now(self.io).toSeconds() - started });
    }

    fn report(self: *Processor, done: Done) void {
        if (self.on_done) |callback| callback(self.context, done);
    }
};

pub const LutFit = struct {
    dense_clipped: [3]bool = .{ false, false, false },
    base_clipped: [3]bool = .{ false, false, false },

    pub fn ok(self: LutFit) bool {
        for (self.dense_clipped, self.base_clipped) |dense, base| {
            if (dense or base) return false;
        }
        return true;
    }
};

pub const ProcessOptions = struct {
    processing_config_path: []const u8 = processing_config.config_file,
    /// Detection preview size, as `processing detect` uses.
    preview_size: i64 = 8192,
    outputs: export_pipeline.OutputSelection = .{},
    invert_request: webgpu.Request = .{},
};

pub const StripOutcome = struct {
    frames: usize,
    dmin: ?[3]f64 = null,
    /// "rebate" (this strip), "roll" (another strip's), or "image".
    dmin_source: []const u8,
    files: [][]u8,

    pub fn deinit(self: StripOutcome, allocator: std.mem.Allocator) void {
        for (self.files) |file| {
            if (file.len != 0) allocator.free(file);
        }
        if (self.files.len != 0) allocator.free(self.files);
    }
};

const ManifestJson = struct {
    schema: []const u8,
    name: []const u8,
    stock: []const u8,
    format: []const u8,
    dpi: u32,
    kind: []const u8,
    rotation: ?i32 = null,
    dmin: ?[3]f64 = null,
    lut_black: ?[3]f64 = null,
    lut_white: ?[3]f64 = null,
};

const MarkerJson = struct {
    frames: usize,
    dmin_source: []const u8,
    dmin: ?[3]f64 = null,
    files: []const []const u8 = &.{},
};

/// Names of the rolls under `scans_root` (directories with a `roll.json`),
/// sorted. The caller frees each name and the slice.
pub fn listRolls(allocator: std.mem.Allocator, io: std.Io, scans_root: []const u8) ![][]u8 {
    var names = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit();
    }
    var dir = std.Io.Dir.cwd().openDir(io, scans_root, .{ .iterate = true }) catch return names.toOwnedSlice();
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        validateName(entry.name) catch continue;
        const manifest = try std.fs.path.join(allocator, &.{ scans_root, entry.name, manifest_name });
        defer allocator.free(manifest);
        if (!fileExists(io, manifest)) continue;
        try names.append(try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, lessThanString);
    return names.toOwnedSlice();
}

/// Roll names become directory and file names: letters, digits, `.`, `_`,
/// and `-`, not starting with `.`.
pub fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_len or name[0] == '.') return Error.InvalidRollName;
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-')) return Error.InvalidRollName;
    }
}

fn validateSettings(settings: Settings) Error!void {
    if (settings.kind != .rgb and settings.kind != .rgb_ir) return Error.InvalidRollSettings;
    if (std.mem.indexOfScalar(u32, &scanner_host.film_dpis, settings.dpi) == null) return Error.InvalidRollSettings;
    if (film_formats.formatByName(settings.format) == null) return Error.InvalidRollSettings;
    if (settings.stock.len == 0) return Error.InvalidRollSettings;
    if (settings.rotation) |rotation| {
        if (!validRotation(rotation)) return Error.InvalidRollSettings;
    }
}

pub fn kindName(kind: contracts.ScanKind) []const u8 {
    return switch (kind) {
        .rgb_ir => "rgb+ir",
        .rgb => "rgb",
        .gray => "gray",
        .ir => "ir",
    };
}

pub fn kindFromName(name: []const u8) ?contracts.ScanKind {
    if (std.mem.eql(u8, name, "rgb+ir")) return .rgb_ir;
    if (std.mem.eql(u8, name, "rgb")) return .rgb;
    return null;
}

/// The NN of `strip_NN_...`.
pub fn stripNumber(strip_path: []const u8) ?usize {
    const name = std.fs.path.basename(strip_path);
    if (!std.mem.startsWith(u8, name, strip_prefix)) return null;
    const rest = name[strip_prefix.len..];
    const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
    return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
}

fn appendTriple(out: *std.array_list.Managed(u8), key: []const u8, value: ?[3]f64) !void {
    if (value) |v| {
        try out.print(",\n  \"{s}\": [{d}, {d}, {d}]", .{ key, v[0], v[1], v[2] });
    } else {
        try out.print(",\n  \"{s}\": null", .{key});
    }
}

fn lessThanString(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn fileExists(io: std.Io, file_path: []const u8) bool {
    std.Io.Dir.cwd().access(io, file_path, .{}) catch return false;
    return true;
}

/// Writes `<path>.partial` and renames it over `path`, so readers never see
/// a half-written file.
pub fn writeFileAtomic(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, data: []const u8) !void {
    const partial = try std.fmt.allocPrint(allocator, "{s}.partial", .{file_path});
    defer allocator.free(partial);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = partial, .data = data, .flags = .{ .truncate = true } });
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(partial, cwd, file_path, io);
}

fn shrink(allocator: std.mem.Allocator, paths: [][]u8, len: usize) ![][]u8 {
    if (len == paths.len) return paths;
    const kept = try allocator.alloc([]u8, len);
    @memcpy(kept, paths[0..len]);
    allocator.free(paths);
    return kept;
}

const review_long_side: usize = 1600;
const frame_colors = [_][3]u8{
    .{ 255, 64, 64 },
    .{ 255, 170, 0 },
    .{ 60, 200, 60 },
    .{ 40, 160, 255 },
    .{ 200, 80, 255 },
    .{ 255, 255, 255 },
};
const rebate_color = [3]u8{ 0, 255, 255 };

const Rgb8Image = struct {
    width: usize,
    height: usize,
    pixels: []u8,
};

fn downscaleRgb8(allocator: std.mem.Allocator, src: []const u8, width: usize, height: usize, factor: usize) !Rgb8Image {
    const out_w = @max(@as(usize, 1), width / factor);
    const out_h = @max(@as(usize, 1), height / factor);
    const out = try allocator.alloc(u8, out_w * out_h * 3);
    for (0..out_h) |oy| {
        for (0..out_w) |ox| {
            var sums = [_]u32{ 0, 0, 0 };
            var count: u32 = 0;
            for (oy * factor..@min(height, (oy + 1) * factor)) |y| {
                for (ox * factor..@min(width, (ox + 1) * factor)) |x| {
                    for (0..3) |channel| sums[channel] += src[(y * width + x) * 3 + channel];
                    count += 1;
                }
            }
            for (0..3) |channel| out[(oy * out_w + ox) * 3 + channel] = @intCast(sums[channel] / @max(count, 1));
        }
    }
    return .{ .width = out_w, .height = out_h, .pixels = out };
}

fn drawRotatedRect(image: *Rgb8Image, cx: f64, cy: f64, w: f64, h: f64, angle: f64, color: [3]u8) void {
    const c = @cos(angle);
    const s = @sin(angle);
    const offsets = [_][2]f64{ .{ -w / 2, -h / 2 }, .{ w / 2, -h / 2 }, .{ w / 2, h / 2 }, .{ -w / 2, h / 2 } };
    var corners: [4][2]f64 = undefined;
    for (offsets, &corners) |offset, *corner| {
        corner.* = .{ cx + offset[0] * c - offset[1] * s, cy + offset[0] * s + offset[1] * c };
    }
    for (0..4) |index| {
        const a = corners[index];
        const b = corners[(index + 1) % 4];
        drawLine(image, a[0], a[1], b[0], b[1], color);
    }
}

/// A two-pixel-wide line, clipped to the image.
fn drawLine(image: *Rgb8Image, x0: f64, y0: f64, x1: f64, y1: f64, color: [3]u8) void {
    const steps: usize = @intFromFloat(@max(1.0, @ceil(@max(@abs(x1 - x0), @abs(y1 - y0)))));
    for (0..steps + 1) |step| {
        const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
        const x = x0 + (x1 - x0) * t;
        const y = y0 + (y1 - y0) * t;
        for ([_]f64{ 0, 1 }) |dy| {
            for ([_]f64{ 0, 1 }) |dx| setPixel(image, x + dx - 0.5, y + dy - 0.5, color);
        }
    }
}

fn setPixel(image: *Rgb8Image, x: f64, y: f64, color: [3]u8) void {
    if (x < 0 or y < 0) return;
    const px: usize = @intFromFloat(x);
    const py: usize = @intFromFloat(y);
    if (px >= image.width or py >= image.height) return;
    @memcpy(image.pixels[(py * image.width + px) * 3 ..][0..3], &color);
}

const review_head =
    \\<!doctype html>
    \\<html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width, initial-scale=1">{s}
    \\<title>Roll {s}</title>
    \\<style>
    \\:root {{ --bg:#f7f7f5; --fg:#1d1d1f; --muted:#6b6b70; --line:#dcdcd8; }}
    \\@media (prefers-color-scheme: dark) {{ :root {{ --bg:#17171a; --fg:#ececec; --muted:#9a9aa2; --line:#34343a; }} }}
    \\body {{ margin:0; background:var(--bg); color:var(--fg); font:14px/1.45 -apple-system, system-ui, sans-serif; }}
    \\main {{ padding:20px 16px 48px; }}
    \\h1 {{ font-size:22px; margin:0 0 4px; }}
    \\.meta {{ color:var(--muted); margin:2px 0; }}
    \\.swatch {{ display:inline-block; width:11px; height:11px; margin:0 3px 0 10px; vertical-align:-1px; }}
    \\.strips {{ display:flex; flex-wrap:wrap; gap:18px; margin-top:16px; align-items:flex-start; }}
    \\figure {{ margin:0; max-width:320px; }}
    \\figure img {{ display:block; max-height:80vh; max-width:100%; border:1px solid var(--line); }}
    \\figcaption {{ font-size:13px; margin-top:6px; }}
    \\.files {{ color:var(--muted); font-size:12px; }}
    \\</style></head><body><main>
    \\<h1>Roll {s}</h1>
    \\<p class=meta>{s}, {s}, {d} dpi, {s}</p>
    \\
;

test "roll names are safe directory names" {
    try validateName("gold200-a");
    try validateName("2026_09.portra");
    try std.testing.expectError(Error.InvalidRollName, validateName(""));
    try std.testing.expectError(Error.InvalidRollName, validateName(".hidden"));
    try std.testing.expectError(Error.InvalidRollName, validateName("a/b"));
    try std.testing.expectError(Error.InvalidRollName, validateName("with space"));
}

test "creates, reopens, and numbers the strips of a roll" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const scans = try std.fs.path.join(allocator, &.{ root, "scans" });
    defer allocator.free(scans);
    const frames_root = try std.fs.path.join(allocator, &.{ root, "frames" });
    defer allocator.free(frames_root);

    var roll = try Roll.create(allocator, io, scans, frames_root, "gold-a", .{ .stock = "kodak_portra", .format = "645", .dpi = 1600, .kind = .rgb });
    defer roll.deinit();
    try std.testing.expectError(Error.RollExists, Roll.create(allocator, io, scans, frames_root, "gold-a", .{}));
    try std.testing.expectError(Error.InvalidRollSettings, Roll.create(allocator, io, scans, frames_root, "bad", .{ .format = "110" }));
    try std.testing.expectError(Error.RollNotFound, Roll.open(allocator, io, scans, frames_root, "missing"));
    {
        const html = try testReviewHtml(&roll);
        defer allocator.free(html);
        try std.testing.expect(std.mem.indexOf(u8, html, "No strips yet") != null);
        try std.testing.expect(std.mem.indexOf(u8, html, "http-equiv=refresh") != null);
    }

    const first = try roll.nextStripPath(io);
    defer allocator.free(first);
    try std.testing.expect(std.mem.endsWith(u8, first, "/gold-a/strip_01_rgb_1600dpi.tiff"));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = first, .data = "x" });
    const second = try roll.nextStripPath(io);
    defer allocator.free(second);
    try std.testing.expect(std.mem.endsWith(u8, second, "strip_02_rgb_1600dpi.tiff"));
    try std.testing.expectEqual(@as(?usize, 2), stripNumber(second));

    roll.dmin = .{ 0.1, 0.2, 0.3 };
    try roll.save(io);
    var reopened = try Roll.open(allocator, io, scans, frames_root, "gold-a");
    defer reopened.deinit();
    try std.testing.expectEqualStrings("kodak_portra", reopened.stock);
    try std.testing.expectEqualStrings("645", reopened.format);
    try std.testing.expectEqual(@as(u32, 1600), reopened.dpi);
    try std.testing.expectEqual(contracts.ScanKind.rgb, reopened.kind);
    try std.testing.expectEqual(@as(i32, 0), reopened.rotation);
    try std.testing.expectEqual(@as(f64, 0.2), reopened.dmin.?[1]);
    try std.testing.expect(std.mem.endsWith(u8, reopened.frames_dir, "frames/gold-a"));

    var strips = try reopened.listStrips(io);
    defer strips.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), strips.paths.len);
    try std.testing.expect(!reopened.isProcessed(io, strips.paths[0]));

    // A scanned strip without its review picture yet gets no broken image.
    const html = try testReviewHtml(&reopened);
    defer allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<img") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "strip_01_rgb_1600dpi</b><br>scanned; the picture appears") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "http-equiv=refresh") != null);
}

fn testReviewHtml(roll: *const Roll) ![]u8 {
    try roll.writeReviewIndex(std.testing.io);
    const review = try roll.path(std.testing.allocator, "review/index.html");
    defer std.testing.allocator.free(review);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, review, std.testing.allocator, .limited(64 * 1024));
}

test "exported frames default to landscape for formats that are portrait in the scan" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);

    try std.testing.expectEqual(@as(i32, 270), defaultRotation("35mm"));
    try std.testing.expectEqual(@as(i32, 270), defaultRotation("6x9"));
    try std.testing.expectEqual(@as(i32, 0), defaultRotation("645"));
    try std.testing.expectEqual(@as(i32, 0), defaultRotation("6x6"));
    try std.testing.expectError(Error.InvalidRollSettings, Roll.create(allocator, io, root, root, "bad", .{ .rotation = 45 }));

    var turned = try Roll.create(allocator, io, root, root, "turned", .{ .rotation = 90 });
    turned.deinit();
    var reopened = try Roll.open(allocator, io, root, root, "turned");
    defer reopened.deinit();
    try std.testing.expectEqual(@as(i32, 90), reopened.rotation);

    // Rolls saved before rotation existed take the format's default.
    const old_dir = try std.fs.path.join(allocator, &.{ root, "old" });
    defer allocator.free(old_dir);
    try std.Io.Dir.cwd().createDirPath(io, old_dir);
    const old_manifest = try std.fs.path.join(allocator, &.{ old_dir, manifest_name });
    defer allocator.free(old_manifest);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = old_manifest,
        .data =
        \\{"schema": "v600.roll.v1", "name": "old", "stock": "kodak_gold", "format": "35mm", "dpi": 3200, "kind": "rgb+ir"}
        ,
    });
    var old = try Roll.open(allocator, io, root, root, "old");
    defer old.deinit();
    try std.testing.expectEqual(@as(i32, 270), old.rotation);
}

test "lists the rolls under a scans directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    var b = try Roll.create(allocator, io, root, root, "b-roll", .{});
    b.deinit();
    var a = try Roll.create(allocator, io, root, root, "a-roll", .{});
    a.deinit();
    try tmp.dir.createDir(io, "not-a-roll", .default_dir);
    const names = try listRolls(allocator, io, root);
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("a-roll", names[0]);
    try std.testing.expectEqualStrings("b-roll", names[1]);
}

test "the first strip's LUT becomes the roll's and later strips are checked against it" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    var roll = try Roll.create(allocator, io, root, root, "r1", .{});
    defer roll.deinit();

    var red: [256]u8 = undefined;
    for (&red, 0..) |*value, index| value.* = @intCast(255 - index);
    const first = try roll.adoptLut(io, .{ .red = red, .black = .{ 8.0, 2.0, 0.0 }, .white = .{ 96.0, 49.0, 23.0 } });
    try std.testing.expectEqual(@as(u8, 255), first.?[0]);
    try std.testing.expectEqual(@as(u8, 0), first.?[256]);
    // A later strip keeps the roll LUT whatever it computes itself.
    const second = try roll.adoptLut(io, .{});
    try std.testing.expectEqualSlices(u8, &first.?, &second.?);

    var reopened = try Roll.open(allocator, io, root, root, "r1");
    defer reopened.deinit();
    try std.testing.expectEqual(@as(f64, 96.0), reopened.lut_white.?[0]);
    try std.testing.expect(reopened.checkLutFit(.{ .black = .{ 9.0, 3.0, 0.5 }, .white = .{ 90.0, 45.0, 22.0 } }).ok());
    const fit = reopened.checkLutFit(.{ .black = .{ 7.0, 3.0, 0.5 }, .white = .{ 90.0, 50.0, 22.0 } });
    try std.testing.expect(!fit.ok());
    try std.testing.expect(fit.dense_clipped[0] and !fit.dense_clipped[1]);
    try std.testing.expect(fit.base_clipped[1] and !fit.base_clipped[0]);
}

test "review drawing stays inside the image" {
    const allocator = std.testing.allocator;
    var image = Rgb8Image{ .width = 20, .height = 10, .pixels = try allocator.alloc(u8, 20 * 10 * 3) };
    defer allocator.free(image.pixels);
    @memset(image.pixels, 0);
    drawRotatedRect(&image, 10, 5, 30, 30, 0.3, .{ 255, 0, 0 });
    drawRotatedRect(&image, 10, 5, 8, 4, 0.0, .{ 0, 255, 0 });
    try std.testing.expectEqual(@as(u8, 255), image.pixels[(3 * 20 + 6) * 3 + 1]);
    const small = try downscaleRgb8(allocator, image.pixels, 20, 10, 3);
    defer allocator.free(small.pixels);
    try std.testing.expectEqual(@as(usize, 6), small.width);
    try std.testing.expectEqual(@as(usize, 3), small.height);
}

test "processes a real strip scan into exports, a marker, and a review page" {
    // Uses a local real scan when present; a fresh clone has none.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const source = "scans/scan_0006_rgbir_800dpi.tiff";
    std.Io.Dir.cwd().access(io, source, .{}) catch return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const exports_root = try std.fs.path.join(allocator, &.{ root, "frames" });
    defer allocator.free(exports_root);
    var roll = try Roll.create(allocator, io, root, exports_root, "real", .{ .dpi = 800 });
    defer roll.deinit();
    const strip = try roll.nextStripPath(io);
    defer allocator.free(strip);
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source, std.Io.Dir.cwd(), strip, io, .{});

    const outcome = try roll.processStrip(io, strip, .{
        .processing_config_path = "no-such-config.toml",
        .outputs = .{ .ir_neg = false, .ir_inv = false, .inv_only = true },
    });
    defer outcome.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), outcome.frames);
    try std.testing.expectEqualStrings("rebate", outcome.dmin_source);
    try std.testing.expectEqual(@as(usize, 5), outcome.files.len);
    try std.testing.expect(std.mem.endsWith(u8, outcome.files[0], "real_s01_01_inv.tif"));
    try std.testing.expect(std.mem.endsWith(u8, outcome.files[4], "real_s01_05_inv.tif"));
    try std.testing.expect(roll.isProcessed(io, strip));
    {
        // 35mm frames come out landscape, with the scan's DPI and date.
        const first = try std.fs.path.join(allocator, &.{ roll.frames_dir, outcome.files[0] });
        defer allocator.free(first);
        const info = try tiff.readRgbIrPageInfo(allocator, first);
        try std.testing.expect(info.rgb.width > info.rgb.height);
        try std.testing.expectEqual(@as(?u32, 800), try tiff.readDpi(allocator, first));
        const scan_date = (try tiff.readDateTime(allocator, strip)).?;
        defer allocator.free(scan_date);
        const frame_date = (try tiff.readDateTime(allocator, first)).?;
        defer allocator.free(frame_date);
        try std.testing.expectEqualStrings(scan_date, frame_date);
    }
    try std.testing.expect(roll.dmin != null);
    const review = try roll.path(allocator, "review/index.html");
    defer allocator.free(review);
    const html = try std.Io.Dir.cwd().readFileAlloc(io, review, allocator, .limited(64 * 1024));
    defer allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "5 frames, Dmin from rebate") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<img src=\"strip_01_rgbir_800dpi.jpg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "http-equiv=refresh") == null);

    // Reprocessing replaces the strip's exports instead of adding copies.
    const again = try roll.processStrip(io, strip, .{
        .processing_config_path = "no-such-config.toml",
        .outputs = .{ .ir_neg = false, .ir_inv = false, .inv_only = true },
    });
    defer again.deinit(allocator);
    try std.testing.expectEqualSlices(u8, outcome.files[0], again.files[0]);
    var exported = try tiff.findImages(allocator, io, roll.frames_dir);
    defer exported.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), exported.paths.len);
}

test "the background processor reports every queued strip before it stops" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    var roll = try Roll.create(allocator, io, root, root, "queue", .{});
    defer roll.deinit();

    const Counter = struct {
        failed: std.atomic.Value(usize) = .init(0),
        fn done(context: ?*anyopaque, result: Processor.Done) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (result.err != null) _ = self.failed.fetchAdd(1, .monotonic);
        }
    };
    var counter = Counter{};
    const processor = try Processor.start(io, root, root, "queue", .{}, Counter.done, &counter);
    // Neither strip exists, so both report an error.
    try processor.enqueue("missing/strip_01_rgbir_3200dpi.tiff");
    try processor.enqueue("missing/strip_02_rgbir_3200dpi.tiff");
    processor.finish();
    try std.testing.expectEqual(@as(usize, 2), counter.failed.load(.monotonic));
}
