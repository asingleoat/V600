import {
  cropIrScalarToRgbFrame,
  cropRgb16ToFrame,
  generateStandardNormalNoise,
  requiredInpaintNoiseSamples,
} from "../app_core.mjs";

import {
  createCancelledMessage,
  createErrorMessage,
  createExportResultMessage,
  createFrameDetectResultMessage,
  createIrAlignResultMessage,
  createIrCleanCropResultMessage,
  createIrEstimateResultMessage,
  createIrInpaintResultMessage,
  createIrMaskResultMessage,
  createIrRgbMaskResultMessage,
  createPreviewResultMessage,
  createReadyMessage,
  createStaleResultMessage,
  createTimingMessage,
  isStaleResponse,
  messageTypes,
} from "./protocol.mjs";

const previewOptionsSize = 60;
const frameDetectOptionsSize = 32;
const frameDetectRectSize = 40;
const frameDetectResultSize = 56;
const irAlignOptionsSize = 16;
const irEstimateOptionsSize = 32;
const irEstimateResultSize = 24;
const irMaskOptionsSize = 36;
const irMaskResizeOptionsSize = 16;
const irInpaintOptionsSize = 8;
const irInpaintGrainOptionsSize = 16;
const statusNames = Object.freeze([
  "ok",
  "invalid-buffer",
  "invalid-dimensions",
  "invalid-stock",
  "out-of-memory",
  "processing-error",
]);

let parentPort = null;
let wasmExports = null;
let wasmPointerBits = 32;
let activeRequest = null;

if (isNodeRuntime()) {
  const workerThreads = await import("node:worker_threads");
  parentPort = workerThreads.parentPort;
  parentPort.on("message", (message) => {
    handleMessage(message).catch((err) => postError(message, "worker-exception", err.message, false));
  });
} else {
  globalThis.onmessage = (event) => {
    handleMessage(event.data).catch((err) => postError(event.data, "worker-exception", err.message, false));
  };
}

async function handleMessage(message) {
  switch (message.type) {
    case messageTypes.loadModule:
      await handleLoadModule(message);
      break;
    case messageTypes.processPreview:
      handleProcessPreview(message);
      break;
    case messageTypes.processExport:
      handleProcessExport(message);
      break;
    case messageTypes.processFrameDetect:
      handleProcessFrameDetect(message);
      break;
    case messageTypes.processIrEstimate:
      handleProcessIrEstimate(message);
      break;
    case messageTypes.processIrAlign:
      handleProcessIrAlign(message);
      break;
    case messageTypes.processIrMask:
      handleProcessIrMask(message);
      break;
    case messageTypes.processIrRgbMask:
      handleProcessIrRgbMask(message);
      break;
    case messageTypes.processIrInpaint:
      handleProcessIrInpaint(message);
      break;
    case messageTypes.processIrCleanCrop:
      handleProcessIrCleanCrop(message);
      break;
    case messageTypes.cancel:
      handleCancel(message);
      break;
    default:
      postError(message, "unknown-message", `Unknown worker message type: ${message.type}`, false);
      break;
  }
}

async function handleLoadModule(message) {
  const started = performance.now();
  const wasmBytes = await loadWasmBytes(message.wasm_url);
  const { instance } = await WebAssembly.instantiate(wasmBytes, {});
  wasmExports = instance.exports;
  requireExport("memory");
  requireExport("v600_wasm_pointer_bits");
  requireExport("v600_wasm_alloc");
  requireExport("v600_wasm_free");
  requireExport("v600_preview_invert_u16_to_u8");
  requireExport("v600_export_invert_u16_to_u16");
  requireExport("v600_detect_frames_rgb16");
  requireExport("v600_ir_estimate_translation_f32");
  requireExport("v600_ir_apply_translation_f32");
  requireExport("v600_ir_make_defect_mask_u8");
  requireExport("v600_ir_make_defect_mask_f32");
  requireExport("v600_ir_resize_mask_to_rgb_u8");
  requireExport("v600_ir_biharmonic_inpaint_u16");
  requireExport("v600_ir_inpaint_grain_u16_with_noise");
  wasmPointerBits = wasmExports.v600_wasm_pointer_bits();
  if (wasmPointerBits !== 32 && wasmPointerBits !== 64) {
    throw new Error(`unsupported Wasm pointer width: ${wasmPointerBits}`);
  }
  post(createTimingMessage({
    requestId: message.request_id,
    generation: null,
    stage: "worker.load-module",
    elapsedUs: elapsedUs(started),
  }));
  post(createReadyMessage({
    requestId: message.request_id,
    capabilities: {
      operations: ["process-preview", "process-export", "process-frame-detect", "process-ir-estimate", "process-ir-align", "process-ir-mask", "process-ir-rgb-mask", "process-ir-inpaint", "process-ir-clean-crop"],
      preview_options_layout: "PreviewOptions/v1",
      frame_detect_options_layout: "FrameDetectOptions/v1",
      ir_estimate_options_layout: "IrEstimateOptions/v1",
      ir_align_options_layout: "IrAlignOptions/v1",
      ir_mask_options_layout: "IrMaskOptions/v1",
      ir_mask_resize_options_layout: "IrMaskResizeOptions/v1",
      ir_inpaint_options_layout: "IrInpaintOptions/v1",
      ir_inpaint_grain_options_layout: "IrInpaintGrainOptions/v1",
      pointer_bits: wasmPointerBits,
      output_formats: ["rgb8-preview", "rgb16-export", "frame-detection", "ir-alignment", "ir-f32", "ir-mask", "rgb-mask", "cleaned-rgb16", "ir-clean-crops"],
      cache_key_schema: "v600.webapp.cache-key.v1",
    },
  }));
}

