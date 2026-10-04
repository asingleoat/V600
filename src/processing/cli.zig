const std = @import("std");

const config = @import("config.zig");
const events = @import("events.zig");
const export_pipeline = @import("export.zig");
const frames = @import("frames.zig");
const inversion = @import("inversion.zig");
const ir_processing = @import("ir.zig");
const print = @import("print.zig");
const tiff = @import("../tiff.zig");
const webgpu = @import("webgpu.zig");
const workflow = @import("workflow.zig");

pub const CommandTag = enum {
    info,
    detect,
    rebate,
    export_frames,
};

pub const InfoOptions = struct {
    input: []const u8 = "",
};

const default_preview_size: i64 = 8192;

pub const DetectOptions = struct {
    input: []const u8 = "",
    format: []const u8 = "35mm",
    n_frames: ?usize = null,
    preview_size: i64 = default_preview_size,
    config_path: []const u8 = config.config_file,
    save: bool = true,
    apply_clahe: bool = true,
    detect_film_extent: bool = true,
    exact_aspect: bool = false,
};

pub const RebateOptions = struct {
    input: []const u8 = "",
    x: f64 = 0.0,
    y: f64 = 0.0,
    w: f64 = 0.0,
    h: f64 = 0.0,
    /// Radians; `--angle` takes degrees like every CLI angle.
    angle: f64 = 0.0,
    config_path: []const u8 = config.config_file,
    save: bool = true,
};

pub const ExportOptions = struct {
    input: []const u8 = "",
    output_dir: []const u8 = "frames",
    basename: ?[]const u8 = null,
    frames: [64]export_pipeline.FrameRect = undefined,
    frame_count: usize = 0,
    outputs: export_pipeline.OutputSelection = .{},
    film_stock: ?[]const u8 = null,
    format: []const u8 = "35mm",
    dmin: ?[3]f64 = null,
    current_dpi: ?u32 = null,
    config_path: []const u8 = config.config_file,
    align_ir: bool = true,
    emit_events: bool = false,
    cancel_file: ?[]const u8 = null,
    /// A print size name, or "off"; with `print_dpi`, overrides the config.
    print_size: ?[]const u8 = null,
    print_dpi: ?u32 = null,
};

pub const ProcessingCommand = union(CommandTag) {
    info: InfoOptions,
    detect: DetectOptions,
    rebate: RebateOptions,
    export_frames: ExportOptions,
};

pub fn parseArgs(argv: []const []const u8) !ProcessingCommand {
    if (argv.len == 0) return error.MissingProcessingCommand;
    const subcommand = argv[0];
    if (std.mem.eql(u8, subcommand, "info")) {
        return .{ .info = try parseInfoArgs(argv[1..]) };
    }
    if (std.mem.eql(u8, subcommand, "detect")) {
        return .{ .detect = try parseDetectArgs(argv[1..]) };
    }
    if (std.mem.eql(u8, subcommand, "rebate")) {
        return .{ .rebate = try parseRebateArgs(argv[1..]) };
    }
    if (std.mem.eql(u8, subcommand, "export")) {
        return .{ .export_frames = try parseExportArgs(argv[1..]) };
    }
    return error.UnknownProcessingCommand;
}

pub fn runCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: ProcessingCommand,
    stdout: anytype,
    processing_gpu_request: webgpu.Request,
) !void {
    switch (command) {
        .info => |options| try runInfo(allocator, options, stdout),
        .detect => |options| try runDetect(allocator, io, options, stdout),
        .rebate => |options| try runRebate(allocator, io, options, stdout),
        .export_frames => |options| try runExport(allocator, io, options, stdout, processing_gpu_request),
    }
}

fn parseInfoArgs(argv: []const []const u8) !InfoOptions {
    var options = InfoOptions{};
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--input")) {
            index += 1;
            if (index >= argv.len) return error.MissingInputPath;
            options.input = argv[index];
        } else {
            return error.UnknownProcessingOption;
        }
    }
    if (options.input.len == 0) return error.MissingInputPath;
    return options;
}

