const std = @import("std");
const builtin = @import("builtin");

const processing_config = @import("../processing/config.zig");
const processing_events = @import("../processing/events.zig");
const processing_export = @import("../processing/export.zig");
const processing_film_stocks = @import("../processing/film_stocks.zig");
const processing_frames = @import("../processing/frames.zig");
const processing_webgpu = @import("../processing/webgpu.zig");
const processing_workflow = @import("../processing/workflow.zig");
const process_cache = @import("process_cache.zig");
const tiff = @import("../tiff.zig");
const ui_state = @import("state.zig");

pub const ExecuteFn = *const fn (*Context) anyerror!void;

const max_queued_events = 128;
const message_capacity = std.fs.max_path_bytes;

const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

const FixedMessage = struct {
    bytes: [message_capacity]u8 = [_]u8{0} ** message_capacity,
    len: usize = 0,

    fn init(text: []const u8) FixedMessage {
        var message = FixedMessage{};
        message.len = @min(text.len, message.bytes.len);
        @memcpy(message.bytes[0..message.len], text[0..message.len]);
        return message;
    }

    fn slice(self: *const FixedMessage) []const u8 {
        return self.bytes[0..self.len];
    }
};

const QueuedEvent = union(enum) {
    progress: FixedMessage,
    file_written: FixedMessage,
};

