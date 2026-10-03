const std = @import("std");

const processing_render = @import("../processing/render.zig");
const processing_webgpu = @import("../processing/webgpu.zig");
const processing_workflow = @import("../processing/workflow.zig");

pub const ExecuteFn = *const fn (*Context) anyerror!void;

pub const Key = struct {
    generation: usize,
    source_raw_ptr: usize,
    width: usize,
    height: usize,
    stock: ?[]u8 = null,
    dmin: ?[3]f64 = null,
    render_options: processing_render.RenderToDisplayOptions = .{},
    invert_request: processing_webgpu.Request = .{},

    pub fn empty() Key {
        return .{
            .generation = 0,
            .source_raw_ptr = 0,
            .width = 0,
            .height = 0,
        };
    }

    pub fn initCopy(
        allocator: std.mem.Allocator,
        preview: processing_workflow.QuickPreview,
        generation: usize,
        options: processing_workflow.InvertedPreviewOptions,
    ) !Key {
        const stock = if (options.stock) |value| try allocator.dupe(u8, value) else null;
        errdefer if (stock) |owned| allocator.free(owned);
        return .{
            .generation = generation,
            .source_raw_ptr = @intFromPtr(preview.preview_raw.ptr),
            .width = preview.preview_width,
            .height = preview.preview_height,
            .stock = stock,
            .dmin = options.dmin,
            .render_options = options.render_options,
            .invert_request = options.invert_request,
        };
    }

    pub fn deinit(self: *Key, allocator: std.mem.Allocator) void {
        if (self.stock) |stock| {
            allocator.free(stock);
            self.stock = null;
        }
    }

    pub fn matches(
        self: Key,
        preview: processing_workflow.QuickPreview,
        generation: usize,
        options: processing_workflow.InvertedPreviewOptions,
    ) bool {
        return self.generation == generation and
            self.source_raw_ptr == @intFromPtr(preview.preview_raw.ptr) and
            self.width == preview.preview_width and
            self.height == preview.preview_height and
            stockEqual(self.stock, options.stock) and
            dminEqual(self.dmin, options.dmin) and
            renderOptionsEqual(self.render_options, options.render_options) and
            webgpuRequestEqual(self.invert_request, options.invert_request);
    }
};

pub const Result = struct {
    key: Key,
    rgb8: ?[]u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.key.deinit(allocator);
        if (self.rgb8) |rgb| {
            allocator.free(rgb);
            self.rgb8 = null;
        }
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    key: Key,
    preview: processing_workflow.QuickPreview,
    rgb8: ?[]u8 = null,
    error_detail: []const u8 = "",
    done: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    execute: ExecuteFn,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    execute: ExecuteFn = runInvertedPreviewRender,
    thread: ?std.Thread = null,
    context: ?*Context = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator) Worker {
        return .{ .allocator = allocator };
    }

    pub fn initWithExecutor(allocator: std.mem.Allocator, execute: ExecuteFn) Worker {
        var worker = init(allocator);
        worker.execute = execute;
        return worker;
    }

    pub fn deinit(self: *Worker) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.cleanupContext();
    }

    pub fn isRunning(self: Worker) bool {
        return self.context != null and !self.done.load(.acquire);
    }

    pub fn start(
        self: *Worker,
        preview: processing_workflow.QuickPreview,
        generation: usize,
        options: processing_workflow.InvertedPreviewOptions,
    ) !bool {
        if (self.context != null) return false;
        if (options.stock == null or preview.info.is_grayscale) return false;

        var preview_copy: ?processing_workflow.QuickPreview = try copyPreviewForRender(self.allocator, preview);
        errdefer if (preview_copy) |copy| copy.deinit(self.allocator);
        var key = try Key.initCopy(self.allocator, preview, generation, options);
        errdefer key.deinit(self.allocator);

        const context = try self.allocator.create(Context);
        // Until the context owns the key and preview copy, free only the
        // struct; afterwards destroyContext frees everything.
        var context_initialized = false;
        errdefer if (!context_initialized) self.allocator.destroy(context);
        context.* = .{
            .allocator = self.allocator,
            .key = key,
            .preview = preview_copy.?,
            .done = &self.done,
            .failed = &self.failed,
            .execute = self.execute,
        };
        key = Key.empty();
        preview_copy = null;
        context_initialized = true;
        errdefer self.destroyContext(context);

        self.done.store(false, .release);
        self.failed.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{context});
        self.context = context;
        return true;
    }

    pub fn poll(self: *Worker) ?Result {
        const context = self.context orelse return null;
        if (!context.done.load(.acquire)) return null;

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        var result: ?Result = null;
        if (!context.failed.load(.acquire)) {
            if (context.rgb8) |rgb| {
                result = .{
                    .key = context.key,
                    .rgb8 = rgb,
                };
                context.key = Key.empty();
                context.rgb8 = null;
            }
        }
        self.cleanupContext();
        return result;
    }

    fn cleanupContext(self: *Worker) void {
        if (self.context) |context| {
            self.destroyContext(context);
            self.context = null;
        }
        self.done.store(false, .release);
        self.failed.store(false, .release);
    }

    fn destroyContext(self: *Worker, context: *Context) void {
        context.key.deinit(self.allocator);
        context.preview.deinit(self.allocator);
        if (context.rgb8) |rgb| self.allocator.free(rgb);
        self.allocator.destroy(context);
    }
};

