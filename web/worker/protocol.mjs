export const protocolSchema = "v600.webapp.worker.v1";
export const cacheKeySchema = "v600.webapp.cache-key.v1";
export const protocolVersion = 1;

export const messageTypes = Object.freeze({
  loadModule: "load-module",
  loadImage: "load-image",
  processPreview: "process-preview",
  processExport: "process-export",
  processFrameDetect: "process-frame-detect",
  processIrEstimate: "process-ir-estimate",
  processIrAlign: "process-ir-align",
  processIrMask: "process-ir-mask",
  processIrRgbMask: "process-ir-rgb-mask",
  processIrInpaint: "process-ir-inpaint",
  processIrCleanCrop: "process-ir-clean-crop",
  cancel: "cancel",
  ready: "ready",
  imageLoaded: "image-loaded",
  progress: "progress",
  timing: "timing",
  previewResult: "preview-result",
  exportResult: "export-result",
  frameDetectResult: "frame-detect-result",
  irEstimateResult: "ir-estimate-result",
  irAlignResult: "ir-align-result",
  irMaskResult: "ir-mask-result",
  irRgbMaskResult: "ir-rgb-mask-result",
  irInpaintResult: "ir-inpaint-result",
  irCleanCropResult: "ir-clean-crop-result",
  staleResult: "stale-result",
  cancelled: "cancelled",
  error: "error",
});

export const requiredPreviewCacheKeyPaths = Object.freeze([
  ["schema"],
  ["version"],
  ["operation"],
  ["file", "content_hash"],
  ["file", "name"],
  ["file", "size"],
  ["file", "last_modified_ms"],
  ["image", "width"],
  ["image", "height"],
  ["image", "channels"],
  ["image", "bit_depth"],
  ["image", "page_layout"],
  ["frame", "selection"],
  ["rebate", "mode"],
  ["rebate", "dmin"],
  ["film_stock", "id"],
  ["film_stock", "coefficients_hash"],
  ["processing_config"],
  ["render"],
  ["preview", "max_px"],
  ["preview", "output_width"],
  ["preview", "output_height"],
  ["preview", "percentile_sample_limit"],
  ["backend", "kind"],
  ["backend", "precision"],
  ["backend", "gpu"],
  ["output", "kind"],
  ["output", "color_space"],
]);

export const requiredIrAlignCacheKeyPaths = Object.freeze([
  ["schema"],
  ["version"],
  ["operation"],
  ["file", "content_hash"],
  ["file", "name"],
  ["file", "size"],
  ["file", "last_modified_ms"],
  ["image", "page_layout"],
  ["image", "ir"],
  ["alignment"],
  ["backend", "kind"],
  ["backend", "precision"],
  ["backend", "gpu"],
  ["output", "kind"],
]);

export const requiredFrameDetectCacheKeyPaths = Object.freeze([
  ["schema"],
  ["version"],
  ["operation"],
  ["file", "content_hash"],
  ["file", "name"],
  ["file", "size"],
  ["file", "last_modified_ms"],
  ["image", "width"],
  ["image", "height"],
  ["image", "channels"],
  ["image", "bit_depth"],
  ["image", "page_layout"],
  ["detection", "format"],
  ["detection", "frame_count_override"],
  ["detection", "detect_film_extent"],
  ["detection", "apply_clahe"],
  ["backend", "kind"],
  ["backend", "precision"],
  ["backend", "gpu"],
  ["output", "kind"],
]);

export const requiredIrEstimateCacheKeyPaths = Object.freeze([
  ["schema"],
  ["version"],
  ["operation"],
  ["file", "content_hash"],
  ["file", "name"],
  ["file", "size"],
  ["file", "last_modified_ms"],
  ["image", "width"],
  ["image", "height"],
  ["image", "page_layout"],
  ["image", "ir"],
  ["estimator"],
  ["backend", "kind"],
  ["backend", "precision"],
  ["backend", "gpu"],
  ["output", "kind"],
]);

export const requiredIrMaskCacheKeyPaths = Object.freeze([
  ["schema"],
  ["version"],
  ["operation"],
  ["file", "content_hash"],
  ["file", "name"],
  ["file", "size"],
  ["file", "last_modified_ms"],
  ["image", "page_layout"],
  ["image", "ir"],
  ["processing_config", "dust_removal"],
  ["backend", "kind"],
  ["backend", "precision"],
  ["backend", "gpu"],
  ["output", "kind"],
]);

export const requiredIrRgbMaskCacheKeyPaths = Object.freeze([
  ["schema"],
  ["version"],
  ["operation"],
  ["file", "content_hash"],
  ["file", "name"],
  ["file", "size"],
  ["file", "last_modified_ms"],
  ["image", "width"],
  ["image", "height"],
  ["image", "page_layout"],
  ["image", "ir"],
  ["processing_config", "dust_removal"],
  ["upstream", "ir_mask_cache_key"],
  ["resize", "mode"],
  ["resize", "post_resize_dilate_radius"],
  ["backend", "kind"],
  ["backend", "precision"],
  ["backend", "gpu"],
  ["output", "kind"],
]);

