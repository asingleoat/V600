// WebPreviewClient: the browser-side worker RPC client used by the app shell
// and the headless smokes.

import { scalarArrayType, sha256ArrayBuffer } from "./util.mjs";
import { defaultDustRemovalConfig, defaultFrameDetectConfig, defaultFrameDetectOptions, defaultIrAlignOptions, defaultIrEstimateConfig, defaultIrEstimateOptions, defaultIrInpaintGrainOptions, defaultIrMaskOptions, defaultIrMaskResizeOptions, defaultPreviewOptions, defaultRenderConfig, stockIds, stockName } from "./config.mjs";
import { frameCropGeometry, normalizeFrameSelection, parseRawRgb16Buffer, previewOutputGeometry, randomNoiseSeed, scalarArrayBufferToF32 } from "./geometry.mjs";
import { buildFrameDetectCacheInput, buildIrAlignCacheInput, buildIrCleanCropCacheInput, buildIrEstimateCacheInput, buildIrInpaintCacheInput, buildIrMaskCacheInput, buildIrRgbMaskCacheInput, buildPreviewCacheInput, exportCacheKey, fileIdentity, frameDetectCacheKey, irAlignCacheKey, irCleanCropCacheKey, irEstimateCacheKey, irInpaintCacheKey, irMaskCacheKey, irRgbMaskCacheKey, previewCacheKey } from "./cache_inputs.mjs";
import { exportVariants } from "./export_pipeline.mjs";
import { createLoadModuleMessage, createProcessMessage, messageTypes } from "./worker/protocol.mjs";

export class WebPreviewClient {
  constructor({ worker, wasmUrl, timeoutMs = 5000 }) {
    this.worker = worker;
    this.wasmUrl = wasmUrl;
    this.timeoutMs = timeoutMs;
    this.sequence = 0;
    this.loadPromise = null;
    this.loaded = false;
    this.readyMessage = null;
  }

  async loadModule() {
    if (this.loaded) return this.readyMessage;
    if (this.loadPromise) return this.loadPromise;
    const requestId = this.nextRequestId("load");
    const ready = this.waitFor((message) => {
      return message.request_id === requestId && (
        message.type === messageTypes.ready ||
        message.type === messageTypes.error
      );
    });
    this.post(createLoadModuleMessage({
      requestId,
      wasmUrl: this.wasmUrl,
      wasmSha256: null,
    }));
    this.loadPromise = ready.then((message) => {
      if (message.type === messageTypes.error) {
        throw new Error(`worker load failed: ${message.message}`);
      }
      this.loaded = true;
      this.readyMessage = message;
      return message;
    }, (err) => {
      this.loadPromise = null;
      throw err;
    });
    return this.loadPromise;
  }

  async detectFramesRgb16({
    arrayBuffer,
    file,
    image,
    detection = defaultFrameDetectConfig(),
    maxFrames = 32,
  }) {
    await this.loadModule();
    parseRawRgb16Buffer(arrayBuffer, image);
    const normalizedDetection = defaultFrameDetectConfig(detection);
    const cacheInput = buildFrameDetectCacheInput({
      file,
      image,
      detection: normalizedDetection,
    });
    const cacheKey = await frameDetectCacheKey(cacheInput);
    const rawBuffer = arrayBuffer.slice(0);
    const message = await this.request({
      prefix: "frame-detect",
      operation: "process-frame-detect",
      resultType: messageTypes.frameDetectResult,
      staleLabel: "frame detection",
      cacheKey,
      cacheInput,
      buffers: {
        raw_rgb: {
          buffer: rawBuffer,
          samples: rawBuffer.byteLength / 2,
        },
      },
      options: {
        frame_detect_options_layout: "FrameDetectOptions/v1",
        frame_detect_options: defaultFrameDetectOptions({
          image,
          detection: normalizedDetection,
        }),
        max_frames: maxFrames,
      },
      transfer: [rawBuffer],
    });
    return {
      cacheKey,
      frames: message.frames,
      aspect: message.aspect,
      rebate: message.rebate,
      timings: message.timings,
    };
  }

