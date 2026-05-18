const std = @import("std");
const v600 = @import("v600");

const export_pipeline = v600.processing.export_pipeline;
const film_stocks = v600.processing.film_stocks;
const frames = v600.processing.frames;
const inversion = v600.processing.inversion;
const measurement = v600.processing.measurement;
const render = v600.processing.render;
const tiff = v600.tiff;
const webgpu = v600.processing.webgpu;
const workflow = v600.processing.workflow;

const default_scan = "scans/scan_0006_rgbir_800dpi.tiff";
const default_output_dir = "/tmp/v600-processing-bench";
const default_config_path = "/tmp/v600-processing-bench-config.toml";
const benchmark_stock = "kodak_gold";
const benchmark_dmin = [3]f64{ 0.3229871988296509, 0.48254984617233276, 0.6367867588996887 };
const benchmark_35mm_width_mm = 36.0;
const benchmark_35mm_height_mm = 24.0;
const mm_per_inch = 25.4;
const fallback_export_dpi: u32 = 800;
const preview_gpu_max_abs_tolerance = 1;
const export_gpu_max_abs_tolerance = 64;

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
        shouldRun(options.case_filter, "preview_render_u8_vs_u16") or
        shouldRun(options.case_filter, "preview_render_breakdown") or
        shouldRun(options.case_filter, "preview_render_quantile_tradeoff") or
        shouldRun(options.case_filter, "inverted_preview_cpu_vs_gpu") or
        shouldRun(options.case_filter, "invert_negative_preview_cpu_vs_simd") or
        shouldRun(options.case_filter, "invert_negative_preview_u16_vs_f64") or
        shouldRun(options.case_filter, "invert_negative_preview_breakdown") or
        shouldRun(options.case_filter, "invert_negative_preview_lut_tradeoff") or
        shouldRun(options.case_filter, "export_detected_frames") or
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
                .stock = benchmark_stock,
                .dmin = benchmark_dmin,
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

        if (shouldRun(options.case_filter, "inverted_preview_cpu_vs_gpu")) {
            try benchInvertedPreviewPair(allocator, stdout, options.scan_path, loaded);
        }

        if (shouldRun(options.case_filter, "preview_render_u8_vs_u16")) {
            try benchPreviewRenderU8Pair(allocator, stdout, options.scan_path, loaded);
        }

        if (shouldRun(options.case_filter, "preview_render_breakdown")) {
            try benchPreviewRenderBreakdown(allocator, stdout, options.scan_path, loaded);
        }

        if (shouldRun(options.case_filter, "preview_render_quantile_tradeoff")) {
            try benchPreviewRenderQuantileTradeoff(allocator, stdout, options.scan_path, loaded);
        }

        if (shouldRun(options.case_filter, "invert_negative_preview_cpu_vs_simd")) {
            try benchPreviewInvertSimdPair(allocator, stdout, options.scan_path, loaded);
        }

        if (shouldRun(options.case_filter, "invert_negative_preview_u16_vs_f64")) {
            try benchPreviewInvertU16Pair(allocator, stdout, options.scan_path, loaded);
        }

        if (shouldRun(options.case_filter, "invert_negative_preview_breakdown")) {
            try benchPreviewInvertBreakdown(allocator, stdout, options.scan_path, loaded);
        }

        if (shouldRun(options.case_filter, "invert_negative_preview_lut_tradeoff")) {
            try benchPreviewInvertLutTradeoff(allocator, stdout, options.scan_path, loaded);
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

        if (shouldRun(options.case_filter, "export_detected_frames")) {
            const result = if (auto_result) |existing|
                existing
            else blk: {
                auto_result = try workflow.autoDetectPreview(allocator, loaded, .{
                    .format = "35mm",
                    .n_frames = 5,
                });
                break :blk auto_result.?;
            };
            try benchDetectedFrameExport(allocator, init.io, stdout, options.scan_path, loaded, result);
        }
    }

    if (shouldRun(options.case_filter, "export_inv_only")) {
        try benchExport(allocator, init.io, stdout, options.scan_path, .{
            .ir_neg = false,
            .ir_inv = false,
            .inv_only = true,
        }, false, .{}, "export_inv_only");
    }

    if (shouldRun(options.case_filter, "export_inv_only_cpu_vs_gpu")) {
        try benchExportPair(allocator, init.io, stdout, options.scan_path, .{
            .ir_neg = false,
            .ir_inv = false,
            .inv_only = true,
        }, false, "export_inv_only_cpu_vs_gpu");
    }

    if (shouldRun(options.case_filter, "export_fullres_inv_cpu_vs_gpu")) {
        const selection = try fullResolutionBenchmarkSelection(allocator, options.scan_path);
        try benchExportPairWithRect(allocator, init.io, stdout, options.scan_path, .{
            .ir_neg = false,
            .ir_inv = false,
            .inv_only = true,
        }, false, "export_fullres_inv_cpu_vs_gpu", selection.rect, selection.dpi);
    }

    if (shouldRun(options.case_filter, "invert_negative_fullres_cpu_vs_simd")) {
        const selection = try fullResolutionBenchmarkSelection(allocator, options.scan_path);
        try benchFullResolutionInvertSimdPair(allocator, stdout, options.scan_path, selection.rect);
    }

    if (shouldRun(options.case_filter, "export_render_u16_vs_f64")) {
        const selection = try fullResolutionBenchmarkSelection(allocator, options.scan_path);
        try benchExportRenderU16Pair(allocator, stdout, options.scan_path, selection.rect);
    }

    if (shouldRun(options.case_filter, "export_all")) {
        try benchExport(allocator, init.io, stdout, options.scan_path, .{
            .ir_neg = true,
            .ir_inv = true,
            .inv_only = true,
        }, true, .{}, "export_all");
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

fn benchInvertedPreviewPair(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
) !void {
    if (!webgpu.compiled) {
        try stdout.print("inverted_preview_cpu_vs_gpu,{s},{d},{d},{d},0,skipped_webgpu_not_compiled\n", .{
            scan_path,
            loaded.preview_width,
            loaded.preview_height,
            loaded.preview_width * loaded.preview_height,
        });
        return;
    }

    var cpu_cache = workflow.InvertedPreviewCache{};
    defer cpu_cache.deinit(allocator);
    const cpu_started = monotonicNowNs();
    const cpu_rgb = (try workflow.renderInvertedPreviewRgb8(allocator, loaded, &cpu_cache, .{
        .stock = benchmark_stock,
        .dmin = benchmark_dmin,
    })) orelse {
        try stdout.print("inverted_preview_cpu_vs_gpu,{s},{d},{d},{d},0,skipped_unavailable\n", .{
            scan_path,
            loaded.preview_width,
            loaded.preview_height,
            loaded.preview_width * loaded.preview_height,
        });
        return;
    };
    const cpu_elapsed = monotonicNowNs() - cpu_started;
    defer allocator.free(cpu_rgb);

    var gpu_cold_cache = workflow.InvertedPreviewCache{};
    defer gpu_cold_cache.deinit(allocator);
    const gpu_cold_started = monotonicNowNs();
    const gpu_cold_rgb = (try workflow.renderInvertedPreviewRgb8(allocator, loaded, &gpu_cold_cache, .{
        .stock = benchmark_stock,
        .dmin = benchmark_dmin,
        .invert_request = .{ .backend = .webgpu },
    })) orelse return error.InvertedPreviewUnavailable;
    const gpu_cold_elapsed = monotonicNowNs() - gpu_cold_started;
    defer allocator.free(gpu_cold_rgb);

    var gpu_warm_cache = workflow.InvertedPreviewCache{};
    defer gpu_warm_cache.deinit(allocator);
    const gpu_warm_started = monotonicNowNs();
    const gpu_warm_rgb = (try workflow.renderInvertedPreviewRgb8(allocator, loaded, &gpu_warm_cache, .{
        .stock = benchmark_stock,
        .dmin = benchmark_dmin,
        .invert_request = .{ .backend = .webgpu },
    })) orelse return error.InvertedPreviewUnavailable;
    const gpu_warm_elapsed = monotonicNowNs() - gpu_warm_started;
    defer allocator.free(gpu_warm_rgb);

    const cold_diff = try compareU8(cpu_rgb, gpu_cold_rgb);
    if (cold_diff.max_abs > preview_gpu_max_abs_tolerance) return error.GpuPreviewMismatch;
    const diff = try compareU8(cpu_rgb, gpu_warm_rgb);
    if (diff.max_abs > preview_gpu_max_abs_tolerance) return error.GpuPreviewMismatch;
    try stdout.print(
        "inverted_preview_cpu_vs_gpu,{s},{d},{d},{d},{d},cpu_us={d};gpu_cold_us={d};gpu_warm_us={d};cold_speedup_x1000={d};warm_speedup_x1000={d};max_abs={d};rms={d:.3};mismatches={d};checksum_cpu={d};checksum_gpu={d}\n",
        .{
            scan_path,
            loaded.preview_width,
            loaded.preview_height,
            loaded.preview_width * loaded.preview_height,
            gpu_warm_elapsed / std.time.ns_per_us,
            cpu_elapsed / std.time.ns_per_us,
            gpu_cold_elapsed / std.time.ns_per_us,
            gpu_warm_elapsed / std.time.ns_per_us,
            speedupX1000(cpu_elapsed, gpu_cold_elapsed),
            speedupX1000(cpu_elapsed, gpu_warm_elapsed),
            diff.max_abs,
            diff.rms,
            diff.mismatches,
            checksumU8(cpu_rgb),
            checksumU8(gpu_warm_rgb),
        },
    );
}

fn benchPreviewRenderU8Pair(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
) !void {
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, loaded.preview_width, loaded.preview_height), 3);
    if (loaded.preview_raw.len != sample_count) return error.InvalidPreviewBuffer;

    const raw_f64 = try allocator.alloc(f64, loaded.preview_raw.len);
    defer allocator.free(raw_f64);
    for (loaded.preview_raw, raw_f64) |sample, *out| {
        out.* = @floatFromInt(sample);
    }

    const scene = try allocator.alloc(f64, raw_f64.len);
    defer allocator.free(scene);
    _ = try inversion.invertNegative(allocator, raw_f64, scene, .{
        .dmin = benchmark_dmin,
        .coeffs = film_stocks.kodak_gold_coeffs,
    });

    const rendered_u16 = try allocator.alloc(u16, sample_count);
    defer allocator.free(rendered_u16);
    const shifted_u8 = try allocator.alloc(u8, sample_count);
    defer allocator.free(shifted_u8);
    const direct_u8 = try allocator.alloc(u8, sample_count);
    defer allocator.free(direct_u8);

    const old_started = monotonicNowNs();
    try render.renderToDisplay(allocator, scene, rendered_u16, .{});
    for (rendered_u16, shifted_u8) |sample, *out| {
        out.* = @intCast(sample >> 8);
    }
    const old_elapsed = monotonicNowNs() - old_started;

    const direct_started = monotonicNowNs();
    try render.renderToDisplayU8(allocator, scene, direct_u8, .{});
    const direct_elapsed = monotonicNowNs() - direct_started;

    const diff = try compareU8(shifted_u8, direct_u8);

    try stdout.print(
        "preview_render_u8_vs_u16,{s},{d},{d},{d},{d},u16_then_u8_us={d};direct_u8_us={d};speedup_x1000={d};max_abs={d};rms={d:.3};mismatches={d};checksum_u16_shift={d};checksum_u8={d}\n",
        .{
            scan_path,
            loaded.preview_width,
            loaded.preview_height,
            loaded.preview_width * loaded.preview_height,
            direct_elapsed / std.time.ns_per_us,
            old_elapsed / std.time.ns_per_us,
            direct_elapsed / std.time.ns_per_us,
            speedupX1000(old_elapsed, direct_elapsed),
            diff.max_abs,
            diff.rms,
            diff.mismatches,
            checksumU8(shifted_u8),
            checksumU8(direct_u8),
        },
    );
}

