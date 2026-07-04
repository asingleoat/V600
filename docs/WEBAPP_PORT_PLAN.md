# Browser/Wasm Distribution Plan

This document plans a browser-distributed version of the Zig V600 processing
application. It is a roadmap, not a claim that browser builds are already wired.
The native Zig application remains the production implementation, and the
Python implementation remains the frozen behavior oracle for function parity.

## Goal

Create a web-distributed processing application with native-class performance:

- run the accepted Zig processing algorithms in WebAssembly;
- maximize code reuse with the native Zig distribution so browser and native
  stay in lock step as long-term supported products;
- keep expensive work off the browser main thread;
- preserve the same final-output parity surfaces used by the native rewrite;
- use browser WebGPU only behind explicit CPU fallback and comparison gates;
- distribute as static web assets once the processing path is proven.

The first web product is a processing and export webapp for already-scanned
files. Direct scanner control from a browser is not a version-one web target.

## Current Repo Facts

The current native implementation is not directly browser-portable as one
binary:

- `build.zig` links native system libraries: `libtiff-4`, `zlib`, `libjpeg`,
  `opencv4`, `superlu`, optional `wgpu_native`, and UI libraries `sdl3` plus
  `nuklear`.
- `src/ui/main.zig` owns a normal SDL window, renderer, and blocking event loop
  around `SDL_PollEvent` and `SDL_RenderPresent`.
- Native UI workers use `std.Thread` for scanner startup, preview loading,
  processing, inversion preview, and export.
- Processing and UI code read and write host filesystem paths such as `scans/`,
  `frames/`, config TOML files, TIFF pages, JPEG previews, sidecars, and timing
  reports.
- Scanner support is OS-specific. Linux uses SANE/wrapper processes; macOS is
  an Epson Interpreter/USB runtime; neither maps cleanly to a portable browser
  sandbox.
- Native WebGPU work uses `wgpu-native`. Browser WebGPU must use the browser
  `navigator.gpu` API and a separate host adapter, even if WGSL kernels are
  shared.

These facts make a straight "compile the native app to the web" path high risk.
The first browser deliverable should isolate a pure processing core and wrap it
with browser-native file, UI, worker, and GPU adapters.

## Shared-Core Policy

The browser build and the native build are both long-term supported
distributions. They should share processing implementation, workflow contracts,
and performance work wherever the browser sandbox permits it. Treat duplicated
browser logic as a temporary adapter choice, not as an independent product
line.

Rules:

- Image math, frame geometry, crop sampling, inversion, rendering,
  dust-removal masks, inpainting, frame autodetect, and export variant behavior
  should live in shared Zig modules first.
- The Wasm target should be a narrow ABI facade over shared Zig modules, not a
  second algorithm implementation. When a Wasm wrapper grows meaningful
  workflow logic, either move that logic into `src/processing/` or explain why
  the browser adapter must own it.
- JavaScript may own browser-only adapters: DOM state, file pickers, Blob
  downloads, canvas presentation, worker lifecycle, transfer buffers, and
  browser storage. JavaScript should not own durable image-processing
  algorithms unless there is a recorded portability reason and a native-vs-web
  fixture test.
- Cache-key and metadata contracts should be shared or generated from shared
  definitions where practical. Until then, JS cache-key builders and metadata
  helpers must have headless tests that compare against the native contract.
- Any optimization accepted for native CPU should be considered the default
  candidate for Wasm CPU. If the browser route cannot reuse it because of
  threads, SIMD availability, native C dependencies, or filesystem access,
  document the specific blocker and add a browser-specific benchmark/accuracy
  gate before diverging.
- Browser WebGPU may share WGSL kernels with native WebGPU, but host adapter
  code will remain separate. CPU Wasm remains the correctness fallback.

Current reuse map, 2026-05-24:

- Already shared directly by Wasm: film stock coefficients, custom negative
  inversion, density LUT path, display rendering, IR mask/resize/inpaint
  primitives, translation-ECC helpers, and frame detection.
- Still adapter-owned or duplicated in browser JS: TIFF reader/writer,
  selected-frame RGB/IR crop orchestration, rotated crop helper, export
  orchestration sequencing, worker/cache-key payload construction, metadata
  sidecar assembly, and UI state mapping.
