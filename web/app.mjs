import {
  WebPreviewClient,
  defaultPreviewMaxPixels,
  defaultFrameDetectConfig,
  defaultRenderConfig,
  defaultFrameSelection,
  defaultOutputSelection,
  computeDminFromRgb16,
  drawRgb8ToCanvas,
  enabledExportVariants,
  exportNativeVariantResults,
  fileIdentity,
  frameSelectionFromDetectedFrame,
  metadataJsonBytes,
  normalizeFrameSelection,
  stockIds,
} from "./app_core.mjs";
import { loadIrPageFromTiff, loadRgb16PageFromTiff, rgb16ToTiffBytes } from "./tiff.mjs";

const wasmCoreUrl = new URL("./v600-wasm-core.wasm", import.meta.url).href;

const state = {
  client: null,
  clientReady: null,
  activeBuffer: null,
  activeFile: null,
  lastResult: null,
  detectedFrames: [],
  rebateSelection: null,
  activeFrameIndex: -1,
  galleryEntries: [],
  nextGalleryId: 1,
  drag: null,
};

const elements = {
  tabButtons: document.querySelectorAll("[data-tab-target]"),
  tabPanels: document.querySelectorAll("[data-tab-panel]"),
  file: document.querySelector("#file"),
  width: document.querySelector("#width"),
  height: document.querySelector("#height"),
  frameX: document.querySelector("#frame-x"),
  frameY: document.querySelector("#frame-y"),
  frameW: document.querySelector("#frame-w"),
  frameH: document.querySelector("#frame-h"),
  frameAngle: document.querySelector("#frame-angle"),
  detectFormat: document.querySelector("#detect-format"),
  detectFrames: document.querySelector("#detect-frames"),
  detectedFrame: document.querySelector("#detected-frame"),
  stock: document.querySelector("#stock"),
  dminR: document.querySelector("#dmin-r"),
  dminG: document.querySelector("#dmin-g"),
  dminB: document.querySelector("#dmin-b"),
  contrast: document.querySelector("#contrast"),
  curveK: document.querySelector("#curve-k"),
  percentileLo: document.querySelector("#percentile-lo"),
  percentileHi: document.querySelector("#percentile-hi"),
  exposure: document.querySelector("#exposure"),
  colorTemp: document.querySelector("#color-temp"),
  colorTint: document.querySelector("#color-tint"),
  sampleLimit: document.querySelector("#sample-limit"),
  previewMaxPx: document.querySelector("#preview-max-px"),
  exportIrNeg: document.querySelector("#export-ir-neg"),
  exportIrInv: document.querySelector("#export-ir-inv"),
  exportInvOnly: document.querySelector("#export-inv-only"),
  exportAllFrames: document.querySelector("#export-all-frames"),
  autoDetect: document.querySelector("#auto-detect"),
  updatePreview: document.querySelector("#update-preview"),
  exportSelected: document.querySelector("#export-selected"),
  canvas: document.querySelector("#preview"),
  frameOverlay: document.querySelector("#frame-overlay"),
  selectionOverlay: document.querySelector("#selection-overlay"),
  galleryList: document.querySelector("#gallery-list"),
  galleryEmpty: document.querySelector("#gallery-empty"),
  clearGallery: document.querySelector("#clear-gallery"),
  status: document.querySelector("#status"),
  timing: document.querySelector("#timing"),
};

elements.tabButtons.forEach((button) => {
  button.addEventListener("click", () => {
    setActiveTab(button.dataset.tabTarget);
  });
});

elements.file.addEventListener("change", async () => {
  const file = elements.file.files[0];
  if (!file) return;
  state.activeBuffer = await file.arrayBuffer();
  state.activeFile = file;
  clearDetectedFrames();
  state.rebateSelection = null;
  tryUpdateImageControlsFromActiveInput();
  setActiveTab("process");
  setStatus(file.name);
  if (isTiffName(file.name)) {
    processCurrentInput().catch((err) => setStatus(err.message));
  }
});

elements.detectedFrame.addEventListener("change", () => {
  const index = Number.parseInt(elements.detectedFrame.value, 10);
  selectDetectedFrame(index);
});

