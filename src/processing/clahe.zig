//! CLAHE (contrast-limited adaptive histogram equalization) for the frame
//! detector, ported from the Python oracle: tile LUT construction, reflected
//! index maps, and bilinear LUT interpolation output.

const std = @import("std");
const parallelism = @import("parallelism.zig");

const workerCountForItems = parallelism.workerCountForItems;

pub const clahe_parallel_min_pixels: usize = 1_000_000;
pub const ClaheAxisMap = struct {
    first: []usize,
    second: []usize,
    fraction: []f64,
    inverse_fraction: []f64,

    fn deinit(self: *ClaheAxisMap, allocator: std.mem.Allocator) void {
        allocator.free(self.first);
        allocator.free(self.second);
        allocator.free(self.fraction);
        allocator.free(self.inverse_fraction);
        self.* = undefined;
    }
};

pub const ClaheOutputRowsContext = struct {
    input: []const u8,
    output: []u8,
    width: usize,
    tiles_x: usize,
    luts: []const u8,
    x_map: ClaheAxisMap,
    y_map: ClaheAxisMap,
    y_start: usize,
    y_end: usize,
};

pub const ClaheLutTilesContext = struct {
    input: []const u8,
    luts: []u8,
    reflect_x: []const usize,
    reflect_y: []const usize,
    width: usize,
    tile_width: usize,
    tile_height: usize,
    tiles_x: usize,
    clip_limit: usize,
    lut_scale: f64,
    tile_start: usize,
    tile_end: usize,
};

pub const ClaheOptions = struct {
    clip_limit: f64 = 3.0,
    tiles_x: usize = 8,
    tiles_y: usize = 8,
};

pub fn applyClahe8(
    allocator: std.mem.Allocator,
    input: []const u8,
    width: usize,
    height: usize,
    options: ClaheOptions,
) ![]u8 {
    if (width == 0 or height == 0 or input.len != width * height) return error.InvalidClaheInput;
    if (options.tiles_x == 0 or options.tiles_y == 0 or !std.math.isFinite(options.clip_limit)) return error.InvalidClaheInput;

    const tile_width = ceilDiv(width, options.tiles_x);
    const tile_height = ceilDiv(height, options.tiles_y);
    const ext_width = tile_width * options.tiles_x;
    const ext_height = tile_height * options.tiles_y;
    const tile_area = tile_width * tile_height;
    const pixel_count = try std.math.mul(usize, width, height);

    const reflect_x = try buildReflectIndexMap(allocator, ext_width, width);
    defer allocator.free(reflect_x);
    const reflect_y = try buildReflectIndexMap(allocator, ext_height, height);
    defer allocator.free(reflect_y);

    const luts = try allocator.alloc(u8, options.tiles_x * options.tiles_y * 256);
    defer allocator.free(luts);
    const clip_limit = claheClipLimit(options.clip_limit, tile_area);
    const lut_scale = 255.0 / @as(f64, @floatFromInt(tile_area));
    if (pixel_count >= clahe_parallel_min_pixels) {
        const worker_count = @min(workerCountForItems(pixel_count, clahe_parallel_min_pixels), options.tiles_x * options.tiles_y);
        if (worker_count > 1) {
            try buildClahe8LutsParallel(allocator, input, luts, reflect_x, reflect_y, width, tile_width, tile_height, options.tiles_x, options.tiles_y, clip_limit, lut_scale, worker_count);
        } else {
            buildClahe8LutTiles(input, luts, reflect_x, reflect_y, width, tile_width, tile_height, options.tiles_x, clip_limit, lut_scale, 0, options.tiles_x * options.tiles_y);
        }
    } else {
        buildClahe8LutTiles(input, luts, reflect_x, reflect_y, width, tile_width, tile_height, options.tiles_x, clip_limit, lut_scale, 0, options.tiles_x * options.tiles_y);
    }

    const output = try allocator.alloc(u8, width * height);
    errdefer allocator.free(output);
    var x_map = try buildClaheAxisMap(allocator, width, tile_width, options.tiles_x);
    defer x_map.deinit(allocator);
    var y_map = try buildClaheAxisMap(allocator, height, tile_height, options.tiles_y);
    defer y_map.deinit(allocator);
    if (pixel_count >= clahe_parallel_min_pixels) {
        const cpu_count = std.Thread.getCpuCount() catch 1;
        const worker_limit = if (cpu_count > 1) cpu_count - 1 else 1;
        const worker_count = @min(worker_limit, height);
        if (worker_count > 1) {
            try applyClahe8OutputParallel(allocator, input, output, width, height, options.tiles_x, luts, x_map, y_map, worker_count);
            return output;
        }
    }
    applyClahe8OutputRows(input, output, width, options.tiles_x, luts, x_map, y_map, 0, height);
    return output;
}