- Native-only by design for now: scanner drivers, SDL3/Nuklear UI, native
  filesystem path management, native thread scheduling, native `wgpu-native`
  host setup, and C/C++ helper dependencies that have not been ported to
  dependency-free Zig.

## Current Implementation Status

As of 2026-05-23, the repo has moved from planning into the first Wasm
checkpoint:

- `pre-wasm-checkpoint` is an annotated tag on commit `cf46f12`, immediately
  before source changes for browser/Wasm work.
- `zig build wasm-core --summary all` builds
  `zig-out/bin/v600-wasm-core.wasm`.
- The first Wasm artifact exports:
  - `v600_wasm_pointer_bits`
  - `v600_wasm_alloc`
  - `v600_wasm_free`
  - `v600_preview_invert_u16_to_u8`
  - `v600_export_invert_u16_to_u16`
- The first exported processing operation accepts an in-memory `u16 RGB`
  buffer plus explicit preview inversion/render options and writes final
  `u8 RGB` preview pixels.
- The default target is now `wasm64-freestanding`, single-threaded, with
  exported linear memory and no filesystem, scanner, SDL, Nuklear, OpenCV,
  SuperLU, libtiff, libjpeg, or `wgpu-native` dependency. `wasm32` is retained
  only as an optional compatibility artifact while it stays trivial to build
  and test.
- Native tests include a native build of the same Wasm-core source so the
  buffer validation and deterministic output paths remain covered by
  `zig build test --summary all`.
- `nodejs` has been added to `flake.nix` and `shell.nix` as the headless
  JavaScript/Wasm harness dependency.
- `zig build wasm-core-smoke --summary all` now loads the emitted Wasm module
  through Node, writes raw/options buffers through exported linear memory,
  calls `v600_preview_invert_u16_to_u8`, checks final `u8 RGB` bytes, and
  validates invalid-dimension and invalid-stock result codes.
- `docs/WEBAPP_WORKER_PROTOCOL.md` and `web/worker/protocol.mjs` define the
  first browser worker protocol boundary, including canonical preview cache
  keys, cancellation, timing, errors, and stale-result rejection.
- `zig build wasm-worker-protocol-smoke --summary all` verifies that the
  protocol cache key changes for selected file, image shape, frame geometry,
  rebate/Dmin, film stock coefficients, processing config, render config,
  preview sample cap, backend, and output shape.
- `web/worker/processor.mjs` implements the first browser/Node-compatible
  Worker runtime loop for Wasm module load, transferred `u16 RGB` preview
  processing, transferred `u8 RGB` preview output, invalid-stock error
  reporting, and cancellation acknowledgement.
- `zig build wasm-worker-runtime-smoke --summary all` validates the Worker
  runtime against the emitted `v600-wasm-core.wasm` artifact.
- `web/index.html`, `web/app.mjs`, `web/app_core.mjs`, and `web/styles.css`
  provide the first browser processing shell. The shell imports raw RGB16 scan
  buffers through browser file APIs, drives the Wasm worker, and draws returned
  RGB8 preview pixels to canvas.
- `zig build wasm-webapp-shell-smoke --summary all` validates the shell
  orchestration headlessly through the same Worker/Wasm runtime.
- `web/tiff.mjs` adds a browser-side classic TIFF reader for uncompressed
  scanner-style RGB16 pages and optional 8-bit IR pages. The browser shell now
  accepts `.tif`/`.tiff` inputs for that first supported TIFF shape.
- `zig build wasm-tiff-reader-smoke --summary all` validates the TIFF reader
  against the committed `rgb-thumb-ir.tiff` Python oracle fixture and
  round-trips the fixture RGB page through the browser TIFF writer.
- `test/wasm/real_scan_ir_estimate_probe.mjs` is a manual diagnostic, not a
  build-step test:
  `node test/wasm/real_scan_ir_estimate_probe.mjs zig-out/webapp/v600-wasm-core.wasm scans/<file>.tiff`
  reports the browser translation-ECC estimate for a local RGB+IR scan so it
  can be compared against the native estimate.
- The shell exposes render/Dmin/sample-limit controls. These controls flow
  through the same cache-key and worker request path as the headless shell
  smoke. The early PPM preview download surface was removed once TIFF export
  variants landed; canvas preview plus TIFF/JSON export downloads are the
  supported outputs.
