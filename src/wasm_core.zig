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

const exported_core_functions = [_][]const u8{
    "cerealgrain_wasm_alloc",
    "cerealgrain_wasm_free",
    "cerealgrain_preview_invert_u16_to_u8",
    "cerealgrain_export_invert_u16_to_u16",
    "cerealgrain_ir_make_defect_mask_u8",
    "cerealgrain_ir_make_defect_mask_f32",
    "cerealgrain_ir_resize_mask_to_rgb_u8",
    "cerealgrain_ir_biharmonic_inpaint_u16",
    "cerealgrain_ir_inpaint_grain_u16_with_noise",
    "cerealgrain_ir_apply_translation_f32",
    "cerealgrain_ir_estimate_translation_f32",
    "cerealgrain_detect_frames_rgb16",
};

comptime {
    for (exported_core_functions) |name| {
        @export(&@field(core, name), .{ .name = name });
    }
}

export fn cerealgrain_wasm_pointer_bits() u32 {
    return @bitSizeOf(usize);
}

test {
    std.testing.refAllDecls(core);
}