const RenderBreakdown = struct {
    allocate_us: u64,
    luminance_us: u64,
    sort_us: u64,
    percentile_us: u64,
    transform_us: u64,
    total_us: u64,
    positive_count: usize,
    lo: f64,
    hi: f64,
};

fn benchPreviewRenderBreakdown(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
) !void {
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, loaded.preview_width, loaded.preview_height), 3);
    if (loaded.preview_raw.len != sample_count) return error.InvalidPreviewBuffer;

    const raw_f64 = try allocator.alloc(f64, loaded.preview_raw.len);
    defer allocator.free(raw_f64);
    for (loaded.preview_raw, raw_f64) |sample, *out| {
        out.* = @floatFromInt(sample);
    }

    const scene = try allocator.alloc(f64, raw_f64.len);
    defer allocator.free(scene);
    _ = try inversion.invertNegative(allocator, raw_f64, scene, .{
        .dmin = benchmark_dmin,
        .coeffs = film_stocks.kodak_gold_coeffs,
    });

    const reference = try allocator.alloc(u8, sample_count);
    defer allocator.free(reference);
    const exact_options: render.RenderToDisplayOptions = .{ .percentile_sample_limit = render.exact_percentile_sample_limit };
    try render.renderToDisplayU8(allocator, scene, reference, exact_options);

    const measured = try allocator.alloc(u8, sample_count);
    defer allocator.free(measured);
    const breakdown = try renderDisplayU8Breakdown(allocator, scene, measured, exact_options);
    const diff = try compareU8(reference, measured);
    if (diff.max_abs != 0) return error.RenderBreakdownMismatch;

    const order_stats_us = breakdown.luminance_us + breakdown.sort_us + breakdown.percentile_us;
    try stdout.print(
        "preview_render_breakdown,{s},{d},{d},{d},{d},total_us={d};allocate_us={d};luminance_us={d};sort_us={d};percentile_us={d};order_stats_us={d};transform_us={d};positive_count={d};lo={d:.9};hi={d:.9};order_stats_pct_x1000={d};transform_pct_x1000={d};max_abs={d};checksum={d}\n",
        .{
            scan_path,
            loaded.preview_width,
            loaded.preview_height,
            loaded.preview_width * loaded.preview_height,
            breakdown.total_us,
            breakdown.total_us,
            breakdown.allocate_us,
            breakdown.luminance_us,
            breakdown.sort_us,
            breakdown.percentile_us,
            order_stats_us,
            breakdown.transform_us,
            breakdown.positive_count,
            breakdown.lo,
            breakdown.hi,
            pctX1000(order_stats_us, breakdown.total_us),
            pctX1000(breakdown.transform_us, breakdown.total_us),
            diff.max_abs,
            checksumU8(measured),
        },
    );
}

fn benchPreviewRenderQuantileTradeoff(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
) !void {
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, loaded.preview_width, loaded.preview_height), 3);
    if (loaded.preview_raw.len != sample_count) return error.InvalidPreviewBuffer;

    const raw_f64 = try allocator.alloc(f64, loaded.preview_raw.len);
    defer allocator.free(raw_f64);
    for (loaded.preview_raw, raw_f64) |sample, *out| {
        out.* = @floatFromInt(sample);
    }

    const scene = try allocator.alloc(f64, raw_f64.len);
    defer allocator.free(scene);
    _ = try inversion.invertNegative(allocator, raw_f64, scene, .{
        .dmin = benchmark_dmin,
        .coeffs = film_stocks.kodak_gold_coeffs,
    });

    const exact = try allocator.alloc(u8, sample_count);
    defer allocator.free(exact);
    const exact_options: render.RenderToDisplayOptions = .{ .percentile_sample_limit = render.exact_percentile_sample_limit };
    const exact_breakdown = try renderDisplayU8Breakdown(allocator, scene, exact, exact_options);
    const exact_elapsed_us = exact_breakdown.total_us;
    try stdout.print(
        "preview_render_quantile_tradeoff,{s},{d},{d},{d},{d},mode=exact_f64;sample_limit={d};exact_us={d};scratch_bytes={d};max_abs=0;rms=0;mismatches=0;mismatch_pct_x1000=0;checksum={d}\n",
        .{
            scan_path,
            loaded.preview_width,
            loaded.preview_height,
            loaded.preview_width * loaded.preview_height,
            exact_elapsed_us,
            render.exact_percentile_sample_limit,
            exact_elapsed_us,
            renderPercentileScratchBytes(loaded.preview_width * loaded.preview_height, render.exact_percentile_sample_limit),
            checksumU8(exact),
        },
    );

    const estimated = try allocator.alloc(u8, sample_count);
    defer allocator.free(estimated);
    const sample_limits = [_]usize{ render.default_percentile_sample_limit, 32_768, 65_536, 131_072, 262_144, 524_288, 1_048_576 };
    for (sample_limits) |sample_limit| {
        const options: render.RenderToDisplayOptions = .{ .percentile_sample_limit = sample_limit };
        const started = monotonicNowNs();
        try render.renderToDisplayU8(allocator, scene, estimated, options);
        const elapsed = monotonicNowNs() - started;
        const diff = try compareU8(exact, estimated);
        try stdout.print(
            "preview_render_quantile_tradeoff,{s},{d},{d},{d},{d},mode=estimate_f32;sample_limit={d};exact_us={d};estimate_us={d};speedup_x1000={d};scratch_bytes={d};max_abs={d};rms={d:.3};mismatches={d};mismatch_pct_x1000={d};checksum_exact={d};checksum_estimate={d}\n",
            .{
                scan_path,
                loaded.preview_width,
                loaded.preview_height,
                loaded.preview_width * loaded.preview_height,
                elapsed / std.time.ns_per_us,
                sample_limit,
                exact_elapsed_us,
                elapsed / std.time.ns_per_us,
                speedupX1000(exact_elapsed_us * std.time.ns_per_us, elapsed),
                renderPercentileScratchBytes(loaded.preview_width * loaded.preview_height, sample_limit),
                diff.max_abs,
                diff.rms,
                diff.mismatches,
                pctX1000(@intCast(diff.mismatches), @intCast(exact.len)),
                checksumU8(exact),
                checksumU8(estimated),
            },
        );
    }
}

