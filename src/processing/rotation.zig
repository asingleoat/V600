//! Rotation and crop geometry: expanded-rotation transforms, the
//! replicate-boundary rotation resample, the OpenCV-style rotated rect crop,
//! and the byte-sample helpers shared with detection gray preparation.

const std = @import("std");
const parallelism = @import("parallelism.zig");

pub const rotation_parallel_min_pixels: usize = 1_000_000;
pub const FrameRect = struct {
    cx: f64,
    cy: f64,
    w: f64,
    h: f64,
    angle: f64,
};

pub const AffineTransform = struct {
    values: [6]f64,
};

pub const ExpandedRotation = struct {
    rotated_width: usize,
    rotated_height: usize,
    forward: AffineTransform,
    inverse: AffineTransform,
};

pub const RotatedCrop = struct {
    width: usize,
    height: usize,
    pixels: []f64,

    pub fn deinit(self: *RotatedCrop, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const RotationRowsContext = struct {
    image: []const f64,
    pixels: []f64,
    width: usize,
    height: usize,
    rotated_width: usize,
    inverse: [6]f64,
    y_start: usize,
    y_end: usize,
};

pub fn expandedRotationTransform(orig_width: usize, orig_height: usize, angle_rad: f64) !ExpandedRotation {
    if (orig_width == 0 or orig_height == 0 or !std.math.isFinite(angle_rad)) return error.InvalidRotationTransformInput;
    const center_x = @as(f64, @floatFromInt(orig_width)) / 2.0;
    const center_y = @as(f64, @floatFromInt(orig_height)) / 2.0;
    const alpha = std.math.cos(angle_rad);
    const beta = std.math.sin(angle_rad);
    var forward = AffineTransform{ .values = .{
        alpha,
        beta,
        (1.0 - alpha) * center_x - beta * center_y,
        -beta,
        alpha,
        beta * center_x + (1.0 - alpha) * center_y,
    } };
    const rotated_width: usize = @intFromFloat(@as(f64, @floatFromInt(orig_height)) * @abs(beta) + @as(f64, @floatFromInt(orig_width)) * @abs(alpha));
    const rotated_height: usize = @intFromFloat(@as(f64, @floatFromInt(orig_height)) * @abs(alpha) + @as(f64, @floatFromInt(orig_width)) * @abs(beta));
    forward.values[2] += @as(f64, @floatFromInt(rotated_width)) / 2.0 - center_x;
    forward.values[5] += @as(f64, @floatFromInt(rotated_height)) / 2.0 - center_y;
    return .{
        .rotated_width = rotated_width,
        .rotated_height = rotated_height,
        .forward = forward,
        .inverse = try invertAffineTransform(forward),
    };
}

pub fn transformFramesFromRotatedToOriginal(frames: []FrameRect, inverse: AffineTransform, strip_angle_rad: f64) !void {
    if (!std.math.isFinite(strip_angle_rad)) return error.InvalidRotationTransformInput;
    for (frames) |*frame| {
        if (!std.math.isFinite(frame.cx) or !std.math.isFinite(frame.cy) or !std.math.isFinite(frame.angle)) {
            return error.InvalidRotationTransformInput;
        }
        const rcx = frame.cx;
        const rcy = frame.cy;
        frame.cx = inverse.values[0] * rcx + inverse.values[1] * rcy + inverse.values[2];
        frame.cy = inverse.values[3] * rcx + inverse.values[4] * rcy + inverse.values[5];
        frame.angle += strip_angle_rad;
    }
}

pub fn rotateImageExpandedReplicate(
    allocator: std.mem.Allocator,
    image: []const f64,
    width: usize,
    height: usize,
    angle_rad: f64,
) !RotatedCrop {
    if (width == 0 or height == 0 or image.len != width * height) return error.InvalidRotationTransformInput;
    const transform = try expandedRotationTransform(width, height, angle_rad);
    const pixels = try allocator.alloc(f64, transform.rotated_width * transform.rotated_height);
    errdefer allocator.free(pixels);
    const pixel_count = transform.rotated_width * transform.rotated_height;
    if (parallelism.enabled and pixel_count >= rotation_parallel_min_pixels) {
        const cpu_count = std.Thread.getCpuCount() catch 1;
        const worker_limit = if (cpu_count > 1) cpu_count - 1 else 1;
        const worker_count = @min(worker_limit, transform.rotated_height);
        if (worker_count > 1) {
            try rotateImageExpandedReplicateParallel(
                allocator,
                image,
                pixels,
                width,
                height,
                transform.rotated_width,
                transform.rotated_height,
                transform.inverse.values,
                worker_count,
            );
            return .{ .width = transform.rotated_width, .height = transform.rotated_height, .pixels = pixels };
        }
    }
    rotateImageExpandedReplicateRows(image, pixels, width, height, transform.rotated_width, transform.inverse.values, 0, transform.rotated_height);
    return .{ .width = transform.rotated_width, .height = transform.rotated_height, .pixels = pixels };
}

pub fn rotateImageExpandedReplicateParallel(
    allocator: std.mem.Allocator,
    image: []const f64,
    pixels: []f64,
    width: usize,
    height: usize,
    rotated_width: usize,
    rotated_height: usize,
    inverse: [6]f64,
    worker_count: usize,
) !void {
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(RotationRowsContext, worker_count);
    defer allocator.free(contexts);
    var started: usize = 0;
    errdefer {
        for (threads[0..started]) |thread| {
            thread.join();
        }
    }
    for (0..worker_count) |worker_index| {
        const y_start = rotated_height * worker_index / worker_count;
        const y_end = rotated_height * (worker_index + 1) / worker_count;
        contexts[worker_index] = .{
            .image = image,
            .pixels = pixels,
            .width = width,
            .height = height,
            .rotated_width = rotated_width,
            .inverse = inverse,
            .y_start = y_start,
            .y_end = y_end,
        };
        threads[worker_index] = try std.Thread.spawn(.{}, rotateImageExpandedReplicateWorker, .{&contexts[worker_index]});
        started += 1;
    }
    for (threads) |thread| {
        thread.join();
    }
}

pub fn rotateImageExpandedReplicateWorker(context: *const RotationRowsContext) void {
    rotateImageExpandedReplicateRows(
        context.image,
        context.pixels,
        context.width,
        context.height,
        context.rotated_width,
        context.inverse,
        context.y_start,
        context.y_end,
    );
}

pub fn rotateImageExpandedReplicateRows(
    image: []const f64,
    pixels: []f64,
    width: usize,
    height: usize,
    rotated_width: usize,
    inverse: [6]f64,
    y_start: usize,
    y_end: usize,
) void {
    for (y_start..y_end) |y| {
        const fy = @as(f64, @floatFromInt(y));
        var src_x = inverse[1] * fy + inverse[2];
        var src_y = inverse[4] * fy + inverse[5];
        for (0..rotated_width) |x| {
            pixels[y * rotated_width + x] = sampleReplicateBilinear(image, width, height, src_x, src_y);
            src_x += inverse[0];
            src_y += inverse[3];
        }
    }
}

pub fn cropRotatedRect(
    allocator: std.mem.Allocator,
    image: []const f64,
    img_width: usize,
    img_height: usize,
    cx: f64,
    cy: f64,
    w: f64,
    h: f64,
    angle_deg: f64,
) !RotatedCrop {
    if (img_width == 0 or img_height == 0 or image.len != img_width * img_height) return error.InvalidRotatedCropInput;
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or !std.math.isFinite(w) or !std.math.isFinite(h) or !std.math.isFinite(angle_deg)) {
        return error.InvalidRotatedCropInput;
    }
    if (w <= 0.0 or h <= 0.0) return error.InvalidRotatedCropInput;

    const diag = @sqrt(w * w + h * h) / 2.0;
    const margin: i64 = @as(i64, @intFromFloat(@ceil(diag))) + 4;
    const cx_i: i64 = @intFromFloat(cx);
    const cy_i: i64 = @intFromFloat(cy);
    const x0_i = @max(cx_i - margin, 0);
    const y0_i = @max(cy_i - margin, 0);
    const x1_i = @min(cx_i + margin, @as(i64, @intCast(img_width)));
    const y1_i = @min(cy_i + margin, @as(i64, @intCast(img_height)));
    if (x1_i <= x0_i or y1_i <= y0_i) return error.InvalidRotatedCropInput;

    const x0: usize = @intCast(x0_i);
    const y0: usize = @intCast(y0_i);
    const sub_w: usize = @intCast(x1_i - x0_i);
    const sub_h: usize = @intCast(y1_i - y0_i);
    const local_cx = cx - @as(f64, @floatFromInt(x0));
    const local_cy = cy - @as(f64, @floatFromInt(y0));

    const pad: usize = 2;
    const out_w: usize = @as(usize, @intFromFloat(@ceil(w))) + pad * 2;
    const out_h: usize = @as(usize, @intFromFloat(@ceil(h))) + pad * 2;
    const final_w: usize = @intFromFloat(w);
    const final_h: usize = @intFromFloat(h);
    if (final_w == 0 or final_h == 0) return error.InvalidRotatedCropInput;

    const radians = angle_deg * std.math.pi / 180.0;
    const alpha = @cos(radians);
    const beta = @sin(radians);
    const m00 = alpha;
    const m01 = beta;
    var m02 = (1.0 - alpha) * local_cx - beta * local_cy;
    const m10 = -beta;
    const m11 = alpha;
    var m12 = beta * local_cx + (1.0 - alpha) * local_cy;
    m02 += @as(f64, @floatFromInt(out_w)) / 2.0 - local_cx;
    m12 += @as(f64, @floatFromInt(out_h)) / 2.0 - local_cy;

    const det = m00 * m11 - m01 * m10;
    if (@abs(det) < 1e-12) return error.InvalidRotatedCropInput;
    const inv00 = m11 / det;
    const inv01 = -m01 / det;
    const inv10 = -m10 / det;
    const inv11 = m00 / det;

    const pixels = try allocator.alloc(f64, final_w * final_h);
    errdefer allocator.free(pixels);
    for (0..final_h) |out_y| {
        for (0..final_w) |out_x| {
            const dst_x = @as(f64, @floatFromInt(out_x + pad));
            const dst_y = @as(f64, @floatFromInt(out_y + pad));
            const tx = dst_x - m02;
            const ty = dst_y - m12;
            const src_x = inv00 * tx + inv01 * ty;
            const src_y = inv10 * tx + inv11 * ty;
            pixels[out_y * final_w + out_x] = sampleReflectBilinear(image, img_width, x0, y0, sub_w, sub_h, src_x, src_y);
        }
    }
    return .{ .width = final_w, .height = final_h, .pixels = pixels };
}

pub fn sampleToPythonGray8(data: []const u8, sample_index: usize, bits_per_sample: u16) u8 {
    const sample = sampleToU16(data, sample_index, bits_per_sample);
    if (bits_per_sample == 8) return @intCast(sample);
    return @intCast(sample / 256);
}

pub fn sampleToU16(data: []const u8, sample_index: usize, bits_per_sample: u16) u16 {
    if (bits_per_sample == 8) return data[sample_index];
    const byte_index = sample_index * 2;
    return std.mem.readInt(u16, data[byte_index..][0..2], .little);
}

pub fn writeRoundedSample(data: []u8, sample_index: usize, bits_per_sample: u16, value: f64) void {
    const max_value: f64 = if (bits_per_sample == 8) 255.0 else 65535.0;
    const rounded: u16 = if (!std.math.isFinite(value) or value <= 0.0)
        0
    else if (value >= max_value)
        @intFromFloat(max_value)
    else
        @intFromFloat(@floor(value + 0.5));
    if (bits_per_sample == 8) {
        data[sample_index] = @intCast(rounded);
    } else {
        const byte_index = sample_index * 2;
        std.mem.writeInt(u16, data[byte_index..][0..2], rounded, .little);
    }
}

pub fn invertAffineTransform(transform: AffineTransform) !AffineTransform {
    const a = transform.values[0];
    const b = transform.values[1];
    const c = transform.values[2];
    const d = transform.values[3];
    const e = transform.values[4];
    const f = transform.values[5];
    const det = a * e - b * d;
    if (@abs(det) <= 1e-15) return error.InvalidRotationTransformInput;
    return .{ .values = .{
        e / det,
        -b / det,
        (b * f - c * e) / det,
        -d / det,
        a / det,
        (c * d - a * f) / det,
    } };
}

pub fn sampleReplicateBilinear(image: []const f64, width: usize, height: usize, x: f64, y: f64) f64 {
    const x_floor = @floor(x);
    const y_floor = @floor(y);
    const xi: i64 = @intFromFloat(x_floor);
    const yi: i64 = @intFromFloat(y_floor);
    const fx = x - x_floor;
    const fy = y - y_floor;
    const x0 = clampIndex(xi, width);
    const x1 = clampIndex(xi + 1, width);
    const y0 = clampIndex(yi, height);
    const y1 = clampIndex(yi + 1, height);
    const p00 = image[y0 * width + x0];
    const p10 = image[y0 * width + x1];
    const p01 = image[y1 * width + x0];
    const p11 = image[y1 * width + x1];
    const top = p00 * (1.0 - fx) + p10 * fx;
    const bottom = p01 * (1.0 - fx) + p11 * fx;
    return top * (1.0 - fy) + bottom * fy;
}

pub fn clampIndex(index: i64, len: usize) usize {
    if (index <= 0) return 0;
    const value: usize = @intCast(index);
    return @min(value, len - 1);
}

pub fn sampleReflectBilinear(
    image: []const f64,
    img_width: usize,
    x0: usize,
    y0: usize,
    sub_w: usize,
    sub_h: usize,
    x: f64,
    y: f64,
) f64 {
    const x_floor = @floor(x);
    const y_floor = @floor(y);
    const xi: i64 = @intFromFloat(x_floor);
    const yi: i64 = @intFromFloat(y_floor);
    const fx = x - x_floor;
    const fy = y - y_floor;
    const x_a = reflectIndex(xi, sub_w);
    const x_b = reflectIndex(xi + 1, sub_w);
    const y_a = reflectIndex(yi, sub_h);
    const y_b = reflectIndex(yi + 1, sub_h);
    const p00 = image[(y0 + y_a) * img_width + x0 + x_a];
    const p10 = image[(y0 + y_a) * img_width + x0 + x_b];
    const p01 = image[(y0 + y_b) * img_width + x0 + x_a];
    const p11 = image[(y0 + y_b) * img_width + x0 + x_b];
    const top = p00 * (1.0 - fx) + p10 * fx;
    const bottom = p01 * (1.0 - fx) + p11 * fx;
    return top * (1.0 - fy) + bottom * fy;
}

pub fn reflectIndex(index: i64, len: usize) usize {
    if (len <= 1) return 0;
    const n: i64 = @intCast(len);
    var reflected = index;
    while (reflected < 0 or reflected >= n) {
        if (reflected < 0) {
            reflected = -reflected - 1;
        } else {
            reflected = 2 * n - reflected - 1;
        }
    }
    return @intCast(reflected);
}
