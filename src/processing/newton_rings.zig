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
//! Tuned on 136 real 35mm and 6x7 frames scanned at 6400 dpi. Sizes are in
//! millimetres of film, so they hold at any scan resolution.
const std = @import("std");
const config = @import("config.zig");
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
    try writer.writeAll("Newton's rings in ");
    try writeFrames(writer, frames);
    try writer.writeAll(if (frames.len == 1) ": consider rescanning it" else ": consider rescanning them");
}

/// "frame 3", "frames 2 and 4", "frames 1, 3, and 5".
pub fn writeFrames(writer: *std.Io.Writer, frames: []const usize) std.Io.Writer.Error!void {
    try writer.writeAll(if (frames.len == 1) "frame " else "frames ");
    for (frames, 0..) |frame, index| {
        if (index > 0) try writer.writeAll(if (index + 1 < frames.len) ", " else if (frames.len == 2) " and " else ", and ");
        try writer.print("{d}", .{frame});
    }
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
/// at other ratios. Over 0.05 where the owner sees rings plainly, 0.05 and
/// under where they are faint or absent; the warning keeps a margin above
/// the faint ones. `frame` is in whole-scan coordinates; `rgb` holds the page
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
    var analysis = (try analyze(Rgb, Ir, allocator, rgb, rows, ir, frame, dpi)) orelse return 0;
    defer analysis.deinit(allocator);
    return analysis.score();
}

/// An RGB page as exports hold it, linear values, which `reduceRings`
/// changes.
pub const Image = struct {
    pixels: []f64,
    width: usize,
    height: usize,
    channels: usize,
};

/// Whether exports subtract the visible rings: the `reduce_newton_rings`
/// setting, on unless set off.
pub fn reduceForConfig(overrides: []const config.Override) bool {
    for (overrides) |entry| {
        if (std.mem.eql(u8, entry.name, "reduce_newton_rings")) return switch (entry.value) {
            .boolean => |on| on,
            else => true,
        };
    }
    return true;
}

/// Subtracts from `rgb` the visible rings about every centre of `frame` that
/// scores at the warning level, and returns the frame's score from before,
/// as `ringScore` does: the rings are fainter, not gone, so the warning
/// stands. Weaker centres are left alone: the gates in `PolarFit` do not
/// hold back picture on their own (run on every centre, they change
/// ring-free frames), and a centre scoring 0.056 took a cloud's texture for
/// rings. `ir` is the whole IR page, at any resolution.
pub fn reduceRings(allocator: std.mem.Allocator, rgb: Image, ir: View(f64), frame: Frame, dpi: u32) !f64 {
    const view = View(f64){ .pixels = rgb.pixels, .width = rgb.width, .height = rgb.height, .channels = rgb.channels };
    var analysis = (try analyze(f64, f64, allocator, view, .{}, ir, frame, dpi)) orelse return 0;
    defer analysis.deinit(allocator);
    const score = analysis.score();
    if (!warns(score)) return score;
    const order = try allocator.dupe(Found, analysis.found);
    defer allocator.free(order);
    std.mem.sort(Found, order, {}, struct {
        fn stronger(_: void, a: Found, b: Found) bool {
            return a.score > b.score;
        }
    }.stronger);
    var reduced: usize = 0;
    while (reduced < order.len and warns(order[reduced].score)) reduced += 1;
    {
        var removed = try ringModels(allocator, &analysis, order[0..reduced]);
        defer for (&removed) |plane| allocator.free(plane);
        try applyToPixels(allocator, rgb, removed, analysis.placement());
    }
    for (order[0..reduced]) |found| try finePass(allocator, rgb, ir, &analysis, found, dpi);
    return score;
}

/// A frame on the check's grid with its band-passed planes and every IR
/// ring centre's fit.
const Analysis = struct {
    params: Params,
    factor: usize,
    /// The grid's first RGB pixel, in the rows the check was given.
    x0: usize,
    y0: usize,
    grid: Grid,
    bands: Bands,
    found: []Found,

    fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        allocator.free(self.found);
        self.bands.deinit(allocator);
        self.grid.deinit(allocator);
    }

    fn score(self: Analysis) f64 {
        var best: f64 = 0;
        for (self.found) |found| best = @max(best, found.score);
        return best;
    }

    fn placement(self: *const Analysis) Placement {
        return .{ .factor = self.factor, .x0 = self.x0, .y0 = self.y0, .width = self.grid.width, .height = self.grid.height };
    }
};

/// Where a grid sits on the RGB page: cell (x, y) averages the `factor` x
/// `factor` pixels from (x0 + factor x, y0 + factor y).
const Placement = struct {
    factor: usize,
    x0: usize,
    y0: usize,
    width: usize,
    height: usize,
};

const Found = struct {
    centre: Centre,
    score: f64,
    /// Red-minus-green cycles per IR fringe at the best fit.
    ratio: f64,
};

fn analyze(
    comptime Rgb: type,
    comptime Ir: type,
    allocator: std.mem.Allocator,
    rgb: View(Rgb),
    rows: Rows,
    ir: View(Ir),
    frame: Frame,
    dpi: u32,
) !?Analysis {
    const factor: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(dpi)) / grid_dpi))));
    const params = Params.init(@as(f64, @floatFromInt(dpi)) / @as(f64, @floatFromInt(factor)) / 25.4);

    const first: f64 = @floatFromInt(rows.first);
    const x0 = clampToExtent(frame.cx - 0.5 * frame.w, rgb.width);
    const x1 = clampToExtent(frame.cx + 0.5 * frame.w, rgb.width);
    const y0 = clampToExtent(frame.cy - 0.5 * frame.h - first, rgb.height);
    const y1 = clampToExtent(frame.cy + 0.5 * frame.h - first, rgb.height);
    const width = (x1 -| x0) / factor;
    const height = (y1 -| y0) / factor;
    if (width < 2 * params.window or height < 2 * params.window) return null;

    var grid = try Grid.init(allocator, width, height);
    errdefer grid.deinit(allocator);
    try sampleRgb(Rgb, allocator, rgb, x0, y0, factor, &grid);
    sampleIr(Ir, ir, rgb.width, rows.page_height orelse rgb.height, x0, rows.first + y0, factor, &grid);
    try regressOutPicture(&grid);
    var bands = try Bands.init(allocator, &grid, params);
    errdefer bands.deinit(allocator);

    const centres = try ringCentres(allocator, bands.centres, width, height, params);
    defer allocator.free(centres);
    var fitter = try RayFitter.init(allocator, params.ray_length);
    defer fitter.deinit(allocator);
    var found = try std.array_list.Managed(Found).initCapacity(allocator, centres.len);
    errdefer found.deinit();
    for (centres) |centre| {
        const fit = fitter.fit(bands.ir, bands.colour, width, height, centre, params) orelse continue;
        found.appendAssumeCapacity(.{ .centre = centre, .score = fit.score, .ratio = fit.ratio });
    }
    return .{ .params = params, .factor = factor, .x0 = x0, .y0 = y0, .grid = grid, .bands = bands, .found = try found.toOwnedSlice() };
}

fn clampToExtent(value: f64, extent: usize) usize {
    return @intFromFloat(std.math.clamp(@floor(value), 0, @as(f64, @floatFromInt(extent))));
}

