const std = @import("std");
const builtin = @import("builtin");

const contracts = @import("contracts.zig");
const events = @import("events.zig");
const lut = @import("lut.zig");
const sane = @import("sane.zig");
const tiff = @import("../tiff.zig");

pub const v600_vendor_id = "04b8";
pub const v600_product_id = "013a";
pub const v600_vendor_id_int: u16 = 0x04b8;
pub const v600_product_id_int: u16 = 0x013a;
pub const usbdevfs_reset: u32 = 0x5514;
pub const sane_default_model_name = "Perfection V600 / GT-X820 (SANE)";

pub const Device = struct {
    name: []const u8,
    vendor: []const u8 = "",
    model: []const u8 = "",
    kind: []const u8 = "",
    raw_line: []const u8 = "",

    pub const BackendKind = enum {
        epson2,
        epkowa_interpreter,
        epkowa,
        other,
    };

    pub fn backendKind(self: Device) BackendKind {
        if (std.mem.indexOf(u8, self.name, "epson2") != null) return .epson2;
        if (std.mem.indexOf(u8, self.name, "epkowa:interpreter") != null) return .epkowa_interpreter;
        if (std.mem.indexOf(u8, self.name, "epkowa") != null) return .epkowa;
        return .other;
    }

    pub fn backendRank(self: Device) u8 {
        return self.backendRankForKind(.rgb);
    }

    pub fn backendRankForKind(self: Device, kind: contracts.ScanKind) u8 {
        return switch (kind) {
            .ir, .rgb_ir => switch (self.backendKind()) {
                .epkowa_interpreter => 0,
                .epkowa => 1,
                .epson2 => 2,
                .other => 3,
            },
            .rgb, .gray => switch (self.backendKind()) {
                .epson2 => 0,
                .epkowa_interpreter => 1,
                .epkowa => 2,
                .other => 3,
            },
        };
    }

    pub fn canUseForKind(self: Device, kind: contracts.ScanKind) bool {
        return switch (kind) {
            .ir, .rgb_ir => switch (self.backendKind()) {
                .epkowa_interpreter, .epkowa => true,
                .epson2, .other => false,
            },
            .rgb, .gray => true,
        };
    }

    pub fn looksLikeV600(self: Device) bool {
        return containsAny(self.raw_line, &.{ "V600", "GT-X820", "Perfection V600" }) or
            containsAny(self.name, &.{ "epkowa:interpreter", "epson2" });
    }
};

pub const ProgressEvent = events.ProgressEvent;
pub const FailureKind = events.FailureKind;

pub const WrapperAvailability = sane.WrapperAvailability;

pub const cache_header = "v600-scanner-device-cache-v1";
pub const tiff_software = "epdaughter-sane";
const custom_lut_marker = tiff.scanner_custom_lut_marker;

pub const TiffMetadataTag = enum(u16) {
    make = 271,
    model = 272,
    software = 305,
};

pub const TiffMetadataTagValue = struct {
    tag: TiffMetadataTag,
    value: []const u8,
};

pub const SaveImageFormat = enum {
    tiff,
    png,
};

