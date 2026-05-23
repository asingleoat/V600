const std = @import("std");

const film_stocks = @import("film_stocks.zig");
const measurement = @import("measurement.zig");
const numeric = @import("numeric_fixture.zig");
const render = @import("render.zig");
const webgpu = @import("webgpu.zig");

pub const InvertOptions = struct {
    dmin: ?[3]f64 = null,
    coeffs: ?film_stocks.Coefficients = null,
    stock: []const u8 = "kodak_gold",
    dark_rgb: ?[3]f64 = null,
    light_rgb: ?[3]f64 = null,
    default_light: f64 = 65535.0,
    rebate_mask: ?[]const bool = null,
    dmin_percentile: f64 = 1.0,
    request: webgpu.Request = .{},
};

pub const InvertResult = struct {
    dmin: [3]f64,
};

const simd_width = 4;
const SimdF64 = @Vector(simd_width, f64);
const SimdF32 = @Vector(simd_width, f32);
const log2_to_log10_scalar = 0.3010299956639812;

pub const density_lut_entries: usize = 1 << 16;
const density_lut_channels: usize = 3;
const density_lut_len: usize = density_lut_entries * density_lut_channels;

pub const DensityLutF64 = struct {
    values: []f64,

    pub fn init(allocator: std.mem.Allocator, dmin: [3]f64, default_light: f64) !DensityLutF64 {
        try validateDefaultLight(default_light);
        const values = try allocator.alloc(f64, density_lut_len);
        errdefer allocator.free(values);
        fillDensityLut(f64, values, dmin, default_light);
        return .{ .values = values };
    }

    pub fn deinit(self: DensityLutF64, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
    }

    fn channel(self: DensityLutF64, index: usize) []const f64 {
        const start = index * density_lut_entries;
        return self.values[start..][0..density_lut_entries];
    }
};

