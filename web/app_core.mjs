import {
  createLoadModuleMessage,
  createProcessFrameDetectMessage,
  createProcessExportMessage,
  createProcessIrAlignMessage,
  createProcessIrCleanCropMessage,
  createProcessIrEstimateMessage,
  createProcessIrInpaintMessage,
  createProcessIrMaskMessage,
  createProcessIrRgbMaskMessage,
  createProcessPreviewMessage,
  exportCacheKeyString,
  frameDetectCacheKeyString,
  irAlignCacheKeyString,
  irCleanCropCacheKeyString,
  irEstimateCacheKeyString,
  irInpaintCacheKeyString,
  irMaskCacheKeyString,
  irRgbMaskCacheKeyString,
  messageTypes,
  previewCacheKeyString,
} from "./worker/protocol.mjs";

export const stockIds = Object.freeze({
  identity: 0,
  kodakGold: 1,
  kodakPortra: 2,
});

export const defaultPreviewMaxPixels = 2_000_000;

export const frameFormatIds = Object.freeze({
  "35mm": 1,
  "645": 2,
  "6x6": 3,
  "6x7": 4,
  "6x9": 5,
});

export const exportVariants = Object.freeze({
  irNeg: Object.freeze({
    id: "ir_neg",
    suffix: "_ir",
    metadata_variant: "ir_cleaned",
    needs_ir: true,
    needs_invert: false,
  }),
  irInv: Object.freeze({
    id: "ir_inv",
    suffix: "",
    metadata_variant: "ir_cleaned_inverted",
    needs_ir: true,
    needs_invert: true,
  }),
  invOnly: Object.freeze({
    id: "inv_only",
    suffix: "_inv",
    metadata_variant: "inverted",
    needs_ir: false,
    needs_invert: true,
  }),
});

export const nativeExportVariantOrder = Object.freeze([
  exportVariants.irNeg,
  exportVariants.irInv,
  exportVariants.invOnly,
]);

export function defaultOutputSelection(overrides = {}) {
  return {
    ir_neg: false,
    ir_inv: true,
    inv_only: false,
    ...overrides,
  };
}

export function enabledExportVariants(selection = defaultOutputSelection()) {
  return nativeExportVariantOrder.filter((variant) => Boolean(selection[variant.id]));
}

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

export function parseRawRgb16Buffer(arrayBuffer, { width, height }) {
  const expectedBytes = width * height * 3 * 2;
  if (arrayBuffer.byteLength !== expectedBytes) {
    throw new Error(`RGB16 input size ${arrayBuffer.byteLength} does not match ${width}x${height}`);
  }
  return new Uint16Array(arrayBuffer);
}

export function defaultFrameSelection(image) {
  const width = positiveInteger(image.width, "image width");
  const height = positiveInteger(image.height, "image height");
  return {
    kind: "full-image",
    x: 0,
    y: 0,
    w: width,
    h: height,
    cx: width / 2,
    cy: height / 2,
    angle: 0.0,
  };
}

export function normalizeFrameSelection(selection, image) {
  const full = defaultFrameSelection(image);
  if (!selection || selection.kind === "full-image") return full;

  const angle = Number(selection.angle ?? 0);
  if (!Number.isFinite(angle)) throw new Error("frame angle must be finite");

  const rawW = Number(selection.w);
  const rawH = Number(selection.h);
  if (!Number.isFinite(rawW) || !Number.isFinite(rawH) || rawW <= 0.0 || rawH <= 0.0) {
    throw new Error("frame rectangle contains invalid dimensions");
  }
  const rawCx = Number.isFinite(Number(selection.cx))
    ? Number(selection.cx)
    : Number(selection.x) + rawW / 2.0;
  const rawCy = Number.isFinite(Number(selection.cy))
    ? Number(selection.cy)
    : Number(selection.y) + rawH / 2.0;
  if (!Number.isFinite(rawCx) || !Number.isFinite(rawCy)) {
    throw new Error("frame rectangle contains non-finite values");
  }

  const x = rawCx - rawW / 2.0;
  const y = rawCy - rawH / 2.0;
  return {
    kind: "manual-rect",
    x,
    y,
    w: rawW,
    h: rawH,
    cx: rawCx,
    cy: rawCy,
    angle,
  };
}

export function frameCropGeometry(image, frameSelection = null) {
  const frame = normalizeFrameSelection(frameSelection, image);
  if (frame.kind === "full-image") {
    return {
      width: image.width,
      height: image.height,
      frame,
    };
  }
  if (isAxisAligned(frame)) {
    const bounds = axisAlignedFrameBounds(frame, image);
    return {
      width: bounds.w,
      height: bounds.h,
      frame: bounds,
    };
  }
  const width = Math.trunc(frame.w);
  const height = Math.trunc(frame.h);
  if (width <= 0 || height <= 0) throw new Error("rotated crop dimensions must be positive");
  return {
    width,
    height,
    frame,
  };
}

export function previewOutputGeometry(width, height, maxPixels = defaultPreviewMaxPixels) {
  const sourceWidth = positiveInteger(Math.trunc(width), "preview source width");
  const sourceHeight = positiveInteger(Math.trunc(height), "preview source height");
  const sourcePixels = sourceWidth * sourceHeight;
  const limit = positiveInteger(Math.trunc(maxPixels), "preview max pixels");
  if (sourcePixels <= limit) {
    return {
      width: sourceWidth,
      height: sourceHeight,
      scale: 1.0,
      max_pixels: limit,
    };
  }
  const scale = Math.sqrt(limit / sourcePixels);
  return {
    width: Math.max(1, Math.floor(sourceWidth * scale)),
    height: Math.max(1, Math.floor(sourceHeight * scale)),
    scale,
    max_pixels: limit,
  };
}

export function cropRgb16ToFrame(arrayBuffer, image, frameSelection = null) {
  const source = parseRawRgb16Buffer(arrayBuffer, image);
  const frame = normalizeFrameSelection(frameSelection, image);
  if (frame.kind === "full-image") {
    return {
      arrayBuffer: arrayBuffer.slice(0),
      width: image.width,
      height: image.height,
      frame,
    };
  }

  if (isAxisAligned(frame)) {
    return cropRgb16AxisAligned(source, image, frame);
  }
  return cropRgb16Rotated(source, image, frame);
}

export function computeDminFromRgb16(arrayBuffer, image, frameSelection = null, {
  percentile = 1.0,
  defaultLight = 65535.0,
} = {}) {
  if (!Number.isFinite(percentile) || percentile < 0.0 || percentile > 100.0) {
    throw new Error("Dmin percentile must be between 0 and 100");
  }
  if (!Number.isFinite(defaultLight) || defaultLight <= 0.0) {
    throw new Error("Dmin default light must be positive");
  }
  const cropped = cropRgb16ToFrame(arrayBuffer, image, frameSelection);
  const samples = parseRawRgb16Buffer(cropped.arrayBuffer, {
    width: cropped.width,
    height: cropped.height,
  });
  return [
    percentileDensityChannel(samples, 0, percentile, defaultLight),
    percentileDensityChannel(samples, 1, percentile, defaultLight),
    percentileDensityChannel(samples, 2, percentile, defaultLight),
  ];
}

