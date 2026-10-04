const std = @import("std");
const cerealgrain = @import("cerealgrain");

const color = cerealgrain.processing.color;
const webgpu = cerealgrain.processing.webgpu;

const Case = struct {
    name: []const u8,
    width: usize,
    height: usize,
    cpu_iterations: usize,
    gpu_e2e_iterations: usize,
    gpu_resident_iterations: usize,
};

const cases = [_]Case{
    .{
        .name = "preview_1024x768",
        .width = 1024,
        .height = 768,
        .cpu_iterations = 2,
        .gpu_e2e_iterations = 3,
        .gpu_resident_iterations = 20,
    },
    .{
        .name = "export_frame_2048x3072",
        .width = 2048,
        .height = 3072,
        .cpu_iterations = 1,
        .gpu_e2e_iterations = 1,
        .gpu_resident_iterations = 10,
    },
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print(
        "benchmark,input,width,height,pixels,samples,bytes_uploaded,bytes_downloaded,backend,adapter,cpu_iterations,cpu_ns,gpu_e2e_iterations,gpu_e2e_ns,gpu_resident_iterations,gpu_resident_ns,e2e_speedup_x1000,resident_speedup_x1000,checksum\n",
        .{},
    );
    for (cases) |case| {
        try runCase(allocator, stdout, case);
    }
}

fn runCase(allocator: std.mem.Allocator, stdout: anytype, case: Case) !void {
    const pixel_count = try std.math.mul(usize, case.width, case.height);
    const sample_count = try std.math.mul(usize, pixel_count, 3);

    const input = try allocator.alloc(f64, sample_count);
    defer allocator.free(input);
    const output = try allocator.alloc(f64, sample_count);
    defer allocator.free(output);
    fillScene(input, case.width);

    const params = color.DarktableSigmoidParams{
        .middle_grey_contrast = 1.5,
        .contrast_skewness = -0.25,
        .display_white_target = 5.0,
        .display_black_target = 0.015,
        .color_processing = 2,
        .hue_preservation = 0.65,
    };
    const committed = color.sigmoidCommitParams(params);

    const cpu_start = monotonicNowNs();
    for (0..case.cpu_iterations) |_| {
        try color.applySigmoid(input, output, params);
    }
    const cpu_ns = monotonicNowNs() - cpu_start;

    const gpu = try webgpu.benchmarkApplySigmoidKernel(allocator, input, .{
        .white_target = committed.white_target,
        .paper_exposure = committed.paper_exposure,
        .film_fog = committed.film_fog,
        .film_power = committed.film_power,
        .paper_power = committed.paper_power,
    }, .{
        .e2e_iterations = case.gpu_e2e_iterations,
        .resident_iterations = case.gpu_resident_iterations,
    });
    defer gpu.deinit(allocator);

    const cpu_per_iter = nsPerIteration(cpu_ns, case.cpu_iterations);
    const gpu_e2e_per_iter = nsPerIteration(gpu.gpu_e2e_ns, case.gpu_e2e_iterations);
    const gpu_resident_per_iter = nsPerIteration(gpu.gpu_resident_ns, case.gpu_resident_iterations);

    try stdout.print(
        "apply_sigmoid,{s},{d},{d},{d},{d},{d},{d},{s},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n",
        .{
            case.name,
            case.width,
            case.height,
            pixel_count,
            sample_count,
            gpu.bytes_uploaded,
            gpu.bytes_downloaded,
            gpu.backend,
            gpu.adapter,
            case.cpu_iterations,
            cpu_ns,
            case.gpu_e2e_iterations,
            gpu.gpu_e2e_ns,
            case.gpu_resident_iterations,
            gpu.gpu_resident_ns,
            speedupX1000(cpu_per_iter, gpu_e2e_per_iter),
            speedupX1000(cpu_per_iter, gpu_resident_per_iter),
            checksumF64(output),
        },
    );
}

fn fillScene(buffer: []f64, width: usize) void {
    for (buffer, 0..) |*value, sample_index| {
        const pixel = sample_index / 3;
        const channel = sample_index % 3;
        const x = pixel % width;
        const y = pixel / width;
        const pattern = (x * 31 + y * 17 + channel * 13) % 10_250;
        value.* = @as(f64, @floatFromInt(pattern)) / 1000.0 - 0.25;
    }
}

fn nsPerIteration(elapsed_ns: u64, iterations: usize) u64 {
    return elapsed_ns / iterations;
}

fn speedupX1000(cpu_ns: u64, gpu_ns: u64) u64 {
    if (gpu_ns == 0) return std.math.maxInt(u64);
    return cpu_ns * 1000 / gpu_ns;
}

fn checksumF64(output: []const f64) i64 {
    var sum: f64 = 0.0;
    for (output) |value| {
        sum += value;
    }
    return @intFromFloat(@round(sum * 1_000.0));
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
