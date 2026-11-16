//! The Frame view's live preview: one frame cut from the strip preview and
//! rendered as its export is, with the frame's own settings, in a worker
//! thread. The cut frame and its inversion stay cached in the worker, so a
//! settings change only renders again.

const std = @import("std");

const processing_export = @import("../processing/export.zig");
const film_stocks = @import("../processing/film_stocks.zig");
const icc = @import("../processing/icc.zig");
const inversion = @import("../processing/inversion.zig");
const processing_render = @import("../processing/render.zig");
const rgb_space = @import("../processing/rgb_space.zig");

/// What the frame is cut from and how it inverts.
pub const CropKey = struct {
    generation: usize,
    raw_ptr: usize,
    rect: processing_export.FrameRect,
    coeffs: film_stocks.Coefficients,
    dmin: ?[3]f64,

    pub fn eql(self: CropKey, other: CropKey) bool {
        return self.generation == other.generation and self.raw_ptr == other.raw_ptr and
            std.meta.eql(self.rect, other.rect) and std.meta.eql(self.coeffs, other.coeffs) and
            std.meta.eql(self.dmin, other.dmin);
    }
};

/// A soft proof: the frame as a printer profile renders it, on screen.
pub const Proof = struct {
    path: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,
    options: icc.Options = .{},
    paper_white: bool = false,

    pub fn init(path: []const u8, options: icc.Options, paper_white: bool) ?Proof {
        if (path.len > std.fs.max_path_bytes) return null;
        var proof = Proof{ .options = options, .paper_white = paper_white, .len = path.len };
        @memcpy(proof.path[0..path.len], path);
        return proof;
    }

    pub fn slice(self: *const Proof) []const u8 {
        return self.path[0..self.len];
    }

    pub fn eql(self: *const Proof, other: *const Proof) bool {
        return std.mem.eql(u8, self.slice(), other.slice()) and std.meta.eql(self.options, other.options) and self.paper_white == other.paper_white;
    }
};

pub const Key = struct {
    crop: CropKey,
    render_options: processing_render.RenderToDisplayOptions,
    proof: ?Proof = null,
    /// The screen's gamut: sRGB gives 8-bit sRGB; a wider one (Display P3)
    /// gives linear light in sRGB's primaries, past 0 and 1 where the
    /// colour is outside sRGB, as half floats with alpha, for a renderer
    /// drawing in extended linear sRGB.
    screen: rgb_space.Space = .srgb,

    pub fn eql(self: Key, other: Key) bool {
        const proofs_equal = if (self.proof) |*a| (if (other.proof) |*b| a.eql(b) else false) else other.proof == null;
        return self.crop.eql(other.crop) and std.meta.eql(self.render_options, other.render_options) and proofs_equal and self.screen == other.screen;
    }
};

