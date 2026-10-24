//! The two rows of perforations along a 35mm strip. Each hole lets clear
//! light through, 2.79 mm across the strip and 1.98 mm along it, the rows'
//! centres 28.2 mm apart (35mm film's perforation standard), and the rows
//! show however faint the pictures between them: every frame lies between
//! them.

const std = @import("std");
const strips = @import("strips.zig");

/// Lines x = a + b y, for a strip running down the image.
pub const Line = strips.Line;

pub const Perforations = struct {
    /// The centre lines of the left and right rows of holes.
    left: Line,
    right: Line,
    /// A hole's size across the strip, in pixels.
    hole_across_px: f64,

    /// The film between the rows' inner edges at `y`, less `margin`.
    pub fn innerSpan(self: Perforations, y: f64, margin: f64) [2]f64 {
        const half = self.hole_across_px / 2.0;
        return .{ self.left.at(y) + half + margin, self.right.at(y) - half - margin };
    }

    /// The rows in another image's coordinates, through `forward` (an
    /// affine x' = m0 x + m1 y + m2, y' = m3 x + m4 y + m5).
    pub fn transformed(self: Perforations, forward: [6]f64, height: f64) Perforations {
        return .{
            .left = transformLine(self.left, forward, height),
            .right = transformLine(self.right, forward, height),
            .hole_across_px = self.hole_across_px,
        };
    }
};

fn transformLine(line: Line, m: [6]f64, height: f64) Line {
    const x0 = line.at(0.0);
    const x1 = line.at(height);
    const p0 = [2]f64{ m[0] * x0 + m[1] * 0.0 + m[2], m[3] * x0 + m[4] * 0.0 + m[5] };
    const p1 = [2]f64{ m[0] * x1 + m[1] * height + m[2], m[3] * x1 + m[4] * height + m[5] };
    const b = (p1[0] - p0[0]) / (p1[1] - p0[1]);
    return .{ .a = p0[0] - b * p0[1], .b = b };
}

const hole_across_mm = 2.794;
const hole_along_mm = 1.98;
const row_spacing_mm = 28.16;
/// A clear island counts as a hole within this share of the standard size.
const hole_size_tolerance = 0.25;
/// The rows' slopes must agree this closely (the film is one piece), and
/// their spacing come within this share of the standard.
const max_row_angle_difference = 0.15 * std.math.pi / 180.0;
const row_spacing_tolerance = 0.04;
/// Each row needs this many holes, the length of a frame and a half.
const min_holes_per_row = 8;

