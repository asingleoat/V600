//! Newton's rings: interference fringes where the film touches the scanner
//! glass. The scanner's IR light is narrow-band, so the IR page shows fringes
//! wherever the film comes within tens of microns of the glass, even with the
//! matte emulsion side down. White light shows them only near true contact,
//! and a viewer sees them only where the picture is smooth. The check measures
//! how much of a frame shows rings a viewer would see:
//!
//! - The picture is regressed out of the IR (it leaks in through the dyes),
//!   which leaves fringes and dust.
//! - Candidate pixels lie in a broad IR fringe field, where the picture is
//!   smooth at fine scale and its band-passed density varies well above the
//!   frame's grain.
//! - They count only inside tiles where the red channel peaks at 1.3 to 1.95
//!   times the IR fringe frequency, along the IR fringes: the same gap seen at
//!   red's shorter wavelength. Picture detail sits at one frequency in every
//!   channel.
//!
//! Tuned on 136 real 35mm and 6x7 frames scanned at 6400 dpi; pixel
//! parameters are at the check's 533 dpi grid and scale with it.
const std = @import("std");
const parallelism = @import("parallelism.zig");

/// The grid the check runs on: 6400 dpi scans average 12 x 12 pixels.
const grid_dpi: f64 = 6400.0 / 12.0;
/// Frames with at least this much ring area get a warning: strong rings
/// only. Faint ones are hard to see and harder to measure.
pub const warning_mm2: f64 = 5.0;

pub fn View(comptime T: type) type {
    return struct {
        pixels: []const T,
        width: usize,
        height: usize,
        channels: usize,
    };
}

/// A frame in RGB pixel coordinates; the check covers its middle 90% each way.
pub const Frame = struct {
    cx: f64,
    cy: f64,
    w: f64,
    h: f64,
};

pub fn warns(area_mm2: f64) bool {
    return area_mm2 >= warning_mm2;
}

/// "Newton's rings in frame 3: consider rescanning it", or "frames 2 and 4",
/// "frames 1, 3, and 5"; frames are numbered from 1.
pub fn writeWarning(writer: *std.Io.Writer, frames: []const usize) std.Io.Writer.Error!void {
    try writer.writeAll(if (frames.len == 1) "Newton's rings in frame " else "Newton's rings in frames ");
    for (frames, 0..) |frame, index| {
        if (index > 0) try writer.writeAll(if (index + 1 < frames.len) ", " else if (frames.len == 2) " and " else ", and ");
        try writer.print("{d}", .{frame});
    }
    try writer.writeAll(if (frames.len == 1) ": consider rescanning it" else ": consider rescanning them");
}

pub fn warningText(allocator: std.mem.Allocator, frames: []const usize) ![]u8 {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeWarning(&writer, frames);
    return allocator.dupe(u8, writer.buffered());
}

/// Where a block of RGB rows sits in the whole scan, when only part of it is
/// loaded.
pub const Rows = struct {
    first: usize = 0,
    /// The whole RGB page's height; null when `rgb` is the whole page.
    page_height: ?usize = null,
};

/// The area, in mm² of film, showing visible Newton's rings. `frame` is in
/// whole-scan coordinates; `rgb` holds the page or the rows `rows` says. `ir`
/// is the whole IR page, at any resolution.
pub fn ringArea(
    comptime Rgb: type,
    comptime Ir: type,
    allocator: std.mem.Allocator,
    rgb: View(Rgb),
    rows: Rows,
    ir: View(Ir),
    frame: Frame,
    dpi: u32,
) !f64 {
    const factor: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(dpi)) / grid_dpi))));
    const grid_px_per_mm = @as(f64, @floatFromInt(dpi)) / @as(f64, @floatFromInt(factor)) / 25.4;
    const params = Params.init(grid_px_per_mm * 25.4 / grid_dpi);

    const first: f64 = @floatFromInt(rows.first);
    const x0 = clampToExtent(frame.cx - 0.45 * frame.w, rgb.width);
    const x1 = clampToExtent(frame.cx + 0.45 * frame.w, rgb.width);
    const y0 = clampToExtent(frame.cy - 0.45 * frame.h - first, rgb.height);
    const y1 = clampToExtent(frame.cy + 0.45 * frame.h - first, rgb.height);
    const width = (x1 -| x0) / factor;
    const height = (y1 -| y0) / factor;
    if (width < params.tile + 2 or height < params.tile + 2) return 0;

    var grid = try Grid.init(allocator, width, height);
    defer grid.deinit(allocator);
    sampleRgb(Rgb, rgb, x0, y0, factor, &grid);
    sampleIr(Ir, ir, rgb.width, rows.page_height orelse rgb.height, x0, rows.first + y0, factor, &grid);
    try regressOutPicture(&grid);

    const visible = try visibleRingPixels(allocator, &grid, params);
    defer allocator.free(visible);
    const matched = try redMatchedTiles(allocator, &grid, params);
    defer allocator.free(matched);

    var count: usize = 0;
    for (visible, matched) |v, m| count += @intFromBool(v and m);
    const mm_per_px = 1.0 / grid_px_per_mm;
    return @as(f64, @floatFromInt(count)) * mm_per_px * mm_per_px;
}

