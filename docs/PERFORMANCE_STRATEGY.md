# Performance Strategy

Rules for making the Zig app faster, current measurements, and the verdicts
of past experiments. The per-iteration benchmark log that used to live here is
in git history; its dated entries run from 2026-05-15 to 2026-05-23.

## Rules

- Keep user-visible results the same unless the change is meant to improve
  them. Python parity is not a requirement; the Python code is only a record
  of where the port started.
- Approximations (sampling, f32, LUTs, polynomials, downsampling, SIMD, GPU)
  are fine when the speedup is worth the measured difference at the final
  surface: `u8` preview, `u16` export, binary mask, frame geometry, or
  metadata. Record both.
- Keep an exact reference path where it is cheap, so approximations can be
  measured (`percentile_sample_limit = 0`, `invertNegativeProvidedDminScalar`,
  `AdaptiveDustPrecision.f64`).
- Order: remove CPU algorithmic waste, then SIMD for stable per-pixel kernels
  (scalar fallback kept, same fixtures), then GPU for parallel image
  transforms whose CPU version is accepted.
- No GPU work on control paths: scanner startup, command planning, config
  I/O, TIFF metadata, XMP, gallery filesystem work, Nuklear layout.
  `negadoctor` is not a GPU target.
- UI rendering stays separate from processing acceleration. WebGPU is an
  optional processing backend, not a required runtime dependency; the CPU
  path stays for tests and fallback.
- Worker counts derive from available cores (leave one free), active outer
  workers, and predicted memory. No fixed thread counts.
- Scanner work is measurement-first. No speculative probes or retry loops;
  startup speed comes from caching, fewer blocking probes, lazy init.

## Benchmark Evidence

- Timings use `-Doptimize=ReleaseFast`. Record before and after benchmark
  output.
- Exact changes show `max_abs=0`, `mismatches=0` or equal checksums at the
  final surface; exports also `metadata_equal=true`, `file_set_equal=true`.
- Approximate changes show `max_abs`, RMS or MSE, and mismatch count or rate
  next to the speedup. Detector changes also show mask-area overlap against
  the previous output (IoU, Dice, area retained, area confirmed), and should
  be looked at on real scans.
- Judge by end-to-end wall time on a real scan: aggregate worker substages can
  improve while the slowest worker regresses. Use staged `*_breakdown` cases
  for small passes; single wall-clock runs are noisy.
- GPU benchmarks report cold and warm timings. No silent CPU fallback.
- Fixture tests are regression baselines. When output changes on purpose,
  update the expectations in the same commit and record the measured change;
  never loosen a tolerance just to pass.
- SIMD and GPU backends need backend-selection tests proving the scalar
  fallback remains; GPU needs a headless CPU-vs-GPU comparison before UI use.
- Run gates from the ambient shell. Run Nix gates only when `flake.nix`,
  `shell.nix`, package outputs, or dependency wiring change; do not run Nix to
  repair a shell during routine work. Run `bench-gpu-readiness` before GPU
  backend work.

```sh
zig build test --summary all
zig build -Dui=true --summary all
zig build -Doptimize=ReleaseFast bench-color --summary all
zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all
zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- \
  --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames
```

`--scan` defaults to `scans/scan_0006_rgbir_800dpi.tiff` (scans live in the
gitignored `scans/`). `--case` defaults to `all`, which includes the long
RGB+IR export cases.

## Current Numbers

Latest recorded value per Process case, ReleaseFast.
`scan_0004_rgbir_3200dpi.tiff`: 865 MB, RGB and IR `5120x24125`, quick
preview `1738x8192`. `scan_0006_rgbir_800dpi.tiff`: quick preview `1272x6031`.