- Browser-side manual frame selection now works through numeric controls and
  canvas drag rectangles. The web shell includes the normalized frame in the
  cache key, then the worker performs selected-frame RGB16 crop before calling
  the Wasm preview/export functions.
- The browser worker also exposes a selected-frame full-resolution RGB16 export
  operation. It uses the same in-memory crop, Dmin, film stock, and render
  controls as preview, returns `u16 RGB` through a transferred buffer, and can
  download an uncompressed 16-bit TIFF plus `v600.webapp.rgb16-export.v1`
  metadata sidecar.
- Browser export controls now model the native variant order and suffixes:
  `_ir` raw/IR-cleaned negative, empty-suffix IR-cleaned inverted, and `_inv`
  inverted-only. When a TIFF includes an IR page, browser `_ir` and empty-suffix
  `ir_inv` now use the composed IR-cleaning path: optional browser
  translation-ECC alignment, RGB/IR frame crops, defect mask generation,
  RGB-mask resize/dilate, grain-aware inpaint, and optional Wasm
  inversion/render. Files without IR data retain the native no-IR fallback.
- Browser frame autodetect now has a first accepted worker slice. The webapp
  exposes `process-frame-detect`, calls `v600_detect_frames_rgb16` in the Wasm
  core, and the shell has Format, optional Frames, and Auto Detect controls.
  The headless smokes synthesize the accepted 35mm three-frame fixture and
  verify aspect, frame geometry, suggested rebate, and cache-key state. The
  browser shell now keeps every detected frame as a selectable frame, preserves
  per-frame angle, supports rotated RGB16/IR crops for preview/export, can
  export every selected/detected frame with native frame-indexed filenames, and
  keeps RGB preview/inverted-export crop work off the browser UI thread.
- The browser worker now exposes the first IR-processing slice:
  `process-ir-mask` accepts an 8-bit TIFF IR page buffer, dust-removal
  options, and the full IR-mask cache key, then calls the Wasm
  `v600_ir_make_defect_mask_u8` export backed by the accepted Zig
  `makeDefectMask` path. This proves mask construction in the browser runtime;
  `process-ir-estimate` estimates a translation-ECC offset from `f32` or raw
  scalar RGB/IR buffers, and `process-ir-align` applies a provided translation
  offset with the Wasm `v600_ir_apply_translation_f32` export. Raw alignment
  inputs are converted to f32 in the worker before calling Wasm.
  `process-ir-rgb-mask`
  applies the native `irCleanRegion` mask-geometry branch by nearest-resizing
  the IR mask to RGB dimensions and applying the fixed radius-1 post-resize
  dilation when dimensions differ. `process-ir-inpaint` exposes both the
  `biharmonic-no-grain` repair stage and the grain-aware
  `biharmonic-grain` stage. The grain-aware stage ports local-grain estimation,
  DFT-shaped grain synthesis, biharmonic signal repair, and masked RGB16
  writeback into dependency-free Wasm. `WebPreviewClient.exportIrCleanedRgb16`
  composes these pieces for browser `_ir` and `ir_inv` export variants.
  Selected-frame RGB16 and aligned-IR crop preparation for that composed path
  now runs through `process-ir-clean-crop`, and downstream intermediate file
  identity is derived from the complete crop cache key instead of hashing a
  concatenated main-thread crop buffer.
- `zig build wasm-webapp --summary all` stages `web/` plus
  `v600-wasm-core.wasm` into `zig-out/webapp/` as a static browser
  distribution, and `zig build wasm-webapp-static-smoke --summary all`
  serve-checks those staged assets without a bundler or framework.

## Product Modes

### Mode A: Browser Processing Webapp

This is the recommended first webapp.

Capabilities:

- import TIFFs or supported scan files through browser file pickers;
- run frame detection, preview inversion, dust processing, and export in
  WebAssembly;
- show images through canvas/WebGL/WebGPU-backed presentation;
- download exported TIFF/JPEG/PNG assets from browser blobs;
- persist UI config, cache metadata, and recent sessions through IndexedDB or
  Origin Private File System;
- use browser WebGPU opportunistically for kernels with CPU fallback.

Scanner control is excluded. Users scan with the native app or other scanner
software, then process files in the browser.

Current local-use command:

```sh
zig build wasm-webapp
python3 -m http.server 8433 --bind 127.0.0.1 --directory zig-out/webapp
```

