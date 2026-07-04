# Browser Worker Protocol

This document defines the first browser processing worker boundary. It is a
headless protocol contract for the future webapp shell; it is not a browser UI
implementation.

## Scope

The browser main thread owns file pickers, UI state, canvas presentation,
downloads, persistent config, cache lookup, and stale-result suppression. The
worker owns Wasm module lifetime and processing execution.

All expensive image processing runs in the worker. The main thread must never
block on image processing and must never accept a worker result unless the
request id, generation, and cache key still match the current UI state.

## Message Schema

Every message includes:

- `schema`: `v600.webapp.worker.v1`
- `version`: `1`
- `direction`: `main-to-worker` or `worker-to-main`
- `type`
- `request_id`

Main-to-worker messages:

- `load-module`: load or replace the Wasm module.
- `load-image`: hand the worker decoded scan metadata and image buffers.
- `process-preview`: run the preview inversion operation for a complete cache
  key and explicit buffer/options descriptors. When `options.crop` is present,
  the worker crops the transferred full RGB16 buffer before calling Wasm and
  emits a `worker.crop-rgb16` timing stage.
- `process-export`: run the selected-frame full-resolution RGB16 export
  operation for a complete cache key and explicit buffer/options descriptors.
  It accepts the same optional `options.crop` descriptor as preview.
- `process-frame-detect`: run the accepted frame detector for a complete
  frame-detection cache key and explicit RGB16 buffer/options descriptors.
- `process-ir-estimate`: estimate a translation offset between RGB and IR
  inputs for a complete IR-estimation cache key and explicit RGB/IR
  buffer/options descriptors. Inputs may be `f32` or raw scalar formats such as
  `u16` RGB; the worker converts non-f32 buffers before calling Wasm.
- `process-ir-align`: apply a provided IR translation offset for a complete
  IR-alignment cache key and explicit IR buffer/options descriptors. Inputs may
  be `f32` or raw scalar formats such as `u8`; the worker returns aligned
  `f32` IR.
- `process-ir-mask`: run the accepted IR defect-mask operation for a complete
  IR-mask cache key and explicit 8-bit or f32 IR buffer/options descriptors.
- `process-ir-rgb-mask`: resize an IR defect mask to RGB coordinates for a
  complete RGB-sized-mask cache key and explicit mask/options descriptors.
- `process-ir-inpaint`: run browser-safe RGB16 inpainting for a complete
  inpaint cache key and explicit RGB16/mask/options descriptors. Supplying
  grain options plus a transferred `Float64` noise buffer selects the
  grain-aware path; grain options may instead include `noise_seed`, in which
  case the worker generates deterministic standard-normal noise and reports
  `worker.generate-ir-grain-noise`.
- `process-ir-clean-crop`: crop the full RGB16 page and aligned f32 IR page to
  the selected IR-clean frame for a complete crop cache key. It reports
  `worker.crop-ir-clean-rgb16` and `worker.crop-ir-clean-ir-f32`.
- `cancel`: request cancellation of a generation/request.

Worker-to-main messages:

- `ready`: module loaded and worker capabilities are available, including the
  loaded Wasm core's `pointer_bits` value (`64` for the default large-scan
  build, `32` only for the optional compatibility artifact).
- `image-loaded`: image metadata and buffers were accepted.
- `progress`: coarse progress for a long-running operation.
- `timing`: structured timing event for a named stage.
- `preview-result`: final preview output for a request/cache key.
- `export-result`: final export output for a request/cache key.
- `frame-detect-result`: detected preview-space frame rectangles, aspect, and
  optional suggested rebate for a request/cache key.
- `ir-estimate-result`: estimated translation offset and ECC diagnostics for
  a request/cache key.
- `ir-align-result`: final aligned `f32` IR output for a request/cache key.
- `ir-mask-result`: final `u8` defect mask output for a request/cache key.
- `ir-rgb-mask-result`: final RGB-sized `u8` defect mask output for a
  request/cache key.
- `ir-inpaint-result`: final inpainted `u16 RGB` output for a request/cache
  key.
