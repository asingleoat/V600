import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";

const root = process.argv[2];
if (!root) throw new Error("usage: node test/wasm/webapp_static_smoke.mjs <webapp-dir>");

const requiredPaths = [
  "index.html",
  "styles.css",
  "app.mjs",
  "app_core.mjs",
  "util.mjs",
  "config.mjs",
  "geometry.mjs",
  "cache_inputs.mjs",
  "export_pipeline.mjs",
  "preview_client.mjs",
  "tiff.mjs",
  "worker/processor.mjs",
  "worker/protocol.mjs",
  "worker/wasm_abi.mjs",
  "v600-wasm-core.wasm",
];

for (const relative of requiredPaths) {
  const stat = await fs.stat(path.join(root, relative));
  assert.equal(stat.isFile(), true, `${relative} is not a file`);
  assert.ok(stat.size > 0, `${relative} is empty`);
}

const index = await fs.readFile(path.join(root, "index.html"), "utf8");
assert.match(index, /src="\.\/app\.mjs"/);
assert.match(index, /data-tab-target="scan"/);
assert.match(index, /data-tab-target="process"/);
assert.match(index, /data-tab-target="gallery"/);
assert.match(index, /id="auto-detect"/);
assert.match(index, /id="update-preview"/);
assert.match(index, /id="export-selected"/);
assert.match(index, /id="frame-overlay"/);
assert.doesNotMatch(index, /wasm-url/);
assert.doesNotMatch(index, /id="sample"/);
assert.doesNotMatch(index, /id="frame-full"/);
assert.doesNotMatch(index, /id="download"/);
assert.doesNotMatch(index, /id="export-rgb16"/);
assert.doesNotMatch(index, />Sample<\/button>/);
assert.doesNotMatch(index, />Full Frame<\/button>/);
assert.doesNotMatch(index, />Download<\/button>/);
assert.doesNotMatch(index, />Export RGB16<\/button>/);

const app = await fs.readFile(path.join(root, "app.mjs"), "utf8");
assert.match(app, /new URL\("\.\/v600-wasm-core\.wasm", import\.meta\.url\)\.href/);
assert.match(app, /refreshFrameOverlay/);
assert.match(app, /applyDetectedRebate/);
assert.match(app, /computeDminFromRgb16/);
assert.match(app, /function currentPreviewFrameSelection\(image\)\s*\{\s*return defaultFrameSelection\(image\);/s);
assert.doesNotMatch(app, /querySelector\("#wasm-url"\)/);
assert.doesNotMatch(app, /demoRawRgb16Buffer/);

const styles = await fs.readFile(path.join(root, "styles.css"), "utf8");
assert.match(styles, /\.control-panel\s*\{[^}]*flex-wrap:\s*wrap/s);
assert.match(styles, /\.frame-overlay/);
assert.match(styles, /\.frame-box/);
assert.match(styles, /\.rebate-box/);

const worker = await fs.readFile(path.join(root, "worker/processor.mjs"), "utf8");
assert.match(worker, /createWasmAbi/);
assert.doesNotMatch(worker, /v600_wasm_alloc\(len\)\s*>>>\s*0/);

const wasmAbi = await fs.readFile(path.join(root, "worker/wasm_abi.mjs"), "utf8");
assert.match(wasmAbi, /v600_wasm_pointer_bits/);
assert.match(wasmAbi, /pointerBits === 64 \? BigInt\(value\) : value/);
assert.doesNotMatch(wasmAbi, /v600_wasm_alloc\(len\)\s*>>>\s*0/);
assert.match(wasmAbi, /exceeds memory size/);

const server = http.createServer(async (request, response) => {
  try {
    const requestUrl = new URL(request.url ?? "/", "http://127.0.0.1");
    const cleanPath = requestUrl.pathname === "/" ? "/index.html" : requestUrl.pathname;
    const relative = cleanPath.replace(/^\/+/, "");
    if (relative.includes("..")) {
      response.writeHead(400);
      response.end("bad path");
      return;
    }
    const filePath = path.join(root, relative);
    const body = await fs.readFile(filePath);
    response.writeHead(200, { "content-type": contentType(relative) });
    response.end(body);
  } catch {
    response.writeHead(404);
    response.end("not found");
  }
});

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
try {
  const address = server.address();
  const baseUrl = `http://127.0.0.1:${address.port}`;
  for (const relative of requiredPaths) {
    const response = await fetch(`${baseUrl}/${relative}`);
    assert.equal(response.status, 200, `${relative} was not served`);
    const bytes = new Uint8Array(await response.arrayBuffer());
    assert.ok(bytes.length > 0, `${relative} served empty response`);
    if (relative.endsWith(".wasm")) {
      assert.deepEqual(Array.from(bytes.slice(0, 4)), [0x00, 0x61, 0x73, 0x6d]);
    }
  }

  console.log(JSON.stringify({
    event: "webapp-static-smoke",
    schema: "v600.webapp.event.v1",
    files: requiredPaths.length,
    status: "ok",
  }));
} finally {
  await new Promise((resolve) => server.close(resolve));
}

function contentType(relative) {
  if (relative.endsWith(".html")) return "text/html";
  if (relative.endsWith(".css")) return "text/css";
  if (relative.endsWith(".mjs")) return "text/javascript";
  if (relative.endsWith(".wasm")) return "application/wasm";
  return "application/octet-stream";
}
