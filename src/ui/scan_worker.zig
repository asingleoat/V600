const std = @import("std");

const film_lut = @import("../scanner/film_lut.zig");
const scanner_contracts = @import("../scanner/contracts.zig");
const scanner_events = @import("../scanner/events.zig");
const scanner_host = @import("../scanner.zig").host;
const scanner_lut = @import("../scanner/lut.zig");
const preview_worker = @import("preview_worker.zig");
const ui_state = @import("state.zig");

pub const ExecuteFn = *const fn (*Context) anyerror!void;

const max_queued_events = 64;

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

const EventQueue = struct {
    lock_state: SpinLock = .{},
    events: [max_queued_events]ui_state.ScannerBackendEvent = undefined,
    len: usize = 0,
    event_sink: ?scanner_events.Sink = null,

    fn clear(self: *EventQueue) void {
        self.lock_state.lock();
        defer self.lock_state.unlock();
        self.len = 0;
    }

    fn push(self: *EventQueue, event: ui_state.ScannerBackendEvent) void {
        self.lock_state.lock();
        defer self.lock_state.unlock();
        if (self.len < self.events.len) {
            self.events[self.len] = event;
            self.len += 1;
        } else {
            self.events[self.events.len - 1] = event;
        }
    }

    fn pushTiming(self: *EventQueue, event: scanner_events.TimingEvent) void {
        scanner_events.emitTiming(event);
        if (self.event_sink) |sink| sink.send(.{ .timing = event });
        self.push(.{ .timing = event });
    }

    fn pushTimingSince(self: *EventQueue, stage: []const u8, start_ns: u64, detail: ?[]const u8) void {
        self.pushTiming(.{
            .stage = stage,
            .elapsed_us = (monotonicNowNs() - start_ns) / std.time.ns_per_us,
            .detail = detail,
        });
    }

    fn drain(self: *EventQueue, model: *ui_state.State) usize {
        var local: [max_queued_events]ui_state.ScannerBackendEvent = undefined;
        self.lock_state.lock();
        const count = self.len;
        for (0..count) |index| local[index] = self.events[index];
        self.len = 0;
        self.lock_state.unlock();

        for (local[0..count]) |event| {
            model.applyScannerBackendEvent(event);
        }
        return count;
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    request: ui_state.ScanStartPlan,
    output_path: []u8,
    cancel_file_path: ?[]u8,
    lut_file_path: ?[]u8 = null,
    metadata_path: ?[]u8 = null,
    capabilities: ?scanner_contracts.ScannerCapabilities = null,
    error_detail: []const u8 = "",
    done: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    cancelled: *std.atomic.Value(bool),
    event_queue: *EventQueue,
    execute: ExecuteFn,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    execute: ExecuteFn = runScannerScan,
    thread: ?std.Thread = null,
    context: ?*Context = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    event_queue: EventQueue = .{},
    cancel_file_written: bool = false,
    event_sink: ?scanner_events.Sink = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *std.process.Environ.Map,
    ) Worker {
        return .{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
        };
    }

    pub fn initWithExecutor(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ_map: *std.process.Environ.Map,
        execute: ExecuteFn,
    ) Worker {
        var worker = init(allocator, io, environ_map);
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

    pub fn startQueued(self: *Worker, model: *ui_state.State, preview_buffer: ?preview_worker.PreviewBuffer) !bool {
        if (self.context != null) return false;
        const command = model.takeCommand() orelse return false;
        switch (command) {
            .preview_scan => {
                model.pending_command = command;
                return false;
            },
            .scan_start => |plan| try self.startScan(plan, preview_buffer, model.scanner_capabilities),
        }
        return true;
    }

    pub fn startScan(
        self: *Worker,
        plan: ui_state.ScanStartPlan,
        preview_buffer: ?preview_worker.PreviewBuffer,
        capabilities: ?scanner_contracts.ScannerCapabilities,
    ) !void {
        if (self.context != null) return error.ScanWorkerBusy;

        const start_ns = monotonicNowNs();
        self.done.store(false, .release);
        self.failed.store(false, .release);
        self.cancelled.store(false, .release);
        self.event_queue.clear();
        self.event_queue.event_sink = self.event_sink;
        self.cancel_file_written = false;

        const output_path = try self.allocator.dupe(u8, plan.output_path);
        errdefer self.allocator.free(output_path);
        const cancel_file_path = if (plan.cancel_file_path) |path| try self.allocator.dupe(u8, path) else null;
        errdefer if (cancel_file_path) |path| self.allocator.free(path);
        const lut_start = monotonicNowNs();
        const lut_file_path = try self.prepareLutFile(plan, output_path, preview_buffer, &self.event_queue);
        self.event_queue.pushTimingSince("native.scan.lut_prepare", lut_start, if (lut_file_path == null) "skipped" else "ok");
        errdefer if (lut_file_path) |path| {
            deleteIfExists(self.io, path);
            self.allocator.free(path);
        };

        if (cancel_file_path) |path| {
            const cancel_cleanup_start = monotonicNowNs();
            deleteIfExists(self.io, path);
            self.event_queue.pushTimingSince("native.scan.cancel_file_cleanup", cancel_cleanup_start, "pre-start");
        }

        const context = try self.allocator.create(Context);
        errdefer self.allocator.destroy(context);

        var owned_plan = plan;
        owned_plan.output_path = output_path;
        owned_plan.request.output_path = output_path;
        owned_plan.cancel_file_path = cancel_file_path;
        owned_plan.request.lut_file_path = lut_file_path;
        context.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .environ_map = self.environ_map,
            .request = owned_plan,
            .output_path = output_path,
            .cancel_file_path = cancel_file_path,
            .lut_file_path = lut_file_path,
            .capabilities = capabilities,
            .done = &self.done,
            .failed = &self.failed,
            .cancelled = &self.cancelled,
            .event_queue = &self.event_queue,
            .execute = self.execute,
        };
        self.event_queue.pushTimingSince("native.scan.start_scan", start_ns, "prepared");

        self.thread = try std.Thread.spawn(.{}, threadMain, .{context});
        self.context = context;
    }

    fn prepareLutFile(
        self: *Worker,
        plan: ui_state.ScanStartPlan,
        output_path: []const u8,
        preview_buffer: ?preview_worker.PreviewBuffer,
        event_queue: *EventQueue,
    ) !?[]u8 {
        if (plan.request.kind == .ir) return null;
        const preview = preview_buffer orelse return null;
        if (preview.samples_per_pixel < 3 or preview.bits_per_sample != 8) return null;
        const selection = plan.preview_selection orelse return null;
        const generate_start = monotonicNowNs();
        const computed = try film_lut.computeFilmLuts(
            self.allocator,
            preview.data,
            @intCast(preview.width),
            @intCast(preview.height),
            @intCast(preview.samples_per_pixel),
            .{ .x = selection.x, .y = selection.y, .w = selection.w, .h = selection.h },
            .{ .mode = exposureMode(plan.exposure) },
        );
        event_queue.pushTimingSince("native.scan.lut_generate", generate_start, "ok");
        if (computed.red == null and computed.green == null and computed.blue == null) return null;

        const path = try std.fmt.allocPrint(self.allocator, "{s}.lut.bin", .{output_path});
        errdefer self.allocator.free(path);
        const write_start = monotonicNowNs();
        try scanner_lut.writeRgbFile(
            self.io,
            path,
            if (computed.red) |*lut| lut else null,
            if (computed.green) |*lut| lut else null,
            if (computed.blue) |*lut| lut else null,
        );
        event_queue.pushTimingSince("native.scan.lut_write", write_start, "ok");
        return path;
    }

    pub fn requestCancelIfNeeded(self: *Worker, model: *ui_state.State) !void {
        if (!model.scanner.cancel_requested or self.cancel_file_written) return;
        const context = self.context orelse return;
        const path = context.cancel_file_path orelse return;
        const start_ns = monotonicNowNs();
        try writeCancelFile(self.io, path);
        self.cancel_file_written = true;
        context.event_queue.pushTimingSince("native.scan.cancel_file_write", start_ns, "ok");
    }

    pub fn poll(self: *Worker, model: *ui_state.State) bool {
        self.requestCancelIfNeeded(model) catch {
            model.applyScannerBackendEvent(.{ .scan_error = .{
                .kind = .backend_failure,
                .detail = "failed to write scanner cancel file",
            } });
            return false;
        };

        const drain_start = monotonicNowNs();
        const drained = self.event_queue.drain(model);
        if (drained != 0) {
            self.applyTiming(model, .{
                .stage = "native.scan.event_drain",
                .elapsed_us = (monotonicNowNs() - drain_start) / std.time.ns_per_us,
                .detail = "running",
            });
        }
        const context = self.context orelse return false;
        if (!context.done.load(.acquire)) return false;

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        const final_drain_start = monotonicNowNs();
        const final_drained = self.event_queue.drain(model);
        if (final_drained != 0) {
            self.applyTiming(model, .{
                .stage = "native.scan.event_drain",
                .elapsed_us = (monotonicNowNs() - final_drain_start) / std.time.ns_per_us,
                .detail = "final",
            });
        }

        const state_start = monotonicNowNs();
        if (context.cancelled.load(.acquire)) {
            model.applyScannerBackendEvent(.{ .scan_cancelled = .{
                .kind = .cancelled,
                .detail = "cancel file observed",
            } });
        } else if (context.failed.load(.acquire)) {
            model.applyScannerBackendEvent(.{ .scan_error = .{
                .kind = .backend_failure,
                .detail = if (context.error_detail.len == 0) "scan failed" else context.error_detail,
            } });
        } else {
            model.applyScannerBackendEvent(.{ .scan_complete = .{
                .output = context.output_path,
                .metadata = context.metadata_path orelse context.output_path,
            } });
        }
        self.applyTiming(model, .{
            .stage = "native.scan.state_update",
            .elapsed_us = (monotonicNowNs() - state_start) / std.time.ns_per_us,
            .detail = if (context.cancelled.load(.acquire)) "cancelled" else if (context.failed.load(.acquire)) "failed" else "ok",
        });

        const cleanup_start = monotonicNowNs();
        self.cleanupContext();
        self.applyTiming(model, .{
            .stage = "native.scan.cleanup",
            .elapsed_us = (monotonicNowNs() - cleanup_start) / std.time.ns_per_us,
            .detail = "ok",
        });
        return true;
    }

    fn applyTiming(self: *Worker, model: *ui_state.State, event: scanner_events.TimingEvent) void {
        scanner_events.emitTiming(event);
        if (self.event_sink) |sink| sink.send(.{ .timing = event });
        model.applyScannerBackendEvent(.{ .timing = event });
    }

    fn cleanupContext(self: *Worker) void {
        if (self.context) |context| {
            if (context.cancel_file_path) |path| {
                deleteIfExists(self.io, path);
                self.allocator.free(path);
            }
            if (context.lut_file_path) |path| {
                deleteIfExists(self.io, path);
                self.allocator.free(path);
            }
            if (context.metadata_path) |path| self.allocator.free(path);
            self.allocator.free(context.output_path);
            self.allocator.destroy(context);
            self.context = null;
        }
        self.done.store(false, .release);
        self.failed.store(false, .release);
        self.cancelled.store(false, .release);
        self.event_queue.clear();
        self.cancel_file_written = false;
    }
};

