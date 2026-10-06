const std = @import("std");
const builtin = @import("builtin");
const cerealgrain = @import("cerealgrain");
const roll_cli = @import("roll_cli.zig");

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
        std.debug.print("cerealgrain {s}\n", .{cerealgrain.version});
    } else if (std.mem.eql(u8, command, "scanner-contract")) {
        std.debug.print("default dpi: {d}\n", .{cerealgrain.scanner.contracts.ScanRequest.default_dpi});
        std.debug.print("rgb+ir TIFF pages: RGB={d} thumbnail={d} IR={d}\n", .{
            cerealgrain.scanner.contracts.TiffPageLayout.rgb,
            cerealgrain.scanner.contracts.TiffPageLayout.thumbnail,
            cerealgrain.scanner.contracts.TiffPageLayout.ir,
        });
    } else if (std.mem.eql(u8, command, "scanner")) {
        handleScanner(init.gpa, io, init.environ_map, &args, stdout) catch |err| {
            try stdout.flush();
            return err;
        };
        try stdout.flush();
    } else if (std.mem.eql(u8, command, "serve")) {
        try handleServe(init.gpa, io, init.environ_map, &args, stdout);
    } else if (std.mem.eql(u8, command, "roll")) {
        roll_cli.handle(init.gpa, io, init.environ_map, &args, stdout) catch |err| {
            try stdout.flush();
            return err;
        };
        try stdout.flush();
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
        try handleMacosScannerSmoke(allocator, io, environ_map, stdout);
        return;
    }
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) {
        try stdout.print("scanner backend unsupported on this host\n", .{});
        return error.UnsupportedScannerBackend;
    }
    try handleScannerHost(allocator, io, environ_map, args, stdout, subcommand);
}

fn handleScannerHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
    stdout: anytype,
    subcommand: []const u8,
) !void {
    var scanner_args = try parseScannerCommonOptions(allocator, args);
    defer scanner_args.deinit();

    var timing_report: ?cerealgrain.scanner.events.TimingReport = null;
    defer if (timing_report) |*report| report.deinit();
    if (scanner_args.timing_report_path) |path| {
        timing_report = try cerealgrain.scanner.events.TimingReport.open(allocator, io, path);
    }
    const event_sink: ?cerealgrain.scanner.events.Sink = if (timing_report) |*report| report.sink() else null;

    const runtime = cerealgrain.scanner.host.Runtime{
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
        defer cerealgrain.scanner.host.freeDevices(allocator, devices);
        for (devices) |device| {
            try stdout.print("{s}\n", .{device.raw_line});
        }
        writeReportStatus(&timing_report, "scanner devices", "ok", null, null);
    } else if (std.mem.eql(u8, subcommand, "probe")) {
        try writeReportContext(&timing_report, .{ .command = "scanner probe" });
        try stdout.print("cerealgrain: {s}\n", .{cerealgrain.version});
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
            try stdout.print("USB reset not run: pass --yes to reset the scanner's USB device\n", .{});
            return;
        }
        const outcome = try runtime.usbReset();
        defer outcome.deinit(allocator);
        switch (outcome.status) {
            .reset_performed => try stdout.print("USB reset performed on {s}\n", .{outcome.path.?}),
            .device_not_found => try stdout.print("USB reset failed: no known Epson scanner on USB\n", .{}),
            .permission_denied => try stdout.print("USB reset failed: permission denied for {s}\n", .{outcome.path.?}),
            .reset_failed => try stdout.print("USB reset failed for {s}\n", .{outcome.path.?}),
        }
    } else if (std.mem.eql(u8, subcommand, "smoke")) {
        if (!hardwareSmokeEnabled(environ_map)) {
            try writeReportContext(&timing_report, .{ .command = "scanner smoke" });
            writeReportStatus(&timing_report, "scanner smoke", "skipped", "set CEREALGRAIN_HARDWARE_SMOKE=1 to run", null);
            try stdout.print("hardware smoke skipped: set CEREALGRAIN_HARDWARE_SMOKE=1 to run\n", .{});
            return;
        }
        var options = try parseScanOptions(remaining);
        if (options.output_path.len == 0) {
            options.output_path = "/tmp/cerealgrain-smoke-rgb.tiff";
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
            writeReportStatus(&timing_report, "scanner processing-smoke", "skipped", "set CEREALGRAIN_HARDWARE_SMOKE=1 to run", null);
            try stdout.print("scanner processing smoke skipped: set CEREALGRAIN_HARDWARE_SMOKE=1 to run\n", .{});
            return;
        }
        var options = try parseScanOptions(remaining);
        if (options.output_path.len == 0) {
            options.output_path = "/tmp/cerealgrain-processing-smoke.tiff";
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
        cerealgrain.processing.cli.runCommand(allocator, io, .{ .info = .{ .input = options.output_path } }, stdout, .{}) catch |err| {
            writeReportStatus(&timing_report, "scanner processing-smoke", "error", @errorName(err), reportOutput(options.output_path));
            return err;
        };
        writeReportStatus(&timing_report, "scanner processing-smoke", "ok", null, reportOutput(options.output_path));
    } else {
        try printScannerUsage();
        return error.UnknownScannerCommand;
    }
}

