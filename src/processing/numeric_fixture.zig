const std = @import("std");

pub const Tolerance = struct {
    abs: f64,
    rel: f64,
    reason: []const u8,
};

pub const JsonFixture = struct {
    name: []const u8,
    operation: []const u8,
    python_oracle: []const u8,
    generated_by: []const u8,
    shape: []const usize,
    expected_shape: ?[]const usize = null,
    tolerance: Tolerance,
    input: []const f64,
    expected: []const f64,
};

pub const LoadedJsonFixture = struct {
    parsed: std.json.Parsed(JsonFixture),

    pub fn deinit(self: *LoadedJsonFixture) void {
        self.parsed.deinit();
    }

    pub fn value(self: *const LoadedJsonFixture) *const JsonFixture {
        return &self.parsed.value;
    }
};

pub const ErrorStats = struct {
    max_abs: f64,
    max_index: usize,
    rms: f64,
};

pub fn loadJsonFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !LoadedJsonFixture {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(text);

    var parsed = try std.json.parseFromSlice(JsonFixture, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    try validateJsonFixture(parsed.value);
    return .{ .parsed = parsed };
}

pub fn validateJsonFixture(fixture: JsonFixture) !void {
    if (fixture.name.len == 0) return error.InvalidNumericFixture;
    if (fixture.operation.len == 0) return error.InvalidNumericFixture;
    if (fixture.python_oracle.len == 0) return error.InvalidNumericFixture;
    if (fixture.generated_by.len == 0) return error.InvalidNumericFixture;
    if (fixture.tolerance.reason.len == 0) return error.InvalidNumericFixture;
    if (!std.math.isFinite(fixture.tolerance.abs) or fixture.tolerance.abs < 0.0) return error.InvalidNumericFixture;
    if (!std.math.isFinite(fixture.tolerance.rel) or fixture.tolerance.rel < 0.0) return error.InvalidNumericFixture;

    const input_count = try elementCount(fixture.shape);
    const expected_count = try elementCount(fixture.expected_shape orelse fixture.shape);
    if (fixture.input.len != input_count) return error.InvalidNumericFixture;
    if (fixture.expected.len != expected_count) return error.InvalidNumericFixture;
}

pub fn assertCloseSlices(expected: []const f64, actual: []const f64, tolerance: Tolerance) !void {
    if (expected.len != actual.len) return error.ShapeMismatch;
    for (expected, actual) |expected_value, actual_value| {
        if (withinTolerance(expected_value, actual_value, tolerance)) continue;
        return error.NumericMismatch;
    }
}

pub fn errorStats(expected: []const f64, actual: []const f64) !ErrorStats {
    if (expected.len != actual.len) return error.ShapeMismatch;
    if (expected.len == 0) return .{ .max_abs = 0.0, .max_index = 0, .rms = 0.0 };

    var max_abs: f64 = 0.0;
    var max_index: usize = 0;
    var sum_sq: f64 = 0.0;
    for (expected, actual, 0..) |expected_value, actual_value, index| {
        const diff = @abs(expected_value - actual_value);
        if (diff > max_abs) {
            max_abs = diff;
            max_index = index;
        }
        sum_sq += diff * diff;
    }
    return .{
        .max_abs = max_abs,
        .max_index = max_index,
        .rms = @sqrt(sum_sq / @as(f64, @floatFromInt(expected.len))),
    };
}

pub fn withinTolerance(expected: f64, actual: f64, tolerance: Tolerance) bool {
    if (!std.math.isFinite(expected) or !std.math.isFinite(actual)) return expected == actual;
    const diff = @abs(expected - actual);
    return diff <= allowedError(expected, tolerance);
}

pub fn allowedError(expected: f64, tolerance: Tolerance) f64 {
    return tolerance.abs + tolerance.rel * @abs(expected);
}

fn elementCount(shape: []const usize) !usize {
    if (shape.len == 0) return error.InvalidNumericFixture;
    var count: usize = 1;
    for (shape) |dimension| {
        if (dimension == 0) return error.InvalidNumericFixture;
        count = std.math.mul(usize, count, dimension) catch return error.InvalidNumericFixture;
    }
    return count;
}

test "loads numeric JSON fixture and validates tolerance metadata" {
    const allocator = std.testing.allocator;
    var fixture = try loadJsonFixture(allocator, std.testing.io, "test/fixtures/processing/numeric/linear-scale-smoke.json");
    defer fixture.deinit();

    const value = fixture.value();
    try std.testing.expectEqualStrings("linear-scale-smoke", value.name);
    try std.testing.expectEqualStrings("synthetic_linear_scale", value.operation);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, value.shape);
    try std.testing.expectEqual(@as(usize, 6), value.expected.len);

    const actual = [_]f64{ 0.25, 1.75, 3.25, 4.75, 6.2500004, 7.75 };
    try assertCloseSlices(value.expected, &actual, value.tolerance);
}

test "numeric close assertion reports shape and value mismatches" {
    const tolerance: Tolerance = .{ .abs = 0.000001, .rel = 0.000001, .reason = "unit test tolerance" };
    try std.testing.expectError(error.ShapeMismatch, assertCloseSlices(&.{1.0}, &.{ 1.0, 2.0 }, tolerance));
    try std.testing.expectError(error.NumericMismatch, assertCloseSlices(&.{1.0}, &.{1.01}, tolerance));
}

test "numeric error stats include max absolute error and RMS" {
    const stats = try errorStats(&.{ 1.0, 2.0, 3.0 }, &.{ 1.0, 2.5, 2.5 });
    try std.testing.expectEqual(@as(usize, 1), stats.max_index);
    try std.testing.expectApproxEqAbs(0.5, stats.max_abs, 0.000001);
    try std.testing.expectApproxEqAbs(@sqrt(0.5 / 3.0), stats.rms, 0.000001);
}

test "numeric fixture validation rejects missing metadata and wrong shape" {
    const shape = [_]usize{ 2, 2 };
    const input = [_]f64{ 1.0, 2.0, 3.0 };
    const expected = [_]f64{ 1.0, 2.0, 3.0 };
    const invalid: JsonFixture = .{
        .name = "bad",
        .operation = "bad",
        .python_oracle = "synthetic",
        .generated_by = "unit test",
        .shape = &shape,
        .tolerance = .{ .abs = 0.0, .rel = 0.0, .reason = "unit test" },
        .input = &input,
        .expected = &expected,
    };
    try std.testing.expectError(error.InvalidNumericFixture, validateJsonFixture(invalid));
}