fn renderDisplayU8Breakdown(
    allocator: std.mem.Allocator,
    input: []const f64,
    output: []u8,
    options: render.RenderToDisplayOptions,
) !RenderBreakdown {
    if (input.len == 0 or input.len % 3 != 0 or input.len != output.len) return error.InvalidRenderBuffer;
    const total_started = monotonicNowNs();
    const pixel_count = input.len / 3;
    const allocate_started = monotonicNowNs();
    const positive = try allocator.alloc(f64, pixel_count);
    const allocate_elapsed = monotonicNowNs() - allocate_started;
    defer allocator.free(positive);

    const luminance_started = monotonicNowNs();
    var count: usize = 0;
    var index: usize = 0;
    while (index < input.len) : (index += 3) {
        const luminance = 0.2126 * input[index] + 0.7152 * input[index + 1] + 0.0722 * input[index + 2];
        if (luminance > 0.001) {
            positive[count] = luminance;
            count += 1;
        }
    }
    const luminance_elapsed = monotonicNowNs() - luminance_started;

    var lo: f64 = 0.0;
    var hi: f64 = 1.0;
    var sort_elapsed: u64 = 0;
    var percentile_elapsed: u64 = 0;
    if (count != 0) {
        const values = positive[0..count];
        const sort_started = monotonicNowNs();
        std.sort.pdq(f64, values, {}, lessThanF64);
        sort_elapsed = monotonicNowNs() - sort_started;

        const percentile_started = monotonicNowNs();
        lo = percentileSorted(values, options.percentile_lo);
        hi = percentileSorted(values, options.percentile_hi);
        if (hi <= lo) hi = lo + 1.0;
        percentile_elapsed = monotonicNowNs() - percentile_started;
    }

    const transform_started = monotonicNowNs();
    const denominator = hi - lo;
    const apply_color_balance = @abs(options.color_temp) > 0.001 or @abs(options.color_tint) > 0.001;
    const multipliers = if (apply_color_balance)
        colorBalanceMultipliers(options.color_temp, options.color_tint)
    else
        [_]f64{ 1.0, 1.0, 1.0 };
    const apply_exposure = @abs(options.exposure_compensation) > 0.001;
    const exposure_gamma = if (apply_exposure) 1.0 / (1.0 + options.exposure_compensation) else 1.0;
    const apply_contrast = options.contrast > 1.001 and (options.contrast - 1.0) * options.curve_k > 0.1;
    const contrast_k = (options.contrast - 1.0) * options.curve_k;
    const curve_lo = if (apply_contrast) logistic(contrast_k, 0.0) else 0.0;
    const curve_hi = if (apply_contrast) logistic(contrast_k, 1.0) else 1.0;

    for (input, output, 0..) |value, *out, sample_index| {
        var display = clamp((value - lo) / denominator, 0.0, 1.0);
        if (apply_color_balance) {
            display = @max(display * multipliers[sample_index % 3], 0.0);
        }
        if (apply_exposure) {
            display = std.math.pow(f64, display, exposure_gamma);
        }
        if (apply_contrast) {
            const raw = logistic(contrast_k, display);
            display = (raw - curve_lo) / (curve_hi - curve_lo);
        }
        out.* = @intCast(displayToU16(display) >> 8);
    }
    const transform_elapsed = monotonicNowNs() - transform_started;
    const total_elapsed = monotonicNowNs() - total_started;

    return .{
        .allocate_us = allocate_elapsed / std.time.ns_per_us,
        .luminance_us = luminance_elapsed / std.time.ns_per_us,
        .sort_us = sort_elapsed / std.time.ns_per_us,
        .percentile_us = percentile_elapsed / std.time.ns_per_us,
        .transform_us = transform_elapsed / std.time.ns_per_us,
        .total_us = total_elapsed / std.time.ns_per_us,
        .positive_count = count,
        .lo = lo,
        .hi = hi,
    };
}

fn percentileSorted(values: []const f64, percentile: f64) f64 {
    const rank = (@as(f64, @floatFromInt(values.len - 1)) * percentile) / 100.0;
    const lower: usize = @intFromFloat(@floor(rank));
    const upper: usize = @intFromFloat(@ceil(rank));
    const fraction = rank - @as(f64, @floatFromInt(lower));
    return values[lower] * (1.0 - fraction) + values[upper] * fraction;
}

fn colorBalanceMultipliers(color_temp: f64, color_tint: f64) [3]f64 {
    var r_mul = 1.0 + color_temp * 0.5;
    var b_mul = 1.0 - color_temp * 0.5;
    var g_mul = 1.0 - color_tint * 0.5;
    const lum_scale = 0.2126 * r_mul + 0.7152 * g_mul + 0.0722 * b_mul;
    r_mul /= lum_scale;
    g_mul /= lum_scale;
    b_mul /= lum_scale;
    return .{ r_mul, g_mul, b_mul };
}

fn displayToU16(display: f64) u16 {
    return @intFromFloat(clamp(display * 65535.0, 0.0, 65535.0));
}

fn logistic(k: f64, value: f64) f64 {
    return 1.0 / (1.0 + @exp(-k * (value - 0.5)));
}

fn clamp(value: f64, lo: f64, hi: f64) f64 {
    return @min(@max(value, lo), hi);
}

fn lessThanF64(_: void, lhs: f64, rhs: f64) bool {
    return lhs < rhs;
}

fn benchPreviewInvertSimdPair(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
) !void {
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, loaded.preview_width, loaded.preview_height), 3);
    if (loaded.preview_raw.len != sample_count) return error.InvalidPreviewBuffer;
    const input = try allocator.alloc(f64, loaded.preview_raw.len);
    defer allocator.free(input);
    for (loaded.preview_raw, input) |sample, *out| {
        out.* = @floatFromInt(sample);
    }
    try benchInvertSimdPair(
        allocator,
        stdout,
        "invert_negative_preview_cpu_vs_simd",
        scan_path,
        loaded.preview_width,
        loaded.preview_height,
        input,
    );
}

fn benchPreviewInvertU16Pair(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
) !void {
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, loaded.preview_width, loaded.preview_height), 3);
    if (loaded.preview_raw.len != sample_count) return error.InvalidPreviewBuffer;

    const staged_input = try allocator.alloc(f64, loaded.preview_raw.len);
    defer allocator.free(staged_input);
    const staged_output = try allocator.alloc(f64, loaded.preview_raw.len);
    defer allocator.free(staged_output);
    const direct_output = try allocator.alloc(f64, loaded.preview_raw.len);
    defer allocator.free(direct_output);

    const staged_started = monotonicNowNs();
    for (loaded.preview_raw, staged_input) |sample, *out| {
        out.* = @floatFromInt(sample);
    }
    try inversion.invertNegativeProvidedDminSimd(
        staged_input,
        staged_output,
        benchmark_dmin,
        film_stocks.kodak_gold_coeffs,
        65535.0,
    );
    const staged_elapsed = monotonicNowNs() - staged_started;

    const direct_started = monotonicNowNs();
    try inversion.invertNegativeProvidedDminU16Simd(
        loaded.preview_raw,
        direct_output,
        benchmark_dmin,
        film_stocks.kodak_gold_coeffs,
        65535.0,
    );
    const direct_elapsed = monotonicNowNs() - direct_started;

    const diff = try compareF64(staged_output, direct_output, 0.0);
    if (diff.max_abs != 0.0) return error.InversionU16Mismatch;
    try stdout.print(
        "invert_negative_preview_u16_vs_f64,{s},{d},{d},{d},{d},staged_f64_us={d};direct_u16_us={d};speedup_x1000={d};max_abs={d:.12};rms={d:.12};mismatches={d};checksum_f64={d};checksum_u16={d}\n",
        .{
            scan_path,
            loaded.preview_width,
            loaded.preview_height,
            loaded.preview_width * loaded.preview_height,
            direct_elapsed / std.time.ns_per_us,
            staged_elapsed / std.time.ns_per_us,
            direct_elapsed / std.time.ns_per_us,
            speedupX1000(staged_elapsed, direct_elapsed),
            diff.max_abs,
            diff.rms,
            diff.mismatches,
            checksumF64(staged_output),
            checksumF64(direct_output),
        },
    );
}