| Case (`--case`) | Input | Work | Latest | Date |
| --- | --- | --- | ---: | --- |
| `render` (`render_synthetic`) | synthetic | 1,048,576 pixels | 14.154 ms | 2026-10-03 |
| `load_preview` | scan_0004 | quick preview | 639072 us | 2026-05-19 |
| `inverted_preview` | scan_0006 | first-use inverted preview | 60998 us | 2026-10-03 |
| `auto_detect` | scan_0004 | 5 frames, aspect 24:36 | 172900 us | 2026-05-19 |
| `auto_detect_breakdown` | scan_0004 | staged, parity-checked `detect_us` | 146591 us | 2026-05-19 or later |
| `rebate` (`rebate_dmin`) | scan_0004 | full-resolution rebate Dmin | 431103 us | 2026-05-19 |
| `export_inv_only` | scan_0006 | one 764x1145 frame, one file | 323.828 ms | 2026-05-17 |
| `export_all` | scan_0006 | one 764x1145 frame, three files | 2364.064 ms | 2026-05-17 |
| `export_detected_frames` | scan_0004 | 5 full-resolution frames, `inv_only`, 5 workers | 665669 us | 2026-05-19 |
| `export_detected_frames_ir_all_breakdown` | scan_0004 | 5 frames, 15 files, IR align | 13366626 us | 2026-10-03 |
| `export_detected_frames_ir_all_breakdown` | 6x7 strip, 6400 dpi (Mac) | 2 frames, 6 files, `--format 6x7 --frames 0` | 88883402 us | 2026-10-03 |
| `export_detected_frames_ir_all_breakdown` | 35mm strip, 6400 dpi (Mac) | 5 frames, 15 files | 52392648 us | 2026-10-03 |

Major wins (scan_0004 unless noted):

- `render_to_display` (`bench-color`): `7971894` to `129087` ns-per-pixel
  x1000 (2026-05-15 to 2026-05-18), quadratic insertion sort removed.
- `preview_render_quantile_tradeoff`: `1335115 us` to `71011 us` (`18.801x`).
- `invert_negative_preview_lut_tradeoff`: `345713 us` to `74063 us` (`4.667x`).
- `inverted_preview`: `410896 us` to `85910 us` (`4.783x`).
- `load_preview`: `2255972 us` to `647912 us` (`3.482x`), exact.
- `auto_detect_breakdown`: `729511 us` to `146591 us` (`4.976x`), exact.
- `rebate`: `2396746 us` to `448352 us` (`5.346x`), same Dmin.
- `export_detected_frames`: `5981208 us` to `665669 us` (`8.986x`); that
  baseline was already parallel (serial `18125889 us`).
- `export_detected_frames_ir_all_breakdown`: `190808106 us` to
  `30366888 us` wall; not exact (f32 adaptive dust). Then the IR passes in
  parallel and a parallel TIFF writer, exact up to the render table below:
  scan_0004 `34952197 us` to `13366626 us` (`2.61x`); on the Mac a 6400 dpi
  6x7 strip `243550453 us` to `88883402 us` (`2.74x`), a 35mm strip
  `99645089 us` to `52392648 us` (`1.90x`).
- `inverted_preview` after the current display transform: `94801 us` to
  `60998 us` (`1.55x`), low-density curve table and smaller render bands.
- `process_rgb_page_cache_sequence`: `1932655 us` to `1120225 us` (`1.725x`).
- `process_result_cache_repeat`: `701955 us` to `15230 us` (`46.090x`).
- Scanner capability reuse: native preview smoke `46437116 us` to
  `28221448 us`; scan-worker `runtime_scan` `25627817 us` to `13551496 us`.

## Concluded Experiments

Verdicts as recorded in the log. "Exact" means identical final output.

Render and inversion (the display-table verdicts concern the earlier
percentile-stretch S-curve, since replaced by the current display transform):

- Characteristic-curve inversion from a 16,384-entry table over density
  1/64 to 4, exact outside it: adopted, synthetic render `76964 us` to
  `30602 us` (`2.5x`), final `u16` `max_abs=1` (RMS `0.076` at most) against
  the exact inversion on real previews.
- A second table below 1/64, 256 cells per octave indexed by the density's
  bits: adopted. Strip previews had 37% of channel values there (film base,
  thin shadows), each paying `expm1` and `log`. Render on scan_0006's
  preview `32.5` to `19.7` ns per pixel on one thread; against the previous
  build, final `u16` `max_abs=1` (RMS `0.0253`, `0.064%` of samples, at
  most) on three 6400 dpi frames and two whole 800 dpi strips; `u8`
  `max_abs=1`.
