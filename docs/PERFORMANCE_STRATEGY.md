# Performance Strategy

This document records where acceleration is worth introducing during the
Python-to-Zig rewrite. The rule is parity first: no SIMD, threading, GPU, or
algorithm change is accepted as rewrite progress unless it preserves the frozen
Python function's observable behavior and algorithmic contract. Alternate
algorithms are post-parity experiments only, require explicit user approval,
and must remain separate from parity checklist completion. Numeric acceleration
does not require byte-for-byte equality with the Python oracle or with
intermediate floating-point buffers: small final-output errors are acceptable
for large speed increases when the error budget is explicit and measured at the
final `u8` preview, `u16` export, binary mask, frame-geometry, or metadata
surface.

## Current Baseline

Run:

```sh
zig build -Doptimize=ReleaseFast bench-color --summary all
```

Current Linux baseline from 2026-05-18, 4096 pixels per pass, after replacing
quadratic numeric insertion sorts with exact `pdq` sorting, wiring the
provided-Dmin `invert_negative` CPU path through the fused SIMD implementation,
adding the linear-only coefficient fast path, and adding preview-specific
direct-u8/direct-u16 fusion paths, sampled preview percentiles, and dynamic
display LUTs:

| Path | ns-per-pixel x1000 | Notes |
| --- | ---: | --- |
| `srgb_to_linear` | 54639 | Scalar transfer function with `pow`. |
| `linear_to_srgb` | 49268 | Scalar transfer function with `pow`; benchmarked for GPU readiness coverage. |
| `color_matrix_rec2020` | 614 | Simple 3x3 multiply; not a current bottleneck. |
| `density_transform_kodak_gold` | 929 | Linear-only built-in profile fast path. |
| `invert_negative_scalar` | 34559 | Scalar oracle for provided-Dmin custom inversion. |
| `invert_negative` | 16772 | Production CPU path; fused SIMD when provided Dmin/default light permit it. |
| `invert_negative_simd` | 16642 | Direct SIMD helper benchmark for comparison with production dispatch. |
| `invert_negative_u16_simd` | 16824 | Direct `u16` input helper; synthetic row excludes the removed staging allocation/pass. |
| `darktable_sigmoid` | 175506 | Hot scalar nonlinear path. |
| `negadoctor` | 224845 | Hot scalar nonlinear path with several transfer stages; retained for darktable/XMP parity, not a GPU target. |
| `render_to_display` | 129087 | Exact percentile semantics with non-quadratic sorting. |
| `render_to_display_u16_then_u8` | 125588 | Old preview-shaped path: render display `u16`, then downshift to `u8`. |
| `render_to_display_u8` | 127761 | Direct preview display path; real-scan benchmark is the authoritative win because synthetic size falls back to exact semantics. |

The previous 2026-05-15 `render_to_display` baseline was
`7971894 ns-per-pixel x1000`, dominated by accidental quadratic insertion
sorting over full positive-luminance buffers.

Run user-visible Process command coverage with:

```sh
zig build -Doptimize=ReleaseFast bench-processing-commands
```

Current Linux command baseline from 2026-05-17 on local
`scans/scan_0006_rgbir_800dpi.tiff`:

| Command | Image/Units | Elapsed |
| --- | ---: | ---: |
| `render_synthetic` | 1,048,576 pixels | 155.301 ms |
| `load_preview` | 1272x6031 preview | 992.954 ms |
| `inverted_preview` | 1272x6031 preview | 1309.567 ms |
| `auto_detect` | 1272x6031 preview | 376.805 ms |
| `rebate_dmin` | 613x25 rebate crop | 147.102 ms |
| `export_inv_only` | one 764x1145 frame, one file | 323.828 ms |
| `export_all` | one 764x1145 frame, three files | 2364.064 ms |

The Python upstream comparison could not be refreshed in the same shell because
`python3` could not import `numpy`. Do not run Nix to repair that in routine
optimization work; either use an ambient shell that already has Python
processing dependencies or stop for a human shell reload after dependency edits.

## Acceleration Order

1. Optimize CPU implementations before SIMD or GPU.
   `render_to_display` was the first target because the port accidentally used
   insertion sort for full positive-luminance percentile buffers. That is fixed
   with exact non-quadratic sorting in `renderToDisplay`, Dmin percentiles, IR
   percentiles, and detector medians. Exact render semantics remain available
   through `percentile_sample_limit=0` and small-buffer fallback for fixtures and
   oracle comparisons. Preview-sized production rendering now uses the
   explicitly approved robust percentile estimate and display LUT path because
   final quantized output stays within the accepted one-code-value tolerance on
   real scans. Future approximate statistics must still be approved and recorded
   with final-output error evidence.
   The same final-output rule applies to f32, LUT, polynomial, SIMD, and GPU
   approximations: compare the operation's final user-visible/export result
   rather than requiring byte-for-byte equality in every internal buffer, and
   accept the approximation only when the speedup justifies the measured error.

2. Add SIMD only for stable per-pixel kernels.
   Good candidates are `srgbToLinear`, `linearToSrgb`, `applySigmoid`,
   `negadoctor`, and density polynomial evaluation. SIMD work must keep a
   scalar fallback and reuse the same fixture tests. The provided-Dmin
   `invert_negative` CPU path now uses a fused SIMD implementation only for
   the exact default-light/no-dark-light case; scalar code remains available as
   `invertNegativeProvidedDminScalar` for oracle comparisons and benchmarks.

3. Defer GPU until CPU parity is complete.
   WebGPU should first target preview/export image transforms that are
   embarrassingly parallel: transfer functions, matrix transforms, sigmoid,
   negadoctor, IR mask operations, and display rendering. GPU kernels must
   execute the same Python-shaped operation that the CPU path already proved.
   Do not introduce GPU acceleration into scanner startup, scanner command
   planning, config I/O, TIFF metadata, or other low-throughput control paths.

4. Keep UI rendering separate from image-processing acceleration.
   SDL3/Nuklear can begin with CPU-rendered image buffers uploaded to textures.
   WebGPU should be introduced as an optional processing/render backend with
   the CPU path still used for tests and fallback.

## Recorded CPU Waste/Fusion Targets

These are approved follow-up performance targets, but each must preserve the
same Python-visible behavior and retain an exact scalar/oracle comparison.

- Deferred dominant preview hotspot: after f32 density-LUT and f32
  display-index adoption, first-use inverted preview is still dominated by f32
  `invert_negative` scene generation. On `scan_0004_rgbir_3200dpi.tiff`,
  `inverted_preview_f32_breakdown` measured full production preview at
  `122313 us`, with manual stage timing `invert_us=68753`, `range_us=1310`,
  and `output_write_us=52157`. User direction on 2026-05-19 was to pass over
  this just-optimized density-LUT loop for now and look for secondary hotspots.
- Current Process hotspot ranking on `scan_0004_rgbir_3200dpi.tiff` after the
  2026-05-19 nested fused-export pass: `export_detected_frames` `665669 us`
  for five frames, `load_preview` `639072 us`, `rebate_dmin` `431103 us`,
  `auto_detect` `172900 us`, and first-use inverted preview production
  `76083 us` (`inverted_preview_f32_breakdown` manual mirror `123357 us`).
  Export and preview load are now close enough that the next larger target is
  repeated RGB TIFF page reads: `load_preview_breakdown` spends about
  `314019 us` in RGB page read and export spends about `325067 us` in
  `load_full_us` for the same scan. Scanner live timing remains blocked by
  SANE enumeration.
- The headless Process RGB page cache prototype is complete. The benchmark
  `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case process_rgb_page_cache_sequence`
  compared the current stateless preview + auto-detect + rebate + export
  sequence against one resident `loadRgbPageWithMetadataTimed` reused for quick
  preview, rebate Dmin, and no-IR/provided-Dmin export. It reported cached
  `1075616 us` versus baseline `2001858 us` (`1.861x`), cached RGB resident
  bytes `741120000`, cached load `325380 us`, cached RGB read `300145 us`,
  baseline repeated-load-ish time `1477842 us`, avoided read time
  `1152462 us`, baseline preview `677912 us` versus cached preview
  `229352 us`, baseline rebate `450573 us` versus cached rebate `65867 us`,
  baseline export `700209 us` versus cached export `300197 us`, and baseline
  export load `349356 us` versus cached export load `0 us`. Parity was exact:
  preview mismatches `0`, `dmin_max_abs=0.000000000000`, `export_max_abs=0`,
  `export_mismatches=0`, `metadata_equal=true`, and `file_set_equal=true`.
  This is not yet a native UI state cache; image-switch and stale-worker
  invalidation remain required before storing the resident page in UI state.
- The native Process cache-key contract is now explicit and test-covered in
  `src/ui/process_cache.zig`. Cache lookup is intentionally a general
  processing-result layer, not an undo-history mechanism: future undo/redo
  should store lightweight UI/config snapshots, and replaying a snapshot may
  benefit from cache hits. Keys are built from image path plus file metadata
  when available, the full active processing config including custom stock
  coefficients, and operation-specific state for RGB page, quick preview,
  auto-detect, rebate Dmin, inverted preview, and export outputs. Hashes can be
  used as the practical index for the small resident UI cache; the current key
  stores a compact 128-bit semantic fingerprint while keeping deterministic
  serialized key construction unit-tested for diagnostics and transparent
  fallback on misses. Direct `zig build test --summary all` passed `418/418`.
- Native Process quick-preview cache integration is complete. `State` now owns
  a bounded `ProcessResultCache`, and `ProcessWorker.startLoadIndex` checks the
  semantic quick-preview key before spawning image-load work. Hits install a
  cloned preview through the same accepted-result path as the worker; misses
  transparently run the existing computation and populate the cache only after
  generation/path ownership checks pass. Tests cover clone isolation, unchanged
  image hit/worker bypass, and processing-config mutation miss/fallback.
  Direct `zig build test --summary all` passed `421/421`. Full-resolution
  resident RGB-page storage remains a separate checkpoint because it needs an
  explicit memory budget and eviction policy.
- Native Process resident RGB-page caching is now wired into the worker layer.
  `RgbPageCache` has a 1 GiB default budget, two resident slots, resident-byte
  accounting, and LRU eviction; pages larger than the budget are rejected so
  callers fall back to the normal TIFF-load path. Accepted image-load workers
  move their loaded RGB page into the cache, later image loads can generate
  quick previews from a resident page clone, rebate/auto-detect Dmin workers
  can compute Dmin from the resident page, and export workers attempt
  `processExportFromCachedRgbPage` before falling back to `processExportFromTiff`
  for unsupported shapes. Direct `zig build test --summary all` passed
  `428/428`. The real-scan cache sequence benchmark
  `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case process_rgb_page_cache_sequence`
  reported cached `1120225 us` versus baseline `1932655 us`
  (`1.725x`), cached RGB bytes `741120000`, avoided read time `1056380 us`,
  preview `241429 us` versus `639922 us`, rebate `65228 us` versus
  `443560 us`, export `296899 us` versus `676540 us`, export load `0 us`
  versus `334072 us`, and exact parity for preview, Dmin, export pixels,
  metadata, and file set.
- The first derived-result cache is now wired for rebate Dmin. `DminCache`
  stores small `[3]f64` results under the same 128-bit semantic fingerprint
  contract, including image identity, full processing config state, and the
  full-resolution rebate rectangle. Repeated identical Dmin requests bypass the
  worker thread, persist `dmin` through `saveRebateDmin`, and apply state
  through the normal accepted generation/path path; misses run the existing
  worker. Accepted explicit rebate and auto-detect suggested-rebate results
  populate the cache after stale-result checks pass. Direct
  `zig build test --summary all` passed `432/432`.
- Native Process auto-detect result caching is now wired as the second
  derived-result cache. `AutoDetectCache` stores cloned frames, aspect,
  suggested rebate, full-resolution rebate, and optional Dmin under a key built
  from image identity, full processing config state, detection options, scale
  adjustment, output rotation, preview dimensions, and preview scale. Repeated
  identical Auto Detect requests replay through
  `applyProcessAutoDetectWorkerResult`, remember aspect, persist cached Dmin
  through `saveRebateDmin`, and avoid preview copying plus detector/Dmin worker
  execution. Misses run the existing worker. Direct
  `zig build test --summary all` passed `434/434`.
