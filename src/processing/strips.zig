//! Film strips side by side in one scan. On the transparency unit each
//! strip is an island of film in the light through clear glass, however
//! close the strips lie, so frame detection finds the strips first and
//! detects each on its own (`frames.detectFramesFromImage`).

const std = @import("std");

pub const Strip = struct {
    /// Bounding box in image pixels.
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    label: u32,
    /// For a strip running down the image, its left and right edges as
    /// lines x = a + b y, fitted where they show; null where the scan's
    /// border cuts that side off (two 35mm strips are wider than the V600's
    /// transparency unit, so the outer perforations go).
    left_edge: ?Line = null,
    right_edge: ?Line = null,
    cut_left: bool = false,
    cut_right: bool = false,
};

pub const Line = struct {
    a: f64,
    b: f64,

    pub fn at(self: Line, t: f64) f64 {
        return self.a + self.b * t;
    }
};

pub const StripMap = struct {
    /// Each pixel's region, 0 where there is no film.
    labels: []u32,
    /// The strips in order across them (left to right for strips running
    /// down the image).
    strips: []Strip,
    /// Darkest gray value counted as clear glass.
    clear_threshold: u8,

    pub fn deinit(self: *StripMap, allocator: std.mem.Allocator) void {
        allocator.free(self.labels);
        allocator.free(self.strips);
        self.* = undefined;
    }
};

/// A strip's region must have at least this share of the largest one's
/// area; dust, tape, and slivers of film stay out.
const min_area_of_largest = 0.25;
/// And run this many times longer than it is wide.
const min_elongation = 2.5;
/// And, when the scale is known, be at least this share of the format's
/// strip width across (strips at the scan's edge lose their perforations).
const min_width_of_strip = 0.6;

/// The strips in a detection gray image (film darker than clear glass).
/// `strip_width_px` is the format's strip width in image pixels, if known.
pub fn find(allocator: std.mem.Allocator, gray: []const u8, width: usize, height: usize, strip_width_px: ?f64) !StripMap {
    if (width == 0 or height == 0 or gray.len != width * height) return error.InvalidStripInput;
    const clear_threshold = clearThreshold(gray);

    const labels = try allocator.alloc(u32, gray.len);
    errdefer allocator.free(labels);
    @memset(labels, 0);
    const queue = try allocator.alloc(usize, gray.len);
    defer allocator.free(queue);

    const Region = struct { area: usize, min_x: usize, max_x: usize, min_y: usize, max_y: usize };
    var regions: std.ArrayList(Region) = .empty;
    defer regions.deinit(allocator);
    for (gray, 0..) |value, start| {
        if (labels[start] != 0 or value > clear_threshold) continue;
        const label: u32 = @intCast(regions.items.len + 1);
        var region = Region{ .area = 0, .min_x = start % width, .max_x = start % width, .min_y = start / width, .max_y = start / width };
        labels[start] = label;
        queue[0] = start;
        var head: usize = 0;
        var tail: usize = 1;
        while (head < tail) : (head += 1) {
            const index = queue[head];
            const x = index % width;
            const y = index / width;
            region.area += 1;
            region.min_x = @min(region.min_x, x);
            region.max_x = @max(region.max_x, x);
            region.min_y = @min(region.min_y, y);
            region.max_y = @max(region.max_y, y);
            const neighbours = [_]?usize{
                if (x > 0) index - 1 else null,
                if (x + 1 < width) index + 1 else null,
                if (y > 0) index - width else null,
                if (y + 1 < height) index + width else null,
            };
            for (neighbours) |maybe| {
                const next = maybe orelse continue;
                if (labels[next] != 0 or gray[next] > clear_threshold) continue;
                labels[next] = label;
                queue[tail] = next;
                tail += 1;
            }
        }
        try regions.append(allocator, region);
    }

    var largest: usize = 0;
    for (regions.items) |region| largest = @max(largest, region.area);
    var strips: std.ArrayList(Strip) = .empty;
    errdefer strips.deinit(allocator);
    for (regions.items, 1..) |region, label| {
        const w = region.max_x - region.min_x + 1;
        const h = region.max_y - region.min_y + 1;
        const across: f64 = @floatFromInt(@min(w, h));
        const along: f64 = @floatFromInt(@max(w, h));
        if (@as(f64, @floatFromInt(region.area)) < min_area_of_largest * @as(f64, @floatFromInt(largest))) continue;
        if (along < min_elongation * across) continue;
        if (strip_width_px) |strip_width| {
            if (across < min_width_of_strip * strip_width) continue;
        }
        try strips.append(allocator, .{ .x = region.min_x, .y = region.min_y, .width = w, .height = h, .label = @intCast(label) });
    }
    // Order across the strips: by x when they run down the image.
    const items = strips.items;
    var vertical = true;
    for (items) |strip| vertical = vertical and strip.height >= strip.width;
    if (vertical) {
        std.mem.sort(Strip, items, {}, struct {
            fn lessThan(_: void, a: Strip, b: Strip) bool {
                return 2 * a.x + a.width < 2 * b.x + b.width;
            }
        }.lessThan);
    } else {
        std.mem.sort(Strip, items, {}, struct {
            fn lessThan(_: void, a: Strip, b: Strip) bool {
                return 2 * a.y + a.height < 2 * b.y + b.height;
            }
        }.lessThan);
    }
    if (vertical) {
        for (items) |*strip| try fitEdges(allocator, labels, width, strip);
    }
    return .{ .labels = labels, .strips = try strips.toOwnedSlice(allocator), .clear_threshold = clear_threshold };
}

