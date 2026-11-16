//! Colour contrast within colour families, in Oklab. A frame's chromatic
//! colours are fitted as up to twelve families (peaks of its a,b
//! histogram); each family's colours gain chroma along their own hue, are
//! pulled toward the family's centre in hue and chroma (cohesion), and
//! inside a small core about the moved centre their chroma differences grow
//! (local gain), keeping the hue and lightness the earlier steps gave.
//! Greys stay neutral. Out-of-gamut results lose chroma at
//! constant lightness until they fit.
//!
//! The filter's math follows the browser prototype the fixtures in
//! test/fixtures/processing/chroma came from; its fit does not. The model is fitted once per
//! image and shared by every pixel, so tiles and threads need no halos.
//! `Filter.applyLinear` is the f32 path the render uses, eight pixels at a
//! time; the tests hold it to an f64 version of the same math.
//!
//! The families are fitted on a small copy of the image, smoothed so that
//! colours average within objects but not across their edges, each colour
//! counted by its chroma and by how far it lies from its surroundings, and
//! lone specks not at all: they sit on the frame's colourful objects, not
//! its near-grey general tones.
//!
//! Nothing here allocates: `Fit` (1.9 MB) and `Filter` (235 KB) are filled
//! in place, in memory the caller owns.

const std = @import("std");

const rgb_space = @import("rgb_space.zig");

pub const Settings = struct {
    /// How far each colour's hue is pulled toward its family's centre, 0 to 1.
    hue: f64 = 0.70,
    /// How far its chroma is pulled toward the centre's, 0 to 1.
    chroma: f64 = 0.55,
    /// How much each family's colours gain chroma, along their own hue, as a
    /// share of it, 0 to 0.8.
    boost: f64 = 0.30,
    /// Largest core radius, in Oklab a,b: the shades whose chroma
    /// differences grow, 0 to 0.08.
    radius: f64 = 0.025,
    /// How much chroma differences grow at a core's middle, 0 to 0.5.
    gain: f64 = 0.40,
    /// The most colour families to fit, 1 to 12: the tallest are kept.
    families: usize = max_families,
    /// The colourfulness the boost aims for, 0 to 0.15: the 90th percentile
    /// of the frame's chroma after the filter. With a target, `boost` is the
    /// most a frame gets: a muted frame gets up to it, one already as
    /// colourful none. 0 always boosts by `boost`.
    target: f64 = 0.0,

    pub const max = Settings{ .hue = 1.0, .chroma = 1.0, .boost = 0.8, .radius = 0.08, .gain = 0.5, .target = 0.15 };

    pub fn validate(self: Settings) !void {
        inline for (.{ "hue", "chroma", "boost", "radius", "gain", "target" }) |name| {
            const value = @field(self, name);
            if (!std.math.isFinite(value) or value < 0.0 or value > @field(max, name)) return error.InvalidChromaSetting;
        }
        if (self.families < 1 or self.families > max_families) return error.InvalidChromaSetting;
    }

    pub fn eql(self: Settings, other: Settings) bool {
        return self.hue == other.hue and self.chroma == other.chroma and self.boost == other.boost and
            self.radius == other.radius and self.gain == other.gain and self.families == other.families and
            self.target == other.target;
    }

    fn isIdentity(self: Settings) bool {
        return self.hue == 0.0 and self.chroma == 0.0 and self.boost == 0.0 and (self.gain == 0.0 or self.radius == 0.0);
    }
};

pub const max_families = 12;

/// The field's grid over a,b.
const grid_size = 121;
const grid_half = 60;
const grid_step: f64 = 0.006;
const grid_bins = grid_size * grid_size;
// Chroma below neutral_lo counts as neutral; families and the field fade in
// up to neutral_hi.
const neutral_lo: f64 = 0.015;
const neutral_hi: f64 = 0.055;
const gate_hi: f64 = 0.021;
// Greys stay neutral: the pull and the boost fade in with a colour's own
// chroma, from nothing at neutral_lo to full at protect_hi.
const protect_hi: f64 = 0.04;
const field_sigma: f64 = 0.044;

/// The longest side of the image the families are fitted on.
pub const fit_side = 256;
// Edge-preserving smoothing of the fitting image: each pixel's a,b becomes
// the mean of its 7 x 7 neighbours weighted by how close they are in
// Oklab, three times over, so grain and texture average out within an
// object but not across its edges.
const smooth_radius = 3;
const smooth_passes = 3;
const smooth_range: f32 = 0.03;
// The families' histogram over a,b, and its Gaussian smoothing.
const hist_size = 201;
const hist_half = 100;
const hist_step: f64 = 0.003;
const hist_bins = hist_size * hist_size;
const peak_sigma: f64 = 0.012;
const peak_radius = 12; // bins: 3 sigma / step
const peak_min_chroma: f64 = 0.034;
// A family's peak must reach this share of the tallest: low enough for a
// small, vivid object (fireweed flowers on a hillside came to 0.015).
const peak_min_share: f32 = 0.01;
// Colours count by the square of their chroma, so families sit on the
// colourful objects in a frame rather than its near-grey general tones,
// plus the square of how far they lie from their surround's colour, so a
// small object unlike its setting (brown hair against rock, lake and sky)
// counts as much as a vivid one.
const chroma_weight_power = 2;
const chroma_weight_scale: f32 = 0.05;
const surround_scale: f32 = 0.03;

pub const Family = struct { a: f64, b: f64, height: f64 };

pub const Model = struct {
    families: [max_families]Family = undefined,
    count: usize = 0,

    pub fn slice(self: *const Model) []const Family {
        return self.families[0..self.count];
    }
};

/// The size of the fitting image for an image of `width` x `height`: the
/// same shape, its longest side at most `fit_side`. An image with no known
/// width (one row) keeps up to `row_samples` samples, unsmoothed.
pub fn fitSize(width: usize, height: usize) [2]usize {
    if (height <= 1) return .{ @max(1, @min(width, row_samples)), 1 };
    const longest = @max(width, height);
    if (longest <= fit_side) return .{ width, height };
    return .{
        @max(1, width * fit_side / longest),
        @max(1, height * fit_side / longest),
    };
}

const row_samples = 8192;
// The fitting image is kept by channel, each plane with a border of
// `pad` repeated edge pixels and rows long enough for whole vectors.
const pad = smooth_radius;
const max_stride = fit_side + 2 * pad + 2 * lanes;
const plane_size = max_stride * (fit_side + 2 * pad);