fn benchPreviewInvertBreakdown(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
) !void {
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, loaded.preview_width, loaded.preview_height), 3);
    if (loaded.preview_raw.len != sample_count) return error.InvalidPreviewBuffer;
    if (!film_stocks.usesOnlyLinearTerms(film_stocks.kodak_gold_coeffs)) return error.BenchmarkRequiresLinearStock;

    const direct_output = try allocator.alloc(f64, loaded.preview_raw.len);
    defer allocator.free(direct_output);
    const net_density = try allocator.alloc(f64, loaded.preview_raw.len);
    defer allocator.free(net_density);
    const staged_output = try allocator.alloc(f64, loaded.preview_raw.len);
    defer allocator.free(staged_output);

    const direct_started = monotonicNowNs();
    try inversion.invertNegativeProvidedDminU16Simd(
        loaded.preview_raw,
        direct_output,
        benchmark_dmin,
        film_stocks.kodak_gold_coeffs,
        65535.0,
    );
    const direct_elapsed = monotonicNowNs() - direct_started;

    const density_started = monotonicNowNs();
    try computeNetDensityU16Simd(loaded.preview_raw, net_density, benchmark_dmin, 65535.0);
    const density_elapsed = monotonicNowNs() - density_started;

    const linear_started = monotonicNowNs();
    try applyLinearStockSimd(net_density, staged_output, film_stocks.kodak_gold_coeffs);
    const linear_elapsed = monotonicNowNs() - linear_started;

    const staged_elapsed = density_elapsed + linear_elapsed;
    const diff = try compareF64(direct_output, staged_output, 0.0);
    try stdout.print(
        "invert_negative_preview_breakdown,{s},{d},{d},{d},{d},direct_u16_us={d};density_us={d};linear_transform_us={d};staged_total_us={d};density_pct_x1000={d};linear_pct_x1000={d};direct_fused_speedup_x1000={d};max_abs={d:.12};rms={d:.12};mismatches={d};checksum_direct={d};checksum_staged={d}\n",
        .{
            scan_path,
            loaded.preview_width,
            loaded.preview_height,
            loaded.preview_width * loaded.preview_height,
            direct_elapsed / std.time.ns_per_us,
            direct_elapsed / std.time.ns_per_us,
            density_elapsed / std.time.ns_per_us,
            linear_elapsed / std.time.ns_per_us,
            staged_elapsed / std.time.ns_per_us,
            pctX1000(density_elapsed / std.time.ns_per_us, staged_elapsed / std.time.ns_per_us),
            pctX1000(linear_elapsed / std.time.ns_per_us, staged_elapsed / std.time.ns_per_us),
            speedupX1000(staged_elapsed, direct_elapsed),
            diff.max_abs,
            diff.rms,
            diff.mismatches,
            checksumF64(direct_output),
            checksumF64(staged_output),
        },
    );
}

fn benchPreviewInvertLutTradeoff(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
) !void {
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, loaded.preview_width, loaded.preview_height), 3);
    if (loaded.preview_raw.len != sample_count) return error.InvalidPreviewBuffer;
    if (!film_stocks.usesOnlyLinearTerms(film_stocks.kodak_gold_coeffs)) return error.BenchmarkRequiresLinearStock;

    const reference_scene = try allocator.alloc(f64, loaded.preview_raw.len);
    defer allocator.free(reference_scene);
    const direct_started = monotonicNowNs();
    try inversion.invertNegativeProvidedDminU16Simd(
        loaded.preview_raw,
        reference_scene,
        benchmark_dmin,
        film_stocks.kodak_gold_coeffs,
        65535.0,
    );
    const direct_elapsed = monotonicNowNs() - direct_started;

    const reference_u8 = try allocator.alloc(u8, sample_count);
    defer allocator.free(reference_u8);
    try render.renderToDisplayU8(allocator, reference_scene, reference_u8, .{});

    const reference_u16 = try allocator.alloc(u16, sample_count);
    defer allocator.free(reference_u16);
    try render.renderToDisplay(allocator, reference_scene, reference_u16, .{});

    try stdout.print(
        "invert_negative_preview_lut_tradeoff,{s},{d},{d},{d},{d},variant=direct_u16_simd;build_us=0;apply_us={d};total_us={d};scene_max_abs=0;scene_rms=0;scene_mismatches=0;u8_max_abs=0;u8_rms=0;u8_mismatches=0;u16_max_abs=0;u16_rms=0;u16_mismatches=0;checksum_scene={d};checksum_u8={d};checksum_u16={d}\n",
        .{
            scan_path,
            loaded.preview_width,
            loaded.preview_height,
            loaded.preview_width * loaded.preview_height,
            direct_elapsed / std.time.ns_per_us,
            direct_elapsed / std.time.ns_per_us,
            direct_elapsed / std.time.ns_per_us,
            checksumF64(reference_scene),
            checksumU8(reference_u8),
            checksumU16(reference_u16),
        },
    );

    {
        const variant_scene = try allocator.alloc(f64, loaded.preview_raw.len);
        defer allocator.free(variant_scene);
        const build_started = monotonicNowNs();
        const lut = try inversion.DensityLutF64.init(allocator, benchmark_dmin, 65535.0);
        const build_elapsed = monotonicNowNs() - build_started;
        defer lut.deinit(allocator);
        const apply_started = monotonicNowNs();
        try inversion.invertNegativeProvidedDminU16WithDensityLutF64(
            loaded.preview_raw,
            variant_scene,
            lut,
            film_stocks.kodak_gold_coeffs,
        );
        const apply_elapsed = monotonicNowNs() - apply_started;
        try printLutTradeoffRow(
            allocator,
            stdout,
            scan_path,
            loaded,
            "f64_density_lut_to_f64",
            build_elapsed,
            apply_elapsed,
            direct_elapsed,
            reference_scene,
            reference_u8,
            reference_u16,
            variant_scene,
        );
    }

    const f32_build_started = monotonicNowNs();
    const lut_f32 = try inversion.DensityLutF32.init(allocator, benchmark_dmin, 65535.0);
    const f32_build_elapsed = monotonicNowNs() - f32_build_started;
    defer lut_f32.deinit(allocator);

    {
        const variant_scene = try allocator.alloc(f64, loaded.preview_raw.len);
        defer allocator.free(variant_scene);
        const apply_started = monotonicNowNs();
        try inversion.invertNegativeProvidedDminU16WithDensityLutF32(
            loaded.preview_raw,
            variant_scene,
            lut_f32,
            film_stocks.kodak_gold_coeffs,
        );
        const apply_elapsed = monotonicNowNs() - apply_started;
        try printLutTradeoffRow(
            allocator,
            stdout,
            scan_path,
            loaded,
            "f32_density_lut_to_f64",
            f32_build_elapsed,
            apply_elapsed,
            direct_elapsed,
            reference_scene,
            reference_u8,
            reference_u16,
            variant_scene,
        );
    }

    {
        const variant_scene_f32 = try allocator.alloc(f32, loaded.preview_raw.len);
        defer allocator.free(variant_scene_f32);
        const variant_scene = try allocator.alloc(f64, loaded.preview_raw.len);
        defer allocator.free(variant_scene);
        const apply_started = monotonicNowNs();
        try inversion.invertNegativeProvidedDminU16WithDensityLutF32OutputF32(
            loaded.preview_raw,
            variant_scene_f32,
            lut_f32,
            film_stocks.kodak_gold_coeffs,
        );
        const apply_elapsed = monotonicNowNs() - apply_started;
        widenF32ToF64(variant_scene_f32, variant_scene);
        try printLutTradeoffRow(
            allocator,
            stdout,
            scan_path,
            loaded,
            "f32_density_lut_to_f32_widened",
            f32_build_elapsed,
            apply_elapsed,
            direct_elapsed,
            reference_scene,
            reference_u8,
            reference_u16,
            variant_scene,
        );
    }
}

