import fs from "node:fs";
import { Worker } from "node:worker_threads";

import { fileIdentity, WebPreviewClient } from "../../web/app_core.mjs";
import { loadIrPageFromTiff, loadRgb16PageFromTiff } from "../../web/tiff.mjs";

const wasmPath = process.argv[2];
const scanPath = process.argv[3];
if (!wasmPath || !scanPath) {
  throw new Error("usage: node test/wasm/real_scan_ir_estimate_probe.mjs <v600-wasm-core.wasm> <scan.tiff>");
}

const bytes = fs.readFileSync(scanPath);
const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
const rgbPage = loadRgb16PageFromTiff(buffer);
const irPage = loadIrPageFromTiff(buffer);
if (!irPage) throw new Error("scan does not contain an 8-bit IR page");

const rgbF32 = new Float32Array(rgbPage.data.length);
for (let index = 0; index < rgbPage.data.length; index += 1) rgbF32[index] = rgbPage.data[index];
const irF32 = new Float32Array(irPage.data.length);
for (let index = 0; index < irPage.data.length; index += 1) irF32[index] = irPage.data[index];

const file = await fileIdentity({
  name: scanPath.split("/").pop(),
  size: buffer.byteLength,
  lastModified: 0,
  arrayBuffer: buffer,
});
const image = {
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

const worker = new Worker(new URL("../../web/worker/processor.mjs", import.meta.url), {
  type: "module",
});
const client = new WebPreviewClient({ worker, wasmUrl: wasmPath, timeoutMs: 30000 });

try {
  await client.loadModule();
  const started = performance.now();
  const result = await client.estimateIrTranslationF32({
    rgbBuffer: rgbF32.buffer,
    irBuffer: irF32.buffer,
    file,
    image,
  });
  console.log(JSON.stringify({
    event: "real-scan-ir-estimate-probe",
    schema: "v600.webapp.event.v1",
    scan: scanPath,
    rgb: { width: rgbPage.width, height: rgbPage.height },
    ir: { width: irPage.width, height: irPage.height },
    elapsed_us: Math.round((performance.now() - started) * 1000),
    alignment: result.alignment,
    timings: result.timings,
    status: "ok",
  }));
} finally {
  await client.close();
}
