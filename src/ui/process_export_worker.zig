const std = @import("std");

const processing_config = @import("../processing/config.zig");
const processing_export = @import("../processing/export.zig");
const processing_frames = @import("../processing/frames.zig");
const processing_workflow = @import("../processing/workflow.zig");
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
            const message = std.fmt.bufPrint(
                &model.process_status_buffer,
                "{s}",
                .{result.message},
            ) catch "Export complete";
            model.finishProcessExport(message, result.files.len);
        } else {
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
        model: *const ui_state.State,
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
        freeConfigOverrides(self.allocator, context.config_overrides, context.config_override_names);
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

fn runProcessingExport(context: *Context) !void {
    context.event_queue.pushProgress("Starting export...");
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
                context.event_queue.pushFileWritten(file_name);
            } else {
                context.event_queue.pushProgress(notice.message);
            }
        },
        else => context.event_queue.pushProgress(notice.message),
    }
}

fn currentProcessingImagePath(model: *const ui_state.State) ?[]const u8 {
    if (model.processing.image_idx >= model.processing_images.paths.len) return null;
    return model.processing_images.paths[model.processing.image_idx];
}

fn processingConfigActiveStock(loaded: *const processing_config.LoadedConfig) ?[]const u8 {
    const value = loaded.value("stock") orelse return null;
    if (std.meta.activeTag(value) != .string) return null;
    const stock = value.string.slice();
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
            try std.Thread.yield();
            continue;
        };
        break;
    } else {
        return error.ExportReleaseNotObserved;
    }
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
        try std.Thread.yield();
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
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(!model.process_exporting);
    try std.testing.expectEqual(@as(usize, 1), model.process_export_files_written);
    const expected = try std.fmt.allocPrint(allocator, "Exported 1 file to {s}/ (0.0s)", .{output_dir});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, model.status);
    try std.testing.expectApproxEqAbs(0.2, model.processing.dmin.?[1], 0.0);
}
