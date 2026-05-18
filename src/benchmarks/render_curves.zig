const std = @import("std");
const v600 = @import("v600");

const film_stocks = v600.processing.film_stocks;
const inversion = v600.processing.inversion;
const render = v600.processing.render;
const workflow = v600.processing.workflow;

const default_scan = "scans/scan_0004_rgbir_3200dpi.tiff";
const benchmark_stock_dmin = [3]f64{ 0.3229871988296509, 0.48254984617233276, 0.6367867588996887 };
const default_preview_max_px: usize = 8192;
const default_iterations: usize = 1;
const fit_sample_count: usize = 4096;
const curve_error_sample_count: usize = 65_536;
const max_poly_terms: usize = 12;

const BenchOptions = struct {
    scan_path: []const u8 = default_scan,
    iterations: usize = default_iterations,
};

const CurveConstants = struct {
    k: f64,
    lo: f64,
    hi: f64,
    denominator: f64,
};

const Polynomial = struct {
    degree: usize,
    terms: usize,
    q: [max_poly_terms]f64,
};

const DiffSummary = struct {
    max_abs: u64,
    rms: f64,
    mismatches: usize,
};

const CurveError = struct {
    max_abs: f64,
    rms: f64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const options = try parseArgs(allocator, init);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print("benchmark,input,width,height,units,elapsed_us,detail\n", .{});

    if (!scanExists(init.io, options.scan_path)) {
        try stdout.print("render_curve_transform,{s},0,0,0,0,skipped_missing_scan\n", .{options.scan_path});
        return;
    }

    var preview = try workflow.loadQuickPreview(allocator, options.scan_path, default_preview_max_px);
    defer preview.deinit(allocator);
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, preview.preview_width, preview.preview_height), 3);
    if (preview.preview_raw.len != sample_count) return error.InvalidPreviewBuffer;

    const scene = try allocator.alloc(f64, sample_count);
    defer allocator.free(scene);
    try inversion.invertNegativeProvidedDminU16Simd(
        preview.preview_raw,
        scene,
        benchmark_stock_dmin,
        film_stocks.kodak_gold_coeffs,
        65535.0,
    );

    const render_options: render.RenderToDisplayOptions = .{};
    const range = try render.estimateDisplayLuminanceRange(allocator, scene, render_options);
    const constants = contrastCurveConstants((render_options.contrast - 1.0) * render_options.curve_k);

    const production = try allocator.alloc(u8, sample_count);
    defer allocator.free(production);
    const production_u16 = try allocator.alloc(u16, sample_count);
    defer allocator.free(production_u16);
    renderExact(scene, production, range, constants);
    renderExactU16(scene, production_u16, range, constants);

    const output = try allocator.alloc(u8, sample_count);
    defer allocator.free(output);
    const output_u16 = try allocator.alloc(u16, sample_count);
    defer allocator.free(output_u16);

    try benchExact(stdout, options, preview, scene, production, production_u16, output, output_u16, range, constants);
    const nearest_entries = [_]usize{ 16, 32, 64, 128, 256, 512, 1024 };
    for (nearest_entries) |entries| {
        try benchLutU8(stdout, allocator, options, preview, scene, production, output, range, constants, entries);
    }
    for (nearest_entries) |entries| {
        try benchLutU16(stdout, allocator, options, preview, scene, production_u16, output_u16, range, constants, entries);
    }
    const linear_entries = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };
    for (linear_entries) |entries| {
        try benchLutLinearF32(stdout, allocator, options, preview, scene, production, production_u16, output, output_u16, range, constants, entries);
    }
    try benchPolynomial(stdout, options, preview, scene, production, production_u16, output, output_u16, range, constants, 3);
    try benchPolynomial(stdout, options, preview, scene, production, production_u16, output, output_u16, range, constants, 5);
    try benchPolynomial(stdout, options, preview, scene, production, production_u16, output, output_u16, range, constants, 7);
    try benchPolynomial(stdout, options, preview, scene, production, production_u16, output, output_u16, range, constants, 9);
}

