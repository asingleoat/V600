const std = @import("std");

const processing_workflow = @import("processing/workflow.zig");

pub const ScannerConnection = enum {
    disconnected,
    connecting,
    connected,
    error_state,
};

pub const ScannerStatus = struct {
    status: []const u8,
    scanning: bool,
    connecting: bool,
    connected: bool,
    error_message: ?[]const u8,
};

pub const ScannerInfo = struct {
    preview_width: usize,
    preview_height: usize,
    tpu_width_in: f64,
    tpu_height_in: f64,
    scan_counter: usize,
};

pub const ScannerState = struct {
    connection: ScannerConnection = .disconnected,
    scanner_error: ?[]const u8 = null,
    preview_width: usize = 0,
    preview_height: usize = 0,
    preview_scale: f64 = 1.0,
    preview_dpi: u32 = 200,
    tpu_width_in: f64 = 0.0,
    tpu_height_in: f64 = 0.0,
    scan_counter: usize = 1,
    output_dir: []const u8 = ".",
    scanning: bool = false,
    scan_status: []const u8 = "",
    cancel_requested: bool = false,

    pub fn status(self: ScannerState) ScannerStatus {
        return .{
            .status = self.scan_status,
            .scanning = self.scanning,
            .connecting = self.connection == .connecting,
            .connected = self.connection == .connected,
            .error_message = self.scanner_error,
        };
    }

    pub fn info(self: ScannerState) ScannerInfo {
        return .{
            .preview_width = self.preview_width,
            .preview_height = self.preview_height,
            .tpu_width_in = self.tpu_width_in,
            .tpu_height_in = self.tpu_height_in,
            .scan_counter = self.scan_counter,
        };
    }

    pub fn requestCancel(self: *ScannerState) void {
        self.cancel_requested = true;
    }
};

pub const RebateRect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    angle: f64 = 0.0,
};

pub const ProcessingInfo = struct {
    full_width: usize,
    full_height: usize,
    preview_scale: f64,
    filename: []const u8,
    image_idx: usize,
    image_count: usize,
    loading: bool,
    has_dmin: bool,
    dpi: ?u32,
    dpi_scale: f64,
};

pub const ProcessingState = struct {
    input_path: []const u8 = "",
    input_dir: []const u8 = ".",
    output_dir: []const u8 = ".",
    full_image_ready: bool = false,
    dmin: ?[3]f64 = null,
    preview_scale: f64 = 1.0,
    full_width: usize = 0,
    full_height: usize = 0,
    image_count: usize = 0,
    image_idx: usize = 0,
    ir_clean: bool = true,
    loading: bool = false,
    has_ir: bool = false,
    is_grayscale: bool = false,
    progress: []const u8 = "",
    rebate_rect: ?RebateRect = null,
    current_dpi: ?u32 = null,

    pub fn init(scan_dir: []const u8, output_dir: []const u8, image_count: usize) ProcessingState {
        return .{
            .input_dir = scan_dir,
            .output_dir = output_dir,
            .image_count = image_count,
        };
    }

    pub fn beginImageLoad(self: *ProcessingState, path: []const u8, index: usize) void {
        self.loading = true;
        self.full_image_ready = false;
        self.input_path = path;
        self.image_idx = index;
        self.full_width = 0;
        self.full_height = 0;
        self.has_ir = false;
        self.is_grayscale = false;
        self.current_dpi = null;
    }

    pub fn finishImageLoad(
        self: *ProcessingState,
        width: usize,
        height: usize,
        has_ir: bool,
        is_grayscale: bool,
        dpi: ?u32,
        preview_scale: f64,
    ) void {
        self.full_width = width;
        self.full_height = height;
        self.has_ir = has_ir;
        self.is_grayscale = is_grayscale;
        self.current_dpi = dpi;
        self.preview_scale = preview_scale;
        self.full_image_ready = false;
        self.loading = false;
    }

    pub fn setProgress(self: *ProcessingState, message: []const u8) void {
        self.progress = message;
    }

    pub fn info(self: ProcessingState) ProcessingInfo {
        return .{
            .full_width = self.full_width,
            .full_height = self.full_height,
            .preview_scale = self.preview_scale,
            .filename = if (self.input_path.len == 0) "" else std.fs.path.basename(self.input_path),
            .image_idx = self.image_idx,
            .image_count = self.image_count,
            .loading = self.loading,
            .has_dmin = self.dmin != null,
            .dpi = self.current_dpi,
            .dpi_scale = processing_workflow.dpiScale(self.current_dpi),
        };
    }
};