- Render threads per 256Ki pixels instead of per million (a strip preview
  had 7 of 31), and the display curve's constant `K^p` computed once per
  table: adopted, exact.
- Exact `pdq` sort for render, Dmin, IR, detector percentiles: adopted, exact.
- 16,384-sample f32 luminance range plus 256-entry display LUT: adopted, `u8`
  `max_abs=1`, RMS `0.364`. Approved by the owner for performance; applies
  to previews and exports.
- Direct `u8` preview render (`renderToDisplayU8`): adopted, `2.260x`, `u8`
  `max_abs=1`.
- f32 display-table index (`renderToDisplayU8F32`): adopted, `u8` `max_abs=2`
  against the f64-index path.
- Parallel preview display write: adopted, byte-identical to serial.
- Fused SIMD provided-Dmin inversion (default light, no dark/light RGB):
  adopted; scalar kept as reference.
- Linear-only coefficient fast path (`usesOnlyLinearTerms`): adopted, exact.
- Direct-`u16` SIMD preview inversion, no f64 staging: adopted, exact.
- f64 density LUT: exact, `138229 us`; not chosen for preview; kept for
  reference comparisons and non-preview paths.
- f32 density LUT to f32 scene for preview, built from f32 Dmin: adopted,
  `u8` `max_abs=2`.
- f32 density-LUT export (default light, linear coefficients): adopted,
  `2.128x`, final `u16` `max_abs=1`.

Preview load, export, caches:

- One OpenCV preview pass, one TIFF open, exact 256-bin percentiles, one-walk
  stretch histograms: adopted, exact.
- Interleaved crop, RGB-only loader, chunked sample expansion, no-op rotation
  passthrough, direct TIFF-sample crop for no-IR export: adopted, exact.
- Fused crop to f32 scene with nested row parallelism: adopted.
- `u16` export pipeline (`prepareInvertedPositiveOutputU16`,
  `applyRotationU16`): adopted, exact, `1.105x`.
- Dynamic frame scheduler replacing the Python max-4 pool: adopted, `3.030x`.
- Rebate Dmin cropped from TIFF samples: adopted, same Dmin.
- Native `RgbPageCache` (1 GiB, two slots, LRU) and result caches (quick
  preview, Dmin, auto-detect, inverted preview): adopted, exact replay.
- Deflate TIFF strips compressed on all cores and written raw in order:
  adopted, same pixels. With zlib, the 6x7 strip's six 1.45 GB files took
  `75.6 s` to `31.3 s` on the Mac, files `0.4%` to `0.6%` smaller than
  libtiff's. With libdeflate at libtiff's level 6 (adopted): file sizes as
  libtiff wrote them, writing `15.2 s` to `8.3 s` against zlib on Linux (31
  threads), and a two-frame 6x7 `processing export` on the Mac `115.1 s` to
  `86.4 s`.

`auto_detect`:

- Passes (shared grayscale, run-length components, run-based horizontal
  close, CLAHE maps, parallel rotation/CLAHE/angle work, portable SIMD,
  boundary preallocation): adopted, exact. The DTW pitch alignment they also
  sped up has since been replaced by a dynamic-program fit (a few ms).
- Parallel binary close: rejected and removed; regressed four-scan average.
- Exact vertical run morphology: rejected; slower than rolling counts.
- SIMD vertical morphology counts: rejected; `film_close_us` regressed to
  `52392 us`.

IR cleaning (`ir.zig`):

- Gaussian interior without reflect lookups: adopted, exact, `1.196x` wall.
- Ellipse row-span morphology: adopted, exact; later replaced by sliding
  windows.
- Coarse-mask writeback fusion: kept as memory cleanup only (`1.003x`).
- Gaussian scratch/output reuse: rejected; regressed.
- Symmetric-pair Gaussian: adopted, exact, `1.244x` wall.
- Inline helper plus four-step unroll: rejected; regressed.
- Center and pair-weight hoist: adopted, `1.025x`.
- Dynamic inner row parallelism: adopted, `1.695x` wall. Forced one or three
  inner workers were slower (`0.580x`, `0.919x`).
