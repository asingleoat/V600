const std = @import("std");

const app_state = @import("../app_state.zig");
const processing_config = @import("../processing/config.zig");
const processing_export = @import("../processing/export.zig");
const processing_events = @import("../processing/events.zig");
const processing_frames = @import("../processing/frames.zig");
const processing_webgpu = @import("../processing/webgpu.zig");
const processing_workflow = @import("../processing/workflow.zig");
const scanner_config = @import("../scanner/config.zig");
const scanner_contracts = @import("../scanner/contracts.zig");
const scanner_events = @import("../scanner/events.zig");
const process_cache = @import("process_cache.zig");
const scan_workflow = @import("scan_workflow.zig");
const tiff = @import("../tiff.zig");

pub const ScanControls = scan_workflow.ScanControls;
pub const ScanMode = scan_workflow.ScanMode;
pub const ExposureMode = scan_workflow.ExposureMode;
pub const PreviewSelection = scan_workflow.PreviewSelection;
pub const PreviewSelectionEditMode = scan_workflow.PreviewSelectionEditMode;
pub const PreviewScreenRect = scan_workflow.PreviewScreenRect;
pub const ScanAreaInches = scan_workflow.AreaInches;
pub const PreviewScanPlan = scan_workflow.PreviewScanPlan;
pub const ScanStartPlan = scan_workflow.ScanStartPlan;
pub const previewSelectionFromDraw = scan_workflow.previewSelectionFromDraw;
pub const adjustedPreviewSelection = scan_workflow.adjustedPreviewSelection;
pub const scanSelectionEstimate = scan_workflow.scanSelectionEstimate;
pub const formatScanSelectionEstimate = scan_workflow.formatScanSelectionEstimate;
pub const handleScanFormatEta = scan_workflow.handleScanFormatEta;
pub const detectFilmAreaSelection = scan_workflow.detectFilmAreaSelection;

pub const PreviewImageInfo = struct {
    output_path: []const u8,
    width: usize,
    height: usize,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    data_len: usize,
};

pub const ProcessNavigationInfo = struct {
    filename: []const u8,
    image_idx: usize,
    image_count: usize,
    loading: bool,
    preview_ready: bool,
    can_navigate: bool,
    progress: []const u8,
    status: []const u8,
};

pub const ProcessPreviewResponse = struct {
    jpeg: []u8,
    used_inverted: bool,
    fell_back_to_quick: bool,

    pub fn deinit(self: ProcessPreviewResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.jpeg);
    }
};

pub fn stableScannerCapabilities(
    capabilities: scanner_contracts.ScannerCapabilities,
) scanner_contracts.ScannerCapabilities {
    return .{
        .device_name = "",
        .model = if (capabilities.known_model) |known| known.name else "Epson scanner",
        .known_model = capabilities.known_model,
        .optical_dpi = capabilities.optical_dpi,
        .max_resolution = capabilities.max_resolution,
        .flatbed_width_in = capabilities.flatbed_width_in,
        .flatbed_height_in = capabilities.flatbed_height_in,
        .tpu_width_in = capabilities.tpu_width_in,
        .tpu_height_in = capabilities.tpu_height_in,
        .ir_supported = capabilities.ir_supported,
    };
}

pub const ProcessSelection = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    angle: f64 = 0.0,
    rotation: i32 = 0,
};

pub const default_process_output_rotation: i32 = 270;

/// Frames saved for an image (a roll strip's framing file), in
/// full-resolution pixels.
pub const ProcessFraming = struct {
    frames: [64]processing_export.FrameRect = undefined,
    count: usize = 0,
    rebate: ?processing_frames.RebateOriginRect = null,
};

/// The Process view's frames and rebate at one moment, for undo and for
/// telling hand edits from what the app set.
pub const ProcessSelectionsSnapshot = struct {
    selections: [64]ProcessSelection = undefined,
    count: usize = 0,
    rebate: ?app_state.RebateRect = null,
    rebate_preview: ?ProcessSelection = null,

    fn sameAs(self: *const ProcessSelectionsSnapshot, other: *const ProcessSelectionsSnapshot) bool {
        if (self.count != other.count) return false;
        for (self.selections[0..self.count], other.selections[0..other.count]) |a, b| {
            if (!std.meta.eql(a, b)) return false;
        }
        return std.meta.eql(self.rebate, other.rebate);
    }
};

/// Edits count as settled once nothing has changed for this long.
pub const process_edit_settle_ms: u64 = 600;
const process_undo_depth = 32;
pub const process_draw_frame_min_size: f64 = 10.0;

pub const ProcessDrawnFrameFinalization = enum {
    invalid_index,
    removed_too_small,
    accepted,
};

pub fn processDrawnFrameAccepted(selection: ProcessSelection) bool {
    return selection.w >= process_draw_frame_min_size and selection.h >= process_draw_frame_min_size;
}

pub const ProcessViewPoint = struct {
    x: f64,
    y: f64,
};

pub const ProcessViewTransform = struct {
    scale: f64 = 1.0,
    offset_x: f64 = 0.0,
    offset_y: f64 = 0.0,
    panning: bool = false,
    pan_button: u8 = 0,
    pan_start_x: f64 = 0.0,
    pan_start_y: f64 = 0.0,
    needs_fit: bool = true,
    fitted: bool = false,
    key_buffer: [std.fs.max_path_bytes]u8 = [_]u8{0} ** std.fs.max_path_bytes,
    key_len: usize = 0,
    output_width: usize = 0,
    output_height: usize = 0,
    /// Top-left of the area the image is fitted into (the canvas beside the
    /// control panel); `output_width` and `output_height` are its size.
    area_x: f64 = 0.0,
    area_y: f64 = 0.0,

    pub fn ensureFit(
        self: *ProcessViewTransform,
        key: []const u8,
        output_width: usize,
        output_height: usize,
        image_width: usize,
        image_height: usize,
    ) void {
        self.ensureFitIn(key, 0.0, 0.0, output_width, output_height, image_width, image_height);
    }

    /// Fits the image into the area at (`area_x`, `area_y`) of the given size
    /// when the key or the area changes.
    pub fn ensureFitIn(
        self: *ProcessViewTransform,
        key: []const u8,
        area_x: f64,
        area_y: f64,
        output_width: usize,
        output_height: usize,
        image_width: usize,
        image_height: usize,
    ) void {
        const current_key = self.key_buffer[0..self.key_len];
        const key_changed = !std.mem.eql(u8, current_key, key);
        if (!self.needs_fit and !key_changed and
            self.output_width == output_width and self.output_height == output_height and
            self.area_x == area_x and self.area_y == area_y)
        {
            return;
        }
        self.area_x = area_x;
        self.area_y = area_y;
        if (key_changed) {
            const len = @min(key.len, self.key_buffer.len);
            @memcpy(self.key_buffer[0..len], key[0..len]);
            self.key_len = len;
        }
        self.fit(output_width, output_height, image_width, image_height);
    }

    pub fn fit(
        self: *ProcessViewTransform,
        output_width: usize,
        output_height: usize,
        image_width: usize,
        image_height: usize,
    ) void {
        if (output_width == 0 or output_height == 0 or image_width == 0 or image_height == 0) return;
        const out_w = @as(f64, @floatFromInt(output_width));
        const out_h = @as(f64, @floatFromInt(output_height));
        const img_w = @as(f64, @floatFromInt(image_width));
        const img_h = @as(f64, @floatFromInt(image_height));
        self.scale = @min(out_w / img_w, out_h / img_h) * 0.95;
        self.offset_x = self.area_x + (out_w - img_w * self.scale) / 2.0;
        self.offset_y = self.area_y + (out_h - img_h * self.scale) / 2.0;
        self.output_width = output_width;
        self.output_height = output_height;
        self.needs_fit = false;
        self.fitted = true;
        self.panning = false;
        self.pan_button = 0;
    }

    pub fn requestFit(self: *ProcessViewTransform) void {
        self.needs_fit = true;
    }

    pub fn zoomAt(self: *ProcessViewTransform, x: f64, y: f64, factor: f64) void {
        if (!self.fitted or factor <= 0.0) return;
        self.offset_x = x - (x - self.offset_x) * factor;
        self.offset_y = y - (y - self.offset_y) * factor;
        self.scale *= factor;
    }

    pub fn beginPan(self: *ProcessViewTransform, x: f64, y: f64, button: u8) void {
        if (!self.fitted) return;
        self.panning = true;
        self.pan_button = button;
        self.pan_start_x = x - self.offset_x;
        self.pan_start_y = y - self.offset_y;
    }

    pub fn updatePan(self: *ProcessViewTransform, x: f64, y: f64) void {
        if (!self.panning) return;
        self.offset_x = x - self.pan_start_x;
        self.offset_y = y - self.pan_start_y;
    }

    pub fn endPan(self: *ProcessViewTransform, button: u8) void {
        if (self.pan_button != 0 and self.pan_button != button) return;
        self.panning = false;
        self.pan_button = 0;
    }

    pub fn imageRect(self: ProcessViewTransform, image_width: usize, image_height: usize) PreviewScreenRect {
        return .{
            .x = self.offset_x,
            .y = self.offset_y,
            .w = @as(f64, @floatFromInt(image_width)) * self.scale,
            .h = @as(f64, @floatFromInt(image_height)) * self.scale,
            .scale = self.scale,
        };
    }

    pub fn screenToPreview(self: ProcessViewTransform, screen_x: f64, screen_y: f64) ProcessViewPoint {
        return .{
            .x = (screen_x - self.offset_x) / self.scale,
            .y = (screen_y - self.offset_y) / self.scale,
        };
    }

    pub fn screenToPreviewClamped(
        self: ProcessViewTransform,
        screen_x: f64,
        screen_y: f64,
        image_width: f64,
        image_height: f64,
    ) ProcessViewPoint {
        const point = self.screenToPreview(screen_x, screen_y);
        return .{
            .x = clampFloat(point.x, 0.0, image_width),
            .y = clampFloat(point.y, 0.0, image_height),
        };
    }

    pub fn viewportCenterPreview(self: ProcessViewTransform, image_width: f64, image_height: f64) ProcessViewPoint {
        if (!self.fitted or self.scale <= 0.0 or self.output_width == 0 or self.output_height == 0) {
            return .{ .x = image_width / 2.0, .y = image_height / 2.0 };
        }
        const screen_x = @as(f64, @floatFromInt(self.output_width)) / 2.0;
        const screen_y = @as(f64, @floatFromInt(self.output_height)) / 2.0;
        return self.screenToPreviewClamped(screen_x, screen_y, image_width, image_height);
    }
};

fn clampFloat(value: f64, min_value: f64, max_value: f64) f64 {
    return @min(@max(value, min_value), max_value);
}

pub const ProcessRebateInfo = struct {
    preview_rect: ?ProcessSelection,
    full_rect: ?app_state.RebateRect,
    has_dmin: bool,
    dmin: ?[3]f64,
    dmin_display: []const u8,
};

pub const ProcessExportControls = struct {
    basename: []const u8 = "",
    export_ir_neg: bool = false,
    export_ir_inv: bool = true,
    export_inv_only: bool = false,

    pub fn outputSelection(self: ProcessExportControls) processing_export.OutputSelection {
        return .{
            .ir_neg = self.export_ir_neg,
            .ir_inv = self.export_ir_inv,
            .inv_only = self.export_inv_only,
        };
    }
};

pub const ProcessExportStatus = struct {
    exporting: bool,
    files_written: usize,
    status: []const u8,
};

pub const ProcessImageMutation = struct {
    message: []const u8,
    image_idx: usize,
    image_count: usize,
    switched: bool,
};

pub const GalleryInfo = struct {
    files: [][]u8,
    active_index: ?usize,
    image_count: usize,
    filename: []const u8,
    can_navigate: bool,
    status: []const u8,
};

pub const ProcessSettingsInfo = struct {
    entries: []const processing_config.Entry,
    active_stock: ?[]const u8,
    preview_inversion: bool,
};

pub const ProcessSettingsDraft = struct {
    entries: [32]processing_config.Override = undefined,
    len: usize = 0,

    pub fn put(self: *ProcessSettingsDraft, name: []const u8, value: processing_config.Value) !void {
        for (self.entries[0..self.len]) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.value = value;
                return;
            }
        }
        if (self.len >= self.entries.len) return error.TooManyPendingProcessSettings;
        self.entries[self.len] = .{ .name = name, .value = value };
        self.len += 1;
    }

    pub fn pending(self: *const ProcessSettingsDraft) []const processing_config.Override {
        return self.entries[0..self.len];
    }

    pub fn clear(self: *ProcessSettingsDraft) void {
        self.len = 0;
    }
};

pub const ProcessStockChoice = struct {
    name: []const u8,
    description: []const u8,
};

pub const ProcessStocksInfo = struct {
    active: ?[]const u8,
    stocks: []const ProcessStockChoice,
};

pub const ProcessingBackendEvent = union(enum) {
    export_start: processing_events.ExportStartEvent,
    export_progress: processing_events.ExportProgressEvent,
    file_written: processing_events.FileWrittenEvent,
    export_complete: processing_events.ExportCompleteEvent,
    export_cancelled: processing_events.ExportCancelledEvent,
    processing_error: processing_events.ProcessingErrorEvent,
};

pub const ScannerBackendEvent = union(enum) {
    scan_start: scanner_events.ScanStartEvent,
    progress: scanner_events.ProgressEvent,
    scan_complete: scanner_events.ScanCompleteEvent,
    scan_cancelled: scanner_events.ScanFailureEvent,
    scan_error: scanner_events.ScanFailureEvent,
    timing: scanner_events.TimingEvent,
};

pub const Command = union(enum) {
    preview_scan: PreviewScanPlan,
    scan_start: ScanStartPlan,
};

pub const View = enum {
    scan,
    process,
    gallery,

    pub fn title(self: View) []const u8 {
        return switch (self) {
            .scan => "Scan",
            .process => "Process",
            .gallery => "Gallery",
        };
    }

    pub fn titleZ(self: View) [*:0]const u8 {
        return switch (self) {
            .scan => "Scan",
            .process => "Process",
            .gallery => "Gallery",
        };
    }
};