fn clampToExtent(value: f64, extent: usize) usize {
    return @intFromFloat(std.math.clamp(@floor(value), 0, @as(f64, @floatFromInt(extent))));
}

const Params = struct {
    scale: f64,
    tile: usize,
    min_field_px: usize,

    fn init(scale: f64) Params {
        return .{
            .scale = scale,
            .tile = @max(16, @as(usize, @intFromFloat(@round(96 * scale)))),
            .min_field_px = @intFromFloat(@round(2000 * scale * scale)),
        };
    }

    fn px(self: Params, at_grid: f64) f64 {
        return at_grid * self.scale;
    }
};

const Grid = struct {
    width: usize,
    height: usize,
    /// Densities (-log10 of the linear values) of R, G, and B, then the IR's.
    density: [3][]f32,
    ir: []f32,

    fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Grid {
        const n = width * height;
        var grid = Grid{ .width = width, .height = height, .density = undefined, .ir = &.{} };
        var made: usize = 0;
        errdefer for (grid.density[0..made]) |plane| allocator.free(plane);
        for (&grid.density) |*plane| {
            plane.* = try allocator.alloc(f32, n);
            made += 1;
        }
        grid.ir = try allocator.alloc(f32, n);
        return grid;
    }

    fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
        for (self.density) |plane| allocator.free(plane);
        allocator.free(self.ir);
    }

    fn len(self: Grid) usize {
        return self.width * self.height;
    }
};

fn density(value: f64) f32 {
    return @floatCast(-std.math.log10(@max(value, 1.0)));
}

fn sampleRgb(comptime T: type, rgb: View(T), x0: usize, y0: usize, factor: usize, grid: *Grid) void {
    const area: f64 = @floatFromInt(factor * factor);
    for (0..grid.height) |gy| {
        for (0..grid.width) |gx| {
            var sums = [3]f64{ 0, 0, 0 };
            for (0..factor) |dy| {
                const row = (y0 + gy * factor + dy) * rgb.width;
                for (0..factor) |dx| {
                    const base = (row + x0 + gx * factor + dx) * rgb.channels;
                    for (&sums, 0..) |*sum, ch| sum.* += toF64(T, rgb.pixels[base + ch]);
                }
            }
            for (sums, 0..) |sum, ch| grid.density[ch][gy * grid.width + gx] = density(sum / area);
        }
    }
}

fn sampleIr(comptime T: type, ir: View(T), rgb_width: usize, rgb_height: usize, x0: usize, y0: usize, factor: usize, grid: *Grid) void {
    const sx = @as(f64, @floatFromInt(ir.width)) / @as(f64, @floatFromInt(rgb_width));
    const sy = @as(f64, @floatFromInt(ir.height)) / @as(f64, @floatFromInt(rgb_height));
    for (0..grid.height) |gy| {
        const ya = irIndex(@floatFromInt(y0 + gy * factor), sy, ir.height);
        const yb = @max(ya + 1, irIndex(@floatFromInt(y0 + (gy + 1) * factor), sy, ir.height));
        for (0..grid.width) |gx| {
            const xa = irIndex(@floatFromInt(x0 + gx * factor), sx, ir.width);
            const xb = @max(xa + 1, irIndex(@floatFromInt(x0 + (gx + 1) * factor), sx, ir.width));
            var sum: f64 = 0;
            var count: usize = 0;
            for (ya..@min(yb, ir.height)) |y| {
                for (xa..@min(xb, ir.width)) |x| {
                    sum += toF64(T, ir.pixels[(y * ir.width + x) * ir.channels]);
                    count += 1;
                }
            }
            grid.ir[gy * grid.width + gx] = density(sum / @as(f64, @floatFromInt(@max(count, 1))));
        }
    }
}

fn irIndex(rgb_coord: f64, scale: f64, extent: usize) usize {
    return @min(extent - 1, @as(usize, @intFromFloat(@floor(rgb_coord * scale))));
}

