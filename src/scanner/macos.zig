const std = @import("std");
const builtin = @import("builtin");

const contracts = @import("contracts.zig");
const interpreter = @import("interpreter.zig");

pub const callback_timeout_ms: u32 = 10_000;
pub const direct_timeout_ms: u32 = 5_000;
pub const callback_success: i8 = 1;
pub const callback_failure: i8 = 0;
pub const callback_error: i16 = -1;
pub const callback_ok: i16 = 0;
pub const ica_driver_url = "https://ftp.epson.com/drivers/ESICA_5.8.23.dmg";
pub const epson_vendor_id: u16 = 0x04b8;

pub const InterpreterHost = enum {
    linux,
    macos,
    other,
};

pub const InterpreterRequirementStatus = enum {
    ready,
    missing_manual_install_required,
    unsupported_linux,
};

pub const InterpreterRequirement = struct {
    status: InterpreterRequirementStatus,
    path: ?[]u8 = null,
    interp_id: []const u8,
    driver_url: []const u8 = ica_driver_url,

    pub fn deinit(self: *InterpreterRequirement, allocator: std.mem.Allocator) void {
        if (self.path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const ScanDataStatus = enum {
    complete,
    read_failed,
    fatal_error,
    cancel_request,
};

pub const ScanDataReadResult = struct {
    data: []u8,
    status: ScanDataStatus,
    blocks_read: u32,
    status_byte: ?u8,

    pub fn deinit(self: *ScanDataReadResult, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

pub const valid_resolutions = [_]u32{
    75,  100, 150, 200,  240,  266,  300,  320,  350,  360,  400,   480,
    600, 720, 800, 1200, 1600, 2400, 3200, 4800, 6400, 9600, 12800,
};

pub const valid_ir_resolutions = [_]u32{ 800, 1600, 3200 };

pub const UsbEndpointPair = struct {
    out_address: u8,
    in_address: u8,
};

pub const ScanPlan = struct {
    effective_dpi: u32,
    original_dpi: u32,
    x_pixels: u32,
    y_pixels: u32,
    out_width: u32,
    out_height: u32,
    color_mode: u8,
    source_code: u8,
    channels: u8,
    bytes_per_pixel: u8,
    expected_size: u64,
    params: interpreter.SetParameters,
};

pub const UsbTransferError = error{
    InvalidCallbackContext,
    InvalidCallbackBuffer,
    UsbReadFailed,
    UsbWriteFailed,
    UnexpectedAck,
};

pub fn selectEndpointPair(endpoint_addresses: []const u8) ?UsbEndpointPair {
    var ep_out: ?u8 = null;
    var ep_in: ?u8 = null;
    for (endpoint_addresses) |address| {
        if ((address & 0x80) != 0) {
            if (ep_in == null) ep_in = address;
        } else {
            if (ep_out == null) ep_out = address;
        }
        if (ep_out != null and ep_in != null) break;
    }
    return .{ .out_address = ep_out orelse return null, .in_address = ep_in orelse return null };
}

pub const UsbIo = struct {
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, buffer: []u8, timeout_ms: u32) UsbTransferError!usize,
    writeFn: *const fn (context: *anyopaque, data: []const u8, timeout_ms: u32) UsbTransferError!void,

    pub fn read(self: UsbIo, buffer: []u8, timeout_ms: u32) UsbTransferError!usize {
        return self.readFn(self.context, buffer, timeout_ms);
    }

    pub fn write(self: UsbIo, data: []const u8, timeout_ms: u32) UsbTransferError!void {
        return self.writeFn(self.context, data, timeout_ms);
    }
};

pub const CallbackContext = struct {
    usb: UsbIo,
};

pub const UsbCallback = *const fn (
    buffer: ?[*]u8,
    length: u32,
    handle: ?*anyopaque,
    err: ?*i16,
) callconv(.c) i8;

pub const InterpreterApi = struct {
    context: *anyopaque,
    initFn: *const fn (context: *anyopaque, read_cb: UsbCallback, write_cb: UsbCallback, usb_handle: ?*anyopaque) bool,
    writeFn: *const fn (context: *anyopaque, data: []const u8) bool,
    readFn: *const fn (context: *anyopaque, buffer: []u8) bool,
    closeFn: *const fn (context: *anyopaque) void,
    usbErrorFn: *const fn (context: *anyopaque) i16,
    interpreterErrorFn: *const fn (context: *anyopaque) i32,
};

const CIntInit = *const fn (read_cb: UsbCallback, write_cb: UsbCallback, usb_handle: ?*anyopaque) callconv(.c) u8;
const CIntWrite = *const fn (data: [*]const u8, len: u32) callconv(.c) u8;
const CIntRead = *const fn (data: [*]u8, len: u32) callconv(.c) u8;
const CIntClose = *const fn () callconv(.c) void;
const CIntGetUsbError = *const fn () callconv(.c) i16;
const CIntGetInterpreterError = *const fn () callconv(.c) i32;

pub const InterpreterSymbols = struct {
    init: CIntInit,
    write: CIntWrite,
    read: CIntRead,
    close: CIntClose,
    usb_error: CIntGetUsbError,
    interpreter_error: CIntGetInterpreterError,

    pub fn api(self: *InterpreterSymbols) InterpreterApi {
        return .{
            .context = self,
            .initFn = symbolInit,
            .writeFn = symbolWrite,
            .readFn = symbolRead,
            .closeFn = symbolClose,
            .usbErrorFn = symbolUsbError,
            .interpreterErrorFn = symbolInterpreterError,
        };
    }
};

pub const LoadedInterpreter = struct {
    lib: std.DynLib,
    symbols: InterpreterSymbols,

    pub fn open(path: []const u8) !LoadedInterpreter {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();
        const symbols = loadInterpreterSymbols(&lib) orelse return error.MissingInterpreterSymbol;
        return .{ .lib = lib, .symbols = symbols };
    }

    pub fn api(self: *LoadedInterpreter) InterpreterApi {
        return self.symbols.api();
    }

    pub fn close(self: *LoadedInterpreter) void {
        self.lib.close();
        self.* = undefined;
    }
};

/// ESC/I sent straight to the scanner, for models whose firmware speaks it
/// and that have no Epson interpreter: writes go to bulk OUT, and each read
/// collects exactly the bytes asked for from bulk IN, as `INTRead` does.
pub const DirectEscI = struct {
    usb: UsbIo,

    pub fn api(self: *DirectEscI) InterpreterApi {
        return .{
            .context = self,
            .initFn = directInit,
            .writeFn = directWrite,
            .readFn = directRead,
            .closeFn = directClose,
            .usbErrorFn = directUsbError,
            .interpreterErrorFn = directInterpreterError,
        };
    }
};

/// Long enough for the first block of a high-resolution pass, which the
/// scanner takes a while to deliver.
const direct_esci_timeout_ms: u32 = 60_000;

fn directInit(_: *anyopaque, _: UsbCallback, _: UsbCallback, _: ?*anyopaque) bool {
    return true;
}

fn directWrite(context: *anyopaque, data: []const u8) bool {
    const self: *DirectEscI = @ptrCast(@alignCast(context));
    self.usb.write(data, direct_esci_timeout_ms) catch return false;
    return true;
}

fn directRead(context: *anyopaque, buffer: []u8) bool {
    const self: *DirectEscI = @ptrCast(@alignCast(context));
    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = self.usb.read(buffer[filled..], direct_esci_timeout_ms) catch return false;
        if (n == 0) return false;
        filled += n;
    }
    return true;
}

fn directClose(_: *anyopaque) void {}

fn directUsbError(_: *anyopaque) i16 {
    return 0;
}

fn directInterpreterError(_: *anyopaque) i32 {
    return 0;
}

/// Callback context used instead of the callback handle while a detached
/// session is open. The Python driver passed a NULL handle to INTInit and
/// never relied on the interpreter handing it back, so the live runtime does
/// the same.
var detached_callback_context: ?*CallbackContext = null;

pub const InterpreterSession = struct {
    api: InterpreterApi,
    callback_context: CallbackContext,
    /// Pass a NULL handle to INTInit and route callbacks through
    /// `detached_callback_context`. Only one detached session may be open.
    detached: bool = false,

    pub fn init(self: *InterpreterSession) !void {
        const handle: ?*anyopaque = if (self.detached) null else &self.callback_context;
        if (self.detached) detached_callback_context = &self.callback_context;
        if (!self.api.initFn(self.api.context, usbReadCallback, usbWriteCallback, handle)) {
            self.clearDetached();
            return error.InterpreterInitFailed;
        }
    }

    pub fn reinit(self: *InterpreterSession) !void {
        self.api.closeFn(self.api.context);
        try self.init();
    }

    pub fn close(self: *InterpreterSession) void {
        self.api.closeFn(self.api.context);
        self.clearDetached();
    }

    fn clearDetached(self: *InterpreterSession) void {
        if (detached_callback_context == &self.callback_context) detached_callback_context = null;
    }

    pub fn write(self: *InterpreterSession, data: []const u8) !void {
        if (!self.api.writeFn(self.api.context, data)) return error.InterpreterWriteFailed;
    }

    pub fn read(self: *InterpreterSession, buffer: []u8) !void {
        if (!self.api.readFn(self.api.context, buffer)) return error.InterpreterReadFailed;
    }

    pub fn usbError(self: *InterpreterSession) i16 {
        return self.api.usbErrorFn(self.api.context);
    }

    pub fn interpreterError(self: *InterpreterSession) i32 {
        return self.api.interpreterErrorFn(self.api.context);
    }
};

pub fn loadInterpreterSymbols(source: anytype) ?InterpreterSymbols {
    return .{
        .init = source.lookup(CIntInit, "INTInit") orelse return null,
        .write = source.lookup(CIntWrite, "INTWrite") orelse return null,
        .read = source.lookup(CIntRead, "INTRead") orelse return null,
        .close = source.lookup(CIntClose, "INTClose") orelse return null,
        .usb_error = source.lookup(CIntGetUsbError, "INTGetUSBError") orelse return null,
        .interpreter_error = source.lookup(CIntGetInterpreterError, "INTGetInterpreterError") orelse return null,
    };
}

pub const GammaTables = struct {
    r: ?[]const u8 = null,
    g: ?[]const u8 = null,
    b: ?[]const u8 = null,
};

pub fn interpreterSearchPaths(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    interp_id: []const u8,
) ![]const []u8 {
    return interpreterSearchPathsUnderRoot(allocator, base_dir, interp_id, "");
}

/// Like `interpreterSearchPaths`, with the system `/Library` locations moved
/// under `system_root`, so tests do not depend on what the host has installed.
fn interpreterSearchPathsUnderRoot(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    interp_id: []const u8,
    system_root: []const u8,
) ![]const []u8 {
    const name = try std.fmt.allocPrint(allocator, "Interpreter {s}", .{interp_id});
    defer allocator.free(name);
    const model_dir = try std.fmt.allocPrint(allocator, "ES00{s}", .{interp_id});
    defer allocator.free(model_dir);

    const paths = try allocator.alloc([]u8, 3);
    errdefer allocator.free(paths);
    var initialized: usize = 0;
    errdefer {
        for (paths[0..initialized]) |path| allocator.free(path);
    }

    paths[0] = try std.fs.path.join(allocator, &.{ base_dir, "firmware", name });
    initialized += 1;
    paths[1] = try std.fmt.allocPrint(
        allocator,
        "{s}/Library/Image Capture/Devices/EPSON Scanner.app/Contents/PlugIns/{s}.bundle/Contents/MacOS/{s}",
        .{ system_root, name, name },
    );
    initialized += 1;
    paths[2] = try std.fmt.allocPrint(
        allocator,
        "{s}/Library/Image Capture/Support/EPSON/Epson Scan 2/Models/{s}/{s}.bundle/Contents/MacOS/{s}",
        .{ system_root, model_dir, name, name },
    );
    initialized += 1;

    return paths;
}

pub fn freeInterpreterSearchPaths(allocator: std.mem.Allocator, paths: []const []u8) void {
    for (paths) |path| allocator.free(path);
    allocator.free(paths);
}

pub fn currentInterpreterHost() InterpreterHost {
    return switch (builtin.os.tag) {
        .linux => .linux,
        .macos => .macos,
        else => .other,
    };
}

pub fn findInterpreter(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    interp_id: []const u8,
) !?[]u8 {
    return findInterpreterForHost(allocator, io, base_dir, interp_id, currentInterpreterHost());
}

pub fn findInterpreterForHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    interp_id: []const u8,
    host: InterpreterHost,
) !?[]u8 {
    return findInterpreterUnderRoot(allocator, io, base_dir, interp_id, host, "");
}

fn findInterpreterUnderRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    interp_id: []const u8,
    host: InterpreterHost,
    system_root: []const u8,
) !?[]u8 {
    if (host == .linux) return null;

    const paths = try interpreterSearchPathsUnderRoot(allocator, base_dir, interp_id, system_root);
    defer freeInterpreterSearchPaths(allocator, paths);
    for (paths) |path| {
        if (pathExists(io, path)) return try allocator.dupe(u8, path);
    }
    return null;
}

pub fn ensureInterpreterManual(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    interp_id: []const u8,
) !InterpreterRequirement {
    return ensureInterpreterManualForHost(allocator, io, base_dir, interp_id, currentInterpreterHost());
}

pub fn ensureInterpreterManualForHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    interp_id: []const u8,
    host: InterpreterHost,
) !InterpreterRequirement {
    return ensureInterpreterManualUnderRoot(allocator, io, base_dir, interp_id, host, "");
}

fn ensureInterpreterManualUnderRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    interp_id: []const u8,
    host: InterpreterHost,
    system_root: []const u8,
) !InterpreterRequirement {
    if (host == .linux) {
        return .{
            .status = .unsupported_linux,
            .interp_id = interp_id,
        };
    }
    if (try findInterpreterUnderRoot(allocator, io, base_dir, interp_id, host, system_root)) |path| {
        return .{
            .status = .ready,
            .path = path,
            .interp_id = interp_id,
        };
    }
    return .{
        .status = .missing_manual_install_required,
        .interp_id = interp_id,
    };
}

pub fn usbReadCallback(buffer: ?[*]u8, length: u32, handle: ?*anyopaque, err: ?*i16) callconv(.c) i8 {
    const slice = callbackSlice(buffer, length) catch {
        setCallbackError(err);
        return callback_failure;
    };
    const context = callbackContext(handle) catch {
        setCallbackError(err);
        return callback_failure;
    };
    _ = context.usb.read(slice, callback_timeout_ms) catch {
        setCallbackError(err);
        return callback_failure;
    };
    setCallbackOk(err);
    return callback_success;
}

pub fn usbWriteCallback(buffer: ?[*]u8, length: u32, handle: ?*anyopaque, err: ?*i16) callconv(.c) i8 {
    const slice = callbackSlice(buffer, length) catch {
        setCallbackError(err);
        return callback_failure;
    };
    const context = callbackContext(handle) catch {
        setCallbackError(err);
        return callback_failure;
    };
    context.usb.write(slice, callback_timeout_ms) catch {
        setCallbackError(err);
        return callback_failure;
    };
    setCallbackOk(err);
    return callback_success;
}

pub fn rsCommand(usb: UsbIo, command: interpreter.RsCommand) !void {
    const prefix = interpreter.rsCommandPrefix(command.subcommand);
    try usb.write(&prefix, direct_timeout_ms);
    try expectAck(usb);
    if (command.data.len > 0) {
        try usb.write(command.data, direct_timeout_ms);
        try expectAck(usb);
    }
}

pub fn registerWrite(usb: UsbIo, write: interpreter.RegisterWrite) !void {
    const prefix = interpreter.registerWriteCommand();
    try usb.write(&prefix, direct_timeout_ms);
    try expectAck(usb);
    try usb.write(write.header, direct_timeout_ms);
    try usb.write(write.data, direct_timeout_ms);
    try expectAck(usb);
}

pub fn uploadGammaTables(usb: UsbIo, tables: GammaTables) !void {
    const identity = interpreter.identityGammaTable();
    const lut_r = tables.r orelse &identity;
    const lut_g = tables.g orelse &identity;
    const lut_b = tables.b orelse &identity;
    try registerWrite(usb, .{ .header = &interpreter.gammaRegisterHeader(0xfc), .data = lut_r });
    try registerWrite(usb, .{ .header = &interpreter.gammaRegisterHeader(0xfd), .data = lut_g });
    try registerWrite(usb, .{ .header = &interpreter.gammaRegisterHeader(0xfe), .data = lut_b });
}

