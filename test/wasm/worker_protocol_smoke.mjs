import assert from "node:assert/strict";
import { createHash } from "node:crypto";

import {
  createCancelMessage,
  createErrorMessage,
  createExportResultMessage,
  createFrameDetectResultMessage,
  createIrAlignResultMessage,
  createIrCleanCropResultMessage,
  createIrEstimateResultMessage,
  createIrInpaintResultMessage,
  createIrRgbMaskResultMessage,
  createLoadImageMessage,
  createLoadModuleMessage,
  createProcessExportMessage,
  createProcessFrameDetectMessage,
  createProcessIrAlignMessage,
  createProcessIrCleanCropMessage,
  createProcessIrEstimateMessage,
  createProcessIrInpaintMessage,
  createProcessIrMaskMessage,
  createProcessIrRgbMaskMessage,
  createPreviewResultMessage,
  createIrMaskResultMessage,
  createProcessPreviewMessage,
  createStaleResultMessage,
  createTimingMessage,
  exportCacheKeyString,
  frameDetectCacheKeyString,
  irAlignCacheKeyString,
  irCleanCropCacheKeyString,
  irEstimateCacheKeyString,
  irInpaintCacheKeyString,
  irMaskCacheKeyString,
  irRgbMaskCacheKeyString,
  isStaleResponse,
  messageTypes,
  previewCacheKeyString,
  stableStringify,
} from "../../web/worker/protocol.mjs";

function sha256(text) {
  return `sha256:${createHash("sha256").update(text).digest("hex")}`;
}

function sampleCacheInput(overrides = {}) {
  return mergeDeep({
    file: {
      content_hash: "sha256:scan-fixture",
      name: "scan_0004_rgbir_3200dpi.tiff",
      size: 1536000000,
      last_modified_ms: 1779552000000,
    },
    image: {
      width: 20600,
      height: 12000,
      channels: 3,
      bit_depth: 16,
      page_layout: "rgb-thumb-ir",
      dpi: 3200,
      ir: {
        width: 5120,
        height: 24125,
        channels: 1,
        bit_depth: 8,
      },
    },
    frame: {
      selection: {
        kind: "rotated-rect",
        cx: 4050.25,
        cy: 3110.5,
        w: 3063.0,
        h: 4600.0,
        angle: -0.0125,
      },
    },
    rebate: {
      mode: "provided-dmin",
      rect: { x: 345.5, y: 217.25, w: 480.0, h: 94.0, angle: -0.0125 },
      dmin: [0.051, 0.062, 0.073],
    },
    film_stock: {
      id: "kodak_gold",
      coefficients_hash: "builtin:kodak_gold:v1",
    },
    processing_config: {
      stock: "kodak_gold",
      dust_removal: {
        enabled: true,
        ir_threshold: 0.18,
        ir_blur_size: 301,
        ir_min_area: 24,
      },
      render: {
        contrast: 1.8,
        percentile_lo: 0.5,
        percentile_hi: 99.5,
        exposure_compensation: 0.0,
        color_temp: 0.0,
        color_tint: 0.0,
      },
      custom_stocks: {},
    },
    render: {
      contrast: 1.8,
      percentile_lo: 0.5,
      percentile_hi: 99.5,
      exposure_compensation: 0.0,
      color_temp: 0.0,
      color_tint: 0.0,
    },
    preview: {
      max_px: 12000000,
      output_width: 1200,
      output_height: 1802,
      scale: 0.3918,
      percentile_sample_limit: 16384,
    },
    backend: {
      kind: "wasm-cpu",
      precision: "f32",
      gpu: false,
      simd: false,
      density_lut: "f32",
    },
    output: {
      kind: "rgb8-preview",
      color_space: "srgb",
    },
  }, overrides);
}

