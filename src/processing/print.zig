//! Print copies of exported frames: an 8-bit sRGB JPEG scaled to fit a print
//! size at a printing resolution, written next to the frame's 16-bit TIFF.
//!
//! The sizes are the common lab print sizes plus the paper sizes Epson's
//! EcoTank photo printers take (up to 13 x 19 in on the ET-8550). The
//! resolutions are the 300 ppi labs print at (Fuji Frontier, Noritsu) and the
//! 360 and 720 ppi Epson's printer drivers work at.
const std = @import("std");

const color = @import("color.zig");
const config = @import("config.zig");
const parallelism = @import("parallelism.zig");

pub const Size = struct {
    /// The `print_size` config value, and the size in the copy's file name.
    name: []const u8,
    label: [:0]const u8,
    short_in: f64,
    long_in: f64,
};

const mm_per_inch = 25.4;

/// Smallest first.
pub const sizes = [_]Size{
    .{ .name = "4x6", .label = "4 x 6 in", .short_in = 4, .long_in = 6 },
    .{ .name = "5x7", .label = "5 x 7 in", .short_in = 5, .long_in = 7 },
    .{ .name = "8x8", .label = "8 x 8 in", .short_in = 8, .long_in = 8 },
    .{ .name = "8x10", .label = "8 x 10 in", .short_in = 8, .long_in = 10 },
    .{ .name = "letter", .label = "Letter 8.5 x 11 in", .short_in = 8.5, .long_in = 11 },
    .{ .name = "8x12", .label = "8 x 12 in", .short_in = 8, .long_in = 12 },
    .{ .name = "a4", .label = "A4 210 x 297 mm", .short_in = 210.0 / mm_per_inch, .long_in = 297.0 / mm_per_inch },
    .{ .name = "12x12", .label = "12 x 12 in", .short_in = 12, .long_in = 12 },
    .{ .name = "11x14", .label = "11 x 14 in", .short_in = 11, .long_in = 14 },
    .{ .name = "11x17", .label = "11 x 17 in", .short_in = 11, .long_in = 17 },
    .{ .name = "a3", .label = "A3 297 x 420 mm", .short_in = 297.0 / mm_per_inch, .long_in = 420.0 / mm_per_inch },
    .{ .name = "12x18", .label = "12 x 18 in", .short_in = 12, .long_in = 18 },
    .{ .name = "13x19", .label = "A3+ 13 x 19 in", .short_in = 13, .long_in = 19 },
    .{ .name = "16x20", .label = "16 x 20 in", .short_in = 16, .long_in = 20 },
    .{ .name = "16x24", .label = "16 x 24 in", .short_in = 16, .long_in = 24 },
    .{ .name = "20x30", .label = "20 x 30 in", .short_in = 20, .long_in = 30 },
    .{ .name = "24x36", .label = "24 x 36 in", .short_in = 24, .long_in = 36 },
};

pub const Resolution = struct {
    dpi: u32,
    label: [:0]const u8,
};

pub const resolutions = [_]Resolution{
    .{ .dpi = 300, .label = "300 dpi: labs" },
    .{ .dpi = 360, .label = "360 dpi: Epson" },
    .{ .dpi = 720, .label = "720 dpi: Epson, finest" },
};
pub const default_dpi: u32 = 360;
/// Resolutions the config and the CLI accept beyond the listed ones.
pub const min_dpi: u32 = 72;
pub const max_dpi: u32 = 2400;

pub const jpeg_quality = 95;

pub const Spec = struct {
    size: *const Size,
    dpi: u32 = default_dpi,
};

pub fn sizeIndex(name: []const u8) ?usize {
    for (sizes, 0..) |size, index| {
        if (std.ascii.eqlIgnoreCase(size.name, name)) return index;
    }
    return null;
}

pub fn sizeNamed(name: []const u8) ?*const Size {
    return &sizes[sizeIndex(name) orelse return null];
}

/// The print copy the config asks for: `print_size` names a size (absent,
/// "off", or unknown for none) and `print_dpi` its resolution.
pub fn specForConfig(overrides: []const config.Override) ?Spec {
    var size: ?*const Size = null;
    var dpi = default_dpi;
    for (overrides) |*entry| {
        if (std.mem.eql(u8, entry.name, "print_size")) {
            size = switch (entry.value) {
                .string => |*name| sizeNamed(name.slice()),
                else => null,
            };
        } else if (std.mem.eql(u8, entry.name, "print_dpi")) {
            const value = entry.value.asFloat();
            if (value >= min_dpi and value <= max_dpi) dpi = @intFromFloat(@round(value));
        }
    }
    return .{ .size = size orelse return null, .dpi = dpi };
}

