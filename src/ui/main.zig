const std = @import("std");
const v600 = @import("v600");
const ui_theme = v600.native_ui_theme;

const ConnectWorker = v600.native_ui_connect_worker.Worker;
const PreviewBuffer = v600.native_ui_preview_worker.PreviewBuffer;
const PreviewWorker = v600.native_ui_preview_worker.Worker;
const ScanWorker = v600.native_ui_scan_worker.Worker;
const ProcessWorker = v600.native_ui_process_worker.Worker;
const ProcessExportWorker = v600.native_ui_process_export_worker.Worker;
const InvertedPreviewWorker = v600.native_ui_inverted_preview_worker.Worker;
const InvertedPreviewKey = v600.native_ui_inverted_preview_worker.Key;
const InvertedPreviewResult = v600.native_ui_inverted_preview_worker.Result;

const ProcessUiState = struct {
    preview_size: c_int = 8192,
    format_index: usize = 0,
    aspect_index: usize = default_process_aspect_index,
    n_frames: c_int = 0,
    scale_percent: f32 = 0.0,
    last_angle: f64 = 0.0,
    last_w: f64 = 0.0,
    last_h: f64 = 0.0,
    last_rotation: i32 = v600.native_ui.default_process_output_rotation,
    render_contrast: f32 = 1.4,
    render_curve_k: f32 = 5.0,
    render_percentile_lo: f32 = 0.5,
    render_percentile_hi: f32 = 99.5,
    exposure_compensation: f32 = 0.0,
    color_temp: f32 = 0.0,
    color_tint: f32 = 0.0,
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
    settings_draft: v600.native_ui.ProcessSettingsDraft = .{},

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

const ProcessSelectionEditMode = enum {
    draw_frame,
    draw_rebate,
    move,
    rotate,
    north_west,
    north,
    north_east,
    east,
    south_east,
    south,
    south_west,
    west,
};

const ScanSelectionInteraction = struct {
    active: bool = false,
    mode: v600.native_ui.PreviewSelectionEditMode = .move,
    start_x: f64 = 0.0,
    start_y: f64 = 0.0,
    original: v600.native_ui.PreviewSelection = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 },

    fn beginDraw(self: *ScanSelectionInteraction, preview_x: f64, preview_y: f64) void {
        self.active = true;
        self.mode = .move;
        self.start_x = preview_x;
        self.start_y = preview_y;
        self.original = .{ .x = preview_x, .y = preview_y, .w = 0.0, .h = 0.0 };
    }

    fn beginEdit(
        self: *ScanSelectionInteraction,
        mode: v600.native_ui.PreviewSelectionEditMode,
        preview_x: f64,
        preview_y: f64,
        selection: v600.native_ui.PreviewSelection,
    ) void {
        self.active = true;
        self.mode = mode;
        self.start_x = preview_x;
        self.start_y = preview_y;
        self.original = selection;
    }

    fn drawing(self: ScanSelectionInteraction) bool {
        return self.original.w == 0.0 and self.original.h == 0.0;
    }

    fn end(self: *ScanSelectionInteraction) void {
        self.active = false;
    }
};

const ProcessSelectionTarget = enum {
    frame,
    rebate,
};

const ProcessDrawTarget = enum {
    frame,
    rebate,
};

const ProcessSelectionInteraction = struct {
    active_target: ?ProcessSelectionTarget = null,
    active_index: ?usize = null,
    mode: ProcessSelectionEditMode = .move,
    pending_draw: ?ProcessDrawTarget = null,
    start_x: f64 = 0.0,
    start_y: f64 = 0.0,
    start_pointer_angle: f64 = 0.0,
    original: v600.native_ui.ProcessSelection = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 },
    rebate_active: bool = false,

    fn beginFrame(
        self: *ProcessSelectionInteraction,
        index: usize,
        mode: ProcessSelectionEditMode,
        preview_x: f64,
        preview_y: f64,
        selection: v600.native_ui.ProcessSelection,
    ) void {
        self.active_target = .frame;
        self.active_index = index;
        self.mode = mode;
        self.start_x = preview_x;
        self.start_y = preview_y;
        self.start_pointer_angle = pointerAngleFromSelectionCenter(selection, preview_x, preview_y);
        self.original = selection;
        self.rebate_active = false;
    }

    fn beginRebate(
        self: *ProcessSelectionInteraction,
        mode: ProcessSelectionEditMode,
        preview_x: f64,
        preview_y: f64,
        selection: v600.native_ui.ProcessSelection,
    ) void {
        self.active_target = .rebate;
        self.active_index = null;
        self.mode = mode;
        self.start_x = preview_x;
        self.start_y = preview_y;
        self.start_pointer_angle = pointerAngleFromSelectionCenter(selection, preview_x, preview_y);
        self.original = selection;
        self.rebate_active = true;
    }

    fn beginDrawFrame(self: *ProcessSelectionInteraction, index: usize, preview_x: f64, preview_y: f64) void {
        self.active_target = .frame;
        self.active_index = index;
        self.mode = .draw_frame;
        self.start_x = preview_x;
        self.start_y = preview_y;
        self.original = .{ .x = preview_x, .y = preview_y, .w = 0.0, .h = 0.0 };
        self.rebate_active = false;
    }

    fn beginDrawRebate(self: *ProcessSelectionInteraction, preview_x: f64, preview_y: f64) void {
        self.active_target = .rebate;
        self.active_index = null;
        self.mode = .draw_rebate;
        self.start_x = preview_x;
        self.start_y = preview_y;
        self.original = .{ .x = preview_x, .y = preview_y, .w = 0.0, .h = 0.0 };
        self.rebate_active = true;
    }

    fn end(self: *ProcessSelectionInteraction) void {
        self.active_target = null;
        self.active_index = null;
    }
};

const process_formats = [_][]const u8{ "35mm", "645", "6x6", "6x7", "6x9" };
const process_format_labels = [_][*:0]const u8{ "35mm", "645", "6x6", "6x7", "6x9" };
const process_selection_line_width: f32 = 3.0;
const process_selection_antialias_width: f32 = 1.0;

const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cDefine("NK_INCLUDE_FIXED_TYPES", "1");
    @cDefine("NK_INCLUDE_STANDARD_IO", "1");
    @cDefine("NK_INCLUDE_STANDARD_VARARGS", "1");
    @cDefine("NK_INCLUDE_DEFAULT_ALLOCATOR", "1");
    @cDefine("NK_INCLUDE_VERTEX_BUFFER_OUTPUT", "1");
    @cDefine("NK_INCLUDE_FONT_BAKING", "1");
    @cDefine("NK_INCLUDE_DEFAULT_FONT", "1");
    @cInclude("SDL3/SDL.h");
    @cInclude("nuklear.h");
});

var runtime_ui_config = ui_theme.Config{};
var active_control_panel_rect: c.struct_nk_rect = c.struct_nk_rect{ .x = 16.0, .y = 16.0, .w = 520.0, .h = 360.0 };
var active_footer_rect: c.struct_nk_rect = c.struct_nk_rect{ .x = 0.0, .y = 704.0, .w = 1024.0, .h = 48.0 };

fn controlPanelFlags() c_uint {
    return c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE;
}

fn footerBarFlags() c_uint {
    return c.NK_WINDOW_BORDER | c.NK_WINDOW_NO_SCROLLBAR | c.NK_WINDOW_NO_INPUT;
}

fn controlPanelRect() c.struct_nk_rect {
    return active_control_panel_rect;
}

fn footerBarRect() c.struct_nk_rect {
    return active_footer_rect;
}

fn updateUiChromeRects(window: *c.SDL_Window, model: *const v600.native_ui.State) void {
    var window_w: c_int = 0;
    var window_h: c_int = 0;
    if (!c.SDL_GetWindowSize(window, &window_w, &window_h)) {
        const metrics = runtime_ui_config.metrics();
        window_w = metrics.initialWindowWidth();
        window_h = metrics.initialWindowHeight();
    }
    active_footer_rect = footerBarRectForSize(
        @floatFromInt(@max(window_w, 1)),
        @floatFromInt(@max(window_h, 1)),
    );
    active_control_panel_rect = controlPanelRectForSize(
        @floatFromInt(@max(window_w, 1)),
        @floatFromInt(@max(window_h, 1)),
        model,
    );
}

fn footerBarHeight() f32 {
    return runtime_ui_config.metrics().row(46.0);
}

fn footerBarRectForSize(window_w: f32, window_h: f32) c.struct_nk_rect {
    const height = @min(footerBarHeight(), @max(1.0, window_h));
    return c.nk_rect(
        0.0,
        @max(0.0, window_h - height),
        @max(1.0, window_w),
        height,
    );
}

fn controlPanelRectForSize(window_w: f32, window_h: f32, model: *const v600.native_ui.State) c.struct_nk_rect {
    const metrics = runtime_ui_config.metrics();
    const available_w = @max(80.0, window_w - metrics.margin * 2.0);
    const width = @min(metrics.panelWidth(window_w), available_w);
    const available_h = @max(1.0, window_h - footerBarHeight() - metrics.margin * 3.0);
    return c.nk_rect(
        metrics.margin,
        metrics.margin,
        width,
        @min(metrics.row(controlPanelBaseHeight(model)), available_h),
    );
}

fn controlPanelBaseHeight(model: *const v600.native_ui.State) f32 {
    return switch (model.active_view) {
        .scan => 330.0,
        .gallery => 330.0,
        .process => 940.0 +
            @as(f32, @floatFromInt(@min(model.processing_images.paths.len, 16))) * 24.0 +
            @as(f32, @floatFromInt(@min(model.process_selection_count, 12))) * 50.0,
    };
}

fn layoutRow(ctx: *c.struct_nk_context, base_height: f32, columns: c_int) void {
    c.nk_layout_row_dynamic(ctx, runtime_ui_config.metrics().row(base_height), columns);
}

fn layoutRowStatic(ctx: *c.struct_nk_context, base_height: f32, base_width: c_int, columns: c_int) void {
    const metrics = runtime_ui_config.metrics();
    c.nk_layout_row_static(
        ctx,
        metrics.row(base_height),
        @intFromFloat(@round(@as(f32, @floatFromInt(base_width)) * metrics.scale)),
        columns,
    );
}

fn applyNuklearStyle(ctx: *c.struct_nk_context, config: ui_theme.Config) void {
    const palette = config.palette();
    var colors: [c.NK_COLOR_COUNT]c.struct_nk_color = undefined;
    for (&colors) |*color| color.* = nkColor(palette.window);
    setStyleColor(&colors, c.NK_COLOR_TEXT, palette.text);
    setStyleColor(&colors, c.NK_COLOR_WINDOW, palette.window);
    setStyleColor(&colors, c.NK_COLOR_HEADER, palette.header);
    setStyleColor(&colors, c.NK_COLOR_BORDER, palette.border);
    setStyleColor(&colors, c.NK_COLOR_BUTTON, palette.button);
    setStyleColor(&colors, c.NK_COLOR_BUTTON_HOVER, palette.button_hover);
    setStyleColor(&colors, c.NK_COLOR_BUTTON_ACTIVE, palette.button_active);
    setStyleColor(&colors, c.NK_COLOR_TOGGLE, palette.toggle);
    setStyleColor(&colors, c.NK_COLOR_TOGGLE_HOVER, palette.toggle_hover);
    setStyleColor(&colors, c.NK_COLOR_TOGGLE_CURSOR, palette.toggle_cursor);
    setStyleColor(&colors, c.NK_COLOR_SELECT, palette.select);
    setStyleColor(&colors, c.NK_COLOR_SELECT_ACTIVE, palette.select_active);
    setStyleColor(&colors, c.NK_COLOR_SLIDER, palette.slider);
    setStyleColor(&colors, c.NK_COLOR_SLIDER_CURSOR, palette.slider_cursor);
    setStyleColor(&colors, c.NK_COLOR_SLIDER_CURSOR_HOVER, palette.slider_cursor_hover);
    setStyleColor(&colors, c.NK_COLOR_SLIDER_CURSOR_ACTIVE, palette.slider_cursor_hover);
    setStyleColor(&colors, c.NK_COLOR_PROPERTY, palette.property);
    setStyleColor(&colors, c.NK_COLOR_EDIT, palette.edit);
    setStyleColor(&colors, c.NK_COLOR_EDIT_CURSOR, palette.edit_cursor);
    setStyleColor(&colors, c.NK_COLOR_COMBO, palette.property);
    setStyleColor(&colors, c.NK_COLOR_SCROLLBAR, palette.scrollbar);
    setStyleColor(&colors, c.NK_COLOR_SCROLLBAR_CURSOR, palette.scrollbar_cursor);
    setStyleColor(&colors, c.NK_COLOR_SCROLLBAR_CURSOR_HOVER, palette.button_hover);
    setStyleColor(&colors, c.NK_COLOR_SCROLLBAR_CURSOR_ACTIVE, palette.button_active);
    setStyleColor(&colors, c.NK_COLOR_TAB_HEADER, palette.tab_header);
    setStyleColor(&colors, c.NK_COLOR_KNOB, palette.slider);
    setStyleColor(&colors, c.NK_COLOR_KNOB_CURSOR, palette.slider_cursor);
    setStyleColor(&colors, c.NK_COLOR_KNOB_CURSOR_HOVER, palette.slider_cursor_hover);
    setStyleColor(&colors, c.NK_COLOR_KNOB_CURSOR_ACTIVE, palette.slider_cursor_hover);
    c.nk_style_from_table(ctx, &colors);

    const metrics = config.metrics();
    ctx.*.style.window.padding = c.nk_vec2(metrics.window_padding_x, metrics.window_padding_y);
    ctx.*.style.window.spacing = c.nk_vec2(metrics.widget_spacing_x, metrics.widget_spacing_y);
    ctx.*.style.window.scrollbar_size = c.nk_vec2(metrics.scrollbar_width, metrics.scrollbar_width);
    ctx.*.style.window.rounding = metrics.rounding;
    ctx.*.style.window.border = metrics.border;
    ctx.*.style.button.padding = c.nk_vec2(metrics.row(6.0), metrics.row(3.0));
    ctx.*.style.button.rounding = metrics.rounding;
    ctx.*.style.button.border = metrics.border;
    ctx.*.style.edit.padding = c.nk_vec2(metrics.row(5.0), metrics.row(3.0));
    ctx.*.style.edit.rounding = metrics.rounding;
    ctx.*.style.edit.border = metrics.border;
    ctx.*.style.property.padding = c.nk_vec2(metrics.row(5.0), metrics.row(3.0));
    ctx.*.style.property.rounding = metrics.rounding;
    ctx.*.style.property.border = metrics.border;
    ctx.*.style.slider.padding = c.nk_vec2(metrics.row(5.0), metrics.row(3.0));
    ctx.*.style.slider.rounding = metrics.rounding;
    ctx.*.style.slider.cursor_size = c.nk_vec2(metrics.row(16.0), metrics.row(16.0));
    ctx.*.style.scrollv.padding = c.nk_vec2(0.0, 0.0);
    ctx.*.style.scrollv.rounding = metrics.rounding;
    ctx.*.style.scrollv.border = metrics.border;
}

fn setStyleColor(colors: *[c.NK_COLOR_COUNT]c.struct_nk_color, index: c_int, color: ui_theme.Rgba) void {
    colors[@as(usize, @intCast(index))] = nkColor(color);
}