pub fn buildClahe8LutsParallel(
    allocator: std.mem.Allocator,
    input: []const u8,
    luts: []u8,
    reflect_x: []const usize,
    reflect_y: []const usize,
    width: usize,
    tile_width: usize,
    tile_height: usize,
    tiles_x: usize,
    tiles_y: usize,
    clip_limit: usize,
    lut_scale: f64,
    worker_count: usize,
) !void {
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(ClaheLutTilesContext, worker_count);
    defer allocator.free(contexts);
    const tile_count = tiles_x * tiles_y;
    var started: usize = 0;
    errdefer {
        for (threads[0..started]) |thread| {
            thread.join();
        }
    }
    for (0..worker_count) |worker_index| {
        const tile_start = tile_count * worker_index / worker_count;
        const tile_end = tile_count * (worker_index + 1) / worker_count;
        contexts[worker_index] = .{
            .input = input,
            .luts = luts,
            .reflect_x = reflect_x,
            .reflect_y = reflect_y,
            .width = width,
            .tile_width = tile_width,
            .tile_height = tile_height,
            .tiles_x = tiles_x,
            .clip_limit = clip_limit,
            .lut_scale = lut_scale,
            .tile_start = tile_start,
            .tile_end = tile_end,
        };
        threads[worker_index] = try std.Thread.spawn(.{}, buildClahe8LutsWorker, .{&contexts[worker_index]});
        started += 1;
    }
    for (threads) |thread| {
        thread.join();
    }
}

pub fn buildClahe8LutsWorker(context: *const ClaheLutTilesContext) void {
    buildClahe8LutTiles(
        context.input,
        context.luts,
        context.reflect_x,
        context.reflect_y,
        context.width,
        context.tile_width,
        context.tile_height,
        context.tiles_x,
        context.clip_limit,
        context.lut_scale,
        context.tile_start,
        context.tile_end,
    );
}

pub fn buildClahe8LutTiles(
    input: []const u8,
    luts: []u8,
    reflect_x: []const usize,
    reflect_y: []const usize,
    width: usize,
    tile_width: usize,
    tile_height: usize,
    tiles_x: usize,
    clip_limit: usize,
    lut_scale: f64,
    tile_start: usize,
    tile_end: usize,
) void {
    for (tile_start..tile_end) |tile_index| {
        const tile_y = tile_index / tiles_x;
        const tile_x = tile_index % tiles_x;
        var hist = [_]usize{0} ** 256;
        const start_x = tile_x * tile_width;
        const start_y = tile_y * tile_height;
        for (0..tile_height) |yy| {
            const source_y = reflect_y[start_y + yy];
            const source_row = input[source_y * width ..][0..width];
            for (0..tile_width) |xx| {
                hist[source_row[reflect_x[start_x + xx]]] += 1;
            }
        }
        if (clip_limit > 0) {
            clipHistogram(&hist, clip_limit);
        }
        const lut_offset = tile_index * 256;
        var sum: usize = 0;
        for (hist, 0..) |count, bin| {
            sum += count;
            luts[lut_offset + bin] = saturateRoundU8(@as(f64, @floatFromInt(sum)) * lut_scale);
        }
    }
}

pub fn applyClahe8OutputParallel(
    allocator: std.mem.Allocator,
    input: []const u8,
    output: []u8,
    width: usize,
    height: usize,
    tiles_x: usize,
    luts: []const u8,
    x_map: ClaheAxisMap,
    y_map: ClaheAxisMap,
    worker_count: usize,
) !void {
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const contexts = try allocator.alloc(ClaheOutputRowsContext, worker_count);
    defer allocator.free(contexts);
    var started: usize = 0;
    errdefer {
        for (threads[0..started]) |thread| {
            thread.join();
        }
    }
    for (0..worker_count) |worker_index| {
        const y_start = height * worker_index / worker_count;
        const y_end = height * (worker_index + 1) / worker_count;
        contexts[worker_index] = .{
            .input = input,
            .output = output,
            .width = width,
            .tiles_x = tiles_x,
            .luts = luts,
            .x_map = x_map,
            .y_map = y_map,
            .y_start = y_start,
            .y_end = y_end,
        };
        threads[worker_index] = try std.Thread.spawn(.{}, applyClahe8OutputWorker, .{&contexts[worker_index]});
        started += 1;
    }
    for (threads) |thread| {
        thread.join();
    }
}