[
  elements.frameX,
  elements.frameY,
  elements.frameW,
  elements.frameH,
  elements.frameAngle,
].forEach((input) => {
  input.addEventListener("input", () => {
    const image = currentImageFromControls();
    const frame = frameSelectionFromControls(image);
    if (state.activeFrameIndex >= 0 && state.activeFrameIndex < state.detectedFrames.length) {
      state.detectedFrames[state.activeFrameIndex] = frame;
      updateDetectedFrameControl();
    }
    refreshFrameOverlay();
  });
});

elements.autoDetect.addEventListener("click", () => {
  autoDetectCurrentInput().catch((err) => setStatus(err.message));
});

elements.updatePreview.addEventListener("click", () => {
  processCurrentInput().catch((err) => setStatus(err.message));
});

elements.exportSelected.addEventListener("click", () => {
  exportCurrentInput().catch((err) => setStatus(err.message));
});

elements.clearGallery.addEventListener("click", () => {
  clearGallery();
});

elements.canvas.addEventListener("pointerdown", (event) => {
  const image = currentImageFromControls();
  if (image.width <= 0 || image.height <= 0) return;
  elements.canvas.setPointerCapture(event.pointerId);
  state.drag = {
    pointerId: event.pointerId,
    startDom: canvasDomPoint(event),
    startSource: canvasSourcePoint(event),
  };
  updateSelectionOverlay(state.drag.startDom, state.drag.startDom);
});

elements.canvas.addEventListener("pointermove", (event) => {
  if (!state.drag || state.drag.pointerId !== event.pointerId) return;
  updateSelectionOverlay(state.drag.startDom, canvasDomPoint(event));
});

elements.canvas.addEventListener("pointerup", (event) => {
  if (!state.drag || state.drag.pointerId !== event.pointerId) return;
  const start = state.drag.startSource;
  const end = canvasSourcePoint(event);
  const image = currentImageFromControls();
  const frame = normalizeFrameSelection({
    kind: "manual-rect",
    x: Math.min(start.x, end.x),
    y: Math.min(start.y, end.y),
    w: Math.max(1, Math.abs(end.x - start.x)),
    h: Math.max(1, Math.abs(end.y - start.y)),
    angle: 0,
  }, image);
  clearDetectedFrames();
  setFrameControls(frame);
  refreshFrameOverlay();
  state.drag = null;
  setStatus(`Frame ${frame.x},${frame.y} ${frame.w}x${frame.h}`);
});

elements.canvas.addEventListener("pointercancel", () => {
  state.drag = null;
  hideSelectionOverlay();
});

async function processCurrentInput() {
  if (!state.activeBuffer) {
    throw new Error("Choose an image first");
  }

  setStatus("Loading worker");
  await ensureClient();

  const source = decodedCurrentInput();
  const width = source.width;
  const height = source.height;
  const image = sourceImageDescriptor(source);
  elements.width.value = String(width);
  elements.height.value = String(height);

  const stockId = Number.parseInt(elements.stock.value, 10);
  const render = currentRenderConfig();
  const dmin = currentDmin();
  const previewFrameSelection = currentPreviewFrameSelection({ width, height });
  const file = await fileIdentity({
    name: state.activeFile.name,
    size: state.activeFile.size,
    lastModified: state.activeFile.lastModified,
    arrayBuffer: state.activeBuffer,
  });

  setStatus("Processing");
  const result = await state.client.processRawRgb16({
    arrayBuffer: source.inputBuffer,
    file,
    image,
    stockId,
    render,
    dmin,
    previewMaxPx: currentPreviewMaxPx(),
    percentileSampleLimit: Number.parseInt(elements.sampleLimit.value, 10),
    frameSelection: previewFrameSelection,
    transferInput: true,
  });
  state.lastResult = {
    ...result,
    file,
    image,
    stockId,
    render,
    dmin,
  };
  drawRgb8ToCanvas(elements.canvas, result.rgb8, result.width, result.height);
  hideSelectionOverlay();
  refreshFrameOverlay();
  elements.timing.textContent = result.timings.map((timing) => `${timing.stage}: ${timing.elapsed_us} us`).join("  ");
  setStatus("Preview ready");
}