fn toF64(comptime T: type, value: T) f64 {
    return switch (@typeInfo(T)) {
        .float => @floatCast(value),
        .int => @floatFromInt(value),
        else => @compileError("unsupported sample type"),
    };
}

/// Least squares of the IR density on the three dye densities and a constant,
/// leaving in `grid.ir` what the picture does not explain.
fn regressOutPicture(grid: *Grid) !void {
    var ata = [_][5]f64{[_]f64{0} ** 5} ** 4;
    for (0..grid.len()) |i| {
        const row = [4]f64{ grid.density[0][i], grid.density[1][i], grid.density[2][i], 1 };
        for (0..4) |a| {
            for (0..4) |b| ata[a][b] += row[a] * row[b];
            ata[a][4] += row[a] * grid.ir[i];
        }
    }
    const coef = solve4(ata) orelse return;
    for (0..grid.len()) |i| {
        const predicted = coef[0] * grid.density[0][i] + coef[1] * grid.density[1][i] + coef[2] * grid.density[2][i] + coef[3];
        grid.ir[i] = @floatCast(grid.ir[i] - predicted);
    }
}

fn solve4(augmented: [4][5]f64) ?[4]f64 {
    var m = augmented;
    for (0..4) |col| {
        var pivot = col;
        for (col + 1..4) |row| {
            if (@abs(m[row][col]) > @abs(m[pivot][col])) pivot = row;
        }
        if (@abs(m[pivot][col]) < 1e-12) return null;
        std.mem.swap([5]f64, &m[col], &m[pivot]);
        for (0..4) |row| {
            if (row == col) continue;
            const f = m[row][col] / m[col][col];
            for (col..5) |k| m[row][k] -= f * m[col][k];
        }
    }
    return .{ m[0][4] / m[0][0], m[1][4] / m[1][1], m[2][4] / m[2][2], m[3][4] / m[3][3] };
}

/// Smooth pixels inside broad IR fringe fields whose band-passed density
/// varies well above the frame's grain.
fn visibleRingPixels(allocator: std.mem.Allocator, grid: *const Grid, params: Params) ![]bool {
    const n = grid.len();
    var scratch = try Scratch.init(allocator, grid.width, grid.height);
    defer scratch.deinit(allocator);

    // IR fringe fields: local amplitude of the band-passed IR leftover.
    const fringe = try allocator.alloc(bool, n);
    defer allocator.free(fringe);
    {
        const b = try scratch.bandPass(allocator, grid.ir, params.px(3), params.px(16));
        defer allocator.free(b);
        const amp = try scratch.localAmplitude(allocator, &.{b}, params.px(8));
        defer allocator.free(amp);
        for (amp, fringe) |a, *f| f.* = a > 0.004;
    }
    try keepLargeComponents(allocator, fringe, grid.width, grid.height, params.min_field_px);

    // Fine-scale texture: where the picture itself has detail.
    const texture = try allocator.alloc(f32, n);
    defer allocator.free(texture);
    @memset(texture, 0);
    for (grid.density) |plane| {
        const b = try scratch.bandPass(allocator, plane, params.px(0.7), params.px(2.5));
        defer allocator.free(b);
        const amp = try scratch.localAmplitude(allocator, &.{b}, params.px(8));
        defer allocator.free(amp);
        for (texture, amp) |*t, a| t.* = @max(t.*, a);
    }
    const smooth = try allocator.alloc(bool, n);
    defer allocator.free(smooth);
    const texture_floor = try percentile(allocator, texture, null, 0.10, 1) orelse return error.EmptyGrid;
    for (texture, smooth) |t, *s| s.* = t < 1.6 * texture_floor;

    // Ring-scale variation of all three dye densities.
    var bands: [3][]f32 = undefined;
    var made: usize = 0;
    defer for (bands[0..made]) |b| allocator.free(b);
    for (grid.density, 0..) |plane, ch| {
        bands[ch] = try scratch.bandPass(allocator, plane, params.px(3), params.px(16));
        made += 1;
    }
    const variation = try scratch.localAmplitude(allocator, &bands, params.px(8));
    defer allocator.free(variation);

    // The frame's grain level: smooth pixels away from fringes, else any.
    const quiet = try allocator.alloc(bool, n);
    defer allocator.free(quiet);
    for (smooth, fringe, quiet) |s, f, *q| q.* = s and !f;
    const base = try percentile(allocator, variation, quiet, 0.5, 501) orelse
        try percentile(allocator, variation, smooth, 0.5, 501) orelse
        try percentile(allocator, variation, null, 0.5, 1) orelse return error.EmptyGrid;

    const visible = try allocator.alloc(bool, n);
    for (visible, smooth, fringe, variation) |*v, s, f, c| v.* = s and f and c > 2.0 * base;
    return visible;
}