fn parseArgs(allocator: std.mem.Allocator, init: std.process.Init) !BenchOptions {
    var options = BenchOptions{};
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--scan")) {
            options.scan_path = args.next() orelse return error.MissingScanPath;
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            const value = args.next() orelse return error.MissingIterationCount;
            options.iterations = try std.fmt.parseInt(usize, value, 10);
        } else {
            return error.UnknownBenchmarkArg;
        }
    }
    options.iterations = @max(options.iterations, 1);
    return options;
}

fn scanExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn benchExact(
    stdout: anytype,
    options: BenchOptions,
    preview: workflow.QuickPreview,
    scene: []const f64,
    production: []const u8,
    production_u16: []const u16,
    output: []u8,
    output_u16: []u16,
    range: render.LuminanceRange,
    constants: CurveConstants,
) !void {
    const started = monotonicNowNs();
    for (0..options.iterations) |_| {
        renderExact(scene, output, range, constants);
    }
    const elapsed = monotonicNowNs() - started;
    const diff = try compareU8(production, output);
    if (diff.max_abs != 0) return error.ExactCurveHarnessMismatch;
    try printResult(stdout, "render_curve_preview_u8", "exact_logistic", options, preview, elapsed, diff, 0, "curve_max_abs=0;curve_rms=0;checksum={d}", .{checksumU8(output)});

    const u16_started = monotonicNowNs();
    for (0..options.iterations) |_| {
        renderExactU16(scene, output_u16, range, constants);
    }
    const u16_elapsed = monotonicNowNs() - u16_started;
    const u16_diff = try compareU16(production_u16, output_u16);
    if (u16_diff.max_abs != 0) return error.ExactCurveHarnessMismatch;
    try printResult(stdout, "render_curve_export_u16", "exact_logistic", options, preview, u16_elapsed, u16_diff, 0, "curve_max_abs=0;curve_rms=0;checksum={d}", .{checksumU16(output_u16)});
}

fn benchLutU8(
    stdout: anytype,
    allocator: std.mem.Allocator,
    options: BenchOptions,
    preview: workflow.QuickPreview,
    scene: []const f64,
    production: []const u8,
    output: []u8,
    range: render.LuminanceRange,
    constants: CurveConstants,
    entries: usize,
) !void {
    const table = try allocator.alloc(u8, entries);
    defer allocator.free(table);
    const build_started = monotonicNowNs();
    fillLutU8(table, constants);
    const build_elapsed = monotonicNowNs() - build_started;

    const started = monotonicNowNs();
    for (0..options.iterations) |_| {
        renderLutU8(scene, output, range, table);
    }
    const elapsed = monotonicNowNs() - started;
    const diff = try compareU8(production, output);
    const curve_error = curveErrorLutU8(table, constants);
    try printResult(stdout, "render_curve_preview_u8", "lut_u8_nearest", options, preview, elapsed, diff, entries, "entries={d};table_bytes={d};build_us={d};curve_max_abs={d:.9};curve_rms={d:.9};checksum={d}", .{
        entries,
        table.len,
        build_elapsed / std.time.ns_per_us,
        curve_error.max_abs,
        curve_error.rms,
        checksumU8(output),
    });
}

fn benchLutU16(
    stdout: anytype,
    allocator: std.mem.Allocator,
    options: BenchOptions,
    preview: workflow.QuickPreview,
    scene: []const f64,
    production: []const u16,
    output: []u16,
    range: render.LuminanceRange,
    constants: CurveConstants,
    entries: usize,
) !void {
    const table = try allocator.alloc(u16, entries);
    defer allocator.free(table);
    const build_started = monotonicNowNs();
    fillLutU16(table, constants);
    const build_elapsed = monotonicNowNs() - build_started;

    const started = monotonicNowNs();
    for (0..options.iterations) |_| {
        renderLutU16(scene, output, range, table);
    }
    const elapsed = monotonicNowNs() - started;
    const diff = try compareU16(production, output);
    const curve_error = curveErrorLutU16(table, constants);
    try printResult(stdout, "render_curve_export_u16", "lut_u16_nearest", options, preview, elapsed, diff, entries, "entries={d};table_bytes={d};build_us={d};curve_max_abs={d:.9};curve_rms={d:.9};checksum={d}", .{
        entries,
        table.len * @sizeOf(u16),
        build_elapsed / std.time.ns_per_us,
        curve_error.max_abs,
        curve_error.rms,
        checksumU16(output),
    });
}

