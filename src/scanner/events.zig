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

pub const Event = union(enum) {
    startup: StartupEvent,
    device_discovery: DeviceDiscoveryEvent,
    probe: ProbeEvent,
    scan_start: ScanStartEvent,
    progress: ProgressEvent,
    scan_complete: ScanCompleteEvent,
    scan_cancelled: ScanFailureEvent,
    scan_error: ScanFailureEvent,
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

    try std.testing.expectEqualStrings(
        \\{"event":"startup","schema":"v600.scanner.event.v1","platform":"linux","backend":"sane"}
        \\{"event":"device-discovery","schema":"v600.scanner.event.v1","discovery_attempted":false,"devices_found":null,"selected_device":"epkowa:interpreter:001:017","selection_source":"cache-hit"}
        \\{"event":"scan-start","schema":"v600.scanner.event.v1","device":"epkowa:interpreter:001:017","output":"/tmp/out.tiff","source":"tpu","kind":"rgb","requested_dpi":400,"effective_dpi":400}
        \\{"event":"progress","schema":"v600.scanner.event.v1","percent":82}
        \\{"event":"scan-complete","schema":"v600.scanner.event.v1","output":"/tmp/out.tiff","metadata":"/tmp/out.tiff.json"}
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
