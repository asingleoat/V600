//! Comptime switch for the std.Thread-based parallel paths in the processing
//! modules. Freestanding Wasm is single-threaded; referencing this constant in
//! branch conditions keeps the thread-spawning code out of semantic analysis
//! for Wasm targets, so it must stay comptime-known.
const builtin = @import("builtin");

pub const enabled = !builtin.cpu.arch.isWasm();
