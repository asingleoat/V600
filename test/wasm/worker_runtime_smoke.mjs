import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import { Worker } from "node:worker_threads";

import {
  createCancelMessage,
  createLoadModuleMessage,
  createProcessExportMessage,
  createProcessFrameDetectMessage,
  createProcessIrAlignMessage,
  createProcessIrEstimateMessage,
  createProcessIrInpaintMessage,
  createProcessIrMaskMessage,
  createProcessIrRgbMaskMessage,
  createProcessPreviewMessage,
  exportCacheKeyString,
  frameDetectCacheKeyString,
  irAlignCacheKeyString,
  irEstimateCacheKeyString,
  irInpaintCacheKeyString,
  irMaskCacheKeyString,
  irRgbMaskCacheKeyString,
  messageTypes,
  previewCacheKeyString,
} from "../../web/worker/protocol.mjs";
import { assertCloseToFixture, assertDetectedFramesShape, buildAlignmentRgbFixture, frameDetectCount, frameDetectHeight, frameDetectWidth, normalizedToU16, syntheticFrameDetectRawBuffer } from "./helpers.mjs";

const rawFixture = new Uint16Array([
  51000, 42000, 35000,
  45000, 39000, 31000,
  39000, 33000, 26000,
  33000, 27000, 21000,
]);
const expectedPreview = new Uint8Array([
  0, 8, 116,
  12, 44, 193,
  111, 141, 255,
  229, 251, 255,
]);
const irWidth = 9;
const irHeight = 9;
const irFixture = new Uint8Array(irWidth * irHeight).fill(255);
irFixture[40] = 0;
const expectedIrMask = new Uint8Array(irWidth * irHeight);
expectedIrMask[40] = 255;
const expectedRgbMask = new Uint8Array([
  0, 255,
  255, 255,
]);
function sha256(text) {
  return `sha256:${createHash("sha256").update(text).digest("hex")}`;
}

function previewOptions(overrides = {}) {
  return {
    width: 2,
    height: 2,
    stock: 1,
    dmin_r: 0.05,
    dmin_g: 0.06,
    dmin_b: 0.07,
    default_light: 65535.0,
    contrast: 1.4,
    curve_k: 5.0,
    percentile_lo: 0.5,
    percentile_hi: 99.5,
    exposure_compensation: 0.0,
    color_temp: 0.0,
    color_tint: 0.0,
    percentile_sample_limit: 16384,
    ...overrides,
  };
}

function irMaskOptions(overrides = {}) {
  return {
    width: irWidth,
    height: irHeight,
    threshold: 1.0,
    hair_sensitivity: 2.0,
    min_area: 1,
    dilate_radius: 0,
    close_radius: 0,
    blur_size: 7,
    max_coverage: 1.0,
    ...overrides,
  };
}

function irAlignFixture() {
  return JSON.parse(fs.readFileSync("test/fixtures/processing/ir/align-ratio-1-to-2.json", "utf8"));
}

function biharmonicFixture() {
  return JSON.parse(fs.readFileSync("test/fixtures/processing/ir/biharmonic-inpaint-smoke.json", "utf8"));
}

function grainInpaintFixture() {
  return JSON.parse(fs.readFileSync("test/fixtures/processing/ir/inpaint-biharmonic-grain-uint16-smoke.json", "utf8"));
}