function cropRgb16AxisAligned(source, image, frame) {
  const bounds = axisAlignedFrameBounds(frame, image);
  const out = new Uint16Array(bounds.w * bounds.h * 3);
  const sourceStride = image.width * 3;
  const copyWidth = bounds.w * 3;
  for (let row = 0; row < bounds.h; row += 1) {
    const sourceStart = (bounds.y + row) * sourceStride + bounds.x * 3;
    out.set(source.subarray(sourceStart, sourceStart + copyWidth), row * copyWidth);
  }
  return {
    arrayBuffer: out.buffer,
    width: bounds.w,
    height: bounds.h,
    frame: bounds,
  };
}

function percentileDensityChannel(samples, channel, percentile, defaultLight) {
  const pixelCount = samples.length / 3;
  const values = new Float64Array(pixelCount);
  for (let pixelIndex = 0; pixelIndex < pixelCount; pixelIndex += 1) {
    const sample = samples[pixelIndex * 3 + channel];
    const transmittance = Math.max(sample / defaultLight, 1.0e-8);
    values[pixelIndex] = -Math.log10(transmittance);
  }
  values.sort();
  const rank = ((values.length - 1) * percentile) / 100.0;
  const lower = Math.floor(rank);
  const upper = Math.ceil(rank);
  const fraction = rank - lower;
  return values[lower] * (1.0 - fraction) + values[upper] * fraction;
}

function cropRgb16Rotated(source, image, frame) {
  const cropped = cropRotatedSamples({
    source,
    sourceWidth: image.width,
    sourceHeight: image.height,
    channels: 3,
    frame,
    ArrayType: Uint16Array,
    sampleMapper: roundToU16,
  });
  return {
    arrayBuffer: cropped.buffer,
    width: cropped.width,
    height: cropped.height,
    frame,
  };
}

export function cropIrScalarToRgbFrame(arrayBuffer, image, frameSelection = null, sampleFormat = "u8") {
  if (!image.ir) throw new Error("IR crop requires image.ir metadata");
  const frame = normalizeFrameSelection(frameSelection, image);
  const ArrayType = scalarArrayType(sampleFormat);
  const source = new ArrayType(arrayBuffer);
  if (source.length !== image.ir.width * image.ir.height) {
    throw new Error(`IR input size ${source.length} does not match ${image.ir.width}x${image.ir.height}`);
  }
  if (frame.kind === "full-image") {
    return {
      arrayBuffer: arrayBuffer.slice(0),
      width: image.ir.width,
      height: image.ir.height,
      frame,
    };
  }

  const scaleX = image.ir.width / image.width;
  const scaleY = image.ir.height / image.height;
  const irFrame = normalizeFrameSelection({
    kind: "manual-rect",
    cx: frame.cx * scaleX,
    cy: frame.cy * scaleY,
    w: frame.w * scaleX,
    h: frame.h * scaleY,
    angle: frame.angle,
  }, { width: image.ir.width, height: image.ir.height });
  if (!isAxisAligned(irFrame)) {
    const cropped = cropScalarRotated(source, image.ir.width, image.ir.height, irFrame, ArrayType);
    return {
      ...cropped,
      frame,
    };
  }
  const x0 = clampInt(Math.floor(frame.x * scaleX), 0, image.ir.width - 1);
  const y0 = clampInt(Math.floor(frame.y * scaleY), 0, image.ir.height - 1);
  const x1 = clampInt(Math.ceil((frame.x + frame.w) * scaleX), x0 + 1, image.ir.width);
  const y1 = clampInt(Math.ceil((frame.y + frame.h) * scaleY), y0 + 1, image.ir.height);
  const width = x1 - x0;
  const height = y1 - y0;
  const out = new ArrayType(width * height);
  for (let row = 0; row < height; row += 1) {
    const sourceStart = (y0 + row) * image.ir.width + x0;
    out.set(source.subarray(sourceStart, sourceStart + width), row * width);
  }
  return {
    arrayBuffer: out.buffer,
    width,
    height,
    frame,
  };
}

function cropScalarRotated(source, width, height, frame, ArrayType) {
  const cropped = cropRotatedSamples({
    source,
    sourceWidth: width,
    sourceHeight: height,
    channels: 1,
    frame,
    ArrayType,
    sampleMapper: ArrayType === Uint8Array ? roundToU8 : (value) => value,
  });
  return {
    arrayBuffer: cropped.buffer,
    width: cropped.width,
    height: cropped.height,
  };
}

function cropRotatedSamples({
  source,
  sourceWidth,
  sourceHeight,
  channels,
  frame,
  ArrayType,
  sampleMapper,
}) {
  const finalWidth = Math.trunc(frame.w);
  const finalHeight = Math.trunc(frame.h);
  if (finalWidth <= 0 || finalHeight <= 0) throw new Error("rotated crop dimensions must be positive");

  const diagonal = Math.hypot(frame.w, frame.h) / 2.0;
  const margin = Math.ceil(diagonal) + 4;
  const cxInt = Math.trunc(frame.cx);
  const cyInt = Math.trunc(frame.cy);
  const x0 = Math.max(cxInt - margin, 0);
  const y0 = Math.max(cyInt - margin, 0);
  const x1 = Math.min(cxInt + margin, sourceWidth);
  const y1 = Math.min(cyInt + margin, sourceHeight);
  if (x1 <= x0 || y1 <= y0) throw new Error("rotated crop lies outside the image");

  const subWidth = x1 - x0;
  const subHeight = y1 - y0;
  const localCx = frame.cx - x0;
  const localCy = frame.cy - y0;
  const pad = 2;
  const outWidth = Math.ceil(frame.w) + pad * 2;
  const outHeight = Math.ceil(frame.h) + pad * 2;
  const alpha = Math.cos(frame.angle);
  const beta = Math.sin(frame.angle);
  const m00 = alpha;
  const m01 = beta;
  let m02 = (1.0 - alpha) * localCx - beta * localCy;
  const m10 = -beta;
  const m11 = alpha;
  let m12 = beta * localCx + (1.0 - alpha) * localCy;
  m02 += outWidth / 2.0 - localCx;
  m12 += outHeight / 2.0 - localCy;

  const det = m00 * m11 - m01 * m10;
  if (Math.abs(det) < 1.0e-12) throw new Error("rotated crop transform is singular");
  const inv00 = m11 / det;
  const inv01 = -m01 / det;
  const inv10 = -m10 / det;
  const inv11 = m00 / det;

  const out = new ArrayType(finalWidth * finalHeight * channels);
  for (let outY = 0; outY < finalHeight; outY += 1) {
    for (let outX = 0; outX < finalWidth; outX += 1) {
      const dstX = outX + pad;
      const dstY = outY + pad;
      const tx = dstX - m02;
      const ty = dstY - m12;
      const srcX = inv00 * tx + inv01 * ty;
      const srcY = inv10 * tx + inv11 * ty;
      const outBase = (outY * finalWidth + outX) * channels;
      sampleReflectBilinear(source, sourceWidth, x0, y0, subWidth, subHeight, srcX, srcY, channels, out, outBase, sampleMapper);
    }
  }
  return { buffer: out.buffer, width: finalWidth, height: finalHeight };
}

