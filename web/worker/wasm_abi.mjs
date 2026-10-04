// Wasm ABI boundary shared by the browser worker (worker/processor.mjs) and
// the direct Node core smoke (test/wasm/wasm_core_smoke.mjs): required-export
// validation, pointer-width-aware index/byte-offset conversion, allocator
// calls, and the extern options-struct byte layouts. The layouts here must
// stay in lockstep with the extern structs in src/wasm/core.zig; keeping them
// in one module is what prevents worker/smoke drift.

export const previewOptionsSize = 72;
export const frameDetectOptionsSize = 32;
export const frameDetectRectSize = 40;
export const frameDetectResultSize = 56;
export const irAlignOptionsSize = 16;
export const irEstimateOptionsSize = 32;
export const irEstimateResultSize = 24;
export const irMaskOptionsSize = 36;
export const irMaskResizeOptionsSize = 16;
export const irInpaintOptionsSize = 8;
export const irInpaintGrainOptionsSize = 16;

export const requiredWasmExports = [
  "memory",
  "cerealgrain_wasm_pointer_bits",
  "cerealgrain_wasm_alloc",
  "cerealgrain_wasm_free",
  "cerealgrain_preview_invert_u16_to_u8",
  "cerealgrain_export_invert_u16_to_u16",
  "cerealgrain_detect_frames_rgb16",
  "cerealgrain_ir_estimate_translation_f32",
  "cerealgrain_ir_apply_translation_f32",
  "cerealgrain_ir_make_defect_mask_u8",
  "cerealgrain_ir_make_defect_mask_f32",
  "cerealgrain_ir_resize_mask_to_rgb_u8",
  "cerealgrain_ir_biharmonic_inpaint_u16",
  "cerealgrain_ir_inpaint_grain_u16_with_noise",
];

export function aspectName(code) {
  switch (code) {
    case 1: return "24:36";
    case 2: return "36:24";
    case 3: return "41.5:56";
    case 4: return "56:41.5";
    case 5: return "56:56";
    case 6: return "56:69";
    case 7: return "69:56";
    case 8: return "56:84";
    case 9: return "84:56";
    default: return null;
  }
}