/// Gated identity probe of a scanner attached to this Mac.
fn handleMacosScannerSmoke(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    stdout: anytype,
) !void {
    if (!macosHardwareSmokeEnabled(environ_map)) {
        try stdout.print("macOS scanner smoke skipped: set CEREALGRAIN_MACOS_HARDWARE_SMOKE=1 to run\n", .{});
        return;
    }
    if (builtin.os.tag != .macos) {
        try stdout.print("macOS scanner smoke requires a macOS host\n", .{});
        return error.UnsupportedPlatform;
    }
    const runtime = cerealgrain.scanner.host.Runtime{
        .allocator = allocator,
        .io = io,
        .environ_map = environ_map,
    };
    _ = try runtime.probe(stdout);
}

fn hardwareSmokeEnabled(environ_map: *std.process.Environ.Map) bool {
    const value = environ_map.get("CEREALGRAIN_HARDWARE_SMOKE") orelse return false;
    return std.mem.eql(u8, value, "1");
}

fn macosHardwareSmokeEnabled(environ_map: *std.process.Environ.Map) bool {
    const value = environ_map.get("CEREALGRAIN_MACOS_HARDWARE_SMOKE") orelse return false;
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
    var command = cerealgrain.processing.cli.parseArgs(remaining.items) catch |err| {
        try printProcessingUsage();
        return err;
    };
    var roll = try applyRollDefaults(allocator, io, &command, remaining.items);
    defer if (roll) |*open_roll| open_roll.deinit();
    const processing_gpu_request = try cerealgrain.processing.inversion.invertNegativeRequestFromEnvironment(environ_map);
    cerealgrain.processing.cli.runCommand(allocator, io, command, stdout, processing_gpu_request) catch |err| {
        cerealgrain.processing.events.emitProcessingError(.{
            .operation = "processing",
            .detail = @errorName(err),
        });
        try stdout.print("{{\"error\":\"{s}\"}}\n", .{@errorName(err)});
    };
}

/// A strip inside a roll directory takes the roll's film stock and format
/// unless the command names them. Returns the roll, which backs the strings.
fn applyRollDefaults(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: *cerealgrain.processing.cli.ProcessingCommand,
    argv: []const []const u8,
) !?cerealgrain.roll.Roll {
    const input = switch (command.*) {
        .detect => |options| options.input,
        .export_frames => |options| options.input,
        else => return null,
    };
    const dir = std.fs.path.dirname(input) orelse return null;
    const scans_root = std.fs.path.dirname(dir) orelse ".";
    var roll = cerealgrain.roll.Roll.open(allocator, io, scans_root, roll_cli.frames_root, std.fs.path.basename(dir)) catch return null;
    errdefer roll.deinit();
    const has_format = hasArg(argv, "--format");
    switch (command.*) {
        .detect => |*options| {
            if (!has_format) options.format = roll.format;
        },
        .export_frames => |*options| {
            if (!has_format) options.format = roll.format;
            if (!hasArg(argv, "--stock")) options.film_stock = roll.stock;
        },
        else => {},
    }
    return roll;
}

