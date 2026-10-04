const tag = Object.freeze({
  imageWidth: 256,
  imageLength: 257,
  bitsPerSample: 258,
  compression: 259,
  photometric: 262,
  stripOffsets: 273,
  samplesPerPixel: 277,
  rowsPerStrip: 278,
  stripByteCounts: 279,
  xResolution: 282,
  yResolution: 283,
  planarConfiguration: 284,
  resolutionUnit: 296,
  software: 305,
  scannerLut: 50001,
});

const scannerLutLength = 768;

const typeSize = Object.freeze({
  1: 1,
  2: 1,
  3: 2,
  4: 4,
  5: 8,
});

export function loadTiffPages(arrayBuffer) {
  const view = new DataView(arrayBuffer);
  const byteOrder = String.fromCharCode(view.getUint8(0), view.getUint8(1));
  const littleEndian = byteOrder === "II";
  if (!littleEndian && byteOrder !== "MM") throw new Error("unsupported TIFF byte order");
  if (view.getUint16(2, littleEndian) !== 42) throw new Error("unsupported TIFF version");

  const pages = [];
  let ifdOffset = view.getUint32(4, littleEndian);
  while (ifdOffset !== 0) {
    const parsed = readIfd(view, ifdOffset, littleEndian);
    pages.push(pageFromTags(view, parsed.tags, littleEndian, pages.length));
    ifdOffset = parsed.nextIfdOffset;
  }
  return pages;
}

export function loadRgb16PageFromTiff(arrayBuffer) {
  const page = loadTiffPages(arrayBuffer).find((candidate) => {
    return candidate.samplesPerPixel === 3 &&
      candidate.bitsPerSample.every((bits) => bits === 16) &&
      candidate.photometric === 2;
  });
  if (!page) throw new Error("TIFF does not contain an uncompressed RGB16 page");
  return {
    width: page.width,
    height: page.height,
    dpi: page.dpi,
    data: page.u16Data,
  };
}

export function loadIrPageFromTiff(arrayBuffer) {
  const page = loadTiffPages(arrayBuffer).find((candidate) => {
    return candidate.samplesPerPixel === 1 &&
      candidate.bitsPerSample.length === 1 &&
      candidate.bitsPerSample[0] === 8 &&
      candidate.photometric === 1;
  });
  if (!page) return null;
  return {
    width: page.width,
    height: page.height,
    data: page.u8Data,
  };
}

export function rgb16ToTiffBytes(rgb16, width, height, { dpi = 800, software = "CerealGrain web" } = {}) {
  if (!Number.isInteger(width) || width <= 0) throw new Error("TIFF width must be a positive integer");
  if (!Number.isInteger(height) || height <= 0) throw new Error("TIFF height must be a positive integer");
  if (rgb16.length !== width * height * 3) throw new Error("RGB16 data length does not match TIFF dimensions");
  const normalizedDpi = Number.isFinite(dpi) && dpi > 0 ? Math.round(dpi) : 800;
  const softwareBytes = asciiBytes(`${software}\0`);
  const entryCount = 14;
  const ifdOffset = 8;
  const ifdSize = 2 + entryCount * 12 + 4;
  const bitsOffset = ifdOffset + ifdSize;
  const xResolutionOffset = align2(bitsOffset + 6);
  const yResolutionOffset = align2(xResolutionOffset + 8);
  const softwareOffset = align2(yResolutionOffset + 8);
  const pixelOffset = align2(softwareOffset + softwareBytes.length);
  const pixelByteCount = rgb16.length * 2;
  const bytes = new Uint8Array(pixelOffset + pixelByteCount);
  const view = new DataView(bytes.buffer);

  bytes[0] = 0x49;
  bytes[1] = 0x49;
  view.setUint16(2, 42, true);
  view.setUint32(4, ifdOffset, true);
  view.setUint16(ifdOffset, entryCount, true);

  const entries = [
    [tag.imageWidth, 4, 1, width],
    [tag.imageLength, 4, 1, height],
    [tag.bitsPerSample, 3, 3, bitsOffset],
    [tag.compression, 3, 1, 1],
    [tag.photometric, 3, 1, 2],
    [tag.stripOffsets, 4, 1, pixelOffset],
    [tag.samplesPerPixel, 3, 1, 3],
    [tag.rowsPerStrip, 4, 1, height],
    [tag.stripByteCounts, 4, 1, pixelByteCount],
    [tag.xResolution, 5, 1, xResolutionOffset],
    [tag.yResolution, 5, 1, yResolutionOffset],
    [tag.planarConfiguration, 3, 1, 1],
    [tag.resolutionUnit, 3, 1, 2],
    [tag.software, 2, softwareBytes.length, softwareOffset],
  ];
  entries.sort((a, b) => a[0] - b[0]);
  for (let index = 0; index < entries.length; index += 1) {
    writeIfdEntry(view, ifdOffset + 2 + index * 12, entries[index]);
  }
  view.setUint32(ifdOffset + 2 + entryCount * 12, 0, true);

  view.setUint16(bitsOffset, 16, true);
  view.setUint16(bitsOffset + 2, 16, true);
  view.setUint16(bitsOffset + 4, 16, true);
  writeRational(view, xResolutionOffset, normalizedDpi, 1);
  writeRational(view, yResolutionOffset, normalizedDpi, 1);
  bytes.set(softwareBytes, softwareOffset);
  for (let index = 0; index < rgb16.length; index += 1) {
    view.setUint16(pixelOffset + index * 2, rgb16[index], true);
  }
  return bytes;
}