export const requiredIrInpaintCacheKeyPaths = Object.freeze([
  ["schema"],
  ["version"],
  ["operation"],
  ["file", "content_hash"],
  ["file", "name"],
  ["file", "size"],
  ["file", "last_modified_ms"],
  ["image", "width"],
  ["image", "height"],
  ["image", "page_layout"],
  ["image", "ir"],
  ["processing_config", "dust_removal"],
  ["upstream", "rgb_mask_cache_key"],
  ["inpaint", "mode"],
  ["inpaint", "value_kind"],
  ["inpaint", "padding"],
  ["inpaint", "grain_padding"],
  ["inpaint", "noise_hash"],
  ["backend", "kind"],
  ["backend", "precision"],
  ["backend", "gpu"],
  ["output", "kind"],
]);

export const requiredIrCleanCropCacheKeyPaths = Object.freeze([
  ["schema"],
  ["version"],
  ["operation"],
  ["file", "content_hash"],
  ["file", "name"],
  ["file", "size"],
  ["file", "last_modified_ms"],
  ["image", "width"],
  ["image", "height"],
  ["image", "page_layout"],
  ["image", "ir"],
  ["frame", "selection"],
  ["alignment"],
  ["backend", "kind"],
  ["backend", "precision"],
  ["backend", "gpu"],
  ["output", "kind"],
]);

export function createLoadModuleMessage({ requestId, wasmUrl, wasmSha256 = null }) {
  return baseRequest(messageTypes.loadModule, requestId, {
    wasm_url: wasmUrl,
    wasm_sha256: wasmSha256,
  });
}

export function createLoadImageMessage({ requestId, generation, image, file }) {
  return baseRequest(messageTypes.loadImage, requestId, {
    generation,
    image,
    file,
  });
}

export function createProcessPreviewMessage({
  requestId,
  generation,
  cacheKey,
  cacheKeyPayload,
  buffers,
  options,
}) {
  return baseRequest(messageTypes.processPreview, requestId, {
    generation,
    cache_key: cacheKey,
    cache_key_payload: previewCacheKeyPayload(cacheKeyPayload),
    buffers,
    options,
  });
}

export function createProcessExportMessage({
  requestId,
  generation,
  cacheKey,
  cacheKeyPayload,
  buffers,
  options,
}) {
  return baseRequest(messageTypes.processExport, requestId, {
    generation,
    cache_key: cacheKey,
    cache_key_payload: exportCacheKeyPayload(cacheKeyPayload),
    buffers,
    options,
  });
}

export function createProcessFrameDetectMessage({
  requestId,
  generation,
  cacheKey,
  cacheKeyPayload,
  buffers,
  options,
}) {
  return baseRequest(messageTypes.processFrameDetect, requestId, {
    generation,
    cache_key: cacheKey,
    cache_key_payload: frameDetectCacheKeyPayload(cacheKeyPayload),
    buffers,
    options,
  });
}

export function createProcessIrMaskMessage({
  requestId,
  generation,
  cacheKey,
  cacheKeyPayload,
  buffers,
  options,
}) {
  return baseRequest(messageTypes.processIrMask, requestId, {
    generation,
    cache_key: cacheKey,
    cache_key_payload: irMaskCacheKeyPayload(cacheKeyPayload),
    buffers,
    options,
  });
}

export function createProcessIrRgbMaskMessage({
  requestId,
  generation,
  cacheKey,
  cacheKeyPayload,
  buffers,
  options,
}) {
  return baseRequest(messageTypes.processIrRgbMask, requestId, {
    generation,
    cache_key: cacheKey,
    cache_key_payload: irRgbMaskCacheKeyPayload(cacheKeyPayload),
    buffers,
    options,
  });
}

export function createProcessIrInpaintMessage({
  requestId,
  generation,
  cacheKey,
  cacheKeyPayload,
  buffers,
  options,
}) {
  return baseRequest(messageTypes.processIrInpaint, requestId, {
    generation,
    cache_key: cacheKey,
    cache_key_payload: irInpaintCacheKeyPayload(cacheKeyPayload),
    buffers,
    options,
  });
}

export function createProcessIrCleanCropMessage({
  requestId,
  generation,
  cacheKey,
  cacheKeyPayload,
  buffers,
  options,
}) {
  return baseRequest(messageTypes.processIrCleanCrop, requestId, {
    generation,
    cache_key: cacheKey,
    cache_key_payload: irCleanCropCacheKeyPayload(cacheKeyPayload),
    buffers,
    options,
  });
}

