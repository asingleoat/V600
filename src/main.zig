const std = @import("std");
const v600 = @import("v600");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.next();
    const command = args.next() orelse {
        try printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "version")) {
        std.debug.print("v600-zig scanner foundation\n", .{});
    } else if (std.mem.eql(u8, command, "scanner-contract")) {
        std.debug.print("default dpi: {d}\n", .{v600.scanner.contracts.ScanRequest.default_dpi});
        std.debug.print("rgb+ir TIFF pages: RGB={d} thumbnail={d} IR={d}\n", .{
            v600.scanner.contracts.TiffPageLayout.rgb,
            v600.scanner.contracts.TiffPageLayout.thumbnail,
            v600.scanner.contracts.TiffPageLayout.ir,
        });
    } else if (std.mem.eql(u8, command, "scanner")) {
        handleScanner(init.gpa, io, init.environ_map, &args, stdout) catch |err| {
            try stdout.flush();
            return err;
        };
        try stdout.flush();
    } else if (std.mem.eql(u8, command, "serve")) {
        try handleServe(init.gpa, io, init.environ_map, &args, stdout);
    } else if (std.mem.eql(u8, command, "processing")) {
        handleProcessing(init.gpa, io, init.environ_map, &args, stdout) catch |err| {
            try stdout.flush();
            return err;
        };
        try stdout.flush();
    } else {
        try printUsage();
        return error.UnknownCommand;
    }
}

fn handleScanner(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
    stdout: anytype,
) !void {
    const subcommand = args.next() orelse {
        try printScannerUsage();
        return error.MissingScannerCommand;
    };

    if (std.mem.eql(u8, subcommand, "macos-smoke")) {
        try handleMacosScannerSmoke(environ_map, stdout);
        return;
    }

    switch (v600.scanner.backendKindForCurrentHost()) {
        .sane => try handleScannerSane(allocator, io, environ_map, args, stdout, subcommand),
        .interpreter => {
            try stdout.print("scanner backend unsupported on this host until macOS interpreter runtime wiring is complete\n", .{});
            return error.UnsupportedScannerBackend;
        },
    }
}