fn threadMain(context: *Context) void {
    context.execute(context) catch |err| {
        if (err == error.ScanCancelled) {
            context.cancelled.store(true, .release);
        } else {
            context.error_detail = @errorName(err);
            context.failed.store(true, .release);
        }
    };
    context.done.store(true, .release);
}

fn runScannerScan(context: *Context) !void {
    const setup_start = monotonicNowNs();
    const runtime = scanner_host.Runtime{
        .allocator = context.allocator,
        .io = context.io,
        .environ_map = context.environ_map,
        .event_sink = .{
            .context = context,
            .emit = enqueueRuntimeEvent,
        },
    };
    context.event_queue.pushTimingSince("native.scan.runtime_setup", setup_start, "ok");
    var request = context.request.request;
    request.output_path = context.output_path;
    const scan_start = monotonicNowNs();
    try runtime.scan(.{
        .request = request,
        .output_path = context.output_path,
        .cancel_file = context.cancel_file_path,
        .capabilities = context.capabilities,
    });
    context.event_queue.pushTimingSince("native.scan.runtime_scan", scan_start, "ok");
    const metadata_start = monotonicNowNs();
    context.metadata_path = try std.fmt.allocPrint(context.allocator, "{s}.json", .{context.output_path});
    context.event_queue.pushTimingSince("native.scan.metadata_path", metadata_start, "ok");
}

