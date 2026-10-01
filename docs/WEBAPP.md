# Browser Webapp

## What it is

The webapp is a static browser app for processing scans. You load a scan
TIFF (or a raw RGB16 buffer with width and height typed in), preview the
inversion, auto-detect frames, IR-clean, and export 16-bit TIFFs with JSON
sidecars. It has three tabs: Scan, Process, and Gallery. The processing math
runs in a WebAssembly build of the shared Zig code in `src/processing/`,
inside one Web Worker. The browser cannot drive the scanner. The Scan tab
works only when the page is served by the local companion (`v600-zig serve`,
see `docs/SCANNER_COMPANION.md`), which runs the native Linux SANE stack. The
native app remains the reference implementation.

## Build, run, test

```sh
zig build wasm-webapp
```

This copies `web/` into `zig-out/webapp/` and puts both cores next to
`index.html`: `v600-wasm-core.wasm` (wasm64) and `v600-wasm-core32.wasm`
(wasm32). `app.mjs` loads wasm64 when the browser supports Wasm memory64
(`supportsWasm64()`), and wasm32 otherwise.

To serve it with scanning enabled:

```sh
./zig-out/bin/v600-zig serve        # http://127.0.0.1:8433/
```

To serve it for processing only:

```sh
python3 -m http.server 8433 --bind 127.0.0.1 --directory zig-out/webapp
```

Serving requirements:

- A secure context (localhost or https). File hashing uses `crypto.subtle`,
  and every Process action fails without it.
- `.mjs` files must be served as JavaScript. The `.wasm` MIME type does not
  matter, because the worker fetches the bytes and calls
  `WebAssembly.instantiate`.
- The Scan tab calls same-origin `/api/*`. Under any other server it shows
  "Companion not detected".
- No COOP/COEP headers are needed, because nothing uses Wasm threads.

The tests are separate Node build steps. `zig build test` does not run them.
It only compiles `src/wasm_core.zig` natively and runs its unit tests.

```sh
zig build wasm-core-smoke --summary all              # wasm64 core exports, fixtures, error codes
zig build wasm32-core-smoke --summary all            # same script against the wasm32 core
zig build wasm-worker-protocol-smoke --summary all   # message shapes, cache-key canonicalization
zig build wasm-worker-runtime-smoke --summary all    # worker/processor.mjs under node:worker_threads
zig build wasm-webapp-shell-smoke --summary all      # WebPreviewClient + export pipeline (not app.mjs)
zig build wasm-tiff-reader-smoke --summary all       # tiff.mjs against test/fixtures/tiff/rgb-thumb-ir.tiff
zig build wasm-webapp-static-smoke --summary all     # staged files exist; text checks on index.html/app.mjs
zig build companion-smoke --summary all              # v600-zig serve against a fake scanimage
zig build bench-wasm-webapp-crop-export --summary all
```

Notes on these steps:

- They need `node` on `PATH`, which `flake.nix` and `shell.nix` provide. The
  build passes Node no flags, so that Node must run memory64 modules as is.
- `companion-smoke` builds the full native `v600-zig`.
- The bench reads `V600_WASM_BENCH_SCAN` or `--scan`. Without either, it uses
  the first local `scans/*.tiff` candidate and falls back to the committed
  fixture TIFF.

There is also a manual probe, which is not a build step:

```sh
node test/wasm/real_scan_ir_estimate_probe.mjs zig-out/webapp/v600-wasm-core.wasm scans/<file>.tiff
```

## Architecture

### Wasm core

`src/wasm_core.zig` exports the functions defined in `src/wasm/core.zig`.
`addWasmCore` in `build.zig` builds two targets:

- `wasm64-freestanding` as `v600-wasm-core.wasm` (step `wasm-core`), used by
  browsers with memory64 (Chrome 133+, current Firefox).
- `wasm32-freestanding` as `v600-wasm-core32.wasm` (step `wasm32-core`), the
  fallback for browsers without it; limited to 4 GiB of memory.

Both builds are single-threaded, have no entry point, export their memory, and
set `rdynamic`. They build as ReleaseFast unless `-Doptimize` names another
release mode.