fn nkColor(color: ui_theme.Rgba) c.struct_nk_color {
    return c.nk_rgba(color.r, color.g, color.b, color.a);
}

fn setRendererColor(renderer: *c.SDL_Renderer, color: ui_theme.Rgba) void {
    _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
}

pub fn main(init: std.process.Init) !void {
    var smoke = false;
    var preview_worker_smoke = false;
    var scan_worker_smoke = false;
    var preview_render_smoke = false;
    var scan_interaction_smoke = false;
    var process_render_smoke = false;
    var process_interaction_smoke = false;
    var process_worker_smoke = false;
    var process_dump_smoke = false;
    var process_selector_smoke = false;
    var process_confirm_smoke = false;
    var process_export_smoke = false;
    var gallery_render_smoke = false;
    var gallery_interaction_smoke = false;
    var gallery_shortcut_smoke = false;
    var gallery_confirm_smoke = false;
    var scanner_connect_smoke = false;
    var preview_worker_output: []const u8 = "/tmp/v600-native-preview-worker-smoke.tiff";
    var scan_worker_output: []const u8 = "/tmp/v600-native-scan-worker-smoke.tiff";
    var process_ui = ProcessUiState{};
    var model = v600.native_ui.State.init("scans", "frames", 0);
    defer model.deinit(std.heap.page_allocator);
    std.Io.Dir.cwd().createDirPath(init.io, model.scanner.output_dir) catch {};
    var scanner_config_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const scanner_config_path = v600.native_ui.scannerConfigPath(&scanner_config_path_buffer, model.scanner.output_dir) catch v600.scanner.config.file_name;
    model.loadScannerConfig(std.heap.page_allocator, init.io, scanner_config_path) catch {};
    var processing_config_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const processing_config_path = v600.native_ui.processingConfigPath(&processing_config_path_buffer) catch v600.processing.config.config_file;
    model.loadProcessingConfig(std.heap.page_allocator, init.io, processing_config_path) catch {};
    syncProcessUiFromConfig(&process_ui, &model);
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
    runtime_ui_config = ui_theme.Config.fromEnvironment(init.environ_map);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
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
        } else if (std.mem.eql(u8, arg, "--scan-interaction-smoke")) {
            preview_render_smoke = true;
            scan_interaction_smoke = true;
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
        } else if (std.mem.eql(u8, arg, "--ui-theme")) {
            const value = args.next() orelse return error.MissingUiTheme;
            runtime_ui_config.theme = ui_theme.ThemeName.parse(value) orelse return error.InvalidUiTheme;
        } else if (std.mem.eql(u8, arg, "--ui-scale")) {
            const value = args.next() orelse return error.MissingUiScale;
            runtime_ui_config.scale = try ui_theme.parseScale(value);
        } else if (std.mem.eql(u8, arg, "--out")) {
            const output = args.next() orelse return error.MissingSmokeOutput;
            preview_worker_output = output;
            scan_worker_output = output;
        }
    }
    runtime_ui_config = runtime_ui_config.normalized();

    if (smoke) try assertScanBusyQueuePolicy();

    if (preview_worker_smoke) {
        try runPreviewWorkerSmoke(init.environ_map, &model, &preview_worker, preview_worker_output);
        return;
    }
    if (scan_worker_smoke) {
        try runScanWorkerSmoke(&model, &scan_worker, scan_worker_output);
        return;
    }
    if (process_dump_smoke) {
        try runProcessDumpSmoke(&model, std.heap.page_allocator);
        return;
    }
    const start_connect_worker = !preview_render_smoke and !process_render_smoke and !gallery_render_smoke;
    if (start_connect_worker) {
        if (smoke) connect_worker.execute = v600.native_ui_connect_worker.fakeConnectDelayedSuccess;
        if (!(try connect_worker.start(&model))) return error.ScannerConnectWorkerDidNotStart;
        if (scanner_connect_smoke or smoke) try assertScannerConnectSmokeInitial(&model);
    }
    if (preview_render_smoke) {
        try seedSyntheticPreview(&preview_worker, &model);
    }
    if (process_interaction_smoke) {
        process_worker.execute = v600.native_ui_process_worker.fakeRebateSuccess;
    }
    if (process_render_smoke) {
        try validateProcessAutoDetectUiDefaults(&process_ui);
        var smoke_processing_config = v600.processing.config.LoadedConfig{};
        try smoke_processing_config.apply(&.{
            .{ .name = "stock", .value = .{ .string = v600.processing.config.FixedString.init("kodak_gold") } },
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
        process_worker.execute = v600.native_ui_process_worker.fakeLoadDelayedSuccess;
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

    const runtime_metrics = runtime_ui_config.metrics();
    const window = c.SDL_CreateWindow(
        "V600",
        runtime_metrics.initialWindowWidth(),
        runtime_metrics.initialWindowHeight(),
        c.SDL_WINDOW_RESIZABLE,
    ) orelse return error.SdlCreateWindowFailed;
    defer c.SDL_DestroyWindow(window);
    updateUiChromeRects(window, &model);
    if (smoke) try assertControlPanelPolicy();
    if (smoke) try assertFooterStatusPolicy(&process_worker, &process_export_worker);

    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlCreateRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);
    var preview_texture = PreviewTextureCache{};
    defer preview_texture.deinit();
    var scan_selection_interaction = ScanSelectionInteraction{};
    var process_texture = ProcessPreviewTextureCache{};
    defer process_texture.deinit(std.heap.page_allocator);
    var process_selection_interaction = ProcessSelectionInteraction{};
    var process_transform = v600.native_ui.ProcessViewTransform{};
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

    var atlas: c.struct_nk_font_atlas = undefined;
    c.nk_font_atlas_init_default(&atlas);
    defer c.nk_font_atlas_clear(&atlas);
    c.nk_font_atlas_begin(&atlas);
    const font = c.nk_font_atlas_add_default(&atlas, runtime_metrics.font_size, null) orelse return error.NuklearFontFailed;
    var atlas_width: c_int = 0;
    var atlas_height: c_int = 0;
    const atlas_pixels = c.nk_font_atlas_bake(&atlas, &atlas_width, &atlas_height, c.NK_FONT_ATLAS_RGBA32) orelse return error.NuklearFontBakeFailed;
    var nuklear_renderer = try NuklearRenderer.init(renderer, atlas_pixels, atlas_width, atlas_height);
    defer nuklear_renderer.deinit();
    c.nk_font_atlas_end(&atlas, c.nk_handle_ptr(nuklear_renderer.font_texture), &nuklear_renderer.null_texture);

    var ctx: c.struct_nk_context = undefined;
    if (c.nk_init_default(&ctx, &font.*.handle) == 0) return error.NuklearInitFailed;
    defer c.nk_free(&ctx);
    applyNuklearStyle(&ctx, runtime_ui_config);

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
            feedNuklearInput(&ctx, event);
            handleScanSelectionEvent(
                &scan_selection_interaction,
                &model,
                renderer,
                preview_worker.last_preview,
                event,
            );
            handleScanShortcutEvent(&scan_selection_interaction, &model, event);
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
            handleProcessShortcutEvent(&process_selection_interaction, &model, event, ctx.text_edit.active != 0);
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
        if (model.quit_requested) running = false;

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
                .scan => drawScanView(&ctx, &model),
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
        _ = preview_worker.poll(&model);
        _ = scan_worker.poll(&model);
        if (process_worker.poll(&model)) {
            if (process_worker.takeLastAutoAspect()) |aspect| {
                process_ui.aspect_index = processAspectIndexClosestTo(aspect) orelse process_ui.aspect_index;
            }
        }
        _ = process_export_worker.poll(&model);
        if (inverted_preview_worker.poll()) |completed| {
            var result = completed;
            defer result.deinit(std.heap.page_allocator);
            _ = process_texture.installInvertedResult(renderer, std.heap.page_allocator, &model, &result) catch |err| blk: {
                setProcessUiError(&model, err);
                break :blk false;
            };
        }
        if (model.active_view == .process and model.takeProcessAutoDetectPending()) {
            startProcessAutoDetect(
                &model,
                &process_worker,
                processing_config_path,
                &process_ui,
            ) catch |err| setProcessUiError(&model, err);
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

        setRendererColor(renderer, runtime_ui_config.palette().background);
        _ = c.SDL_RenderClear(renderer);
        if (model.active_view == .gallery) {
            renderGalleryTexture(renderer, &gallery_texture, &gallery_transform, &model, std.heap.page_allocator);
        } else if (model.active_view == .process) {
            renderProcessTexture(renderer, &process_texture, &inverted_preview_worker, &model, &process_selection_interaction, &process_transform);
        } else {
            renderPreviewTexture(renderer, &preview_texture, preview_worker.last_preview, &model);
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
        _ = c.SDL_RenderPresent(renderer);
        c.nk_clear(&ctx);

        frames += 1;
        const smoke_min_frames: usize = if (scan_interaction_smoke or process_interaction_smoke or process_worker_smoke or process_selector_smoke or process_export_smoke or gallery_interaction_smoke or gallery_shortcut_smoke or gallery_confirm_smoke) 2 else 1;
        const smoke_max_frames: usize = if (process_render_smoke) 120 else smoke_min_frames;
        if (smoke and frames >= smoke_min_frames and (!process_render_smoke or process_inverted_render_checked)) running = false;
        if (smoke and frames >= smoke_max_frames) {
            if (process_render_smoke and !process_inverted_render_checked) return error.ProcessRenderSmokeFailed;
            running = false;
        }
        c.SDL_Delay(16);
    }
}

fn assertNuklearChromeRendered(renderer: *c.SDL_Renderer) !void {
    const surface = c.SDL_RenderReadPixels(renderer, null) orelse return error.SdlRenderReadbackFailed;
    defer c.SDL_DestroySurface(surface);

    const clear = runtime_ui_config.palette().background;
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
    model: *v600.native_ui.State,
    preview_worker: *PreviewWorker,
    output_path: []const u8,
) !void {
    if (!hardwareSmokeEnabled(environ_map)) {
        std.debug.print("native preview worker smoke skipped: set V600_HARDWARE_SMOKE=1 to run\n", .{});
        return;
    }
    if (!model.scannerStatus().connected) {
        const caps = v600.scanner.contracts.ScannerCapabilities{};
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

fn assertScannerConnectSmokeInitial(model: *v600.native_ui.State) !void {
    const status = model.scannerStatus();
    if (!status.connecting or status.connected) return error.ScannerConnectSmokeFailed;
    if (std.mem.eql(u8, status.status, "Ready")) return error.ScannerConnectSmokeFailed;
    if (std.mem.eql(u8, model.status, "Ready")) return error.ScannerConnectSmokeFailed;
    if (std.mem.eql(u8, model.scanStatusDisplay(), "Ready")) return error.ScannerConnectSmokeFailed;
}

fn assertScanBusyQueuePolicy() !void {
    var model = v600.native_ui.State.init("scans", "frames", 0);
    defer model.deinit(std.heap.page_allocator);
    model.scannerConnected(160, 100, 2.7, 9.54);
    if (!model.queuePreviewScan("/tmp/v600-native-preview-a.tiff")) return error.ScanBusySmokeFailed;
    if (model.queuePreviewScan("/tmp/v600-native-preview-b.tiff")) return error.ScanBusySmokeFailed;
    if (model.queueScanStartPath("/tmp/v600-native-scan-after-preview.tiff", null)) return error.ScanBusySmokeFailed;
    switch (model.pending_command orelse return error.ScanBusySmokeFailed) {
        .preview_scan => |plan| {
            if (!std.mem.eql(u8, plan.output_path, "/tmp/v600-native-preview-a.tiff")) return error.ScanBusySmokeFailed;
        },
        .scan_start => return error.ScanBusySmokeFailed,
    }
}

fn runScanWorkerSmoke(
    model: *v600.native_ui.State,
    scan_worker: *ScanWorker,
    output_path: []const u8,
) !void {
    if (!hardwareSmokeEnabled(scan_worker.environ_map)) {
        std.debug.print("native scan worker smoke skipped: set V600_HARDWARE_SMOKE=1 to run\n", .{});
        return;
    }

    const caps = v600.scanner.contracts.ScannerCapabilities{};
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

    const cancel_path = ".zig-cache/v600-native-scan-worker-smoke.cancel";
    if (!model.queueScanStartPath(output_path, cancel_path)) return error.ScanWorkerPlanUnavailable;
    if (!(try scan_worker.startQueued(model, null))) return error.ScanWorkerDidNotStart;
    while (!scan_worker.poll(model)) {
        try std.Thread.yield();
    }
    if (model.scanner.scanning) return error.ScanWorkerSmokeFailed;
    std.debug.print("native scan worker smoke status: {s}\n", .{model.status});
    std.debug.print("native scan worker smoke wrote {s}\n", .{output_path});
}

fn hardwareSmokeEnabled(environ_map: *std.process.Environ.Map) bool {
    const value = environ_map.get("V600_HARDWARE_SMOKE") orelse return false;
    return std.mem.eql(u8, value, "1");
}

fn seedSyntheticPreview(preview_worker: *PreviewWorker, model: *v600.native_ui.State) !void {
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
    const caps = v600.scanner.contracts.ScannerCapabilities{};
    model.scan_controls.autoselect = false;
    model.finishPreviewScan(caps, preview_worker.last_preview.?.info());
    model.scan_controls.setSelection(.{ .x = 100.0, .y = 55.0, .w = 35.0, .h = 30.0 });
}

fn seedProcessWorkerSmokeImages(model: *v600.native_ui.State, allocator: std.mem.Allocator) !void {
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    preview_size: i64,
) !void {
    const scan_dir = ".zig-cache/tmp/v600-native-process-confirm-smoke/scans";
    const output_dir = ".zig-cache/tmp/v600-native-process-confirm-smoke/frames";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, ".zig-cache/tmp/v600-native-process-confirm-smoke") catch {};
    try cwd.createDirPath(io, scan_dir);
    try cwd.createDirPath(io, output_dir);
    const fixture = try cwd.readFileAlloc(
        io,
        "test/fixtures/tiff/rgb-thumb-ir.tiff",
        allocator,
        .limited(128 * 1024),
    );
    defer allocator.free(fixture);
    try cwd.writeFile(io, .{ .sub_path = ".zig-cache/tmp/v600-native-process-confirm-smoke/scans/confirm_a.tiff", .data = fixture });
    try cwd.writeFile(io, .{ .sub_path = ".zig-cache/tmp/v600-native-process-confirm-smoke/scans/confirm_b.tiff", .data = fixture });
    model.processing.input_dir = scan_dir;
    model.processing.output_dir = output_dir;
    _ = try model.refreshProcessingImageList(allocator, io);
    _ = try model.switchProcessingImage(allocator, 0, preview_size);
}

fn seedSyntheticGallery(model: *v600.native_ui.State, io: std.Io) !void {
    const output_dir = ".zig-cache/tmp/v600-native-gallery-smoke";
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
    try cwd.writeFile(io, .{ .sub_path = ".zig-cache/tmp/v600-native-gallery-smoke/roll_01_inv.tif", .data = fixture });
    try cwd.writeFile(io, .{ .sub_path = ".zig-cache/tmp/v600-native-gallery-smoke/roll_02_inv.tif", .data = fixture });
    model.processing.output_dir = output_dir;
    _ = try model.refreshGalleryFiles(std.heap.page_allocator, io);
    model.show(.gallery);
}

fn feedNuklearInput(ctx: *c.struct_nk_context, event: c.SDL_Event) void {
    switch (event.type) {
        c.SDL_EVENT_MOUSE_MOTION => {
            c.nk_input_motion(ctx, mouseCoord(event.motion.x), mouseCoord(event.motion.y));
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (nkButtonFromSdl(event.button.button)) |button| {
                c.nk_input_button(
                    ctx,
                    button,
                    mouseCoord(event.button.x),
                    mouseCoord(event.button.y),
                    nkBool(event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN),
                );
            }
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            if (!controlPanelShouldReceiveWheel(event)) return;
            var x = event.wheel.x;
            var y = event.wheel.y;
            if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) {
                x = -x;
                y = -y;
            }
            c.nk_input_scroll(ctx, c.nk_vec2(x, y));
        },
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
            if (nkKeyFromSdl(event.key.key)) |key| {
                c.nk_input_key(ctx, key, nkBool(event.type == c.SDL_EVENT_KEY_DOWN));
            }
        },
        else => {},
    }
}

fn handleScanSelectionEvent(
    interaction: *ScanSelectionInteraction,
    model: *v600.native_ui.State,
    renderer: *c.SDL_Renderer,
    preview: ?PreviewBuffer,
    event: c.SDL_Event,
) void {
    if (model.active_view != .scan) {
        interaction.end();
        return;
    }
    const image_rect = scanImageRect(renderer, preview) orelse {
        interaction.end();
        return;
    };
    const bounds = scanPreviewBounds(preview) orelse return;
    switch (event.type) {
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            if (event.button.button != c.SDL_BUTTON_LEFT) return;
            const screen_x = @as(f64, @floatCast(event.button.x));
            const screen_y = @as(f64, @floatCast(event.button.y));
            if (pointInUiChrome(screen_x, screen_y)) return;
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
            if (!interaction.active) return;
            const preview_point = screenToScanPreviewUnclamped(
                image_rect,
                @as(f64, @floatCast(event.motion.x)),
                @as(f64, @floatCast(event.motion.y)),
            );
            if (interaction.drawing()) {
                model.scan_controls.selection = v600.native_ui.previewSelectionFromDraw(
                    interaction.start_x,
                    interaction.start_y,
                    preview_point.x,
                    preview_point.y,
                    bounds.w,
                    bounds.h,
                );
            } else {
                model.scan_controls.selection = v600.native_ui.adjustedPreviewSelection(
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

fn handleScanShortcutEvent(
    interaction: *ScanSelectionInteraction,
    model: *v600.native_ui.State,
    event: c.SDL_Event,
) void {
    if (model.active_view != .scan or event.type != c.SDL_EVENT_KEY_DOWN) return;
    switch (event.key.key) {
        c.SDLK_ESCAPE, c.SDLK_DELETE => {
            model.scan_controls.selection = null;
            interaction.end();
        },
        else => {},
    }
}

const ScanPreviewBounds = struct {
    w: f64,
    h: f64,
};

const ScanPreviewPoint = struct {
    x: f64,
    y: f64,
};

fn scanImageRect(renderer: *c.SDL_Renderer, preview: ?PreviewBuffer) ?v600.native_ui.PreviewScreenRect {
    const image = preview orelse return null;
    var out_w: c_int = 0;
    var out_h: c_int = 0;
    if (!c.SDL_GetCurrentRenderOutputSize(renderer, &out_w, &out_h)) return null;
    return v600.native_ui.fitPreviewImage(
        image.width,
        image.height,
        @intCast(out_w),
        @intCast(out_h),
        20.0,
    );
}

fn scanPreviewBounds(preview: ?PreviewBuffer) ?ScanPreviewBounds {
    const image = preview orelse return null;
    return .{
        .w = @floatFromInt(image.width),
        .h = @floatFromInt(image.height),
    };
}

fn screenToScanPreview(
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
) ?ScanPreviewPoint {
    if (screen_x < image_rect.x or screen_y < image_rect.y or
        screen_x > image_rect.x + image_rect.w or screen_y > image_rect.y + image_rect.h)
    {
        return null;
    }
    return screenToScanPreviewUnclamped(image_rect, screen_x, screen_y);
}

fn screenToScanPreviewUnclamped(
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
) ScanPreviewPoint {
    return .{
        .x = (screen_x - image_rect.x) / image_rect.scale,
        .y = (screen_y - image_rect.y) / image_rect.scale,
    };
}

fn hitScanSelection(
    selection: ?v600.native_ui.PreviewSelection,
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
    preview_x: f64,
    preview_y: f64,
) ?v600.native_ui.PreviewSelectionEditMode {
    const sel = selection orelse return null;
    if (!sel.isDrawable()) return null;
    if (scanSelectionHandleAt(sel, image_rect, screen_x, screen_y)) |mode| return mode;
    if (preview_x >= sel.x and preview_x <= sel.x + sel.w and preview_y >= sel.y and preview_y <= sel.y + sel.h) {
        return .move;
    }
    return null;
}

fn scanSelectionHandleAt(
    selection: v600.native_ui.PreviewSelection,
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
) ?v600.native_ui.PreviewSelectionEditMode {
    const x = image_rect.x + selection.x * image_rect.scale;
    const y = image_rect.y + selection.y * image_rect.scale;
    const w = selection.w * image_rect.scale;
    const h = selection.h * image_rect.scale;
    const mx = x + w / 2.0;
    const my = y + h / 2.0;
    const handles = [_]struct {
        x: f64,
        y: f64,
        mode: v600.native_ui.PreviewSelectionEditMode,
    }{
        .{ .x = x, .y = y, .mode = .north_west },
        .{ .x = mx, .y = y, .mode = .north },
        .{ .x = x + w, .y = y, .mode = .north_east },
        .{ .x = x + w, .y = my, .mode = .east },
        .{ .x = x + w, .y = y + h, .mode = .south_east },
        .{ .x = mx, .y = y + h, .mode = .south },
        .{ .x = x, .y = y + h, .mode = .south_west },
        .{ .x = x, .y = my, .mode = .west },
    };
    for (handles) |handle| {
        if (@abs(screen_x - handle.x) <= 8.0 and @abs(screen_y - handle.y) <= 8.0) {
            return handle.mode;
        }
    }
    return null;
}

fn handleGalleryImageEvent(
    transform: *GalleryViewTransform,
    model: *const v600.native_ui.State,
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
            transform.zoomAt(x, y, if (wheel_y > 0) 1.1 else 0.9);
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
    model: *v600.native_ui.State,
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
    transform: *v600.native_ui.ProcessViewTransform,
    model: *v600.native_ui.State,
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
    if (process_worker.isRunning() or !model.processPreviewInteractionReady()) {
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
            transform.zoomAt(screen_x, screen_y, if (wheel_y > 0) 1.1 else 0.9);
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
    model: *v600.native_ui.State,
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
        else => {},
    }
}

fn finalizeProcessRebate(
    model: *v600.native_ui.State,
    process_worker: *ProcessWorker,
    config_path: []const u8,
    rebate: v600.native_ui.ProcessSelection,
) void {
    const accepted = model.setProcessRebatePreviewRect(rebate) catch |err| {
        setProcessUiError(model, err);
        return;
    };
    if (!accepted) return;
    startProcessRebate(model, process_worker, config_path) catch |err| setProcessUiError(model, err);
}

const ProcessPreviewPoint = struct {
    x: f64,
    y: f64,
};

const ProcessScreenPoint = struct {
    x: f64,
    y: f64,
};

const ProcessPreviewBounds = struct {
    w: f64,
    h: f64,
};

const ProcessSelectionHit = struct {
    target: ProcessSelectionTarget,
    index: ?usize,
    mode: ProcessSelectionEditMode,
};

fn processImageRect(
    renderer: *c.SDL_Renderer,
    model: *const v600.native_ui.State,
    transform: *v600.native_ui.ProcessViewTransform,
) ?v600.native_ui.PreviewScreenRect {
    const preview = model.processing_preview orelse return null;
    var out_w: c_int = 0;
    var out_h: c_int = 0;
    if (!c.SDL_GetCurrentRenderOutputSize(renderer, &out_w, &out_h)) return null;
    transform.ensureFit(
        model.processing.input_path,
        @intCast(@max(out_w, 1)),
        @intCast(@max(out_h, 1)),
        preview.preview_width,
        preview.preview_height,
    );
    return transform.imageRect(preview.preview_width, preview.preview_height);
}

fn processPreviewBounds(model: *const v600.native_ui.State) ?ProcessPreviewBounds {
    const preview = model.processing_preview orelse return null;
    return .{
        .w = @floatFromInt(preview.preview_width),
        .h = @floatFromInt(preview.preview_height),
    };
}

fn screenToPreview(
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
) ?ProcessPreviewPoint {
    if (screen_x < image_rect.x or screen_y < image_rect.y or
        screen_x > image_rect.x + image_rect.w or screen_y > image_rect.y + image_rect.h)
    {
        return null;
    }
    return screenToPreviewUnclamped(image_rect, screen_x, screen_y);
}

fn screenToPreviewUnclamped(
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
) ProcessPreviewPoint {
    return .{
        .x = (screen_x - image_rect.x) / image_rect.scale,
        .y = (screen_y - image_rect.y) / image_rect.scale,
    };
}

fn processSelectionCenter(selection: v600.native_ui.ProcessSelection) ProcessPreviewPoint {
    return .{
        .x = selection.x + selection.w / 2.0,
        .y = selection.y + selection.h / 2.0,
    };
}

fn pointerAngleFromSelectionCenter(
    selection: v600.native_ui.ProcessSelection,
    preview_x: f64,
    preview_y: f64,
) f64 {
    const center = processSelectionCenter(selection);
    return std.math.atan2(preview_y - center.y, preview_x - center.x);
}

fn selectionLocalToPreview(
    selection: v600.native_ui.ProcessSelection,
    local_x: f64,
    local_y: f64,
) ProcessPreviewPoint {
    const center = processSelectionCenter(selection);
    const cos_a = @cos(selection.angle);
    const sin_a = @sin(selection.angle);
    return .{
        .x = center.x + local_x * cos_a - local_y * sin_a,
        .y = center.y + local_x * sin_a + local_y * cos_a,
    };
}

fn selectionLocalToScreen(
    image_rect: v600.native_ui.PreviewScreenRect,
    selection: v600.native_ui.ProcessSelection,
    local_x: f64,
    local_y: f64,
) ProcessScreenPoint {
    const preview = selectionLocalToPreview(selection, local_x, local_y);
    return .{
        .x = image_rect.x + preview.x * image_rect.scale,
        .y = image_rect.y + preview.y * image_rect.scale,
    };
}

fn previewToSelectionLocal(
    selection: v600.native_ui.ProcessSelection,
    preview_x: f64,
    preview_y: f64,
) ProcessPreviewPoint {
    const center = processSelectionCenter(selection);
    const dx = preview_x - center.x;
    const dy = preview_y - center.y;
    const cos_a = @cos(selection.angle);
    const sin_a = @sin(selection.angle);
    return .{
        .x = dx * cos_a + dy * sin_a,
        .y = -dx * sin_a + dy * cos_a,
    };
}

fn previewDeltaToSelectionLocal(angle: f64, dx: f64, dy: f64) ProcessPreviewPoint {
    const cos_a = @cos(angle);
    const sin_a = @sin(angle);
    return .{
        .x = dx * cos_a + dy * sin_a,
        .y = -dx * sin_a + dy * cos_a,
    };
}

fn processRotationHandleOffsetPreview(image_rect: v600.native_ui.PreviewScreenRect) f64 {
    if (image_rect.scale <= 0.0) return 0.0;
    return 28.0 / image_rect.scale;
}

fn hitProcessSelection(
    model: *const v600.native_ui.State,
    interaction: *const ProcessSelectionInteraction,
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
    preview_x: f64,
    preview_y: f64,
) ?ProcessSelectionHit {
    var index = model.process_selection_count;
    while (index > 0) {
        index -= 1;
        const selection = model.process_selections[index];
        if (processSelectionHandleAt(selection, image_rect, screen_x, screen_y)) |mode| {
            return .{ .target = .frame, .index = index, .mode = mode };
        }
        const local = previewToSelectionLocal(selection, preview_x, preview_y);
        if (@abs(local.x) <= selection.w / 2.0 and @abs(local.y) <= selection.h / 2.0) {
            return .{ .target = .frame, .index = index, .mode = .move };
        }
    }
    if (model.process_rebate_rect) |rebate| {
        if (interaction.rebate_active) {
            if (processSelectionHandleAt(rebate, image_rect, screen_x, screen_y)) |mode| {
                return .{ .target = .rebate, .index = null, .mode = mode };
            }
        }
        const local = previewToSelectionLocal(rebate, preview_x, preview_y);
        if (@abs(local.x) <= rebate.w / 2.0 and @abs(local.y) <= rebate.h / 2.0) {
            return .{ .target = .rebate, .index = null, .mode = .move };
        }
    }
    return null;
}

fn processSelectionHandleAt(
    selection: v600.native_ui.ProcessSelection,
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
) ?ProcessSelectionEditMode {
    if (selection.w <= 0.0 or selection.h <= 0.0) return null;
    const half_w = selection.w / 2.0;
    const half_h = selection.h / 2.0;
    const rotate_y = -half_h - processRotationHandleOffsetPreview(image_rect);
    const rotate_bottom_y = half_h + processRotationHandleOffsetPreview(image_rect);
    const rotate_left_x = -half_w - processRotationHandleOffsetPreview(image_rect);
    const rotate_right_x = half_w + processRotationHandleOffsetPreview(image_rect);
    const handles = [_]struct {
        local_x: f64,
        local_y: f64,
        mode: ProcessSelectionEditMode,
    }{
        .{ .local_x = 0.0, .local_y = rotate_y, .mode = .rotate },
        .{ .local_x = 0.0, .local_y = rotate_bottom_y, .mode = .rotate },
        .{ .local_x = rotate_left_x, .local_y = 0.0, .mode = .rotate },
        .{ .local_x = rotate_right_x, .local_y = 0.0, .mode = .rotate },
        .{ .local_x = -half_w, .local_y = -half_h, .mode = .north_west },
        .{ .local_x = 0.0, .local_y = -half_h, .mode = .north },
        .{ .local_x = half_w, .local_y = -half_h, .mode = .north_east },
        .{ .local_x = half_w, .local_y = 0.0, .mode = .east },
        .{ .local_x = half_w, .local_y = half_h, .mode = .south_east },
        .{ .local_x = 0.0, .local_y = half_h, .mode = .south },
        .{ .local_x = -half_w, .local_y = half_h, .mode = .south_west },
        .{ .local_x = -half_w, .local_y = 0.0, .mode = .west },
    };
    for (handles) |handle| {
        const point = selectionLocalToScreen(image_rect, selection, handle.local_x, handle.local_y);
        const tolerance: f64 = if (handle.mode == .rotate) 10.0 else 8.0;
        if (@abs(screen_x - point.x) <= tolerance and @abs(screen_y - point.y) <= tolerance) {
            return handle.mode;
        }
    }
    return null;
}

fn adjustedProcessSelection(
    original: v600.native_ui.ProcessSelection,
    mode: ProcessSelectionEditMode,
    dx: f64,
    dy: f64,
    bounds_w: f64,
    bounds_h: f64,
    aspect: ?f64,
) v600.native_ui.ProcessSelection {
    const min_size = @max(@min(@min(bounds_w, bounds_h), 20.0), 0.1);
    switch (mode) {
        .move => {
            const w = @min(original.w, bounds_w);
            const h = @min(original.h, bounds_h);
            const x = clampFloat(original.x + dx, 0.0, @max(bounds_w - w, 0.0));
            const y = clampFloat(original.y + dy, 0.0, @max(bounds_h - h, 0.0));
            return .{ .x = x, .y = y, .w = w, .h = h, .angle = original.angle, .rotation = original.rotation };
        },
        .rotate => return original,
        .draw_frame, .draw_rebate => return original,
        else => {},
    }

    var left = -original.w / 2.0;
    var top = -original.h / 2.0;
    var right = original.w / 2.0;
    var bottom = original.h / 2.0;
    switch (mode) {
        .north_west => {
            left += dx;
            top += dy;
        },
        .north => top += dy,
        .north_east => {
            right += dx;
            top += dy;
        },
        .east => right += dx,
        .south_east => {
            right += dx;
            bottom += dy;
        },
        .south => bottom += dy,
        .south_west => {
            left += dx;
            bottom += dy;
        },
        .west => left += dx,
        .move, .rotate, .draw_frame, .draw_rebate => unreachable,
    }

    if (right - left < min_size) {
        switch (mode) {
            .west, .north_west, .south_west => left = right - min_size,
            else => right = left + min_size,
        }
    }
    if (bottom - top < min_size) {
        switch (mode) {
            .north, .north_west, .north_east => top = bottom - min_size,
            else => bottom = top + min_size,
        }
    }

    if (aspect) |ratio| {
        if (ratio > 0.0) {
            var width = right - left;
            var height = bottom - top;
            if (mode == .north or mode == .south) {
                width = height * ratio;
            } else {
                height = width / ratio;
            }
            width = @max(width, min_size);
            height = @max(height, min_size);
            const center_y = (top + bottom) / 2.0;
            switch (mode) {
                .west, .north_west, .south_west => left = right - width,
                else => right = left + width,
            }
            switch (mode) {
                .north, .north_west, .north_east => top = bottom - height,
                .south, .south_west, .south_east => bottom = top + height,
                .east, .west => {
                    top = center_y - height / 2.0;
                    bottom = center_y + height / 2.0;
                },
                .move, .rotate, .draw_frame, .draw_rebate => unreachable,
            }
        }
    }

    const max_w = @max(bounds_w, min_size);
    const max_h = @max(bounds_h, min_size);
    var new_w = @min(right - left, max_w);
    var new_h = @min(bottom - top, max_h);
    new_w = @max(new_w, min_size);
    new_h = @max(new_h, min_size);

    const local_center_x = (left + right) / 2.0;
    const local_center_y = (top + bottom) / 2.0;
    const original_center = processSelectionCenter(original);
    const cos_a = @cos(original.angle);
    const sin_a = @sin(original.angle);
    const unclamped_center_x = original_center.x + local_center_x * cos_a - local_center_y * sin_a;
    const unclamped_center_y = original_center.y + local_center_x * sin_a + local_center_y * cos_a;
    const center_x = clampSpanCenter(unclamped_center_x, new_w, bounds_w);
    const center_y = clampSpanCenter(unclamped_center_y, new_h, bounds_h);

    return .{
        .x = center_x - new_w / 2.0,
        .y = center_y - new_h / 2.0,
        .w = new_w,
        .h = new_h,
        .angle = original.angle,
        .rotation = original.rotation,
    };
}

fn rotatedProcessSelection(
    original: v600.native_ui.ProcessSelection,
    start_pointer_angle: f64,
    preview_x: f64,
    preview_y: f64,
) v600.native_ui.ProcessSelection {
    var adjusted = original;
    const current_pointer_angle = pointerAngleFromSelectionCenter(original, preview_x, preview_y);
    adjusted.angle = normalizeAngle(original.angle + current_pointer_angle - start_pointer_angle);
    return adjusted;
}

fn normalizeAngle(angle: f64) f64 {
    var normalized = angle;
    const tau = std.math.tau;
    while (normalized > std.math.pi) normalized -= tau;
    while (normalized <= -std.math.pi) normalized += tau;
    return normalized;
}

fn clampSpanCenter(value: f64, span: f64, bounds: f64) f64 {
    if (bounds <= 0.0) return 0.0;
    if (span >= bounds) return bounds / 2.0;
    const half = span / 2.0;
    return clampFloat(value, half, bounds - half);
}

fn clampFloat(value: f64, min_value: f64, max_value: f64) f64 {
    return @min(@max(value, min_value), max_value);
}

fn imagePointOutsideUiChrome(
    image_rect: v600.native_ui.PreviewScreenRect,
    ratio_x: f64,
    ratio_y: f64,
) ?ProcessScreenPoint {
    const min_x = image_rect.x + 20.0;
    const max_x = image_rect.x + image_rect.w - 20.0;
    const min_y = image_rect.y + 20.0;
    const max_y = image_rect.y + image_rect.h - 20.0;
    if (min_x > max_x or min_y > max_y) return null;

    const x = clampFloat(image_rect.x + image_rect.w * ratio_x, min_x, max_x);
    var y = clampFloat(image_rect.y + image_rect.h * ratio_y, min_y, max_y);
    if (pointInFooterBar(x, y)) {
        const footer = footerBarRect();
        y = clampFloat(@as(f64, @floatCast(footer.y)) - 24.0, min_y, max_y);
    }
    if (!pointInUiChrome(x, y)) return .{ .x = x, .y = y };

    const panel = controlPanelRect();
    const gap = 24.0;
    const candidates = [_]ProcessScreenPoint{
        .{ .x = clampFloat(@as(f64, @floatCast(panel.x + panel.w)) + gap, min_x, max_x), .y = y },
        .{ .x = clampFloat(@as(f64, @floatCast(panel.x)) - gap, min_x, max_x), .y = y },
        .{ .x = x, .y = clampFloat(@as(f64, @floatCast(panel.y + panel.h)) + gap, min_y, max_y) },
        .{ .x = x, .y = clampFloat(@as(f64, @floatCast(panel.y)) - gap, min_y, max_y) },
    };
    for (candidates) |candidate| {
        if (candidate.x >= min_x and candidate.x <= max_x and
            candidate.y >= min_y and candidate.y <= max_y and
            !pointInUiChrome(candidate.x, candidate.y))
        {
            return candidate;
        }
    }
    return null;
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
) v600.native_ui.ProcessSelection {
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
    model: *v600.native_ui.State,
    target: ProcessSelectionTarget,
    index: ?usize,
    selection: v600.native_ui.ProcessSelection,
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

fn updateProcessUiLastSelection(ui: *ProcessUiState, selection: v600.native_ui.ProcessSelection) void {
    ui.last_angle = selection.angle;
    ui.last_w = selection.w;
    ui.last_h = selection.h;
    ui.last_rotation = selection.rotation;
}

fn syncProcessExportBasename(ui: *ProcessUiState, model: *const v600.native_ui.State) void {
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
    model: *v600.native_ui.State,
    ui: *ProcessUiState,
    transform: *const v600.native_ui.ProcessViewTransform,
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
    const selection = v600.native_ui.ProcessSelection{
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
    renderer: *c.SDL_Renderer,
    preview: ?PreviewBuffer,
    allocator: std.mem.Allocator,
    io: std.Io,
) !void {
    const image_rect = scanImageRect(renderer, preview) orelse return error.ScanInteractionSmokeFailed;
    model.scan_controls.selection = null;
    model.scan_controls.auto_selection = .{ .x = 10.0, .y = 10.0, .w = 20.0, .h = 20.0 };

    var event: c.SDL_Event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(image_rect.x + image_rect.w * 0.64);
    event.button.y = @floatCast(image_rect.y + image_rect.h * 0.66);
    handleScanSelectionEvent(interaction, model, renderer, preview, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(image_rect.x + image_rect.w * 0.82);
    event.motion.y = @floatCast(image_rect.y + image_rect.h * 0.84);
    handleScanSelectionEvent(interaction, model, renderer, preview, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleScanSelectionEvent(interaction, model, renderer, preview, event);
    const drawn = model.scan_controls.selection orelse return error.ScanInteractionSmokeFailed;
    if (!drawn.isDrawable() or model.scan_controls.auto_selection == null) return error.ScanInteractionSmokeFailed;
    if (model.scanStartPlan("scans/smoke.tiff", null) == null) return error.ScanInteractionSmokeFailed;

    const cfg_dir = ".zig-cache/tmp/v600-native-scan-interaction-smoke";
    const cfg_path = ".zig-cache/tmp/v600-native-scan-interaction-smoke/epdaughter_config.toml";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, cfg_dir) catch {};
    try cwd.createDirPath(io, cfg_dir);
    if (!(try model.saveScannerConfig(allocator, io, cfg_path))) return error.ScanInteractionSmokeFailed;
    const loaded = try v600.scanner.config.loadFile(allocator, io, cfg_path);
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
    handleScanSelectionEvent(interaction, model, renderer, preview, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(center_x + 36.0);
    event.motion.y = @floatCast(center_y + 24.0);
    handleScanSelectionEvent(interaction, model, renderer, preview, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleScanSelectionEvent(interaction, model, renderer, preview, event);
    const moved = model.scan_controls.selection orelse return error.ScanInteractionSmokeFailed;
    if (moved.x <= drawn.x or moved.y <= drawn.y) return error.ScanInteractionSmokeFailed;

    const handle_x = image_rect.x + (moved.x + moved.w) * image_rect.scale;
    const handle_y = image_rect.y + (moved.y + moved.h) * image_rect.scale;
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(handle_x);
    event.button.y = @floatCast(handle_y);
    handleScanSelectionEvent(interaction, model, renderer, preview, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(handle_x + 48.0);
    event.motion.y = @floatCast(handle_y + 32.0);
    handleScanSelectionEvent(interaction, model, renderer, preview, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleScanSelectionEvent(interaction, model, renderer, preview, event);
    const resized = model.scan_controls.selection orelse return error.ScanInteractionSmokeFailed;
    if (resized.w <= moved.w or resized.h <= moved.h) return error.ScanInteractionSmokeFailed;

    event = undefined;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_ESCAPE;
    handleScanShortcutEvent(interaction, model, event);
    if (model.scan_controls.selection != null or model.scan_controls.auto_selection == null) {
        return error.ScanInteractionSmokeFailed;
    }
    if (!model.scan_controls.restoreAutoSelection()) return error.ScanInteractionSmokeFailed;
    if (model.scan_controls.selection == null) return error.ScanInteractionSmokeFailed;
    event = undefined;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_DELETE;
    handleScanShortcutEvent(interaction, model, event);
    if (model.scan_controls.selection != null or model.scan_controls.auto_selection == null) {
        return error.ScanInteractionSmokeFailed;
    }

    model.scan_controls.selection = null;
    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = @floatCast(image_rect.x + image_rect.w * 0.92);
    event.button.y = @floatCast(image_rect.y + image_rect.h * 0.90);
    handleScanSelectionEvent(interaction, model, renderer, preview, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_MOTION;
    event.motion.x = @floatCast(image_rect.x + image_rect.w * 0.921);
    event.motion.y = @floatCast(image_rect.y + image_rect.h * 0.901);
    handleScanSelectionEvent(interaction, model, renderer, preview, event);

    event = undefined;
    event.type = c.SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.button = c.SDL_BUTTON_LEFT;
    handleScanSelectionEvent(interaction, model, renderer, preview, event);
    if (model.scan_controls.selection != null) return error.ScanInteractionSmokeFailed;
}

fn runGalleryInteractionSmokeEvents(transform: *GalleryViewTransform, model: *const v600.native_ui.State) !void {
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
    transform: *v600.native_ui.ProcessViewTransform,
    model: *v600.native_ui.State,
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
    const selection = v600.native_ui.ProcessSelection{
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
    if (bounds.w < v600.native_ui.process_draw_frame_min_size or bounds.h < v600.native_ui.process_draw_frame_min_size) {
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
    model: *v600.native_ui.State,
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
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ".zig-cache/tmp/v600-native-gallery-smoke/roll_03_inv.tif", .data = fixture });

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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
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

fn nkButtonFromSdl(button: u8) ?c_uint {
    return switch (button) {
        c.SDL_BUTTON_LEFT => c.NK_BUTTON_LEFT,
        c.SDL_BUTTON_MIDDLE => c.NK_BUTTON_MIDDLE,
        c.SDL_BUTTON_RIGHT => c.NK_BUTTON_RIGHT,
        else => null,
    };
}

fn nkKeyFromSdl(key: c.SDL_Keycode) ?c_uint {
    return switch (key) {
        c.SDLK_DELETE => c.NK_KEY_DEL,
        c.SDLK_BACKSPACE => c.NK_KEY_BACKSPACE,
        c.SDLK_LEFT => c.NK_KEY_LEFT,
        c.SDLK_RIGHT => c.NK_KEY_RIGHT,
        c.SDLK_ESCAPE => c.NK_KEY_TEXT_RESET_MODE,
        else => null,
    };
}

fn mouseCoord(value: f32) c_int {
    return @intFromFloat(@round(value));
}

fn pointInRect(rect: c.struct_nk_rect, x: f64, y: f64) bool {
    const left: f64 = @floatCast(rect.x);
    const top: f64 = @floatCast(rect.y);
    const right: f64 = @floatCast(rect.x + rect.w);
    const bottom: f64 = @floatCast(rect.y + rect.h);
    return x >= left and x <= right and y >= top and y <= bottom;
}

fn pointInControlPanel(x: f64, y: f64) bool {
    return pointInRect(controlPanelRect(), x, y);
}

fn pointInFooterBar(x: f64, y: f64) bool {
    return pointInRect(footerBarRect(), x, y);
}

fn pointInUiChrome(x: f64, y: f64) bool {
    return pointInControlPanel(x, y) or pointInFooterBar(x, y);
}

fn controlPanelShouldReceiveWheel(event: c.SDL_Event) bool {
    if (event.type != c.SDL_EVENT_MOUSE_WHEEL) return false;
    return pointInControlPanel(
        @as(f64, @floatCast(event.wheel.mouse_x)),
        @as(f64, @floatCast(event.wheel.mouse_y)),
    );
}

fn assertControlPanelPolicy() !void {
    if ((controlPanelFlags() & c.NK_WINDOW_MOVABLE) != 0) return error.ControlPanelIsMovable;
    if ((footerBarFlags() & c.NK_WINDOW_MOVABLE) != 0) return error.FooterBarIsMovable;
    if ((footerBarFlags() & c.NK_WINDOW_NO_INPUT) == 0) return error.FooterBarAcceptsInput;
    const rect = controlPanelRect();
    const left: f64 = @floatCast(rect.x);
    const top: f64 = @floatCast(rect.y);
    const right: f64 = @floatCast(rect.x + rect.w);
    const bottom: f64 = @floatCast(rect.y + rect.h);
    if (!pointInControlPanel(left + 1.0, top + 1.0)) return error.ControlPanelHitPolicyMismatch;
    if (!pointInControlPanel(right, bottom)) return error.ControlPanelHitPolicyMismatch;
    if (pointInControlPanel(left - 1.0, top + 1.0)) return error.ControlPanelHitPolicyMismatch;
    if (pointInControlPanel(right + 1.0, bottom + 1.0)) return error.ControlPanelHitPolicyMismatch;

    var event: c.SDL_Event = undefined;
    event.type = c.SDL_EVENT_MOUSE_WHEEL;
    event.wheel.mouse_x = @floatCast(left + 1.0);
    event.wheel.mouse_y = @floatCast(top + 1.0);
    if (!controlPanelShouldReceiveWheel(event)) return error.ControlPanelWheelPolicyMismatch;
    event.wheel.mouse_x = @floatCast(right + 1.0);
    event.wheel.mouse_y = @floatCast(bottom + 1.0);
    if (controlPanelShouldReceiveWheel(event)) return error.ControlPanelWheelPolicyMismatch;

    const footer = footerBarRect();
    const footer_left: f64 = @floatCast(footer.x);
    const footer_top: f64 = @floatCast(footer.y);
    const footer_right: f64 = @floatCast(footer.x + footer.w);
    const footer_bottom: f64 = @floatCast(footer.y + footer.h);
    if (!pointInFooterBar(footer_left + 1.0, footer_top + 1.0)) return error.FooterBarHitPolicyMismatch;
    if (!pointInUiChrome(footer_right - 1.0, footer_bottom - 1.0)) return error.FooterBarHitPolicyMismatch;
    event.wheel.mouse_x = @floatCast(footer_left + 1.0);
    event.wheel.mouse_y = @floatCast(footer_top + 1.0);
    if (controlPanelShouldReceiveWheel(event)) return error.FooterBarWheelPolicyMismatch;
}

fn drawFooterStatusBar(
    ctx: *c.struct_nk_context,
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
    process_worker: *ProcessWorker,
    export_worker: *ProcessExportWorker,
) []const u8 {
    return switch (model.active_view) {
        .scan => scanFooterStatusText(buffer, model),
        .process => processFooterStatusText(buffer, model, process_worker, export_worker),
        .gallery => galleryFooterStatusText(buffer, model),
    };
}

fn scanFooterStatusText(buffer: []u8, model: *const v600.native_ui.State) []const u8 {
    const status = model.scanStatusDisplay();
    if (model.scanner_progress_percent) |percent| {
        return std.fmt.bufPrint(
            buffer,
            "Scan | {s} | {d}%",
            .{ status, percent },
        ) catch status;
    }
    return std.fmt.bufPrint(buffer, "Scan | {s}", .{status}) catch status;
}

fn processFooterStatusText(
    buffer: []u8,
    model: *v600.native_ui.State,
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
    model: *const v600.native_ui.State,
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

fn galleryFooterStatusText(buffer: []u8, model: *const v600.native_ui.State) []const u8 {
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
    var scan_model = v600.native_ui.State{};
    scan_model.scanner.scanning = true;
    scan_model.scanner_progress_percent = 42;
    const scan_text = footerStatusText(&buffer, &scan_model, process_worker, export_worker);
    if (std.mem.indexOf(u8, scan_text, "Scan | Scanning... | 42%") == null) return error.FooterStatusPolicyMismatch;

    var process_model = v600.native_ui.State{};
    process_model.show(.process);
    process_model.setProcessingProgress("Processing 1 frame...");
    const process_text = footerStatusText(&buffer, &process_model, process_worker, export_worker);
    if (std.mem.indexOf(u8, process_text, "Process | Processing 1 frame... | No scan TIFFs found | Dmin: not set") == null) {
        return error.FooterStatusPolicyMismatch;
    }

    var gallery_model = v600.native_ui.State{};
    gallery_model.show(.gallery);
    gallery_model.setStatus("No exports found");
    const gallery_text = footerStatusText(&buffer, &gallery_model, process_worker, export_worker);
    if (std.mem.indexOf(u8, gallery_text, "Gallery | No exports found | No exported frames") == null) {
        return error.FooterStatusPolicyMismatch;
    }
}

fn drawNavigation(ctx: *c.struct_nk_context, model: *v600.native_ui.State) void {
    layoutRow(ctx, 28.0, 3);
    if (c.nk_option_label(ctx, "Scan", nkBool(model.active_view == .scan)) != 0) model.show(.scan);
    if (c.nk_option_label(ctx, "Process", nkBool(model.active_view == .process)) != 0) model.show(.process);
    if (c.nk_option_label(ctx, "Gallery", nkBool(model.active_view == .gallery)) != 0) model.show(.gallery);
}

fn drawScanView(ctx: *c.struct_nk_context, model: *v600.native_ui.State) void {
    const scanner_busy = model.scannerWorkActive();
    layoutRow(ctx, 28.0, 3);
    if (scanner_busy) c.nk_widget_disable_begin(ctx);
    if (c.nk_button_label(ctx, "Preview") != 0) {
        _ = model.queuePreviewScan("/tmp/v600-native-preview.tiff");
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

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Mode", c.NK_TEXT_LEFT);
    layoutRow(ctx, 28.0, 3);
    if (c.nk_option_label(ctx, "RGB + IR", nkBool(model.scan_controls.mode == .rgb_ir)) != 0) model.scan_controls.setMode(.rgb_ir);
    if (c.nk_option_label(ctx, "RGB", nkBool(model.scan_controls.mode == .rgb)) != 0) model.scan_controls.setMode(.rgb);
    if (c.nk_option_label(ctx, "IR", nkBool(model.scan_controls.mode == .ir)) != 0) model.scan_controls.setMode(.ir);

    const dpis = model.scan_controls.mode.validDpis();
    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "DPI", c.NK_TEXT_LEFT);
    layoutRow(ctx, 28.0, @as(c_int, @intCast(dpis.len)));
    for (dpis) |dpi| {
        if (c.nk_option_label(ctx, dpiLabelZ(dpi), nkBool(model.scan_controls.dpi == dpi)) != 0) {
            model.scan_controls.setDpi(dpi);
        }
    }

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Exposure", c.NK_TEXT_LEFT);
    layoutRow(ctx, 28.0, 2);
    if (c.nk_option_label(ctx, "Linear", nkBool(model.scan_controls.exposure == .linear)) != 0) model.scan_controls.exposure = .linear;
    if (c.nk_option_label(ctx, "Affine", nkBool(model.scan_controls.exposure == .affine)) != 0) model.scan_controls.exposure = .affine;

    layoutRow(ctx, 30.0, 2);
    if (!scanner_busy) {
        if (c.nk_button_label(ctx, "Scan Selection") != 0) _ = model.queueScanStart(".zig-cache/v600-native-scan.cancel");
    } else {
        if (c.nk_button_label(ctx, "Cancel") != 0) model.requestScannerCancel();
    }
    var estimate_buffer: [192]u8 = undefined;
    const estimate_text = v600.native_ui.formatScanSelectionEstimate(
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    ui: *ProcessUiState,
    interaction: *ProcessSelectionInteraction,
    confirmation: *ProcessConfirmation,
    process_worker: *ProcessWorker,
    export_worker: *ProcessExportWorker,
    transform: *const v600.native_ui.ProcessViewTransform,
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
        if (c.nk_button_label(ctx, "Refresh") != 0) {
            refreshAndLoadProcessingImage(model, process_worker, allocator, io, processingPreviewSize(ui)) catch |err| setProcessUiError(model, err);
        }
        if (c.nk_button_label(ctx, "Prev") != 0) {
            startPreviousProcessingImage(model, process_worker, processingPreviewSize(ui)) catch |err| setProcessUiError(model, err);
        }
        if (c.nk_button_label(ctx, "Next") != 0) {
            startNextProcessingImage(model, process_worker, processingPreviewSize(ui)) catch |err| setProcessUiError(model, err);
        }
        if (c.nk_button_label(ctx, "Trash") != 0) {
            requestProcessConfirmation(model, confirmation, allocator, .trash) catch |err| setProcessUiError(model, err);
        }
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
    c.nk_property_int(ctx, "Max px", 512, &ui.preview_size, 8192, 512, 256);
    if (ui.preview_size != old_preview_size) {
        queueProcessIntSetting(model, ui, "preview_size", ui.preview_size);
    }
    var inverted = nkBool(model.processing_preview_inversion_enabled);
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
        if (c.nk_option_text(ctx, option.label.ptr, @intCast(option.label.len), nkBool(ui.aspect_index == index)) != 0) {
            ui.aspect_index = index;
            saveProcessStringSetting(model, allocator, io, config_path, "aspect", option.value) catch |err| setProcessUiError(model, err);
        }
    }
    layoutRow(ctx, 28.0, @intCast(process_format_labels.len));
    for (process_format_labels, 0..) |label, index| {
        if (c.nk_option_label(ctx, label, nkBool(ui.format_index == index)) != 0) {
            ui.format_index = index;
        }
    }
    const old_scale = ui.scale_percent;
    layoutRow(ctx, 28.0, 2);
    c.nk_property_int(ctx, "Frames", 0, &ui.n_frames, 12, 1, 1);
    c.nk_property_float(ctx, "Scale %", -1.0, &ui.scale_percent, 1.0, 0.1, 0.05);
    if (old_scale != ui.scale_percent) {
        model.rescaleProcessAutoSelections(@floatCast(ui.scale_percent));
    }
    layoutRow(ctx, 28.0, 4);
    if (worker_active) {
        c.nk_label(ctx, "Auto Detect", c.NK_TEXT_CENTERED);
    } else if (c.nk_button_label(ctx, "Auto Detect") != 0) {
        startProcessAutoDetect(model, process_worker, config_path, ui) catch |err| setProcessUiError(model, err);
    }
    if (c.nk_button_label(ctx, "Clear") != 0) {
        model.clearProcessingSelections();
        model.setStatus("Selections cleared");
    }
    if (worker_active) {
        c.nk_label(ctx, "Dmin", c.NK_TEXT_CENTERED);
    } else if (c.nk_button_label(ctx, "Dmin") != 0) {
        startProcessRebate(model, process_worker, config_path) catch |err| setProcessUiError(model, err);
    }
    if (c.nk_button_label(ctx, "Dump") != 0) {
        model.dumpProcessSelections() catch |err| setProcessUiError(model, err);
    }
    layoutRow(ctx, 28.0, 2);
    if (c.nk_button_label(ctx, "+ New selection") != 0) {
        addProcessSelectionFromUi(model, ui, transform) catch |err| setProcessUiError(model, err);
    }
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
    drawProcessSelectionControls(ctx, model, ui);

    syncProcessExportBasename(ui, model);
    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Export", c.NK_TEXT_LEFT);
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
    var ir_neg = nkBool(ui.export_ir_neg);
    if (c.nk_checkbox_label(ctx, "IR neg", &ir_neg) != 0) ui.export_ir_neg = ir_neg != 0;
    var ir_inv = nkBool(ui.export_ir_inv);
    if (c.nk_checkbox_label(ctx, "IR inv", &ir_inv) != 0) ui.export_ir_inv = ir_inv != 0;
    var inv_only = nkBool(ui.export_inv_only);
    if (c.nk_checkbox_label(ctx, "Inv only", &inv_only) != 0) ui.export_inv_only = inv_only != 0;
    layoutRow(ctx, 30.0, 1);
    if (export_active) {
        c.nk_label(ctx, "Exporting...", c.NK_TEXT_LEFT);
    } else if (c.nk_button_label(ctx, "Export Selected") != 0) {
        runProcessExport(model, export_worker, ui) catch |err| setProcessUiError(model, err);
    }
}

fn drawProcessImageSelector(
    ctx: *c.struct_nk_context,
    model: *v600.native_ui.State,
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

fn drawProcessSelectionControls(
    ctx: *c.struct_nk_context,
    model: *v600.native_ui.State,
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
            if (c.nk_option_label(ctx, rotation_label, nkBool(selection.rotation == rotation)) != 0) {
                model.process_selections[index].rotation = rotation;
                ui.last_rotation = rotation;
            }
        }
    }
}

fn drawProcessSettingsControls(
    ctx: *c.struct_nk_context,
    model: *v600.native_ui.State,
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
    drawFloatSetting(ctx, model, ui, "Contrast", "render_contrast", &ui.render_contrast, 1.0, 2.0, 0.05);
    drawFloatSetting(ctx, model, ui, "Curve k", "render_curve_k", &ui.render_curve_k, 2.0, 10.0, 0.5);
    drawFloatSetting(ctx, model, ui, "Black %", "render_percentile_lo", &ui.render_percentile_lo, 0.0, 5.0, 0.1);
    drawFloatSetting(ctx, model, ui, "White %", "render_percentile_hi", &ui.render_percentile_hi, 95.0, 100.0, 0.1);
    drawFloatSetting(ctx, model, ui, "Exposure", "exposure_compensation", &ui.exposure_compensation, -0.5, 2.0, 0.05);

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Color Balance", c.NK_TEXT_LEFT);
    drawColorPad(ctx, model, ui);
    drawFloatSetting(ctx, model, ui, "Temp", "color_temp", &ui.color_temp, -1.0, 1.0, 0.05);
    drawFloatSetting(ctx, model, ui, "Tint", "color_tint", &ui.color_tint, -1.0, 1.0, 0.05);
    layoutRow(ctx, 26.0, 1);
    if (c.nk_button_label(ctx, "Reset Color") != 0) {
        ui.color_temp = 0.0;
        ui.color_tint = 0.0;
        queueProcessFloatSetting(model, ui, "color_temp", ui.color_temp);
        queueProcessFloatSetting(model, ui, "color_tint", ui.color_tint);
        commitPendingProcessSettings(model, allocator, io, config_path, ui) catch |err| setProcessUiError(model, err);
    }

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Dust & Scratch", c.NK_TEXT_LEFT);
    drawFloatSetting(ctx, model, ui, "IR thresh", "ir_threshold", &ui.ir_threshold, 0.02, 0.50, 0.01);
    drawFloatSetting(ctx, model, ui, "Hair sens", "ir_hair_sensitivity", &ui.ir_hair_sensitivity, 0.02, 0.30, 0.01);
    drawIntSetting(ctx, model, ui, "Dilate", "ir_dilate_radius", &ui.ir_dilate_radius, 0, 10, 1);
    drawIntSetting(ctx, model, ui, "Close", "ir_close_radius", &ui.ir_close_radius, 0, 15, 1);
    drawIntSetting(ctx, model, ui, "Min area", "ir_min_area", &ui.ir_min_area, 1, 20, 1);
    drawFloatSetting(ctx, model, ui, "Max cov", "ir_max_coverage", &ui.ir_max_coverage, 0.005, 0.10, 0.005);
    drawIntSetting(ctx, model, ui, "Padding", "inpaint_padding", &ui.inpaint_padding, 4, 48, 2);
    if (processSettingsCommitReady(ctx)) {
        commitPendingProcessSettings(model, allocator, io, config_path, ui) catch |err| setProcessUiError(model, err);
    }
}

fn drawProcessStockControls(
    ctx: *c.struct_nk_context,
    model: *v600.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    ui: *ProcessUiState,
) void {
    var stock_buffer: [16]v600.native_ui.ProcessStockChoice = undefined;
    const info = model.processingStocksInfo(&stock_buffer) catch return;
    const active = info.active orelse "";
    layoutRow(ctx, 24.0, 1);
    if (c.nk_option_label(ctx, "(none)", nkBool(active.len == 0)) != 0) {
        selectProcessStock(model, allocator, io, config_path, ui, "") catch |err| setProcessUiError(model, err);
    }
    for (info.stocks) |stock| {
        layoutRow(ctx, 24.0, 1);
        const selected = std.mem.eql(u8, active, stock.name);
        if (c.nk_option_text(ctx, stock.name.ptr, @intCast(stock.name.len), nkBool(selected)) != 0) {
            selectProcessStock(model, allocator, io, config_path, ui, stock.name) catch |err| setProcessUiError(model, err);
        }
    }
}

fn drawColorPad(
    ctx: *c.struct_nk_context,
    model: *v600.native_ui.State,
    ui: *ProcessUiState,
) void {
    layoutRow(ctx, 88.0, 1);
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
    const dot_radius = runtime_ui_config.metrics().color_dot_radius;
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
    model: *v600.native_ui.State,
    ui: *ProcessUiState,
    label: [*:0]const u8,
    name: []const u8,
    value: *f32,
    min: f32,
    max: f32,
    step: f32,
) void {
    const before = value.*;
    layoutRow(ctx, 26.0, 1);
    c.nk_property_float(ctx, label, min, value, max, step, step * 0.25);
    if (@abs(value.* - before) > 0.000001) {
        queueProcessFloatSetting(model, ui, name, value.*);
    }
}

fn drawIntSetting(
    ctx: *c.struct_nk_context,
    model: *v600.native_ui.State,
    ui: *ProcessUiState,
    label: [*:0]const u8,
    name: []const u8,
    value: *c_int,
    min: c_int,
    max: c_int,
    step: c_int,
) void {
    const before = value.*;
    layoutRow(ctx, 26.0, 1);
    c.nk_property_int(ctx, label, min, value, max, step, @floatFromInt(step));
    if (value.* != before) {
        queueProcessIntSetting(model, ui, name, value.*);
    }
}

fn ensureProcessImageLoaded(
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
    process_worker: *ProcessWorker,
    preview_size: i64,
) !void {
    const count = model.processing_images.paths.len;
    if (count == 0) {
        model.setStatus("No images");
        return;
    }
    const index = if (model.processing.image_idx > 0) model.processing.image_idx - 1 else count - 1;
    _ = try process_worker.startLoadIndex(model, index, preview_size);
}

fn startNextProcessingImage(
    model: *v600.native_ui.State,
    process_worker: *ProcessWorker,
    preview_size: i64,
) !void {
    const count = model.processing_images.paths.len;
    if (count == 0) {
        model.setStatus("No images");
        return;
    }
    const index = if (model.processing.image_idx < count - 1) model.processing.image_idx + 1 else 0;
    _ = try process_worker.startLoadIndex(model, index, preview_size);
}

fn startProcessingImageAfterRefresh(
    model: *v600.native_ui.State,
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

fn syncProcessUiFromConfig(ui: *ProcessUiState, model: *const v600.native_ui.State) void {
    ui.preview_size = processSettingInt(model, "preview_size");
    ui.render_contrast = processSettingFloat(model, "render_contrast");
    ui.render_curve_k = processSettingFloat(model, "render_curve_k");
    ui.render_percentile_lo = processSettingFloat(model, "render_percentile_lo");
    ui.render_percentile_hi = processSettingFloat(model, "render_percentile_hi");
    ui.exposure_compensation = processSettingFloat(model, "exposure_compensation");
    ui.color_temp = processSettingFloat(model, "color_temp");
    ui.color_tint = processSettingFloat(model, "color_tint");
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

fn processSettingFloat(model: *const v600.native_ui.State, name: []const u8) f32 {
    if (model.processing_config.value(name)) |value| return @floatCast(value.asFloat());
    if (v600.processing.config.defaultValue(name)) |value| return @floatCast(value.asFloat());
    return 0.0;
}

fn processSettingInt(model: *const v600.native_ui.State, name: []const u8) c_int {
    if (model.processing_config.value(name)) |value| return @intFromFloat(@round(value.asFloat()));
    if (v600.processing.config.defaultValue(name)) |value| return @intFromFloat(@round(value.asFloat()));
    return 0;
}

fn processSettingBool(model: *const v600.native_ui.State, name: []const u8, fallback: bool) bool {
    const value = model.processing_config.value(name) orelse return fallback;
    return switch (value) {
        .boolean => |boolean| boolean,
        else => fallback,
    };
}

fn processSettingString(model: *const v600.native_ui.State, name: []const u8) ?[]const u8 {
    const value = model.processing_config.value(name) orelse return null;
    return switch (value) {
        .string => |string| string.slice(),
        else => null,
    };
}

fn selectProcessStock(
    model: *v600.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    ui: *ProcessUiState,
    stock: []const u8,
) !void {
    const fixed = try v600.processing.config.FixedString.from(stock);
    if (stock.len == 0) {
        const updates = [_]v600.processing.config.Override{
            .{ .name = "stock", .value = .{ .string = fixed } },
        };
        try model.saveProcessingSettings(allocator, io, config_path, &updates);
        return;
    }
    ui.export_ir_inv = true;
    const updates = [_]v600.processing.config.Override{
        .{ .name = "stock", .value = .{ .string = fixed } },
        .{ .name = "export_ir_inv", .value = .{ .boolean = true } },
    };
    try model.saveProcessingSettings(allocator, io, config_path, &updates);
}

fn queueProcessFloatSetting(
    model: *v600.native_ui.State,
    ui: *ProcessUiState,
    name: []const u8,
    value: f32,
) void {
    ui.settings_draft.put(name, .{ .float = @floatCast(value) }) catch |err| setProcessUiError(model, err);
}

fn queueProcessIntSetting(
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    name: []const u8,
    value: []const u8,
) !void {
    const fixed = try v600.processing.config.FixedString.from(value);
    const updates = [_]v600.processing.config.Override{
        .{ .name = name, .value = .{ .string = fixed } },
    };
    try model.saveProcessingSettings(allocator, io, config_path, &updates);
}

fn processingPreviewSize(ui: *const ProcessUiState) i64 {
    return @intCast(@max(ui.preview_size, 1));
}

fn processAutoDetectOptions(ui: *const ProcessUiState) v600.processing.workflow.AutoDetectOptions {
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
    if (ui.last_rotation != v600.native_ui.default_process_output_rotation) return error.ProcessAutoDetectDefaultMismatch;
}

fn validateProcessExportBasenameUiParity(ui: *ProcessUiState, model: *v600.native_ui.State) !void {
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
    model: *v600.native_ui.State,
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
    model: *v600.native_ui.State,
    process_worker: *ProcessWorker,
    config_path: []const u8,
) !void {
    _ = try process_worker.startRebateFromState(model, config_path);
}

fn runProcessExport(
    model: *v600.native_ui.State,
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

fn setProcessUiError(model: *v600.native_ui.State, err: anyerror) void {
    model.setStatus(switch (err) {
        error.NoProcessImageLoaded => "No process image loaded",
        error.InvalidFilmFormat => "Invalid film format",
        error.FileNotFound => "File not found",
        error.AccessDenied => "Access denied",
        else => @errorName(err),
    });
}

fn scanControlsEqual(a: v600.native_ui.ScanControls, b: v600.native_ui.ScanControls) bool {
    return a.dpi == b.dpi and
        a.mode == b.mode and
        a.exposure == b.exposure and
        a.autoselect == b.autoselect and
        selectionsEqual(a.selection, b.selection) and
        selectionsEqual(a.auto_selection, b.auto_selection);
}

fn selectionsEqual(a: ?v600.native_ui.PreviewSelection, b: ?v600.native_ui.PreviewSelection) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.x == b.?.x and
        a.?.y == b.?.y and
        a.?.w == b.?.w and
        a.?.h == b.?.h;
}

const PreviewTextureCache = struct {
    texture: ?*c.SDL_Texture = null,
    data_ptr: ?[*]const u8 = null,
    width: u32 = 0,
    height: u32 = 0,

    fn deinit(self: *PreviewTextureCache) void {
        if (self.texture) |texture| {
            c.SDL_DestroyTexture(texture);
            self.texture = null;
        }
    }

    fn textureFor(self: *PreviewTextureCache, renderer: *c.SDL_Renderer, preview: PreviewBuffer) !*c.SDL_Texture {
        if (self.texture) |texture| {
            if (self.data_ptr == preview.data.ptr and self.width == preview.width and self.height == preview.height) {
                return texture;
            }
            c.SDL_DestroyTexture(texture);
            self.texture = null;
        }

        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_RGB24,
            c.SDL_TEXTUREACCESS_STATIC,
            @intCast(preview.width),
            @intCast(preview.height),
        ) orelse return error.SdlPreviewTextureFailed;
        errdefer c.SDL_DestroyTexture(texture);
        const pitch = try std.math.mul(c_int, @intCast(preview.width), 3);
        if (!c.SDL_UpdateTexture(texture, null, preview.data.ptr, pitch)) {
            return error.SdlPreviewTextureUpdateFailed;
        }
        self.texture = texture;
        self.data_ptr = preview.data.ptr;
        self.width = preview.width;
        self.height = preview.height;
        return texture;
    }
};

const ProcessPreviewTextureCache = struct {
    texture: ?*c.SDL_Texture = null,
    data_ptr: ?[*]const u8 = null,
    width: usize = 0,
    height: usize = 0,
    used_inverted: bool = false,
    texture_key: ?InvertedPreviewKey = null,
    request_key: ?InvertedPreviewKey = null,

    fn deinit(self: *ProcessPreviewTextureCache, allocator: std.mem.Allocator) void {
        self.clearTexture(allocator);
        self.clearRequestKey(allocator);
    }

    fn textureFor(
        self: *ProcessPreviewTextureCache,
        renderer: *c.SDL_Renderer,
        allocator: std.mem.Allocator,
        model: *v600.native_ui.State,
        inverted_preview_worker: *InvertedPreviewWorker,
    ) !*c.SDL_Texture {
        const preview = model.processing_preview orelse return error.NoProcessImageLoaded;
        const requested_inverted = model.processing_preview_inversion_enabled;
        const options = model.processingInvertedPreviewOptions();
        const generation = model.processingGeneration();
        if (requested_inverted) {
            try self.maybeStartInvertedRender(allocator, preview, generation, options, inverted_preview_worker);
        } else {
            self.clearRequestKey(allocator);
        }

        if (self.texture) |texture| {
            if (self.width == preview.preview_width and self.height == preview.preview_height and
                !self.used_inverted and self.data_ptr == preview.preview_rgb8.ptr)
            {
                return texture;
            }
            if (requested_inverted and self.used_inverted) {
                if (self.texture_key) |key| {
                    if (key.matches(preview, generation, options)) return texture;
                }
            }
            self.clearTexture(allocator);
        }

        const texture = try createProcessRgbTexture(renderer, preview.preview_width, preview.preview_height, preview.preview_rgb8);
        self.texture = texture;
        self.data_ptr = preview.preview_rgb8.ptr;
        self.width = preview.preview_width;
        self.height = preview.preview_height;
        self.used_inverted = false;
        return texture;
    }

    fn installInvertedResult(
        self: *ProcessPreviewTextureCache,
        renderer: *c.SDL_Renderer,
        allocator: std.mem.Allocator,
        model: *v600.native_ui.State,
        result: *InvertedPreviewResult,
    ) !bool {
        const preview = model.processing_preview orelse return false;
        const options = model.processingInvertedPreviewOptions();
        if (!model.processing_preview_inversion_enabled or
            !result.key.matches(preview, model.processingGeneration(), options))
        {
            return false;
        }
        const rgb = result.rgb8 orelse return false;
        const expected_len = try std.math.mul(usize, try std.math.mul(usize, preview.preview_width, preview.preview_height), 3);
        if (rgb.len != expected_len) return error.InvalidPreviewBuffer;

        const texture = try createProcessRgbTexture(renderer, preview.preview_width, preview.preview_height, rgb);
        allocator.free(rgb);
        result.rgb8 = null;
        self.clearTexture(allocator);
        self.clearRequestKey(allocator);
        self.texture = texture;
        self.data_ptr = null;
        self.width = preview.preview_width;
        self.height = preview.preview_height;
        self.used_inverted = true;
        self.texture_key = result.key;
        result.key = InvertedPreviewKey.empty();
        return true;
    }

    fn maybeStartInvertedRender(
        self: *ProcessPreviewTextureCache,
        allocator: std.mem.Allocator,
        preview: v600.processing.workflow.QuickPreview,
        generation: usize,
        options: v600.processing.workflow.InvertedPreviewOptions,
        worker: *InvertedPreviewWorker,
    ) !void {
        if (options.stock == null or preview.info.is_grayscale or worker.isRunning()) return;
        if (self.used_inverted) {
            if (self.texture_key) |key| {
                if (key.matches(preview, generation, options)) return;
            }
        }
        if (self.request_key) |key| {
            if (key.matches(preview, generation, options)) return;
        }

        var request_key = try InvertedPreviewKey.initCopy(allocator, preview, generation, options);
        errdefer request_key.deinit(allocator);
        if (try worker.start(preview, generation, options)) {
            self.replaceRequestKey(allocator, &request_key);
        } else {
            request_key.deinit(allocator);
        }
    }

    fn replaceRequestKey(
        self: *ProcessPreviewTextureCache,
        allocator: std.mem.Allocator,
        key: *InvertedPreviewKey,
    ) void {
        self.clearRequestKey(allocator);
        self.request_key = key.*;
        key.* = InvertedPreviewKey.empty();
    }

    fn clearTexture(self: *ProcessPreviewTextureCache, allocator: std.mem.Allocator) void {
        if (self.texture) |texture| {
            c.SDL_DestroyTexture(texture);
            self.texture = null;
        }
        if (self.texture_key) |*key| {
            key.deinit(allocator);
            self.texture_key = null;
        }
        self.data_ptr = null;
        self.width = 0;
        self.height = 0;
        self.used_inverted = false;
    }

    fn clearRequestKey(self: *ProcessPreviewTextureCache, allocator: std.mem.Allocator) void {
        if (self.request_key) |*key| {
            key.deinit(allocator);
            self.request_key = null;
        }
    }
};

fn createProcessRgbTexture(
    renderer: *c.SDL_Renderer,
    width: usize,
    height: usize,
    rgb: []const u8,
) !*c.SDL_Texture {
    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_RGB24,
        c.SDL_TEXTUREACCESS_STATIC,
        @intCast(width),
        @intCast(height),
    ) orelse return error.SdlProcessTextureFailed;
    errdefer c.SDL_DestroyTexture(texture);
    const pitch = try std.math.mul(c_int, @intCast(width), 3);
    if (!c.SDL_UpdateTexture(texture, null, rgb.ptr, pitch)) {
        return error.SdlProcessTextureUpdateFailed;
    }
    return texture;
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

const GalleryViewTransform = struct {
    scale: f64 = 1.0,
    offset_x: f64 = 0.0,
    offset_y: f64 = 0.0,
    panning: bool = false,
    pan_button: u8 = 0,
    pan_start_x: f64 = 0.0,
    pan_start_y: f64 = 0.0,
    needs_fit: bool = true,
    fitted: bool = false,
    key: ?[]u8 = null,
    output_width: c_int = 0,
    output_height: c_int = 0,

    fn deinit(self: *GalleryViewTransform, allocator: std.mem.Allocator) void {
        if (self.key) |key| {
            allocator.free(key);
            self.key = null;
        }
    }

    fn ensureFit(
        self: *GalleryViewTransform,
        allocator: std.mem.Allocator,
        key: []const u8,
        output_width: c_int,
        output_height: c_int,
        image_width: u32,
        image_height: u32,
    ) !void {
        const key_changed = self.key == null or !std.mem.eql(u8, self.key.?, key);
        if (!self.needs_fit and !key_changed and self.output_width == output_width and self.output_height == output_height) return;
        if (key_changed) {
            if (self.key) |old_key| allocator.free(old_key);
            self.key = try allocator.dupe(u8, key);
        }
        self.fit(output_width, output_height, image_width, image_height);
    }

    fn fit(self: *GalleryViewTransform, output_width: c_int, output_height: c_int, image_width: u32, image_height: u32) void {
        const out_w = @as(f64, @floatFromInt(@max(output_width, 1)));
        const out_h = @as(f64, @floatFromInt(@max(output_height, 1)));
        const img_w = @as(f64, @floatFromInt(image_width));
        const img_h = @as(f64, @floatFromInt(image_height));
        self.scale = @min(@min(out_w / img_w, out_h / img_h), 1.0);
        self.offset_x = (out_w - img_w * self.scale) / 2.0;
        self.offset_y = (out_h - img_h * self.scale) / 2.0;
        self.output_width = output_width;
        self.output_height = output_height;
        self.needs_fit = false;
        self.fitted = true;
        self.panning = false;
        self.pan_button = 0;
    }

    fn requestFit(self: *GalleryViewTransform) void {
        self.needs_fit = true;
    }

    fn zoomAt(self: *GalleryViewTransform, x: f64, y: f64, factor: f64) void {
        if (!self.fitted) return;
        self.offset_x = x - (x - self.offset_x) * factor;
        self.offset_y = y - (y - self.offset_y) * factor;
        self.scale *= factor;
    }

    fn beginPan(self: *GalleryViewTransform, x: f64, y: f64, button: u8) void {
        if (!self.fitted) return;
        self.panning = true;
        self.pan_button = button;
        self.pan_start_x = x - self.offset_x;
        self.pan_start_y = y - self.offset_y;
    }

    fn updatePan(self: *GalleryViewTransform, x: f64, y: f64) void {
        if (!self.panning) return;
        self.offset_x = x - self.pan_start_x;
        self.offset_y = y - self.pan_start_y;
    }

    fn endPan(self: *GalleryViewTransform, button: u8) void {
        if (self.pan_button != 0 and self.pan_button != button) return;
        self.panning = false;
        self.pan_button = 0;
    }

    fn isFitted(self: GalleryViewTransform) bool {
        return self.fitted and self.scale > 0.0;
    }

    fn destination(self: GalleryViewTransform, image_width: u32, image_height: u32) c.SDL_FRect {
        return .{
            .x = @floatCast(self.offset_x),
            .y = @floatCast(self.offset_y),
            .w = @floatCast(@as(f64, @floatFromInt(image_width)) * self.scale),
            .h = @floatCast(@as(f64, @floatFromInt(image_height)) * self.scale),
        };
    }
};

const GalleryTextureCache = struct {
    texture: ?*c.SDL_Texture = null,
    key: ?[]u8 = null,
    width: u32 = 0,
    height: u32 = 0,

    fn deinit(self: *GalleryTextureCache, allocator: std.mem.Allocator) void {
        if (self.texture) |texture| {
            c.SDL_DestroyTexture(texture);
            self.texture = null;
        }
        if (self.key) |key| {
            allocator.free(key);
            self.key = null;
        }
    }

    fn textureFor(
        self: *GalleryTextureCache,
        renderer: *c.SDL_Renderer,
        allocator: std.mem.Allocator,
        model: *const v600.native_ui.State,
    ) !?*c.SDL_Texture {
        const name = model.currentGalleryFileName() orelse return null;
        const path = try std.fs.path.join(allocator, &.{ model.processing.output_dir, name });
        defer allocator.free(path);
        if (self.texture) |texture| {
            if (self.key) |key| {
                if (std.mem.eql(u8, key, path)) return texture;
            }
        }

        self.deinit(allocator);
        var image = try v600.tiff.loadRgbPage(allocator, path);
        defer image.deinit(allocator);
        const rgb = try galleryImageRgb8(allocator, image);
        defer allocator.free(rgb);
        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_RGB24,
            c.SDL_TEXTUREACCESS_STATIC,
            @intCast(image.width),
            @intCast(image.height),
        ) orelse return error.SdlGalleryTextureFailed;
        errdefer c.SDL_DestroyTexture(texture);
        const pitch = try std.math.mul(c_int, @intCast(image.width), 3);
        if (!c.SDL_UpdateTexture(texture, null, rgb.ptr, pitch)) {
            return error.SdlGalleryTextureUpdateFailed;
        }
        self.texture = texture;
        self.key = try allocator.dupe(u8, path);
        self.width = image.width;
        self.height = image.height;
        return texture;
    }
};

const gallery_thumb_max_dim = 200;

const GalleryThumbnail = struct {
    name: []u8,
    texture: *c.SDL_Texture,
    width: u32,
    height: u32,

    fn deinit(self: GalleryThumbnail, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        c.SDL_DestroyTexture(self.texture);
    }
};

const GalleryThumbnailCache = struct {
    output_dir: ?[]u8 = null,
    entries: []GalleryThumbnail = &.{},

    fn deinit(self: *GalleryThumbnailCache, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.entries = &.{};
        if (self.output_dir) |output_dir| {
            allocator.free(output_dir);
            self.output_dir = null;
        }
    }

    fn sync(
        self: *GalleryThumbnailCache,
        allocator: std.mem.Allocator,
        output_dir: []const u8,
        files: []const []const u8,
    ) !void {
        if (self.output_dir == null or !std.mem.eql(u8, self.output_dir.?, output_dir)) {
            self.deinit(allocator);
            self.output_dir = try allocator.dupe(u8, output_dir);
        }

        var index: usize = 0;
        while (index < self.entries.len) {
            if (containsGalleryName(files, self.entries[index].name)) {
                index += 1;
                continue;
            }
            self.entries[index].deinit(allocator);
            self.entries[index] = self.entries[self.entries.len - 1];
            self.entries = try resizeThumbnailEntries(allocator, self.entries, self.entries.len - 1);
        }
    }

    fn imageFor(
        self: *GalleryThumbnailCache,
        renderer: *c.SDL_Renderer,
        allocator: std.mem.Allocator,
        output_dir: []const u8,
        name: []const u8,
    ) !c.struct_nk_image {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return nkImageForTexture(entry.texture, entry.width, entry.height);
            }
        }

        const path = try std.fs.path.join(allocator, &.{ output_dir, name });
        defer allocator.free(path);
        var image = try v600.tiff.loadRgbPage(allocator, path);
        defer image.deinit(allocator);
        const rgb = try galleryImageRgb8(allocator, image);
        defer allocator.free(rgb);
        const dimensions = thumbnailDimensions(image.width, image.height);
        const resized = try v600.processing.frames.resizeImageArea(
            allocator,
            rgb,
            @intCast(image.width),
            @intCast(image.height),
            3,
            8,
            @intCast(dimensions.width),
            @intCast(dimensions.height),
        );
        defer allocator.free(resized);
        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_RGB24,
            c.SDL_TEXTUREACCESS_STATIC,
            @intCast(dimensions.width),
            @intCast(dimensions.height),
        ) orelse return error.SdlGalleryThumbnailTextureFailed;
        errdefer c.SDL_DestroyTexture(texture);
        const pitch = try std.math.mul(c_int, @intCast(dimensions.width), 3);
        if (!c.SDL_UpdateTexture(texture, null, resized.ptr, pitch)) {
            return error.SdlGalleryThumbnailTextureUpdateFailed;
        }

        const entry = GalleryThumbnail{
            .name = try allocator.dupe(u8, name),
            .texture = texture,
            .width = dimensions.width,
            .height = dimensions.height,
        };
        errdefer entry.deinit(allocator);
        try self.append(allocator, entry);
        return nkImageForTexture(texture, dimensions.width, dimensions.height);
    }

    fn append(self: *GalleryThumbnailCache, allocator: std.mem.Allocator, entry: GalleryThumbnail) !void {
        const next = try allocator.alloc(GalleryThumbnail, self.entries.len + 1);
        @memcpy(next[0..self.entries.len], self.entries);
        next[self.entries.len] = entry;
        allocator.free(self.entries);
        self.entries = next;
    }
};

fn containsGalleryName(files: []const []const u8, name: []const u8) bool {
    for (files) |file| {
        if (std.mem.eql(u8, file, name)) return true;
    }
    return false;
}

fn resizeThumbnailEntries(
    allocator: std.mem.Allocator,
    entries: []GalleryThumbnail,
    len: usize,
) ![]GalleryThumbnail {
    const next = try allocator.alloc(GalleryThumbnail, len);
    @memcpy(next, entries[0..len]);
    allocator.free(entries);
    return next;
}

const ThumbnailDimensions = struct {
    width: u32,
    height: u32,
};

fn thumbnailDimensions(width: u32, height: u32) ThumbnailDimensions {
    const max_dim = @max(width, height);
    if (max_dim <= gallery_thumb_max_dim) {
        return .{ .width = width, .height = height };
    }
    const scale = @as(f64, @floatFromInt(gallery_thumb_max_dim)) / @as(f64, @floatFromInt(max_dim));
    return .{
        .width = @max(@as(u32, 1), @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(width)) * scale)))),
        .height = @max(@as(u32, 1), @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(height)) * scale)))),
    };
}

fn nkImageForTexture(texture: *c.SDL_Texture, width: u32, height: u32) c.struct_nk_image {
    return c.nk_subimage_handle(
        c.nk_handle_ptr(texture),
        @intCast(width),
        @intCast(height),
        c.nk_rect(0, 0, @floatFromInt(width), @floatFromInt(height)),
    );
}

const UiVertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: c.SDL_FColor,
};

const NuklearRenderer = struct {
    renderer: *c.SDL_Renderer,
    font_texture: *c.SDL_Texture,
    null_texture: c.struct_nk_draw_null_texture,

    fn init(renderer: *c.SDL_Renderer, atlas_pixels: *const anyopaque, width: c_int, height: c_int) !NuklearRenderer {
        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_RGBA32,
            c.SDL_TEXTUREACCESS_STATIC,
            width,
            height,
        ) orelse return error.NuklearFontTextureFailed;
        errdefer c.SDL_DestroyTexture(texture);
        if (!c.SDL_UpdateTexture(texture, null, atlas_pixels, width * 4)) {
            return error.NuklearFontTextureUpdateFailed;
        }
        _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
        return .{
            .renderer = renderer,
            .font_texture = texture,
            .null_texture = undefined,
        };
    }

    fn deinit(self: *NuklearRenderer) void {
        c.SDL_DestroyTexture(self.font_texture);
    }

    fn render(self: *NuklearRenderer, ctx: *c.struct_nk_context) !void {
        var cmds: c.struct_nk_buffer = undefined;
        var vertices: c.struct_nk_buffer = undefined;
        var elements: c.struct_nk_buffer = undefined;
        c.nk_buffer_init_default(&cmds);
        defer c.nk_buffer_free(&cmds);
        c.nk_buffer_init_default(&vertices);
        defer c.nk_buffer_free(&vertices);
        c.nk_buffer_init_default(&elements);
        defer c.nk_buffer_free(&elements);

        const layout = [_]c.struct_nk_draw_vertex_layout_element{
            .{ .attribute = c.NK_VERTEX_POSITION, .format = c.NK_FORMAT_FLOAT, .offset = @offsetOf(UiVertex, "position") },
            .{ .attribute = c.NK_VERTEX_TEXCOORD, .format = c.NK_FORMAT_FLOAT, .offset = @offsetOf(UiVertex, "uv") },
            .{ .attribute = c.NK_VERTEX_COLOR, .format = c.NK_FORMAT_R32G32B32A32_FLOAT, .offset = @offsetOf(UiVertex, "color") },
            .{ .attribute = c.NK_VERTEX_ATTRIBUTE_COUNT, .format = c.NK_FORMAT_COUNT, .offset = 0 },
        };
        const config = c.struct_nk_convert_config{
            .global_alpha = 1.0,
            .line_AA = c.NK_ANTI_ALIASING_ON,
            .shape_AA = c.NK_ANTI_ALIASING_ON,
            .circle_segment_count = 22,
            .arc_segment_count = 22,
            .curve_segment_count = 22,
            .tex_null = self.null_texture,
            .vertex_layout = &layout,
            .vertex_size = @sizeOf(UiVertex),
            .vertex_alignment = @alignOf(UiVertex),
        };
        const convert_result = c.nk_convert(ctx, &cmds, &vertices, &elements, &config);
        if (convert_result != c.NK_CONVERT_SUCCESS) return error.NuklearConvertFailed;

        const vertex_bytes = c.nk_buffer_total(&vertices);
        const element_bytes = c.nk_buffer_total(&elements);
        if (vertex_bytes == 0 or element_bytes == 0) return;
        const vertex_count: c_int = @intCast(vertex_bytes / @sizeOf(UiVertex));
        const vertices_ptr: [*]const UiVertex = @ptrCast(@alignCast(c.nk_buffer_memory_const(&vertices)));
        const elements_ptr: [*]const c.nk_draw_index = @ptrCast(@alignCast(c.nk_buffer_memory_const(&elements)));

        var element_offset: usize = 0;
        var command = c.nk__draw_begin(ctx, &cmds);
        while (command != null) : (command = c.nk__draw_next(command, &cmds, ctx)) {
            const cmd = command.?;
            if (cmd.*.elem_count == 0) continue;
            const clip = c.SDL_Rect{
                .x = @intFromFloat(@max(0.0, @floor(cmd.*.clip_rect.x))),
                .y = @intFromFloat(@max(0.0, @floor(cmd.*.clip_rect.y))),
                .w = @intFromFloat(@max(0.0, @ceil(cmd.*.clip_rect.w))),
                .h = @intFromFloat(@max(0.0, @ceil(cmd.*.clip_rect.h))),
            };
            _ = c.SDL_SetRenderClipRect(self.renderer, &clip);
            const texture: ?*c.SDL_Texture = if (cmd.*.texture.ptr) |ptr|
                @ptrCast(@alignCast(ptr))
            else
                null;
            _ = c.SDL_RenderGeometryRaw(
                self.renderer,
                texture,
                &vertices_ptr[0].position[0],
                @sizeOf(UiVertex),
                &vertices_ptr[0].color,
                @sizeOf(UiVertex),
                &vertices_ptr[0].uv[0],
                @sizeOf(UiVertex),
                vertex_count,
                elements_ptr + element_offset,
                @intCast(cmd.*.elem_count),
                @sizeOf(c.nk_draw_index),
            );
            element_offset += cmd.*.elem_count;
        }
        _ = c.SDL_SetRenderClipRect(self.renderer, null);
    }
};

fn renderPreviewTexture(
    renderer: *c.SDL_Renderer,
    cache: *PreviewTextureCache,
    preview: ?PreviewBuffer,
    model: *const v600.native_ui.State,
) void {
    const image = preview orelse return;
    var out_w: c_int = 0;
    var out_h: c_int = 0;
    if (!c.SDL_GetCurrentRenderOutputSize(renderer, &out_w, &out_h)) return;
    const rect = v600.native_ui.fitPreviewImage(
        image.width,
        image.height,
        @intCast(out_w),
        @intCast(out_h),
        20.0,
    ) orelse return;
    const texture = cache.textureFor(renderer, image) catch return;
    const dst = c.SDL_FRect{
        .x = @floatCast(rect.x),
        .y = @floatCast(rect.y),
        .w = @floatCast(rect.w),
        .h = @floatCast(rect.h),
    };
    _ = c.SDL_RenderTexture(renderer, texture, null, &dst);
    renderSelectionOverlay(renderer, rect, model.scan_controls.selection);
}

fn renderProcessTexture(
    renderer: *c.SDL_Renderer,
    cache: *ProcessPreviewTextureCache,
    inverted_preview_worker: *InvertedPreviewWorker,
    model: *v600.native_ui.State,
    interaction: *const ProcessSelectionInteraction,
    transform: *v600.native_ui.ProcessViewTransform,
) void {
    if (model.processing.loading or model.processing_preview == null) return;
    const rect = processImageRect(renderer, model, transform) orelse return;
    const texture = cache.textureFor(renderer, std.heap.page_allocator, model, inverted_preview_worker) catch return;
    const dst = c.SDL_FRect{
        .x = @floatCast(rect.x),
        .y = @floatCast(rect.y),
        .w = @floatCast(rect.w),
        .h = @floatCast(rect.h),
    };
    _ = c.SDL_RenderTexture(renderer, texture, null, &dst);
    renderProcessSelections(renderer, rect, model, interaction);
}

fn renderGalleryTexture(
    renderer: *c.SDL_Renderer,
    cache: *GalleryTextureCache,
    transform: *GalleryViewTransform,
    model: *v600.native_ui.State,
    allocator: std.mem.Allocator,
) void {
    const texture = cache.textureFor(renderer, allocator, model) catch |err| {
        setGalleryUiError(model, err);
        return;
    } orelse return;
    var out_w: c_int = 0;
    var out_h: c_int = 0;
    if (!c.SDL_GetCurrentRenderOutputSize(renderer, &out_w, &out_h)) return;
    const key = cache.key orelse return;
    transform.ensureFit(allocator, key, out_w, out_h, cache.width, cache.height) catch |err| {
        setGalleryUiError(model, err);
        return;
    };
    const dst = transform.destination(cache.width, cache.height);
    _ = c.SDL_RenderTexture(renderer, texture, null, &dst);
}

fn galleryImageRgb8(allocator: std.mem.Allocator, image: v600.tiff.Image) ![]u8 {
    const pixels = try std.math.mul(usize, image.width, image.height);
    const samples = try std.math.mul(usize, pixels, 3);
    const out = try allocator.alloc(u8, samples);
    errdefer allocator.free(out);

    if (image.samples_per_pixel == 3 and image.bits_per_sample == 8) {
        @memcpy(out, image.data[0..samples]);
        return out;
    }
    if (image.samples_per_pixel == 3 and image.bits_per_sample == 16) {
        for (0..samples) |sample| {
            out[sample] = image.data[sample * 2 + 1];
        }
        return out;
    }
    if (image.samples_per_pixel == 1 and image.bits_per_sample == 8) {
        for (0..pixels) |pixel| {
            const value = image.data[pixel];
            out[pixel * 3 + 0] = value;
            out[pixel * 3 + 1] = value;
            out[pixel * 3 + 2] = value;
        }
        return out;
    }
    if (image.samples_per_pixel == 1 and image.bits_per_sample == 16) {
        for (0..pixels) |pixel| {
            const value = image.data[pixel * 2 + 1];
            out[pixel * 3 + 0] = value;
            out[pixel * 3 + 1] = value;
            out[pixel * 3 + 2] = value;
        }
        return out;
    }
    return error.UnsupportedGalleryImage;
}

fn renderSelectionOverlay(
    renderer: *c.SDL_Renderer,
    image_rect: v600.native_ui.PreviewScreenRect,
    selection: ?v600.native_ui.PreviewSelection,
) void {
    const sel = selection orelse return;
    if (!sel.isDrawable()) return;
    const x = image_rect.x + sel.x * image_rect.scale;
    const y = image_rect.y + sel.y * image_rect.scale;
    const w = sel.w * image_rect.scale;
    const h = sel.h * image_rect.scale;
    if (w <= 0.0 or h <= 0.0) return;

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 128);
    const dim_rects = [_]c.SDL_FRect{
        .{ .x = @floatCast(image_rect.x), .y = @floatCast(image_rect.y), .w = @floatCast(image_rect.w), .h = @floatCast(y - image_rect.y) },
        .{ .x = @floatCast(image_rect.x), .y = @floatCast(y), .w = @floatCast(x - image_rect.x), .h = @floatCast(h) },
        .{ .x = @floatCast(x + w), .y = @floatCast(y), .w = @floatCast((image_rect.x + image_rect.w) - (x + w)), .h = @floatCast(h) },
        .{ .x = @floatCast(image_rect.x), .y = @floatCast(y + h), .w = @floatCast(image_rect.w), .h = @floatCast((image_rect.y + image_rect.h) - (y + h)) },
    };
    _ = c.SDL_RenderFillRects(renderer, &dim_rects, @intCast(dim_rects.len));

    _ = c.SDL_SetRenderDrawColor(renderer, 34, 221, 102, 255);
    const border = c.SDL_FRect{ .x = @floatCast(x), .y = @floatCast(y), .w = @floatCast(w), .h = @floatCast(h) };
    _ = c.SDL_RenderRect(renderer, &border);
    renderSelectionHandles(renderer, x, y, w, h);
}