/// Gaussian filtering on one grid size, with a reusable buffer.
const Scratch = struct {
    width: usize,
    height: usize,
    tmp: []f32,

    fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Scratch {
        return .{ .width = width, .height = height, .tmp = try allocator.alloc(f32, width * height) };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        allocator.free(self.tmp);
    }

    fn blur(self: *Scratch, allocator: std.mem.Allocator, src: []const f32, sigma: f64, dst: []f32) !void {
        try gaussianBlur(allocator, src, self.width, self.height, sigma, self.tmp, dst);
    }

    /// G(sigma_lo) - G(sigma_hi): a caller-owned band-pass of `src`.
    fn bandPass(self: *Scratch, allocator: std.mem.Allocator, src: []const f32, lo: f64, hi: f64) ![]f32 {
        const out = try allocator.alloc(f32, src.len);
        errdefer allocator.free(out);
        const wide = try allocator.alloc(f32, src.len);
        defer allocator.free(wide);
        try self.blur(allocator, src, lo, out);
        try self.blur(allocator, src, hi, wide);
        for (out, wide) |*o, w| o.* -= w;
        return out;
    }

    /// sqrt(G(sum of squares, sigma)): a caller-owned local amplitude.
    fn localAmplitude(self: *Scratch, allocator: std.mem.Allocator, signals: []const []const f32, sigma: f64) ![]f32 {
        const sq = try allocator.alloc(f32, signals[0].len);
        defer allocator.free(sq);
        @memset(sq, 0);
        for (signals) |signal| {
            for (sq, signal) |*q, v| q.* += v * v;
        }
        const out = try allocator.alloc(f32, sq.len);
        errdefer allocator.free(out);
        try self.blur(allocator, sq, sigma, out);
        for (out) |*o| o.* = @sqrt(@max(o.*, 0));
        return out;
    }
};

/// Separable Gaussian with mirrored edges (the edge pixel repeated), kernel
/// radius 4 sigma.
fn gaussianBlur(allocator: std.mem.Allocator, src: []const f32, width: usize, height: usize, sigma: f64, tmp: []f32, dst: []f32) !void {
    const radius: usize = @intFromFloat(4.0 * sigma + 0.5);
    if (radius == 0) {
        @memcpy(dst, src);
        return;
    }
    const kernel = try allocator.alloc(f32, 2 * radius + 1);
    defer allocator.free(kernel);
    var sum: f64 = 0;
    for (kernel, 0..) |*k, i| {
        const x = @as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(radius));
        const v = @exp(-0.5 * x * x / (sigma * sigma));
        k.* = @floatCast(v);
        sum += v;
    }
    for (kernel) |*k| k.* = @floatCast(@as(f64, k.*) / sum);

    const Pass = struct {
        src: []const f32,
        dst: []f32,
        width: usize,
        height: usize,
        kernel: []const f32,
        radius: usize,
        horizontal: bool,

        fn rows(p: @This(), row_start: usize, row_end: usize) void {
            const r: isize = @intCast(p.radius);
            for (row_start..row_end) |y| {
                for (0..p.width) |x| {
                    var acc: f32 = 0;
                    for (p.kernel, 0..) |k, i| {
                        const offset = @as(isize, @intCast(i)) - r;
                        const v = if (p.horizontal)
                            p.src[y * p.width + mirror(@as(isize, @intCast(x)) + offset, p.width)]
                        else
                            p.src[mirror(@as(isize, @intCast(y)) + offset, p.height) * p.width + x];
                        acc += k * v;
                    }
                    p.dst[y * p.width + x] = acc;
                }
            }
        }
    };
    try parallelism.forRowBands(allocator, height, Pass{ .src = src, .dst = tmp, .width = width, .height = height, .kernel = kernel, .radius = radius, .horizontal = true }, Pass.rows);
    try parallelism.forRowBands(allocator, height, Pass{ .src = tmp, .dst = dst, .width = width, .height = height, .kernel = kernel, .radius = radius, .horizontal = false }, Pass.rows);
}

fn mirror(index: isize, extent: usize) usize {
    const n: isize = @intCast(extent);
    var i = index;
    while (i < 0 or i >= n) {
        i = if (i < 0) -i - 1 else 2 * n - i - 1;
    }
    return @intCast(i);
}

