const std = @import("std");

const c = @cImport({
    @cInclude("zlib.h");
});

pub const NegadoctorParams = struct {
    film_stock: i32,
    dmin: [3]f64,
    wb_high: [3]f64,
    wb_low: [3]f64,
    d_max: f64,
    offset: f64,
    black: f64,
    gamma: f64,
    soft_clip: f64,
    exposure: f64,
};

pub const SigmoidParams = struct {
    middle_grey_contrast: f64,
    contrast_skewness: f64,
    display_white_target: f64,
    display_black_target: f64,
    color_processing: i32,
    hue_preservation: f64,
};

pub const ChannelMixerParams = struct {
    scene_x: f64,
    scene_y: f64,
    temperature: f64,
    matrix: [3][3]f64,
};

pub fn parseNegadoctorParams(params_hex: []const u8) !NegadoctorParams {
    var bytes: [76]u8 = undefined;
    const decoded = try std.fmt.hexToBytes(&bytes, params_hex);
    if (decoded.len != bytes.len) return error.InvalidNegadoctorParams;

    return .{
        .film_stock = readI32(&bytes, 0),
        .dmin = .{ readF32(&bytes, 1), readF32(&bytes, 2), readF32(&bytes, 3) },
        .wb_high = .{ readF32(&bytes, 5), readF32(&bytes, 6), readF32(&bytes, 7) },
        .wb_low = .{ readF32(&bytes, 9), readF32(&bytes, 10), readF32(&bytes, 11) },
        .d_max = readF32(&bytes, 13),
        .offset = readF32(&bytes, 14),
        .black = readF32(&bytes, 15),
        .gamma = readF32(&bytes, 16),
        .soft_clip = readF32(&bytes, 17),
        .exposure = readF32(&bytes, 18),
    };
}

pub fn extractNegadoctorFromText(text: []const u8) !?NegadoctorParams {
    const params = findLastEnabledParams(text, "negadoctor") orelse return null;
    return try parseNegadoctorParams(params);
}

pub fn extractNegadoctorFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?NegadoctorParams {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024));
    defer allocator.free(text);
    return try extractNegadoctorFromText(text);
}

pub fn parseSigmoidParams(params_hex: []const u8) !SigmoidParams {
    var bytes: [56]u8 = undefined;
    const decoded = try std.fmt.hexToBytes(&bytes, params_hex);
    if (decoded.len != bytes.len) return error.InvalidSigmoidParams;

    return .{
        .middle_grey_contrast = readF32(&bytes, 0),
        .contrast_skewness = readF32(&bytes, 1),
        .display_white_target = readF32(&bytes, 2) * 0.01,
        .display_black_target = readF32(&bytes, 3) * 0.01,
        .color_processing = readI32(&bytes, 4),
        .hue_preservation = std.math.clamp(readF32(&bytes, 5) * 0.01, 0.0, 1.0),
    };
}

pub fn extractSigmoidFromText(text: []const u8) !?SigmoidParams {
    const params = findLastEnabledParams(text, "sigmoid") orelse return null;
    return try parseSigmoidParams(params);
}

pub fn extractSigmoidFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?SigmoidParams {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024));
    defer allocator.free(text);
    return try extractSigmoidFromText(text);
}

pub fn parseChannelMixerParams(allocator: std.mem.Allocator, params: []const u8) !ChannelMixerParams {
    if (params.len <= 4 or !std.mem.startsWith(u8, params, "gz")) return error.InvalidChannelMixerParams;

    const decoded = try decodeDarktableZlibBase64(allocator, params[4..]);
    defer allocator.free(decoded);
    const raw = try zlibDecompress(allocator, decoded);
    defer allocator.free(raw);
    if (raw.len < 37 * 4) return error.InvalidChannelMixerParams;

    const scene_x = readF32(raw, 34);
    const scene_y = readF32(raw, 35);
    const temperature = readF32(raw, 36);
    return .{
        .scene_x = scene_x,
        .scene_y = scene_y,
        .temperature = temperature,
        .matrix = computeCat16Matrix(scene_x, scene_y),
    };
}

pub fn extractChannelMixerFromText(allocator: std.mem.Allocator, text: []const u8) !?ChannelMixerParams {
    const params = findLastEnabledParams(text, "channelmixerrgb") orelse return null;
    return try parseChannelMixerParams(allocator, params);
}

