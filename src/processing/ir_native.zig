//! ECC alignment over row bands around the pure-Zig estimator.

const std = @import("std");

const ir_pure = @import("ir_pure.zig");
const parallelism = @import("parallelism.zig");

// ECC runs at 1/8 scale with OpenCV findTransformECC's iteration limits,
// which the earlier OpenCV helper used.
const pure_ecc_scale: f64 = 0.125;
const pure_ecc_max_iterations: u32 = 200;
const pure_ecc_epsilon: f64 = 1.0e-6;

/// IR-to-RGB translation for alignment, in Zig on every target (the OpenCV
/// helper indexed with 32-bit ints and overran on strips past 2^31 samples):
/// `ir_pure.estimateTranslationEcc`, built from the same pieces, with its
/// full-resolution passes (the maxima, the strip's grey at IR resolution, the
/// IR's u8 copy, and the resizes for ECC) run over bands of rows.
pub fn estimateTranslationEcc(
    allocator: std.mem.Allocator,
    rgb: []const f64,
    rgb_width: usize,
    rgb_height: usize,
    ir: []const f64,
    ir_width: usize,
    ir_height: usize,
) !ir_pure.TranslationEstimate {
    const rgb_pixels = rgb_width * rgb_height;
    const ir_pixels = ir_width * ir_height;

    const gray_rgb = try allocator.alloc(u8, rgb_pixels);
    defer allocator.free(gray_rgb);
    const rgb_denominator = ir_pure.u8Denominator(f64, try maxFiniteByRows(allocator, rgb, rgb_height));
    try parallelism.forRowBands(allocator, rgb_height, GrayRows{ .rgb = rgb, .width = rgb_width, .denominator = rgb_denominator, .gray = gray_rgb }, GrayRows.rows);

    const gray_ir = try allocator.alloc(u8, ir_pixels);
    defer allocator.free(gray_ir);
    if (rgb_width == ir_width and rgb_height == ir_height) {
        @memcpy(gray_ir, gray_rgb);
    } else {
        try resizeByRows(allocator, gray_rgb, rgb_width, rgb_height, gray_ir, ir_width, ir_height);
    }

    const ir_u8 = try allocator.alloc(u8, ir_pixels);
    defer allocator.free(ir_u8);
    const ir_denominator = ir_pure.u8Denominator(f64, try maxFiniteByRows(allocator, ir, ir_height));
    try parallelism.forRowBands(allocator, ir_height, U8Rows{ .input = ir, .width = ir_width, .denominator = ir_denominator, .output = ir_u8 }, U8Rows.rows);

    const small = try ir_pure.eccSmallSize(ir_width, ir_height, pure_ecc_scale);
    const template_u8 = try allocator.alloc(u8, small.width * small.height);
    defer allocator.free(template_u8);
    const image_u8 = try allocator.alloc(u8, small.width * small.height);
    defer allocator.free(image_u8);
    try resizeByRows(allocator, gray_ir, ir_width, ir_height, template_u8, small.width, small.height);
    try resizeByRows(allocator, ir_u8, ir_width, ir_height, image_u8, small.width, small.height);
    return ir_pure.estimateTranslationEccSmall(allocator, template_u8, image_u8, small.width, small.height, pure_ecc_scale, pure_ecc_max_iterations, pure_ecc_epsilon);
}

/// Each row's maximum in parallel, then the largest of them; any non-finite
/// sample is an error, as in `ir_pure.maxFiniteSample`.
fn maxFiniteByRows(allocator: std.mem.Allocator, samples: []const f64, height: usize) !f64 {
    const row_max = try allocator.alloc(?f64, height);
    defer allocator.free(row_max);
    const Rows = struct {
        samples: []const f64,
        row_len: usize,
        row_max: []?f64,

        fn rows(pass: @This(), row_start: usize, row_end: usize) void {
            for (row_start..row_end) |row| {
                pass.row_max[row] = ir_pure.maxFiniteSample(f64, pass.samples[row * pass.row_len ..][0..pass.row_len]) catch null;
            }
        }
    };
    try parallelism.forRowBands(allocator, height, Rows{ .samples = samples, .row_len = samples.len / height, .row_max = row_max }, Rows.rows);
    var max_value: f64 = 0.0;
    for (row_max) |value| {
        const row_value = value orelse return error.InvalidBuffer;
        if (row_value > max_value) max_value = row_value;
    }
    return max_value;
}

fn resizeByRows(allocator: std.mem.Allocator, input: []const u8, in_width: usize, in_height: usize, output: []u8, out_width: usize, out_height: usize) !void {
    const Rows = struct {
        input: []const u8,
        in_width: usize,
        in_height: usize,
        output: []u8,
        out_width: usize,
        out_height: usize,

        fn rows(pass: @This(), row_start: usize, row_end: usize) void {
            ir_pure.areaResizeU8Rows(pass.input, pass.in_width, pass.in_height, pass.output, pass.out_width, pass.out_height, row_start, row_end);
        }
    };
    try parallelism.forRowBands(allocator, out_height, Rows{ .input = input, .in_width = in_width, .in_height = in_height, .output = output, .out_width = out_width, .out_height = out_height }, Rows.rows);
}

const GrayRows = struct {
    rgb: []const f64,
    width: usize,
    denominator: f64,
    gray: []u8,

    fn rows(pass: GrayRows, row_start: usize, row_end: usize) void {
        ir_pure.rgbToGrayU8Range(f64, pass.rgb, pass.denominator, pass.gray, row_start * pass.width, row_end * pass.width);
    }
};

const U8Rows = struct {
    input: []const f64,
    width: usize,
    denominator: f64,
    output: []u8,

    fn rows(pass: U8Rows, row_start: usize, row_end: usize) void {
        ir_pure.samplesToU8Range(f64, pass.input, pass.denominator, pass.output, row_start * pass.width, row_end * pass.width);
    }
};