Then open `http://127.0.0.1:8433/`. The staged app expects
`v600-wasm-core.wasm` next to `index.html`.

### Mode B: Browser UI With Local Native Scanner Companion

This is the likely path if browser distribution must include scanner control.

Capabilities:

- browser runs the same processing webapp as Mode A;
- a small native local companion owns SANE/Epson Interpreter access;
- browser and companion communicate over localhost with a narrow JSON/event
  protocol;
- scanner outputs are handed to the browser as files, streams, or local URLs.

This keeps scanner behavior in the native trust boundary while still allowing
browser distribution for the user-facing app.

### Mode C: Full Browser Scanner Control

This is a research track, not an accepted product target.

WebUSB is limited, experimental, permission-gated, and browser-dependent. It
also does not provide SANE, Epson ICA, or the existing patched Linux wrapper
environment. A full browser scanner backend would need explicit user approval,
separate hardware-risk planning, and new live tests before implementation.

## Browser Technical Constraints

### Main Loop

The browser main thread must return to the browser event loop. A native infinite
SDL-style loop has to become an Emscripten/SDL main callback loop or be replaced
by a browser-native render loop. For this project, the recommended first UI is
a browser-native shell, not Nuklear through an Emscripten canvas.

### Filesystem

Browser code cannot freely read and write host paths. The webapp must replace
native path ownership with:

- browser `File` and `Blob` objects for import/export;
- worker-transferable `ArrayBuffer` payloads for processing;
- IndexedDB or OPFS for persistent config and cache state;
- explicit download/save actions for exported files.

Do not build browser correctness around MEMFS path behavior unless a future
Emscripten UI spike explicitly chooses that architecture.

### Threads

The first WebAssembly core should be single-threaded inside a Web Worker.
Browser Wasm threads require a separate build mode and deployment headers such
as COOP/COEP. Native `std.Thread` worker structure should therefore be adapted
at the browser shell boundary first, not compiled through unchanged.

### Memory Model

Large scans can exceed 4 GiB once RGB16, IR, masks, aligned f32 buffers,
exports, and intermediate working memory are considered together. The browser
distribution must therefore be wasm64-first rather than treating the wasm32
address space as a product limit.

Rules:

- `wasm-core`, `wasm-core-smoke`, and `wasm-webapp` build the default
  `wasm64-freestanding` artifact.
- `wasm32-core` and `wasm32-core-smoke` are optional compatibility checks only.
  Do not block large-scan design on wasm32 constraints.
- Exported ABI functions expose `usize` pointers and lengths. The JS worker
  must ask the module for `v600_wasm_pointer_bits()` and pass pointers/lengths
  as `BigInt` for wasm64.
- JS byte offsets may be converted back to `Number` only after a safe-integer
  check, because `ArrayBuffer`, `DataView`, and typed-array constructors still
  use numeric byte offsets.
- wasm64 removes the 4 GiB pointer ceiling, but it does not remove browser heap,
  `ArrayBuffer`, transfer, TIFF, or output-file size limits. Full large-scan
  support still needs tiled/streaming TIFF decode, processing, and export so
  the webapp does not require every full-resolution intermediate to be resident
  at once.

### Native C/C++ Libraries

Avoid compiling the full native dependency graph in the first checkpoint.
Treat each C/C++ dependency as a separate portability decision:

| Dependency | Current native role | First webapp plan |
| --- | --- | --- |
| libtiff | TIFF page I/O and metadata | Start with browser/JS decode or a narrow pure-Wasm decode boundary; compile libtiff later only if needed. |
| libjpeg | preview JPEG encode/decode | Prefer browser canvas/blob codecs for display/export wrappers first. |
| OpenCV | ECC alignment, preview helpers, some image operations | Keep out of the first Wasm core; port or isolate needed operations one by one. |
| SuperLU | sparse biharmonic inpaint solve | Keep native first; web dust cleanup may need a later solver strategy. |
| SDL3/Nuklear | native UI | Keep desktop-native; use browser-native UI first, Emscripten SDL only as a spike. |
| wgpu-native | native WebGPU host | Replace with browser WebGPU adapter; share WGSL only after CPU Wasm parity. |

### SIMD

WebAssembly SIMD can be valuable, but the first portability boundary should
compile and test without relying on platform-specific native SIMD assumptions.
Once baseline Wasm parity is stable, add explicit SIMD benchmarks for the same
operations already optimized in native Zig.