pub fn extractChannelMixerFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?ChannelMixerParams {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024));
    defer allocator.free(text);
    return try extractChannelMixerFromText(allocator, text);
}

pub fn computeCat16Matrix(scene_x: f64, scene_y: f64) [3][3]f64 {
    const m_cat16: [3][3]f64 = .{
        .{ 0.401288, 0.650173, -0.051461 },
        .{ -0.250268, 1.204414, 0.045854 },
        .{ -0.002079, 0.048952, 0.953127 },
    };
    const m_rec2020_to_xyz_d65: [3][3]f64 = .{
        .{ 0.6369580, 0.1446169, 0.1688810 },
        .{ 0.2627002, 0.6779981, 0.0593017 },
        .{ 0.0000000, 0.0280727, 1.0609851 },
    };
    const m_bradford: [3][3]f64 = .{
        .{ 0.8951, 0.2664, -0.1614 },
        .{ -0.7502, 1.7135, 0.0367 },
        .{ 0.0389, -0.0685, 1.0296 },
    };

    const scene_xyz = xyToXyz(scene_x, scene_y);
    const d50_xyz = xyToXyz(0.3457, 0.3585);
    const scene_lms = matVec(m_cat16, scene_xyz);
    const d50_lms = matVec(m_cat16, d50_xyz);

    const d65_xyz: [3]f64 = .{ 0.95047, 1.0, 1.08883 };
    const d50_xyz_ref: [3]f64 = .{ 0.96429568, 1.0, 0.82510460 };
    const d65_lms = matVec(m_bradford, d65_xyz);
    const d50_lms_ref = matVec(m_bradford, d50_xyz_ref);
    const brad_gains: [3]f64 = .{
        d50_lms_ref[0] / d65_lms[0],
        d50_lms_ref[1] / d65_lms[1],
        d50_lms_ref[2] / d65_lms[2],
    };
    const m_d65_to_d50 = matMul(matMul(matInv3(m_bradford), diag(brad_gains)), m_bradford);
    const m_rec2020_to_xyz_d50 = matMul(m_d65_to_d50, m_rec2020_to_xyz_d65);
    const m_xyz_d50_to_rec2020 = matInv3(m_rec2020_to_xyz_d50);

    const gains: [3]f64 = .{
        scene_lms[0] / d50_lms[0],
        scene_lms[1] / d50_lms[1],
        scene_lms[2] / d50_lms[2],
    };
    const m_adapt_xyz = matMul(matMul(matInv3(m_cat16), diag(gains)), m_cat16);
    return matMul(matMul(m_xyz_d50_to_rec2020, m_adapt_xyz), m_rec2020_to_xyz_d50);
}

fn decodeDarktableZlibBase64(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const padding = if (input.len % 4 == 0) 0 else 4 - (input.len % 4);
    const source = if (padding == 0) input else blk: {
        const padded = try allocator.alloc(u8, input.len + padding);
        @memcpy(padded[0..input.len], input);
        @memset(padded[input.len..], '=');
        break :blk padded;
    };
    defer if (padding != 0) allocator.free(source);

    const size = std.base64.standard.Decoder.calcSizeForSlice(source) catch return error.InvalidChannelMixerParams;
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, source) catch return error.InvalidChannelMixerParams;
    return decoded;
}

fn zlibDecompress(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var capacity = @max(compressed.len * 4, @as(usize, 256));
    while (capacity <= 1024 * 1024) : (capacity *= 2) {
        const out = try allocator.alloc(u8, capacity);
        var out_len: c.uLongf = @intCast(out.len);
        const result = c.uncompress(out.ptr, &out_len, compressed.ptr, @intCast(compressed.len));
        if (result == c.Z_OK) {
            return try allocator.realloc(out, @intCast(out_len));
        }
        allocator.free(out);
        if (result != c.Z_BUF_ERROR) return error.InvalidChannelMixerParams;
    }
    return error.InvalidChannelMixerParams;
}

fn readI32(bytes: []const u8, index: usize) i32 {
    const offset = index * 4;
    return std.mem.readInt(i32, bytes[offset..][0..4], .little);
}