function handleProcessFrameDetect(message) {
  if (!wasmExports) {
    postError(message, "module-not-loaded", "Wasm module is not loaded", true);
    return;
  }
  activeRequest = {
    requestId: message.request_id,
    generation: message.generation,
    cacheKey: message.cache_key,
  };

  const started = performance.now();
  const raw = new Uint16Array(message.buffers.raw_rgb.buffer);
  const options = message.options.frame_detect_options;
  const maxFrames = Math.max(1, message.options.max_frames ?? 32);
  const rawBytes = raw.byteLength;
  const framesBytes = maxFrames * frameDetectRectSize;
  let rawPtr = 0;
  let framesPtr = 0;
  let resultPtr = 0;
  let optionsPtr = 0;

  try {
    rawPtr = alloc(rawBytes);
    framesPtr = alloc(framesBytes);
    resultPtr = alloc(frameDetectResultSize);
    optionsPtr = alloc(frameDetectOptionsSize);
    new Uint16Array(wasmExports.memory.buffer, rawPtr, raw.length).set(raw);
    writeFrameDetectOptions(optionsPtr, options);
    const status = callCore(
      "v600_detect_frames_rgb16",
      rawPtr,
      raw.length,
      framesPtr,
      maxFrames,
      resultPtr,
      optionsPtr,
    );
    if (status !== 0) {
      postError(message, statusName(status), `Wasm frame detection failed with ${statusName(status)}`, true);
      return;
    }
    const detection = readFrameDetectResult(resultPtr, framesPtr);
    const result = createFrameDetectResultMessage({
      requestId: message.request_id,
      generation: message.generation,
      cacheKey: message.cache_key,
      frames: detection.frames,
      aspect: detection.aspect,
      rebate: detection.rebate,
      timings: [
        {
          stage: "worker.process-frame-detect",
          elapsed_us: elapsedUs(started),
        },
      ],
    });
    if (isStaleResponse(result, activeRequest)) {
      post(createStaleResultMessage({
        requestId: message.request_id,
        generation: message.generation,
        activeGeneration: activeRequest.generation,
        cacheKey: message.cache_key,
        reason: "active-request-mismatch",
      }));
      return;
    }
    post(result);
  } finally {
    free(optionsPtr, frameDetectOptionsSize);
    free(resultPtr, frameDetectResultSize);
    free(framesPtr, framesBytes);
    free(rawPtr, rawBytes);
  }
}

function handleProcessIrEstimate(message) {
  if (!wasmExports) {
    postError(message, "module-not-loaded", "Wasm module is not loaded", true);
    return;
  }
  activeRequest = {
    requestId: message.request_id,
    generation: message.generation,
    cacheKey: message.cache_key,
  };

  const started = performance.now();
  const conversionStarted = performance.now();
  const rgb = bufferToFloat32(message.buffers.rgb.buffer, message.buffers.rgb.format ?? "f32");
  const ir = bufferToFloat32(message.buffers.ir.buffer, message.buffers.ir.format ?? "f32");
  const conversionTimings = [];
  if ((message.buffers.rgb.format ?? "f32") !== "f32" || (message.buffers.ir.format ?? "f32") !== "f32") {
    conversionTimings.push({
      stage: "worker.convert-ir-estimate-inputs-f32",
      elapsed_us: elapsedUs(conversionStarted),
    });
  }
  const options = message.options.ir_estimate_options;
  let rgbPtr = 0;
  let irPtr = 0;
  let optionsPtr = 0;
  let resultPtr = 0;

  try {
    rgbPtr = alloc(rgb.byteLength);
    irPtr = alloc(ir.byteLength);
    optionsPtr = alloc(irEstimateOptionsSize);
    resultPtr = alloc(irEstimateResultSize);
    new Float32Array(wasmExports.memory.buffer, rgbPtr, rgb.length).set(rgb);
    new Float32Array(wasmExports.memory.buffer, irPtr, ir.length).set(ir);
    writeIrEstimateOptions(optionsPtr, options);
    const status = callCore(
      "v600_ir_estimate_translation_f32",
      rgbPtr,
      rgb.length,
      irPtr,
      ir.length,
      resultPtr,
      optionsPtr,
    );
    if (status !== 0) {
      postError(message, statusName(status), `Wasm IR estimate failed with ${statusName(status)}`, true);
      return;
    }
    const alignment = readIrEstimateResult(resultPtr);
    const result = createIrEstimateResultMessage({
      requestId: message.request_id,
      generation: message.generation,
      cacheKey: message.cache_key,
      alignment,
      timings: [
        ...conversionTimings,
        {
          stage: "worker.process-ir-estimate",
          elapsed_us: elapsedUs(started),
        },
      ],
    });
    if (isStaleResponse(result, activeRequest)) {
      post(createStaleResultMessage({
        requestId: message.request_id,
        generation: message.generation,
        activeGeneration: activeRequest.generation,
        cacheKey: message.cache_key,
        reason: "active-request-mismatch",
      }));
      return;
    }
    post(result);
  } finally {
    free(resultPtr, irEstimateResultSize);
    free(optionsPtr, irEstimateOptionsSize);
    free(irPtr, ir.byteLength);
    free(rgbPtr, rgb.byteLength);
  }
}