/// Sizes on the check's grid, from millimetres of film.
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
    /// Ring removal: the colour fit's window, the radius rays match their
    /// IR fringe counts at, and the fade at the rays' ends.
    fit_sigma: f64,
    ring_ref: usize,
    taper: f64,
    px_per_mm: f64,

    fn init(px_per_mm: f64) Params {
        var radii: [7]usize = undefined;
        for (&radii, [_]f64{ 0.476, 0.714, 1.048, 1.524, 2.191, 3.143, 4.524 }) |*radius, mm| radius.* = @max(2, px(mm, px_per_mm));
        return .{
            .fine = 0.0238 * px_per_mm,
            .broad = 1.429 * px_per_mm,
            .centre_fine = 0.0714 * px_per_mm,
            .radii = radii,
            .peak_window = px(1.976, px_per_mm) | 1,
            // The power of two nearest 6.1 mm.
            .ray_length = std.math.ceilPowerOfTwoAssert(usize, @max(64, px(6.096 / std.math.sqrt2, px_per_mm))),
            .window = @max(16, px(1.905, px_per_mm)),
            .ray_start = px(0.286, px_per_mm),
            .fit_sigma = 0.286 * px_per_mm,
            .ring_ref = px(0.952, px_per_mm),
            .taper = 0.571 * px_per_mm,
            .px_per_mm = px_per_mm,
        };
    }

    fn px(mm: f64, px_per_mm: f64) usize {
        return @intFromFloat(@round(mm * px_per_mm));
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

    fn init(allocator: std.mem.Allocator, grid: *const Grid, params: Params) !Bands {
        const w = grid.width;
        const h = grid.height;
        const tmp = try allocator.alloc(f32, grid.len());
        defer allocator.free(tmp);
        const broad = try allocator.alloc(f32, grid.len());
        defer allocator.free(broad);
        const red_green = try allocator.alloc(f32, grid.len());
        defer allocator.free(red_green);
        for (red_green, grid.density[0], grid.density[1]) |*d, r, g| d.* = r - g;
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

        try blur(allocator, red_green, w, h, params.broad, tmp, broad);
        self.colour = try allocator.alloc(f32, grid.len());
        try blur(allocator, red_green, w, h, params.fine, tmp, self.colour);
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

    const Fit = struct {
        score: f64,
        ratio: f64,
    };

    /// The centre's score and best ratio, or null when no window of the
    /// rays lies inside the frame.
    fn fit(self: *RayFitter, ir: []const f32, colour: []const f32, width: usize, height: usize, centre: Centre, params: Params) ?Fit {
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
        var best = Fit{ .score = -1, .ratio = 0 };
        for (ratio_lo..ratio_hi + 1) |i| {
            const others = @max(explained[i - ratio_offset], explained[i + ratio_offset]);
            const score = (explained[i] - others) / @as(f64, @floatFromInt(fits));
            if (score > best.score) best = .{ .score = score, .ratio = ratio_first + ratio_step * @as(f64, @floatFromInt(i)) };
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

// Ring removal. Visible rings add to the density of the film under them, so
// subtracting a model of them in density (multiplying linear values) leaves
// the picture as it was. The model comes from the IR: about each ring
// centre, along rays, the colour density is fitted as a sinusoid of the
// detector's ratio times the IR fringe phase. Tuned on real 6400 dpi frames
// by exporting with and without it.

/// The rings count at an IR phase where, pooled round the ring system,
/// they explain this many times what chance would.
const presence_k = 2.0;
/// The area, in grid pixels, over which grain is correlated: grain is finer
/// than a grid pixel, and sampling the rays bilinearly spreads it over about
/// two.
const corr_area = 2.0;
/// The ring system's IR phase in bins of this width, pooled over
/// `bin_sigma` bins (half an IR fringe) either way.
const bin_width = std.math.pi / 8.0;
const bin_sigma = 8.0;
/// The removal reaches this many IR fringes beyond where rings show.
const zone_margin = 4.0;

/// Sizes of one ring fit, in its grid's pixels.
const FitSizes = struct {
    ray_length: usize,
    ray_start: usize,
    flip_at: usize,
    ring_ref: usize,
    fit_sigma: f64,
    /// The subtraction fades out over `taper` to nothing at `reach`.
    reach: f64,
    taper: f64,
    /// A fit counts where it explains this many times what chance would in
    /// its window.
    local_k: f64,

    fn coarse(params: Params) FitSizes {
        return .{
            .ray_length = params.ray_length,
            .ray_start = params.ray_start,
            .flip_at = @min(params.ray_length - 1, 3 * params.window / 2),
            .ring_ref = params.ring_ref,
            .fit_sigma = params.fit_sigma,
            .reach = @floatFromInt(params.ray_length - 1),
            .taper = params.taper,
            .local_k = 2,
        };
    }

    /// The fine pass: rays of 2 mm, a fit window a fifth of the coarse one,
    /// so with fewer pixels a stricter gate; it works on the middle of the
    /// ring system, fading out from 0.6 to 1 mm and leaving the rest to the
    /// coarse pass. Run further out and looser, it took grain for rings and
    /// left a seam along the IR fringe where its gates closed.
    fn fine(px_per_mm: f64) FitSizes {
        const length = std.math.ceilPowerOfTwoAssert(usize, @max(64, Params.px(2.03 / std.math.sqrt2, px_per_mm)));
        return .{
            .ray_length = length,
            .ray_start = Params.px(0.095, px_per_mm),
            .flip_at = @min(length - 1, Params.px(0.95, px_per_mm)),
            .ring_ref = Params.px(0.30, px_per_mm),
            .fit_sigma = 0.06 * px_per_mm,
            .reach = 1.0 * px_per_mm,
            .taper = 0.4 * px_per_mm,
            .local_k = 6,
        };
    }
};

/// Picture edges and dust, in a grid's pixels. Edges steeper than `tau`
/// density per pixel after a blur of `blur` hold the removal off within
/// `grow`; within `core` of a ring centre (fading out over another `core`)
/// only steps across the radius count, since the rings, and a round speck,
/// step along it. IR defects (dust, denser in the IR than its blur of
/// `defect_blur` around it by 0.04, grown by `defect_grow`) stay out of the
/// fit, and steps within `defect_reach` of one do not count as edges: the
/// speck that holds the film off the glass sits at the middle of its rings,
/// and the export's dust removal paints it out.
const EdgeSizes = struct {
    blur: f64,
    tau: f64,
    grow: usize,
    core: f64,
    defect_blur: f64,
    defect_grow: usize,
    defect_reach: usize,

    fn init(px_per_mm: f64) EdgeSizes {
        return .{
            .blur = 0.0357 * px_per_mm,
            .tau = 0.672 / px_per_mm,
            .grow = Params.px(0.286, px_per_mm),
            .core = 1.0 * px_per_mm,
            .defect_blur = 0.095 * px_per_mm,
            .defect_grow = @max(1, Params.px(0.048, px_per_mm)),
            .defect_reach = @max(1, Params.px(0.05, px_per_mm)),
        };
    }
};

/// IR defects as 1, else 0, and the same grown by `defect_reach`.
const Defects = struct {
    mask: []f32,
    near: []f32,

    fn init(allocator: std.mem.Allocator, grid: *const Grid, sizes: EdgeSizes) !Defects {
        const n = grid.len();
        const tmp = try allocator.alloc(f32, n);
        defer allocator.free(tmp);
        const raw = try allocator.alloc(f32, n);
        defer allocator.free(raw);
        try blur(allocator, grid.ir, grid.width, grid.height, sizes.defect_blur, tmp, raw);
        for (raw, grid.ir) |*r, v| r.* = if (v - r.* > 0.04) 1 else 0;
        var self = Defects{ .mask = try allocator.alloc(f32, n), .near = &.{} };
        errdefer allocator.free(self.mask);
        try maxFilter(allocator, raw, grid.width, grid.height, sizes.defect_grow, tmp, self.mask);
        self.near = try allocator.alloc(f32, n);
        try maxFilter(allocator, self.mask, grid.width, grid.height, sizes.defect_reach, tmp, self.near);
        return self;
    }

    fn deinit(self: *Defects, allocator: std.mem.Allocator) void {
        allocator.free(self.mask);
        allocator.free(self.near);
    }
};

/// Each channel's density gradient after the edge blur.
const Gradients = struct {
    dx: [3][]f32,
    dy: [3][]f32,

    fn init(allocator: std.mem.Allocator, grid: *const Grid, sizes: EdgeSizes) !Gradients {
        const n = grid.len();
        var self = Gradients{ .dx = .{ &.{}, &.{}, &.{} }, .dy = .{ &.{}, &.{}, &.{} } };
        errdefer self.deinit(allocator);
        const tmp = try allocator.alloc(f32, n);
        defer allocator.free(tmp);
        const blurred = try allocator.alloc(f32, n);
        defer allocator.free(blurred);
        for (grid.density, &self.dx, &self.dy) |plane, *dx, *dy| {
            dx.* = try allocator.alloc(f32, n);
            dy.* = try allocator.alloc(f32, n);
            try blur(allocator, plane, grid.width, grid.height, sizes.blur, tmp, blurred);
            for (0..grid.height) |y| {
                for (0..grid.width) |x| {
                    const g = sobel(blurred, grid.width, grid.height, x, y);
                    dx.*[y * grid.width + x] = @floatCast(g.dx / 8);
                    dy.*[y * grid.width + x] = @floatCast(g.dy / 8);
                }
            }
        }
        return self;
    }

    fn deinit(self: *Gradients, allocator: std.mem.Allocator) void {
        for (self.dx) |plane| allocator.free(plane);
        for (self.dy) |plane| allocator.free(plane);
    }
};

/// The edge weight about one centre, out to `reach` (0 beyond): 1 on smooth
/// picture, falling to 0 near picture edges.
fn edgeWeight(
    allocator: std.mem.Allocator,
    gradients: *const Gradients,
    defects: *const Defects,
    width: usize,
    height: usize,
    centre: Centre,
    reach: usize,
    sizes: EdgeSizes,
    out: []f32,
) !void {
    @memset(out, 0);
    const span = reach + sizes.grow + 1;
    const x0 = centre.x -| span;
    const x1 = @min(width, centre.x + span + 1);
    const y0 = centre.y -| span;
    const y1 = @min(height, centre.y + span + 1);
    const ww = x1 - x0;
    const wh = y1 - y0;
    const steep = try allocator.alloc(f32, ww * wh);
    defer allocator.free(steep);
    const grown = try allocator.alloc(f32, ww * wh);
    defer allocator.free(grown);
    const tmp = try allocator.alloc(f32, ww * wh);
    defer allocator.free(tmp);
    const cx: f64 = @floatFromInt(centre.x);
    const cy: f64 = @floatFromInt(centre.y);
    for (y0..y1) |y| {
        for (x0..x1) |x| {
            const i = y * width + x;
            const local = (y - y0) * ww + (x - x0);
            if (defects.near[i] != 0) {
                steep[local] = 0;
                continue;
            }
            const dx = @as(f64, @floatFromInt(x)) - cx;
            const dy = @as(f64, @floatFromInt(y)) - cy;
            const r = @sqrt(dx * dx + dy * dy) + 1e-9;
            const near = std.math.clamp(2 - r / sizes.core, 0, 1);
            var g: f64 = 0;
            for (gradients.dx, gradients.dy) |gxs, gys| {
                const gx: f64 = gxs[i];
                const gy: f64 = gys[i];
                const across = @abs(gx * dy / r - gy * dx / r);
                g = @max(g, near * across + (1 - near) * @sqrt(gx * gx + gy * gy));
            }
            steep[local] = @floatCast(g);
        }
    }
    try maxFilter(allocator, steep, ww, wh, sizes.grow, tmp, grown);
    const tau: f32 = @floatCast(sizes.tau);
    for (y0..y1) |y| {
        for (x0..x1) |x| {
            const g = grown[(y - y0) * ww + (x - x0)];
            out[y * width + x] = @exp(-(g / tau) * (g / tau));
        }
    }
}

/// The rings to subtract, per channel on the grid: centre by centre (in
/// `reduced`, the strongest first), each fitted to the densities the ones
/// before left. The fits take the densities as they are: a local level and
/// gradient stand for the picture, where a high-pass would leave halos by
/// edges that the fit takes for rings.
fn ringModels(allocator: std.mem.Allocator, analysis: *const Analysis, reduced: []const Found) ![3][]f32 {
    const grid = &analysis.grid;
    const params = analysis.params;
    const n = grid.len();
    var removed = [3][]f32{ &.{}, &.{}, &.{} };
    errdefer for (removed) |plane| allocator.free(plane);
    var densities = [3][]f32{ &.{}, &.{}, &.{} };
    defer for (densities) |plane| allocator.free(plane);
    for (&removed, &densities, grid.density) |*r, *d, source| {
        r.* = try allocator.alloc(f32, n);
        @memset(r.*, 0);
        d.* = try allocator.dupe(f32, source);
    }
    const sizes = FitSizes.coarse(params);
    const edges = EdgeSizes.init(params.px_per_mm);
    var defects = try Defects.init(allocator, grid, edges);
    defer defects.deinit(allocator);
    var gradients = try Gradients.init(allocator, grid, edges);
    defer gradients.deinit(allocator);
    const edge = try allocator.alloc(f32, n);
    defer allocator.free(edge);

    var fit = try PolarFit.init(allocator, sizes.ray_length);
    defer fit.deinit(allocator);
    for (reduced) |found| {
        try edgeWeight(allocator, &gradients, &defects, grid.width, grid.height, found.centre, sizes.ray_length, edges, edge);
        try fit.subtract(allocator, densities, analysis.bands.ir, edge, defects.near, grid.width, grid.height, found.centre, found.ratio, sizes, removed);
    }
    return removed;
}

/// The grid the fine pass runs on: 6400 dpi scans average 2 x 2 pixels, to
/// the IR's own resolution.
const fine_dpi: f64 = 3200;
/// The fine pass runs only where the IR phase climbs this steadily out from
/// the centre (`refineCentre`): small dust bullseyes reach 0.99, and where
/// the IR rings are irregular (0.7-0.9: contact fields, noisy frames) a
/// fit this fine follows the wrong phase and adds rings instead.
const fine_steadiness = 0.92;

/// After the coarse pass, the rings left within 2 mm of one centre, fitted
/// on a grid three times finer: the middle of a small ring system is finer
/// than the coarse fit can follow. The fit runs on the pixels as the coarse
/// pass left them, about the point the IR rings centre on.
fn finePass(allocator: std.mem.Allocator, rgb: Image, ir: View(f64), analysis: *const Analysis, found: Found, dpi: u32) !void {
    const factor: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(dpi)) / fine_dpi))));
    const px_per_mm = @as(f64, @floatFromInt(dpi)) / @as(f64, @floatFromInt(factor)) / 25.4;
    const sizes = FitSizes.fine(px_per_mm);
    const edges = EdgeSizes.init(px_per_mm);

    // The centre on the RGB page, and a square about it within the frame.
    const coarse = analysis.placement();
    const cf: f64 = @floatFromInt(coarse.factor);
    const px: f64 = @as(f64, @floatFromInt(coarse.x0)) + (@as(f64, @floatFromInt(found.centre.x)) + 0.5) * cf;
    const py: f64 = @as(f64, @floatFromInt(coarse.y0)) + (@as(f64, @floatFromInt(found.centre.y)) + 0.5) * cf;
    const half: f64 = @floatFromInt((sizes.ray_length + edges.grow + 2) * factor);
    const fx0f: f64 = @floatFromInt(coarse.x0);
    const fy0f: f64 = @floatFromInt(coarse.y0);
    const fx1f: f64 = @floatFromInt(coarse.x0 + coarse.width * coarse.factor);
    const fy1f: f64 = @floatFromInt(coarse.y0 + coarse.height * coarse.factor);
    const x0: usize = @intFromFloat(@max(fx0f, @floor(px - half)));
    const y0: usize = @intFromFloat(@max(fy0f, @floor(py - half)));
    const x1: usize = @intFromFloat(@min(fx1f, @floor(px + half)));
    const y1: usize = @intFromFloat(@min(fy1f, @floor(py + half)));
    const width = (x1 -| x0) / factor;
    const height = (y1 -| y0) / factor;
    if (width < 4 * sizes.ray_start or height < 4 * sizes.ray_start) return;

    const view = View(f64){ .pixels = rgb.pixels, .width = rgb.width, .height = rgb.height, .channels = rgb.channels };
    var grid = try Grid.init(allocator, width, height);
    defer grid.deinit(allocator);
    try sampleRgb(f64, allocator, view, x0, y0, factor, &grid);
    sampleIr(f64, ir, rgb.width, rgb.height, x0, y0, factor, &grid);
    try regressOutPicture(&grid);

    const n = grid.len();
    const tmp = try allocator.alloc(f32, n);
    defer allocator.free(tmp);
    const broad = try allocator.alloc(f32, n);
    defer allocator.free(broad);
    const band = try allocator.alloc(f32, n);
    defer allocator.free(band);
    try blur(allocator, grid.ir, width, height, 0.5 * px_per_mm, tmp, broad);
    try blur(allocator, grid.ir, width, height, 0.008 * px_per_mm, tmp, band);
    for (band, broad) |*b, w| b.* -= w;

    const ff: f64 = @floatFromInt(factor);
    const start = Centre{
        .x = @intFromFloat(std.math.clamp((px - @as(f64, @floatFromInt(x0))) / ff - 0.5, 0, @as(f64, @floatFromInt(width - 1)))),
        .y = @intFromFloat(std.math.clamp((py - @as(f64, @floatFromInt(y0))) / ff - 0.5, 0, @as(f64, @floatFromInt(height - 1)))),
        .strength = 0,
    };
    const refined = try refineCentre(allocator, band, width, height, start, Params.px(0.19, px_per_mm), sizes.ray_length / 2);
    if (refined.steadiness < fine_steadiness) return;
    const centre = refined.centre;

    var defects = try Defects.init(allocator, &grid, edges);
    defer defects.deinit(allocator);
    var gradients = try Gradients.init(allocator, &grid, edges);
    defer gradients.deinit(allocator);
    const edge = try allocator.alloc(f32, n);
    defer allocator.free(edge);
    try edgeWeight(allocator, &gradients, &defects, width, height, centre, sizes.ray_length, edges, edge);

    var removed = [3][]f32{ &.{}, &.{}, &.{} };
    defer for (removed) |plane| allocator.free(plane);
    for (&removed) |*r| {
        r.* = try allocator.alloc(f32, n);
        @memset(r.*, 0);
    }
    var fit = try PolarFit.init(allocator, sizes.ray_length);
    defer fit.deinit(allocator);
    try fit.subtract(allocator, grid.density, band, edge, defects.near, width, height, centre, found.ratio, sizes, removed);
    try applyToPixels(allocator, rgb, removed, .{ .factor = factor, .x0 = x0, .y0 = y0, .width = width, .height = height });
}