fn handleScannerSane(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
    stdout: anytype,
    subcommand: []const u8,
) !void {
    var scanner_args = try parseScannerCommonOptions(allocator, args);
    defer scanner_args.deinit();

    var timing_report: ?v600.scanner.events.TimingReport = null;
    defer if (timing_report) |*report| report.deinit();
    if (scanner_args.timing_report_path) |path| {
        timing_report = try v600.scanner.events.TimingReport.open(allocator, io, path);
    }
    const event_sink: ?v600.scanner.events.Sink = if (timing_report) |*report| report.sink() else null;

    const runtime = v600.scanner.linux.Runtime{
        .allocator = allocator,
        .io = io,
        .environ_map = environ_map,
        .event_sink = event_sink,
    };
    const remaining = scanner_args.remaining.items;

    if (std.mem.eql(u8, subcommand, "devices")) {
        try writeReportContext(&timing_report, .{ .command = "scanner devices" });
        const devices = runtime.discoverDevices() catch |err| {
            writeReportStatus(&timing_report, "scanner devices", "error", @errorName(err), null);
            return err;
        };
        defer v600.scanner.linux.freeDevices(allocator, devices);
        for (devices) |device| {
            try stdout.print("{s}\n", .{device.raw_line});
        }
        writeReportStatus(&timing_report, "scanner devices", "ok", null, null);
    } else if (std.mem.eql(u8, subcommand, "probe")) {
        try writeReportContext(&timing_report, .{ .command = "scanner probe" });
        _ = runtime.probe(stdout) catch |err| {
            writeReportStatus(&timing_report, "scanner probe", "error", @errorName(err), null);
            return err;
        };
        writeReportStatus(&timing_report, "scanner probe", "ok", null, null);
    } else if (std.mem.eql(u8, subcommand, "preview")) {
        try runScannerPreview(allocator, io, runtime, remaining, stdout);
    } else if (std.mem.eql(u8, subcommand, "scan")) {
        var options = try parseScanOptions(remaining);
        var auto_output_buffer: [std.fs.max_path_bytes]u8 = undefined;
        if (options.output_path.len == 0) {
            options.output_path = try autoScanOutputPath(&auto_output_buffer, io, options.request);
        }
        try writeScanReportContext(&timing_report, "scanner scan", options);
        runtime.scan(options) catch |err| {
            writeReportStatus(&timing_report, "scanner scan", "error", @errorName(err), reportOutput(options.output_path));
            return err;
        };
        writeReportStatus(&timing_report, "scanner scan", "ok", null, reportOutput(options.output_path));
    } else if (std.mem.eql(u8, subcommand, "usb-reset")) {
        const confirmed = try parseUsbResetOptions(remaining);
        if (!confirmed) {
            try stdout.print("USB reset not run: pass --yes to reset the Epson V600 USB device\n", .{});
            return;
        }
        const outcome = try runtime.usbReset();
        defer outcome.deinit(allocator);
        switch (outcome.status) {
            .reset_performed => try stdout.print("USB reset performed on {s}\n", .{outcome.path.?}),
            .device_not_found => try stdout.print("USB reset failed: Epson V600 USB device not found\n", .{}),
            .permission_denied => try stdout.print("USB reset failed: permission denied for {s}\n", .{outcome.path.?}),
            .reset_failed => try stdout.print("USB reset failed for {s}\n", .{outcome.path.?}),
        }
    } else if (std.mem.eql(u8, subcommand, "smoke")) {
        if (!hardwareSmokeEnabled(environ_map)) {
            try writeReportContext(&timing_report, .{ .command = "scanner smoke" });
            writeReportStatus(&timing_report, "scanner smoke", "skipped", "set V600_HARDWARE_SMOKE=1 to run", null);
            try stdout.print("hardware smoke skipped: set V600_HARDWARE_SMOKE=1 to run\n", .{});
            return;
        }
        var options = try parseScanOptions(remaining);
        if (options.output_path.len == 0) {
            options.output_path = "/tmp/v600-zig-smoke-rgb.tiff";
        }
        try writeScanReportContext(&timing_report, "scanner smoke", options);
        runtime.scan(options) catch |err| {
            writeReportStatus(&timing_report, "scanner smoke", "error", @errorName(err), reportOutput(options.output_path));
            return err;
        };
        writeReportStatus(&timing_report, "scanner smoke", "ok", null, reportOutput(options.output_path));
    } else if (std.mem.eql(u8, subcommand, "processing-smoke")) {
        if (!hardwareSmokeEnabled(environ_map)) {
            try writeReportContext(&timing_report, .{ .command = "scanner processing-smoke" });
            writeReportStatus(&timing_report, "scanner processing-smoke", "skipped", "set V600_HARDWARE_SMOKE=1 to run", null);
            try stdout.print("scanner processing smoke skipped: set V600_HARDWARE_SMOKE=1 to run\n", .{});
            return;
        }
        var options = try parseScanOptions(remaining);
        if (options.output_path.len == 0) {
            options.output_path = "/tmp/v600-zig-processing-smoke.tiff";
        }
        if (!options.request.area.isExplicit()) {
            options.request.area.width = 0.25;
            options.request.area.height = 0.25;
        }
        try writeScanReportContext(&timing_report, "scanner processing-smoke", options);
        runtime.scan(options) catch |err| {
            writeReportStatus(&timing_report, "scanner processing-smoke", "error", @errorName(err), reportOutput(options.output_path));
            return err;
        };
        v600.processing.cli.runCommand(allocator, io, .{ .info = .{ .input = options.output_path } }, stdout, .{}) catch |err| {
            writeReportStatus(&timing_report, "scanner processing-smoke", "error", @errorName(err), reportOutput(options.output_path));
            return err;
        };
        writeReportStatus(&timing_report, "scanner processing-smoke", "ok", null, reportOutput(options.output_path));
    } else {
        try printScannerUsage();
        return error.UnknownScannerCommand;
    }
}

fn handleMacosScannerSmoke(environ_map: *std.process.Environ.Map, stdout: anytype) !void {
    if (!macosHardwareSmokeEnabled(environ_map)) {
        try stdout.print("macOS scanner smoke skipped: set V600_MACOS_HARDWARE_SMOKE=1 to run\n", .{});
        return;
    }
    if (v600.scanner.backendKindForCurrentHost() != .interpreter) {
        try stdout.print("macOS scanner smoke requires a macOS interpreter host\n", .{});
        return error.UnsupportedPlatform;
    }
    try stdout.print("macOS scanner smoke not implemented until interpreter USB runtime is wired\n", .{});
    return error.UnsupportedScannerBackend;
}