pub fn runTpuCalibrationProgram(usb: UsbIo) !void {
    for (interpreter.tpu_calibration_program) |op| {
        switch (op) {
            .rs => |command| try rsCommand(usb, command),
            .register_write => |write| try registerWrite(usb, write),
        }
    }
}

pub fn configureTpu(usb: UsbIo, tables: GammaTables) !void {
    try uploadGammaTables(usb, tables);
    try runTpuCalibrationProgram(usb);
}

pub fn writeCommand(session: *InterpreterSession, data: []const u8) bool {
    session.write(data) catch return false;
    return true;
}

pub fn readResponse(session: *InterpreterSession, buffer: []u8) bool {
    session.read(buffer) catch return false;
    return true;
}

pub fn commandAck(session: *InterpreterSession, data: []const u8) bool {
    if (!writeCommand(session, data)) return false;
    var resp: [1]u8 = undefined;
    if (!readResponse(session, &resp)) return false;
    if (resp[0] == interpreter.ACK) return true;
    if (resp[0] == interpreter.NAK) return false;
    return true;
}

pub fn reset(session: *InterpreterSession) bool {
    const command = interpreter.resetCommand();
    return commandAck(session, &command);
}

pub fn getIdentity(session: *InterpreterSession, out: *[256]u8) bool {
    const command = interpreter.identityCommand();
    if (!writeCommand(session, &command)) return false;
    return readResponse(session, out);
}

pub fn getStatus(session: *InterpreterSession, out: *[16]u8) bool {
    const command = interpreter.statusCommand();
    if (!writeCommand(session, &command)) return false;
    return readResponse(session, out);
}

pub fn getExtendedStatus(session: *InterpreterSession, out: *[64]u8) bool {
    const command = interpreter.extendedStatusCommand();
    if (!writeCommand(session, &command)) return false;
    return readResponse(session, out);
}

pub fn getExtendedIdentity(session: *InterpreterSession) ?interpreter.ExtendedIdentity {
    const command = interpreter.extendedIdentityCommand();
    if (!writeCommand(session, &command)) return null;
    var resp: [80]u8 = undefined;
    if (!readResponse(session, &resp)) return null;
    return interpreter.parseExtendedIdentity(&resp) catch null;
}

pub fn capabilitiesFromExtendedIdentity(identity: *const interpreter.ExtendedIdentity) contracts.ScannerCapabilities {
    const optical_dpi_f: f64 = @floatFromInt(identity.optical_dpi);
    return .{
        .model = identity.modelName(),
        .optical_dpi = identity.optical_dpi,
        .max_resolution = identity.max_dpi,
        .flatbed_width_in = @as(f64, @floatFromInt(identity.flatbed_width)) / optical_dpi_f,
        .flatbed_height_in = @as(f64, @floatFromInt(identity.flatbed_height)) / optical_dpi_f,
        .tpu_width_in = @as(f64, @floatFromInt(identity.tpu_width)) / optical_dpi_f,
        .tpu_height_in = @as(f64, @floatFromInt(identity.tpu_height)) / optical_dpi_f,
        .ir_supported = identity.irSupported(),
    };
}

pub fn planScan(request: contracts.ScanRequest, caps: contracts.ScannerCapabilities) !ScanPlan {
    if (request.kind == .rgb_ir) return error.CombinedScanRequiresRuntime;

    const max_x_in = if (request.source == .flatbed) caps.flatbed_width_in else caps.tpu_width_in;
    const max_y_in = if (request.source == .flatbed) caps.flatbed_height_in else caps.tpu_height_in;
    const x_in = request.area.x;
    const y_in = request.area.y;
    const w_in = request.area.width orelse (max_x_in - x_in);
    const h_in = request.area.height orelse (max_y_in - y_in);

    const effective_dpi = nearestResolution(
        request.dpi,
        if (request.kind == .ir) &valid_ir_resolutions else &valid_resolutions,
    );
    const dpi_f: f64 = @floatFromInt(effective_dpi);
    const x_pixels: u32 = @intFromFloat(x_in * dpi_f);
    const y_pixels: u32 = @intFromFloat(y_in * dpi_f);
    const out_width: u32 = @intFromFloat(w_in * dpi_f);
    const out_height: u32 = @intFromFloat(h_in * dpi_f);

    const color_mode: u8 = if (request.kind == .rgb) 0x13 else 0x00;
    const source_code: u8 = if (request.kind == .ir) 3 else switch (request.source) {
        .flatbed => 0,
        .tpu => 1,
    };
    const channels: u8 = if (request.kind == .rgb) 3 else 1;
    const bytes_per_sample: u8 = if (request.depth == .sixteen) 2 else 1;
    const bytes_per_pixel = channels * bytes_per_sample;
    const expected_size = @as(u64, out_width) * @as(u64, out_height) * @as(u64, bytes_per_pixel);
    const params = interpreter.SetParameters{
        .dpi = effective_dpi,
        .x = x_pixels,
        .y = y_pixels,
        .width = out_width,
        .height = out_height,
        .color_mode = color_mode,
        .depth = @intFromEnum(request.depth),
        .source = source_code,
    };

    return .{
        .effective_dpi = effective_dpi,
        .original_dpi = request.dpi,
        .x_pixels = x_pixels,
        .y_pixels = y_pixels,
        .out_width = out_width,
        .out_height = out_height,
        .color_mode = color_mode,
        .source_code = source_code,
        .channels = channels,
        .bytes_per_pixel = bytes_per_pixel,
        .expected_size = expected_size,
        .params = params,
    };
}

pub fn setResolution(session: *InterpreterSession, dpi: u16) bool {
    const command = interpreter.setResolutionCommand(dpi);
    return writeCommand(session, &command);
}

pub fn setScanArea(session: *InterpreterSession, x: u32, y: u32, width: u32, height: u32) bool {
    const command = interpreter.setScanAreaCommand(x, y, width, height);
    return writeCommand(session, &command);
}

pub fn setColorMode(session: *InterpreterSession, mode: u8) bool {
    const command = interpreter.setColorModeCommand(mode);
    return writeCommand(session, &command);
}

pub fn setDataFormat(session: *InterpreterSession, bits: u8) bool {
    const command = interpreter.setDataFormatCommand(bits);
    return writeCommand(session, &command);
}

pub fn setSource(session: *InterpreterSession, source: u8, enable: bool) bool {
    const command = interpreter.setSourceCommand(source, enable);
    return writeCommand(session, &command);
}

pub fn startScan(session: *InterpreterSession) bool {
    const command = interpreter.startScanCommand();
    return writeCommand(session, &command);
}

pub fn setScanningParameters(session: *InterpreterSession, params: interpreter.SetParameters) bool {
    const command = interpreter.setScanningParametersCommand();
    if (!commandAck(session, &command)) return false;
    const block = interpreter.buildSetScanningParameters(params);
    return commandAck(session, &block);
}

pub fn enableInfrared(session: *InterpreterSession) bool {
    const read_params_command = interpreter.readScanParametersCommand();
    if (!writeCommand(session, &read_params_command)) return false;

    var params: [64]u8 = undefined;
    if (!readResponse(session, &params)) return false;

    const challenge = interpreter.buildInfraredChallenge(&params) catch return false;
    const enable_command = [_]u8{ interpreter.ESC, 0x23 };
    if (!commandAck(session, &enable_command)) return false;
    return commandAck(session, &challenge);
}

pub fn startExtendedScan(session: *InterpreterSession) ?interpreter.StartScanInfo {
    const command = interpreter.startExtendedScanCommand();
    session.write(&command) catch return null;

    var resp: [14]u8 = undefined;
    session.read(&resp) catch return null;
    return interpreter.parseStartScanResponse(&resp) catch null;
}