async function autoDetectCurrentInput() {
  if (!state.activeBuffer) {
    throw new Error("Choose an image first");
  }

  setStatus("Loading worker");
  await ensureClient();

  const source = decodedCurrentInput();
  const image = sourceImageDescriptor(source);
  elements.width.value = String(source.width);
  elements.height.value = String(source.height);
  const file = await fileIdentity({
    name: state.activeFile.name,
    size: state.activeFile.size,
    lastModified: state.activeFile.lastModified,
    arrayBuffer: state.activeBuffer,
  });

  setStatus("Detecting frames");
  const result = await state.client.detectFramesRgb16({
    arrayBuffer: source.inputBuffer,
    file,
    image,
    detection: currentFrameDetectConfig(),
  });
  if (result.frames.length === 0) throw new Error("No frames detected");
  state.detectedFrames = result.frames.map((frame) => normalizeFrameSelection(frameSelectionFromDetectedFrame(frame), image));
  state.activeFrameIndex = 0;
  const dminMessage = result.rebate
    ? applyDetectedRebate(result.rebate, source.inputBuffer, image)
    : clearDetectedRebate();
  updateDetectedFrameControl();
  elements.exportAllFrames.checked = state.detectedFrames.length > 1;
  setFrameControls(state.detectedFrames[0]);
  hideSelectionOverlay();
  refreshFrameOverlay();
  elements.timing.textContent = result.timings.map((timing) => `${timing.stage}: ${timing.elapsed_us} us`).join("  ");
  setStatus(`Detected ${result.frames.length} frame${result.frames.length === 1 ? "" : "s"}${result.aspect ? ` (${result.aspect})` : ""}${dminMessage ? `; ${dminMessage}` : ""}`);
}

async function exportCurrentInput() {
  if (!state.activeBuffer) {
    throw new Error("Choose an image first");
  }

  setStatus("Loading worker");
  await ensureClient();

  const source = decodedCurrentInput();
  const width = source.width;
  const height = source.height;
  const image = sourceImageDescriptor(source);
  elements.width.value = String(width);
  elements.height.value = String(height);

  const stockId = Number.parseInt(elements.stock.value, 10);
  const render = currentRenderConfig();
  const dmin = currentDmin();
  const file = await fileIdentity({
    name: state.activeFile.name,
    size: state.activeFile.size,
    lastModified: state.activeFile.lastModified,
    arrayBuffer: state.activeBuffer,
  });

  const variants = enabledExportVariants(currentOutputSelection());
  if (variants.length === 0) throw new Error("No export variants selected");
  const frameSelections = currentExportFrameSelections({ width, height });

  setStatus("Exporting");
  const exported = await exportNativeVariantResults({
    client: state.client,
    arrayBuffer: source.inputBuffer,
    irBuffer: source.irBuffer,
    irSampleFormat: source.irSampleFormat,
    file,
    image,
    stockId,
    render,
    dmin,
    percentileSampleLimit: Number.parseInt(elements.sampleLimit.value, 10),
    frameSelections,
    variants,
    transferInput: true,
  });
  for (const item of exported) {
    const { result, metadata, filename, metadataFilename } = item;
    const tiff = rgb16ToTiffBytes(result.rgb16, result.width, result.height, { dpi: source.dpi ?? 800 });
    addGalleryEntry({
      filename,
      metadataFilename,
      tiff,
      metadata: metadataJsonBytes(metadata),
      width: result.width,
      height: result.height,
      frameIndex: item.frameIndex,
      variant: item.variant.id,
    });
  }
  elements.timing.textContent = exported
    .flatMap((item) => item.result.timings.map((timing) => `f${item.frameIndex + 1}.${item.variant.id}.${timing.stage}: ${timing.elapsed_us} us`))
    .join("  ");
  setStatus(`Exported ${exported.length} file${exported.length === 1 ? "" : "s"}`);
  setActiveTab("gallery");
}

