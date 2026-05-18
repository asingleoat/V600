const std = @import("std");

const numeric = @import("numeric_fixture.zig");

pub const basis_labels = [_][]const u8{ "R", "G", "B", "R2", "G2", "B2", "RG", "RB", "GB", "bias" };
pub const basis_len = basis_labels.len;
pub const channel_count = 3;
pub const Coefficients = [basis_len][channel_count]f64;

pub const BuiltinStock = struct {
    name: []const u8,
    description: []const u8,
    coeffs: Coefficients,
};

pub const identity_coeffs: Coefficients = .{
    .{ 1.0, 0.0, 0.0 },
    .{ 0.0, 1.0, 0.0 },
    .{ 0.0, 0.0, 1.0 },
    zero_row,
    zero_row,
    zero_row,
    zero_row,
    zero_row,
    zero_row,
    zero_row,
};

pub const kodak_gold_coeffs: Coefficients = .{
    .{ 1.20, -0.04, 0.0 },
    .{ -0.10, 0.90, -0.06 },
    .{ 0.0, -0.04, 1.02 },
    zero_row,
    zero_row,
    zero_row,
    zero_row,
    zero_row,
    zero_row,
    zero_row,
};

pub const kodak_portra_coeffs: Coefficients = .{
    .{ 1.15, -0.03, 0.0 },
    .{ -0.08, 0.93, -0.04 },
    .{ 0.0, 0.0, 1.00 },
    zero_row,
    zero_row,
    zero_row,
    zero_row,
    zero_row,
    zero_row,
    zero_row,
};

pub const builtin_stocks = [_]BuiltinStock{
    .{
        .name = "kodak_gold",
        .description = "Kodak Gold 200 on Epson V600",
        .coeffs = kodak_gold_coeffs,
    },
    .{
        .name = "kodak_portra",
        .description = "Kodak Portra 400 on Epson V600",
        .coeffs = kodak_portra_coeffs,
    },
};

const zero_row = [_]f64{ 0.0, 0.0, 0.0 };

pub fn builtinStock(name: []const u8) ?BuiltinStock {
    for (builtin_stocks) |stock| {
        if (std.mem.eql(u8, stock.name, name)) return stock;
    }
    return null;
}

pub fn polyFeaturesPixel(rgb: [channel_count]f64) [basis_len]f64 {
    const r = rgb[0];
    const g = rgb[1];
    const b = rgb[2];
    return .{ r, g, b, r * r, g * g, b * b, r * g, r * b, g * b, 1.0 };
}

pub fn polyFeatures(input: []const f64, output: []f64) !void {
    try validateDensityInput(input);
    const pixel_count = input.len / channel_count;
    if (output.len != pixel_count * basis_len) return error.InvalidDensityTransformBuffer;

    var out_index: usize = 0;
    var input_index: usize = 0;
    while (input_index < input.len) : (input_index += channel_count) {
        const basis = polyFeaturesPixel(.{
            input[input_index],
            input[input_index + 1],
            input[input_index + 2],
        });
        for (basis) |value| {
            output[out_index] = value;
            out_index += 1;
        }
    }
}

pub fn applyBasis(coeffs: Coefficients, basis: [basis_len]f64) [channel_count]f64 {
    var out = [_]f64{ 0.0, 0.0, 0.0 };
    for (basis, 0..) |basis_value, row| {
        inline for (0..channel_count) |channel| {
            out[channel] += basis_value * coeffs[row][channel];
        }
    }
    return out;
}

pub fn usesOnlyLinearTerms(coeffs: Coefficients) bool {
    for (coeffs[3..]) |row| {
        inline for (0..channel_count) |channel| {
            if (row[channel] != 0.0) return false;
        }
    }
    return true;
}

pub fn applyLinearTerms(coeffs: Coefficients, rgb: [channel_count]f64) [channel_count]f64 {
    var out = [_]f64{ 0.0, 0.0, 0.0 };
    inline for (0..channel_count) |channel| {
        out[channel] =
            rgb[0] * coeffs[0][channel] +
            rgb[1] * coeffs[1][channel] +
            rgb[2] * coeffs[2][channel];
    }
    return out;
}