fn benchLutLinearF32(
    stdout: anytype,
    allocator: std.mem.Allocator,
    options: BenchOptions,
    preview: workflow.QuickPreview,
    scene: []const f64,
    production: []const u8,
    production_u16: []const u16,
    output: []u8,
    output_u16: []u16,
    range: render.LuminanceRange,
    constants: CurveConstants,
    entries: usize,
) !void {
    const table = try allocator.alloc(f32, entries);
    defer allocator.free(table);
    const build_started = monotonicNowNs();
    fillLutF32(table, constants);
    const build_elapsed = monotonicNowNs() - build_started;

    const started = monotonicNowNs();
    for (0..options.iterations) |_| {
        renderLutLinearF32(scene, output, range, table);
    }
    const elapsed = monotonicNowNs() - started;
    const diff = try compareU8(production, output);
    const curve_error = curveErrorLutF32(table, constants);
    try printResult(stdout, "render_curve_preview_u8", "lut_f32_linear", options, preview, elapsed, diff, entries, "entries={d};table_bytes={d};build_us={d};curve_max_abs={d:.9};curve_rms={d:.9};checksum={d}", .{
        entries,
        table.len * @sizeOf(f32),
        build_elapsed / std.time.ns_per_us,
        curve_error.max_abs,
        curve_error.rms,
        checksumU8(output),
    });

    const u16_started = monotonicNowNs();
    for (0..options.iterations) |_| {
        renderLutLinearF32U16(scene, output_u16, range, table);
    }
    const u16_elapsed = monotonicNowNs() - u16_started;
    const u16_diff = try compareU16(production_u16, output_u16);
    try printResult(stdout, "render_curve_export_u16", "lut_f32_linear", options, preview, u16_elapsed, u16_diff, entries, "entries={d};table_bytes={d};build_us={d};curve_max_abs={d:.9};curve_rms={d:.9};checksum={d}", .{
        entries,
        table.len * @sizeOf(f32),
        build_elapsed / std.time.ns_per_us,
        curve_error.max_abs,
        curve_error.rms,
        checksumU16(output_u16),
    });
}

fn benchPolynomial(
    stdout: anytype,
    options: BenchOptions,
    preview: workflow.QuickPreview,
    scene: []const f64,
    production: []const u8,
    production_u16: []const u16,
    output: []u8,
    output_u16: []u16,
    range: render.LuminanceRange,
    constants: CurveConstants,
    degree: usize,
) !void {
    const fit_started = monotonicNowNs();
    const polynomial = try fitEndpointPolynomial(constants, degree, fit_sample_count);
    const fit_elapsed = monotonicNowNs() - fit_started;

    const started = monotonicNowNs();
    for (0..options.iterations) |_| {
        renderPolynomial(scene, output, range, polynomial);
    }
    const elapsed = monotonicNowNs() - started;
    const diff = try compareU8(production, output);
    const curve_error = curveErrorPolynomial(polynomial, constants);
    try printResult(stdout, "render_curve_preview_u8", "poly_endpoint_ls", options, preview, elapsed, diff, degree, "degree={d};fit_samples={d};fit_us={d};coeff_checksum={d};curve_max_abs={d:.9};curve_rms={d:.9};checksum={d}", .{
        degree,
        fit_sample_count,
        fit_elapsed / std.time.ns_per_us,
        checksumPolynomial(polynomial),
        curve_error.max_abs,
        curve_error.rms,
        checksumU8(output),
    });

    const u16_started = monotonicNowNs();
    for (0..options.iterations) |_| {
        renderPolynomialU16(scene, output_u16, range, polynomial);
    }
    const u16_elapsed = monotonicNowNs() - u16_started;
    const u16_diff = try compareU16(production_u16, output_u16);
    try printResult(stdout, "render_curve_export_u16", "poly_endpoint_ls", options, preview, u16_elapsed, u16_diff, degree, "degree={d};fit_samples={d};fit_us={d};coeff_checksum={d};curve_max_abs={d:.9};curve_rms={d:.9};checksum={d}", .{
        degree,
        fit_sample_count,
        fit_elapsed / std.time.ns_per_us,
        checksumPolynomial(polynomial),
        curve_error.max_abs,
        curve_error.rms,
        checksumU16(output_u16),
    });
}

