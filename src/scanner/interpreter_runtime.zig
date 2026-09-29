//! macOS scanner runtime. Drives the scanner through Epson's Interpreter
//! bundle over libusb, following the Python driver (`scanner.py`): reset,
//! optional IR challenge, FS W parameters, TPU calibration with gamma LUTs,
//! FS G, block reads, horizontal mirroring for the transparency unit, and a
//! TIFF written in-process.
//!
//! Opening a connection uploads firmware (about 10 s), so one connection is
//! shared by every runtime in the process and reopened only after a failure
//! or a cancelled scan.

const std = @import("std");

const contracts = @import("contracts.zig");
const events = @import("events.zig");
const interpreter = @import("interpreter.zig");
const linux = @import("linux.zig");
const lut = @import("lut.zig");
const macos = @import("macos.zig");
const sane = @import("sane.zig");
const tiff = @import("../tiff.zig");
const usb = @import("usb.zig");

pub const Device = linux.Device;
pub const ScanOptions = linux.ScanOptions;
pub const UsbResetOutcome = linux.UsbResetOutcome;
pub const freeDevices = linux.freeDevices;

pub const platform_name = "macos";
pub const backend_name = "interpreter";
pub const tiff_software = "epdaughter";
pub const device_name = "epson-interpreter";

const thumbnail_max_height: u32 = 256;

const Hardware = struct {
    device: usb.Device,
    library: macos.LoadedInterpreter,
};

const Connection = struct {
    /// The claimed USB device and loaded bundle; null when tests drive the
    /// runtime through fakes.
    hardware: ?Hardware,
    usb_io: macos.UsbIo,
    session: macos.InterpreterSession,
    model: macos.ScannerModelSelection,
    tpu_configured: bool = false,
    uploaded_luts: ?[lut.serialized_len]u8 = null,
    needs_reinit: bool = false,

    fn modelName(self: *const Connection) []const u8 {
        return switch (self.model) {
            .known => |model| model.name,
            .unknown => "Epson Scanner",
        };
    }
};

var connection_mutex: std.Io.Mutex = .init;
var shared_connection: ?*Connection = null;

