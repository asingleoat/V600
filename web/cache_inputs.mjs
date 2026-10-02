// Cache-key input builders and sha256 cache-key helpers for every worker
// operation, plus source-file identity hashing.

import { sha256ArrayBuffer, sha256Text } from "./util.mjs";
import { defaultDustRemovalConfig, defaultFrameDetectConfig, defaultIrEstimateConfig, defaultRenderConfig, stockCoefficientsHash, stockIds } from "./config.mjs";
import { normalizeFrameSelection } from "./geometry.mjs";
import { exportCacheKeyString, frameDetectCacheKeyString, irAlignCacheKeyString, irCleanCropCacheKeyString, irEstimateCacheKeyString, irInpaintCacheKeyString, irMaskCacheKeyString, irRgbMaskCacheKeyString, previewCacheKeyString } from "./worker/protocol.mjs";

export function buildPreviewCacheInput({
  file,
  image,
  stock = "kodak_gold",
  stockId = stockIds.kodakGold,
  render = defaultRenderConfig(),
  dmin = [0.05, 0.06, 0.07],
  frameSelection = null,
  preview,
  output = { kind: "rgb8-preview", color_space: "srgb" },
}) {
  const frame = normalizeFrameSelection(frameSelection, image);
  const outputWidth = preview.output_width ?? frame.w;
  const outputHeight = preview.output_height ?? frame.h;
  return {
    file,
    image: {
      width: image.width,
      height: image.height,
      channels: 3,
      bit_depth: 16,
      page_layout: image.page_layout ?? "rgb",
      dpi: image.dpi ?? null,
      ir: image.ir ?? null,
    },
    frame: {
      selection: frame,
    },
    rebate: {
      mode: "provided-dmin",
      rect: { x: 0.0, y: 0.0, w: 1.0, h: 1.0, angle: 0.0 },
      dmin,
    },
    film_stock: {
      id: stock,
      coefficients_hash: stockCoefficientsHash(stockId),
    },
    processing_config: {
      stock,
      dust_removal: { enabled: false },
      render,
      custom_stocks: {},
    },
    render,
    preview: {
      max_px: preview.max_px ?? outputWidth * outputHeight,
      output_width: outputWidth,
      output_height: outputHeight,
      scale: preview.scale ?? 1.0,
      percentile_sample_limit: preview.percentile_sample_limit ?? 16384,
    },
    backend: {
      kind: "wasm-cpu",
      precision: "f32",
      gpu: false,
      simd: false,
      density_lut: "f32",
    },
    output: {
      ...output,
    },
  };
}

export function buildFrameDetectCacheInput({
  file,
  image,
  detection = defaultFrameDetectConfig(),
  output = { kind: "frame-detection", coordinate_space: "preview" },
}) {
  return {
    file,
    image: {
      width: image.width,
      height: image.height,
      channels: 3,
      bit_depth: 16,
      page_layout: image.page_layout ?? "rgb",
      dpi: image.dpi ?? null,
      ir: image.ir ?? null,
    },
    detection: {
      format: detection.format,
      frame_count_override: detection.frame_count_override ?? null,
      detect_film_extent: detection.detect_film_extent !== false,
      apply_clahe: detection.apply_clahe !== false,
    },
    backend: {
      kind: "wasm-cpu",
      precision: "f64-detector",
      gpu: false,
      simd: false,
    },
    output: {
      ...output,
    },
  };
}

export async function fileIdentity({ name, size, lastModified, arrayBuffer }) {
  return {
    content_hash: await sha256ArrayBuffer(arrayBuffer),
    name,
    size,
    last_modified_ms: lastModified ?? 0,
  };
}

export async function previewCacheKey(input) {
  return sha256Text(previewCacheKeyString(input));
}

export async function exportCacheKey(input) {
  return sha256Text(exportCacheKeyString(input));
}

export async function frameDetectCacheKey(input) {
  return sha256Text(frameDetectCacheKeyString(input));
}

export async function irMaskCacheKey(input) {
  return sha256Text(irMaskCacheKeyString(input));
}

export async function irRgbMaskCacheKey(input) {
  return sha256Text(irRgbMaskCacheKeyString(input));
}

export async function irInpaintCacheKey(input) {
  return sha256Text(irInpaintCacheKeyString(input));
}

export async function irAlignCacheKey(input) {
  return sha256Text(irAlignCacheKeyString(input));
}

export async function irCleanCropCacheKey(input) {
  return sha256Text(irCleanCropCacheKeyString(input));
}

export async function irEstimateCacheKey(input) {
  return sha256Text(irEstimateCacheKeyString(input));
}

