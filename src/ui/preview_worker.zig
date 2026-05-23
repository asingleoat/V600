const std = @import("std");

const scanner_contracts = @import("../scanner/contracts.zig");
const scanner_events = @import("../scanner/events.zig");
const scanner_linux = @import("../scanner/linux.zig");
const tiff = @import("../tiff.zig");
const ui_state = @import("state.zig");

pub const ExecuteFn = *const fn (*Context) anyerror!void;
const test_worker_poll_attempts = 100_000;
const max_preview_timing_events = 32;

pub const PreviewBuffer = struct {
    output_path: []u8,
    width: u32,
    height: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    data: []u8,

    pub fn deinit(self: PreviewBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.output_path);
        allocator.free(self.data);
    }

    pub fn info(self: PreviewBuffer) ui_state.PreviewImageInfo {
        return .{
            .output_path = self.output_path,
            .width = self.width,
            .height = self.height,
            .samples_per_pixel = self.samples_per_pixel,
            .bits_per_sample = self.bits_per_sample,
            .data_len = self.data.len,
        };
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    request: ui_state.PreviewScanPlan,
    output_path: []u8,
    capabilities: ?scanner_contracts.ScannerCapabilities = null,
    preview_buffer: ?PreviewBuffer = null,
    timing_events: [max_preview_timing_events]scanner_events.TimingEvent = undefined,
    timing_len: usize = 0,
    event_sink: ?scanner_events.Sink = null,
    done: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    execute: ExecuteFn,

    fn pushTiming(self: *Context, event: scanner_events.TimingEvent) void {
        scanner_events.emitTiming(event);
        if (self.event_sink) |sink| sink.send(.{ .timing = event });
        if (self.timing_len < self.timing_events.len) {
            self.timing_events[self.timing_len] = event;
            self.timing_len += 1;
        } else {
            self.timing_events[self.timing_events.len - 1] = event;
        }
    }

    fn pushTimingSince(self: *Context, stage: []const u8, start_ns: u64, detail: ?[]const u8) void {
        self.pushTiming(.{
            .stage = stage,
            .elapsed_us = (monotonicNowNs() - start_ns) / std.time.ns_per_us,
            .detail = detail,
        });
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    execute: ExecuteFn = runScannerPreview,
    thread: ?std.Thread = null,
    context: ?*Context = null,
    last_preview: ?PreviewBuffer = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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
        self.clearLastPreview();
        self.cleanupContext();
    }

    pub fn isRunning(self: Worker) bool {
        return self.context != null and !self.done.load(.acquire);
    }

    pub fn startQueued(self: *Worker, model: *ui_state.State) !bool {
        if (self.context != null) return false;
        const command = model.takeCommand() orelse return false;
        switch (command) {
            .preview_scan => |plan| try self.startPreview(plan, model.scanner_capabilities),
            .scan_start => {
                model.pending_command = command;
                return false;
            },
        }
        return true;
    }

    pub fn startPreview(
        self: *Worker,
        plan: ui_state.PreviewScanPlan,
        capabilities: ?scanner_contracts.ScannerCapabilities,
    ) !void {
        if (self.context != null) return error.PreviewWorkerBusy;

        const start_ns = monotonicNowNs();
        self.done.store(false, .release);
        self.failed.store(false, .release);

        const output_path = try self.allocator.dupe(u8, plan.output_path);
        errdefer self.allocator.free(output_path);

        const context = try self.allocator.create(Context);
        errdefer self.allocator.destroy(context);

        var owned_plan = plan;
        owned_plan.output_path = output_path;
        owned_plan.request.output_path = output_path;
        context.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .environ_map = self.environ_map,
            .request = owned_plan,
            .output_path = output_path,
            .capabilities = capabilities,
            .event_sink = self.event_sink,
            .done = &self.done,
            .failed = &self.failed,
            .execute = self.execute,
        };
        context.pushTimingSince("native.preview.start_preview", start_ns, "prepared");

        self.thread = try std.Thread.spawn(.{}, threadMain, .{context});
        self.context = context;
    }

    pub fn poll(self: *Worker, model: *ui_state.State) bool {
        const context = self.context orelse return false;
        if (!context.done.load(.acquire)) return false;

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.applyTimingEvents(model, context);

        if (context.failed.load(.acquire)) {
            const state_start = monotonicNowNs();
            model.applyScannerBackendEvent(.{ .scan_error = .{
                .kind = .backend_failure,
                .detail = "preview scan failed",
            } });
            self.applyTiming(model, .{
                .stage = "native.preview.state_update",
                .elapsed_us = (monotonicNowNs() - state_start) / std.time.ns_per_us,
                .detail = "failed",
            });
        } else if (context.preview_buffer) |preview| {
            const state_start = monotonicNowNs();
            self.clearLastPreview();
            self.last_preview = preview;
            context.preview_buffer = null;
            model.finishPreviewScan(
                context.capabilities orelse scanner_contracts.ScannerCapabilities{},
                self.last_preview.?.info(),
            );
            model.applyPreviewAutoSelect(
                self.allocator,
                self.last_preview.?.data,
                @intCast(self.last_preview.?.width),
                @intCast(self.last_preview.?.height),
                @intCast(self.last_preview.?.samples_per_pixel),
            ) catch {
                model.previewAutoSelectFailed();
            };
            self.applyTiming(model, .{
                .stage = "native.preview.state_update",
                .elapsed_us = (monotonicNowNs() - state_start) / std.time.ns_per_us,
                .detail = "ok",
            });
        } else {
            const state_start = monotonicNowNs();
            model.applyScannerBackendEvent(.{ .scan_error = .{
                .kind = .backend_failure,
                .detail = "preview scan produced no image",
            } });
            self.applyTiming(model, .{
                .stage = "native.preview.state_update",
                .elapsed_us = (monotonicNowNs() - state_start) / std.time.ns_per_us,
                .detail = "missing-image",
            });
        }
        self.cleanupContext();
        return true;
    }

    fn applyTimingEvents(_: *Worker, model: *ui_state.State, context: *const Context) void {
        for (context.timing_events[0..context.timing_len]) |timing| {
            model.applyScannerBackendEvent(.{ .timing = timing });
        }
    }

    fn applyTiming(self: *Worker, model: *ui_state.State, event: scanner_events.TimingEvent) void {
        scanner_events.emitTiming(event);
        if (self.event_sink) |sink| sink.send(.{ .timing = event });
        model.applyScannerBackendEvent(.{ .timing = event });
    }

    fn clearLastPreview(self: *Worker) void {
        if (self.last_preview) |preview| {
            preview.deinit(self.allocator);
            self.last_preview = null;
        }
    }

    fn cleanupContext(self: *Worker) void {
        if (self.context) |context| {
            if (context.preview_buffer) |preview| {
                preview.deinit(self.allocator);
            }
            self.allocator.free(context.output_path);
            self.allocator.destroy(context);
            self.context = null;
        }
        self.done.store(false, .release);
        self.failed.store(false, .release);
    }
};