pub fn applyClahe8OutputWorker(context: *const ClaheOutputRowsContext) void {
    applyClahe8OutputRows(
        context.input,
        context.output,
        context.width,
        context.tiles_x,
        context.luts,
        context.x_map,
        context.y_map,
        context.y_start,
        context.y_end,
    );
}

pub fn applyClahe8OutputRows(
    input: []const u8,
    output: []u8,
    width: usize,
    tiles_x: usize,
    luts: []const u8,
    x_map: ClaheAxisMap,
    y_map: ClaheAxisMap,
    y_start: usize,
    y_end: usize,
) void {
    for (y_start..y_end) |y| {
        const ty1_base = y_map.first[y] * tiles_x * 256;
        const ty2_base = y_map.second[y] * tiles_x * 256;
        const ya = y_map.fraction[y];
        const ya1 = y_map.inverse_fraction[y];
        const input_row = input[y * width ..][0..width];
        const output_row = output[y * width ..][0..width];
        for (0..width) |x| {
            const xa = x_map.fraction[x];
            const xa1 = x_map.inverse_fraction[x];
            const value = input_row[x];
            const tx1_offset = x_map.first[x] * 256 + value;
            const tx2_offset = x_map.second[x] * 256 + value;
            const lut11 = luts[ty1_base + tx1_offset];
            const lut12 = luts[ty1_base + tx2_offset];
            const lut21 = luts[ty2_base + tx1_offset];
            const lut22 = luts[ty2_base + tx2_offset];
            const top = @as(f64, @floatFromInt(lut11)) * xa1 + @as(f64, @floatFromInt(lut12)) * xa;
            const bottom = @as(f64, @floatFromInt(lut21)) * xa1 + @as(f64, @floatFromInt(lut22)) * xa;
            output_row[x] = saturateRoundU8(top * ya1 + bottom * ya);
        }
    }
}

pub fn reflect101Index(index: i32, len: usize) usize {
    if (len <= 1) return 0;
    const n: i32 = @intCast(len);
    var reflected = index;
    while (reflected < 0 or reflected >= n) {
        if (reflected < 0) {
            reflected = -reflected;
        } else {
            reflected = 2 * n - reflected - 2;
        }
    }
    return @intCast(reflected);
}

pub fn buildReflectIndexMap(allocator: std.mem.Allocator, extended_len: usize, source_len: usize) ![]usize {
    if (extended_len == 0 or source_len == 0) return error.InvalidClaheInput;
    const map = try allocator.alloc(usize, extended_len);
    errdefer allocator.free(map);
    for (map, 0..) |*value, index| {
        value.* = reflect101Index(@intCast(index), source_len);
    }
    return map;
}

pub fn buildClaheAxisMap(
    allocator: std.mem.Allocator,
    length: usize,
    tile_size: usize,
    tile_count: usize,
) !ClaheAxisMap {
    if (length == 0 or tile_size == 0 or tile_count == 0) return error.InvalidClaheInput;
    var map = ClaheAxisMap{
        .first = try allocator.alloc(usize, length),
        .second = try allocator.alloc(usize, length),
        .fraction = try allocator.alloc(f64, length),
        .inverse_fraction = try allocator.alloc(f64, length),
    };
    errdefer map.deinit(allocator);

    const inv_tile_size = 1.0 / @as(f64, @floatFromInt(tile_size));
    for (0..length) |index| {
        const tf = @as(f64, @floatFromInt(index)) * inv_tile_size - 0.5;
        const first_raw: isize = @intFromFloat(@floor(tf));
        const second_raw = first_raw + 1;
        const frac = tf - @as(f64, @floatFromInt(first_raw));
        map.first[index] = clampTileIndex(first_raw, tile_count);
        map.second[index] = clampTileIndex(second_raw, tile_count);
        map.fraction[index] = frac;
        map.inverse_fraction[index] = 1.0 - frac;
    }
    return map;
}

pub fn ceilDiv(numerator: usize, denominator: usize) usize {
    return (numerator + denominator - 1) / denominator;
}

pub fn claheClipLimit(clip_limit: f64, tile_area: usize) usize {
    if (clip_limit <= 0.0) return 0;
    const raw: usize = @intFromFloat(clip_limit * @as(f64, @floatFromInt(tile_area)) / 256.0);
    return @max(@as(usize, 1), raw);
}

pub fn clipHistogram(hist: *[256]usize, clip_limit: usize) void {
    var clipped: usize = 0;
    for (hist) |*count| {
        if (count.* > clip_limit) {
            clipped += count.* - clip_limit;
            count.* = clip_limit;
        }
    }
    const redist_batch = clipped / 256;
    const residual_count = clipped - redist_batch * 256;
    for (hist) |*count| {
        count.* += redist_batch;
    }
    if (residual_count == 0) return;
    const residual_step = @max(@as(usize, 1), 256 / residual_count);
    var residual = residual_count;
    var index: usize = 0;
    while (index < 256 and residual > 0) : (index += residual_step) {
        hist[index] += 1;
        residual -= 1;
    }
}