  async processRawRgb16({
    arrayBuffer,
    file,
    image,
    stockId = stockIds.kodakGold,
    render = defaultRenderConfig(),
    dmin = [0.05, 0.06, 0.07],
    previewMaxPx = image.width * image.height,
    percentileSampleLimit = 16384,
    frameSelection = null,
    transferInput = false,
  }) {
    await this.loadModule();
    parseRawRgb16Buffer(arrayBuffer, image);
    const crop = frameCropGeometry(image, frameSelection);
    const previewGeometry = previewOutputGeometry(crop.width, crop.height, previewMaxPx);
    const stock = stockName(stockId);
    const cacheInput = buildPreviewCacheInput({
      file,
      image,
      stock,
      stockId,
      render,
      dmin,
      frameSelection: crop.frame,
      preview: {
        max_px: previewGeometry.max_pixels,
        output_width: previewGeometry.width,
        output_height: previewGeometry.height,
        scale: previewGeometry.scale,
        percentile_sample_limit: percentileSampleLimit,
      },
    });
    const cacheKey = await previewCacheKey(cacheInput);
    const rawBuffer = transferInput ? arrayBuffer : arrayBuffer.slice(0);
    const message = await this.request({
      prefix: "preview",
      operation: "process-preview",
      resultType: messageTypes.previewResult,
      staleLabel: "preview",
      cacheKey,
      cacheInput,
      buffers: {
        raw_rgb: {
          buffer: rawBuffer,
          samples: rawBuffer.byteLength / 2,
        },
      },
      options: {
        preview_options_layout: "PreviewOptions/v3",
        preview_options: defaultPreviewOptions({
          width: previewGeometry.width,
          height: previewGeometry.height,
          stock: stockId,
          render,
          dmin,
          percentileSampleLimit,
        }),
        input: {
          width: crop.width,
          height: crop.height,
        },
        crop: crop.frame.kind === "full-image" ? null : {
          image,
          frame_selection: crop.frame,
        },
        resize: previewGeometry.width === crop.width && previewGeometry.height === crop.height
          ? null
          : {
            width: previewGeometry.width,
            height: previewGeometry.height,
            mode: "area-box",
          },
      },
      transfer: [rawBuffer],
    });
    return {
      cacheKey,
      rgb8: new Uint8Array(message.output.buffer),
      width: message.output.width,
      height: message.output.height,
      frame: crop.frame,
      previewScale: previewGeometry.scale,
      timings: message.timings,
    };
  }

  async exportRawRgb16({
    arrayBuffer,
    file,
    image,
    stockId = stockIds.kodakGold,
    render = defaultRenderConfig(),
    dmin = [0.05, 0.06, 0.07],
    percentileSampleLimit = 16384,
    frameSelection = null,
    variant = exportVariants.irInv,
    transferInput = false,
  }) {
    await this.loadModule();
    parseRawRgb16Buffer(arrayBuffer, image);
    const crop = frameCropGeometry(image, frameSelection);
    const stock = stockName(stockId);
    const cacheInput = buildPreviewCacheInput({
      file,
      image,
      stock,
      stockId,
      render,
      dmin,
      frameSelection: crop.frame,
      preview: {
        max_px: crop.width * crop.height,
        output_width: crop.width,
        output_height: crop.height,
        percentile_sample_limit: percentileSampleLimit,
      },
      output: { kind: "rgb16-export", color_space: "srgb", variant: variant.id },
    });
    const cacheKey = await exportCacheKey(cacheInput);
    const rawBuffer = transferInput ? arrayBuffer : arrayBuffer.slice(0);
    const message = await this.request({
      prefix: "export",
      operation: "process-export",
      resultType: messageTypes.exportResult,
      staleLabel: "export",
      cacheKey,
      cacheInput,
      buffers: {
        raw_rgb: {
          buffer: rawBuffer,
          samples: rawBuffer.byteLength / 2,
        },
      },
      options: {
        preview_options_layout: "PreviewOptions/v3",
        preview_options: defaultPreviewOptions({
          width: crop.width,
          height: crop.height,
          stock: stockId,
          render,
          dmin,
          percentileSampleLimit,
        }),
        crop: crop.frame.kind === "full-image" ? null : {
          image,
          frame_selection: crop.frame,
        },
      },
      transfer: [rawBuffer],
    });
    return {
      cacheKey,
      rgb16: new Uint16Array(message.output.buffer),
      width: message.output.width,
      height: message.output.height,
      frame: crop.frame,
      timings: message.timings,
    };
  }