- Native Process inverted-preview result caching completes the derived-cache
  checkpoint. `InvertedPreviewCache` stores RGB8 preview outputs under a
  semantic key built from image identity, full processing config state, active
  stock, Dmin, render options, GPU request, preview dimensions, and preview
  scale. The SDL texture cache still uses its pointer/generation key only for
  current texture validity, while reusable RGB8 results live in
  `ProcessResultCache`. Direct `zig build test --summary all` passed
  `435/435`; direct `zig build -Dui=true --summary all` and dummy-SDL
  `zig build -Dui=true run-ui -- --process-render-smoke` passed. The real-scan
  benchmark
  `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case process_result_cache_repeat`
  reported baseline `701955 us`, cached `15230 us` (`46.090x`), auto-detect
  `179246 us` versus hit `0 us`, Dmin `447778 us` versus hit `0 us`, inverted
  preview `74930 us` versus hit `15229 us`, and exact replay parity:
  `auto_mismatches=0`, `dmin_max_abs=0.000000000000`, `inverted_max_abs=0`,
  `inverted_mismatches=0`, and matching inverted-preview checksums.
- `auto_detect` stage breakdown was added on 2026-05-19 as
  `auto_detect_breakdown`. The benchmark runs the normal production
  `workflow.autoDetectPreview` path and a staged
  `frames.detectFramesFromImageBreakdown` path on the same preview, then
  requires exact output parity. On `scan_0004_rgbir_3200dpi.tiff`, the command
  `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`
  reported total `729511 us`, reference `746645 us`, frames `5`, aspect
  `24:36`, checksum `38221731`, `frame_max_abs=0`, `rebate_max_abs=0`, and
  `mismatches=0`.
- Across `scan_0001` through `scan_0004` real 3200 DPI RGBIR scans, average
  `auto_detect_breakdown` timing was about `870938 us`: film extent
  `378610 us` (`43.5%`), CLAHE `189884 us` (`21.8%`), rotation `119234 us`
  (`13.7%`), grayscale prep `76250 us` (`8.8%`), and axis detection `80313 us`
  (`9.2%`). The axis sub-breakdown shows profiles and angle fitting dominate
  that smaller bucket; DTW, edge snap/repair, frame construction,
  rotation-back transform, and rebate postprocess are not current bottlenecks.
- Next `auto_detect` optimization should start by reducing duplicated
  grayscale preparation between film extent and CLAHE without changing
  behavior. The current route makes f64 grayscale from the preview, converts it
  back to thresholdable u8 for film extent, and converts it again to inverted
  u8 for CLAHE before returning f64. The optimization target is shared or
  fused production of those exact intermediate values while preserving the same
  Otsu threshold, binary close, largest component, rotated extent, CLAHE, and
  final frame/rebate output. If that does not explain enough of the film extent
  time, add a deeper `film_extent_breakdown` before changing contour/component
  implementation details.
- First `auto_detect` optimization pass is complete. The production path now
  retains the quantized u8 grayscale next to the f64 grayscale, uses exact
  integer quantization for 16-bit RGB grayscale, runs film extent directly from
  u8, combines CLAHE input quantization/inversion, uses a u8-to-f64 table,
  reworks binary close to row-major sliding windows, consumes the private
  component mask in place with a u32 queue when possible, uses partial Otsu
  histograms, precomputes row affine terms in rotation, and computes vertical
  cross profiles row-major. On `scan_0004_rgbir_3200dpi.tiff`, normal
  `auto_detect` improved from `765814 us` to `605658 us` with unchanged frames
  `5`, aspect `24:36`, and checksum `38221731`. The parity-checked
  `auto_detect_breakdown` improved from `729511 us` to `608397 us`
  (`1.199x`) with `frame_max_abs=0`, `rebate_max_abs=0`, and `mismatches=0`.
  Across `scan_0001` through `scan_0004`, average breakdown timing improved
  from `870938 us` to `682404 us` (`1.276x`). Updated average stage shares are
  film extent `36.1%`, CLAHE `25.5%`, rotation `17.8%`, grayscale prep `9.3%`,
  and axis detection `7.2%`.
- Second `auto_detect` optimization pass is complete. CLAHE now precomputes
  reflected border maps and per-axis interpolation maps, and it no longer
  materializes the padded extended image before histogram/LUT construction.
  Rotation now increments affine source coordinates across each row, and
  connected-component labeling avoids a redundant initial component-mask clear.
  On `scan_0004_rgbir_3200dpi.tiff`, normal `auto_detect` improved to
  `557439 us` with unchanged frames `5`, aspect `24:36`, and checksum
  `38221731`. The parity-checked `auto_detect_breakdown` improved to
  `541755 us` with `frame_max_abs=0`, `rebate_max_abs=0`, and `mismatches=0`;
  stage timings were film extent `179309 us`, rotation `127573 us`, CLAHE
  `117997 us`, grayscale prep `49138 us`, and axis detection `46501 us`.
  Across `scan_0001` through `scan_0004`, average breakdown timing is now
  `621128 us`, a `1.402x` speedup over the initial `870938 us` breakdown and a
  `1.099x` speedup over the first optimized pass. Updated average stage shares
  are film extent `38.0%`, CLAHE `22.0%`, rotation `16.8%`, grayscale prep
  `10.2%`, and axis detection `8.4%`. Next work should keep component/close,
  CLAHE internals, and rotation in scope, while continuing to take small
  pass-reduction wins with exact parity evidence.
- Third `auto_detect` optimization pass is complete. Connected-component
  flood fill now uses explicit 8-neighbor checks, large real-scan rotation and
  CLAHE output rows run in parallel, and scan-sized CLAHE conversion buffers
  (`f64 -> inverted u8`, `u8 -> inverted u8`, `u8 -> f64`) use the same
  thresholded worker pattern. On `scan_0004_rgbir_3200dpi.tiff`, normal
  `auto_detect` improved to `305134 us` with unchanged frames `5`, aspect
  `24:36`, and checksum `38221731`. The parity-checked
  `auto_detect_breakdown` improved to `277906 us` with `frame_max_abs=0`,
  `rebate_max_abs=0`, and `mismatches=0`; stage timings were film extent
  `129079 us`, grayscale prep `44826 us`, axis detection `37897 us`, CLAHE
  `31668 us`, and rotation `12272 us`. Across `scan_0001` through `scan_0004`,
  average breakdown timing is now `362798 us`, a `2.401x` speedup over the
  initial `870938 us` breakdown and a `1.712x` speedup over the second optimized
  pass. Updated average stage shares are film extent `48.0%`, grayscale prep
  `16.5%`, axis detection `14.1%`, CLAHE `9.9%`, and rotation `3.4%`. Next work
  should focus on film extent, exact 16-bit RGB grayscale prep, and axis-stage
  reductions before revisiting rotation or CLAHE.
- Fourth `auto_detect` optimization pass is complete. `prepareDetectionGrayImage`
  now fills the retained u8 and f64 grayscale buffers in thresholded parallel
  chunks for scan-sized previews, while preserving the exact Python grayscale
  quantization rules for 16-bit RGB, 8-bit RGB, and grayscale inputs. On
  `scan_0004_rgbir_3200dpi.tiff`, normal `auto_detect` improved to `275746 us`
  with unchanged frames `5`, aspect `24:36`, and checksum `38221731`. The
  parity-checked `auto_detect_breakdown` improved to `253750 us` with
  `frame_max_abs=0`, `rebate_max_abs=0`, and `mismatches=0`; stage timings were
  film extent `129155 us`, axis detection `45596 us`, CLAHE `33725 us`,
  rotation `11585 us`, and grayscale prep `8529 us`. Across `scan_0001` through
  `scan_0004`, average breakdown timing is now `313237 us`, a `2.780x` speedup
  over the initial `870938 us` breakdown and a `1.158x` speedup over the third
  optimized pass. Updated average stage shares are film extent `55.5%`, axis
  detection `16.2%`, CLAHE `11.5%`, rotation `3.8%`, and grayscale prep `3.5%`.
  Next work should focus on film extent close/component work, then axis-stage
  reductions.
- Fifth `auto_detect` optimization pass is complete. Scan-sized film extent now
  uses run-length 8-connected component labeling instead of per-pixel BFS,
  while small masks keep the BFS path. The run path encodes true-runs per row,
  unions adjacent-row runs whose ranges overlap or touch, preserves largest
  component tie behavior with a first row-major index, and materializes the same
  boolean component mask for rotated-extent geometry. A parallel binary-close
  attempt was tested and removed because it preserved parity but regressed the
  four-scan average. Angle-stage allocation churn was also reduced by reusing
  precomputed Gaussian kernels, scratch buffers, and contiguous gradient
  storage. On `scan_0004_rgbir_3200dpi.tiff`, normal `auto_detect` now reports
  `225901 us` with unchanged frames `5`, aspect `24:36`, and checksum
  `38221731`. The parity-checked `auto_detect_breakdown` reports `201144 us`
  with `frame_max_abs=0`, `rebate_max_abs=0`, and `mismatches=0`; stage timings
  were film extent `74999 us`, axis detection `46171 us`, CLAHE `33336 us`,
  rotation `11897 us`, and grayscale prep `8990 us`. Across `scan_0001` through
  `scan_0004`, average breakdown timing is now `244486 us`, a `3.562x` speedup
  over the initial `870938 us` breakdown and a `1.281x` speedup over the fourth
  optimized pass. Updated average stage shares are film extent `42.6%`, axis
  detection `20.4%`, CLAHE `14.3%`, rotation `5.0%`, and grayscale prep `4.5%`.
  Binary close is now the dominant film-extent substage at about `62839 us`;
  run-length component labeling averages about `7167 us`.
- Sixth `auto_detect` optimization pass is complete. Binary close now uses
  exact run-based horizontal dilation and erosion while keeping the same
  vertical rolling-count passes; horizontal dilation fills radius-expanded
  true-run ranges, and horizontal erosion fills only centers whose clipped
  window is contained inside a true-run. The 1D Gaussian helper now uses direct
  contiguous indexing for interior samples and reflect-101 only at edges, which
  benefits profile blur, angle estimation, cross-strip refinement, and gradient
  smoothing without changing kernel order. Vertical strip profile setup now uses
  segmented row loops that preserve cross-profile accumulation order while
  collecting the three non-overlapping band sums in the same row walk. On
  `scan_0004_rgbir_3200dpi.tiff`, normal `auto_detect` now reports `205658 us`
  with unchanged frames `5`, aspect `24:36`, and checksum `38221731`. The
  parity-checked `auto_detect_breakdown` reports `186829 us` with
  `frame_max_abs=0`, `rebate_max_abs=0`, and `mismatches=0`; stage timings were
  film extent `63997 us`, axis detection `37616 us`, CLAHE `34456 us`, rotation
  `12163 us`, and grayscale prep `9005 us`. Across `scan_0001` through
  `scan_0004`, average breakdown timing is now `221766 us`, a `3.927x` speedup
  over the initial `870938 us` breakdown and a `1.102x` speedup over the fifth
  optimized pass. Updated average stage shares are film extent `40.2%`, axis
  detection `18.7%`, CLAHE `16.2%`, rotation `5.6%`, and grayscale prep `5.0%`.
- Seventh `auto_detect` optimization pass is complete. Exact vertical run
  morphology was tested and rejected because strided column scans/writes made it
  slower than the rolling-count vertical passes despite exact parity. The
  accepted changes parallelize two independent work sets: scan-sized angle
  gradient construction now builds the 20 strip profiles/gradients in disjoint
  worker chunks, and CLAHE LUT construction now builds the 64 tile histograms
  and LUTs in disjoint tile ranges. Theil-Sen input order, per-tile histogram
  order, clipping, LUT math, Gaussian kernels, and reflect-101 behavior are
  unchanged. On `scan_0004_rgbir_3200dpi.tiff`, normal `auto_detect` now reports
  `176017 us` with unchanged frames `5`, aspect `24:36`, and checksum
  `38221731`. The four-scan refresh's parity-checked `auto_detect_breakdown`
  for `scan_0004` reports `179503 us` with `frame_max_abs=0`,
  `rebate_max_abs=0`, and `mismatches=0`; stage timings were film extent
  `73693 us`, axis detection `26697 us`, CLAHE `26063 us`, rotation `12009 us`,
  and grayscale prep `9377 us`. Across `scan_0001` through `scan_0004`, average
  breakdown timing is now `203021 us`, a `4.290x` speedup over the initial
  `870938 us` breakdown and a `1.092x` speedup over the sixth optimized pass.
  Updated average stage shares are film extent `45.0%`, axis detection `13.5%`,
  CLAHE `13.3%`, rotation `6.1%`, and grayscale prep `5.4%`.