const EventQueue = struct {
    lock_state: SpinLock = .{},
    events: [max_queued_events]QueuedEvent = undefined,
    len: usize = 0,

    fn clear(self: *EventQueue) void {
        self.lock_state.lock();
        defer self.lock_state.unlock();
        self.len = 0;
    }

    fn pushProgress(self: *EventQueue, message: []const u8) void {
        self.push(.{ .progress = FixedMessage.init(message) });
    }

    fn pushFileWritten(self: *EventQueue, file_name: []const u8) void {
        self.push(.{ .file_written = FixedMessage.init(file_name) });
    }

    fn push(self: *EventQueue, event: QueuedEvent) void {
        self.lock_state.lock();
        defer self.lock_state.unlock();
        if (self.len < self.events.len) {
            self.events[self.len] = event;
            self.len += 1;
        } else {
            self.events[self.events.len - 1] = event;
        }
    }

    fn drain(self: *EventQueue, model: *ui_state.State) void {
        var local: [max_queued_events]QueuedEvent = undefined;
        self.lock_state.lock();
        const count = self.len;
        for (0..count) |index| local[index] = self.events[index];
        self.len = 0;
        self.lock_state.unlock();

        for (local[0..count]) |event| {
            switch (event) {
                .progress => |message| model.applyProcessingBackendEvent(.{
                    .export_progress = .{ .message = message.slice() },
                }),
                .file_written => |file_name| model.applyProcessingBackendEvent(.{
                    .file_written = .{ .file = file_name.slice() },
                }),
            }
        }
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    input_path: []u8,
    output_dir: []u8,
    basename: []u8,
    rects: []processing_export.FrameRect,
    outputs: processing_export.OutputSelection,
    active_stock: ?[]u8,
    stock_coeffs: ?@import("../processing/film_stocks.zig").Coefficients,
    dmin: ?[3]f64,
    rebate_rect: ?processing_frames.RebateOriginRect,
    current_dpi: ?u32,
    config_overrides: []processing_config.Override,
    config_override_names: [][]u8,
    invert_request: processing_webgpu.Request,
    rgb_page: ?tiff.RgbPageWithMetadata = null,
    total_seconds_override: ?f64 = null,
    result: ?processing_workflow.ExportWorkflowResult = null,
    error_detail: []const u8 = "",
    done: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    event_queue: *EventQueue,
    execute: ExecuteFn,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    execute: ExecuteFn = runProcessingExport,
    thread: ?std.Thread = null,
    context: ?*Context = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    event_queue: EventQueue = .{},

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

    pub fn startFromState(
        self: *Worker,
        model: *ui_state.State,
        controls: ui_state.ProcessExportControls,
    ) !bool {
        if (self.context != null or model.process_exporting) return false;
        const input_path = currentProcessingImagePath(model) orelse {
            model.setProcessingProgress("No image loaded");
            return error.NoProcessImageLoaded;
        };

        var rect_buffer: [64]processing_export.FrameRect = undefined;
        const request = (try model.beginProcessExport(controls, &rect_buffer)) orelse return false;
        errdefer |err| model.applyProcessingBackendEvent(.{ .processing_error = .{
            .operation = "export",
            .detail = @errorName(err),
        } });

        self.done.store(false, .release);
        self.failed.store(false, .release);
        self.event_queue.clear();

        const context = try self.createContext(model, input_path, request);
        errdefer self.destroyContext(context);

        self.thread = try std.Thread.spawn(.{}, threadMain, .{context});
        self.context = context;
        return true;
    }

    pub fn poll(self: *Worker, model: *ui_state.State) bool {
        self.event_queue.drain(model);
        const context = self.context orelse return false;
        if (!context.done.load(.acquire)) return false;

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.event_queue.drain(model);

        if (context.failed.load(.acquire)) {
            model.applyProcessingBackendEvent(.{ .processing_error = .{
                .operation = "export",
                .detail = if (context.error_detail.len == 0) "export failed" else context.error_detail,
            } });
        } else if (context.result) |result| {
            if (result.dmin) |dmin| model.processing.dmin = dmin;
            var missing_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            if (firstMissingExportFile(self.io, context.output_dir, result.files, &missing_path_buffer)) |path| {
                var detail_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
                const detail = std.fmt.bufPrint(
                    &detail_buffer,
                    "reported output missing on disk: {s}",
                    .{path},
                ) catch "reported output missing on disk";
                emitExportError("export", detail);
                model.applyProcessingBackendEvent(.{ .processing_error = .{
                    .operation = "export",
                    .detail = detail,
                } });
            } else {
                const message = std.fmt.bufPrint(
                    &model.process_status_buffer,
                    "{s}",
                    .{result.message},
                ) catch "Export complete";
                emitExportComplete(context.output_dir, result.files.len);
                model.finishProcessExport(message, result.files.len);
                _ = model.refreshGalleryFilesPreservingStatus(self.allocator, self.io) catch false;
            }
        } else {
            emitExportError("export", "export produced no result");
            model.applyProcessingBackendEvent(.{ .processing_error = .{
                .operation = "export",
                .detail = "export produced no result",
            } });
        }

        self.cleanupContext();
        return true;
    }

    fn createContext(
        self: *Worker,
        model: *ui_state.State,
        input_path: []const u8,
        request: processing_export.ExportRequest,
    ) !*Context {
        const context = try self.allocator.create(Context);
        errdefer self.allocator.destroy(context);

        const owned_input_path = try self.allocator.dupe(u8, input_path);
        errdefer self.allocator.free(owned_input_path);
        const owned_output_dir = try self.allocator.dupe(u8, model.processing.output_dir);
        errdefer self.allocator.free(owned_output_dir);
        const owned_basename = try self.allocator.dupe(u8, request.basename);
        errdefer self.allocator.free(owned_basename);
        const owned_rects = try self.allocator.dupe(processing_export.FrameRect, request.rects);
        errdefer self.allocator.free(owned_rects);

        const active_stock_name = if (request.outputs.needInvert())
            processingConfigActiveStock(&model.processing_config)
        else
            null;
        const owned_active_stock = if (active_stock_name) |name| try self.allocator.dupe(u8, name) else null;
        errdefer if (owned_active_stock) |name| self.allocator.free(name);
        const stock_coeffs = if (active_stock_name) |name| blk: {
            const profile = model.processing_config.availableStock(name) orelse return error.UnknownFilmStock;
            if (!profile.has_coeffs) return error.UnknownFilmStock;
            break :blk profile.coeffs;
        } else null;

        var override_names: [][]u8 = &.{};
        const overrides = try copyConfigOverrides(self.allocator, &model.processing_config, &override_names);
        errdefer freeConfigOverrides(self.allocator, overrides, override_names);

        const rebate = if (model.processing.rebate_rect) |rect| processing_frames.RebateOriginRect{
            .x = rect.x,
            .y = rect.y,
            .w = rect.w,
            .h = rect.h,
            .angle = rect.angle,
        } else null;
        var rgb_key = try process_cache.rgbPageKey(self.allocator, self.io, input_path);
        defer rgb_key.deinit(self.allocator);
        const cached_rgb_page = try model.processing_result_cache.rgb_pages.getClone(self.allocator, rgb_key);
        errdefer if (cached_rgb_page) |page| page.deinit(self.allocator);

        context.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .input_path = owned_input_path,
            .output_dir = owned_output_dir,
            .basename = owned_basename,
            .rects = owned_rects,
            .outputs = request.outputs,
            .active_stock = owned_active_stock,
            .stock_coeffs = stock_coeffs,
            .dmin = model.processing.dmin,
            .rebate_rect = rebate,
            .current_dpi = model.processing.current_dpi,
            .config_overrides = overrides,
            .config_override_names = override_names,
            .invert_request = model.processing_gpu_request,
            .rgb_page = cached_rgb_page,
            .done = &self.done,
            .failed = &self.failed,
            .event_queue = &self.event_queue,
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
        self.event_queue.clear();
    }

    fn destroyContext(self: *Worker, context: *Context) void {
        if (context.result) |result| result.deinit(self.allocator);
        self.allocator.free(context.input_path);
        self.allocator.free(context.output_dir);
        self.allocator.free(context.basename);
        self.allocator.free(context.rects);
        if (context.active_stock) |name| self.allocator.free(name);
        if (context.rgb_page) |page| page.deinit(self.allocator);
        freeConfigOverrides(self.allocator, context.config_overrides, context.config_override_names);
        self.allocator.destroy(context);
    }
};

fn threadMain(context: *Context) void {
    emitExportStart(context);
    context.execute(context) catch |err| {
        context.error_detail = @errorName(err);
        emitExportError("export", @errorName(err));
        context.failed.store(true, .release);
    };
    context.done.store(true, .release);
}

fn runProcessingExport(context: *Context) !void {
    context.event_queue.pushProgress("Starting export...");
    if (context.rgb_page) |page| {
        context.result = processing_workflow.processExportFromCachedRgbPage(context.allocator, context.io, page, .{
            .input_path = context.input_path,
            .output_dir = context.output_dir,
            .basename = context.basename,
            .rects = context.rects,
            .outputs = context.outputs,
            .active_stock = context.active_stock,
            .stock_coeffs = context.stock_coeffs,
            .dmin = context.dmin,
            .rebate_rect = context.rebate_rect,
            .current_dpi = context.current_dpi,
            .config_overrides = context.config_overrides,
            .invert_request = context.invert_request,
            .total_seconds_override = context.total_seconds_override,
            .progress_sink = .{
                .context = context,
                .emit = enqueueWorkflowProgress,
            },
        }) catch |err| switch (err) {
            error.UnsupportedCachedRgbExport => null,
            else => return err,
        };
        if (context.result != null) return;
    }
    context.result = try processing_workflow.processExportFromTiff(context.allocator, context.io, .{
        .input_path = context.input_path,
        .output_dir = context.output_dir,
        .basename = context.basename,
        .rects = context.rects,
        .outputs = context.outputs,
        .active_stock = context.active_stock,
        .stock_coeffs = context.stock_coeffs,
        .dmin = context.dmin,
        .rebate_rect = context.rebate_rect,
        .current_dpi = context.current_dpi,
        .config_overrides = context.config_overrides,
        .invert_request = context.invert_request,
        .total_seconds_override = context.total_seconds_override,
        .progress_sink = .{
            .context = context,
            .emit = enqueueWorkflowProgress,
        },
    });
}

fn enqueueWorkflowProgress(raw_context: *anyopaque, notice: processing_workflow.ExportProgressNotice) void {
    const context: *Context = @ptrCast(@alignCast(raw_context));
    switch (notice.kind) {
        .wrote_file => {
            if (notice.file_name) |file_name| {
                emitFileWritten(file_name);
                context.event_queue.pushFileWritten(file_name);
            } else {
                emitExportProgress(notice.message);
                context.event_queue.pushProgress(notice.message);
            }
        },
        else => {
            emitExportProgress(notice.message);
            context.event_queue.pushProgress(notice.message);
        },
    }
}

fn firstMissingExportFile(
    io: std.Io,
    output_dir: []const u8,
    files: []const []const u8,
    buffer: []u8,
) ?[]const u8 {
    for (files) |file| {
        const path = formatExportPath(buffer, output_dir, file) catch file;
        std.Io.Dir.cwd().access(io, path, .{}) catch return path;
    }
    return null;
}

fn formatExportPath(buffer: []u8, output_dir: []const u8, file: []const u8) ![]const u8 {
    if (output_dir.len == 0 or std.mem.eql(u8, output_dir, ".")) {
        return std.fmt.bufPrint(buffer, "{s}", .{file});
    }
    if (std.mem.endsWith(u8, output_dir, "/")) {
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ output_dir, file });
    }
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ output_dir, file });
}