/// Finds the perforation rows in a detection gray image of a 35mm strip
/// running down it (film darker than clear glass), or null when two clear
/// rows are not there: a strip cut at the scan's edge, 120 film, or holes
/// the scan's border or a holder hides.
pub fn find(allocator: std.mem.Allocator, gray: []const u8, width: usize, height: usize, px_per_mm: f64) !?Perforations {
    if (width == 0 or height <= width or gray.len != width * height) return null;
    const clear = strips.clearThreshold(gray);
    const labels = try allocator.alloc(u32, gray.len);
    defer allocator.free(labels);
    @memset(labels, 0);
    const queue = try allocator.alloc(usize, gray.len);
    defer allocator.free(queue);

    const Hole = struct { x: f64, y: f64 };
    var holes: std.ArrayList(Hole) = .empty;
    defer holes.deinit(allocator);
    const across_px = hole_across_mm * px_per_mm;
    const along_px = hole_along_mm * px_per_mm;
    var next_label: u32 = 0;
    for (gray, 0..) |value, start| {
        if (labels[start] != 0 or value <= clear) continue;
        next_label += 1;
        labels[start] = next_label;
        queue[0] = start;
        var head: usize = 0;
        var tail: usize = 1;
        var min_x = start % width;
        var max_x = min_x;
        var min_y = start / width;
        var max_y = min_y;
        var sum_x: f64 = 0.0;
        var sum_y: f64 = 0.0;
        var touches_border = false;
        while (head < tail) : (head += 1) {
            const index = queue[head];
            const x = index % width;
            const y = index / width;
            sum_x += @floatFromInt(x);
            sum_y += @floatFromInt(y);
            min_x = @min(min_x, x);
            max_x = @max(max_x, x);
            min_y = @min(min_y, y);
            max_y = @max(max_y, y);
            if (x == 0 or y == 0 or x + 1 == width or y + 1 == height) touches_border = true;
            const neighbours = [_]?usize{
                if (x > 0) index - 1 else null,
                if (x + 1 < width) index + 1 else null,
                if (y > 0) index - width else null,
                if (y + 1 < height) index + width else null,
            };
            for (neighbours) |maybe| {
                const next = maybe orelse continue;
                if (labels[next] != 0 or gray[next] <= clear) continue;
                labels[next] = next_label;
                queue[tail] = next;
                tail += 1;
            }
        }
        // Clear glass round the strip touches the border or is far larger;
        // a hole is an island of the standard size inside the film.
        if (touches_border) continue;
        const w: f64 = @floatFromInt(max_x - min_x + 1);
        const h: f64 = @floatFromInt(max_y - min_y + 1);
        if (@abs(w - across_px) > hole_size_tolerance * across_px) continue;
        if (@abs(h - along_px) > hole_size_tolerance * along_px) continue;
        const area: f64 = @floatFromInt(tail);
        if (area < 0.6 * w * h) continue;
        try holes.append(allocator, .{ .x = sum_x / area, .y = sum_y / area });
    }
    if (holes.items.len < 2 * min_holes_per_row) return null;

    // The rows are the two sides of the widest gap between holes across.
    const items = holes.items;
    std.mem.sort(Hole, items, {}, struct {
        fn lessThan(_: void, a: Hole, b: Hole) bool {
            return a.x < b.x;
        }
    }.lessThan);
    var split: usize = 0;
    var widest: f64 = 0.0;
    for (1..items.len) |index| {
        const gap = items[index].x - items[index - 1].x;
        if (gap > widest) {
            widest = gap;
            split = index;
        }
    }
    const left_holes = items[0..split];
    const right_holes = items[split..];
    if (left_holes.len < min_holes_per_row or right_holes.len < min_holes_per_row) return null;
    const left = (try fitRow(allocator, left_holes, px_per_mm)) orelse return null;
    const right = (try fitRow(allocator, right_holes, px_per_mm)) orelse return null;
    if (@abs(std.math.atan(left.b) - std.math.atan(right.b)) > max_row_angle_difference) return null;
    const middle = @as(f64, @floatFromInt(height)) / 2.0;
    const spacing = right.at(middle) - left.at(middle);
    if (@abs(spacing - row_spacing_mm * px_per_mm) > row_spacing_tolerance * row_spacing_mm * px_per_mm) return null;

    // The standard's width, not the measured one: at preview scale the
    // holes' blurred edges make them look wider.
    return .{ .left = left, .right = right, .hole_across_px = across_px };
}

/// x = a + b y through the holes' centres, fitted again without any more
/// than 0.3 mm off the first fit (a hole the dust removal or a scratch
/// half filled).
fn fitRow(allocator: std.mem.Allocator, holes: anytype, px_per_mm: f64) !?Line {
    const ys = try allocator.alloc(f64, holes.len);
    defer allocator.free(ys);
    const xs = try allocator.alloc(f64, holes.len);
    defer allocator.free(xs);
    for (holes, ys, xs) |hole, *y, *x| {
        y.* = hole.y;
        x.* = hole.x;
    }
    const first = fitLine(ys, xs, null, 0.0) orelse return null;
    return fitLine(ys, xs, first, 0.3 * px_per_mm) orelse first;
}

fn fitLine(ts: []const f64, ss: []const f64, previous: ?Line, reach: f64) ?Line {
    var n: f64 = 0.0;
    var st: f64 = 0.0;
    var s_sum: f64 = 0.0;
    var stt: f64 = 0.0;
    var sts: f64 = 0.0;
    for (ts, ss) |t, s| {
        if (previous) |line| if (@abs(s - line.at(t)) > reach) continue;
        n += 1.0;
        st += t;
        s_sum += s;
        stt += t * t;
        sts += t * s;
    }
    if (n < 2.0) return null;
    const denominator = n * stt - st * st;
    if (denominator == 0.0) return null;
    const b = (n * sts - st * s_sum) / denominator;
    return .{ .a = (s_sum - b * st) / n, .b = b };
}