fn printLutTradeoffRow(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
    variant: []const u8,
    build_elapsed: u64,
    apply_elapsed: u64,
    direct_elapsed: u64,
    reference_scene: []const f64,
    reference_u8: []const u8,
    reference_u16: []const u16,
    variant_scene: []const f64,
) !void {
    const scene_diff = try compareF64(reference_scene, variant_scene, 0.0);

    const variant_u8 = try allocator.alloc(u8, reference_u8.len);
    defer allocator.free(variant_u8);
    try render.renderToDisplayU8(allocator, variant_scene, variant_u8, .{});
    const u8_diff = try compareU8(reference_u8, variant_u8);

    const variant_u16 = try allocator.alloc(u16, reference_u16.len);
    defer allocator.free(variant_u16);
    try render.renderToDisplay(allocator, variant_scene, variant_u16, .{});
    const u16_diff = try compareU16(reference_u16, variant_u16);

    const total_elapsed = build_elapsed + apply_elapsed;
    try stdout.print(
        "invert_negative_preview_lut_tradeoff,{s},{d},{d},{d},{d},variant={s};build_us={d};apply_us={d};total_us={d};apply_speedup_x1000={d};total_speedup_x1000={d};scene_max_abs={d:.12};scene_rms={d:.12};scene_mse={d:.18};scene_mismatches={d};u8_max_abs={d};u8_rms={d:.6};u8_mse={d:.9};u8_mismatches={d};u16_max_abs={d};u16_rms={d:.6};u16_mse={d:.9};u16_mismatches={d};checksum_scene={d};checksum_u8={d};checksum_u16={d}\n",
        .{
            scan_path,
            loaded.preview_width,
            loaded.preview_height,
            loaded.preview_width * loaded.preview_height,
            total_elapsed / std.time.ns_per_us,
            variant,
            build_elapsed / std.time.ns_per_us,
            apply_elapsed / std.time.ns_per_us,
            total_elapsed / std.time.ns_per_us,
            speedupX1000(direct_elapsed, apply_elapsed),
            speedupX1000(direct_elapsed, total_elapsed),
            scene_diff.max_abs,
            scene_diff.rms,
            scene_diff.mse,
            scene_diff.mismatches,
            u8_diff.max_abs,
            u8_diff.rms,
            u8_diff.mse,
            u8_diff.mismatches,
            u16_diff.max_abs,
            u16_diff.rms,
            u16_diff.mse,
            u16_diff.mismatches,
            checksumF64(variant_scene),
            checksumU8(variant_u8),
            checksumU16(variant_u16),
        },
    );
}

const bench_simd_width = 4;
const BenchSimdF64 = @Vector(bench_simd_width, f64);

fn computeNetDensityU16Simd(raw_rgb: []const u16, output: []f64, dmin: [3]f64, default_light: f64) !void {
    if (raw_rgb.len != output.len or raw_rgb.len == 0 or raw_rgb.len % 3 != 0) {
        return error.InvalidInversionBuffer;
    }
    if (!std.math.isFinite(default_light) or default_light < measurement.eps) {
        return error.InvalidNormalizeReference;
    }

    const pixel_count = raw_rgb.len / 3;
    const inv_light: BenchSimdF64 = @splat(1.0 / default_light);
    const eps_v: BenchSimdF64 = @splat(measurement.eps);
    const log2_to_log10: BenchSimdF64 = @splat(0.3010299956639812);
    const zero: BenchSimdF64 = @splat(0.0);
    const dmin_r: BenchSimdF64 = @splat(dmin[0]);
    const dmin_g: BenchSimdF64 = @splat(dmin[1]);
    const dmin_b: BenchSimdF64 = @splat(dmin[2]);

    var pixel: usize = 0;
    while (pixel + bench_simd_width <= pixel_count) : (pixel += bench_simd_width) {
        const base = pixel * 3;
        const raw_r: BenchSimdF64 = .{
            @floatFromInt(raw_rgb[base]),
            @floatFromInt(raw_rgb[base + 3]),
            @floatFromInt(raw_rgb[base + 6]),
            @floatFromInt(raw_rgb[base + 9]),
        };
        const raw_g: BenchSimdF64 = .{
            @floatFromInt(raw_rgb[base + 1]),
            @floatFromInt(raw_rgb[base + 4]),
            @floatFromInt(raw_rgb[base + 7]),
            @floatFromInt(raw_rgb[base + 10]),
        };
        const raw_b: BenchSimdF64 = .{
            @floatFromInt(raw_rgb[base + 2]),
            @floatFromInt(raw_rgb[base + 5]),
            @floatFromInt(raw_rgb[base + 8]),
            @floatFromInt(raw_rgb[base + 11]),
        };

        const tr = @max(raw_r * inv_light, eps_v);
        const tg = @max(raw_g * inv_light, eps_v);
        const tb = @max(raw_b * inv_light, eps_v);
        const dr = @max(-@log2(tr) * log2_to_log10 - dmin_r, zero);
        const dg = @max(-@log2(tg) * log2_to_log10 - dmin_g, zero);
        const db = @max(-@log2(tb) * log2_to_log10 - dmin_b, zero);

        inline for (0..bench_simd_width) |lane| {
            output[base + lane * 3] = dr[lane];
            output[base + lane * 3 + 1] = dg[lane];
            output[base + lane * 3 + 2] = db[lane];
        }
    }

    while (pixel < pixel_count) : (pixel += 1) {
        const base = pixel * 3;
        const tr = @max(@as(f64, @floatFromInt(raw_rgb[base])) / default_light, measurement.eps);
        const tg = @max(@as(f64, @floatFromInt(raw_rgb[base + 1])) / default_light, measurement.eps);
        const tb = @max(@as(f64, @floatFromInt(raw_rgb[base + 2])) / default_light, measurement.eps);
        output[base] = @max(-std.math.log2(tr) * 0.3010299956639812 - dmin[0], 0.0);
        output[base + 1] = @max(-std.math.log2(tg) * 0.3010299956639812 - dmin[1], 0.0);
        output[base + 2] = @max(-std.math.log2(tb) * 0.3010299956639812 - dmin[2], 0.0);
    }
}

fn applyLinearStockSimd(input: []const f64, output: []f64, coeffs: film_stocks.Coefficients) !void {
    if (input.len != output.len or input.len == 0 or input.len % 3 != 0) {
        return error.InvalidInversionBuffer;
    }
    if (!film_stocks.usesOnlyLinearTerms(coeffs)) return error.BenchmarkRequiresLinearStock;

    const pixel_count = input.len / 3;
    const zero: BenchSimdF64 = @splat(0.0);
    const c00: BenchSimdF64 = @splat(coeffs[0][0]);
    const c01: BenchSimdF64 = @splat(coeffs[0][1]);
    const c02: BenchSimdF64 = @splat(coeffs[0][2]);
    const c10: BenchSimdF64 = @splat(coeffs[1][0]);
    const c11: BenchSimdF64 = @splat(coeffs[1][1]);
    const c12: BenchSimdF64 = @splat(coeffs[1][2]);
    const c20: BenchSimdF64 = @splat(coeffs[2][0]);
    const c21: BenchSimdF64 = @splat(coeffs[2][1]);
    const c22: BenchSimdF64 = @splat(coeffs[2][2]);

    var pixel: usize = 0;
    while (pixel + bench_simd_width <= pixel_count) : (pixel += bench_simd_width) {
        const base = pixel * 3;
        const dr: BenchSimdF64 = .{ input[base], input[base + 3], input[base + 6], input[base + 9] };
        const dg: BenchSimdF64 = .{ input[base + 1], input[base + 4], input[base + 7], input[base + 10] };
        const db: BenchSimdF64 = .{ input[base + 2], input[base + 5], input[base + 8], input[base + 11] };

        const out_r = @max(dr * c00 + dg * c10 + db * c20, zero);
        const out_g = @max(dr * c01 + dg * c11 + db * c21, zero);
        const out_b = @max(dr * c02 + dg * c12 + db * c22, zero);

        inline for (0..bench_simd_width) |lane| {
            output[base + lane * 3] = out_r[lane];
            output[base + lane * 3 + 1] = out_g[lane];
            output[base + lane * 3 + 2] = out_b[lane];
        }
    }

    while (pixel < pixel_count) : (pixel += 1) {
        const base = pixel * 3;
        const transformed = film_stocks.applyLinearTerms(coeffs, .{
            input[base],
            input[base + 1],
            input[base + 2],
        });
        output[base] = @max(transformed[0], 0.0);
        output[base + 1] = @max(transformed[1], 0.0);
        output[base + 2] = @max(transformed[2], 0.0);
    }
}