pub fn readScanData(
    allocator: std.mem.Allocator,
    session: *InterpreterSession,
    block_size: u32,
    block_count: u32,
    last_block_size: u32,
) !ScanDataReadResult {
    const total_blocks = try std.math.add(u32, block_count, if (last_block_size != 0) 1 else 0);
    var data = std.array_list.Managed(u8).init(allocator);
    errdefer data.deinit();

    if (total_blocks == 0) {
        return finishScanDataRead(&data, .complete, 0, null);
    }

    const max_payload_size = @max(block_size, last_block_size);
    const chunk_len = try std.math.add(usize, @as(usize, @intCast(max_payload_size)), 1);
    const chunk = try allocator.alloc(u8, chunk_len);
    defer allocator.free(chunk);

    var block_index: u32 = 0;
    var blocks_read: u32 = 0;
    var last_status: ?u8 = null;
    while (block_index < total_blocks) : (block_index += 1) {
        const is_last = block_index == total_blocks - 1;
        const payload_size = if (is_last and last_block_size != 0) last_block_size else block_size;
        const payload_len: usize = @intCast(payload_size);
        const read_buf = chunk[0 .. payload_len + 1];

        session.read(read_buf) catch {
            return finishScanDataRead(&data, .read_failed, blocks_read, null);
        };

        const status_byte = read_buf[payload_len];
        last_status = status_byte;
        try data.appendSlice(read_buf[0..payload_len]);
        blocks_read += 1;

        if ((status_byte & 0x80) != 0) {
            return finishScanDataRead(&data, .fatal_error, blocks_read, status_byte);
        }
        if ((status_byte & 0x20) != 0) {
            return finishScanDataRead(&data, .cancel_request, blocks_read, status_byte);
        }

        if (!is_last) {
            session.write(&.{interpreter.ACK}) catch {};
        }
    }

    return finishScanDataRead(&data, .complete, blocks_read, last_status);
}

fn callbackSlice(buffer: ?[*]u8, length: u32) UsbTransferError![]u8 {
    if (length == 0) return &.{};
    const ptr = buffer orelse return UsbTransferError.InvalidCallbackBuffer;
    return ptr[0..length];
}

fn callbackContext(handle: ?*anyopaque) UsbTransferError!*CallbackContext {
    if (detached_callback_context) |context| return context;
    const raw = handle orelse return UsbTransferError.InvalidCallbackContext;
    return @ptrCast(@alignCast(raw));
}

fn setCallbackOk(err: ?*i16) void {
    if (err) |ptr| ptr.* = callback_ok;
}

fn setCallbackError(err: ?*i16) void {
    if (err) |ptr| ptr.* = callback_error;
}

fn expectAck(usb: UsbIo) !void {
    var ack: [1]u8 = undefined;
    const n = try usb.read(&ack, direct_timeout_ms);
    if (n != 1 or ack[0] != interpreter.ACK) return UsbTransferError.UnexpectedAck;
}

fn symbolInit(context: *anyopaque, read_cb: UsbCallback, write_cb: UsbCallback, usb_handle: ?*anyopaque) bool {
    const symbols: *InterpreterSymbols = @ptrCast(@alignCast(context));
    return symbols.init(read_cb, write_cb, usb_handle) != 0;
}

fn symbolWrite(context: *anyopaque, data: []const u8) bool {
    if (data.len > std.math.maxInt(u32)) return false;
    const symbols: *InterpreterSymbols = @ptrCast(@alignCast(context));
    return symbols.write(data.ptr, @intCast(data.len)) != 0;
}

fn symbolRead(context: *anyopaque, buffer: []u8) bool {
    if (buffer.len > std.math.maxInt(u32)) return false;
    const symbols: *InterpreterSymbols = @ptrCast(@alignCast(context));
    return symbols.read(buffer.ptr, @intCast(buffer.len)) != 0;
}

fn symbolClose(context: *anyopaque) void {
    const symbols: *InterpreterSymbols = @ptrCast(@alignCast(context));
    symbols.close();
}

fn symbolUsbError(context: *anyopaque) i16 {
    const symbols: *InterpreterSymbols = @ptrCast(@alignCast(context));
    return symbols.usb_error();
}

fn symbolInterpreterError(context: *anyopaque) i32 {
    const symbols: *InterpreterSymbols = @ptrCast(@alignCast(context));
    return symbols.interpreter_error();
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn nearestResolution(dpi: u32, valid: []const u32) u32 {
    var best = valid[0];
    var best_delta = absDiff(dpi, best);
    for (valid[1..]) |candidate| {
        const delta = absDiff(dpi, candidate);
        if (delta < best_delta) {
            best = candidate;
            best_delta = delta;
        }
    }
    return best;
}

fn absDiff(a: u32, b: u32) u32 {
    return if (a >= b) a - b else b - a;
}

fn finishScanDataRead(
    data: *std.array_list.Managed(u8),
    status: ScanDataStatus,
    blocks_read: u32,
    status_byte: ?u8,
) !ScanDataReadResult {
    return .{
        .data = try data.toOwnedSlice(),
        .status = status,
        .blocks_read = blocks_read,
        .status_byte = status_byte,
    };
}

const FakeUsb = struct {
    read_bytes: []const u8 = &.{},
    read_offset: usize = 0,
    writes: [4096]u8 = undefined,
    write_len: usize = 0,
    fail_read: bool = false,
    fail_write: bool = false,
    /// Most bytes one read returns (0: no limit), like short USB transfers.
    read_chunk: usize = 0,
    last_read_timeout: u32 = 0,
    last_write_timeout: u32 = 0,

    fn io(self: *FakeUsb) UsbIo {
        return .{ .context = self, .readFn = read, .writeFn = write };
    }

    fn written(self: *const FakeUsb) []const u8 {
        return self.writes[0..self.write_len];
    }

    fn read(context: *anyopaque, buffer: []u8, timeout_ms: u32) UsbTransferError!usize {
        const self: *FakeUsb = @ptrCast(@alignCast(context));
        self.last_read_timeout = timeout_ms;
        if (self.fail_read) return UsbTransferError.UsbReadFailed;
        const available = self.read_bytes[self.read_offset..];
        var n = @min(buffer.len, available.len);
        if (self.read_chunk != 0) n = @min(n, self.read_chunk);
        @memcpy(buffer[0..n], available[0..n]);
        self.read_offset += n;
        return n;
    }

    fn write(context: *anyopaque, data: []const u8, timeout_ms: u32) UsbTransferError!void {
        const self: *FakeUsb = @ptrCast(@alignCast(context));
        self.last_write_timeout = timeout_ms;
        if (self.fail_write) return UsbTransferError.UsbWriteFailed;
        if (self.write_len + data.len > self.writes.len) return UsbTransferError.UsbWriteFailed;
        @memcpy(self.writes[self.write_len..][0..data.len], data);
        self.write_len += data.len;
    }
};

const FakeInterpreter = struct {
    init_count: usize = 0,
    close_count: usize = 0,
    write_count: usize = 0,
    read_count: usize = 0,
    read_bytes: ?[]const u8 = null,
    read_offset: usize = 0,
    writes: [4096]u8 = undefined,
    write_len: usize = 0,
    read_cb: ?UsbCallback = null,
    write_cb: ?UsbCallback = null,
    usb_handle: ?*anyopaque = null,
    fail_init: bool = false,
    fail_write: bool = false,
    fail_read: bool = false,

    fn api(self: *FakeInterpreter) InterpreterApi {
        return .{
            .context = self,
            .initFn = init,
            .writeFn = write,
            .readFn = read,
            .closeFn = close,
            .usbErrorFn = usbError,
            .interpreterErrorFn = interpreterError,
        };
    }

    fn written(self: *const FakeInterpreter) []const u8 {
        return self.writes[0..self.write_len];
    }

    fn init(context: *anyopaque, read_cb: UsbCallback, write_cb: UsbCallback, usb_handle: ?*anyopaque) bool {
        const self: *FakeInterpreter = @ptrCast(@alignCast(context));
        self.init_count += 1;
        self.read_cb = read_cb;
        self.write_cb = write_cb;
        self.usb_handle = usb_handle;
        return !self.fail_init;
    }

    fn write(context: *anyopaque, data: []const u8) bool {
        const self: *FakeInterpreter = @ptrCast(@alignCast(context));
        self.write_count += 1;
        if (self.fail_write) return false;
        if (self.write_len + data.len > self.writes.len) return false;
        @memcpy(self.writes[self.write_len..][0..data.len], data);
        self.write_len += data.len;
        return !self.fail_write;
    }

    fn read(context: *anyopaque, buffer: []u8) bool {
        const self: *FakeInterpreter = @ptrCast(@alignCast(context));
        self.read_count += 1;
        if (self.fail_read) return false;
        if (self.read_bytes) |bytes| {
            if (self.read_offset + buffer.len > bytes.len) return false;
            @memcpy(buffer, bytes[self.read_offset..][0..buffer.len]);
            self.read_offset += buffer.len;
        } else {
            @memset(buffer, 0);
        }
        return !self.fail_read;
    }

    fn close(context: *anyopaque) void {
        const self: *FakeInterpreter = @ptrCast(@alignCast(context));
        self.close_count += 1;
    }

    fn usbError(context: *anyopaque) i16 {
        _ = context;
        return -7;
    }

    fn interpreterError(context: *anyopaque) i32 {
        _ = context;
        return -11;
    }
};

const FakeSymbolLookup = struct {
    missing_name: ?[]const u8 = null,

    fn lookup(self: *FakeSymbolLookup, comptime T: type, name: [:0]const u8) ?T {
        if (self.missing_name) |missing| {
            if (std.mem.eql(u8, missing, name)) return null;
        }
        if (std.mem.eql(u8, name, "INTInit")) return @ptrCast(&fakeDynamicInit);
        if (std.mem.eql(u8, name, "INTWrite")) return @ptrCast(&fakeDynamicWrite);
        if (std.mem.eql(u8, name, "INTRead")) return @ptrCast(&fakeDynamicRead);
        if (std.mem.eql(u8, name, "INTClose")) return @ptrCast(&fakeDynamicClose);
        if (std.mem.eql(u8, name, "INTGetUSBError")) return @ptrCast(&fakeDynamicUsbError);
        if (std.mem.eql(u8, name, "INTGetInterpreterError")) return @ptrCast(&fakeDynamicInterpreterError);
        return null;
    }
};

var fake_dynamic_init_count: usize = 0;
var fake_dynamic_write_len: u32 = 0;
var fake_dynamic_read_len: u32 = 0;
var fake_dynamic_close_count: usize = 0;

fn resetFakeDynamicSymbols() void {
    fake_dynamic_init_count = 0;
    fake_dynamic_write_len = 0;
    fake_dynamic_read_len = 0;
    fake_dynamic_close_count = 0;
}

fn fakeDynamicInit(read_cb: UsbCallback, write_cb: UsbCallback, usb_handle: ?*anyopaque) callconv(.c) u8 {
    _ = read_cb;
    _ = write_cb;
    _ = usb_handle;
    fake_dynamic_init_count += 1;
    return 1;
}

fn fakeDynamicWrite(data: [*]const u8, len: u32) callconv(.c) u8 {
    _ = data;
    fake_dynamic_write_len = len;
    return 1;
}

fn fakeDynamicRead(data: [*]u8, len: u32) callconv(.c) u8 {
    if (len > 0) data[0] = 0xab;
    fake_dynamic_read_len = len;
    return 1;
}

fn fakeDynamicClose() callconv(.c) void {
    fake_dynamic_close_count += 1;
}

fn fakeDynamicUsbError() callconv(.c) i16 {
    return -3;
}

fn fakeDynamicInterpreterError() callconv(.c) i32 {
    return -5;
}

test "builds macOS interpreter search paths like Python" {
    const paths = try interpreterSearchPaths(std.testing.allocator, "/repo", "A1");
    defer freeInterpreterSearchPaths(std.testing.allocator, paths);
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    try std.testing.expectEqualStrings("/repo/firmware/Interpreter A1", paths[0]);
    try std.testing.expectEqualStrings(
        "/Library/Image Capture/Devices/EPSON Scanner.app/Contents/PlugIns/Interpreter A1.bundle/Contents/MacOS/Interpreter A1",
        paths[1],
    );
    try std.testing.expectEqualStrings(
        "/Library/Image Capture/Support/EPSON/Epson Scan 2/Models/ES00A1/Interpreter A1.bundle/Contents/MacOS/Interpreter A1",
        paths[2],
    );
}

test "direct ESC/I writes straight through and reads exactly the requested bytes" {
    var fake = FakeUsb{ .read_bytes = &.{ 0x06, 1, 2, 3, 4, 5, 6, 7, 8 }, .read_chunk = 3 };
    var direct = DirectEscI{ .usb = fake.io() };
    var session = InterpreterSession{ .api = direct.api(), .callback_context = .{ .usb = fake.io() } };
    try session.init();

    try std.testing.expect(commandAck(&session, &interpreter.resetCommand()));
    try std.testing.expectEqualSlices(u8, &interpreter.resetCommand(), fake.written());
    var block: [8]u8 = undefined;
    try session.read(&block);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &block);
    try std.testing.expectEqual(direct_esci_timeout_ms, fake.last_read_timeout);
    // Nothing more to read: the read fails instead of returning short.
    try std.testing.expectError(error.InterpreterReadFailed, session.read(&block));
    try session.reinit();
    session.close();
}