pub const State = struct {
    active_view: View = .scan,
    scan_controls: ScanControls = .{},
    scanner: app_state.ScannerState = .{},
    processing: app_state.ProcessingState = .{},
    processing_config: processing_config.LoadedConfig = .{},
    processing_images: tiff.ImageList = .{ .paths = &.{} },
    gallery_files: processing_export.GalleryFileList = .{ .files = &.{} },
    processing_preview: ?processing_workflow.QuickPreview = null,
    processing_inverted_cache: processing_workflow.InvertedPreviewCache = .{},
    processing_result_cache: process_cache.ProcessResultCache = .{},
    status: []const u8 = "",
    quit_requested: bool = false,
    preview_requested: bool = false,
    preview_ready: bool = false,
    preview_image: ?PreviewImageInfo = null,
    scanner_capabilities: ?scanner_contracts.ScannerCapabilities = null,
    scanner_progress_percent: ?u8 = null,
    scan_started_ms: ?u64 = null,
    scan_pass_started_ms: ?u64 = null,
    scan_ir_pass: bool = false,
    scan_eta_seconds: ?f64 = null,
    scan_finished_pending: bool = false,
    reconnect_requested: bool = false,
    scanner_timing_stage: []const u8 = "",
    scanner_timing_elapsed_us: u64 = 0,
    scanner_timing_detail: ?[]const u8 = null,
    scanner_timing_count: usize = 0,
    pending_command: ?Command = null,
    scan_output_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    scan_status_buffer: [256]u8 = undefined,
    scanner_timing_stage_buffer: [96]u8 = undefined,
    scanner_timing_detail_buffer: [128]u8 = undefined,
    active_scan_mode: ?ScanMode = null,
    /// The selection being scanned, fixed when the scan starts.
    active_scan_selection: ?PreviewSelection = null,
    active_scan_dpi: u32 = 0,
    pending_config_selection: ?ScanAreaInches = null,
    processing_preview_inversion_enabled: bool = false,
    process_selections: [64]ProcessSelection = undefined,
    process_selection_count: usize = 0,
    process_active_selection: ?usize = null,
    process_last_auto_frames: [64]processing_frames.FrameRect = undefined,
    process_last_auto_count: usize = 0,
    process_last_rotation: i32 = default_process_output_rotation,
    process_rebate_rect: ?ProcessSelection = null,
    /// Frames saved for the loaded image, laid over its first auto-detect.
    process_saved_framing: ?ProcessFraming = null,
    process_saved_framing_unapplied: bool = false,
    /// Set when frames with their own rebate were restored, so the UI
    /// remeasures Dmin from it.
    process_rebate_dmin_pending: bool = false,
    /// The frames as the app last set them or as the last settled edit left
    /// them; anything different is an edit in progress.
    process_baseline: ProcessSelectionsSnapshot = .{},
    process_edit_hash: u64 = 0,
    process_edit_changed_ms: u64 = 0,
    /// The frames are a hand choice (a settled edit or an undo) not yet
    /// saved for the image.
    process_framing_dirty: bool = false,
    process_undo: [process_undo_depth]ProcessSelectionsSnapshot = undefined,
    process_undo_len: usize = 0,
    process_auto_detect_pending: bool = false,
    process_exporting: bool = false,
    process_export_files_written: usize = 0,
    process_status_buffer: [128]u8 = undefined,
    process_dmin_buffer: [64]u8 = undefined,
    processing_gpu_request: processing_webgpu.Request = .{},
    processing_generation: usize = 0,
    gallery_index: usize = 0,

    pub fn init(scan_dir: []const u8, output_dir: []const u8, image_count: usize) State {
        return .{
            .scanner = .{ .output_dir = scan_dir },
            .processing = app_state.ProcessingState.init(scan_dir, output_dir, image_count),
        };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearProcessingPreview(allocator);
        self.processing_inverted_cache.deinit(allocator);
        self.processing_result_cache.deinit(allocator);
        self.processing_images.deinit(allocator);
        self.processing_images = .{ .paths = &.{} };
        self.gallery_files.deinit(allocator);
        self.gallery_files = .{ .files = &.{} };
        self.processing.image_count = 0;
        self.processing.image_idx = 0;
        self.gallery_index = 0;
    }

    pub fn show(self: *State, view: View) void {
        self.active_view = view;
    }

    /// Asks the main loop to run the scanner connect worker again.
    pub fn requestReconnect(self: *State) void {
        self.reconnect_requested = true;
    }

    pub fn takeReconnectRequest(self: *State) bool {
        const requested = self.reconnect_requested;
        self.reconnect_requested = false;
        return requested;
    }

    pub fn requestQuit(self: *State) void {
        self.quit_requested = true;
    }

    pub fn setStatus(self: *State, message: []const u8) void {
        self.status = message;
    }

    pub fn beginScannerConnect(self: *State) void {
        self.scanner.connection = .connecting;
        self.scanner_capabilities = null;
        self.scanner.scanner_error = null;
        self.scanner.scan_status = "Connecting...";
        self.status = self.scanner.scan_status;
    }

    pub fn scannerConnected(
        self: *State,
        preview_width: usize,
        preview_height: usize,
        tpu_width_in: f64,
        tpu_height_in: f64,
    ) void {
        self.scannerConnectedWithCapabilities(preview_width, preview_height, .{
            .tpu_width_in = tpu_width_in,
            .tpu_height_in = tpu_height_in,
        });
    }

    pub fn scannerConnectedWithCapabilities(
        self: *State,
        preview_width: usize,
        preview_height: usize,
        capabilities: scanner_contracts.ScannerCapabilities,
    ) void {
        self.scanner.connection = .connected;
        self.scanner.scanner_error = null;
        self.scanner.preview_width = preview_width;
        self.scanner.preview_height = preview_height;
        self.scanner.tpu_width_in = capabilities.tpu_width_in;
        self.scanner.tpu_height_in = capabilities.tpu_height_in;
        self.scanner_capabilities = stableScannerCapabilities(capabilities);
        self.scan_controls.useScanner(.fromCapabilities(&self.scanner_capabilities.?));
        self.scanner.scan_status = "";
        self.applyPendingScannerConfigSelection();
    }

    pub fn scannerFailed(self: *State, raw_message: []const u8) void {
        const message = scannerErrorText(raw_message);
        const stored_len = @min(message.len, self.scan_status_buffer.len);
        @memcpy(self.scan_status_buffer[0..stored_len], message[0..stored_len]);
        const stored = self.scan_status_buffer[0..stored_len];
        self.scanner.connection = .error_state;
        self.scanner_capabilities = null;
        self.scanner.scanner_error = stored;
        self.scanner.scanning = false;
        self.scanner.scan_status = stored;
        self.status = stored;
    }

    pub fn beginScan(self: *State, message: []const u8) void {
        self.scanner.scanning = true;
        self.scanner.cancel_requested = false;
        self.scanner.scan_status = message;
        self.scanner_progress_percent = null;
    }

    pub fn setScanStatus(self: *State, message: []const u8) void {
        self.scanner.scan_status = message;
    }

    pub fn updateScanProgressStatus(self: *State, now_ms: u64) void {
        if (!self.scanner.scanning or self.preview_requested) {
            self.scan_started_ms = null;
            self.scan_pass_started_ms = null;
            self.scan_eta_seconds = null;
            return;
        }
        const mode = self.active_scan_mode orelse return;
        const scan_started = self.scan_started_ms orelse now_ms;
        const pass_started = self.scan_pass_started_ms orelse now_ms;
        self.scan_started_ms = scan_started;
        self.scan_pass_started_ms = pass_started;
        const percent = self.scanner_progress_percent orelse return;
        if (percent == 0) return;

        const done: f64 = @floatFromInt(@min(percent, 100));
        const pass_elapsed = @as(f64, @floatFromInt(now_ms -| pass_started)) / 1000.0;
        const pass_eta = pass_elapsed * (100.0 - done) / done;
        const elapsed = @as(f64, @floatFromInt(now_ms -| scan_started)) / 1000.0;
        const dpi = self.active_scan_dpi;
        const message = switch (mode) {
            .rgb_ir => if (self.scan_ir_pass)
                scan_workflow.handleScanIrProgressStatus(&self.scan_status_buffer, dpi, percent, pass_eta, elapsed)
            else
                scan_workflow.handleScanRgbProgressStatus(&self.scan_status_buffer, dpi, percent, pass_eta, elapsed),
            .rgb, .ir => scan_workflow.handleScanSingleProgressStatus(&self.scan_status_buffer, mode, percent, pass_eta, elapsed),
        } catch return;
        self.scanner.scan_status = message;
        self.status = message;
        self.scan_eta_seconds = if (mode == .rgb_ir and !self.scan_ir_pass)
            scan_workflow.rgbIrTotalEtaSeconds(dpi, percent, pass_eta)
        else
            pass_eta;
    }

    pub fn syncScanCounter(self: *State, io: std.Io) void {
        const next = tiff.nextScanNumber(io, self.scanner.output_dir, "scan_") catch return;
        self.scanner.scan_counter = @max(self.scanner.scan_counter, next);
    }

    pub fn finishScan(self: *State) void {
        self.scanner.scanning = false;
        self.scanner.scan_status = "";
        self.scanner.scan_counter += 1;
        self.active_scan_mode = null;
        self.active_scan_selection = null;
        self.active_scan_dpi = 0;
    }

    pub fn requestScannerCancel(self: *State) void {
        self.scanner.requestCancel();
        self.scanner.scan_status = "Cancelling...";
    }

    pub fn beginPreviewRequest(self: *State) void {
        self.active_view = .scan;
        self.preview_requested = true;
        self.preview_ready = false;
        self.preview_image = null;
        self.scan_controls.auto_selection = null;
        self.beginScan("Scanning preview...");
        self.status = "Scanning preview...";
    }

    pub fn queuePreviewScan(self: *State, output_path: []const u8) bool {
        if (self.scanner.connection == .connecting) {
            self.status = "Scanner connecting, please wait...";
            self.scanner.scan_status = self.status;
            return false;
        }
        if (self.scanner.connection != .connected) {
            self.status = self.scanner.scanner_error orelse "No scanner connected";
            self.scanner.scan_status = self.status;
            return false;
        }
        if (self.scannerWorkActive()) return self.rejectScannerBusy();
        const plan = self.previewScanPlan(output_path) orelse {
            self.status = "Scanner area unavailable";
            self.scanner.scan_status = self.status;
            return false;
        };
        self.pending_command = .{ .preview_scan = plan };
        self.beginPreviewRequest();
        return true;
    }

    pub fn queueScanStart(self: *State, cancel_file_path: ?[]const u8) bool {
        if (self.scanner.connection == .connecting) {
            self.status = "Scanner connecting, please wait...";
            self.scanner.scan_status = self.status;
            return false;
        }
        if (self.scanner.connection != .connected) {
            self.status = self.scanner.scanner_error orelse "No scanner connected";
            self.scanner.scan_status = self.status;
            return false;
        }
        if (self.scannerWorkActive()) return self.rejectScannerBusy();
        const output_path = scan_workflow.scanOutputPath(
            &self.scan_output_path_buffer,
            self.scanner.output_dir,
            self.scan_controls,
            self.scanner.scan_counter,
        ) catch {
            self.status = "Scan output path unavailable";
            self.scanner.scan_status = self.status;
            return false;
        };
        const plan = self.scanStartPlan(output_path, cancel_file_path) orelse {
            self.status = "Draw a selection rectangle first.";
            self.scanner.scan_status = self.status;
            return false;
        };
        self.queueScanPlan(plan);
        return true;
    }

    pub fn queueScanStartPath(self: *State, output_path: []const u8, cancel_file_path: ?[]const u8) bool {
        return self.queueStripScan(output_path, cancel_file_path, null);
    }

    /// Queues a scan of the current selection to `output_path`, with a roll's
    /// gamma LUT file when one is given.
    pub fn queueStripScan(self: *State, output_path: []const u8, cancel_file_path: ?[]const u8, roll_lut_path: ?[]const u8) bool {
        if (self.scanner.connection == .connecting) {
            self.status = "Scanner connecting, please wait...";
            self.scanner.scan_status = self.status;
            return false;
        }
        if (self.scanner.connection != .connected) {
            self.status = self.scanner.scanner_error orelse "No scanner connected";
            self.scanner.scan_status = self.status;
            return false;
        }
        if (self.scannerWorkActive()) return self.rejectScannerBusy();
        var plan = self.scanStartPlan(output_path, cancel_file_path) orelse {
            self.status = "Draw a selection rectangle first.";
            self.scanner.scan_status = self.status;
            return false;
        };
        plan.roll_lut_path = roll_lut_path;
        self.queueScanPlan(plan);
        return true;
    }

    /// Points the Process tab and the gallery at other directories (a
    /// roll's strips and exports, or back to the defaults) and drops the
    /// loaded image.
    pub fn setProcessingDirectories(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        input_dir: []const u8,
        output_dir: []const u8,
    ) void {
        self.clearProcessingPreview(allocator);
        self.processing.input_dir = input_dir;
        self.processing.output_dir = output_dir;
        self.processing.input_path = "";
        self.processing.image_idx = 0;
        _ = self.refreshProcessingImageList(allocator, io) catch {};
        _ = self.refreshGalleryFiles(allocator, io) catch {};
    }

    pub fn scannerWorkActive(self: State) bool {
        return self.scanner.scanning or self.pending_command != null;
    }

    fn rejectScannerBusy(self: *State) bool {
        self.status = "Scanner busy, please wait...";
        return false;
    }

    fn queueScanPlan(self: *State, plan: ScanStartPlan) void {
        self.pending_command = .{ .scan_start = plan };
        self.beginHandleScan(plan);
        self.active_scan_selection = self.scan_controls.selection;
    }

    pub fn takeCommand(self: *State) ?Command {
        const command = self.pending_command;
        self.pending_command = null;
        return command;
    }

    pub fn applyScannerBackendEvent(self: *State, event: ScannerBackendEvent) void {
        switch (event) {
            .scan_start => |scan_start| {
                const preview = scan_start.effective_dpi == self.scanner.preview_dpi and
                    scan_start.kind == .rgb;
                if (preview) {
                    self.beginPreviewRequest();
                } else {
                    self.beginHandleScanFromBackend(scan_start);
                }
            },
            .progress => |progress| {
                self.scanner_progress_percent = progress.percent;
            },
            .scan_complete => |scan_complete| {
                self.scanner.scanning = false;
                self.scanner_progress_percent = null;
                if (self.preview_requested) {
                    self.preview_requested = false;
                    self.preview_ready = true;
                    self.scanner.scan_status = "Preview ready";
                    self.status = "Preview ready";
                } else {
                    self.finishHandleScan(scan_complete.output);
                }
            },
            .scan_cancelled => |failure| {
                self.scanner.scanning = false;
                self.scanner.cancel_requested = false;
                self.scanner_progress_percent = null;
                self.preview_requested = false;
                self.active_scan_mode = null;
                self.active_scan_selection = null;
                self.active_scan_dpi = 0;
                self.scanner.scan_status = failure.detail;
                self.status = failure.detail;
            },
            .scan_error => |failure| {
                self.scanner.scanning = false;
                self.scanner.cancel_requested = false;
                self.scanner_progress_percent = null;
                self.preview_requested = false;
                const detail = scannerErrorText(failure.detail);
                if (self.active_scan_mode != null) {
                    self.setHandleScanErrorStatus(detail);
                } else {
                    self.scanner.scan_status = detail;
                    self.status = detail;
                }
            },
            .timing => |timing| {
                self.recordScannerTiming(timing);
            },
        }
    }

    fn recordScannerTiming(self: *State, timing: scanner_events.TimingEvent) void {
        const stage_len = @min(timing.stage.len, self.scanner_timing_stage_buffer.len);
        @memcpy(self.scanner_timing_stage_buffer[0..stage_len], timing.stage[0..stage_len]);
        self.scanner_timing_stage = self.scanner_timing_stage_buffer[0..stage_len];
        self.scanner_timing_elapsed_us = timing.elapsed_us;
        self.scanner_timing_count += 1;
        if (timing.detail) |detail| {
            const detail_len = @min(detail.len, self.scanner_timing_detail_buffer.len);
            @memcpy(self.scanner_timing_detail_buffer[0..detail_len], detail[0..detail_len]);
            self.scanner_timing_detail = self.scanner_timing_detail_buffer[0..detail_len];
        } else {
            self.scanner_timing_detail = null;
        }
    }

    pub fn finishPreviewScan(
        self: *State,
        capabilities: scanner_contracts.ScannerCapabilities,
        image: PreviewImageInfo,
    ) void {
        self.scanner.connection = .connected;
        self.scanner_capabilities = stableScannerCapabilities(capabilities);
        self.scan_controls.useScanner(.fromCapabilities(&self.scanner_capabilities.?));
        self.scanner.tpu_width_in = capabilities.tpu_width_in;
        self.scanner.tpu_height_in = capabilities.tpu_height_in;
        self.scanner.preview_width = image.width;
        self.scanner.preview_height = image.height;
        self.preview_image = image;
        self.scan_controls.auto_selection = null;
        if (self.scan_controls.autoselect) {
            self.scan_controls.selection = null;
        } else {
            self.applyPendingScannerConfigSelection();
        }
        self.scanner.scanning = false;
        // A preview cannot be cancelled; drop a cancel pressed during it.
        self.scanner.cancel_requested = false;
        self.scanner_progress_percent = null;
        self.preview_requested = false;
        self.preview_ready = true;
        self.scanner.scan_status = if (self.scan_controls.autoselect)
            "Preview ready"
        else
            "Preview ready. Draw a rectangle to select scan area.";
        self.status = self.scanner.scan_status;
    }

    pub fn scanRestoreAutoAvailable(self: State) bool {
        return self.scan_controls.auto_selection != null;
    }

    pub fn applyPreviewAutoSelect(
        self: *State,
        allocator: std.mem.Allocator,
        preview: []const u8,
        width: usize,
        height: usize,
        channels: usize,
    ) !void {
        if (!self.scan_controls.autoselect) return;
        const selection = try scan_workflow.detectFilmAreaSelection(
            allocator,
            preview,
            width,
            height,
            channels,
            self.scanner.preview_dpi,
            self.scanner.tpu_width_in,
            self.scanner.tpu_height_in,
            .{},
        );
        if (selection) |detected| {
            self.scan_controls.setAutoSelection(detected);
            self.scanner.scan_status = "Film area detected. Adjust selection if needed.";
            self.status = self.scanner.scan_status;
        } else {
            self.scan_controls.selection = null;
            self.scanner.scan_status = "No film detected. Draw a rectangle manually.";
            self.status = self.scanner.scan_status;
        }
    }

    pub fn previewAutoSelectFailed(self: *State) void {
        if (!self.scan_controls.autoselect) return;
        self.scan_controls.selection = null;
        self.scanner.scan_status = "Auto-detect failed. Draw a rectangle manually.";
        self.status = self.scanner.scan_status;
    }

    pub fn previewScanPlan(self: State, output_path: []const u8) ?PreviewScanPlan {
        return scan_workflow.previewScanPlan(self.scanner.info(), self.scanner.preview_dpi, output_path);
    }

    pub fn scanStartPlan(self: State, output_path: []const u8, cancel_file_path: ?[]const u8) ?ScanStartPlan {
        return scan_workflow.scanStartPlan(self.scanner.info(), self.scan_controls, output_path, cancel_file_path);
    }

    pub fn applyScannerConfig(self: *State, loaded: scanner_config.LoadedConfig) void {
        if (loaded.active.autoselect) self.scan_controls.autoselect = loaded.values.autoselect;
        if (loaded.active.mode) {
            if (scanModeFromConfig(loaded.values.mode.slice())) |mode| {
                self.scan_controls.setMode(mode);
            }
        }
        if (loaded.active.dpi and scanModeSupportsDpi(&self.scan_controls, self.scan_controls.mode, loaded.values.dpi)) {
            self.scan_controls.dpi = loaded.values.dpi;
        }
        if (loaded.active.sel_x_in and
            loaded.active.sel_y_in and
            loaded.active.sel_w_in and
            loaded.active.sel_h_in)
        {
            const area = ScanAreaInches{
                .x = loaded.values.sel_x_in,
                .y = loaded.values.sel_y_in,
                .w = loaded.values.sel_w_in,
                .h = loaded.values.sel_h_in,
            };
            self.pending_config_selection = area;
            self.applyPendingScannerConfigSelection();
        }
    }

    pub fn loadScannerConfig(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) !void {
        const loaded = try scanner_config.loadFile(allocator, io, path);
        self.applyScannerConfig(loaded);
    }

    pub fn scannerConfigUpdates(self: State) scanner_config.LoadedConfig {
        var updates = scanner_config.LoadedConfig{};
        updates.values.dpi = self.scan_controls.dpi;
        updates.active.dpi = true;
        updates.values.mode.set(self.scan_controls.mode.wireValue()) catch unreachable;
        updates.active.mode = true;
        updates.values.autoselect = self.scan_controls.autoselect;
        updates.active.autoselect = true;
        if (self.scan_controls.selectionForConfig(self.scanner.info())) |area| {
            updates.values.sel_x_in = area.x;
            updates.active.sel_x_in = true;
            updates.values.sel_y_in = area.y;
            updates.active.sel_y_in = true;
            updates.values.sel_w_in = area.w;
            updates.active.sel_w_in = true;
            updates.values.sel_h_in = area.h;
            updates.active.sel_h_in = true;
        }
        return updates;
    }

    pub fn saveScannerConfig(
        self: State,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) !bool {
        try scanner_config.saveFile(allocator, io, path, self.scannerConfigUpdates());
        return true;
    }

    pub fn applyProcessingConfig(self: *State, loaded: processing_config.LoadedConfig) void {
        self.processing_config = loaded;
        self.applyProcessingConfigState();
    }

    pub fn loadProcessingConfig(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) !void {
        const loaded = try processing_config.loadFile(allocator, io, path);
        self.applyProcessingConfig(loaded);
    }

    pub fn processingSettingsInfo(
        self: *const State,
        out_entries: *[32]processing_config.Entry,
    ) ProcessSettingsInfo {
        var count: usize = 0;
        for (self.processing_config.entries[0..self.processing_config.len]) |entry| {
            if (std.mem.eql(u8, entry.name.slice(), "_stocks")) continue;
            out_entries[count] = entry;
            count += 1;
        }
        return .{
            .entries = out_entries[0..count],
            .active_stock = self.processing_config.activeStock(),
            .preview_inversion = processingConfigBool(&self.processing_config, "preview_inversion") orelse false,
        };
    }

    pub fn processingStocksInfo(
        self: *const State,
        out_stocks: []ProcessStockChoice,
    ) !ProcessStocksInfo {
        var count: usize = 0;
        for (processing_config.builtin_stocks) |builtin| {
            if (count >= out_stocks.len) return error.TooManyStockProfiles;
            out_stocks[count] = if (processingCustomStock(&self.processing_config, builtin.name)) |custom|
                stockChoiceFromProfile(custom)
            else
                .{ .name = builtin.name, .description = builtin.description };
            count += 1;
        }
        for (self.processing_config.stocks[0..self.processing_config.stock_len]) |*profile| {
            if (isProcessingBuiltinStock(profile.name.slice())) continue;
            if (count >= out_stocks.len) return error.TooManyStockProfiles;
            out_stocks[count] = stockChoiceFromProfile(profile);
            count += 1;
        }
        return .{
            .active = self.processing_config.activeStock(),
            .stocks = out_stocks[0..count],
        };
    }

    pub fn saveProcessingSettings(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        updates: []const processing_config.Override,
    ) !void {
        const changes_stock = processingUpdatesContain(updates, "stock");
        try self.processing_config.apply(updates);
        self.applyProcessingConfigState();
        try processing_config.saveLoadedFile(allocator, io, path, self.processing_config);
        if (changes_stock) self.invalidateProcessingInversionCache(allocator);
    }

    pub fn beginProcessingImageLoad(self: *State, path: []const u8, index: usize) void {
        self.active_view = .process;
        self.processing.beginImageLoad(path, index);
        self.status = "Loading image...";
    }

    pub fn beginProcessingImageLoadRequest(self: *State, path: []const u8, index: usize) usize {
        self.clearProcessingImageSelections();
        self.process_auto_detect_pending = false;
        self.processing_generation += 1;
        self.beginProcessingImageLoad(path, index);
        return self.processing_generation;
    }

    pub fn finishProcessingImageLoad(
        self: *State,
        width: usize,
        height: usize,
        has_ir: bool,
        is_grayscale: bool,
        dpi: ?u32,
        preview_scale: f64,
    ) void {
        self.processing.finishImageLoad(width, height, has_ir, is_grayscale, dpi, preview_scale);
        self.status = "Image loaded";
    }

    pub fn processPreviewInteractionReady(self: State) bool {
        return !self.processing.loading and self.processing_preview != null;
    }

    pub fn finishProcessingImageLoadResult(
        self: *State,
        allocator: std.mem.Allocator,
        generation: usize,
        index: usize,
        path: []const u8,
        preview: *?processing_workflow.QuickPreview,
    ) bool {
        if (!self.processingOwnerMatches(generation, path) or self.processing.image_idx != index) {
            return false;
        }
        const loaded = preview.* orelse return false;
        self.clearProcessingPreview(allocator);
        self.finishProcessingImageLoad(
            loaded.info.width,
            loaded.info.height,
            loaded.info.has_ir,
            loaded.info.is_grayscale,
            loaded.info.dpi,
            loaded.info.preview_scale,
        );
        self.processing_preview = loaded;
        preview.* = null;
        self.process_auto_detect_pending = true;
        return true;
    }

    pub fn rescanProcessingImages(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) !void {
        const had_input_path = self.processing.input_path.len != 0;
        var images = try processing_workflow.findImages(allocator, io, self.processing.input_dir);
        errdefer images.deinit(allocator);
        const retained_index = processing_workflow.retainedImageIndex(
            self.processing_images.paths,
            self.processing.image_idx,
            images.paths,
        );
        self.processing_images.deinit(allocator);
        self.processing_images = images;
        self.processing.image_count = self.processing_images.paths.len;
        self.processing.image_idx = retained_index;
        if (self.processing.image_count == 0) {
            self.processing.input_path = "";
        } else if (had_input_path) {
            self.processing.input_path = self.processing_images.paths[self.processing.image_idx];
        }
    }

    pub fn switchProcessingImage(
        self: *State,
        allocator: std.mem.Allocator,
        index: usize,
        preview_size: i64,
    ) !app_state.ProcessingInfo {
        if (index >= self.processing_images.paths.len) {
            self.status = "Invalid index";
            return error.InvalidProcessImageIndex;
        }
        const path = self.processing_images.paths[index];
        const generation = self.beginProcessingImageLoadRequest(path, index);
        const preview = try processing_workflow.loadQuickPreview(allocator, path, preview_size);
        errdefer preview.deinit(allocator);
        var owned_preview: ?processing_workflow.QuickPreview = preview;
        _ = self.finishProcessingImageLoadResult(allocator, generation, index, path, &owned_preview);
        return self.processingInfo();
    }

    pub fn switchProcessingImageAfterRefresh(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        selected_index: usize,
        preview_size: i64,
    ) !?app_state.ProcessingInfo {
        const refreshed_index = (try self.processingImageIndexAfterRefresh(allocator, io, selected_index)) orelse return null;
        if (self.processing_preview != null and refreshed_index == self.processing.image_idx) {
            return self.processingInfo();
        }
        return try self.switchProcessingImage(allocator, refreshed_index, preview_size);
    }

    pub fn processingImageIndexAfterRefresh(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        selected_index: usize,
    ) !?usize {
        if (selected_index >= self.processing_images.paths.len) {
            self.status = "Invalid index";
            return error.InvalidProcessImageIndex;
        }
        const selected_path = try allocator.dupe(u8, self.processing_images.paths[selected_index]);
        defer allocator.free(selected_path);

        try self.rescanProcessingImages(allocator, io);
        const refreshed_index = processImagePathIndex(self.processing_images.paths, selected_path) orelse {
            self.status = "Image list changed";
            return null;
        };
        return refreshed_index;
    }

    pub fn takeScanFinished(self: *State) bool {
        const finished = self.scan_finished_pending;
        self.scan_finished_pending = false;
        return finished;
    }

    pub fn takeProcessAutoDetectPending(self: *State) bool {
        const pending = self.process_auto_detect_pending;
        self.process_auto_detect_pending = false;
        return pending;
    }

    pub fn invalidateProcessingInversionCache(self: *State, allocator: std.mem.Allocator) void {
        self.processing_inverted_cache.invalidate(allocator);
    }

    pub fn setProcessingPreviewInversionEnabled(self: *State, enabled: bool) void {
        self.processing_preview_inversion_enabled = enabled;
    }

    pub fn setProcessingGpuRequest(
        self: *State,
        allocator: std.mem.Allocator,
        request: processing_webgpu.Request,
    ) void {
        if (self.processing_gpu_request.backend != request.backend or
            self.processing_gpu_request.fallback != request.fallback)
        {
            self.processing_inverted_cache.invalidate(allocator);
        }
        self.processing_gpu_request = request;
    }

    pub fn renderInvertedProcessingPreview(
        self: *State,
        allocator: std.mem.Allocator,
        options: processing_workflow.InvertedPreviewOptions,
    ) !?[]u8 {
        const preview = self.processing_preview orelse return null;
        return processing_workflow.renderInvertedPreviewJpeg(
            allocator,
            preview,
            &self.processing_inverted_cache,
            options,
        );
    }

    pub fn renderSelectedProcessingPreview(
        self: *State,
        allocator: std.mem.Allocator,
        options: processing_workflow.InvertedPreviewOptions,
    ) !?ProcessPreviewResponse {
        const preview = self.processing_preview orelse return null;
        if (self.processing_preview_inversion_enabled) {
            if (self.renderInvertedProcessingPreview(allocator, options) catch null) |jpeg| {
                return .{
                    .jpeg = jpeg,
                    .used_inverted = true,
                    .fell_back_to_quick = false,
                };
            }
            return .{
                .jpeg = try allocator.dupe(u8, preview.jpeg),
                .used_inverted = false,
                .fell_back_to_quick = true,
            };
        }
        return .{
            .jpeg = try allocator.dupe(u8, preview.jpeg),
            .used_inverted = false,
            .fell_back_to_quick = false,
        };
    }

    pub fn processingInvertedPreviewOptions(self: *const State) processing_workflow.InvertedPreviewOptions {
        return .{
            .stock = self.processing_config.activeStock(),
            .dmin = self.processing.dmin,
            .render_options = .{
                .contrast = processingConfigFloat(&self.processing_config, "render_contrast"),
                .percentile_lo = processingConfigFloat(&self.processing_config, "render_percentile_lo"),
                .percentile_hi = processingConfigFloat(&self.processing_config, "render_percentile_hi"),
                .exposure_compensation = processingConfigFloat(&self.processing_config, "exposure_compensation"),
                .color_temp = processingConfigFloat(&self.processing_config, "color_temp"),
                .color_tint = processingConfigFloat(&self.processing_config, "color_tint"),
                .auto_white_balance = processingConfigFloat(&self.processing_config, "auto_white_balance"),
                .film_gamma = processingConfigFloat(&self.processing_config, "film_gamma"),
                .film_toe = processingConfigFloat(&self.processing_config, "film_toe"),
                .dye_crosstalk = processingConfigFloat(&self.processing_config, "dye_crosstalk"),
            },
            .invert_request = self.processing_gpu_request,
        };
    }

    pub fn setProcessingProgress(self: *State, message: []const u8) void {
        self.processing.setProgress(message);
        self.status = message;
    }

    pub fn clearProcessingSelections(self: *State) void {
        self.process_selection_count = 0;
        self.process_active_selection = null;
    }

    pub fn clearProcessingImageSelections(self: *State) void {
        self.clearProcessingSelections();
        self.process_last_auto_count = 0;
        self.process_rebate_rect = null;
        self.processing.rebate_rect = null;
        self.process_baseline = .{};
        self.process_edit_hash = 0;
        self.process_framing_dirty = false;
        self.process_undo_len = 0;
    }

    pub fn processSelectionsSnapshot(self: *const State) ProcessSelectionsSnapshot {
        var snapshot = ProcessSelectionsSnapshot{
            .count = self.process_selection_count,
            .rebate = self.processing.rebate_rect,
            .rebate_preview = self.process_rebate_rect,
        };
        @memcpy(snapshot.selections[0..snapshot.count], self.process_selections[0..snapshot.count]);
        return snapshot;
    }

    fn restoreProcessSelections(self: *State, snapshot: *const ProcessSelectionsSnapshot) void {
        @memcpy(self.process_selections[0..snapshot.count], snapshot.selections[0..snapshot.count]);
        self.process_selection_count = snapshot.count;
        self.process_active_selection = if (snapshot.count > 0) 0 else null;
        if (!std.meta.eql(self.processing.rebate_rect, snapshot.rebate) and snapshot.rebate != null) {
            self.process_rebate_dmin_pending = true;
        }
        self.processing.rebate_rect = snapshot.rebate;
        self.process_rebate_rect = snapshot.rebate_preview;
    }

    fn pushProcessUndo(self: *State, snapshot: ProcessSelectionsSnapshot) void {
        if (snapshot.count == 0 and snapshot.rebate == null) return;
        if (self.process_undo_len > 0 and self.process_undo[self.process_undo_len - 1].sameAs(&snapshot)) return;
        if (self.process_undo_len == process_undo_depth) {
            std.mem.copyForwards(ProcessSelectionsSnapshot, self.process_undo[0 .. process_undo_depth - 1], self.process_undo[1..]);
            self.process_undo_len -= 1;
        }
        self.process_undo[self.process_undo_len] = snapshot;
        self.process_undo_len += 1;
    }

    pub fn canUndoProcessSelections(self: *const State) bool {
        if (self.process_undo_len > 0) return true;
        const current = self.processSelectionsSnapshot();
        return !current.sameAs(&self.process_baseline);
    }

    /// Undoes an edit still settling, else restores the frames before the
    /// last settled edit or auto-detect.
    pub fn undoProcessSelections(self: *State) bool {
        const current = self.processSelectionsSnapshot();
        if (!current.sameAs(&self.process_baseline)) {
            const baseline = self.process_baseline;
            self.restoreProcessSelections(&baseline);
            self.process_edit_hash = 0;
            self.status = "Undid the last change to the frames";
            return true;
        }
        if (self.process_undo_len == 0) return false;
        self.process_undo_len -= 1;
        const snapshot = self.process_undo[self.process_undo_len];
        self.restoreProcessSelections(&snapshot);
        self.process_baseline = snapshot;
        self.process_edit_hash = 0;
        self.process_framing_dirty = true;
        self.status = "Restored the previous frames";
        return true;
    }

    /// Call each frame: an edit that has stopped changing becomes the new
    /// baseline, the state before it goes on the undo stack, and the frames
    /// are marked as a hand choice to save.
    pub fn settleProcessEdits(self: *State, now_ms: u64) void {
        const current = self.processSelectionsSnapshot();
        if (current.sameAs(&self.process_baseline)) {
            self.process_edit_hash = 0;
            return;
        }
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.sliceAsBytes(current.selections[0..current.count]));
        hasher.update(std.mem.asBytes(&current.rebate));
        const hash = hasher.final() | 1;
        if (hash != self.process_edit_hash) {
            self.process_edit_hash = hash;
            self.process_edit_changed_ms = now_ms;
            return;
        }
        if (now_ms -| self.process_edit_changed_ms < process_edit_settle_ms) return;
        self.pushProcessUndo(self.process_baseline);
        self.process_baseline = current;
        self.process_edit_hash = 0;
        self.process_framing_dirty = true;
    }

    /// The current frames were saved for the image.
    pub fn markProcessFramingSaved(self: *State, framing: ProcessFraming) void {
        self.process_saved_framing = framing;
        self.process_baseline = self.processSelectionsSnapshot();
        self.process_edit_hash = 0;
        self.process_framing_dirty = false;
    }

    /// Frames saved for the newly loaded image, or null; they replace its
    /// first auto-detect result.
    pub fn setProcessSavedFraming(self: *State, framing: ?ProcessFraming) void {
        self.process_saved_framing = framing;
        self.process_saved_framing_unapplied = framing != null;
    }

    pub fn takeProcessRebateDminPending(self: *State) bool {
        const pending = self.process_rebate_dmin_pending;
        self.process_rebate_dmin_pending = false;
        return pending;
    }

    fn applyProcessSavedFraming(self: *State, framing: *const ProcessFraming) void {
        const scale = self.processing.preview_scale;
        if (scale <= 0.0) return;
        for (framing.frames[0..framing.count], 0..) |frame, index| {
            self.process_selections[index] = .{
                .x = (frame.cx - frame.w / 2.0) * scale,
                .y = (frame.cy - frame.h / 2.0) * scale,
                .w = frame.w * scale,
                .h = frame.h * scale,
                .angle = frame.angle * std.math.pi / 180.0,
                .rotation = frame.rotation,
            };
        }
        self.process_selection_count = framing.count;
        self.process_active_selection = if (framing.count > 0) 0 else null;
        if (framing.rebate) |r| {
            self.processing.rebate_rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .angle = r.angle };
            self.process_rebate_rect = .{ .x = r.x * scale, .y = r.y * scale, .w = r.w * scale, .h = r.h * scale, .angle = r.angle };
            self.process_rebate_dmin_pending = true;
        }
    }

    /// After auto-detect replaced the frames: the first result for an image
    /// with saved frames gives way to them; otherwise the new frames stand,
    /// with what they replaced on the undo stack.
    fn finishProcessAutoDetect(self: *State, before: ProcessSelectionsSnapshot) void {
        if (self.process_saved_framing_unapplied) {
            self.process_saved_framing_unapplied = false;
            if (self.process_saved_framing) |*framing| {
                self.applyProcessSavedFraming(framing);
                self.status = "Showing this strip's saved frames";
            }
        } else {
            self.pushProcessUndo(before);
            if (self.process_saved_framing != null) {
                self.status = "Detected frames are not saved yet: edit them or Export Strip Frames to keep them, or Undo to go back";
            }
        }
        self.process_baseline = self.processSelectionsSnapshot();
        self.process_edit_hash = 0;
        self.process_framing_dirty = false;
    }

    pub fn writeProcessSelectionDump(self: State, out: anytype) !void {
        try out.print("\n  === Selections ({d} frames) ===\n", .{self.process_selection_count});
        try out.print("  preview_scale={d:.4}\n", .{self.processing.preview_scale});
        for (self.process_selections[0..self.process_selection_count], 0..) |selection, index| {
            try out.print(
                "  Frame {d}: x={d:.1} y={d:.1} w={d:.1} h={d:.1} angle={d:.4}\n",
                .{
                    index + 1,
                    selection.x,
                    selection.y,
                    selection.w,
                    selection.h,
                    selection.angle,
                },
            );
        }
    }

    pub fn dumpProcessSelections(self: *State) !void {
        var out = ProcessSelectionDebugWriter{};
        try self.dumpProcessSelectionsTo(&out);
    }

    pub fn dumpProcessSelectionsTo(self: *State, out: anytype) !void {
        try self.writeProcessSelectionDump(out);
        self.status = std.fmt.bufPrint(
            &self.process_status_buffer,
            "Dumped {d} selections to server console",
            .{self.process_selection_count},
        ) catch "Dumped selections to server console";
    }

    pub fn addProcessSelection(self: *State, selection: ProcessSelection) !usize {
        if (self.process_selection_count >= self.process_selections.len) return error.TooManyProcessSelections;
        const index = self.process_selection_count;
        self.process_selections[index] = selection;
        self.process_selection_count += 1;
        self.process_active_selection = index;
        return index;
    }

    pub fn removeProcessSelection(self: *State, index: usize) bool {
        if (index >= self.process_selection_count) return false;
        var i = index;
        while (i + 1 < self.process_selection_count) : (i += 1) {
            self.process_selections[i] = self.process_selections[i + 1];
        }
        self.process_selection_count -= 1;
        if (self.process_selection_count == 0) {
            self.process_active_selection = null;
        } else if (self.process_active_selection) |active| {
            self.process_active_selection = if (active > index) active - 1 else @min(active, self.process_selection_count - 1);
        } else {
            self.process_active_selection = @min(index, self.process_selection_count - 1);
        }
        self.process_last_auto_count = 0;
        return true;
    }

    pub fn finalizeProcessDrawnFrame(self: *State, index: usize) ProcessDrawnFrameFinalization {
        if (index >= self.process_selection_count) return .invalid_index;
        if (!processDrawnFrameAccepted(self.process_selections[index])) {
            _ = self.removeProcessSelection(index);
            self.setStatus("Selection too small, cleared");
            return .removed_too_small;
        }
        self.setStatus("Selection added");
        return .accepted;
    }

    pub fn applyProcessAutoDetect(
        self: *State,
        frames: []const processing_frames.FrameRect,
        aspect: ?[]const u8,
        rebate: ?processing_frames.RebateRect,
        scale_percent: f64,
        rotation: i32,
    ) !void {
        if (frames.len > self.process_selections.len) return error.TooManyProcessSelections;
        const scale = 1.0 + scale_percent / 100.0;
        for (frames, 0..) |frame, index| {
            self.process_last_auto_frames[index] = frame;
            self.process_selections[index] = selectionFromDetectedFrame(frame, scale, rotation);
        }
        self.process_selection_count = frames.len;
        self.process_last_auto_count = frames.len;
        self.process_last_rotation = rotation;
        self.process_active_selection = if (frames.len > 0) 0 else null;
        self.process_rebate_rect = if (rebate) |rb| .{
            .x = rb.cx - rb.w / 2.0,
            .y = rb.cy - rb.h / 2.0,
            .w = rb.w,
            .h = rb.h,
            .angle = rb.angle,
        } else null;
        const aspect_text = aspect orelse "";
        self.status = std.fmt.bufPrint(
            &self.process_status_buffer,
            "Detected {d} frames ({s})",
            .{ frames.len, aspect_text },
        ) catch "Detected frames";
    }

    pub fn runProcessAutoDetect(
        self: *State,
        allocator: std.mem.Allocator,
        options: processing_workflow.AutoDetectOptions,
    ) !processing_workflow.AutoDetectResult {
        const preview = self.processing_preview orelse {
            self.status = "No image loaded";
            return error.NoProcessImageLoaded;
        };
        return try processing_workflow.autoDetectPreview(allocator, preview, options);
    }

    pub fn runProcessAutoDetectWorkflow(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        config_path: []const u8,
        options: processing_workflow.AutoDetectOptions,
        scale_percent: f64,
        rotation: i32,
    ) ![]const u8 {
        const before = self.processSelectionsSnapshot();
        var result = try self.runProcessAutoDetect(allocator, options);
        defer result.deinit(allocator);
        try self.applyProcessAutoDetect(
            result.frames,
            result.aspect,
            result.rebate,
            scale_percent,
            rotation,
        );
        if (result.rebate != null) {
            _ = try self.runProcessAutoDetectRebate(allocator, io, config_path);
        }
        self.finishProcessAutoDetect(before);
        return result.aspect;
    }

    pub fn applyProcessAutoDetectWorkerResult(
        self: *State,
        allocator: std.mem.Allocator,
        generation: usize,
        path: []const u8,
        result: *processing_workflow.AutoDetectResult,
        scale_percent: f64,
        rotation: i32,
        full_rebate: ?app_state.RebateRect,
        dmin: ?[3]f64,
    ) !bool {
        if (!self.processingOwnerMatches(generation, path)) return false;
        const before = self.processSelectionsSnapshot();
        try self.applyProcessAutoDetect(
            result.frames,
            result.aspect,
            result.rebate,
            scale_percent,
            rotation,
        );
        if (full_rebate) |rect| {
            self.processing.rebate_rect = rect;
        }
        if (dmin) |value| {
            try self.applyProcessDminConfig(value);
            self.applyProcessRebateDmin(allocator, value);
        }
        self.finishProcessAutoDetect(before);
        return true;
    }

    pub fn rescaleProcessAutoSelections(self: *State, scale_percent: f64) void {
        const scale = 1.0 + scale_percent / 100.0;
        for (self.process_last_auto_frames[0..self.process_last_auto_count], 0..) |frame, index| {
            self.process_selections[index] = selectionFromDetectedFrame(frame, scale, self.process_last_rotation);
        }
        self.process_selection_count = self.process_last_auto_count;
        self.process_active_selection = if (self.process_selection_count > 0) 0 else null;
    }

    pub fn processExportRects(self: State, out: *[64]processing_export.FrameRect) ![]processing_export.FrameRect {
        if (self.process_selection_count > out.len) return error.TooManyProcessSelections;
        if (self.processing.preview_scale <= 0.0) return error.InvalidPreviewScale;
        for (self.process_selections[0..self.process_selection_count], 0..) |selection, index| {
            out[index] = .{
                .cx = (selection.x + selection.w / 2.0) / self.processing.preview_scale,
                .cy = (selection.y + selection.h / 2.0) / self.processing.preview_scale,
                .w = selection.w / self.processing.preview_scale,
                .h = selection.h / self.processing.preview_scale,
                .angle = selection.angle * 180.0 / std.math.pi,
                .rotation = selection.rotation,
            };
        }
        return out[0..self.process_selection_count];
    }

    pub fn setProcessRebatePreviewRect(self: *State, rect: ProcessSelection) !bool {
        if (rect.w <= 5.0 or rect.h <= 5.0) {
            self.process_rebate_rect = null;
            self.processing.rebate_rect = null;
            self.status = "Rebate selection too small, cleared";
            return false;
        }
        const full_origin = try processing_frames.previewRebateToFullResolution(.{
            .x = rect.x,
            .y = rect.y,
            .w = rect.w,
            .h = rect.h,
            .angle = rect.angle,
        }, self.processing.preview_scale);
        const full: app_state.RebateRect = .{
            .x = full_origin.x,
            .y = full_origin.y,
            .w = full_origin.w,
            .h = full_origin.h,
            .angle = full_origin.angle,
        };
        self.process_rebate_rect = rect;
        self.processing.rebate_rect = full;
        self.status = std.fmt.bufPrint(
            &self.process_status_buffer,
            "Rebate set ({d}x{d} px)",
            .{ @as(i64, @intFromFloat(@round(rect.w))), @as(i64, @intFromFloat(@round(rect.h))) },
        ) catch "Rebate set";
        return true;
    }

    pub fn processRebateRequest(self: State) !?app_state.RebateRect {
        const rect = self.process_rebate_rect orelse return null;
        const full = try processing_frames.previewRebateToFullResolution(.{
            .x = rect.x,
            .y = rect.y,
            .w = rect.w,
            .h = rect.h,
            .angle = rect.angle,
        }, self.processing.preview_scale);
        return .{
            .x = full.x,
            .y = full.y,
            .w = full.w,
            .h = full.h,
            .angle = full.angle,
        };
    }

    pub fn runProcessRebate(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        config_path: []const u8,
        rect: app_state.RebateRect,
    ) ![3]f64 {
        const input_path = self.currentProcessingImagePath() orelse {
            self.status = "No image loaded";
            return error.NoProcessImageLoaded;
        };
        const result = try processing_workflow.processRebateFromTiff(
            allocator,
            io,
            input_path,
            config_path,
            .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h, .angle = rect.angle },
            false,
        );
        const list = try processing_config.FloatList.init(&result.dmin);
        try self.saveProcessingSettings(allocator, io, config_path, &.{
            .{ .name = "dmin", .value = .{ .list = list } },
        });
        self.processing.rebate_rect = rect;
        self.applyProcessRebateDmin(allocator, result.dmin);
        return result.dmin;
    }

    pub fn applyProcessRebateWorkerResult(
        self: *State,
        allocator: std.mem.Allocator,
        generation: usize,
        path: []const u8,
        rect: app_state.RebateRect,
        dmin: [3]f64,
    ) !bool {
        if (!self.processingOwnerMatches(generation, path)) return false;
        // The rebate moved while this one was measured: the newer box is
        // measured next, and this result would undo it.
        if (self.process_rebate_dmin_pending) return false;
        self.processing.rebate_rect = rect;
        try self.applyProcessDminConfig(dmin);
        self.applyProcessRebateDmin(allocator, dmin);
        self.setProcessingProgress("Dmin computed");
        return true;
    }

    pub fn runProcessAutoDetectRebate(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        config_path: []const u8,
    ) !bool {
        const rect = (try self.processRebateRequest()) orelse return false;
        _ = try self.runProcessRebate(allocator, io, config_path, rect);
        return true;
    }

    pub fn applyProcessRebateDmin(self: *State, allocator: std.mem.Allocator, dmin: ?[3]f64) void {
        self.processing.dmin = dmin;
        self.invalidateProcessingInversionCache(allocator);
    }

    fn applyProcessDminConfig(self: *State, dmin: [3]f64) !void {
        const list = try processing_config.FloatList.init(&dmin);
        try self.processing_config.apply(&.{
            .{ .name = "dmin", .value = .{ .list = list } },
        });
    }

    pub fn processRebateInfo(self: *State) ProcessRebateInfo {
        return .{
            .preview_rect = self.process_rebate_rect,
            .full_rect = self.processing.rebate_rect,
            .has_dmin = self.processing.dmin != null,
            .dmin = self.processing.dmin,
            .dmin_display = self.processDminDisplay(),
        };
    }

    pub fn processDminDisplay(self: *State) []const u8 {
        if (self.processing.dmin) |dmin| {
            return std.fmt.bufPrint(
                &self.process_dmin_buffer,
                "Dmin: {d:.3} {d:.3} {d:.3}",
                .{ dmin[0], dmin[1], dmin[2] },
            ) catch "Dmin: set";
        }
        return "Dmin: not set";
    }

    pub fn beginProcessExport(
        self: *State,
        controls: ProcessExportControls,
        out_rects: *[64]processing_export.FrameRect,
    ) !?processing_export.ExportRequest {
        if (self.process_selection_count == 0) {
            self.status = "No selections to export";
            self.processing.setProgress(self.status);
            return null;
        }
        const rects = try self.processExportRects(out_rects);
        self.process_exporting = true;
        self.process_export_files_written = 0;
        self.status = "Starting export...";
        self.processing.setProgress(self.status);
        return .{
            .basename = if (controls.basename.len == 0) "frame" else controls.basename,
            .rects = rects,
            .outputs = controls.outputSelection(),
        };
    }

    pub fn runProcessExport(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        controls: ProcessExportControls,
        out_rects: *[64]processing_export.FrameRect,
        total_seconds_override: ?f64,
    ) !?processing_workflow.ExportWorkflowResult {
        const request = (try self.beginProcessExport(controls, out_rects)) orelse return null;
        errdefer self.process_exporting = false;
        const input_path = self.currentProcessingImagePath() orelse {
            self.status = "No image loaded";
            self.processing.setProgress(self.status);
            return error.NoProcessImageLoaded;
        };
        var overrides_buffer: [32]processing_config.Override = undefined;
        const overrides = self.processing_config.overrides(&overrides_buffer);
        const active_stock = self.processing_config.activeStock();
        const stock_coeffs = if (active_stock) |stock_name| blk: {
            const profile = self.processing_config.availableStock(stock_name) orelse return error.UnknownFilmStock;
            if (!profile.has_coeffs) return error.UnknownFilmStock;
            break :blk profile.coeffs;
        } else null;
        const rebate = if (self.processing.rebate_rect) |rect| processing_frames.RebateOriginRect{
            .x = rect.x,
            .y = rect.y,
            .w = rect.w,
            .h = rect.h,
            .angle = rect.angle,
        } else null;

        var result = try processing_workflow.processExportFromTiff(allocator, io, .{
            .input_path = input_path,
            .output_dir = self.processing.output_dir,
            .basename = request.basename,
            .rects = request.rects,
            .outputs = request.outputs,
            .active_stock = active_stock,
            .stock_coeffs = stock_coeffs,
            .dmin = self.processing.dmin,
            .rebate_rect = rebate,
            .current_dpi = self.processing.current_dpi,
            .config_overrides = overrides,
            .invert_request = self.processing_gpu_request,
            .total_seconds_override = total_seconds_override,
        });
        errdefer result.deinit(allocator);
        if (result.dmin) |dmin| {
            self.processing.dmin = dmin;
        }
        const message = std.fmt.bufPrint(
            &self.process_status_buffer,
            "{s}",
            .{result.message},
        ) catch "Export complete";
        self.finishProcessExport(message, result.files.len);
        return result;
    }

    pub fn currentProcessingImageStem(self: State) []const u8 {
        const path = if (self.processing.input_path.len != 0)
            self.processing.input_path
        else
            self.currentProcessingImagePath() orelse return "";
        return std.fs.path.stem(std.fs.path.basename(path));
    }

    pub fn applyProcessingBackendEvent(self: *State, event: ProcessingBackendEvent) void {
        switch (event) {
            .export_start => {
                self.process_exporting = true;
                self.process_export_files_written = 0;
                self.setProcessingProgress("Starting export...");
            },
            .export_progress => |progress| {
                const message = std.fmt.bufPrint(
                    &self.process_status_buffer,
                    "{s}",
                    .{progress.message},
                ) catch "Export progress";
                self.setProcessingProgress(message);
            },
            .file_written => |written| {
                self.process_export_files_written += 1;
                const message = std.fmt.bufPrint(
                    &self.process_status_buffer,
                    "Wrote {s}",
                    .{written.file},
                ) catch "Wrote file";
                self.setProcessingProgress(message);
            },
            .export_complete => |complete| {
                self.process_exporting = false;
                self.process_export_files_written = complete.file_count;
                const message = std.fmt.bufPrint(
                    &self.process_status_buffer,
                    "Exported {d} file{s} to {s}/",
                    .{ complete.file_count, if (complete.file_count == 1) "" else "s", complete.output_dir },
                ) catch "Export complete";
                self.setProcessingProgress(message);
            },
            .export_cancelled => |cancelled| {
                self.process_exporting = false;
                const message = std.fmt.bufPrint(
                    &self.process_status_buffer,
                    "Export cancelled: {s}",
                    .{cancelled.detail},
                ) catch "Export cancelled";
                self.setProcessingProgress(message);
            },
            .processing_error => |failure| {
                self.process_exporting = false;
                self.processing.loading = false;
                const message = if (std.mem.eql(u8, failure.operation, "export"))
                    std.fmt.bufPrint(&self.process_status_buffer, "Export failed: {s}", .{failure.detail}) catch "Export failed"
                else
                    std.fmt.bufPrint(&self.process_status_buffer, "{s} failed: {s}", .{ failure.operation, failure.detail }) catch "Processing failed";
                self.setProcessingProgress(message);
            },
        }
    }

    pub fn finishProcessExport(self: *State, message: []const u8, files_written: usize) void {
        self.process_exporting = false;
        self.process_export_files_written = files_written;
        self.setProcessingProgress(message);
    }

    pub fn processExportStatus(self: State) ProcessExportStatus {
        return .{
            .exporting = self.process_exporting,
            .files_written = self.process_export_files_written,
            .status = self.status,
        };
    }

    pub fn trashCurrentProcessingImage(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        preview_size: i64,
    ) !ProcessImageMutation {
        const old_index = self.processing.image_idx;
        const path = self.currentProcessingImagePath() orelse {
            self.status = "No image loaded";
            return error.NoProcessImageLoaded;
        };
        const original_name = std.fs.path.basename(path);
        const parent = std.fs.path.dirname(path) orelse ".";
        const trash_dir = try std.fs.path.join(allocator, &.{ parent, ".trash" });
        defer allocator.free(trash_dir);
        try std.Io.Dir.cwd().createDirPath(io, trash_dir);

        const stem = std.fs.path.stem(original_name);
        const suffix = std.fs.path.extension(original_name);
        var dest_name = try allocator.dupe(u8, original_name);
        defer allocator.free(dest_name);
        var counter: usize = 1;
        while (true) : (counter += 1) {
            const dest_path = try std.fs.path.join(allocator, &.{ trash_dir, dest_name });
            defer allocator.free(dest_path);
            std.Io.Dir.cwd().access(io, dest_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    const cwd = std.Io.Dir.cwd();
                    try cwd.rename(path, cwd, dest_path, io);
                    const message = std.fmt.bufPrint(
                        &self.process_status_buffer,
                        "Moved {s} to trash",
                        .{original_name},
                    ) catch "Moved scan to trash";
                    return try self.afterProcessingImageMutation(allocator, io, old_index, preview_size, message);
                },
                else => return err,
            };
            allocator.free(dest_name);
            dest_name = try std.fmt.allocPrint(allocator, "{s}_{d}{s}", .{ stem, counter, suffix });
        }
    }

    pub fn deleteCurrentProcessingImage(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        preview_size: i64,
    ) !ProcessImageMutation {
        const old_index = self.processing.image_idx;
        const path = self.currentProcessingImagePath() orelse {
            self.status = "No image loaded";
            return error.NoProcessImageLoaded;
        };
        const original_name = std.fs.path.basename(path);
        try std.Io.Dir.cwd().deleteFile(io, path);
        const message = std.fmt.bufPrint(
            &self.process_status_buffer,
            "Deleted {s}",
            .{original_name},
        ) catch "Deleted scan";
        return try self.afterProcessingImageMutation(allocator, io, old_index, preview_size, message);
    }

    pub fn galleryInfo(self: State) GalleryInfo {
        const has_file = self.gallery_index < self.gallery_files.files.len;
        return .{
            .files = self.gallery_files.files,
            .active_index = if (has_file) self.gallery_index else null,
            .image_count = self.gallery_files.files.len,
            .filename = if (has_file) self.gallery_files.files[self.gallery_index] else "",
            .can_navigate = self.gallery_files.files.len > 0,
            .status = self.status,
        };
    }

    pub fn currentGalleryFileName(self: State) ?[]const u8 {
        if (self.gallery_index >= self.gallery_files.files.len) return null;
        return self.gallery_files.files[self.gallery_index];
    }

    pub fn refreshGalleryFiles(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) !GalleryInfo {
        const old_index = self.gallery_index;
        var next = try processing_export.listGalleryFiles(allocator, io, self.processing.output_dir);
        errdefer next.deinit(allocator);

        self.acceptGalleryFiles(allocator, next, old_index);
        return self.galleryInfo();
    }

    pub fn refreshGalleryFilesIfChanged(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) !bool {
        const old_index = self.gallery_index;
        var next = try processing_export.listGalleryFiles(allocator, io, self.processing.output_dir);
        errdefer next.deinit(allocator);
        if (galleryFileListsEqual(self.gallery_files.files, next.files)) {
            next.deinit(allocator);
            return false;
        }
        self.acceptGalleryFiles(allocator, next, old_index);
        return true;
    }

    pub fn refreshGalleryFilesPreservingStatus(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) !bool {
        const old_index = self.gallery_index;
        var next = try processing_export.listGalleryFiles(allocator, io, self.processing.output_dir);
        errdefer next.deinit(allocator);
        if (galleryFileListsEqual(self.gallery_files.files, next.files)) {
            next.deinit(allocator);
            return false;
        }
        self.acceptGalleryFilesWithStatusPolicy(allocator, next, old_index, false);
        return true;
    }

    fn acceptGalleryFiles(
        self: *State,
        allocator: std.mem.Allocator,
        next: processing_export.GalleryFileList,
        old_index: usize,
    ) void {
        self.acceptGalleryFilesWithStatusPolicy(allocator, next, old_index, true);
    }

    fn acceptGalleryFilesWithStatusPolicy(
        self: *State,
        allocator: std.mem.Allocator,
        next: processing_export.GalleryFileList,
        old_index: usize,
        update_status: bool,
    ) void {
        self.gallery_files.deinit(allocator);
        self.gallery_files = next;
        if (self.gallery_files.files.len == 0) {
            self.gallery_index = 0;
            if (update_status) self.status = "No exports found";
            return;
        }

        self.gallery_index = if (old_index < self.gallery_files.files.len) old_index else 0;
        if (update_status) self.setGalleryCountStatus();
    }

    pub fn showGalleryImage(self: *State, index: usize) !GalleryInfo {
        if (self.gallery_files.files.len == 0) {
            self.gallery_index = 0;
            self.status = "No exports found";
            return self.galleryInfo();
        }
        if (index >= self.gallery_files.files.len) {
            self.status = "Invalid index";
            return error.InvalidGalleryImageIndex;
        }
        self.gallery_index = index;
        self.setGalleryImageStatus();
        return self.galleryInfo();
    }

    pub fn switchPreviousGalleryImage(self: *State) !GalleryInfo {
        const count = self.gallery_files.files.len;
        if (count == 0) {
            self.gallery_index = 0;
            self.status = "No exports found";
            return self.galleryInfo();
        }
        const index = if (self.gallery_index > 0) self.gallery_index - 1 else count - 1;
        return try self.showGalleryImage(index);
    }

    pub fn switchNextGalleryImage(self: *State) !GalleryInfo {
        const count = self.gallery_files.files.len;
        if (count == 0) {
            self.gallery_index = 0;
            self.status = "No exports found";
            return self.galleryInfo();
        }
        const index = if (self.gallery_index < count - 1) self.gallery_index + 1 else 0;
        return try self.showGalleryImage(index);
    }

    pub fn trashCurrentGalleryFile(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) !processing_export.GalleryMutation {
        const name = self.currentGalleryFileName() orelse {
            self.status = "No exports found";
            return error.NoGalleryFileSelected;
        };
        return self.trashGalleryFileByName(allocator, io, name);
    }

    pub fn trashGalleryFileByName(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        name: []const u8,
    ) !processing_export.GalleryMutation {
        var mutation = try processing_export.trashGalleryFile(allocator, io, self.processing.output_dir, name);
        errdefer mutation.deinit(allocator);
        _ = try self.refreshGalleryFiles(allocator, io);
        return mutation;
    }

    pub fn deleteCurrentGalleryFile(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) !processing_export.GalleryMutation {
        const name = self.currentGalleryFileName() orelse {
            self.status = "No exports found";
            return error.NoGalleryFileSelected;
        };
        return self.deleteGalleryFileByName(allocator, io, name);
    }

    pub fn deleteGalleryFileByName(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        name: []const u8,
    ) !processing_export.GalleryMutation {
        var mutation = try processing_export.deleteGalleryFile(allocator, io, self.processing.output_dir, name);
        errdefer mutation.deinit(allocator);
        _ = try self.refreshGalleryFiles(allocator, io);
        return mutation;
    }

    pub fn processingNavigationInfo(self: State) ProcessNavigationInfo {
        return .{
            .filename = if (self.processing.input_path.len == 0) "" else std.fs.path.basename(self.processing.input_path),
            .image_idx = self.processing.image_idx,
            .image_count = self.processing.image_count,
            .loading = self.processing.loading,
            .preview_ready = self.processing_preview != null,
            .can_navigate = self.processing.image_count > 0,
            .progress = self.processing.progress,
            .status = self.status,
        };
    }

    pub fn refreshProcessingImageList(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) !ProcessNavigationInfo {
        try self.rescanProcessingImages(allocator, io);
        if (self.processing.image_count == 0) {
            self.status = "No images";
        }
        return self.processingNavigationInfo();
    }

    pub fn switchPreviousProcessingImage(
        self: *State,
        allocator: std.mem.Allocator,
        preview_size: i64,
    ) !?app_state.ProcessingInfo {
        const count = self.processing_images.paths.len;
        if (count == 0) {
            self.status = "No images";
            return null;
        }
        const index = if (self.processing.image_idx > 0) self.processing.image_idx - 1 else count - 1;
        return try self.switchProcessingImage(allocator, index, preview_size);
    }

    pub fn switchNextProcessingImage(
        self: *State,
        allocator: std.mem.Allocator,
        preview_size: i64,
    ) !?app_state.ProcessingInfo {
        const count = self.processing_images.paths.len;
        if (count == 0) {
            self.status = "No images";
            return null;
        }
        const index = if (self.processing.image_idx < count - 1) self.processing.image_idx + 1 else 0;
        return try self.switchProcessingImage(allocator, index, preview_size);
    }

    pub fn scannerStatus(self: State) app_state.ScannerStatus {
        return self.scanner.status();
    }

    pub fn scanStatusDisplay(self: State) []const u8 {
        if (self.scanner.cancel_requested) return "Cancelling...";
        if (self.scanner.scan_status.len != 0) return self.scanner.scan_status;
        if (self.preview_requested) return "Scanning preview...";
        if (self.scanner.scanning) return "Scanning...";
        if (self.preview_ready) return "Preview ready";
        if (self.status.len != 0) return self.status;
        return "Ready";
    }

    pub fn processingInfo(self: State) app_state.ProcessingInfo {
        return self.processing.info();
    }

    pub fn activeTitle(self: State) []const u8 {
        return self.active_view.title();
    }

    pub fn activeTitleZ(self: State) [*:0]const u8 {
        return self.active_view.titleZ();
    }

    fn beginHandleScan(self: *State, plan: ScanStartPlan) void {
        self.scanner.scanning = true;
        self.scanner.cancel_requested = false;
        self.scanner_progress_percent = null;
        self.scan_started_ms = null;
        self.scan_pass_started_ms = null;
        self.scan_ir_pass = false;
        self.scan_eta_seconds = null;
        self.active_scan_mode = plan.mode;
        self.active_scan_dpi = plan.request.dpi;
        const message = scan_workflow.handleScanInitialStatus(
            &self.scan_status_buffer,
            plan.mode,
            plan.request.dpi,
        ) catch "Scanning...";
        self.scanner.scan_status = message;
        self.status = message;
    }

    fn beginHandleScanFromBackend(self: *State, scan_start: scanner_events.ScanStartEvent) void {
        self.scanner.scanning = true;
        self.scanner_progress_percent = null;
        const mode = self.active_scan_mode orelse scanModeFromBackendKind(scan_start.kind);
        self.active_scan_mode = mode;
        if (self.active_scan_dpi == 0) self.active_scan_dpi = scan_start.requested_dpi;
        self.scan_pass_started_ms = null;
        self.scan_ir_pass = mode == .rgb_ir and scan_start.kind == .ir;
        self.scan_eta_seconds = null;

        const message = if (mode == .rgb_ir and scan_start.kind == .ir)
            scan_workflow.handleScanRgbIrSecondPassStatus(&self.scan_status_buffer, self.active_scan_dpi) catch "Scanning..."
        else
            scan_workflow.handleScanInitialStatus(
                &self.scan_status_buffer,
                mode,
                self.active_scan_dpi,
            ) catch "Scanning...";
        self.scanner.scan_status = message;
        self.status = message;
    }

    fn finishHandleScan(self: *State, output_path: []const u8) void {
        self.scanner.scanning = false;
        self.scan_finished_pending = true;
        self.scanner_progress_percent = null;
        self.scanner.scan_counter += 1;
        self.active_scan_mode = null;
        self.active_scan_selection = null;
        self.active_scan_dpi = 0;
        const message = scan_workflow.handleScanSavedStatus(
            &self.scan_status_buffer,
            output_path,
        ) catch "Scan saved";
        self.scanner.scan_status = message;
        self.status = message;
    }

    fn setHandleScanErrorStatus(self: *State, detail: []const u8) void {
        self.active_scan_mode = null;
        self.active_scan_selection = null;
        self.active_scan_dpi = 0;
        const message = scan_workflow.handleScanErrorStatus(
            &self.scan_status_buffer,
            detail,
        ) catch detail;
        self.scanner.scan_status = message;
        self.status = message;
    }

    fn applyPendingScannerConfigSelection(self: *State) void {
        const area = self.pending_config_selection orelse return;
        if (self.scan_controls.restoreSelectionFromConfig(area, self.scanner.info())) {
            self.pending_config_selection = null;
        }
    }

    fn applyProcessingConfigState(self: *State) void {
        if (processingConfigBool(&self.processing_config, "preview_inversion")) |enabled| {
            self.processing_preview_inversion_enabled = enabled;
        }
        if (self.processing_config.activeStock() != null) {
            if (self.processing_config.savedDmin()) |dmin| {
                self.processing.dmin = dmin;
            }
        }
    }

    fn clearProcessingPreview(self: *State, allocator: std.mem.Allocator) void {
        if (self.processing_preview) |preview| {
            preview.deinit(allocator);
            self.processing_preview = null;
        }
        self.processing_inverted_cache.invalidate(allocator);
    }

    fn currentProcessingImagePath(self: State) ?[]const u8 {
        if (self.processing.image_idx >= self.processing_images.paths.len) return null;
        return self.processing_images.paths[self.processing.image_idx];
    }

    pub fn currentProcessingImagePathForWorker(self: State) ?[]const u8 {
        return self.currentProcessingImagePath();
    }

    pub fn processingGeneration(self: State) usize {
        return self.processing_generation;
    }

    pub fn processingOwnerMatches(self: State, generation: usize, path: []const u8) bool {
        if (generation != self.processing_generation) return false;
        const active_path = self.currentProcessingImagePath() orelse return false;
        return std.mem.eql(u8, active_path, path) and std.mem.eql(u8, self.processing.input_path, path);
    }

    fn setGalleryCountStatus(self: *State) void {
        const count = self.gallery_files.files.len;
        if (count == 0) {
            self.status = "No exports found";
            return;
        }
        self.status = std.fmt.bufPrint(
            &self.process_status_buffer,
            "{d} exported frame{s}",
            .{ count, if (count == 1) "" else "s" },
        ) catch "Exports found";
    }

    fn setGalleryImageStatus(self: *State) void {
        const name = self.currentGalleryFileName() orelse {
            self.status = "No exports found";
            return;
        };
        self.status = std.fmt.bufPrint(
            &self.process_status_buffer,
            "{d}/{d}: {s}",
            .{ self.gallery_index + 1, self.gallery_files.files.len, name },
        ) catch name;
    }

    fn afterProcessingImageMutation(
        self: *State,
        allocator: std.mem.Allocator,
        io: std.Io,
        old_index: usize,
        preview_size: i64,
        message: []const u8,
    ) !ProcessImageMutation {
        try self.rescanProcessingImages(allocator, io);
        if (self.processing.image_count == 0) {
            self.clearProcessingPreview(allocator);
            self.clearProcessingImageSelections();
            self.processing.input_path = "";
            self.processing.image_idx = 0;
            self.processing.full_width = 0;
            self.processing.full_height = 0;
            self.processing.full_image_ready = false;
            self.processing.loading = false;
            self.processing.has_ir = false;
            self.processing.is_grayscale = false;
            self.processing.current_dpi = null;
            self.status = message;
            return .{
                .message = message,
                .image_idx = 0,
                .image_count = 0,
                .switched = false,
            };
        }

        const next_index = @min(old_index, self.processing.image_count - 1);
        _ = try self.switchProcessingImage(allocator, next_index, preview_size);
        return .{
            .message = message,
            .image_idx = self.processing.image_idx,
            .image_count = self.processing.image_count,
            .switched = true,
        };
    }
};

