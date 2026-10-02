//! Dependency-free pure-Zig ports of the native C/C++ IR helper behavior:
//! the opencv_ir.cpp local grain estimation, grain spectrum, and grain
//! synthesis path, and the translation-only ECC estimator (ported from the
//! former opencv_ecc.cpp; now the only implementation, native and browser).
//! Shared by the browser Wasm core and the native build, so
//! everything here must stay freestanding-safe: single-threaded, no libc,
//! no OS calls, std-only.

const std = @import("std");

pub fn roundF32(value: f64) f64 {
    const rounded: f32 = @floatCast(value);
    return @floatCast(rounded);
}

fn rgbToIrGrayU8(
    comptime T: type,
    allocator: std.mem.Allocator,
    rgb: []const T,
    rgb_width: usize,
    rgb_height: usize,
    output: []u8,
    ir_width: usize,
    ir_height: usize,
) !void {
    const rgb_pixels = rgb_width * rgb_height;
    const gray_rgb = try allocator.alloc(u8, rgb_pixels);
    defer allocator.free(gray_rgb);
    var max_value: T = 0.0;
    for (rgb) |sample| {
        if (!std.math.isFinite(sample)) return error.InvalidBuffer;
        if (sample > max_value) max_value = sample;
    }
    const denominator = @as(f64, @floatCast(max_value)) / 255.0 + 1.0e-10;
    for (0..rgb_pixels) |pixel| {
        const base = pixel * 3;
        const r = scaledU8(T, rgb[base], denominator);
        const g = scaledU8(T, rgb[base + 1], denominator);
        const b = scaledU8(T, rgb[base + 2], denominator);
        const gray = (@as(u32, r) * 77 + @as(u32, g) * 150 + @as(u32, b) * 29 + 128) >> 8;
        gray_rgb[pixel] = @intCast(gray);
    }
    if (rgb_width == ir_width and rgb_height == ir_height) {
        @memcpy(output, gray_rgb);
    } else {
        areaResizeU8(gray_rgb, rgb_width, rgb_height, output, ir_width, ir_height);
    }
}

fn samplesToU8(comptime T: type, input: []const T, output: []u8) !void {
    var max_value: T = 0.0;
    for (input) |sample| {
        if (!std.math.isFinite(sample)) return error.InvalidBuffer;
        if (sample > max_value) max_value = sample;
    }
    const denominator = @as(f64, @floatCast(max_value)) / 255.0 + 1.0e-10;
    for (input, output) |sample, *out| {
        out.* = scaledU8(T, sample, denominator);
    }
}

fn scaledU8(comptime T: type, sample: T, denominator: f64) u8 {
    if (sample <= 0.0 or denominator <= 0.0) return 0;
    const scaled = @as(f64, @floatCast(sample)) / denominator;
    if (scaled >= 255.0) return 255;
    return @intFromFloat(@floor(scaled));
}
fn areaResizeU8(input: []const u8, in_width: usize, in_height: usize, output: []u8, out_width: usize, out_height: usize) void {
    const scale_x = @as(f64, @floatFromInt(in_width)) / @as(f64, @floatFromInt(out_width));
    const scale_y = @as(f64, @floatFromInt(in_height)) / @as(f64, @floatFromInt(out_height));
    for (0..out_height) |out_y| {
        const y0: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(out_y)) * scale_y));
        const y1: usize = @max(y0 + 1, @as(usize, @intFromFloat(@floor(@as(f64, @floatFromInt(out_y + 1)) * scale_y))));
        for (0..out_width) |out_x| {
            const x0: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(out_x)) * scale_x));
            const x1: usize = @max(x0 + 1, @as(usize, @intFromFloat(@floor(@as(f64, @floatFromInt(out_x + 1)) * scale_x))));
            var sum: u64 = 0;
            var count: u64 = 0;
            for (y0..@min(y1, in_height)) |src_y| {
                for (x0..@min(x1, in_width)) |src_x| {
                    sum += input[src_y * in_width + src_x];
                    count += 1;
                }
            }
            output[out_y * out_width + out_x] = @intCast((sum + count / 2) / count);
        }
    }
}
pub const LocalGrainEstimate = struct {
    grain_std: [3]f64,
    signal: []f64,
    spectrum: ?[]f64,

    pub fn deinit(self: LocalGrainEstimate, allocator: std.mem.Allocator) void {
        if (self.spectrum) |spectrum| allocator.free(spectrum);
        allocator.free(self.signal);
    }
};