function handleProcessIrAlign(message) {
  if (!wasmExports) {
    postError(message, "module-not-loaded", "Wasm module is not loaded", true);
    return;
  }
  activeRequest = {
    requestId: message.request_id,
    generation: message.generation,
    cacheKey: message.cache_key,
  };

  const started = performance.now();
  const conversionStarted = performance.now();
  const ir = bufferToFloat32(message.buffers.ir.buffer, message.buffers.ir.format ?? "f32");
  const conversionTimings = [];
  if ((message.buffers.ir.format ?? "f32") !== "f32") {
    conversionTimings.push({
      stage: "worker.convert-ir-align-input-f32",
      elapsed_us: elapsedUs(conversionStarted),
    });
  }
  const options = message.options.ir_align_options;
  const outputBytes = ir.byteLength;
  let irPtr = 0;
  let outputPtr = 0;
  let optionsPtr = 0;

  try {
    irPtr = alloc(ir.byteLength);
    outputPtr = alloc(outputBytes);
    optionsPtr = alloc(irAlignOptionsSize);
    new Float32Array(wasmExports.memory.buffer, irPtr, ir.length).set(ir);
    writeIrAlignOptions(optionsPtr, options);
    const status = callCore(
      "v600_ir_apply_translation_f32",
      irPtr,
      ir.length,
      outputPtr,
      ir.length,
      optionsPtr,
    );
    if (status !== 0) {
      postError(message, statusName(status), `Wasm IR alignment failed with ${statusName(status)}`, true);
      return;
    }
    const resultBuffer = new Float32Array(wasmExports.memory.buffer, outputPtr, ir.length).slice().buffer;
    const result = createIrAlignResultMessage({
      requestId: message.request_id,
      generation: message.generation,
      cacheKey: message.cache_key,
      output: {
        buffer: resultBuffer,
        width: options.width,
        height: options.height,
        format: "ir-f32",
      },
      timings: [
        ...conversionTimings,
        {
          stage: "worker.process-ir-align",
          elapsed_us: elapsedUs(started),
        },
      ],
    });
    if (isStaleResponse(result, activeRequest)) {
      post(createStaleResultMessage({
        requestId: message.request_id,
        generation: message.generation,
        activeGeneration: activeRequest.generation,
        cacheKey: message.cache_key,
        reason: "active-request-mismatch",
      }));
      return;
    }
    post(result, [resultBuffer]);
  } finally {
    free(optionsPtr, irAlignOptionsSize);
    free(outputPtr, outputBytes);
    free(irPtr, ir.byteLength);
  }
}

function handleProcessIrMask(message) {
  if (!wasmExports) {
    postError(message, "module-not-loaded", "Wasm module is not loaded", true);
    return;
  }
  activeRequest = {
    requestId: message.request_id,
    generation: message.generation,
    cacheKey: message.cache_key,
  };

  const started = performance.now();
  const irFormat = message.buffers.ir.format ?? "u8";
  const ir = irFormat === "f32"
    ? new Float32Array(message.buffers.ir.buffer)
    : new Uint8Array(message.buffers.ir.buffer);
  const options = message.options.ir_mask_options;
  const outputBytes = ir.length;
  let irPtr = 0;
  let outputPtr = 0;
  let optionsPtr = 0;

  try {
    irPtr = alloc(ir.byteLength);
    outputPtr = alloc(outputBytes);
    optionsPtr = alloc(irMaskOptionsSize);
    if (irFormat === "f32") {
      new Float32Array(wasmExports.memory.buffer, irPtr, ir.length).set(ir);
    } else {
      new Uint8Array(wasmExports.memory.buffer, irPtr, ir.length).set(ir);
    }
    writeIrMaskOptions(optionsPtr, options);
    const status = callCore(
      irFormat === "f32" ? "v600_ir_make_defect_mask_f32" : "v600_ir_make_defect_mask_u8",
      irPtr,
      ir.length,
      outputPtr,
      outputBytes,
      optionsPtr,
    );
    if (status !== 0) {
      postError(message, statusName(status), `Wasm IR mask failed with ${statusName(status)}`, true);
      return;
    }
    const resultBuffer = new Uint8Array(wasmExports.memory.buffer, outputPtr, outputBytes).slice().buffer;
    const result = createIrMaskResultMessage({
      requestId: message.request_id,
      generation: message.generation,
      cacheKey: message.cache_key,
      output: {
        buffer: resultBuffer,
        width: options.width,
        height: options.height,
        format: "mask-u8",
      },
      timings: [
        {
          stage: "worker.process-ir-mask",
          elapsed_us: elapsedUs(started),
        },
      ],
    });
    if (isStaleResponse(result, activeRequest)) {
      post(createStaleResultMessage({
        requestId: message.request_id,
        generation: message.generation,
        activeGeneration: activeRequest.generation,
        cacheKey: message.cache_key,
        reason: "active-request-mismatch",
      }));
      return;
    }
    post(result, [resultBuffer]);
  } finally {
    free(optionsPtr, irMaskOptionsSize);
    free(outputPtr, outputBytes);
    free(irPtr, ir.byteLength);
  }
}