/// The part of the strip preview round a frame, copied for the worker,
/// with the frame's rectangle in its coordinates.
pub const CropSource = struct {
    pixels: []u16,
    width: usize,
    height: usize,
    rect: processing_export.FrameRect,

    /// Copies the neighbourhood of `rect` (preview pixels) out of `raw`.
    pub fn copy(allocator: std.mem.Allocator, raw: []const u16, width: usize, height: usize, rect: processing_export.FrameRect) !CropSource {
        const reach = @sqrt(rect.w * rect.w + rect.h * rect.h) / 2.0 + 4.0;
        const x0: usize = @intFromFloat(std.math.clamp(@floor(rect.cx - reach), 0.0, @as(f64, @floatFromInt(width))));
        const y0: usize = @intFromFloat(std.math.clamp(@floor(rect.cy - reach), 0.0, @as(f64, @floatFromInt(height))));
        const x1: usize = @intFromFloat(std.math.clamp(@ceil(rect.cx + reach), 0.0, @as(f64, @floatFromInt(width))));
        const y1: usize = @intFromFloat(std.math.clamp(@ceil(rect.cy + reach), 0.0, @as(f64, @floatFromInt(height))));
        if (x1 <= x0 or y1 <= y0) return error.FrameOutsidePreview;
        const pixels = try allocator.alloc(u16, (x1 - x0) * (y1 - y0) * 3);
        for (y0..y1) |y| {
            @memcpy(pixels[(y - y0) * (x1 - x0) * 3 ..][0 .. (x1 - x0) * 3], raw[(y * width + x0) * 3 ..][0 .. (x1 - x0) * 3]);
        }
        var local = rect;
        local.cx -= @floatFromInt(x0);
        local.cy -= @floatFromInt(y0);
        return .{ .pixels = pixels, .width = x1 - x0, .height = y1 - y0, .rect = local };
    }

    pub fn deinit(self: CropSource, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const Result = struct {
    key: Key,
    /// 8-bit RGB, or with a wide screen RGBA half floats (`key.screen`).
    pixels: []u8,
    width: usize,
    height: usize,
    /// Dmin was not set, so the frame's own was used.
    estimated_dmin: bool,
};

const Job = struct {
    key: Key,
    source: ?CropSource,
};

/// The cut frame (before its output rotation) and its scene-linear light.
const Cache = struct {
    key: ?CropKey = null,
    width: usize = 0,
    height: usize = 0,
    scene: []f64 = &.{},

    fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        allocator.free(self.scene);
        self.* = .{};
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    job: ?Job = null,
    cache: Cache = .{},
    /// The last soft proof's transform, kept while the proof stays.
    proof_transform: ?icc.Transform = null,
    proof_for: ?Proof = null,
    proof_space: rgb_space.Space = .srgb,
    proof_screen: rgb_space.Space = .srgb,
    result: ?Result = null,
    error_name: []const u8 = "",
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator) Worker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Worker) void {
        self.join();
        self.dropJob();
        if (self.result) |result| self.allocator.free(result.pixels);
        self.result = null;
        self.cache.deinit(self.allocator);
        if (self.proof_transform) |transform| transform.deinit();
        self.proof_transform = null;
    }

    pub fn isRunning(self: *const Worker) bool {
        return self.thread != null and !self.done.load(.acquire);
    }

    /// Whether the worker already holds the frame cut for `crop`, so a job
    /// needs no new source.
    pub fn hasCrop(self: *const Worker, crop: CropKey) bool {
        return if (self.cache.key) |held| held.eql(crop) else false;
    }

    /// Starts rendering `key`; `source` is required unless `hasCrop`. Takes
    /// ownership of `source`. False when a job is still running.
    pub fn start(self: *Worker, key: Key, source: ?CropSource) !bool {
        if (self.isRunning()) {
            if (source) |owned| owned.deinit(self.allocator);
            return false;
        }
        self.join();
        self.dropJob();
        self.job = .{ .key = key, .source = source };
        self.done.store(false, .release);
        self.failed.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return true;
    }

    /// The finished render, if one finished since the last call; the caller
    /// owns its pixels. Failures come back as an error.
    pub fn take(self: *Worker) !?Result {
        if (self.thread == null or !self.done.load(.acquire)) return null;
        self.join();
        self.dropJob();
        if (self.failed.load(.acquire)) {
            self.cache.deinit(self.allocator);
            return error.FramePreviewFailed;
        }
        const result = self.result;
        self.result = null;
        return result;
    }

    fn join(self: *Worker) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn dropJob(self: *Worker) void {
        if (self.job) |job| {
            if (job.source) |source| source.deinit(self.allocator);
        }
        self.job = null;
    }

    /// The soft proof from the render's primaries to the screen: 8-bit
    /// sRGB, or linear light in a wider screen's gamut.
    fn proofTransform(self: *Worker, proof: *const Proof, space: rgb_space.Space, screen: rgb_space.Space) !icc.Transform {
        if (self.proof_transform) |transform| {
            if (self.proof_space == space and self.proof_screen == screen and self.proof_for.?.eql(proof)) return transform;
            transform.deinit();
            self.proof_transform = null;
        }
        const source = try icc.spaceProfile(space, .linear);
        defer source.deinit();
        const display = try icc.spaceProfile(screen, if (screen == .srgb) .srgb_curve else .linear);
        defer display.deinit();
        const printer = try icc.Profile.openFile(proof.slice());
        defer printer.deinit();
        const transform = try icc.Transform.initProof(source, .rgb_f32, display, if (screen == .srgb) .rgb_u8 else .rgb_f32, printer, proof.options, proof.paper_white);
        self.proof_transform = transform;
        self.proof_for = proof.*;
        self.proof_space = space;
        self.proof_screen = screen;
        return transform;
    }

    fn threadMain(self: *Worker) void {
        self.run() catch |err| {
            self.error_name = @errorName(err);
            self.failed.store(true, .release);
        };
        self.done.store(true, .release);
    }

    fn run(self: *Worker) !void {
        const allocator = self.allocator;
        const job = self.job.?;
        var estimated_dmin = job.key.crop.dmin == null;
        if (!self.hasCrop(job.key.crop)) {
            const source = job.source orelse return error.FramePreviewSourceMissing;
            self.cache.deinit(allocator);
            const values = try allocator.alloc(f64, source.pixels.len);
            defer allocator.free(values);
            for (source.pixels, values) |sample, *value| value.* = @floatFromInt(sample);
            const crop = try processing_export.cropFrame(allocator, values, source.width, source.height, 3, source.rect);
            defer crop.deinit(allocator);
            const scene = try allocator.alloc(f64, crop.pixels.len);
            errdefer allocator.free(scene);
            _ = try inversion.invertNegative(allocator, crop.pixels, scene, .{
                .dmin = job.key.crop.dmin,
                .coeffs = job.key.crop.coeffs,
            });
            self.cache = .{ .key = job.key.crop, .width = crop.width, .height = crop.height, .scene = scene };
        } else {
            estimated_dmin = self.cache.key.?.dmin == null;
        }

        const width = self.cache.width;
        const height = self.cache.height;
        const screen = job.key.screen;
        const bytes_per_pixel: usize = if (screen == .srgb) 3 else 8;
        const rendered = try allocator.alloc(u8, width * height * bytes_per_pixel);
        defer allocator.free(rendered);
        var options = job.key.render_options;
        options.frame_width = width;
        if (screen == .srgb) {
            if (job.key.proof) |*proof| {
                options.output = null;
                const linear = try allocator.alloc(f32, self.cache.scene.len);
                defer allocator.free(linear);
                try processing_render.renderToLinear(allocator, self.cache.scene, linear, options);
                const transform = try self.proofTransform(proof, options.primaries, screen);
                transform.apply(linear, rendered, width * height);
            } else {
                options.output = .srgb;
                try processing_render.renderToDisplayU8(allocator, self.cache.scene, rendered, options);
            }
        } else {
            // Linear light in the screen's gamut, then in sRGB's primaries
            // (extended past 0 and 1) for the renderer.
            const linear = try allocator.alloc(f32, self.cache.scene.len);
            defer allocator.free(linear);
            if (job.key.proof) |*proof| {
                options.output = null;
                const working = try allocator.alloc(f32, self.cache.scene.len);
                defer allocator.free(working);
                try processing_render.renderToLinear(allocator, self.cache.scene, working, options);
                const transform = try self.proofTransform(proof, options.primaries, screen);
                transform.apply(working, linear, width * height);
            } else {
                options.output = screen;
                try processing_render.renderToLinear(allocator, self.cache.scene, linear, options);
            }
            writeExtendedHalf(screen, linear, std.mem.bytesAsSlice([4]f16, @as([]align(1) u8, rendered)));
        }

        const rotation = job.key.crop.rect.rotation;
        const turned = rotation == 90 or rotation == 270;
        const out_width = if (turned) height else width;
        const out_height = if (turned) width else height;
        const out = try allocator.alloc(u8, rendered.len);
        errdefer allocator.free(out);
        for (0..out_height) |y| {
            for (0..out_width) |x| {
                // As export.applyRotation turns frames.
                const src_x, const src_y = switch (rotation) {
                    90 => .{ y, height - 1 - x },
                    180 => .{ width - 1 - x, height - 1 - y },
                    270 => .{ width - 1 - y, x },
                    else => .{ x, y },
                };
                @memcpy(out[(y * out_width + x) * bytes_per_pixel ..][0..bytes_per_pixel], rendered[(src_y * width + src_x) * bytes_per_pixel ..][0..bytes_per_pixel]);
            }
        }
        self.result = .{ .key = job.key, .pixels = out, .width = out_width, .height = out_height, .estimated_dmin = estimated_dmin };
    }
};

