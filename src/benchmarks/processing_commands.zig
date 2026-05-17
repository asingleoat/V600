const std = @import("std");
const v600 = @import("v600");

const export_pipeline = v600.processing.export_pipeline;
const film_stocks = v600.processing.film_stocks;
const frames = v600.processing.frames;
const render = v600.processing.render;
const workflow = v600.processing.workflow;

const default_scan = "scans/scan_0006_rgbir_800dpi.tiff";
const default_output_dir = "/tmp/v600-processing-bench";
const default_config_path = "/tmp/v600-processing-bench-config.toml";

const BenchOptions = struct {
    scan_path: []const u8 = default_scan,
    case_filter: []const u8 = "all",
    synthetic_pixels: usize = 1_048_576,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const options = try parseArgs(allocator, init);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print("benchmark,input,width,height,units,elapsed_us,detail\n", .{});

    if (shouldRun(options.case_filter, "render")) {
        try benchSyntheticRender(allocator, stdout, options.synthetic_pixels);
    }

    if (!scanExists(init.io, options.scan_path)) {
        try stdout.print("scan_commands,{s},0,0,0,0,skipped_missing_scan\n", .{options.scan_path});
        return;
    }

    var preview: ?workflow.QuickPreview = null;
    if (shouldRun(options.case_filter, "load_preview") or
        shouldRun(options.case_filter, "inverted_preview") or
        shouldRun(options.case_filter, "auto_detect") or
        shouldRun(options.case_filter, "rebate"))
    {
        const started = monotonicNowNs();
        preview = try workflow.loadQuickPreview(allocator, options.scan_path, 8192);
        const elapsed = monotonicNowNs() - started;
        if (shouldRun(options.case_filter, "load_preview")) {
            const loaded = preview.?;
            try stdout.print("load_preview,{s},{d},{d},{d},{d},{d}\n", .{
                options.scan_path,
                loaded.preview_width,
                loaded.preview_height,
                loaded.preview_width * loaded.preview_height,
                elapsed / std.time.ns_per_us,
                checksumU8(loaded.preview_rgb8),
            });
        }
    }
    defer if (preview) |loaded| loaded.deinit(allocator);

    var auto_result: ?workflow.AutoDetectResult = null;
    defer if (auto_result) |*result| result.deinit(allocator);

    if (preview) |loaded| {
        if (shouldRun(options.case_filter, "inverted_preview")) {
            var cache = workflow.InvertedPreviewCache{};
            defer cache.deinit(allocator);
            const started = monotonicNowNs();
            const rendered = try workflow.renderInvertedPreviewRgb8(allocator, loaded, &cache, .{
                .stock = "kodak_gold",
                .dmin = .{ 0.3229871988296509, 0.48254984617233276, 0.6367867588996887 },
            });
            const elapsed = monotonicNowNs() - started;
            if (rendered) |rgb8| {
                defer allocator.free(rgb8);
                try stdout.print("inverted_preview,{s},{d},{d},{d},{d},{d}\n", .{
                    options.scan_path,
                    loaded.preview_width,
                    loaded.preview_height,
                    loaded.preview_width * loaded.preview_height,
                    elapsed / std.time.ns_per_us,
                    checksumU8(rgb8),
                });
            } else {
                try stdout.print("inverted_preview,{s},{d},{d},{d},{d},skipped_unavailable\n", .{
                    options.scan_path,
                    loaded.preview_width,
                    loaded.preview_height,
                    loaded.preview_width * loaded.preview_height,
                    elapsed / std.time.ns_per_us,
                });
            }
        }

        if (shouldRun(options.case_filter, "auto_detect") or shouldRun(options.case_filter, "rebate")) {
            const started = monotonicNowNs();
            auto_result = try workflow.autoDetectPreview(allocator, loaded, .{
                .format = "35mm",
                .n_frames = 5,
            });
            const elapsed = monotonicNowNs() - started;
            if (shouldRun(options.case_filter, "auto_detect")) {
                const result = auto_result.?;
                try stdout.print("auto_detect,{s},{d},{d},{d},{d},frames={d};aspect={s};checksum={d}\n", .{
                    options.scan_path,
                    loaded.preview_width,
                    loaded.preview_height,
                    loaded.preview_width * loaded.preview_height,
                    elapsed / std.time.ns_per_us,
                    result.frames.len,
                    result.aspect,
                    checksumFrames(result.frames),
                });
            }
        }

        if (shouldRun(options.case_filter, "rebate")) {
            if (auto_result) |result| {
                if (result.rebate) |rebate| {
                    const full = try frames.previewRebateToFullResolution(.{
                        .x = rebate.cx - rebate.w / 2.0,
                        .y = rebate.cy - rebate.h / 2.0,
                        .w = rebate.w,
                        .h = rebate.h,
                        .angle = rebate.angle,
                    }, loaded.info.preview_scale);
                    const started = monotonicNowNs();
                    const rebate_result = try workflow.processRebateFromTiff(
                        allocator,
                        init.io,
                        options.scan_path,
                        default_config_path,
                        full,
                        false,
                    );
                    const elapsed = monotonicNowNs() - started;
                    try stdout.print("rebate_dmin,{s},{d},{d},3,{d},dmin={d:.6}:{d:.6}:{d:.6}\n", .{
                        options.scan_path,
                        @as(usize, @intFromFloat(full.w)),
                        @as(usize, @intFromFloat(full.h)),
                        elapsed / std.time.ns_per_us,
                        rebate_result.dmin[0],
                        rebate_result.dmin[1],
                        rebate_result.dmin[2],
                    });
                } else {
                    try stdout.print("rebate_dmin,{s},0,0,0,0,skipped_no_rebate\n", .{options.scan_path});
                }
            }
        }
    }

    if (shouldRun(options.case_filter, "export_inv_only")) {
        try benchExport(allocator, init.io, stdout, options.scan_path, .{
            .ir_neg = false,
            .ir_inv = false,
            .inv_only = true,
        }, false, "export_inv_only");
    }

    if (shouldRun(options.case_filter, "export_all")) {
        try benchExport(allocator, init.io, stdout, options.scan_path, .{
            .ir_neg = true,
            .ir_inv = true,
            .inv_only = true,
        }, true, "export_all");
    }
}

