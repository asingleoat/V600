const std = @import("std");
const core = @import("wasm/core.zig");

pub const PreviewOptions = core.PreviewOptions;
pub const IrMaskOptions = core.IrMaskOptions;
pub const IrMaskResizeOptions = core.IrMaskResizeOptions;
pub const IrInpaintOptions = core.IrInpaintOptions;
pub const IrInpaintGrainOptions = core.IrInpaintGrainOptions;
pub const IrAlignOptions = core.IrAlignOptions;
pub const IrEstimateOptions = core.IrEstimateOptions;
pub const IrEstimateResult = core.IrEstimateResult;
pub const FrameDetectOptions = core.FrameDetectOptions;
pub const FrameDetectRect = core.FrameDetectRect;
pub const FrameDetectResult = core.FrameDetectResult;

export fn v600_wasm_pointer_bits() u32 {
    return @bitSizeOf(usize);
}

export fn v600_wasm_alloc(len: usize) usize {
    return core.v600_wasm_alloc(len);
}

export fn v600_wasm_free(ptr_addr: usize, len: usize) void {
    core.v600_wasm_free(ptr_addr, len);
}

export fn v600_preview_invert_u16_to_u8(
    raw_ptr: [*]const u16,
    raw_len: usize,
    output_ptr: [*]u8,
    output_len: usize,
    options_ptr: *const PreviewOptions,
) i32 {
    return core.v600_preview_invert_u16_to_u8(raw_ptr, raw_len, output_ptr, output_len, options_ptr);
}

export fn v600_export_invert_u16_to_u16(
    raw_ptr: [*]const u16,
    raw_len: usize,
    output_ptr: [*]u16,
    output_len: usize,
    options_ptr: *const PreviewOptions,
) i32 {
    return core.v600_export_invert_u16_to_u16(raw_ptr, raw_len, output_ptr, output_len, options_ptr);
}

export fn v600_ir_make_defect_mask_u8(
    ir_ptr: [*]const u8,
    ir_len: usize,
    output_ptr: [*]u8,
    output_len: usize,
    options_ptr: *const IrMaskOptions,
) i32 {
    return core.v600_ir_make_defect_mask_u8(ir_ptr, ir_len, output_ptr, output_len, options_ptr);
}

export fn v600_ir_make_defect_mask_f32(
    ir_ptr: [*]const f32,
    ir_len: usize,
    output_ptr: [*]u8,
    output_len: usize,
    options_ptr: *const IrMaskOptions,
) i32 {
    return core.v600_ir_make_defect_mask_f32(ir_ptr, ir_len, output_ptr, output_len, options_ptr);
}

export fn v600_ir_resize_mask_to_rgb_u8(
    ir_mask_ptr: [*]const u8,
    ir_mask_len: usize,
    output_ptr: [*]u8,
    output_len: usize,
    options_ptr: *const IrMaskResizeOptions,
) i32 {
    return core.v600_ir_resize_mask_to_rgb_u8(ir_mask_ptr, ir_mask_len, output_ptr, output_len, options_ptr);
}

export fn v600_ir_biharmonic_inpaint_u16(
    rgb_ptr: [*]const u16,
    rgb_len: usize,
    mask_ptr: [*]const u8,
    mask_len: usize,
    output_ptr: [*]u16,
    output_len: usize,
    options_ptr: *const IrInpaintOptions,
) i32 {
    return core.v600_ir_biharmonic_inpaint_u16(rgb_ptr, rgb_len, mask_ptr, mask_len, output_ptr, output_len, options_ptr);
}

export fn v600_ir_inpaint_grain_u16_with_noise(
    rgb_ptr: [*]const u16,
    rgb_len: usize,
    mask_ptr: [*]const u8,
    mask_len: usize,
    noise_ptr: [*]const f64,
    noise_len: usize,
    output_ptr: [*]u16,
    output_len: usize,
    options_ptr: *const IrInpaintGrainOptions,
) i32 {
    return core.v600_ir_inpaint_grain_u16_with_noise(
        rgb_ptr,
        rgb_len,
        mask_ptr,
        mask_len,
        noise_ptr,
        noise_len,
        output_ptr,
        output_len,
        options_ptr,
    );
}

export fn v600_ir_apply_translation_f32(
    ir_ptr: [*]const f32,
    ir_len: usize,
    output_ptr: [*]f32,
    output_len: usize,
    options_ptr: *const IrAlignOptions,
) i32 {
    return core.v600_ir_apply_translation_f32(ir_ptr, ir_len, output_ptr, output_len, options_ptr);
}

export fn v600_ir_estimate_translation_f32(
    rgb_ptr: [*]const f32,
    rgb_len: usize,
    ir_ptr: [*]const f32,
    ir_len: usize,
    result_ptr: *IrEstimateResult,
    options_ptr: *const IrEstimateOptions,
) i32 {
    return core.v600_ir_estimate_translation_f32(rgb_ptr, rgb_len, ir_ptr, ir_len, result_ptr, options_ptr);
}

export fn v600_detect_frames_rgb16(
    raw_ptr: [*]const u16,
    raw_len: usize,
    frames_ptr: [*]FrameDetectRect,
    frames_len: usize,
    result_ptr: *FrameDetectResult,
    options_ptr: *const FrameDetectOptions,
) i32 {
    return core.v600_detect_frames_rgb16(raw_ptr, raw_len, frames_ptr, frames_len, result_ptr, options_ptr);
}

test {
    std.testing.refAllDecls(core);
}
