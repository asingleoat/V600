import assert from "node:assert/strict";
import fs from "node:fs";
import { Worker } from "node:worker_threads";

import {
  WebPreviewClient,
  buildFrameDetectCacheInput,
  buildIrAlignCacheInput,
  buildIrEstimateCacheInput,
  buildIrInpaintCacheInput,
  buildIrMaskCacheInput,
  buildIrRgbMaskCacheInput,
  buildNativeVariantExportMetadata,
  computeDminFromRgb16,
  defaultFrameDetectConfig,
  defaultDustRemovalConfig,
  defaultOutputSelection,
  enabledExportVariants,
  exportNativeVariantResults,
  exportRawNegativeRgb16,
  exportVariants,
  fileIdentity,
  frameSelectionFromDetectedFrame,
  frameDetectCacheKey,
  irAlignCacheKey,
  irEstimateCacheKey,
  irInpaintCacheKey,
  irMaskCacheKey,
  irRgbMaskCacheKey,
  previewCacheKey,
  previewOutputGeometry,
  parseRawRgb16Buffer,
  buildPreviewCacheInput,
  cropIrScalarToRgbFrame,
  cropRgb16ToFrame,
  defaultRenderConfig,
  metadataJsonBytes,
  nativeExportFilename,
  nativeExportMetadataFilename,
  normalizeFrameSelection,
  rgb8ToRgba,
  stockIds,
} from "../../web/app_core.mjs";
import { demoRawRgb16Buffer, expectedDemoPreview, rawFixture } from "./demo_fixture.mjs";
import { loadIrPageFromTiff, loadRgb16PageFromTiff, rgb16ToTiffBytes } from "../../web/tiff.mjs";
import { assertCloseToFixture, assertDetectedFramesApprox, buildAlignmentRgbFixture, expectedDetectedFrames, frameDetectHeight, frameDetectWidth, normalizedToU16, syntheticFrameDetectRawBuffer } from "./helpers.mjs";

const wasmPath = process.argv[2];
if (!wasmPath) throw new Error("usage: node test/wasm/webapp_shell_smoke.mjs <v600-wasm-core.wasm>");

const worker = new Worker(new URL("../../web/worker/processor.mjs", import.meta.url), {
  type: "module",
});
const client = new WebPreviewClient({ worker, wasmUrl: wasmPath, timeoutMs: 5000 });