- Eighth `auto_detect` optimization pass is complete. Portable Zig `@Vector`
  SIMD was tested on the clean independent loops. Accepted changes are an
  8-lane RGB16 grayscale-prep path, a 32-lane `u8` inversion path for
  non-rotated CLAHE prep, a 4-lane `u8 -> f64` conversion path after CLAHE, and
  a 4-lane f64 Gaussian-blur interior dot product. A direct SIMD rewrite of the
  vertical morphology count loops was rejected: it preserved exact parity but
  regressed `scan_0004` `film_close_us` to `52392 us`, so the scalar
  rolling-count vertical passes remain in place. On
  `scan_0004_rgbir_3200dpi.tiff`, normal `auto_detect` now reports `173351 us`
  with unchanged frames `5`, aspect `24:36`, and checksum `38221731`. The
  four-scan refresh's parity-checked `auto_detect_breakdown` row for
  `scan_0004` reports `166139 us` with `frame_max_abs=0`, `rebate_max_abs=0`,
  and `mismatches=0`; stage timings were film extent `73063 us`, axis detection
  `17675 us`, CLAHE `24361 us`, rotation `12393 us`, and grayscale prep
  `9306 us`. Across the currently present real scan files
  `scan_0001_rgbir_3200dpi.tiff` through `scan_0004_rgbir_3200dpi.tiff`, average
  breakdown timing is now `196084 us`, a `4.442x` speedup over the initial
  `870938 us` breakdown and a `1.035x` speedup over the seventh optimized pass.
  Updated average stage shares are film extent `47.4%`, axis detection `11.8%`,
  CLAHE `13.1%`, rotation `6.3%`, and grayscale prep `5.7%`.
- Ninth `auto_detect` optimization pass is complete. The DTW inner loop now
  computes the squared difference as `diff * diff` instead of calling the
  generic `pow(diff, 2.0)`, preserving the same DTW cost function with less
  hot-loop overhead. Film-extent geometry also preallocates boundary point
  storage from the component bounds before running the same convex
  hull/min-area-rectangle algorithm. On `scan_0004_rgbir_3200dpi.tiff`, the
  parity-checked `auto_detect_breakdown` moved from `detect_us=158824` to
  `detect_us=146591`, with frames `5`, aspect `24:36`, checksum `38221731`,
  `frame_max_abs=0`, `rebate_max_abs=0`, and `mismatches=0`. Stage timings in
  that accepted row were film extent `63202 us`, close `34028 us`, geometry
  `14917 us`, CLAHE `23061 us`, rotation `12167 us`, axis total `18017 us`,
  and DTW `1564 us`. A `scan_0003` spread check reported `detect_us=174011`,
  `axis_total_us=24037`, `dtw_us=9053`, and exact parity. The single normal
  `auto_detect` command on `scan_0004` measured `188485 us`, so use the staged
  breakdown rather than that noisy wall time to evaluate this small pass.

Completed fusion target:

- Coefficient-shape fast path: built-in Kodak Gold, Portra, and identity
  coefficients currently use only linear rows. `usesOnlyLinearTerms` detects
  exact zero quadratic/cross/bias rows and routes density transforms and fused
  SIMD inversion through a direct 3x3 multiply, while custom profiles with
  nonzero higher-order rows still use the general 10-term polynomial path.
- Preview render-to-u8: `renderInvertedPreviewRgb8` now calls
  `renderToDisplayU8`, which writes the preview `u8` display buffer directly
  and keeps exact fallback available for fixture-sized inputs and
  `percentile_sample_limit=0`.
- Preview robust range and display LUTs: large preview renders now estimate the
  robust luminance range from a deterministic f32 sample capped at 16k values
  and use a dynamic 256-entry preview display LUT. The exact path still exists
  for oracle checks. On `scan_0004_rgbir_3200dpi.tiff`, combined exact
  full-sort/full-curve preview render took `1335115 us`; the production
  16k-sample plus LUT path took `71011 us`, a `18.801x` speedup, with final
  preview bytes at `max_abs=1`, RMS `0.364`.
- Raw staging fusion: provided-Dmin preview inversion now calls
  `invertNegativeProvidedDminU16Simd` and avoids expanding the whole `u16`
  preview into a temporary `f64` raw buffer. On the same `scan_0004` preview,
  refreshed staged-f64 inversion took `453399 us`; direct-u16 inversion took
  `348303 us` with `max_abs=0`, a `1.301x` speedup for the inversion segment.
- Preview density LUT and f32 scene path: provided-Dmin CPU preview inversion now
  uses a dynamic per-channel `u16 -> net_density` f32 LUT and stores preview
  scene-linear data as f32. The f32 preview LUT is now also built from f32 Dmin
  values, while config/UI/oracle APIs still carry Dmin as f64. The exact f64
  SIMD and f64 LUT paths remain available for oracle comparisons and
  non-preview paths. On `scan_0004`,
  direct-u16 SIMD inversion took `345713 us`; f64 density LUT to f64 scene took
  `138229 us` with exact final `u8/u16`; accepted f32 density LUT to f32 scene
  took `74063 us` including LUT build, with preview `u8 max_abs=2`,
  `u8_mse=0.000004987`, export-shaped `u16 max_abs=1`,
  `u16_mse=0.001272631`. The f32-Dmin LUT variant measured `build_us=975`,
  `apply_us=65765`, final preview `u8 max_abs=2`, and `u8_mse=0.000010418`.
  Full `inverted_preview` with f32 Dmin LUT construction measured
  `production_us=130053` in the current mixed secondary-hotspot checkout.
- Preview f32 display index path: `renderToDisplayU8F32` now writes preview
  bytes with a channel-specific per-pixel loop and f32 table-index arithmetic.
  The exact f64-index table path remains in `inverted_preview_f32_breakdown` as
  a comparison surface. On `scan_0004`, production preview dropped from the
  accepted f32-density baseline of `146687 us` to `122313 us`; the output write
  stage measured `52157 us` versus `64246 us` for the exact f64-index write.
  The exact-index comparison was `max_abs=2`, RMS `0.002104`, MSE
  `0.000004425`, and `153` changed channel samples out of `42,713,088`.
- Parallel f32 preview display write: large `renderToDisplayU8F32` preview
  buffers now write disjoint pixel ranges across worker threads while keeping
  the same range estimate, LUT values, f32 table-index arithmetic, and u8
  quantization. On `scan_0004`, `inverted_preview_f32_breakdown` production
  time dropped from the refreshed `126523 us` baseline to `85910 us`; the
  serial manual mirror remained byte-identical with `max_abs=0`,
  `mismatches=0`, and checksum `3912224310`. The serial split still reported
  `invert_us=69018`, `range_us=1273`, and `output_write_us=50123`, so use
  production time for the parallel win and the manual split as the oracle
  comparison surface. `scan_0003` refreshed at `84269 us` production with exact
  production-vs-manual bytes and checksum `3387841946`.
- Quick preview load waste: `generateQuickPreview` computes preview geometry in
  Zig and normally calls the OpenCV preview builder once instead of running
  resize/stretch/CLAHE/JPEG once to discover JPEG length and then again to fill
  buffers. `loadQuickPreview` now opens the TIFF once for DPI, RGB pixels, and
  IR metadata, instead of separate metadata/page reads or reading full IR data
  just to set UI state. The OpenCV stretch helper now replaces per-channel
  content-pixel vectors plus `std::sort` with exact 256-bin u8 histograms using
  the same NumPy linear percentile rank/interpolation formula, and it stretches
  the interleaved RGB rows directly before the unchanged CLAHE/JPEG stages. On
  `scan_0004`, cumulative `load_preview` improved from the older
  `2255972 us` two-pass/full-IR baseline to `647912 us`, with unchanged
  checksum `6666414344`, a `3.482x` speedup. Against the fresh same-turn
  `1338976 us` baseline, this breakdown pass is `2.066x` faster. Final
  `load_preview_breakdown` on the same scan reported `rgb_read_us=312098`,
  `quick_preview_us=267162`, `invert_stretch_us=66142`, `clahe_us=57794`, and
  exact staged-vs-production raw/RGB/JPEG parity with `mismatches=0`.
- Quick preview stretch pass fusion: `stretch_content_percentiles` now builds
  all three masked RGB histograms in one preview walk and applies all active
  channel stretches in one preview walk. This preserves the exact
  channel-independent NumPy percentile/truncation behavior while avoiding
  separate full-image passes per channel. On `scan_0004`,
  `load_preview_breakdown` moved from total `586596 us` with
  `invert_stretch_us=65809` to total `576577 us` with
  `invert_stretch_us=54955`; raw/RGB/JPEG outputs stayed byte-identical with
  `mismatches=0`.
- Full-resolution detected-frame export waste: `export_detected_frames_breakdown`
  now times the existing export workflow and compares timed output against an
  untimed reference by file set, private metadata JSON, and TIFF pixels. The
  first breakdown on `scan_0004_rgbir_3200dpi.tiff` measured timed
  `4309330 us`, reference `4326493 us`, `load_full_us=1382038`,
  `frame_processing_us=2775287`, and aggregate worker `rgb_crop_us=9537480`.
  `cropFrame` now samples the interleaved RGB image directly with the same
  rotated-rect, reflect-border, and bilinear math instead of materializing a
  full-image plane per channel. RGB-only exports now avoid the RGB+IR page
  loader, and large TIFF sample-to-f64 expansion runs in disjoint chunks. Final
  `scan_0004` production `export_detected_frames` is `1820484 us`, versus the
  previous `4138270 us` refresh (`2.274x`) and older `5981208 us` parallel
  baseline (`3.286x`). Final breakdown reported timed `1758568 us`,
  reference `1819796 us`, `load_full_us=614686`,
  `frame_processing_us=995968`, aggregate `rgb_crop_us=959419`,
  `inversion_us=1730664`, `display_render_us=684521`, `write_us=571604`,
  `workers=5`, adjusted peak `2159506560` bytes/worker, and exact parity
  (`max_abs=0`, `mismatches=0`, `metadata_equal=true`,
  `file_set_equal=true`).
- Export no-op rotation waste: Python `apply_rotation` returns the original
  image for rotation values other than `90`, `180`, and `270`. The Zig u16
  export path now mirrors that ownership behavior by returning the rendered
  `u16` buffer directly when the frame rotation is a no-op instead of
  allocating and copying a second full image through `applyRotationU16`. On
  `scan_0004_rgbir_3200dpi.tiff`, refreshed
  `export_detected_frames_breakdown` moved from `1625129 us` to `1569086 us`,
  with aggregate `output_rotation_us` dropping from `193710` to `0`; file set,
  private metadata, and pixels remained exact (`max_abs=0`,
  `mismatches=0`). A `scan_0003_rgbir_3200dpi.tiff` spread check reported
  `1442871 us` with the same exact parity. The refreshed normal production
  `export_detected_frames` command on `scan_0004` reported `1539625 us`,
  `workers=5`, serial `4193699 us`, parallel speedup `2.723x`, and checksum
  `18880`.
- No-IR/provided-Dmin export staging: the common detected-frame `inv_only`
  export path now avoids full-scan `f64` materialization. When no IR output is
  selected and Dmin is already provided, `processExportFromTiff` loads only the
  raw RGB TIFF page plus metadata, crops each frame directly from TIFF samples,
  and then processes the cropped frame. The direct TIFF crop preserves the
  same rotated-rect, reflect-border, and bilinear math; the existing unit test
  compares it exactly against full-image f64 cropping. The crop loop was also
  reduced to compute reflect indices and bilinear weights once per output
  pixel and sample all RGB channels together. On `scan_0004`,
  `export_detected_frames_breakdown` compared the direct-crop route against a
  no-direct-crop reference and reported timed `1280965 us`, reference
  `1567751 us`, `load_full_us=331018`, `frame_processing_us=905791`,
  aggregate `rgb_crop_us=1045899`, and exact TIFF/metadata parity. The normal
  production command measured `1279140 us`.
- Full-resolution export f32 density-LUT path: provided-Dmin CPU export now
  uses the same accepted f32 density-LUT idea as preview, but only for the safe
  default-light/no-dark/no-light CPU path with linear stock coefficients. A
  benchmark-only tradeoff case keeps the f64 helper as reference and pushes the
  comparison through final `u16`: on `scan_0004`, f64 reference was
  `484129 us`, f32 LUT export was `227450 us` (`2.128x`), with `max_abs=1`,
  RMS `0.054239`, MSE `0.002941895`; on `scan_0003`, f64 reference was
  `456660 us`, f32 LUT export was `219494 us` (`2.080x`), with `max_abs=1`,
  RMS `0.052345`, MSE `0.002740004`. After production integration,
  `export_detected_frames_breakdown` on `scan_0004` reported timed
  `997165 us`, no-direct-crop reference `1273769 us`, `load_full_us=322084`,
  `frame_processing_us=635082`, aggregate `rgb_crop_us=1055382`,
  `inversion_us=628417`, `display_render_us=560723`, `write_us=419987`, and
  exact direct-crop-vs-no-direct-crop output parity. The normal
  `export_detected_frames` command reported `1009255 us`, serial `2843707 us`,
  five workers, and checksum `18950`. The `scan_0003` spread check reported
  timed `926099 us`, reference `1165373 us`, and exact parity.