pub const SaveImagePlan = struct {
    path: []u8,
    format: SaveImageFormat,
    converted_png_16_to_tiff: bool = false,

    pub fn deinit(self: SaveImagePlan, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const DeviceChoiceSource = events.SelectionSource;

pub const DeviceChoice = struct {
    name: []u8,
    source: DeviceChoiceSource,

    pub fn deinit(self: DeviceChoice, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const SaneBackendState = struct {
    device_name: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    product_id: ?u16 = null,
    cached_capabilities: ?contracts.ScannerCapabilities = null,

    pub fn init(product_id: ?u16) SaneBackendState {
        return .{ .product_id = product_id };
    }
};

pub fn saneIdentity(allocator: std.mem.Allocator, model_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "SANE {s}", .{model_name});
}

pub fn saneStatus() [1]u8 {
    return .{0};
}

pub fn saneExtendedIdentity() [80]u8 {
    return .{0} ** 80;
}

pub fn planSaveImage(allocator: std.mem.Allocator, path: []const u8, depth: contracts.BitDepth) !SaveImagePlan {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) {
        if (depth == .sixteen) {
            return .{
                .path = try std.mem.replaceOwned(u8, allocator, path, ".png", ".tiff"),
                .format = .tiff,
                .converted_png_16_to_tiff = true,
            };
        }
        return .{ .path = try allocator.dupe(u8, path), .format = .png };
    }
    return .{ .path = try allocator.dupe(u8, path), .format = .tiff };
}

pub const UsbDeviceId = struct {
    vendor_id: u16,
    product_id: u16,
};

pub const UsbResetStatus = enum {
    reset_performed,
    device_not_found,
    permission_denied,
    reset_failed,
};

pub const UsbResetOutcome = struct {
    status: UsbResetStatus,
    path: ?[]u8 = null,

    pub fn deinit(self: UsbResetOutcome, allocator: std.mem.Allocator) void {
        if (self.path) |path| allocator.free(path);
    }
};

const ScanFailure = struct {
    kind: FailureKind,
    detail: []u8,

    fn deinit(self: ScanFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.detail);
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    scanimage_command: ?[]const u8 = null,
    event_sink: ?events.Sink = null,

    pub fn wrappers(self: Runtime) WrapperAvailability {
        if (self.scanimage_command != null) return .{
            .scanimage_v600 = true,
            .scanimage_v600_ir = true,
        };
        return .{
            .scanimage_v600 = self.commandExists("scanimage-v600"),
            .scanimage_v600_ir = self.commandExists("scanimage-v600-ir"),
        };
    }

    pub fn close(self: Runtime) void {
        _ = self;
    }

    pub fn getIdentity(self: Runtime, model_name: []const u8) ![]u8 {
        return saneIdentity(self.allocator, model_name);
    }

    pub fn getStatus(_: Runtime) [1]u8 {
        return saneStatus();
    }

    pub fn getExtendedIdentity(_: Runtime) [80]u8 {
        return saneExtendedIdentity();
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
        const elapsed_ns = monotonicNowNs() - start_ns;
        self.emitTiming(.{
            .stage = stage,
            .elapsed_us = elapsed_ns / std.time.ns_per_us,
            .detail = detail,
        });
    }

    pub fn discoverDevices(self: Runtime) ![]Device {
        return self.discoverDevicesForKind(.rgb);
    }

    fn discoverDevicesForKind(self: Runtime, kind: contracts.ScanKind) ![]Device {
        const total_start = monotonicNowNs();
        var total_detail: []const u8 = "error";
        defer self.emitTimingSince("linux.discover.total", total_start, total_detail);

        const list_start = monotonicNowNs();
        const result = runCapture(self.allocator, self.io, &.{ self.discoveryCommand(), "-L" }, self.environ_map) catch |err| {
            self.emitTimingSince("linux.discover.scanimage_list", list_start, "spawn-error");
            return err;
        };
        self.emitTimingSince("linux.discover.scanimage_list", list_start, if (result.succeeded()) "ok" else "failed");
        defer result.deinit(self.allocator);
        if (!result.succeeded()) {
            self.emitDeviceDiscovery(.{
                .discovery_attempted = true,
                .devices_found = 0,
                .selected_device = null,
                .selection_source = .none,
            });
            return error.ScanimageListFailed;
        }
        const parse_start = monotonicNowNs();
        const devices = parseDeviceList(self.allocator, result.stdout) catch |err| {
            self.emitTimingSince("linux.discover.parse_device_list", parse_start, "error");
            return err;
        };
        self.emitTimingSince("linux.discover.parse_device_list", parse_start, "ok");
        const select_start = monotonicNowNs();
        const selected = selectDeviceForKind(devices, kind);
        self.emitTimingSince("linux.discover.select_device", select_start, if (selected != null) "selected" else "none");
        self.emitDeviceDiscovery(.{
            .discovery_attempted = true,
            .devices_found = devices.len,
            .selected_device = if (selected) |device| device.name else null,
            .selection_source = if (selected != null) .discovered else .none,
        });
        total_detail = if (selected != null) "selected" else "no-v600";
        return devices;
    }

    pub fn probe(self: Runtime, out: anytype) !contracts.ScannerCapabilities {
        const total_start = monotonicNowNs();
        var total_detail: []const u8 = "error";
        defer self.emitTimingSince("linux.probe.total", total_start, total_detail);

        self.emitStartup(.{ .platform = "linux", .backend = "sane" });
        const discover_start = monotonicNowNs();
        const devices = try self.discoverDevicesForKind(.rgb_ir);
        self.emitTimingSince("linux.probe.discover_devices", discover_start, "ok");
        defer freeDevices(self.allocator, devices);

        const select_start = monotonicNowNs();
        const device = selectDeviceForKind(devices, .rgb_ir) orelse return error.NoV600Device;
        self.emitTimingSince("linux.probe.select_device", select_start, "selected");
        const cache_write_start = monotonicNowNs();
        self.writeCachedDeviceName(device.name);
        self.emitTimingSince("linux.probe.cache_write", cache_write_start, "attempted");
        const wrappers_available = self.wrappers();
        const help_cmd = if (wrappers_available.scanimage_v600) "scanimage-v600" else "scanimage";

        const flatbed_help = try self.helpFor(help_cmd, device.name, .flatbed);
        defer self.allocator.free(flatbed_help);
        const tpu_help = try self.helpFor(help_cmd, device.name, .tpu);
        defer self.allocator.free(tpu_help);

        const parse_start = monotonicNowNs();
        var caps = sane.parseCombinedCapabilities(flatbed_help, tpu_help);
        if (caps.device_name.len == 0) caps.device_name = device.name;
        caps.ir_supported = wrappers_available.scanimage_v600_ir and device.canUseForKind(.ir);
        self.emitTimingSince("linux.probe.parse_combined_capabilities", parse_start, "ok");
        self.emitProbe(.{
            .device = caps.device_name,
            .model = caps.model,
            .max_resolution = caps.max_resolution,
            .ir_supported = caps.ir_supported,
        });

        try out.print("device: {s}\n", .{caps.device_name});
        try out.print("model: {s}\n", .{caps.model});
        try out.print("wrappers: scanimage-v600={any} scanimage-v600-ir={any}\n", .{
            wrappers_available.scanimage_v600,
            wrappers_available.scanimage_v600_ir,
        });
        try out.print("flatbed: {d:.3}in x {d:.3}in\n", .{ caps.flatbed_width_in, caps.flatbed_height_in });
        try out.print("tpu: {d:.3}in x {d:.3}in\n", .{ caps.tpu_width_in, caps.tpu_height_in });
        try out.print("max_resolution: {d}\n", .{caps.max_resolution});
        try out.print("ir_supported: {any}\n", .{caps.ir_supported});
        total_detail = "ok";
        return caps;
    }

    pub fn scan(self: Runtime, options: ScanOptions) !void {
        self.emitStartup(.{ .platform = "linux", .backend = "sane" });
        if (options.output_path.len == 0) {
            self.emitScanError(.{ .kind = .scanimage_failed, .detail = "missing output path" });
            return error.MissingOutputPath;
        }

        var selected = try self.resolveDeviceName(options.device_name, options.request.kind);
        defer selected.deinit(self.allocator);

        if (options.request.kind == .rgb_ir) {
            try self.scanRgbIr(options, selected.name);
            return;
        }

        var first_failure = self.scanOnce(options, selected.name) catch |err| switch (err) {
            error.ScanimageHelpFailed => try self.makeFailure(.no_device, "scanimage capability lookup failed"),
            else => return err,
        };
        if (first_failure == null) return;
        defer first_failure.?.deinit(self.allocator);

        if (selected.source == .cache_hit and options.device_name == null and first_failure.?.kind == .no_device) {
            const refreshed = try self.discoverAndCacheDeviceName(options.request.kind);
            selected.deinit(self.allocator);
            selected = refreshed;
            var retry_failure = self.scanOnce(options, selected.name) catch |err| switch (err) {
                error.ScanimageHelpFailed => try self.makeFailure(.no_device, "scanimage capability lookup failed after cache refresh"),
                else => return err,
            };
            if (retry_failure == null) return;
            defer retry_failure.?.deinit(self.allocator);
            self.emitScanError(.{ .kind = retry_failure.?.kind, .detail = retry_failure.?.detail });
            return error.ScanFailed;
        }

        self.emitScanError(.{ .kind = first_failure.?.kind, .detail = first_failure.?.detail });
        return error.ScanFailed;
    }

    fn scanRgbIr(self: Runtime, options: ScanOptions, device_name: []const u8) !void {
        const total_start = monotonicNowNs();
        var total_detail: []const u8 = "error";
        defer self.emitTimingSince("linux.scan_rgb_ir.total", total_start, total_detail);

        const rgb_path = try std.fmt.allocPrint(self.allocator, "{s}.rgb.tmp.tiff", .{options.output_path});
        defer self.allocator.free(rgb_path);
        const ir_path = try std.fmt.allocPrint(self.allocator, "{s}.ir.tmp.tiff", .{options.output_path});
        defer self.allocator.free(ir_path);
        const thumb_path = try std.fmt.allocPrint(self.allocator, "{s}.thumb.tmp.tiff", .{options.output_path});
        defer self.allocator.free(thumb_path);
        const rgb_sidecar_path = try std.fmt.allocPrint(self.allocator, "{s}.json", .{rgb_path});
        defer self.allocator.free(rgb_sidecar_path);
        const ir_sidecar_path = try std.fmt.allocPrint(self.allocator, "{s}.json", .{ir_path});
        defer self.allocator.free(ir_sidecar_path);
        defer {
            const cleanup_start = monotonicNowNs();
            deleteIfExists(self.io, rgb_path);
            deleteIfExists(self.io, ir_path);
            deleteIfExists(self.io, thumb_path);
            deleteIfExists(self.io, rgb_sidecar_path);
            deleteIfExists(self.io, ir_sidecar_path);
            self.emitTimingSince("linux.scan_rgb_ir.temp_cleanup", cleanup_start, "attempted");
        }

        const rgb_plan_start = monotonicNowNs();
        var rgb_request = options.request;
        rgb_request.kind = .rgb;
        rgb_request.depth = .sixteen;
        rgb_request.source = if (options.request.source == .flatbed) .flatbed else .tpu;
        rgb_request.output_path = rgb_path;
        var rgb_options = options;
        rgb_options.request = rgb_request;
        rgb_options.output_path = rgb_path;
        rgb_options.device_name = device_name;
        self.emitTimingSince("linux.scan_rgb_ir.rgb_plan", rgb_plan_start, "ok");
        const rgb_pass_start = monotonicNowNs();
        try self.scanPassOrEmit(rgb_options, device_name);
        self.emitTimingSince("linux.scan_rgb_ir.rgb_pass", rgb_pass_start, "ok");

        const ir_plan_start = monotonicNowNs();
        var ir_request = options.request;
        ir_request.kind = .ir;
        ir_request.depth = .eight;
        ir_request.source = .tpu;
        ir_request.dpi = @min(options.request.dpi, 3200);
        ir_request.lut_file_path = null;
        ir_request.output_path = ir_path;
        var ir_options = options;
        ir_options.request = ir_request;
        ir_options.output_path = ir_path;
        ir_options.device_name = device_name;
        self.emitTimingSince("linux.scan_rgb_ir.ir_plan", ir_plan_start, "ok");
        const ir_pass_start = monotonicNowNs();
        try self.scanPassOrEmit(ir_options, device_name);
        self.emitTimingSince("linux.scan_rgb_ir.ir_pass", ir_pass_start, "ok");

        const thumbnail_start = monotonicNowNs();
        try self.createThumbnail(rgb_path, thumb_path);
        self.emitTimingSince("linux.scan_rgb_ir.thumbnail", thumbnail_start, "ok");
        const combine_start = monotonicNowNs();
        try self.combineTiffPages(rgb_path, thumb_path, ir_path, options.output_path);
        self.emitTimingSince("linux.scan_rgb_ir.combine_tiff_pages", combine_start, "ok");
        const pass_dpis = combinedPassDpis(options.request);
        const metadata_tags_start = monotonicNowNs();
        try self.applyTiffMetadataTags(options.output_path, .{
            .model = "Epson Perfection V600 Photo",
            .software = tiff_software,
            .dpi = pass_dpis.rgb,
            .custom_luts_applied = customLutsApplied(options.request),
        });
        try tiff.writeScannerPageMetadata(self.allocator, options.output_path, contracts.TiffPageLayout.ir, .{
            .model = "Epson Perfection V600 Photo",
            .software = tiff_software,
            .dpi = pass_dpis.ir,
        });
        self.emitTimingSince("linux.scan_rgb_ir.metadata_tags", metadata_tags_start, "ok");
        const sidecar_start = monotonicNowNs();
        const metadata_path = try writeCombinedMetadataSidecar(self.allocator, self.io, options, device_name, pass_dpis);
        self.emitTimingSince("linux.scan_rgb_ir.metadata_sidecar", sidecar_start, "ok");
        defer self.allocator.free(metadata_path);
        self.emitScanComplete(.{
            .output = options.output_path,
            .metadata = metadata_path,
        });
        total_detail = "ok";
    }

    fn scanPassOrEmit(self: Runtime, options: ScanOptions, device_name: []const u8) !void {
        const failure = self.scanOnce(options, device_name) catch |err| switch (err) {
            error.ScanimageHelpFailed => try self.makeFailure(.no_device, "scanimage capability lookup failed"),
            else => return err,
        };
        if (failure) |scan_failure| {
            defer scan_failure.deinit(self.allocator);
            self.emitScanError(.{ .kind = scan_failure.kind, .detail = scan_failure.detail });
            return error.ScanFailed;
        }
    }

    fn createThumbnail(self: Runtime, rgb_path: []const u8, thumb_path: []const u8) !void {
        const result = try runCapture(self.allocator, self.io, &.{
            "magick",
            rgb_path,
            "-auto-orient",
            "-depth",
            "8",
            "-resize",
            "x256>",
            thumb_path,
        }, null);
        defer result.deinit(self.allocator);
        if (!result.succeeded()) return error.ThumbnailFailed;
    }

    fn combineTiffPages(self: Runtime, rgb_path: []const u8, thumb_path: []const u8, ir_path: []const u8, output_path: []const u8) !void {
        const result = try runCapture(self.allocator, self.io, &.{
            "tiffcp",
            rgb_path,
            thumb_path,
            ir_path,
            output_path,
        }, null);
        defer result.deinit(self.allocator);
        if (!result.succeeded()) return error.TiffCombineFailed;
    }

    fn scanOnce(self: Runtime, options: ScanOptions, device_name: []const u8) !?ScanFailure {
        const total_start = monotonicNowNs();
        var total_detail: []const u8 = "error";
        defer self.emitTimingSince("linux.scan_once.total", total_start, total_detail);

        const caps_start = monotonicNowNs();
        var caps_detail: []const u8 = "error";
        var caps = if (options.capabilities) |caps_override| caps: {
            caps_detail = "override";
            break :caps caps_override;
        } else if (!options.request.area.isExplicit()) caps: {
            caps_detail = "default-no-area";
            break :caps contracts.ScannerCapabilities{ .device_name = device_name };
        } else caps: {
            const help_cmd = if (self.wrappers().scanimage_v600) "scanimage-v600" else "scanimage";
            const flatbed_help = try self.helpFor(help_cmd, device_name, .flatbed);
            defer self.allocator.free(flatbed_help);
            const tpu_help = try self.helpFor(help_cmd, device_name, .tpu);
            defer self.allocator.free(tpu_help);
            var parsed = sane.parseCombinedCapabilities(flatbed_help, tpu_help);
            parsed.device_name = device_name;
            caps_detail = "probe";
            break :caps parsed;
        };
        if (caps.device_name.len == 0) caps.device_name = device_name;
        self.emitTimingSince("linux.scan_once.capability_lookup", caps_start, caps_detail);

        const normalize_start = monotonicNowNs();
        var request = options.request;
        request.output_path = options.output_path;
        self.emitTimingSince("linux.scan_once.request_normalize", normalize_start, "ok");
        const plan_start = monotonicNowNs();
        var plan = sane.planCommand(self.allocator, request, caps, self.wrappers()) catch |err| switch (err) {
            error.IrWrapperRequired => {
                self.emitTimingSince("linux.scan_once.command_plan", plan_start, "missing-ir-wrapper");
                total_detail = "unsupported-ir-wrapper";
                return try self.makeFailure(.unsupported_option, "IR scanning requires the scanimage-v600-ir wrapper; plain SCAN_IR_MODE fallback is not a verified scanner capability");
            },
            else => return err,
        };
        defer plan.deinit(self.allocator);
        self.applyScanimageCommandOverride(&plan);
        self.emitTimingSince("linux.scan_once.command_plan", plan_start, "ok");
        const progress_flag_start = monotonicNowNs();
        try addProgressFlag(self.allocator, &plan);
        self.emitTimingSince("linux.scan_once.progress_flag", progress_flag_start, "ok");

        self.emitScanStart(.{
            .device = caps.device_name,
            .output = options.output_path,
            .source = plan.source,
            .kind = plan.kind,
            .requested_dpi = plan.original_dpi,
            .effective_dpi = plan.effective_dpi,
        });
        const run_start = monotonicNowNs();
        const timeout_ms = scanTimeoutMs(request, plan.effective_dpi, plan.source, caps);
        const result = try self.runScanPlan(&plan, options.cancel_file, timeout_ms);
        self.emitTimingSince("linux.scan_once.run_scan_plan", run_start, if (result.succeeded()) "ok" else if (result.timed_out) "timeout" else "failed");
        defer result.deinit(self.allocator);
        if (result.timed_out) {
            total_detail = "scan-timeout";
            var detail_buffer: [96]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buffer, "scanimage did not finish within {d} s and was stopped", .{timeout_ms / std.time.ms_per_s}) catch "scanimage timed out";
            return try self.makeFailure(.scanimage_failed, detail);
        }
        if (!result.succeeded()) {
            total_detail = "scan-failed";
            return try self.makeFailure(classifyFailure(result.stderr), result.stderr);
        }
        const mirror_start = monotonicNowNs();
        try self.mirrorTiffForSource(options.output_path, plan.source);
        self.emitTimingSince("linux.scan_once.mirror", mirror_start, if (shouldMirrorTiff(plan.source)) "applied" else "skipped");
        const metadata_tags_start = monotonicNowNs();
        try self.applyTiffMetadataTags(options.output_path, .{
            .model = if (caps.model.len == 0) "Epson Scanner" else caps.model,
            .software = tiff_software,
            .dpi = plan.effective_dpi,
            .custom_luts_applied = customLutsApplied(options.request),
        });
        self.emitTimingSince("linux.scan_once.metadata_tags", metadata_tags_start, "ok");
        const sidecar_start = monotonicNowNs();
        const metadata_path = try writeMetadataSidecar(self.allocator, self.io, options, caps, &plan);
        self.emitTimingSince("linux.scan_once.metadata_sidecar", sidecar_start, "ok");
        defer self.allocator.free(metadata_path);
        self.emitScanComplete(.{
            .output = options.output_path,
            .metadata = metadata_path,
        });
        total_detail = "ok";
        return null;
    }

    fn makeFailure(self: Runtime, kind: FailureKind, raw_detail: []const u8) !ScanFailure {
        const detail = std.mem.trim(u8, raw_detail, " \t\r\n");
        return .{
            .kind = kind,
            .detail = try self.allocator.dupe(u8, if (detail.len == 0) "scanimage exited without diagnostic" else detail),
        };
    }

    fn mirrorTiffForSource(self: Runtime, output_path: []const u8, source: contracts.Source) !void {
        if (!shouldMirrorTiff(source)) return;
        try self.mirrorTiffHorizontallyInPlace(output_path);
    }

    fn mirrorTiffHorizontallyInPlace(self: Runtime, output_path: []const u8) !void {
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.mirror.tmp.tiff", .{output_path});
        defer self.allocator.free(tmp_path);
        defer deleteIfExists(self.io, tmp_path);

        try self.mirrorTiffHorizontally(output_path, tmp_path);
        try replaceFile(self.io, tmp_path, output_path);
    }

    fn mirrorTiffHorizontally(self: Runtime, input_path: []const u8, output_path: []const u8) !void {
        const result = try runCapture(self.allocator, self.io, &.{
            "magick",
            input_path,
            "-flop",
            output_path,
        }, null);
        defer result.deinit(self.allocator);
        if (!result.succeeded()) return error.TiffMirrorFailed;
    }

    fn applyTiffMetadataTags(self: Runtime, output_path: []const u8, metadata: contracts.TiffMetadata) !void {
        try tiff.writeScannerMetadata(self.allocator, output_path, .{
            .make = metadata.make,
            .model = metadata.model,
            .software = metadata.software,
            .dpi = metadata.dpi,
            .custom_luts_applied = metadata.custom_luts_applied,
        });
    }

    fn helpFor(self: Runtime, command: []const u8, device_name: []const u8, source: contracts.Source) ![]u8 {
        const source_name = switch (source) {
            .flatbed => "Flatbed",
            .tpu => "Transparency Unit",
        };
        const stage = switch (source) {
            .flatbed => "linux.capabilities.help.flatbed",
            .tpu => "linux.capabilities.help.tpu",
        };
        const executable = if (self.scanimage_command != null and isScanimageCommand(command)) self.scanimageCommand() else command;
        const start = monotonicNowNs();
        const result = runCapture(self.allocator, self.io, &.{
            executable,
            "--device-name",
            device_name,
            "--source",
            source_name,
            "--help",
        }, self.environ_map) catch |err| {
            self.emitTimingSince(stage, start, "spawn-error");
            return err;
        };
        self.emitTimingSince(stage, start, if (result.succeeded()) "ok" else "failed");
        defer {
            self.allocator.free(result.stderr);
        }
        if (!result.succeeded()) {
            self.allocator.free(result.stdout);
            return error.ScanimageHelpFailed;
        }
        return result.stdout;
    }

    fn runScanPlan(self: Runtime, plan: *const sane.CommandPlan, cancel_file: ?[]const u8, timeout_ms: u64) !RunResult {
        const total_start = monotonicNowNs();
        var total_detail: []const u8 = "error";
        defer self.emitTimingSince("linux.scan.run_plan.total", total_start, total_detail);

        const env_start = monotonicNowNs();
        var env_map: ?std.process.Environ.Map = null;
        defer if (env_map) |*map| map.deinit();
        const child_env = try prepareEnvironment(self.allocator, self.environ_map, plan.env, &env_map);
        self.emitTimingSince("linux.scan.environment", env_start, if (child_env == null) "inherit" else "custom");

        const spawn_start = monotonicNowNs();
        var child = try std.process.spawn(self.io, .{
            .argv = plan.argv.items,
            .environ_map = child_env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        });
        self.emitTimingSince("linux.scan.child_spawn", spawn_start, "ok");
        errdefer child.kill(self.io);

        var stderr = std.array_list.Managed(u8).init(self.allocator);
        errdefer stderr.deinit();

        var stream_buffer: [128]u8 = undefined;
        const stderr_fd = child.stderr.?.handle;
        const stream_start = monotonicNowNs();
        const deadline_ns = total_start + timeout_ms * std.time.ns_per_ms;
        var progress_emit_ns: u64 = 0;
        var stream_detail: []const u8 = "ok";
        while (true) {
            if (cancel_file) |path| {
                if (cancelState(cancel_file, cancelFileExists(self.io, path)) == .cancel_requested) {
                    stream_detail = "cancelled";
                    self.emitTimingSince("linux.scan.cancel_file", total_start, "observed");
                    child.kill(self.io);
                    self.emitScanCancelled(.{ .kind = .cancelled, .detail = "cancel file observed" });
                    total_detail = "cancelled";
                    return error.ScanCancelled;
                }
            }
            if (monotonicNowNs() >= deadline_ns) {
                self.emitTimingSince("linux.scan.stderr_stream", stream_start, "timeout");
                child.kill(self.io);
                total_detail = "timeout";
                return .{
                    .term = .{ .unknown = 0 },
                    .stdout = &.{},
                    .stderr = try stderr.toOwnedSlice(),
                    .timed_out = true,
                };
            }

            // Wait for output in short steps so cancel and the deadline are
            // checked even while scanimage is silent.
            var poll_fds = [_]std.posix.pollfd{.{ .fd = stderr_fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&poll_fds, 250) == 0) continue;
            const n = try std.posix.read(stderr_fd, &stream_buffer);
            if (n == 0) break;
            try stderr.appendSlice(stream_buffer[0..n]);
            const progress_start = monotonicNowNs();
            emitProgressFromChunk(self, stream_buffer[0..n]) catch {};
            progress_emit_ns += monotonicNowNs() - progress_start;
        }
        self.emitTimingSince("linux.scan.stderr_stream", stream_start, stream_detail);
        self.emitTiming(.{
            .stage = "linux.scan.progress_emit_total",
            .elapsed_us = progress_emit_ns / std.time.ns_per_us,
            .detail = "stderr-chunks",
        });

        const wait_start = monotonicNowNs();
        const term = try child.wait(self.io);
        self.emitTimingSince("linux.scan.child_wait", wait_start, "ok");
        total_detail = "ok";
        return .{
            .term = term,
            .stdout = &.{},
            .stderr = try stderr.toOwnedSlice(),
        };
    }

    fn commandExists(self: Runtime, command: []const u8) bool {
        const result = runCapture(self.allocator, self.io, &.{ "sh", "-c", commandExistsScript(command) }, self.environ_map) catch return false;
        defer result.deinit(self.allocator);
        return result.succeeded();
    }

    fn scanimageCommand(self: Runtime) []const u8 {
        return self.scanimage_command orelse "scanimage";
    }

    fn discoveryCommand(self: Runtime) []const u8 {
        if (self.scanimage_command) |command| return command;
        if (self.commandExists("scanimage-v600")) return "scanimage-v600";
        return "scanimage";
    }

    fn applyScanimageCommandOverride(self: Runtime, plan: *sane.CommandPlan) void {
        const override = self.scanimage_command orelse return;
        if (plan.argv.items.len == 0) return;
        if (isScanimageCommand(plan.argv.items[0])) {
            plan.argv.items[0] = override;
        }
    }

    fn resolveDeviceName(self: Runtime, explicit_device_name: ?[]const u8, kind: contracts.ScanKind) !DeviceChoice {
        if (explicit_device_name) |name| {
            const start = monotonicNowNs();
            self.emitDeviceDiscovery(.{
                .discovery_attempted = false,
                .devices_found = null,
                .selected_device = name,
                .selection_source = .explicit,
            });
            self.emitTimingSince("linux.resolve.explicit", start, "selected");
            return .{ .name = try self.allocator.dupe(u8, name), .source = .explicit };
        }
        const cache_start = monotonicNowNs();
        const cached = self.readCachedDeviceName() catch |err| {
            self.emitTimingSince("linux.resolve.cache_lookup", cache_start, "error");
            return err;
        };
        self.emitTimingSince("linux.resolve.cache_lookup", cache_start, if (cached != null) "hit" else "miss");
        if (cached) |cached_name| {
            if (!cachedDeviceUsableForKind(cached_name, kind)) {
                self.allocator.free(cached_name);
                self.emitTimingSince("linux.resolve.cache_kind_filter", cache_start, "ignored");
                const discover_start = monotonicNowNs();
                const choice = self.discoverAndCacheDeviceName(kind) catch |err| {
                    self.emitTimingSince("linux.resolve.discover_and_cache", discover_start, "error");
                    return err;
                };
                self.emitTimingSince("linux.resolve.discover_and_cache", discover_start, "selected");
                return choice;
            }
            self.emitDeviceDiscovery(.{
                .discovery_attempted = false,
                .devices_found = null,
                .selected_device = cached_name,
                .selection_source = .cache_hit,
            });
            return .{ .name = cached_name, .source = .cache_hit };
        }
        const discover_start = monotonicNowNs();
        const choice = self.discoverAndCacheDeviceName(kind) catch |err| {
            self.emitTimingSince("linux.resolve.discover_and_cache", discover_start, "error");
            return err;
        };
        self.emitTimingSince("linux.resolve.discover_and_cache", discover_start, "selected");
        return choice;
    }

    fn discoverAndCacheDeviceName(self: Runtime, kind: contracts.ScanKind) !DeviceChoice {
        const devices = try self.discoverDevicesForKind(kind);
        defer freeDevices(self.allocator, devices);
        const selected = selectDeviceForKind(devices, kind) orelse return error.NoV600Device;
        const name = try self.allocator.dupe(u8, selected.name);
        self.writeCachedDeviceName(name);
        return .{ .name = name, .source = .discovered };
    }

    fn readCachedDeviceName(self: Runtime) !?[]u8 {
        const path = try self.deviceCachePath() orelse return null;
        defer self.allocator.free(path);

        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(4096)) catch return null;
        defer self.allocator.free(data);
        return parseCachedDeviceName(self.allocator, data);
    }

    fn writeCachedDeviceName(self: Runtime, device_name: []const u8) void {
        const start = monotonicNowNs();
        var detail: []const u8 = "error";
        defer self.emitTimingSince("linux.cache.write", start, detail);

        const path = self.deviceCachePath() catch return;
        const cache_path = path orelse {
            detail = "disabled";
            return;
        };
        defer self.allocator.free(cache_path);

        const data = serializeDeviceCache(self.allocator, device_name) catch return;
        defer self.allocator.free(data);

        if (std.fs.path.dirname(cache_path)) |dir_name| {
            std.Io.Dir.cwd().createDirPath(self.io, dir_name) catch return;
        }
        std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = cache_path,
            .data = data,
            .flags = .{ .truncate = true },
        }) catch return;
        detail = "ok";
    }

    fn deviceCachePath(self: Runtime) !?[]u8 {
        if (self.environ_map.get("V600_SCANNER_DEVICE_CACHE")) |path| {
            if (path.len != 0) return try self.allocator.dupe(u8, path);
        }
        if (self.environ_map.get("XDG_CACHE_HOME")) |cache_home| {
            if (cache_home.len != 0) {
                return try std.fmt.allocPrint(self.allocator, "{s}/v600/scanner-device.txt", .{cache_home});
            }
        }
        if (self.environ_map.get("HOME")) |home| {
            if (home.len != 0) {
                return try std.fmt.allocPrint(self.allocator, "{s}/.cache/v600/scanner-device.txt", .{home});
            }
        }
        return null;
    }

    pub fn usbReset(self: Runtime) !UsbResetOutcome {
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

        var bus: usize = 1;
        while (bus <= 10) : (bus += 1) {
            var dev: usize = 1;
            while (dev < 128) : (dev += 1) {
                const path = try usbDevicePath(self.allocator, bus, dev);
                const device_id = self.readUsbDeviceId(path) catch null;
                if (device_id) |id| {
                    if (isV600UsbDevice(id)) {
                        return self.resetUsbDevicePath(path);
                    }
                }
                self.allocator.free(path);
            }
        }

        return .{ .status = .device_not_found };
    }

    fn readUsbDeviceId(self: Runtime, path: []const u8) !?UsbDeviceId {
        var file = std.Io.Dir.openFileAbsolute(self.io, path, .{
            .mode = .read_only,
            .allow_directory = false,
        }) catch return null;
        defer file.close(self.io);

        var buffer: [18]u8 = undefined;
        var reader = file.readerStreaming(self.io, &.{});
        const n = reader.interface.readSliceShort(&buffer) catch return null;
        return parseUsbDeviceDescriptor(buffer[0..n]);
    }

    fn resetUsbDevicePath(self: Runtime, path: []u8) !UsbResetOutcome {
        errdefer self.allocator.free(path);

        var file = std.Io.Dir.openFileAbsolute(self.io, path, .{
            .mode = .read_write,
            .allow_directory = false,
        }) catch |err| switch (err) {
            error.AccessDenied => return .{ .status = .permission_denied, .path = path },
            else => return .{ .status = .reset_failed, .path = path },
        };
        defer file.close(self.io);

        const rc = std.posix.system.ioctl(file.handle, usbdevfs_reset, @as(usize, 0));
        switch (std.posix.system.errno(rc)) {
            .SUCCESS => {
                sleepAfterUsbReset();
                return .{ .status = .reset_performed, .path = path };
            },
            .ACCES, .PERM => return .{ .status = .permission_denied, .path = path },
            else => return .{ .status = .reset_failed, .path = path },
        }
    }
};

