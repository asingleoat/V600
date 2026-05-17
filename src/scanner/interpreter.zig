const std = @import("std");

pub const ESC: u8 = 0x1b;
pub const FS: u8 = 0x1c;
pub const RS: u8 = 0x1e;
pub const ACK: u8 = 0x06;
pub const NAK: u8 = 0x15;
pub const CAN: u8 = 0x18;

pub const IrXorKey = [32]u8{
    0xCA, 0xFB, 0x77, 0x71, 0x20, 0x16, 0xDA, 0x09,
    0x5F, 0x57, 0x09, 0x12, 0x04, 0x83, 0x76, 0x77,
    0x3C, 0x73, 0x9C, 0xBE, 0x7A, 0xE0, 0x52, 0xE2,
    0x90, 0x0D, 0xFF, 0x9A, 0xEF, 0x4C, 0x2C, 0x81,
};

pub const Error = error{
    InvalidChallengeInput,
    InvalidExtendedIdentityResponse,
    InvalidStartScanResponse,
    FatalScannerStatus,
    ScannerNotReady,
};

pub const SetParameters = struct {
    dpi: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    color_mode: u8 = 0x13,
    depth: u8 = 8,
    source: u8 = 0,
    scan_mode: u8 = 0,
    block_lines: u8 = 0,
    gamma: u8 = 0x03,
};

pub const StartScanInfo = struct {
    status: u8,
    block_size: u32,
    block_count: u32,
    last_block_size: u32,
};

pub const RsCommand = struct {
    subcommand: u8,
    data: []const u8 = &.{},
};

pub const RegisterWrite = struct {
    header: []const u8,
    data: []const u8,
};

pub const TpuCalibrationOp = union(enum) {
    rs: RsCommand,
    register_write: RegisterWrite,
};

pub const ExtendedIdentity = struct {
    command_level_major: u8,
    command_level_minor: u8,
    optical_dpi: u32,
    min_dpi: u32,
    max_dpi: u32,
    max_pixels: u32,
    flatbed_width: u32,
    flatbed_height: u32,
    tpu_width: u32,
    tpu_height: u32,
    capabilities: u8,
    model: [16]u8,
    input_depth: u8,
    max_output_depth: u8,

    pub fn modelName(self: *const ExtendedIdentity) []const u8 {
        return trimModelName(&self.model);
    }

    pub fn irSupported(self: ExtendedIdentity) bool {
        return (self.capabilities & 0x02) != 0;
    }
};

const cmd_a2 = [_]u8{0x02};
const cmd_25 = [_]u8{0x02};
const cmd_5a = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
const cmd_11 = [_]u8{0x03};
const cmd_31 = [_]u8{
    0x80, 0x00,
    0x80, 0x00,
    0x80, 0x00,
    0x00, 0x00,
    0x1e, 0x1e,
    0x1e, 0x00,
};
const cmd_21 = [_]u8{
    0x80, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00,
};
const cmd_22 = [_]u8{
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x80, 0x16, 0x00, 0x00, 0x00, 0x00,
};
const cmd_41 = [_]u8{
    0x8f, 0x0c, 0x0f, 0x0e, 0x96, 0x00, 0x00, 0x00,
    0x01, 0x01, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x80, 0x80, 0x96, 0x00, 0x00, 0x00,
};
const cmd_42 = [_]u8{0x00} ** 24;
const cmd_43 = [_]u8{
    0x00, 0x80,
    0x00, 0x80,
    0x00, 0x80,
    0x09, 0x78,
    0xec, 0x79,
    0xf2, 0x7a,
    0x00, 0x00,
    0x00, 0x00,
    0x00, 0x00,
};
const cmd_01 = [_]u8{
    0x30, 0x05, 0x00, 0x00,
    0x80, 0x00, 0xff, 0x00,
    0xff, 0x00, 0x02, 0x00,
};
const gain_shading_header = [_]u8{ 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00 };
const gain_shading_data = block: {
    var data = [_]u8{0xff} ** 256;
    data[0] = 0x00;
    data[1] = 0x00;
    data[2] = 0x00;
    data[3] = 0x00;
    data[4] = 0x28;
    data[5] = 0x00;
    data[6] = 0xc0;
    data[7] = 0x39;
    data[8] = 0xc8;
    data[9] = 0x00;
    data[10] = 0xc0;
    data[11] = 0x39;
    data[12] = 0x90;
    data[13] = 0x01;
    data[14] = 0x00;
    data[15] = 0x10;
    break :block data;
};