  async makeIrMaskF32({
    irBuffer,
    file,
    image,
    dustRemoval = defaultDustRemovalConfig(),
  }) {
    await this.loadModule();
    if (!image.ir) throw new Error("IR mask processing requires image.ir metadata");
    if (irBuffer.byteLength !== image.ir.width * image.ir.height * 4) {
      throw new Error(`IR f32 input size ${irBuffer.byteLength} does not match ${image.ir.width}x${image.ir.height}`);
    }
    const cacheInput = buildIrMaskCacheInput({
      file,
      image,
      dustRemoval,
    });
    const cacheKey = await irMaskCacheKey(cacheInput);
    const message = await this.request({
      prefix: "ir-mask-f32",
      operation: "process-ir-mask",
      resultType: messageTypes.irMaskResult,
      staleLabel: "IR f32 mask",
      cacheKey,
      cacheInput,
      buffers: {
        ir: {
          buffer: irBuffer,
          samples: irBuffer.byteLength / 4,
          format: "f32",
        },
      },
      options: {
        ir_mask_options_layout: "IrMaskOptions/v1",
        ir_mask_options: defaultIrMaskOptions({ image, dustRemoval }),
      },
      transfer: [irBuffer],
    });
    return {
      cacheKey,
      mask: new Uint8Array(message.output.buffer),
      width: message.output.width,
      height: message.output.height,
      timings: message.timings,
    };
  }

  async resizeIrMaskToRgbU8({
    maskBuffer,
    file,
    image,
    dustRemoval = defaultDustRemovalConfig(),
    irMaskCacheKey,
  }) {
    await this.loadModule();
    if (!image.ir) throw new Error("RGB-sized IR mask processing requires image.ir metadata");
    if (maskBuffer.byteLength !== image.ir.width * image.ir.height) {
      throw new Error(`IR mask size ${maskBuffer.byteLength} does not match ${image.ir.width}x${image.ir.height}`);
    }
    const cacheInput = buildIrRgbMaskCacheInput({
      file,
      image,
      dustRemoval,
      irMaskCacheKey,
    });
    const cacheKey = await irRgbMaskCacheKey(cacheInput);
    const message = await this.request({
      prefix: "ir-rgb-mask",
      operation: "process-ir-rgb-mask",
      resultType: messageTypes.irRgbMaskResult,
      staleLabel: "RGB-sized IR mask",
      cacheKey,
      cacheInput,
      buffers: {
        ir_mask: {
          buffer: maskBuffer,
          samples: maskBuffer.byteLength,
        },
      },
      options: {
        ir_mask_resize_options_layout: "IrMaskResizeOptions/v1",
        ir_mask_resize_options: defaultIrMaskResizeOptions({ image }),
      },
      transfer: [maskBuffer],
    });
    return {
      cacheKey,
      mask: new Uint8Array(message.output.buffer),
      width: message.output.width,
      height: message.output.height,
      timings: message.timings,
    };
  }