pub fn estimateLocalGrain(
    allocator: std.mem.Allocator,
    roi_rgb: []const f64,
    roi_mask: []const u8,
    width: usize,
    height: usize,
    grain_padding: usize,
    grain_sigma: f64,
) !LocalGrainEstimate {
    if (width == 0 or height == 0 or roi_rgb.len != width * height * 3 or roi_mask.len != width * height) {
        return error.InvalidIrLocalGrainBuffer;
    }

    const rgb_f32 = try allocator.alloc(f32, roi_rgb.len);
    defer allocator.free(rgb_f32);
    for (roi_rgb, rgb_f32) |value, *out| {
        if (!std.math.isFinite(value)) return error.InvalidIrLocalGrainBuffer;
        out.* = @floatCast(value);
    }

    const signal_f32 = try allocator.alloc(f32, roi_rgb.len);
    defer allocator.free(signal_f32);
    {
        // Normalized convolution: the low-pass of the clean pixels only, so
        // the defect does not leak into the values around it.
        const known = try allocator.alloc(f32, roi_rgb.len);
        defer allocator.free(known);
        const weighted = try allocator.alloc(f32, roi_rgb.len);
        defer allocator.free(weighted);
        for (known, weighted, rgb_f32, 0..) |*k, *w, value, index| {
            k.* = if (roi_mask[index / 3] != 0) 0.0 else 1.0;
            w.* = value * k.*;
        }
        const denominator = try allocator.alloc(f32, roi_rgb.len);
        defer allocator.free(denominator);
        try gaussianBlurRgbSigmaF32(allocator, weighted, width, height, grain_sigma, signal_f32);
        try gaussianBlurRgbSigmaF32(allocator, known, width, height, grain_sigma, denominator);
        for (signal_f32, denominator, rgb_f32) |*out, den, value| {
            out.* = if (den > 1.0e-3) out.* / den else value;
        }
    }

    const signal = try allocator.alloc(f64, roi_rgb.len);
    errdefer allocator.free(signal);
    for (signal_f32, signal) |value, *out| {
        out.* = @floatCast(value);
    }

    const dilated = try allocator.alloc(u8, roi_mask.len);
    defer allocator.free(dilated);
    try dilateMaskOpenCvEllipse(allocator, roi_mask, width, height, grain_padding, dilated);

    var surround_count: usize = 0;
    var clean_count: usize = 0;
    for (roi_mask, dilated) |mask_value, dilated_value| {
        const masked = mask_value != 0;
        if (!masked) clean_count += 1;
        if (dilated_value != 0 and !masked) surround_count += 1;
    }

    var grain_std = [_]f64{ 0.0, 0.0, 0.0 };
    if (surround_count > 10) {
        var sum = [_]f64{ 0.0, 0.0, 0.0 };
        var sum_sq = [_]f64{ 0.0, 0.0, 0.0 };
        for (0..height) |y| {
            for (0..width) |x| {
                const pixel = y * width + x;
                if (dilated[pixel] == 0 or roi_mask[pixel] != 0) continue;
                for (0..3) |channel| {
                    const index = pixel * 3 + channel;
                    const grain = rgb_f32[index] - signal_f32[index];
                    const grain_f64: f64 = @floatCast(grain);
                    sum[channel] += grain_f64;
                    sum_sq[channel] += grain_f64 * grain_f64;
                }
            }
        }
        const count_f = @as(f64, @floatFromInt(surround_count));
        for (0..3) |channel| {
            const mean = sum[channel] / count_f;
            var variance = sum_sq[channel] / count_f - mean * mean;
            if (variance < 0.0) variance = 0.0;
            grain_std[channel] = roundF32(@sqrt(variance));
        }
    }

    const spectrum = try estimateGrainSpectrum(
        allocator,
        rgb_f32,
        signal_f32,
        roi_mask,
        width,
        height,
        surround_count,
        clean_count,
    );
    errdefer if (spectrum) |values| allocator.free(values);

    return .{
        .grain_std = grain_std,
        .signal = signal,
        .spectrum = spectrum,
    };
}