fn renderProcessSelections(
    renderer: *c.SDL_Renderer,
    image_rect: v600.native_ui.PreviewScreenRect,
    model: *const v600.native_ui.State,
    interaction: *const ProcessSelectionInteraction,
) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    for (model.process_selections[0..model.process_selection_count], 0..) |selection, index| {
        const active = if (model.process_active_selection) |active_index| active_index == index else index == 0;
        const color = if (active)
            sdlColor(34, 221, 102, 255)
        else
            sdlColor(34, 160, 221, 220);
        renderProcessSelectionRect(renderer, image_rect, selection, active, color);
    }
    if (model.process_rebate_rect) |rebate| {
        const color = sdlColor(255, 184, 77, 255);
        renderProcessSelectionRect(renderer, image_rect, rebate, interaction.rebate_active, color);
    }
}

fn renderProcessSelectionRect(
    renderer: *c.SDL_Renderer,
    image_rect: v600.native_ui.PreviewScreenRect,
    selection: v600.native_ui.ProcessSelection,
    show_handles: bool,
    color: c.SDL_FColor,
) void {
    if (selection.w <= 0.0 or selection.h <= 0.0) return;
    const corners = processSelectionScreenCorners(image_rect, selection);
    for (0..corners.len) |index| {
        const next = (index + 1) % corners.len;
        renderAntialiasedLine(
            renderer,
            corners[index].x,
            corners[index].y,
            corners[next].x,
            corners[next].y,
            process_selection_line_width,
            process_selection_antialias_width,
            color,
        );
    }
    _ = c.SDL_SetRenderDrawColor(
        renderer,
        @intFromFloat(@round(color.r * 255.0)),
        @intFromFloat(@round(color.g * 255.0)),
        @intFromFloat(@round(color.b * 255.0)),
        @intFromFloat(@round(color.a * 255.0)),
    );
    if (show_handles) renderProcessSelectionHandles(renderer, image_rect, selection);
}

