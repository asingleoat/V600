// Barrel module for the browser processing app. The implementation lives in
// the focused modules re-exported here; app.mjs, the headless smokes, and the
// bench harness import everything through this stable surface.

export * from "./util.mjs";
export * from "./config.mjs";
export * from "./geometry.mjs";
export * from "./cache_inputs.mjs";
export * from "./export_pipeline.mjs";
export * from "./preview_client.mjs";

import { rgb8ToRgba } from "./geometry.mjs";

export function drawRgb8ToCanvas(canvas, rgb8, width, height) {
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d");
  const imageData = new ImageData(rgb8ToRgba(rgb8), width, height);
  context.putImageData(imageData, 0, 0);
}
