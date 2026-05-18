const std = @import("std");
const v600 = @import("v600");

const color = v600.processing.color;
const numeric = v600.processing.numeric_fixture;
const webgpu = v600.processing.webgpu;

const fixture_path = "test/fixtures/processing/numeric/apply-darktable-sigmoid.json";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var fixture = try numeric.loadJsonFixture(allocator, init.io, fixture_path);
    defer fixture.deinit();
    const value = fixture.value();

    const params = color.DarktableSigmoidParams{
        .middle_grey_contrast = 1.5,
        .contrast_skewness = -0.25,
        .display_white_target = 5.0,
        .display_black_target = 0.015,
        .color_processing = 2,
        .hue_preservation = 0.65,
    };
    const committed = color.sigmoidCommitParams(params);

    const cpu_output = try allocator.alloc(f64, value.expected.len);
    defer allocator.free(cpu_output);
    try color.applySigmoid(value.input, cpu_output, params);
    try numeric.assertCloseSlices(value.expected, cpu_output, value.tolerance);

    const gpu_output = try webgpu.applySigmoidKernel(allocator, value.input, .{
        .white_target = committed.white_target,
        .paper_exposure = committed.paper_exposure,
        .film_fog = committed.film_fog,
        .film_power = committed.film_power,
        .paper_power = committed.paper_power,
    }, .{});
    defer allocator.free(gpu_output);

    const stats = try numeric.errorStats(cpu_output, gpu_output);
    if (numeric.assertCloseSlices(cpu_output, gpu_output, value.tolerance)) {
        try stdout.print(
            "webgpu_sigmoid_compare,status,ok,count,{d},max_abs,{d:.9},max_index,{d},rms,{d:.9},tolerance_abs,{d:.9},tolerance_rel,{d:.9}\n",
            .{
                gpu_output.len,
                stats.max_abs,
                stats.max_index,
                stats.rms,
                value.tolerance.abs,
                value.tolerance.rel,
            },
        );
    } else |err| {
        try stdout.print(
            "webgpu_sigmoid_compare,status,mismatch,count,{d},max_abs,{d:.9},max_index,{d},rms,{d:.9},tolerance_abs,{d:.9},tolerance_rel,{d:.9}\n",
            .{
                gpu_output.len,
                stats.max_abs,
                stats.max_index,
                stats.rms,
                value.tolerance.abs,
                value.tolerance.rel,
            },
        );
        return err;
    }
}