pub const ScanOptions = struct {
    request: contracts.ScanRequest,
    output_path: []const u8,
    metadata_path: ?[]const u8 = null,
    device_name: ?[]const u8 = null,
    cancel_file: ?[]const u8 = null,
    capabilities: ?contracts.ScannerCapabilities = null,
};

const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool = false,

    fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        if (self.stdout.len != 0) allocator.free(self.stdout);
        if (self.stderr.len != 0) allocator.free(self.stderr);
    }

    fn succeeded(self: RunResult) bool {
        if (self.timed_out) return false;
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

// Python's estimate (10 s plus 2 s per megapixel, tripled at 3200 dpi and
// above); scanimage gets twice that, and at least five minutes.
fn scanTimeoutMs(request: contracts.ScanRequest, effective_dpi: u32, source: contracts.Source, caps: contracts.ScannerCapabilities) u64 {
    const full_width_in = if (source == .tpu) caps.tpu_width_in else caps.flatbed_width_in;
    const full_height_in = if (source == .tpu) caps.tpu_height_in else caps.flatbed_height_in;
    const dpi: f64 = @floatFromInt(effective_dpi);
    const width_px = (request.area.width orelse full_width_in) * dpi;
    const height_px = (request.area.height orelse full_height_in) * dpi;
    var estimate_s = 10.0 + width_px * height_px / 1_000_000.0 * 2.0;
    if (effective_dpi >= 3200) estimate_s *= 3.0;
    return @intFromFloat(@max(300.0, estimate_s * 2.0) * std.time.ms_per_s);
}

const CombinedPassDpis = struct {
    rgb: u32,
    ir: u32,
};

fn combinedPassDpis(request: contracts.ScanRequest) CombinedPassDpis {
    var rgb_request = request;
    rgb_request.kind = .rgb;
    rgb_request.depth = .sixteen;
    rgb_request.source = if (request.source == .flatbed) .flatbed else .tpu;

    var ir_request = request;
    ir_request.kind = .ir;
    ir_request.depth = .eight;
    ir_request.source = .tpu;
    ir_request.dpi = @min(request.dpi, 3200);

    return .{
        .rgb = sane.effectiveDpiForRequest(rgb_request),
        .ir = sane.effectiveDpiForRequest(ir_request),
    };
}

fn runCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
) !RunResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(8 * 1024 * 1024),
        .environ_map = environ_map,
        .expand_arg0 = .expand,
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn parseDeviceList(allocator: std.mem.Allocator, output: []const u8) ![]Device {
    var devices = std.array_list.Managed(Device).init(allocator);
    errdefer {
        for (devices.items) |device| freeDevice(allocator, device);
        devices.deinit();
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "device `")) continue;
        const name = between(line, "`", "'") orelse continue;
        var device = Device{
            .name = try allocator.dupe(u8, name),
            .raw_line = try allocator.dupe(u8, line),
        };
        errdefer freeDevice(allocator, device);

        const is_pos = std.mem.indexOf(u8, line, " is a ");
        if (is_pos) |pos| {
            const desc = line[pos + " is a ".len ..];
            var parts = std.mem.splitScalar(u8, desc, ' ');
            if (parts.next()) |vendor| device.vendor = try allocator.dupe(u8, vendor);
            if (parts.next()) |model| device.model = try allocator.dupe(u8, model);
            if (std.mem.lastIndexOfScalar(u8, desc, ' ')) |last_space| {
                device.kind = try allocator.dupe(u8, desc[last_space + 1 ..]);
            }
        }

        try devices.append(device);
    }

    return devices.toOwnedSlice();
}