fn estimateGrainSpectrum(
    allocator: std.mem.Allocator,
    rgb_f32: []const f32,
    signal_f32: []const f32,
    mask: []const u8,
    width: usize,
    height: usize,
    surround_count: usize,
    clean_count: usize,
) !?[]f64 {
    const r_max = @min(width, height) / 2;
    if (surround_count <= 64 or r_max == 0) return null;

    const spectrum_sum = try allocator.alloc(f64, r_max);
    errdefer allocator.free(spectrum_sum);
    @memset(spectrum_sum, 0.0);

    const ring_count = try allocator.alloc(usize, r_max);
    defer allocator.free(ring_count);
    @memset(ring_count, 0);

    const dft_input = try allocator.alloc(f64, width * height);
    defer allocator.free(dft_input);

    const cy = height / 2;
    const cx = width / 2;
    const y_shift = (height + 1) / 2;
    const x_shift = (width + 1) / 2;
    // Rings of equal frequency, in bins of the shorter side: a DFT bin is
    // 1/width cycles per pixel across and 1/height down.
    const short_side: f64 = @floatFromInt(@min(width, height));
    const x_bin = short_side / @as(f64, @floatFromInt(width));
    const y_bin = short_side / @as(f64, @floatFromInt(height));

    for (0..3) |channel| {
        for (0..height) |y| {
            const wy = if (height > 1)
                0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(height - 1)))
            else
                1.0;
            for (0..width) |x| {
                const wx = if (width > 1)
                    0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(width - 1)))
                else
                    1.0;
                const pixel = y * width + x;
                var grain = @as(f64, @floatCast(rgb_f32[pixel * 3 + channel] - signal_f32[pixel * 3 + channel]));
                if (mask[pixel] != 0) grain = 0.0;
                dft_input[pixel] = grain * wy * wx;
            }
        }

        const dft_output = try dft2RealToComplex(allocator, dft_input, width, height);
        defer allocator.free(dft_output);
        for (0..height) |y| {
            const src_y = (y + y_shift) % height;
            const dy = @as(f64, @floatFromInt(@as(isize, @intCast(y)) - @as(isize, @intCast(cy)))) * y_bin;
            for (0..width) |x| {
                const src_x = (x + x_shift) % width;
                const dx = @as(f64, @floatFromInt(@as(isize, @intCast(x)) - @as(isize, @intCast(cx)))) * x_bin;
                const ri: usize = @intFromFloat(@sqrt(dx * dx + dy * dy));
                if (ri >= r_max) continue;
                const value = dft_output[src_y * width + src_x];
                spectrum_sum[ri] += (value.re * value.re + value.im * value.im) / 3.0;
                if (channel == 0) ring_count[ri] += 1;
            }
        }
    }

    var spectrum_total: f64 = 0.0;
    const clean_fraction = @as(f64, @floatFromInt(clean_count)) / @as(f64, @floatFromInt(width * height));
    for (0..r_max) |r| {
        if (ring_count[r] > 0) {
            spectrum_sum[r] /= @floatFromInt(ring_count[r]);
        }
        if (clean_fraction > 0.1) {
            spectrum_sum[r] /= clean_fraction * clean_fraction;
        }
        spectrum_total += spectrum_sum[r];
    }

    if (spectrum_total <= 0.0) {
        allocator.free(spectrum_sum);
        return null;
    }
    for (spectrum_sum) |*value| {
        value.* /= spectrum_total;
    }
    return spectrum_sum;
}

pub fn synthesizeGrainFromNoise(
    allocator: std.mem.Allocator,
    noise: []const f64,
    width: usize,
    height: usize,
    grain_std: []const f64,
    grain_spectrum: ?[]const f64,
    channels: usize,
    output: []f64,
) !void {
    if (width == 0 or height == 0 or channels == 0 or
        noise.len != width * height * channels or
        output.len != noise.len or
        grain_std.len < channels)
    {
        return error.InvalidIrGrainSynthesisBuffer;
    }

    const plane = try allocator.alloc(f64, width * height);
    defer allocator.free(plane);
    for (0..channels) |channel| {
        for (0..height) |y| {
            for (0..width) |x| {
                plane[y * width + x] = noise[(channel * height + y) * width + x];
            }
        }

        const dft = try dft2RealToComplex(allocator, plane, width, height);
        defer allocator.free(dft);
        shapeSpectrumInPlace(dft, width, height, grain_spectrum);

        try inverseDft2ComplexToReal(allocator, dft, width, height, plane);
        var sum: f64 = 0.0;
        var sum_sq: f64 = 0.0;
        for (plane) |value| {
            sum += value;
            sum_sq += value * value;
        }
        const count = @as(f64, @floatFromInt(plane.len));
        const mean = sum / count;
        var variance = sum_sq / count - mean * mean;
        if (variance < 0.0) variance = 0.0;
        const noise_std = @sqrt(variance);

        for (0..height) |y| {
            for (0..width) |x| {
                const pixel = y * width + x;
                var shaped = plane[pixel];
                if (noise_std > 0.0) shaped /= noise_std;
                output[pixel * channels + channel] = roundF32(shaped * grain_std[channel]);
            }
        }
    }
}