const Pass = struct {
    image: tiff.ImageView,
    data: []u8,
    effective_dpi: u32,

    fn deinit(self: Pass, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    /// Unused here; kept so callers can build either host runtime alike.
    scanimage_command: ?[]const u8 = null,
    event_sink: ?events.Sink = null,

    pub fn close(_: Runtime) void {}

    pub fn discoverDevices(self: Runtime) ![]Device {
        const found = usb.listScanners(self.allocator) catch |err| {
            self.emitDeviceDiscovery(.{ .discovery_attempted = true, .devices_found = 0, .selected_device = null, .selection_source = .none });
            return err;
        };
        defer self.allocator.free(found);

        var devices = std.array_list.Managed(Device).init(self.allocator);
        errdefer {
            for (devices.items) |device| freeDeviceFields(self.allocator, device);
            devices.deinit();
        }
        for (found) |entry| {
            const device = try self.describeDevice(entry);
            devices.append(device) catch |err| {
                freeDeviceFields(self.allocator, device);
                return err;
            };
        }
        self.emitDeviceDiscovery(.{
            .discovery_attempted = true,
            .devices_found = devices.items.len,
            .selected_device = if (devices.items.len != 0) devices.items[0].name else null,
            .selection_source = if (devices.items.len != 0) .discovered else .none,
        });
        return devices.toOwnedSlice();
    }

    fn describeDevice(self: Runtime, entry: usb.Found) !Device {
        const model_name = switch (macos.scannerModelForProductId(entry.product_id)) {
            .known => |known| known.name,
            .unknown => "Unknown Epson scanner",
        };
        const name = try std.fmt.allocPrint(self.allocator, "{s}:usb:{d:0>3}:{d:0>3}", .{ device_name, entry.bus, entry.address });
        errdefer self.allocator.free(name);
        const vendor = try self.allocator.dupe(u8, "Epson");
        errdefer self.allocator.free(vendor);
        const model = try self.allocator.dupe(u8, model_name);
        errdefer self.allocator.free(model);
        const kind = try self.allocator.dupe(u8, "film scanner");
        errdefer self.allocator.free(kind);
        const raw_line = try std.fmt.allocPrint(self.allocator, "device `{s}' is an Epson {s} (usb 04b8:{x:0>4})", .{ name, model_name, entry.product_id });
        return .{ .name = name, .vendor = vendor, .model = model, .kind = kind, .raw_line = raw_line };
    }

    pub fn probe(self: Runtime, out: anytype) !contracts.ScannerCapabilities {
        self.emitStartup(.{ .platform = platform_name, .backend = backend_name });
        const conn = try self.acquire();
        var ok = false;
        defer self.release(ok);

        const caps = try capabilities(conn);
        self.emitProbe(.{
            .device = caps.device_name,
            .model = caps.model,
            .max_resolution = caps.max_resolution,
            .ir_supported = caps.ir_supported,
        });
        try out.print("device: {s}\n", .{caps.device_name});
        try out.print("model: {s}\n", .{caps.model});
        try out.print("flatbed: {d:.3}in x {d:.3}in\n", .{ caps.flatbed_width_in, caps.flatbed_height_in });
        try out.print("tpu: {d:.3}in x {d:.3}in\n", .{ caps.tpu_width_in, caps.tpu_height_in });
        try out.print("max_resolution: {d}\n", .{caps.max_resolution});
        try out.print("ir_supported: {any}\n", .{caps.ir_supported});
        ok = true;
        return caps;
    }

    pub fn usbReset(_: Runtime) !UsbResetOutcome {
        return error.UnsupportedPlatform;
    }

    pub fn scan(self: Runtime, options: ScanOptions) !void {
        self.emitStartup(.{ .platform = platform_name, .backend = backend_name });
        if (options.output_path.len == 0) {
            self.emitScanError(.{ .kind = .backend_failure, .detail = "missing output path" });
            return error.MissingOutputPath;
        }

        const conn = self.acquire() catch |err| {
            self.emitScanError(.{ .kind = failureKind(err), .detail = @errorName(err) });
            return err;
        };
        var ok = false;
        defer self.release(ok);

        self.scanWithConnection(conn, options) catch |err| {
            if (err == error.ScanCancelled) {
                self.emitScanCancelled(.{ .kind = .cancelled, .detail = "cancel file observed" });
            } else {
                self.emitScanError(.{ .kind = failureKind(err), .detail = @errorName(err) });
            }
            return err;
        };
        ok = true;
    }

    fn scanWithConnection(self: Runtime, conn: *Connection, options: ScanOptions) !void {
        const caps = try capabilities(conn);
        var luts_buffer: [lut.serialized_len]u8 = undefined;
        const luts = try self.loadLuts(options.request, &luts_buffer);

        if (options.request.kind == .rgb_ir) {
            var rgb_request = options.request;
            rgb_request.kind = .rgb;
            rgb_request.depth = .sixteen;
            const rgb = try self.scanPass(conn, caps, rgb_request, options, luts);
            defer rgb.deinit(self.allocator);

            var ir_request = options.request;
            ir_request.kind = .ir;
            ir_request.depth = .eight;
            ir_request.source = .tpu;
            ir_request.dpi = @min(options.request.dpi, 3200);
            const ir = try self.scanPass(conn, caps, ir_request, options, luts);
            defer ir.deinit(self.allocator);

            const thumbnail = try makeThumbnail(self.allocator, rgb.image);
            defer self.allocator.free(thumbnail.data);

            try tiff.writeScanPages(self.allocator, options.output_path, &.{
                .{ .image = rgb.image, .metadata = self.pageMetadata(conn, rgb.effective_dpi, luts != null) },
                .{ .image = thumbnail },
                .{ .image = ir.image, .metadata = self.pageMetadata(conn, ir.effective_dpi, false) },
            });
            const metadata_path = try self.writeSidecar(conn, options, rgb.effective_dpi, ir.effective_dpi, luts != null);
            defer self.allocator.free(metadata_path);
            self.emitScanComplete(.{ .output = options.output_path, .metadata = metadata_path });
            return;
        }

        const pass = try self.scanPass(conn, caps, options.request, options, luts);
        defer pass.deinit(self.allocator);
        const luts_applied = luts != null and options.request.kind == .rgb;
        try tiff.writeScanPages(self.allocator, options.output_path, &.{
            .{ .image = pass.image, .metadata = self.pageMetadata(conn, pass.effective_dpi, luts_applied) },
        });
        const metadata_path = try self.writeSidecar(conn, options, pass.effective_dpi, null, luts_applied);
        defer self.allocator.free(metadata_path);
        self.emitScanComplete(.{ .output = options.output_path, .metadata = metadata_path });
    }

    /// One scanner pass, ported from Python `EpsonScanner.scan`.
    fn scanPass(
        self: Runtime,
        conn: *Connection,
        caps: contracts.ScannerCapabilities,
        request: contracts.ScanRequest,
        options: ScanOptions,
        luts: ?*const [lut.serialized_len]u8,
    ) !Pass {
        var planned = request;
        // Snap to the same resolutions as the Linux backend, so previews and
        // scans come out at the DPI the UI expects on either host.
        planned.dpi = sane.effectiveDpiForRequest(request);
        planned.area = clampArea(request.area, request.source, caps);
        // Python always scanned IR at 8 bits.
        if (request.kind == .ir) planned.depth = .eight;
        const plan = try macos.planScan(planned, caps);
        if (plan.out_width == 0 or plan.out_height == 0) return error.EmptyScanArea;

        self.emitScanStart(.{
            .device = caps.device_name,
            .output = options.output_path,
            .source = request.source,
            .kind = request.kind,
            .requested_dpi = request.dpi,
            .effective_dpi = plan.effective_dpi,
        });

        const session = &conn.session;
        if (!macos.reset(session)) return error.ScannerResetFailed;
        if (request.kind == .ir) {
            // Python only warned here and carried on.
            if (!macos.enableInfrared(session)) self.emitTiming(.{ .stage = "macos.scan.enable_ir", .elapsed_us = 0, .detail = "failed" });
        }
        if (!macos.setScanningParameters(session, plan.params)) return error.ScanParametersRejected;

        if (request.source == .tpu or request.kind == .ir) {
            const wanted: ?[lut.serialized_len]u8 = if (request.kind == .rgb and luts != null) luts.?.* else null;
            if (!conn.tpu_configured or !sameLuts(conn.uploaded_luts, wanted)) {
                conn.uploaded_luts = wanted;
                try macos.configureTpu(conn.usb_io, gammaTables(&conn.uploaded_luts));
                conn.tpu_configured = true;
                // The direct RS commands desync the interpreter's USB state.
                conn.needs_reinit = true;
            }
        }

        const info = macos.startExtendedScan(session) orelse return error.ScanStartFailed;
        const expected: usize = @intCast(plan.expected_size);
        const data = try self.readBlocks(session, info, expected, options.cancel_file);
        errdefer self.allocator.free(data);

        if (conn.needs_reinit) {
            conn.needs_reinit = false;
            session.reinit() catch return error.InterpreterReinitFailed;
        }

        const bytes_per_sample: u16 = if (planned.depth == .sixteen) 2 else 1;
        const image = tiff.ImageView{
            .width = plan.out_width,
            .height = plan.out_height,
            .samples_per_pixel = plan.channels,
            .bits_per_sample = bytes_per_sample * 8,
            .data = data,
        };
        // Film lies emulsion-down on the glass, so transparency-unit scans
        // come out left-right reversed.
        if (request.source == .tpu or request.kind == .ir) mirrorRows(data, plan.out_width, plan.bytes_per_pixel);
        return .{ .image = image, .data = data, .effective_dpi = plan.effective_dpi };
    }

    fn readBlocks(
        self: Runtime,
        session: *macos.InterpreterSession,
        info: interpreter.StartScanInfo,
        expected: usize,
        cancel_file: ?[]const u8,
    ) ![]u8 {
        const total_blocks = try std.math.add(u32, info.block_count, if (info.last_block_size != 0) 1 else 0);
        const delivered = @as(usize, info.block_size) * info.block_count + info.last_block_size;
        if (delivered < expected) return error.ScanDataShort;

        // One spare byte: each block is followed by a status byte, which the
        // next block then overwrites.
        const buffer = try self.allocator.alloc(u8, delivered + 1);
        errdefer self.allocator.free(buffer);

        var offset: usize = 0;
        var last_percent: u8 = 255;
        var block: u32 = 0;
        while (block < total_blocks) : (block += 1) {
            const is_last = block + 1 == total_blocks;
            const size: usize = if (is_last and info.last_block_size != 0) info.last_block_size else info.block_size;
            session.read(buffer[offset .. offset + size + 1]) catch return error.ScanReadFailed;
            const status = buffer[offset + size];
            offset += size;

            if ((status & 0x80) != 0) return error.ScannerFatalError;
            if ((status & 0x20) != 0) return error.ScanCancelled;
            if (cancel_file) |path| {
                if (linux.cancelFileExists(self.io, path)) {
                    _ = macos.writeCommand(session, &interpreter.cancelCommand());
                    return error.ScanCancelled;
                }
            }
            if (!is_last) _ = macos.writeCommand(session, &interpreter.ackCommand());

            const percent: u8 = @intCast(@min(100, offset * 100 / @max(expected, 1)));
            if (percent != last_percent) {
                last_percent = percent;
                self.emitProgress(.{ .percent = percent });
            }
        }
        if (offset < expected) return error.ScanDataShort;
        if (self.allocator.resize(buffer, expected)) return buffer[0..expected];
        const data = try self.allocator.dupe(u8, buffer[0..expected]);
        self.allocator.free(buffer);
        return data;
    }

    fn loadLuts(self: Runtime, request: contracts.ScanRequest, buffer: *[lut.serialized_len]u8) !?*const [lut.serialized_len]u8 {
        if (request.kind != .rgb and request.kind != .rgb_ir) return null;
        const path = request.lut_file_path orelse return null;
        const data = try std.Io.Dir.cwd().readFile(self.io, path, buffer);
        if (data.len != lut.serialized_len) return error.InvalidLutFile;
        return buffer;
    }

    fn pageMetadata(_: Runtime, conn: *const Connection, dpi: u32, luts_applied: bool) tiff.ScannerMetadata {
        return .{
            .model = conn.modelName(),
            .software = tiff_software,
            .dpi = dpi,
            .custom_luts_applied = luts_applied,
        };
    }

    fn writeSidecar(
        self: Runtime,
        conn: *const Connection,
        options: ScanOptions,
        dpi: u32,
        ir_dpi: ?u32,
        luts_applied: bool,
    ) ![]u8 {
        const metadata_path = if (options.metadata_path) |path|
            try self.allocator.dupe(u8, path)
        else
            try std.fmt.allocPrint(self.allocator, "{s}.json", .{options.output_path});
        errdefer self.allocator.free(metadata_path);

        var file = try std.Io.Dir.cwd().createFile(self.io, metadata_path, .{ .truncate = true });
        defer file.close(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(self.io, &buffer);
        const out = &writer.interface;

        const kind_name = if (options.request.kind == .rgb_ir) "rgb+ir" else @tagName(options.request.kind);
        try out.print(
            \\{{
            \\  "software": "v600-zig",
            \\  "backend": "{s}",
            \\  "device": "{s}",
            \\  "model": "{s}",
            \\  "source": "{t}",
            \\  "kind": "{s}",
            \\  "requested_dpi": {d},
            \\  "effective_dpi": {d},
            \\
        , .{
            backend_name,
            device_name,
            conn.modelName(),
            options.request.source,
            kind_name,
            options.request.dpi,
            dpi,
        });
        if (ir_dpi) |value| {
            try out.print("  \"rgb_effective_dpi\": {d},\n  \"ir_effective_dpi\": {d},\n", .{ dpi, value });
        }
        const depth: u8 = if (options.request.kind == .rgb_ir) 16 else @intFromEnum(options.request.depth);
        try out.print(
            \\  "depth": {d},
            \\  "output": "{s}",
            \\  "custom_luts_applied": {any},
            \\  "tiff_metadata": {{
            \\    "make": "EPSON",
            \\    "model": "{s}",
            \\    "software": "{s}"
            \\  }}
        , .{ depth, options.output_path, luts_applied, conn.modelName(), tiff_software });
        if (ir_dpi != null) {
            try out.print(
                \\,
                \\  "pages": [
                \\    {{"index": 0, "kind": "rgb"}},
                \\    {{"index": 1, "kind": "thumbnail"}},
                \\    {{"index": 2, "kind": "ir"}}
                \\  ]
            , .{});
        }
        try out.print("\n}}\n", .{});
        try out.flush();
        return metadata_path;
    }

    fn acquire(self: Runtime) !*Connection {
        connection_mutex.lockUncancelable(self.io);
        errdefer connection_mutex.unlock(self.io);
        if (shared_connection) |conn| return conn;
        const conn = try self.openConnection();
        shared_connection = conn;
        return conn;
    }

    /// Unlocks the shared connection; after a failure it is closed so the
    /// next operation starts from a fresh USB claim and interpreter init.
    fn release(self: Runtime, ok: bool) void {
        if (!ok) {
            if (shared_connection) |conn| closeConnection(conn);
            shared_connection = null;
        }
        connection_mutex.unlock(self.io);
    }

    fn openConnection(self: Runtime) !*Connection {
        const conn = try std.heap.page_allocator.create(Connection);
        errdefer std.heap.page_allocator.destroy(conn);

        const open_start = monotonicNowNs();
        conn.hardware = .{ .device = try usb.Device.open(null), .library = undefined };
        const hardware = &conn.hardware.?;
        errdefer hardware.device.close();
        conn.model = macos.scannerModelForProductId(hardware.device.product_id);
        self.emitTimingSince("macos.open.usb", open_start, "ok");

        const path = try macos.findInterpreter(self.allocator, self.io, ".", conn.model.interpId()) orelse
            return error.InterpreterNotInstalled;
        defer self.allocator.free(path);
        hardware.library = try macos.LoadedInterpreter.open(path);
        errdefer hardware.library.close();

        conn.usb_io = hardware.device.io();
        conn.session = .{
            .api = hardware.library.api(),
            .callback_context = .{ .usb = conn.usb_io },
            .detached = true,
        };
        conn.tpu_configured = false;
        conn.uploaded_luts = null;
        conn.needs_reinit = false;

        const init_start = monotonicNowNs();
        conn.session.init() catch |err| {
            var detail_buffer: [64]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buffer, "usb={d} interpreter={d}", .{
                conn.session.usbError(),
                conn.session.interpreterError(),
            }) catch "init failed";
            self.emitTimingSince("macos.open.interpreter_init", init_start, detail);
            return err;
        };
        self.emitTimingSince("macos.open.interpreter_init", init_start, "ok");
        return conn;
    }

    fn emitStartup(self: Runtime, event: events.StartupEvent) void {
        events.emitStartup(event);
        if (self.event_sink) |sink| sink.send(.{ .startup = event });
    }

    fn emitDeviceDiscovery(self: Runtime, event: events.DeviceDiscoveryEvent) void {
        events.emitDeviceDiscovery(event);
        if (self.event_sink) |sink| sink.send(.{ .device_discovery = event });
    }

    fn emitProbe(self: Runtime, event: events.ProbeEvent) void {
        events.emitProbe(event);
        if (self.event_sink) |sink| sink.send(.{ .probe = event });
    }

    fn emitScanStart(self: Runtime, event: events.ScanStartEvent) void {
        events.emitScanStart(event);
        if (self.event_sink) |sink| sink.send(.{ .scan_start = event });
    }

    fn emitProgress(self: Runtime, event: events.ProgressEvent) void {
        events.emitProgress(event);
        if (self.event_sink) |sink| sink.send(.{ .progress = event });
    }

    fn emitScanComplete(self: Runtime, event: events.ScanCompleteEvent) void {
        events.emitScanComplete(event);
        if (self.event_sink) |sink| sink.send(.{ .scan_complete = event });
    }

    fn emitScanCancelled(self: Runtime, event: events.ScanFailureEvent) void {
        events.emitScanCancelled(event);
        if (self.event_sink) |sink| sink.send(.{ .scan_cancelled = event });
    }

    fn emitScanError(self: Runtime, event: events.ScanFailureEvent) void {
        events.emitScanError(event);
        if (self.event_sink) |sink| sink.send(.{ .scan_error = event });
    }

    fn emitTiming(self: Runtime, event: events.TimingEvent) void {
        events.emitTiming(event);
        if (self.event_sink) |sink| sink.send(.{ .timing = event });
    }

    fn emitTimingSince(self: Runtime, stage: []const u8, start_ns: u64, detail: ?[]const u8) void {
        self.emitTiming(.{
            .stage = stage,
            .elapsed_us = (monotonicNowNs() - start_ns) / std.time.ns_per_us,
            .detail = detail,
        });
    }
};

fn freeDeviceFields(allocator: std.mem.Allocator, device: Device) void {
    allocator.free(device.name);
    allocator.free(device.vendor);
    allocator.free(device.model);
    allocator.free(device.kind);
    allocator.free(device.raw_line);
}

fn closeConnection(conn: *Connection) void {
    conn.session.close();
    if (conn.hardware) |*hardware| {
        hardware.library.close();
        hardware.device.close();
    }
    std.heap.page_allocator.destroy(conn);
}

fn capabilities(conn: *Connection) !contracts.ScannerCapabilities {
    const identity = macos.getExtendedIdentity(&conn.session) orelse return error.ScannerIdentityFailed;
    var caps = macos.capabilitiesFromExtendedIdentity(&identity);
    // The identity's model string lives on this stack frame; name the
    // scanner from the static model table instead.
    caps.model = conn.modelName();
    caps.device_name = device_name;
    caps.ir_supported = caps.ir_supported and conn.model.irSupported();
    return caps;
}

fn failureKind(err: anyerror) events.FailureKind {
    return switch (err) {
        error.ScannerNotFound => .no_device,
        error.ScannerBusy => .device_busy,
        error.ScannerAccessDenied => .permission_denied,
        error.ScanCancelled => .cancelled,
        else => .backend_failure,
    };
}

fn clampArea(area: contracts.AreaInches, source: contracts.Source, caps: contracts.ScannerCapabilities) contracts.AreaInches {
    const max_w = if (source == .flatbed) caps.flatbed_width_in else caps.tpu_width_in;
    const max_h = if (source == .flatbed) caps.flatbed_height_in else caps.tpu_height_in;
    const x = std.math.clamp(area.x, 0.0, max_w);
    const y = std.math.clamp(area.y, 0.0, max_h);
    return .{
        .x = x,
        .y = y,
        .width = @min(area.width orelse (max_w - x), max_w - x),
        .height = @min(area.height orelse (max_h - y), max_h - y),
    };
}

fn sameLuts(a: ?[lut.serialized_len]u8, b: ?[lut.serialized_len]u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, &a.?, &b.?);
}

fn gammaTables(luts: *const ?[lut.serialized_len]u8) macos.GammaTables {
    const values = if (luts.*) |*values| values else return .{};
    return .{
        .r = values[0..256],
        .g = values[256..512],
        .b = values[512..768],
    };
}

/// Reverses each row in place, keeping the bytes of each pixel in order.
pub fn mirrorRows(data: []u8, width: u32, bytes_per_pixel: u8) void {
    const bpp: usize = bytes_per_pixel;
    const row_len = @as(usize, width) * bpp;
    if (row_len == 0) return;
    var row_start: usize = 0;
    while (row_start + row_len <= data.len) : (row_start += row_len) {
        const row = data[row_start .. row_start + row_len];
        var left: usize = 0;
        var right: usize = @as(usize, width) - 1;
        while (left < right) : ({
            left += 1;
            right -= 1;
        }) {
            var tmp: [8]u8 = undefined;
            @memcpy(tmp[0..bpp], row[left * bpp ..][0..bpp]);
            @memcpy(row[left * bpp ..][0..bpp], row[right * bpp ..][0..bpp]);
            @memcpy(row[right * bpp ..][0..bpp], tmp[0..bpp]);
        }
    }
}

/// An 8-bit RGB thumbnail at most 256 rows tall, averaged from a 16-bit RGB
/// page (Python stored `rgb >> 8` resized to 256 rows as page 1).
pub fn makeThumbnail(allocator: std.mem.Allocator, rgb: tiff.ImageView) !tiff.ImageView {
    if (rgb.samples_per_pixel != 3 or rgb.bits_per_sample != 16) return error.UnsupportedThumbnailSource;
    const src_w: usize = rgb.width;
    const src_h: usize = rgb.height;
    const dst_h: usize = @max(1, @min(src_h, thumbnail_max_height));
    const dst_w: usize = @max(1, src_w * dst_h / @max(src_h, 1));
    const out = try allocator.alloc(u8, dst_w * dst_h * 3);
    errdefer allocator.free(out);

    for (0..dst_h) |dy| {
        const y0 = dy * src_h / dst_h;
        const y1 = @max(y0 + 1, (dy + 1) * src_h / dst_h);
        for (0..dst_w) |dx| {
            const x0 = dx * src_w / dst_w;
            const x1 = @max(x0 + 1, (dx + 1) * src_w / dst_w);
            var sums = [_]u64{ 0, 0, 0 };
            for (y0..y1) |y| {
                for (x0..x1) |x| {
                    const base = (y * src_w + x) * 6;
                    for (0..3) |ch| {
                        sums[ch] += std.mem.readInt(u16, rgb.data[base + ch * 2 ..][0..2], .little);
                    }
                }
            }
            const count: u64 = (y1 - y0) * (x1 - x0);
            for (0..3) |ch| {
                out[(dy * dst_w + dx) * 3 + ch] = @intCast((sums[ch] / count) >> 8);
            }
        }
    }
    return .{
        .width = @intCast(dst_w),
        .height = @intCast(dst_h),
        .samples_per_pixel = 3,
        .bits_per_sample = 8,
        .data = out,
    };
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "mirrors each row while keeping pixel byte order" {
    var data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    mirrorRows(&data, 3, 2);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 3, 4, 1, 2, 11, 12, 9, 10, 7, 8 }, &data);
    var odd = [_]u8{ 1, 2, 3, 4, 5 };
    mirrorRows(&odd, 5, 1);
    try std.testing.expectEqualSlices(u8, &.{ 5, 4, 3, 2, 1 }, &odd);
}

test "thumbnail averages 16-bit RGB down to 8-bit at most 256 rows" {
    const allocator = std.testing.allocator;
    const width: u32 = 4;
    const height: u32 = 512;
    const data = try allocator.alloc(u8, @as(usize, width) * height * 6);
    defer allocator.free(data);
    for (0..@as(usize, width) * height) |i| {
        std.mem.writeInt(u16, data[i * 6 ..][0..2], 0x1000, .little);
        std.mem.writeInt(u16, data[i * 6 + 2 ..][0..2], 0x8000, .little);
        std.mem.writeInt(u16, data[i * 6 + 4 ..][0..2], 0xff00, .little);
    }
    const thumb = try makeThumbnail(allocator, .{ .width = width, .height = height, .samples_per_pixel = 3, .bits_per_sample = 16, .data = data });
    defer allocator.free(thumb.data);
    try std.testing.expectEqual(@as(u32, 256), thumb.height);
    try std.testing.expectEqual(@as(u32, 2), thumb.width);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x80, 0xff }, thumb.data[0..3]);
}

