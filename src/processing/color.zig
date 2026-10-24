const std = @import("std");

const numeric = @import("numeric_fixture.zig");
const webgpu = @import("webgpu.zig");

pub const middle_grey: f64 = 0.1845;

pub const m_srgb_to_rec2020_d50: [3][3]f64 = .{
    .{ 0.62750372, 0.32927550, 0.04330266 },
    .{ 0.06910838, 0.91951916, 0.01135963 },
    .{ 0.01639405, 0.08801124, 0.89538034 },
};

pub const DarktableSigmoidParams = struct {
    middle_grey_contrast: f64,
    contrast_skewness: f64,
    display_white_target: f64,
    display_black_target: f64,
    color_processing: i32 = 0,
    hue_preservation: f64 = 0.0,
};

pub const DarktableSigmoidCommit = struct {
    white_target: f64,
    black_target: f64,
    paper_exposure: f64,
    film_fog: f64,
    film_power: f64,
    paper_power: f64,
};

pub const ApplySigmoidOptions = struct {
    request: webgpu.Request = .{},
};

pub fn srgbToLinearValue(value: f64) f64 {
    if (value <= 0.04045) return value / 12.92;
    return std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
}

pub fn linearToSrgbValue(value: f64) f64 {
    const clamped = @max(value, 0.0);
    if (clamped <= 0.0031308) return clamped * 12.92;
    return 1.055 * std.math.pow(f64, clamped, 1.0 / 2.4) - 0.055;
}

pub fn applyColorMatrixPixel(rgb: [3]f64, matrix: [3][3]f64) [3]f64 {
    return .{
        matrix[0][0] * rgb[0] + matrix[0][1] * rgb[1] + matrix[0][2] * rgb[2],
        matrix[1][0] * rgb[0] + matrix[1][1] * rgb[1] + matrix[1][2] * rgb[2],
        matrix[2][0] * rgb[0] + matrix[2][1] * rgb[1] + matrix[2][2] * rgb[2],
    };
}

pub fn srgbToLinear(input: []const f64, output: []f64) !void {
    try validateRgbBuffers(input, output);
    for (input, output) |in_value, *out_value| {
        out_value.* = srgbToLinearValue(in_value);
    }
}

pub fn linearToSrgb(input: []const f64, output: []f64) !void {
    try validateRgbBuffers(input, output);
    for (input, output) |in_value, *out_value| {
        out_value.* = linearToSrgbValue(in_value);
    }
}

pub fn applyColorMatrix(input: []const f64, output: []f64, matrix: [3][3]f64) !void {
    try validateRgbBuffers(input, output);
    var index: usize = 0;
    while (index < input.len) : (index += 3) {
        const out = applyColorMatrixPixel(.{
            input[index],
            input[index + 1],
            input[index + 2],
        }, matrix);
        output[index] = out[0];
        output[index + 1] = out[1];
        output[index + 2] = out[2];
    }
}

pub fn generalizedLogLogisticSigmoidValue(
    value: f64,
    magnitude: f64,
    paper_exposure: f64,
    film_fog: f64,
    film_power: f64,
    paper_power: f64,
) f64 {
    const clamped = @max(value, 0.0);
    const film_response = std.math.pow(f64, film_fog + clamped, film_power);
    const ratio = film_response / (paper_exposure + film_response);
    const paper_response = magnitude * std.math.pow(f64, ratio, paper_power);
    if (std.math.isNan(paper_response)) return magnitude;
    return paper_response;
}

pub fn sigmoidCommitParams(params: DarktableSigmoidParams) DarktableSigmoidCommit {
    const ref_film_power = params.middle_grey_contrast;
    const ref_paper_power = 1.0;
    const ref_magnitude = 1.0;
    const ref_film_fog = 0.0;
    const ref_paper_exposure =
        std.math.pow(f64, ref_film_fog + middle_grey, ref_film_power) *
        ((ref_magnitude / middle_grey) - 1.0);

    const delta = 1e-6;
    const ref_slope = (generalizedLogLogisticSigmoidValue(
        middle_grey + delta,
        ref_magnitude,
        ref_paper_exposure,
        ref_film_fog,
        ref_film_power,
        ref_paper_power,
    ) - generalizedLogLogisticSigmoidValue(
        middle_grey - delta,
        ref_magnitude,
        ref_paper_exposure,
        ref_film_fog,
        ref_film_power,
        ref_paper_power,
    )) / (2.0 * delta);

    const paper_power = std.math.pow(f64, 5.0, -params.contrast_skewness);
    const white_target = params.display_white_target;
    const black_target = params.display_black_target;

    const temp_film_power = 1.0;
    const temp_white_grey_relation = std.math.pow(f64, white_target / middle_grey, 1.0 / paper_power) - 1.0;
    const temp_paper_exposure = std.math.pow(f64, middle_grey, temp_film_power) * temp_white_grey_relation;
    const temp_slope = (generalizedLogLogisticSigmoidValue(
        middle_grey + delta,
        white_target,
        temp_paper_exposure,
        ref_film_fog,
        temp_film_power,
        paper_power,
    ) - generalizedLogLogisticSigmoidValue(
        middle_grey - delta,
        white_target,
        temp_paper_exposure,
        ref_film_fog,
        temp_film_power,
        paper_power,
    )) / (2.0 * delta);

    const film_power = ref_slope / temp_slope;
    const white_grey_relation = std.math.pow(f64, white_target / middle_grey, 1.0 / paper_power) - 1.0;
    const white_black_relation = std.math.pow(f64, black_target / white_target, -1.0 / paper_power) - 1.0;
    const film_fog =
        middle_grey * std.math.pow(f64, white_grey_relation, 1.0 / film_power) /
        (std.math.pow(f64, white_black_relation, 1.0 / film_power) -
            std.math.pow(f64, white_grey_relation, 1.0 / film_power));
    const paper_exposure = std.math.pow(f64, film_fog + middle_grey, film_power) * white_grey_relation;

    return .{
        .white_target = white_target,
        .black_target = black_target,
        .paper_exposure = paper_exposure,
        .film_fog = film_fog,
        .film_power = film_power,
        .paper_power = paper_power,
    };
}