/// The q-quantile (linear between ranks) of `values` where `mask` is set, or
/// null when fewer than `min_count` qualify.
fn percentile(allocator: std.mem.Allocator, values: []const f32, mask: ?[]const bool, q: f64, min_count: usize) !?f32 {
    var count: usize = 0;
    for (values, 0..) |_, i| {
        if (mask == null or mask.?[i]) count += 1;
    }
    if (count < min_count or count == 0) return null;
    const picked = try allocator.alloc(f32, count);
    defer allocator.free(picked);
    var n: usize = 0;
    for (values, 0..) |v, i| {
        if (mask == null or mask.?[i]) {
            picked[n] = v;
            n += 1;
        }
    }
    std.mem.sort(f32, picked, {}, std.sort.asc(f32));
    const rank = q * @as(f64, @floatFromInt(count - 1));
    const lo: usize = @intFromFloat(@floor(rank));
    const hi = @min(lo + 1, count - 1);
    const t: f32 = @floatCast(rank - @floor(rank));
    return picked[lo] + (picked[hi] - picked[lo]) * t;
}

/// Clears 4-connected components of `mask` smaller than `min_size`.
fn keepLargeComponents(allocator: std.mem.Allocator, mask: []bool, width: usize, height: usize, min_size: usize) !void {
    const seen = try allocator.alloc(bool, mask.len);
    defer allocator.free(seen);
    @memset(seen, false);
    var stack = std.array_list.Managed(usize).init(allocator);
    defer stack.deinit();
    var members = std.array_list.Managed(usize).init(allocator);
    defer members.deinit();
    for (0..mask.len) |start| {
        if (!mask[start] or seen[start]) continue;
        stack.clearRetainingCapacity();
        members.clearRetainingCapacity();
        try stack.append(start);
        seen[start] = true;
        while (stack.pop()) |i| {
            try members.append(i);
            const x = i % width;
            const y = i / width;
            const neighbours = [4]?usize{
                if (x > 0) i - 1 else null,
                if (x + 1 < width) i + 1 else null,
                if (y > 0) i - width else null,
                if (y + 1 < height) i + width else null,
            };
            for (neighbours) |neighbour| {
                const j = neighbour orelse continue;
                if (mask[j] and !seen[j]) {
                    seen[j] = true;
                    try stack.append(j);
                }
            }
        }
        if (members.items.len < min_size) {
            for (members.items) |i| mask[i] = false;
        }
    }
}

/// Pixels of tiles where the red channel peaks at 1.3-1.95x the IR fringe
/// frequency, along the fringes, far above its power the other ways round.
fn redMatchedTiles(allocator: std.mem.Allocator, grid: *const Grid, params: Params) ![]bool {
    var scratch = try Scratch.init(allocator, grid.width, grid.height);
    defer scratch.deinit(allocator);
    const ir = try scratch.bandPass(allocator, grid.ir, params.px(1), params.px(30));
    defer allocator.free(ir);
    const red = try scratch.bandPass(allocator, grid.density[0], params.px(1), params.px(30));
    defer allocator.free(red);

    const matched = try allocator.alloc(bool, grid.len());
    errdefer allocator.free(matched);
    @memset(matched, false);

    var tiles = try TileSpectra.init(allocator, params.tile);
    defer tiles.deinit(allocator);
    const t = params.tile;
    const step = t / 2;
    // Fringe periods 0.4 to 4 mm.
    const min_freq = 1.0 / params.px(84);
    const max_freq = 1.0 / params.px(8.4);
    var y: usize = 0;
    while (y + t <= grid.height) : (y += step) {
        var x: usize = 0;
        while (x + t <= grid.width) : (x += step) {
            if (try tiles.matchedZ(ir, red, grid.width, x, y, min_freq, max_freq) > 60) {
                for (y..y + t) |yy| @memset(matched[yy * grid.width + x ..][0..t], true);
            }
        }
    }
    return matched;
}