fn emitExportStart(context: *const Context) void {
    if (builtin.is_test) return;
    processing_events.emitExportStart(.{
        .frame_count = context.rects.len,
        .output_dir = context.output_dir,
    });
    std.debug.print(
        "[v600 process export] start input={s} output_dir={s} basename={s} frames={d} ir_neg={s} ir_inv={s} inv_only={s}\n",
        .{
            context.input_path,
            context.output_dir,
            context.basename,
            context.rects.len,
            boolText(context.outputs.ir_neg),
            boolText(context.outputs.ir_inv),
            boolText(context.outputs.inv_only),
        },
    );
}

fn emitExportProgress(message: []const u8) void {
    if (builtin.is_test) return;
    processing_events.emitExportProgress(.{ .message = message });
}

fn emitFileWritten(file_name: []const u8) void {
    if (builtin.is_test) return;
    processing_events.emitFileWritten(.{ .file = file_name });
}

fn emitExportComplete(output_dir: []const u8, file_count: usize) void {
    if (builtin.is_test) return;
    processing_events.emitExportComplete(.{
        .file_count = file_count,
        .output_dir = output_dir,
    });
}

fn emitExportError(operation: []const u8, detail: []const u8) void {
    if (builtin.is_test) return;
    processing_events.emitProcessingError(.{
        .operation = operation,
        .detail = detail,
    });
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn currentProcessingImagePath(model: *const ui_state.State) ?[]const u8 {
    if (model.processing.image_idx >= model.processing_images.paths.len) return null;
    return model.processing_images.paths[model.processing.image_idx];
}

fn processingConfigActiveStock(loaded: *const processing_config.LoadedConfig) ?[]const u8 {
    const entry = loaded.entry("stock") orelse return null;
    if (std.meta.activeTag(entry.value) != .string) return null;
    const stock = entry.value.string.slice();
    return if (stock.len == 0) null else stock;
}

fn copyConfigOverrides(
    allocator: std.mem.Allocator,
    loaded: *const processing_config.LoadedConfig,
    out_names: *[][]u8,
) ![]processing_config.Override {
    var count: usize = 0;
    for (loaded.entries[0..loaded.len]) |entry| {
        if (!std.mem.eql(u8, entry.name.slice(), "_stocks")) count += 1;
    }
    const names = try allocator.alloc([]u8, count);
    errdefer allocator.free(names);
    const overrides = try allocator.alloc(processing_config.Override, count);
    errdefer allocator.free(overrides);

    var index: usize = 0;
    errdefer {
        for (names[0..index]) |name| allocator.free(name);
    }
    for (loaded.entries[0..loaded.len]) |entry| {
        const name = entry.name.slice();
        if (std.mem.eql(u8, name, "_stocks")) continue;
        names[index] = try allocator.dupe(u8, name);
        overrides[index] = .{ .name = names[index], .value = entry.value };
        index += 1;
    }
    out_names.* = names;
    return overrides;
}

fn freeConfigOverrides(
    allocator: std.mem.Allocator,
    overrides: []processing_config.Override,
    names: [][]u8,
) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
    allocator.free(overrides);
}