fn hasArg(argv: []const []const u8, flag: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
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
fn autoScanOutputPath(buffer: []u8, io: std.Io, request: cerealgrain.scanner.contracts.ScanRequest) ![]const u8 {
    const dir = "scans";
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const number = try cerealgrain.tiff.nextScanNumber(io, dir, "scan_");
    const tag = switch (request.kind) {
        .rgb => "rgb",
        .rgb_ir => "rgbir",
        .ir => "ir",
        .gray => "gray",
    };
    const dpi = cerealgrain.scanner.host.effectiveDpiForRequest(request);
    return std.fmt.bufPrint(buffer, "{s}/scan_{d:0>4}_{s}_{d}dpi.tiff", .{ dir, number, tag, dpi });
}

/// Scans the whole transparency unit at 400 dpi, 8-bit, reports the film area
/// in the inch coordinates `scanner scan --x --y --width --height` takes, and
/// writes the film's gamma LUTs to `<preview>.lut.bin` for `--lut-file`.
fn runScannerPreview(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: cerealgrain.scanner.host.Runtime,
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

    var preview = try roll_cli.loadPreview(allocator, options.output_path);
    defer preview.deinit(allocator);
    const image = preview.image;
    const selection = preview.selection;
    try stdout.print("{{\"ok\":true,\"preview\":\"{s}\",\"film_area\":", .{options.output_path});
    if (preview.area) |area| {
        try stdout.print("{{\"x\":{d:.3},\"y\":{d:.3},\"width\":{d:.3},\"height\":{d:.3}}}", .{ area.x, area.y, area.w, area.h });
    } else {
        try stdout.print("null", .{});
    }

    // Per-channel gamma LUTs stretching the film strip's own black and white
    // points to the full output range, for `scanner scan --lut-file`.
    const film = selection orelse {
        try stdout.print(",\"lut_file\":null}}\n", .{});
        return;
    };
    const luts = try cerealgrain.scanner.film_lut.computeFilmLuts(
        allocator,
        image.data,
        image.width,
        image.height,
        image.samples_per_pixel,
        .{ .x = film.x, .y = film.y, .w = film.w, .h = film.h },
        .{},
    );
    if (luts.red == null and luts.green == null and luts.blue == null) {
        try stdout.print(",\"lut_file\":null}}\n", .{});
        return;
    }
    const lut_path = try std.fmt.allocPrint(allocator, "{s}.lut.bin", .{options.output_path});
    defer allocator.free(lut_path);
    try cerealgrain.scanner.lut.writeRgbFile(
        io,
        lut_path,
        if (luts.red) |*table| table else null,
        if (luts.green) |*table| table else null,
        if (luts.blue) |*table| table else null,
    );
    try stdout.print(",\"lut_file\":\"{s}\",\"lut_black\":[{d:.2},{d:.2},{d:.2}],\"lut_white\":[{d:.2},{d:.2},{d:.2}]}}\n", .{
        lut_path,
        luts.black[0] orelse 0, luts.black[1] orelse 0, luts.black[2] orelse 0,
        luts.white[0] orelse 0, luts.white[1] orelse 0, luts.white[2] orelse 0,
    });
}

fn parseScanOptions(args: []const []const u8) !cerealgrain.scanner.host.ScanOptions {
    var request = cerealgrain.scanner.contracts.ScanRequest{
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
    report: *?cerealgrain.scanner.events.TimingReport,
    command: []const u8,
    options: cerealgrain.scanner.host.ScanOptions,
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
    report: *?cerealgrain.scanner.events.TimingReport,
    event: cerealgrain.scanner.events.TimingContextEvent,
) !void {
    if (report.*) |*item| try item.writeContext(event);
}

fn writeReportStatus(
    report: *?cerealgrain.scanner.events.TimingReport,
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

fn parseSource(value: []const u8) !cerealgrain.scanner.contracts.Source {
    if (std.mem.eql(u8, value, "flatbed")) return .flatbed;
    if (std.mem.eql(u8, value, "tpu")) return .tpu;
    return error.InvalidSource;
}

fn parseKind(value: []const u8) !cerealgrain.scanner.contracts.ScanKind {
    if (std.mem.eql(u8, value, "rgb")) return .rgb;
    if (std.mem.eql(u8, value, "gray")) return .gray;
    if (std.mem.eql(u8, value, "ir")) return .ir;
    if (std.mem.eql(u8, value, "rgb+ir")) return .rgb_ir;
    if (std.mem.eql(u8, value, "rgbir")) return .rgb_ir;
    return error.InvalidKind;
}

fn parseDepth(value: []const u8) !cerealgrain.scanner.contracts.BitDepth {
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
    var options = cerealgrain.companion.ServeOptions{};
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
    try cerealgrain.companion.serve(allocator, io, environ_map, options, stdout);
}

fn printUsage() !void {
    std.debug.print(
        \\usage: cerealgrain <command>
        \\
        \\commands:
        \\  version           print build identity
        \\  scanner-contract  print scanner contract constants
        \\  scanner <command> run scanner discovery, probe, or scan commands
        \\  processing <cmd>  run processing workflow commands
        \\  roll <command>    scan and process a film roll strip by strip
        \\  serve             run the local browser companion server
        \\
    , .{});
}

fn printScannerUsage() !void {
    std.debug.print(
        \\usage: cerealgrain scanner <command>
        \\
        \\commands:
        \\  devices                       list scanners
        \\  probe                         report the scanner's model and capabilities
        \\  preview [--out PATH]           400 dpi TPU preview; prints the film area for scan
        \\                                 and writes the film's LUTs to PATH.lut.bin
        \\  scan [--out PATH] [options]    run a real scanner pass; default output is
        \\                                 scans/scan_NNNN_<mode>_<dpi>dpi.tiff
        \\  usb-reset --yes                explicitly reset the scanner's USB device (Linux)
        \\  smoke [--out PATH] [options]   gated hardware smoke scan
        \\  processing-smoke [options]     gated scan then processing load smoke
        \\  macos-smoke                    gated macOS scanner identity probe
        \\
        \\scan options:
        \\  --device NAME
        \\  --source flatbed|tpu
        \\  --kind rgb|gray|ir|rgb+ir
        \\  --dpi DPI
        \\  --depth 8|16
        \\  --x IN --y IN --width IN --height IN
        \\  --metadata PATH
        \\  --lut-file PATH                per-channel gamma LUTs (macOS; from preview)
        \\  --cancel-file PATH
        \\  --timing-report PATH
        \\
    , .{});
}

fn printProcessingUsage() !void {
    std.debug.print(
        \\usage: cerealgrain processing <command>
        \\
        \\commands:
        \\  info --input PATH
        \\  detect --input PATH [--format 35mm|645|6x6|6x7|6x9] [--n-frames N] [--preview-size PX]
        \\         [--exact-aspect] [--config PATH] [--no-save]
        \\         (detects on a preview, max side PX, default 8192; prints full-resolution frames
        \\          and the rebate as center, size, and angle_deg, and saves the rebate's Dmin;
        \\          --exact-aspect trims frames to the format's exact aspect, for prints)
        \\  rebate --input PATH --x PX --y PX --width PX --height PX [--angle DEG] [--config PATH] [--no-save]
        \\         (x and y are the top-left corner)
        \\  rings --input PATH --frame CX,CY,W,H[,ANGLE_DEG] [--frame ...]
        \\         (Newton's rings: area of each frame showing them, from the IR page)
        \\  export --input PATH --frame CX,CY,W,H[,ANGLE_DEG[,ROT]] [--out-dir DIR] [--basename NAME] [--ir-neg] [--no-ir-inv] [--inv-only]
        \\         [--stock NAME] [--dmin R,G,B] [--format FMT] [--dpi DPI] [--config PATH]
        \\         [--print SIZE|off] [--print-dpi DPI]
        \\         (stock and parameters come from processing.toml, dpi from the TIFF; Dmin
        \\          from --dmin, else this scan's detected rebate, else the saved Dmin, else the image;
        \\          --print also writes each frame as an 8-bit JPEG fitted to a print, at --print-dpi
        \\          (default 360): 4x6 5x7 8x8 8x10 letter 8x12 a4 12x12 11x14 11x17 a3 12x18
        \\          13x19 16x20 16x24 20x30 24x36)
        \\
    , .{});
}
