const std = @import("std");
const v600 = @import("v600");

const color = v600.processing.color;
const film_stocks = v600.processing.film_stocks;
const gpu_boundary = v600.processing.gpu_boundary;
const inversion = v600.processing.inversion;
const render = v600.processing.render;

const pixel_count: usize = 4096;
const color_iterations: usize = 256;
const transform_iterations: usize = 128;
const render_iterations: usize = 16;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var gate = false;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--gpu-readiness-gate")) {
            gate = true;
        } else {
            return error.UnknownBenchmarkArg;
        }
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const len = pixel_count * 3;
    const scene = try allocator.alloc(f64, len);
    defer allocator.free(scene);
    const raw = try allocator.alloc(f64, len);
    defer allocator.free(raw);
    const raw_u16 = try allocator.alloc(u16, len);
    defer allocator.free(raw_u16);
    const out = try allocator.alloc(f64, len);
    defer allocator.free(out);
    const out_u16 = try allocator.alloc(u16, len);
    defer allocator.free(out_u16);
    const out_u8 = try allocator.alloc(u8, len);
    defer allocator.free(out_u8);

    fillScene(scene);
    fillRaw(raw);
    fillRawU16(raw_u16);

    var coverage = BenchmarkCoverage{};
    try stdout.print("benchmark,pixels,iterations,total_ns,ns_per_pixel_x1000,checksum\n", .{});
    try benchSrgbToLinear(stdout, scene, out);
    coverage.mark("srgb_to_linear");
    try benchLinearToSrgb(stdout, scene, out);
    coverage.mark("linear_to_srgb");
    try benchColorMatrix(stdout, scene, out);
    coverage.mark("apply_color_matrix");
    try benchDensityTransform(stdout, scene, out);
    coverage.mark("apply_density_transform");
    try benchInvertNegativeScalar(stdout, allocator, raw, out);
    try benchInvertNegative(stdout, allocator, raw, out);
    coverage.mark("invert_negative");
    try benchInvertNegativeSimd(stdout, raw, out);
    try benchInvertNegativeU16Simd(stdout, raw_u16, out);
    try benchDarktableSigmoid(stdout, scene, out);
    coverage.mark("apply_sigmoid");
    try benchNegadoctor(stdout, raw, out);
    coverage.mark("negadoctor");
    try benchRenderToDisplay(stdout, allocator, scene, out_u16);
    coverage.mark("render_to_display");
    try benchRenderToDisplayU16ThenU8(stdout, allocator, scene, out_u16, out_u8);
    try benchRenderToDisplayU8(stdout, allocator, scene, out_u8);
    if (gate) {
        try coverage.validateGpuReadiness(stdout);
    }
}

fn fillScene(buffer: []f64) void {
    var index: usize = 0;
    while (index < buffer.len) : (index += 3) {
        const pixel: f64 = @floatFromInt(index / 3);
        buffer[index] = @mod(pixel * 0.013, 2.0);
        buffer[index + 1] = @mod(pixel * 0.017 + 0.05, 2.0);
        buffer[index + 2] = @mod(pixel * 0.019 + 0.10, 2.0);
    }
}

fn fillRaw(buffer: []f64) void {
    for (buffer, 0..) |*value, index| {
        value.* = @floatFromInt(1024 + ((index * 7919) % 62000));
    }
}

fn fillRawU16(buffer: []u16) void {
    for (buffer, 0..) |*value, index| {
        value.* = @intCast(1024 + ((index * 7919) % 62000));
    }
}

fn benchSrgbToLinear(stdout: anytype, input: []const f64, output: []f64) !void {
    const start = monotonicNowNs();
    for (0..color_iterations) |_| {
        try color.srgbToLinear(input, output);
    }
    try reportF64(stdout, "srgb_to_linear", color_iterations, monotonicNowNs() - start, output);
}

fn benchLinearToSrgb(stdout: anytype, input: []const f64, output: []f64) !void {
    const start = monotonicNowNs();
    for (0..color_iterations) |_| {
        try color.linearToSrgb(input, output);
    }
    try reportF64(stdout, "linear_to_srgb", color_iterations, monotonicNowNs() - start, output);
}

fn benchColorMatrix(stdout: anytype, input: []const f64, output: []f64) !void {
    const start = monotonicNowNs();
    for (0..color_iterations) |_| {
        try color.applyColorMatrix(input, output, color.m_srgb_to_rec2020_d50);
    }
    try reportF64(stdout, "color_matrix_rec2020", color_iterations, monotonicNowNs() - start, output);
}

fn benchDensityTransform(stdout: anytype, input: []const f64, output: []f64) !void {
    const start = monotonicNowNs();
    for (0..transform_iterations) |_| {
        try film_stocks.applyDensityTransform(input, output, film_stocks.kodak_gold_coeffs);
    }
    try reportF64(stdout, "density_transform_kodak_gold", transform_iterations, monotonicNowNs() - start, output);
}