fn parseDetectArgs(argv: []const []const u8) !DetectOptions {
    var options = DetectOptions{};
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--input")) {
            index += 1;
            if (index >= argv.len) return error.MissingInputPath;
            options.input = argv[index];
        } else if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= argv.len) return error.MissingFormat;
            options.format = argv[index];
        } else if (std.mem.eql(u8, arg, "--n-frames")) {
            index += 1;
            if (index >= argv.len) return error.MissingFrameCount;
            options.n_frames = try std.fmt.parseInt(usize, argv[index], 10);
        } else if (std.mem.eql(u8, arg, "--preview-size")) {
            index += 1;
            if (index >= argv.len) return error.MissingPreviewSize;
            options.preview_size = try std.fmt.parseInt(i64, argv[index], 10);
        } else if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index >= argv.len) return error.MissingConfigPath;
            options.config_path = argv[index];
        } else if (std.mem.eql(u8, arg, "--no-save")) {
            options.save = false;
        } else if (std.mem.eql(u8, arg, "--no-clahe")) {
            options.apply_clahe = false;
        } else if (std.mem.eql(u8, arg, "--no-film-extent")) {
            options.detect_film_extent = false;
        } else if (std.mem.eql(u8, arg, "--exact-aspect")) {
            options.exact_aspect = true;
        } else {
            return error.UnknownProcessingOption;
        }
    }
    if (options.input.len == 0) return error.MissingInputPath;
    _ = frames.formatByName(options.format) orelse return error.InvalidFilmFormat;
    return options;
}

fn parseRebateArgs(argv: []const []const u8) !RebateOptions {
    var options = RebateOptions{};
    var have_rect = false;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--input")) {
            index += 1;
            if (index >= argv.len) return error.MissingInputPath;
            options.input = argv[index];
        } else if (std.mem.eql(u8, arg, "--x")) {
            index += 1;
            if (index >= argv.len) return error.MissingRebateCoordinate;
            options.x = try std.fmt.parseFloat(f64, argv[index]);
            have_rect = true;
        } else if (std.mem.eql(u8, arg, "--y")) {
            index += 1;
            if (index >= argv.len) return error.MissingRebateCoordinate;
            options.y = try std.fmt.parseFloat(f64, argv[index]);
            have_rect = true;
        } else if (std.mem.eql(u8, arg, "--width")) {
            index += 1;
            if (index >= argv.len) return error.MissingRebateCoordinate;
            options.w = try std.fmt.parseFloat(f64, argv[index]);
            have_rect = true;
        } else if (std.mem.eql(u8, arg, "--height")) {
            index += 1;
            if (index >= argv.len) return error.MissingRebateCoordinate;
            options.h = try std.fmt.parseFloat(f64, argv[index]);
            have_rect = true;
        } else if (std.mem.eql(u8, arg, "--angle")) {
            index += 1;
            if (index >= argv.len) return error.MissingRebateCoordinate;
            options.angle = std.math.degreesToRadians(try std.fmt.parseFloat(f64, argv[index]));
        } else if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index >= argv.len) return error.MissingConfigPath;
            options.config_path = argv[index];
        } else if (std.mem.eql(u8, arg, "--no-save")) {
            options.save = false;
        } else {
            return error.UnknownProcessingOption;
        }
    }
    if (options.input.len == 0) return error.MissingInputPath;
    if (!have_rect or options.w <= 0.0 or options.h <= 0.0) return error.InvalidRebateRect;
    return options;
}