fn benchFullResolutionInvertSimdPair(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_path: []const u8,
    rect: export_pipeline.FrameRect,
) !void {
    const image = try workflow.loadRgbImageAsF64(allocator, scan_path);
    defer image.deinit(allocator);
    const crop = try export_pipeline.cropFrame(allocator, image.pixels, image.width, image.height, image.channels, rect);
    defer crop.deinit(allocator);
    if (crop.channels != 3) return error.InvalidExportImage;
    try benchInvertSimdPair(
        allocator,
        stdout,
        "invert_negative_fullres_cpu_vs_simd",
        scan_path,
        crop.width,
        crop.height,
        crop.pixels,
    );
}

fn benchExportRenderU16Pair(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_path: []const u8,
    rect: export_pipeline.FrameRect,
) !void {
    const image = try workflow.loadRgbImageAsF64(allocator, scan_path);
    defer image.deinit(allocator);
    const crop = try export_pipeline.cropFrame(allocator, image.pixels, image.width, image.height, image.channels, rect);
    defer crop.deinit(allocator);

    const old_started = monotonicNowNs();
    const old = try export_pipeline.prepareInvertedPositiveOutput(allocator, crop, .{
        .dmin = benchmark_dmin,
        .coeffs = film_stocks.kodak_gold_coeffs,
    }, .{}, rect.rotation);
    const old_elapsed = monotonicNowNs() - old_started;
    defer old.deinit(allocator);

    const direct_started = monotonicNowNs();
    const direct = try export_pipeline.prepareInvertedPositiveOutputU16(allocator, crop, .{
        .dmin = benchmark_dmin,
        .coeffs = film_stocks.kodak_gold_coeffs,
    }, .{}, rect.rotation);
    const direct_elapsed = monotonicNowNs() - direct_started;
    defer direct.deinit(allocator);

    const old_u16 = try allocator.alloc(u16, old.pixels.len);
    defer allocator.free(old_u16);
    for (old.pixels, old_u16) |value, *sample| {
        const clipped = @min(@max(value, 0.0), 65535.0);
        sample.* = @intFromFloat(@round(clipped));
    }
    const diff = try compareU16(old_u16, direct.pixels);
    if (diff.max_abs != 0) return error.ExportRenderU16Mismatch;

    try stdout.print(
        "export_render_u16_vs_f64,{s},{d},{d},{d},{d},f64_display_us={d};direct_u16_us={d};speedup_x1000={d};max_abs={d};rms={d:.3};mismatches={d};checksum_f64={d};checksum_u16={d}\n",
        .{
            scan_path,
            direct.width,
            direct.height,
            direct.width * direct.height,
            direct_elapsed / std.time.ns_per_us,
            old_elapsed / std.time.ns_per_us,
            direct_elapsed / std.time.ns_per_us,
            speedupX1000(old_elapsed, direct_elapsed),
            diff.max_abs,
            diff.rms,
            diff.mismatches,
            checksumU16(old_u16),
            checksumU16(direct.pixels),
        },
    );
}

fn benchInvertSimdPair(
    allocator: std.mem.Allocator,
    stdout: anytype,
    name: []const u8,
    scan_path: []const u8,
    width: usize,
    height: usize,
    input: []const f64,
) !void {
    const scalar = try allocator.alloc(f64, input.len);
    defer allocator.free(scalar);
    const simd = try allocator.alloc(f64, input.len);
    defer allocator.free(simd);

    const scalar_started = monotonicNowNs();
    try inversion.invertNegativeProvidedDminScalar(
        allocator,
        input,
        scalar,
        benchmark_dmin,
        film_stocks.kodak_gold_coeffs,
        .{ .default_light = 65535.0 },
    );
    const scalar_elapsed = monotonicNowNs() - scalar_started;

    const simd_started = monotonicNowNs();
    try inversion.invertNegativeProvidedDminSimd(
        input,
        simd,
        benchmark_dmin,
        film_stocks.kodak_gold_coeffs,
        65535.0,
    );
    const simd_elapsed = monotonicNowNs() - simd_started;

    const diff = try compareF64(scalar, simd, 0.000000001);
    try stdout.print(
        "{s},{s},{d},{d},{d},{d},cpu_us={d};simd_us={d};speedup_x1000={d};max_abs={d:.12};rms={d:.12};mismatches={d};checksum_cpu={d};checksum_simd={d}\n",
        .{
            name,
            scan_path,
            width,
            height,
            width * height,
            simd_elapsed / std.time.ns_per_us,
            scalar_elapsed / std.time.ns_per_us,
            simd_elapsed / std.time.ns_per_us,
            speedupX1000(scalar_elapsed, simd_elapsed),
            diff.max_abs,
            diff.rms,
            diff.mismatches,
            checksumF64(scalar),
            checksumF64(simd),
        },
    );
}

const ExportCapture = struct {
    output_dir: []u8,
    result: workflow.ExportWorkflowResult,
    elapsed_ns: u64,

    pub fn deinit(self: *ExportCapture, allocator: std.mem.Allocator, io: std.Io) void {
        self.result.deinit(allocator);
        std.Io.Dir.cwd().deleteTree(io, self.output_dir) catch {};
        allocator.free(self.output_dir);
    }
};

fn benchExport(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: anytype,
    scan_path: []const u8,
    outputs: export_pipeline.OutputSelection,
    align_ir: bool,
    invert_request: webgpu.Request,
    name: []const u8,
) !void {
    const basename = try std.fmt.allocPrint(allocator, "zig_bench_{d}", .{monotonicNowNs()});
    defer allocator.free(basename);

    var capture = try runExportCapture(allocator, io, scan_path, outputs, align_ir, invert_request, basename);
    defer capture.deinit(allocator, io);
    const rect = scan0006RepresentativeFrame();
    try stdout.print("{s},{s},{d},{d},{d},{d},files={d}\n", .{
        name,
        scan_path,
        @as(usize, @intFromFloat(rect.w)),
        @as(usize, @intFromFloat(rect.h)),
        capture.result.files.len,
        capture.elapsed_ns / std.time.ns_per_us,
        capture.result.files.len,
    });
}

fn benchDetectedFrameExport(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
    detected: workflow.AutoDetectResult,
) !void {
    if (detected.frames.len == 0) {
        try stdout.print("export_detected_frames,{s},0,0,0,0,skipped_no_frames\n", .{scan_path});
        return;
    }

    const rects = try allocator.alloc(export_pipeline.FrameRect, detected.frames.len);
    defer allocator.free(rects);
    var total_pixels: usize = 0;
    for (detected.frames, rects) |frame, *out| {
        const full = try frames.previewFrameToFullResolution(frame, loaded.info.preview_scale);
        out.* = .{
            .cx = full.cx,
            .cy = full.cy,
            .w = full.w,
            .h = full.h,
            .angle = full.angle,
            .rotation = 0,
        };
        total_pixels += @as(usize, @intFromFloat(full.w)) * @as(usize, @intFromFloat(full.h));
    }

    const basename = try std.fmt.allocPrint(allocator, "zig_bench_detected_{d}", .{monotonicNowNs()});
    defer allocator.free(basename);
    var capture = try runExportCaptureWithRects(allocator, io, scan_path, .{
        .ir_neg = false,
        .ir_inv = false,
        .inv_only = true,
    }, false, .{}, basename, rects, loaded.info.dpi orelse fallback_export_dpi, true);
    defer capture.deinit(allocator, io);
    const serial_basename = try std.fmt.allocPrint(allocator, "zig_bench_detected_serial_{d}", .{monotonicNowNs()});
    defer allocator.free(serial_basename);
    var serial = try runExportCaptureWithRects(allocator, io, scan_path, .{
        .ir_neg = false,
        .ir_inv = false,
        .inv_only = true,
    }, false, .{}, serial_basename, rects, loaded.info.dpi orelse fallback_export_dpi, false);
    defer serial.deinit(allocator, io);
    const parallelism: workflow.ExportParallelismDecision = capture.result.parallelism orelse .{
        .worker_count = 0,
        .cpu_count = 0,
        .cpu_worker_limit = 0,
        .memory_worker_limit = null,
        .available_memory_bytes = null,
        .memory_budget_bytes = null,
        .estimated_worker_peak_bytes = 0,
        .adjusted_worker_peak_bytes = 0,
        .memory_limited = false,
    };
    try stdout.print("export_detected_frames,{s},{d},{d},{d},{d},frames={d};files={d};workers={d};cpu_limit={d};mem_limit={d};estimated_worker_peak_bytes={d};adjusted_worker_peak_bytes={d};serial_us={d};parallel_us={d};speedup_x1000={d};checksum={d}\n", .{
        scan_path,
        @as(usize, @intFromFloat(rects[0].w)),
        @as(usize, @intFromFloat(rects[0].h)),
        total_pixels,
        capture.elapsed_ns / std.time.ns_per_us,
        rects.len,
        capture.result.files.len,
        parallelism.worker_count,
        parallelism.cpu_worker_limit,
        parallelism.memory_worker_limit orelse 0,
        parallelism.estimated_worker_peak_bytes,
        parallelism.adjusted_worker_peak_bytes,
        serial.elapsed_ns / std.time.ns_per_us,
        capture.elapsed_ns / std.time.ns_per_us,
        speedupX1000(serial.elapsed_ns, capture.elapsed_ns),
        checksumStrings(capture.result.files),
    });
}

