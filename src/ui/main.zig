const std = @import("std");
const cerealgrain = @import("cerealgrain");
const ui_theme = cerealgrain.native_ui_theme;

const ConnectWorker = cerealgrain.native_ui_connect_worker.Worker;
const PreviewBuffer = cerealgrain.native_ui_preview_worker.PreviewBuffer;
const PreviewWorker = cerealgrain.native_ui_preview_worker.Worker;
const ScanWorker = cerealgrain.native_ui_scan_worker.Worker;
const ProcessWorker = cerealgrain.native_ui_process_worker.Worker;
const ProcessExportWorker = cerealgrain.native_ui_process_export_worker.Worker;
const InvertedPreviewWorker = cerealgrain.native_ui_inverted_preview_worker.Worker;
const InvertedPreviewKey = cerealgrain.native_ui_inverted_preview_worker.Key;
const InvertedPreviewResult = cerealgrain.native_ui_inverted_preview_worker.Result;
const ProcessCache = cerealgrain.native_ui_process_cache;

const c = @import("sdl_nuklear.zig").c;
const chrome = @import("chrome.zig");
const selection_geometry = @import("selection_geometry.zig");
const render_layer = @import("render.zig");
const sound = @import("sound.zig");
const cursor = @import("cursor.zig");
const roll_panel = @import("roll_panel.zig");

const layoutRow = chrome.layoutRow;
const layoutRowStatic = chrome.layoutRowStatic;
const tooltip = chrome.tooltip;
const applyNuklearStyle = chrome.applyNuklearStyle;
const nkColor = chrome.nkColor;
const setRendererColor = chrome.setRendererColor;
const controlPanelFlags = chrome.controlPanelFlags;
const footerBarFlags = chrome.footerBarFlags;
const controlPanelRect = chrome.controlPanelRect;
const footerBarRect = chrome.footerBarRect;
const updateUiChromeRects = chrome.updateUiChromeRects;
const footerBarHeight = chrome.footerBarHeight;
const footerBarRectForSize = chrome.footerBarRectForSize;
const controlPanelRectForSize = chrome.controlPanelRectForSize;
const feedNuklearInput = chrome.feedNuklearInput;
const pointInControlPanel = chrome.pointInControlPanel;
const pointInFooterBar = chrome.pointInFooterBar;
const pointInUiChrome = chrome.pointInUiChrome;
const controlPanelShouldReceiveWheel = chrome.controlPanelShouldReceiveWheel;
const assertControlPanelPolicy = chrome.assertControlPanelPolicy;
const nkBool = chrome.nkBool;
const drawText = chrome.drawText;

const ProcessSelectionEditMode = selection_geometry.ProcessSelectionEditMode;
const ScanSelectionInteraction = selection_geometry.ScanSelectionInteraction;
const ProcessSelectionTarget = selection_geometry.ProcessSelectionTarget;
const ProcessDrawTarget = selection_geometry.ProcessDrawTarget;
const ProcessSelectionInteraction = selection_geometry.ProcessSelectionInteraction;
const ScanPreviewBounds = selection_geometry.ScanPreviewBounds;
const ScanPreviewPoint = selection_geometry.ScanPreviewPoint;
const ProcessPreviewPoint = selection_geometry.ProcessPreviewPoint;
const ProcessScreenPoint = selection_geometry.ProcessScreenPoint;
const ProcessPreviewBounds = selection_geometry.ProcessPreviewBounds;
const ProcessSelectionHit = selection_geometry.ProcessSelectionHit;
const scanImageRect = selection_geometry.scanImageRect;
const scanPreviewBounds = selection_geometry.scanPreviewBounds;
const screenToScanPreview = selection_geometry.screenToScanPreview;
const screenToScanPreviewUnclamped = selection_geometry.screenToScanPreviewUnclamped;
const hitScanSelection = selection_geometry.hitScanSelection;
const scanSelectionHandleAt = selection_geometry.scanSelectionHandleAt;
const processImageRect = selection_geometry.processImageRect;
const processPreviewBounds = selection_geometry.processPreviewBounds;
const screenToPreview = selection_geometry.screenToPreview;
const screenToPreviewUnclamped = selection_geometry.screenToPreviewUnclamped;
const processSelectionCenter = selection_geometry.processSelectionCenter;
const pointerAngleFromSelectionCenter = selection_geometry.pointerAngleFromSelectionCenter;
const selectionLocalToPreview = selection_geometry.selectionLocalToPreview;
const selectionLocalToScreen = selection_geometry.selectionLocalToScreen;
const previewToSelectionLocal = selection_geometry.previewToSelectionLocal;
const previewDeltaToSelectionLocal = selection_geometry.previewDeltaToSelectionLocal;
const processRotationHandleOffsetPreview = selection_geometry.processRotationHandleOffsetPreview;
const hitProcessSelection = selection_geometry.hitProcessSelection;
const processSelectionHandleAt = selection_geometry.processSelectionHandleAt;
const adjustedProcessSelection = selection_geometry.adjustedProcessSelection;
const rotatedProcessSelection = selection_geometry.rotatedProcessSelection;
const normalizeAngle = selection_geometry.normalizeAngle;
const clampSpanCenter = selection_geometry.clampSpanCenter;
const clampFloat = selection_geometry.clampFloat;
const imagePointOutsideUiChrome = selection_geometry.imagePointOutsideUiChrome;

const PreviewTextureCache = render_layer.PreviewTextureCache;
const ProcessPreviewTextureCache = render_layer.ProcessPreviewTextureCache;
const GalleryViewTransform = render_layer.GalleryViewTransform;
const GalleryTextureCache = render_layer.GalleryTextureCache;
const GalleryThumbnailCache = render_layer.GalleryThumbnailCache;
const NuklearRenderer = render_layer.NuklearRenderer;
const invertedPreviewCacheKey = render_layer.invertedPreviewCacheKey;
const cacheInvertedPreviewResult = render_layer.cacheInvertedPreviewResult;
const createProcessRgbTexture = render_layer.createProcessRgbTexture;
const nkImageForTexture = render_layer.nkImageForTexture;
const renderPreviewTexture = render_layer.renderPreviewTexture;
const renderProcessTexture = render_layer.renderProcessTexture;
const renderGalleryTexture = render_layer.renderGalleryTexture;
const galleryImageRgb8 = render_layer.galleryImageRgb8;
const renderSelectionOverlay = render_layer.renderSelectionOverlay;
const renderProcessSelections = render_layer.renderProcessSelections;
const renderSelectionHandles = render_layer.renderSelectionHandles;
const renderProcessSelectionHandles = render_layer.renderProcessSelectionHandles;
const processSelectionScreenCorners = render_layer.processSelectionScreenCorners;
const containsGalleryName = render_layer.containsGalleryName;
const setGalleryUiError = render_layer.setGalleryUiError;

const ProcessUiState = struct {
    preview_size: c_int = 8192,
    format_index: usize = 0,
    aspect_index: usize = default_process_aspect_index,
    n_frames: c_int = 0,
    scale_percent: f32 = 0.0,
    last_angle: f64 = 0.0,
    last_w: f64 = 0.0,
    last_h: f64 = 0.0,
    last_rotation: i32 = cerealgrain.native_ui.default_process_output_rotation,
    render_contrast: f32 = 1.8,
    dye_crosstalk: f32 = 0.2,
    render_percentile_lo: f32 = 0.5,
    render_percentile_hi: f32 = 99.5,
    exposure_compensation: f32 = 0.0,
    color_temp: f32 = 0.0,
    color_tint: f32 = 0.0,
    auto_white_balance: f32 = 1.0,
    ir_threshold: f32 = 0.10,
    ir_hair_sensitivity: f32 = 0.10,
    ir_dilate_radius: c_int = 4,
    ir_close_radius: c_int = 6,
    ir_min_area: c_int = 3,
    ir_max_coverage: f32 = 0.03,
    inpaint_padding: c_int = 16,
    export_ir_neg: bool = false,
    export_ir_inv: bool = true,
    export_inv_only: bool = false,
    export_basename_buffer: [128]u8 = [_]u8{0} ** 128,
    export_basename_len: c_int = 0,
    export_basename_source_buffer: [std.fs.max_path_bytes]u8 = [_]u8{0} ** std.fs.max_path_bytes,
    export_basename_source_len: usize = 0,
    settings_draft: cerealgrain.native_ui.ProcessSettingsDraft = .{},

    fn setExportBasename(self: *ProcessUiState, value: []const u8) void {
        @memset(self.export_basename_buffer[0..], 0);
        const len = @min(value.len, self.export_basename_buffer.len);
        @memcpy(self.export_basename_buffer[0..len], value[0..len]);
        self.export_basename_len = @intCast(len);
    }

    fn exportBasename(self: *const ProcessUiState) []const u8 {
        const len: usize = @intCast(@max(self.export_basename_len, 0));
        return self.export_basename_buffer[0..@min(len, self.export_basename_buffer.len)];
    }
};

const SmokeWindowSize = struct {
    width: c_int,
    height: c_int,
};

const ProcessAspectOption = struct {
    value: []const u8,
    label: []const u8,
    ratio: ?f64,
};

const process_aspect_options = [_]ProcessAspectOption{
    .{ .value = "free", .label = "Free", .ratio = null },
    .{ .value = "1:1", .label = "1:1", .ratio = 1.0 },
    .{ .value = "3:2", .label = "3:2", .ratio = 3.0 / 2.0 },
    .{ .value = "4:3", .label = "4:3", .ratio = 4.0 / 3.0 },
    .{ .value = "5:4", .label = "5:4", .ratio = 5.0 / 4.0 },
    .{ .value = "6:4.5", .label = "6:4.5", .ratio = 6.0 / 4.5 },
    .{ .value = "7:6", .label = "7:6", .ratio = 7.0 / 6.0 },
    .{ .value = "9:6", .label = "9:6", .ratio = 9.0 / 6.0 },
    .{ .value = "16:9", .label = "16:9", .ratio = 16.0 / 9.0 },
    .{ .value = "17:6", .label = "17:6", .ratio = 17.0 / 6.0 },
    .{ .value = "2:3", .label = "2:3", .ratio = 2.0 / 3.0 },
    .{ .value = "3:4", .label = "3:4", .ratio = 3.0 / 4.0 },
    .{ .value = "4:5", .label = "4:5", .ratio = 4.0 / 5.0 },
    .{ .value = "4.5:6", .label = "4.5:6", .ratio = 4.5 / 6.0 },
    .{ .value = "6:7", .label = "6:7", .ratio = 6.0 / 7.0 },
    .{ .value = "6:9", .label = "6:9", .ratio = 6.0 / 9.0 },
    .{ .value = "9:16", .label = "9:16", .ratio = 9.0 / 16.0 },
    .{ .value = "6:17", .label = "6:17", .ratio = 6.0 / 17.0 },
};

const default_process_aspect_index: usize = 2;