test "select_endpoint_pair preserves first OUT and first IN descriptor behavior" {
    const pair = selectEndpointPair(&.{ 0x02, 0x83, 0x04, 0x85 }).?;
    try std.testing.expectEqual(@as(u8, 0x02), pair.out_address);
    try std.testing.expectEqual(@as(u8, 0x83), pair.in_address);

    try std.testing.expectEqual(@as(?UsbEndpointPair, null), selectEndpointPair(&.{ 0x01, 0x02 }));
    try std.testing.expectEqual(@as(?UsbEndpointPair, null), selectEndpointPair(&.{ 0x81, 0x82 }));
}

test "loads Epson interpreter symbol set and exposes InterpreterApi wrappers" {
    resetFakeDynamicSymbols();
    var lookup = FakeSymbolLookup{};
    var symbols = loadInterpreterSymbols(&lookup).?;
    var api = symbols.api();

    try std.testing.expect(api.initFn(api.context, usbReadCallback, usbWriteCallback, null));
    try std.testing.expect(api.writeFn(api.context, "abc"));
    var buffer = [_]u8{0} ** 2;
    try std.testing.expect(api.readFn(api.context, &buffer));
    api.closeFn(api.context);

    try std.testing.expectEqual(@as(usize, 1), fake_dynamic_init_count);
    try std.testing.expectEqual(@as(u32, 3), fake_dynamic_write_len);
    try std.testing.expectEqual(@as(u32, 2), fake_dynamic_read_len);
    try std.testing.expectEqual(@as(u8, 0xab), buffer[0]);
    try std.testing.expectEqual(@as(usize, 1), fake_dynamic_close_count);
    try std.testing.expectEqual(@as(i16, -3), api.usbErrorFn(api.context));
    try std.testing.expectEqual(@as(i32, -5), api.interpreterErrorFn(api.context));
}

test "rejects incomplete Epson interpreter symbol set" {
    var lookup = FakeSymbolLookup{ .missing_name = "INTRead" };
    try std.testing.expectEqual(@as(?InterpreterSymbols, null), loadInterpreterSymbols(&lookup));
}

test "find_interpreter keeps Python's Linux no-op behavior" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "firmware", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "firmware/Interpreter A1", .data = "stub" });

    const base_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(base_dir);

    const found = try findInterpreterForHost(allocator, std.testing.io, base_dir, "A1", .linux);
    try std.testing.expectEqual(@as(?[]u8, null), found);
}

test "find_interpreter returns the first existing macOS interpreter path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "firmware", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "firmware/Interpreter A1", .data = "stub" });

    const base_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(base_dir);
    const expected = try std.fmt.allocPrint(allocator, "{s}/firmware/Interpreter A1", .{base_dir});
    defer allocator.free(expected);

    const found = (try findInterpreterForHost(allocator, std.testing.io, base_dir, "A1", .macos)).?;
    defer allocator.free(found);
    try std.testing.expectEqualStrings(expected, found);
}

test "find_interpreter returns null when no non-Linux search path exists" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(base_dir);

    const found = try findInterpreterUnderRoot(allocator, std.testing.io, base_dir, "A1", .macos, base_dir);
    defer if (found) |path| allocator.free(path);
    try std.testing.expectEqual(@as(?[]u8, null), found);
}

test "ensure_interpreter manual helper reports unsupported Linux without download" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "firmware", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "firmware/Interpreter A1", .data = "stub" });
    const base_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(base_dir);

    var requirement = try ensureInterpreterManualForHost(allocator, std.testing.io, base_dir, "A1", .linux);
    defer requirement.deinit(allocator);
    try std.testing.expectEqual(InterpreterRequirementStatus.unsupported_linux, requirement.status);
    try std.testing.expect(requirement.path == null);
    try std.testing.expectEqualStrings("A1", requirement.interp_id);
    try std.testing.expectEqualStrings(ica_driver_url, requirement.driver_url);
}