fn threadMain(context: *Context) void {
    context.execute(context) catch |err| {
        context.error_detail = @errorName(err);
        context.failed.store(true, .release);
    };
    context.done.store(true, .release);
}

fn runInvertedPreviewRender(context: *Context) !void {
    var cache = processing_workflow.InvertedPreviewCache{};
    defer cache.deinit(context.allocator);
    context.rgb8 = (try processing_workflow.renderInvertedPreviewRgb8(
        context.allocator,
        context.preview,
        &cache,
        .{
            .stock = context.key.stock,
            .dmin = context.key.dmin,
            .render_options = context.key.render_options,
            .invert_request = context.key.invert_request,
        },
    )) orelse return error.InvertedPreviewUnavailable;
}

fn copyPreviewForRender(
    allocator: std.mem.Allocator,
    preview: processing_workflow.QuickPreview,
) !processing_workflow.QuickPreview {
    const raw = try allocator.dupe(u16, preview.preview_raw);
    errdefer allocator.free(raw);
    const rgb8 = try allocator.alloc(u8, 0);
    errdefer allocator.free(rgb8);
    const jpeg = try allocator.alloc(u8, 0);
    return .{
        .info = preview.info,
        .preview_width = preview.preview_width,
        .preview_height = preview.preview_height,
        .preview_raw = raw,
        .preview_rgb8 = rgb8,
        .jpeg = jpeg,
    };
}

pub fn renderOptionsEqual(
    a: processing_render.RenderToDisplayOptions,
    b: processing_render.RenderToDisplayOptions,
) bool {
    return a.contrast == b.contrast and
        a.percentile_lo == b.percentile_lo and
        a.percentile_hi == b.percentile_hi and
        a.exposure_compensation == b.exposure_compensation and
        a.color_temp == b.color_temp and
        a.color_tint == b.color_tint and
        a.auto_white_balance == b.auto_white_balance and
        a.film_gamma == b.film_gamma and
        a.film_toe == b.film_toe and
        a.dye_crosstalk == b.dye_crosstalk and
        a.percentile_sample_limit == b.percentile_sample_limit;
}

pub fn stockEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn dminEqual(a: ?[3]f64, b: ?[3]f64) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?[0] == b.?[0] and a.?[1] == b.?[1] and a.?[2] == b.?[2];
}

pub fn webgpuRequestEqual(a: processing_webgpu.Request, b: processing_webgpu.Request) bool {
    return a.backend == b.backend and a.fallback == b.fallback;
}