fn gaussianBlurRgbSigmaF32(
    allocator: std.mem.Allocator,
    input: []const f32,
    width: usize,
    height: usize,
    sigma: f64,
    output: []f32,
) !void {
    if (input.len != width * height * 3 or output.len != input.len) return error.InvalidIrLocalGrainBuffer;
    const kernel_size = openCvGaussianKernelSizeForF32(sigma);
    const kernel = try gaussianKernelSigmaF32(allocator, sigma, kernel_size);
    defer allocator.free(kernel);

    const temp = try allocator.alloc(f32, input.len);
    defer allocator.free(temp);
    const radius: i32 = @intCast(kernel_size / 2);
    for (0..height) |y| {
        for (0..width) |x| {
            for (0..3) |channel| {
                var sum: f32 = 0.0;
                for (kernel, 0..) |weight, k| {
                    const offset = @as(i32, @intCast(k)) - radius;
                    const sx = reflect101Index(@as(i32, @intCast(x)) + offset, width);
                    sum += input[(y * width + sx) * 3 + channel] * weight;
                }
                temp[(y * width + x) * 3 + channel] = sum;
            }
        }
    }
    for (0..height) |y| {
        for (0..width) |x| {
            for (0..3) |channel| {
                var sum: f32 = 0.0;
                for (kernel, 0..) |weight, k| {
                    const offset = @as(i32, @intCast(k)) - radius;
                    const sy = reflect101Index(@as(i32, @intCast(y)) + offset, height);
                    sum += temp[(sy * width + x) * 3 + channel] * weight;
                }
                output[(y * width + x) * 3 + channel] = sum;
            }
        }
    }
}

fn openCvGaussianKernelSizeForF32(sigma: f64) usize {
    const raw = @floor(sigma * 8.0 + 1.0 + 0.5);
    var size: usize = @intFromFloat(raw);
    size |= 1;
    return @max(size, 3);
}

fn gaussianKernelSigmaF32(allocator: std.mem.Allocator, sigma: f64, kernel_size: usize) ![]f32 {
    const kernel = try allocator.alloc(f32, kernel_size);
    errdefer allocator.free(kernel);
    const half = (@as(f64, @floatFromInt(kernel_size)) - 1.0) * 0.5;
    var sum: f64 = 0.0;
    for (kernel, 0..) |*weight, index| {
        const x = @as(f64, @floatFromInt(index)) - half;
        const value = @exp(-(x * x) / (2.0 * sigma * sigma));
        weight.* = @floatCast(value);
        sum += value;
    }
    const inv_sum: f32 = @floatCast(1.0 / sum);
    for (kernel) |*weight| {
        weight.* *= inv_sum;
    }
    return kernel;
}

fn dilateMaskOpenCvEllipse(
    allocator: std.mem.Allocator,
    input: []const u8,
    width: usize,
    height: usize,
    radius: usize,
    output: []u8,
) !void {
    if (input.len != width * height or output.len != input.len) return error.InvalidIrLocalGrainBuffer;
    const spans = try openCvEllipseSpans(allocator, radius);
    defer allocator.free(spans);
    const height_i: i32 = @intCast(height);
    const width_i: i32 = @intCast(width);
    @memset(output, 0);
    for (0..height) |y| {
        const y_i: i32 = @intCast(y);
        for (0..width) |x| {
            const x_i: i32 = @intCast(x);
            var set = false;
            for (spans) |span| {
                const sy = y_i + span.y_offset;
                if (sy < 0 or sy >= height_i) continue;
                const start_i = @max(x_i + span.x_min, 0);
                const end_i = @min(x_i + span.x_max, width_i - 1);
                if (start_i > end_i) continue;
                const row = @as(usize, @intCast(sy)) * width;
                var sx: usize = @intCast(start_i);
                const end: usize = @intCast(end_i);
                while (sx <= end) : (sx += 1) {
                    if (input[row + sx] != 0) {
                        set = true;
                        break;
                    }
                }
                if (set) break;
            }
            output[y * width + x] = if (set) 255 else 0;
        }
    }
}

const EllipseSpan = struct {
    y_offset: i32,
    x_min: i32,
    x_max: i32,
};

// Matches cv::getStructuringElement(MORPH_ELLIPSE); for radius >= 2 this
// differs from the skimage-style disk in ir.zig ellipseKernelRowSpans, so the
// two must not be deduplicated.
fn openCvEllipseSpans(allocator: std.mem.Allocator, radius: usize) ![]EllipseSpan {
    const diameter = radius * 2 + 1;
    const spans = try allocator.alloc(EllipseSpan, diameter);
    errdefer allocator.free(spans);
    if (radius == 0) {
        spans[0] = .{ .y_offset = 0, .x_min = 0, .x_max = 0 };
        return spans;
    }
    const r_i: i32 = @intCast(radius);
    const r = @as(f64, @floatFromInt(radius));
    const r_sq = r * r;
    for (0..diameter) |y| {
        const dy_i = @as(i32, @intCast(y)) - r_i;
        const dy = @as(f64, @floatFromInt(dy_i));
        const dx_f = r * @sqrt(@max(0.0, (r_sq - dy * dy) / r_sq));
        const dx_i: i32 = @intFromFloat(@floor(dx_f + 0.5));
        spans[y] = .{
            .y_offset = dy_i,
            .x_min = -dx_i,
            .x_max = dx_i,
        };
    }
    return spans;
}

const Complex = struct {
    re: f64,
    im: f64,
};