fn threadMain(context: *Context) void {
    context.execute(context) catch {
        context.failed.store(true, .release);
    };
    context.done.store(true, .release);
}

fn runScannerPreview(context: *Context) !void {
    const total_start = monotonicNowNs();
    var total_detail: []const u8 = "error";
    defer context.pushTimingSince("native.preview.total", total_start, total_detail);

    const runtime = scanner_linux.Runtime{
        .allocator = context.allocator,
        .io = context.io,
        .environ_map = context.environ_map,
        .event_sink = context.event_sink,
    };
    const probe_start = monotonicNowNs();
    const caps = if (context.capabilities) |cached| caps: {
        context.pushTimingSince("native.preview.probe", probe_start, "cached");
        break :caps cached;
    } else caps: {
        const probed = try runtime.probe(DiscardOutput{});
        const stable = ui_state.stableScannerCapabilities(probed);
        context.capabilities = stable;
        context.pushTimingSince("native.preview.probe", probe_start, "ok");
        break :caps stable;
    };
    const request_start = monotonicNowNs();
    var request = context.request.request;
    request.area.width = caps.tpu_width_in;
    request.area.height = caps.tpu_height_in;
    request.output_path = context.output_path;
    context.pushTimingSince("native.preview.request_construct", request_start, "ok");
    const scan_start = monotonicNowNs();
    try runtime.scan(.{
        .request = request,
        .output_path = context.output_path,
        .capabilities = caps,
    });
    context.pushTimingSince("native.preview.scan", scan_start, "ok");
    const load_start = monotonicNowNs();
    var preview = try loadPreviewBuffer(context.allocator, context.output_path);
    errdefer preview.deinit(context.allocator);
    context.pushTimingSince("native.preview.tiff_load", load_start, "ok");
    const downsample_start = monotonicNowNs();
    const downsample_detail: []const u8 = if (request.dpi == effectiveTpuDpi(request.dpi)) "skipped" else "applied";
    preview = try downsamplePreviewIfNeeded(context.allocator, preview, request.dpi, effectiveTpuDpi(request.dpi));
    context.pushTimingSince("native.preview.downsample", downsample_start, downsample_detail);
    context.preview_buffer = preview;
    total_detail = "ok";
}