function mergeDeep(base, override) {
  if (!isPlainObject(base) || !isPlainObject(override)) return override;
  const out = { ...base };
  for (const [key, value] of Object.entries(override)) {
    out[key] = key in out ? mergeDeep(out[key], value) : value;
  }
  return out;
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function assertKeyChanges(label, override) {
  const baseline = sha256(previewCacheKeyString(sampleCacheInput()));
  const changed = sha256(previewCacheKeyString(sampleCacheInput(override)));
  assert.notEqual(changed, baseline, `${label} did not change the cache key`);
}

const canonicalA = previewCacheKeyString(sampleCacheInput());
const canonicalB = previewCacheKeyString({
  backend: sampleCacheInput().backend,
  output: sampleCacheInput().output,
  preview: sampleCacheInput().preview,
  render: sampleCacheInput().render,
  processing_config: sampleCacheInput().processing_config,
  film_stock: sampleCacheInput().film_stock,
  rebate: sampleCacheInput().rebate,
  frame: sampleCacheInput().frame,
  image: sampleCacheInput().image,
  file: sampleCacheInput().file,
});
assert.equal(canonicalA, canonicalB, "canonical cache key depends on object insertion order");

const cacheKey = sha256(canonicalA);
assert.match(cacheKey, /^sha256:[0-9a-f]{64}$/);
const exportKey = sha256(exportCacheKeyString(sampleCacheInput({
  output: {
    kind: "rgb16-export",
    color_space: "srgb",
  },
})));
assert.match(exportKey, /^sha256:[0-9a-f]{64}$/);
assert.notEqual(exportKey, cacheKey);
const frameDetectInput = {
  file: sampleCacheInput().file,
  image: sampleCacheInput().image,
  detection: {
    format: "35mm",
    frame_count_override: null,
    detect_film_extent: true,
    apply_clahe: true,
  },
  backend: {
    kind: "wasm-cpu",
    precision: "f64-detector",
    gpu: false,
  },
  output: {
    kind: "frame-detection",
    coordinate_space: "preview",
  },
};
const frameDetectKey = sha256(frameDetectCacheKeyString(frameDetectInput));
assert.match(frameDetectKey, /^sha256:[0-9a-f]{64}$/);
assert.notEqual(frameDetectKey, cacheKey);
const irMaskInput = {
  file: sampleCacheInput().file,
  image: sampleCacheInput().image,
  processing_config: {
    dust_removal: sampleCacheInput().processing_config.dust_removal,
  },
  backend: {
    kind: "wasm-cpu",
    precision: "f32",
    gpu: false,
  },
  output: {
    kind: "ir-mask",
    color_space: "mask",
  },
};
const irMaskKey = sha256(irMaskCacheKeyString(irMaskInput));
assert.match(irMaskKey, /^sha256:[0-9a-f]{64}$/);
assert.notEqual(irMaskKey, cacheKey);
const irRgbMaskInput = {
  file: sampleCacheInput().file,
  image: sampleCacheInput().image,
  processing_config: {
    dust_removal: sampleCacheInput().processing_config.dust_removal,
  },
  upstream: {
    ir_mask_cache_key: irMaskKey,
  },
  resize: {
    mode: "native-nearest-ir-to-rgb",
    post_resize_dilate_radius: 1,
  },
  backend: {
    kind: "wasm-cpu",
    precision: "u8",
    gpu: false,
  },
  output: {
    kind: "rgb-mask",
    color_space: "mask",
  },
};
const irRgbMaskKey = sha256(irRgbMaskCacheKeyString(irRgbMaskInput));
assert.match(irRgbMaskKey, /^sha256:[0-9a-f]{64}$/);
assert.notEqual(irRgbMaskKey, cacheKey);
assert.notEqual(irRgbMaskKey, irMaskKey);
const irInpaintInput = {
  file: sampleCacheInput().file,
  image: sampleCacheInput().image,
  processing_config: {
    dust_removal: sampleCacheInput().processing_config.dust_removal,
  },
  upstream: {
    rgb_mask_cache_key: irRgbMaskKey,
  },
  inpaint: {
    mode: "biharmonic-no-grain",
    value_kind: "uint16",
    padding: 0,
    grain_padding: 0,
    noise_hash: null,
  },
  backend: {
    kind: "wasm-cpu",
    precision: "f64-solver-u16-output",
    gpu: false,
  },
  output: {
    kind: "cleaned-rgb16",
    color_space: "scanner-rgb",
  },
};
const irInpaintKey = sha256(irInpaintCacheKeyString(irInpaintInput));
assert.match(irInpaintKey, /^sha256:[0-9a-f]{64}$/);
assert.notEqual(irInpaintKey, cacheKey);
assert.notEqual(irInpaintKey, irMaskKey);
assert.notEqual(irInpaintKey, irRgbMaskKey);
const irAlignInput = {
  file: sampleCacheInput().file,
  image: sampleCacheInput().image,
  alignment: {
    mode: "provided-offset",
    tx: 9.91815185546875,
    ty: -5.849216461181641,
  },
  backend: {
    kind: "wasm-cpu",
    precision: "f32",
    gpu: false,
  },
  output: {
    kind: "ir-f32",
    color_space: "infrared",
  },
};
const irAlignKey = sha256(irAlignCacheKeyString(irAlignInput));
assert.match(irAlignKey, /^sha256:[0-9a-f]{64}$/);
assert.notEqual(irAlignKey, cacheKey);
assert.notEqual(irAlignKey, irMaskKey);
const irEstimateInput = {
  file: sampleCacheInput().file,
  image: sampleCacheInput().image,
  estimator: {
    mode: "translation-ecc",
    max_iterations: 200,
    ecc_scale: 0.125,
    epsilon: 1.0e-6,
  },
  backend: {
    kind: "wasm-cpu",
    precision: "f32",
    gpu: false,
  },
  output: {
    kind: "ir-alignment",
    color_space: "infrared",
  },
};
const irEstimateKey = sha256(irEstimateCacheKeyString(irEstimateInput));
assert.match(irEstimateKey, /^sha256:[0-9a-f]{64}$/);
assert.notEqual(irEstimateKey, cacheKey);
assert.notEqual(irEstimateKey, irMaskKey);
assert.notEqual(irEstimateKey, irAlignKey);

assertKeyChanges("selected file", { file: { content_hash: "sha256:other-scan" } });
assertKeyChanges("image dimensions", { image: { width: 20599 } });
assertKeyChanges("selected frame", { frame: { selection: { angle: 0.025 } } });
assertKeyChanges("rebate dmin", { rebate: { dmin: [0.055, 0.062, 0.073] } });
assertKeyChanges("film stock coefficients", { film_stock: { coefficients_hash: "custom:kodak_gold:edited" } });
assertKeyChanges("processing config", { processing_config: { dust_removal: { ir_threshold: 0.22 } } });
assertKeyChanges("render config", { render: { contrast: 1.6 } });
assertKeyChanges("preview sample cap", { preview: { percentile_sample_limit: 8192 } });
assertKeyChanges("backend selection", { backend: { kind: "webgpu", gpu: true } });
assertKeyChanges("output shape", { output: { kind: "rgb16-export" } });

assert.throws(
  () => previewCacheKeyString(sampleCacheInput({ film_stock: { coefficients_hash: undefined } })),
  /cache key missing fields|undefined is not a valid protocol value/,
);
assert.throws(
  () => irMaskCacheKeyString({ ...irMaskInput, image: { ...irMaskInput.image, ir: undefined } }),
  /cache key missing fields|undefined is not a valid protocol value/,
);
assert.throws(
  () => irRgbMaskCacheKeyString({ ...irRgbMaskInput, upstream: { ir_mask_cache_key: undefined } }),
  /cache key missing fields|undefined is not a valid protocol value/,
);
assert.throws(
  () => irInpaintCacheKeyString({ ...irInpaintInput, inpaint: { ...irInpaintInput.inpaint, mode: undefined } }),
  /cache key missing fields|undefined is not a valid protocol value/,
);
assert.throws(
  () => irAlignCacheKeyString({ ...irAlignInput, alignment: undefined }),
  /cache key missing fields|undefined is not a valid protocol value/,
);
assert.throws(
  () => irEstimateCacheKeyString({ ...irEstimateInput, estimator: undefined }),
  /cache key missing fields|undefined is not a valid protocol value/,
);
assert.throws(
  () => frameDetectCacheKeyString({ ...frameDetectInput, detection: { ...frameDetectInput.detection, format: undefined } }),
  /cache key missing fields|undefined is not a valid protocol value/,
);
assert.throws(() => stableStringify({ bad: Number.NaN }), /non-finite/);

const loadModule = createLoadModuleMessage({
  requestId: "req-load-module",
  wasmUrl: "cerealgrain-wasm-core.wasm",
  wasmSha256: "sha256:module",
});
assert.equal(loadModule.type, messageTypes.loadModule);
assert.equal(loadModule.direction, "main-to-worker");

const loadImage = createLoadImageMessage({
  requestId: "req-load-image",
  generation: 3,
  image: sampleCacheInput().image,
  file: sampleCacheInput().file,
});
assert.equal(loadImage.type, messageTypes.loadImage);
assert.equal(loadImage.generation, 3);

const processPreview = createProcessPreviewMessage({
  requestId: "req-preview",
  generation: 4,
  cacheKey,
  cacheKeyPayload: sampleCacheInput(),
  buffers: {
    raw_rgb_ptr: 1024,
    raw_rgb_len: 12,
    output_ptr: 4096,
    output_len: 12,
    options_ptr: 8192,
    options_len: 60,
  },
  options: {
    preview_options_layout: "PreviewOptions/v3",
  },
});
assert.equal(processPreview.type, messageTypes.processPreview);
assert.equal(processPreview.cache_key, cacheKey);
assert.equal(processPreview.cache_key_payload.schema, "cerealgrain.webapp.cache-key.v1");
assert.equal(processPreview.cache_key_payload.operation, "process-preview");

const processExport = createProcessExportMessage({
  requestId: "req-export",
  generation: 6,
  cacheKey: exportKey,
  cacheKeyPayload: sampleCacheInput({
    output: {
      kind: "rgb16-export",
      color_space: "srgb",
    },
  }),
  buffers: {
    raw_rgb_ptr: 1024,
    raw_rgb_len: 12,
    output_ptr: 4096,
    output_len: 24,
    options_ptr: 8192,
    options_len: 60,
  },
  options: {
    preview_options_layout: "PreviewOptions/v3",
  },
});
assert.equal(processExport.type, messageTypes.processExport);
assert.equal(processExport.cache_key, exportKey);
assert.equal(processExport.cache_key_payload.operation, "process-export");

const processFrameDetect = createProcessFrameDetectMessage({
  requestId: "req-frame-detect",
  generation: 7,
  cacheKey: frameDetectKey,
  cacheKeyPayload: frameDetectInput,
  buffers: {
    raw_rgb: {
      buffer_id: "rgb16-preview-1",
      samples: 20600 * 12000 * 3,
    },
  },
  options: {
    frame_detect_options_layout: "FrameDetectOptions/v1",
    frame_detect_options: {
      width: 20600,
      height: 12000,
      format: 1,
      frame_count_override: 0,
      detect_film_extent: true,
      apply_clahe: true,
    },
    max_frames: 32,
  },
});
assert.equal(processFrameDetect.type, messageTypes.processFrameDetect);
assert.equal(processFrameDetect.cache_key, frameDetectKey);
assert.equal(processFrameDetect.cache_key_payload.operation, "process-frame-detect");

const processIrAlign = createProcessIrAlignMessage({
  requestId: "req-ir-align",
  generation: 7,
  cacheKey: irAlignKey,
  cacheKeyPayload: irAlignInput,
  buffers: {
    ir: {
      buffer_id: "ir-f32-1",
      samples: 5120 * 24125,
    },
  },
  options: {
    ir_align_options_layout: "IrAlignOptions/v1",
    ir_align_options: {
      width: 5120,
      height: 24125,
      tx: 9.91815185546875,
      ty: -5.849216461181641,
    },
  },
});
assert.equal(processIrAlign.type, messageTypes.processIrAlign);
assert.equal(processIrAlign.cache_key, irAlignKey);
assert.equal(processIrAlign.cache_key_payload.operation, "process-ir-align");

const processIrEstimate = createProcessIrEstimateMessage({
  requestId: "req-ir-estimate",
  generation: 7,
  cacheKey: irEstimateKey,
  cacheKeyPayload: irEstimateInput,
  buffers: {
    rgb: {
      buffer_id: "rgb-f32-1",
      samples: 160 * 128 * 3,
    },
    ir: {
      buffer_id: "ir-f32-1",
      samples: 5120 * 24125,
    },
  },
  options: {
    ir_estimate_options_layout: "IrEstimateOptions/v1",
    ir_estimate_options: {
      rgb_width: 160,
      rgb_height: 128,
      ir_width: 80,
      ir_height: 64,
      max_iterations: 200,
      ecc_scale: 0.125,
      epsilon: 1.0e-6,
    },
  },
});
assert.equal(processIrEstimate.type, messageTypes.processIrEstimate);
assert.equal(processIrEstimate.cache_key, irEstimateKey);
assert.equal(processIrEstimate.cache_key_payload.operation, "process-ir-estimate");

const processIrMask = createProcessIrMaskMessage({
  requestId: "req-ir-mask",
  generation: 8,
  cacheKey: irMaskKey,
  cacheKeyPayload: irMaskInput,
  buffers: {
    ir: {
      buffer_id: "ir-1",
      samples: 5120 * 24125,
    },
  },
  options: {
    ir_mask_options_layout: "IrMaskOptions/v1",
    ir_mask_options: {
      width: 5120,
      height: 24125,
      threshold: 0.18,
      hair_sensitivity: 0.10,
      min_area: 24,
      dilate_radius: 4,
      close_radius: 6,
      blur_size: 301,
      max_coverage: 0.03,
    },
  },
});
assert.equal(processIrMask.type, messageTypes.processIrMask);
assert.equal(processIrMask.cache_key, irMaskKey);
assert.equal(processIrMask.cache_key_payload.operation, "process-ir-mask");

const processIrRgbMask = createProcessIrRgbMaskMessage({
  requestId: "req-ir-rgb-mask",
  generation: 9,
  cacheKey: irRgbMaskKey,
  cacheKeyPayload: irRgbMaskInput,
  buffers: {
    ir_mask: {
      buffer_id: "mask-1",
      samples: 5120 * 24125,
    },
  },
  options: {
    ir_mask_resize_options_layout: "IrMaskResizeOptions/v1",
    ir_mask_resize_options: {
      ir_width: 5120,
      ir_height: 24125,
      rgb_width: 20600,
      rgb_height: 12000,
    },
  },
});
assert.equal(processIrRgbMask.type, messageTypes.processIrRgbMask);
assert.equal(processIrRgbMask.cache_key, irRgbMaskKey);
assert.equal(processIrRgbMask.cache_key_payload.operation, "process-ir-rgb-mask");

const processIrInpaint = createProcessIrInpaintMessage({
  requestId: "req-ir-inpaint",
  generation: 10,
  cacheKey: irInpaintKey,
  cacheKeyPayload: irInpaintInput,
  buffers: {
    rgb: {
      buffer_id: "rgb16-1",
      samples: 20600 * 12000 * 3,
    },
    rgb_mask: {
      buffer_id: "mask-rgb-1",
      samples: 20600 * 12000,
    },
  },
  options: {
    ir_inpaint_options_layout: "IrInpaintOptions/v1",
    ir_inpaint_options: {
      width: 20600,
      height: 12000,
    },
  },
});
assert.equal(processIrInpaint.type, messageTypes.processIrInpaint);
assert.equal(processIrInpaint.cache_key, irInpaintKey);
assert.equal(processIrInpaint.cache_key_payload.operation, "process-ir-inpaint");

const irCleanCropInput = sampleCacheInput({
  alignment: { mode: "provided-offset", tx: 0.75, ty: -2.5 },
  backend: { kind: "wasm-worker", precision: "rgb16-ir-f32", gpu: false },
  output: { kind: "ir-clean-crops", color_space: "scanner-rgb-and-infrared" },
});
const irCleanCropKey = sha256(irCleanCropCacheKeyString(irCleanCropInput));
const processIrCleanCrop = createProcessIrCleanCropMessage({
  requestId: "req-ir-clean-crop",
  generation: 9,
  cacheKey: irCleanCropKey,
  cacheKeyPayload: irCleanCropInput,
  buffers: {
    raw_rgb: { buffer: new ArrayBuffer(24), samples: 12, format: "u16" },
    ir: { buffer: new ArrayBuffer(16), samples: 4, format: "f32" },
  },
  options: {
    image: irCleanCropInput.image,
    frame_selection: irCleanCropInput.frame.selection,
  },
});
assert.equal(processIrCleanCrop.type, messageTypes.processIrCleanCrop);
assert.equal(processIrCleanCrop.cache_key, irCleanCropKey);
assert.equal(processIrCleanCrop.cache_key_payload.operation, "process-ir-clean-crop");

const cancel = createCancelMessage({
  requestId: "req-preview",
  generation: 4,
  reason: "user",
});
assert.equal(cancel.type, messageTypes.cancel);

const result = createPreviewResultMessage({
  requestId: "req-preview",
  generation: 4,
  cacheKey,
  output: { buffer_id: "preview-1", width: 1200, height: 1802, format: "rgb8" },
  timings: [{ stage: "preview", elapsed_us: 1410 }],
});
const exportResult = createExportResultMessage({
  requestId: "req-export",
  generation: 6,
  cacheKey: exportKey,
  output: { buffer_id: "export-1", width: 1200, height: 1802, format: "rgb16" },
  timings: [{ stage: "export", elapsed_us: 1810 }],
});
assert.equal(exportResult.type, messageTypes.exportResult);
assert.equal(exportResult.output.format, "rgb16");
const frameDetectResult = createFrameDetectResultMessage({
  requestId: "req-frame-detect",
  generation: 7,
  cacheKey: frameDetectKey,
  frames: [{ cx: 95.0, cy: 130.0, w: 100.0, h: 150.0, angle: 0.0 }],
  aspect: "24:36",
  rebate: null,
  timings: [{ stage: "frame-detect", elapsed_us: 4410 }],
});
assert.equal(frameDetectResult.type, messageTypes.frameDetectResult);
assert.equal(frameDetectResult.frames.length, 1);
const irAlignResult = createIrAlignResultMessage({
  requestId: "req-ir-align",
  generation: 7,
  cacheKey: irAlignKey,
  output: { buffer_id: "ir-align-1", width: 5120, height: 24125, format: "ir-f32" },
  timings: [{ stage: "ir-align", elapsed_us: 2510 }],
});
assert.equal(irAlignResult.type, messageTypes.irAlignResult);
assert.equal(irAlignResult.output.format, "ir-f32");
const irEstimateResult = createIrEstimateResultMessage({
  requestId: "req-ir-estimate",
  generation: 7,
  cacheKey: irEstimateKey,
  alignment: {
    mode: "estimated-translation-ecc",
    tx: 9.883345603942871,
    ty: -5.884145736694336,
    rho: 0.987080991268158,
    iterations: 5,
    shifted: true,
  },
  timings: [{ stage: "ir-estimate", elapsed_us: 2310 }],
});
assert.equal(irEstimateResult.type, messageTypes.irEstimateResult);
assert.equal(irEstimateResult.alignment.mode, "estimated-translation-ecc");
const irMaskResult = createIrMaskResultMessage({
  requestId: "req-ir-mask",
  generation: 8,
  cacheKey: irMaskKey,
  output: { buffer_id: "mask-1", width: 5120, height: 24125, format: "mask-u8" },
  timings: [{ stage: "ir-mask", elapsed_us: 2810 }],
});
assert.equal(irMaskResult.type, messageTypes.irMaskResult);
assert.equal(irMaskResult.output.format, "mask-u8");
const irRgbMaskResult = createIrRgbMaskResultMessage({
  requestId: "req-ir-rgb-mask",
  generation: 9,
  cacheKey: irRgbMaskKey,
  output: { buffer_id: "mask-rgb-1", width: 20600, height: 12000, format: "mask-u8" },
  timings: [{ stage: "ir-rgb-mask", elapsed_us: 2810 }],
});
assert.equal(irRgbMaskResult.type, messageTypes.irRgbMaskResult);
assert.equal(irRgbMaskResult.output.format, "mask-u8");
const irInpaintResult = createIrInpaintResultMessage({
  requestId: "req-ir-inpaint",
  generation: 10,
  cacheKey: irInpaintKey,
  output: { buffer_id: "cleaned-rgb16-1", width: 20600, height: 12000, format: "rgb16", mode: "biharmonic-no-grain" },
  timings: [{ stage: "ir-inpaint", elapsed_us: 92810 }],
});
assert.equal(irInpaintResult.type, messageTypes.irInpaintResult);
assert.equal(irInpaintResult.output.mode, "biharmonic-no-grain");

const irCleanCropResult = createIrCleanCropResultMessage({
  requestId: "req-ir-clean-crop",
  generation: 9,
  cacheKey: irCleanCropKey,
  output: {
    rgb: { buffer: new ArrayBuffer(24), width: 2, height: 2, format: "rgb16" },
    ir: { buffer: new ArrayBuffer(16), width: 2, height: 2, format: "ir-f32" },
    frame: irCleanCropInput.frame.selection,
  },
  timings: [{ stage: "worker.crop-ir-clean-rgb16", elapsed_us: 500 }],
});
assert.equal(irCleanCropResult.type, messageTypes.irCleanCropResult);
assert.equal(irCleanCropResult.output.rgb.format, "rgb16");
const active = { requestId: "req-preview", generation: 4, cacheKey };
assert.equal(isStaleResponse(result, active), false);
assert.equal(isStaleResponse(result, { ...active, generation: 5 }), true);
assert.equal(isStaleResponse(result, { ...active, requestId: "req-new" }), true);
assert.equal(isStaleResponse(result, { ...active, cacheKey: "sha256:other" }), true);

const stale = createStaleResultMessage({
  requestId: "req-preview",
  generation: 3,
  activeGeneration: 4,
  cacheKey,
  reason: "generation-mismatch",
});
assert.equal(stale.type, messageTypes.staleResult);

const timing = createTimingMessage({
  requestId: "req-preview",
  generation: 4,
  stage: "wasm.preview",
  elapsedUs: 1410,
});
assert.equal(timing.type, messageTypes.timing);
assert.equal(timing.elapsed_us, 1410);

const error = createErrorMessage({
  requestId: "req-preview",
  generation: 4,
  code: "invalid-stock",
  message: "Unknown film stock",
  recoverable: true,
});
assert.equal(error.type, messageTypes.error);
assert.equal(error.recoverable, true);

console.log(JSON.stringify({
  event: "worker-protocol-smoke",
  schema: "cerealgrain.webapp.event.v1",
  cache_key: cacheKey,
  checked_message_types: [
    loadModule.type,
    loadImage.type,
    processPreview.type,
    processExport.type,
    processFrameDetect.type,
    processIrEstimate.type,
    processIrAlign.type,
    processIrMask.type,
    processIrRgbMask.type,
    processIrInpaint.type,
    processIrCleanCrop.type,
    cancel.type,
    result.type,
    exportResult.type,
    frameDetectResult.type,
    irEstimateResult.type,
    irAlignResult.type,
    irMaskResult.type,
    irRgbMaskResult.type,
    irInpaintResult.type,
    irCleanCropResult.type,
    stale.type,
    timing.type,
    error.type,
  ],
  status: "ok",
}));