fn renderExact(
    input: []const f64,
    output: []u8,
    range: render.LuminanceRange,
    constants: CurveConstants,
) void {
    const inv_denominator = 1.0 / (range.hi - range.lo);
    for (input, output) |value, *out| {
        const x = clamp((value - range.lo) * inv_denominator, 0.0, 1.0);
        out.* = quantizeU8(exactCurve(constants, x));
    }
}

fn renderExactU16(
    input: []const f64,
    output: []u16,
    range: render.LuminanceRange,
    constants: CurveConstants,
) void {
    const inv_denominator = 1.0 / (range.hi - range.lo);
    for (input, output) |value, *out| {
        const x = clamp((value - range.lo) * inv_denominator, 0.0, 1.0);
        out.* = quantizeU16(exactCurve(constants, x));
    }
}

fn renderLutU8(
    input: []const f64,
    output: []u8,
    range: render.LuminanceRange,
    table: []const u8,
) void {
    const inv_denominator = 1.0 / (range.hi - range.lo);
    const scale = @as(f64, @floatFromInt(table.len - 1));
    for (input, output) |value, *out| {
        const x = clamp((value - range.lo) * inv_denominator, 0.0, 1.0);
        const index: usize = @intFromFloat(@round(x * scale));
        out.* = table[@min(index, table.len - 1)];
    }
}

fn renderLutU16(
    input: []const f64,
    output: []u16,
    range: render.LuminanceRange,
    table: []const u16,
) void {
    const inv_denominator = 1.0 / (range.hi - range.lo);
    const scale = @as(f64, @floatFromInt(table.len - 1));
    for (input, output) |value, *out| {
        const x = clamp((value - range.lo) * inv_denominator, 0.0, 1.0);
        const index: usize = @intFromFloat(@round(x * scale));
        out.* = table[@min(index, table.len - 1)];
    }
}

fn renderLutLinearF32(
    input: []const f64,
    output: []u8,
    range: render.LuminanceRange,
    table: []const f32,
) void {
    const inv_denominator = 1.0 / (range.hi - range.lo);
    const scale = @as(f64, @floatFromInt(table.len - 1));
    for (input, output) |value, *out| {
        const x = clamp((value - range.lo) * inv_denominator, 0.0, 1.0);
        const position = x * scale;
        const lower: usize = @intFromFloat(@floor(position));
        const upper = @min(lower + 1, table.len - 1);
        const fraction = position - @as(f64, @floatFromInt(lower));
        const lo: f64 = @floatCast(table[lower]);
        const hi: f64 = @floatCast(table[upper]);
        out.* = quantizeU8(lo * (1.0 - fraction) + hi * fraction);
    }
}

fn renderLutLinearF32U16(
    input: []const f64,
    output: []u16,
    range: render.LuminanceRange,
    table: []const f32,
) void {
    const inv_denominator = 1.0 / (range.hi - range.lo);
    const scale = @as(f64, @floatFromInt(table.len - 1));
    for (input, output) |value, *out| {
        const x = clamp((value - range.lo) * inv_denominator, 0.0, 1.0);
        const position = x * scale;
        const lower: usize = @intFromFloat(@floor(position));
        const upper = @min(lower + 1, table.len - 1);
        const fraction = position - @as(f64, @floatFromInt(lower));
        const lo: f64 = @floatCast(table[lower]);
        const hi: f64 = @floatCast(table[upper]);
        out.* = quantizeU16(lo * (1.0 - fraction) + hi * fraction);
    }
}

fn renderPolynomial(
    input: []const f64,
    output: []u8,
    range: render.LuminanceRange,
    polynomial: Polynomial,
) void {
    const inv_denominator = 1.0 / (range.hi - range.lo);
    for (input, output) |value, *out| {
        const x = clamp((value - range.lo) * inv_denominator, 0.0, 1.0);
        out.* = quantizeU8(evalEndpointPolynomial(polynomial, x));
    }
}

fn renderPolynomialU16(
    input: []const f64,
    output: []u16,
    range: render.LuminanceRange,
    polynomial: Polynomial,
) void {
    const inv_denominator = 1.0 / (range.hi - range.lo);
    for (input, output) |value, *out| {
        const x = clamp((value - range.lo) * inv_denominator, 0.0, 1.0);
        out.* = quantizeU16(evalEndpointPolynomial(polynomial, x));
    }
}