const TileSpectra = struct {
    size: usize,
    window: []f64,
    window_sum: f64,
    cos_table: []f64,
    sin_table: []f64,
    ir_tile: []f64,
    red_tile: []f64,
    re: []f64,
    im: []f64,
    row_re: []f64,
    row_im: []f64,

    fn init(allocator: std.mem.Allocator, size: usize) !TileSpectra {
        const n = size * size;
        var self: TileSpectra = undefined;
        self.size = size;
        self.window = try allocator.alloc(f64, n);
        errdefer allocator.free(self.window);
        self.cos_table = try allocator.alloc(f64, size);
        errdefer allocator.free(self.cos_table);
        self.sin_table = try allocator.alloc(f64, size);
        errdefer allocator.free(self.sin_table);
        self.ir_tile = try allocator.alloc(f64, n);
        errdefer allocator.free(self.ir_tile);
        self.red_tile = try allocator.alloc(f64, n);
        errdefer allocator.free(self.red_tile);
        self.re = try allocator.alloc(f64, n);
        errdefer allocator.free(self.re);
        self.im = try allocator.alloc(f64, n);
        errdefer allocator.free(self.im);
        self.row_re = try allocator.alloc(f64, n);
        errdefer allocator.free(self.row_re);
        self.row_im = try allocator.alloc(f64, n);
        const sizef: f64 = @floatFromInt(size);
        var hann: [512]f64 = undefined;
        for (0..size) |i| {
            hann[i] = 0.5 - 0.5 * @cos(2 * std.math.pi * @as(f64, @floatFromInt(i)) / (sizef - 1));
            const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / sizef;
            self.cos_table[i] = @cos(angle);
            self.sin_table[i] = @sin(angle);
        }
        self.window_sum = 0;
        for (0..size) |r| {
            for (0..size) |c| {
                self.window[r * size + c] = hann[r] * hann[c];
                self.window_sum += hann[r] * hann[c];
            }
        }
        return self;
    }

    fn deinit(self: *TileSpectra, allocator: std.mem.Allocator) void {
        for ([_][]f64{ self.window, self.cos_table, self.sin_table, self.ir_tile, self.red_tile, self.re, self.im, self.row_re, self.row_im }) |buffer| allocator.free(buffer);
    }

    /// Mean-removed, windowed copy of the tile at (x, y).
    fn load(self: *TileSpectra, src: []const f32, width: usize, x: usize, y: usize, dst: []f64) void {
        const n = self.size;
        var mean: f64 = 0;
        for (0..n) |r| {
            for (0..n) |c| mean += src[(y + r) * width + x + c];
        }
        mean /= @floatFromInt(n * n);
        for (0..n) |r| {
            for (0..n) |c| dst[r * n + c] = (src[(y + r) * width + x + c] - mean) * self.window[r * n + c];
        }
    }

    /// Full 2-D DFT power of `tile` into `self.re` (power), by rows then columns.
    fn powerSpectrum(self: *TileSpectra, tile: []const f64) void {
        const n = self.size;
        for (0..n) |r| {
            for (0..n) |k| {
                var sr: f64 = 0;
                var si: f64 = 0;
                for (0..n) |c| {
                    const idx = (k * c) % n;
                    sr += tile[r * n + c] * self.cos_table[idx];
                    si -= tile[r * n + c] * self.sin_table[idx];
                }
                self.row_re[r * n + k] = sr;
                self.row_im[r * n + k] = si;
            }
        }
        for (0..n) |k| {
            for (0..n) |ky| {
                var sr: f64 = 0;
                var si: f64 = 0;
                for (0..n) |r| {
                    const idx = (ky * r) % n;
                    const cr = self.cos_table[idx];
                    const ci = -self.sin_table[idx];
                    const ar = self.row_re[r * n + k];
                    const ai = self.row_im[r * n + k];
                    sr += ar * cr - ai * ci;
                    si += ar * ci + ai * cr;
                }
                self.re[ky * n + k] = sr * sr + si * si;
            }
        }
    }

    /// DFT power of `tile` at an arbitrary frequency (cycles per pixel).
    fn powerAt(self: *TileSpectra, tile: []const f64, fy: f64, fx: f64) f64 {
        const n = self.size;
        var sr: f64 = 0;
        var si: f64 = 0;
        for (0..n) |r| {
            var rr: f64 = 0;
            var ri: f64 = 0;
            for (0..n) |c| {
                const a = -2 * std.math.pi * fx * @as(f64, @floatFromInt(c));
                rr += tile[r * n + c] * @cos(a);
                ri += tile[r * n + c] * @sin(a);
            }
            const b = -2 * std.math.pi * fy * @as(f64, @floatFromInt(r));
            const cb = @cos(b);
            const sb = @sin(b);
            sr += rr * cb - ri * sb;
            si += rr * sb + ri * cb;
        }
        return sr * sr + si * si;
    }

    fn freq(self: TileSpectra, bin: usize) f64 {
        const n: isize = @intCast(self.size);
        const b: isize = @intCast(bin);
        const signed = if (b < @divTrunc(n + 1, 2)) b else b - n;
        return @as(f64, @floatFromInt(signed)) / @as(f64, @floatFromInt(n));
    }

    /// How far the red channel's power at its IR-predicted frequency stands
    /// above its power there in other directions, or 0 without clean IR
    /// fringes in the tile.
    fn matchedZ(self: *TileSpectra, ir: []const f32, red: []const f32, width: usize, x: usize, y: usize, min_freq: f64, max_freq: f64) !f64 {
        const n = self.size;
        self.load(ir, width, x, y, self.ir_tile);
        self.powerSpectrum(self.ir_tile);
        var total: f64 = 0;
        var best: f64 = -1;
        var best_r: usize = 0;
        var best_c: usize = 0;
        for (0..n) |r| {
            for (0..n) |c| {
                const radius = std.math.hypot(self.freq(r), self.freq(c));
                if (radius < min_freq or radius > max_freq) continue;
                const p = self.re[r * n + c];
                total += p;
                if (p > best) {
                    best = p;
                    best_r = r;
                    best_c = c;
                }
            }
        }
        if (best <= 0 or total <= 0) return 0;
        var peak: f64 = 0;
        for ([_]usize{ n - 1, 0, 1 }) |dr| {
            for ([_]usize{ n - 1, 0, 1 }) |dc| {
                const r = (best_r + dr) % n;
                const c = (best_c + dc) % n;
                const radius = std.math.hypot(self.freq(r), self.freq(c));
                if (radius >= min_freq and radius <= max_freq) peak += self.re[r * n + c];
            }
        }
        const share = 2 * peak / total;
        const ir_amp = 2 * @sqrt(best) / self.window_sum;
        if (share < 0.25 or ir_amp < 0.002) return 0;
        const ky = self.freq(best_r);
        const kx = self.freq(best_c);
        // A sinusoidal fringe has little power at twice its frequency; an edge does.
        if (std.math.hypot(2 * ky, 2 * kx) <= 0.5 and self.powerAt(self.ir_tile, 2 * ky, 2 * kx) > 0.15 * best) return 0;

        self.load(red, width, x, y, self.red_tile);
        var best_z: f64 = 0;
        for (0..14) |i| {
            const rho = 1.30 + 0.05 * @as(f64, @floatFromInt(i));
            const fy = rho * ky;
            const fx = rho * kx;
            const radius = std.math.hypot(fy, fx);
            if (radius > 0.25) continue;
            const matched = self.powerAt(self.red_tile, fy, fx);
            const angle = std.math.atan2(fy, fx);
            var others: [10]f64 = undefined;
            for (&others, 0..) |*o, j| {
                const a = angle + 0.4 + (std.math.pi - 0.8) * @as(f64, @floatFromInt(j)) / 9.0;
                o.* = self.powerAt(self.red_tile, radius * @sin(a), radius * @cos(a));
            }
            std.mem.sort(f64, &others, {}, std.sort.asc(f64));
            const reference = 0.5 * (others[4] + others[5]);
            if (reference > 0) best_z = @max(best_z, matched / reference);
        }
        return best_z;
    }
};

