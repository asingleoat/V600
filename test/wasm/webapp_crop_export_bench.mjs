import fs from "node:fs";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { Worker } from "node:worker_threads";

import {
  WebPreviewClient,
  cropRgb16ToFrame,
  defaultRenderConfig,
  exportNativeVariantResults,
  exportVariants,
  fileIdentity,
  frameSelectionFromDetectedFrame,
  normalizeFrameSelection,
  stockIds,
} from "../../web/app_core.mjs";
import { loadIrPageFromTiff, loadRgb16PageFromTiff } from "../../web/tiff.mjs";

const wasmPath = process.argv[2];
if (!wasmPath) throw new Error("usage: node test/wasm/webapp_crop_export_bench.mjs <cerealgrain-wasm-core.wasm> [--scan path] [--max-frames n] [--variant inv-only|ir-neg|ir-inv]");

const options = parseArgs(process.argv.slice(3));
const scanPath = options.scan ?? process.env.CEREALGRAIN_WASM_BENCH_SCAN ?? defaultScanPath();
if (!scanPath || !fs.existsSync(scanPath)) {
  console.log(JSON.stringify({
    event: "wasm-webapp-crop-export-bench",
    schema: "cerealgrain.webapp.event.v1",
    status: "skipped",
    reason: "no local scan TIFF found; set CEREALGRAIN_WASM_BENCH_SCAN or pass --scan",
  }));
  process.exit(0);
}

const maxFrames = Math.max(1, Number.parseInt(options.maxFrames ?? "2", 10) || 2);
const variant = variantByName(options.variant ?? "inv-only");
const cropRepeats = Math.max(1, Number.parseInt(options.cropRepeats ?? "3", 10) || 3);
const scanBytes = fs.readFileSync(scanPath);
const scanBuffer = scanBytes.buffer.slice(scanBytes.byteOffset, scanBytes.byteOffset + scanBytes.byteLength);

const loadStarted = performance.now();
const rgbPage = loadRgb16PageFromTiff(scanBuffer);
const irPage = loadIrPageFromTiff(scanBuffer);
const loadUs = elapsedUs(loadStarted);
const rgbBuffer = rgbPage.data.buffer.slice(rgbPage.data.byteOffset, rgbPage.data.byteOffset + rgbPage.data.byteLength);
const irBuffer = irPage
  ? irPage.data.buffer.slice(irPage.data.byteOffset, irPage.data.byteOffset + irPage.data.byteLength)
  : null;
const image = {
  width: rgbPage.width,
  height: rgbPage.height,
  dpi: rgbPage.dpi,
  page_layout: irPage ? "rgb-thumb-ir" : "rgb",
  ir: irPage ? {
    width: irPage.width,
    height: irPage.height,
    channels: 1,
    bit_depth: 8,
  } : null,
};
const oracleFrames = loadOracleFrames(scanPath, image);
const frameSelections = oracleFrames.slice(0, maxFrames).map((frame) => normalizeFrameSelection(frameSelectionFromDetectedFrame(frame), image));
if (frameSelections.length === 0) throw new Error(`no benchmark frames available for ${scanPath}`);

const fileStarted = performance.now();
const file = await fileIdentity({
  name: path.basename(scanPath),
  size: scanBytes.byteLength,
  lastModified: fs.statSync(scanPath).mtimeMs,
  arrayBuffer: scanBuffer,
});
const fileIdentityUs = elapsedUs(fileStarted);

const axisFrame = normalizeFrameSelection({ ...frameSelections[0], angle: 0.0 }, image);
const rotatedFrame = frameSelections[0];
const axisCrop = benchCrop(rgbBuffer, image, axisFrame, cropRepeats);
const rotatedCrop = benchCrop(rgbBuffer, image, rotatedFrame, cropRepeats);

const worker = new Worker(new URL("../../web/worker/processor.mjs", import.meta.url), { type: "module" });
const client = new WebPreviewClient({ worker, wasmUrl: wasmPath, timeoutMs: 120000 });

let previewUs = null;
let previewChecksum = null;
let previewWorkerCropUs = null;
let exportUs = null;
let exportChecksums = [];
try {
  await client.loadModule();

  const previewInput = rgbBuffer.slice(0);
  const previewStarted = performance.now();
  const preview = await client.processRawRgb16({
    arrayBuffer: previewInput,
    file,
    image,
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    frameSelection: rotatedFrame,
    transferInput: true,
  });
  previewUs = elapsedUs(previewStarted);
  previewChecksum = checksumU8(preview.rgb8);
  previewWorkerCropUs = timingUs(preview.timings, "worker.crop-rgb16");

  const exportInput = frameSelections.length === 1 ? rgbBuffer.slice(0) : rgbBuffer;
  const exportStarted = performance.now();
  const exported = await exportNativeVariantResults({
    client,
    arrayBuffer: exportInput,
    irBuffer,
    irSampleFormat: irPage ? "u8" : "u8",
    file,
    image,
    stockId: stockIds.kodakGold,
    render: defaultRenderConfig(),
    frameSelections,
    variants: [variant],
    transferInput: frameSelections.length === 1,
  });
  exportUs = elapsedUs(exportStarted);
  exportChecksums = exported.map((item) => ({
    frame_index: item.frameIndex,
    variant: item.variant.id,
    width: item.result.width,
    height: item.result.height,
    samples: item.result.rgb16.length,
    checksum: checksumU16(item.result.rgb16),
    worker_crop_us: timingUs(item.result.timings, "worker.crop-rgb16"),
  }));
} finally {
  await client.close();
}

