# Browser/Wasm Distribution Plan

This document plans a browser-distributed version of the Zig V600 processing
application. It is a roadmap, not a claim that browser builds are already wired.
The native Zig application remains the production implementation, and the
Python implementation remains the frozen behavior oracle for function parity.

## Goal

Create a web-distributed processing application with native-class performance:

- run the accepted Zig processing algorithms in WebAssembly;
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

### Browser Shell

The browser shell owns:

- file import and decode staging;
- worker lifecycle;
- cancellation tokens and stale-result suppression;
- UI config persistence;
- cache keys;
- canvas presentation;
- download/export UX;
- optional WebGPU device selection and GPU buffer lifetime.

The shell should be thin with respect to image math. Pixel-transform behavior
must stay in Zig/Wasm or in explicitly compared WGSL kernels.

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

Start with a no-dependency Zig Wasm target for the processing core, likely
`wasm32-freestanding`, with a small JS loader. This keeps the first checkpoint
independent of SDL, OpenCV, TIFF, and Emscripten filesystem behavior.

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

1. Portability audit.
   - Classify processing symbols into pure Zig, filesystem-bound,
     thread-bound, native-C-bound, scanner-bound, and GPU-host-bound groups.
   - Record the first viable Wasm-safe symbol set.

2. Minimal Wasm processing core.
   - Add a no-filesystem, no-scanner, no-thread Wasm build target.
   - Export a tiny entrypoint that accepts an in-memory `u16 RGB` buffer plus
     inversion/render config and returns final `u8` preview pixels.
   - Compare against native Zig CPU output.

3. Fixture harness.
   - Add committed synthetic fixtures and one small promoted real-scan crop if
     appropriate.
   - Record final-surface tolerances and exact benchmark commands.

4. Worker protocol.
   - Add a browser worker harness for loading Wasm, passing buffers, reporting
     progress, cancelling work, and rejecting stale results.
   - Add cache-key tests that include the full file and config state.

5. Browser process UI shell.
   - Build import, preview, frame selection, config controls, and export
     download around the worker protocol.
   - Keep scanner UI out of this mode.

6. Image I/O expansion.
   - Decide whether TIFF/JPEG decode and encode stay in browser JS APIs,
     become narrow Wasm helpers, or use compiled C libraries.
   - Add metadata round-trip tests before claiming export parity.

7. Dust and frame detection expansion.
   - Add Wasm-safe frame detection and dust-cleaning stages only after the
     dependency audit identifies which OpenCV/SuperLU paths need replacement,
     porting, or explicit C-library compilation.

8. Browser WebGPU backend.
   - Add a browser WebGPU adapter for one already-accepted WGSL kernel.
   - Compare downloaded output against CPU Wasm/native CPU.
   - Keep CPU fallback mandatory.

9. Static packaging.
   - Produce a static bundle with cacheable assets, source maps for debug
     builds, and documented deployment headers.
   - Add a package/check target only after the required web tooling is in Nix
     and the human has reloaded the shell.

10. Optional native scanner companion.
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

## Non-Goals

- Direct browser scanner control for version one.
- Making WebGPU required.
- Replacing accepted Python-shaped algorithms with web-convenient
  approximations without explicit tolerance evidence.
- Porting the entire SDL3/Nuklear native UI to browser before the processing
  core is proven.
- Treating MEMFS or path-shaped browser storage as equivalent to native
  filesystem behavior without explicit tests.
