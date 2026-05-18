# Performance Strategy

This document records where acceleration is worth introducing during the
Python-to-Zig rewrite. The rule is parity first: no SIMD, threading, GPU, or
algorithm change is accepted as rewrite progress unless it preserves the frozen
Python function's observable behavior and algorithmic contract. Alternate
algorithms are post-parity experiments only, require explicit user approval,
and must remain separate from parity checklist completion.

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

- Next preview hotspot after f32 density-LUT adoption: first-use inverted
  preview is now split between f32 `invert_negative` scene generation and
  display rendering. On `scan_0004_rgbir_3200dpi.tiff`,
  `invert_negative_preview_lut_tradeoff` measured the accepted f32 density LUT
  scene generation at `74063 us` including LUT build, while the full
  `inverted_preview` command measured `146687 us`. The remaining work is now
  roughly half inversion and half display/range/render output; future work
  should benchmark these together before choosing another target.

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
  scene-linear data as f32. The exact f64 SIMD and f64 LUT paths remain
  available for oracle comparisons and non-preview paths. On `scan_0004`,
  direct-u16 SIMD inversion took `345713 us`; f64 density LUT to f64 scene took
  `138229 us` with exact final `u8/u16`; accepted f32 density LUT to f32 scene
  took `74063 us` including LUT build, with preview `u8 max_abs=2`,
  `u8_mse=0.000004987`, export-shaped `u16 max_abs=1`,
  `u16_mse=0.001272631`. Full `inverted_preview` now takes `146687 us`.
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
| `export_render_u16_vs_f64` | full-resolution inverted-positive export helper | `2184971 us` old display `f64` helper | `1976225 us` direct `u16` helper | `1.105x` | `max_abs=0`, `rms=0.000`, checksums equal |
| `export_detected_frames` | 5 autodetected full-resolution frames | `18125889 us` serial frame loop | `5981208 us` dynamic CPU/memory-limited frame workers | `3.030x` | 5 workers, CPU limit 31, memory limit 25, adjusted peak `2159506560` bytes/worker |
| `inverted_preview` | full CPU inverted preview | `410896 us` after sampled render/LUT path | `146687 us` after f32 density LUT scene path | `2.802x` | checksum `3912224049` |

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