pub fn freeDevices(allocator: std.mem.Allocator, devices: []Device) void {
    for (devices) |device| freeDevice(allocator, device);
    allocator.free(devices);
}

fn freeDevice(allocator: std.mem.Allocator, device: Device) void {
    allocator.free(device.name);
    if (device.vendor.len != 0) allocator.free(device.vendor);
    if (device.model.len != 0) allocator.free(device.model);
    if (device.kind.len != 0) allocator.free(device.kind);
    if (device.raw_line.len != 0) allocator.free(device.raw_line);
}

pub fn selectDevice(devices: []const Device) ?Device {
    return selectDeviceForKind(devices, .rgb);
}

pub fn selectDeviceForKind(devices: []const Device, kind: contracts.ScanKind) ?Device {
    var selected: ?Device = null;
    for (devices) |device| {
        if (!device.looksLikeV600()) continue;
        if (!device.canUseForKind(kind)) continue;
        if (selected == null or device.backendRankForKind(kind) < selected.?.backendRankForKind(kind)) {
            selected = device;
        }
    }
    return selected;
}

pub fn chooseDeviceName(
    allocator: std.mem.Allocator,
    devices: []const Device,
    cached_name: ?[]const u8,
    explicit_name: ?[]const u8,
) !?DeviceChoice {
    return chooseDeviceNameForKind(allocator, devices, cached_name, explicit_name, .rgb);
}

pub fn chooseDeviceNameForKind(
    allocator: std.mem.Allocator,
    devices: []const Device,
    cached_name: ?[]const u8,
    explicit_name: ?[]const u8,
    kind: contracts.ScanKind,
) !?DeviceChoice {
    if (explicit_name) |name| {
        return .{ .name = try allocator.dupe(u8, name), .source = .explicit };
    }
    if (cached_name) |name| {
        if (cachedDeviceUsableForKind(name, kind) and deviceListContains(devices, name)) {
            return .{ .name = try allocator.dupe(u8, name), .source = .cache_hit };
        }
    }
    if (selectDeviceForKind(devices, kind)) |selected| {
        return .{ .name = try allocator.dupe(u8, selected.name), .source = .discovered };
    }
    return null;
}

pub fn serializeDeviceCache(allocator: std.mem.Allocator, device_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ cache_header, device_name });
}

pub fn parseCachedDeviceName(allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const header = lines.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, header, " \t\r"), cache_header)) return null;
    const raw_name = lines.next() orelse return null;
    const name = std.mem.trim(u8, raw_name, " \t\r");
    if (name.len == 0) return null;
    return try allocator.dupe(u8, name);
}

fn deviceListContains(devices: []const Device, device_name: []const u8) bool {
    for (devices) |device| {
        if (std.mem.eql(u8, device.name, device_name)) return true;
    }
    return false;
}

pub fn tiffMetadataTags(caps: contracts.ScannerCapabilities) [3]TiffMetadataTagValue {
    return .{
        .{ .tag = .make, .value = "EPSON" },
        .{ .tag = .model, .value = if (caps.model.len == 0) "Epson Scanner" else caps.model },
        .{ .tag = .software, .value = tiff_software },
    };
}

pub fn parseUsbDeviceDescriptor(descriptor: []const u8) ?UsbDeviceId {
    if (descriptor.len < 18) return null;
    return .{
        .vendor_id = std.mem.readInt(u16, descriptor[8..10], .little),
        .product_id = std.mem.readInt(u16, descriptor[10..12], .little),
    };
}

pub fn isV600UsbDevice(device_id: UsbDeviceId) bool {
    return device_id.vendor_id == v600_vendor_id_int and device_id.product_id == v600_product_id_int;
}

pub fn usbDevicePath(allocator: std.mem.Allocator, bus: usize, dev: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "/dev/bus/usb/{d:0>3}/{d:0>3}", .{ bus, dev });
}

pub fn usbResetStatusName(status: UsbResetStatus) []const u8 {
    return switch (status) {
        .reset_performed => "reset-performed",
        .device_not_found => "device-not-found",
        .permission_denied => "permission-denied",
        .reset_failed => "reset-failed",
    };
}

fn sleepAfterUsbReset() void {
    var remaining = std.posix.timespec{ .sec = 2, .nsec = 0 };
    while (true) {
        switch (std.posix.system.errno(std.posix.system.nanosleep(&remaining, &remaining))) {
            .SUCCESS => return,
            .INTR => continue,
            else => return,
        }
    }
}

pub fn shouldMirrorTiff(source: contracts.Source) bool {
    return source == .tpu;
}

fn tiffTagNumber(tag: TiffMetadataTag) []const u8 {
    return switch (tag) {
        .make => "271",
        .model => "272",
        .software => "305",
    };
}

pub fn parseProgress(line_or_chunk: []const u8) ?ProgressEvent {
    var cursor: usize = 0;
    while (cursor < line_or_chunk.len) {
        while (cursor < line_or_chunk.len and !std.ascii.isDigit(line_or_chunk[cursor])) cursor += 1;
        const start = cursor;
        while (cursor < line_or_chunk.len and std.ascii.isDigit(line_or_chunk[cursor])) cursor += 1;
        const integer_end = cursor;
        if (cursor > start and cursor < line_or_chunk.len and line_or_chunk[cursor] == '.') {
            while (cursor < line_or_chunk.len and (std.ascii.isDigit(line_or_chunk[cursor]) or line_or_chunk[cursor] == '.')) cursor += 1;
        }
        if (cursor > start and cursor < line_or_chunk.len and line_or_chunk[cursor] == '%') {
            const value = std.fmt.parseInt(u8, line_or_chunk[start..integer_end], 10) catch return null;
            return .{ .percent = @min(value, 100) };
        }
    }
    return null;
}

pub fn classifyFailure(stderr: []const u8) FailureKind {
    if (containsAny(stderr, &.{ "Device busy", "device busy", "Resource busy", "resource busy" })) return .device_busy;
    if (containsAny(stderr, &.{ "Access denied", "Permission denied", "permission denied", "Operation not permitted", "insufficient permissions" })) return .permission_denied;
    if (containsAny(stderr, &.{ "No scanners were identified", "No such device", "no such device", "open of device" })) return .no_device;
    if (containsAny(stderr, &.{ "Unknown option", "unknown option", "unrecognized option", "Unsupported option", "unsupported option", "Invalid argument" })) return .unsupported_option;
    if (containsAny(stderr, &.{ "paper jam", "Paper jam", "jammed", "Jammed" })) return .paper_jam;
    if (containsAny(stderr, &.{ "cancel", "Cancel" })) return .cancelled;
    if (containsAny(stderr, &.{ "Error during device I/O", "I/O error", "backend error", "Backend error", "sane_start", "sane_read" })) return .backend_failure;
    return .scanimage_failed;
}

pub fn cancelFileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn cancelState(cancel_file: ?[]const u8, file_exists: bool) contracts.CancelState {
    return if (cancel_file != null and file_exists) .cancel_requested else .keep_scanning;
}

fn addProgressFlag(allocator: std.mem.Allocator, plan: *sane.CommandPlan) !void {
    try plan.argv.insert(allocator, 1, "--progress");
}