function handleProcessIrRgbMask(message) {
  if (!wasmExports) {
    postError(message, "module-not-loaded", "Wasm module is not loaded", true);
    return;
  }
  activeRequest = {
    requestId: message.request_id,
    generation: message.generation,
    cacheKey: message.cache_key,
  };

  const started = performance.now();
  const mask = new Uint8Array(message.buffers.ir_mask.buffer);
  const options = message.options.ir_mask_resize_options;
  const outputBytes = options.rgb_width * options.rgb_height;
  let maskPtr = 0;
  let outputPtr = 0;
  let optionsPtr = 0;

  try {
    maskPtr = alloc(mask.byteLength);
    outputPtr = alloc(outputBytes);
    optionsPtr = alloc(irMaskResizeOptionsSize);
    new Uint8Array(wasmExports.memory.buffer, maskPtr, mask.length).set(mask);
    writeIrMaskResizeOptions(optionsPtr, options);
    const status = callCore(
      "v600_ir_resize_mask_to_rgb_u8",
      maskPtr,
      mask.length,
      outputPtr,
      outputBytes,
      optionsPtr,
    );
    if (status !== 0) {
      postError(message, statusName(status), `Wasm RGB-sized IR mask failed with ${statusName(status)}`, true);
      return;
    }
    const resultBuffer = new Uint8Array(wasmExports.memory.buffer, outputPtr, outputBytes).slice().buffer;
    const result = createIrRgbMaskResultMessage({
      requestId: message.request_id,
      generation: message.generation,
      cacheKey: message.cache_key,
      output: {
        buffer: resultBuffer,
        width: options.rgb_width,
        height: options.rgb_height,
        format: "mask-u8",
      },
      timings: [
        {
          stage: "worker.process-ir-rgb-mask",
          elapsed_us: elapsedUs(started),
        },
      ],
    });
    if (isStaleResponse(result, activeRequest)) {
      post(createStaleResultMessage({
        requestId: message.request_id,
        generation: message.generation,
        activeGeneration: activeRequest.generation,
        cacheKey: message.cache_key,
        reason: "active-request-mismatch",
      }));
      return;
    }
    post(result, [resultBuffer]);
  } finally {
    free(optionsPtr, irMaskResizeOptionsSize);
    free(outputPtr, outputBytes);
    free(maskPtr, mask.byteLength);
  }
}

function handleProcessIrInpaint(message) {
  if (!wasmExports) {
    postError(message, "module-not-loaded", "Wasm module is not loaded", true);
    return;
  }
  activeRequest = {
    requestId: message.request_id,
    generation: message.generation,
    cacheKey: message.cache_key,
  };

  const started = performance.now();
  const rgb = new Uint16Array(message.buffers.rgb.buffer);
  const mask = new Uint8Array(message.buffers.rgb_mask.buffer);
  const grainMode = Boolean(message.options.ir_inpaint_grain_options);
  const options = grainMode ? message.options.ir_inpaint_grain_options : message.options.ir_inpaint_options;
  let noise = grainMode && message.buffers.noise ? new Float64Array(message.buffers.noise.buffer) : null;
  const operationTimings = [];
  const outputBytes = rgb.byteLength;
  let rgbPtr = 0;
  let maskPtr = 0;
  let noisePtr = 0;
  let outputPtr = 0;
  let optionsPtr = 0;

  try {
    rgbPtr = alloc(rgb.byteLength);
    maskPtr = alloc(mask.byteLength);
    outputPtr = alloc(outputBytes);
    optionsPtr = alloc(grainMode ? irInpaintGrainOptionsSize : irInpaintOptionsSize);
    new Uint16Array(wasmExports.memory.buffer, rgbPtr, rgb.length).set(rgb);
    new Uint8Array(wasmExports.memory.buffer, maskPtr, mask.length).set(mask);
    let status = 0;
    if (grainMode) {
      if (!noise) {
        const noiseStarted = performance.now();
        const seed = options.noise_seed ?? "default";
        const sampleCount = requiredInpaintNoiseSamples(mask, options.width, options.height, options.padding);
        noise = new Float64Array(generateStandardNormalNoise(sampleCount, seededRandom(seed)));
        const timing = {
          stage: "worker.generate-ir-grain-noise",
          elapsed_us: elapsedUs(noiseStarted),
          detail: `seed:${seed}`,
        };
        operationTimings.push(timing);
        post(createTimingMessage({
          requestId: message.request_id,
          generation: message.generation,
          stage: timing.stage,
          elapsedUs: timing.elapsed_us,
          detail: timing.detail,
        }));
      }
      if (noise.byteLength > 0) {
        noisePtr = alloc(noise.byteLength);
        new Float64Array(wasmExports.memory.buffer, noisePtr, noise.length).set(noise);
      }
      writeIrInpaintGrainOptions(optionsPtr, options);
      status = callCore(
        "v600_ir_inpaint_grain_u16_with_noise",
        rgbPtr,
        rgb.length,
        maskPtr,
        mask.length,
        noisePtr,
        noise.length,
        outputPtr,
        rgb.length,
        optionsPtr,
      );
    } else {
      writeIrInpaintOptions(optionsPtr, options);
      status = callCore(
        "v600_ir_biharmonic_inpaint_u16",
        rgbPtr,
        rgb.length,
        maskPtr,
        mask.length,
        outputPtr,
        rgb.length,
        optionsPtr,
      );
    }
    if (status !== 0) {
      postError(message, statusName(status), `Wasm IR inpaint failed with ${statusName(status)}`, true);
      return;
    }
    const resultBuffer = new Uint16Array(wasmExports.memory.buffer, outputPtr, rgb.length).slice().buffer;
    const result = createIrInpaintResultMessage({
      requestId: message.request_id,
      generation: message.generation,
      cacheKey: message.cache_key,
      output: {
        buffer: resultBuffer,
        width: options.width,
        height: options.height,
        format: "rgb16",
        mode: grainMode ? "biharmonic-grain" : "biharmonic-no-grain",
      },
      timings: [
        ...operationTimings,
        {
          stage: grainMode ? "worker.process-ir-inpaint-grain" : "worker.process-ir-inpaint",
          elapsed_us: elapsedUs(started),
        },
      ],
    });
    if (isStaleResponse(result, activeRequest)) {
      post(createStaleResultMessage({
        requestId: message.request_id,
        generation: message.generation,
        activeGeneration: activeRequest.generation,
        cacheKey: message.cache_key,
        reason: "active-request-mismatch",
      }));
      return;
    }
    post(result, [resultBuffer]);
  } finally {
    free(optionsPtr, grainMode ? irInpaintGrainOptionsSize : irInpaintOptionsSize);
    free(outputPtr, outputBytes);
    free(noisePtr, noise?.byteLength ?? 0);
    free(maskPtr, mask.byteLength);
    free(rgbPtr, rgb.byteLength);
  }
}

