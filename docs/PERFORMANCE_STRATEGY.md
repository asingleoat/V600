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

Current Linux baseline from 2026-05-17, 4096 pixels per pass, after replacing
quadratic numeric insertion sorts with exact `pdq` sorting:

| Path | ns-per-pixel x1000 | Notes |
| --- | ---: | --- |
| `srgb_to_linear` | 55375 | Scalar transfer function with `pow`. |
| `linear_to_srgb` | 49504 | Scalar transfer function with `pow`; benchmarked for GPU readiness coverage. |
| `color_matrix_rec2020` | 662 | Simple 3x3 multiply; not a current bottleneck. |
| `density_transform_kodak_gold` | 2940 | Polynomial transform is cheap relative to nonlinear paths. |
| `darktable_sigmoid` | 174045 | Hot scalar nonlinear path. |
| `negadoctor` | 225178 | Hot scalar nonlinear path with several transfer stages. |
| `render_to_display` | 128035 | Exact percentile semantics with non-quadratic sorting. |

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
   percentiles, and detector medians. Further render acceleration should
   preserve the same percentile semantics first, for example by reducing
   allocation churn or using an exact selection implementation that returns the
   same percentile result. Histogram or approximate percentile behavior is not
   function-for-function parity and belongs only in a later explicitly approved
   experiment.

2. Add SIMD only for stable per-pixel kernels.
   Good candidates are `srgbToLinear`, `linearToSrgb`, `applySigmoid`,
   `negadoctor`, and density polynomial evaluation. SIMD work must keep a
   scalar fallback and reuse the same fixture tests.

3. Defer GPU until CPU parity is complete.
   Dawn/WebGPU should first target preview/export image transforms that are
   embarrassingly parallel: transfer functions, matrix transforms, sigmoid,
   negadoctor, IR mask operations, and display rendering. GPU kernels must
   execute the same Python-shaped operation that the CPU path already proved.
   Do not introduce GPU acceleration into scanner startup, scanner command
   planning, config I/O, TIFF metadata, or other low-throughput control paths.

4. Keep UI rendering separate from image-processing acceleration.
   SDL3/Nuklear can begin with CPU-rendered image buffers uploaded to textures.
   Dawn should be introduced as an optional processing/render backend with the
   CPU path still used for tests and fallback.

## Dawn/WebGPU Dependency Strategy

Dawn/WebGPU is a future optional acceleration backend, not a required dependency
for the current CPU parity rewrite. Do not add Dawn to the default CLI/UI build
until a CPU implementation of the same operation is already accepted and covered
by fixtures.

As of the 2026-05-15 planning pass, do not assume that `pkgs.dawn` in nixpkgs
means Google's WebGPU Dawn. Package search results show that the `dawn` package
name can refer to an unrelated unfree DAWN 3D PostScript processor, while
Google's Dawn remains the WebGPU implementation we intend to target:

- https://github.com/google/dawn
- https://mynixos.com/nixpkgs/package/dawn
- https://vcpkg.io/en/package/dawn.html

The Nix strategy is:

1. Keep default `packages.default`, `checks.zig-tests`, and `devShells.default`
   CPU-only until WebGPU work begins.
2. Add a separate optional Dawn package expression or overlay only when the
   first GPU backend checkpoint is selected. Name it unambiguously, for example
   `webgpuDawn`, not plain `dawn`.
3. Prefer a nixpkgs-provided Google Dawn package only if the package's homepage,
   headers, libraries, and license clearly match Google's Dawn. If nixpkgs does
   not provide that package, add a local derivation pinned to `google/dawn`.
4. Export a pkg-config file from the derivation with the exact headers and
   libraries the Zig build will use. The expected C ABI target is the WebGPU
   native/Dawn C headers, not a browser API shim.
5. Add a `-Dwebgpu=true` Zig build option only after the package exists in Nix.
   The option must default to false and the CPU backend must remain available.
6. Add a separate validation shell/output for GPU work if the extra runtime
   closure is large. Do not force every CPU parity build to pull the Dawn toolchain.

When the first actual Dawn dependency edit is made, stop after editing
`flake.nix`/`shell.nix` and ask for a human shell reload. Do not try to repair
the shell by running `nix develop`, `nix-shell`, `nix build`, or `nix flake check`
inside the active conversation.

After the shell is reloaded, verify the package with direct commands from the
ambient shell before linking Zig code:

```sh
pkg-config --modversion <chosen-dawn-pc-name>
pkg-config --cflags <chosen-dawn-pc-name>
pkg-config --libs <chosen-dawn-pc-name>
```

Only then wire `build.zig` to the selected pkg-config name.

## CPU/GPU Image Buffer Boundary

The CPU implementation remains the source of truth for parity. GPU work must
cross an explicit transfer boundary instead of sharing opaque mutable buffers
with scanner, TIFF, processing, or UI state.