/// A small copy of the image, in Oklab, from which `model` finds the colour
/// families.
pub const Fit = struct {
    width: usize,
    height: usize,
    stride: usize,
    l: [plane_size]f32,
    a: [plane_size]f32,
    b: [plane_size]f32,
    // Scratch: the smoothing's output, then each pixel's support and its
    // contrast with its surround.
    next_a: [plane_size]f32,
    next_b: [plane_size]f32,
    spare: [plane_size]f32,
    bins: [hist_bins]f32,

    /// Starts an image of `size` (from `fitSize`); fill it with `set`.
    pub fn begin(self: *Fit, size: [2]usize) void {
        self.width = size[0];
        self.height = size[1];
        self.stride = std.mem.alignForward(usize, size[0] + 2 * pad, lanes) + lanes;
    }

    pub fn set(self: *Fit, x: usize, y: usize, lab: [3]f32) void {
        const i = self.index(x, y);
        self.l[i] = lab[0];
        self.a[i] = lab[1];
        self.b[i] = lab[2];
    }

    pub fn index(self: *const Fit, x: usize, y: usize) usize {
        return (y + pad) * self.stride + x + pad;
    }

    /// The colour families: local maxima of a smoothed, chroma-weighted
    /// histogram of the smoothed image's a,b, tallest first, apart from
    /// each other. Overwrites the image.
    pub fn model(self: *Fit) Model {
        const spatial = self.height > 1 and self.width > 1;
        if (spatial) {
            for (0..smooth_passes) |_| self.smooth();
            self.measureSupport();
            self.measureSurround();
        }
        @memset(&self.bins, 0.0);
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const i = self.index(x, y);
                const a = self.a[i];
                const b = self.b[i];
                const c = @sqrt(a * a + b * b);
                const t = std.math.clamp((c - @as(f32, @floatCast(neutral_lo))) / @as(f32, @floatCast(neutral_hi - neutral_lo)), 0.0, 1.0);
                const support: f32 = if (spatial) self.next_a[i] else 1.0;
                const contrast: f32 = if (spatial) self.next_b[i] / surround_scale else 0.0;
                const colourful = std.math.pow(f32, c / chroma_weight_scale, chroma_weight_power) + contrast * contrast;
                const weight = support * t * t * (3.0 - 2.0 * t) * colourful;
                self.bins[histBin(b) * hist_size + histBin(a)] += weight;
            }
        }
        var kernel: [2 * peak_radius + 1]f32 = undefined;
        for (&kernel, 0..) |*k, i| {
            const offset = (@as(f64, @floatFromInt(i)) - peak_radius) * hist_step / peak_sigma;
            k.* = @floatCast(@exp(-0.5 * offset * offset));
        }
        // Separable Gaussian, truncated at the grid's edges.
        var line: [hist_size]f32 = undefined;
        for (0..hist_size) |y| {
            const row = self.bins[y * hist_size ..][0..hist_size];
            smoothLine(&kernel, row, 1, &line);
            @memcpy(row, &line);
        }
        for (0..hist_size) |x| {
            smoothLine(&kernel, self.bins[x..], hist_size, &line);
            for (line, 0..) |value, y| self.bins[y * hist_size + x] = value;
        }

        var result = Model{};
        var candidates: [hist_bins]u16 = undefined;
        var count: usize = 0;
        for (1..hist_size - 1) |y| {
            for (1..hist_size - 1) |x| {
                const p = y * hist_size + x;
                const h = self.bins[p];
                const a = histCoordinate(x);
                const b = histCoordinate(y);
                if (!(h > 0.0) or @sqrt(a * a + b * b) < peak_min_chroma) continue;
                const maximum = for ([_]usize{ p - hist_size, p, p + hist_size }) |q| {
                    if (self.bins[q - 1] > h or self.bins[q] > h or self.bins[q + 1] > h) break false;
                } else true;
                if (maximum) {
                    candidates[count] = @intCast(p);
                    count += 1;
                }
            }
        }
        if (count == 0) return result;
        // Stable: equal heights keep scan order.
        std.mem.sort(u16, candidates[0..count], &self.bins, tallerFirst);
        const tallest = self.bins[candidates[0]];
        for (candidates[0..count]) |p| {
            const h = self.bins[p];
            if (result.count >= max_families or h < peak_min_share * tallest) break;
            const a = histCoordinate(p % hist_size);
            const b = histCoordinate(p / hist_size);
            const apart = for (result.slice()) |family| {
                const da = a - family.a;
                const db = b - family.b;
                if (!(@sqrt(da * da + db * db) > 1.6 * peak_sigma)) break false;
            } else true;
            if (apart) {
                result.families[result.count] = .{ .a = a, .b = b, .height = h };
                result.count += 1;
            }
        }
        return result;
    }

    /// How far each pixel's a,b lies from its surround's (a box mean
    /// reaching a tenth of the image's long side each way), into `next_b`:
    /// small objects unlike their setting stand out, where a broad cast
    /// matches its own surround. Uses `l`, no longer needed, and `spare`.
    fn measureSurround(self: *Fit) void {
        const width = self.width;
        const height = self.height;
        const reach = @max(1, @max(width, height) / 10);
        // Along each row: the box means of a into `l`, of b into `spare`.
        for (0..height) |y| {
            const row = self.index(0, y);
            var sum_a: f32 = 0.0;
            var sum_b: f32 = 0.0;
            var lo: usize = 0;
            var hi: usize = 0; // the box is [lo, hi)
            for (0..width) |x| {
                while (hi < @min(width, x + reach + 1)) : (hi += 1) {
                    sum_a += self.a[row + hi];
                    sum_b += self.b[row + hi];
                }
                while (lo < x -| reach) : (lo += 1) {
                    sum_a -= self.a[row + lo];
                    sum_b -= self.b[row + lo];
                }
                const count: f32 = @floatFromInt(hi - lo);
                self.l[row + x] = sum_a / count;
                self.spare[row + x] = sum_b / count;
            }
        }
        // Down each column, then the distance from the surround.
        for (0..width) |x| {
            var sum_a: f32 = 0.0;
            var sum_b: f32 = 0.0;
            var lo: usize = 0;
            var hi: usize = 0;
            for (0..height) |y| {
                while (hi < @min(height, y + reach + 1)) : (hi += 1) {
                    sum_a += self.l[self.index(x, hi)];
                    sum_b += self.spare[self.index(x, hi)];
                }
                while (lo < y -| reach) : (lo += 1) {
                    sum_a -= self.l[self.index(x, lo)];
                    sum_b -= self.spare[self.index(x, lo)];
                }
                const count: f32 = @floatFromInt(hi - lo);
                const i = self.index(x, y);
                const da = self.a[i] - sum_a / count;
                const db = self.b[i] - sum_b / count;
                self.next_b[i] = @sqrt(da * da + db * db);
            }
        }
    }

    /// Repeats the edge pixels into the border.
    fn padEdges(self: *Fit) void {
        for ([_]*[plane_size]f32{ &self.l, &self.a, &self.b }) |plane| {
            for (0..self.height) |y| {
                const row = plane[(y + pad) * self.stride ..][0..self.stride];
                @memset(row[0..pad], row[pad]);
                @memset(row[pad + self.width ..], row[pad + self.width - 1]);
            }
            const first = plane[pad * self.stride ..][0..self.stride];
            const last = plane[(self.height - 1 + pad) * self.stride ..][0..self.stride];
            for (0..pad) |y| {
                @memcpy(plane[y * self.stride ..][0..self.stride], first);
                @memcpy(plane[(self.height + pad + y) * self.stride ..][0..self.stride], last);
            }
        }
    }

    /// One pass of the edge-preserving smoothing, a vector of pixels at a
    /// time: each a,b becomes its neighbours' mean, weighted by closeness
    /// in Oklab.
    fn smooth(self: *Fit) void {
        self.padEdges();
        const stride: isize = @intCast(self.stride);
        for (0..self.height) |y| {
            var x: usize = 0;
            while (x < self.width) : (x += lanes) {
                const centre = self.index(x, y);
                const cl: V = self.l[centre..][0..lanes].*;
                const ca: V = self.a[centre..][0..lanes].*;
                const cb: V = self.b[centre..][0..lanes].*;
                var sum_a = sv(0.0);
                var sum_b = sv(0.0);
                var sum_w = sv(0.0);
                var dy: isize = -smooth_radius;
                while (dy <= smooth_radius) : (dy += 1) {
                    var dx: isize = -smooth_radius;
                    while (dx <= smooth_radius) : (dx += 1) {
                        const o: usize = @intCast(@as(isize, @intCast(centre)) + dy * stride + dx);
                        const ol: V = self.l[o..][0..lanes].*;
                        const oa: V = self.a[o..][0..lanes].*;
                        const ob: V = self.b[o..][0..lanes].*;
                        const w = rangeWeight((ol - cl) * (ol - cl) + (oa - ca) * (oa - ca) + (ob - cb) * (ob - cb));
                        sum_a += w * oa;
                        sum_b += w * ob;
                        sum_w += w;
                    }
                }
                self.next_a[centre..][0..lanes].* = sum_a / sum_w;
                self.next_b[centre..][0..lanes].* = sum_b / sum_w;
            }
        }
        for (0..self.height) |y| {
            const row = self.index(0, y);
            @memcpy(self.a[row..][0..self.width], self.next_a[row..][0..self.width]);
            @memcpy(self.b[row..][0..self.width], self.next_b[row..][0..self.width]);
        }
    }

    /// Whether each pixel belongs to a patch of its colour (a,b within about
    /// the smoothing's range) at least 2 x 2 pixels across: 0 for a lone
    /// speck, 1 from about four like pixels in its 3 x 3 neighbourhood,
    /// into `next_a`.
    fn measureSupport(self: *Fit) void {
        self.padEdges();
        const stride: isize = @intCast(self.stride);
        for (0..self.height) |y| {
            var x: usize = 0;
            while (x < self.width) : (x += lanes) {
                const centre = self.index(x, y);
                const ca: V = self.a[centre..][0..lanes].*;
                const cb: V = self.b[centre..][0..lanes].*;
                var sum = sv(0.0);
                var dy: isize = -1;
                while (dy <= 1) : (dy += 1) {
                    var dx: isize = -1;
                    while (dx <= 1) : (dx += 1) {
                        const o: usize = @intCast(@as(isize, @intCast(centre)) + dy * stride + dx);
                        const oa: V = self.a[o..][0..lanes].*;
                        const ob: V = self.b[o..][0..lanes].*;
                        sum += rangeWeight((oa - ca) * (oa - ca) + (ob - cb) * (ob - cb));
                    }
                }
                self.next_a[centre..][0..lanes].* = smoothstepV(sv(0.15), sv(0.45), sum / sv(9.0));
            }
        }
    }
};

