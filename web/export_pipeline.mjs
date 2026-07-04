// Native-variant export orchestration: variant tables, filenames, metadata
// sidecars, and the multi-frame multi-variant export loop.

import { sanitizeStem } from "./util.mjs";
import { defaultDustRemovalConfig, defaultRenderConfig, stockIds, stockName } from "./config.mjs";
import { cropRgb16ToFrame, parseRawRgb16Buffer } from "./geometry.mjs";
import { buildPreviewCacheInput, exportCacheKey } from "./cache_inputs.mjs";

export const exportVariants = Object.freeze({
  irNeg: Object.freeze({
    id: "ir_neg",
    suffix: "_ir",
    metadata_variant: "ir_cleaned",
    needs_ir: true,
    needs_invert: false,
  }),
  irInv: Object.freeze({
    id: "ir_inv",
    suffix: "",
    metadata_variant: "ir_cleaned_inverted",
    needs_ir: true,
    needs_invert: true,
  }),
  invOnly: Object.freeze({
    id: "inv_only",
    suffix: "_inv",
    metadata_variant: "inverted",
    needs_ir: false,
    needs_invert: true,
  }),
});

export const nativeExportVariantOrder = Object.freeze([
  exportVariants.irNeg,
  exportVariants.irInv,
  exportVariants.invOnly,
]);

export function defaultOutputSelection(overrides = {}) {
  return {
    ir_neg: false,
    ir_inv: true,
    inv_only: false,
    ...overrides,
  };
}

export function enabledExportVariants(selection = defaultOutputSelection()) {
  return nativeExportVariantOrder.filter((variant) => Boolean(selection[variant.id]));
}

export async function exportRawNegativeRgb16({
  arrayBuffer,
  file,
  image,
  stockId = stockIds.kodakGold,
  render = defaultRenderConfig(),
  dmin = [0.05, 0.06, 0.07],
  percentileSampleLimit = 16384,
  frameSelection = null,
  variant = exportVariants.irNeg,
}) {
  const started = performance.now();
  parseRawRgb16Buffer(arrayBuffer, image);
  const cropped = cropRgb16ToFrame(arrayBuffer, image, frameSelection);
  const stock = stockName(stockId);
  const cacheInput = buildPreviewCacheInput({
    file,
    image,
    stock,
    stockId,
    render,
    dmin,
    frameSelection: cropped.frame,
    preview: {
      max_px: cropped.width * cropped.height,
      output_width: cropped.width,
      output_height: cropped.height,
      percentile_sample_limit: percentileSampleLimit,
    },
    output: {
      kind: "rgb16-negative-export",
      color_space: "scanner-rgb",
      variant: variant.id,
    },
  });
  return {
    cacheKey: await exportCacheKey(cacheInput),
    rgb16: new Uint16Array(cropped.arrayBuffer),
    width: cropped.width,
    height: cropped.height,
    frame: cropped.frame,
    timings: [
      {
        stage: "browser.raw-negative-export",
        elapsed_us: Math.round((performance.now() - started) * 1000),
      },
    ],
  };
}

export async function exportNativeVariantResults({
  client,
  arrayBuffer,
  irBuffer = null,
  irSampleFormat = "u8",
  file,
  image,
  stockId = stockIds.kodakGold,
  render = defaultRenderConfig(),
  dmin = [0.05, 0.06, 0.07],
  percentileSampleLimit = 16384,
  frameSelections = [null],
  variants = enabledExportVariants(defaultOutputSelection()),
  dustRemoval = defaultDustRemovalConfig(),
  transferInput = false,
}) {
  const exported = [];
  const canTransferInput = transferInput && frameSelections.length * variants.length === 1;
  for (let frameIndex = 0; frameIndex < frameSelections.length; frameIndex += 1) {
    const frameSelection = frameSelections[frameIndex];
    for (const variant of variants) {
      const result = variant.needs_ir && irBuffer
        ? await client.exportIrCleanedRgb16({
          arrayBuffer,
          irBuffer,
          irSampleFormat,
          file,
          image,
          stockId,
          render,
          dmin,
          percentileSampleLimit,
          frameSelection,
          variant,
          dustRemoval,
        })
        : variant.needs_invert
        ? await client.exportRawRgb16({
          arrayBuffer,
          file,
          image,
          stockId,
          render,
          dmin,
          percentileSampleLimit,
          frameSelection,
          variant,
          transferInput: canTransferInput,
        })
        : await exportRawNegativeRgb16({
          arrayBuffer,
          file,
          image,
          stockId,
          render,
          dmin,
          percentileSampleLimit,
          frameSelection,
          variant,
        });
      const metadata = buildNativeVariantExportMetadata({
        file,
        image,
        frame: result.frame,
        variant,
        stockId,
        render,
        dmin,
        cacheKey: result.cacheKey,
        output: {
          kind: "rgb16-export",
          format: "tiff",
          color_space: variant.needs_invert ? "srgb" : "scanner-rgb",
          bit_depth: 16,
          width: result.width,
          height: result.height,
        },
        timings: result.timings,
        irCleaning: variant.needs_ir && irBuffer ? result.mode ?? "browser-ir-cleaned" : "browser-no-ir-fallback",
      });
      exported.push({
        frameIndex,
        variant,
        result,
        metadata,
        filename: nativeExportFilename({ sourceName: file.name, frameIndex, variant }),
        metadataFilename: nativeExportMetadataFilename({ sourceName: file.name, frameIndex, variant }),
      });
    }
  }
  return exported;
}

export function nativeExportFilename({ sourceName, frameIndex = 0, variant }) {
  const sourceStem = sanitizeStem(sourceName.replace(/\.[^.]*$/, "")) || "scan";
  return `${sourceStem}_${String(frameIndex + 1).padStart(2, "0")}${variant.suffix}.tif`;
}

export function nativeExportMetadataFilename({ sourceName, frameIndex = 0, variant }) {
  return `${nativeExportFilename({ sourceName, frameIndex, variant })}.json`;
}

export function buildNativeVariantExportMetadata({
  file,
  image,
  frame,
  variant,
  stockId,
  render,
  dmin,
  cacheKey,
  output,
  timings = [],
  irCleaning = "browser-no-ir-fallback",
}) {
  const metadata = {
    schema: "v600.webapp.native-export-metadata.v1",
    source: file.name,
    source_file: file,
    source_image: {
      width: image.width,
      height: image.height,
      dpi: image.dpi ?? null,
      channels: 3,
      bit_depth: 16,
      page_layout: image.page_layout ?? "rgb",
      ir: image.ir ?? null,
    },
    rebate_rect: null,
    crop: {
      cx: frame.cx,
      cy: frame.cy,
      w: frame.w,
      h: frame.h,
      angle: frame.angle,
    },
    frame,
    variant: variant.metadata_variant,
    output: {
      kind: output.kind,
      format: output.format,
      color_space: output.color_space,
      bit_depth: output.bit_depth,
      width: output.width,
      height: output.height,
    },
    cache_key: cacheKey,
    timings,
    browser_notes: {
      ir_cleaning: irCleaning,
    },
  };
  if (variant.id !== exportVariants.irNeg.id) {
    metadata.stock = stockName(stockId);
    metadata.contrast = render.contrast;
    metadata.dmin = dmin;
  }
  return metadata;
}

export function metadataJsonBytes(metadata) {
  return new TextEncoder().encode(`${JSON.stringify(metadata, null, 2)}\n`);
}