/// Linear light in `screen`'s primaries as RGBA half floats in sRGB's
/// primaries: colours outside sRGB go below 0 or above 1, as an extended
/// linear sRGB renderer takes them.
pub fn writeExtendedHalf(screen: rgb_space.Space, linear: []const f32, out: []align(1) [4]f16) void {
    const m = rgb_space.conversion(screen, .srgb);
    for (out, 0..) |*pixel, i| {
        const rgb = rgb_space.multiplyVector(m, .{ linear[i * 3], linear[i * 3 + 1], linear[i * 3 + 2] });
        pixel.* = .{ @floatCast(rgb[0]), @floatCast(rgb[1]), @floatCast(rgb[2]), 1.0 };
    }
}

test "a frame renders cut out, inverted, and turned like its export" {
    const allocator = std.testing.allocator;
    // A 40 x 30 negative with a brighter (thinner) left half.
    const width = 40;
    const height = 30;
    var raw: [width * height * 3]u16 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            for (0..3) |c| raw[(y * width + x) * 3 + c] = if (x < 20) 50000 else 20000 + @as(u16, @intCast(c)) * 1000;
        }
    }
    const rect = processing_export.FrameRect{ .cx = 20, .cy = 15, .w = 24, .h = 16, .angle = 0, .rotation = 90 };
    const key = Key{
        .crop = .{ .generation = 1, .raw_ptr = 1, .rect = rect, .coeffs = film_stocks.kodak_gold_coeffs, .dmin = .{ 0.1, 0.1, 0.1 } },
        .render_options = .{},
    };
    var worker = Worker.init(allocator);
    defer worker.deinit();
    try std.testing.expect(try worker.start(key, try CropSource.copy(allocator, &raw, width, height, rect)));
    while (worker.isRunning()) std.Thread.yield() catch {};
    const result = (try worker.take()).?;
    defer allocator.free(result.pixels);
    try std.testing.expectEqual(@as(usize, 16), result.width);
    try std.testing.expectEqual(@as(usize, 24), result.height);
    try std.testing.expect(!result.estimated_dmin);
    try std.testing.expect(worker.hasCrop(key.crop));

    // A settings change renders again from the cached frame.
    var brighter = key;
    brighter.render_options.exposure_compensation = 1.0;
    try std.testing.expect(try worker.start(brighter, null));
    while (worker.isRunning()) std.Thread.yield() catch {};
    const again = (try worker.take()).?;
    defer allocator.free(again.pixels);
    var sum_before: u64 = 0;
    var sum_after: u64 = 0;
    for (result.pixels, again.pixels) |a, b| {
        sum_before += a;
        sum_after += b;
    }
    try std.testing.expect(sum_after > sum_before);
}