fn dft2RealToComplex(
    allocator: std.mem.Allocator,
    input: []const f64,
    width: usize,
    height: usize,
) ![]Complex {
    if (input.len != width * height) return error.InvalidBuffer;
    const temp = try allocator.alloc(Complex, input.len);
    defer allocator.free(temp);
    const output = try allocator.alloc(Complex, input.len);
    errdefer allocator.free(output);

    const tau = 2.0 * std.math.pi;
    for (0..height) |y| {
        for (0..width) |u| {
            var sum = Complex{ .re = 0.0, .im = 0.0 };
            for (0..width) |x| {
                const angle = -tau * @as(f64, @floatFromInt(u * x)) / @as(f64, @floatFromInt(width));
                const value = input[y * width + x];
                sum.re += value * @cos(angle);
                sum.im += value * @sin(angle);
            }
            temp[y * width + u] = sum;
        }
    }

    for (0..height) |v| {
        for (0..width) |u| {
            var sum = Complex{ .re = 0.0, .im = 0.0 };
            for (0..height) |y| {
                const angle = -tau * @as(f64, @floatFromInt(v * y)) / @as(f64, @floatFromInt(height));
                const twiddle = Complex{ .re = @cos(angle), .im = @sin(angle) };
                const value = temp[y * width + u];
                sum.re += value.re * twiddle.re - value.im * twiddle.im;
                sum.im += value.re * twiddle.im + value.im * twiddle.re;
            }
            output[v * width + u] = sum;
        }
    }
    return output;
}

fn inverseDft2ComplexToReal(
    allocator: std.mem.Allocator,
    input: []const Complex,
    width: usize,
    height: usize,
    output: []f64,
) !void {
    if (input.len != width * height or output.len != input.len) return error.InvalidBuffer;
    const temp = try allocator.alloc(Complex, input.len);
    defer allocator.free(temp);
    const tau = 2.0 * std.math.pi;

    for (0..height) |v| {
        for (0..width) |x| {
            var sum = Complex{ .re = 0.0, .im = 0.0 };
            for (0..width) |u| {
                const angle = tau * @as(f64, @floatFromInt(u * x)) / @as(f64, @floatFromInt(width));
                const twiddle = Complex{ .re = @cos(angle), .im = @sin(angle) };
                const value = input[v * width + u];
                sum.re += value.re * twiddle.re - value.im * twiddle.im;
                sum.im += value.re * twiddle.im + value.im * twiddle.re;
            }
            temp[v * width + x] = sum;
        }
    }

    const scale = 1.0 / @as(f64, @floatFromInt(width * height));
    for (0..height) |y| {
        for (0..width) |x| {
            var sum = Complex{ .re = 0.0, .im = 0.0 };
            for (0..height) |v| {
                const angle = tau * @as(f64, @floatFromInt(v * y)) / @as(f64, @floatFromInt(height));
                const twiddle = Complex{ .re = @cos(angle), .im = @sin(angle) };
                const value = temp[v * width + x];
                sum.re += value.re * twiddle.re - value.im * twiddle.im;
                sum.im += value.re * twiddle.im + value.im * twiddle.re;
            }
            output[y * width + x] = sum.re * scale;
        }
    }
}

fn shapeSpectrumInPlace(values: []Complex, width: usize, height: usize, grain_spectrum: ?[]const f64) void {
    const cy = height / 2;
    const cx = width / 2;
    const y_shift = height / 2;
    const x_shift = width / 2;
    const spectrum_len = if (grain_spectrum) |spectrum| spectrum.len else 0;
    // Rings of equal frequency, in bins of the shorter side, as measured.
    const short_side: f64 = @floatFromInt(@min(width, height));
    const x_bin = short_side / @as(f64, @floatFromInt(width));
    const y_bin = short_side / @as(f64, @floatFromInt(height));

    for (0..height) |y| {
        const centered_y = (y + y_shift) % height;
        const dy = @as(f64, @floatFromInt(@as(isize, @intCast(centered_y)) - @as(isize, @intCast(cy)))) * y_bin;
        for (0..width) |x| {
            const centered_x = (x + x_shift) % width;
            const dx = @as(f64, @floatFromInt(@as(isize, @intCast(centered_x)) - @as(isize, @intCast(cx)))) * x_bin;
            const radius = @sqrt(dx * dx + dy * dy);
            var amp: f64 = 1.0;
            if (grain_spectrum != null and spectrum_len > 4) {
                const spectrum = grain_spectrum.?;
                if (radius >= @as(f64, @floatFromInt(spectrum_len - 1))) {
                    amp = @sqrt(@max(spectrum[spectrum_len - 1], 0.0));
                } else {
                    const lower: usize = @intFromFloat(@floor(radius));
                    const upper = lower + 1;
                    const t = radius - @as(f64, @floatFromInt(lower));
                    const low = @sqrt(@max(spectrum[lower], 0.0));
                    const high = @sqrt(@max(spectrum[upper], 0.0));
                    amp = low * (1.0 - t) + high * t;
                }
            } else {
                const safe_radius = if (radius > 0.0) radius else 1.0;
                amp = 1.0 / safe_radius;
            }
            const index = y * width + x;
            values[index].re *= amp;
            values[index].im *= amp;
        }
    }
}