pub const tpu_calibration_sequence = [_]RsCommand{
    .{ .subcommand = 0xa2, .data = &cmd_a2 },
    .{ .subcommand = 0x25, .data = &cmd_25 },
    .{ .subcommand = 0x5a, .data = &cmd_5a },
    .{ .subcommand = 0x11, .data = &cmd_11 },
    .{ .subcommand = 0x31, .data = &cmd_31 },
    .{ .subcommand = 0x21, .data = &cmd_21 },
    .{ .subcommand = 0x22, .data = &cmd_22 },
    .{ .subcommand = 0x41, .data = &cmd_41 },
    .{ .subcommand = 0x42, .data = &cmd_42 },
    .{ .subcommand = 0x43, .data = &cmd_43 },
    .{ .subcommand = 0x01, .data = &cmd_01 },
    .{ .subcommand = 0x05 },
};

pub const tpu_calibration_program = [_]TpuCalibrationOp{
    .{ .rs = .{ .subcommand = 0xa2, .data = &cmd_a2 } },
    .{ .rs = .{ .subcommand = 0x25, .data = &cmd_25 } },
    .{ .rs = .{ .subcommand = 0x5a, .data = &cmd_5a } },
    .{ .rs = .{ .subcommand = 0x11, .data = &cmd_11 } },
    .{ .rs = .{ .subcommand = 0x31, .data = &cmd_31 } },
    .{ .rs = .{ .subcommand = 0x21, .data = &cmd_21 } },
    .{ .register_write = .{ .header = &gain_shading_header, .data = &gain_shading_data } },
    .{ .rs = .{ .subcommand = 0x22, .data = &cmd_22 } },
    .{ .rs = .{ .subcommand = 0x41, .data = &cmd_41 } },
    .{ .rs = .{ .subcommand = 0x42, .data = &cmd_42 } },
    .{ .rs = .{ .subcommand = 0x43, .data = &cmd_43 } },
    .{ .rs = .{ .subcommand = 0x01, .data = &cmd_01 } },
    .{ .rs = .{ .subcommand = 0x05 } },
};

pub fn resetCommand() [2]u8 {
    return .{ ESC, 0x40 };
}

pub fn identityCommand() [2]u8 {
    return .{ ESC, 0x49 };
}

pub fn statusCommand() [2]u8 {
    return .{ ESC, 0x46 };
}

pub fn extendedStatusCommand() [2]u8 {
    return .{ ESC, 0x66 };
}

pub fn extendedIdentityCommand() [2]u8 {
    return .{ FS, 0x49 };
}

pub fn setResolutionCommand(dpi: u16) [6]u8 {
    var command = [_]u8{ ESC, 0x52, 0, 0, 0, 0 };
    std.mem.writeInt(u16, command[2..4], dpi, .little);
    std.mem.writeInt(u16, command[4..6], dpi, .little);
    return command;
}

pub fn setScanAreaCommand(x: u32, y: u32, width: u32, height: u32) [18]u8 {
    var command = [_]u8{ ESC, 0x41 } ++ ([_]u8{0} ** 16);
    std.mem.writeInt(u32, command[2..6], x, .little);
    std.mem.writeInt(u32, command[6..10], y, .little);
    std.mem.writeInt(u32, command[10..14], width, .little);
    std.mem.writeInt(u32, command[14..18], height, .little);
    return command;
}

pub fn setColorModeCommand(mode: u8) [3]u8 {
    return .{ ESC, 0x43, mode };
}

pub fn setDataFormatCommand(bits: u8) [3]u8 {
    return .{ ESC, 0x44, bits };
}

pub fn setSourceCommand(source: u8, enable: bool) [4]u8 {
    return .{ ESC, 0x65, if (enable) 0x01 else 0x00, source };
}

pub fn startScanCommand() [2]u8 {
    return .{ ESC, 0x47 };
}

pub fn readScanParametersCommand() [2]u8 {
    return .{ FS, 0x53 };
}