fn fakeExportWaitForRelease(context: *Context) !void {
    context.event_queue.pushProgress("Preparing export (1 frame)...");
    context.event_queue.pushProgress("Processing 1 frame...");
    const release_path = try std.fs.path.join(context.allocator, &.{ context.output_dir, ".release" });
    defer context.allocator.free(release_path);
    for (0..10_000) |_| {
        std.Io.Dir.cwd().access(context.io, release_path, .{}) catch {
            std.Io.sleep(context.io, .fromMilliseconds(1), .awake) catch {};
            continue;
        };
        break;
    } else {
        return error.ExportReleaseNotObserved;
    }
    const output_path = try std.fs.path.join(context.allocator, &.{ context.output_dir, "roll_01_inv.tif" });
    defer context.allocator.free(output_path);
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = output_path, .data = "" });
    context.event_queue.pushFileWritten("roll_01_inv.tif");
    const files = try context.allocator.alloc([]u8, 1);
    errdefer context.allocator.free(files);
    files[0] = try context.allocator.dupe(u8, "roll_01_inv.tif");
    errdefer context.allocator.free(files[0]);
    context.result = .{
        .message = try std.fmt.allocPrint(context.allocator, "Exported 1 file to {s}/ (0.0s)", .{context.output_dir}),
        .files = files,
        .dmin = .{ 0.1, 0.2, 0.3 },
        .progress = .{ .events = try context.allocator.alloc(processing_export.ExportProgressEvent, 0) },
    };
}

