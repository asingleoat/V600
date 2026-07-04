import fs from "node:fs";
import { performance } from "node:perf_hooks";

const status = {
  ok: 0,
  invalidBuffer: 1,
  invalidDimensions: 2,
  invalidStock: 3,
};

const stock = {
  kodakGold: 1,
};

const previewOptionsSize = 60;
const irMaskOptionsSize = 36;
const irMaskResizeOptionsSize = 16;
const irInpaintOptionsSize = 8;
const irInpaintGrainOptionsSize = 16;
const irAlignOptionsSize = 16;
const irEstimateOptionsSize = 32;
const irEstimateResultSize = 24;
const rawFixture = new Uint16Array([
  51000, 42000, 35000,
  45000, 39000, 31000,
  39000, 33000, 26000,
  33000, 27000, 21000,
]);
const expectedPreview = new Uint8Array([
  0, 5, 141,
  18, 39, 222,
  122, 133, 255,
  242, 243, 255,
]);
const irWidth = 9;
const irHeight = 9;
const irFixture = new Uint8Array(irWidth * irHeight).fill(255);
irFixture[40] = 0;
const expectedIrMask = new Uint8Array(irWidth * irHeight);
expectedIrMask[40] = 255;
let wasmPointerBits = 32;

function fail(message) {
  console.error(message);
  process.exit(1);
}

function requireExport(exports, name, kind) {
  if (!(name in exports)) fail(`missing export: ${name}`);
  if (kind && typeof exports[name] !== kind) {
    fail(`unexpected export type for ${name}: expected ${kind}, got ${typeof exports[name]}`);
  }
  return exports[name];
}

function writePreviewOptions(exports, ptr, overrides = {}) {
  const options = {
    width: 2,
    height: 2,
    stock: stock.kodakGold,
    dminR: 0.05,
    dminG: 0.06,
    dminB: 0.07,
    defaultLight: 65535.0,
    contrast: 1.4,
    curveK: 5.0,
    percentileLo: 0.5,
    percentileHi: 99.5,
    exposureCompensation: 0.0,
    colorTemp: 0.0,
    colorTint: 0.0,
    percentileSampleLimit: 16384,
    ...overrides,
  };
  const view = new DataView(exports.memory.buffer, ptr, previewOptionsSize);
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
  f32(options.dminR);
  f32(options.dminG);
  f32(options.dminB);
  f32(options.defaultLight);
  f32(options.contrast);
  f32(options.curveK);
  f32(options.percentileLo);
  f32(options.percentileHi);
  f32(options.exposureCompensation);
  f32(options.colorTemp);
  f32(options.colorTint);
  u32(options.percentileSampleLimit);

  if (offset !== previewOptionsSize) fail(`preview option layout wrote ${offset} bytes`);
}

function writeIrMaskOptions(exports, ptr, overrides = {}) {
  const options = {
    width: irWidth,
    height: irHeight,
    threshold: 1.0,
    hairSensitivity: 2.0,
    minArea: 1,
    dilateRadius: 0,
    closeRadius: 0,
    blurSize: 7,
    maxCoverage: 1.0,
    ...overrides,
  };
  const view = new DataView(exports.memory.buffer, ptr, irMaskOptionsSize);
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
  f32(options.hairSensitivity);
  u32(options.minArea);
  u32(options.dilateRadius);
  u32(options.closeRadius);
  u32(options.blurSize);
  f32(options.maxCoverage);

  if (offset !== irMaskOptionsSize) fail(`IR mask option layout wrote ${offset} bytes`);
}

function writeIrMaskResizeOptions(exports, ptr, overrides = {}) {
  const options = {
    irWidth,
    irHeight,
    rgbWidth: irWidth,
    rgbHeight: irHeight,
    ...overrides,
  };
  const view = new DataView(exports.memory.buffer, ptr, irMaskResizeOptionsSize);
  let offset = 0;
  const u32 = (value) => {
    view.setUint32(offset, value, true);
    offset += 4;
  };

  u32(options.irWidth);
  u32(options.irHeight);
  u32(options.rgbWidth);
  u32(options.rgbHeight);

  if (offset !== irMaskResizeOptionsSize) fail(`IR mask resize option layout wrote ${offset} bytes`);
}