test "clamps the scan area to the source bounds" {
    const caps = contracts.ScannerCapabilities{ .tpu_width_in = 2.7, .tpu_height_in = 9.54 };
    const area = clampArea(.{ .x = 0.5, .y = 9.0, .width = 3.0, .height = 1.0 }, .tpu, caps);
    try std.testing.expectApproxEqAbs(2.2, area.width.?, 1e-9);
    try std.testing.expectApproxEqAbs(0.54, area.height.?, 1e-9);
    const full = clampArea(.{}, .tpu, caps);
    try std.testing.expectApproxEqAbs(2.7, full.width.?, 1e-9);
}

/// Answers the interpreter's ESC/I conversation the way the V600 does, well
/// enough to run whole scans: FS I identity, ACKs, FS S parameters, FS G
/// block layouts from `starts`, and patterned block data.
const FakeScanner = struct {
    const State = enum { ack, identity, params, start, data };

    starts: []const interpreter.StartScanInfo,
    start_index: usize = 0,
    state: State = .ack,
    data_counter: usize = 0,
    init_count: usize = 0,
    close_count: usize = 0,
    fs_w_count: usize = 0,
    ir_enable_count: usize = 0,

    fn api(self: *FakeScanner) macos.InterpreterApi {
        return .{
            .context = self,
            .initFn = init,
            .writeFn = write,
            .readFn = read,
            .closeFn = close,
            .usbErrorFn = usbError,
            .interpreterErrorFn = interpreterError,
        };
    }

    fn init(context: *anyopaque, _: macos.UsbCallback, _: macos.UsbCallback, _: ?*anyopaque) bool {
        const self: *FakeScanner = @ptrCast(@alignCast(context));
        self.init_count += 1;
        return true;
    }

    fn close(context: *anyopaque) void {
        const self: *FakeScanner = @ptrCast(@alignCast(context));
        self.close_count += 1;
    }

    fn usbError(_: *anyopaque) i16 {
        return 0;
    }

    fn interpreterError(_: *anyopaque) i32 {
        return 0;
    }

    fn write(context: *anyopaque, data: []const u8) bool {
        const self: *FakeScanner = @ptrCast(@alignCast(context));
        if (data.len == 2 and data[0] == interpreter.FS) {
            switch (data[1]) {
                0x49 => self.state = .identity,
                0x53 => self.state = .params,
                0x47 => self.state = .start,
                0x57 => {
                    self.fs_w_count += 1;
                    self.state = .ack;
                },
                else => self.state = .ack,
            }
        } else if (data.len == 2 and data[0] == interpreter.ESC and data[1] == 0x23) {
            self.ir_enable_count += 1;
            self.state = .ack;
        } else if (data.len == 1 and data[0] == interpreter.ACK and self.state == .data) {
            // Block acknowledgement; the next read is the next block.
        } else {
            self.state = .ack;
        }
        return true;
    }

    fn read(context: *anyopaque, buffer: []u8) bool {
        const self: *FakeScanner = @ptrCast(@alignCast(context));
        switch (self.state) {
            .ack => buffer[0] = interpreter.ACK,
            .identity => {
                @memset(buffer, 0);
                std.mem.writeInt(u32, buffer[4..8], 6400, .little);
                std.mem.writeInt(u32, buffer[12..16], 12800, .little);
                std.mem.writeInt(u32, buffer[20..24], 54400, .little);
                std.mem.writeInt(u32, buffer[24..28], 74880, .little);
                std.mem.writeInt(u32, buffer[36..40], 17280, .little);
                std.mem.writeInt(u32, buffer[40..44], 61056, .little);
                buffer[44] = 0x02;
                @memcpy(buffer[46..62], "GT-X820         ");
            },
            .params => @memset(buffer, 0x11),
            .start => {
                const info = self.starts[self.start_index];
                self.start_index += 1;
                self.data_counter = 0;
                buffer[0] = 0x02;
                buffer[1] = 0x00;
                std.mem.writeInt(u32, buffer[2..6], info.block_size, .little);
                std.mem.writeInt(u32, buffer[6..10], info.block_count, .little);
                std.mem.writeInt(u32, buffer[10..14], info.last_block_size, .little);
                self.state = .data;
            },
            .data => {
                for (buffer[0 .. buffer.len - 1]) |*byte| {
                    byte.* = patternByte(self.data_counter);
                    self.data_counter += 1;
                }
                buffer[buffer.len - 1] = 0x00;
            },
        }
        return true;
    }

    fn patternByte(index: usize) u8 {
        return @intCast(index % 251);
    }
};