function sampleReflectBilinear(source, sourceWidth, x0, y0, subWidth, subHeight, x, y, channels, out, outBase, sampleMapper) {
  const xFloor = Math.floor(x);
  const yFloor = Math.floor(y);
  const fx = x - xFloor;
  const fy = y - yFloor;
  const xa = reflectIndex(xFloor, subWidth);
  const xb = reflectIndex(xFloor + 1, subWidth);
  const ya = reflectIndex(yFloor, subHeight);
  const yb = reflectIndex(yFloor + 1, subHeight);
  const offset00 = ((y0 + ya) * sourceWidth + x0 + xa) * channels;
  const offset10 = ((y0 + ya) * sourceWidth + x0 + xb) * channels;
  const offset01 = ((y0 + yb) * sourceWidth + x0 + xa) * channels;
  const offset11 = ((y0 + yb) * sourceWidth + x0 + xb) * channels;
  for (let channel = 0; channel < channels; channel += 1) {
    const p00 = source[offset00 + channel];
    const p10 = source[offset10 + channel];
    const p01 = source[offset01 + channel];
    const p11 = source[offset11 + channel];
    const top = p00 * (1.0 - fx) + p10 * fx;
    const bottom = p01 * (1.0 - fx) + p11 * fx;
    out[outBase + channel] = sampleMapper(top * (1.0 - fy) + bottom * fy);
  }
}

function axisAlignedFrameBounds(frame, image) {
  const x = clampInt(Math.round(frame.x), 0, image.width - 1);
  const y = clampInt(Math.round(frame.y), 0, image.height - 1);
  const w = clampInt(Math.round(frame.w), 1, image.width - x);
  const h = clampInt(Math.round(frame.h), 1, image.height - y);
  return {
    ...frame,
    x,
    y,
    w,
    h,
    cx: x + w / 2.0,
    cy: y + h / 2.0,
    angle: 0.0,
  };
}

export function scalarArrayBufferToF32(arrayBuffer, sampleFormat = "u8") {
  const ArrayType = scalarArrayType(sampleFormat);
  const source = new ArrayType(arrayBuffer);
  const out = new Float32Array(source.length);
  for (let index = 0; index < source.length; index += 1) out[index] = source[index];
  return out.buffer;
}

export function requiredInpaintNoiseSamples(mask, width, height, padding = 16) {
  if (mask.length !== width * height) throw new Error("mask length does not match dimensions");
  const labels = new Uint32Array(mask.length);
  const stack = new Uint32Array(mask.length);
  let label = 0;
  let total = 0;
  for (let start = 0; start < mask.length; start += 1) {
    if (mask[start] === 0 || labels[start] !== 0) continue;
    label += 1;
    let stackLen = 1;
    stack[0] = start;
    labels[start] = label;
    let left = start % width;
    let right = left + 1;
    let top = Math.floor(start / width);
    let bottom = top + 1;
    while (stackLen > 0) {
      stackLen -= 1;
      const index = stack[stackLen];
      const x = index % width;
      const y = Math.floor(index / width);
      left = Math.min(left, x);
      right = Math.max(right, x + 1);
      top = Math.min(top, y);
      bottom = Math.max(bottom, y + 1);
      for (let dy = -1; dy <= 1; dy += 1) {
        for (let dx = -1; dx <= 1; dx += 1) {
          if (dx === 0 && dy === 0) continue;
          const nx = x + dx;
          const ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
          const next = ny * width + nx;
          if (mask[next] === 0 || labels[next] !== 0) continue;
          labels[next] = label;
          stack[stackLen] = next;
          stackLen += 1;
        }
      }
    }
    const x0 = Math.max(0, left - padding);
    const y0 = Math.max(0, top - padding);
    const x1 = Math.min(width, right + padding);
    const y1 = Math.min(height, bottom + padding);
    total += (x1 - x0) * (y1 - y0) * 3;
  }
  return total;
}

export function generateStandardNormalNoise(sampleCount, random = Math.random) {
  const out = new Float64Array(sampleCount);
  for (let index = 0; index < out.length; index += 2) {
    const u1 = Math.max(Number.MIN_VALUE, random());
    const u2 = random();
    const radius = Math.sqrt(-2.0 * Math.log(u1));
    const theta = 2.0 * Math.PI * u2;
    out[index] = radius * Math.cos(theta);
    if (index + 1 < out.length) out[index + 1] = radius * Math.sin(theta);
  }
  return out.buffer;
}

export function randomNoiseSeed() {
  if (globalThis.crypto?.getRandomValues) {
    const values = new Uint32Array(4);
    globalThis.crypto.getRandomValues(values);
    return Array.from(values, (value) => value.toString(16).padStart(8, "0")).join("-");
  }
  const high = Date.now().toString(16);
  const low = Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, "0");
  return `${high}-${low}`;
}

export async function exportRawNegativeRgb16({
  arrayBuffer,
  file,
  image,
  stockId = stockIds.kodakGold,
  render = defaultRenderConfig(),
  dmin = [0.05, 0.06, 0.07],
  percentileSampleLimit = 16384,
  frameSelection = null,
  variant = exportVariants.irNeg,
}) {
  const started = performance.now();
  parseRawRgb16Buffer(arrayBuffer, image);
  const cropped = cropRgb16ToFrame(arrayBuffer, image, frameSelection);
  const stock = stockName(stockId);
  const cacheInput = buildPreviewCacheInput({
    file,
    image,
    stock,
    stockId,
    render,
    dmin,
    frameSelection: cropped.frame,
    preview: {
      max_px: cropped.width * cropped.height,
      output_width: cropped.width,
      output_height: cropped.height,
      percentile_sample_limit: percentileSampleLimit,
    },
    output: {
      kind: "rgb16-negative-export",
      color_space: "scanner-rgb",
      variant: variant.id,
    },
  });
  return {
    cacheKey: await exportCacheKey(cacheInput),
    rgb16: new Uint16Array(cropped.arrayBuffer),
    width: cropped.width,
    height: cropped.height,
    frame: cropped.frame,
    timings: [
      {
        stage: "browser.raw-negative-export",
        elapsed_us: Math.round((performance.now() - started) * 1000),
      },
    ],
  };
}

export async function exportNativeVariantResults({
  client,
  arrayBuffer,
  irBuffer = null,
  irSampleFormat = "u8",
  file,
  image,
  stockId = stockIds.kodakGold,
  render = defaultRenderConfig(),
  dmin = [0.05, 0.06, 0.07],
  percentileSampleLimit = 16384,
  frameSelections = [null],
  variants = enabledExportVariants(defaultOutputSelection()),
  dustRemoval = defaultDustRemovalConfig(),
  transferInput = false,
}) {
  const exported = [];
  const canTransferInput = transferInput && frameSelections.length * variants.length === 1;
  for (let frameIndex = 0; frameIndex < frameSelections.length; frameIndex += 1) {
    const frameSelection = frameSelections[frameIndex];
    for (const variant of variants) {
      const result = variant.needs_ir && irBuffer
        ? await client.exportIrCleanedRgb16({
          arrayBuffer,
          irBuffer,
          irSampleFormat,
          file,
          image,
          stockId,
          render,
          dmin,
          percentileSampleLimit,
          frameSelection,
          variant,
          dustRemoval,
        })
        : variant.needs_invert
        ? await client.exportRawRgb16({
          arrayBuffer,
          file,
          image,
          stockId,
          render,
          dmin,
          percentileSampleLimit,
          frameSelection,
          variant,
          transferInput: canTransferInput,
        })
        : await exportRawNegativeRgb16({
          arrayBuffer,
          file,
          image,
          stockId,
          render,
          dmin,
          percentileSampleLimit,
          frameSelection,
          variant,
        });
      const metadata = buildNativeVariantExportMetadata({
        file,
        image,
        frame: result.frame,
        variant,
        stockId,
        render,
        dmin,
        cacheKey: result.cacheKey,
        output: {
          kind: "rgb16-export",
          format: "tiff",
          color_space: variant.needs_invert ? "srgb" : "scanner-rgb",
          bit_depth: 16,
          width: result.width,
          height: result.height,
        },
        timings: result.timings,
        irCleaning: variant.needs_ir && irBuffer ? result.mode ?? "browser-ir-cleaned" : "browser-no-ir-fallback",
      });
      exported.push({
        frameIndex,
        variant,
        result,
        metadata,
        filename: nativeExportFilename({ sourceName: file.name, frameIndex, variant }),
        metadataFilename: nativeExportMetadataFilename({ sourceName: file.name, frameIndex, variant }),
      });
    }
  }
  return exported;
}

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