function writeIrInpaintOptions(exports, ptr, overrides = {}) {
  const options = {
    width: 1,
    height: 1,
    ...overrides,
  };
  const view = new DataView(exports.memory.buffer, ptr, irInpaintOptionsSize);
  let offset = 0;
  const u32 = (value) => {
    view.setUint32(offset, value, true);
    offset += 4;
  };

  u32(options.width);
  u32(options.height);

  if (offset !== irInpaintOptionsSize) fail(`IR inpaint option layout wrote ${offset} bytes`);
}

function writeIrInpaintGrainOptions(exports, ptr, overrides = {}) {
  const options = {
    width: 1,
    height: 1,
    padding: 0,
    grainPadding: 0,
    ...overrides,
  };
  const view = new DataView(exports.memory.buffer, ptr, irInpaintGrainOptionsSize);
  let offset = 0;
  const u32 = (value) => {
    view.setUint32(offset, value, true);
    offset += 4;
  };

  u32(options.width);
  u32(options.height);
  u32(options.padding);
  u32(options.grainPadding);

  if (offset !== irInpaintGrainOptionsSize) fail(`IR grain inpaint option layout wrote ${offset} bytes`);
}

function writeIrAlignOptions(exports, ptr, overrides = {}) {
  const options = {
    width: irWidth,
    height: irHeight,
    tx: 0.0,
    ty: 0.0,
    ...overrides,
  };
  const view = new DataView(exports.memory.buffer, ptr, irAlignOptionsSize);
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

  if (offset !== irAlignOptionsSize) fail(`IR align option layout wrote ${offset} bytes`);
}

function writeIrEstimateOptions(exports, ptr, overrides = {}) {
  const options = {
    rgbWidth: 160,
    rgbHeight: 128,
    irWidth,
    irHeight,
    maxIterations: 200,
    eccScale: 0.125,
    epsilon: 1.0e-6,
    reserved: 0,
    ...overrides,
  };
  const view = new DataView(exports.memory.buffer, ptr, irEstimateOptionsSize);
  let offset = 0;
  const u32 = (value) => {
    view.setUint32(offset, value, true);
    offset += 4;
  };
  const f32 = (value) => {
    view.setFloat32(offset, value, true);
    offset += 4;
  };

  u32(options.rgbWidth);
  u32(options.rgbHeight);
  u32(options.irWidth);
  u32(options.irHeight);
  u32(options.maxIterations);
  f32(options.eccScale);
  f32(options.epsilon);
  u32(options.reserved);

  if (offset !== irEstimateOptionsSize) fail(`IR estimate option layout wrote ${offset} bytes`);
}

function alloc(exports, len) {
  const ptr = wasmByteOffset(exports.v600_wasm_alloc(wasmIndex(len)), "allocation pointer");
  if (ptr === 0) fail(`wasm allocation failed for ${len} bytes`);
  if (BigInt(ptr) + BigInt(len) > BigInt(exports.memory.buffer.byteLength)) {
    fail(`wasm allocation ${ptr}+${len} exceeds memory size ${exports.memory.buffer.byteLength}`);
  }
  return ptr;
}

function free(exports, ptr, len) {
  if (ptr === 0 || len === 0) return;
  exports.v600_wasm_free(wasmIndex(ptr), wasmIndex(len));
}

function callCore(exports, name, ...args) {
  return exports[name](...args.map((arg) => wasmIndex(arg)));
}

function wasmIndex(value) {
  if (!Number.isSafeInteger(value) || value < 0) {
    fail(`Wasm index is not a non-negative safe integer: ${value}`);
  }
  return wasmPointerBits === 64 ? BigInt(value) : value;
}

function wasmByteOffset(value, label) {
  const numeric = typeof value === "bigint" ? Number(value) : value;
  if (!Number.isSafeInteger(numeric) || numeric < 0) {
    fail(`${label} cannot be represented as a JavaScript byte offset: ${value}`);
  }
  return numeric;
}

function arraysEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

function runPreview(exports, ptrs, optionOverrides = {}) {
  new Uint16Array(exports.memory.buffer, ptrs.raw, rawFixture.length).set(rawFixture);
  writePreviewOptions(exports, ptrs.options, optionOverrides);
  return callCore(
    exports,
    "v600_preview_invert_u16_to_u8",
    ptrs.raw,
    rawFixture.length,
    ptrs.output,
    expectedPreview.length,
    ptrs.options,
  );
}