const ProcessSelectionDebugWriter = struct {
    pub fn print(_: *ProcessSelectionDebugWriter, comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(fmt, args);
    }
};

const ProcessSelectionDumpBufferWriter = struct {
    buffer: *std.array_list.Managed(u8),

    pub fn print(self: *ProcessSelectionDumpBufferWriter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.buffer.allocator, fmt, args);
        defer self.buffer.allocator.free(text);
        try self.buffer.appendSlice(text);
    }
};

fn processingConfigEntry(
    loaded: *const processing_config.LoadedConfig,
    name: []const u8,
) ?*const processing_config.Entry {
    for (loaded.entries[0..loaded.len]) |*entry| {
        if (std.mem.eql(u8, entry.name.slice(), name)) return entry;
    }
    return null;
}

fn processImagePathIndex(paths: []const []const u8, selected_path: []const u8) ?usize {
    for (paths, 0..) |path, index| {
        if (std.mem.eql(u8, path, selected_path)) return index;
    }
    return null;
}

fn processingConfigBool(loaded: *const processing_config.LoadedConfig, name: []const u8) ?bool {
    const entry = processingConfigEntry(loaded, name) orelse return null;
    if (std.meta.activeTag(entry.value) != .boolean) return null;
    return entry.value.boolean;
}