- Exact paired two-output Gaussian: rejected and removed; regressed.
- f64 Gaussian row-interior SIMD: adopted, `1.070x` wall.
- Sliding-window morphology: adopted, exact, `1.077x` wall.
- Meijering f64 SIMD: adopted, exact mask. f32 Meijering deferred.
- First f32 adaptive dust, before the Gaussian work: not promoted; wall
  `0.970x`, final export `max_abs=27825`, RMS `105.251609`.
- f32 adaptive dust with the same Gaussian work: adopted as default
  (`AdaptiveDustPrecision.f32`, `.f64` kept as reference). The Python code
  computes this detector in float32 (`scratchndent/processing/defects/
  ir_removal.py`). `1.757x` export wall; IoU `91.713%`, Dice `95.677%`
  against f64; final TIFF RMS `110.633142`. Accepted on mask overlap.
- Pass-count reduction: not possible without changing the detector.
- Smaller blur sizes (`603` to `151`, default `1205`): rejected; IoU
  `74.949%` at `603`.
- Box cascades (`f32_box3` to `f32_box8`): rejected; zero dust pixels found.
- Full-plan downsampled Gaussian (`f32_down2` to `f32_down8`, best `down4`
  IoU `92.158%`): rejected as default, too lossy.
- `f32_down4_final`: rejected; IoU `91.835%`, final pair must stay exact.
- `f32_down4_coarse`: parked, non-default, pending an owner decision.
  `1.279x` export wall, IoU `99.281%`, final TIFF RMS `83.164927`, mismatch
  rate `2.729%`.

Measured on the 6x7 strip above unless noted; all exact (the six exported
TIFFs decode identically, or equal tests against the one-pass code):

- Morphology over row bands in parallel: adopted; close `26.7 s` to
  `3.5 s`, dilate `8.8 s` to `1.2 s`.
- f32 Gaussian, vertical pass in 64-column tiles down all rows (the kernel
  window stays in cache) and horizontal pass on four interleaved vectors:
  adopted; one 7000x8600 pass with a 1205 kernel on 9 threads, vertical
  `3.9 s` to `0.7 s`, horizontal `1.3 s` to `1.1 s`; adaptive dust `44.5 s`
  to `16.0 s`. Tiles one output row at a time: no gain (memory-bound).
- Meijering filters and eigenvalues over row bands: adopted, `9.7 s` to
  `1.8 s`.
- ECC preparation (maxima, grey, u8 copy, resizes) over row bands on the
  native side; `ir_pure` stays single-threaded for Wasm: adopted, IR
  alignment `7.8 s` to `1.2 s`.
- Defect fills in parallel by levels (a fill waits only for fills whose
  padded regions it touches): adopted; one frame's fills `18.6 s` to `6.1 s`
  on the Mac. macOS's OpenBLAS takes one lock per BLAS call, so SuperLU runs
  at most four solves at once there (nine at once took `10.1 s`); Linux runs
  every thread (`2.0 s` on 16). Per-thread arenas and one-thread OpenBLAS
  changed nothing.

GPU, browser, scanner:

- `apply_sigmoid` WGSL: works, not wired into UI or export. Parked.
- `invert_negative` WGSL: works, opt-in, slower at workflow level. Parked.
- `negadoctor` on GPU: rejected, non-goal.
- Browser RGB16 crop in the Worker: adopted. Moving it into the Wasm core:
  parked.
- Native session capability reuse: adopted. CLI capability disk cache: left
  out, needs an invalidation key design.

## GPU / WebGPU

Dependencies: nixpkgs `wgpu-native` (C library, `include/webgpu` headers).
nixpkgs `pkgs.dawn` is an unrelated PostScript tool; keep the backend boundary
small enough to add Google Dawn later. `wgpu-native` is only in
`devShells.webgpu` and `shell.nix` with `withWebGPU=true`, which export
`WGPU_NATIVE_INCLUDE_DIR` and `WGPU_NATIVE_LIBRARY_DIR` (no pkg-config file).
`-Dwebgpu=true` links `libwgpu_native` and defaults to false; default
builds, tests, and `-Dui=true` need no WebGPU library or GPU.