fn fakeExportAssertGpuRequest(context: *Context) !void {
    try std.testing.expectEqual(processing_webgpu.Backend.webgpu, context.invert_request.backend);
    try std.testing.expectEqual(processing_webgpu.FallbackPolicy.allow_cpu, context.invert_request.fallback);
    context.result = .{
        .message = try context.allocator.dupe(u8, "GPU request observed"),
        .files = try context.allocator.alloc([]u8, 0),
        .progress = .{ .events = try context.allocator.alloc(processing_export.ExportProgressEvent, 0) },
    };
}

fn fakeExportAssertBuiltinStockCoeffs(context: *Context) !void {
    try std.testing.expectEqualStrings("kodak_gold", context.active_stock.?);
    try std.testing.expect(context.stock_coeffs != null);
    try std.testing.expectEqual(processing_film_stocks.kodak_gold_coeffs, context.stock_coeffs.?);
    context.result = .{
        .message = try context.allocator.dupe(u8, "builtin stock coeffs observed"),
        .files = try context.allocator.alloc([]u8, 0),
        .progress = .{ .events = try context.allocator.alloc(processing_export.ExportProgressEvent, 0) },
    };
}

fn fakeExportAssertCachedRgbPage(context: *Context) !void {
    try std.testing.expect(context.rgb_page != null);
    try std.testing.expectEqual(@as(usize, 12), context.rgb_page.?.rgb.data.len);
    context.result = .{
        .message = try context.allocator.dupe(u8, "cached RGB page observed"),
        .files = try context.allocator.alloc([]u8, 0),
        .progress = .{ .events = try context.allocator.alloc(processing_export.ExportProgressEvent, 0) },
    };
}

fn fakeExportReportsMissingFile(context: *Context) !void {
    const files = try context.allocator.alloc([]u8, 1);
    errdefer context.allocator.free(files);
    files[0] = try context.allocator.dupe(u8, "missing_01_inv.tif");
    errdefer context.allocator.free(files[0]);
    context.result = .{
        .message = try std.fmt.allocPrint(context.allocator, "Exported 1 file to {s}/ (0.0s)", .{context.output_dir}),
        .files = files,
        .progress = .{ .events = try context.allocator.alloc(processing_export.ExportProgressEvent, 0) },
    };
}

fn fakeRgbPage(allocator: std.mem.Allocator, width: u32, height: u32) !tiff.RgbPageWithMetadata {
    const len = @as(usize, width) * @as(usize, height) * 3;
    const data = try allocator.alloc(u8, len);
    for (data, 0..) |*sample, index| sample.* = @intCast(index % 256);
    return .{
        .rgb = .{
            .width = width,
            .height = height,
            .samples_per_pixel = 3,
            .bits_per_sample = 8,
            .data = data,
        },
        .dpi = 800,
        .ir = null,
    };
}