pub fn applySigmoid(input: []const f64, output: []f64, params: DarktableSigmoidParams) !void {
    try validateRgbBuffers(input, output);
    const committed = sigmoidCommitParams(params);
    for (input, output) |value, *out| {
        out.* = roundF32(generalizedLogLogisticSigmoidValue(
            roundF32(value),
            committed.white_target,
            committed.paper_exposure,
            committed.film_fog,
            committed.film_power,
            committed.paper_power,
        ));
    }
}

pub fn applySigmoidWithBackend(
    allocator: std.mem.Allocator,
    input: []const f64,
    output: []f64,
    params: DarktableSigmoidParams,
    options: ApplySigmoidOptions,
) !void {
    try validateRgbBuffers(input, output);
    if (try webgpu.shouldUseCpu(options.request)) {
        return applySigmoid(input, output, params);
    }
    const committed = sigmoidCommitParams(params);
    const gpu_output = try webgpu.applySigmoidKernel(allocator, input, .{
        .white_target = committed.white_target,
        .paper_exposure = committed.paper_exposure,
        .film_fog = committed.film_fog,
        .film_power = committed.film_power,
        .paper_power = committed.paper_power,
    }, .{});
    defer allocator.free(gpu_output);
    if (gpu_output.len != output.len) return error.InvalidColorBuffer;
    @memcpy(output, gpu_output);
}

fn validateRgbBuffers(input: []const f64, output: []const f64) !void {
    if (input.len != output.len) return error.InvalidColorBuffer;
    if (input.len % 3 != 0) return error.InvalidColorBuffer;
}

fn roundF32(value: f64) f64 {
    const rounded: f32 = @floatCast(value);
    return @floatCast(rounded);
}

pub fn applySigmoidRequestFromEnvironment(environ_map: *const std.process.Environ.Map) !webgpu.Request {
    return webgpu.requestFromEnvironment(environ_map);
}

fn expectMatrixFlat(matrix: [3][3]f64, expected: []const f64) !void {
    var actual: [9]f64 = undefined;
    var index: usize = 0;
    for (0..3) |row| {
        for (0..3) |col| {
            actual[index] = matrix[row][col];
            index += 1;
        }
    }
    const tolerance: numeric.Tolerance = .{ .abs = 0.0, .rel = 0.0, .reason = "constant equality" };
    try numeric.assertCloseSlices(expected, &actual, tolerance);
}

fn testSigmoidParams() DarktableSigmoidParams {
    return .{
        .middle_grey_contrast = 1.5,
        .contrast_skewness = -0.25,
        .display_white_target = 5.0,
        .display_black_target = 0.015,
        .color_processing = 2,
        .hue_preservation = 0.65,
    };
}

test "color matrix constants match Python oracle values" {
    try std.testing.expectApproxEqAbs(0.1845, middle_grey, 0.0);
    try expectMatrixFlat(m_srgb_to_rec2020_d50, &.{
        0.62750372, 0.3292755,  0.04330266,
        0.06910838, 0.91951916, 0.01135963,
        0.01639405, 0.08801124, 0.89538034,
    });
}

test "sRGB to linear matches Python fixture" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/srgb-to-linear.json");
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try srgbToLinear(value.input, actual);
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "linear to sRGB matches Python fixture" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/linear-to-srgb.json");
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try linearToSrgb(value.input, actual);
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "sRGB to Rec2020 matrix multiply matches Python fixture" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/srgb-to-rec2020-matrix.json");
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try applyColorMatrix(value.input, actual, m_srgb_to_rec2020_d50);
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "darktable sigmoid commit params match Python fixture" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/sigmoid-commit-params.json");
    defer fixture.deinit();

    const value = fixture.value();
    const committed = sigmoidCommitParams(.{
        .middle_grey_contrast = value.input[0],
        .contrast_skewness = value.input[1],
        .display_white_target = value.input[2],
        .display_black_target = value.input[3],
        .color_processing = @intFromFloat(value.input[4]),
        .hue_preservation = value.input[5],
    });
    const actual = [_]f64{
        committed.white_target,
        committed.black_target,
        committed.paper_exposure,
        committed.film_fog,
        committed.film_power,
        committed.paper_power,
    };
    try numeric.assertCloseSlices(value.expected, &actual, value.tolerance);
}