Buffer boundary (`src/processing/gpu_boundary.zig`): `CpuImageView` for
borrowed CPU memory with explicit size, format, role, and stride;
`GpuImageDescriptor` for GPU allocations; `TransferPlan.upload` and
`.download`, with tightly packed parity downloads. CPU buffers own
correctness; uploads borrow only for the transfer; long-lived GPU allocations
are cached by descriptor; UI textures are presentation only.
`gpu_kernel_candidates` lists candidates, each needing a CPU fallback and a
download comparison.

Kernels in `src/processing/shaders/`, compared with Zig CPU on Linux/Vulkan:

| Kernel | Parity | Reachable from |
| --- | --- | --- |
| `apply_sigmoid.wgsl` | `max_abs=0.000000477`, `rms=0.000000184` (tolerance `abs=0.000002`, `rel=0.000002`) | compare, bench, runtime-smoke steps |
| `invert_negative.wgsl` | identity `max_abs=0.000000109`; Kodak Gold `0.000000190`; custom edge `0.000000874` | processing CLI and native UI, opt-in |

Both use 2D dispatch (65,535 workgroups per dimension). `invert_negative`
covers provided Dmin without dark/light RGB, runs in 64 MiB RGB-f32 chunks,
and caches device and pipeline per process.

```sh
zig build -Dwebgpu=true webgpu-sigmoid-compare --summary all
zig build -Dwebgpu=true webgpu-invert-negative-compare --summary all
zig build -Dwebgpu=true webgpu-invert-negative-runtime-smoke --summary all
```

Workflow result, explicit WebGPU inversion versus the Zig CPU path:

| Case | Scan | Work | CPU | GPU cold | GPU warm | Warm speedup | Parity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `inverted_preview_cpu_vs_gpu` | scan_0006 | 1272x6031 preview | 1030988 us | 1381265 us | 1174797 us | 0.877x | max_abs=1 |
| `export_inv_only_cpu_vs_gpu` | scan_0006 | 764x1145 crop | 305597 us | 463620 us | 257772 us | 1.185x | max_abs=1 |
| `inverted_preview_cpu_vs_gpu` | scan_0004 | 1738x8192 preview | 1800749 us | 2378655 us | 2194852 us | 0.820x | max_abs=1 |
| `inverted_preview_cpu_vs_gpu` | scan_0003 | 1901x8192 preview | 2060415 us | 2544158 us | 2323564 us | 0.886x | max_abs=1 |
| `export_fullres_inv_cpu_vs_gpu` | scan_0004 | 4535x3023 crop | 4786929 us | 5249665 us | 5056970 us | 0.946x | max_abs=1 |
| `export_fullres_inv_cpu_vs_gpu` | scan_0003 | 4420x3023 crop | 4468992 us | 4858133 us | 4681464 us | 0.954x | max_abs=1 |

Warm WebGPU is slower than CPU on every large scan (`0.820x` to `0.954x`);
only the small scan_0006 export crop is faster. The kernels alone are fast
(`invert_negative` `12.970x` end-to-end and `158.843x` resident on a
`1024x768` buffer; `apply_sigmoid` `83.191x` and `1034.907x`), but TIFF load,
CPU render, crop, write, transfers, and boundary crossings dominate the
workflow. The CPU columns predate the later CPU work (scan_0004 inverted
preview `1800749 us` here, `76083 us` now) and have not been re-measured.
WebGPU stays opt-in and off by default until more stages stay on the GPU.

Opt-in: `V600_PROCESSING_GPU`, read once at startup by the processing CLI
(`src/main.zig`) and the native UI (`src/ui/main.zig`) through
`webgpu.requestFromEnvironment`. Unset, empty, or `0` selects CPU; `1` or
`webgpu` selects WebGPU and fails fast; `allow-cpu` or `webgpu-allow-cpu`
falls back to CPU only when the build lacks `-Dwebgpu=true` or the inversion
options are unsupported on GPU. Other values are a startup error. The request
only affects `invert_negative`; in the native UI it covers inverted preview
and export, and changing it invalidates the inverted-preview cache. There is
no UI toggle or config key.