`src/processing/gpu_boundary.zig` defines the first stable boundary contract:

- `CpuImageView` describes borrowed CPU memory with explicit width, height,
  pixel format, role, row stride, and ownership. It accepts tightly packed
  buffers and padded rows, but rejects invalid dimensions, short buffers, and
  strides smaller than one row.
- `GpuImageDescriptor` describes a future Dawn/WebGPU-side image allocation
  without importing Dawn headers or changing the default build.
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

These are the only current color/render candidates for Dawn/WebGPU work. The
listed Python and Zig symbols are the parity contracts a GPU path must preserve.
The same inventory is mirrored in `src/processing/gpu_boundary.zig` as
`gpu_kernel_candidates`; tests require every candidate to keep a CPU fallback
and a CPU download comparison gate.

| Priority | Python contract | Zig CPU contract | Buffer boundary | GPU suitability | Required guard before UI/export use |
| --- | --- | --- | --- | --- | --- |
| P0 | `scratchndent/processing/negative/render.py:90` `render_to_display` | `src/processing/render.zig` `renderToDisplay` | `.scene_linear` `rgb_f64` to `.display_output` `rgb_u16` | Best eventual payoff, but split it carefully. Luminance extraction, color balance, exposure, contrast, clamp, and u16 write are parallel. Exact robust percentile selection is the hard part and should be optimized on CPU first before GPU reduction work. | CPU fallback test, Python oracle fixtures, and CPU-vs-GPU download comparison over the same percentile values. |
| P1 | `scratchndent/processing/negative/color_transforms.py:48` / `:355` `_negadoctor_kernel`, `negadoctor` | `src/processing/color.zig` `negadoctor` | scanner/TIFF `rgb_f64` raw input to `.scene_linear` `rgb_f64` | Good per-pixel candidate. It has expensive transfer, log, power, matrix, and soft-clip math but no inter-pixel dependency. | Fixture tolerance must account only for representational GPU math differences; the staged float32 rounding points remain part of parity. |
| P1 | `scratchndent/processing/negative/color_transforms.py:96` / `:333` `_sigmoid_kernel`, `apply_sigmoid` | `src/processing/color.zig` `applySigmoid` | `.scene_linear` `rgb_f64` to `.scene_linear` `rgb_f64` | Good per-channel candidate once params are committed on CPU. It is branch-light, nonlinear, and parallel. | Keep `sigmoidCommitParams` on CPU unless a separate fixture proves identical committed constants. Compare downloaded GPU output to the existing Python fixture tolerance. |
| P2 | `scratchndent/processing/negative/color_transforms.py:114` / `:172` `_srgb_to_linear_kernel`, `srgb_to_linear`; `:126` / `:181` `_linear_to_srgb_kernel`, `linear_to_srgb` | `src/processing/color.zig` `srgbToLinear`, `linearToSrgb`; `src/processing/render.zig` `applySrgbGamma` | `rgb_f64` to `rgb_f64` | Simple per-sample transfer functions. Worth batching only when fused with a larger GPU pass because standalone transfer overhead may dominate. | Scalar fallback and transfer-function fixtures stay mandatory. |
| P2 | `scratchndent/processing/negative/color_transforms.py:140` / `:167` `_color_matrix_kernel`, `apply_color_matrix` | `src/processing/color.zig` `applyColorMatrix` | `rgb_f64` to `rgb_f64` | Very cheap per-pixel 3x3 multiply. Good for fusion with negadoctor or display conversion, not as a standalone dispatch. | Matrix fixture and exact constant tests must pass for the CPU path; GPU comparison can use the same fixture tolerance. |
| P2 | `scratchndent/calibration/film_stocks.py` polynomial density transform | `src/processing/film_stocks.zig` `applyDensityTransform` | density `rgb_f64` to `.scene_linear` `rgb_f64` | Parallel and predictable, but current benchmark says it is cheap. Keep lower priority unless fused with inversion. | Preserve 10-term basis order and built-in stock coefficients. |
| Defer | `scratchndent/processing/negative/render.py:13` / `:50` `_sigmoid_tonemap_kernel`, `sigmoid_tonemap` | `src/processing/render.zig` `sigmoidTonemap` | `rgb_f64` to `rgb_f64` | Parallel, but not currently on the measured hot path. | Existing sigmoid tone-map fixture before any backend split. |

Do not target scanner startup, scanner command planning, TIFF metadata, config
load/save, XMP parsing, filesystem gallery work, or Nuklear layout as GPU
kernels. Those paths are control flow, I/O, or UI presentation and are not the
performance problem identified by the benchmark.

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
- Do not make Dawn/WebGPU a required runtime dependency before the CPU native UI
  path is functionally complete.
