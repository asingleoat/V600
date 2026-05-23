const std = @import("std");

const scanner_contracts = @import("../scanner/contracts.zig");
const scanner_linux = @import("../scanner/linux.zig");
const ui_state = @import("state.zig");

pub const ExecuteFn = *const fn (*Context) anyerror!void;

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    capabilities: ?scanner_contracts.ScannerCapabilities = null,
    error_detail: ?[]u8 = null,
    done: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    execute: ExecuteFn,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    execute: ExecuteFn = runScannerProbe,
    thread: ?std.Thread = null,
    context: ?*Context = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

    pub fn start(self: *Worker, model: *ui_state.State) !bool {
        if (self.context != null) return false;

        self.done.store(false, .release);
        self.failed.store(false, .release);

        const context = try self.allocator.create(Context);
        errdefer self.allocator.destroy(context);
        context.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .environ_map = self.environ_map,
            .done = &self.done,
            .failed = &self.failed,
            .execute = self.execute,
        };

        model.beginScannerConnect();
        self.thread = try std.Thread.spawn(.{}, threadMain, .{context});
        self.context = context;
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
            model.scannerFailed(context.error_detail orelse "Scanner connection failed");
        } else if (context.capabilities) |caps| {
            model.scannerConnectedWithCapabilities(0, 0, caps);
            model.setStatus("Scanner connected. Ready.");
        } else {
            model.scannerFailed("Scanner connection produced no capabilities");
        }
        self.cleanupContext();
        return true;
    }

    fn cleanupContext(self: *Worker) void {
        if (self.context) |context| {
            if (context.error_detail) |detail| self.allocator.free(detail);
            self.allocator.destroy(context);
            self.context = null;
        }
        self.done.store(false, .release);
        self.failed.store(false, .release);
    }
};

fn threadMain(context: *Context) void {
    context.execute(context) catch |err| {
        if (context.error_detail == null) {
            context.error_detail = std.fmt.allocPrint(context.allocator, "{s}", .{@errorName(err)}) catch null;
        }
        context.failed.store(true, .release);
    };
    context.done.store(true, .release);
}

fn runScannerProbe(context: *Context) !void {
    const runtime = scanner_linux.Runtime{
        .allocator = context.allocator,
        .io = context.io,
        .environ_map = context.environ_map,
    };
    context.capabilities = ui_state.stableScannerCapabilities(try runtime.probe(DiscardOutput{}));
}

pub fn fakeConnectSuccess(context: *Context) !void {
    context.capabilities = .{
        .tpu_width_in = 2.7,
        .tpu_height_in = 9.54,
    };
}

pub fn fakeConnectDelayedSuccess(context: *Context) !void {
    for (0..5000) |_| std.Thread.yield() catch {};
    try fakeConnectSuccess(context);
}

pub fn fakeConnectFailure(context: *Context) !void {
    context.error_detail = try context.allocator.dupe(u8, "backend unavailable");
    return error.FakeConnectFailure;
}

const DiscardOutput = struct {
    pub fn print(_: DiscardOutput, comptime _: []const u8, _: anytype) !void {}
};

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

test "scanner connect worker transitions from connecting to connected" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    defer model.deinit(std.testing.allocator);

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeConnectSuccess);
    defer worker.deinit();

    try std.testing.expect(try worker.start(&model));
    try std.testing.expect(model.scannerStatus().connecting);
    try std.testing.expect(!model.queuePreviewScan("/tmp/v600-native-preview.tiff"));
    try std.testing.expectEqualStrings("Scanner connecting, please wait...", model.scanner.scan_status);

    try waitForPoll(&worker, &model);
    try std.testing.expect(!worker.isRunning());
    try std.testing.expect(model.scannerStatus().connected);
    try std.testing.expectApproxEqAbs(2.7, model.scanner.tpu_width_in, 0.0);
    try std.testing.expectApproxEqAbs(9.54, model.scanner.tpu_height_in, 0.0);
    try std.testing.expectEqualStrings("Scanner connected. Ready.", model.status);
}

test "scanner connect worker transitions from connecting to error" {
    var env = try std.process.Environ.createMap(std.testing.environ, std.testing.allocator);
    defer env.deinit();

    var model = ui_state.State.init("scans", "frames", 0);
    defer model.deinit(std.testing.allocator);

    var worker = Worker.initWithExecutor(std.testing.allocator, std.testing.io, &env, fakeConnectFailure);
    defer worker.deinit();

    try std.testing.expect(try worker.start(&model));
    try std.testing.expect(model.scannerStatus().connecting);

    try waitForPoll(&worker, &model);
    try std.testing.expect(!model.scannerStatus().connected);
    try std.testing.expect(!model.scannerStatus().connecting);
    try std.testing.expectEqualStrings("backend unavailable", model.scanner.scanner_error.?);
    try std.testing.expect(!model.queueScanStart(null));
    try std.testing.expectEqualStrings("backend unavailable", model.scanner.scan_status);
}