fn prepareEnvironment(
    allocator: std.mem.Allocator,
    parent: *std.process.Environ.Map,
    env: sane.EnvironmentPlan,
    storage: *?std.process.Environ.Map,
) !?*const std.process.Environ.Map {
    if (!env.scan_ir_mode and env.lut_file == null) return null;
    storage.* = try parent.clone(allocator);
    if (env.scan_ir_mode) try storage.*.?.put("SCAN_IR_MODE", "1");
    if (env.lut_file) |lut_file| try storage.*.?.put("V600_LUT_FILE", lut_file);
    return &storage.*.?;
}

fn emitProgressFromChunk(self: Runtime, chunk: []const u8) !void {
    var cursor: usize = 0;
    while (cursor < chunk.len) {
        while (cursor < chunk.len and !std.ascii.isDigit(chunk[cursor])) cursor += 1;
        const start = cursor;
        while (cursor < chunk.len and std.ascii.isDigit(chunk[cursor])) cursor += 1;
        const integer_end = cursor;
        if (cursor > start and cursor < chunk.len and chunk[cursor] == '.') {
            while (cursor < chunk.len and (std.ascii.isDigit(chunk[cursor]) or chunk[cursor] == '.')) cursor += 1;
        }
        if (cursor <= start or cursor >= chunk.len or chunk[cursor] != '%') {
            if (cursor == start) cursor += 1;
            continue;
        }
        const raw = std.fmt.parseInt(u8, chunk[start..integer_end], 10) catch {
            cursor += 1;
            continue;
        };
        const progress = ProgressEvent{ .percent = @min(raw, 100) };
        self.emitProgress(progress);
        cursor += 1;
    }
}

