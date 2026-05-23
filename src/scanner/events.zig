const std = @import("std");

const contracts = @import("contracts.zig");

pub const schema = "v600.scanner.event.v1";

pub const EventName = enum {
    startup,
    device_discovery,
    probe,
    scan_start,
    progress,
    scan_complete,
    scan_cancelled,
    scan_error,
    timing,
    timing_context,
    timing_status,
};

pub const SelectionSource = enum {
    explicit,
    cache_hit,
    discovered,
    none,
};

pub const FailureKind = enum {
    device_busy,
    no_device,
    permission_denied,
    unsupported_option,
    paper_jam,
    backend_failure,
    cancelled,
    scanimage_failed,
};

pub const StartupEvent = struct {
    platform: []const u8,
    backend: []const u8,
};

pub const DeviceDiscoveryEvent = struct {
    discovery_attempted: bool,
    devices_found: ?usize,
    selected_device: ?[]const u8,
    selection_source: SelectionSource,
};

pub const ProbeEvent = struct {
    device: []const u8,
    model: []const u8,
    max_resolution: u32,
    ir_supported: bool,
};

pub const ScanStartEvent = struct {
    device: []const u8,
    output: []const u8,
    source: contracts.Source,
    kind: contracts.ScanKind,
    requested_dpi: u32,
    effective_dpi: u32,
};

pub const ProgressEvent = struct {
    percent: u8,
};

pub const ScanCompleteEvent = struct {
    output: []const u8,
    metadata: []const u8,
};

pub const ScanFailureEvent = struct {
    kind: FailureKind,
    detail: []const u8,
};

pub const TimingEvent = struct {
    stage: []const u8,
    elapsed_us: u64,
    detail: ?[]const u8 = null,
};

pub const TimingContextEvent = struct {
    command: []const u8,
    output: ?[]const u8 = null,
    device: ?[]const u8 = null,
    source: ?contracts.Source = null,
    kind: ?contracts.ScanKind = null,
    depth: ?contracts.BitDepth = null,
    dpi: ?u32 = null,
};

pub const TimingStatusEvent = struct {
    command: []const u8,
    status: []const u8,
    detail: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

pub const Event = union(enum) {
    startup: StartupEvent,
    device_discovery: DeviceDiscoveryEvent,
    probe: ProbeEvent,
    scan_start: ScanStartEvent,
    progress: ProgressEvent,
    scan_complete: ScanCompleteEvent,
    scan_cancelled: ScanFailureEvent,
    scan_error: ScanFailureEvent,
    timing: TimingEvent,
};

pub const Sink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, Event) void,

    pub fn send(self: Sink, event: Event) void {
        self.emit(self.context, event);
    }
};

pub fn eventName(value: EventName) []const u8 {
    return switch (value) {
        .startup => "startup",
        .device_discovery => "device-discovery",
        .probe => "probe",
        .scan_start => "scan-start",
        .progress => "progress",
        .scan_complete => "scan-complete",
        .scan_cancelled => "scan-cancelled",
        .scan_error => "scan-error",
        .timing => "timing",
        .timing_context => "timing-context",
        .timing_status => "timing-status",
    };
}

pub fn selectionSource(value: SelectionSource) []const u8 {
    return switch (value) {
        .explicit => "explicit",
        .cache_hit => "cache-hit",
        .discovered => "discovered",
        .none => "none",
    };
}

pub fn failureKind(value: FailureKind) []const u8 {
    return switch (value) {
        .device_busy => "device-busy",
        .no_device => "no-device",
        .permission_denied => "permission-denied",
        .unsupported_option => "unsupported-option",
        .paper_jam => "paper-jam",
        .backend_failure => "backend-failure",
        .cancelled => "cancelled",
        .scanimage_failed => "scanimage-failed",
    };
}

pub fn writeStartup(out: anytype, event: StartupEvent) !void {
    try begin(out, .startup);
    try writeStringField(out, "platform", event.platform);
    try writeStringField(out, "backend", event.backend);
    try out.print("}}\n", .{});
}

