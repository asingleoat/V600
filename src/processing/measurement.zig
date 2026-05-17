const std = @import("std");

const numeric = @import("numeric_fixture.zig");

pub const eps: f64 = 1e-8;

pub const NormalizeOptions = struct {
    dark_rgb: ?[3]f64 = null,
    light_rgb: ?[3]f64 = null,
    default_light: f64 = 65535.0,
};

pub fn normalizeTransmittance(input: []const f64, output: []f64, options: NormalizeOptions) !void {
    try validateRgbBuffers(input, output);
    const dark = options.dark_rgb orelse .{ 0.0, 0.0, 0.0 };
    const light = options.light_rgb orelse .{ options.default_light, options.default_light, options.default_light };

    for (input, output, 0..) |raw, *out, index| {
        const channel = index % 3;
        const numerator = raw - dark[channel];
        const denominator = @max(light[channel] - dark[channel], eps);
        out.* = @max(numerator / denominator, eps);
    }
}

pub fn transmittanceToDensity(input: []const f64, output: []f64) !void {
    try validateRgbBuffers(input, output);
    for (input, output) |transmittance, *out| {
        out.* = transmittanceToDensityValue(transmittance);
    }
}

pub fn transmittanceToDensityValue(transmittance: f64) f64 {
    return -std.math.log10(@max(transmittance, eps));
}

pub fn estimateDmin(
    allocator: std.mem.Allocator,
    density: []const f64,
    rebate_mask: ?[]const bool,
    percentile: f64,
) ![3]f64 {
    try validateRgbInput(density);
    const pixel_count = density.len / 3;
    if (rebate_mask) |mask| {
        if (mask.len != pixel_count) return error.InvalidMeasurementMask;
        if (countSelected(mask) > 0) {
            return .{
                try percentileChannel(allocator, density, mask, 0, 50.0),
                try percentileChannel(allocator, density, mask, 1, 50.0),
                try percentileChannel(allocator, density, mask, 2, 50.0),
            };
        }
    }

    return .{
        try percentileChannel(allocator, density, null, 0, percentile),
        try percentileChannel(allocator, density, null, 1, percentile),
        try percentileChannel(allocator, density, null, 2, percentile),
    };
}

pub fn subtractDmin(density: []const f64, output: []f64, dmin: [3]f64) !void {
    try validateRgbBuffers(density, output);
    for (density, output, 0..) |value, *out, index| {
        out.* = @max(value - dmin[index % 3], 0.0);
    }
}

fn validateRgbBuffers(input: []const f64, output: []const f64) !void {
    try validateRgbInput(input);
    if (input.len != output.len) return error.InvalidMeasurementBuffer;
}

fn validateRgbInput(input: []const f64) !void {
    if (input.len == 0) return error.InvalidMeasurementBuffer;
    if (input.len % 3 != 0) return error.InvalidMeasurementBuffer;
}

fn countSelected(mask: []const bool) usize {
    var count: usize = 0;
    for (mask) |selected| {
        if (selected) count += 1;
    }
    return count;
}

fn percentileChannel(
    allocator: std.mem.Allocator,
    density: []const f64,
    rebate_mask: ?[]const bool,
    channel: usize,
    percentile: f64,
) !f64 {
    if (!std.math.isFinite(percentile) or percentile < 0.0 or percentile > 100.0) {
        return error.InvalidMeasurementPercentile;
    }
    const pixel_count = density.len / 3;
    const selected_count = if (rebate_mask) |mask| countSelected(mask) else pixel_count;
    if (selected_count == 0) return error.InvalidMeasurementMask;

    const values = try allocator.alloc(f64, selected_count);
    defer allocator.free(values);

    var out_index: usize = 0;
    for (0..pixel_count) |pixel_index| {
        if (rebate_mask) |mask| {
            if (!mask[pixel_index]) continue;
        }
        values[out_index] = density[pixel_index * 3 + channel];
        out_index += 1;
    }

    std.sort.pdq(f64, values, {}, lessThanF64);
    const rank = (@as(f64, @floatFromInt(values.len - 1)) * percentile) / 100.0;
    const lower: usize = @intFromFloat(@floor(rank));
    const upper: usize = @intFromFloat(@ceil(rank));
    const fraction = rank - @as(f64, @floatFromInt(lower));
    return values[lower] * (1.0 - fraction) + values[upper] * fraction;
}

fn lessThanF64(_: void, lhs: f64, rhs: f64) bool {
    return lhs < rhs;
}

fn expectFixture(path: []const u8, options: NormalizeOptions) !void {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, path);
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try normalizeTransmittance(value.input, actual, options);
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "normalizes uint16 scanner values with Python default light" {
    try expectFixture("test/fixtures/processing/numeric/transmittance-u16-default.json", .{ .default_light = 65535.0 });
}

test "normalizes float values with Python default unit light" {
    try expectFixture("test/fixtures/processing/numeric/transmittance-float-default.json", .{ .default_light = 1.0 });
}

test "normalizes with explicit dark and light RGB frames" {
    try expectFixture("test/fixtures/processing/numeric/transmittance-dark-light.json", .{
        .dark_rgb = .{ 100.0, 100.0, 100.0 },
        .light_rgb = .{ 1000.0, 1100.0, 1300.0 },
    });
}

test "converts transmittance to density with EPS clamp" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/transmittance-to-density.json");
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try transmittanceToDensity(value.input, actual);
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "estimates Dmin from non-empty rebate mask by channel median" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/dmin-rebate-median.json");
    defer fixture.deinit();

    const value = fixture.value();
    const mask = [_]bool{ true, false, false, true };
    const dmin = try estimateDmin(allocator, value.input, &mask, 1.0);
    try numeric.assertCloseSlices(value.expected, &dmin, value.tolerance);
}

test "estimates Dmin from fallback percentile when mask is missing" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/dmin-percentile-25.json");
    defer fixture.deinit();

    const value = fixture.value();
    const dmin = try estimateDmin(allocator, value.input, null, 25.0);
    try numeric.assertCloseSlices(value.expected, &dmin, value.tolerance);
}

test "falls back to percentile when rebate mask is empty" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/dmin-percentile-25.json");
    defer fixture.deinit();

    const value = fixture.value();
    const mask = [_]bool{ false, false, false, false };
    const dmin = try estimateDmin(allocator, value.input, &mask, 25.0);
    try numeric.assertCloseSlices(value.expected, &dmin, value.tolerance);
}

test "subtracts Dmin and clamps negative net density to zero" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/subtract-dmin.json");
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try subtractDmin(value.input, actual, .{ 0.45, 0.85, 1.05 });
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "measurement buffers must be flat RGB triples" {
    var out: [2]f64 = undefined;
    try std.testing.expectError(error.InvalidMeasurementBuffer, transmittanceToDensity(&.{ 0.5, 1.0 }, &out));
}

test "Dmin estimation validates mask length and percentile" {
    const density = [_]f64{ 0.1, 0.2, 0.3 };
    const mask = [_]bool{ true, false };
    try std.testing.expectError(error.InvalidMeasurementMask, estimateDmin(std.testing.allocator, &density, &mask, 1.0));
    try std.testing.expectError(error.InvalidMeasurementPercentile, estimateDmin(std.testing.allocator, &density, null, -1.0));
}