fn processingConfigFloat(loaded: *const processing_config.LoadedConfig, name: []const u8) f64 {
    if (processingConfigEntry(loaded, name)) |entry| return entry.value.asFloat();
    const default = processing_config.defaultValue(name) orelse return 0.0;
    return default.asFloat();
}

fn galleryFileListsEqual(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

fn processingUpdatesContain(updates: []const processing_config.Override, name: []const u8) bool {
    for (updates) |update| {
        if (std.mem.eql(u8, update.name, name)) return true;
    }
    return false;
}

fn processingCustomStock(
    loaded: *const processing_config.LoadedConfig,
    name: []const u8,
) ?*const processing_config.StockProfile {
    for (loaded.stocks[0..loaded.stock_len]) |*stock| {
        if (std.mem.eql(u8, stock.name.slice(), name)) return stock;
    }
    return null;
}

fn stockChoiceFromProfile(profile: *const processing_config.StockProfile) ProcessStockChoice {
    const name = profile.name.slice();
    return .{
        .name = name,
        .description = profile.descriptionSlice() orelse name,
    };
}

fn isProcessingBuiltinStock(name: []const u8) bool {
    for (processing_config.builtin_stocks) |stock| {
        if (std.mem.eql(u8, stock.name, name)) return true;
    }
    return false;
}

fn scanModeFromBackendKind(kind: scanner_contracts.ScanKind) ScanMode {
    return switch (kind) {
        .rgb_ir => .rgb_ir,
        .ir => .ir,
        .rgb, .gray => .rgb,
    };
}

fn selectionFromDetectedFrame(frame: processing_frames.FrameRect, scale: f64, rotation: i32) ProcessSelection {
    return .{
        .x = frame.cx - (frame.w * scale) / 2.0,
        .y = frame.cy - (frame.h * scale) / 2.0,
        .w = frame.w * scale,
        .h = frame.h * scale,
        .angle = frame.angle,
        .rotation = rotation,
    };
}

/// Plain words for the scanner errors a person can act on.
pub fn scannerErrorText(detail: []const u8) []const u8 {
    if (std.mem.eql(u8, detail, "ScannerBusy") or std.mem.eql(u8, detail, "ScannerAccessDenied")) {
        return "Another program has the scanner (on macOS, Epson Scanner Monitor or Event Manager). Quit it, then reconnect.";
    }
    if (std.mem.eql(u8, detail, "ScannerNotFound")) return "No scanner found. Check the USB cable and power.";
    if (std.mem.eql(u8, detail, "InterpreterNotInstalled")) return "Epson's scanner driver is not installed.";
    if (std.mem.eql(u8, detail, "NoFilmFound")) return "No film found on the preview.";
    if (std.mem.eql(u8, detail, "InfraredUnsupported")) return "This scanner has no infrared channel. Scan in RGB.";
    if (std.mem.eql(u8, detail, "InfraredEnableFailed")) return "The scanner refused an infrared scan. Scan in RGB, and please report it.";
    if (std.mem.eql(u8, detail, "ScanParametersRejected")) return "The scanner refused these settings, most likely the resolution. Try another, and please report it.";
    return detail;
}

pub fn scannerConfigPath(buffer: []u8, output_dir: []const u8) ![]u8 {
    if (output_dir.len == 0) return std.fmt.bufPrint(buffer, "{s}", .{scanner_config.file_name});
    if (std.mem.endsWith(u8, output_dir, "/")) {
        return std.fmt.bufPrint(buffer, "{s}{s}", .{ output_dir, scanner_config.file_name });
    }
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ output_dir, scanner_config.file_name });
}

pub fn processingConfigPath(buffer: []u8) ![]u8 {
    return std.fmt.bufPrint(buffer, "{s}", .{processing_config.config_file});
}