test "process export worker keeps UI state live and rejects duplicate starts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/frames", .{tmp.sub_path[0..]});
    defer allocator.free(output_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, output_dir);
    const release_path = try std.fs.path.join(allocator, &.{ output_dir, ".release" });
    defer allocator.free(release_path);

    var model = ui_state.State.init("scans", output_dir, 0);
    defer model.deinit(allocator);
    model.processing.output_dir = output_dir;
    model.processing.preview_scale = 1.0;
    model.processing.current_dpi = 800;
    model.processing_images.paths = try allocator.alloc([]u8, 1);
    model.processing_images.paths[0] = try allocator.dupe(u8, "test/fixtures/tiff/rgb-thumb-ir.tiff");
    model.processing.image_count = 1;
    model.processing.image_idx = 0;
    model.process_selections[0] = .{ .x = 0.0, .y = 0.0, .w = 2.0, .h = 2.0, .rotation = 0 };
    model.process_selection_count = 1;

    var worker = Worker.initWithExecutor(allocator, std.testing.io, fakeExportWaitForRelease);
    defer worker.deinit();
    try std.testing.expect(try worker.startFromState(&model, .{
        .basename = "roll",
        .export_ir_inv = false,
        .export_inv_only = true,
    }));
    try std.testing.expect(model.process_exporting);
    try std.testing.expect(worker.isRunning());
    try std.testing.expect(!(try worker.startFromState(&model, .{})));

    var observed_progress = false;
    for (0..1000) |_| {
        _ = worker.poll(&model);
        if (std.mem.eql(u8, model.processExportStatus().status, "Processing 1 frame...")) {
            observed_progress = true;
            break;
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(observed_progress);
    try std.testing.expect(model.process_exporting);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = release_path, .data = "" });
    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(completed);
    try std.testing.expect(!model.process_exporting);
    try std.testing.expectEqual(@as(usize, 1), model.process_export_files_written);
    const expected = try std.fmt.allocPrint(allocator, "Exported 1 file to {s}/ (0.0s)", .{output_dir});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, model.status);
    try std.testing.expectApproxEqAbs(0.2, model.processing.dmin.?[1], 0.0);
    try std.testing.expectEqual(@as(usize, 1), model.gallery_files.files.len);
    try std.testing.expectEqualStrings("roll_01_inv.tif", model.gallery_files.files[0]);
    try std.testing.expectEqualStrings(expected, model.galleryInfo().status);
}

test "process export worker rejects successful result when reported file is absent" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/frames", .{tmp.sub_path[0..]});
    defer allocator.free(output_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, output_dir);

    var model = ui_state.State.init("scans", output_dir, 0);
    defer model.deinit(allocator);
    model.processing.output_dir = output_dir;
    model.processing.preview_scale = 1.0;
    model.processing.current_dpi = 800;
    model.processing_images.paths = try allocator.alloc([]u8, 1);
    model.processing_images.paths[0] = try allocator.dupe(u8, "test/fixtures/tiff/rgb-thumb-ir.tiff");
    model.processing.image_count = 1;
    model.processing.image_idx = 0;
    model.process_selections[0] = .{ .x = 0.0, .y = 0.0, .w = 2.0, .h = 2.0, .rotation = 0 };
    model.process_selection_count = 1;

    var worker = Worker.initWithExecutor(allocator, std.testing.io, fakeExportReportsMissingFile);
    defer worker.deinit();
    try std.testing.expect(try worker.startFromState(&model, .{
        .basename = "roll",
        .export_ir_inv = false,
        .export_inv_only = true,
    }));
    for (0..1000) |_| {
        if (worker.poll(&model)) break;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    } else return error.ExportWorkerDidNotFinish;

    try std.testing.expect(!model.process_exporting);
    try std.testing.expectEqual(@as(usize, 0), model.process_export_files_written);
    const expected_status = try std.fmt.allocPrint(
        allocator,
        "Export failed: reported output missing on disk: {s}/missing_01_inv.tif",
        .{output_dir},
    );
    defer allocator.free(expected_status);
    try std.testing.expectEqualStrings(expected_status, model.status);
    try std.testing.expectEqual(@as(usize, 0), model.gallery_files.files.len);
}

