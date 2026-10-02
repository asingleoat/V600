//! Native helper boundary for IR processing: the OpenCV/SuperLU extern
//! declarations that only link on libc builds, the availability switch, and
//! the pure-Zig fallback wiring used by freestanding/no-libc targets.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const ir_pure = @import("ir_pure.zig");

pub const available = !builtin.cpu.arch.isWasm() and build_options.native_libs;

pub extern fn v600_estimate_local_grain(
    roi_rgb: [*]const f64,
    roi_mask: [*]const u8,
    width: c_int,
    height: c_int,
    grain_padding: c_int,
    grain_sigma: f64,
    grain_std: [*]f64,
    signal_out: [*]f64,
    spectrum_out: [*]f64,
    spectrum_capacity: c_int,
    spectrum_len: *c_int,
    has_spectrum: *c_int,
) c_int;

pub extern fn v600_synthesize_grain_from_noise(
    noise: [*]const f64,
    width: c_int,
    height: c_int,
    grain_std: [*]const f64,
    grain_spectrum: ?[*]const f64,
    spectrum_len: c_int,
    channels: c_int,
    output: [*]f64,
) c_int;

extern fn v600_solve_sparse_lu(
    n: usize,
    row_offsets: [*]const usize,
    columns: [*]const usize,
    values: [*]const f64,
    nnz: usize,
    channels: usize,
    rhs: [*]const f64,
    output: [*]f64,
) c_int;

pub fn solveSparseLu(
    n: usize,
    row_offsets: [*]const usize,
    columns: [*]const usize,
    values: [*]const f64,
    nnz: usize,
    channels: usize,
    rhs: [*]const f64,
    output: [*]f64,
) c_int {
    if (available) {
        return v600_solve_sparse_lu(n, row_offsets, columns, values, nnz, channels, rhs, output);
    }
    // There is no pure SuperLU port: report failure so the biharmonic solver
    // falls back to its pure iterative path.
    return 1;
}

// ECC runs at 1/8 scale with OpenCV findTransformECC's iteration limits,
// which the earlier OpenCV helper used.
const pure_ecc_scale: f64 = 0.125;
const pure_ecc_max_iterations: u32 = 200;
const pure_ecc_epsilon: f64 = 1.0e-6;

/// IR-to-RGB translation for alignment, in Zig on every target (the OpenCV
/// helper indexed with 32-bit ints and overran on strips past 2^31 samples).
pub fn estimateTranslationEcc(
    allocator: std.mem.Allocator,
    rgb: []const f64,
    rgb_width: usize,
    rgb_height: usize,
    ir: []const f64,
    ir_width: usize,
    ir_height: usize,
) !ir_pure.TranslationEstimate {
    return ir_pure.estimateTranslationEcc(
        f64,
        allocator,
        rgb,
        rgb_width,
        rgb_height,
        ir,
        ir_width,
        ir_height,
        pure_ecc_scale,
        pure_ecc_max_iterations,
        pure_ecc_epsilon,
    );
}