const Refined = struct {
    centre: Centre,
    /// The share of steps along the rays where the IR phase moves the ray's
    /// way.
    steadiness: f64,
};

/// The point within `search` of `start` from which the IR phase grows most
/// steadily outward along 64 rays of `length` samples: the middle of the
/// ring system, which the coarse vote finds only roughly.
fn refineCentre(allocator: std.mem.Allocator, band: []const f32, width: usize, height: usize, start: Centre, search: usize, length: usize) !Refined {
    var fft = try Fft.init(allocator, length);
    defer fft.deinit(allocator);
    const buffers = try allocator.alloc(f64, 3 * length);
    defer allocator.free(buffers);
    const re = buffers[0..length];
    const im = buffers[length .. 2 * length];
    const phase = buffers[2 * length ..];
    const Score = struct {
        fn of(f: *const Fft, b: []const f32, w: usize, h: usize, x: f64, y: f64, re_: []f64, im_: []f64, ph: []f64) f64 {
            var steady: usize = 0;
            var total: usize = 0;
            for (0..64) |k| {
                const angle = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / 64;
                for (re_, 0..) |*v, r| {
                    const rf: f64 = @floatFromInt(r);
                    v.* = bilinear(b, w, h, x + rf * @cos(angle), y + rf * @sin(angle));
                }
                analyticPhase(f, re_, im_, ph);
                var rising: usize = 0;
                for (6..ph.len - 1) |i| rising += @intFromBool(ph[i + 1] > ph[i]);
                const steps = ph.len - 7;
                // Either way round: the phase grows outward or inward.
                steady += @max(rising, steps - rising);
                total += steps;
            }
            return @as(f64, @floatFromInt(steady)) / @as(f64, @floatFromInt(total));
        }
    };
    var best = start;
    var best_score = Score.of(&fft, band, width, height, @floatFromInt(start.x), @floatFromInt(start.y), re, im, phase);
    const s: isize = @intCast(search);
    for ([_]isize{ 8, 4, 2, 1 }) |step| {
        const centre = best;
        const reach: isize = if (step == 8) s else 2 * step;
        var dy: isize = -reach;
        while (dy <= reach) : (dy += step) {
            var dx: isize = -reach;
            while (dx <= reach) : (dx += step) {
                const x = @as(isize, @intCast(centre.x)) + dx;
                const y = @as(isize, @intCast(centre.y)) + dy;
                if (x < 0 or y < 0 or x >= width or y >= height) continue;
                const score = Score.of(&fft, band, width, height, @floatFromInt(x), @floatFromInt(y), re, im, phase);
                if (score > best_score) {
                    best_score = score;
                    best = .{ .x = @intCast(x), .y = @intCast(y), .strength = 0 };
                }
            }
        }
    }
    return .{ .centre = best, .steadiness = best_score };
}