fn enqueueRuntimeEvent(raw_context: *anyopaque, event: scanner_events.Event) void {
    const context: *Context = @ptrCast(@alignCast(raw_context));
    if (context.event_queue.event_sink) |sink| sink.send(event);
    switch (event) {
        .scan_start => |scan_start| context.event_queue.push(.{ .scan_start = .{
            .device = "",
            .output = "",
            .source = scan_start.source,
            .kind = scan_start.kind,
            .requested_dpi = scan_start.requested_dpi,
            .effective_dpi = scan_start.effective_dpi,
        } }),
        .progress => |progress| context.event_queue.push(.{ .progress = progress }),
        .timing => |timing| context.event_queue.push(.{ .timing = timing }),
        else => {},
    }
}

fn exposureMode(mode: ui_state.ExposureMode) film_lut.Mode {
    return switch (mode) {
        .affine => .affine,
        .linear => .linear,
    };
}

fn writeCancelFile(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len != 0) std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    file.close(io);
}

fn deleteIfExists(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn fakeScanSuccess(context: *Context) !void {
    context.event_queue.pushTiming(.{
        .stage = "native.scan.fake_executor",
        .elapsed_us = 1,
        .detail = "ok",
    });
    if (context.request.request.source != .tpu) return error.BadSource;
    if (context.request.request.output_path == null) return error.MissingOutputPath;
    if (!std.mem.eql(u8, context.request.request.output_path.?, context.output_path)) return error.BadOutputPath;
    if (context.lut_file_path) |path| {
        if (context.request.request.lut_file_path == null) return error.MissingRequestLutPath;
        if (!std.mem.eql(u8, context.request.request.lut_file_path.?, path)) return error.BadRequestLutPath;
    }
    context.metadata_path = try std.fmt.allocPrint(context.allocator, "{s}.json", .{context.output_path});
}

fn fakeScanRequiresCachedCapabilities(context: *Context) !void {
    context.event_queue.pushTiming(.{
        .stage = "native.scan.fake_cached_capabilities",
        .elapsed_us = 1,
        .detail = "ok",
    });
    const caps = context.capabilities orelse return error.MissingCachedCapabilities;
    if (caps.max_resolution != 3200) return error.BadCachedCapabilities;
    if (caps.tpu_width_in != 3.0 or caps.tpu_height_in != 9.0) return error.BadCachedCapabilities;
    context.metadata_path = try std.fmt.allocPrint(context.allocator, "{s}.json", .{context.output_path});
}

fn fakeScanFailure(context: *Context) !void {
    context.event_queue.pushTiming(.{
        .stage = "native.scan.fake_executor",
        .elapsed_us = 1,
        .detail = "failed",
    });
    return error.FakeScanFailure;
}

fn fakeScanWaitForCancel(context: *Context) !void {
    const path = context.cancel_file_path orelse return error.MissingCancelFile;
    for (0..10_000) |_| {
        if (fileExists(context.io, path)) return error.ScanCancelled;
        try std.Thread.yield();
    }
    return error.CancelFileNotObserved;
}

fn fakeScanEmitLiveEventsWaitForCancel(context: *Context) !void {
    context.event_queue.push(.{ .scan_start = .{
        .device = "",
        .output = "",
        .source = .tpu,
        .kind = .rgb,
        .requested_dpi = context.request.request.dpi,
        .effective_dpi = context.request.request.dpi,
    } });
    context.event_queue.push(.{ .progress = .{ .percent = 37 } });
    context.event_queue.push(.{ .scan_start = .{
        .device = "",
        .output = "",
        .source = .tpu,
        .kind = .ir,
        .requested_dpi = @min(context.request.request.dpi, 3200),
        .effective_dpi = @min(context.request.request.dpi, 3200),
    } });
    context.event_queue.push(.{ .progress = .{ .percent = 82 } });

    const path = context.cancel_file_path orelse return error.MissingCancelFile;
    for (0..10_000) |_| {
        if (fileExists(context.io, path)) return error.ScanCancelled;
        try std.Thread.yield();
    }
    return error.CancelFileNotObserved;
}

fn previewBufferWithFilmLutImage(allocator: std.mem.Allocator) !preview_worker.PreviewBuffer {
    const data = try allocator.alloc(u8, 24 * 24 * 3);
    errdefer allocator.free(data);
    @memset(data, 230);
    var y: usize = 4;
    while (y < 20) : (y += 1) {
        var x: usize = 4;
        while (x < 20) : (x += 1) {
            const offset = (y * 24 + x) * 3;
            data[offset] = @intCast(30 + x * 3 + y);
            data[offset + 1] = @intCast(20 + x * 2 + y * 2);
            data[offset + 2] = @intCast(10 + x + y * 3);
        }
        x = 18;
        while (x < 20) : (x += 1) {
            const offset = (y * 24 + x) * 3;
            data[offset] = 245;
            data[offset + 1] = 245;
            data[offset + 2] = 245;
        }
    }
    const output_path = try allocator.dupe(u8, "film-lut-preview");
    errdefer allocator.free(output_path);
    return .{
        .output_path = output_path,
        .width = 24,
        .height = 24,
        .samples_per_pixel = 3,
        .bits_per_sample = 8,
        .data = data,
    };
}

test "scan worker consumes queued scan command without blocking UI state" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(1000, 500, 10.0, 5.0);
    model.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(model.queueScanStart(".zig-cache/v600-scan.cancel"));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, null));
    try std.testing.expect(model.pending_command == null);

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(!worker.isRunning());
    try std.testing.expect(!model.scanner.scanning);
    try std.testing.expectEqual(@as(usize, 2), model.scanner.scan_counter);
    try std.testing.expectEqualStrings("Saved: scan_0001_rgbir_3200dpi.tiff", model.status);
    try std.testing.expect(model.scanner_timing_count >= 5);
    try std.testing.expectEqualStrings("native.scan.cleanup", model.scanner_timing_stage);
    try std.testing.expectEqualStrings("ok", model.scanner_timing_detail.?);
}