  async inpaintGrainRgb16WithNoise({
    rgbBuffer,
    maskBuffer,
    noiseBuffer = null,
    noiseSeed = null,
    file,
    image,
    dustRemoval = defaultDustRemovalConfig(),
    rgbMaskCacheKey,
    padding = 16,
    grainPadding = 8,
  }) {
    await this.loadModule();
    if (rgbBuffer.byteLength !== image.width * image.height * 3 * 2) {
      throw new Error(`RGB16 input size ${rgbBuffer.byteLength} does not match ${image.width}x${image.height}`);
    }
    if (maskBuffer.byteLength !== image.width * image.height) {
      throw new Error(`RGB mask size ${maskBuffer.byteLength} does not match ${image.width}x${image.height}`);
    }
    if (noiseBuffer && noiseBuffer.byteLength % 8 !== 0) {
      throw new Error(`grain noise buffer size ${noiseBuffer.byteLength} is not Float64-aligned`);
    }
    if (!noiseBuffer && !noiseSeed) {
      throw new Error("grain-aware inpaint requires either a noise buffer or a noise seed");
    }
    const noiseHash = noiseBuffer ? await sha256ArrayBuffer(noiseBuffer) : `seed:${noiseSeed}`;
    const cacheInput = buildIrInpaintCacheInput({
      file,
      image,
      dustRemoval,
      rgbMaskCacheKey,
      mode: "biharmonic-grain",
      padding,
      grainPadding,
      noiseHash,
    });
    const cacheKey = await irInpaintCacheKey(cacheInput);
    const message = await this.request({
      prefix: "ir-inpaint-grain",
      operation: "process-ir-inpaint",
      resultType: messageTypes.irInpaintResult,
      staleLabel: "IR inpaint grain",
      cacheKey,
      cacheInput,
      buffers: {
        rgb: {
          buffer: rgbBuffer,
          samples: rgbBuffer.byteLength / 2,
        },
        rgb_mask: {
          buffer: maskBuffer,
          samples: maskBuffer.byteLength,
        },
        ...(noiseBuffer ? {
          noise: {
            buffer: noiseBuffer,
            samples: noiseBuffer.byteLength / 8,
          },
        } : {}),
      },
      options: {
        ir_inpaint_grain_options_layout: "IrInpaintGrainOptions/v1",
        ir_inpaint_grain_options: {
          ...defaultIrInpaintGrainOptions({ image, padding, grainPadding }),
          noise_seed: noiseSeed,
        },
      },
      transfer: noiseBuffer ? [rgbBuffer, maskBuffer, noiseBuffer] : [rgbBuffer, maskBuffer],
    });
    return {
      cacheKey,
      rgb16: new Uint16Array(message.output.buffer),
      width: message.output.width,
      height: message.output.height,
      mode: message.output.mode,
      timings: message.timings,
      noiseHash,
    };
  }

  async prepareIrCleanCrops({
    arrayBuffer,
    irBuffer,
    file,
    image,
    frameSelection = null,
    alignment = null,
  }) {
    await this.loadModule();
    if (!image.ir) throw new Error("IR-clean crop requires image.ir metadata");
    parseRawRgb16Buffer(arrayBuffer, image);
    if (irBuffer.byteLength !== image.ir.width * image.ir.height * 4) {
      throw new Error(`aligned IR f32 input size ${irBuffer.byteLength} does not match ${image.ir.width}x${image.ir.height}`);
    }
    const normalizedFrame = normalizeFrameSelection(frameSelection, image);
    const cacheInput = buildIrCleanCropCacheInput({
      file,
      image,
      frameSelection: normalizedFrame,
      alignment,
    });
    const cacheKey = await irCleanCropCacheKey(cacheInput);
    const message = await this.request({
      prefix: "ir-clean-crop",
      operation: "process-ir-clean-crop",
      resultType: messageTypes.irCleanCropResult,
      staleLabel: "IR clean crop",
      cacheKey,
      cacheInput,
      buffers: {
        raw_rgb: {
          buffer: arrayBuffer,
          samples: arrayBuffer.byteLength / 2,
          format: "u16",
        },
        ir: {
          buffer: irBuffer,
          samples: irBuffer.byteLength / 4,
          format: "f32",
        },
      },
      options: {
        image,
        frame_selection: normalizedFrame,
      },
      transfer: [arrayBuffer, irBuffer],
    });
    return {
      cacheKey,
      rgb16: new Uint16Array(message.output.rgb.buffer),
      irF32: new Float32Array(message.output.ir.buffer),
      width: message.output.rgb.width,
      height: message.output.rgb.height,
      irWidth: message.output.ir.width,
      irHeight: message.output.ir.height,
      frame: message.output.frame,
      timings: message.timings,
    };
  }