/// Direct USB for the TPU RS commands: every read is an ACK.
const AckUsb = struct {
    writes: usize = 0,

    fn io(self: *AckUsb) macos.UsbIo {
        return .{ .context = self, .readFn = readAck, .writeFn = countWrite };
    }

    fn readAck(_: *anyopaque, buffer: []u8, _: u32) macos.UsbTransferError!usize {
        buffer[0] = interpreter.ACK;
        return 1;
    }

    fn countWrite(context: *anyopaque, _: []const u8, _: u32) macos.UsbTransferError!void {
        const self: *AckUsb = @ptrCast(@alignCast(context));
        self.writes += 1;
    }
};

test "runs an RGB+IR scan through the interpreter conversation into a three-page TIFF" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/scan.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(output);

    // 1/64 x 1/128 in at 800 dpi is 12 x 6 pixels: 432 RGB16 bytes, 72 IR bytes.
    var fake = FakeScanner{ .starts = &.{
        .{ .status = 0, .block_size = 100, .block_count = 4, .last_block_size = 32 },
        .{ .status = 0, .block_size = 50, .block_count = 1, .last_block_size = 22 },
    } };
    var ack_usb = AckUsb{};
    const conn = try std.heap.page_allocator.create(Connection);
    conn.* = .{
        .hardware = null,
        .usb_io = ack_usb.io(),
        .session = .{ .api = fake.api(), .callback_context = .{ .usb = ack_usb.io() } },
        .model = macos.scannerModelForProductId(0x013a),
    };
    shared_connection = conn;
    defer {
        if (shared_connection) |leftover| std.heap.page_allocator.destroy(leftover);
        shared_connection = null;
    }

    var env = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer env.deinit();
    const runtime = Runtime{ .allocator = allocator, .io = std.testing.io, .environ_map = &env };
    try runtime.scan(.{
        .request = .{
            .dpi = 800,
            .source = .tpu,
            .kind = .rgb_ir,
            .area = .{ .x = 0.25, .y = 1.0, .width = 1.0 / 64.0, .height = 1.0 / 128.0 },
        },
        .output_path = output,
    });

    try std.testing.expectEqual(@as(usize, 2), fake.start_index);
    try std.testing.expectEqual(@as(usize, 2), fake.fs_w_count);
    try std.testing.expectEqual(@as(usize, 1), fake.ir_enable_count);
    // TPU calibration runs once, then the interpreter is reinitialized.
    try std.testing.expect(ack_usb.writes > 0);
    try std.testing.expectEqual(@as(usize, 1), fake.init_count);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);

    var pages = try tiff.loadRgbIrPages(allocator, output);
    defer pages.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 12), pages.rgb.width);
    try std.testing.expectEqual(@as(u32, 6), pages.rgb.height);
    try std.testing.expectEqual(@as(u16, 16), pages.rgb.bits_per_sample);
    var expected_rgb: [432]u8 = undefined;
    for (&expected_rgb, 0..) |*byte, i| byte.* = FakeScanner.patternByte(i);
    mirrorRows(&expected_rgb, 12, 6);
    try std.testing.expectEqualSlices(u8, &expected_rgb, pages.rgb.data);

    const ir = pages.ir.?;
    try std.testing.expectEqual(@as(u16, 8), ir.bits_per_sample);
    try std.testing.expectEqual(@as(u16, 1), ir.samples_per_pixel);
    var expected_ir: [72]u8 = undefined;
    for (&expected_ir, 0..) |*byte, i| byte.* = FakeScanner.patternByte(i);
    mirrorRows(&expected_ir, 12, 1);
    try std.testing.expectEqualSlices(u8, &expected_ir, ir.data);
    try std.testing.expectEqual(@as(?u32, 800), try tiff.readDpi(allocator, output));

    const sidecar_path = try std.fmt.allocPrint(allocator, "{s}.json", .{output});
    defer allocator.free(sidecar_path);
    const sidecar = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, sidecar_path, allocator, .limited(8192));
    defer allocator.free(sidecar);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, sidecar, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("rgb+ir", parsed.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 800), parsed.value.object.get("ir_effective_dpi").?.integer);
}