export function buildIrEstimateCacheInput({
  file,
  image,
  estimator = defaultIrEstimateConfig(),
  output = { kind: "ir-alignment", color_space: "infrared" },
}) {
  const ir = image.ir ?? null;
  return {
    file,
    image: {
      width: image.width,
      height: image.height,
      channels: 3,
      bit_depth: 16,
      page_layout: image.page_layout ?? "rgb",
      dpi: image.dpi ?? null,
      ir,
    },
    estimator,
    backend: {
      kind: "wasm-cpu",
      precision: "f32",
      gpu: false,
      simd: false,
    },
    output: {
      ...output,
    },
  };
}

export function buildIrAlignCacheInput({
  file,
  image,
  alignment,
  output = { kind: "ir-f32", color_space: "infrared" },
}) {
  const ir = image.ir ?? null;
  return {
    file,
    image: {
      width: image.width,
      height: image.height,
      channels: 3,
      bit_depth: 16,
      page_layout: image.page_layout ?? "rgb",
      dpi: image.dpi ?? null,
      ir,
    },
    alignment: {
      ...alignment,
    },
    backend: {
      kind: "wasm-cpu",
      precision: "f32",
      gpu: false,
      simd: false,
    },
    output: {
      ...output,
    },
  };
}

export function buildIrMaskCacheInput({
  file,
  image,
  dustRemoval = defaultDustRemovalConfig(),
  output = { kind: "ir-mask", color_space: "mask" },
}) {
  const ir = image.ir ?? null;
  return {
    file,
    image: {
      width: image.width,
      height: image.height,
      channels: 3,
      bit_depth: 16,
      page_layout: image.page_layout ?? "rgb",
      dpi: image.dpi ?? null,
      ir,
    },
    processing_config: {
      dust_removal: dustRemoval,
    },
    backend: {
      kind: "wasm-cpu",
      precision: "f32",
      gpu: false,
      simd: false,
    },
    output: {
      ...output,
    },
  };
}

export function buildIrRgbMaskCacheInput({
  file,
  image,
  dustRemoval = defaultDustRemovalConfig(),
  irMaskCacheKey,
  output = { kind: "rgb-mask", color_space: "mask" },
}) {
  const ir = image.ir ?? null;
  return {
    file,
    image: {
      width: image.width,
      height: image.height,
      channels: 3,
      bit_depth: 16,
      page_layout: image.page_layout ?? "rgb",
      dpi: image.dpi ?? null,
      ir,
    },
    processing_config: {
      dust_removal: dustRemoval,
    },
    upstream: {
      ir_mask_cache_key: irMaskCacheKey,
    },
    resize: {
      mode: "native-nearest-ir-to-rgb",
      post_resize_dilate_radius: ir && (ir.width !== image.width || ir.height !== image.height) ? 1 : 0,
    },
    backend: {
      kind: "wasm-cpu",
      precision: "u8",
      gpu: false,
      simd: false,
    },
    output: {
      ...output,
    },
  };
}

export function buildIrInpaintCacheInput({
  file,
  image,
  dustRemoval = defaultDustRemovalConfig(),
  rgbMaskCacheKey,
  mode = "biharmonic-no-grain",
  padding = 0,
  grainPadding = 0,
  grainSigma = 0,
  noiseHash = null,
  output = { kind: "cleaned-rgb16", color_space: "scanner-rgb" },
}) {
  const ir = image.ir ?? null;
  return {
    file,
    image: {
      width: image.width,
      height: image.height,
      channels: 3,
      bit_depth: 16,
      page_layout: image.page_layout ?? "rgb",
      dpi: image.dpi ?? null,
      ir,
    },
    processing_config: {
      dust_removal: dustRemoval,
    },
    upstream: {
      rgb_mask_cache_key: rgbMaskCacheKey,
    },
    inpaint: {
      mode,
      value_kind: "uint16",
      padding,
      grain_padding: grainPadding,
      grain_sigma: grainSigma,
      noise_hash: noiseHash,
    },
    backend: {
      kind: "wasm-cpu",
      precision: mode === "biharmonic-grain" ? "f64-solver-dft-u16-output" : "f64-solver-u16-output",
      gpu: false,
      simd: false,
    },
    output: {
      ...output,
    },
  };
}

export function buildIrCleanCropCacheInput({
  file,
  image,
  frameSelection,
  alignment = null,
  output = { kind: "ir-clean-crops", color_space: "scanner-rgb-and-infrared" },
}) {
  const ir = image.ir ?? null;
  return {
    file,
    image: {
      width: image.width,
      height: image.height,
      channels: 3,
      bit_depth: 16,
      page_layout: image.page_layout ?? "rgb-thumb-ir",
      dpi: image.dpi ?? null,
      ir,
    },
    frame: {
      selection: normalizeFrameSelection(frameSelection, image),
    },
    alignment,
    backend: {
      kind: "wasm-worker",
      precision: "rgb16-ir-f32",
      gpu: false,
    },
    output: {
      ...output,
    },
  };
}