pub fn writeDeviceDiscovery(out: anytype, event: DeviceDiscoveryEvent) !void {
    try begin(out, .device_discovery);
    try writeBoolField(out, "discovery_attempted", event.discovery_attempted);
    try writeOptionalUsizeField(out, "devices_found", event.devices_found);
    try writeOptionalStringField(out, "selected_device", event.selected_device);
    try writeStringField(out, "selection_source", selectionSource(event.selection_source));
    try out.print("}}\n", .{});
}

pub fn writeProbe(out: anytype, event: ProbeEvent) !void {
    try begin(out, .probe);
    try writeStringField(out, "device", event.device);
    try writeStringField(out, "model", event.model);
    try writeU32Field(out, "max_resolution", event.max_resolution);
    try writeBoolField(out, "ir_supported", event.ir_supported);
    try out.print("}}\n", .{});
}

pub fn writeScanStart(out: anytype, event: ScanStartEvent) !void {
    try begin(out, .scan_start);
    try writeStringField(out, "device", event.device);
    try writeStringField(out, "output", event.output);
    try writeStringField(out, "source", sourceName(event.source));
    try writeStringField(out, "kind", scanKindName(event.kind));
    try writeU32Field(out, "requested_dpi", event.requested_dpi);
    try writeU32Field(out, "effective_dpi", event.effective_dpi);
    try out.print("}}\n", .{});
}

pub fn writeProgress(out: anytype, event: ProgressEvent) !void {
    try begin(out, .progress);
    try writeU8Field(out, "percent", event.percent);
    try out.print("}}\n", .{});
}

pub fn writeScanComplete(out: anytype, event: ScanCompleteEvent) !void {
    try begin(out, .scan_complete);
    try writeStringField(out, "output", event.output);
    try writeStringField(out, "metadata", event.metadata);
    try out.print("}}\n", .{});
}

pub fn writeScanCancelled(out: anytype, event: ScanFailureEvent) !void {
    try begin(out, .scan_cancelled);
    try writeStringField(out, "kind", failureKind(event.kind));
    try writeStringField(out, "detail", event.detail);
    try out.print("}}\n", .{});
}

pub fn writeScanError(out: anytype, event: ScanFailureEvent) !void {
    try begin(out, .scan_error);
    try writeStringField(out, "kind", failureKind(event.kind));
    try writeStringField(out, "detail", event.detail);
    try out.print("}}\n", .{});
}

pub fn writeTiming(out: anytype, event: TimingEvent) !void {
    try begin(out, .timing);
    try writeStringField(out, "stage", event.stage);
    try writeU64Field(out, "elapsed_us", event.elapsed_us);
    try writeOptionalStringField(out, "detail", event.detail);
    try out.print("}}\n", .{});
}

pub fn writeTimingContext(out: anytype, event: TimingContextEvent) !void {
    try begin(out, .timing_context);
    try writeStringField(out, "command", event.command);
    try writeOptionalStringField(out, "output", event.output);
    try writeOptionalStringField(out, "device", event.device);
    try writeOptionalSourceField(out, "source", event.source);
    try writeOptionalKindField(out, "kind", event.kind);
    try writeOptionalDepthField(out, "depth", event.depth);
    try writeOptionalU32Field(out, "dpi", event.dpi);
    try out.print("}}\n", .{});
}

pub fn writeTimingStatus(out: anytype, event: TimingStatusEvent) !void {
    try begin(out, .timing_status);
    try writeStringField(out, "command", event.command);
    try writeStringField(out, "status", event.status);
    try writeOptionalStringField(out, "detail", event.detail);
    try writeOptionalStringField(out, "output", event.output);
    try out.print("}}\n", .{});
}

pub fn writeEvent(out: anytype, event: Event) !void {
    switch (event) {
        .startup => |item| try writeStartup(out, item),
        .device_discovery => |item| try writeDeviceDiscovery(out, item),
        .probe => |item| try writeProbe(out, item),
        .scan_start => |item| try writeScanStart(out, item),
        .progress => |item| try writeProgress(out, item),
        .scan_complete => |item| try writeScanComplete(out, item),
        .scan_cancelled => |item| try writeScanCancelled(out, item),
        .scan_error => |item| try writeScanError(out, item),
        .timing => |item| try writeTiming(out, item),
    }
}