fn hardwareSmokeEnabled(environ_map: *std.process.Environ.Map) bool {
    const value = environ_map.get("V600_HARDWARE_SMOKE") orelse return false;
    return std.mem.eql(u8, value, "1");
}

fn macosHardwareSmokeEnabled(environ_map: *std.process.Environ.Map) bool {
    const value = environ_map.get("V600_MACOS_HARDWARE_SMOKE") orelse return false;
    return std.mem.eql(u8, value, "1");
}

fn handleProcessing(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
    stdout: anytype,
) !void {
    var remaining = std.array_list.Managed([]const u8).init(allocator);
    defer remaining.deinit();
    while (args.next()) |arg| {
        try remaining.append(arg);
    }
    const command = v600.processing.cli.parseArgs(remaining.items) catch |err| {
        try printProcessingUsage();
        return err;
    };
    const processing_gpu_request = try v600.processing.inversion.invertNegativeRequestFromEnvironment(environ_map);
    v600.processing.cli.runCommand(allocator, io, command, stdout, processing_gpu_request) catch |err| {
        v600.processing.events.emitProcessingError(.{
            .operation = "processing",
            .detail = @errorName(err),
        });
        try stdout.print("{{\"error\":\"{s}\"}}\n", .{@errorName(err)});
    };
}

const ScannerCommonArgs = struct {
    timing_report_path: ?[]const u8 = null,
    remaining: std.array_list.Managed([]const u8),

    fn deinit(self: *ScannerCommonArgs) void {
        self.remaining.deinit();
    }
};

fn parseScannerCommonOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !ScannerCommonArgs {
    var common = ScannerCommonArgs{
        .remaining = std.array_list.Managed([]const u8).init(allocator),
    };
    errdefer common.deinit();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--timing-report")) {
            common.timing_report_path = args.next() orelse return error.MissingTimingReportPath;
        } else {
            try common.remaining.append(arg);
        }
    }
    return common;
}

/// scans/scan_NNNN_<mode>_<dpi>dpi.tiff, numbered after the highest existing
/// scan so nothing is overwritten, named with the dpi the scanner delivers.
fn autoScanOutputPath(buffer: []u8, io: std.Io, request: v600.scanner.contracts.ScanRequest) ![]const u8 {
    const dir = "scans";
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const number = try v600.tiff.nextScanNumber(io, dir, "scan_");
    const tag = switch (request.kind) {
        .rgb => "rgb",
        .rgb_ir => "rgbir",
        .ir => "ir",
        .gray => "gray",
    };
    const dpi = v600.scanner.sane.effectiveDpiForRequest(request);
    return std.fmt.bufPrint(buffer, "{s}/scan_{d:0>4}_{s}_{d}dpi.tiff", .{ dir, number, tag, dpi });
}

/// Scans the whole transparency unit at 400 dpi, 8-bit, and reports the film
/// area in the inch coordinates `scanner scan --x --y --width --height` takes.
fn runScannerPreview(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: v600.scanner.linux.Runtime,
    args: []const []const u8,
    stdout: anytype,
) !void {
    var options = try parseScanOptions(args);
    options.request = .{ .dpi = 400, .source = .tpu, .kind = .rgb, .depth = .eight };
    if (options.output_path.len == 0) {
        try std.Io.Dir.cwd().createDirPath(io, "scans");
        options.output_path = "scans/preview.tiff";
    }
    try runtime.scan(options);

    const image = try v600.tiff.loadRgbPage(allocator, options.output_path);
    defer image.deinit(allocator);
    const dpi: f64 = @floatFromInt(v600.scanner.sane.effectiveDpiForRequest(options.request));
    const info = v600.app_state.ScannerInfo{
        .preview_width = image.width,
        .preview_height = image.height,
        .tpu_width_in = @as(f64, @floatFromInt(image.width)) / dpi,
        .tpu_height_in = @as(f64, @floatFromInt(image.height)) / dpi,
        .scan_counter = 0,
    };
    const selection = try v600.native_ui.detectFilmAreaSelection(
        allocator,
        image.data,
        image.width,
        image.height,
        image.samples_per_pixel,
        @intFromFloat(dpi),
        info.tpu_width_in,
        info.tpu_height_in,
        .{},
    );
    const controls = v600.native_ui.ScanControls{ .selection = selection };
    try stdout.print("{{\"ok\":true,\"preview\":\"{s}\",\"film_area\":", .{options.output_path});
    if (controls.selectionForScanStart(info)) |area| {
        try stdout.print("{{\"x\":{d:.3},\"y\":{d:.3},\"width\":{d:.3},\"height\":{d:.3}}}}}\n", .{ area.x, area.y, area.w, area.h });
    } else {
        try stdout.print("null}}\n", .{});
    }
}

