// Shared leaf helpers for the browser app modules: hashing, numeric
// clamping/rounding, and runtime detection.

export async function sha256ArrayBuffer(arrayBuffer) {
  return `sha256:${toHex(await digestSha256(arrayBuffer))}`;
}

export async function sha256Text(text) {
  return `sha256:${toHex(await digestSha256(new TextEncoder().encode(text)))}`;
}

export async function digestSha256(bytes) {
  if (globalThis.crypto?.subtle) {
    return new Uint8Array(await globalThis.crypto.subtle.digest("SHA-256", bytes));
  }
  if (isNodeRuntime()) {
    const { createHash } = await import("node:crypto");
    return createHash("sha256").update(bytes).digest();
  }
  throw new Error("SHA-256 is unavailable in this browser");
}

export function toHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function positiveInteger(value, label) {
  if (!Number.isInteger(value) || value <= 0) throw new Error(`${label} must be a positive integer`);
  return value;
}

export function scalarArrayType(sampleFormat) {
  switch (sampleFormat) {
    case "u8":
      return Uint8Array;
    case "u16":
      return Uint16Array;
    case "f32":
      return Float32Array;
    default:
      throw new Error(`unsupported scalar sample format: ${sampleFormat}`);
  }
}

export function clampInt(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

export function reflectIndex(index, length) {
  if (length <= 1) return 0;
  let reflected = index;
  while (reflected < 0 || reflected >= length) {
    if (reflected < 0) {
      reflected = -reflected - 1;
    } else {
      reflected = 2 * length - reflected - 1;
    }
  }
  return reflected;
}

export function roundToU8(value) {
  if (!Number.isFinite(value) || value <= 0.0) return 0;
  if (value >= 255.0) return 255;
  return Math.round(value);
}

export function roundToU16(value) {
  if (!Number.isFinite(value) || value <= 0.0) return 0;
  if (value >= 65535.0) return 65535;
  return Math.round(value);
}

export function sanitizeStem(value) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 96);
}

export function isNodeRuntime() {
  return typeof process !== "undefined" && !!process.versions?.node;
}

// True when the runtime accepts 64-bit tables and memories (Wasm memory64),
// which the wasm64 processing core needs.
export function supportsWasm64() {
  return WebAssembly.validate(new Uint8Array([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // header
    0x04, 0x04, 0x01, 0x70, 0x04, 0x00, // table section: one funcref table, i64 limits, min 0
    0x05, 0x03, 0x01, 0x04, 0x00, // memory section: one memory, i64 limits, min 0
  ]));
}