async function ensureClient() {
  if (!state.client) {
    const worker = new Worker(new URL("./worker/processor.mjs", import.meta.url), { type: "module" });
    state.client = new WebPreviewClient({
      worker,
      wasmUrl: wasmCoreUrl,
      timeoutMs: 300000,
    });
    state.clientReady = state.client.loadModule().catch((err) => {
      const failedClient = state.client;
      state.client = null;
      state.clientReady = null;
      failedClient?.close();
      throw err;
    });
  }
  await state.clientReady;
}

function setStatus(text) {
  elements.status.textContent = text;
}

function setActiveTab(tabName) {
  elements.tabButtons.forEach((button) => {
    const active = button.dataset.tabTarget === tabName;
    button.classList.toggle("is-active", active);
    button.setAttribute("aria-selected", active ? "true" : "false");
  });
  elements.tabPanels.forEach((panel) => {
    panel.hidden = panel.dataset.tabPanel !== tabName;
  });
  refreshFrameOverlay();
}

function isTiffName(name) {
  return /\.(tif|tiff)$/i.test(name);
}

function currentRenderConfig() {
  return defaultRenderConfig({
    contrast: Number.parseFloat(elements.contrast.value),
    curve_k: Number.parseFloat(elements.curveK.value),
    percentile_lo: Number.parseFloat(elements.percentileLo.value),
    percentile_hi: Number.parseFloat(elements.percentileHi.value),
    exposure_compensation: Number.parseFloat(elements.exposure.value),
    color_temp: Number.parseFloat(elements.colorTemp.value),
    color_tint: Number.parseFloat(elements.colorTint.value),
  });
}

function currentDmin() {
  return [
    Number.parseFloat(elements.dminR.value),
    Number.parseFloat(elements.dminG.value),
    Number.parseFloat(elements.dminB.value),
  ];
}

function setDminControls(dmin) {
  elements.dminR.value = formatControlNumber(dmin[0]);
  elements.dminG.value = formatControlNumber(dmin[1]);
  elements.dminB.value = formatControlNumber(dmin[2]);
}

function currentPreviewMaxPx() {
  const value = Number.parseInt(elements.previewMaxPx.value, 10);
  return Number.isInteger(value) && value > 0 ? value : defaultPreviewMaxPixels;
}

function currentOutputSelection() {
  return defaultOutputSelection({
    ir_neg: elements.exportIrNeg.checked,
    ir_inv: elements.exportIrInv.checked,
    inv_only: elements.exportInvOnly.checked,
  });
}

function currentFrameDetectConfig() {
  const frameCount = Number.parseInt(elements.detectFrames.value, 10) || 0;
  return defaultFrameDetectConfig({
    format: elements.detectFormat.value,
    frame_count_override: frameCount > 0 ? frameCount : null,
    detect_film_extent: true,
    apply_clahe: true,
  });
}

function currentPreviewFrameSelection(image) {
  return defaultFrameSelection(image);
}

function decodedCurrentInput() {
  let width = Number.parseInt(elements.width.value, 10);
  let height = Number.parseInt(elements.height.value, 10);
  let dpi = null;
  let inputBuffer = state.activeBuffer.slice(0);
  let pageLayout = "rgb";
  let ir = null;
  let irBuffer = null;
  let irSampleFormat = null;
  if (isTiffName(state.activeFile.name)) {
    const rgbPage = loadRgb16PageFromTiff(state.activeBuffer);
    const irPage = loadIrPageFromTiff(state.activeBuffer);
    width = rgbPage.width;
    height = rgbPage.height;
    dpi = rgbPage.dpi;
    inputBuffer = rgbPage.data.buffer.slice(
      rgbPage.data.byteOffset,
      rgbPage.data.byteOffset + rgbPage.data.byteLength,
    );
    if (irPage) {
      pageLayout = "rgb-thumb-ir";
      ir = {
        width: irPage.width,
        height: irPage.height,
        channels: 1,
        bit_depth: 8,
      };
      irBuffer = irPage.data.buffer.slice(
        irPage.data.byteOffset,
        irPage.data.byteOffset + irPage.data.byteLength,
      );
      irSampleFormat = "u8";
    }
  }
  return { inputBuffer, width, height, dpi, pageLayout, ir, irBuffer, irSampleFormat };
}