test "warnings name the frames" {
    const allocator = std.testing.allocator;
    for ([_]struct { frames: []const usize, text: []const u8 }{
        .{ .frames = &.{3}, .text = "Newton's rings in frame 3: consider rescanning it" },
        .{ .frames = &.{ 2, 4 }, .text = "Newton's rings in frames 2 and 4: consider rescanning them" },
        .{ .frames = &.{ 1, 3, 5 }, .text = "Newton's rings in frames 1, 3, and 5: consider rescanning them" },
    }) |case| {
        const text = try warningText(allocator, case.frames);
        defer allocator.free(text);
        try std.testing.expectEqualStrings(case.text, text);
    }
}

test "gaussian blur keeps a flat field and spreads an impulse symmetrically" {
    const allocator = std.testing.allocator;
    const w = 21;
    const h = 15;
    var src = [_]f32{0} ** (w * h);
    var tmp = [_]f32{0} ** (w * h);
    var dst = [_]f32{0} ** (w * h);
    src[7 * w + 10] = 1;
    try gaussianBlur(allocator, &src, w, h, 1.5, &tmp, &dst);
    var total: f32 = 0;
    for (dst) |v| total += v;
    try std.testing.expectApproxEqAbs(@as(f32, 1), total, 1e-4);
    try std.testing.expectApproxEqAbs(dst[7 * w + 8], dst[7 * w + 12], 1e-6);
    try std.testing.expectApproxEqAbs(dst[5 * w + 10], dst[9 * w + 10], 1e-6);
    @memset(&src, 3);
    try gaussianBlur(allocator, &src, w, h, 4, &tmp, &dst);
    for (dst) |v| try std.testing.expectApproxEqAbs(@as(f32, 3), v, 1e-4);
}