/// Multiplies `rgb`'s linear values by 10^removed, the grid's planes
/// interpolated onto its pixels.
fn applyToPixels(allocator: std.mem.Allocator, rgb: Image, removed: [3][]f32, at: Placement) !void {
    var gx0: usize = at.width;
    var gx1: usize = 0;
    var gy0: usize = at.height;
    var gy1: usize = 0;
    for (0..at.height) |y| {
        for (0..at.width) |x| {
            const i = y * at.width + x;
            if (removed[0][i] == 0 and removed[1][i] == 0 and removed[2][i] == 0) continue;
            gx0 = @min(gx0, x);
            gx1 = @max(gx1, x);
            gy0 = @min(gy0, y);
            gy1 = @max(gy1, y);
        }
    }
    if (gx1 < gx0) return;
    const f = at.factor;
    const Pass = struct {
        rgb: Image,
        removed: [3][]f32,
        at: Placement,
        px0: usize,
        px1: usize,
        py0: usize,

        fn rows(p: @This(), start: usize, end: usize) void {
            const factor: f64 = @floatFromInt(p.at.factor);
            const max_x: f64 = @floatFromInt(p.at.width - 1);
            const max_y: f64 = @floatFromInt(p.at.height - 1);
            for (p.py0 + start..p.py0 + end) |y| {
                const gy = std.math.clamp((@as(f64, @floatFromInt(y - p.at.y0)) + 0.5) / factor - 0.5, 0, max_y);
                for (p.px0..p.px1) |x| {
                    const gx = std.math.clamp((@as(f64, @floatFromInt(x - p.at.x0)) + 0.5) / factor - 0.5, 0, max_x);
                    const base = (y * p.rgb.width + x) * p.rgb.channels;
                    for (p.removed, 0..) |plane, c| {
                        const m = bilinear(plane, p.at.width, p.at.height, gx, gy);
                        if (m != 0) p.rgb.pixels[base + c] *= @exp(m * std.math.ln10);
                    }
                }
            }
        }
    };
    const py0 = at.y0 + gy0 * f;
    const py1 = @min(rgb.height, at.y0 + (gy1 + 1) * f);
    try parallelism.forRowBands(allocator, py1 - py0, Pass{
        .rgb = rgb,
        .removed = removed,
        .at = at,
        .px0 = at.x0 + gx0 * f,
        .px1 = @min(rgb.width, at.x0 + (gx1 + 1) * f),
        .py0 = py0,
    }, Pass.rows);
}