function sourceImageDescriptor(source) {
  return {
    width: source.width,
    height: source.height,
    dpi: source.dpi,
    page_layout: source.pageLayout,
    ir: source.ir,
  };
}

function tryUpdateImageControlsFromActiveInput() {
  try {
    if (!state.activeBuffer || !isTiffName(state.activeFile.name)) return;
    const rgbPage = loadRgb16PageFromTiff(state.activeBuffer);
    elements.width.value = String(rgbPage.width);
    elements.height.value = String(rgbPage.height);
    setFullFrameControls({ width: rgbPage.width, height: rgbPage.height });
    refreshFrameOverlay();
  } catch {
    setFullFrameControls(currentImageFromControls());
    refreshFrameOverlay();
  }
}

function currentImageFromControls() {
  return {
    width: Math.max(1, Number.parseInt(elements.width.value, 10) || 1),
    height: Math.max(1, Number.parseInt(elements.height.value, 10) || 1),
  };
}

function currentFrameSelection(image) {
  const frame = normalizeFrameSelection({
    kind: "manual-rect",
    x: Number.parseFloat(elements.frameX.value) || 0,
    y: Number.parseFloat(elements.frameY.value) || 0,
    w: Number.parseFloat(elements.frameW.value) || image.width,
    h: Number.parseFloat(elements.frameH.value) || image.height,
    angle: Number.parseFloat(elements.frameAngle.value) || 0,
  }, image);
  setFrameControls(frame);
  if (state.activeFrameIndex >= 0 && state.activeFrameIndex < state.detectedFrames.length) {
    state.detectedFrames[state.activeFrameIndex] = frame;
    updateDetectedFrameControl();
  }
  return frame;
}

function currentExportFrameSelections(image) {
  const current = currentFrameSelection(image);
  if (elements.exportAllFrames.checked && state.detectedFrames.length > 0) {
    return state.detectedFrames.map((frame) => normalizeFrameSelection(frame, image));
  }
  return [current];
}

function setFullFrameControls(image) {
  setFrameControls(defaultFrameSelection(image));
}

function setFrameControls(frame) {
  elements.frameX.value = formatControlNumber(frame.x);
  elements.frameY.value = formatControlNumber(frame.y);
  elements.frameW.value = formatControlNumber(frame.w);
  elements.frameH.value = formatControlNumber(frame.h);
  elements.frameAngle.value = formatControlNumber(frame.angle);
  refreshFrameOverlay();
}

function clearDetectedFrames() {
  state.detectedFrames = [];
  state.activeFrameIndex = -1;
  elements.exportAllFrames.checked = false;
  updateDetectedFrameControl();
  refreshFrameOverlay();
}

function selectDetectedFrame(index) {
  if (index < 0 || index >= state.detectedFrames.length) {
    state.activeFrameIndex = -1;
    elements.detectedFrame.value = "-1";
    refreshFrameOverlay();
    return;
  }
  state.activeFrameIndex = index;
  elements.detectedFrame.value = String(index);
  setFrameControls(state.detectedFrames[index]);
  refreshFrameOverlay();
}

function updateDetectedFrameControl() {
  elements.detectedFrame.replaceChildren();
  elements.detectedFrame.append(new Option("Manual", "-1"));
  state.detectedFrames.forEach((frame, index) => {
    elements.detectedFrame.append(new Option(`Frame ${index + 1} (${formatControlNumber(frame.w)}x${formatControlNumber(frame.h)})`, String(index)));
  });
  elements.detectedFrame.value = String(state.activeFrameIndex);
}

function canvasSourceFrame() {
  if (state.lastResult?.frame) return state.lastResult.frame;
  return defaultFrameSelection(currentImageFromControls());
}

function applyDetectedRebate(rebate, arrayBuffer, image) {
  const frame = normalizeFrameSelection(frameSelectionFromDetectedFrame(rebate), image);
  state.rebateSelection = frame;
  const dmin = computeDminFromRgb16(arrayBuffer, image, frame);
  setDminControls(dmin);
  return `Dmin ${dmin.map((value) => formatControlNumber(value)).join(" ")}`;
}