fn renderAntialiasedLine(
    renderer: *c.SDL_Renderer,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    width: f32,
    aa_width: f32,
    color: c.SDL_FColor,
) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= 0.000001) return;

    const nx = -dy / len;
    const ny = dx / len;
    const half = @max(@as(f64, @floatCast(width)) * 0.5, 0.5);
    const aa = @max(@as(f64, @floatCast(aa_width)), 0.0);
    renderLineQuad(renderer, x0, y0, x1, y1, nx, ny, -half, half, color, color);
    if (aa > 0.0) {
        var transparent = color;
        transparent.a = 0.0;
        renderLineQuad(renderer, x0, y0, x1, y1, nx, ny, half, half + aa, color, transparent);
        renderLineQuad(renderer, x0, y0, x1, y1, nx, ny, -half - aa, -half, transparent, color);
    }
}

fn renderLineQuad(
    renderer: *c.SDL_Renderer,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    nx: f64,
    ny: f64,
    offset_a: f64,
    offset_b: f64,
    color_a: c.SDL_FColor,
    color_b: c.SDL_FColor,
) void {
    const vertices = [_]c.SDL_Vertex{
        sdlVertex(x0 + nx * offset_a, y0 + ny * offset_a, color_a),
        sdlVertex(x1 + nx * offset_a, y1 + ny * offset_a, color_a),
        sdlVertex(x1 + nx * offset_b, y1 + ny * offset_b, color_b),
        sdlVertex(x0 + nx * offset_b, y0 + ny * offset_b, color_b),
    };
    const indices = [_]c_int{ 0, 1, 2, 0, 2, 3 };
    _ = c.SDL_RenderGeometry(renderer, null, &vertices, @intCast(vertices.len), &indices, @intCast(indices.len));
}