  async exportIrCleanedRgb16({
    arrayBuffer,
    irBuffer,
    irSampleFormat = "u8",
    file,
    image,
    stockId = stockIds.kodakGold,
    render = defaultRenderConfig(),
    dmin = [0.05, 0.06, 0.07],
    percentileSampleLimit = 16384,
    frameSelection = null,
    variant = exportVariants.irNeg,
    dustRemoval = defaultDustRemovalConfig(),
    noiseBuffer = null,
    alignIr = true,
    estimator = defaultIrEstimateConfig(),
    grainPadding = 8,
  }) {
    await this.loadModule();
    if (!variant.needs_ir) throw new Error(`variant ${variant.id} does not use IR cleaning`);
    if (!image.ir) throw new Error("IR-cleaned export requires image.ir metadata");
    parseRawRgb16Buffer(arrayBuffer, image);
    const irSampleBytes = scalarArrayType(irSampleFormat).BYTES_PER_ELEMENT;
    if (irBuffer.byteLength !== image.ir.width * image.ir.height * irSampleBytes) {
      throw new Error(`IR ${irSampleFormat} input size ${irBuffer.byteLength} does not match ${image.ir.width}x${image.ir.height}`);
    }

    const frame = frameCropGeometry(image, frameSelection).frame;
    let fullIrF32Buffer = null;
    let alignment = null;
    let alignmentTimings = [];
    if (alignIr) {
      try {
        const estimate = await this.estimateIrTranslationF32({
          rgbBuffer: arrayBuffer.slice(0),
          irBuffer: irBuffer.slice(0),
          rgbSampleFormat: "u16",
          irSampleFormat,
          file,
          image,
          estimator,
        });
        alignment = estimate.alignment;
        alignmentTimings = alignmentTimings.concat(estimate.timings);
        const aligned = await this.applyIrTranslationF32({
          irBuffer: irBuffer.slice(0),
          irSampleFormat,
          file,
          image,
          alignment,
        });
        fullIrF32Buffer = aligned.ir.buffer.slice(aligned.ir.byteOffset, aligned.ir.byteOffset + aligned.ir.byteLength);
        alignmentTimings = alignmentTimings.concat(aligned.timings);
      } catch (err) {
        alignment = { mode: "unaligned-fallback", error: err.message };
        alignmentTimings.push({ stage: "browser.ir-align-fallback", elapsed_us: 0, detail: err.message });
      }
    }
    if (!fullIrF32Buffer) {
      fullIrF32Buffer = scalarArrayBufferToF32(irBuffer, irSampleFormat);
    }

    const cropped = await this.prepareIrCleanCrops({
      arrayBuffer: arrayBuffer.slice(0),
      irBuffer: fullIrF32Buffer,
      file,
      image,
      frameSelection: frame,
      alignment,
    });
    const croppedRgbBuffer = cropped.rgb16.buffer.slice(cropped.rgb16.byteOffset, cropped.rgb16.byteOffset + cropped.rgb16.byteLength);
    const croppedIrBuffer = cropped.irF32.buffer.slice(cropped.irF32.byteOffset, cropped.irF32.byteOffset + cropped.irF32.byteLength);
    const cleanImage = {
      width: cropped.width,
      height: cropped.height,
      dpi: image.dpi ?? null,
      page_layout: image.page_layout ?? "rgb-thumb-ir",
      ir: {
        width: cropped.irWidth,
        height: cropped.irHeight,
        channels: 1,
        bit_depth: 32,
      },
    };
    const cropFile = {
      content_hash: cropped.cacheKey,
      name: `${file.name}.frame-${frame.x}-${frame.y}-${frame.w}x${frame.h}.aligned-ir-clean-input`,
      size: croppedRgbBuffer.byteLength + croppedIrBuffer.byteLength,
      last_modified_ms: file.last_modified_ms ?? 0,
    };

    const irMask = await this.makeIrMaskF32({
      irBuffer: croppedIrBuffer.slice(0),
      file: cropFile,
      image: cleanImage,
      dustRemoval,
    });
    const rgbMask = await this.resizeIrMaskToRgbU8({
      maskBuffer: irMask.mask.buffer.slice(irMask.mask.byteOffset, irMask.mask.byteOffset + irMask.mask.byteLength),
      file: cropFile,
      image: cleanImage,
      dustRemoval,
      irMaskCacheKey: irMask.cacheKey,
    });
    const padding = Number.isInteger(dustRemoval.inpaint_padding) ? dustRemoval.inpaint_padding : 16;
    const noiseSeed = noiseBuffer ? null : randomNoiseSeed();
    const cleaned = await this.inpaintGrainRgb16WithNoise({
      rgbBuffer: croppedRgbBuffer.slice(0),
      maskBuffer: rgbMask.mask.buffer.slice(rgbMask.mask.byteOffset, rgbMask.mask.byteOffset + rgbMask.mask.byteLength),
      noiseBuffer,
      noiseSeed,
      file: cropFile,
      image: cleanImage,
      dustRemoval,
      rgbMaskCacheKey: rgbMask.cacheKey,
      padding,
      grainPadding,
    });
    const cleanTimings = alignmentTimings
      .concat(cropped.timings)
      .concat(irMask.timings)
      .concat(rgbMask.timings)
      .concat(cleaned.timings);

    if (!variant.needs_invert) {
      return {
        cacheKey: cleaned.cacheKey,
        rgb16: cleaned.rgb16,
        width: cleaned.width,
        height: cleaned.height,
        frame,
        mode: cleaned.mode,
        alignment,
        timings: cleanTimings,
      };
    }

    const cleanedBuffer = cleaned.rgb16.buffer.slice(cleaned.rgb16.byteOffset, cleaned.rgb16.byteOffset + cleaned.rgb16.byteLength);
    const cleanedFile = await fileIdentity({
      name: `${file.name}.frame-${frame.x}-${frame.y}-${frame.w}x${frame.h}.ir-cleaned`,
      size: cleanedBuffer.byteLength,
      lastModified: file.last_modified_ms ?? 0,
      arrayBuffer: cleanedBuffer.slice(0),
    });
    const inverted = await this.exportRawRgb16({
      arrayBuffer: cleanedBuffer,
      file: cleanedFile,
      image: {
        width: cleaned.width,
        height: cleaned.height,
        dpi: image.dpi ?? null,
        page_layout: "rgb",
      },
      stockId,
      render,
      dmin,
      percentileSampleLimit,
      frameSelection: null,
      variant,
    });
    return {
      ...inverted,
      frame,
      alignment,
      timings: cleanTimings.concat(inverted.timings),
    };
  }