test "scan worker passes connected scanner capabilities to runtime context" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnectedWithCapabilities(1000, 500, .{
        .max_resolution = 3200,
        .tpu_width_in = 3.0,
        .tpu_height_in = 9.0,
    });
    model.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(model.queueScanStart(".zig-cache/v600-scan.cancel"));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanRequiresCachedCapabilities);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, null));

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(!model.scanner.scanning);
    try std.testing.expectEqualStrings("Saved: scan_0001_rgbir_3200dpi.tiff", model.status);
}

test "scan worker writes temporary LUT file from preview pixels" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scan_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(scan_dir);

    var preview = try previewBufferWithFilmLutImage(std.testing.allocator);
    defer preview.deinit(std.testing.allocator);

    var model = ui_state.State.init(scan_dir, "frames", 0);
    model.scannerConnected(24, 24, 1.0, 1.0);
    model.scan_controls.setSelection(.{ .x = 0.0, .y = 0.0, .w = 24.0, .h = 24.0 });
    try std.testing.expect(model.queueScanStart(null));
    const expected = try film_lut.computeFilmLuts(std.testing.allocator, preview.data, 24, 24, 3, .{ .x = 0, .y = 0, .w = 24, .h = 24 }, .{});

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, preview));
    const lut_path = try std.testing.allocator.dupe(u8, worker.context.?.lut_file_path.?);
    defer std.testing.allocator.free(lut_path);
    try std.testing.expectEqualStrings(worker.context.?.request.request.lut_file_path.?, lut_path);

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, lut_path, std.testing.allocator, .limited(scanner_lut.serialized_len + 1));
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(usize, scanner_lut.serialized_len), data.len);
    try std.testing.expectEqualSlices(u8, &expected.red.?, data[0..256]);
    try std.testing.expectEqualSlices(u8, &expected.green.?, data[256..512]);
    try std.testing.expectEqualSlices(u8, &expected.blue.?, data[512..768]);

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, lut_path, .{}));
    try std.testing.expect(model.scanner_timing_count >= 7);
    try std.testing.expectEqualStrings("native.scan.cleanup", model.scanner_timing_stage);
}