pub fn emitStartup(event: StartupEvent) void {
    var out = DebugWriter{};
    writeStartup(&out, event) catch {};
}

pub fn emitDeviceDiscovery(event: DeviceDiscoveryEvent) void {
    var out = DebugWriter{};
    writeDeviceDiscovery(&out, event) catch {};
}

pub fn emitProbe(event: ProbeEvent) void {
    var out = DebugWriter{};
    writeProbe(&out, event) catch {};
}

pub fn emitScanStart(event: ScanStartEvent) void {
    var out = DebugWriter{};
    writeScanStart(&out, event) catch {};
}

pub fn emitProgress(event: ProgressEvent) void {
    var out = DebugWriter{};
    writeProgress(&out, event) catch {};
}

pub fn emitScanComplete(event: ScanCompleteEvent) void {
    var out = DebugWriter{};
    writeScanComplete(&out, event) catch {};
}

pub fn emitScanCancelled(event: ScanFailureEvent) void {
    var out = DebugWriter{};
    writeScanCancelled(&out, event) catch {};
}

pub fn emitScanError(event: ScanFailureEvent) void {
    var out = DebugWriter{};
    writeScanError(&out, event) catch {};
}

pub fn emitTiming(event: TimingEvent) void {
    var out = DebugWriter{};
    writeTiming(&out, event) catch {};
}

fn begin(out: anytype, name: EventName) !void {
    try out.print("{{\"event\":", .{});
    try writeJsonString(out, eventName(name));
    try out.print(",\"schema\":", .{});
    try writeJsonString(out, schema);
}

fn writeStringField(out: anytype, name: []const u8, value: []const u8) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":", .{});
    try writeJsonString(out, value);
}

fn writeOptionalStringField(out: anytype, name: []const u8, value: ?[]const u8) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":", .{});
    if (value) |string| {
        try writeJsonString(out, string);
    } else {
        try out.print("null", .{});
    }
}

fn writeBoolField(out: anytype, name: []const u8, value: bool) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":{any}", .{value});
}

fn writeU8Field(out: anytype, name: []const u8, value: u8) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":{d}", .{value});
}

fn writeU32Field(out: anytype, name: []const u8, value: u32) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":{d}", .{value});
}

fn writeU64Field(out: anytype, name: []const u8, value: u64) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":{d}", .{value});
}

fn writeOptionalU32Field(out: anytype, name: []const u8, value: ?u32) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":", .{});
    if (value) |number| {
        try out.print("{d}", .{number});
    } else {
        try out.print("null", .{});
    }
}

fn writeOptionalUsizeField(out: anytype, name: []const u8, value: ?usize) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":", .{});
    if (value) |number| {
        try out.print("{d}", .{number});
    } else {
        try out.print("null", .{});
    }
}

fn writeOptionalSourceField(out: anytype, name: []const u8, value: ?contracts.Source) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":", .{});
    if (value) |source| {
        try writeJsonString(out, sourceName(source));
    } else {
        try out.print("null", .{});
    }
}

fn writeOptionalKindField(out: anytype, name: []const u8, value: ?contracts.ScanKind) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":", .{});
    if (value) |kind| {
        try writeJsonString(out, scanKindName(kind));
    } else {
        try out.print("null", .{});
    }
}

fn writeOptionalDepthField(out: anytype, name: []const u8, value: ?contracts.BitDepth) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":", .{});
    if (value) |depth| {
        try out.print("{d}", .{@intFromEnum(depth)});
    } else {
        try out.print("null", .{});
    }
}

fn writeJsonString(out: anytype, value: []const u8) !void {
    try out.print("\"", .{});
    for (value) |byte| {
        switch (byte) {
            '"' => try out.print("\\\"", .{}),
            '\\' => try out.print("\\\\", .{}),
            '\n' => try out.print("\\n", .{}),
            '\r' => try out.print("\\r", .{}),
            '\t' => try out.print("\\t", .{}),
            else => {
                if (byte < 0x20) {
                    try out.print("\\u00{c}{c}", .{ hexDigit(byte >> 4), hexDigit(byte & 0x0f) });
                } else {
                    try out.print("{c}", .{byte});
                }
            },
        }
    }
    try out.print("\"", .{});
}