/// A side touching the scan's border in this share of the strip's rows is
/// cut off there.
const cut_share = 0.5;

/// Fits a vertical strip's left and right edges to the outermost pixels of
/// its region in each row, leaving out the 5% at each cut end of the film.
fn fitEdges(allocator: std.mem.Allocator, labels: []const u32, width: usize, strip: *Strip) !void {
    const rows = strip.height;
    const lefts = try allocator.alloc(f64, rows);
    defer allocator.free(lefts);
    const rights = try allocator.alloc(f64, rows);
    defer allocator.free(rights);
    var at_left: usize = 0;
    var at_right: usize = 0;
    var counted: usize = 0;
    const skip = rows / 20;
    var left_count: usize = 0;
    var right_count: usize = 0;
    const ys = try allocator.alloc(f64, rows);
    defer allocator.free(ys);
    const ys_right = try allocator.alloc(f64, rows);
    defer allocator.free(ys_right);
    for (strip.y + skip..strip.y + rows - skip) |y| {
        var min_x: ?usize = null;
        var max_x: usize = 0;
        for (strip.x..strip.x + strip.width) |x| {
            if (labels[y * width + x] != strip.label) continue;
            if (min_x == null) min_x = x;
            max_x = x;
        }
        const first = min_x orelse continue;
        counted += 1;
        if (first == 0) at_left += 1 else {
            lefts[left_count] = @floatFromInt(first);
            ys[left_count] = @floatFromInt(y);
            left_count += 1;
        }
        if (max_x == width - 1) at_right += 1 else {
            rights[right_count] = @floatFromInt(max_x);
            ys_right[right_count] = @floatFromInt(y);
            right_count += 1;
        }
    }
    if (counted == 0) return;
    const share = cut_share * @as(f64, @floatFromInt(counted));
    strip.cut_left = @as(f64, @floatFromInt(at_left)) >= share;
    strip.cut_right = @as(f64, @floatFromInt(at_right)) >= share;
    if (!strip.cut_left) strip.left_edge = fitLine(ys[0..left_count], lefts[0..left_count]);
    if (!strip.cut_right) strip.right_edge = fitLine(ys_right[0..right_count], rights[0..right_count]);
}

/// Least squares, then again without the points more than 3 px off: a
/// nick in the film's edge or a sliver of dust should not tilt the line.
fn fitLine(ts: []const f64, ss: []const f64) ?Line {
    var line = fitLineWhere(ts, ss, null, 0.0) orelse return null;
    line = fitLineWhere(ts, ss, line, 3.0) orelse line;
    return line;
}

fn fitLineWhere(ts: []const f64, ss: []const f64, previous: ?Line, reach: f64) ?Line {
    var n: f64 = 0.0;
    var st: f64 = 0.0;
    var ss_sum: f64 = 0.0;
    var stt: f64 = 0.0;
    var sts: f64 = 0.0;
    for (ts, ss) |t, s_value| {
        if (previous) |line| if (@abs(s_value - line.at(t)) > reach) continue;
        n += 1.0;
        st += t;
        ss_sum += s_value;
        stt += t * t;
        sts += t * s_value;
    }
    if (n < 2.0) return null;
    const denominator = n * stt - st * st;
    if (denominator == 0.0) return null;
    const b = (n * sts - st * ss_sum) / denominator;
    return .{ .a = (ss_sum - b * st) / n, .b = b };
}

/// The darkest gray value counted as clear glass: picture, film base, and
/// glass, the first split separating the picture from the rest, the second,
/// among the brighter pixels, the film base from the glass.
pub fn clearThreshold(gray: []const u8) u8 {
    var hist = [_]usize{0} ** 256;
    for (gray) |value| hist[value] += 1;
    const picture_split = otsu(&hist, 0, 255);
    return otsu(&hist, picture_split + 1, 255);
}