test "scan worker keeps IR-only scans on identity LUT policy" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scan_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(scan_dir);

    var preview = try previewBufferWithFilmLutImage(std.testing.allocator);
    defer preview.deinit(std.testing.allocator);

    var model = ui_state.State.init(scan_dir, "frames", 0);
    model.scannerConnected(24, 24, 1.0, 1.0);
    model.scan_controls.setMode(.ir);
    model.scan_controls.setSelection(.{ .x = 0.0, .y = 0.0, .w = 24.0, .h = 24.0 });
    try std.testing.expect(model.queueScanStart(null));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, preview));
    try std.testing.expect(worker.context.?.lut_file_path == null);
    try std.testing.expect(worker.context.?.request.request.lut_file_path == null);
}

test "scan worker leaves preview command for preview worker" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(0, 0, 2.7, 9.54);
    try std.testing.expect(model.queuePreviewScan("/tmp/v600-native-preview.tiff"));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanSuccess);
    defer worker.deinit();
    try std.testing.expect(!(try worker.startQueued(&model, null)));
    try std.testing.expect(model.pending_command != null);
    switch (model.pending_command.?) {
        .preview_scan => |plan| try std.testing.expectEqualStrings("/tmp/v600-native-preview.tiff", plan.output_path),
        .scan_start => unreachable,
    }
}