fn parseExportArgs(argv: []const []const u8) !ExportOptions {
    var options = ExportOptions{};
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--input")) {
            index += 1;
            if (index >= argv.len) return error.MissingInputPath;
            options.input = argv[index];
        } else if (std.mem.eql(u8, arg, "--out-dir")) {
            index += 1;
            if (index >= argv.len) return error.MissingOutputDir;
            options.output_dir = argv[index];
        } else if (std.mem.eql(u8, arg, "--basename")) {
            index += 1;
            if (index >= argv.len) return error.MissingBasename;
            options.basename = argv[index];
        } else if (std.mem.eql(u8, arg, "--frame")) {
            index += 1;
            if (index >= argv.len) return error.MissingFrameSpec;
            if (options.frame_count >= options.frames.len) return error.TooManyFrames;
            options.frames[options.frame_count] = try parseFrameSpec(argv[index]);
            options.frame_count += 1;
        } else if (std.mem.eql(u8, arg, "--ir-neg")) {
            options.outputs.ir_neg = true;
        } else if (std.mem.eql(u8, arg, "--no-ir-neg")) {
            options.outputs.ir_neg = false;
        } else if (std.mem.eql(u8, arg, "--ir-inv")) {
            options.outputs.ir_inv = true;
        } else if (std.mem.eql(u8, arg, "--no-ir-inv")) {
            options.outputs.ir_inv = false;
        } else if (std.mem.eql(u8, arg, "--inv-only")) {
            options.outputs.inv_only = true;
        } else if (std.mem.eql(u8, arg, "--no-inv-only")) {
            options.outputs.inv_only = false;
        } else if (std.mem.eql(u8, arg, "--stock")) {
            index += 1;
            if (index >= argv.len) return error.MissingStock;
            options.film_stock = argv[index];
        } else if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= argv.len) return error.MissingFormat;
            options.format = argv[index];
        } else if (std.mem.eql(u8, arg, "--dmin")) {
            index += 1;
            if (index >= argv.len) return error.MissingDmin;
            options.dmin = try parseDminSpec(argv[index]);
        } else if (std.mem.eql(u8, arg, "--dpi")) {
            index += 1;
            if (index >= argv.len) return error.MissingDpi;
            options.current_dpi = try std.fmt.parseInt(u32, argv[index], 10);
        } else if (std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index >= argv.len) return error.MissingConfigPath;
            options.config_path = argv[index];
        } else if (std.mem.eql(u8, arg, "--no-align-ir")) {
            options.align_ir = false;
        } else if (std.mem.eql(u8, arg, "--events")) {
            options.emit_events = true;
        } else if (std.mem.eql(u8, arg, "--cancel-file")) {
            index += 1;
            if (index >= argv.len) return error.MissingCancelFile;
            options.cancel_file = argv[index];
        } else if (std.mem.eql(u8, arg, "--print")) {
            index += 1;
            if (index >= argv.len) return error.MissingPrintSize;
            if (!std.mem.eql(u8, argv[index], "off") and print.sizeNamed(argv[index]) == null) return error.UnknownPrintSize;
            options.print_size = argv[index];
        } else if (std.mem.eql(u8, arg, "--print-dpi")) {
            index += 1;
            if (index >= argv.len) return error.MissingPrintDpi;
            const dpi = try std.fmt.parseInt(u32, argv[index], 10);
            if (dpi < print.min_dpi or dpi > print.max_dpi) return error.InvalidPrintDpi;
            options.print_dpi = dpi;
        } else {
            return error.UnknownProcessingOption;
        }
    }
    if (options.input.len == 0) return error.MissingInputPath;
    if (options.frame_count == 0) return error.MissingFrameSpec;
    if (!options.outputs.any()) return error.NoExportOutputsSelected;
    _ = frames.formatByName(options.format) orelse return error.InvalidFilmFormat;
    return options;
}

pub fn parseFrameSpec(text: []const u8) !export_pipeline.FrameRect {
    var values: [6]f64 = .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        if (count >= values.len) return error.InvalidFrameSpec;
        values[count] = try std.fmt.parseFloat(f64, std.mem.trim(u8, part, " \t"));
        count += 1;
    }
    if (count < 4) return error.InvalidFrameSpec;
    return .{
        .cx = values[0],
        .cy = values[1],
        .w = values[2],
        .h = values[3],
        .angle = if (count >= 5) values[4] else 0.0,
        .rotation = if (count >= 6) @intFromFloat(values[5]) else 0,
    };
}