/// The folder for scans, exports, and both configs, which all resolve from
/// the working directory: `CEREALGRAIN_DATA_DIR` if set, else
/// Pictures/CerealGrain in the home folder for the macOS app bundle (Finder
/// starts apps in "/"). Null keeps the working directory, as when run from a
/// checkout.
pub fn dataDirPath(buffer: []u8, data_dir_env: ?[]const u8, home: ?[]const u8, exe_path: []const u8) !?[]const u8 {
    if (data_dir_env) |dir| return dir;
    if (std.mem.indexOf(u8, exe_path, ".app/Contents/MacOS/") == null) return null;
    const home_dir = home orelse return error.MissingHomeDirectory;
    return try std.fmt.bufPrint(buffer, "{s}/Pictures/CerealGrain", .{home_dir});
}

test "scanner errors read as advice, including the ones other models may hit" {
    try std.testing.expectEqualStrings("This scanner has no infrared channel. Scan in RGB.", scannerErrorText("InfraredUnsupported"));
    try std.testing.expect(std.mem.indexOf(u8, scannerErrorText("ScanParametersRejected"), "resolution") != null);
    try std.testing.expectEqualStrings("SomethingElse", scannerErrorText("SomethingElse"));
}

test "the data folder is the override, else Pictures/CerealGrain for the app bundle" {
    var buffer: [256]u8 = undefined;
    const bundle_exe = "/Applications/CerealGrain.app/Contents/MacOS/cerealgrain-ui";
    try std.testing.expectEqualStrings("/Users/someone/Pictures/CerealGrain", (try dataDirPath(&buffer, null, "/Users/someone", bundle_exe)).?);
    try std.testing.expectEqualStrings("/data/v600", (try dataDirPath(&buffer, "/data/v600", "/Users/someone", bundle_exe)).?);
    try std.testing.expectEqualStrings("/data/v600", (try dataDirPath(&buffer, "/data/v600", null, "/repo/zig-out/bin/cerealgrain-ui")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try dataDirPath(&buffer, null, "/Users/someone", "/repo/zig-out/bin/cerealgrain-ui"));
    try std.testing.expectError(error.MissingHomeDirectory, dataDirPath(&buffer, null, null, bundle_exe));
}

fn scanModeFromConfig(value: []const u8) ?ScanMode {
    if (std.mem.eql(u8, value, "rgb+ir")) return .rgb_ir;
    if (std.mem.eql(u8, value, "rgb")) return .rgb;
    if (std.mem.eql(u8, value, "ir")) return .ir;
    return null;
}

fn scanModeSupportsDpi(controls: *const ScanControls, mode: ScanMode, dpi: u32) bool {
    for (controls.validDpis(mode)) |valid| {
        if (valid == dpi) return true;
    }
    return false;
}

test "native Process preview transform mirrors extract_ui zoom pan and viewport center math" {
    var transform = ProcessViewTransform{};
    transform.ensureFit("scan-a.tiff", 1000, 800, 500, 400);
    try std.testing.expect(transform.fitted);
    try std.testing.expectApproxEqAbs(1.9, transform.scale, 0.000001);
    try std.testing.expectApproxEqAbs(25.0, transform.offset_x, 0.000001);
    try std.testing.expectApproxEqAbs(20.0, transform.offset_y, 0.000001);

    const anchor_before = transform.screenToPreview(500.0, 400.0);
    transform.zoomAt(500.0, 400.0, 1.1);
    const anchor_after = transform.screenToPreview(500.0, 400.0);
    try std.testing.expectApproxEqAbs(anchor_before.x, anchor_after.x, 0.000001);
    try std.testing.expectApproxEqAbs(anchor_before.y, anchor_after.y, 0.000001);

    const offset_x = transform.offset_x;
    const offset_y = transform.offset_y;
    transform.beginPan(500.0, 400.0, 2);
    transform.updatePan(530.0, 420.0);
    transform.endPan(2);
    try std.testing.expect(!transform.panning);
    try std.testing.expectApproxEqAbs(offset_x + 30.0, transform.offset_x, 0.000001);
    try std.testing.expectApproxEqAbs(offset_y + 20.0, transform.offset_y, 0.000001);

    const center = transform.viewportCenterPreview(500.0, 400.0);
    const expected_center = transform.screenToPreviewClamped(500.0, 400.0, 500.0, 400.0);
    try std.testing.expectApproxEqAbs(expected_center.x, center.x, 0.000001);
    try std.testing.expectApproxEqAbs(expected_center.y, center.y, 0.000001);

    transform.ensureFit("scan-b.tiff", 1000, 800, 500, 400);
    try std.testing.expectApproxEqAbs(1.9, transform.scale, 0.000001);
    try std.testing.expectApproxEqAbs(25.0, transform.offset_x, 0.000001);
    try std.testing.expectApproxEqAbs(20.0, transform.offset_y, 0.000001);

    // Fitting into the canvas beside the panel offsets by the area origin.
    transform.ensureFitIn("scan-b.tiff", 600.0, 16.0, 400, 800, 500, 400);
    try std.testing.expectApproxEqAbs(0.76, transform.scale, 0.000001);
    try std.testing.expectApproxEqAbs(610.0, transform.offset_x, 0.000001);
    try std.testing.expectApproxEqAbs(264.0, transform.offset_y, 0.000001);
}

test "native UI state initializes without SDL or Nuklear bindings" {
    var state = State.init("scans", "frames", 3);
    defer state.deinit(std.testing.allocator);
    try std.testing.expectEqual(View.scan, state.active_view);
    try std.testing.expectEqualStrings("scans", state.scanner.output_dir);
    try std.testing.expectEqualStrings("scans", state.processing.input_dir);
    try std.testing.expectEqualStrings("frames", state.processing.output_dir);
    try std.testing.expectEqual(@as(usize, 3), state.processing.image_count);
    try std.testing.expectEqualStrings("Scan", state.activeTitle());

    state.show(.process);
    state.setStatus("Ready");
    try std.testing.expectEqual(View.process, state.active_view);
    try std.testing.expectEqualStrings("Process", state.activeTitle());
    try std.testing.expectEqualStrings("Ready", state.status);

    state.requestQuit();
    try std.testing.expect(state.quit_requested);
}

test "native Process settings draft coalesces transient edits before commit" {
    var draft = ProcessSettingsDraft{};
    try draft.put("render_contrast", .{ .float = 1.45 });
    try draft.put("render_contrast", .{ .float = 1.60 });
    try draft.put("ir_min_area", .{ .integer = 7 });
    try draft.put("color_temp", .{ .float = 0.25 });
    try draft.put("color_tint", .{ .float = -0.10 });
    try draft.put("color_temp", .{ .float = 0.50 });
    try draft.put("preview_size", .{ .integer = 4096 });

    const pending = draft.pending();
    try std.testing.expectEqual(@as(usize, 5), pending.len);
    try std.testing.expectEqualStrings("render_contrast", pending[0].name);
    try pending[0].value.expectEqual(.{ .float = 1.60 });
    try std.testing.expectEqualStrings("ir_min_area", pending[1].name);
    try pending[1].value.expectEqual(.{ .integer = 7 });
    try std.testing.expectEqualStrings("color_temp", pending[2].name);
    try pending[2].value.expectEqual(.{ .float = 0.50 });
    try std.testing.expectEqualStrings("color_tint", pending[3].name);
    try pending[3].value.expectEqual(.{ .float = -0.10 });
    try std.testing.expectEqualStrings("preview_size", pending[4].name);
    try pending[4].value.expectEqual(.{ .integer = 4096 });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const config_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/{s}",
        .{ tmp.sub_path[0..], processing_config.config_file },
    );
    defer allocator.free(config_path);
    var state = State.init("scans", "frames", 0);
    defer state.deinit(allocator);
    try state.saveProcessingSettings(allocator, std.testing.io, config_path, pending);
    const saved = try processing_config.loadFile(allocator, std.testing.io, config_path);
    try saved.value("render_contrast").?.expectEqual(.{ .float = 1.60 });
    try saved.value("ir_min_area").?.expectEqual(.{ .integer = 7 });
    try saved.value("color_temp").?.expectEqual(.{ .float = 0.50 });
    try saved.value("color_tint").?.expectEqual(.{ .float = -0.10 });
    try saved.value("preview_size").?.expectEqual(.{ .integer = 4096 });

    draft.clear();
    try std.testing.expectEqual(@as(usize, 0), draft.pending().len);
}

test "native UI scanner transitions mirror browser workflow state headlessly" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.beginScannerConnect();
    var status = state.scannerStatus();
    try std.testing.expect(status.connecting);
    try std.testing.expect(!status.connected);
    try std.testing.expectEqualStrings("Connecting...", status.status);

    state.scannerConnected(640, 480, 8.5, 11.7);
    status = state.scannerStatus();
    try std.testing.expect(!status.connecting);
    try std.testing.expect(status.connected);
    try std.testing.expectEqualStrings("", status.status);
    const info = state.scanner.info();
    try std.testing.expectEqual(@as(usize, 640), info.preview_width);
    try std.testing.expectEqual(@as(usize, 480), info.preview_height);
    try std.testing.expectApproxEqAbs(8.5, info.tpu_width_in, 0.0);
    try std.testing.expectApproxEqAbs(11.7, info.tpu_height_in, 0.0);
    try std.testing.expect(state.scanner_capabilities != null);
    try std.testing.expectApproxEqAbs(8.5, state.scanner_capabilities.?.tpu_width_in, 0.0);
    try std.testing.expectApproxEqAbs(11.7, state.scanner_capabilities.?.tpu_height_in, 0.0);

    state.scannerConnectedWithCapabilities(320, 240, .{
        .max_resolution = 3200,
        .tpu_width_in = 2.7,
        .tpu_height_in = 9.54,
    });
    try std.testing.expectEqual(@as(u32, 3200), state.scanner_capabilities.?.max_resolution);
    try std.testing.expectApproxEqAbs(2.7, state.scanner.tpu_width_in, 0.0);
    try std.testing.expectApproxEqAbs(9.54, state.scanner.tpu_height_in, 0.0);

    state.beginScan("Scanning...");
    status = state.scannerStatus();
    try std.testing.expect(status.scanning);
    try std.testing.expectEqualStrings("Scanning...", status.status);

    state.setScanStatus("Saving...");
    status = state.scannerStatus();
    try std.testing.expectEqualStrings("Saving...", status.status);

    state.requestScannerCancel();
    status = state.scannerStatus();
    try std.testing.expect(state.scanner.cancel_requested);
    try std.testing.expectEqualStrings("Cancelling...", status.status);

    state.finishScan();
    status = state.scannerStatus();
    try std.testing.expect(!status.scanning);
    try std.testing.expectEqual(@as(usize, 2), state.scanner.scan_counter);
}

test "native Scan status display renders scanner state messages by priority" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Ready", state.scanStatusDisplay());

    state.beginScannerConnect();
    try std.testing.expectEqualStrings("Connecting...", state.scanStatusDisplay());

    state.scannerFailed("backend unavailable");
    try std.testing.expectEqualStrings("backend unavailable", state.scanStatusDisplay());
    try std.testing.expect(state.scanner_capabilities == null);

    state.scannerConnected(160, 100, 2.7, 9.54);
    state.beginPreviewRequest();
    try std.testing.expectEqualStrings("Scanning preview...", state.scanStatusDisplay());

    state.finishPreviewScan(.{}, .{
        .output_path = "preview.tiff",
        .width = 160,
        .height = 100,
        .samples_per_pixel = 3,
        .bits_per_sample = 8,
        .data_len = 160 * 100 * 3,
    });
    try std.testing.expectEqualStrings("Preview ready", state.scanStatusDisplay());

    state.scan_controls.setSelection(.{ .x = 10.0, .y = 10.0, .w = 30.0, .h = 20.0 });
    try std.testing.expect(state.queueScanStart(null));
    try std.testing.expectEqualStrings("Pass 1/2: Scanning RGB at 3200 DPI...", state.scanStatusDisplay());

    state.applyScannerBackendEvent(.{ .scan_complete = .{
        .output = "scans/scan_0001_rgbir_3200dpi.tiff",
        .metadata = "scans/scan_0001_rgbir_3200dpi.tiff.json",
    } });
    try std.testing.expectEqualStrings("Saved: scan_0001_rgbir_3200dpi.tiff", state.scanStatusDisplay());

    state.beginScan("Scanning...");
    state.requestScannerCancel();
    try std.testing.expectEqualStrings("Cancelling...", state.scanStatusDisplay());

    var error_state = State.init("scans", "frames", 0);
    defer error_state.deinit(std.testing.allocator);
    error_state.beginScan("Scanning...");
    error_state.applyScannerBackendEvent(.{ .scan_error = .{
        .kind = .scanimage_failed,
        .detail = "scanimage failed",
    } });
    try std.testing.expectEqualStrings("scanimage failed", error_state.scanStatusDisplay());
}

test "native Scan selection estimate changes through state selection mode and dpi" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.scannerConnected(1000, 500, 10.0, 5.0);
    state.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });

    var initial_buffer: [192]u8 = undefined;
    const initial = try std.testing.allocator.dupe(
        u8,
        (try scan_workflow.formatScanSelectionEstimate(&initial_buffer, state.scan_controls, state.scanner.info())).?,
    );
    defer std.testing.allocator.free(initial);

    state.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 300.0, .h = 100.0 });
    var resized_buffer: [192]u8 = undefined;
    const resized = try std.testing.allocator.dupe(
        u8,
        (try scan_workflow.formatScanSelectionEstimate(&resized_buffer, state.scan_controls, state.scanner.info())).?,
    );
    defer std.testing.allocator.free(resized);
    try std.testing.expect(!std.mem.eql(u8, initial, resized));

    state.scan_controls.setMode(.rgb);
    state.scan_controls.setDpi(1600);
    var mode_buffer: [192]u8 = undefined;
    const mode_changed = (try scan_workflow.formatScanSelectionEstimate(&mode_buffer, state.scan_controls, state.scanner.info())).?;
    try std.testing.expect(!std.mem.eql(u8, resized, mode_changed));
}

fn expectPendingPreview(state: State, expected_output: []const u8) !void {
    const command = state.pending_command orelse return error.NoPendingCommand;
    switch (command) {
        .preview_scan => |plan| try std.testing.expectEqualStrings(expected_output, plan.output_path),
        .scan_start => return error.ExpectedPreviewCommand,
    }
}

fn expectPendingScan(state: State, expected_output: []const u8) !void {
    const command = state.pending_command orelse return error.NoPendingCommand;
    switch (command) {
        .preview_scan => return error.ExpectedScanCommand,
        .scan_start => |plan| try std.testing.expectEqualStrings(expected_output, plan.output_path),
    }
}

test "native UI rejects duplicate scanner work queues without corrupting commands" {
    var preview_state = State.init("scans", "frames", 0);
    defer preview_state.deinit(std.testing.allocator);
    preview_state.scannerConnected(160, 100, 2.7, 9.54);
    try std.testing.expect(preview_state.queuePreviewScan("/tmp/preview-a.tiff"));
    try std.testing.expect(!preview_state.queuePreviewScan("/tmp/preview-b.tiff"));
    try std.testing.expectEqualStrings("Scanner busy, please wait...", preview_state.status);
    try std.testing.expectEqualStrings("Scanning preview...", preview_state.scanner.scan_status);
    try expectPendingPreview(preview_state, "/tmp/preview-a.tiff");

    var scan_then_preview = State.init("scans", "frames", 0);
    defer scan_then_preview.deinit(std.testing.allocator);
    scan_then_preview.scannerConnected(160, 100, 2.7, 9.54);
    scan_then_preview.scan_controls.setSelection(.{ .x = 10.0, .y = 10.0, .w = 30.0, .h = 20.0 });
    try std.testing.expect(scan_then_preview.queueScanStartPath("/tmp/scan-a.tiff", ".zig-cache/scan-a.cancel"));
    try std.testing.expect(!scan_then_preview.queuePreviewScan("/tmp/preview-after-scan.tiff"));
    try std.testing.expectEqualStrings("Scanner busy, please wait...", scan_then_preview.status);
    try std.testing.expectEqualStrings("Pass 1/2: Scanning RGB at 3200 DPI...", scan_then_preview.scanner.scan_status);
    try expectPendingScan(scan_then_preview, "/tmp/scan-a.tiff");

    var preview_then_scan = State.init("scans", "frames", 0);
    defer preview_then_scan.deinit(std.testing.allocator);
    preview_then_scan.scannerConnected(160, 100, 2.7, 9.54);
    try std.testing.expect(preview_then_scan.queuePreviewScan("/tmp/preview-first.tiff"));
    try std.testing.expect(!preview_then_scan.queueScanStartPath("/tmp/scan-after-preview.tiff", null));
    try std.testing.expectEqualStrings("Scanner busy, please wait...", preview_then_scan.status);
    try expectPendingPreview(preview_then_scan, "/tmp/preview-first.tiff");

    var scan_state = State.init("scans", "frames", 0);
    defer scan_state.deinit(std.testing.allocator);
    scan_state.scannerConnected(160, 100, 2.7, 9.54);
    scan_state.scan_controls.setSelection(.{ .x = 10.0, .y = 10.0, .w = 30.0, .h = 20.0 });
    try std.testing.expect(scan_state.queueScanStartPath("/tmp/scan-first.tiff", ".zig-cache/scan-first.cancel"));
    try std.testing.expect(!scan_state.queueScanStartPath("/tmp/scan-second.tiff", ".zig-cache/scan-second.cancel"));
    try std.testing.expectEqualStrings("Scanner busy, please wait...", scan_state.status);
    try expectPendingScan(scan_state, "/tmp/scan-first.tiff");
}

test "native UI cancellation does not corrupt queued scanner command ownership" {
    var preview_state = State.init("scans", "frames", 0);
    defer preview_state.deinit(std.testing.allocator);
    preview_state.scannerConnected(160, 100, 2.7, 9.54);
    try std.testing.expect(preview_state.queuePreviewScan("/tmp/preview-cancel.tiff"));
    preview_state.requestScannerCancel();
    try std.testing.expect(preview_state.scanner.cancel_requested);
    try std.testing.expectEqualStrings("Cancelling...", preview_state.scanStatusDisplay());
    try expectPendingPreview(preview_state, "/tmp/preview-cancel.tiff");

    var scan_state = State.init("scans", "frames", 0);
    defer scan_state.deinit(std.testing.allocator);
    scan_state.scannerConnected(160, 100, 2.7, 9.54);
    scan_state.scan_controls.setSelection(.{ .x = 10.0, .y = 10.0, .w = 30.0, .h = 20.0 });
    try std.testing.expect(scan_state.queueScanStartPath("/tmp/scan-cancel.tiff", ".zig-cache/scan-cancel.cancel"));
    scan_state.requestScannerCancel();
    try std.testing.expect(scan_state.scanner.cancel_requested);
    try std.testing.expectEqualStrings("Cancelling...", scan_state.scanStatusDisplay());
    try expectPendingScan(scan_state, "/tmp/scan-cancel.tiff");
}

test "native UI processing and gallery transitions are headless state changes" {
    var state = State.init("scans", "frames", 4);
    defer state.deinit(std.testing.allocator);
    const allocator = std.testing.allocator;
    state.processing_preview = .{
        .info = .{
            .width = 10,
            .height = 10,
            .has_ir = false,
            .is_grayscale = false,
            .dpi = null,
            .preview_scale = 1.0,
            .rgb_samples_per_pixel = 3,
            .rgb_bits_per_sample = 8,
        },
        .preview_width = 10,
        .preview_height = 10,
        .preview_raw = try allocator.alloc(u16, 0),
        .preview_rgb8 = try allocator.alloc(u8, 0),
        .jpeg = try allocator.alloc(u8, 0),
    };
    try std.testing.expect(state.processPreviewInteractionReady());

    state.beginProcessingImageLoad("scans/scan_0006_rgbir_800dpi.tiff", 2);
    try std.testing.expectEqual(View.process, state.active_view);
    var info = state.processingInfo();
    try std.testing.expect(info.loading);
    try std.testing.expectEqualStrings("scan_0006_rgbir_800dpi.tiff", info.filename);
    try std.testing.expectEqualStrings("Loading image...", state.status);
    try std.testing.expect(!state.processPreviewInteractionReady());

    state.finishProcessingImageLoad(1272, 6031, true, false, 800, 0.5);
    info = state.processingInfo();
    try std.testing.expect(!info.loading);
    try std.testing.expect(state.processPreviewInteractionReady());
    try std.testing.expect(!state.processing.full_image_ready);
    try std.testing.expectEqual(@as(usize, 1272), info.full_width);
    try std.testing.expectEqual(@as(usize, 6031), info.full_height);
    try std.testing.expectEqual(@as(?u32, 800), info.dpi);
    try std.testing.expectApproxEqAbs(0.5, info.preview_scale, 0.0);
    try std.testing.expectEqualStrings("Image loaded", state.status);

    state.setProcessingProgress("Exporting frame 1/1");
    try std.testing.expectEqualStrings("Exporting frame 1/1", state.processing.progress);
    try std.testing.expectEqualStrings("Exporting frame 1/1", state.status);

    state.show(.gallery);
    try std.testing.expectEqual(View.gallery, state.active_view);
    try std.testing.expectEqualStrings("Gallery", state.activeTitle());
}

test "native Scan numbering resumes after existing scans and never moves backwards" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan_0001_rgb_800dpi.tiff", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan_0007_rgbir_3200dpi.tiff", .data = "" });

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    var state = State.init(dir_path, "frames", 0);
    defer state.deinit(allocator);

    state.syncScanCounter(std.testing.io);
    try std.testing.expectEqual(@as(usize, 8), state.scanner.scan_counter);

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try scan_workflow.scanOutputPath(&path_buffer, state.scanner.output_dir, state.scan_controls, state.scanner.scan_counter);
    try std.testing.expect(std.mem.indexOf(u8, path, "/scan_0008_") != null);

    state.scanner.scan_counter = 20;
    state.syncScanCounter(std.testing.io);
    try std.testing.expectEqual(@as(usize, 20), state.scanner.scan_counter);
}

test "native UI rescans process images with process_handlers /images semantics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.TIFF", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "A.tif", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan.png", .data = "" });

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    var state = State.init(dir_path, "frames", 0);
    defer state.deinit(allocator);

    try state.rescanProcessingImages(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), state.processing.image_count);
    try std.testing.expectEqual(@as(usize, 0), state.processing.image_idx);
    try std.testing.expectEqualStrings("A.tif", std.fs.path.basename(state.processing_images.paths[0]));
    try std.testing.expectEqualStrings("b.TIFF", std.fs.path.basename(state.processing_images.paths[1]));
}