/// How alike two colours are, from their squared Oklab distance: 1 when
/// equal, 0.6 at the smoothing's range, nothing past 2.1 times it.
inline fn rangeWeight(distance2: V) V {
    const t = @max(sv(0.0), sv(1.0) - distance2 * sv(1.0 / (4.5 * smooth_range * smooth_range)));
    return t * t;
}

fn smoothLine(kernel: *const [2 * peak_radius + 1]f32, values: []const f32, stride: usize, out: *[hist_size]f32) void {
    for (out, 0..) |*sum, i| {
        sum.* = 0.0;
        const lo = i -| peak_radius;
        const hi = @min(i + peak_radius, hist_size - 1);
        for (lo..hi + 1) |j| sum.* += values[j * stride] * kernel[j + peak_radius - i];
    }
}

fn tallerFirst(heights: *const [hist_bins]f32, lhs: u16, rhs: u16) bool {
    return heights[lhs] > heights[rhs];
}

fn histBin(value: f32) usize {
    return @intFromFloat(std.math.clamp(@round(value / @as(f32, @floatCast(hist_step))) + hist_half, 0.0, hist_size - 1));
}

fn histCoordinate(index: usize) f64 {
    return (@as(f64, @floatFromInt(index)) - hist_half) * hist_step;
}

fn gridCoordinate(index: usize) f64 {
    return (@as(f64, @floatFromInt(index)) - grid_half) * grid_step;
}

pub const lanes = 8;
pub const V = @Vector(lanes, f32);
/// A field grid node: the cohesion pull (hue times the total pull plus
/// chroma minus hue times its radial part), an a,b pair, and how much the
/// families claim the colour there (their share of the weight), faded
/// toward neutral; the fourth lane is unused.
const Node = @Vector(4, f32);