test "ensure_interpreter manual helper returns ready path when interpreter exists" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "firmware", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "firmware/Interpreter A1", .data = "stub" });
    const base_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(base_dir);
    const expected = try std.fmt.allocPrint(allocator, "{s}/firmware/Interpreter A1", .{base_dir});
    defer allocator.free(expected);

    var requirement = try ensureInterpreterManualForHost(allocator, std.testing.io, base_dir, "A1", .macos);
    defer requirement.deinit(allocator);
    try std.testing.expectEqual(InterpreterRequirementStatus.ready, requirement.status);
    try std.testing.expectEqualStrings(expected, requirement.path.?);
}

test "ensure_interpreter manual helper reports missing without automatic download" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(base_dir);

    var requirement = try ensureInterpreterManualUnderRoot(allocator, std.testing.io, base_dir, "A1", .macos, base_dir);
    defer requirement.deinit(allocator);
    try std.testing.expectEqual(InterpreterRequirementStatus.missing_manual_install_required, requirement.status);
    try std.testing.expect(requirement.path == null);
    try std.testing.expectEqualStrings(ica_driver_url, requirement.driver_url);
}

test "initializes and reinitializes interpreter session with persistent callbacks" {
    var fake_usb = FakeUsb{ .read_bytes = &.{0xaa} };
    var fake_interpreter = FakeInterpreter{};
    var session = InterpreterSession{
        .api = fake_interpreter.api(),
        .callback_context = .{ .usb = fake_usb.io() },
    };

    try session.init();
    try std.testing.expectEqual(@as(usize, 1), fake_interpreter.init_count);
    try std.testing.expectEqual(@intFromPtr(&session.callback_context), @intFromPtr(fake_interpreter.usb_handle.?));
    try std.testing.expect(fake_interpreter.read_cb.? == usbReadCallback);
    try std.testing.expect(fake_interpreter.write_cb.? == usbWriteCallback);

    try session.write(&.{ interpreter.ESC, 0x40 });
    var buf = [_]u8{0} ** 2;
    try session.read(&buf);
    try std.testing.expectEqual(@as(usize, 1), fake_interpreter.write_count);
    try std.testing.expectEqual(@as(usize, 1), fake_interpreter.read_count);
    try std.testing.expectEqual(@as(i16, -7), session.usbError());
    try std.testing.expectEqual(@as(i32, -11), session.interpreterError());

    try session.reinit();
    try std.testing.expectEqual(@as(usize, 1), fake_interpreter.close_count);
    try std.testing.expectEqual(@as(usize, 2), fake_interpreter.init_count);
}

test "detached session passes a NULL handle and routes callbacks to its context" {
    var fake_usb = FakeUsb{ .read_bytes = &.{0x5a} };
    var fake_interpreter = FakeInterpreter{};
    var session = InterpreterSession{
        .api = fake_interpreter.api(),
        .callback_context = .{ .usb = fake_usb.io() },
        .detached = true,
    };

    try session.init();
    try std.testing.expect(fake_interpreter.usb_handle == null);

    var buf = [_]u8{0};
    var err: i16 = 99;
    try std.testing.expectEqual(callback_success, fake_interpreter.read_cb.?(&buf, buf.len, null, &err));
    try std.testing.expectEqual(@as(u8, 0x5a), buf[0]);
    try std.testing.expectEqual(callback_ok, err);

    session.close();
    try std.testing.expectEqual(callback_failure, usbReadCallback(&buf, buf.len, null, &err));
}

test "read_scan_data reads full and final blocks with ACKs between blocks" {
    const allocator = std.testing.allocator;
    var fake_interpreter = FakeInterpreter{ .read_bytes = &.{
        'a', 'b', 'c',  0x00,
        'd', 'e', 'f',  0x00,
        'g', 'h', 0x00,
    } };
    var session = InterpreterSession{
        .api = fake_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };

    var result = try readScanData(allocator, &session, 3, 2, 2);
    defer result.deinit(allocator);

    try std.testing.expectEqual(ScanDataStatus.complete, result.status);
    try std.testing.expectEqual(@as(u32, 3), result.blocks_read);
    try std.testing.expectEqual(@as(?u8, 0x00), result.status_byte);
    try std.testing.expectEqualSlices(u8, "abcdefgh", result.data);
    try std.testing.expectEqualSlices(u8, &.{ interpreter.ACK, interpreter.ACK }, fake_interpreter.written());
}

test "read_scan_data returns partial bytes on interpreter read failure" {
    const allocator = std.testing.allocator;
    var fake_interpreter = FakeInterpreter{ .read_bytes = &.{
        'a', 'b', 0x00,
    } };
    var session = InterpreterSession{
        .api = fake_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };

    var result = try readScanData(allocator, &session, 2, 2, 0);
    defer result.deinit(allocator);

    try std.testing.expectEqual(ScanDataStatus.read_failed, result.status);
    try std.testing.expectEqual(@as(u32, 1), result.blocks_read);
    try std.testing.expectEqual(@as(?u8, null), result.status_byte);
    try std.testing.expectEqualSlices(u8, "ab", result.data);
    try std.testing.expectEqualSlices(u8, &.{interpreter.ACK}, fake_interpreter.written());
}

test "read_scan_data keeps fatal block payload and does not ACK it" {
    const allocator = std.testing.allocator;
    var fake_interpreter = FakeInterpreter{ .read_bytes = &.{
        'a', 'b', 0x80,
        'c', 'd', 0x00,
    } };
    var session = InterpreterSession{
        .api = fake_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };

    var result = try readScanData(allocator, &session, 2, 2, 0);
    defer result.deinit(allocator);

    try std.testing.expectEqual(ScanDataStatus.fatal_error, result.status);
    try std.testing.expectEqual(@as(u32, 1), result.blocks_read);
    try std.testing.expectEqual(@as(?u8, 0x80), result.status_byte);
    try std.testing.expectEqualSlices(u8, "ab", result.data);
    try std.testing.expectEqualSlices(u8, &.{}, fake_interpreter.written());
}

test "read_scan_data keeps cancel block payload and stops after previous ACK" {
    const allocator = std.testing.allocator;
    var fake_interpreter = FakeInterpreter{ .read_bytes = &.{
        'a', 'b', 0x00,
        'c', 'd', 0x20,
    } };
    var session = InterpreterSession{
        .api = fake_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };

    var result = try readScanData(allocator, &session, 2, 2, 0);
    defer result.deinit(allocator);

    try std.testing.expectEqual(ScanDataStatus.cancel_request, result.status);
    try std.testing.expectEqual(@as(u32, 2), result.blocks_read);
    try std.testing.expectEqual(@as(?u8, 0x20), result.status_byte);
    try std.testing.expectEqualSlices(u8, "abcd", result.data);
    try std.testing.expectEqualSlices(u8, &.{interpreter.ACK}, fake_interpreter.written());
}

test "start_extended_scan writes FS G and parses scan block info" {
    var fake_interpreter = FakeInterpreter{ .read_bytes = &.{
        0x02, 0x00,
        0x00, 0x10,
        0x00, 0x00,
        0x03, 0x00,
        0x00, 0x00,
        0x80, 0x00,
        0x00, 0x00,
    } };
    var session = InterpreterSession{
        .api = fake_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };

    const info = startExtendedScan(&session).?;
    const command = interpreter.startExtendedScanCommand();
    try std.testing.expectEqualSlices(u8, &command, fake_interpreter.written());
    try std.testing.expectEqual(@as(u8, 0), info.status);
    try std.testing.expectEqual(@as(u32, 4096), info.block_size);
    try std.testing.expectEqual(@as(u32, 3), info.block_count);
    try std.testing.expectEqual(@as(u32, 128), info.last_block_size);
}

test "start_extended_scan returns null on Python None response cases" {
    var bad_response = FakeInterpreter{ .read_bytes = &.{
        0x00, 0x00,
        0x00, 0x10,
        0x00, 0x00,
        0x03, 0x00,
        0x00, 0x00,
        0x80, 0x00,
        0x00, 0x00,
    } };
    var bad_session = InterpreterSession{
        .api = bad_response.api(),
        .callback_context = .{ .usb = undefined },
    };
    try std.testing.expect(startExtendedScan(&bad_session) == null);

    var failed_write = FakeInterpreter{ .fail_write = true };
    var failed_write_session = InterpreterSession{
        .api = failed_write.api(),
        .callback_context = .{ .usb = undefined },
    };
    try std.testing.expect(startExtendedScan(&failed_write_session) == null);

    var failed_read = FakeInterpreter{ .read_bytes = &.{} };
    var failed_read_session = InterpreterSession{
        .api = failed_read.api(),
        .callback_context = .{ .usb = undefined },
    };
    try std.testing.expect(startExtendedScan(&failed_read_session) == null);
}