const exportPerOutputUs = exportChecksums.length > 0 ? exportUs / exportChecksums.length : null;
const cropShare = exportPerOutputUs ? rotatedCrop.median_us / exportPerOutputUs : null;
const blocksFrameBudget = rotatedCrop.median_us > 16_000;
const materialExportShare = cropShare !== null && cropShare > 0.05;
const workerCropActive = previewWorkerCropUs !== null && exportChecksums.every((item) => item.worker_crop_us !== null);
const decision = blocksFrameBudget || materialExportShare
  ? workerCropActive
    ? "crop-is-material-and-now-runs-in-worker; consider-wasm-crop-optimization-later"
    : "move-crop-off-main-thread-before-browser-release"
  : "keep-shell-crop-for-now";

console.log(JSON.stringify({
  event: "wasm-webapp-crop-export-bench",
  schema: "cerealgrain.webapp.event.v1",
  status: "ok",
  scan: scanPath,
  file_bytes: scanBytes.byteLength,
  rgb: { width: rgbPage.width, height: rgbPage.height, samples: rgbPage.data.length },
  ir: irPage ? { width: irPage.width, height: irPage.height, samples: irPage.data.length } : null,
  oracle_frames: oracleFrames.length,
  frames_used: frameSelections.length,
  variant: variant.id,
  load_tiff_us: loadUs,
  file_identity_us: fileIdentityUs,
  axis_crop: axisCrop,
  rotated_crop: rotatedCrop,
  rotated_preview_us: previewUs,
  rotated_preview_worker_crop_us: previewWorkerCropUs,
  rotated_preview_checksum: previewChecksum,
  export_all_us: exportUs,
  export_per_output_us: exportPerOutputUs,
  rotated_crop_share_of_export_per_output: cropShare,
  worker_crop_active: workerCropActive,
  export_outputs: exportChecksums,
  decision,
}));

function benchCrop(arrayBuffer, image, frame, repeats) {
  const times = [];
  let checksum = 0;
  let width = 0;
  let height = 0;
  let samples = 0;
  for (let index = 0; index < repeats; index += 1) {
    const started = performance.now();
    const crop = cropRgb16ToFrame(arrayBuffer, image, frame);
    const elapsed = elapsedUs(started);
    const rgb16 = new Uint16Array(crop.arrayBuffer);
    checksum = checksumU16(rgb16);
    width = crop.width;
    height = crop.height;
    samples = rgb16.length;
    times.push(elapsed);
  }
  times.sort((a, b) => a - b);
  return {
    repeats,
    width,
    height,
    samples,
    min_us: times[0],
    median_us: times[Math.floor(times.length / 2)],
    max_us: times[times.length - 1],
    checksum,
  };
}

function loadOracleFrames(scanPathValue, image) {
  const fixturePath = "test/fixtures/processing/frames/test-detect-python-output.json";
  if (fs.existsSync(fixturePath)) {
    const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf8"));
    const normalizedScanPath = normalizePath(scanPathValue);
    const match = fixture.cases.find((entry) => normalizePath(entry.scan) === normalizedScanPath);
    if (match) {
      const scale = 1.0 / match.preview_scale;
      return match.frames.map((frame) => ({
        cx: frame.cx * scale,
        cy: frame.cy * scale,
        w: frame.w * scale,
        h: frame.h * scale,
        angle: frame.angle,
      }));
    }
  }
  const width = Math.max(1, Math.floor(image.width * 0.60));
  const height = Math.max(1, Math.floor(image.height * 0.30));
  return [{
    cx: image.width / 2.0,
    cy: image.height / 2.0,
    w: width,
    h: height,
    angle: 0.03,
  }];
}

function defaultScanPath() {
  const candidates = [
    "scans/scan_0004_rgbir_3200dpi.tiff",
    "scans/scan_0003_rgbir_3200dpi.tiff",
    "scans/scan_0006_rgbir_800dpi.tiff",
    "test/fixtures/tiff/rgb-thumb-ir.tiff",
  ];
  return candidates.find((candidate) => fs.existsSync(candidate)) ?? null;
}

function variantByName(name) {
  switch (name) {
    case "ir-neg":
      return exportVariants.irNeg;
    case "ir-inv":
      return exportVariants.irInv;
    case "inv-only":
      return exportVariants.invOnly;
    default:
      throw new Error(`unknown variant: ${name}`);
  }
}

function parseArgs(args) {
  const parsed = {};
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--scan") parsed.scan = args[++index];
    else if (arg === "--max-frames") parsed.maxFrames = args[++index];
    else if (arg === "--variant") parsed.variant = args[++index];
    else if (arg === "--crop-repeats") parsed.cropRepeats = args[++index];
    else throw new Error(`unknown argument: ${arg}`);
  }
  return parsed;
}

function checksumU8(values) {
  let hash = 2166136261;
  for (let index = 0; index < values.length; index += 1) {
    hash ^= values[index];
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash >>> 0;
}

function checksumU16(values) {
  let hash = 2166136261;
  for (let index = 0; index < values.length; index += 1) {
    hash ^= values[index] & 0xff;
    hash = Math.imul(hash, 16777619) >>> 0;
    hash ^= values[index] >>> 8;
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash >>> 0;
}

function elapsedUs(started) {
  return Math.round((performance.now() - started) * 1000);
}

function timingUs(timings, stage) {
  return timings.find((timing) => timing.stage === stage)?.elapsed_us ?? null;
}

function normalizePath(value) {
  return value.replaceAll("\\", "/").replace(/^\.\//, "");
}