const process_formats = [_][]const u8{ "35mm", "645", "6x6", "6x7", "6x9" };
const process_format_labels = [_][*:0]const u8{ "35mm", "645", "6x6", "6x7", "6x9" };
pub fn main(init: std.process.Init) !void {
    var smoke = false;
    var any_smoke = false;
    var preview_worker_smoke = false;
    var scan_worker_smoke = false;
    var preview_render_smoke = false;
    var scan_interaction_smoke = false;
    var scan_sweep_smoke = false;
    var roll_reframe_smoke = false;
    var roll_close_smoke = false;
    var roll_smoke = false;
    var roll_name_input_smoke = false;
    var roll_strip_smoke = false;
    var process_render_smoke = false;
    var process_interaction_smoke = false;
    var process_worker_smoke = false;
    var process_worker_screenshot_smoke = false;
    var process_dump_smoke = false;
    var process_selector_smoke = false;
    var process_confirm_smoke = false;
    var process_export_smoke = false;
    var gallery_render_smoke = false;
    var gallery_interaction_smoke = false;
    var gallery_shortcut_smoke = false;
    var gallery_confirm_smoke = false;
    var gallery_trash_prompt_smoke = false;
    var gallery_delete_prompt_smoke = false;
    var scanner_connect_smoke = false;
    var preview_worker_output: []const u8 = "/tmp/cerealgrain-native-preview-worker-smoke.tiff";
    var scan_worker_output: []const u8 = "/tmp/cerealgrain-native-scan-worker-smoke.tiff";
    var timing_report_path: ?[]const u8 = null;
    var screenshot_path: ?[:0]const u8 = null;
    var smoke_hold_ms: u64 = 0;
    var smoke_resize_to: ?SmokeWindowSize = null;
    var initial_window_size: ?SmokeWindowSize = null;
    var process_ui = ProcessUiState{};
    var scan_dir: []const u8 = "scans";
    var output_dir: []const u8 = "frames";
    chrome.runtime_ui_config = ui_theme.Config.fromEnvironment(init.environ_map);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.endsWith(u8, arg, "-smoke")) any_smoke = true;
        if (std.mem.eql(u8, arg, "--smoke")) {
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--scanner-connect-smoke")) {
            scanner_connect_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--preview-worker-smoke")) {
            preview_worker_smoke = true;
        } else if (std.mem.eql(u8, arg, "--scan-worker-smoke")) {
            scan_worker_smoke = true;
        } else if (std.mem.eql(u8, arg, "--preview-render-smoke")) {
            preview_render_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--roll-strip-smoke")) {
            roll_strip_smoke = true;
        } else if (std.mem.eql(u8, arg, "--roll-name-input-smoke")) {
            roll_name_input_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--roll-smoke")) {
            preview_render_smoke = true;
            roll_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--scan-interaction-smoke")) {
            preview_render_smoke = true;
            scan_interaction_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--roll-close-smoke")) {
            roll_close_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--roll-reframe-smoke")) {
            roll_reframe_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--scan-sweep-smoke")) {
            preview_render_smoke = true;
            scan_sweep_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--process-render-smoke")) {
            process_render_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--process-interaction-smoke")) {
            process_render_smoke = true;
            process_interaction_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--process-worker-smoke")) {
            process_worker_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--process-worker-screenshot-smoke")) {
            process_worker_smoke = true;
            process_worker_screenshot_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--process-dump-smoke")) {
            process_dump_smoke = true;
        } else if (std.mem.eql(u8, arg, "--process-selector-smoke")) {
            process_render_smoke = true;
            process_selector_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--process-confirm-smoke")) {
            process_render_smoke = true;
            process_confirm_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--process-export-smoke")) {
            process_render_smoke = true;
            process_export_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--gallery-render-smoke")) {
            gallery_render_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--gallery-interaction-smoke")) {
            gallery_render_smoke = true;
            gallery_interaction_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--gallery-shortcut-smoke")) {
            gallery_render_smoke = true;
            gallery_shortcut_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--gallery-confirm-smoke")) {
            gallery_render_smoke = true;
            gallery_confirm_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--gallery-trash-prompt-smoke")) {
            gallery_render_smoke = true;
            gallery_trash_prompt_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--gallery-delete-prompt-smoke")) {
            gallery_render_smoke = true;
            gallery_delete_prompt_smoke = true;
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--ui-theme")) {
            const value = args.next() orelse return error.MissingUiTheme;
            chrome.runtime_ui_config.theme = ui_theme.ThemeName.parse(value) orelse return error.InvalidUiTheme;
        } else if (std.mem.eql(u8, arg, "--ui-scale")) {
            const value = args.next() orelse return error.MissingUiScale;
            chrome.runtime_ui_config.scale = try ui_theme.parseScale(value);
        } else if (std.mem.eql(u8, arg, "--screenshot")) {
            screenshot_path = args.next() orelse return error.MissingScreenshotPath;
        } else if (std.mem.eql(u8, arg, "--timing-report")) {
            timing_report_path = args.next() orelse return error.MissingTimingReportPath;
        } else if (std.mem.eql(u8, arg, "--smoke-hold-ms")) {
            const value = args.next() orelse return error.MissingSmokeHoldMs;
            smoke_hold_ms = try std.fmt.parseUnsigned(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--smoke-resize-to")) {
            const value = args.next() orelse return error.MissingSmokeResizeTo;
            smoke_resize_to = try parseSmokeWindowSize(value);
        } else if (std.mem.eql(u8, arg, "--window-size")) {
            const value = args.next() orelse return error.MissingWindowSize;
            initial_window_size = try parseSmokeWindowSize(value);
        } else if (std.mem.eql(u8, arg, "--scan-dir")) {
            scan_dir = args.next() orelse return error.MissingScanDir;
        } else if (std.mem.eql(u8, arg, "--output-dir")) {
            output_dir = args.next() orelse return error.MissingOutputDir;
        } else if (std.mem.eql(u8, arg, "--out")) {
            const output = args.next() orelse return error.MissingSmokeOutput;
            preview_worker_output = output;
            scan_worker_output = output;
        }
    }
    chrome.runtime_ui_config = chrome.runtime_ui_config.normalized();
    // Smokes run in the checkout and keep their paths there unless
    // CEREALGRAIN_DATA_DIR moves them.
    if (!any_smoke or init.environ_map.get("CEREALGRAIN_DATA_DIR") != null) try enterDataDir(init.io, init.environ_map);
    if (roll_smoke or roll_strip_smoke or roll_name_input_smoke or roll_reframe_smoke or roll_close_smoke) {
        scan_dir = roll_smoke_root ++ "/scans";
        output_dir = roll_smoke_root ++ "/frames";
    }
    if (process_export_smoke) {
        std.Io.Dir.cwd().deleteTree(init.io, export_smoke_root) catch {};
        output_dir = export_smoke_root;
    }
    var model = cerealgrain.native_ui.State.init(scan_dir, output_dir, 0);
    defer model.deinit(std.heap.page_allocator);
    std.Io.Dir.cwd().createDirPath(init.io, model.scanner.output_dir) catch {};
    model.syncScanCounter(init.io);
    var scanner_config_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const scanner_config_path = cerealgrain.native_ui.scannerConfigPath(&scanner_config_path_buffer, model.scanner.output_dir) catch cerealgrain.scanner.config.file_name;
    model.loadScannerConfig(std.heap.page_allocator, init.io, scanner_config_path) catch {};
    var processing_config_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const processing_config_path = if (roll_smoke or roll_strip_smoke or roll_name_input_smoke or roll_reframe_smoke or roll_close_smoke)
        roll_smoke_root ++ "/" ++ cerealgrain.processing.config.config_file
    else
        cerealgrain.native_ui.processingConfigPath(&processing_config_path_buffer) catch cerealgrain.processing.config.config_file;
    model.loadProcessingConfig(std.heap.page_allocator, init.io, processing_config_path) catch {};
    model.setProcessingGpuRequest(
        std.heap.page_allocator,
        try cerealgrain.processing.inversion.invertNegativeRequestFromEnvironment(init.environ_map),
    );
    syncProcessUiFromConfig(&process_ui, &model);
    var timing_report: ?cerealgrain.scanner.events.TimingReport = null;
    defer if (timing_report) |*report| report.deinit();
    var connect_worker = ConnectWorker.init(std.heap.page_allocator, init.io, init.environ_map);
    defer connect_worker.deinit();
    var preview_worker = PreviewWorker.init(std.heap.page_allocator, init.io, init.environ_map);
    defer preview_worker.deinit();
    var scan_worker = ScanWorker.init(std.heap.page_allocator, init.io, init.environ_map);
    defer scan_worker.deinit();
    var process_worker = ProcessWorker.init(std.heap.page_allocator, init.io);
    defer process_worker.deinit();
    var process_export_worker = ProcessExportWorker.init(std.heap.page_allocator, init.io);
    defer process_export_worker.deinit();
    var inverted_preview_worker = InvertedPreviewWorker.init(std.heap.page_allocator);
    defer inverted_preview_worker.deinit();
    var rolls = roll_panel.RollPanel.init(init.io, &model, scanner_config_path, processing_config_path);
    defer rolls.deinit(&model);
    // Smoke runs never reopen a real roll or export its strips.
    // Only a real session reopens the current roll: opening it saves both
    // configs and queues strip exports, which a smoke run from the checkout
    // must not do to the owner's rolls.
    const interactive = !any_smoke and screenshot_path == null;
    if (interactive) rolls.restore(&model);
    if (roll_smoke) try setupRollSmoke(&rolls, &model, init.io);
    if (roll_reframe_smoke) try runRollReframeSmoke(&rolls, &model, init.io);
    if (roll_close_smoke) try runRollCloseSmoke(&rolls, &model, init.io);
    if (roll_strip_smoke) {
        if (!hardwareSmokeEnabled(init.environ_map)) {
            std.debug.print("native roll strip smoke skipped: set CEREALGRAIN_HARDWARE_SMOKE=1 to run\n", .{});
            return;
        }
        std.Io.Dir.cwd().deleteTree(init.io, roll_smoke_root) catch {};
        var roll = try cerealgrain.roll.Roll.create(std.heap.page_allocator, init.io, model.scanner.output_dir, model.processing.output_dir, "strip-smoke", .{ .dpi = 800 });
        roll.deinit();
        try rolls.openRoll(&model, "strip-smoke");
    }
    var roll_strip_started = false;
    var text_input_active = false;
    // From the previous frame's draw; keyboard shortcuts stand aside while
    // a field is being edited.
    var text_editing = false;
    const roll_strip_deadline_ms: u64 = c.SDL_GetTicks() + 15 * std.time.ms_per_min;
    if (timing_report_path) |path| {
        timing_report = try cerealgrain.scanner.events.TimingReport.open(std.heap.page_allocator, init.io, path);
        if (timing_report) |*report| {
            const sink = report.sink();
            preview_worker.event_sink = sink;
            scan_worker.event_sink = sink;
        }
    }

    if (smoke) try assertScanBusyQueuePolicy();

    if (preview_worker_smoke) {
        try writeUiReportContext(&timing_report, .{
            .command = "native preview-worker smoke",
            .output = preview_worker_output,
            .source = .tpu,
            .kind = .rgb,
            .depth = .eight,
            .dpi = model.scanner.preview_dpi,
        });
        const skipped = !hardwareSmokeEnabled(init.environ_map);
        runPreviewWorkerSmoke(init.environ_map, &model, &preview_worker, preview_worker_output) catch |err| {
            writeUiReportStatus(&timing_report, "native preview-worker smoke", "error", @errorName(err), preview_worker_output);
            return err;
        };
        writeUiReportStatus(
            &timing_report,
            "native preview-worker smoke",
            if (skipped) "skipped" else "ok",
            if (skipped) "set CEREALGRAIN_HARDWARE_SMOKE=1 to run" else null,
            preview_worker_output,
        );
        return;
    }
    if (scan_worker_smoke) {
        try writeUiReportContext(&timing_report, .{
            .command = "native scan-worker smoke",
            .output = scan_worker_output,
            .source = .tpu,
            .kind = .rgb,
            .depth = .sixteen,
            .dpi = 800,
        });
        const skipped = !hardwareSmokeEnabled(init.environ_map);
        runScanWorkerSmoke(&model, &scan_worker, scan_worker_output) catch |err| {
            writeUiReportStatus(&timing_report, "native scan-worker smoke", "error", @errorName(err), scan_worker_output);
            return err;
        };
        writeUiReportStatus(
            &timing_report,
            "native scan-worker smoke",
            if (skipped) "skipped" else "ok",
            if (skipped) "set CEREALGRAIN_HARDWARE_SMOKE=1 to run" else null,
            scan_worker_output,
        );
        return;
    }
    if (process_dump_smoke) {
        try runProcessDumpSmoke(&model, std.heap.page_allocator);
        return;
    }
    const start_connect_worker = !preview_render_smoke and !process_render_smoke and !gallery_render_smoke;
    if (start_connect_worker) {
        if (smoke) connect_worker.execute = cerealgrain.native_ui_connect_worker.fakeConnectDelayedSuccess;
        if (!(try connect_worker.start(&model))) return error.ScannerConnectWorkerDidNotStart;
        if (scanner_connect_smoke or smoke) try assertScannerConnectSmokeInitial(&model);
    }
    if (preview_render_smoke) {
        try seedSyntheticPreview(&preview_worker, &model);
    }
    if (scan_sweep_smoke) seedScanSweepSmoke(&model);
    if (process_interaction_smoke) {
        process_worker.execute = cerealgrain.native_ui_process_worker.fakeRebateSuccess;
    }
    if (process_render_smoke) {
        try validateProcessAutoDetectUiDefaults(&process_ui);
        var smoke_processing_config = cerealgrain.processing.config.LoadedConfig{};
        try smoke_processing_config.apply(&.{
            .{ .name = "stock", .value = .{ .string = cerealgrain.processing.config.FixedString.init("kodak_gold") } },
        });
        model.applyProcessingConfig(smoke_processing_config);
        model.setProcessingPreviewInversionEnabled(true);
        if (process_confirm_smoke or process_selector_smoke) {
            try seedProcessMutationSmoke(&model, std.heap.page_allocator, init.io, processingPreviewSize(&process_ui));
        } else {
            try seedProcessPreview(&model, std.heap.page_allocator, processingPreviewSize(&process_ui));
        }
        model.show(.process);
        try validateProcessExportBasenameUiParity(&process_ui, &model);
    }
    if (process_worker_smoke) {
        process_worker.execute = if (process_worker_screenshot_smoke)
            cerealgrain.native_ui_process_worker.fakeLoadScreenshotDelayedSuccess
        else
            cerealgrain.native_ui_process_worker.fakeLoadDelayedSuccess;
        try seedProcessWorkerSmokeImages(&model, std.heap.page_allocator);
        model.show(.process);
        if (!(try process_worker.startLoadIndex(&model, 0, processingPreviewSize(&process_ui)))) {
            return error.ProcessWorkerSmokeFailed;
        }
    }
    if (gallery_render_smoke) {
        try seedSyntheticGallery(&model, init.io);
    }

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInitFailed;
    defer c.SDL_Quit();
    // The typing smoke copies and pastes; give the person their clipboard back.
    const saved_clipboard: ?*anyopaque = if (roll_name_input_smoke) c.SDL_GetClipboardText() else null;
    defer if (saved_clipboard) |text| {
        _ = c.SDL_SetClipboardText(@ptrCast(text));
        c.SDL_free(text);
    };
    defer sound.deinit();
    defer cursor.deinit();

    const runtime_metrics = chrome.runtime_ui_config.metrics();
    var initial_width = if (initial_window_size) |size| size.width else runtime_metrics.initialWindowWidth();
    var initial_height = if (initial_window_size) |size| size.height else runtime_metrics.initialWindowHeight();
    if (initial_window_size == null) {
        // Fit the default size to the screen (a laptop may be under 1000
        // points tall), keeping a margin for the menu bar and dock.
        var usable: c.SDL_Rect = undefined;
        if (c.SDL_GetDisplayUsableBounds(c.SDL_GetPrimaryDisplay(), &usable)) {
            initial_width = @min(initial_width, @max(640, @divTrunc(usable.w * 95, 100)));
            initial_height = @min(initial_height, @max(480, @divTrunc(usable.h * 95, 100)));
        }
    }
    const window = c.SDL_CreateWindow(
        "CerealGrain",
        initial_width,
        initial_height,
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse return error.SdlCreateWindowFailed;
    defer c.SDL_DestroyWindow(window);
    updateUiChromeRects(window, &model);
    if (smoke) try assertControlPanelPolicy();
    if (smoke and !process_worker_smoke) try assertFooterStatusPolicy(&process_worker, &process_export_worker);

    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlCreateRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);
    var preview_texture = PreviewTextureCache{};
    defer preview_texture.deinit();
    var scan_selection_interaction = ScanSelectionInteraction{};
    var process_texture = ProcessPreviewTextureCache{};
    defer process_texture.deinit(std.heap.page_allocator);
    var process_selection_interaction = ProcessSelectionInteraction{};
    var process_transform = cerealgrain.native_ui.ProcessViewTransform{};
    var scan_transform = cerealgrain.native_ui.ProcessViewTransform{};
    var scan_sweep = cerealgrain.native_ui_scan_sweep.Animator{};
    var synced_roll_generation: usize = 0;
    var process_confirmation = ProcessConfirmation{};
    defer process_confirmation.deinit(std.heap.page_allocator);
    var process_selector_checked = false;
    var process_export_checked = false;
    var gallery_texture = GalleryTextureCache{};
    defer gallery_texture.deinit(std.heap.page_allocator);
    var gallery_thumbnails = GalleryThumbnailCache{};
    defer gallery_thumbnails.deinit(std.heap.page_allocator);
    var gallery_transform = GalleryViewTransform{};
    defer gallery_transform.deinit(std.heap.page_allocator);
    var gallery_confirmation = GalleryConfirmation{};
    defer gallery_confirmation.deinit(std.heap.page_allocator);
    if (gallery_trash_prompt_smoke) {
        try requestGalleryConfirmation(&model, &gallery_confirmation, std.heap.page_allocator, .trash);
    }
    if (gallery_delete_prompt_smoke) {
        try requestGalleryConfirmation(&model, &gallery_confirmation, std.heap.page_allocator, .delete);
    }

    var nuklear_renderer = NuklearRenderer.init(renderer);
    defer nuklear_renderer.deinit();
    var ui_font = UiFont{ .requested_scale = chrome.runtime_ui_config.normalized().scale };
    defer ui_font.deinit();
    try ui_font.bake(window, &nuklear_renderer);

    var ctx: c.struct_nk_context = undefined;
    if (c.nk_init_default(&ctx, &ui_font.font.*.handle) == 0) return error.NuklearInitFailed;
    chrome.installClipboard(&ctx);
    defer c.nk_free(&ctx);
    applyNuklearStyle(&ctx, chrome.runtime_ui_config);

    var running = true;
    var frames: usize = 0;
    var nuklear_render_probe_done = false;
    var scan_interaction_checked = false;
    var process_inverted_render_checked = false;
    var process_interaction_checked = false;
    var process_worker_checked = false;
    var process_confirmation_checked = false;
    var gallery_interactions_checked = false;
    var gallery_shortcuts_checked = false;
    var gallery_confirmation_checked = false;
    var last_gallery_refresh_ms: u64 = 0;
    var window_title_eta: ?u64 = null;
    const smoke_started_ms = c.SDL_GetTicks();
    var smoke_resize_applied = false;
    while (running) {
        _ = connect_worker.poll(&model);
        var event: c.SDL_Event = undefined;
        const active_view_before = model.active_view;
        const scan_controls_before = model.scan_controls;
        updateUiChromeRects(window, &model);
        c.nk_input_begin(&ctx);
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_WINDOW_RESIZED or event.type == c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) {
                updateUiChromeRects(window, &model);
            }
            if (event.type == c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED or event.type == c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) {
                if (ui_font.densityChanged(window)) {
                    try ui_font.bake(window, &nuklear_renderer);
                    c.nk_style_set_font(&ctx, &ui_font.font.*.handle);
                    applyNuklearStyle(&ctx, chrome.runtime_ui_config);
                    updateUiChromeRects(window, &model);
                }
            }
            feedNuklearInput(&ctx, event);
            handleScanSelectionEvent(
                &scan_selection_interaction,
                &model,
                renderer,
                preview_worker.last_preview,
                &scan_transform,
                event,
            );
            handleScanShortcutEvent(&scan_selection_interaction, &model, event, text_editing);
            handleGalleryImageEvent(&gallery_transform, &model, event);
            handleProcessSelectionEvent(
                &process_selection_interaction,
                &process_transform,
                &model,
                &process_ui,
                renderer,
                &process_worker,
                processing_config_path,
                event,
            );
            handleProcessShortcutEvent(&process_selection_interaction, &model, event, text_editing);
            handleGalleryShortcutEvent(
                &model,
                &gallery_transform,
                &gallery_confirmation,
                std.heap.page_allocator,
                init.io,
                event,
                &last_gallery_refresh_ms,
            ) catch |err| setGalleryUiError(&model, err);
            if (event.type == c.SDL_EVENT_QUIT) {
                model.requestQuit();
            }
        }
        c.nk_input_end(&ctx);
        if (canvasCursorShape(
            &model,
            renderer,
            preview_worker.last_preview,
            &scan_transform,
            &scan_selection_interaction,
            &process_selection_interaction,
            &process_transform,
        )) |shape| cursor.set(shape);
        // A roll export in progress finishes before the app quits, with the
        // status line saying so, instead of freezing the window in shutdown.
        if (model.quit_requested and rolls.stopForQuit(&model)) running = false;

        if (c.nk_begin(
            &ctx,
            model.activeTitleZ(),
            controlPanelRect(),
            controlPanelFlags(),
        ) != 0) {
            drawNavigation(&ctx, &model);
            if (active_view_before != .gallery and model.active_view == .gallery) {
                _ = model.refreshGalleryFiles(std.heap.page_allocator, init.io) catch |err| {
                    setGalleryUiError(&model, err);
                };
                last_gallery_refresh_ms = c.SDL_GetTicks();
            }
            if (active_view_before != .process and model.active_view == .process) {
                ensureProcessImageLoaded(
                    &model,
                    &process_worker,
                    std.heap.page_allocator,
                    init.io,
                    @intCast(process_ui.preview_size),
                ) catch |err| setProcessUiError(&model, err);
            }
            switch (model.active_view) {
                .scan => drawScanView(&ctx, &model, init.io, &rolls, preview_worker.last_preview),
                .process => drawProcessView(
                    &ctx,
                    &model,
                    std.heap.page_allocator,
                    init.io,
                    processing_config_path,
                    &process_ui,
                    &process_selection_interaction,
                    &process_confirmation,
                    &process_worker,
                    &process_export_worker,
                    &process_transform,
                    &rolls,
                ),
                .gallery => drawGalleryView(
                    &ctx,
                    &model,
                    renderer,
                    &gallery_thumbnails,
                    &gallery_confirmation,
                    &gallery_transform,
                    std.heap.page_allocator,
                    init.io,
                ),
            }
        }
        c.nk_end(&ctx);
        text_editing = chrome.textEditing(&ctx);
        chrome.syncTextInput(window, text_editing, &text_input_active);
        if (model.takeReconnectRequest()) _ = connect_worker.start(&model) catch false;
        if (!scanControlsEqual(scan_controls_before, model.scan_controls)) {
            _ = model.saveScannerConfig(std.heap.page_allocator, init.io, scanner_config_path) catch false;
        }

        const scan_controls_before_workers = model.scan_controls;
        _ = preview_worker.startQueued(&model) catch |err| blk: {
            model.applyScannerBackendEvent(.{ .scan_error = .{
                .kind = .backend_failure,
                .detail = @errorName(err),
            } });
            break :blk false;
        };
        _ = scan_worker.startQueued(&model, preview_worker.last_preview) catch |err| blk: {
            model.applyScannerBackendEvent(.{ .scan_error = .{
                .kind = .backend_failure,
                .detail = @errorName(err),
            } });
            break :blk false;
        };
        _ = connect_worker.poll(&model);
        if (preview_worker.poll(&model)) {
            scan_transform.requestFit();
            rolls.afterPreview(&model, preview_worker.last_preview);
        }
        _ = scan_worker.poll(&model);
        model.updateScanProgressStatus(c.SDL_GetTicks());
        const scan_finished = model.takeScanFinished();
        if (scan_finished) sound.playScanFinished();
        rolls.afterScanPoll(&model, scan_finished);
        rolls.poll(&model);
        sound.update();
        updateWindowTitle(window, &model, &window_title_eta);
        if (process_worker.poll(&model)) {
            if (process_worker.takeLastAutoAspect()) |aspect| {
                process_ui.aspect_index = processAspectIndexClosestTo(aspect) orelse process_ui.aspect_index;
            }
        }
        _ = process_export_worker.poll(&model);
        if (inverted_preview_worker.poll()) |completed| {
            var result = completed;
            defer result.deinit(std.heap.page_allocator);
            _ = process_texture.installInvertedResult(renderer, std.heap.page_allocator, init.io, &model, &result) catch |err| blk: {
                setProcessUiError(&model, err);
                break :blk false;
            };
        }
        rolls.syncSavedFraming(&model);
        followRollInProcessView(&rolls, &process_ui, &synced_roll_generation);
        if (model.active_view == .process and model.takeProcessAutoDetectPending()) {
            startProcessAutoDetect(
                &model,
                &process_worker,
                processing_config_path,
                &process_ui,
            ) catch |err| setProcessUiError(&model, err);
        }
        // Hand edits settle, go on the undo stack, and save for roll strips.
        model.settleProcessEdits(c.SDL_GetTicks());
        rolls.saveFramingIfEdited(&model);
        // Restored frames with their own rebate, and rebate edits made while
        // the worker was busy, remeasure Dmin once it is free.
        if (model.process_rebate_dmin_pending and !process_worker.isRunning()) {
            _ = model.takeProcessRebateDminPending();
            startProcessRebate(&model, &process_worker, processing_config_path) catch |err| setProcessUiError(&model, err);
        }
        if (!scanControlsEqual(scan_controls_before_workers, model.scan_controls)) {
            _ = model.saveScannerConfig(std.heap.page_allocator, init.io, scanner_config_path) catch false;
        }
        _ = maybeRefreshGalleryFiles(
            &model,
            &gallery_transform,
            std.heap.page_allocator,
            init.io,
            c.SDL_GetTicks(),
            &last_gallery_refresh_ms,
        ) catch |err| setGalleryUiError(&model, err);
        drawFooterStatusBar(&ctx, &model, &process_worker, &process_export_worker);

        setRendererColor(renderer, chrome.runtime_ui_config.palette().background);
        _ = c.SDL_RenderClear(renderer);
        if (model.active_view == .gallery) {
            renderGalleryTexture(renderer, &gallery_texture, &gallery_transform, &model, std.heap.page_allocator);
        } else if (model.active_view == .process) {
            renderProcessTexture(renderer, init.io, &process_texture, &inverted_preview_worker, &model, &process_selection_interaction, &process_transform);
        } else {
            const now_ms = c.SDL_GetTicks();
            renderPreviewTexture(renderer, &preview_texture, preview_worker.last_preview, &model, &scan_transform, currentScanSweep(&scan_sweep, &model, now_ms), now_ms);
            if (scan_sweep_smoke and frames >= 1) try assertScanSweepRendered(renderer, &model, preview_worker.last_preview, &scan_transform);
        }
        try nuklear_renderer.render(&ctx);
        if ((preview_render_smoke or process_render_smoke or gallery_render_smoke) and !nuklear_render_probe_done) {
            try assertNuklearChromeRendered(renderer);
            if (process_render_smoke and (model.processing_preview == null or process_texture.texture == null)) {
                return error.ProcessRenderSmokeFailed;
            }
            if (gallery_render_smoke) {
                const gallery_info = model.galleryInfo();
                if (gallery_info.active_index == null or gallery_thumbnails.entries.len != gallery_info.image_count or !gallery_transform.isFitted()) {
                    return error.GalleryThumbnailSmokeFailed;
                }
            }
            nuklear_render_probe_done = true;
        }
        if (process_render_smoke and process_texture.used_inverted) {
            process_inverted_render_checked = true;
        }
        if (scan_interaction_smoke and !scan_interaction_checked and preview_texture.texture != null) {
            try runScanSelectionInteractionSmokeEvents(
                &scan_selection_interaction,
                &model,
                renderer,
                preview_worker.last_preview,
                &scan_transform,
                std.heap.page_allocator,
                init.io,
            );
            scan_interaction_checked = true;
        }
        if (process_interaction_smoke and !process_interaction_checked and process_texture.texture != null) {
            try runProcessSelectionInteractionSmokeEvents(
                &process_selection_interaction,
                &process_transform,
                &model,
                &process_ui,
                renderer,
                &process_worker,
                processing_config_path,
            );
            process_interaction_checked = true;
        }
        if (process_worker_smoke and !process_worker_checked) {
            if (!process_worker.isRunning() or !model.processing.loading) return error.ProcessWorkerSmokeFailed;
            process_worker_checked = true;
        }
        if (process_confirm_smoke and !process_confirmation_checked and process_texture.texture != null) {
            try runProcessConfirmationSmoke(
                &model,
                &process_confirmation,
                std.heap.page_allocator,
                init.io,
                processingPreviewSize(&process_ui),
            );
            process_confirmation_checked = true;
        }
        if (process_selector_smoke and !process_selector_checked and process_texture.texture != null) {
            try runProcessSelectorSmoke(
                &model,
                std.heap.page_allocator,
                init.io,
                processingPreviewSize(&process_ui),
            );
            process_selector_checked = true;
        }
        if (process_export_smoke and !process_export_checked and process_texture.texture != null) {
            try runProcessExportSmoke(&process_export_worker, &model, &process_ui);
            process_export_checked = true;
        }
        if (gallery_interaction_smoke and !gallery_interactions_checked and gallery_transform.isFitted()) {
            try runGalleryInteractionSmokeEvents(&gallery_transform, &model);
            gallery_interactions_checked = true;
        }
        if (gallery_shortcut_smoke and !gallery_shortcuts_checked and gallery_transform.isFitted()) {
            try runGalleryShortcutRefreshSmoke(
                &model,
                &gallery_transform,
                &gallery_confirmation,
                std.heap.page_allocator,
                init.io,
                &last_gallery_refresh_ms,
            );
            gallery_shortcuts_checked = true;
        }
        if (gallery_confirm_smoke and !gallery_confirmation_checked and gallery_transform.isFitted()) {
            try runGalleryConfirmationSmoke(
                &model,
                &gallery_transform,
                &gallery_confirmation,
                std.heap.page_allocator,
                init.io,
            );
            gallery_confirmation_checked = true;
        }
        if (screenshot_path) |path| saveScreenshot(renderer, path);
        _ = c.SDL_RenderPresent(renderer);
        c.nk_clear(&ctx);

        frames += 1;
        if (smoke_resize_to) |size| {
            if (!smoke_resize_applied and frames == 1) {
                if (!c.SDL_SetWindowSize(window, size.width, size.height)) return error.SdlSetWindowSizeFailed;
                _ = c.SDL_SyncWindow(window);
                updateUiChromeRects(window, &model);
                smoke_resize_applied = true;
            }
        }
        if (roll_strip_smoke) {
            // Click Scan Strip once connected, then run until its export lands.
            if (!roll_strip_started and model.scannerStatus().connected) {
                rolls.scanStrip(&model);
                roll_strip_started = true;
            } else if (roll_strip_started and rolls.exportsFinished() and !rolls.stripInFlight() and !model.scannerWorkActive()) {
                running = false;
            }
            if (model.scanner.connection == .error_state or c.SDL_GetTicks() > roll_strip_deadline_ms) {
                std.debug.print("native roll strip smoke: {s} {s}\n", .{ model.status, rolls.notice });
                return error.RollStripSmokeFailed;
            }
        }
        // Click the roll name field, then type, the way SDL delivers both.
        if (roll_name_input_smoke) {
            const field = rolls.name_field_rect;
            if (frames == 1) pushMouseButton(c.SDL_EVENT_MOUSE_BUTTON_DOWN, field.x + field.w / 2.0, field.y + field.h / 2.0);
            if (frames == 2) pushMouseButton(c.SDL_EVENT_MOUSE_BUTTON_UP, field.x + field.w / 2.0, field.y + field.h / 2.0);
            if (frames == 3) pushTextEvent("gold-45");
            if (frames == 4) pushKey(c.SDLK_BACKSPACE);
            if (frames == 5) pushTextEvent("00");
            // Select all, copy, go to the end, paste: the text doubles.
            if (frames == 6) pushKeyWithMod(c.SDLK_A, c.SDL_KMOD_GUI);
            if (frames == 7) pushKeyWithMod(c.SDLK_C, c.SDL_KMOD_GUI);
            if (frames == 8) pushKey(c.SDLK_END);
            if (frames == 9) pushKeyWithMod(c.SDLK_V, c.SDL_KMOD_GUI);
        }
        const smoke_min_frames: usize = if (roll_name_input_smoke) 12 else if (scan_interaction_smoke or scan_sweep_smoke or process_interaction_smoke or process_worker_smoke or process_selector_smoke or process_export_smoke or gallery_interaction_smoke or gallery_shortcut_smoke or gallery_confirm_smoke) 2 else 1;
        const smoke_max_frames: usize = if (process_render_smoke) 120 else smoke_min_frames;
        const smoke_elapsed_ms = c.SDL_GetTicks() - smoke_started_ms;
        if (smoke and frames >= smoke_min_frames and (!process_render_smoke or process_inverted_render_checked) and smoke_elapsed_ms >= smoke_hold_ms) running = false;
        if (smoke and frames >= smoke_max_frames) {
            if (process_render_smoke and !process_inverted_render_checked) return error.ProcessRenderSmokeFailed;
            if (smoke_elapsed_ms >= smoke_hold_ms) running = false;
        }
        c.SDL_Delay(16);
    }
    if (scan_interaction_smoke and !scan_interaction_checked) return error.ScanInteractionSmokeFailed;
    if (roll_smoke) {
        try assertRollSmoke(&rolls, &model);
        // The Process view follows the roll: 645, which needs no rotation.
        if (!std.mem.eql(u8, process_formats[process_ui.format_index], "645") or process_ui.last_rotation != 0) return error.RollSmokeFailed;
    }
    if (roll_name_input_smoke) {
        const typed = rolls.new_name[0..@intCast(rolls.new_name_len)];
        if (!std.mem.eql(u8, typed, "gold-400gold-400")) {
            std.debug.print("roll name input smoke typed \"{s}\"\n", .{typed});
            return error.RollNameInputSmokeFailed;
        }
        if (!text_input_active) return error.RollNameInputSmokeFailed;
    }
    if (roll_strip_smoke) try assertRollStripSmoke(&rolls, init.io);
    if (process_interaction_smoke and !process_interaction_checked) return error.ProcessInteractionSmokeFailed;
}

fn saveScreenshot(renderer: *c.SDL_Renderer, path: [:0]const u8) void {
    const surface = c.SDL_RenderReadPixels(renderer, null) orelse return;
    defer c.SDL_DestroySurface(surface);
    _ = c.SDL_SaveBMP(surface, path.ptr);
}