fn benchInvertNegative(
    stdout: anytype,
    allocator: std.mem.Allocator,
    input: []const f64,
    output: []f64,
) !void {
    const start = monotonicNowNs();
    for (0..transform_iterations) |_| {
        _ = try inversion.invertNegative(allocator, input, output, .{
            .dmin = .{ 0.32, 0.48, 0.64 },
            .coeffs = film_stocks.kodak_gold_coeffs,
        });
    }
    try reportF64(stdout, "invert_negative", transform_iterations, monotonicNowNs() - start, output);
}

fn benchInvertNegativeScalar(
    stdout: anytype,
    allocator: std.mem.Allocator,
    input: []const f64,
    output: []f64,
) !void {
    const start = monotonicNowNs();
    for (0..transform_iterations) |_| {
        try inversion.invertNegativeProvidedDminScalar(
            allocator,
            input,
            output,
            .{ 0.32, 0.48, 0.64 },
            film_stocks.kodak_gold_coeffs,
            .{ .default_light = 65535.0 },
        );
    }
    try reportF64(stdout, "invert_negative_scalar", transform_iterations, monotonicNowNs() - start, output);
}

fn benchInvertNegativeSimd(stdout: anytype, input: []const f64, output: []f64) !void {
    const start = monotonicNowNs();
    for (0..transform_iterations) |_| {
        try inversion.invertNegativeProvidedDminSimd(
            input,
            output,
            .{ 0.32, 0.48, 0.64 },
            film_stocks.kodak_gold_coeffs,
            65535.0,
        );
    }
    try reportF64(stdout, "invert_negative_simd", transform_iterations, monotonicNowNs() - start, output);
}

fn benchInvertNegativeU16Simd(stdout: anytype, input: []const u16, output: []f64) !void {
    const start = monotonicNowNs();
    for (0..transform_iterations) |_| {
        try inversion.invertNegativeProvidedDminU16Simd(
            input,
            output,
            .{ 0.32, 0.48, 0.64 },
            film_stocks.kodak_gold_coeffs,
            65535.0,
        );
    }
    try reportF64(stdout, "invert_negative_u16_simd", transform_iterations, monotonicNowNs() - start, output);
}

fn benchDarktableSigmoid(stdout: anytype, input: []const f64, output: []f64) !void {
    const params = color.DarktableSigmoidParams{
        .middle_grey_contrast = 1.5,
        .contrast_skewness = -0.25,
        .display_white_target = 5.0,
        .display_black_target = 0.015,
        .color_processing = 2,
        .hue_preservation = 0.65,
    };
    const start = monotonicNowNs();
    for (0..transform_iterations) |_| {
        try color.applySigmoid(input, output, params);
    }
    try reportF64(stdout, "darktable_sigmoid", transform_iterations, monotonicNowNs() - start, output);
}

fn benchNegadoctor(stdout: anytype, input: []const f64, output: []f64) !void {
    const params = color.NegadoctorParams{
        .film_stock = 1,
        .dmin = .{ 0.11, 0.22, 0.33 },
        .wb_high = .{ 1.10, 1.20, 1.30 },
        .wb_low = .{ 0.01, 0.02, 0.03 },
        .d_max = 2.5,
        .offset = 0.125,
        .black = 0.015,
        .gamma = 1.7,
        .soft_clip = 0.85,
        .exposure = 1.25,
    };
    const start = monotonicNowNs();
    for (0..transform_iterations) |_| {
        try color.negadoctor(input, output, params);
    }
    try reportF64(stdout, "negadoctor", transform_iterations, monotonicNowNs() - start, output);
}

fn benchRenderToDisplay(stdout: anytype, allocator: std.mem.Allocator, input: []const f64, output: []u16) !void {
    const start = monotonicNowNs();
    for (0..render_iterations) |_| {
        try render.renderToDisplay(allocator, input, output, .{
            .contrast = 1.8,
            .percentile_lo = 0.5,
            .percentile_hi = 99.5,
            .exposure_compensation = 0.15,
            .color_temp = 0.1,
            .color_tint = -0.05,
        });
    }
    try reportU16(stdout, "render_to_display", render_iterations, monotonicNowNs() - start, output);
}

fn benchRenderToDisplayU16ThenU8(
    stdout: anytype,
    allocator: std.mem.Allocator,
    input: []const f64,
    output_u16: []u16,
    output_u8: []u8,
) !void {
    const start = monotonicNowNs();
    for (0..render_iterations) |_| {
        try render.renderToDisplay(allocator, input, output_u16, .{
            .contrast = 1.8,
            .percentile_lo = 0.5,
            .percentile_hi = 99.5,
            .exposure_compensation = 0.15,
            .color_temp = 0.1,
            .color_tint = -0.05,
        });
        for (output_u16, output_u8) |value, *out| {
            out.* = @intCast(value >> 8);
        }
    }
    try reportU8(stdout, "render_to_display_u16_then_u8", render_iterations, monotonicNowNs() - start, output_u8);
}

fn benchRenderToDisplayU8(stdout: anytype, allocator: std.mem.Allocator, input: []const f64, output: []u8) !void {
    const start = monotonicNowNs();
    for (0..render_iterations) |_| {
        try render.renderToDisplayU8(allocator, input, output, .{
            .contrast = 1.8,
            .percentile_lo = 0.5,
            .percentile_hi = 99.5,
            .exposure_compensation = 0.15,
            .color_temp = 0.1,
            .color_tint = -0.05,
        });
    }
    try reportU8(stdout, "render_to_display_u8", render_iterations, monotonicNowNs() - start, output);
}