  async applyIrTranslationF32({
    irBuffer,
    irSampleFormat = "f32",
    file,
    image,
    alignment,
  }) {
    await this.loadModule();
    if (!image.ir) throw new Error("IR alignment processing requires image.ir metadata");
    const irSampleBytes = scalarArrayType(irSampleFormat).BYTES_PER_ELEMENT;
    if (irBuffer.byteLength !== image.ir.width * image.ir.height * irSampleBytes) {
      throw new Error(`IR ${irSampleFormat} input size ${irBuffer.byteLength} does not match ${image.ir.width}x${image.ir.height}`);
    }
    const cacheInput = buildIrAlignCacheInput({
      file,
      image,
      alignment,
    });
    const cacheKey = await irAlignCacheKey(cacheInput);
    const message = await this.request({
      prefix: "ir-align",
      operation: "process-ir-align",
      resultType: messageTypes.irAlignResult,
      staleLabel: "IR alignment",
      cacheKey,
      cacheInput,
      buffers: {
        ir: {
          buffer: irBuffer,
          samples: irBuffer.byteLength / irSampleBytes,
          format: irSampleFormat,
        },
      },
      options: {
        ir_align_options_layout: "IrAlignOptions/v1",
        ir_align_options: defaultIrAlignOptions({ image, alignment }),
      },
      transfer: [irBuffer],
    });
    return {
      cacheKey,
      ir: new Float32Array(message.output.buffer),
      width: message.output.width,
      height: message.output.height,
      timings: message.timings,
    };
  }