pub const Fit = struct {
    width: usize,
    height: usize,
    /// The resolution written to the file: the spec's, or lower when the
    /// image has too few pixels to fill the size at the spec's.
    dpi: u32,
    /// The copy is the image's own pixels, the middle `width` x `height`:
    /// at most a row or column goes, so its shape is exactly the frame's.
    kept: bool = false,
};

/// The copy's pixel size: the image scaled to fit inside the print, turned
/// the way the image is, without cropping. `aspect` is the frame's true
/// width over height, which the image's whole pixels only approximate (the
/// crop cuts a fraction of a pixel off each side), so an exact-aspect frame
/// gives a copy of exactly its aspect. Never scales up: an image with too
/// few pixels keeps them, at the resolution that fits the print.
pub fn fit(width: usize, height: usize, aspect: f64, spec: Spec) Fit {
    const landscape = width > height;
    const across_in = if (landscape) spec.size.long_in else spec.size.short_in;
    const down_in = if (landscape) spec.size.short_in else spec.size.long_in;
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const dpi: f64 = @floatFromInt(spec.dpi);
    const box_w = @floor(across_in * dpi + 1e-6);
    const box_h = @floor(down_in * dpi + 1e-6);
    if (w <= box_w and h <= box_h) {
        const exact_w = @round(h * aspect);
        const kept_w = @max(1.0, @min(w, exact_w));
        const kept_h = if (exact_w <= w) h else @max(1.0, @min(h, @round(w / aspect)));
        const fitting_dpi = @max(kept_w / across_in, kept_h / down_in);
        return .{
            .width = @intFromFloat(kept_w),
            .height = @intFromFloat(kept_h),
            .dpi = @max(1, @as(u32, @intFromFloat(@ceil(fitting_dpi - 1e-9)))),
            .kept = true,
        };
    }
    if (aspect >= box_w / box_h) {
        return .{ .width = @intFromFloat(box_w), .height = scaledSide(box_w / aspect, box_h), .dpi = spec.dpi };
    }
    return .{ .width = scaledSide(box_h * aspect, box_w), .height = @intFromFloat(box_h), .dpi = spec.dpi };
}

fn scaledSide(side: f64, limit: f64) usize {
    return @intFromFloat(@max(1.0, @min(limit, @round(side))));
}

/// `<tiff path without its extension>_<size>_<dpi>dpi.jpg`.
pub fn copyPath(allocator: std.mem.Allocator, tiff_path: []const u8, size: *const Size, dpi: u32) ![]u8 {
    const extension = std.fs.path.extension(tiff_path);
    const stem = tiff_path[0 .. tiff_path.len - extension.len];
    return std.fmt.allocPrint(allocator, "{s}_{s}_{d}dpi.jpg", .{ stem, size.name, dpi });
}

extern fn cerealgrain_write_rgb_jpeg_file(
    path: [*:0]const u8,
    rgb: [*]const u8,
    width: c_int,
    height: c_int,
    quality: c_int,
    dpi: c_int,
) c_int;

/// Writes the print copy of a 16-bit sRGB RGB image next to `tiff_path` and
/// returns the copy's path. `aspect` is the frame's true width over height.
pub fn writeCopy(
    allocator: std.mem.Allocator,
    tiff_path: []const u8,
    pixels: []const u16,
    width: usize,
    height: usize,
    aspect: f64,
    spec: Spec,
) ![]u8 {
    const fitted = fit(width, height, aspect, spec);
    const rgb = if (fitted.kept)
        try trimToSrgb8(allocator, pixels, width, height, fitted.width, fitted.height)
    else
        try downscaleToSrgb8(allocator, pixels, width, height, fitted.width, fitted.height);
    defer allocator.free(rgb);
    const path = try copyPath(allocator, tiff_path, spec.size, fitted.dpi);
    errdefer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const status = cerealgrain_write_rgb_jpeg_file(
        path_z.ptr,
        rgb.ptr,
        std.math.cast(c_int, fitted.width) orelse return error.PrintCopyTooLarge,
        std.math.cast(c_int, fitted.height) orelse return error.PrintCopyTooLarge,
        jpeg_quality,
        @intCast(fitted.dpi),
    );
    if (status != 0) return error.PrintCopyWriteFailed;
    return path;
}