/// The colour rings about one centre, on rays out to the ray length: the
/// IR fringe phase along each ray, with every ray's fringe count matched to
/// its neighbours', and per channel a local least-squares fit of the
/// density to a level, a gradient, and a sinusoid of the centre's ratio
/// times that phase. The sinusoid counts where it explains well above
/// chance (the residual over the window's independent pixels), away from
/// picture edges, and at IR phases (gaps) where rings show round the whole
/// system.
const PolarFit = struct {
    rays: usize,
    length: usize,
    fft: Fft,
    re: []f64,
    im: []f64,
    /// Each ray's direction.
    ray_cos: []f64,
    ray_sin: []f64,
    /// Ray-major samples: IR phase, cos and sin of ratio times phase, the
    /// weight the subtraction takes (inside the frame, away from picture
    /// edges), and the one the fit takes (that, clear of IR defects and their
    /// shoulders too). The subtraction covers the defects from the fit about
    /// them: left alone, the rings by a speck stand out once the rest are
    /// gone.
    phase: []f64,
    cos: []f64,
    sin: []f64,
    weight: []f64,
    fit_weight: []f64,
    inside: []bool,
    /// Smoothed w b_i b_j over the basis b = (1, x, y, cos, sin), i <= j.
    shared: [basis_pairs][]f64,
    /// A channel's density less its picture, then its smoothed w b_i v and
    /// w v^2.
    value: []f64,
    sums: [basis_len + 1][]f64,
    a: []f64,
    b: []f64,
    gain: []f64,
    scratch: []f64,
    line: []f64,
    line_tmp: []f64,

    const basis_len = 5;
    const basis_pairs = basis_len * (basis_len + 1) / 2;

    fn init(allocator: std.mem.Allocator, length: usize) !PolarFit {
        const rays = std.math.ceilPowerOfTwoAssert(usize, @intFromFloat(@ceil(2 * std.math.pi * @as(f64, @floatFromInt(length)))));
        var self: PolarFit = undefined;
        self.rays = rays;
        self.length = length;
        self.fft = try Fft.init(allocator, length);
        errdefer self.fft.deinit(allocator);
        const n = rays * length;
        const owned = self.planes();
        for (owned) |plane| plane.* = &.{};
        errdefer for (owned) |plane| allocator.free(plane.*);
        for (owned) |plane| {
            const len = if (plane == &self.re or plane == &self.im)
                length
            else if (plane == &self.ray_cos or plane == &self.ray_sin)
                rays
            else
                n;
            plane.* = try allocator.alloc(f64, len);
        }
        self.line = try allocator.alloc(f64, @max(rays, length));
        errdefer allocator.free(self.line);
        self.line_tmp = try allocator.alloc(f64, @max(rays, length));
        errdefer allocator.free(self.line_tmp);
        for (self.ray_cos, self.ray_sin, 0..) |*c, *s, k| {
            const angle = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(rays));
            c.* = @cos(angle);
            s.* = @sin(angle);
        }
        self.inside = try allocator.alloc(bool, n);
        return self;
    }

    const fixed_planes = 14;

    fn planes(self: *PolarFit) [fixed_planes + basis_pairs + basis_len + 1]*[]f64 {
        var out: [fixed_planes + basis_pairs + basis_len + 1]*[]f64 = undefined;
        const fixed = [fixed_planes]*[]f64{ &self.re, &self.im, &self.ray_cos, &self.ray_sin, &self.phase, &self.cos, &self.sin, &self.weight, &self.fit_weight, &self.value, &self.a, &self.b, &self.gain, &self.scratch };
        @memcpy(out[0..fixed_planes], &fixed);
        for (&self.shared, 0..) |*plane, i| out[fixed_planes + i] = plane;
        for (&self.sums, 0..) |*plane, i| out[fixed_planes + basis_pairs + i] = plane;
        return out;
    }

    fn deinit(self: *PolarFit, allocator: std.mem.Allocator) void {
        self.fft.deinit(allocator);
        for (self.planes()) |plane| allocator.free(plane.*);
        allocator.free(self.line);
        allocator.free(self.line_tmp);
        allocator.free(self.inside);
    }

    /// The basis at sample `i`: level, offset from the centre in fit windows
    /// (for the gradient), and the ring sinusoid.
    fn basis(self: *const PolarFit, i: usize, sigma: f64) [basis_len]f64 {
        const r: f64 = @floatFromInt(i % self.length);
        const k = i / self.length;
        return .{ 1, r * self.ray_cos[k] / sigma, r * self.ray_sin[k] / sigma, self.cos[i], self.sin[i] };
    }

    /// Fits the rings about `centre` in each of `densities`, at `ratio`
    /// colour cycles per IR fringe, subtracts them, and adds them to
    /// `removed`. `defects` (1 near IR defects) stay out of the fit.
    fn subtract(
        self: *PolarFit,
        allocator: std.mem.Allocator,
        densities: [3][]f32,
        ir: []const f32,
        edge: []const f32,
        defects: []const f32,
        width: usize,
        height: usize,
        centre: Centre,
        ratio: f64,
        sizes: FitSizes,
        removed: [3][]f32,
    ) !void {
        const rays = self.rays;
        const length = self.length;
        const n = rays * length;
        const cx: f64 = @floatFromInt(centre.x);
        const cy: f64 = @floatFromInt(centre.y);
        const max_x: f64 = @floatFromInt(width - 1);
        const max_y: f64 = @floatFromInt(height - 1);
        const flip_at = sizes.flip_at;
        const sigma = sizes.fit_sigma;

        // The IR fringe phase along each ray, growing outward.
        for (0..rays) |k| {
            const row = k * length;
            for (0..length) |r| {
                const rf: f64 = @floatFromInt(r);
                const x = cx + rf * self.ray_cos[k];
                const y = cy + rf * self.ray_sin[k];
                const in_frame = x >= 0 and y >= 0 and x <= max_x and y <= max_y;
                self.re[r] = bilinear(ir, width, height, x, y);
                self.inside[row + r] = in_frame;
                self.weight[row + r] = if (in_frame) bilinear(edge, width, height, x, y) else 0;
                self.fit_weight[row + r] = if (bilinear(defects, width, height, x, y) < 0.5) self.weight[row + r] else 0;
            }
            const phase = self.phase[row..][0..length];
            analyticPhase(&self.fft, self.re, self.im, phase);
            if (phase[flip_at] - phase[sizes.ray_start] + 1e-12 < 0) {
                for (phase) |*p| p.* = -p.*;
            }
        }
        // Each ray's fringe count matched to its neighbour's at ring_ref.
        {
            var previous = self.phase[sizes.ring_ref];
            var correction: f64 = 0;
            for (1..rays) |k| {
                const raw = self.phase[k * length + sizes.ring_ref];
                const step = raw - previous;
                if (@abs(step) >= std.math.pi) {
                    var wrapped = @mod(step + std.math.pi, 2 * std.math.pi) - std.math.pi;
                    if (wrapped == -std.math.pi and step > 0) wrapped = std.math.pi;
                    correction += wrapped - step;
                }
                previous = raw;
                if (correction != 0) {
                    for (self.phase[k * length ..][0..length]) |*p| p.* += correction;
                }
            }
        }
        for (self.phase, self.cos, self.sin) |p, *c, *s| {
            c.* = @cos(ratio * p);
            s.* = @sin(ratio * p);
        }

        // Smoothed products of the basis the channels share.
        {
            var pair: usize = 0;
            for (0..basis_len) |bi| {
                for (bi..basis_len) |bj| {
                    for (self.scratch, 0..) |*out, i| {
                        const base = self.basis(i, sigma);
                        out.* = self.fit_weight[i] * base[bi] * base[bj];
                    }
                    self.smooth(self.scratch, self.shared[pair], sigma);
                    pair += 1;
                }
            }
        }

        const n_eff_full = 2 * std.math.pi * sigma * sigma / corr_area;
        for (densities, removed) |density_plane, rem| {
            // The channel along the rays, and its smoothed products.
            for (0..rays) |k| {
                for (0..length) |r| {
                    const rf: f64 = @floatFromInt(r);
                    self.value[k * length + r] = bilinear(density_plane, width, height, cx + rf * self.ray_cos[k], cy + rf * self.ray_sin[k]);
                }
            }
            for (0..basis_len + 1) |j| {
                for (self.scratch, 0..) |*out, i| {
                    const v = self.value[i];
                    out.* = self.fit_weight[i] * v * (if (j < basis_len) self.basis(i, sigma)[j] else v);
                }
                self.smooth(self.scratch, self.sums[j], sigma);
            }
            // Local fit: the picture's level and gradient, a cos + b sin,
            // and how far above chance.
            for (0..n) |i| {
                var m: [basis_len][basis_len]f64 = undefined;
                var pair: usize = 0;
                for (0..basis_len) |bi| {
                    for (bi..basis_len) |bj| {
                        m[bi][bj] = self.shared[pair][i];
                        m[bj][bi] = self.shared[pair][i];
                        pair += 1;
                    }
                    m[bi][bi] += 1e-9;
                }
                var rhs: [basis_len]f64 = undefined;
                for (&rhs, 0..) |*v, j| v.* = self.sums[j][i];
                const x = solveSmall(basis_len, m, rhs);
                var explained: f64 = 0;
                for (x, rhs) |xj, bj| explained += xj * bj;
                const s1 = self.shared[0][i];
                const resid = @max(self.sums[basis_len][i] - explained, 0) / @max(s1, 1e-12);
                // Fewer independent pixels where the window is mostly off the
                // frame or on edges.
                const n_eff = n_eff_full * std.math.clamp(s1, 1e-3, 1);
                const amp2 = 0.25 * (x[3] * x[3] + x[4] * x[4]);
                const base = self.basis(i, sigma);
                self.a[i] = x[3];
                self.b[i] = x[4];
                self.gain[i] = std.math.clamp(1 - sizes.local_k * (resid / n_eff) / (amp2 + 1e-30), 0, 1);
                self.value[i] -= x[0] + x[1] * base[1] + x[2] * base[2];
            }
            const zone = try self.ringZone(allocator);
            defer allocator.free(zone.bins);
            for (0..n) |i| {
                const bin = zone.bin(self.phase[i]);
                self.value[i] = (self.a[i] * self.cos[i] + self.b[i] * self.sin[i]) * self.gain[i] * zone.bins[bin] * self.weight[i];
            }
            self.toGrid(self.value, centre, width, height, sizes, density_plane, rem);
        }
    }

    const Zone = struct {
        lo: f64,
        bins: []f64,

        fn bin(self: Zone, phase: f64) usize {
            const at = @floor((phase - self.lo) / bin_width);
            return @intFromFloat(std.math.clamp(at, 0, @as(f64, @floatFromInt(self.bins.len - 1))));
        }
    };

    /// Per IR phase bin, 1 where the channel's rings show round the whole
    /// system (fitted on `value`, the channel less its level), out to
    /// `zone_margin` fringes beyond, else 0, softened at the edges.
    fn ringZone(self: *PolarFit, allocator: std.mem.Allocator) !Zone {
        var lo: f64 = std.math.inf(f64);
        var hi: f64 = -std.math.inf(f64);
        for (self.phase, self.inside) |p, in| {
            if (!in) continue;
            lo = @min(lo, p);
            hi = @max(hi, p);
        }
        if (!(hi >= lo)) return .{ .lo = 0, .bins = try allocator.dupe(f64, &.{0}) };
        const count: usize = @as(usize, @intFromFloat(@ceil((hi - lo) / bin_width))) + 1;
        var sums: [7][]f64 = undefined;
        var made: usize = 0;
        defer for (sums[0..made]) |plane| allocator.free(plane);
        for (&sums) |*plane| {
            plane.* = try allocator.alloc(f64, count);
            @memset(plane.*, 0);
            made += 1;
        }
        const zone = Zone{ .lo = lo, .bins = try allocator.alloc(f64, count) };
        errdefer allocator.free(zone.bins);
        const per_ray = 2 * std.math.pi / @as(f64, @floatFromInt(self.rays));
        for (0..self.rays * self.length) |i| {
            const w = self.fit_weight[i];
            if (w == 0) continue;
            const r: f64 = @floatFromInt(i % self.length);
            const wa = w * @max(r, 0.5) * per_ray;
            const c = self.cos[i];
            const s = self.sin[i];
            const u = self.value[i];
            const b = zone.bin(self.phase[i]);
            sums[0][b] += wa;
            sums[1][b] += wa * c * c;
            sums[2][b] += wa * s * s;
            sums[3][b] += wa * c * s;
            sums[4][b] += wa * u * c;
            sums[5][b] += wa * u * s;
            sums[6][b] += wa * u * u;
        }
        const smoothed = try allocator.alloc(f64, count);
        defer allocator.free(smoothed);
        for (sums) |plane| {
            gaussian1d(plane, bin_sigma, smoothed);
            @memcpy(plane, smoothed);
        }
        const eff_bins = 2 * @sqrt(std.math.pi) * bin_sigma;
        for (zone.bins, 0..) |*shows, b| {
            const det = sums[1][b] * sums[2][b] - sums[3][b] * sums[3][b] + 1e-30;
            const a = (sums[4][b] * sums[2][b] - sums[5][b] * sums[3][b]) / det;
            const c = (sums[5][b] * sums[1][b] - sums[4][b] * sums[3][b]) / det;
            const resid = @max(sums[6][b] - (a * sums[4][b] + c * sums[5][b]), 0) / @max(sums[0][b], 1e-12);
            const chance = resid / @max(sums[0][b] * eff_bins / corr_area, 1);
            const presence = std.math.clamp(1 - presence_k * chance / (0.25 * (a * a + c * c) + 1e-30), 0, 1);
            shows.* = if (presence > 0.05) 1 else 0;
        }
        // Out to the margin, then softened.
        const reach: usize = @intFromFloat(zone_margin * 2 * std.math.pi / bin_width);
        for (zone.bins, 0..) |_, b| {
            var any: f64 = 0;
            for (b -| reach..@min(count, b + reach + 1)) |j| any = @max(any, zone.bins[j]);
            smoothed[b] = any;
        }
        gaussian1d(smoothed, 2.0, zone.bins);
        return zone;
    }

    /// Box-cascade smoothing of a ray-major plane: `sigma` samples along each
    /// ray (mirrored at its ends) and `sigma` pixels of arc across rays
    /// (wrapping round), so wider in angle near the centre.
    fn smooth(self: *PolarFit, src: []const f64, dst: []f64, sigma: f64) void {
        const length = self.length;
        const rays = self.rays;
        const along = boxRadii(sigma);
        for (0..rays) |k| {
            boxLine(src[k * length ..][0..length], dst[k * length ..][0..length], self.line_tmp[0..length], along, false);
        }
        const line = self.line[0..rays];
        const tmp = self.line_tmp[0..rays];
        for (0..length) |r| {
            for (line, 0..) |*v, k| v.* = dst[k * length + r];
            const arc = sigma * @as(f64, @floatFromInt(rays)) / (2 * std.math.pi * @max(@as(f64, @floatFromInt(r)), 1));
            boxLine(line, line, tmp, boxRadii(@min(arc, @as(f64, @floatFromInt(rays)))), true);
            for (line, 0..) |v, k| dst[k * length + r] = v;
        }
    }

    /// Subtracts the polar model from the grid plane `target` and adds it to
    /// `removed`, fading to nothing at the rays' ends.
    fn toGrid(self: *PolarFit, model: []const f64, centre: Centre, width: usize, height: usize, sizes: FitSizes, target: []f32, removed: []f32) void {
        const length = self.length;
        const rays = self.rays;
        const reach = @min(@as(f64, @floatFromInt(length - 1)), sizes.reach);
        const cx: f64 = @floatFromInt(centre.x);
        const cy: f64 = @floatFromInt(centre.y);
        const y_start = centre.y -| length;
        const y_end = @min(height, centre.y + length + 1);
        const x_start = centre.x -| length;
        const x_end = @min(width, centre.x + length + 1);
        const per_ray = @as(f64, @floatFromInt(rays)) / (2 * std.math.pi);
        for (y_start..y_end) |y| {
            for (x_start..x_end) |x| {
                const dx = @as(f64, @floatFromInt(x)) - cx;
                const dy = @as(f64, @floatFromInt(y)) - cy;
                const r = @sqrt(dx * dx + dy * dy);
                if (r >= reach) continue;
                var theta = std.math.atan2(dy, dx);
                if (theta < 0) theta += 2 * std.math.pi;
                const t = theta * per_ray;
                const k0: usize = @as(usize, @intFromFloat(@floor(t))) % rays;
                const k1 = (k0 + 1) % rays;
                const ft = t - @floor(t);
                const r0: usize = @intFromFloat(@floor(r));
                const r1 = @min(r0 + 1, length - 1);
                const fr = r - @floor(r);
                const near = (1 - fr) * model[k0 * length + r0] + fr * model[k0 * length + r1];
                const far = (1 - fr) * model[k1 * length + r0] + fr * model[k1 * length + r1];
                const fade = std.math.clamp((reach - r) / sizes.taper, 0, 1);
                const m: f32 = @floatCast(((1 - ft) * near + ft * far) * fade);
                target[y * width + x] -= m;
                removed[y * width + x] += m;
            }
        }
    }
};

