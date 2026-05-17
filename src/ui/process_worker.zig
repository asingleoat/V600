const std = @import("std");
const builtin = @import("builtin");

const app_state = @import("../app_state.zig");
const processing_config = @import("../processing/config.zig");
const processing_frames = @import("../processing/frames.zig");
const processing_workflow = @import("../processing/workflow.zig");
const ui_state = @import("state.zig");

pub const Operation = enum {
    load_image,
    auto_detect,
    rebate,

    fn label(self: Operation) []const u8 {
        return switch (self) {
            .load_image => "load",
            .auto_detect => "auto-detect",
            .rebate => "rebate",
        };
    }
};

pub const ExecuteFn = *const fn (*Context) anyerror!void;

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    operation: Operation,
    path: []u8,
    config_path: []u8,
    index: usize,
    generation: usize,
    preview_size: i64,
    preview: ?processing_workflow.QuickPreview = null,
    options: processing_workflow.AutoDetectOptions = .{},
    scale_percent: f64 = 0.0,
    rotation: i32 = ui_state.default_process_output_rotation,
    auto_result: ?processing_workflow.AutoDetectResult = null,
    full_rebate: ?app_state.RebateRect = null,
    dmin: ?[3]f64 = null,
    error_detail: []const u8 = "",
    started_ms: i64 = 0,
    finished_ms: i64 = 0,
    done: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    execute: ExecuteFn,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    execute: ExecuteFn = runProcessOperation,
    thread: ?std.Thread = null,
    context: ?*Context = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_auto_aspect_buffer: [32]u8 = undefined,
    last_auto_aspect_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Worker {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn initWithExecutor(
        allocator: std.mem.Allocator,
        io: std.Io,
        execute: ExecuteFn,
    ) Worker {
        var worker = init(allocator, io);
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

    pub fn takeLastAutoAspect(self: *Worker) ?[]const u8 {
        if (self.last_auto_aspect_len == 0) return null;
        const aspect = self.last_auto_aspect_buffer[0..self.last_auto_aspect_len];
        self.last_auto_aspect_len = 0;
        return aspect;
    }

    pub fn activeStatus(self: *const Worker, buffer: []u8) []const u8 {
        const context = self.context orelse return "Process worker idle";
        var elapsed_buffer: [32]u8 = undefined;
        const elapsed = formatElapsed(&elapsed_buffer, elapsedMsSince(context.started_ms));
        const name = std.fs.path.basename(context.path);
        return switch (context.operation) {
            .load_image => std.fmt.bufPrint(
                buffer,
                "Process worker: loading {s}, elapsed {s}",
                .{ name, elapsed },
            ) catch "Process worker active",
            .auto_detect => blk: {
                var frames_buffer: [32]u8 = undefined;
                const frames = if (context.options.n_frames) |n|
                    std.fmt.bufPrint(&frames_buffer, "{d}", .{n}) catch "set"
                else
                    "auto";
                break :blk std.fmt.bufPrint(
                    buffer,
                    "Process worker: auto-detect {s}, {d}x{d}, format={s}, frames={s}, elapsed {s}",
                    .{
                        name,
                        if (context.preview) |preview| preview.preview_width else 0,
                        if (context.preview) |preview| preview.preview_height else 0,
                        context.options.format orelse "auto",
                        frames,
                        elapsed,
                    },
                ) catch "Process worker active";
            },
            .rebate => std.fmt.bufPrint(
                buffer,
                "Process worker: computing Dmin for {s}, elapsed {s}",
                .{ name, elapsed },
            ) catch "Process worker active",
        };
    }

    pub fn startLoadIndex(
        self: *Worker,
        model: *ui_state.State,
        index: usize,
        preview_size: i64,
    ) !bool {
        if (self.context != null) return rejectBusy(model);
        if (index >= model.processing_images.paths.len) {
            model.setStatus("Invalid index");
            return error.InvalidProcessImageIndex;
        }
        const path = model.processing_images.paths[index];
        const generation = model.beginProcessingImageLoadRequest(path, index);
        const context = try self.createContext(.{
            .operation = .load_image,
            .path = path,
            .index = index,
            .generation = generation,
            .preview_size = preview_size,
        });
        errdefer self.destroyContext(context);
        try self.spawn(context);
        return true;
    }

    pub fn startAutoDetectFromState(
        self: *Worker,
        model: *ui_state.State,
        config_path: []const u8,
        options: processing_workflow.AutoDetectOptions,
        scale_percent: f64,
        rotation: i32,
    ) !bool {
        if (self.context != null) return rejectBusy(model);
        const path = model.currentProcessingImagePathForWorker() orelse {
            model.setProcessingProgress("No image loaded");
            return error.NoProcessImageLoaded;
        };
        const preview = model.processing_preview orelse {
            model.setProcessingProgress("No image loaded");
            return error.NoProcessImageLoaded;
        };
        var preview_copy: ?processing_workflow.QuickPreview = try copyPreviewForDetect(self.allocator, preview);
        errdefer if (preview_copy) |copy| copy.deinit(self.allocator);
        const context = try self.createContext(.{
            .operation = .auto_detect,
            .path = path,
            .config_path = config_path,
            .generation = model.processingGeneration(),
            .preview = preview_copy.?,
            .options = options,
            .scale_percent = scale_percent,
            .rotation = rotation,
        });
        preview_copy = null;
        errdefer self.destroyContext(context);
        model.setProcessingProgress("Detecting frames...");
        try self.spawn(context);
        return true;
    }

    pub fn startRebateFromState(
        self: *Worker,
        model: *ui_state.State,
        config_path: []const u8,
    ) !bool {
        if (self.context != null) return rejectBusy(model);
        const path = model.currentProcessingImagePathForWorker() orelse {
            model.setProcessingProgress("No image loaded");
            return error.NoProcessImageLoaded;
        };
        const rect = (try model.processRebateRequest()) orelse {
            model.setStatus("No rebate selection");
            return false;
        };
        const context = try self.createContext(.{
            .operation = .rebate,
            .path = path,
            .config_path = config_path,
            .generation = model.processingGeneration(),
            .full_rebate = rect,
        });
        errdefer self.destroyContext(context);
        model.setProcessingProgress("Computing Dmin...");
        try self.spawn(context);
        return true;
    }

    pub fn poll(self: *Worker, model: *ui_state.State) bool {
        const context = self.context orelse return false;
        if (!context.done.load(.acquire)) return false;

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        if (context.failed.load(.acquire)) {
            model.applyProcessingBackendEvent(.{ .processing_error = .{
                .operation = context.operation.label(),
                .detail = if (context.error_detail.len == 0) "worker failed" else context.error_detail,
            } });
            logWorkerFailed(context);
        } else {
            const applied = self.applyResult(model, context) catch |err| {
                model.applyProcessingBackendEvent(.{ .processing_error = .{
                    .operation = context.operation.label(),
                    .detail = @errorName(err),
                } });
                logWorkerApplyFailed(context, err);
                self.cleanupContext();
                return true;
            };
            logWorkerFinished(context, applied);
        }

        self.cleanupContext();
        return true;
    }

    fn applyResult(self: *Worker, model: *ui_state.State, context: *Context) !bool {
        switch (context.operation) {
            .load_image => {
                return model.finishProcessingImageLoadResult(
                    self.allocator,
                    context.generation,
                    context.index,
                    context.path,
                    &context.preview,
                );
            },
            .auto_detect => {
                const result = if (context.auto_result) |*auto_result| auto_result else return error.MissingAutoDetectResult;
                const applied = try model.applyProcessAutoDetectWorkerResult(
                    self.allocator,
                    context.generation,
                    context.path,
                    result,
                    context.scale_percent,
                    context.rotation,
                    context.full_rebate,
                    context.dmin,
                );
                if (applied) self.rememberAutoAspect(result.aspect);
                return applied;
            },
            .rebate => {
                return try model.applyProcessRebateWorkerResult(
                    self.allocator,
                    context.generation,
                    context.path,
                    context.full_rebate orelse return error.MissingRebateResult,
                    context.dmin orelse return error.MissingRebateResult,
                );
            },
        }
    }

    fn spawn(self: *Worker, context: *Context) !void {
        self.done.store(false, .release);
        self.failed.store(false, .release);
        context.started_ms = nowMilliseconds();
        logWorkerStarted(context);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{context});
        self.context = context;
    }

    fn createContext(self: *Worker, request: StartRequest) !*Context {
        const context = try self.allocator.create(Context);
        errdefer self.allocator.destroy(context);
        const owned_path = try self.allocator.dupe(u8, request.path);
        errdefer self.allocator.free(owned_path);
        const owned_config_path = try self.allocator.dupe(u8, request.config_path);
        errdefer self.allocator.free(owned_config_path);
        context.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .operation = request.operation,
            .path = owned_path,
            .config_path = owned_config_path,
            .index = request.index,
            .generation = request.generation,
            .preview_size = request.preview_size,
            .preview = request.preview,
            .options = request.options,
            .scale_percent = request.scale_percent,
            .rotation = request.rotation,
            .full_rebate = request.full_rebate,
            .done = &self.done,
            .failed = &self.failed,
            .execute = self.execute,
        };
        return context;
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
        self.allocator.free(context.path);
        self.allocator.free(context.config_path);
        if (context.preview) |preview| preview.deinit(self.allocator);
        if (context.auto_result) |*result| result.deinit(self.allocator);
        self.allocator.destroy(context);
    }

    fn rememberAutoAspect(self: *Worker, aspect: []const u8) void {
        self.last_auto_aspect_len = @min(aspect.len, self.last_auto_aspect_buffer.len);
        @memcpy(self.last_auto_aspect_buffer[0..self.last_auto_aspect_len], aspect[0..self.last_auto_aspect_len]);
    }
};