- Fused direct TIFF crop to f32 scene: after the safe f32 export path landed,
  the direct no-IR/provided-Dmin route still materialized a full f64 crop and
  immediately interpolated it into a f32 density-LUT scene. The fused route
  keeps the same guarded conditions, reflect-border bilinear sampler, linear
  coefficient gating, metadata, filenames, and f64/no-direct benchmark
  reference, but writes the f32 scene directly from TIFF samples. On
  `scan_0004`, `export_detected_frames_breakdown` reported timed `893305 us`,
  no-direct reference `1278393 us`, `load_full_us=336646`,
  `frame_processing_us=510911`, aggregate fused `inversion_us=1474796`,
  `display_render_us=561146`, `write_us=285799`, `rgb_crop_us=0`, and exact
  TIFF/metadata parity. The normal `export_detected_frames` command reported
  `883583 us`, serial `2587911 us`, five workers, and checksum `18940`. The
  `scan_0003` spread check reported timed `826455 us`, reference `1172728 us`,
  and exact parity.
- Nested fused export scene parallelism: the fused direct crop-to-f32-scene
  loop is now row-parallel inside each frame when the outer export worker plan
  has spare CPU budget. The nested worker count is derived from
  `cpu_worker_limit / frame_worker_count`, so the current five-frame export
  uses more cores without hardcoding parallelism; small crops and unsupported
  fast-path conditions keep the serial/fallback paths. On `scan_0004`,
  `export_detected_frames_breakdown` reported timed `665289 us`, no-direct
  reference `1276807 us`, `load_full_us=325067`,
  `frame_processing_us=297149`, aggregate fused `inversion_us=368390`,
  `display_render_us=561994`, `write_us=293486`, and exact TIFF/metadata
  parity. The normal command reported `665669 us`, serial `2442106 us`, five
  workers, and checksum `18875`. The `scan_0003` spread check reported timed
  `608411 us`, reference `1150193 us`, and exact parity.
- Rebate Dmin crop waste: `computeRebateDminFromTiff` now crops the rotated
  rebate directly from the TIFF RGB sample buffer and materializes f64 only for
  the rebate crop. This avoids converting the entire scan to f64 before
  cropping a narrow rebate strip. On `scan_0004`, `rebate_dmin` improved from
  `2396746 us` to `448352 us`, a `5.346x` speedup, with unchanged Dmin
  `0.283915:0.422373:0.606312`.
- Export u16 pipeline: inverted-positive export now uses
  `prepareInvertedPositiveOutputU16`, `applyRotationU16`, and direct TIFF writes
  from `u16` display samples. This removes the display-valued `f64` widening,
  f64 rotation, and write-time narrowing after `renderToDisplay`. On the
  `scan_0004` full-resolution crop, old helper timing was `2184971 us`; direct
  u16 helper timing was `1976225 us` with `max_abs=0`, a `1.105x` speedup.
- Per-frame export parallelism: Python `handle_export` uses independent frame
  jobs and completion-order collection through `ThreadPoolExecutor`. Zig keeps
  that job boundary but replaces the fixed Python max-4 cap with a dynamic
  scheduler: worker count is limited by selected frame count, available cores
  minus one, and a predicted per-worker memory peak checked against Linux
  `MemAvailable`. Worker jobs now use a freeing allocator instead of retaining
  all temporary image buffers in a per-job arena. On `scan_0004`, automatic
  frame detection produced 5 full-resolution frames; the scheduler selected 5
  workers (`cpu_limit=31`, `mem_limit=25`, adjusted peak about 2.16 GB/worker),
  serial export took `18125889 us`, and parallel export took `5981208 us`, a
  `3.030x` speedup.
- Full RGB+IR export baseline: `export_detected_frames_ir_all_breakdown` now
  times the path that the optimized no-IR benchmark intentionally skips. It runs
  automatic frame detection on a real RGBIR scan, scales detected frames to full
  resolution, enables all three Python output variants (`ir_neg`, `ir_inv`,
  `inv_only`), enables IR alignment, and reports the existing workflow/frame
  timings. On `scan_0004_rgbir_3200dpi.tiff`, the command
  `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
  detected 5 frames, exported 15 files, selected 5 workers (`cpu_limit=31`,
  `mem_limit=12`, adjusted peak `4592713860` bytes/worker), and reported wall
  time `190808106 us`. Top-level timings were `load_full_us=599856`,
  `ir_align_us=1673798`, and `frame_processing_us=188211285`. Aggregate worker
  timings, summed across parallel frame workers, were `rgb_crop_us=905109`,
  `ir_crop_us=437284`, `ir_clean_us=787208607`, `ir_neg_prepare_us=718080`,
  `inversion_us=1246442`, `display_render_us=1134027`, `metadata_us=555`, and
  `write_us=1029704`. The next optimization target is not yet a replacement
  algorithm; it is a deeper `ir_clean` breakdown that separates defect-mask
  construction, Meijering line response, morphology/component filtering,
  RGB-mask resize/dilate, ROI traversal, local grain estimation, biharmonic
  solve, grain synthesis, and masked writeback.
- Full RGB+IR `ir_clean` substage baseline: the same large-scan benchmark now
  surfaces the IR-cleaning substages. On `scan_0004_rgbir_3200dpi.tiff`, the
  refreshed command reported wall time `190718657 us`, 5 detected frames, 15
  files, and 5 workers. Aggregate worker timing was `ir_clean_us=785563995`,
  dominated by defect-mask construction at `ir_defect_mask_us=778452492`.
  Within that mask path, `ir_adaptive_dust_us=635418409`,
  `ir_close_us=85680031`, `ir_dilate_us=40233518`,
  `ir_line_detection_us=16917340`, and `ir_meijering_us=16403513`. Inpainting
  was much smaller on this data: `ir_inpaint_total_us=6501771`, split into
  `ir_biharmonic_us=2270265`, `ir_grain_synthesis_us=1831843`,
  `ir_local_grain_us=1200286`, `ir_inpaint_label_us=265199`, and
  `ir_inpaint_noise_us=198929`. This makes the next concrete optimization target
  adaptive dust-mask construction, especially its repeated large Gaussian blur
  and full-frame pass structure. Mask close/dilate morphology is second. The
  native Meijering port is visible but not the dominant cost, and biharmonic
  inpainting should not be optimized first based on this real-scan profile.
- Adaptive dust Gaussian interior optimization: `gaussianBlur` now preserves the
  same Python-parity kernel, separable pass order, f64 accumulation, and
  reflect-101 boundary behavior while skipping per-sample reflect-index work for
  horizontal and vertical interior pixels. The required large-scan command
  `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
  reported wall time `159440683 us`, 5 detected frames, 15 files, and 5 workers.
  Compared with the immediately preceding substage baseline, wall time improved
  from `190718657 us` to `159440683 us` (`1.196x`), `ir_clean_us` from
  `785563995` to `718263872` (`1.094x`), `ir_defect_mask_us` from `778452492`
  to `711082383` (`1.095x`), and `ir_adaptive_dust_us` from `635418409` to
  `557917334` (`1.139x`). This pass did not change Meijering, morphology,
  inpainting, output selection, or Python-visible behavior. The largest
  remaining measured buckets are still adaptive dust construction
  (`557917334 us`) and binary morphology (`ir_close_us=93476919`,
  `ir_dilate_us=42286263`).
- Adaptive dust f32 precision evaluation: f32 intermediates are now available as
  an explicit non-default path through `AdaptiveDustPrecision`, while the
  production config remains f64 because full parallel export wall time did not
  improve. The targeted benchmark
  `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case ir_adaptive_dust_f32_tradeoff`
  compared f64 and f32 on one automatically detected `3063x4600` full-resolution
  IR crop (`14089800` pixels). f32 reduced mask time from `136109894 us` to
  `112945584 us` (`1.205x`) and adaptive-dust time from `107138353 us` to
  `83793576 us` (`1.279x`). Final binary-mask drift was small in area but not
  zero: `15054` mismatched pixels (`0.107%`), defect pixels changed from
  `170799` to `182329`, mask max abs was `255`, RMS `8.335156`, and MSE
  `69.474822`. A production trial then ran the full RGB+IR export with f32
  enabled: wall times were `165267646 us` and `163784775 us`, versus a current
  f64 reference of `159448976 us`. Aggregate worker substages did improve
  (`ir_adaptive_dust_us` `557821104` to `540898167`/`539335673`; `ir_clean_us`
  `716107372` to `697968369`/`696632356`), but the slowest-worker wall time
  regressed. The next f32 work should focus on f32-specific loop fusion, SIMD,
  or worker scheduling before promotion.
- IR mask morphology ellipse-row spans: `dilateMask` and `erodeMask` now
  precompute active x-ranges for each ellipse kernel row and iterate those spans
  instead of scanning every cell in the dense boolean bounding box. The geometry
  test verifies the spans match dense kernels for radii `0`, `1`, `2`, `4`,
  `16`, and `24`, preserving the existing border clipping and binary output
  semantics. On the full RGB+IR export benchmark
  `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`,
  wall time improved from the current f64 reference `159448976 us` to
  `144076086 us` (`1.107x`). Aggregate worker timings improved as follows:
  `ir_clean_us` `716107372` to `636850277` (`1.124x`),
  `ir_defect_mask_us` `708843297` to `629591097` (`1.126x`),
  `ir_close_us` `91518424` to `36048515` (`2.539x`), and `ir_dilate_us`
  `42157517` to `18597569` (`2.267x`). The remaining dominant bucket is still
  adaptive dust construction at `ir_adaptive_dust_us=557736885`.
- Adaptive dust coarse-mask writeback fusion: the f64 production path and f32
  experimental path now write the cleaned IR staging buffer during the first
  coarse-threshold pass, removing the temporary full-size boolean `coarse_mask`
  allocation and separate duplicate/writeback pass. This preserves the same
  threshold arithmetic, Gaussian calls, production f64 precision, and final
  mask/sigma formulas. On the same full RGB+IR export benchmark, wall time moved
  from the row-span result `144076086 us` to `143598455 us` (`1.003x`), while
  aggregate worker timings were essentially neutral: `ir_clean_us=637732625`,
  `ir_defect_mask_us=630417030`, and `ir_adaptive_dust_us=558328648`. Keep this
  as memory-pressure cleanup, not as a material speed win. Future IR f32 or
  approximate fast paths should be judged by final mask/export error and
  end-to-end wall-clock improvement, not by intermediate byte equality.
- Full-export f32 final-output tradeoff: the dedicated benchmark
  `export_detected_frames_ir_f32_tradeoff` now forces the same detected RGB+IR
  export through f64 and f32 adaptive dust, then compares final TIFF pixels and
  metadata. On `scan_0004_rgbir_3200dpi.tiff`, f32 improved aggregate worker
  substages (`ir_clean_us=638415641 -> 617929999`,
  `ir_defect_mask_us=631029883 -> 610858126`, and
  `ir_adaptive_dust_us=558880229 -> 538774812`) but regressed full-export wall
  time from `143882065 us` to `148260825 us` (`0.970x`). Final export error was
  too large for the new tolerance policy: `max_abs=27825`, RMS `105.251609`,
  MSE `11077.901284`, `65843162` mismatched samples, and mismatch rate
  `10.407%`, with metadata and file sets equal. Do not promote the current f32
  adaptive-dust path. The next useful IR pass is exact or carefully
  final-output-checked optimization of the remaining f64 Gaussian/pass
  structure.
- f64 adaptive-dust Gaussian symmetry: a scratch/output reuse attempt was
  measured and rejected first. It preserved tests but regressed the full
  benchmark to `174015799 us` wall without inlining and `149925086 us` wall
  with an inline helper, versus the accepted pre-item baseline `143598455 us`.
  The accepted optimization keeps the f64 production path and odd-kernel
  reflect-101 semantics, but uses the Gaussian kernel's symmetry so each pixel
  evaluates the center sample plus paired left/right or top/bottom samples
  instead of all 301 taps independently. `zig build test --summary all` passed
  `436/436`, including exact Python IR threshold/mask/full-clean fixtures. On
  `scan_0004_rgbir_3200dpi.tiff`, the full RGB+IR export benchmark improved
  wall time from `143598455 us` to `115466073 us` (`1.244x`), `ir_clean_us`
  from `637732625` to `501935111` (`1.271x`), `ir_defect_mask_us` from
  `630417030` to `494646364` (`1.275x`), and `ir_adaptive_dust_us` from
  `558328648` to `414778748` (`1.346x`). The next pass should re-rank the
  remaining RGB+IR export buckets from this new baseline before selecting more
  work.
