const std = @import("std");

const film_stocks = @import("film_stocks.zig");
const measurement = @import("measurement.zig");
const numeric = @import("numeric_fixture.zig");
const render = @import("render.zig");

pub const InvertOptions = struct {
    dmin: ?[3]f64 = null,
    coeffs: ?film_stocks.Coefficients = null,
    stock: []const u8 = "kodak_gold",
    dark_rgb: ?[3]f64 = null,
    light_rgb: ?[3]f64 = null,
    default_light: f64 = 65535.0,
    rebate_mask: ?[]const bool = null,
    dmin_percentile: f64 = 1.0,
};

pub const InvertResult = struct {
    dmin: [3]f64,
};

pub fn computeDmin(
    allocator: std.mem.Allocator,
    raw_rgb: []const f64,
    rebate_mask: ?[]const bool,
    options: measurement.NormalizeOptions,
) ![3]f64 {
    const transmittance = try allocator.alloc(f64, raw_rgb.len);
    defer allocator.free(transmittance);
    try measurement.normalizeTransmittance(raw_rgb, transmittance, options);

    const density = try allocator.alloc(f64, raw_rgb.len);
    defer allocator.free(density);
    try measurement.transmittanceToDensity(transmittance, density);
    return measurement.estimateDmin(allocator, density, rebate_mask, 1.0);
}

pub fn invertNegative(
    allocator: std.mem.Allocator,
    raw_rgb: []const f64,
    output: []f64,
    options: InvertOptions,
) !InvertResult {
    if (raw_rgb.len != output.len) return error.InvalidInversionBuffer;

    const coeffs = if (options.coeffs) |coeffs|
        coeffs
    else if (film_stocks.builtinStock(options.stock)) |stock|
        stock.coeffs
    else
        return error.UnknownFilmStock;

    const transmittance = try allocator.alloc(f64, raw_rgb.len);
    defer allocator.free(transmittance);
    try measurement.normalizeTransmittance(raw_rgb, transmittance, .{
        .dark_rgb = options.dark_rgb,
        .light_rgb = options.light_rgb,
        .default_light = options.default_light,
    });

    const density = try allocator.alloc(f64, raw_rgb.len);
    defer allocator.free(density);
    try measurement.transmittanceToDensity(transmittance, density);

    const dmin = options.dmin orelse try measurement.estimateDmin(
        allocator,
        density,
        options.rebate_mask,
        options.dmin_percentile,
    );

    const net_density = try allocator.alloc(f64, raw_rgb.len);
    defer allocator.free(net_density);
    try measurement.subtractDmin(density, net_density, dmin);
    try film_stocks.applyDensityTransform(net_density, output, coeffs);
    for (output) |*value| {
        value.* = @max(value.*, 0.0);
    }

    return .{ .dmin = dmin };
}

fn expectInversionFixture(path: []const u8, coeffs: film_stocks.Coefficients) !void {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, path);
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    const result = try invertNegative(allocator, value.input, actual, .{
        .dmin = .{ 0.2, 0.1, 0.05 },
        .coeffs = coeffs,
    });
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
    try std.testing.expectApproxEqAbs(0.2, result.dmin[0], 0.0);
    try std.testing.expectApproxEqAbs(0.1, result.dmin[1], 0.0);
    try std.testing.expectApproxEqAbs(0.05, result.dmin[2], 0.0);
}

test "inverts negative with provided Dmin and identity coefficients" {
    try expectInversionFixture(
        "test/fixtures/processing/numeric/invert-negative-identity-dmin.json",
        film_stocks.identity_coeffs,
    );
}

test "inverts negative with provided Dmin and Kodak Gold coefficients" {
    try expectInversionFixture(
        "test/fixtures/processing/numeric/invert-negative-kodak-gold-dmin.json",
        film_stocks.kodak_gold_coeffs,
    );
}

test "computeDmin composes Python measurement pipeline" {
    const allocator = std.testing.allocator;
    const raw = [_]f64{
        65535.0, 32768.0, 16384.0,
        32768.0, 16384.0, 8192.0,
    };
    const dmin = try computeDmin(allocator, &raw, null, .{});
    try std.testing.expectApproxEqAbs(0.0030102336880553178, dmin[0], 0.000002);
    try std.testing.expectApproxEqAbs(0.30403351178932945, dmin[1], 0.000002);
    try std.testing.expectApproxEqAbs(0.6050626465457164, dmin[2], 0.000002);
}

test "inversion resolves built-in stock by name" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/invert-negative-kodak-gold-dmin.json");
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    _ = try invertNegative(allocator, value.input, actual, .{
        .dmin = .{ 0.2, 0.1, 0.05 },
        .stock = "kodak_gold",
    });
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "inversion rejects unknown stock and mismatched buffers" {
    var out: [3]f64 = undefined;
    try std.testing.expectError(error.UnknownFilmStock, invertNegative(std.testing.allocator, &.{ 1.0, 2.0, 3.0 }, &out, .{ .stock = "missing" }));
    try std.testing.expectError(error.InvalidInversionBuffer, invertNegative(std.testing.allocator, &.{ 1.0, 2.0, 3.0 }, out[0..2], .{}));
}

test "real scan crop matches Python negative-to-positive pipeline" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(
        allocator,
        std.testing.io,
        "test/fixtures/processing/numeric/real-scan-negative-to-positive-scan-0006-crop.json",
    );
    defer fixture.deinit();

    const value = fixture.value();
    const scene_linear = try allocator.alloc(f64, value.input.len);
    defer allocator.free(scene_linear);
    const inversion = try invertNegative(allocator, value.input, scene_linear, .{
        .stock = "kodak_gold",
    });
    try std.testing.expectApproxEqAbs(0.3229871988296509, inversion.dmin[0], 0.0000005);
    try std.testing.expectApproxEqAbs(0.48254984617233276, inversion.dmin[1], 0.0000005);
    try std.testing.expectApproxEqAbs(0.6367867588996887, inversion.dmin[2], 0.0000005);

    const actual_u16 = try allocator.alloc(u16, value.expected.len);
    defer allocator.free(actual_u16);
    try render.renderToDisplay(allocator, scene_linear, actual_u16, .{
        .contrast = 1.4,
        .curve_k = 5.0,
        .percentile_lo = 0.5,
        .percentile_hi = 99.5,
        .exposure_compensation = 0.0,
        .color_temp = 0.0,
        .color_tint = 0.0,
    });

    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    for (actual_u16, actual) |sample, *out| {
        out.* = @floatFromInt(sample);
    }
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}