fn parseScanOptions(args: []const []const u8) !v600.scanner.linux.ScanOptions {
    var request = v600.scanner.contracts.ScanRequest{
        .dpi = 400,
        .source = .tpu,
        .kind = .rgb,
        .depth = .sixteen,
    };
    var output_path: []const u8 = "";
    var metadata_path: ?[]const u8 = null;
    var device_name: ?[]const u8 = null;
    var cancel_file: ?[]const u8 = null;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--device")) {
            index += 1;
            if (index >= args.len) return error.MissingDeviceName;
            device_name = args[index];
        } else if (std.mem.eql(u8, arg, "--source")) {
            index += 1;
            if (index >= args.len) return error.MissingSource;
            request.source = try parseSource(args[index]);
        } else if (std.mem.eql(u8, arg, "--kind")) {
            index += 1;
            if (index >= args.len) return error.MissingKind;
            request.kind = try parseKind(args[index]);
        } else if (std.mem.eql(u8, arg, "--dpi")) {
            index += 1;
            if (index >= args.len) return error.MissingDpi;
            request.dpi = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--depth")) {
            index += 1;
            if (index >= args.len) return error.MissingDepth;
            request.depth = try parseDepth(args[index]);
        } else if (std.mem.eql(u8, arg, "--out")) {
            index += 1;
            if (index >= args.len) return error.MissingOutputPath;
            output_path = args[index];
        } else if (std.mem.eql(u8, arg, "--metadata")) {
            index += 1;
            if (index >= args.len) return error.MissingMetadataPath;
            metadata_path = args[index];
        } else if (std.mem.eql(u8, arg, "--lut-file")) {
            index += 1;
            if (index >= args.len) return error.MissingLutFilePath;
            request.lut_file_path = args[index];
        } else if (std.mem.eql(u8, arg, "--cancel-file")) {
            index += 1;
            if (index >= args.len) return error.MissingCancelFile;
            cancel_file = args[index];
        } else if (std.mem.eql(u8, arg, "--x")) {
            index += 1;
            if (index >= args.len) return error.MissingAreaX;
            request.area.x = try std.fmt.parseFloat(f64, args[index]);
        } else if (std.mem.eql(u8, arg, "--y")) {
            index += 1;
            if (index >= args.len) return error.MissingAreaY;
            request.area.y = try std.fmt.parseFloat(f64, args[index]);
        } else if (std.mem.eql(u8, arg, "--width")) {
            index += 1;
            if (index >= args.len) return error.MissingAreaWidth;
            request.area.width = try std.fmt.parseFloat(f64, args[index]);
        } else if (std.mem.eql(u8, arg, "--height")) {
            index += 1;
            if (index >= args.len) return error.MissingAreaHeight;
            request.area.height = try std.fmt.parseFloat(f64, args[index]);
        } else {
            return error.UnknownScanOption;
        }
    }

    return .{
        .request = request,
        .output_path = output_path,
        .metadata_path = metadata_path,
        .device_name = device_name,
        .cancel_file = cancel_file,
    };
}

fn parseUsbResetOptions(args: []const []const u8) !bool {
    var confirmed = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--yes")) {
            confirmed = true;
        } else {
            return error.UnknownUsbResetOption;
        }
    }
    return confirmed;
}

fn writeScanReportContext(
    report: *?v600.scanner.events.TimingReport,
    command: []const u8,
    options: v600.scanner.linux.ScanOptions,
) !void {
    try writeReportContext(report, .{
        .command = command,
        .output = reportOutput(options.output_path),
        .device = options.device_name,
        .source = options.request.source,
        .kind = options.request.kind,
        .depth = options.request.depth,
        .dpi = options.request.dpi,
    });
}

fn writeReportContext(
    report: *?v600.scanner.events.TimingReport,
    event: v600.scanner.events.TimingContextEvent,
) !void {
    if (report.*) |*item| try item.writeContext(event);
}

fn writeReportStatus(
    report: *?v600.scanner.events.TimingReport,
    command: []const u8,
    status: []const u8,
    detail: ?[]const u8,
    output: ?[]const u8,
) void {
    if (report.*) |*item| {
        item.writeStatus(.{
            .command = command,
            .status = status,
            .detail = detail,
            .output = output,
        }) catch {};
    }
}

