import assert from "node:assert/strict";
import fs from "node:fs";

import {
  loadIrPageFromTiff,
  loadRgb16PageFromTiff,
  loadTiffPages,
  rgb16ToTiffBytes,
} from "../../web/tiff.mjs";

const fixturePath = "test/fixtures/tiff/rgb-thumb-ir.tiff";
const oracle = JSON.parse(fs.readFileSync("test/fixtures/tiff/rgb-thumb-ir.json", "utf8")).python_oracle;
const bytes = fs.readFileSync(fixturePath);
const arrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);

const pages = loadTiffPages(arrayBuffer);
assert.equal(pages.length, oracle.page_count);
assert.equal(pages[0].width, oracle.rgb_shape[1]);
assert.equal(pages[0].height, oracle.rgb_shape[0]);
assert.equal(pages[0].samplesPerPixel, 3);
assert.deepEqual(pages[0].bitsPerSample, [16, 16, 16]);
assert.equal(pages[0].dpi, oracle.dpi);

const rgb = loadRgb16PageFromTiff(arrayBuffer);
assert.equal(rgb.width, oracle.rgb_shape[1]);
assert.equal(rgb.height, oracle.rgb_shape[0]);
assert.equal(rgb.dpi, oracle.dpi);
assert.deepEqual(Array.from(rgb.data), oracle.rgb_values);

const ir = loadIrPageFromTiff(arrayBuffer);
assert.equal(ir.width, oracle.ir_shape[1]);
assert.equal(ir.height, oracle.ir_shape[0]);
assert.deepEqual(Array.from(ir.data), oracle.ir_values);

const roundTripBytes = rgb16ToTiffBytes(rgb.data, rgb.width, rgb.height, { dpi: rgb.dpi });
const roundTrip = loadRgb16PageFromTiff(
  roundTripBytes.buffer.slice(roundTripBytes.byteOffset, roundTripBytes.byteOffset + roundTripBytes.byteLength),
);
assert.equal(roundTrip.width, rgb.width);
assert.equal(roundTrip.height, rgb.height);
assert.equal(roundTrip.dpi, rgb.dpi);
assert.deepEqual(Array.from(roundTrip.data), Array.from(rgb.data));

console.log(JSON.stringify({
  event: "tiff-reader-smoke",
  schema: "v600.webapp.event.v1",
  fixture: fixturePath,
  pages: pages.length,
  rgb_samples: rgb.data.length,
  ir_samples: ir.data.length,
  dpi: rgb.dpi,
  status: "ok",
}));
