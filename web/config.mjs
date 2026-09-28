// Processing configuration tables and Wasm option builders: film stock ids,
// render/dust-removal/detect defaults, and config-to-ABI-options mapping.

export const stockIds = Object.freeze({
  identity: 0,
  kodakGold: 1,
  kodakPortra: 2,
});

export const frameFormatIds = Object.freeze({
  "35mm": 1,
  "645": 2,
  "6x6": 3,
  "6x7": 4,
  "6x9": 5,
});

export function defaultRenderConfig(overrides = {}) {
  return {
    contrast: 1.4,
    curve_k: 5.0,
    percentile_lo: 0.5,
    percentile_hi: 99.5,
    exposure_compensation: 0.0,
    color_temp: 0.0,
    color_tint: 0.0,
    ...overrides,
  };
}

export function defaultDustRemovalConfig(overrides = {}) {
  return {
    enabled: true,
    ir_threshold: 0.10,
    ir_hair_sensitivity: 0.10,
    ir_min_area: 3,
    ir_dilate_radius: 4,
    ir_close_radius: 6,
    ir_blur_size: 301,
    ir_max_coverage: 0.03,
    inpaint_padding: 16,
    ...overrides,
  };
}

// Dust-removal values are given at 800 dpi. Scale them to the scan: linear
// sizes with dpi, ir_min_area with its square, truncating to integers and
// keeping the blur size odd, as src/processing/config.zig getParam does.
export function dustRemovalForDpi(dustRemoval, dpi) {
  if (!Number.isFinite(dpi) || dpi <= 0) return dustRemoval;
  const scale = dpi / 800;
  return {
    ...dustRemoval,
    ir_min_area: Math.trunc(dustRemoval.ir_min_area * scale * scale),
    ir_dilate_radius: Math.trunc(dustRemoval.ir_dilate_radius * scale),
    ir_close_radius: Math.trunc(dustRemoval.ir_close_radius * scale),
    ir_blur_size: Math.trunc(dustRemoval.ir_blur_size * scale) | 1,
    inpaint_padding: Math.trunc(dustRemoval.inpaint_padding * scale),
  };
}

export function defaultPreviewOptions({
  width,
  height,
  stock = stockIds.kodakGold,
  render = {},
  dmin = [0.05, 0.06, 0.07],
  percentileSampleLimit = 16384,
}) {
  const renderConfig = defaultRenderConfig(render);
  return {
    width,
    height,
    stock,
    dmin_r: dmin[0],
    dmin_g: dmin[1],
    dmin_b: dmin[2],
    default_light: 65535.0,
    contrast: renderConfig.contrast,
    curve_k: renderConfig.curve_k,
    percentile_lo: renderConfig.percentile_lo,
    percentile_hi: renderConfig.percentile_hi,
    exposure_compensation: renderConfig.exposure_compensation,
    color_temp: renderConfig.color_temp,
    color_tint: renderConfig.color_tint,
    percentile_sample_limit: percentileSampleLimit,
  };
}

export function defaultFrameDetectConfig(overrides = {}) {
  return {
    format: "35mm",
    frame_count_override: null,
    detect_film_extent: true,
    apply_clahe: true,
    ...overrides,
  };
}

export function defaultFrameDetectOptions({ image, detection = defaultFrameDetectConfig() }) {
  return {
    width: image.width,
    height: image.height,
    format: frameFormatId(detection.format),
    frame_count_override: detection.frame_count_override ?? 0,
    detect_film_extent: detection.detect_film_extent !== false,
    apply_clahe: detection.apply_clahe !== false,
  };
}

export function defaultIrMaskOptions({ image, dustRemoval = defaultDustRemovalConfig() }) {
  if (!image.ir) throw new Error("IR mask options require image.ir dimensions");
  return {
    width: image.ir.width,
    height: image.ir.height,
    threshold: dustRemoval.ir_threshold,
    hair_sensitivity: dustRemoval.ir_hair_sensitivity,
    min_area: dustRemoval.ir_min_area,
    dilate_radius: dustRemoval.ir_dilate_radius,
    close_radius: dustRemoval.ir_close_radius,
    blur_size: dustRemoval.ir_blur_size,
    max_coverage: dustRemoval.ir_max_coverage,
  };
}

export function defaultIrMaskResizeOptions({ image }) {
  if (!image.ir) throw new Error("IR mask resize options require image.ir dimensions");
  return {
    ir_width: image.ir.width,
    ir_height: image.ir.height,
    rgb_width: image.width,
    rgb_height: image.height,
  };
}

export function defaultIrInpaintGrainOptions({ image, padding = 16, grainPadding = 8 }) {
  return {
    width: image.width,
    height: image.height,
    padding,
    grain_padding: grainPadding,
  };
}

export function defaultIrEstimateConfig(overrides = {}) {
  return {
    mode: "translation-ecc",
    max_iterations: 200,
    ecc_scale: 0.125,
    epsilon: 1.0e-6,
    ...overrides,
  };
}

export function defaultIrEstimateOptions({ image, estimator = defaultIrEstimateConfig() }) {
  if (!image.ir) throw new Error("IR estimate options require image.ir dimensions");
  return {
    rgb_width: image.width,
    rgb_height: image.height,
    ir_width: image.ir.width,
    ir_height: image.ir.height,
    max_iterations: estimator.max_iterations,
    ecc_scale: estimator.ecc_scale,
    epsilon: estimator.epsilon,
  };
}

export function defaultIrAlignOptions({ image, alignment }) {
  if (!image.ir) throw new Error("IR alignment options require image.ir dimensions");
  return {
    width: image.ir.width,
    height: image.ir.height,
    tx: alignment.tx,
    ty: alignment.ty,
  };
}

export function stockName(stockId) {
  switch (stockId) {
    case stockIds.identity:
      return "identity";
    case stockIds.kodakPortra:
      return "kodak_portra";
    case stockIds.kodakGold:
    default:
      return "kodak_gold";
  }
}

export function stockCoefficientsHash(stockId) {
  switch (stockId) {
    case stockIds.identity:
      return "builtin:identity:v1";
    case stockIds.kodakPortra:
      return "builtin:kodak_portra:v1";
    case stockIds.kodakGold:
    default:
      return "builtin:kodak_gold:v1";
  }
}

export function frameFormatId(format) {
  const id = frameFormatIds[format ?? "35mm"];
  if (!id) throw new Error(`unsupported frame format: ${format}`);
  return id;
}