- Post-symmetric RGB+IR hotspot ranking: the new
  `export_detected_frames_ir_all_breakdown` baseline on `scan_0004` is
  `115466073 us` wall with five workers. Aggregate worker time is still led by
  adaptive dust at `ir_adaptive_dust_us=414778748`. The next visible buckets
  are morphology (`ir_close_us=42261132`, `ir_dilate_us=20326471`), line
  detection (`ir_line_detection_us=17074953`, mostly
  `ir_meijering_us=16561774`), and inpainting (`ir_inpaint_total_us=6689753`).
  Non-IR export work is much smaller in this profile:
  `inversion_us=1266442`, `display_render_us=1164135`, `write_us=1091038`,
  `rgb_crop_us=970976`, and `ir_neg_prepare_us=704631`. Continue with f64
  adaptive-dust Gaussian inner-loop optimization before moving to morphology or
  Meijering, because adaptive dust remains roughly 6.6x larger than close and
  dilate combined.
- f64 symmetric Gaussian pair-weight hoist: inline helper extraction plus a
  four-step unroll was measured and rejected first because it regressed the
  full benchmark to `135528031 us` wall and
  `ir_adaptive_dust_us=462300729`. The accepted cleanup hoists the center
  weight and positive-side pair-weight slice out of the hot pixel loops, keeping
  the same f64 symmetric-pair operation and final masks. `zig build test
  --summary all` passed `436/436`. On the full RGB+IR export benchmark, wall
  time improved from `115466073 us` to `112640045 us` (`1.025x`),
  `ir_clean_us` from `501935111` to `489493295` (`1.025x`),
  `ir_defect_mask_us` from `494646364` to `482300081` (`1.026x`), and
  `ir_adaptive_dust_us` from `414778748` to `410319185` (`1.011x`).
- Post-pair-weight RGB+IR hotspot ranking: the new full-export baseline is
  `112640045 us` wall with five frame workers. Adaptive dust remains dominant
  at `ir_adaptive_dust_us=410319185`. The next largest groups are morphology
  close+dilate (`36017015 + 18620195 = 54637210`), line detection
  (`17137935`, mostly `ir_meijering_us=16565769`), and inpainting
  (`6586451`). Non-IR/export overhead is around one millisecond per aggregate
  bucket. Because adaptive dust is still about `7.51x` larger than close and
  dilate combined, the next adaptive-dust candidate should be dynamic
  intra-frame parallelism for the large f64 Gaussian passes. Any worker count
  must be derived from available cores and active outer frame workers, leaving
  at least one core free; do not introduce fixed four-thread parallelism.
- Dynamic f64 adaptive-dust Gaussian row parallelism: the export workflow now
  derives an inner adaptive-dust worker count from the accepted outer export
  scheduler: use the CPU worker limit that already leaves one core free, divide
  it by the active frame-export worker count, and fall back to one worker when
  the context or image size is too small. `gaussianBlur` keeps the same f64
  kernel, reflect-101 boundaries, symmetric pair accumulation, and horizontal-
  then-vertical pass order, but computes coarse row ranges in parallel for
  large crops. `zig build test --summary all` passed `437/437`, including a
  focused f64 Gaussian single-thread-vs-parallel equality test. On
  `scan_0004_rgbir_3200dpi.tiff`,
  `export_detected_frames_ir_all_breakdown` selected five outer workers and
  six inner adaptive workers. Wall time improved from `112640045 us` to
  `66473821 us` (`1.695x`), `ir_clean_us` from `489493295` to `290608197`
  (`1.684x`), `ir_defect_mask_us` from `482300081` to `283388034`
  (`1.702x`), and `ir_adaptive_dust_us` from `410319185` to `208921810`
  (`1.964x`). The remaining ranked buckets are adaptive dust
  `208921810`, morphology close+dilate `55783879`, line detection
  `18467284`, and inpainting `6616422`.
- Residual adaptive-dust substage breakdown: after adding read-only timing for
  the accepted dynamic f64 path, `export_detected_frames_ir_all_breakdown` on
  `scan_0004` reported wall `64864199 us`, five outer workers, and six inner
  adaptive workers. The residual `ir_adaptive_dust_us=198285318` is still
  dominated by the four Gaussian calls: first background `61186856`, first
  squared buffer `55810809`, second background `46629868`, and second squared
  buffer `32446593`, totaling `196074126 us`. The surrounding passes are much
  smaller: normalization `310776`, first square fill `334140`, coarse
  replacement `587349`, second square fill `82847`, and final mask/sigma
  `575032`. Morphology close+dilate is `56057837`, so residual adaptive
  Gaussian work is still about `3.50x` larger; the next same-behavior target is
  exact paired Gaussian processing for same-kernel background/square blur pairs
  before switching to morphology.
- Rejected exact paired Gaussian attempt: an exact helper that computed
  `ir_f`/`ir_f^2` and `ir_cleaned`/`ir_cleaned^2` in paired two-output
  Gaussian passes passed `zig build test --summary all` with `438/438`,
  including f64 equality against two separate `gaussianBlur` calls. It
  regressed the real-scan export benchmark, so it was removed. The paired run
  reported wall `73487216 us`, `ir_clean_us=303816205`,
  `ir_defect_mask_us=296420226`, `ir_adaptive_dust_us=222767894`,
  `ir_adaptive_pair1_us=137515218`, and `ir_adaptive_pair2_us=83670512`,
  versus the substage baseline wall `64864199 us` and
  `ir_adaptive_dust_us=198285318`. After reverting the paired helper, `zig
  build test --summary all` returned to `437/437`, and the full benchmark
  reported wall `65905071 us` with `ir_adaptive_dust_us=204580083`.
  Continue from the exact separate-Gaussian path; the next target should be
  dynamic worker-count/cache-locality tuning before returning to morphology.
- Adaptive Gaussian worker-count tradeoff: `export_detected_frames_ir_worker_tradeoff`
  keeps the same f64 algorithm and compares only inner row-parallel worker
  scheduling on the detected `scan_0004` RGB+IR export. The dynamic production
  heuristic chose six inner workers and reported wall `65653063 us`,
  `ir_clean_us=286266156`, `ir_defect_mask_us=279106694`, and
  `ir_adaptive_dust_us=205512992`. Forced single-inner-worker execution was
  exact at the output surface but much slower: wall `113133809 us`,
  `ir_adaptive_dust_us=411079599`, and `0.580x` dynamic wall speed. Forced
  three-inner-worker execution was also exact but still slower: wall
  `71395103 us`, `ir_adaptive_dust_us=217415105`, and `0.919x` dynamic wall
  speed. The override comparisons reported `max_abs=0`, RMS `0.000000`,
  `mismatches=0`, `metadata_equal=true`, and `file_set_equal=true`. Keep the
  current dynamic `cpu_worker_limit / outer_worker_count` heuristic for this
  workload; lower inner worker counts reduce scheduling pressure but lose
  throughput on the dominant Gaussian passes.
- f64 Gaussian row-interior SIMD: the accepted f64 adaptive Gaussian path now
  processes contiguous row interiors four columns at a time while keeping
  scalar boundary and tail fallbacks. This preserves the same reflect-101
  boundaries, center/pair weights, pass order, and per-lane symmetric pair
  accumulation. Direct `zig build test --summary all` passed `438/438`. On
  `scan_0004`, `export_detected_frames_ir_all_breakdown` improved wall time
  from the dynamic-worker baseline `65653063 us` to `61361504 us` (`1.070x`)
  and aggregate `ir_adaptive_dust_us` from `205512992` to `194511415`
  (`1.057x`). The post-SIMD Gaussian substages were first background
  `56498296`, first squared blur `56819666`, second background `45540430`,
  and second squared blur `33386281`. This is a modest accepted same-behavior
  win; residual adaptive Gaussian remains the largest bucket, with morphology
  close+dilate still the next visible secondary bucket.
- Post-SIMD RGB+IR export re-rank: the latest `scan_0004`
  `export_detected_frames_ir_all_breakdown` ranks aggregate worker buckets as
  adaptive dust `194511415`, morphology close+dilate
  `36813481 + 18857556 = 55671037`, line detection `18165612` including
  Meijering `17636531`, inpainting `6501227`, crop/IR negative prep about
  `2123461`, inversion `1236476`, display render `1131678`, and write
  `997421`. Residual adaptive Gaussian is still largest, but recent exact local
  Gaussian attempts are producing smaller wins or regressions. The next
  secondary checkpoint should target exact morphology close/dilate acceleration
  while preserving the accepted ellipse row-span geometry and mask semantics.
- Sliding-window morphology: `dilateMask` and `erodeMask` now preserve the same
  ellipse row-span geometry and border clipping but replace per-output-pixel
  span rescans with exact sliding horizontal windows per valid source row/span.
  Scalar reference implementations remain in tests. Direct `zig build test
  --summary all` passed `439/439`, including radii `0`, `1`, `2`, `4`, and `6`
  comparisons against the reference on an edge-heavy sparse mask. On `scan_0004`,
  `export_detected_frames_ir_all_breakdown` improved wall time from the
  post-Gaussian-SIMD baseline `61361504 us` to `56971107 us` (`1.077x`),
  close+dilate from `36813481 + 18857556 = 55671037` to
  `22107579 + 7205414 = 29312993` (`1.899x`), and `ir_defect_mask_us` from
  `268555723` to `245276844` (`1.095x`). Accept this exact morphology
  acceleration.
- Post-morphology re-rank: after sliding-window morphology, the remaining
  aggregate worker buckets on `scan_0004` are adaptive dust `198356313`,
  morphology close+dilate `29312993`, line detection `17409612` including
  Meijering `16883452`, inpainting `6577417`, crop/IR negative prep about
  `2010986`, inversion `1244581`, display render `1137729`, and write
  `1040920`. The next unexamined f64-heavy secondary path is Meijering line
  response. Evaluate f32/SIMD variants there with mask and final-export
  comparison before promotion; keep more invasive bitset morphology and
  approximate adaptive Gaussian work as later candidates.
- Meijering f64 SIMD: the line-response path now keeps f64 precision and the
  SciPy-shaped kernels, but vectorizes Gaussian filter-axis work over
  contiguous columns while retaining scalar edge/tail handling and reflect-index
  boundaries. Scalar reference functions remain available for tests and
  benchmarks. Direct `zig build test --summary all` passed `441/441`. Focused
  `ir_meijering_simd_tradeoff` on a detected `3063x4600` `scan_0004` crop
  reported exact mask equality against scalar reference (`max_abs=0`, RMS
  `0.000000`, MSE `0.000000`, `mismatches=0`, defect delta `0`) while reducing
  line detection from `3152980` to `1024918 us` (`3.076x`) and Meijering from
  `3046428` to `916660 us` (`3.323x`). Full `export_detected_frames_ir_all_breakdown`
  reported wall `55067434 us`, `ir_line_detection_us=6991369`, and
  `ir_meijering_us=6406495`, improving over the post-morphology baseline wall
  `56971107 us`, line detection `17409612`, and Meijering `16883452`. Accept
  exact f64 SIMD here; defer f32 Meijering unless this path becomes material
  again.
- Post-Meijering re-rank: latest full `export_detected_frames_ir_all_breakdown`
  on `scan_0004` reported wall `55067434 us`, aggregate adaptive dust
  `203868883`, morphology close+dilate `22369387 + 7170575 = 29539962`, line
  detection `6991369` including Meijering `6406495`, inpainting `6655521`,
  crop/IR negative prep about `2018525`, inversion `1245229`, display render
  `1133825`, and write `1001051`. Adaptive dust is now about `6.90x` larger
  than close+dilate and about `29.16x` larger than line detection. Return to
  adaptive dust next, specifically by making the existing f32 candidate a fair
  comparison: its Gaussian blur path currently lags the f64 path's accepted
  parallel/SIMD work, while the Python oracle itself uses `float32` for this
  calculation. Judge any promotion from focused mask metrics and full final
  TIFF export metrics, not from intermediate floating-point differences.