fn writeMetadataSidecar(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ScanOptions,
    caps: contracts.ScannerCapabilities,
    plan: *const sane.CommandPlan,
) ![]u8 {
    const metadata_path = if (options.metadata_path) |path|
        try allocator.dupe(u8, path)
    else
        try std.fmt.allocPrint(allocator, "{s}.json", .{options.output_path});
    errdefer allocator.free(metadata_path);

    var file = try std.Io.Dir.cwd().createFile(io, metadata_path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const out = &writer.interface;

    try out.print(
        \\{{
        \\  "software": "v600-zig",
        \\  "device": "{s}",
        \\  "model": "{s}",
        \\  "source": "{t}",
        \\  "kind": "{t}",
        \\  "requested_dpi": {d},
        \\  "effective_dpi": {d},
        \\  "depth": {d},
        \\  "output": "{s}",
        \\  "custom_luts_applied": {any},
        \\  "tiff_metadata": {{
        \\    "make": "EPSON",
        \\    "model": "{s}",
        \\    "software": "{s}"
        \\  }},
        \\  "argv": [
        \\
    , .{
        caps.device_name,
        caps.model,
        plan.source,
        plan.kind,
        plan.original_dpi,
        plan.effective_dpi,
        @intFromEnum(options.request.depth),
        options.output_path,
        customLutsApplied(options.request),
        if (caps.model.len == 0) "Epson Scanner" else caps.model,
        tiff_software,
    });
    for (plan.argv.items, 0..) |arg, i| {
        try out.print("    \"{s}\"{s}\n", .{ arg, if (i + 1 == plan.argv.items.len) "" else "," });
    }
    try out.print("  ]\n}}\n", .{});
    try out.flush();
    return metadata_path;
}

fn writeCombinedMetadataSidecar(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ScanOptions,
    device_name: []const u8,
    pass_dpis: CombinedPassDpis,
) ![]u8 {
    const metadata_path = if (options.metadata_path) |path|
        try allocator.dupe(u8, path)
    else
        try std.fmt.allocPrint(allocator, "{s}.json", .{options.output_path});
    errdefer allocator.free(metadata_path);

    var file = try std.Io.Dir.cwd().createFile(io, metadata_path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const out = &writer.interface;

    try out.print(
        \\{{
        \\  "software": "v600-zig",
        \\  "device": "{s}",
        \\  "model": "Epson Perfection V600 Photo",
        \\  "source": "{t}",
        \\  "kind": "rgb+ir",
        \\  "requested_dpi": {d},
        \\  "effective_dpi": {d},
        \\  "rgb_effective_dpi": {d},
        \\  "ir_effective_dpi": {d},
        \\  "depth": 16,
        \\  "output": "{s}",
        \\  "custom_luts_applied": {any},
        \\  "tiff_metadata": {{
        \\    "make": "EPSON",
        \\    "model": "Epson Perfection V600 Photo",
        \\    "software": "{s}"
        \\  }},
        \\  "pages": [
        \\    {{"index": 0, "kind": "rgb"}},
        \\    {{"index": 1, "kind": "thumbnail"}},
        \\    {{"index": 2, "kind": "ir"}}
        \\  ]
        \\}}
        \\
    , .{
        device_name,
        options.request.source,
        options.request.dpi,
        pass_dpis.rgb,
        pass_dpis.rgb,
        pass_dpis.ir,
        options.output_path,
        customLutsApplied(options.request),
        tiff_software,
    });
    try out.flush();
    return metadata_path;
}

fn deleteIfExists(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn customLutsApplied(request: contracts.ScanRequest) bool {
    return switch (request.kind) {
        .rgb, .rgb_ir => request.lut_file_path != null,
        .gray, .ir => false,
    };
}

fn replaceFile(io: std.Io, old_path: []const u8, new_path: []const u8) !void {
    if (std.fs.path.isAbsolute(old_path) or std.fs.path.isAbsolute(new_path)) {
        try std.Io.Dir.renameAbsolute(old_path, new_path, io);
    } else {
        const cwd = std.Io.Dir.cwd();
        try cwd.rename(old_path, cwd, new_path, io);
    }
}

fn commandExistsScript(command: []const u8) []const u8 {
    if (std.mem.eql(u8, command, "scanimage-v600")) return "command -v scanimage-v600 >/dev/null 2>&1";
    if (std.mem.eql(u8, command, "scanimage-v600-ir")) return "command -v scanimage-v600-ir >/dev/null 2>&1";
    return "false";
}

fn isScanimageCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "scanimage") or
        std.mem.eql(u8, command, "scanimage-v600") or
        std.mem.eql(u8, command, "scanimage-v600-ir");
}

fn cachedDeviceUsableForKind(device_name: []const u8, kind: contracts.ScanKind) bool {
    return switch (kind) {
        .ir, .rgb_ir => std.mem.indexOf(u8, device_name, "epkowa") != null,
        .rgb, .gray => true,
    };
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn between(haystack: []const u8, left: []const u8, right: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, haystack, left) orelse return null;
    const body_start = start + left.len;
    const end_rel = std.mem.indexOf(u8, haystack[body_start..], right) orelse return null;
    return haystack[body_start .. body_start + end_rel];
}

fn expectDeviceName(device: ?Device, expected: []const u8) !void {
    try std.testing.expect(device != null);
    try std.testing.expectEqualStrings(expected, device.?.name);
}

test "parses scanimage device list and selects preferred V600 backend" {
    const allocator = std.testing.allocator;
    const output =
        \\device `epkowa:interpreter:001:017' is a Epson (unknown model) flatbed scanner
        \\device `epson2:libusb:001:018' is a Epson V600 flatbed scanner
        \\
    ;
    const devices = try parseDeviceList(allocator, output);
    defer freeDevices(allocator, devices);
    try std.testing.expectEqual(@as(usize, 2), devices.len);
    try expectDeviceName(selectDevice(devices), "epson2:libusb:001:018");
}

test "selects epkowa interpreter backend for IR-capable scan kinds" {
    const allocator = std.testing.allocator;
    const output =
        \\device `epkowa:interpreter:001:017' is a Epson (unknown model) flatbed scanner
        \\device `epson2:libusb:001:018' is a Epson V600 flatbed scanner
        \\
    ;
    const devices = try parseDeviceList(allocator, output);
    defer freeDevices(allocator, devices);
    try expectDeviceName(selectDeviceForKind(devices, .ir), "epkowa:interpreter:001:017");
    try expectDeviceName(selectDeviceForKind(devices, .rgb_ir), "epkowa:interpreter:001:017");
}

test "accepts live epkowa interpreter listing when model text is unknown" {
    const allocator = std.testing.allocator;
    const output =
        \\device `epkowa:interpreter:001:017' is a Epson (unknown model) flatbed scanner
        \\
    ;
    const devices = try parseDeviceList(allocator, output);
    defer freeDevices(allocator, devices);
    try expectDeviceName(selectDevice(devices), "epkowa:interpreter:001:017");
}

test "serializes and parses persistent scanner device cache" {
    const allocator = std.testing.allocator;
    const data = try serializeDeviceCache(allocator, "epkowa:interpreter:001:017");
    defer allocator.free(data);
    const parsed = (try parseCachedDeviceName(allocator, data)).?;
    defer allocator.free(parsed);
    try std.testing.expectEqualStrings("epkowa:interpreter:001:017", parsed);
    try std.testing.expect((try parseCachedDeviceName(allocator, "not-a-v600-cache\nfoo\n")) == null);
}

test "chooses explicit device over cache and discovery" {
    const allocator = std.testing.allocator;
    const devices = try parseDeviceList(allocator,
        \\device `epkowa:interpreter:001:017' is a Epson Perfection V600 Photo flatbed scanner
        \\
    );
    defer freeDevices(allocator, devices);
    const choice = (try chooseDeviceName(allocator, devices, "epkowa:interpreter:001:017", "manual:device")).?;
    defer choice.deinit(allocator);
    try std.testing.expectEqual(DeviceChoiceSource.explicit, choice.source);
    try std.testing.expectEqualStrings("manual:device", choice.name);
}

test "uses cache hit when cached device is still present" {
    const allocator = std.testing.allocator;
    const devices = try parseDeviceList(allocator,
        \\device `epkowa:interpreter:001:017' is a Epson Perfection V600 Photo flatbed scanner
        \\
    );
    defer freeDevices(allocator, devices);
    const choice = (try chooseDeviceName(allocator, devices, "epkowa:interpreter:001:017", null)).?;
    defer choice.deinit(allocator);
    try std.testing.expectEqual(DeviceChoiceSource.cache_hit, choice.source);
    try std.testing.expectEqualStrings("epkowa:interpreter:001:017", choice.name);
}

test "ignores stale cache and falls back to discovered V600 device" {
    const allocator = std.testing.allocator;
    const devices = try parseDeviceList(allocator,
        \\device `epkowa:interpreter:001:018' is a Epson Perfection V600 Photo flatbed scanner
        \\
    );
    defer freeDevices(allocator, devices);
    const choice = (try chooseDeviceName(allocator, devices, "epkowa:interpreter:001:017", null)).?;
    defer choice.deinit(allocator);
    try std.testing.expectEqual(DeviceChoiceSource.discovered, choice.source);
    try std.testing.expectEqualStrings("epkowa:interpreter:001:018", choice.name);
}

test "ignores epson2 cache for IR scans and discovers epkowa" {
    const allocator = std.testing.allocator;
    const devices = try parseDeviceList(allocator,
        \\device `epkowa:interpreter:001:017' is a Epson Perfection V600 Photo flatbed scanner
        \\device `epson2:libusb:001:018' is a Epson V600 flatbed scanner
        \\
    );
    defer freeDevices(allocator, devices);
    const choice = (try chooseDeviceNameForKind(allocator, devices, "epson2:libusb:001:018", null, .rgb_ir)).?;
    defer choice.deinit(allocator);
    try std.testing.expectEqual(DeviceChoiceSource.discovered, choice.source);
    try std.testing.expectEqualStrings("epkowa:interpreter:001:017", choice.name);
}

const NullWriter = struct {
    pub fn print(_: *NullWriter, comptime fmt: []const u8, args: anytype) !void {
        _ = fmt;
        _ = args;
    }
};

const RecordedScannerEvent = union(enum) {
    name: events.EventName,
    timing_stage: []const u8,
};

const ScannerEventRecorder = struct {
    entries: [64]RecordedScannerEvent = undefined,
    len: usize = 0,

    fn record(self: *ScannerEventRecorder, entry: RecordedScannerEvent) void {
        if (self.len < self.entries.len) {
            self.entries[self.len] = entry;
            self.len += 1;
        }
    }

    fn indexOfTiming(self: ScannerEventRecorder, stage: []const u8) ?usize {
        for (self.entries[0..self.len], 0..) |entry, index| {
            switch (entry) {
                .timing_stage => |value| if (std.mem.eql(u8, value, stage)) return index,
                else => {},
            }
        }
        return null;
    }

    fn indexOfName(self: ScannerEventRecorder, name: events.EventName) ?usize {
        for (self.entries[0..self.len], 0..) |entry, index| {
            switch (entry) {
                .name => |value| if (value == name) return index,
                else => {},
            }
        }
        return null;
    }
};

fn recordScannerEvent(raw_context: *anyopaque, event: events.Event) void {
    const recorder: *ScannerEventRecorder = @ptrCast(@alignCast(raw_context));
    switch (event) {
        .startup => recorder.record(.{ .name = .startup }),
        .device_discovery => recorder.record(.{ .name = .device_discovery }),
        .probe => recorder.record(.{ .name = .probe }),
        .scan_start => recorder.record(.{ .name = .scan_start }),
        .progress => recorder.record(.{ .name = .progress }),
        .scan_complete => recorder.record(.{ .name = .scan_complete }),
        .scan_cancelled => recorder.record(.{ .name = .scan_cancelled }),
        .scan_error => recorder.record(.{ .name = .scan_error }),
        .timing => |timing| recorder.record(.{ .timing_stage = timing.stage }),
    }
}

fn expectTimingBefore(recorder: ScannerEventRecorder, before: []const u8, after: []const u8) !void {
    const before_index = recorder.indexOfTiming(before) orelse return error.MissingBeforeTiming;
    const after_index = recorder.indexOfTiming(after) orelse return error.MissingAfterTiming;
    try std.testing.expect(before_index < after_index);
}

fn expectEventBeforeTiming(recorder: ScannerEventRecorder, event_name: events.EventName, stage: []const u8) !void {
    const event_index = recorder.indexOfName(event_name) orelse return error.MissingEvent;
    const timing_index = recorder.indexOfTiming(stage) orelse return error.MissingTiming;
    try std.testing.expect(event_index < timing_index);
}

fn expectTimingBeforeEvent(recorder: ScannerEventRecorder, stage: []const u8, event_name: events.EventName) !void {
    const timing_index = recorder.indexOfTiming(stage) orelse return error.MissingTiming;
    const event_index = recorder.indexOfName(event_name) orelse return error.MissingEvent;
    try std.testing.expect(timing_index < event_index);
}

test "probe emits timing events around fake discovery and capabilities" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\#!/bin/sh
        \\if [ "$1" = "-L" ]; then
        \\cat <<'LIST'
        \\device `epkowa:interpreter:001:017' is a Epson Perfection V600 Photo flatbed scanner
        \\LIST
        \\exit 0
        \\fi
        \\case "$*" in
        \\  *"Transparency Unit"*)
        \\cat <<'TPU'
        \\Options specific to device `epkowa:interpreter:001:017':
        \\    --resolution 400|800|1600|3200dpi [400]
        \\    -x 0..68.58mm [68.58]
        \\    -y 0..242.316mm [242.316]
        \\    --source Flatbed|Transparency Unit [Transparency Unit]
        \\TPU
        \\    ;;
        \\  *)
        \\cat <<'FLATBED'
        \\Options specific to device `epkowa:interpreter:001:017':
        \\    --resolution 400|800|1600|3200dpi [400]
        \\    -x 0..215.9mm [215.9]
        \\    -y 0..297.18mm [297.18]
        \\    --source Flatbed|Transparency Unit [Flatbed]
        \\FLATBED
        \\    ;;
        \\esac
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scanimage", .data = script });
    try tmp.dir.setFilePermissions(std.testing.io, "scanimage", .executable_file, .{});

    const fake_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(fake_dir);
    const script_path = try std.fmt.allocPrint(allocator, "{s}/scanimage", .{fake_dir});
    defer allocator.free(script_path);
    const cache_path = try std.fmt.allocPrint(allocator, "{s}/device-cache.txt", .{fake_dir});
    defer allocator.free(cache_path);

    var environ_map = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer environ_map.deinit();
    try environ_map.put("V600_SCANNER_DEVICE_CACHE", cache_path);

    var recorder = ScannerEventRecorder{};
    const runtime = Runtime{
        .allocator = allocator,
        .io = std.testing.io,
        .environ_map = &environ_map,
        .scanimage_command = script_path,
        .event_sink = .{
            .context = &recorder,
            .emit = recordScannerEvent,
        },
    };

    var out = NullWriter{};
    const caps = try runtime.probe(&out);
    try std.testing.expectEqual(@as(u32, 3200), caps.max_resolution);

    try expectEventBeforeTiming(recorder, .startup, "linux.discover.scanimage_list");
    try expectTimingBefore(recorder, "linux.discover.scanimage_list", "linux.discover.parse_device_list");
    try expectTimingBefore(recorder, "linux.discover.parse_device_list", "linux.discover.select_device");
    try expectTimingBefore(recorder, "linux.discover.select_device", "linux.discover.total");
    try expectTimingBefore(recorder, "linux.probe.discover_devices", "linux.probe.select_device");
    try expectTimingBefore(recorder, "linux.probe.select_device", "linux.cache.write");
    try expectTimingBefore(recorder, "linux.probe.cache_write", "linux.capabilities.help.flatbed");
    try expectTimingBefore(recorder, "linux.capabilities.help.flatbed", "linux.capabilities.help.tpu");
    try expectTimingBefore(recorder, "linux.capabilities.help.tpu", "linux.probe.parse_combined_capabilities");
    try expectTimingBeforeEvent(recorder, "linux.probe.parse_combined_capabilities", .probe);
    try expectEventBeforeTiming(recorder, .probe, "linux.probe.total");
}

test "resolve device emits cache-hit timing without discovery" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cache_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/device-cache.txt", .{tmp.sub_path[0..]});
    defer allocator.free(cache_path);
    const cache_data = try serializeDeviceCache(allocator, "epkowa:interpreter:001:017");
    defer allocator.free(cache_data);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "device-cache.txt", .data = cache_data });

    var environ_map = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer environ_map.deinit();
    try environ_map.put("V600_SCANNER_DEVICE_CACHE", cache_path);

    var recorder = ScannerEventRecorder{};
    const runtime = Runtime{
        .allocator = allocator,
        .io = std.testing.io,
        .environ_map = &environ_map,
        .event_sink = .{
            .context = &recorder,
            .emit = recordScannerEvent,
        },
    };

    const choice = try runtime.resolveDeviceName(null, .rgb);
    defer choice.deinit(allocator);

    try std.testing.expectEqual(DeviceChoiceSource.cache_hit, choice.source);
    try std.testing.expectEqualStrings("epkowa:interpreter:001:017", choice.name);
    try std.testing.expect(recorder.indexOfTiming("linux.resolve.cache_lookup") != null);
    try std.testing.expect(recorder.indexOfName(.device_discovery) != null);
    try std.testing.expect(recorder.indexOfTiming("linux.discover.total") == null);
}

test "failed fake discovery keeps device-discovery event and timing diagnostics" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\#!/bin/sh
        \\printf 'No scanners were identified\n' >&2
        \\exit 1
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scanimage", .data = script });
    try tmp.dir.setFilePermissions(std.testing.io, "scanimage", .executable_file, .{});

    const fake_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(fake_dir);
    const script_path = try std.fmt.allocPrint(allocator, "{s}/scanimage", .{fake_dir});
    defer allocator.free(script_path);

    var environ_map = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer environ_map.deinit();

    var recorder = ScannerEventRecorder{};
    const runtime = Runtime{
        .allocator = allocator,
        .io = std.testing.io,
        .environ_map = &environ_map,
        .scanimage_command = script_path,
        .event_sink = .{
            .context = &recorder,
            .emit = recordScannerEvent,
        },
    };

    try std.testing.expectError(error.ScanimageListFailed, runtime.discoverDevices());
    try std.testing.expect(recorder.indexOfName(.device_discovery) != null);
    try std.testing.expect(recorder.indexOfTiming("linux.discover.scanimage_list") != null);
    try std.testing.expect(recorder.indexOfTiming("linux.discover.total") != null);
    try expectTimingBefore(recorder, "linux.discover.scanimage_list", "linux.discover.total");
}

test "parses scanimage progress chunks" {
    try std.testing.expectEqual(@as(u8, 37), parseProgress("Progress: 37.2%").?.percent);
    try std.testing.expectEqual(@as(u8, 100), parseProgress("\r100%").?.percent);
    try std.testing.expect(parseProgress("warming up") == null);
}

test "maps TIFF metadata tags to Python SANE parity values" {
    const tags = tiffMetadataTags(.{ .model = "Epson Perfection V600 Photo" });
    try std.testing.expectEqual(TiffMetadataTag.make, tags[0].tag);
    try std.testing.expectEqualStrings("271", tiffTagNumber(tags[0].tag));
    try std.testing.expectEqualStrings("EPSON", tags[0].value);
    try std.testing.expectEqual(TiffMetadataTag.model, tags[1].tag);
    try std.testing.expectEqualStrings("272", tiffTagNumber(tags[1].tag));
    try std.testing.expectEqualStrings("Epson Perfection V600 Photo", tags[1].value);
    try std.testing.expectEqual(TiffMetadataTag.software, tags[2].tag);
    try std.testing.expectEqualStrings("305", tiffTagNumber(tags[2].tag));
    try std.testing.expectEqualStrings("epdaughter-sane", tags[2].value);

    const fallback = tiffMetadataTags(.{ .model = "" });
    try std.testing.expectEqualStrings("Epson Scanner", fallback[1].value);
}

test "parses USB descriptors and matches Epson V600 product id" {
    var descriptor = [_]u8{0} ** 18;
    descriptor[8] = 0xb8;
    descriptor[9] = 0x04;
    descriptor[10] = 0x3a;
    descriptor[11] = 0x01;

    const device_id = parseUsbDeviceDescriptor(&descriptor).?;
    try std.testing.expectEqual(@as(u16, 0x04b8), device_id.vendor_id);
    try std.testing.expectEqual(@as(u16, 0x013a), device_id.product_id);
    try std.testing.expect(isV600UsbDevice(device_id));

    descriptor[10] = 0xff;
    try std.testing.expect(!isV600UsbDevice(parseUsbDeviceDescriptor(&descriptor).?));
    try std.testing.expect(parseUsbDeviceDescriptor(descriptor[0..17]) == null);
}

test "formats Linux USB device paths like Python fallback scanner reset" {
    const allocator = std.testing.allocator;
    const path = try usbDevicePath(allocator, 1, 7);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/dev/bus/usb/001/007", path);
}

test "names USB reset outcomes for explicit CLI reporting" {
    try std.testing.expectEqualStrings("reset-performed", usbResetStatusName(.reset_performed));
    try std.testing.expectEqualStrings("device-not-found", usbResetStatusName(.device_not_found));
    try std.testing.expectEqualStrings("permission-denied", usbResetStatusName(.permission_denied));
    try std.testing.expectEqualStrings("reset-failed", usbResetStatusName(.reset_failed));
}

test "mirrors only TPU TIFF outputs" {
    try std.testing.expect(shouldMirrorTiff(.tpu));
    try std.testing.expect(!shouldMirrorTiff(.flatbed));
}

test "marks custom LUT metadata only for RGB-bearing scan requests" {
    try std.testing.expect(customLutsApplied(.{ .kind = .rgb, .lut_file_path = "/tmp/lut.bin" }));
    try std.testing.expect(customLutsApplied(.{ .kind = .rgb_ir, .lut_file_path = "/tmp/lut.bin" }));
    try std.testing.expect(!customLutsApplied(.{ .kind = .gray, .lut_file_path = "/tmp/lut.bin" }));
    try std.testing.expect(!customLutsApplied(.{ .kind = .ir, .lut_file_path = "/tmp/lut.bin" }));
    try std.testing.expect(!customLutsApplied(.{ .kind = .rgb }));
}

test "classifies common scan failures" {
    try std.testing.expectEqual(FailureKind.device_busy, classifyFailure("open of device failed: Device busy"));
    try std.testing.expectEqual(FailureKind.no_device, classifyFailure("No scanners were identified"));
    try std.testing.expectEqual(FailureKind.permission_denied, classifyFailure("open of device failed: Access denied"));
    try std.testing.expectEqual(FailureKind.unsupported_option, classifyFailure("setting of option --source failed: Invalid argument"));
    try std.testing.expectEqual(FailureKind.paper_jam, classifyFailure("sane_read: Document feeder jammed"));
    try std.testing.expectEqual(FailureKind.cancelled, classifyFailure("scan cancelled by user"));
    try std.testing.expectEqual(FailureKind.backend_failure, classifyFailure("sane_start: Error during device I/O"));
    try std.testing.expectEqual(FailureKind.scanimage_failed, classifyFailure("unexpected scanner diagnostic"));
}

test "maps cancel file observation to scanner cancel state" {
    try std.testing.expectEqual(contracts.CancelState.keep_scanning, cancelState(null, true));
    try std.testing.expectEqual(contracts.CancelState.keep_scanning, cancelState("cancel", false));
    try std.testing.expectEqual(contracts.CancelState.cancel_requested, cancelState("cancel", true));
}

test "adds progress flag without changing command semantics" {
    const allocator = std.testing.allocator;
    const caps = contracts.ScannerCapabilities{ .device_name = "epkowa:interpreter:001:017" };
    const request = contracts.ScanRequest{ .dpi = 400, .source = .tpu, .kind = .rgb, .output_path = "out.tiff" };
    var plan = try sane.planCommand(allocator, request, caps, .{ .scanimage_v600 = true });
    defer plan.deinit(allocator);
    try addProgressFlag(allocator, &plan);
    try std.testing.expectEqualStrings("scanimage-v600", plan.argv.items[0]);
    try std.testing.expectEqualStrings("--progress", plan.argv.items[1]);
}

test "scanner cancellation kills fake long-running child" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\cancel_file="$1"
        \\pid_file="$2"
        \\printf '%s\n' "$$" > "$pid_file"
        \\printf 'Progress: 1%%\n' >&2
        \\: > "$cancel_file"
        \\while :; do printf 'Progress: 2%%\n' >&2; done
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fake-scanimage.sh", .data = script });

    const script_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-scanimage.sh", .{tmp.sub_path[0..]});
    defer allocator.free(script_path);
    const cancel_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/cancel", .{tmp.sub_path[0..]});
    defer allocator.free(cancel_path);
    const pid_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/pid", .{tmp.sub_path[0..]});
    defer allocator.free(pid_path);

    var plan = sane.CommandPlan{
        .effective_dpi = 400,
        .original_dpi = 400,
        .source = .tpu,
        .kind = .rgb,
    };
    defer plan.deinit(allocator);
    try plan.argv.append(allocator, "sh");
    try plan.argv.append(allocator, script_path);
    try plan.argv.append(allocator, cancel_path);
    try plan.argv.append(allocator, pid_path);

    var environ_map = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer environ_map.deinit();

    var recorder = ScannerEventRecorder{};
    const runtime = Runtime{
        .allocator = allocator,
        .io = std.testing.io,
        .environ_map = &environ_map,
        .event_sink = .{
            .context = &recorder,
            .emit = recordScannerEvent,
        },
    };

    try std.testing.expectError(error.ScanCancelled, runtime.runScanPlan(&plan, cancel_path, 60_000));
    try std.testing.expect(recorder.indexOfTiming("linux.scan.environment") != null);
    try std.testing.expect(recorder.indexOfTiming("linux.scan.child_spawn") != null);
    try std.testing.expect(recorder.indexOfTiming("linux.scan.cancel_file") != null);
    try std.testing.expect(recorder.indexOfTiming("linux.scan.run_plan.total") != null);
    try std.testing.expect(recorder.indexOfName(.scan_cancelled) != null);

    const pid_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, pid_path, allocator, .limited(64));
    defer allocator.free(pid_bytes);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_bytes, " \t\r\n"), 10);
    try std.testing.expect(!processExists(pid));
}

fn runSilentFakeScan(allocator: std.mem.Allocator, touch_cancel_file: bool, timeout_ms: u64) !struct { result: anyerror!RunResult, pid: std.posix.pid_t, elapsed_ms: u64 } {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Starts, optionally requests cancel, then stays silent: no more stderr output.
    const script =
        \\cancel_file="$1"
        \\pid_file="$2"
        \\printf '%s\n' "$$" > "$pid_file"
        \\printf 'Progress: 1%%\n' >&2
        \\if [ "$3" = "cancel" ]; then : > "$cancel_file"; fi
        \\exec sleep 30
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fake-scanimage.sh", .data = script });
    const script_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/fake-scanimage.sh", .{tmp.sub_path[0..]});
    defer allocator.free(script_path);
    const cancel_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/cancel", .{tmp.sub_path[0..]});
    defer allocator.free(cancel_path);
    const pid_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/pid", .{tmp.sub_path[0..]});
    defer allocator.free(pid_path);

    var plan = sane.CommandPlan{ .effective_dpi = 400, .original_dpi = 400, .source = .tpu, .kind = .rgb };
    defer plan.deinit(allocator);
    for ([_][]const u8{ "sh", script_path, cancel_path, pid_path, if (touch_cancel_file) "cancel" else "wait" }) |arg| {
        try plan.argv.append(allocator, arg);
    }

    var environ_map = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer environ_map.deinit();
    const runtime = Runtime{ .allocator = allocator, .io = std.testing.io, .environ_map = &environ_map };

    const start_ns = monotonicNowNs();
    const result = runtime.runScanPlan(&plan, cancel_path, timeout_ms);
    const elapsed_ms = (monotonicNowNs() - start_ns) / std.time.ns_per_ms;
    const pid_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, pid_path, allocator, .limited(64));
    defer allocator.free(pid_bytes);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_bytes, " \t\r\n"), 10);
    return .{ .result = result, .pid = pid, .elapsed_ms = elapsed_ms };
}

test "scan run stops a silent scanimage at its deadline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const run = try runSilentFakeScan(allocator, false, 500);
    const result = try run.result;
    defer result.deinit(allocator);
    try std.testing.expect(result.timed_out);
    try std.testing.expect(!result.succeeded());
    try std.testing.expect(run.elapsed_ms < 5_000);
    try std.testing.expect(!processExists(run.pid));
}

test "cancel stops a scanimage that has gone silent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const run = try runSilentFakeScan(allocator, true, 60_000);
    try std.testing.expectError(error.ScanCancelled, run.result);
    try std.testing.expect(run.elapsed_ms < 5_000);
    try std.testing.expect(!processExists(run.pid));
}

test "scan timeout follows the Python estimate with a five-minute floor" {
    const caps = contracts.ScannerCapabilities{};
    const small: contracts.ScanRequest = .{ .dpi = 800, .area = .{ .width = 1.0, .height = 1.5 } };
    try std.testing.expectEqual(@as(u64, 300_000), scanTimeoutMs(small, 800, .tpu, caps));

    // 1.0 x 9.0 in at 3200 dpi is 92.16 MP: (10 + 184.32) s x 3 x 2 = 1165.92 s.
    const strip: contracts.ScanRequest = .{ .dpi = 3200, .area = .{ .width = 1.0, .height = 9.0 } };
    const strip_ms: i64 = @intCast(scanTimeoutMs(strip, 3200, .tpu, caps));
    try std.testing.expect(@abs(strip_ms - 1_165_920) <= 1);
}

test "single-pass scan emits timing diagnostics with fake scanimage" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\#!/bin/sh
        \\out=""
        \\while [ "$#" -gt 0 ]; do
        \\  if [ "$1" = "-o" ]; then
        \\    shift
        \\    out="$1"
        \\  fi
        \\  shift
        \\done
        \\printf 'Progress: 25%%\n' >&2
        \\printf 'Progress: 100%%\n' >&2
        \\if [ -z "$out" ]; then
        \\  exit 2
        \\fi
        \\magick -size 2x1 xc:black -depth 16 "$out"
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scanimage", .data = script });
    try tmp.dir.setFilePermissions(std.testing.io, "scanimage", .executable_file, .{});

    const fake_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(fake_dir);
    const script_path = try std.fmt.allocPrint(allocator, "{s}/scanimage", .{fake_dir});
    defer allocator.free(script_path);
    const output_path = try std.fmt.allocPrint(allocator, "{s}/single-pass.tiff", .{fake_dir});
    defer allocator.free(output_path);
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}.json", .{output_path});
    defer allocator.free(metadata_path);

    var environ_map = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer environ_map.deinit();

    var recorder = ScannerEventRecorder{};
    const runtime = Runtime{
        .allocator = allocator,
        .io = std.testing.io,
        .environ_map = &environ_map,
        .scanimage_command = script_path,
        .event_sink = .{
            .context = &recorder,
            .emit = recordScannerEvent,
        },
    };

    const failure = try runtime.scanOnce(.{
        .request = .{ .dpi = 400, .source = .flatbed, .kind = .rgb },
        .output_path = output_path,
        .capabilities = .{
            .device_name = "fake:device",
            .model = "Fake V600",
            .max_resolution = 3200,
            .flatbed_width_in = 8.5,
            .flatbed_height_in = 11.7,
        },
    }, "fake:device");
    try std.testing.expect(failure == null);
    try std.testing.expect(cancelFileExists(std.testing.io, output_path));
    try std.testing.expect(cancelFileExists(std.testing.io, metadata_path));

    try std.testing.expect(recorder.indexOfName(.scan_start) != null);
    try std.testing.expect(recorder.indexOfName(.progress) != null);
    try std.testing.expect(recorder.indexOfName(.scan_complete) != null);
    try expectTimingBefore(recorder, "linux.scan_once.capability_lookup", "linux.scan_once.request_normalize");
    try expectTimingBefore(recorder, "linux.scan_once.request_normalize", "linux.scan_once.command_plan");
    try expectTimingBefore(recorder, "linux.scan_once.command_plan", "linux.scan_once.progress_flag");
    try expectTimingBeforeEvent(recorder, "linux.scan_once.progress_flag", .scan_start);
    try expectEventBeforeTiming(recorder, .scan_start, "linux.scan.environment");
    try expectTimingBefore(recorder, "linux.scan.environment", "linux.scan.child_spawn");
    try expectTimingBefore(recorder, "linux.scan.child_spawn", "linux.scan.stderr_stream");
    try expectTimingBefore(recorder, "linux.scan.stderr_stream", "linux.scan.progress_emit_total");
    try expectTimingBefore(recorder, "linux.scan.progress_emit_total", "linux.scan.child_wait");
    try expectTimingBefore(recorder, "linux.scan.child_wait", "linux.scan.run_plan.total");
    try expectTimingBefore(recorder, "linux.scan_once.run_scan_plan", "linux.scan_once.mirror");
    try expectTimingBefore(recorder, "linux.scan_once.mirror", "linux.scan_once.metadata_tags");
    try expectTimingBefore(recorder, "linux.scan_once.metadata_tags", "linux.scan_once.metadata_sidecar");
    try expectTimingBeforeEvent(recorder, "linux.scan_once.metadata_sidecar", .scan_complete);
    try expectEventBeforeTiming(recorder, .scan_complete, "linux.scan_once.total");
}

test "RGB plus IR scan orchestration emits timing diagnostics with fake scanimage" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\#!/bin/sh
        \\out=""
        \\while [ "$#" -gt 0 ]; do
        \\  if [ "$1" = "-o" ]; then
        \\    shift
        \\    out="$1"
        \\  fi
        \\  shift
        \\done
        \\printf 'Progress: 100%%\n' >&2
        \\if [ -z "$out" ]; then
        \\  exit 2
        \\fi
        \\magick -size 2x1 xc:black -depth 16 "$out"
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scanimage", .data = script });
    try tmp.dir.setFilePermissions(std.testing.io, "scanimage", .executable_file, .{});

    const fake_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(fake_dir);
    const script_path = try std.fmt.allocPrint(allocator, "{s}/scanimage", .{fake_dir});
    defer allocator.free(script_path);
    const output_path = try std.fmt.allocPrint(allocator, "{s}/rgbir.tiff", .{fake_dir});
    defer allocator.free(output_path);
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}.json", .{output_path});
    defer allocator.free(metadata_path);
    const rgb_tmp_path = try std.fmt.allocPrint(allocator, "{s}.rgb.tmp.tiff", .{output_path});
    defer allocator.free(rgb_tmp_path);
    const ir_tmp_path = try std.fmt.allocPrint(allocator, "{s}.ir.tmp.tiff", .{output_path});
    defer allocator.free(ir_tmp_path);
    const thumb_tmp_path = try std.fmt.allocPrint(allocator, "{s}.thumb.tmp.tiff", .{output_path});
    defer allocator.free(thumb_tmp_path);

    var environ_map = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer environ_map.deinit();

    var recorder = ScannerEventRecorder{};
    const runtime = Runtime{
        .allocator = allocator,
        .io = std.testing.io,
        .environ_map = &environ_map,
        .scanimage_command = script_path,
        .event_sink = .{
            .context = &recorder,
            .emit = recordScannerEvent,
        },
    };

    try runtime.scan(.{
        .request = .{ .dpi = 400, .source = .flatbed, .kind = .rgb_ir },
        .output_path = output_path,
        .device_name = "fake:device",
    });

    try std.testing.expect(cancelFileExists(std.testing.io, output_path));
    try std.testing.expect(cancelFileExists(std.testing.io, metadata_path));
    try std.testing.expect(!cancelFileExists(std.testing.io, rgb_tmp_path));
    try std.testing.expect(!cancelFileExists(std.testing.io, ir_tmp_path));
    try std.testing.expect(!cancelFileExists(std.testing.io, thumb_tmp_path));

    try expectTimingBefore(recorder, "linux.scan_rgb_ir.rgb_plan", "linux.scan_rgb_ir.rgb_pass");
    try expectTimingBefore(recorder, "linux.scan_rgb_ir.rgb_pass", "linux.scan_rgb_ir.ir_plan");
    try expectTimingBefore(recorder, "linux.scan_rgb_ir.ir_plan", "linux.scan_rgb_ir.ir_pass");
    try expectTimingBefore(recorder, "linux.scan_rgb_ir.ir_pass", "linux.scan_rgb_ir.thumbnail");
    try expectTimingBefore(recorder, "linux.scan_rgb_ir.thumbnail", "linux.scan_rgb_ir.combine_tiff_pages");
    try expectTimingBefore(recorder, "linux.scan_rgb_ir.combine_tiff_pages", "linux.scan_rgb_ir.metadata_tags");
    try expectTimingBefore(recorder, "linux.scan_rgb_ir.metadata_tags", "linux.scan_rgb_ir.metadata_sidecar");
    try expectTimingBefore(recorder, "linux.scan_rgb_ir.metadata_sidecar", "linux.scan_rgb_ir.temp_cleanup");
    try expectTimingBefore(recorder, "linux.scan_rgb_ir.temp_cleanup", "linux.scan_rgb_ir.total");
}

test "writes RGB plus IR sidecar with stable page layout" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const metadata_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/combined.json", .{tmp.sub_path[0..]});
    defer allocator.free(metadata_path);
    const options = ScanOptions{
        .request = .{ .dpi = 400, .source = .tpu, .kind = .rgb_ir },
        .output_path = "combined.tiff",
        .metadata_path = metadata_path,
    };

    const written_path = try writeCombinedMetadataSidecar(allocator, std.testing.io, options, "epkowa:interpreter:001:017", combinedPassDpis(options.request));
    defer allocator.free(written_path);
    try std.testing.expectEqualStrings(metadata_path, written_path);

    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, metadata_path, allocator, .limited(4096));
    defer allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"kind\": \"rgb+ir\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"index\": 0, \"kind\": \"rgb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"index\": 1, \"kind\": \"thumbnail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"index\": 2, \"kind\": \"ir\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"rgb_effective_dpi\": 400") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"ir_effective_dpi\": 800") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, ".tmp.tiff") == null);
}

test "prepareEnvironment exposes V600_LUT_FILE to scan child" {
    const allocator = std.testing.allocator;
    var parent = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer parent.deinit();

    var storage: ?std.process.Environ.Map = null;
    defer if (storage) |*map| map.deinit();

    const child_env = (try prepareEnvironment(allocator, &parent, .{ .lut_file = "/tmp/v600-luts.bin" }, &storage)).?;
    try std.testing.expectEqualStrings("/tmp/v600-luts.bin", child_env.get("V600_LUT_FILE").?);
}

test "mirrors TIFF horizontally like Python TPU postprocessing" {
    if (!commandAvailableForTest("magick")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ppm =
        \\P3
        \\3 1
        \\255
        \\255 0 0 0 255 0 0 0 255
        \\
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input.ppm", .data = ppm });

    const ppm_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/input.ppm", .{tmp.sub_path[0..]});
    defer allocator.free(ppm_path);
    const input_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/input.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(input_path);
    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/output.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(output_path);

    var environ_map = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer environ_map.deinit();
    const runtime = Runtime{
        .allocator = allocator,
        .io = std.testing.io,
        .environ_map = &environ_map,
    };

    var create = try runCapture(allocator, std.testing.io, &.{
        "magick",
        ppm_path,
        "-depth",
        "8",
        input_path,
    }, null);
    defer create.deinit(allocator);
    try std.testing.expect(create.succeeded());

    try runtime.mirrorTiffHorizontally(input_path, output_path);

    const pixels = try runCapture(allocator, std.testing.io, &.{
        "magick",
        output_path,
        "-depth",
        "8",
        "rgb:-",
    }, null);
    defer pixels.deinit(allocator);
    try std.testing.expect(pixels.succeeded());
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 0, 255, 0, 255, 0, 0 }, pixels.stdout);
}

test "applies custom LUT TIFF metadata marker through native TIFF wrapper" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tiff_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/input.tiff", .{tmp.sub_path[0..]});
    defer allocator.free(tiff_path);
    const lut_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/lut.bin", .{tmp.sub_path[0..]});
    defer allocator.free(lut_path);

    try tiff.writeImage(allocator, tiff_path, .{
        .width = 1,
        .height = 1,
        .samples_per_pixel = 3,
        .bits_per_sample = 8,
        .data = &.{ 12, 34, 56 },
    }, .{});

    try lut.writeRgbFile(std.testing.io, lut_path, null, null, null);
    const lut_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, lut_path, allocator, .limited(lut.serialized_len + 1));
    defer allocator.free(lut_data);
    try std.testing.expectEqual(@as(usize, lut.serialized_len), lut_data.len);

    var environ_map = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer environ_map.deinit();
    const runtime = Runtime{
        .allocator = allocator,
        .io = std.testing.io,
        .environ_map = &environ_map,
    };

    try runtime.applyTiffMetadataTags(tiff_path, .{
        .model = "Epson Perfection V600 Photo",
        .software = tiff_software,
        .dpi = 800,
        .custom_luts_applied = true,
    });
    const marker = (try tiff.readAsciiTag(allocator, tiff_path, tiff.scanner_custom_lut_tag, tiff.scanner_custom_lut_name)).?;
    defer allocator.free(marker);
    try std.testing.expectEqualStrings(custom_lut_marker, marker);
    try std.testing.expectEqual(@as(?u32, 800), try tiff.readDpi(allocator, tiff_path));
}

test "SANE backend identity status and close match Python no-hardware methods" {
    const allocator = std.testing.allocator;
    var environ_map = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer environ_map.deinit();
    const runtime = Runtime{
        .allocator = allocator,
        .io = std.testing.io,
        .environ_map = &environ_map,
    };

    const identity = try runtime.getIdentity(sane_default_model_name);
    defer allocator.free(identity);
    try std.testing.expectEqualStrings("SANE Perfection V600 / GT-X820 (SANE)", identity);
    const status = runtime.getStatus();
    try std.testing.expectEqualSlices(u8, &.{0}, &status);
    const extended = runtime.getExtendedIdentity();
    const expected_extended = [_]u8{0} ** 80;
    try std.testing.expectEqual(@as(usize, 80), extended.len);
    try std.testing.expectEqualSlices(u8, &expected_extended, &extended);
    runtime.close();
}

test "SANE backend init state mirrors Python constructor defaults" {
    const default_state = SaneBackendState.init(null);
    try std.testing.expect(default_state.device_name == null);
    try std.testing.expect(default_state.model_name == null);
    try std.testing.expect(default_state.product_id == null);
    try std.testing.expect(default_state.cached_capabilities == null);

    const explicit_state = SaneBackendState.init(v600_product_id_int);
    try std.testing.expectEqual(@as(?u16, v600_product_id_int), explicit_state.product_id);
    try std.testing.expect(explicit_state.device_name == null);
    try std.testing.expect(explicit_state.model_name == null);
    try std.testing.expect(explicit_state.cached_capabilities == null);
}

test "SANE save image planning mirrors Python extension and depth routing" {
    const allocator = std.testing.allocator;

    const tiff_plan = try planSaveImage(allocator, "scan.tiff", .sixteen);
    defer tiff_plan.deinit(allocator);
    try std.testing.expectEqual(SaveImageFormat.tiff, tiff_plan.format);
    try std.testing.expectEqualStrings("scan.tiff", tiff_plan.path);
    try std.testing.expect(!tiff_plan.converted_png_16_to_tiff);

    const png_8_plan = try planSaveImage(allocator, "scan.png", .eight);
    defer png_8_plan.deinit(allocator);
    try std.testing.expectEqual(SaveImageFormat.png, png_8_plan.format);
    try std.testing.expectEqualStrings("scan.png", png_8_plan.path);
    try std.testing.expect(!png_8_plan.converted_png_16_to_tiff);

    const png_16_plan = try planSaveImage(allocator, "scan.png", .sixteen);
    defer png_16_plan.deinit(allocator);
    try std.testing.expectEqual(SaveImageFormat.tiff, png_16_plan.format);
    try std.testing.expectEqualStrings("scan.tiff", png_16_plan.path);
    try std.testing.expect(png_16_plan.converted_png_16_to_tiff);

    const unknown_plan = try planSaveImage(allocator, "scan.raw", .eight);
    defer unknown_plan.deinit(allocator);
    try std.testing.expectEqual(SaveImageFormat.tiff, unknown_plan.format);
    try std.testing.expectEqualStrings("scan.raw", unknown_plan.path);
}

fn processExists(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => return false,
    };
    return true;
}

fn commandAvailableForTest(command: []const u8) bool {
    if (std.mem.eql(u8, command, "magick")) {
        const result = runCapture(std.testing.allocator, std.testing.io, &.{
            "sh",
            "-c",
            "command -v magick >/dev/null 2>&1",
        }, null) catch return false;
        defer result.deinit(std.testing.allocator);
        return result.succeeded();
    }
    if (std.mem.eql(u8, command, "exiftool")) {
        const result = runCapture(std.testing.allocator, std.testing.io, &.{
            "sh",
            "-c",
            "command -v exiftool >/dev/null 2>&1",
        }, null) catch return false;
        defer result.deinit(std.testing.allocator);
        return result.succeeded();
    }
    return false;
}