function handleProcessIrCleanCrop(message) {
  activeRequest = {
    requestId: message.request_id,
    generation: message.generation,
    cacheKey: message.cache_key,
  };

  const timings = [];
  let croppedRgb;
  let croppedIr;
  try {
    const rgbStarted = performance.now();
    croppedRgb = cropRgb16ToFrame(
      message.buffers.raw_rgb.buffer,
      message.options.image,
      message.options.frame_selection,
    );
    timings.push({
      stage: "worker.crop-ir-clean-rgb16",
      elapsed_us: elapsedUs(rgbStarted),
    });

    const irStarted = performance.now();
    croppedIr = cropIrScalarToRgbFrame(
      message.buffers.ir.buffer,
      {
        width: message.options.image.width,
        height: message.options.image.height,
        ir: {
          ...message.options.image.ir,
          bit_depth: 32,
        },
      },
      croppedRgb.frame,
      "f32",
    );
    timings.push({
      stage: "worker.crop-ir-clean-ir-f32",
      elapsed_us: elapsedUs(irStarted),
    });
  } catch (err) {
    postError(message, "invalid-ir-clean-crop", err.message, true);
    return;
  }

  const result = createIrCleanCropResultMessage({
    requestId: message.request_id,
    generation: message.generation,
    cacheKey: message.cache_key,
    output: {
      rgb: {
        buffer: croppedRgb.arrayBuffer,
        width: croppedRgb.width,
        height: croppedRgb.height,
        format: "rgb16",
      },
      ir: {
        buffer: croppedIr.arrayBuffer,
        width: croppedIr.width,
        height: croppedIr.height,
        format: "ir-f32",
      },
      frame: croppedRgb.frame,
    },
    timings,
  });
  if (isStaleResponse(result, activeRequest)) {
    post(createStaleResultMessage({
      requestId: message.request_id,
      generation: message.generation,
      activeGeneration: activeRequest.generation,
      cacheKey: message.cache_key,
      reason: "active-request-mismatch",
    }));
    return;
  }
  post(result, [croppedRgb.arrayBuffer, croppedIr.arrayBuffer]);
}

function handleProcessPreview(message) {
  if (!wasmExports) {
    postError(message, "module-not-loaded", "Wasm module is not loaded", true);
    return;
  }
  activeRequest = {
    requestId: message.request_id,
    generation: message.generation,
    cacheKey: message.cache_key,
  };

  const started = performance.now();
  let prepared;
  try {
    prepared = prepareRgb16BufferForProcessing(message);
  } catch (err) {
    postError(message, "invalid-crop", err.message, true);
    return;
  }
  const raw = prepared.raw;
  const options = prepared.options;
  const outputBytes = raw.length;
  const rawBytes = raw.byteLength;
  let rawPtr = 0;
  let outputPtr = 0;
  let optionsPtr = 0;

  try {
    rawPtr = alloc(rawBytes);
    outputPtr = alloc(outputBytes);
    optionsPtr = alloc(previewOptionsSize);
    new Uint16Array(wasmExports.memory.buffer, rawPtr, raw.length).set(raw);
    writePreviewOptions(optionsPtr, options);
    const status = callCore(
      "v600_preview_invert_u16_to_u8",
      rawPtr,
      raw.length,
      outputPtr,
      outputBytes,
      optionsPtr,
    );
    if (status !== 0) {
      postError(message, statusName(status), `Wasm preview failed with ${statusName(status)}`, true);
      return;
    }
    const resultBuffer = new Uint8Array(wasmExports.memory.buffer, outputPtr, outputBytes).slice().buffer;
    const result = createPreviewResultMessage({
      requestId: message.request_id,
      generation: message.generation,
      cacheKey: message.cache_key,
      output: {
        buffer: resultBuffer,
        width: options.width,
        height: options.height,
        format: "rgb8",
      },
      timings: [
        ...prepared.timings,
        {
          stage: "worker.process-preview",
          elapsed_us: elapsedUs(started),
        },
      ],
    });
    if (isStaleResponse(result, activeRequest)) {
      post(createStaleResultMessage({
        requestId: message.request_id,
        generation: message.generation,
        activeGeneration: activeRequest.generation,
        cacheKey: message.cache_key,
        reason: "active-request-mismatch",
      }));
      return;
    }
    post(result, [resultBuffer]);
  } finally {
    free(optionsPtr, previewOptionsSize);
    free(outputPtr, outputBytes);
    free(rawPtr, rawBytes);
  }
}