Remaining GPU plans:

- `render_to_display`: not started. Recorded direction: exact percentiles and
  constants on CPU, WGSL for the per-sample transform only.
- Next kernel: `invert_negative` was chosen and built; none selected since.

## Scanner Timing

`--timing-report PATH` appends `timing` JSONL records (plus `timing-context`
and `timing-status`) for the CLI scanner commands and the native
preview-worker and scan-worker smokes.

```sh
zig build run -- scanner devices --timing-report scanner-timing.jsonl
zig build run -- scanner probe --timing-report scanner-timing.jsonl
```

Last live pass, 2026-05-23, Linux, Epson V600 through epkowa and the rebuilt
`scanimage-v600` wrappers: `scanimage -L` `6040061 us`; probe total
`18209430 us` (flatbed and TPU `--help` about 6 s each); tiny RGB `scanOnce`
`25388919 us`, of which capability probe `12084453 us`; tiny IR `scanOnce`
`41331150 us`; tiny RGB+IR `scanRgbIr` `68154355 us`. Capability reuse then
removed the probe from native preview and scan-worker runs.

Open: each `scanimage` call costs about 6 s, so discovery and probe stay slow,
and the CLI has no capability cache.

## Browser/Wasm Crop And Export

Selected-frame crop must not run on the UI thread. The harness skips when no
local scan is present.

```sh
V600_WASM_BENCH_SCAN=scans/scan_0006_rgbir_800dpi.tiff \
  zig build bench-wasm-webapp-crop-export --summary all
node test/wasm/webapp_crop_export_bench.mjs zig-out/webapp/v600-wasm-core.wasm \
  --scan scans/scan_0004_rgbir_3200dpi.tiff --max-frames 1 --variant inv-only --crop-repeats 1
```

2026-05-23: scan_0006, two 35mm frames: axis crop median `2839 us`, rotated
crop median `39365 us`, export-all `224686 us`. scan_0004, one `3063x4600`
frame: rotated crop `624732 us`, export total `1572892 us`, crop share
`0.397`.

RGB16 crop runs in the browser Worker for `process-preview` and
`process-export`. Move it into the Wasm core only if a refreshed benchmark
shows the Worker crop is still a bottleneck after the worker-side IR-clean
split.

## Open Items

- f32 `invert_negative` scene generation dominates first-use inverted
  preview. scan_0004 serial split: `invert_us=68753`, `range_us=1310`,
  `output_write_us=52157` (the write is now parallel). Deferred by the owner
  on 2026-05-19.
- RGB TIFF page reads: about `314019 us` in `load_preview_breakdown` and
  `load_full_us=325067` in export on scan_0004. The native page cache avoids
  repeats; first reads and CLI runs still pay it.
- RGB+IR export is the slowest command (`13366626 us` on scan_0004).
  Adaptive dust leads (`27518442 us` aggregate), then line detection and
  close. On the Mac 6x7 strip, adaptive dust and the fills lead (about
  `16 s` each); writing led with zlib (`31345250 us`) and takes about half
  that with libdeflate. `f32_down4_coarse` awaits a decision.
- Row-band passes take every core even when frames export in parallel: on
  scan_0004 (5 frames at once) line detection went from `6.1 s` to `6.7 s`
  aggregate while the export as a whole sped up `2.61x`.
- `auto_detect`: film extent is the largest stage (`47.4%` average after the
  eighth pass); binary close is its largest substage.
- Adaptive dust variants were judged by mask overlap with the f64 detector:
  f32 became the default at IoU `91.713%` (final TIFF RMS `110.633142`)
  while full-plan `f32_down4` was rejected at `92.158%`, and
  `f32_down4_coarse` (`1.279x`, IoU `99.281%` against f32) is parked. With
  parity no longer required, choose between them on detection quality and
  speed on real scans.
- The WebGPU comparison predates the current CPU path; re-measure before more
  GPU work.