pub fn parseDminSpec(text: []const u8) ![3]f64 {
    var values: [3]f64 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        if (count >= values.len) return error.InvalidDmin;
        values[count] = try std.fmt.parseFloat(f64, std.mem.trim(u8, part, " \t"));
        count += 1;
    }
    if (count != 3) return error.InvalidDmin;
    return values;
}

fn runInfo(allocator: std.mem.Allocator, options: InfoOptions, stdout: anytype) !void {
    const pages = try tiff.loadRgbIrPages(allocator, options.input);
    defer pages.deinit(allocator);
    const dpi = try tiff.readDpi(allocator, options.input);
    try stdout.print("{{\"full_width\":{d},\"full_height\":{d},\"filename\":", .{ pages.rgb.width, pages.rgb.height });
    try writeJsonString(stdout, std.fs.path.basename(options.input));
    try stdout.print(",\"has_ir\":{},\"dpi\":", .{pages.ir != null});
    if (dpi) |value| {
        try stdout.print("{d}", .{value});
    } else {
        try stdout.print("null", .{});
    }
    try stdout.print("}}\n", .{});
}

fn runDetect(allocator: std.mem.Allocator, io: std.Io, options: DetectOptions, stdout: anytype) !void {
    // Detect on the quick preview, as the native UI does (including its
    // single-small-frame fallback), then report full-resolution coordinates
    // for `export --frame`. Like the UI, measure Dmin on the rebate it finds
    // and save it to the processing config.
    const preview = try workflow.loadQuickPreview(allocator, options.input, options.preview_size);
    defer preview.deinit(allocator);
    var result = try workflow.autoDetectPreview(allocator, preview, .{
        .format = options.format,
        .n_frames = options.n_frames,
        .detect_film_extent = options.detect_film_extent,
        .apply_clahe = options.apply_clahe,
        .exact_aspect = options.exact_aspect,
    });
    defer result.deinit(allocator);
    const to_full = 1.0 / preview.info.preview_scale;

    var dmin: ?[3]f64 = null;
    if (result.rebate) |rebate| {
        dmin = try workflow.computeRebateDminFromTiff(allocator, options.input, try workflow.fullResolutionRebate(rebate, preview.info.preview_scale));
        if (options.save) try workflow.saveRebateDmin(allocator, io, options.config_path, dmin.?);
    }

    try stdout.print("{{\"ok\":true,\"aspect\":", .{});
    try writeJsonString(stdout, result.aspect);
    try stdout.print(",\"frames\":[", .{});
    for (result.frames, 0..) |frame, index| {
        if (index != 0) try stdout.print(",", .{});
        try writeFrameJson(stdout, .{ .cx = frame.cx * to_full, .cy = frame.cy * to_full, .w = frame.w * to_full, .h = frame.h * to_full, .angle = frame.angle });
    }
    try stdout.print("],\"rebate\":", .{});
    if (result.rebate) |rebate| {
        try writeRebateJson(stdout, .{ .cx = rebate.cx * to_full, .cy = rebate.cy * to_full, .w = rebate.w * to_full, .h = rebate.h * to_full, .angle = rebate.angle });
    } else {
        try stdout.print("null", .{});
    }
    try stdout.print(",\"dmin\":", .{});
    try writeDminJson(stdout, dmin);
    try stdout.print("}}\n", .{});
}