/// The fitted families and settings, ready to filter pixels.
pub const Filter = struct {
    settings: Settings,
    count: usize,
    gated: bool,
    boost: f32,
    gain: f32,
    // Per family: centre, chroma, and the core and collar fitted inside the
    // clearance to its neighbours and to the neutral axis.
    a: [max_families]f32,
    b: [max_families]f32,
    chroma: [max_families]f32,
    core: [max_families]f32,
    collar: [max_families]f32,
    nodes: [grid_bins]Node,
    /// The colour space of the pixels it filters.
    lms: Lms,

    /// For linear sRGB; set `lms` afterwards for another space.
    pub fn init(self: *Filter, model: *const Model, settings: Settings) !void {
        try settings.validate();
        self.settings = settings;
        self.lms = srgb_lms;
        // Families come tallest first, so the first ones are the kept ones.
        self.count = if (settings.isIdentity()) 0 else @min(model.count, settings.families);
        self.gated = settings.radius > 0.0;
        self.boost = @floatCast(settings.boost);
        self.gain = @floatCast(settings.gain);
        if (self.count == 0) return;
        const families = model.slice()[0..self.count];
        for (families, 0..) |family, k| {
            var separation = std.math.inf(f64);
            for (families, 0..) |other, j| {
                if (j == k) continue;
                const da = family.a - other.a;
                const db = family.b - other.b;
                separation = @min(separation, @sqrt(da * da + db * db));
            }
            const chroma = @sqrt(family.a * family.a + family.b * family.b);
            const clearance = @max(0.0, chroma - neutral_lo);
            const core = @min(settings.radius, 0.45 * separation, 0.90 * clearance);
            self.a[k] = @floatCast(family.a);
            self.b[k] = @floatCast(family.b);
            self.chroma[k] = @floatCast(chroma);
            self.core[k] = @floatCast(core);
            self.collar[k] = @floatCast(@min(1.5 * core, 0.49 * separation, 0.98 * clearance));
        }
        self.buildField(families);
    }

    /// With a target, sets the boost (between none and the settings') at
    /// which the frame's colours, as `rgb` samples them in linear light,
    /// come out at the target colourfulness. Bisects on the filter's own
    /// output, so a frame already that colourful gets no boost.
    pub fn adaptBoost(self: *Filter, r: []const f32, g: []const f32, b: []const f32) void {
        const target = self.settings.target;
        if (self.count == 0 or target == 0.0 or r.len == 0) return;
        const most = self.settings.boost;
        if (self.colourfulness(r, g, b, 0.0) >= target) return self.setBoost(0.0);
        if (self.colourfulness(r, g, b, most) <= target) return self.setBoost(most);
        var lo: f64 = 0.0;
        var hi = most;
        for (0..8) |_| {
            const mid = (lo + hi) / 2.0;
            if (self.colourfulness(r, g, b, mid) < target) lo = mid else hi = mid;
        }
        self.setBoost(lo);
    }

    fn setBoost(self: *Filter, boost: f64) void {
        self.settings.boost = boost;
        self.boost = @floatCast(boost);
    }

    /// The 90th percentile of the samples' chroma after the filter, at
    /// `boost`.
    fn colourfulness(self: *Filter, r: []const f32, g: []const f32, b: []const f32, boost: f64) f64 {
        self.setBoost(boost);
        const bins = 600;
        const bin_width: f32 = 0.0005;
        var counts: [bins]u32 = @splat(0);
        var pixels: Span = undefined;
        var start: usize = 0;
        while (start < r.len) : (start += span_pixels) {
            const n = @min(span_pixels, r.len - start);
            @memcpy(pixels.r[0..n], r[start..][0..n]);
            @memcpy(pixels.g[0..n], g[start..][0..n]);
            @memcpy(pixels.b[0..n], b[start..][0..n]);
            self.applySpan(&pixels, n);
            var first: usize = 0;
            while (first < n) : (first += lanes) {
                const lab = oklabWith(&self.lms, .{ @as(V, pixels.r[first..][0..lanes].*), @as(V, pixels.g[first..][0..lanes].*), @as(V, pixels.b[first..][0..lanes].*) });
                const chroma: [lanes]f32 = @as(V, @sqrt(lab[1] * lab[1] + lab[2] * lab[2]));
                for (chroma[0..@min(lanes, n - first)]) |c| counts[@min(bins - 1, @as(usize, @intFromFloat(c / bin_width)))] += 1;
            }
        }
        const wanted = (r.len * 9 + 9) / 10;
        var seen: usize = 0;
        for (counts, 0..) |count, bin| {
            seen += count;
            if (seen >= wanted) return (@as(f64, @floatFromInt(bin)) + 0.5) * bin_width;
        }
        return bins * bin_width;
    }

    pub fn isIdentity(self: *const Filter) bool {
        return self.count == 0;
    }

    /// Each family pulls with a Gaussian weight of distance, so colours far
    /// from every family (greys of other hues among them) keep theirs.
    fn buildField(self: *Filter, families: []const Family) void {
        const spread = 2.0 * field_sigma * field_sigma;
        const radial_share = self.settings.chroma - self.settings.hue;
        for (0..grid_size) |y| {
            for (0..grid_size) |x| {
                const a = gridCoordinate(x);
                const b = gridCoordinate(y);
                var weight_sum: f64 = 0.0;
                var pull = [2]f64{ 0.0, 0.0 };
                for (families) |center| {
                    const da = center.a - a;
                    const db = center.b - b;
                    const w = @exp(-(da * da + db * db) / spread);
                    // The pull's part along the centre's own chroma.
                    const projection = (da * center.a + db * center.b) / (center.a * center.a + center.b * center.b);
                    pull[0] += w * (self.settings.hue * da + radial_share * projection * center.a);
                    pull[1] += w * (self.settings.hue * db + radial_share * projection * center.b);
                    weight_sum += w;
                }
                // A colour belongs to the families by their weights, which
                // fall off with distance; shared out only where they overlap.
                const scale = smoothstep(neutral_lo, neutral_hi, @sqrt(a * a + b * b)) / @max(1.0, weight_sum);
                self.nodes[y * grid_size + x] = .{
                    @floatCast(scale * pull[0]),
                    @floatCast(scale * pull[1]),
                    @floatCast(scale * weight_sum),
                    0.0,
                };
            }
        }
    }

    /// Filters `count` pixels of linear-light sRGB, each channel 0 to 1, in
    /// place, and marks those that changed; the others are left alone.
    /// Colours pushed out of gamut wait in a queue and are brought back
    /// `lanes` at a time, so the bisection runs on full vectors.
    pub fn applySpan(self: *const Filter, pixels: *Span, count: usize) void {
        @memset(pixels.changed[0..count], false);
        if (self.count == 0) return;
        var queue: Queue = undefined;
        var queued: usize = 0;
        var start: usize = 0;
        while (start < count) : (start += lanes) {
            const rgb = [3]V{ pixels.r[start..][0..lanes].*, pixels.g[start..][0..lanes].*, pixels.b[start..][0..lanes].* };
            const moved = self.move(rgb) orelse continue;
            const out = oklabToLinear(&self.lms, moved.L, moved.a, moved.b);
            const outside: [lanes]bool = !inGamut(out) & moved.changed;
            const changed: [lanes]bool = moved.changed;
            const values = [3][lanes]f32{ out[0], out[1], out[2] };
            const L: [lanes]f32 = moved.L;
            const a: [lanes]f32 = moved.a;
            const b: [lanes]f32 = moved.b;
            for (0..@min(lanes, count - start)) |lane| {
                if (!changed[lane]) continue;
                const index = start + lane;
                pixels.changed[index] = true;
                if (outside[lane]) {
                    queue.L[queued] = L[lane];
                    queue.a[queued] = a[lane];
                    queue.b[queued] = b[lane];
                    queue.index[queued] = @intCast(index);
                    queued += 1;
                    continue;
                }
                pixels.r[index] = values[0][lane];
                pixels.g[index] = values[1][lane];
                pixels.b[index] = values[2][lane];
            }
        }
        var first: usize = 0;
        while (first < queued) : (first += lanes) {
            // Spare lanes repeat the first entry and are not written.
            var L: [lanes]f32 = @splat(queue.L[first]);
            var a: [lanes]f32 = @splat(queue.a[first]);
            var b: [lanes]f32 = @splat(queue.b[first]);
            const n = @min(lanes, queued - first);
            @memcpy(L[0..n], queue.L[first..][0..n]);
            @memcpy(a[0..n], queue.a[first..][0..n]);
            @memcpy(b[0..n], queue.b[first..][0..n]);
            const out = intoGamut(&self.lms, L, a, b);
            const values = [3][lanes]f32{ out[0], out[1], out[2] };
            for (0..n) |lane| {
                const index = queue.index[first + lane];
                pixels.r[index] = values[0][lane];
                pixels.g[index] = values[1][lane];
                pixels.b[index] = values[2][lane];
            }
        }
    }

    const Moved = struct { L: V, a: V, b: V, changed: @Vector(lanes, bool) };

    /// Where `lanes` colours move in Oklab, or null when none does.
    inline fn move(self: *const Filter, rgb: [3]V) ?Moved {
        const none: ?Moved = null;
        const lab = oklabWith(&self.lms, rgb);
        const L = lab[0];
        const a = lab[1];
        const b = lab[2];
        const c = @sqrt(a * a + b * b);
        // With cores on, the gate holds everything below neutral_lo still.
        if (self.gated and !@reduce(.Or, c >= sv(neutral_lo))) return none;

        const field = self.fieldAt(a, b);

        var smallest = sv(1.0);
        var owned: @Vector(lanes, bool) = @splat(false);
        var owner_distance = sv(0.0);
        var owner_chroma = sv(0.0);
        var owner_core = sv(0.0);
        var owner_collar = sv(0.0);
        var gate = sv(1.0);
        if (self.gated) {
            gate = smoothstepV(sv(neutral_lo), sv(gate_hi), c);
            for (0..self.count) |k| {
                const da = a - sv(self.a[k]);
                const db = b - sv(self.b[k]);
                const distance = @sqrt(da * da + db * db);
                const core = sv(self.core[k]);
                if (self.core[k] != 0.0) {
                    // Cohesion fades in from nothing at the core's edge.
                    const excess = distance - core;
                    const scale = (excess * excess) / (distance * (excess + sv(0.5) * core));
                    smallest = @min(smallest, @select(f32, distance <= core, sv(0.0), scale));
                }
                // Collars do not overlap: at most one family owns a pixel.
                const inside = distance < sv(self.collar[k]);
                owned = owned | inside;
                owner_distance = @select(f32, inside, distance, owner_distance);
                owner_chroma = @select(f32, inside, sv(self.chroma[k]), owner_chroma);
                owner_core = @select(f32, inside, core, owner_core);
                owner_collar = @select(f32, inside, sv(self.collar[k]), owner_collar);
            }
        }
        const protect = smoothstepV(sv(neutral_lo), sv(protect_hi), c);
        const cohesion = gate * smallest * protect;
        // Boost moves each colour out along its own hue, as far as the
        // families claim it: fully inside a core, blending across its
        // collar to the field's share. So greys gain no cast.
        const in_core = owned & (owner_distance <= owner_core);
        const in_collar = owned & !in_core;
        const core_weight = sv(1.0) - smoothstepV(sv(1.0 / 3.0), sv(1.0), owner_distance / @max(owner_core, sv(1e-12)));
        const weighted_gain = @select(f32, in_core & (owner_distance < owner_core), sv(self.gain) * core_weight, sv(0.0));
        const mix = sv(1.0) - smoothstepV(owner_core, @max(owner_collar, owner_core + sv(1e-12)), owner_distance);
        const share = protect * @select(f32, in_core, sv(1.0), @select(f32, in_collar, (sv(1.0) - mix) * gate * field[2] + mix, gate * field[2]));

        const da = cohesion * field[0] + sv(self.boost) * share * a;
        const db = cohesion * field[1] + sv(self.boost) * share * b;
        const changed = (@abs(da) + @abs(db) >= sv(1e-7)) | (weighted_gain != sv(0.0));
        if (!@reduce(.Or, changed)) return none;

        var out_a = a + da;
        var out_b = b + db;
        if (@reduce(.Or, weighted_gain > sv(0.0))) {
            // Chroma differences from the moved centre grow, along each
            // colour's own hue.
            const out_c = @max(@sqrt(out_a * out_a + out_b * out_b), sv(1e-12));
            const pivot = sv(1.0 + self.boost) * owner_chroma;
            const scale = sv(1.0) + weighted_gain * (out_c - pivot) / out_c;
            out_a *= scale;
            out_b *= scale;
        }
        return .{ .L = L, .a = out_a, .b = out_b, .changed = changed };
    }

    /// The field at each lane's a,b, bilinear between grid nodes: pull a,b
    /// and boost a,b.
    inline fn fieldAt(self: *const Filter, a: V, b: V) [4]V {
        const top = sv(grid_size - 1.00001);
        const x = std.math.clamp(a / sv(grid_step) + sv(grid_half), sv(0.0), top);
        const y = std.math.clamp(b / sv(grid_step) + sv(grid_half), sv(0.0), top);
        const fx = @floor(x);
        const fy = @floor(y);
        const dx: [lanes]f32 = x - fx;
        const dy: [lanes]f32 = y - fy;
        const ix: [lanes]u32 = @as(@Vector(lanes, u32), @intFromFloat(fx));
        const iy: [lanes]u32 = @as(@Vector(lanes, u32), @intFromFloat(fy));
        var field: [4][lanes]f32 = undefined;
        for (0..lanes) |lane| {
            const p = @as(usize, iy[lane]) * grid_size + ix[lane];
            const wx: Node = @splat(dx[lane]);
            const wy: Node = @splat(dy[lane]);
            const one: Node = @splat(1.0);
            const value = (one - wy) * ((one - wx) * self.nodes[p] + wx * self.nodes[p + 1]) +
                wy * ((one - wx) * self.nodes[p + grid_size] + wx * self.nodes[p + grid_size + 1]);
            inline for (0..4) |k| field[k][lane] = value[k];
        }
        return .{ field[0], field[1], field[2], field[3] };
    }
};