fn benchExportPair(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: anytype,
    scan_path: []const u8,
    outputs: export_pipeline.OutputSelection,
    align_ir: bool,
    name: []const u8,
) !void {
    try benchExportPairWithRect(allocator, io, stdout, scan_path, outputs, align_ir, name, scan0006RepresentativeFrame(), 800);
}

fn benchExportPairWithRect(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: anytype,
    scan_path: []const u8,
    outputs: export_pipeline.OutputSelection,
    align_ir: bool,
    name: []const u8,
    rect: export_pipeline.FrameRect,
    current_dpi: u32,
) !void {
    if (!webgpu.compiled) {
        try stdout.print("{s},{s},{d},{d},0,0,skipped_webgpu_not_compiled\n", .{
            name,
            scan_path,
            @as(usize, @intFromFloat(rect.w)),
            @as(usize, @intFromFloat(rect.h)),
        });
        return;
    }

    const basename = try std.fmt.allocPrint(allocator, "zig_bench_pair_{d}", .{monotonicNowNs()});
    defer allocator.free(basename);

    var cpu = try runExportCaptureWithRect(allocator, io, scan_path, outputs, align_ir, .{}, basename, rect, current_dpi);
    defer cpu.deinit(allocator, io);
    var gpu_cold = try runExportCaptureWithRect(allocator, io, scan_path, outputs, align_ir, .{ .backend = .webgpu }, basename, rect, current_dpi);
    defer gpu_cold.deinit(allocator, io);
    var gpu_warm = try runExportCaptureWithRect(allocator, io, scan_path, outputs, align_ir, .{ .backend = .webgpu }, basename, rect, current_dpi);
    defer gpu_warm.deinit(allocator, io);

    const cold_comparison = try compareFirstExport(allocator, cpu.output_dir, cpu.result, gpu_cold.output_dir, gpu_cold.result);
    if (!cold_comparison.metadata_equal) return error.GpuExportMetadataMismatch;
    if (cold_comparison.diff.max_abs > export_gpu_max_abs_tolerance) return error.GpuExportPixelMismatch;
    const comparison = try compareFirstExport(allocator, cpu.output_dir, cpu.result, gpu_warm.output_dir, gpu_warm.result);
    if (!comparison.metadata_equal) return error.GpuExportMetadataMismatch;
    if (comparison.diff.max_abs > export_gpu_max_abs_tolerance) return error.GpuExportPixelMismatch;
    try stdout.print(
        "{s},{s},{d},{d},{d},{d},cpu_us={d};gpu_cold_us={d};gpu_warm_us={d};cold_speedup_x1000={d};warm_speedup_x1000={d};max_abs={d};rms={d:.3};mismatches={d};metadata_equal={};file_name_equal={};files={d}\n",
        .{
            name,
            scan_path,
            @as(usize, @intFromFloat(rect.w)),
            @as(usize, @intFromFloat(rect.h)),
            cpu.result.files.len,
            gpu_warm.elapsed_ns / std.time.ns_per_us,
            cpu.elapsed_ns / std.time.ns_per_us,
            gpu_cold.elapsed_ns / std.time.ns_per_us,
            gpu_warm.elapsed_ns / std.time.ns_per_us,
            speedupX1000(cpu.elapsed_ns, gpu_cold.elapsed_ns),
            speedupX1000(cpu.elapsed_ns, gpu_warm.elapsed_ns),
            comparison.diff.max_abs,
            comparison.diff.rms,
            comparison.diff.mismatches,
            comparison.metadata_equal,
            comparison.file_name_equal,
            gpu_warm.result.files.len,
        },
    );
}

fn runExportCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    scan_path: []const u8,
    outputs: export_pipeline.OutputSelection,
    align_ir: bool,
    invert_request: webgpu.Request,
    basename: []const u8,
) !ExportCapture {
    return runExportCaptureWithRect(
        allocator,
        io,
        scan_path,
        outputs,
        align_ir,
        invert_request,
        basename,
        scan0006RepresentativeFrame(),
        800,
    );
}

fn runExportCaptureWithRect(
    allocator: std.mem.Allocator,
    io: std.Io,
    scan_path: []const u8,
    outputs: export_pipeline.OutputSelection,
    align_ir: bool,
    invert_request: webgpu.Request,
    basename: []const u8,
    rect: export_pipeline.FrameRect,
    current_dpi: u32,
) !ExportCapture {
    if (invert_request.backend == .webgpu and !webgpu.compiled) return error.WebGpuNotCompiled;
    const rects = [_]export_pipeline.FrameRect{rect};
    return runExportCaptureWithRects(allocator, io, scan_path, outputs, align_ir, invert_request, basename, &rects, current_dpi, true);
}

fn runExportCaptureWithRects(
    allocator: std.mem.Allocator,
    io: std.Io,
    scan_path: []const u8,
    outputs: export_pipeline.OutputSelection,
    align_ir: bool,
    invert_request: webgpu.Request,
    basename: []const u8,
    rects: []const export_pipeline.FrameRect,
    current_dpi: u32,
    parallel_frames: bool,
) !ExportCapture {
    if (invert_request.backend == .webgpu and !webgpu.compiled) return error.WebGpuNotCompiled;
    const output_dir = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ default_output_dir, monotonicNowNs() });
    errdefer allocator.free(output_dir);
    errdefer std.Io.Dir.cwd().deleteTree(io, output_dir) catch {};

    const started = monotonicNowNs();
    var result = try workflow.processExportFromTiff(allocator, io, .{
        .input_path = scan_path,
        .output_dir = output_dir,
        .basename = basename,
        .rects = rects,
        .outputs = outputs,
        .active_stock = benchmark_stock,
        .stock_coeffs = film_stocks.kodak_gold_coeffs,
        .dmin = benchmark_dmin,
        .current_dpi = current_dpi,
        .align_ir = align_ir,
        .invert_request = invert_request,
        .parallel_frames = parallel_frames,
    });
    errdefer result.deinit(allocator);
    return .{
        .output_dir = output_dir,
        .result = result,
        .elapsed_ns = monotonicNowNs() - started,
    };
}

const FullResolutionBenchmarkSelection = struct {
    rect: export_pipeline.FrameRect,
    dpi: u32,
};

fn fullResolutionBenchmarkSelection(
    allocator: std.mem.Allocator,
    scan_path: []const u8,
) !FullResolutionBenchmarkSelection {
    const image = try tiff.loadRgbPage(allocator, scan_path);
    defer image.deinit(allocator);
    const dpi = (try tiff.readDpi(allocator, scan_path)) orelse fallback_export_dpi;
    const dpi_f: f64 = @floatFromInt(dpi);
    const width_f: f64 = @floatFromInt(image.width);
    const height_f: f64 = @floatFromInt(image.height);
    const frame_w = @min(width_f * 0.90, dpi_f * benchmark_35mm_width_mm / mm_per_inch);
    const frame_h = @min(height_f * 0.45, dpi_f * benchmark_35mm_height_mm / mm_per_inch);
    return .{
        .rect = .{
            .cx = width_f / 2.0,
            .cy = height_f / 2.0,
            .w = frame_w,
            .h = frame_h,
            .angle = 0.0,
            .rotation = 0,
        },
        .dpi = dpi,
    };
}