try {
  await client.loadModule();
  const rawBuffer = demoRawRgb16Buffer();
  parseRawRgb16Buffer(rawBuffer, { width: 2, height: 2 });
  const file = await fileIdentity({
    name: "synthetic-2x2.rgb16",
    size: rawBuffer.byteLength,
    lastModified: 0,
    arrayBuffer: rawBuffer,
  });
  const cacheInput = buildPreviewCacheInput({
    file,
    image: { width: 2, height: 2, dpi: null },
    stock: "kodak_gold",
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    dmin: [0.05, 0.06, 0.07],
    preview: { max_px: 4, percentile_sample_limit: 16384 },
  });
  const expectedKey = await previewCacheKey(cacheInput);
  const result = await client.processRawRgb16({
    arrayBuffer: rawBuffer,
    file,
    image: { width: 2, height: 2, dpi: null },
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
  });

  assert.match(result.cacheKey, /^sha256:[0-9a-f]{64}$/);
  assert.equal(result.cacheKey, expectedKey);
  assert.deepEqual(Array.from(result.rgb8), Array.from(expectedDemoPreview));
  assert.equal(result.width, 2);
  assert.equal(result.height, 2);
  assert.equal(rgb8ToRgba(result.rgb8).length, 16);

  const raceWorker = new Worker(new URL("../../web/worker/processor.mjs", import.meta.url), {
    type: "module",
  });
  const raceClient = new WebPreviewClient({ worker: raceWorker, wasmUrl: wasmPath, timeoutMs: 5000 });
  try {
    const raceLoad = raceClient.loadModule();
    const raceResult = await raceClient.processRawRgb16({
      arrayBuffer: rawBuffer.slice(0),
      file,
      image: { width: 2, height: 2, dpi: null },
      stockId: stockIds.kodakGold,
      render: defaultRenderConfig(),
    });
    await raceLoad;
    assert.deepEqual(Array.from(raceResult.rgb8), Array.from(expectedDemoPreview));
  } finally {
    await raceClient.close();
  }

  const badLoadWorker = new Worker(new URL("../../web/worker/processor.mjs", import.meta.url), {
    type: "module",
  });
  const badLoadClient = new WebPreviewClient({ worker: badLoadWorker, wasmUrl: "test/fixtures/missing-v600-wasm-core.wasm", timeoutMs: 5000 });
  await assert.rejects(
    () => badLoadClient.loadModule(),
    /worker load failed:/,
  );
  await badLoadClient.close();

  const manualFrame = normalizeFrameSelection({ kind: "manual-rect", x: 1, y: 0, w: 1, h: 2, angle: 0 }, {
    width: 2,
    height: 2,
  });
  const cropped = cropRgb16ToFrame(rawBuffer, { width: 2, height: 2 }, manualFrame);
  assert.equal(cropped.width, 1);
  assert.equal(cropped.height, 2);
  assert.deepEqual(Array.from(new Uint16Array(cropped.arrayBuffer)), [
    45000, 39000, 31000,
    33000, 27000, 21000,
  ]);
  const cropResult = await client.processRawRgb16({
    arrayBuffer: rawBuffer,
    file,
    image: { width: 2, height: 2, dpi: null },
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    frameSelection: manualFrame,
  });
  assert.equal(cropResult.width, 1);
  assert.equal(cropResult.height, 2);
  assert.deepEqual(cropResult.frame, manualFrame);
  assert.ok(cropResult.timings.some((timing) => timing.stage === "worker.crop-rgb16"));
  assert.notEqual(cropResult.cacheKey, result.cacheKey);

  const rotatedCropFixture = JSON.parse(fs.readFileSync("test/fixtures/processing/frames/rotated-rect-crop-smoke.json", "utf8"));
  const [rotatedFixtureHeight, rotatedFixtureWidth] = rotatedCropFixture.shape;
  const rotatedRgb = new Uint16Array(rotatedCropFixture.input.length * 3);
  for (let index = 0; index < rotatedCropFixture.input.length; index += 1) {
    const sample = Math.round(rotatedCropFixture.input[index] * 1000.0);
    rotatedRgb[index * 3] = sample;
    rotatedRgb[index * 3 + 1] = sample;
    rotatedRgb[index * 3 + 2] = sample;
  }
  const rotatedFrame = normalizeFrameSelection({
    kind: "manual-rect",
    cx: rotatedCropFixture.cx,
    cy: rotatedCropFixture.cy,
    w: rotatedCropFixture.w,
    h: rotatedCropFixture.h,
    angle: rotatedCropFixture.angle_deg * Math.PI / 180.0,
  }, { width: rotatedFixtureWidth, height: rotatedFixtureHeight });
  const rotatedCrop = cropRgb16ToFrame(
    rotatedRgb.buffer.slice(rotatedRgb.byteOffset, rotatedRgb.byteOffset + rotatedRgb.byteLength),
    { width: rotatedFixtureWidth, height: rotatedFixtureHeight },
    rotatedFrame,
  );
  assert.equal(rotatedCrop.width, rotatedCropFixture.expected_shape[1]);
  assert.equal(rotatedCrop.height, rotatedCropFixture.expected_shape[0]);
  const rotatedCropRgb = new Uint16Array(rotatedCrop.arrayBuffer);
  let rotatedMaxAbs = 0;
  for (let index = 0; index < rotatedCropFixture.expected.length; index += 1) {
    const expected = Math.round(rotatedCropFixture.expected[index] * 1000.0);
    rotatedMaxAbs = Math.max(rotatedMaxAbs, Math.abs(rotatedCropRgb[index * 3] - expected));
  }
  assert.ok(rotatedMaxAbs <= 250, `rotated RGB16 crop max_abs ${rotatedMaxAbs} exceeds 250`);

  const rotatedIr = Float32Array.from(rotatedCropFixture.input);
  const rotatedIrCrop = cropIrScalarToRgbFrame(
    rotatedIr.buffer.slice(rotatedIr.byteOffset, rotatedIr.byteOffset + rotatedIr.byteLength),
    {
      width: rotatedFixtureWidth,
      height: rotatedFixtureHeight,
      ir: { width: rotatedFixtureWidth, height: rotatedFixtureHeight, channels: 1, bit_depth: 32 },
    },
    rotatedFrame,
    "f32",
  );
  assert.equal(rotatedIrCrop.width, rotatedCropFixture.expected_shape[1]);
  assert.equal(rotatedIrCrop.height, rotatedCropFixture.expected_shape[0]);
  const rotatedIrValues = new Float32Array(rotatedIrCrop.arrayBuffer);
  let rotatedIrMaxAbs = 0.0;
  for (let index = 0; index < rotatedCropFixture.expected.length; index += 1) {
    rotatedIrMaxAbs = Math.max(rotatedIrMaxAbs, Math.abs(rotatedIrValues[index] - rotatedCropFixture.expected[index]));
  }
  assert.ok(rotatedIrMaxAbs <= 0.25, `rotated IR crop max_abs ${rotatedIrMaxAbs} exceeds 0.25`);

  const frameDetectBuffer = syntheticFrameDetectRawBuffer();
  const frameDetectFile = await fileIdentity({
    name: "axis-35mm-vertical-three-frame.rgb16",
    size: frameDetectBuffer.byteLength,
    lastModified: 0,
    arrayBuffer: frameDetectBuffer,
  });
  const detection = defaultFrameDetectConfig({
    format: "35mm",
    frame_count_override: 3,
    detect_film_extent: false,
    apply_clahe: false,
  });
  const frameDetectInput = buildFrameDetectCacheInput({
    file: frameDetectFile,
    image: { width: frameDetectWidth, height: frameDetectHeight, dpi: null },
    detection,
  });
  const expectedFrameDetectKey = await frameDetectCacheKey(frameDetectInput);
  const frameDetectResult = await client.detectFramesRgb16({
    arrayBuffer: frameDetectBuffer,
    file: frameDetectFile,
    image: { width: frameDetectWidth, height: frameDetectHeight, dpi: null },
    detection,
    maxFrames: 8,
  });
  assert.equal(frameDetectResult.cacheKey, expectedFrameDetectKey);
  assert.equal(frameDetectResult.aspect, "24:36");
  assertDetectedFramesApprox(frameDetectResult.frames, expectedDetectedFrames);
  assert.ok(frameDetectResult.rebate);
  const detectedRebateSelection = frameSelectionFromDetectedFrame(frameDetectResult.rebate);
  const detectedRebateDmin = computeDminFromRgb16(frameDetectBuffer.slice(0), {
    width: frameDetectWidth,
    height: frameDetectHeight,
    dpi: null,
  }, detectedRebateSelection);
  assert.equal(detectedRebateDmin.length, 3);
  assert.ok(detectedRebateDmin.every((value) => Number.isFinite(value) && value >= 0.0));
  const firstDetectedSelection = frameSelectionFromDetectedFrame(frameDetectResult.frames[0]);
  assert.equal(firstDetectedSelection.angle, frameDetectResult.frames[0].angle);
  assert.equal(firstDetectedSelection.x, firstDetectedSelection.cx - firstDetectedSelection.w / 2.0);

  const dminFixture = JSON.parse(fs.readFileSync("test/fixtures/processing/numeric/dmin-percentile-25.json", "utf8"));
  const [dminPixels, dminChannels] = dminFixture.shape;
  assert.equal(dminChannels, 3);
  const dminRaw = new Uint16Array(dminFixture.input.length);
  for (let index = 0; index < dminFixture.input.length; index += 1) {
    dminRaw[index] = Math.round(65535.0 * Math.pow(10.0, -dminFixture.input[index]));
  }
  const dminActual = computeDminFromRgb16(
    dminRaw.buffer.slice(dminRaw.byteOffset, dminRaw.byteOffset + dminRaw.byteLength),
    { width: 1, height: dminPixels, dpi: null },
    null,
    { percentile: 25.0 },
  );
  // Shared-core contract: the browser Dmin estimator against the Python
  // estimate_dmin fallback-percentile oracle fixture. The fixture records
  // density-domain inputs; converting them to u16 transmittance samples for
  // the browser entry point quantizes each density by at most
  // log10(s / (s - 0.5)) ~= 3.4e-4 at the smallest sample, so the native
  // 1e-6 fixture tolerance widens to 5e-4 here.
  for (let channel = 0; channel < 3; channel += 1) {
    assert.ok(
      Math.abs(dminActual[channel] - dminFixture.expected[channel]) <= 5.0e-4,
      `dmin channel ${channel}: ${dminActual[channel]} vs oracle ${dminFixture.expected[channel]}`,
    );
  }

  const uniformDminRaw = new Uint16Array([
    32768, 16384, 8192,
    32768, 16384, 8192,
    32768, 16384, 8192,
    32768, 16384, 8192,
  ]);
  const uniformDmin = computeDminFromRgb16(uniformDminRaw.buffer, { width: 2, height: 2, dpi: null });
  assert.ok(Math.abs(uniformDmin[0] - -Math.log10(32768 / 65535)) < 1.0e-12);
  assert.ok(Math.abs(uniformDmin[1] - -Math.log10(16384 / 65535)) < 1.0e-12);
  assert.ok(Math.abs(uniformDmin[2] - -Math.log10(8192 / 65535)) < 1.0e-12);

  const adjusted = await client.processRawRgb16({
    arrayBuffer: rawBuffer,
    file,
    image: { width: 2, height: 2, dpi: null },
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig({ contrast: 1.7 }),
    dmin: [0.06, 0.06, 0.07],
    percentileSampleLimit: 256,
  });
  assert.notEqual(adjusted.cacheKey, result.cacheKey);

  const boundedRaw = new Uint16Array(4 * 4 * 3);
  for (let index = 0; index < boundedRaw.length; index += 1) boundedRaw[index] = 1000 + index * 257;
  const boundedBuffer = boundedRaw.buffer.slice(boundedRaw.byteOffset, boundedRaw.byteOffset + boundedRaw.byteLength);
  const boundedFile = await fileIdentity({
    name: "bounded-preview-4x4.rgb16",
    size: boundedBuffer.byteLength,
    lastModified: 0,
    arrayBuffer: boundedBuffer,
  });
  const boundedGeometry = previewOutputGeometry(4, 4, 4);
  assert.deepEqual(boundedGeometry, {
    width: 2,
    height: 2,
    scale: 0.5,
    max_pixels: 4,
  });
  const boundedCacheInput = buildPreviewCacheInput({
    file: boundedFile,
    image: { width: 4, height: 4, dpi: null },
    stock: "kodak_gold",
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    dmin: [0.05, 0.06, 0.07],
    preview: {
      max_px: 4,
      output_width: 2,
      output_height: 2,
      scale: 0.5,
      percentile_sample_limit: 16384,
    },
  });
  const boundedResult = await client.processRawRgb16({
    arrayBuffer: boundedBuffer,
    file: boundedFile,
    image: { width: 4, height: 4, dpi: null },
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    previewMaxPx: 4,
  });
  assert.equal(boundedResult.cacheKey, await previewCacheKey(boundedCacheInput));
  assert.equal(boundedResult.width, 2);
  assert.equal(boundedResult.height, 2);
  assert.equal(boundedResult.rgb8.length, 12);
  assert.equal(boundedResult.previewScale, 0.5);
  assert.ok(boundedResult.timings.some((timing) => timing.stage === "worker.resize-rgb16-area"));

  assert.deepEqual(
    enabledExportVariants(defaultOutputSelection({ ir_neg: true, ir_inv: false, inv_only: true })).map((variant) => variant.id),
    ["ir_neg", "inv_only"],
  );
  assert.equal(nativeExportFilename({
    sourceName: "synthetic-2x2.rgb16",
    frameIndex: 0,
    variant: exportVariants.irNeg,
  }), "synthetic-2x2_01_ir.tif");
  assert.equal(nativeExportFilename({
    sourceName: "synthetic-2x2.rgb16",
    frameIndex: 0,
    variant: exportVariants.irInv,
  }), "synthetic-2x2_01.tif");
  assert.equal(nativeExportFilename({
    sourceName: "synthetic-2x2.rgb16",
    frameIndex: 0,
    variant: exportVariants.invOnly,
  }), "synthetic-2x2_01_inv.tif");
  assert.equal(nativeExportMetadataFilename({
    sourceName: "synthetic-2x2.rgb16",
    frameIndex: 0,
    variant: exportVariants.invOnly,
  }), "synthetic-2x2_01_inv.tif.json");

  const exportResult = await client.exportRawRgb16({
    arrayBuffer: rawBuffer,
    file,
    image: { width: 2, height: 2, dpi: null },
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    variant: exportVariants.invOnly,
  });
  assert.equal(exportResult.width, 2);
  assert.equal(exportResult.height, 2);
  assert.equal(exportResult.rgb16.length, expectedDemoPreview.length);
  for (let index = 0; index < exportResult.rgb16.length; index += 1) {
    assert.equal(exportResult.rgb16[index] >> 8, expectedDemoPreview[index]);
  }
  assert.notEqual(exportResult.cacheKey, result.cacheKey);
  const exportTiff = rgb16ToTiffBytes(exportResult.rgb16, exportResult.width, exportResult.height, { dpi: 800 });
  const exportTiffRoundTrip = loadRgb16PageFromTiff(
    exportTiff.buffer.slice(exportTiff.byteOffset, exportTiff.byteOffset + exportTiff.byteLength),
  );
  assert.equal(exportTiffRoundTrip.width, exportResult.width);
  assert.equal(exportTiffRoundTrip.height, exportResult.height);
  assert.equal(exportTiffRoundTrip.dpi, 800);
  assert.deepEqual(Array.from(exportTiffRoundTrip.data), Array.from(exportResult.rgb16));
  const exportMetadata = buildNativeVariantExportMetadata({
    file,
    image: { width: 2, height: 2, dpi: null },
    frame: exportResult.frame,
    variant: exportVariants.invOnly,
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    dmin: [0.05, 0.06, 0.07],
    cacheKey: exportResult.cacheKey,
    output: {
      schema: "v600.webapp.rgb16-export.v1",
      operation: "rgb16-export",
      kind: "rgb16-export",
      format: "tiff",
      color_space: "srgb",
      bit_depth: 16,
      width: exportResult.width,
      height: exportResult.height,
    },
    timings: exportResult.timings,
  });
  const exportMetadataValue = JSON.parse(new TextDecoder().decode(metadataJsonBytes(exportMetadata)));
  assert.equal(exportMetadataValue.variant, "inverted");
  assert.equal(exportMetadataValue.stock, "kodak_gold");
  assert.deepEqual(exportMetadataValue.dmin, [0.05, 0.06, 0.07]);

  const irInvResult = await client.exportRawRgb16({
    arrayBuffer: rawBuffer,
    file,
    image: { width: 2, height: 2, dpi: null },
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    variant: exportVariants.irInv,
  });
  assert.notEqual(irInvResult.cacheKey, exportResult.cacheKey);
  assert.deepEqual(Array.from(irInvResult.rgb16), Array.from(exportResult.rgb16));

  const multiFrameExports = await exportNativeVariantResults({
    client,
    arrayBuffer: rawBuffer,
    file,
    image: { width: 2, height: 2, dpi: null },
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    dmin: [0.05, 0.06, 0.07],
    frameSelections: [
      normalizeFrameSelection(null, { width: 2, height: 2 }),
      manualFrame,
    ],
    variants: [exportVariants.irInv, exportVariants.invOnly],
  });
  assert.equal(multiFrameExports.length, 4);
  assert.deepEqual(multiFrameExports.map((item) => item.filename), [
    "synthetic-2x2_01.tif",
    "synthetic-2x2_01_inv.tif",
    "synthetic-2x2_02.tif",
    "synthetic-2x2_02_inv.tif",
  ]);
  assert.deepEqual(multiFrameExports.map((item) => item.metadataFilename), [
    "synthetic-2x2_01.tif.json",
    "synthetic-2x2_01_inv.tif.json",
    "synthetic-2x2_02.tif.json",
    "synthetic-2x2_02_inv.tif.json",
  ]);
  assert.equal(multiFrameExports[2].result.width, 1);
  assert.equal(multiFrameExports[2].result.height, 2);
  assert.equal(multiFrameExports[2].metadata.crop.cx, manualFrame.cx);

  const irNegResult = await exportRawNegativeRgb16({
    arrayBuffer: rawBuffer,
    file,
    image: { width: 2, height: 2, dpi: null },
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    variant: exportVariants.irNeg,
  });
  assert.deepEqual(Array.from(irNegResult.rgb16), Array.from(rawFixture));
  assert.notEqual(irNegResult.cacheKey, exportResult.cacheKey);
  const irNegMetadata = buildNativeVariantExportMetadata({
    file,
    image: { width: 2, height: 2, dpi: null },
    frame: irNegResult.frame,
    variant: exportVariants.irNeg,
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    dmin: [0.05, 0.06, 0.07],
    cacheKey: irNegResult.cacheKey,
    output: {
      kind: "rgb16-export",
      format: "tiff",
      color_space: "scanner-rgb",
      bit_depth: 16,
      width: irNegResult.width,
      height: irNegResult.height,
    },
    timings: irNegResult.timings,
  });
  const irNegMetadataValue = JSON.parse(new TextDecoder().decode(metadataJsonBytes(irNegMetadata)));
  assert.equal(irNegMetadataValue.variant, "ir_cleaned");
  assert.equal("stock" in irNegMetadataValue, false);

  const irMaskPixels = new Uint8Array(9 * 9);
  irMaskPixels[40] = 255;
  const irImage = {
    width: 2,
    height: 2,
    dpi: null,
    page_layout: "rgb-thumb-ir",
    ir: {
      width: 9,
      height: 9,
      channels: 1,
      bit_depth: 8,
    },
  };
  const dustRemoval = defaultDustRemovalConfig({
    ir_threshold: 1.0,
    ir_hair_sensitivity: 2.0,
    ir_min_area: 1,
    ir_dilate_radius: 0,
    ir_close_radius: 0,
    ir_blur_size: 7,
    ir_max_coverage: 1.0,
  });
  const irCacheInput = buildIrMaskCacheInput({ file, image: irImage, dustRemoval });
  const irMaskKey = await irMaskCacheKey(irCacheInput);
  const expectedRgbMask = new Uint8Array([
    0, 255,
    255, 255,
  ]);
  const irRgbMaskCacheInput = buildIrRgbMaskCacheInput({
    file,
    image: irImage,
    dustRemoval,
    irMaskCacheKey: irMaskKey,
  });
  const expectedIrRgbMaskKey = await irRgbMaskCacheKey(irRgbMaskCacheInput);
  const irRgbMask = await client.resizeIrMaskToRgbU8({
    maskBuffer: irMaskPixels.buffer.slice(irMaskPixels.byteOffset, irMaskPixels.byteOffset + irMaskPixels.byteLength),
    file,
    image: irImage,
    dustRemoval,
    irMaskCacheKey: irMaskKey,
  });
  assert.equal(irRgbMask.cacheKey, expectedIrRgbMaskKey);
  assert.equal(irRgbMask.width, 2);
  assert.equal(irRgbMask.height, 2);
  assert.deepEqual(Array.from(irRgbMask.mask), Array.from(expectedRgbMask));

  const grainFixture = JSON.parse(fs.readFileSync("test/fixtures/processing/ir/inpaint-biharmonic-grain-uint16-smoke.json", "utf8"));
  const [grainHeight, grainWidth, grainChannels] = grainFixture.shape;
  assert.equal(grainChannels, 3);
  const grainInput = Uint16Array.from(grainFixture.input);
  const grainMask = Uint8Array.from(grainFixture.mask, (value) => value === 0 ? 0 : 255);
  const grainNoise = Float64Array.from(grainFixture.noise);
  const grainExpected = Uint16Array.from(grainFixture.expected);
  const grainImage = {
    width: grainWidth,
    height: grainHeight,
    dpi: null,
    page_layout: "rgb-thumb-ir",
    ir: {
      width: grainWidth,
      height: grainHeight,
      channels: 1,
      bit_depth: 8,
    },
  };
  const grainInputBuffer = grainInput.buffer.slice(grainInput.byteOffset, grainInput.byteOffset + grainInput.byteLength);
  const grainMaskBuffer = grainMask.buffer.slice(grainMask.byteOffset, grainMask.byteOffset + grainMask.byteLength);
  const grainNoiseBuffer = grainNoise.buffer.slice(grainNoise.byteOffset, grainNoise.byteOffset + grainNoise.byteLength);
  const grainBytes = new Uint8Array(grainInputBuffer.byteLength + grainMaskBuffer.byteLength + grainNoiseBuffer.byteLength);
  grainBytes.set(new Uint8Array(grainInputBuffer), 0);
  grainBytes.set(new Uint8Array(grainMaskBuffer), grainInputBuffer.byteLength);
  grainBytes.set(new Uint8Array(grainNoiseBuffer), grainInputBuffer.byteLength + grainMaskBuffer.byteLength);
  const grainFile = await fileIdentity({
    name: "biharmonic-grain-inpaint.rgb16-mask-noise",
    size: grainBytes.byteLength,
    lastModified: 0,
    arrayBuffer: grainBytes.buffer,
  });
  const grainNoiseFile = await fileIdentity({
    name: "biharmonic-grain-noise.float64",
    size: grainNoiseBuffer.byteLength,
    lastModified: 0,
    arrayBuffer: grainNoiseBuffer.slice(0),
  });
  const grainRgbMaskCacheKey = "sha256:webapp-shell-grain-rgb-mask";
  const grainCacheInput = buildIrInpaintCacheInput({
    file: grainFile,
    image: grainImage,
    dustRemoval,
    rgbMaskCacheKey: grainRgbMaskCacheKey,
    mode: "biharmonic-grain",
    padding: grainFixture.padding,
    grainPadding: grainFixture.grain_padding,
    noiseHash: grainNoiseFile.content_hash,
  });
  const expectedGrainKey = await irInpaintCacheKey(grainCacheInput);
  const grainResult = await client.inpaintGrainRgb16WithNoise({
    rgbBuffer: grainInputBuffer,
    maskBuffer: grainMaskBuffer,
    noiseBuffer: grainNoiseBuffer,
    file: grainFile,
    image: grainImage,
    dustRemoval,
    rgbMaskCacheKey: grainRgbMaskCacheKey,
    padding: grainFixture.padding,
    grainPadding: grainFixture.grain_padding,
  });
  assert.equal(grainResult.cacheKey, expectedGrainKey);
  assert.equal(grainResult.noiseHash, grainNoiseFile.content_hash);
  assert.equal(grainResult.mode, "biharmonic-grain");
  let grainMaxAbs = 0;
  for (let index = 0; index < grainResult.rgb16.length; index += 1) {
    grainMaxAbs = Math.max(grainMaxAbs, Math.abs(grainResult.rgb16[index] - grainExpected[index]));
  }
  assert.ok(grainMaxAbs <= grainFixture.tolerance.abs, `shell grain inpaint max_abs ${grainMaxAbs} exceeds ${grainFixture.tolerance.abs}`);

  const seededNoise = "shell-grain-noise-seed";
  const seededGrainCacheInput = buildIrInpaintCacheInput({
    file: grainFile,
    image: grainImage,
    dustRemoval,
    rgbMaskCacheKey: grainRgbMaskCacheKey,
    mode: "biharmonic-grain",
    padding: grainFixture.padding,
    grainPadding: grainFixture.grain_padding,
    noiseHash: `seed:${seededNoise}`,
  });
  const seededGrainKey = await irInpaintCacheKey(seededGrainCacheInput);
  const seededGrainA = await client.inpaintGrainRgb16WithNoise({
    rgbBuffer: grainInput.buffer.slice(grainInput.byteOffset, grainInput.byteOffset + grainInput.byteLength),
    maskBuffer: grainMask.buffer.slice(grainMask.byteOffset, grainMask.byteOffset + grainMask.byteLength),
    noiseSeed: seededNoise,
    file: grainFile,
    image: grainImage,
    dustRemoval,
    rgbMaskCacheKey: grainRgbMaskCacheKey,
    padding: grainFixture.padding,
    grainPadding: grainFixture.grain_padding,
  });
  const seededGrainB = await client.inpaintGrainRgb16WithNoise({
    rgbBuffer: grainInput.buffer.slice(grainInput.byteOffset, grainInput.byteOffset + grainInput.byteLength),
    maskBuffer: grainMask.buffer.slice(grainMask.byteOffset, grainMask.byteOffset + grainMask.byteLength),
    noiseSeed: seededNoise,
    file: grainFile,
    image: grainImage,
    dustRemoval,
    rgbMaskCacheKey: grainRgbMaskCacheKey,
    padding: grainFixture.padding,
    grainPadding: grainFixture.grain_padding,
  });
  assert.equal(seededGrainA.cacheKey, seededGrainKey);
  assert.equal(seededGrainA.noiseHash, `seed:${seededNoise}`);
  assert.ok(seededGrainA.timings.some((timing) => timing.stage === "worker.generate-ir-grain-noise"));
  assert.deepEqual(Array.from(seededGrainA.rgb16), Array.from(seededGrainB.rgb16));

  const cleanFixture = JSON.parse(fs.readFileSync("test/fixtures/processing/ir/ir-clean-region-uint16-smoke.json", "utf8"));
  const [cleanHeight, cleanWidth, cleanChannels] = cleanFixture.rgb_shape;
  const [cleanIrHeight, cleanIrWidth] = cleanFixture.ir_shape;
  assert.equal(cleanChannels, 3);
  const cleanRgb = Uint16Array.from(cleanFixture.rgb);
  const cleanIr = Float32Array.from(cleanFixture.ir);
  const cleanNoise = Float64Array.from(cleanFixture.noise);
  const cleanExpected = Uint16Array.from(cleanFixture.expected);
  const cleanInputBytes = new Uint8Array(cleanRgb.byteLength + cleanIr.byteLength);
  cleanInputBytes.set(new Uint8Array(cleanRgb.buffer), 0);
  cleanInputBytes.set(new Uint8Array(cleanIr.buffer), cleanRgb.byteLength);
  const cleanFile = await fileIdentity({
    name: "ir-clean-region.rgb16-ir-f32",
    size: cleanInputBytes.byteLength,
    lastModified: 0,
    arrayBuffer: cleanInputBytes.buffer,
  });
  const cleanResult = await client.exportIrCleanedRgb16({
    arrayBuffer: cleanRgb.buffer.slice(cleanRgb.byteOffset, cleanRgb.byteOffset + cleanRgb.byteLength),
    irBuffer: cleanIr.buffer.slice(cleanIr.byteOffset, cleanIr.byteOffset + cleanIr.byteLength),
    irSampleFormat: "f32",
    file: cleanFile,
    image: {
      width: cleanWidth,
      height: cleanHeight,
      dpi: null,
      page_layout: "rgb-ir-f32",
      ir: {
        width: cleanIrWidth,
        height: cleanIrHeight,
        channels: 1,
        bit_depth: 32,
      },
    },
    dustRemoval: {
      ...defaultDustRemovalConfig(),
      ir_threshold: cleanFixture.threshold,
      ir_hair_sensitivity: cleanFixture.hair_sensitivity,
      ir_min_area: cleanFixture.min_area,
      ir_dilate_radius: cleanFixture.dilate_radius,
      ir_close_radius: cleanFixture.close_radius,
      ir_blur_size: cleanFixture.blur_size,
      ir_max_coverage: cleanFixture.max_coverage,
      inpaint_padding: cleanFixture.inpaint_padding,
    },
    noiseBuffer: cleanNoise.buffer.slice(cleanNoise.byteOffset, cleanNoise.byteOffset + cleanNoise.byteLength),
    alignIr: false,
    variant: exportVariants.irNeg,
    grainPadding: cleanFixture.grain_padding,
  });
  assert.equal(cleanResult.mode, "biharmonic-grain");
  assert.ok(cleanResult.timings.some((timing) => timing.stage === "worker.crop-ir-clean-rgb16"));
  assert.ok(cleanResult.timings.some((timing) => timing.stage === "worker.crop-ir-clean-ir-f32"));
  let cleanMaxAbs = 0;
  for (let index = 0; index < cleanResult.rgb16.length; index += 1) {
    cleanMaxAbs = Math.max(cleanMaxAbs, Math.abs(cleanResult.rgb16[index] - cleanExpected[index]));
  }
  assert.ok(cleanMaxAbs <= cleanFixture.tolerance.abs, `shell cleaned export max_abs ${cleanMaxAbs} exceeds ${cleanFixture.tolerance.abs}`);

  const cleanExpectedBuffer = cleanExpected.buffer.slice(cleanExpected.byteOffset, cleanExpected.byteOffset + cleanExpected.byteLength);
  const cleanExpectedFile = await fileIdentity({
    name: "ir-clean-region-expected.rgb16",
    size: cleanExpectedBuffer.byteLength,
    lastModified: 0,
    arrayBuffer: cleanExpectedBuffer.slice(0),
  });
  const expectedCleanInv = await client.exportRawRgb16({
    arrayBuffer: cleanExpectedBuffer,
    file: cleanExpectedFile,
    image: { width: cleanWidth, height: cleanHeight, dpi: null, page_layout: "rgb" },
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    dmin: [0.05, 0.06, 0.07],
    variant: exportVariants.irInv,
  });
  const cleanInvResult = await client.exportIrCleanedRgb16({
    arrayBuffer: cleanRgb.buffer.slice(cleanRgb.byteOffset, cleanRgb.byteOffset + cleanRgb.byteLength),
    irBuffer: cleanIr.buffer.slice(cleanIr.byteOffset, cleanIr.byteOffset + cleanIr.byteLength),
    irSampleFormat: "f32",
    file: cleanFile,
    image: {
      width: cleanWidth,
      height: cleanHeight,
      dpi: null,
      page_layout: "rgb-ir-f32",
      ir: {
        width: cleanIrWidth,
        height: cleanIrHeight,
        channels: 1,
        bit_depth: 32,
      },
    },
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    dmin: [0.05, 0.06, 0.07],
    dustRemoval: {
      ...defaultDustRemovalConfig(),
      ir_threshold: cleanFixture.threshold,
      ir_hair_sensitivity: cleanFixture.hair_sensitivity,
      ir_min_area: cleanFixture.min_area,
      ir_dilate_radius: cleanFixture.dilate_radius,
      ir_close_radius: cleanFixture.close_radius,
      ir_blur_size: cleanFixture.blur_size,
      ir_max_coverage: cleanFixture.max_coverage,
      inpaint_padding: cleanFixture.inpaint_padding,
    },
    noiseBuffer: cleanNoise.buffer.slice(cleanNoise.byteOffset, cleanNoise.byteOffset + cleanNoise.byteLength),
    alignIr: false,
    variant: exportVariants.irInv,
    grainPadding: cleanFixture.grain_padding,
  });
  let cleanInvMaxAbs = 0;
  for (let index = 0; index < cleanInvResult.rgb16.length; index += 1) {
    cleanInvMaxAbs = Math.max(cleanInvMaxAbs, Math.abs(cleanInvResult.rgb16[index] - expectedCleanInv.rgb16[index]));
  }
  assert.equal(cleanInvMaxAbs, 0);

  const alignFixture = JSON.parse(fs.readFileSync("test/fixtures/processing/ir/align-ratio-1-to-2.json", "utf8"));
  const estimateRgb = buildAlignmentRgbFixture(alignFixture);
  const estimateRgbBuffer = estimateRgb.buffer.slice(estimateRgb.byteOffset, estimateRgb.byteOffset + estimateRgb.byteLength);
  const estimateIr = Float32Array.from(alignFixture.ir);
  const estimateIrBuffer = estimateIr.buffer.slice(estimateIr.byteOffset, estimateIr.byteOffset + estimateIr.byteLength);
  const estimateBytes = new Uint8Array(estimateRgbBuffer.byteLength + estimateIrBuffer.byteLength);
  estimateBytes.set(new Uint8Array(estimateRgbBuffer), 0);
  estimateBytes.set(new Uint8Array(estimateIrBuffer), estimateRgbBuffer.byteLength);
  const estimateFile = await fileIdentity({
    name: "align-ratio-1-to-2.rgb-ir-f32",
    size: estimateBytes.byteLength,
    lastModified: 0,
    arrayBuffer: estimateBytes.buffer,
  });
  const estimateImage = {
    width: alignFixture.ir_shape[1] * alignFixture.ratio,
    height: alignFixture.ir_shape[0] * alignFixture.ratio,
    dpi: 800,
    page_layout: "rgb-thumb-ir",
    ir: {
      width: alignFixture.ir_shape[1],
      height: alignFixture.ir_shape[0],
      channels: 1,
      bit_depth: 32,
    },
  };
  const estimateCacheInput = buildIrEstimateCacheInput({ file: estimateFile, image: estimateImage });
  const expectedEstimateKey = await irEstimateCacheKey(estimateCacheInput);
  const estimatedAlignment = await client.estimateIrTranslationF32({
    rgbBuffer: estimateRgbBuffer,
    irBuffer: estimateIrBuffer,
    file: estimateFile,
    image: estimateImage,
  });
  assert.equal(estimatedAlignment.cacheKey, expectedEstimateKey);
  assert.equal(estimatedAlignment.alignment.mode, "estimated-translation-ecc");
  assert.ok(Math.abs(estimatedAlignment.alignment.tx - alignFixture.expected_offset[0]) <= 0.25);
  assert.ok(Math.abs(estimatedAlignment.alignment.ty - alignFixture.expected_offset[1]) <= 0.25);
  assert.ok(estimatedAlignment.timings.some((timing) => timing.stage === "worker.process-ir-estimate"));

  const estimateRgbU16 = Uint16Array.from(estimateRgb, (value) => Math.max(0, Math.min(65535, Math.round(value))));
  const estimateRgbU16Buffer = estimateRgbU16.buffer.slice(estimateRgbU16.byteOffset, estimateRgbU16.byteOffset + estimateRgbU16.byteLength);
  const rawEstimateIrBuffer = estimateIr.buffer.slice(estimateIr.byteOffset, estimateIr.byteOffset + estimateIr.byteLength);
  const rawEstimateBytes = new Uint8Array(estimateRgbU16Buffer.byteLength + rawEstimateIrBuffer.byteLength);
  rawEstimateBytes.set(new Uint8Array(estimateRgbU16Buffer), 0);
  rawEstimateBytes.set(new Uint8Array(rawEstimateIrBuffer), estimateRgbU16Buffer.byteLength);
  const rawEstimateFile = await fileIdentity({
    name: "align-ratio-1-to-2.rgb-u16-ir-f32",
    size: rawEstimateBytes.byteLength,
    lastModified: 0,
    arrayBuffer: rawEstimateBytes.buffer,
  });
  const rawEstimatedAlignment = await client.estimateIrTranslationF32({
    rgbBuffer: estimateRgbU16Buffer,
    irBuffer: rawEstimateIrBuffer.slice(0),
    rgbSampleFormat: "u16",
    irSampleFormat: "f32",
    file: rawEstimateFile,
    image: estimateImage,
  });
  assert.ok(Math.abs(rawEstimatedAlignment.alignment.tx - estimatedAlignment.alignment.tx) <= 0.05);
  assert.ok(Math.abs(rawEstimatedAlignment.alignment.ty - estimatedAlignment.alignment.ty) <= 0.05);
  assert.ok(rawEstimatedAlignment.timings.some((timing) => timing.stage === "worker.convert-ir-estimate-inputs-f32"));

  const alignInput = Float32Array.from(alignFixture.ir);
  const alignBuffer = alignInput.buffer.slice(alignInput.byteOffset, alignInput.byteOffset + alignInput.byteLength);
  const alignFile = await fileIdentity({
    name: "align-ratio-1-to-2.ir-f32",
    size: alignBuffer.byteLength,
    lastModified: 0,
    arrayBuffer: alignBuffer,
  });
  const alignImage = {
    width: 160,
    height: 128,
    dpi: 800,
    page_layout: "rgb-thumb-ir",
    ir: {
      width: alignFixture.ir_shape[1],
      height: alignFixture.ir_shape[0],
      channels: 1,
      bit_depth: 32,
    },
  };
  const alignment = {
    mode: "provided-offset",
    tx: alignFixture.expected_offset[0],
    ty: alignFixture.expected_offset[1],
  };
  const alignCacheInput = buildIrAlignCacheInput({ file: alignFile, image: alignImage, alignment });
  const expectedAlignKey = await irAlignCacheKey(alignCacheInput);
  const alignedIr = await client.applyIrTranslationF32({
    irBuffer: alignBuffer,
    file: alignFile,
    image: alignImage,
    alignment,
  });
  assert.equal(alignedIr.cacheKey, expectedAlignKey);
  assert.equal(alignedIr.width, alignFixture.ir_shape[1]);
  assert.equal(alignedIr.height, alignFixture.ir_shape[0]);
  const alignError = assertCloseToFixture(alignedIr.ir, alignFixture);
  assert.ok(alignedIr.timings.some((timing) => timing.stage === "worker.process-ir-align"));

  const alignInputU16 = Uint16Array.from(alignFixture.ir, (value) => Math.max(0, Math.min(65535, Math.round(value))));
  const alignU16Buffer = alignInputU16.buffer.slice(alignInputU16.byteOffset, alignInputU16.byteOffset + alignInputU16.byteLength);
  const alignU16File = await fileIdentity({
    name: "align-ratio-1-to-2.ir-u16",
    size: alignU16Buffer.byteLength,
    lastModified: 0,
    arrayBuffer: alignU16Buffer.slice(0),
  });
  const alignU16Image = {
    ...alignImage,
    ir: {
      ...alignImage.ir,
      bit_depth: 16,
    },
  };
  const alignedIrU16 = await client.applyIrTranslationF32({
    irBuffer: alignU16Buffer,
    irSampleFormat: "u16",
    file: alignU16File,
    image: alignU16Image,
    alignment,
  });
  assert.equal(alignedIrU16.width, alignFixture.ir_shape[1]);
  assert.equal(alignedIrU16.height, alignFixture.ir_shape[0]);
  assertCloseToFixture(alignedIrU16.ir, alignFixture, alignError.maxAbs + 0.75, alignError.rms + 0.75);
  assert.ok(alignedIrU16.timings.some((timing) => timing.stage === "worker.convert-ir-align-input-f32"));

  const tiffBytes = fs.readFileSync("test/fixtures/tiff/rgb-thumb-ir.tiff");
  const tiffBuffer = tiffBytes.buffer.slice(tiffBytes.byteOffset, tiffBytes.byteOffset + tiffBytes.byteLength);
  const rgbPage = loadRgb16PageFromTiff(tiffBuffer);
  const irPage = loadIrPageFromTiff(tiffBuffer);
  assert.ok(irPage);
  const tiffImage = {
    width: rgbPage.width,
    height: rgbPage.height,
    dpi: rgbPage.dpi,
    page_layout: "rgb-thumb-ir",
    ir: {
      width: irPage.width,
      height: irPage.height,
      channels: 1,
      bit_depth: 8,
    },
  };
  const tiffFile = await fileIdentity({
    name: "rgb-thumb-ir.tiff",
    size: tiffBuffer.byteLength,
    lastModified: 0,
    arrayBuffer: tiffBuffer,
  });
  const tiffCacheInput = buildPreviewCacheInput({
    file: tiffFile,
    image: tiffImage,
    stock: "kodak_gold",
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    dmin: [0.05, 0.06, 0.07],
    preview: { max_px: rgbPage.width * rgbPage.height, percentile_sample_limit: 16384 },
  });
  assert.equal(tiffCacheInput.image.page_layout, "rgb-thumb-ir");
  assert.deepEqual(tiffCacheInput.image.ir, tiffImage.ir);
  const rgbOnlyTiffCacheInput = buildPreviewCacheInput({
    file: tiffFile,
    image: { width: rgbPage.width, height: rgbPage.height, dpi: rgbPage.dpi },
    stock: "kodak_gold",
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    dmin: [0.05, 0.06, 0.07],
    preview: { max_px: rgbPage.width * rgbPage.height, percentile_sample_limit: 16384 },
  });
  const tiffExpectedKey = await previewCacheKey(tiffCacheInput);
  assert.notEqual(tiffExpectedKey, await previewCacheKey(rgbOnlyTiffCacheInput));
  const tiffResult = await client.processRawRgb16({
    arrayBuffer: rgbPage.data.buffer.slice(rgbPage.data.byteOffset, rgbPage.data.byteOffset + rgbPage.data.byteLength),
    file: tiffFile,
    image: tiffImage,
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
  });
  assert.equal(tiffResult.cacheKey, tiffExpectedKey);
  assert.equal(tiffResult.rgb8.length, rgbPage.data.length);
  assert.throws(() => parseRawRgb16Buffer(rawBuffer, { width: 3, height: 2 }), /does not match/);

  console.log(JSON.stringify({
    event: "webapp-shell-smoke",
    schema: "v600.webapp.event.v1",
    cache_key: result.cacheKey,
    output_bytes: result.rgb8.length,
    ir_alignment_max_abs: alignError.maxAbs,
    ir_alignment_rms: alignError.rms,
    status: "ok",
  }));
} finally {
  await client.close();
}