test "scanner state defaults and status mirror Python ScannerState" {
    var state = ScannerState{};
    try std.testing.expectEqual(@as(usize, 1), state.scan_counter);
    try std.testing.expectEqual(@as(u32, 200), state.preview_dpi);
    try std.testing.expectEqualStrings(".", state.output_dir);
    var status = state.status();
    try std.testing.expect(!status.connected);
    try std.testing.expect(!status.connecting);
    try std.testing.expect(!status.scanning);
    try std.testing.expectEqualStrings("", status.status);

    state.connection = .connecting;
    status = state.status();
    try std.testing.expect(status.connecting);
    try std.testing.expect(!status.connected);

    state.connection = .connected;
    state.scanning = true;
    state.scan_status = "Scanning...";
    state.preview_width = 640;
    state.preview_height = 480;
    status = state.status();
    try std.testing.expect(status.connected);
    try std.testing.expect(status.scanning);
    try std.testing.expectEqualStrings("Scanning...", status.status);
    const info = state.info();
    try std.testing.expectEqual(@as(usize, 640), info.preview_width);
    try std.testing.expectEqual(@as(usize, 480), info.preview_height);

    state.requestCancel();
    try std.testing.expect(state.cancel_requested);
}

test "processing state defaults mirror Python module globals" {
    const state = ProcessingState{};
    try std.testing.expectEqualStrings("", state.input_path);
    try std.testing.expectEqualStrings(".", state.input_dir);
    try std.testing.expectEqualStrings(".", state.output_dir);
    try std.testing.expect(!state.full_image_ready);
    try std.testing.expect(state.ir_clean);
    try std.testing.expect(!state.loading);
    try std.testing.expect(!state.has_ir);
    try std.testing.expect(!state.is_grayscale);
    try std.testing.expect(state.dmin == null);
    try std.testing.expect(state.rebate_rect == null);
    try std.testing.expect(state.current_dpi == null);
    try std.testing.expectApproxEqAbs(1.0, state.preview_scale, 0.0);
}

test "processing image load transitions preserve process_handlers info contract" {
    var state = ProcessingState.init("scans", "frames", 4);
    state.beginImageLoad("scans/scan_0006_rgbir_800dpi.tiff", 2);
    var info = state.info();
    try std.testing.expect(info.loading);
    try std.testing.expect(!state.full_image_ready);
    try std.testing.expectEqualStrings("scan_0006_rgbir_800dpi.tiff", info.filename);
    try std.testing.expectEqual(@as(usize, 2), info.image_idx);
    try std.testing.expectEqual(@as(usize, 4), info.image_count);
    try std.testing.expectEqual(@as(?u32, null), info.dpi);
    try std.testing.expectApproxEqAbs(1.0, info.dpi_scale, 0.0);

    state.finishImageLoad(1272, 6031, true, false, 800, 0.5);
    state.dmin = .{ 0.1, 0.2, 0.3 };
    state.setProgress("Loaded 1272x6031 image");
    info = state.info();
    try std.testing.expect(!info.loading);
    try std.testing.expect(!state.full_image_ready);
    try std.testing.expect(info.has_dmin);
    try std.testing.expect(state.has_ir);
    try std.testing.expect(!state.is_grayscale);
    try std.testing.expectEqual(@as(usize, 1272), info.full_width);
    try std.testing.expectEqual(@as(usize, 6031), info.full_height);
    try std.testing.expectEqual(@as(?u32, 800), info.dpi);
    try std.testing.expectApproxEqAbs(1.0, info.dpi_scale, 0.0);
    try std.testing.expectApproxEqAbs(0.5, info.preview_scale, 0.0);
    try std.testing.expectEqualStrings("Loaded 1272x6031 image", state.progress);
}
