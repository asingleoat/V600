const std = @import("std");
const v600 = @import("v600");

const film_stocks = v600.processing.film_stocks;
const inversion = v600.processing.inversion;
const numeric = v600.processing.numeric_fixture;
const webgpu = v600.processing.webgpu;

const FixtureCase = struct {
    path: []const u8,
    dmin: [3]f64,
    coeffs: film_stocks.Coefficients,
};

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

const builtin_cases = [_]FixtureCase{
    .{
        .path = "test/fixtures/processing/numeric/invert-negative-identity-dmin.json",
        .dmin = .{ 0.2, 0.1, 0.05 },
        .coeffs = film_stocks.identity_coeffs,
    },
    .{
        .path = "test/fixtures/processing/numeric/invert-negative-kodak-gold-dmin.json",
        .dmin = .{ 0.2, 0.1, 0.05 },
        .coeffs = film_stocks.kodak_gold_coeffs,
    },
};

const custom_path = "test/fixtures/processing/numeric/invert-negative-custom-edge-dmin.json";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    for (builtin_cases) |case| {
        try compareBuiltinFixture(allocator, init.io, stdout, case);
    }
    try compareCustomFixture(allocator, init.io, stdout, custom_path);
}

fn compareBuiltinFixture(allocator: std.mem.Allocator, io: std.Io, stdout: anytype, case: FixtureCase) !void {
    var fixture = try numeric.loadJsonFixture(allocator, io, case.path);
    defer fixture.deinit();
    const value = fixture.value();
    try compareFixture(
        allocator,
        stdout,
        std.fs.path.stem(std.fs.path.basename(case.path)),
        value.input,
        value.expected,
        value.tolerance,
        case.dmin,
        case.coeffs,
    );
}

fn compareCustomFixture(allocator: std.mem.Allocator, io: std.Io, stdout: anytype, path: []const u8) !void {
    var fixture = try loadCustomInversionFixture(allocator, io, path);
    defer fixture.deinit();
    const value = fixture.value();
    try compareFixture(
        allocator,
        stdout,
        value.name,
        value.input,
        value.expected,
        value.tolerance,
        value.dmin,
        value.coeffs,
    );
}

fn compareFixture(
    allocator: std.mem.Allocator,
    stdout: anytype,
    name: []const u8,
    input: []const f64,
    expected: []const f64,
    tolerance: numeric.Tolerance,
    dmin: [3]f64,
    coeffs: film_stocks.Coefficients,
) !void {
    const cpu_output = try allocator.alloc(f64, expected.len);
    defer allocator.free(cpu_output);
    _ = try inversion.invertNegative(allocator, input, cpu_output, .{
        .dmin = dmin,
        .coeffs = coeffs,
    });
    try numeric.assertCloseSlices(expected, cpu_output, tolerance);

    const gpu_output = try webgpu.applyInvertNegativeKernel(allocator, input, .{
        .dmin = dmin,
        .coeffs = coeffs,
    }, .{});
    defer allocator.free(gpu_output);

    const stats = try numeric.errorStats(cpu_output, gpu_output);
    if (numeric.assertCloseSlices(cpu_output, gpu_output, tolerance)) {
        try stdout.print(
            "webgpu_invert_negative_compare,status,ok,fixture,{s},count,{d},max_abs,{d:.9},max_index,{d},rms,{d:.9},tolerance_abs,{d:.9},tolerance_rel,{d:.9}\n",
            .{
                name,
                gpu_output.len,
                stats.max_abs,
                stats.max_index,
                stats.rms,
                tolerance.abs,
                tolerance.rel,
            },
        );
    } else |err| {
        try stdout.print(
            "webgpu_invert_negative_compare,status,mismatch,fixture,{s},count,{d},max_abs,{d:.9},max_index,{d},rms,{d:.9},tolerance_abs,{d:.9},tolerance_rel,{d:.9}\n",
            .{
                name,
                gpu_output.len,
                stats.max_abs,
                stats.max_index,
                stats.rms,
                tolerance.abs,
                tolerance.rel,
            },
        );
        return err;
    }
}

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