fn assertNuklearChromeRendered(renderer: *c.SDL_Renderer) !void {
    const surface = c.SDL_RenderReadPixels(renderer, null) orelse return error.SdlRenderReadbackFailed;
    defer c.SDL_DestroySurface(surface);

    const clear = chrome.runtime_ui_config.palette().background;
    const background = [_]u8{ clear.r, clear.g, clear.b };
    var y: c_int = 24;
    while (y < 340) : (y += 4) {
        var x: c_int = 24;
        while (x < 172) : (x += 4) {
            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;
            var a: u8 = 0;
            if (!c.SDL_ReadSurfacePixel(surface, x, y, &r, &g, &b, &a)) return error.SdlRenderReadbackFailed;
            if (pixelDiffers(background, .{ r, g, b })) return;
        }
    }
    return error.NuklearRenderProbeFailed;
}

fn pixelDiffers(a: [3]u8, b: [3]u8) bool {
    for (0..3) |index| {
        const av: i16 = a[index];
        const bv: i16 = b[index];
        if (@abs(av - bv) > 8) return true;
    }
    return false;
}

fn runPreviewWorkerSmoke(
    environ_map: *std.process.Environ.Map,
    model: *cerealgrain.native_ui.State,
    preview_worker: *PreviewWorker,
    output_path: []const u8,
) !void {
    if (!hardwareSmokeEnabled(environ_map)) {
        std.debug.print("native preview worker smoke skipped: set CEREALGRAIN_HARDWARE_SMOKE=1 to run\n", .{});
        return;
    }
    if (!model.scannerStatus().connected) {
        const caps = cerealgrain.scanner.contracts.ScannerCapabilities{};
        model.scannerConnected(0, 0, caps.tpu_width_in, caps.tpu_height_in);
    }
    if (!model.queuePreviewScan(output_path)) return error.PreviewWorkerPlanUnavailable;
    if (!(try preview_worker.startQueued(model))) return error.PreviewWorkerDidNotStart;
    while (!preview_worker.poll(model)) {
        try std.Thread.yield();
    }
    if (!model.preview_ready) return error.PreviewWorkerSmokeFailed;
    if (model.preview_image) |image| {
        std.debug.print("native preview worker cached {d}x{d} {d}-bit preview from {s}\n", .{
            image.width,
            image.height,
            image.bits_per_sample,
            output_path,
        });
    }
    std.debug.print("native preview worker smoke wrote {s}\n", .{output_path});
}

fn assertScannerConnectSmokeInitial(model: *cerealgrain.native_ui.State) !void {
    const status = model.scannerStatus();
    if (!status.connecting or status.connected) return error.ScannerConnectSmokeFailed;
    if (std.mem.eql(u8, status.status, "Ready")) return error.ScannerConnectSmokeFailed;
    if (std.mem.eql(u8, model.status, "Ready")) return error.ScannerConnectSmokeFailed;
    if (std.mem.eql(u8, model.scanStatusDisplay(), "Ready")) return error.ScannerConnectSmokeFailed;
}

fn assertScanBusyQueuePolicy() !void {
    var model = cerealgrain.native_ui.State.init("scans", "frames", 0);
    defer model.deinit(std.heap.page_allocator);
    model.scannerConnected(160, 100, 2.7, 9.54);
    if (!model.queuePreviewScan("/tmp/cerealgrain-native-preview-a.tiff")) return error.ScanBusySmokeFailed;
    if (model.queuePreviewScan("/tmp/cerealgrain-native-preview-b.tiff")) return error.ScanBusySmokeFailed;
    if (model.queueScanStartPath("/tmp/cerealgrain-native-scan-after-preview.tiff", null)) return error.ScanBusySmokeFailed;
    switch (model.pending_command orelse return error.ScanBusySmokeFailed) {
        .preview_scan => |plan| {
            if (!std.mem.eql(u8, plan.output_path, "/tmp/cerealgrain-native-preview-a.tiff")) return error.ScanBusySmokeFailed;
        },
        .scan_start => return error.ScanBusySmokeFailed,
    }
}

fn runScanWorkerSmoke(
    model: *cerealgrain.native_ui.State,
    scan_worker: *ScanWorker,
    output_path: []const u8,
) !void {
    if (!hardwareSmokeEnabled(scan_worker.environ_map)) {
        std.debug.print("native scan worker smoke skipped: set CEREALGRAIN_HARDWARE_SMOKE=1 to run\n", .{});
        return;
    }

    const caps = cerealgrain.scanner.contracts.ScannerCapabilities{};
    model.scannerConnected(1000, 1000, caps.tpu_width_in, caps.tpu_height_in);
    model.scan_controls.setMode(.rgb);
    model.scan_controls.setDpi(800);
    model.scan_controls.autoselect = false;
    model.scan_controls.setSelection(.{
        .x = 50.0,
        .y = 50.0,
        .w = 0.25 / caps.tpu_width_in * 1000.0,
        .h = 0.25 / caps.tpu_height_in * 1000.0,
    });

    const cancel_path = ".zig-cache/cerealgrain-native-scan-worker-smoke.cancel";
    if (!model.queueScanStartPath(output_path, cancel_path)) return error.ScanWorkerPlanUnavailable;
    if (!(try scan_worker.startQueued(model, null))) return error.ScanWorkerDidNotStart;
    while (!scan_worker.poll(model)) {
        try std.Thread.yield();
    }
    if (model.scanner.scanning) return error.ScanWorkerSmokeFailed;
    std.debug.print("native scan worker smoke status: {s}\n", .{model.status});
    std.debug.print("native scan worker smoke wrote {s}\n", .{output_path});
}

const roll_smoke_root = ".zig-cache/tmp/cerealgrain-native-roll-smoke";
const export_smoke_root = ".zig-cache/tmp/cerealgrain-native-export-smoke";

/// Creates a roll with one unexported-looking strip entry missing, then opens
/// it through the panel as a person would.
fn setupRollSmoke(rolls: *roll_panel.RollPanel, model: *cerealgrain.native_ui.State, io: std.Io) !void {
    std.Io.Dir.cwd().deleteTree(io, roll_smoke_root) catch {};
    var roll = try cerealgrain.roll.Roll.create(std.heap.page_allocator, io, model.scanner.output_dir, model.processing.output_dir, "smoke-roll", .{ .stock = "kodak_portra", .format = "645", .dpi = 1600 });
    roll.deinit();
    try rolls.openRoll(model, "smoke-roll");
    if (model.scan_controls.dpi != 1600 or model.scan_controls.mode != .rgb_ir) return error.RollSmokeFailed;
    // Picking another resolution with the roll open applies to its next strips.
    model.scan_controls.setDpi(3200);
}

/// Opens a roll whose one strip was auto-exported, frames it by hand in the
/// Process view, exports through the roll, and checks that the hand frame
/// replaced the automatic export under the roll's name and was saved.
fn runRollReframeSmoke(rolls: *roll_panel.RollPanel, model: *cerealgrain.native_ui.State, io: std.Io) !void {
    const allocator = std.heap.page_allocator;
    std.Io.Dir.cwd().deleteTree(io, roll_smoke_root) catch {};
    var roll = try cerealgrain.roll.Roll.create(allocator, io, model.scanner.output_dir, model.processing.output_dir, "reframe", .{ .dpi = 800 });
    defer roll.deinit();
    const strip = try roll.nextStripPath(io);
    defer allocator.free(strip);
    try writeSmokeStrip(strip);
    try rolls.openRoll(model, "reframe");
    try waitForRollExports(rolls, io);

    _ = try model.refreshProcessingImageList(allocator, io);
    const path = model.currentProcessingImagePathForWorker() orelse return error.RollReframeSmokeFailed;
    if (rolls.stripNumberOf(path) != 1) return error.RollReframeSmokeFailed;
    model.processing.preview_scale = 0.5;
    model.clearProcessingSelections();
    _ = try model.addProcessSelection(.{ .x = 20.0, .y = 40.0, .w = 50.0, .h = 75.0, .angle = 0.0, .rotation = 0 });
    try rolls.exportFramedStrip(model, path);
    try waitForRollExports(rolls, io);

    var exported = try cerealgrain.tiff.findImages(allocator, io, roll.frames_dir);
    defer exported.deinit(allocator);
    if (exported.paths.len != 1 or !std.mem.endsWith(u8, exported.paths[0], "/reframe_s01_01.tif")) return error.RollReframeSmokeFailed;
    const info = try cerealgrain.tiff.readRgbIrPageInfo(allocator, exported.paths[0]);
    if (info.rgb.width != 100 or info.rgb.height != 150) return error.RollReframeSmokeFailed;
    if (!roll.hasFraming(io, strip)) return error.RollReframeSmokeFailed;
    const marker = try std.fmt.allocPrint(allocator, "{s}{s}", .{ strip, cerealgrain.roll.processed_suffix });
    defer allocator.free(marker);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, marker, allocator, .limited(64 * 1024));
    defer allocator.free(text);
    if (std.mem.indexOf(u8, text, "\"framing\": \"manual\"") == null) return error.RollReframeSmokeFailed;

    // An edit saves once it settles; undo saves the earlier frames back.
    if (model.process_saved_framing == null) return error.RollReframeSmokeFailed;
    model.process_selections[0].x += 5.0;
    model.settleProcessEdits(1_000);
    model.settleProcessEdits(1_000 + cerealgrain.native_ui.process_edit_settle_ms);
    rolls.saveFramingIfEdited(model);
    if (try framingCx(allocator, io, strip) != 100.0) return error.RollReframeSmokeFailed;
    if (!model.undoProcessSelections()) return error.RollReframeSmokeFailed;
    rolls.saveFramingIfEdited(model);
    if (try framingCx(allocator, io, strip) != 90.0) return error.RollReframeSmokeFailed;
    // The smoke's frame then draws the Process view's roll export controls.
    model.active_view = .process;
}

fn framingCx(allocator: std.mem.Allocator, io: std.Io, strip: []const u8) !f64 {
    const framing_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ strip, cerealgrain.roll.framing_suffix });
    defer allocator.free(framing_path);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, framing_path, allocator, .limited(64 * 1024));
    defer allocator.free(text);
    const parsed = try std.json.parseFromSlice(struct { frames: []const struct { cx: f64 } }, allocator, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return parsed.value.frames[0].cx;
}

/// Closes a roll while its strip exports: Close Roll returns at once, the
/// panel reports the export still finishing, and it completes afterwards.
fn runRollCloseSmoke(rolls: *roll_panel.RollPanel, model: *cerealgrain.native_ui.State, io: std.Io) !void {
    const allocator = std.heap.page_allocator;
    std.Io.Dir.cwd().deleteTree(io, roll_smoke_root) catch {};
    var roll = try cerealgrain.roll.Roll.create(allocator, io, model.scanner.output_dir, model.processing.output_dir, "close", .{ .dpi = 800 });
    defer roll.deinit();
    const strip = try roll.nextStripPath(io);
    defer allocator.free(strip);
    try writeSmokeStripSized(strip, 1600, 4800);
    const second = try std.fmt.allocPrint(allocator, "{s}/strip_02_rgbir_800dpi.tiff", .{roll.dir});
    defer allocator.free(second);
    // 38 x 51 mm: room for one 35mm frame, so its export can run.
    try writeSmokeStripSized(second, 1200, 1600);
    try rolls.openRoll(model, "close");
    const processor = rolls.processor orelse return error.RollCloseSmokeFailed;
    var status_buffer: [256]u8 = undefined;
    var waited_ms: usize = 0;
    while (processor.status(&status_buffer) == null) : (waited_ms += 5) {
        if (waited_ms > 30_000) return error.RollCloseSmokeTimedOut;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }

    const started = c.SDL_GetTicks();
    rolls.closeRoll(model);
    const close_ms = c.SDL_GetTicks() - started;
    if (close_ms > 500 or rolls.isActive()) return error.RollCloseSmokeFailed;
    const finishing = rolls.finishing orelse return error.RollCloseSmokeFailed;
    std.debug.print("roll close smoke: Close Roll returned in {d} ms; still exporting: {s}; dropped {d} queued\n", .{ close_ms, finishing.status(&status_buffer) orelse "(between stages)", rolls.dropped_strips });
    if (rolls.dropped_strips != 1) return error.RollCloseSmokeFailed;

    waited_ms = 0;
    while (rolls.finishing != null) : (waited_ms += 20) {
        if (waited_ms > 300_000) return error.RollCloseSmokeTimedOut;
        rolls.poll(model);
        try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    }
    if (!roll.isProcessed(io, strip)) return error.RollCloseSmokeFailed;
    if (std.mem.indexOf(u8, rolls.notice, "1 queued strip will export when close is opened again") == null) return error.RollCloseSmokeFailed;
    if (roll.isProcessed(io, second)) return error.RollCloseSmokeFailed;

    // Reopening exports the strip the close dropped.
    try rolls.openRoll(model, "close");
    try waitForRollExports(rolls, io);
    if (!roll.isProcessed(io, second)) return error.RollCloseSmokeFailed;
}

fn waitForRollExports(rolls: *roll_panel.RollPanel, io: std.Io) !void {
    const processor = rolls.processor orelse return error.RollReframeSmokeFailed;
    var waited_ms: usize = 0;
    while (processor.pending() != 0) : (waited_ms += 20) {
        if (waited_ms > 120_000) return error.RollReframeSmokeTimedOut;
        try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    }
}

/// A plain grey 240x480 RGB+IR strip scan at 800 dpi.
fn writeSmokeStrip(path: []const u8) !void {
    try writeSmokeStripSized(path, 240, 480);
}

fn writeSmokeStripSized(path: []const u8, width: u32, height: u32) !void {
    const allocator = std.heap.page_allocator;
    const rgb = try allocator.alloc(u16, @as(usize, width) * height * 3);
    defer allocator.free(rgb);
    @memset(rgb, 30000);
    const thumb = [_]u8{117} ** (2 * 4 * 3);
    const ir = try allocator.alloc(u8, @as(usize, width) * height);
    defer allocator.free(ir);
    @memset(ir, 250);
    try cerealgrain.tiff.writeScanPages(allocator, path, &.{
        .{ .image = .{ .width = width, .height = height, .samples_per_pixel = 3, .bits_per_sample = 16, .data = std.mem.sliceAsBytes(rgb) }, .metadata = .{ .dpi = 800 } },
        .{ .image = .{ .width = 2, .height = 4, .samples_per_pixel = 3, .bits_per_sample = 8, .data = &thumb } },
        .{ .image = .{ .width = width, .height = height, .samples_per_pixel = 1, .bits_per_sample = 8, .data = ir }, .metadata = .{ .dpi = 800 } },
    });
}

/// A key press and release, as one keystroke.
fn pushKey(key: c.SDL_Keycode) void {
    pushKeyWithMod(key, 0);
}

fn pushKeyWithMod(key: c.SDL_Keycode, mod: c.SDL_Keymod) void {
    for ([_]u32{ c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP }) |kind| {
        var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
        event.type = kind;
        event.key.key = key;
        event.key.mod = mod;
        event.key.down = kind == c.SDL_EVENT_KEY_DOWN;
        _ = c.SDL_PushEvent(&event);
    }
}

fn pushMouseButton(kind: u32, x: f32, y: f32) void {
    var motion: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    motion.type = c.SDL_EVENT_MOUSE_MOTION;
    motion.motion.x = x;
    motion.motion.y = y;
    _ = c.SDL_PushEvent(&motion);
    var button: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    button.type = kind;
    button.button.button = c.SDL_BUTTON_LEFT;
    button.button.down = kind == c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    button.button.x = x;
    button.button.y = y;
    _ = c.SDL_PushEvent(&button);
}

fn pushTextEvent(text: [*:0]const u8) void {
    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = text;
    _ = c.SDL_PushEvent(&event);
}

fn assertRollSmoke(rolls: *roll_panel.RollPanel, model: *cerealgrain.native_ui.State) !void {
    if (!rolls.isActive()) return error.RollSmokeFailed;
    if (!std.mem.endsWith(u8, model.processing.input_dir, "/smoke-roll")) return error.RollSmokeFailed;
    if (!std.mem.endsWith(u8, model.processing.output_dir, "frames/smoke-roll")) return error.RollSmokeFailed;
    if (!std.mem.eql(u8, model.processing_config.activeStock() orelse "", "kodak_portra")) return error.RollSmokeFailed;
    const roll = &(rolls.active orelse return error.RollSmokeFailed);
    if (roll.dpi != 3200) return error.RollSmokeFailed;
    var saved = try cerealgrain.roll.Roll.open(std.heap.page_allocator, rolls.io, rolls.scans_root, rolls.frames_root, "smoke-roll");
    defer saved.deinit();
    if (saved.dpi != 3200) return error.RollSmokeFailed;
}

fn assertRollStripSmoke(rolls: *roll_panel.RollPanel, io: std.Io) !void {
    const roll = &(rolls.active orelse return error.RollStripSmokeFailed);
    var strips = try roll.listStrips(io);
    defer strips.deinit(std.heap.page_allocator);
    if (strips.paths.len != 1 or !roll.isProcessed(io, strips.paths[0])) return error.RollStripSmokeFailed;
    var exported = try cerealgrain.tiff.findImages(std.heap.page_allocator, io, roll.frames_dir);
    defer exported.deinit(std.heap.page_allocator);
    if (exported.paths.len == 0) return error.RollStripSmokeFailed;
    std.debug.print("native roll strip smoke: {s} exported {d} frame file{s} to {s}\n", .{
        std.fs.path.basename(strips.paths[0]),
        exported.paths.len,
        if (exported.paths.len == 1) "" else "s",
        roll.frames_dir,
    });
}

/// Zoom for one wheel event, in proportion to how far it scrolled: a mouse
/// notch (1.0) zooms by `base`, a trackpad sends many small fractions, and a
/// sideways swipe (0) does not zoom.
fn wheelZoomFactor(wheel_y: f32, base: f64) f64 {
    return std.math.pow(f64, base, std.math.clamp(@as(f64, wheel_y), -3.0, 3.0));
}

fn enterDataDir(io: std.Io, environ_map: *std.process.Environ.Map) !void {
    var exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buffer) catch 0;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try cerealgrain.native_ui.dataDirPath(&path_buffer, environ_map.get("CEREALGRAIN_DATA_DIR"), environ_map.get("HOME"), exe_buffer[0..exe_len]) orelse return;
    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer dir.close(io);
    try std.process.setCurrentDir(io, dir);
}

fn hardwareSmokeEnabled(environ_map: *std.process.Environ.Map) bool {
    const value = environ_map.get("CEREALGRAIN_HARDWARE_SMOKE") orelse return false;
    return std.mem.eql(u8, value, "1");
}

fn writeUiReportContext(
    report: *?cerealgrain.scanner.events.TimingReport,
    event: cerealgrain.scanner.events.TimingContextEvent,
) !void {
    if (report.*) |*item| try item.writeContext(event);
}

fn writeUiReportStatus(
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

/// Nuklear's built-in 13 px pixel font, baked at a whole number of device
/// pixels per font pixel for the window's pixel density. Drawing stays in
/// window points (the render scale is the density), so glyphs land 1:1 on
/// device pixels instead of being stretched to a fractional size.
const UiFont = struct {
    requested_scale: f32,
    density: f32 = 0.0,
    atlas: ?c.struct_nk_font_atlas = null,
    font: *c.struct_nk_font = undefined,

    fn windowDensity(window: *c.SDL_Window) f32 {
        const density = c.SDL_GetWindowPixelDensity(window);
        return if (std.math.isFinite(density) and density >= 1.0) density else 1.0;
    }

    fn densityChanged(self: *const UiFont, window: *c.SDL_Window) bool {
        return windowDensity(window) != self.density;
    }

    /// Sets the render scale and the UI scale for the window's density and
    /// bakes the font into the renderer's font texture. The caller points
    /// the Nuklear context at `font` afterwards.
    fn bake(self: *UiFont, window: *c.SDL_Window, nuklear_renderer: *NuklearRenderer) !void {
        const density = windowDensity(window);
        const multiple = ui_theme.fontPixelMultiple(self.requested_scale, density);
        const device_px = 13.0 * multiple;

        var atlas: c.struct_nk_font_atlas = undefined;
        c.nk_font_atlas_init_default(&atlas);
        errdefer c.nk_font_atlas_clear(&atlas);
        c.nk_font_atlas_begin(&atlas);
        var config = c.nk_font_config(device_px);
        config.pixel_snap = 1;
        config.oversample_h = 1;
        config.oversample_v = 1;
        const font = c.nk_font_atlas_add_default(&atlas, device_px, &config) orelse return error.NuklearFontFailed;
        var width: c_int = 0;
        var height: c_int = 0;
        const pixels = c.nk_font_atlas_bake(&atlas, &width, &height, c.NK_FONT_ATLAS_RGBA32) orelse return error.NuklearFontBakeFailed;
        try nuklear_renderer.setFontTexture(pixels, width, height);
        c.nk_font_atlas_end(&atlas, c.nk_handle_ptr(nuklear_renderer.font_texture), &nuklear_renderer.null_texture);
        // Glyphs are baked in device pixels; layout measures in points.
        font.*.handle.height = device_px / density;

        _ = c.SDL_SetRenderScale(nuklear_renderer.renderer, density, density);
        chrome.runtime_ui_config.scale = multiple / density;
        if (self.atlas) |*old| c.nk_font_atlas_clear(old);
        self.atlas = atlas;
        self.font = font;
        self.density = density;
    }

    fn deinit(self: *UiFont) void {
        if (self.atlas) |*atlas| c.nk_font_atlas_clear(atlas);
    }
};

/// When a roll opens, the Process view takes its film format (for
/// auto-detect) and its rotation (for frames you draw).
fn followRollInProcessView(rolls: *const roll_panel.RollPanel, ui: *ProcessUiState, synced_generation: *usize) void {
    if (rolls.generation == synced_generation.*) return;
    synced_generation.* = rolls.generation;
    const roll = &(rolls.active orelse return);
    for (process_formats, 0..) |format, index| {
        if (std.mem.eql(u8, format, roll.format)) ui.format_index = index;
    }
    ui.last_rotation = roll.rotation;
}

/// The scan line for this frame: over the selection being scanned, or the
/// whole preview during a preview scan.
fn currentScanSweep(
    animator: *cerealgrain.native_ui_scan_sweep.Animator,
    model: *const cerealgrain.native_ui.State,
    now_ms: u64,
) ?cerealgrain.native_ui_scan_sweep.Sweep {
    if (!model.scanner.scanning) {
        animator.reset();
        return null;
    }
    const area: ?cerealgrain.native_ui.PreviewSelection = if (model.preview_requested)
        null
    else
        model.active_scan_selection orelse return null;
    const ir_pass = !model.preview_requested and (model.scan_ir_pass or model.active_scan_mode == .ir);
    const fraction = animator.update(model.scanner_progress_percent, ir_pass, now_ms);
    return .{ .area = area, .fraction = fraction orelse 0.0, .ir_pass = ir_pass, .waiting = fraction == null };
}

/// An RGB+IR scan 40% through its RGB pass over a large selection.
fn seedScanSweepSmoke(model: *cerealgrain.native_ui.State) void {
    model.scan_controls.setSelection(.{ .x = 20.0, .y = 10.0, .w = 120.0, .h = 80.0 });
    model.active_scan_selection = model.scan_controls.selection;
    model.active_scan_mode = .rgb_ir;
    model.active_scan_dpi = 3200;
    model.scanner.scanning = true;
    model.scanner_progress_percent = 40;
}

/// The line sits at the reported progress down the selection, blue in the
/// RGB pass and red in the IR pass.
fn assertScanSweepRendered(
    renderer: *c.SDL_Renderer,
    model: *const cerealgrain.native_ui.State,
    preview: ?cerealgrain.native_ui_preview_worker.PreviewBuffer,
    transform: *cerealgrain.native_ui.ProcessViewTransform,
) !void {
    const rect = selection_geometry.scanImageRect(renderer, preview, transform) orelse return error.ScanSweepSmokeFailed;
    const sel = model.active_scan_selection orelse return error.ScanSweepSmokeFailed;
    const x: c_int = @intFromFloat(rect.x + (sel.x + sel.w / 2.0) * rect.scale);
    const fraction = @as(f64, @floatFromInt(model.scanner_progress_percent orelse 0)) / 100.0;
    const y: c_int = @intFromFloat(rect.y + (sel.y + sel.h * fraction) * rect.scale);
    const surface = c.SDL_RenderReadPixels(renderer, null) orelse return error.SdlRenderReadbackFailed;
    defer c.SDL_DestroySurface(surface);
    var r: u8 = 0;
    var g: u8 = 0;
    var b: u8 = 0;
    var a: u8 = 0;
    if (!c.SDL_ReadSurfacePixel(surface, x, y, &r, &g, &b, &a)) return error.SdlRenderReadbackFailed;
    const lit = if (model.scan_ir_pass) r >= 190 and r >= b else b >= 190 and g >= 160 and b >= r;
    if (!lit) return error.ScanSweepSmokeFailed;
}

fn seedSyntheticPreview(preview_worker: *PreviewWorker, model: *cerealgrain.native_ui.State) !void {
    const width: usize = 160;
    const height: usize = 100;
    const channels: usize = 3;
    const data = try std.heap.page_allocator.alloc(u8, width * height * channels);
    errdefer std.heap.page_allocator.free(data);
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * width + x) * channels;
            data[offset] = @intCast((x * 255) / width);
            data[offset + 1] = @intCast((y * 255) / height);
            data[offset + 2] = @intCast(((x + y) * 255) / (width + height));
        }
    }
    const output_path = try std.heap.page_allocator.dupe(u8, "synthetic-preview");
    errdefer std.heap.page_allocator.free(output_path);
    preview_worker.last_preview = .{
        .output_path = output_path,
        .width = @intCast(width),
        .height = @intCast(height),
        .samples_per_pixel = @intCast(channels),
        .bits_per_sample = 8,
        .data = data,
    };
    const caps = cerealgrain.scanner.contracts.ScannerCapabilities{};
    model.scan_controls.autoselect = false;
    model.finishPreviewScan(caps, preview_worker.last_preview.?.info());
    model.scan_controls.setSelection(.{ .x = 100.0, .y = 55.0, .w = 35.0, .h = 30.0 });
}