  async estimateIrTranslationF32({
    rgbBuffer,
    irBuffer,
    rgbSampleFormat = "f32",
    irSampleFormat = "f32",
    file,
    image,
    estimator = defaultIrEstimateConfig(),
  }) {
    await this.loadModule();
    if (!image.ir) throw new Error("IR estimate processing requires image.ir metadata");
    const rgbSampleBytes = scalarArrayType(rgbSampleFormat).BYTES_PER_ELEMENT;
    const irSampleBytes = scalarArrayType(irSampleFormat).BYTES_PER_ELEMENT;
    if (rgbBuffer.byteLength !== image.width * image.height * 3 * rgbSampleBytes) {
      throw new Error(`RGB ${rgbSampleFormat} input size ${rgbBuffer.byteLength} does not match ${image.width}x${image.height}`);
    }
    if (irBuffer.byteLength !== image.ir.width * image.ir.height * irSampleBytes) {
      throw new Error(`IR ${irSampleFormat} input size ${irBuffer.byteLength} does not match ${image.ir.width}x${image.ir.height}`);
    }
    const cacheInput = buildIrEstimateCacheInput({
      file,
      image,
      estimator,
    });
    const cacheKey = await irEstimateCacheKey(cacheInput);
    const message = await this.request({
      prefix: "ir-estimate",
      operation: "process-ir-estimate",
      resultType: messageTypes.irEstimateResult,
      staleLabel: "IR estimate",
      cacheKey,
      cacheInput,
      buffers: {
        rgb: {
          buffer: rgbBuffer,
          samples: rgbBuffer.byteLength / rgbSampleBytes,
          format: rgbSampleFormat,
        },
        ir: {
          buffer: irBuffer,
          samples: irBuffer.byteLength / irSampleBytes,
          format: irSampleFormat,
        },
      },
      options: {
        ir_estimate_options_layout: "IrEstimateOptions/v1",
        ir_estimate_options: defaultIrEstimateOptions({ image, estimator }),
      },
      transfer: [rgbBuffer, irBuffer],
    });
    return {
      cacheKey,
      alignment: message.alignment,
      timings: message.timings,
    };
  }

  async request({
    prefix,
    operation,
    resultType,
    staleLabel,
    cacheKey,
    cacheInput,
    buffers,
    options,
    transfer = [],
  }) {
    const requestId = this.nextRequestId(prefix);
    const generation = this.sequence;
    const result = this.waitFor((message) => {
      return message.request_id === requestId && (
        message.type === resultType ||
        message.type === messageTypes.error ||
        message.type === messageTypes.staleResult
      );
    });
    this.post(createProcessMessage(operation, {
      requestId,
      generation,
      cacheKey,
      cacheKeyPayload: cacheInput,
      buffers,
      options,
    }), transfer);
    const message = await result;
    if (message.type === messageTypes.error) {
      throw new Error(message.message);
    }
    if (message.type === messageTypes.staleResult) {
      throw new Error(`stale ${staleLabel} result: ${message.reason}`);
    }
    return message;
  }

  close() {
    this.loaded = false;
    this.readyMessage = null;
    this.loadPromise = null;
    if (typeof this.worker.terminate === "function") return this.worker.terminate();
    return undefined;
  }

  nextRequestId(prefix) {
    this.sequence += 1;
    return `${prefix}-${this.sequence}`;
  }

  post(message, transfer = []) {
    this.worker.postMessage(message, transfer);
  }

  waitFor(predicate) {
    return new Promise((resolve, reject) => {
      let removeListener = () => {};
      let timer = null;
      const cleanup = () => {
        if (timer !== null) clearTimeout(timer);
        removeListener();
      };
      if (this.timeoutMs > 0) {
        timer = setTimeout(() => {
          cleanup();
          reject(new Error("timed out waiting for web worker message"));
        }, this.timeoutMs);
      }
      const onMessage = (message) => {
        const payload = message?.data ?? message;
        if (!predicate(payload)) return;
        cleanup();
        resolve(payload);
      };
      const onError = (err) => {
        cleanup();
        reject(err);
      };
      removeListener = addWorkerListener(this.worker, onMessage, onError);
    });
  }
}

export function addWorkerListener(worker, onMessage, onError) {
  let removed = false;
  if (typeof worker.addEventListener === "function") {
    worker.addEventListener("message", onMessage);
    worker.addEventListener("error", onError);
    return () => {
      if (removed) return;
      removed = true;
      worker.removeEventListener("message", onMessage);
      worker.removeEventListener("error", onError);
    };
  }
  worker.on("message", onMessage);
  worker.on("error", onError);
  return () => {
    if (removed) return;
    removed = true;
    worker.off("message", onMessage);
    worker.off("error", onError);
  };
}