fn fakePreviewSuccess(context: *Context) !void {
    context.pushTiming(.{
        .stage = "native.preview.fake_executor",
        .elapsed_us = 1,
        .detail = "ok",
    });
    if (context.request.request.dpi != 200) return error.BadDpi;
    if (context.request.request.kind != .rgb) return error.BadKind;
    context.capabilities = .{
        .tpu_width_in = 2.7,
        .tpu_height_in = 9.54,
    };
    context.preview_buffer = try previewBufferFromBytes(
        context.allocator,
        context.output_path,
        2,
        1,
        3,
        8,
        &.{ 0, 32, 64, 96, 128, 255 },
    );
}

fn fakePreviewRequiresCachedCapabilities(context: *Context) !void {
    context.pushTiming(.{
        .stage = "native.preview.fake_cached_capabilities",
        .elapsed_us = 1,
        .detail = "ok",
    });
    const caps = context.capabilities orelse return error.MissingCachedCapabilities;
    if (caps.max_resolution != 3200) return error.BadCachedCapabilities;
    if (caps.tpu_width_in != 3.0 or caps.tpu_height_in != 9.0) return error.BadCachedCapabilities;
    context.preview_buffer = try previewBufferFromBytes(
        context.allocator,
        context.output_path,
        1,
        1,
        3,
        8,
        &.{ 1, 2, 3 },
    );
}

fn fakePreviewFailure(context: *Context) !void {
    context.pushTiming(.{
        .stage = "native.preview.fake_executor",
        .elapsed_us = 1,
        .detail = "failed",
    });
    return error.FakePreviewFailure;
}

const DiscardOutput = struct {
    pub fn print(_: DiscardOutput, comptime _: []const u8, _: anytype) !void {}
};

fn loadPreviewBuffer(allocator: std.mem.Allocator, output_path: []const u8) !PreviewBuffer {
    const image = try tiff.loadRgbPage(allocator, output_path);
    errdefer image.deinit(allocator);
    if (image.samples_per_pixel != 3 or image.bits_per_sample != 8) {
        return error.UnsupportedPreviewImage;
    }
    return .{
        .output_path = try allocator.dupe(u8, output_path),
        .width = image.width,
        .height = image.height,
        .samples_per_pixel = image.samples_per_pixel,
        .bits_per_sample = image.bits_per_sample,
        .data = image.data,
    };
}

fn downsamplePreviewIfNeeded(
    allocator: std.mem.Allocator,
    preview: PreviewBuffer,
    requested_dpi: u32,
    effective_dpi: u32,
) !PreviewBuffer {
    if (requested_dpi == effective_dpi) return preview;
    if (preview.samples_per_pixel != 3 or preview.bits_per_sample != 8) {
        return error.UnsupportedPreviewImage;
    }
    const out_width = scaledDimension(preview.width, requested_dpi, effective_dpi);
    const out_height = scaledDimension(preview.height, requested_dpi, effective_dpi);
    const resized = try resizeLanczosRgb8(
        allocator,
        preview.data,
        preview.width,
        preview.height,
        out_width,
        out_height,
    );
    allocator.free(preview.data);
    return .{
        .output_path = preview.output_path,
        .width = out_width,
        .height = out_height,
        .samples_per_pixel = preview.samples_per_pixel,
        .bits_per_sample = preview.bits_per_sample,
        .data = resized,
    };
}