fn contrastCurveConstants(k: f64) CurveConstants {
    const lo = logistic(k, 0.0);
    const hi = logistic(k, 1.0);
    return .{
        .k = k,
        .lo = lo,
        .hi = hi,
        .denominator = hi - lo,
    };
}

fn exactCurve(constants: CurveConstants, x: f64) f64 {
    return (logistic(constants.k, x) - constants.lo) / constants.denominator;
}

fn logistic(k: f64, x: f64) f64 {
    return 1.0 / (1.0 + @exp(-k * (x - 0.5)));
}

fn fillLutU8(table: []u8, constants: CurveConstants) void {
    const denominator = @as(f64, @floatFromInt(table.len - 1));
    for (table, 0..) |*entry, index| {
        const x = @as(f64, @floatFromInt(index)) / denominator;
        entry.* = quantizeU8(exactCurve(constants, x));
    }
}

fn fillLutU16(table: []u16, constants: CurveConstants) void {
    const denominator = @as(f64, @floatFromInt(table.len - 1));
    for (table, 0..) |*entry, index| {
        const x = @as(f64, @floatFromInt(index)) / denominator;
        entry.* = quantizeU16(exactCurve(constants, x));
    }
}

fn fillLutF32(table: []f32, constants: CurveConstants) void {
    const denominator = @as(f64, @floatFromInt(table.len - 1));
    for (table, 0..) |*entry, index| {
        const x = @as(f64, @floatFromInt(index)) / denominator;
        entry.* = @floatCast(exactCurve(constants, x));
    }
}

fn fitEndpointPolynomial(constants: CurveConstants, degree: usize, sample_count: usize) !Polynomial {
    if (degree < 2 or degree > max_poly_terms + 1) return error.InvalidPolynomialDegree;
    const terms = degree - 1;
    var normal: [max_poly_terms][max_poly_terms]f64 = undefined;
    var rhs: [max_poly_terms]f64 = undefined;
    for (&normal) |*row| row.* = [_]f64{0.0} ** max_poly_terms;
    rhs = [_]f64{0.0} ** max_poly_terms;

    for (0..sample_count) |sample_index| {
        const x = (@as(f64, @floatFromInt(sample_index)) + 0.5) / @as(f64, @floatFromInt(sample_count));
        const residual = exactCurve(constants, x) - x;
        var phi: [max_poly_terms]f64 = undefined;
        const base = x * (1.0 - x);
        var power: f64 = 1.0;
        for (0..terms) |index| {
            phi[index] = base * power;
            power *= x;
        }
        for (0..terms) |row| {
            rhs[row] += phi[row] * residual;
            for (0..terms) |column| {
                normal[row][column] += phi[row] * phi[column];
            }
        }
    }

    var polynomial = Polynomial{
        .degree = degree,
        .terms = terms,
        .q = [_]f64{0.0} ** max_poly_terms,
    };
    try solveLinearSystem(terms, &normal, &rhs, polynomial.q[0..terms]);
    return polynomial;
}

fn solveLinearSystem(
    n: usize,
    matrix: *[max_poly_terms][max_poly_terms]f64,
    rhs: *[max_poly_terms]f64,
    output: []f64,
) !void {
    for (0..n) |column| {
        var pivot = column;
        var pivot_abs = @abs(matrix[column][column]);
        for (column + 1..n) |row| {
            const value_abs = @abs(matrix[row][column]);
            if (value_abs > pivot_abs) {
                pivot = row;
                pivot_abs = value_abs;
            }
        }
        if (pivot_abs < 1e-18) return error.SingularPolynomialFit;
        if (pivot != column) {
            const row_tmp = matrix[pivot];
            matrix[pivot] = matrix[column];
            matrix[column] = row_tmp;
            const rhs_tmp = rhs[pivot];
            rhs[pivot] = rhs[column];
            rhs[column] = rhs_tmp;
        }
        for (column + 1..n) |row| {
            const factor = matrix[row][column] / matrix[column][column];
            matrix[row][column] = 0.0;
            for (column + 1..n) |inner_column| {
                matrix[row][inner_column] -= factor * matrix[column][inner_column];
            }
            rhs[row] -= factor * rhs[column];
        }
    }

    var row = n;
    while (row > 0) {
        row -= 1;
        var sum = rhs[row];
        for (row + 1..n) |column| {
            sum -= matrix[row][column] * output[column];
        }
        output[row] = sum / matrix[row][row];
    }
}