fn sdlVertex(x: f64, y: f64, color: c.SDL_FColor) c.SDL_Vertex {
    return .{
        .position = .{ .x = @floatCast(x), .y = @floatCast(y) },
        .color = color,
        .tex_coord = .{ .x = 0.0, .y = 0.0 },
    };
}

fn sdlColor(r: u8, g: u8, b: u8, a: u8) c.SDL_FColor {
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = @as(f32, @floatFromInt(a)) / 255.0,
    };
}

fn renderSelectionHandles(renderer: *c.SDL_Renderer, x: f64, y: f64, w: f64, h: f64) void {
    const handle_size = 8.0;
    const half = handle_size / 2.0;
    const mx = x + w / 2.0;
    const my = y + h / 2.0;
    const points = [_][2]f64{
        .{ x, y },      .{ mx, y },        .{ x + w, y },
        .{ x + w, my }, .{ x + w, y + h }, .{ mx, y + h },
        .{ x, y + h },  .{ x, my },
    };
    var rects: [points.len]c.SDL_FRect = undefined;
    for (points, 0..) |point, i| {
        rects[i] = .{
            .x = @floatCast(point[0] - half),
            .y = @floatCast(point[1] - half),
            .w = @floatCast(handle_size),
            .h = @floatCast(handle_size),
        };
    }
    _ = c.SDL_RenderFillRects(renderer, &rects, @intCast(rects.len));
}