function readIfd(view, offset, littleEndian) {
  const count = view.getUint16(offset, littleEndian);
  const tags = new Map();
  for (let index = 0; index < count; index += 1) {
    const entryOffset = offset + 2 + index * 12;
    const id = view.getUint16(entryOffset, littleEndian);
    const type = view.getUint16(entryOffset + 2, littleEndian);
    const valueCount = view.getUint32(entryOffset + 4, littleEndian);
    const byteCount = checkedByteCount(type, valueCount);
    const valueOffset = byteCount <= 4 ? entryOffset + 8 : view.getUint32(entryOffset + 8, littleEndian);
    tags.set(id, readValue(view, valueOffset, type, valueCount, littleEndian));
  }
  const nextIfdOffset = view.getUint32(offset + 2 + count * 12, littleEndian);
  return { tags, nextIfdOffset };
}

function pageFromTags(view, tags, littleEndian, index) {
  const width = requiredNumber(tags, tag.imageWidth, `page ${index} width`);
  const height = requiredNumber(tags, tag.imageLength, `page ${index} height`);
  const samplesPerPixel = numberOrDefault(tags, tag.samplesPerPixel, 1);
  const bitsPerSample = arrayValue(tags.get(tag.bitsPerSample) ?? 1);
  const compression = numberOrDefault(tags, tag.compression, 1);
  const photometric = requiredNumber(tags, tag.photometric, `page ${index} photometric`);
  const planarConfiguration = numberOrDefault(tags, tag.planarConfiguration, 1);
  if (compression !== 1) throw new Error(`unsupported TIFF compression on page ${index}`);
  if (planarConfiguration !== 1) throw new Error(`unsupported planar TIFF page ${index}`);

  const stripOffsets = arrayValue(tags.get(tag.stripOffsets));
  const stripByteCounts = arrayValue(tags.get(tag.stripByteCounts));
  if (stripOffsets.length !== stripByteCounts.length) throw new Error(`mismatched TIFF strip tags on page ${index}`);
  const bytes = readStrips(view, stripOffsets, stripByteCounts);
  const page = {
    index,
    width,
    height,
    samplesPerPixel,
    bitsPerSample,
    compression,
    photometric,
    dpi: readDpi(tags),
    byteData: bytes,
    u16Data: null,
    u8Data: null,
  };
  if (bitsPerSample.every((bits) => bits === 16)) page.u16Data = bytesToU16(bytes, littleEndian);
  if (bitsPerSample.every((bits) => bits === 8)) page.u8Data = bytes;
  const scannerLut = tags.get(tag.scannerLut);
  if (page.u16Data && samplesPerPixel === 3 && Array.isArray(scannerLut) && scannerLut.length === scannerLutLength) {
    linearizeRgb16(page.u16Data, scannerLut);
  }
  return page;
}

// Maps RGB16 samples scanned through a scanner gamma LUT (tag 50001) back to
// values proportional to the sensor signal, in place. Mirrors
// `linearizeRgb16` in src/tiff.zig: knot k sits at sensor value 256k and
// output 257 * lut[k], linear between knots, and each channel is scaled so
// the LUT's white point is 65535.
export function linearizeRgb16(samples, lut) {
  const tables = [0, 1, 2].map((channel) => inverseLutTable(lut.slice(channel * 256, channel * 256 + 256)));
  for (let index = 0; index < samples.length; index += 1) {
    const table = tables[index % 3];
    if (table) samples[index] = table[samples[index]];
  }
}