- Adaptive dust f32 Gaussian promotion: the f32 adaptive-dust path now uses the
  same optimization class as f64 for Gaussian blur: odd-kernel pair weights,
  reflect-101 scalar boundaries, contiguous SIMD interiors, scalar tails, and
  the same adaptive inner worker count. Since the Python oracle uses
  `float32` for this detector, f32 is now the production default while f64
  remains available as the reference override. Direct `zig build test --summary
  all` passed `442/442`. Focused `ir_adaptive_dust_f32_tradeoff` on a detected
  `3063x4600` `scan_0004` crop reported `reference_us=41730250`, `f32_us=26637777`
  (`1.566x`), `ref_adaptive_us=34786235`, `f32_adaptive_us=19682661`, and
  mask-area overlap of intersection `170433`, union `185831`, IoU `91.713%`,
  reference area retained `99.785%`, f32 area confirmed `91.894%`, and Dice
  `95.677%`. Treat those shared-area values, not raw binary-pixel mismatch
  counts, as the detector-quality evidence. Full `export_detected_frames_ir_f32_tradeoff`
  reported f64 reference wall `53259036 us`, f32 wall `30311036 us` (`1.757x`),
  `reference_ir_adaptive_dust_us=187612329`, `f32_ir_adaptive_dust_us=81431700`,
  metadata/file-set equality, final TIFF RMS `110.633142` on a 16-bit scale,
  and `abs_gt_4096=85657` of about `632.7M` final samples. The final-image
  deltas are local inpainting consequences of changed detector area and are
  secondary to mask-area overlap for this decision. Refreshed f32-default
  `export_detected_frames_ir_all_breakdown` reported wall `30366888 us`,
  `ir_clean_us=127446236`, `ir_defect_mask_us=119817222`,
  `ir_adaptive_dust_us=83048463`, `ir_close_us=22715193`,
  `ir_dilate_us=7640539`, `ir_line_detection_us=6192776`, and
  `ir_inpaint_total_us=6992917`, a `1.814x` wall-time improvement over the
  preceding f64-default `55067434 us`.
- Post-f32-promotion re-rank: with f32 adaptive dust as the default, remaining
  aggregate worker buckets on `scan_0004` are adaptive dust `83048463`,
  morphology close+dilate `22715193 + 7640539 = 30355732`, inpainting
  `6992917`, line detection `6192776` including Meijering `5649074`, crop/IR
  negative prep about `2101692`, inversion `1263675`, display render
  `1137713`, and write `1067462`. Adaptive dust remains the largest bucket but
  is now only about `2.74x` larger than close+dilate. The next performance
  target is remaining adaptive Gaussian pass count and approximation work,
  using mask-area overlap as the primary acceptance gate for detector changes.
- Adaptive dust blur-size approximation sweep: exact pass-count reduction is
  not available from the current Python-shaped formula because the first
  background/squared passes define the coarse mask and the second
  background/squared passes run on the coarse-cleaned IR to define final
  `n_sigma2`. Reusing or dropping any of those passes changes the detector.
  A benchmark-only `ir_adaptive_dust_blur_tradeoff` now sweeps lower effective
  f32 blur sizes while preserving threshold formulas and downstream stages.
  Direct `zig build test --summary all` passed `442/442`. On the first detected
  `3063x4600` `scan_0004` crop, default blur `1205` took
  `reference_adaptive_us=5119769`. Candidate blur `603` reduced adaptive time
  to `1918499 us`, but mask-area overlap fell to IoU `74.949%`, reference area
  retained `89.199%`, candidate area confirmed `82.430%`, and Dice `85.681%`.
  Smaller candidates were worse: blur `401` IoU `59.524%`, blur `301` IoU
  `56.496%`, blur `201` IoU `37.506%`, and blur `151` IoU `18.142%`. Reject
  lower blur-size approximation for production despite the speedup; it changes
  detector area too much under the agreed mask-area acceptance surface.
- Same-scale approximate Gaussian sweep: added non-default adaptive-dust
  candidate modes for box cascades, downsampled exact Gaussian blurs, and mixed
  coarse/final plans. Direct `zig build test --summary all` passed `445/445`.
  Focused
  `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case ir_adaptive_dust_gaussian_approx_tradeoff`
  on the first detected `3063x4600` `scan_0004` crop rejected the box-cascade
  family: 3, 4, 6, and 8 boxes all produced zero candidate dust pixels and
  zero mask overlap. Full-plan downsampled Gaussian candidates were faster but
  still too lossy for a default detector: the best full-plan `down4` result
  reached IoU `92.158%`, reference area retained `93.481%`, candidate area
  confirmed `98.486%`, Dice `95.919%`, and adaptive time about `0.69s` versus
  an exact f32 reference around `4.96-5.17s`. Mixed-plan diagnostics showed the
  final local-statistics Gaussian pair needs to stay exact: `down4_final`
  stayed around IoU `91.835%` and reference retained `93.505%`, while
  `down4_coarse` reached IoU `99.281%`, reference retained `99.968%`,
  candidate confirmed `99.312%`, Dice `99.639%`, defect delta `1224`, and
  reduced focused adaptive time from `4964063 us` to `2852742 us`.
- Full-export `down4_coarse` evidence: direct
  `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_gaussian_approx_tradeoff`
  compared the current f32 path with `down4_coarse` across 5 detected frames
  and 15 output files. Wall time improved `28556578 -> 22316350 us`
  (`1.279x`); aggregate `ir_clean_us` improved `116515098 -> 87628300`,
  `ir_defect_mask_us` improved `108889709 -> 79947181`, and
  `ir_adaptive_dust_us` improved `74083018 -> 45182508`. Metadata and file sets
  matched. Final TIFF comparison reported RMS `83.164927`, MSE `6916.405047`,
  mismatch rate `2.729%`, and `abs_gt_4096=46144`. Keep this as a non-default
  candidate pending explicit acceptance of the final-output tradeoff; the
  production `.f32` adaptive path remains exact Gaussian.

## WebGPU Dependency Strategy

WebGPU is a future optional acceleration backend, not a required dependency for
the current CPU parity rewrite. Do not add WebGPU to the default CLI/UI build
until a CPU implementation of the same operation is already accepted and covered
by fixtures.

As of 2026-05-17, the first concrete backend dependency is nixpkgs
`wgpu-native`, not Google Dawn. Direct package queries and pinned nixpkgs source
inspection showed that `pkgs.dawn` is an unrelated DAWN 3D PostScript processor,
while `pkgs.wgpu-native` provides the native WebGPU C library and headers we can
use from Zig. Keep the Zig backend boundary small enough that Google Dawn can be
added later if it becomes necessary.

The Nix strategy is:

1. Keep default `packages.default`, `checks.zig-tests`, and `devShells.default`
   CPU-only until WebGPU work begins.
2. Keep `wgpu-native` in `devShells.webgpu` and legacy `shell.nix` only when
   `withWebGPU=true`. Do not force every CPU parity build to pull the GPU
   runtime closure.
3. Expose `WGPU_NATIVE_INCLUDE_DIR` and `WGPU_NATIVE_LIBRARY_DIR` from the
   WebGPU shell. The nixpkgs `wgpu-native` package installs `include/webgpu`
   headers and `libwgpu_native`, but its package expression does not expose a
   pkg-config file.
4. Add `-Dwebgpu=true` Zig build plumbing only after the package exists in Nix.
   The option must default to false and the CPU backend must remain available.
5. A `-Dwebgpu=true` build may link `libwgpu_native`, but default `zig build`,
   `zig build test`, and `zig build -Dui=true` must not require WebGPU headers,
   libraries, a GPU, Vulkan, Metal, D3D12, or runtime permissions.

After the WebGPU shell is reloaded, verify the package with direct commands
from the ambient shell before linking Zig code:

```sh
test -r "$WGPU_NATIVE_INCLUDE_DIR/webgpu/wgpu.h"
test -r "$WGPU_NATIVE_INCLUDE_DIR/webgpu/webgpu.h"
test -e "$WGPU_NATIVE_LIBRARY_DIR/libwgpu_native.so"
zig version
```

Only then wire `build.zig` to those explicit include/library variables.

## CPU/GPU Image Buffer Boundary

The CPU implementation remains the source of truth for parity. GPU work must
cross an explicit transfer boundary instead of sharing opaque mutable buffers
with scanner, TIFF, processing, or UI state.

`src/processing/gpu_boundary.zig` defines the first stable boundary contract:

- `CpuImageView` describes borrowed CPU memory with explicit width, height,
  pixel format, role, row stride, and ownership. It accepts tightly packed
  buffers and padded rows, but rejects invalid dimensions, short buffers, and
  strides smaller than one row.
- `GpuImageDescriptor` describes a future WebGPU-side image allocation
  without importing native WebGPU headers or changing the default build.
- `TransferPlan.upload` records CPU-to-GPU upload geometry from a validated
  CPU view. `TransferPlan.download` records GPU-to-CPU parity downloads with a
  tightly packed CPU comparison buffer requirement.
- Buffer roles name the Python-shaped data being moved: scanner raw, TIFF page,
  quick preview raw/display, scene-linear data, display output, defect mask, UI
  texture upload, and GPU parity download.

The rules are:

1. CPU buffers own correctness. GPU kernels are optional accelerators and must
   be compared against the accepted CPU operation before feeding UI or export
   results.
2. Uploads may borrow scanner/TIFF/processing/UI buffers only for the duration
   of the transfer. Long-lived GPU allocations must be cached by descriptor,
   not by retaining raw CPU slices.
3. Downloads used for parity are tightly packed CPU buffers and must compare
   with the same tolerances as the scalar/oracle tests for that operation.
4. UI texture uploads remain a presentation boundary. They can consume CPU
   display buffers, but they must not become the canonical processing result.

## GPU Kernel Candidate Inventory

These are the only current color/render candidates for WebGPU work. The
listed Python and Zig symbols are the parity contracts a GPU path must preserve.
The same inventory is mirrored in `src/processing/gpu_boundary.zig` as
`gpu_kernel_candidates`; tests require every candidate to keep a CPU fallback
and a CPU download comparison gate.

Non-goal: `negadoctor` is not a WebGPU target for this rewrite. It remains in
the codebase only for darktable/XMP parity and fixture coverage. The active
UI/export inversion path is the custom density-domain `invert_negative`
pipeline, so autonomous GPU work must not select `negadoctor`.

| Priority | Python contract | Zig CPU contract | Buffer boundary | GPU suitability | Required guard before UI/export use |
| --- | --- | --- | --- | --- | --- |
| P0 | `scratchndent/processing/negative/render.py:90` `render_to_display` | `src/processing/render.zig` `renderToDisplay` | `.scene_linear` `rgb_f64` to `.display_output` `rgb_u16` | Best eventual payoff, but split it carefully. Luminance extraction, color balance, exposure, contrast, clamp, and u16 write are parallel. Exact robust percentile selection is the hard part and should be optimized on CPU first before GPU reduction work. | CPU fallback test, Python oracle fixtures, and CPU-vs-GPU download comparison over the same percentile values. |
| P1 | `scratchndent/processing/negative/inversion.py:61` `invert_negative` | `src/processing/inversion.zig` `invertNegative` | scanner/TIFF `rgb_f64` CPU raw input staged as `rgb_f32` to `.scene_linear` `rgb_f32`, downloaded as `rgb_f64` for parity comparison | Active custom inversion path. Provided-Dmin mode is per-pixel after Dmin and coefficients are known: normalize transmittance, density, Dmin clamp, 10-term stock polynomial, non-negative clamp. | CPU fallback, Python oracle fixtures, CPU-vs-GPU download comparison, and an edge fixture for EPS/Dmin/basis/clamp behavior. Dmin estimation remains CPU for the first GPU checkpoint. |
| P1 | `scratchndent/processing/negative/color_transforms.py:96` / `:333` `_sigmoid_kernel`, `apply_sigmoid` | `src/processing/color.zig` `applySigmoid`; `src/processing/shaders/apply_sigmoid.wgsl` | `.scene_linear` `rgb_f64` CPU buffers staged as `.scene_linear` `rgb_f32` WebGPU buffers, downloaded back to `rgb_f64` for parity comparison | Good per-channel candidate once params are committed on CPU. It is branch-light, nonlinear, and parallel. Existing Python parity already stores output through float32-like rounding, which makes it a lower-risk first shader. First live comparison passed with `max_abs=0.000000477` and `rms=0.000000184` against the CPU reference. | Keep `sigmoidCommitParams` on CPU unless a separate fixture proves identical committed constants. Compare downloaded GPU output to the existing Python fixture tolerance through `zig build -Dwebgpu=true webgpu-sigmoid-compare --summary all`; UI/export integration remains blocked until benchmark evidence proves a useful threshold. |
| P2 | `scratchndent/processing/negative/color_transforms.py:114` / `:172` `_srgb_to_linear_kernel`, `srgb_to_linear`; `:126` / `:181` `_linear_to_srgb_kernel`, `linear_to_srgb` | `src/processing/color.zig` `srgbToLinear`, `linearToSrgb`; `src/processing/render.zig` `applySrgbGamma` | `rgb_f64` to `rgb_f64` | Simple per-sample transfer functions. Worth batching only when fused with a larger GPU pass because standalone transfer overhead may dominate. | Scalar fallback and transfer-function fixtures stay mandatory. |
| P2 | `scratchndent/processing/negative/color_transforms.py:140` / `:167` `_color_matrix_kernel`, `apply_color_matrix` | `src/processing/color.zig` `applyColorMatrix` | `rgb_f64` to `rgb_f64` | Very cheap per-pixel 3x3 multiply. Good for fusion with custom inversion or display conversion, not as a standalone dispatch. | Matrix fixture and exact constant tests must pass for the CPU path; GPU comparison can use the same fixture tolerance. |
| P2 | `scratchndent/calibration/film_stocks.py` polynomial density transform | `src/processing/film_stocks.zig` `applyDensityTransform` | density `rgb_f64` to `.scene_linear` `rgb_f64` | Parallel and predictable, but current benchmark says it is cheap. Keep lower priority unless fused with inversion. | Preserve 10-term basis order and built-in stock coefficients. |
| Defer | `scratchndent/processing/negative/render.py:13` / `:50` `_sigmoid_tonemap_kernel`, `sigmoid_tonemap` | `src/processing/render.zig` `sigmoidTonemap` | `rgb_f64` to `rgb_f64` | Parallel, but not currently on the measured hot path. | Existing sigmoid tone-map fixture before any backend split. |