test "on a wide screen a frame renders as extended linear sRGB half floats" {
    const allocator = std.testing.allocator;
    // A saturated negative: little red density, much blue.
    const width = 8;
    const height = 8;
    var raw: [width * height * 3]u16 = undefined;
    for (0..width * height) |pixel| raw[pixel * 3 ..][0..3].* = if (pixel % 2 == 0) .{ 60000, 20000, 9000 } else .{ 30000, 30000, 30000 };
    const rect = processing_export.FrameRect{ .cx = 4, .cy = 4, .w = 8, .h = 8, .angle = 0, .rotation = 0 };
    const key = Key{
        .crop = .{ .generation = 1, .raw_ptr = 1, .rect = rect, .coeffs = film_stocks.kodak_gold_coeffs, .dmin = .{ 0.1, 0.1, 0.1 } },
        .render_options = .{ .primaries = .rec2020, .auto_white_balance = 0.0 },
        .screen = .display_p3,
    };
    var worker = Worker.init(allocator);
    defer worker.deinit();
    try std.testing.expect(try worker.start(key, try CropSource.copy(allocator, &raw, width, height, rect)));
    while (worker.isRunning()) std.Thread.yield() catch {};
    const result = (try worker.take()).?;
    defer allocator.free(result.pixels);
    try std.testing.expectEqual(result.width * result.height * 8, result.pixels.len);
    const half = std.mem.bytesAsSlice([4]f16, @as([]align(1) u8, result.pixels));
    var beyond = false;
    for (half) |pixel| {
        try std.testing.expectEqual(@as(f16, 1.0), pixel[3]);
        for (pixel[0..3]) |v| {
            try std.testing.expect(v > -0.6 and v < 1.6);
            if (v < -0.002 or v > 1.002) beyond = true;
        }
    }
    // The saturated colour reaches past sRGB, as P3 allows.
    try std.testing.expect(beyond);
}