export function createWasmAbi(exports) {
  for (const name of requiredWasmExports) {
    if (!(name in exports)) throw new Error(`missing Wasm export: ${name}`);
  }
  const pointerBits = Number(exports.cerealgrain_wasm_pointer_bits());
  if (pointerBits !== 32 && pointerBits !== 64) {
    throw new Error(`unsupported Wasm pointer width: ${pointerBits}`);
  }

  function wasmIndex(value) {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error(`Wasm index is not a non-negative safe integer: ${value}`);
    }
    return pointerBits === 64 ? BigInt(value) : value;
  }

  function wasmByteOffset(value, label) {
    const numeric = typeof value === "bigint" ? Number(value) : value;
    if (!Number.isSafeInteger(numeric) || numeric < 0) {
      throw new Error(`${label} cannot be represented as a JavaScript byte offset: ${value}`);
    }
    return numeric;
  }

  function alloc(len) {
    const ptr = wasmByteOffset(exports.cerealgrain_wasm_alloc(wasmIndex(len)), "allocation pointer");
    if (ptr === 0) throw new Error(`wasm allocation failed for ${len} bytes`);
    if (BigInt(ptr) + BigInt(len) > BigInt(exports.memory.buffer.byteLength)) {
      throw new Error(`wasm allocation ${ptr}+${len} exceeds memory size ${exports.memory.buffer.byteLength}`);
    }
    return ptr;
  }

  function free(ptr, len) {
    if (ptr === 0 || len === 0) return;
    exports.cerealgrain_wasm_free(wasmIndex(ptr), wasmIndex(len));
  }

  function callCore(name, ...args) {
    return exports[name](...args.map((arg) => wasmIndex(arg)));
  }

  function structView(ptr, size) {
    return new DataView(exports.memory.buffer, ptr, size);
  }

  function fieldWriters(view) {
    let offset = 0;
    return {
      u32: (value) => {
        view.setUint32(offset, value, true);
        offset += 4;
      },
      f32: (value) => {
        view.setFloat32(offset, value, true);
        offset += 4;
      },
      written: () => offset,
    };
  }

  function writePreviewOptions(ptr, options) {
    const { u32, f32, written } = fieldWriters(structView(ptr, previewOptionsSize));
    u32(options.width);
    u32(options.height);
    u32(options.stock);
    f32(options.dmin_r);
    f32(options.dmin_g);
    f32(options.dmin_b);
    f32(options.default_light);
    f32(options.contrast);
    f32(options.percentile_lo);
    f32(options.percentile_hi);
    f32(options.exposure_compensation);
    f32(options.color_temp);
    f32(options.color_tint);
    u32(options.percentile_sample_limit);
    f32(options.auto_white_balance ?? 1);
    f32(options.film_gamma ?? 0.55);
    f32(options.film_toe ?? 0.25);
    f32(options.dye_crosstalk ?? 0.2);
    if (written() !== previewOptionsSize) throw new Error(`preview option layout wrote ${written()} bytes`);
  }

  function writeFrameDetectOptions(ptr, options) {
    const { u32, written } = fieldWriters(structView(ptr, frameDetectOptionsSize));
    u32(options.width);
    u32(options.height);
    u32(options.format);
    u32(options.frame_count_override ?? 0);
    u32(options.detect_film_extent ? 1 : 0);
    u32(options.apply_clahe ? 1 : 0);
    u32(0);
    u32(0);
    if (written() !== frameDetectOptionsSize) throw new Error(`frame detect option layout wrote ${written()} bytes`);
  }

  function writeIrMaskOptions(ptr, options) {
    const { u32, f32, written } = fieldWriters(structView(ptr, irMaskOptionsSize));
    u32(options.width);
    u32(options.height);
    f32(options.threshold);
    f32(options.hair_sensitivity);
    u32(options.min_area);
    u32(options.dilate_radius);
    u32(options.close_radius);
    u32(options.blur_size);
    f32(options.max_coverage);
    if (written() !== irMaskOptionsSize) throw new Error(`IR mask option layout wrote ${written()} bytes`);
  }

  function writeIrEstimateOptions(ptr, options) {
    const { u32, f32, written } = fieldWriters(structView(ptr, irEstimateOptionsSize));
    u32(options.rgb_width);
    u32(options.rgb_height);
    u32(options.ir_width);
    u32(options.ir_height);
    u32(options.max_iterations);
    f32(options.ecc_scale);
    f32(options.epsilon);
    u32(0);
    if (written() !== irEstimateOptionsSize) throw new Error(`IR estimate option layout wrote ${written()} bytes`);
  }

  function writeIrMaskResizeOptions(ptr, options) {
    const { u32, written } = fieldWriters(structView(ptr, irMaskResizeOptionsSize));
    u32(options.ir_width);
    u32(options.ir_height);
    u32(options.rgb_width);
    u32(options.rgb_height);
    if (written() !== irMaskResizeOptionsSize) throw new Error(`IR mask resize option layout wrote ${written()} bytes`);
  }

  function writeIrInpaintOptions(ptr, options) {
    const { u32, written } = fieldWriters(structView(ptr, irInpaintOptionsSize));
    u32(options.width);
    u32(options.height);
    if (written() !== irInpaintOptionsSize) throw new Error(`IR inpaint option layout wrote ${written()} bytes`);
  }

  function writeIrInpaintGrainOptions(ptr, options) {
    const { u32, written } = fieldWriters(structView(ptr, irInpaintGrainOptionsSize));
    u32(options.width);
    u32(options.height);
    u32(options.padding);
    u32(options.grain_padding);
    if (written() !== irInpaintGrainOptionsSize) throw new Error(`IR grain inpaint option layout wrote ${written()} bytes`);
  }

  function writeIrAlignOptions(ptr, options) {
    const { u32, f32, written } = fieldWriters(structView(ptr, irAlignOptionsSize));
    u32(options.width);
    u32(options.height);
    f32(options.tx);
    f32(options.ty);
    if (written() !== irAlignOptionsSize) throw new Error(`IR align option layout wrote ${written()} bytes`);
  }

  function readIrEstimateResult(ptr) {
    const view = structView(ptr, irEstimateResultSize);
    return {
      mode: "estimated-translation-ecc",
      tx: view.getFloat32(0, true),
      ty: view.getFloat32(4, true),
      rho: view.getFloat32(8, true),
      iterations: view.getUint32(12, true),
      shifted: view.getUint32(16, true) !== 0,
    };
  }

  function readFrameDetectResult(resultPtr, framesPtr) {
    const resultView = structView(resultPtr, frameDetectResultSize);
    const frameCount = resultView.getUint32(0, true);
    const aspect = aspectName(resultView.getUint32(4, true));
    const hasRebate = resultView.getUint32(8, true) !== 0;
    const frames = [];
    const framesView = new DataView(exports.memory.buffer, framesPtr, frameCount * frameDetectRectSize);
    for (let index = 0; index < frameCount; index += 1) {
      const offset = index * frameDetectRectSize;
      frames.push({
        cx: framesView.getFloat64(offset, true),
        cy: framesView.getFloat64(offset + 8, true),
        w: framesView.getFloat64(offset + 16, true),
        h: framesView.getFloat64(offset + 24, true),
        angle: framesView.getFloat64(offset + 32, true),
      });
    }
    return {
      frames,
      aspect,
      rebate: hasRebate ? {
        cx: resultView.getFloat64(16, true),
        cy: resultView.getFloat64(24, true),
        w: resultView.getFloat64(32, true),
        h: resultView.getFloat64(40, true),
        angle: resultView.getFloat64(48, true),
      } : null,
    };
  }

  return {
    pointerBits,
    wasmIndex,
    wasmByteOffset,
    alloc,
    free,
    callCore,
    writePreviewOptions,
    writeFrameDetectOptions,
    writeIrMaskOptions,
    writeIrEstimateOptions,
    writeIrMaskResizeOptions,
    writeIrInpaintOptions,
    writeIrInpaintGrainOptions,
    writeIrAlignOptions,
    readIrEstimateResult,
    readFrameDetectResult,
  };
}