const StartRequest = struct {
    operation: Operation,
    path: []const u8,
    config_path: []const u8 = "",
    index: usize = 0,
    generation: usize,
    preview_size: i64 = 0,
    preview: ?processing_workflow.QuickPreview = null,
    options: processing_workflow.AutoDetectOptions = .{},
    scale_percent: f64 = 0.0,
    rotation: i32 = ui_state.default_process_output_rotation,
    full_rebate: ?app_state.RebateRect = null,
};

fn rejectBusy(model: *ui_state.State) bool {
    model.setProcessingProgress("Processing busy, please wait...");
    return false;
}

fn threadMain(context: *Context) void {
    context.execute(context) catch |err| {
        context.error_detail = @errorName(err);
        context.failed.store(true, .release);
    };
    context.finished_ms = nowMilliseconds();
    context.done.store(true, .release);
}

fn runProcessOperation(context: *Context) !void {
    switch (context.operation) {
        .load_image => {
            context.preview = try processing_workflow.loadQuickPreview(
                context.allocator,
                context.path,
                context.preview_size,
            );
        },
        .auto_detect => {
            const preview = context.preview orelse return error.NoProcessImageLoaded;
            const detector_start_ms = nowMilliseconds();
            var result = try processing_workflow.autoDetectPreview(context.allocator, preview, context.options);
            errdefer result.deinit(context.allocator);
            logAutoDetectComplete(context, result, elapsedMsSince(detector_start_ms));
            if (result.rebate) |rebate| {
                const full = try processing_frames.previewRebateToFullResolution(.{
                    .x = rebate.cx - rebate.w / 2.0,
                    .y = rebate.cy - rebate.h / 2.0,
                    .w = rebate.w,
                    .h = rebate.h,
                    .angle = rebate.angle,
                }, preview.info.preview_scale);
                context.full_rebate = .{
                    .x = full.x,
                    .y = full.y,
                    .w = full.w,
                    .h = full.h,
                    .angle = full.angle,
                };
                logAutoDetectRebateStart(context);
                const rebate_result = try processing_workflow.processRebateFromTiff(
                    context.allocator,
                    context.io,
                    context.path,
                    context.config_path,
                    full,
                    true,
                );
                context.dmin = rebate_result.dmin;
            }
            context.auto_result = result;
        },
        .rebate => {
            const rect = context.full_rebate orelse return error.NoRebateSelection;
            const result = try processing_workflow.processRebateFromTiff(
                context.allocator,
                context.io,
                context.path,
                context.config_path,
                .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .angle = rect.angle },
                true,
            );
            context.dmin = result.dmin;
        },
    }
}