/// Three running-sum box passes along a line, mirrored at its ends or
/// wrapping round; `dst` may be `src`.
fn boxLine(src: []const f64, dst: []f64, tmp: []f64, radii: [3]usize, wrap: bool) void {
    boxLinePass(src, tmp, radii[0], wrap);
    boxLinePass(tmp, dst, radii[1], wrap);
    boxLinePass(dst, tmp, radii[2], wrap);
    @memcpy(dst, tmp);
}

fn boxLinePass(src: []const f64, dst: []f64, radius: usize, wrap: bool) void {
    const n = src.len;
    const r: isize = @intCast(if (wrap) @min(radius, (n - 1) / 2) else radius);
    if (r == 0) {
        @memcpy(dst, src);
        return;
    }
    const index = struct {
        fn at(i: isize, len: usize, around: bool) usize {
            return if (around) @intCast(@mod(i, @as(isize, @intCast(len)))) else mirror(i, len);
        }
    }.at;
    var sum: f64 = 0;
    var k: isize = -r;
    while (k <= r) : (k += 1) sum += src[index(k, n, wrap)];
    const scale = 1.0 / @as(f64, @floatFromInt(2 * r + 1));
    for (0..n) |x| {
        dst[x] = sum * scale;
        const xi: isize = @intCast(x);
        sum += src[index(xi + r + 1, n, wrap)] - src[index(xi - r, n, wrap)];
    }
}