/// Pixels for `Filter.applySpan`, by channel.
pub const span_pixels = 256;
pub const Span = struct {
    r: [span_pixels]f32 align(32),
    g: [span_pixels]f32 align(32),
    b: [span_pixels]f32 align(32),
    changed: [span_pixels]bool,
};

const Queue = struct {
    L: [span_pixels]f32,
    a: [span_pixels]f32,
    b: [span_pixels]f32,
    index: [span_pixels]u16,
};

/// Linear light for out-of-gamut Oklab colours: the largest share of their
/// chroma, to 1/4096, that fits, at the same lightness.
fn intoGamut(lms: *const Lms, L: V, a: V, b: V) [3]V {
    var lo = sv(0.0);
    var hi = sv(1.0);
    for (0..12) |_| {
        const mid = (lo + hi) * sv(0.5);
        const fits = inGamut(oklabToLinear(lms, L, a * mid, b * mid));
        lo = @select(f32, fits, mid, lo);
        hi = @select(f32, fits, hi, mid);
    }
    return oklabToLinear(lms, L, a * lo, b * lo);
}

/// A colour space's matrices to and from Oklab's cone space, in f32.
pub const Lms = struct {
    to: [3][3]f32,
    from: [3][3]f32,

    pub fn of(space: rgb_space.Space) Lms {
        const m = rgb_space.lms(space);
        var out: Lms = undefined;
        for (0..3) |row| for (0..3) |column| {
            out.to[row][column] = @floatCast(m.to_lms[row][column]);
            out.from[row][column] = @floatCast(m.from_lms[row][column]);
        };
        return out;
    }
};

pub const srgb_lms = Lms.of(.srgb);

/// Oklab of `lanes` pixels of linear-light sRGB, in f32.
pub inline fn oklabV(rgb: [3]V) [3]V {
    return oklabWith(&srgb_lms, rgb);
}

/// Oklab of `lanes` pixels of linear light in the space of `m`, in f32.
pub inline fn oklabWith(m: *const Lms, rgb: [3]V) [3]V {
    const t = &m.to;
    const lms = [3]V{
        cbrtV(sv(t[0][0]) * rgb[0] + sv(t[0][1]) * rgb[1] + sv(t[0][2]) * rgb[2]),
        cbrtV(sv(t[1][0]) * rgb[0] + sv(t[1][1]) * rgb[1] + sv(t[1][2]) * rgb[2]),
        cbrtV(sv(t[2][0]) * rgb[0] + sv(t[2][1]) * rgb[1] + sv(t[2][2]) * rgb[2]),
    };
    return .{
        sv(0.2104542553) * lms[0] + sv(0.793617785) * lms[1] - sv(0.0040720468) * lms[2],
        sv(1.9779984951) * lms[0] - sv(2.428592205) * lms[1] + sv(0.4505937099) * lms[2],
        sv(0.0259040371) * lms[0] + sv(0.7827717662) * lms[1] - sv(0.808675766) * lms[2],
    };
}

inline fn oklabToLinear(space: *const Lms, L: V, a: V, b: V) [3]V {
    const l0 = L + sv(0.3963377774) * a + sv(0.2158037573) * b;
    const m0 = L - sv(0.1055613458) * a - sv(0.0638541728) * b;
    const s0 = L - sv(0.0894841775) * a - sv(1.291485548) * b;
    const l = l0 * l0 * l0;
    const m = m0 * m0 * m0;
    const s = s0 * s0 * s0;
    const f = &space.from;
    return .{
        sv(f[0][0]) * l + sv(f[0][1]) * m + sv(f[0][2]) * s,
        sv(f[1][0]) * l + sv(f[1][1]) * m + sv(f[1][2]) * s,
        sv(f[2][0]) * l + sv(f[2][1]) * m + sv(f[2][2]) * s,
    };
}

/// One colour brought into the gamut of `m`'s space as fitSpan does.
pub fn fitPixel(m: *const Lms, rgb: [3]f32) @Vector(3, f32) {
    const v = [3]V{ @splat(rgb[0]), @splat(rgb[1]), @splat(rgb[2]) };
    if (@reduce(.And, inGamut(v))) return .{ rgb[0], rgb[1], rgb[2] };
    const lab = oklabWith(m, v);
    const fitted = intoGamut(m, lab[0], lab[1], lab[2]);
    return .{
        std.math.clamp(fitted[0][0], 0.0, 1.0),
        std.math.clamp(fitted[1][0], 0.0, 1.0),
        std.math.clamp(fitted[2][0], 0.0, 1.0),
    };
}

