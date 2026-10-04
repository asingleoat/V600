const std = @import("std");
const cerealgrain = @import("cerealgrain");

const ir = cerealgrain.processing.ir;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const width: usize = 52;
    const height: usize = 52;
    const channels: usize = 3;
    const pixels = width * height;
    const image = try allocator.alloc(f64, pixels * channels);
    defer allocator.free(image);
    const mask = try allocator.alloc(u8, pixels);
    defer allocator.free(mask);
    const output = try allocator.alloc(f64, image.len);
    defer allocator.free(output);

    @memset(mask, 0);
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = y * width + x;
            const xf: f64 = @floatFromInt(x);
            const yf: f64 = @floatFromInt(y);
            image[pixel * channels] = 0.1 + xf * 0.007 + yf * 0.003;
            image[pixel * channels + 1] = 0.2 + xf * 0.002 + yf * 0.005;
            image[pixel * channels + 2] = 0.3 + xf * 0.004 - yf * 0.001;
            if (x >= 6 and x < 46 and y >= 6 and y < 46) {
                mask[pixel] = 255;
            }
        }
    }

    try ir.biharmonicInpaint(allocator, image, mask, width, height, channels, output);

    var best_ns: u64 = std.math.maxInt(u64);
    var total_ns: u128 = 0;
    const runs: usize = 25;
    for (0..runs) |_| {
        const start = monotonicNanos();
        try ir.biharmonicInpaint(allocator, image, mask, width, height, channels, output);
        const elapsed = monotonicNanos() - start;
        best_ns = @min(best_ns, elapsed);
        total_ns += elapsed;
    }

    var max_error: f64 = 0.0;
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = y * width + x;
            if (mask[pixel] == 0) continue;
            for (0..channels) |channel| {
                max_error = @max(max_error, @abs(output[pixel * channels + channel] - image[pixel * channels + channel]));
            }
        }
    }
    if (max_error > 1e-6) return error.IrInpaintBenchmarkMismatch;
    const python_baseline_best_ns: u64 = 4_860_013;
    if (best_ns >= python_baseline_best_ns) return error.IrInpaintBenchmarkRegression;

    const average_ns = total_ns / runs;
    try stdout.print(
        "ir_biharmonic_sparse_affine unknowns=1600 runs={d} best_ms={d:.3} avg_ms={d:.3} python_best_ms={d:.3} max_error={d:.12}\n",
        .{
            runs,
            @as(f64, @floatFromInt(best_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(average_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(python_baseline_best_ns)) / 1_000_000.0,
            max_error,
        },
    );
}

fn monotonicNanos() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