function clearDetectedRebate() {
  state.rebateSelection = null;
  return "";
}

function frameSelectionFromControls(image) {
  return normalizeFrameSelection({
    kind: "manual-rect",
    x: Number.parseFloat(elements.frameX.value) || 0,
    y: Number.parseFloat(elements.frameY.value) || 0,
    w: Number.parseFloat(elements.frameW.value) || image.width,
    h: Number.parseFloat(elements.frameH.value) || image.height,
    angle: Number.parseFloat(elements.frameAngle.value) || 0,
  }, image);
}

function visibleFrameSelections() {
  if (state.detectedFrames.length > 0) {
    return state.detectedFrames.map((frame, index) => ({
      frame,
      index,
      active: index === state.activeFrameIndex,
    }));
  }
  if (!state.activeBuffer) return [];
  const image = currentImageFromControls();
  const frame = frameSelectionFromControls(image);
  if (isFullFrameEquivalent(frame, image)) return [];
  return [{ frame, index: 0, active: true }];
}

function refreshFrameOverlay() {
  if (!elements.frameOverlay) return;
  elements.frameOverlay.replaceChildren();
  const canvasRect = elements.canvas.getBoundingClientRect();
  if (canvasRect.width <= 0 || canvasRect.height <= 0) return;
  const sourceFrame = canvasSourceFrame();
  if (state.rebateSelection) {
    const rebateDisplay = frameToDisplayRect(state.rebateSelection, sourceFrame, canvasRect);
    if (rebateDisplay) {
      elements.frameOverlay.append(selectionBoxElement({
        className: "rebate-box",
        display: rebateDisplay,
        angle: state.rebateSelection.angle,
        label: "rebate (Dmin)",
      }));
    }
  }
  const selections = visibleFrameSelections();
  for (const item of selections) {
    const display = frameToDisplayRect(item.frame, sourceFrame, canvasRect);
    if (!display) continue;
    elements.frameOverlay.append(selectionBoxElement({
      className: `frame-box${item.active ? " is-active" : ""}`,
      display,
      angle: item.frame.angle,
      label: `#${item.index + 1}: ${formatControlNumber(item.frame.w)}x${formatControlNumber(item.frame.h)}`,
    }));
  }
}

function selectionBoxElement({ className, display, angle, label }) {
  const box = document.createElement("div");
  box.className = className;
  Object.assign(box.style, {
    left: `${display.left}px`,
    top: `${display.top}px`,
    width: `${display.width}px`,
    height: `${display.height}px`,
    transform: `rotate(${angle || 0}rad)`,
  });

  const labelEl = document.createElement("div");
  labelEl.className = "selection-box-label";
  labelEl.textContent = label;
  box.append(labelEl);
  return box;
}

function frameToDisplayRect(frame, sourceFrame, canvasRect) {
  const sourceW = Math.max(1, sourceFrame.w);
  const sourceH = Math.max(1, sourceFrame.h);
  const cx = ((frame.cx - sourceFrame.x) / sourceW) * canvasRect.width;
  const cy = ((frame.cy - sourceFrame.y) / sourceH) * canvasRect.height;
  const width = (frame.w / sourceW) * canvasRect.width;
  const height = (frame.h / sourceH) * canvasRect.height;
  if (!Number.isFinite(cx) || !Number.isFinite(cy) || !Number.isFinite(width) || !Number.isFinite(height)) return null;
  if (width <= 0 || height <= 0) return null;
  const pad = Math.max(width, height);
  if (cx + pad < 0 || cy + pad < 0 || cx - pad > canvasRect.width || cy - pad > canvasRect.height) return null;
  return {
    left: cx - width / 2,
    top: cy - height / 2,
    width: Math.max(1, width),
    height: Math.max(1, height),
  };
}

function isFullFrameEquivalent(frame, image) {
  return Math.abs(frame.x) < 0.5 &&
    Math.abs(frame.y) < 0.5 &&
    Math.abs(frame.w - image.width) < 0.5 &&
    Math.abs(frame.h - image.height) < 0.5 &&
    Math.abs(frame.angle) < 1.0e-6;
}