/// Auto-detects on the scan's quick preview and returns the suggested rebate
/// in full-resolution pixels, or null when detection finds none or fails.
fn detectedRebate(allocator: std.mem.Allocator, input: []const u8, format: []const u8) !?frames.RebateOriginRect {
    const preview = try workflow.loadQuickPreview(allocator, input, default_preview_size);
    defer preview.deinit(allocator);
    var result = workflow.autoDetectPreview(allocator, preview, .{ .format = format }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer result.deinit(allocator);
    const rebate = result.rebate orelse return null;
    return try workflow.fullResolutionRebate(rebate, preview.info.preview_scale);
}

fn writeDminJson(stdout: anytype, dmin: ?[3]f64) !void {
    if (dmin) |value| {
        try stdout.print("[{d},{d},{d}]", .{ value[0], value[1], value[2] });
    } else {
        try stdout.print("null", .{});
    }
}

fn runRebate(allocator: std.mem.Allocator, io: std.Io, options: RebateOptions, stdout: anytype) !void {
    const result = try workflow.processRebateFromTiff(allocator, io, options.input, options.config_path, .{
        .x = options.x,
        .y = options.y,
        .w = options.w,
        .h = options.h,
        .angle = options.angle,
    }, options.save);
    const dmin = result.dmin;
    try stdout.print("{{\"ok\":true,\"dmin\":[{d},{d},{d}]}}\n", .{ dmin[0], dmin[1], dmin[2] });
}

fn runExport(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExportOptions,
    stdout: anytype,
    processing_gpu_request: webgpu.Request,
) !void {
    // Settings come from the processing config, as in the native UI; flags override.
    const loaded_config = try config.loadFile(allocator, io, options.config_path);
    var override_buffer: [config.max_entries]config.Override = undefined;
    const overrides = loaded_config.overrides(&override_buffer);
    const stock_name = options.film_stock orelse loaded_config.activeStock() orelse "kodak_gold";
    const stock = loaded_config.availableStock(stock_name) orelse return error.UnknownFilmStock;

    try std.Io.Dir.cwd().createDirPath(io, options.output_dir);
    const need_ir = options.outputs.needIr();
    var pages = try workflow.loadFullImageAsF64(allocator, options.input, need_ir);
    defer pages.deinit(allocator);
    const current_dpi = options.current_dpi orelse pages.dpi;
    const scan_datetime = try tiff.readDateTime(allocator, options.input);
    defer if (scan_datetime) |datetime| allocator.free(datetime);

    // One Dmin for the whole strip, so every frame gets the same base color:
    // the flag, else the rebate auto-detect finds on this scan, else the saved
    // Dmin (which may come from another scan), else the whole image.
    var dmin = options.dmin;
    var dmin_source: []const u8 = if (dmin != null) "flag" else "none";
    if (dmin == null and options.outputs.needInvert()) {
        if (try detectedRebate(allocator, options.input, options.format)) |rebate| {
            dmin = try workflow.computeRebateDminFromImage(allocator, pages.rgb, rebate);
            dmin_source = "rebate";
        } else if (loaded_config.savedDmin()) |saved| {
            dmin = saved;
            dmin_source = "config";
        } else {
            dmin = try inversion.computeDmin(allocator, pages.rgb.pixels, null, .{});
            dmin_source = "image";
        }
    }

    var aligned_ir: ?export_pipeline.Image = null;
    defer if (aligned_ir) |image| image.deinit(allocator);
    if (need_ir and options.align_ir) {
        if (pages.ir) |ir| {
            const aligned = try allocator.alloc(f64, ir.pixels.len);
            errdefer allocator.free(aligned);
            _ = try ir_processing.alignIr(
                allocator,
                pages.rgb.pixels,
                pages.rgb.width,
                pages.rgb.height,
                ir.pixels,
                ir.width,
                ir.height,
                aligned,
                .{},
            );
            aligned_ir = .{ .width = ir.width, .height = ir.height, .channels = 1, .pixels = aligned };
        }
    }

    const basename = options.basename orelse std.fs.path.stem(std.fs.path.basename(options.input));
    const render_options = workflow.renderOptionsForConfig(current_dpi, overrides);
    var print_spec = print.specForConfig(overrides);
    if (options.print_size) |name| {
        print_spec = if (print.sizeNamed(name)) |size| .{ .size = size, .dpi = if (print_spec) |spec| spec.dpi else print.default_dpi } else null;
    }
    if (options.print_dpi) |dpi| {
        if (print_spec) |*spec| spec.dpi = dpi;
    }
    const ir_scale_x = if (aligned_ir) |ir| @as(f64, @floatFromInt(ir.width)) / @as(f64, @floatFromInt(pages.rgb.width)) else 1.0;
    const ir_scale_y = if (aligned_ir) |ir| @as(f64, @floatFromInt(ir.height)) / @as(f64, @floatFromInt(pages.rgb.height)) else 1.0;
    // Frames go one at a time here, so each may use every core.
    var ir_clean_options = workflow.irCleanOptionsForConfig(current_dpi, workflow.irDpi(current_dpi, ir_scale_x), overrides);
    const inner_workers = @max(1, (std.Thread.getCpuCount() catch 1) -| 1);
    ir_clean_options.defect_mask.adaptive_worker_count = inner_workers;
    ir_clean_options.inpaint.worker_count = inner_workers;
    var written = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (written.items) |name| allocator.free(name);
        written.deinit();
    }
    if (options.emit_events) {
        events.emitExportStart(.{
            .frame_count = options.frame_count,
            .output_dir = options.output_dir,
        });
        const message = try std.fmt.allocPrint(allocator, "Processing {d} frame{s}...", .{
            options.frame_count,
            if (options.frame_count == 1) "" else "s",
        });
        defer allocator.free(message);
        events.emitExportProgress(.{ .message = message });
    }

    if (isCancelled(io, options.cancel_file)) {
        if (options.emit_events) events.emitExportCancelled(.{ .detail = "cancel file observed" });
        try writeExportCancelledResult(stdout, &.{});
        return;
    }

    for (options.frames[0..options.frame_count], 0..) |rect, frame_index| {
        if (isCancelled(io, options.cancel_file)) {
            if (options.emit_events) events.emitExportCancelled(.{ .detail = "cancel file observed" });
            try writeExportCancelledResult(stdout, written.items);
            return;
        }
        const paths = try outputPathsForFrame(allocator, io, options.output_dir, basename, frame_index, options.outputs, print_spec);
        defer paths.deinit(allocator);
        var prng = std.Random.DefaultPrng.init(workflow.frameExportSeed(frame_index));
        const result = try export_pipeline.processFrame(
            allocator,
            frame_index,
            rect,
            pages.rgb,
            aligned_ir,
            ir_scale_x,
            ir_scale_y,
            .{
                .outputs = options.outputs,
                .paths = paths.paths,
                .base_meta = .{
                    .source = std.fs.path.basename(options.input),
                    .crop = rect,
                    .dpi = current_dpi,
                    .datetime = scan_datetime,
                },
                .film_stock = stock_name,
                .stock_coeffs = stock.coeffs,
                .dmin = dmin,
                .render_options = render_options,
                .ir_clean_options = ir_clean_options,
                .invert_request = processing_gpu_request,
                .random = prng.random(),
            },
        );
        defer result.deinit(allocator);
        for (result.written) |name| {
            try written.append(try allocator.dupe(u8, name));
            if (options.emit_events) {
                events.emitFileWritten(.{ .file = name });
            }
        }
    }
    if (options.emit_events) {
        events.emitExportComplete(.{
            .file_count = written.items.len,
            .output_dir = options.output_dir,
        });
    }

    try stdout.print("{{\"message\":\"Exported {d} file{s} to {s}/\",\"files\":[", .{
        written.items.len,
        if (written.items.len == 1) "" else "s",
        options.output_dir,
    });
    for (written.items, 0..) |name, index| {
        if (index != 0) try stdout.print(",", .{});
        try writeJsonString(stdout, name);
    }
    try stdout.print("],\"dmin\":", .{});
    try writeDminJson(stdout, dmin);
    try stdout.print(",\"dmin_source\":\"{s}\"}}\n", .{dmin_source});
}