/// A Gaussian of `sigma` samples along a short line, mirrored at its ends.
fn gaussian1d(src: []const f64, sigma: f64, dst: []f64) void {
    const radius: isize = @intFromFloat(4 * sigma + 0.5);
    for (dst, 0..) |*out, i| {
        var sum: f64 = 0;
        var total: f64 = 0;
        var k: isize = -radius;
        while (k <= radius) : (k += 1) {
            const kf: f64 = @floatFromInt(k);
            const w = @exp(-0.5 * kf * kf / (sigma * sigma));
            sum += w * src[mirror(@as(isize, @intCast(i)) + k, src.len)];
            total += w;
        }
        out.* = sum / total;
    }
}

/// Gaussian elimination with partial pivoting; zeros for a singular system.
fn solveSmall(comptime n: usize, matrix: [n][n]f64, rhs: [n]f64) [n]f64 {
    var m = matrix;
    var v = rhs;
    for (0..n) |col| {
        var pivot = col;
        for (col + 1..n) |row| {
            if (@abs(m[row][col]) > @abs(m[pivot][col])) pivot = row;
        }
        if (@abs(m[pivot][col]) < 1e-300) return [_]f64{0} ** n;
        std.mem.swap([n]f64, &m[col], &m[pivot]);
        std.mem.swap(f64, &v[col], &v[pivot]);
        for (col + 1..n) |row| {
            const f = m[row][col] / m[col][col];
            for (col..n) |k| m[row][k] -= f * m[col][k];
            v[row] -= f * v[col];
        }
    }
    var x: [n]f64 = undefined;
    var row = n;
    while (row > 0) {
        row -= 1;
        var sum = v[row];
        for (row + 1..n) |k| sum -= m[row][k] * x[k];
        x[row] = sum / m[row][row];
    }
    return x;
}

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