pub fn setScanningParametersCommand() [2]u8 {
    return .{ FS, 0x57 };
}

pub fn startExtendedScanCommand() [2]u8 {
    return .{ FS, 0x47 };
}

pub fn ackCommand() [1]u8 {
    return .{ACK};
}

pub fn cancelCommand() [1]u8 {
    return .{CAN};
}

pub fn rsCommandPrefix(subcommand: u8) [2]u8 {
    return .{ RS, subcommand };
}

pub fn registerWriteCommand() [2]u8 {
    return rsCommandPrefix(0x84);
}

pub fn identityGammaTable() [256]u8 {
    var table: [256]u8 = undefined;
    for (&table, 0..) |*byte, i| byte.* = @intCast(i);
    return table;
}

pub fn buildInfraredChallenge(params: []const u8) Error![32]u8 {
    if (params.len < 32) return Error.InvalidChallengeInput;
    var out: [32]u8 = undefined;
    for (&out, 0..) |*byte, i| {
        byte.* = IrXorKey[i] ^ params[i];
    }
    return out;
}

pub fn buildSetScanningParameters(params: SetParameters) [64]u8 {
    var buf = [_]u8{0} ** 64;
    std.mem.writeInt(u32, buf[0..4], params.dpi, .little);
    std.mem.writeInt(u32, buf[4..8], params.dpi, .little);
    std.mem.writeInt(u32, buf[8..12], params.x, .little);
    std.mem.writeInt(u32, buf[12..16], params.y, .little);
    std.mem.writeInt(u32, buf[16..20], params.width, .little);
    std.mem.writeInt(u32, buf[20..24], params.height, .little);
    buf[24] = params.color_mode;
    buf[25] = params.depth;
    buf[26] = params.source;
    buf[27] = params.scan_mode;
    buf[28] = params.block_lines;
    buf[29] = params.gamma;
    return buf;
}

pub fn gammaRegisterHeader(table_id: u8) [8]u8 {
    return .{ 0x03, 0x00, table_id, 0x1f, 0x02, 0x00, 0x01, 0x00 };
}

pub fn tpuGainShadingHeader() [8]u8 {
    return gain_shading_header;
}

pub fn tpuGainShadingData() [256]u8 {
    return gain_shading_data;
}

pub fn parseExtendedIdentity(resp: []const u8) Error!ExtendedIdentity {
    if (resp.len < 80) return Error.InvalidExtendedIdentityResponse;
    var model: [16]u8 = undefined;
    @memcpy(model[0..], resp[46..62]);
    return .{
        .command_level_major = resp[0],
        .command_level_minor = resp[1],
        .optical_dpi = std.mem.readInt(u32, resp[4..8], .little),
        .min_dpi = std.mem.readInt(u32, resp[8..12], .little),
        .max_dpi = std.mem.readInt(u32, resp[12..16], .little),
        .max_pixels = std.mem.readInt(u32, resp[16..20], .little),
        .flatbed_width = std.mem.readInt(u32, resp[20..24], .little),
        .flatbed_height = std.mem.readInt(u32, resp[24..28], .little),
        .tpu_width = std.mem.readInt(u32, resp[36..40], .little),
        .tpu_height = std.mem.readInt(u32, resp[40..44], .little),
        .capabilities = resp[44],
        .model = model,
        .input_depth = resp[66],
        .max_output_depth = resp[67],
    };
}

pub fn parseStartScanResponse(resp: []const u8) Error!StartScanInfo {
    if (resp.len < 14 or resp[0] != 0x02) return Error.InvalidStartScanResponse;
    const status = resp[1];
    if ((status & 0x80) != 0) return Error.FatalScannerStatus;
    if ((status & 0x40) != 0) return Error.ScannerNotReady;
    return .{
        .status = status,
        .block_size = std.mem.readInt(u32, resp[2..6], .little),
        .block_count = std.mem.readInt(u32, resp[6..10], .little),
        .last_block_size = std.mem.readInt(u32, resp[10..14], .little),
    };
}