/// The middle `out_width` x `out_height` of a 16-bit RGB image, in 8 bits.
pub fn trimToSrgb8(
    allocator: std.mem.Allocator,
    pixels: []const u16,
    width: usize,
    height: usize,
    out_width: usize,
    out_height: usize,
) ![]u8 {
    std.debug.assert(pixels.len == width * height * 3);
    std.debug.assert(out_width <= width and out_height <= height);
    const output = try allocator.alloc(u8, out_width * out_height * 3);
    const x0 = (width - out_width) / 2;
    const y0 = (height - out_height) / 2;
    for (0..out_height) |y| {
        const row = pixels[((y0 + y) * width + x0) * 3 ..][0 .. out_width * 3];
        for (row, output[y * out_width * 3 ..][0 .. out_width * 3]) |value, *out| {
            out.* = @intCast((@as(u32, value) * 255 + 32767) / 65535);
        }
    }
    return output;
}

/// Area-averages a 16-bit sRGB RGB image down to `out_width` x
/// `out_height` 8-bit sRGB, averaging in linear light so fine detail keeps
/// its brightness.
pub fn downscaleToSrgb8(
    allocator: std.mem.Allocator,
    pixels: []const u16,
    width: usize,
    height: usize,
    out_width: usize,
    out_height: usize,
) ![]u8 {
    std.debug.assert(pixels.len == width * height * 3);
    std.debug.assert(out_width <= width and out_height <= height and out_width > 0 and out_height > 0);
    const output = try allocator.alloc(u8, out_width * out_height * 3);
    errdefer allocator.free(output);

    const decode = try allocator.alloc(f32, 65536);
    defer allocator.free(decode);
    for (decode, 0..) |*value, index| {
        value.* = @floatCast(color.srgbToLinearValue(@as(f64, @floatFromInt(index)) / 65535.0));
    }
    var encode: [255]f32 = undefined;
    for (&encode, 0..) |*threshold, index| {
        threshold.* = @floatCast(color.srgbToLinearValue((@as(f64, @floatFromInt(index)) + 0.5) / 255.0));
    }
    const xs = try areaSpans(allocator, width, out_width);
    defer allocator.free(xs);
    const ys = try areaSpans(allocator, height, out_height);
    defer allocator.free(ys);

    try parallelism.forRowBands(allocator, out_height, Downscale{
        .pixels = pixels,
        .width = width,
        .xs = xs,
        .ys = ys,
        .decode = decode,
        .encode = &encode,
        .output = output,
    }, Downscale.rows);
    return output;
}

/// The source pixels an output pixel covers, `start..end`, with the
/// fractions of the first and last that fall inside it.
const Span = struct {
    start: usize,
    end: usize,
    first: f32,
    last: f32,
    /// The covered length, in source pixels.
    total: f32,

    fn weight(self: Span, index: usize) f32 {
        if (index == self.start) return self.first;
        if (index + 1 == self.end) return self.last;
        return 1.0;
    }
};

fn areaSpans(allocator: std.mem.Allocator, in_len: usize, out_len: usize) ![]Span {
    const spans = try allocator.alloc(Span, out_len);
    const scale = @as(f64, @floatFromInt(in_len)) / @as(f64, @floatFromInt(out_len));
    for (spans, 0..) |*span, index| {
        const lo = @as(f64, @floatFromInt(index)) * scale;
        const hi = if (index + 1 == out_len) @as(f64, @floatFromInt(in_len)) else @as(f64, @floatFromInt(index + 1)) * scale;
        const start: usize = @intFromFloat(@floor(lo));
        const end: usize = @min(in_len, @as(usize, @intFromFloat(@ceil(hi))));
        span.* = .{
            .start = start,
            .end = end,
            .first = @floatCast(@min(@as(f64, @floatFromInt(start + 1)), hi) - lo),
            .last = @floatCast(hi - @max(@as(f64, @floatFromInt(end - 1)), lo)),
            .total = @floatCast(hi - lo),
        };
    }
    return spans;
}

const Downscale = struct {
    pixels: []const u16,
    width: usize,
    xs: []const Span,
    ys: []const Span,
    decode: []const f32,
    encode: *const [255]f32,
    output: []u8,

    fn rows(self: Downscale, row_start: usize, row_end: usize) void {
        const Vec = @Vector(3, f32);
        const out_width = self.xs.len;
        for (row_start..row_end) |oy| {
            const ys = self.ys[oy];
            for (self.xs, 0..) |xs, ox| {
                var acc: Vec = @splat(0.0);
                for (ys.start..ys.end) |sy| {
                    const row = self.pixels[sy * self.width * 3 ..][0 .. self.width * 3];
                    var sum: Vec = @splat(0.0);
                    for (xs.start..xs.end) |sx| {
                        const pixel: Vec = .{ self.decode[row[sx * 3]], self.decode[row[sx * 3 + 1]], self.decode[row[sx * 3 + 2]] };
                        sum += pixel * @as(Vec, @splat(xs.weight(sx)));
                    }
                    acc += sum * @as(Vec, @splat(ys.weight(sy)));
                }
                const mean = acc / @as(Vec, @splat(xs.total * ys.total));
                const out = self.output[(oy * out_width + ox) * 3 ..][0..3];
                inline for (0..3) |channel| out[channel] = encodeSrgb8(self.encode, mean[channel]);
            }
        }
    }
};

