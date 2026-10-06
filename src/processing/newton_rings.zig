//! Newton's rings: interference fringes where the film comes within a few
//! microns of the scanner glass, around a speck of dust that holds it off or
//! where it bows onto the glass. The scanner's IR light is narrow-band, so the
//! IR page shows fringes wherever the film is within tens of microns of the
//! glass, even with the matte emulsion side down, and most frames have some.
//! White light shows them only where the gap is smallest, as coloured rings:
//! the same gap seen at the dyes' shorter wavelengths, so red-minus-green
//! density runs through 1.3 to 1.8 cycles for each IR fringe. Picture content
//! does not follow the IR fringes at a fixed ratio. The check:
//!
//! - regresses the picture out of the IR (it leaks in through the dyes),
//!   which leaves fringes and dust;
//! - finds the centres of IR ring systems by radial symmetry;
//! - along rays from each centre, takes the IR fringe phase and fits
//!   red-minus-green density as a sinusoid of a multiple of it;
//! - scores a centre by how much more of that density's variance the fit
//!   explains at its best ratio from 1.3 to 1.8 than 0.3 either side, and a
//!   frame by its best centre.
//!
//! Tuned on 136 real 35mm and 6x7 frames scanned at 6400 dpi; pixel
//! parameters are at the check's 1067 dpi grid and scale with it.
const std = @import("std");
const parallelism = @import("parallelism.zig");

/// The grid the check runs on: 6400 dpi scans average 6 x 6 pixels.
const grid_dpi: f64 = 6400.0 / 6.0;
/// Frames scoring at least this get a warning: strong rings only. Faint ones
/// are hard to see and harder to measure.
pub const warning_score: f64 = 0.06;

pub fn View(comptime T: type) type {
    return struct {
        pixels: []const T,
        width: usize,
        height: usize,
        channels: usize,
    };
}

/// A frame in RGB pixel coordinates; the check covers all of it.
pub const Frame = struct {
    cx: f64,
    cy: f64,
    w: f64,
    h: f64,
};