fn gaussianBlur5Reflect101InPlace(allocator: std.mem.Allocator, values: []f32, width: usize, height: usize) !void {
    const temp = try allocator.alloc(f32, values.len);
    defer allocator.free(temp);
    const weights = [_]f32{ 0.0625, 0.25, 0.375, 0.25, 0.0625 };
    for (0..height) |y| {
        for (0..width) |x| {
            var sum: f32 = 0.0;
            inline for (0..5) |k| {
                const offset: i32 = @as(i32, @intCast(k)) - 2;
                const src_x = reflect101Index(@as(i32, @intCast(x)) + offset, width);
                sum += values[y * width + src_x] * weights[k];
            }
            temp[y * width + x] = sum;
        }
    }
    for (0..height) |y| {
        for (0..width) |x| {
            var sum: f32 = 0.0;
            inline for (0..5) |k| {
                const offset: i32 = @as(i32, @intCast(k)) - 2;
                const src_y = reflect101Index(@as(i32, @intCast(y)) + offset, height);
                sum += temp[src_y * width + x] * weights[k];
            }
            values[y * width + x] = sum;
        }
    }
}

fn gradientCentralReflect101(input: []const f32, width: usize, height: usize, output_x: []f32, output_y: []f32) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const x_i: i32 = @intCast(x);
            const y_i: i32 = @intCast(y);
            const left = input[y * width + reflect101Index(x_i - 1, width)];
            const right = input[y * width + reflect101Index(x_i + 1, width)];
            const up = input[reflect101Index(y_i - 1, height) * width + x];
            const down = input[reflect101Index(y_i + 1, height) * width + x];
            output_x[y * width + x] = (right - left) * 0.5;
            output_y[y * width + x] = (down - up) * 0.5;
        }
    }
}

const EccWork = struct {
    image: []f32,
    gradient_x: []f32,
    gradient_y: []f32,
    mask: []u8,
    template_zm: []f32,

    fn init(allocator: std.mem.Allocator, len: usize) !EccWork {
        const image = try allocator.alloc(f32, len);
        errdefer allocator.free(image);
        const gradient_x = try allocator.alloc(f32, len);
        errdefer allocator.free(gradient_x);
        const gradient_y = try allocator.alloc(f32, len);
        errdefer allocator.free(gradient_y);
        const mask = try allocator.alloc(u8, len);
        errdefer allocator.free(mask);
        const template_zm = try allocator.alloc(f32, len);
        return .{
            .image = image,
            .gradient_x = gradient_x,
            .gradient_y = gradient_y,
            .mask = mask,
            .template_zm = template_zm,
        };
    }

    fn deinit(self: EccWork, allocator: std.mem.Allocator) void {
        allocator.free(self.template_zm);
        allocator.free(self.mask);
        allocator.free(self.gradient_y);
        allocator.free(self.gradient_x);
        allocator.free(self.image);
    }
};

