// Shared helpers for the browser Wasm smoke suite: synthetic fixture
// builders and tolerance assertions that were previously duplicated across
// wasm_core_smoke, worker_runtime_smoke, and webapp_shell_smoke.
import assert from "node:assert/strict";

export const frameDetectWidth = 180;
export const frameDetectHeight = 620;

export const expectedDetectedFrames = [
  { cx: 95.0, cy: 130.0, w: 100.0, h: 150.0, angle: 0.0 },
  { cx: 95.0, cy: 310.0, w: 100.0, h: 150.0, angle: 0.0 },
  { cx: 95.0, cy: 490.0, w: 100.0, h: 150.0, angle: 0.0 },
];

export function normalizedToU16(value) {
  if (!Number.isFinite(value) || value <= 0.0) return 0;
  if (value >= 1.0) return 65535;
  return Math.floor(value * 65535.0 + 0.5);
}

export function buildAlignmentRgbFixture(fixture) {
  const height = fixture.ir_shape[0];
  const width = fixture.ir_shape[1];
  const ratio = fixture.ratio;
  const base = new Float64Array(width * height);
  let minValue = Number.POSITIVE_INFINITY;
  let maxValue = Number.NEGATIVE_INFINITY;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const value = alignmentPatternValue(x, y, width, height);
      base[y * width + x] = value;
      minValue = Math.min(minValue, value);
      maxValue = Math.max(maxValue, value);
    }
  }
  const rgbWidth = width * ratio;
  const rgbHeight = height * ratio;
  const rgb = new Float32Array(rgbWidth * rgbHeight * 3);
  for (let y = 0; y < rgbHeight; y += 1) {
    for (let x = 0; x < rgbWidth; x += 1) {
      const baseValue = base[Math.floor(y / ratio) * width + Math.floor(x / ratio)];
      const normalized = (baseValue - minValue) / (maxValue - minValue);
      const value = 1000.0 + normalized * 50000.0;
      const index = (y * rgbWidth + x) * 3;
      rgb[index] = value;
      rgb[index + 1] = value * 0.9 + 500.0;
      rgb[index + 2] = value * 1.1;
    }
  }
  return rgb;
}

export function alignmentPatternValue(x, y, width, height) {
  let value =
    0.42 * Math.sin(x / 7.0) +
    0.31 * Math.cos(y / 9.0) +
    0.27 * Math.sin((x + y) / 13.0) +
    0.21 * Math.cos((2.0 * x - y) / 17.0);
  value += 1.7 * gaussianBlob(x, y, 0.22 * width, 0.3 * height, 0.11 * width);
  value += -1.2 * gaussianBlob(x, y, 0.68 * width, 0.55 * height, 0.16 * width);
  value += 1.4 * gaussianBlob(x, y, 0.48 * width, 0.78 * height, 0.09 * width);
  return value;
}

export function gaussianBlob(x, y, cx, cy, sigma) {
  const dx = x - cx;
  const dy = y - cy;
  return Math.exp(-((dx * dx + dy * dy) / (2.0 * sigma * sigma)));
}

export function assertCloseToFixture(actual, fixture, maxTolerance = 0.01, rmsTolerance = 0.01) {
  assert.equal(actual.length, fixture.expected.length);
  let maxAbs = 0.0;
  let sumSq = 0.0;
  for (let index = 0; index < actual.length; index += 1) {
    const diff = actual[index] - fixture.expected[index];
    maxAbs = Math.max(maxAbs, Math.abs(diff));
    sumSq += diff * diff;
  }
  const rms = Math.sqrt(sumSq / actual.length);
  assert.ok(maxAbs <= maxTolerance, `IR alignment max_abs ${maxAbs} exceeds ${maxTolerance}`);
  assert.ok(rms <= rmsTolerance, `IR alignment rms ${rms} exceeds ${rmsTolerance}`);
  return { maxAbs, rms };
}

export function syntheticFrameDetectRawBuffer() {
  const pixels = new Uint16Array(frameDetectWidth * frameDetectHeight * 3);
  fillRgb16Level(pixels, 0, 0, frameDetectWidth, frameDetectHeight, 0.92);
  fillRgb16Level(pixels, 30, 20, 140, 580, 0.65);
  fillRgb16Level(pixels, 45, 55, 100, 150, 0.18);
  fillRgb16Level(pixels, 45, 235, 100, 150, 0.18);
  fillRgb16Level(pixels, 45, 415, 100, 150, 0.18);
  return pixels.buffer;
}

export function fillRgb16Level(pixels, x, y, width, height, level) {
  const sample = Math.max(0, Math.min(65535, Math.round(level * 65535)));
  const x0 = Math.max(0, x);
  const y0 = Math.max(0, y);
  const x1 = Math.min(frameDetectWidth, x + width);
  const y1 = Math.min(frameDetectHeight, y + height);
  for (let yy = y0; yy < y1; yy += 1) {
    for (let xx = x0; xx < x1; xx += 1) {
      const index = (yy * frameDetectWidth + xx) * 3;
      pixels[index] = sample;
      pixels[index + 1] = sample;
      pixels[index + 2] = sample;
    }
  }
}

export function assertDetectedFramesApprox(actual, expected, tolerance = 12.0) {
  assert.equal(actual.length, expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    const a = actual[index];
    const e = expected[index];
    for (const field of ["cx", "cy", "w", "h"]) {
      assert.ok(Math.abs(a[field] - e[field]) <= tolerance, `frame ${index} ${field}: ${a[field]} vs ${e[field]}`);
    }
    assert.ok(Math.abs(a.angle - e.angle) <= 0.05, `frame ${index} angle: ${a.angle} vs ${e.angle}`);
  }
}
