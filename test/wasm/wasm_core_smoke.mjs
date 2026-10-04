import fs from "node:fs";
import { performance } from "node:perf_hooks";
import { alignmentPatternValue, buildAlignmentRgbFixture, normalizedToU16 } from "./helpers.mjs";
import {
  createWasmAbi,
  irAlignOptionsSize,
  irEstimateOptionsSize,
  irEstimateResultSize,
  irInpaintGrainOptionsSize,
  irInpaintOptionsSize,
  irMaskOptionsSize,
  irMaskResizeOptionsSize,
  previewOptionsSize,
} from "../../web/worker/wasm_abi.mjs";

const status = {
  ok: 0,
  invalidBuffer: 1,
  invalidDimensions: 2,
  invalidStock: 3,
};

const stock = {
  kodakGold: 1,
};

const rawFixture = new Uint16Array([
  51000, 42000, 35000,
  45000, 39000, 31000,
  39000, 33000, 26000,
  33000, 27000, 21000,
]);
const expectedPreview = new Uint8Array([
  83, 83, 83,
  108, 96, 103,
  135, 128, 132,
  164, 165, 165,
]);
const irWidth = 9;
const irHeight = 9;
const irFixture = new Uint8Array(irWidth * irHeight).fill(255);
irFixture[40] = 0;
const expectedIrMask = new Uint8Array(irWidth * irHeight);
expectedIrMask[40] = 255;

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

function writePreviewOptions(ptr, overrides = {}) {
  const options = {
    width: 2,
    height: 2,
    stock: stock.kodakGold,
    dminR: 0.05,
    dminG: 0.06,
    dminB: 0.07,
    defaultLight: 65535.0,
    contrast: 1.8,
    percentileLo: 0.5,
    percentileHi: 99.5,
    exposureCompensation: 0.0,
    colorTemp: 0.0,
    colorTint: 0.0,
    percentileSampleLimit: 16384,
    ...overrides,
  };
  abi.writePreviewOptions(ptr, {
    width: options.width,
    height: options.height,
    stock: options.stock,
    dmin_r: options.dminR,
    dmin_g: options.dminG,
    dmin_b: options.dminB,
    default_light: options.defaultLight,
    contrast: options.contrast,
    percentile_lo: options.percentileLo,
    percentile_hi: options.percentileHi,
    exposure_compensation: options.exposureCompensation,
    color_temp: options.colorTemp,
    color_tint: options.colorTint,
    percentile_sample_limit: options.percentileSampleLimit,
  });
}

function writeIrMaskOptions(ptr, overrides = {}) {
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
  abi.writeIrMaskOptions(ptr, {
    width: options.width,
    height: options.height,
    threshold: options.threshold,
    hair_sensitivity: options.hairSensitivity,
    min_area: options.minArea,
    dilate_radius: options.dilateRadius,
    close_radius: options.closeRadius,
    blur_size: options.blurSize,
    max_coverage: options.maxCoverage,
  });
}

function writeIrMaskResizeOptions(ptr, overrides = {}) {
  const options = {
    irWidth,
    irHeight,
    rgbWidth: irWidth,
    rgbHeight: irHeight,
    ...overrides,
  };
  abi.writeIrMaskResizeOptions(ptr, {
    ir_width: options.irWidth,
    ir_height: options.irHeight,
    rgb_width: options.rgbWidth,
    rgb_height: options.rgbHeight,
  });
}

function writeIrInpaintOptions(ptr, overrides = {}) {
  const options = {
    width: 1,
    height: 1,
    ...overrides,
  };
  abi.writeIrInpaintOptions(ptr, { width: options.width, height: options.height });
}

function writeIrInpaintGrainOptions(ptr, overrides = {}) {
  const options = {
    width: 1,
    height: 1,
    padding: 0,
    grainPadding: 0,
    ...overrides,
  };
  abi.writeIrInpaintGrainOptions(ptr, {
    width: options.width,
    height: options.height,
    padding: options.padding,
    grain_padding: options.grainPadding,
  });
}

function writeIrAlignOptions(ptr, overrides = {}) {
  const options = {
    width: irWidth,
    height: irHeight,
    tx: 0.0,
    ty: 0.0,
    ...overrides,
  };
  abi.writeIrAlignOptions(ptr, {
    width: options.width,
    height: options.height,
    tx: options.tx,
    ty: options.ty,
  });
}

function writeIrEstimateOptions(ptr, overrides = {}) {
  const options = {
    rgbWidth: 160,
    rgbHeight: 128,
    irWidth,
    irHeight,
    maxIterations: 200,
    eccScale: 0.125,
    epsilon: 1.0e-6,
    ...overrides,
  };
  abi.writeIrEstimateOptions(ptr, {
    rgb_width: options.rgbWidth,
    rgb_height: options.rgbHeight,
    ir_width: options.irWidth,
    ir_height: options.irHeight,
    max_iterations: options.maxIterations,
    ecc_scale: options.eccScale,
    epsilon: options.epsilon,
  });
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
  writePreviewOptions(ptrs.options, optionOverrides);
  return abi.callCore(
    "cerealgrain_preview_invert_u16_to_u8",
    ptrs.raw,
    rawFixture.length,
    ptrs.output,
    expectedPreview.length,
    ptrs.options,
  );
}