function cacheInput() {
  return {
    file: {
      content_hash: "sha256:worker-runtime-smoke",
      name: "worker-runtime-smoke.rgb16",
      size: rawFixture.byteLength,
      last_modified_ms: 1779552000000,
    },
    image: {
      width: 2,
      height: 2,
      channels: 3,
      bit_depth: 16,
      page_layout: "rgb",
      dpi: 800,
    },
    frame: {
      selection: { kind: "full-image", cx: 1.0, cy: 1.0, w: 2.0, h: 2.0, angle: 0.0 },
    },
    rebate: {
      mode: "provided-dmin",
      rect: { x: 0.0, y: 0.0, w: 1.0, h: 1.0, angle: 0.0 },
      dmin: [0.05, 0.06, 0.07],
    },
    film_stock: {
      id: "kodak_gold",
      coefficients_hash: "builtin:kodak_gold:v1",
    },
    processing_config: {
      stock: "kodak_gold",
      dust_removal: { enabled: false },
      render: previewOptions(),
      custom_stocks: {},
    },
    render: {
      contrast: 1.4,
      curve_k: 5.0,
      percentile_lo: 0.5,
      percentile_hi: 99.5,
      exposure_compensation: 0.0,
      color_temp: 0.0,
      color_tint: 0.0,
    },
    preview: {
      max_px: 16384,
      output_width: 2,
      output_height: 2,
      scale: 1.0,
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
  };
}

function transferableRawBuffer() {
  return rawFixture.buffer.slice(rawFixture.byteOffset, rawFixture.byteOffset + rawFixture.byteLength);
}

function exportCacheInput() {
  const input = cacheInput();
  input.output = {
    kind: "rgb16-export",
    color_space: "srgb",
  };
  return input;
}

function frameDetectCacheInput() {
  return {
    file: {
      content_hash: "sha256:worker-runtime-frame-detect",
      name: "axis-35mm-vertical-three-frame.rgb16",
      size: frameDetectWidth * frameDetectHeight * 3 * 2,
      last_modified_ms: 1779552000000,
    },
    image: {
      width: frameDetectWidth,
      height: frameDetectHeight,
      channels: 3,
      bit_depth: 16,
      page_layout: "rgb",
      dpi: null,
      ir: null,
    },
    detection: {
      format: "35mm",
      frame_count_override: 3,
      detect_film_extent: false,
      apply_clahe: false,
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
}

function frameDetectOptions() {
  return {
    width: frameDetectWidth,
    height: frameDetectHeight,
    format: 1,
    frame_count_override: 3,
    detect_film_extent: false,
    apply_clahe: false,
  };
}

function irMaskCacheInput() {
  return {
    file: {
      content_hash: "sha256:worker-runtime-ir-smoke",
      name: "worker-runtime-smoke-rgbir.tiff",
      size: rawFixture.byteLength + irFixture.byteLength,
      last_modified_ms: 1779552000000,
    },
    image: {
      width: 2,
      height: 2,
      channels: 3,
      bit_depth: 16,
      page_layout: "rgb-thumb-ir",
      dpi: 800,
      ir: {
        width: irWidth,
        height: irHeight,
        channels: 1,
        bit_depth: 8,
      },
    },
    processing_config: {
      dust_removal: {
        enabled: true,
        ir_threshold: 1.0,
        ir_hair_sensitivity: 2.0,
        ir_min_area: 1,
        ir_dilate_radius: 0,
        ir_close_radius: 0,
        ir_blur_size: 7,
        ir_max_coverage: 1.0,
      },
    },
    backend: {
      kind: "wasm-cpu",
      precision: "f32",
      gpu: false,
      simd: false,
    },
    output: {
      kind: "ir-mask",
      color_space: "mask",
    },
  };
}

function irRgbMaskCacheInput(irMaskKey) {
  const input = irMaskCacheInput();
  input.upstream = {
    ir_mask_cache_key: irMaskKey,
  };
  input.resize = {
    mode: "native-nearest-ir-to-rgb",
    post_resize_dilate_radius: 1,
  };
  input.backend = {
    kind: "wasm-cpu",
    precision: "u8",
    gpu: false,
  };
  input.output = {
    kind: "rgb-mask",
    color_space: "mask",
  };
  return input;
}

function irInpaintCacheInput(rgbMaskKey, overrides = {}) {
  const input = irMaskCacheInput();
  input.image = {
    ...input.image,
    width: 8,
    height: 7,
    ir: {
      width: 8,
      height: 7,
      channels: 1,
      bit_depth: 8,
    },
  };
  input.upstream = {
    rgb_mask_cache_key: rgbMaskKey,
  };
  input.inpaint = {
    mode: "biharmonic-no-grain",
    value_kind: "uint16",
    padding: 0,
    grain_padding: 0,
    grain_sigma: 0,
    noise_hash: null,
    ...overrides.inpaint,
  };
  input.backend = {
    kind: "wasm-cpu",
    precision: "f64-solver-u16-output",
    gpu: false,
    ...overrides.backend,
  };
  input.output = {
    kind: "cleaned-rgb16",
    color_space: "scanner-rgb",
  };
  return input;
}

function irAlignCacheInput(fixture) {
  return {
    file: {
      content_hash: "sha256:worker-runtime-ir-align-smoke",
      name: "align-ratio-1-to-2.ir-f32",
      size: fixture.ir.length * 4,
      last_modified_ms: 1779552000000,
    },
    image: {
      width: 160,
      height: 128,
      channels: 3,
      bit_depth: 16,
      page_layout: "rgb-thumb-ir",
      dpi: 800,
      ir: {
        width: fixture.ir_shape[1],
        height: fixture.ir_shape[0],
        channels: 1,
        bit_depth: 32,
      },
    },
    alignment: {
      mode: "provided-offset",
      tx: fixture.expected_offset[0],
      ty: fixture.expected_offset[1],
    },
    backend: {
      kind: "wasm-cpu",
      precision: "f32",
      gpu: false,
      simd: false,
    },
    output: {
      kind: "ir-f32",
      color_space: "infrared",
    },
  };
}

function irEstimateCacheInput(fixture) {
  const ratio = fixture.ratio;
  return {
    file: {
      content_hash: "sha256:worker-runtime-ir-estimate-smoke",
      name: "align-ratio-1-to-2.rgb-ir-f32",
      size: (fixture.ir.length + fixture.ir.length * ratio * ratio * 3) * 4,
      last_modified_ms: 1779552000000,
    },
    image: {
      width: fixture.ir_shape[1] * ratio,
      height: fixture.ir_shape[0] * ratio,
      channels: 3,
      bit_depth: 16,
      page_layout: "rgb-thumb-ir",
      dpi: 800,
      ir: {
        width: fixture.ir_shape[1],
        height: fixture.ir_shape[0],
        channels: 1,
        bit_depth: 32,
      },
    },
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
      simd: false,
    },
    output: {
      kind: "ir-alignment",
      color_space: "infrared",
    },
  };
}

function waitFor(worker, predicate) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error("timed out waiting for worker message"));
    }, 30000);
    const onMessage = (message) => {
      if (!predicate(message)) return;
      cleanup();
      resolve(message);
    };
    const onError = (err) => {
      cleanup();
      reject(err);
    };
    const cleanup = () => {
      clearTimeout(timer);
      worker.off("message", onMessage);
      worker.off("error", onError);
    };
    worker.on("message", onMessage);
    worker.on("error", onError);
  });
}