pub const DensityLutF32 = struct {
    values: []f32,

    pub fn init(allocator: std.mem.Allocator, dmin: [3]f64, default_light: f64) !DensityLutF32 {
        try validateDefaultLight(default_light);
        const values = try allocator.alloc(f32, density_lut_len);
        errdefer allocator.free(values);
        fillDensityLut(f32, values, dmin, default_light);
        return .{ .values = values };
    }

    pub fn initF32(allocator: std.mem.Allocator, dmin: [3]f32, default_light: f32) !DensityLutF32 {
        try validateDefaultLightF32(default_light);
        const values = try allocator.alloc(f32, density_lut_len);
        errdefer allocator.free(values);
        fillDensityLutF32(values, dmin, default_light);
        return .{ .values = values };
    }

    pub fn deinit(self: DensityLutF32, allocator: std.mem.Allocator) void {
        allocator.free(self.values);
    }

    pub fn channel(self: DensityLutF32, index: usize) []const f32 {
        const start = index * density_lut_entries;
        return self.values[start..][0..density_lut_entries];
    }

    pub fn lookupSampleF64(self: DensityLutF32, channel_index: usize, sample: f64) f32 {
        return lookupF64SampleF32(self.channel(channel_index), sample);
    }
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

    if (!try shouldUseCpuForInvert(options)) {
        const dmin = options.dmin orelse try computeDmin(allocator, raw_rgb, options.rebate_mask, .{
            .dark_rgb = options.dark_rgb,
            .light_rgb = options.light_rgb,
            .default_light = options.default_light,
        });
        const gpu_output = try webgpu.applyInvertNegativeKernel(allocator, raw_rgb, .{
            .dmin = dmin,
            .coeffs = coeffs,
            .default_light = options.default_light,
        }, .{});
        defer allocator.free(gpu_output);
        if (gpu_output.len != output.len) return error.InvalidInversionBuffer;
        @memcpy(output, gpu_output);
        return .{ .dmin = dmin };
    }

    if (options.dmin) |dmin| {
        if (canUseProvidedDminSimd(raw_rgb, options)) {
            try invertNegativeProvidedDminSimd(raw_rgb, output, dmin, coeffs, options.default_light);
        } else {
            try invertNegativeProvidedDminScalar(allocator, raw_rgb, output, dmin, coeffs, .{
                .dark_rgb = options.dark_rgb,
                .light_rgb = options.light_rgb,
                .default_light = options.default_light,
            });
        }
        return .{ .dmin = dmin };
    }

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

    const dmin = try measurement.estimateDmin(
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

pub fn invertNegativeProvidedDminScalar(
    allocator: std.mem.Allocator,
    raw_rgb: []const f64,
    output: []f64,
    dmin: [3]f64,
    coeffs: film_stocks.Coefficients,
    normalize_options: measurement.NormalizeOptions,
) !void {
    if (raw_rgb.len != output.len) return error.InvalidInversionBuffer;

    const transmittance = try allocator.alloc(f64, raw_rgb.len);
    defer allocator.free(transmittance);
    try measurement.normalizeTransmittance(raw_rgb, transmittance, normalize_options);

    const density = try allocator.alloc(f64, raw_rgb.len);
    defer allocator.free(density);
    try measurement.transmittanceToDensity(transmittance, density);

    const net_density = try allocator.alloc(f64, raw_rgb.len);
    defer allocator.free(net_density);
    try measurement.subtractDmin(density, net_density, dmin);
    try film_stocks.applyDensityTransform(net_density, output, coeffs);
    for (output) |*value| {
        value.* = @max(value.*, 0.0);
    }
}

pub fn invertNegativeProvidedDminSimd(
    raw_rgb: []const f64,
    output: []f64,
    dmin: [3]f64,
    coeffs: film_stocks.Coefficients,
    default_light: f64,
) !void {
    if (raw_rgb.len != output.len or raw_rgb.len == 0 or raw_rgb.len % 3 != 0) {
        return error.InvalidInversionBuffer;
    }

    if (film_stocks.usesOnlyLinearTerms(coeffs)) {
        return invertNegativeProvidedDminLinearSimd(raw_rgb, output, dmin, coeffs, default_light);
    }

    const pixel_count = raw_rgb.len / 3;
    const inv_light: SimdF64 = @splat(1.0 / default_light);
    const eps_v: SimdF64 = @splat(measurement.eps);
    const log2_to_log10_v: SimdF64 = @splat(log2_to_log10_scalar);
    const zero: SimdF64 = @splat(0.0);
    const one: SimdF64 = @splat(1.0);
    const dmin_r: SimdF64 = @splat(dmin[0]);
    const dmin_g: SimdF64 = @splat(dmin[1]);
    const dmin_b: SimdF64 = @splat(dmin[2]);

    var pixel: usize = 0;
    while (pixel + simd_width <= pixel_count) : (pixel += simd_width) {
        const base = pixel * 3;
        const raw_r: SimdF64 = .{ raw_rgb[base], raw_rgb[base + 3], raw_rgb[base + 6], raw_rgb[base + 9] };
        const raw_g: SimdF64 = .{ raw_rgb[base + 1], raw_rgb[base + 4], raw_rgb[base + 7], raw_rgb[base + 10] };
        const raw_b: SimdF64 = .{ raw_rgb[base + 2], raw_rgb[base + 5], raw_rgb[base + 8], raw_rgb[base + 11] };

        const tr = @max(raw_r * inv_light, eps_v);
        const tg = @max(raw_g * inv_light, eps_v);
        const tb = @max(raw_b * inv_light, eps_v);
        const dr = @max(-@log2(tr) * log2_to_log10_v - dmin_r, zero);
        const dg = @max(-@log2(tg) * log2_to_log10_v - dmin_g, zero);
        const db = @max(-@log2(tb) * log2_to_log10_v - dmin_b, zero);

        const basis = [_]SimdF64{
            dr,
            dg,
            db,
            dr * dr,
            dg * dg,
            db * db,
            dr * dg,
            dr * db,
            dg * db,
            one,
        };

        var out_r: SimdF64 = @splat(0.0);
        var out_g: SimdF64 = @splat(0.0);
        var out_b: SimdF64 = @splat(0.0);
        inline for (0..film_stocks.basis_len) |row| {
            out_r += basis[row] * @as(SimdF64, @splat(coeffs[row][0]));
            out_g += basis[row] * @as(SimdF64, @splat(coeffs[row][1]));
            out_b += basis[row] * @as(SimdF64, @splat(coeffs[row][2]));
        }
        out_r = @max(out_r, zero);
        out_g = @max(out_g, zero);
        out_b = @max(out_b, zero);

        inline for (0..simd_width) |lane| {
            output[base + lane * 3] = out_r[lane];
            output[base + lane * 3 + 1] = out_g[lane];
            output[base + lane * 3 + 2] = out_b[lane];
        }
    }

    while (pixel < pixel_count) : (pixel += 1) {
        const base = pixel * 3;
        const tr = @max(raw_rgb[base] / default_light, measurement.eps);
        const tg = @max(raw_rgb[base + 1] / default_light, measurement.eps);
        const tb = @max(raw_rgb[base + 2] / default_light, measurement.eps);
        const dr = @max(-std.math.log2(tr) * 0.3010299956639812 - dmin[0], 0.0);
        const dg = @max(-std.math.log2(tg) * 0.3010299956639812 - dmin[1], 0.0);
        const db = @max(-std.math.log2(tb) * 0.3010299956639812 - dmin[2], 0.0);
        const basis = [_]f64{ dr, dg, db, dr * dr, dg * dg, db * db, dr * dg, dr * db, dg * db, 1.0 };
        const transformed = film_stocks.applyBasis(coeffs, basis);
        output[base] = @max(transformed[0], 0.0);
        output[base + 1] = @max(transformed[1], 0.0);
        output[base + 2] = @max(transformed[2], 0.0);
    }
}

pub fn invertNegativeProvidedDminU16Simd(
    raw_rgb: []const u16,
    output: []f64,
    dmin: [3]f64,
    coeffs: film_stocks.Coefficients,
    default_light: f64,
) !void {
    if (raw_rgb.len != output.len or raw_rgb.len == 0 or raw_rgb.len % 3 != 0) {
        return error.InvalidInversionBuffer;
    }
    if (!std.math.isFinite(default_light) or default_light < measurement.eps) {
        return error.InvalidNormalizeReference;
    }

    if (film_stocks.usesOnlyLinearTerms(coeffs)) {
        return invertNegativeProvidedDminU16LinearSimd(raw_rgb, output, dmin, coeffs, default_light);
    }

    const pixel_count = raw_rgb.len / 3;
    const inv_light: SimdF64 = @splat(1.0 / default_light);
    const eps_v: SimdF64 = @splat(measurement.eps);
    const log2_to_log10_v: SimdF64 = @splat(log2_to_log10_scalar);
    const zero: SimdF64 = @splat(0.0);
    const one: SimdF64 = @splat(1.0);
    const dmin_r: SimdF64 = @splat(dmin[0]);
    const dmin_g: SimdF64 = @splat(dmin[1]);
    const dmin_b: SimdF64 = @splat(dmin[2]);

    var pixel: usize = 0;
    while (pixel + simd_width <= pixel_count) : (pixel += simd_width) {
        const base = pixel * 3;
        const raw_r: SimdF64 = .{
            @floatFromInt(raw_rgb[base]),
            @floatFromInt(raw_rgb[base + 3]),
            @floatFromInt(raw_rgb[base + 6]),
            @floatFromInt(raw_rgb[base + 9]),
        };
        const raw_g: SimdF64 = .{
            @floatFromInt(raw_rgb[base + 1]),
            @floatFromInt(raw_rgb[base + 4]),
            @floatFromInt(raw_rgb[base + 7]),
            @floatFromInt(raw_rgb[base + 10]),
        };
        const raw_b: SimdF64 = .{
            @floatFromInt(raw_rgb[base + 2]),
            @floatFromInt(raw_rgb[base + 5]),
            @floatFromInt(raw_rgb[base + 8]),
            @floatFromInt(raw_rgb[base + 11]),
        };

        const tr = @max(raw_r * inv_light, eps_v);
        const tg = @max(raw_g * inv_light, eps_v);
        const tb = @max(raw_b * inv_light, eps_v);
        const dr = @max(-@log2(tr) * log2_to_log10_v - dmin_r, zero);
        const dg = @max(-@log2(tg) * log2_to_log10_v - dmin_g, zero);
        const db = @max(-@log2(tb) * log2_to_log10_v - dmin_b, zero);

        const basis = [_]SimdF64{
            dr,
            dg,
            db,
            dr * dr,
            dg * dg,
            db * db,
            dr * dg,
            dr * db,
            dg * db,
            one,
        };

        var out_r: SimdF64 = @splat(0.0);
        var out_g: SimdF64 = @splat(0.0);
        var out_b: SimdF64 = @splat(0.0);
        inline for (0..film_stocks.basis_len) |row| {
            out_r += basis[row] * @as(SimdF64, @splat(coeffs[row][0]));
            out_g += basis[row] * @as(SimdF64, @splat(coeffs[row][1]));
            out_b += basis[row] * @as(SimdF64, @splat(coeffs[row][2]));
        }
        out_r = @max(out_r, zero);
        out_g = @max(out_g, zero);
        out_b = @max(out_b, zero);

        inline for (0..simd_width) |lane| {
            output[base + lane * 3] = out_r[lane];
            output[base + lane * 3 + 1] = out_g[lane];
            output[base + lane * 3 + 2] = out_b[lane];
        }
    }

    while (pixel < pixel_count) : (pixel += 1) {
        const base = pixel * 3;
        const tr = @max(@as(f64, @floatFromInt(raw_rgb[base])) / default_light, measurement.eps);
        const tg = @max(@as(f64, @floatFromInt(raw_rgb[base + 1])) / default_light, measurement.eps);
        const tb = @max(@as(f64, @floatFromInt(raw_rgb[base + 2])) / default_light, measurement.eps);
        const dr = @max(-std.math.log2(tr) * 0.3010299956639812 - dmin[0], 0.0);
        const dg = @max(-std.math.log2(tg) * 0.3010299956639812 - dmin[1], 0.0);
        const db = @max(-std.math.log2(tb) * 0.3010299956639812 - dmin[2], 0.0);
        const basis = [_]f64{ dr, dg, db, dr * dr, dg * dg, db * db, dr * dg, dr * db, dg * db, 1.0 };
        const transformed = film_stocks.applyBasis(coeffs, basis);
        output[base] = @max(transformed[0], 0.0);
        output[base + 1] = @max(transformed[1], 0.0);
        output[base + 2] = @max(transformed[2], 0.0);
    }
}

pub fn invertNegativeProvidedDminU16WithDensityLutF64(
    raw_rgb: []const u16,
    output: []f64,
    lut: DensityLutF64,
    coeffs: film_stocks.Coefficients,
) !void {
    try validateU16InvertBuffers(raw_rgb, output.len);
    try validateDensityLutLen(lut.values.len);

    if (film_stocks.usesOnlyLinearTerms(coeffs)) {
        return invertNegativeProvidedDminU16LinearDensityLutF64(raw_rgb, output, lut, coeffs);
    }

    const r_lut = lut.channel(0);
    const g_lut = lut.channel(1);
    const b_lut = lut.channel(2);
    const pixel_count = raw_rgb.len / 3;
    const zero: SimdF64 = @splat(0.0);
    const one: SimdF64 = @splat(1.0);

    var pixel: usize = 0;
    while (pixel + simd_width <= pixel_count) : (pixel += simd_width) {
        const base = pixel * 3;
        const dr: SimdF64 = .{
            r_lut[lutIndex(raw_rgb[base])],
            r_lut[lutIndex(raw_rgb[base + 3])],
            r_lut[lutIndex(raw_rgb[base + 6])],
            r_lut[lutIndex(raw_rgb[base + 9])],
        };
        const dg: SimdF64 = .{
            g_lut[lutIndex(raw_rgb[base + 1])],
            g_lut[lutIndex(raw_rgb[base + 4])],
            g_lut[lutIndex(raw_rgb[base + 7])],
            g_lut[lutIndex(raw_rgb[base + 10])],
        };
        const db: SimdF64 = .{
            b_lut[lutIndex(raw_rgb[base + 2])],
            b_lut[lutIndex(raw_rgb[base + 5])],
            b_lut[lutIndex(raw_rgb[base + 8])],
            b_lut[lutIndex(raw_rgb[base + 11])],
        };

        const basis = [_]SimdF64{
            dr,
            dg,
            db,
            dr * dr,
            dg * dg,
            db * db,
            dr * dg,
            dr * db,
            dg * db,
            one,
        };

        var out_r: SimdF64 = @splat(0.0);
        var out_g: SimdF64 = @splat(0.0);
        var out_b: SimdF64 = @splat(0.0);
        inline for (0..film_stocks.basis_len) |row| {
            out_r += basis[row] * @as(SimdF64, @splat(coeffs[row][0]));
            out_g += basis[row] * @as(SimdF64, @splat(coeffs[row][1]));
            out_b += basis[row] * @as(SimdF64, @splat(coeffs[row][2]));
        }
        out_r = @max(out_r, zero);
        out_g = @max(out_g, zero);
        out_b = @max(out_b, zero);

        inline for (0..simd_width) |lane| {
            output[base + lane * 3] = out_r[lane];
            output[base + lane * 3 + 1] = out_g[lane];
            output[base + lane * 3 + 2] = out_b[lane];
        }
    }

    while (pixel < pixel_count) : (pixel += 1) {
        const base = pixel * 3;
        const dr = r_lut[lutIndex(raw_rgb[base])];
        const dg = g_lut[lutIndex(raw_rgb[base + 1])];
        const db = b_lut[lutIndex(raw_rgb[base + 2])];
        const basis = [_]f64{ dr, dg, db, dr * dr, dg * dg, db * db, dr * dg, dr * db, dg * db, 1.0 };
        const transformed = film_stocks.applyBasis(coeffs, basis);
        output[base] = @max(transformed[0], 0.0);
        output[base + 1] = @max(transformed[1], 0.0);
        output[base + 2] = @max(transformed[2], 0.0);
    }
}

pub fn invertNegativeProvidedDminU16WithDensityLutF32(
    raw_rgb: []const u16,
    output: []f64,
    lut: DensityLutF32,
    coeffs: film_stocks.Coefficients,
) !void {
    try validateU16InvertBuffers(raw_rgb, output.len);
    try validateDensityLutLen(lut.values.len);

    if (film_stocks.usesOnlyLinearTerms(coeffs)) {
        return invertNegativeProvidedDminU16LinearDensityLutF32(raw_rgb, output, lut, coeffs);
    }

    const r_lut = lut.channel(0);
    const g_lut = lut.channel(1);
    const b_lut = lut.channel(2);
    const pixel_count = raw_rgb.len / 3;
    const zero: SimdF64 = @splat(0.0);
    const one: SimdF64 = @splat(1.0);

    var pixel: usize = 0;
    while (pixel + simd_width <= pixel_count) : (pixel += simd_width) {
        const base = pixel * 3;
        const dr: SimdF64 = .{
            lookupF32AsF64(r_lut, raw_rgb[base]),
            lookupF32AsF64(r_lut, raw_rgb[base + 3]),
            lookupF32AsF64(r_lut, raw_rgb[base + 6]),
            lookupF32AsF64(r_lut, raw_rgb[base + 9]),
        };
        const dg: SimdF64 = .{
            lookupF32AsF64(g_lut, raw_rgb[base + 1]),
            lookupF32AsF64(g_lut, raw_rgb[base + 4]),
            lookupF32AsF64(g_lut, raw_rgb[base + 7]),
            lookupF32AsF64(g_lut, raw_rgb[base + 10]),
        };
        const db: SimdF64 = .{
            lookupF32AsF64(b_lut, raw_rgb[base + 2]),
            lookupF32AsF64(b_lut, raw_rgb[base + 5]),
            lookupF32AsF64(b_lut, raw_rgb[base + 8]),
            lookupF32AsF64(b_lut, raw_rgb[base + 11]),
        };

        const basis = [_]SimdF64{
            dr,
            dg,
            db,
            dr * dr,
            dg * dg,
            db * db,
            dr * dg,
            dr * db,
            dg * db,
            one,
        };

        var out_r: SimdF64 = @splat(0.0);
        var out_g: SimdF64 = @splat(0.0);
        var out_b: SimdF64 = @splat(0.0);
        inline for (0..film_stocks.basis_len) |row| {
            out_r += basis[row] * @as(SimdF64, @splat(coeffs[row][0]));
            out_g += basis[row] * @as(SimdF64, @splat(coeffs[row][1]));
            out_b += basis[row] * @as(SimdF64, @splat(coeffs[row][2]));
        }
        out_r = @max(out_r, zero);
        out_g = @max(out_g, zero);
        out_b = @max(out_b, zero);

        inline for (0..simd_width) |lane| {
            output[base + lane * 3] = out_r[lane];
            output[base + lane * 3 + 1] = out_g[lane];
            output[base + lane * 3 + 2] = out_b[lane];
        }
    }

    while (pixel < pixel_count) : (pixel += 1) {
        const base = pixel * 3;
        const dr = lookupF32AsF64(r_lut, raw_rgb[base]);
        const dg = lookupF32AsF64(g_lut, raw_rgb[base + 1]);
        const db = lookupF32AsF64(b_lut, raw_rgb[base + 2]);
        const basis = [_]f64{ dr, dg, db, dr * dr, dg * dg, db * db, dr * dg, dr * db, dg * db, 1.0 };
        const transformed = film_stocks.applyBasis(coeffs, basis);
        output[base] = @max(transformed[0], 0.0);
        output[base + 1] = @max(transformed[1], 0.0);
        output[base + 2] = @max(transformed[2], 0.0);
    }
}

pub fn invertNegativeProvidedDminU16WithDensityLutF32OutputF32(
    raw_rgb: []const u16,
    output: []f32,
    lut: DensityLutF32,
    coeffs: film_stocks.Coefficients,
) !void {
    try validateU16InvertBuffers(raw_rgb, output.len);
    try validateDensityLutLen(lut.values.len);
    if (!film_stocks.usesOnlyLinearTerms(coeffs)) return error.UnsupportedDensityLutOutput;

    const r_lut = lut.channel(0);
    const g_lut = lut.channel(1);
    const b_lut = lut.channel(2);
    const pixel_count = raw_rgb.len / 3;
    const zero: SimdF32 = @splat(0.0);
    const c00: SimdF32 = @splat(@as(f32, @floatCast(coeffs[0][0])));
    const c01: SimdF32 = @splat(@as(f32, @floatCast(coeffs[0][1])));
    const c02: SimdF32 = @splat(@as(f32, @floatCast(coeffs[0][2])));
    const c10: SimdF32 = @splat(@as(f32, @floatCast(coeffs[1][0])));
    const c11: SimdF32 = @splat(@as(f32, @floatCast(coeffs[1][1])));
    const c12: SimdF32 = @splat(@as(f32, @floatCast(coeffs[1][2])));
    const c20: SimdF32 = @splat(@as(f32, @floatCast(coeffs[2][0])));
    const c21: SimdF32 = @splat(@as(f32, @floatCast(coeffs[2][1])));
    const c22: SimdF32 = @splat(@as(f32, @floatCast(coeffs[2][2])));

    var pixel: usize = 0;
    while (pixel + simd_width <= pixel_count) : (pixel += simd_width) {
        const base = pixel * 3;
        const dr: SimdF32 = .{
            r_lut[lutIndex(raw_rgb[base])],
            r_lut[lutIndex(raw_rgb[base + 3])],
            r_lut[lutIndex(raw_rgb[base + 6])],
            r_lut[lutIndex(raw_rgb[base + 9])],
        };
        const dg: SimdF32 = .{
            g_lut[lutIndex(raw_rgb[base + 1])],
            g_lut[lutIndex(raw_rgb[base + 4])],
            g_lut[lutIndex(raw_rgb[base + 7])],
            g_lut[lutIndex(raw_rgb[base + 10])],
        };
        const db: SimdF32 = .{
            b_lut[lutIndex(raw_rgb[base + 2])],
            b_lut[lutIndex(raw_rgb[base + 5])],
            b_lut[lutIndex(raw_rgb[base + 8])],
            b_lut[lutIndex(raw_rgb[base + 11])],
        };

        const out_r = @max(dr * c00 + dg * c10 + db * c20, zero);
        const out_g = @max(dr * c01 + dg * c11 + db * c21, zero);
        const out_b = @max(dr * c02 + dg * c12 + db * c22, zero);

        inline for (0..simd_width) |lane| {
            output[base + lane * 3] = out_r[lane];
            output[base + lane * 3 + 1] = out_g[lane];
            output[base + lane * 3 + 2] = out_b[lane];
        }
    }

    while (pixel < pixel_count) : (pixel += 1) {
        const base = pixel * 3;
        const dr = r_lut[lutIndex(raw_rgb[base])];
        const dg = g_lut[lutIndex(raw_rgb[base + 1])];
        const db = b_lut[lutIndex(raw_rgb[base + 2])];
        const out_r = dr * @as(f32, @floatCast(coeffs[0][0])) + dg * @as(f32, @floatCast(coeffs[1][0])) + db * @as(f32, @floatCast(coeffs[2][0]));
        const out_g = dr * @as(f32, @floatCast(coeffs[0][1])) + dg * @as(f32, @floatCast(coeffs[1][1])) + db * @as(f32, @floatCast(coeffs[2][1]));
        const out_b = dr * @as(f32, @floatCast(coeffs[0][2])) + dg * @as(f32, @floatCast(coeffs[1][2])) + db * @as(f32, @floatCast(coeffs[2][2]));
        output[base] = @max(out_r, 0.0);
        output[base + 1] = @max(out_g, 0.0);
        output[base + 2] = @max(out_b, 0.0);
    }
}

pub fn invertNegativeF64WithDensityLutF32OutputF32(
    raw_rgb: []const f64,
    output: []f32,
    lut: DensityLutF32,
    coeffs: film_stocks.Coefficients,
) !void {
    if (raw_rgb.len != output.len or raw_rgb.len == 0 or raw_rgb.len % 3 != 0) return error.InvalidInversionBuffer;
    try validateDensityLutLen(lut.values.len);
    if (!film_stocks.usesOnlyLinearTerms(coeffs)) return error.UnsupportedDensityLutOutput;

    const r_lut = lut.channel(0);
    const g_lut = lut.channel(1);
    const b_lut = lut.channel(2);
    const c00: f32 = @floatCast(coeffs[0][0]);
    const c01: f32 = @floatCast(coeffs[0][1]);
    const c02: f32 = @floatCast(coeffs[0][2]);
    const c10: f32 = @floatCast(coeffs[1][0]);
    const c11: f32 = @floatCast(coeffs[1][1]);
    const c12: f32 = @floatCast(coeffs[1][2]);
    const c20: f32 = @floatCast(coeffs[2][0]);
    const c21: f32 = @floatCast(coeffs[2][1]);
    const c22: f32 = @floatCast(coeffs[2][2]);

    var index: usize = 0;
    while (index < raw_rgb.len) : (index += 3) {
        const dr = lookupF64SampleF32(r_lut, raw_rgb[index]);
        const dg = lookupF64SampleF32(g_lut, raw_rgb[index + 1]);
        const db = lookupF64SampleF32(b_lut, raw_rgb[index + 2]);
        output[index] = @max(dr * c00 + dg * c10 + db * c20, 0.0);
        output[index + 1] = @max(dr * c01 + dg * c11 + db * c21, 0.0);
        output[index + 2] = @max(dr * c02 + dg * c12 + db * c22, 0.0);
    }
}

fn invertNegativeProvidedDminLinearSimd(
    raw_rgb: []const f64,
    output: []f64,
    dmin: [3]f64,
    coeffs: film_stocks.Coefficients,
    default_light: f64,
) !void {
    const pixel_count = raw_rgb.len / 3;
    const inv_light: SimdF64 = @splat(1.0 / default_light);
    const eps_v: SimdF64 = @splat(measurement.eps);
    const log2_to_log10_v: SimdF64 = @splat(log2_to_log10_scalar);
    const zero: SimdF64 = @splat(0.0);
    const dmin_r: SimdF64 = @splat(dmin[0]);
    const dmin_g: SimdF64 = @splat(dmin[1]);
    const dmin_b: SimdF64 = @splat(dmin[2]);
    const c00: SimdF64 = @splat(coeffs[0][0]);
    const c01: SimdF64 = @splat(coeffs[0][1]);
    const c02: SimdF64 = @splat(coeffs[0][2]);
    const c10: SimdF64 = @splat(coeffs[1][0]);
    const c11: SimdF64 = @splat(coeffs[1][1]);
    const c12: SimdF64 = @splat(coeffs[1][2]);
    const c20: SimdF64 = @splat(coeffs[2][0]);
    const c21: SimdF64 = @splat(coeffs[2][1]);
    const c22: SimdF64 = @splat(coeffs[2][2]);

    var pixel: usize = 0;
    while (pixel + simd_width <= pixel_count) : (pixel += simd_width) {
        const base = pixel * 3;
        const raw_r: SimdF64 = .{ raw_rgb[base], raw_rgb[base + 3], raw_rgb[base + 6], raw_rgb[base + 9] };
        const raw_g: SimdF64 = .{ raw_rgb[base + 1], raw_rgb[base + 4], raw_rgb[base + 7], raw_rgb[base + 10] };
        const raw_b: SimdF64 = .{ raw_rgb[base + 2], raw_rgb[base + 5], raw_rgb[base + 8], raw_rgb[base + 11] };

        const tr = @max(raw_r * inv_light, eps_v);
        const tg = @max(raw_g * inv_light, eps_v);
        const tb = @max(raw_b * inv_light, eps_v);
        const dr = @max(-@log2(tr) * log2_to_log10_v - dmin_r, zero);
        const dg = @max(-@log2(tg) * log2_to_log10_v - dmin_g, zero);
        const db = @max(-@log2(tb) * log2_to_log10_v - dmin_b, zero);

        const out_r = @max(dr * c00 + dg * c10 + db * c20, zero);
        const out_g = @max(dr * c01 + dg * c11 + db * c21, zero);
        const out_b = @max(dr * c02 + dg * c12 + db * c22, zero);

        inline for (0..simd_width) |lane| {
            output[base + lane * 3] = out_r[lane];
            output[base + lane * 3 + 1] = out_g[lane];
            output[base + lane * 3 + 2] = out_b[lane];
        }
    }

    while (pixel < pixel_count) : (pixel += 1) {
        const base = pixel * 3;
        const tr = @max(raw_rgb[base] / default_light, measurement.eps);
        const tg = @max(raw_rgb[base + 1] / default_light, measurement.eps);
        const tb = @max(raw_rgb[base + 2] / default_light, measurement.eps);
        const dr = @max(-std.math.log2(tr) * 0.3010299956639812 - dmin[0], 0.0);
        const dg = @max(-std.math.log2(tg) * 0.3010299956639812 - dmin[1], 0.0);
        const db = @max(-std.math.log2(tb) * 0.3010299956639812 - dmin[2], 0.0);
        const transformed = film_stocks.applyLinearTerms(coeffs, .{ dr, dg, db });
        output[base] = @max(transformed[0], 0.0);
        output[base + 1] = @max(transformed[1], 0.0);
        output[base + 2] = @max(transformed[2], 0.0);
    }
}

fn invertNegativeProvidedDminU16LinearSimd(
    raw_rgb: []const u16,
    output: []f64,
    dmin: [3]f64,
    coeffs: film_stocks.Coefficients,
    default_light: f64,
) !void {
    const pixel_count = raw_rgb.len / 3;
    const inv_light: SimdF64 = @splat(1.0 / default_light);
    const eps_v: SimdF64 = @splat(measurement.eps);
    const log2_to_log10_v: SimdF64 = @splat(log2_to_log10_scalar);
    const zero: SimdF64 = @splat(0.0);
    const dmin_r: SimdF64 = @splat(dmin[0]);
    const dmin_g: SimdF64 = @splat(dmin[1]);
    const dmin_b: SimdF64 = @splat(dmin[2]);
    const c00: SimdF64 = @splat(coeffs[0][0]);
    const c01: SimdF64 = @splat(coeffs[0][1]);
    const c02: SimdF64 = @splat(coeffs[0][2]);
    const c10: SimdF64 = @splat(coeffs[1][0]);
    const c11: SimdF64 = @splat(coeffs[1][1]);
    const c12: SimdF64 = @splat(coeffs[1][2]);
    const c20: SimdF64 = @splat(coeffs[2][0]);
    const c21: SimdF64 = @splat(coeffs[2][1]);
    const c22: SimdF64 = @splat(coeffs[2][2]);

    var pixel: usize = 0;
    while (pixel + simd_width <= pixel_count) : (pixel += simd_width) {
        const base = pixel * 3;
        const raw_r: SimdF64 = .{
            @floatFromInt(raw_rgb[base]),
            @floatFromInt(raw_rgb[base + 3]),
            @floatFromInt(raw_rgb[base + 6]),
            @floatFromInt(raw_rgb[base + 9]),
        };
        const raw_g: SimdF64 = .{
            @floatFromInt(raw_rgb[base + 1]),
            @floatFromInt(raw_rgb[base + 4]),
            @floatFromInt(raw_rgb[base + 7]),
            @floatFromInt(raw_rgb[base + 10]),
        };
        const raw_b: SimdF64 = .{
            @floatFromInt(raw_rgb[base + 2]),
            @floatFromInt(raw_rgb[base + 5]),
            @floatFromInt(raw_rgb[base + 8]),
            @floatFromInt(raw_rgb[base + 11]),
        };

        const tr = @max(raw_r * inv_light, eps_v);
        const tg = @max(raw_g * inv_light, eps_v);
        const tb = @max(raw_b * inv_light, eps_v);
        const dr = @max(-@log2(tr) * log2_to_log10_v - dmin_r, zero);
        const dg = @max(-@log2(tg) * log2_to_log10_v - dmin_g, zero);
        const db = @max(-@log2(tb) * log2_to_log10_v - dmin_b, zero);

        const out_r = @max(dr * c00 + dg * c10 + db * c20, zero);
        const out_g = @max(dr * c01 + dg * c11 + db * c21, zero);
        const out_b = @max(dr * c02 + dg * c12 + db * c22, zero);

        inline for (0..simd_width) |lane| {
            output[base + lane * 3] = out_r[lane];
            output[base + lane * 3 + 1] = out_g[lane];
            output[base + lane * 3 + 2] = out_b[lane];
        }
    }

    while (pixel < pixel_count) : (pixel += 1) {
        const base = pixel * 3;
        const tr = @max(@as(f64, @floatFromInt(raw_rgb[base])) / default_light, measurement.eps);
        const tg = @max(@as(f64, @floatFromInt(raw_rgb[base + 1])) / default_light, measurement.eps);
        const tb = @max(@as(f64, @floatFromInt(raw_rgb[base + 2])) / default_light, measurement.eps);
        const dr = @max(-std.math.log2(tr) * 0.3010299956639812 - dmin[0], 0.0);
        const dg = @max(-std.math.log2(tg) * 0.3010299956639812 - dmin[1], 0.0);
        const db = @max(-std.math.log2(tb) * 0.3010299956639812 - dmin[2], 0.0);
        const transformed = film_stocks.applyLinearTerms(coeffs, .{ dr, dg, db });
        output[base] = @max(transformed[0], 0.0);
        output[base + 1] = @max(transformed[1], 0.0);
        output[base + 2] = @max(transformed[2], 0.0);
    }
}

fn invertNegativeProvidedDminU16LinearDensityLutF64(
    raw_rgb: []const u16,
    output: []f64,
    lut: DensityLutF64,
    coeffs: film_stocks.Coefficients,
) !void {
    const r_lut = lut.channel(0);
    const g_lut = lut.channel(1);
    const b_lut = lut.channel(2);
    const pixel_count = raw_rgb.len / 3;
    const zero: SimdF64 = @splat(0.0);
    const c00: SimdF64 = @splat(coeffs[0][0]);
    const c01: SimdF64 = @splat(coeffs[0][1]);
    const c02: SimdF64 = @splat(coeffs[0][2]);
    const c10: SimdF64 = @splat(coeffs[1][0]);
    const c11: SimdF64 = @splat(coeffs[1][1]);
    const c12: SimdF64 = @splat(coeffs[1][2]);
    const c20: SimdF64 = @splat(coeffs[2][0]);
    const c21: SimdF64 = @splat(coeffs[2][1]);
    const c22: SimdF64 = @splat(coeffs[2][2]);

    var pixel: usize = 0;
    while (pixel + simd_width <= pixel_count) : (pixel += simd_width) {
        const base = pixel * 3;
        const dr: SimdF64 = .{
            r_lut[lutIndex(raw_rgb[base])],
            r_lut[lutIndex(raw_rgb[base + 3])],
            r_lut[lutIndex(raw_rgb[base + 6])],
            r_lut[lutIndex(raw_rgb[base + 9])],
        };
        const dg: SimdF64 = .{
            g_lut[lutIndex(raw_rgb[base + 1])],
            g_lut[lutIndex(raw_rgb[base + 4])],
            g_lut[lutIndex(raw_rgb[base + 7])],
            g_lut[lutIndex(raw_rgb[base + 10])],
        };
        const db: SimdF64 = .{
            b_lut[lutIndex(raw_rgb[base + 2])],
            b_lut[lutIndex(raw_rgb[base + 5])],
            b_lut[lutIndex(raw_rgb[base + 8])],
            b_lut[lutIndex(raw_rgb[base + 11])],
        };

        const out_r = @max(dr * c00 + dg * c10 + db * c20, zero);
        const out_g = @max(dr * c01 + dg * c11 + db * c21, zero);
        const out_b = @max(dr * c02 + dg * c12 + db * c22, zero);

        inline for (0..simd_width) |lane| {
            output[base + lane * 3] = out_r[lane];
            output[base + lane * 3 + 1] = out_g[lane];
            output[base + lane * 3 + 2] = out_b[lane];
        }
    }

    while (pixel < pixel_count) : (pixel += 1) {
        const base = pixel * 3;
        const transformed = film_stocks.applyLinearTerms(coeffs, .{
            r_lut[lutIndex(raw_rgb[base])],
            g_lut[lutIndex(raw_rgb[base + 1])],
            b_lut[lutIndex(raw_rgb[base + 2])],
        });
        output[base] = @max(transformed[0], 0.0);
        output[base + 1] = @max(transformed[1], 0.0);
        output[base + 2] = @max(transformed[2], 0.0);
    }
}

fn invertNegativeProvidedDminU16LinearDensityLutF32(
    raw_rgb: []const u16,
    output: []f64,
    lut: DensityLutF32,
    coeffs: film_stocks.Coefficients,
) !void {
    const r_lut = lut.channel(0);
    const g_lut = lut.channel(1);
    const b_lut = lut.channel(2);
    const pixel_count = raw_rgb.len / 3;
    const zero: SimdF64 = @splat(0.0);
    const c00: SimdF64 = @splat(coeffs[0][0]);
    const c01: SimdF64 = @splat(coeffs[0][1]);
    const c02: SimdF64 = @splat(coeffs[0][2]);
    const c10: SimdF64 = @splat(coeffs[1][0]);
    const c11: SimdF64 = @splat(coeffs[1][1]);
    const c12: SimdF64 = @splat(coeffs[1][2]);
    const c20: SimdF64 = @splat(coeffs[2][0]);
    const c21: SimdF64 = @splat(coeffs[2][1]);
    const c22: SimdF64 = @splat(coeffs[2][2]);

    var pixel: usize = 0;
    while (pixel + simd_width <= pixel_count) : (pixel += simd_width) {
        const base = pixel * 3;
        const dr: SimdF64 = .{
            lookupF32AsF64(r_lut, raw_rgb[base]),
            lookupF32AsF64(r_lut, raw_rgb[base + 3]),
            lookupF32AsF64(r_lut, raw_rgb[base + 6]),
            lookupF32AsF64(r_lut, raw_rgb[base + 9]),
        };
        const dg: SimdF64 = .{
            lookupF32AsF64(g_lut, raw_rgb[base + 1]),
            lookupF32AsF64(g_lut, raw_rgb[base + 4]),
            lookupF32AsF64(g_lut, raw_rgb[base + 7]),
            lookupF32AsF64(g_lut, raw_rgb[base + 10]),
        };
        const db: SimdF64 = .{
            lookupF32AsF64(b_lut, raw_rgb[base + 2]),
            lookupF32AsF64(b_lut, raw_rgb[base + 5]),
            lookupF32AsF64(b_lut, raw_rgb[base + 8]),
            lookupF32AsF64(b_lut, raw_rgb[base + 11]),
        };

        const out_r = @max(dr * c00 + dg * c10 + db * c20, zero);
        const out_g = @max(dr * c01 + dg * c11 + db * c21, zero);
        const out_b = @max(dr * c02 + dg * c12 + db * c22, zero);

        inline for (0..simd_width) |lane| {
            output[base + lane * 3] = out_r[lane];
            output[base + lane * 3 + 1] = out_g[lane];
            output[base + lane * 3 + 2] = out_b[lane];
        }
    }

    while (pixel < pixel_count) : (pixel += 1) {
        const base = pixel * 3;
        const transformed = film_stocks.applyLinearTerms(coeffs, .{
            lookupF32AsF64(r_lut, raw_rgb[base]),
            lookupF32AsF64(g_lut, raw_rgb[base + 1]),
            lookupF32AsF64(b_lut, raw_rgb[base + 2]),
        });
        output[base] = @max(transformed[0], 0.0);
        output[base + 1] = @max(transformed[1], 0.0);
        output[base + 2] = @max(transformed[2], 0.0);
    }
}

pub fn invertNegativeRequestFromEnvironment(environ_map: *const std.process.Environ.Map) !webgpu.Request {
    return webgpu.requestFromEnvironment(environ_map);
}

fn shouldUseCpuForInvert(options: InvertOptions) !bool {
    const should_use_cpu = try webgpu.shouldUseCpu(options.request);
    if (should_use_cpu) return true;
    const gpu_supports_options = options.dark_rgb == null and options.light_rgb == null;
    if (gpu_supports_options) return false;
    return switch (options.request.fallback) {
        .allow_cpu => true,
        .fail => error.WebGpuInvertNegativeUnsupportedOptions,
    };
}

fn canUseProvidedDminSimd(raw_rgb: []const f64, options: InvertOptions) bool {
    return options.dark_rgb == null and
        options.light_rgb == null and
        raw_rgb.len != 0 and
        raw_rgb.len % 3 == 0 and
        std.math.isFinite(options.default_light) and
        options.default_light >= measurement.eps;
}

fn validateDefaultLight(default_light: f64) !void {
    if (!std.math.isFinite(default_light) or default_light < measurement.eps) {
        return error.InvalidNormalizeReference;
    }
}

fn validateDefaultLightF32(default_light: f32) !void {
    if (!std.math.isFinite(default_light) or default_light < @as(f32, @floatCast(measurement.eps))) {
        return error.InvalidNormalizeReference;
    }
}

fn validateU16InvertBuffers(raw_rgb: []const u16, output_len: usize) !void {
    if (raw_rgb.len != output_len or raw_rgb.len == 0 or raw_rgb.len % 3 != 0) {
        return error.InvalidInversionBuffer;
    }
}

fn validateDensityLutLen(len: usize) !void {
    if (len != density_lut_len) return error.InvalidDensityLut;
}

fn fillDensityLut(comptime T: type, values: []T, dmin: [3]f64, default_light: f64) void {
    for (0..density_lut_channels) |channel| {
        const channel_values = values[channel * density_lut_entries ..][0..density_lut_entries];
        for (channel_values, 0..) |*out, sample_index| {
            const value = netDensityForRawSample(@intCast(sample_index), dmin[channel], default_light);
            out.* = switch (T) {
                f64 => value,
                f32 => @as(f32, @floatCast(value)),
                else => @compileError("unsupported density LUT value type"),
            };
        }
    }
}

fn fillDensityLutF32(values: []f32, dmin: [3]f32, default_light: f32) void {
    const eps: f32 = @floatCast(measurement.eps);
    const log2_to_log10: f32 = @floatCast(log2_to_log10_scalar);
    for (0..density_lut_channels) |channel| {
        const channel_values = values[channel * density_lut_entries ..][0..density_lut_entries];
        for (channel_values, 0..) |*out, sample_index| {
            const transmittance = @max(@as(f32, @floatFromInt(sample_index)) / default_light, eps);
            out.* = @max(-@log2(transmittance) * log2_to_log10 - dmin[channel], 0.0);
        }
    }
}

fn netDensityForRawSample(sample: u16, dmin: f64, default_light: f64) f64 {
    const transmittance = @max(@as(f64, @floatFromInt(sample)) / default_light, measurement.eps);
    return @max(-std.math.log2(transmittance) * log2_to_log10_scalar - dmin, 0.0);
}

inline fn lutIndex(sample: u16) usize {
    return @intCast(sample);
}

inline fn lookupF32AsF64(lut: []const f32, sample: u16) f64 {
    return @as(f64, @floatCast(lut[lutIndex(sample)]));
}

inline fn lookupF64SampleF32(lut: []const f32, sample: f64) f32 {
    const clamped = @min(@max(sample, 0.0), @as(f64, @floatFromInt(density_lut_entries - 1)));
    const lower: usize = @intFromFloat(@floor(clamped));
    const upper = @min(lower + 1, density_lut_entries - 1);
    const fraction: f32 = @floatCast(clamped - @as(f64, @floatFromInt(lower)));
    return lut[lower] * (1.0 - fraction) + lut[upper] * fraction;
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

const CustomInversionFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    shape: []const usize,
    tolerance: numeric.Tolerance,
    dmin: [3]f64,
    coeffs: film_stocks.Coefficients,
    input: []const f64,
    expected: []const f64,
};

const LoadedCustomInversionFixture = struct {
    parsed: std.json.Parsed(CustomInversionFixture),

    fn deinit(self: *LoadedCustomInversionFixture) void {
        self.parsed.deinit();
    }

    fn value(self: *const LoadedCustomInversionFixture) *const CustomInversionFixture {
        return &self.parsed.value;
    }
};

fn loadCustomInversionFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !LoadedCustomInversionFixture {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(text);

    var parsed = try std.json.parseFromSlice(CustomInversionFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    try numeric.validateJsonFixture(.{
        .name = parsed.value.name,
        .operation = parsed.value.operation,
        .python_oracle = parsed.value.python_oracle,
        .generated_by = parsed.value.generated_by,
        .shape = parsed.value.shape,
        .tolerance = parsed.value.tolerance,
        .input = parsed.value.input,
        .expected = parsed.value.expected,
    });
    return .{ .parsed = parsed };
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

test "inversion custom edge fixture pins EPS, Dmin, polynomial, and output clamps" {
    const allocator = std.testing.allocator;
    var fixture = try loadCustomInversionFixture(
        allocator,
        std.testing.io,
        "test/fixtures/processing/numeric/invert-negative-custom-edge-dmin.json",
    );
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    const result = try invertNegative(allocator, value.input, actual, .{
        .dmin = value.dmin,
        .coeffs = value.coeffs,
    });
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
    try numeric.assertCloseSlices(&value.dmin, &result.dmin, .{
        .abs = 0.0,
        .rel = 0.0,
        .reason = "provided Dmin pass-through",
    });
}

test "SIMD provided-Dmin inversion matches custom edge fixture" {
    const allocator = std.testing.allocator;
    var fixture = try loadCustomInversionFixture(
        allocator,
        std.testing.io,
        "test/fixtures/processing/numeric/invert-negative-custom-edge-dmin.json",
    );
    defer fixture.deinit();

    const value = fixture.value();
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);
    try invertNegativeProvidedDminSimd(
        value.input,
        actual,
        value.dmin,
        value.coeffs,
        65535.0,
    );
    try numeric.assertCloseSlices(value.expected, actual, value.tolerance);
}

test "u16 provided-Dmin inversion matches staged f64 SIMD for linear coefficients" {
    const allocator = std.testing.allocator;
    const raw_u16 = [_]u16{
        0,     512,   1024,
        8192,  16384, 24576,
        32768, 40960, 49152,
        65535, 60000, 55000,
        12345, 23456, 34567,
    };
    const raw_f64 = try allocator.alloc(f64, raw_u16.len);
    defer allocator.free(raw_f64);
    for (raw_u16, raw_f64) |sample, *out| {
        out.* = @floatFromInt(sample);
    }

    const expected = try allocator.alloc(f64, raw_u16.len);
    defer allocator.free(expected);
    const actual = try allocator.alloc(f64, raw_u16.len);
    defer allocator.free(actual);

    try invertNegativeProvidedDminSimd(
        raw_f64,
        expected,
        .{ 0.32, 0.48, 0.64 },
        film_stocks.kodak_gold_coeffs,
        65535.0,
    );
    try invertNegativeProvidedDminU16Simd(
        &raw_u16,
        actual,
        .{ 0.32, 0.48, 0.64 },
        film_stocks.kodak_gold_coeffs,
        65535.0,
    );
    try numeric.assertCloseSlices(expected, actual, .{
        .abs = 0.0,
        .rel = 0.0,
        .reason = "u16 input fusion must preserve staged f64 SIMD output",
    });
}

test "u16 provided-Dmin inversion matches staged f64 SIMD for quadratic coefficients" {
    const allocator = std.testing.allocator;
    const raw_u16 = [_]u16{
        0,     512,   1024,
        8192,  16384, 24576,
        32768, 40960, 49152,
        65535, 60000, 55000,
        12345, 23456, 34567,
    };
    const raw_f64 = try allocator.alloc(f64, raw_u16.len);
    defer allocator.free(raw_f64);
    for (raw_u16, raw_f64) |sample, *out| {
        out.* = @floatFromInt(sample);
    }

    var coeffs = film_stocks.kodak_gold_coeffs;
    coeffs[3] = .{ 0.03, -0.02, 0.01 };
    coeffs[6] = .{ 0.01, 0.02, -0.015 };
    coeffs[9] = .{ 0.05, 0.04, 0.03 };

    const expected = try allocator.alloc(f64, raw_u16.len);
    defer allocator.free(expected);
    const actual = try allocator.alloc(f64, raw_u16.len);
    defer allocator.free(actual);

    try invertNegativeProvidedDminSimd(
        raw_f64,
        expected,
        .{ 0.32, 0.48, 0.64 },
        coeffs,
        65535.0,
    );
    try invertNegativeProvidedDminU16Simd(
        &raw_u16,
        actual,
        .{ 0.32, 0.48, 0.64 },
        coeffs,
        65535.0,
    );
    try numeric.assertCloseSlices(expected, actual, .{
        .abs = 0.0,
        .rel = 0.0,
        .reason = "u16 input fusion must preserve staged f64 generic SIMD output",
    });
}

test "u16 density LUT f64 path matches direct u16 SIMD within log implementation tolerance" {
    const allocator = std.testing.allocator;
    const raw_u16 = [_]u16{
        0,     512,   1024,
        8192,  16384, 24576,
        32768, 40960, 49152,
        65535, 60000, 55000,
        12345, 23456, 34567,
    };
    const dmin = [3]f64{ 0.32, 0.48, 0.64 };
    const expected = try allocator.alloc(f64, raw_u16.len);
    defer allocator.free(expected);
    const actual = try allocator.alloc(f64, raw_u16.len);
    defer allocator.free(actual);

    try invertNegativeProvidedDminU16Simd(
        &raw_u16,
        expected,
        dmin,
        film_stocks.kodak_gold_coeffs,
        65535.0,
    );
    const lut = try DensityLutF64.init(allocator, dmin, 65535.0);
    defer lut.deinit(allocator);
    try invertNegativeProvidedDminU16WithDensityLutF64(
        &raw_u16,
        actual,
        lut,
        film_stocks.kodak_gold_coeffs,
    );
    try numeric.assertCloseSlices(expected, actual, .{
        .abs = 1e-12,
        .rel = 1e-12,
        .reason = "density LUT must preserve u16 provided-Dmin inversion",
    });
}

test "u16 density LUT f32 output stays below scene-linear tolerance" {
    const allocator = std.testing.allocator;
    const raw_u16 = [_]u16{
        0,     512,   1024,
        8192,  16384, 24576,
        32768, 40960, 49152,
        65535, 60000, 55000,
        12345, 23456, 34567,
    };
    const dmin = [3]f64{ 0.32, 0.48, 0.64 };
    const expected = try allocator.alloc(f64, raw_u16.len);
    defer allocator.free(expected);
    const actual_f32 = try allocator.alloc(f32, raw_u16.len);
    defer allocator.free(actual_f32);
    const actual = try allocator.alloc(f64, raw_u16.len);
    defer allocator.free(actual);

    try invertNegativeProvidedDminU16Simd(
        &raw_u16,
        expected,
        dmin,
        film_stocks.kodak_gold_coeffs,
        65535.0,
    );
    const lut = try DensityLutF32.init(allocator, dmin, 65535.0);
    defer lut.deinit(allocator);
    try invertNegativeProvidedDminU16WithDensityLutF32OutputF32(
        &raw_u16,
        actual_f32,
        lut,
        film_stocks.kodak_gold_coeffs,
    );
    for (actual_f32, actual) |sample, *out| {
        out.* = @floatCast(sample);
    }
    try numeric.assertCloseSlices(expected, actual, .{
        .abs = 5e-7,
        .rel = 5e-7,
        .reason = "f32 density LUT output should stay well below display code precision",
    });
}

test "provided-Dmin production CPU path matches scalar oracle" {
    const allocator = std.testing.allocator;
    var fixture = try loadCustomInversionFixture(
        allocator,
        std.testing.io,
        "test/fixtures/processing/numeric/invert-negative-custom-edge-dmin.json",
    );
    defer fixture.deinit();

    const value = fixture.value();
    const expected = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(expected);
    const actual = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(actual);

    try invertNegativeProvidedDminScalar(
        allocator,
        value.input,
        expected,
        value.dmin,
        value.coeffs,
        .{},
    );
    _ = try invertNegative(allocator, value.input, actual, .{
        .dmin = value.dmin,
        .coeffs = value.coeffs,
    });
    try numeric.assertCloseSlices(expected, actual, value.tolerance);
}

test "inversion backend request defaults to CPU parity path" {
    const allocator = std.testing.allocator;
    const input = [_]f64{
        10000.0, 20000.0, 30000.0,
        40000.0, 50000.0, 60000.0,
    };
    var expected: [input.len]f64 = undefined;
    var actual: [input.len]f64 = undefined;
    _ = try invertNegative(allocator, &input, &expected, .{
        .dmin = .{ 0.2, 0.1, 0.05 },
        .coeffs = film_stocks.kodak_gold_coeffs,
    });
    _ = try invertNegative(allocator, &input, &actual, .{
        .dmin = .{ 0.2, 0.1, 0.05 },
        .coeffs = film_stocks.kodak_gold_coeffs,
        .request = .{ .backend = .cpu },
    });
    try numeric.assertCloseSlices(&expected, &actual, .{
        .abs = 0.0,
        .rel = 0.0,
        .reason = "explicit CPU parity",
    });
}

test "inversion backend request rejects unavailable WebGPU and runs compiled GPU" {
    const allocator = std.testing.allocator;
    const input = [_]f64{ 10000.0, 20000.0, 30000.0 };
    var actual: [input.len]f64 = undefined;
    const result = invertNegative(allocator, &input, &actual, .{
        .dmin = .{ 0.2, 0.1, 0.05 },
        .coeffs = film_stocks.kodak_gold_coeffs,
        .request = .{ .backend = .webgpu },
    });
    if (webgpu.compiled) {
        _ = try result;
        var expected: [input.len]f64 = undefined;
        _ = try invertNegative(allocator, &input, &expected, .{
            .dmin = .{ 0.2, 0.1, 0.05 },
            .coeffs = film_stocks.kodak_gold_coeffs,
        });
        try numeric.assertCloseSlices(&expected, &actual, .{
            .abs = 0.000002,
            .rel = 0.000002,
            .reason = "GPU f32 parity",
        });
    } else {
        try std.testing.expectError(error.WebGpuNotCompiled, result);
    }
}

test "inversion backend request keeps unsupported dark-light options on explicit fallback CPU" {
    const allocator = std.testing.allocator;
    const input = [_]f64{ 10000.0, 20000.0, 30000.0 };
    var expected: [input.len]f64 = undefined;
    var actual: [input.len]f64 = undefined;
    _ = try invertNegative(allocator, &input, &expected, .{
        .dmin = .{ 0.2, 0.1, 0.05 },
        .coeffs = film_stocks.kodak_gold_coeffs,
        .dark_rgb = .{ 100.0, 100.0, 100.0 },
        .light_rgb = .{ 65000.0, 65000.0, 65000.0 },
    });
    _ = try invertNegative(allocator, &input, &actual, .{
        .dmin = .{ 0.2, 0.1, 0.05 },
        .coeffs = film_stocks.kodak_gold_coeffs,
        .dark_rgb = .{ 100.0, 100.0, 100.0 },
        .light_rgb = .{ 65000.0, 65000.0, 65000.0 },
        .request = .{ .backend = .webgpu, .fallback = .allow_cpu },
    });
    try numeric.assertCloseSlices(&expected, &actual, .{
        .abs = 0.0,
        .rel = 0.0,
        .reason = "unsupported GPU options fallback to CPU only when requested",
    });

    const fail_fast = invertNegative(allocator, &input, &actual, .{
        .dmin = .{ 0.2, 0.1, 0.05 },
        .coeffs = film_stocks.kodak_gold_coeffs,
        .dark_rgb = .{ 100.0, 100.0, 100.0 },
        .request = .{ .backend = .webgpu },
    });
    if (webgpu.compiled) {
        try std.testing.expectError(error.WebGpuInvertNegativeUnsupportedOptions, fail_fast);
    } else {
        try std.testing.expectError(error.WebGpuNotCompiled, fail_fast);
    }
}

test "inversion runtime request parser shares processing GPU env" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(webgpu.Backend.cpu, (try invertNegativeRequestFromEnvironment(&env)).backend);
    try env.put(webgpu.processing_gpu_env_var, "webgpu");
    try std.testing.expectEqual(webgpu.Backend.webgpu, (try invertNegativeRequestFromEnvironment(&env)).backend);
    try env.put(webgpu.processing_gpu_env_var, "bad");
    try std.testing.expectError(error.InvalidProcessingGpuEnv, invertNegativeRequestFromEnvironment(&env));
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
