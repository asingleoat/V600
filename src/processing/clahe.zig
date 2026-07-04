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
    if (parallelism.enabled and pixel_count >= clahe_parallel_min_pixels) {
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
    if (parallelism.enabled and pixel_count >= clahe_parallel_min_pixels) {
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