The core is a thin ABI facade. It imports `film_stocks`, `frames`,
`inversion`, `ir`, `ir_pure`, and `render` from `src/processing/`, so native
and browser run the same inversion, rendering, frame detection, IR mask,
alignment, and inpaint code.

The core does not link libc, OpenCV, SuperLU, libtiff, libjpeg, or SDL:

- The ECC alignment and local-grain helpers come from `ir_pure.zig`. The
  native build uses the same ECC (it replaced the OpenCV helper) and the
  grain ports only without libc. The ECC is held to a 0.05 px envelope of
  OpenCV's on the alignment fixtures and is not bit-exact with it.
- SuperLU has no port. The biharmonic solve falls back to its iterative path.

The exports are:

- `v600_wasm_pointer_bits`, `_alloc`, and `_free`
- `v600_preview_invert_u16_to_u8` and `v600_export_invert_u16_to_u16`
- `v600_detect_frames_rgb16`
- `v600_ir_estimate_translation_f32` and `v600_ir_apply_translation_f32`
- `v600_ir_make_defect_mask_u8`, `v600_ir_make_defect_mask_f32`, and
  `v600_ir_resize_mask_to_rgb_u8`
- `v600_ir_biharmonic_inpaint_u16` and `v600_ir_inpaint_grain_u16_with_noise`

Each call returns a status: ok, invalid-buffer, invalid-dimensions,
invalid-stock, out-of-memory, or processing-error.

Pointers and lengths are `usize`, so they are `BigInt` in JS on wasm64.
`web/worker/wasm_abi.mjs` handles both pointer widths. It also mirrors the
`extern struct` option layouts by hand, so a layout change must update both
files.

Film stocks are fixed ids: 0 identity, 1 Kodak Gold, 2 Kodak Portra.

### Browser modules

| File | Role |
| --- | --- |
| `app.mjs` | DOM wiring, state, TIFF decode, gallery, companion hand-off |
| `app_core.mjs` | Barrel re-export used by the app and tests |
| `preview_client.mjs` | `WebPreviewClient`: worker RPC and the composed IR-clean export |
| `export_pipeline.mjs` | Variants (`_ir`, empty suffix, `_inv`), filenames, sidecar metadata |
| `geometry.mjs` | Frame normalization, crops, Dmin percentile, grain-noise sizing |
| `config.mjs` | Defaults and Wasm option builders |
| `cache_inputs.mjs`, `util.mjs` | Cache-key payloads, SHA-256 |
| `tiff.mjs` | Uncompressed classic TIFF reader (RGB16 page, optional 8-bit IR page) and RGB16 writer |
| `companion.mjs` | Client for the `v600-zig serve` API |
| `worker/processor.mjs` | Module Worker: loads Wasm, crops and resizes in JS, calls Wasm |
| `worker/protocol.mjs` | Message builders, cache-key canonicalization |
| `worker/wasm_abi.mjs` | Export checks, pointer conversion, option packing |

Messages, cache-key fields, and the stale-result rule are described in
`docs/WEBAPP_WORKER_PROTOCOL.md`.

The preview always shows the whole image, downscaled to the "Preview px"
budget. It shows the inversion only, with no IR cleaning, and frames are
drawn as overlays on it.

### Algorithms still in JS

These run as JS code rather than through Wasm:

- Rotated crop. `cropRotatedSamples` in `geometry.mjs` (reflect-padded
  bilinear) duplicates `cropRotatedRect` in `src/processing/rotation.zig`. It
  is checked against `rotated-rect-crop-smoke.json`.
- Preview downscale. `resizeRgb16AreaBox` in `worker/processor.mjs` averages
  boxes with integer boundaries. The native preview uses
  `frames.resizeImageArea`, which matches OpenCV `INTER_AREA` with fractional
  weights. The two differ when the scale factor is not an integer, and no
  test compares them.
- Grain-noise sizing. `requiredInpaintNoiseSamples` in `geometry.mjs`
  re-derives the native `requiredInpaintNoiseLen`. The noise itself comes
  from Box-Muller on a seeded JS PRNG rather than `std.Random.floatNorm`.
- Dmin from the detected rebate. `computeDminFromRgb16` duplicates
  `inversion.computeDmin` and runs on the main thread. It is checked against
  `dmin-percentile-25.json`.

TIFF I/O, IR-clean sequencing, and metadata assembly are also in JS.