fn seedProcessWorkerSmokeImages(model: *cerealgrain.native_ui.State, allocator: std.mem.Allocator) !void {
    model.processing_images.deinit(allocator);
    model.processing_images.paths = try allocator.alloc([]u8, 1);
    errdefer {
        allocator.free(model.processing_images.paths);
        model.processing_images.paths = &.{};
    }
    model.processing_images.paths[0] = try allocator.dupe(u8, "scans/process-worker-smoke.tiff");
    model.processing.image_count = 1;
    model.processing.image_idx = 0;
}

fn seedProcessPreview(
    model: *cerealgrain.native_ui.State,
    allocator: std.mem.Allocator,
    preview_size: i64,
) !void {
    model.processing_images.deinit(allocator);
    model.processing_images.paths = try allocator.alloc([]u8, 1);
    errdefer {
        for (model.processing_images.paths) |path| allocator.free(path);
        allocator.free(model.processing_images.paths);
        model.processing_images.paths = &.{};
    }
    model.processing_images.paths[0] = try allocator.dupe(u8, "test/fixtures/tiff/rgb-thumb-ir.tiff");
    model.processing.image_count = 1;
    model.processing.image_idx = 0;
    _ = try model.switchProcessingImage(allocator, 0, preview_size);
}

fn seedProcessMutationSmoke(
    model: *cerealgrain.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    preview_size: i64,
) !void {
    const scan_dir = ".zig-cache/tmp/cerealgrain-native-process-confirm-smoke/scans";
    const output_dir = ".zig-cache/tmp/cerealgrain-native-process-confirm-smoke/frames";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, ".zig-cache/tmp/cerealgrain-native-process-confirm-smoke") catch {};
    try cwd.createDirPath(io, scan_dir);
    try cwd.createDirPath(io, output_dir);
    const fixture = try cwd.readFileAlloc(
        io,
        "test/fixtures/tiff/rgb-thumb-ir.tiff",
        allocator,
        .limited(128 * 1024),
    );
    defer allocator.free(fixture);
    try cwd.writeFile(io, .{ .sub_path = ".zig-cache/tmp/cerealgrain-native-process-confirm-smoke/scans/confirm_a.tiff", .data = fixture });
    try cwd.writeFile(io, .{ .sub_path = ".zig-cache/tmp/cerealgrain-native-process-confirm-smoke/scans/confirm_b.tiff", .data = fixture });
    model.processing.input_dir = scan_dir;
    model.processing.output_dir = output_dir;
    _ = try model.refreshProcessingImageList(allocator, io);
    _ = try model.switchProcessingImage(allocator, 0, preview_size);
}

fn seedSyntheticGallery(model: *cerealgrain.native_ui.State, io: std.Io) !void {
    const output_dir = ".zig-cache/tmp/cerealgrain-native-gallery-smoke";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, output_dir) catch {};
    try cwd.createDirPath(io, output_dir);
    const fixture = try cwd.readFileAlloc(
        io,
        "test/fixtures/tiff/rgb-thumb-ir.tiff",
        std.heap.page_allocator,
        .limited(128 * 1024),
    );
    defer std.heap.page_allocator.free(fixture);
    try cwd.writeFile(io, .{ .sub_path = ".zig-cache/tmp/cerealgrain-native-gallery-smoke/roll_01_inv.tif", .data = fixture });
    try cwd.writeFile(io, .{ .sub_path = ".zig-cache/tmp/cerealgrain-native-gallery-smoke/roll_02_inv.tif", .data = fixture });
    model.processing.output_dir = output_dir;
    _ = try model.refreshGalleryFiles(std.heap.page_allocator, io);
    model.show(.gallery);
}

fn handleScanSelectionEvent(
    interaction: *ScanSelectionInteraction,
    model: *cerealgrain.native_ui.State,
    renderer: *c.SDL_Renderer,
    preview: ?PreviewBuffer,
    transform: *cerealgrain.native_ui.ProcessViewTransform,
    event: c.SDL_Event,
) void {
    if (model.active_view != .scan) {
        interaction.end();
        transform.panning = false;
        return;
    }
    const image_rect = scanImageRect(renderer, preview, transform) orelse {
        interaction.end();
        return;
    };
    const bounds = scanPreviewBounds(preview) orelse return;
    switch (event.type) {
        c.SDL_EVENT_MOUSE_WHEEL => {
            const screen_x = @as(f64, @floatCast(event.wheel.mouse_x));
            const screen_y = @as(f64, @floatCast(event.wheel.mouse_y));
            if (pointInUiChrome(screen_x, screen_y)) return;
            var wheel_y = event.wheel.y;
            if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) wheel_y = -wheel_y;
            transform.zoomAt(screen_x, screen_y, wheelZoomFactor(wheel_y, 1.15));
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const screen_x = @as(f64, @floatCast(event.button.x));
            const screen_y = @as(f64, @floatCast(event.button.y));
            if (pointInUiChrome(screen_x, screen_y)) return;
            if (event.button.button == c.SDL_BUTTON_MIDDLE) {
                transform.beginPan(screen_x, screen_y, event.button.button);
                return;
            }
            if (event.button.button != c.SDL_BUTTON_LEFT) return;
            const preview_point = screenToScanPreviewUnclamped(image_rect, screen_x, screen_y);
            if (hitScanSelection(model.scan_controls.selection, image_rect, screen_x, screen_y, preview_point.x, preview_point.y)) |mode| {
                const selection = model.scan_controls.selection orelse return;
                interaction.beginEdit(mode, preview_point.x, preview_point.y, selection);
            } else if (screenToScanPreview(image_rect, screen_x, screen_y)) |inside_preview_point| {
                model.scan_controls.selection = .{
                    .x = inside_preview_point.x,
                    .y = inside_preview_point.y,
                    .w = 0.0,
                    .h = 0.0,
                };
                interaction.beginDraw(inside_preview_point.x, inside_preview_point.y);
            }
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            transform.updatePan(@as(f64, @floatCast(event.motion.x)), @as(f64, @floatCast(event.motion.y)));
            if (!interaction.active) return;
            const preview_point = screenToScanPreviewUnclamped(
                image_rect,
                @as(f64, @floatCast(event.motion.x)),
                @as(f64, @floatCast(event.motion.y)),
            );
            if (interaction.drawing()) {
                model.scan_controls.selection = cerealgrain.native_ui.previewSelectionFromDraw(
                    interaction.start_x,
                    interaction.start_y,
                    preview_point.x,
                    preview_point.y,
                    bounds.w,
                    bounds.h,
                );
            } else {
                model.scan_controls.selection = cerealgrain.native_ui.adjustedPreviewSelection(
                    interaction.original,
                    interaction.mode,
                    preview_point.x - interaction.start_x,
                    preview_point.y - interaction.start_y,
                    bounds.w,
                    bounds.h,
                );
            }
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (event.button.button == c.SDL_BUTTON_MIDDLE) transform.endPan(event.button.button);
            if (event.button.button != c.SDL_BUTTON_LEFT or !interaction.active) return;
            if (interaction.drawing()) {
                const selection = model.scan_controls.selection;
                if (selection == null or !selection.?.isDrawable()) {
                    model.scan_controls.selection = null;
                    model.setStatus("Selection too small, cleared");
                } else {
                    model.setStatus("Selection ready");
                }
            } else {
                model.setStatus("Selection adjusted");
            }
            interaction.end();
        },
        else => {},
    }
}

/// Cursor for the image under the mouse, or null to keep the current one while
/// a selection is being dragged.
fn canvasCursorShape(
    model: *const cerealgrain.native_ui.State,
    renderer: *c.SDL_Renderer,
    preview: ?PreviewBuffer,
    scan_transform: *cerealgrain.native_ui.ProcessViewTransform,
    scan_interaction: *const ScanSelectionInteraction,
    process_interaction: *const ProcessSelectionInteraction,
    process_transform: *cerealgrain.native_ui.ProcessViewTransform,
) ?cursor.Shape {
    var mouse_x: f32 = 0.0;
    var mouse_y: f32 = 0.0;
    _ = c.SDL_GetMouseState(&mouse_x, &mouse_y);
    const x: f64 = mouse_x;
    const y: f64 = mouse_y;
    if (pointInUiChrome(x, y)) return .default;
    switch (model.active_view) {
        .scan => {
            if (scan_interaction.active) return null;
            if (scan_transform.panning) return .move;
            const rect = scanImageRect(renderer, preview, scan_transform) orelse return .default;
            const point = screenToScanPreviewUnclamped(rect, x, y);
            if (hitScanSelection(model.scan_controls.selection, rect, x, y, point.x, point.y)) |mode| return cursor.forScanEdit(mode);
            return if (screenToScanPreview(rect, x, y) != null) .crosshair else .default;
        },
        .process => {
            if (process_interaction.active_target != null) return null;
            if (process_transform.panning) return .move;
            if (!model.processPreviewInteractionReady()) return .default;
            const rect = processImageRect(renderer, model, process_transform) orelse return .default;
            if (process_interaction.pending_draw != null) return .crosshair;
            const point = screenToPreviewUnclamped(rect, x, y);
            if (hitProcessSelection(model, process_interaction, rect, x, y, point.x, point.y)) |hit| return cursor.forProcessEdit(hit.mode);
            return if (screenToPreview(rect, x, y) != null) .crosshair else .default;
        },
        .gallery => return .default,
    }
}

fn handleScanShortcutEvent(
    interaction: *ScanSelectionInteraction,
    model: *cerealgrain.native_ui.State,
    event: c.SDL_Event,
    editing_widget_active: bool,
) void {
    if (model.active_view != .scan or event.type != c.SDL_EVENT_KEY_DOWN or editing_widget_active) return;
    switch (event.key.key) {
        c.SDLK_ESCAPE, c.SDLK_DELETE => {
            model.scan_controls.selection = null;
            interaction.end();
        },
        else => {},
    }
}

fn handleGalleryImageEvent(
    transform: *GalleryViewTransform,
    model: *const cerealgrain.native_ui.State,
    event: c.SDL_Event,
) void {
    if (model.active_view != .gallery or model.currentGalleryFileName() == null) return;
    switch (event.type) {
        c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => transform.requestFit(),
        c.SDL_EVENT_MOUSE_WHEEL => {
            const x = @as(f64, @floatCast(event.wheel.mouse_x));
            const y = @as(f64, @floatCast(event.wheel.mouse_y));
            if (pointInUiChrome(x, y)) return;
            var wheel_y = event.wheel.y;
            if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) wheel_y = -wheel_y;
            transform.zoomAt(x, y, wheelZoomFactor(wheel_y, 1.1));
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const x = @as(f64, @floatCast(event.button.x));
            const y = @as(f64, @floatCast(event.button.y));
            if (pointInUiChrome(x, y)) return;
            if (event.button.clicks >= 2) {
                transform.requestFit();
            } else if (event.button.button == c.SDL_BUTTON_MIDDLE) {
                transform.beginPan(x, y, event.button.button);
            } else if (event.button.button == c.SDL_BUTTON_LEFT and transform.scale > 1.01) {
                transform.beginPan(x, y, event.button.button);
            }
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            transform.updatePan(
                @as(f64, @floatCast(event.motion.x)),
                @as(f64, @floatCast(event.motion.y)),
            );
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (event.button.button == c.SDL_BUTTON_MIDDLE or event.button.button == c.SDL_BUTTON_LEFT) {
                transform.endPan(event.button.button);
            }
        },
        else => {},
    }
}

fn handleGalleryShortcutEvent(
    model: *cerealgrain.native_ui.State,
    transform: *GalleryViewTransform,
    confirmation: *GalleryConfirmation,
    allocator: std.mem.Allocator,
    io: std.Io,
    event: c.SDL_Event,
    last_refresh_ms: *u64,
) !void {
    if (model.active_view != .gallery) return;
    switch (event.type) {
        c.SDL_EVENT_KEY_DOWN => {
            switch (event.key.key) {
                c.SDLK_LEFT => {
                    _ = try model.switchPreviousGalleryImage();
                    transform.requestFit();
                },
                c.SDLK_RIGHT => {
                    _ = try model.switchNextGalleryImage();
                    transform.requestFit();
                },
                c.SDLK_DELETE, c.SDLK_BACKSPACE => {
                    try requestGalleryConfirmation(model, confirmation, allocator, .trash);
                    last_refresh_ms.* = c.SDL_GetTicks();
                },
                else => {},
            }
        },
        c.SDL_EVENT_WINDOW_FOCUS_GAINED => {
            if (try model.refreshGalleryFilesIfChanged(allocator, io)) {
                transform.requestFit();
            }
            last_refresh_ms.* = c.SDL_GetTicks();
        },
        else => {},
    }
}

fn handleProcessSelectionEvent(
    interaction: *ProcessSelectionInteraction,
    transform: *cerealgrain.native_ui.ProcessViewTransform,
    model: *cerealgrain.native_ui.State,
    ui: *ProcessUiState,
    renderer: *c.SDL_Renderer,
    process_worker: *ProcessWorker,
    config_path: []const u8,
    event: c.SDL_Event,
) void {
    if (model.active_view != .process) {
        interaction.end();
        transform.panning = false;
        return;
    }
    if (process_worker.blocksSelectionEdits() or !model.processPreviewInteractionReady()) {
        interaction.end();
        transform.panning = false;
        return;
    }
    const image_rect = processImageRect(renderer, model, transform) orelse return;
    switch (event.type) {
        c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => transform.requestFit(),
        c.SDL_EVENT_MOUSE_WHEEL => {
            const screen_x = @as(f64, @floatCast(event.wheel.mouse_x));
            const screen_y = @as(f64, @floatCast(event.wheel.mouse_y));
            if (pointInUiChrome(screen_x, screen_y)) return;
            var wheel_y = event.wheel.y;
            if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) wheel_y = -wheel_y;
            transform.zoomAt(screen_x, screen_y, wheelZoomFactor(wheel_y, 1.1));
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const screen_x = @as(f64, @floatCast(event.button.x));
            const screen_y = @as(f64, @floatCast(event.button.y));
            if (pointInUiChrome(screen_x, screen_y)) return;
            if (event.button.button == c.SDL_BUTTON_MIDDLE) {
                transform.beginPan(screen_x, screen_y, event.button.button);
                return;
            }
            if (event.button.button != c.SDL_BUTTON_LEFT) return;
            const preview_point = screenToPreviewUnclamped(image_rect, screen_x, screen_y);
            if (hitProcessSelection(model, interaction, image_rect, screen_x, screen_y, preview_point.x, preview_point.y)) |hit| {
                interaction.pending_draw = null;
                switch (hit.target) {
                    .frame => {
                        const index = hit.index orelse return;
                        model.process_active_selection = index;
                        interaction.beginFrame(index, hit.mode, preview_point.x, preview_point.y, model.process_selections[index]);
                    },
                    .rebate => {
                        const rebate = model.process_rebate_rect orelse return;
                        model.process_active_selection = null;
                        interaction.beginRebate(hit.mode, preview_point.x, preview_point.y, rebate);
                    },
                }
            } else if (screenToPreview(image_rect, screen_x, screen_y)) |inside_preview_point| {
                if (interaction.pending_draw == .rebate) {
                    interaction.pending_draw = null;
                    model.process_active_selection = null;
                    model.process_rebate_rect = .{
                        .x = inside_preview_point.x,
                        .y = inside_preview_point.y,
                        .w = 0.0,
                        .h = 0.0,
                    };
                    interaction.beginDrawRebate(inside_preview_point.x, inside_preview_point.y);
                } else {
                    const index = model.addProcessSelection(.{
                        .x = inside_preview_point.x,
                        .y = inside_preview_point.y,
                        .w = 0.0,
                        .h = 0.0,
                        .angle = ui.last_angle,
                        .rotation = ui.last_rotation,
                    }) catch {
                        model.setStatus("Too many frame selections");
                        return;
                    };
                    interaction.beginDrawFrame(index, inside_preview_point.x, inside_preview_point.y);
                }
            }
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            const screen_x = @as(f64, @floatCast(event.motion.x));
            const screen_y = @as(f64, @floatCast(event.motion.y));
            if (transform.panning) {
                transform.updatePan(screen_x, screen_y);
                return;
            }
            const preview_point = screenToPreviewUnclamped(image_rect, screen_x, screen_y);
            const bounds = processPreviewBounds(model) orelse return;
            if (interaction.mode == .draw_rebate) {
                var rebate = processSelectionFromDraw(
                    interaction.start_x,
                    interaction.start_y,
                    preview_point.x,
                    preview_point.y,
                    null,
                    bounds,
                    0.0,
                    0,
                );
                rebate.angle = 0.0;
                model.process_rebate_rect = rebate;
                return;
            }
            if (interaction.mode == .draw_frame) {
                const index = interaction.active_index orelse return;
                if (index >= model.process_selection_count) {
                    interaction.end();
                    return;
                }
                model.process_selections[index] = processSelectionFromDraw(
                    interaction.start_x,
                    interaction.start_y,
                    preview_point.x,
                    preview_point.y,
                    selectedProcessAspect(ui),
                    bounds,
                    ui.last_angle,
                    ui.last_rotation,
                );
                return;
            }
            const dx = preview_point.x - interaction.start_x;
            const dy = preview_point.y - interaction.start_y;
            const target = interaction.active_target orelse return;
            const original = interaction.original;
            if (interaction.mode == .rotate) {
                const rotated = rotatedProcessSelection(
                    original,
                    interaction.start_pointer_angle,
                    preview_point.x,
                    preview_point.y,
                );
                applyProcessInteractionSelection(model, target, interaction.active_index, rotated);
                return;
            }
            const local_delta = if (interaction.mode == .move)
                ProcessPreviewPoint{ .x = dx, .y = dy }
            else
                previewDeltaToSelectionLocal(original.angle, dx, dy);
            const aspect = if (target == .frame) selectedProcessAspect(ui) else null;
            const adjusted = adjustedProcessSelection(
                original,
                interaction.mode,
                local_delta.x,
                local_delta.y,
                bounds.w,
                bounds.h,
                aspect,
            );
            applyProcessInteractionSelection(model, target, interaction.active_index, adjusted);
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (event.button.button == c.SDL_BUTTON_MIDDLE) {
                transform.endPan(event.button.button);
                return;
            }
            if (event.button.button == c.SDL_BUTTON_LEFT) {
                if (interaction.mode == .draw_frame) {
                    if (interaction.active_index) |index| {
                        const result = model.finalizeProcessDrawnFrame(index);
                        if (result == .accepted) updateProcessUiLastSelection(ui, model.process_selections[index]);
                    }
                } else if (interaction.mode == .draw_rebate) {
                    if (model.process_rebate_rect) |rebate| {
                        finalizeProcessRebate(model, process_worker, config_path, rebate);
                    }
                } else if (interaction.active_target) |target| {
                    switch (target) {
                        .frame => if (interaction.active_index) |index| {
                            if (index < model.process_selection_count) updateProcessUiLastSelection(ui, model.process_selections[index]);
                            model.setStatus("Selection adjusted");
                        },
                        .rebate => if (model.process_rebate_rect) |rebate| {
                            finalizeProcessRebate(model, process_worker, config_path, rebate);
                        },
                    }
                }
                interaction.end();
            }
        },
        else => {},
    }
}

fn handleProcessShortcutEvent(
    interaction: *ProcessSelectionInteraction,
    model: *cerealgrain.native_ui.State,
    event: c.SDL_Event,
    editing_widget_active: bool,
) void {
    if (model.active_view != .process or event.type != c.SDL_EVENT_KEY_DOWN or editing_widget_active) return;
    switch (event.key.key) {
        c.SDLK_DELETE, c.SDLK_BACKSPACE => {
            if (model.process_active_selection) |index| {
                if (model.removeProcessSelection(index)) interaction.end();
            }
        },
        c.SDLK_Z => {
            if ((event.key.mod & (c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL)) != 0 and model.undoProcessSelections()) interaction.end();
        },
        else => {},
    }
}