Do not target scanner startup, scanner command planning, TIFF metadata, config
load/save, XMP parsing, filesystem gallery work, or Nuklear layout as GPU
kernels. Those paths are control flow, I/O, or UI presentation and are not the
performance problem identified by the benchmark.

## Current WebGPU Evidence

`apply_sigmoid` is the first live WGSL kernel. It is still disconnected from
default UI/export behavior and is available only through explicit WebGPU
comparison, benchmark, and runtime-switch steps.

Validation and comparison:
- `zig build -Dwebgpu=true webgpu-sigmoid-compare --summary all` passed on
  `wgpu-native` Vulkan adapter `590.48.01`.
- `zig build -Dwebgpu=true webgpu-sigmoid-runtime-smoke --summary all` passed.
  With no `V600_PROCESSING_GPU` env var, the runtime switch kept CPU behavior
  with `max_abs=0.000000000`. With `V600_PROCESSING_GPU=1`, the same fixture
  used WebGPU and reported `max_abs=0.000000477`, `rms=0.000000184`.
- `zig build -Dui=true native-process-export-smoke --summary all` passed after
  the runtime switch was added, confirming the native Process export surface
  still starts through the default CPU path.
- The comparison used `apply-darktable-sigmoid.json`, CPU-committed sigmoid
  constants, `rgb_f64` to `rgb_f32` staging, and tightly packed `rgb_f32`
  download.
- Error versus the CPU reference was `max_abs=0.000000477`,
  `max_index=10`, and `rms=0.000000184`, within the existing
  `abs=0.000002`, `rel=0.000002` Python oracle tolerance.

ReleaseFast benchmark:

| Input | Pixels | Samples | Uploaded | Downloaded | CPU | GPU end-to-end | GPU resident dispatch | End-to-end speedup | Resident speedup |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `preview_1024x768` | `786432` | `2359296` | `9437216` B | `9437184` B | `2` iters, `260132211 ns` | `3` iters, `4690388 ns` | `20` iters, `2513597 ns` | `83.191x` | `1034.907x` |
| `export_frame_2048x3072` | `6291456` | `18874368` | `75497504` B | `75497472` B | `1` iter, `1060823646 ns` | `1` iter, `13297413 ns` | `10` iters, `6715031 ns` | `79.776x` | `1579.774x` |

The initial one-dimensional dispatch exceeded WebGPU's 65,535-workgroup
per-dimension limit on export-sized input. The shader now uses 2D dispatch
geometry and a uniform `dispatch_width` while preserving the same tail guard
against `index >= count`.

Runtime policy:
- Default remains CPU. Missing, empty, or `0` `V600_PROCESSING_GPU` selects
  `webgpu.Backend.cpu`.
- `V600_PROCESSING_GPU=1` or `webgpu` selects WebGPU with fail-fast behavior.
- `V600_PROCESSING_GPU=allow-cpu` or `webgpu-allow-cpu` requests WebGPU but
  permits explicit CPU fallback only when WebGPU is unavailable.
- Silent fallback is still forbidden for benchmark evidence.
- The runtime parser is shared by `apply_sigmoid` and `invert_negative`.
  `invert_negative` callers must pass the parsed request explicitly. The
  processing CLI export path passes the ambient env request through to
  workflow/export; native UI callers remain CPU until a UI setting is
  intentionally wired.

## Next GPU Kernel Decision

The next standalone GPU target is the custom `invert_negative` scene-linear
stage, not darktable `negadoctor`.

Rationale:
- `apply_sigmoid` proved that `wgpu-native` dispatch, f32 staging, tight
  readback, and explicit runtime selection work on the current Linux/Vulkan
  environment.
- The active UI/export inversion path does not use `negadoctor`; it uses the
  project custom density-domain pipeline in `invert_negative`.
- The provided-Dmin part of `invert_negative` is per-pixel once coefficients
  and Dmin are known: normalize transmittance, convert to density, subtract
  Dmin, apply the 10-term stock polynomial, and clamp to non-negative
  scene-linear output.
- This targets the current `inverted_preview` and export hot path without
  taking on `render_to_display` percentile reductions yet.

Required guardrails before accepting an `invert_negative` shader:
- Start with standalone upload-dispatch-download comparison only.
- Reuse `test/fixtures/processing/numeric/invert-negative-identity-dmin.json`
  and `test/fixtures/processing/numeric/invert-negative-kodak-gold-dmin.json`.
- Add an edge-case fixture covering low/zero raw samples, Dmin clamp behavior,
  all 10 polynomial basis terms, cross-channel terms, and non-negative output
  clamp.
- Record max absolute error, RMS error, and tolerance. Any tolerance expansion
  must be representational f32 WGSL math only, not an algorithm change.

Current `invert_negative` WebGPU evidence:
- Added `test/fixtures/processing/numeric/invert-negative-custom-edge-dmin.json`
  from Python `invert_negative` using uint16 input semantics, provided Dmin,
  and custom coefficients.
- `zig build -Dwebgpu=true webgpu-invert-negative-compare --summary all`
  compares downloaded GPU output to Zig CPU `invertNegative`, after first
  proving Zig CPU still matches the Python fixtures. It passed on Vulkan
  adapter `590.48.01`:
  - identity fixture: `max_abs=0.000000109`, `rms=0.000000043`.
  - Kodak Gold fixture: `max_abs=0.000000190`, `rms=0.000000073`.
  - custom edge fixture: `max_abs=0.000000874`, `rms=0.000000243`.
- `zig build -Dwebgpu=true webgpu-invert-negative-runtime-smoke --summary all`
  passed. With no `V600_PROCESSING_GPU` env var, the runtime switch kept CPU
  behavior with `max_abs=0.000000132`, `rms=0.000000046`. With
  `V600_PROCESSING_GPU=1`, it selected WebGPU after adapter preflight and
  reported `max_abs=0.000000322`, `rms=0.000000113`.

ReleaseFast `invert_negative` benchmark:

| Input | Pixels | Samples | Uploaded | Downloaded | CPU | GPU end-to-end | GPU resident dispatch | End-to-end speedup | Resident speedup |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `preview_1024x768` | `786432` | `2359296` | `9437344` B | `9437184` B | `1` iter, `20873284 ns` | `3` iters, `4827842 ns` | `20` iters, `2628179 ns` | `12.970x` | `158.843x` |
| `export_frame_2048x3072` | `6291456` | `18874368` | `75497632` B | `75497472` B | `1` iter, `156608114 ns` | `1` iter, `14024699 ns` | `10` iters, `9126367 ns` | `11.166x` | `171.599x` |

These timings compare the GPU kernel against the current Zig CPU inversion
pipeline, which now includes the provided-Dmin CPU SIMD fast path. The Python
implementation is the behavior oracle, not the benchmark baseline.

The production `invert_negative` WebGPU path now caches the WebGPU instance,
device, queue, bind-group layout, and compute pipeline per process. End-to-end
benchmarks must therefore report both cold and warm timings:
- Cold timings include first-use adapter/device/pipeline setup.
- Warm timings represent repeated Process work after the cache is live.
- The default path remains CPU unless the runtime explicitly requests WebGPU.

ReleaseFast Process workflow benchmark evidence, using
`scans/scan_0006_rgbir_800dpi.tiff` and comparing explicit WebGPU inversion to
the Zig CPU path:

| Benchmark | Work | CPU | GPU cold | GPU warm | Cold speedup | Warm speedup | Parity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `bench-processing-commands -- --case inverted_preview_cpu_vs_gpu` | `1272x6031` preview, `7671432` px | `1030988 us` | `1381265 us` | `1174797 us` | `0.746x` | `0.877x` | `max_abs=1`, `rms=0.002`, `mismatches=137` |
| `bench-processing-commands -- --case export_inv_only_cpu_vs_gpu` | scan-0006 representative crop, `764x1145`, one file | `305597 us` | `463620 us` | `257772 us` | `0.659x` | `1.185x` | `max_abs=1`, `rms=0.052`, `mismatches=7216`, `metadata_equal=true`, `file_name_equal=true` |

Performance conclusion: after the CPU SIMD fast path, warm WebGPU is still
faster for the tiny representative export crop, but preview is slower and large
full-resolution exports are slower. Any native UI GPU opt-in must account for
that cache lifecycle and should wait until render-stage GPU work or broader
buffer residency makes the boundary cost worthwhile.

Large real-scan ReleaseFast evidence from `scans/`:

| Benchmark | Scan | Source size | Work | CPU | GPU cold | GPU warm | Warm speedup | Parity |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `bench-processing-commands -- --case load_preview` | `scan_0004_rgbir_3200dpi.tiff` | 865 MB, RGB `5120x24125`, IR `5120x24125` | quick preview `1738x8192`, `14237696` px | n/a | n/a | `2330243 us` load | n/a | checksum `6666414344` |
| `bench-processing-commands -- --case inverted_preview_cpu_vs_gpu` | `scan_0004_rgbir_3200dpi.tiff` | same | inverted preview `1738x8192`, `14237696` px | `1800749 us` | `2378655 us` | `2194852 us` | `0.820x` | `max_abs=1`, `rms=0.002`, `mismatches=259` |
| `bench-processing-commands -- --case load_preview` | `scan_0003_rgbir_3200dpi.tiff` | 728 MB | quick preview `1901x8192`, `15572992` px | n/a | n/a | `2446635 us` load | n/a | checksum `7029421254` |
| `bench-processing-commands -- --case inverted_preview_cpu_vs_gpu` | `scan_0003_rgbir_3200dpi.tiff` | same | inverted preview `1901x8192`, `15572992` px | `2060415 us` | `2544158 us` | `2323564 us` | `0.886x` | `max_abs=1`, `rms=0.002`, `mismatches=278` |
| `bench-processing-commands -- --case export_fullres_inv_cpu_vs_gpu` | `scan_0004_rgbir_3200dpi.tiff` | 865 MB | full-resolution export crop `4535x3023`, one file | `4786929 us` | `5249665 us` | `5056970 us` | `0.946x` | `max_abs=1`, `rms=0.050`, `metadata_equal=true` |
| `bench-processing-commands -- --case export_fullres_inv_cpu_vs_gpu` | `scan_0003_rgbir_3200dpi.tiff` | 728 MB | full-resolution export crop `4420x3023`, one file | `4468992 us` | `4858133 us` | `4681464 us` | `0.954x` | `max_abs=1`, `rms=0.051`, `metadata_equal=true` |

CPU fusion evidence on `scan_0004_rgbir_3200dpi.tiff`:

| Benchmark | Work | Before | After | Speedup | Parity |
| --- | --- | ---: | ---: | ---: | --- |
| `preview_render_quantile_tradeoff` | render existing scene-linear preview to display bytes | `1335115 us` exact full-sort/full-curve path | `71011 us` 16k-sample robust range plus 256-entry preview LUT | `18.801x` | final `u8` `max_abs=1`, `rms=0.364` against exact path |
| `preview_render_u8_vs_u16` | compare production preview `u8` path against production export-shaped `u16` LUT path shifted to `u8` | `156844 us` current `u16` plus downshift path | `69388 us` direct `u8` path | `2.260x` | final `u8` `max_abs=1`, `rms=0.361` |
| `invert_negative_preview_u16_vs_f64` | provided-Dmin preview inversion | `453399 us` staged `f64` input plus SIMD | `348303 us` direct `u16` SIMD | `1.301x` | `max_abs=0`, `rms=0.000000000000`, checksums equal |
| `invert_negative_preview_breakdown` | direct-u16 provided-Dmin preview inversion split by stage | n/a | `347419 us` fused production path | n/a | benchmark-only staged split: `density_us=340854`, `linear_transform_us=138941`, exact checksum match |
| `invert_negative_preview_lut_tradeoff` | provided-Dmin preview inversion density LUT variants | `345713 us` direct-u16 SIMD | `74063 us` f32 density LUT to f32 scene, including LUT build | `4.667x` | preview `u8 max_abs=2`, `u8_mse=0.000004987`; export-shaped `u16 max_abs=1`, `u16_mse=0.001272631` |
| `inverted_preview_f32_breakdown` | full f32 inverted preview plus stage split | `146687 us` accepted f32-density preview with exact f64 table index | `85910 us` production preview with f32 table index and parallel display write | `1.708x` | current output exact to serial f32-index mirror; exact f64-index comparison on refreshed scan4 `max_abs=2`, `mse=0.000002130`, `79/42713088` channel samples changed |
| `load_preview` | TIFF image load plus quick preview buffers/JPEG | `2255972 us` two OpenCV preview passes plus full RGB+IR page load | `647912 us` one-open TIFF metadata/RGB load plus exact u8 histogram percentile stretch | `3.482x` | checksum `6666414344`; breakdown raw/RGB/JPEG `mismatches=0` |
| `auto_detect_breakdown` | autodetect stage split on preview `1738x8192` | `729511 us` initial breakdown on `scan_0004` | `146591 us` after grayscale, film extent, CLAHE, rotation, conversion, run-length component, run-based horizontal close, axis reductions, parallel CLAHE LUTs, portable SIMD conversion/blur paths, DTW square simplification, and boundary preallocation | `4.976x` | exact parity against production `auto_detect`: frames `5`, aspect `24:36`, checksum `38221731`, `frame_max_abs=0`, `rebate_max_abs=0`; stages now film extent `63202 us`, axis detection `18017 us`, CLAHE `23061 us`, rotation `12167 us`, grayscale prep `8426 us` |
| `rebate` | full-resolution rebate Dmin from autodetected rebate | `2396746 us` full RGB+IR load and full-image f64 conversion before crop | `448352 us` RGB page load plus direct TIFF-sample rebate crop | `5.346x` | unchanged Dmin `0.283915:0.422373:0.606312` |
| `export_render_u16_vs_f64` | full-resolution inverted-positive export helper | `2184971 us` old display `f64` helper | `1976225 us` direct `u16` helper | `1.105x` | `max_abs=0`, `rms=0.000`, checksums equal |
| `export_fullres_f32_lut_tradeoff` | one full-resolution export crop through final `u16` | `484129 us` f64 export helper | `227450 us` f32 density LUT plus f32 render | `2.128x` | final `u16 max_abs=1`, RMS `0.054239`, MSE `0.002941895` |
| `export_detected_frames` | 5 autodetected full-resolution frames | `5981208 us` dynamic CPU/memory-limited frame workers before export breakdown pass | `665669 us` nested fused direct TIFF crop to f32 scene plus f32 density-LUT export | `8.986x` | 5 workers, CPU limit 31, memory limit 28, adjusted peak `2159506560` bytes/worker; breakdown direct-crop/no-direct-crop TIFFs exact with `max_abs=0`, metadata equal |
| `inverted_preview` | full CPU inverted preview | `410896 us` after sampled render/LUT path | `85910 us` after f32 density LUT scene path, f32 table index, and parallel display write | `4.783x` | checksum `3912224310` |

The first large `scan_0004` GPU preview attempt exposed a real WebGPU scaling
bug: a single `invert_negative` storage binding exceeded the native backend's
limit and aborted in `wgpuQueueSubmit`. The production GPU path now chunks
`invert_negative` work into 64 MiB RGB-f32 slices, with a chunk-range unit test
covering the `1738x8192` preview case. Large-scan results show that isolated
kernel throughput is not the limiting factor anymore. After the CPU SIMD fast
path, the current WebGPU preview/export workflow is slower than the CPU path on
large scans because TIFF load, CPU render/display, crop/write work, transfer,
and repeated CPU/GPU boundary crossings dominate. Keep WebGPU opt-in/default-off
until additional stages can remain on the GPU side of the same boundary.

## Native UI GPU Opt-In Policy

The native UI keeps CPU processing as the default. It does not expose or persist
a visible GPU toggle yet because current large-scan benchmark evidence shows the
explicit WebGPU preview/export workflow is slower than the CPU SIMD path until
more processing stages move behind the same GPU boundary.

For operator/debug testing, the native UI reads `V600_PROCESSING_GPU` once at
startup and stores the parsed request in UI state:
- Missing, empty, or `0` selects CPU.
- `1` or `webgpu` selects WebGPU with fail-fast behavior.
- `allow-cpu` or `webgpu-allow-cpu` selects WebGPU with explicit CPU fallback
  only when WebGPU is unavailable.

The request is shared by inverted preview rendering and Process export. Changing
the request in state invalidates the inverted-preview cache so CPU and WebGPU
scene-linear buffers are not reused across backend changes. No
`scratchndent_config.toml` key exists for this policy; a persisted UI setting
must wait for prewarm/status diagnostics or render-stage GPU acceleration that
makes the CPU/GPU boundary tradeoff worthwhile.

## `render_to_display` WebGPU Plan

The accepted parity plan is a hybrid path: keep robust luminance percentile
selection on CPU, then optionally run the per-sample display transform on
WebGPU. This is the only currently approved `render_to_display` GPU direction.

Percentile invariants that must not change:
- Luminance is `0.2126 * R + 0.7152 * G + 0.0722 * B`.
- The percentile population is exactly `luminance > 0.001`.
- Empty positive populations use `lo=0.0`, `hi=1.0`.
- Percentiles use NumPy-style sorted linear interpolation:
  `rank = (n - 1) * percentile / 100`, then floor/ceil interpolation.
- If `hi <= lo`, set `hi = lo + 1.0`.
- Invalid or non-finite percentile values fail before GPU dispatch.

The first shader must not compute percentiles. CPU exact `lo`/`hi`, color
balance multipliers, exposure gamma, and contrast constants are computed before
dispatch and passed as uniforms. WGSL may apply only normalization, color
balance, exposure power, logistic S-curve, clamping, and display quantization.
Downloaded GPU output must compare against Zig CPU `renderToDisplay` over the
existing Python fixtures. Any tolerance must come from WGSL f32 arithmetic and
final integer quantization only; percentile value differences are not allowed.

Approximate GPU percentile methods are explicitly outside the exact parity path:
histograms, sampling, fixed-bin CDFs, t-digests, and WGSL-f32 percentile
selection cannot be called exact for the current Zig CPU f64 contract. The CPU
preview path now has an explicitly approved approximate robust-statistic mode
with final-output error evidence; any GPU approximation needs the same style of
opt-in decision and CPU-vs-GPU final-output measurements.

## Scanner Timing Baseline Plan

Scanner startup, preview, and full-resolution scan optimization is
measurement-first. Do not add speculative probes or retry loops to make the UI
"feel" more active; first record where time is actually spent.

Accepted instrumentation so far:
- The scanner event schema includes a `timing` JSONL event with stable
  `event`, `schema`, `stage`, `elapsed_us`, and nullable `detail` fields.
- The scanner event schema also includes report-only `timing-context` and
  `timing-status` JSONL records for appendable live diagnostics. The CLI
  accepts `--timing-report PATH` for scanner devices/probe/scan/smoke flows,
  and the native UI accepts the same flag for preview-worker and scan-worker
  smoke paths.
- Linux discovery emits timings for `scanimage -L`, device-list parsing,
  selected-device resolution, and total discovery.
- Linux probe emits timings for discovery, selected-device resolution, cache
  write, flatbed and TPU `scanimage --help`, combined capability parsing, and
  total probe.
- Linux device resolution emits timings for explicit selection, cache lookup,
  and discover-and-cache fallback.
- Linux single-pass scan emits timings for capability lookup, request
  normalization, command planning, environment/LUT setup, child spawn,
  stderr/progress streaming, aggregate progress-event emission, child wait,
  cancel-file observation, mirror handling, TIFF metadata rewrite, sidecar
  write, and total `scanOnce`.
- Linux RGB+IR scan orchestration emits timings for RGB/IR planning and pass
  execution, thumbnail generation, multipage TIFF combine, final metadata
  rewrite, combined sidecar write, temp cleanup, and total `scanRgbIr`.
- Native preview worker emits timings for worker start, probe/capability
  refresh, preview request construction, runtime scan, TIFF load, downsample,
  total execution, and final UI state update. Native state stores the latest
  scanner timing sample and count without changing user-visible scan status.
- Native scan worker emits timings for start preparation, temporary scanner LUT
  generation/write, cancel-file pre-cleanup and write, runtime setup, runtime
  scan execution, metadata-path propagation, backend event drain, final UI
  state update, and cleanup. Runtime timing events are passed through the scan
  worker queue instead of being dropped.

Validation evidence from 2026-05-19: direct
`zig build test --summary all` passed `412/412`, including fake-process probe
timing order, cache-hit resolution without discovery, failed discovery that
preserves the existing `device-discovery` event while adding timing
diagnostics, fake-child cancellation timing, and fake single-pass scan timing
through real TIFF metadata and sidecar work. The RGB+IR fake scan additionally
exercises real temp TIFFs, thumbnail generation, `tiffcp` combine, final
metadata/sidecar write, and temp cleanup. Preview worker success/failure tests
assert timing diagnostics are surfaced through state while preserving
preview-ready and failure behavior. Scan worker success/LUT/cancellation/live
event/failure tests assert timing diagnostics are surfaced through state while
preserving scan status, progress, cancellation, and output behavior. Report
path tests prove context/status/event append semantics, and direct skip smokes
proved `--timing-report` writes appendable JSONL for scanner smoke,
scanner-to-processing smoke, native preview-worker smoke, and native
scan-worker smoke without hardware access. Live hardware timings still need the
gated scanner smoke pass before any scanner-side optimization is selected.

Live attempt from 2026-05-19: `zig build run -- scanner devices
--timing-report .zig-cache/tmp/v600-live-scanner-timing.jsonl` and
`zig build run -- scanner probe --timing-report
.zig-cache/tmp/v600-live-scanner-timing.jsonl` recorded discovery timings, but
SANE returned zero devices and probe failed with `NoV600Device`. USB still saw
the Epson V600 at `001:018`, permissions allowed scanner-group access, and
`sane-find-scanner` saw a possible `libusb:001:018` scanner, so the current
blocker is SANE enumeration rather than missing USB visibility. Do not run live
scan smokes until `scanimage -L` or the project wrapper reports the V600 again.
Later the same day, `zig build run -- scanner devices --timing-report
.zig-cache/tmp/v600-live-scanner-timing-refresh.jsonl` still reported
`devices_found=0`; the `linux.discover.scanimage_list` timing was
`5743827 us`.

## Required Evidence For Optimization Work

- Capture before and after `bench-color` output in `plan.md`.
- Identify the exact Python function and named dependency being accelerated
  before accepting a benchmark. The optimized Zig path must remain a
  function-for-function port of that Python path, not a replacement algorithm.
- Keep Python oracle fixtures passing unless the change has an explicit
  approved tolerance shift. A tolerance shift permits representational numeric
  differences, not a different algorithm.
- Run direct Zig gates from the ambient shell for ordinary CPU optimization:
  - `zig build test --summary all`
  - `zig build -Dui=true --summary all`
  - the relevant benchmark command, for example
    `zig build -Doptimize=ReleaseFast bench-color --summary all`
  - for user-visible Process command latency:
    `zig build -Doptimize=ReleaseFast bench-processing-commands`
  - before any GPU backend work:
    `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
- Run Nix graph/package gates only when the optimization changes
  `flake.nix`, `shell.nix`, package outputs, or dependency wiring. Do not use a
  Nix wrapper as routine proof for ordinary Zig-only edits.
- For SIMD or GPU backends, add backend-selection tests that prove the scalar
  fallback remains available.
- For GPU work, add a headless CPU-vs-GPU numeric comparison before connecting
  the backend to the UI.

## Non-Goals

- Do not optimize scanner startup by adding speculative hardware probes.
  Startup performance should come from caching, fewer blocking probes, and
  clearer lazy initialization.
- Do not replace exact output with approximate math during the parity rewrite
  unless the deviation is measured, documented, and explicitly accepted.
- Do not make WebGPU a required runtime dependency before the CPU native UI
  path is functionally complete.