## Browser constraints

- Main thread: the UI is a DOM shell, and the SDL/Nuklear UI is not ported.
  Wasm work runs in one Worker. TIFF decode, file hashing, and Dmin still run
  on the main thread.
- Files: input is a picked `File` or a companion download, and output is a
  Blob download. Nothing persists: there is no IndexedDB, OPFS, or
  `localStorage` use.
- Threads: the core is single-threaded. Native `std.Thread` parallelism is
  unavailable here.
- Memory: wasm64 removes the 4 GiB pointer limit, but browser heap and
  `ArrayBuffer` limits still apply. The app keeps the whole file resident,
  makes several full-size copies per action, and has no tiled or streaming
  decode.
- Native C/C++ libraries (OpenCV, SuperLU, libtiff, libjpeg, wgpu-native) are
  unavailable in the browser, so the core uses the pure ports above and JS
  replaces libtiff. There is no JPEG path and no browser WebGPU path.
- SIMD: `build.zig` sets no extra Wasm CPU features, and there is no Wasm
  SIMD work or benchmark.
- Emscripten and WASI builds were not pursued. Direct WebUSB scanner control
  was not built; `plan.md` has a research note on it.

## Feature coverage versus native

Works:

- RGB16 TIFF import with an optional 8-bit IR page, and raw RGB16 import.
- Inversion preview with the render controls.
- Frame auto-detect for 35mm, 645, 6x6, 6x7, and 6x9, with a frame-count
  override. When the detector returns a rebate, Dmin is taken from it.
- Manual frames through numeric fields or a canvas drag, including rotated
  frames.
- Export of `_ir`, IR-cleaned inverted, and `_inv`, for one frame or all
  detected frames, with native filenames.
- Companion scans: RGB+IR, RGB, gray, or IR; 400 to 3200 dpi; TPU or
  flatbed; an optional scan area. The result loads into Process.

Missing:

- Custom film stocks. Only the three built-in stocks exist.
- Output rotation (native `applyRotation`).
- Manual rebate selection. Dmin is typed in, comes from the detected rebate,
  or falls back to the whole image (sampled to about a million pixels), as in
  the native app.
- Settings persistence.
- Multi-image or folder browsing. There is a single file input.
- The embedded TIFF metadata tag (native tag 65000). The browser writes a
  JSON sidecar instead.
- Preview scans and film-LUT scans through the companion.

## Verification status

- The Node smokes run the Wasm core, the worker under
  `node:worker_threads`, `WebPreviewClient`, the export pipeline, the TIFF
  reader, and the companion client against a fake `scanimage`.
- On 2026-09-28 the staged app was driven in headless Chrome 145 (wasm64)
  and Chromium 129 (wasm32 fallback) over the DevTools protocol: load
  `scans/scan_0006_rgbir_800dpi.tiff`, preview, auto-detect (5 frames),
  export an IR-cleaned frame. Both gave the same frames and Dmin, with no
  console errors. This is a manual check, not a build step; Chromium is not
  in the dev shell. Firefox and Safari have not been tried.
- No test executes `app.mjs` automatically, and no live scan through the
  Scan tab is recorded.

## Known issues

- `load-image` is defined in `worker/protocol.mjs`, but the worker has no case
  for it and would reply `unknown-message`. Nothing sends it.
- Cancel is a no-op, and the app never sends it. The worker sets a
  `cancelled` flag that nothing reads, then acknowledges. Its handlers are
  synchronous, so the stale-result check compares a request with itself and
  cannot fire either.
- The SHA-256 cache keys are computed but never used to look anything up,
  because there is no result cache. They only end up in sidecar `cache_key`.
  Every action still hashes the whole source file to build them.
- IR export repeats work. For N frames with both IR variants, it runs
  full-page ECC and alignment 2N times, plus 2N crop, mask, and inpaint
  passes. Native cleans each frame once and derives both variants from that
  pass. Each browser pass also draws a new noise seed, so `_ir` and the
  inverted output of one frame get different synthesized grain.
- `decodedCurrentInput` re-parses the TIFF on every Update Preview, Auto
  Detect, and Export. The RGB and IR page loaders each parse every page, so
  that is two full parses per action, plus a full copy of the file.