function handleProcessExport(message) {
  if (!wasmExports) {
    postError(message, "module-not-loaded", "Wasm module is not loaded", true);
    return;
  }
  activeRequest = {
    requestId: message.request_id,
    generation: message.generation,
    cacheKey: message.cache_key,
  };

  const started = performance.now();
  let prepared;
  try {
    prepared = prepareRgb16BufferForProcessing(message);
  } catch (err) {
    postError(message, "invalid-crop", err.message, true);
    return;
  }
  const raw = prepared.raw;
  const options = prepared.options;
  const outputBytes = raw.byteLength;
  const rawBytes = raw.byteLength;
  let rawPtr = 0;
  let outputPtr = 0;
  let optionsPtr = 0;

  try {
    rawPtr = alloc(rawBytes);
    outputPtr = alloc(outputBytes);
    optionsPtr = alloc(previewOptionsSize);
    new Uint16Array(wasmExports.memory.buffer, rawPtr, raw.length).set(raw);
    writePreviewOptions(optionsPtr, options);
    const status = callCore(
      "v600_export_invert_u16_to_u16",
      rawPtr,
      raw.length,
      outputPtr,
      raw.length,
      optionsPtr,
    );
    if (status !== 0) {
      postError(message, statusName(status), `Wasm export failed with ${statusName(status)}`, true);
      return;
    }
    const resultBuffer = new Uint16Array(wasmExports.memory.buffer, outputPtr, raw.length).slice().buffer;
    const result = createExportResultMessage({
      requestId: message.request_id,
      generation: message.generation,
      cacheKey: message.cache_key,
      output: {
        buffer: resultBuffer,
        width: options.width,
        height: options.height,
        format: "rgb16",
      },
      timings: [
        ...prepared.timings,
        {
          stage: "worker.process-export",
          elapsed_us: elapsedUs(started),
        },
      ],
    });
    if (isStaleResponse(result, activeRequest)) {
      post(createStaleResultMessage({
        requestId: message.request_id,
        generation: message.generation,
        activeGeneration: activeRequest.generation,
        cacheKey: message.cache_key,
        reason: "active-request-mismatch",
      }));
      return;
    }
    post(result, [resultBuffer]);
  } finally {
    free(optionsPtr, previewOptionsSize);
    free(outputPtr, outputBytes);
    free(rawPtr, rawBytes);
  }
}

function prepareRgb16BufferForProcessing(message) {
  let rawBuffer = message.buffers.raw_rgb.buffer;
  let options = message.options.preview_options;
  let inputWidth = message.options.input?.width ?? options.width;
  let inputHeight = message.options.input?.height ?? options.height;
  const timings = [];
  const crop = message.options.crop ?? null;
  if (crop) {
    const cropStarted = performance.now();
    const cropped = cropRgb16ToFrame(rawBuffer, crop.image, crop.frame_selection);
    rawBuffer = cropped.arrayBuffer;
    inputWidth = cropped.width;
    inputHeight = cropped.height;
    if (message.options.input && (inputWidth !== message.options.input.width || inputHeight !== message.options.input.height)) {
      throw new Error(`worker crop output ${inputWidth}x${inputHeight} did not match requested ${message.options.input?.width}x${message.options.input?.height}`);
    }
    timings.push({
      stage: "worker.crop-rgb16",
      elapsed_us: elapsedUs(cropStarted),
    });
  }
  const resize = message.options.resize ?? null;
  if (resize) {
    const resizeStarted = performance.now();
    if (resize.width !== options.width || resize.height !== options.height) {
      throw new Error(`worker resize output ${resize.width}x${resize.height} did not match requested ${options.width}x${options.height}`);
    }
    rawBuffer = resizeRgb16AreaBox(rawBuffer, inputWidth, inputHeight, resize.width, resize.height);
    inputWidth = resize.width;
    inputHeight = resize.height;
    timings.push({
      stage: "worker.resize-rgb16-area",
      elapsed_us: elapsedUs(resizeStarted),
      detail: `${inputWidth}x${inputHeight}`,
    });
  }
  options = {
    ...options,
    width: inputWidth,
    height: inputHeight,
  };
  return {
    raw: new Uint16Array(rawBuffer),
    options,
    timings,
  };
}