## Target Architecture

### `wasm_core`

Add a narrow processing core module that can be built for Wasm without scanner,
filesystem, SDL, native threads, or native C dependencies.

Initial responsibilities:

- exported allocator or caller-owned memory protocol;
- raw image buffer descriptors;
- processing config descriptor;
- frame rectangle descriptor;
- inversion/render entrypoint for final preview `u8` output;
- later export-shaped `u16` output;
- stable error/result codes and diagnostics.

The first core should use existing pure Zig processing code where it already
has no host dependency. Any dependency on filesystem paths, C helpers, scanner
runtime, or UI state must be pushed outside the boundary.

Long term, `wasm_core` should remain mostly ABI packing/unpacking. Shared
behavior belongs in `src/processing/` modules that can be imported by native
CLI/UI tests and by the freestanding Wasm target. If a helper cannot compile
for freestanding Wasm, split the host-bound edge from the pure operation rather
than copying the operation into JS.

### Browser Shell

The browser shell owns:

- file import and decode staging;
- worker lifecycle;
- cancellation tokens and stale-result suppression;
- UI config persistence;
- cache lookup and eviction;
- canvas presentation;
- download/export UX;
- optional WebGPU device selection and GPU buffer lifetime.

The shell should be thin with respect to image math. Pixel-transform behavior
must stay in Zig/Wasm or in explicitly compared WGSL kernels. Cache-key payload
schema, export variant ordering, metadata fields, and filename contracts should
move toward shared Zig/generated definitions; while they remain in JS, tests
must compare them to the native contract.

### Worker Protocol

All processing commands run in a Web Worker. Message keys must include the full
state needed to prove cache correctness:

- content identity or file hash;
- file dimensions, bit depth, and channel/page layout;
- selected frame or full image geometry;
- rebate selection and Dmin state;
- film stock and custom coefficients;
- every render/dust/export config value;
- preview size and quality limit;
- output variant and export format;
- algorithm backend selections, including CPU/GPU/approximation modes.

Cache misses recompute transparently. Cache hits must never return data for a
different selected file or processing state.

### Browser WebGPU Adapter

Browser WebGPU is a separate adapter from native `wgpu-native`.

Rules:

- CPU Wasm remains the default and required fallback.
- WGSL kernels may be shared with native only when uniforms, buffer layout, and
  final-output comparison tests prove equivalence.
- Cold timings and warm timings must be reported separately.
- GPU work is not integrated into preview/export UI until a downloaded
  CPU-vs-GPU comparison passes at final `u8` or `u16` surfaces.

## Build Strategy

### First Build Target

Start with a no-dependency Zig Wasm target for the processing core. The default
artifact is `wasm64-freestanding`; an optional `wasm32-freestanding` artifact
may be kept only while it remains a simple compatibility build using the same
worker ABI helpers. This keeps the checkpoint independent of SDL, OpenCV, TIFF,
and Emscripten filesystem behavior while leaving enough address space for
large-scan processing.

The first build should not change native default build behavior.

### Emscripten Track

Use Emscripten only if we explicitly decide to:

- reuse SDL3/Nuklear in a canvas;
- compile libtiff/libjpeg/OpenCV/SuperLU into the web build;
- rely on Emscripten filesystem compatibility.

This is a separate spike because it implies a larger dependency and packaging
surface. If Emscripten or Node-based test tooling is missing from the ambient
shell, update Nix files if needed, then stop and ask the human to reload the
shell before running those tools.

### WASI Track

WASI is not the primary browser UI target. It may be useful later for CLI-like
server-side processing or a component-model experiment, but it does not solve
browser canvas, file picker, download, Web Worker, or WebGPU integration by
itself.

## Testing Strategy

### Oracles

Use the existing accepted hierarchy:

1. Python remains the behavior oracle for function parity.
2. Native Zig CPU is the performance and implementation baseline once parity is
   accepted for that function.
3. Wasm CPU must match native Zig CPU at final surfaces.
4. Browser WebGPU must match Wasm/native CPU at final surfaces.

Do not use broad visual similarity as a substitute for fixture metrics.

### Headless Tests

The first useful browser tests should be headless and deterministic:

- build the Wasm core;
- load it in a minimal JS or browser harness;
- pass synthetic and committed fixture buffers;
- compare final output bytes and reported metadata;
- check error paths for invalid dimensions/config;
- verify cancellation/stale-result behavior at the worker protocol level.

Browser UI screenshot tests are not a first checkpoint. Pixel math and worker
protocol parity should come first.

### Metrics

Every processing comparison records the same style of evidence already used by
native performance work:

- exact command or harness invocation;
- input fixture or real scan name;
- dimensions, channels, and bit depth;
- cold Wasm instantiate time;
- warm processing time;
- transfer time if buffers cross worker or GPU boundaries;
- final `u8` preview `max_abs`, RMS/MSE, mismatch count/rate;
- final `u16` export `max_abs`, RMS/MSE, mismatch count/rate;
- mask IoU/Dice/shared-area metrics for detector masks;
- metadata equality where applicable.

### Real Scan Data

Use real scans from local `scans/` for performance tuning, but do not depend on
gitignored data as the only correctness evidence. Promote small representative
fixtures into `test/fixtures/` when size and licensing allow.

## Implementation Checklist

These checkpoints are intentionally ordered so an agent can make progress
without scanner hardware.

1. Portability audit. Complete for the first checkpoint.
   - Classify processing symbols into pure Zig, filesystem-bound,
     thread-bound, native-C-bound, scanner-bound, and GPU-host-bound groups.
   - Record the first viable Wasm-safe symbol set.

2. Minimal Wasm processing core. Complete for the first preview checkpoint.
   - Add a no-filesystem, no-scanner, no-thread Wasm build target.
   - Export a tiny entrypoint that accepts an in-memory `u16 RGB` buffer plus
     inversion/render config and returns final `u8` preview pixels.
   - Compare against native Zig CPU output.

3. Headless JS/Wasm execution harness. Complete for the first preview
   checkpoint.
   - Load `zig-out/bin/v600-wasm-core.wasm` from Node.
   - Allocate input, output, and packed option buffers through
     `v600_wasm_alloc`.
   - Call `v600_preview_invert_u16_to_u8`.
   - Compare final `u8` output against the native Zig helper for the same
     synthetic fixture.
   - Record cold instantiate time and warm processing time.

4. Fixture harness. Complete for the first preview checkpoint.
   - Add committed synthetic fixtures and one small promoted real-scan crop if
     appropriate.
   - Record final-surface tolerances and exact benchmark commands.

5. Worker protocol boundary. Complete for the first preview checkpoint.
   - Define the browser worker messages for loading Wasm, passing buffers,
     reporting progress, cancelling work, and rejecting stale results.
   - Add cache-key tests that include the full file and config state.

6. Browser worker runtime loop. Complete for the first preview checkpoint.
   - Implement the actual Worker script that uses the protocol boundary,
     loads the Wasm module, runs process-preview commands, and emits timing,
     progress, stale-result, error, and preview-result messages.

7. Browser process UI shell. Complete for the first raw-RGB16 preview
   checkpoint.
   - Build import, preview, frame selection, config controls, and export
     download around the worker protocol.
   - Keep scanner UI out of this mode.

8. Image I/O expansion. Complete for the first uncompressed RGB16 TIFF
   checkpoint.
   - Decide whether TIFF/JPEG decode and encode stay in browser JS APIs,
     become narrow Wasm helpers, or use compiled C libraries.
   - Add metadata round-trip tests before claiming export parity.

9. Dust and frame detection expansion.
   - Frame detection has a first Wasm-safe worker slice:
     `v600_detect_frames_rgb16`, `process-frame-detect`, shell Auto Detect
     controls, synthetic detector fixture coverage, browser multi-frame
     selection, rotated crop, and export-all-detected-frames behavior.
   - Dust-cleaning has a first composed browser export path for `_ir` and
     `ir_inv` when TIFF IR pages are present.
   - Browser crop/export benchmarking proved selected-frame RGB crop is
     material, so `process-preview` and `process-export` now run RGB16 crop in
     the worker and report `worker.crop-rgb16`.
   - Remaining Process parity work is broader real-scan detector fixture
     coverage. Full-page alignment f32 conversions, IR-clean RGB/IR frame
     crops, and runtime grain noise generation now happen in the worker.

10. Browser WebGPU backend.
    - Add a browser WebGPU adapter for one already-accepted WGSL kernel.
    - Compare downloaded output against CPU Wasm/native CPU.
    - Keep CPU fallback mandatory.