/// Brings the colours of a span that lie outside its space's gamut (the
/// unit cube) back in: their largest share of Oklab chroma that fits, at the
/// same lightness and hue, then clipped (for lightness above white).
pub fn fitSpan(m: *const Lms, pixels: *Span, count: usize) void {
    var start: usize = 0;
    while (start < count) : (start += lanes) {
        const n = @min(lanes, count - start);
        var rgb: [3]V = undefined;
        inline for (.{ &pixels.r, &pixels.g, &pixels.b }, 0..) |channel, k| {
            var values: [lanes]f32 = @splat(0.5);
            @memcpy(values[0..n], channel[start..][0..n]);
            rgb[k] = values;
        }
        if (@reduce(.And, inGamut(rgb))) continue;
        const lab = oklabWith(m, rgb);
        const fitted = intoGamut(m, lab[0], lab[1], lab[2]);
        const outside: [lanes]bool = !inGamut(rgb);
        inline for (.{ &pixels.r, &pixels.g, &pixels.b }, 0..) |channel, k| {
            const values: [lanes]f32 = std.math.clamp(fitted[k], sv(0.0), sv(1.0));
            for (0..n) |lane| {
                if (outside[lane]) channel[start + lane] = values[lane];
            }
        }
    }
}

inline fn inGamut(rgb: [3]V) @Vector(lanes, bool) {
    var fits: @Vector(lanes, bool) = @splat(true);
    inline for (0..3) |channel| {
        fits = fits & (rgb[channel] >= sv(-1e-7)) & (rgb[channel] <= sv(1.0000001));
    }
    return fits;
}

inline fn sv(value: anytype) V {
    return @splat(@as(f32, @floatCast(value)));
}

inline fn smoothstepV(lo: V, hi: V, value: V) V {
    const t = std.math.clamp((value - lo) / (hi - lo), sv(0.0), sv(1.0));
    return t * t * (sv(3.0) - sv(2.0) * t);
}

/// Cube root of non-negative values: a bit-level first guess (musl's
/// cbrtf constant), then two Halley steps, to f32 precision.
inline fn cbrtV(x: V) V {
    const clamped = @max(x, sv(1e-24));
    const U = @Vector(lanes, u32);
    const bits: U = @bitCast(clamped);
    var y: V = @bitCast(bits / @as(U, @splat(3)) + @as(U, @splat(709958130)));
    inline for (0..2) |_| {
        const y3 = y * y * y;
        y = y * (y3 + sv(2.0) * clamped) / (sv(2.0) * y3 + clamped);
    }
    return y;
}

/// Oklab of linear light in the space of `m`, in f64.
pub fn oklabFromLinearWith(m: *const rgb_space.Lms, r: f64, g: f64, b: f64) [3]f64 {
    const cone = rgb_space.multiplyVector(m.to_lms, .{ r, g, b });
    const l = std.math.cbrt(cone[0]);
    const mm = std.math.cbrt(cone[1]);
    const s = std.math.cbrt(cone[2]);
    return .{
        0.2104542553 * l + 0.793617785 * mm - 0.0040720468 * s,
        1.9779984951 * l - 2.428592205 * mm + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * mm - 0.808675766 * s,
    };
}

/// Oklab of linear-light sRGB, in f64.
pub fn oklabFromLinear(r: f64, g: f64, b: f64) [3]f64 {
    const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return .{
        0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
    };
}