function resizeRgb16AreaBox(arrayBuffer, sourceWidth, sourceHeight, targetWidth, targetHeight) {
  if (!Number.isInteger(sourceWidth) || !Number.isInteger(sourceHeight) || sourceWidth <= 0 || sourceHeight <= 0) {
    throw new Error("resize source dimensions must be positive integers");
  }
  if (!Number.isInteger(targetWidth) || !Number.isInteger(targetHeight) || targetWidth <= 0 || targetHeight <= 0) {
    throw new Error("resize target dimensions must be positive integers");
  }
  if (targetWidth > sourceWidth || targetHeight > sourceHeight) {
    throw new Error("preview resize only supports downscaling");
  }
  const source = new Uint16Array(arrayBuffer);
  if (source.length !== sourceWidth * sourceHeight * 3) {
    throw new Error("resize input length does not match source dimensions");
  }
  if (targetWidth === sourceWidth && targetHeight === sourceHeight) {
    return arrayBuffer.slice(0);
  }

  const output = new Uint16Array(targetWidth * targetHeight * 3);
  const scaleX = sourceWidth / targetWidth;
  const scaleY = sourceHeight / targetHeight;
  for (let y = 0; y < targetHeight; y += 1) {
    const y0 = Math.floor(y * scaleY);
    const y1 = Math.max(y0 + 1, Math.min(sourceHeight, Math.floor((y + 1) * scaleY)));
    for (let x = 0; x < targetWidth; x += 1) {
      const x0 = Math.floor(x * scaleX);
      const x1 = Math.max(x0 + 1, Math.min(sourceWidth, Math.floor((x + 1) * scaleX)));
      const count = (x1 - x0) * (y1 - y0);
      const dest = (y * targetWidth + x) * 3;
      let r = 0;
      let g = 0;
      let b = 0;
      for (let yy = y0; yy < y1; yy += 1) {
        let src = (yy * sourceWidth + x0) * 3;
        for (let xx = x0; xx < x1; xx += 1) {
          r += source[src];
          g += source[src + 1];
          b += source[src + 2];
          src += 3;
        }
      }
      output[dest] = Math.round(r / count);
      output[dest + 1] = Math.round(g / count);
      output[dest + 2] = Math.round(b / count);
    }
  }
  return output.buffer;
}

function handleCancel(message) {
  if (activeRequest && activeRequest.requestId === message.request_id) {
    activeRequest = {
      ...activeRequest,
      generation: message.generation,
      cancelled: true,
    };
  }
  post(createCancelledMessage({
    requestId: message.request_id,
    generation: message.generation,
    reason: message.reason,
  }));
}

async function loadWasmBytes(path) {
  if (isNodeRuntime()) {
    const fs = await import("node:fs/promises");
    return fs.readFile(path);
  }
  const response = await fetch(path, { cache: "no-store" });
  if (!response.ok) throw new Error(`failed to load Wasm module: ${response.status}`);
  return response.arrayBuffer();
}

function writePreviewOptions(ptr, options) {
  const view = new DataView(wasmExports.memory.buffer, ptr, previewOptionsSize);
  let offset = 0;
  const u32 = (value) => {
    view.setUint32(offset, value, true);
    offset += 4;
  };
  const f32 = (value) => {
    view.setFloat32(offset, value, true);
    offset += 4;
  };
  u32(options.width);
  u32(options.height);
  u32(options.stock);
  f32(options.dmin_r);
  f32(options.dmin_g);
  f32(options.dmin_b);
  f32(options.default_light);
  f32(options.contrast);
  f32(options.curve_k);
  f32(options.percentile_lo);
  f32(options.percentile_hi);
  f32(options.exposure_compensation);
  f32(options.color_temp);
  f32(options.color_tint);
  u32(options.percentile_sample_limit);
}

function writeFrameDetectOptions(ptr, options) {
  const view = new DataView(wasmExports.memory.buffer, ptr, frameDetectOptionsSize);
  let offset = 0;
  const u32 = (value) => {
    view.setUint32(offset, value, true);
    offset += 4;
  };

  u32(options.width);
  u32(options.height);
  u32(options.format);
  u32(options.frame_count_override ?? 0);
  u32(options.detect_film_extent ? 1 : 0);
  u32(options.apply_clahe ? 1 : 0);
  u32(0);
  u32(0);

  if (offset !== frameDetectOptionsSize) throw new Error(`frame detect option layout wrote ${offset} bytes`);
}

function writeIrMaskOptions(ptr, options) {
  const view = new DataView(wasmExports.memory.buffer, ptr, irMaskOptionsSize);
  let offset = 0;
  const u32 = (value) => {
    view.setUint32(offset, value, true);
    offset += 4;
  };
  const f32 = (value) => {
    view.setFloat32(offset, value, true);
    offset += 4;
  };

  u32(options.width);
  u32(options.height);
  f32(options.threshold);
  f32(options.hair_sensitivity);
  u32(options.min_area);
  u32(options.dilate_radius);
  u32(options.close_radius);
  u32(options.blur_size);
  f32(options.max_coverage);

  if (offset !== irMaskOptionsSize) throw new Error(`IR mask option layout wrote ${offset} bytes`);
}

function writeIrEstimateOptions(ptr, options) {
  const view = new DataView(wasmExports.memory.buffer, ptr, irEstimateOptionsSize);
  let offset = 0;
  const u32 = (value) => {
    view.setUint32(offset, value, true);
    offset += 4;
  };
  const f32 = (value) => {
    view.setFloat32(offset, value, true);
    offset += 4;
  };

  u32(options.rgb_width);
  u32(options.rgb_height);
  u32(options.ir_width);
  u32(options.ir_height);
  u32(options.max_iterations);
  f32(options.ecc_scale);
  f32(options.epsilon);
  u32(0);

  if (offset !== irEstimateOptionsSize) throw new Error(`IR estimate option layout wrote ${offset} bytes`);
}