fn elapsedMsSince(started_ms: i64) u64 {
    if (started_ms <= 0) return 0;
    const now = nowMilliseconds();
    if (now <= started_ms) return 0;
    return @intCast(now - started_ms);
}

fn nowMilliseconds() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    const seconds_ms = @as(i128, @intCast(ts.sec)) * std.time.ms_per_s;
    const nanos_ms = @divTrunc(@as(i128, @intCast(ts.nsec)), std.time.ns_per_ms);
    return @intCast(seconds_ms + nanos_ms);
}

fn elapsedMsBetween(started_ms: i64, finished_ms: i64) u64 {
    if (started_ms <= 0 or finished_ms <= started_ms) return 0;
    return @intCast(finished_ms - started_ms);
}

fn formatElapsed(buffer: []u8, elapsed_ms: u64) []const u8 {
    const seconds = elapsed_ms / 1000;
    const tenths = (elapsed_ms % 1000) / 100;
    if (seconds < 60) {
        return std.fmt.bufPrint(buffer, "{d}.{d}s", .{ seconds, tenths }) catch "?s";
    }
    const minutes = seconds / 60;
    const rem = seconds % 60;
    return std.fmt.bufPrint(buffer, "{d}m{d:0>2}s", .{ minutes, rem }) catch "?s";
}