fn processSelectionScreenCorners(
    image_rect: v600.native_ui.PreviewScreenRect,
    selection: v600.native_ui.ProcessSelection,
) [4]ProcessScreenPoint {
    const half_w = selection.w / 2.0;
    const half_h = selection.h / 2.0;
    return .{
        selectionLocalToScreen(image_rect, selection, -half_w, -half_h),
        selectionLocalToScreen(image_rect, selection, half_w, -half_h),
        selectionLocalToScreen(image_rect, selection, half_w, half_h),
        selectionLocalToScreen(image_rect, selection, -half_w, half_h),
    };
}

fn renderProcessSelectionHandles(
    renderer: *c.SDL_Renderer,
    image_rect: v600.native_ui.PreviewScreenRect,
    selection: v600.native_ui.ProcessSelection,
) void {
    const handle_size = 8.0;
    const half_handle = handle_size / 2.0;
    const half_w = selection.w / 2.0;
    const half_h = selection.h / 2.0;
    const resize_points = [_]ProcessScreenPoint{
        selectionLocalToScreen(image_rect, selection, -half_w, -half_h),
        selectionLocalToScreen(image_rect, selection, 0.0, -half_h),
        selectionLocalToScreen(image_rect, selection, half_w, -half_h),
        selectionLocalToScreen(image_rect, selection, half_w, 0.0),
        selectionLocalToScreen(image_rect, selection, half_w, half_h),
        selectionLocalToScreen(image_rect, selection, 0.0, half_h),
        selectionLocalToScreen(image_rect, selection, -half_w, half_h),
        selectionLocalToScreen(image_rect, selection, -half_w, 0.0),
    };
    var rects: [resize_points.len]c.SDL_FRect = undefined;
    for (resize_points, 0..) |point, i| {
        rects[i] = .{
            .x = @floatCast(point.x - half_handle),
            .y = @floatCast(point.y - half_handle),
            .w = @floatCast(handle_size),
            .h = @floatCast(handle_size),
        };
    }
    _ = c.SDL_RenderFillRects(renderer, &rects, @intCast(rects.len));

    const offset = processRotationHandleOffsetPreview(image_rect);
    const rotate_points = [_]struct {
        base_x: f64,
        base_y: f64,
        handle_x: f64,
        handle_y: f64,
    }{
        .{ .base_x = 0.0, .base_y = -half_h, .handle_x = 0.0, .handle_y = -half_h - offset },
        .{ .base_x = 0.0, .base_y = half_h, .handle_x = 0.0, .handle_y = half_h + offset },
        .{ .base_x = -half_w, .base_y = 0.0, .handle_x = -half_w - offset, .handle_y = 0.0 },
        .{ .base_x = half_w, .base_y = 0.0, .handle_x = half_w + offset, .handle_y = 0.0 },
    };
    for (rotate_points) |points| {
        const base = selectionLocalToScreen(image_rect, selection, points.base_x, points.base_y);
        const handle = selectionLocalToScreen(image_rect, selection, points.handle_x, points.handle_y);
        _ = c.SDL_RenderLine(
            renderer,
            @floatCast(base.x),
            @floatCast(base.y),
            @floatCast(handle.x),
            @floatCast(handle.y),
        );
        const rotate_rect = c.SDL_FRect{
            .x = @floatCast(handle.x - 5.0),
            .y = @floatCast(handle.y - 5.0),
            .w = 10.0,
            .h = 10.0,
        };
        _ = c.SDL_RenderRect(renderer, &rotate_rect);
    }
}

fn nkBool(value: bool) c.nk_bool {
    return if (value) 1 else 0;
}

fn drawText(ctx: *c.struct_nk_context, text: []const u8) void {
    c.nk_text(ctx, text.ptr, @intCast(text.len), c.NK_TEXT_LEFT);
}

fn setGalleryUiError(model: *v600.native_ui.State, err: anyerror) void {
    model.setStatus(switch (err) {
        error.NoGalleryFileSelected => "No exports found",
        error.FileNotFound => "File not found",
        error.AccessDenied => "Access denied",
        error.InvalidGalleryImageIndex => "Invalid index",
        else => @errorName(err),
    });
}

fn dpiLabelZ(dpi: u32) [*:0]const u8 {
    return switch (dpi) {
        800 => "800",
        1200 => "1200",
        1600 => "1600",
        3200 => "3200",
        6400 => "6400",
        else => "unknown",
    };
}