fn finalizeProcessRebate(
    model: *cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    config_path: []const u8,
    rebate: cerealgrain.native_ui.ProcessSelection,
) void {
    const accepted = model.setProcessRebatePreviewRect(rebate) catch |err| {
        setProcessUiError(model, err);
        return;
    };
    if (!accepted) return;
    // Measure the latest box once the worker is free rather than drop it.
    if (process_worker.isRunning()) {
        model.process_rebate_dmin_pending = true;
        model.setStatus("Rebate moved; Dmin is measured when the current processing finishes");
        return;
    }
    startProcessRebate(model, process_worker, config_path) catch |err| setProcessUiError(model, err);
}

fn selectedProcessAspect(ui: *const ProcessUiState) ?f64 {
    const index = @min(ui.aspect_index, process_aspect_options.len - 1);
    return process_aspect_options[index].ratio;
}

fn processSelectionFromDraw(
    start_x: f64,
    start_y: f64,
    current_x: f64,
    current_y: f64,
    aspect: ?f64,
    bounds: ProcessPreviewBounds,
    angle: f64,
    rotation: i32,
) cerealgrain.native_ui.ProcessSelection {
    const width = current_x - start_x;
    var height = current_y - start_y;
    if (aspect) |ratio| {
        if (ratio > 0.0) {
            const sign: f64 = if (height < 0.0) -1.0 else 1.0;
            height = sign * @abs(width) / ratio;
        }
    }
    var x = if (width >= 0.0) start_x else start_x + width;
    var y = if (height >= 0.0) start_y else start_y + height;
    var w = @abs(width);
    var h = @abs(height);
    if (bounds.w > 0.0) {
        x = clampFloat(x, 0.0, bounds.w);
        w = @min(w, @max(bounds.w - x, 0.0));
    }
    if (bounds.h > 0.0) {
        y = clampFloat(y, 0.0, bounds.h);
        h = @min(h, @max(bounds.h - y, 0.0));
    }
    return .{ .x = x, .y = y, .w = w, .h = h, .angle = angle, .rotation = rotation };
}

fn applyProcessInteractionSelection(
    model: *cerealgrain.native_ui.State,
    target: ProcessSelectionTarget,
    index: ?usize,
    selection: cerealgrain.native_ui.ProcessSelection,
) void {
    switch (target) {
        .frame => {
            const frame_index = index orelse return;
            if (frame_index >= model.process_selection_count) return;
            model.process_selections[frame_index] = selection;
        },
        .rebate => {
            model.process_rebate_rect = selection;
        },
    }
}

fn updateProcessUiLastSelection(ui: *ProcessUiState, selection: cerealgrain.native_ui.ProcessSelection) void {
    ui.last_angle = selection.angle;
    ui.last_w = selection.w;
    ui.last_h = selection.h;
    ui.last_rotation = selection.rotation;
}

fn syncProcessExportBasename(ui: *ProcessUiState, model: *const cerealgrain.native_ui.State) void {
    const source = model.processing.input_path;
    if (source.len == 0) {
        if (ui.export_basename_source_len != 0) {
            ui.export_basename_source_len = 0;
            ui.setExportBasename("");
        }
        return;
    }
    const current_source = ui.export_basename_source_buffer[0..ui.export_basename_source_len];
    if (std.mem.eql(u8, current_source, source)) return;

    const copy_len = @min(source.len, ui.export_basename_source_buffer.len);
    @memcpy(ui.export_basename_source_buffer[0..copy_len], source[0..copy_len]);
    ui.export_basename_source_len = copy_len;
    ui.setExportBasename(model.currentProcessingImageStem());
}

fn addProcessSelectionFromUi(
    model: *cerealgrain.native_ui.State,
    ui: *ProcessUiState,
    transform: *const cerealgrain.native_ui.ProcessViewTransform,
) !void {
    const bounds = processPreviewBounds(model) orelse return error.NoProcessImageLoaded;
    const aspect = selectedProcessAspect(ui);
    var w: f64 = undefined;
    var h: f64 = undefined;
    if (ui.last_w > 0.0 and ui.last_h > 0.0) {
        const area = ui.last_w * ui.last_h;
        if (aspect) |ratio| {
            w = @sqrt(area * ratio);
            h = w / ratio;
        } else {
            w = ui.last_w;
            h = ui.last_h;
        }
    } else {
        h = bounds.h * 0.3;
        w = h * (aspect orelse 1.5);
    }
    w = @min(w, bounds.w);
    h = @min(h, bounds.h);
    const center = transform.viewportCenterPreview(bounds.w, bounds.h);
    const cx = center.x;
    const cy = center.y;
    const selection = cerealgrain.native_ui.ProcessSelection{
        .x = clampFloat(cx - w / 2.0, 0.0, @max(bounds.w - w, 0.0)),
        .y = clampFloat(cy - h / 2.0, 0.0, @max(bounds.h - h, 0.0)),
        .w = w,
        .h = h,
        .angle = ui.last_angle,
        .rotation = ui.last_rotation,
    };
    _ = try model.addProcessSelection(selection);
    updateProcessUiLastSelection(ui, selection);
    model.setStatus("Selection added");
}

fn processAspectIndexForValue(value: []const u8) ?usize {
    for (process_aspect_options, 0..) |option, index| {
        if (std.mem.eql(u8, option.value, value)) return index;
    }
    return null;
}

fn processAspectIndexClosestTo(value: []const u8) ?usize {
    const ratio = parseProcessAspectRatio(value) orelse return null;
    var best_index: ?usize = null;
    var best_err: f64 = std.math.inf(f64);
    for (process_aspect_options, 0..) |option, index| {
        const option_ratio = option.ratio orelse continue;
        const err = @abs(option_ratio - ratio);
        if (err < best_err) {
            best_err = err;
            best_index = index;
        }
    }
    if (best_err < 0.05) return best_index;
    return 0;
}

fn parseProcessAspectRatio(value: []const u8) ?f64 {
    const separator = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    const a = std.fmt.parseFloat(f64, value[0..separator]) catch return null;
    const b = std.fmt.parseFloat(f64, value[separator + 1 ..]) catch return null;
    if (b == 0.0) return null;
    return a / b;
}

fn maybeRefreshGalleryFiles(
    model: *cerealgrain.native_ui.State,
    transform: *GalleryViewTransform,
    allocator: std.mem.Allocator,
    io: std.Io,
    now_ms: u64,
    last_refresh_ms: *u64,
) !bool {
    if (model.active_view != .gallery) return false;
    if (last_refresh_ms.* != 0 and now_ms >= last_refresh_ms.* and now_ms - last_refresh_ms.* < 500) return false;
    last_refresh_ms.* = now_ms;
    const changed = try model.refreshGalleryFilesIfChanged(allocator, io);
    if (changed) transform.requestFit();
    return changed;
}

fn runScanSelectionInteractionSmokeEvents(
    interaction: *ScanSelectionInteraction,
    model: *cerealgrain.native_ui.State,
    renderer: *c.SDL_Renderer,
    preview: ?PreviewBuffer,
    transform: *cerealgrain.native_ui.ProcessViewTransform,
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    const image_rect = scanImageRect(renderer, preview, transform) orelse return error.ScanInteractionSmokeFailed;
    model.scan_controls.selection = null;
    model.scan_controls.auto_selection = .{ .x = 10.0, .y = 10.0, .w = 20.0, .h = 20.0 };

    var event: c.SDL_Event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(image_rect.x + image_rect.w * 0.64);
    event.button.y = @floatCast(image_rect.y + image_rect.h * 0.66);
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(image_rect.x + image_rect.w * 0.82);
    event.motion.y = @floatCast(image_rect.y + image_rect.h * 0.84);
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);
    const drawn = model.scan_controls.selection orelse return error.ScanInteractionSmokeFailed;
    if (!drawn.isDrawable() or model.scan_controls.auto_selection == null) return error.ScanInteractionSmokeFailed;
    if (model.scanStartPlan("scans/smoke.tiff", null) == null) return error.ScanInteractionSmokeFailed;

    const cfg_dir = ".zig-cache/tmp/cerealgrain-native-scan-interaction-smoke";
    const cfg_path = ".zig-cache/tmp/cerealgrain-native-scan-interaction-smoke/scanner.toml";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, cfg_dir) catch {};
    try cwd.createDirPath(io, cfg_dir);
    if (!(try model.saveScannerConfig(allocator, io, cfg_path))) return error.ScanInteractionSmokeFailed;
    const loaded = try cerealgrain.scanner.config.loadFile(allocator, io, cfg_path);
    if (!loaded.active.sel_x_in or !loaded.active.sel_y_in or !loaded.active.sel_w_in or !loaded.active.sel_h_in) {
        return error.ScanInteractionSmokeFailed;
    }
    if (loaded.values.sel_w_in <= 0.0 or loaded.values.sel_h_in <= 0.0) return error.ScanInteractionSmokeFailed;

    const center_x = image_rect.x + (drawn.x + drawn.w / 2.0) * image_rect.scale;
    const center_y = image_rect.y + (drawn.y + drawn.h / 2.0) * image_rect.scale;
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(center_x);
    event.button.y = @floatCast(center_y);
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(center_x + 36.0);
    event.motion.y = @floatCast(center_y + 24.0);
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);
    const moved = model.scan_controls.selection orelse return error.ScanInteractionSmokeFailed;
    if (moved.x <= drawn.x or moved.y <= drawn.y) return error.ScanInteractionSmokeFailed;

    const handle_x = image_rect.x + (moved.x + moved.w) * image_rect.scale;
    const handle_y = image_rect.y + (moved.y + moved.h) * image_rect.scale;
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(handle_x);
    event.button.y = @floatCast(handle_y);
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(handle_x + 48.0);
    event.motion.y = @floatCast(handle_y + 32.0);
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);
    const resized = model.scan_controls.selection orelse return error.ScanInteractionSmokeFailed;
    if (resized.w <= moved.w or resized.h <= moved.h) return error.ScanInteractionSmokeFailed;

    event = undefined;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_ESCAPE;
    handleScanShortcutEvent(interaction, model, event, false);
    if (model.scan_controls.selection != null or model.scan_controls.auto_selection == null) {
        return error.ScanInteractionSmokeFailed;
    }
    if (!model.scan_controls.restoreAutoSelection()) return error.ScanInteractionSmokeFailed;
    if (model.scan_controls.selection == null) return error.ScanInteractionSmokeFailed;
    event = undefined;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_DELETE;
    handleScanShortcutEvent(interaction, model, event, false);
    if (model.scan_controls.selection != null or model.scan_controls.auto_selection == null) {
        return error.ScanInteractionSmokeFailed;
    }

    model.scan_controls.selection = null;
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(image_rect.x + image_rect.w * 0.92);
    event.button.y = @floatCast(image_rect.y + image_rect.h * 0.90);
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(image_rect.x + image_rect.w * 0.921);
    event.motion.y = @floatCast(image_rect.y + image_rect.h * 0.901);
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);
    if (model.scan_controls.selection != null) return error.ScanInteractionSmokeFailed;

    // Wheel zoom keeps the preview point under the cursor; middle-drag pans.
    const zoom_x = image_rect.x + image_rect.w * 0.8;
    const zoom_y = image_rect.y + image_rect.h * 0.5;
    const fitted = scanImageRect(renderer, preview, transform) orelse return error.ScanInteractionSmokeFailed;
    const anchor = screenToScanPreviewUnclamped(fitted, zoom_x, zoom_y);
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_WHEEL;
    event.wheel.mouse_x = @floatCast(zoom_x);
    event.wheel.mouse_y = @floatCast(zoom_y);
    event.wheel.y = 1.0;
    event.wheel.direction = c.SDL_MOUSEWHEEL_NORMAL;
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);
    const zoomed = scanImageRect(renderer, preview, transform) orelse return error.ScanInteractionSmokeFailed;
    if (zoomed.scale <= fitted.scale * 1.1) return error.ScanInteractionSmokeFailed;
    const anchor_after = screenToScanPreviewUnclamped(zoomed, zoom_x, zoom_y);
    if (@abs(anchor_after.x - anchor.x) > 0.01 or @abs(anchor_after.y - anchor.y) > 0.01) return error.ScanInteractionSmokeFailed;

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_MIDDLE;
    event.button.x = @floatCast(zoom_x);
    event.button.y = @floatCast(zoom_y);
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(zoom_x + 40.0);
    event.motion.y = @floatCast(zoom_y + 30.0);
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_MIDDLE;
    handleScanSelectionEvent(interaction, model, renderer, preview, transform, event);
    const panned = scanImageRect(renderer, preview, transform) orelse return error.ScanInteractionSmokeFailed;
    if (@abs(panned.x - zoomed.x - 40.0) > 0.01 or @abs(panned.y - zoomed.y - 30.0) > 0.01) return error.ScanInteractionSmokeFailed;
    if (transform.panning) return error.ScanInteractionSmokeFailed;
    transform.requestFit();
}

fn runGalleryInteractionSmokeEvents(transform: *GalleryViewTransform, model: *const cerealgrain.native_ui.State) !void {
    const start_scale = transform.scale;

    var event: c.SDL_Event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.clicks = 1;
    event.button.x = 800.0;
    event.button.y = 500.0;
    handleGalleryImageEvent(transform, model, event);
    if (transform.panning) return error.GalleryInteractionSmokeFailed;

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_WHEEL;
    event.wheel.mouse_x = 800.0;
    event.wheel.mouse_y = 500.0;
    event.wheel.y = 1.0;
    event.wheel.direction = c.SDL_MOUSEWHEEL_NORMAL;
    handleGalleryImageEvent(transform, model, event);
    if (transform.scale <= start_scale) return error.GalleryInteractionSmokeFailed;

    const zoomed_x = transform.offset_x;
    const zoomed_y = transform.offset_y;
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.clicks = 1;
    event.button.x = 800.0;
    event.button.y = 500.0;
    handleGalleryImageEvent(transform, model, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = 830.0;
    event.motion.y = 525.0;
    handleGalleryImageEvent(transform, model, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleGalleryImageEvent(transform, model, event);
    if (transform.panning or (transform.offset_x == zoomed_x and transform.offset_y == zoomed_y)) {
        return error.GalleryInteractionSmokeFailed;
    }

    const left_drag_x = transform.offset_x;
    const left_drag_y = transform.offset_y;
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_MIDDLE;
    event.button.clicks = 1;
    event.button.x = 800.0;
    event.button.y = 500.0;
    handleGalleryImageEvent(transform, model, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = 850.0;
    event.motion.y = 535.0;
    handleGalleryImageEvent(transform, model, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_MIDDLE;
    handleGalleryImageEvent(transform, model, event);
    if (transform.panning or (transform.offset_x == left_drag_x and transform.offset_y == left_drag_y)) {
        return error.GalleryInteractionSmokeFailed;
    }

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.clicks = 2;
    event.button.x = 800.0;
    event.button.y = 500.0;
    handleGalleryImageEvent(transform, model, event);
    if (!transform.needs_fit) return error.GalleryInteractionSmokeFailed;

    transform.needs_fit = false;
    event = undefined;
    event.type = c.SDL_EVENT_WINDOW_RESIZED;
    handleGalleryImageEvent(transform, model, event);
    if (!transform.needs_fit) return error.GalleryInteractionSmokeFailed;
}

fn runProcessSelectionInteractionSmokeEvents(
    interaction: *ProcessSelectionInteraction,
    transform: *cerealgrain.native_ui.ProcessViewTransform,
    model: *cerealgrain.native_ui.State,
    ui: *ProcessUiState,
    renderer: *c.SDL_Renderer,
    process_worker: *ProcessWorker,
    config_path: []const u8,
) !void {
    var image_rect = processImageRect(renderer, model, transform) orelse return error.ProcessInteractionSmokeFailed;
    const bounds = processPreviewBounds(model) orelse return error.ProcessInteractionSmokeFailed;
    const start_scale = transform.scale;
    const zoom_point = imagePointOutsideUiChrome(image_rect, 0.72, 0.55) orelse return error.ProcessInteractionSmokeFailed;
    const zoom_screen_x = zoom_point.x;
    const zoom_screen_y = zoom_point.y;
    var event: c.SDL_Event = undefined;
    event.type = c.SDL_EVENT_MOUSE_WHEEL;
    event.wheel.mouse_x = @floatCast(zoom_screen_x);
    event.wheel.mouse_y = @floatCast(zoom_screen_y);
    event.wheel.y = 1.0;
    event.wheel.direction = c.SDL_MOUSEWHEEL_NORMAL;
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);
    if (transform.scale <= start_scale) return error.ProcessInteractionSmokeFailed;

    const zoomed_offset_x = transform.offset_x;
    const zoomed_offset_y = transform.offset_y;
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_MIDDLE;
    event.button.x = @floatCast(zoom_screen_x);
    event.button.y = @floatCast(zoom_screen_y);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(zoom_screen_x + 36.0);
    event.motion.y = @floatCast(zoom_screen_y + 24.0);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_MIDDLE;
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);
    if (transform.panning or (transform.offset_x == zoomed_offset_x and transform.offset_y == zoomed_offset_y)) {
        return error.ProcessInteractionSmokeFailed;
    }

    image_rect = processImageRect(renderer, model, transform) orelse return error.ProcessInteractionSmokeFailed;
    const target_point = imagePointOutsideUiChrome(image_rect, 0.72, 0.70) orelse return error.ProcessInteractionSmokeFailed;
    const target_screen_x = target_point.x;
    const target_screen_y = target_point.y;
    const target_preview = screenToPreview(image_rect, target_screen_x, target_screen_y) orelse return error.ProcessInteractionSmokeFailed;
    const selection_w = @max(bounds.w * 0.18, @min(bounds.w * 0.25, 1.0));
    const selection_h = @max(bounds.h * 0.18, @min(bounds.h * 0.25, 1.0));
    const selection = cerealgrain.native_ui.ProcessSelection{
        .x = clampFloat(target_preview.x - selection_w / 2.0, 0.0, @max(bounds.w - selection_w, 0.0)),
        .y = clampFloat(target_preview.y - selection_h / 2.0, 0.0, @max(bounds.h - selection_h, 0.0)),
        .w = selection_w,
        .h = selection_h,
    };
    model.process_selections[0] = selection;
    model.process_selection_count = 1;
    model.process_active_selection = 0;

    const center_x = image_rect.x + (selection.x + selection.w / 2.0) * image_rect.scale;
    const center_y = image_rect.y + (selection.y + selection.h / 2.0) * image_rect.scale;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(center_x);
    event.button.y = @floatCast(center_y);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);
    if (interaction.active_index == null) return error.ProcessInteractionSmokeFailed;

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(center_x + 24.0);
    event.motion.y = @floatCast(center_y + 16.0);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);
    if (model.process_selections[0].x <= selection.x or model.process_selections[0].y <= selection.y) {
        return error.ProcessInteractionSmokeFailed;
    }

    const moved = model.process_selections[0];
    const handle_x = image_rect.x + (moved.x + moved.w) * image_rect.scale;
    const handle_y = image_rect.y + (moved.y + moved.h) * image_rect.scale;
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(handle_x);
    event.button.y = @floatCast(handle_y);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(handle_x + 30.0);
    event.motion.y = @floatCast(handle_y + 20.0);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);
    if (model.process_selections[0].w <= moved.w or model.process_selections[0].h <= moved.h) {
        return error.ProcessInteractionSmokeFailed;
    }

    const resized = model.process_selections[0];
    const rotate_handle = selectionLocalToScreen(
        image_rect,
        resized,
        resized.w / 2.0 + processRotationHandleOffsetPreview(image_rect),
        0.0,
    );
    const rotate_center = selectionLocalToScreen(image_rect, resized, 0.0, 0.0);
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(rotate_handle.x);
    event.button.y = @floatCast(rotate_handle.y);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(rotate_center.x + 60.0);
    event.motion.y = @floatCast(rotate_center.y - 60.0);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);
    if (@abs(model.process_selections[0].angle - resized.angle) <= 0.01) {
        return error.ProcessInteractionSmokeFailed;
    }

    ui.aspect_index = default_process_aspect_index;
    ui.last_w = @min(bounds.w, 1.0);
    ui.last_h = @min(bounds.h, 1.0);
    ui.last_angle = 0.0;
    const expected_add_center = transform.viewportCenterPreview(bounds.w, bounds.h);
    const add_count = model.process_selection_count;
    try addProcessSelectionFromUi(model, ui, transform);
    if (model.process_selection_count != add_count + 1) return error.ProcessInteractionSmokeFailed;
    const added = model.process_selections[add_count];
    if (@abs(added.w / added.h - (3.0 / 2.0)) > 0.01) return error.ProcessInteractionSmokeFailed;
    const added_center = processSelectionCenter(added);
    if (@abs(added_center.x - expected_add_center.x) > added.w / 2.0 + 0.01 or
        @abs(added_center.y - expected_add_center.y) > added.h / 2.0 + 0.01)
    {
        return error.ProcessInteractionSmokeFailed;
    }
    event = undefined;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_BACKSPACE;
    handleProcessShortcutEvent(interaction, model, event, true);
    if (model.process_selection_count != add_count + 1) return error.ProcessInteractionSmokeFailed;
    handleProcessShortcutEvent(interaction, model, event, false);
    if (model.process_selection_count != add_count) return error.ProcessInteractionSmokeFailed;
    model.active_view = .gallery;
    model.process_active_selection = 0;
    handleProcessShortcutEvent(interaction, model, event, false);
    if (model.process_selection_count != add_count) return error.ProcessInteractionSmokeFailed;
    model.active_view = .process;
    event.key.key = c.SDLK_DELETE;
    model.process_active_selection = 0;
    handleProcessShortcutEvent(interaction, model, event, false);
    if (add_count == 0 or model.process_selection_count != add_count - 1) return error.ProcessInteractionSmokeFailed;

    model.process_selection_count = 0;
    model.process_active_selection = null;
    interaction.end();
    interaction.rebate_active = false;
    const draw_start_x = image_rect.x + image_rect.w * 0.70;
    const draw_start_y = image_rect.y + image_rect.h * 0.12;
    const draw_end_x = image_rect.x + image_rect.w * 0.98;
    const draw_end_y = image_rect.y + image_rect.h * 0.50;
    const draw_count = model.process_selection_count;
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(draw_start_x);
    event.button.y = @floatCast(draw_start_y);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(draw_end_x);
    event.motion.y = @floatCast(draw_end_y);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);
    if (bounds.w < cerealgrain.native_ui.process_draw_frame_min_size or bounds.h < cerealgrain.native_ui.process_draw_frame_min_size) {
        if (model.process_selection_count != draw_count) return error.ProcessInteractionSmokeFailed;
        if (!std.mem.eql(u8, model.status, "Selection too small, cleared")) return error.ProcessInteractionSmokeFailed;
    } else {
        if (model.process_selection_count != draw_count + 1) return error.ProcessInteractionSmokeFailed;
        const drawn = model.process_selections[draw_count];
        if (@abs(drawn.w / drawn.h - (3.0 / 2.0)) > 0.01) return error.ProcessInteractionSmokeFailed;
        if (drawn.rotation != ui.last_rotation) return error.ProcessInteractionSmokeFailed;
    }

    model.process_selection_count = 0;
    model.process_active_selection = null;
    model.process_rebate_rect = .{ .x = 1.20, .y = 0.12, .w = 0.60, .h = 0.60 };
    interaction.rebate_active = true;
    const rebate_before = model.process_rebate_rect.?;
    const rebate_center_x = image_rect.x + (rebate_before.x + rebate_before.w / 2.0) * image_rect.scale;
    const rebate_center_y = image_rect.y + (rebate_before.y + rebate_before.h / 2.0) * image_rect.scale;
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(rebate_center_x);
    event.button.y = @floatCast(rebate_center_y);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(rebate_center_x + 20.0);
    event.motion.y = @floatCast(rebate_center_y + 10.0);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);
    if (model.process_rebate_rect.?.x <= rebate_before.x or !interaction.rebate_active) {
        return error.ProcessInteractionSmokeFailed;
    }
    interaction.end();
    interaction.rebate_active = true;

    const rebate_rot_handle = selectionLocalToScreen(
        image_rect,
        model.process_rebate_rect.?,
        model.process_rebate_rect.?.w / 2.0 + processRotationHandleOffsetPreview(image_rect),
        0.0,
    );
    const rebate_rot_center = selectionLocalToScreen(image_rect, model.process_rebate_rect.?, 0.0, 0.0);
    const rebate_angle = model.process_rebate_rect.?.angle;
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(rebate_rot_handle.x);
    event.button.y = @floatCast(rebate_rot_handle.y);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(rebate_rot_center.x + 40.0);
    event.motion.y = @floatCast(rebate_rot_center.y - 40.0);
    handleProcessSelectionEvent(interaction, transform, model, ui, renderer, process_worker, config_path, event);
    if (@abs(model.process_rebate_rect.?.angle - rebate_angle) <= 0.01) {
        return error.ProcessInteractionSmokeFailed;
    }
    interaction.end();
}