fn waitForPoll(worker: *Worker) !Result {
    for (0..100_000) |_| {
        if (worker.poll()) |result| return result;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    return error.InvertedPreviewWorkerDidNotFinish;
}

fn fakeRenderSuccess(context: *Context) !void {
    const len = try std.math.mul(usize, try std.math.mul(usize, context.preview.preview_width, context.preview.preview_height), 3);
    const rgb = try context.allocator.alloc(u8, len);
    errdefer context.allocator.free(rgb);
    for (rgb, 0..) |*sample, index| {
        sample.* = @intCast((context.preview.preview_raw[index] >> 8) & 0xff);
    }
    context.rgb8 = rgb;
}

fn fakeRenderDelayedSuccess(context: *Context) !void {
    for (0..1_000) |_| std.Thread.yield() catch {};
    try fakeRenderSuccess(context);
}

fn fakePreview(allocator: std.mem.Allocator, width: usize, height: usize) !processing_workflow.QuickPreview {
    const raw = try allocator.alloc(u16, width * height * 3);
    errdefer allocator.free(raw);
    for (raw, 0..) |*sample, index| sample.* = @intCast(index * 257);
    const rgb8 = try allocator.alloc(u8, width * height * 3);
    errdefer allocator.free(rgb8);
    for (rgb8, 0..) |*sample, index| sample.* = @intCast(index & 0xff);
    const jpeg = try allocator.alloc(u8, 0);
    return .{
        .info = .{
            .width = width,
            .height = height,
            .has_ir = false,
            .is_grayscale = false,
            .dpi = 800,
            .preview_scale = 1.0,
            .rgb_samples_per_pixel = 3,
            .rgb_bits_per_sample = 16,
        },
        .preview_width = width,
        .preview_height = height,
        .preview_raw = raw,
        .preview_rgb8 = rgb8,
        .jpeg = jpeg,
    };
}

test "inverted preview worker returns copied RGB result without touching UI state" {
    var preview = try fakePreview(std.testing.allocator, 3, 2);
    defer preview.deinit(std.testing.allocator);

    var worker = Worker.initWithExecutor(std.testing.allocator, fakeRenderSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.start(preview, 7, .{ .stock = "kodak_gold" }));
    preview.preview_raw[0] = 65535;

    var result = try waitForPoll(&worker);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 7), result.key.generation);
    try std.testing.expectEqual(@as(usize, @intFromPtr(preview.preview_raw.ptr)), result.key.source_raw_ptr);
    try std.testing.expectEqualStrings("kodak_gold", result.key.stock.?);
    try std.testing.expectEqual(@as(u8, 0), result.rgb8.?[0]);
}

test "inverted preview worker rejects duplicate render starts while running" {
    var preview = try fakePreview(std.testing.allocator, 3, 2);
    defer preview.deinit(std.testing.allocator);

    var worker = Worker.initWithExecutor(std.testing.allocator, fakeRenderDelayedSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.start(preview, 1, .{ .stock = "kodak_gold" }));
    try std.testing.expect(!(try worker.start(preview, 1, .{ .stock = "kodak_gold" })));
    var result = try waitForPoll(&worker);
    defer result.deinit(std.testing.allocator);
}

test "inverted preview worker does not start without renderable inverted inputs" {
    var preview = try fakePreview(std.testing.allocator, 3, 2);
    defer preview.deinit(std.testing.allocator);

    var worker = Worker.initWithExecutor(std.testing.allocator, fakeRenderSuccess);
    defer worker.deinit();
    try std.testing.expect(!(try worker.start(preview, 1, .{})));
    preview.info.is_grayscale = true;
    try std.testing.expect(!(try worker.start(preview, 1, .{ .stock = "kodak_gold" })));
}

test "inverted preview key includes inversion backend request" {
    var preview = try fakePreview(std.testing.allocator, 3, 2);
    defer preview.deinit(std.testing.allocator);

    var key = try Key.initCopy(std.testing.allocator, preview, 1, .{ .stock = "kodak_gold" });
    defer key.deinit(std.testing.allocator);
    try std.testing.expect(key.matches(preview, 1, .{ .stock = "kodak_gold" }));
    try std.testing.expect(!key.matches(preview, 1, .{
        .stock = "kodak_gold",
        .invert_request = .{ .backend = .webgpu },
    }));
}