test "the tile spectrum finds a fringe's frequency and power at any frequency agrees with it" {
    const allocator = std.testing.allocator;
    var tiles = try TileSpectra.init(allocator, 32);
    defer tiles.deinit(allocator);
    var plane = [_]f32{0} ** (32 * 32);
    for (0..32) |r| {
        for (0..32) |c| plane[r * 32 + c] = @floatCast(@cos(2 * std.math.pi * (3.0 * @as(f64, @floatFromInt(r)) + 5.0 * @as(f64, @floatFromInt(c))) / 32.0));
    }
    tiles.load(&plane, 32, 0, 0, tiles.ir_tile);
    tiles.powerSpectrum(tiles.ir_tile);
    var best: f64 = 0;
    var at: usize = 0;
    for (tiles.re, 0..) |p, i| {
        if (p > best) {
            best = p;
            at = i;
        }
    }
    const r = at / 32;
    const c = at % 32;
    try std.testing.expect((r == 3 and c == 5) or (r == 29 and c == 27));
    try std.testing.expectApproxEqRel(best, tiles.powerAt(tiles.ir_tile, tiles.freq(r), tiles.freq(c)), 1e-9);
}

test "small components go and large ones stay" {
    const allocator = std.testing.allocator;
    var mask = [_]bool{false} ** (6 * 4);
    for ([_]usize{ 0, 1, 6, 7, 12 }) |i| mask[i] = true; // 5 pixels
    mask[4] = true; // 1 pixel
    try keepLargeComponents(allocator, &mask, 6, 4, 3);
    try std.testing.expect(mask[0] and mask[12]);
    try std.testing.expect(!mask[4]);
}

/// A synthetic frame at the check's grid scale: smooth sky, film grain, and,
/// when `rings`, Newton's rings about a contact point in red as well as IR.
fn syntheticFrame(allocator: std.mem.Allocator, rings: bool) ![]u16 {
    const w = 480;
    const h = 480;
    const pixels = try allocator.alloc(u16, w * h * 4);
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (0..h) |y| {
        for (0..w) |x| {
            const dx = @as(f64, @floatFromInt(x)) - 240;
            const dy = @as(f64, @floatFromInt(y)) - 240;
            // Gap in micrometres: film bowed with a 20 m radius, touching the
            // glass at the centre, at 21 px per mm. The white light's fringes
            // fade sooner than the narrow-band IR's.
            const r_mm = @sqrt(dx * dx + dy * dy) / 21.0;
            const gap_um = r_mm * r_mm / 40.0;
            const ir_mod = 0.04 * @exp(-(r_mm * r_mm) / 64.0) * @cos(4 * std.math.pi * gap_um / 0.94);
            const red_mod = if (rings) 0.03 * @exp(-(r_mm * r_mm) / 16.0) * @cos(4 * std.math.pi * gap_um / 0.61) else 0;
            const grain = 0.004 * (random.float(f64) - 0.5);
            const base = (y * w + x) * 4;
            pixels[base] = @intFromFloat(30000 * @exp(red_mod + grain));
            pixels[base + 1] = @intFromFloat(28000 * @exp(grain));
            pixels[base + 2] = @intFromFloat(26000 * @exp(grain));
            pixels[base + 3] = @intFromFloat(@min(65535, 40000 * @exp(ir_mod + grain)));
        }
    }
    return pixels;
}

test "rings in red and IR about a contact point read as visible rings; IR alone does not" {
    const allocator = std.testing.allocator;
    for ([_]bool{ true, false }) |rings| {
        const all = try syntheticFrame(allocator, rings);
        defer allocator.free(all);
        const rgb = try allocator.alloc(u16, 480 * 480 * 3);
        defer allocator.free(rgb);
        const ir = try allocator.alloc(u16, 480 * 480);
        defer allocator.free(ir);
        for (0..480 * 480) |i| {
            @memcpy(rgb[i * 3 ..][0..3], all[i * 4 ..][0..3]);
            ir[i] = all[i * 4 + 3];
        }
        const area = try ringArea(u16, u16, allocator, .{ .pixels = rgb, .width = 480, .height = 480, .channels = 3 }, .{}, .{ .pixels = ir, .width = 480, .height = 480, .channels = 1 }, .{ .cx = 240, .cy = 240, .w = 480, .h = 480 }, 533);
        if (rings) try std.testing.expect(warns(area)) else try std.testing.expect(!warns(area));
    }
}