fn eccTranslationIteration(
    template_f: []const f32,
    image_f: []const f32,
    gradient_x: []const f32,
    gradient_y: []const f32,
    width: usize,
    height: usize,
    tx: *f64,
    ty: *f64,
    rho: *f64,
    last_rho: *f64,
    work: EccWork,
) !void {
    var valid_pixels: u32 = 0;
    var image_sum: f64 = 0.0;
    var template_sum: f64 = 0.0;
    for (0..height) |y| {
        for (0..width) |x| {
            const index = y * width + x;
            const sample_x = @as(f64, @floatFromInt(x)) + tx.*;
            const sample_y = @as(f64, @floatFromInt(y)) + ty.*;
            const valid = nearestInBounds(sample_x, width) and nearestInBounds(sample_y, height);
            work.mask[index] = if (valid) 1 else 0;
            work.image[index] = sampleConstantLinearOpenCv(image_f, width, height, sample_x, sample_y);
            work.gradient_x[index] = sampleConstantLinearOpenCv(gradient_x, width, height, sample_x, sample_y);
            work.gradient_y[index] = sampleConstantLinearOpenCv(gradient_y, width, height, sample_x, sample_y);
            if (valid) {
                valid_pixels += 1;
                image_sum += work.image[index];
                template_sum += template_f[index];
            }
        }
    }
    if (valid_pixels == 0) return error.InvalidBuffer;
    const inv_valid = 1.0 / @as(f64, @floatFromInt(valid_pixels));
    const image_mean = image_sum * inv_valid;
    const template_mean = template_sum * inv_valid;

    var image_norm_sq: f64 = 0.0;
    var template_norm_sq: f64 = 0.0;
    var h00: f64 = 0.0;
    var h01: f64 = 0.0;
    var h11: f64 = 0.0;
    var correlation: f64 = 0.0;
    var image_projection_x: f64 = 0.0;
    var image_projection_y: f64 = 0.0;
    var template_projection_x: f64 = 0.0;
    var template_projection_y: f64 = 0.0;
    for (0..template_f.len) |index| {
        const gx = @as(f64, @floatCast(work.gradient_x[index]));
        const gy = @as(f64, @floatCast(work.gradient_y[index]));
        const image_zero_mean = if (work.mask[index] != 0)
            @as(f64, @floatCast(work.image[index])) - image_mean
        else
            @as(f64, @floatCast(work.image[index]));
        const template_zero_mean = if (work.mask[index] != 0)
            @as(f64, @floatCast(template_f[index])) - template_mean
        else
            0.0;
        work.template_zm[index] = @floatCast(template_zero_mean);
        if (work.mask[index] != 0) image_norm_sq += image_zero_mean * image_zero_mean;
        template_norm_sq += template_zero_mean * template_zero_mean;
        correlation += template_zero_mean * image_zero_mean;
        h00 += gx * gx;
        h01 += gx * gy;
        h11 += gy * gy;
        image_projection_x += gx * image_zero_mean;
        image_projection_y += gy * image_zero_mean;
        template_projection_x += gx * template_zero_mean;
        template_projection_y += gy * template_zero_mean;
    }
    if (image_norm_sq <= 0.0 or template_norm_sq <= 0.0) return error.InvalidBuffer;
    const det = h00 * h11 - h01 * h01;
    if (@abs(det) < 1.0e-20) return error.InvalidBuffer;
    const inv00 = h11 / det;
    const inv01 = -h01 / det;
    const inv11 = h00 / det;

    last_rho.* = rho.*;
    rho.* = correlation / @sqrt(image_norm_sq * template_norm_sq);
    if (!std.math.isFinite(rho.*)) return error.InvalidBuffer;

    const image_projection_hessian_x = inv00 * image_projection_x + inv01 * image_projection_y;
    const image_projection_hessian_y = inv01 * image_projection_x + inv11 * image_projection_y;
    const lambda_n = image_norm_sq - (image_projection_x * image_projection_hessian_x + image_projection_y * image_projection_hessian_y);
    const lambda_d = correlation - (template_projection_x * image_projection_hessian_x + template_projection_y * image_projection_hessian_y);
    if (lambda_d <= 0.0 or !std.math.isFinite(lambda_d)) return error.InvalidBuffer;
    const lambda = lambda_n / lambda_d;

    var error_projection_x: f64 = 0.0;
    var error_projection_y: f64 = 0.0;
    for (0..template_f.len) |index| {
        const gx = @as(f64, @floatCast(work.gradient_x[index]));
        const gy = @as(f64, @floatCast(work.gradient_y[index]));
        const image_zero_mean = if (work.mask[index] != 0)
            @as(f64, @floatCast(work.image[index])) - image_mean
        else
            @as(f64, @floatCast(work.image[index]));
        const err = lambda * @as(f64, @floatCast(work.template_zm[index])) - image_zero_mean;
        error_projection_x += gx * err;
        error_projection_y += gy * err;
    }
    tx.* += inv00 * error_projection_x + inv01 * error_projection_y;
    ty.* += inv01 * error_projection_x + inv11 * error_projection_y;
}

fn reflect101Index(index: i32, len: usize) usize {
    if (len <= 1) return 0;
    var reflected = index;
    const n: i32 = @intCast(len);
    while (reflected < 0 or reflected >= n) {
        if (reflected < 0) {
            reflected = -reflected;
        } else {
            reflected = 2 * n - reflected - 2;
        }
    }
    return @intCast(reflected);
}

fn nearestInBounds(value: f64, len: usize) bool {
    const rounded: i32 = @intFromFloat(@floor(value + 0.5));
    return rounded >= 0 and rounded < @as(i32, @intCast(len));
}

fn sampleConstantLinearOpenCv(values: []const f32, width: usize, height: usize, x: f64, y: f64) f32 {
    var x0: i32 = @intFromFloat(@floor(x));
    var y0: i32 = @intFromFloat(@floor(y));
    var ix: i32 = @intFromFloat(@floor((x - @floor(x)) * 32.0 + 0.5));
    var iy: i32 = @intFromFloat(@floor((y - @floor(y)) * 32.0 + 0.5));
    if (ix == 32) {
        x0 += 1;
        ix = 0;
    }
    if (iy == 32) {
        y0 += 1;
        iy = 0;
    }
    const xf = @as(f32, @floatFromInt(ix)) / 32.0;
    const yf = @as(f32, @floatFromInt(iy)) / 32.0;
    const v00 = sampleConstantNearest(values, width, height, x0, y0);
    const v10 = sampleConstantNearest(values, width, height, x0 + 1, y0);
    const v01 = sampleConstantNearest(values, width, height, x0, y0 + 1);
    const v11 = sampleConstantNearest(values, width, height, x0 + 1, y0 + 1);
    const top = v00 * (1.0 - xf) + v10 * xf;
    const bottom = v01 * (1.0 - xf) + v11 * xf;
    return top * (1.0 - yf) + bottom * yf;
}

