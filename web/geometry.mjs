// Frame-selection and crop geometry math: normalization, axis-aligned and
// rotated RGB16/scalar crops, preview scaling, Dmin percentile estimation,
// and grain-noise sizing/generation.

import { clampInt, positiveInteger, reflectIndex, roundToU16, roundToU8, scalarArrayType } from "./util.mjs";

export const defaultPreviewMaxPixels = 2_000_000;

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

export function cropRgb16AxisAligned(source, image, frame) {
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

export function percentileDensityChannel(samples, channel, percentile, defaultLight) {
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

export function cropRgb16Rotated(source, image, frame) {
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

export function cropScalarRotated(source, width, height, frame, ArrayType) {
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

export function cropRotatedSamples({
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

export function sampleReflectBilinear(source, sourceWidth, x0, y0, subWidth, subHeight, x, y, channels, out, outBase, sampleMapper) {
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

export function axisAlignedFrameBounds(frame, image) {
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

export function isAxisAligned(frame) {
  return Math.abs(frame.angle) <= 1.0e-9;
}