function writeIrMaskResizeOptions(ptr, options) {
  const view = new DataView(wasmExports.memory.buffer, ptr, irMaskResizeOptionsSize);
  let offset = 0;
  const u32 = (value) => {
    view.setUint32(offset, value, true);
    offset += 4;
  };

  u32(options.ir_width);
  u32(options.ir_height);
  u32(options.rgb_width);
  u32(options.rgb_height);

  if (offset !== irMaskResizeOptionsSize) throw new Error(`IR mask resize option layout wrote ${offset} bytes`);
}

function writeIrInpaintOptions(ptr, options) {
  const view = new DataView(wasmExports.memory.buffer, ptr, irInpaintOptionsSize);
  let offset = 0;
  const u32 = (value) => {
    view.setUint32(offset, value, true);
    offset += 4;
  };

  u32(options.width);
  u32(options.height);

  if (offset !== irInpaintOptionsSize) throw new Error(`IR inpaint option layout wrote ${offset} bytes`);
}

function writeIrInpaintGrainOptions(ptr, options) {
  const view = new DataView(wasmExports.memory.buffer, ptr, irInpaintGrainOptionsSize);
  let offset = 0;
  const u32 = (value) => {
    view.setUint32(offset, value, true);
    offset += 4;
  };

  u32(options.width);
  u32(options.height);
  u32(options.padding);
  u32(options.grain_padding);

  if (offset !== irInpaintGrainOptionsSize) throw new Error(`IR grain inpaint option layout wrote ${offset} bytes`);
}

function readIrEstimateResult(ptr) {
  const view = new DataView(wasmExports.memory.buffer, ptr, irEstimateResultSize);
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
  const resultView = new DataView(wasmExports.memory.buffer, resultPtr, frameDetectResultSize);
  const frameCount = resultView.getUint32(0, true);
  const aspect = aspectName(resultView.getUint32(4, true));
  const hasRebate = resultView.getUint32(8, true) !== 0;
  const frames = [];
  const framesView = new DataView(wasmExports.memory.buffer, framesPtr, frameCount * frameDetectRectSize);
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

function aspectName(code) {
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

function writeIrAlignOptions(ptr, options) {
  const view = new DataView(wasmExports.memory.buffer, ptr, irAlignOptionsSize);
  let offset = 0;
  const u32 = (value) => {
    view.setUint32(offset, value, true);
    offset += 4;
  };
  const f32 = (value) => {
    view.setFloat32(offset, value, true);
    offset += 4;
  };

  u32(options.width);
  u32(options.height);
  f32(options.tx);
  f32(options.ty);

  if (offset !== irAlignOptionsSize) throw new Error(`IR align option layout wrote ${offset} bytes`);
}

function alloc(len) {
  const ptr = wasmByteOffset(wasmExports.v600_wasm_alloc(wasmIndex(len)), "allocation pointer");
  if (ptr === 0) throw new Error(`wasm allocation failed for ${len} bytes`);
  if (BigInt(ptr) + BigInt(len) > BigInt(wasmExports.memory.buffer.byteLength)) {
    throw new Error(`wasm allocation ${ptr}+${len} exceeds memory size ${wasmExports.memory.buffer.byteLength}`);
  }
  return ptr;
}

function free(ptr, len) {
  if (ptr === 0 || len === 0) return;
  wasmExports.v600_wasm_free(wasmIndex(ptr), wasmIndex(len));
}

function callCore(name, ...args) {
  return wasmExports[name](...args.map((arg) => wasmIndex(arg)));
}

function wasmIndex(value) {
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`Wasm index is not a non-negative safe integer: ${value}`);
  }
  return wasmPointerBits === 64 ? BigInt(value) : value;
}

function wasmByteOffset(value, label) {
  const numeric = typeof value === "bigint" ? Number(value) : value;
  if (!Number.isSafeInteger(numeric) || numeric < 0) {
    throw new Error(`${label} cannot be represented as a JavaScript byte offset: ${value}`);
  }
  return numeric;
}

function requireExport(name) {
  if (!(name in wasmExports)) throw new Error(`missing Wasm export: ${name}`);
}

function postError(message, code, detail, recoverable) {
  post(createErrorMessage({
    requestId: message?.request_id ?? "unknown",
    generation: message?.generation ?? null,
    code,
    message: detail,
    recoverable,
  }));
}

function post(message, transfer = []) {
  if (parentPort) {
    parentPort.postMessage(message, transfer);
  } else {
    globalThis.postMessage(message, transfer);
  }
}

function elapsedUs(started) {
  return Math.round((performance.now() - started) * 1000);
}

function bufferToFloat32(buffer, format) {
  if (format === "f32") return new Float32Array(buffer);
  const SourceArray = scalarArrayType(format);
  const source = new SourceArray(buffer);
  const out = new Float32Array(source.length);
  for (let index = 0; index < source.length; index += 1) out[index] = source[index];
  return out;
}

function scalarArrayType(format) {
  switch (format) {
    case "u8":
      return Uint8Array;
    case "u16":
      return Uint16Array;
    default:
      throw new Error(`unsupported scalar buffer format: ${format}`);
  }
}

function seededRandom(seedText) {
  let state = hashSeed(seedText);
  return () => {
    state = (state + 0x6D2B79F5) >>> 0;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

function hashSeed(seedText) {
  let hash = 0x811c9dc5;
  const text = String(seedText);
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

function statusName(status) {
  return statusNames[status] ?? "unknown-status";
}

function isNodeRuntime() {
  return typeof process !== "undefined" && !!process.versions?.node;
}