export function createProcessIrEstimateMessage({
  requestId,
  generation,
  cacheKey,
  cacheKeyPayload,
  buffers,
  options,
}) {
  return baseRequest(messageTypes.processIrEstimate, requestId, {
    generation,
    cache_key: cacheKey,
    cache_key_payload: irEstimateCacheKeyPayload(cacheKeyPayload),
    buffers,
    options,
  });
}

export function createProcessIrAlignMessage({
  requestId,
  generation,
  cacheKey,
  cacheKeyPayload,
  buffers,
  options,
}) {
  return baseRequest(messageTypes.processIrAlign, requestId, {
    generation,
    cache_key: cacheKey,
    cache_key_payload: irAlignCacheKeyPayload(cacheKeyPayload),
    buffers,
    options,
  });
}

export function createCancelMessage({ requestId, generation, reason = "user" }) {
  return baseRequest(messageTypes.cancel, requestId, {
    generation,
    reason,
  });
}

export function createReadyMessage({ requestId, capabilities }) {
  return baseResponse(messageTypes.ready, requestId, {
    capabilities,
  });
}

export function createImageLoadedMessage({ requestId, generation, image }) {
  return baseResponse(messageTypes.imageLoaded, requestId, {
    generation,
    image,
  });
}

export function createProgressMessage({ requestId, generation, stage, complete, total = 1 }) {
  return baseResponse(messageTypes.progress, requestId, {
    generation,
    stage,
    complete,
    total,
  });
}

export function createTimingMessage({ requestId, generation, stage, elapsedUs, detail = null }) {
  return baseResponse(messageTypes.timing, requestId, {
    generation,
    stage,
    elapsed_us: elapsedUs,
    detail,
  });
}

export function createPreviewResultMessage({
  requestId,
  generation,
  cacheKey,
  output,
  timings = [],
}) {
  return baseResponse(messageTypes.previewResult, requestId, {
    generation,
    cache_key: cacheKey,
    output,
    timings,
  });
}

export function createExportResultMessage({
  requestId,
  generation,
  cacheKey,
  output,
  timings = [],
}) {
  return baseResponse(messageTypes.exportResult, requestId, {
    generation,
    cache_key: cacheKey,
    output,
    timings,
  });
}

export function createFrameDetectResultMessage({
  requestId,
  generation,
  cacheKey,
  frames,
  aspect,
  rebate = null,
  timings = [],
}) {
  return baseResponse(messageTypes.frameDetectResult, requestId, {
    generation,
    cache_key: cacheKey,
    frames,
    aspect,
    rebate,
    timings,
  });
}

export function createIrMaskResultMessage({
  requestId,
  generation,
  cacheKey,
  output,
  timings = [],
}) {
  return baseResponse(messageTypes.irMaskResult, requestId, {
    generation,
    cache_key: cacheKey,
    output,
    timings,
  });
}

export function createIrEstimateResultMessage({
  requestId,
  generation,
  cacheKey,
  alignment,
  timings = [],
}) {
  return baseResponse(messageTypes.irEstimateResult, requestId, {
    generation,
    cache_key: cacheKey,
    alignment,
    timings,
  });
}

export function createIrAlignResultMessage({
  requestId,
  generation,
  cacheKey,
  output,
  timings = [],
}) {
  return baseResponse(messageTypes.irAlignResult, requestId, {
    generation,
    cache_key: cacheKey,
    output,
    timings,
  });
}

export function createIrRgbMaskResultMessage({
  requestId,
  generation,
  cacheKey,
  output,
  timings = [],
}) {
  return baseResponse(messageTypes.irRgbMaskResult, requestId, {
    generation,
    cache_key: cacheKey,
    output,
    timings,
  });
}

export function createIrInpaintResultMessage({
  requestId,
  generation,
  cacheKey,
  output,
  timings = [],
}) {
  return baseResponse(messageTypes.irInpaintResult, requestId, {
    generation,
    cache_key: cacheKey,
    output,
    timings,
  });
}

export function createIrCleanCropResultMessage({
  requestId,
  generation,
  cacheKey,
  output,
  timings = [],
}) {
  return baseResponse(messageTypes.irCleanCropResult, requestId, {
    generation,
    cache_key: cacheKey,
    output,
    timings,
  });
}

export function createStaleResultMessage({ requestId, generation, activeGeneration, cacheKey, reason }) {
  return baseResponse(messageTypes.staleResult, requestId, {
    generation,
    active_generation: activeGeneration,
    cache_key: cacheKey,
    reason,
  });
}

export function createCancelledMessage({ requestId, generation, reason }) {
  return baseResponse(messageTypes.cancelled, requestId, {
    generation,
    reason,
  });
}

