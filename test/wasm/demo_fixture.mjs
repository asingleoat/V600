// Shared 2x2 RGB16 demo fixture for the browser shell smoke. The expected
// preview bytes pin the kodak_gold default render of this exact input, the
// same oracle values duplicated locally by wasm_core_smoke.mjs and
// worker_runtime_smoke.mjs.
export const rawFixture = new Uint16Array([
  51000, 42000, 35000,
  45000, 39000, 31000,
  39000, 33000, 26000,
  33000, 27000, 21000,
]);

export const expectedDemoPreview = new Uint8Array([
  0, 5, 141,
  18, 39, 222,
  122, 133, 255,
  242, 243, 255,
]);

export function demoRawRgb16Buffer() {
  return rawFixture.buffer.slice(rawFixture.byteOffset, rawFixture.byteOffset + rawFixture.byteLength);
}