function runExport(exports, ptrs, optionOverrides = {}) {
  new Uint16Array(exports.memory.buffer, ptrs.raw, rawFixture.length).set(rawFixture);
  writePreviewOptions(exports, ptrs.options, optionOverrides);
  return callCore(
    exports,
    "v600_export_invert_u16_to_u16",
    ptrs.raw,
    rawFixture.length,
    ptrs.exportOutput,
    rawFixture.length,
    ptrs.options,
  );
}

function runIrMask(exports, ptrs, optionOverrides = {}) {
  new Uint8Array(exports.memory.buffer, ptrs.ir, irFixture.length).set(irFixture);
  writeIrMaskOptions(exports, ptrs.irOptions, optionOverrides);
  return callCore(
    exports,
    "v600_ir_make_defect_mask_u8",
    ptrs.ir,
    irFixture.length,
    ptrs.irMask,
    expectedIrMask.length,
    ptrs.irOptions,
  );
}

function runIrMaskF32(exports, ptrs, optionOverrides = {}) {
  new Float32Array(exports.memory.buffer, ptrs.irF32, irFixture.length).set(irFixture);
  writeIrMaskOptions(exports, ptrs.irOptions, optionOverrides);
  return callCore(
    exports,
    "v600_ir_make_defect_mask_f32",
    ptrs.irF32,
    irFixture.length,
    ptrs.irMask,
    expectedIrMask.length,
    ptrs.irOptions,
  );
}

function runIrAlignFixture(exports, ptrs) {
  const fixtureBytes = fs.readFileSync("test/fixtures/processing/ir/align-ratio-1-to-2.json", "utf8");
  const fixture = JSON.parse(fixtureBytes);
  const height = fixture.ir_shape[0];
  const width = fixture.ir_shape[1];
  const samples = width * height;
  if (samples > ptrs.alignSamples) fail(`alignment fixture has ${samples} samples, capacity is ${ptrs.alignSamples}`);
  new Float32Array(exports.memory.buffer, ptrs.alignInput, samples).set(fixture.ir);
  writeIrAlignOptions(exports, ptrs.alignOptions, {
    width,
    height,
    tx: fixture.expected_offset[0],
    ty: fixture.expected_offset[1],
  });
  const statusCode = callCore(
    exports,
    "v600_ir_apply_translation_f32",
    ptrs.alignInput,
    samples,
    ptrs.alignOutput,
    samples,
    ptrs.alignOptions,
  );
  if (statusCode !== status.ok) fail(`IR alignment status ${statusCode}, expected ${status.ok}`);
  const actual = new Float32Array(exports.memory.buffer, ptrs.alignOutput, samples);
  let maxAbs = 0.0;
  let sumSq = 0.0;
  for (let index = 0; index < samples; index += 1) {
    const diff = actual[index] - fixture.expected[index];
    maxAbs = Math.max(maxAbs, Math.abs(diff));
    sumSq += diff * diff;
  }
  return { samples, maxAbs, rms: Math.sqrt(sumSq / samples) };
}