test "darktable sigmoid apply matches Python fixture" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/apply-darktable-sigmoid.json");
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try applySigmoid(value.input, actual, testSigmoidParams());
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "darktable sigmoid backend interface defaults to CPU parity path" {
    const input = [_]f64{ 0.0, 0.05, 0.1845, 0.75, 1.5, 3.0 };
    var expected: [input.len]f64 = undefined;
    var actual: [input.len]f64 = undefined;

    try std.testing.expectEqual(webgpu.Backend.cpu, (ApplySigmoidOptions{}).request.backend);
    try applySigmoid(&input, &expected, testSigmoidParams());
    try applySigmoidWithBackend(std.testing.allocator, &input, &actual, testSigmoidParams(), .{});
    try std.testing.expectEqualSlices(f64, &expected, &actual);
}

test "darktable sigmoid backend interface honors explicit CPU request" {
    const input = [_]f64{ -1.0, 0.01, 0.25, 0.5, 1.0, 2.0 };
    var expected: [input.len]f64 = undefined;
    var actual: [input.len]f64 = undefined;

    try applySigmoid(&input, &expected, testSigmoidParams());
    try applySigmoidWithBackend(
        std.testing.allocator,
        &input,
        &actual,
        testSigmoidParams(),
        .{ .request = .{ .backend = .cpu } },
    );
    try std.testing.expectEqualSlices(f64, &expected, &actual);
}

test "darktable sigmoid backend interface rejects unavailable WebGPU and runs compiled GPU" {
    const input = [_]f64{ 0.0, 0.1, 0.2 };
    var actual: [input.len]f64 = undefined;

    const result = applySigmoidWithBackend(
        std.testing.allocator,
        &input,
        &actual,
        testSigmoidParams(),
        .{ .request = .{ .backend = .webgpu } },
    );
    if (webgpu.compiled) {
        try result;
        var expected: [input.len]f64 = undefined;
        try applySigmoid(&input, &expected, testSigmoidParams());
        const tolerance: numeric.Tolerance = .{ .abs = 0.000002, .rel = 0.000002, .reason = "GPU f32 parity" };
        try numeric.assertCloseSlices(&expected, &actual, tolerance);
    } else {
        try std.testing.expectError(error.WebGpuNotCompiled, result);
    }
}

test "darktable sigmoid backend interface uses explicit CPU fallback only when WebGPU is not compiled" {
    const input = [_]f64{ 0.0, 0.05, 0.1845, 0.75, 1.5, 3.0 };
    var expected: [input.len]f64 = undefined;
    var actual: [input.len]f64 = undefined;

    const options = ApplySigmoidOptions{
        .request = .{ .backend = .webgpu, .fallback = .allow_cpu },
    };
    if (webgpu.compiled) {
        try applySigmoidWithBackend(std.testing.allocator, &input, &actual, testSigmoidParams(), options);
        try applySigmoid(&input, &expected, testSigmoidParams());
        const tolerance: numeric.Tolerance = .{ .abs = 0.000002, .rel = 0.000002, .reason = "GPU f32 parity" };
        try numeric.assertCloseSlices(&expected, &actual, tolerance);
    } else {
        try applySigmoid(&input, &expected, testSigmoidParams());
        try applySigmoidWithBackend(std.testing.allocator, &input, &actual, testSigmoidParams(), options);
        try std.testing.expectEqualSlices(f64, &expected, &actual);
    }
}

test "darktable sigmoid runtime request honors explicit processing GPU env" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectEqual(webgpu.Backend.cpu, (try applySigmoidRequestFromEnvironment(&env)).backend);
    try env.put(webgpu.processing_gpu_env_var, "0");
    try std.testing.expectEqual(webgpu.Backend.cpu, (try applySigmoidRequestFromEnvironment(&env)).backend);
    try env.put(webgpu.processing_gpu_env_var, "1");
    const webgpu_request = try applySigmoidRequestFromEnvironment(&env);
    try std.testing.expectEqual(webgpu.Backend.webgpu, webgpu_request.backend);
    try std.testing.expectEqual(webgpu.FallbackPolicy.fail, webgpu_request.fallback);

    try env.put(webgpu.processing_gpu_env_var, "allow-cpu");
    const fallback_request = try applySigmoidRequestFromEnvironment(&env);
    try std.testing.expectEqual(webgpu.Backend.webgpu, fallback_request.backend);
    try std.testing.expectEqual(webgpu.FallbackPolicy.allow_cpu, fallback_request.fallback);

    try env.put(webgpu.processing_gpu_env_var, "yes-please");
    try std.testing.expectError(error.InvalidProcessingGpuEnv, applySigmoidRequestFromEnvironment(&env));
}

test "color buffer helpers reject non-RGB flat buffers" {
    var out: [2]f64 = undefined;
    try std.testing.expectError(error.InvalidColorBuffer, srgbToLinear(&.{ 0.0, 1.0 }, &out));
}