test "native UI switches process image through process_handlers metadata state" {
    const allocator = std.testing.allocator;
    var state = State.init("scans", "frames", 0);
    defer state.deinit(allocator);

    const paths = try allocator.alloc([]u8, 1);
    errdefer allocator.free(paths);
    paths[0] = try allocator.dupe(u8, "test/fixtures/tiff/rgb-thumb-ir.tiff");
    state.processing_images = .{ .paths = paths };
    state.processing.image_count = paths.len;

    const info = try state.switchProcessingImage(allocator, 0, 8192);
    try std.testing.expectEqual(View.process, state.active_view);
    try std.testing.expectEqualStrings("rgb-thumb-ir.tiff", info.filename);
    try std.testing.expectEqual(@as(usize, 0), info.image_idx);
    try std.testing.expectEqual(@as(usize, 1), info.image_count);
    try std.testing.expectEqual(@as(usize, 2), info.full_width);
    try std.testing.expectEqual(@as(usize, 2), info.full_height);
    try std.testing.expect(state.processing.has_ir);
    try std.testing.expectEqual(@as(?u32, 800), info.dpi);
    try std.testing.expectApproxEqAbs(1.0, info.dpi_scale, 0.0);
    try std.testing.expectApproxEqAbs(1.0, info.preview_scale, 0.0);
    try std.testing.expect(!state.processing.loading);
    try std.testing.expect(!state.processing.full_image_ready);
    try std.testing.expect(state.processing_preview != null);
    try std.testing.expectEqual(@as(usize, 2), state.processing_preview.?.preview_width);
    try std.testing.expectEqual(@as(usize, 2), state.processing_preview.?.preview_height);
    try std.testing.expectEqual(@as(usize, 12), state.processing_preview.?.preview_raw.len);
    try std.testing.expect(state.processing_preview.?.jpeg.len > 0);
    try std.testing.expectEqualStrings("rgb-thumb-ir", state.currentProcessingImageStem());
    try std.testing.expectEqualStrings("Image loaded", state.status);
    try std.testing.expect(state.takeProcessAutoDetectPending());
    try std.testing.expect(!state.takeProcessAutoDetectPending());

    var missing_preview = State.init("scans", "frames", 0);
    defer missing_preview.deinit(allocator);
    try std.testing.expect((try missing_preview.renderInvertedProcessingPreview(allocator, .{
        .stock = "kodak_gold",
    })) == null);

    const inverted = (try state.renderInvertedProcessingPreview(allocator, .{
        .stock = "kodak_gold",
    })).?;
    defer allocator.free(inverted);
    try std.testing.expect(state.processing_inverted_cache.scene_linear != null);
    state.invalidateProcessingInversionCache(allocator);
    try std.testing.expect(state.processing_inverted_cache.scene_linear == null);

    try std.testing.expectError(error.InvalidProcessImageIndex, state.switchProcessingImage(allocator, 2, 8192));
    try std.testing.expectEqualStrings("Invalid index", state.status);
}

test "native UI process navigation state mirrors extract_ui image controls" {
    const allocator = std.testing.allocator;
    var empty = State.init("scans", "frames", 0);
    defer empty.deinit(allocator);
    var nav = empty.processingNavigationInfo();
    try std.testing.expect(!nav.can_navigate);
    try std.testing.expect(!nav.preview_ready);
    try std.testing.expectEqualStrings("", nav.filename);
    try std.testing.expect((try empty.switchNextProcessingImage(allocator, 8192)) == null);
    try std.testing.expectEqualStrings("No images", empty.status);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.TIFF", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "A.tif", .data = "" });
    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    var listed = State.init(dir_path, "frames", 0);
    defer listed.deinit(allocator);
    nav = try listed.refreshProcessingImageList(allocator, std.testing.io);
    try std.testing.expect(nav.can_navigate);
    try std.testing.expectEqual(@as(usize, 2), nav.image_count);
    try std.testing.expectEqual(@as(usize, 0), nav.image_idx);

    var state = State.init("scans", "frames", 0);
    defer state.deinit(allocator);
    const paths = try allocator.alloc([]u8, 2);
    paths[0] = try allocator.dupe(u8, "test/fixtures/tiff/rgb-thumb-ir.tiff");
    paths[1] = try allocator.dupe(u8, "test/fixtures/tiff/rgb-thumb-ir.tiff");
    state.processing_images = .{ .paths = paths };
    state.processing.image_count = paths.len;

    _ = try state.switchNextProcessingImage(allocator, 8192);
    try std.testing.expect(state.takeProcessAutoDetectPending());
    try std.testing.expect(!state.takeProcessAutoDetectPending());
    nav = state.processingNavigationInfo();
    try std.testing.expectEqual(@as(usize, 1), nav.image_idx);
    try std.testing.expect(nav.preview_ready);
    try std.testing.expectEqualStrings("rgb-thumb-ir.tiff", nav.filename);

    _ = try state.switchNextProcessingImage(allocator, 8192);
    try std.testing.expect(state.takeProcessAutoDetectPending());
    try std.testing.expectEqual(@as(usize, 0), state.processing.image_idx);
    _ = try state.switchPreviousProcessingImage(allocator, 8192);
    try std.testing.expect(state.takeProcessAutoDetectPending());
    try std.testing.expectEqual(@as(usize, 1), state.processing.image_idx);
}

test "native UI direct process selector refreshes and switches by arbitrary index" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fixture = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test/fixtures/tiff/rgb-thumb-ir.tiff",
        allocator,
        .limited(128 * 1024),
    );
    defer allocator.free(fixture);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan_a.tiff", .data = fixture });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan_b.tiff", .data = fixture });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "scan_c.tiff", .data = fixture });

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    var state = State.init(dir_path, "frames", 0);
    defer state.deinit(allocator);

    const nav = try state.refreshProcessingImageList(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 3), nav.image_count);
    try std.testing.expectEqualStrings("scan_a.tiff", std.fs.path.basename(state.processing_images.paths[0]));
    try std.testing.expectEqualStrings("scan_c.tiff", std.fs.path.basename(state.processing_images.paths[2]));

    _ = try state.switchProcessingImage(allocator, 0, 8192);
    try std.testing.expect(state.takeProcessAutoDetectPending());
    try std.testing.expect(!state.takeProcessAutoDetectPending());

    const info = (try state.switchProcessingImageAfterRefresh(allocator, std.testing.io, 2, 8192)).?;
    try std.testing.expectEqual(@as(usize, 2), info.image_idx);
    try std.testing.expectEqual(@as(usize, 3), info.image_count);
    try std.testing.expectEqualStrings("scan_c.tiff", info.filename);
    try std.testing.expectEqualStrings("scan_c.tiff", std.fs.path.basename(state.processing.input_path));
    try std.testing.expect(state.processing_preview != null);
    try std.testing.expect(state.takeProcessAutoDetectPending());
    try std.testing.expect(!state.takeProcessAutoDetectPending());

    try state.rescanProcessingImages(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), state.processing.image_idx);
    try std.testing.expectEqualStrings("scan_c.tiff", std.fs.path.basename(state.processing.input_path));

    try std.testing.expectError(
        error.InvalidProcessImageIndex,
        state.switchProcessingImageAfterRefresh(allocator, std.testing.io, 99, 8192),
    );
    try std.testing.expectEqualStrings("Invalid index", state.status);
}

test "native UI process preview mode falls back like extract_ui preview image" {
    const allocator = std.testing.allocator;
    var state = State.init("scans", "frames", 0);
    defer state.deinit(allocator);
    const paths = try allocator.alloc([]u8, 1);
    paths[0] = try allocator.dupe(u8, "test/fixtures/tiff/rgb-thumb-ir.tiff");
    state.processing_images = .{ .paths = paths };
    state.processing.image_count = paths.len;
    _ = try state.switchProcessingImage(allocator, 0, 8192);

    const response = (try state.renderSelectedProcessingPreview(allocator, .{})).?;
    defer response.deinit(allocator);
    try std.testing.expect(!response.used_inverted);
    try std.testing.expect(!response.fell_back_to_quick);
    try std.testing.expectEqualSlices(u8, state.processing_preview.?.jpeg, response.jpeg);

    state.setProcessingPreviewInversionEnabled(true);
    const fallback = (try state.renderSelectedProcessingPreview(allocator, .{})).?;
    defer fallback.deinit(allocator);
    try std.testing.expect(!fallback.used_inverted);
    try std.testing.expect(fallback.fell_back_to_quick);
    try std.testing.expectEqualSlices(u8, state.processing_preview.?.jpeg, fallback.jpeg);

    const unknown_stock = (try state.renderSelectedProcessingPreview(allocator, .{
        .stock = "missing-stock",
    })).?;
    defer unknown_stock.deinit(allocator);
    try std.testing.expect(!unknown_stock.used_inverted);
    try std.testing.expect(unknown_stock.fell_back_to_quick);

    const inverted = (try state.renderSelectedProcessingPreview(allocator, .{
        .stock = "kodak_gold",
    })).?;
    defer inverted.deinit(allocator);
    try std.testing.expect(inverted.used_inverted);
    try std.testing.expect(!inverted.fell_back_to_quick);
    try std.testing.expect(state.processing_inverted_cache.scene_linear != null);

    var no_preview = State.init("scans", "frames", 0);
    defer no_preview.deinit(allocator);
    try std.testing.expect((try no_preview.renderSelectedProcessingPreview(allocator, .{
        .stock = "kodak_gold",
    })) == null);
}

test "native UI processing GPU request is state-owned and feeds inverted preview options" {
    const allocator = std.testing.allocator;
    var state = State.init("scans", "frames", 0);
    defer state.deinit(allocator);

    try std.testing.expectEqual(processing_webgpu.Backend.cpu, state.processingInvertedPreviewOptions().invert_request.backend);
    state.processing_inverted_cache.scene_linear = try allocator.alloc(f64, 3);
    state.setProcessingGpuRequest(allocator, .{
        .backend = .webgpu,
        .fallback = .allow_cpu,
    });
    const options = state.processingInvertedPreviewOptions();
    try std.testing.expectEqual(processing_webgpu.Backend.webgpu, options.invert_request.backend);
    try std.testing.expectEqual(processing_webgpu.FallbackPolicy.allow_cpu, options.invert_request.fallback);
    try std.testing.expect(state.processing_inverted_cache.scene_linear == null);
}

test "native UI process settings and stocks mirror process_handlers routes" {
    const allocator = std.testing.allocator;
    var state = State.init("scans", "frames", 0);
    defer state.deinit(allocator);

    const custom_text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test/fixtures/processing/config/custom-stock-save.toml",
        allocator,
        .limited(128 * 1024),
    );
    defer allocator.free(custom_text);
    state.applyProcessingConfig(processing_config.parseText(custom_text));
    try state.processing_config.set("_stocks", .{ .boolean = true });

    var entries_buffer: [32]processing_config.Entry = undefined;
    const settings = state.processingSettingsInfo(&entries_buffer);
    try std.testing.expectEqualStrings("custom_c41", settings.active_stock.?);
    try std.testing.expect(!settings.preview_inversion);
    var saw_stock = false;
    for (settings.entries) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.name.slice(), "_stocks"));
        if (std.mem.eql(u8, entry.name.slice(), "stock")) saw_stock = true;
    }
    try std.testing.expect(saw_stock);

    var stocks_buffer: [16]ProcessStockChoice = undefined;
    const stocks = try state.processingStocksInfo(&stocks_buffer);
    try std.testing.expectEqualStrings("custom_c41", stocks.active.?);
    try std.testing.expectEqual(@as(usize, 3), stocks.stocks.len);
    try std.testing.expectEqualStrings("kodak_gold", stocks.stocks[0].name);
    try std.testing.expectEqualStrings("Kodak Gold 200 on Epson V600", stocks.stocks[0].description);
    try std.testing.expectEqualStrings("kodak_portra", stocks.stocks[1].name);
    try std.testing.expectEqualStrings("custom_c41", stocks.stocks[2].name);
    try std.testing.expectEqualStrings("Custom C-41 test profile", stocks.stocks[2].description);

    const partial_text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test/fixtures/processing/config/partial-save.toml",
        allocator,
        .limited(128 * 1024),
    );
    defer allocator.free(partial_text);
    state.applyProcessingConfig(processing_config.parseText(partial_text));
    try std.testing.expect(state.processing_preview_inversion_enabled);
    try std.testing.expectApproxEqAbs(0.2, state.processing.dmin.?[1], 0.0);
    state.processing_inverted_cache.scene_linear = try allocator.alloc(f64, 3);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/{s}",
        .{ tmp.sub_path[0..], processing_config.config_file },
    );
    defer allocator.free(config_path);
    const updates = [_]processing_config.Override{
        .{ .name = "stock", .value = .{ .string = processing_config.FixedString.init("kodak_portra") } },
        .{ .name = "preview_inversion", .value = .{ .boolean = false } },
    };
    try state.saveProcessingSettings(allocator, std.testing.io, config_path, &updates);
    try std.testing.expect(state.processing_inverted_cache.scene_linear == null);
    try std.testing.expect(!state.processing_preview_inversion_enabled);
    try std.testing.expectEqualStrings("kodak_portra", state.processing_config.activeStock().?);
    const preview_options = state.processingInvertedPreviewOptions();
    try std.testing.expectEqualStrings("kodak_portra", preview_options.stock.?);
    try std.testing.expectApproxEqAbs(1.6, preview_options.render_options.contrast, 0.0);
    try std.testing.expectApproxEqAbs(0.0, preview_options.render_options.color_temp, 0.0);

    const saved = try processing_config.loadFile(allocator, std.testing.io, config_path);
    try saved.value("stock").?.expectEqual(.{ .string = processing_config.FixedString.init("kodak_portra") });
    try saved.value("preview_inversion").?.expectEqual(.{ .boolean = false });
    try saved.value("dmin").?.expectEqual(.{ .list = try processing_config.FloatList.init(&.{ 0.1, 0.2, 0.3 }) });

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(processing_config.config_file, try processingConfigPath(&path_buffer));
}

test "native UI auto-detect selections mirror extract_ui export geometry" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.processing.preview_scale = 0.5;
    const frames = [_]processing_frames.FrameRect{
        .{ .cx = 100.0, .cy = 80.0, .w = 40.0, .h = 20.0, .angle = std.math.pi / 18.0 },
        .{ .cx = 180.0, .cy = 82.0, .w = 42.0, .h = 22.0, .angle = -std.math.pi / 36.0 },
    };
    try state.applyProcessAutoDetect(
        &frames,
        "3:2",
        .{ .cx = 140.0, .cy = 30.0, .w = 12.0, .h = 8.0, .angle = 0.25 },
        10.0,
        90,
    );
    try std.testing.expectEqual(@as(usize, 2), state.process_selection_count);
    try std.testing.expectEqual(@as(?usize, 0), state.process_active_selection);
    try std.testing.expectEqualStrings("Detected 2 frames (3:2)", state.status);

    const first = state.process_selections[0];
    try std.testing.expectApproxEqAbs(78.0, first.x, 0.0);
    try std.testing.expectApproxEqAbs(69.0, first.y, 0.0);
    try std.testing.expectApproxEqAbs(44.0, first.w, 0.0);
    try std.testing.expectApproxEqAbs(22.0, first.h, 0.0);
    try std.testing.expectApproxEqAbs(std.math.pi / 18.0, first.angle, 0.0);
    try std.testing.expectEqual(@as(i32, 90), first.rotation);
    try std.testing.expectApproxEqAbs(134.0, state.process_rebate_rect.?.x, 0.0);
    try std.testing.expectApproxEqAbs(26.0, state.process_rebate_rect.?.y, 0.0);

    var out: [64]processing_export.FrameRect = undefined;
    const export_rects = try state.processExportRects(&out);
    try std.testing.expectEqual(@as(usize, 2), export_rects.len);
    try std.testing.expectApproxEqAbs(200.0, export_rects[0].cx, 0.0);
    try std.testing.expectApproxEqAbs(160.0, export_rects[0].cy, 0.0);
    try std.testing.expectApproxEqAbs(88.0, export_rects[0].w, 0.0);
    try std.testing.expectApproxEqAbs(44.0, export_rects[0].h, 0.0);
    try std.testing.expectApproxEqAbs(10.0, export_rects[0].angle, 0.0000001);
    try std.testing.expectEqual(@as(i32, 90), export_rects[0].rotation);

    state.rescaleProcessAutoSelections(0.0);
    try std.testing.expectApproxEqAbs(80.0, state.process_selections[0].x, 0.0);
    try std.testing.expectApproxEqAbs(70.0, state.process_selections[0].y, 0.0);
    try std.testing.expectApproxEqAbs(40.0, state.process_selections[0].w, 0.0);
    try std.testing.expectEqual(@as(i32, 90), state.process_selections[0].rotation);

    state.processing.rebate_rect = .{ .x = 268.0, .y = 52.0, .w = 24.0, .h = 16.0, .angle = 0.25 };
    state.processing.dmin = .{ 0.1, 0.2, 0.3 };
    state.processing_inverted_cache.scene_linear = try std.testing.allocator.alloc(f64, 3);
    state.clearProcessingSelections();
    try std.testing.expectEqual(@as(usize, 0), state.process_selection_count);
    try std.testing.expect(state.process_active_selection == null);
    try std.testing.expectEqual(@as(usize, 2), state.process_last_auto_count);
    try std.testing.expect(state.process_rebate_rect != null);
    try std.testing.expect(state.processing.rebate_rect != null);
    try std.testing.expect(state.processing.dmin != null);
    try std.testing.expect(state.processing_inverted_cache.scene_linear != null);

    state.rescaleProcessAutoSelections(0.0);
    try std.testing.expectEqual(@as(usize, 2), state.process_selection_count);
    try std.testing.expectEqual(@as(?usize, 0), state.process_active_selection);

    state.clearProcessingImageSelections();
    try std.testing.expectEqual(@as(usize, 0), state.process_selection_count);
    try std.testing.expect(state.process_active_selection == null);
    try std.testing.expectEqual(@as(usize, 0), state.process_last_auto_count);
    try std.testing.expect(state.process_rebate_rect == null);
    try std.testing.expect(state.processing.rebate_rect == null);
    try std.testing.expect(state.processing.dmin != null);
    try std.testing.expect(state.processing_inverted_cache.scene_linear != null);
}

test "native Process dump selections formats diagnostics and status without mutation" {
    const allocator = std.testing.allocator;
    var empty = State.init("scans", "frames", 0);
    defer empty.deinit(allocator);
    empty.processing.preview_scale = 0.5;

    var empty_buffer = std.array_list.Managed(u8).init(allocator);
    defer empty_buffer.deinit();
    var empty_writer = ProcessSelectionDumpBufferWriter{ .buffer = &empty_buffer };
    try empty.dumpProcessSelectionsTo(&empty_writer);
    try std.testing.expectEqualStrings(
        \\
        \\  === Selections (0 frames) ===
        \\  preview_scale=0.5000
        \\
    ,
        empty_buffer.items,
    );
    try std.testing.expectEqualStrings("Dumped 0 selections to server console", empty.status);

    var state = State.init("scans", "frames", 0);
    defer state.deinit(allocator);
    state.processing.preview_scale = 0.25;
    _ = try state.addProcessSelection(.{ .x = 1.0, .y = 2.0, .w = 30.0, .h = 20.0, .angle = 0.25, .rotation = 270 });
    _ = try state.addProcessSelection(.{ .x = 40.5, .y = 3.24, .w = 31.74, .h = 21.12, .angle = -0.125, .rotation = 90 });
    state.process_active_selection = 1;

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var writer = ProcessSelectionDumpBufferWriter{ .buffer = &buffer };
    try state.dumpProcessSelectionsTo(&writer);
    try std.testing.expectEqualStrings(
        \\
        \\  === Selections (2 frames) ===
        \\  preview_scale=0.2500
        \\  Frame 1: x=1.0 y=2.0 w=30.0 h=20.0 angle=0.2500
        \\  Frame 2: x=40.5 y=3.2 w=31.7 h=21.1 angle=-0.1250
        \\
    ,
        buffer.items,
    );
    try std.testing.expectEqual(@as(usize, 2), state.process_selection_count);
    try std.testing.expectEqual(@as(?usize, 1), state.process_active_selection);
    try std.testing.expectEqualStrings("Dumped 2 selections to server console", state.status);
}

test "native UI manual process selection list mirrors extract_ui add remove semantics" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);

    const first = try state.addProcessSelection(.{ .x = 1.0, .y = 2.0, .w = 30.0, .h = 20.0, .rotation = 270 });
    const second = try state.addProcessSelection(.{ .x = 40.0, .y = 2.0, .w = 30.0, .h = 20.0, .rotation = 90 });
    try std.testing.expectEqual(@as(usize, 0), first);
    try std.testing.expectEqual(@as(usize, 1), second);
    try std.testing.expectEqual(@as(?usize, 1), state.process_active_selection);
    try std.testing.expectEqual(@as(usize, 2), state.process_selection_count);

    try std.testing.expect(state.removeProcessSelection(0));
    try std.testing.expectEqual(@as(usize, 1), state.process_selection_count);
    try std.testing.expectEqual(@as(?usize, 0), state.process_active_selection);
    try std.testing.expectApproxEqAbs(40.0, state.process_selections[0].x, 0.0);
    try std.testing.expectEqual(@as(i32, 90), state.process_selections[0].rotation);

    try std.testing.expect(state.removeProcessSelection(0));
    try std.testing.expectEqual(@as(usize, 0), state.process_selection_count);
    try std.testing.expect(state.process_active_selection == null);
    try std.testing.expect(!state.removeProcessSelection(0));
}

test "native UI drawn process frame finalization mirrors browser fixed 10 px threshold" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);

    const narrow = try state.addProcessSelection(.{ .x = 0.0, .y = 0.0, .w = 9.99, .h = 10.0 });
    try std.testing.expectEqual(ProcessDrawnFrameFinalization.removed_too_small, state.finalizeProcessDrawnFrame(narrow));
    try std.testing.expectEqual(@as(usize, 0), state.process_selection_count);
    try std.testing.expectEqualStrings("Selection too small, cleared", state.status);

    const short = try state.addProcessSelection(.{ .x = 0.0, .y = 0.0, .w = 10.0, .h = 9.99 });
    try std.testing.expectEqual(ProcessDrawnFrameFinalization.removed_too_small, state.finalizeProcessDrawnFrame(short));
    try std.testing.expectEqual(@as(usize, 0), state.process_selection_count);

    const exact = try state.addProcessSelection(.{ .x = 0.0, .y = 0.0, .w = process_draw_frame_min_size, .h = process_draw_frame_min_size });
    try std.testing.expect(processDrawnFrameAccepted(state.process_selections[exact]));
    try std.testing.expectEqual(ProcessDrawnFrameFinalization.accepted, state.finalizeProcessDrawnFrame(exact));
    try std.testing.expectEqual(@as(usize, 1), state.process_selection_count);
    try std.testing.expectEqualStrings("Selection added", state.status);

    try std.testing.expectEqual(ProcessDrawnFrameFinalization.invalid_index, state.finalizeProcessDrawnFrame(7));
}