const ExportComparison = struct {
    diff: DiffSummary,
    metadata_equal: bool,
    file_name_equal: bool,
};

fn compareFirstExport(
    allocator: std.mem.Allocator,
    cpu_dir: []const u8,
    cpu_result: workflow.ExportWorkflowResult,
    gpu_dir: []const u8,
    gpu_result: workflow.ExportWorkflowResult,
) !ExportComparison {
    if (cpu_result.files.len == 0 or gpu_result.files.len == 0) return error.MissingExportOutput;
    if (cpu_result.files.len != gpu_result.files.len) return error.ExportFileCountMismatch;
    const cpu_path = try std.fs.path.join(allocator, &.{ cpu_dir, cpu_result.files[0] });
    defer allocator.free(cpu_path);
    const gpu_path = try std.fs.path.join(allocator, &.{ gpu_dir, gpu_result.files[0] });
    defer allocator.free(gpu_path);

    const cpu_image = try tiff.loadRgbPage(allocator, cpu_path);
    defer cpu_image.deinit(allocator);
    const gpu_image = try tiff.loadRgbPage(allocator, gpu_path);
    defer gpu_image.deinit(allocator);
    const diff = try compareTiffImages(cpu_image, gpu_image);

    const cpu_metadata = try tiff.readExportMetadataJson(allocator, cpu_path);
    defer if (cpu_metadata) |metadata| allocator.free(metadata);
    const gpu_metadata = try tiff.readExportMetadataJson(allocator, gpu_path);
    defer if (gpu_metadata) |metadata| allocator.free(metadata);

    return .{
        .diff = diff,
        .metadata_equal = optionalBytesEqual(cpu_metadata, gpu_metadata),
        .file_name_equal = std.mem.eql(u8, cpu_result.files[0], gpu_result.files[0]),
    };
}

const DiffSummary = struct {
    count: usize,
    max_abs: u64,
    rms: f64,
    mse: f64,
    mismatches: usize,
};

const F64DiffSummary = struct {
    count: usize,
    max_abs: f64,
    rms: f64,
    mse: f64,
    mismatches: usize,
};

fn compareF64(a: []const f64, b: []const f64, mismatch_epsilon: f64) !F64DiffSummary {
    if (a.len != b.len) return error.OutputLengthMismatch;
    var max_abs: f64 = 0.0;
    var sum_sq: f64 = 0.0;
    var mismatches: usize = 0;
    for (a, b) |left, right| {
        const diff = @abs(left - right);
        if (diff > mismatch_epsilon) mismatches += 1;
        max_abs = @max(max_abs, diff);
        sum_sq += diff * diff;
    }
    const mse = if (a.len == 0) 0.0 else sum_sq / @as(f64, @floatFromInt(a.len));
    return .{
        .count = a.len,
        .max_abs = max_abs,
        .rms = @sqrt(mse),
        .mse = mse,
        .mismatches = mismatches,
    };
}

fn compareU8(a: []const u8, b: []const u8) !DiffSummary {
    if (a.len != b.len) return error.OutputLengthMismatch;
    var max_abs: u64 = 0;
    var sum_sq: f64 = 0.0;
    var mismatches: usize = 0;
    for (a, b) |left, right| {
        const diff = if (left >= right)
            @as(u64, left) - @as(u64, right)
        else
            @as(u64, right) - @as(u64, left);
        if (diff != 0) mismatches += 1;
        max_abs = @max(max_abs, diff);
        const diff_f: f64 = @floatFromInt(diff);
        sum_sq += diff_f * diff_f;
    }
    const mse = if (a.len == 0) 0.0 else sum_sq / @as(f64, @floatFromInt(a.len));
    return .{
        .count = a.len,
        .max_abs = max_abs,
        .rms = @sqrt(mse),
        .mse = mse,
        .mismatches = mismatches,
    };
}

fn compareU16(a: []const u16, b: []const u16) !DiffSummary {
    if (a.len != b.len) return error.OutputLengthMismatch;
    var max_abs: u64 = 0;
    var sum_sq: f64 = 0.0;
    var mismatches: usize = 0;
    for (a, b) |left, right| {
        const diff = if (left >= right)
            @as(u64, left) - @as(u64, right)
        else
            @as(u64, right) - @as(u64, left);
        if (diff != 0) mismatches += 1;
        max_abs = @max(max_abs, diff);
        const diff_f: f64 = @floatFromInt(diff);
        sum_sq += diff_f * diff_f;
    }
    const mse = if (a.len == 0) 0.0 else sum_sq / @as(f64, @floatFromInt(a.len));
    return .{
        .count = a.len,
        .max_abs = max_abs,
        .rms = @sqrt(mse),
        .mse = mse,
        .mismatches = mismatches,
    };
}

fn compareTiffImages(a: tiff.Image, b: tiff.Image) !DiffSummary {
    if (a.width != b.width or a.height != b.height or
        a.samples_per_pixel != b.samples_per_pixel or
        a.bits_per_sample != b.bits_per_sample)
    {
        return error.OutputShapeMismatch;
    }
    return switch (a.bits_per_sample) {
        8 => compareU8(a.data, b.data),
        16 => compareU16Le(a.data, b.data),
        else => error.UnsupportedBenchmarkTiff,
    };
}

fn compareU16Le(a: []const u8, b: []const u8) !DiffSummary {
    if (a.len != b.len) return error.OutputLengthMismatch;
    if (a.len % 2 != 0) return error.OutputShapeMismatch;
    var max_abs: u64 = 0;
    var sum_sq: f64 = 0.0;
    var mismatches: usize = 0;
    const count = a.len / 2;
    for (0..count) |index| {
        const left = std.mem.readInt(u16, a[index * 2 ..][0..2], .little);
        const right = std.mem.readInt(u16, b[index * 2 ..][0..2], .little);
        const diff = if (left >= right)
            @as(u64, left) - @as(u64, right)
        else
            @as(u64, right) - @as(u64, left);
        if (diff != 0) mismatches += 1;
        max_abs = @max(max_abs, diff);
        const diff_f: f64 = @floatFromInt(diff);
        sum_sq += diff_f * diff_f;
    }
    const mse = if (count == 0) 0.0 else sum_sq / @as(f64, @floatFromInt(count));
    return .{
        .count = count,
        .max_abs = max_abs,
        .rms = @sqrt(mse),
        .mse = mse,
        .mismatches = mismatches,
    };
}

fn optionalBytesEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn speedupX1000(cpu_ns: u64, gpu_ns: u64) u64 {
    if (gpu_ns == 0) return 0;
    return @intCast((@as(u128, cpu_ns) * 1000) / @as(u128, gpu_ns));
}

fn pctX1000(part_us: u64, total_us: u64) u64 {
    if (total_us == 0) return 0;
    return @intCast((@as(u128, part_us) * 100_000) / @as(u128, total_us));
}

fn renderPercentileScratchBytes(pixel_count: usize, sample_limit: usize) usize {
    const sample_count = render.percentileScratchSampleCount(pixel_count, sample_limit);
    const sample_size: usize = if (sample_count == pixel_count) @sizeOf(f64) else @sizeOf(f32);
    return sample_count * sample_size;
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

fn checksumF64(values: []const f64) i64 {
    var sum: f64 = 0.0;
    for (values) |value| sum += value;
    return @intFromFloat(@round(sum * 1_000_000.0));
}

fn widenF32ToF64(input: []const f32, output: []f64) void {
    std.debug.assert(input.len == output.len);
    for (input, output) |sample, *out| {
        out.* = @floatCast(sample);
    }
}

fn checksumFrames(values: []const frames.FrameRect) i64 {
    var sum: f64 = 0.0;
    for (values) |frame| {
        sum += frame.cx + frame.cy + frame.w + frame.h + frame.angle * 1000.0;
    }
    return @intFromFloat(@round(sum * 1000.0));
}

fn checksumStrings(values: []const []const u8) u64 {
    var sum: u64 = 0;
    for (values) |value| {
        for (value) |byte| sum +%= byte;
    }
    return sum;
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
