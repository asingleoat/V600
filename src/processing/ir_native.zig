//! Native helper boundary for IR processing: the OpenCV/SuperLU extern
//! declarations that only link on libc builds, the availability switch, and
//! the pure-Zig fallback wiring used by freestanding/no-libc targets.

const std = @import("std");
const builtin = @import("builtin");

const ir_pure = @import("ir_pure.zig");

pub const available = !builtin.cpu.arch.isWasm() and builtin.link_libc;

pub extern fn v600_align_ir_find_ecc_translation(
    rgb: [*]const f64,
    rgb_width: c_int,
    rgb_height: c_int,
    ir: [*]const f64,
    ir_width: c_int,
    ir_height: c_int,
    tx: *f64,
    ty: *f64,
) c_int;

pub extern fn v600_estimate_local_grain(
    roi_rgb: [*]const f64,
    roi_mask: [*]const u8,
    width: c_int,
    height: c_int,
    grain_padding: c_int,
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

// Matches the opencv_ecc.cpp constants so the pure-Zig fallback estimates the
// same translation shape as the native OpenCV helper.
const pure_ecc_scale: f64 = 0.125;
const pure_ecc_max_iterations: u32 = 200;
const pure_ecc_epsilon: f64 = 1.0e-6;

pub fn estimateTranslationEccPure(
    allocator: std.mem.Allocator,
    rgb: []const f64,
    rgb_width: usize,
    rgb_height: usize,
    ir: []const f64,
    ir_width: usize,
    ir_height: usize,
) !ir_pure.TranslationEstimate {
    const rgb_f32 = try allocator.alloc(f32, rgb.len);
    defer allocator.free(rgb_f32);
    for (rgb, rgb_f32) |value, *out| out.* = @floatCast(value);
    const ir_f32 = try allocator.alloc(f32, ir.len);
    defer allocator.free(ir_f32);
    for (ir, ir_f32) |value, *out| out.* = @floatCast(value);
    return ir_pure.estimateTranslationEccF32(
        allocator,
        rgb_f32,
        rgb_width,
        rgb_height,
        ir_f32,
        ir_width,
        ir_height,
        pure_ecc_scale,
        pure_ecc_max_iterations,
        pure_ecc_epsilon,
    );
}