/// The nearest 8-bit sRGB code for a linear value: how many code midpoints
/// lie at or below it.
fn encodeSrgb8(thresholds: *const [255]f32, value: f32) u8 {
    var lo: usize = 0;
    var hi: usize = thresholds.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (value >= thresholds[mid]) lo = mid + 1 else hi = mid;
    }
    return @intCast(lo);
}

test "print sizes fit the image without cropping and never scale it up" {
    const eight_by_ten = Spec{ .size = sizeNamed("8x10").?, .dpi = 360 };
    // 35mm at 6400 dpi, landscape: the long side fills 10 in, the short one
    // falls short of 8 in (2:3 against 4:5).
    try std.testing.expectEqual(Fit{ .width = 3600, .height = 2400, .dpi = 360 }, fit(9070, 6047, 9070.0 / 6047.0, eight_by_ten));
    // Portrait turns the print too.
    try std.testing.expectEqual(Fit{ .width = 2400, .height = 3600, .dpi = 360 }, fit(6047, 9070, 6047.0 / 9070.0, eight_by_ten));
    // 6x7 (56 x 69 mm) is nearly 4:5: the short side fills 8 in.
    try std.testing.expectEqual(Fit{ .width = 3549, .height = 2880, .dpi = 360 }, fit(17386, 14110, 17386.0 / 14110.0, eight_by_ten));
    // A4 at 300 dpi is 2480 x 3507 px, rounded down so it fits.
    try std.testing.expectEqual(Fit{ .width = 2338, .height = 3507, .dpi = 300 }, fit(6047, 9070, 6047.0 / 9070.0, .{ .size = sizeNamed("a4").?, .dpi = 300 }));
    // Too few pixels for 24 x 36 in at 300 dpi: keep them, print at 252.
    try std.testing.expectEqual(Fit{ .width = 9070, .height = 6047, .dpi = 252, .kept = true }, fit(9070, 6047, 9070.0 / 6047.0, .{ .size = sizeNamed("24x36").?, .dpi = 300 }));
    // Square film on a square print.
    try std.testing.expectEqual(Fit{ .width = 2400, .height = 2400, .dpi = 300 }, fit(14000, 14000, 1.0, .{ .size = sizeNamed("8x8").?, .dpi = 300 }));
}

test "an exact-aspect frame cut to whole pixels gives a copy of exactly its aspect" {
    // A 2:3 frame of 3058.8 x 4588.2 px crops to 3058 x 4588, which alone
    // would give 2879 x 4320 on 8 x 12 in and 2805 x 4209 on A4.
    const exact = 2.0 / 3.0;
    try std.testing.expectEqual(Fit{ .width = 2880, .height = 4320, .dpi = 360 }, fit(3058, 4588, exact, .{ .size = sizeNamed("8x12").?, .dpi = 360 }));
    try std.testing.expectEqual(Fit{ .width = 2806, .height = 4209, .dpi = 360 }, fit(3058, 4588, exact, .{ .size = sizeNamed("a4").?, .dpi = 360 }));
    try std.testing.expectEqual(Fit{ .width = 2000, .height = 3000, .dpi = 300 }, fit(3058, 4588, exact, .{ .size = sizeNamed("8x10").?, .dpi = 300 }));
    // Kept at full size on A3, the frame loses its stray row instead.
    try std.testing.expectEqual(Fit{ .width = 3058, .height = 4587, .dpi = 278, .kept = true }, fit(3058, 4588, exact, .{ .size = sizeNamed("a3").?, .dpi = 300 }));
    // A camera's own frame, half a percent wider than 2:3, keeps its shape.
    try std.testing.expectEqual(Fit{ .width = 2000, .height = 2996, .dpi = 250 }, fit(3063, 4588, 3063.0 / 4588.0, .{ .size = sizeNamed("8x12").?, .dpi = 250 }));
}

