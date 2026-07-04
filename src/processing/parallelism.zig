//! Comptime switch for the std.Thread-based parallel paths in the processing
//! modules. Freestanding Wasm is single-threaded; referencing this constant in
//! branch conditions keeps the thread-spawning code out of semantic analysis
//! for Wasm targets, so it must stay comptime-known.
const std = @import("std");
const builtin = @import("builtin");

pub const enabled = !builtin.cpu.arch.isWasm();

pub fn workerCountForItems(item_count: usize, min_items: usize) usize {
    if (!enabled) return 1;
    if (item_count < min_items) return 1;
    const cpu_count = std.Thread.getCpuCount() catch 1;
    if (cpu_count <= 1) return 1;
    return @min(cpu_count - 1, item_count);
}