test "commandAck preserves Python ACK NAK and unexpected response behavior" {
    var ack_interpreter = FakeInterpreter{ .read_bytes = &.{interpreter.ACK} };
    var ack_session = InterpreterSession{
        .api = ack_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };
    try std.testing.expect(commandAck(&ack_session, &.{ 0xaa, 0xbb }));
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, ack_interpreter.written());

    var nak_interpreter = FakeInterpreter{ .read_bytes = &.{interpreter.NAK} };
    var nak_session = InterpreterSession{
        .api = nak_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };
    try std.testing.expect(!commandAck(&nak_session, &.{0xcc}));

    var unexpected_interpreter = FakeInterpreter{ .read_bytes = &.{0x99} };
    var unexpected_session = InterpreterSession{
        .api = unexpected_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };
    try std.testing.expect(commandAck(&unexpected_session, &.{0xdd}));
}

test "reset uses Python ESC at command ACK exchange" {
    var fake_interpreter = FakeInterpreter{ .read_bytes = &.{interpreter.ACK} };
    var session = InterpreterSession{
        .api = fake_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };

    const command = interpreter.resetCommand();
    try std.testing.expect(reset(&session));
    try std.testing.expectEqualSlices(u8, &command, fake_interpreter.written());
}

test "identity and status runtime reads write Python commands and fill buffers" {
    var identity_bytes = [_]u8{0x11} ** 256;
    var identity_interpreter = FakeInterpreter{ .read_bytes = &identity_bytes };
    var identity_session = InterpreterSession{
        .api = identity_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };
    var identity_out: [256]u8 = undefined;
    const identity_command = interpreter.identityCommand();
    try std.testing.expect(getIdentity(&identity_session, &identity_out));
    try std.testing.expectEqualSlices(u8, &identity_command, identity_interpreter.written());
    try std.testing.expectEqualSlices(u8, &identity_bytes, &identity_out);

    var status_bytes = [_]u8{0x22} ** 16;
    var status_interpreter = FakeInterpreter{ .read_bytes = &status_bytes };
    var status_session = InterpreterSession{
        .api = status_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };
    var status_out: [16]u8 = undefined;
    const status_command = interpreter.statusCommand();
    try std.testing.expect(getStatus(&status_session, &status_out));
    try std.testing.expectEqualSlices(u8, &status_command, status_interpreter.written());
    try std.testing.expectEqualSlices(u8, &status_bytes, &status_out);

    var extended_status_bytes = [_]u8{0x33} ** 64;
    var extended_status_interpreter = FakeInterpreter{ .read_bytes = &extended_status_bytes };
    var extended_status_session = InterpreterSession{
        .api = extended_status_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };
    var extended_status_out: [64]u8 = undefined;
    const extended_status_command = interpreter.extendedStatusCommand();
    try std.testing.expect(getExtendedStatus(&extended_status_session, &extended_status_out));
    try std.testing.expectEqualSlices(u8, &extended_status_command, extended_status_interpreter.written());
    try std.testing.expectEqualSlices(u8, &extended_status_bytes, &extended_status_out);
}

test "get_extended_identity writes FS I and parses capability response" {
    var resp = [_]u8{0} ** 80;
    resp[0] = '2';
    resp[1] = '0';
    std.mem.writeInt(u32, resp[4..8], 6400, .little);
    std.mem.writeInt(u32, resp[8..12], 50, .little);
    std.mem.writeInt(u32, resp[12..16], 12800, .little);
    std.mem.writeInt(u32, resp[16..20], 65535, .little);
    std.mem.writeInt(u32, resp[20..24], 54400, .little);
    std.mem.writeInt(u32, resp[24..28], 74880, .little);
    std.mem.writeInt(u32, resp[36..40], 17280, .little);
    std.mem.writeInt(u32, resp[40..44], 61056, .little);
    resp[44] = 0x82;
    @memcpy(resp[46..62], "GT-X820         ");
    resp[66] = 16;
    resp[67] = 16;

    var fake_interpreter = FakeInterpreter{ .read_bytes = &resp };
    var session = InterpreterSession{
        .api = fake_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };

    const command = interpreter.extendedIdentityCommand();
    const identity = getExtendedIdentity(&session).?;
    try std.testing.expectEqualSlices(u8, &command, fake_interpreter.written());
    try std.testing.expectEqual(@as(u32, 6400), identity.optical_dpi);
    try std.testing.expectEqual(@as(u32, 17280), identity.tpu_width);
    try std.testing.expect(identity.irSupported());
    try std.testing.expectEqualStrings("GT-X820", identity.modelName());
}

test "macOS extended identity maps to shared scanner capabilities like Python" {
    var model: [16]u8 = undefined;
    @memcpy(&model, "GT-X820         ");
    const identity = interpreter.ExtendedIdentity{
        .command_level_major = '2',
        .command_level_minor = '0',
        .optical_dpi = 6400,
        .min_dpi = 50,
        .max_dpi = 12800,
        .max_pixels = 65535,
        .flatbed_width = 54400,
        .flatbed_height = 74880,
        .tpu_width = 17280,
        .tpu_height = 61056,
        .capabilities = 0x82,
        .model = model,
        .input_depth = 16,
        .max_output_depth = 16,
    };

    const caps = capabilitiesFromExtendedIdentity(&identity);
    try std.testing.expectEqual(@as(u32, 6400), caps.optical_dpi);
    try std.testing.expectEqual(@as(u32, 12800), caps.max_resolution);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5), caps.flatbed_width_in, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 11.7), caps.flatbed_height_in, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.7), caps.tpu_width_in, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 9.54), caps.tpu_height_in, 0.000001);
    try std.testing.expect(caps.ir_supported);
    try std.testing.expectEqualStrings("GT-X820", caps.model);
}

test "macOS scan planning defaults TPU RGB area and snaps DPI like Python" {
    const caps = contracts.ScannerCapabilities{
        .optical_dpi = 6400,
        .max_resolution = 12800,
        .flatbed_width_in = 8.5,
        .flatbed_height_in = 11.7,
        .tpu_width_in = 2.7,
        .tpu_height_in = 9.54,
    };
    const request = contracts.ScanRequest{
        .dpi = 333,
        .source = .tpu,
        .kind = .rgb,
        .depth = .sixteen,
    };

    const plan = try planScan(request, caps);
    try std.testing.expectEqual(@as(u32, 320), plan.effective_dpi);
    try std.testing.expectEqual(@as(u32, 333), plan.original_dpi);
    try std.testing.expectEqual(@as(u32, 0), plan.x_pixels);
    try std.testing.expectEqual(@as(u32, 0), plan.y_pixels);
    try std.testing.expectEqual(@as(u32, 864), plan.out_width);
    try std.testing.expectEqual(@as(u32, 3052), plan.out_height);
    try std.testing.expectEqual(@as(u8, 0x13), plan.color_mode);
    try std.testing.expectEqual(@as(u8, 1), plan.source_code);
    try std.testing.expectEqual(@as(u8, 3), plan.channels);
    try std.testing.expectEqual(@as(u8, 6), plan.bytes_per_pixel);
    try std.testing.expectEqual(@as(u64, 864 * 3052 * 6), plan.expected_size);
    try std.testing.expectEqual(@as(u32, 320), plan.params.dpi);
    try std.testing.expectEqual(@as(u32, 864), plan.params.width);
    try std.testing.expectEqual(@as(u32, 3052), plan.params.height);
    try std.testing.expectEqual(@as(u8, 16), plan.params.depth);
}

test "macOS scan planning uses IR resolution table and selected area" {
    const caps = contracts.ScannerCapabilities{
        .optical_dpi = 6400,
        .max_resolution = 12800,
        .flatbed_width_in = 8.5,
        .flatbed_height_in = 11.7,
        .tpu_width_in = 2.7,
        .tpu_height_in = 9.54,
    };
    const request = contracts.ScanRequest{
        .dpi = 1200,
        .source = .tpu,
        .kind = .ir,
        .depth = .sixteen,
        .area = .{ .x = 0.1, .y = 0.2, .width = 0.5, .height = 0.25 },
    };

    const plan = try planScan(request, caps);
    try std.testing.expectEqual(@as(u32, 800), plan.effective_dpi);
    try std.testing.expectEqual(@as(u32, 80), plan.x_pixels);
    try std.testing.expectEqual(@as(u32, 160), plan.y_pixels);
    try std.testing.expectEqual(@as(u32, 400), plan.out_width);
    try std.testing.expectEqual(@as(u32, 200), plan.out_height);
    try std.testing.expectEqual(@as(u8, 0x00), plan.color_mode);
    try std.testing.expectEqual(@as(u8, 3), plan.source_code);
    try std.testing.expectEqual(@as(u8, 1), plan.channels);
    try std.testing.expectEqual(@as(u8, 2), plan.bytes_per_pixel);
    try std.testing.expectEqual(@as(u64, 400 * 200 * 2), plan.expected_size);
    try std.testing.expectEqual(@as(u32, 800), plan.params.dpi);
    try std.testing.expectEqual(@as(u32, 80), plan.params.x);
    try std.testing.expectEqual(@as(u32, 160), plan.params.y);
    try std.testing.expectEqual(@as(u8, 3), plan.params.source);
}