test "the print spec comes from the config, off unless a known size is named" {
    const size = try config.FixedString.from("8x12");
    try std.testing.expect(specForConfig(&.{}) == null);
    try std.testing.expect(specForConfig(&.{.{ .name = "print_size", .value = .{ .string = try config.FixedString.from("off") } }}) == null);
    const spec = specForConfig(&.{.{ .name = "print_size", .value = .{ .string = size } }}).?;
    try std.testing.expectEqualStrings("8x12", spec.size.name);
    try std.testing.expectEqual(default_dpi, spec.dpi);
    const lab = specForConfig(&.{
        .{ .name = "print_dpi", .value = .{ .integer = 300 } },
        .{ .name = "print_size", .value = .{ .string = try config.FixedString.from("A4") } },
    }).?;
    try std.testing.expectEqualStrings("a4", lab.size.name);
    try std.testing.expectEqual(@as(u32, 300), lab.dpi);
    const nonsense = specForConfig(&.{
        .{ .name = "print_size", .value = .{ .string = size } },
        .{ .name = "print_dpi", .value = .{ .integer = 5 } },
    }).?;
    try std.testing.expectEqual(default_dpi, nonsense.dpi);
}

test "print copies are named after their TIFF, size, and resolution" {
    const path = try copyPath(std.testing.allocator, "frames/gold/gold_s01_02.tif", sizeNamed("13x19").?, 360);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("frames/gold/gold_s01_02_13x19_360dpi.jpg", path);
}

test "the downscale averages in linear light and keeps flat areas exact" {
    const allocator = std.testing.allocator;
    // 4 x 2 pixels down to 2 x 1: the left pair black and white, the right
    // pair flat mid grey.
    const grey: u16 = 0x8080;
    const pixels = [_]u16{
        0,     0,     0,     65535, 65535, 65535, grey, grey, grey, grey, grey, grey,
        65535, 65535, 65535, 0,     0,     0,     grey, grey, grey, grey, grey, grey,
    };
    const out = try downscaleToSrgb8(allocator, &pixels, 4, 2, 2, 1);
    defer allocator.free(out);
    // Half black, half white is 50% linear, sRGB code 188, not 128.
    try std.testing.expectEqualSlices(u8, &.{ 188, 188, 188, 128, 128, 128 }, out);

    // Kept pixels go straight to 8 bits, the middle of them when trimmed.
    const same = try trimToSrgb8(allocator, &pixels, 4, 2, 4, 2);
    defer allocator.free(same);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 255, 255, 128, 128, 128 }, same[0..9]);
    const trimmed = try trimToSrgb8(allocator, &pixels, 4, 2, 2, 1);
    defer allocator.free(trimmed);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 128, 128, 128 }, trimmed);
}

test "the downscale weighs source pixels by how much of each an output pixel covers" {
    const allocator = std.testing.allocator;
    // 3 pixels down to 2: each output pixel covers one whole source pixel
    // and half of the middle one.
    const spans = try areaSpans(allocator, 3, 2);
    defer allocator.free(spans);
    try std.testing.expectEqual(@as(usize, 0), spans[0].start);
    try std.testing.expectEqual(@as(usize, 2), spans[0].end);
    try std.testing.expectEqual(@as(f32, 1.0), spans[0].weight(0));
    try std.testing.expectEqual(@as(f32, 0.5), spans[0].weight(1));
    try std.testing.expectEqual(@as(usize, 1), spans[1].start);
    try std.testing.expectEqual(@as(f32, 0.5), spans[1].weight(1));
    try std.testing.expectEqual(@as(f32, 1.0), spans[1].weight(2));
    try std.testing.expectEqual(@as(f32, 1.5), spans[1].total);

    // A large image takes the threaded path and stays exact on flat colour.
    const width = 1500;
    const height = 1000;
    const pixels = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(pixels);
    for (0..width * height) |index| @memcpy(pixels[index * 3 ..][0..3], &[_]u16{ 0x2020, 0x8080, 0xc0c0 });
    const fitted = fit(width, height, 1.5, .{ .size = sizeNamed("4x6").?, .dpi = 100 });
    try std.testing.expectEqual(@as(usize, 600), fitted.width);
    try std.testing.expectEqual(@as(usize, 400), fitted.height);
    const out = try downscaleToSrgb8(allocator, pixels, width, height, fitted.width, fitted.height);
    defer allocator.free(out);
    for (0..fitted.width * fitted.height) |index| try std.testing.expectEqualSlices(u8, &.{ 0x20, 0x80, 0xc0 }, out[index * 3 ..][0..3]);
}