11. Shared native/Wasm processing facade.
    - Audit every image-processing helper in `web/app_core.mjs` and
      `web/worker/processor.mjs`; classify it as browser adapter, duplicated
      processing behavior, or temporary staging.
    - Introduce or extend a dependency-free Zig facade under `src/processing/`
      for operations that should be callable by both native and Wasm without
      filesystem, scanner, SDL, native threads, or native C dependencies.
    - Native tests must call the facade directly. Wasm/worker tests must call
      the exported ABI over the same fixtures and compare final `u8`, `u16`,
      mask, geometry, metadata, and timing surfaces.
    - The first concrete migration target is selected-frame crop/rotated-crop
      math, because real-scan benchmarking showed crop can dominate browser
      preview/export time and the native code already owns the accepted crop
      semantics.
    - Follow-on targets: export variant ordering and filename/metadata schema,
      IR-clean export sequencing, preview/full-export option packing, and
      cache-key payload construction.

12. Static packaging.
    - Produce a static bundle with cacheable assets, source maps for debug
      builds, and documented deployment headers.
    - Add a package/check target only after the required web tooling is in Nix
      and the human has reloaded the shell.

13. Optional native scanner companion.
    - Design only after Mode A processing is useful.
    - Reuse existing scanner event schemas and timing reports.
    - Keep the browser-to-companion protocol narrow and auditable.

## Definition Of Done For The First Web Checkpoint

The first implementation checkpoint is complete only when:

- no native default build behavior changes;
- a direct Zig build produces the Wasm processing core;
- the core can be loaded by a headless harness;
- a `u16 RGB` fixture is transformed to final `u8` preview output;
- output matches native Zig CPU within a documented final-output tolerance;
- cold instantiate, warm processing, and transfer timings are recorded;
- `zig build test --summary all` still passes for native code if Zig source is
  changed;
- no scanner hardware, Nix evaluation, or browser screenshot is required.

Current first-checkpoint evidence, 2026-05-23:

- `zig build wasm-core --summary all` produced
  `zig-out/bin/v600-wasm-core.wasm` (`705238` bytes).
- `zig build wasm-core-smoke --summary all` passed through Node with
  `cold_instantiate_us=821`, `warm_processing_us=1422`,
  `input_samples=12`, `output_bytes=12`, `export_output_bytes=24`,
  `ir_mask_bytes=81`, `ir_rgb_mask_bytes=2592`,
  `ir_rgb_mask_defect_pixels=96`, `ir_alignment_samples=5120`,
  `ir_alignment_max_abs=0.0037903999982518144`, and
  `ir_alignment_rms=0.00080799120470609`; the same smoke estimated
  translation-ECC offset `tx=9.883345603942871`,
  `ty=-5.884145736694336`, `rho=0.987080991268158`, `iterations=5`, and
  estimated-offset final aligned-IR error
  `max_abs=141.42405929500092`, `rms=41.3169664994467`; it also checked the
  `biharmonic-inpaint-smoke` fixture after RGB16 quantization with
  `ir_inpaint_samples=168`, `ir_inpaint_max_abs=1`, and
  `ir_inpaint_rms=0.17251638983558856`; it also replayed
  `inpaint-biharmonic-grain-uint16-smoke.json` with
  `ir_grain_inpaint_samples=504`, `ir_grain_inpaint_max_abs=0`,
  `ir_grain_inpaint_rms=0`, and `ir_grain_inpaint_mismatches=0`.
- `zig build -Doptimize=ReleaseFast wasm-core-smoke --summary all` passed with
  `cold_instantiate_us=575` and `warm_processing_us=1629`; this tiny fixture is
  a correctness smoke, not a throughput benchmark.
- `zig build wasm-worker-protocol-smoke --summary all` passed with cache key
  `sha256:7a78109694f476d8023294f7025bf1426b4f6d8ca92fe869a25449bb07e7a93b`
  and checked `load-module`, `load-image`, `process-preview`,
  `process-export`, `process-frame-detect`, `process-ir-estimate`, `process-ir-align`,
  `process-ir-mask`, `process-ir-rgb-mask`, `cancel`, `preview-result`,
  `export-result`, `frame-detect-result`, `ir-estimate-result`, `ir-align-result`, `ir-mask-result`,
  `ir-rgb-mask-result`, `process-ir-inpaint`, `ir-inpaint-result`,
  `stale-result`, `timing`, and `error` messages.
