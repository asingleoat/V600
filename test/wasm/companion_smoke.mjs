// Hardware-free smoke for the local scanner companion server: starts
// `v600-zig serve` against a fake scanimage (the same override pattern the
// scanner runtime tests use), then exercises the API contract in
// docs/SCANNER_COMPANION.md end to end, including parsing the finished scan
// TIFF with the browser TIFF reader.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { loadRgb16PageFromTiff } from "../../web/tiff.mjs";

const exePath = process.argv[2];
const webappDir = process.argv[3];
if (!exePath || !webappDir) {
  throw new Error("usage: node test/wasm/companion_smoke.mjs <v600-zig> <webapp-dir>");
}

const port = 8461;
const base = `http://127.0.0.1:${port}`;
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "v600-companion-smoke-"));
const scriptPath = path.join(tmpDir, "scanimage");
const outDir = path.join(tmpDir, "scans");

fs.writeFileSync(scriptPath, `#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    shift
    out="$1"
  fi
  shift
done
printf 'Progress: 50%%\\n' >&2
printf 'Progress: 100%%\\n' >&2
if [ -z "$out" ]; then
  exit 2
fi
magick -size 4x2 gradient:red-blue -type TrueColor -depth 16 -compress None "$out"
`);
fs.chmodSync(scriptPath, 0o755);

const child = spawn(exePath, [
  "serve",
  "--port", String(port),
  "--webapp-dir", webappDir,
  "--out-dir", outDir,
  "--scanimage", scriptPath,
], { stdio: ["ignore", "pipe", "inherit"] });

let stdoutBuffer = "";
const ready = new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("companion did not report ready")), 15000);
  child.stdout.on("data", (chunk) => {
    stdoutBuffer += chunk.toString();
    for (const line of stdoutBuffer.split("\n")) {
      if (line.includes("companion-ready")) {
        clearTimeout(timer);
        resolve(JSON.parse(line));
      }
    }
  });
  child.on("exit", (code) => {
    clearTimeout(timer);
    reject(new Error(`companion exited early with code ${code}`));
  });
});

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

try {
  const readyEvent = await ready;
  assert.equal(readyEvent.schema, "v600.companion.event.v1");
  assert.equal(readyEvent.service, "v600-companion");
  assert.equal(readyEvent.port, port);

  const status = await (await fetch(`${base}/api/status`)).json();
  assert.equal(status.schema, "v600.companion.api.v1");
  assert.equal(status.service, "v600-companion");
  assert.equal(status.job, null);

  const index = await fetch(`${base}/`);
  assert.equal(index.status, 200);
  assert.match(index.headers.get("content-type"), /text\/html/);
  assert.match(await index.text(), /data-tab-target="process"/);

  const appCore = await fetch(`${base}/app_core.mjs`);
  assert.equal(appCore.status, 200);
  assert.match(appCore.headers.get("content-type"), /text\/javascript/);

  const wasmResponse = await fetch(`${base}/v600-wasm-core.wasm`);
  assert.equal(wasmResponse.status, 200);
  const wasmBytes = new Uint8Array(await wasmResponse.arrayBuffer());
  assert.deepEqual(Array.from(wasmBytes.slice(0, 4)), [0x00, 0x61, 0x73, 0x6d]);

  assert.equal((await fetch(`${base}/missing-file.txt`)).status, 404);
  assert.equal((await fetch(`${base}/api/unknown`)).status, 404);

  const devices = await (await fetch(`${base}/api/devices`)).json();
  assert.equal(devices.schema, "v600.companion.api.v1");
  assert.ok(Array.isArray(devices.devices));

  const started = await (await fetch(`${base}/api/scan`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ dpi: 400, source: "flatbed", kind: "rgb+ir", device: "fake:device" }),
  })).json();
  assert.equal(started.job, 1);
  assert.equal(started.status, "running");
  assert.match(started.output, /companion_scan_0001\.tiff$/);

  const eventNames = new Set();
  let statuses = [];
  let next = 0;
  let terminal = null;
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const page = await (await fetch(`${base}/api/scan/1/events?from=${next}`)).json();
    assert.equal(page.schema, "v600.companion.api.v1");
    assert.equal(page.job, 1);
    for (const event of page.events) {
      eventNames.add(event.event);
      if (event.event === "companion-status") statuses.push(event.status);
    }
    next = page.next;
    if (page.status !== "running") {
      terminal = page.status;
      break;
    }
    await sleep(150);
  }
  assert.equal(terminal, "complete", `scan job ended ${terminal}; events: ${[...eventNames].join(",")}`);
  assert.ok(eventNames.has("companion-status"));
  assert.ok(eventNames.has("scan-start"), `missing scan-start in ${[...eventNames].join(",")}`);
  assert.ok(eventNames.has("progress"));
  assert.ok(eventNames.has("scan-complete"));
  assert.deepEqual(statuses, ["running", "complete"]);

  assert.equal((await fetch(`${base}/api/scan/999/events`)).status, 404);
  assert.equal((await fetch(`${base}/api/scan/1/cancel`, { method: "POST" })).status, 409);

  const fileResponse = await fetch(`${base}/api/scan/1/file`);
  assert.equal(fileResponse.status, 200);
  assert.match(fileResponse.headers.get("content-type"), /image\/tiff/);
  const tiffBytes = await fileResponse.arrayBuffer();
  const rgbPage = loadRgb16PageFromTiff(tiffBytes);
  assert.ok(rgbPage.width > 0 && rgbPage.height > 0);
  assert.equal(rgbPage.data.length, rgbPage.width * rgbPage.height * 3);

  const metadataResponse = await fetch(`${base}/api/scan/1/metadata`);
  assert.equal(metadataResponse.status, 200);
  const metadata = await metadataResponse.json();
  assert.equal(typeof metadata, "object");

  const secondStatus = await (await fetch(`${base}/api/status`)).json();
  assert.equal(secondStatus.job.id, 1);
  assert.equal(secondStatus.job.status, "complete");

  console.log(JSON.stringify({
    event: "companion-smoke",
    schema: "v600.webapp.event.v1",
    job_status: terminal,
    event_names: [...eventNames].sort(),
    rgb_width: rgbPage.width,
    rgb_height: rgbPage.height,
    status: "ok",
  }));
} finally {
  child.kill("SIGTERM");
  fs.rmSync(tmpDir, { recursive: true, force: true });
}