fn parseArgs(allocator: std.mem.Allocator, init: std.process.Init) !BenchOptions {
    var options = BenchOptions{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scan")) {
            options.scan_path = args.next() orelse return error.MissingScanPath;
        } else if (std.mem.eql(u8, arg, "--case")) {
            options.case_filter = args.next() orelse return error.MissingBenchmarkCase;
        } else if (std.mem.eql(u8, arg, "--pixels")) {
            const value = args.next() orelse return error.MissingPixelCount;
            options.synthetic_pixels = try std.fmt.parseInt(usize, value, 10);
        } else {
            return error.UnknownBenchmarkArg;
        }
    }
    return options;
}

fn shouldRun(filter: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, filter, "all") or std.mem.eql(u8, filter, name);
}

fn scanExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn benchSyntheticRender(
    allocator: std.mem.Allocator,
    stdout: anytype,
    pixel_count: usize,
) !void {
    const sample_count = try std.math.mul(usize, pixel_count, 3);
    const input = try allocator.alloc(f64, sample_count);
    defer allocator.free(input);
    const output = try allocator.alloc(u16, sample_count);
    defer allocator.free(output);
    for (0..pixel_count) |pixel| {
        const base = @as(f64, @floatFromInt((pixel * 7919) % 65535)) / 65535.0;
        input[pixel * 3] = base * 1.25 + 0.01;
        input[pixel * 3 + 1] = @mod(base * 1.73 + 0.13, 1.75) + 0.02;
        input[pixel * 3 + 2] = @mod(base * 2.11 + 0.27, 1.50) + 0.03;
    }

    const started = monotonicNowNs();
    try render.renderToDisplay(allocator, input, output, .{
        .contrast = 1.4,
        .curve_k = 5.0,
        .percentile_lo = 0.5,
        .percentile_hi = 99.5,
        .exposure_compensation = 0.15,
        .color_temp = 0.1,
        .color_tint = -0.05,
    });
    const elapsed = monotonicNowNs() - started;
    try stdout.print("render_synthetic,generated,{d},1,{d},{d},{d}\n", .{
        pixel_count,
        pixel_count,
        elapsed / std.time.ns_per_us,
        checksumU16(output),
    });
}

fn benchExport(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: anytype,
    scan_path: []const u8,
    outputs: export_pipeline.OutputSelection,
    align_ir: bool,
    name: []const u8,
) !void {
    const output_dir = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ default_output_dir, monotonicNowNs() });
    defer allocator.free(output_dir);
    defer std.Io.Dir.cwd().deleteTree(io, output_dir) catch {};

    const rects = [_]export_pipeline.FrameRect{scan0006RepresentativeFrame()};
    const basename = try std.fmt.allocPrint(allocator, "zig_bench_{d}", .{monotonicNowNs()});
    defer allocator.free(basename);

    const started = monotonicNowNs();
    const result = try workflow.processExportFromTiff(allocator, io, .{
        .input_path = scan_path,
        .output_dir = output_dir,
        .basename = basename,
        .rects = &rects,
        .outputs = outputs,
        .active_stock = "kodak_gold",
        .stock_coeffs = film_stocks.kodak_gold_coeffs,
        .dmin = .{ 0.3229871988296509, 0.48254984617233276, 0.6367867588996887 },
        .current_dpi = 800,
        .align_ir = align_ir,
    });
    const elapsed = monotonicNowNs() - started;
    defer result.deinit(allocator);
    try stdout.print("{s},{s},{d},{d},{d},{d},files={d}\n", .{
        name,
        scan_path,
        @as(usize, @intFromFloat(rects[0].w)),
        @as(usize, @intFromFloat(rects[0].h)),
        result.files.len,
        elapsed / std.time.ns_per_us,
        result.files.len,
    });
}

fn scan0006RepresentativeFrame() export_pipeline.FrameRect {
    const x = 334.4;
    const y = 59.1;
    const w = 764.0;
    const h = 1145.9;
    return .{
        .cx = x + w / 2.0,
        .cy = y + h / 2.0,
        .w = w,
        .h = h,
        .angle = 0.0304,
        .rotation = 0,
    };
}

fn checksumU8(values: []const u8) u64 {
    var sum: u64 = 0;
    for (values) |value| sum +%= value;
    return sum;
}

fn checksumU16(values: []const u16) u64 {
    var sum: u64 = 0;
    for (values) |value| sum +%= value;
    return sum;
}

fn checksumFrames(values: []const frames.FrameRect) i64 {
    var sum: f64 = 0.0;
    for (values) |frame| {
        sum += frame.cx + frame.cy + frame.w + frame.h + frame.angle * 1000.0;
    }
    return @intFromFloat(@round(sum * 1000.0));
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