/// Otsu's threshold over the histogram's values from `lo` to `hi`: the
/// last value of the darker class.
fn otsu(hist: *const [256]usize, lo: usize, hi: usize) u8 {
    if (lo >= hi) return @intCast(@min(lo, 255));
    var total: f64 = 0.0;
    var sum: f64 = 0.0;
    for (lo..hi + 1) |value| {
        total += @floatFromInt(hist[value]);
        sum += @as(f64, @floatFromInt(value)) * @as(f64, @floatFromInt(hist[value]));
    }
    var best: usize = lo;
    var best_variance: f64 = -1.0;
    var weight: f64 = 0.0;
    var weighted_sum: f64 = 0.0;
    for (lo..hi) |value| {
        weight += @floatFromInt(hist[value]);
        weighted_sum += @as(f64, @floatFromInt(value)) * @as(f64, @floatFromInt(hist[value]));
        const rest = total - weight;
        if (weight == 0.0 or rest == 0.0) continue;
        const mean_dark = weighted_sum / weight;
        const mean_bright = (sum - weighted_sum) / rest;
        const variance = weight * rest * (mean_dark - mean_bright) * (mean_dark - mean_bright);
        if (variance > best_variance) {
            best_variance = variance;
            best = value;
        }
    }
    return @intCast(best);
}

pub const Isolated = struct {
    /// The crop's samples, in the source's layout.
    data: []u8,
    /// The crop's top-left corner in the image; negative where it reaches
    /// past the scan's border.
    x: isize,
    y: isize,
    width: usize,
    height: usize,
    /// For a strip cut by the border, its whole width, length, and angle
    /// (as frames.FilmExtent has them), which its film no longer shows.
    extent: ?struct { across: f64, along: f64, angle: f64 } = null,
};

/// One strip cut out with `margin` pixels of its surroundings, every other
/// strip there painted over with the clear glass's mean color, so frame
/// detection sees a single strip in clear light. A strip whose outer side
/// the scan's border cuts off is centered from its inner edge and
/// `strip_width_px` instead, with clear glass past the border, since frame
/// detection starts from the strip's middle.
pub fn isolate(
    allocator: std.mem.Allocator,
    map: StripMap,
    index: usize,
    gray: []const u8,
    data: []const u8,
    width: usize,
    height: usize,
    samples_per_pixel: usize,
    bits_per_sample: u16,
    margin: usize,
    strip_width_px: ?f64,
) !Isolated {
    const strip = map.strips[index];
    const bytes_per_sample: usize = bits_per_sample / 8;
    const pixel_bytes = samples_per_pixel * bytes_per_sample;
    const margin_i: isize = @intCast(margin);

    var x0: isize = @as(isize, @intCast(strip.x)) - margin_i;
    var x1: isize = @as(isize, @intCast(strip.x + strip.width)) + margin_i;
    const y0: isize = @max(0, @as(isize, @intCast(strip.y)) - margin_i);
    const y1: isize = @min(@as(isize, @intCast(height)), @as(isize, @intCast(strip.y + strip.height)) + margin_i);
    var extent: @FieldType(Isolated, "extent") = null;
    const inner: ?Line = if (strip.cut_left and !strip.cut_right) strip.right_edge else if (strip.cut_right and !strip.cut_left) strip.left_edge else null;
    if (inner != null and strip_width_px != null) {
        const edge = inner.?;
        const strip_width = strip_width_px.?;
        const middle_y = @as(f64, @floatFromInt(y0 + y1)) / 2.0;
        const center = edge.at(middle_y) + (if (strip.cut_left) -strip_width / 2.0 else strip_width / 2.0);
        const tilt = @abs(edge.b) * @as(f64, @floatFromInt(y1 - y0)) / 2.0;
        const half = strip_width / 2.0 + @as(f64, @floatFromInt(margin)) + tilt;
        x0 = @intFromFloat(@round(center - half));
        x1 = @intFromFloat(@round(center + half));
        extent = .{ .across = strip_width, .along = @floatFromInt(strip.height), .angle = -std.math.atan(edge.b) };
    } else {
        x0 = @max(0, x0);
        x1 = @min(@as(isize, @intCast(width)), x1);
    }

    // The clear glass's color, sample by sample, from every clear pixel.
    var clear_sum = [_]f64{0.0} ** 4;
    var clear_count: usize = 0;
    for (gray, 0..) |value, pixel| {
        if (value <= map.clear_threshold) continue;
        clear_count += 1;
        for (0..samples_per_pixel) |sample| clear_sum[sample] += sampleAt(data, pixel * samples_per_pixel + sample, bits_per_sample);
    }
    var clear_pixel = [_]u8{0} ** 8;
    for (0..samples_per_pixel) |sample| {
        const max_value: f64 = if (bits_per_sample == 16) 65535.0 else 255.0;
        const value = if (clear_count > 0) clear_sum[sample] / @as(f64, @floatFromInt(clear_count)) else max_value;
        writeSample(clear_pixel[sample * bytes_per_sample ..], @intFromFloat(@round(value)), bits_per_sample);
    }

    const crop_width: usize = @intCast(x1 - x0);
    const crop_height: usize = @intCast(y1 - y0);
    // Other strips' film in the crop, grown by two pixels so their
    // anti-aliased edges go too; everything past the border is clear.
    const is_other = try allocator.alloc(bool, maxLabel(map) + 1);
    defer allocator.free(is_other);
    @memset(is_other, false);
    for (map.strips) |other| is_other[other.label] = other.label != strip.label;
    const paint = try allocator.alloc(bool, crop_width * crop_height);
    defer allocator.free(paint);
    for (0..crop_height) |row| {
        for (0..crop_width) |column| {
            const x = x0 + @as(isize, @intCast(column));
            const y = y0 + @as(isize, @intCast(row));
            const inside = x >= 0 and x < width and y >= 0 and y < height;
            paint[row * crop_width + column] = inside and is_other[map.labels[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))]];
        }
    }
    try grow(allocator, paint, crop_width, crop_height, 2);

    const out = try allocator.alloc(u8, crop_width * crop_height * pixel_bytes);
    for (0..crop_height) |row| {
        for (0..crop_width) |column| {
            const target = out[(row * crop_width + column) * pixel_bytes ..][0..pixel_bytes];
            const x = x0 + @as(isize, @intCast(column));
            const y = y0 + @as(isize, @intCast(row));
            const inside = x >= 0 and x < width and y >= 0 and y < height;
            if (!inside or paint[row * crop_width + column]) {
                @memcpy(target, clear_pixel[0..pixel_bytes]);
            } else {
                @memcpy(target, data[(@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))) * pixel_bytes ..][0..pixel_bytes]);
            }
        }
    }
    return .{ .data = out, .x = x0, .y = y0, .width = crop_width, .height = crop_height, .extent = extent };
}