test "process export worker copies resident RGB page into workflow context" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/frames", .{tmp.sub_path[0..]});
    defer allocator.free(output_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, output_dir);

    var model = ui_state.State.init("scans", output_dir, 0);
    defer model.deinit(allocator);
    model.processing.output_dir = output_dir;
    model.processing.preview_scale = 1.0;
    model.processing.current_dpi = 800;
    model.processing.dmin = .{ 0.1, 0.2, 0.3 };
    model.processing_images.paths = try allocator.alloc([]u8, 1);
    model.processing_images.paths[0] = try allocator.dupe(u8, "scans/scan_export_rgb_cache.tiff");
    model.processing.image_count = 1;
    model.processing.image_idx = 0;
    model.process_selections[0] = .{ .x = 0.0, .y = 0.0, .w = 2.0, .h = 2.0, .rotation = 0 };
    model.process_selection_count = 1;

    var key = try process_cache.rgbPageKey(allocator, std.testing.io, model.processing_images.paths[0]);
    defer key.deinit(allocator);
    var page = try fakeRgbPage(allocator, 2, 2);
    try std.testing.expect(try model.processing_result_cache.rgb_pages.putOwned(allocator, key, &page));

    var worker = Worker.initWithExecutor(allocator, std.testing.io, fakeExportAssertCachedRgbPage);
    defer worker.deinit();
    try std.testing.expect(try worker.startFromState(&model, .{
        .basename = "roll",
        .export_ir_inv = false,
        .export_inv_only = true,
    }));
    for (0..1000) |_| {
        if (worker.poll(&model)) break;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    } else return error.ExportWorkerDidNotFinish;
    try std.testing.expectEqualStrings("cached RGB page observed", model.status);
}

test "process export worker copies native processing GPU request into workflow context" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/frames", .{tmp.sub_path[0..]});
    defer allocator.free(output_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, output_dir);

    var model = ui_state.State.init("scans", output_dir, 0);
    defer model.deinit(allocator);
    model.setProcessingGpuRequest(allocator, .{
        .backend = .webgpu,
        .fallback = .allow_cpu,
    });
    model.processing.output_dir = output_dir;
    model.processing.preview_scale = 1.0;
    model.processing.current_dpi = 800;
    model.processing_images.paths = try allocator.alloc([]u8, 1);
    model.processing_images.paths[0] = try allocator.dupe(u8, "test/fixtures/tiff/rgb-thumb-ir.tiff");
    model.processing.image_count = 1;
    model.processing.image_idx = 0;
    model.process_selections[0] = .{ .x = 0.0, .y = 0.0, .w = 2.0, .h = 2.0, .rotation = 0 };
    model.process_selection_count = 1;

    var worker = Worker.initWithExecutor(allocator, std.testing.io, fakeExportAssertGpuRequest);
    defer worker.deinit();
    try std.testing.expect(try worker.startFromState(&model, .{
        .basename = "roll",
        .export_ir_inv = false,
        .export_inv_only = true,
    }));

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(completed);
    try std.testing.expectEqualStrings("GPU request observed", model.status);
}

test "process export worker resolves selected builtin stock despite incomplete config shadow" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/frames", .{tmp.sub_path[0..]});
    defer allocator.free(output_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, output_dir);

    var model = ui_state.State.init("scans", output_dir, 0);
    defer model.deinit(allocator);
    model.processing.output_dir = output_dir;
    model.processing.preview_scale = 1.0;
    model.processing.current_dpi = 800;
    model.processing_images.paths = try allocator.alloc([]u8, 1);
    model.processing_images.paths[0] = try allocator.dupe(u8, "test/fixtures/tiff/rgb-thumb-ir.tiff");
    model.processing.image_count = 1;
    model.processing.image_idx = 0;
    model.process_selections[0] = .{ .x = 0.0, .y = 0.0, .w = 2.0, .h = 2.0, .rotation = 0 };
    model.process_selection_count = 1;

    var loaded = processing_config.LoadedConfig{};
    try loaded.set("stock", .{ .string = processing_config.FixedString.init("kodak_gold") });
    _ = try loaded.ensureStock("kodak_gold");
    model.applyProcessingConfig(loaded);

    var worker = Worker.initWithExecutor(allocator, std.testing.io, fakeExportAssertBuiltinStockCoeffs);
    defer worker.deinit();
    try std.testing.expect(try worker.startFromState(&model, .{
        .basename = "roll",
        .export_ir_inv = false,
        .export_inv_only = true,
    }));

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(completed);
    try std.testing.expectEqualStrings("builtin stock coeffs observed", model.status);
}