fn isCancelled(io: std.Io, cancel_file: ?[]const u8) bool {
    const path = cancel_file orelse return false;
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn writeExportCancelledResult(stdout: anytype, files: []const []const u8) !void {
    try stdout.print("{{\"cancelled\":true,\"files\":[", .{});
    for (files, 0..) |name, index| {
        if (index != 0) try stdout.print(",", .{});
        try writeJsonString(stdout, name);
    }
    try stdout.print("]}}\n", .{});
}

const OwnedOutputPaths = struct {
    paths: export_pipeline.OutputPaths,

    fn deinit(self: OwnedOutputPaths, allocator: std.mem.Allocator) void {
        if (self.paths.ir_neg) |path| allocator.free(path);
        if (self.paths.ir_inv) |path| allocator.free(path);
        if (self.paths.inv_only) |path| allocator.free(path);
    }
};

fn outputPathsForFrame(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
    basename: []const u8,
    frame_index: usize,
    outputs: export_pipeline.OutputSelection,
    print_spec: ?print.Spec,
) !OwnedOutputPaths {
    var result = OwnedOutputPaths{ .paths = .{ .print = print_spec } };
    errdefer result.deinit(allocator);
    if (outputs.ir_neg) result.paths.ir_neg = try export_pipeline.uniqueFrameOutputPath(allocator, io, output_dir, basename, frame_index, .ir_neg);
    if (outputs.ir_inv) result.paths.ir_inv = try export_pipeline.uniqueFrameOutputPath(allocator, io, output_dir, basename, frame_index, .ir_inv);
    if (outputs.inv_only) result.paths.inv_only = try export_pipeline.uniqueFrameOutputPath(allocator, io, output_dir, basename, frame_index, .inv_only);
    return result;
}

// Frames and rebates carry radians internally; the CLI prints degrees, the
// unit `export --frame` and `rebate --angle` take.
fn writeFrameJson(stdout: anytype, frame: frames.FrameRect) !void {
    try stdout.print("{{\"cx\":{d},\"cy\":{d},\"w\":{d},\"h\":{d},\"angle_deg\":{d}}}", .{
        frame.cx,
        frame.cy,
        frame.w,
        frame.h,
        std.math.radiansToDegrees(frame.angle),
    });
}

fn writeRebateJson(stdout: anytype, rebate: frames.RebateRect) !void {
    try stdout.print("{{\"cx\":{d},\"cy\":{d},\"w\":{d},\"h\":{d},\"angle_deg\":{d}}}", .{
        rebate.cx,
        rebate.cy,
        rebate.w,
        rebate.h,
        std.math.radiansToDegrees(rebate.angle),
    });
}

fn writeJsonString(stdout: anytype, value: []const u8) !void {
    try stdout.print("\"", .{});
    for (value) |byte| {
        switch (byte) {
            '"' => try stdout.print("\\\"", .{}),
            '\\' => try stdout.print("\\\\", .{}),
            '\n' => try stdout.print("\\n", .{}),
            '\r' => try stdout.print("\\r", .{}),
            '\t' => try stdout.print("\\t", .{}),
            else => try stdout.print("{c}", .{byte}),
        }
    }
    try stdout.print("\"", .{});
}

test "processing CLI parses frame and Dmin specs" {
    const frame = try parseFrameSpec("16, 17, 8, 6, -1.5, 90");
    try std.testing.expectApproxEqAbs(16.0, frame.cx, 0.0);
    try std.testing.expectApproxEqAbs(17.0, frame.cy, 0.0);
    try std.testing.expectApproxEqAbs(8.0, frame.w, 0.0);
    try std.testing.expectApproxEqAbs(6.0, frame.h, 0.0);
    try std.testing.expectApproxEqAbs(-1.5, frame.angle, 0.0);
    try std.testing.expectEqual(@as(i32, 90), frame.rotation);

    const dmin = try parseDminSpec("0.1,0.2,0.3");
    try std.testing.expectApproxEqAbs(0.1, dmin[0], 0.0);
    try std.testing.expectApproxEqAbs(0.2, dmin[1], 0.0);
    try std.testing.expectApproxEqAbs(0.3, dmin[2], 0.0);
}

test "processing CLI prints frame and rebate angles in degrees" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeFrameJson(&writer, .{ .cx = 1, .cy = 2, .w = 3, .h = 4, .angle = std.math.pi / 180.0 * 1.5 });
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"angle_deg\":1.5") != null);
    writer = std.Io.Writer.fixed(&buffer);
    try writeRebateJson(&writer, .{ .cx = 1, .cy = 2, .w = 3, .h = 4, .angle = -std.math.pi / 2.0 });
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"angle_deg\":-90") != null);
}