test "native UI auto-detect workflow mirrors no-image route boundary" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);

    try std.testing.expectError(error.NoProcessImageLoaded, state.runProcessAutoDetect(std.testing.allocator, .{
        .format = "35mm",
    }));
    try std.testing.expectEqualStrings("No image loaded", state.status);
}

test "native UI auto-detect suggested rebate computes and persists Dmin" {
    const allocator = std.testing.allocator;
    var state = State.init("scans", "frames", 0);
    defer state.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/{s}",
        .{ tmp.sub_path[0..], processing_config.config_file },
    );
    defer allocator.free(config_path);

    state.processing_images.paths = try allocator.alloc([]u8, 1);
    state.processing_images.paths[0] = try allocator.dupe(u8, "test/fixtures/tiff/rgb-thumb-ir.tiff");
    state.processing.image_count = 1;
    state.processing.image_idx = 0;
    state.processing.preview_scale = 1.0;
    state.processing_inverted_cache.scene_linear = try allocator.alloc(f64, 3);

    const frames = [_]processing_frames.FrameRect{
        .{ .cx = 4.0, .cy = 4.0, .w = 4.0, .h = 4.0, .angle = 0.0 },
    };
    try state.applyProcessAutoDetect(
        &frames,
        "1:1",
        .{ .cx = 1.0, .cy = 1.0, .w = 2.0, .h = 2.0, .angle = 0.0 },
        0.0,
        0,
    );

    try std.testing.expect(try state.runProcessAutoDetectRebate(allocator, std.testing.io, config_path));
    try std.testing.expect(state.processing.dmin != null);
    try std.testing.expect(state.processing_inverted_cache.scene_linear == null);
    try std.testing.expectApproxEqAbs(2.0, state.processing.rebate_rect.?.w, 0.0);
    const dmin = state.processing.dmin.?;
    const saved = try processing_config.loadFile(allocator, std.testing.io, config_path);
    try saved.value("dmin").?.expectEqual(.{ .list = try processing_config.FloatList.init(&dmin) });
}

test "native UI rebate controls mirror extract_ui rebate state" {
    const allocator = std.testing.allocator;
    var state = State.init("scans", "frames", 0);
    defer state.deinit(allocator);
    state.processing.preview_scale = 0.25;

    try std.testing.expectEqualStrings("Dmin: not set", state.processDminDisplay());
    try std.testing.expect(try state.setProcessRebatePreviewRect(.{
        .x = 20.0,
        .y = 12.0,
        .w = 30.4,
        .h = 10.6,
        .angle = 0.25,
    }));
    try std.testing.expectEqualStrings("Rebate set (30x11 px)", state.status);
    try std.testing.expectApproxEqAbs(20.0, state.process_rebate_rect.?.x, 0.0);

    const request = (try state.processRebateRequest()).?;
    try std.testing.expectApproxEqAbs(80.0, request.x, 0.0);
    try std.testing.expectApproxEqAbs(48.0, request.y, 0.0);
    try std.testing.expectApproxEqAbs(121.6, request.w, 0.0000001);
    try std.testing.expectApproxEqAbs(42.4, request.h, 0.0000001);
    try std.testing.expectApproxEqAbs(0.25, request.angle, 0.0);
    try std.testing.expectApproxEqAbs(request.x, state.processing.rebate_rect.?.x, 0.0);
    try std.testing.expect(!state.processRebateInfo().has_dmin);

    state.processing_inverted_cache.scene_linear = try allocator.alloc(f64, 3);
    state.applyProcessRebateDmin(allocator, .{ 0.1234, 0.5678, 1.0 });
    const info = state.processRebateInfo();
    try std.testing.expect(info.has_dmin);
    try std.testing.expectApproxEqAbs(0.5678, info.dmin.?[1], 0.0);
    try std.testing.expectEqualStrings("Dmin: 0.123 0.568 1.000", info.dmin_display);
    try std.testing.expect(state.processing_inverted_cache.scene_linear == null);

    try std.testing.expect(!try state.setProcessRebatePreviewRect(.{
        .x = 1.0,
        .y = 2.0,
        .w = 5.0,
        .h = 8.0,
        .angle = 0.0,
    }));
    try std.testing.expect(state.process_rebate_rect == null);
    try std.testing.expect(state.processing.rebate_rect == null);
    try std.testing.expectEqualStrings("Rebate selection too small, cleared", state.status);

    state.processing.preview_scale = 0.0;
    try std.testing.expectError(error.InvalidPreviewScale, state.setProcessRebatePreviewRect(.{
        .x = 10.0,
        .y = 10.0,
        .w = 20.0,
        .h = 20.0,
        .angle = 0.0,
    }));
    try std.testing.expect(state.process_rebate_rect == null);
}

test "native UI rebate workflow mirrors process_handlers route" {
    const allocator = std.testing.allocator;
    var state = State.init("scans", "frames", 0);
    defer state.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/{s}",
        .{ tmp.sub_path[0..], processing_config.config_file },
    );
    defer allocator.free(config_path);

    try std.testing.expectError(error.NoProcessImageLoaded, state.runProcessRebate(allocator, std.testing.io, config_path, .{
        .x = 0.0,
        .y = 0.0,
        .w = 2.0,
        .h = 2.0,
        .angle = 0.0,
    }));
    try std.testing.expectEqualStrings("No image loaded", state.status);

    state.processing_images.paths = try allocator.alloc([]u8, 1);
    state.processing_images.paths[0] = try allocator.dupe(u8, "test/fixtures/tiff/rgb-thumb-ir.tiff");
    state.processing.image_count = 1;
    state.processing.image_idx = 0;
    state.processing_inverted_cache.scene_linear = try allocator.alloc(f64, 3);

    const rect: app_state.RebateRect = .{ .x = 0.0, .y = 0.0, .w = 2.0, .h = 2.0, .angle = 0.0 };
    const dmin = try state.runProcessRebate(allocator, std.testing.io, config_path, rect);
    try std.testing.expect(state.processing_inverted_cache.scene_linear == null);
    try std.testing.expectApproxEqAbs(dmin[1], state.processing.dmin.?[1], 0.0);
    try std.testing.expectApproxEqAbs(rect.w, state.processing.rebate_rect.?.w, 0.0);

    const saved = try processing_config.loadFile(allocator, std.testing.io, config_path);
    try saved.value("dmin").?.expectEqual(.{ .list = try processing_config.FloatList.init(&dmin) });
    try state.processing_config.value("dmin").?.expectEqual(.{ .list = try processing_config.FloatList.init(&dmin) });
}

test "native UI export controls mirror extract_ui request and progress state" {
    var empty = State.init("scans", "frames", 0);
    defer empty.deinit(std.testing.allocator);
    var rect_buffer: [64]processing_export.FrameRect = undefined;
    try std.testing.expect((try empty.beginProcessExport(.{}, &rect_buffer)) == null);
    try std.testing.expectEqualStrings("No selections to export", empty.status);
    try std.testing.expectEqualStrings("No selections to export", empty.processing.progress);

    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.processing.preview_scale = 0.5;
    state.processing.input_path = "scans/roll.001.rgbir.tiff";
    try std.testing.expectEqualStrings("roll.001.rgbir", state.currentProcessingImageStem());
    state.process_selections[0] = .{
        .x = 10.0,
        .y = 20.0,
        .w = 30.0,
        .h = 40.0,
        .angle = std.math.pi / 6.0,
        .rotation = 180,
    };
    state.process_selection_count = 1;

    const request = (try state.beginProcessExport(.{}, &rect_buffer)).?;
    try std.testing.expectEqualStrings("frame", request.basename);
    try std.testing.expect(!request.outputs.ir_neg);
    try std.testing.expect(request.outputs.ir_inv);
    try std.testing.expect(!request.outputs.inv_only);
    try std.testing.expectEqual(@as(usize, 1), request.rects.len);
    try std.testing.expectApproxEqAbs(50.0, request.rects[0].cx, 0.0);
    try std.testing.expectApproxEqAbs(80.0, request.rects[0].cy, 0.0);
    try std.testing.expectApproxEqAbs(60.0, request.rects[0].w, 0.0);
    try std.testing.expectApproxEqAbs(80.0, request.rects[0].h, 0.0);
    try std.testing.expectApproxEqAbs(30.0, request.rects[0].angle, 0.0000001);
    try std.testing.expectEqual(@as(i32, 180), request.rects[0].rotation);
    try std.testing.expect(state.process_exporting);
    try std.testing.expectEqualStrings("Starting export...", state.status);

    const no_output_request = (try state.beginProcessExport(.{
        .basename = "roll",
        .export_ir_inv = false,
    }, &rect_buffer)).?;
    try std.testing.expectEqualStrings("roll", no_output_request.basename);
    try std.testing.expect(!no_output_request.outputs.any());

    state.applyProcessingBackendEvent(.{ .export_progress = .{ .message = "Processing 1 frame..." } });
    try std.testing.expectEqualStrings("Processing 1 frame...", state.status);
    state.applyProcessingBackendEvent(.{ .file_written = .{ .file = "roll_01.tif" } });
    try std.testing.expectEqual(@as(usize, 1), state.process_export_files_written);
    try std.testing.expectEqualStrings("Wrote roll_01.tif", state.status);
    state.applyProcessingBackendEvent(.{ .export_complete = .{ .file_count = 1, .output_dir = "frames" } });
    try std.testing.expect(!state.process_exporting);
    try std.testing.expectEqual(@as(usize, 1), state.process_export_files_written);
    try std.testing.expectEqualStrings("Exported 1 file to frames/", state.status);

    state.applyProcessingBackendEvent(.{ .processing_error = .{ .operation = "export", .detail = "disk full" } });
    try std.testing.expectEqualStrings("Export failed: disk full", state.status);
    state.applyProcessingBackendEvent(.{ .export_cancelled = .{ .detail = "cancel file observed" } });
    try std.testing.expectEqualStrings("Export cancelled: cancel file observed", state.status);

    state.finishProcessExport("No output variants selected", 0);
    const export_status = state.processExportStatus();
    try std.testing.expect(!export_status.exporting);
    try std.testing.expectEqual(@as(usize, 0), export_status.files_written);
    try std.testing.expectEqualStrings("No output variants selected", export_status.status);
}

test "native UI export workflow mirrors process_handlers handle_export" {
    const allocator = std.testing.allocator;
    var state = State.init("scans", "frames", 0);
    defer state.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/frames", .{tmp.sub_path[0..]});
    defer allocator.free(output_dir);
    state.processing.output_dir = output_dir;
    state.processing.preview_scale = 1.0;
    state.processing.current_dpi = 800;
    state.processing.rebate_rect = .{ .x = 0.0, .y = 0.0, .w = 2.0, .h = 2.0, .angle = 0.0 };
    state.applyProcessingConfig(processing_config.parseText(
        \\stock = "kodak_gold"
        \\
    ));
    state.processing_images.paths = try allocator.alloc([]u8, 1);
    state.processing_images.paths[0] = try allocator.dupe(u8, "test/fixtures/tiff/rgb-thumb-ir.tiff");
    state.processing.image_count = 1;
    state.processing.image_idx = 0;
    state.process_selections[0] = .{ .x = 0.0, .y = 0.0, .w = 2.0, .h = 2.0, .angle = 0.0, .rotation = 0 };
    state.process_selection_count = 1;

    var rect_buffer: [64]processing_export.FrameRect = undefined;
    const result = (try state.runProcessExport(allocator, std.testing.io, .{
        .basename = "roll",
        .export_ir_inv = false,
        .export_inv_only = true,
    }, &rect_buffer, 0.04)).?;
    defer result.deinit(allocator);

    try std.testing.expect(!state.process_exporting);
    try std.testing.expectEqual(@as(usize, 1), state.process_export_files_written);
    const expected_status = try std.fmt.allocPrint(allocator, "Exported 1 file to {s}/ (0.0s)", .{output_dir});
    defer allocator.free(expected_status);
    try std.testing.expectEqualStrings(expected_status, state.status);
    try std.testing.expect(state.processing.dmin != null);
    try std.testing.expectEqualStrings("roll_01_inv.tif", result.files[0]);
    const output_path = try std.fs.path.join(allocator, &.{ output_dir, result.files[0] });
    defer allocator.free(output_path);
    try std.Io.Dir.cwd().access(std.testing.io, output_path, .{});
}

test "native UI scan trash and delete mirror extract_ui image recovery" {
    const allocator = std.testing.allocator;
    var empty = State.init("scans", "frames", 0);
    defer empty.deinit(allocator);
    try std.testing.expectError(error.NoProcessImageLoaded, empty.trashCurrentProcessingImage(allocator, std.testing.io, 8192));
    try std.testing.expectEqualStrings("No image loaded", empty.status);

    const fixture = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test/fixtures/tiff/rgb-thumb-ir.tiff",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(fixture);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.tif", .data = fixture });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.tif", .data = fixture });
    try tmp.dir.createDir(std.testing.io, ".trash", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".trash/a.tif", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".trash/a_1.tif", .data = "" });

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    var state = State.init(dir_path, "frames", 0);
    defer state.deinit(allocator);
    try state.rescanProcessingImages(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), state.processing.image_count);

    const trashed = try state.trashCurrentProcessingImage(allocator, std.testing.io, 8192);
    try std.testing.expectEqualStrings("Moved a.tif to trash", trashed.message);
    try std.testing.expectEqual(@as(usize, 0), trashed.image_idx);
    try std.testing.expectEqual(@as(usize, 1), trashed.image_count);
    try std.testing.expect(trashed.switched);
    try std.testing.expectEqualStrings("b.tif", std.fs.path.basename(state.processing.input_path));
    try tmp.dir.access(std.testing.io, ".trash/a_2.tif", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "a.tif", .{}));

    const deleted = try state.deleteCurrentProcessingImage(allocator, std.testing.io, 8192);
    try std.testing.expectEqualStrings("Deleted b.tif", deleted.message);
    try std.testing.expectEqual(@as(usize, 0), deleted.image_count);
    try std.testing.expect(!deleted.switched);
    try std.testing.expectEqualStrings("", state.processing.input_path);
    try std.testing.expectEqualStrings("Deleted b.tif", state.status);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "b.tif", .{}));
}

test "native UI gallery handoff mirrors browser list navigation and mutations" {
    const allocator = std.testing.allocator;

    var missing = State.init("scans", ".zig-cache/tmp/cerealgrain-gallery-state-missing", 0);
    defer missing.deinit(allocator);
    var info = try missing.refreshGalleryFiles(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), info.image_count);
    try std.testing.expect(info.active_index == null);
    try std.testing.expect(!info.can_navigate);
    try std.testing.expectEqualStrings("No exports found", info.status);
    try std.testing.expectError(error.NoGalleryFileSelected, missing.trashCurrentGalleryFile(allocator, std.testing.io));
    try std.testing.expectEqualStrings("No exports found", missing.status);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.tif", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.TIFF", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "" });
    try tmp.dir.createDir(std.testing.io, ".trash", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".trash/b.TIFF", .data = "" });

    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(dir_path);
    var state = State.init("scans", dir_path, 0);
    defer state.deinit(allocator);

    info = try state.refreshGalleryFiles(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), info.image_count);
    try std.testing.expectEqual(@as(?usize, 0), info.active_index);
    try std.testing.expectEqualStrings("a.tif", info.filename);
    try std.testing.expectEqualStrings("2 exported frames", info.status);
    try std.testing.expectEqualStrings("a.tif", state.gallery_files.files[0]);
    try std.testing.expectEqualStrings("b.TIFF", state.gallery_files.files[1]);

    info = try state.showGalleryImage(1);
    try std.testing.expectEqual(@as(?usize, 1), info.active_index);
    try std.testing.expectEqualStrings("b.TIFF", info.filename);
    try std.testing.expectEqualStrings("2/2: b.TIFF", info.status);

    info = try state.switchNextGalleryImage();
    try std.testing.expectEqual(@as(?usize, 0), info.active_index);
    try std.testing.expectEqualStrings("a.tif", info.filename);
    info = try state.switchPreviousGalleryImage();
    try std.testing.expectEqual(@as(?usize, 1), info.active_index);
    try std.testing.expectEqualStrings("b.TIFF", info.filename);

    var trashed = try state.trashCurrentGalleryFile(allocator, std.testing.io);
    defer trashed.deinit(allocator);
    try std.testing.expectEqualStrings("Moved b.TIFF to trash", trashed.message);
    try tmp.dir.access(std.testing.io, ".trash/b_1.TIFF", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "b.TIFF", .{}));
    info = state.galleryInfo();
    try std.testing.expectEqual(@as(?usize, 0), info.active_index);
    try std.testing.expectEqual(@as(usize, 1), info.image_count);
    try std.testing.expectEqualStrings("a.tif", info.filename);
    try std.testing.expectEqualStrings("1 exported frame", info.status);

    var deleted = try state.deleteCurrentGalleryFile(allocator, std.testing.io);
    defer deleted.deinit(allocator);
    try std.testing.expectEqualStrings("Deleted a.tif", deleted.message);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "a.tif", .{}));
    info = state.galleryInfo();
    try std.testing.expectEqual(@as(usize, 0), info.image_count);
    try std.testing.expect(info.active_index == null);
    try std.testing.expectEqualStrings("No exports found", info.status);

    state.status = "unchanged";
    try std.testing.expect(!(try state.refreshGalleryFilesIfChanged(allocator, std.testing.io)));
    try std.testing.expectEqualStrings("unchanged", state.status);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "c.tif", .data = "" });
    try std.testing.expect(try state.refreshGalleryFilesIfChanged(allocator, std.testing.io));
    info = state.galleryInfo();
    try std.testing.expectEqual(@as(usize, 1), info.image_count);
    try std.testing.expectEqualStrings("c.tif", info.filename);
    try std.testing.expectEqualStrings("1 exported frame", info.status);
}

test "native UI preview status follows scanner backend events headlessly" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.applyScannerBackendEvent(.{ .scan_start = .{
        .device = "epkowa:interpreter:001:017",
        .output = "/tmp/cerealgrain-preview.tiff",
        .source = .tpu,
        .kind = .rgb,
        .requested_dpi = 200,
        .effective_dpi = 200,
    } });
    var status = state.scannerStatus();
    try std.testing.expectEqual(View.scan, state.active_view);
    try std.testing.expect(state.preview_requested);
    try std.testing.expect(status.scanning);
    try std.testing.expectEqualStrings("Scanning preview...", status.status);

    state.applyScannerBackendEvent(.{ .progress = .{ .percent = 42 } });
    status = state.scannerStatus();
    try std.testing.expectEqual(@as(?u8, 42), state.scanner_progress_percent);
    try std.testing.expectEqualStrings("Scanning preview...", status.status);

    state.applyScannerBackendEvent(.{ .scan_complete = .{
        .output = "/tmp/cerealgrain-preview.tiff",
        .metadata = "/tmp/cerealgrain-preview.tiff.json",
    } });
    status = state.scannerStatus();
    try std.testing.expect(!status.scanning);
    try std.testing.expect(!state.preview_requested);
    try std.testing.expect(state.preview_ready);
    try std.testing.expectEqual(@as(?u8, null), state.scanner_progress_percent);
    try std.testing.expectEqualStrings("Preview ready", status.status);
    try std.testing.expect(!state.takeScanFinished());
}

test "native Scan progress shows ETA, elapsed time, and the combined RGB+IR total" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.active_scan_mode = .rgb_ir;
    state.active_scan_dpi = 3200;
    state.applyScannerBackendEvent(.{ .scan_start = .{
        .device = "epkowa:interpreter:001:017",
        .output = "scans/scan_0001_rgbir_3200dpi.tiff.rgb.tmp.tiff",
        .source = .tpu,
        .kind = .rgb,
        .requested_dpi = 3200,
        .effective_dpi = 3200,
    } });
    state.updateScanProgressStatus(1_000);
    try std.testing.expectEqual(@as(?f64, null), state.scan_eta_seconds);

    state.applyScannerBackendEvent(.{ .progress = .{ .percent = 25 } });
    state.updateScanProgressStatus(21_000);
    try std.testing.expectEqualStrings("RGB 25%, total 18%, ETA 2m00s, elapsed 20s", state.scanStatusDisplay());
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), state.scan_eta_seconds.?, 0.001);

    state.applyScannerBackendEvent(.{ .scan_start = .{
        .device = "epkowa:interpreter:001:017",
        .output = "scans/scan_0001_rgbir_3200dpi.tiff.ir.tmp.tiff",
        .source = .tpu,
        .kind = .ir,
        .requested_dpi = 3200,
        .effective_dpi = 3200,
    } });
    state.updateScanProgressStatus(61_000);
    try std.testing.expectEqualStrings("Pass 2/2: Scanning IR at 3200 DPI...", state.scanStatusDisplay());
    state.applyScannerBackendEvent(.{ .progress = .{ .percent = 50 } });
    state.updateScanProgressStatus(71_000);
    try std.testing.expectEqualStrings("IR 50%, total 87%, ETA 10s, elapsed 1m10s", state.scanStatusDisplay());
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), state.scan_eta_seconds.?, 0.001);

    state.applyScannerBackendEvent(.{ .scan_complete = .{
        .output = "scans/scan_0001_rgbir_3200dpi.tiff",
        .metadata = "scans/scan_0001_rgbir_3200dpi.tiff.json",
    } });
    state.updateScanProgressStatus(72_000);
    try std.testing.expectEqual(@as(?f64, null), state.scan_eta_seconds);
    try std.testing.expect(state.takeScanFinished());
    try std.testing.expect(!state.takeScanFinished());
}

test "native UI preview auto-select applies the film-area detector result" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.scanner.preview_dpi = 10;
    var preview = [_]u8{200} ** (10 * 6 * 3);
    var y: usize = 1;
    while (y <= 4) : (y += 1) {
        var x: usize = 2;
        while (x <= 6) : (x += 1) {
            const offset = (y * 10 + x) * 3;
            preview[offset] = 20;
            preview[offset + 1] = 20;
            preview[offset + 2] = 20;
        }
    }

    state.finishPreviewScan(.{
        .tpu_width_in = 1.0,
        .tpu_height_in = 0.6,
    }, .{
        .output_path = "/tmp/cerealgrain-native-preview.tiff",
        .width = 10,
        .height = 6,
        .samples_per_pixel = 3,
        .bits_per_sample = 8,
        .data_len = preview.len,
    });
    try std.testing.expect(state.scan_controls.selection == null);
    try std.testing.expect(!state.scanRestoreAutoAvailable());

    try state.applyPreviewAutoSelect(std.testing.allocator, &preview, 10, 6, 3);
    const selection = state.scan_controls.selection.?;
    try std.testing.expect(state.scanRestoreAutoAvailable());
    // The dark block spans 0.2-0.6 in across and 0.1-0.4 in down at 10 dpi,
    // plus the default 2 mm clear margin on every side.
    const margin = 2.0 / 25.4;
    try std.testing.expectApproxEqAbs((0.2 - margin) * 10.0, selection.x, 0.000001);
    try std.testing.expectApproxEqAbs((0.1 - margin) * 10.0, selection.y, 0.000001);
    try std.testing.expectApproxEqAbs((0.4 + 2.0 * margin) * 10.0, selection.w, 0.000001);
    try std.testing.expectApproxEqAbs((0.3 + 2.0 * margin) * 10.0, selection.h, 0.000001);
    try std.testing.expectEqualStrings("Film area detected. Adjust selection if needed.", state.scanner.scan_status);

    state.beginPreviewRequest();
    try std.testing.expect(!state.scanRestoreAutoAvailable());
}