export function createErrorMessage({ requestId, generation = null, code, message, recoverable = false }) {
  return baseResponse(messageTypes.error, requestId, {
    generation,
    code,
    message,
    recoverable,
  });
}

export function previewCacheKeyPayload(input) {
  return operationCacheKeyPayload(input, "process-preview");
}

export function exportCacheKeyPayload(input) {
  return operationCacheKeyPayload(input, "process-export");
}

export function frameDetectCacheKeyPayload(input) {
  return operationCacheKeyPayload(input, "process-frame-detect", requiredFrameDetectCacheKeyPaths);
}

export function irMaskCacheKeyPayload(input) {
  return operationCacheKeyPayload(input, "process-ir-mask", requiredIrMaskCacheKeyPaths);
}

export function irRgbMaskCacheKeyPayload(input) {
  return operationCacheKeyPayload(input, "process-ir-rgb-mask", requiredIrRgbMaskCacheKeyPaths);
}

export function irInpaintCacheKeyPayload(input) {
  return operationCacheKeyPayload(input, "process-ir-inpaint", requiredIrInpaintCacheKeyPaths);
}

export function irCleanCropCacheKeyPayload(input) {
  return operationCacheKeyPayload(input, "process-ir-clean-crop", requiredIrCleanCropCacheKeyPaths);
}

export function irEstimateCacheKeyPayload(input) {
  return operationCacheKeyPayload(input, "process-ir-estimate", requiredIrEstimateCacheKeyPaths);
}

export function irAlignCacheKeyPayload(input) {
  return operationCacheKeyPayload(input, "process-ir-align", requiredIrAlignCacheKeyPaths);
}

export function operationCacheKeyPayload(input, operation, requiredPaths = requiredPreviewCacheKeyPaths) {
  const payload = {
    schema: cacheKeySchema,
    version: 1,
    operation,
    ...input,
  };
  const missing = missingPaths(payload, requiredPaths);
  if (missing.length > 0) {
    throw new Error(`cache key missing fields: ${missing.join(", ")}`);
  }
  return canonicalize(payload);
}

export function previewCacheKeyString(input) {
  return stableStringify(previewCacheKeyPayload(input));
}

export function exportCacheKeyString(input) {
  return stableStringify(exportCacheKeyPayload(input));
}

export function frameDetectCacheKeyString(input) {
  return stableStringify(frameDetectCacheKeyPayload(input));
}

export function irMaskCacheKeyString(input) {
  return stableStringify(irMaskCacheKeyPayload(input));
}

export function irRgbMaskCacheKeyString(input) {
  return stableStringify(irRgbMaskCacheKeyPayload(input));
}

export function irInpaintCacheKeyString(input) {
  return stableStringify(irInpaintCacheKeyPayload(input));
}

export function irCleanCropCacheKeyString(input) {
  return stableStringify(irCleanCropCacheKeyPayload(input));
}

export function irEstimateCacheKeyString(input) {
  return stableStringify(irEstimateCacheKeyPayload(input));
}

export function irAlignCacheKeyString(input) {
  return stableStringify(irAlignCacheKeyPayload(input));
}

export function isStaleResponse(response, active) {
  if (response.request_id !== active.requestId) return true;
  if ("generation" in response && response.generation !== active.generation) return true;
  if ("cache_key" in response && response.cache_key !== active.cacheKey) return true;
  return false;
}

export function stableStringify(value) {
  return JSON.stringify(canonicalize(value));
}

export function canonicalize(value) {
  if (value === null) return null;
  if (Array.isArray(value)) return value.map((item) => canonicalize(item));
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("non-finite numbers are not valid protocol values");
    return value;
  }
  if (typeof value === "string" || typeof value === "boolean") return value;
  if (typeof value === "undefined") throw new Error("undefined is not a valid protocol value");
  if (typeof value !== "object") throw new Error(`unsupported protocol value type: ${typeof value}`);

  const out = {};
  for (const key of Object.keys(value).sort()) {
    out[key] = canonicalize(value[key]);
  }
  return out;
}

function baseRequest(type, requestId, fields) {
  return {
    schema: protocolSchema,
    version: protocolVersion,
    direction: "main-to-worker",
    type,
    request_id: requestId,
    ...fields,
  };
}

function baseResponse(type, requestId, fields) {
  return {
    schema: protocolSchema,
    version: protocolVersion,
    direction: "worker-to-main",
    type,
    request_id: requestId,
    ...fields,
  };
}

function missingPaths(value, paths) {
  const missing = [];
  for (const path of paths) {
    let current = value;
    let found = true;
    for (const part of path) {
      if (!isObjectLike(current) || !(part in current)) {
        found = false;
        break;
      }
      current = current[part];
    }
    if (!found || typeof current === "undefined") missing.push(path.join("."));
  }
  return missing;
}

function isObjectLike(value) {
  return value !== null && typeof value === "object";
}