pub fn warns(score: f64) bool {
    return score >= warning_score;
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

/// How strongly a frame shows visible Newton's rings: the share of the
/// variance of red-minus-green density about its strongest IR ring centre
/// that the IR fringes explain at the dyes' wavelengths, above their share
/// at other ratios. 0.1 and up where rings are plain to see, under 0.03
/// without them. `frame` is in whole-scan coordinates; `rgb` holds the page
/// or the rows `rows` says. `ir` is the whole IR page, at any resolution.
pub fn ringScore(
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
    const params = Params.init(@as(f64, @floatFromInt(dpi)) / @as(f64, @floatFromInt(factor)) / grid_dpi);

    const first: f64 = @floatFromInt(rows.first);
    const x0 = clampToExtent(frame.cx - 0.5 * frame.w, rgb.width);
    const x1 = clampToExtent(frame.cx + 0.5 * frame.w, rgb.width);
    const y0 = clampToExtent(frame.cy - 0.5 * frame.h - first, rgb.height);
    const y1 = clampToExtent(frame.cy + 0.5 * frame.h - first, rgb.height);
    const width = (x1 -| x0) / factor;
    const height = (y1 -| y0) / factor;
    if (width < 2 * params.window or height < 2 * params.window) return 0;

    var bands = bands: {
        var grid = try Grid.init(allocator, width, height);
        defer grid.deinit(allocator);
        try sampleRgb(Rgb, allocator, rgb, x0, y0, factor, &grid);
        sampleIr(Ir, ir, rgb.width, rows.page_height orelse rgb.height, x0, rows.first + y0, factor, &grid);
        try regressOutPicture(&grid);
        break :bands try Bands.init(allocator, &grid, params);
    };
    defer bands.deinit(allocator);

    const centres = try ringCentres(allocator, bands.centres, width, height, params);
    defer allocator.free(centres);

    var fitter = try RayFitter.init(allocator, params.ray_length);
    defer fitter.deinit(allocator);
    var best: f64 = 0;
    for (centres) |centre| {
        const score = fitter.score(bands.ir, bands.colour, width, height, centre, params) orelse continue;
        best = @max(best, score);
    }
    return best;
}

fn clampToExtent(value: f64, extent: usize) usize {
    return @intFromFloat(std.math.clamp(@floor(value), 0, @as(f64, @floatFromInt(extent))));
}

/// Pixel sizes on the check's grid, from the sizes at 1067 dpi.
const Params = struct {
    /// Gaussian sigmas: the fine detail the fringes are kept to, the picture
    /// shading taken out, and the smoothing of the IR its ring centres are
    /// found on.
    fine: f64,
    broad: f64,
    centre_fine: f64,
    /// Ring radii the symmetry votes look for, 0.5 to 4.5 mm.
    radii: [7]usize,
    /// Centres are the strongest symmetry in this square, 2 mm across.
    peak_window: usize,
    /// Rays reach about 6 mm; a power of two for the FFT.
    ray_length: usize,
    /// Fits run over windows of this many samples, half-overlapping, from
    /// `ray_start` out.
    window: usize,
    ray_start: usize,

    fn init(scale: f64) Params {
        var radii: [7]usize = undefined;
        for (&radii, [_]f64{ 20, 30, 44, 64, 92, 132, 190 }) |*radius, at_grid| radius.* = @max(2, px(at_grid, scale));
        return .{
            .fine = scale,
            .broad = 60 * scale,
            .centre_fine = 3 * scale,
            .radii = radii,
            .peak_window = px(83, scale) | 1,
            // The power of two nearest 256 px.
            .ray_length = std.math.ceilPowerOfTwoAssert(usize, @max(64, px(256.0 / std.math.sqrt2, scale))),
            .window = @max(16, px(80, scale)),
            .ray_start = px(12, scale),
        };
    }

    fn px(at_grid: f64, scale: f64) usize {
        return @intFromFloat(@round(at_grid * scale));
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

fn sampleRgb(comptime T: type, allocator: std.mem.Allocator, rgb: View(T), x0: usize, y0: usize, factor: usize, grid: *Grid) !void {
    const Pass = struct {
        rgb: View(T),
        x0: usize,
        y0: usize,
        factor: usize,
        grid: *Grid,

        fn rows(p: @This(), row_start: usize, row_end: usize) void {
            const area: f64 = @floatFromInt(p.factor * p.factor);
            for (row_start..row_end) |gy| {
                for (0..p.grid.width) |gx| {
                    var sums = [3]f64{ 0, 0, 0 };
                    for (0..p.factor) |dy| {
                        const row = (p.y0 + gy * p.factor + dy) * p.rgb.width;
                        for (0..p.factor) |dx| {
                            const base = (row + p.x0 + gx * p.factor + dx) * p.rgb.channels;
                            for (&sums, 0..) |*sum, ch| sum.* += toF64(T, p.rgb.pixels[base + ch]);
                        }
                    }
                    for (sums, 0..) |sum, ch| p.grid.density[ch][gy * p.grid.width + gx] = density(sum / area);
                }
            }
        }
    };
    try parallelism.forRowBands(allocator, grid.height, Pass{ .rgb = rgb, .x0 = x0, .y0 = y0, .factor = factor, .grid = grid }, Pass.rows);
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

/// The band-passed planes the check reads, each with the picture's shading
/// taken out: the IR leftover and red-minus-green density at fine detail,
/// and the IR smoothed for finding ring centres.
const Bands = struct {
    ir: []f32,
    colour: []f32,
    centres: []f32,

    fn init(allocator: std.mem.Allocator, grid: *Grid, params: Params) !Bands {
        const w = grid.width;
        const h = grid.height;
        for (grid.density[0], grid.density[1]) |*r, g| r.* -= g;
        // The blue and green planes are free from here on: scratch.
        const tmp = grid.density[1];
        const broad = grid.density[2];
        var self: Bands = .{ .ir = &.{}, .colour = &.{}, .centres = &.{} };
        errdefer self.deinit(allocator);

        try blur(allocator, grid.ir, w, h, params.broad, tmp, broad);
        self.ir = try allocator.alloc(f32, grid.len());
        try blur(allocator, grid.ir, w, h, params.fine, tmp, self.ir);
        self.centres = try allocator.alloc(f32, grid.len());
        try blur(allocator, grid.ir, w, h, params.centre_fine, tmp, self.centres);
        for (self.ir, self.centres, broad) |*fine, *centre, b| {
            fine.* -= b;
            centre.* -= b;
        }

        try blur(allocator, grid.density[0], w, h, params.broad, tmp, broad);
        self.colour = try allocator.alloc(f32, grid.len());
        try blur(allocator, grid.density[0], w, h, params.fine, tmp, self.colour);
        for (self.colour, broad) |*fine, b| fine.* -= b;
        return self;
    }

    fn deinit(self: *Bands, allocator: std.mem.Allocator) void {
        allocator.free(self.ir);
        allocator.free(self.colour);
        allocator.free(self.centres);
    }
};

/// Gaussian blur with mirrored edges (the edge pixel repeated): exact for
/// small sigmas, three box passes of the same variance for wide ones.
fn blur(allocator: std.mem.Allocator, src: []const f32, width: usize, height: usize, sigma: f64, tmp: []f32, dst: []f32) !void {
    if (sigma <= 4) return gaussianBlur(allocator, src, width, height, sigma, tmp, dst);
    const radii = boxRadii(sigma);
    try boxPass(allocator, src, tmp, width, height, radii[0], .horizontal);
    try boxPass(allocator, tmp, dst, width, height, radii[1], .horizontal);
    try boxPass(allocator, dst, tmp, width, height, radii[2], .horizontal);
    try boxPass(allocator, tmp, dst, width, height, radii[0], .vertical);
    try boxPass(allocator, dst, tmp, width, height, radii[1], .vertical);
    try boxPass(allocator, tmp, dst, width, height, radii[2], .vertical);
}

/// Radii of three boxes whose variances sum closest to sigma squared: a box
/// of width 2r + 1 has variance r (r + 1) / 3, so the radii differ by at
/// most one.
fn boxRadii(sigma: f64) [3]usize {
    const variance = struct {
        fn of(r: usize) f64 {
            const rf: f64 = @floatFromInt(r);
            return rf * (rf + 1) / 3;
        }
    }.of;
    const r: usize = @intFromFloat(@floor(0.5 * (@sqrt(4 * sigma * sigma + 1) - 1)));
    const smaller = std.math.clamp(@round((3 * variance(r + 1) - sigma * sigma) / (variance(r + 1) - variance(r))), 0, 3);
    var radii = [3]usize{ r + 1, r + 1, r + 1 };
    for (radii[0..@intFromFloat(smaller)]) |*radius| radius.* = r;
    return radii;
}

/// One running-sum box filter of width 2 * radius + 1 along rows or columns.
fn boxPass(allocator: std.mem.Allocator, src: []const f32, dst: []f32, width: usize, height: usize, radius: usize, comptime direction: enum { horizontal, vertical }) !void {
    const Pass = struct {
        src: []const f32,
        dst: []f32,
        width: usize,
        height: usize,
        radius: usize,
        sums: []f64,

        /// Rows `start..end` for a horizontal pass, columns for a vertical one.
        fn lines(p: @This(), start: usize, end: usize) void {
            const r: isize = @intCast(p.radius);
            const scale = 1.0 / @as(f64, @floatFromInt(2 * p.radius + 1));
            if (direction == .horizontal) {
                for (start..end) |y| {
                    const row = p.src[y * p.width ..][0..p.width];
                    var sum: f64 = 0;
                    var k: isize = -r;
                    while (k <= r) : (k += 1) sum += row[mirror(k, p.width)];
                    for (0..p.width) |x| {
                        p.dst[y * p.width + x] = @floatCast(sum * scale);
                        const xi: isize = @intCast(x);
                        sum += @as(f64, row[mirror(xi + r + 1, p.width)]) - row[mirror(xi - r, p.width)];
                    }
                }
            } else {
                // Down the image a row at a time, one running sum per column.
                const sums = p.sums[start..end];
                @memset(sums, 0);
                var k: isize = -r;
                while (k <= r) : (k += 1) {
                    const row = p.src[mirror(k, p.height) * p.width ..];
                    for (sums, start..) |*sum, x| sum.* += row[x];
                }
                for (0..p.height) |y| {
                    const yi: isize = @intCast(y);
                    const enter = p.src[mirror(yi + r + 1, p.height) * p.width ..];
                    const leave = p.src[mirror(yi - r, p.height) * p.width ..];
                    for (sums, start..) |*sum, x| {
                        p.dst[y * p.width + x] = @floatCast(sum.* * scale);
                        sum.* += @as(f64, enter[x]) - leave[x];
                    }
                }
            }
        }
    };
    const sums = try allocator.alloc(f64, if (direction == .vertical) width else 0);
    defer allocator.free(sums);
    const pass = Pass{ .src = src, .dst = dst, .width = width, .height = height, .radius = radius, .sums = sums };
    try parallelism.forRowBands(allocator, if (direction == .horizontal) height else width, pass, Pass.lines);
}

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

const Centre = struct {
    x: usize,
    y: usize,
    strength: f32,
};

/// At most this many ring centres are fitted, the strongest first.
const max_centres = 20;

/// The strongest ring centres in `src`: radial symmetry of its gradients,
/// at its local maxima.
fn ringCentres(allocator: std.mem.Allocator, src: []const f32, width: usize, height: usize, params: Params) ![]Centre {
    const n = width * height;
    const symmetry = try allocator.alloc(f32, n);
    defer allocator.free(symmetry);
    const votes = try allocator.alloc(f32, n);
    defer allocator.free(votes);
    const tmp = try allocator.alloc(f32, n);
    defer allocator.free(tmp);
    const blurred = try allocator.alloc(f32, n);
    defer allocator.free(blurred);

    // Gradients count when well above the frame's typical one.
    for (0..height) |y| {
        for (0..width) |x| votes[y * width + x] = @floatCast(sobel(src, width, height, x, y).magnitude);
    }
    const threshold = 3 * median(votes);
    var voters = std.array_list.Managed(Voter).init(allocator);
    defer voters.deinit();
    for (0..height) |y| {
        for (0..width) |x| {
            const g = sobel(src, width, height, x, y);
            if (!(g.magnitude > threshold)) continue;
            try voters.append(.{ .x = @floatFromInt(x), .y = @floatFromInt(y), .ux = @floatCast(g.dx / g.magnitude), .uy = @floatCast(g.dy / g.magnitude) });
        }
    }

    // Each strong gradient votes for the points one radius along and against
    // it; a ring's centre collects votes from all round it.
    @memset(symmetry, 0);
    for (params.radii) |radius| {
        @memset(votes, 0);
        const r: f32 = @floatFromInt(radius);
        for (voters.items) |v| {
            for ([_]f32{ 1, -1 }) |sign| {
                const vy = @round(v.y + sign * r * v.uy);
                const vx = @round(v.x + sign * r * v.ux);
                if (vy < 0 or vx < 0) continue;
                const iy: usize = @intFromFloat(vy);
                const ix: usize = @intFromFloat(vx);
                if (iy < height and ix < width) votes[iy * width + ix] += 1;
            }
        }
        try blur(allocator, votes, width, height, 0.25 * @as(f64, r), tmp, blurred);
        const per_circumference: f32 = @floatCast(1 / (2 * std.math.pi * r));
        for (symmetry, blurred) |*s, b| s.* += b * per_circumference;
    }

    // Local maxima over the peak window.
    try maxFilter(allocator, symmetry, width, height, params.peak_window / 2, tmp, blurred);
    var centres = std.array_list.Managed(Centre).init(allocator);
    defer centres.deinit();
    for (symmetry, blurred, 0..) |s, peak, i| {
        if (s > 0 and s == peak) try centres.append(.{ .x = i % width, .y = i / width, .strength = s });
    }
    std.mem.sort(Centre, centres.items, {}, struct {
        fn stronger(_: void, a: Centre, b: Centre) bool {
            return a.strength > b.strength;
        }
    }.stronger);
    const count = @min(centres.items.len, max_centres);
    return allocator.dupe(Centre, centres.items[0..count]);
}

const Voter = struct {
    x: f32,
    y: f32,
    /// The unit gradient.
    ux: f32,
    uy: f32,
};

const Gradient = struct {
    dx: f64,
    dy: f64,
    magnitude: f64,
};

/// Sobel gradient with mirrored edges.
fn sobel(src: []const f32, width: usize, height: usize, x: usize, y: usize) Gradient {
    const xi: isize = @intCast(x);
    const yi: isize = @intCast(y);
    var dx: f64 = 0;
    var dy: f64 = 0;
    for ([_]isize{ -1, 0, 1 }, [_]f64{ 1, 2, 1 }) |o, weight| {
        const row_up = mirror(yi - 1, height) * width;
        const row_down = mirror(yi + 1, height) * width;
        const col = mirror(xi + o, width);
        dy += weight * (src[row_down + col] - src[row_up + col]);
        const row = mirror(yi + o, height) * width;
        dx += weight * (src[row + mirror(xi + 1, width)] - src[row + mirror(xi - 1, width)]);
    }
    return .{ .dx = dx, .dy = dy, .magnitude = @sqrt(dx * dx + dy * dy) };
}

/// The middle value of `values` (the upper one of an even count), which it
/// reorders: quickselect with three-way partitions.
fn median(values: []f32) f32 {
    const k = values.len / 2;
    var lo: usize = 0;
    var hi: usize = values.len;
    while (hi - lo > 1) {
        const a = values[lo];
        const b = values[lo + (hi - lo) / 2];
        const c = values[hi - 1];
        const pivot = @max(@min(a, b), @min(@max(a, b), c));
        var lt = lo;
        var i = lo;
        var gt = hi;
        while (i < gt) {
            if (values[i] < pivot) {
                std.mem.swap(f32, &values[lt], &values[i]);
                lt += 1;
                i += 1;
            } else if (values[i] > pivot) {
                gt -= 1;
                std.mem.swap(f32, &values[i], &values[gt]);
            } else {
                i += 1;
            }
        }
        if (k < lt) {
            hi = lt;
        } else if (k >= gt) {
            lo = gt;
        } else {
            return pivot;
        }
    }
    return values[k];
}

/// The maximum over a (2 * radius + 1) square about each pixel, clipped at
/// the edges.
fn maxFilter(allocator: std.mem.Allocator, src: []const f32, width: usize, height: usize, radius: usize, tmp: []f32, dst: []f32) !void {
    const Pass = struct {
        src: []const f32,
        dst: []f32,
        width: usize,
        height: usize,
        radius: usize,
        horizontal: bool,

        fn rows(p: @This(), row_start: usize, row_end: usize) void {
            for (row_start..row_end) |y| {
                const out = p.dst[y * p.width ..][0..p.width];
                if (p.horizontal) {
                    const row = p.src[y * p.width ..][0..p.width];
                    for (out, 0..) |*o, x| o.* = std.mem.max(f32, row[x -| p.radius..@min(p.width, x + p.radius + 1)]);
                } else {
                    @memcpy(out, p.src[y * p.width ..][0..p.width]);
                    for (y -| p.radius..@min(p.height, y + p.radius + 1)) |yy| {
                        for (out, p.src[yy * p.width ..][0..p.width]) |*o, v| o.* = @max(o.*, v);
                    }
                }
            }
        }
    };
    try parallelism.forRowBands(allocator, height, Pass{ .src = src, .dst = tmp, .width = width, .height = height, .radius = radius, .horizontal = true }, Pass.rows);
    try parallelism.forRowBands(allocator, height, Pass{ .src = tmp, .dst = dst, .width = width, .height = height, .radius = radius, .horizontal = false }, Pass.rows);
}

const ray_count = 96;
/// Ratios of red-minus-green cycles to IR fringes the fits try: 1.0 to 2.1.
const ratio_first = 1.0;
const ratio_step = 0.05;
const ratio_count = 23;
/// Visible rings sit at ratios 1.3 to 1.8 (indices 6 to 16), compared with
/// the fits 0.3 (6 steps) either side.
const ratio_lo = 6;
const ratio_hi = 16;
const ratio_offset = 6;

/// Fits along the rays from one centre; buffers sized for one ray length.
const RayFitter = struct {
    fft: Fft,
    re: []f64,
    im: []f64,
    /// Per ray: the IR fringe phase and red-minus-green density at each
    /// sample, and how many samples from the centre lie inside the frame.
    phase: []f64,
    colour: []f64,
    inside: [ray_count]usize,

    fn init(allocator: std.mem.Allocator, length: usize) !RayFitter {
        var self: RayFitter = undefined;
        self.fft = try Fft.init(allocator, length);
        errdefer self.fft.deinit(allocator);
        self.re = try allocator.alloc(f64, length);
        errdefer allocator.free(self.re);
        self.im = try allocator.alloc(f64, length);
        errdefer allocator.free(self.im);
        self.phase = try allocator.alloc(f64, ray_count * length);
        errdefer allocator.free(self.phase);
        self.colour = try allocator.alloc(f64, ray_count * length);
        return self;
    }

    fn deinit(self: *RayFitter, allocator: std.mem.Allocator) void {
        self.fft.deinit(allocator);
        allocator.free(self.re);
        allocator.free(self.im);
        allocator.free(self.phase);
        allocator.free(self.colour);
    }

    /// The centre's score, or null when no window of the rays lies inside the
    /// frame.
    fn score(self: *RayFitter, ir: []const f32, colour: []const f32, width: usize, height: usize, centre: Centre, params: Params) ?f64 {
        const length = params.ray_length;
        const cx: f64 = @floatFromInt(centre.x);
        const cy: f64 = @floatFromInt(centre.y);
        const max_x: f64 = @floatFromInt(width - 1);
        const max_y: f64 = @floatFromInt(height - 1);
        const flip_at = @min(length - 1, 3 * params.window / 2);
        for (0..ray_count) |k| {
            const angle = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / ray_count;
            const dx = @cos(angle);
            const dy = @sin(angle);
            const phase = self.phase[k * length ..][0..length];
            const ray_colour = self.colour[k * length ..][0..length];
            self.inside[k] = length;
            for (0..length) |r| {
                const rf: f64 = @floatFromInt(r);
                const x = cx + rf * dx;
                const y = cy + rf * dy;
                if (self.inside[k] == length and (x < 0 or y < 0 or x > max_x or y > max_y)) self.inside[k] = r;
                self.re[r] = bilinear(ir, width, height, x, y);
                ray_colour[r] = bilinear(colour, width, height, x, y);
            }
            analyticPhase(&self.fft, self.re, self.im, phase);
            // Phase grows outward, whichever way the fringes run.
            if (phase[flip_at] - phase[params.ray_start] + 1e-12 < 0) {
                for (phase) |*p| p.* = -p.*;
            }
        }

        var explained = [_]f64{0} ** ratio_count;
        var fits: usize = 0;
        var start = params.ray_start;
        while (start + params.window <= length) : (start += params.window / 2) {
            var rays_inside: usize = 0;
            for (self.inside) |inside| rays_inside += @intFromBool(start + params.window <= inside);
            if (rays_inside < 8) continue;
            for (self.inside, 0..) |inside, k| {
                if (start + params.window > inside) continue;
                const offset = k * length + start;
                fitWindow(self.phase[offset..][0..params.window], self.colour[offset..][0..params.window], &explained);
                fits += 1;
            }
        }
        if (fits == 0) return null;
        var best: f64 = -1;
        for (ratio_lo..ratio_hi + 1) |i| {
            const others = @max(explained[i - ratio_offset], explained[i + ratio_offset]);
            best = @max(best, (explained[i] - others) / @as(f64, @floatFromInt(fits)));
        }
        return best;
    }
};

/// Bilinear sample with coordinates clamped to the plane.
fn bilinear(plane: []const f32, width: usize, height: usize, x: f64, y: f64) f64 {
    const cx = std.math.clamp(x, 0, @as(f64, @floatFromInt(width - 1)));
    const cy = std.math.clamp(y, 0, @as(f64, @floatFromInt(height - 1)));
    const x0: usize = @intFromFloat(@floor(cx));
    const y0: usize = @intFromFloat(@floor(cy));
    const x1 = @min(x0 + 1, width - 1);
    const y1 = @min(y0 + 1, height - 1);
    const tx = cx - @as(f64, @floatFromInt(x0));
    const ty = cy - @as(f64, @floatFromInt(y0));
    const top = (1 - tx) * plane[y0 * width + x0] + tx * plane[y0 * width + x1];
    const bottom = (1 - tx) * plane[y1 * width + x0] + tx * plane[y1 * width + x1];
    return (1 - ty) * top + ty * bottom;
}

/// Adds to `explained`, for each ratio, the share of `colour`'s variance
/// that a sinusoid of that multiple of `phase` explains (least squares).
fn fitWindow(phase: []const f64, colour: []const f64, explained: *[ratio_count]f64) void {
    var mean: f64 = 0;
    for (colour) |c| mean += c;
    mean /= @floatFromInt(colour.len);
    var total: f64 = 1e-30;
    var cc = [_]f64{0} ** ratio_count;
    var ss = [_]f64{0} ** ratio_count;
    var cs = [_]f64{0} ** ratio_count;
    var vc = [_]f64{0} ** ratio_count;
    var vs = [_]f64{0} ** ratio_count;
    for (phase, colour) |p, c| {
        const v = c - mean;
        total += v * v;
        // cos and sin of each ratio times p, stepping the ratio by rotation.
        var re = @cos(ratio_first * p);
        var im = @sin(ratio_first * p);
        const step_re = @cos(ratio_step * p);
        const step_im = @sin(ratio_step * p);
        for (0..ratio_count) |j| {
            cc[j] += re * re;
            ss[j] += im * im;
            cs[j] += re * im;
            vc[j] += v * re;
            vs[j] += v * im;
            const next_re = re * step_re - im * step_im;
            im = re * step_im + im * step_re;
            re = next_re;
        }
    }
    for (0..ratio_count) |j| {
        const det = cc[j] * ss[j] - cs[j] * cs[j] + 1e-30;
        const a = (vc[j] * ss[j] - vs[j] * cs[j]) / det;
        const b = (vs[j] * cc[j] - vc[j] * cs[j]) / det;
        explained[j] += (a * vc[j] + b * vs[j]) / total;
    }
}

/// The unwrapped phase of the analytic signal of `re` (the Hilbert transform
/// by FFT); `re` and `im` are scratch of the FFT's length.
fn analyticPhase(fft: *const Fft, re: []f64, im: []f64, phase: []f64) void {
    const n = fft.n;
    @memset(im, 0);
    fft.transform(re, im, false);
    for (1..n / 2) |k| {
        re[k] *= 2;
        im[k] *= 2;
    }
    @memset(re[n / 2 + 1 ..], 0);
    @memset(im[n / 2 + 1 ..], 0);
    fft.transform(re, im, true);
    var correction: f64 = 0;
    var previous: f64 = 0;
    for (0..n) |i| {
        const raw = std.math.atan2(im[i], re[i]);
        if (i > 0) {
            const step = raw - previous;
            if (@abs(step) >= std.math.pi) {
                var wrapped = @mod(step + std.math.pi, 2 * std.math.pi) - std.math.pi;
                if (wrapped == -std.math.pi and step > 0) wrapped = std.math.pi;
                correction += wrapped - step;
            }
        }
        phase[i] = raw + correction;
        previous = raw;
    }
}

/// Radix-2 complex FFT of one power-of-two length.
const Fft = struct {
    n: usize,
    cos: []f64,
    sin: []f64,

    fn init(allocator: std.mem.Allocator, n: usize) !Fft {
        const cos = try allocator.alloc(f64, n / 2);
        errdefer allocator.free(cos);
        const sin = try allocator.alloc(f64, n / 2);
        for (cos, sin, 0..) |*c, *s, k| {
            const angle = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            c.* = @cos(angle);
            s.* = @sin(angle);
        }
        return .{ .n = n, .cos = cos, .sin = sin };
    }

    fn deinit(self: *Fft, allocator: std.mem.Allocator) void {
        allocator.free(self.cos);
        allocator.free(self.sin);
    }

    /// In place; the inverse divides by n.
    fn transform(self: *const Fft, re: []f64, im: []f64, inverse: bool) void {
        const n = self.n;
        var j: usize = 0;
        for (1..n) |i| {
            var bit = n >> 1;
            while (j & bit != 0) : (bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) {
                std.mem.swap(f64, &re[i], &re[j]);
                std.mem.swap(f64, &im[i], &im[j]);
            }
        }
        var len: usize = 2;
        while (len <= n) : (len <<= 1) {
            const stride = n / len;
            var i: usize = 0;
            while (i < n) : (i += len) {
                for (0..len / 2) |k| {
                    const wr = self.cos[k * stride];
                    const wi = if (inverse) self.sin[k * stride] else -self.sin[k * stride];
                    const a = i + k;
                    const b = a + len / 2;
                    const tr = re[b] * wr - im[b] * wi;
                    const ti = re[b] * wi + im[b] * wr;
                    re[b] = re[a] - tr;
                    im[b] = im[a] - ti;
                    re[a] += tr;
                    im[a] += ti;
                }
            }
        }
        if (inverse) {
            const scale = 1 / @as(f64, @floatFromInt(n));
            for (re, im) |*r, *m| {
                r.* *= scale;
                m.* *= scale;
            }
        }
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

test "blurs keep a flat field and spread an impulse symmetrically to the asked sigma" {
    const allocator = std.testing.allocator;
    const w = 161;
    const h = 141;
    const src = try allocator.alloc(f32, w * h);
    defer allocator.free(src);
    const tmp = try allocator.alloc(f32, w * h);
    defer allocator.free(tmp);
    const dst = try allocator.alloc(f32, w * h);
    defer allocator.free(dst);
    for ([_]f64{ 1.5, 12 }) |sigma| {
        @memset(src, 0);
        src[70 * w + 80] = 1;
        try blur(allocator, src, w, h, sigma, tmp, dst);
        var total: f64 = 0;
        var variance: f64 = 0;
        for (dst, 0..) |v, i| {
            total += v;
            const dx = @as(f64, @floatFromInt(i % w)) - 80;
            variance += v * dx * dx;
        }
        try std.testing.expectApproxEqAbs(@as(f64, 1), total, 1e-4);
        try std.testing.expectApproxEqRel(sigma * sigma, variance, 0.05);
        try std.testing.expectApproxEqAbs(dst[70 * w + 77], dst[70 * w + 83], 1e-6);
        try std.testing.expectApproxEqAbs(dst[66 * w + 80], dst[74 * w + 80], 1e-6);
        @memset(src, 3);
        try blur(allocator, src, w, h, sigma, tmp, dst);
        for (dst) |v| try std.testing.expectApproxEqAbs(@as(f32, 3), v, 1e-4);
    }
}

test "the analytic phase of a chirp follows it" {
    const allocator = std.testing.allocator;
    var fft = try Fft.init(allocator, 256);
    defer fft.deinit(allocator);
    var re: [256]f64 = undefined;
    var im: [256]f64 = undefined;
    var phase: [256]f64 = undefined;
    const expected = struct {
        fn at(i: usize) f64 {
            const t: f64 = @floatFromInt(i);
            return 0.3 * t + 0.0004 * t * t;
        }
    }.at;
    for (&re, 0..) |*r, i| r.* = @cos(expected(i));
    analyticPhase(&fft, &re, &im, &phase);
    for (40..216) |i| try std.testing.expectApproxEqAbs(expected(i) - expected(128), phase[i] - phase[128], 0.15);
}

test "a fit explains colour that runs at its ratio to the phase and little else" {
    var phase: [80]f64 = undefined;
    var colour: [80]f64 = undefined;
    for (&phase, &colour, 0..) |*p, *c, i| {
        p.* = 0.5 * @as(f64, @floatFromInt(i));
        c.* = @cos(1.5 * p.* + 0.7);
    }
    var explained = [_]f64{0} ** ratio_count;
    fitWindow(&phase, &colour, &explained);
    // Not quite 1: the window's mean comes off first.
    try std.testing.expect(explained[10] > 0.99);
    try std.testing.expect(explained[10 - ratio_offset] < 0.3);
    try std.testing.expect(explained[10 + ratio_offset] < 0.3);
}

test "the median is the middle value" {
    var values = [_]f32{ 5, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5 };
    try std.testing.expectEqual(@as(f32, 5), median(&values));
    var even = [_]f32{ 8, 2, 7, 1 };
    try std.testing.expectEqual(@as(f32, 7), median(&even));
}

/// A synthetic frame at the check's grid: a smooth picture with a soft edge,
/// film grain, and Newton's rings about a dust speck in the IR. With
/// `visible`, red and green show them too, at the dyes' wavelengths. It
/// tests the plumbing only; the check is tuned and judged on real scans.
fn syntheticFrame(allocator: std.mem.Allocator, visible: bool) ![]u16 {
    const w = 400;
    const h = 400;
    const pixels = try allocator.alloc(u16, w * h * 4);
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (0..h) |y| {
        for (0..w) |x| {
            const dx = @as(f64, @floatFromInt(x)) - 190;
            const dy = @as(f64, @floatFromInt(y)) - 210;
            // Gap in micrometres, 42 px per mm: the film slopes down from a
            // speck at the centre, and the white light's fringes fade
            // faster than the narrow-band IR's.
            const r_mm = @sqrt(dx * dx + dy * dy) / 42.0;
            const gap_um = 6 - 0.25 * r_mm * r_mm;
            const ir_mod = 0.04 * @cos(4 * std.math.pi * gap_um / 0.94);
            const fade = @exp(-(r_mm * r_mm) / 9.0);
            const red_mod = if (visible) 0.03 * fade * @cos(4 * std.math.pi * gap_um / 0.61) else 0;
            const green_mod = if (visible) 0.02 * fade * @cos(4 * std.math.pi * gap_um / 0.54) else 0;
            const picture = 0.3 * std.math.tanh((@as(f64, @floatFromInt(x)) - 300) / 6);
            var grain: [4]f64 = undefined;
            for (&grain) |*g| g.* = 0.01 * (random.float(f64) - 0.5);
            const base = (y * w + x) * 4;
            pixels[base] = @intFromFloat(30000 * @exp(picture + red_mod + grain[0]));
            pixels[base + 1] = @intFromFloat(28000 * @exp(picture + green_mod + grain[1]));
            pixels[base + 2] = @intFromFloat(26000 * @exp(picture + grain[2]));
            pixels[base + 3] = @intFromFloat(@min(65535, 40000 * @exp(ir_mod + 0.2 * picture + grain[3])));
        }
    }
    return pixels;
}

test "the check runs end to end: synthetic rings in colour warn, IR alone does not" {
    const allocator = std.testing.allocator;
    for ([_]bool{ true, false }) |visible| {
        const all = try syntheticFrame(allocator, visible);
        defer allocator.free(all);
        const rgb = try allocator.alloc(u16, 400 * 400 * 3);
        defer allocator.free(rgb);
        const ir = try allocator.alloc(u16, 400 * 400);
        defer allocator.free(ir);
        for (0..400 * 400) |i| {
            @memcpy(rgb[i * 3 ..][0..3], all[i * 4 ..][0..3]);
            ir[i] = all[i * 4 + 3];
        }
        const score = try ringScore(u16, u16, allocator, .{ .pixels = rgb, .width = 400, .height = 400, .channels = 3 }, .{}, .{ .pixels = ir, .width = 400, .height = 400, .channels = 1 }, .{ .cx = 200, .cy = 200, .w = 400, .h = 400 }, 1067);
        try std.testing.expectEqual(visible, warns(score));
    }
}