fn sourceName(source: contracts.Source) []const u8 {
    return switch (source) {
        .flatbed => "flatbed",
        .tpu => "tpu",
    };
}

fn scanKindName(kind: contracts.ScanKind) []const u8 {
    return switch (kind) {
        .rgb => "rgb",
        .gray => "gray",
        .ir => "ir",
        .rgb_ir => "rgb+ir",
    };
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

const DebugWriter = struct {
    pub fn print(_: *DebugWriter, comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(fmt, args);
    }
};

pub const TimingReport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    offset: u64,
    lock: ReportLock = .{},
    failed: bool = false,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !TimingReport {
        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len != 0) try std.Io.Dir.cwd().createDirPath(io, parent);
        }
        var file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .truncate = false,
        });
        const stat = try file.stat(io);
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .offset = stat.size,
        };
    }

    pub fn deinit(self: *TimingReport) void {
        self.file.close(self.io);
    }

    pub fn sink(self: *TimingReport) Sink {
        return .{
            .context = self,
            .emit = emitReportSink,
        };
    }

    pub fn writeContext(self: *TimingReport, event: TimingContextEvent) !void {
        self.lock.lock();
        defer self.lock.unlock();
        var out = TimingReportWriter{ .report = self };
        try writeTimingContext(&out, event);
    }

    pub fn writeStatus(self: *TimingReport, event: TimingStatusEvent) !void {
        self.lock.lock();
        defer self.lock.unlock();
        var out = TimingReportWriter{ .report = self };
        try writeTimingStatus(&out, event);
    }

    fn writeSinkEvent(self: *TimingReport, event: Event) void {
        self.lock.lock();
        defer self.lock.unlock();
        var out = TimingReportWriter{ .report = self };
        writeEvent(&out, event) catch {
            self.failed = true;
        };
    }

    fn appendBytes(self: *TimingReport, bytes: []const u8) !void {
        try self.file.writePositionalAll(self.io, bytes, self.offset);
        self.offset += bytes.len;
    }
};

const ReportLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *ReportLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *ReportLock) void {
        self.locked.store(false, .release);
    }
};

fn emitReportSink(raw_context: *anyopaque, event: Event) void {
    const report: *TimingReport = @ptrCast(@alignCast(raw_context));
    report.writeSinkEvent(event);
}

const TimingReportWriter = struct {
    report: *TimingReport,

    pub fn print(self: *TimingReportWriter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.report.allocator, fmt, args);
        defer self.report.allocator.free(text);
        try self.report.appendBytes(text);
    }
};

const CaptureWriter = struct {
    allocator: std.mem.Allocator,
    bytes: std.array_list.Managed(u8),

    fn init(allocator: std.mem.Allocator) CaptureWriter {
        return .{
            .allocator = allocator,
            .bytes = std.array_list.Managed(u8).init(allocator),
        };
    }

    fn deinit(self: *CaptureWriter) void {
        self.bytes.deinit();
    }

    pub fn print(self: *CaptureWriter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        try self.bytes.appendSlice(text);
    }
};

test "scanner JSON event names are stable" {
    try std.testing.expectEqualStrings("startup", eventName(.startup));
    try std.testing.expectEqualStrings("device-discovery", eventName(.device_discovery));
    try std.testing.expectEqualStrings("probe", eventName(.probe));
    try std.testing.expectEqualStrings("scan-start", eventName(.scan_start));
    try std.testing.expectEqualStrings("progress", eventName(.progress));
    try std.testing.expectEqualStrings("scan-complete", eventName(.scan_complete));
    try std.testing.expectEqualStrings("scan-cancelled", eventName(.scan_cancelled));
    try std.testing.expectEqualStrings("scan-error", eventName(.scan_error));
    try std.testing.expectEqualStrings("timing", eventName(.timing));
    try std.testing.expectEqualStrings("timing-context", eventName(.timing_context));
    try std.testing.expectEqualStrings("timing-status", eventName(.timing_status));
}