fn scaledDimension(input: u32, requested_dpi: u32, effective_dpi: u32) u32 {
    const scaled = @as(f64, @floatFromInt(input)) *
        @as(f64, @floatFromInt(requested_dpi)) /
        @as(f64, @floatFromInt(effective_dpi));
    return @max(1, @as(u32, @intFromFloat(@floor(scaled))));
}

fn effectiveTpuDpi(requested_dpi: u32) u32 {
    const valid = [_]u32{ 400, 800, 1600, 3200 };
    var closest = valid[0];
    var closest_delta = absDiff(closest, requested_dpi);
    for (valid[1..]) |dpi| {
        const delta = absDiff(dpi, requested_dpi);
        if (delta < closest_delta) {
            closest = dpi;
            closest_delta = delta;
        }
    }
    return closest;
}

fn resizeLanczosRgb8(
    allocator: std.mem.Allocator,
    input: []const u8,
    width: u32,
    height: u32,
    out_width: u32,
    out_height: u32,
) ![]u8 {
    if (width == 0 or height == 0 or out_width == 0 or out_height == 0) {
        return error.InvalidResizeDimensions;
    }
    const input_len = try std.math.mul(usize, width, try std.math.mul(usize, height, 3));
    if (input.len != input_len) return error.InvalidResizeInput;

    var x_weights = try AxisWeights.init(allocator, width, out_width);
    defer x_weights.deinit(allocator);
    var y_weights = try AxisWeights.init(allocator, height, out_height);
    defer y_weights.deinit(allocator);

    const tmp_len = try std.math.mul(usize, out_width, try std.math.mul(usize, height, 3));
    const tmp = try allocator.alloc(f64, tmp_len);
    defer allocator.free(tmp);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var ox: usize = 0;
        while (ox < out_width) : (ox += 1) {
            for (0..3) |ch| {
                var sum: f64 = 0.0;
                const weights = x_weights.weightsFor(ox);
                var i: usize = 0;
                while (i < weights.len) : (i += 1) {
                    const ix = x_weights.starts[ox] + i;
                    sum += weights[i] * @as(f64, @floatFromInt(input[(y * width + ix) * 3 + ch]));
                }
                tmp[(y * out_width + ox) * 3 + ch] = sum;
            }
        }
    }

    const out_len = try std.math.mul(usize, out_width, try std.math.mul(usize, out_height, 3));
    const output = try allocator.alloc(u8, out_len);
    errdefer allocator.free(output);

    var oy: usize = 0;
    while (oy < out_height) : (oy += 1) {
        var ox: usize = 0;
        while (ox < out_width) : (ox += 1) {
            for (0..3) |ch| {
                var sum: f64 = 0.0;
                const weights = y_weights.weightsFor(oy);
                var i: usize = 0;
                while (i < weights.len) : (i += 1) {
                    const iy = y_weights.starts[oy] + i;
                    sum += weights[i] * tmp[(iy * out_width + ox) * 3 + ch];
                }
                output[(oy * out_width + ox) * 3 + ch] = roundU8(sum);
            }
        }
    }
    return output;
}