- `zig build wasm-worker-runtime-smoke --summary all` passed with cache key
  `sha256:b8c377a296b220e0a621d9374a8ea9bb2b3170906fba9244b80ec58507bc0313`
  and `output_bytes=12`, plus provided-offset IR alignment
  `max_abs=0.0037903999982518144`, `rms=0.00080799120470609`, and
  translation-ECC estimate `tx=9.883345603942871`,
  `ty=-5.884145736694336`; it also returned `ir_rgb_mask_bytes=4` for the
  transferred RGB-sized mask smoke, `ir_inpaint_max_abs=1` for the transferred
  biharmonic RGB16 inpaint smoke, passed transferred and seed-generated
  grain-aware RGB16 inpaint smokes against the Python/Zig oracle tolerance, and synthesized the
  accepted `axis-35mm-vertical-three-frame` RGB16 frame-detection fixture with
  three detected frames within 12 preview pixels plus a suggested rebate.
- `zig build wasm-webapp-shell-smoke --summary all` passed with cache key
  `sha256:ff770c73e2bace100184062036ffbbd43ec30929c9d2cf539c81ab0a0ad1a4ae`
  and `output_bytes=12`, plus the same provided-offset IR alignment fixture
  tolerance and shell-level RGB-sized IR-mask plus grain-aware inpaint
  cache-key/client coverage. It also verifies worker-side IR-clean RGB/IR crop
  stages. The same shell smoke now composes full cleaned RGB16
  output from `ir-clean-region-uint16-smoke.json`: `ir_neg` is checked against
  the Python/Zig cleaned-output fixture tolerance, and `ir_inv` is checked for
  exact equality against the accepted Wasm inversion/export path run over the
  oracle cleaned RGB16 input. It also verifies
  `WebPreviewClient.detectFramesRgb16`, the frame-detect cache key, the same
  synthetic 35mm three-frame geometry, aspect reporting, suggested rebate
  reporting, detected-frame selection conversion, rotated RGB16 and f32 IR crop
  parity against the Python/Zig rotated-crop fixture tolerance, and multi-frame
  multi-variant export filenames/metadata. It also asserts selected manual
  preview crop reports the worker-side `worker.crop-rgb16` timing stage.
- `V600_WASM_BENCH_SCAN=scans/scan_0006_rgbir_800dpi.tiff zig build bench-wasm-webapp-crop-export --summary all`
  passed. It measured two real 35mm frames, axis crop median `2839 us`,
  rotated crop median `39365 us`, worker export crop timings `43759 us` and
  `38660 us`, export-all `224686 us`, and confirmed `worker_crop_active=true`.
- A direct 3200 DPI benchmark on `scans/scan_0004_rgbir_3200dpi.tiff` measured
  one full-resolution `3063x4600` frame, axis crop `32838 us`, rotated crop
  `624732 us`, preview worker crop `622467 us`, export worker crop `667572 us`,
  export total `1572892 us`, and crop share `0.397`.
- `zig build wasm-tiff-reader-smoke --summary all` passed against
  `test/fixtures/tiff/rgb-thumb-ir.tiff`, reporting `pages=3`,
  `rgb_samples=12`, `ir_samples=6`, and `dpi=800`, then round-tripped the RGB
  page through `rgb16ToTiffBytes`.
- `zig build wasm-webapp-static-smoke --summary all` passed, serve-checking
  8 staged static files from `zig-out/webapp/`.
- `zig build test --summary all` passed with 552 pass / 8 expected skips in
  the no-libc `wasm_core` imported native-helper fixture tests.
- `zig build --summary all` passed.
- `zig build -Dui=true --summary all` passed.

## Non-Goals

- Direct browser scanner control for version one.
- Making WebGPU required.
- Replacing accepted Python-shaped algorithms with web-convenient
  approximations without explicit tolerance evidence.
- Maintaining browser-only image-processing algorithms when the same behavior
  can reasonably live in shared Zig.
- Porting the entire SDL3/Nuklear native UI to browser before the processing
  core is proven.
- Treating MEMFS or path-shaped browser storage as equivalent to native
  filesystem behavior without explicit tests.