const wasmPath = process.argv[2];
if (!wasmPath) throw new Error("usage: node test/wasm/worker_runtime_smoke.mjs <v600-wasm-core.wasm>");

const worker = new Worker(new URL("../../web/worker/processor.mjs", import.meta.url), {
  type: "module",
});

try {
  const loadTiming = waitFor(worker, (message) => message.type === messageTypes.timing && message.stage === "worker.load-module");
  const readyMessage = waitFor(worker, (message) => message.type === messageTypes.ready);
  worker.postMessage(createLoadModuleMessage({
    requestId: "req-load",
    wasmUrl: wasmPath,
    wasmSha256: null,
  }));
  await loadTiming;
  const ready = await readyMessage;
  assert.deepEqual(ready.capabilities.operations, ["process-preview", "process-export", "process-frame-detect", "process-ir-estimate", "process-ir-align", "process-ir-mask", "process-ir-rgb-mask", "process-ir-inpaint", "process-ir-clean-crop"]);
  assert.ok([32, 64].includes(ready.capabilities.pointer_bits));

  const cacheKey = sha256(previewCacheKeyString(cacheInput()));
  const rawBuffer = transferableRawBuffer();
  const processMessage = createProcessPreviewMessage({
    requestId: "req-preview",
    generation: 1,
    cacheKey,
    cacheKeyPayload: cacheInput(),
    buffers: {
      raw_rgb: {
        buffer: rawBuffer,
        samples: rawFixture.length,
      },
    },
    options: {
      preview_options_layout: "PreviewOptions/v1",
      preview_options: previewOptions(),
    },
  });
  worker.postMessage(processMessage, [rawBuffer]);
  const result = await waitFor(worker, (message) => message.type === messageTypes.previewResult);
  assert.equal(result.request_id, "req-preview");
  assert.equal(result.generation, 1);
  assert.equal(result.cache_key, cacheKey);
  assert.equal(result.output.width, 2);
  assert.equal(result.output.height, 2);
  assert.deepEqual(Array.from(new Uint8Array(result.output.buffer)), Array.from(expectedPreview));
  assert.ok(result.timings.some((timing) => timing.stage === "worker.process-preview"));

  const exportKey = sha256(exportCacheKeyString(exportCacheInput()));
  const exportRawBuffer = transferableRawBuffer();
  worker.postMessage(createProcessExportMessage({
    requestId: "req-export",
    generation: 2,
    cacheKey: exportKey,
    cacheKeyPayload: exportCacheInput(),
    buffers: {
      raw_rgb: {
        buffer: exportRawBuffer,
        samples: rawFixture.length,
      },
    },
    options: {
      preview_options_layout: "PreviewOptions/v1",
      preview_options: previewOptions(),
    },
  }), [exportRawBuffer]);
  const exportResult = await waitFor(worker, (message) => message.type === messageTypes.exportResult);
  assert.equal(exportResult.request_id, "req-export");
  assert.equal(exportResult.cache_key, exportKey);
  assert.equal(exportResult.output.width, 2);
  assert.equal(exportResult.output.height, 2);
  const exportRgb16 = new Uint16Array(exportResult.output.buffer);
  assert.equal(exportRgb16.length, rawFixture.length);
  for (let index = 0; index < exportRgb16.length; index += 1) {
    assert.equal(exportRgb16[index] >> 8, expectedPreview[index]);
  }
  assert.ok(exportResult.timings.some((timing) => timing.stage === "worker.process-export"));

  const frameDetectKey = sha256(frameDetectCacheKeyString(frameDetectCacheInput()));
  const frameDetectRawBuffer = syntheticFrameDetectRawBuffer();
  worker.postMessage(createProcessFrameDetectMessage({
    requestId: "req-frame-detect",
    generation: 3,
    cacheKey: frameDetectKey,
    cacheKeyPayload: frameDetectCacheInput(),
    buffers: {
      raw_rgb: {
        buffer: frameDetectRawBuffer,
        samples: frameDetectWidth * frameDetectHeight * 3,
      },
    },
    options: {
      frame_detect_options_layout: "FrameDetectOptions/v1",
      frame_detect_options: frameDetectOptions(),
      max_frames: 8,
    },
  }), [frameDetectRawBuffer]);
  const frameDetectResult = await waitFor(worker, (message) => message.type === messageTypes.frameDetectResult);
  assert.equal(frameDetectResult.request_id, "req-frame-detect");
  assert.equal(frameDetectResult.cache_key, frameDetectKey);
  assert.equal(frameDetectResult.aspect, "24:36");
  assertDetectedFramesShape(frameDetectResult.frames, frameDetectCount);
  assert.ok(frameDetectResult.rebate);
  assert.ok(frameDetectResult.timings.some((timing) => timing.stage === "worker.process-frame-detect"));

  const irMaskKey = sha256(irMaskCacheKeyString(irMaskCacheInput()));
  const irBuffer = irFixture.buffer.slice(irFixture.byteOffset, irFixture.byteOffset + irFixture.byteLength);
  worker.postMessage(createProcessIrMaskMessage({
    requestId: "req-ir-mask",
    generation: 3,
    cacheKey: irMaskKey,
    cacheKeyPayload: irMaskCacheInput(),
    buffers: {
      ir: {
        buffer: irBuffer,
        samples: irFixture.length,
      },
    },
    options: {
      ir_mask_options_layout: "IrMaskOptions/v1",
      ir_mask_options: irMaskOptions(),
    },
  }), [irBuffer]);
  const irMaskResult = await waitFor(worker, (message) => message.type === messageTypes.irMaskResult);
  assert.equal(irMaskResult.request_id, "req-ir-mask");
  assert.equal(irMaskResult.cache_key, irMaskKey);
  assert.equal(irMaskResult.output.width, irWidth);
  assert.equal(irMaskResult.output.height, irHeight);
  assert.deepEqual(Array.from(new Uint8Array(irMaskResult.output.buffer)), Array.from(expectedIrMask));
  assert.ok(irMaskResult.timings.some((timing) => timing.stage === "worker.process-ir-mask"));

  const irRgbMaskKey = sha256(irRgbMaskCacheKeyString(irRgbMaskCacheInput(irMaskKey)));
  const irMaskForResize = new Uint8Array(irMaskResult.output.buffer);
  worker.postMessage(createProcessIrRgbMaskMessage({
    requestId: "req-ir-rgb-mask",
    generation: 4,
    cacheKey: irRgbMaskKey,
    cacheKeyPayload: irRgbMaskCacheInput(irMaskKey),
    buffers: {
      ir_mask: {
        buffer: irMaskForResize.buffer,
        samples: irMaskForResize.length,
      },
    },
    options: {
      ir_mask_resize_options_layout: "IrMaskResizeOptions/v1",
      ir_mask_resize_options: {
        ir_width: irWidth,
        ir_height: irHeight,
        rgb_width: 2,
        rgb_height: 2,
      },
    },
  }), [irMaskForResize.buffer]);
  const irRgbMaskResult = await waitFor(worker, (message) => message.type === messageTypes.irRgbMaskResult);
  assert.equal(irRgbMaskResult.request_id, "req-ir-rgb-mask");
  assert.equal(irRgbMaskResult.cache_key, irRgbMaskKey);
  assert.equal(irRgbMaskResult.output.width, 2);
  assert.equal(irRgbMaskResult.output.height, 2);
  assert.deepEqual(Array.from(new Uint8Array(irRgbMaskResult.output.buffer)), Array.from(expectedRgbMask));
  assert.ok(irRgbMaskResult.timings.some((timing) => timing.stage === "worker.process-ir-rgb-mask"));

  const inpaintFixture = biharmonicFixture();
  const [inpaintHeight, inpaintWidth, inpaintChannels] = inpaintFixture.shape;
  assert.equal(inpaintChannels, 3);
  const inpaintInput = Uint16Array.from(inpaintFixture.input, (value) => normalizedToU16(value));
  const inpaintMask = Uint8Array.from(inpaintFixture.mask, (value) => value === 0 ? 0 : 255);
  const inpaintExpected = Uint16Array.from(inpaintFixture.expected, (value) => normalizedToU16(value));
  const inpaintMaskKey = "sha256:worker-runtime-rgb-mask";
  const inpaintKey = sha256(irInpaintCacheKeyString(irInpaintCacheInput(inpaintMaskKey)));
  worker.postMessage(createProcessIrInpaintMessage({
    requestId: "req-ir-inpaint",
    generation: 5,
    cacheKey: inpaintKey,
    cacheKeyPayload: irInpaintCacheInput(inpaintMaskKey),
    buffers: {
      rgb: {
        buffer: inpaintInput.buffer,
        samples: inpaintInput.length,
      },
      rgb_mask: {
        buffer: inpaintMask.buffer,
        samples: inpaintMask.length,
      },
    },
    options: {
      ir_inpaint_options_layout: "IrInpaintOptions/v1",
      ir_inpaint_options: {
        width: inpaintWidth,
        height: inpaintHeight,
      },
    },
  }), [inpaintInput.buffer, inpaintMask.buffer]);
  const irInpaintResult = await waitFor(worker, (message) => message.type === messageTypes.irInpaintResult);
  assert.equal(irInpaintResult.request_id, "req-ir-inpaint");
  assert.equal(irInpaintResult.cache_key, inpaintKey);
  assert.equal(irInpaintResult.output.width, inpaintWidth);
  assert.equal(irInpaintResult.output.height, inpaintHeight);
  assert.equal(irInpaintResult.output.mode, "biharmonic-no-grain");
  const inpaintActual = new Uint16Array(irInpaintResult.output.buffer);
  assert.equal(inpaintActual.length, inpaintExpected.length);
  let inpaintMaxAbs = 0;
  for (let index = 0; index < inpaintActual.length; index += 1) {
    inpaintMaxAbs = Math.max(inpaintMaxAbs, Math.abs(inpaintActual[index] - inpaintExpected[index]));
  }
  assert.ok(inpaintMaxAbs <= 2, `inpaint max_abs ${inpaintMaxAbs} exceeds 2`);
  assert.ok(irInpaintResult.timings.some((timing) => timing.stage === "worker.process-ir-inpaint"));

  const grainFixture = grainInpaintFixture();
  const [grainHeight, grainWidth, grainChannels] = grainFixture.shape;
  assert.equal(grainChannels, 3);
  const grainInput = Uint16Array.from(grainFixture.input);
  const grainMask = Uint8Array.from(grainFixture.mask, (value) => value === 0 ? 0 : 255);
  const grainNoise = Float64Array.from(grainFixture.noise);
  const grainExpected = Uint16Array.from(grainFixture.expected);
  const grainMaskKey = "sha256:worker-runtime-grain-rgb-mask";
  const grainCacheInput = irInpaintCacheInput(grainMaskKey, {
    inpaint: {
      mode: "biharmonic-grain",
      padding: grainFixture.padding,
      grain_padding: grainFixture.grain_padding,
      noise_hash: "sha256:worker-runtime-captured-grain-noise",
    },
    backend: {
      precision: "f64-solver-dft-u16-output",
    },
  });
  grainCacheInput.image.width = grainWidth;
  grainCacheInput.image.height = grainHeight;
  grainCacheInput.image.ir.width = grainWidth;
  grainCacheInput.image.ir.height = grainHeight;
  const grainKey = sha256(irInpaintCacheKeyString(grainCacheInput));
  worker.postMessage(createProcessIrInpaintMessage({
    requestId: "req-ir-inpaint-grain",
    generation: 6,
    cacheKey: grainKey,
    cacheKeyPayload: grainCacheInput,
    buffers: {
      rgb: {
        buffer: grainInput.buffer,
        samples: grainInput.length,
      },
      rgb_mask: {
        buffer: grainMask.buffer,
        samples: grainMask.length,
      },
      noise: {
        buffer: grainNoise.buffer,
        samples: grainNoise.length,
      },
    },
    options: {
      ir_inpaint_grain_options_layout: "IrInpaintGrainOptions/v2",
      ir_inpaint_grain_options: {
        width: grainWidth,
        height: grainHeight,
        padding: grainFixture.padding,
        grain_padding: grainFixture.grain_padding,
      },
    },
  }), [grainInput.buffer, grainMask.buffer, grainNoise.buffer]);
  const irGrainInpaintResult = await waitFor(worker, (message) => message.type === messageTypes.irInpaintResult);
  assert.equal(irGrainInpaintResult.request_id, "req-ir-inpaint-grain");
  assert.equal(irGrainInpaintResult.cache_key, grainKey);
  assert.equal(irGrainInpaintResult.output.width, grainWidth);
  assert.equal(irGrainInpaintResult.output.height, grainHeight);
  assert.equal(irGrainInpaintResult.output.mode, "biharmonic-grain");
  const grainActual = new Uint16Array(irGrainInpaintResult.output.buffer);
  assert.equal(grainActual.length, grainExpected.length);
  let grainMaxAbs = 0;
  for (let index = 0; index < grainActual.length; index += 1) {
    grainMaxAbs = Math.max(grainMaxAbs, Math.abs(grainActual[index] - grainExpected[index]));
  }
  assert.ok(grainMaxAbs <= grainFixture.tolerance.abs, `grain inpaint max_abs ${grainMaxAbs} exceeds ${grainFixture.tolerance.abs}`);
  assert.ok(irGrainInpaintResult.timings.some((timing) => timing.stage === "worker.process-ir-inpaint-grain"));

  const alignFixture = irAlignFixture();
  const estimateKey = sha256(irEstimateCacheKeyString(irEstimateCacheInput(alignFixture)));
  const estimateRgb = buildAlignmentRgbFixture(alignFixture);
  const estimateIr = Float32Array.from(alignFixture.ir);
  worker.postMessage(createProcessIrEstimateMessage({
    requestId: "req-ir-estimate",
    generation: 4,
    cacheKey: estimateKey,
    cacheKeyPayload: irEstimateCacheInput(alignFixture),
    buffers: {
      rgb: {
        buffer: estimateRgb.buffer,
        samples: estimateRgb.length,
      },
      ir: {
        buffer: estimateIr.buffer,
        samples: estimateIr.length,
      },
    },
    options: {
      ir_estimate_options_layout: "IrEstimateOptions/v1",
      ir_estimate_options: {
        rgb_width: alignFixture.ir_shape[1] * alignFixture.ratio,
        rgb_height: alignFixture.ir_shape[0] * alignFixture.ratio,
        ir_width: alignFixture.ir_shape[1],
        ir_height: alignFixture.ir_shape[0],
        max_iterations: 200,
        ecc_scale: 0.125,
        epsilon: 1.0e-6,
      },
    },
  }), [estimateRgb.buffer, estimateIr.buffer]);
  const irEstimateResult = await waitFor(worker, (message) => message.type === messageTypes.irEstimateResult);
  assert.equal(irEstimateResult.request_id, "req-ir-estimate");
  assert.equal(irEstimateResult.cache_key, estimateKey);
  assert.equal(irEstimateResult.alignment.mode, "estimated-translation-ecc");
  assert.ok(Math.abs(irEstimateResult.alignment.tx - alignFixture.expected_offset[0]) <= 0.25);
  assert.ok(Math.abs(irEstimateResult.alignment.ty - alignFixture.expected_offset[1]) <= 0.25);
  assert.equal(irEstimateResult.alignment.shifted, true);
  assert.ok(irEstimateResult.timings.some((timing) => timing.stage === "worker.process-ir-estimate"));

  const alignKey = sha256(irAlignCacheKeyString(irAlignCacheInput(alignFixture)));
  const alignInput = Float32Array.from(alignFixture.ir);
  worker.postMessage(createProcessIrAlignMessage({
    requestId: "req-ir-align",
    generation: 4,
    cacheKey: alignKey,
    cacheKeyPayload: irAlignCacheInput(alignFixture),
    buffers: {
      ir: {
        buffer: alignInput.buffer,
        samples: alignInput.length,
      },
    },
    options: {
      ir_align_options_layout: "IrAlignOptions/v1",
      ir_align_options: {
        width: alignFixture.ir_shape[1],
        height: alignFixture.ir_shape[0],
        tx: alignFixture.expected_offset[0],
        ty: alignFixture.expected_offset[1],
      },
    },
  }), [alignInput.buffer]);
  const irAlignResult = await waitFor(worker, (message) => message.type === messageTypes.irAlignResult);
  assert.equal(irAlignResult.request_id, "req-ir-align");
  assert.equal(irAlignResult.cache_key, alignKey);
  assert.equal(irAlignResult.output.width, alignFixture.ir_shape[1]);
  assert.equal(irAlignResult.output.height, alignFixture.ir_shape[0]);
  assert.equal(irAlignResult.output.format, "ir-f32");
  const alignError = assertCloseToFixture(new Float32Array(irAlignResult.output.buffer), alignFixture);
  assert.ok(irAlignResult.timings.some((timing) => timing.stage === "worker.process-ir-align"));

  const badRawBuffer = transferableRawBuffer();
  worker.postMessage(createProcessPreviewMessage({
    requestId: "req-preview-bad-stock",
    generation: 2,
    cacheKey,
    cacheKeyPayload: cacheInput(),
    buffers: {
      raw_rgb: {
        buffer: badRawBuffer,
        samples: rawFixture.length,
      },
    },
    options: {
      preview_options_layout: "PreviewOptions/v1",
      preview_options: previewOptions({ stock: 99 }),
    },
  }), [badRawBuffer]);
  const error = await waitFor(worker, (message) => message.type === messageTypes.error);
  assert.equal(error.code, "invalid-stock");
  assert.equal(error.recoverable, true);

  worker.postMessage(createCancelMessage({
    requestId: "req-preview",
    generation: 3,
    reason: "user",
  }));
  const cancelled = await waitFor(worker, (message) => message.type === messageTypes.cancelled);
  assert.equal(cancelled.reason, "user");

  console.log(JSON.stringify({
    event: "worker-runtime-smoke",
    schema: "v600.webapp.event.v1",
    cache_key: cacheKey,
    output_bytes: expectedPreview.length,
    ir_rgb_mask_bytes: expectedRgbMask.length,
    ir_inpaint_max_abs: inpaintMaxAbs,
    ir_alignment_max_abs: alignError.maxAbs,
    ir_alignment_rms: alignError.rms,
    ir_estimate_tx: irEstimateResult.alignment.tx,
    ir_estimate_ty: irEstimateResult.alignment.ty,
    status: "ok",
  }));
} finally {
  await worker.terminate();
}