test "processing CLI parses command options" {
    const info = try parseArgs(&.{ "info", "--input", "scan.tiff" });
    try std.testing.expectEqual(CommandTag.info, std.meta.activeTag(info));
    try std.testing.expectEqualStrings("scan.tiff", info.info.input);

    const detect = try parseArgs(&.{ "detect", "--input", "scan.tiff", "--format", "35mm", "--n-frames", "4", "--no-clahe" });
    try std.testing.expectEqual(CommandTag.detect, std.meta.activeTag(detect));
    try std.testing.expectEqual(@as(?usize, 4), detect.detect.n_frames);
    try std.testing.expect(!detect.detect.apply_clahe);
    try std.testing.expect(detect.detect.save);
    const detect_no_save = try parseArgs(&.{ "detect", "--input", "scan.tiff", "--no-save", "--config", "roll.toml" });
    try std.testing.expect(!detect_no_save.detect.save);
    try std.testing.expectEqualStrings("roll.toml", detect_no_save.detect.config_path);

    const rebate = try parseArgs(&.{ "rebate", "--input", "scan.tiff", "--x", "1", "--y", "2", "--width", "3", "--height", "4", "--angle", "90", "--no-save" });
    try std.testing.expectEqual(CommandTag.rebate, std.meta.activeTag(rebate));
    try std.testing.expect(!rebate.rebate.save);
    try std.testing.expectApproxEqAbs(3.0, rebate.rebate.w, 0.0);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, rebate.rebate.angle, 1e-12);

    const export_cmd = try parseArgs(&.{ "export", "--input", "scan.tiff", "--out-dir", "frames", "--frame", "16,16,8,6,0,90", "--ir-neg", "--inv-only", "--dmin", "0.1,0.2,0.3", "--events", "--cancel-file", "cancel.flag" });
    try std.testing.expectEqual(CommandTag.export_frames, std.meta.activeTag(export_cmd));
    try std.testing.expect(export_cmd.export_frames.outputs.ir_neg);
    try std.testing.expect(export_cmd.export_frames.outputs.ir_inv);
    try std.testing.expect(export_cmd.export_frames.outputs.inv_only);
    try std.testing.expect(export_cmd.export_frames.emit_events);
    try std.testing.expectEqualStrings("cancel.flag", export_cmd.export_frames.cancel_file.?);
    try std.testing.expectEqual(@as(usize, 1), export_cmd.export_frames.frame_count);
    try std.testing.expectApproxEqAbs(0.2, export_cmd.export_frames.dmin.?[1], 0.0);
    try std.testing.expectEqualStrings("35mm", export_cmd.export_frames.format);
    const export_645 = try parseArgs(&.{ "export", "--input", "scan.tiff", "--frame", "16,16,8,6", "--format", "645" });
    try std.testing.expectEqualStrings("645", export_645.export_frames.format);
    try std.testing.expectError(error.InvalidFilmFormat, parseArgs(&.{ "export", "--input", "scan.tiff", "--frame", "16,16,8,6", "--format", "110" }));
}