fn reportOutput(output_path: []const u8) ?[]const u8 {
    return if (output_path.len == 0) null else output_path;
}

fn parseSource(value: []const u8) !v600.scanner.contracts.Source {
    if (std.mem.eql(u8, value, "flatbed")) return .flatbed;
    if (std.mem.eql(u8, value, "tpu")) return .tpu;
    return error.InvalidSource;
}

fn parseKind(value: []const u8) !v600.scanner.contracts.ScanKind {
    if (std.mem.eql(u8, value, "rgb")) return .rgb;
    if (std.mem.eql(u8, value, "gray")) return .gray;
    if (std.mem.eql(u8, value, "ir")) return .ir;
    if (std.mem.eql(u8, value, "rgb+ir")) return .rgb_ir;
    if (std.mem.eql(u8, value, "rgbir")) return .rgb_ir;
    return error.InvalidKind;
}

fn parseDepth(value: []const u8) !v600.scanner.contracts.BitDepth {
    if (std.mem.eql(u8, value, "8")) return .eight;
    if (std.mem.eql(u8, value, "16")) return .sixteen;
    return error.InvalidDepth;
}

fn handleServe(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
    stdout: anytype,
) !void {
    var options = v600.companion.ServeOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const value = args.next() orelse return error.MissingPort;
            options.port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, arg, "--webapp-dir")) {
            options.webapp_dir = args.next() orelse return error.MissingWebappDir;
        } else if (std.mem.eql(u8, arg, "--out-dir")) {
            options.out_dir = args.next() orelse return error.MissingOutDir;
        } else if (std.mem.eql(u8, arg, "--scanimage")) {
            options.scanimage_command = args.next() orelse return error.MissingScanimagePath;
        } else {
            return error.UnknownServeOption;
        }
    }
    try v600.companion.serve(allocator, io, environ_map, options, stdout);
}

fn printUsage() !void {
    std.debug.print(
        \\usage: v600-zig <command>
        \\
        \\commands:
        \\  version           print build identity
        \\  scanner-contract  print scanner contract constants
        \\  scanner <command> run scanner discovery, probe, or scan commands
        \\  processing <cmd>  run processing workflow commands
        \\  serve             run the local browser companion server
        \\
    , .{});
}

fn printScannerUsage() !void {
    std.debug.print(
        \\usage: v600-zig scanner <command>
        \\
        \\commands:
        \\  devices                       list SANE devices
        \\  probe                         report selected V600 capabilities
        \\  preview [--out PATH]           400 dpi TPU preview; prints the film area for scan
        \\  scan [--out PATH] [options]    run a real scanner pass; default output is
        \\                                 scans/scan_NNNN_<mode>_<dpi>dpi.tiff
        \\  usb-reset --yes                explicitly reset the V600 USB device
        \\  smoke [--out PATH] [options]   gated hardware smoke scan
        \\  processing-smoke [options]     gated scan then processing load smoke
        \\  macos-smoke                    gated future macOS interpreter smoke
        \\
        \\scan options:
        \\  --device NAME
        \\  --source flatbed|tpu
        \\  --kind rgb|gray|ir|rgb+ir
        \\  --dpi DPI
        \\  --depth 8|16
        \\  --x IN --y IN --width IN --height IN
        \\  --metadata PATH
        \\  --lut-file PATH
        \\  --cancel-file PATH
        \\  --timing-report PATH
        \\
    , .{});
}

fn printProcessingUsage() !void {
    std.debug.print(
        \\usage: v600-zig processing <command>
        \\
        \\commands:
        \\  info --input PATH
        \\  detect --input PATH [--format 35mm|645|6x6|6x7|6x9] [--n-frames N] [--preview-size PX]
        \\         (detects on a preview, max side PX, default 8192; prints full-resolution frames)
        \\  rebate --input PATH --x PX --y PX --width PX --height PX [--angle RAD] [--config PATH] [--no-save]
        \\  export --input PATH --frame CX,CY,W,H[,ANGLE_DEG[,ROT]] [--out-dir DIR] [--basename NAME] [--ir-neg] [--no-ir-inv] [--inv-only]
        \\         [--stock NAME] [--dmin R,G,B] [--dpi DPI] [--config PATH]
        \\         (stock, Dmin, and parameters default to scratchndent_config.toml; dpi to the TIFF)
        \\
    , .{});
}