test "builds basic ESC and FS commands from Python command fixtures" {
    const reset = resetCommand();
    try expectFixtureCommand("reset", &reset);
    const identity = identityCommand();
    try expectFixtureCommand("identity", &identity);
    const status = statusCommand();
    try expectFixtureCommand("status", &status);
    const extended_status = extendedStatusCommand();
    try expectFixtureCommand("extended_status", &extended_status);
    const extended_identity = extendedIdentityCommand();
    try expectFixtureCommand("extended_identity", &extended_identity);
    const set_resolution = setResolutionCommand(3200);
    try expectFixtureCommand("set_resolution_3200", &set_resolution);
    const set_area = setScanAreaCommand(320, 640, 4800, 6400);
    try expectFixtureCommand("set_scan_area_320_640_4800_6400", &set_area);
    const color_mode = setColorModeCommand(0x13);
    try expectFixtureCommand("set_color_mode_rgb_byte_seq", &color_mode);
    const data_format = setDataFormatCommand(16);
    try expectFixtureCommand("set_data_format_16", &data_format);
    const source = setSourceCommand(1, true);
    try expectFixtureCommand("set_source_tpu_enabled", &source);
    const start = startScanCommand();
    try expectFixtureCommand("start_scan", &start);
    const read_params = readScanParametersCommand();
    try expectFixtureCommand("read_scan_parameters", &read_params);
    const set_params = setScanningParametersCommand();
    try expectFixtureCommand("set_scanning_parameters", &set_params);
    const start_extended = startExtendedScanCommand();
    try expectFixtureCommand("start_extended_scan", &start_extended);
    const ack = ackCommand();
    try expectFixtureCommand("ack", &ack);
    const cancel = cancelCommand();
    try expectFixtureCommand("cancel", &cancel);
}

test "builds FS W parameter block exactly like Python backend" {
    const buf = buildSetScanningParameters(.{
        .dpi = 3200,
        .x = 320,
        .y = 640,
        .width = 4800,
        .height = 6400,
        .color_mode = 0x13,
        .depth = 16,
        .source = 1,
    });
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x0c, 0x00, 0x00 }, buf[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 0x01, 0x00, 0x00 }, buf[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 0xc0, 0x12, 0x00, 0x00 }, buf[16..20]);
    try std.testing.expectEqual(@as(u8, 0x13), buf[24]);
    try std.testing.expectEqual(@as(u8, 16), buf[25]);
    try std.testing.expectEqual(@as(u8, 1), buf[26]);
    try std.testing.expectEqual(@as(u8, 0x03), buf[29]);
}

test "builds IR challenge by XORing first 32 parameter bytes" {
    var params: [64]u8 = undefined;
    for (&params, 0..) |*byte, i| byte.* = @intCast(i);
    const challenge = try buildInfraredChallenge(&params);
    try std.testing.expectEqual(IrXorKey[0] ^ 0, challenge[0]);
    try std.testing.expectEqual(IrXorKey[31] ^ 31, challenge[31]);
}

test "exposes captured TPU RS calibration sequence" {
    try std.testing.expectEqual(@as(u8, 0xa2), tpu_calibration_sequence[0].subcommand);
    try std.testing.expectEqualSlices(u8, &.{0x02}, tpu_calibration_sequence[0].data);
    try std.testing.expectEqual(@as(u8, 0x31), tpu_calibration_sequence[4].subcommand);
    try std.testing.expectEqual(@as(usize, 12), tpu_calibration_sequence[4].data.len);
    try std.testing.expectEqual(@as(u8, 0x05), tpu_calibration_sequence[tpu_calibration_sequence.len - 1].subcommand);
}

test "models full TPU calibration program including gain shading register write" {
    try expectFixtureContains("test/fixtures/scanner/interpreter/tpu-calibration-program.txt", "gain_shading command=1e 84");
    try std.testing.expectEqual(@as(usize, 13), tpu_calibration_program.len);
    switch (tpu_calibration_program[6]) {
        .register_write => |write| {
            try std.testing.expectEqualSlices(u8, &.{ 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00 }, write.header);
            try std.testing.expectEqual(@as(usize, 256), write.data.len);
            try std.testing.expectEqualSlices(u8, &.{
                0x00, 0x00, 0x00, 0x00,
                0x28, 0x00, 0xc0, 0x39,
                0xc8, 0x00, 0xc0, 0x39,
                0x90, 0x01, 0x00, 0x10,
            }, write.data[0..16]);
            try std.testing.expectEqual(@as(u8, 0xff), write.data[16]);
            try std.testing.expectEqual(@as(u8, 0xff), write.data[255]);
        },
        else => return error.ExpectedRegisterWrite,
    }
}