fn reportF64(stdout: anytype, name: []const u8, iterations: usize, elapsed_ns: u64, output: []const f64) !void {
    try stdout.print("{s},{d},{d},{d},{d},{d}\n", .{
        name,
        pixel_count,
        iterations,
        elapsed_ns,
        nsPerPixelX1000(elapsed_ns, iterations),
        checksumF64(output),
    });
}

fn reportU16(stdout: anytype, name: []const u8, iterations: usize, elapsed_ns: u64, output: []const u16) !void {
    try stdout.print("{s},{d},{d},{d},{d},{d}\n", .{
        name,
        pixel_count,
        iterations,
        elapsed_ns,
        nsPerPixelX1000(elapsed_ns, iterations),
        checksumU16(output),
    });
}

fn reportU8(stdout: anytype, name: []const u8, iterations: usize, elapsed_ns: u64, output: []const u8) !void {
    try stdout.print("{s},{d},{d},{d},{d},{d}\n", .{
        name,
        pixel_count,
        iterations,
        elapsed_ns,
        nsPerPixelX1000(elapsed_ns, iterations),
        checksumU8(output),
    });
}

fn nsPerPixelX1000(elapsed_ns: u64, iterations: usize) u64 {
    return elapsed_ns * 1000 / (pixel_count * iterations);
}

fn checksumF64(output: []const f64) i64 {
    var sum: f64 = 0.0;
    for (output) |value| {
        sum += value;
    }
    return @intFromFloat(@round(sum * 1_000_000.0));
}

fn checksumU16(output: []const u16) u64 {
    var sum: u64 = 0;
    for (output) |value| {
        sum +%= value;
    }
    return sum;
}

fn checksumU8(output: []const u8) u64 {
    var sum: u64 = 0;
    for (output) |value| {
        sum +%= value;
    }
    return sum;
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const BenchmarkCoverage = struct {
    srgb_to_linear: bool = false,
    linear_to_srgb: bool = false,
    apply_color_matrix: bool = false,
    apply_density_transform: bool = false,
    invert_negative: bool = false,
    apply_sigmoid: bool = false,
    negadoctor: bool = false,
    render_to_display: bool = false,

    fn mark(self: *BenchmarkCoverage, candidate_name: []const u8) void {
        if (std.mem.eql(u8, candidate_name, "srgb_to_linear")) {
            self.srgb_to_linear = true;
        } else if (std.mem.eql(u8, candidate_name, "linear_to_srgb")) {
            self.linear_to_srgb = true;
        } else if (std.mem.eql(u8, candidate_name, "apply_color_matrix")) {
            self.apply_color_matrix = true;
        } else if (std.mem.eql(u8, candidate_name, "apply_density_transform")) {
            self.apply_density_transform = true;
        } else if (std.mem.eql(u8, candidate_name, "invert_negative")) {
            self.invert_negative = true;
        } else if (std.mem.eql(u8, candidate_name, "apply_sigmoid")) {
            self.apply_sigmoid = true;
        } else if (std.mem.eql(u8, candidate_name, "negadoctor")) {
            self.negadoctor = true;
        } else if (std.mem.eql(u8, candidate_name, "render_to_display")) {
            self.render_to_display = true;
        }
    }

    fn has(self: BenchmarkCoverage, candidate_name: []const u8) bool {
        if (std.mem.eql(u8, candidate_name, "srgb_to_linear")) return self.srgb_to_linear;
        if (std.mem.eql(u8, candidate_name, "linear_to_srgb")) return self.linear_to_srgb;
        if (std.mem.eql(u8, candidate_name, "apply_color_matrix")) return self.apply_color_matrix;
        if (std.mem.eql(u8, candidate_name, "apply_density_transform")) return self.apply_density_transform;
        if (std.mem.eql(u8, candidate_name, "invert_negative")) return self.invert_negative;
        if (std.mem.eql(u8, candidate_name, "apply_sigmoid")) return self.apply_sigmoid;
        if (std.mem.eql(u8, candidate_name, "negadoctor")) return self.negadoctor;
        if (std.mem.eql(u8, candidate_name, "render_to_display")) return self.render_to_display;
        return false;
    }

    fn validateGpuReadiness(self: BenchmarkCoverage, stdout: anytype) !void {
        var active_candidates: usize = 0;
        var benchmarked_candidates: usize = 0;
        for (gpu_boundary.gpu_kernel_candidates) |candidate| {
            try gpu_boundary.validateGpuCandidate(candidate);
            if (candidate.priority == .deferred) continue;
            active_candidates += 1;
            if (!self.has(candidate.name)) return error.MissingGpuCandidateBenchmark;
            benchmarked_candidates += 1;
        }
        try stdout.print("gpu_readiness_gate,active_candidates,{d},benchmarked_candidates,{d}\n", .{
            active_candidates,
            benchmarked_candidates,
        });
    }
};