test "scanner JSON failure kind names are stable" {
    try std.testing.expectEqualStrings("device-busy", failureKind(.device_busy));
    try std.testing.expectEqualStrings("no-device", failureKind(.no_device));
    try std.testing.expectEqualStrings("permission-denied", failureKind(.permission_denied));
    try std.testing.expectEqualStrings("unsupported-option", failureKind(.unsupported_option));
    try std.testing.expectEqualStrings("paper-jam", failureKind(.paper_jam));
    try std.testing.expectEqualStrings("backend-failure", failureKind(.backend_failure));
    try std.testing.expectEqualStrings("cancelled", failureKind(.cancelled));
    try std.testing.expectEqualStrings("scanimage-failed", failureKind(.scanimage_failed));
}

test "scanner JSON events render stable field names" {
    var out = CaptureWriter.init(std.testing.allocator);
    defer out.deinit();

    try writeStartup(&out, .{ .platform = "linux", .backend = "sane" });
    try writeDeviceDiscovery(&out, .{
        .discovery_attempted = false,
        .devices_found = null,
        .selected_device = "epkowa:interpreter:001:017",
        .selection_source = .cache_hit,
    });
    try writeScanStart(&out, .{
        .device = "epkowa:interpreter:001:017",
        .output = "/tmp/out.tiff",
        .source = .tpu,
        .kind = .rgb,
        .requested_dpi = 400,
        .effective_dpi = 400,
    });
    try writeProgress(&out, .{ .percent = 82 });
    try writeScanComplete(&out, .{
        .output = "/tmp/out.tiff",
        .metadata = "/tmp/out.tiff.json",
    });
    try writeTiming(&out, .{
        .stage = "scanimage.wait",
        .elapsed_us = 125000,
        .detail = "rgb pass",
    });

    try std.testing.expectEqualStrings(
        \\{"event":"startup","schema":"v600.scanner.event.v1","platform":"linux","backend":"sane"}
        \\{"event":"device-discovery","schema":"v600.scanner.event.v1","discovery_attempted":false,"devices_found":null,"selected_device":"epkowa:interpreter:001:017","selection_source":"cache-hit"}
        \\{"event":"scan-start","schema":"v600.scanner.event.v1","device":"epkowa:interpreter:001:017","output":"/tmp/out.tiff","source":"tpu","kind":"rgb","requested_dpi":400,"effective_dpi":400}
        \\{"event":"progress","schema":"v600.scanner.event.v1","percent":82}
        \\{"event":"scan-complete","schema":"v600.scanner.event.v1","output":"/tmp/out.tiff","metadata":"/tmp/out.tiff.json"}
        \\{"event":"timing","schema":"v600.scanner.event.v1","stage":"scanimage.wait","elapsed_us":125000,"detail":"rgb pass"}
        \\
    , out.bytes.items);
}

test "scanner JSON events escape string fields" {
    var out = CaptureWriter.init(std.testing.allocator);
    defer out.deinit();

    try writeScanError(&out, .{
        .kind = .scanimage_failed,
        .detail = "quote \" slash \\ newline\n",
    });

    try std.testing.expectEqualStrings(
        \\{"event":"scan-error","schema":"v600.scanner.event.v1","kind":"scanimage-failed","detail":"quote \" slash \\ newline\n"}
        \\
    , out.bytes.items);
}

test "scanner timing event detail can be null or escaped" {
    var out = CaptureWriter.init(std.testing.allocator);
    defer out.deinit();

    try writeTiming(&out, .{
        .stage = "probe.help",
        .elapsed_us = 42,
    });
    try writeTiming(&out, .{
        .stage = "worker\nstate",
        .elapsed_us = 7,
        .detail = "quote \" slash \\",
    });

    try std.testing.expectEqualStrings(
        \\{"event":"timing","schema":"v600.scanner.event.v1","stage":"probe.help","elapsed_us":42,"detail":null}
        \\{"event":"timing","schema":"v600.scanner.event.v1","stage":"worker\nstate","elapsed_us":7,"detail":"quote \" slash \\"}
        \\
    , out.bytes.items);
}