- `ir-clean-crop-result`: cropped RGB16 and aligned f32 IR frame buffers for a
  request/cache key.
- `stale-result`: worker detected that a result is no longer current.
- `cancelled`: worker accepted cancellation.
- `error`: structured recoverable or terminal error.

## Cache Key

Preview results are keyed by a canonical JSON payload with schema
`v600.webapp.cache-key.v1`. The digest should be a sufficiently large hash of
the canonical payload, currently represented as `sha256:<hex>`.

The preview/export cache key must include:

- selected file identity: content hash, name, size, and last modified time;
- image dimensions, channels, bit depth, page layout, and DPI;
- selected frame geometry;
- rebate mode, rebate geometry, and Dmin values;
- film stock id and coefficient hash;
- complete processing config state;
- render controls;
- preview size/quality state;
- backend selection and precision;
- output kind and color space.

Cache hits are allowed only when the full key matches. Cache misses must fall
back to computation transparently.

The IR-mask cache key is a separate operation key. It must include selected
file identity, source RGB/IR page layout, IR page dimensions/bit depth,
complete dust-removal config, backend selection/precision, and output kind.
It deliberately does not include film stock, Dmin, render curves, or frame
geometry; cropped export callers use a derived file identity for the cropped
RGB/IR buffers so different frame selections cannot collide.

The frame-detection cache key is a separate operation key. It must include
selected file identity, RGB dimensions, bit depth, page layout, detector format,
optional frame-count override, film-extent detection flag, CLAHE flag, backend
selection/precision, and output kind. It deliberately does not include film
stock, Dmin, render curves, or dust-removal config because the accepted detector
operates on preview RGB data before inversion/render/export settings.

The IR-alignment cache key is also a separate operation key. It must include
selected file identity, source RGB/IR page layout, IR page dimensions/bit
depth, the alignment method and offset parameters, backend
selection/precision, and output kind. Offset estimation is intentionally keyed
as a separate operation, then its result feeds this deterministic translation
application step.

The IR-estimation cache key must include selected file identity, source RGB/IR
page layout, RGB and IR dimensions, estimator configuration, backend
selection/precision, and output kind. The first estimator is
`translation-ecc`, a pure Wasm port of the translation-only OpenCV ECC shape.
It is fixture-tested and has first real-scan evidence; final cleaned-output
evidence is still required before enabling browser IR-cleaned exports.

The RGB-sized IR-mask cache key must include selected file identity, source
RGB/IR page layout, RGB dimensions, IR page dimensions/bit depth, dust-removal
config, the upstream IR-mask cache key, resize mode, post-resize dilation rule,
backend selection/precision, and output kind. The current resize mode is the
native `irCleanRegion` geometry branch: nearest-neighbor IR-mask resize to RGB
dimensions followed by a radius-1 3x3 ellipse dilation when dimensions differ.

The IR-inpaint cache key must include selected file identity, source RGB/IR page
layout, RGB dimensions, IR page metadata, dust-removal config, the upstream
RGB-sized-mask cache key, inpaint mode/value kind, padding, grain padding, noise
hash, backend selection/precision, and output kind. Supported modes are
`biharmonic-no-grain` and `biharmonic-grain`. The grain-aware mode ports local
grain estimation, DFT-shaped grain synthesis, biharmonic signal repair, and
masked RGB16 writeback into dependency-free Wasm. Browser `ir_neg` and `ir_inv`
exports compose this primitive with mask generation, optional IR alignment, and
export sidecar metadata when a TIFF IR page is present; files without IR data
retain the no-IR fallback path.

## Stale Result Rule

The main thread tracks the active `{ request_id, generation, cache_key }`.
Every worker result that contains any of those fields is rejected as stale when
one does not match the active tuple.

This rule is separate from undo history. Undo history will later be a light
record of configuration state; cache correctness is based only on the full
operation key.

## Executable Contract

`web/worker/protocol.mjs` is the source-owned protocol helper module, and
`web/worker/processor.mjs` is the first worker runtime that consumes it.

`zig build wasm-worker-protocol-smoke --summary all` runs the headless Node
contract test. The protocol smoke verifies:

- canonical cache-key serialization is insertion-order independent;
- changing selected file, image shape, frame geometry, rebate/Dmin, film stock
  coefficients, processing config, render config, preview sample cap, backend,
  or output shape changes the cache key;
- required cache-key fields are enforced;
- load, process-preview, cancel, result, stale-result, timing, and error
  message shapes are stable for preview, export, frame detection, IR-estimation,
  IR-alignment, IR-mask, RGB-sized IR-mask, and IR-inpaint operations;
- stale-result rejection works for request, generation, and cache-key changes.

`zig build wasm-worker-runtime-smoke --summary all` runs the runtime Worker
against the emitted Wasm core. The runtime smoke verifies:

- the worker loads the Wasm module and reports `ready` with a supported
  pointer width;
- raw `u16 RGB` data is transferred to the worker;
- selected-frame RGB16 crop can run inside the worker before preview/export
  Wasm processing and reports `worker.crop-rgb16`;
- `PreviewOptions` are packed in the worker and passed to Wasm;
- final `u8 RGB` preview output and `u16 RGB` export output are transferred
  back to the caller;
- `process-frame-detect` returns the accepted synthetic 35mm three-frame
  fixture within detector tolerance, with aspect and suggested rebate metadata;
- estimated translation-ECC offsets are returned through
  `process-ir-estimate` and checked against the OpenCV/Python fixture
  tolerance, including worker-side conversion from raw `u16` RGB to f32;
- final aligned `f32` IR output is transferred back to the caller through
  `process-ir-align` and compared against the replay fixture tolerance;
- final `u8` IR defect-mask output is transferred back to the caller through
  `process-ir-mask`;
- final RGB-sized `u8` IR defect-mask output is transferred back through
  `process-ir-rgb-mask` after the native resize/dilate geometry step;
- final `u16 RGB` biharmonic-only and grain-aware inpaint outputs are
  transferred back through `process-ir-inpaint`, including worker-generated
  deterministic grain noise when only a `noise_seed` is supplied;
- IR-clean RGB16 and aligned f32 IR frame crops are transferred back through
  `process-ir-clean-crop`, and the browser shell derives downstream
  intermediate identity from the crop cache key instead of hashing a
  concatenated main-thread buffer copy;
- invalid stock errors are recoverable protocol errors;
- cancellation is acknowledged through the protocol.

## Lockstep-Critical Determinism Contracts

Some browser-side JavaScript intentionally reproduces native behavior that is
not itself behind the Wasm boundary. These pieces are lockstep-critical: a
change on either side without the other breaks caching or grain
reproducibility, so they must only change together with their counterpart and
their covering smokes.

- Grain-noise sizing: `requiredInpaintNoiseSamples` in `web/geometry.mjs`
  labels 8-connected mask components and pads their bounding boxes exactly
  like the native `requiredInpaintNoiseLen`/`labelMaskComponents8`/
  `addClampedLimit` path in `src/processing/ir.zig`. If the sizes disagree,
  `process-ir-inpaint` rejects the noise buffer as invalid.
- Grain-noise generation: captured-noise runs use caller-provided `Float64`
  buffers hashed into the cache key; seeded runs use the worker's FNV-1a
  seed hash plus mulberry32-style generator and the Box-Muller transform in
  `web/geometry.mjs` `generateStandardNormalNoise`. Seeded outputs must stay
  byte-identical for a given `noise_seed`, which the shell smoke asserts.
- Dmin estimation: `computeDminFromRgb16` mirrors the Python
  `estimate_dmin` fallback-percentile path (density conversion, numpy-style
  linear percentile interpolation). The shell smoke replays the native
  `dmin-percentile-25` oracle fixture against the browser entry point within
  a u16-quantization tolerance.
- Cache-key canonicalization: browser cache keys are canonical-JSON sha256
  strings pinned by exact hash vectors in the worker protocol smoke. The
  native UI process cache uses in-memory structural keys
  (`src/ui/process_cache.zig`), so there is no byte-level native key to
  compare against; the shared contract is that both sides key on the same
  state inputs, tracked by the cache-key field tables above.