fn logWorkerStarted(context: *const Context) void {
    if (builtin.is_test) return;
    switch (context.operation) {
        .load_image => std.debug.print(
            "[v600 process] start load path={s} generation={d} preview_size={d}\n",
            .{ context.path, context.generation, context.preview_size },
        ),
        .auto_detect => {
            var frames_buffer: [32]u8 = undefined;
            const frames = if (context.options.n_frames) |n|
                std.fmt.bufPrint(&frames_buffer, "{d}", .{n}) catch "set"
            else
                "auto";
            std.debug.print(
                "[v600 process] start auto-detect path={s} generation={d} preview={d}x{d} format={s} frames={s} scale={d:.2} rotation={d}\n",
                .{
                    context.path,
                    context.generation,
                    if (context.preview) |preview| preview.preview_width else 0,
                    if (context.preview) |preview| preview.preview_height else 0,
                    context.options.format orelse "auto",
                    frames,
                    context.scale_percent,
                    context.rotation,
                },
            );
        },
        .rebate => std.debug.print(
            "[v600 process] start rebate path={s} generation={d}\n",
            .{ context.path, context.generation },
        ),
    }
}

fn logAutoDetectComplete(context: *const Context, result: processing_workflow.AutoDetectResult, elapsed_ms: u64) void {
    if (builtin.is_test) return;
    var elapsed_buffer: [32]u8 = undefined;
    const elapsed = formatElapsed(&elapsed_buffer, elapsed_ms);
    std.debug.print(
        "[v600 process] auto-detect detector complete path={s} elapsed={s} frames={d} aspect={s} rebate={s}\n",
        .{ context.path, elapsed, result.frames.len, result.aspect, if (result.rebate != null) "yes" else "no" },
    );
}

fn logAutoDetectRebateStart(context: *const Context) void {
    if (builtin.is_test) return;
    std.debug.print("[v600 process] auto-detect computing suggested-rebate Dmin path={s}\n", .{context.path});
}

fn logWorkerFailed(context: *const Context) void {
    if (builtin.is_test) return;
    var elapsed_buffer: [32]u8 = undefined;
    const elapsed = formatElapsed(&elapsed_buffer, elapsedMsBetween(context.started_ms, context.finished_ms));
    std.debug.print(
        "[v600 process] failed {s} path={s} elapsed={s} error={s}\n",
        .{ context.operation.label(), context.path, elapsed, if (context.error_detail.len == 0) "worker failed" else context.error_detail },
    );
}

fn logWorkerApplyFailed(context: *const Context, err: anyerror) void {
    if (builtin.is_test) return;
    var elapsed_buffer: [32]u8 = undefined;
    const elapsed = formatElapsed(&elapsed_buffer, elapsedMsBetween(context.started_ms, context.finished_ms));
    std.debug.print(
        "[v600 process] apply failed {s} path={s} elapsed={s} error={s}\n",
        .{ context.operation.label(), context.path, elapsed, @errorName(err) },
    );
}

fn logWorkerFinished(context: *const Context, applied: bool) void {
    if (builtin.is_test) return;
    var elapsed_buffer: [32]u8 = undefined;
    const elapsed = formatElapsed(&elapsed_buffer, elapsedMsBetween(context.started_ms, context.finished_ms));
    std.debug.print(
        "[v600 process] finish {s} path={s} elapsed={s} applied={s}\n",
        .{ context.operation.label(), context.path, elapsed, if (applied) "yes" else "stale" },
    );
}