fn readF32(bytes: []const u8, index: usize) f64 {
    const offset = index * 4;
    const raw = std.mem.readInt(u32, bytes[offset..][0..4], .little);
    const value: f32 = @bitCast(raw);
    return @floatCast(value);
}

fn findLastEnabledParams(text: []const u8, operation: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    var last: ?[]const u8 = null;
    while (std.mem.indexOf(u8, text[cursor..], "<rdf:li")) |start_rel| {
        const start = cursor + start_rel;
        const end_rel = std.mem.indexOfScalar(u8, text[start..], '>') orelse break;
        const tag = text[start .. start + end_rel + 1];
        cursor = start + end_rel + 1;

        const op = attribute(tag, "darktable:operation") orelse continue;
        const enabled = attribute(tag, "darktable:enabled") orelse continue;
        if (!std.mem.eql(u8, op, operation) or !std.mem.eql(u8, enabled, "1")) continue;
        last = attribute(tag, "darktable:params");
    }
    return last;
}

fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, tag, name) orelse return null;
    const equals = start + name.len;
    if (equals + 1 >= tag.len or tag[equals] != '=' or tag[equals + 1] != '"') return null;
    const value_start = equals + 2;
    const end_rel = std.mem.indexOfScalar(u8, tag[value_start..], '"') orelse return null;
    return tag[value_start .. value_start + end_rel];
}

fn xyToXyz(x: f64, y: f64) [3]f64 {
    return .{ x / y, 1.0, (1.0 - x - y) / y };
}

fn matVec(matrix: [3][3]f64, vector: [3]f64) [3]f64 {
    return .{
        matrix[0][0] * vector[0] + matrix[0][1] * vector[1] + matrix[0][2] * vector[2],
        matrix[1][0] * vector[0] + matrix[1][1] * vector[1] + matrix[1][2] * vector[2],
        matrix[2][0] * vector[0] + matrix[2][1] * vector[1] + matrix[2][2] * vector[2],
    };
}

fn matMul(a: [3][3]f64, b: [3][3]f64) [3][3]f64 {
    var out: [3][3]f64 = undefined;
    for (0..3) |row| {
        for (0..3) |col| {
            out[row][col] = a[row][0] * b[0][col] + a[row][1] * b[1][col] + a[row][2] * b[2][col];
        }
    }
    return out;
}

fn diag(values: [3]f64) [3][3]f64 {
    return .{
        .{ values[0], 0.0, 0.0 },
        .{ 0.0, values[1], 0.0 },
        .{ 0.0, 0.0, values[2] },
    };
}