fn sampleConstantNearest(values: []const f32, width: usize, height: usize, x: i32, y: i32) f32 {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(width)) or y >= @as(i32, @intCast(height))) return 0.0;
    return values[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))];
}

pub const TranslationEstimate = struct {
    tx: f64,
    ty: f64,
    rho: f64,
    iterations: u32,
};

pub fn estimateTranslationEccF32(
    allocator: std.mem.Allocator,
    rgb_f32: []const f32,
    rgb_width: usize,
    rgb_height: usize,
    ir_f32: []const f32,
    ir_width: usize,
    ir_height: usize,
    ecc_scale: f64,
    max_iterations: u32,
    epsilon: f64,
) !TranslationEstimate {
    return estimateTranslationEcc(f32, allocator, rgb_f32, rgb_width, rgb_height, ir_f32, ir_width, ir_height, ecc_scale, max_iterations, epsilon);
}

/// Translation-only ECC of the IR channel against the RGB image's gray at
/// IR resolution. `T` is the sample type (f32 in the browser, f64 natively,
/// so a full-resolution strip is never copied). Sizes and indexes are usize,
/// so strips past 2^31 samples work.
pub fn estimateTranslationEcc(
    comptime T: type,
    allocator: std.mem.Allocator,
    rgb: []const T,
    rgb_width: usize,
    rgb_height: usize,
    ir: []const T,
    ir_width: usize,
    ir_height: usize,
    ecc_scale: f64,
    max_iterations: u32,
    epsilon: f64,
) !TranslationEstimate {
    const ir_pixels = ir_width * ir_height;

    const gray_ir = try allocator.alloc(u8, ir_pixels);
    defer allocator.free(gray_ir);
    try rgbToIrGrayU8(T, allocator, rgb, rgb_width, rgb_height, gray_ir, ir_width, ir_height);

    const ir_u8 = try allocator.alloc(u8, ir_pixels);
    defer allocator.free(ir_u8);
    try samplesToU8(T, ir, ir_u8);

    const small_width = @max(@as(usize, 1), @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(ir_width)) * ecc_scale))));
    const small_height = @max(@as(usize, 1), @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(ir_height)) * ecc_scale))));
    if (small_width < 2 or small_height < 2) return error.InvalidDimensions;
    const small_pixels = small_width * small_height;

    const template_u8 = try allocator.alloc(u8, small_pixels);
    defer allocator.free(template_u8);
    const image_u8 = try allocator.alloc(u8, small_pixels);
    defer allocator.free(image_u8);
    areaResizeU8(gray_ir, ir_width, ir_height, template_u8, small_width, small_height);
    areaResizeU8(ir_u8, ir_width, ir_height, image_u8, small_width, small_height);

    const template_f = try allocator.alloc(f32, small_pixels);
    defer allocator.free(template_f);
    const image_f = try allocator.alloc(f32, small_pixels);
    defer allocator.free(image_f);
    for (template_u8, template_f) |sample, *out| out.* = @floatFromInt(sample);
    for (image_u8, image_f) |sample, *out| out.* = @floatFromInt(sample);
    try gaussianBlur5Reflect101InPlace(allocator, template_f, small_width, small_height);
    try gaussianBlur5Reflect101InPlace(allocator, image_f, small_width, small_height);

    const gradient_x = try allocator.alloc(f32, small_pixels);
    defer allocator.free(gradient_x);
    const gradient_y = try allocator.alloc(f32, small_pixels);
    defer allocator.free(gradient_y);
    gradientCentralReflect101(image_f, small_width, small_height, gradient_x, gradient_y);

    const work = try EccWork.init(allocator, small_pixels);
    defer work.deinit(allocator);

    var tx: f64 = 0.0;
    var ty: f64 = 0.0;
    var rho: f64 = -1.0;
    var last_rho: f64 = -epsilon;
    var iterations: u32 = 0;
    while (iterations < max_iterations and @abs(rho - last_rho) >= epsilon) {
        iterations += 1;
        try eccTranslationIteration(template_f, image_f, gradient_x, gradient_y, small_width, small_height, &tx, &ty, &rho, &last_rho, work);
    }

    return .{
        .tx = tx / ecc_scale,
        .ty = ty / ecc_scale,
        .rho = rho,
        .iterations = iterations,
    };
}