fn copyPreviewForDetect(
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

fn waitForPoll(worker: *Worker, model: *ui_state.State) !void {
    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
}

fn fakeLoadSuccess(context: *Context) !void {
    context.preview = try fakePreview(context.allocator, 4, 3, 0.5);
}

pub fn fakeLoadDelayedSuccess(context: *Context) !void {
    for (0..200_000) |_| std.Thread.yield() catch {};
    try fakeLoadSuccess(context);
}

fn fakeAutoDetectSuccess(context: *Context) !void {
    const frames = try context.allocator.alloc(processing_frames.FrameRect, 1);
    frames[0] = .{ .cx = 8.0, .cy = 6.0, .w = 4.0, .h = 3.0, .angle = 0.0 };
    context.auto_result = .{
        .frames = frames,
        .aspect = "35mm",
        .rebate = .{ .cx = 2.0, .cy = 2.0, .w = 1.0, .h = 1.0, .angle = 0.0 },
    };
    context.full_rebate = .{ .x = 3.0, .y = 3.0, .w = 2.0, .h = 2.0, .angle = 0.0 };
    context.dmin = .{ 0.1, 0.2, 0.3 };
}

pub fn fakeRebateSuccess(context: *Context) !void {
    context.dmin = .{ 0.4, 0.5, 0.6 };
}

fn fakePreview(allocator: std.mem.Allocator, width: usize, height: usize, scale: f64) !processing_workflow.QuickPreview {
    const raw = try allocator.alloc(u16, width * height * 3);
    errdefer allocator.free(raw);
    for (raw, 0..) |*sample, index| sample.* = @intCast(index);
    const rgb8 = try allocator.alloc(u8, 0);
    errdefer allocator.free(rgb8);
    const jpeg = try allocator.alloc(u8, 0);
    return .{
        .info = .{
            .width = width * 2,
            .height = height * 2,
            .has_ir = true,
            .is_grayscale = false,
            .dpi = 800,
            .preview_scale = scale,
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

test "process worker loads image preview off the UI state path" {
    var model = ui_state.State.init("scans", "frames", 0);
    defer model.deinit(std.testing.allocator);
    model.processing_images.paths = try std.testing.allocator.alloc([]u8, 1);
    model.processing_images.paths[0] = try std.testing.allocator.dupe(u8, "scans/scan_0001.tiff");
    model.processing.image_count = 1;

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, fakeLoadSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startLoadIndex(&model, 0, 8192));
    try std.testing.expect(model.processing.loading);
    try waitForPoll(&worker, &model);
    try std.testing.expect(model.processing_preview != null);
    try std.testing.expect(!model.processing.loading);
    try std.testing.expect(model.takeProcessAutoDetectPending());
}

test "process worker rejects stale image load results" {
    var model = ui_state.State.init("scans", "frames", 0);
    defer model.deinit(std.testing.allocator);
    model.processing_images.paths = try std.testing.allocator.alloc([]u8, 2);
    model.processing_images.paths[0] = try std.testing.allocator.dupe(u8, "scans/scan_a.tiff");
    model.processing_images.paths[1] = try std.testing.allocator.dupe(u8, "scans/scan_b.tiff");
    model.processing.image_count = 2;

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, fakeLoadSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startLoadIndex(&model, 0, 8192));
    _ = model.beginProcessingImageLoadRequest(model.processing_images.paths[1], 1);
    try waitForPoll(&worker, &model);
    try std.testing.expect(model.processing_preview == null);
    try std.testing.expectEqual(@as(usize, 1), model.processing.image_idx);
    try std.testing.expectEqualStrings("scans/scan_b.tiff", model.processing.input_path);
}

test "process worker rejects duplicate incompatible starts while running" {
    var model = ui_state.State.init("scans", "frames", 0);
    defer model.deinit(std.testing.allocator);
    model.processing_images.paths = try std.testing.allocator.alloc([]u8, 1);
    model.processing_images.paths[0] = try std.testing.allocator.dupe(u8, "scans/scan_busy.tiff");
    model.processing.image_count = 1;

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, fakeLoadSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startLoadIndex(&model, 0, 8192));
    try std.testing.expect(!(try worker.startLoadIndex(&model, 0, 8192)));
    try std.testing.expect(!(try worker.startAutoDetectFromState(&model, "scratchndent_config.toml", .{}, 0.0, ui_state.default_process_output_rotation)));
    try std.testing.expectEqualStrings("Processing busy, please wait...", model.processing.progress);
    try waitForPoll(&worker, &model);
}

test "process worker exposes active operation diagnostics" {
    var model = ui_state.State.init("scans", "frames", 0);
    defer model.deinit(std.testing.allocator);
    model.processing_images.paths = try std.testing.allocator.alloc([]u8, 1);
    model.processing_images.paths[0] = try std.testing.allocator.dupe(u8, "scans/scan_diagnostics.tiff");
    model.processing.image_count = 1;
    const generation = model.beginProcessingImageLoadRequest(model.processing_images.paths[0], 0);
    var preview: ?processing_workflow.QuickPreview = try fakePreview(std.testing.allocator, 4, 3, 0.5);
    try std.testing.expect(model.finishProcessingImageLoadResult(std.testing.allocator, generation, 0, model.processing_images.paths[0], &preview));
    _ = model.takeProcessAutoDetectPending();

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, fakeAutoDetectSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startAutoDetectFromState(
        &model,
        "scratchndent_config.toml",
        .{ .format = "35mm", .n_frames = 6 },
        0.5,
        ui_state.default_process_output_rotation,
    ));
    var status_buffer: [256]u8 = undefined;
    const status = worker.activeStatus(&status_buffer);
    try std.testing.expect(std.mem.indexOf(u8, status, "auto-detect") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "scan_diagnostics.tiff") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "format=35mm") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "frames=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "elapsed") != null);
    try waitForPoll(&worker, &model);
}