pub fn clampTileIndex(index: isize, tile_count: usize) usize {
    if (index <= 0) return 0;
    const value: usize = @intCast(index);
    return @min(value, tile_count - 1);
}

pub fn saturateRoundU8(value: f64) u8 {
    if (value <= 0.0) return 0;
    if (value >= 255.0) return 255;
    return @intFromFloat(@floor(value + 0.5));
}

/// OpenCV's CLAHE (`createCLAHE(clip_limit, tiles).apply`) on each channel
/// of interleaved 8-bit pixels, in place, as OpenCV computes it: when either
/// side does not divide into the tiles it pads both (reflect-101) to the
/// next multiple, which changes the tile size even on a side that divided
/// evenly, and it builds the lookup tables and interpolates in f32, rounding
/// half to even. The quick preview's display uses this; the frame detector
/// keeps `applyClahe8`, which it was tuned on.
pub fn claheOpenCvInPlace(
    allocator: std.mem.Allocator,
    pixels: []u8,
    width: usize,
    height: usize,
    channels: usize,
    clip_limit: f64,
    tiles_x: usize,
    tiles_y: usize,
) !void {
    if (width == 0 or height == 0 or channels == 0 or channels > max_opencv_channels or pixels.len != width * height * channels) return error.InvalidClaheInput;
    if (tiles_x == 0 or tiles_y == 0 or tiles_x > max_opencv_tiles_x) return error.InvalidClaheInput;
    const padded = width % tiles_x != 0 or height % tiles_y != 0;
    const ext_width = if (padded) width + tiles_x - width % tiles_x else width;
    const ext_height = if (padded) height + tiles_y - height % tiles_y else height;
    const tile_width = ext_width / tiles_x;
    const tile_height = ext_height / tiles_y;
    const tile_area = tile_width * tile_height;

    const reflect_x = try buildReflectIndexMap(allocator, ext_width, width);
    defer allocator.free(reflect_x);
    const reflect_y = try buildReflectIndexMap(allocator, ext_height, height);
    defer allocator.free(reflect_y);
    const columns = try allocator.alloc(TilePosition, width);
    defer allocator.free(columns);
    const inv_tile_width = 1.0 / @as(f32, @floatFromInt(tile_width));
    for (columns, 0..) |*column, x| column.* = tilePosition(x, inv_tile_width, tiles_x);

    // Tables by tile, then value, then channel.
    const luts = try allocator.alloc(u8, tiles_x * tiles_y * 256 * channels);
    defer allocator.free(luts);
    const context = OpenCvClahe{
        .pixels = pixels,
        .width = width,
        .channels = channels,
        .reflect_x = reflect_x,
        .reflect_y = reflect_y,
        .tile_width = tile_width,
        .tile_height = tile_height,
        .tiles_x = tiles_x,
        .tiles_y = tiles_y,
        .clip = claheClipLimit(clip_limit, tile_area),
        .lut_scale = 255.0 / @as(f32, @floatFromInt(tile_area)),
        .luts = luts,
        .columns = columns,
        .inv_tile_height = 1.0 / @as(f32, @floatFromInt(tile_height)),
    };
    // Every table first: each output sample then depends only on its own
    // input value, so the pixels can be rewritten in place.
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const lut_workers = @max(1, @min(cpu_count -| 1, tiles_y));
    if (lut_workers == 1 or width * height < clahe_parallel_min_pixels) {
        context.tileRows(0, tiles_y);
    } else {
        const threads = try allocator.alloc(std.Thread, lut_workers);
        defer allocator.free(threads);
        var started: usize = 0;
        defer for (threads[0..started]) |thread| thread.join();
        for (0..lut_workers) |worker| {
            threads[worker] = try std.Thread.spawn(.{}, OpenCvClahe.tileRows, .{ &context, tiles_y * worker / lut_workers, tiles_y * (worker + 1) / lut_workers });
            started += 1;
        }
    }
    try parallelism.forRowBands(allocator, height, &context, OpenCvClahe.rows);
}

const max_opencv_tiles_x = 64;
const max_opencv_channels = 4;