export function defaultFrameDetectConfig(overrides = {}) {
  return {
    format: "35mm",
    frame_count_override: null,
    detect_film_extent: true,
    apply_clahe: true,
    ...overrides,
  };
}

export function frameSelectionFromDetectedFrame(frame, scale = 1.0) {
  const cx = Number(frame.cx);
  const cy = Number(frame.cy);
  const w = Number(frame.w) * scale;
  const h = Number(frame.h) * scale;
  const angle = Number(frame.angle ?? 0);
  if (!Number.isFinite(cx) || !Number.isFinite(cy) || !Number.isFinite(w) || !Number.isFinite(h) || !Number.isFinite(angle)) {
    throw new Error("detected frame contains non-finite values");
  }
  return {
    kind: "manual-rect",
    x: cx - w / 2.0,
    y: cy - h / 2.0,
    w,
    h,
    cx,
    cy,
    angle,
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

export function rgb8ToRgba(rgb8) {
  const rgba = new Uint8ClampedArray((rgb8.length / 3) * 4);
  for (let src = 0, dst = 0; src < rgb8.length; src += 3, dst += 4) {
    rgba[dst] = rgb8[src];
    rgba[dst + 1] = rgb8[src + 1];
    rgba[dst + 2] = rgb8[src + 2];
    rgba[dst + 3] = 255;
  }
  return rgba;
}

export function nativeExportFilename({ sourceName, frameIndex = 0, variant }) {
  const sourceStem = sanitizeStem(sourceName.replace(/\.[^.]*$/, "")) || "scan";
  return `${sourceStem}_${String(frameIndex + 1).padStart(2, "0")}${variant.suffix}.tif`;
}

export function nativeExportMetadataFilename({ sourceName, frameIndex = 0, variant }) {
  return `${nativeExportFilename({ sourceName, frameIndex, variant })}.json`;
}

export function buildNativeVariantExportMetadata({
  file,
  image,
  frame,
  variant,
  stockId,
  render,
  dmin,
  cacheKey,
  output,
  timings = [],
  irCleaning = "browser-no-ir-fallback",
}) {
  const metadata = {
    schema: "v600.webapp.native-export-metadata.v1",
    source: file.name,
    source_file: file,
    source_image: {
      width: image.width,
      height: image.height,
      dpi: image.dpi ?? null,
      channels: 3,
      bit_depth: 16,
      page_layout: image.page_layout ?? "rgb",
      ir: image.ir ?? null,
    },
    rebate_rect: null,
    crop: {
      cx: frame.cx,
      cy: frame.cy,
      w: frame.w,
      h: frame.h,
      angle: frame.angle,
    },
    frame,
    variant: variant.metadata_variant,
    output: {
      kind: output.kind,
      format: output.format,
      color_space: output.color_space,
      bit_depth: output.bit_depth,
      width: output.width,
      height: output.height,
    },
    cache_key: cacheKey,
    timings,
    browser_notes: {
      ir_cleaning: irCleaning,
    },
  };
  if (variant.id !== exportVariants.irNeg.id) {
    metadata.stock = stockName(stockId);
    metadata.contrast = render.contrast;
    metadata.dmin = dmin;
  }
  return metadata;
}

export function metadataJsonBytes(metadata) {
  return new TextEncoder().encode(`${JSON.stringify(metadata, null, 2)}\n`);
}

export function drawRgb8ToCanvas(canvas, rgb8, width, height) {
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d");
  const imageData = new ImageData(rgb8ToRgba(rgb8), width, height);
  context.putImageData(imageData, 0, 0);
}

export class WebPreviewClient {
  constructor({ worker, wasmUrl, timeoutMs = 5000 }) {
    this.worker = worker;
    this.wasmUrl = wasmUrl;
    this.timeoutMs = timeoutMs;
    this.sequence = 0;
    this.loadPromise = null;
    this.loaded = false;
    this.readyMessage = null;
  }

  async loadModule() {
    if (this.loaded) return this.readyMessage;
    if (this.loadPromise) return this.loadPromise;
    const requestId = this.nextRequestId("load");
    const ready = this.waitFor((message) => {
      return message.request_id === requestId && (
        message.type === messageTypes.ready ||
        message.type === messageTypes.error
      );
    });
    this.post(createLoadModuleMessage({
      requestId,
      wasmUrl: this.wasmUrl,
      wasmSha256: null,
    }));
    this.loadPromise = ready.then((message) => {
      if (message.type === messageTypes.error) {
        throw new Error(`worker load failed: ${message.message}`);
      }
      this.loaded = true;
      this.readyMessage = message;
      return message;
    }, (err) => {
      this.loadPromise = null;
      throw err;
    });
    return this.loadPromise;
  }

  async detectFramesRgb16({
    arrayBuffer,
    file,
    image,
    detection = defaultFrameDetectConfig(),
    maxFrames = 32,
  }) {
    await this.loadModule();
    parseRawRgb16Buffer(arrayBuffer, image);
    const normalizedDetection = defaultFrameDetectConfig(detection);
    const cacheInput = buildFrameDetectCacheInput({
      file,
      image,
      detection: normalizedDetection,
    });
    const cacheKey = await frameDetectCacheKey(cacheInput);
    const requestId = this.nextRequestId("frame-detect");
    const generation = this.sequence;
    const rawBuffer = arrayBuffer.slice(0);
    const result = this.waitFor((message) => {
      return message.request_id === requestId && (
        message.type === messageTypes.frameDetectResult ||
        message.type === messageTypes.error ||
        message.type === messageTypes.staleResult
      );
    });
    const processMessage = createProcessFrameDetectMessage({
      requestId,
      generation,
      cacheKey,
      cacheKeyPayload: cacheInput,
      buffers: {
        raw_rgb: {
          buffer: rawBuffer,
          samples: rawBuffer.byteLength / 2,
        },
      },
      options: {
        frame_detect_options_layout: "FrameDetectOptions/v1",
        frame_detect_options: defaultFrameDetectOptions({
          image,
          detection: normalizedDetection,
        }),
        max_frames: maxFrames,
      },
    });
    this.post(processMessage, [rawBuffer]);
    const message = await result;
    if (message.type === messageTypes.error) {
      throw new Error(message.message);
    }
    if (message.type === messageTypes.staleResult) {
      throw new Error(`stale frame detection result: ${message.reason}`);
    }
    return {
      cacheKey,
      frames: message.frames,
      aspect: message.aspect,
      rebate: message.rebate,
      timings: message.timings,
    };
  }

  async processRawRgb16({
    arrayBuffer,
    file,
    image,
    stockId = stockIds.kodakGold,
    render = defaultRenderConfig(),
    dmin = [0.05, 0.06, 0.07],
    previewMaxPx = image.width * image.height,
    percentileSampleLimit = 16384,
    frameSelection = null,
    transferInput = false,
  }) {
    await this.loadModule();
    parseRawRgb16Buffer(arrayBuffer, image);
    const crop = frameCropGeometry(image, frameSelection);
    const previewGeometry = previewOutputGeometry(crop.width, crop.height, previewMaxPx);
    const stock = stockName(stockId);
    const cacheInput = buildPreviewCacheInput({
      file,
      image,
      stock,
      stockId,
      render,
      dmin,
      frameSelection: crop.frame,
      preview: {
        max_px: previewGeometry.max_pixels,
        output_width: previewGeometry.width,
        output_height: previewGeometry.height,
        scale: previewGeometry.scale,
        percentile_sample_limit: percentileSampleLimit,
      },
    });
    const cacheKey = await previewCacheKey(cacheInput);
    const requestId = this.nextRequestId("preview");
    const generation = this.sequence;
    const rawBuffer = transferInput ? arrayBuffer : arrayBuffer.slice(0);
    const result = this.waitFor((message) => {
      return message.request_id === requestId && (
        message.type === messageTypes.previewResult ||
        message.type === messageTypes.error ||
        message.type === messageTypes.staleResult
      );
    });
    const processMessage = createProcessPreviewMessage({
      requestId,
      generation,
      cacheKey,
      cacheKeyPayload: cacheInput,
      buffers: {
        raw_rgb: {
          buffer: rawBuffer,
          samples: rawBuffer.byteLength / 2,
        },
      },
      options: {
        preview_options_layout: "PreviewOptions/v1",
        preview_options: defaultPreviewOptions({
          width: previewGeometry.width,
          height: previewGeometry.height,
          stock: stockId,
          render,
          dmin,
          percentileSampleLimit,
        }),
        input: {
          width: crop.width,
          height: crop.height,
        },
        crop: crop.frame.kind === "full-image" ? null : {
          image,
          frame_selection: crop.frame,
        },
        resize: previewGeometry.width === crop.width && previewGeometry.height === crop.height
          ? null
          : {
            width: previewGeometry.width,
            height: previewGeometry.height,
            mode: "area-box",
          },
      },
    });
    this.post(processMessage, [rawBuffer]);
    const message = await result;
    if (message.type === messageTypes.error) {
      throw new Error(message.message);
    }
    if (message.type === messageTypes.staleResult) {
      throw new Error(`stale preview result: ${message.reason}`);
    }
    return {
      cacheKey,
      rgb8: new Uint8Array(message.output.buffer),
      width: message.output.width,
      height: message.output.height,
      frame: crop.frame,
      previewScale: previewGeometry.scale,
      timings: message.timings,
    };
  }

  async exportRawRgb16({
    arrayBuffer,
    file,
    image,
    stockId = stockIds.kodakGold,
    render = defaultRenderConfig(),
    dmin = [0.05, 0.06, 0.07],
    percentileSampleLimit = 16384,
    frameSelection = null,
    variant = exportVariants.irInv,
    transferInput = false,
  }) {
    await this.loadModule();
    parseRawRgb16Buffer(arrayBuffer, image);
    const crop = frameCropGeometry(image, frameSelection);
    const stock = stockName(stockId);
    const cacheInput = buildPreviewCacheInput({
      file,
      image,
      stock,
      stockId,
      render,
      dmin,
      frameSelection: crop.frame,
      preview: {
        max_px: crop.width * crop.height,
        output_width: crop.width,
        output_height: crop.height,
        percentile_sample_limit: percentileSampleLimit,
      },
      output: { kind: "rgb16-export", color_space: "srgb", variant: variant.id },
    });
    const cacheKey = await exportCacheKey(cacheInput);
    const requestId = this.nextRequestId("export");
    const generation = this.sequence;
    const rawBuffer = transferInput ? arrayBuffer : arrayBuffer.slice(0);
    const result = this.waitFor((message) => {
      return message.request_id === requestId && (
        message.type === messageTypes.exportResult ||
        message.type === messageTypes.error ||
        message.type === messageTypes.staleResult
      );
    });
    const processMessage = createProcessExportMessage({
      requestId,
      generation,
      cacheKey,
      cacheKeyPayload: cacheInput,
      buffers: {
        raw_rgb: {
          buffer: rawBuffer,
          samples: rawBuffer.byteLength / 2,
        },
      },
      options: {
        preview_options_layout: "PreviewOptions/v1",
        preview_options: defaultPreviewOptions({
          width: crop.width,
          height: crop.height,
          stock: stockId,
          render,
          dmin,
          percentileSampleLimit,
        }),
        crop: crop.frame.kind === "full-image" ? null : {
          image,
          frame_selection: crop.frame,
        },
      },
    });
    this.post(processMessage, [rawBuffer]);
    const message = await result;
    if (message.type === messageTypes.error) {
      throw new Error(message.message);
    }
    if (message.type === messageTypes.staleResult) {
      throw new Error(`stale export result: ${message.reason}`);
    }
    return {
      cacheKey,
      rgb16: new Uint16Array(message.output.buffer),
      width: message.output.width,
      height: message.output.height,
      frame: crop.frame,
      timings: message.timings,
    };
  }

  async makeIrMaskF32({
    irBuffer,
    file,
    image,
    dustRemoval = defaultDustRemovalConfig(),
  }) {
    await this.loadModule();
    if (!image.ir) throw new Error("IR mask processing requires image.ir metadata");
    if (irBuffer.byteLength !== image.ir.width * image.ir.height * 4) {
      throw new Error(`IR f32 input size ${irBuffer.byteLength} does not match ${image.ir.width}x${image.ir.height}`);
    }
    const cacheInput = buildIrMaskCacheInput({
      file,
      image,
      dustRemoval,
    });
    const cacheKey = await irMaskCacheKey(cacheInput);
    const requestId = this.nextRequestId("ir-mask-f32");
    const generation = this.sequence;
    const result = this.waitFor((message) => {
      return message.request_id === requestId && (
        message.type === messageTypes.irMaskResult ||
        message.type === messageTypes.error ||
        message.type === messageTypes.staleResult
      );
    });
    const processMessage = createProcessIrMaskMessage({
      requestId,
      generation,
      cacheKey,
      cacheKeyPayload: cacheInput,
      buffers: {
        ir: {
          buffer: irBuffer,
          samples: irBuffer.byteLength / 4,
          format: "f32",
        },
      },
      options: {
        ir_mask_options_layout: "IrMaskOptions/v1",
        ir_mask_options: defaultIrMaskOptions({ image, dustRemoval }),
      },
    });
    this.post(processMessage, [irBuffer]);
    const message = await result;
    if (message.type === messageTypes.error) {
      throw new Error(message.message);
    }
    if (message.type === messageTypes.staleResult) {
      throw new Error(`stale IR f32 mask result: ${message.reason}`);
    }
    return {
      cacheKey,
      mask: new Uint8Array(message.output.buffer),
      width: message.output.width,
      height: message.output.height,
      timings: message.timings,
    };
  }

  async resizeIrMaskToRgbU8({
    maskBuffer,
    file,
    image,
    dustRemoval = defaultDustRemovalConfig(),
    irMaskCacheKey,
  }) {
    await this.loadModule();
    if (!image.ir) throw new Error("RGB-sized IR mask processing requires image.ir metadata");
    if (maskBuffer.byteLength !== image.ir.width * image.ir.height) {
      throw new Error(`IR mask size ${maskBuffer.byteLength} does not match ${image.ir.width}x${image.ir.height}`);
    }
    const cacheInput = buildIrRgbMaskCacheInput({
      file,
      image,
      dustRemoval,
      irMaskCacheKey,
    });
    const cacheKey = await irRgbMaskCacheKey(cacheInput);
    const requestId = this.nextRequestId("ir-rgb-mask");
    const generation = this.sequence;
    const result = this.waitFor((message) => {
      return message.request_id === requestId && (
        message.type === messageTypes.irRgbMaskResult ||
        message.type === messageTypes.error ||
        message.type === messageTypes.staleResult
      );
    });
    const processMessage = createProcessIrRgbMaskMessage({
      requestId,
      generation,
      cacheKey,
      cacheKeyPayload: cacheInput,
      buffers: {
        ir_mask: {
          buffer: maskBuffer,
          samples: maskBuffer.byteLength,
        },
      },
      options: {
        ir_mask_resize_options_layout: "IrMaskResizeOptions/v1",
        ir_mask_resize_options: defaultIrMaskResizeOptions({ image }),
      },
    });
    this.post(processMessage, [maskBuffer]);
    const message = await result;
    if (message.type === messageTypes.error) {
      throw new Error(message.message);
    }
    if (message.type === messageTypes.staleResult) {
      throw new Error(`stale RGB-sized IR mask result: ${message.reason}`);
    }
    return {
      cacheKey,
      mask: new Uint8Array(message.output.buffer),
      width: message.output.width,
      height: message.output.height,
      timings: message.timings,
    };
  }

  async inpaintGrainRgb16WithNoise({
    rgbBuffer,
    maskBuffer,
    noiseBuffer = null,
    noiseSeed = null,
    file,
    image,
    dustRemoval = defaultDustRemovalConfig(),
    rgbMaskCacheKey,
    padding = 16,
    grainPadding = 8,
  }) {
    await this.loadModule();
    if (rgbBuffer.byteLength !== image.width * image.height * 3 * 2) {
      throw new Error(`RGB16 input size ${rgbBuffer.byteLength} does not match ${image.width}x${image.height}`);
    }
    if (maskBuffer.byteLength !== image.width * image.height) {
      throw new Error(`RGB mask size ${maskBuffer.byteLength} does not match ${image.width}x${image.height}`);
    }
    if (noiseBuffer && noiseBuffer.byteLength % 8 !== 0) {
      throw new Error(`grain noise buffer size ${noiseBuffer.byteLength} is not Float64-aligned`);
    }
    if (!noiseBuffer && !noiseSeed) {
      throw new Error("grain-aware inpaint requires either a noise buffer or a noise seed");
    }
    const noiseHash = noiseBuffer ? await sha256ArrayBuffer(noiseBuffer) : `seed:${noiseSeed}`;
    const cacheInput = buildIrInpaintCacheInput({
      file,
      image,
      dustRemoval,
      rgbMaskCacheKey,
      mode: "biharmonic-grain",
      padding,
      grainPadding,
      noiseHash,
    });
    const cacheKey = await irInpaintCacheKey(cacheInput);
    const requestId = this.nextRequestId("ir-inpaint-grain");
    const generation = this.sequence;
    const result = this.waitFor((message) => {
      return message.request_id === requestId && (
        message.type === messageTypes.irInpaintResult ||
        message.type === messageTypes.error ||
        message.type === messageTypes.staleResult
      );
    });
    const processMessage = createProcessIrInpaintMessage({
      requestId,
      generation,
      cacheKey,
      cacheKeyPayload: cacheInput,
      buffers: {
        rgb: {
          buffer: rgbBuffer,
          samples: rgbBuffer.byteLength / 2,
        },
        rgb_mask: {
          buffer: maskBuffer,
          samples: maskBuffer.byteLength,
        },
        ...(noiseBuffer ? {
          noise: {
            buffer: noiseBuffer,
            samples: noiseBuffer.byteLength / 8,
          },
        } : {}),
      },
      options: {
        ir_inpaint_grain_options_layout: "IrInpaintGrainOptions/v1",
        ir_inpaint_grain_options: {
          ...defaultIrInpaintGrainOptions({ image, padding, grainPadding }),
          noise_seed: noiseSeed,
        },
      },
    });
    this.post(processMessage, noiseBuffer ? [rgbBuffer, maskBuffer, noiseBuffer] : [rgbBuffer, maskBuffer]);
    const message = await result;
    if (message.type === messageTypes.error) {
      throw new Error(message.message);
    }
    if (message.type === messageTypes.staleResult) {
      throw new Error(`stale IR inpaint grain result: ${message.reason}`);
    }
    return {
      cacheKey,
      rgb16: new Uint16Array(message.output.buffer),
      width: message.output.width,
      height: message.output.height,
      mode: message.output.mode,
      timings: message.timings,
      noiseHash,
    };
  }

  async prepareIrCleanCrops({
    arrayBuffer,
    irBuffer,
    file,
    image,
    frameSelection = null,
    alignment = null,
  }) {
    await this.loadModule();
    if (!image.ir) throw new Error("IR-clean crop requires image.ir metadata");
    parseRawRgb16Buffer(arrayBuffer, image);
    if (irBuffer.byteLength !== image.ir.width * image.ir.height * 4) {
      throw new Error(`aligned IR f32 input size ${irBuffer.byteLength} does not match ${image.ir.width}x${image.ir.height}`);
    }
    const normalizedFrame = normalizeFrameSelection(frameSelection, image);
    const cacheInput = buildIrCleanCropCacheInput({
      file,
      image,
      frameSelection: normalizedFrame,
      alignment,
    });
    const cacheKey = await irCleanCropCacheKey(cacheInput);
    const requestId = this.nextRequestId("ir-clean-crop");
    const generation = this.sequence;
    const result = this.waitFor((message) => {
      return message.request_id === requestId && (
        message.type === messageTypes.irCleanCropResult ||
        message.type === messageTypes.error ||
        message.type === messageTypes.staleResult
      );
    });
    const processMessage = createProcessIrCleanCropMessage({
      requestId,
      generation,
      cacheKey,
      cacheKeyPayload: cacheInput,
      buffers: {
        raw_rgb: {
          buffer: arrayBuffer,
          samples: arrayBuffer.byteLength / 2,
          format: "u16",
        },
        ir: {
          buffer: irBuffer,
          samples: irBuffer.byteLength / 4,
          format: "f32",
        },
      },
      options: {
        image,
        frame_selection: normalizedFrame,
      },
    });
    this.post(processMessage, [arrayBuffer, irBuffer]);
    const message = await result;
    if (message.type === messageTypes.error) {
      throw new Error(message.message);
    }
    if (message.type === messageTypes.staleResult) {
      throw new Error(`stale IR clean crop result: ${message.reason}`);
    }
    return {
      cacheKey,
      rgb16: new Uint16Array(message.output.rgb.buffer),
      irF32: new Float32Array(message.output.ir.buffer),
      width: message.output.rgb.width,
      height: message.output.rgb.height,
      irWidth: message.output.ir.width,
      irHeight: message.output.ir.height,
      frame: message.output.frame,
      timings: message.timings,
    };
  }

  async exportIrCleanedRgb16({
    arrayBuffer,
    irBuffer,
    irSampleFormat = "u8",
    file,
    image,
    stockId = stockIds.kodakGold,
    render = defaultRenderConfig(),
    dmin = [0.05, 0.06, 0.07],
    percentileSampleLimit = 16384,
    frameSelection = null,
    variant = exportVariants.irNeg,
    dustRemoval = defaultDustRemovalConfig(),
    noiseBuffer = null,
    alignIr = true,
    estimator = defaultIrEstimateConfig(),
    grainPadding = 8,
  }) {
    await this.loadModule();
    if (!variant.needs_ir) throw new Error(`variant ${variant.id} does not use IR cleaning`);
    if (!image.ir) throw new Error("IR-cleaned export requires image.ir metadata");
    parseRawRgb16Buffer(arrayBuffer, image);
    const irSampleBytes = scalarArrayType(irSampleFormat).BYTES_PER_ELEMENT;
    if (irBuffer.byteLength !== image.ir.width * image.ir.height * irSampleBytes) {
      throw new Error(`IR ${irSampleFormat} input size ${irBuffer.byteLength} does not match ${image.ir.width}x${image.ir.height}`);
    }

    const frame = frameCropGeometry(image, frameSelection).frame;
    let fullIrF32Buffer = null;
    let alignment = null;
    let alignmentTimings = [];
    if (alignIr) {
      try {
        const estimate = await this.estimateIrTranslationF32({
          rgbBuffer: arrayBuffer.slice(0),
          irBuffer: irBuffer.slice(0),
          rgbSampleFormat: "u16",
          irSampleFormat,
          file,
          image,
          estimator,
        });
        alignment = estimate.alignment;
        alignmentTimings = alignmentTimings.concat(estimate.timings);
        const aligned = await this.applyIrTranslationF32({
          irBuffer: irBuffer.slice(0),
          irSampleFormat,
          file,
          image,
          alignment,
        });
        fullIrF32Buffer = aligned.ir.buffer.slice(aligned.ir.byteOffset, aligned.ir.byteOffset + aligned.ir.byteLength);
        alignmentTimings = alignmentTimings.concat(aligned.timings);
      } catch (err) {
        alignment = { mode: "unaligned-fallback", error: err.message };
        alignmentTimings.push({ stage: "browser.ir-align-fallback", elapsed_us: 0, detail: err.message });
      }
    }
    if (!fullIrF32Buffer) {
      fullIrF32Buffer = scalarArrayBufferToF32(irBuffer, irSampleFormat);
    }

    const cropped = await this.prepareIrCleanCrops({
      arrayBuffer: arrayBuffer.slice(0),
      irBuffer: fullIrF32Buffer,
      file,
      image,
      frameSelection: frame,
      alignment,
    });
    const croppedRgbBuffer = cropped.rgb16.buffer.slice(cropped.rgb16.byteOffset, cropped.rgb16.byteOffset + cropped.rgb16.byteLength);
    const croppedIrBuffer = cropped.irF32.buffer.slice(cropped.irF32.byteOffset, cropped.irF32.byteOffset + cropped.irF32.byteLength);
    const cleanImage = {
      width: cropped.width,
      height: cropped.height,
      dpi: image.dpi ?? null,
      page_layout: image.page_layout ?? "rgb-thumb-ir",
      ir: {
        width: cropped.irWidth,
        height: cropped.irHeight,
        channels: 1,
        bit_depth: 32,
      },
    };
    const cropFile = {
      content_hash: cropped.cacheKey,
      name: `${file.name}.frame-${frame.x}-${frame.y}-${frame.w}x${frame.h}.aligned-ir-clean-input`,
      size: croppedRgbBuffer.byteLength + croppedIrBuffer.byteLength,
      last_modified_ms: file.last_modified_ms ?? 0,
    };

    const irMask = await this.makeIrMaskF32({
      irBuffer: croppedIrBuffer.slice(0),
      file: cropFile,
      image: cleanImage,
      dustRemoval,
    });
    const rgbMask = await this.resizeIrMaskToRgbU8({
      maskBuffer: irMask.mask.buffer.slice(irMask.mask.byteOffset, irMask.mask.byteOffset + irMask.mask.byteLength),
      file: cropFile,
      image: cleanImage,
      dustRemoval,
      irMaskCacheKey: irMask.cacheKey,
    });
    const padding = Number.isInteger(dustRemoval.inpaint_padding) ? dustRemoval.inpaint_padding : 16;
    const noiseSeed = noiseBuffer ? null : randomNoiseSeed();
    const cleaned = await this.inpaintGrainRgb16WithNoise({
      rgbBuffer: croppedRgbBuffer.slice(0),
      maskBuffer: rgbMask.mask.buffer.slice(rgbMask.mask.byteOffset, rgbMask.mask.byteOffset + rgbMask.mask.byteLength),
      noiseBuffer,
      noiseSeed,
      file: cropFile,
      image: cleanImage,
      dustRemoval,
      rgbMaskCacheKey: rgbMask.cacheKey,
      padding,
      grainPadding,
    });
    const cleanTimings = alignmentTimings
      .concat(cropped.timings)
      .concat(irMask.timings)
      .concat(rgbMask.timings)
      .concat(cleaned.timings);

    if (!variant.needs_invert) {
      return {
        cacheKey: cleaned.cacheKey,
        rgb16: cleaned.rgb16,
        width: cleaned.width,
        height: cleaned.height,
        frame,
        mode: cleaned.mode,
        alignment,
        timings: cleanTimings,
      };
    }

    const cleanedBuffer = cleaned.rgb16.buffer.slice(cleaned.rgb16.byteOffset, cleaned.rgb16.byteOffset + cleaned.rgb16.byteLength);
    const cleanedFile = await fileIdentity({
      name: `${file.name}.frame-${frame.x}-${frame.y}-${frame.w}x${frame.h}.ir-cleaned`,
      size: cleanedBuffer.byteLength,
      lastModified: file.last_modified_ms ?? 0,
      arrayBuffer: cleanedBuffer.slice(0),
    });
    const inverted = await this.exportRawRgb16({
      arrayBuffer: cleanedBuffer,
      file: cleanedFile,
      image: {
        width: cleaned.width,
        height: cleaned.height,
        dpi: image.dpi ?? null,
        page_layout: "rgb",
      },
      stockId,
      render,
      dmin,
      percentileSampleLimit,
      frameSelection: null,
      variant,
    });
    return {
      ...inverted,
      frame,
      alignment,
      timings: cleanTimings.concat(inverted.timings),
    };
  }

  async applyIrTranslationF32({
    irBuffer,
    irSampleFormat = "f32",
    file,
    image,
    alignment,
  }) {
    await this.loadModule();
    if (!image.ir) throw new Error("IR alignment processing requires image.ir metadata");
    const irSampleBytes = scalarArrayType(irSampleFormat).BYTES_PER_ELEMENT;
    if (irBuffer.byteLength !== image.ir.width * image.ir.height * irSampleBytes) {
      throw new Error(`IR ${irSampleFormat} input size ${irBuffer.byteLength} does not match ${image.ir.width}x${image.ir.height}`);
    }
    const cacheInput = buildIrAlignCacheInput({
      file,
      image,
      alignment,
    });
    const cacheKey = await irAlignCacheKey(cacheInput);
    const requestId = this.nextRequestId("ir-align");
    const generation = this.sequence;
    const result = this.waitFor((message) => {
      return message.request_id === requestId && (
        message.type === messageTypes.irAlignResult ||
        message.type === messageTypes.error ||
        message.type === messageTypes.staleResult
      );
    });
    const processMessage = createProcessIrAlignMessage({
      requestId,
      generation,
      cacheKey,
      cacheKeyPayload: cacheInput,
      buffers: {
        ir: {
          buffer: irBuffer,
          samples: irBuffer.byteLength / irSampleBytes,
          format: irSampleFormat,
        },
      },
      options: {
        ir_align_options_layout: "IrAlignOptions/v1",
        ir_align_options: defaultIrAlignOptions({ image, alignment }),
      },
    });
    this.post(processMessage, [irBuffer]);
    const message = await result;
    if (message.type === messageTypes.error) {
      throw new Error(message.message);
    }
    if (message.type === messageTypes.staleResult) {
      throw new Error(`stale IR alignment result: ${message.reason}`);
    }
    return {
      cacheKey,
      ir: new Float32Array(message.output.buffer),
      width: message.output.width,
      height: message.output.height,
      timings: message.timings,
    };
  }

  async estimateIrTranslationF32({
    rgbBuffer,
    irBuffer,
    rgbSampleFormat = "f32",
    irSampleFormat = "f32",
    file,
    image,
    estimator = defaultIrEstimateConfig(),
  }) {
    await this.loadModule();
    if (!image.ir) throw new Error("IR estimate processing requires image.ir metadata");
    const rgbSampleBytes = scalarArrayType(rgbSampleFormat).BYTES_PER_ELEMENT;
    const irSampleBytes = scalarArrayType(irSampleFormat).BYTES_PER_ELEMENT;
    if (rgbBuffer.byteLength !== image.width * image.height * 3 * rgbSampleBytes) {
      throw new Error(`RGB ${rgbSampleFormat} input size ${rgbBuffer.byteLength} does not match ${image.width}x${image.height}`);
    }
    if (irBuffer.byteLength !== image.ir.width * image.ir.height * irSampleBytes) {
      throw new Error(`IR ${irSampleFormat} input size ${irBuffer.byteLength} does not match ${image.ir.width}x${image.ir.height}`);
    }
    const cacheInput = buildIrEstimateCacheInput({
      file,
      image,
      estimator,
    });
    const cacheKey = await irEstimateCacheKey(cacheInput);
    const requestId = this.nextRequestId("ir-estimate");
    const generation = this.sequence;
    const result = this.waitFor((message) => {
      return message.request_id === requestId && (
        message.type === messageTypes.irEstimateResult ||
        message.type === messageTypes.error ||
        message.type === messageTypes.staleResult
      );
    });
    const processMessage = createProcessIrEstimateMessage({
      requestId,
      generation,
      cacheKey,
      cacheKeyPayload: cacheInput,
      buffers: {
        rgb: {
          buffer: rgbBuffer,
          samples: rgbBuffer.byteLength / rgbSampleBytes,
          format: rgbSampleFormat,
        },
        ir: {
          buffer: irBuffer,
          samples: irBuffer.byteLength / irSampleBytes,
          format: irSampleFormat,
        },
      },
      options: {
        ir_estimate_options_layout: "IrEstimateOptions/v1",
        ir_estimate_options: defaultIrEstimateOptions({ image, estimator }),
      },
    });
    this.post(processMessage, [rgbBuffer, irBuffer]);
    const message = await result;
    if (message.type === messageTypes.error) {
      throw new Error(message.message);
    }
    if (message.type === messageTypes.staleResult) {
      throw new Error(`stale IR estimate result: ${message.reason}`);
    }
    return {
      cacheKey,
      alignment: message.alignment,
      timings: message.timings,
    };
  }

  close() {
    this.loaded = false;
    this.readyMessage = null;
    this.loadPromise = null;
    if (typeof this.worker.terminate === "function") return this.worker.terminate();
    return undefined;
  }

  nextRequestId(prefix) {
    this.sequence += 1;
    return `${prefix}-${this.sequence}`;
  }

  post(message, transfer = []) {
    this.worker.postMessage(message, transfer);
  }

  waitFor(predicate) {
    return new Promise((resolve, reject) => {
      let removeListener = () => {};
      let timer = null;
      const cleanup = () => {
        if (timer !== null) clearTimeout(timer);
        removeListener();
      };
      if (this.timeoutMs > 0) {
        timer = setTimeout(() => {
          cleanup();
          reject(new Error("timed out waiting for web worker message"));
        }, this.timeoutMs);
      }
      const onMessage = (message) => {
        const payload = message?.data ?? message;
        if (!predicate(payload)) return;
        cleanup();
        resolve(payload);
      };
      const onError = (err) => {
        cleanup();
        reject(err);
      };
      removeListener = addWorkerListener(this.worker, onMessage, onError);
    });
  }
}

function addWorkerListener(worker, onMessage, onError) {
  let removed = false;
  if (typeof worker.addEventListener === "function") {
    worker.addEventListener("message", onMessage);
    worker.addEventListener("error", onError);
    return () => {
      if (removed) return;
      removed = true;
      worker.removeEventListener("message", onMessage);
      worker.removeEventListener("error", onError);
    };
  }
  worker.on("message", onMessage);
  worker.on("error", onError);
  return () => {
    if (removed) return;
    removed = true;
    worker.off("message", onMessage);
    worker.off("error", onError);
  };
}

async function sha256ArrayBuffer(arrayBuffer) {
  return `sha256:${toHex(await digestSha256(arrayBuffer))}`;
}

async function sha256Text(text) {
  return `sha256:${toHex(await digestSha256(new TextEncoder().encode(text)))}`;
}

async function digestSha256(bytes) {
  if (globalThis.crypto?.subtle) {
    return new Uint8Array(await globalThis.crypto.subtle.digest("SHA-256", bytes));
  }
  if (isNodeRuntime()) {
    const { createHash } = await import("node:crypto");
    return createHash("sha256").update(bytes).digest();
  }
  throw new Error("SHA-256 is unavailable in this browser");
}

function toHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function stockName(stockId) {
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

function stockCoefficientsHash(stockId) {
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

function frameFormatId(format) {
  const id = frameFormatIds[format ?? "35mm"];
  if (!id) throw new Error(`unsupported frame format: ${format}`);
  return id;
}

function positiveInteger(value, label) {
  if (!Number.isInteger(value) || value <= 0) throw new Error(`${label} must be a positive integer`);
  return value;
}

function scalarArrayType(sampleFormat) {
  switch (sampleFormat) {
    case "u8":
      return Uint8Array;
    case "u16":
      return Uint16Array;
    case "f32":
      return Float32Array;
    default:
      throw new Error(`unsupported scalar sample format: ${sampleFormat}`);
  }
}

function clampInt(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function isAxisAligned(frame) {
  return Math.abs(frame.angle) <= 1.0e-9;
}

function reflectIndex(index, length) {
  if (length <= 1) return 0;
  let reflected = index;
  while (reflected < 0 || reflected >= length) {
    if (reflected < 0) {
      reflected = -reflected - 1;
    } else {
      reflected = 2 * length - reflected - 1;
    }
  }
  return reflected;
}

function roundToU8(value) {
  if (!Number.isFinite(value) || value <= 0.0) return 0;
  if (value >= 255.0) return 255;
  return Math.round(value);
}

function roundToU16(value) {
  if (!Number.isFinite(value) || value <= 0.0) return 0;
  if (value >= 65535.0) return 65535;
  return Math.round(value);
}

function sanitizeStem(value) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 96);
}

function isNodeRuntime() {
  return typeof process !== "undefined" && !!process.versions?.node;
}