function canvasSourcePoint(event) {
  const dom = canvasDomPoint(event);
  const rect = elements.canvas.getBoundingClientRect();
  const frame = canvasSourceFrame();
  const x = frame.x + (dom.x / Math.max(1, rect.width)) * frame.w;
  const y = frame.y + (dom.y / Math.max(1, rect.height)) * frame.h;
  return { x, y };
}

function canvasDomPoint(event) {
  const rect = elements.canvas.getBoundingClientRect();
  return {
    x: clamp(event.clientX - rect.left, 0, rect.width),
    y: clamp(event.clientY - rect.top, 0, rect.height),
  };
}

function updateSelectionOverlay(start, end) {
  const left = Math.min(start.x, end.x);
  const top = Math.min(start.y, end.y);
  const width = Math.max(1, Math.abs(end.x - start.x));
  const height = Math.max(1, Math.abs(end.y - start.y));
  Object.assign(elements.selectionOverlay.style, {
    left: `${left}px`,
    top: `${top}px`,
    width: `${width}px`,
    height: `${height}px`,
  });
  elements.selectionOverlay.hidden = false;
}

function hideSelectionOverlay() {
  elements.selectionOverlay.hidden = true;
}

function addGalleryEntry({ filename, metadataFilename, tiff, metadata, width, height, frameIndex, variant }) {
  const entry = {
    id: state.nextGalleryId,
    filename,
    metadataFilename,
    width,
    height,
    frameIndex,
    variant,
    tiffUrl: URL.createObjectURL(new Blob([tiff], { type: "image/tiff" })),
    metadataUrl: URL.createObjectURL(new Blob([metadata], { type: "application/json" })),
  };
  state.nextGalleryId += 1;
  state.galleryEntries.unshift(entry);
  renderGallery();
}

function clearGallery() {
  for (const entry of state.galleryEntries) {
    URL.revokeObjectURL(entry.tiffUrl);
    URL.revokeObjectURL(entry.metadataUrl);
  }
  state.galleryEntries = [];
  renderGallery();
  setStatus("Gallery cleared");
}

function renderGallery() {
  elements.galleryList.replaceChildren();
  elements.galleryEmpty.hidden = state.galleryEntries.length !== 0;
  for (const entry of state.galleryEntries) {
    const item = document.createElement("article");
    item.className = "gallery-item";

    const title = document.createElement("h2");
    title.textContent = entry.filename;
    item.append(title);

    const meta = document.createElement("p");
    meta.textContent = `${entry.width}x${entry.height}  Frame ${entry.frameIndex + 1}  ${entry.variant}`;
    item.append(meta);

    const actions = document.createElement("div");
    actions.className = "gallery-actions";
    actions.append(downloadLink(entry.tiffUrl, entry.filename, "Save TIFF"));
    actions.append(downloadLink(entry.metadataUrl, entry.metadataFilename, "Save JSON"));
    item.append(actions);

    elements.galleryList.append(item);
  }
}

function downloadLink(url, filename, label) {
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  anchor.className = "button-link";
  anchor.textContent = label;
  return anchor;
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function formatControlNumber(value) {
  const number = Number(value ?? 0);
  if (Math.abs(number - Math.round(number)) <= 1.0e-9) return String(Math.round(number));
  return number.toFixed(4).replace(/0+$/g, "").replace(/\.$/g, "");
}

window.addEventListener("beforeunload", () => {
  for (const entry of state.galleryEntries) {
    URL.revokeObjectURL(entry.tiffUrl);
    URL.revokeObjectURL(entry.metadataUrl);
  }
  state.client?.close();
});

window.addEventListener("resize", refreshFrameOverlay);

elements.stock.value = String(stockIds.kodakGold);
elements.exportIrNeg.checked = false;
elements.exportIrInv.checked = true;
elements.exportInvOnly.checked = false;
elements.exportAllFrames.checked = false;
updateDetectedFrameControl();
setFullFrameControls({ width: 2, height: 2 });
setActiveTab("process");
renderGallery();
setStatus("Ready");