function runExport(exports, ptrs, optionOverrides = {}) {
  new Uint16Array(exports.memory.buffer, ptrs.raw, rawFixture.length).set(rawFixture);
  writePreviewOptions(ptrs.options, optionOverrides);
  return abi.callCore(
    "cerealgrain_export_invert_u16_to_u16",
    ptrs.raw,
    rawFixture.length,
    ptrs.exportOutput,
    rawFixture.length,
    ptrs.options,
  );
}

function runIrMask(exports, ptrs, optionOverrides = {}) {
  new Uint8Array(exports.memory.buffer, ptrs.ir, irFixture.length).set(irFixture);
  writeIrMaskOptions(ptrs.irOptions, optionOverrides);
  return abi.callCore(
    "cerealgrain_ir_make_defect_mask_u8",
    ptrs.ir,
    irFixture.length,
    ptrs.irMask,
    expectedIrMask.length,
    ptrs.irOptions,
  );
}

function runIrMaskF32(exports, ptrs, optionOverrides = {}) {
  new Float32Array(exports.memory.buffer, ptrs.irF32, irFixture.length).set(irFixture);
  writeIrMaskOptions(ptrs.irOptions, optionOverrides);
  return abi.callCore(
    "cerealgrain_ir_make_defect_mask_f32",
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
  writeIrAlignOptions(ptrs.alignOptions, {
    width,
    height,
    tx: fixture.expected_offset[0],
    ty: fixture.expected_offset[1],
  });
  const statusCode = abi.callCore(
    "cerealgrain_ir_apply_translation_f32",
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
  writeIrEstimateOptions(ptrs.estimateOptions, {
    rgbWidth,
    rgbHeight,
    irWidth: width,
    irHeight: height,
  });
  const statusCode = abi.callCore(
    "cerealgrain_ir_estimate_translation_f32",
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
  writeIrAlignOptions(ptrs.alignOptions, { width, height, tx, ty });
  const alignStatus = abi.callCore(
    "cerealgrain_ir_apply_translation_f32",
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

  const irPtr = abi.alloc(ir.byteLength);
  const irMaskPtr = abi.alloc(expectedIrMaskFixture.byteLength);
  const rgbMaskPtr = abi.alloc(expectedRgbMask.byteLength);
  const irOptionsPtr = abi.alloc(irMaskOptionsSize);
  const resizeOptionsPtr = abi.alloc(irMaskResizeOptionsSize);
  try {
    new Float32Array(exports.memory.buffer, irPtr, ir.length).set(ir);
    writeIrMaskOptions(irOptionsPtr, {
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
    const maskStatus = abi.callCore(
      "cerealgrain_ir_make_defect_mask_f32",
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

    writeIrMaskResizeOptions(resizeOptionsPtr, {
      irWidth: resizeIrWidth,
      irHeight: resizeIrHeight,
      rgbWidth,
      rgbHeight,
    });
    const resizeStatus = abi.callCore(
      "cerealgrain_ir_resize_mask_to_rgb_u8",
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
    abi.free(resizeOptionsPtr, irMaskResizeOptionsSize);
    abi.free(irOptionsPtr, irMaskOptionsSize);
    abi.free(rgbMaskPtr, expectedRgbMask.byteLength);
    abi.free(irMaskPtr, expectedIrMaskFixture.byteLength);
    abi.free(irPtr, ir.byteLength);
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
  const rgbPtr = abi.alloc(input.byteLength);
  const maskPtr = abi.alloc(mask.byteLength);
  const outputPtr = abi.alloc(expected.byteLength);
  const optionsPtr = abi.alloc(irInpaintOptionsSize);
  try {
    new Uint16Array(exports.memory.buffer, rgbPtr, input.length).set(input);
    new Uint8Array(exports.memory.buffer, maskPtr, mask.length).set(mask);
    writeIrInpaintOptions(optionsPtr, { width, height });
    const result = abi.callCore(
      "cerealgrain_ir_biharmonic_inpaint_u16",
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
    abi.free(optionsPtr, irInpaintOptionsSize);
    abi.free(outputPtr, expected.byteLength);
    abi.free(maskPtr, mask.byteLength);
    abi.free(rgbPtr, input.byteLength);
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
  const rgbPtr = abi.alloc(input.byteLength);
  const maskPtr = abi.alloc(mask.byteLength);
  const noisePtr = abi.alloc(noise.byteLength);
  const outputPtr = abi.alloc(expected.byteLength);
  const optionsPtr = abi.alloc(irInpaintGrainOptionsSize);
  try {
    new Uint16Array(exports.memory.buffer, rgbPtr, input.length).set(input);
    new Uint8Array(exports.memory.buffer, maskPtr, mask.length).set(mask);
    new Float64Array(exports.memory.buffer, noisePtr, noise.length).set(noise);
    writeIrInpaintGrainOptions(optionsPtr, {
      width,
      height,
      padding: fixture.padding,
      grainPadding: fixture.grain_padding,
    });
    const result = abi.callCore(
      "cerealgrain_ir_inpaint_grain_u16_with_noise",
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
    abi.free(optionsPtr, irInpaintGrainOptionsSize);
    abi.free(outputPtr, expected.byteLength);
    abi.free(noisePtr, noise.byteLength);
    abi.free(maskPtr, mask.byteLength);
    abi.free(rgbPtr, input.byteLength);
  }
}

function countNonZero(values) {
  let count = 0;
  for (const value of values) {
    if (value !== 0) count += 1;
  }
  return count;
}

const wasmPath = process.argv[2];
if (!wasmPath) fail("usage: node test/wasm/wasm_core_smoke.mjs <cerealgrain-wasm-core.wasm>");

const wasmBytes = fs.readFileSync(wasmPath);
const instantiateStart = performance.now();
const { instance } = await WebAssembly.instantiate(wasmBytes, {});
const coldInstantiateUs = Math.round((performance.now() - instantiateStart) * 1000);
const exports = instance.exports;

requireExport(exports, "memory");
requireExport(exports, "cerealgrain_wasm_pointer_bits", "function");
requireExport(exports, "cerealgrain_wasm_alloc", "function");
requireExport(exports, "cerealgrain_wasm_free", "function");
requireExport(exports, "cerealgrain_preview_invert_u16_to_u8", "function");
requireExport(exports, "cerealgrain_export_invert_u16_to_u16", "function");
requireExport(exports, "cerealgrain_ir_make_defect_mask_u8", "function");
requireExport(exports, "cerealgrain_ir_make_defect_mask_f32", "function");
requireExport(exports, "cerealgrain_ir_resize_mask_to_rgb_u8", "function");
requireExport(exports, "cerealgrain_ir_biharmonic_inpaint_u16", "function");
requireExport(exports, "cerealgrain_ir_inpaint_grain_u16_with_noise", "function");
requireExport(exports, "cerealgrain_ir_apply_translation_f32", "function");
requireExport(exports, "cerealgrain_ir_estimate_translation_f32", "function");
const abi = createWasmAbi(exports);
const wasmPointerBits = abi.pointerBits;

const alignSamplesCapacity = 80 * 64;
const alignFixtureBytes = alignSamplesCapacity * 4;
const estimateRgbSamplesCapacity = 160 * 128 * 3;
const estimateRgbBytes = estimateRgbSamplesCapacity * 4;

const ptrs = {
  raw: abi.alloc(rawFixture.byteLength),
  output: abi.alloc(expectedPreview.length),
  exportOutput: abi.alloc(rawFixture.byteLength),
  options: abi.alloc(previewOptionsSize),
  ir: abi.alloc(irFixture.byteLength),
  irF32: abi.alloc(irFixture.length * 4),
  irMask: abi.alloc(expectedIrMask.length),
  irOptions: abi.alloc(irMaskOptionsSize),
  alignInput: abi.alloc(alignFixtureBytes),
  alignOutput: abi.alloc(alignFixtureBytes),
  alignOptions: abi.alloc(irAlignOptionsSize),
  alignSamples: alignSamplesCapacity,
  estimateRgb: abi.alloc(estimateRgbBytes),
  estimateOptions: abi.alloc(irEstimateOptionsSize),
  estimateResult: abi.alloc(irEstimateResultSize),
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
    schema: "cerealgrain.webapp.event.v1",
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
  abi.free(ptrs.estimateResult, irEstimateResultSize);
  abi.free(ptrs.estimateOptions, irEstimateOptionsSize);
  abi.free(ptrs.estimateRgb, estimateRgbBytes);
  abi.free(ptrs.alignOptions, irAlignOptionsSize);
  abi.free(ptrs.alignOutput, alignFixtureBytes);
  abi.free(ptrs.alignInput, alignFixtureBytes);
  abi.free(ptrs.irOptions, irMaskOptionsSize);
  abi.free(ptrs.irMask, expectedIrMask.length);
  abi.free(ptrs.irF32, irFixture.length * 4);
  abi.free(ptrs.ir, irFixture.byteLength);
  abi.free(ptrs.options, previewOptionsSize);
  abi.free(ptrs.exportOutput, rawFixture.byteLength);
  abi.free(ptrs.output, expectedPreview.length);
  abi.free(ptrs.raw, rawFixture.byteLength);
}