fn evalEndpointPolynomial(polynomial: Polynomial, x: f64) f64 {
    var q_value = polynomial.q[polynomial.terms - 1];
    var index = polynomial.terms - 1;
    while (index > 0) {
        index -= 1;
        q_value = q_value * x + polynomial.q[index];
    }
    return clamp(x + x * (1.0 - x) * q_value, 0.0, 1.0);
}

fn curveErrorLutU8(table: []const u8, constants: CurveConstants) CurveError {
    var max_abs: f64 = 0.0;
    var sum_sq: f64 = 0.0;
    const scale = @as(f64, @floatFromInt(table.len - 1));
    for (0..curve_error_sample_count) |sample_index| {
        const x = @as(f64, @floatFromInt(sample_index)) / @as(f64, @floatFromInt(curve_error_sample_count - 1));
        const exact = exactCurve(constants, x);
        const table_index: usize = @intFromFloat(@round(x * scale));
        const approximate = @as(f64, @floatFromInt(table[@min(table_index, table.len - 1)])) / 255.0;
        const diff = @abs(exact - approximate);
        max_abs = @max(max_abs, diff);
        sum_sq += diff * diff;
    }
    return .{ .max_abs = max_abs, .rms = @sqrt(sum_sq / @as(f64, @floatFromInt(curve_error_sample_count))) };
}

fn curveErrorLutU16(table: []const u16, constants: CurveConstants) CurveError {
    var max_abs: f64 = 0.0;
    var sum_sq: f64 = 0.0;
    const scale = @as(f64, @floatFromInt(table.len - 1));
    for (0..curve_error_sample_count) |sample_index| {
        const x = @as(f64, @floatFromInt(sample_index)) / @as(f64, @floatFromInt(curve_error_sample_count - 1));
        const exact = exactCurve(constants, x);
        const table_index: usize = @intFromFloat(@round(x * scale));
        const approximate = @as(f64, @floatFromInt(table[@min(table_index, table.len - 1)])) / 65535.0;
        const diff = @abs(exact - approximate);
        max_abs = @max(max_abs, diff);
        sum_sq += diff * diff;
    }
    return .{ .max_abs = max_abs, .rms = @sqrt(sum_sq / @as(f64, @floatFromInt(curve_error_sample_count))) };
}

fn curveErrorLutF32(table: []const f32, constants: CurveConstants) CurveError {
    var max_abs: f64 = 0.0;
    var sum_sq: f64 = 0.0;
    const scale = @as(f64, @floatFromInt(table.len - 1));
    for (0..curve_error_sample_count) |sample_index| {
        const x = @as(f64, @floatFromInt(sample_index)) / @as(f64, @floatFromInt(curve_error_sample_count - 1));
        const exact = exactCurve(constants, x);
        const position = x * scale;
        const lower: usize = @intFromFloat(@floor(position));
        const upper = @min(lower + 1, table.len - 1);
        const fraction = position - @as(f64, @floatFromInt(lower));
        const lo: f64 = @floatCast(table[lower]);
        const hi: f64 = @floatCast(table[upper]);
        const approximate = lo * (1.0 - fraction) + hi * fraction;
        const diff = @abs(exact - approximate);
        max_abs = @max(max_abs, diff);
        sum_sq += diff * diff;
    }
    return .{ .max_abs = max_abs, .rms = @sqrt(sum_sq / @as(f64, @floatFromInt(curve_error_sample_count))) };
}

fn curveErrorPolynomial(polynomial: Polynomial, constants: CurveConstants) CurveError {
    var max_abs: f64 = 0.0;
    var sum_sq: f64 = 0.0;
    for (0..curve_error_sample_count) |sample_index| {
        const x = @as(f64, @floatFromInt(sample_index)) / @as(f64, @floatFromInt(curve_error_sample_count - 1));
        const exact = exactCurve(constants, x);
        const approximate = evalEndpointPolynomial(polynomial, x);
        const diff = @abs(exact - approximate);
        max_abs = @max(max_abs, diff);
        sum_sq += diff * diff;
    }
    return .{ .max_abs = max_abs, .rms = @sqrt(sum_sq / @as(f64, @floatFromInt(curve_error_sample_count))) };
}