fn runGalleryShortcutRefreshSmoke(
    model: *cerealgrain.native_ui.State,
    transform: *GalleryViewTransform,
    confirmation: *GalleryConfirmation,
    allocator: std.mem.Allocator,
    io: std.Io,
    last_refresh_ms: *u64,
) !void {
    if (model.galleryInfo().image_count < 2) return error.GalleryShortcutSmokeFailed;

    var event: c.SDL_Event = undefined;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_RIGHT;
    try handleGalleryShortcutEvent(model, transform, confirmation, allocator, io, event, last_refresh_ms);
    if (model.galleryInfo().active_index != 1) return error.GalleryShortcutSmokeFailed;

    event = undefined;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_LEFT;
    try handleGalleryShortcutEvent(model, transform, confirmation, allocator, io, event, last_refresh_ms);
    if (model.galleryInfo().active_index != 0) return error.GalleryShortcutSmokeFailed;

    event = undefined;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_BACKSPACE;
    try handleGalleryShortcutEvent(model, transform, confirmation, allocator, io, event, last_refresh_ms);
    if (!confirmation.pending() or model.galleryInfo().image_count != 2) return error.GalleryShortcutSmokeFailed;
    try executeGalleryConfirmation(model, transform, confirmation, allocator, io);
    if (model.galleryInfo().image_count != 1) return error.GalleryShortcutSmokeFailed;

    const fixture = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test/fixtures/tiff/rgb-thumb-ir.tiff",
        allocator,
        .limited(128 * 1024),
    );
    defer allocator.free(fixture);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ".zig-cache/tmp/cerealgrain-native-gallery-smoke/roll_03_inv.tif", .data = fixture });

    last_refresh_ms.* = 0;
    if (!(try maybeRefreshGalleryFiles(model, transform, allocator, io, 500, last_refresh_ms))) {
        return error.GalleryShortcutSmokeFailed;
    }
    if (model.galleryInfo().image_count != 2) return error.GalleryShortcutSmokeFailed;
    if (try maybeRefreshGalleryFiles(model, transform, allocator, io, 600, last_refresh_ms)) {
        return error.GalleryShortcutSmokeFailed;
    }
}

fn runGalleryConfirmationSmoke(
    model: *cerealgrain.native_ui.State,
    transform: *GalleryViewTransform,
    confirmation: *GalleryConfirmation,
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    const initial_count = model.galleryInfo().image_count;
    if (initial_count < 2) return error.GalleryConfirmationSmokeFailed;

    try requestGalleryConfirmation(model, confirmation, allocator, .delete);
    if (!confirmation.pending() or model.galleryInfo().image_count != initial_count) {
        return error.GalleryConfirmationSmokeFailed;
    }
    confirmation.deinit(allocator);
    if (model.galleryInfo().image_count != initial_count) return error.GalleryConfirmationSmokeFailed;

    try requestGalleryConfirmation(model, confirmation, allocator, .trash);
    if (!confirmation.pending() or model.galleryInfo().image_count != initial_count) {
        return error.GalleryConfirmationSmokeFailed;
    }
    try executeGalleryConfirmation(model, transform, confirmation, allocator, io);
    if (confirmation.pending() or model.galleryInfo().image_count != initial_count - 1) {
        return error.GalleryConfirmationSmokeFailed;
    }
}

fn runProcessConfirmationSmoke(
    model: *cerealgrain.native_ui.State,
    confirmation: *ProcessConfirmation,
    allocator: std.mem.Allocator,
    io: std.Io,
    preview_size: i64,
) !void {
    const initial = model.processingNavigationInfo();
    if (initial.image_count < 2 or initial.filename.len == 0) return error.ProcessConfirmationSmokeFailed;
    const captured_name = try allocator.dupe(u8, initial.filename);
    defer allocator.free(captured_name);

    try requestProcessConfirmation(model, confirmation, allocator, .delete);
    if (!confirmation.pending() or confirmation.action != .delete) return error.ProcessConfirmationSmokeFailed;
    if (!std.mem.eql(u8, confirmation.name.?, captured_name)) return error.ProcessConfirmationSmokeFailed;
    if (model.processingNavigationInfo().image_count != initial.image_count) return error.ProcessConfirmationSmokeFailed;
    confirmation.deinit(allocator);
    model.setStatus("Cancelled");
    if (model.processingNavigationInfo().image_count != initial.image_count) return error.ProcessConfirmationSmokeFailed;

    try requestProcessConfirmation(model, confirmation, allocator, .trash);
    if (!confirmation.pending() or confirmation.action != .trash) return error.ProcessConfirmationSmokeFailed;
    try executeProcessConfirmation(model, confirmation, allocator, io, preview_size);
    const after = model.processingNavigationInfo();
    if (after.image_count != initial.image_count - 1 or confirmation.pending()) {
        return error.ProcessConfirmationSmokeFailed;
    }
    if (std.mem.eql(u8, after.filename, captured_name)) return error.ProcessConfirmationSmokeFailed;
}

fn runProcessSelectorSmoke(
    model: *cerealgrain.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    preview_size: i64,
) !void {
    const initial = model.processingNavigationInfo();
    if (initial.image_count < 2 or initial.filename.len == 0) return error.ProcessSelectorSmokeFailed;
    const initial_filename = try allocator.dupe(u8, initial.filename);
    defer allocator.free(initial_filename);

    _ = model.takeProcessAutoDetectPending();
    const selected = (try model.switchProcessingImageAfterRefresh(allocator, io, 1, preview_size)) orelse return error.ProcessSelectorSmokeFailed;
    if (selected.image_idx != 1 or selected.image_count != initial.image_count) {
        return error.ProcessSelectorSmokeFailed;
    }
    if (std.mem.eql(u8, selected.filename, initial_filename)) return error.ProcessSelectorSmokeFailed;
    if (!model.takeProcessAutoDetectPending()) return error.ProcessSelectorSmokeFailed;
    if (model.takeProcessAutoDetectPending()) return error.ProcessSelectorSmokeFailed;

    try model.rescanProcessingImages(allocator, io);
    if (model.processingNavigationInfo().image_idx != 1) return error.ProcessSelectorSmokeFailed;
    if (model.switchProcessingImageAfterRefresh(allocator, io, 99, preview_size)) |_| {
        return error.ProcessSelectorSmokeFailed;
    } else |err| {
        if (err != error.InvalidProcessImageIndex) return err;
    }
    if (!std.mem.eql(u8, model.status, "Invalid index")) return error.ProcessSelectorSmokeFailed;
}

fn runProcessExportSmoke(
    worker: *ProcessExportWorker,
    model: *cerealgrain.native_ui.State,
    ui: *ProcessUiState,
) !void {
    if (model.process_selection_count == 0) {
        model.process_selections[0] = .{ .x = 0.0, .y = 0.0, .w = 2.0, .h = 2.0, .rotation = 0 };
        model.process_selection_count = 1;
        model.process_active_selection = 0;
    }
    ui.setExportBasename("ui-smoke");
    ui.export_ir_neg = true;
    ui.export_ir_inv = false;
    ui.export_inv_only = false;
    if (!(try worker.startFromState(model, .{
        .basename = ui.exportBasename(),
        .export_ir_neg = ui.export_ir_neg,
        .export_ir_inv = ui.export_ir_inv,
        .export_inv_only = ui.export_inv_only,
    }))) return error.ProcessExportSmokeFailed;
    if (!model.process_exporting or !worker.isRunning()) return error.ProcessExportSmokeFailed;
    if (try worker.startFromState(model, .{})) return error.ProcessExportSmokeFailed;
}

const ProcessDumpSmokeWriter = struct {
    buffer: *std.array_list.Managed(u8),

    pub fn print(self: *ProcessDumpSmokeWriter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.buffer.allocator, fmt, args);
        defer self.buffer.allocator.free(text);
        try self.buffer.appendSlice(text);
    }
};

fn runProcessDumpSmoke(
    model: *cerealgrain.native_ui.State,
    allocator: std.mem.Allocator,
) !void {
    model.processing.preview_scale = 0.25;
    _ = try model.addProcessSelection(.{ .x = 1.0, .y = 2.0, .w = 30.0, .h = 20.0, .angle = 0.25, .rotation = 270 });

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = ProcessDumpSmokeWriter{ .buffer = &buffer };
    try model.dumpProcessSelectionsTo(&writer);
    if (!std.mem.eql(u8, model.status, "Dumped 1 selections to server console")) {
        return error.ProcessDumpSmokeFailed;
    }
    if (!std.mem.containsAtLeast(u8, buffer.items, 1, "=== Selections (1 frames) ===") or
        !std.mem.containsAtLeast(u8, buffer.items, 1, "preview_scale=0.2500") or
        !std.mem.containsAtLeast(u8, buffer.items, 1, "Frame 1: x=1.0 y=2.0 w=30.0 h=20.0 angle=0.2500"))
    {
        return error.ProcessDumpSmokeFailed;
    }
}

fn drawFooterStatusBar(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    export_worker: *ProcessExportWorker,
) void {
    if (c.nk_begin(ctx, "Footer Status", footerBarRect(), footerBarFlags()) != 0) {
        var text_buffer: [1024]u8 = undefined;
        layoutRow(ctx, 24.0, 1);
        drawText(ctx, footerStatusText(&text_buffer, model, process_worker, export_worker));
    }
    c.nk_end(ctx);
}

fn footerStatusText(
    buffer: []u8,
    model: *cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    export_worker: *ProcessExportWorker,
) []const u8 {
    return switch (model.active_view) {
        .scan => scanFooterStatusText(buffer, model),
        .process => processFooterStatusText(buffer, model, process_worker, export_worker),
        .gallery => galleryFooterStatusText(buffer, model),
    };
}

fn scanFooterStatusText(buffer: []u8, model: *const cerealgrain.native_ui.State) []const u8 {
    const status = model.scanStatusDisplay();
    if (model.scan_eta_seconds != null) return std.fmt.bufPrint(buffer, "Scan | {s}", .{status}) catch status;
    if (model.scanner_progress_percent) |percent| {
        return std.fmt.bufPrint(
            buffer,
            "Scan | {s} | {d}%",
            .{ status, percent },
        ) catch status;
    }
    return std.fmt.bufPrint(buffer, "Scan | {s}", .{status}) catch status;
}

fn updateWindowTitle(window: *c.SDL_Window, model: *const cerealgrain.native_ui.State, shown_eta: *?u64) void {
    const eta: ?u64 = if (model.scan_eta_seconds) |seconds| @intFromFloat(@max(seconds, 0.0)) else null;
    if (std.meta.eql(eta, shown_eta.*)) return;
    shown_eta.* = eta;
    var eta_buffer: [32]u8 = undefined;
    var title_buffer: [64]u8 = undefined;
    const title = if (eta) |seconds| blk: {
        const text = cerealgrain.native_ui.handleScanFormatEta(&eta_buffer, @floatFromInt(seconds)) catch break :blk "CerealGrain";
        break :blk std.fmt.bufPrintZ(&title_buffer, "{s} — CerealGrain", .{text}) catch "CerealGrain";
    } else "CerealGrain";
    _ = c.SDL_SetWindowTitle(window, title.ptr);
}

fn processFooterStatusText(
    buffer: []u8,
    model: *cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    export_worker: *ProcessExportWorker,
) []const u8 {
    var primary_buffer: [448]u8 = undefined;
    const primary = processFooterPrimaryStatus(&primary_buffer, model, process_worker, export_worker);
    const nav = model.processingNavigationInfo();
    const info = model.processingInfo();
    const dmin = model.processDminDisplay();
    if (nav.preview_ready) {
        return std.fmt.bufPrint(
            buffer,
            "Process | {s} | {d}/{d}: {s} | {d}x{d}px scale {d:.4} {s} | {s}",
            .{
                primary,
                nav.image_idx + 1,
                nav.image_count,
                nav.filename,
                info.full_width,
                info.full_height,
                info.preview_scale,
                if (model.processing.has_ir) "RGB+IR" else "RGB",
                dmin,
            },
        ) catch primary;
    }
    if (nav.image_count == 0) {
        return std.fmt.bufPrint(
            buffer,
            "Process | {s} | No scan TIFFs found | {s}",
            .{ primary, dmin },
        ) catch primary;
    }
    return std.fmt.bufPrint(
        buffer,
        "Process | {s} | {d}/{d}: {s} | Refresh to load preview | {s}",
        .{ primary, nav.image_idx + 1, nav.image_count, nav.filename, dmin },
    ) catch primary;
}

fn processFooterPrimaryStatus(
    buffer: []u8,
    model: *const cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    export_worker: *ProcessExportWorker,
) []const u8 {
    if (process_worker.isRunning()) return process_worker.activeStatus(buffer);
    const export_status = model.processExportStatus();
    if (export_worker.isRunning() or export_status.exporting) {
        return std.fmt.bufPrint(
            buffer,
            "Exporting... {d} written",
            .{export_status.files_written},
        ) catch "Exporting...";
    }
    if (model.processing.loading) return "Loading image...";
    if (model.status.len != 0) return model.status;
    if (model.processing.progress.len != 0) return model.processing.progress;
    return "Ready";
}

fn galleryFooterStatusText(buffer: []u8, model: *const cerealgrain.native_ui.State) []const u8 {
    const info = model.galleryInfo();
    const status = if (model.status.len == 0) "Ready" else model.status;
    if (info.image_count == 0) {
        return std.fmt.bufPrint(buffer, "Gallery | {s} | No exported frames", .{status}) catch status;
    }
    const active_index = if (info.active_index) |index| index + 1 else 0;
    return std.fmt.bufPrint(
        buffer,
        "Gallery | {s} | {d}/{d}: {s}",
        .{ status, active_index, info.image_count, info.filename },
    ) catch status;
}

fn assertFooterStatusPolicy(process_worker: *ProcessWorker, export_worker: *ProcessExportWorker) !void {
    var buffer: [1024]u8 = undefined;
    var scan_model = cerealgrain.native_ui.State{};
    scan_model.scanner.scanning = true;
    scan_model.scanner_progress_percent = 42;
    const scan_text = footerStatusText(&buffer, &scan_model, process_worker, export_worker);
    if (std.mem.indexOf(u8, scan_text, "Scan | Scanning... | 42%") == null) return error.FooterStatusPolicyMismatch;

    var process_model = cerealgrain.native_ui.State{};
    process_model.show(.process);
    process_model.setProcessingProgress("Processing 1 frame...");
    const process_text = footerStatusText(&buffer, &process_model, process_worker, export_worker);
    if (std.mem.indexOf(u8, process_text, "Process | Processing 1 frame... | No scan TIFFs found | Dmin: not set") == null) {
        return error.FooterStatusPolicyMismatch;
    }

    var gallery_model = cerealgrain.native_ui.State{};
    gallery_model.show(.gallery);
    gallery_model.setStatus("No exports found");
    const gallery_text = footerStatusText(&buffer, &gallery_model, process_worker, export_worker);
    if (std.mem.indexOf(u8, gallery_text, "Gallery | No exports found | No exported frames") == null) {
        return error.FooterStatusPolicyMismatch;
    }
}

fn drawNavigation(ctx: *c.struct_nk_context, model: *cerealgrain.native_ui.State) void {
    layoutRow(ctx, 28.0, 3);
    if (chrome.optionClicked(ctx, "Scan", model.active_view == .scan)) model.show(.scan);
    if (chrome.optionClicked(ctx, "Process", model.active_view == .process)) model.show(.process);
    if (chrome.optionClicked(ctx, "Gallery", model.active_view == .gallery)) model.show(.gallery);
}

fn drawScanView(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    io: std.Io,
    rolls: *roll_panel.RollPanel,
    preview: ?cerealgrain.native_ui_preview_worker.PreviewBuffer,
) void {
    const scanner_busy = model.scannerWorkActive();
    if (model.scanner.connection == .error_state or model.scanner.connection == .disconnected) {
        layoutRow(ctx, 30.0, 1);
        tooltip(ctx, "Connect to the scanner again, for example after turning it on or quitting another program that held it");
        if (c.nk_button_label(ctx, "Reconnect Scanner") != 0) model.requestReconnect();
    }
    if (model.scanner_capabilities) |caps| {
        layoutRow(ctx, 20.0, 1);
        c.nk_label(ctx, scannerNameZ(caps.model), c.NK_TEXT_LEFT);
        if (!caps.tested()) {
            layoutRow(ctx, 40.0, 1);
            c.nk_label_wrap(ctx, "Not yet tested with CerealGrain: please report how it goes.");
        }
    }
    rolls.draw(ctx, model, preview);
    layoutRow(ctx, 28.0, 3);
    if (scanner_busy) c.nk_widget_disable_begin(ctx);
    if (c.nk_button_label(ctx, "Preview") != 0) {
        _ = model.queuePreviewScan(roll_panel.preview_output);
    }
    if (scanner_busy) c.nk_widget_disable_end(ctx);
    var autoselect = nkBool(model.scan_controls.autoselect);
    if (c.nk_checkbox_label(ctx, "Auto-select", &autoselect) != 0) {
        model.scan_controls.autoselect = autoselect != 0;
    }
    if (model.scanRestoreAutoAvailable()) {
        if (scanner_busy) c.nk_widget_disable_begin(ctx);
        if (c.nk_button_label(ctx, "Restore Auto") != 0 and !scanner_busy) {
            _ = model.scan_controls.restoreAutoSelection();
            model.setStatus("Auto-detected area restored");
        }
        if (scanner_busy) c.nk_widget_disable_end(ctx);
    } else {
        c.nk_label(ctx, "", c.NK_TEXT_LEFT);
    }

    // With a roll open, mode and resolution changes apply to its next strips.
    const roll_open = rolls.isActive();
    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Mode", c.NK_TEXT_LEFT);
    layoutRow(ctx, 28.0, 3);
    const infrared = model.scan_controls.choices.infrared;
    if (!infrared) c.nk_widget_disable_begin(ctx);
    if (chrome.optionClicked(ctx, "RGB + IR", model.scan_controls.mode == .rgb_ir)) model.scan_controls.setMode(.rgb_ir);
    if (!infrared) c.nk_widget_disable_end(ctx);
    if (chrome.optionClicked(ctx, "RGB", model.scan_controls.mode == .rgb)) model.scan_controls.setMode(.rgb);
    if (!infrared) c.nk_widget_disable_begin(ctx);
    if (chrome.optionClicked(ctx, "IR", model.scan_controls.mode == .ir)) model.scan_controls.setMode(.ir);
    if (!infrared) c.nk_widget_disable_end(ctx);
    if (!infrared) {
        layoutRow(ctx, 40.0, 1);
        c.nk_label_wrap(ctx, "This scanner has no infrared channel, so no dust removal.");
    }

    const dpis = model.scan_controls.validDpis(model.scan_controls.mode);
    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "DPI", c.NK_TEXT_LEFT);
    layoutRow(ctx, 28.0, @as(c_int, @intCast(dpis.len)));
    for (dpis) |dpi| {
        if (chrome.optionClicked(ctx, std.mem.span(dpiLabelZ(dpi)), model.scan_controls.dpi == dpi)) {
            model.scan_controls.setDpi(dpi);
        }
    }

    if (roll_open) rolls.syncControls(model);

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Exposure", c.NK_TEXT_LEFT);
    layoutRow(ctx, 28.0, 2);
    if (chrome.optionClicked(ctx, "Linear", model.scan_controls.exposure == .linear)) model.scan_controls.exposure = .linear;
    if (chrome.optionClicked(ctx, "Affine", model.scan_controls.exposure == .affine)) model.scan_controls.exposure = .affine;

    layoutRow(ctx, 30.0, 2);
    if (!scanner_busy) {
        if (c.nk_button_label(ctx, "Scan Selection") != 0) {
            if (roll_open) {
                rolls.queueStrip(model, preview);
            } else {
                model.syncScanCounter(io);
                _ = model.queueScanStart(roll_panel.cancel_file);
            }
        }
    } else {
        if (c.nk_button_label(ctx, "Cancel") != 0) model.requestScannerCancel();
    }
    var estimate_buffer: [192]u8 = undefined;
    const estimate_text = cerealgrain.native_ui.formatScanSelectionEstimate(
        &estimate_buffer,
        model.scan_controls,
        model.scanner.info(),
    ) catch null;
    if (estimate_text) |text| {
        drawText(ctx, text);
    } else {
        c.nk_label(ctx, "No selection", c.NK_TEXT_LEFT);
    }
}