fn smoothstep(lo: f64, hi: f64, value: f64) f64 {
    const t = std.math.clamp((value - lo) / (hi - lo), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// Tests: the f32 path against the same math in f64, scalar and branchy as
// the prototype wrote it, and both against the prototype's own output.

fn srgbDecode(v: f64) f64 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

fn srgbEncode(v: f64) f64 {
    return if (v <= 0.0031308) 12.92 * v else 1.055 * std.math.pow(f64, v, 1.0 / 2.4) - 0.055;
}

fn linearFromOklabReference(L: f64, a: f64, b: f64, rgb: *[3]f64) bool {
    const l0 = L + 0.3963377774 * a + 0.2158037573 * b;
    const m0 = L - 0.1055613458 * a - 0.0638541728 * b;
    const s0 = L - 0.0894841775 * a - 1.291485548 * b;
    const l = l0 * l0 * l0;
    const m = m0 * m0 * m0;
    const s = s0 * s0 * s0;
    rgb[0] = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    rgb[1] = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    rgb[2] = -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s;
    for (rgb) |v| if (!(v >= -1e-7 and v <= 1.0000001)) return false;
    return true;
}

/// One pixel in f64: linear light, or null when it stays as it is.
fn filterReference(filter: *const Filter, lab: [3]f64) ?[3]f64 {
    const settings = filter.settings;
    const L = lab[0];
    const a = lab[1];
    const b = lab[2];

    var field: [4]f64 = undefined;
    {
        const x = std.math.clamp(a / grid_step + grid_half, 0.0, grid_size - 1.00001);
        const y = std.math.clamp(b / grid_step + grid_half, 0.0, grid_size - 1.00001);
        const dx = x - @floor(x);
        const dy = y - @floor(y);
        const p = @as(usize, @intFromFloat(@floor(y))) * grid_size + @as(usize, @intFromFloat(@floor(x)));
        const nodes = [4][4]f32{ filter.nodes[p], filter.nodes[p + 1], filter.nodes[p + grid_size], filter.nodes[p + grid_size + 1] };
        for (&field, 0..) |*value, k| {
            const n00: f64 = nodes[0][k];
            const n10: f64 = nodes[1][k];
            const n01: f64 = nodes[2][k];
            const n11: f64 = nodes[3][k];
            value.* = (1.0 - dy) * ((1.0 - dx) * n00 + dx * n10) + dy * ((1.0 - dx) * n01 + dx * n11);
        }
    }

    var smallest: f64 = 1.0;
    var gate: f64 = 1.0;
    var owner: ?usize = null;
    var owner_distance: f64 = 0.0;
    if (settings.radius > 0.0) {
        gate = smoothstep(neutral_lo, gate_hi, @sqrt(a * a + b * b));
        for (0..filter.count) |k| {
            const da = a - filter.a[k];
            const db = b - filter.b[k];
            const distance = @sqrt(da * da + db * db);
            const core: f64 = filter.core[k];
            const scale = if (core == 0.0) 1.0 else if (distance <= core) 0.0 else blk: {
                const excess = distance - core;
                break :blk (excess / distance) * (excess / (excess + 0.5 * core));
            };
            smallest = @min(smallest, scale);
            if (distance < filter.collar[k]) {
                owner = k;
                owner_distance = distance;
            }
        }
    }
    const protect = smoothstep(neutral_lo, protect_hi, @sqrt(a * a + b * b));
    const cohesion = gate * smallest * protect;
    var share = gate * field[2];
    var weighted_gain: f64 = 0.0;
    if (owner) |k| {
        const core: f64 = filter.core[k];
        if (owner_distance <= core) {
            share = 1.0;
            const weight = if (owner_distance >= core) 0.0 else 1.0 - smoothstep(1.0 / 3.0, 1.0, owner_distance / core);
            weighted_gain = settings.gain * weight;
        } else {
            const mix = 1.0 - smoothstep(core, filter.collar[k], owner_distance);
            share = (1.0 - mix) * share + mix;
        }
    }
    share *= protect;
    const da = cohesion * field[0] + settings.boost * share * a;
    const db = cohesion * field[1] + settings.boost * share * b;
    if (@abs(da) + @abs(db) < 1e-7 and weighted_gain == 0.0) return null;

    var out_a = a + da;
    var out_b = b + db;
    if (weighted_gain > 0.0) {
        const pivot = (1.0 + settings.boost) * filter.chroma[owner.?];
        const c = @sqrt(out_a * out_a + out_b * out_b);
        const scale = (c + weighted_gain * (c - pivot)) / c;
        out_a *= scale;
        out_b *= scale;
    }
    var rgb: [3]f64 = undefined;
    if (!linearFromOklabReference(L, out_a, out_b, &rgb)) {
        var lo: f64 = 0.0;
        var hi: f64 = 1.0;
        for (0..12) |_| {
            const mid = (lo + hi) / 2.0;
            if (linearFromOklabReference(L, out_a * mid, out_b * mid, &rgb)) lo = mid else hi = mid;
        }
        _ = linearFromOklabReference(L, out_a * lo, out_b * lo, &rgb);
    }
    return rgb;
}

const fixture_dir = "test/fixtures/processing/chroma/";

const Manifest = struct {
    width: usize,
    height: usize,
    input: []const u8,
    expectedPeaks: []const struct { a: f64, b: f64, h: f64 },
    cases: []const struct {
        name: []const u8,
        settings: Settings,
        output: []const u8,
        changedPixelCount: usize,
    },
    invariants: struct { neutralSampleIndices: []const usize },
};

const Prototype = struct {
    parsed: std.json.Parsed(Manifest),
    text: []u8,
    source: []u8,

    fn load(allocator: std.mem.Allocator) !Prototype {
        const text = try readFixture(allocator, "manifest.json");
        errdefer allocator.free(text);
        const parsed = try std.json.parseFromSlice(Manifest, allocator, text, .{ .ignore_unknown_fields = true });
        errdefer parsed.deinit();
        const source = try readFixture(allocator, parsed.value.input);
        return .{ .parsed = parsed, .text = text, .source = source };
    }

    fn deinit(self: *Prototype, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        self.parsed.deinit();
        allocator.free(self.text);
    }
};

fn readFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, fixture_dir ++ "{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 20));
}

/// The families the prototype fitted to its swatches.
fn prototypeModel(prototype: *const Prototype) Model {
    var model = Model{};
    for (prototype.parsed.value.expectedPeaks) |peak| {
        model.families[model.count] = .{ .a = peak.a, .b = peak.b, .height = peak.h };
        model.count += 1;
    }
    return model;
}

fn encode8(v: f64) u8 {
    return @intFromFloat(std.math.clamp(@round(255.0 * srgbEncode(v)), 0.0, 255.0));
}

/// Filters an RGBA8 image, transparent pixels left alone, by the f64 path
/// or the fast one.
fn applyRgba8(filter: *const Filter, input: []const u8, output: []u8, comptime fast: bool) void {
    @memcpy(output, input);
    const pixel_count = input.len / 4;
    var pixels: Span = undefined;
    var start: usize = 0;
    while (start < pixel_count) : (start += span_pixels) {
        const n = @min(span_pixels, pixel_count - start);
        for (0..n) |i| {
            const pixel = input[4 * (start + i) ..][0..4];
            // Transparent pixels go in black, which never changes.
            var linear: [3]f64 = .{ 0.0, 0.0, 0.0 };
            if (pixel[3] != 0) {
                for (&linear, pixel[0..3]) |*out, byte| out.* = srgbDecode(@as(f64, @floatFromInt(byte)) / 255.0);
            }
            if (!fast) {
                if (pixel[3] == 0 or filter.count == 0) continue;
                const rgb = filterReference(filter, oklabFromLinear(linear[0], linear[1], linear[2])) orelse continue;
                for (0..3) |channel| output[4 * (start + i) + channel] = encode8(rgb[channel]);
                continue;
            }
            pixels.r[i] = @floatCast(linear[0]);
            pixels.g[i] = @floatCast(linear[1]);
            pixels.b[i] = @floatCast(linear[2]);
        }
        if (!fast) continue;
        filter.applySpan(&pixels, n);
        for (0..n) |i| {
            if (!pixels.changed[i] or input[4 * (start + i) + 3] == 0) continue;
            const out = output[4 * (start + i) ..][0..3];
            out[0] = encode8(pixels.r[i]);
            out[1] = encode8(pixels.g[i]);
            out[2] = encode8(pixels.b[i]);
        }
    }
}

test "the fit finds colourful objects, not near-grey tones or scattered specks" {
    const allocator = std.testing.allocator;
    const fit = try allocator.create(Fit);
    defer allocator.destroy(fit);
    // A grainy grey ground with a broad near-grey warm cast over half of it,
    // a green patch, a small magenta patch, and blue specks scattered alone.
    const width = 200;
    const height = 120;
    fit.begin(fitSize(width, height));
    var random = std.Random.DefaultPrng.init(7);
    for (0..height) |y| {
        for (0..width) |x| {
            var lab = [3]f32{ 0.6, 0.004, 0.008 };
            if (x >= 100) lab = .{ 0.6, 0.014, 0.022 };
            if (x >= 20 and x < 60 and y >= 20 and y < 60) lab = .{ 0.55, -0.06, 0.08 };
            if (x >= 130 and x < 145 and y >= 70 and y < 85) lab = .{ 0.6, 0.12, -0.03 };
            if ((x * 7 + y * 13) % 97 == 0) lab = .{ 0.6, -0.03, -0.15 };
            for (lab[1..]) |*v| v.* += (random.random().float(f32) - 0.5) * 0.03;
            fit.set(x, y, lab);
        }
    }
    const model = fit.model();
    try std.testing.expectEqual(@as(usize, 2), model.count);
    try std.testing.expectApproxEqAbs(@as(f64, -0.06), model.families[0].a, 0.006);
    try std.testing.expectApproxEqAbs(@as(f64, 0.08), model.families[0].b, 0.006);
    try std.testing.expectApproxEqAbs(@as(f64, 0.12), model.families[1].a, 0.006);
    try std.testing.expectApproxEqAbs(@as(f64, -0.03), model.families[1].b, 0.006);
}

test "without boost or pull, both paths stay within an 8-bit level of the prototype's output" {
    const allocator = std.testing.allocator;
    var prototype = try Prototype.load(allocator);
    defer prototype.deinit(allocator);
    const source = prototype.source;
    const model = prototypeModel(&prototype);
    const filter = try allocator.create(Filter);
    defer allocator.destroy(filter);
    const output = try allocator.alloc(u8, source.len);
    defer allocator.free(output);
    for (prototype.parsed.value.cases) |case| {
        // Boost and pull leave greys neutral here, unlike the prototype's,
        // which moved them toward the families' hues.
        if (case.settings.boost != 0.0 or case.settings.hue != 0.0 or case.settings.chroma != 0.0) continue;
        const expected = try readFixture(allocator, case.output);
        defer allocator.free(expected);
        try filter.init(&model, case.settings);
        inline for (.{ false, true }) |fast| {
            applyRgba8(filter, source, output, fast);
            var changed: usize = 0;
            for (0..source.len / 4) |i| {
                for (0..4) |channel| {
                    const got: i32 = output[4 * i + channel];
                    const want: i32 = expected[4 * i + channel];
                    std.testing.expect(@abs(got - want) <= 1) catch |err| {
                        std.debug.print("case {s}, fast {}, pixel {d}: {d} against {d}\n", .{ case.name, fast, i, got, want });
                        return err;
                    };
                }
                if (!std.mem.eql(u8, source[4 * i ..][0..4], output[4 * i ..][0..4])) changed += 1;
            }
            try std.testing.expectEqual(case.changedPixelCount, changed);
            for (prototype.parsed.value.invariants.neutralSampleIndices) |i| {
                try std.testing.expectEqualSlices(u8, source[4 * i ..][0..4], output[4 * i ..][0..4]);
            }
        }
    }
}

test "the fast f32 path stays within a few 16-bit levels of f64 over the sRGB cube" {
    const allocator = std.testing.allocator;
    var prototype = try Prototype.load(allocator);
    defer prototype.deinit(allocator);
    const model = prototypeModel(&prototype);
    const filter = try allocator.create(Filter);
    defer allocator.destroy(filter);
    const step = 3;
    const levels = 255 / step + 1;
    const total = levels * levels * levels;
    for ([_]Settings{ .{}, Settings.max }) |settings| {
        try filter.init(&model, settings);
        // Colours brought back into gamut can differ by the bisection's
        // last step (1/4096 of their chroma), which near black shows as up
        // to 0.85 of an 8-bit level; the rest stay within a few 16-bit
        // levels.
        var inner_worst: u64 = 0;
        var edge_worst: u64 = 0;
        var sum_squares: f64 = 0.0;
        var pixels: Span = undefined;
        var exact: [span_pixels][3]f64 = undefined;
        var start: usize = 0;
        while (start < total) : (start += span_pixels) {
            const n = @min(span_pixels, total - start);
            for (0..n) |i| {
                const index = start + i;
                var linear: [3]f64 = undefined;
                for (&linear, [_]usize{ index % levels, index / levels % levels, index / (levels * levels) }) |*out, level| {
                    out.* = srgbDecode(@as(f64, @floatFromInt(level * step)) / 255.0);
                }
                exact[i] = filterReference(filter, oklabFromLinear(linear[0], linear[1], linear[2])) orelse linear;
                pixels.r[i] = @floatCast(linear[0]);
                pixels.g[i] = @floatCast(linear[1]);
                pixels.b[i] = @floatCast(linear[2]);
            }
            filter.applySpan(&pixels, n);
            for (0..n) |i| {
                const edge = for (exact[i]) |v| {
                    if (v < 0.002 or v > 0.998) break true;
                } else false;
                for (exact[i], [_]f32{ pixels.r[i], pixels.g[i], pixels.b[i] }) |want, got| {
                    const diff = @as(i64, u16Level(want)) - @as(i64, u16Level(got));
                    if (edge) edge_worst = @max(edge_worst, @abs(diff)) else inner_worst = @max(inner_worst, @abs(diff));
                    sum_squares += @floatFromInt(diff * diff);
                }
            }
        }
        const rms = @sqrt(sum_squares / @as(f64, @floatFromInt(3 * total)));
        // Inside, f32 rounding near black (sRGB's slope there is 12.92)
        // reaches 4 levels with the boost at its 0.8 maximum.
        try std.testing.expect(inner_worst <= 4 and edge_worst <= 257 and rms < 2.0);
    }
}

/// The render's 16-bit level for linear light.
fn u16Level(linear: anytype) u16 {
    const v = std.math.clamp(@as(f64, linear), 0.0, 1.0);
    return @intFromFloat(std.math.clamp(srgbEncode(v) * 65535.0, 0.0, 65535.0));
}

test "greys stay neutral while a family's colour moves out along its hue" {
    const allocator = std.testing.allocator;
    var model = Model{};
    model.families[0] = .{ .a = 0.02, .b = 0.07, .height = 1.0 };
    model.count = 1;
    const filter = try allocator.create(Filter);
    defer allocator.destroy(filter);
    try filter.init(&model, .{});
    const family_hue = std.math.atan2(@as(f64, 0.07), 0.02);
    for (0..72) |step| {
        const angle = @as(f64, @floatFromInt(step)) * std.math.pi / 36.0;
        for ([_]f64{ 0.01, 0.02, 0.03, 0.04, 0.05 }) |radius| {
            const lab = [3]f64{ 0.6, radius * @cos(angle), radius * @sin(angle) };
            const moved = filterReference(filter, lab) orelse continue;
            const out = oklabFromLinear(moved[0], moved[1], moved[2]);
            const shift = @sqrt((out[1] - lab[1]) * (out[1] - lab[1]) + (out[2] - lab[2]) * (out[2] - lab[2]));
            // Near greys of any hue barely move. Colours more than 120
            // degrees from the family's hue feel only the edge of its pull:
            // at chroma 0.04, under a twentieth of their chroma.
            if (radius <= 0.02) try std.testing.expect(shift < 0.0005);
            if (@cos(angle - family_hue) < -0.5) try std.testing.expect(shift < 0.002);
        }
    }
    // The family's own colour moves out by the boost, keeping its hue.
    const centre = filterReference(filter, .{ 0.6, 0.02, 0.07 }).?;
    const out = oklabFromLinear(centre[0], centre[1], centre[2]);
    try std.testing.expectApproxEqAbs(@as(f64, 0.026), out[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.091), out[2], 0.001);
}

fn oklabToLinearScalar(lab: [3]f64) [3]f64 {
    var rgb: [3]f64 = undefined;
    _ = linearFromOklabReference(lab[0], lab[1], lab[2], &rgb);
    return rgb;
}

test "the boost adapts to reach a colourfulness target" {
    const allocator = std.testing.allocator;
    var model = Model{};
    model.families[0] = .{ .a = 0.03, .b = 0.05, .height = 1.0 };
    model.count = 1;
    const filter = try allocator.create(Filter);
    defer allocator.destroy(filter);
    // Samples of one warm colour family at three colourfulness levels.
    var r: [4096]f32 = undefined;
    var g: [4096]f32 = undefined;
    var b: [4096]f32 = undefined;
    for ([_]f64{ 0.6, 0.8, 1.4 }, [_]f64{ 0.3, -1.0, 0.0 }) |level, expected| {
        var random = std.Random.DefaultPrng.init(5);
        for (&r, &g, &b) |*rr, *gg, *bb| {
            const spread = level * (0.7 + 0.6 * random.random().float(f64));
            const lab = [3]f64{ 0.6, 0.03 * spread, 0.05 * spread };
            const linear = oklabToLinearScalar(lab);
            rr.* = @floatCast(linear[0]);
            gg.* = @floatCast(linear[1]);
            bb.* = @floatCast(linear[2]);
        }
        try filter.init(&model, .{ .boost = 0.3, .target = 0.06 });
        filter.adaptBoost(&r, &g, &b);
        if (expected >= 0.0) {
            // Muted: the most it may; already colourful: none.
            try std.testing.expectEqual(expected, filter.settings.boost);
        } else {
            // In between: the boost that reaches the target.
            try std.testing.expect(filter.settings.boost > 0.0 and filter.settings.boost < 0.3);
            try std.testing.expectApproxEqAbs(@as(f64, 0.06), filter.colourfulness(&r, &g, &b, filter.settings.boost), 0.001);
        }
    }
}

test "settings outside their ranges are rejected" {
    try (Settings{}).validate();
    try std.testing.expectError(error.InvalidChromaSetting, (Settings{ .gain = 0.6 }).validate());
    try std.testing.expectError(error.InvalidChromaSetting, (Settings{ .hue = -0.1 }).validate());
    try std.testing.expectError(error.InvalidChromaSetting, (Settings{ .radius = std.math.nan(f64) }).validate());
    try std.testing.expectError(error.InvalidChromaSetting, (Settings{ .families = 0 }).validate());
    try std.testing.expectError(error.InvalidChromaSetting, (Settings{ .families = 13 }).validate());
}

test "fewer families keep the tallest and leave the others' colours alone" {
    const allocator = std.testing.allocator;
    var prototype = try Prototype.load(allocator);
    defer prototype.deinit(allocator);
    const model = prototypeModel(&prototype);
    try std.testing.expectEqual(@as(usize, 5), model.count);
    const filter = try allocator.create(Filter);
    defer allocator.destroy(filter);
    const all = try allocator.alloc(u8, prototype.source.len);
    defer allocator.free(all);
    const two = try allocator.alloc(u8, prototype.source.len);
    defer allocator.free(two);
    try filter.init(&model, .{});
    applyRgba8(filter, prototype.source, all, true);
    try filter.init(&model, .{ .families = 2 });
    try std.testing.expectEqual(@as(usize, 2), filter.count);
    try std.testing.expectEqual(@as(f32, @floatCast(model.families[1].a)), filter.a[1]);
    applyRgba8(filter, prototype.source, two, true);
    try std.testing.expect(!std.mem.eql(u8, all, two));
}