test "native UI preview auto-select failure leaves manual selection empty" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    const preview = [_]u8{200} ** (10 * 10 * 3);
    state.finishPreviewScan(.{
        .tpu_width_in = 1.0,
        .tpu_height_in = 1.0,
    }, .{
        .output_path = "/tmp/cerealgrain-native-preview.tiff",
        .width = 10,
        .height = 10,
        .samples_per_pixel = 3,
        .bits_per_sample = 8,
        .data_len = preview.len,
    });
    try state.applyPreviewAutoSelect(std.testing.allocator, &preview, 10, 10, 3);
    try std.testing.expect(state.scan_controls.selection == null);
    try std.testing.expect(state.scan_controls.auto_selection == null);
    try std.testing.expectEqualStrings("No film detected. Draw a rectangle manually.", state.scanner.scan_status);
}

test "native UI preview without auto-select restores pending saved selection" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.scan_controls.autoselect = false;
    state.pending_config_selection = .{ .x = 1.0, .y = 0.5, .w = 2.0, .h = 1.0 };

    state.finishPreviewScan(.{
        .tpu_width_in = 10.0,
        .tpu_height_in = 5.0,
    }, .{
        .output_path = "/tmp/cerealgrain-native-preview.tiff",
        .width = 1000,
        .height = 500,
        .samples_per_pixel = 3,
        .bits_per_sample = 8,
        .data_len = 1000 * 500 * 3,
    });
    const selection = state.scan_controls.selection.?;
    try std.testing.expectApproxEqAbs(100.0, selection.x, 0.0);
    try std.testing.expectApproxEqAbs(50.0, selection.y, 0.0);
    try std.testing.expectApproxEqAbs(200.0, selection.w, 0.0);
    try std.testing.expectApproxEqAbs(100.0, selection.h, 0.0);
    try std.testing.expectEqualStrings("Preview ready. Draw a rectangle to select scan area.", state.scanner.scan_status);
}

test "native UI scanner cancellation and errors follow backend events headlessly" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.beginPreviewRequest();
    state.applyScannerBackendEvent(.{ .scan_cancelled = .{
        .kind = .cancelled,
        .detail = "cancel file observed",
    } });
    var status = state.scannerStatus();
    try std.testing.expect(!status.scanning);
    try std.testing.expect(!state.preview_requested);
    try std.testing.expectEqualStrings("cancel file observed", status.status);

    state.beginScan("Scanning...");
    state.applyScannerBackendEvent(.{ .scan_error = .{
        .kind = .scanimage_failed,
        .detail = "scanimage failed",
    } });
    status = state.scannerStatus();
    try std.testing.expect(!status.scanning);
    try std.testing.expectEqualStrings("scanimage failed", status.status);
}

test "native UI queues preview scan command without running scanner hardware" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.scannerConnected(0, 0, 2.7, 9.54);
    try std.testing.expect(state.queuePreviewScan("/tmp/cerealgrain-native-preview.tiff"));
    try std.testing.expect(state.preview_requested);
    try std.testing.expect(state.scanner.scanning);

    const command = state.takeCommand().?;
    try std.testing.expect(state.pending_command == null);
    switch (command) {
        .preview_scan => |plan| {
            try std.testing.expectEqual(@as(u32, 200), plan.request.dpi);
            try std.testing.expectEqualStrings("/tmp/cerealgrain-native-preview.tiff", plan.output_path);
            try std.testing.expectApproxEqAbs(2.7, plan.request.area.width.?, 0.0);
            try std.testing.expectApproxEqAbs(9.54, plan.request.area.height.?, 0.0);
        },
        .scan_start => unreachable,
    }

    var missing = State.init("scans", "frames", 0);
    defer missing.deinit(std.testing.allocator);
    missing.scanner.connection = .connected;
    try std.testing.expect(!missing.queuePreviewScan("/tmp/cerealgrain-native-preview.tiff"));
    try std.testing.expect(missing.pending_command == null);
    try std.testing.expect(!missing.preview_requested);
}

test "native UI preview request preserves offline and connecting route behavior" {
    var disconnected = State.init("scans", "frames", 0);
    defer disconnected.deinit(std.testing.allocator);
    try std.testing.expect(!disconnected.queuePreviewScan("/tmp/cerealgrain-native-preview.tiff"));
    try std.testing.expectEqualStrings("No scanner connected", disconnected.scanner.scan_status);

    var connecting = State.init("scans", "frames", 0);
    defer connecting.deinit(std.testing.allocator);
    connecting.beginScannerConnect();
    try std.testing.expect(!connecting.queuePreviewScan("/tmp/cerealgrain-native-preview.tiff"));
    try std.testing.expectEqualStrings("Scanner connecting, please wait...", connecting.scanner.scan_status);

    var failed = State.init("scans", "frames", 0);
    defer failed.deinit(std.testing.allocator);
    failed.scannerFailed("backend unavailable");
    try std.testing.expect(!failed.queuePreviewScan("/tmp/cerealgrain-native-preview.tiff"));
    try std.testing.expectEqualStrings("backend unavailable", failed.scanner.scan_status);
}

test "native UI queues scan-start command with browser scan request contract" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.scannerConnected(1000, 500, 10.0, 5.0);
    state.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(state.queueScanStart(".zig-cache/cerealgrain-scan.cancel"));
    try std.testing.expect(state.scanner.scanning);
    try std.testing.expectEqualStrings("Pass 1/2: Scanning RGB at 3200 DPI...", state.scanner.scan_status);

    const command = state.takeCommand().?;
    switch (command) {
        .preview_scan => unreachable,
        .scan_start => |plan| {
            try std.testing.expectEqual(@as(u32, 3200), plan.request.dpi);
            try std.testing.expectEqual(scanner_contracts.Source.tpu, plan.request.source);
            try std.testing.expectEqual(scanner_contracts.ScanKind.rgb_ir, plan.request.kind);
            try std.testing.expectEqual(scanner_contracts.BitDepth.sixteen, plan.request.depth);
            try std.testing.expectApproxEqAbs(7.0, plan.request.area.x, 0.0);
            try std.testing.expectApproxEqAbs(0.5, plan.request.area.y, 0.0);
            try std.testing.expectApproxEqAbs(2.0, plan.request.area.width.?, 0.0);
            try std.testing.expectApproxEqAbs(1.0, plan.request.area.height.?, 0.0);
            try std.testing.expectEqualStrings("scans/scan_0001_rgbir_3200dpi.tiff", plan.output_path);
            try std.testing.expectEqualStrings(plan.output_path, plan.request.output_path.?);
            try std.testing.expectEqualStrings(".zig-cache/cerealgrain-scan.cancel", plan.cancel_file_path.?);
        },
    }

    var ir_state = State.init("scans", "frames", 0);
    defer ir_state.deinit(std.testing.allocator);
    ir_state.scannerConnected(1000, 500, 10.0, 5.0);
    ir_state.scan_controls.setMode(.ir);
    ir_state.scan_controls.setDpi(1600);
    ir_state.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    ir_state.scanner.scan_counter = 12;
    try std.testing.expect(ir_state.queueScanStart(null));
    const ir_command = ir_state.takeCommand().?;
    switch (ir_command) {
        .preview_scan => unreachable,
        .scan_start => |plan| {
            try std.testing.expectEqual(scanner_contracts.ScanKind.ir, plan.request.kind);
            try std.testing.expectEqual(scanner_contracts.BitDepth.eight, plan.request.depth);
            try std.testing.expectEqualStrings("scans/scan_0012_ir_1600dpi.tiff", plan.output_path);
            try std.testing.expect(plan.cancel_file_path == null);
        },
    }
}

test "native UI queues scan-start command to explicit output path" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.scannerConnected(1000, 500, 10.0, 5.0);
    state.scan_controls.setMode(.rgb);
    state.scan_controls.setDpi(800);
    state.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(state.queueScanStartPath("/tmp/cerealgrain-native-scan-worker-smoke.tiff", ".zig-cache/cerealgrain-native-scan.cancel"));

    const command = state.takeCommand().?;
    switch (command) {
        .preview_scan => unreachable,
        .scan_start => |plan| {
            try std.testing.expectEqual(scanner_contracts.ScanKind.rgb, plan.request.kind);
            try std.testing.expectEqual(@as(u32, 800), plan.request.dpi);
            try std.testing.expectEqualStrings("/tmp/cerealgrain-native-scan-worker-smoke.tiff", plan.output_path);
            try std.testing.expectEqualStrings("/tmp/cerealgrain-native-scan-worker-smoke.tiff", plan.request.output_path.?);
            try std.testing.expectEqualStrings(".zig-cache/cerealgrain-native-scan.cancel", plan.cancel_file_path.?);
        },
    }
}

test "native UI scan status strings follow handle_scan pass transitions" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.scannerConnected(1000, 500, 10.0, 5.0);
    state.scan_controls.setDpi(1600);
    state.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });
    try std.testing.expect(state.queueScanStart(null));
    try std.testing.expectEqualStrings("Pass 1/2: Scanning RGB at 1600 DPI...", state.scanner.scan_status);

    state.applyScannerBackendEvent(.{ .scan_start = .{
        .device = "epkowa:interpreter:001:017",
        .output = "scans/scan_0001_rgbir_1600dpi.tiff.rgb.tmp.tiff",
        .source = .tpu,
        .kind = .rgb,
        .requested_dpi = 1600,
        .effective_dpi = 1600,
    } });
    try std.testing.expectEqualStrings("Pass 1/2: Scanning RGB at 1600 DPI...", state.scanner.scan_status);

    state.applyScannerBackendEvent(.{ .scan_start = .{
        .device = "epkowa:interpreter:001:017",
        .output = "scans/scan_0001_rgbir_1600dpi.tiff.ir.tmp.tiff",
        .source = .tpu,
        .kind = .ir,
        .requested_dpi = 1600,
        .effective_dpi = 1600,
    } });
    try std.testing.expectEqualStrings("Pass 2/2: Scanning IR at 1600 DPI...", state.scanner.scan_status);

    state.applyScannerBackendEvent(.{ .scan_complete = .{
        .output = "scans/scan_0001_rgbir_1600dpi.tiff",
        .metadata = "scans/scan_0001_rgbir_1600dpi.tiff.json",
    } });
    try std.testing.expect(!state.scanner.scanning);
    try std.testing.expectEqual(@as(usize, 2), state.scanner.scan_counter);
    try std.testing.expectEqualStrings("Saved: scan_0001_rgbir_1600dpi.tiff", state.scanner.scan_status);
    try std.testing.expectEqualStrings("Saved: scan_0001_rgbir_1600dpi.tiff", state.status);
}

test "native UI scan-start request preserves offline connecting and no-selection behavior" {
    var disconnected = State.init("scans", "frames", 0);
    defer disconnected.deinit(std.testing.allocator);
    try std.testing.expect(!disconnected.queueScanStart(null));
    try std.testing.expectEqualStrings("No scanner connected", disconnected.scanner.scan_status);

    var connecting = State.init("scans", "frames", 0);
    defer connecting.deinit(std.testing.allocator);
    connecting.beginScannerConnect();
    try std.testing.expect(!connecting.queueScanStart(null));
    try std.testing.expectEqualStrings("Scanner connecting, please wait...", connecting.scanner.scan_status);

    var failed = State.init("scans", "frames", 0);
    defer failed.deinit(std.testing.allocator);
    failed.scannerFailed("backend unavailable");
    try std.testing.expect(!failed.queueScanStart(null));
    try std.testing.expectEqualStrings("backend unavailable", failed.scanner.scan_status);

    var missing_selection = State.init("scans", "frames", 0);
    defer missing_selection.deinit(std.testing.allocator);
    missing_selection.scannerConnected(1000, 500, 10.0, 5.0);
    try std.testing.expect(!missing_selection.queueScanStart(null));
    try std.testing.expectEqualStrings("Draw a selection rectangle first.", missing_selection.scanner.scan_status);
    try std.testing.expect(missing_selection.pending_command == null);
}

test "native UI applies browser scanner config restore semantics" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    var loaded = scanner_config.LoadedConfig{};
    try loaded.values.mode.set("rgb");
    loaded.active.mode = true;
    loaded.values.dpi = 1600;
    loaded.active.dpi = true;
    loaded.values.autoselect = false;
    loaded.active.autoselect = true;
    loaded.values.sel_x_in = 1.0;
    loaded.active.sel_x_in = true;
    loaded.values.sel_y_in = 0.5;
    loaded.active.sel_y_in = true;
    loaded.values.sel_w_in = 2.0;
    loaded.active.sel_w_in = true;
    loaded.values.sel_h_in = 1.0;
    loaded.active.sel_h_in = true;

    state.applyScannerConfig(loaded);
    try std.testing.expectEqual(ScanMode.rgb, state.scan_controls.mode);
    try std.testing.expectEqual(@as(u32, 1600), state.scan_controls.dpi);
    try std.testing.expect(!state.scan_controls.autoselect);
    try std.testing.expect(state.scan_controls.selection == null);
    try std.testing.expect(state.pending_config_selection != null);

    state.scannerConnected(1000, 500, 10.0, 5.0);
    const selection = state.scan_controls.selection.?;
    try std.testing.expectApproxEqAbs(100.0, selection.x, 0.0);
    try std.testing.expectApproxEqAbs(50.0, selection.y, 0.0);
    try std.testing.expectApproxEqAbs(200.0, selection.w, 0.0);
    try std.testing.expectApproxEqAbs(100.0, selection.h, 0.0);
    try std.testing.expect(state.pending_config_selection == null);
}

test "native UI restore ignores browser config dpi unavailable for restored mode" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    var loaded = scanner_config.LoadedConfig{};
    try loaded.values.mode.set("rgb+ir");
    loaded.active.mode = true;
    loaded.values.dpi = 1200;
    loaded.active.dpi = true;

    state.applyScannerConfig(loaded);
    try std.testing.expectEqual(ScanMode.rgb_ir, state.scan_controls.mode);
    try std.testing.expectEqual(@as(u32, 3200), state.scan_controls.dpi);
}

test "native UI saves scanner config controls without requiring a selection" {
    var state = State.init("scans", "frames", 0);
    defer state.deinit(std.testing.allocator);
    state.scannerConnected(1000, 500, 10.0, 5.0);

    state.scan_controls.setMode(.rgb);
    state.scan_controls.setDpi(1600);
    state.scan_controls.autoselect = false;
    var updates = state.scannerConfigUpdates();
    try std.testing.expect(updates.active.dpi);
    try std.testing.expect(updates.active.mode);
    try std.testing.expect(updates.active.autoselect);
    try std.testing.expect(!updates.active.sel_x_in);
    try std.testing.expect(!updates.active.sel_y_in);
    try std.testing.expect(!updates.active.sel_w_in);
    try std.testing.expect(!updates.active.sel_h_in);
    try std.testing.expectEqual(@as(u32, 1600), updates.values.dpi);
    try std.testing.expectEqualStrings("rgb", updates.values.mode.slice());
    try std.testing.expect(!updates.values.autoselect);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scan_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer std.testing.allocator.free(scan_dir);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try scannerConfigPath(&path_buffer, scan_dir);
    try std.testing.expect(try state.saveScannerConfig(std.testing.allocator, std.testing.io, path));
    var saved = try scanner_config.loadFile(std.testing.allocator, std.testing.io, path);
    try std.testing.expect(saved.active.dpi);
    try std.testing.expect(saved.active.mode);
    try std.testing.expect(saved.active.autoselect);
    try std.testing.expect(!saved.active.sel_x_in);
    try std.testing.expect(!saved.active.sel_y_in);
    try std.testing.expect(!saved.active.sel_w_in);
    try std.testing.expect(!saved.active.sel_h_in);
    try std.testing.expectEqual(@as(u32, 1600), saved.values.dpi);
    try std.testing.expectEqualStrings("rgb", saved.values.mode.slice());
    try std.testing.expect(!saved.values.autoselect);

    state.scan_controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });

    updates = state.scannerConfigUpdates();
    try std.testing.expect(updates.active.dpi);
    try std.testing.expect(updates.active.mode);
    try std.testing.expect(updates.active.autoselect);
    try std.testing.expect(updates.active.sel_x_in);
    try std.testing.expectEqual(@as(u32, 1600), updates.values.dpi);
    try std.testing.expectEqualStrings("rgb", updates.values.mode.slice());
    try std.testing.expect(!updates.values.autoselect);
    try std.testing.expectApproxEqAbs(1.0, updates.values.sel_x_in, 0.0);
    try std.testing.expectApproxEqAbs(0.5, updates.values.sel_y_in, 0.0);
    try std.testing.expectApproxEqAbs(2.0, updates.values.sel_w_in, 0.0);
    try std.testing.expectApproxEqAbs(1.0, updates.values.sel_h_in, 0.0);

    try std.testing.expect(try state.saveScannerConfig(std.testing.allocator, std.testing.io, path));
    saved = try scanner_config.loadFile(std.testing.allocator, std.testing.io, path);
    try std.testing.expect(saved.active.dpi);
    try std.testing.expect(saved.active.sel_h_in);
    try std.testing.expectEqual(@as(u32, 1600), saved.values.dpi);
    try std.testing.expectEqualStrings("rgb", saved.values.mode.slice());
    try std.testing.expectApproxEqAbs(2.0, saved.values.sel_w_in, 0.0);

    state.scan_controls.selection = null;
    state.scan_controls.setMode(.ir);
    try std.testing.expect(try state.saveScannerConfig(std.testing.allocator, std.testing.io, path));
    saved = try scanner_config.loadFile(std.testing.allocator, std.testing.io, path);
    try std.testing.expectEqualStrings("ir", saved.values.mode.slice());
    try std.testing.expect(saved.active.sel_x_in);
    try std.testing.expect(saved.active.sel_y_in);
    try std.testing.expect(saved.active.sel_w_in);
    try std.testing.expect(saved.active.sel_h_in);
    try std.testing.expectApproxEqAbs(1.0, saved.values.sel_x_in, 0.0);
    try std.testing.expectApproxEqAbs(0.5, saved.values.sel_y_in, 0.0);
    try std.testing.expectApproxEqAbs(2.0, saved.values.sel_w_in, 0.0);
    try std.testing.expectApproxEqAbs(1.0, saved.values.sel_h_in, 0.0);
}

test "settled hand edits can be undone and untouched auto-detect frames are not edits" {
    var state = State.init("scans", "frames", 0);
    state.processing.preview_scale = 0.5;
    // Auto-detect sets two frames.
    const before_auto = state.processSelectionsSnapshot();
    state.process_selections[0] = .{ .x = 10, .y = 20, .w = 100, .h = 150, .rotation = 270 };
    state.process_selections[1] = .{ .x = 10, .y = 200, .w = 100, .h = 150, .rotation = 270 };
    state.process_selection_count = 2;
    state.finishProcessAutoDetect(before_auto);
    state.settleProcessEdits(0);
    state.settleProcessEdits(10_000);
    try std.testing.expect(!state.process_framing_dirty);
    try std.testing.expect(!state.canUndoProcessSelections());

    // A drag settles after a pause.
    state.process_selections[0].x = 4;
    state.settleProcessEdits(10_000);
    state.settleProcessEdits(10_000 + process_edit_settle_ms - 1);
    try std.testing.expect(!state.process_framing_dirty);
    state.settleProcessEdits(10_000 + process_edit_settle_ms);
    try std.testing.expect(state.process_framing_dirty);
    try std.testing.expect(state.canUndoProcessSelections());

    try std.testing.expect(state.undoProcessSelections());
    try std.testing.expectEqual(@as(f64, 10), state.process_selections[0].x);
    try std.testing.expect(state.process_framing_dirty);
    try std.testing.expect(!state.canUndoProcessSelections());
}

test "auto-detect over hand frames can be undone, and saved frames replace only the first detect" {
    var state = State.init("scans", "frames", 0);
    state.processing.preview_scale = 0.5;
    var framing = ProcessFraming{ .count = 1 };
    framing.frames[0] = .{ .cx = 200, .cy = 300, .w = 100, .h = 200, .angle = 0, .rotation = 270 };
    framing.rebate = .{ .x = 0, .y = 500, .w = 100, .h = 20 };
    state.setProcessSavedFraming(framing);

    // The strip loads and auto-detects; its saved frames win.
    var before = state.processSelectionsSnapshot();
    state.process_selections[0] = .{ .x = 1, .y = 1, .w = 5, .h = 5 };
    state.process_selection_count = 1;
    state.finishProcessAutoDetect(before);
    try std.testing.expectEqual(@as(usize, 1), state.process_selection_count);
    try std.testing.expectEqual(@as(f64, 75), state.process_selections[0].x);
    try std.testing.expectEqual(@as(f64, 100), state.process_selections[0].y);
    try std.testing.expectEqual(@as(f64, 50), state.process_selections[0].w);
    try std.testing.expectEqual(@as(i32, 270), state.process_selections[0].rotation);
    try std.testing.expectEqual(@as(f64, 500), state.processing.rebate_rect.?.y);
    try std.testing.expect(state.takeProcessRebateDminPending());
    try std.testing.expect(!state.process_framing_dirty);
    try std.testing.expect(!state.canUndoProcessSelections());

    // Pressing auto-detect again replaces them, with Undo back to the saved frames.
    before = state.processSelectionsSnapshot();
    state.process_selections[0] = .{ .x = 3, .y = 3, .w = 9, .h = 9 };
    state.finishProcessAutoDetect(before);
    try std.testing.expectEqual(@as(f64, 3), state.process_selections[0].x);
    try std.testing.expect(std.mem.startsWith(u8, state.status, "Detected frames are not saved yet"));
    try std.testing.expect(state.undoProcessSelections());
    try std.testing.expectEqual(@as(f64, 75), state.process_selections[0].x);
}