fn drawGalleryView(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    renderer: *c.SDL_Renderer,
    thumbnails: *GalleryThumbnailCache,
    confirmation: *GalleryConfirmation,
    transform: *GalleryViewTransform,
    allocator: std.mem.Allocator,
    io: std.Io,
) void {
    layoutRow(ctx, 28.0, 5);
    if (c.nk_button_label(ctx, "Refresh") != 0) {
        _ = model.refreshGalleryFiles(allocator, io) catch |err| setGalleryUiError(model, err);
    }
    if (c.nk_button_label(ctx, "Prev") != 0) {
        _ = model.switchPreviousGalleryImage() catch |err| setGalleryUiError(model, err);
    }
    if (c.nk_button_label(ctx, "Next") != 0) {
        _ = model.switchNextGalleryImage() catch |err| setGalleryUiError(model, err);
    }
    if (c.nk_button_label(ctx, "Trash") != 0) {
        requestGalleryConfirmation(model, confirmation, allocator, .trash) catch |err| setGalleryUiError(model, err);
    }
    if (c.nk_button_label(ctx, "Delete") != 0) {
        requestGalleryConfirmation(model, confirmation, allocator, .delete) catch |err| setGalleryUiError(model, err);
    }

    const info = model.galleryInfo();
    drawGalleryConfirmation(ctx, model, transform, confirmation, allocator, io);
    layoutRow(ctx, 26.0, 1);
    if (info.image_count == 0) {
        c.nk_label(ctx, "No exported frames yet", c.NK_TEXT_LEFT);
    } else {
        drawText(ctx, info.filename);
    }

    thumbnails.sync(allocator, model.processing.output_dir, info.files) catch |err| {
        setGalleryUiError(model, err);
    };
    layoutRowStatic(ctx, 76.0, 84, @intCast(@max(@as(usize, 1), @min(info.files.len, 5))));
    for (info.files, 0..) |name, index| {
        var selected = nkBool(info.active_index != null and info.active_index.? == index);
        const selected_before = selected;
        if (thumbnails.imageFor(renderer, allocator, model.processing.output_dir, name)) |image| {
            _ = c.nk_selectable_image_text(ctx, image, name.ptr, @intCast(name.len), c.NK_TEXT_CENTERED, &selected);
        } else |err| {
            setGalleryUiError(model, err);
            _ = c.nk_selectable_text(ctx, name.ptr, @intCast(name.len), c.NK_TEXT_LEFT, &selected);
        }
        if (selected != selected_before and selected != 0) {
            _ = model.showGalleryImage(index) catch |err| setGalleryUiError(model, err);
        }
    }
}

fn requestGalleryConfirmation(
    model: *cerealgrain.native_ui.State,
    confirmation: *GalleryConfirmation,
    allocator: std.mem.Allocator,
    action: GalleryConfirmAction,
) !void {
    const name = model.currentGalleryFileName() orelse {
        model.setStatus("No exports found");
        return error.NoGalleryFileSelected;
    };
    try confirmation.request(allocator, action, name);
}

fn drawGalleryConfirmation(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    transform: *GalleryViewTransform,
    confirmation: *GalleryConfirmation,
    allocator: std.mem.Allocator,
    io: std.Io,
) void {
    if (!confirmation.pending()) return;
    const action = confirmation.action.?;
    const name = confirmation.name.?;
    var message_buffer: [320]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buffer,
        "Confirm {s}: {s}",
        .{ action.verb(), name },
    ) catch "Confirm action";
    layoutRow(ctx, 24.0, 1);
    drawText(ctx, message);
    layoutRow(ctx, 28.0, 2);
    if (c.nk_button_label(ctx, "Confirm") != 0) {
        executeGalleryConfirmation(model, transform, confirmation, allocator, io) catch |err| {
            setGalleryUiError(model, err);
            confirmation.deinit(allocator);
        };
    }
    if (c.nk_button_label(ctx, "Cancel") != 0) {
        confirmation.deinit(allocator);
        model.setStatus("Cancelled");
    }
}

fn executeGalleryConfirmation(
    model: *cerealgrain.native_ui.State,
    transform: *GalleryViewTransform,
    confirmation: *GalleryConfirmation,
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    const action = confirmation.action orelse return error.NoGalleryConfirmation;
    const name = confirmation.name orelse return error.NoGalleryConfirmation;
    var mutation = switch (action) {
        .trash => try model.trashGalleryFileByName(allocator, io, name),
        .delete => try model.deleteGalleryFileByName(allocator, io, name),
    };
    mutation.deinit(allocator);
    confirmation.deinit(allocator);
    transform.requestFit();
}

fn requestProcessConfirmation(
    model: *cerealgrain.native_ui.State,
    confirmation: *ProcessConfirmation,
    allocator: std.mem.Allocator,
    action: ProcessConfirmAction,
) !void {
    const nav = model.processingNavigationInfo();
    if (nav.image_count == 0 or nav.filename.len == 0) {
        model.setStatus("No image loaded");
        return error.NoProcessImageLoaded;
    }
    try confirmation.request(allocator, action, nav.filename);
    model.setStatus("Confirm scan action");
}

fn drawProcessConfirmation(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    confirmation: *ProcessConfirmation,
    allocator: std.mem.Allocator,
    io: std.Io,
    preview_size: i64,
) void {
    const name = confirmation.name orelse return;
    const action = confirmation.action orelse return;
    var text_buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(
        &text_buffer,
        "Confirm {s}: {s}",
        .{ action.verb(), name },
    ) catch "Confirm scan action";
    layoutRow(ctx, 22.0, 1);
    drawText(ctx, text);
    layoutRow(ctx, 28.0, 2);
    if (c.nk_button_label(ctx, "Confirm") != 0) {
        executeProcessConfirmation(model, confirmation, allocator, io, preview_size) catch |err| {
            setProcessUiError(model, err);
        };
    }
    if (c.nk_button_label(ctx, "Cancel") != 0) {
        confirmation.deinit(allocator);
        model.setStatus("Cancelled");
    }
}

fn executeProcessConfirmation(
    model: *cerealgrain.native_ui.State,
    confirmation: *ProcessConfirmation,
    allocator: std.mem.Allocator,
    io: std.Io,
    preview_size: i64,
) !void {
    const action = confirmation.action orelse return error.NoProcessConfirmation;
    const name = confirmation.name orelse return error.NoProcessConfirmation;
    const current = model.processingNavigationInfo().filename;
    if (!std.mem.eql(u8, current, name)) {
        confirmation.deinit(allocator);
        model.setStatus("Scan selection changed");
        return;
    }
    _ = switch (action) {
        .trash => try model.trashCurrentProcessingImage(allocator, io, preview_size),
        .delete => try model.deleteCurrentProcessingImage(allocator, io, preview_size),
    };
    confirmation.deinit(allocator);
}

fn drawProcessView(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    ui: *ProcessUiState,
    interaction: *ProcessSelectionInteraction,
    confirmation: *ProcessConfirmation,
    process_worker: *ProcessWorker,
    export_worker: *ProcessExportWorker,
    transform: *const cerealgrain.native_ui.ProcessViewTransform,
    rolls: *roll_panel.RollPanel,
) void {
    const export_active = model.process_exporting or export_worker.isRunning();
    const worker_active = process_worker.isRunning();
    const load_active = model.processing.loading;
    const controls_enabled = !export_active and !worker_active and !load_active;
    layoutRow(ctx, 28.0, 1);
    c.nk_label(ctx, "Images", c.NK_TEXT_LEFT);
    layoutRow(ctx, 28.0, 5);
    if (!controls_enabled) {
        c.nk_label(ctx, "Refresh", c.NK_TEXT_CENTERED);
        c.nk_label(ctx, "Prev", c.NK_TEXT_CENTERED);
        c.nk_label(ctx, "Next", c.NK_TEXT_CENTERED);
        c.nk_label(ctx, "Trash", c.NK_TEXT_CENTERED);
        c.nk_label(ctx, "Delete", c.NK_TEXT_CENTERED);
    } else {
        tooltip(ctx, "Rescan the scan folder for new images");
        if (c.nk_button_label(ctx, "Refresh") != 0) {
            refreshAndLoadProcessingImage(model, process_worker, allocator, io, processingPreviewSize(ui)) catch |err| setProcessUiError(model, err);
        }
        tooltip(ctx, "Previous image");
        if (c.nk_button_label(ctx, "Prev") != 0) {
            startPreviousProcessingImage(model, process_worker, allocator, io, processingPreviewSize(ui)) catch |err| setProcessUiError(model, err);
        }
        tooltip(ctx, "Next image");
        if (c.nk_button_label(ctx, "Next") != 0) {
            startNextProcessingImage(model, process_worker, allocator, io, processingPreviewSize(ui)) catch |err| setProcessUiError(model, err);
        }
        tooltip(ctx, "Move the current scan to the trash");
        if (c.nk_button_label(ctx, "Trash") != 0) {
            requestProcessConfirmation(model, confirmation, allocator, .trash) catch |err| setProcessUiError(model, err);
        }
        tooltip(ctx, "Permanently delete the current scan");
        if (c.nk_button_label(ctx, "Delete") != 0) {
            requestProcessConfirmation(model, confirmation, allocator, .delete) catch |err| setProcessUiError(model, err);
        }
    }
    drawProcessConfirmation(ctx, model, confirmation, allocator, io, processingPreviewSize(ui));

    const nav = model.processingNavigationInfo();
    var image_text_buffer: [256]u8 = undefined;
    const image_text = if (nav.image_count == 0)
        "No scan TIFFs found"
    else
        std.fmt.bufPrint(
            &image_text_buffer,
            "{d}/{d}: {s}",
            .{ nav.image_idx + 1, nav.image_count, nav.filename },
        ) catch nav.filename;
    layoutRow(ctx, 24.0, 1);
    drawText(ctx, image_text);
    drawProcessImageSelector(ctx, model, process_worker, allocator, io, processingPreviewSize(ui), controls_enabled);

    if (load_active) c.nk_widget_disable_begin(ctx);
    defer if (load_active) c.nk_widget_disable_end(ctx);

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Preview", c.NK_TEXT_LEFT);
    layoutRow(ctx, 28.0, 2);
    const old_preview_size = ui.preview_size;
    tooltip(ctx, "Longest side of the preview image in pixels. Larger is sharper but slower to load and process");
    c.nk_property_int(ctx, "Max px", 512, &ui.preview_size, 8192, 512, 256);
    if (ui.preview_size != old_preview_size) {
        queueProcessIntSetting(model, ui, "preview_size", ui.preview_size);
    }
    var inverted = nkBool(model.processing_preview_inversion_enabled);
    tooltip(ctx, "Show the live inverted positive instead of the plain negative");
    if (c.nk_checkbox_label(ctx, "Inverted", &inverted) != 0) {
        const enabled = inverted != 0;
        model.setProcessingPreviewInversionEnabled(enabled);
        model.saveProcessingSettings(allocator, io, config_path, &.{
            .{ .name = "preview_inversion", .value = .{ .boolean = enabled } },
        }) catch |err| setProcessUiError(model, err);
    }

    drawProcessSettingsControls(ctx, model, allocator, io, config_path, ui);

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Detect", c.NK_TEXT_LEFT);
    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Aspect", c.NK_TEXT_LEFT);
    layoutRow(ctx, 24.0, 3);
    for (process_aspect_options, 0..) |option, index| {
        if (chrome.optionClicked(ctx, option.label, ui.aspect_index == index)) {
            ui.aspect_index = index;
            saveProcessStringSetting(model, allocator, io, config_path, "aspect", option.value) catch |err| setProcessUiError(model, err);
        }
    }
    layoutRow(ctx, 28.0, @intCast(process_format_labels.len));
    for (process_format_labels, 0..) |label, index| {
        tooltip(ctx, "Film format for auto-detection");
        if (chrome.optionClicked(ctx, std.mem.span(label), ui.format_index == index)) {
            ui.format_index = index;
        }
    }
    const old_scale = ui.scale_percent;
    layoutRow(ctx, 28.0, 2);
    tooltip(ctx, "Number of frames to detect. 0 lets auto-detection decide");
    c.nk_property_int(ctx, "Frames", 0, &ui.n_frames, 12, 1, 1);
    tooltip(ctx, "Scale adjustment for auto-detected frames. Positive grows frames, negative shrinks them");
    c.nk_property_float(ctx, "Scale %", -1.0, &ui.scale_percent, 1.0, 0.1, 0.05);
    if (old_scale != ui.scale_percent) {
        model.rescaleProcessAutoSelections(@floatCast(ui.scale_percent));
    }
    layoutRow(ctx, 28.0, 4);
    tooltip(ctx, "Automatically detect frame positions based on the film format");
    if (worker_active) {
        c.nk_label(ctx, "Auto Detect", c.NK_TEXT_CENTERED);
    } else if (c.nk_button_label(ctx, "Auto Detect") != 0) {
        startProcessAutoDetect(model, process_worker, config_path, ui) catch |err| setProcessUiError(model, err);
    }
    tooltip(ctx, "Remove all frame selections");
    if (c.nk_button_label(ctx, "Clear") != 0) {
        model.clearProcessingSelections();
        model.setStatus("Selections cleared");
    }
    tooltip(ctx, "Measure the film base color (Dmin) from the rebate box, used to remove the orange mask");
    if (worker_active) {
        c.nk_label(ctx, "Dmin", c.NK_TEXT_CENTERED);
    } else if (c.nk_button_label(ctx, "Dmin") != 0) {
        startProcessRebate(model, process_worker, config_path) catch |err| setProcessUiError(model, err);
    }
    tooltip(ctx, "Print the current selections to the terminal as ground truth");
    if (c.nk_button_label(ctx, "Dump") != 0) {
        model.dumpProcessSelections() catch |err| setProcessUiError(model, err);
    }
    layoutRow(ctx, 28.0, 2);
    if (c.nk_button_label(ctx, "+ New selection") != 0) {
        addProcessSelectionFromUi(model, ui, transform) catch |err| setProcessUiError(model, err);
    }
    tooltip(ctx, "Select an area of unexposed film (the orange strip between frames or at the edge of the strip) to calibrate base color removal");
    if (c.nk_button_label(ctx, "Set rebate") != 0) {
        interaction.pending_draw = .rebate;
        interaction.rebate_active = true;
        model.process_active_selection = null;
        model.setStatus("Click and drag over unexposed film edge");
    }

    var selection_text_buffer: [128]u8 = undefined;
    const selection_text = std.fmt.bufPrint(
        &selection_text_buffer,
        "{d} frame selection{s}",
        .{ model.process_selection_count, if (model.process_selection_count == 1) "" else "s" },
    ) catch "Selections";
    layoutRow(ctx, 22.0, 1);
    drawText(ctx, selection_text);
    drawProcessUndo(ctx, model);
    drawProcessSelectionControls(ctx, model, ui);

    syncProcessExportBasename(ui, model);
    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Export", c.NK_TEXT_LEFT);
    // A strip of the open roll exports through the roll: its names, and the
    // frames are kept as the strip's framing for later re-exports.
    const image_path = model.currentProcessingImagePathForWorker();
    if (if (image_path) |path| rolls.stripNumberOf(path) else null) |strip_number| {
        var name_buffer: [96]u8 = undefined;
        var note_buffer: [192]u8 = undefined;
        const note = if (model.process_saved_framing != null)
            std.fmt.bufPrint(&note_buffer, "Your frames for this strip are saved. Export Strip Frames re-exports them as {s}_NN.tif.", .{rolls.stripExportName(&name_buffer, strip_number)}) catch ""
        else
            std.fmt.bufPrint(&note_buffer, "Edits save automatically. Export Strip Frames re-exports this strip as {s}_NN.tif.", .{rolls.stripExportName(&name_buffer, strip_number)}) catch "";
        layoutRow(ctx, 22.0, 1);
        drawText(ctx, note);
        layoutRow(ctx, 30.0, 1);
        if (export_active) {
            c.nk_label(ctx, "Exporting...", c.NK_TEXT_LEFT);
        } else if (c.nk_button_label(ctx, "Export Strip Frames") != 0) {
            rolls.exportFramedStrip(model, image_path.?) catch |err| setProcessUiError(model, err);
        }
        return;
    }
    layoutRow(ctx, 28.0, 1);
    _ = c.nk_edit_string(
        ctx,
        c.NK_EDIT_FIELD,
        &ui.export_basename_buffer,
        &ui.export_basename_len,
        @intCast(ui.export_basename_buffer.len),
        c.nk_filter_default,
    );
    layoutRow(ctx, 28.0, 3);
    drawProcessExportVariant(ctx, model, allocator, io, config_path, "IR neg", "export_ir_neg", &ui.export_ir_neg, "Export the IR-cleaned negative (dust and scratch removal only)");
    drawProcessExportVariant(ctx, model, allocator, io, config_path, "IR inv", "export_ir_inv", &ui.export_ir_inv, "Export the inverted positive, with IR cleaning and color inversion");
    drawProcessExportVariant(ctx, model, allocator, io, config_path, "Inv only", "export_inv_only", &ui.export_inv_only, "Export the inverted positive without IR cleaning");
    layoutRow(ctx, 30.0, 1);
    if (export_active) {
        c.nk_label(ctx, "Exporting...", c.NK_TEXT_LEFT);
    } else if (c.nk_button_label(ctx, "Export Selected") != 0) {
        runProcessExport(model, export_worker, ui) catch |err| setProcessUiError(model, err);
    }
}

fn drawProcessImageSelector(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    allocator: std.mem.Allocator,
    io: std.Io,
    preview_size: i64,
    enabled: bool,
) void {
    const count = model.processing_images.paths.len;
    if (count == 0) return;

    layoutRow(ctx, 22.0, 1);
    c.nk_label(ctx, "Image selector", c.NK_TEXT_LEFT);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const path = model.processing_images.paths[index];
        const name = std.fs.path.basename(path);
        var label_buffer: [256]u8 = undefined;
        const label = std.fmt.bufPrint(
            &label_buffer,
            "{d}/{d}: {s}",
            .{ index + 1, count, name },
        ) catch name;

        layoutRow(ctx, 24.0, 1);
        if (!enabled) {
            drawText(ctx, label);
            continue;
        }
        var selected = nkBool(index == model.processing.image_idx);
        if (c.nk_selectable_text(ctx, label.ptr, @intCast(label.len), c.NK_TEXT_LEFT, &selected) != 0 and
            selected != 0 and index != model.processing.image_idx)
        {
            startProcessingImageAfterRefresh(model, process_worker, allocator, io, index, preview_size) catch |err| {
                setProcessUiError(model, err);
                return;
            };
            return;
        }
    }
}

fn drawProcessUndo(ctx: *c.struct_nk_context, model: *cerealgrain.native_ui.State) void {
    const can_undo = model.canUndoProcessSelections();
    layoutRow(ctx, 28.0, 1);
    if (!can_undo) c.nk_widget_disable_begin(ctx);
    tooltip(ctx, "Restore the frames from before the last change or auto-detect (Cmd+Z)");
    if (c.nk_button_label(ctx, if (can_undo) "Undo Frames" else "Undo Frames (nothing to undo yet)") != 0 and can_undo) {
        _ = model.undoProcessSelections();
    }
    if (!can_undo) c.nk_widget_disable_end(ctx);
}

fn drawProcessSelectionControls(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    ui: *ProcessUiState,
) void {
    if (model.process_selection_count == 0) return;

    var index: usize = 0;
    while (index < model.process_selection_count) : (index += 1) {
        var label_buffer: [48]u8 = undefined;
        const selection = model.process_selections[index];
        const active = if (model.process_active_selection) |active_index| active_index == index else false;
        const label = std.fmt.bufPrint(
            &label_buffer,
            "#{d}: {d}x{d}",
            .{
                index + 1,
                @as(i64, @intFromFloat(@round(selection.w / @max(model.processing.preview_scale, 0.000001)))),
                @as(i64, @intFromFloat(@round(selection.h / @max(model.processing.preview_scale, 0.000001)))),
            },
        ) catch "#";
        layoutRow(ctx, 24.0, 3);
        var selected = nkBool(active);
        if (c.nk_selectable_text(ctx, label.ptr, @intCast(label.len), c.NK_TEXT_LEFT, &selected) != 0) {
            model.process_active_selection = index;
        }
        if (c.nk_button_label(ctx, "Delete") != 0) {
            _ = model.removeProcessSelection(index);
            model.setStatus("Selection removed");
            break;
        }
        c.nk_label(ctx, "Rotate", c.NK_TEXT_LEFT);
        layoutRow(ctx, 24.0, 4);
        const rotations = [_]i32{ 0, 90, 180, 270 };
        const labels = [_][*:0]const u8{ "0", "90", "180", "270" };
        for (rotations, labels) |rotation, rotation_label| {
            if (chrome.optionClicked(ctx, std.mem.span(rotation_label), selection.rotation == rotation)) {
                model.process_selections[index].rotation = rotation;
                ui.last_rotation = rotation;
            }
        }
    }
}

fn drawProcessSettingsControls(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    ui: *ProcessUiState,
) void {
    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Film Stock", c.NK_TEXT_LEFT);
    drawProcessStockControls(ctx, model, allocator, io, config_path, ui);

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Render", c.NK_TEXT_LEFT);
    drawFloatSetting(ctx, model, ui, "Contrast", "render_contrast", &ui.render_contrast, 1.0, 3.0, 0.05, "Contrast of the display curve through 18% grey. 1 is gentle; higher values deepen shadows and brighten highlights. The film's own contrast is kept, so a hazy scene stays soft");
    drawFloatSetting(ctx, model, ui, "Crosstalk", "dye_crosstalk", &ui.dye_crosstalk, 0.0, 0.5, 0.02, "Dye crosstalk to undo: the scan sees each dye partly through the others, which mutes colour. Higher values restore more colour; 0 leaves the scan's colour as it is");
    drawFloatSetting(ctx, model, ui, "Black %", "render_percentile_lo", &ui.render_percentile_lo, 0.0, 5.0, 0.1, "Percentile of each channel used as its black point for automatic white balance. Higher values ignore more dark outliers");
    drawFloatSetting(ctx, model, ui, "White %", "render_percentile_hi", &ui.render_percentile_hi, 95.0, 100.0, 0.1, "Percentile of each channel used as its white point for automatic white balance. Lower values ignore more bright outliers such as specular highlights");
    drawFloatSetting(ctx, model, ui, "Exposure", "exposure_compensation", &ui.exposure_compensation, -3.0, 3.0, 0.1, "Exposure in stops on top of automatic exposure, which puts the frame's average brightness at 18% grey. Positive values brighten");

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Color Balance", c.NK_TEXT_LEFT);
    drawFloatSetting(ctx, model, ui, "Auto WB", "auto_white_balance", &ui.auto_white_balance, 0.0, 1.0, 0.05, "Automatic white balance for each frame: gives every channel its own black and white point so neutral shadows and highlights come out neutral. 1 = full, 0 = off (for scenes whose darkest and brightest parts are not neutral, like sunsets). Temp and tint adjust on top");
    drawColorPad(ctx, model, ui);
    drawFloatSetting(ctx, model, ui, "Temp", "color_temp", &ui.color_temp, -1.0, 1.0, 0.05, "Color temperature, from blue to yellow. 0 is neutral. Same as the horizontal axis of the pad above");
    drawFloatSetting(ctx, model, ui, "Tint", "color_tint", &ui.color_tint, -1.0, 1.0, 0.05, "Tint, from green to magenta. 0 is neutral. Same as the vertical axis of the pad above");
    layoutRow(ctx, 26.0, 1);
    tooltip(ctx, "Set temperature and tint back to neutral and automatic white balance back to full");
    if (c.nk_button_label(ctx, "Reset Color") != 0) {
        ui.color_temp = 0.0;
        ui.color_tint = 0.0;
        ui.auto_white_balance = 1.0;
        queueProcessFloatSetting(model, ui, "color_temp", ui.color_temp);
        queueProcessFloatSetting(model, ui, "color_tint", ui.color_tint);
        queueProcessFloatSetting(model, ui, "auto_white_balance", ui.auto_white_balance);
        commitPendingProcessSettings(model, allocator, io, config_path, ui) catch |err| setProcessUiError(model, err);
    }

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Dust & Scratch", c.NK_TEXT_LEFT);
    drawFloatSetting(ctx, model, ui, "IR thresh", "ir_threshold", &ui.ir_threshold, 0.02, 0.50, 0.01, "How far below the local background a pixel must be to count as a defect. Lower values detect fainter dust but may flag film grain. Higher values only catch obvious defects");
    drawFloatSetting(ctx, model, ui, "Hair sens", "ir_hair_sensitivity", &ui.ir_hair_sensitivity, 0.02, 0.30, 0.01, "Meijering ridge filter threshold for detecting thin linear features like hairs and scratches. Lower values catch finer or fainter hairs but may produce false positives on textured areas");
    drawIntSetting(ctx, model, ui, "Dilate", "ir_dilate_radius", &ui.ir_dilate_radius, 0, 10, 1, "Expand detected defect regions by this many pixels, so the inpainter covers the full extent of each defect including soft edges");
    drawIntSetting(ctx, model, ui, "Close", "ir_close_radius", &ui.ir_close_radius, 0, 15, 1, "Morphological close radius. Fills small gaps within partially detected large defects, joining nearby detected regions into a single defect");
    drawIntSetting(ctx, model, ui, "Min area", "ir_min_area", &ui.ir_min_area, 1, 20, 1, "Detected regions smaller than this many pixels are discarded as noise. Increase to ignore tiny specks, decrease to catch very small dust");
    drawFloatSetting(ctx, model, ui, "Max cov", "ir_max_coverage", &ui.ir_max_coverage, 0.005, 0.10, 0.005, "Safety limit: if more than this fraction of the image is flagged as defects, detection is assumed to be wrong and no cleaning is done. Prevents damaging the image when thresholds are too aggressive");
    drawIntSetting(ctx, model, ui, "Padding", "inpaint_padding", &ui.inpaint_padding, 4, 48, 2, "How many pixels of clean context to include around each defect when inpainting. More padding gives better reconstruction but is slower for large defects");
    if (processSettingsCommitReady(ctx)) {
        commitPendingProcessSettings(model, allocator, io, config_path, ui) catch |err| setProcessUiError(model, err);
    }
}