pub fn applyDensityTransform(net_density: []const f64, output: []f64, coeffs: Coefficients) !void {
    try validateDensityInput(net_density);
    if (output.len != net_density.len) return error.InvalidDensityTransformBuffer;

    if (usesOnlyLinearTerms(coeffs)) {
        var index: usize = 0;
        while (index < net_density.len) : (index += channel_count) {
            const transformed = applyLinearTerms(coeffs, .{
                net_density[index],
                net_density[index + 1],
                net_density[index + 2],
            });
            output[index] = transformed[0];
            output[index + 1] = transformed[1];
            output[index + 2] = transformed[2];
        }
        return;
    }

    var index: usize = 0;
    while (index < net_density.len) : (index += channel_count) {
        const basis = polyFeaturesPixel(.{
            net_density[index],
            net_density[index + 1],
            net_density[index + 2],
        });
        const transformed = applyBasis(coeffs, basis);
        output[index] = transformed[0];
        output[index + 1] = transformed[1];
        output[index + 2] = transformed[2];
    }
}

fn validateDensityInput(input: []const f64) !void {
    if (input.len == 0) return error.InvalidDensityTransformBuffer;
    if (input.len % channel_count != 0) return error.InvalidDensityTransformBuffer;
}

fn expectChannels(expected: [channel_count]f64, actual: [channel_count]f64) !void {
    inline for (0..channel_count) |channel| {
        try std.testing.expectEqual(expected[channel], actual[channel]);
    }
}

test "builds polynomial features in Python basis order" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/poly-features.json");
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try polyFeatures(value.input, actual);
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "applies identity density transform against Python fixture" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/density-transform-identity.json");
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try applyDensityTransform(value.input, actual, identity_coeffs);
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "applies Kodak Gold density transform against Python fixture" {
    const allocator = std.testing.allocator;
    var fixture = try numeric.loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/density-transform-kodak-gold.json");
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try applyDensityTransform(value.input, actual, kodak_gold_coeffs);
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "density transform buffers must be flat RGB triples" {
    var out: [2]f64 = undefined;
    try std.testing.expectError(error.InvalidDensityTransformBuffer, applyDensityTransform(&.{ 0.1, 0.2 }, &out, identity_coeffs));
}

test "preserves film stock coefficient shapes and builtin metadata" {
    try std.testing.expectEqual(@as(usize, 10), basis_len);
    try std.testing.expectEqual(@as(usize, 3), channel_count);
    try std.testing.expectEqual(@as(usize, 2), builtin_stocks.len);
    try std.testing.expectEqual(@as(usize, basis_len), identity_coeffs.len);
    try std.testing.expectEqual(@as(usize, channel_count), identity_coeffs[0].len);
    try std.testing.expectEqualStrings("bias", basis_labels[9]);

    const gold = builtinStock("kodak_gold").?;
    try std.testing.expectEqualStrings("Kodak Gold 200 on Epson V600", gold.description);
    const portra = builtinStock("kodak_portra").?;
    try std.testing.expectEqualStrings("Kodak Portra 400 on Epson V600", portra.description);
    try std.testing.expect(builtinStock("missing") == null);
}

test "preserves selected identity and stock polynomial outputs" {
    try std.testing.expect(usesOnlyLinearTerms(identity_coeffs));
    try std.testing.expect(usesOnlyLinearTerms(kodak_gold_coeffs));
    try std.testing.expect(usesOnlyLinearTerms(kodak_portra_coeffs));
    var quadratic = kodak_gold_coeffs;
    quadratic[3][0] = 0.001;
    try std.testing.expect(!usesOnlyLinearTerms(quadratic));

    try expectChannels(.{ 0.2, 0.3, 0.4 }, applyBasis(identity_coeffs, .{
        0.2, 0.3, 0.4, 0.04, 0.09, 0.16, 0.06, 0.08, 0.12, 1.0,
    }));
    try expectChannels(.{ 0.2, 0.3, 0.4 }, applyLinearTerms(identity_coeffs, .{
        0.2, 0.3, 0.4,
    }));
    try expectChannels(.{ 1.20, -0.04, 0.0 }, applyBasis(kodak_gold_coeffs, .{
        1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    }));
    try expectChannels(.{ -0.10, 0.90, -0.06 }, applyBasis(kodak_gold_coeffs, .{
        0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    }));
    try expectChannels(.{ 1.15, -0.03, 0.0 }, applyBasis(kodak_portra_coeffs, .{
        1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    }));
}