test "process worker runs pending auto-detect once and applies Dmin" {
    var model = ui_state.State.init("scans", "frames", 0);
    defer model.deinit(std.testing.allocator);
    model.processing_images.paths = try std.testing.allocator.alloc([]u8, 1);
    model.processing_images.paths[0] = try std.testing.allocator.dupe(u8, "scans/scan_detect.tiff");
    model.processing.image_count = 1;
    const generation = model.beginProcessingImageLoadRequest(model.processing_images.paths[0], 0);
    var preview: ?processing_workflow.QuickPreview = try fakePreview(std.testing.allocator, 4, 3, 0.5);
    try std.testing.expect(model.finishProcessingImageLoadResult(std.testing.allocator, generation, 0, model.processing_images.paths[0], &preview));
    try std.testing.expect(model.takeProcessAutoDetectPending());
    try std.testing.expect(!model.takeProcessAutoDetectPending());

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, fakeAutoDetectSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startAutoDetectFromState(&model, "scratchndent_config.toml", .{}, 0.0, ui_state.default_process_output_rotation));
    try waitForPoll(&worker, &model);
    try std.testing.expectEqual(@as(usize, 1), model.process_selection_count);
    try std.testing.expect(model.process_rebate_rect != null);
    try std.testing.expect(model.processing.rebate_rect != null);
    try std.testing.expectApproxEqAbs(0.1, model.processing.dmin.?[0], 0.0);
}

test "process worker applies explicit rebate Dmin result to matching image" {
    var model = ui_state.State.init("scans", "frames", 0);
    defer model.deinit(std.testing.allocator);
    model.processing_images.paths = try std.testing.allocator.alloc([]u8, 1);
    model.processing_images.paths[0] = try std.testing.allocator.dupe(u8, "scans/scan_rebate.tiff");
    model.processing.image_count = 1;
    const generation = model.beginProcessingImageLoadRequest(model.processing_images.paths[0], 0);
    var preview: ?processing_workflow.QuickPreview = try fakePreview(std.testing.allocator, 4, 3, 0.5);
    try std.testing.expect(model.finishProcessingImageLoadResult(std.testing.allocator, generation, 0, model.processing_images.paths[0], &preview));
    try std.testing.expect(try model.setProcessRebatePreviewRect(.{ .x = 1.0, .y = 1.0, .w = 6.0, .h = 6.0 }));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, fakeRebateSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startRebateFromState(&model, "scratchndent_config.toml"));
    try waitForPoll(&worker, &model);
    try std.testing.expectApproxEqAbs(0.4, model.processing.dmin.?[0], 0.0);
    try std.testing.expectEqualStrings("Dmin computed", model.processing.progress);
}