test "a cancel file stops the scan, sends CAN, and drops the connection" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/scan.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(output);
    const cancel_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/cancel", .{tmp.sub_path[0..]});
    defer allocator.free(cancel_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cancel", .data = "" });

    var fake = FakeScanner{ .starts = &.{
        .{ .status = 0, .block_size = 100, .block_count = 4, .last_block_size = 32 },
    } };
    var ack_usb = AckUsb{};
    const conn = try std.heap.page_allocator.create(Connection);
    conn.* = .{
        .hardware = null,
        .usb_io = ack_usb.io(),
        .session = .{ .api = fake.api(), .callback_context = .{ .usb = ack_usb.io() } },
        .model = macos.scannerModelForProductId(0x013a),
    };
    shared_connection = conn;

    var env = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer env.deinit();
    const runtime = Runtime{ .allocator = allocator, .io = std.testing.io, .environ_map = &env };
    try std.testing.expectError(error.ScanCancelled, runtime.scan(.{
        .request = .{ .dpi = 800, .source = .tpu, .kind = .rgb, .area = .{ .width = 1.0 / 64.0, .height = 1.0 / 128.0 } },
        .output_path = output,
        .cancel_file = cancel_path,
    }));
    // The failed connection was closed and freed.
    try std.testing.expect(shared_connection == null);
    try std.testing.expectEqual(@as(usize, 1), fake.close_count);
}