fn drawProcessStockControls(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    ui: *ProcessUiState,
) void {
    var stock_buffer: [16]cerealgrain.native_ui.ProcessStockChoice = undefined;
    const info = model.processingStocksInfo(&stock_buffer) catch return;
    const active = info.active orelse "";
    layoutRow(ctx, 24.0, 1);
    if (chrome.optionClicked(ctx, "(none)", active.len == 0)) {
        selectProcessStock(model, allocator, io, config_path, ui, "") catch |err| setProcessUiError(model, err);
    }
    for (info.stocks) |stock| {
        layoutRow(ctx, 24.0, 1);
        const selected = std.mem.eql(u8, active, stock.name);
        tooltip(ctx, if (stock.description.len != 0) stock.description else stock.name);
        if (chrome.optionClicked(ctx, stock.name, selected)) {
            selectProcessStock(model, allocator, io, config_path, ui, stock.name) catch |err| setProcessUiError(model, err);
        }
    }
}

fn drawColorPad(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    ui: *ProcessUiState,
) void {
    layoutRow(ctx, 88.0, 1);
    tooltip(ctx, "Drag the point to adjust color balance. Horizontal: temperature, blue to yellow. Vertical: tint, green to magenta. The center is neutral");
    var bounds: c.struct_nk_rect = undefined;
    if (c.nk_widget(&bounds, ctx) == c.NK_WIDGET_INVALID) return;

    const canvas = c.nk_window_get_canvas(ctx);
    c.nk_fill_rect_multi_color(
        canvas,
        bounds,
        c.nk_rgb(60, 95, 170),
        c.nk_rgb(70, 150, 80),
        c.nk_rgb(195, 170, 55),
        c.nk_rgb(170, 75, 165),
    );
    c.nk_stroke_rect(canvas, bounds, 2.0, 1.0, c.nk_rgb(85, 88, 96));
    c.nk_stroke_rect(
        canvas,
        c.nk_rect(bounds.x + bounds.w * 0.5, bounds.y, 1.0, bounds.h),
        0.0,
        1.0,
        c.nk_rgb(210, 210, 210),
    );
    c.nk_stroke_rect(
        canvas,
        c.nk_rect(bounds.x, bounds.y + bounds.h * 0.5, bounds.w, 1.0),
        0.0,
        1.0,
        c.nk_rgb(210, 210, 210),
    );

    const dot_x = bounds.x + ((ui.color_temp + 1.0) * 0.5) * bounds.w;
    const dot_y = bounds.y + ((ui.color_tint + 1.0) * 0.5) * bounds.h;
    const dot_radius = chrome.runtime_ui_config.metrics().color_dot_radius;
    c.nk_fill_circle(canvas, c.nk_rect(dot_x - dot_radius, dot_y - dot_radius, dot_radius * 2.0, dot_radius * 2.0), c.nk_rgb(245, 245, 245));
    c.nk_stroke_circle(canvas, c.nk_rect(dot_x - dot_radius, dot_y - dot_radius, dot_radius * 2.0, dot_radius * 2.0), 1.0, c.nk_rgb(20, 20, 24));

    const input = &ctx.*.input;
    const in_bounds = c.nk_input_is_mouse_hovering_rect(input, bounds) != 0;
    const dragging = c.nk_input_is_mouse_down(input, c.NK_BUTTON_LEFT) != 0;
    if (in_bounds and dragging) {
        const before_temp = ui.color_temp;
        const before_tint = ui.color_tint;
        const mx = @min(bounds.x + bounds.w, @max(bounds.x, input.mouse.pos.x));
        const my = @min(bounds.y + bounds.h, @max(bounds.y, input.mouse.pos.y));
        ui.color_temp = ((mx - bounds.x) / bounds.w) * 2.0 - 1.0;
        ui.color_tint = ((my - bounds.y) / bounds.h) * 2.0 - 1.0;
        if (@abs(ui.color_temp - before_temp) > 0.000001 or @abs(ui.color_tint - before_tint) > 0.000001) {
            queueProcessFloatSetting(model, ui, "color_temp", ui.color_temp);
            queueProcessFloatSetting(model, ui, "color_tint", ui.color_tint);
        }
    }
}

fn drawFloatSetting(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    ui: *ProcessUiState,
    label: [*:0]const u8,
    name: []const u8,
    value: *f32,
    min: f32,
    max: f32,
    step: f32,
    help: []const u8,
) void {
    const before = value.*;
    layoutRow(ctx, 26.0, 1);
    tooltip(ctx, help);
    c.nk_property_float(ctx, label, min, value, max, step, step * 0.25);
    if (@abs(value.* - before) > 0.000001) {
        queueProcessFloatSetting(model, ui, name, value.*);
    }
}

fn drawIntSetting(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    ui: *ProcessUiState,
    label: [*:0]const u8,
    name: []const u8,
    value: *c_int,
    min: c_int,
    max: c_int,
    step: c_int,
    help: []const u8,
) void {
    const before = value.*;
    layoutRow(ctx, 26.0, 1);
    tooltip(ctx, help);
    c.nk_property_int(ctx, label, min, value, max, step, @floatFromInt(step));
    if (value.* != before) {
        queueProcessIntSetting(model, ui, name, value.*);
    }
}

fn ensureProcessImageLoaded(
    model: *cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    allocator: std.mem.Allocator,
    io: std.Io,
    preview_size: i64,
) !void {
    if (model.processing_preview != null) return;
    if (process_worker.isRunning()) return;
    try refreshAndLoadProcessingImage(model, process_worker, allocator, io, preview_size);
}

fn refreshAndLoadProcessingImage(
    model: *cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    allocator: std.mem.Allocator,
    io: std.Io,
    preview_size: i64,
) !void {
    _ = try model.refreshProcessingImageList(allocator, io);
    if (model.processing.image_count == 0) return;
    const index = if (model.processing.image_idx < model.processing.image_count) model.processing.image_idx else 0;
    _ = try process_worker.startLoadIndex(model, index, preview_size);
}

fn startPreviousProcessingImage(
    model: *cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    allocator: std.mem.Allocator,
    io: std.Io,
    preview_size: i64,
) !void {
    _ = try model.refreshProcessingImageList(allocator, io);
    const count = model.processing_images.paths.len;
    if (count == 0) {
        model.setStatus("No images");
        return;
    }
    const index = if (model.processing.image_idx > 0) model.processing.image_idx - 1 else count - 1;
    _ = try process_worker.startLoadIndex(model, index, preview_size);
}

fn startNextProcessingImage(
    model: *cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    allocator: std.mem.Allocator,
    io: std.Io,
    preview_size: i64,
) !void {
    _ = try model.refreshProcessingImageList(allocator, io);
    const count = model.processing_images.paths.len;
    if (count == 0) {
        model.setStatus("No images");
        return;
    }
    const index = if (model.processing.image_idx < count - 1) model.processing.image_idx + 1 else 0;
    _ = try process_worker.startLoadIndex(model, index, preview_size);
}

fn startProcessingImageAfterRefresh(
    model: *cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    allocator: std.mem.Allocator,
    io: std.Io,
    selected_index: usize,
    preview_size: i64,
) !void {
    const refreshed_index = (try model.processingImageIndexAfterRefresh(allocator, io, selected_index)) orelse return;
    if (model.processing_preview != null and refreshed_index == model.processing.image_idx) return;
    _ = try process_worker.startLoadIndex(model, refreshed_index, preview_size);
}

fn syncProcessUiFromConfig(ui: *ProcessUiState, model: *const cerealgrain.native_ui.State) void {
    ui.preview_size = processSettingInt(model, "preview_size");
    ui.render_contrast = processSettingFloat(model, "render_contrast");
    ui.dye_crosstalk = processSettingFloat(model, "dye_crosstalk");
    ui.render_percentile_lo = processSettingFloat(model, "render_percentile_lo");
    ui.render_percentile_hi = processSettingFloat(model, "render_percentile_hi");
    ui.exposure_compensation = processSettingFloat(model, "exposure_compensation");
    ui.color_temp = processSettingFloat(model, "color_temp");
    ui.color_tint = processSettingFloat(model, "color_tint");
    ui.auto_white_balance = processSettingFloat(model, "auto_white_balance");
    ui.ir_threshold = processSettingFloat(model, "ir_threshold");
    ui.ir_hair_sensitivity = processSettingFloat(model, "ir_hair_sensitivity");
    ui.ir_dilate_radius = processSettingInt(model, "ir_dilate_radius");
    ui.ir_close_radius = processSettingInt(model, "ir_close_radius");
    ui.ir_min_area = processSettingInt(model, "ir_min_area");
    ui.ir_max_coverage = processSettingFloat(model, "ir_max_coverage");
    ui.inpaint_padding = processSettingInt(model, "inpaint_padding");
    ui.export_ir_neg = processSettingBool(model, "export_ir_neg", ui.export_ir_neg);
    ui.export_ir_inv = processSettingBool(model, "export_ir_inv", ui.export_ir_inv);
    ui.export_inv_only = processSettingBool(model, "export_inv_only", ui.export_inv_only);
    if (processSettingString(model, "aspect")) |aspect| {
        ui.aspect_index = processAspectIndexForValue(aspect) orelse default_process_aspect_index;
    }
}

fn processSettingFloat(model: *const cerealgrain.native_ui.State, name: []const u8) f32 {
    if (model.processing_config.value(name)) |value| return @floatCast(value.asFloat());
    if (cerealgrain.processing.config.defaultValue(name)) |value| return @floatCast(value.asFloat());
    return 0.0;
}

fn processSettingInt(model: *const cerealgrain.native_ui.State, name: []const u8) c_int {
    if (model.processing_config.value(name)) |value| return @intFromFloat(@round(value.asFloat()));
    if (cerealgrain.processing.config.defaultValue(name)) |value| return @intFromFloat(@round(value.asFloat()));
    return 0;
}

fn processSettingBool(model: *const cerealgrain.native_ui.State, name: []const u8, fallback: bool) bool {
    const value = model.processing_config.value(name) orelse return fallback;
    return switch (value) {
        .boolean => |boolean| boolean,
        else => fallback,
    };
}

fn processSettingString(model: *const cerealgrain.native_ui.State, name: []const u8) ?[]const u8 {
    const entry = model.processing_config.entry(name) orelse return null;
    return switch (entry.value) {
        .string => |string| string.slice(),
        else => null,
    };
}

fn selectProcessStock(
    model: *cerealgrain.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    ui: *ProcessUiState,
    stock: []const u8,
) !void {
    const fixed = try cerealgrain.processing.config.FixedString.from(stock);
    if (stock.len == 0) {
        const updates = [_]cerealgrain.processing.config.Override{
            .{ .name = "stock", .value = .{ .string = fixed } },
        };
        try model.saveProcessingSettings(allocator, io, config_path, &updates);
        return;
    }
    ui.export_ir_inv = true;
    const updates = [_]cerealgrain.processing.config.Override{
        .{ .name = "stock", .value = .{ .string = fixed } },
        .{ .name = "export_ir_inv", .value = .{ .boolean = true } },
    };
    try model.saveProcessingSettings(allocator, io, config_path, &updates);
}

fn drawProcessExportVariant(
    ctx: *c.struct_nk_context,
    model: *cerealgrain.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    label: [*:0]const u8,
    setting: []const u8,
    enabled: *bool,
    help: []const u8,
) void {
    var checked = nkBool(enabled.*);
    tooltip(ctx, help);
    if (c.nk_checkbox_label(ctx, label, &checked) == 0) return;
    enabled.* = checked != 0;
    const updates = [_]cerealgrain.processing.config.Override{.{ .name = setting, .value = .{ .boolean = enabled.* } }};
    model.saveProcessingSettings(allocator, io, config_path, &updates) catch |err| setProcessUiError(model, err);
}

fn queueProcessFloatSetting(
    model: *cerealgrain.native_ui.State,
    ui: *ProcessUiState,
    name: []const u8,
    value: f32,
) void {
    ui.settings_draft.put(name, .{ .float = @floatCast(value) }) catch |err| setProcessUiError(model, err);
}

fn queueProcessIntSetting(
    model: *cerealgrain.native_ui.State,
    ui: *ProcessUiState,
    name: []const u8,
    value: c_int,
) void {
    ui.settings_draft.put(name, .{ .integer = @intCast(value) }) catch |err| setProcessUiError(model, err);
}

fn processSettingsCommitReady(ctx: *c.struct_nk_context) bool {
    const input = &ctx.*.input;
    return c.nk_input_is_mouse_down(input, c.NK_BUTTON_LEFT) == 0 and
        c.nk_input_is_mouse_down(input, c.NK_BUTTON_RIGHT) == 0 and
        c.nk_input_is_mouse_down(input, c.NK_BUTTON_MIDDLE) == 0;
}

fn commitPendingProcessSettings(
    model: *cerealgrain.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    ui: *ProcessUiState,
) !void {
    const pending = ui.settings_draft.pending();
    if (pending.len == 0) return;
    try model.saveProcessingSettings(allocator, io, config_path, pending);
    ui.settings_draft.clear();
}

fn saveProcessStringSetting(
    model: *cerealgrain.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    name: []const u8,
    value: []const u8,
) !void {
    const fixed = try cerealgrain.processing.config.FixedString.from(value);
    const updates = [_]cerealgrain.processing.config.Override{
        .{ .name = name, .value = .{ .string = fixed } },
    };
    try model.saveProcessingSettings(allocator, io, config_path, &updates);
}

fn processingPreviewSize(ui: *const ProcessUiState) i64 {
    return @intCast(@max(ui.preview_size, 1));
}

fn processAutoDetectOptions(ui: *const ProcessUiState) cerealgrain.processing.workflow.AutoDetectOptions {
    return .{
        .format = process_formats[@min(ui.format_index, process_formats.len - 1)],
        .n_frames = if (ui.n_frames > 0) @intCast(ui.n_frames) else null,
        .detect_film_extent = true,
        .apply_clahe = true,
    };
}

fn validateProcessAutoDetectUiDefaults(ui: *const ProcessUiState) !void {
    const options = processAutoDetectOptions(ui);
    if (options.n_frames != null) return error.ProcessAutoDetectDefaultMismatch;
    if (options.format == null or !std.mem.eql(u8, options.format.?, "35mm")) return error.ProcessAutoDetectDefaultMismatch;
    if (!options.detect_film_extent or !options.apply_clahe) return error.ProcessAutoDetectDefaultMismatch;
    if (ui.scale_percent != 0.0) return error.ProcessAutoDetectDefaultMismatch;
    if (ui.last_rotation != cerealgrain.native_ui.default_process_output_rotation) return error.ProcessAutoDetectDefaultMismatch;
}

fn validateProcessExportBasenameUiParity(ui: *ProcessUiState, model: *cerealgrain.native_ui.State) !void {
    const initial_stem = model.currentProcessingImageStem();
    syncProcessExportBasename(ui, model);
    if (!std.mem.eql(u8, ui.exportBasename(), initial_stem)) return error.ProcessExportBasenameSmokeFailed;

    ui.setExportBasename("operator-roll");
    syncProcessExportBasename(ui, model);
    if (!std.mem.eql(u8, ui.exportBasename(), "operator-roll")) return error.ProcessExportBasenameSmokeFailed;

    const original_input_path = model.processing.input_path;
    model.processing.input_path = "scans/next.scan.rgbir.tiff";
    syncProcessExportBasename(ui, model);
    if (!std.mem.eql(u8, ui.exportBasename(), "next.scan.rgbir")) return error.ProcessExportBasenameSmokeFailed;

    model.processing.input_path = original_input_path;
    ui.export_basename_source_len = 0;
    syncProcessExportBasename(ui, model);
    if (!std.mem.eql(u8, ui.exportBasename(), initial_stem)) return error.ProcessExportBasenameSmokeFailed;
}

fn startProcessAutoDetect(
    model: *cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    config_path: []const u8,
    ui: *ProcessUiState,
) !void {
    _ = try process_worker.startAutoDetectFromState(
        model,
        config_path,
        processAutoDetectOptions(ui),
        @floatCast(ui.scale_percent),
        ui.last_rotation,
    );
}

fn startProcessRebate(
    model: *cerealgrain.native_ui.State,
    process_worker: *ProcessWorker,
    config_path: []const u8,
) !void {
    _ = try process_worker.startRebateFromState(model, config_path);
}

fn runProcessExport(
    model: *cerealgrain.native_ui.State,
    worker: *ProcessExportWorker,
    ui: *const ProcessUiState,
) !void {
    _ = try worker.startFromState(model, .{
        .basename = ui.exportBasename(),
        .export_ir_neg = ui.export_ir_neg,
        .export_ir_inv = ui.export_ir_inv,
        .export_inv_only = ui.export_inv_only,
    });
}

fn setProcessUiError(model: *cerealgrain.native_ui.State, err: anyerror) void {
    model.setStatus(switch (err) {
        error.NoProcessImageLoaded => "No process image loaded",
        error.InvalidFilmFormat => "Invalid film format",
        error.FileNotFound => "File not found",
        error.AccessDenied => "Access denied",
        error.NoFrameSelections => "Draw or detect frames first",
        else => @errorName(err),
    });
}

fn scanControlsEqual(a: cerealgrain.native_ui.ScanControls, b: cerealgrain.native_ui.ScanControls) bool {
    return a.dpi == b.dpi and
        a.mode == b.mode and
        a.exposure == b.exposure and
        a.autoselect == b.autoselect and
        selectionsEqual(a.selection, b.selection) and
        selectionsEqual(a.auto_selection, b.auto_selection);
}

fn selectionsEqual(a: ?cerealgrain.native_ui.PreviewSelection, b: ?cerealgrain.native_ui.PreviewSelection) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.x == b.?.x and
        a.?.y == b.?.y and
        a.?.w == b.?.w and
        a.?.h == b.?.h;
}

const ProcessConfirmAction = enum {
    trash,
    delete,

    fn verb(self: ProcessConfirmAction) []const u8 {
        return switch (self) {
            .trash => "trash",
            .delete => "delete",
        };
    }
};

const ProcessConfirmation = struct {
    action: ?ProcessConfirmAction = null,
    name: ?[]u8 = null,

    fn deinit(self: *ProcessConfirmation, allocator: std.mem.Allocator) void {
        if (self.name) |name| {
            allocator.free(name);
            self.name = null;
        }
        self.action = null;
    }

    fn request(
        self: *ProcessConfirmation,
        allocator: std.mem.Allocator,
        action: ProcessConfirmAction,
        name: []const u8,
    ) !void {
        self.deinit(allocator);
        self.action = action;
        self.name = try allocator.dupe(u8, name);
    }

    fn pending(self: ProcessConfirmation) bool {
        return self.action != null and self.name != null;
    }
};

const GalleryConfirmAction = enum {
    trash,
    delete,

    fn verb(self: GalleryConfirmAction) []const u8 {
        return switch (self) {
            .trash => "trash",
            .delete => "delete",
        };
    }
};

const GalleryConfirmation = struct {
    action: ?GalleryConfirmAction = null,
    name: ?[]u8 = null,

    fn deinit(self: *GalleryConfirmation, allocator: std.mem.Allocator) void {
        if (self.name) |name| {
            allocator.free(name);
            self.name = null;
        }
        self.action = null;
    }

    fn request(
        self: *GalleryConfirmation,
        allocator: std.mem.Allocator,
        action: GalleryConfirmAction,
        name: []const u8,
    ) !void {
        self.deinit(allocator);
        self.action = action;
        self.name = try allocator.dupe(u8, name);
    }

    fn pending(self: GalleryConfirmation) bool {
        return self.action != null and self.name != null;
    }
};

fn parseSmokeWindowSize(value: []const u8) !SmokeWindowSize {
    const separator = std.mem.indexOfScalar(u8, value, 'x') orelse return error.InvalidSmokeWindowSize;
    const width = try std.fmt.parseInt(c_int, value[0..separator], 10);
    const height = try std.fmt.parseInt(c_int, value[separator + 1 ..], 10);
    if (width < 320 or height < 240) return error.InvalidSmokeWindowSize;
    return .{ .width = width, .height = height };
}

fn dpiLabelZ(dpi: u32) [*:0]const u8 {
    return switch (dpi) {
        300 => "300",
        600 => "600",
        800 => "800",
        1200 => "1200",
        1600 => "1600",
        2400 => "2400",
        3200 => "3200",
        4800 => "4800",
        6400 => "6400",
        else => "unknown",
    };
}

/// Nuklear takes NUL-terminated text; model names are plain slices.
fn scannerNameZ(name: []const u8) [*:0]const u8 {
    const Static = struct {
        var buffer: [96:0]u8 = undefined;
    };
    const len = @min(name.len, Static.buffer.len);
    @memcpy(Static.buffer[0..len], name[0..len]);
    Static.buffer[len] = 0;
    return &Static.buffer;
}