const AxisWeights = struct {
    starts: []usize,
    counts: []usize,
    weights: []f64,
    max_taps: usize,

    fn init(allocator: std.mem.Allocator, input_len: u32, output_len: u32) !AxisWeights {
        const scale = @as(f64, @floatFromInt(input_len)) / @as(f64, @floatFromInt(output_len));
        const filter_scale = @max(scale, 1.0);
        const support = 3.0 * filter_scale;
        const max_taps: usize = @intFromFloat(@ceil(support * 2.0) + 1.0);
        const starts = try allocator.alloc(usize, output_len);
        errdefer allocator.free(starts);
        const counts = try allocator.alloc(usize, output_len);
        errdefer allocator.free(counts);
        const weights = try allocator.alloc(f64, @as(usize, output_len) * max_taps);
        errdefer allocator.free(weights);
        @memset(weights, 0.0);

        for (0..output_len) |out_index| {
            const center = (@as(f64, @floatFromInt(out_index)) + 0.5) * scale;
            var start_f = @floor(center - support + 0.5);
            var stop_f = @floor(center + support + 0.5);
            start_f = @max(start_f, 0.0);
            stop_f = @min(stop_f, @as(f64, @floatFromInt(input_len)));
            const start: usize = @intFromFloat(start_f);
            const stop: usize = @intFromFloat(stop_f);
            starts[out_index] = start;
            counts[out_index] = stop - start;

            var total: f64 = 0.0;
            for (start..stop, 0..) |input_index, tap| {
                const x = (@as(f64, @floatFromInt(input_index)) + 0.5 - center) / filter_scale;
                const weight = lanczos(x);
                weights[out_index * max_taps + tap] = weight;
                total += weight;
            }
            if (total != 0.0) {
                for (0..counts[out_index]) |tap| {
                    weights[out_index * max_taps + tap] /= total;
                }
            }
        }

        return .{
            .starts = starts,
            .counts = counts,
            .weights = weights,
            .max_taps = max_taps,
        };
    }

    fn deinit(self: AxisWeights, allocator: std.mem.Allocator) void {
        allocator.free(self.starts);
        allocator.free(self.counts);
        allocator.free(self.weights);
    }

    fn weightsFor(self: AxisWeights, output_index: usize) []const f64 {
        const start = output_index * self.max_taps;
        return self.weights[start .. start + self.counts[output_index]];
    }
};

fn lanczos(x: f64) f64 {
    const ax = @abs(x);
    if (ax < 0.0000001) return 1.0;
    if (ax >= 3.0) return 0.0;
    return sinc(ax) * sinc(ax / 3.0);
}

fn sinc(x: f64) f64 {
    const pix = std.math.pi * x;
    return @sin(pix) / pix;
}

fn roundU8(value: f64) u8 {
    const clamped = @min(255.0, @max(0.0, value));
    return @intFromFloat(@floor(clamped + 0.5));
}

fn absDiff(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn previewBufferFromBytes(
    allocator: std.mem.Allocator,
    output_path: []const u8,
    width: u32,
    height: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    data: []const u8,
) !PreviewBuffer {
    return .{
        .output_path = try allocator.dupe(u8, output_path),
        .width = width,
        .height = height,
        .samples_per_pixel = samples_per_pixel,
        .bits_per_sample = bits_per_sample,
        .data = try allocator.dupe(u8, data),
    };
}

const PreviewDownsampleFixture = struct {
    input_width: u32,
    input_height: u32,
    channels: u16,
    requested_dpi: u32,
    effective_dpi: u32,
    input: []const u8,
    expected_width: u32,
    expected_height: u32,
    expected: []const u8,
    tolerance: u8,
};

fn expectPreviewDownsampleFixture(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(PreviewDownsampleFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const fixture = parsed.value;
    try std.testing.expectEqual(@as(u16, 3), fixture.channels);

    var preview = try previewBufferFromBytes(
        allocator,
        "/tmp/preview.tiff",
        fixture.input_width,
        fixture.input_height,
        fixture.channels,
        8,
        fixture.input,
    );
    preview = try downsamplePreviewIfNeeded(allocator, preview, fixture.requested_dpi, fixture.effective_dpi);
    defer preview.deinit(allocator);

    try std.testing.expectEqual(fixture.expected_width, preview.width);
    try std.testing.expectEqual(fixture.expected_height, preview.height);
    try std.testing.expectEqual(fixture.expected.len, preview.data.len);
    for (fixture.expected, preview.data) |expected, actual| {
        const delta = if (actual > expected) actual - expected else expected - actual;
        try std.testing.expect(delta <= fixture.tolerance);
    }
}

test "preview worker consumes queued command without blocking UI state" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(0, 0, 2.7, 9.54);
    try std.testing.expect(model.queuePreviewScan("/tmp/v600-native-preview.tiff"));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakePreviewSuccess);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model));
    try std.testing.expect(model.pending_command == null);

    var completed = false;
    for (0..test_worker_poll_attempts) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(!worker.isRunning());
    try std.testing.expect(model.preview_ready);
    try std.testing.expect(!model.scanner.scanning);
    try std.testing.expect(worker.last_preview != null);
    try std.testing.expectEqual(@as(usize, 2), model.scanner.preview_width);
    try std.testing.expectEqual(@as(usize, 1), model.scanner.preview_height);
    try std.testing.expectApproxEqAbs(2.7, model.scanner.tpu_width_in, 0.0);
    try std.testing.expectApproxEqAbs(9.54, model.scanner.tpu_height_in, 0.0);
    try std.testing.expectEqual(@as(usize, 6), model.preview_image.?.data_len);
    try std.testing.expect(model.scanner_timing_count >= 3);
    try std.testing.expectEqualStrings("native.preview.state_update", model.scanner_timing_stage);
    try std.testing.expectEqualStrings("ok", model.scanner_timing_detail.?);
}