test "exports reduce Newton's rings unless the setting is off" {
    try std.testing.expect(reduceForConfig(&.{}));
    try std.testing.expect(!reduceForConfig(&.{.{ .name = "reduce_newton_rings", .value = .{ .boolean = false } }}));
    try std.testing.expect(reduceForConfig(&.{.{ .name = "reduce_newton_rings", .value = .{ .boolean = true } }}));
}

test "line smoothing keeps a constant and its total, mirrored or wrapped" {
    var src: [40]f64 = undefined;
    var dst: [40]f64 = undefined;
    var tmp: [40]f64 = undefined;
    for (&src) |*v| v.* = 2.5;
    boxLine(&src, &dst, &tmp, .{ 3, 3, 4 }, false);
    for (dst) |v| try std.testing.expectApproxEqAbs(@as(f64, 2.5), v, 1e-12);
    @memset(&src, 0);
    src[0] = 1;
    boxLine(&src, &dst, &tmp, .{ 3, 3, 4 }, true);
    var total: f64 = 0;
    for (dst) |v| total += v;
    try std.testing.expectApproxEqAbs(@as(f64, 1), total, 1e-12);
    try std.testing.expectApproxEqAbs(dst[1], dst[39], 1e-12);
}

test "the small solve inverts a system" {
    const x = solveSmall(3, .{ .{ 0, 1, 2 }, .{ 4, 1, 0 }, .{ 1, 3, 1 } }, .{ 8, 6, 10 });
    for (x, [_]f64{ 1, 2, 3 }) |got, want| try std.testing.expectApproxEqAbs(want, got, 1e-12);
}

test "the removal runs end to end: synthetic colour rings fade, IR-only rings and far pixels stay" {
    // Plumbing only; the removal is tuned and judged on real scans.
    const allocator = std.testing.allocator;
    for ([_]bool{ true, false }) |visible| {
        const all = try syntheticFrame(allocator, visible);
        defer allocator.free(all);
        const rgb = try allocator.alloc(f64, 400 * 400 * 3);
        defer allocator.free(rgb);
        const ir = try allocator.alloc(f64, 400 * 400);
        defer allocator.free(ir);
        for (0..400 * 400) |i| {
            for (0..3) |c| rgb[i * 3 + c] = @floatFromInt(all[i * 4 + c]);
            ir[i] = @floatFromInt(all[i * 4 + 3]);
        }
        const before = try allocator.dupe(f64, rgb);
        defer allocator.free(before);
        const score = try reduceRings(allocator, .{ .pixels = rgb, .width = 400, .height = 400, .channels = 3 }, .{ .pixels = ir, .width = 400, .height = 400, .channels = 1 }, .{ .cx = 200, .cy = 200, .w = 400, .h = 400 }, 1067);
        // A corner, past every ray.
        try std.testing.expectEqual(before[(399 * 400 + 399) * 3], rgb[(399 * 400 + 399) * 3]);
        if (!visible) {
            try std.testing.expect(!warns(score));
            try std.testing.expectEqualSlices(f64, before, rgb);
            continue;
        }
        // Red-minus-green density about the ring centre, before and after.
        var ring_before: f64 = 0;
        var ring_after: f64 = 0;
        for (130..290) |y| {
            for (100..280) |x| {
                const i = (y * 400 + x) * 3;
                const rg_before = @log10(before[i + 1] / 28000) - @log10(before[i] / 30000);
                const rg_after = @log10(rgb[i + 1] / 28000) - @log10(rgb[i] / 30000);
                ring_before += rg_before * rg_before;
                ring_after += rg_after * rg_after;
            }
        }
        try std.testing.expect(ring_after < 0.5 * ring_before);
    }
}

test "sizes in millimetres land on the pixel sizes tuned at 6400 dpi" {
    const p = Params.init(6400.0 / 6.0 / 25.4);
    try std.testing.expectEqualSlices(usize, &.{ 20, 30, 44, 64, 92, 132, 190 }, &p.radii);
    try std.testing.expectEqual(@as(usize, 83), p.peak_window);
    try std.testing.expectEqual(@as(usize, 256), p.ray_length);
    try std.testing.expectEqual(@as(usize, 80), p.window);
    try std.testing.expectEqual(@as(usize, 12), p.ray_start);
    try std.testing.expectEqual(@as(usize, 40), p.ring_ref);
    try std.testing.expectApproxEqAbs(@as(f64, 60), p.broad, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 12), p.fit_sigma, 0.05);
    const e = EdgeSizes.init(p.px_per_mm);
    try std.testing.expectEqual(@as(usize, 12), e.grow);
    try std.testing.expectApproxEqAbs(@as(f64, 0.016), e.tau, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), e.blur, 0.01);
    try std.testing.expectEqual(@as(usize, 2), e.defect_grow);
    try std.testing.expectEqual(@as(usize, 2), e.defect_reach);
    const f = FitSizes.fine(3200.0 / 25.4);
    try std.testing.expectEqual(@as(usize, 256), f.ray_length);
    try std.testing.expectEqual(@as(usize, 12), f.ray_start);
    try std.testing.expectEqual(@as(usize, 120), f.flip_at);
    try std.testing.expectEqual(@as(usize, 38), f.ring_ref);
}