test "write-only setup commands use Python command builders" {
    const allocator = std.testing.allocator;
    var fake_interpreter = FakeInterpreter{};
    var session = InterpreterSession{
        .api = fake_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };

    try std.testing.expect(setResolution(&session, 3200));
    try std.testing.expect(setScanArea(&session, 1, 2, 3, 4));
    try std.testing.expect(setColorMode(&session, 0x13));
    try std.testing.expect(setDataFormat(&session, 16));
    try std.testing.expect(setSource(&session, 3, true));
    try std.testing.expect(startScan(&session));

    const resolution = interpreter.setResolutionCommand(3200);
    const area = interpreter.setScanAreaCommand(1, 2, 3, 4);
    const color = interpreter.setColorModeCommand(0x13);
    const format = interpreter.setDataFormatCommand(16);
    const source = interpreter.setSourceCommand(3, true);
    const start = interpreter.startScanCommand();
    var expected = std.array_list.Managed(u8).init(allocator);
    defer expected.deinit();
    try expected.appendSlice(&resolution);
    try expected.appendSlice(&area);
    try expected.appendSlice(&color);
    try expected.appendSlice(&format);
    try expected.appendSlice(&source);
    try expected.appendSlice(&start);
    try std.testing.expectEqualSlices(u8, expected.items, fake_interpreter.written());
}

test "set_scanning_parameters sends FS W then parameter block with ACKs" {
    const allocator = std.testing.allocator;
    var fake_interpreter = FakeInterpreter{ .read_bytes = &.{ interpreter.ACK, interpreter.ACK } };
    var session = InterpreterSession{
        .api = fake_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };
    const params = interpreter.SetParameters{
        .dpi = 3200,
        .x = 11,
        .y = 22,
        .width = 333,
        .height = 444,
        .color_mode = 0x13,
        .depth = 16,
        .source = 3,
        .scan_mode = 1,
        .block_lines = 2,
        .gamma = 0x03,
    };
    const command = interpreter.setScanningParametersCommand();
    const block = interpreter.buildSetScanningParameters(params);
    var expected = std.array_list.Managed(u8).init(allocator);
    defer expected.deinit();
    try expected.appendSlice(&command);
    try expected.appendSlice(&block);

    try std.testing.expect(setScanningParameters(&session, params));
    try std.testing.expectEqualSlices(u8, expected.items, fake_interpreter.written());
}

test "enable_infrared reads scan parameters and sends ACKed challenge" {
    const allocator = std.testing.allocator;
    var script = [_]u8{0} ** 66;
    for (script[0..64], 0..) |*byte, i| byte.* = @intCast(i);
    script[64] = interpreter.ACK;
    script[65] = interpreter.ACK;

    var fake_interpreter = FakeInterpreter{ .read_bytes = &script };
    var session = InterpreterSession{
        .api = fake_interpreter.api(),
        .callback_context = .{ .usb = undefined },
    };

    const read_params = interpreter.readScanParametersCommand();
    const enable_command = [_]u8{ interpreter.ESC, 0x23 };
    const challenge = try interpreter.buildInfraredChallenge(script[0..64]);
    var expected = std.array_list.Managed(u8).init(allocator);
    defer expected.deinit();
    try expected.appendSlice(&read_params);
    try expected.appendSlice(&enable_command);
    try expected.appendSlice(&challenge);

    try std.testing.expect(enableInfrared(&session));
    try std.testing.expectEqualSlices(u8, expected.items, fake_interpreter.written());
}

test "macOS USB read callback copies bytes and sets interpreter error pointer" {
    var fake = FakeUsb{ .read_bytes = &.{ 0x10, 0x20, 0x30, 0x40 } };
    var context = CallbackContext{ .usb = fake.io() };
    var out = [_]u8{0} ** 4;
    var err: i16 = 99;

    try std.testing.expectEqual(callback_success, usbReadCallback(&out, out.len, &context, &err));
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30, 0x40 }, &out);
    try std.testing.expectEqual(callback_ok, err);
    try std.testing.expectEqual(callback_timeout_ms, fake.last_read_timeout);
}

test "macOS USB callbacks fail like Python on transfer errors" {
    var fake = FakeUsb{ .fail_read = true };
    var context = CallbackContext{ .usb = fake.io() };
    var out = [_]u8{0} ** 1;
    var err: i16 = 0;

    try std.testing.expectEqual(callback_failure, usbReadCallback(&out, out.len, &context, &err));
    try std.testing.expectEqual(callback_error, err);

    err = 0;
    try std.testing.expectEqual(callback_failure, usbWriteCallback(&out, out.len, null, &err));
    try std.testing.expectEqual(callback_error, err);
}

test "macOS USB write callback forwards exact bytes" {
    var fake = FakeUsb{};
    var context = CallbackContext{ .usb = fake.io() };
    var data = [_]u8{ 0xaa, 0xbb, 0xcc };
    var err: i16 = 99;

    try std.testing.expectEqual(callback_success, usbWriteCallback(&data, data.len, &context, &err));
    try std.testing.expectEqualSlices(u8, &data, fake.written());
    try std.testing.expectEqual(callback_ok, err);
    try std.testing.expectEqual(callback_timeout_ms, fake.last_write_timeout);
}

test "executes direct RS command with Python ACK handshake" {
    var fake = FakeUsb{ .read_bytes = &.{ interpreter.ACK, interpreter.ACK } };
    try rsCommand(fake.io(), .{ .subcommand = 0x31, .data = &.{ 0x01, 0x02, 0x03 } });
    try std.testing.expectEqualSlices(u8, &.{ interpreter.RS, 0x31, 0x01, 0x02, 0x03 }, fake.written());
    try std.testing.expectEqual(direct_timeout_ms, fake.last_read_timeout);
    try std.testing.expectEqual(direct_timeout_ms, fake.last_write_timeout);
}

test "executes register write as prefix ACK then header data ACK" {
    var fake = FakeUsb{ .read_bytes = &.{ interpreter.ACK, interpreter.ACK } };
    const header = [_]u8{ 0x03, 0x00, 0xfc, 0x1f, 0x02, 0x00, 0x01, 0x00 };
    const data = [_]u8{ 0x00, 0x7f, 0xff };
    try registerWrite(fake.io(), .{ .header = &header, .data = &data });
    try std.testing.expectEqualSlices(u8, &.{
        interpreter.RS, 0x84,
        0x03,           0x00,
        0xfc,           0x1f,
        0x02,           0x00,
        0x01,           0x00,
        0x00,           0x7f,
        0xff,
    }, fake.written());
}

test "uploads gamma tables before TPU calibration program" {
    const ack_count = 2 * 3 + 2 * 11 + 1 + 2;
    var ack_bytes = [_]u8{interpreter.ACK} ** ack_count;
    var fake = FakeUsb{ .read_bytes = &ack_bytes };
    const lut = [_]u8{0x55} ** 256;

    try configureTpu(fake.io(), .{ .r = &lut, .g = &lut, .b = &lut });
    const written = fake.written();
    try std.testing.expectEqualSlices(u8, &.{ interpreter.RS, 0x84 }, written[0..2]);
    try std.testing.expectEqualSlices(u8, &interpreter.gammaRegisterHeader(0xfc), written[2..10]);
    try std.testing.expectEqual(@as(u8, 0x55), written[10]);
    const calibration_start = 3 * (2 + 8 + 256);
    try std.testing.expectEqualSlices(u8, &.{ interpreter.RS, 0xa2, 0x02 }, written[calibration_start..][0..3]);
    try std.testing.expectEqual(@as(usize, ack_count), fake.read_offset);
}