function inverseLutTable(lut) {
  for (let knot = 1; knot < 256; knot += 1) {
    if (lut[knot] < lut[knot - 1]) return null;
  }
  let black = 0;
  while (black < 255 && lut[black + 1] === lut[black]) black += 1;
  let white = 255;
  while (white > 0 && lut[white - 1] === lut[white]) white -= 1;
  if (white <= black) return null;

  const scale = 65535 / (white * 256);
  const table = new Uint16Array(65536);
  const blackOut = lut[black] * 257;
  const whiteOut = lut[white] * 257;
  table.fill(Math.round(black * 256 * scale), 0, blackOut + 1);
  table.fill(65535, whiteOut);
  for (let knot = black; knot < white; knot += 1) {
    const out0 = lut[knot] * 257;
    const out1 = lut[knot + 1] * 257;
    if (out1 === out0) continue;
    for (let y = out0; y <= out1; y += 1) {
      const sensor = knot * 256 + (y - out0) * 256 / (out1 - out0);
      table[y] = Math.min(65535, Math.round(sensor * scale));
    }
  }
  return table;
}

function readValue(view, offset, type, count, littleEndian) {
  if (type === 2) {
    const chars = [];
    for (let i = 0; i < count; i += 1) {
      const byte = view.getUint8(offset + i);
      if (byte === 0) break;
      chars.push(String.fromCharCode(byte));
    }
    return chars.join("");
  }

  const values = [];
  for (let i = 0; i < count; i += 1) {
    const cursor = offset + i * typeSize[type];
    switch (type) {
      case 1:
        values.push(view.getUint8(cursor));
        break;
      case 3:
        values.push(view.getUint16(cursor, littleEndian));
        break;
      case 4:
        values.push(view.getUint32(cursor, littleEndian));
        break;
      case 5: {
        const numerator = view.getUint32(cursor, littleEndian);
        const denominator = view.getUint32(cursor + 4, littleEndian);
        values.push(denominator === 0 ? null : numerator / denominator);
        break;
      }
      default:
        throw new Error(`unsupported TIFF tag type ${type}`);
    }
  }
  return count === 1 ? values[0] : values;
}

function readStrips(view, offsets, byteCounts) {
  const total = byteCounts.reduce((sum, count) => sum + count, 0);
  const out = new Uint8Array(total);
  let cursor = 0;
  for (let i = 0; i < offsets.length; i += 1) {
    out.set(new Uint8Array(view.buffer, offsets[i], byteCounts[i]), cursor);
    cursor += byteCounts[i];
  }
  return out;
}

function bytesToU16(bytes, littleEndian) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const out = new Uint16Array(bytes.byteLength / 2);
  for (let i = 0; i < out.length; i += 1) {
    out[i] = view.getUint16(i * 2, littleEndian);
  }
  return out;
}

function checkedByteCount(type, count) {
  if (!(type in typeSize)) throw new Error(`unsupported TIFF tag type ${type}`);
  return typeSize[type] * count;
}

function readDpi(tags) {
  const unit = numberOrDefault(tags, tag.resolutionUnit, 2);
  const xResolution = tags.get(tag.xResolution);
  if (unit !== 2 || typeof xResolution !== "number") return null;
  return Math.round(xResolution);
}

function requiredNumber(tags, id, label) {
  const value = tags.get(id);
  if (typeof value !== "number") throw new Error(`missing TIFF ${label}`);
  return value;
}

function numberOrDefault(tags, id, fallback) {
  const value = tags.get(id);
  return typeof value === "number" ? value : fallback;
}

function arrayValue(value) {
  return Array.isArray(value) ? value : [value];
}

function writeIfdEntry(view, offset, [id, type, count, value]) {
  view.setUint16(offset, id, true);
  view.setUint16(offset + 2, type, true);
  view.setUint32(offset + 4, count, true);
  const byteCount = checkedByteCount(type, count);
  if (byteCount > 4) {
    view.setUint32(offset + 8, value, true);
  } else if (type === 3) {
    view.setUint16(offset + 8, value, true);
  } else {
    view.setUint32(offset + 8, value, true);
  }
}

function writeRational(view, offset, numerator, denominator) {
  view.setUint32(offset, numerator, true);
  view.setUint32(offset + 4, denominator, true);
}

function asciiBytes(value) {
  const bytes = new Uint8Array(value.length);
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code > 127) throw new Error("TIFF ASCII tags must be ASCII");
    bytes[index] = code;
  }
  return bytes;
}

function align2(value) {
  return value + (value % 2);
}
