//! Worker counts and row-band threads for the processing modules' parallel
//! passes.
const std = @import("std");

pub fn workerCountForItems(item_count: usize, min_items: usize) usize {
    if (item_count < min_items) return 1;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    if (cpu_count <= 1) return 1;
    return @min(cpu_count - 1, item_count);
}

const row_band_min_rows: usize = 64;

/// Runs `work(context, row_start, row_end)` over bands of rows, one thread per
/// band, for passes whose rows are independent of each other.
pub fn forRowBands(
    allocator: std.mem.Allocator,
    height: usize,
    context: anytype,
    comptime work: fn (@TypeOf(context), usize, usize) void,
) !void {
    const worker_count = rowBandWorkerCount(height);
    if (worker_count <= 1) {
        work(context, 0, height);
        return;
    }
    const Band = struct {
        context: @TypeOf(context),
        row_start: usize,
        row_end: usize,

        fn run(band: *const @This()) void {
            work(band.context, band.row_start, band.row_end);
        }
    };
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);
    const bands = try allocator.alloc(Band, worker_count);
    defer allocator.free(bands);
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (0..worker_count) |worker| {
        bands[worker] = .{
            .context = context,
            .row_start = height * worker / worker_count,
            .row_end = height * (worker + 1) / worker_count,
        };
        threads[worker] = try std.Thread.spawn(.{}, Band.run, .{&bands[worker]});
        started += 1;
    }
    for (threads) |thread| thread.join();
}

fn rowBandWorkerCount(height: usize) usize {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    if (cpu_count <= 1) return 1;
    return @max(1, @min(cpu_count - 1, height / row_band_min_rows));
}