const OpenCvClahe = struct {
    pixels: []u8,
    width: usize,
    channels: usize,
    reflect_x: []const usize,
    reflect_y: []const usize,
    tile_width: usize,
    tile_height: usize,
    tiles_x: usize,
    tiles_y: usize,
    clip: usize,
    lut_scale: f32,
    luts: []u8,
    columns: []const TilePosition,
    inv_tile_height: f32,

    fn tileRows(self: *const OpenCvClahe, tile_y_start: usize, tile_y_end: usize) void {
        const channels = self.channels;
        for (tile_y_start..tile_y_end) |tile_y| {
            var hists = [_][256]u32{[_]u32{0} ** 256} ** (max_opencv_tiles_x * max_opencv_channels);
            for (self.reflect_y[tile_y * self.tile_height ..][0..self.tile_height]) |source_y| {
                const row = self.pixels[source_y * self.width * channels ..][0 .. self.width * channels];
                for (0..self.tiles_x) |tile_x| {
                    const tile_hists = hists[tile_x * channels ..][0..channels];
                    const start = tile_x * self.tile_width;
                    const end = start + self.tile_width;
                    for (@min(start, self.width)..@min(end, self.width)) |x| {
                        for (tile_hists, row[x * channels ..][0..channels]) |*hist, value| hist[value] += 1;
                    }
                    // Columns past the image's edge come from the reflection.
                    if (end > self.width) {
                        for (self.reflect_x[@max(start, self.width)..end]) |x| {
                            for (tile_hists, row[x * channels ..][0..channels]) |*hist, value| hist[value] += 1;
                        }
                    }
                }
            }
            for (0..self.tiles_x) |tile_x| {
                const lut = self.luts[(tile_y * self.tiles_x + tile_x) * 256 * channels ..][0 .. 256 * channels];
                for (hists[tile_x * channels ..][0..channels], 0..) |*hist, channel| {
                    if (self.clip > 0) clipHistogram32(hist, self.clip);
                    var sum: u32 = 0;
                    for (hist, 0..) |count, value| {
                        sum += count;
                        lut[value * channels + channel] = roundHalfEvenU8(@as(f32, @floatFromInt(sum)) * self.lut_scale);
                    }
                }
            }
        }
    }

    fn rows(self: *const OpenCvClahe, row_start: usize, row_end: usize) void {
        const channels = self.channels;
        const plane_len = 256 * channels;
        for (row_start..row_end) |y| {
            const ty = tilePosition(y, self.inv_tile_height, self.tiles_y);
            const plane1 = self.luts[ty.first * self.tiles_x * plane_len ..];
            const plane2 = self.luts[ty.second * self.tiles_x * plane_len ..];
            const row = self.pixels[y * self.width * channels ..][0 .. self.width * channels];
            for (self.columns, 0..) |tx, x| {
                const first = tx.first * plane_len;
                const second = tx.second * plane_len;
                for (row[x * channels ..][0..channels], 0..) |*out, channel| {
                    const entry = @as(usize, out.*) * channels + channel;
                    const top = @as(f32, @floatFromInt(plane1[first + entry])) * tx.weight_first + @as(f32, @floatFromInt(plane1[second + entry])) * tx.weight_second;
                    const bottom = @as(f32, @floatFromInt(plane2[first + entry])) * tx.weight_first + @as(f32, @floatFromInt(plane2[second + entry])) * tx.weight_second;
                    out.* = roundHalfEvenU8(top * ty.weight_first + bottom * ty.weight_second);
                }
            }
        }
    }
};

fn clipHistogram32(hist: *[256]u32, clip_limit: usize) void {
    var wide: [256]usize = undefined;
    for (hist, &wide) |count, *value| value.* = count;
    clipHistogram(&wide, clip_limit);
    for (wide, hist) |value, *count| count.* = @intCast(value);
}

const TilePosition = struct { first: usize, second: usize, weight_first: f32, weight_second: f32 };

fn tilePosition(index: usize, inv_tile_size: f32, tile_count: usize) TilePosition {
    const position = @as(f32, @floatFromInt(index)) * inv_tile_size - 0.5;
    const first: isize = @intFromFloat(@floor(position));
    const fraction = position - @as(f32, @floatFromInt(first));
    return .{
        .first = clampTileIndex(first, tile_count),
        .second = clampTileIndex(first + 1, tile_count),
        .weight_first = 1.0 - fraction,
        .weight_second = fraction,
    };
}

fn roundHalfEvenU8(value: f32) u8 {
    if (value <= 0.0) return 0;
    if (value >= 255.0) return 255;
    const floor = @floor(value);
    const fraction = value - floor;
    const whole: u8 = @intFromFloat(floor);
    if (fraction > 0.5 or (fraction == 0.5 and whole & 1 == 1)) return whole + 1;
    return whole;
}