fn maxLabel(map: StripMap) u32 {
    var max: u32 = 0;
    for (map.labels) |label| max = @max(max, label);
    return max;
}

/// Grows a mask by `reach` pixels each way (a square), rows then columns.
fn grow(allocator: std.mem.Allocator, mask: []bool, width: usize, height: usize, reach: usize) !void {
    const temp = try allocator.alloc(bool, mask.len);
    defer allocator.free(temp);
    for (0..height) |y| {
        for (0..width) |x| {
            var any = false;
            for ((x -| reach)..@min(width, x + reach + 1)) |nx| any = any or mask[y * width + nx];
            temp[y * width + x] = any;
        }
    }
    for (0..height) |y| {
        for (0..width) |x| {
            var any = false;
            for ((y -| reach)..@min(height, y + reach + 1)) |ny| any = any or temp[ny * width + x];
            mask[y * width + x] = any;
        }
    }
}

fn sampleAt(data: []const u8, index: usize, bits_per_sample: u16) f64 {
    if (bits_per_sample == 16) return @floatFromInt(std.mem.readInt(u16, data[index * 2 ..][0..2], .little));
    return @floatFromInt(data[index]);
}

fn writeSample(out: []u8, value: u16, bits_per_sample: u16) void {
    if (bits_per_sample == 16) {
        std.mem.writeInt(u16, out[0..2], value, .little);
    } else {
        out[0] = @intCast(@min(value, 255));
    }
}

test "two strips side by side are found apart and ordered across" {
    const allocator = std.testing.allocator;
    const width = 60;
    const height = 200;
    var gray = [_]u8{255} ** (width * height);
    // Strips at x 2..26 and 30..56, rows 10..190, with picture and base.
    for (10..190) |y| {
        for (2..27) |x| gray[y * width + x] = if ((y / 20) % 2 == 0) 40 else 180;
        for (30..57) |x| gray[y * width + x] = if ((y / 25) % 2 == 0) 60 else 170;
    }
    var map = try find(allocator, &gray, width, height, null);
    defer map.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), map.strips.len);
    try std.testing.expectEqual(@as(usize, 2), map.strips[0].x);
    try std.testing.expectEqual(@as(usize, 30), map.strips[1].x);
    try std.testing.expectEqual(@as(usize, 180), map.strips[0].height);
}
