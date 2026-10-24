const std = @import("std");
const cerealgrain = @import("cerealgrain");
const monotonicNowNs = @import("cerealgrain").clock.monotonicNowNs;

const export_pipeline = cerealgrain.processing.export_pipeline;
const film_stocks = cerealgrain.processing.film_stocks;
const frames = cerealgrain.processing.frames;
const inversion = cerealgrain.processing.inversion;
const ir_processing = cerealgrain.processing.ir;
const measurement = cerealgrain.processing.measurement;
const process_cache = cerealgrain.native_ui_process_cache;
const processing_config = cerealgrain.processing.config;
const render = cerealgrain.processing.render;
const tiff = cerealgrain.tiff;
const webgpu = cerealgrain.processing.webgpu;
const workflow = cerealgrain.processing.workflow;

const default_scan = "scans/scan_0006_rgbir_800dpi.tiff";
const default_output_dir = "/tmp/cerealgrain-processing-bench";
const default_config_path = "/tmp/cerealgrain-processing-bench-config.toml";
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
    /// Film format and frame count for the auto-detect, rebate, and
    /// detected-frame export cases (0 frames: detection decides).
    format: []const u8 = "35mm",
    frames: u32 = 5,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const options = try parseArgs(allocator, init);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
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

    if (shouldRun(options.case_filter, "process_rgb_page_cache_sequence")) {
        try benchProcessRgbPageCacheSequence(allocator, init.io, stdout, options.scan_path);
    }

    var preview: ?workflow.QuickPreview = null;
    if (shouldRun(options.case_filter, "load_preview") or
        shouldRun(options.case_filter, "load_preview_breakdown") or
        shouldRun(options.case_filter, "inverted_preview") or
        shouldRun(options.case_filter, "process_result_cache_repeat") or
        shouldRun(options.case_filter, "inverted_preview_cpu_vs_gpu") or
        shouldRun(options.case_filter, "invert_negative_preview_breakdown") or
        shouldRun(options.case_filter, "export_detected_frames") or
        shouldRun(options.case_filter, "export_detected_frames_breakdown") or
        shouldRun(options.case_filter, "export_detected_frames_ir_all_breakdown") or
        shouldRun(options.case_filter, "export_detected_frames_ir_gaussian_approx_tradeoff") or
        shouldRun(options.case_filter, "auto_detect") or
        shouldRun(options.case_filter, "auto_detect_breakdown") or
        shouldRun(options.case_filter, "rebate"))
    {
        const started = monotonicNowNs();
        preview = try workflow.loadQuickPreview(allocator, options.scan_path, 8192);
        const elapsed = monotonicNowNs() - started;
        const loaded = preview.?;
        if (shouldRun(options.case_filter, "load_preview")) {
            try stdout.print("load_preview,{s},{d},{d},{d},{d},{d}\n", .{
                options.scan_path,
                loaded.preview_width,
                loaded.preview_height,
                loaded.preview_width * loaded.preview_height,
                elapsed / std.time.ns_per_us,
                checksumU8(loaded.preview_rgb8),
            });
        }
        if (shouldRun(options.case_filter, "load_preview_breakdown")) {
            try benchLoadPreviewBreakdown(allocator, stdout, options.scan_path, loaded, elapsed);
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

        if (shouldRun(options.case_filter, "process_result_cache_repeat")) {
            try benchProcessResultCacheRepeat(allocator, init.io, stdout, options.scan_path, loaded);
        }

        if (shouldRun(options.case_filter, "invert_negative_preview_breakdown")) {
            try benchPreviewInvertBreakdown(allocator, stdout, options.scan_path, loaded);
        }

        if (shouldRun(options.case_filter, "auto_detect") or shouldRun(options.case_filter, "rebate")) {
            const started = monotonicNowNs();
            auto_result = try workflow.autoDetectPreview(allocator, loaded, .{
                .format = options.format,
                .n_frames = if (options.frames == 0) null else @as(usize, options.frames),
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

        if (shouldRun(options.case_filter, "auto_detect_breakdown")) {
            try benchAutoDetectBreakdown(allocator, stdout, options.scan_path, loaded);
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

        if (shouldRun(options.case_filter, "export_detected_frames") or
            shouldRun(options.case_filter, "export_detected_frames_breakdown") or
            shouldRun(options.case_filter, "export_detected_frames_ir_all_breakdown") or
            shouldRun(options.case_filter, "export_detected_frames_ir_gaussian_approx_tradeoff"))
        {
            const result = if (auto_result) |existing|
                existing
            else blk: {
                auto_result = try workflow.autoDetectPreview(allocator, loaded, .{
                    .format = options.format,
                    .n_frames = if (options.frames == 0) null else @as(usize, options.frames),
                });
                break :blk auto_result.?;
            };
            if (shouldRun(options.case_filter, "export_detected_frames")) {
                try benchDetectedFrameExport(allocator, init.io, stdout, options.scan_path, loaded, result);
            }
            if (shouldRun(options.case_filter, "export_detected_frames_breakdown")) {
                try benchDetectedFrameExportBreakdown(allocator, init.io, stdout, options.scan_path, loaded, result);
            }
            if (shouldRun(options.case_filter, "export_detected_frames_ir_all_breakdown")) {
                try benchDetectedFrameExportIrAllBreakdown(allocator, init.io, stdout, options.scan_path, loaded, result);
            }
            if (shouldRun(options.case_filter, "export_detected_frames_ir_gaussian_approx_tradeoff")) {
                try benchDetectedFrameExportIrGaussianApproxTradeoff(allocator, init.io, stdout, options.scan_path, loaded, result);
            }
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
        } else if (std.mem.eql(u8, arg, "--format")) {
            options.format = args.next() orelse return error.MissingFilmFormat;
        } else if (std.mem.eql(u8, arg, "--frames")) {
            const value = args.next() orelse return error.MissingFrameCount;
            options.frames = try std.fmt.parseInt(u32, value, 10);
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
        .contrast = 1.8,
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

fn benchLoadPreviewBreakdown(
    allocator: std.mem.Allocator,
    stdout: anytype,
    path: []const u8,
    reference: workflow.QuickPreview,
    reference_elapsed_ns: u64,
) !void {
    var breakdown = try workflow.loadQuickPreviewBreakdown(allocator, path, 8192);
    defer breakdown.deinit(allocator);
    const measured = breakdown.preview;
    if (reference.preview_width != measured.preview_width or reference.preview_height != measured.preview_height or
        reference.info.width != measured.info.width or reference.info.height != measured.info.height or
        reference.info.has_ir != measured.info.has_ir or reference.info.is_grayscale != measured.info.is_grayscale or
        reference.info.dpi != measured.info.dpi or reference.info.rgb_samples_per_pixel != measured.info.rgb_samples_per_pixel or
        reference.info.rgb_bits_per_sample != measured.info.rgb_bits_per_sample or
        reference.info.ir_samples_per_pixel != measured.info.ir_samples_per_pixel or
        reference.info.ir_bits_per_sample != measured.info.ir_bits_per_sample)
    {
        return error.LoadPreviewBreakdownMetadataMismatch;
    }
    if (@abs(reference.info.preview_scale - measured.info.preview_scale) > 0.0) return error.LoadPreviewBreakdownMetadataMismatch;

    const raw_diff = try compareU16(reference.preview_raw, measured.preview_raw);
    const rgb_diff = try compareU8(reference.preview_rgb8, measured.preview_rgb8);
    const jpeg_diff = try compareU8(reference.jpeg, measured.jpeg);
    if (raw_diff.mismatches != 0 or rgb_diff.mismatches != 0 or jpeg_diff.mismatches != 0) {
        return error.LoadPreviewBreakdownMismatch;
    }

    const quick = breakdown.quick_preview;
    const total_stage_ns = breakdown.tiff_open_ifd_ns +
        breakdown.rgb_read_ns +
        breakdown.ir_info_ns +
        quick.total_ns;
    const dpi_value = measured.info.dpi orelse 0;
    try stdout.print(
        "load_preview_breakdown,{s},{d},{d},{d},{d},reference_us={d};total_us={d};stage_sum_us={d};tiff_open_ifd_us={d};rgb_read_us={d};ir_info_us={d};quick_preview_us={d}",
        .{
            path,
            measured.preview_width,
            measured.preview_height,
            measured.preview_width * measured.preview_height,
            breakdown.total_ns / std.time.ns_per_us,
            reference_elapsed_ns / std.time.ns_per_us,
            breakdown.total_ns / std.time.ns_per_us,
            total_stage_ns / std.time.ns_per_us,
            breakdown.tiff_open_ifd_ns / std.time.ns_per_us,
            breakdown.rgb_read_ns / std.time.ns_per_us,
            breakdown.ir_info_ns / std.time.ns_per_us,
            quick.total_ns / std.time.ns_per_us,
        },
    );
    try stdout.print(
        ";geometry_us={d};resize_us={d};convert_us={d};content_mask_us={d};invert_stretch_us={d};clahe_us={d};raw_copy_us={d};rgb_copy_us={d};jpeg_encode_us={d};jpeg_copy_us={d}",
        .{
            quick.geometry_ns / std.time.ns_per_us,
            quick.resize_ns / std.time.ns_per_us,
            quick.convert_ns / std.time.ns_per_us,
            quick.content_mask_ns / std.time.ns_per_us,
            quick.invert_stretch_ns / std.time.ns_per_us,
            quick.clahe_ns / std.time.ns_per_us,
            quick.raw_copy_ns / std.time.ns_per_us,
            quick.rgb_copy_ns / std.time.ns_per_us,
            quick.jpeg_encode_ns / std.time.ns_per_us,
            quick.jpeg_copy_ns / std.time.ns_per_us,
        },
    );
    try stdout.print(
        ";has_ir={};dpi_present={};dpi={d};preview_scale={d:.9};raw_checksum={d};rgb_checksum={d};jpeg_checksum={d};raw_max_abs={d};rgb_max_abs={d};jpeg_max_abs={d};mismatches={d}\n",
        .{
            measured.info.has_ir,
            measured.info.dpi != null,
            dpi_value,
            measured.info.preview_scale,
            checksumU16(measured.preview_raw),
            checksumU8(measured.preview_rgb8),
            checksumU8(measured.jpeg),
            raw_diff.max_abs,
            rgb_diff.max_abs,
            jpeg_diff.max_abs,
            raw_diff.mismatches + rgb_diff.mismatches + jpeg_diff.mismatches,
        },
    );
}

fn benchProcessRgbPageCacheSequence(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: anytype,
    scan_path: []const u8,
) !void {
    const baseline_started = monotonicNowNs();
    const baseline_preview_started = monotonicNowNs();
    const baseline_preview = try workflow.loadQuickPreview(allocator, scan_path, 8192);
    defer baseline_preview.deinit(allocator);
    const baseline_preview_ns = monotonicNowNs() - baseline_preview_started;

    const baseline_detect_started = monotonicNowNs();
    var baseline_detected = try workflow.autoDetectPreview(allocator, baseline_preview, .{
        .format = "35mm",
        .n_frames = 5,
    });
    defer baseline_detected.deinit(allocator);
    const baseline_detect_ns = monotonicNowNs() - baseline_detect_started;
    const rebate = baseline_detected.rebate orelse return error.MissingBenchmarkRebate;
    const full_rebate = try frames.previewRebateToFullResolution(.{
        .x = rebate.cx - rebate.w / 2.0,
        .y = rebate.cy - rebate.h / 2.0,
        .w = rebate.w,
        .h = rebate.h,
        .angle = rebate.angle,
    }, baseline_preview.info.preview_scale);

    const baseline_rebate_started = monotonicNowNs();
    const baseline_dmin = try workflow.computeRebateDminFromTiff(allocator, scan_path, full_rebate);
    const baseline_rebate_ns = monotonicNowNs() - baseline_rebate_started;

    const rects = try fullResolutionExportRects(allocator, baseline_detected.frames, baseline_preview.info.preview_scale);
    defer allocator.free(rects);
    const current_dpi = baseline_preview.info.dpi orelse fallback_export_dpi;
    const outputs = export_pipeline.OutputSelection{ .ir_neg = false, .ir_inv = false, .inv_only = true };
    const basename = try std.fmt.allocPrint(allocator, "zig_bench_rgb_cache_{d}", .{monotonicNowNs()});
    defer allocator.free(basename);
    var baseline_export_timings = workflow.ExportWorkflowTimings{};
    var baseline_export = try runExportCaptureWithRectsDmin(allocator, io, scan_path, outputs, false, .{}, basename, rects, current_dpi, true, baseline_dmin, true, &baseline_export_timings);
    defer baseline_export.deinit(allocator, io);
    const baseline_total_ns = monotonicNowNs() - baseline_started;

    var cache_tiff_timings = tiff.RgbPageMetadataTimings{};
    const cached_started = monotonicNowNs();
    const cache_load_started = monotonicNowNs();
    const loaded = try tiff.loadRgbPageWithMetadataTimed(allocator, scan_path, &cache_tiff_timings);
    defer loaded.deinit(allocator);
    const cache_load_ns = monotonicNowNs() - cache_load_started;

    const cached_preview_started = monotonicNowNs();
    const cached_preview = try workflow.quickPreviewFromLoadedRgbPage(allocator, loaded, 8192);
    defer cached_preview.deinit(allocator);
    const cached_preview_ns = monotonicNowNs() - cached_preview_started;

    const cached_detect_started = monotonicNowNs();
    var cached_detected = try workflow.autoDetectPreview(allocator, cached_preview, .{
        .format = "35mm",
        .n_frames = 5,
    });
    defer cached_detected.deinit(allocator);
    const cached_detect_ns = monotonicNowNs() - cached_detect_started;

    const cached_rebate_started = monotonicNowNs();
    const cached_dmin = try workflow.computeRebateDminFromTiffImage(allocator, loaded.rgb, full_rebate);
    const cached_rebate_ns = monotonicNowNs() - cached_rebate_started;

    var cached_export_timings = workflow.ExportWorkflowTimings{};
    var cached_export = try runExportCaptureWithCachedRgbPage(allocator, io, loaded, scan_path, outputs, basename, rects, current_dpi, true, cached_dmin, &cached_export_timings);
    defer cached_export.deinit(allocator, io);
    const cached_total_ns = monotonicNowNs() - cached_started;

    const preview_raw_diff = try compareU16(baseline_preview.preview_raw, cached_preview.preview_raw);
    const preview_rgb_diff = try compareU8(baseline_preview.preview_rgb8, cached_preview.preview_rgb8);
    const preview_jpeg_diff = try compareU8(baseline_preview.jpeg, cached_preview.jpeg);
    if (preview_raw_diff.mismatches != 0 or preview_rgb_diff.mismatches != 0 or preview_jpeg_diff.mismatches != 0) return error.CachedRgbPreviewMismatch;
    const dmin_max_abs = maxDminAbsDiff(baseline_dmin, cached_dmin);
    if (dmin_max_abs != 0.0) return error.CachedRgbDminMismatch;
    const comparison = try compareExportResults(allocator, baseline_export.output_dir, baseline_export.result, cached_export.output_dir, cached_export.result);
    if (!comparison.file_set_equal) return error.ExportFileSetMismatch;
    if (!comparison.metadata_equal) return error.ExportMetadataMismatch;
    if (comparison.diff.max_abs > 1) return error.ExportPixelMismatch;

    const baseline_readish_ns = baseline_preview_ns + baseline_rebate_ns + baseline_export_timings.load_full_image_ns;
    const avoided_read_ns = if (baseline_readish_ns > cache_load_ns) baseline_readish_ns - cache_load_ns else 0;
    try stdout.print(
        "process_rgb_page_cache_sequence,{s},{d},{d},{d},{d},baseline_us={d};cached_us={d};speedup_x1000={d};cached_rgb_bytes={d};cached_load_us={d};cached_rgb_read_us={d};baseline_readish_us={d};avoided_read_us={d};baseline_preview_us={d};cached_preview_us={d};baseline_rebate_us={d};cached_rebate_us={d};baseline_export_us={d};cached_export_us={d};baseline_export_load_us={d};cached_export_load_us={d};baseline_detect_us={d};cached_detect_us={d};preview_mismatches={d};dmin_max_abs={d:.12};export_max_abs={d};export_mismatches={d};metadata_equal={};file_set_equal={};checksum_baseline={d};checksum_cached={d}\n",
        .{
            scan_path,
            baseline_preview.preview_width,
            baseline_preview.preview_height,
            baseline_preview.preview_width * baseline_preview.preview_height,
            cached_total_ns / std.time.ns_per_us,
            baseline_total_ns / std.time.ns_per_us,
            cached_total_ns / std.time.ns_per_us,
            speedupX1000(baseline_total_ns, cached_total_ns),
            loaded.rgb.data.len,
            cache_load_ns / std.time.ns_per_us,
            cache_tiff_timings.rgb_read_ns / std.time.ns_per_us,
            baseline_readish_ns / std.time.ns_per_us,
            avoided_read_ns / std.time.ns_per_us,
            baseline_preview_ns / std.time.ns_per_us,
            cached_preview_ns / std.time.ns_per_us,
            baseline_rebate_ns / std.time.ns_per_us,
            cached_rebate_ns / std.time.ns_per_us,
            baseline_export.elapsed_ns / std.time.ns_per_us,
            cached_export.elapsed_ns / std.time.ns_per_us,
            baseline_export_timings.load_full_image_ns / std.time.ns_per_us,
            cached_export_timings.load_full_image_ns / std.time.ns_per_us,
            baseline_detect_ns / std.time.ns_per_us,
            cached_detect_ns / std.time.ns_per_us,
            preview_raw_diff.mismatches + preview_rgb_diff.mismatches + preview_jpeg_diff.mismatches,
            dmin_max_abs,
            comparison.diff.max_abs,
            comparison.diff.mismatches,
            comparison.metadata_equal,
            comparison.file_set_equal,
            checksumStrings(baseline_export.result.files),
            checksumStrings(cached_export.result.files),
        },
    );
}

fn benchProcessResultCacheRepeat(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: anytype,
    scan_path: []const u8,
    preview: workflow.QuickPreview,
) !void {
    var loaded_config = processing_config.LoadedConfig{};
    try loaded_config.set("stock", .{ .string = processing_config.FixedString.init(benchmark_stock) });
    try loaded_config.set("dmin", .{ .list = try processing_config.FloatList.init(&benchmark_dmin) });
    var result_cache = process_cache.ProcessResultCache{};
    defer result_cache.deinit(allocator);

    const auto_options = workflow.AutoDetectOptions{ .format = "35mm", .n_frames = 5 };
    const auto_started = monotonicNowNs();
    var auto_result = try workflow.autoDetectPreview(allocator, preview, auto_options);
    defer auto_result.deinit(allocator);
    const auto_ns = monotonicNowNs() - auto_started;

    var auto_key = try process_cache.autoDetectKey(allocator, io, scan_path, &loaded_config, .{
        .options = auto_options,
        .scale_percent = 0.0,
        .output_rotation = 270,
        .preview_width = preview.preview_width,
        .preview_height = preview.preview_height,
        .preview_scale = preview.info.preview_scale,
    });
    defer auto_key.deinit(allocator);
    try result_cache.auto_detects.putClone(allocator, auto_key, .{ .result = auto_result });
    const auto_hit_started = monotonicNowNs();
    var auto_hit = (try result_cache.auto_detects.getClone(allocator, auto_key)).?;
    const auto_hit_ns = monotonicNowNs() - auto_hit_started;
    defer auto_hit.deinit(allocator);
    const auto_comparison = compareAutoDetectResults(auto_result, auto_hit.result);
    if (auto_comparison.mismatches != 0) return error.ProcessAutoDetectCacheMismatch;

    const rebate = auto_result.rebate orelse return error.MissingBenchmarkRebate;
    const full_rebate = try frames.previewRebateToFullResolution(.{
        .x = rebate.cx - rebate.w / 2.0,
        .y = rebate.cy - rebate.h / 2.0,
        .w = rebate.w,
        .h = rebate.h,
        .angle = rebate.angle,
    }, preview.info.preview_scale);
    const dmin_rect: cerealgrain.app_state.RebateRect = .{
        .x = full_rebate.x,
        .y = full_rebate.y,
        .w = full_rebate.w,
        .h = full_rebate.h,
        .angle = full_rebate.angle,
    };
    const dmin_started = monotonicNowNs();
    const dmin = try workflow.computeRebateDminFromTiff(allocator, scan_path, full_rebate);
    const dmin_ns = monotonicNowNs() - dmin_started;
    var dmin_key = try process_cache.rebateDminKey(allocator, io, scan_path, &loaded_config, dmin_rect);
    defer dmin_key.deinit(allocator);
    try result_cache.dmins.put(allocator, dmin_key, dmin);
    const dmin_hit_started = monotonicNowNs();
    const dmin_hit = result_cache.dmins.get(dmin_key) orelse return error.ProcessDminCacheMiss;
    const dmin_hit_ns = monotonicNowNs() - dmin_hit_started;
    const dmin_max_abs = maxDminAbsDiff(dmin, dmin_hit);
    if (dmin_max_abs != 0.0) return error.ProcessDminCacheMismatch;

    var inversion_cache = workflow.InvertedPreviewCache{};
    defer inversion_cache.deinit(allocator);
    const inverted_started = monotonicNowNs();
    const inverted = (try workflow.renderInvertedPreviewRgb8(allocator, preview, &inversion_cache, .{
        .stock = benchmark_stock,
        .dmin = dmin,
    })) orelse return error.InvertedPreviewUnavailable;
    defer allocator.free(inverted);
    const inverted_ns = monotonicNowNs() - inverted_started;
    var inverted_key = try process_cache.invertedPreviewKey(allocator, io, scan_path, &loaded_config, .{
        .stock = benchmark_stock,
        .dmin = dmin,
        .render_options = .{},
        .invert_request = .{},
        .preview_width = preview.preview_width,
        .preview_height = preview.preview_height,
        .preview_scale = preview.info.preview_scale,
    });
    defer inverted_key.deinit(allocator);
    try result_cache.inverted_previews.putClone(allocator, inverted_key, inverted);
    const inverted_hit_started = monotonicNowNs();
    const inverted_hit = (try result_cache.inverted_previews.getClone(allocator, inverted_key)).?;
    const inverted_hit_ns = monotonicNowNs() - inverted_hit_started;
    defer allocator.free(inverted_hit);
    const inverted_diff = try compareU8(inverted, inverted_hit);
    if (inverted_diff.mismatches != 0) return error.ProcessInvertedPreviewCacheMismatch;

    const baseline_ns = auto_ns + dmin_ns + inverted_ns;
    const cached_ns = auto_hit_ns + dmin_hit_ns + inverted_hit_ns;
    try stdout.print(
        "process_result_cache_repeat,{s},{d},{d},{d},{d},baseline_us={d};cached_us={d};speedup_x1000={d};auto_us={d};auto_hit_us={d};auto_speedup_x1000={d};dmin_us={d};dmin_hit_us={d};dmin_speedup_x1000={d};inverted_us={d};inverted_hit_us={d};inverted_speedup_x1000={d};auto_mismatches={d};auto_frame_max_abs={d:.9};auto_rebate_max_abs={d:.9};dmin_max_abs={d:.12};inverted_max_abs={d};inverted_mismatches={d};checksum_inverted={d};checksum_cached={d}\n",
        .{
            scan_path,
            preview.preview_width,
            preview.preview_height,
            preview.preview_width * preview.preview_height,
            cached_ns / std.time.ns_per_us,
            baseline_ns / std.time.ns_per_us,
            cached_ns / std.time.ns_per_us,
            speedupX1000(baseline_ns, cached_ns),
            auto_ns / std.time.ns_per_us,
            auto_hit_ns / std.time.ns_per_us,
            speedupX1000(auto_ns, auto_hit_ns),
            dmin_ns / std.time.ns_per_us,
            dmin_hit_ns / std.time.ns_per_us,
            speedupX1000(dmin_ns, dmin_hit_ns),
            inverted_ns / std.time.ns_per_us,
            inverted_hit_ns / std.time.ns_per_us,
            speedupX1000(inverted_ns, inverted_hit_ns),
            auto_comparison.mismatches,
            auto_comparison.frame_max_abs,
            auto_comparison.rebate_max_abs,
            dmin_max_abs,
            inverted_diff.max_abs,
            inverted_diff.mismatches,
            checksumU8(inverted),
            checksumU8(inverted_hit),
        },
    );
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

const AutoDetectComparison = struct {
    frame_max_abs: f64 = 0.0,
    rebate_max_abs: f64 = 0.0,
    mismatches: usize = 0,
};

fn benchAutoDetectBreakdown(
    allocator: std.mem.Allocator,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
) !void {
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, loaded.preview_width, loaded.preview_height), 3);
    if (loaded.preview_raw.len != sample_count) return error.InvalidPreviewBuffer;
    const format = frames.formatByName("35mm") orelse return error.InvalidFilmFormat;

    const reference_started = monotonicNowNs();
    var reference = try workflow.autoDetectPreview(allocator, loaded, .{
        .format = "35mm",
        .n_frames = 5,
    });
    const reference_elapsed = monotonicNowNs() - reference_started;
    defer reference.deinit(allocator);

    const detect_started = monotonicNowNs();
    var breakdown = try frames.detectFramesFromImageBreakdown(
        allocator,
        std.mem.sliceAsBytes(loaded.preview_raw),
        loaded.preview_width,
        loaded.preview_height,
        3,
        16,
        format,
        .{
            .frame_count_override = 5,
            .detect_film_extent = true,
            .apply_clahe = true,
            .px_per_mm = if (loaded.info.dpi) |dpi| @as(f64, @floatFromInt(dpi)) / 25.4 * loaded.info.preview_scale else null,
        },
    );
    var breakdown_owns_result = true;
    errdefer {
        if (breakdown_owns_result) breakdown.deinit(allocator);
    }
    const detect_elapsed = monotonicNowNs() - detect_started;

    const postprocess_started = monotonicNowNs();
    var measured = try workflow.autoDetectDetectedFrames(&breakdown.result, loaded.preview_width, loaded.preview_height);
    breakdown_owns_result = false;
    const postprocess_elapsed = monotonicNowNs() - postprocess_started;
    defer measured.deinit(allocator);

    const comparison = compareAutoDetectResults(reference, measured);
    try stdout.print(
        "auto_detect_breakdown,{s},{d},{d},{d},{d},reference_us={d};detect_us={d};prepare_gray_us={d};film_extent_us={d};film_otsu_us={d};film_mask_us={d};film_close_us={d};film_component_us={d};film_geometry_us={d}",
        .{
            scan_path,
            loaded.preview_width,
            loaded.preview_height,
            loaded.preview_width * loaded.preview_height,
            (detect_elapsed + postprocess_elapsed) / std.time.ns_per_us,
            reference_elapsed / std.time.ns_per_us,
            detect_elapsed / std.time.ns_per_us,
            breakdown.prepare_gray_ns / std.time.ns_per_us,
            breakdown.film_extent_ns / std.time.ns_per_us,
            breakdown.film_otsu_ns / std.time.ns_per_us,
            breakdown.film_mask_ns / std.time.ns_per_us,
            breakdown.film_close_ns / std.time.ns_per_us,
            breakdown.film_component_ns / std.time.ns_per_us,
            breakdown.film_geometry_ns / std.time.ns_per_us,
        },
    );
    try stdout.print(
        ";rotate_us={d};clahe_us={d};axis_total_us={d};analyze_us={d};gradients_us={d};fit_us={d};frames_from_edges_us={d};angle_us={d};cross_strip_us={d};transform_back_us={d};postprocess_us={d};rotated={};frames={d};aspect={s};checksum={d};reference_checksum={d};frame_max_abs={d:.9};rebate_max_abs={d:.9};mismatches={d}\n",
        .{
            breakdown.rotate_ns / std.time.ns_per_us,
            breakdown.clahe_ns / std.time.ns_per_us,
            breakdown.axis_total_ns / std.time.ns_per_us,
            breakdown.analyze_ns / std.time.ns_per_us,
            breakdown.gradients_ns / std.time.ns_per_us,
            breakdown.fit_ns / std.time.ns_per_us,
            breakdown.frames_from_edges_ns / std.time.ns_per_us,
            breakdown.angle_ns / std.time.ns_per_us,
            breakdown.cross_strip_ns / std.time.ns_per_us,
            breakdown.transform_back_ns / std.time.ns_per_us,
            postprocess_elapsed / std.time.ns_per_us,
            breakdown.rotated,
            measured.frames.len,
            measured.aspect,
            checksumFrames(measured.frames),
            checksumFrames(reference.frames),
            comparison.frame_max_abs,
            comparison.rebate_max_abs,
            comparison.mismatches,
        },
    );
    if (comparison.mismatches != 0) return error.AutoDetectBreakdownMismatch;
}

fn compareAutoDetectResults(reference: workflow.AutoDetectResult, measured: workflow.AutoDetectResult) AutoDetectComparison {
    var comparison: AutoDetectComparison = .{};
    if (!std.mem.eql(u8, reference.aspect, measured.aspect)) comparison.mismatches += 1;
    if (reference.frames.len != measured.frames.len) {
        comparison.mismatches += 1;
    }
    const frame_count = @min(reference.frames.len, measured.frames.len);
    for (reference.frames[0..frame_count], measured.frames[0..frame_count]) |a, b| {
        compareAutoDetectScalar(a.cx, b.cx, &comparison.frame_max_abs, &comparison.mismatches);
        compareAutoDetectScalar(a.cy, b.cy, &comparison.frame_max_abs, &comparison.mismatches);
        compareAutoDetectScalar(a.w, b.w, &comparison.frame_max_abs, &comparison.mismatches);
        compareAutoDetectScalar(a.h, b.h, &comparison.frame_max_abs, &comparison.mismatches);
        compareAutoDetectScalar(a.angle, b.angle, &comparison.frame_max_abs, &comparison.mismatches);
    }

    if (reference.rebate == null or measured.rebate == null) {
        if (reference.rebate != null or measured.rebate != null) comparison.mismatches += 1;
    } else {
        const a = reference.rebate.?;
        const b = measured.rebate.?;
        compareAutoDetectScalar(a.cx, b.cx, &comparison.rebate_max_abs, &comparison.mismatches);
        compareAutoDetectScalar(a.cy, b.cy, &comparison.rebate_max_abs, &comparison.mismatches);
        compareAutoDetectScalar(a.w, b.w, &comparison.rebate_max_abs, &comparison.mismatches);
        compareAutoDetectScalar(a.h, b.h, &comparison.rebate_max_abs, &comparison.mismatches);
        compareAutoDetectScalar(a.angle, b.angle, &comparison.rebate_max_abs, &comparison.mismatches);
    }
    return comparison;
}

fn compareAutoDetectScalar(reference: f64, measured: f64, max_abs: *f64, mismatches: *usize) void {
    const diff = @abs(reference - measured);
    max_abs.* = @max(max_abs.*, diff);
    if (diff > 1e-9) mismatches.* += 1;
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

const ExportCapture = struct {
    output_dir: []u8,
    result: workflow.ExportWorkflowResult,
    elapsed_ns: u64,
    timings: ?workflow.ExportWorkflowTimings = null,

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

fn benchDetectedFrameExportBreakdown(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
    detected: workflow.AutoDetectResult,
) !void {
    if (detected.frames.len == 0) {
        try stdout.print("export_detected_frames_breakdown,{s},0,0,0,0,skipped_no_frames\n", .{scan_path});
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

    const outputs = export_pipeline.OutputSelection{
        .ir_neg = false,
        .ir_inv = false,
        .inv_only = true,
    };
    const current_dpi = loaded.info.dpi orelse fallback_export_dpi;

    const basename = try std.fmt.allocPrint(allocator, "zig_bench_detected_breakdown_{d}", .{monotonicNowNs()});
    defer allocator.free(basename);
    var reference = try runExportCaptureWithRectsLegacy(allocator, io, scan_path, outputs, false, .{}, basename, rects, current_dpi, true);
    defer reference.deinit(allocator, io);

    var timed = try runExportCaptureWithRectsTimed(allocator, io, scan_path, outputs, false, .{}, basename, rects, current_dpi, true);
    defer timed.deinit(allocator, io);

    const comparison = try compareExportResults(allocator, reference.output_dir, reference.result, timed.output_dir, timed.result);
    if (!comparison.file_set_equal) return error.ExportFileSetMismatch;
    if (!comparison.metadata_equal) return error.ExportMetadataMismatch;
    if (comparison.diff.max_abs > 1) return error.ExportPixelMismatch;

    const parallelism: workflow.ExportParallelismDecision = timed.result.parallelism orelse .{
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
    const timings = timed.timings orelse workflow.ExportWorkflowTimings{};
    const frame = timings.frame_timings;

    try stdout.print(
        "export_detected_frames_breakdown,{s},{d},{d},{d},{d},reference_us={d};timed_us={d};frames={d};files={d};workers={d};cpu_limit={d};mem_limit={d};estimated_worker_peak_bytes={d};adjusted_worker_peak_bytes={d}",
        .{
            scan_path,
            @as(usize, @intFromFloat(rects[0].w)),
            @as(usize, @intFromFloat(rects[0].h)),
            total_pixels,
            timed.elapsed_ns / std.time.ns_per_us,
            reference.elapsed_ns / std.time.ns_per_us,
            timed.elapsed_ns / std.time.ns_per_us,
            rects.len,
            timed.result.files.len,
            parallelism.worker_count,
            parallelism.cpu_worker_limit,
            parallelism.memory_worker_limit orelse 0,
            parallelism.estimated_worker_peak_bytes,
            parallelism.adjusted_worker_peak_bytes,
        },
    );
    try stdout.print(
        ";total_us={d};create_dir_us={d};load_full_us={d};dmin_us={d};ir_align_us={d};path_setup_us={d};plan_parallel_us={d};frame_processing_us={d};worker_setup_us={d};scheduler_wait_us={d};result_merge_us={d};progress_build_us={d};final_message_us={d}",
        .{
            timings.total_ns / std.time.ns_per_us,
            timings.create_output_dir_ns / std.time.ns_per_us,
            timings.load_full_image_ns / std.time.ns_per_us,
            timings.dmin_ns / std.time.ns_per_us,
            timings.ir_align_ns / std.time.ns_per_us,
            timings.path_setup_ns / std.time.ns_per_us,
            timings.plan_parallel_ns / std.time.ns_per_us,
            timings.frame_processing_ns / std.time.ns_per_us,
            timings.worker_setup_ns / std.time.ns_per_us,
            timings.scheduler_wait_ns / std.time.ns_per_us,
            timings.result_merge_ns / std.time.ns_per_us,
            timings.progress_build_ns / std.time.ns_per_us,
            timings.final_message_ns / std.time.ns_per_us,
        },
    );
    try stdout.print(
        ";rgb_crop_us={d};ir_crop_us={d};ir_clean_us={d};ir_neg_prepare_us={d};inversion_us={d};display_render_us={d};output_rotation_us={d};metadata_us={d};write_us={d};max_abs={d};rms={d:.6};mismatches={d};metadata_equal={};file_set_equal={};checksum_reference={d};checksum_timed={d}\n",
        .{
            frame.rgb_crop_ns / std.time.ns_per_us,
            frame.ir_crop_ns / std.time.ns_per_us,
            frame.ir_clean_ns / std.time.ns_per_us,
            frame.ir_neg_prepare_ns / std.time.ns_per_us,
            frame.inversion_ns / std.time.ns_per_us,
            frame.display_render_ns / std.time.ns_per_us,
            frame.output_rotation_ns / std.time.ns_per_us,
            frame.metadata_ns / std.time.ns_per_us,
            frame.write_ns / std.time.ns_per_us,
            comparison.diff.max_abs,
            comparison.diff.rms,
            comparison.diff.mismatches,
            comparison.metadata_equal,
            comparison.file_set_equal,
            checksumStrings(reference.result.files),
            checksumStrings(timed.result.files),
        },
    );
}

fn benchDetectedFrameExportIrAllBreakdown(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
    detected: workflow.AutoDetectResult,
) !void {
    if (detected.frames.len == 0) {
        try stdout.print("export_detected_frames_ir_all_breakdown,{s},0,0,0,0,skipped_no_frames\n", .{scan_path});
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

    const outputs = export_pipeline.OutputSelection{
        .ir_neg = true,
        .ir_inv = true,
        .inv_only = true,
    };
    const current_dpi = loaded.info.dpi orelse fallback_export_dpi;

    const basename = try std.fmt.allocPrint(allocator, "zig_bench_detected_ir_all_breakdown_{d}", .{monotonicNowNs()});
    defer allocator.free(basename);
    var timed = try runExportCaptureWithRectsTimed(allocator, io, scan_path, outputs, true, .{}, basename, rects, current_dpi, true);
    defer timed.deinit(allocator, io);

    const parallelism: workflow.ExportParallelismDecision = timed.result.parallelism orelse .{
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
    const timings = timed.timings orelse workflow.ExportWorkflowTimings{};
    const frame = timings.frame_timings;

    try stdout.print(
        "export_detected_frames_ir_all_breakdown,{s},{d},{d},{d},{d},frames={d};files={d};workers={d};cpu_limit={d};mem_limit={d};estimated_worker_peak_bytes={d};adjusted_worker_peak_bytes={d};ir_inner_workers={d}",
        .{
            scan_path,
            @as(usize, @intFromFloat(rects[0].w)),
            @as(usize, @intFromFloat(rects[0].h)),
            total_pixels,
            timed.elapsed_ns / std.time.ns_per_us,
            rects.len,
            timed.result.files.len,
            parallelism.worker_count,
            parallelism.cpu_worker_limit,
            parallelism.memory_worker_limit orelse 0,
            parallelism.estimated_worker_peak_bytes,
            parallelism.adjusted_worker_peak_bytes,
            timed.result.ir_adaptive_worker_count,
        },
    );
    try stdout.print(
        ";total_us={d};create_dir_us={d};load_full_us={d};dmin_us={d};ir_align_us={d};path_setup_us={d};plan_parallel_us={d};frame_processing_us={d};worker_setup_us={d};scheduler_wait_us={d};result_merge_us={d};progress_build_us={d};final_message_us={d}",
        .{
            timings.total_ns / std.time.ns_per_us,
            timings.create_output_dir_ns / std.time.ns_per_us,
            timings.load_full_image_ns / std.time.ns_per_us,
            timings.dmin_ns / std.time.ns_per_us,
            timings.ir_align_ns / std.time.ns_per_us,
            timings.path_setup_ns / std.time.ns_per_us,
            timings.plan_parallel_ns / std.time.ns_per_us,
            timings.frame_processing_ns / std.time.ns_per_us,
            timings.worker_setup_ns / std.time.ns_per_us,
            timings.scheduler_wait_ns / std.time.ns_per_us,
            timings.result_merge_ns / std.time.ns_per_us,
            timings.progress_build_ns / std.time.ns_per_us,
            timings.final_message_ns / std.time.ns_per_us,
        },
    );
    try stdout.print(
        ";rgb_crop_us={d};ir_crop_us={d};ir_clean_us={d};ir_defect_mask_us={d};ir_adaptive_dust_us={d};ir_adaptive_norm_us={d};ir_adaptive_background1_us={d};ir_adaptive_square1_us={d};ir_adaptive_blurred_square1_us={d};ir_adaptive_coarse_us={d};ir_adaptive_background2_us={d};ir_adaptive_square2_us={d};ir_adaptive_blurred_square2_us={d};ir_adaptive_final_us={d}",
        .{
            frame.rgb_crop_ns / std.time.ns_per_us,
            frame.ir_crop_ns / std.time.ns_per_us,
            frame.ir_clean_ns / std.time.ns_per_us,
            frame.ir_defect_mask_ns / std.time.ns_per_us,
            frame.ir_adaptive_dust_ns / std.time.ns_per_us,
            frame.ir_adaptive_norm_ns / std.time.ns_per_us,
            frame.ir_adaptive_background1_ns / std.time.ns_per_us,
            frame.ir_adaptive_square1_ns / std.time.ns_per_us,
            frame.ir_adaptive_blurred_square1_ns / std.time.ns_per_us,
            frame.ir_adaptive_coarse_ns / std.time.ns_per_us,
            frame.ir_adaptive_background2_ns / std.time.ns_per_us,
            frame.ir_adaptive_square2_ns / std.time.ns_per_us,
            frame.ir_adaptive_blurred_square2_ns / std.time.ns_per_us,
            frame.ir_adaptive_final_ns / std.time.ns_per_us,
        },
    );
    try stdout.print(
        ";ir_line_detection_us={d};ir_line_resize_us={d};ir_line_percentile_us={d};ir_meijering_us={d};ir_line_gate_us={d};ir_close_us={d};ir_component_filter_us={d};ir_dilate_us={d};ir_coverage_us={d};ir_mask_resize_us={d};ir_inpaint_total_us={d};ir_inpaint_noise_us={d};ir_inpaint_label_us={d};ir_inpaint_roi_extract_us={d};ir_local_grain_us={d};ir_biharmonic_us={d};ir_grain_synthesis_us={d};ir_masked_writeback_us={d};ir_neg_prepare_us={d};inversion_us={d};display_render_us={d};output_rotation_us={d};metadata_us={d};write_us={d};checksum={d}\n",
        .{
            frame.ir_line_detection_ns / std.time.ns_per_us,
            frame.ir_line_resize_ns / std.time.ns_per_us,
            frame.ir_line_percentile_ns / std.time.ns_per_us,
            frame.ir_meijering_ns / std.time.ns_per_us,
            frame.ir_line_gate_ns / std.time.ns_per_us,
            frame.ir_close_ns / std.time.ns_per_us,
            frame.ir_component_filter_ns / std.time.ns_per_us,
            frame.ir_dilate_ns / std.time.ns_per_us,
            frame.ir_coverage_ns / std.time.ns_per_us,
            frame.ir_mask_resize_ns / std.time.ns_per_us,
            frame.ir_inpaint_total_ns / std.time.ns_per_us,
            frame.ir_inpaint_noise_ns / std.time.ns_per_us,
            frame.ir_inpaint_label_ns / std.time.ns_per_us,
            frame.ir_inpaint_roi_extract_ns / std.time.ns_per_us,
            frame.ir_local_grain_ns / std.time.ns_per_us,
            frame.ir_biharmonic_ns / std.time.ns_per_us,
            frame.ir_grain_synthesis_ns / std.time.ns_per_us,
            frame.ir_masked_writeback_ns / std.time.ns_per_us,
            frame.ir_neg_prepare_ns / std.time.ns_per_us,
            frame.inversion_ns / std.time.ns_per_us,
            frame.display_render_ns / std.time.ns_per_us,
            frame.output_rotation_ns / std.time.ns_per_us,
            frame.metadata_ns / std.time.ns_per_us,
            frame.write_ns / std.time.ns_per_us,
            checksumStrings(timed.result.files),
        },
    );
}

fn benchDetectedFrameExportIrGaussianApproxTradeoff(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: anytype,
    scan_path: []const u8,
    loaded: workflow.QuickPreview,
    detected: workflow.AutoDetectResult,
) !void {
    if (detected.frames.len == 0) {
        try stdout.print("export_detected_frames_ir_gaussian_approx_tradeoff,{s},0,0,0,0,skipped_no_frames\n", .{scan_path});
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

    const outputs = export_pipeline.OutputSelection{
        .ir_neg = true,
        .ir_inv = true,
        .inv_only = true,
    };
    const current_dpi = loaded.info.dpi orelse fallback_export_dpi;

    const basename = try std.fmt.allocPrint(allocator, "zig_bench_ir_gaussian_approx_tradeoff_{d}", .{monotonicNowNs()});
    defer allocator.free(basename);
    var reference = try runExportCaptureWithRectsTimedPrecision(allocator, io, scan_path, outputs, true, .{}, basename, rects, current_dpi, true, .f32);
    defer reference.deinit(allocator, io);

    var candidate = try runExportCaptureWithRectsTimedPrecision(allocator, io, scan_path, outputs, true, .{}, basename, rects, current_dpi, true, .f32_down4_coarse);
    defer candidate.deinit(allocator, io);

    const comparison = try compareExportResults(allocator, reference.output_dir, reference.result, candidate.output_dir, candidate.result);
    if (!comparison.file_set_equal) return error.ExportFileSetMismatch;
    if (!comparison.metadata_equal) return error.ExportMetadataMismatch;

    const reference_parallelism: workflow.ExportParallelismDecision = reference.result.parallelism orelse .{
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
    const candidate_parallelism: workflow.ExportParallelismDecision = candidate.result.parallelism orelse .{
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
    const reference_timings = reference.timings orelse workflow.ExportWorkflowTimings{};
    const candidate_timings = candidate.timings orelse workflow.ExportWorkflowTimings{};
    const reference_frame = reference_timings.frame_timings;
    const candidate_frame = candidate_timings.frame_timings;

    try stdout.print(
        "export_detected_frames_ir_gaussian_approx_tradeoff,{s},{d},{d},{d},{d},candidate=down4_coarse;reference_us={d};candidate_us={d};speedup_x1000={d};frames={d};files={d};reference_workers={d};candidate_workers={d};reference_ir_inner_workers={d};candidate_ir_inner_workers={d}",
        .{
            scan_path,
            @as(usize, @intFromFloat(rects[0].w)),
            @as(usize, @intFromFloat(rects[0].h)),
            total_pixels,
            candidate.elapsed_ns / std.time.ns_per_us,
            reference.elapsed_ns / std.time.ns_per_us,
            candidate.elapsed_ns / std.time.ns_per_us,
            speedupX1000(reference.elapsed_ns, candidate.elapsed_ns),
            rects.len,
            candidate.result.files.len,
            reference_parallelism.worker_count,
            candidate_parallelism.worker_count,
            reference.result.ir_adaptive_worker_count,
            candidate.result.ir_adaptive_worker_count,
        },
    );
    try stdout.print(
        ";reference_ir_clean_us={d};candidate_ir_clean_us={d};reference_ir_defect_mask_us={d};candidate_ir_defect_mask_us={d};reference_ir_adaptive_dust_us={d};candidate_ir_adaptive_dust_us={d};reference_ir_close_us={d};candidate_ir_close_us={d};reference_ir_dilate_us={d};candidate_ir_dilate_us={d};reference_ir_inpaint_total_us={d};candidate_ir_inpaint_total_us={d}",
        .{
            reference_frame.ir_clean_ns / std.time.ns_per_us,
            candidate_frame.ir_clean_ns / std.time.ns_per_us,
            reference_frame.ir_defect_mask_ns / std.time.ns_per_us,
            candidate_frame.ir_defect_mask_ns / std.time.ns_per_us,
            reference_frame.ir_adaptive_dust_ns / std.time.ns_per_us,
            candidate_frame.ir_adaptive_dust_ns / std.time.ns_per_us,
            reference_frame.ir_close_ns / std.time.ns_per_us,
            candidate_frame.ir_close_ns / std.time.ns_per_us,
            reference_frame.ir_dilate_ns / std.time.ns_per_us,
            candidate_frame.ir_dilate_ns / std.time.ns_per_us,
            reference_frame.ir_inpaint_total_ns / std.time.ns_per_us,
            candidate_frame.ir_inpaint_total_ns / std.time.ns_per_us,
        },
    );
    try stdout.print(
        ";max_abs={d};rms={d:.6};mse={d:.6};mismatches={d};mismatch_pct_x1000={d};abs_gt_1={d};abs_gt_16={d};abs_gt_256={d};abs_gt_1024={d};abs_gt_4096={d};metadata_equal={};file_set_equal={};checksum_reference={d};checksum_candidate={d}\n",
        .{
            comparison.diff.max_abs,
            comparison.diff.rms,
            comparison.diff.mse,
            comparison.diff.mismatches,
            pctX1000(@intCast(comparison.diff.mismatches), @intCast(comparison.diff.count)),
            comparison.diff.abs_gt_1,
            comparison.diff.abs_gt_16,
            comparison.diff.abs_gt_256,
            comparison.diff.abs_gt_1024,
            comparison.diff.abs_gt_4096,
            comparison.metadata_equal,
            comparison.file_set_equal,
            checksumStrings(reference.result.files),
            checksumStrings(candidate.result.files),
        },
    );
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
    return runExportCaptureWithRectsMaybeTimed(allocator, io, scan_path, outputs, align_ir, invert_request, basename, rects, current_dpi, parallel_frames, null);
}

fn runExportCaptureWithRectsLegacy(
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
    return runExportCaptureWithRectsMaybeTimedDirect(allocator, io, scan_path, outputs, align_ir, invert_request, basename, rects, current_dpi, parallel_frames, false, null, null, null);
}

fn runExportCaptureWithRectsTimed(
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
    var timings = workflow.ExportWorkflowTimings{};
    return runExportCaptureWithRectsMaybeTimedDirect(allocator, io, scan_path, outputs, align_ir, invert_request, basename, rects, current_dpi, parallel_frames, true, &timings, null, null);
}

fn runExportCaptureWithRectsTimedPrecision(
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
    adaptive_dust_precision: ir_processing.AdaptiveDustPrecision,
) !ExportCapture {
    var timings = workflow.ExportWorkflowTimings{};
    return runExportCaptureWithRectsMaybeTimedDirect(allocator, io, scan_path, outputs, align_ir, invert_request, basename, rects, current_dpi, parallel_frames, true, &timings, adaptive_dust_precision, null);
}

fn runExportCaptureWithRectsMaybeTimed(
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
    timings: ?*workflow.ExportWorkflowTimings,
) !ExportCapture {
    return runExportCaptureWithRectsMaybeTimedDirect(allocator, io, scan_path, outputs, align_ir, invert_request, basename, rects, current_dpi, parallel_frames, true, timings, null, null);
}

fn runExportCaptureWithRectsMaybeTimedDirect(
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
    allow_direct_rgb_crop: bool,
    timings: ?*workflow.ExportWorkflowTimings,
    adaptive_dust_precision: ?ir_processing.AdaptiveDustPrecision,
    adaptive_dust_worker_count: ?usize,
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
        .allow_direct_rgb_crop = allow_direct_rgb_crop,
        .adaptive_dust_precision_override = adaptive_dust_precision,
        .adaptive_dust_worker_count_override = adaptive_dust_worker_count,
        .timings = timings,
    });
    errdefer result.deinit(allocator);
    return .{
        .output_dir = output_dir,
        .result = result,
        .elapsed_ns = monotonicNowNs() - started,
        .timings = if (timings) |out| out.* else null,
    };
}

fn runExportCaptureWithRectsDmin(
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
    dmin: [3]f64,
    allow_direct_rgb_crop: bool,
    timings: ?*workflow.ExportWorkflowTimings,
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
        .dmin = dmin,
        .current_dpi = current_dpi,
        .align_ir = align_ir,
        .invert_request = invert_request,
        .parallel_frames = parallel_frames,
        .allow_direct_rgb_crop = allow_direct_rgb_crop,
        .timings = timings,
    });
    errdefer result.deinit(allocator);
    return .{
        .output_dir = output_dir,
        .result = result,
        .elapsed_ns = monotonicNowNs() - started,
        .timings = if (timings) |out| out.* else null,
    };
}

fn runExportCaptureWithCachedRgbPage(
    allocator: std.mem.Allocator,
    io: std.Io,
    loaded: tiff.RgbPageWithMetadata,
    scan_path: []const u8,
    outputs: export_pipeline.OutputSelection,
    basename: []const u8,
    rects: []const export_pipeline.FrameRect,
    current_dpi: u32,
    parallel_frames: bool,
    dmin: [3]f64,
    timings: ?*workflow.ExportWorkflowTimings,
) !ExportCapture {
    const output_dir = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ default_output_dir, monotonicNowNs() });
    errdefer allocator.free(output_dir);
    errdefer std.Io.Dir.cwd().deleteTree(io, output_dir) catch {};

    const started = monotonicNowNs();
    var result = try workflow.processExportFromCachedRgbPage(allocator, io, loaded, .{
        .input_path = scan_path,
        .output_dir = output_dir,
        .basename = basename,
        .rects = rects,
        .outputs = outputs,
        .active_stock = benchmark_stock,
        .stock_coeffs = film_stocks.kodak_gold_coeffs,
        .dmin = dmin,
        .current_dpi = current_dpi,
        .align_ir = false,
        .invert_request = .{},
        .parallel_frames = parallel_frames,
        .allow_direct_rgb_crop = true,
        .timings = timings,
    });
    errdefer result.deinit(allocator);
    return .{
        .output_dir = output_dir,
        .result = result,
        .elapsed_ns = monotonicNowNs() - started,
        .timings = if (timings) |out| out.* else null,
    };
}

fn fullResolutionExportRects(
    allocator: std.mem.Allocator,
    preview_frames: []const frames.FrameRect,
    preview_scale: f64,
) ![]export_pipeline.FrameRect {
    const rects = try allocator.alloc(export_pipeline.FrameRect, preview_frames.len);
    errdefer allocator.free(rects);
    for (preview_frames, rects) |frame, *out| {
        const full = try frames.previewFrameToFullResolution(frame, preview_scale);
        out.* = .{
            .cx = full.cx,
            .cy = full.cy,
            .w = full.w,
            .h = full.h,
            .angle = full.angle,
            .rotation = 0,
        };
    }
    return rects;
}

fn maxDminAbsDiff(a: [3]f64, b: [3]f64) f64 {
    var max_abs: f64 = 0.0;
    for (a, b) |left, right| {
        max_abs = @max(max_abs, @abs(left - right));
    }
    return max_abs;
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

const ExportSetComparison = struct {
    diff: DiffSummary,
    metadata_equal: bool,
    file_set_equal: bool,
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

fn compareExportResults(
    allocator: std.mem.Allocator,
    reference_dir: []const u8,
    reference_result: workflow.ExportWorkflowResult,
    measured_dir: []const u8,
    measured_result: workflow.ExportWorkflowResult,
) !ExportSetComparison {
    var aggregate = DiffSummary{
        .count = 0,
        .max_abs = 0,
        .rms = 0.0,
        .mse = 0.0,
        .mismatches = 0,
        .abs_gt_1 = 0,
        .abs_gt_16 = 0,
        .abs_gt_256 = 0,
        .abs_gt_1024 = 0,
        .abs_gt_4096 = 0,
    };
    var sum_sq: f64 = 0.0;
    var metadata_equal = true;
    var file_set_equal = reference_result.files.len == measured_result.files.len;

    for (reference_result.files) |file| {
        const measured_index = findExportFile(measured_result.files, file) orelse {
            file_set_equal = false;
            continue;
        };
        const reference_path = try std.fs.path.join(allocator, &.{ reference_dir, file });
        defer allocator.free(reference_path);
        const measured_path = try std.fs.path.join(allocator, &.{ measured_dir, measured_result.files[measured_index] });
        defer allocator.free(measured_path);

        const reference_image = try tiff.loadRgbPage(allocator, reference_path);
        defer reference_image.deinit(allocator);
        const measured_image = try tiff.loadRgbPage(allocator, measured_path);
        defer measured_image.deinit(allocator);
        const diff = try compareTiffImages(reference_image, measured_image);
        aggregate.count += diff.count;
        aggregate.max_abs = @max(aggregate.max_abs, diff.max_abs);
        aggregate.mismatches += diff.mismatches;
        aggregate.abs_gt_1 += diff.abs_gt_1;
        aggregate.abs_gt_16 += diff.abs_gt_16;
        aggregate.abs_gt_256 += diff.abs_gt_256;
        aggregate.abs_gt_1024 += diff.abs_gt_1024;
        aggregate.abs_gt_4096 += diff.abs_gt_4096;
        sum_sq += diff.mse * @as(f64, @floatFromInt(diff.count));

        const reference_metadata = try tiff.readExportMetadataJson(allocator, reference_path);
        defer if (reference_metadata) |metadata| allocator.free(metadata);
        const measured_metadata = try tiff.readExportMetadataJson(allocator, measured_path);
        defer if (measured_metadata) |metadata| allocator.free(metadata);
        metadata_equal = metadata_equal and optionalBytesEqual(reference_metadata, measured_metadata);
    }

    aggregate.mse = if (aggregate.count == 0) 0.0 else sum_sq / @as(f64, @floatFromInt(aggregate.count));
    aggregate.rms = @sqrt(aggregate.mse);
    return .{
        .diff = aggregate,
        .metadata_equal = metadata_equal,
        .file_set_equal = file_set_equal,
    };
}

fn findExportFile(files: []const []const u8, target: []const u8) ?usize {
    for (files, 0..) |file, index| {
        if (std.mem.eql(u8, file, target)) return index;
    }
    return null;
}

const DiffSummary = struct {
    count: usize,
    max_abs: u64,
    rms: f64,
    mse: f64,
    mismatches: usize,
    abs_gt_1: usize,
    abs_gt_16: usize,
    abs_gt_256: usize,
    abs_gt_1024: usize,
    abs_gt_4096: usize,
};

const MaskAreaOverlap = struct {
    reference_area: usize = 0,
    candidate_area: usize = 0,
    intersection_area: usize = 0,
    union_area: usize = 0,

    fn add(self: *MaskAreaOverlap, other: MaskAreaOverlap) void {
        self.reference_area += other.reference_area;
        self.candidate_area += other.candidate_area;
        self.intersection_area += other.intersection_area;
        self.union_area += other.union_area;
    }

    fn iouX1000(self: MaskAreaOverlap) u64 {
        return ratioX1000(self.intersection_area, self.union_area);
    }

    fn referenceRetainedX1000(self: MaskAreaOverlap) u64 {
        return ratioX1000(self.intersection_area, self.reference_area);
    }

    fn candidateConfirmedX1000(self: MaskAreaOverlap) u64 {
        return ratioX1000(self.intersection_area, self.candidate_area);
    }

    fn diceX1000(self: MaskAreaOverlap) u64 {
        return ratioX1000(self.intersection_area * 2, self.reference_area + self.candidate_area);
    }
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
    var abs_gt_1: usize = 0;
    var abs_gt_16: usize = 0;
    var abs_gt_256: usize = 0;
    var abs_gt_1024: usize = 0;
    var abs_gt_4096: usize = 0;
    for (a, b) |left, right| {
        const diff = if (left >= right)
            @as(u64, left) - @as(u64, right)
        else
            @as(u64, right) - @as(u64, left);
        if (diff != 0) mismatches += 1;
        if (diff > 1) abs_gt_1 += 1;
        if (diff > 16) abs_gt_16 += 1;
        if (diff > 256) abs_gt_256 += 1;
        if (diff > 1024) abs_gt_1024 += 1;
        if (diff > 4096) abs_gt_4096 += 1;
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
        .abs_gt_1 = abs_gt_1,
        .abs_gt_16 = abs_gt_16,
        .abs_gt_256 = abs_gt_256,
        .abs_gt_1024 = abs_gt_1024,
        .abs_gt_4096 = abs_gt_4096,
    };
}

fn compareU16(a: []const u16, b: []const u16) !DiffSummary {
    if (a.len != b.len) return error.OutputLengthMismatch;
    var max_abs: u64 = 0;
    var sum_sq: f64 = 0.0;
    var mismatches: usize = 0;
    var abs_gt_1: usize = 0;
    var abs_gt_16: usize = 0;
    var abs_gt_256: usize = 0;
    var abs_gt_1024: usize = 0;
    var abs_gt_4096: usize = 0;
    for (a, b) |left, right| {
        const diff = if (left >= right)
            @as(u64, left) - @as(u64, right)
        else
            @as(u64, right) - @as(u64, left);
        if (diff != 0) mismatches += 1;
        if (diff > 1) abs_gt_1 += 1;
        if (diff > 16) abs_gt_16 += 1;
        if (diff > 256) abs_gt_256 += 1;
        if (diff > 1024) abs_gt_1024 += 1;
        if (diff > 4096) abs_gt_4096 += 1;
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
        .abs_gt_1 = abs_gt_1,
        .abs_gt_16 = abs_gt_16,
        .abs_gt_256 = abs_gt_256,
        .abs_gt_1024 = abs_gt_1024,
        .abs_gt_4096 = abs_gt_4096,
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
    var abs_gt_1: usize = 0;
    var abs_gt_16: usize = 0;
    var abs_gt_256: usize = 0;
    var abs_gt_1024: usize = 0;
    var abs_gt_4096: usize = 0;
    const count = a.len / 2;
    for (0..count) |index| {
        const left = std.mem.readInt(u16, a[index * 2 ..][0..2], .little);
        const right = std.mem.readInt(u16, b[index * 2 ..][0..2], .little);
        const diff = if (left >= right)
            @as(u64, left) - @as(u64, right)
        else
            @as(u64, right) - @as(u64, left);
        if (diff != 0) mismatches += 1;
        if (diff > 1) abs_gt_1 += 1;
        if (diff > 16) abs_gt_16 += 1;
        if (diff > 256) abs_gt_256 += 1;
        if (diff > 1024) abs_gt_1024 += 1;
        if (diff > 4096) abs_gt_4096 += 1;
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
        .abs_gt_1 = abs_gt_1,
        .abs_gt_16 = abs_gt_16,
        .abs_gt_256 = abs_gt_256,
        .abs_gt_1024 = abs_gt_1024,
        .abs_gt_4096 = abs_gt_4096,
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

fn ratioX1000(part: usize, total: usize) u64 {
    if (total == 0) return 0;
    return @intCast((@as(u128, part) * 100_000) / @as(u128, total));
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