fn printResult(
    stdout: anytype,
    benchmark: []const u8,
    mode: []const u8,
    options: BenchOptions,
    preview: workflow.QuickPreview,
    elapsed_ns: u64,
    diff: DiffSummary,
    parameter: usize,
    comptime detail_fmt: []const u8,
    detail_args: anytype,
) !void {
    try stdout.print(
        "{s},{s},{d},{d},{d},{d},mode={s};parameter={d};iterations={d};max_abs={d};rms={d:.3};mismatches={d};mismatch_pct_x1000={d};",
        .{
            benchmark,
            options.scan_path,
            preview.preview_width,
            preview.preview_height,
            preview.preview_width * preview.preview_height * 3,
            elapsed_ns / std.time.ns_per_us,
            mode,
            parameter,
            options.iterations,
            diff.max_abs,
            diff.rms,
            diff.mismatches,
            pctX1000(@intCast(diff.mismatches), @intCast(preview.preview_width * preview.preview_height * 3)),
        },
    );
    try stdout.print(detail_fmt ++ "\n", detail_args);
}

fn compareU8(a: []const u8, b: []const u8) !DiffSummary {
    if (a.len != b.len) return error.OutputLengthMismatch;
    var max_abs: u64 = 0;
    var sum_sq: f64 = 0.0;
    var mismatches: usize = 0;
    for (a, b) |left, right| {
        const diff = if (left >= right)
            @as(u64, left) - @as(u64, right)
        else
            @as(u64, right) - @as(u64, left);
        if (diff != 0) mismatches += 1;
        max_abs = @max(max_abs, diff);
        const diff_f: f64 = @floatFromInt(diff);
        sum_sq += diff_f * diff_f;
    }
    return .{
        .max_abs = max_abs,
        .rms = if (a.len == 0) 0.0 else @sqrt(sum_sq / @as(f64, @floatFromInt(a.len))),
        .mismatches = mismatches,
    };
}

fn compareU16(a: []const u16, b: []const u16) !DiffSummary {
    if (a.len != b.len) return error.OutputLengthMismatch;
    var max_abs: u64 = 0;
    var sum_sq: f64 = 0.0;
    var mismatches: usize = 0;
    for (a, b) |left, right| {
        const diff = if (left >= right)
            @as(u64, left) - @as(u64, right)
        else
            @as(u64, right) - @as(u64, left);
        if (diff != 0) mismatches += 1;
        max_abs = @max(max_abs, diff);
        const diff_f: f64 = @floatFromInt(diff);
        sum_sq += diff_f * diff_f;
    }
    return .{
        .max_abs = max_abs,
        .rms = if (a.len == 0) 0.0 else @sqrt(sum_sq / @as(f64, @floatFromInt(a.len))),
        .mismatches = mismatches,
    };
}

fn quantizeU8(value: f64) u8 {
    const u16_value: u16 = @intFromFloat(clamp(value * 65535.0, 0.0, 65535.0));
    return @intCast(u16_value >> 8);
}

fn quantizeU16(value: f64) u16 {
    return @intFromFloat(clamp(value * 65535.0, 0.0, 65535.0));
}

fn clamp(value: f64, lo: f64, hi: f64) f64 {
    return @min(@max(value, lo), hi);
}

fn pctX1000(part: u64, total: u64) u64 {
    if (total == 0) return 0;
    return @intCast((@as(u128, part) * 100_000) / @as(u128, total));
}

fn checksumU8(values: []const u8) u64 {
    var sum: u64 = 0;
    for (values) |value| sum +%= value;
    return sum;
}

fn checksumU16(values: []const u16) u64 {
    var sum: u64 = 0;
    for (values) |value| sum +%= value;
    return sum;
}

fn checksumPolynomial(polynomial: Polynomial) i64 {
    var sum: f64 = 0.0;
    for (polynomial.q[0..polynomial.terms]) |coefficient| {
        sum += coefficient;
    }
    return @intFromFloat(@round(sum * 1_000_000_000.0));
}

fn monotonicNowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