test "builds gamma register headers for R G B tables" {
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x00, 0xfc, 0x1f, 0x02, 0x00, 0x01, 0x00 }, &gammaRegisterHeader(0xfc));
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x00, 0xfd, 0x1f, 0x02, 0x00, 0x01, 0x00 }, &gammaRegisterHeader(0xfd));
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x00, 0xfe, 0x1f, 0x02, 0x00, 0x01, 0x00 }, &gammaRegisterHeader(0xfe));
}

test "builds identity gamma table for interpreter register upload" {
    const table = identityGammaTable();
    try std.testing.expectEqual(@as(u8, 0), table[0]);
    try std.testing.expectEqual(@as(u8, 127), table[127]);
    try std.testing.expectEqual(@as(u8, 255), table[255]);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x00, 0xfc, 0x1f, 0x02, 0x00, 0x01, 0x00 }, &gammaRegisterHeader(0xfc));
}

test "parses FS I extended identity into scanner capability fields" {
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

    const identity = try parseExtendedIdentity(&resp);
    try std.testing.expectEqual(@as(u8, '2'), identity.command_level_major);
    try std.testing.expectEqual(@as(u32, 6400), identity.optical_dpi);
    try std.testing.expectEqual(@as(u32, 17280), identity.tpu_width);
    try std.testing.expect(identity.irSupported());
    try std.testing.expectEqualStrings("GT-X820", identity.modelName());
    try std.testing.expectEqual(@as(u8, 16), identity.max_output_depth);
    try std.testing.expectError(Error.InvalidExtendedIdentityResponse, parseExtendedIdentity(resp[0..79]));
}

test "parses FS G start scan response" {
    const resp = [_]u8{
        0x02, 0x00,
        0x00, 0x10,
        0x00, 0x00,
        0x03, 0x00,
        0x00, 0x00,
        0x80, 0x00,
        0x00, 0x00,
    };
    const info = try parseStartScanResponse(&resp);
    try std.testing.expectEqual(@as(u32, 4096), info.block_size);
    try std.testing.expectEqual(@as(u32, 3), info.block_count);
    try std.testing.expectEqual(@as(u32, 128), info.last_block_size);
}

fn expectFixtureCommand(name: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const fixture = try readFixture(allocator, "test/fixtures/scanner/interpreter/basic-commands.hex");
    defer allocator.free(fixture);
    const prefix = try std.fmt.allocPrint(allocator, "{s}=", .{name});
    defer allocator.free(prefix);

    var lines = std.mem.splitScalar(u8, fixture, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const parsed = try parseHexBytes(allocator, line[prefix.len..]);
        defer allocator.free(parsed);
        try std.testing.expectEqualSlices(u8, expected, parsed);
        return;
    }
    return error.MissingFixtureCommand;
}

fn expectFixtureContains(path: []const u8, needle: []const u8) !void {
    const allocator = std.testing.allocator;
    const fixture = try readFixture(allocator, path);
    defer allocator.free(fixture);
    try std.testing.expect(std.mem.indexOf(u8, fixture, needle) != null);
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8192));
}

fn parseHexBytes(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var bytes = std.array_list.Managed(u8).init(allocator);
    errdefer bytes.deinit();

    var high_nibble: ?u8 = null;
    for (text) |ch| {
        if (std.ascii.isWhitespace(ch)) continue;
        const nibble = hexNibble(ch) orelse return error.InvalidHexFixture;
        if (high_nibble) |high| {
            try bytes.append((high << 4) | nibble);
            high_nibble = null;
        } else {
            high_nibble = nibble;
        }
    }
    if (high_nibble != null) return error.InvalidHexFixture;
    return bytes.toOwnedSlice();
}

fn hexNibble(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

fn trimModelName(model: []const u8) []const u8 {
    var end = model.len;
    while (end > 0 and (model[end - 1] == 0 or model[end - 1] == ' ')) end -= 1;
    return model[0..end];
}