function runIrEstimateFixture(exports, ptrs) {
  const fixtureBytes = fs.readFileSync("test/fixtures/processing/ir/align-ratio-1-to-2.json", "utf8");
  const fixture = JSON.parse(fixtureBytes);
  const height = fixture.ir_shape[0];
  const width = fixture.ir_shape[1];
  const ratio = fixture.ratio;
  const rgbWidth = width * ratio;
  const rgbHeight = height * ratio;
  const rgbSamples = rgbWidth * rgbHeight * 3;
  const irSamples = width * height;
  if (rgbSamples > ptrs.estimateRgbSamples) fail(`alignment RGB fixture has ${rgbSamples} samples, capacity is ${ptrs.estimateRgbSamples}`);
  if (irSamples > ptrs.alignSamples) fail(`alignment IR fixture has ${irSamples} samples, capacity is ${ptrs.alignSamples}`);
  const rgb = buildAlignmentRgbFixture(fixture);
  new Float32Array(exports.memory.buffer, ptrs.estimateRgb, rgbSamples).set(rgb);
  new Float32Array(exports.memory.buffer, ptrs.alignInput, irSamples).set(fixture.ir);
  writeIrEstimateOptions(exports, ptrs.estimateOptions, {
    rgbWidth,
    rgbHeight,
    irWidth: width,
    irHeight: height,
  });
  const statusCode = callCore(
    exports,
    "v600_ir_estimate_translation_f32",
    ptrs.estimateRgb,
    rgbSamples,
    ptrs.alignInput,
    irSamples,
    ptrs.estimateResult,
    ptrs.estimateOptions,
  );
  if (statusCode !== status.ok) fail(`IR estimate status ${statusCode}, expected ${status.ok}`);
  const view = new DataView(exports.memory.buffer, ptrs.estimateResult, irEstimateResultSize);
  const tx = view.getFloat32(0, true);
  const ty = view.getFloat32(4, true);
  const rho = view.getFloat32(8, true);
  const iterations = view.getUint32(12, true);
  const shifted = view.getUint32(16, true);
  writeIrAlignOptions(exports, ptrs.alignOptions, { width, height, tx, ty });
  const alignStatus = callCore(
    exports,
    "v600_ir_apply_translation_f32",
    ptrs.alignInput,
    irSamples,
    ptrs.alignOutput,
    irSamples,
    ptrs.alignOptions,
  );
  if (alignStatus !== status.ok) fail(`estimated IR alignment status ${alignStatus}, expected ${status.ok}`);
  const actual = new Float32Array(exports.memory.buffer, ptrs.alignOutput, irSamples);
  let maxAbs = 0.0;
  let sumSq = 0.0;
  for (let index = 0; index < irSamples; index += 1) {
    const diff = actual[index] - fixture.expected[index];
    maxAbs = Math.max(maxAbs, Math.abs(diff));
    sumSq += diff * diff;
  }
  return {
    samples: irSamples,
    tx,
    ty,
    expectedTx: fixture.expected_offset[0],
    expectedTy: fixture.expected_offset[1],
    rho,
    iterations,
    shifted,
    maxAbs,
    rms: Math.sqrt(sumSq / irSamples),
  };
}