test "preview worker reuses connected scanner capabilities" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnectedWithCapabilities(0, 0, .{
        .max_resolution = 3200,
        .tpu_width_in = 3.0,
        .tpu_height_in = 9.0,
    });
    try std.testing.expect(model.queuePreviewScan("/tmp/v600-native-preview-cached.tiff"));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakePreviewRequiresCachedCapabilities);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model));

    var completed = false;
    for (0..test_worker_poll_attempts) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(model.preview_ready);
    try std.testing.expect(model.scanner_capabilities != null);
    try std.testing.expectEqual(@as(u32, 3200), model.scanner_capabilities.?.max_resolution);
    try std.testing.expectApproxEqAbs(3.0, model.scanner.tpu_width_in, 0.0);
    try std.testing.expectApproxEqAbs(9.0, model.scanner.tpu_height_in, 0.0);
}

test "preview worker leaves scan-start command for scan worker" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(1000, 500, 10.0, 5.0);
    model.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(model.queueScanStart(".zig-cache/v600-scan.cancel"));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakePreviewSuccess);
    defer worker.deinit();
    try std.testing.expect(!(try worker.startQueued(&model)));
    try std.testing.expect(model.pending_command != null);
    switch (model.pending_command.?) {
        .preview_scan => unreachable,
        .scan_start => |plan| {
            try std.testing.expectEqual(scanner_contracts.ScanKind.rgb_ir, plan.request.kind);
            try std.testing.expectEqualStrings("scans/scan_0001_rgbir_3200dpi.tiff", plan.output_path);
        },
    }
}

test "preview worker surfaces execution failure to UI state" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    model.scannerConnected(0, 0, 2.7, 9.54);
    try std.testing.expect(model.queuePreviewScan("/tmp/v600-native-preview.tiff"));

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakePreviewFailure);
    defer worker.deinit();
    try std.testing.expect(try worker.startQueued(&model));

    var completed = false;
    for (0..test_worker_poll_attempts) |_| {
        if (worker.poll(&model)) {
            completed = true;
            break;
        }
        try std.Thread.yield();
    }
    try std.testing.expect(completed);
    try std.testing.expect(!model.preview_ready);
    try std.testing.expect(!model.scanner.scanning);
    try std.testing.expectEqualStrings("preview scan failed", model.scanner.scan_status);
    try std.testing.expect(model.scanner_timing_count >= 3);
    try std.testing.expectEqualStrings("native.preview.state_update", model.scanner_timing_stage);
    try std.testing.expectEqualStrings("failed", model.scanner_timing_detail.?);
}

test "preview worker downsamples unsupported TPU preview dpi like Python SANE path" {
    try expectPreviewDownsampleFixture("test/fixtures/ui/preview-lanczos-downsample-smoke.json");
}