test "scanner timing report context and status serialize as JSONL" {
    var out = CaptureWriter.init(std.testing.allocator);
    defer out.deinit();

    try writeTimingContext(&out, .{
        .command = "scanner scan",
        .output = "/tmp/out.tiff",
        .device = "epkowa:interpreter:001:017",
        .source = .tpu,
        .kind = .rgb_ir,
        .depth = .sixteen,
        .dpi = 800,
    });
    try writeTimingStatus(&out, .{
        .command = "scanner scan",
        .status = "error",
        .detail = "scanimage failed",
        .output = "/tmp/out.tiff",
    });

    try std.testing.expectEqualStrings(
        \\{"event":"timing-context","schema":"v600.scanner.event.v1","command":"scanner scan","output":"/tmp/out.tiff","device":"epkowa:interpreter:001:017","source":"tpu","kind":"rgb+ir","depth":16,"dpi":800}
        \\{"event":"timing-status","schema":"v600.scanner.event.v1","command":"scanner scan","status":"error","detail":"scanimage failed","output":"/tmp/out.tiff"}
        \\
    , out.bytes.items);
}

test "scanner timing report appends context events and sink events to file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDirPath(allocator, tmp, "scanner-timing.jsonl");
    defer allocator.free(path);

    {
        var report = try TimingReport.open(allocator, std.testing.io, path);
        defer report.deinit();
        try report.writeContext(.{
            .command = "scanner probe",
            .output = null,
        });
        const sink = report.sink();
        sink.send(.{ .timing = .{
            .stage = "probe.help",
            .elapsed_us = 55,
            .detail = "ok",
        } });
        try report.writeStatus(.{
            .command = "scanner probe",
            .status = "ok",
        });
    }

    {
        var report = try TimingReport.open(allocator, std.testing.io, path);
        defer report.deinit();
        try report.writeStatus(.{
            .command = "scanner probe",
            .status = "ok",
            .detail = "second-run",
        });
    }

    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(4096));
    defer allocator.free(text);
    try std.testing.expectEqualStrings(
        \\{"event":"timing-context","schema":"v600.scanner.event.v1","command":"scanner probe","output":null,"device":null,"source":null,"kind":null,"depth":null,"dpi":null}
        \\{"event":"timing","schema":"v600.scanner.event.v1","stage":"probe.help","elapsed_us":55,"detail":"ok"}
        \\{"event":"timing-status","schema":"v600.scanner.event.v1","command":"scanner probe","status":"ok","detail":null,"output":null}
        \\{"event":"timing-status","schema":"v600.scanner.event.v1","command":"scanner probe","status":"ok","detail":"second-run","output":null}
        \\
    , text);
}

const SinkCapture = struct {
    count: usize = 0,
    last: Event = .{ .startup = .{ .platform = "", .backend = "" } },
};

fn captureSinkEvent(raw_context: *anyopaque, event: Event) void {
    const capture: *SinkCapture = @ptrCast(@alignCast(raw_context));
    capture.count += 1;
    capture.last = event;
}

test "scanner event sink forwards timing events" {
    var capture = SinkCapture{};
    const sink = Sink{
        .context = &capture,
        .emit = captureSinkEvent,
    };

    sink.send(.{ .timing = .{
        .stage = "native.preview.load",
        .elapsed_us = 3300,
        .detail = "preview worker",
    } });

    try std.testing.expectEqual(@as(usize, 1), capture.count);
    switch (capture.last) {
        .timing => |timing| {
            try std.testing.expectEqualStrings("native.preview.load", timing.stage);
            try std.testing.expectEqual(@as(u64, 3300), timing.elapsed_us);
            try std.testing.expectEqualStrings("preview worker", timing.detail.?);
        },
        else => return error.ExpectedTimingEvent,
    }
}

fn tmpDirPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}