fn matInv3(m: [3][3]f64) [3][3]f64 {
    const det =
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
        m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
        m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    const inv_det = 1.0 / det;
    return .{
        .{
            (m[1][1] * m[2][2] - m[1][2] * m[2][1]) * inv_det,
            (m[0][2] * m[2][1] - m[0][1] * m[2][2]) * inv_det,
            (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * inv_det,
        },
        .{
            (m[1][2] * m[2][0] - m[1][0] * m[2][2]) * inv_det,
            (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * inv_det,
            (m[0][2] * m[1][0] - m[0][0] * m[1][2]) * inv_det,
        },
        .{
            (m[1][0] * m[2][1] - m[1][1] * m[2][0]) * inv_det,
            (m[0][1] * m[2][0] - m[0][0] * m[2][1]) * inv_det,
            (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * inv_det,
        },
    };
}

fn expectApprox(expected: f64, actual: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.000001);
}

test "decodes negadoctor params from darktable hex layout" {
    const params = try parseNegadoctorParams("01000000ae47e13dae47613ec3f5a83eae47e13ecdcc8c3f9a99993f6666a63f3333b33f0ad7233c0ad7a33c8fc2f53c0ad7233d000020400000003e8fc2753c9a99d93f9a99593f0000a03f");
    try std.testing.expectEqual(@as(i32, 1), params.film_stock);
    try expectApprox(0.11, params.dmin[0]);
    try expectApprox(0.22, params.dmin[1]);
    try expectApprox(0.33, params.dmin[2]);
    try expectApprox(1.10, params.wb_high[0]);
    try expectApprox(1.20, params.wb_high[1]);
    try expectApprox(1.30, params.wb_high[2]);
    try expectApprox(0.01, params.wb_low[0]);
    try expectApprox(0.02, params.wb_low[1]);
    try expectApprox(0.03, params.wb_low[2]);
    try expectApprox(2.5, params.d_max);
    try expectApprox(0.125, params.offset);
    try expectApprox(0.015, params.black);
    try expectApprox(1.7, params.gamma);
    try expectApprox(0.85, params.soft_clip);
    try expectApprox(1.25, params.exposure);
}

test "decodes sigmoid params with Python scaling and clamping" {
    const params = try parseSigmoidParams("0000c03f000080be0000fa430000c03f02000000000082420000e0400000004100001041000020410000304100004041000050410e000000");
    try expectApprox(1.5, params.middle_grey_contrast);
    try expectApprox(-0.25, params.contrast_skewness);
    try expectApprox(5.0, params.display_white_target);
    try expectApprox(0.015, params.display_black_target);
    try std.testing.expectEqual(@as(i32, 2), params.color_processing);
    try expectApprox(0.65, params.hue_preservation);
}

test "extracts last enabled negadoctor, sigmoid, and channel mixer from XMP sidecar" {
    const allocator = std.testing.allocator;
    const xmp = try readFixture(allocator, "test/fixtures/processing/xmp/darktable-negadoctor-sigmoid.xmp");
    defer allocator.free(xmp);

    const neg = (try extractNegadoctorFromText(xmp)).?;
    try std.testing.expectEqual(@as(i32, 1), neg.film_stock);
    try expectApprox(0.11, neg.dmin[0]);
    try expectApprox(1.25, neg.exposure);

    const sigmoid = (try extractSigmoidFromText(xmp)).?;
    try expectApprox(1.5, sigmoid.middle_grey_contrast);
    try expectApprox(0.65, sigmoid.hue_preservation);

    const channel_mixer = (try extractChannelMixerFromText(allocator, xmp)).?;
    try expectApprox(0.3127, channel_mixer.scene_x);
    try expectApprox(0.3290, channel_mixer.scene_y);
    try expectApprox(6500.0, channel_mixer.temperature);
    try expectApprox(0.969682809432, channel_mixer.matrix[0][0]);
    try expectApprox(-0.051151409024, channel_mixer.matrix[0][1]);
    try expectApprox(-0.003614232499, channel_mixer.matrix[0][2]);
    try expectApprox(0.009639250939, channel_mixer.matrix[1][0]);
    try expectApprox(1.024839161911, channel_mixer.matrix[1][1]);
    try expectApprox(-0.021652049572, channel_mixer.matrix[1][2]);
    try expectApprox(0.003768253457, channel_mixer.matrix[2][0]);
    try expectApprox(0.022988902596, channel_mixer.matrix[2][1]);
    try expectApprox(1.303707082256, channel_mixer.matrix[2][2]);
}

test "returns null for missing enabled XMP modules and errors on malformed params" {
    const allocator = std.testing.allocator;
    const xmp = try readFixture(allocator, "test/fixtures/processing/xmp/missing-modules.xmp");
    defer allocator.free(xmp);
    try std.testing.expect((try extractNegadoctorFromText(xmp)) == null);
    try std.testing.expect((try extractSigmoidFromText(xmp)) == null);
    try std.testing.expect((try extractChannelMixerFromText(allocator, xmp)) == null);
    try std.testing.expectError(error.InvalidNegadoctorParams, parseNegadoctorParams("0000"));
    try std.testing.expectError(error.InvalidChannelMixerParams, parseChannelMixerParams(allocator, "gz01bad"));
}

test "computes CAT16 matrix from channel mixer scene illuminant" {
    const matrix = computeCat16Matrix(0.3127, 0.3290);
    try expectApprox(0.969682809432, matrix[0][0]);
    try expectApprox(-0.051151409024, matrix[0][1]);
    try expectApprox(-0.003614232499, matrix[0][2]);
    try expectApprox(0.009639250939, matrix[1][0]);
    try expectApprox(1.024839161911, matrix[1][1]);
    try expectApprox(-0.021652049572, matrix[1][2]);
    try expectApprox(0.003768253457, matrix[2][0]);
    try expectApprox(0.022988902596, matrix[2][1]);
    try expectApprox(1.303707082256, matrix[2][2]);
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024));
}