test "scan worker writes cancel file and reports cancellation" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cancel_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/native-scan.cancel", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(cancel_path);

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(1000, 500, 10.0, 5.0);
    model.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(model.queueScanStart(cancel_path));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanWaitForCancel);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, null));

    model.requestScannerCancel();
    try worker.requestCancelIfNeeded(&model);
    try std.Io.Dir.cwd().access(std.testing.io, cancel_path, .{});

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(!model.scanner.scanning);
    try std.testing.expectEqualStrings("cancel file observed", model.status);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, cancel_path, .{}));
    try std.testing.expect(model.scanner_timing_count >= 4);
    try std.testing.expectEqualStrings("native.scan.cleanup", model.scanner_timing_stage);
}

test "scan worker drains live backend scan events while running" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cancel_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/native-live-events.cancel", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(cancel_path);

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(1000, 500, 10.0, 5.0);
    model.scan_controls.setDpi(6400);
    model.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(model.queueScanStart(cancel_path));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanEmitLiveEventsWaitForCancel);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, null));

    var observed_live = false;
    for (0..1000) |_| {
        _ = worker.poll(&model);
        if (model.scanner_progress_percent == 82 and
            std.mem.eql(u8, model.scanner.scan_status, "Pass 2/2: Scanning IR at 3200 DPI..."))
        {
            observed_live = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(observed_live);
    try std.testing.expect(model.scanner.scanning);

    model.requestScannerCancel();
    try worker.requestCancelIfNeeded(&model);

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(!model.scanner.scanning);
    try std.testing.expectEqualStrings("cancel file observed", model.status);
    try std.testing.expect(model.scanner_timing_count >= 6);
    try std.testing.expectEqualStrings("native.scan.cleanup", model.scanner_timing_stage);
}

test "scan worker surfaces execution failure to UI state" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(1000, 500, 10.0, 5.0);
    model.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(model.queueScanStart(null));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeScanFailure);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model, null));

    var completed = false;
    for (0..1000) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(!model.scanner.scanning);
    try std.testing.expectEqualStrings("Error: FakeScanFailure", model.status);
    try std.testing.expect(model.scanner_timing_count >= 5);
    try std.testing.expectEqualStrings("native.scan.cleanup", model.scanner_timing_stage);
}