function buildAlignmentRgbFixture(fixture) {
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

function alignmentPatternValue(x, y, width, height) {
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

function gaussianBlob(x, y, cx, cy, sigma) {
  const dx = x - cx;
  const dy = y - cy;
  return Math.exp(-((dx * dx + dy * dy) / (2.0 * sigma * sigma)));
}

function readOutput(exports, ptr) {
  return new Uint8Array(exports.memory.buffer, ptr, expectedPreview.length).slice();
}

function readExportOutput(exports, ptr) {
  return new Uint16Array(exports.memory.buffer, ptr, rawFixture.length).slice();
}

function readIrMask(exports, ptr) {
  return new Uint8Array(exports.memory.buffer, ptr, expectedIrMask.length).slice();
}

function assertPreview(exports, ptrs) {
  const result = runPreview(exports, ptrs);
  if (result !== status.ok) fail(`preview status ${result}, expected ${status.ok}`);
  const actual = readOutput(exports, ptrs.output);
  if (!arraysEqual(actual, expectedPreview)) {
    fail(`preview mismatch: expected ${Array.from(expectedPreview)}, got ${Array.from(actual)}`);
  }
}

function assertExport(exports, ptrs) {
  const result = runExport(exports, ptrs);
  if (result !== status.ok) fail(`export status ${result}, expected ${status.ok}`);
  const actual = readExportOutput(exports, ptrs.exportOutput);
  for (let i = 0; i < actual.length; i += 1) {
    if ((actual[i] >> 8) !== expectedPreview[i]) {
      fail(`export sample ${i} shifted to ${actual[i] >> 8}, expected ${expectedPreview[i]}`);
    }
  }
}

function assertIrMask(exports, ptrs) {
  const result = runIrMask(exports, ptrs);
  if (result !== status.ok) fail(`IR mask status ${result}, expected ${status.ok}`);
  const actual = readIrMask(exports, ptrs.irMask);
  if (!arraysEqual(actual, expectedIrMask)) {
    fail(`IR mask mismatch: expected ${Array.from(expectedIrMask)}, got ${Array.from(actual)}`);
  }
}

function assertIrMaskF32(exports, ptrs) {
  const result = runIrMaskF32(exports, ptrs);
  if (result !== status.ok) fail(`IR f32 mask status ${result}, expected ${status.ok}`);
  const actual = readIrMask(exports, ptrs.irMask);
  if (!arraysEqual(actual, expectedIrMask)) {
    fail(`IR f32 mask mismatch: expected ${Array.from(expectedIrMask)}, got ${Array.from(actual)}`);
  }
}

function assertIrMaskResizeFixture(exports) {
  const fixtureBytes = fs.readFileSync("test/fixtures/processing/ir/ir-clean-region-resize-uint16-smoke.json", "utf8");
  const fixture = JSON.parse(fixtureBytes);
  const [rgbHeight, rgbWidth] = fixture.rgb_shape;
  const [resizeIrHeight, resizeIrWidth] = fixture.ir_shape;
  const ir = Float32Array.from(fixture.ir);
  const expectedIrMaskFixture = Uint8Array.from(fixture.expected_ir_mask);
  const expectedRgbMask = Uint8Array.from(fixture.expected_mask);

  const irPtr = alloc(exports, ir.byteLength);
  const irMaskPtr = alloc(exports, expectedIrMaskFixture.byteLength);
  const rgbMaskPtr = alloc(exports, expectedRgbMask.byteLength);
  const irOptionsPtr = alloc(exports, irMaskOptionsSize);
  const resizeOptionsPtr = alloc(exports, irMaskResizeOptionsSize);
  try {
    new Float32Array(exports.memory.buffer, irPtr, ir.length).set(ir);
    writeIrMaskOptions(exports, irOptionsPtr, {
      width: resizeIrWidth,
      height: resizeIrHeight,
      threshold: fixture.threshold,
      hairSensitivity: fixture.hair_sensitivity,
      minArea: fixture.min_area,
      dilateRadius: fixture.dilate_radius,
      closeRadius: fixture.close_radius,
      blurSize: fixture.blur_size,
      maxCoverage: fixture.max_coverage,
    });
    const maskStatus = callCore(
      exports,
      "v600_ir_make_defect_mask_f32",
      irPtr,
      ir.length,
      irMaskPtr,
      expectedIrMaskFixture.length,
      irOptionsPtr,
    );
    if (maskStatus !== status.ok) fail(`IR resize fixture mask status ${maskStatus}, expected ${status.ok}`);
    const actualIrMask = new Uint8Array(exports.memory.buffer, irMaskPtr, expectedIrMaskFixture.length).slice();
    if (!arraysEqual(actualIrMask, expectedIrMaskFixture)) {
      fail("IR resize fixture produced a non-oracle IR mask");
    }

    writeIrMaskResizeOptions(exports, resizeOptionsPtr, {
      irWidth: resizeIrWidth,
      irHeight: resizeIrHeight,
      rgbWidth,
      rgbHeight,
    });
    const resizeStatus = callCore(
      exports,
      "v600_ir_resize_mask_to_rgb_u8",
      irMaskPtr,
      expectedIrMaskFixture.length,
      rgbMaskPtr,
      expectedRgbMask.length,
      resizeOptionsPtr,
    );
    if (resizeStatus !== status.ok) fail(`IR mask resize status ${resizeStatus}, expected ${status.ok}`);
    const actualRgbMask = new Uint8Array(exports.memory.buffer, rgbMaskPtr, expectedRgbMask.length).slice();
    if (!arraysEqual(actualRgbMask, expectedRgbMask)) {
      fail("IR resize fixture produced a non-oracle RGB-sized mask");
    }
    return {
      irMaskBytes: expectedIrMaskFixture.length,
      rgbMaskBytes: expectedRgbMask.length,
      rgbDefects: countNonZero(actualRgbMask),
    };
  } finally {
    free(exports, resizeOptionsPtr, irMaskResizeOptionsSize);
    free(exports, irOptionsPtr, irMaskOptionsSize);
    free(exports, rgbMaskPtr, expectedRgbMask.byteLength);
    free(exports, irMaskPtr, expectedIrMaskFixture.byteLength);
    free(exports, irPtr, ir.byteLength);
  }
}

function assertBiharmonicInpaintFixture(exports) {
  const fixtureBytes = fs.readFileSync("test/fixtures/processing/ir/biharmonic-inpaint-smoke.json", "utf8");
  const fixture = JSON.parse(fixtureBytes);
  const [height, width, channels] = fixture.shape;
  if (channels !== 3) fail(`unexpected biharmonic fixture channels: ${channels}`);
  const input = Uint16Array.from(fixture.input, (value) => normalizedToU16(value));
  const mask = Uint8Array.from(fixture.mask, (value) => value === 0 ? 0 : 255);
  const expected = Uint16Array.from(fixture.expected, (value) => normalizedToU16(value));
  const rgbPtr = alloc(exports, input.byteLength);
  const maskPtr = alloc(exports, mask.byteLength);
  const outputPtr = alloc(exports, expected.byteLength);
  const optionsPtr = alloc(exports, irInpaintOptionsSize);
  try {
    new Uint16Array(exports.memory.buffer, rgbPtr, input.length).set(input);
    new Uint8Array(exports.memory.buffer, maskPtr, mask.length).set(mask);
    writeIrInpaintOptions(exports, optionsPtr, { width, height });
    const result = callCore(
      exports,
      "v600_ir_biharmonic_inpaint_u16",
      rgbPtr,
      input.length,
      maskPtr,
      mask.length,
      outputPtr,
      expected.length,
      optionsPtr,
    );
    if (result !== status.ok) fail(`biharmonic inpaint status ${result}, expected ${status.ok}`);
    const actual = new Uint16Array(exports.memory.buffer, outputPtr, expected.length).slice();
    let maxAbs = 0;
    let sumSq = 0;
    let mismatches = 0;
    for (let index = 0; index < actual.length; index += 1) {
      const diff = actual[index] - expected[index];
      maxAbs = Math.max(maxAbs, Math.abs(diff));
      sumSq += diff * diff;
      if (diff !== 0) mismatches += 1;
    }
    if (maxAbs > 2) {
      fail(`biharmonic inpaint max_abs ${maxAbs} exceeds 2`);
    }
    return {
      samples: expected.length,
      maxAbs,
      rms: Math.sqrt(sumSq / actual.length),
      mismatches,
    };
  } finally {
    free(exports, optionsPtr, irInpaintOptionsSize);
    free(exports, outputPtr, expected.byteLength);
    free(exports, maskPtr, mask.byteLength);
    free(exports, rgbPtr, input.byteLength);
  }
}

function assertGrainInpaintFixture(exports) {
  const fixtureBytes = fs.readFileSync("test/fixtures/processing/ir/inpaint-biharmonic-grain-uint16-smoke.json", "utf8");
  const fixture = JSON.parse(fixtureBytes);
  const [height, width, channels] = fixture.shape;
  if (channels !== 3) fail(`unexpected grain inpaint fixture channels: ${channels}`);
  const input = Uint16Array.from(fixture.input);
  const mask = Uint8Array.from(fixture.mask, (value) => value === 0 ? 0 : 255);
  const noise = Float64Array.from(fixture.noise);
  const expected = Uint16Array.from(fixture.expected);
  const rgbPtr = alloc(exports, input.byteLength);
  const maskPtr = alloc(exports, mask.byteLength);
  const noisePtr = alloc(exports, noise.byteLength);
  const outputPtr = alloc(exports, expected.byteLength);
  const optionsPtr = alloc(exports, irInpaintGrainOptionsSize);
  try {
    new Uint16Array(exports.memory.buffer, rgbPtr, input.length).set(input);
    new Uint8Array(exports.memory.buffer, maskPtr, mask.length).set(mask);
    new Float64Array(exports.memory.buffer, noisePtr, noise.length).set(noise);
    writeIrInpaintGrainOptions(exports, optionsPtr, {
      width,
      height,
      padding: fixture.padding,
      grainPadding: fixture.grain_padding,
    });
    const result = callCore(
      exports,
      "v600_ir_inpaint_grain_u16_with_noise",
      rgbPtr,
      input.length,
      maskPtr,
      mask.length,
      noisePtr,
      noise.length,
      outputPtr,
      expected.length,
      optionsPtr,
    );
    if (result !== status.ok) fail(`grain inpaint status ${result}, expected ${status.ok}`);
    const actual = new Uint16Array(exports.memory.buffer, outputPtr, expected.length).slice();
    let maxAbs = 0;
    let sumSq = 0;
    let mismatches = 0;
    for (let index = 0; index < actual.length; index += 1) {
      const diff = actual[index] - expected[index];
      maxAbs = Math.max(maxAbs, Math.abs(diff));
      sumSq += diff * diff;
      if (diff !== 0) mismatches += 1;
    }
    if (maxAbs > fixture.tolerance.abs) {
      fail(`grain inpaint max_abs ${maxAbs} exceeds ${fixture.tolerance.abs}`);
    }
    return {
      samples: expected.length,
      maxAbs,
      rms: Math.sqrt(sumSq / actual.length),
      mismatches,
    };
  } finally {
    free(exports, optionsPtr, irInpaintGrainOptionsSize);
    free(exports, outputPtr, expected.byteLength);
    free(exports, noisePtr, noise.byteLength);
    free(exports, maskPtr, mask.byteLength);
    free(exports, rgbPtr, input.byteLength);
  }
}

function normalizedToU16(value) {
  if (!Number.isFinite(value) || value <= 0.0) return 0;
  if (value >= 1.0) return 65535;
  return Math.floor(value * 65535.0 + 0.5);
}

function countNonZero(values) {
  let count = 0;
  for (const value of values) {
    if (value !== 0) count += 1;
  }
  return count;
}

const wasmPath = process.argv[2];
if (!wasmPath) fail("usage: node test/wasm/wasm_core_smoke.mjs <v600-wasm-core.wasm>");

const wasmBytes = fs.readFileSync(wasmPath);
const instantiateStart = performance.now();
const { instance } = await WebAssembly.instantiate(wasmBytes, {});
const coldInstantiateUs = Math.round((performance.now() - instantiateStart) * 1000);
const exports = instance.exports;

requireExport(exports, "memory");
requireExport(exports, "v600_wasm_pointer_bits", "function");
requireExport(exports, "v600_wasm_alloc", "function");
requireExport(exports, "v600_wasm_free", "function");
requireExport(exports, "v600_preview_invert_u16_to_u8", "function");
requireExport(exports, "v600_export_invert_u16_to_u16", "function");
requireExport(exports, "v600_ir_make_defect_mask_u8", "function");
requireExport(exports, "v600_ir_make_defect_mask_f32", "function");
requireExport(exports, "v600_ir_resize_mask_to_rgb_u8", "function");
requireExport(exports, "v600_ir_biharmonic_inpaint_u16", "function");
requireExport(exports, "v600_ir_inpaint_grain_u16_with_noise", "function");
requireExport(exports, "v600_ir_apply_translation_f32", "function");
requireExport(exports, "v600_ir_estimate_translation_f32", "function");
wasmPointerBits = exports.v600_wasm_pointer_bits();
if (wasmPointerBits !== 32 && wasmPointerBits !== 64) {
  fail(`unsupported Wasm pointer width: ${wasmPointerBits}`);
}

const alignSamplesCapacity = 80 * 64;
const alignFixtureBytes = alignSamplesCapacity * 4;
const estimateRgbSamplesCapacity = 160 * 128 * 3;
const estimateRgbBytes = estimateRgbSamplesCapacity * 4;

const ptrs = {
  raw: alloc(exports, rawFixture.byteLength),
  output: alloc(exports, expectedPreview.length),
  exportOutput: alloc(exports, rawFixture.byteLength),
  options: alloc(exports, previewOptionsSize),
  ir: alloc(exports, irFixture.byteLength),
  irF32: alloc(exports, irFixture.length * 4),
  irMask: alloc(exports, expectedIrMask.length),
  irOptions: alloc(exports, irMaskOptionsSize),
  alignInput: alloc(exports, alignFixtureBytes),
  alignOutput: alloc(exports, alignFixtureBytes),
  alignOptions: alloc(exports, irAlignOptionsSize),
  alignSamples: alignSamplesCapacity,
  estimateRgb: alloc(exports, estimateRgbBytes),
  estimateOptions: alloc(exports, irEstimateOptionsSize),
  estimateResult: alloc(exports, irEstimateResultSize),
  estimateRgbSamples: estimateRgbSamplesCapacity,
};

try {
  assertPreview(exports, ptrs);
  assertExport(exports, ptrs);
  assertIrMask(exports, ptrs);
  assertIrMaskF32(exports, ptrs);
  const resizedMask = assertIrMaskResizeFixture(exports);
  const inpaint = assertBiharmonicInpaintFixture(exports);
  const grainInpaint = assertGrainInpaintFixture(exports);
  const alignment = runIrAlignFixture(exports, ptrs);
  if (alignment.maxAbs > 0.01 || alignment.rms > 0.01) {
    fail(`IR alignment mismatch max_abs=${alignment.maxAbs} rms=${alignment.rms}`);
  }
  const estimate = runIrEstimateFixture(exports, ptrs);
  if (Math.abs(estimate.tx - estimate.expectedTx) > 0.25 || Math.abs(estimate.ty - estimate.expectedTy) > 0.25) {
    fail(`IR estimate offset mismatch tx=${estimate.tx} ty=${estimate.ty}`);
  }
  if (estimate.maxAbs > 800.0 || estimate.rms > 250.0) {
    fail(`IR estimate final alignment mismatch max_abs=${estimate.maxAbs} rms=${estimate.rms}`);
  }

  const timedStart = performance.now();
  assertPreview(exports, ptrs);
  const warmProcessingUs = Math.round((performance.now() - timedStart) * 1000);

  const badDimensions = runPreview(exports, ptrs, { width: 2, height: 1 });
  if (badDimensions !== status.invalidDimensions) {
    fail(`invalid-dimensions status ${badDimensions}, expected ${status.invalidDimensions}`);
  }

  const badStock = runPreview(exports, ptrs, { stock: 99 });
  if (badStock !== status.invalidStock) {
    fail(`invalid-stock status ${badStock}, expected ${status.invalidStock}`);
  }

  const badIrOptions = runIrMask(exports, ptrs, { threshold: Number.NaN });
  if (badIrOptions !== status.invalidBuffer) {
    fail(`invalid-IR-options status ${badIrOptions}, expected ${status.invalidBuffer}`);
  }

  console.log(JSON.stringify({
    event: "wasm-core-smoke",
    schema: "v600.webapp.event.v1",
    wasm: wasmPath,
    pointer_bits: wasmPointerBits,
    cold_instantiate_us: coldInstantiateUs,
    warm_processing_us: warmProcessingUs,
    input_samples: rawFixture.length,
    output_bytes: expectedPreview.length,
    export_output_bytes: rawFixture.byteLength,
    ir_mask_bytes: expectedIrMask.length,
    ir_rgb_mask_bytes: resizedMask.rgbMaskBytes,
    ir_rgb_mask_defect_pixels: resizedMask.rgbDefects,
    ir_inpaint_samples: inpaint.samples,
    ir_inpaint_max_abs: inpaint.maxAbs,
    ir_inpaint_rms: inpaint.rms,
    ir_grain_inpaint_samples: grainInpaint.samples,
    ir_grain_inpaint_max_abs: grainInpaint.maxAbs,
    ir_grain_inpaint_rms: grainInpaint.rms,
    ir_grain_inpaint_mismatches: grainInpaint.mismatches,
    ir_alignment_samples: alignment.samples,
    ir_alignment_max_abs: alignment.maxAbs,
    ir_alignment_rms: alignment.rms,
    ir_estimate_tx: estimate.tx,
    ir_estimate_ty: estimate.ty,
    ir_estimate_rho: estimate.rho,
    ir_estimate_iterations: estimate.iterations,
    ir_estimate_max_abs: estimate.maxAbs,
    ir_estimate_rms: estimate.rms,
    status: "ok",
  }));
} finally {
  free(exports, ptrs.estimateResult, irEstimateResultSize);
  free(exports, ptrs.estimateOptions, irEstimateOptionsSize);
  free(exports, ptrs.estimateRgb, estimateRgbBytes);
  free(exports, ptrs.alignOptions, irAlignOptionsSize);
  free(exports, ptrs.alignOutput, alignFixtureBytes);
  free(exports, ptrs.alignInput, alignFixtureBytes);
  free(exports, ptrs.irOptions, irMaskOptionsSize);
  free(exports, ptrs.irMask, expectedIrMask.length);
  free(exports, ptrs.irF32, irFixture.length * 4);
  free(exports, ptrs.ir, irFixture.byteLength);
  free(exports, ptrs.options, previewOptionsSize);
  free(exports, ptrs.exportOutput, rawFixture.byteLength);
  free(exports, ptrs.output, expectedPreview.length);
  free(exports, ptrs.raw, rawFixture.byteLength);
}
