# V600 Zig Rewrite Plan

This project is moving from a mature Python version one implementation to a
function-by-function Zig rewrite. The Python code is now the frozen behavior
oracle. The rewrite succeeds only when the Zig implementation reaches full
behavior parity for scanner operation, processing, export, configuration, and
UI workflows. For numeric image-processing performance work, parity means the
same user-visible operation with documented final-output tolerances; it does not
require byte-for-byte equality with the Python oracle or with intermediate
floating-point buffers when a very small final `u8`/`u16`/mask/geometry error
buys a large speed increase.

The scanner path is the highest-risk and highest-priority work. Make scanner
progress first, keep it testable without hardware where possible, and use real
hardware tests only when the machine and platform allow it. Scanner startup is
known to be slow; do not add extra discovery or probing on hot paths without a
measured reason.

## Operating Rules For Agents

1. Read this file, `AGENTS.md`, and the relevant Python/Zig source before
   making changes.
2. Select the logically next unchecked checklist item in this file.
3. Work that item to completion before checking it off.
4. Add or update tests and parity evidence for that item before checking it
   off.
5. Do not check off an item based on intent, partial implementation, or build
   success alone.
6. If an item is blocked, leave it unchecked and add a short note under that
   item with the blocker, the attempted command, and the observed result.
7. Keep the Python implementation frozen. Use it as an oracle, not as a place
   to make new feature work.
8. Port Python algorithms function-for-function before optimizing. If Python
   calls a named library algorithm, such as OpenCV ECC, OpenCV morphology,
   scikit-image Meijering, scikit-image biharmonic inpainting, SciPy shift, or
   NumPy FFT helpers, Zig must either call that same algorithm or port the same
   algorithmic semantics closely enough to be defended against Python oracle
   fixtures. A different detector, optimizer, interpolator, or inpainter is not
   parity, even if it is faster or looks close on a smoke test.
9. Do not expose replacement algorithms on the production or public Zig API
   surface while claiming parity. Temporary scaffolds must be private,
   explicitly named as non-parity, and removed once the Python-shaped path
   exists.
10. Every completed parity item needs an algorithm identity note. Record the
    Python function, the third-party algorithm or system API it uses, the Zig
    symbol that ports or delegates that same behavior, and the oracle or replay
    evidence that would catch a substitution. If that note cannot be written,
    leave the item unchecked.
11. Performance work must optimize the same operation, not redefine the
    operation. Better memory layout, fewer allocations, streaming I/O, caching,
    SIMD, threading, or GPU execution are valid only when the observable
    behavior remains traceable to the frozen Python function and its algorithm.
    Any intentionally different algorithm is a separate post-parity experiment
    that needs explicit user approval and must not close a rewrite checklist
    item.
12. Numeric performance work does not need byte-for-byte identity with Python
    or with intermediate Zig buffers. It does need an explicit final-output
    error budget and evidence at the surface that matters: final preview `u8`
    pixels, final export `u16` pixels, binary masks, frame geometry, metadata,
    or scanner replay fields. Very small errors are acceptable for large speed
    gains; silent tolerance expansion, unmeasured visual-only acceptance, or
    algorithm substitution is not.
13. Keep changes scoped. Avoid unrelated refactors, formatting churn, and broad
   rewrites unless the current checklist item requires them.
14. Prefer headless tests and replay fixtures first; run hardware and GUI tests
   only when the environment actually supports them.
15. Avoid redundant Nix evaluations. Assume the conversation is already running
    inside the ambient project nix shell. For ordinary code/test checkpoints,
    build only with direct `zig ...` commands and Zig's local build graph. Do
    not wrap normal builds, tests, UI smokes, scanner commands, or formatting
    in `nix develop`, `nix-shell`, `nix build`, or `nix flake check` unless the
    current checklist item explicitly changes Nix/dependency/package wiring or
    the user explicitly asks for a Nix command.
16. If a new dependency, changed dependency, missing native library, stale Zig
    version, or other shell-environment problem means the ambient nix shell is
    no longer sufficient, stop and ask the human to update or re-open the nix
    shell. Do not run Nix commands to repair or refresh the environment
    yourself.
17. Treat items marked `PENDING USER UPDATE` as parked external blockers, not
    as selectable unchecked work. Do not revisit macOS-only hardware, SDK, or
    live scanner validation while the conversation is on Linux. Resume those
    items only after the user explicitly says a macOS host or other required
    environment is available.

## Autonomous Goal Loop

Use this loop for every work session. Do not skip steps because the next code
change looks obvious.

1. **Refresh state.**
   - Run `git status --short`.
   - Read the next unchecked checklist item and its nearby notes.
   - Inspect the Python oracle code, existing Zig code, tests, and docs for
     that item.
   - Identify whether hardware, platform, or fixture data is required.
2. **Declare the local goal.**
   - Restate the selected checklist item as a concrete deliverable.
   - List the expected artifacts: source files, tests, fixtures, docs, CLI
     commands, hardware evidence, or parity manifest rows.
   - If the selected item is blocked, follow the blocked-item protocol and
     move only to the next unblocked item whose prerequisites are complete.
3. **Implement narrowly.**
   - Make the smallest coherent change that completes the selected item.
   - Keep Python frozen unless the user explicitly requested otherwise.
   - Prefer pure functions, replay fixtures, and deterministic tests before
     live hardware paths.
4. **Verify against the right oracle.**
   - For command construction and parsing, compare exact strings and fields.
   - For numeric image behavior, compare against Python-generated fixtures
     with documented tolerances.
   - Do not require byte-for-byte equality for numeric intermediates when a
     faster path is intentionally approximate. Push accuracy checks through to
     the final quantized preview/export/mask/geometry result, record `max_abs`,
     RMS/MSE, mismatch rate, and any metadata equality that applies, and accept
     the tolerance only when the speedup is large enough to justify it.
   - For every function-shaped port, write down the Python symbol and the
     algorithm or named dependency being matched before treating the Zig result
     as parity. Headless tests should fail if a future change swaps in a
     different algorithm while keeping the same broad output shape.
   - For performance work, first identify the exact Python operation being
     accelerated, including any OpenCV, SciPy, scikit-image, NumPy, or SANE
     behavior it depends on. Then prove the optimized Zig path still matches
     that same operation on fixtures or real-scan oracles. Do not substitute a
     different algorithm to win a benchmark during the parity rewrite.
   - For scanner behavior, use replay tests first and hardware-gated tests
     only when hardware is available.
   - For UI behavior, test state/model logic headlessly before manual window
     testing.
5. **Audit completion.**
   - Confirm every bullet under the checklist item is satisfied.
   - Confirm the definition of done below is satisfied.
   - Confirm no unrelated Python behavior or unrelated files changed.
   - Confirm required commands were run, or record why they could not be run.
6. **Record evidence.**
   - Add or update tests, fixtures, manifest rows, and verification notes.
   - For hardware tests, record exact command, device, output path, geometry,
     bit depth, and relevant metadata.
7. **Check off only after evidence exists.**
   - Mark the checklist item complete only after the audit passes.
   - If the item is partially done, leave it unchecked and add a progress note.
8. **Repeat.**
   - Select the next logically available unchecked item.
   - Do not batch-check future work.

### Selecting The Next Item

The next item is not always the next visible unchecked line. Choose the first
unchecked item that satisfies all of these conditions:

- All earlier prerequisite items are complete or explicitly blocked.
- The current machine can make meaningful progress on it.
- The item can be completed with available source, fixtures, or hardware.
- The work will not force unrelated architecture decisions prematurely.
- The item improves parity, testability, performance, or platform readiness in
  the order this plan lays out.
- The item is not marked `PENDING USER UPDATE`.

If the active user direction is performance measurement or optimization, treat
that as a scoped mode of work: choose performance instrumentation, benchmarks,
or same-behavior optimization items first. Do not drift into release QA, native
UI screenshot capture, packaging, Nix validation, or macOS validation items just
because they are unchecked later in the file. Those items are selected only when
the user explicitly switches back to release, UI, packaging, or platform
validation work.

If two items are available, prefer in this order:

1. Scanner correctness and reliability.
2. Parity manifests and fixtures that prevent future drift.
3. Headless processing and image I/O parity.
4. Frame detection and export parity.
5. Native UI foundation.
6. GPU acceleration and packaging.

### No Proxy Completion

Passing a broad check is not enough to mark an item complete. Treat each signal
as evidence only for what it actually covers.

- `zig build test` proves the tests pass; it does not prove parity unless the
  tests compare against the Python oracle or an accepted fixture.
- A replacement algorithm proves only scaffold value. Do not check off a
  function-by-function port while the Zig path uses a different algorithm than
  the frozen Python path.
- `nix flake check` proves the package/check graph evaluates and builds; it
  does not prove scanner hardware behavior.
- A repeated `nix flake check` or `nix build` after every small Zig edit mostly
  proves the same package graph again and accumulates Nix store outputs. Do not
  treat redundant Nix evaluation as stronger parity evidence.
- A successful hardware scan proves that specific scan mode and command; it
  does not prove every scanner mode.
- A compiled UI proves build integration; it does not prove workflow parity.
- A replay protocol test proves byte construction/parsing; it does not prove
  live macOS interpreter behavior.

### Session Handoff Requirements

At the end of a work session, leave enough evidence that the next agent can
continue without redoing investigation.

The final summary or verification log entry should include:

- Checklist item worked.
- Files changed.
- Python oracle consulted.
- Tests and commands run.
- Hardware or platform evidence, if any.
- Known limitations or remaining unchecked work.
- The next logical unchecked item.

## Definition Of Done

Every checklist item must satisfy all applicable requirements in this section
before it can be marked complete.

### Required For Every Item

- The implementation is present and wired into the build or documented as a
  fixture-only item.
- The Python oracle source or reference behavior has been identified.
- Headless tests or replay fixtures cover the new behavior where possible.
- `zig build test --summary all` passes after Zig changes using the
  conversation's ambient nix shell. Do not use `nix develop path:. -c` as a
  build/test wrapper for ordinary checkpoints.
- `zig build --summary all` passes after executable or build-system changes
  using the conversation's ambient nix shell. Do not use a Nix wrapper for this
  command unless this checklist item is specifically about Nix/package wiring.
- `nix flake check path:.` passes only before completing a multi-item stage,
  after dependency/flake/build-system changes, or when the selected checklist
  item explicitly concerns packaging/check wiring.
- `nix build path:. --no-link` passes only before packaging/release gates or
  when package installation semantics changed. It is not required for ordinary
  implementation checkpoints.
- The parity manifest is updated when the item ports Python behavior. A
  replacement algorithm may be recorded only as non-parity scaffold or as a
  separate user-approved post-parity experiment.
- The verification log is updated with commands run and results observed.
- No Python files are changed unless the user explicitly requested a Python
  change.
- Any skipped check is explicitly recorded with the reason it could not run.

### Required For Scanner Items

- Replay tests cover command planning, parsing, and error handling.
- Hardware-free tests do not require the V600.
- Hardware tests are gated and never run as part of default `nix flake check`.
- Live hardware evidence is recorded when the scanner is available.
- Slow startup behavior is considered; do not add extra `scanimage -L` or
  `scanimage --help` calls on scan hot paths without a measured reason.
- Structured events and errors are stable enough for CLI, tests, and future UI
  consumers.

### Required For Processing Items

- Python fixture outputs are generated or identified.
- The Python function and any third-party algorithm it relies on are named.
- Different algorithms remain unchecked scaffolds until replaced by a direct
  port, same-library call, or explicit user-approved behavior change.
- Performance improvements preserve the same Python algorithmic contract. A
  faster implementation may change allocation strategy, storage order,
  batching, parallelism, or low-level math implementation only when parity
  fixtures prove the same observable behavior.
- Processing code that sorts real image-sized arrays must use non-quadratic
  algorithms. Insertion sort is acceptable only for tiny fixed-size arrays where
  the size bound is documented next to the call site.
- Numeric tolerances are documented next to the test or manifest row.
- Small synthetic cases cover edge behavior.
- At least one representative image or array fixture covers realistic behavior
  when practical.
- Performance-sensitive code has a baseline benchmark or a note explaining why
  benchmarking is deferred.

### Required For UI Items

- UI state transitions are testable without opening a real window.
- SDL3 and Nuklear integration is isolated from application logic.
- Manual screenshot/window checks are documented when headless verification
  cannot cover the behavior.
- UI changes preserve current workflow semantics before adding new ergonomics.
- UI adapters must not absorb scanner, processing, or image algorithms. Native
  UI code may model state and issue commands, but the algorithmic work must be
  delegated to the Zig ports of the corresponding Python functions.
- All image-processing work reachable from the native UI must run behind an
  asynchronous worker boundary with copied inputs and generation/key checks.
  The SDL/Nuklear event, render, and state-management paths may upload completed
  buffers, draw overlays, and update state, but must not run TIFF loading,
  preview inversion, frame detection, Dmin, export, or scanner image processing
  synchronously.

### Required For Platform-Specific Items

- Linux-only, macOS-only, and Windows-only assumptions are called out.
- Code compiles on every target that the flake currently exposes or is gated
  behind target checks.
- macOS scanner work has replay tests on Linux before live macOS testing.
- Any untested platform behavior is left unchecked or marked with a blocker
  note, not treated as complete.

## Completion Audit Template

Use this template mentally for small items and write it into the verification
log for larger items.

```md
### YYYY-MM-DD: <checklist item title>

- Checklist item: `<exact unchecked item text>`
- Python oracle: `<file/function/line range or reason none>`
- Zig artifacts: `<files/functions/tests>`
- Fixtures: `<paths or none>`
- Commands:
  - `<command>` -> `<result>`
- Hardware evidence:
  - `<device/output/geometry/depth or not applicable>`
- Parity notes:
  - `<exact match, tolerance, or known deviation>`
- Blockers:
  - `<none or concrete blocker>`
- Completion decision:
  - `<complete or remains unchecked>`
```

## Blocked Item Protocol

An item is blocked when it cannot be completed with the current machine,
platform, source information, fixture data, or user permission.

When blocked:

1. Leave the item unchecked.
2. Add an indented `Blocked:` note directly under the item.
3. Include the date, command or action attempted, actual error/result, and what
   input or environment is needed.
4. Continue only if there is a later checklist item whose prerequisites do not
   depend on the blocked work.
5. Do not mark a blocked item complete because a replay test passed if the item
   explicitly requires live hardware or platform verification.

## Final Goal

Produce a complete, cross-platform Zig application that is behavior-compatible
with the Python project:

- Same scanner capabilities and scan output semantics.
- Same frame detection behavior and coordinate conventions.
- Same film inversion, color, dust removal, and export results within explicit
  numeric tolerances.
- Same configuration defaults, persistence, and runtime parameter scaling.
- Same user workflows, first in CLI/headless form and later in a native UI.
- Native UI built with SDL3 for cross-platform windowing and events.
- Nuklear remains the immediate-mode UI framework.
- Future GPU acceleration targets WebGPU, using nixpkgs `wgpu-native` first
  and keeping the backend boundary narrow enough to swap to Google Dawn later
  if that becomes necessary.
- Nix remains the dependency and build environment for development, checks,
  and packaging.

## Strategic Constraints

### Python Is Frozen

- Do not change Python behavior as part of the rewrite unless the user
  explicitly asks for a bug fix in the frozen implementation.
- If Python behavior is odd but relied on by current workflows, port the odd
  behavior first and document it.
- If a Python path cannot be run because it needs hardware, scans, GUI, or
  platform-specific dependencies, say so and rely on replay fixtures until it
  can be run.
- Preserve Python files as the reference corpus for parity tests.

### Ambient Nix Shell, Zig Builds

- The dependency environment is the conversation's ambient project nix shell.
  Agents must rely on that shell being open and must use direct `zig ...`
  commands for builds, tests, formatting, UI smoke checks, scanner CLI checks,
  and benchmarks.
- Do not invoke `nix develop path:. -c ...`, `nix-shell --run ...`, `nix
  build`, or `nix flake check` for normal implementation checkpoints. These
  commands are allowed only when the current checklist item explicitly changes
  Nix/dependency/package/check wiring, when entering the shell is the requested
  task, or when the user explicitly asks for a Nix command.
- If direct `zig build ...` fails because a native dependency cannot be found,
  record it as an ambient-shell problem and stop that validation path. Do not
  compensate by repeatedly re-entering or re-evaluating Nix.
- If a new dependency or updated nix shell is needed, stop and ask the human
  for assistance. Agents must not self-refresh the shell, update channels, run
  `nix develop`, or otherwise repair the Nix environment on their own.
- Use the flake/shell definitions for dependency declarations. The target Zig
  version is 0.16.0.
- Do not add pip, poetry, conda, venv, npm, or other parallel dependency
  systems.
- Add new native dependencies to `flake.nix` when they are required.
- SDL3, Nuklear, WebGPU via `wgpu-native`, libtiff, libusb, SANE, and platform SDK
  dependencies should be introduced through Nix where possible.
- Keep checks split into hardware-free checks and explicitly gated hardware
  smoke checks.
- Minimize Nix store churn. Ordinary Zig implementation, fixture, and docs
  iterations must reuse the ambient shell and local `.zig-cache`.
- If direct Zig cannot find a native library, ask the user to update or re-open
  the ambient shell. Do not normalize repeated wrapper evaluations and do not
  attempt the shell update yourself.
- The local `.envrc` currently uses `use nix`, so `shell.nix` must come from a
  nixpkgs channel with Zig 0.16.0 and the same native libraries as the flake dev
  shell. If the channel is older, update the channel or switch the local direnv
  entry to `use flake` before relying on direct Zig commands.

### Scanner Priority

- Linux scanner work uses SANE and the existing `scanimage-v600` and
  `scanimage-v600-ir` wrapper behavior.
- macOS scanner work uses the Epson Interpreter path and must be ported from
  Python and docs blind on Linux, then verified later on macOS hardware.
- Scanner startup can be slow. Avoid unnecessary `scanimage -L` and
  `scanimage --help` calls on hot paths.
- Cache or reuse discovered device identity where it does not change behavior.
- Keep hardware tests explicit and gated. Never make CI or `nix flake check`
  depend on scanner hardware.

### UI Direction

- The browser UI is a parity reference, not the long-term UI.
- Browser JavaScript behavior is a reference for interaction semantics only.
  Scanner and processing behavior still comes from the Python route handlers
  and backend modules; native UI work must call or wrap those function-shaped
  Zig ports instead of inventing parallel algorithms.
- Native UI will use SDL3 for window creation, input, clipboard, timers, file
  dialogs where practical, and cross-platform event integration.
- Nuklear remains the immediate-mode GUI layer.
- Rendering may start simple and CPU-backed if needed, but the long-term target
  is WebGPU for GPU acceleration. The first Nix-backed implementation target is
  nixpkgs `wgpu-native`; keep Zig GPU code behind an internal backend boundary
  so Google Dawn remains a future implementation option rather than a hard
  project dependency.
- Do not prematurely redesign workflows. First preserve the Python UI's user
  behavior; then improve native ergonomics after parity is credible.

### Image And Numeric Parity

- Use exact parity where practical for parsing, config, command construction,
  scanner metadata, and file naming.
- Use tolerance-based parity for floating-point image processing.
- Record tolerances per module. Do not hide meaningful algorithmic drift under
  broad tolerances.
- Prefer deterministic fixtures: small arrays, small TIFFs, captured command
  outputs, serialized config files, scanner protocol byte traces, and exported
  metadata.
- Treat algorithm identity as part of the behavior contract. If Python uses a
  specific library primitive, Zig should call that primitive, bind to the same
  underlying algorithm contract, or port the same steps directly in the same
  order. Tolerance handles numeric representation differences, not a different
  detector, solver, optimizer, morphology kernel, interpolator, inpainting
  method, or percentile definition.
- Prefer the Python call graph as the rewrite outline. A Zig checkpoint can
  split code into cleaner functions, but it must still be traceable back to the
  frozen Python functions and their named dependencies. A broad native
  substitute that happens to pass a visual smoke test is not a function-for-
  function port.
- Each parity checkpoint must name the exact Python function or embedded
  browser function being ported. If no Python function is named, the work is
  infrastructure or adapter scaffolding and cannot close an algorithm parity
  item.

## Invariants To Respect

### Scanner Invariants

- Linux and macOS scanner paths are distinct.
- Linux RGB TPU scans should route through `scanimage-v600` when available.
- Linux IR scans require the verified `scanimage-v600-ir` wrapper. Do not treat
  plain `scanimage` plus `SCAN_IR_MODE=1` as a supported fallback unless a
  packaged dispatcher is added and live-tested; the wrapper must load the
  patched interpreter, epkowa backend, and SANE config path together.
- Linux IR and RGB+IR device selection must prefer an `epkowa` /
  `epkowa:interpreter` device and must not use a cached `epson2` device.
- TPU source name is `Transparency Unit`.
- Flatbed source name is `Flatbed`.
- TPU supported resolutions are 400, 800, 1600, and 3200 DPI.
- IR supported resolutions are 800, 1600, and 3200 DPI.
- IR mode is grayscale.
- Non-IR 16-bit scans pass `--depth 16`.
- Output format for scanner-produced files is TIFF.
- SANE scan areas are specified in millimeters using `-l`, `-t`, `-x`, and
  `-y`.
- Area clamping must respect source geometry and the 0.1 mm safety margin.
- TPU scans are mirrored horizontally in the Python path after loading; Zig
  must preserve the same final image orientation.
- RGB plus IR combined files use page 0 for RGB and page 2 for IR; page 1 may
  be a thumbnail.
- Do not assume RGB and IR scans have the same dimensions.
- Scanner progress should be surfaced as structured events.
- Cancellation must terminate the running scan process or protocol operation
  and report a structured cancellation error.
- Scanner errors must be structured enough for a future UI to distinguish busy,
  missing device, cancellation, and backend failure.

### macOS Interpreter Invariants

- Epson Interpreter bundles perform protocol translation but call host-provided
  USB read/write callbacks.
- Direct RS commands bypass the interpreter and can desynchronize interpreter
  state.
- After direct RS commands, reinitialization may be required.
- IR enablement uses the 32-byte XOR challenge key captured in Python/docs.
- TPU calibration command ordering must match captured traces unless hardware
  testing proves otherwise.
- macOS code must be ported behind replayable protocol builders/parsers before
  it is tested on macOS hardware.

### Frame Detection Invariants

- Detection runs on a downscaled preview.
- Frame rectangles are stored in preview coordinates.
- Full-resolution coordinates are obtained by scaling by `1 / preview_scale`.
- Formats exposed by the frozen Python UI/source are 35mm, 645, 6x6, 6x7,
  and 6x9.
- The 35mm spec is 24x36 mm with 38 mm pitch.
- The 645 spec is 56x41.5 mm with 60 mm pitch.
- The 6x6 spec is 56x56 mm with 60 mm pitch.
- The 6x7 spec is 56x69 mm with 73 mm pitch.
- The 6x9 spec is 56x84 mm with 88 mm pitch.
- Edge-based detection uses 1D strip intensity profiles, DTW pitch alignment,
  gradient snapping, size-consistency correction, first/last frame repair,
  cross-strip positioning, and Theil-Sen angle estimation.
- If detection returns exactly one frame covering less than 30 percent of the
  image, it is a detection failure and must fall back to a full-image frame.

### Processing Invariants

- Raw scanner data is 16-bit RGB plus optional IR.
- Processing order is transmittance, density, Dmin subtraction, film stock
  transform, scene-linear RGB, tone map, gamut map, sRGB output.
- Dmin can be computed from rebate selection or from the full image fallback.
- Film stock coefficients are a 3x10 quadratic polynomial in density space
  using basis `[R, G, B, R^2, G^2, B^2, RG, RB, GB, 1]`.
- IR defect detection uses thresholding, dilation/closing, coverage limits,
  and inpainting.
- Parameter values are defined at reference 800 DPI.
- Linear parameters scale by `current_dpi / 800`.
- Area parameters scale by `(current_dpi / 800)^2`.

### Config Invariants

- Scanner config and processing config are separate systems.
- Scanner config file is `epdaughter_config.toml`.
- Processing config file is `scratchndent_config.toml`.
- Config is loaded once into memory in the Python implementation.
- Save operations merge and persist; do not bypass the config layer by reading
  TOML directly in parity code.
- Preserve defaults, section names, value names, comments where practical, and
  DPI-scaled access behavior.

### File And Metadata Invariants

- TIFF metadata should preserve make, model, software, resolution, resolution
  unit, datetime behavior where practical, and custom LUT markers.
- Generated outputs are gitignored and must not be assumed to exist in a fresh
  checkout.
- Scanner outputs belong in `scans/` by default in the current app.
- Export outputs belong in `frames/` by default in the current app.
- Sidecar metadata in the Zig rewrite should record the exact command,
  effective settings, device, software, and parity-relevant scan context.

## Test Strategy

### Validation Tiers

Use the cheapest validation tier that actually covers the change. The goal is
high confidence with low Nix store churn, not repeated full-package rebuilds.

#### Tier 1: Ordinary Zig Implementation Loop

Run after normal Zig source, fixture, and parity-test edits:

```sh
zig build test --summary all
```

This is the default checkpoint for most autonomous goal-loop iterations. It
uses the ambient nix shell plus Zig's incremental build cache and should be
preferred over full Nix package builds when dependencies and flake outputs did
not change.

#### Tier 2: Executable Or Build Graph Check

Run when changing `build.zig`, CLI wiring, installed artifacts, benchmarks, or
code paths that must compile into the executable but are not fully covered by
tests:

```sh
zig build --summary all
```

#### Tier 3: Nix Graph Evaluation

Run only when changing `flake.nix`, `flake.lock`, dependency sets, dev-shell
contents, check definitions, package wiring, platform exposure, or at an
explicit multi-item milestone:

```sh
nix flake check path:.
```

#### Tier 4: Package Build

Run only before packaging/release checkpoints or when package install semantics
changed:

```sh
nix build path:. --no-link
```

Do not run Tier 3 or Tier 4 just because a small Zig detector, processing, or
fixture checkpoint passed Tier 1. If a future agent thinks a full Nix gate is
needed, it should record the concrete reason in the verification log.

Run after Python-only inspection or parity fixture generation when dependencies
are available:

```sh
basedpyright v600/ scratchndent/
```

Do not claim Python runtime success unless the command was actually run inside
the ambient nix shell with the needed Python dependencies available.

### Hardware-Gated Scanner Checks

Only run on a machine with the V600 connected and configured:

```sh
zig build run -- scanner devices
zig build run -- scanner probe
env V600_HARDWARE_SMOKE=1 zig build run -- scanner smoke --out /tmp/v600-zig-rgb-smoke.tiff --source tpu --dpi 400 --kind rgb --depth 16
zig build run -- scanner scan --out /tmp/v600-zig-ir-smoke.tiff --source tpu --dpi 800 --kind ir --depth 8 --width 0.5 --height 0.5
identify -verbose /tmp/v600-zig-rgb-smoke.tiff
identify -verbose /tmp/v600-zig-ir-smoke.tiff
```

Expected Linux V600 evidence on the current machine:

- Device name similar to `epkowa:interpreter:001:017`.
- `scanimage-v600` available.
- `scanimage-v600-ir` available.
- RGB TPU smoke scan writes a 16-bit RGB TIFF.
- IR smoke scan writes an 8-bit grayscale TIFF.

### Python Oracle Checks

Use Python to produce expected behavior, command shapes, metadata, and numeric
outputs whenever the environment permits it.

Suggested fixture types:

- `scanimage -L` captured output.
- `scanimage --help` captured output for flatbed and TPU.
- Scanner command argv and environment expectations.
- Small synthetic RGB/IR arrays.
- Small TIFFs with known metadata and page layouts.
- Frame detection preview images and expected rectangles.
- Config files with expected round-trip output.
- XMP sidecars with expected parsed fields.
- Film stock coefficient fixtures.
- Export output hashes or metrics for representative scans.

### Parity Test Requirements

For each ported Python function or module:

- Identify the Python source function and line range.
- Treat that Python function as the executable algorithm spec. Do not replace
  a Python algorithm with a new algorithm unless the user explicitly approves
  the divergence as post-parity work.
- Preserve named algorithm dependencies from the Python path. If Python uses
  NumPy, OpenCV, SciPy, scikit-image, SANE, or the Epson interpreter behavior,
  the Zig checkpoint must either call the same dependency contract or prove an
  exact function-shaped port against Python oracle fixtures.
- For scanner work, anchor every checkpoint to the specific Python function:
  `v600/gui/scan_handlers.py:_handle_preview`,
  `v600/gui/scan_handlers.py:_handle_scan`, `scanner.py:EpsonScanner.scan`,
  or `v600/core/backends/sane.py:SaneEpsonScanner.scan`. New native UI worker,
  event, or queue shapes are adapters only; they are not complete until the
  corresponding Python handler/backend function behavior is ported or a
  remaining blocker is recorded.
- Write a Zig test for normal behavior.
- Write a Zig test for at least one boundary behavior.
- If output is numeric, record tolerance and why it is acceptable.
- If output is file data, inspect metadata as well as pixels.
- If behavior depends on platform or hardware, add a replay test and a gated
  live test command.
- Do not delete or weaken parity tests without replacing their coverage.

## Fixture And Evidence Layout

Use committed fixtures for small deterministic evidence and keep large scanner
outputs gitignored.

Recommended committed layout:

```text
test/
  fixtures/
    scanner/
      scanimage-list/
      scanimage-help/
      stderr/
      events/
      metadata/
    imaging/
      arrays/
      tiff/
      xmp/
    frames/
      synthetic/
      ground-truth/
    processing/
      python-oracle/
      expected/
```

Recommended generated or local-only layout:

```text
scans/                  real scanner input and smoke outputs, gitignored
frames/                 export outputs, gitignored
/tmp/v600-*             temporary hardware smoke outputs
```

Fixture rules:

- Commit small text fixtures such as `scanimage -L`, `scanimage --help`,
  stderr samples, JSON events, TOML configs, XMP files, and metadata sidecars.
- Commit small binary fixtures only when they are essential and reasonably
  sized.
- Do not commit full-resolution scanner TIFFs unless the user explicitly
  approves the size and content.
- If a large real scan is needed, document its expected local path and provide
  a fallback synthetic fixture.
- Each fixture should state how it was generated, either in the filename, a
  nearby README, or the verification log.
- Python oracle fixtures should record the Python command used to generate
  them and the dependency environment used.

## Parity Manifest

The function-by-function mapping lives in `docs/PARITY_MANIFEST.md`.

Manifest rules:

- Add a row before or during each port, not after the whole phase is finished.
- A Python function can map to multiple Zig functions if the design is cleaner;
  the row must still make the behavior coverage traceable.
- Do not mark a row `parity-accepted` while any required checklist evidence is
  missing.
- If Zig intentionally differs from Python, record the user-approved reason.

Allowed status values:

- `not-started`: no meaningful Zig implementation.
- `scaffolded`: types or stubs exist, but behavior is incomplete.
- `replay-tested`: deterministic tests cover captured or synthetic behavior.
- `oracle-tested`: Zig output compared to Python output.
- `hardware-tested`: relevant scanner or platform hardware was exercised.
- `parity-accepted`: all applicable tests, oracle comparison, and live checks
  are complete.
- `deferred`: intentionally delayed with a recorded reason.
- `blocked`: cannot proceed without specific input or environment.

## Verification Log

This file was reconstructed on 2026-05-15 after a disk-full write attempt
truncated `plan.md` to zero bytes. The reconstruction is based on the prior
plan content visible in command output, `AGENTS.md`, `docs/PARITY_MANIFEST.md`,
the current repo state, and the active checkpoint history. Treat this entry as
the durable source of current goal-loop state going forward.

### 2026-05-15: Plan Hardened For Autonomous Goal Loop

- Expanded `plan.md` with autonomous goal-loop rules, next-item selection,
  no-proxy-completion guidance, definition of done, completion audit template,
  blocked-item protocol, fixture layout, parity manifest rules, and session
  handoff requirements.
- Added Phase 1 checklist items to create `docs/PARITY_MANIFEST.md` and
  committed scanner replay fixture directories before continuing deeper scanner
  work.
- Verified the requested SDL3, Nuklear, WebGPU, and initially Dawn-oriented
  direction remains present in the plan. Updated on 2026-05-17 to use nixpkgs
  `wgpu-native` as the first concrete WebGPU dependency because nixpkgs `dawn`
  is an unrelated PostScript package and the Google Dawn tree is not packaged
  as a reusable standalone dependency in the pinned package set.

### 2026-05-15: Direct Zig Shell Requirement Tightened

- Confirmed `zig version` in the active terminal can be `0.16.0`, but direct
  `zig build test --summary all` still failed when the shell was missing the
  flake's `superlu` library path.
- Confirmed `nix develop path:. -c ...` brings in the correct flake dev-shell
  inputs, including `superlu`, but repeated use of that wrapper is a workaround
  and not the intended steady-state loop.
- Updated `shell.nix` to include the Zig rewrite native dependencies
  (`zig`, `zls`, `zlib`, `superlu`) and to fail fast when `<nixpkgs>` provides
  a Zig older than 0.16.0.
- Local channel evidence 2026-05-15: `nix-shell --run 'zig version'` selected
  Zig `0.14.1`, so this machine either needs a newer nixpkgs channel for
  `use nix`/`shell.nix`, or the local `.envrc` should switch to `use flake`.

### 2026-05-15: Scanner Foundation And Parity Fixtures

- Created `docs/PARITY_MANIFEST.md`.
- Created scanner replay fixture roots under `test/fixtures/scanner/`.
- Added persistent Linux scanner device cache for hot-path startup behavior.
- Added structured scanner JSON event schema.
- Added richer SANE stderr parsing.
- Added Linux scanner cancellation integration test.
- Ported full-area RGB metadata, selected-area RGB, selected-area IR, RGB plus
  IR combined command construction, TPU horizontal mirror parity, custom LUT
  integration, scanner config load/save, and explicit Linux USB reset recovery.
- Expanded macOS interpreter protocol replay coverage. Live macOS hardware
  testing remains blocked until a macOS machine with the scanner is available.
- Added a replay-tested macOS callback/runtime shell for interpreter callback
  registration, USB read/write callback semantics, direct RS/register ACK
  handshakes, gamma upload ordering, and TPU calibration sequencing.

### 2026-05-15: macOS Interpreter Discovery Blind Port

- Ported `scanner.py:58 find_interpreter` into `src/scanner/macos.zig` as
  `findInterpreter`/`findInterpreterForHost`, preserving Python's Linux
  no-op behavior and first-existing-path probe on non-Linux hosts.
- Added temp-directory replay tests for Linux returning `null` even when a
  local firmware file exists, macOS-like hosts returning the first local
  firmware path, and non-Linux no-match returning `null`.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `306/306`. No Nix command was run. No durable fixture was needed because the
  tested behavior is filesystem probing over synthetic paths.

### 2026-05-15: macOS Scan Data Reader Blind Port

- Ported `scanner.py:920 read_scan_data` into `src/scanner/macos.zig` as
  `readScanData`, preserving Python's block count plus optional final-block
  sizing, data-before-status append behavior, partial return on read failure,
  fatal and cancel status handling, and ACK placement between successful
  non-terminal blocks only.
- Added fake-interpreter replay tests for full-block plus final-block reads,
  interpreter read failure, fatal status, and cancel-request status. The helper
  remains a lower-level primitive; high-level macOS scanner dispatch and
  `scan()` progress/cancel wiring are not claimed complete.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `310/310`. No Nix command was run.

### 2026-05-15: macOS Start Extended Scan Blind Port

- Ported `scanner.py:894 start_extended_scan` into `src/scanner/macos.zig` as
  `startExtendedScan`, preserving Python's `FS G` write, 14-byte response read,
  block-info parsing, and `None`/`null` return on command failure, read failure,
  invalid STX, fatal status, or scanner-not-ready status.
- Added fake-interpreter replay tests for a successful runtime exchange and
  Python `None` response cases. Live exchange with the proprietary interpreter
  remains blocked until macOS bundle loading and USB binding are complete on a
  macOS host.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `312/312`. No Nix command was run.

### 2026-05-15: macOS Interpreter Command ACK Blind Port

- Ported Python interpreter command exchange helpers into
  `src/scanner/macos.zig`: `_cmd_ack` as `commandAck`, `reset` as `reset`,
  `set_scanning_parameters` as `setScanningParameters`, and `enable_infrared`
  as `enableInfrared`.
- Preserved Python's ACK behavior exactly: write/read failures return false,
  ACK returns true, NAK returns false, and unexpected non-ACK/non-NAK responses
  are assumed successful. FS W sends the command with ACK, then the 64-byte
  parameter block with ACK. IR enablement sends FS S, reads 64 bytes, XORs the
  first 32 bytes, then ACKs both ESC # and the challenge response.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `316/316`. No Nix command was run.

### 2026-05-15: macOS Interpreter Setup Command Blind Port

- Added replay-tested runtime wrappers for Python's identity/status reads and
  write-only setup commands: `getIdentity`, `getStatus`, `getExtendedStatus`,
  `getExtendedIdentity`, `setResolution`, `setScanArea`, `setColorMode`,
  `setDataFormat`, `setSource`, and `startScan`.
- Preserved the Python command shapes by reusing the already ported command
  builders, then proving the fake interpreter sees the exact write sequence and
  read buffers expected by the Python methods. `getExtendedIdentity` also
  parses the returned 80-byte FS I response into the typed Zig capability
  structure.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `319/319`. No Nix command was run.

### 2026-05-15: macOS Capability Conversion Blind Port

- Added `capabilitiesFromExtendedIdentity` to map a parsed 80-byte FS I
  `ExtendedIdentity` into the shared `ScannerCapabilities` contract using the
  same Python formulas: optical DPI directly, max resolution directly, flatbed
  and TPU dimensions divided by optical DPI, IR from capability bit `0x02`, and
  model from the trimmed identity bytes.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `320/320`. No Nix command was run.

### 2026-05-15: macOS Scan Planning Blind Port

- Added `planScan` to mirror the pure planning portion of Python
  `scanner.py:961 scan`: defaulting full scan area from capabilities, snapping
  requested DPI through Python's valid-resolution lists, truncating inch
  coordinates to pixels with Python `int()` semantics for non-negative inputs,
  selecting color/source codes for RGB/gray/IR, computing channels and expected
  byte counts, and producing the `SetParameters` values consumed by FS W.
- Added replay tests for TPU RGB full-area planning with ordinary DPI snapping
  and selected-area IR planning with the IR-only resolution table, including
  Python's first-wins tie behavior for nearest resolution.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `322/322`. No Nix command was run.

### 2026-05-15: SANE No-Hardware Method Parity

- Ported Python's deterministic SANE no-hardware methods into
  `src/scanner/linux.zig`: `SaneEpsonScanner.close` as `Runtime.close`,
  `get_identity` as `saneIdentity`/`Runtime.getIdentity`, `get_status` as
  `saneStatus`/`Runtime.getStatus`, and `get_extended_identity` as
  `saneExtendedIdentity`/`Runtime.getExtendedIdentity`.
- Preserved Python's exact behavior: close is a no-op, identity is ASCII
  `SANE {model}`, status is one ready byte `0x00`, and extended identity is
  80 zero bytes.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `323/323`. No Nix command was run.

### 2026-05-15: Scanner Backend Dispatch Facade

- Added an explicit scanner backend selector in `src/scanner.zig` matching
  Python `EpsonScanner.__init__`: Linux selects the SANE backend and non-Linux
  hosts select the interpreter backend family.
- Threaded the selector into `src/main.zig` so scanner CLI commands now pass
  through `handleScannerSane` on Linux and fail explicitly on interpreter hosts
  until macOS bundle loading, USB binding, and live interpreter runtime wiring
  are complete.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `324/324`; direct `zig build --summary all` passed; direct
  `zig build -Dui=true --summary all` passed. No Nix command was run.

### 2026-05-15: SANE Constructor State Parity

- Added `SaneBackendState` in `src/scanner/linux.zig` to make Python
  `SaneEpsonScanner.__init__` state explicit: `device_name = None`,
  `model = None`, caller-provided product ID, and no cached capabilities.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `325/325`; direct `zig build --summary all` passed; direct
  `zig build -Dui=true --summary all` passed; `git diff --check` passed. No
  Nix command was run.

### 2026-05-15: SANE Save Routing Parity

- Added `planSaveImage` in `src/scanner/linux.zig` to pin the pure routing
  portion of Python `_save_image`: `.tif`/`.tiff` and unknown extensions write
  TIFF to the requested path, 8-bit `.png` writes PNG to the requested path,
  and 16-bit `.png` rewrites exact `.png` occurrences to `.tiff` before writing
  TIFF.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `326/326`; direct `zig build --summary all` passed; direct
  `zig build -Dui=true --summary all` passed; `git diff --check` passed. No
  Nix command was run.

### 2026-05-15: macOS Smoke Skip Entrypoint

- Added `scanner macos-smoke` in `src/main.zig` and
  `macos-scanner-smoke-skip` in `build.zig`. The command is inert by default
  and requires `V600_MACOS_HARDWARE_SMOKE=1` before it can attempt any future
  live macOS scanner work.
- Added the skip step to `flake.nix` check wiring so package checks can verify
  the no-hardware path later. This did not add or change dependencies, and no
  Nix command was run for this checkpoint.
- Validation 2026-05-15: direct
  `zig build macos-scanner-smoke-skip --summary all` passed and printed the
  expected skip message; direct `zig build test --summary all` passed
  `326/326`; direct `zig build --summary all` passed; direct
  `zig build -Dui=true --summary all` passed; `git diff --check` passed.
- Follow-up validation 2026-05-15: direct
  `env V600_MACOS_HARDWARE_SMOKE=0 zig build run -- scanner macos-smoke`
  skipped; direct
  `env V600_MACOS_HARDWARE_SMOKE=1 zig build run -- scanner macos-smoke` on
  Linux failed before hardware access with `UnsupportedPlatform` and now prints
  the buffered diagnostic before returning the error. Direct
  `zig build test --summary all` passed `326/326`; direct
  `zig build --summary all` passed; direct `zig build -Dui=true --summary all`
  passed.

### 2026-05-15: Manual Interpreter Readiness Helper

- Added `ensureInterpreterManual` and `ensureInterpreterManualForHost` in
  `src/scanner/macos.zig` as the safe, no-download slice of Python
  `ensure_interpreter`. The helper never fetches, mounts, extracts, vendors, or
  writes Epson's ICA driver; it only reports `ready`,
  `missing_manual_install_required`, or `unsupported_linux` and carries the
  Epson ICA URL for human/manual remediation.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `329/329`; direct `zig build --summary all` passed; direct
  `zig build -Dui=true --summary all` passed; `git diff --check` passed. No
  Nix command was run.

### 2026-05-15: macOS Model And Endpoint Selection

- Ported the pure discovery constants from Python's macOS `EpsonScanner.open`
  path into `src/scanner/macos.zig`: Epson vendor ID, supported product IDs,
  model names, interpreter IDs, IR flags, max DPI, and Python's unknown-product
  fallback to Interpreter A1 without IR.
- Added `selectEndpointPair` to preserve the PyUSB descriptor policy of taking
  the first bulk OUT-like endpoint address and first bulk IN-like endpoint
  address from interface order. This is the replay-tested pure slice needed
  before live libusb device open/claim on macOS.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `332/332`; direct `zig build --summary all` passed; direct
  `zig build -Dui=true --summary all` passed. No Nix command was run.

### 2026-05-15: macOS Interpreter Bundle Symbol ABI

- Added `LoadedInterpreter`, `InterpreterSymbols`, and `loadInterpreterSymbols`
  in `src/scanner/macos.zig` to preserve Python's `ctypes.CDLL` symbol binding
  contract for `INTInit`, `INTWrite`, `INTRead`, `INTClose`,
  `INTGetUSBError`, and `INTGetInterpreterError`.
- Kept tests proprietary-bundle-free by replaying the symbol lookup and wrapper
  ABI against fake C-callconv functions. The loader now rejects incomplete
  symbol sets before a session can be initialized.
- Validation 2026-05-15: direct `zig build test --summary all` passed
  `334/334`; direct `zig build --summary all` passed; direct
  `zig build -Dui=true --summary all` passed; direct `zig build
  scanner-smoke-skip scanner-processing-smoke-skip macos-scanner-smoke-skip
  --summary all` passed; direct `zig build -Dui=true
  native-preview-worker-smoke-skip native-scan-worker-smoke-skip --summary all`
  passed. No Nix command was run.

### 2026-05-15: Post-Reload Ambient Shell Validation

- Confirmed the reloaded ambient shell provides Zig `0.16.0`.
- Re-ran the main direct Zig gates from the ambient shell after the dependency
  reload: `zig build test --summary all` passed `329/329`, `zig build --summary
  all` passed, and `zig build -Dui=true --summary all` passed.
- Re-ran the no-hardware skip gates: direct `zig build scanner-smoke-skip
  scanner-processing-smoke-skip macos-scanner-smoke-skip --summary all` passed,
  and direct `zig build -Dui=true native-preview-worker-smoke-skip
  native-scan-worker-smoke-skip --summary all` passed.
- No Nix command was run for this validation.

### 2026-05-15: TIFF And Processing Foundations

- Chose the Zig TIFF strategy and ported DPI metadata reading, TIFF page
  loading, image discovery/unique paths, and TIFF metadata writing.
- Added a committed Python `tifffile` RGB/thumbnail/IR fixture that verifies
  `scratchndent.utils.io.load_tiff_pages` page-selection parity: page 0 RGB,
  page 1 ignored, page 2 IR, with RGB and IR using different dimensions and
  bit depths.
- Added a committed Python `scratchndent.utils.io.write_tiff` exported-frame
  fixture and native `readExportMetadataJson` helper so Zig can inspect the
  exact private tag `65000` JSON produced by the Python export path.
- Ported processing config defaults, DPI-scaled parameter access, film stock
  profile data, and processing config save/merge behavior.
- Decided custom film stock editing behavior for the Zig rewrite: preserve the
  Python manual-TOML `[stocks.*]` workflow and native stock lookup/listing
  parity first; defer any richer native GUI editor until after backend parity.
  The Zig config parser now preserves config-defined stock profiles through
  load/save.
- Ported XMP sidecar parsing.
- Established a numeric fixture harness for Python-oracle comparisons.

### 2026-05-15: Negative, Color, And Performance Foundations

- Ported color matrices/basic transforms, transmittance and density, Dmin
  measurement, film stock polynomial transform, negative inversion pipeline,
  tone mapping, gamut mapping, sRGB output, sigmoid behavior, and Negadoctor
  behavior.
- Added a real-scan negative-to-positive fixture from an 8x8 crop of
  `scans/scan_0006_rgbir_800dpi.tiff`, covering Python `invert_negative`
  through `render_to_display` as one headless parity check without committing
  the full TIFF.
- Added hot color path benchmarks.
- Recorded SIMD and GPU acceleration targets. CPU parity remains first; future
  GPU work targets WebGPU through nixpkgs `wgpu-native` first, while preserving
  an internal boundary that can support Google Dawn later if needed.

### 2026-05-15: Dust Removal Core Progress

- Ported IR thresholding, IR dilation/closing, IR connected-component area
  filtering, and IR max coverage guard.
- Ported IR/RGB alignment through a native OpenCV ECC bridge that calls
  `cv::findTransformECC` with the frozen Python constants and preserves the
  Python fallback-to-unaligned behavior for invalid ECC inputs.
- Ported the Meijering hair/scratch ridge branch used by `make_defect_mask`,
  including area downscale, 99.9 percentile normalization, Hessian eigenvalue
  Meijering response across sigmas 1 through 8, nearest upsample, and sigma
  gating.
- Added deterministic inpainting scaffold tests, but the scaffold is not
  function-for-function parity with Python's biharmonic-plus-grain algorithm.
- End-to-end RGB dust removal parity remains blocked until Python's
  biharmonic-plus-grain inpainting behavior is ported or called.

### 2026-05-15: Frame Detection Components Ported

- Ported frame format specs, 1D strip profile generation, DTW pitch alignment,
  gradient edge snapping, Gaussian weighted peak selection, size-consistency
  correction, first/last frame repair, cross-strip paired-gradient core,
  Theil-Sen angle core, single-frame fallback guard, rotated rectangle crop,
  rebate extraction helpers, and preview-to-full coordinate scaling.
- Current coverage is component-level and fixture-backed. Complete
  `_analyze_strip`/`detect_frames` wiring and full `test_detect.py` parity
  remain unchecked.

### 2026-05-15: Rebate Extraction Helpers Ported

- Completed checklist item: `Port rebate extraction`.
- Python oracle inspected/generated from:
  - `scratchndent/processing/frames/extraction.py:make_rebate_mask`;
  - `scratchndent/processing/frames/extraction.py:rebate_in_bounds`;
  - `scratchndent/processing/frames/extraction.py:extract_rebate_pixels`;
  - `scratchndent/processing/frames/extraction.py:compute_inter_frame_rebate`.
- Added fixture:
  - `test/fixtures/processing/frames/rebate-helpers-smoke.json`.
- Extended `src/processing/frames.zig`.
- Updated `docs/PARITY_MANIFEST.md`.
- Validation commands:
  - `nix develop path:. -c zig build test --summary all` passed with
    `160/160` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: Preview Coordinate Scaling Ported

- Completed checklist item: `Port preview-to-full-resolution coordinate
  scaling`.
- Python oracle inspected/generated from:
  - `v600/gui/process_handlers.py:136`;
  - `v600/gui/process_handlers.py:559`;
  - `v600/gui/extract_ui.html:1280`;
  - `test_detect.py:138`.
- Added fixture:
  - `test/fixtures/processing/frames/preview-coordinate-scaling-smoke.json`.
- Extended `src/processing/frames.zig`.
- Ported:
  - Python preview scale calculation;
  - Python preview dimension truncation;
  - detected-frame preview center rectangle to full-resolution center
    rectangle scaling;
  - UI top-left selection to full-resolution center rectangle conversion;
  - rebate origin rectangle scaling.
- Updated `docs/PARITY_MANIFEST.md`.
- Validation commands:
  - `nix develop path:. -c zig build test --summary all` passed with
    `162/162` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Disk note:
  - A full-gate attempt hit `No space left on device`. Removed disposable
    repo-local `.zig-cache` and ran bounded Nix store GC with `--max 10G` and
    `--max 30G`; the second GC freed about 34 GB and left enough space for the
    successful validation rerun.
- Python files were not modified.

### 2026-05-15: test_detect Ground Truth Parity Harness Added

- Completed checklist item: `Add parity tests against test_detect.py ground
  truth`.
- Python oracle inspected/generated from:
  - `test_detect.py:15` (`TEST_CASES`);
  - `test_detect.py:90` (`compare`);
  - `test_detect.py:138` (`gt_to_full`).
- Added fixture:
  - `test/fixtures/processing/frames/test-detect-ground-truth.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Extended `src/processing/frames.zig`.
- Ported:
  - all four manual `test_detect.py` cases;
  - 16 manual frame rectangles;
  - ground-truth top-left preview rectangle to full-resolution center rectangle
    conversion;
  - RMS scoring over center/dimension errors;
  - angle error semantics;
  - the 30 px RMS acceptance threshold as fixture data.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - This is a headless ground-truth/scoring harness. It intentionally does not
    load the large gitignored scan TIFFs and does not claim complete
    `detect_frames` parity; that remains under later Phase 6 items.
- Validation commands:
  - `nix develop path:. -c zig build test --summary all` passed with
    `163/163` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: Synthetic Frame Detection Fixtures Added

- Completed checklist item: `Add synthetic frame detection fixtures that do
  not require real scans`.
- Added fixture:
  - `test/fixtures/processing/frames/synthetic-detection-fixtures.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Extended `src/processing/frames.zig`.
- Added scan-free fixture coverage for:
  - a vertical 35mm three-frame procedural grayscale strip;
  - a horizontal 6x6 three-frame procedural grayscale strip;
  - generated frame-pixel counts;
  - expected preview-to-full frame conversion;
  - strip-profile smoke validation over the synthesized arrays.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - These are committed targets for later complete `detect_frames` wiring.
    They intentionally do not claim that the full detector is implemented.
- Validation commands:
  - `nix develop path:. -c zig build test --summary all` passed with
    `164/164` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Disk note:
  - A gate attempt again hit `No space left on device` before the build
    command could start. Ran bounded `nix store gc --max 50G`, which freed
    about 55 GB, then reran the full gate successfully.
- Python files were not modified.

### 2026-05-15: Strip Analysis And Initial Placement Ported

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Python oracle inspected/generated from:
  - `scratchndent/processing/frames/detection.py:_analyze_strip`;
  - `scratchndent/processing/frames/detection.py:_initial_placement`.
- Added fixture:
  - `test/fixtures/processing/frames/strip-analysis-initial-placement-smoke.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Extended `src/processing/frames.zig`.
- Ported:
  - orientation choice from image dimensions;
  - optional measured film extent dimensions;
  - pixels-per-mm from strip narrow dimension;
  - frame dimension mapping for vertical and horizontal strips;
  - pitch calculation;
  - Python integer-truncating frame-count formula;
  - centered initial frame placement;
  - strip angle carry-through.
- Updated `docs/PARITY_MANIFEST.md`.
- Completion decision:
  - The full detector wiring item remains unchecked. Film extent detection,
    preprocessing/CLAHE, detector orchestration, cross-strip sample-line
    aggregation, rotation-back transform, and complete output assembly remain.
- Validation commands:
  - `nix develop path:. -c zig build test --summary all` passed with
    `166/166` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: Axis-Aligned Prepared Detector Path Added

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Added fixture:
  - `test/fixtures/processing/frames/axis-aligned-detect-smoke.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Extended `src/processing/frames.zig`.
- Wired:
  - prepared grayscale strip analysis;
  - strip profile generation;
  - absolute gradient computation with Python-style endpoint zeroing and
    detector-stage blur kernel sizing;
  - average-gradient DTW pitch alignment;
  - gradient edge snapping;
  - size-consistency correction;
  - terminal frame repair;
  - frame assembly from strip-axis edge pairs.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - This is a scan-free axis-aligned orchestration path for synthetic strips.
    It intentionally excludes film extent detection, scanner-preview
    preprocessing/CLAHE, Theil-Sen angle aggregation integration, rotated
    cross-strip sampling, rotation-back transform, and real-scan parity.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig build test --summary all` passed with
    `167/167` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: Axis-Aligned Cross-Strip Refinement Integrated

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Updated fixture:
  - `test/fixtures/processing/frames/axis-aligned-detect-smoke.json`.
- Ported and wired:
  - axis-aligned cross-strip line sampling;
  - Python-style pre-gradient smoothing and signed-gradient endpoint zeroing;
  - per-row paired-gradient measurement via `measureCrossStripEdges`;
  - median left/right edge aggregation;
  - cross-center and cross-width update in `detectFramesAxisAlignedPrepared`.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - This is still an axis-aligned prepared-image path. Rotated bilinear
    cross-strip sampling, Theil-Sen angle aggregation integration,
    scanner-preview preprocessing/CLAHE, film extent/rotation handling, and
    real-scan parity remain unchecked.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig build test --summary all` passed with
    `167/167` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Disk note:
  - A gate attempt initially hit `No space left on device`; ran bounded
    `nix store gc --max 50G`, freeing about 55 GB, then reran the full gate.
- Python files were not modified.

### 2026-05-15: Axis-Aligned Theil-Sen Angle Aggregation Integrated

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Updated fixture:
  - `test/fixtures/processing/frames/axis-aligned-detect-smoke.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Ported and wired:
  - Python step-7 angle-gradient strip sampling across 20 cross-strip
    positions;
  - per-strip projection smoothing and absolute-gradient generation;
  - first/last frame edge selection rules that avoid strip-leader and
    strip-end boundaries;
  - per-edge peak search with subpixel quadratic refinement;
  - Theil-Sen angle assignment in `detectFramesAxisAlignedPrepared`.
- Added a sloped-edge 35mm synthetic detector case that asserts non-zero angle
  recovery with an explicit angle tolerance.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - This is still the prepared axis-aligned path. Film extent detection,
    scanner-preview preprocessing/CLAHE, rotated bilinear cross-strip sampling,
    work-scale restoration, rotation-back transform, and real-scan parity
    remain unchecked.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig fmt src/processing/frames.zig` passed.
  - `nix develop path:. -c zig build test --summary all` passed with
    `167/167` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: Rotated Cross-Strip Bilinear Sampling Integrated

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Updated fixture:
  - `test/fixtures/processing/frames/axis-aligned-detect-smoke.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Ported and wired:
  - Python cross-strip sample-line geometry using each frame's current angle;
  - constant-border bilinear sampling equivalent to the `cv2.remap` branch used
    by cross-strip detection;
  - the Python valid-sample coverage guard for rotated sample lines;
  - angle-aware cross-center updates that preserve Python's axis-specific
    coordinate adjustment;
  - true rotated synthetic frame drawing for nonzero-angle detector fixtures.
- Added an explicit rotated cross-size tolerance to the sloped-edge 35mm
  synthetic detector case so the test verifies width recovery, not only center
  and angle.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - This is still the prepared detector path. Film extent detection,
    scanner-preview preprocessing/CLAHE, work-scale restoration,
    rotation-back transform, and real-scan parity remain unchecked.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig fmt src/processing/frames.zig` passed.
  - `nix develop path:. -c zig build test --summary all` passed with
    `167/167` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: Detection Grayscale Preprocessing Boundary Added

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Added fixture:
  - `test/fixtures/processing/frames/detection-gray-preprocess-smoke.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Ported:
  - Python 8-bit grayscale pass-through;
  - Python 8-bit RGB to grayscale conversion for scanner-preview inputs;
  - Python 16-bit grayscale truncation via division by 256;
  - Python 16-bit RGB mean-then-truncate behavior;
  - optional inversion to match the detector preprocessing boundary.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - This pins the dtype/channel conversion and inversion boundary only. CLAHE,
    film extent detection, rotation correction/back-transform, full wrapper
    wiring, and real-scan parity remain unchecked.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig fmt src/processing/frames.zig` passed.
  - `nix develop path:. -c zig build test --summary all` passed with
    `169/169` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Disk note:
  - The first build gate attempt failed before Zig ran because Nix could not
    create a `/tmp/nix-develop-*` directory (`No space left on device`). Ran
    bounded `nix store gc --max 50G`, freeing about 55 GB, then reran the
    build, flake check, and package build successfully.
- Python files were not modified.

### 2026-05-15: Axis-Aligned Film Extent Detection Added

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Added fixture:
  - `test/fixtures/processing/frames/film-extent-axis-aligned-smoke.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Ported the headless-safe subset of `_detect_film_extent`:
  - Otsu film/background split on raw grayscale values;
  - dark-film mask construction;
  - square morphological close with Python-compatible border behavior for
    unrotated edge-touching strips;
  - largest 8-connected component selection;
  - 10 percent minimum component area guard;
  - axis-aligned min-area-rectangle dimensions using Python's contour
    dimension convention for unrotated rectangles.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - This does not yet port rotated `cv2.minAreaRect` angle extraction, image
    rotation correction, rotation-back transform, CLAHE, full wrapper wiring,
    or real-scan parity.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig fmt src/processing/frames.zig` passed.
  - `nix develop path:. -c zig build test --summary all` passed with
    `170/170` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: Image Buffer Detector Wrapper Added

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Updated existing fixture coverage:
  - `test/fixtures/processing/frames/axis-aligned-detect-smoke.json` is now
    replayed through both `detectFramesAxisAlignedPrepared` and the new
    `detectFramesFromImage` byte-buffer wrapper.
- Wired:
  - TIFF/scanner-style byte image inputs plus channel/depth metadata;
  - `prepareDetectionGray` into detector orchestration;
  - optional film extent detection in the image wrapper;
  - prepared detector invocation from converted image buffers.
- Test scope:
  - Fixture replay disables film extent detection for the wrapper pass to
    isolate byte conversion and orchestration from the still-incomplete
    rotated extent path.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - CLAHE, full film extent integration, rotation correction/back-transform,
    work-scale restoration, and real-scan parity remain unchecked.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig fmt src/processing/frames.zig` passed.
  - `nix develop path:. -c zig build test --summary all` passed with
    `170/170` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: Frozen Work-Scale Behavior Pinned

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Ported and tested the current Python work-scale formula:
  - `work_size = max(img_h, img_w)`;
  - `work_scale = min(work_size / max(img_h, img_w), 1.0)`;
  - therefore `work_scale` is always `1.0` for valid images in the frozen
    implementation.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - This intentionally preserves v1 behavior and avoids adding detector
    downsampling during the parity rewrite. Any future downsampling is a
    separate performance change after parity is proven.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig fmt src/processing/frames.zig` passed.
  - `nix develop path:. -c zig build test --summary all` passed with
    `171/171` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Disk note:
  - The first format/test gate attempt failed before Zig ran because Nix could
    not create a `/tmp/nix-develop-*` directory (`No space left on device`).
    Ran bounded `nix store gc --max 50G`, freeing about 55 GB, then reran the
    test gate successfully.
- Python files were not modified.

### 2026-05-15: Detector Aspect String Contract Added

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Updated fixture:
  - `test/fixtures/processing/frames/axis-aligned-detect-smoke.json`.
- Ported:
  - Python's final `aspect` string contract for vertical and horizontal
    selections;
  - `DetectFramesResult.aspect`;
  - aspect assertions through both `detectFramesAxisAlignedPrepared` and the
    `detectFramesFromImage` byte-buffer wrapper.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - This covers result-shape parity only. CLAHE, full film extent integration,
    rotation correction/back-transform, and real-scan parity remain unchecked.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig fmt src/processing/frames.zig` passed.
  - `nix develop path:. -c zig build test --summary all` passed with
    `172/172` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: OpenCV-Style CLAHE Helper Added

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Added fixture:
  - `test/fixtures/processing/frames/clahe-8bit-smoke.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Ported helper-level behavior matching `cv2.createCLAHE(...).apply` for
  8-bit grayscale fixtures:
  - OpenCV clip-limit scaling;
  - clipped-bin redistribution;
  - cumulative LUT generation;
  - reflect-101 padding for non-divisible tile grids;
  - bilinear interpolation between tile LUTs.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - The CLAHE primitive is oracle-tested, but the detector wrapper still needs
    Python's two-image preprocessing split: CLAHE inverted image for strip-axis
    detection and raw inverted image for cross-strip edge detection.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig fmt src/processing/frames.zig` passed.
  - `nix develop path:. -c zig build test --summary all` passed with
    `174/174` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: CLAHE Detector Wrapper Route Integrated

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Updated `docs/PARITY_MANIFEST.md`.
- Wired Python's two-image preprocessing split into `detectFramesFromImage`:
  - raw grayscale preparation is retained for cross-strip refinement;
  - inverted 8-bit grayscale is CLAHE-processed for strip-axis profiles,
    DTW/snapping, and angle estimation;
  - `DetectFramesOptions.cross_gray_raw` lets the prepared detector use a
    separate raw image for cross-strip edge detection;
  - `DetectFramesImageOptions.apply_clahe` keeps tests able to isolate the
    exact non-CLAHE synthetic detector path.
- Updated the axis-aligned detector fixture harness:
  - non-CLAHE wrapper replay still asserts exact synthetic frame geometry;
  - CLAHE-enabled wrapper replay asserts frame count and aspect contract so the
    route is exercised without pretending synthetic step-edge geometry is a
    real-scan oracle.
- Scope note:
  - Real-scan CLAHE detector parity is still unchecked. Rotated film extent,
    image rotation correction/back-transform, and real-scan parity remain.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig fmt src/processing/frames.zig` passed.
  - `nix develop path:. -c zig build test --summary all` passed with
    `174/174` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Disk note:
  - The first format/test gate attempt failed before Zig ran because Nix could
    not create a `/tmp/nix-develop-*` directory (`No space left on device`).
    Ran bounded `nix store gc --max 50G`, freeing about 51 GB, then reran the
    test gate successfully.
- Python files were not modified.

### 2026-05-15: Rotation-Back Coordinate Transform Added

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Added fixture:
  - `test/fixtures/processing/frames/rotation-back-transform-smoke.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Ported:
  - Python/OpenCV expanded rotation matrix arithmetic;
  - canvas expansion dimensions;
  - inverse affine transform;
  - rotated-coordinate frame center back-transform;
  - global strip angle addition to each residual per-frame angle.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - This pins coordinate math only. Rotated image resampling, rotated
    film-extent angle extraction, end-to-end rotated detector wiring, and
    real-scan parity remain unchecked.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig fmt src/processing/frames.zig` passed.
  - `nix develop path:. -c zig build test --summary all` passed with
    `176/176` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: Expanded Rotation Image Resampling Added

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Added fixture:
  - `test/fixtures/processing/frames/expanded-rotation-resample-smoke.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Ported:
  - grayscale expanded-canvas rotation using the Python/OpenCV rotation matrix;
  - inverse-coordinate destination sampling;
  - bilinear interpolation;
  - replicate-border behavior matching `cv2.BORDER_REPLICATE`.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - This pins the image rotation primitive. Rotated film extent angle
    extraction, end-to-end rotated detector wiring, and real-scan parity remain
    unchecked.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig fmt src/processing/frames.zig` passed.
  - `nix develop path:. -c zig build test --summary all` passed with
    `177/177` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: Synthetic Rotated Film Extent Angle Added

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Added fixture:
  - `test/fixtures/processing/frames/film-extent-rotated-smoke.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Extended film extent detection:
  - largest-component mask capture;
  - PCA principal-axis orientation;
  - projection-based narrow/long dimension estimation;
  - Python sign convention for vertical and horizontal coarse strip angles.
- Updated `docs/PARITY_MANIFEST.md`.
- Scope note:
  - This is a synthetic rotated rectangle approximation against OpenCV
    `minAreaRect` fixtures. Real-scan contour/minAreaRect parity,
    end-to-end rotated detector wiring, and real-scan parity remain unchecked.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `nix develop path:. -c zig fmt src/processing/frames.zig` passed.
  - `nix develop path:. -c zig build test --summary all` passed with
    `178/178` tests.
  - `nix develop path:. -c zig build --summary all` passed.
  - `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
    omitted by Nix as incompatible from this host.
  - `nix build path:. --no-link` passed.
- Python files were not modified.

### 2026-05-15: Rotation-Corrected Detector Wrapper Wired

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Added fixture:
  - `test/fixtures/processing/frames/rotated-wrapper-detect-smoke.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Updated `docs/PARITY_MANIFEST.md`.
- Wired:
  - `DetectFramesImageOptions.film_extent_override` for deterministic measured
    extent replay;
  - Python's 0.1 degree rotation threshold in the image-buffer wrapper;
  - expanded raw grayscale rotation before axis-aligned detection;
  - separate rotated raw cross-strip buffer;
  - rotated-coordinate frame detection followed by center and residual-angle
    transform back to original preview coordinates.
- Scope note:
  - The wrapper route is replay-tested with an explicit measured extent to
    isolate rotation/back-transform routing. Real-scan contour/minAreaRect
    extent parity and full detector parity against available scan fixtures
    remain unchecked.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `zig fmt src/processing/frames.zig` passed.
  - `zig build test --summary all` passed with `179/179` tests.
  - Full Nix gates were intentionally skipped for this ordinary Zig/fixture
    checkpoint under the Validation Tiers policy; no dependency, flake, package,
    or install semantics changed.
- Python files were not modified.

### 2026-05-15: macOS Interpreter Callback Runtime Shell Added

- Completed checklist item: `Implement macOS USB callback/runtime layer`.
- Added `src/scanner/macos.zig`.
- Updated `src/scanner.zig`.
- Updated fixture documentation:
  - `test/fixtures/scanner/interpreter/README.md`.
- Updated `docs/PARITY_MANIFEST.md`.
- Python oracle consulted:
  - `scanner.py:_interp_search_paths`;
  - `scanner.py:_init_interpreter`;
  - `scanner.py:_usb_read`;
  - `scanner.py:_usb_write`;
  - `scanner.py:reinit`;
  - `scanner.py:_direct_write`;
  - `scanner.py:_direct_read`;
  - `scanner.py:_rs_cmd`;
  - `scanner.py:_write_register`;
  - `scanner.py:_upload_gamma_tables`;
  - `scanner.py:configure_tpu`;
  - `docs/SCANNER_INTERNALS.md` callback ABI and direct RS notes.
- Port/parity notes:
  - Added a replay-testable `InterpreterSession` shell that preserves INT init,
    read, write, close, error-query, and reinit call shape without loading the
    proprietary Epson bundle on Linux.
  - Added C ABI callback functions for USB read/write. They preserve Python's
    success/failure convention: return true with `err=0`, or false with `err=-1`
    on invalid callback state or transfer failure.
  - Added a testable `UsbIo` boundary for future macOS endpoint binding.
  - Added direct RS command execution, register-write execution, gamma table
    upload ordering, and TPU calibration program sequencing behind fake-USB
    tests.
  - The Zig callback implementation passes a context pointer through
    `usb_handle`; this replaces Python's bound-method closure state while keeping
    the interpreter-visible contract equivalent because the handle is opaque.
- Scope note:
  - This completes the hardware-free runtime shell. It does not claim live
    macOS scanner initialization, bundle loading, USB interface claiming, or live
    scan behavior; those remain blocked under `Add live macOS scanner smoke
    tests`.
- Validation commands:
  - `zig fmt src/scanner/macos.zig src/scanner.zig` passed.
  - `zig build test --summary all` passed with `194/194` tests in 58 seconds
    from inside the Nix shell. This used direct `zig`; no Nix reevaluation or
    package build was run.
- Python files were not modified.

### 2026-05-15: Full `test_detect.py` Real-Scan Detector Output Parity Added

- Completed checklist item: `Wire complete _analyze_strip/detect_frames behavior
  in Zig`, for the scan fixtures covered by `test_detect.py`.
- Completed checklist item: `Add full detector parity tests for all available
  test_detect.py scan fixtures`.
- Extended `src/processing/frames.zig`.
- Added fixtures:
  - `test/fixtures/processing/frames/test-detect-python-output.json`;
  - `test/fixtures/processing/frames/gradient-snap-scipy-prominence-bounds.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Updated `docs/PARITY_MANIFEST.md`.
- Python oracle consulted:
  - `scratchndent/processing/frames/detection.py:detect_frames`;
  - `scratchndent/processing/frames/detection.py` gradient snapping section using
    `scipy.signal.find_peaks(..., prominence=window.max() * 0.3)`;
  - `test_detect.py:load_preview`, `TEST_CASES`, `compare`, and `gt_to_full`.
- Port/parity notes:
  - Real-scan detector acceptance now compares Zig directly against frozen Python
    `detect_frames` output in preview coordinates. Manual `test_detect.py`
    rectangles remain a scoring/UI-selection reference, not the function-parity
    oracle.
  - The distinction matters because frozen Python's `scan_0004` result exceeds
    the nominal 30 px manual RMS threshold on one frame while still being the
    exact behavior Zig must match.
  - Fixed `snapEdgesToGradients` to match SciPy prominence semantics: higher
    neighboring peaks bound the prominence base search, so a later smaller local
    maximum is not prominent just because the whole search window has a deeper
    minimum.
  - The `scan_0003` real-scan divergence was caused by that prominence mismatch;
    after the fix, Python and Zig choose the same repaired edge sequence.
  - The optimized film-extent binary close remains acceptable because it is an
    optimized implementation of the same all-ones square OpenCV close, backed by
    a direct OpenCV fixture.
- Scope note:
  - The real-scan parity fixture covers the four scans named by `test_detect.py`:
    `scan_0001`, `scan_0003`, `scan_0004`, and `scan_0006`. Other files in
    `scans/` need their own Python-output fixtures before they count as parity
    tests.
- Validation commands:
  - `zig build test --summary all` passed with `186/186` tests in 58 seconds
    from inside the Nix shell. This used direct `zig`; no Nix reevaluation or
    package build was run.
- Python files were not modified.

### 2026-05-15: Real Scan 0006 Detector Parity Added

- Progress under checklist item: `Wire complete _analyze_strip/detect_frames
  behavior in Zig`.
- Extended `src/processing/frames.zig`.
- Added fixture:
  - `test/fixtures/processing/frames/film-extent-close-binary-smoke.json`.
- Updated fixture documentation:
  - `test/fixtures/processing/frames/README.md`.
- Updated `docs/PARITY_MANIFEST.md`.
- Python oracle consulted:
  - `scratchndent/processing/frames/detection.py:_detect_film_extent`;
  - `test_detect.py:TEST_CASES`, `load_preview`, `compare`, `gt_to_full`.
- Port/performance notes:
  - The square all-ones binary close used by Python/OpenCV is now implemented
    with separable sliding-window passes. This preserves the same rectangular
    morphology algorithm while avoiding the prior O(width * height * k^2)
    Debug path that made real-scan tests too slow.
  - Added a direct OpenCV oracle fixture for the binary close so future speed
    work cannot silently substitute a different film-extent algorithm.
  - Added a skip-if-missing detector parity test for the real local
    `scans/scan_0006_rgbir_800dpi.tiff` case from `test_detect.py`.
  - The real-scan test remains in the ordinary Zig suite when the local
    gitignored scan exists; it does not require scanner hardware.
- Scope note:
  - The 800 DPI `scan_0006` case has `preview_scale = 1.0`, so it validates
    real TIFF loading and detector parity without also introducing preview
    downscale parity. The 3200 DPI cases remain unchecked.
- Completion decision:
  - The full detector wiring item remains unchecked.
- Validation commands:
  - `python test_detect.py scan_0006` passed against the frozen Python path;
    all five frames were within the 30 px RMS acceptance threshold.
  - `zig fmt src/processing/frames.zig` passed.
  - `zig build test --summary all` passed with `181/181` tests in about 3
    seconds from inside the Nix shell.
  - Full Nix gates were intentionally skipped for this ordinary Zig/fixture
    checkpoint under the Validation Tiers policy; no dependency, flake, package,
    or install semantics changed.
- Python files were not modified.

### 2026-05-14: Zig Scanner Foundation And Linux Hardware Smoke

- `nix develop path:. -c zig build test --summary all` passed with `21/21`
  tests.
- `nix develop path:. -c zig build --summary all` passed.
- `nix flake check path:.` passed on `x86_64-linux`; Darwin systems were
  omitted by Nix as incompatible from this host.
- `nix build path:. --no-link` passed.
- `zig build run -- scanner devices` reported an Epson Perfection V600 Photo
  device similar to `epkowa:interpreter:001:017`.
- `zig build run -- scanner probe` reported both `scanimage-v600` and
  `scanimage-v600-ir` wrappers present, TPU area about `2.700in x 9.540in`,
  and max resolution `3200`.
- RGB TPU smoke scan wrote a 16-bit RGB TIFF at
  `/tmp/v600-zig-rgb-smoke.tiff`.
- IR TPU smoke scan wrote an 8-bit grayscale TIFF at
  `/tmp/v600-zig-ir-smoke.tiff`.
- A small RGB selected-area scan wrote `/tmp/v600-zig-progress-smoke.tiff` and
  emitted structured progress events.
- Python scanner files were not modified.

## Current Zig Foundation

The rewrite currently has:

- `flake.nix` and `flake.lock` for Zig 0.16.0 development.
- `build.zig` with normal build, test, run, and gated scanner smoke steps.
- `src/main.zig` with scanner CLI wiring.
- `src/scanner/contracts.zig` for scanner request/capability/TIFF contracts.
- `src/scanner/events.zig` for stable scanner JSONL event schema and emitters.
- `src/scanner/lut.zig` for 768-byte RGB LUT serialization.
- `src/scanner/sane.zig` for SANE command planning and capability parsing.
- `src/scanner/linux.zig` for live Linux SANE runtime execution.
- `src/scanner/interpreter.zig` for replay-testable macOS protocol surfaces.
- `src/scanner/macos.zig` for replay-testable macOS interpreter callback and
  direct USB runtime sequencing.
- `src/scanner/config.zig` for scanner config TOML parity.
- `src/tiff.zig` for libtiff-backed metadata/page/image behavior.
- `src/processing/config.zig` for processing config parity.
- `src/processing/color.zig`, `measurement.zig`, `stocks.zig`,
  `inversion.zig`, `render.zig`, `ir.zig`, `opencv_ecc.cpp`, and
  `opencv_ir.cpp`, and `superlu_sparse.c` for processing foundations.
- `src/processing/frames.zig` for frame detection/extraction component
  parity.
- A persistent Linux scanner device cache for hot-path scan startup.

## Checklist

Work top to bottom unless a dependency makes that impossible. Pick the next
unchecked item whose prerequisites are complete, finish it, verify it, then
check it off. Every checked item should have either a verification-log entry,
manifest row, test fixture, or recorded hardware evidence.

### Phase 0: Rewrite Governance

- [x] Create `plan.md` with autonomous goal-loop rules.
- [x] Create `docs/PARITY_MANIFEST.md`.
- [x] Create committed fixture directories and README notes for scanner replay
  fixtures.
- [x] Target Zig 0.16.0 through Nix.
- [x] Record SDL3, Nuklear, WebGPU direction.
- [x] Restore `plan.md` after the 2026-05-15 disk-full truncation.

### Phase 1: Scanner Backend Parity

- [x] Scaffold scanner CLI and contracts.
- [x] Add Linux SANE command planner.
- [x] Add Linux scanner runtime execution.
- [x] Add persistent Linux scanner device cache.
- [x] Add structured scanner JSON event schema.
- [x] Add richer SANE stderr parsing.
- [x] Add scanner cancellation behavior.
- [x] Port full-area RGB scan metadata.
- [x] Port selected-area RGB scan behavior.
- [x] Port selected-area IR scan behavior.
- [x] Port RGB plus IR combined scan command behavior.
- [x] Port TPU horizontal mirror behavior.
- [x] Port custom LUT integration for Linux scans.
- [x] Port scanner config loading and saving.
- [x] Port explicit Linux USB reset recovery.
- [x] Expand macOS interpreter protocol replay coverage.
- [x] Implement macOS USB callback/runtime layer.
  - Completed 2026-05-15 on Linux with replay tests for interpreter search path
    generation, persistent callback registration, USB read/write callback
    success/error behavior, direct RS/register ACK handshakes, gamma upload
    ordering, and TPU calibration sequencing.
  - Live bundle loading and USB endpoint binding remain covered by the next
    macOS hardware smoke item.
- PENDING USER UPDATE: Add live macOS scanner smoke tests.
  - Parked external blocker: do not select this item in the autonomous Linux
    loop and do not re-litigate the Linux-host limitation. Resume only after
    the user explicitly says a macOS scanner host is available.
  - Blocked: cannot be completed on the current Linux host. Definition of done
    requires a macOS scanner host with the Epson Interpreter bundle available
    and a connected supported scanner; current Linux validation can only prove
    skip-gate and unsupported-platform behavior.
  - [x] Blind-port `scanner.py:58 find_interpreter` filesystem probing.
    - Completed 2026-05-15: `src/scanner/macos.zig` now exposes
      `findInterpreter` and `findInterpreterForHost`, preserving Python's
      Linux `None`/`null` behavior and the non-Linux first-existing search
      across local firmware and Epson bundle paths.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `306/306`, including Linux no-op, macOS-like first-existing, and
      no-match tests. No Nix command was run.
  - [x] Blind-port `scanner.py:920 read_scan_data` block reader.
    - Completed 2026-05-15: `src/scanner/macos.zig` now exposes
      `readScanData`, preserving full-block/final-block sizing, partial bytes
      on read failure, data retention before fatal/cancel status handling, and
      ACK placement only between successful non-terminal blocks.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `310/310`, including full/final block, read-failure, fatal-status, and
      cancel-status replay tests. No Nix command was run.
  - [x] Blind-port `scanner.py:894 start_extended_scan` runtime exchange.
    - Completed 2026-05-15: `src/scanner/macos.zig` now exposes
      `startExtendedScan`, preserving `FS G` write, 14-byte response read,
      parsed block info, and Python `None`/Zig `null` outcomes on write/read or
      parser failure.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `312/312`, including success and Python `None` response cases. No Nix
      command was run.
  - [x] Blind-port macOS interpreter command ACK exchanges.
    - Completed 2026-05-15: `src/scanner/macos.zig` now exposes `commandAck`,
      `reset`, `setScanningParameters`, and `enableInfrared`, preserving
      Python ACK/NAK/unexpected-response behavior, FS W two-stage ACK upload,
      and IR FS S read plus challenge ACK sequence.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `316/316`. No Nix command was run.
  - [x] Blind-port macOS identity/status and setup command wrappers.
    - Completed 2026-05-15: `src/scanner/macos.zig` now exposes `getIdentity`,
      `getStatus`, `getExtendedStatus`, `getExtendedIdentity`,
      `setResolution`, `setScanArea`, `setColorMode`, `setDataFormat`,
      `setSource`, and `startScan`, reusing the Python-compatible command
      builders and fake-interpreter runtime reads/writes.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `319/319`. No Nix command was run.
  - [x] Blind-port macOS FS I capability conversion.
    - Completed 2026-05-15: `src/scanner/macos.zig` now exposes
      `capabilitiesFromExtendedIdentity`, preserving Python's optical-DPI,
      max-resolution, area-inch, IR capability, and model-name mapping.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `320/320`. No Nix command was run.
  - [x] Blind-port the pure macOS scan planning portion of `scanner.py:961`.
    - Completed 2026-05-15: `src/scanner/macos.zig` now exposes `planScan`,
      preserving Python's capability-derived default area, nearest valid DPI
      snapping, pixel truncation, RGB/gray/IR mode and source codes, channel
      counts, expected byte size, and FS W parameter values before hardware
      exchange begins.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `322/322`. No Nix command was run.
  - [x] Add skip-gated future macOS scanner smoke entrypoint.
    - Completed 2026-05-15: `src/main.zig` now exposes `scanner macos-smoke`,
      gated by `V600_MACOS_HARDWARE_SMOKE=1`. Without the gate it prints a skip
      message and touches no hardware. With the gate on non-macOS it errors as
      unsupported; on interpreter hosts it remains unsupported until bundle
      loading and USB runtime wiring exist.
    - Validation 2026-05-15: direct
      `zig build macos-scanner-smoke-skip --summary all` passed and printed
      the expected skip message; direct `zig build test --summary all` passed
      `326/326`; direct `zig build --summary all` passed; direct
      `zig build -Dui=true --summary all` passed. No Nix command was run.
    - Follow-up validation 2026-05-15: direct
      `env V600_MACOS_HARDWARE_SMOKE=0 zig build run -- scanner macos-smoke`
      skipped; direct
      `env V600_MACOS_HARDWARE_SMOKE=1 zig build run -- scanner macos-smoke`
      on Linux failed before hardware access with `UnsupportedPlatform` while
      printing the intended diagnostic.
  - [x] Add manual-only interpreter readiness helper.
    - Completed 2026-05-15: `src/scanner/macos.zig` now exposes
      `ensureInterpreterManual` and `ensureInterpreterManualForHost`, reporting
      ready path, missing manual install, or unsupported Linux host without
      downloading, mounting, extracting, caching, vendoring, or Nix-storing the
      Epson ICA driver.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `329/329`; direct `zig build --summary all` passed; direct
      `zig build -Dui=true --summary all` passed. No Nix command was run.
  - [x] Blind-port macOS scanner model and endpoint-selection discovery.
    - Completed 2026-05-15: `src/scanner/macos.zig` now carries Python's Epson
      vendor ID, `SCANNER_MODELS` product table, unknown-product fallback, and
      first OUT/first IN endpoint selection policy as pure replay-tested
      helpers.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `332/332`; direct `zig build --summary all` passed; direct
      `zig build -Dui=true --summary all` passed. No Nix command was run.
  - [x] Blind-port macOS interpreter bundle symbol binding.
    - Completed 2026-05-15: `src/scanner/macos.zig` now exposes
      `LoadedInterpreter`, `InterpreterSymbols`, and `loadInterpreterSymbols`
      for the exact Python `ctypes.CDLL` exports used by the Epson Interpreter
      bundle.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `334/334`; direct `zig build --summary all` passed; direct
      `zig build -Dui=true --summary all` passed; direct skip gates for CLI
      and native UI scanner smokes passed. No Nix command was run.
  - Blocked 2026-05-15: live completion requires a macOS scanner host with the
    Epson Interpreter bundle available and a connected supported scanner.
    Remaining live-only work is runtime bundle loading, USB device open/claim,
    interface/endpoint binding, platform-dispatch CLI integration, and a real
    macOS scanner smoke. `ensure_interpreter` download/extract behavior is
    policy-blocked until a human explicitly decides whether Zig should ever
    fetch, mount, extract, cache, vendor, or Nix-store Epson's ICA driver.
  - Still blocked 2026-05-17 on the current Linux host: refreshed the direct
    Zig skip-gate evidence. `zig build macos-scanner-smoke-skip --summary all`
    passed and printed the skip message; `env V600_MACOS_HARDWARE_SMOKE=0
    zig build run -- scanner macos-smoke` skipped without hardware access; and
    `env V600_MACOS_HARDWARE_SMOKE=1 zig build run -- scanner macos-smoke`
    failed before hardware access with `UnsupportedPlatform`, confirming this
    item cannot meet its live macOS definition of done on Linux. No Nix command
    was run.
  - Still blocked 2026-05-17 after the inverted-preview async fix: refreshed
    the same direct Zig evidence. `zig build macos-scanner-smoke-skip --summary
    all` passed and printed the skip message; `env V600_MACOS_HARDWARE_SMOKE=0
    zig build run -- scanner macos-smoke` skipped without hardware access; and
    `env V600_MACOS_HARDWARE_SMOKE=1 zig build run -- scanner macos-smoke`
    failed before hardware access with `UnsupportedPlatform`. The remaining
    definition of done still requires a macOS scanner host with the Epson
    Interpreter bundle and connected scanner. No Nix command was run.
  - Still blocked 2026-05-18 after the WebGPU/runtime-switch work: the
    completion audit found this is the only unchecked item in the plan. Do not
    mark it complete from Linux. Resume on a macOS host with the scanner
    connected and the Epson Interpreter bundle installed, then:
    - Confirm the interpreter bundle can be found with the existing
      `ensureInterpreterManual`/`findInterpreter` path rules. Do not add
      automatic Epson ICA download/extract behavior unless a human explicitly
      approves that policy change.
    - Implement live macOS USB open/claim/interface binding and endpoint
      discovery around the already replay-tested `UsbIo`, `InterpreterSession`,
      `LoadedInterpreter`, `selectEndpointPair`, `planScan`,
      `startExtendedScan`, and `readScanData` pieces.
    - Wire `scanner macos-smoke` through the live interpreter runtime only
      behind `V600_MACOS_HARDWARE_SMOKE=1`.
    - Required macOS validation before checking this item: skipped smoke with
      no env var, unsupported/missing-interpreter diagnostic if applicable,
      live device open/identity/capabilities probe, one tiny RGB smoke scan,
      one tiny IR or RGB+IR smoke if supported, and `zig build test --summary
      all` on macOS.
    - Update `docs/PARITY_MANIFEST.md`, `docs/CROSS_PLATFORM.md`, and this
      item with the exact macOS host, adapter/scanner model, bundle path, smoke
      output paths, and command output. No Nix command is required unless the
      macOS dependency shell/package definition changes.

### Phase 2: TIFF And Image I/O

- [x] Choose Zig TIFF strategy.
- [x] Port TIFF DPI metadata reading.
- [x] Port TIFF page loading.
- [x] Port TIFF image discovery and unique path generation.
- [x] Port TIFF metadata write behavior.
- [x] Add representative multi-page RGB plus IR TIFF parity fixture.
  - Completed 2026-05-15: `test/fixtures/tiff/rgb-thumb-ir.tiff` and
    `rgb-thumb-ir.json` record Python `tifffile` generation plus
    `load_tiff_pages`/`read_tiff_dpi` oracle observations. Direct
    `zig build test --summary all` passed `195/195`.
- [x] Add EXIF/XMP metadata inspection parity for exported frames.
  - Completed 2026-05-15: `test/fixtures/tiff/export-metadata.tiff` and
    `export-metadata.json` record Python `write_tiff` private tag `65000`
    behavior for representative exported-frame metadata. Zig reads and parses
    the JSON through `readExportMetadataJson`. Direct
    `zig build test --summary all` passed `196/196`.

### Phase 3: Config, Stocks, And Utility Parsing

- [x] Port processing config defaults.
- [x] Port processing DPI-scaled parameter access.
- [x] Port film stock profile data.
- [x] Port processing config save/merge behavior.
- [x] Port XMP sidecar parser.
- [x] Establish numeric test harness.
- [x] Decide and document custom film stock editing behavior in Zig.
  - Completed 2026-05-15: keep Python's manual TOML `[stocks.*]` profile
    workflow for v1 parity. Zig parses, resolves, and serializes custom stock
    profiles using `test/fixtures/processing/config/custom-stock-save.toml`.
    Direct `zig build test --summary all` passed `197/197`.

### Phase 4: Negative Processing And Color

- [x] Port color matrices and basic transforms.
- [x] Port transmittance and density conversion.
- [x] Port Dmin measurement.
- [x] Port film stock polynomial transform.
- [x] Port negative inversion pipeline.
- [x] Port tone mapping.
- [x] Port gamut mapping and sRGB output.
- [x] Port sigmoid and Negadoctor behavior.
- [x] Add hot color path benchmarks.
- [x] Decide SIMD and GPU acceleration targets.
- [x] Add representative full negative-to-positive fixture using a real scan.
  - Completed 2026-05-15: generated
    `test/fixtures/processing/numeric/real-scan-negative-to-positive-scan-0006-crop.json`
    from page 0 crop `x=420 y=2500 w=8 h=8` of local
    `scans/scan_0006_rgbir_800dpi.tiff`. Zig verifies Dmin plus rendered
    uint16 output against Python `invert_negative` and `render_to_display`.
    Direct `zig build test --summary all` passed `198/198`.

### Phase 5: IR Dust And Scratch Removal

- [x] Port IR/RGB alignment.
  - Completed 2026-05-15: replaced the integer normalized-correlation
    scaffold with `src/processing/opencv_ecc.cpp`, a native bridge to
    `cv::findTransformECC` using Python's `MOTION_TRANSLATION`, 200 iteration,
    `1e-6` epsilon, and `ecc_scale = 0.125` constants. Updated
    `align-ratio-1-to-2.json` and `align-ratio-1-to-4.json` to Python ECC
    oracle fixtures, kept SciPy reflect/bilinear final-shift parity, and added
    an unaligned fallback test for invalid ECC inputs. Direct
    `zig build test --summary all` passed `213/213`; direct
    `zig build --summary all` passed; `nix flake check path:.` passed on
    `x86_64-linux` after adding the OpenCV dependency.
- [x] Port IR thresholding.
- [x] Port IR dilation and closing.
- [x] Port IR connected-component area filtering.
- [x] Port max coverage guard.
- [x] Port Python biharmonic inpainting and grain synthesis.
  - Reopened 2026-05-15: the frozen Python path labels mask components with
    OpenCV, extracts padded ROIs, estimates local grain with OpenCV dilation,
    Gaussian blur, Hanning-windowed FFT power spectra, calls
    `skimage.restoration.inpaint_biharmonic(channel_axis=-1)`, synthesizes
    grain with NumPy FFT/random normal noise, clips to the original dtype, and
    writes only masked ROI pixels. This item remains unchecked until that
    algorithm is ported or the same library behavior is called with controlled
    RNG/oracle evidence.
  - Correction 2026-05-15: removed the earlier deterministic diffusion
    replacement and its manual fixture from the Zig API/tests. It was not a
    function-for-function port of Python `inpaint` and must not be used as
    parity evidence.
  - Progress 2026-05-15: ported the Python `estimate_local_grain` helper as
    `estimateLocalGrain`, backed by `src/processing/opencv_ir.cpp` for OpenCV
    ellipse dilation, OpenCV Gaussian blur, Hanning-windowed DFT power spectra,
    radial averaging, clean-fraction compensation, and spectrum normalization.
    Added `test/fixtures/processing/ir/estimate-local-grain-smoke.json` as a
    Python oracle fixture. Direct `zig build test --summary all` passed
    `215/215`; direct `zig build --summary all` passed; `nix flake check
    path:.` passed on `x86_64-linux`. Full item remains unchecked because
    `inpaint_biharmonic`, `synthesize_grain`, ROI component traversal, dtype
    clipping, and masked writeback are still pending.
  - Progress 2026-05-15: added `synthesizeGrainFromNoise` for the deterministic
    post-RNG portion of Python `synthesize_grain`, including the measured
    spectrum and fallback 1/f amplitude filters, DFT/IDFT shaping,
    standard-deviation normalization, per-channel grain scaling, and float32
    output storage.
    Fixture `test/fixtures/processing/ir/synthesize-grain-from-noise-smoke.json`
    and `test/fixtures/processing/ir/synthesize-grain-fallback-from-noise-smoke.json`
    monkeypatch Python `np.random.randn` to recorded noise arrays. Direct
    `zig build test --summary all` passed `218/218`; direct
    `zig build --summary all` passed. Full `synthesize_grain` remains pending
    until the runtime RNG behavior is represented or deliberately isolated in
    the final inpaint contract.
  - Progress 2026-05-15: added `biharmonicInpaint`, a dense-solver port of the
    scikit-image radius-2 biharmonic linear system for compact masked RGB
    regions, with fixture `test/fixtures/processing/ir/biharmonic-inpaint-smoke.json`
    generated from `skimage.restoration.inpaint_biharmonic(...,
    channel_axis=-1)`. Direct `zig build test --summary all` passed `220/220`;
    direct `zig build --summary all` passed. This proves the equation and
    boundary handling on a small case; the full Python `inpaint` loop still
    needs ROI component traversal, local-grain integration, runtime grain noise
    handling, dtype clipping, and masked writeback.
  - Progress 2026-05-15: added `inpaintBiharmonicWithGrainFromNoise`, which
    ports the Python `inpaint` orchestration around the kernels: OpenCV-style
    8-connected component traversal, padded ROI extraction, reads from the
    evolving `result` buffer, local grain estimation, biharmonic signal repair,
    spectral grain synthesis from captured NumPy noise planes, original-dtype
    clipping/casting, and masked ROI writeback. Added the two-component uint16
    Python oracle fixture
    `test/fixtures/processing/ir/inpaint-biharmonic-grain-uint16-smoke.json`
    by monkeypatching `np.random.randn` and recording the noise consumed by the
    frozen Python function. Direct `zig build test --summary all` passed
    `222/222`; direct `zig build --summary all` passed. This item remains
    unchecked until the runtime random-normal generation/injection contract is
    represented in the public processing flow and the dense solve has an
    explicit large-region performance/parity plan.
  - Progress 2026-05-15: represented the controlled RNG/injection contract in
    the public dust-removal flow by adding `makeDefectMask`,
    `irCleanRegionWithNoise`, and export `prepareIrCleanedRegionWithNoise`.
    The current public parity path accepts captured standard-normal noise
    planes, which keeps oracle tests deterministic while preserving Python's
    stochastic `np.random.randn` algorithm boundary. This item remains
    unchecked until a production random-normal source is selected for runtime
    cleaning and the dense biharmonic solver is replaced or bounded by a
    parity-preserving sparse/tiling strategy for large real masks.
  - Progress 2026-05-15: added runtime standard-normal wrappers
    `inpaintBiharmonicWithGrain`, `irCleanRegion`, and export
    `prepareIrCleanedRegion`, using `std.Random.floatNorm(f64)` as the Zig
    runtime equivalent of Python's stochastic `np.random.randn` boundary while
    preserving captured-noise APIs for exact oracle tests. Direct
    `zig build test --summary all` passed `225/225`; direct
    `zig build --summary all` passed. This item remains unchecked only because
    the dense biharmonic solve is not yet a credible large-mask implementation;
    the next work here should define and implement a parity-preserving sparse
    or tiled solve before performance acceptance.
  - Completed 2026-05-15: replaced the large-mask dense biharmonic solve with
    a sparse SuperLU bridge in `src/processing/superlu_sparse.c`, called from
    `biharmonicInpaint` after building the same scikit-image radius-2
    Laplace-of-Laplace matrix and RHS. The SuperLU path uses `MMD_ATA`, matching
    Python/scikit-image's `spsolve(..., permc_spec='MMD_ATA')` dependency, and
    keeps the pure Zig CG/BiCGSTAB path only as a fallback. Added
    `bench-ir-inpaint`, which forces a 1600-unknown sparse affine-plane case,
    verifies `max_error <= 1e-6`, and fails if the best Zig solve is slower
    than the recorded Python baseline of `4.860 ms`. Validation:
    `nix develop path:. -c zig build test --summary all` passed `254/254`;
    `nix develop path:. -c zig build --summary all` passed; `nix flake check
    path:.` passed on `x86_64-linux`; `nix build path:. --no-link` passed;
    `nix develop path:. -c zig build -Doptimize=ReleaseFast
    bench-ir-inpaint --summary all` reported best `4.628 ms`, average
    `4.761 ms`, Python baseline `4.860 ms`, and zero affine error.
- [x] Resolve Meijering hair/scratch ridge detector parity.
  - Completed 2026-05-15: added `detectLineDefects` and
    `meijeringLineResponse` with a Python oracle fixture at
    `test/fixtures/processing/ir/meijering-line-detection-smoke.json`.
    This is behavior parity first; performance tuning for large IR images
    remains a later optimization pass. Direct `zig build test --summary all`
    passed `200/200`.
  - Revised 2026-05-15: this item remains checked only for the scikit-image
    Meijering branch. It does not certify the non-parity inpainting scaffold or
    any future inpainting acceptance.
- [x] Add end-to-end dust removal parity fixtures.
  - Completed 2026-05-15: added
    `test/fixtures/processing/ir/ir-clean-region-uint16-smoke.json`, generated
    from the frozen Python path by running `make_defect_mask` with explicit
    options and then `inpaint` with `np.random.randn` monkeypatched to record
    consumed noise planes. The Zig test now verifies the full same-resolution
    IR mask-to-cleaned-RGB path: adaptive dust mask, Meijering line branch,
    morphology/area/coverage composition, public `irCleanRegionWithNoise`,
    captured-noise grain synthesis, biharmonic repair, uint16 writeback, and
    export helper smoke coverage. Direct `zig build test --summary all` passed
    `225/225`; direct `zig build --summary all` passed.
  - Completed branch coverage 2026-05-15: added
    `test/fixtures/processing/ir/ir-clean-region-resize-uint16-smoke.json` for
    the RGB:IR-dimension-mismatch branch, including exact assertions for the
    IR-resolution mask and the RGB-resolution nearest-resized plus 3x3
    ellipse-dilated mask before checking cleaned RGB output. Direct
    `zig build test --summary all` passed `226/226`; direct
    `zig build --summary all` passed.

### Phase 6: Frame Detection And Extraction

- [x] Port format specs for 35mm, 645, and 6x6.
- [x] Port 1D strip profile generation.
- [x] Port DTW pitch alignment.
- [x] Port gradient edge snapping.
- [x] Port Gaussian weighting behavior.
- [x] Port size-consistency correction.
- [x] Port first/last frame repair.
- [x] Port cross-strip paired-gradient positioning.
- [x] Port Theil-Sen angle estimation.
- [x] Port single-frame fallback guard.
- [x] Port rotated rectangle crop.
- [x] Port rebate extraction.
- [x] Port preview-to-full-resolution coordinate scaling.
- [x] Add parity tests against `test_detect.py` ground truth.
- [x] Add synthetic frame detection fixtures that do not require real scans.
- [x] Wire complete `_analyze_strip`/`detect_frames` behavior in Zig.
  - Progress 2026-05-15: ported `_analyze_strip` and `_initial_placement`
    as `analyzeStrip` and `initialPlacement` with fixture
    `test/fixtures/processing/frames/strip-analysis-initial-placement-smoke.json`.
    Full detector orchestration remains unchecked.
  - Progress 2026-05-15: added `detectFramesAxisAlignedPrepared` with fixture
    `test/fixtures/processing/frames/axis-aligned-detect-smoke.json`. Full
    preprocessing, film extent/rotation, angle aggregation, rotated
    cross-strip sampling, and real-scan parity remain unchecked.
  - Progress 2026-05-15: integrated axis-aligned cross-strip paired-gradient
    refinement into `detectFramesAxisAlignedPrepared`; rotated bilinear
    cross-strip sampling remains unchecked.
  - Progress 2026-05-15: integrated axis-aligned Theil-Sen angle aggregation
    into `detectFramesAxisAlignedPrepared` and added a sloped-edge synthetic
    fixture with explicit angle tolerance. Full preprocessing, film
    extent/rotation, rotated bilinear cross-strip sampling, work-scale
    restoration, and real-scan parity remain unchecked.
  - Progress 2026-05-15: integrated rotated bilinear cross-strip sampling into
    the prepared detector path and added explicit cross-size validation to the
    nonzero-angle synthetic fixture. Full preprocessing, film extent/rotation,
    work-scale restoration, and real-scan parity remain unchecked.
  - Progress 2026-05-15: added `prepareDetectionGray` with fixture-backed
    grayscale conversion and inversion semantics for 8-bit/16-bit gray/RGB
    inputs. CLAHE, film extent/rotation, full wrapper wiring, and real-scan
    parity remain unchecked.
  - Progress 2026-05-15: added `detectFilmExtentAxisAligned` for the Otsu,
    close, largest-component, and unrotated extent subset of
    `_detect_film_extent`. Rotated minAreaRect angle extraction, image
    rotation/back-transform, CLAHE, full wrapper wiring, and real-scan parity
    remain unchecked.
  - Progress 2026-05-15: added `detectFramesFromImage` and replayed the
    synthetic detector fixtures through the byte-buffer wrapper with film
    extent disabled. CLAHE, full film extent integration, rotation
    correction/back-transform, work-scale restoration, and real-scan parity
    remain unchecked.
  - Progress 2026-05-15: pinned frozen `detect_frames` work-scale behavior as
    a deliberate no-op (`1.0`) for all valid image dimensions. CLAHE, full film
    extent integration, rotation correction/back-transform, and real-scan
    parity remain unchecked.
  - Progress 2026-05-15: added `DetectFramesResult.aspect` and
    `detectFramesAspect`, with fixture assertions through the prepared and
    image-buffer detector paths. CLAHE, full film extent integration, rotation
    correction/back-transform, and real-scan parity remain unchecked.
  - Progress 2026-05-15: added `applyClahe8` with OpenCV fixture parity for
    clip redistribution, LUT generation, reflect padding, and tile
    interpolation. Detector wrapper integration, full film extent integration,
    rotation correction/back-transform, and real-scan parity remain unchecked.
  - Progress 2026-05-15: wired CLAHE into `detectFramesFromImage` while
    preserving a separate raw cross-strip image. Real-scan CLAHE detector
    parity, rotated film extent, rotation correction/back-transform, and
    real-scan parity remain unchecked.
  - Progress 2026-05-15: added Python/OpenCV rotation-back coordinate
    transform parity for expanded rotation matrices, inverse affine matrices,
    frame center back-transform, and global angle addition. Rotated image
    resampling, rotated film extent angle extraction, end-to-end rotated
    detector wiring, and real-scan parity remain unchecked.
  - Progress 2026-05-15: added expanded grayscale image rotation with
    replicate-border bilinear sampling against a `cv2.warpAffine` fixture.
    Rotated film extent angle extraction, end-to-end rotated detector wiring,
    and real-scan parity remain unchecked.
  - Progress 2026-05-15: added synthetic rotated film extent angle/dimension
    estimation via largest-component PCA/projection against OpenCV
    `minAreaRect` fixtures. Real-scan contour/minAreaRect parity, end-to-end
    rotated detector wiring, and real-scan parity remain unchecked.
  - Progress 2026-05-15: wired the rotation-corrected `detectFramesFromImage`
    route for measured film extents over Python's 0.1 degree threshold and
    added an explicit-extent synthetic wrapper fixture that rotates the raw
    grayscale buffer, detects frames in rotated coordinates, and transforms
    centers/angles back. Detected real-scan extent/minAreaRect parity and full
    scan-fixture detector parity remain unchecked.
  - Completion 2026-05-15: added frozen Python detector-output parity for all
    four `test_detect.py` real scans through skip-if-missing tests, and fixed
    SciPy-bounded prominence snapping so `scan_0003` matches Python's edge repair
    sequence.
- [x] Add full detector parity tests for all available `test_detect.py` scan
  fixtures.
  - Completion 2026-05-15: `test-detect-python-output.json` covers `scan_0001`,
    `scan_0003`, `scan_0004`, and `scan_0006`. Other gitignored scan files must
    get explicit Python-output fixtures before they are treated as parity cases.

### 2026-05-15: Export Pipeline Model Started

- Ported the export request/config model for output toggles, Python default
  output selection, derived `need_ir`/`need_invert` behavior, active-stock
  selection, variant order, suffixes, and metadata variant names.
- Ported export crop/rotation application scaffolding: interleaved multi-channel
  frame crops route through the Python-oracled rotated crop helper per channel,
  and 90/180/270 degree output rotations match Python `cv2.rotate`; all other
  rotation values now preserve Python's unchanged-image fallback.
- Ported the raw RGB negative output fallback semantics used when Python's
  `ir_neg` path is requested without an aligned IR crop: the raw crop is
  rotated and emitted as the negative output without inventing a new export
  variant.
- Ported the IR-cleaned negative output selection semantics: use the cleaned
  crop when available, otherwise preserve Python's raw-crop fallback.
- Ported inverted positive output preparation: crop pixels pass through
  `invertNegative`, `renderToDisplay`, and output rotation, with real-scan
  Python oracle coverage.
- Ported frame naming and suffix rules, including Python's two-digit frame
  numbers, `_ir`/empty/`_inv` variant suffixes, `.tif` extension, and
  `generate_unique_path` collision suffix behavior.
- Ported export gallery file-management semantics: top-level TIFF listing,
  `.trash` moves with Python's unpadded `_1`, `_2` collision suffixes, delete,
  and path rejection for names outside the gallery file namespace.

### Phase 7: Export Pipeline

- [x] Port export request/config model.
  - Completed 2026-05-15: added `src/processing/export.zig` and exported it as
    `processing.export_pipeline`. Direct `zig build test --summary all` passed
    `204/204`.
- [x] Port crop and rotation application.
  - Completed 2026-05-15: added export `cropFrame` and `applyRotation` helpers
    for interleaved image buffers. Direct `zig build test --summary all` passed
    `207/207`.
- [x] Port RGB negative output.
  - Completed 2026-05-15: preserved the frozen Python semantics that there is
    no separate raw RGB-negative variant; raw crop output is the `ir_neg`
    fallback when IR cleaning is requested but no IR crop is available. Also
    fixed output rotation to leave non-90/180/270 values unchanged like Python.
    Direct `zig build test --summary all` passed `208/208`.
- [x] Port IR-cleaned negative output.
  - Completed 2026-05-15: added `prepareIrCleanedNegativeOutput`, covering
    cleaned-crop preference and raw-crop fallback. Direct
    `zig build test --summary all` passed `209/209`.
- [x] Port inverted positive output.
  - Completed 2026-05-15: added `prepareInvertedPositiveOutput` and verified it
    against `real-scan-negative-to-positive-scan-0006-crop.json`. Direct
    `zig build test --summary all` passed `210/210`.
- [x] Port frame naming and suffix rules.
  - Completed 2026-05-15: added `frameFileName`, `frameOutputPath`, and
    `uniqueFrameOutputPath`. Direct `zig build test --summary all` passed
    `212/212`.
- [x] Port export gallery file management semantics.
  - Completed 2026-05-15: added `listGalleryFiles`, `trashGalleryFile`, and
    `deleteGalleryFile` to `src/processing/export.zig`. Tests cover missing
    output directories, sorted top-level TIFF basename listing, non-TIFF and
    nested-file exclusion, trash directory creation, Python `_1`/`_2` collision
    suffix behavior, delete messages, and basic path rejection. Direct
    `zig build test --summary all` passed `229/229`; direct
    `zig build --summary all` passed.
- [x] Add export parity fixtures for representative scans.
  - Completed 2026-05-15: added a self-contained real-scan patch fixture at
    `test/fixtures/processing/export/process-frame-scan-0006-patch.json`,
    generated by the frozen Python `scratchndent.export.process_frame` from a
    compact RGB patch of `scans/scan_0006_rgbir_800dpi.tiff`. Added Zig
    `processFrame`, `ProcessFrameOptions`, TIFF writing, metadata JSON
    emission, and a test that runs the top-level fallback path with
    `aligned_ir=None` and all three Python output variants enabled:
    `ir_neg`, `ir_inv`, and `inv_only`. The test checks Python written-file
    order, raw-crop shape, exact raw negative TIFF pixels, inverted TIFF pixels
    within the already-established render tolerance of +/-2 code values, and
    parsed metadata fields. Direct `zig build test --summary all` passed
    `228/228`; direct `zig build --summary all` passed. No Nix evaluation was
    run.
- [x] Add batch export progress events.
  - Completed 2026-05-15: added `ExportProgressKind`,
    `ExportProgressEvent`, `ExportProgressList`, and
    `buildBatchExportProgress` to model Python `handle_export` progress
    messages headlessly. Tests cover singular/plural frame preparation,
    optional `"Aligning IR channel..."`, `"Processing ..."` messages,
    per-file `"Wrote ..."` messages, final exported-file pluralization, output
    directory formatting, and one-decimal elapsed time formatting. Direct
    `zig build test --summary all` passed `230/230`; direct
    `zig build --summary all` passed. No Nix evaluation was run.

### Phase 8: Application State And CLI

- [x] Define frozen Python workflow state model.
  - Completed 2026-05-15: added `src/app_state.zig` and exported it from
    `src/root.zig`. The module freezes the Python browser workflow state shape
    as testable Zig contracts: scanner connection/status/info fields from
    `v600.gui.scan_handlers.ScannerState`, processing module globals from
    `v600.gui.process_handlers`, processing `/info` fields, image-load
    begin/finish transitions, progress text, Dmin presence, IR/grayscale flags,
    and DPI scale derived from the processing reference DPI. Direct
    `zig build test --summary all` passed `233/233`; direct
    `zig build --summary all` passed. No Nix evaluation was run.
- [x] Add Zig processing CLI for loading images, detecting frames, setting
  rebate, and exporting frames.
  - Completed 2026-05-15: added `src/processing/cli.zig` and wired
    `v600-zig processing` in `src/main.zig`. Subcommands now cover
    `processing info --input PATH`, `processing detect --input PATH --format
    ...`, `processing rebate --input PATH --x ... --y ... --width ...
    --height ...`, and `processing export --input PATH --frame
    CX,CY,W,H[,ANGLE_DEG[,ROT]] ...`. The CLI loads TIFF RGB/IR pages through
    the libtiff wrapper, detects frames with the ported detector, computes
    rebate Dmin through a new direct `computeDmin` wrapper, can persist Dmin
    through the processing config writer, and exports through the top-level
    Python-shaped `processFrame` path with Python default `ir_inv` output
    semantics. Tests cover command parsing, frame/Dmin spec parsing, and
    `computeDmin` composition.
  - Validation 2026-05-15: direct `zig build test --summary all` passed
    `236/236`; direct `zig build --summary all` passed. CLI smokes passed:
    `zig build run -- processing info --input
    test/fixtures/tiff/rgb-thumb-ir.tiff`; `zig build run -- processing rebate
    --input test/fixtures/tiff/rgb-thumb-ir.tiff --x 0 --y 0 --width 1
    --height 1 --no-save`; `zig build run -- processing export --input
    test/fixtures/tiff/rgb-thumb-ir.tiff --out-dir
    .zig-cache/tmp/v600-cli-export --basename cli --frame 1,1,1,1,0,0
    --ir-neg --no-ir-inv --no-align-ir`; and `zig build run -- processing
    detect --input scans/scan_0006_rgbir_800dpi.tiff --format 35mm
    --n-frames 6`. No Nix evaluation was run.
- [x] Add scanner plus processing integration smoke command.
  - Completed 2026-05-15: added gated `v600-zig scanner processing-smoke`
    under the scanner CLI. Without `V600_HARDWARE_SMOKE=1` it reports a skip
    and performs no hardware operation. With the gate enabled, it runs a small
    scanner pass, defaults the output to `/tmp/v600-zig-processing-smoke.tiff`
    when `--out` is omitted, defaults to a small selected area if no area is
    provided, then immediately loads the produced TIFF through the processing
    `info` command path.
  - Validation 2026-05-15: direct `zig build test --summary all` passed
    `236/236`; direct `zig build --summary all` passed; skip command
    `zig build run -- scanner processing-smoke` printed the gated skip message.
    Live command `V600_HARDWARE_SMOKE=1 zig build run -- scanner
    processing-smoke --out /tmp/v600-zig-processing-smoke.tiff --x 0.1 --y
    0.1 --width 0.25 --height 0.25` selected cached device
    `epkowa:interpreter:001:017`, emitted scanner progress, wrote
    `/tmp/v600-zig-processing-smoke.tiff` plus JSON sidecar, and the processing
    info path reported `full_width=96`, `full_height=100`, `has_ir=false`,
    `dpi=400`. Python `tifffile` inspection confirmed page 0 shape
    `(100, 96, 3)` and dtype `uint16`. No Nix evaluation was run.
- [x] Add JSON event stream for long-running processing/export operations.
  - Completed 2026-05-15: added `src/processing/events.zig` with schema
    `v600.processing.event.v1` and stable JSONL writers/emitters for
    `export-start`, `export-progress`, `file-written`, `export-complete`, and
    `processing-error`. Wired `processing export --events` to emit JSONL
    progress on stderr while preserving the normal JSON result on stdout.
  - Validation 2026-05-15: direct `zig build test --summary all` passed
    `238/238`; direct `zig build --summary all` passed. CLI event smoke
    `zig build run -- processing export --events --input
    test/fixtures/tiff/rgb-thumb-ir.tiff --out-dir
    .zig-cache/tmp/v600-cli-events --basename evt --frame 1,1,1,1,0,0
    --ir-neg --no-ir-inv --no-align-ir` emitted export start/progress/file
    written/complete JSONL events plus the final JSON result. No Nix
    evaluation was run.
- [x] Add recovery behavior for missing input files, missing IR pages, and
  cancelled operations.
  - Completed 2026-05-15: processing command execution now catches runtime
    errors, emits a `processing-error` JSONL event, and returns JSON
    `{"error": ...}` instead of surfacing an unstructured failure. Export keeps
    Python's missing-IR fallback by exporting the raw crop when IR output is
    requested but no IR page/alignment is available. Export also accepts
    `--cancel-file PATH`, checks it before and between frames, emits
    `export-cancelled` when `--events` is enabled, and returns
    `{"cancelled": true, "files": [...]}` with any files already completed.
  - Validation 2026-05-15: direct `zig build test --summary all` passed
    `238/238`; direct `zig build --summary all` passed. Missing input smoke
    `zig build run -- processing info --input
    .zig-cache/tmp/v600-missing-input.tiff` returned
    `{"error":"TiffOpenFailed"}` plus a `processing-error` event. Missing IR
    smoke `zig build run -- processing export --input
    test/fixtures/tiff/export-metadata.tiff --out-dir
    .zig-cache/tmp/v600-missing-ir-export --basename no_ir --frame
    1,1,1,1,0,0 --ir-neg --no-ir-inv` wrote `no_ir_01_ir.tif`.
    Cancellation smoke with a pre-existing cancel file emitted
    `export-cancelled` and returned `{"cancelled":true,"files":[]}`. No Nix
    evaluation was run.

### Phase 9: Native UI Foundation

- [x] Add SDL3 dependency through Nix.
  - Completed 2026-05-15: added `pkgs.sdl3` to the flake package
    `buildInputs`, flake test `buildInputs`, and flake dev shell packages.
    Added a guarded `sdl3` entry to legacy `shell.nix` only when the user's
    `<nixpkgs>` channel provides `pkgs.sdl3`, so older channels do not break.
  - Validation 2026-05-15: `nix develop path:. -c pkg-config --modversion
    sdl3` returned `3.4.2`; `nix flake check path:.` passed for
    `x86_64-linux` and omitted the incompatible Darwin systems as before.
    The local legacy `<nixpkgs>` channel does not expose `pkgs.sdl3`; use the
    flake dev shell or update the channel to a recent unstable before relying
    on `shell.nix` for SDL3 work.
- [x] Add Nuklear dependency through Nix.
  - Completed 2026-05-15: nixpkgs does not provide the C Nuklear header as a
    first-class package, so the flake now defines a pinned header-only
    `nuklear` derivation from `Immediate-Mode-UI/Nuklear` tag `4.12.7`
    (`sha256-EE76hj40BwRPRa/+m2Uhgr5pqChrkifwMfGw0DZdxug=`), installs
    `nuklear.h`, and provides a `nuklear.pc` pkg-config file. Added this
    derivation to flake package builds, flake checks, and the flake dev shell.
    Legacy `shell.nix` defines the same pinned derivation locally.
  - Validation 2026-05-15: `nix develop path:. -c sh -c 'pkg-config
    --modversion nuklear && test -f "$(pkg-config --variable=includedir
    nuklear)/nuklear.h"'` returned `4.12.7`; `nix flake check path:.` passed
    for `x86_64-linux` and omitted the incompatible Darwin systems as before.
- [x] Build minimal SDL3 window with Nuklear frame loop.
  - Completed 2026-05-15: added optional `-Dui=true` build wiring for a
    `v600-ui` executable, a minimal SDL3 window/renderer setup, Nuklear
    implementation compilation unit, default-font atlas initialization, one
    Nuklear frame, and a `ui-smoke` build step that exits after one frame.
    Fixed the generated `nuklear.pc` file so `pkg-config --cflags nuklear`
    emits an absolute include path instead of bare `-I`; linked the UI module
    with `libm` for Nuklear's default-font math helpers. This item adds no
    scanner or processing algorithm behavior.
  - Validation 2026-05-15: `nix develop path:. -c zig build -Dui=true
    --summary all` passed; `nix develop path:. -c env SDL_VIDEODRIVER=dummy
    SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
    passed with `v600-ui --smoke`; `nix develop path:. -c zig build test
    --summary all` passed `238/238`; `nix flake check path:.` passed for
    `x86_64-linux` and omitted incompatible Darwin systems.
- [x] Keep UI application state independent from SDL/Nuklear bindings.
  - Completed 2026-05-15: added `src/ui/state.zig` as a pure native UI model
    that owns the active view, scanner workflow state, processing workflow
    state, status text, and quit request without importing SDL3, Nuklear, or C
    bindings. Exported it from `src/root.zig` as `native_ui`. Updated
    `src/ui/main.zig` so the SDL/Nuklear entry point instantiates and renders
    from that model instead of owning workflow state directly.
  - Validation 2026-05-15: `nix develop path:. -c zig build test --summary
    all` passed `239/239`, including the pure native UI state boundary test;
    `nix develop path:. -c zig build -Dui=true --summary all` passed; `nix
    develop path:. -c env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig
    build -Dui=true ui-smoke --summary all` passed. No `nix flake check` was
    run because no flake/dependency/package wiring changed in this checkpoint.
    No parity-manifest row was required because this item adds a binding
    boundary over existing app-state contracts rather than porting a new Python
    behavior.
- [x] Add headless tests for UI state transitions.
  - Completed 2026-05-15: extended `src/ui/state.zig` with pure transition
    helpers for scanner connect/connected/failure, scan start/progress/cancel/
    finish, processing image load begin/finish, processing progress, view
    switching, and quit requests. Added headless tests for the scanner
    transition path and processing/gallery transition path. Updated
    `docs/PARITY_MANIFEST.md` so the app-state row also covers native UI state
    transition evidence.
  - Validation 2026-05-15: `nix develop path:. -c zig build test --summary
    all` passed `241/241`; `nix develop path:. -c zig build -Dui=true
    --summary all` passed; `nix develop path:. -c env SDL_VIDEODRIVER=dummy
    SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
    passed. No `nix flake check` was run because no flake/dependency/package
    wiring changed in this checkpoint.
- [x] Mirror browser scan workflow in native UI.
  - Parent item covers browser scan status, preview, selection, config, scan
    start, progress, cancellation, output naming, and hardware-gated
    validation.
  - Parent completion 2026-05-15: all scan workflow subitems below are now
    complete: native controls, Nuklear submission, Nuklear rendering, preview
    request/status/event flow, preview worker, preview downsampling, SDL
    preview rendering, selection overlay, scan-start planning, nonblocking scan
    worker, LUT computation and temp-file ownership, RGB/RGB+IR/IR LUT policy,
    Python `_handle_scan` status strings, live scan event mapping, scanner
    config persistence, and hardware-gated Linux native scan-worker evidence.
    Current validation after later Phase 11 changes: direct
    `zig build test --summary all` passed `303/303`; direct
    `zig build --summary all` passed; direct `zig build -Dui=true --summary all`
    passed; direct no-hardware scanner/native smoke skip steps passed.
  - Function-for-function constraint: UI interaction details may reference the
    embedded JavaScript in `v600/gui/scan_ui.py`, but scanner behavior must
    follow `v600/gui/scan_handlers.py` and the scanner backend functions it
    calls. Do not count a native UI scan feature complete when it only creates
    a new request/worker shape; complete it when the corresponding Python
    handler behavior is ported or delegated to a function-shaped Zig port.
  - [x] Port native scan controls and preview-selection math.
    - Completed 2026-05-15: added `src/ui/scan_workflow.zig` and attached
      `ScanControls` to `native_ui.State`. The pure model preserves browser
      defaults for mode, DPI, exposure, autoselect, selection persistence, and
      auto-selection restore. Tests cover RGB/RGB+IR/IR DPI option lists,
      closest-DPI fallback, draw/persist selection thresholds, saved-selection
      inches conversion, and the mirrored x-coordinate used by browser
      `/scan/start` requests.
    - Validation 2026-05-15: `nix develop path:. -c zig build test --summary
      all` passed `244/244`; `nix develop path:. -c zig build -Dui=true
      --summary all` passed; `nix develop path:. -c env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
      passed. Updated `docs/PARITY_MANIFEST.md` with the scan-control
      UI-adapter row; this is not scanner backend algorithm parity. No `nix
      flake check` was run because no flake/dependency/package wiring changed.
  - [x] Submit native scan controls to Nuklear from the pure scan model.
    - Completed 2026-05-15: expanded `src/ui/main.zig` so the Nuklear frame
      submits navigation plus scan workflow controls from `native_ui.State`:
      preview, autoselect, restore auto, mode segmented choices, DPI choices
      derived from the active mode, exposure choices, scan/cancel action, and
      selection readiness. Corrected the pure exposure model to match the
      browser values `linear` and `affine`.
    - Validation 2026-05-15: `nix develop path:. -c zig build test --summary
      all` passed `244/244`; `nix develop path:. -c zig build -Dui=true
      --summary all` passed; `nix develop path:. -c env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
      passed. No `nix flake check` was run because no flake/dependency/package
      wiring changed.
    - Correction 2026-05-15: this item covers Nuklear command submission, not
      final visible control rendering. A Nuklear-to-SDL draw-command renderer
      and screenshot/manual verification remain explicit unchecked native UI
      work.
  - [x] Render Nuklear draw commands through SDL3.
    - Required before calling the native UI visually complete. Current
      headless UI smoke proves SDL window creation and frame-loop execution,
      and direct SDL preview texture rendering is implemented below, but
      Nuklear widgets need a real draw-command conversion path before buttons,
      labels, and control chrome are visibly rendered.
    - Completed 2026-05-15: added a Nuklear-to-SDL3 renderer in
      `src/ui/main.zig` that bakes the Nuklear font atlas into an SDL texture,
      converts Nuklear command buffers to interleaved position/UV/float-color
      vertices, applies per-command SDL clip rectangles, and submits indexed
      triangles through `SDL_RenderGeometryRaw`. The preview-render smoke now
      reads pixels back with `SDL_RenderReadPixels` and verifies that Nuklear
      chrome changed pixels in the control-window region outside the direct
      preview texture.
    - Validation 2026-05-15: `nix develop path:. -c zig build -Dui=true
      --summary all` passed; `nix develop path:. -c env
      SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
      ui-smoke --summary all` passed; `nix develop path:. -c env
      SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
      run-ui -- --preview-render-smoke` passed with the pixel-readback proof;
      `nix develop path:. -c zig build test --summary all` passed `254/254`.
      No `nix flake check` was run for this checkpoint because no dependency,
      flake, or package semantics changed.
  - [x] Wire native preview request/status flow to scanner backend events.
    - [x] Add native preview intent and scanner-event state adapter.
      - Completed 2026-05-15: added `ScannerBackendEvent`,
        `beginPreviewRequest`, and `applyScannerBackendEvent` to
        `src/ui/state.zig`. The native UI state now consumes scanner
        `scan-start`, `progress`, `scan-complete`, `scan-cancelled`, and
        `scan-error` events headlessly. Preview start marks the scan view busy,
        progress stores a percent, completion marks preview ready, and
        cancellation/errors surface scanner detail while clearing busy state.
        The Nuklear Preview button now raises this preview intent. Live preview
        worker execution and preview image display remain unchecked.
      - Validation 2026-05-15: `nix develop path:. -c zig build test
        --summary all` passed `246/246`; `nix develop path:. -c zig build
        -Dui=true --summary all` passed; `nix develop path:. -c env
        SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
        ui-smoke --summary all` passed. Updated `docs/PARITY_MANIFEST.md` with
        native scanner-event UI state evidence. No `nix flake check` was run
        because no flake/dependency/package wiring changed.
    - [x] Build pure preview scan request plan.
      - Completed 2026-05-15: added `PreviewScanPlan` and
        `previewScanPlan` in `src/ui/scan_workflow.zig`, exposed through
        `native_ui.State.previewScanPlan`. The plan matches the browser
        preview request shape: TPU source, RGB kind, 8-bit depth, 200 DPI from
        scanner preview state, full TPU area, and explicit output path. This
        remains a pure request contract; it does not run scanner hardware and
        does not complete the Python `_handle_preview` algorithm.
      - Validation 2026-05-15: `nix develop path:. -c zig build test
        --summary all` passed `247/247`; `nix develop path:. -c zig build
        -Dui=true --summary all` passed; `nix develop path:. -c env
        SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
        ui-smoke --summary all` passed. Updated `docs/PARITY_MANIFEST.md` with
        preview scan plan evidence. No `nix flake check` was run because no
        flake/dependency/package wiring changed.
    - [x] Add nonblocking preview command queue boundary.
      - Completed 2026-05-15: added `native_ui.Command`,
        `queuePreviewScan`, and `takeCommand`. The Nuklear Preview button now
        queues a `PreviewScanPlan` when scanner geometry is available, marks
        preview state busy, and leaves a future worker to consume the command.
        Missing scanner geometry queues nothing and leaves hardware untouched.
        This proves the UI can hand off preview work without blocking; it still
        does not execute a live preview scan.
      - Validation 2026-05-15: `nix develop path:. -c zig build test
        --summary all` passed `248/248`; `nix develop path:. -c zig build
        -Dui=true --summary all` passed; `nix develop path:. -c env
        SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
        ui-smoke --summary all` passed. Updated `docs/PARITY_MANIFEST.md` with
        preview command queue evidence. No `nix flake check` was run because no
        flake/dependency/package wiring changed.
    - [x] Port `scan_handlers._handle_preview` into the native preview
      worker without blocking UI.
      - Required Python oracle: `v600/gui/scan_handlers.py:_handle_preview`.
      - Preserve offline/connecting error behavior, scanner locking, capability
        refresh into TPU dimensions, full-TPU RGB 8-bit preview scan at
        `state.preview_dpi`, cached preview image state, and conversion into a
        displayable preview buffer. The native UI does not need an HTTP JPEG
        response, but any replacement display representation must be derived
        from the same scanned preview pixels and recorded as an adapter detail.
      - Hardware-free tests should use a fake preview executor that records the
        same call sequence and state mutations. Hardware smoke remains gated by
        `V600_HARDWARE_SMOKE=1`.
      - [x] Add handler-shaped nonblocking preview worker/cache boundary.
        - Completed 2026-05-15: extended `src/ui/preview_worker.zig` with an
          owned preview cache, capability refresh before scan execution,
          full-TPU preview request update from refreshed TPU dimensions,
          post-scan TIFF page loading into an 8-bit RGB preview buffer, and
          transfer of preview dimensions into `native_ui.State`. Extended
          `src/ui/state.zig` with preview image metadata plus disconnected,
          connecting, and scanner-error preview request behavior matching the
          route-level `_handle_preview` error surface. Fixed
          `src/scanner/linux.zig` so capability-overridden scans still inherit
          the selected device name instead of emitting `--device-name ""`.
        - Validation 2026-05-15: direct `zig build test --summary all` passed
          `251/251`; `nix develop path:. -c zig build -Dui=true --summary
          all` passed; `nix develop path:. -c env SDL_VIDEODRIVER=dummy
          SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary
          all` passed; gated skip command `nix develop path:. -c zig build
          -Dui=true run-ui -- --preview-worker-smoke --out
          /tmp/v600-native-preview-worker-smoke.tiff` printed the expected
          skip message.
        - Hardware evidence 2026-05-15: `nix develop path:. -c env
          V600_HARDWARE_SMOKE=1 zig build -Dui=true run-ui --
          --preview-worker-smoke --out
          /tmp/v600-native-preview-worker-smoke.tiff` selected
          `epkowa:interpreter:001:017`, emitted scan start for TPU RGB
          requested 200 DPI/effective 400 DPI, wrote
          `/tmp/v600-native-preview-worker-smoke.tiff`, and sidecar
          `/tmp/v600-native-preview-worker-smoke.tiff.json` recorded
          `--device-name epkowa:interpreter:001:017`. `identify` reported
          TIFF `1072x3814`, sRGB, 8-bit.
      - [x] Preserve Python SANE preview downsampling and display-buffer
        conversion semantics.
        - Completed 2026-05-15: generated
          `test/fixtures/ui/preview-lanczos-downsample-smoke.json` from
          Pillow 11.2.1 using `Image.Resampling.LANCZOS`, matching the Python
          SANE path used when a 200 DPI TPU preview is scanned at effective
          400 DPI. Added a separable Lanczos RGB8 resize in
          `src/ui/preview_worker.zig` and apply it to preview cache pixels
          when requested and effective TPU DPI differ. The native cache now
          stores requested-DPI display pixels while retaining the hardware TIFF
          as scanner output evidence.
        - Validation 2026-05-15: direct `zig build test --summary all` passed
          `252/252`, including the Pillow fixture with `<=1` uint8 tolerance;
          `nix develop path:. -c zig build -Dui=true --summary all` passed;
          `nix develop path:. -c env SDL_VIDEODRIVER=dummy
          SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary
          all` passed; the gated native preview smoke printed `native preview
          worker cached 536x1907 8-bit preview` from the effective-400-DPI
          TIFF.
      - Completion note 2026-05-15: this ports the native-worker equivalent of
        `_handle_preview` through preview scanning and cache population. The
        HTTP response-specific JPEG `quality=85` serialization is intentionally
        not part of the native UI path; the display buffer is the native
        adapter representation and is derived from the same Python-oracled
        preview pixels.
    - [x] Store and render preview image/selection state in native UI.
      - [x] Store requested-DPI preview image metadata and render preview
        pixels through SDL texture.
        - Completed 2026-05-15: `native_ui.State` now records
          `PreviewImageInfo`, `PreviewWorker` owns the cached RGB8 preview
          buffer, and `src/ui/main.zig` uploads that buffer to an SDL3 RGB24
          texture for rendering in the scan view. Added
          `fitPreviewImage` in `src/ui/scan_workflow.zig` to mirror the
          browser `fitImage` canvas math with a 20 px pad, and exposed a
          `--preview-render-smoke` path that seeds a synthetic preview buffer
          so the SDL texture upload/render path runs headlessly.
        - Validation 2026-05-15: direct `zig build test --summary all` passed
          `253/253`, including the browser-fit layout test; `nix develop
          path:. -c zig build -Dui=true --summary all` passed; `nix develop
          path:. -c env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig
          build -Dui=true ui-smoke --summary all` passed; `nix develop path:.
          -c env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build
          -Dui=true run-ui -- --preview-render-smoke` exited successfully.
      - [x] Render preview selection overlay and handles from native selection
        state.
        - Completed 2026-05-15: `src/ui/main.zig` now renders the current
          preview selection from `native_ui.ScanControls.selection` over the
          SDL preview texture, including dimmed outside regions, green border,
          and eight resize handles matching the browser canvas overlay shape.
          `--preview-render-smoke` seeds both a synthetic preview buffer and a
          synthetic selection so texture upload and overlay drawing execute
          under the SDL dummy/software renderer.
        - Validation 2026-05-15: direct `zig build test --summary all` passed
          `253/253`; `nix develop path:. -c zig build -Dui=true --summary
          all` passed; `nix develop path:. -c env SDL_VIDEODRIVER=dummy
          SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary
          all` passed; `nix develop path:. -c env SDL_VIDEODRIVER=dummy
          SDL_RENDER_DRIVER=software zig build -Dui=true run-ui --
          --preview-render-smoke` exited successfully.
      - Disk note 2026-05-15: repeated Nix UI checks filled the root
        filesystem. Cleared generated `.zig-cache`, then ran `nix-store --gc`,
        which deleted 131 unreachable store paths and freed about 499 GiB.
        Continue to prefer direct `zig build` checks and reserve Nix wrappers
        for SDL/Nuklear dependency validation.
    - Completion note 2026-05-15: the native preview path now covers the
      browser preview request lifecycle from pure request planning through
      nonblocking execution, scanner event state updates, preview buffer cache,
      requested-DPI downsample parity, SDL preview texture rendering,
      selection overlay rendering, and Nuklear draw-command rendering. The
      path has fake-worker tests, Python/Pillow downsample oracle coverage,
      headless SDL/Nuklear smoke coverage, and gated Linux hardware evidence.
  - [x] Wire native scan start/progress/cancel flow to scanner backend events.
    - Completion 2026-05-15: native scan start/progress/cancel flow is
      headlessly wired from the UI command boundary through the nonblocking scan
      worker and scanner runtime event sink. This covers request planning,
      worker ownership, cancel-file signaling, temporary LUT ownership, Python
      `_handle_scan` status/pass strings, live scan-start/progress event
      draining while the scan thread is still running, and saved-output/failure
      completion status. Browser scan config persistence and live Linux
      hardware smoke are still separate unchecked items below.
    - [x] Add pure native scan-start plan and command queue boundary.
      - Completed 2026-05-15: replaced the native UI's placeholder scan button
        state flip with a scan-start command boundary shaped from the Python
        browser path. Added `ScanStartPlan`, `scanStartPlan`,
        `scanOutputFilename`, and `scanOutputPath` in
        `src/ui/scan_workflow.zig`; exposed `native_ui.State.queueScanStart`;
        and made the preview worker leave scan-start commands pending for the
        future scan worker instead of consuming them, with a dedicated worker
        boundary test. The plan preserves the
        browser `/scan/start` inputs: selected preview rectangle is required,
        the x coordinate is mirrored back into TPU scanner coordinates, output
        filenames use Python's `scan_%04d_<mode>_<dpi>dpi.tiff` pattern,
        RGB/RGB+IR use 16-bit requests, IR uses 8-bit requests, and
        offline/connecting/no-selection status messages match the route/UI
        surface.
      - Algorithm identity 2026-05-15: Python references are
        `v600/gui/scan_ui.py` scan-button JSON construction and
        `v600/gui/scan_handlers.py:_handle_scan` parameter/default parsing and
        output naming. This checkpoint ports only the UI adapter/request
        boundary. It does not claim the full `_handle_scan` algorithm because
        LUT computation via `v600.imaging.film.compute_film_luts`, scanner-lock
        execution, two-pass RGB+IR orchestration, progress/ETA formatting,
        thumbnail creation, and TIFF composition still need direct ports or
        delegation to function-shaped Zig implementations.
      - Validation 2026-05-15: `zig version` reported `0.16.0`; direct
        `zig build test --summary all` failed because the currently opened
        shell was missing the refreshed `libsuperlu` dependency path, so
        validation used a refreshed Nix shell. `nix develop path:. -c zig
        build test --summary all` passed `258/258`; `nix develop path:. -c
        zig build -Dui=true --summary all` passed; `nix develop path:. -c env
        SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
        ui-smoke --summary all` passed. No `nix flake check` was run because
        no flake/dependency/package wiring changed in this checkpoint.
    - [x] Add nonblocking native scan worker/cancel-file boundary.
      - Completed 2026-05-15: added `src/ui/scan_worker.zig` and exported it
        as `native_ui_scan_worker`. The worker consumes only `scan_start`
        commands, duplicates command-owned paths before spawning a thread,
        calls the scanner runtime through an executor boundary, writes the
        cancel file when native UI state requests cancellation, deletes stale
        and completed cancel files, and reports completion, cancellation, and
        execution failure back through `native_ui.State.applyScannerBackendEvent`.
        `src/ui/main.zig` now owns both preview and scan workers; preview
        commands remain with the preview worker and scan commands remain with
        the scan worker.
      - Algorithm identity 2026-05-15: Python reference is
        `v600/gui/scan_handlers.py:_handle_scan` for nonblocking UI state,
        scanner lock/call boundary, cancellation via `_check_cancel`, and
        route-level success/error state mutation. Zig delegates actual scanner
        execution to `scanner_linux.Runtime.scan`, which already ports the
        Linux SANE scanner path. This checkpoint is still only the native
        worker/cancel boundary; it does not port `compute_film_luts`,
        two-pass Python progress strings, or Python TIFF thumbnail/composition
        details.
      - Validation 2026-05-15: `nix develop path:. -c zig build test
        --summary all` passed `262/262`, including fake scan worker success,
        preview-command ownership, cancel-file creation/deletion, cancellation,
        and failure tests; `nix develop path:. -c zig build -Dui=true
        --summary all` passed; `nix develop path:. -c env SDL_VIDEODRIVER=dummy
        SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary
        all` passed. No hardware scan and no `nix flake check` were run because
        this item adds the headless worker boundary without dependency or
        packaging changes.
    - [x] Port `_handle_scan` LUT computation and scan-pass orchestration.
      - [x] Port `compute_film_luts` pure LUT algorithm.
        - Completed 2026-05-15: added `src/scanner/film_lut.zig` and exported
          it through `scanner.film_lut`. The Zig port matches
          `v600/imaging/film.py:compute_film_luts` for 8-bit preview input:
          crop truncation, RGB grayscale mean, NumPy-style 256-bin histogram
          over range `0..255`, Otsu between-class variance threshold,
          `< threshold` film mask, `<100` film-pixel identity fallback,
          NumPy percentile interpolation for 0.5/99.5 black and white points,
          degenerate per-channel fallback, affine mode, linear mode, and
          Python `int()` truncation before `0..255` clamping.
        - Algorithm identity 2026-05-15: Python oracle values were generated
          by running `v600.imaging.film.compute_film_luts` directly on the
          synthetic preview arrays used by the Zig tests. Tests assert the
          exact Otsu threshold `93.134765625`, film pixel count `224`, Python
          black/white percentile values, sampled affine LUT outputs, sampled
          linear LUT outputs, and insufficient-film fallback. This is pure
          algorithm parity only; scan worker integration still needs to pass
          preview pixels into this port, write a temporary scanner LUT file,
          attach `request.lut_file_path` for RGB/RGB+IR visible passes, and
          keep IR passes identity as Python does.
        - Validation 2026-05-15: `nix develop path:. -c zig build test
          --summary all` passed `266/266`; `nix develop path:. -c zig build
          --summary all` passed; `nix develop path:. -c zig build -Dui=true
          --summary all` passed; `nix develop path:. -c env
          SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
          ui-smoke --summary all` passed. No hardware scan and no
          `nix flake check` were run because this was a pure algorithm port
          with no dependency, flake, or package changes.
      - [x] Wire scan worker to preview pixels and temporary LUT file.
        - Completed 2026-05-15: extended `ScanStartPlan` with the unmirrored
          preview selection and exposure mode, then wired `src/ui/scan_worker.zig`
          to compute `scanner.film_lut.computeFilmLuts` from
          `PreviewWorker.last_preview` before spawning the scan thread. The
          worker writes a temporary `*.lut.bin` using `scanner.lut.writeRgbFile`,
          attaches it to `request.lut_file_path`, keeps it alive for the scan
          executor, and deletes it during cleanup. If no preview exists or
          `computeFilmLuts` returns all identity fallbacks, no LUT file is
          attached, matching Python's `last_preview_arr is None` and
          insufficient-film behavior.
        - Algorithm identity 2026-05-15: Python reference is
          `v600/gui/scan_handlers.py:_handle_scan` lines that compute
          `px/py/pw/ph` from the selected area and call
          `compute_film_luts(..., mode=exposure_mode)` before scanner execution.
          The native path uses the original preview-pixel selection captured in
          `ScanStartPlan`, which is equivalent to Python's mirror-back formula
          because the scanner request area was already mirrored for hardware.
        - Validation 2026-05-15: `nix develop path:. -c zig build test
          --summary all` passed `268/268`, including a temporary LUT-file test
          that checks actual serialized LUT bytes at Python-oracle sample
          positions and verifies cleanup; `nix develop path:. -c zig build
          --summary all` passed; `nix develop path:. -c zig build -Dui=true
          --summary all` passed; `nix develop path:. -c env
          SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
          ui-smoke --summary all` passed. No hardware scan was run for this
          headless integration checkpoint.
      - [x] Preserve Python visible-pass/IR-pass LUT policy in RGB+IR scans.
        - Completed 2026-05-15: native RGB and RGB+IR scan-start commands may
          attach the computed LUT file; native IR-only commands keep
          `request.lut_file_path` null even when preview pixels are available.
          The existing Linux runtime `scanRgbIr` keeps the visible RGB request's
          LUT path and explicitly clears the IR request LUT path, matching the
          Python handler's `ir_args['lut_*'] = None` policy for the IR pass.
        - Validation 2026-05-15: `nix develop path:. -c zig build test
          --summary all` passed `268/268`, including the native IR-only
          identity-LUT policy test plus existing SANE LUT-env and RGB+IR runtime
          tests.
      - [x] Preserve Python scan status/progress strings and pass transitions.
        - Completed 2026-05-15: added `_handle_scan`-shaped status helpers in
          `src/ui/scan_workflow.zig` for Python's nested `_fmt_elapsed`,
          `_fmt_eta`, `_progress_rgb`, `_progress_ir`, and `_progress_single`
          behavior. The helpers preserve Python's integer-second truncation,
          `MmSSs` formatting, RGB+IR `ir_dpi = min(dpi, 3200)` weighting,
          RGB total-ETA formula, IR total-percent formula, single-pass
          progress strings, initial pass strings, saved filename status, and
          `Error: ...` scan failure status.
        - Native UI state now uses those function-shaped helpers for queued
          scan-start status, backend RGB-to-IR pass transitions, saved-output
          completion, and scan-worker failure status. Preview progress no
          longer overwrites the current Python-shaped status with a generic
          native-only `Scanning...` string.
        - Algorithm identity 2026-05-15: Python reference is
          `v600/gui/scan_handlers.py:_handle_scan`, specifically the local
          `_fmt_elapsed`, `_fmt_eta`, `_progress_rgb`, `_progress_ir`,
          `_progress_single`, initial `state.scan_status = ...`, saved status,
          and exception status assignments. This checkpoint ports the exact
          string algorithms and state transitions; live scanner progress event
          propagation still needs the next checkpoint to carry the same ETA and
          elapsed inputs before it can display those strings during hardware
          scans.
        - Validation 2026-05-15: `nix develop path:. -c zig build test
          --summary all` passed `270/270`; `nix develop path:. -c zig build
          -Dui=true --summary all` passed; `nix develop path:. -c env
          SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
          ui-smoke --summary all` passed. No hardware scan and no
          `nix flake check` were run because this checkpoint changes the
          headless handler/status model, not dependency or package wiring.
    - [x] Map live scan events/progress into native state and output
      completion.
      - Completed 2026-05-15: added a scanner runtime event sink in
        `src/scanner/events.zig` and `src/scanner/linux.zig`, keeping the
        existing JSONL emitters intact while allowing native callers to receive
        structured `scan-start` and `progress` events. `src/ui/scan_worker.zig`
        now owns an allocation-free, spinlocked bounded event queue shared with
        the scanner thread. `Worker.poll` drains queued events into
        `native_ui.State.applyScannerBackendEvent` before completion, then
        reports final output completion through the existing saved-status path.
      - Algorithm identity 2026-05-15: Python references are
        `v600/gui/scan_handlers.py:_handle_scan` progress callback handoff and
        `scanner.py:EpsonScanner.scan` block-read progress callback. The native
        path maps the scanner backend's live pass/progress events into the same
        handler-shaped state transition surface; Linux SANE still provides only
        percent progress, so ETA-specific status strings remain available in
        the function-shaped helpers and await macOS/interpreter or ETA-capable
        event inputs before live display.
      - Validation 2026-05-15: `nix develop path:. -c zig build test
        --summary all` passed `271/271`, including a fake live scan worker test
        that observes RGB-to-IR pass transition and progress percent while the
        worker thread is still running; `nix develop path:. -c zig build
        -Dui=true --summary all` passed; `nix develop path:. -c env
        SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
        ui-smoke --summary all` passed. No hardware scan and no
        `nix flake check` were run because live hardware validation is the
        explicit next scanner item and no dependency/package semantics changed.
  - [x] Preserve browser scan config persistence in native workflow.
    - Completed 2026-05-15: wired native scan state to the existing
      `src/scanner/config.zig` Python-oracled `epdaughter_config.toml` parser
      and writer. `native_ui.State.applyScannerConfig` restores browser-visible
      `mode`, exact valid `dpi`, `autoselect`, and saved selection inches,
      holding selection as a pending config value until preview geometry is
      available just like the browser `window._pendingSelection` flow. Invalid
      restored DPI values that are unavailable for the restored mode are
      ignored rather than snapped, matching the browser select-option restore.
      `scannerConfigUpdates` and `saveScannerConfig` write the Python writer's
      known scanner config keys, preserving mode/DPI/autoselect independently
      from selection geometry and including selection inches only when the
      current preview selection is persistable. The browser's attempted
      `exposure` key remains intentionally non-persistent because Python
      `save_config` drops unknown keys.
    - Native UI startup now creates the scan directory if needed, loads
      `scans/epdaughter_config.toml`, applies it to the scan controls, and
      saves config only when the controls/selection actually change.
    - Algorithm identity 2026-05-15: Python references are
      `v600/config/settings.py:load_config`, `save_config`, `_format_param`,
      and `v600/gui/scan_ui.py` `restoreConfig`, `applyPendingSelection`, and
      `saveConfig`. This checkpoint reuses the existing function-shaped Zig
      scanner config port and adds the native UI adapter semantics.
    - Validation 2026-05-15: `nix develop path:. -c zig build test
      --summary all` passed `274/274`, including native config restore,
      invalid-DPI restore, update construction, and save/load tests;
      `nix develop path:. -c zig build -Dui=true --summary all` passed;
      `nix develop path:. -c env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
      passed. No hardware scan and no `nix flake check` were run because this
      checkpoint changes native state/UI persistence only.
  - [x] Add hardware-gated native scan workflow smoke evidence on Linux.
    - Completed 2026-05-15: added `--scan-worker-smoke` to `v600-ui`. Without
      `V600_HARDWARE_SMOKE=1` it prints a skip message. With the environment
      gate enabled it builds a tiny native scan workflow in headless mode:
      native scan state, RGB 800 DPI controls, explicit selected preview area,
      explicit output path, scan-worker command queue, Linux scanner runtime,
      live scanner event draining, final saved-output status, and TIFF sidecar
      evidence.
    - Hardware evidence 2026-05-15: `nix develop path:. -c env
      V600_HARDWARE_SMOKE=1 zig build -Dui=true run-ui --
      --scan-worker-smoke --out /tmp/v600-native-scan-worker-smoke.tiff`
      selected cached device `epkowa:interpreter:001:017`, emitted
      `scan-start` for TPU RGB requested/effective 800 DPI, emitted progress
      `15,31,47,63,79,95,100`, emitted `scan-complete`, and reported native
      status `Saved: v600-native-scan-worker-smoke.tiff`.
    - Output evidence 2026-05-15: `identify` reported
      `/tmp/v600-native-scan-worker-smoke.tiff TIFF 200x201 ... 16-bit sRGB`;
      the sidecar `/tmp/v600-native-scan-worker-smoke.tiff.json` recorded
      device `epkowa:interpreter:001:017`, source `tpu`, kind `rgb`,
      requested/effective DPI `800`, depth `16`, `custom_luts_applied=false`,
      and scan command area `-l 58.8 -t 12.1 -x 6.4 -y 6.4`.
    - Validation 2026-05-15: `nix develop path:. -c zig build test
      --summary all` passed `275/275`; `nix develop path:. -c zig build
      -Dui=true --summary all` passed; `nix develop path:. -c env
      SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
      ui-smoke --summary all` passed; gated skip command printed the expected
      skip message.
- [x] Mirror browser process workflow in native UI.
  - Work this item as the following function-for-function checkpoints. Select
    the first unchecked sub-item whose prerequisites are complete; do not mark
    the parent item complete until every sub-item has parity evidence.
  - Parent completion 2026-05-15: all process workflow subitems below are now
    complete: image discovery/info/switching, quick preview generation,
    inverted preview cache behavior, native process controls/status,
    `/process/settings`, `/process/stocks`, `/process/auto-detect`,
    `/process/rebate`, `/process/export`, process trash/delete, and gallery
    handoff. Current validation after later Phase 11 changes: direct
    `zig build test --summary all` passed `303/303`; direct
    `zig build --summary all` passed; direct `zig build -Dui=true --summary all`
    passed; direct no-hardware scanner/native smoke skip steps passed.
  - [x] Port `/process` image discovery, info, and switching state.
    - Python oracle: `v600/gui/process_handlers.py:init`,
      `find_images`, `rescan_images`, `load_image`, `switch_to_image`,
      `handle_get("/info")`, `handle_get("/images")`, and
      `handle_post("/switch")`.
    - Required behavior: TIFF discovery sorted by Python
      `scratchndent.utils.find_images`, missing-directory empty list,
      current-image retention on rescan, invalid-index error behavior,
      page 0/page 2 RGB+IR loading, DPI reading, grayscale/IR flags,
      preview scale calculation from `scratchndent.config.get_preview_size`,
      browser info JSON field semantics, and loading-state transitions.
    - Headless evidence: committed TIFF fixtures or skip-if-missing real scans;
      tests must assert image order, current index retention, switch response
      fields, `dpi_scale = round(CURRENT_DPI / REFERENCE_DPI, 2)` semantics,
      and no accidental replacement of Python's TIFF page rules.
    - Completed 2026-05-15: added `src/processing/workflow.zig` for the
      Python-shaped discovery, retained-index, TIFF metadata, preview-scale,
      and DPI-scale helpers; wired `src/ui/state.zig` native state to own the
      process image list, rescan it, and switch by index; adjusted
      `ProcessingState.finishImageLoad` so browser `switch_to_image` metadata
      loading leaves `full_image_ready=false`, matching Python's global state
      after quick preview generation rather than claiming the full image cache
      is ready.
    - Algorithm identity 2026-05-15: this is a direct port of
      `process_handlers.find_images`, `rescan_images`, `load_image`,
      `switch_to_image`, `/info`, `/images`, and `/switch` state semantics.
      It delegates TIFF page and DPI semantics to the existing Python-oracled
      Zig TIFF helpers: page 0 RGB, page 2 IR only when grayscale/single
      sample, and missing directories returning an empty image list. It does
      not implement quick preview pixel generation; that remains the next
      unchecked sub-item because Python uses OpenCV resize/CLAHE and JPEG
      encoding there.
    - Validation 2026-05-15: direct `zig build test --summary all` was
      attempted first to avoid redundant Nix evaluation, but the current shell
      still lacked `libsuperlu` in Zig's library search path. The cached
      wrapper `nix develop path:. -c zig build test --summary all` passed
      `281/281`, including process image parent-directory discovery,
      retained-index behavior, TIFF metadata loading from
      `test/fixtures/tiff/rgb-thumb-ir.tiff`, DPI/preview-scale arithmetic,
      native `/images`-style rescan, and native `/switch`-style metadata state.
      `nix develop path:. -c zig build -Dui=true --summary all` passed, and
      `nix develop path:. -c env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
      passed.
  - [x] Port quick preview generation for `/process/preview`.
    - Python oracle: `v600/gui/process_handlers.py:switch_to_image` preview
      section from `get_preview_size()` through JPEG generation.
    - Required behavior: OpenCV `INTER_AREA` resize, grayscale-to-RGB
      conversion, uint8-to-uint16 preview raw scaling by 257,
      uint16-to-uint8 display conversion by `>> 8`, raw grayscale content mask
      `gray < 240`, negative inversion `255 - preview8`, percentile stretch
      over content pixels only, OpenCV CLAHE with clip limit 2.0 and 8x8 tiles,
      and JPEG quality 90.
    - Headless evidence: Python-generated tiny fixture with exact or
      codec-tolerant JPEG/preview-buffer expectations. Any non-OpenCV
      approximation is scaffold only and does not close this sub-item.
    - Completed 2026-05-15: added `src/processing/opencv_preview.cpp` and
      `src/processing/workflow.zig` quick-preview ownership. The Zig path now
      loads TIFF page 0, computes `small_rgb`, `PREVIEW_RAW`, display
      `preview8`, and JPEG bytes through the same OpenCV/PIL-shaped algorithm
      as Python, then stores the resulting preview buffers on native
      `State.switchProcessingImage`.
    - Algorithm identity 2026-05-15: direct port of the quick-preview block in
      `process_handlers.switch_to_image`: `preview_scale = min(ps/max(h,w),
      1.0)` for positive preview sizes, `int(w * preview_scale)` and
      `int(h * preview_scale)`, OpenCV `INTER_AREA` resize, OpenCV
      `COLOR_GRAY2RGB`, uint8-to-uint16 `* 257`, uint16 display conversion by
      `>> 8`, OpenCV `COLOR_RGB2GRAY`, content mask `gray < 240`, inversion
      `255 - preview8`, NumPy default linear percentiles at 1 and 99 over
      content pixels, float32 stretch and uint8 truncation, OpenCV CLAHE
      `clipLimit=2.0` with `tileGridSize=(8,8)`, and JPEG quality 90 with RGB
      channel semantics.
    - Validation 2026-05-15: `nix develop path:. -c zig build test --summary
      all` passed `282/282`, including the Python-generated
      `test/fixtures/processing/preview/quick-preview-rgb16-resize.json`
      fixture that exercises resize, content-mask percentile stretch, CLAHE,
      preview raw, preview RGB8, and JPEG decode parity. `nix develop path:. -c
      zig build -Dui=true --summary all` passed, and `nix develop path:. -c env
      SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
      ui-smoke --summary all` passed. Because this checkpoint changed
      `build.zig`, `nix flake check path:.` was also run and passed for the
      current Linux system, with Nix reporting the darwin systems as omitted
      incompatible systems. Direct `zig build test` remains blocked in the
      current shell by the known `libsuperlu` library search path issue, so
      the cached `nix develop path:. -c` wrapper was used.
  - [x] Port `/process/preview/inverted` state and cache behavior.
    - Python oracle: `render_inverted_preview` and `invalidate_inversion_cache`.
    - Required behavior: return `None` when no active stock, no raw preview, or
      grayscale input; cache `PREVIEW_SCENE_LINEAR`; call the same
      `invert_negative` and `render_to_display` algorithms and config
      parameters; fall back to quick preview on render error.
    - Completed 2026-05-15: added native inverted-preview rendering around the
      existing Python-oracled `invertNegative` and `renderToDisplay` ports.
      `State.renderInvertedProcessingPreview` now returns `null` when no quick
      preview exists, no stock is active, or the preview is grayscale; otherwise
      it computes and caches scene-linear preview data, rerenders JPEG output
      from that cache, and exposes explicit cache invalidation matching
      `invalidate_inversion_cache`.
    - Algorithm identity 2026-05-15: direct port of
      `process_handlers.render_inverted_preview` guard/cache composition. It
      uses the same stock coefficient lookup, optional Dmin handoff,
      density-domain inversion pipeline, render parameter defaults, uint16 to
      uint8 display conversion by `>> 8`, and JPEG quality 90 RGB output. The
      scene-linear cache is the only persistent cache, matching Python's
      `PREVIEW_SCENE_LINEAR`; rendered JPEG bytes are regenerated per call so
      changed render settings do not require cache invalidation.
    - Validation 2026-05-15: `nix develop path:. -c zig build test --summary
      all` passed `283/283`, including the Python-generated
      `test/fixtures/processing/preview/inverted-preview-kodak-gold-defaults.json`
      oracle fixture for the composed inverted preview plus no-stock,
      grayscale, cache-reuse, and invalidation tests. `nix develop path:. -c
      zig build -Dui=true --summary all` passed, and `nix develop path:. -c env
      SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
      ui-smoke --summary all` passed. The JPEG output helper uses libjpeg's C
      API to match PIL/libjpeg output without expanding the C++ runtime link
      surface. Because this checkpoint added the libjpeg build object and link
      dependency, `nix flake check path:.` was also run and passed for the
      current Linux system, with Nix reporting the darwin systems as omitted
      incompatible systems.
  - [x] Wire native process controls and status to the state model.
    - Python/browser oracle: `v600/gui/extract_ui.html` process toolbar,
      image navigation, settings fetch/save, stock fetch, rebate controls,
      auto-detect command, export command, trash/delete commands, and progress
      polling.
    - Required behavior: native UI may change presentation, but it must expose
      the same workflow states and issue the same Python-shaped operations.
      Test state/model logic headlessly before manual SDL/Nuklear inspection.
    - Work this UI-state item as smaller checkpoints; do not mark the parent
      complete until every visible process workflow has state-level evidence.
    - [x] Wire process image navigation and preview status controls.
      - Browser oracle: `extract_ui.html` image list refresh, previous/next
        image navigation, preview image refresh, `/process/info`,
        `/process/images`, `/process/switch`, and `/process/progress` polling.
      - Required behavior: native state must expose current filename,
        `idx + 1 / image_count`, loading status, no-image status, preview
        readiness, previous/next bounds, image list refresh, switch command
        results, and progress/status messages without requiring SDL.
      - Completed 2026-05-15: added `ProcessNavigationInfo`,
        `processingNavigationInfo`, `refreshProcessingImageList`,
        `switchPreviousProcessingImage`, and `switchNextProcessingImage`.
        Previous/next now wrap like `extract_ui.html`, image-list refresh keeps
        `/process/images` index semantics, no-image operations return no
        switch result and set `No images`, and preview readiness is exposed from
        native process preview ownership without requiring SDL.
      - Validation 2026-05-15: `nix develop path:. -c zig build test
        --summary all` passed `284/284`, including no-image navigation,
        `/process/images`-style refresh, preview-ready status, filename status,
        and previous/next wrap tests. `nix develop path:. -c zig build
        -Dui=true --summary all` passed, and `nix develop path:. -c env
        SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
        ui-smoke --summary all` passed.
    - [x] Wire process preview display mode controls.
      - Browser oracle: quick preview versus inverted preview selection and
        fallback behavior around `/process/preview/inverted`.
      - Required behavior: native state must select quick preview by default,
        request inverted preview only when enabled, fall back to quick preview
        when the inverted path returns null or errors, and invalidate inversion
        cache when stock/settings changes.
      - Completed 2026-05-15: added native preview mode state through
        `processing_preview_inversion_enabled`, `setProcessingPreviewInversionEnabled`,
        and `renderSelectedProcessingPreview`. The selected preview defaults
        to quick JPEG bytes, uses inverted JPEG bytes only when the mode is
        enabled and the inverted path succeeds, and falls back to quick JPEG
        bytes when the inverted path returns null or errors.
      - Validation 2026-05-15: `nix develop path:. -c zig build test
        --summary all` passed `285/285`, including quick-default,
        no-stock fallback, unknown-stock fallback, inverted-success, and
        no-preview null tests. `nix develop path:. -c zig build -Dui=true
        --summary all` passed, and `nix develop path:. -c env
        SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
        ui-smoke --summary all` passed.
    - [x] Wire auto-detect and selection state controls.
      - Browser oracle: auto-detect format selector, optional frame count,
        returned frames/rebate, manual selection debug route, and preview to
        full-resolution scaling.
      - Required behavior: native state must retain detected frames and rebate
        suggestions in preview coordinates and produce the same export-frame
        request shapes.
      - Completed 2026-05-15: added `ProcessSelection`,
        `applyProcessAutoDetect`, `rescaleProcessAutoSelections`, and
        `processExportRects` to native UI state. The native state now stores
        auto-detected frame rectangles in browser preview coordinates, applies
        the browser auto-scale formula, tracks the active selection, stores the
        suggested rebate rectangle as a top-left preview rectangle, clears
        process selections when switching images, and emits export rectangles
        using the browser preview-to-full-resolution conversion.
      - Algorithm identity 2026-05-15: this checkpoint ports UI-state math
        from `extract_ui.html:1164` through `extract_ui.html:1285` and the
        debug selection surface at `process_handlers.py:581`. It does not
        claim the detector algorithm itself. The detector remains the frozen
        Python `process_handlers.handle_post("/auto-detect")` call to
        `scratchndent.processing.frames.detect_frames`, which is tracked by
        the later `/process/auto-detect` workflow item and the frame-detection
        manifest rows.
      - Validation 2026-05-15: `nix develop path:. -c zig build test
        --summary all` passed `286/286`, including native auto-detect
        selection mapping, scale replay, rebate top-left conversion,
        preview-scale export conversion, radians-to-degrees export angle
        conversion, rotation preservation, and clear-selection behavior.
        `nix develop path:. -c zig build -Dui=true --summary all` passed, and
        `nix develop path:. -c env SDL_VIDEODRIVER=dummy
        SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
        passed. No `nix flake check` was run because this was a native
        state/UI checkpoint with no flake or package dependency change.
    - [x] Wire rebate controls.
      - Browser oracle: rebate rectangle input, `/process/rebate`, Dmin update,
        config persistence, and inversion-cache invalidation.
      - Required behavior: native state must hold the selected rebate, expose
        Dmin availability, and clear cached inverted previews after Dmin
        changes.
      - Completed 2026-05-15: added native process rebate state through
        `ProcessRebateInfo`, `setProcessRebatePreviewRect`,
        `processRebateRequest`, `applyProcessRebateDmin`, and
        `processDminDisplay`. The native state now stores the drawn rebate as
        a top-left preview rectangle, rejects too-small rebate selections with
        the browser status text, converts the request to the same full-
        resolution top-left rectangle sent to `/process/rebate`, exposes Dmin
        availability and display text, and invalidates the inverted-preview
        cache after a Dmin update.
      - Algorithm identity 2026-05-15: this checkpoint ports the browser
        rebate control state from `extract_ui.html:1018`,
        `extract_ui.html:1036`, `extract_ui.html:1050`, and
        `extract_ui.html:1121`, plus the `/process/rebate` request shape from
        `process_handlers.py:486`. It does not claim the rebate pixel
        extraction, `compute_dmin`, TOML persistence, or TIFF lazy-load
        behavior; those remain the later `/process/rebate` native workflow
        item and must use the existing Python-shaped crop, measurement, and
        config helpers.
      - Validation 2026-05-15: `nix develop path:. -c zig build test
        --summary all` passed `287/287`, including rebate preview storage,
        too-small clearing, preview-to-full request conversion, radians
        angle preservation, Dmin display formatting, Dmin availability, and
        inverted-cache invalidation. `nix develop path:. -c zig build
        -Dui=true --summary all` passed, and `nix develop path:. -c env
        SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
        ui-smoke --summary all` passed. Direct `zig build test` remains
        blocked until this terminal is re-entered through the corrected flake
        shell or `shell.nix` is evaluated from a nixpkgs channel with Zig
        0.16.0.
    - [x] Wire export controls and progress.
      - Browser oracle: output variant toggles, basename, export command,
        progress polling, final files list, no-output message, and cancellation
        boundary if present.
      - Required behavior: native state must build the same export request
        model and consume the existing processing event stream.
      - Completed 2026-05-15: added native export control state through
        `ProcessExportControls`, `ProcessExportStatus`,
        `ProcessingBackendEvent`, `beginProcessExport`,
        `applyProcessingBackendEvent`, `finishProcessExport`, and
        `processExportStatus`. Native state now rejects empty selections with
        the browser status text, applies browser checkbox defaults, falls back
        to basename `frame` when the basename field is empty, builds the same
        full-resolution frame rects already covered by the selection
        checkpoint, keeps no-output selections as a valid request for the
        workflow layer to answer, tracks the disabled/exporting state, counts
        written files from events, and updates process status from export
        progress, file-written, completion, cancellation, and error events.
      - Algorithm identity 2026-05-15: this checkpoint ports the browser export
        control/request and polling status behavior from
        `extract_ui.html:1262` through `extract_ui.html:1305`, the
        `handle_export` output selection defaults from
        `process_handlers.py:264`, and the already-existing
        `v600.processing.event.v1` processing event surface. It does not claim
        full `handle_export` execution parity; full image loading, Dmin
        fallback, IR alignment, threaded frame processing, output naming, and
        final metadata remain the later `/process/export` native workflow item.
      - Validation 2026-05-15: `nix develop path:. -c zig build test
        --summary all` passed `288/288`, including no-selection status,
        default/custom basename handling, output checkbox mapping including
        no-output request construction, preview-to-full export rect reuse,
        export-start status, progress message consumption, file-written
        counting, completion status, cancellation status, export error status,
        and final no-output message application. `nix develop path:. -c zig
        build -Dui=true --summary all` passed, and `nix develop path:. -c env
        SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
        ui-smoke --summary all` passed.
    - [x] Wire trash/delete controls.
      - Browser oracle: `/process/trash`, `/process/delete`, image rescan, and
        current-index recovery.
      - Required behavior: native state must expose destructive operations as
        explicit commands with no path traversal and retain browser index
        semantics.
      - Completed 2026-05-15: added process scan mutation state through
        `ProcessImageMutation`, `trashCurrentProcessingImage`, and
        `deleteCurrentProcessingImage`. Native state now targets only the
        currently selected image from the internally discovered image list,
        rejects empty/no-image mutations with the browser error text, moves
        scans to a sibling `.trash` directory with Python collision suffixes,
        deletes the current scan, rescans the image directory, clamps the next
        index like the browser, switches to the recovered image when one
        remains, and clears process image state when the last image is removed.
      - Algorithm identity 2026-05-15: this checkpoint ports the browser
        button workflow in `extract_ui.html:1138` and
        `extract_ui.html:1151` plus the scan mutation behavior in
        `process_handlers.py:601` and `process_handlers.py:619`. It does not
        expose a user-supplied filename for scan deletion, so path traversal is
        avoided by construction; gallery filename mutation remains covered by
        the existing gallery/export helpers and the later gallery handoff item.
      - Validation 2026-05-15: `nix develop path:. -c zig build test
        --summary all` passed `289/289`, including no-image rejection,
        `.trash` collision suffix behavior, post-trash rescan and switch,
        post-delete empty-list recovery, and file removal checks against tiny
        TIFF fixtures. `nix develop path:. -c zig build -Dui=true --summary
        all` passed, and `nix develop path:. -c env SDL_VIDEODRIVER=dummy
        SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
        passed.
    - Completion note 2026-05-15: all native process state-control subitems are
      now covered headlessly: image navigation/status, preview display mode,
      auto-detect selection state, rebate controls, export controls/progress,
      and trash/delete controls. This parent item remains UI/state parity only;
      route-level processing workflows are tracked by the following
      `/process/settings`, `/process/auto-detect`, `/process/rebate`,
      `/process/export`, and gallery handoff items.
    - UI wiring update 2026-05-16: replaced the native Process tab placeholder
      in `src/ui/main.zig` with a functional SDL3/Nuklear panel wired to the
      existing native processing state/workflow helpers. The panel now exposes
      scan image refresh/previous/next/trash/delete, preview sizing, inverted
      preview preference persistence, film-format/frame-count/scale controls,
      auto-detect, Dmin computation from the detected rebate, export output
      toggles, export execution, status/progress text, and process preview
      rendering with frame/rebate overlays.
    - Interaction update 2026-05-16: process frame overlays are interactive in
      the native Process preview. Clicking inside a rotated frame moves it;
      dragging edge/corner handles resizes it in the frame's local rotated
      coordinate system; dragging the rotation handle above the top edge
      updates the continuous frame `angle` consumed by export. Hit testing uses
      rotated geometry and allows handles to sit just outside the preview image
      bounds, matching how rotation handles need to behave at the image edge.
    - Validation 2026-05-16: direct `zig build -Dui=true --summary all`
      passed; direct `zig build test --summary all` passed `334/334`; direct
      `zig build -Dui=true run-ui -- --process-render-smoke` passed using the
      committed `test/fixtures/tiff/rgb-thumb-ir.tiff` preview fixture and no
      scanner hardware. No Nix command was run.
    - Interaction validation 2026-05-16: direct `zig build -Dui=true run-ui --
      --process-interaction-smoke` passed. The smoke loads the Process preview
      fixture, creates a synthetic frame selection, simulates a body drag, a
      south-east resize, and a rotation-handle drag, then fails unless position,
      size, and `angle` all change.
    - Autodetect parity fix 2026-05-16: corrected native Process UI defaults to
      match the browser `/process/auto-detect` call shape. The browser sends
      `{format}` only, so native Auto Detect must leave `n_frames = null` unless
      the operator explicitly enters a positive override. The native default is
      now `Frames = 0` for automatic frame count, and the auto-scale control is
      constrained to the browser's `-1..+1%` range. The Process render smoke now
      asserts that default options are `format="35mm"`, `n_frames=null`,
      `detect_film_extent=true`, `apply_clahe=true`, and scale `0`.
  - [x] Port `/process/settings` and `/process/stocks` native workflow.
    - Python oracle: `handle_get("/settings")`, `handle_post("/settings")`,
      `handle_get("/stocks")`, `scratchndent.config.load_config`,
      `save_config`, `get_available_stocks`, and `get_active_stock`.
    - Algorithm identity: port the route handler and config helper behavior
      step-for-step. Do not replace the TOML model, stock selection rules,
      cache invalidation rule, or JSON response shape with a new native
      settings system.
    - Required behavior: omit private `_stocks` from settings JSON, invalidate
      inversion cache when `stock` changes, preserve custom stock visibility,
      and keep `scratchndent_config.toml` as the only processing config file.
    - Completed 2026-05-15: added native state/config wiring for this
      route pair in `src/ui/state.zig`, `src/processing/config.zig`, and
      `src/ui/main.zig`. The implementation keeps the existing
      `scratchndent_config.toml` parser/serializer, exposes settings without
      private `_stocks`, exposes built-in plus config-defined stock choices,
      loads preview inversion and Dmin state from config, saves updates through
      the same config layer, and invalidates the inverted-preview cache when a
      `stock` update is saved.
    - Validation 2026-05-15: after the human reloaded the ambient nix shell,
      direct `zig build test --summary all` passed `290/290`, including
      `native UI process settings and stocks mirror process_handlers routes`.
      Direct `zig build -Dui=true --summary all` passed, and direct
      `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build
      -Dui=true ui-smoke --summary all` passed. No `nix develop`, `nix-shell`,
      `nix build`, or `nix flake check` commands were run for validation.
  - [x] Port `/process/auto-detect` native workflow.
    - Python oracle: `handle_post("/auto-detect")`,
      `scratchndent.processing.frames.detect_frames`,
      `compute_inter_frame_rebate`, and the single-frame fallback guard.
    - Algorithm identity: call or directly port the existing Python frame
      detector pipeline. A different detector, edge finder, optimizer, frame
      scorer, or rebate estimator cannot complete this item even if it is
      faster on the current scans.
    - Required behavior: operate on `PREVIEW_RAW` in preview coordinates,
      preserve format defaults and `n_frames` override, preserve fallback when
      exactly one frame covers less than 30 percent of preview area, and keep
      frame/rebate output shapes unchanged.
    - Completed 2026-05-15: added `AutoDetectOptions`,
      `AutoDetectResult`, `autoDetectPreview`, `autoDetectDetectedFrames`,
      and `State.runProcessAutoDetect`. Native auto-detect now calls the
      existing Python-parity detector over quick-preview RGB16 raw samples,
      preserves the Python route default `"35mm_strip_6"` boundary, forwards
      the frame-count override, applies the full-preview single-frame fallback
      before rebate computation, and returns `No image loaded` through the
      native state boundary when no preview exists. Updated
      `docs/PARITY_MANIFEST.md` with the route-workflow row.
    - Direct validation 2026-05-15: `zig build test --summary all` passed
      `293/293`, including synthetic `PREVIEW_RAW` detector composition,
      invalid default-format boundary, fallback-before-rebate, and no-image
      state tests. Direct `zig build -Dui=true --summary all` passed, and
      direct `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build
      -Dui=true ui-smoke --summary all` passed. No `nix develop`, `nix-shell`,
      `nix build`, or `nix flake check` commands were run for validation.
  - [x] Port `/process/rebate` native workflow.
    - Python oracle: `handle_post("/rebate")`, `extract_rebate_pixels`,
      `compute_dmin`, `save_config({"dmin": ...})`, and cache invalidation.
    - Algorithm identity: use the same rotated rebate extraction and
      transmittance-to-density median calculation as the Python path. Do not
      substitute a visually similar sampling, masking, or averaging algorithm.
    - Required behavior: parse top-left rebate rectangle input, read full TIFF
      RGB if the full image is not already loaded, compute Dmin through the
      same density algorithm, save the same TOML setting, and return the same
      JSON shape.
    - Completed 2026-05-15: added `loadRgbImageAsF64`,
      `computeRebateDminFromImage`, `computeRebateDminFromTiff`,
      `saveRebateDmin`, `processRebateFromTiff`, and
      `State.runProcessRebate`. Native rebate processing now accepts the
      browser route's full-resolution top-left rectangle, uses the existing
      Python-parity rotated crop and density-domain Dmin pipeline, reads TIFF
      page 0 when no full image buffer is resident, persists Dmin through
      `scratchndent_config.toml`, updates native Dmin state, and invalidates
      the inverted-preview cache. Updated `docs/PARITY_MANIFEST.md` with the
      route-workflow row.
    - Direct validation 2026-05-15: `zig build test --summary all` passed
      `295/295`, including synthetic top-left rebate crop/Dmin composition,
      TIFF fixture Dmin save, native no-image boundary, state Dmin update,
      config update, and cache invalidation tests. Direct `zig build -Dui=true
      --summary all` passed, and direct `env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
      passed. No `nix develop`, `nix-shell`, `nix build`, or `nix flake check`
      commands were run for validation.
  - [x] Port `/process/export` native workflow.
    - Python oracle: `handle_export`, `ensure_loaded`,
      `scratchndent.align_ir`, `scratchndent.export.process_frame`,
      `generate_unique_path`, and progress messages.
    - Algorithm identity: preserve each Python export step and named
      dependency, including IR alignment, rotated crop, dust removal,
      negative inversion, render, metadata, and naming behavior. Performance
      work may reorganize memory and scheduling only after fixtures prove the
      same observable outputs.
    - Required behavior: output selection defaults, no-output message, Dmin
      loading/computation, IR alignment scaling, per-frame output naming,
      metadata shape, single-frame vs thread-pool progress order where
      observable, and final message semantics.
    - Completed 2026-05-15: added `FullImage`, `ExportWorkflowOptions`,
      `ExportWorkflowResult`, `loadFullImageAsF64`, `processExportFromTiff`,
      `BaseMetadata.rebate_rect`, and `State.runProcessExport`. Native export
      now short-circuits no-output requests before input loading, loads
      full-resolution RGB/IR pages from TIFF, computes Dmin from an active
      stock using the valid rebate rectangle or full image fallback, uses the
      existing OpenCV ECC IR alignment path and RGB/IR scale factors, delegates
      frame output to the existing Python-parity `processFrame`, preserves
      output path naming/collision behavior, carries rebate metadata into
      exported TIFF sidecar metadata, returns Python-shaped progress/final
      messages including elapsed time, and updates native export/Dmin status.
      Thread-pool scheduling remains a performance implementation detail
      because Python multi-frame completion order is nondeterministic.
      Updated `docs/PARITY_MANIFEST.md` with the route-workflow row.
    - Direct validation 2026-05-15: `zig build test --summary all` passed
      `298/298`, including no-output short-circuit, route-shaped TIFF export,
      Dmin fallback from rebate, metadata rebate propagation, native state
      export status, and output file existence checks. Direct `zig build
      -Dui=true --summary all` passed, and direct `env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
      passed. No `nix develop`, `nix-shell`, `nix build`, or `nix flake check`
      commands were run for validation.
  - [x] Port process trash/delete and gallery handoff.
    - Python oracle: `_scan_trash`, `_scan_delete`, `rescan_images`, and the
      gallery handlers that share `OUTPUT_DIR`.
    - Algorithm identity: preserve the browser/Python file mutation semantics
      exactly, including current-image-only scan mutation and gallery
      filename validation. Do not replace this with a broader file-manager
      abstraction.
    - Required behavior: `.trash` directory placement, collision suffixes,
      current-index retention/recovery after rescan, no-image errors, delete
      semantics, and shared output directory state.
    - Completed 2026-05-15: scan trash/delete state was already covered by
      `ProcessImageMutation`, `trashCurrentProcessingImage`, and
      `deleteCurrentProcessingImage`. Added the missing native gallery handoff
      state in `src/ui/state.zig`: `GalleryInfo`, `refreshGalleryFiles`,
      `showGalleryImage`, previous/next wrap navigation,
      `trashCurrentGalleryFile`, and `deleteCurrentGalleryFile`.
    - Algorithm identity 2026-05-15: gallery state now uses the same
      `processing.output_dir` that export writes to, mirrors the browser
      `/gallery/list` empty-directory result and `No exports found` status,
      preserves numeric `currentIdx` behavior across refresh and mutation,
      resets to index 0 when the old index is out of range, wraps previous/next
      navigation, rejects no-current-file destructive commands, and delegates
      filename validation, `.trash` placement, `_n` collision suffixes, and
      delete semantics to the Python-shaped gallery file helpers.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `299/299`, including the new native gallery handoff test for missing
      output directories, TIFF-only sorted listing, index clamping, wrap
      navigation, no-file rejection, `.trash` collision behavior, delete, and
      empty-gallery recovery. Direct `zig build -Dui=true --summary all`
      passed, and direct `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software
      zig build -Dui=true ui-smoke --summary all` passed. No `nix develop`,
      `nix-shell`, `nix build`, or `nix flake check` commands were run.
- [x] Mirror browser gallery workflow in native UI.
  - [x] Wire native gallery panel to the shared output-directory state.
    - Completed 2026-05-15: replaced the gallery placeholder in
      `src/ui/main.zig` with `drawGalleryView`, which exposes Refresh,
      Previous, Next, Trash, Delete, selectable filenames, empty-gallery
      messaging, and state status text through Nuklear. Switching into the
      gallery view refreshes the shared `processing.output_dir` before
      drawing.
    - Completed 2026-05-15: added `GalleryTextureCache`,
      `renderGalleryTexture`, and `galleryImageRgb8` so the selected export
      TIFF is loaded through the existing TIFF reader, converted to RGB24, and
      rendered behind the control panel with the same fit math used by the
      scanner preview. The smoke seed copies a real tiny TIFF fixture into
      `.zig-cache/tmp/v600-native-gallery-smoke` so the selected-image texture
      path is exercised headlessly.
    - Validation 2026-05-15: direct `zig build -Dui=true --summary all`
      passed, direct `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig
      build -Dui=true ui-smoke --summary all` passed, and direct `env
      SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
      run-ui -- --gallery-render-smoke` passed. The state contract was also
      covered by the direct `zig build test --summary all` run above
      (`299/299`). No Nix commands were run.
  - [x] Add thumbnail strip parity for exported TIFFs.
    - Browser oracle: `refreshList()` thumbnail creation and active thumbnail
      state in `gallery.html`.
    - Required behavior: list rebuild on changed filenames, active selection
      highlighting, and no dependence on external web assets.
    - Completed 2026-05-15: added `GalleryThumbnailCache` and selectable
      Nuklear image thumbnails to `drawGalleryView`. The cache is scoped to
      `processing.output_dir`, prunes stale thumbnails when the gallery file
      list changes, and uses the existing TIFF reader plus `galleryImageRgb8`
      conversion to build SDL RGB24 textures.
    - Algorithm identity 2026-05-15: native thumbnail dimensions follow the
      browser `/gallery/thumb/<name>` route's `max_dim=200` sizing rule:
      `scale = min(max_dim / max(h, w), 1.0)` and integer-truncated
      destination width/height. Downsampling uses the existing
      OpenCV-INTER_AREA-parity `resizeImageArea` helper before the texture is
      handed to Nuklear. The active thumbnail is represented through
      Nuklear's selected image widget state, matching the browser active
      thumbnail state without external image assets.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `299/299`; direct `zig build -Dui=true --summary all` passed; direct
      `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
      ui-smoke --summary all` passed; direct `env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true --summary all run-ui --
      --gallery-render-smoke` passed. The gallery render smoke seeds two real
      TIFF fixture exports and now fails if every listed export does not create
      a thumbnail texture or if no active gallery item exists. No Nix commands
      were run.
  - [x] Add pan/zoom/fit interactions for the selected export image.
    - Browser oracle: wheel zoom around cursor, middle-mouse drag pan,
      double-click fit, and resize-triggered fit.
    - Required behavior: stable transform state per selected image and no text
      overlap with the control panel.
    - Completed 2026-05-15: added `GalleryViewTransform` plus SDL event
      handling for the selected gallery image. The transform is keyed by the
      selected TIFF path and render output size, refits on image change or
      resize, keeps stable scale/offset while the same image is selected,
      zooms around the wheel cursor, pans with the middle mouse button, and
      refits on double-click. Gallery fitting now follows the browser behavior
      of centering at `min(container/image, 1.0)` instead of upscaling tiny
      images.
    - Completed 2026-05-15: added SDL-to-Nuklear mouse input mirroring for
      motion, buttons, and wheel scroll so native gallery controls and
      selectable thumbnails can receive real input. Gallery image transform
      events ignore the fixed control-panel rectangle so image pan/zoom does
      not fight the overlaid controls.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `299/299`; direct `zig build -Dui=true --summary all` passed; direct
      `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
      ui-smoke --summary all` passed; direct `env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true --summary all run-ui --
      --gallery-render-smoke` passed; direct `env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true --summary all run-ui --
      --gallery-interaction-smoke` passed. The interaction smoke runs after
      the first fitted render and verifies wheel zoom changes scale,
      middle-drag changes offset and clears panning on mouse-up, double-click
      requests fit, resize requests fit, and the second smoke frame can refit.
      No Nix commands were run.
  - [x] Add keyboard shortcuts and refresh cadence.
    - Browser oracle: ArrowLeft/ArrowRight navigation, Delete/Backspace trash,
      initial refresh, focus refresh, and 500 ms list refresh.
    - Required behavior: avoid needless filesystem churn while preserving the
      browser-observable refresh behavior.
    - Completed 2026-05-15: added gallery keyboard handling for ArrowLeft,
      ArrowRight, Delete, and Backspace. Left/right delegate to the same
      wraparound gallery selection state as the buttons. Delete/Backspace
      delegates to `trashCurrentGalleryFile`, matching the browser shortcut's
      trash behavior; the confirmation prompt is intentionally tracked by the
      following destructive-operation checkpoint.
    - Completed 2026-05-15: added `refreshGalleryFilesIfChanged` to native
      state so browser-style list refreshes can return early when filenames
      are unchanged. Gallery entry still performs an initial refresh, window
      focus performs a refresh-if-changed, and the main loop runs a gallery-only
      500 ms refresh cadence without rescanning while the user is outside the
      gallery. Unchanged refreshes preserve existing status text and avoid
      thumbnail rebuilds.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `299/299`, including refresh-if-changed preservation and changed-list
      recovery inside the gallery handoff test. Direct `zig build -Dui=true
      --summary all`, direct `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software
      zig build -Dui=true ui-smoke --summary all`, direct `env
      SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
      --summary all run-ui -- --gallery-render-smoke`, direct `env
      SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
      --summary all run-ui -- --gallery-interaction-smoke`, and direct `env
      SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
      --summary all run-ui -- --gallery-shortcut-smoke` all passed. The
      shortcut smoke verifies ArrowRight, ArrowLeft, Backspace trash, changed
      refresh at the 500 ms boundary, and skipped unchanged refresh before
      exiting. No Nix commands were run.
  - [x] Add destructive-operation confirmation UI.
    - Browser oracle: `confirm()` before trash/delete.
    - Required behavior: explicit native confirmation state before mutating
      files; no accidental delete from a single stray click.
    - Completed 2026-05-15: added `GalleryConfirmation` and
      `GalleryConfirmAction` to hold a pending destructive operation and the
      captured filename. Trash/Delete buttons and Delete/Backspace shortcuts
      now request confirmation instead of mutating files immediately.
    - Algorithm identity 2026-05-15: confirmation executes the filename
      captured when the destructive command was requested, matching the
      browser's `confirm()` closure over `name`; cancelling drops the pending
      operation and leaves the file list unchanged. Execution delegates to
      `trashGalleryFileByName` or `deleteGalleryFileByName`, preserving the
      already-oracled route filename validation, `.trash` collision behavior,
      delete semantics, and post-mutation refresh.
    - Validation 2026-05-15: direct `zig build test --summary all` passed
      `299/299`; direct `zig build -Dui=true --summary all`, direct `env
      SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
      ui-smoke --summary all`, direct `env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true --summary all run-ui --
      --gallery-render-smoke`, direct `env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true --summary all run-ui --
      --gallery-interaction-smoke`, direct `env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true --summary all run-ui --
      --gallery-shortcut-smoke`, and direct `env SDL_VIDEODRIVER=dummy
      SDL_RENDER_DRIVER=software zig build -Dui=true --summary all run-ui --
      --gallery-confirm-smoke` all passed. The confirmation smoke verifies
      delete request without mutation, cancel without mutation, trash request
      without mutation, and mutation only after Confirm. No Nix commands were
      run.
- [x] Add manual screenshot/window verification notes.
  - Completed 2026-05-15: added `docs/NATIVE_UI_VERIFICATION.md` to define
    the split between automated SDL dummy checks and real-window manual
    inspection. The document records the ambient-shell/no-Nix rule, direct Zig
    headless gate commands, what those gates prove, what they do not prove, and
    the required real-display screenshot checklist.
  - Required future manual evidence: before release acceptance, run
    `zig build -Dui=true run-ui` on a real display and capture Scan/Gallery
    screenshots at normal and resized window sizes, including gallery
    confirmation prompts and zoom/pan state. Record the date, display
    environment, screenshot paths, commands, and visual defects in this plan.
  - Validation 2026-05-15: documentation-only checkpoint; `git diff --check`
    passed for the touched files. The immediately preceding native UI
    checkpoint also passed direct `zig build test --summary all`, direct
    `zig build -Dui=true --summary all`, and all SDL dummy UI smoke commands.

### Phase 9A: Post-Review Native UI Parity Corrections

These checkpoints come from the direct browser-vs-native parity review. Treat
them as blocking UI parity work even when an earlier broad Phase 9 item is
checked. Work them one at a time, preserve the Python/browser oracle named in
each item, add or update headless tests before checking the item off, and record
the direct Zig validation command output in this plan. Continue to rely on the
conversation's ambient nix shell: use direct `zig ...` commands only. Do not run
`nix develop`, `nix-shell`, `nix build`, or `nix flake check` for these UI
parity corrections unless a checkpoint explicitly changes Nix dependency wiring;
if a missing dependency requires a shell change, edit the Nix files and stop for
human shell reload.

- [x] Restore native Scan preview auto-select parity.
  - Python/browser oracle: `v600/gui/scan_ui.py` preview `img.onload`
    auto-detect flow, `v600/gui/scan_handlers.py:/detect`, and
    `v600/imaging/film.py:detect_film_area`.
  - Required behavior: after the preview worker loads a requested-DPI preview,
    clear the previous auto selection, detect the largest dark film region from
    the displayed preview pixels when `scan_controls.autoselect` is enabled,
    set both `auto_selection` and the current `selection`, surface the browser
    status `Film area detected. Adjust selection if needed.`, keep Restore Auto
    meaningful, and persist the selected area through the existing scanner
    config save path. If no film is detected, leave selection empty and surface
    `No film detected. Draw a rectangle manually.`. If autoselect is disabled,
    apply the pending saved selection and surface the preview-ready manual
    selection status.
  - Algorithm identity: preserve Python `detect_film_area` semantics exactly:
    grayscale is the channel mean, threshold is the midpoint of NumPy-style
    25th and 75th percentiles, components use the SciPy `ndimage.label` default
    connectivity, the largest dark component is rejected when it is `< 5%` of
    all preview pixels, bounds use the Python `cmax - cmin` and `rmax - rmin`
    width/height convention, coordinates are converted through preview DPI and
    TPU inches, and padding uses the function default `pad=0.0125`, not
    `detect_pad` or another config value.
  - Completed 2026-05-16: added `detectFilmAreaSelection` as the native port
    of `v600.imaging.film.detect_film_area`, wired `State.applyPreviewAutoSelect`
    into `PreviewWorker.poll` after the preview pixels are cached, preserved
    browser status text for detected/no-film/auto-detect-failed outcomes,
    restored pending saved selections when autoselect is disabled, and added a
    post-worker scanner-config save check in the main loop so worker-created
    auto selections persist like the browser `saveConfig()` call.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `339/339`, including largest dark-region detection, tiny-component
    rejection, native auto-select state, no-film state, and manual saved
    selection restore tests. Direct `zig build -Dui=true --summary all` passed.
    Direct `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build
    -Dui=true ui-smoke --summary all` passed. Direct `env SDL_VIDEODRIVER=dummy
    SDL_RENDER_DRIVER=software zig build -Dui=true run-ui --
    --preview-render-smoke` passed. No Nix commands were run.
- [x] Make native Process auto-detect compute and persist Dmin from the
      suggested rebate.
  - Python/browser oracle: `extract_ui.html:runAutoDetect` calls
    `sendRebateToServer`; `v600/gui/process_handlers.py:/rebate`.
  - Required behavior: after auto-detect returns a rebate rectangle, convert it
    to the same full-resolution top-left rectangle the browser sends, compute
    Dmin through the existing native rebate workflow, save it to
    `scratchndent_config.toml`, update process Dmin state, and invalidate the
    inverted-preview cache before redrawing.
  - Completed 2026-05-16: added `State.runProcessAutoDetectRebate` and wired
    the native Auto Detect button so a returned suggested rebate immediately
    flows through the existing `/process/rebate` parity workflow. The follow-up
    uses the same preview-to-full conversion as manual rebate, persists `dmin`
    through processing config save, updates `processing.dmin`, stores the full
    rebate rectangle, and invalidates the inverted-preview cache.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `340/340`, including a TIFF-fixture-backed auto-detect suggested-rebate
    Dmin persistence test. Direct `zig build -Dui=true --summary all` passed.
    Direct `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build
    -Dui=true ui-smoke --summary all` passed. Direct `env SDL_VIDEODRIVER=dummy
    SDL_RENDER_DRIVER=software zig build -Dui=true run-ui --
    --process-render-smoke` passed. No Nix commands were run.
- [x] Restore native Process auto-detected frame output rotation default.
  - Python/browser oracle: `extract_ui.html` initializes `lastRotation = 270`
    and applies it to newly auto-detected selections.
  - Required behavior: native auto-detect must default each new frame
    selection's discrete output rotation to `270` until the operator changes
    it. Continuous selection angle remains the detector/canvas angle and must
    not be confused with output rotation.
  - Completed 2026-05-16: added the named native
    `default_process_output_rotation = 270`, initialized Process UI auto-detect
    state with it, and passed it into `applyProcessAutoDetect` so newly
    detected frame selections export with the browser's default discrete
    rotation. The existing continuous detector `angle` remains unchanged.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `340/340`. Direct `zig build -Dui=true --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
    ui-smoke --summary all` passed. Direct `env SDL_VIDEODRIVER=dummy
    SDL_RENDER_DRIVER=software zig build -Dui=true run-ui --
    --process-render-smoke` passed. No Nix commands were run.
- [x] Auto-detect Process frames on initial image load and image switch.
  - Python/browser oracle: `extract_ui.html` initial preview `img.onload`
    one-shot auto-detect and `switchImage` one-shot auto-detect.
  - Required behavior: native Process image load should run the same default
    auto-detect command once for a newly loaded image, including rebate/Dmin
    follow-up once that checkpoint is complete, without repeatedly rerunning on
    every frame.
  - Completed 2026-05-16: added `process_auto_detect_pending` to native state.
    `switchProcessingImage` sets the pending flag after a quick preview is
    loaded, `takeProcessAutoDetectPending` consumes it once, and the main UI
    loop runs the same `runProcessAutoDetectWorkflow` used by the Auto Detect
    button when the Process view has a pending load. This covers initial
    Process tab load and previous/next/switch image loads without repeated
    per-frame detector calls.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `340/340`, including one-shot pending auto-detect assertions for initial
    process image switch and next/previous image navigation. Direct
    `zig build -Dui=true --summary all` passed. Direct `env SDL_VIDEODRIVER=dummy
    SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
    passed. Direct `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig
    build -Dui=true run-ui -- --process-render-smoke` passed. No Nix commands
    were run.
- [x] Make the native Process inverted-preview checkbox affect the rendered
      preview texture.
  - Python/browser oracle: `/process/preview/inverted` and the browser preview
    mode toggle.
  - Required behavior: the checked state must change the image drawn in the
    native Process preview, using the selected quick or inverted preview bytes
    or an equivalent texture cache, and must fall back to quick preview on the
    same no-stock/grayscale/error boundaries as the Python route.
  - Completed 2026-05-16: changed `ProcessPreviewTextureCache` to render from
    the selected Process preview path instead of always uploading
    `preview_rgb8`. When inversion is enabled and an active stock can render,
    the cache decodes the inverted preview JPEG into the SDL texture. If the
    inverted path returns null or errors, it falls back to the quick RGB
    texture. Cache reuse now distinguishes quick data from inverted
    scene-linear cache identity, so Dmin/cache invalidation can force a redraw.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `340/340`. Direct `zig build -Dui=true --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
    ui-smoke --summary all` passed. Direct `env SDL_VIDEODRIVER=dummy
    SDL_RENDER_DRIVER=software zig build -Dui=true run-ui --
    --process-render-smoke` passed; the smoke now enables an active stock and
    preview inversion and fails unless the Process texture used the inverted
    render path. No Nix commands were run.
  - Follow-up completed 2026-05-17: fixed the native UI lockup when toggling
    preview inversion by moving inverted-preview rendering out of
    `ProcessPreviewTextureCache.textureFor` and into
    `src/ui/inverted_preview_worker.zig`. The worker snapshots the quick-preview
    raw buffer, active stock, Dmin, render/color options, preview generation,
    and source pointer before spawning. The UI render path now starts at most one
    keyed inverted-preview job, keeps drawing the quick RGB texture while it is
    pending, uploads only completed RGB8 results, and rejects stale results if
    the image, generation, stock, Dmin, or render options changed.
  - Follow-up validation 2026-05-17: direct `zig build test --summary all`
    passed `364/364`; direct `zig build -Dui=true --summary all` passed; direct
    dummy SDL `zig build -Dui=true ui-smoke --summary all` passed; direct dummy
    SDL `zig build -Dui=true run-ui -- --process-render-smoke`,
    `run-ui -- --process-interaction-smoke`,
    `zig build -Dui=true native-process-worker-smoke --summary all`, and
    `run-ui -- --process-selector-smoke` passed. No Nix commands were run.
- [x] Fill native Process settings, stock, render, IR, and color controls.
  - Python/browser oracle: `extract_ui.html` settings panel, film-stock
    selector, render sliders, color pad, IR dust-removal sliders, and stock
    selection behavior.
  - Required behavior: expose the browser's editable processing settings in
    Nuklear, persist through the same config keys, invalidate cached inverted
    previews when required, and preserve the browser behavior where selecting a
    stock enables IR cleaning and inverted preview state.
  - Completed 2026-05-16: added native Process controls for film stock,
    rendering parameters, color balance, and IR dust/scratch settings. The
    controls initialize from `scratchndent_config.toml` values or Python
    defaults, save through the existing processing config merge path, and keep
    export option defaults in sync with persisted config where present. Stock
    selection now saves the active stock, invalidates inverted-preview cache
    through `saveProcessingSettings`, and enables the native `IR inv` export
    option like the browser. Render and color settings are now included in
    `processingInvertedPreviewOptions`, and the SDL Process texture cache keys
    inverted preview reuse on render/color options so changed settings redraw
    the preview. The color balance control includes an interactive Nuklear
    color pad plus numeric temp/tint controls and reset.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `340/340`, including render-option propagation through
    `processingInvertedPreviewOptions`. Direct `zig build -Dui=true --summary
    all` passed. Direct `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software
    zig build -Dui=true ui-smoke --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
    run-ui -- --process-render-smoke` passed. No Nix commands were run.
  - Follow-up completed 2026-05-17: wired the native Preview `Max px` control
    to the existing `preview_size` processing config key. The control now
    initializes from `scratchndent_config.toml`/Python defaults through
    `syncProcessUiFromConfig`, queues changed values into
    `ProcessSettingsDraft`, and persists through `saveProcessingSettings` so
    subsequent image loads and future program runs keep the chosen
    quality/performance tradeoff.
- [x] Fill native Process selection editing parity.
  - Python/browser oracle: `extract_ui.html` selection drawing/editing model.
  - Required behavior: support manual drawing of new frame selections, `+ New`
    selection, aspect-ratio selector and enforcement, active-selection edits,
    per-frame discrete rotation dropdown, editable rebate draw/move/resize,
    rebate rotation, and four rotation handles for frame selections.
  - Completed 2026-05-16: native Process now exposes the browser aspect
    selector with the same option set and config key, updates it from
    auto-detect aspect strings, supports `+ New selection` using browser-style
    last-size/last-angle/last-rotation inheritance, supports click-drag manual
    frame drawing with aspect enforcement, and shows a selectable per-frame
    list with delete and discrete `0/90/180/270` output rotation controls.
    Frame overlays now expose eight resize handles plus four rotation handles,
    and resize operations enforce the active aspect ratio for frame selections
    while keeping rebate selections freeform. Rebate overlays are now selectable
    editing targets: `Set rebate` arms a draw operation, existing rebates can
    be moved/resized/rotated through the same local-geometry interaction path,
    and valid rebate draw/edit mouse-up finalizes the preview rect and runs the
    Dmin workflow like the browser `/process/rebate` postback.
  - Follow-up completed 2026-05-17: made Process frame/rebate overlays easier
    to see by replacing one-pixel `SDL_RenderLines` borders with an
    antialiased screen-space geometry stroke. The overlay width is controlled by
    the named `process_selection_line_width` constant in `src/ui/main.zig`, with
    `process_selection_antialias_width` controlling the translucent edge falloff.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `341/341`, including manual process selection add/remove list semantics.
    Direct `zig build -Dui=true --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
    ui-smoke --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
    run-ui -- --process-render-smoke` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
    run-ui -- --process-interaction-smoke` passed; the interaction smoke now
    covers move, resize, right-side rotation handles, aspect-bound `+ New`,
    manual frame drawing, and rebate move/rotate hit targets. No Nix commands
    were run.
- [x] Preserve Process Clear semantics.
  - Python/browser oracle: browser Clear button behavior.
  - Required behavior: Clear removes frame selections only. It must not clear
    the rebate rectangle, Dmin, or cached Dmin-derived state.
  - Completed 2026-05-16: split native Process selection cleanup into two
    explicit operations. `clearProcessingSelections()` now matches the browser
    Clear button by clearing only frame selections and the active frame index;
    it preserves the suggested/manual rebate rectangle, full-resolution rebate
    request state, Dmin, the inverted-preview cache, and the last auto-detect
    frame cache so the scale control can repopulate selections. Image switches
    and no-image mutation cleanup now call `clearProcessingImageSelections()`,
    which still clears image-local frame, auto-detect, and rebate overlays so
    stale overlays do not leak onto another TIFF.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `341/341`, including assertions that browser Clear preserves rebate/Dmin
    state and that image-level cleanup clears image-local overlays. No Nix
    commands were run.
- [x] Restore Process export basename parity.
  - Python/browser oracle: browser export basename input defaults to the
    current scan filename stem and remains editable.
  - Required behavior: native export controls should initialize basename from
    the active scan filename stem, preserve operator edits while the image is
    unchanged, and update appropriately when switching images.
  - Completed 2026-05-16: native Process now has an editable basename field in
    the Export section. The field initializes from the active image stem using
    the same last-extension stripping behavior as the browser, preserves
    operator edits while `processing.input_path` is unchanged, resets to the
    next image stem when the active image changes, and passes the current field
    value into `State.runProcessExport`. An empty field still falls back to
    `frame` through the existing export request boundary, matching
    `basename.value || "frame"`.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `341/341`, including current image stem assertions with multi-dot names.
    Direct `zig build -Dui=true --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
    ui-smoke --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
    run-ui -- --process-render-smoke` passed; the Process render smoke now
    asserts basename initialization, edit preservation while the image is
    unchanged, and reset on image-path change. No Nix commands were run.
- [x] Add Process trash/delete confirmation.
  - Python/browser oracle: `confirm()` before destructive scan mutations.
  - Required behavior: native Process trash/delete and relevant shortcuts must
    request explicit confirmation before mutating files, capture the filename
    being confirmed, and mutate only on confirmation.
  - Completed 2026-05-16: native Process `Trash` and `Delete` buttons now
    create a pending confirmation instead of mutating immediately. The pending
    action stores the filename shown at request time, renders `Confirm` and
    `Cancel` controls in the Process panel, leaves the image list unchanged
    until confirmation, and refuses to mutate if the active filename changed
    before confirmation. Confirm dispatches to the existing Python-shaped trash
    or delete workflow; Cancel drops the pending action without touching files.
    There were no pre-existing Process destructive keyboard shortcuts to
    preserve; gallery shortcuts remain separate.
  - Validation 2026-05-16: direct `zig build -Dui=true --summary all` passed.
    Direct `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build
    -Dui=true run-ui -- --process-confirm-smoke` passed against temporary TIFF
    copies under `.zig-cache/tmp`, verifying captured filename, no mutation
    before confirmation, cancel behavior, and mutation only after Confirm. No
    Nix commands were run.
- [x] Restore Gallery left-drag pan when zoomed.
  - Python/browser oracle: `gallery.html` permits left-button drag when
    `scale > 1.01` and middle-button drag at any zoom.
  - Required behavior: native Gallery should keep middle-drag pan behavior and
    additionally pan with left drag only when zoomed beyond the browser
    threshold, without stealing thumbnail or control-panel input.
  - Completed 2026-05-16: native Gallery image interaction now starts panning
    on left-button drag only when the fitted image scale is above `1.01`, while
    preserving middle-button panning at any zoom. Double-click fit and
    control-panel exclusion still take priority, and pan release now tracks the
    initiating mouse button so left and middle drags both end cleanly.
  - Validation 2026-05-16: direct `zig build -Dui=true --summary all` passed.
    Direct `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build
    -Dui=true run-ui -- --gallery-interaction-smoke` passed; the smoke now
    asserts that left-drag does not pan at fitted scale, left-drag does pan
    after wheel zoom, middle-drag still pans, double-click still requests fit,
    and resize still requests fit. No Nix commands were run.

- [x] Restore native Scan manual selection editing parity.
  - Review source: 2026-05-16 second browser-vs-native UI parity pass.
  - Python/browser oracle: `v600/gui/scan_ui.py` canvas handlers for draw,
    move, resize, wheel zoom, Escape/Delete clear, and scan-start area
    conversion.
  - Required behavior: native Scan must let the operator create, move, and
    resize the preview selection directly on the rendered preview; reject tiny
    selections the same way the browser does; keep the existing dimmed overlay
    and handles meaningful; clear with Escape/Delete once the keyboard shortcut
    checkpoint is completed; save valid selection changes through scanner config;
    and ensure `Scan Selection` can be reached without relying on auto-detect or
    test-only seeded state.
  - Required tests/evidence: add headless model tests for draw/move/resize
    geometry, mirror-back scan-start conversion, saved-selection persistence,
    and too-small selection rejection. Add an SDL dummy smoke path that seeds a
    preview, sends representative mouse events, and fails if
    `scan_controls.selection` is not updated before scan planning.
  - Completed 2026-05-16: added native Scan selection interaction state and
    routed SDL mouse events through `handleScanSelectionEvent` while the Scan
    view is active. The native preview now supports browser-shaped left-drag
    selection drawing, hit-tested move, eight-handle resize, too-small draw
    rejection, direct scan-start planning from an event-created selection, and
    preservation of the stored auto-selection so Restore Auto remains meaningful
    after manual adjustment. The main loop now captures scan-control state before
    SDL event dispatch, so mouse-created selection changes are eligible for the
    existing scanner config save path in the same frame.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `342/342`, including `scan preview selection draw move and resize mirror
    browser canvas math` plus the existing mirrored scan-start and config
    conversion tests. Direct `zig build -Dui=true --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
    ui-smoke --summary all` passed. Direct `env SDL_VIDEODRIVER=dummy
    SDL_RENDER_DRIVER=software zig build -Dui=true run-ui --
    --preview-render-smoke` passed. Direct `env SDL_VIDEODRIVER=dummy
    SDL_RENDER_DRIVER=software zig build -Dui=true run-ui --
    --scan-interaction-smoke` passed; the smoke draws, plans, saves/reloads a
    temp scanner config with the drawn selection, moves, resizes, and rejects a
    too-small selection. No Nix commands were run.

- [x] Make native Process export asynchronous and live-progress equivalent.
  - Review source: 2026-05-16 second browser-vs-native UI parity pass.
  - Python/browser oracle: `extract_ui.html` disables the export button, starts
    export, polls `/process/progress`, and updates status while the long export
    request is in flight; `v600/gui/process_handlers.py:handle_export` and
    progress reporting remain the behavior reference.
  - Required behavior: native Process export must not block the SDL/Nuklear event
    loop during long exports. It must surface `Starting export...`, per-frame or
    per-file progress, completion, and failure states while the UI continues to
    render; prevent duplicate concurrent export starts; preserve the existing
    export request shape, basename fallback, output toggles, Dmin behavior, and
    metadata parity; and keep destructive image navigation disabled or otherwise
    well-defined while an export is active.
  - Required tests/evidence: add a worker/event or equivalent headless path that
    proves `process_exporting` remains true across at least one UI frame before
    completion, progress events are visible in `processExportStatus`, duplicate
    starts are rejected or ignored consistently, and the final file list/message
    still matches the synchronous parity fixtures.
  - Completed 2026-05-16: added `src/ui/process_export_worker.zig` as the native
    Process export worker. The worker snapshots the active image, output
    directory, basename, full-resolution export rects, output toggles, active
    stock only when inverted output is requested, Dmin, rebate rectangle, DPI,
    and processing config overrides before spawning a background thread. The
    workflow now accepts an `ExportProgressSink` and emits the browser-shaped
    `Starting export...`, preparing, optional IR alignment, processing, per-file
    written, completion, and failure statuses into native state while the UI
    keeps rendering. Duplicate starts are ignored while an export is active, and
    native Process image refresh/navigation/trash/delete controls are inert while
    the worker owns the current image.
	  - Validation 2026-05-16: direct `zig build test --summary all` passed
	    `343/343`, including the worker headless test that holds
	    `process_exporting` true across a poll frame, observes
	    `processExportStatus`, rejects duplicate starts, then verifies final file
	    count/message and Dmin handoff. Direct `zig build -Dui=true --summary all`
	    passed. Direct
	    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
	    passed. Direct
	    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --process-export-smoke`
	    exited successfully. No Nix command was run.
  - Corrective checkpoint 2026-05-23: native Process export no longer trusts a
    successful worker result unless every reported output basename is visible on
    disk under the shared Gallery output directory. Export completion now refreshes
    the in-memory Gallery file list without clobbering the Process export footer
    message, and the native worker emits structured `v600.processing.event.v1`
    `export-start`, `export-progress`, `file-written`, `export-complete`, and
    `processing-error` diagnostics so scanner probe logs cannot be mistaken for
    export-write evidence. Headless tests now cover both the positive handoff
    path and the false-success guard where a reported output is missing on disk.
  - Validation 2026-05-23: direct `zig build test --summary all` passed
    `451/451`; direct `zig build -Dui=true --summary all` passed; direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true native-process-export-smoke --summary all`
    passed and logged processing export events plus a real `file-written` event.
    The smoke-generated `frames/ui-smoke_01_ir_004.tif` was removed after the
    check. No Nix command was run.

	- [x] Add native Process preview zoom and pan parity.
  - Review source: 2026-05-16 second browser-vs-native UI parity pass.
  - Python/browser oracle: `extract_ui.html` wheel zoom and middle-mouse pan over
    the processing canvas.
  - Required behavior: native Process preview must maintain an image transform
    comparable to the browser's `scale`, `offsetX`, and `offsetY`; wheel zoom
    should zoom around the pointer; middle-button drag should pan; selection
    hit-testing, drawing, moving, resizing, and rotation must operate in the
    transformed preview coordinate system; `+ New selection` should place the
    new frame at the center of the current viewport, not always the whole image;
    and switching images should reset or fit the transform like the browser.
  - Required tests/evidence: add headless transform tests for point conversion,
    wheel zoom anchoring, pan deltas, transformed selection hit-testing, and
    viewport-centered `+ New selection`. Extend the SDL dummy Process
    interaction smoke to zoom, pan, then edit a frame successfully.
  - Completed 2026-05-16: added `ProcessViewTransform` as a pure native UI state
    helper with browser-shaped `scale`, `offset_x`, `offset_y`, fit, zoom, pan,
    screen-to-preview conversion, image-key refit, and viewport-center helpers.
    Native Process rendering, selection hit testing, drawing, moving, resizing,
    rotation, and middle-button pan now all use the transformed preview rect.
    `+ New selection` now centers the frame on the current transformed viewport
    instead of always using the full preview center.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `344/344`, including transform unit coverage for fit math, zoom anchoring,
    pan deltas, viewport-center conversion, and image-key reset. Direct
    `zig build -Dui=true --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
    passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --process-interaction-smoke`
    exited successfully and now zooms, pans, edits a frame, and verifies
    viewport-centered add behavior. No Nix command was run.

- [x] Add direct native Process image selector parity.
  - Review source: 2026-05-16 second browser-vs-native UI parity pass.
  - Python/browser oracle: `extract_ui.html` `img-select`, refresh-on-focus, and
    `/process/switch` arbitrary-index behavior.
  - Required behavior: native Process must expose a direct selectable list or
    dropdown for all scan TIFFs, showing the same `index/count: filename`
    information as the browser, refreshing the image list before selection when
    appropriate, preserving previous/next wrap navigation, switching to an
    arbitrary selected index through the existing `switchProcessingImage` model
    path, and triggering the same one-shot auto-detect behavior as Prev/Next.
  - Required tests/evidence: add model/UI-adapter tests for arbitrary index
    switching, current index retention after refresh, out-of-range rejection,
    and pending auto-detect after direct selection. Add an SDL dummy smoke if the
    Nuklear selector can be driven reliably headlessly.
  - Completed 2026-05-16: added native Process direct image selection through
    `drawProcessImageSelector` and `State.switchProcessingImageAfterRefresh`.
    The selector renders every discovered scan TIFF as the browser-shaped
    `{index}/{count}: filename` text, treats the selected row as the active
    image, and routes arbitrary selection through the same
    `switchProcessingImage` load/cleanup path used by Prev/Next. The selector
    path snapshots the clicked item, refreshes the image list before switching,
    resolves the same path in the refreshed list, rejects out-of-range indexes,
    preserves current-index retention across refresh, and triggers the same
    one-shot pending auto-detect flag as image navigation. While adding this, a
    dangling `processing.input_path` bug after `rescanProcessingImages` was
    fixed by rebinding the active path to the refreshed owned path slice.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `345/345`, including the new direct selector test for arbitrary index
    switching, refreshed-list current retention, invalid-index rejection, active
    path rebinding, and pending auto-detect consumption. Direct
    `zig build -Dui=true --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
    passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --process-selector-smoke`
    exited successfully against seeded TIFF copies. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --process-interaction-smoke`
    exited successfully after the selector panel addition. No Nix command was
    run.

- [x] Match browser Process settings persistence boundaries.
  - Review source: 2026-05-16 second browser-vs-native UI parity pass.
  - Python/browser oracle: `extract_ui.html` updates slider display during
    `input` but persists on `change`, and color balance saves once on mouseup or
    double-click reset.
  - Required behavior: native Process controls should avoid writing
    `scratchndent_config.toml` on every drag frame or every repeated Nuklear
    property tick. Persist settings at browser-equivalent commit boundaries or
    through a small explicit debounce/dirty-commit mechanism that preserves
    effective UI behavior without unnecessary disk churn. Cache invalidation for
    stock/render/color changes must remain correct.
  - Required tests/evidence: add tests around a small settings-edit controller or
    equivalent helper showing transient edits update UI state, committed edits
    write once, repeated drag events do not cause redundant config writes, and
    stock selection still invalidates inverted preview and enables IR+inverted.
  - Completed 2026-05-16: added `ProcessSettingsDraft` as the native Process
    settings commit buffer. Render, color, and IR Nuklear property controls now
    update their visible UI values immediately but queue coalesced pending
    config overrides instead of writing `scratchndent_config.toml` on each
    drag/property tick. The pending batch commits when no mouse button is down,
    matching the browser's effective change/mouseup boundary closely enough for
    native immediate-mode controls. Color-pad dragging queues temp/tint as a
    pair, Reset Color writes one committed pair, and stock selection remains an
    immediate save because the browser stock dropdown posts immediately and also
    enables `export_ir_inv`.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `346/346`, including the new settings-draft coalescing test and the existing
    stock/settings invalidation coverage. Direct `zig build -Dui=true --summary
    all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
    passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --process-render-smoke`
    exited successfully. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --process-selector-smoke`
    exited successfully. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --process-interaction-smoke`
    exited successfully. No Nix command was run.
  - Follow-up completed 2026-05-17: included `preview_size`/Preview `Max px` in
    the same coalesced settings boundary. Repeated Nuklear property ticks update
    the in-memory preview-size value immediately but persist a single
    `preview_size` override when the settings draft commits, avoiding redundant
    TOML writes while preserving the operator-selected preview quality setting.

- [x] Preserve Scanner config partial-update persistence without requiring a
      selection.
  - Review source: 2026-05-16 second browser-vs-native UI parity pass.
  - Python/browser oracle: `/scan/config` accepts partial updates for DPI, mode,
    autoselect, exposure, and selection independently; `v600/config/settings.py`
    merges provided keys into `epdaughter_config.toml`.
  - Required behavior: native scanner config saving must persist DPI, mode,
    autoselect, and any future scan-control fields even when no preview
    selection exists. Selection keys should be written only when a valid
    selection exists, but lack of a selection must not suppress unrelated active
    settings. Ensure this does not regress saved-selection restore or
    mirror-back scan-start geometry.
  - Required tests/evidence: add config tests where mode/DPI/autoselect changes
    are saved with `selection == null`, selection fields remain absent or
    unchanged as intended, and later valid selection saves merge with those
    settings.
  - Completed 2026-05-16: changed `State.scannerConfigUpdates` so it always
    returns active `dpi`, `mode`, and `autoselect` updates, then conditionally
    includes `sel_x_in`, `sel_y_in`, `sel_w_in`, and `sel_h_in` only when the
    current selection and preview geometry can be converted to inches. This keeps
    the native main loop from dropping control changes before a preview
    selection exists, while preserving existing selection keys during unrelated
    partial saves. `saveScannerConfig` now always writes through the Python-shaped
    TOML merge path. The browser's attempted `exposure` value remains
    non-persistent because the frozen Python `v600/config/settings.py` schema
    ignores unknown keys.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `346/346`, including the updated native scanner config test covering
    no-selection mode/DPI/autoselect save, selection fields staying inactive in a
    new file, later valid-selection merge, and preservation of existing selection
    fields across a later unrelated partial save. Direct
    `zig build -Dui=true --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
    passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --scan-interaction-smoke`
    exited successfully. No Nix command was run.

- [x] Add native Scan and Process selection keyboard shortcut parity.
  - Review source: 2026-05-16 second browser-vs-native UI parity pass.
  - Python/browser oracle: `scan_ui.py` clears the scan selection on
    Escape/Delete, and `extract_ui.html` removes the active Process frame on
    Delete/Backspace when an input is not focused.
  - Required behavior: native Scan must clear the current scan selection through
    the matching keys without corrupting auto-selection restore state. Native
    Process must remove the active frame selection with Delete/Backspace while
    respecting focused text/property widgets and without triggering gallery or
    destructive image actions. Selection-list delete buttons remain available.
  - Required tests/evidence: add keyboard event tests or SDL dummy smoke coverage
    for Scan clear, Process active-frame deletion, ignored deletion while an
    edit field is active, and Gallery shortcut isolation.
  - Completed 2026-05-16: added native SDL key handlers for Scan and Process
    selection shortcuts. Scan `Escape` and `Delete` now clear only the current
    preview selection and leave `auto_selection` intact so Restore Auto still
    works. Process `Delete` and `Backspace` remove the active frame selection
    through the existing `removeProcessSelection` path, ignore events while
    Nuklear's text editor is active so export-basename and property edits keep
    their keys, and return early outside the Process view so Gallery shortcuts
    remain isolated. `Escape` is also forwarded to Nuklear text-edit reset mode.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `346/346`. Direct `zig build -Dui=true --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
    passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --scan-interaction-smoke`
    exited successfully with Escape/Delete selection-clear assertions. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --process-interaction-smoke`
    exited successfully with Backspace/Delete deletion, edit-active ignore, and
    Gallery-view isolation assertions. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --gallery-shortcut-smoke`
    exited successfully. No Nix command was run.

- [x] Make native image-event exclusion follow actual control-panel bounds.
  - Review source: 2026-05-16 second browser-vs-native UI parity pass.
  - Python/browser oracle: browser toolbar/sidebar controls consume pointer
    input according to their actual DOM layout; image interactions never depend
    on stale hard-coded panel coordinates.
  - Required behavior: native Gallery, Process, and Scan image interactions must
    ignore pointer input over the current Nuklear control panel even if the panel
    is moved, resized, or later made larger. Either keep the native panel fixed
    and non-movable or replace `pointInControlPanel` with dynamic bounds captured
    from the actual Nuklear window. The fix must not block valid image input
    outside the panel.
  - Required tests/evidence: add focused helper tests for the chosen bounds
    policy and an SDL dummy smoke that moves or simulates moved bounds when the
    panel remains movable, then verifies image interactions are excluded only in
    the current panel region.
  - Completed 2026-05-16: made the native Nuklear control panel fixed by removing
    `NK_WINDOW_MOVABLE` from its flags, routed the `nk_begin` rectangle and
    `pointInControlPanel` through the same `controlPanelRect` helper, and added
    a smoke-time `assertControlPanelPolicy` guard that fails if the panel becomes
    movable again or if the hit-test rectangle drifts from the draw rectangle.
    This follows the allowed fixed-panel policy and matches the browser's
    fixed-control layout closely enough for Scan, Process, and Gallery image
    interaction exclusion.
  - Follow-up completed 2026-05-17: wheel events now follow the same fixed-panel
    ownership rule. `feedNuklearInput` sends `nk_input_scroll` only when the
    SDL wheel event's mouse coordinates are inside `controlPanelRect`; wheel
    events over the image area remain available to Gallery/Process image zoom
    handlers without also scrolling the control panel. `assertControlPanelPolicy`
    now checks both inside-panel and outside-panel wheel routing.
  - Validation 2026-05-16: direct `zig build test --summary all` passed
    `346/346`. Direct `zig build -Dui=true --summary all` passed. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all`
    passed and executed the fixed-panel policy assertion. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --scan-interaction-smoke`
    exited successfully. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --process-interaction-smoke`
    exited successfully. Direct
    `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true run-ui -- --gallery-interaction-smoke`
    exited successfully. No Nix command was run.
  - Follow-up validation 2026-05-17: direct `zig build -Dui=true --summary all`
    passed. Direct dummy-SDL `ui-smoke` passed and executed the wheel-routing
    policy assertion. Direct dummy-SDL `run-ui -- --process-interaction-smoke`
    passed. Direct ReleaseFast dummy-SDL `ui-smoke` and `run-ui --
    --process-interaction-smoke` passed. No Nix command was run.
  - Follow-up completed 2026-05-17: image-event exclusion now treats the fixed
    footer status bar as UI chrome in addition to the control panel. Gallery,
    Process, and Scan image handlers ignore mouse button/wheel input over either
    chrome region, while `feedNuklearInput` still sends wheel scroll to Nuklear
    only when the pointer is over the control panel. The smoke-time policy
    assertion now also fails if the footer becomes movable, accepts input, or
    starts receiving control-panel wheel events.

- [x] Move native status and progress indicators into a footer status bar.
  - Product/UI goal: status, progress, and passive processing measurements
    should live in one predictable bottom bar instead of consuming control-panel
    rows in each tab body.
  - Required behavior: add a fixed non-interactive footer bar to the SDL/Nuklear
    chrome; keep the control panel constrained above it; remove duplicated
    status/progress rows from Scan, Process, and Gallery panels; keep the
    underlying state strings unchanged; show scanner percent, Process worker
    activity, export progress/file counts, preview image metadata, Dmin, gallery
    status, and ready/empty states from the same state helpers used before; and
    make image hit testing ignore the footer without routing footer wheel input
    to the scrollable control panel.
  - Completed 2026-05-17: `src/ui/main.zig` now maintains `footerBarRect`
    alongside `controlPanelRect`, draws `drawFooterStatusBar` after worker
    polling and before Nuklear rendering, formats per-view footer text through
    `scanFooterStatusText`, `processFooterStatusText`, and
    `galleryFooterStatusText`, removes the old Scan/Gallery/Process status rows,
    and replaces image event exclusion with `pointInUiChrome` so the footer is
    part of the non-image interaction surface. The UI smoke also asserts footer
    text policy for scanner percent, Process status/Dmin, and Gallery empty
    status so a rendered-but-empty footer fails headless verification.
  - Validation 2026-05-17: direct `zig build -Dui=true --summary all` passed.
    Direct `zig build test --summary all` passed `367/367`. Direct dummy-SDL
    `ui-smoke`, `run-ui -- --scan-interaction-smoke`, `run-ui --
    --process-interaction-smoke`, `run-ui -- --process-render-smoke`, `run-ui
    -- --gallery-render-smoke`, and `run-ui -- --gallery-interaction-smoke`
    passed. No Nix command was run.

- [x] Factor native Nuklear theming and UI scale into a configurable policy.
  - Product/UI goal: the native UI should no longer look like raw Nuklear
    defaults, and the operator must be able to increase control size for
    different monitors without editing layout code.
  - Required behavior: keep the visual policy outside the workflow/state model;
    provide named theme presets; expose a UI scale knob through environment and
    command-line configuration; scale font size, row heights, thumbnail rows,
    color-pad handle size, control padding, and initial window size together;
    and compute the fixed control-panel rectangle from the current window,
    active view, image-selector count, and selection count so Scan/Gallery can
    avoid scrollbars at normal sizes and Process only scrolls when content
    exceeds the parent window.
  - Completed 2026-05-17: added `src/ui/theme.zig` as a pure theme/metrics
    module with `darkroom`, `lighttable`, and `graphite` palettes, scale
    parsing/clamping, row metrics, and panel sizing helpers. `src/ui/main.zig`
    now imports that policy through `v600.native_ui_theme`, applies a Nuklear
    color table plus padding/rounding/scrollbar metrics, uses a larger default
    `1.15` UI scale, supports `V600_UI_THEME`, `V600_UI_SCALE`, `--ui-theme`,
    and `--ui-scale`, and derives `controlPanelRect` from the current SDL
    window and native model instead of fixed `520x360` constants.
  - Follow-up completed 2026-05-17: updated the Process interaction smoke to
    choose image gesture points outside the current dynamic control-panel bounds
    instead of relying on old hard-coded coordinates. This preserves the panel
    exclusion invariant as the panel grows.
  - Validation 2026-05-17: direct `zig build test --summary all` passed
    `367/367`, including pure theme parse/metric tests. Direct `zig build
    -Dui=true --summary all` passed. Direct dummy-SDL `ui-smoke`,
    `run-ui -- --scan-interaction-smoke`, `run-ui --
    --process-interaction-smoke`, and `run-ui -- --gallery-interaction-smoke`
    passed. Direct dummy-SDL `V600_UI_THEME=graphite V600_UI_SCALE=1.45 zig
    build -Dui=true run-ui -- --process-render-smoke` passed. No Nix command
    was run.

- [x] Preserve browser scanner startup/connection lifecycle in the native UI.
  - Review source: 2026-05-16 third browser-vs-native UI parity pass.
  - Python/browser oracle: `scan.py` starts the HTTP UI immediately and connects
    the scanner in the background; `scan_handlers.py` exposes
    `connecting`, `connected`, and `scanner_error`; `scan_ui.py` polls
    `/scan/status` and shows connecting/offline text until the backend is
    actually available.
  - Current native risk: `src/ui/main.zig` initializes the native model as
    connected with default capabilities before any scanner probe has succeeded.
    That masks slow startup and makes the UI claim `Ready` even when hardware is
    still being discovered or unavailable.
  - Required behavior: native startup must represent `connecting` until the
    scanner backend probe completes, then transition to connected/error through
    the existing scanner state contract. The UI should remain usable while the
    connection attempt is in flight, but Preview/Scan requests must return the
    browser-shaped connecting/offline status until connection succeeds.
  - Required tests/evidence: add a no-hardware fake connector/worker test for
    connecting-to-connected, connecting-to-error, and request rejection while
    connecting. Add a dummy-SDL smoke that starts with a delayed fake connector
    and verifies the initial status is not `Ready`.
  - Completed: added `src/ui/connect_worker.zig`, exported it through
    `src/root.zig`, and changed native startup to call `beginScannerConnect()`
    and probe in a background worker instead of pre-marking the scanner
    connected with default V600 dimensions. The worker transitions through
    `scannerConnected()` or `scannerFailed()`, the normal UI keeps running
    while probing, and smoke runs use a delayed fake connector so headless UI
    verification never touches scanner hardware. Preview button failures now
    preserve the browser-shaped connecting/offline status instead of replacing
    it with a generic area error.
  - Validation: direct `zig build test --summary all` passed `348/348`; direct
    `zig build -Dui=true --summary all` passed; direct dummy SDL
    `zig build -Dui=true ui-smoke --summary all` passed; direct dummy SDL
    `zig build -Dui=true native-scanner-connect-smoke --summary all` passed;
    direct dummy SDL `zig build -Dui=true run-ui -- --scanner-connect-smoke`
    passed; direct dummy SDL `run-ui -- --scan-interaction-smoke` and
    `run-ui -- --process-interaction-smoke` passed. No Nix command was run.

- [x] Render native Scan status from the scanner state without suppressing
      Python-shaped messages.
  - Review source: 2026-05-16 third browser-vs-native UI parity pass.
  - Python/browser oracle: `scan_ui.py` renders status text returned by
    `/scan/status`, including preview results, offline errors, scan pass strings,
    progress/ETA strings, cancellation, and saved-output messages from
    `scan_handlers.py`.
  - Current native risk: `statusLabelZ` returns `Preview ready` before checking
    active scanning, collapses most non-empty `model.status` values to `Ready`,
    and does not directly render `model.scanner.scan_status`. This can hide
    browser-parity messages that already exist in native state.
  - Required behavior: the Scan panel should display the active
    `scanner.scan_status`/progress text first, preserve preview-ready and
    cancel/error states in the same priority order the browser exposes, and never
    show stale `Preview ready` while a scan is actively running.
  - Required tests/evidence: add unit tests for status-label priority covering
    existing-preview-then-scan, connecting/offline, preview in progress, saved
    scan, scan error, and cancellation. Add a dummy-SDL status smoke if practical.
  - Completed: replaced the native Scan panel's `statusLabelZ` collapsing helper
    with `State.scanStatusDisplay()`, so Nuklear renders the active
    `scanner.scan_status` text directly and falls back to preview/scanning,
    model status, then `Ready`. The connector smoke now asserts this display
    value is not `Ready` during startup.
  - Validation: direct `zig build test --summary all` passed `349/349`; direct
    `zig build -Dui=true --summary all` passed; direct dummy SDL
    `zig build -Dui=true native-scanner-connect-smoke --summary all` passed;
    direct dummy SDL `zig build -Dui=true ui-smoke --summary all` passed; direct
    dummy SDL `zig build -Dui=true run-ui -- --scanner-connect-smoke` passed.
    No Nix command was run.

- [x] Prevent duplicate native Preview/Scan queueing while scanner work is
      active.
  - Review source: 2026-05-16 third browser-vs-native UI parity pass.
  - Python/browser oracle: `scan_ui.py:setButtonsEnabled(false)` disables Preview
    and Scan while a preview or scan request is active, showing Cancel for scan.
    The Python handler also owns the scanner behind `scanner_lock`.
  - Current native risk: the Preview button remains clickable while
    `model.scanner.scanning` is true, and `queuePreviewScan` does not reject
    active scanner work before replacing `pending_command` and resetting preview
    state.
  - Required behavior: native Preview, Scan Selection, and Cancel controls must
    follow the browser's busy-state semantics. Preview requests during any active
    preview/scan should be ignored with a useful status, scan-start should remain
    unavailable while work is active, and Cancel should target the active scan
    worker without corrupting pending preview commands.
  - Required tests/evidence: add state tests for preview-while-preview,
    preview-while-scan, scan-while-preview, scan-while-scan, and cancellation
    ownership. Add a dummy-SDL smoke that verifies busy controls do not enqueue a
    second command.
  - Completed: added `State.scannerWorkActive()` and a busy rejection path for
    preview and scan-start queueing. Busy rejection updates `model.status`
    without overwriting the active scanner progress/status text, preserving the
    in-flight command. The native Scan panel disables Preview while scanner work
    is active and shows Cancel instead of Scan Selection during active work.
  - Validation: direct `zig build test --summary all` passed `351/351`; direct
    `zig build -Dui=true --summary all` passed; direct dummy SDL
    `zig build -Dui=true ui-smoke --summary all` passed; direct dummy SDL
    `zig build -Dui=true run-ui -- --scan-interaction-smoke` passed; direct
    dummy SDL `zig build -Dui=true native-scanner-connect-smoke --summary all`
    passed. No Nix command was run.

- [x] Move Process image load, auto-detect, and rebate follow-up off the native
      UI thread.
  - Review source: 2026-05-16 third browser-vs-native UI parity pass.
  - Python/browser oracle: `extract_ui.html` uses asynchronous `fetch()` calls for
    `/process/switch`, `/process/auto-detect`, and `/process/rebate`, so the
    browser event loop remains responsive while TIFF loading, detector work, and
    Dmin computation run on the server side.
  - Current native risk: switching into Process, Refresh/Prev/Next/direct image
    selection, the pending one-shot auto-detect, Auto Detect, and Dmin all call
    TIFF loading/detection/Dmin functions synchronously from the SDL/Nuklear main
    loop. On real scans this can visibly freeze the native UI.
  - Required behavior: introduce Process load/detect/rebate worker boundaries
    equivalent to the existing export worker pattern. Workers must snapshot
    inputs, stream or publish status, reject duplicate incompatible starts,
    preserve current-image ownership, and apply results only if they still match
    the active image/generation.
  - Required tests/evidence: add headless fake-worker tests for image load,
    switch cancellation/stale-result rejection, auto-detect pending one-shot,
    rebate Dmin result application, and UI responsiveness across at least one
    frame while the worker is active. Keep algorithm parity tests unchanged.
  - Completed: added `src/ui/process_worker.zig` with load, auto-detect, and
    rebate operations that snapshot paths/config/preview data, run work on a
    thread, reject duplicate incompatible starts, and apply results only when
    the active image path and `processing_generation` still match. Native
    Process Refresh/Prev/Next/direct selector loads now start the load worker;
    pending one-shot auto-detect, Auto Detect, Dmin, and rebate finalization now
    start worker operations instead of running TIFF load, frame detection, or
    Dmin computation on the SDL/Nuklear path. The existing algorithm helpers and
    oracle tests remain unchanged.
  - Validation: direct `zig build test --summary all` passed `356/356`; direct
    `zig build -Dui=true --summary all` passed; direct dummy SDL
    `zig build -Dui=true native-process-worker-smoke --summary all` passed;
    direct dummy SDL `zig build -Dui=true ui-smoke --summary all` passed; direct
    dummy SDL `run-ui -- --process-render-smoke`,
    `run-ui -- --process-interaction-smoke`, and
    `run-ui -- --process-selector-smoke` passed. No Nix command was run.

  - Follow-up completed 2026-05-17: extended the same native UI responsiveness
    rule to inverted Process previews. Browser inversion runs through an async
    fetch/server route rather than the browser event loop; native now schedules
    inversion through `InvertedPreviewWorker`, copies render inputs before
    spawning, and keeps UI state management limited to request keys, completed
    texture upload, and stale-result rejection.
  - Follow-up completed 2026-05-17: added live worker diagnostics for Process
    image load, auto-detect, and rebate/Dmin work. Native now renders the active
    operation, basename, preview dimensions/options where applicable, and
    elapsed time while a worker is running; stderr logs record worker start,
    detector completion, suggested-rebate Dmin start, failure/apply-failure, and
    successful completion. This makes pegged-CPU/no-visible-work failures
    diagnosable without moving processing back onto the UI thread.

- [x] Add native Scan selection output estimate parity.
  - Review source: 2026-05-16 third browser-vs-native UI parity pass.
  - Python/browser oracle: `scan_ui.py:updateInfo` shows selected area in inches
    and millimeters, output pixel dimensions, mode, estimated data size, and
    estimated time using the browser's `5 MB/s + 8s per pass` formula.
  - Required behavior: native Scan should show an equivalent estimate whenever a
    valid selection exists and update it as selection, mode, or DPI changes. RGB,
    IR, and RGB+IR must use the same channel, bit-depth, IR-DPI, data-size, pass,
    and `fmtTime` logic as the browser.
  - Required tests/evidence: add pure helper tests for RGB, IR, and RGB+IR at
    6400 DPI, plus a dummy-SDL smoke or state assertion showing the estimate
    changes after a selection resize and DPI/mode change.
  - Completed 2026-05-17: added `ScanSelectionEstimate`,
    `scanSelectionEstimate`, and `formatScanSelectionEstimate` in
    `src/ui/scan_workflow.zig`, exported the helper through native UI state, and
    changed the native Scan panel to display the formatted estimate instead of
    collapsing valid selections to `Selection ready`. The port preserves the
    browser `updateInfo` order: rounded two-decimal inches feed output-pixel and
    IR-DPI calculations, RGB/RGB+IR/IR byte estimates use two bytes per sample,
    RGB+IR caps the IR estimate at 3200 DPI and counts two passes, and estimate
    time uses the browser `~Ns` / `~NmSSs` `fmtTime` shape.
  - Validation 2026-05-17: direct `zig build test --summary all` passed
    `359/359`, including pure RGB/RGB+IR/IR 6400-DPI estimate assertions, the
    UI-valid IR DPI snap assertion, and a native state assertion that the
    estimate changes after selection resize and DPI/mode changes. Direct
    `zig build -Dui=true --summary all` passed. Direct dummy-SDL
    `ui-smoke` passed. Direct dummy-SDL `run-ui -- --scan-interaction-smoke`
    passed. No Nix command was run.

- [x] Add native Process Dump selections diagnostic parity.
  - Review source: 2026-05-16 third browser-vs-native UI parity pass.
  - Python/browser oracle: `extract_ui.html` has a `Dump` button that posts
    selections and `preview_scale` to `/process/debug/selections`; the handler
    prints frame geometry for ground-truth/debug capture and reports a
    `Dumped N selections to server console` status.
  - Required behavior: native Process should expose an equivalent diagnostic
    command gated as a developer/debug action. It should print the same
    per-frame fields, include preview-scale context, and update the Process
    status without mutating selections.
  - Required tests/evidence: add formatting/helper tests for zero and multiple
    selections and an SDL dummy smoke or direct command smoke that verifies the
    status text and emitted diagnostic lines.
  - Completed 2026-05-17: added `writeProcessSelectionDump`,
    `dumpProcessSelectionsTo`, and `dumpProcessSelections` to native UI state,
    exposed a native Process `Dump` button beside Auto Detect/Clear/Dmin, and
    added `--process-dump-smoke` plus the `native-process-dump-smoke` build
    step. The diagnostic preserves the Python handler's header and per-frame
    `x`, `y`, `w`, `h`, and `angle` fields, includes the browser-posted
    `preview_scale` as context, does not mutate selections or active selection,
    and updates status to `Dumped N selections to server console`.
  - Validation 2026-05-17: direct `zig build test --summary all` passed
    `360/360`, including zero-selection and multi-selection diagnostic/status
    assertions. Direct `zig build -Dui=true --summary all` passed. Direct
    `zig build -Dui=true native-process-dump-smoke --summary all` passed.
    Direct dummy-SDL `ui-smoke` passed. Direct dummy-SDL
    `run-ui -- --process-interaction-smoke` passed. No Nix command was run.

- [x] Block stale native Process preview interactions while image loads are
  active.
  - Review source: 2026-05-17 fourth browser-vs-native UI parity pass.
  - Python/browser oracle: `extract_ui.html:switchImage` shows the full loading
    overlay before clearing selections and switching image metadata; the overlay
    remains until the new preview image load finishes, so the previous preview
    cannot be edited under the new `INPUT_PATH`.
  - Current native risk: `beginProcessingImageLoadRequest` clears selections and
    updates `processing.input_path`, but the old `processing_preview` remains
    renderable while the background load runs. Image navigation controls are
    disabled, but selection, rebate, auto-detect, and export controls can still
    act against the stale preview geometry.
  - Required behavior: either clear/suppress the old Process preview while the
    load worker is active or gate all preview-dependent Process interactions
    until the new preview has been committed. The chosen behavior must preserve
    browser loading/selection clearing semantics and avoid applying old-preview
    frame/rebate geometry to the newly selected TIFF.
  - Required tests/evidence: add a state or worker test proving stale preview
    geometry is not accepted during an in-flight load, plus a dummy-SDL Process
    interaction or selector smoke covering the loading gate.
  - Completed 2026-05-17: added `processPreviewInteractionReady` and wired the
    Process tab so active image loads suppress stale preview textures, end
    in-flight image/rebate interactions, and disable preview-dependent controls
    while the worker/loading state is active. Processing errors now clear the
    loading flag so failed loads do not leave the Process tab permanently
    locked.
  - Follow-up 2026-05-17: narrowed the native gate after operator testing showed
    non-image-load Process workers greyed out the whole tab. Native now uses the
    full control disable only for image loads, preserving the browser loading
    overlay behavior, while background Auto Detect or Dmin work only prevents
    duplicate Auto Detect/Dmin starts. Stock, render, selection-list, dump, and
    export controls no longer become inactive just because the Process worker is
    running.
  - Validation 2026-05-17: direct `zig build test --summary all` passed
    `360/360`, including a state assertion that a previous preview is not
    interaction-ready during an in-flight image load and becomes ready again
    after the new preview commits. Direct `zig build -Dui=true --summary all`
    passed. Direct dummy-SDL `native-process-worker-smoke`, `ui-smoke`, and
    `run-ui -- --process-interaction-smoke` passed. No Nix command was run.
  - Follow-up validation 2026-05-17: direct `zig build -Dui=true --summary all`
    passed. Direct dummy-SDL `ui-smoke`, `run-ui --
    --process-interaction-smoke`, and `native-process-worker-smoke` passed. No
    Nix command was run.

- [x] Match browser Process newly drawn small-frame rejection threshold.
  - Review source: 2026-05-17 fourth browser-vs-native UI parity pass.
  - Python/browser oracle: `extract_ui.html` removes a newly drawn frame
    selection when `s.w < 10 || s.h < 10` in preview coordinates.
  - Current native risk: `processDrawMinimumSize` derives a threshold from the
    preview dimensions, capped at 10 px, so small previews can accept selections
    the browser would remove.
  - Required behavior: native newly drawn frame selections must use the browser's
    fixed 10 px preview-coordinate threshold. Rebate threshold remains the
    separate browser `>5` px rule.
  - Required tests/evidence: add pure Process selection/finalization coverage
    for below-10 and exactly-10 frame selections and rerun the Process
    interaction smoke.
  - Completed 2026-05-17: replaced the scaled native draw threshold with the
    browser's fixed `10.0` preview-pixel frame rule, moved drawn-frame
    finalization into the native UI state boundary, and kept the rebate
    finalization threshold on its separate `>5` px browser rule.
  - Validation 2026-05-17: direct `zig build test --summary all` passed
    `361/361`, including below-10 rejection, exact-10 acceptance, status, and
    invalid-index finalization assertions. Direct UI build
    (`zig build -Dui=true --summary all`) passed. Direct dummy-SDL
    `run-ui -- --process-interaction-smoke` passed and now asserts that the tiny
    committed preview fixture rejects newly drawn frames under the browser rule.
    Direct dummy-SDL `ui-smoke` passed. No Nix command was run.

- [x] Hide or disable native Scan Restore Auto until an auto-detected selection
  exists.
  - Review source: 2026-05-17 fourth browser-vs-native UI parity pass.
  - Python/browser oracle: `scan_ui.py` initializes `#btn-restore-auto` with
    `display:none`, hides it before each Preview request, and only shows it
    after successful film-area auto-detection.
  - Current native risk: the `Restore Auto` button is always rendered and
    silently no-ops when no `auto_selection` exists.
  - Required behavior: native Scan should only expose or enable Restore Auto
    while an auto-detected selection is available, and new Preview requests
    should return it to the unavailable state until detection succeeds.
  - Required tests/evidence: add a UI/state assertion for initial hidden/disabled
    behavior, post-detection availability, and new-preview reset; rerun the
    Scan interaction smoke.
  - Completed 2026-05-17: added `scanRestoreAutoAvailable`, cleared
    `auto_selection` when a new Preview request starts, and changed the native
    Scan panel to render `Restore Auto` only when an auto-detected selection is
    currently available. The button is disabled during scanner work when it is
    present.
  - Validation 2026-05-17: direct `zig build test --summary all` passed
    `361/361`, including assertions for initial unavailable Restore Auto,
    successful auto-detect availability, and new-preview reset. Direct UI build
    (`zig build -Dui=true --summary all`) passed. Direct dummy-SDL
    `run-ui -- --scan-interaction-smoke` passed. Direct dummy-SDL `ui-smoke`
    passed. No Nix command was run.

### Phase 10: WebGPU Preparation

- [x] Add WebGPU dependency strategy through Nix.
  - Strategy is documented in `docs/PERFORMANCE_STRATEGY.md`. WebGPU stays
    optional and out of the default CPU parity shell until a CPU implementation
    of the same operation is accepted and fixture-covered. Future dependency
    wiring must use an unambiguous native WebGPU package, default
    `-Dwebgpu=false`, preserve CPU fallback, and stop for a human shell reload
    after any `flake.nix`/`shell.nix` edit.
  - Update 2026-05-17: use nixpkgs `wgpu-native` as the first concrete backend
    dependency. The pinned nixpkgs `dawn` package is unrelated to Google Dawn,
    and the Google Dawn source checkout visible to Nix at the attempted
    revision has no standalone `CMakeLists.txt`. Keep Google Dawn as a possible
    future backend behind the same internal Zig boundary.
  - Validation 2026-05-15: docs-only checkpoint. Updated the baseline benchmark
    command to direct ambient-shell Zig usage and did not run `nix develop`,
    `nix-shell`, `nix build`, or `nix flake check`.
- [x] Define CPU/GPU image buffer ownership boundaries.
  - Added `src/processing/gpu_boundary.zig` as a dependency-free contract for
    future WebGPU work. The boundary records explicit pixel formats,
    scanner/TIFF/preview/scene-linear/display/mask/UI/parity buffer roles,
    CPU/GPU memory domains, row-stride validation, transfer directions, and the
    requirement that GPU parity downloads materialize tightly packed CPU
    comparison buffers.
  - Documented the ownership rules in `docs/PERFORMANCE_STRATEGY.md` and added
    a rewrite-infrastructure manifest row in `docs/PARITY_MANIFEST.md`. No
    WebGPU dependency, shell change, or Nix command was introduced.
  - Validation 2026-05-15: direct `zig version` reported `0.16.0`; direct
    `zig fmt src/processing/gpu_boundary.zig src/processing.zig`; direct
    `zig build test --summary all` passed `302/302`; direct
    `zig build --summary all` passed; direct `zig build -Dui=true --summary all`
    passed. No `nix develop`, `nix-shell`, `nix build`, or `nix flake check`
    commands were run.
- [x] Identify color/render kernels suitable for GPU acceleration.
  - Documented the GPU kernel candidate inventory in
    `docs/PERFORMANCE_STRATEGY.md`, tied each candidate to its frozen Python
    contract and Zig CPU function, and ranked them by current measured payoff
    and GPU suitability. `render_to_display` is P0 but requires exact percentile
    handling; custom `invert_negative` and darktable `apply_sigmoid` are P1
    nonlinear kernels; transfer functions, matrix multiply, and film-stock
    density transforms are P2/fusion candidates; scanner startup, config, TIFF
    metadata, XMP parsing, filesystem/gallery work, and Nuklear layout are
    explicitly excluded.
  - Validation 2026-05-15: direct
    `zig build -Doptimize=ReleaseFast bench-color --summary all` passed and
    recorded current `ns_per_pixel_x1000` values: `srgb_to_linear=69258`,
    `color_matrix_rec2020=741`, `density_transform_kodak_gold=3129`,
    `darktable_sigmoid=177926`, `negadoctor=225250`,
    `render_to_display=7878360`. No Nix commands were run.
- [x] Add CPU fallback tests for every future GPU path.
  - Mirrored the documented GPU kernel inventory into
    `src/processing/gpu_boundary.zig` as `gpu_kernel_candidates`. The registry
    records priority, frozen Python contract, Zig CPU symbol, buffer roles, and
    input/output formats for each planned color/render GPU path.
  - Added the headless test
    `every future GPU kernel candidate requires CPU fallback and download
    comparison`, which rejects candidates with missing Python contracts, missing
    CPU symbols, missing CPU fallback, missing GPU download comparison, or
    inconsistent RGB channel geometry. This makes CPU fallback a checked rule
    before any WebGPU backend exists.
  - Validation 2026-05-15: direct
    `zig fmt src/processing/gpu_boundary.zig src/processing.zig`; direct
    `zig build test --summary all` passed `303/303`; direct
    `zig build --summary all` passed; direct `zig build -Dui=true --summary all`
    passed. No Nix commands were run.
- [x] Add benchmark gates for CPU parity before GPU backend work.
  - Added `bench-gpu-readiness` in `build.zig`. It runs the color benchmark
    executable with `--gpu-readiness-gate`, executes all active CPU paths from
    the GPU candidate registry, and fails if an active candidate is missing
    CPU benchmark coverage, CPU fallback, or GPU download comparison policy.
  - Extended `src/benchmarks/color_paths.zig` with a `linear_to_srgb` benchmark
    so all active P0/P1/P2 candidates are covered. Deferred candidates remain
    excluded until they are promoted.
  - Validation 2026-05-15: direct
    `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
    passed with `gpu_readiness_gate,active_candidates,7,benchmarked_candidates,7`
    and benchmark values `srgb_to_linear=70512`, `linear_to_srgb=67961`,
    `color_matrix_rec2020=726`, `density_transform_kodak_gold=3127`,
    `darktable_sigmoid=176554`, `negadoctor=232394`,
    `render_to_display=7971894`. Direct `zig build test --summary all` passed
    `303/303`; direct `zig build --summary all` passed; direct
    `zig build -Dui=true --summary all` passed. No Nix commands were run.
  - GPU work must execute the same Python-shaped processing operations already
    accepted on CPU. A GPU-only algorithm change is not parity evidence.

- [x] Add user-visible Process command performance benchmark and remove
      accidental quadratic numeric sorts.
  - User report: every Process command could peg CPU and appear hopelessly slow;
    auto-detect was only one symptom. The main code defect found in this pass
    was not a Python algorithm difference but the Zig port using insertion sort
    for image-sized percentile and median arrays. That made `render_to_display`,
    Dmin fallback/measurement, IR percentile work, and detector medians
    vulnerable to quadratic behavior on real images.
  - Completed 2026-05-17: replaced numeric `std.sort.insertion` calls with
    exact `std.sort.pdq` sorting in `src/processing/render.zig`,
    `src/processing/measurement.zig`, `src/processing/ir.zig`, and
    `src/processing/frames.zig`. This preserves Python's sorted-percentile and
    median semantics while removing the accidental O(n^2) implementation.
  - Added `src/benchmarks/processing_commands.zig` and the
    `bench-processing-commands` build step. The benchmark covers the
    user-visible Process command surface: synthetic display render, quick
    preview load, inverted preview render, frame auto-detect, rebate Dmin, one
    inverted export, and all export variants on the local
    `scans/scan_0006_rgbir_800dpi.tiff` fixture.
  - ReleaseFast benchmark evidence 2026-05-17:
    `zig build -Doptimize=ReleaseFast bench-color` reported
    `render_to_display=128035 ns_per_pixel_x1000`, down from the previous
    recorded `7971894`. `zig build -Doptimize=ReleaseFast
    bench-processing-commands` reported `render_synthetic=155.301 ms` for
    1,048,576 pixels, `load_preview=992.954 ms`,
    `inverted_preview=1309.567 ms`, `auto_detect=376.805 ms`,
    `rebate_dmin=147.102 ms`, `export_inv_only=323.828 ms`, and
    `export_all=2364.064 ms`.
  - Python upstream timing could not be refreshed in the current ambient shell:
    direct `python3` failed with `ModuleNotFoundError: No module named 'numpy'`.
    No Nix command was run. The next Python comparison must happen only in an
    already-loaded Python processing shell or after stopping for a human shell
    reload if dependencies change.
  - Validation 2026-05-17: direct `zig build test --summary all` passed
    `365/365`; direct ReleaseFast UI build
    (`zig build -Doptimize=ReleaseFast -Dui=true --summary all`) passed; direct
    dummy-SDL ReleaseFast `ui-smoke`,
    `native-process-worker-smoke`, `run-ui -- --process-render-smoke`, `run-ui
    -- --process-interaction-smoke`, and `run-ui -- --process-selector-smoke`
    passed. No Nix command was run.

### Phase 10A: WebGPU Bootstrap And First GPGPU Kernel

This phase turns the completed WebGPU preparation into a real optional backend.
It is intentionally split into small checkpoints so an agent can keep moving
without repeatedly rebuilding Nix or guessing at GPU parity. The CPU path
remains the production correctness path until a GPU kernel has a CPU fallback,
headless CPU-vs-GPU comparison, benchmark evidence, and an explicit integration
gate.

#### Phase 10A Operating Rules

- Do not run `nix develop`, `nix-shell`, `nix build`, `nix flake check`, or
  `nix search` from the agent loop.
- If a checkpoint requires a new WebGPU dependency, edit the Nix files and
  stop. Ask the human to reload the requested shell. Resume only after the
  human confirms the shell was reloaded.
- Default builds must stay CPU-only. `zig build`, `zig build test`, and
  `zig build -Dui=true` must not require WebGPU, a GPU, Vulkan, Metal, D3D12,
  or GPU runtime permissions.
- Every WebGPU build option must default off. Use an explicit build flag such
  as `-Dwebgpu=true` and, later, an explicit runtime flag or environment value
  before GPU execution is used by UI/export workflows.
- Do not claim performance progress from a GPU-only algorithm. The GPU path
  must implement the same Python-shaped operation already accepted on CPU, with
  an explicit CPU fallback and comparison against downloaded GPU output.
- WebGPU/WGSL generally means 32-bit float math. Before porting any current
  `f64` CPU path, add an explicit representation decision and fixture
  tolerance: either introduce a CPU `f32` staging/reference path that is
  compared to Python within documented tolerance, or choose a kernel whose
  existing parity contract already includes float32-like staging. Silent f64 to
  f32 downcasts are not acceptable.
- The first kernel should be small enough to debug. Prefer `apply_sigmoid` as
  the first real GPGPU kernel unless fresh benchmark and fixture evidence shows
  another per-pixel candidate is lower risk. Do not start with full
  `render_to_display`; its exact percentile behavior is a separate reduction
  problem.
- GPU work must not touch scanner startup, scanner command planning, TIFF
  metadata, config I/O, XMP parsing, filesystem gallery operations, or Nuklear
  layout.

- [x] Refresh the GPU readiness baseline and choose the first kernel.
  - Start by reading `docs/PERFORMANCE_STRATEGY.md`,
    `src/processing/gpu_boundary.zig`, `src/benchmarks/color_paths.zig`, and
    the CPU implementation for the candidate kernel.
  - Run only direct Zig commands from the ambient shell:
    - `zig build test --summary all`
    - `zig build -Dui=true --summary all`
    - `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
    - `zig build -Doptimize=ReleaseFast bench-processing-commands`
  - Record the current benchmark output under this item before editing GPU
    code.
  - Select exactly one first kernel and write the choice under this item with:
    Python source function, Zig CPU function, input/output buffer role,
    input/output scalar representation, expected tolerance, and why the kernel
    is a better first target than the alternatives.
  - Default decision if there is no contrary evidence: choose
    `apply_sigmoid` because it is per-channel, branch-light, already fixture
    covered, and avoids the percentile/reduction complexity of
    `render_to_display`.
  - Completion evidence: benchmark output recorded, first-kernel choice
    recorded, and no source changes beyond docs unless the selected checkpoint
    explicitly requires them.
  - Completed 2026-05-17: selected `apply_sigmoid` as the first GPGPU kernel.
    Python source contract:
    `scratchndent/processing/negative/color_transforms.py:96`
    `_sigmoid_kernel` and `:333` `apply_sigmoid`. Zig CPU contract:
    `src/processing/color.zig:196` `applySigmoid`. Buffer boundary:
    `.scene_linear` to `.scene_linear`, currently `rgb_f64` CPU buffers with
    deliberate `roundF32` input/output staging in the accepted CPU parity path.
    Expected first GPU tolerance should start from the committed Python oracle
    fixture `test/fixtures/processing/numeric/apply-darktable-sigmoid.json`
    tolerance, `abs=0.000002`, `rel=0.000002`, because the existing CPU path
    already mirrors Python's float32 output storage parity. Keep
    `sigmoidCommitParams` on CPU for the first shader unless a later fixture
    proves identical committed constants on GPU.
  - Rationale: `apply_sigmoid` is a hot scalar nonlinear path
    (`darktable_sigmoid=174651 ns_per_pixel_x1000` in this refresh), is
    per-channel and branch-light, has no inter-pixel dependency, is already
    covered by Python oracle fixtures, and avoids the exact percentile/reduction
    complexity that makes `render_to_display` a poor first shader despite its
    P0 priority. Corrected later: darktable `negadoctor` is a non-goal for GPU
    work because it is not the active UI/export inversion path; the second
    target is the custom `invert_negative` scene-linear stage.
  - Validation 2026-05-17: direct `zig build test --summary all` passed
    `367/367`; direct `zig build -Dui=true --summary all` passed; direct
    `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
    passed with:
    `srgb_to_linear=55614`, `linear_to_srgb=49605`,
    `color_matrix_rec2020=663`, `density_transform_kodak_gold=3114`,
    `darktable_sigmoid=174651`, `negadoctor=228136`,
    `render_to_display=188852`, and
    `gpu_readiness_gate,active_candidates,7,benchmarked_candidates,7`.
    Direct `zig build -Doptimize=ReleaseFast bench-processing-commands`
    passed with `render_synthetic=157085 us`, `load_preview=1027938 us`,
    `inverted_preview=1314158 us`, `auto_detect=416457 us`,
    `rebate_dmin=159662 us`, `export_inv_only=327803 us`, and
    `export_all=2474111 us` on `scans/scan_0006_rgbir_800dpi.tiff`.
    No Nix command was run.

- [x] Probe the ambient shell for an existing WebGPU package without Nix.
  - Run only non-Nix probes:
    - `pkg-config --list-all | rg -i 'dawn|webgpu|wgpu'`
    - if a candidate appears, `pkg-config --modversion <name>`
    - `pkg-config --cflags <name>`
    - `pkg-config --libs <name>`
  - If no candidate appears, record that the ambient shell lacks WebGPU and
    continue to the dependency-edit checkpoint.
  - If a candidate appears, verify it is a native WebGPU implementation usable
    from Zig, not the unrelated DAWN PostScript package or a browser-only shim.
    Evidence must include the pkg-config name if available, version, include
    path, library flags, and which header provides the C ABI expected by Zig.
  - Do not link Zig code in this checkpoint unless the package identity is
    unambiguous.
  - Completed 2026-05-17: direct
    `pkg-config --list-all | rg -i 'dawn|webgpu|wgpu'` exited with status `1`
    and no output, so the ambient shell does not expose a usable WebGPU
    pkg-config target. No `pkg-config --modversion`, `--cflags`, or `--libs`
    follow-up was possible because there was no candidate package name. Later
    Nix package queries confirmed nixpkgs provides `wgpu-native`; that package
    installs headers and `libwgpu_native` but does not expose a pkg-config file
    in its Nix expression. No Nix build or shell reload was run by the agent.

- [x] Add an optional nixpkgs `wgpu-native` dependency to Nix, then stop for
      shell reload.
  - Own files: `flake.nix` and `shell.nix`.
  - Use the pinned nixpkgs `wgpu-native` package rather than a local Google Dawn
    derivation. Nix package queries on 2026-05-17 showed:
    - `nixpkgs#wgpu-native.version` = `27.0.4.0`
    - `nixpkgs#wgpu-utils.version` = `29.0.1`
    - `nixpkgs#python3Packages.wgpu-py.version` = `0.31.0`
    - `nixpkgs#dawn.meta.description` = unrelated PostScript processor
  - Keep default package/check/dev shell paths CPU-only unless the human
    explicitly asks for WebGPU in the default shell. Prefer `devShells.webgpu`
    and the legacy `shell.nix` opt-in argument `withWebGPU`.
  - Because nixpkgs `wgpu-native` installs headers and `libwgpu_native` but no
    pkg-config target in its package expression, expose explicit environment
    variables for Zig build plumbing:
    - `WGPU_NATIVE_INCLUDE_DIR`
    - `WGPU_NATIVE_LIBRARY_DIR`
    - `LD_LIBRARY_PATH` including `wgpu-native` and platform GPU loader
  - Do not invent a local pkg-config shim unless later Zig build plumbing proves
    it materially simpler than using those explicit include/library variables.
  - Stop immediately after the Nix edit and ask the human to reload the
    requested shell. The handoff must state exactly which shell/output should
    be reloaded and which variables/files should exist afterward.
  - Completion evidence before checking off: after the human reloads the shell,
    direct probes succeed:
    - `test -r "$WGPU_NATIVE_INCLUDE_DIR/webgpu/wgpu.h"`
    - `test -r "$WGPU_NATIVE_INCLUDE_DIR/webgpu/webgpu.h"`
    - `test -e "$WGPU_NATIVE_LIBRARY_DIR/libwgpu_native.so"` on Linux, or the
      host platform's equivalent shared library extension
    - `zig version` still reports `0.16.0`
  - Progress 2026-05-17: replaced the local `nix/webgpu-dawn.nix` attempt with
    nixpkgs `wgpu-native`, exported `packages.webgpuNative`, kept
    `devShells.webgpu`, and kept legacy `shell.nix` `withWebGPU`. The prior
    local Google Dawn derivation is removed because the fetched tree had no
    standalone CMake project and nixpkgs `dawn` is not Google Dawn. Stop here;
    ask the human to reload `nix develop .#webgpu` or `nix-shell --arg
    withWebGPU true`, then run the direct probes above.
  - Completion evidence 2026-05-17: after the human confirmed the chat was
    reloaded inside the new `nix develop` shell, direct probes showed
    `WGPU_NATIVE_INCLUDE_DIR=/nix/store/hi09iq4mclwgrjpm8h1lsqzk5npnwab7-wgpu-native-27.0.4.0-dev/include`,
    `WGPU_NATIVE_LIBRARY_DIR=/nix/store/4zlzfq4h64367nndz89z4824z559zg7v-wgpu-native-27.0.4.0/lib`,
    readable `webgpu/wgpu.h`, readable `webgpu/webgpu.h`, present
    `libwgpu_native.so`, and `zig version` reported `0.16.0`.

- [x] Add `-Dwebgpu=true` build plumbing with CPU-only default behavior.
  - Own files: `build.zig`, `src/processing.zig`, and a minimal new module such
    as `src/processing/webgpu.zig` if needed.
  - Add a build option that defaults to false. When false, no WebGPU headers,
    libraries, imports, link flags, pkg-config lookup, GPU tests, or GPU runtime
    code may be required.
  - When true, use `WGPU_NATIVE_INCLUDE_DIR` and `WGPU_NATIVE_LIBRARY_DIR` from
    the WebGPU shell and link only the GPU executable/test steps that need
    `libwgpu_native`. Keep ordinary `zig build test` and
    `zig build -Dui=true` valid without `-Dwebgpu=true`.
  - Add a compile-time capability constant or small API that lets tests and
    processing code ask whether WebGPU support was compiled in without using
    stringly build-state checks.
  - Add direct validation commands:
    - `zig build test --summary all`
    - `zig build -Dui=true --summary all`
    - `zig build -Dwebgpu=true --summary all`
  - Do not add real GPU execution yet unless the next smoke checkpoint is also
    selected and the dependency has been verified in the ambient shell.
  - Completed 2026-05-17: added `-Dwebgpu=true` to `build.zig`, injected a
    generated `build_options` module, and added `src/processing/webgpu.zig` as
    a backend capability boundary with `compiled`, `Backend`, `Request`,
    `FallbackPolicy`, `requireCompiled`, `canUseWebGpu`, and `shouldUseCpu`.
    Default builds do not read WebGPU environment variables, add WebGPU include
    paths, link `libwgpu_native`, or require a GPU runtime. WebGPU-enabled
    builds read `WGPU_NATIVE_INCLUDE_DIR` and `WGPU_NATIVE_LIBRARY_DIR`, add the
    include/library/RPATH paths, and link `wgpu_native`.
  - Validation 2026-05-17: direct `zig build test --summary all` passed
    `371/371`; direct `zig build -Dui=true --summary all` passed; direct
    `zig build -Dwebgpu=true --summary all` passed; direct
    `zig build -Dwebgpu=true test --summary all` passed `371/371`, exercising
    the compile-time `compiled=true` capability branch; direct
    `zig build -Dui=true -Dwebgpu=true --summary all` passed. No `nix develop`,
    `nix-shell`, `nix build`, or `nix flake check` command was run.

- [x] Add a minimal WebGPU adapter-device smoke that is never part of the
      default build.
  - Own files: `src/processing/webgpu.zig`, `build.zig`, and any tiny C ABI
    wrapper needed to keep Zig 0.16 integration simple.
  - The smoke should initialize the native WebGPU instance, request an adapter,
    request a device, install uncaptured-error/device-lost callbacks if the C
    API requires them, then release all objects cleanly.
  - Add a build step such as `webgpu-smoke` that requires `-Dwebgpu=true`.
    It must not run as part of `zig build test`, `zig build`, `zig build
    -Dui=true`, or default flake checks.
  - If no adapter is available on the current host, the smoke may report a
    structured skip only when a documented environment value asks for
    no-hardware/no-adapter behavior. Otherwise it should fail clearly, because
    a GPU backend cannot be validated without an adapter.
  - Record the backend selected by `wgpu-native` when available, for example
    Vulkan on Linux, Metal on macOS, or D3D12 on Windows.
  - Validation commands:
    - `zig build -Dwebgpu=true --summary all`
    - `zig build -Dwebgpu=true webgpu-smoke --summary all`
    - `zig build test --summary all`
    - `zig build -Dui=true --summary all`
  - Completed 2026-05-17: added `src/processing/webgpu_native.zig` with the
    native WebGPU C import isolated behind the compile-time `webgpu` flag,
    added `src/tools/webgpu_smoke.zig`, and added a `webgpu-smoke` build step
    that fails clearly unless invoked with `-Dwebgpu=true`. The smoke creates a
    `wgpu-native` instance, requests an adapter, records adapter info, requests
    a device with device-lost and uncaptured-error callbacks installed, releases
    device/adapter/instance handles, and prints structured backend metadata.
    `V600_WEBGPU_SMOKE_ALLOW_NO_ADAPTER=1` is the explicit no-adapter skip gate;
    without it, no adapter is a failure.
  - Validation 2026-05-17: direct
    `zig build -Dwebgpu=true webgpu-smoke --summary all` passed and reported
    `webgpu_smoke,status,ok,backend,vulkan,adapter_type,discrete,adapter,590.48.01,vendor_id,4318,device_id,10114,version,452985856`.
    Direct `zig build -Dwebgpu=true --summary all` passed. Direct
    `zig build test --summary all` passed `372/372`. Direct
    `zig build -Dui=true --summary all` passed. No `nix develop`, `nix-shell`,
    `nix build`, or `nix flake check` command was run.

- [x] Extend the CPU/GPU boundary for the first kernel's real representation.
  - If the first kernel uses 32-bit float buffers, add `f32` to
    `ScalarType`, add the needed `PixelFormat` values such as `rgb_f32`, and
    update `CpuImageView`, `GpuImageDescriptor`, transfer-plan tests, and
    `gpu_kernel_candidates`.
  - Add explicit conversion helpers only where the first kernel needs them.
    The helper names must say what representation is being produced, for
    example `sceneLinearF64ToF32Staging`, not a vague `prepareGpuBuffer`.
  - Add tests for byte geometry, stride validation, tight download buffers,
    and conversion edge cases including NaN/Inf/clamp behavior if the CPU path
    can produce them.
  - Record the Python oracle tolerance and the CPU f64-to-GPU-representation
    tolerance under the selected kernel item. A broad visual smoke is not
    enough.
  - Validation commands:
    - `zig build test --summary all`
    - `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
  - Completed 2026-05-17: extended `src/processing/gpu_boundary.zig` with
    `ScalarType.f32`, `PixelFormat.gray_f32`, `PixelFormat.rgb_f32`, and f32
    byte/channel geometry. The selected first kernel, `apply_sigmoid`, now
    declares `.scene_linear` `rgb_f32` upload/download formats while preserving
    the CPU `f64` public path. Added explicit conversion helpers
    `sceneLinearF64ToF32Staging` and `sceneLinearF32DownloadToF64`.
  - Representation and tolerance: the Python oracle tolerance remains the
    committed `apply-darktable-sigmoid.json` tolerance,
    `abs=0.000002`, `rel=0.000002`. The CPU-to-WebGPU representation boundary
    is explicit f64-to-f32 staging with no hidden clamp. Tests preserve finite
    float32 rounding, signed zero, NaN, positive infinity, and negative
    infinity; invalid mismatched or non-RGB-multiple slices return
    `InvalidGpuStagingBuffer`.
  - Validation 2026-05-17: direct `zig build test --summary all` passed
    `373/373`. Direct
    `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
    passed with `gpu_readiness_gate,active_candidates,7,benchmarked_candidates,7`
    and benchmark values `srgb_to_linear=55350`, `linear_to_srgb=49293`,
    `color_matrix_rec2020=657`, `density_transform_kodak_gold=3102`,
    `darktable_sigmoid=173965`, `negadoctor=224777`, and
    `render_to_display=129849`. No Nix command was run.
  - Refreshed 2026-05-18 after adding custom `invert_negative` to the GPU
    candidate registry: direct
    `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
    passed with `gpu_readiness_gate,active_candidates,7,benchmarked_candidates,7`
    and benchmark values `srgb_to_linear=70282`, `linear_to_srgb=67782`,
    `color_matrix_rec2020=654`, `density_transform_kodak_gold=3119`,
    `invert_negative=37297`, `darktable_sigmoid=177594`,
    `negadoctor=227647`, and `render_to_display=129809`. No Nix command was
    run.
  - Release-audit refresh 2026-05-18 after the CPU SIMD inversion work:
    direct
    `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
    passed with `gpu_readiness_gate,active_candidates,7,benchmarked_candidates,7`
    and benchmark values `srgb_to_linear=56555`, `linear_to_srgb=50487`,
    `color_matrix_rec2020=722`, `density_transform_kodak_gold=3125`,
    `invert_negative_scalar=38942`, `invert_negative=18524`,
    `invert_negative_simd=18498`, `darktable_sigmoid=176263`,
    `negadoctor=225133`, and `render_to_display=128230`. No Nix command was
    run.

- [x] Add a backend-neutral first-kernel interface with scalar fallback.
  - Own the smallest CPU-call boundary for the selected kernel, not the whole
    processing pipeline.
  - Add a backend enum or options struct with at least `cpu` and `webgpu`
    choices. Default must be `cpu`.
  - The public processing function must keep its current CPU behavior unless
    the caller explicitly selects WebGPU and the binary was built with
    `-Dwebgpu=true`.
  - If WebGPU was requested but not compiled in, return a clear error or fall
    back only if the caller explicitly allowed fallback. Silent fallback is not
    acceptable in parity/performance benchmarks because it can fake a GPU pass.
  - Add unit tests for CPU default, explicit CPU, WebGPU-not-compiled behavior,
    and fallback policy.
  - Do not connect this interface to the native UI or export workflow yet.
  - Completed 2026-05-17: added `ApplySigmoidOptions` and
    `applySigmoidWithBackend` in `src/processing/color.zig`. The existing
    `applySigmoid` CPU implementation remains the parity source of truth.
    Default and explicit CPU requests call the scalar path. Explicit WebGPU
    requests return `WebGpuNotCompiled` in CPU-only builds, may use the scalar
    fallback only when `fallback = .allow_cpu`, and return
    `WebGpuKernelNotImplemented` in WebGPU builds until the WGSL kernel exists.
    This keeps benchmarks from accidentally counting silent CPU fallback as a
    GPU pass.
  - Validation 2026-05-17: direct `zig build test --summary all` passed
    `377/377`; direct `zig build -Dwebgpu=true test --summary all` passed
    `377/377`. No Nix command was run.

- [x] Implement the first WGSL compute shader and CPU-vs-GPU comparison harness.
  - Keep shader ownership obvious. Use a dedicated shader file or a clearly
    named embedded string; avoid burying WGSL in unrelated processing code.
  - The shader must operate only on the selected kernel's explicit staging
    buffers and parameters. Do not add a fused multi-kernel pipeline in the
    first pass.
  - Dispatch geometry must cover exact image lengths and handle non-multiple
    workgroup tails without reading or writing out of bounds.
  - Download GPU output into a tightly packed CPU buffer through the
    `TransferPlan.download` policy.
  - Compare GPU output to the accepted CPU reference over committed fixtures.
    Record max absolute error, RMS error, and tolerance. If tolerance needs to
    differ from existing Python fixtures because WGSL uses f32, document why the
    difference is representational and not algorithmic.
  - Add a GPU comparison build step or test that only runs with
    `-Dwebgpu=true` and an explicit GPU validation command.
  - Required validation:
    - `zig build test --summary all`
    - `zig build -Dui=true --summary all`
    - `zig build -Dwebgpu=true --summary all`
    - `zig build -Dwebgpu=true webgpu-smoke --summary all`
    - `zig build -Dwebgpu=true <first-kernel-gpu-compare-step> --summary all`
  - Completed 2026-05-17: added the dedicated shader file
    `src/processing/shaders/apply_sigmoid.wgsl`, native `wgpu-native`
    dispatch/download code in `src/processing/webgpu_native.zig`, the public
    gated `webgpu.applySigmoidKernel` entrypoint, and the
    `webgpu-sigmoid-compare` build step. The shader operates on the explicit
    `.scene_linear` `rgb_f32` staging buffers selected in the CPU/GPU boundary
    item, uses CPU-committed sigmoid constants, guards non-multiple workgroup
    tails with `index >= count`, and downloads through the tight
    `TransferPlan.download` `rgb_f32` parity buffer before converting back to
    `rgb_f64` for comparison.
  - Comparison evidence 2026-05-17: direct
    `zig build -Dwebgpu=true webgpu-sigmoid-compare --summary all` passed
    against `test/fixtures/processing/numeric/apply-darktable-sigmoid.json`
    with `count=18`, `max_abs=0.000000477`, `max_index=10`,
    `rms=0.000000184`, `tolerance_abs=0.000002000`, and
    `tolerance_rel=0.000002000`. No broader tolerance was needed; the
    observed difference is within the existing Python oracle tolerance.
  - Validation 2026-05-17: direct `zig build test --summary all` passed
    `378/378`; direct `zig build -Dui=true --summary all` passed; direct
    `zig build -Dwebgpu=true --summary all` passed; direct
    `zig build -Dwebgpu=true test --summary all` passed `378/378`; direct
    `zig build -Dwebgpu=true webgpu-smoke --summary all` passed on Vulkan
    discrete adapter `590.48.01`. No Nix command was run.

- [x] Benchmark the first GPU kernel against CPU at realistic sizes.
  - Add or extend a ReleaseFast benchmark that measures:
    - CPU reference kernel only.
    - GPU upload plus dispatch plus download.
    - GPU dispatch on already-resident buffers if the backend supports it.
    - End-to-end cost at preview-sized and export-frame-sized dimensions.
  - The benchmark must print enough metadata to interpret the result: image
    dimensions, bytes uploaded, bytes downloaded, selected adapter/backend,
    iterations, CPU time, GPU end-to-end time, GPU resident-dispatch time, and
    speedup or slowdown.
  - Do not integrate the GPU path into UI/export unless end-to-end GPU time is
    faster for a documented size threshold or there is a clear follow-up plan
    to amortize transfers by fusing kernels.
  - Record results under this item and update `docs/PERFORMANCE_STRATEGY.md`.
  - Validation command:
    - `zig build -Dwebgpu=true -Doptimize=ReleaseFast <first-kernel-gpu-bench-step> --summary all`
  - Completed 2026-05-17: added `src/benchmarks/webgpu_sigmoid.zig` and the
    `bench-webgpu-sigmoid` build step. The benchmark creates deterministic
    scene-linear `rgb_f64` input, measures the existing CPU `applySigmoid`
    reference, measures WebGPU upload + dispatch + readback, and separately
    measures resident-buffer dispatch after upload. The first benchmark attempt
    exposed WebGPU's 65,535-workgroup per-dimension limit; the shader and
    dispatch planner now use 2D workgroup geometry with a uniform
    `dispatch_width`, so export-sized buffers are covered without reading or
    writing past `count`.
  - Results 2026-05-17 on `wgpu-native` Vulkan adapter `590.48.01`:
    - `preview_1024x768`: `786432` pixels, `2359296` samples,
      `9437216` bytes uploaded per end-to-end iteration, `9437184` bytes
      downloaded, CPU `2` iterations in `260132211 ns`, GPU end-to-end `3`
      iterations in `4690388 ns`, resident dispatch `20` iterations in
      `2513597 ns`, `e2e_speedup_x1000=83191`,
      `resident_speedup_x1000=1034907`.
    - `export_frame_2048x3072`: `6291456` pixels, `18874368` samples,
      `75497504` bytes uploaded, `75497472` bytes downloaded, CPU `1`
      iteration in `1060823646 ns`, GPU end-to-end `1` iteration in
      `13297413 ns`, resident dispatch `10` iterations in `6715031 ns`,
      `e2e_speedup_x1000=79776`, `resident_speedup_x1000=1579774`.
  - Validation 2026-05-17: direct
    `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-webgpu-sigmoid --summary all`
    passed; direct `zig build -Dwebgpu=true webgpu-sigmoid-compare --summary all`
    still passed with `max_abs=0.000000477`, `rms=0.000000184`; direct
    `zig build test --summary all` passed `378/378`; direct
    `zig build -Dwebgpu=true test --summary all` passed `378/378`; direct
    `zig build -Dwebgpu=true --summary all` passed; direct
    `zig build -Dui=true --summary all` passed. No Nix command was run.

- [x] Integrate the first GPU kernel behind an explicit non-default runtime
      switch.
  - Wire the backend only into the narrow workflow that uses the selected
    kernel. Do not turn on GPU globally.
  - Add an explicit opt-in, for example a CLI flag or `V600_PROCESSING_GPU=1`.
    The default runtime behavior remains CPU.
  - If the GPU backend fails after opt-in, surface a diagnostic with the native
    WebGPU backend, adapter name if available, operation name, and fallback
    policy.
  - Add tests proving default CPU behavior is unchanged and opt-in requests use
    the GPU backend only when compiled with `-Dwebgpu=true`.
  - Add one UI/export smoke only after the backend-neutral comparison and
    benchmark checkpoints are complete.
  - Update `docs/PERFORMANCE_STRATEGY.md`, `docs/PARITY_MANIFEST.md`, and this
    plan with evidence. Do not mark this item complete based on a shader smoke
    alone.
  - Completed 2026-05-18: changed `applySigmoidWithBackend` so explicit
    WebGPU requests call `webgpu.applySigmoidKernel` and copy the downloaded
    result into the caller's output buffer. The original `applySigmoid` scalar
    function remains unchanged and remains the default path. Added
    `applySigmoidRequestFromEnvironment`, where missing, empty, or `0`
    `V600_PROCESSING_GPU` selects CPU; `1` or `webgpu` selects WebGPU with
    fail-fast fallback; and `allow-cpu`/`webgpu-allow-cpu` selects explicit
    CPU fallback only when WebGPU is unavailable.
  - Added `webgpu-sigmoid-runtime-smoke`, which runs the same
    `apply-darktable-sigmoid.json` fixture twice in a WebGPU build: once with
    no runtime env var and once with `V600_PROCESSING_GPU=1`. The explicit GPU
    run performs an adapter/device preflight so failure diagnostics include the
    operation, `wgpu-native`, fallback policy, and adapter information when
    available. Successful runtime output on 2026-05-18 showed default CPU
    `max_abs=0.000000000`, explicit WebGPU `max_abs=0.000000477`,
    `rms=0.000000184`, and adapter `590.48.01` on Vulkan.
  - Added `native-process-export-smoke` as the post-comparison UI/export smoke.
    This validates that the native Process export flow still starts from the UI
    while the new GPU backend remains opt-in and disconnected from default
    UI/export behavior.
  - Validation 2026-05-18: direct `zig build test --summary all` passed
    `379/379`; direct `zig build -Dwebgpu=true test --summary all` passed
    `380/380`; direct `zig build -Dwebgpu=true webgpu-sigmoid-runtime-smoke --summary all`
    passed; direct `zig build -Dwebgpu=true webgpu-sigmoid-compare --summary all`
    passed with `max_abs=0.000000477`; direct
    `zig build -Dwebgpu=true --summary all` passed; direct
    `zig build -Dui=true native-process-export-smoke --summary all` passed;
    direct `zig build -Dui=true --summary all` passed. No Nix command was run.

- [x] Decide the second GPU kernel only after first-kernel evidence is recorded.
  - Use the benchmark results to decide whether to:
    - fuse `apply_sigmoid` with the custom inversion or color-matrix work,
    - target custom `invert_negative` as the next standalone per-pixel kernel,
    - target transfer functions only as part of a fused pipeline,
    - or postpone more GPU work until CPU/UI parity gaps are smaller.
  - Do not start `render_to_display` GPU reduction work until there is a written
    plan for exact percentile parity or a user-approved post-parity approximate
    percentile mode.
  - Record the decision, next kernel, expected buffer residency strategy, and
    required fixtures before adding more shader code.
  - Corrected 2026-05-18 decision: target the custom `invert_negative`
    scene-linear stage, not darktable `negadoctor`. Rationale: the active
    native UI/export path uses the custom density-domain pipeline
    `normalize_transmittance -> transmittance_to_density -> subtract_dmin ->
    apply_density_transform -> non-negative clamp`. `negadoctor` is retained
    for darktable/XMP parity but is not the production inversion path.
  - Buffer residency strategy: keep the initial `invert_negative` comparison as
    a standalone upload-dispatch-download pass using explicit staging buffers.
    Do not fuse it with `apply_sigmoid`, render, TIFF loading, or Dmin
    estimation until the standalone CPU-vs-GPU error and benchmark are
    recorded. The follow-up residency goal is raw/TIFF `rgb_f32` input on GPU,
    `scene_linear` `rgb_f32` output kept resident for later render work, and a
    tightly packed CPU download only for parity comparison.
  - Required fixtures before shader acceptance: reuse the committed
    `test/fixtures/processing/numeric/invert-negative-identity-dmin.json` and
    `test/fixtures/processing/numeric/invert-negative-kodak-gold-dmin.json`
    fixtures; add an edge-case fixture before integration that covers low/zero
    raw samples, Dmin clamp behavior, all 10 polynomial basis terms,
    cross-channel terms, and non-negative output clamp. Compare against the
    existing CPU implementation and document any f32 WGSL tolerance separately
    from algorithmic differences.
  - Deferred: do not start `render_to_display` GPU reduction work yet. It is
    likely the best user-visible target, but exact percentile parity is the
    hard part and needs a separate written reduction/selection plan before any
    shader implementation. Do not use an approximate percentile mode unless
    the user explicitly approves it as a post-parity divergence.

### Phase 10B: Custom Inversion WebGPU Kernel

This phase starts only because Phase 10A recorded first-kernel comparison and
benchmark evidence and selected the active custom inversion path as the next
GPU target. It must preserve the frozen Python
`scratchndent.processing.negative.inversion.invert_negative` algorithm and the
Zig CPU `src/processing/inversion.zig` oracle. Do not fuse with
`apply_sigmoid`, render, TIFF loading, or Dmin estimation until the standalone
shader has fixture comparison and benchmark evidence.

Non-goal: darktable `negadoctor` is not a GPU acceleration target. It remains
ported only for darktable/XMP compatibility and oracle coverage; autonomous
work must not select it as a WebGPU kernel.

- [x] Add custom inversion GPU edge-case fixture and CPU oracle coverage.
  - Add a Python-generated fixture for `invert_negative` with provided Dmin and
    custom coefficients. It must cover low/zero raw samples, transmittance EPS
    clamping, Dmin subtraction clamp, all 10 polynomial basis terms,
    cross-channel terms, and non-negative output clamp.
  - Make the fixture carry the Dmin and coefficients needed by the comparison
    harness so GPU work cannot silently depend on built-in stock defaults.
  - Update the parity manifest and performance strategy with the fixture
    purpose.
  - Completed 2026-05-18: added
    `test/fixtures/processing/numeric/invert-negative-custom-edge-dmin.json`,
    generated from Python `invert_negative` with uint16 input semantics,
    provided Dmin, and custom coefficients. Added a Zig CPU oracle test in
    `src/processing/inversion.zig` that reads fixture-local Dmin and coeffs and
    verifies output against Python.

- [x] Implement custom inversion WGSL shader and CPU-vs-GPU comparison harness.
  - Add an explicit `InvertNegativeKernelParams` WebGPU ABI. The ABI must
    include Dmin, default light, optional dark/light handling policy for this
    checkpoint, and the 10x3 stock coefficient matrix.
  - Stage scanner/TIFF `rgb_f64` input as explicit `rgb_f32` samples, run the
    same normalize-transmittance, density, Dmin subtraction, 10-term polynomial
    transform, and non-negative clamp sequence as the CPU oracle, then download
    tightly packed `rgb_f32` output and convert to `rgb_f64` for comparison.
  - Add a `webgpu-invert-negative-compare` build step gated by `-Dwebgpu=true`.
    It must compare the identity-Dmin, Kodak-Gold-Dmin, and edge fixtures
    against CPU output and record max absolute error and RMS.
  - Do not integrate the shader into UI/export yet.
  - Completed 2026-05-18: added
    `src/processing/shaders/invert_negative.wgsl`,
    `webgpu.InvertNegativeKernelParams`,
    `webgpu.applyInvertNegativeKernel`, native `wgpu-native` dispatch/readback,
    and `src/tools/webgpu_invert_negative_compare.zig`. The comparison first
    checks Zig CPU output against the Python fixture, then compares downloaded
    GPU output to the Zig CPU oracle. Validation:
    `zig build -Dwebgpu=true webgpu-invert-negative-compare --summary all`
    passed with identity `max_abs=0.000000109`, Kodak Gold
    `max_abs=0.000000190`, and custom edge `max_abs=0.000000874`.

- [x] Benchmark custom inversion WebGPU against CPU at realistic sizes.
  - Add `bench-webgpu-invert-negative` with preview-sized and export-frame-sized
    deterministic RGB16-like inputs.
  - Report CPU time, GPU upload-dispatch-download time, resident dispatch time,
    transfer sizes, adapter/backend, speedup, and a checksum.
  - Record benchmark evidence in this plan and
    `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-18: added
    `src/benchmarks/webgpu_invert_negative.zig` and
    `bench-webgpu-invert-negative`. ReleaseFast results on `wgpu-native` Vulkan
    adapter `590.48.01`:
    - Release-audit refresh after chunking:
      `preview_1024x768`: CPU `1` iteration in `49391124 ns`, GPU
      end-to-end `3` iterations in `4837440 ns`, resident dispatch `20`
      iterations in `2632473 ns`, `e2e_speedup_x1000=30630`,
      `resident_speedup_x1000=375246`.
    - Release-audit refresh after chunking:
      `export_frame_2048x3072`: CPU `1` iteration in `374313447 ns`, GPU
      end-to-end `1` iteration in `13765099 ns`, resident dispatch `10`
      iterations in `8738861 ns`, `e2e_speedup_x1000=27192`,
      `resident_speedup_x1000=428332`.
    - Validation command:
      `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-webgpu-invert-negative --summary all`.

- [x] Integrate custom inversion behind an explicit non-default runtime switch.
  - Keep default UI/export behavior CPU.
  - Reuse the explicit processing GPU runtime policy; silent fallback remains
    forbidden for benchmark evidence.
  - Add a runtime smoke proving default CPU behavior and explicit WebGPU
    behavior against the custom inversion fixtures.
  - Completed 2026-05-18: added shared `webgpu.requestFromEnvironment` for
    `V600_PROCESSING_GPU`, added `InvertOptions.request`, and routed explicit
    WebGPU requests through `webgpu.applyInvertNegativeKernel`. Unsupported
    dark/light flat-field options stay CPU with explicit `allow_cpu` fallback
    and fail fast otherwise. The processing CLI export path parses the ambient
    environment once and passes the request through workflow/export to
    `invertNegative`; native UI callers remain CPU until a UI setting is
    intentionally wired.
  - Added `webgpu-invert-negative-runtime-smoke`, which runs the Kodak Gold
    Dmin fixture once with default CPU behavior and once with
    `V600_PROCESSING_GPU=1`. Validation:
    `zig build -Dwebgpu=true webgpu-invert-negative-runtime-smoke --summary all`
    passed with default CPU `max_abs=0.000000132`, `rms=0.000000046`; explicit
    WebGPU `max_abs=0.000000322`, `rms=0.000000113`; and adapter preflight on
    Vulkan adapter `590.48.01`.

- [x] Decide the next GPU residency/fusion checkpoint.
  - Use custom inversion evidence to decide whether to keep building standalone
    kernels, fuse inversion with render setup or `apply_sigmoid`, or stop GPU
    work until more CPU/UI parity gaps are closed.
  - Do not start `render_to_display` percentile/reduction work without an exact
    parity plan or explicit user-approved post-parity divergence.
  - Completed 2026-05-18: do not fuse kernels yet. The standalone
    `invert_negative` kernel is already much faster than the Zig CPU path, but
    end-to-end user-visible benefit still depends on transfer cost, render
    percentile work, TIFF/crop cost, and native UI worker scheduling. The next
    checkpoint is end-to-end opt-in measurement through the real processing
    workflow/CLI export path with `V600_PROCESSING_GPU=1`, followed by a written
    exact-percentile plan before any `render_to_display` WebGPU reduction work.
    Keep `apply_sigmoid` separate for now because it is not on the active
    custom inversion export path.

### Phase 10C: End-To-End GPU Inversion Adoption

This phase measures whether the now-working custom inversion GPU kernel
improves real user workflows before adding more shaders or fusing kernels.

- [x] Add end-to-end processing benchmarks for CPU vs explicit GPU inversion.
  - Extend or add a benchmark that runs the same processing workflow/export path
    with default CPU inversion and an explicit WebGPU inversion request. The
    CLI/export runtime path still reaches that same request through
    `V600_PROCESSING_GPU=1`.
  - Include preview-sized and real/export-sized cases when fixtures are
    available.
  - Report total wall time, inversion time if separately observable, transfer
    sizes, files written or preview bytes produced, and CPU/GPU speedup.
  - Compare output pixels/metadata against the CPU path or existing Python
    fixtures; do not accept speedup without parity evidence.
  - Completed 2026-05-18 with direct Zig commands only. The benchmark now has
    paired `inverted_preview_cpu_vs_gpu` and `export_inv_only_cpu_vs_gpu`
    cases in `src/benchmarks/processing_commands.zig`. Both compare explicit
    WebGPU inversion against the Zig CPU path while Python remains the frozen
    fixture oracle for CPU behavior.
  - The benchmark reports cold and warm GPU wall time separately because the
    production WebGPU path now caches the invert-negative device/queue/pipeline
    per process. Cold numbers include first-use setup; warm numbers represent
    repeated Process work after the cache is live.
  - Validation:
    - `zig build bench-processing-commands --summary all -- --case inverted_preview_cpu_vs_gpu`
      in a non-WebGPU build skipped cleanly with `skipped_webgpu_not_compiled`.
    - `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-processing-commands --summary all -- --case inverted_preview_cpu_vs_gpu`
      on `scans/scan_0006_rgbir_800dpi.tiff` reported
      `cpu_us=1313962`, `gpu_cold_us=1275732`, `gpu_warm_us=1099184`,
      `cold_speedup_x1000=1029`, `warm_speedup_x1000=1195`,
      `max_abs=1`, `rms=0.002`, and `mismatches=137`.
    - `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-processing-commands --summary all -- --case export_inv_only_cpu_vs_gpu`
      on the representative scan-0006 crop reported `cpu_us=354957`,
      `gpu_cold_us=480207`, `gpu_warm_us=267855`,
      `cold_speedup_x1000=739`, `warm_speedup_x1000=1325`,
      `max_abs=1`, `rms=0.052`, `mismatches=7216`,
      `metadata_equal=true`, `file_name_equal=true`, and `files=1`.
  - Performance interpretation: preview and export are now faster after the
    WebGPU runtime is warm, but the first export remains slower because it pays
    adapter/device/pipeline setup. UI adoption must therefore decide whether an
    explicit GPU opt-in should prewarm the cache or surface first-use latency.

- [x] Decide native UI opt-in control for GPU inversion.
  - Keep default CPU behavior.
  - Decide whether the native UI should expose a processing GPU toggle, read the
    environment once at startup, or stay CLI-only until render GPU work exists.
  - Include the cache lifecycle in the decision. Warm GPU inversion is faster
    in the current benchmark, but cold single-frame export is slower; an
    explicit UI opt-in may need prewarm diagnostics before it feels faster.
  - If a UI setting is added, persist it through config only after documenting
    the behavior and adding headless state tests.
  - Completed 2026-05-18: native UI now reads `V600_PROCESSING_GPU` once at
    startup through the same `invertNegativeRequestFromEnvironment` parser used
    by the CLI. Missing, empty, or `0` keeps CPU default. `1`/`webgpu` requests
    WebGPU fail-fast. `allow-cpu`/`webgpu-allow-cpu` requests WebGPU with the
    already-defined explicit CPU fallback policy.
  - Decision: do not add a visible persisted toggle yet. The current
    end-to-end benchmark shows warm WebGPU inversion is faster, but cold
    single-frame export is still slower. Persisting a UI preference before
    prewarm/status diagnostics would make first-use latency look like a broken
    setting. The native UI therefore has an operator/debug opt-in through the
    environment only, with CPU as the stable default.
  - Implementation notes:
    - `State.processing_gpu_request` owns the native UI runtime request.
    - `processingInvertedPreviewOptions` passes the request to async inverted
      preview rendering, and request changes invalidate the inverted-preview
      cache.
    - `ProcessExportWorker.Context` and direct `State.runProcessExport` pass
      the request into `ExportWorkflowOptions.invert_request`.
    - No `scratchndent_config.toml` key was added and no persisted setting was
      introduced.
  - Validation:
    - Refreshed after CPU SIMD inversion work: `zig build test --summary all`
      passed `391/391`, including headless state tests for preview option
      propagation and export-worker context propagation.
    - `zig build -Dui=true ui-smoke --summary all` passed.
    - `zig build -Dui=true -Dwebgpu=true ui-smoke --summary all` passed.
    - `V600_PROCESSING_GPU=allow-cpu zig build -Dui=true ui-smoke --summary all`
      passed, proving the non-WebGPU UI build can parse the explicit fallback
      request.
    - `V600_PROCESSING_GPU=1 zig build -Dui=true -Dwebgpu=true ui-smoke --summary all`
      passed, proving the WebGPU-enabled native UI startup accepts the explicit
      GPU request.

- [x] Write exact `render_to_display` percentile GPU plan.
  - Preserve Python/Zig percentile semantics exactly unless the user explicitly
    approves a post-parity approximate mode.
  - Decide CPU percentile plus GPU render, GPU reduction/selection, or a hybrid
    approach before any WGSL render shader is written.
  - Completed 2026-05-18: chosen plan is a hybrid exact-parity path:
    keep robust luminance percentile selection on CPU, then optionally run only
    the per-sample display transform on WebGPU. This preserves the frozen
    Python/Zig percentile contract while still moving the parallel color
    balance, exposure, S-curve, clamp, and uint16 write stage to the GPU.
  - Non-negotiable percentile invariants:
    - Luminance is computed in current Python/Zig order:
      `0.2126 * R + 0.7152 * G + 0.0722 * B`.
    - The positive sample set is exactly `luminance > 0.001`; zeros, negative
      luminance, and tiny positive values at or below the threshold are excluded.
    - Empty positive set returns `lo=0.0`, `hi=1.0`.
    - Percentiles use NumPy-style linear interpolation over the sorted positive
      luminance values:
      `rank = (n - 1) * percentile / 100`, floor/ceil neighbors, and linear
      interpolation by the fractional rank.
    - If `hi <= lo`, set `hi = lo + 1.0`.
    - Percentile inputs outside `[0, 100]` or non-finite values remain boundary
      errors before any GPU dispatch.
  - First acceptable GPU implementation:
    - Extract or expose a CPU `robustLuminanceRange` helper only if needed for
      testing; do not change its semantics.
    - Add `RenderToDisplayGpuParams` containing exact CPU `lo`, `hi`, color
      balance multipliers, exposure gamma, contrast constants, and flags.
    - Stage input `scene_linear` as the established GPU boundary format. The
      percentile range itself is computed from the existing CPU `f64` input
      before staging so WebGPU `f32` luminance cannot perturb the selected
      range.
    - WGSL applies only:
      normalize/clamp -> optional color balance -> optional exposure power ->
      optional logistic S-curve -> final clamp -> uint16-compatible display
      quantization.
    - Download the GPU display output and compare against the Zig CPU
      `renderToDisplay` output on every fixture before any workflow integration.
      Any tolerance must be justified solely by f32 WGSL arithmetic and final
      integer quantization; percentile value changes are not allowed.
  - Deferred GPU percentile/reduction work:
    - Do not implement histogram, t-digest, sampling, fixed-bin CDF, or other
      approximate percentile methods in the parity path.
    - Do not compute robust percentile on GPU with WGSL `f32` luminance and
      call it exact relative to the current Zig CPU `f64` contract.
    - If CPU percentile selection remains a bottleneck, first optimize the CPU
      exact path with an order-statistics selection algorithm that returns the
      same lower/upper percentile values as full sorting.
    - A full GPU percentile path is a separate post-parity design item and
      requires either a proven exact representation contract or explicit user
      approval for an approximate mode.
  - Required implementation gates when this plan is executed:
    - Reuse `render-to-display-baseline.json`,
      `render-to-display-adjusted.json`, and
      `render-to-display-no-positive-luminance.json`.
    - Add a dedicated WebGPU compare step, for example
      `webgpu-render-to-display-compare`, gated behind `-Dwebgpu=true`.
    - Add a realistic-size benchmark that reports CPU total time, CPU
      percentile time, GPU transform/download time, transfer sizes, output
      max/RMS difference, and speedup against the Zig CPU render path.
    - Only after the standalone comparison and benchmark pass may preview/export
      integration route render work through an explicit WebGPU request.

### Phase 11: Packaging And Cross-Platform

- [x] Package Linux CLI and native UI with Nix.
  - Updated `flake.nix` to expose explicit package outputs:
    `packages.cli` builds the CLI without SDL3/Nuklear, `packages.ui` builds
    the native SDL3/Nuklear UI package, and `packages.default` points at
    `packages.ui`. Both packages use isolated Zig cache directories in the Nix
    build and keep `meta.mainProgram` aligned with the expected binary.
  - Validation 2026-05-15: a single package validation command,
    `nix build path:.#cli path:.#ui --no-link --print-build-logs`, succeeded.
    The CLI package installed `bin/v600-zig`; the UI package installed
    `bin/v600-zig` and `bin/v600-ui`. This was the only Nix command for this
    checkpoint and was run because the checklist item is Nix package wiring.
- [x] Gate Linux scanner hardware smoke checks.
  - Tightened CLI and native UI hardware smoke gates so `V600_HARDWARE_SMOKE`
    must equal `1`; absent values and `V600_HARDWARE_SMOKE=0` skip without
    touching scanner hardware.
  - Added explicit no-hardware build steps: `scanner-smoke-skip`,
    `scanner-processing-smoke-skip`, `native-preview-worker-smoke-skip`, and
    `native-scan-worker-smoke-skip`. The flake check runs these skip steps so
    package/check validation cannot accidentally require attached scanner
    hardware.
  - Validation 2026-05-15: direct
    `zig build scanner-smoke-skip scanner-processing-smoke-skip --summary all`
    printed the expected skip messages and passed; direct
    `zig build -Dui=true native-preview-worker-smoke-skip native-scan-worker-smoke-skip --summary all`
    printed the expected skip messages and passed; direct
    `env V600_HARDWARE_SMOKE=0 zig build run -- scanner smoke --out /tmp/v600-should-not-scan.tiff`
    skipped; direct
    `env V600_HARDWARE_SMOKE=0 zig build -Dui=true run-ui -- --scan-worker-smoke --out /tmp/v600-native-should-not-scan.tiff`
    skipped.
    Direct `zig build test --summary all` passed `303/303`; direct
    `zig build --summary all` passed; direct `zig build -Dui=true --summary all`
    passed. One targeted Nix check command,
    `nix build path:.#checks.x86_64-linux.zig-tests --no-link --print-build-logs`,
    succeeded and showed all hardware smoke checks skipping without
    `V600_HARDWARE_SMOKE=1`.
- [x] Add macOS build plan and SDK constraints.
  - Added `docs/CROSS_PLATFORM.md` with macOS host-build sequence, SDK and
    dependency constraints, Epson Interpreter bundle search paths, current
    scanner runtime gaps, and future live macOS scanner validation steps.
    The document explicitly states that Linux cross-compilation is not macOS
    proof and that the proprietary Epson bundle must be host-installed rather
    than vendored into the repo or Nix store.
  - Validation 2026-05-15: docs-only checkpoint based on existing
    `src/scanner/macos.zig`, `docs/SCANNER_INTERNALS.md`, `flake.nix` systems,
    and current Linux-only runtime dispatch. No build or Nix command was needed.
- [x] Add Windows build plan for UI and non-scanner workflows.
  - Added `docs/CROSS_PLATFORM.md` Windows scope: native SDL3/Nuklear UI,
    processing-only TIFF workflows, gallery/config/numeric tests, and explicit
    scanner exclusion for version one. The plan calls out required work for
    target/dependency wiring, scanner runtime dispatch, Windows path semantics,
    validation on a real Windows host, and future D3D12/WebGPU planning after
    CPU parity.
  - Validation 2026-05-15: docs-only checkpoint. No build or Nix command was
    needed because Windows is not wired as a current target.
- [x] Document platform-specific scanner support and limitations.
  - Added the support matrix in `docs/CROSS_PLATFORM.md`: Linux scanner support
    is SANE-backed and live-tested; macOS scanner support is planned through
    Epson Interpreter and currently replay-tested only; Windows scanner support
    is out of scope for version one. The matrix also records processing CLI,
    native UI, packaging status, and hardware-smoke gate requirements.
  - Validation 2026-05-15: docs-only checkpoint. No build or Nix command was
    needed.
- [x] Add release checklist for parity-accepted version one rewrite.
  - Added the release checklist in `docs/CROSS_PLATFORM.md`, covering checked
    `plan.md` evidence, parity manifest status, direct Zig gates, GPU readiness
    benchmark gate, Linux package/check builds, refreshed Linux live scanner
    evidence, macOS host validation, real-display UI screenshots, no required
    WebGPU default path, no hardware-dependent default checks, and generated
    output hygiene.
  - Validation 2026-05-15: docs-only checkpoint. `git diff --check` passed for
    the touched docs and plan files.

### Phase 11A: Browser/Wasm Distribution Planning

- [x] Record the Browser/Wasm webapp distribution strategy.
  - Scope:
    - Plan only; do not add Emscripten, Node, Playwright, browser package
      tooling, new build targets, or Nix dependency changes in this checkpoint.
    - Ground the plan in the current native Zig app shape rather than assuming
      the SDL3/Nuklear application can be cross-compiled unchanged.
    - Keep scanner control out of the first web product. The first browser
      deliverable is a processing/export webapp for already-scanned files; a
      local native scanner companion is a later design option; full WebUSB
      scanner control is a research track.
    - Preserve the existing parity hierarchy: Python remains the behavior
      oracle, accepted native Zig CPU remains the implementation/performance
      baseline, Wasm CPU must match final native Zig surfaces, and browser
      WebGPU must keep CPU fallback plus downloaded comparison evidence.
  - Completed 2026-05-23:
    - Added `docs/WEBAPP_PORT_PLAN.md` with product modes, current native
      portability blockers, target Wasm/browser architecture, build strategy,
      dependency risks, Web Worker/cache-key requirements, browser WebGPU
      adapter rules, headless parity/performance metrics, and a staged
      implementation checklist.
    - Updated `docs/CROSS_PLATFORM.md` with browser distribution invariants,
      a Browser/Wasm plan section, a Browser/Wasm support-matrix row, and the
      explicit rule that browser scanner control is not a version-one web
      target.
    - Updated `docs/PARITY_MANIFEST.md` so Phase 11 cross-platform planning
      points at the Browser/Wasm plan alongside the native platform docs.
    - Validation: docs-only checkpoint. No Zig build, Nix evaluation, or new
      dependency was needed because no source code or build graph changed.

### Phase 12: Release Acceptance Audit

This phase maps the active `/goal` and `docs/CROSS_PLATFORM.md` release
checklist to concrete evidence. Do not mark the thread goal complete until
every item below is either checked with current evidence or explicitly deferred
by the user for the release claim. Passing tests, a full-looking manifest, or
the absence of older unchecked boxes is not enough by itself.

Prompt-to-artifact checklist:

| Requirement | Artifact/evidence source | Current decision |
| --- | --- | --- |
| Choose next smallest `plan.md` checkpoint until complete | This checklist and `rg -n "\[ \]" plan.md` | Active in Phase 12 |
| Implement and validate checkpoints | Source diffs, direct Zig gates, hardware smokes, benchmarks | Partially current; release refresh below |
| Update fixtures, verification log, and parity manifest | `test/fixtures/**`, this log, `docs/PARITY_MANIFEST.md` | Needs final audit after release gates |
| Complete parity, native UI, GPU, packaging, and exit criteria | `docs/CROSS_PLATFORM.md` release checklist items 1-15 | Not complete until this phase is done |
| Avoid proxy completion | Per-item evidence must name commands, files, blockers, or deferrals | Required for all items below |

- [x] Perform current-state completion audit and expose remaining release work.
  - Completed 2026-05-18: the audit restated the goal as a version-one
    parity-accepted Zig replacement with current evidence for all release
    checklist items. `rg -n "\[ \]" plan.md` returned no older unchecked
    checklist items before this Phase 12 section was added, but
    `docs/CROSS_PLATFORM.md` still requires release evidence that was not
    represented as selectable plan work.
  - Evidence inspected: `plan.md`, `docs/CROSS_PLATFORM.md`,
    `docs/PARITY_MANIFEST.md`, `docs/PERFORMANCE_STRATEGY.md`, `git status
    --short`, and local generated-output listings.
  - Missing or weak evidence found: current direct Zig release-gate refresh,
    release-time Nix package/check gates, release-time Linux live scanner smoke
    refresh, macOS host build/test evidence, and real-display native UI
    screenshots.
  - Completion decision: this audit item is complete, but the thread goal is
    not complete.

- [x] Refresh direct Zig release gates from the ambient shell.
  - Covers release checklist items 3, 4, 5, 6, 13, and 14.
  - Run only direct Zig commands:
    - `zig build test --summary all`
    - `zig build --summary all`
    - `zig build -Dui=true --summary all`
    - `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
  - Required evidence before checking off: exact pass/fail results, test
    counts when available, and confirmation that default build/test paths did
    not require WebGPU or scanner hardware.
  - Completed 2026-05-18 with direct Zig commands only:
    - Refreshed after CPU SIMD and preview buffer-fusion work:
      `zig build test --summary all` passed. Build summary:
      `9/9 steps succeeded; 395/395 tests passed`.
    - `zig build --summary all` passed. Build summary:
      `9/9 steps succeeded`; installed `v600-zig`.
    - `zig build -Dui=true --summary all` passed. Build summary:
      `12/12 steps succeeded`; installed `v600-zig` and `v600-ui`.
    - `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
      passed. Build summary: `9/9 steps succeeded`; benchmark gate:
      `gpu_readiness_gate,active_candidates,7,benchmarked_candidates,7`.
      Refreshed after the preview buffer-fusion work with
      `ns_per_pixel_x1000` values:
      `srgb_to_linear=71629`, `linear_to_srgb=69382`,
      `color_matrix_rec2020=773`, `density_transform_kodak_gold=987`,
      `invert_negative_scalar=40930`, `invert_negative=20877`,
      `invert_negative_simd=20714`, `invert_negative_u16_simd=20857`,
      `darktable_sigmoid=188053`, `negadoctor=276806`,
      `render_to_display=135889`, `render_to_display_u16_then_u8=131381`,
      and `render_to_display_u8=137533`.
  - Default build/test confirmation: none of these commands used
    `-Dwebgpu=true`, `V600_PROCESSING_GPU`, `V600_HARDWARE_SMOKE=1`, or Nix.

- [x] Refresh WebGPU opt-in performance/parity gates after current changes.
  - Covers the GPU portion of the goal and confirms the latest tree still
    compares explicit WebGPU against the Zig CPU oracle.
  - Run only from an already-loaded WebGPU-capable ambient shell:
    - `zig build -Dwebgpu=true test --summary all`
    - `zig build -Dwebgpu=true webgpu-invert-negative-compare --summary all`
    - `zig build -Dwebgpu=true webgpu-invert-negative-runtime-smoke --summary all`
    - `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-webgpu-invert-negative --summary all`
  - Required evidence before checking off: CPU-vs-GPU max/RMS differences,
    cold/warm or end-to-end/resident timings where reported, and confirmation
    that Python remains the behavior oracle while Zig CPU is the performance
    comparison baseline.
  - If the ambient shell is no longer WebGPU-capable, do not run Nix; record
    the missing variable/library and ask the human to reload the WebGPU shell.
  - Completed 2026-05-18 from the already-loaded WebGPU ambient shell. Direct
    probes confirmed readable `$WGPU_NATIVE_INCLUDE_DIR/webgpu/wgpu.h` and
    present `$WGPU_NATIVE_LIBRARY_DIR/libwgpu_native.so`; no Nix command was
    run.
  - Validation:
    - Refreshed after CPU SIMD and preview buffer-fusion work:
      `zig build -Dwebgpu=true test --summary all` passed. Build summary:
      `9/9 steps succeeded; 397/397 tests passed`.
    - `zig build -Dwebgpu=true webgpu-invert-negative-compare --summary all`
      passed with identity `max_abs=0.000000109`, `rms=0.000000043`; Kodak
      Gold `max_abs=0.000000190`, `rms=0.000000073`; and custom edge
      `max_abs=0.000000874`, `rms=0.000000243`.
    - `zig build -Dwebgpu=true webgpu-invert-negative-runtime-smoke --summary all`
      passed. Default CPU request reported `max_abs=0.000000132`,
      `rms=0.000000046`; explicit WebGPU reported `max_abs=0.000000322`,
      `rms=0.000000113`; adapter preflight selected Vulkan adapter
      `590.48.01`.
    - `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-webgpu-invert-negative --summary all`
      passed after the CPU SIMD and linear-coefficient fast paths changed the
      Zig CPU baseline. `preview_1024x768`: CPU `20873284 ns`,
      GPU end-to-end `4827842 ns`, resident `2628179 ns`, end-to-end speedup
      `12.970x`, resident speedup `158.843x`. `export_frame_2048x3072`:
      CPU `156608114 ns`, GPU end-to-end `14024699 ns`, resident
      `9126367 ns`, end-to-end speedup `11.166x`, resident speedup `171.599x`.
  - Performance comparison baseline: these GPU numbers compare against the Zig
    CPU `invert_negative` pipeline. Python remains the behavior oracle through
    the committed fixtures and CPU oracle tests.

- [x] Benchmark large real scan data from `scans/` for preview and full-res
      export throughput.
  - Added `export_fullres_inv_cpu_vs_gpu` to
    `src/benchmarks/processing_commands.zig`. The case derives a 35mm-sized
    full-resolution crop from the real TIFF page geometry and DPI, then runs
    the normal export workflow with CPU inversion, explicit WebGPU cold
    inversion, and explicit WebGPU warm inversion.
  - Fixed the production `invert_negative` WebGPU path to chunk large inputs
    into 64 MiB RGB-f32 slices. The first large real scan attempt on
    `scan_0004_rgbir_3200dpi.tiff` aborted in `wgpuQueueSubmit` because the
    one-shot storage-buffer bind group exceeded the native backend's binding
    size limit. Added a chunk-range unit test covering the `1738x8192` preview
    case that exposed the problem.
  - Large scan discovery:
    - `scans/scan_0004_rgbir_3200dpi.tiff`: 864682512 bytes; RGB page
      `5120x24125`; IR page `5120x24125`.
    - `scans/scan_0003_rgbir_3200dpi.tiff`: 727783712 bytes.
  - Validation and benchmark evidence:
    - `zig build -Dwebgpu=true test --summary all` passed `397/397`.
    - `zig build -Dwebgpu=true webgpu-invert-negative-compare --summary all`
      passed after chunking with identity `max_abs=0.000000109`, Kodak Gold
      `max_abs=0.000000190`, and custom edge `max_abs=0.000000874`.
    - `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case load_preview`
      loaded a `1738x8192` preview in `2330243 us`.
    - Refreshed after the CPU SIMD, linear-coefficient, direct-u16, and
      direct-u8 fast paths:
      `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case inverted_preview_cpu_vs_gpu`
      reported CPU `1800749 us`, GPU cold `2378655 us`, GPU warm
      `2194852 us`, warm speedup `0.820x`, `max_abs=1`, `rms=0.002`.
    - `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0003_rgbir_3200dpi.tiff --case load_preview`
      loaded a `1901x8192` preview in `2446635 us`.
    - Refreshed after the CPU SIMD fast path:
      `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0003_rgbir_3200dpi.tiff --case inverted_preview_cpu_vs_gpu`
      reported CPU `2060415 us`, GPU cold `2544158 us`, GPU warm
      `2323564 us`, warm speedup `0.886x`, `max_abs=1`, `rms=0.002`.
    - Refreshed after the CPU SIMD, linear-coefficient, and direct-u16 export
      fast paths:
      `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_fullres_inv_cpu_vs_gpu`
      exported a full-resolution `4535x3023` crop and reported CPU
      `4786929 us`, GPU cold `5249665 us`, GPU warm `5056970 us`, warm
      speedup `0.946x`, `max_abs=1`, `rms=0.050`,
      `metadata_equal=true`.
    - Refreshed after the CPU SIMD fast path:
      `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0003_rgbir_3200dpi.tiff --case export_fullres_inv_cpu_vs_gpu`
      exported a full-resolution `4420x3023` crop and reported CPU
      `4468992 us`, GPU cold `4858133 us`, GPU warm `4681464 us`, warm
      speedup `0.954x`, `max_abs=1`, `rms=0.051`,
      `metadata_equal=true`.
  - Performance decision: after the CPU SIMD fast path, large real-scan
    WebGPU preview/export workflows are slower than the CPU path despite the
    standalone GPU kernel still being faster. TIFF loading, CPU render/display,
    crop/write work, transfers, and repeated CPU/GPU boundaries dominate. Keep
    WebGPU opt-in/default-off and next reduce those workflow costs or move
    additional render/display stages behind the same explicit WebGPU request.

- [x] Add fused CPU SIMD fast path for provided-Dmin `invert_negative`.
  - Scope: same custom Python `invert_negative` algorithm, not `negadoctor`.
    The production CPU path may use SIMD only when Dmin is provided, dark/light
    calibration is absent, the input is valid RGB triples, and `default_light`
    has the same effective denominator as the scalar path. Other cases keep the
    scalar oracle path.
  - Implementation notes:
    - Added `invertNegativeProvidedDminScalar` as an explicit scalar oracle for
      benchmarks and fallback.
    - Added `invertNegativeProvidedDminSimd` as the fused per-pixel path:
      raw/default-light normalization, density, Dmin subtraction, 10-term
      coefficient transform, and non-negative clamp in one pass.
    - Added `film_stocks.usesOnlyLinearTerms` and `applyLinearTerms` so the
      built-in identity, Kodak Gold, and Portra profiles use a direct 3x3
      linear transform while custom profiles with nonzero higher-order rows
      keep the general 10-term path.
    - Wired `invertNegative` to select SIMD for the safe provided-Dmin CPU case
      while preserving explicit WebGPU request behavior and scalar fallback.
    - Added `invert_negative_scalar` and `invert_negative_simd` benchmark rows
      beside the production `invert_negative` row.
  - Validation:
    - `zig build test --summary all` passed `394/394`.
    - `zig build -Dwebgpu=true test --summary all` passed `396/396`.
    - `zig build -Dwebgpu=true webgpu-invert-negative-compare --summary all`
      passed with unchanged identity/Kodak/custom-edge tolerances.
    - `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
      passed with `gpu_readiness_gate,active_candidates,7,benchmarked_candidates,7`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case invert_negative_preview_cpu_vs_simd`
      reported scalar `841762 us`, SIMD `344512 us`, speedup `2.443x`,
      `max_abs=0`, `rms=0`, and equal checksums on a `1738x8192` preview.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case invert_negative_fullres_cpu_vs_simd`
      reported scalar `835616 us`, SIMD `344307 us`, speedup `2.426x`,
      `max_abs=0`, `rms=0`, and equal checksums on a `4535x3023` crop.

- [x] Record additional CPU waste/fusion optimization targets.
  - Added to `docs/PERFORMANCE_STRATEGY.md` as parity-constrained fusion
    targets:
    - Export u16 render/rotate/write path to avoid display-valued `f64`
      temporaries.
    - Exact percentile selection to avoid full luminance sorting without
      changing NumPy-style interpolation semantics.
  - The coefficient-shape fast path is now complete under the fused CPU SIMD
    checkpoint above; it remains listed in `docs/PERFORMANCE_STRATEGY.md` as a
    completed fusion target, not a pending follow-up.
  - Preview render-to-u8 and u16-input raw staging fusion are now complete under
    the preview buffer-fusion checkpoint below.

- [x] Implement preview buffer-fusion wins for direct-u8 render and direct-u16
      inversion.
  - Scope: keep the frozen Python custom `invert_negative` and
    `render_to_display` algorithms. These are representation/pass reductions,
    not alternate processing algorithms.
  - Implementation notes:
    - Added `render.renderToDisplayU8`, sharing the exact display math with
      `renderToDisplay` and preserving the old preview quantization contract:
      output byte equals `renderToDisplay(... u16) >> 8`.
    - Routed `workflow.renderInvertedPreviewRgb8` through
      `renderToDisplayU8`, removing the temporary preview `u16` display buffer
      and downshift pass.
    - Added `inversion.invertNegativeProvidedDminU16Simd`, covering both
      linear-only coefficient and general 10-term coefficient paths, so
      provided-Dmin previews can avoid expanding the whole `u16` preview into a
      temporary `f64` raw buffer.
    - Routed CPU provided-Dmin preview inversion through the direct `u16` path
      while preserving explicit WebGPU requests and the non-Dmin fallback path.
    - Added `render_to_display_u16_then_u8`,
      `render_to_display_u8`, and `invert_negative_u16_simd` benchmark rows.
    - Added `preview_render_u8_vs_u16` and
      `invert_negative_preview_u16_vs_f64` real-scan benchmark cases.
  - Validation:
    - `zig build test --summary all` passed `394/394`.
    - `zig build -Dwebgpu=true test --summary all` passed `396/396`.
    - `zig build -Dwebgpu=true webgpu-invert-negative-compare --summary all`
      passed with identity `max_abs=0.000000109`, Kodak Gold
      `max_abs=0.000000190`, and custom edge `max_abs=0.000000874`.
    - `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
      passed with `gpu_readiness_gate,active_candidates,7,benchmarked_candidates,7`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case preview_render_u8_vs_u16`
      reported old `u16_then_u8_us=1462721`, direct `u8` `1428256 us`,
      speedup `1.024x`, `max_abs=0`, `rms=0.000`, and equal checksums.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case invert_negative_preview_u16_vs_f64`
      reported staged `f64` `474283 us`, direct `u16` `341936 us`, speedup
      `1.387x`, `max_abs=0`, `rms=0.000000000000`, and equal checksums.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case inverted_preview`
      reported full CPU inverted preview `1796580 us`, down from the earlier
      current-session post-render-fusion run of `1947054 us`, with checksum
      `3913296606`.

- [x] Implement approved sampled render range and dynamic display LUTs.
  - Scope: same frozen `render_to_display` transform and final quantized
    preview/export outputs. Exact semantics remain available through
    `percentile_sample_limit=0` and fixture-sized fallback; large production
    previews use the explicitly approved approximate robust-statistic mode.
  - Implementation notes:
    - Added `RenderToDisplayOptions.percentile_sample_limit`, public
      `LuminanceRange`, and `estimateDisplayLuminanceRange`.
    - Kept exact f64 full-sort percentile behavior for oracle and small fixture
      paths.
    - Added deterministic f32 robust-range sampling with a default 16k sample
      cap to avoid image-sized sort/scratch work on large previews.
    - Added separate dynamic display LUTs for the separate constraints:
      256-entry nearest `u8` LUT for preview and 1024-entry linear f32 LUT for
      export-shaped `u16` display.
    - Updated the export parallelism memory heuristic so render percentile
      scratch uses the exact/sampled render option instead of always assuming a
      full f64 luminance buffer.
    - Added `bench-render-curves` and `preview_render_quantile_tradeoff` to
      measure exact-vs-LUT accuracy and runtime on real scan data.
  - Validation:
    - `zig build test --summary all` passed `400/400`.
    - `zig build -Doptimize=ReleaseFast bench-color --summary all` passed; the
      current synthetic rows include `invert_negative=16772`,
      `invert_negative_u16_simd=16824`, `render_to_display=129087`,
      `render_to_display_u16_then_u8=125588`, and
      `render_to_display_u8=127761` ns-per-pixel x1000.
    - `zig build -Doptimize=ReleaseFast bench-render-curves --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --iterations 3`
      showed the accepted LUT sizes: 256-entry nearest preview LUT around
      `37.1 ms` with `max_abs=1`, RMS `0.361`; 1024-entry linear export LUT
      around `89.6 ms` with `max_abs=1`, RMS `0.039`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case preview_render_quantile_tradeoff`
      reported exact full-sort/full-curve preview render `1335115 us`; the
      production 16k-sample plus preview LUT path took `71011 us`, speedup
      `18.801x`, with final `u8` `max_abs=1`, RMS `0.364`, and scratch reduced
      from `113901568` bytes to `65536` bytes.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case inverted_preview`
      reported full CPU inverted preview `410896 us`, checksum `3912223882`.

- [x] Optimize the next preview hotspot: `invert_negative` density/log.
  - Start here after the sampled render/LUT checkpoint unless a newer benchmark
    invalidates it.
  - Starting evidence:
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case inverted_preview`
      reported full inverted preview `410896 us`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case invert_negative_preview_u16_vs_f64`
      reported direct-u16 preview inversion `348303 us`, so inversion is now
      roughly 85 percent of the visible preview operation.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case preview_render_u8_vs_u16`
      reported direct preview display render `69388 us`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case invert_negative_preview_breakdown`
      reported fused direct-u16 inversion `347419 us`; a benchmark-only staged
      split measured `density_us=340854` and `linear_transform_us=138941` with
      exact output equality, showing the `u16 -> net density` log conversion is
      the next target.
  - Implementation notes:
    - Added dynamic per-channel density LUT types to `inversion.zig`:
      `DensityLutF64` and `DensityLutF32`.
    - Added LUT-backed `u16` provided-Dmin inversion helpers for f64 scene
      output, f32-density/f64 scene output, and f32-density/f32 scene output.
    - Added `render.renderToDisplayU8F32` so the preview path can keep f32
      scene-linear data through display rendering instead of widening back to
      f64.
    - `InvertedPreviewCache` now keeps a separate `scene_linear_f32` buffer for
      the provided-Dmin/default CPU preview path. Existing f64 cache behavior
      remains for no-Dmin, WebGPU, exact fixture, and non-preview paths.
    - The native inverted-preview worker now includes
      `percentile_sample_limit` in render-option cache keys so preview quality
      changes cannot reuse stale render results.
  - Validation:
    - `zig build test --summary all` passed `402/402`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case invert_negative_preview_lut_tradeoff`
      reported direct-u16 SIMD `345713 us`; f64 density LUT to f64 scene
      `138229 us`, exact final `u8/u16`; f32 density LUT to f64 scene
      `136506 us`, preview `u8 max_abs=2`, `u8_mse=0.000001967`,
      export-shaped `u16 max_abs=1`, `u16_mse=0.000391519`; and accepted f32
      density LUT to f32 scene `74063 us`, speedup `4.667x`,
      `scene_mse=0.000000000000000194`, preview `u8 max_abs=2`,
      `u8_mse=0.000004987`, export-shaped `u16 max_abs=1`,
      `u16_mse=0.001272631`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case inverted_preview`
      reported full CPU inverted preview `146687 us`, checksum `3912224049`,
      down from `410896 us` before the density LUT checkpoint and `208072 us`
      with the conservative f64 density-LUT preview path.

- [x] Re-benchmark preview after f32 density LUT adoption and select the next
      hotspot.
  - Added `inverted_preview_f32_breakdown` to
    `bench-processing-commands`. It reports production first-use preview time,
    manual f32 stage timings, output parity against production, and comparison
    against the exact f64 table-index output path.
  - Implemented two display-output wins while preserving the same preview
    algorithm:
    - channel-specific per-pixel loops avoid the old per-sample `index % 3`
      in preview display LUT writes;
    - `renderToDisplayU8F32` now uses f32 range/index arithmetic for the
      preview table lookup, leaving the exact f64-index comparison in the
      benchmark harness.
  - Validation on `scan_0004_rgbir_3200dpi.tiff`:
    - Pre-change accepted f32-density full preview: `146687 us`, checksum
      `3912224049`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case inverted_preview_f32_breakdown`
      reported production `122313 us`, manual total `123680 us`,
      `invert_us=68753`, `range_us=1310`, `output_write_us=52157`,
      `max_abs=0` and matching checksum `3912224212` against the manual
      f32-index mirror.
    - Exact f64-index output comparison on the same scan reported
      `exact_output_write_us=64246`, `exact_max_abs=2`,
      `exact_mse=0.000004425`, and `exact_mismatches=153` out of
      `42,713,088` channel samples.
  - Multi-scan real-data spread for the exact f64-index comparison:
    - `scan_0001_rgbir_3200dpi.tiff`: production `243030 us`,
      `output_write_us=92289`, exact write `113211 us`, `max_abs=2`,
      `mse=0.000001385`, `104` mismatches out of `85,917,696` channel
      samples.
    - `scan_0002_rgbir_3200dpi.tiff`: production `129442 us`,
      `output_write_us=49808`, exact write `61893 us`, `max_abs=2`,
      `mse=0.000007563`, `325` mismatches out of `46,148,094` channel
      samples.
    - `scan_0003_rgbir_3200dpi.tiff`: production `131599 us`,
      `output_write_us=50181`, exact write `62477 us`, `max_abs=2`,
      `mse=0.000002247`, `96` mismatches out of `46,718,976` channel samples.
    - `scan_0004_rgbir_3200dpi.tiff`: production `122313 us`,
      `output_write_us=52157`, exact write `64246 us`, `max_abs=2`,
      `mse=0.000004425`, `153` mismatches out of `42,713,088` channel samples.
  - Selected next hotspot: f32 density-LUT inversion is now dominant. On the
    measured real scans it accounts for roughly 56-61 percent of manual preview
    time, while output write is now roughly 37-42 percent and range estimation
    is about 1 percent.

- Parked note - Optimize current dominant preview hotspot: f32 density-LUT
  inversion.
  - Deferral note: on 2026-05-19, user explicitly asked to pass over this
    because it was just optimized and is unlikely to be the lowest-friction
    remaining win. Do not choose this as the next autonomous item until the
    larger export/autodetect/scanner waits are reduced or the user asks to
    return to it.
  - Precision note: Dmin does not need f64 precision inside the accepted f32
    preview path. The f32 density LUT now has an `initF32` constructor, and
    `renderInvertedPreviewRgb8` routes provided-Dmin/default CPU preview
    inversion through f32 Dmin for LUT construction. Config/UI/oracle surfaces
    still keep f64 Dmin to avoid broad churn and preserve existing fixtures.
  - Evidence on `scan_0004_rgbir_3200dpi.tiff`:
    `invert_negative_preview_lut_tradeoff` measured f32-Dmin LUT construction
    at `build_us=975`, `apply_us=65765`, total `66740 us`, final preview
    `u8 max_abs=2`, `u8_mse=0.000010418`, export-shaped `u16 max_abs=1`, and
    `u16_mse=0.002867622`.
  - Current production preview evidence:
    `inverted_preview_f32_breakdown` measured `production_us=130053`,
    `lut_build_us=980`, `invert_us=75242`, `output_write_us=50321`,
    exact manual mirror equality, and checksum `3912224310`.
  - Scope: keep the same provided-Dmin `invert_negative` math and f32
    density-LUT semantics. Do not replace the inversion algorithm.
  - Start from `inversion.invertNegativeProvidedDminU16WithDensityLutF32OutputF32`
    and its `workflow.renderInvertedPreviewRgb8` use.
  - Candidate approaches to test in this order:
    - remove remaining loop overhead in the f32 LUT output path without
      changing results;
    - benchmark row/chunk parallelism for preview scene generation, using the
      existing dynamic CPU/memory parallelism policy as the export precedent and
      leaving at least one core free;
    - evaluate whether output-write parallelism should share the same worker
      scheduler or remain single-threaded to reduce memory traffic;
    - only after CPU parallelism is measured, revisit GPU execution for this
      exact operation with CPU fallback and CPU-vs-GPU output downloads.
  - Required evidence before checking off:
    - `zig build test --summary all`;
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case inverted_preview_f32_breakdown`;
    - before/after stage timing, checksum, and final `u8` diff metrics against
      the accepted CPU path;
    - update this plan and `docs/PERFORMANCE_STRATEGY.md`.

- [x] Optimize secondary Process hotspots outside the f32 density-LUT loop.
  - Motivation: after f32 density-LUT work, density inversion is still the
    largest sub-stage inside inverted preview, but other Process operations had
    larger user-visible latencies and more obvious redundant work.
  - Secondary baseline on `scan_0004_rgbir_3200dpi.tiff`:
    - `load_preview`: `2255972 us`, checksum `6666414344`;
    - `auto_detect`: `769041 us`, frames `5`, checksum `38221731`;
    - `rebate_dmin`: `2396746 us`, Dmin
      `0.283915:0.422373:0.606312`;
    - `inverted_preview_f32_breakdown`: production `122020 us`,
      manual total `126633 us`;
    - `export_detected_frames`: parallel `4273176 us`, serial `9594052 us`,
      workers `5`.
  - Quick preview improvements:
    - `generateQuickPreview` now computes the expected preview geometry in Zig
      and calls `v600_process_quick_preview` once on the normal path. The
      previous implementation called the OpenCV resize/stretch/CLAHE/JPEG path
      once to discover JPEG length and then repeated the same work to fill the
      real output buffers.
    - The fallback remains: if the initial JPEG capacity is too small, the code
      resizes to the reported encoded length and reruns the OpenCV path.
    - `loadQuickPreview` now reads only RGB pixels plus IR page metadata. It no
      longer reads the full IR page just to set `has_ir` and IR bit-depth UI
      state.
    - Added TIFF page metadata APIs:
      `readRgbIrPageInfo` and `readIrPageInfo`.
  - Rebate Dmin improvements:
    - `loadRgbImageAsF64` now loads only TIFF page 0 for RGB-only callers
      instead of loading RGB+IR and discarding IR.
    - `computeRebateDminFromTiff` now crops the small rotated rebate directly
      from the TIFF RGB sample buffer and materializes f64 only for the rebate
      crop, rather than converting the entire scan to f64 before cropping.
    - Added a synthetic crop-parity test comparing the direct TIFF crop helper
      against the existing full-f64 `export.cropFrame` path.
  - Refreshed results on `scan_0004_rgbir_3200dpi.tiff`:
    - `load_preview`: `1327413 us`, checksum `6666414344`
      (`1.700x` faster than the `2255972 us` baseline).
    - `rebate_dmin`: `448352 us`, same Dmin
      `0.283915:0.422373:0.606312` (`5.346x` faster than the
      `2396746 us` baseline).
    - `auto_detect`: `765814 us`; now the largest remaining interactive
      secondary Process command after image load.
    - `inverted_preview_f32_breakdown`: production `125575 us`, manual total
      `129836 us`, checksum `3912224212`.
    - `export_detected_frames`: parallel `4138270 us`, serial `9668720 us`,
      workers `5`.
  - Validation:
    - `zig build test --summary all` passed `403/403`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case load_preview`
      reported `1327413 us`, checksum `6666414344`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case rebate`
      reported `448352 us`, same Dmin as baseline.

- [x] Break down and optimize the first `auto_detect` secondary hotspot pass.
  - Current refreshed timing:
    `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect`
    reported `765814 us`, frames `5`, aspect `24:36`, checksum `38221731`.
  - Scope: preserve Python frame autodetect behavior. Do not change detector
    semantics, defaults, frame fallback rules, or rebate computation to gain
    speed.
  - Progress 2026-05-19:
    - Added the parity-checked `auto_detect_breakdown` benchmark. It runs the
      production `workflow.autoDetectPreview` path and the staged
      `frames.detectFramesFromImageBreakdown` path on the same preview, then
      fails if frame count, aspect, frame geometry, rebate geometry, or frame
      checksum differ.
    - Validation command:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`
      reported exact parity: frames `5`, aspect `24:36`, checksum `38221731`,
      `frame_max_abs=0`, `rebate_max_abs=0`, `mismatches=0`.
    - Real 3200 DPI scan-set breakdown:
      - `scan_0001_rgbir_3200dpi.tiff`: total `1334010 us`, film extent
        `608503 us`, CLAHE `278455 us`, rotation `158150 us`, grayscale prep
        `123649 us`, axis detection `122152 us`.
      - `scan_0002_rgbir_3200dpi.tiff`: total `689004 us`, film extent
        `307472 us`, CLAHE `155468 us`, rotation `78798 us`, grayscale prep
        `61174 us`, axis detection `66636 us`.
      - `scan_0003_rgbir_3200dpi.tiff`: total `731227 us`, film extent
        `316458 us`, CLAHE `163559 us`, rotation `101859 us`, grayscale prep
        `61898 us`, axis detection `64086 us`.
      - `scan_0004_rgbir_3200dpi.tiff`: total `729511 us`, film extent
        `282007 us`, CLAHE `162053 us`, rotation `138127 us`, grayscale prep
        `58280 us`, axis detection `68378 us`.
    - Average across those four real 3200 DPI scans: film extent is about
      `43.5%` of `auto_detect`, CLAHE `21.8%`, rotation `13.7%`, grayscale
      prep `8.8%`, and axis detection `9.2%`. Inside axis detection, profile
      aggregation and angle fitting dominate; DTW, snap/repair, edge-to-frame
      construction, rebate postprocess, and rotation-back transform are small.
  - Next optimization target:
    - Start with film extent and duplicated grayscale/CLAHE preparation waste.
      The current route derives f64 grayscale, then film extent converts it to
      thresholdable u8 data, and CLAHE converts the same f64 grayscale back to
      inverted u8 before producing f64 again. A correct optimization should
      share or fuse those exact intermediate values while preserving the same
      Otsu threshold, binary close, largest-component, rotated-extent, CLAHE,
      and final frame/rebate output.
    - If film-extent conversion/fusion is not enough, add a deeper
      `film_extent_breakdown` before changing contour/component logic.
    - Only then consider rotation and CLAHE loop-level optimization.
  - Required evidence before checking off:
    - `zig build test --summary all`;
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`;
    - before/after stage timing on at least `scan_0004_rgbir_3200dpi.tiff`;
    - unchanged frame count/aspect/checksum, `frame_max_abs`, `rebate_max_abs`,
      and mismatch count against the production `auto_detect` path;
    - update this plan and `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-19:
    - Added deeper film-extent stage timing:
      `film_otsu_us`, `film_mask_us`, `film_close_us`,
      `film_component_us`, and `film_geometry_us`.
    - Preserved the detector contract while reducing full-image passes and
      strided memory access:
      - `prepareDetectionGrayImage` retains the quantized u8 grayscale
        alongside the f64 grayscale so film extent and non-rotated CLAHE do not
        reconstruct it from f64.
      - 16-bit RGB grayscale quantization now uses exact integer division
        equivalent to Python's `(mean / 256).astype(uint8)`.
      - Film extent can run directly from the u8 grayscale, with fixture checks
        proving exact parity against the original f64 film-extent helper.
      - Binary close now reuses scratch buffers and uses row-major sliding
        vertical and horizontal windows instead of repeated prefix passes with
        strided column scans.
      - Largest-component detection now consumes its private mask in place
        instead of allocating and streaming a second visited bitmap, and uses a
        u32 queue when the preview fits.
      - Otsu's u8 histogram now uses independent partial histograms.
      - u8-to-f64 widening now uses a 256-entry table.
      - Rotated-image affine sampling precomputes row terms without changing
        the bilinear sampler semantics.
      - Vertical cross-profile accumulation now runs row-major while preserving
        per-column summation order.
    - Updated `scan_0004_rgbir_3200dpi.tiff` `auto_detect_breakdown`:
      total `608397 us` versus `729511 us` before this pass (`1.199x`);
      film extent `193853 us` versus `282007 us`; Otsu `3603 us`, mask
      `7255 us`, close `47110 us`, component `118397 us`, geometry
      `15243 us`; CLAHE `153740 us`; rotation `147704 us`; axis total
      `41190 us`; profiles `11549 us`; frames `5`, aspect `24:36`,
      checksum `38221731`, `frame_max_abs=0`, `rebate_max_abs=0`,
      `mismatches=0`.
    - Normal `auto_detect` on `scan_0004_rgbir_3200dpi.tiff` now reports
      `605658 us`, frames `5`, aspect `24:36`, checksum `38221731`, versus the
      refreshed `765814 us` baseline (`1.265x`).
    - Across `scan_0001` through `scan_0004` real 3200 DPI RGBIR scans,
      average `auto_detect_breakdown` improved from `870938 us` to
      `682404 us` (`1.276x`). Updated average stage shares are film extent
      about `36.1%`, CLAHE `25.5%`, rotation `17.8%`, grayscale prep `9.3%`,
      and axis detection `7.2%`.
    - Validation:
      - `zig build test --summary all` passed `403/403`.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`
        reported exact parity with `mismatches=0`.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect`
        reported `605658 us`, checksum `38221731`.

- [x] Continue `auto_detect` optimization on the remaining stage buckets.
  - Current 2026-05-19 target order from the optimized breakdown:
    - CLAHE remains around `153740 us` on `scan_0004` and averages about
      `25.5%` of the four-scan timing.
    - Rotation remains around `147704 us` on `scan_0004` and averages about
      `17.8%`.
    - Film extent is still the largest combined bucket, but close and
      connected component have already been improved; the next film-extent
      work should focus on exact connected-component/geometry improvements or
      OpenCV-parity evidence before replacing more logic.
    - Smaller buckets still matter: mask generation, geometry, DTW, angle
      fitting, and cross-strip refinement should remain eligible for measured
      pass reductions.
  - Keep the same required evidence style as the completed pass: ReleaseFast
    before/after stage timings, exact frame/rebate parity, `zig build test
    --summary all`, and notes in this file plus `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-19:
    - Optimized CLAHE without changing the OpenCV-shaped operation:
      - precomputed reflected border index maps instead of calling
        `reflect101Index` for every padded pixel;
      - precomputed per-x/per-y tile interpolation indices and f64 weights
        instead of recomputing `floor`, clamp, fraction, and inverse fraction
        inside every output pixel;
      - avoided materializing the padded `extended` image because it is only
        used for tile histograms; histograms now read through the same
        reflected index maps directly from the source image.
    - Reduced rotation overhead by incrementing affine source coordinates along
      each row after precomputing the row origin, while keeping the same
      replicate-border bilinear sampler.
    - Removed a redundant initial full-image `component_mask` clear in
      connected-component detection.
    - Updated `scan_0004_rgbir_3200dpi.tiff` `auto_detect_breakdown`:
      total `541755 us`; film extent `179309 us`; Otsu `3613 us`, mask
      `7278 us`, close `46727 us`, component `104529 us`, geometry
      `15133 us`; rotation `127573 us`; CLAHE `117997 us`; axis total
      `46501 us`; frames `5`, aspect `24:36`, checksum `38221731`,
      `frame_max_abs=0`, `rebate_max_abs=0`, `mismatches=0`.
    - Normal `auto_detect` on `scan_0004_rgbir_3200dpi.tiff` now reports
      `557439 us`, frames `5`, aspect `24:36`, checksum `38221731`, versus the
      refreshed `765814 us` baseline (`1.374x`).
    - Across `scan_0001` through `scan_0004` real 3200 DPI RGBIR scans,
      average `auto_detect_breakdown` improved from the initial `870938 us` to
      `621128 us` (`1.402x`), and from the first optimized pass's `682404 us`
      to `621128 us` (`1.099x`). Updated average stage shares are film extent
      about `38.0%`, CLAHE `22.0%`, rotation `16.8%`, grayscale prep `10.2%`,
      and axis detection `8.4%`.
    - Validation:
      - `zig build test --summary all` passed `403/403`.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`
        reported exact parity with `mismatches=0`.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect`
        reported `557439 us`, checksum `38221731`.

- [x] Continue `auto_detect` optimization after the CLAHE pass.
  - Starting target order from the previous four-scan evidence:
    - Film extent remains the largest bucket. Connected-component labeling is
      the largest film substage, averaging about `137109 us` across the four
      3200 DPI scans; binary close averages about `62898 us`; geometry remains
      smaller but still eligible.
    - CLAHE still averages about `136840 us`; future CLAHE work should be
      guided by a deeper breakdown into input quantization, histogram/LUT
      construction, output interpolation, and u8-to-f64 widening.
    - Rotation averages about `104280 us`; further work should measure whether
      parallel rows, f32 intermediates, or a fixed-point interpolation path can
      preserve final frame/rebate parity and fixture tolerance.
    - Keep optimizing cheap stages too when the change removes a real pass,
      branch, allocation, or strided memory access and has exact parity
      evidence.
  - Required evidence remains unchanged: ReleaseFast before/after stage
    timings on real scans, exact frame/rebate parity, `zig build test --summary
    all`, and updates to this plan plus `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-19:
    - Reworked connected-component flood fill to use explicit 8-neighbor checks
      instead of nested 3x3 neighbor loops while preserving the same in-place
      private mask consumption and best-component mask output.
    - Added thresholded parallel row execution for the large real-scan rotation
      and CLAHE output passes. Small fixtures remain serial below the named
      `1_000_000` item/pixel thresholds, and real scans use available cores
      while leaving one core for the system.
    - Added thresholded parallel conversion passes around CLAHE:
      `f64 -> inverted u8`, `u8 -> inverted u8`, and `u8 -> f64`. This keeps the
      OpenCV-shaped CLAHE operation intact and only removes single-threaded
      buffer walks on scan-sized previews.
    - Updated `scan_0004_rgbir_3200dpi.tiff` `auto_detect_breakdown`:
      total `277906 us`; film extent `129079 us`; Otsu `4953 us`, mask
      `2779 us`, close `45001 us`, component `58494 us`, geometry `15253 us`;
      rotation `12272 us`; CLAHE `31668 us`; axis total `37897 us`; frames `5`,
      aspect `24:36`, checksum `38221731`, `frame_max_abs=0`,
      `rebate_max_abs=0`, `mismatches=0`.
    - Normal `auto_detect` on `scan_0004_rgbir_3200dpi.tiff` now reports
      `305134 us`, frames `5`, aspect `24:36`, checksum `38221731`, versus the
      refreshed `765814 us` baseline (`2.510x`) and the previous pass's
      `557439 us` (`1.827x`).
    - Across `scan_0001` through `scan_0004` real 3200 DPI RGBIR scans, average
      `auto_detect_breakdown` improved from the initial `870938 us` to
      `362798 us` (`2.401x`), and from the previous optimized pass's `621128 us`
      to `362798 us` (`1.712x`). Updated average stage shares are film extent
      about `48.0%`, grayscale prep `16.5%`, axis detection `14.1%`, CLAHE
      `9.9%`, and rotation `3.4%`.
    - Validation:
      - `zig build test --summary all` passed `403/403`.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`
        reported exact parity with `mismatches=0`.
      - Four-scan real-data refresh ran `auto_detect_breakdown` on
        `scan_0001_rgbir_3200dpi.tiff` through
        `scan_0004_rgbir_3200dpi.tiff`, with `frame_max_abs=0`,
        `rebate_max_abs=0`, and `mismatches=0` for every scan.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect`
        reported `305134 us`, checksum `38221731`.

- [x] Continue `auto_detect` optimization from the latest stage ranking.
  - Starting target order from the previous four-scan evidence:
    - Film extent is again the dominant bucket, averaging about `173986 us`.
      Within it, connected-component labeling averages about `77197 us`, binary
      close about `62164 us`, geometry about `21320 us`, Otsu about `5013 us`,
      and mask generation about `4556 us`.
    - Initial grayscale preparation averages about `59683 us`. The next pass
      should check whether `prepareDetectionGrayImage` can be parallelized or
      specialized for the common 16-bit RGB scanner-preview path without
      changing the exact Python grayscale quantization.
    - Axis detection averages about `51005 us`; substage evidence points at
      profile construction, DTW, angle fitting, and cross-strip refinement as
      the relevant work, not output assembly.
    - CLAHE now averages about `35953 us` and rotation about `12418 us`; avoid
      chasing those before the larger buckets unless the change is an obvious
      pass removal with exact parity evidence.
  - Required evidence remains unchanged: ReleaseFast before/after stage
    timings on real scans, exact frame/rebate parity, `zig build test --summary
    all`, and updates to this plan plus `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-19:
    - Parallelized `prepareDetectionGrayImage` for scan-sized previews while
      keeping the exact Python grayscale quantization rules:
      - 16-bit RGB still uses integer `(r + g + b) / (3 * 256)`;
      - 8-bit RGB still uses the weighted rounded path;
      - grayscale inputs still use the Python-compatible sample-to-u8 helper;
      - both the retained u8 buffer and f64 buffer are filled from the same
        prepared byte.
    - The worker path uses the existing named conversion threshold so small
      fixtures and tiny images remain serial.
    - Updated `scan_0004_rgbir_3200dpi.tiff` `auto_detect_breakdown`:
      total `253750 us`; prepare gray `8529 us`; film extent `129155 us`;
      Otsu `3681 us`, mask `2871 us`, close `45522 us`, component `59270 us`,
      geometry `15303 us`; rotation `11585 us`; CLAHE `33725 us`; axis total
      `45596 us`; frames `5`, aspect `24:36`, checksum `38221731`,
      `frame_max_abs=0`, `rebate_max_abs=0`, `mismatches=0`.
    - Normal `auto_detect` on `scan_0004_rgbir_3200dpi.tiff` now reports
      `275746 us`, frames `5`, aspect `24:36`, checksum `38221731`, versus the
      refreshed `765814 us` baseline (`2.777x`) and the previous pass's
      `305134 us` (`1.107x`).
    - Across `scan_0001` through `scan_0004` real 3200 DPI RGBIR scans, average
      `auto_detect_breakdown` improved from the initial `870938 us` to
      `313237 us` (`2.780x`), and from the previous optimized pass's `362798 us`
      to `313237 us` (`1.158x`). Updated average stage shares are film extent
      about `55.5%`, axis detection `16.2%`, CLAHE `11.5%`, rotation `3.8%`,
      and grayscale prep `3.5%`.
    - Validation:
      - `zig build test --summary all` passed `403/403`.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`
        reported exact parity with `mismatches=0`.
      - Four-scan real-data refresh ran `auto_detect_breakdown` on
        `scan_0001_rgbir_3200dpi.tiff` through
        `scan_0004_rgbir_3200dpi.tiff`, with `frame_max_abs=0`,
        `rebate_max_abs=0`, and `mismatches=0` for every scan.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect`
        reported `275746 us`, checksum `38221731`.

- [x] Continue `auto_detect` optimization from the post-prep stage ranking.
  - Starting target order from the previous four-scan evidence:
    - Film extent is now clearly dominant, averaging about `173762 us`.
      Within it, connected-component labeling averages about `75581 us`, binary
      close about `62745 us`, geometry about `21290 us`, Otsu about `6123 us`,
      and mask generation about `4540 us`.
    - Axis detection averages about `50740 us`; substage evidence points at
      profile construction, DTW, angle fitting, and cross-strip refinement as
      the relevant work.
    - CLAHE averages about `36081 us`; rotation averages about `11837 us`;
      grayscale prep now averages only about `10938 us`.
    - Next film-extent work should prefer exact algorithm-preserving changes:
      parallel row windows for binary close, lower-allocation component
      bookkeeping, or a parity-backed connected-component rewrite. Do not change
      Otsu, close semantics, component connectivity, rotated extent geometry, or
      failure thresholds without a Python-oracle fixture and explicit approval.
  - Required evidence remains unchanged: ReleaseFast before/after stage
    timings on real scans, exact frame/rebate parity, `zig build test --summary
    all`, and updates to this plan plus `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-19:
    - Replaced scan-sized connected-component flood fill with a run-length
      8-connected component pass:
      - rows are encoded as true-runs;
      - adjacent-row runs are unioned when their x ranges overlap or touch,
        preserving the same 8-connectivity as the BFS path;
      - component stats track area, bounds, and first row-major index so
        largest-component tie behavior remains stable;
      - the final largest component is materialized back into the same boolean
        `component_mask` consumed by rotated-extent geometry;
      - small masks below the named threshold still use the existing BFS path.
    - Tested a parallel row/column binary-close split and rejected it. It
      preserved parity but regressed the four-scan average, so it was removed.
      Binary close remains the largest film-extent substage and needs a
      different exact approach.
    - Reduced angle-stage allocation churn by precomputing the profile and
      gradient Gaussian kernels once, reusing scratch buffers, and storing the
      20 angle gradients in one contiguous allocation. The reflect-101 Gaussian
      convolution and gradient math remain unchanged.
    - Updated `scan_0004_rgbir_3200dpi.tiff` `auto_detect_breakdown`:
      total `201144 us`; prepare gray `8990 us`; film extent `74999 us`;
      Otsu `3679 us`, mask `2931 us`, close `45532 us`, component `5345 us`,
      geometry `15164 us`; rotation `11897 us`; CLAHE `33336 us`; axis total
      `46171 us`; frames `5`, aspect `24:36`, checksum `38221731`,
      `frame_max_abs=0`, `rebate_max_abs=0`, `mismatches=0`.
    - Normal `auto_detect` on `scan_0004_rgbir_3200dpi.tiff` now reports
      `225901 us`, frames `5`, aspect `24:36`, checksum `38221731`, versus the
      refreshed `765814 us` baseline (`3.390x`) and the previous pass's
      `275746 us` (`1.221x`).
    - Across `scan_0001` through `scan_0004` real 3200 DPI RGBIR scans, average
      `auto_detect_breakdown` improved from the initial `870938 us` to
      `244486 us` (`3.562x`), and from the previous optimized pass's `313237 us`
      to `244486 us` (`1.281x`). Updated average stage shares are film extent
      about `42.6%`, axis detection `20.4%`, CLAHE `14.3%`, rotation `5.0%`,
      and grayscale prep `4.5%`. Within film extent, binary close is now
      dominant at about `62839 us`; run-length component labeling averages only
      about `7167 us`.
    - Validation:
      - `zig build test --summary all` passed `403/403`.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`
        reported exact parity with `mismatches=0`.
      - Four-scan real-data refresh ran `auto_detect_breakdown` on
        `scan_0001_rgbir_3200dpi.tiff` through
        `scan_0004_rgbir_3200dpi.tiff`, with `frame_max_abs=0`,
        `rebate_max_abs=0`, and `mismatches=0` for every scan.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect`
        reported `225901 us`, checksum `38221731`.

- [x] Continue `auto_detect` optimization after run-length component labeling.
  - Starting target order from the previous four-scan evidence:
    - Binary close is the largest remaining `auto_detect` substage, averaging
      about `62839 us`. The rejected row/column threading attempt shows thread
      overhead and memory traffic can erase gains; next attempts should focus on
      exact pass reduction, better memory layout, or a benchmarked morphology
      representation change with fixture parity.
    - Axis detection averages about `49960 us`; angle fitting and profile
      construction are still the largest substages, with DTW occasionally
      visible depending on the scan.
    - CLAHE averages about `35050 us`; rotation averages about `12313 us`;
      grayscale prep averages about `11033 us`.
    - Keep preserving Python-oracle behavior: do not change Otsu, close
      semantics, component connectivity, rotated extent geometry, edge snapping,
      angle estimation, or cross-strip refinement without a parity fixture and
      explicit approval.
  - Required evidence remains unchanged: ReleaseFast before/after stage
    timings on real scans, exact frame/rebate parity, `zig build test --summary
    all`, and updates to this plan plus `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-19:
    - Optimized the exact binary close without changing its square-kernel,
      separable semantics:
      - horizontal dilation now scans true-runs in each row and fills the
        radius-expanded output ranges;
      - horizontal erosion now scans true-runs and fills only positions whose
        clipped horizontal window is fully contained in the run;
      - vertical dilation/erosion remain the row-major rolling-count passes
        because the earlier row/column-threaded attempt regressed.
    - Optimized 1D Gaussian blur call sites used by profiles, angle estimation,
      cross-strip refinement, and gradient smoothing:
      - interior samples now use direct contiguous indexing;
      - only edge samples call the reflect-101 index helper;
      - kernel order and reflect-101 edge behavior are unchanged.
    - Reduced profile setup for vertical strips with a segmented row pass:
      cross-profile accumulation still proceeds left-to-right across each row,
      while the three non-overlapping band sums are accumulated during the same
      row walk. A branch-per-pixel membership version was tested and rejected
      because it regressed profile time.
    - Updated `scan_0004_rgbir_3200dpi.tiff` `auto_detect_breakdown`:
      total `186829 us`; prepare gray `9005 us`; film extent `63997 us`;
      Otsu `3709 us`, mask `2849 us`, close `33901 us`, component `5589 us`,
      geometry `15107 us`; rotation `12163 us`; CLAHE `34456 us`; axis total
      `37616 us`; profiles `8256 us`, gradients `362 us`, DTW `10172 us`,
      angle `16418 us`, cross-strip `2365 us`; frames `5`, aspect `24:36`,
      checksum `38221731`, `frame_max_abs=0`, `rebate_max_abs=0`,
      `mismatches=0`.
    - Normal `auto_detect` on `scan_0004_rgbir_3200dpi.tiff` now reports
      `205658 us`, frames `5`, aspect `24:36`, checksum `38221731`, versus the
      refreshed `765814 us` baseline (`3.724x`) and the previous pass's
      `225901 us` (`1.098x`).
    - Across `scan_0001` through `scan_0004` real 3200 DPI RGBIR scans, average
      `auto_detect_breakdown` improved from the initial `870938 us` to
      `221766 us` (`3.927x`), and from the previous optimized pass's `244486 us`
      to `221766 us` (`1.102x`). Updated average stage shares are film extent
      about `40.2%`, axis detection `18.7%`, CLAHE `16.2%`, rotation `5.6%`,
      and grayscale prep `5.0%`.
    - Validation:
      - `zig build test --summary all` passed `403/403`.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`
        reported exact parity with `mismatches=0`.
      - Four-scan real-data refresh ran `auto_detect_breakdown` on
        `scan_0001_rgbir_3200dpi.tiff` through
        `scan_0004_rgbir_3200dpi.tiff`, with `frame_max_abs=0`,
        `rebate_max_abs=0`, and `mismatches=0` for every scan.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect`
        reported `205658 us`, checksum `38221731`.

- [x] Continue `auto_detect` optimization after run-based close and profile
      reductions.
  - Starting target order from the previous four-scan evidence:
    - Binary close remains the largest single substage, averaging about
      `47895 us`. The accepted horizontal run pass helped; remaining work likely
      needs exact vertical-pass reduction, a safe representation change, or a
      different way to feed the run-length component stage.
    - Axis detection averages about `41457 us`; angle fitting averages about
      `19401 us`, profile setup about `9894 us`, and DTW about `8266 us`.
    - CLAHE averages about `35934 us`; rotation averages about `12341 us`;
      grayscale prep averages about `10986 us`.
    - Keep preserving Python-oracle behavior: do not change Otsu, close
      semantics, component connectivity, rotated extent geometry, edge snapping,
      angle estimation, or cross-strip refinement without a parity fixture and
      explicit approval.
  - Required evidence remains unchanged: ReleaseFast before/after stage
    timings on real scans, exact frame/rebate parity, `zig build test --summary
    all`, and updates to this plan plus `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-19:
    - Tested exact vertical run morphology inside `closeBinaryMask` and rejected
      it. It preserved exact frame/rebate parity but regressed close time because
      the column scans and writes are strided; the rolling-count vertical passes
      remain faster.
    - Parallelized angle-gradient construction:
      - the 20 angle-strip profile/gradient builds now run in disjoint worker
        chunks for scan-sized work;
      - each worker writes disjoint profile, scratch, gradient, and position
        slots;
      - Theil-Sen input order, Gaussian kernels, reflect-101 behavior, and
        gradient math are unchanged.
    - Parallelized CLAHE LUT construction:
      - the 64 tile histograms/LUTs are built in disjoint tile ranges;
      - per-tile histogram accumulation order and clipping/LUT math are
        unchanged;
      - CLAHE output interpolation remains the existing row-parallel path.
    - Updated `scan_0004_rgbir_3200dpi.tiff` `auto_detect_breakdown` from the
      four-scan refresh: total `179503 us`; prepare gray `9377 us`; film extent
      `73693 us`; Otsu `3728 us`, mask `3031 us`, close `41423 us`, component
      `7702 us`, geometry `15060 us`; rotation `12009 us`; CLAHE `26063 us`;
      axis total `26697 us`; profiles `8406 us`, gradients `361 us`,
      DTW `10460 us`, angle `5051 us`, cross-strip `2375 us`; frames `5`,
      aspect `24:36`, checksum `38221731`, `frame_max_abs=0`,
      `rebate_max_abs=0`, `mismatches=0`.
    - Normal `auto_detect` on `scan_0004_rgbir_3200dpi.tiff` now reports
      `176017 us`, frames `5`, aspect `24:36`, checksum `38221731`, versus the
      refreshed `765814 us` baseline (`4.351x`) and the previous pass's
      `205658 us` (`1.168x`).
    - Across `scan_0001` through `scan_0004` real 3200 DPI RGBIR scans, average
      `auto_detect_breakdown` improved from the initial `870938 us` to
      `203021 us` (`4.290x`), and from the previous optimized pass's `221766 us`
      to `203021 us` (`1.092x`). Updated average stage shares are film extent
      about `45.0%`, axis detection `13.5%`, CLAHE `13.3%`, rotation `6.1%`,
      and grayscale prep `5.4%`.
    - Validation:
      - `zig build test --summary all` passed `403/403`.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`
        reported exact parity with `mismatches=0`.
      - Four-scan real-data refresh ran `auto_detect_breakdown` on
        `scan_0001_rgbir_3200dpi.tiff` through
        `scan_0004_rgbir_3200dpi.tiff`, with `frame_max_abs=0`,
        `rebate_max_abs=0`, and `mismatches=0` for every scan.
      - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect`
        reported `176017 us`, checksum `38221731`.

- [x] Continue `auto_detect` optimization after parallel angle and CLAHE LUT
      construction.
  - Completed 2026-05-19: tried portable Zig `@Vector` SIMD on the clean
    independent loops and kept only measured wins:
    - added an 8-lane RGB16 grayscale-prep vector path for the common
      3-channel, 16-bit scanner preview input;
    - added a 32-lane `u8` inversion path for non-rotated CLAHE prep;
    - added a 4-lane `u8 -> f64` conversion path after CLAHE;
    - added a 4-lane f64 dot-product path for the Gaussian blur interior;
    - tested and rejected a vertical morphology count-loop SIMD path because it
      preserved exact parity but regressed `scan_0004` `film_close_us` from the
      mid-30 ms range to `52392 us`.
  - Evidence:
    - Baseline before this SIMD pass:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`
      reported `166426 us`, with `prepare_gray_us=8662`,
      `film_extent_us=64435`, `film_close_us=34444`, `clahe_us=26620`,
      `axis_total_us=26199`, `gradients_us=364`, exact parity, and checksum
      `38221731`.
    - Accepted SIMD pass:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`
      reported `166139 us` in the four-scan refresh row, with
      `prepare_gray_us=9306`, `film_extent_us=73063`, `film_close_us=38239`,
      `clahe_us=24361`, `axis_total_us=17675`, `gradients_us=163`, exact
      parity, and checksum `38221731`.
    - Normal production command:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect`
      reported `173351 us`, frames `5`, aspect `24:36`, checksum `38221731`.
    - Four-scan refresh over the currently present real scan files
      `scan_0001_rgbir_3200dpi.tiff` through `scan_0004_rgbir_3200dpi.tiff`
      reported exact frame/rebate parity on every row and average
      `auto_detect_breakdown` `196084 us`, down from the prior documented
      `203021 us`.
    - `zig build test --summary all` passed `403/403`.

Autonomous performance iteration map:

- Always choose the first unchecked unblocked item below. If a stage is blocked
  by hardware, platform, or missing live data, record the blocker and move to
  the next unblocked item.
- While the active user direction is performance iteration, this map takes
  precedence over later release-QA and UI screenshot checklist items. Release
  screenshots are useful for final native UI readiness, but they do not answer
  performance questions and must not be selected during the performance loop
  unless the user explicitly asks to switch back to UI QA.
- Process image switching and quick preview load: completed by the
  `load_preview` item below; return only if fresh UI timing shows it has become
  dominant again.
- Full-resolution detected-frame export: completed by the
  `export_detected_frames` breakdown item below. Return only after a fresh
  ranking shows it is again the best same-behavior target.
- Frame autodetection and film strip selection: partially optimized and still
  headless-testable; continue only after refreshing the ranking so the next
  pass is driven by current data rather than stale checklist text.
- Processing preview and inversion: keep the accepted f32 density-LUT path; do
  not return to the just-optimized density loop until larger waits are reduced
  or the user explicitly asks.
- Scanner startup, scanner preview, and full-resolution scan: measure first and
  keep hardware/live checks gated. On Linux, live scanner timing is blocked
  until SANE enumerates the USB-visible V600. Avoid adding startup probes or
  hot-path discovery while chasing performance.

- [x] Break down and optimize `load_preview` / Process image switching.
  - Why this was selected: current evidence put `load_preview` around
    `1327413 us`
    on `scan_0004_rgbir_3200dpi.tiff`, which is now larger than
    `auto_detect` and first-use inverted preview. It is frequent, headless
    testable from real scan files, and likely contains avoidable I/O or image
    preparation duplication.
  - Scope:
    - Add a parity-checked `load_preview_breakdown` benchmark case if one does
      not already exist.
    - Break down at least: TIFF open/IFD parsing, RGB page read/decode, IR page
      discovery/metadata work, preview geometry, resize/downsample, stretch or
      normalization, CLAHE or preview enhancement, JPEG/preview byte encoding,
      and any buffer copies into the workflow result.
    - Compare the staged breakdown result against production `load_preview` for
      preview dimensions, scale, RGB checksum, IR metadata availability, JPEG or
      preview-buffer checksum, and any visible status fields.
    - Optimize only same-behavior work: remove duplicate reads/copies, fuse
      exact pass-compatible conversions, cache per-image metadata, avoid
      re-decoding pages for metadata already discovered, and prefer row-major
      contiguous loops.
    - Do not change preview max-px semantics, preview color/stretch behavior,
      CLAHE behavior, page selection, metadata handling, or config persistence
      without explicit parity evidence and approval.
  - Completed 2026-05-19:
    - Added `loadRgbPageWithMetadata` and timed variants so Process image
      switching opens the TIFF once, reads DPI, RGB page data, and IR page
      metadata in one pass instead of doing separate metadata and page reads.
    - Added `loadQuickPreviewBreakdown` /
      `generateQuickPreviewBreakdown` and a parity-checked
      `load_preview_breakdown` benchmark case. The breakdown compares staged
      output against production `load_preview` for preview dimensions, source
      dimensions, DPI, preview scale, RGB/IR metadata, `preview_raw`,
      `preview_rgb8`, and JPEG bytes.
    - Replaced the OpenCV helper's per-channel content-pixel vectors and
      `std::sort` percentiles with exact 256-bin u8 histograms using the same
      NumPy linear percentile rank/interpolation formula. Because the stretch
      input is u8, this is exact rather than approximate.
    - Applied stretch directly over the interleaved RGB preview rows, avoiding
      split/merge work before CLAHE while leaving OpenCV CLAHE, JPEG quality,
      preview max-px semantics, IR metadata handling, and output bytes
      unchanged.
  - Evidence:
    - Fresh pre-change baseline:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case load_preview`
      reported `1338976 us`, dimensions `1738x8192`, and checksum
      `6666414344`.
    - First breakdown before percentile optimization:
      `load_preview_breakdown` on `scan_0004_rgbir_3200dpi.tiff` reported
      total `1284464 us`, reference `1328864 us`, `rgb_read_us=321845`,
      `quick_preview_us=937390`, `invert_stretch_us=723859`, checksum
      `6666414344`, and exact staged-vs-production parity:
      `raw_max_abs=0`, `rgb_max_abs=0`, `jpeg_max_abs=0`, `mismatches=0`.
    - Final production command:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case load_preview`
      reported `647912 us`, checksum `6666414344`, a `2.066x` speedup over
      the fresh same-scan baseline and a `3.482x` cumulative speedup over the
      earlier `2255972 us` two-pass/full-IR baseline.
    - Final `scan_0004_rgbir_3200dpi.tiff` breakdown reported total
      `604474 us`, reference `648119 us`, `rgb_read_us=312098`,
      `quick_preview_us=267162`, `invert_stretch_us=66142`,
      `clahe_us=57794`, checksum `6666414344`, and exact raw/RGB/JPEG parity.
    - Four-scan real-data refresh over `scan_0001_rgbir_3200dpi.tiff` through
      `scan_0004_rgbir_3200dpi.tiff` reported exact parity for every row.
      Breakdown average was `569861 us`; production `load_preview` average was
      `629568 us`.
    - `zig build test --summary all` passed `403/403`.

- [x] Break down and optimize full-resolution detected-frame export.
  - Why this is second: multi-frame export improved from `18125889 us` serial
    to `5981208 us` parallel for five detected frames, and a later refresh
    measured `4138270 us` after other processing wins, but it remains the
    largest end-to-end wait after image loading.
  - Scope:
    - Add or extend an `export_detected_frames_breakdown` benchmark that uses
      real automatic frame detection, scales detected preview rectangles to
      full resolution, and exports those exact geometries.
    - Break down at least: TIFF RGB/IR load, IR alignment, frame crop/rotation,
      IR clean/mask/inpaint, inversion, display render, encoder/write, metadata
      write, per-worker setup, and scheduler wait/merge time.
    - Keep the Python-visible export contract: same output variants, paths,
      metadata, Dmin/rebate behavior, film-stock math, IR-clean behavior,
      completion-order result collection, and deterministic frame-worker seeds.
    - Optimize CPU first. GPU export is not currently a win on large real scans;
      revisit only after CPU-side staging/copy costs are reduced or render-stage
      GPU residency changes the boundary cost.
  - Required evidence before checking off:
    - Baseline and after:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames`
      plus the new breakdown case.
    - Include selected worker count, CPU/memory limits, per-worker peak memory
      estimate, total output count, metadata equality, checksums or max/RMS
      parity for output buffers when available, and wall-clock speedup.
    - `zig build test --summary all`.
    - Update this plan and `docs/PERFORMANCE_STRATEGY.md` with accepted and
      rejected attempts.
  - Completed 2026-05-19:
    - Added optional export timing surfaces without changing the production
      request or output contract:
      - `ExportWorkflowTimings` records output-dir setup, full-image load,
        Dmin, IR alignment, path setup, parallelism planning, frame processing,
        worker setup, scheduler wait, result merge, progress construction, and
        final message construction.
      - `ProcessFrameTimings` records RGB crop, IR crop, IR clean, IR-negative
        preparation, inversion, display render, output rotation, metadata JSON,
        and TIFF write time. IR stage fields are populated when the selected
        output variants require IR; they are zero for the current inv-only
        detected-frame benchmark.
      - Added `export_detected_frames_breakdown`; it runs the same autodetected
        full-resolution frame geometries as `export_detected_frames`, compares
        an untimed reference export against the timed export by file set,
        private metadata JSON, and TIFF pixels, and fails on any mismatch.
    - Optimized `export.cropFrame` by sampling the interleaved RGB image
      directly with the same rotated-rectangle, reflect-border, and bilinear
      math. The old path materialized a full-size single-channel plane for
      each channel and then cropped each plane separately.
    - Routed RGB-only exports through TIFF page 0 instead of the RGB+IR page
      loader when no selected output variant needs IR.
    - Parallelized TIFF sample-to-f64 expansion for large images. This keeps
      the same full-image f64 representation for the accepted path but reduces
      wall time in the load bucket.
  - Evidence:
    - Initial breakdown before the crop/load work:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_breakdown`
      reported timed `4309330 us`, reference `4326493 us`, `load_full_us=1382038`,
      `frame_processing_us=2775287`, aggregate `rgb_crop_us=9537480`,
      `inversion_us=1828898`, `display_render_us=680774`, `write_us=346634`,
      and exact parity: `max_abs=0`, `mismatches=0`,
      `metadata_equal=true`, `file_set_equal=true`.
    - After direct interleaved crop:
      `export_detected_frames_breakdown` on `scan_0004_rgbir_3200dpi.tiff`
      reported timed `2496705 us`, reference `2547008 us`,
      `load_full_us=1386866`, `frame_processing_us=942406`, and aggregate
      `rgb_crop_us=910877`, with exact TIFF/metadata parity.
    - Final after RGB-only load routing and parallel sample-to-f64 expansion:
      `export_detected_frames_breakdown` on `scan_0004_rgbir_3200dpi.tiff`
      reported timed `1758568 us`, reference `1819796 us`,
      `load_full_us=614686`, `frame_processing_us=995968`,
      `rgb_crop_us=959419`, `inversion_us=1730664`,
      `display_render_us=684521`, `write_us=571604`, `workers=5`,
      `cpu_limit=31`, `mem_limit=25`, adjusted peak
      `2159506560` bytes/worker, and exact parity.
    - Final production command:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames`
      reported parallel `1820484 us`, serial `4727361 us`, `workers=5`,
      `cpu_limit=31`, `mem_limit=26`, adjusted peak
      `2159506560` bytes/worker, and `speedup_x1000=2596`.
      This is `2.274x` faster than the previous `4138270 us` refresh and
      `3.286x` faster than the older `5981208 us` parallel baseline.
    - Real-scan spread check:
      `export_detected_frames_breakdown` on `scan_0003_rgbir_3200dpi.tiff`
      reported timed `1644338 us`, reference `1742743 us`,
      `load_full_us=521177`, `frame_processing_us=992584`, exact parity, and
      the normal `export_detected_frames` command reported parallel
      `1681612 us`, serial `4580094 us`, `workers=5`.
    - `zig build test --summary all` passed `403/403`.

- [x] Continue `auto_detect` optimization after the first portable SIMD pass.
  - Current target order from the latest four-scan evidence:
    - Film extent remains the largest bucket at about `93032 us` average. Binary
      close is still the largest film substage at about `49379 us`; vertical
      run morphology and direct count-loop SIMD were both rejected, so future
      close work should look for exact pass reduction, a cache-friendly bitset
      representation, or feeding the run-length component stage more directly.
    - Axis detection averages about `23066 us`; profile setup averages about
      `10018 us`, DTW about `4532 us`, angle about `5872 us`, and cross-strip
      about `2398 us`.
    - CLAHE averages about `25769 us`; further CLAHE work should break down LUT
      construction, output interpolation, and conversion costs before changing
      code.
    - Keep preserving Python-oracle behavior: do not change Otsu, close
      semantics, component connectivity, rotated extent geometry, edge snapping,
      angle estimation, or cross-strip refinement without a parity fixture and
      explicit approval.
  - Required evidence remains unchanged: ReleaseFast before/after stage
    timings on real scans, exact frame/rebate parity, `zig build test --summary
    all`, and updates to this plan plus `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-19:
    - Replaced the DTW inner-loop square from `std.math.pow(diff, 2.0)` to
      `diff * diff`. This preserves the same DTW cost function while avoiding
      the generic power helper in a hot loop.
    - Preallocated film-extent boundary point storage from the component bounds
      before collecting boundary pixels for convex hull/min-area rectangle
      geometry. The collected points and geometry algorithm are unchanged.
    - Baseline immediately before this pass:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect_breakdown`
      reported `detect_us=158824`, `film_extent_us=62538`,
      `film_close_us=32337`, `film_geometry_us=15136`,
      `axis_total_us=24658`, `dtw_us=9804`, frames `5`, aspect `24:36`,
      checksum `38221731`, and exact frame/rebate parity.
    - After the accepted pass, the same command on
      `scan_0004_rgbir_3200dpi.tiff` reported `detect_us=146591`,
      `film_extent_us=63202`, `film_close_us=34028`,
      `film_geometry_us=14917`, `axis_total_us=18017`, `dtw_us=1564`,
      frames `5`, aspect `24:36`, checksum `38221731`,
      `frame_max_abs=0`, `rebate_max_abs=0`, and `mismatches=0`.
      The DTW substage is noisy, but the breakdown total moved from
      `158824 us` to `146591 us` with exact output parity.
    - `scan_0003_rgbir_3200dpi.tiff` spread check reported
      `detect_us=174011`, `film_extent_us=73674`, `axis_total_us=24037`,
      `dtw_us=9053`, frames `5`, checksum `38975998`, and exact
      frame/rebate parity.
    - Normal production command:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case auto_detect`
      reported `188485 us`, frames `5`, aspect `24:36`, checksum
      `38221731`. This single-command wall time is noisy, so the accepted
      evidence for this pass is the parity-checked staged breakdown.
    - `zig build test --summary all` passed `403/403`.

- [x] Revisit processing preview inversion only after load/export/autodetect
      work or if UI latency data points back to it.
  - Current evidence: `inverted_preview_f32_breakdown` measured about
    `122313 us` on `scan_0004_rgbir_3200dpi.tiff`, with `invert_us=68753` and
    `output_write_us=52157`. This is no longer the largest Process-tab cost,
    but it is still a good target once larger waits are reduced.
  - Scope:
    - Keep the accepted f32 density-LUT path and final u8/u16 tolerance rules.
    - Look for output-write fusion, scene-buffer lifetime reduction,
      cache-friendly display LUT application, and safe SIMD/parallelism in
      remaining per-pixel loops.
    - Do not replace the `invert_negative` algorithm, film-stock profile math,
      robust range estimator, display LUT semantics, or final quantization
      tolerance without explicit approval.
  - Required evidence before checking off:
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case inverted_preview_f32_breakdown`.
    - Report wall time, stage split, final `u8` max/RMS/MSE, checksum, memory
      changes, and any rejected SIMD/GPU attempts.
    - `zig build test --summary all`.
  - Completed 2026-05-19:
    - Parallelized the f32 preview display-LUT write in
      `renderToDisplayU8F32` for large preview buffers. The range estimate,
      LUT contents, f32 table-index arithmetic, channel order, and final u8
      quantization are unchanged; workers write disjoint pixel ranges.
    - Memory behavior: no extra persistent image buffer is introduced. Large
      previews allocate only short-lived thread/context arrays around the same
      output buffer that production already returned.
    - Baseline immediately before this pass:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case inverted_preview_f32_breakdown`
      reported `production_us=126523`, `manual_total_us=119743`,
      `invert_us=66599`, serial mirror `output_write_us=50408`,
      `max_abs=0`, `mismatches=0`, checksum `3912224310`, exact-path
      comparison `exact_max_abs=2`, `exact_mse=0.000002130`, and
      `exact_mismatches=79`.
    - After the accepted pass, the same command on
      `scan_0004_rgbir_3200dpi.tiff` reported `production_us=85910` with the
      serial manual mirror still byte-identical: `max_abs=0`, `rms=0`,
      `mismatches=0`, checksum `3912224310`. The manual split remains useful
      as a serial comparison surface and reported `invert_us=69018`,
      `range_us=1273`, and serial `output_write_us=50123`.
    - `scan_0003_rgbir_3200dpi.tiff` spread check reported
      `production_us=84269`, `manual_total_us=132749`, `invert_us=80742`,
      serial `output_write_us=49715`, exact production-vs-manual bytes, and
      checksum `3387841946`.
    - `zig build test --summary all` passed `403/403`.

- [x] Refresh the Process performance ranking before selecting more non-scanner
      optimization work.
  - Why this is next: the last several checked items changed the relative cost
    of preview load, detected-frame export, autodetect, rebate sampling, and
    inverted preview. The old "next target" notes are stale enough that the
    next optimization pass should be selected from a fresh ReleaseFast ranking
    on real scan data, not from release-QA checklist order.
  - Scope:
    - Use the ambient nix shell and direct Zig commands only. Do not run
      `nix develop`, `nix-shell`, `nix build`, `nix flake check`, or
      `nix search`.
    - Run current production timing on
      `scans/scan_0004_rgbir_3200dpi.tiff` for at least:
      `load_preview`, `auto_detect`, `rebate`, `inverted_preview_f32_breakdown`,
      and `export_detected_frames`.
    - Run the matching staged breakdown for the largest current production
      bucket: `load_preview_breakdown`, `auto_detect_breakdown`, or
      `export_detected_frames_breakdown` as indicated by the ranking.
    - Run at least one spread check on `scans/scan_0003_rgbir_3200dpi.tiff` for
      the selected largest bucket before starting code changes.
    - Rank by user-visible wall time first, then by stage breakdown and
      optimization risk. Include dimensions, frame count, worker count where
      applicable, checksums, `max_abs`/RMS/mismatch metrics, and any metadata
      equality evidence the benchmark reports.
    - Select the first same-behavior optimization target from the fresh data.
      Do not switch to UI screenshots, native UI release QA, packaging, Nix
      validation, or parked macOS work while this checkpoint is active.
  - Required evidence before checking off:
    - Exact benchmark commands and outputs summarized in this plan and in
      `docs/PERFORMANCE_STRATEGY.md`.
    - A ranked next-target decision with the reason it is safe to pursue under
      the Python-oracle/function-for-function parity rule.
    - `zig build test --summary all` after any code changes. If this checkpoint
      only records measurements and no source changes, record that no test rerun
      was needed beyond benchmark parity checks.
  - Completed 2026-05-19:
    - Refreshed the Process ranking on `scan_0004_rgbir_3200dpi.tiff` using
      direct ReleaseFast Zig commands:
      - `load_preview`: `649140 us`, checksum `6666414344`;
      - `auto_detect`: `164340 us`, frames `5`, aspect `24:36`, checksum
        `38221731`;
      - `rebate`: `435945 us`, Dmin
        `0.283915:0.422373:0.606312`;
      - `inverted_preview_f32_breakdown`: production `82646 us`, manual mirror
        `139090 us`, `max_abs=0`, `mismatches=0`, checksum `3912224310`;
      - `export_detected_frames`: before the no-op rotation fix, `1622925 us`,
        frames `5`, files `5`, workers `5`, serial `4411959 us`, checksum
        `19055`.
    - Selected `export_detected_frames` as the continuing target because it was
      still the largest user-visible wait by a wide margin. The matching
      breakdown on `scan_0004` reported `1625129 us`, `load_full_us=510167`,
      `frame_processing_us=958556`, aggregate `rgb_crop_us=929083`,
      `inversion_us=1705012`, `display_render_us=680585`,
      `output_rotation_us=193710`, `write_us=463837`, and exact
      timed-vs-reference parity (`max_abs=0`, `mismatches=0`,
      `metadata_equal=true`, `file_set_equal=true`). A `scan_0003` spread check
      reported `1543391 us` with exact parity.
    - Removed a same-behavior no-op rotation copy from
      `prepareInvertedPositiveOutputU16WithTimings`: Python `apply_rotation`
      returns the image unchanged for rotations other than `90`, `180`, and
      `270`, so Zig now returns the rendered `u16` buffer directly for those
      no-op rotations instead of allocating and copying a second full image.
    - After that change, `export_detected_frames_breakdown` on `scan_0004`
      reported `1569086 us`, `load_full_us=499770`,
      `frame_processing_us=912631`, aggregate `output_rotation_us=0`, and exact
      parity. The `scan_0003` spread check reported `1442871 us`, also with
      exact parity. The normal production command on `scan_0004` reported
      `1539625 us`, serial `4193699 us`, workers `5`, and checksum `18880`.
    - Current ranked Process waits are therefore: export `1539625 us`,
      `load_preview` `649140 us`, rebate `435945 us`, `auto_detect`
      `164340 us`, and production inverted preview `82646 us`.
    - `zig build test --summary all` passed `412/412`.

- [x] Reduce no-IR/provided-Dmin full-resolution export staging.
  - Why this is next: after no-op rotation removal, detected-frame export is
    still the dominant Process wait. The current inv-only benchmark has no IR
    work and receives Dmin up front, but the production workflow still loads
    the whole RGB page, expands the full scan to f64, then crops each frame from
    that f64 image before inversion. That is safe but wasteful for this common
    export shape.
  - Scope:
    - Preserve the Python export contract: same crop geometry, OpenCV-shaped
      reflect-border bilinear sampling, same Dmin/stock/render settings,
      output filenames, metadata JSON, completion-order collection, and final
      TIFF pixels within the accepted exact or explicit u16-LSB tolerance.
    - Add a benchmark or staging path that compares the current full-image f64
      route against a no-IR/provided-Dmin route that crops directly from the
      raw TIFF RGB sample buffer and materializes only frame crops.
    - Separately test whether the frame crop can enter the accepted f32
      density-LUT inversion/render path for full-resolution export. Push the
      accuracy comparison through final `u16` output, not just intermediate
      floats. Do not switch production to the f32 route unless the output error
      is within the approved final-output tolerance and the wall-clock win is
      meaningful.
    - Keep the old f64 path as fallback for IR exports, missing Dmin, custom
      nonlinear stock coefficients, GPU requests, and any case where the fast
      path cannot prove parity.
  - Required evidence before checking off:
    - Baseline and after
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_breakdown`.
    - At least one spread check on `scan_0003_rgbir_3200dpi.tiff`.
    - Stage timings for load, crop, inversion, render, write, worker count,
      memory estimate, wall-clock speedup, and final TIFF/metadata parity.
    - `zig build test --summary all`.
  - Completed 2026-05-19:
    - Added a guarded no-IR/provided-Dmin direct RGB crop route for inv-only
      exports. When no selected variant needs IR, Dmin is already provided,
      and only inverted output is requested, the workflow now loads the RGB
      TIFF page plus metadata, crops each frame directly from the TIFF sample
      buffer, and processes only the cropped frame. The existing full-image f64
      path remains the fallback for IR exports, missing Dmin, non-inverted
      variants, custom nonlinear coefficient rows, explicit GPU requests, and
      unsupported fast-path conditions.
    - Kept crop behavior tied to the existing Python-shaped export geometry:
      the direct TIFF crop uses the same rotated rectangle, reflect-border
      bilinear sampling, frame scaling, metadata, filenames, and worker result
      collection as the reference path. The RGB sampler was then tightened to
      compute the reflected sample coordinates once and load RGB together
      instead of running three independent per-channel sample paths.
    - Added a full-resolution f32 density-LUT export route for the safe
      provided-Dmin/default-light/no-dark-light CPU case with built-in or
      otherwise linear coefficients. Accuracy is measured through final `u16`
      output, not intermediate floats; the f64 path remains available for
      oracle comparison and unsupported export shapes.
  - Evidence:
    - Direct-crop staging before the RGB-together loop on
      `scan_0004_rgbir_3200dpi.tiff`:
      `export_detected_frames_breakdown` reported timed `1324307 us`,
      no-direct-crop reference `1539523 us`, exact TIFF/metadata parity
      (`max_abs=0`, `mismatches=0`, `metadata_equal=true`,
      `file_set_equal=true`), and production `export_detected_frames`
      reported `1333224 us`.
    - After RGB-together direct sampling, the same breakdown on `scan_0004`
      reported timed `1280965 us`, reference `1567751 us`,
      `rgb_crop_us=1045899`, exact TIFF/metadata parity, and production
      `export_detected_frames` reported `1279140 us`, serial `4048302 us`.
      The `scan_0003_rgbir_3200dpi.tiff` spread check reported timed
      `1213441 us`, reference `1438646 us`, also with exact parity.
    - The standalone full-resolution f32 LUT tradeoff benchmark on `scan_0004`
      reported f64 reference `484129 us`, f32 variant `227450 us`,
      `lut_build_us=1214`, `invert_us=119361`, `render_us=106873`,
      speedup `2.128x`, and final `u16 max_abs=1`, RMS `0.054239`,
      MSE `0.002941895`. The `scan_0003` spread check reported reference
      `456660 us`, variant `219494 us`, speedup `2.080x`, final
      `u16 max_abs=1`, RMS `0.052345`, and MSE `0.002740004`.
    - After production integration of the safe f32 LUT route,
      `export_detected_frames_breakdown` on `scan_0004` reported timed
      `997165 us`, no-direct-crop reference `1273769 us`, `workers=5`,
      `cpu_limit=31`, `mem_limit=28`, adjusted peak
      `2159506560` bytes/worker, `load_full_us=322084`,
      `frame_processing_us=635082`, aggregate `rgb_crop_us=1055382`,
      `inversion_us=628417`, `display_render_us=560723`, `write_us=419987`,
      and exact fast-path-vs-reference TIFF/metadata parity.
    - Final production command on `scan_0004`:
      `export_detected_frames` reported `1009255 us`, serial `2843707 us`,
      `workers=5`, `cpu_limit=31`, `mem_limit=28`, adjusted peak
      `2159506560` bytes/worker, and `speedup_x1000=2817`.
    - The `scan_0003` spread check after f32 integration reported
      `export_detected_frames_breakdown` timed `926099 us`, reference
      `1165373 us`, `load_full_us=276024`, `frame_processing_us=614576`,
      aggregate `rgb_crop_us=1043241`, `inversion_us=626996`,
      `display_render_us=556730`, `write_us=307985`, and exact
      TIFF/metadata parity.
    - `zig build test --summary all` passed `412/412`.

- [x] Continue Process export optimization from the direct-crop/f32 stage split.
  - Why this is next: live scanner timing remains blocked by SANE enumeration,
    and the current Process ranking still has `export_detected_frames` as the
    largest unblocked user-visible wait at about `1009255 us` on
    `scan_0004_rgbir_3200dpi.tiff`. The latest aggregate stage split across
    five frame workers is direct TIFF crop `1055382 us`, f32 density-LUT
    inversion `628417 us`, f32 display render `560723 us`, and write
    `419987 us`.
  - Scope:
    - Keep the same no-IR/provided-Dmin inv-only export contract and the same
      f64 reference/final-u16 tolerance used by the accepted f32 export path.
    - Start by reducing staging between direct TIFF crop and f32
      density-LUT inversion. The current fast path still materializes a full
      f64 crop before immediately interpolating density LUTs into a f32 scene.
      Test a fused direct-TIFF-crop-to-f32-scene route for the same guarded
      conditions, with the old f64 crop path retained as fallback and oracle.
    - Preserve crop geometry, reflect-border bilinear sampling, Dmin handling,
      stock coefficient gating, output metadata, filenames, worker scheduling,
      and completion-order result collection.
  - Required evidence before checking off:
    - Baseline and after
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_breakdown`.
    - At least one spread check on `scan_0003_rgbir_3200dpi.tiff`.
    - Stage timings for crop/fused inversion, render, write, worker count,
      memory estimate, wall-clock speedup, and final TIFF/metadata parity.
    - `zig build test --summary all`.
  - Completed 2026-05-19:
    - Added a fused direct-TIFF-crop-to-f32-scene route for the same guarded
      safe export shape already accepted for f32 density-LUT export. The path
      builds the f32 density LUT, samples TIFF RGB through the existing
      reflect-border bilinear sampler, immediately applies the linear
      density-transform coefficients into the f32 scene buffer, then renders
      and writes through the existing `u16` export path.
    - The old direct-TIFF-to-f64-crop path remains fallback for unsupported
      conditions. The f64 no-direct-crop route remains the benchmark reference,
      and final TIFF/metadata comparison remains enforced.
    - Timing note: the fused loop intentionally reports its combined
      crop-plus-density work in `inversion_us`, so `rgb_crop_us=0` for this
      fast path. Compare wall time and the combined old
      `rgb_crop_us + inversion_us` aggregate when evaluating this pass.
  - Evidence:
    - `zig build test --summary all` passed `412/412`.
    - `export_detected_frames_breakdown` on
      `scan_0004_rgbir_3200dpi.tiff` reported timed `893305 us`, no-direct
      reference `1278393 us`, `workers=5`, `cpu_limit=31`, `mem_limit=28`,
      adjusted peak `2159506560` bytes/worker, `load_full_us=336646`,
      `frame_processing_us=510911`, aggregate fused `inversion_us=1474796`,
      `display_render_us=561146`, `write_us=285799`, `rgb_crop_us=0`, and
      exact TIFF/metadata parity (`max_abs=0`, `mismatches=0`,
      `metadata_equal=true`, `file_set_equal=true`).
    - `export_detected_frames_breakdown` on
      `scan_0003_rgbir_3200dpi.tiff` reported timed `826455 us`, no-direct
      reference `1172728 us`, `load_full_us=275767`,
      `frame_processing_us=514492`, aggregate fused `inversion_us=1468376`,
      `display_render_us=561071`, `write_us=288599`, and exact
      TIFF/metadata parity.
    - Normal production command on `scan_0004`:
      `export_detected_frames` reported `883583 us`, serial `2587911 us`,
      `workers=5`, `cpu_limit=31`, `mem_limit=28`, adjusted peak
      `2159506560` bytes/worker, and `speedup_x1000=2928`.

- [x] Refresh the Process performance ranking after fused export staging.
  - Why this is next: the latest export pass changed the largest known Process
    bucket again. Before optimizing another stage, refresh the user-visible
    ranking so the next target is chosen from current timings rather than the
    old pre-fusion split.
  - Scope:
    - Use direct Zig commands only.
    - Run `load_preview`, `rebate`, `auto_detect`,
      `inverted_preview_f32_breakdown`, and `export_detected_frames` on
      `scans/scan_0004_rgbir_3200dpi.tiff`.
    - Select the next unblocked same-behavior target from current evidence,
      skipping live scanner items until SANE enumerates the V600.
  - Required evidence before checking off:
    - Exact command outputs summarized here and in
      `docs/PERFORMANCE_STRATEGY.md`.
    - A ranked next-target decision and required validation checklist.
    - If no source changes are made, no extra `zig build test` rerun is needed
      beyond benchmark parity; if code changes are made, run
      `zig build test --summary all`.
  - Completed 2026-05-19:
    - Refreshed the Process ranking on `scan_0004_rgbir_3200dpi.tiff`:
      `load_preview` `639072 us`, checksum `6666414344`; `rebate_dmin`
      `431103 us`, Dmin `0.283915:0.422373:0.606312`; `auto_detect`
      `172900 us`, frames `5`, aspect `24:36`, checksum `38221731`;
      `inverted_preview_f32_breakdown` production `76083 us`, manual mirror
      `123357 us`, `max_abs=0`, checksum `3912224310`; and
      pre-nested-parallel export `883583 us`.
    - Selected the fused export frame-processing bucket as the same-behavior
      follow-up because export was still largest and the fused
      crop-plus-density work was single-threaded inside each of five frame
      workers while the CPU budget allowed more cores.
    - Added budgeted row-level parallelism inside the fused direct TIFF
      crop-to-f32-scene loop. The nested worker count is derived from the
      existing export CPU worker limit divided by the outer frame-worker count,
      leaving the old serial path for small crops and fallback conditions.
    - `zig build test --summary all` passed `412/412`.
    - After the nested pass, `export_detected_frames_breakdown` on
      `scan_0004` reported timed `665289 us`, no-direct reference
      `1276807 us`, `workers=5`, `cpu_limit=31`, `mem_limit=28`, adjusted peak
      `2159506560` bytes/worker, `load_full_us=325067`,
      `frame_processing_us=297149`, aggregate fused `inversion_us=368390`,
      `display_render_us=561994`, `write_us=293486`, `rgb_crop_us=0`, and
      exact TIFF/metadata parity.
    - The `scan_0003` spread check reported timed `608411 us`, reference
      `1150193 us`, `load_full_us=275430`, `frame_processing_us=301205`,
      aggregate fused `inversion_us=363790`, `display_render_us=565134`,
      `write_us=270693`, and exact TIFF/metadata parity.
    - Normal production `export_detected_frames` on `scan_0004` reported
      `665669 us`, serial `2442106 us`, `workers=5`, `cpu_limit=31`,
      `mem_limit=28`, adjusted peak `2159506560` bytes/worker, and
      `speedup_x1000=3668`.
    - Current ranked Process waits are now export `665669 us`, `load_preview`
      `639072 us`, rebate `431103 us`, `auto_detect` `172900 us`, and
      inverted preview production `76083 us`.

- [x] Break down the new top-tier Process waits before the next optimization.
  - Why this is next: after nested export parallelism, export and Process image
    load are close enough that a fresh stage-level comparison should decide the
    next target. Scanner live work remains blocked by SANE enumeration, so this
    is the next unblocked performance loop item.
  - Scope:
    - Run `export_detected_frames_breakdown` and `load_preview_breakdown` on
      `scan_0004_rgbir_3200dpi.tiff`.
    - Compare wall time, stage split, exact parity metrics, and optimization
      risk. Select a same-behavior target with a concrete validation checklist.
    - Do not switch to release QA, UI screenshots, Nix package checks, or macOS
      work while this performance checkpoint is active.
  - Required evidence before checking off:
    - Exact benchmark command summaries for both breakdowns.
    - A ranked next-target decision and checklist.
    - `zig build test --summary all` only if code changes are made.
  - Completed 2026-05-19:
    - `load_preview_breakdown` on `scan_0004_rgbir_3200dpi.tiff` before the
      small preview pass reported total `586596 us`, reference `687977 us`,
      `rgb_read_us=308681`, `quick_preview_us=253135`,
      `invert_stretch_us=65809`, `clahe_us=40902`, `raw_copy_us=32704`,
      `rgb_copy_us=14951`, `jpeg_encode_us=25662`, and exact
      raw/RGB/JPEG parity.
    - `export_detected_frames_breakdown` after nested fused export reported
      total `665289 us`, `load_full_us=325067`,
      `frame_processing_us=297149`, aggregate fused `inversion_us=368390`,
      `display_render_us=561994`, and exact TIFF/metadata parity.
    - Selected two targets from this evidence:
      - a small immediate load-preview pass fusion, because
        `stretch_content_percentiles` still walked the full preview separately
        for each RGB channel even though the percentile and stretch math is
        channel-independent;
      - a larger follow-up repeated-TIFF-read/cache checkpoint, because the
        top waits now share the same roughly `300 ms` RGB page read cost.
    - Implemented the small preview pass fusion in `opencv_preview.cpp`: the
      masked 256-bin histograms for RGB channels are now built in one image
      walk and the active channel stretches are applied in one image walk.
      Output semantics are unchanged.
    - `zig build test --summary all` passed `412/412`.
    - After the preview pass fusion, `load_preview_breakdown` reported total
      `576577 us`, reference `711587 us`, `rgb_read_us=314019`,
      `quick_preview_us=237544`, `invert_stretch_us=54955`,
      `clahe_us=38662`, `raw_copy_us=32823`, `rgb_copy_us=15089`,
      `jpeg_encode_us=26101`, and exact raw/RGB/JPEG parity. A normal
      `load_preview` run reported `684465 us`, checksum `6666414344`; this
      single-command wall time is noisy, so use the parity-checked breakdown
      for the pass-level win.

- [x] Prototype a Process RGB page cache to avoid repeated TIFF reads.
  - Why this is next: after export and preview loop work, the largest shared
    avoidable-looking cost is repeatedly reading the same full RGB TIFF page.
    Current evidence shows `load_preview_breakdown` `rgb_read_us` around
    `314019 us` and export `load_full_us` around `325067 us` on the same
    loaded image. Python kept processing image state in memory, so a carefully
    scoped cache may be more function-for-function than repeatedly reopening
    the TIFF for rebate/export.
  - Scope:
    - First add a headless workflow benchmark or state-level replay that proves
      the potential win without changing UI ownership unsafely. Compare
      load-preview + rebate + export with and without reusing an already-loaded
      RGB page.
    - Preserve current fallback behavior for CLI/stateless commands, image
      switches, stale worker generations, file changes, IR-needed exports,
      missing Dmin, and memory-limited systems.
    - Do not store the full RGB page in native UI state until ownership,
      invalidation, and worker handoff are explicit and covered by tests.
  - Required evidence before checking off:
    - A benchmark on `scan_0004_rgbir_3200dpi.tiff` quantifying avoided TIFF
      read time and any memory increase.
    - Replay/state tests for cache invalidation on image switch and stale
      worker result rejection if the UI cache is integrated.
    - Exact output parity for rebate Dmin and export TIFF/metadata.
    - `zig build test --summary all` after any code change.
  - Completed 2026-05-19:
    - Added the headless `process_rgb_page_cache_sequence` benchmark and the
      cache-safe workflow entry points `quickPreviewFromLoadedRgbPage`,
      `computeRebateDminFromTiffImage`, and
      `processExportFromCachedRgbPage`. This checkpoint intentionally does not
      store the full RGB page in native UI state, so image-switch and stale
      worker cache-invalidation tests remain deferred until UI cache ownership
      is explicitly integrated.
    - The benchmark compares the current stateless sequence
      `loadQuickPreview` -> `autoDetectPreview` -> `computeRebateDminFromTiff`
      -> `processExportFromTiff` against one `loadRgbPageWithMetadataTimed`
      reused for quick preview, rebate Dmin, and direct no-IR/provided-Dmin
      export. CLI/stateless commands still keep their existing load behavior.
    - `zig build test --summary all` passed `412/412`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case process_rgb_page_cache_sequence`
      reported cached `1075616 us` versus baseline `2001858 us`
      (`speedup_x1000=1861`), cached RGB resident bytes `741120000`,
      cached load `325380 us`, cached RGB read `300145 us`, baseline
      repeated-load-ish time `1477842 us`, avoided read time `1152462 us`,
      baseline preview `677912 us` versus cached preview `229352 us`, baseline
      rebate `450573 us` versus cached rebate `65867 us`, baseline export
      `700209 us` versus cached export `300197 us`, baseline export load
      `349356 us` versus cached export load `0 us`, and exact parity:
      preview mismatches `0`, `dmin_max_abs=0.000000000000`,
      `export_max_abs=0`, `export_mismatches=0`, `metadata_equal=true`, and
      `file_set_equal=true`.

- [x] Define the semantic native Process result-cache key contract.
  - Why this is next: the headless RGB-page cache proved that repeated TIFF
    reads are expensive, but a native UI cache must be broader and stricter
    than a single resident buffer. It must support fast image switching,
    repeated setting changes, and later undo/redo without coupling cache
    behavior to undo history.
  - Invariants:
    - Cache lookup must be transparent: if the exact semantic key is absent,
      the UI must run the normal computation path and then may populate the
      cache.
    - Undo/redo history is not part of the cache. Future undo/redo should be a
      light record of selected file, config, selections, rebate/Dmin, and other
      UI state snapshots; replaying a snapshot may hit the cache, but it must
      not own cache entries or invalidation.
    - A cache hit must be keyed by the selected image identity and every
      relevant processing input for the operation. The image identity includes
      the path plus file size and mtime when available. The processing state
      includes the full loaded processing config, custom stock coefficients,
      selected Dmin/rebate/frames/render settings/GPU request/output choices as
      appropriate for the operation.
    - A compact hash fingerprint is acceptable as the practical key because
      the resident state set is small and a reasonable fingerprint collision is
      effectively impossible in this UI. The implementation must still keep the
      serialized key construction deterministic and testable so diagnostics can
      explain why a hit or miss happened.
    - Do not store large image buffers in native UI state until ownership,
      memory budget, image-switch invalidation, and stale-worker handoff are
      covered by tests.
  - Scope:
    - Add a standalone native Process cache-key module independent of
      undo/redo and independent of SDL/Nuklear rendering.
    - Serialize the full active `scratchndent_config.toml` state in a canonical
      order, including every active config entry and every custom stock profile
      coefficient.
    - Define operation-state serializers for RGB-page, quick-preview,
      auto-detect, rebate Dmin, inverted preview, and export-output cache
      candidates.
    - Add a small byte-result cache harness proving exact-key hit/miss
      behavior without yet claiming a production resident image cache.
  - Required evidence before checking off:
    - Unit tests that a config-entry value change, custom stock coefficient
      change, selected file path/mtime change, preview-size change, Dmin/render
      option/GPU change, auto-detect option change, and export-output choice
      change all change the key.
    - A cache harness test proving miss fallback is visible as a null result
      for non-identical semantic keys.
    - `zig build test --summary all`.
  - Completed 2026-05-20:
    - Added `src/ui/process_cache.zig` and exported it through `src/root.zig`.
      The module defines semantic operations, image identity, deterministic
      config-state bytes, operation-state bytes, compact 128-bit semantic
      fingerprints for lookup, and a small byte-result cache harness.
    - The cache-key code is deliberately not tied to undo history. It can
      support future undo/redo because a restored state snapshot can recreate
      the same semantic key, but the cache remains a general processing-result
      layer.
    - `zig build test --summary all` passed `418/418`.

- [x] Integrate native Process quick-preview caching on image load and image
      switch.
  - Why this is next: the key contract is now test-covered, and quick-preview
    image switching is the smallest UI-facing cache integration that can use
    it without taking ownership of a full-resolution RGB page yet.
  - Scope:
    - Add a bounded native Process result-cache owner outside undo/redo
      history.
    - Store derived quick-preview results under semantic keys built from image
      path/size/mtime, full processing config state, and preview-size operation
      state.
    - On image load or image switch, attempt a cache lookup before spawning the
      load worker. On miss, run the existing worker computation and populate
      the cache only after the result passes stale-generation/path checks.
    - Keep current stateless CLI behavior and direct workflow functions
      unchanged.
  - Required evidence before checking off:
    - State/worker tests for cache hit on reloading an unchanged image and miss
      on processing config change.
    - Cache clone tests proving cached preview buffers are not aliased with UI
      state.
    - `zig build test --summary all`.
  - Completed 2026-05-20:
    - Added `ProcessResultCache` and `QuickPreviewCache` to
      `src/ui/process_cache.zig`, with a bounded four-entry cache and cloned
      preview ownership on both insert and hit.
    - Added `processing_result_cache` to native `State`; deinit clears cached
      preview entries independently from undo/redo and independently from the
      current visible preview.
    - `ProcessWorker.startLoadIndex` now checks the semantic quick-preview key
      before spawning a worker. Cache hits install a cloned preview through the
      same `finishProcessingImageLoadResult` path as worker results. Cache
      misses run the existing load worker and populate the cache only after the
      result is accepted for the current generation/path.
    - Tests cover cloned cache hits, unchanged-image worker bypass, and config
      mutation miss/fallback behavior.
    - `zig build test --summary all` passed `421/421`.

- [x] Integrate native Process resident RGB-page caching.
  - Why this is next: quick-preview caching now covers fast image switching for
    derived previews, but the previous benchmark showed that one resident RGB
    page avoided about `1.15 s` of repeated reads in a preview + rebate + export
    sequence on `scan_0004_rgbir_3200dpi.tiff`.
  - Scope:
    - Add a bounded resident RGB-page owner with an explicit memory budget and
      LRU or simple recency eviction policy.
    - Store full-resolution RGB page data under semantic keys built from image
      path/size/mtime plus the relevant operation state.
    - Use the resident page for quick-preview generation, rebate Dmin, and
      no-IR/provided-Dmin export only where the existing cached workflow
      helpers already proved exact parity.
    - Preserve transparent fallback to existing TIFF-load computation when the
      cache misses, memory budget is exceeded, IR data is required, Dmin is
      missing, or worker ownership is stale.
  - Required evidence before checking off:
    - State/worker tests for image-switch hit, file metadata miss, memory-budget
      eviction, and stale worker rejection.
    - A direct benchmark showing cached UI sequence latency versus the current
      `load_preview`/rebate/export path on a real scan from `scans/`.
    - `zig build test --summary all`.
  - Completed 2026-05-20:
    - Added a bounded `RgbPageCache` to `src/ui/process_cache.zig` with a
      default 1 GiB memory budget, two-entry capacity, explicit resident-byte
      accounting, and least-recently-used eviction. Pages larger than the
      budget are rejected and fall back to normal computation.
    - Process image-load workers now preserve the loaded full-resolution RGB
      page after the load result is accepted, move it into the resident cache,
      and can generate quick previews from a resident page clone on later
      image switches. Stale worker results do not populate the cache.
    - Rebate and auto-detect Dmin follow-up workers receive a resident RGB page
      clone when available and otherwise fall back to `processRebateFromTiff`.
    - Process export workers receive a resident RGB page clone when available
      and attempt `processExportFromCachedRgbPage`; unsupported export shapes
      transparently fall back to `processExportFromTiff`.
    - Tests cover cloned page ownership, file metadata key misses,
      memory-budget eviction, over-budget rejection, accepted load population,
      stale load rejection, rebate context handoff, and export context handoff.
    - `zig build test --summary all` passed `428/428`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case process_rgb_page_cache_sequence`
      reported cached `1120225 us` versus baseline `1932655 us`
      (`speedup_x1000=1725`), cached RGB bytes `741120000`,
      avoided read time `1056380 us`, baseline preview `639922 us` versus
      cached preview `241429 us`, baseline rebate `443560 us` versus cached
      rebate `65228 us`, baseline export `676540 us` versus cached export
      `296899 us`, baseline export load `334072 us` versus cached export load
      `0 us`, and exact parity: preview mismatches `0`,
      `dmin_max_abs=0.000000000000`, `export_max_abs=0`, export mismatches
      `0`, `metadata_equal=true`, and `file_set_equal=true`.

- [x] Add derived native Process result caches for Dmin, auto-detect, and
      inverted preview.
  - Scope:
    - Cache rebate Dmin by image identity, full config state, and full rebate
      rectangle.
    - Cache auto-detect by image identity, full config state, preview identity
      or preview state, detection options, scale adjustment, and output
      rotation.
    - Replace or wrap the current pointer/generation inverted-preview guard
      with a semantic key that includes image identity, preview dimensions,
      full config state, active stock, Dmin, render options, and GPU request.
    - Preserve transparent fallback to computation on every cache miss.
  - Required evidence before checking off:
    - Tests proving each relevant state mutation misses the cache.
    - Tests proving repeated identical operations hit and produce the same UI
      state without recomputation.
    - Performance evidence for repeated settings toggles and image switching.
  - Completed 2026-05-20 Dmin-cache slice:
    - Added a bounded `DminCache` to `src/ui/process_cache.zig`, keyed by the
      same compact semantic fingerprint contract as the quick-preview and
      resident RGB-page caches.
    - `ProcessWorker.startRebateFromState` now checks the cached Dmin before
      spawning the rebate worker. Hits persist `dmin` to
      `scratchndent_config.toml` through `saveRebateDmin` and apply the result
      through the same accepted-generation/path state path as worker results.
      Misses transparently run the existing rebate worker.
    - Accepted explicit rebate workers and auto-detect suggested-rebate
      follow-up workers populate the Dmin cache after their result is accepted
      for the active image.
    - Tests cover Dmin cache hit/update/LRU eviction, image metadata, full
      config state, and rebate rectangle misses, and the worker-level hit path
      that bypasses the worker while still saving config and updating native
      state.
    - `zig build test --summary all` passed `432/432`.
  - Completed 2026-05-20 auto-detect-cache slice:
    - Added a bounded `AutoDetectCache` that stores cloned detector frames,
      aspect, suggested rebate, full-resolution rebate, and optional Dmin under
      a semantic key built from image identity, full processing config state,
      detection options, scale adjustment, output rotation, preview dimensions,
      and preview scale.
    - `ProcessWorker.startAutoDetectFromState` checks the auto-detect cache
      before copying preview buffers or spawning the detector worker. Hits
      replay through `applyProcessAutoDetectWorkerResult`, remember the aspect,
      persist cached Dmin through `saveRebateDmin`, and avoid recomputation.
      Misses run the existing worker path.
    - Accepted auto-detect worker results populate both the auto-detect cache
      and, when a suggested rebate Dmin exists, the separate Dmin cache after
      generation/path checks pass.
    - Tests cover auto-detect result clone isolation, full-config cache misses,
      and the worker-level hit path that bypasses the worker while applying
      selections, rebate, aspect, Dmin, and config persistence.
    - `zig build test --summary all` passed `434/434`.
  - Completed 2026-05-20 inverted-preview-cache slice:
    - Added a bounded `InvertedPreviewCache` to `ProcessResultCache` for RGB8
      inverted preview outputs under the same compact semantic fingerprint
      contract.
    - Added `invertedPreviewKey`, keyed by image identity, full processing
      config state, active stock, Dmin, render options, GPU request, preview
      dimensions, and preview scale.
    - The SDL/Nuklear `ProcessPreviewTextureCache` now keeps its local
      pointer/generation key only for current texture validity, checks the
      semantic Process result cache before starting an inverted-preview worker,
      uploads cached RGB8 results directly on hits, and caches accepted worker
      results after the existing current-generation/options match succeeds.
      Misses transparently run the existing worker path.
    - Tests cover inverted-preview RGB8 clone isolation and misses for full
      config, Dmin, and render-state mutations.
    - `zig build test --summary all` passed `435/435`.
    - Direct UI validation passed:
      `zig build -Dui=true --summary all` and
      `SDL_VIDEODRIVER=dummy zig build -Dui=true run-ui -- --process-render-smoke`.
    - Added `process_result_cache_repeat` benchmark coverage. On
      `scans/scan_0004_rgbir_3200dpi.tiff`,
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case process_result_cache_repeat`
      reported baseline `701955 us`, cached `15230 us`
      (`speedup_x1000=46090`), auto-detect `179246 us` versus hit `0 us`,
      Dmin `447778 us` versus hit `0 us`, inverted preview `74930 us` versus
      hit `15229 us`, and exact parity:
      `auto_mismatches=0`, `dmin_max_abs=0.000000000000`,
      `inverted_max_abs=0`, `inverted_mismatches=0`, and matching checksums.

- [x] Finish scanner preview, scanner startup, and full-resolution scan live
      timing before attempting scanner-side optimization.
  - Why this is measurement-first: scanner startup is known slow and important,
    but live scan time is partly hardware/I/O bound. Blind changes risk
    breaking scanner parity or adding more blocking startup work.
  - Autonomous loop instruction:
    - Treat the nested checklist below as the active scanner-performance work
      queue. Select the first unchecked unblocked scanner checkpoint, complete
      its code, replay/headless tests, live evidence if required, and docs
      updates, then check off only that checkpoint. Re-run the loop until the
      parent item has a complete timing baseline and a ranked follow-up
      optimization list.
    - Use the conversation's ambient nix shell and direct `zig ...` commands
      only. Do not run `nix develop`, `nix-shell`, `nix build`,
      `nix flake check`, or `nix search` while iterating. If a dependency or
      Zig version is missing, edit Nix files if needed, stop, and ask the human
      to reload the shell.
  - Scope:
    - Add structured timing around device discovery, connect/open, capability
      probing, option setting, LUT generation/application, preview scan, full
      scan, IR pass planning, file write, metadata write, and worker progress
      event emission.
    - Keep startup non-blocking: do not add blocking discovery, repeated SANE
      probes, or scanner connection attempts on UI startup or hot paths without
      benchmark evidence.
    - Prefer cached capabilities, lazy connection, replayable scanner tests,
      and clear progress diagnostics.
    - Linux live hardware checks remain gated behind `V600_HARDWARE_SMOKE=1`;
      macOS live scanner work remains parked pending explicit user update.
  - Required evidence before checking off:
    - Headless/replay tests for timing event formatting and scanner-worker state.
    - When hardware is available and visible to SANE, run gated RGB, IR, RGB+IR,
      metadata, LUT, native preview-worker, native scan-worker, and
      scanner-to-processing smoke commands.
    - Record exact commands, device identity, output paths, TIFF geometry/page
      summaries, and timing breakdowns.
    - `zig build test --summary all`.
  - Completed 2026-05-23:
    - Rebuilt Linux wrappers enumerated `epkowa:interpreter:001:020` without
      manual environment repair.
    - Headless/replay timing and worker tests passed through
      `zig build test --summary all` with `450/450` tests.
    - Live gated RGB, IR, RGB+IR, LUT, scanner-to-processing, native
      preview-worker, and native scan-worker smokes are recorded below with
      exact commands, output paths, geometry, sidecars, and timing reports.
    - First scanner-side optimization was selected and completed:
      session-local native capability reuse avoids repeated `scanimage --help`
      probes for selected-area preview/scan workers while preserving fallback
      behavior.
  - Scanner instrumentation and optimization checklist:
    - [x] Define the scanner timing event contract.
      - Add a stable JSONL event shape in `src/scanner/events.zig` for timing
        samples without breaking existing `startup`, `device_discovery`,
        `probe`, `scan_start`, `progress`, `scan_complete`,
        `scan_cancelled`, and `scan_error` consumers.
      - Required fields should include at least schema/version, event name,
        stage name, elapsed microseconds, and an optional detail string or
        small structured context. Use monotonic timing; never wall-clock time
        for elapsed durations.
      - Add schema tests for event name spelling, field spelling, integer
        formatting, detail escaping, and fanout through the existing event
        sink. This checkpoint is complete only when `zig build test --summary
        all` passes.
      - Completed 2026-05-19:
        - Added `TimingEvent` and the `timing` JSONL event name to
          `src/scanner/events.zig`.
        - Stable fields are `event`, `schema`, `stage`, `elapsed_us`, and
          nullable `detail`. Runtime instrumentation will convert monotonic
          durations to elapsed microseconds before emitting this event.
        - Added `writeTiming` / `emitTiming`, `Event.timing`, and a sink
          forwarding test so scanner runtimes and native workers can route the
          timing event through the existing event bus without changing the
          older scanner lifecycle events.
      - Evidence:
        - `zig build test --summary all` passed `405/405`.
    - [x] Instrument Linux scanner startup and capability discovery.
      - Time device cache lookup, `scanimage -L`, device-list parsing,
        selected-device resolution, flatbed `scanimage --help`, TPU
        `scanimage --help`, capability parsing, combined capability assembly,
        and total `Runtime.probe`.
      - Preserve the nonblocking native UI lifecycle: no new synchronous probe
        on UI startup, no repeated discovery on hot paths, and no automatic
        retry loop without explicit user action or benchmark evidence.
      - Add fake-process or replay tests that prove timing events are emitted
        in deterministic order around successful discovery/probe and that
        scanner errors still emit the existing failure events.
      - Completed 2026-05-19:
        - `Runtime.discoverDevices` now emits timing for `scanimage -L`,
          device-list parsing, V600 selection, and total discovery.
        - `Runtime.probe` now emits timing for discovery, selected-device
          resolution, cache-write attempt, flatbed and TPU capability help,
          combined capability parsing, and total probe.
        - `Runtime.resolveDeviceName` now emits timing for explicit selection,
          cache lookup, and discover-and-cache fallback. Device cache writes
          emit `linux.cache.write` timing while preserving their previous
          best-effort/no-throw behavior.
        - Added a `scanimage_command` runtime override for replay tests. Normal
          runtime behavior still defaults to `scanimage`/wrapper discovery and
          no additional scanner probes were added.
      - Evidence:
        - `zig build test --summary all` passed `408/408`.
        - Added fake-process tests for successful probe timing order, cache-hit
          resolution without discovery, and failed discovery preserving the
          existing `device-discovery` event plus timing diagnostics.
    - [x] Instrument single-pass scan execution.
      - Time request normalization, capability lookup when required for an
        explicit scan area, SANE command planning, environment/LUT wiring,
        child process spawn, stderr progress parsing, progress event emission,
        child wait, cancel-file handling, mirror step, TIFF metadata rewrite,
        metadata sidecar write, and total `scanOnce`.
      - Keep progress semantics stable: existing progress percentages and
        failure classification must remain unchanged, and timing events must
        not hide or reorder user-visible scan errors.
      - Add headless tests using the fake child/cancel infrastructure so this
        checkpoint does not require hardware.
      - Completed 2026-05-19:
        - `scanOnce` now emits timing for capability lookup, request
          normalization, command planning, progress-flag insertion,
          `runScanPlan`, mirror handling, TIFF metadata rewrite, metadata
          sidecar write, and total single-pass scan time.
        - `runScanPlan` now emits timing for environment/LUT setup, child
          spawn, stderr/progress streaming, aggregate progress-event emission,
          child wait, cancel-file observation, and total child execution.
        - Added a fake `scanimage` single-pass test that writes a real TIFF via
          ImageMagick and exercises scan-start, progress, metadata rewrite,
          sidecar write, scan-complete, and timing event order without scanner
          hardware.
        - Extended the fake cancellation test to assert cancel timing and the
          existing `scan-cancelled` event.
      - Evidence:
        - `zig build test --summary all` passed `409/409`.
    - [x] Instrument RGB+IR orchestration and post-scan file work.
      - Time RGB pass, IR pass, IR DPI/source planning, thumbnail generation,
        multipage TIFF combine, metadata rewrite, sidecar write, temporary
        file cleanup, and total `scanRgbIr`.
      - Preserve page layout and metadata invariants: page 0 RGB, page 2 IR
        when present, existing Make/Model/Software/DPI/custom-LUT tags, sidecar
        fields, and completion event payloads.
      - Add replay tests for RGB+IR timing event ordering using fake scan
        executors or existing TIFF fixtures where possible.
      - Completed 2026-05-19:
        - `scanRgbIr` now emits orchestration timing for RGB pass planning,
          RGB pass execution, IR pass planning, IR pass execution, thumbnail
          generation, multipage TIFF combine, final metadata tag rewrite,
          combined sidecar write, temp-file cleanup, and total RGB+IR time.
        - Added a fake RGB+IR scan test that drives the public `Runtime.scan`
          path with an explicit fake device, writes real temporary TIFFs,
          creates the thumbnail, combines pages with `tiffcp`, writes final
          metadata/sidecar files, and verifies temp cleanup without hardware.
      - Evidence:
        - `zig build test --summary all` passed `410/410`.
    - [x] Instrument native preview-worker latency.
      - Time preview worker queue acceptance, probe/capability refresh,
        preview scan request construction, scanner runtime scan, TIFF load,
        preview page conversion, Python-parity Lanczos downsample when needed,
        `PreviewBuffer` allocation/copy, and state update.
      - Preserve browser parity: UI remains usable while connecting, Preview
        while connecting still reports the Python-shaped connecting message,
        downsample semantics remain the accepted Pillow Lanczos oracle, and
        preview selection state is not reset except where the browser did so.
      - Add headless worker/state tests proving timing diagnostics are surfaced
        without changing success, failure, or cancellation state transitions.
      - Completed 2026-05-19:
        - `PreviewWorker` now records timing events for preview-worker start,
          runtime probe, preview request construction, runtime scan, TIFF load,
          downsample, total preview execution, and final UI state update.
        - `State.applyScannerBackendEvent` now accepts `timing` events and
          stores the latest scanner timing stage/detail/elapsed value plus a
          timing count. Timing events intentionally do not change scan status,
          preview readiness, progress, or cancellation/error transitions.
        - Preview worker success and failure tests now assert diagnostics are
          surfaced through native state while preserving the existing
          preview-ready and failure-status behavior.
      - Evidence:
        - `zig build test --summary all` passed `410/410`.
    - [x] Instrument native full-scan worker latency.
      - Time scan worker queue acceptance, temporary LUT generation from the
        selected preview, LUT-file write, runtime setup, backend event drain,
        scan command execution, cancellation request/cleanup, output path
        propagation, and final UI state update.
      - Preserve LUT policy: RGB scans may use the selected custom scanner LUT,
        IR-only scans use identity/fallback policy, and custom LUT metadata
        remains visible in TIFF tags/sidecars.
      - Add headless worker/state tests for success, cancellation, failure, and
        timing diagnostics.
      - Completed 2026-05-19:
        - `ScanWorker` now emits timing for scan start preparation, temporary
          scanner LUT generation, LUT file write, aggregate LUT preparation,
          pre-start cancel-file cleanup, cancel-file write, runtime setup,
          runtime scan execution, metadata-path propagation, backend event
          drains, final UI state update, and worker cleanup.
        - Scanner runtime `timing` events are now passed through the scan
          worker event queue instead of being dropped.
        - Success, temporary-LUT, cancellation, live-event-drain, and failure
          tests now assert timing diagnostics are surfaced through native state
          while preserving scan status, progress, cancellation, and output
          behavior.
      - Evidence:
        - `zig build test --summary all` passed `410/410`.
    - [x] Add a scanner timing report path for live diagnostics.
      - Provide a CLI/UI-accessible way to capture scanner timing JSONL during
        `scanner probe`, `scanner scan`, native preview-worker smoke,
        native scan-worker smoke, and `scanner processing-smoke`.
      - The report must be useful when the UI pegs CPU or appears idle: include
        current stage, elapsed timings, output path, device identity when
        known, selected source/mode/depth/DPI, and final success/error status.
      - Keep the format append-friendly so repeated live runs can be compared
        without parsing human status text.
      - Completed 2026-05-19:
        - `src/scanner/events.zig` now provides an append-mode
          `TimingReport` sink. It mirrors existing scanner lifecycle,
          progress, error, and timing events to JSONL without changing normal
          stderr/debug event emission.
        - Added report-only `timing-context` and `timing-status` JSONL records
          so live runs are delimited with command name, output path, selected
          device when already known, source/kind/depth/DPI, and final
          `ok`/`error`/`skipped` status.
        - `v600-zig scanner` accepts `--timing-report PATH` for `devices`,
          `probe`, `scan`, `smoke`, and `processing-smoke`. The report stream
          captures runtime events for probe/scan paths and records skipped
          status without touching hardware when `V600_HARDWARE_SMOKE=1` is not
          set.
        - `v600-ui` accepts `--timing-report PATH`; native preview-worker and
          scan-worker smoke paths write context/status records and route
          worker/runtime scanner events to the same appendable report sink.
      - Evidence:
        - `zig build test --summary all` passed `412/412`.
        - `zig build scanner-smoke-skip scanner-processing-smoke-skip
          --summary all` passed.
        - `zig build -Dui=true native-preview-worker-smoke-skip
          native-scan-worker-smoke-skip --summary all` passed.
        - `zig build run -- scanner smoke --timing-report
          .zig-cache/tmp/v600-scanner-report-smoke.jsonl` skipped and wrote
          `scanner smoke` context/status JSONL.
        - `zig build run -- scanner processing-smoke --timing-report
          .zig-cache/tmp/v600-scanner-report-smoke.jsonl` appended
          `scanner processing-smoke` context/status JSONL.
        - `zig build -Dui=true run-ui -- --preview-worker-smoke
          --timing-report .zig-cache/tmp/v600-ui-report-smoke.jsonl` skipped
          and wrote native preview-worker context/status JSONL.
        - `zig build -Dui=true run-ui -- --scan-worker-smoke
          --timing-report .zig-cache/tmp/v600-ui-report-smoke.jsonl` appended
          native scan-worker context/status JSONL.
    - [x] Run headless validation for the completed instrumentation.
      - Required command: `zig build test --summary all`.
      - Also run the smallest direct Zig build/UI smoke commands touched by the
        instrumentation, for example `zig build -Dui=true --summary all` or
        the relevant smoke step, but only direct `zig ...` commands.
      - Record exact command lines and pass/fail results under this checklist
        and in `docs/PARITY_MANIFEST.md` if the event schema, worker behavior,
        or scanner parity evidence changed.
      - Completed 2026-05-19:
        - `zig build test --summary all` passed `412/412`.
        - `zig build scanner-smoke-skip scanner-processing-smoke-skip
          --summary all` passed and printed the expected no-hardware skip
          messages.
        - `zig build -Dui=true native-preview-worker-smoke-skip
          native-scan-worker-smoke-skip --summary all` passed and printed the
          expected no-hardware skip messages.
        - `zig build run -- scanner smoke --timing-report
          .zig-cache/tmp/v600-scanner-report-smoke.jsonl` passed without
          hardware and wrote skipped report records.
        - `zig build run -- scanner processing-smoke --timing-report
          .zig-cache/tmp/v600-scanner-report-smoke.jsonl` passed without
          hardware and appended skipped report records.
        - `zig build -Dui=true run-ui -- --preview-worker-smoke
          --timing-report .zig-cache/tmp/v600-ui-report-smoke.jsonl` passed
          without hardware and wrote skipped report records.
        - `zig build -Dui=true run-ui -- --scan-worker-smoke --timing-report
          .zig-cache/tmp/v600-ui-report-smoke.jsonl` passed without hardware
          and appended skipped report records.
        - `git diff --check -- src/scanner/events.zig src/ui/preview_worker.zig
          src/ui/scan_worker.zig src/main.zig src/ui/main.zig plan.md
          docs/PARITY_MANIFEST.md docs/PERFORMANCE_STRATEGY.md` passed.
    - [x] Run gated Linux live scanner timing smokes when hardware is visible
          to SANE.
      - Use `V600_HARDWARE_SMOKE=1` and small selected TPU areas for fast,
        low-waste evidence. Do not run live hardware smokes without the gate.
      - Cover RGB, IR, RGB+IR, metadata rewrite, custom LUT metadata,
        native preview-worker, native scan-worker, and
        scanner-to-processing smoke.
      - Record exact commands, selected SANE device, output paths, TIFF page
        geometry/dtypes, sidecar summaries, and timing-event summaries in this
        plan and `docs/PARITY_MANIFEST.md`.
      - Blocked 2026-05-19:
        - `zig build run -- scanner devices --timing-report
          .zig-cache/tmp/v600-live-scanner-timing.jsonl` completed and wrote a
          timing report, but SANE reported `devices_found=0`. The recorded
          `linux.discover.scanimage_list` stage took about 5.83 seconds.
        - `zig build run -- scanner probe --timing-report
          .zig-cache/tmp/v600-live-scanner-timing.jsonl` appended startup and
          discovery timings, then failed with `NoV600Device`. The second
          recorded `linux.discover.scanimage_list` stage took about
          6.02 seconds.
        - USB and permissions are not the obvious blocker: `lsusb` sees
          `04b8:013a Seiko Epson Corp. GT-X820 [Perfection V600 Photo]` at
          `001:018`, `/dev/bus/usb/001/018` is group-writable by `scanner`,
          the current user is in the `scanner` group, and
          `sane-find-scanner` reports a possible scanner at `libusb:001:018`.
        - `scanimage -L`, `scanimage-v600 -L`, and `scanimage-v600-ir -L`
          still return no scanner devices; explicit `epkowa`/`epson2` device
          attempts fail with `Invalid argument`, `Error during device I/O`, or
          `Device busy`.
        - Rechecked later on 2026-05-19: `lsusb` still sees
          `04b8:013a Seiko Epson Corp. GT-X820 [Perfection V600 Photo]` at
          `001:018`, but direct `scanimage -L` still reports
          `No scanners were identified`.
        - Rechecked again through the Zig timing path:
          `zig build run -- scanner devices --timing-report
          .zig-cache/tmp/v600-live-scanner-timing-refresh.jsonl` emitted
          `devices_found=0`; `linux.discover.scanimage_list` took
          `5743827 us` and `linux.discover.total` took `5749153 us`.
        - No live scan smoke was run and no output TIFF was produced. Required
          next input is to make the scanner enumerate through SANE again
          before running gated RGB, IR, RGB+IR, native worker, or
          scanner-to-processing smoke commands.
      - Rechecked after scanner reboot on 2026-05-23:
        - USB visibility recovered at a new bus address:
          `04b8:013a Seiko Epson Corp. GT-X820 [Perfection V600 Photo]` at
          `001:020`, and `sane-find-scanner` reported a possible scanner at
          `libusb:001:020`.
        - Plain ambient `scanimage -L`, current system `scanimage-v600 -L`, and
          current system `scanimage-v600-ir -L` still reported no scanner.
          Direct `zig build run -- scanner devices --timing-report
          .zig-cache/tmp/v600-live-scanner-feature-support.jsonl` also reported
          `devices_found=0` without manual environment repair.
        - SANE debug showed the current system wrappers were not making
          `libsane-epkowa.so.1` visible. The active wrapper searched only the
          SANE/gcc/wgpu/vulkan library paths and therefore loaded `epson2` but
          could not load `epkowa`.
        - Manual backend-path repair proved the scanner and epkowa backend are
          usable:
          `LD_LIBRARY_PATH="/run/current-system/sw/lib/sane${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" scanimage-v600 -L`
          listed `epkowa:interpreter:001:020`.
        - With the same manual backend path, direct
          `zig build run -- scanner devices --timing-report
          .zig-cache/tmp/v600-live-scanner-feature-support.jsonl` selected
          `epkowa:interpreter:001:020`; discovery took about 8.34 seconds.
        - With the same manual backend path, direct
          `zig build run -- scanner probe --timing-report
          .zig-cache/tmp/v600-live-scanner-feature-support.jsonl` succeeded:
          wrappers `true/true`, flatbed `8.500 x 11.700 in`, TPU
          `2.700 x 9.540 in`, max resolution `3200`, and
          `ir_supported=true`. Probe timing was about 8.68 seconds for
          discovery, 8.38 seconds for flatbed help, 8.68 seconds for TPU help,
          and 25.77 seconds total.
        - The repo overlay was updated so future `scanimage-v600` and
          `scanimage-v600-ir` wrappers prepend the epkowa backend directory and
          use `/etc/sane-config`. A system rebuild/reload is required before
          plain wrapper commands can be expected to pass without the manual
          `LD_LIBRARY_PATH` repair.
      - Completed 2026-05-23 after NixOS rebuild:
        - Rebuilt wrappers now include the epkowa backend path and
          `/etc/sane-config`. `scanimage-v600 -L` and `scanimage-v600-ir -L`
          both enumerated `epkowa:interpreter:001:020` without the manual
          `LD_LIBRARY_PATH` repair.
        - Direct discovery/probe commands:
          - `zig build run -- scanner devices --timing-report
            .zig-cache/tmp/v600-live-scanner-feature-support.jsonl` selected
            `epkowa:interpreter:001:020`; `linux.discover.scanimage_list`
            took `6040061 us`, total discovery `6046567 us`.
          - `zig build run -- scanner probe --timing-report
            .zig-cache/tmp/v600-live-scanner-feature-support.jsonl` succeeded
            with wrappers `true/true`, flatbed `8.500 x 11.700 in`, TPU
            `2.700 x 9.540 in`, max resolution `3200`, and
            `ir_supported=true`; discovery took `6064935 us`, flatbed help
            `6048726 us`, TPU help `6069691 us`, total probe `18209430 us`.
        - Packaging hardening refresh 2026-05-23:
          - Replaced inline `sed` epkowa source edits with
            `nixos/patch-epkowa-v600.py`, which validates exact source anchors,
            is idempotent, and applies the USB request-size override plus the
            16-bit `dip_apply_color_profile` bypass at the intended function
            site.
          - Replaced the generated `patch_ir.py` heredoc with checked-in
            `nixos/patch-v600-interpreter-ir.py`, which pins the pre-fixup
            interpreter hashes, validates the byte sites at `0x17c83` and
            `0x18f01`, supports idempotency, and rejects corrupted or changed
            binaries.
          - Hardened `scanimage-v600` and `scanimage-v600-ir` so missing packaged
            epkowa backend/interpreter paths are fatal errors instead of warnings
            followed by an unverified fallback.
          - Validation commands passed:
            `python3 nixos/patch-epkowa-v600.py --self-test`;
            `python3 nixos/patch-v600-interpreter-ir.py --self-test`; a
            two-pass replay of the epkowa patcher against pinned
            `iscan_2.30.4-2.tar.gz`; extracted-interpreter patch check with
            pre-fixup patched sha256
            `9627a8a1f3fc492f826265b9db620b3820f7e30da642adc1004765eeaff1e74a`;
            `nix build --impure --expr 'let pkgs = import <nixpkgs> { overlays
            = [ (import ./nixos/v600-overlay.nix) ]; }; in pkgs.epkowa'
            --no-link --print-build-logs --print-out-paths`;
            equivalent targeted builds for `pkgs.v600-interpreters` and a
            `scanimage-v600`/`scanimage-v600-ir` wrapper bundle;
            `zig build test --summary all` passed `450/450`.
          - Built-wrapper live smoke passed from the store bundle:
            `scanimage-v600 -L` listed
            `epkowa:interpreter:001:020` as an Epson Perfection V600 Photo, and
            `scanimage-v600-ir -L` listed the same device as an Epson
            Perfection V600 Photo with the IR interpreter preloaded.
        - Direct CLI smoke commands:
          - `env V600_HARDWARE_SMOKE=1 zig build run -- scanner smoke --out
            /tmp/v600-live-20260523-rgb.tiff --source tpu --dpi 400 --kind rgb
            --depth 16 --x 0.1 --y 0.1 --width 0.25 --height 0.25
            --timing-report .zig-cache/tmp/v600-live-scanner-feature-support.jsonl`
            wrote `96x100` 16-bit sRGB RGB TIFF and sidecar with
            requested/effective DPI `400/400`; total `scanOnce` took
            `25388919 us`.
          - `env V600_HARDWARE_SMOKE=1 zig build run -- scanner smoke --out
            /tmp/v600-live-20260523-ir.tiff --source tpu --dpi 800 --kind ir
            --depth 8 --x 0.1 --y 0.1 --width 0.25 --height 0.25
            --timing-report .zig-cache/tmp/v600-live-scanner-feature-support.jsonl`
            wrote `200x201` 8-bit Gray IR TIFF and sidecar with
            requested/effective DPI `800/800`; total `scanOnce` took
            `41331150 us`.
          - `env V600_HARDWARE_SMOKE=1 zig build run -- scanner smoke --out
            /tmp/v600-live-20260523-rgbir.tiff --source tpu --dpi 400 --kind
            rgb+ir --depth 16 --x 0.1 --y 0.1 --width 0.25 --height 0.25
            --timing-report .zig-cache/tmp/v600-live-scanner-feature-support.jsonl`
            wrote page 0 RGB `96x100` 16-bit sRGB, page 1 thumbnail `96x100`
            8-bit sRGB, and page 2 IR `200x201` 8-bit Gray. The final sidecar
            recorded requested DPI `400`, RGB effective DPI `400`, and IR
            effective DPI `800`; total `scanRgbIr` took `68154355 us`.
          - Temporary identity LUT generated with `perl -e 'print pack("C*",
            ((0..255), (0..255), (0..255)))' >
            /tmp/v600-live-20260523-identity.lut`, verified at 768 bytes.
            `env V600_HARDWARE_SMOKE=1 zig build run -- scanner smoke --out
            /tmp/v600-live-20260523-lut-rgb.tiff --source tpu --dpi 400 --kind
            rgb --depth 16 --x 0.1 --y 0.1 --width 0.25 --height 0.25
            --lut-file /tmp/v600-live-20260523-identity.lut --timing-report
            .zig-cache/tmp/v600-live-scanner-feature-support.jsonl` wrote
            `96x100` 16-bit sRGB. The sidecar recorded
            `custom_luts_applied=true`, runtime timing recorded
            `linux.scan.environment` detail `custom`, and `tiffinfo` showed
            tag `50000: Custom film LUTs applied`.
          - `env V600_HARDWARE_SMOKE=1 zig build run -- scanner
            processing-smoke --out /tmp/v600-live-20260523-processing-smoke.tiff
            --source tpu --dpi 400 --kind rgb --depth 16 --x 0.1 --y 0.1
            --width 0.25 --height 0.25 --timing-report
            .zig-cache/tmp/v600-live-scanner-feature-support.jsonl` scanned
            `96x100` 16-bit sRGB and loaded it through processing info:
            `{"full_width":96,"full_height":100,"has_ir":false,"dpi":400}`.
        - Direct native UI smoke commands:
          - `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software
            V600_HARDWARE_SMOKE=1 zig build -Dui=true run-ui --
            --preview-worker-smoke --out
            /tmp/v600-live-20260523-native-preview-worker-smoke.tiff
            --timing-report .zig-cache/tmp/v600-live-ui-feature-support.jsonl`
            wrote `1072x3814` 8-bit sRGB hardware preview, loaded it, applied
            Lanczos downsample in `876753 us`, cached a `536x1907` 8-bit
            preview, and completed native preview total in `46437116 us`.
          - `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software
            V600_HARDWARE_SMOKE=1 zig build -Dui=true run-ui --
            --scan-worker-smoke --out
            /tmp/v600-live-20260523-native-scan-worker-smoke.tiff
            --timing-report .zig-cache/tmp/v600-live-ui-feature-support.jsonl`
            wrote `200x201` 16-bit sRGB, drained progress
            `15,31,47,63,79,95,100`, and reported
            `Saved: v600-live-20260523-native-scan-worker-smoke.tiff`.
        - Output inspection:
          - `identify -format '%f[%p] %m %wx%h %[depth]-bit %[colorspace]\n'
            ...` confirmed all geometry and bit-depth values above.
          - `jq` sidecar inspection confirmed device
            `epkowa:interpreter:001:020`, source/kind/depth/DPI fields, RGB+IR
            page metadata, and LUT metadata.
    - [x] Analyze the scanner timing baseline and choose the first optimization.
      - Build a ranked table for startup, preview, single-pass full scan, and
        RGB+IR scan. Separate unavoidable hardware motion/I/O time from
        avoidable host-side time such as repeated discovery, repeated
        capability probes, TIFF rewrites, duplicate file reads, unnecessary
        conversions, excess UI polling, and progress-event overhead.
      - Optimization candidates must preserve function-for-function parity.
        Likely first candidates are cached capabilities, lazy connect/open,
        removing repeated `scanimage --help`, reusing selected device/cache
        state, avoiding duplicate TIFF post-processing, and improving progress
        diagnostics. Do not change scanner algorithms or add speculative
        probes.
      - Add the selected optimization as the next unchecked checkpoint with
        required before/after live timing evidence before implementing it.
      - Completed 2026-05-23:
        - Ranked avoidable host-side timings from live evidence:
          - Probe/startup: discovery `~6.05 s` plus flatbed help `~6.05 s` plus
            TPU help `~6.07 s`, total `~18.21 s`.
          - Tiny selected RGB scan: capability help/probe `~12.08 s` before a
            `~13.25 s` child scan, total `~25.39 s`.
          - Tiny selected IR scan: capability help/probe `~12.11 s` before a
            `~29.17 s` child scan, total `~41.33 s`.
          - Tiny selected RGB+IR scan: two capability probes consumed
            `~25.52 s` before/around `~42.45 s` of scan pass time, total
            `~68.15 s`.
          - Native preview worker: probe `~18.22 s`, scan `~27.33 s`, downsample
            `~0.88 s`, total `~46.44 s`.
          - Native scan worker: capability probe `~12.13 s`, runtime scan
            `~25.63 s`, metadata/state cleanup negligible.
        - First optimization selected: reuse cached scanner capabilities for a
          selected device instead of running flatbed and TPU `scanimage --help`
          on every selected-area scan. This is parity-preserving because the
          capability data is scanner/backend metadata, not image data or scan
          algorithm output.
    - [x] Implement Linux scanner capability-cache reuse for selected-area
          scans.
      - Required behavior:
        - Cache `ScannerCapabilities` by selected device name and wrapper
          capability context in the runtime or app state, and reuse them for
          subsequent selected-area scans where the same device/wrapper context is
          still active.
        - Native UI workers should prefer already-known connected scanner
          capabilities instead of reprobe-only execution when the state has a
          current connected scanner capability record.
        - CLI single-shot behavior may use an on-disk cache only if it is keyed
          by device name plus wrapper/config context and invalidates cleanly; an
          in-process runtime cache is acceptable for UI/session reuse.
        - Preserve correctness: if cached capabilities are missing or fail
          validation, fall back transparently to the current probe path.
      - Required evidence before checking off:
        - Replay/headless tests proving cache hit, cache miss, stale device
          fallback, and no behavior change in command planning.
        - Direct `zig build test --summary all`.
        - Direct `zig build -Dui=true --summary all`.
        - Before/after live timing for at least native preview-worker and native
          scan-worker smokes, plus one CLI RGB selected-area scan if a CLI cache
          is implemented. Report capability lookup/probe time, child scan time,
          total time, selected device, output path, and TIFF/sidecar parity.
      - Completed 2026-05-23:
        - Implementation:
          - Added `State.scanner_capabilities` and
            `State.scannerConnectedWithCapabilities`. The stored capabilities are
            a stable by-value copy without borrowed `scanimage --help` slices.
          - The connect worker now stores probed capabilities in native state
            instead of only copying TPU dimensions.
          - The preview worker receives active connected capabilities from state.
            On cache hit it emits `native.preview.probe` detail `cached` and
            skips `Runtime.probe`; on cache miss it keeps the existing live probe
            fallback.
          - The scan worker passes active connected capabilities into the
            existing `Runtime.scan` capability override, so selected-area scans
            avoid the flatbed/TPU `scanimage --help` probe while preserving
            command planning and metadata sidecar behavior.
          - Capability cache invalidation is session-local and conservative:
            `beginScannerConnect` and `scannerFailed` clear the cache. CLI
            single-shot disk caching was intentionally not implemented in this
            checkpoint because it needs persistent invalidation keys.
        - Headless validation:
          - Added native state tests for storing, replacing, and clearing scanner
            capabilities.
          - Added preview-worker cache-hit test proving queued preview commands
            receive connected capabilities.
          - Added scan-worker cache-hit test proving queued scan commands pass
            connected capabilities into the runtime context.
          - `zig build test --summary all` passed `450/450`.
          - `zig build -Dui=true --summary all` passed.
        - Live before/after timing evidence:
          - Baseline native preview worker from the previous live pass:
            `native.preview.probe=18218779 us`, `native.preview.scan=27331577 us`,
            `native.preview.downsample=876753 us`, total
            `native.preview.total=46437116 us`.
          - Cached native preview command:
            `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software
            V600_HARDWARE_SMOKE=1 zig build -Dui=true run-ui --
            --preview-worker-smoke --out
            /tmp/v600-live-20260523-native-preview-worker-cached.tiff
            --timing-report .zig-cache/tmp/v600-live-ui-capability-cache.jsonl`
            emitted `native.preview.probe` detail `cached`,
            `linux.scan_once.capability_lookup` detail `override`,
            `native.preview.scan=27291923 us`,
            `native.preview.downsample=919098 us`, and total
            `native.preview.total=28221448 us`. Output remained
            `1072x3814` 8-bit sRGB, and the worker cached a `536x1907` 8-bit
            preview. Effective speedup: about `1.65x` wall-clock for the smoke,
            saving the prior `~18.2 s` probe.
          - Baseline native scan worker from the previous live pass:
            `linux.scan_once.capability_lookup=12130892 us`,
            `native.scan.runtime_scan=25627817 us`, output `200x201` 16-bit sRGB.
          - Cached native scan command:
            `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software
            V600_HARDWARE_SMOKE=1 zig build -Dui=true run-ui --
            --scan-worker-smoke --out
            /tmp/v600-live-20260523-native-scan-worker-cached.tiff
            --timing-report .zig-cache/tmp/v600-live-ui-capability-cache.jsonl`
            emitted `linux.scan_once.capability_lookup` detail `override`,
            `native.scan.runtime_scan=13551496 us`, progress
            `15,31,47,63,79,95,100`, and output `200x201` 16-bit sRGB. Effective
            speedup: about `1.89x` for runtime scan, saving the prior `~12.1 s`
            capability probe.
        - Output parity evidence:
          - `identify -format '%f[%p] %m %wx%h %[depth]-bit %[colorspace]\n'
            /tmp/v600-live-20260523-native-preview-worker-cached.tiff
            /tmp/v600-live-20260523-native-scan-worker-cached.tiff` confirmed
            preview `1072x3814` 8-bit sRGB and scan `200x201` 16-bit sRGB.
          - `jq` sidecar inspection confirmed device `epkowa:interpreter:001:020`,
            source `tpu`, preview requested/effective DPI `200/400`, scan
            requested/effective DPI `800/800`, expected bit depth, and
            `custom_luts_applied=false`.

- [x] Implement direct-u16 inverted-positive export output.
  - Scope: same `invert_negative` plus `render_to_display` export result as the
    frozen Python path. This is a representation/pass reduction after
    `renderToDisplay`, not an output-format or algorithm change.
  - Implementation notes:
    - Added `export.ImageU16`, `applyRotationU16`, and
      `prepareInvertedPositiveOutputU16`.
    - Routed inverted export variants through the direct `u16` path, avoiding
      the old `u16 -> f64 -> rotated f64 -> rounded u16` display-output cycle.
    - Kept the existing f64-returning `prepareInvertedPositiveOutput` helper as
      an oracle/test surface.
    - Added `export_render_u16_vs_f64` to the real-scan benchmark commands.
  - Validation:
    - `zig build test --summary all` passed `395/395`.
    - `zig build -Dwebgpu=true test --summary all` passed `397/397`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_render_u16_vs_f64`
      reported old display-f64 helper `2184971 us`, direct-u16 helper
      `1976225 us`, speedup `1.105x`, `max_abs=0`, `rms=0.000`, and equal
      checksums on the `4535x3023` full-resolution crop.
    - `zig build -Dwebgpu=true -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_fullres_inv_cpu_vs_gpu`
      reported CPU `4786929 us`, GPU cold `5249665 us`, GPU warm
      `5056970 us`, warm speedup `0.946x`, `max_abs=1`, `rms=0.050`, and
      `metadata_equal=true`.

- [x] Restore and improve multi-frame export parallelism.
  - Parity note: frozen Python `v600/gui/process_handlers.py:345` uses
    `ThreadPoolExecutor(max_workers=min(n_rects, 4))` when exporting more than
    one selected frame. Zig had been processing frames serially inside
    `processExportFromTiff`, which was both a parity miss and a throughput miss.
    The fixed Python worker cap is not a parity invariant; the invariant is the
    per-frame job boundary, precomputed output paths, read-only shared source
    images, and completion-order result collection.
  - Implementation notes:
    - Added `parallel_frames` to `ExportWorkflowOptions`, defaulting to true.
    - `processExportFromTiff` now builds all per-frame output paths first, then
      uses `planExportParallelism` for multi-frame exports, sharing loaded RGB
      and aligned IR images read-only.
    - The planner is a compile-time-evaluable declarative memory model, not code
      introspection. Zig cannot inspect arbitrary function bodies at comptime to
      infer allocator calls, so the estimator lives beside the workflow and
      mirrors the export branches using `@sizeOf`, frame dimensions, output
      toggles, source image shapes, crop scratch, render percentile scratch,
      inverted-output buffers, and IR-clean scratch estimates.
    - Worker count is bounded by frame count, available CPU cores minus one, and
      predicted memory headroom. On Linux the runtime probe reads
      `/proc/meminfo` `MemAvailable`; the budget subtracts a named system
      reserve, uses a named fraction of the remaining memory, and applies a
      named safety multiplier to the per-worker peak estimate.
    - Frame workers now use `std.heap.smp_allocator` instead of a per-job arena.
      The arena kept temporary crop/render/write buffers alive until the whole
      batch finished, which distorted both real memory use and the scheduler's
      memory model.
    - `ExportWorkflowResult.parallelism` records the selected worker count,
      CPU limit, memory limit, available-memory budget, and raw/adjusted
      per-worker peak estimate for benchmark diagnostics.
    - Each frame worker still uses a deterministic frame-index seed to avoid
      sharing PRNG state across threads.
    - Single-frame exports and explicit `parallel_frames=false` retain a serial
      path for benchmark comparison.
    - Added `export_detected_frames` benchmark case. It runs automatic frame
      detection on the real preview, scales detected rectangles to full
      resolution, then exports those real frame geometries.
  - Validation:
    - `zig build test --summary all` passed `400/400`.
    - `zig build -Dwebgpu=true test --summary all` passed `402/402`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames`
      detected 5 frames, exported 5 files, selected 5 workers
      (`cpu_limit=31`, `mem_limit=25`, adjusted peak `2159506560` bytes/worker),
      and reported serial `18125889 us`, parallel `5981208 us`, speedup
      `3.030x`.

- [x] Add real-scan IR/RGB+IR detected-frame export breakdown coverage.
  - Why this is next: the no-IR/provided-Dmin `inv_only` export path has had
    repeated optimization passes, but the full RGB+IR path still lacks an
    equivalent real-scan timing breakdown for IR alignment, IR crop,
    IR-cleaned negative output, IR-cleaned inverted output, raw inverted output,
    metadata, and write costs.
  - Scope:
    - Add a headless benchmark case that runs automatic frame detection on a real
      RGBIR scan, scales detected frames to full resolution, exports all Python
      output variants (`ir_neg`, `ir_inv`, `inv_only`) with IR alignment enabled,
      and reports the existing workflow/frame timing fields.
    - Preserve current export behavior. This checkpoint is measurement only; do
      not replace Meijering, inpainting, IR alignment, interpolation, TIFF
      writing, or output-selection algorithms while adding the benchmark.
    - Keep the existing no-IR `export_detected_frames_breakdown` case unchanged
      so future comparisons can distinguish the optimized no-IR path from the
      full RGB+IR path.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - A ReleaseFast benchmark on a real scan from `scans/`, preferably a large
      3200 DPI RGBIR scan when memory allows, recording exact command, image
      dimensions, detected frame count, selected workers, wall time, and the
      stage breakdown including `ir_align_us`, `ir_crop_us`, `ir_clean_us`,
      `ir_neg_prepare_us`, `inversion_us`, `display_render_us`, `metadata_us`,
      and `write_us`.
    - Update `docs/PERFORMANCE_STRATEGY.md` and `docs/PARITY_MANIFEST.md` with
      the measured baseline and the next ranked optimization target.
  - Completed 2026-05-20:
    - Added `export_detected_frames_ir_all_breakdown` to
      `src/benchmarks/processing_commands.zig`. The case reuses automatic frame
      detection on the selected real scan, scales detected frames to full
      resolution, enables all three Python output variants (`ir_neg`, `ir_inv`,
      `inv_only`), enables IR alignment, and prints the existing workflow/frame
      timing fields without changing the export algorithm.
    - `zig build test --summary all` passed `435/435`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      completed on the large RGBIR scan. It detected 5 frames, exported 15
      files, selected 5 workers (`cpu_limit=31`, `mem_limit=12`, adjusted peak
      `4592713860` bytes/worker), and reported wall time `190808106 us`.
    - Stage timings: `load_full_us=599856`, `ir_align_us=1673798`,
      `frame_processing_us=188211285`, aggregate `rgb_crop_us=905109`,
      `ir_crop_us=437284`, `ir_clean_us=787208607`,
      `ir_neg_prepare_us=718080`, `inversion_us=1246442`,
      `display_render_us=1134027`, `metadata_us=555`, and
      `write_us=1029704`. Aggregate frame timings are summed across parallel
      workers and can exceed wall time.
    - Ranked next target: add a deeper `ir_clean` timing breakdown before any
      optimization. Split at least defect-mask construction, Meijering line
      response, morphology/component filtering, mask resize/dilate, ROI
      traversal, local grain estimation, biharmonic solve, grain synthesis, and
      masked writeback. The current top-level evidence shows IR cleaning
      dominates full RGB+IR export by orders of magnitude over alignment,
      inversion, rendering, metadata, and TIFF writing.

- [x] Add `ir_clean` substage timing before optimizing IR dust removal.
  - Scope:
    - Add optional timing instrumentation inside the current Zig IR-cleaning
      implementation without changing the Python-parity algorithms.
    - Split at least: defect-mask construction, adaptive dust detection,
      line-defect detection, Meijering response, morphology/component filtering,
      RGB mask resize/dilate, runtime noise generation, ROI traversal/extraction,
      local grain estimation, biharmonic solve, grain synthesis, and masked
      writeback.
    - Surface those timings through the existing export frame/workflow timing
      aggregation and through the `export_detected_frames_ir_all_breakdown`
      benchmark row.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - Re-run
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`.
    - Update `docs/PERFORMANCE_STRATEGY.md` and `docs/PARITY_MANIFEST.md` with
      the ranked `ir_clean` substage baseline and the next concrete optimization
      candidate.
  - Completed 2026-05-20:
    - Added `IrCleanTimings` in `src/processing/ir.zig` and timed wrappers for
      the existing IR-cleaning functions. Existing public untimed calls still
      route through the same behavior with null timing.
    - Surfaced the IR-clean substages through `ProcessFrameTimings` and
      `export_detected_frames_ir_all_breakdown`.
    - `zig build test --summary all` passed `435/435`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall time `190718657 us`, 5 detected frames, 15 files, and 5
      workers.
    - Aggregate IR-clean worker timing was `ir_clean_us=785563995`, dominated by
      `ir_defect_mask_us=778452492`. Within defect-mask construction,
      `ir_adaptive_dust_us=635418409`, `ir_close_us=85680031`,
      `ir_dilate_us=40233518`, `ir_line_detection_us=16917340`, and
      `ir_meijering_us=16403513`.
    - Inpainting was not the primary hotspot in this run:
      `ir_inpaint_total_us=6501771`, with `ir_biharmonic_us=2270265`,
      `ir_grain_synthesis_us=1831843`, `ir_local_grain_us=1200286`, and
      `ir_inpaint_noise_us=198929`.
    - Ranked next target: optimize adaptive dust-mask construction first,
      especially the repeated large Gaussian blur and full-frame pass structure.
      The second target is mask morphology close/dilate. Meijering and
      biharmonic inpainting should not be the first optimization target based on
      this real-scan evidence.

- [x] Optimize adaptive dust-mask Gaussian blur interior loops.
  - Scope:
    - Preserve the current Python-parity Gaussian kernel, reflect-101 boundary
      behavior, pass order, and f64 arithmetic.
    - Avoid per-sample reflect-index work for horizontal and vertical interior
      pixels where the whole Gaussian kernel is in bounds.
    - Do not change Meijering, morphology, inpainting, or output selection in
      this checkpoint.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - Re-run
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`.
    - Record before/after wall time plus `ir_adaptive_dust_us`,
      `ir_defect_mask_us`, `ir_clean_us`, and any other changed stage in
      `docs/PERFORMANCE_STRATEGY.md`, `docs/PARITY_MANIFEST.md`, and this plan.
  - Completed 2026-05-20:
    - Updated `gaussianBlur` in `src/processing/ir.zig` to split both
      separable passes into boundary and interior regions. Boundary pixels
      still use `reflect101Index`; interior pixels now use direct contiguous
      indexing with the same kernel weights, pass order, and f64 accumulation.
    - No Meijering, morphology, inpainting, or output-selection behavior was
      changed in this checkpoint.
    - `zig build test --summary all` passed `435/435`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall time `159440683 us`, 5 detected frames, 15 files, and 5
      workers.
    - Against the immediately preceding IR-clean substage baseline, wall time
      improved from `190718657 us` to `159440683 us` (`1.196x`), aggregate
      `ir_clean_us` improved from `785563995` to `718263872` (`1.094x`),
      `ir_defect_mask_us` improved from `778452492` to `711082383` (`1.095x`),
      and `ir_adaptive_dust_us` improved from `635418409` to `557917334`
      (`1.139x`).
    - Remaining large buckets in this run include `ir_adaptive_dust_us`,
      `ir_close_us=93476919`, `ir_dilate_us=42286263`, and
      `ir_meijering_us=16677145`. The next performance pass should continue
      with adaptive dust-mask pass structure and/or morphology before revisiting
      Meijering or inpainting.

- [x] Evaluate f32 intermediates for adaptive dust-mask construction.
  - Scope:
    - Keep an explicit f64 adaptive-dust path available as the reference/oracle
      comparator.
    - Add a f32 adaptive-dust intermediate path for the image-wide normalized
      IR, Gaussian backgrounds, squared buffers, coarse replacement pass, and
      final sigma calculation.
    - Compare final binary masks and, if promoted into production, final export
      pixels rather than requiring byte-for-byte equality of every intermediate
      floating-point value. Very small final differences are acceptable when
      the speedup is meaningful.
    - Do not change Meijering, morphology, inpainting, scanner I/O, or output
      selection in this checkpoint.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - Run
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case ir_adaptive_dust_f32_tradeoff`
      and record f64-vs-f32 mask timing on a representative detected
      full-resolution crop, speedup, defect-pixel delta, mask max/RMS/MSE, and
      mismatch rate.
    - If f32 is enabled for the production IR-clean path, re-run
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      and record before/after wall time, `ir_adaptive_dust_us`,
      `ir_defect_mask_us`, and `ir_clean_us`.
    - Update `docs/PERFORMANCE_STRATEGY.md`, `docs/PARITY_MANIFEST.md`, and
      this plan with the accepted tolerance decision and benchmark evidence.
  - Completed 2026-05-20:
    - Added `AdaptiveDustPrecision`, a retained f64 reference path, and an
      explicit f32 adaptive-dust path covering normalized IR, Gaussian
      backgrounds, squared buffers, coarse replacement, and final sigma
      calculation.
    - Added `ir_adaptive_dust_f32_tradeoff` to
      `bench-processing-commands`. The benchmark uses automatic frame detection
      on the real scan, selects one representative detected full-resolution IR
      crop, and compares final binary masks rather than requiring intermediate
      float equality.
    - `zig build test --summary all` passed `435/435`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case ir_adaptive_dust_f32_tradeoff`
      reported a `3063x4600` crop (`14089800` pixels): f64 mask time
      `136109894 us`, f32 mask time `112945584 us` (`1.205x`), f64 adaptive
      substage `107138353 us`, f32 adaptive substage `83793576 us` (`1.279x`),
      reference defects `170799`, f32 defects `182329`, defect delta `11530`,
      mask mismatches `15054`, mismatch rate `0.107%`, mask RMS `8.335156`,
      and mask MSE `69.474822`.
    - Temporarily enabling f32 for the configured production IR-clean path did
      not produce a wall-clock win in the full parallel RGB+IR export. Two f32
      runs reported wall times `165267646 us` and `163784775 us`, while the
      current f64 reference run reported `159448976 us`.
    - The f32 full-export runs did reduce aggregate worker substages
      (`ir_adaptive_dust_us` down to `540898167`/`539335673` from current f64
      `557821104`, and `ir_clean_us` down to `697968369`/`696632356` from
      current f64 `716107372`), but the slowest-worker wall time regressed.
      Decision: keep production configuration on f64 for now, retain f32 as an
      explicit benchmark/experimental path, and revisit after f32-specific loop
      fusion, SIMD, or parallel scheduling work.

- [x] Optimize IR mask morphology ellipse iteration without changing kernel
      semantics.
  - Scope:
    - Preserve the existing ellipse kernel geometry, border clipping behavior,
      close-then-area-filter-then-dilate order, and binary 0/255 output.
    - Replace dense boolean kernel-cell iteration with precomputed active row
      spans for the same ellipse so close/dilate skip inactive kernel cells.
    - Do not change adaptive dust, Meijering, component filtering, inpainting,
      scanner I/O, or output selection in this checkpoint.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - Re-run
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`.
    - Record before/after wall time plus `ir_close_us`, `ir_dilate_us`,
      `ir_defect_mask_us`, `ir_clean_us`, and any visible regressions in
      `docs/PERFORMANCE_STRATEGY.md`, `docs/PARITY_MANIFEST.md`, and this plan.
  - Completed 2026-05-20:
    - Replaced dense boolean ellipse-kernel iteration in `dilateMask` and
      `erodeMask` with precomputed active row spans derived from the same
      ellipse formula. Border clipping and binary output semantics are
      unchanged.
    - Added a geometry test proving row spans match dense ellipse kernels for
      radii `0`, `1`, `2`, `4`, `16`, and `24`.
    - `zig build test --summary all` passed `436/436`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall time `144076086 us`, 5 detected frames, 15 files, and 5
      workers.
    - Compared with the current f64 reference run before this checkpoint, wall
      time improved from `159448976 us` to `144076086 us` (`1.107x`),
      aggregate `ir_clean_us` improved from `716107372` to `636850277`
      (`1.124x`), `ir_defect_mask_us` from `708843297` to `629591097`
      (`1.126x`), `ir_close_us` from `91518424` to `36048515` (`2.539x`), and
      `ir_dilate_us` from `42157517` to `18597569` (`2.267x`).
    - Remaining dominant measured bucket is still adaptive dust construction:
      `ir_adaptive_dust_us=557736885`. Meijering and inpainting remain much
      smaller in this run.

- [x] Fuse adaptive-dust coarse-mask writeback into cleaned IR staging.
  - Scope:
    - Preserve the current f64 production adaptive-dust arithmetic, thresholds,
      Gaussian calls, and final mask/sigma outputs.
    - Remove the temporary full-size `coarse_mask` allocation and the separate
      `ir_f` duplicate/writeback pass by writing `ir_cleaned` directly during
      the first coarse-threshold loop.
    - Apply the same mechanical cleanup to the explicit f32 experimental path
      so both implementations stay structurally aligned.
    - Do not change morphology, Meijering, component filtering, inpainting,
      scanner I/O, or output selection in this checkpoint.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - Re-run
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`.
    - Record before/after wall time plus `ir_adaptive_dust_us`,
      `ir_defect_mask_us`, `ir_clean_us`, and any visible regressions in
      `docs/PERFORMANCE_STRATEGY.md`, `docs/PARITY_MANIFEST.md`, and this plan.
  - Completed 2026-05-20:
    - Updated the f64 production and f32 experimental adaptive-dust paths to
      write `ir_cleaned` during the first coarse-threshold pass, removing the
      temporary full-size `coarse_mask` allocation and the separate duplicate
      writeback pass.
    - The threshold arithmetic, Gaussian calls, f64 production precision,
      final sigma/mask formulas, morphology, Meijering, inpainting, scanner
      I/O, and output selection are unchanged.
    - `zig build test --summary all` passed `436/436`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall time `143598455 us`, 5 detected frames, 15 files, and 5
      workers.
    - Compared with the immediately preceding row-span benchmark, wall time
      moved from `144076086 us` to `143598455 us` (`1.003x`). Aggregate worker
      substage timings were effectively neutral: `ir_clean_us` moved from
      `636850277` to `637732625`, `ir_defect_mask_us` from `629591097` to
      `630417030`, and `ir_adaptive_dust_us` from `557736885` to `558328648`.
      The change is retained as a memory-pressure and pass-count cleanup, not
      as a material speed win.

- [x] Evaluate tolerated final-output approximate/f32 IR fast paths only where
      they produce a meaningful end-to-end win.
  - Scope:
    - Use the user's 2026-05-20 tolerance direction: byte-for-byte parity with
      Python or intermediate Zig buffers is not required for numeric hot paths,
      but final-output errors must be very small and explicitly measured.
    - Start from the existing adaptive-dust f32 path and real-scan full-export
      evidence; do not promote it unless full-export wall time improves, not
      just aggregate worker substages.
    - Consider f32-specific loop fusion, SIMD, smaller/streamed temporaries, or
      final-mask/output-toleranced approximations. Do not switch detector,
      morphology, Meijering, inpainting, or scanner algorithms under this item.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - A ReleaseFast benchmark on `scans/scan_0004_rgbir_3200dpi.tiff` that
      reports full-export wall time and the same IR substages as
      `export_detected_frames_ir_all_breakdown`.
    - Final-output error metrics at the relevant surface: final mask
      mismatches/RMS/MSE for mask-only changes, final export `u16` max/RMS/MSE
      and metadata equality for export changes, and final preview `u8`
      max/RMS/MSE for preview changes.
    - Update `docs/PERFORMANCE_STRATEGY.md`, `docs/PARITY_MANIFEST.md`, and
      this plan with the chosen tolerance, speedup, and acceptance/rejection
      decision.
  - Completed 2026-05-20:
    - Added `ExportWorkflowOptions.adaptive_dust_precision_override` so
      benchmarks can force f64 or f32 adaptive-dust precision without changing
      production defaults or config semantics.
    - Added `export_detected_frames_ir_f32_tradeoff`, which runs the same
      automatically detected full-resolution RGB+IR export once with f64
      adaptive dust and once with f32 adaptive dust, then compares the final
      TIFF outputs and metadata.
    - `zig build test --summary all` passed `436/436`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_f32_tradeoff`
      reported reference wall time `143882065 us` and f32 wall time
      `148260825 us` (`0.970x`, slower).
    - f32 did reduce aggregate worker substages:
      `ir_clean_us=638415641 -> 617929999`, `ir_defect_mask_us=631029883 ->
      610858126`, and `ir_adaptive_dust_us=558880229 -> 538774812`.
    - Final export error was not acceptably small: `max_abs=27825`, RMS
      `105.251609`, MSE `11077.901284`, `65843162` mismatched samples across
      the 15-file export set, mismatch rate `10.407%`, with metadata and file
      sets equal.
    - Decision: do not promote the current f32 adaptive-dust path. The
      toleranced policy is accepted, but this candidate fails both criteria:
      full-export wall time is slower and final-output error is too large.

- [x] Optimize remaining f64 adaptive-dust Gaussian/pass structure before
      revisiting approximate IR output.
  - Scope:
    - Treat adaptive dust construction as the dominant current measured IR
      hotspot: after the full-output f32 rejection, the f64 reference still
      spends about `558880229 us` aggregate worker time in
      `ir_adaptive_dust_us` on `scan_0004_rgbir_3200dpi.tiff`.
    - Prefer exact or final-output-toleranced changes that reduce Gaussian
      blur memory traffic and pass count: separable-row staging reuse,
      allocation reuse, SIMDable row/column kernels, tiling/cache locality,
      or parallelism within a frame when frame-level workers leave cores idle.
    - Do not change morphology, Meijering, inpainting, scanner I/O, frame
      geometry, or output selection in this checkpoint.
    - If an approximate or f32 variant is tested, compare final masks and final
      TIFF outputs, not only internal buffers.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - ReleaseFast benchmark on `scans/scan_0004_rgbir_3200dpi.tiff` using
      `export_detected_frames_ir_all_breakdown` or a more focused adaptive-dust
      benchmark that still reports final-output error.
    - Before/after wall time, `ir_adaptive_dust_us`, `ir_defect_mask_us`,
      `ir_clean_us`, memory/allocation changes where measurable, and final
      output parity/tolerance metrics.
    - Update `docs/PERFORMANCE_STRATEGY.md`, `docs/PARITY_MANIFEST.md`, and
      this plan with the accepted or rejected result.
  - Completed 2026-05-20:
    - First attempted exact Gaussian kernel/scratch reuse and second-pass
      output-buffer reuse for the f64 adaptive-dust path. It preserved tests
      but regressed the real-scan benchmark, so it was reverted. The non-inline
      helper version reported wall `174015799 us` and
      `ir_adaptive_dust_us=609626253`; the inline helper version improved to
      wall `149925086 us` and `ir_adaptive_dust_us=565721791`, still worse
      than the accepted pre-item baseline.
    - Accepted the f64 Gaussian symmetry optimization instead: the separable
      blur now uses paired left/right and top/bottom samples for odd kernels,
      preserving the same reflect-101 boundary behavior and Gaussian weights
      while reducing the per-pixel kernel work from 301 weighted samples to
      one center sample plus 150 symmetric pairs for the default IR blur.
    - No morphology, Meijering, inpainting, scanner I/O, frame geometry, or
      output selection code changed in the accepted path.
    - `zig build test --summary all` passed `436/436`, including exact Python
      IR fixtures for adaptive thresholding, binary masks, and full IR clean
      outputs.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall time `115466073 us`, 5 detected frames, 15 files, 5
      workers, `estimated_worker_peak_bytes=3061809240`, and
      `adjusted_worker_peak_bytes=4592713860`.
    - Compared with the immediately preceding accepted coarse-mask writeback
      baseline, wall time improved from `143598455 us` to `115466073 us`
      (`1.244x`), aggregate `ir_clean_us` from `637732625` to `501935111`
      (`1.271x`), `ir_defect_mask_us` from `630417030` to `494646364`
      (`1.275x`), and `ir_adaptive_dust_us` from `558328648` to `414778748`
      (`1.346x`).
    - Final-output evidence: the existing Python-oracle IR tests still passed
      with exact binary mask equality and fixture tolerances; no final-output
      tolerance expansion was needed.

- [x] Re-rank RGB+IR export hotspots after symmetric Gaussian optimization.
  - Scope:
    - Use the latest `export_detected_frames_ir_all_breakdown` result as the
      new baseline.
    - Decide the next smallest optimization target from the remaining measured
      buckets rather than returning automatically to adaptive dust. Current
      visible candidates include residual adaptive dust, morphology
      close/dilate, Meijering line detection, inpainting substeps, write time,
      and display/inversion work.
    - Do not switch algorithms. Any approximation must use the final-output
      tolerance policy and record final mask/export error.
  - Required evidence before checking off:
    - A short ranked analysis in this plan and `docs/PERFORMANCE_STRATEGY.md`.
    - If a new optimization item is selected, add it as the next unchecked
      checkpoint with exact scope and required evidence.
  - Completed 2026-05-20:
    - New baseline command:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`.
    - New wall time is `115466073 us`; `frame_processing_us=112809952`;
      `workers=5`; `estimated_worker_peak_bytes=3061809240`;
      `adjusted_worker_peak_bytes=4592713860`.
    - Ranked aggregate buckets:
      1. `ir_adaptive_dust_us=414778748`, still the dominant bucket.
      2. Morphology: `ir_close_us=42261132` and `ir_dilate_us=20326471`,
         now large enough to matter again after Gaussian pairing.
      3. Line detection: `ir_line_detection_us=17074953`, almost entirely
         `ir_meijering_us=16561774`.
      4. Inpainting: `ir_inpaint_total_us=6689753`, with
         `ir_biharmonic_us=2334478`, `ir_grain_synthesis_us=1835238`, and
         `ir_local_grain_us=1218085`.
      5. Non-IR processing buckets are much smaller in this RGB+IR profile:
         `inversion_us=1266442`, `display_render_us=1164135`,
         `write_us=1091038`, `rgb_crop_us=970976`, and
         `ir_neg_prepare_us=704631`.
    - Decision: continue with adaptive-dust Gaussian inner-loop work first,
      because it is still about 6.6x larger than close+dilate combined.
      Morphology and Meijering are the next secondary candidates if further
      Gaussian work stops producing wins.

- [x] Optimize f64 adaptive-dust symmetric Gaussian inner loops.
  - Scope:
    - Preserve the accepted f64 Gaussian operation: same odd kernel weights,
      same reflect-101 boundary behavior, same separable horizontal-then-
      vertical pass order, and same final adaptive-dust formulas.
    - Target the remaining `ir_adaptive_dust_us=414778748` bucket by improving
      the symmetric-pair inner loops, especially the interior rows/columns.
      Try unrolling, SIMD-friendly pair accumulation, or cache-local loop
      structure; reject changes that regress the full export benchmark.
    - Do not change morphology, Meijering, inpainting, scanner I/O, frame
      geometry, output selection, f32 production defaults, or the Gaussian
      kernel itself.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - ReleaseFast benchmark on `scans/scan_0004_rgbir_3200dpi.tiff` using
      `export_detected_frames_ir_all_breakdown`.
    - Before/after wall time, `ir_adaptive_dust_us`, `ir_defect_mask_us`,
      `ir_clean_us`, and final-output parity/tolerance evidence from the IR
      Python fixtures or a more focused final-output comparison.
    - Update `docs/PERFORMANCE_STRATEGY.md`, `docs/PARITY_MANIFEST.md`, and
      this plan with the accepted or rejected result.
  - Completed 2026-05-20:
    - Tried inline helper extraction plus four-step unrolling of the symmetric
      pair accumulation. It passed tests but regressed the full benchmark to
      wall `135528031 us` and `ir_adaptive_dust_us=462300729`, so the helper
      extraction and unroll were reverted.
    - Accepted a smaller inner-loop cleanup: hoist the Gaussian center weight
      and the positive-side pair-weight slice out of the pixel loops so hot
      loops use `pair_weights[d - 1]` instead of recomputing
      `kernel[radius + d]`.
    - `zig build test --summary all` passed `436/436`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall time `112640045 us`, 5 detected frames, 15 files, and 5
      workers.
    - Compared with the symmetric-Gaussian baseline, wall time improved from
      `115466073 us` to `112640045 us` (`1.025x`), aggregate `ir_clean_us`
      from `501935111` to `489493295` (`1.025x`),
      `ir_defect_mask_us` from `494646364` to `482300081` (`1.026x`), and
      `ir_adaptive_dust_us` from `414778748` to `410319185` (`1.011x`).
    - Final-output evidence: Python-oracle IR tests still passed with exact
      binary mask equality and fixture tolerances. No final-output tolerance
      expansion was needed.

- [x] Re-rank RGB+IR export hotspots after pair-weight Gaussian cleanup.
  - Scope:
    - Use the latest `export_detected_frames_ir_all_breakdown` result as the
      new baseline.
    - Decide whether the next smallest useful target is still adaptive dust or
      whether morphology close/dilate, Meijering, or inpainting now offer a
      better return.
    - Add the next concrete optimization checkpoint with required evidence.
  - Required evidence before checking off:
    - A short ranked analysis in this plan and `docs/PERFORMANCE_STRATEGY.md`.
    - If a new optimization item is selected, add it as the next unchecked
      checkpoint with exact scope and required evidence.
  - Completed 2026-05-20:
    - New baseline command:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`.
    - New wall time is `112640045 us`; `frame_processing_us=110027631`;
      `workers=5`; `estimated_worker_peak_bytes=3061809240`;
      `adjusted_worker_peak_bytes=4592713860`.
    - Ranked aggregate buckets:
      1. `ir_adaptive_dust_us=410319185`, still dominant.
      2. Morphology close+dilate combined:
         `ir_close_us=36017015 + ir_dilate_us=18620195 = 54637210`.
      3. Line detection: `ir_line_detection_us=17137935`, mostly
         `ir_meijering_us=16565769`.
      4. Inpainting: `ir_inpaint_total_us=6586451`.
      5. Non-IR/export overhead remains small: `inversion_us=1277419`,
         `display_render_us=1148002`, `write_us=1080015`,
         `rgb_crop_us=967748`, and `ir_neg_prepare_us=714051`.
    - Decision: adaptive dust remains about `7.51x` larger than close+dilate
      combined, so the next checkpoint should still target adaptive dust.
      Scalar pair-loop cleanup is now producing smaller wins, so the next
      candidate should be dynamic intra-frame parallelism for the large
      Gaussian passes, with worker counts derived from available cores and the
      outer export-worker count rather than hardcoded.

- [x] Evaluate dynamic intra-frame parallelism for f64 adaptive-dust Gaussian
      passes.
  - Scope:
    - Keep the accepted f64 adaptive-dust algorithm: same normalized IR input,
      Gaussian kernels, reflect-101 boundaries, pass order, thresholds, final
      mask, and `n_sigma2` output.
    - Explore parallelizing large Gaussian horizontal/vertical passes inside a
      frame only when it is expected to help. The worker count must be dynamic:
      account for available CPU cores, leave at least one core free, and divide
      by the active outer frame-export worker count where that context is
      available. Do not hardcode fixed four-thread parallelism.
    - Avoid per-row thread spawning. Use coarse row ranges or a reusable/simple
      per-blur worker plan so thread overhead does not dominate smaller images.
    - Default behavior must remain deterministic and must fall back to single
      threaded execution for small images, single-core systems, tests, or any
      missing worker context.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - ReleaseFast benchmark on `scans/scan_0004_rgbir_3200dpi.tiff` using
      `export_detected_frames_ir_all_breakdown`.
    - Before/after wall time, `ir_adaptive_dust_us`, `ir_defect_mask_us`,
      `ir_clean_us`, selected outer workers, selected inner workers, and final
      output tolerance evidence from the Python IR fixtures or a focused
      comparison. Exact Python-output bytes are not required if the final error
      is very small and the speedup is large, but the operation must remain the
      same adaptive-dust Gaussian pipeline.
    - Update `docs/PERFORMANCE_STRATEGY.md`, `docs/PARITY_MANIFEST.md`, and
      this plan with the accepted or rejected result.
  - Completed 2026-05-20:
    - Added dynamic inner adaptive-dust worker selection to the export
      workflow. The selected count is derived from the existing outer export
      planner: use the CPU worker limit that already leaves one core free,
      divide by the active frame-export worker count, and fall back to one
      worker when no useful worker context is available.
    - Added `adaptive_worker_count`/`worker_count` options through IR-clean
      and threshold options. Defaults remain single-threaded, so direct unit
      tests and small standalone calls do not spawn worker threads unless a
      caller passes scheduling context.
    - Updated f64 `gaussianBlur` to process coarse row ranges in parallel for
      large images. It still uses the same f64 kernel, reflect-101 boundaries,
      symmetric pair accumulation, and horizontal-then-vertical pass order.
      Threading is per blur pass and per coarse range, not per row.
    - Added benchmark reporting for the selected inner worker count and added
      a focused test proving the f64 Gaussian parallel row-range path is
      exactly equal to the single-threaded path on a large synthetic image.
    - `zig build test --summary all` passed `437/437`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall time `66473821 us`, 5 detected frames, 15 files, 5 outer
      workers, CPU worker limit `31`, memory worker limit `12`,
      `ir_inner_workers=6`, `estimated_worker_peak_bytes=3061809240`, and
      `adjusted_worker_peak_bytes=4592713860`.
    - Compared with the pair-weight baseline, wall time improved from
      `112640045 us` to `66473821 us` (`1.695x`), aggregate `ir_clean_us`
      from `489493295` to `290608197` (`1.684x`),
      `ir_defect_mask_us` from `482300081` to `283388034` (`1.702x`), and
      `ir_adaptive_dust_us` from `410319185` to `208921810` (`1.964x`).
    - Final-output evidence: the new parallel Gaussian row-range test proves
      exact f64 blur equality against the single-threaded implementation, and
      the existing Python-oracle IR fixtures still pass. No final-output
      tolerance expansion was needed for this exact scheduling change.
    - Remaining ranked buckets from this run: `ir_adaptive_dust_us=208921810`,
      morphology close+dilate `37097562 + 18686317 = 55783879`, line
      detection `18467284`, and inpainting `6616422`.

- [x] Break down residual adaptive-dust time after dynamic Gaussian
      parallelism.
  - Scope:
    - Keep the accepted f64 adaptive-dust algorithm and dynamic worker
      scheduling unchanged.
    - Instrument or benchmark the remaining adaptive-dust substeps separately:
      first Gaussian background, squared-input fill, second Gaussian, coarse
      replacement loop, cleaned-square fill, third Gaussian background, fourth
      Gaussian square, and final mask/sigma loop.
    - The goal is to decide whether more adaptive-dust work remains the best
      target, or whether the next optimization should move to morphology
      close/dilate or Meijering.
    - Do not change output behavior in this checkpoint unless the measurement
      exposes an obvious same-behavior pass fusion.
  - Required evidence before checking off:
    - `zig build test --summary all` if code changes.
    - A ReleaseFast benchmark on `scans/scan_0004_rgbir_3200dpi.tiff` that
      reports adaptive-dust substage timings and the existing full RGB+IR
      export breakdown.
    - Record ranked substages, chosen next target, and any same-behavior
      optimization result in `docs/PERFORMANCE_STRATEGY.md`,
      `docs/PARITY_MANIFEST.md` if symbols/evidence changed, and this plan.
  - Completed 2026-05-20:
    - Added adaptive-dust substage timers for normalization, first background
      Gaussian, first square fill, first square Gaussian, coarse replacement,
      second background Gaussian, second square fill, second square Gaussian,
      and final mask/sigma writeout.
    - The instrumentation is read-only timing/reporting. It does not change
      adaptive-dust arithmetic, Gaussian kernels, worker counts, thresholds,
      masks, or export output.
    - `zig build test --summary all` passed `437/437`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall time `64864199 us`, 5 outer workers, and
      `ir_inner_workers=6`.
    - Residual `ir_adaptive_dust_us=198285318` is still almost entirely the
      four f64 Gaussian calls:
      `ir_adaptive_background1_us=61186856`,
      `ir_adaptive_blurred_square1_us=55810809`,
      `ir_adaptive_background2_us=46629868`, and
      `ir_adaptive_blurred_square2_us=32446593`, for `196074126 us` total.
    - Non-Gaussian adaptive work is now small by comparison:
      normalization `310776`, square1 `334140`, coarse replacement `587349`,
      square2 `82847`, and final mask/sigma `575032`.
    - Decision: do not switch to morphology yet. Morphology close+dilate is
      `37265119 + 18792718 = 56057837`, while residual adaptive Gaussian work
      is still about `3.50x` larger. The next target should be exact paired
      Gaussian work: combine same-kernel background and squared-buffer blurs
      into paired two-output passes where it preserves per-output accumulation
      order.

- [x] Evaluate exact paired Gaussian blur for adaptive-dust background and
      squared-buffer passes.
  - Scope:
    - Keep the same adaptive-dust algorithm, f64 precision, reflect-101
      boundaries, Gaussian kernels, symmetric pair accumulation, dynamic row
      worker selection, thresholds, final mask, and `n_sigma2` output.
    - Explore a two-input/two-output Gaussian helper for the two same-kernel
      pairs: `ir_f` with `ir_f^2`, and `ir_cleaned` with `ir_cleaned^2`.
      The helper must preserve each output's single-image accumulation order
      so exact f64 equality remains possible.
    - The goal is to reduce duplicated row/column traversal, thread setup,
      cache misses, and allocation pressure without approximating or changing
      the detector.
    - Reject the change if it regresses the real-scan full-export benchmark.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - A focused test proving paired Gaussian output equals two separate
      `gaussianBlur` calls on a large image.
    - ReleaseFast `export_detected_frames_ir_all_breakdown` on
      `scans/scan_0004_rgbir_3200dpi.tiff` with before/after wall,
      `ir_adaptive_dust_us`, the four adaptive Gaussian substages,
      `ir_defect_mask_us`, and `ir_clean_us`.
    - Update `docs/PERFORMANCE_STRATEGY.md`, `docs/PARITY_MANIFEST.md`, and
      this plan with accepted or rejected evidence.
  - Completed 2026-05-20:
    - Implemented an exact paired f64 Gaussian prototype that computed
      `ir_f`/`ir_f^2` and `ir_cleaned`/`ir_cleaned^2` through paired
      two-output horizontal and vertical passes.
    - Added a focused large-image test proving the paired helper produced
      exactly the same f64 slices as two separate `gaussianBlur` calls for the
      primary and squared-input outputs.
    - `zig build test --summary all` passed `438/438` with the prototype.
    - The real-scan benchmark regressed, so the prototype was rejected and
      reverted. The paired run reported wall `73487216 us`,
      `ir_clean_us=303816205`, `ir_defect_mask_us=296420226`,
      `ir_adaptive_dust_us=222767894`, `ir_adaptive_pair1_us=137515218`, and
      `ir_adaptive_pair2_us=83670512`.
    - The accepted substage baseline before the prototype was wall
      `64864199 us` and `ir_adaptive_dust_us=198285318`. After reverting,
      `zig build test --summary all` passed `437/437`, and the same benchmark
      reported wall `65905071 us`, `ir_clean_us=286744747`,
      `ir_defect_mask_us=279629325`, and `ir_adaptive_dust_us=204580083`.
    - Decision: keep the separate exact Gaussian path. The paired helper
      reduced duplicated control structure but worsened cache/memory behavior
      enough to lose end-to-end.

- [x] Evaluate adaptive Gaussian inner-worker count and cache-locality
      heuristic.
  - Scope:
    - Keep the accepted f64 adaptive-dust algorithm: same normalized IR input,
      Gaussian kernels, reflect-101 boundaries, symmetric pair accumulation,
      pass order, thresholds, final mask, and `n_sigma2` output.
    - Measure whether `innerAdaptiveDustWorkerCount = cpu_worker_limit /
      outer_worker_count` is the best heuristic for large RGB+IR exports, or
      whether memory bandwidth and strided vertical passes prefer fewer inner
      workers.
    - Add only benchmark/test plumbing needed to compare inner worker counts;
      production defaults must remain dynamic, deterministic, and single-
      threaded when no export scheduling context exists.
    - If a better heuristic is found, keep it explainable from available cores,
      outer worker count, and measured memory/cache behavior. Do not hardcode a
      fixed worker count.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - ReleaseFast comparisons on `scans/scan_0004_rgbir_3200dpi.tiff` for at
      least the current heuristic, single inner worker, and one lower inner
      worker count, reporting wall time, `ir_inner_workers`,
      `ir_adaptive_dust_us`, the four Gaussian substages,
      `ir_defect_mask_us`, and `ir_clean_us`.
    - If production heuristic changes, record before/after wall time and exact
      output/tolerance evidence from tests or focused comparisons.
    - Update `docs/PERFORMANCE_STRATEGY.md`, `docs/PARITY_MANIFEST.md` if
      symbols/evidence changed, and this plan.
  - Completed 2026-05-20:
    - Added benchmark-only `adaptive_dust_worker_count_override` plumbing on
      `ExportWorkflowOptions`, with production default behavior still using the
      dynamic `cpu_worker_limit / outer_worker_count` heuristic.
    - Added a focused unit test proving the default resolves to the dynamic
      value and explicit overrides clamp to at least one worker.
    - Added `export_detected_frames_ir_worker_tradeoff`, which runs the same
      detected-frame full RGB+IR export with the dynamic worker count, forced
      single inner worker, and a lower mid-count override, then compares
      override outputs back to the dynamic export.
    - `zig build test --summary all` passed `438/438`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_worker_tradeoff`
      reported exact output matches for override runs:
      `max_abs=0`, RMS `0.000000`, `mismatches=0`,
      `metadata_equal=true`, and `file_set_equal=true`.
    - Dynamic production heuristic: wall `65653063 us`,
      `ir_inner_workers=6`, `ir_clean_us=286266156`,
      `ir_defect_mask_us=279106694`, `ir_adaptive_dust_us=205512992`,
      Gaussian substages `64624540`, `51519509`, `49557454`, and
      `37804170`.
    - Forced single inner worker: wall `113133809 us`, speedup vs dynamic
      `0.580x`, `ir_adaptive_dust_us=411079599`, Gaussian substages
      `104035068`, `102390746`, `102920935`, and `99749123`.
    - Forced three inner workers: wall `71395103 us`, speedup vs dynamic
      `0.919x`, `ir_adaptive_dust_us=217415105`, Gaussian substages
      `63956937`, `51821693`, `56418289`, and `43291721`.
    - Decision: retain the current dynamic six-inner-worker choice for this
      workload. Lower worker counts preserve exact output but lose wall-clock
      time, so no production heuristic change is justified from this pass.

- [x] Evaluate SIMD vectorization for f64 adaptive Gaussian row interiors.
  - Scope:
    - Keep the accepted f64 adaptive-dust algorithm: same normalized IR input,
      Gaussian kernels, reflect-101 boundaries, symmetric pair accumulation,
      pass order, thresholds, final mask, and `n_sigma2` output.
    - Add fixed-width SIMD only for contiguous row-interior work where each
      lane preserves the scalar per-pixel accumulation order. Keep scalar
      paths for boundaries, tails, small images, and unsupported shapes.
    - Reject the change if Zig tests or real-scan benchmark evidence show
      behavior drift or wall-clock regression.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - ReleaseFast `export_detected_frames_ir_all_breakdown` on
      `scans/scan_0004_rgbir_3200dpi.tiff`, compared against the current
      dynamic-worker baseline: wall time, `ir_adaptive_dust_us`, the four
      Gaussian substages, `ir_defect_mask_us`, and `ir_clean_us`.
    - Record the accepted/rejected result in `docs/PERFORMANCE_STRATEGY.md`,
      `docs/PARITY_MANIFEST.md` if symbols/evidence changed, and this plan.
  - Completed 2026-05-20:
    - Added a fixed-width f64 SIMD path for contiguous Gaussian row-interior
      work. Boundary columns/rows, row tails, small images, and scheduling
      fallback paths remain scalar.
    - The vector path keeps the same center plus symmetric-pair accumulation
      structure per lane and reuses the existing reflect-101 scalar handling at
      boundaries.
    - `zig build test --summary all` passed `438/438`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall `61361504 us`, `ir_clean_us=275649326`,
      `ir_defect_mask_us=268555723`, and `ir_adaptive_dust_us=194511415`.
    - Compared with the accepted dynamic-worker baseline from the prior item,
      wall improved from `65653063 us` to `61361504 us` (`1.070x`), and
      adaptive dust improved from `205512992 us` to `194511415 us` (`1.057x`).
    - Gaussian substages after SIMD were `ir_adaptive_background1_us=56498296`,
      `ir_adaptive_blurred_square1_us=56819666`,
      `ir_adaptive_background2_us=45540430`, and
      `ir_adaptive_blurred_square2_us=33386281`.
    - Decision: accept the SIMD row-interior path. It is a small but real
      same-behavior win and keeps scalar fallbacks for non-vector tails.

- [x] Re-rank RGB+IR export hotspots after f64 Gaussian SIMD and select the
      next secondary optimization.
  - Scope:
    - Use the latest `export_detected_frames_ir_all_breakdown` result as the
      source of truth.
    - Candidate secondary buckets now include residual adaptive Gaussian,
      morphology close/dilate, Meijering line detection, inpainting substeps,
      write time, and crop/IR prep overhead.
    - If a concrete optimization target is chosen, add it as the next
      unchecked checkpoint with scope, tests, benchmark evidence, and parity
      constraints before implementing.
  - Required evidence before checking off:
    - No code changes required unless the re-rank adds benchmark plumbing.
    - Record the ranked buckets and selected next checkpoint in this plan and
      `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-20:
    - Used the accepted f64 Gaussian SIMD benchmark as the source of truth:
      `export_detected_frames_ir_all_breakdown` on `scan_0004` reported wall
      `61361504 us`, `ir_clean_us=275649326`, and
      `ir_defect_mask_us=268555723`.
    - Ranked remaining aggregate worker buckets:
      adaptive dust `194511415`, morphology close+dilate
      `36813481 + 18857556 = 55671037`, line detection `18165612`
      including Meijering `17636531`, inpainting `6501227`, crop/IR negative
      prep about `2123461`, inversion `1236476`, display render `1131678`,
      and write `997421`.
    - Decision: residual adaptive Gaussian is still the largest bucket, but
      exact same-behavior local Gaussian changes are now showing smaller wins.
      The next secondary optimization should target morphology close/dilate,
      because it is the next largest non-Gaussian bucket and has no final-output
      tolerance question if the ellipse geometry is preserved.

- [x] Evaluate SIMD or bitset acceleration for IR morphology close/dilate.
  - Scope:
    - Preserve the existing ellipse row-span geometry, mask values, border
      clipping, close-before-dilate order, component filtering inputs, and final
      defect mask semantics.
    - Start from `dilateMask`, `erodeMask`, and `ellipseKernelRowSpans` in
      `src/processing/ir.zig`.
    - Explore same-behavior acceleration only: SIMD byte scans, row-span early
      exits, bitset row operations, or cache-local tiling are acceptable if
      they produce identical masks on focused tests.
    - Reject approximations or kernel-shape changes unless the user explicitly
      approves a toleranced morphology variant.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - Focused morphology tests proving exact output against the existing scalar
      row-span behavior for edge clipping, full interior spans, and sparse
      masks.
    - ReleaseFast `export_detected_frames_ir_all_breakdown` on
      `scans/scan_0004_rgbir_3200dpi.tiff`, reporting wall time,
      `ir_close_us`, `ir_dilate_us`, `ir_defect_mask_us`, and
      `ir_clean_us` before/after.
    - Record accepted/rejected evidence in `docs/PERFORMANCE_STRATEGY.md`,
      `docs/PARITY_MANIFEST.md` if symbols/evidence changed, and this plan.
  - Completed 2026-05-20:
    - Replaced per-output-pixel ellipse-span rescans with exact sliding
      horizontal windows per valid ellipse span and source row.
    - Preserved the existing ellipse row-span geometry, border clipping,
      close-before-dilate order, binary 0/255 mask semantics, and scalar
      reference behavior.
    - Kept scalar reference `dilateMaskReference` and `erodeMaskReference` for
      tests, and added a focused test comparing optimized dilation/erosion
      against the reference for radii `0`, `1`, `2`, `4`, and `6` on an
      edge-heavy sparse mask.
    - `zig build test --summary all` passed `439/439`.
    - `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall `56971107 us`, `ir_clean_us=252425331`,
      `ir_defect_mask_us=245276844`, `ir_close_us=22107579`, and
      `ir_dilate_us=7205414`.
    - Compared with the post-SIMD baseline, wall improved from `61361504 us`
      to `56971107 us` (`1.077x`), close+dilate improved from
      `36813481 + 18857556 = 55671037` to
      `22107579 + 7205414 = 29312993` (`1.899x`), and
      `ir_defect_mask_us` improved from `268555723` to `245276844`
      (`1.095x`).
    - Decision: accept the exact sliding-window morphology path.

- [x] Re-rank RGB+IR export hotspots after sliding-window morphology.
  - Scope:
    - Use the latest `export_detected_frames_ir_all_breakdown` result as the
      source of truth.
    - Candidate buckets now include residual adaptive Gaussian, line detection
      and Meijering, inpainting, remaining morphology, write time, and crop/IR
      prep overhead.
    - If a concrete optimization target is chosen, add it as the next
      unchecked checkpoint with scope, tests, benchmark evidence, and parity
      constraints before implementing.
  - Required evidence before checking off:
    - No code changes required unless the re-rank adds benchmark plumbing.
    - Record the ranked buckets and selected next checkpoint in this plan and
      `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-20:
    - Used the accepted sliding-window morphology benchmark as the source of
      truth: wall `56971107 us`, `ir_clean_us=252425331`, and
      `ir_defect_mask_us=245276844`.
    - Ranked remaining aggregate worker buckets:
      adaptive dust `198356313`, morphology close+dilate
      `22107579 + 7205414 = 29312993`, line detection `17409612`
      including Meijering `16883452`, inpainting `6577417`, crop/IR negative
      prep about `2010986`, inversion `1244581`, display render `1137729`,
      and write `1040920`.
    - Decision: residual adaptive Gaussian remains the dominant bucket, but the
      next unexamined f64-heavy secondary path is Meijering line response. Add
      a focused precision/SIMD tradeoff checkpoint before considering more
      invasive bitset morphology or approximate adaptive Gaussian changes.

- [x] Evaluate Meijering line-response f32/SIMD tradeoffs.
  - Scope:
    - Preserve the Python-shaped line-defect pipeline: resized `n_sigma`, dark
      line response, sigma range, thresholding, line-mask merge, and downstream
      morphology inputs.
    - Start from `detectLineDefectsTimed`, `meijeringLineResponse`,
      `hessianGaussian`, `gaussianFilterOrder`, and `gaussianFilterAxis` in
      `src/processing/ir.zig`.
    - Add benchmark plumbing if needed to compare f64 reference against f32
      and/or SIMD variants on real detected scan data.
    - Do not promote a variant unless final line mask and full export
      differences are measured at the relevant mask/TIFF surfaces and are
      either exact or explicitly acceptable.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - A focused mask comparison reporting line-mask `max_abs`, RMS/MSE,
      mismatches, and defect-count delta for f64 reference versus candidate.
    - ReleaseFast `export_detected_frames_ir_all_breakdown` on
      `scans/scan_0004_rgbir_3200dpi.tiff`, reporting wall time,
      `ir_line_detection_us`, `ir_meijering_us`, `ir_defect_mask_us`, and
      `ir_clean_us`.
    - If promoted into production, final export comparison with `max_abs`,
      RMS/MSE, mismatch count/rate, metadata equality, and file-set equality.
    - Record accepted/rejected evidence in `docs/PERFORMANCE_STRATEGY.md`,
      `docs/PARITY_MANIFEST.md` if symbols/evidence changed, and this plan.
  - Completed 2026-05-20:
    - Chose the exact f64 SIMD route before trying f32. The SciPy-shaped
      Gaussian filter axis now vectorizes contiguous columns while keeping
      scalar edge/tail handling and the same reflect-index boundary behavior.
    - Added scalar reference paths for the Gaussian filter axis, Hessian
      Gaussian, Meijering response, line-defect detection, and full defect-mask
      construction so benchmarks/tests can compare production SIMD against the
      accepted scalar operation.
    - Added tests proving SIMD Gaussian filter axes match scalar reference
      output for x/y axes, order `0`/`1`, and both truncate regimes, plus a
      line-mask test proving production Meijering matches scalar reference.
    - `zig build test --summary all` passed `441/441`.
    - Focused real-scan benchmark:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case ir_meijering_simd_tradeoff`
      reported exact mask equality against the scalar reference on a
      `3063x4600` crop: `max_abs=0`, RMS `0.000000`, MSE `0.000000`,
      `mismatches=0`, defect delta `0`, and `reference_defects=170799` /
      `simd_defects=170799`.
    - The same focused benchmark reported total mask time
      `19550794 -> 17352766 us` (`1.126x`), line detection
      `3152980 -> 1024918 us` (`3.076x`), and Meijering
      `3046428 -> 916660 us` (`3.323x`).
    - Full RGB+IR export benchmark:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall `55067434 us`, `ir_clean_us=247882926`,
      `ir_defect_mask_us=240639668`, `ir_line_detection_us=6991369`, and
      `ir_meijering_us=6406495`.
    - Compared with the sliding-window morphology baseline, wall improved from
      `56971107 us` to `55067434 us` (`1.034x`), line detection improved from
      `17409612` to `6991369` (`2.490x`), and Meijering improved from
      `16883452` to `6406495` (`2.636x`).
    - Decision: accept exact f64 SIMD for the line-response Gaussian filter
      axes. Do not pursue f32 Meijering unless later profiling shows this path
      is again material.

- [x] Re-rank RGB+IR export hotspots after Meijering SIMD.
  - Scope:
    - Use the latest `export_detected_frames_ir_all_breakdown` result as the
      source of truth.
    - Candidate buckets now include residual adaptive Gaussian, remaining
      morphology, inpainting, write time, crop/IR prep overhead, and any
      remaining line-detection overhead.
    - If a concrete optimization target is chosen, add it as the next
      unchecked checkpoint with scope, tests, benchmark evidence, and parity
      constraints before implementing.
  - Required evidence before checking off:
    - No code changes required unless the re-rank adds benchmark plumbing.
    - Record the ranked buckets and selected next checkpoint in this plan and
      `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-20:
    - Latest source-of-truth benchmark:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall `55067434 us`, aggregate `ir_clean_us=247882926`,
      `ir_defect_mask_us=240639668`, `ir_adaptive_dust_us=203868883`,
      `ir_close_us=22369387`, `ir_dilate_us=7170575`,
      `ir_line_detection_us=6991369`, `ir_meijering_us=6406495`,
      `ir_inpaint_total_us=6655521`, `rgb_crop_us=898340`,
      `ir_crop_us=434626`, `ir_neg_prepare_us=685559`,
      `inversion_us=1245229`, `display_render_us=1133825`, and
      `write_us=1001051`.
    - Ranked remaining buckets:
      1. Adaptive dust Gaussian/statistics construction: `203868883 us`.
      2. Morphology close+dilate: `22369387 + 7170575 = 29539962 us`.
      3. Line detection: `6991369 us`, including Meijering `6406495 us`.
      4. Inpainting: `6655521 us`.
      5. Crop/IR negative prep: about `2018525 us`.
      6. Inversion: `1245229 us`.
      7. Display render: `1133825 us`.
      8. TIFF write: `1001051 us`.
    - Decision: line detection is no longer the next large target. Adaptive
      dust is now about `6.90x` larger than close+dilate and about `29.16x`
      larger than line detection, so the next checkpoint should return to the
      adaptive-dust path.
    - Selected next checkpoint: make the existing f32 adaptive-dust candidate a
      fair performance comparison by giving its Gaussian path the same class of
      parallel/SIMD treatment already accepted for f64, then judge promotion
      only from full mask and final-export speed/accuracy evidence. The Python
      oracle already uses `float32` for this path, and tiny final-surface
      differences below practical output significance are acceptable for a
      large speedup, but large local inpaint/output differences must be
      reported rather than hidden.

- [x] Optimize f32 adaptive-dust Gaussian candidate.
  - Scope:
    - Work only on the existing adaptive dust path in `src/processing/ir.zig`.
      Preserve the two-pass Python-shaped computation: normalize IR, Gaussian
      background, Gaussian squared signal, coarse replacement, second
      Gaussian background, second Gaussian squared signal, final `n_sigma2`
      and ratio test.
    - Keep f64 production available as the reference until the full-export
      tradeoff is measured. The candidate may use f32 intermediates because
      the Python oracle does, but it must not alter threshold formulas, mask
      combination, morphology, line detection, or inpainting.
    - Give `gaussianBlurF32` the same practical optimization class as f64:
      odd-kernel pair-weight loops, reflect-101 scalar boundaries, contiguous
      SIMD interiors, and the adaptive worker count supplied through
      `ThresholdOptions.worker_count`.
    - Keep scalar/tail fallbacks so the implementation is correct on arbitrary
      dimensions and platforms where vector width is only a compile-time Zig
      vectorization hint.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - Focused `ir_adaptive_dust_f32_tradeoff` on
      `scans/scan_0004_rgbir_3200dpi.tiff`, reporting shared mask-area
      metrics as the acceptance surface: intersection area, union area, IoU,
      reference area retained, candidate area confirmed, and Dice. Direct
      pixel mismatch counters may remain as diagnostics but are not the
      primary detector-quality metric.
    - Full `export_detected_frames_ir_f32_tradeoff` on the same scan,
      reporting f64 reference wall, f32 wall, speedup, final TIFF `max_abs`,
      RMS/MSE, mismatch count/rate, metadata equality, file-set equality, and
      relevant IR substage times.
    - If promoted to production defaults, refresh
      `export_detected_frames_ir_all_breakdown` and record the new default
      wall time and bucket ranking.
    - Record accepted/rejected evidence in `docs/PERFORMANCE_STRATEGY.md`,
      `docs/PARITY_MANIFEST.md` if symbols/evidence changed, and this plan.
  - Completed 2026-05-20:
    - Updated `gaussianBlurF32` to use the same optimization class as the f64
      path: odd-kernel pair weights, reflect-101 scalar boundary handling,
      contiguous SIMD interiors, scalar tails, and row-parallel horizontal and
      vertical passes selected by `ThresholdOptions.worker_count`.
    - Added mask-area overlap reporting to `ir_adaptive_dust_f32_tradeoff` so
      detector acceptability is judged by shared region area rather than by
      final TIFF sample deltas or a raw binary-pixel mismatch count.
    - Promoted f32 adaptive dust to the production default while keeping the
      f64 path available as the benchmark/reference override. This matches the
      Python oracle's `float32` adaptive-dust calculation more closely than the
      previous f64 default.
    - `zig build test --summary all` passed `442/442`.
    - Focused mask benchmark:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case ir_adaptive_dust_f32_tradeoff`
      on a detected `3063x4600` crop reported `reference_us=41730250`,
      `f32_us=26637777` (`1.566x`), `ref_adaptive_us=34786235`,
      `f32_adaptive_us=19682661`, `reference_defects=170799`,
      `f32_defects=185465`, intersection area `170433`, union area `185831`,
      IoU `91.713%`, reference area retained `99.785%`, f32 area confirmed
      `91.894%`, and Dice `95.677%`.
    - Full f64-vs-f32 export tradeoff:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_f32_tradeoff`
      reported f64 reference wall `53259036 us`, f32 wall `30311036 us`
      (`1.757x`), `reference_ir_adaptive_dust_us=187612329`,
      `f32_ir_adaptive_dust_us=81431700`, metadata equality `true`, file-set
      equality `true`, final TIFF RMS `110.633142` on a 16-bit scale, and
      `abs_gt_4096=85657` of roughly `632.7M` final samples. The final-image
      differences are expected because small mask-area changes toggle
      inpainting in local regions; the mask-area overlap metrics are the
      primary acceptance evidence for this detector change.
    - Production-default refresh:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall `30366888 us`, `ir_clean_us=127446236`,
      `ir_defect_mask_us=119817222`, `ir_adaptive_dust_us=83048463`,
      `ir_close_us=22715193`, `ir_dilate_us=7640539`,
      `ir_line_detection_us=6192776`, `ir_meijering_us=5649074`,
      `ir_inpaint_total_us=6992917`, `inversion_us=1263675`,
      `display_render_us=1137713`, and `write_us=1067462`.
    - Decision: accept the f32 default. Compared with the pre-checkpoint f64
      default wall `55067434 us`, production RGB+IR export now improves to
      `30366888 us` (`1.814x`) while preserving nearly all reference defect
      area and keeping f64 available for direct comparisons.

- [x] Re-rank RGB+IR export hotspots after f32 adaptive-dust promotion.
  - Scope:
    - Use the latest f32-default `export_detected_frames_ir_all_breakdown`
      result as the source of truth.
    - Candidate buckets now include residual adaptive Gaussian work,
      morphology close+dilate, inpainting, line detection, crop/IR prep,
      inversion, display render, and write time.
    - If the next target changes the detector numerics, require mask-area
      overlap metrics as the primary acceptance surface instead of direct
      final-image pixel mismatch counts.
  - Required evidence before checking off:
    - No code changes required unless benchmark plumbing is missing.
    - Record ranked buckets and selected next checkpoint in this plan and
      `docs/PERFORMANCE_STRATEGY.md`.
  - Completed 2026-05-20:
    - Latest source-of-truth benchmark:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_all_breakdown`
      reported wall `30366888 us`, `ir_clean_us=127446236`,
      `ir_defect_mask_us=119817222`, `ir_adaptive_dust_us=83048463`,
      `ir_close_us=22715193`, `ir_dilate_us=7640539`,
      `ir_line_detection_us=6192776`, `ir_meijering_us=5649074`,
      `ir_inpaint_total_us=6992917`, `rgb_crop_us=927089`,
      `ir_crop_us=454459`, `ir_neg_prepare_us=720144`,
      `inversion_us=1263675`, `display_render_us=1137713`, and
      `write_us=1067462`.
    - Ranked remaining buckets:
      1. Adaptive dust Gaussian/statistics construction: `83048463 us`.
      2. Morphology close+dilate: `22715193 + 7640539 = 30355732 us`.
      3. Inpainting: `6992917 us`.
      4. Line detection: `6192776 us`, including Meijering `5649074 us`.
      5. Crop/IR negative prep: about `2101692 us`.
      6. Inversion: `1263675 us`.
      7. Display render: `1137713 us`.
      8. TIFF write: `1067462 us`.
    - Decision: adaptive dust remains the largest bucket, but it is now only
      about `2.74x` larger than close+dilate after the f32 promotion. The next
      checkpoint should examine remaining adaptive Gaussian pass count and
      approximation opportunities, with mask-area overlap as the acceptance
      gate for detector changes.

- [x] Evaluate adaptive-dust Gaussian pass-count and approximation candidates.
  - Scope:
    - Stay within the Python-shaped adaptive dust detector unless a candidate is
      explicitly recorded as a toleranced approximation. Do not change line
      detection, morphology, inpainting, or downstream export semantics in this
      checkpoint.
    - First identify whether any of the four f32 Gaussian passes can be avoided,
      fused, or reused without changing results. Exact wins remain preferred.
    - If exact fusion is exhausted, evaluate approximation candidates only
      behind benchmark-controlled paths: lower effective blur work, repeated
      box/binomial approximations, reduced-resolution background estimation, or
      other separable approximations that preserve the same threshold formulas.
    - For any approximate candidate, use mask-area overlap as the primary
      detector-quality surface: IoU, reference area retained, candidate area
      confirmed, Dice, and defect-area delta. Final TIFF pixel deltas are
      secondary diagnostics because mask changes can trigger local inpainting
      differences.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - Focused real-scan benchmark on
      `scans/scan_0004_rgbir_3200dpi.tiff` reporting adaptive-dust time,
      detector-area overlap metrics, and close/dilate/line timings.
    - If a candidate is promoted, full
      `export_detected_frames_ir_all_breakdown` wall time and bucket ranking.
    - Record accepted/rejected candidates in `docs/PERFORMANCE_STRATEGY.md`,
      `docs/PARITY_MANIFEST.md` if symbols/evidence changed, and this plan.
  - Completed 2026-05-20:
    - Exact pass-count review: the four Gaussian passes are not independently
      droppable without changing the Python-shaped detector. The first
      background and squared-signal passes define the coarse mask; the second
      background and squared-signal passes operate on the coarse-cleaned IR and
      define the final `n_sigma2` used by dust and line gating. Reusing a first
      pass for a second pass or omitting either squared-signal pass changes the
      local variance formula. Earlier exact paired-output Gaussian work also
      preserved output but regressed this workload, so no exact pass-count
      promotion is available from the current structure.
    - Added benchmark-only `ir_adaptive_dust_blur_tradeoff` to evaluate lower
      effective Gaussian blur sizes while preserving the same two-pass
      threshold formulas, line detection, morphology, inpainting handoff, and
      production defaults.
    - `zig build test --summary all` passed `442/442`.
    - Focused benchmark:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case ir_adaptive_dust_blur_tradeoff`
      compared the current f32 detector blur size `1205` against reduced
      candidates on the first detected `3063x4600` crop.
    - Candidate `603` (`divisor=2`) reduced candidate adaptive time to
      `1918499 us` versus reference `5119769 us`, but detector overlap was too
      weak: IoU `74.949%`, reference area retained `89.199%`, candidate area
      confirmed `82.430%`, Dice `85.681%`, and defect delta `15230`.
    - Candidate `401` (`divisor=3`) reduced adaptive time to `1030390 us` but
      fell to IoU `59.524%`, reference retained `84.104%`, candidate confirmed
      `67.070%`, Dice `74.627%`, and defect delta `47102`.
    - Candidate `301` (`divisor=4`) reduced adaptive time to `717764 us` but
      fell to IoU `56.496%`, reference retained `73.107%`, candidate confirmed
      `71.317%`, Dice `72.201%`, and defect delta `4653`.
    - Candidate `201` (`divisor=6`) and `151` (`divisor=8`) were clearly
      unacceptable with IoU `37.506%` and `18.142%` respectively.
    - Decision: reject lower blur-size approximations for production. They are
      faster, but even the mildest candidate changes the detector area too much
      under the agreed mask-area acceptance surface. Keep the current f32
      default blur size and leave more invasive approximations for an explicit
      future experiment.

- [x] Evaluate same-scale approximate Gaussian implementations for adaptive dust.
  - Scope:
    - This is an explicitly approved approximate-detector experiment. Keep the
      current f32 Gaussian adaptive-dust path as the production default and as
      the focused reference for this checkpoint.
    - Preserve the Python-shaped detector structure: normalized IR, first
      background and squared-signal blur, coarse replacement, second background
      and squared-signal blur, final `n_sigma2`, then the existing line,
      morphology, coverage, and inpainting handoff.
    - Do not reduce the configured blur size in this checkpoint. Approximate
      the same Gaussian scale with faster separable methods such as repeated
      box filters or other bounded-error Gaussian approximations.
    - Candidate modes must be explicit non-default precision/backend options
      so benchmark code can select them without changing UI, CLI, export, or
      config defaults.
    - Use mask-area overlap as the primary quality surface: IoU, reference
      area retained, candidate area confirmed, Dice, and defect-area delta.
      Report focused adaptive-dust time and downstream line/close/dilate
      timings so quality and performance are evaluated together.
  - Required evidence before checking off:
    - `zig build test --summary all`.
    - Focused real-scan benchmark on
      `scans/scan_0004_rgbir_3200dpi.tiff` comparing the default f32 Gaussian
      path against approximate candidates on a detected full-resolution IR
      crop.
    - If a candidate is accepted for production, run a full
      `export_detected_frames_ir_all_breakdown` refresh and record wall time,
      aggregate bucket changes, and any final-output parity diagnostics.
    - Record the accepted or rejected candidates in
      `docs/PERFORMANCE_STRATEGY.md`, `docs/PARITY_MANIFEST.md`, and this
      plan item before checking it off.
  - Completed 2026-05-20:
    - Added explicit non-default adaptive-dust candidate modes for repeated box
      cascades (`f32_box3`, `f32_box4`, `f32_box6`, `f32_box8`), downsampled
      exact Gaussian approximations (`f32_down2`, `f32_down3`, `f32_down4`,
      `f32_down6`, `f32_down8`), and mixed plans that approximate only the
      first/coarse pair or final pair (`f32_down4_coarse`, `f32_down4_final`).
      The production/default `.f32` path remains the exact Gaussian path.
    - Added benchmark-only
      `ir_adaptive_dust_gaussian_approx_tradeoff` and
      `export_detected_frames_ir_gaussian_approx_tradeoff` cases. Added unit
      coverage for constant-image preservation and parallel consistency of the
      approximation helpers.
    - `zig build test --summary all` passed `445/445`.
    - Focused benchmark:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case ir_adaptive_dust_gaussian_approx_tradeoff`
      compared candidates on the first detected `3063x4600` IR crop.
    - Rejected box cascades as a family for this detector: box counts 3, 4, 6,
      and 8 all produced `candidate_defects=0`, `mask_iou_x1000=0`, and
      `mask_ref_area_retained_x1000=0`, despite reducing adaptive time to about
      `0.50-0.83s` versus the exact f32 reference around `4.96-5.17s`.
    - Rejected applying downsampled Gaussian approximation to all four
      adaptive blurs: the best full-plan candidate was `down4` with IoU
      `92.158%`, reference retained `93.481%`, candidate confirmed `98.486%`,
      Dice `95.919%`, and adaptive time around `0.69s`; it misses too much
      reference mask area for a default detector.
    - Diagnostic mixed plans showed the quality loss comes primarily from
      approximating the final local-statistics pair. `down4_final` stayed near
      the full-plan result with IoU `91.835%` and reference retained `93.505%`.
      `down4_coarse` was much closer to the exact f32 mask: IoU `99.281%`,
      reference retained `99.968%`, candidate confirmed `99.312%`, Dice
      `99.639%`, defect delta `1224`, and mismatches `1342` of `14089800`
      mask pixels while reducing focused adaptive time from `4964063 us` to
      `2852742 us`.
    - Full-export benchmark:
      `zig build -Doptimize=ReleaseFast bench-processing-commands --summary all -- --scan scans/scan_0004_rgbir_3200dpi.tiff --case export_detected_frames_ir_gaussian_approx_tradeoff`
      compared the production f32 path with `down4_coarse` across 5 detected
      frames and 15 output files. Wall time improved from `28556578 us` to
      `22316350 us` (`1.279x`); aggregate `ir_clean_us` improved
      `116515098 -> 87628300`, `ir_defect_mask_us` improved
      `108889709 -> 79947181`, and `ir_adaptive_dust_us` improved
      `74083018 -> 45182508`. Metadata and file sets matched. Final TIFF
      comparison reported RMS `83.164927`, MSE `6916.405047`, mismatches
      `17265757`, mismatch rate `2.729%`, and `abs_gt_4096=46144`.
    - Decision: keep all approximate Gaussian paths non-default for now.
      `down4_coarse` is a strong candidate for an explicitly approved fast
      detector mode or future default, but production should not switch in this
      checkpoint without reviewing the final-output tolerance tradeoff. The
      current default `.f32` exact Gaussian adaptive path remains active.

- [x] Refresh Linux live scanner release smoke evidence.
  - Covers release checklist item 9.
  - Required modes/evidence: RGB, IR, RGB+IR, metadata, LUT, native preview
    worker, native scan worker, and scanner-to-processing workflow.
  - Use only gated commands with `V600_HARDWARE_SMOKE=1`; never add scanner
    access to default builds or checks.
  - Required evidence before checking off: exact commands, device identity,
    output paths, TIFF page/depth/geometry summaries, relevant metadata sidecar
    fields, and any event/progress output needed to prove the worker and
    workflow paths.
  - Blocked 2026-05-18: direct gated command
    `env V600_HARDWARE_SMOKE=1 zig build run -- scanner smoke --out /tmp/v600-release-rgb.tiff --source tpu --dpi 400 --kind rgb --depth 16 --x 0.1 --y 0.1 --width 0.25 --height 0.25`
    selected cached device `epkowa:interpreter:001:018` and emitted
    `scan-start`, then refreshed discovery and failed with `NoV600Device`.
    Follow-up `zig build run -- scanner devices` reported
    `devices_found=0`, and `zig build run -- scanner probe` failed with
    `NoV600Device`. No release hardware output TIFF was produced.
  - Required next input: make the scanner visible to SANE again, then rerun the
    RGB, IR, RGB+IR, metadata, LUT, native preview-worker, native scan-worker,
    and scanner-to-processing smoke commands.
  - Completed 2026-05-23 after the rebuilt scanner wrapper was active:
    - See the completed scanner-performance checklist above for the exact live
      gated commands and timings.
    - Required coverage is present for RGB, IR, RGB+IR, metadata, LUT, native
      preview-worker, native scan-worker, and scanner-to-processing workflow.
    - `docs/PARITY_MANIFEST.md` and `docs/PERFORMANCE_STRATEGY.md` record the
      release smoke outputs, sidecar fields, timing report paths, and the
      follow-up capability-cache optimization result.

- [x] Refresh Linux Nix package and no-hardware check gates.
  - Covers release checklist items 7 and 8.
  - Required commands:
    - `nix build path:.#cli path:.#ui --no-link --print-build-logs`
    - `nix build path:.#checks.x86_64-linux.zig-tests --no-link --print-build-logs`
  - Blocked 2026-05-18: the user explicitly directed agents to avoid redundant
    Nix evaluations and to rely on the ambient shell for ordinary work. Do not
    run these release gates until the user explicitly authorizes release-time
    Nix validation or asks for a packaging refresh.
  - Completed 2026-05-23 after explicit user authorization to run the release
    Nix gates:
    - `nix build path:.#cli path:.#ui --no-link --print-build-logs` completed
      with exit code 0. Nix built:
      - `/nix/store/0bfn1dywh9hbxpfh3z7lblqzds7mdvma-v600-zig-cli-0.1.0`
      - `/nix/store/l6k8xi1vz3wd196my7jb3m1cls93dl9i-v600-zig-ui-0.1.0`
      The CLI build phase completed in `48 seconds`; the UI build phase
      completed in `54 seconds`.
    - `nix build path:.#checks.x86_64-linux.zig-tests --no-link
      --print-build-logs` completed with exit code 0. The check derivation
      built `/nix/store/p5r5crfc3z8yh6hm8nqi1b4q07a1ij5x-v600-zig-tests.drv`
      and printed the expected no-hardware skips for macOS scanner smoke,
      scanner processing smoke, Linux scanner smoke, native scan worker smoke,
      and native preview worker smoke.

- [x] Officially pause macOS direct build/test evidence until the user reopens
      the work on macOS hardware.
  - Covers release checklist item 10 under the current Linux-scoped release
    claim.
  - Blocked 2026-05-18: current machine is Linux. This remained parked under
    the `PENDING USER UPDATE` macOS policy until a macOS host was available.
  - Paused 2026-05-23 by explicit user direction: macOS build/test/scanner work
    is officially paused until the user reminds the project of that work and
    reopens it on macOS hardware. Do not select macOS-only SDK, build, bundle,
    USB, or scanner validation work in the autonomous loop until then.
  - Completion decision: checked only as a release-scope deferral. This is not
    macOS build/test evidence and must not be presented as macOS support.

- [x] Keep macOS live scanner support explicitly deferred from the release claim.
  - Covers release checklist item 11 for the current Linux-hosted audit.
  - Evidence: `docs/CROSS_PLATFORM.md` records macOS scanner support as planned
    through Epson Interpreter, replay-tested only, with live build/scanner
    validation pending. The parked `PENDING USER UPDATE: Add live macOS scanner
    smoke tests` item in this plan requires a macOS scanner host and Epson
    Interpreter bundle before live scanner support can be claimed.
  - Completion decision: checked only as an explicit deferral, not as live
    macOS scanner support.

- [x] Record native UI real-display screenshot verification.
  - Covers release checklist item 12.
  - Required workflows: scan, process, gallery, confirmation, and pan/zoom.
  - Use `docs/NATIVE_UI_VERIFICATION.md` as the checklist. Headless SDL dummy
    smokes are useful but not sufficient for this release item.
  - Required evidence before checking off: date, display environment, command,
    screenshot paths, viewport/window sizes, and visual defects or explicit
    "no defect observed" notes.
  - Partial progress 2026-05-19:
    - The shell itself is still a TTY (`DISPLAY=`, `WAYLAND_DISPLAY=`,
      `XDG_SESSION_TYPE=tty`), but the machine has an accessible LightDM/Xorg
      session at `DISPLAY=:0` with `XAUTHORITY=$HOME/.Xauthority`.
      `xdotool getdisplaygeometry` reported `3840x4720`; screenshots were
      captured with `scrot 1.11.1`.
    - Added real-display verification helpers that preserve the existing smoke
      behavior when unused:
      - `--smoke-hold-ms` keeps seeded UI smoke windows open long enough for
        real screenshots.
      - `--gallery-trash-prompt-smoke` and
        `--gallery-delete-prompt-smoke` seed Gallery confirmation prompts
        without mutating files.
      - `--process-worker-screenshot-smoke` keeps a fake Process load worker
        active long enough to capture footer progress.
      - The Process worker fake preview now supplies a valid RGB buffer for
        its advertised dimensions, avoiding an SDL texture update crash when a
        held smoke window renders the completed fake preview.
      - `--smoke-resize-to` and `--window-size` were added for deterministic
        viewport attempts, but the current X session still kept the window at
        `1918x2158`.
    - Real-display screenshot paths under
      `.zig-cache/tmp/native-ui-real-display-2026-05-19/`:
      - `scan-scale-1-default.png`, `scan-scale-1-45.png`, `scan-narrow.png`,
        `scan-wide.png`;
      - `process-default.png`, `process-short.png`,
        `process-worker-active.png`;
      - `gallery-default.png`, `gallery-trash-prompt.png`,
        `gallery-delete-prompt.png`, `gallery-panzoom.png`;
      - `contact-sheet.png`;
      - matching `*.geometry.txt` sidecars were captured for each named
        screenshot.
    - Visual findings from the captured set:
      - Scan, Process, and Gallery tabs render on the real X display with
        readable navigation, control panels, image areas, and pinned footer
        status bars.
      - Gallery thumbnails show real fixture TIFF content, active thumbnail
        state is distinguishable, and both Trash and Delete confirmation
        prompts are visible with Confirm/Cancel controls.
      - The Process active-worker screenshot shows footer text for the running
        load worker. The Process render screenshot shows the expected seeded
        fixture and an auto-detect failure status from the tiny test image.
      - No obvious text overlap, footer overlap, blank texture, or broken
        prompt layout was observed in the captured default-size images.
    - Required validation passed after the helper changes:
      - `zig build test --summary all` passed `412/412`.
      - `zig build -Dui=true --summary all` passed.
      - `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build
        -Dui=true ui-smoke --summary all` passed.
      - Direct dummy-SDL `run-ui` smokes passed for
        `--preview-render-smoke --smoke-hold-ms 10`,
        `--process-worker-screenshot-smoke --smoke-hold-ms 10`,
        `--gallery-trash-prompt-smoke --smoke-hold-ms 10`, and
        `--gallery-delete-prompt-smoke --smoke-hold-ms 10`.
    - Still not complete:
      - The required narrower/wider resized-window evidence is not satisfied.
        `xdotool windowsize`, SDL `--smoke-resize-to`, and `--window-size`
        attempts all still captured `1918x2158` windows in this X session.
        A follow-up Xfce/X11 attempt also removed `MAXIMIZED_VERT`,
        `MAXIMIZED_HORZ`, and `FULLSCREEN` window state with `xdotool
        windowstate`, then requested `900x700`; geometry and screenshot output
        still reported `1918x2158`.
      - Manual pointer-feel checks for wheel ownership, middle-button pan,
        double-click refit, keyboard wrapping, and cancel/no-mutation behavior
        remain better performed from the live graphical session.
    - Required next input: use the graphical desktop directly to resize the
      window narrower/wider and complete the manual interaction checklist in
      `docs/NATIVE_UI_VERIFICATION.md`, or provide a display environment that
      permits window resizing from automation.
  - Completed 2026-05-23:
    - Display environment:
      - The ambient shell still reports only `XDG_SESSION_TYPE=tty`, but the
        local X session is reachable through
        `DISPLAY=:0 XAUTHORITY=$HOME/.Xauthority`.
      - `xrandr --current` reported a `3840x4720` X screen with `DP-0`
        connected at `3840x2560+0+2160`.
      - The window manager is xmonad. Requested `--window-size` values are
        intentionally tiled by xmonad; the user confirmed this is acceptable
        and not a UI defect. Geometry sidecars for all refreshed screenshots
        record `Position: 0,2160` and `Geometry: 3838x2522`.
    - Screenshot capture method:
      - Real windows were launched with direct Zig commands using
        `DISPLAY=:0 XAUTHORITY=$HOME/.Xauthority SDL_RENDER_DRIVER=software
        zig build -Dui=true run-ui -- ... --smoke-hold-ms ...`.
      - Window captures used the existing desktop screenshot tool:
        `scrot -w <window-id>`, with `xdotool getwindowgeometry` sidecars.
      - Gallery pan/zoom screenshot used `xdotool` to send two wheel-up events
        and a middle-button drag inside the real Gallery window before capture.
    - Screenshot paths under
      `.zig-cache/tmp/native-ui-real-display-2026-05-23/`:
      - Scan: `scan-default.png`, `scan-scale-1.png`, `scan-scale-145.png`,
        `scan-requested-narrow.png`, `scan-requested-wide.png`.
      - Process: `process-default.png`, `process-requested-short.png`,
        `process-worker-active.png`.
      - Gallery: `gallery-default.png`, `gallery-trash-prompt.png`,
        `gallery-delete-prompt.png`, `gallery-panzoom.png`.
      - Supporting outputs: matching `*.geometry.txt`, per-run `*.log`,
        `identify.txt`, and `contact-sheet.png`.
    - Image/geometry evidence:
      - `identify -format '%f %wx%h %[depth]-bit %[colorspace]\n'
        .zig-cache/tmp/native-ui-real-display-2026-05-23/*.png` confirmed the
        refreshed screenshots are 8-bit sRGB PNGs. All xmonad-tiled captures
        are `3838x2522`; an older first probe `scan-default-1280x900.png` is
        also present at `3838x2158` but is not needed for release evidence.
      - Scan screenshots show readable top navigation, preview controls,
        scale `1.0` and `1.45` sizing, preview image, selection box, and pinned
        Scan footer.
      - Process screenshots show the image selector, preview controls, render
        controls, color pad, dust controls, the seeded preview image, and a
        footer status line. `process-worker-active.png` shows the fake Process
        load worker status in the footer while work is active.
      - Gallery screenshots show two seeded TIFF exports, active thumbnail
        highlighting, Trash and Delete confirmation prompts with Confirm/Cancel
        controls, and Gallery footer text. The seeded TIFF fixture is very dark,
        so the large selected export area appears dark, but the thumbnails and
        file labels confirm real fixture-backed gallery content rather than a
        blank placeholder.
      - Visual inspection found no obvious text overlap, footer overlap, broken
        prompt layout, blank control panels, or unreadable scale-1.45 controls
        in the refreshed xmonad captures.
    - Supporting direct UI validation:
      - `zig build -Dui=true --summary all` passed.
      - `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build
        -Dui=true ui-smoke --summary all` passed.
      - Direct dummy-SDL interaction/render smokes passed:
        `run-ui -- --scan-interaction-smoke`,
        `run-ui -- --process-render-smoke`,
        `run-ui -- --gallery-interaction-smoke`,
        `run-ui -- --gallery-shortcut-smoke`, and
        `run-ui -- --gallery-confirm-smoke`.
      - These smokes cover wheel-routing, selection editing, Gallery
        zoom/pan/fit events, shortcut wrapping, Delete/Backspace confirmation
        requests, and no-mutation-before-confirm behavior at the event/state
        boundary. The real-display screenshots cover compositor/window
        readability and the xmonad-controlled tile geometry.

- [x] Final parity manifest and generated-output hygiene audit.
  - Covers release checklist items 1, 2, and 15 after all other Phase 12 work.
  - Required checks:
    - every selectable `plan.md` item is checked or has a user-approved release
      deferral/blocker;
    - every applicable `docs/PARITY_MANIFEST.md` row is `parity-accepted` or
      has an explicit release-approved deferred/blocker reason;
    - `git status --short` contains only intended source/docs/fixture changes,
      not generated scans, frames, configs, TIFF/PNG/JPEG outputs, or temporary
      smoke files.
  - Completion decision: checked only after the 2026-05-23 release-scope
    acceptance and final hygiene audit below.
  - Audit attempt 2026-05-20:
    - This item cannot honestly be checked off yet. Remaining unchecked rows
      are parked as `PENDING USER UPDATE`, but the release checklist still needs
      explicit human/environment input for Linux SANE visibility/live scanner
      smokes, release-time Nix package/check validation, a macOS host, and a
      graphical session that can complete the real-display UI resize/manual
      interaction evidence.
    - `rg -n "^- \[ \]" plan.md` now shows only the parked
      `PENDING USER UPDATE` blockers plus this final audit row, so there is no
      further unblocked implementation checkpoint to select in the current
      Linux shell.
    - The parity manifest is not in final release-accepted shape:
      `rg -n "\| (not-started|scaffolded|replay-tested|oracle-tested|hardware-tested|deferred|blocked)(/| |\|)" docs/PARITY_MANIFEST.md | wc -l`
      reported `181` rows/statuses that are not literally
      `parity-accepted` and therefore need either final acceptance updates or
      explicit release-approved deferral/blocker decisions before checklist
      item 2 in `docs/CROSS_PLATFORM.md` can pass.
    - Generated-output hygiene is currently acceptable but not a final release
      audit: `git status --short --untracked-files=all` showed only tracked
      source/docs modifications and no untracked scan/frame/config/TIFF/PNG/JPEG
      smoke outputs.
  - Audit refresh 2026-05-23:
    - The Linux SANE/live-scanner blocker from the 2026-05-20 audit is no
      longer current. The rebuilt wrapper live-smoke pass and scanner
      capability-cache optimization are checked above and committed.
    - Current unchecked rows from `rg -n "^- \[ \]|^\s+- \[ \]" plan.md` are
      only:
      - macOS direct build/test evidence, blocked until a macOS host is
        available;
      - this final parity/hygiene audit, blocked until the parked release
        inputs above are resolved or explicitly release-deferred.
    - The parity manifest is still not in final release-accepted shape:
      `rg -n "\| (not-started|scaffolded|replay-tested|oracle-tested|hardware-tested|deferred|blocked)(/| |\|)" docs/PARITY_MANIFEST.md | wc -l`
      reported `182` rows/statuses that are not literally `parity-accepted`.
      This is not necessarily a code defect, but it means release checklist
      item 2 still needs an explicit acceptance/deferral pass.
    - Generated-output hygiene is clean for the current checkout:
      `git status --short --untracked-files=all` produced no output.
  - Post-Nix-gate audit refresh 2026-05-23:
    - The release-time Linux Nix package/check gate is no longer a blocker.
      After explicit user authorization, both required Nix build commands
      passed and the evidence is recorded above.
    - Current unchecked rows from `rg -n "^- \[ \]|^\s+- \[ \]" plan.md` are
      only:
      - macOS direct build/test evidence, blocked until a macOS host is
        available or until the release scope explicitly defers macOS build/test
        evidence;
      - this final parity/hygiene audit, blocked until the macOS item is
        resolved or explicitly release-deferred and the manifest acceptance pass
        is complete.
    - Current manifest acceptance count is unchanged:
      `rg -n "\| (not-started|scaffolded|replay-tested|oracle-tested|hardware-tested|deferred|blocked)(/| |\|)" docs/PARITY_MANIFEST.md | wc -l`
      reports `182`.
    - Generated-output hygiene remains clean:
      `git status --short --untracked-files=all` produced no output.
  - Post-scanner-patching audit refresh 2026-05-23:
    - Scanner patching hardening is committed as
      `ee4b0da Harden V600 scanner patching`.
    - `git status --short --untracked-files=all` produced no output after that
      commit.
    - Current unchecked rows from `rg -n "^- \[ \]" plan.md` are only the macOS
      direct build/test evidence item and this final audit item.
    - A header-aware parse of `docs/PARITY_MANIFEST.md` found 142 rows with an
      actual `Status` column. The strict unresolved status cells are:
      - line 69 `blocked`: `scanner.py:70 ensure_interpreter`, blocked on the
        explicit proprietary Epson ICA download/extract/vendor policy decision
        and macOS host validation;
      - line 76 `scaffolded/replay-tested`: `scanner.py:370 close`, replayed for
        interpreter close but still not live macOS-tested;
      - line 104 `scaffolded/replay-tested`: `scanner.py:1190 _save_image`,
        partially represented by Linux TIFF save/metadata/mirror helpers;
      - line 105 `scaffolded/replay-tested`: `scanner.py:1221 main`, broad
        Python CLI parity remains intentionally represented by rewritten
        scanner/processing subcommands rather than every original CLI path;
      - line 115 `scaffolded/replay-tested`:
        `v600/core/backends/sane.py:479 SaneEpsonScanner._save_image`, same Linux
        save helper surface as line 104.
	    - This confirms there is no further honest local checklist completion without
	      either macOS host evidence or an explicit release-scope decision accepting
	      or deferring the remaining macOS/proprietary-interpreter and broad
	      CLI/save-surface gaps.
  - Post-export-handoff audit refresh 2026-05-23:
    - A live native Process export report showed scanner probe timing but no new
      files under `frames/`, `scans/processed/`, the repo, or `/tmp`; this exposed
      an export/Gallery diagnostic gap rather than a scanner issue.
    - Corrective work is recorded in the asynchronous Process export checkpoint
      above and in `docs/PARITY_MANIFEST.md`: export completion now validates
      reported files on disk, refreshes Gallery state after successful export, and
      emits structured `v600.processing.event.v1` diagnostics.
    - Validation after the corrective work:
      - `zig build test --summary all` passed `451/451`;
      - `zig build -Dui=true --summary all` passed;
      - `env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true
        native-process-export-smoke --summary all` passed and logged a real
        processing `file-written` event.
    - The smoke-generated `frames/ui-smoke_01_ir_004.tif` was removed after the
      check. `find frames -maxdepth 1 ...` now shows only older checked-ignore
      frame outputs, not a fresh generated TIFF.
    - Current unchecked rows from `rg -n "^- \[ \]|- \[ \]" plan.md` remain only
      the macOS direct build/test evidence item and this final audit item.
    - `git status --short --untracked-files=all` currently shows only intended
      tracked source/docs changes from this corrective checkpoint:
      `docs/PARITY_MANIFEST.md`, `plan.md`, `src/ui/process_export_worker.zig`,
      and `src/ui/state.zig`.
  - Post-selected-stock export audit refresh 2026-05-23:
    - A native Process export with a selected film stock could fail before
      spawning the export worker with `UnknownFilmStock`, even though the
      selected `kodak_gold`/`kodak_portra` profile affected the preview.
    - Root cause: the async export worker's active-stock helper returned a slice
      into a temporary copied config `Value`; the stock name was then stale by the
      time export coefficient lookup ran.
    - Corrective work:
      - added `LoadedConfig.entry` for stable borrowed access to stored config
        entries while retaining value-copy access for numeric/simple callers;
      - changed async export stock lookup to borrow the active stock string from
        the stored config entry;
      - changed the Process aspect string helper to use the same stable entry
        access and avoid the same temporary-slice class;
      - made built-in stock names with incomplete config-defined shadows fall
        back to compiled built-in coefficients, while complete custom profiles
        still override.
    - Validation:
      - `zig build test --summary all` passed `453/453`;
      - `zig build -Dui=true --summary all` passed;
      - `SDL_VIDEODRIVER=dummy zig build -Dui=true
        native-process-export-smoke --summary all` passed.
    - Added regression coverage for an async inverted export with selected
      `kodak_gold` and an incomplete `[stocks.kodak_gold]` shadow; this failed
      with `UnknownFilmStock` before the stable-entry fix.
    - The smoke-generated `frames/ui-smoke_01_ir_004.tif` was removed after the
      check. `git status --short --untracked-files=all` now shows only intended
      tracked source/docs changes for this checkpoint.
  - Browser/Wasm and macOS-pause audit refresh 2026-05-23:
    - Added `docs/WEBAPP_PORT_PLAN.md` and updated
      `docs/CROSS_PLATFORM.md`, `docs/PARITY_MANIFEST.md`, and this plan with a
      browser processing-webapp roadmap. This is docs-only future platform work;
      it does not alter native build behavior or the current release claim.
    - The user explicitly paused macOS build/test/scanner work until the work
      is reopened on macOS hardware. The macOS evidence row above is checked as
      a release-scope deferral, not as macOS support, and
      `docs/CROSS_PLATFORM.md` now says not to select macOS-only work in the
      autonomous loop until the user reopens it.
    - The user explicitly accepted that the project has met and exceeded Python
      parity for the current native-app release. Based on that release-scope
      decision, the remaining legacy scanner `_save_image` PNG-writer and
      exact `scanner.py` argparse-compatibility rows in
      `docs/PARITY_MANIFEST.md` are recorded as deferred/replay-tested
      non-blockers rather than hidden parity gaps. The current replacement
      surface is the native app plus rewritten scanner/processing subcommands.
    - Current checkbox audit:
      `rg -n "^- \[ \]|^\s+- \[ \]" plan.md` showed only this final audit row
      before it was checked.
    - Manifest status audit:
      a header-aware parse for actual `Status` columns found no remaining
      `not-started`, `scaffolded`, or `blocked` status cells after the macOS
      and legacy CLI/save-surface deferrals were recorded. Deferred rows now
      have explicit release-scope reasons.
    - Generated-output hygiene:
      `git status --short --untracked-files=all` currently shows only intended
      docs changes plus the new intended source document
      `docs/WEBAPP_PORT_PLAN.md`; no generated scans, frames, configs, TIFF,
      PNG, JPEG, or smoke outputs are present in git status.
    - Formatting hygiene:
      `git diff --check -- plan.md docs/CROSS_PLATFORM.md
      docs/PARITY_MANIFEST.md docs/WEBAPP_PORT_PLAN.md` passed.

### Phase 13: Browser/Wasm Distribution Implementation

This phase starts the browser distribution track now that the native Zig app is
accepted for the current parity claim. Continue to use direct `zig ...`
commands inside the ambient shell. Do not run Nix commands for ordinary loops.
If a web dependency is missing, edit Nix files if needed and stop for a human
shell reload before using it.

- [x] Tag the pre-Wasm checkpoint.
  - Completed 2026-05-23:
    - Created annotated tag `pre-wasm-checkpoint` on commit `cf46f12`
      (`Record webapp distribution plan`) before source changes for the
      browser/Wasm implementation track.
    - Existing release checkpoint tag `zig-port-mvp` remains untouched.

- [x] Add the first dependency-free Wasm processing core build target.
  - Scope:
    - Add a narrow freestanding Wasm build target instead of trying to
      compile the SDL3/Nuklear native app to a browser target.
    - Keep the core single-threaded and free of scanner, filesystem, SDL,
      Nuklear, OpenCV, SuperLU, libtiff, libjpeg, and `wgpu-native`
      dependencies.
    - Export only a tiny buffer ABI until a JS worker protocol exists.
  - Completed 2026-05-23:
    - Added `zig build wasm-core` to build
      `zig-out/bin/v600-wasm-core.wasm`.
    - Added `src/wasm_core.zig` as the exported root wrapper and
      `src/wasm/core.zig` as the reusable implementation module.
    - Exported `v600_wasm_alloc`, `v600_wasm_free`, and
      `v600_preview_invert_u16_to_u8`.
    - The first exported processing operation accepts an in-memory `u16 RGB`
      buffer plus `PreviewOptions`, applies the accepted
      `invert_negative`/render path with provided Dmin and film stock, and
      writes final `u8 RGB` preview pixels.
    - Added a Wasm-architecture sequential branch to the render helper so the
      first freestanding target does not depend on native `std.Thread`.
  - Validation 2026-05-23:
    - `zig build wasm-core --summary all` passed and produced
      `zig-out/bin/v600-wasm-core.wasm` (`705238` bytes).
    - `strings zig-out/bin/v600-wasm-core.wasm | rg 'v600_'` showed
      `v600_preview_invert_u16_to_u8`, `v600_wasm_free`, and
      `v600_wasm_alloc`.
    - `zig build test --summary all` passed `523/523`.
    - `zig build --summary all` passed.
    - `zig build -Dui=true --summary all` passed.
  - Update 2026-05-24:
    - The default browser processing core is now `wasm64-freestanding`, not
      `wasm32-freestanding`, because large scan workflows can exceed the 4 GiB
      wasm32 address ceiling. `wasm32` is retained only as an optional
      compatibility artifact while it remains trivial.

- [x] Add and run the headless JS/Wasm runtime harness.
  - Completed 2026-05-23:
    - Added `nodejs` to both `flake.nix` and `shell.nix`, then continued only
      after the human reloaded the project shell.
    - Added `test/wasm/wasm_core_smoke.mjs` as a Node-based headless harness.
    - Added `zig build wasm-core-smoke` as an explicit direct Zig step.
    - The harness loads the emitted Wasm module, verifies the expected exports,
      packs `PreviewOptions`, allocates raw input/output/options through
      `v600_wasm_alloc`, calls `v600_preview_invert_u16_to_u8`, checks final
      `u8 RGB` bytes, validates invalid-dimension and invalid-stock status
      returns, and frees caller-owned buffers.
  - Validation 2026-05-23:
    - `node --version` reported `v24.14.1`.
    - `zig build wasm-core-smoke --summary all` passed and reported
      `cold_instantiate_us=651`, `warm_processing_us=1410`,
      `input_samples=12`, `output_bytes=12`, `status=ok`.
    - `zig build -Doptimize=ReleaseFast wasm-core-smoke --summary all` passed
      and reported `cold_instantiate_us=575`, `warm_processing_us=1629`.

- [x] Add committed Web/Wasm fixture coverage.
  - Completed 2026-05-23:
    - Added a source-owned synthetic `u16 RGB` fixture and expected final
      `u8 RGB` preview bytes to both the native Wasm-core Zig test and the Node
      Wasm smoke harness.
    - The accepted tolerance for the first smoke is exact final byte equality
      because it is a tiny deterministic fixture running the same f32/LUT
      preview path.
    - The JS harness also exercises invalid dimensions and invalid stock IDs
      through the exported ABI.
  - Validation 2026-05-23:
    - `zig build test --summary all` passed `523/523`.
    - `zig build wasm-core-smoke --summary all` passed.
    - `zig build --summary all` passed.
    - `zig build -Dui=true --summary all` passed.

- [x] Define the browser worker protocol boundary.
  - Completed 2026-05-23:
    - Added `docs/WEBAPP_WORKER_PROTOCOL.md` as the protocol contract for the
      browser main thread and processing worker.
    - Added `web/worker/protocol.mjs` as a source-owned browser-compatible
      protocol helper module.
    - Added `test/wasm/worker_protocol_smoke.mjs` and
      `zig build wasm-worker-protocol-smoke`.
    - Message types now cover module load, image load, process-preview,
      process-export, cancel, ready/image-loaded, progress, timing,
      preview-result, export-result,
      stale-result, cancelled, and error flows.
    - The preview/export cache keys include selected file identity, dimensions,
      bit depth, page layout, selected frame, rebate/Dmin state, film stock
      coefficient hash, complete processing config state, render controls,
      preview size/quality, backend/precision, and output shape.
    - Stale worker results are rejected when `request_id`, `generation`, or
      `cache_key` no longer matches the active UI state.
  - Validation 2026-05-23:
    - `zig build wasm-worker-protocol-smoke --summary all` passed and reported
      cache key
      `sha256:9d82fe04aa444b45e9106a5fe6878cc1ab9552be33e99c81ea7480acb0de8f93`
      while checking `load-module`, `load-image`, `process-preview`,
      `process-export`, `cancel`, `preview-result`, `export-result`,
      `stale-result`, `timing`, and `error` messages.
    - The smoke proves cache keys change for selected file, image shape, frame
      geometry, rebate/Dmin, film stock coefficients, processing config, render
      config, preview sample cap, backend selection, and output shape.
    - `zig build wasm-core-smoke --summary all` passed.
    - `zig build test --summary all` passed `523/523`.
    - `zig build --summary all` passed.
    - `zig build -Dui=true --summary all` passed.

- [x] Implement the browser worker runtime loop.
  - Completed 2026-05-23:
    - Added `web/worker/processor.mjs` as a browser/Node-compatible module
      Worker runtime that consumes the checked protocol boundary.
    - The worker loads the Wasm module, verifies required exports, owns
      allocator/free calls, accepts transferred `u16 RGB` buffers, packs
      `PreviewOptions`, calls preview or RGB16 export Wasm entrypoints, and
      returns transferred `u8 RGB` preview or `u16 RGB` export buffers.
    - The worker emits timing, preview-result, error, stale-result, and
      cancelled messages through the protocol with request id, generation, and
      cache key preserved.
    - Added `test/wasm/worker_runtime_smoke.mjs` and
      `zig build wasm-worker-runtime-smoke`.
  - Validation 2026-05-23:
    - `zig build wasm-worker-runtime-smoke --summary all` passed and reported
      cache key
      `sha256:b8c377a296b220e0a621d9374a8ea9bb2b3170906fba9244b80ec58507bc0313`,
      `output_bytes=12`, and `status=ok`.
    - The smoke verified module load/ready, transferred raw input,
      transferred preview output, exact final `u8 RGB` bytes, recoverable
      invalid-stock errors, and cancellation acknowledgement.
    - `zig build wasm-worker-protocol-smoke --summary all` passed.
    - `zig build wasm-core-smoke --summary all` passed.
    - `zig build test --summary all` passed `523/523`.
    - `zig build --summary all` passed.
    - `zig build -Dui=true --summary all` passed.

- [x] Build the first browser processing shell.
  - Completed 2026-05-23:
    - Added `web/index.html`, `web/app.mjs`, `web/app_core.mjs`, and
      `web/styles.css`.
    - The shell imports raw RGB16 buffers through browser file APIs, accepts
      width/height metadata, selects built-in film stock, loads the Wasm worker,
      runs preview processing, draws returned RGB8 pixels to canvas, and keeps
      scanner controls out of the browser mode.
    - Added `test/wasm/webapp_shell_smoke.mjs` and
      `zig build wasm-webapp-shell-smoke` to test shell orchestration without a
      browser dependency.
    - The first shell deliberately does not port the SDL3/Nuklear native UI;
      it is a browser-native UI around the Wasm worker.
  - Validation 2026-05-23:
    - `zig build wasm-webapp-shell-smoke --summary all` passed and reported
      cache key
      `sha256:07ffab7b1cae25df986196de64eb28cdb9c8295cbf64f422d6d0037e083589f2`,
      `output_bytes=12`, and `status=ok`.
    - The smoke verified raw RGB16 size validation, Worker module load, cache
      key construction, exact final RGB8 bytes, and RGB8-to-RGBA canvas buffer
      conversion.

- [x] Add browser scan-file image I/O expansion.
  - Completed 2026-05-23:
    - Added `web/tiff.mjs` as a browser-side classic TIFF reader for the first
      supported scanner-file shape.
    - The reader preserves the committed fixture semantics for uncompressed
      page 0 RGB16, ignored page 1 thumbnail, optional page 2 8-bit IR, RGB
      dimensions, IR dimensions, bit depth, and page-0 DPI.
    - Wired `.tif`/`.tiff` browser file inputs through the shell path:
      `web/app.mjs` now decodes the RGB16 page, fills width/height, and sends
      the decoded RGB buffer through the Wasm worker.
    - Added `test/wasm/tiff_reader_smoke.mjs` and
      `zig build wasm-tiff-reader-smoke`.
  - Validation 2026-05-23:
    - `zig build wasm-tiff-reader-smoke --summary all` passed against
      `test/fixtures/tiff/rgb-thumb-ir.tiff`, reporting `pages=3`,
      `rgb_samples=12`, `ir_samples=6`, `dpi=800`, and `status=ok`.
    - `zig build wasm-webapp-shell-smoke --summary all` also processed the
      committed TIFF RGB page through the browser shell worker path.

- [x] Add browser preview controls and download output.
  - Completed 2026-05-23:
    - Added browser controls for Dmin RGB, contrast, curve, percentile limits,
      exposure, color temp/tint, percentile sample cap, and built-in stock.
    - Threaded those controls through `WebPreviewClient.processRawRgb16`, the
      preview cache key, and the worker `PreviewOptions` request.
    - Added `rgb8ToPpmBytes` and a browser PPM preview download action.
    - Extended the shell smoke to prove render/Dmin/sample-limit changes alter
      the cache key and that PPM output bytes are generated with the expected
      header and length.
  - Validation 2026-05-23:
    - `zig build wasm-webapp-shell-smoke --summary all` passed and reported
      cache key
      `sha256:07ffab7b1cae25df986196de64eb28cdb9c8295cbf64f422d6d0037e083589f2`,
      `output_bytes=12`, and `status=ok`.

- [x] Add browser frame selection and export workflow expansion.
  - Add browser-side frame selection state and canvas interaction for full
    image or manual crop rectangles.
  - Decide whether browser frame autodetect uses the existing Zig frame code in
    Wasm or a staged later port of its dependencies.
  - Add export-shaped output beyond preview PPM, including metadata and file
    naming contracts, before claiming browser export parity.
  - Completed 2026-05-23:
    - Added normalized browser frame selection helpers and RGB16 crop logic in
      `web/app_core.mjs`.
    - Threaded selected frame geometry through `WebPreviewClient.processRawRgb16`,
      the preview cache key, the cropped worker input buffer, and returned
      result metadata without changing the native Zig UI or worker.
    - Added numeric frame controls, a Full Frame action, and canvas drag
      rectangle selection in the browser shell.
    - Added deterministic preview export naming plus
      `v600.webapp.preview-export.v1` JSON metadata sidecars alongside the PPM
      preview download.
    - Browser frame autodetect is explicitly staged for a later checkpoint:
      use the accepted Zig frame code in Wasm only after its pure dependency
      boundary is audited, rather than adding a second browser-only detector.
  - Validation 2026-05-23:
    - `zig build wasm-worker-protocol-smoke wasm-worker-runtime-smoke wasm-webapp-shell-smoke --summary all`
      passed. The shell smoke reported cache key
      `sha256:07ffab7b1cae25df986196de64eb28cdb9c8295cbf64f422d6d0037e083589f2`,
      `output_bytes=12`, and `status=ok`.
    - The shell smoke verifies exact full-frame RGB8 output, manual `1x2`
      crop sample bytes, selected-frame cache-key mutation, result frame
      round-trip, PPM filename contract, metadata filename contract, and JSON
      metadata schema.

- [x] Add browser static packaging and local serve smoke.
  - Add a direct Zig build step that installs or stages the web shell assets
    and emitted `v600-wasm-core.wasm` into a single static distribution
    directory.
  - Keep the package static: no Node bundler, no browser framework, and no
    runtime dependency on repository-relative paths.
  - Add a headless or minimal HTTP smoke that proves `web/index.html`, module
    imports, worker imports, and the Wasm artifact are addressable from the
    staged directory.
  - Document the normal user command for serving the static webapp locally.
  - Completed 2026-05-23:
    - Added `zig build wasm-webapp` to stage `web/` plus the generated
      `v600-wasm-core.wasm` into `zig-out/webapp/`.
    - Changed the browser shell's default Wasm URL to
      `./v600-wasm-core.wasm`, so the staged app is self-contained instead of
      relying on a repository-relative `zig-out/bin` path.
    - Added `test/wasm/webapp_static_smoke.mjs` and
      `zig build wasm-webapp-static-smoke` to verify the staged static layout
      through a local HTTP server.
    - Documented the local-use command:
      `zig build wasm-webapp`, then
      `python3 -m http.server 8433 --bind 127.0.0.1 --directory zig-out/webapp`.
  - Validation 2026-05-23:
    - `zig build wasm-webapp-static-smoke --summary all` passed, installed
      `web/`, installed the generated Wasm artifact, served 8 staged files,
      and verified the `v600-wasm-core.wasm` magic bytes.

- [x] Add browser full-resolution RGB16 export path.
  - Add a Wasm/browser export operation that can emit full selected-frame
    output at export resolution, not only an RGB8 preview PPM.
  - Preserve the Python/Zig accepted processing controls and metadata surface
    in the export cache key.
  - Decide the first browser export file format deliberately. TIFF parity is
    preferred for scan workflow parity, but PNG or PPM may be an interim
    artifact only if documented as not export parity.
  - Completed 2026-05-23:
    - Added `v600_export_invert_u16_to_u16` to the dependency-free Wasm core,
      reusing the same custom `invert_negative` path and accepted
      `renderToDisplayU16F32` export render surface.
    - Added `process-export` / `export-result` protocol messages, export
      cache-key operation separation, and worker runtime dispatch with
      transferred `u16 RGB` output.
    - Added `WebPreviewClient.exportRawRgb16`, `rgb16ToPpmBytes` for headless
      diagnostics, and an `Export RGB16` browser action for the current
      selected frame.
    - The initial browser export operation is full-resolution selected-frame
      RGB16 pixel output. The browser-facing file wrapper is handled by the
      follow-up TIFF checkpoint below.
  - Validation 2026-05-23:
    - `zig build wasm-core-smoke wasm-worker-protocol-smoke wasm-worker-runtime-smoke wasm-webapp-shell-smoke wasm-webapp-static-smoke --summary all`
      passed. The core smoke reported `export_output_bytes=24`; the protocol
      smoke checked `process-export` and `export-result`; the worker and shell
      smokes verified transferred RGB16 output.
    - `zig build test --summary all` passed `523/523`.
    - The native Wasm-core test and Node smokes verify that exact tiny-fixture
      RGB16 export samples shift down to the accepted RGB8 preview bytes.

- [x] Add browser TIFF export path.
  - Emit browser exports in an accepted native/Python-compatible TIFF shape for
    the current RGB16 positive output.
  - Preserve metadata sidecar semantics, selected-frame naming, bit depth, and
    output variant contracts from the native export pipeline.
  - Keep the RGB16 PPM helper as a diagnostic byte-surface check, not as the
    user-facing browser export.
  - Completed 2026-05-23:
    - Added `rgb16ToTiffBytes` to `web/tiff.mjs` as a narrow classic
      little-endian, uncompressed, chunky RGB16 TIFF writer with DPI metadata.
    - Changed the browser `Export RGB16` action to download TIFF plus
      `v600.webapp.rgb16-export.v1` JSON metadata instead of exposing the PPM
      diagnostic format as the user-facing export.
    - Kept `rgb16ToPpmBytes` in the headless shell smoke as a simple diagnostic
      byte-surface helper, not as the browser export file format.
  - Validation 2026-05-23:
    - `zig build wasm-tiff-reader-smoke wasm-webapp-shell-smoke wasm-webapp-static-smoke --summary all`
      passed. The TIFF reader smoke now round-trips the committed RGB fixture
      through the browser TIFF writer. The shell smoke round-trips the Wasm
      RGB16 export TIFF bytes through `loadRgb16PageFromTiff` and verifies DPI,
      dimensions, and exact samples.

- [x] Add browser native export variant parity.
  - Port the native export variant model beyond the current RGB16 positive
    output: IR-negative, IR-inverted, no-IR fallback naming, and any enabled
    sidecar fields that the browser can support without scanner control.
  - Keep unsupported browser-only gaps explicit, especially dust cleanup until
    IR alignment/processing is available in the web pipeline.
  - Completed 2026-05-23:
    - Added browser-native definitions for the accepted export variants in the
      same order as native Zig: `ir_neg`, `ir_inv`, `inv_only`.
    - Preserved native suffixes and metadata variant names:
      `_ir`/`ir_cleaned`, empty suffix/`ir_cleaned_inverted`, and
      `_inv`/`inverted`.
    - Added browser output checkboxes with native default selection
      `ir_inv=true`, `ir_neg=false`, `inv_only=false`.
    - Implemented the supported no-IR fallback behavior: `ir_neg` exports the
      selected raw RGB16 negative crop, while `ir_inv` and `inv_only` export
      inverted RGB16 through the Wasm worker. True IR dust cleanup remains a
      separate processing-port checkpoint.
    - Added native-shaped browser export filenames:
      `<basename>_01_ir.tif`, `<basename>_01.tif`, and
      `<basename>_01_inv.tif`, plus `.tif.json` sidecars.
    - Added `v600.webapp.native-export-metadata.v1` metadata with native
      `source`, `rebate_rect`, `crop`, and `variant` fields; inverted variants
      also include stock, contrast, and Dmin like native metadata.
  - Validation 2026-05-23:
    - `zig build wasm-webapp-shell-smoke --summary all` passed. The shell smoke
      verifies variant order, suffix filenames, metadata filenames,
      per-variant cache-key separation, raw `_ir` crop bytes, inverted variant
      output equality, and native metadata variant fields.

- [x] Port browser IR cleanup and aligned RGB/IR export variants.
  - Use TIFF page 2 IR input when present and port the accepted IR alignment,
    adaptive dust mask, inpaint, and IR-cleaned output path to Wasm/browser.
  - Keep the current no-IR fallback behavior as the baseline until the IR path
    has final-output parity evidence.
  - Add headless fixtures that compare masks, cleaned RGB16 outputs, and
    metadata against native/Python oracle data.
  - [x] Preserve TIFF RGB+IR identity in browser cache and sidecar metadata.
    - Completed 2026-05-23:
      - Browser TIFF decoding now propagates `page_layout="rgb-thumb-ir"` and
        IR page shape metadata into preview/export cache-key payloads and
        metadata sidecars.
      - The webapp shell smoke asserts the IR-aware cache key differs from the
        RGB-only descriptor for the same TIFF source.
  - [x] Add a headless Wasm/worker IR defect-mask slice.
    - Completed 2026-05-23:
      - Added `IrMaskOptions` and `v600_ir_make_defect_mask_u8` to the
        freestanding Wasm core.
      - The Wasm path uses the accepted Zig `makeDefectMask` algorithm on
        8-bit IR page samples converted to the same f64 domain as native TIFF
        loading, with single-worker execution for browser/no-libc targets.
      - Added worker protocol/runtime support for `process-ir-mask` and
        `ir-mask-result`; cache keys include file identity, RGB/IR page layout,
        IR dimensions, dust-removal config, backend, and output kind.
      - Native C helper-dependent paths remain intentionally unavailable in
        browser/no-libc builds: OpenCV ECC alignment, local-grain estimation,
        SuperLU sparse inpaint, grain synthesis, and full cleaned-RGB export.
    - Validation 2026-05-23:
      - `zig build wasm-core-smoke wasm-worker-protocol-smoke wasm-worker-runtime-smoke wasm-webapp-shell-smoke wasm-tiff-reader-smoke wasm-webapp-static-smoke --summary all`
        passed, including `ir_mask_bytes=81`, `process-ir-mask`, and
        `ir-mask-result` coverage.
      - `zig build test --summary all` passed with 552 pass / 8 expected skips
        in the no-libc `wasm_core` imported native-helper fixture tests.
      - `zig build --summary all` passed.
      - `zig build -Dui=true --summary all` passed.
  - [x] Port browser IR alignment.
    - Decide whether the browser path needs an exact pure-Zig ECC replacement,
      a constrained translation-search approximation with final-output
      evidence, or a documented no-alignment first checkpoint for TIFFs whose
      RGB/IR pages are already aligned.
    - Keep any approximation behind explicit parity metrics against native
      `alignIr` fixtures and real RGB+IR scan crops.
    - [x] Add a browser-safe provided-offset IR translation primitive.
      - Completed 2026-05-23:
        - Added `IrAlignOptions` and `v600_ir_apply_translation_f32` to the
          freestanding Wasm core.
        - Added `process-ir-align` and `ir-align-result` to the worker
          protocol/runtime, plus app-core cache helpers and
          `WebPreviewClient.applyIrTranslationF32`.
        - This is not full browser IR alignment parity yet: it applies a known
          offset with reflect-boundary bilinear sampling so later ECC/search
          offset estimation can feed the same transform.
      - Validation 2026-05-23:
        - `zig build wasm-core-smoke wasm-worker-protocol-smoke wasm-worker-runtime-smoke wasm-webapp-shell-smoke wasm-tiff-reader-smoke wasm-webapp-static-smoke --summary all`
          passed.
        - The core, worker runtime, and shell smokes replayed
          `test/fixtures/processing/ir/align-ratio-1-to-2.json` with final
          aligned-IR error `max_abs=0.0037903999982518144` and
          `rms=0.00080799120470609`.
        - `zig build test --summary all` passed with 552 pass / 8 expected
          skips in the no-libc `wasm_core` imported native-helper fixture
          tests.
        - `zig build --summary all` passed.
        - `zig build -Dui=true --summary all` passed.
        - `git diff --check` passed.
    - [x] Port browser offset estimation for IR alignment.
      - Either port the native ECC dependency to pure Zig/Wasm-compatible code
        or implement a constrained translation-search approximation with
        final-output evidence against native `alignIr` fixtures and real
        RGB+IR scan crops.
      - Rejected shortcut, 2026-05-23:
        - A direct normalized-correlation/MSE translation search against the
          deterministic alignment fixtures selects `(tx=8, ty=-5)` for both
          1:2 and 1:4 RGB:IR cases, while the frozen Python/OpenCV ECC oracle
          reports `(tx=9.91815185546875, ty=-5.849216461181641)`.
        - Applying the correlation-search offset to
          `align-ratio-1-to-2.json` produced final aligned-IR error
          `max_abs=5518.508537260004`, `rms=1875.8776050286474` for the
          integer candidate. A closer OpenCV-source-shaped JS prototype still
          produced `max_abs=4281.558554020983`, `rms=1275.7578724824039`.
        - Do not wire a simple correlation search as the browser alignment
          estimator without mask/final-cleaned-output evidence that justifies
          the divergence. The next serious attempt should port the
          translation-only ECC iteration more faithfully, including OpenCV's
          small-image preprocessing, Gaussian smoothing, gradient filters,
          valid-pixel mask, lambda update, and convergence semantics.
      - [x] Add a browser worker translation-ECC estimator first slice.
        - Completed 2026-05-23:
          - Added `IrEstimateOptions`, `IrEstimateResult`, and
            `v600_ir_estimate_translation_f32` to the freestanding Wasm core.
          - The estimator follows the Python/OpenCV alignment shape:
            RGB-to-8-bit grayscale conversion, RGB-to-IR area downscale,
            IR 8-bit normalization, `ecc_scale=0.125` area downscale,
            5x5 Gaussian smoothing, central-difference image gradients,
            translation-only ECC lambda update, in-place masked image
            zero-meaning semantics, 1/32 fixed-point bilinear warp weights,
            and full-resolution offset scaling.
          - Added worker/app-core protocol support for `process-ir-estimate`
            and `ir-estimate-result`, with cache keys that include file
            identity, RGB/IR page layout, IR dimensions, estimator config,
            backend, and output kind.
          - This remains a first slice, not full browser IR alignment
            completion: it is fixture-tested but still needs real RGB+IR scan
            crop evidence before checking off browser offset estimation.
        - Validation 2026-05-23:
          - `zig build wasm-core-smoke wasm-worker-protocol-smoke wasm-worker-runtime-smoke wasm-webapp-shell-smoke wasm-tiff-reader-smoke wasm-webapp-static-smoke --summary all`
            passed.
          - `wasm-core-smoke` estimated `tx=9.883345603942871`,
            `ty=-5.884145736694336`, `rho=0.987080991268158`,
            `iterations=5` against the OpenCV/Python oracle
            `tx=9.91815185546875`, `ty=-5.849216461181641`.
          - Applying that estimated offset to
            `test/fixtures/processing/ir/align-ratio-1-to-2.json` produced
            final aligned-IR error `max_abs=141.42405929500092`,
            `rms=41.3169664994467`.
          - `zig build test --summary all` passed with 552 pass / 8 expected
            skips in the no-libc `wasm_core` imported native-helper fixture
            tests.
          - `zig build --summary all` passed.
          - `zig build -Dui=true --summary all` passed.
          - Real scan probe:
            - Native Python/OpenCV oracle on
              `scans/scan_0006_rgbir_800dpi.tiff` reported
              `tx=0.7342356443405151`, `ty=-2.5735411643981934`,
              `rho=0.9041734788915521` on a `1272x6031` RGB/IR scan.
            - `node test/wasm/real_scan_ir_estimate_probe.mjs zig-out/webapp/v600-wasm-core.wasm scans/scan_0006_rgbir_800dpi.tiff`
              reported Wasm/browser estimate `tx=0.9593804478645325`,
              `ty=-2.5981011390686035`, `rho=0.9173573851585388`,
              `iterations=14`, worker elapsed `583069 us`.
            - Applying the native and Wasm-estimated offsets to the real
              8-bit IR page with SciPy reflect/bilinear shift produced
              `max_abs=14.833351135253906`, `rms=0.29577261209487915`,
              and `mismatch_rate_gt_1=0.010591764353773845`.
        - Acceptance note:
          - Browser IR alignment is now available as two worker/app-core
            operations: estimate translation-ECC offset, then apply the
            translation to the IR plane.
          - True IR-cleaned browser export is still intentionally disabled
            until the cleaned-RGB output item below has final-output evidence.
  - [x] Port browser cleaned-RGB output.
    - Reuse the browser IR mask, resize it to RGB dimensions exactly like
      native `irCleanRegion`, then add an inpainting strategy with headless
      mask-overlap and final `u16` cleaned-output evidence.
    - Do not enable browser `ir_neg`/`ir_inv` true IR-cleaned exports until
      cleaned RGB16 output and sidecar metadata have parity evidence.
    - [x] Port browser RGB-sized IR-mask geometry.
      - Completed 2026-05-23:
        - Added `IrMaskResizeOptions` and `v600_ir_resize_mask_to_rgb_u8` to
          the freestanding Wasm core.
        - The operation matches the native `irCleanRegion` geometry branch:
          same-size RGB/IR masks are copied, size-mismatched masks use nearest
          IR-to-RGB resize followed by the fixed radius-1 3x3 ellipse dilation.
        - Added `process-ir-rgb-mask` and `ir-rgb-mask-result` to the worker
          protocol/runtime plus app-core cache helpers and
          `WebPreviewClient.resizeIrMaskToRgbU8`.
        - The RGB-sized-mask cache key includes the upstream IR-mask cache key,
          RGB/IR dimensions, dust-removal config, resize mode, post-resize
          dilation rule, backend, and output kind so cached mask geometry cannot
          silently cross UI/config states.
      - Validation 2026-05-23:
        - `zig build wasm-core-smoke wasm-worker-protocol-smoke wasm-worker-runtime-smoke wasm-webapp-shell-smoke --summary all`
          passed.
        - `wasm-core-smoke` replayed
          `test/fixtures/processing/ir/ir-clean-region-resize-uint16-smoke.json`
          through IR-mask generation plus RGB-mask resize and matched the oracle
          `expected_ir_mask` and `expected_mask`, reporting
          `ir_rgb_mask_bytes=2592` and `ir_rgb_mask_defect_pixels=96`.
        - Worker protocol/runtime and shell smokes covered
          `process-ir-rgb-mask`, `ir-rgb-mask-result`, transferred mask output,
          cache-key equality, and client method wiring.
    - [x] Port browser inpainting and final cleaned RGB16 output.
      - Decide whether the first browser path ports native grain estimation,
        biharmonic solve, and grain synthesis directly to dependency-free Zig or
        stages a documented approximation behind final-output mask/shared-area
        and RGB16 error evidence.
      - Keep `ir_neg`/`ir_inv` browser export fallbacks in place until this
        checkpoint passes final-output evidence.
      - [x] Port browser-safe biharmonic RGB16 repair.
        - Completed 2026-05-23:
          - Added `IrInpaintOptions` and `v600_ir_biharmonic_inpaint_u16` to
            the freestanding Wasm core.
          - The operation converts caller-managed RGB16 samples to normalized
            f64, runs the accepted Zig `biharmonicInpaint` solver with the
            caller-provided RGB-sized mask, and writes final RGB16 samples.
          - Added `process-ir-inpaint` and `ir-inpaint-result` to the worker
            protocol/runtime plus app-core cache helpers and
            `WebPreviewClient.inpaintBiharmonicRgb16`.
          - The inpaint cache key includes file identity, RGB/IR metadata,
            dust-removal config, upstream RGB-mask cache key, inpaint mode
            `biharmonic-no-grain`, value kind, backend, and output kind.
        - Validation 2026-05-23:
          - `zig build wasm-core-smoke wasm-worker-protocol-smoke wasm-worker-runtime-smoke wasm-webapp-shell-smoke --summary all`
            passed.
          - `wasm-core-smoke` replayed
            `test/fixtures/processing/ir/biharmonic-inpaint-smoke.json` after
            RGB16 quantization with `ir_inpaint_samples=168`,
            `ir_inpaint_max_abs=1`, and
            `ir_inpaint_rms=0.17251638983558856`.
          - Worker runtime and app shell smokes transferred RGB16 plus RGB-mask
            buffers through `process-ir-inpaint` and checked final RGB16 output
            with `max_abs <= 2`.
        - Remaining caveat:
          - This is a biharmonic-only repair stage. It does not include native
            local-grain estimation, DFT-shaped grain synthesis, runtime random
            noise capture, or final full `irCleanRegion` RGB16 parity. Do not
            enable browser `ir_neg`/`ir_inv` dust-cleaned exports from this
            stage alone.
      - [x] Port browser local-grain estimation and grain synthesis.
        - Completed 2026-05-23:
          - Added browser/no-libc local grain estimation that mirrors the native
            helper contract: OpenCV-shaped ellipse dilation, sigma-2.5
            reflect101 RGB blur, surrounding-grain standard deviation, Hann
            windowing, radial DFT spectrum capture, and normalized spectrum
            output.
          - Added dependency-free DFT/IDFT grain synthesis for browser Wasm,
            including spectrum-shaped and `1/radius` fallback shaping,
            per-channel standard-deviation normalization, f32 rounding, and
            interleaved RGB output.
          - Added `IrInpaintGrainOptions` and
            `v600_ir_inpaint_grain_u16_with_noise` to the freestanding Wasm
            core. The exported operation runs the same component/ROI loop as
            native `inpaintBiharmonicWithGrainFromNoise`: copy RGB16 input,
            label 8-connected mask components, extract padded ROIs from the
            current output buffer, estimate local grain, repair the blurred
            signal with the accepted Zig biharmonic solver, synthesize captured
            grain noise, and write back only masked RGB16 pixels.
          - Extended `process-ir-inpaint` so the worker can run either
            `biharmonic-no-grain` or `biharmonic-grain` depending on whether
            grain options are supplied. Grain-aware calls may transfer a
            captured `Float64` noise buffer for oracle tests or provide a
            `noise_seed` for worker-generated runtime noise.
          - Extended the inpaint cache key to include inpaint mode, value kind,
            padding, grain padding, and either a captured-noise hash or seed
            identity. This keeps cached cleaned output keyed by the full state
            that affects the grain-aware result.
          - Added `WebPreviewClient.inpaintGrainRgb16WithNoise` for app-shell
            orchestration.
        - Validation 2026-05-23:
          - `zig build wasm-core-smoke --summary all` passed and replayed
            `test/fixtures/processing/ir/inpaint-biharmonic-grain-uint16-smoke.json`
            with `ir_grain_inpaint_samples=504`,
            `ir_grain_inpaint_max_abs=0`, `ir_grain_inpaint_rms=0`, and
            `ir_grain_inpaint_mismatches=0`.
          - `zig build wasm-worker-protocol-smoke wasm-worker-runtime-smoke wasm-webapp-shell-smoke --summary all`
            passed. Worker/runtime and shell smokes transferred RGB16, RGB-mask,
            and captured-noise buffers through `process-ir-inpaint` in
            `biharmonic-grain` mode and checked final RGB16 output against the
            oracle fixture tolerance.
      - [x] Wire browser full cleaned RGB16 output.
        - Completed 2026-05-23:
          - Added `WebPreviewClient.exportIrCleanedRgb16`, which composes the
            accepted browser primitives into the Python-shaped export path:
            optional translation-ECC IR alignment over full scan pages, RGB and
            aligned-IR frame crops using the same scaled geometry, f32 IR defect
            mask generation, RGB-sized mask resize/dilate, grain-aware RGB16
            inpaint, and optional Wasm inversion/render for `ir_inv`.
          - Browser UI export now uses real IR cleaning for `_ir`/`ir_neg` and
            empty-suffix `ir_inv` whenever the loaded TIFF includes an IR page.
            The no-IR fallback remains for scan files without IR data.
          - Added exact shell-level full-cleaned-output coverage for
            `test/fixtures/processing/ir/ir-clean-region-uint16-smoke.json` in
            `ir_neg` mode. The same smoke also verifies `ir_inv` by comparing
            browser cleaned-plus-inverted output against the accepted Wasm
            inversion/export path run over the oracle cleaned RGB16 image.
          - Worker `process-ir-mask` now accepts either 8-bit TIFF IR buffers or
            f32 IR buffers. Browser TIFF imports still use 8-bit IR pages;
            f32 support exists so headless oracle fixtures can exercise the
            same high-level composition without quantizing Python fixture IR.
        - Validation 2026-05-23:
          - `zig build wasm-webapp-shell-smoke --summary all` passed with the
            composed `ir_neg` output within the fixture tolerance and exact
            `ir_inv` compositional equality against accepted cleaned-input
            inversion.

- [x] Add browser frame autodetect worker and shell first slice.
  - Scope:
    - Expose the accepted Zig frame detector through the dependency-free Wasm
      core rather than adding a browser-only detector.
    - Add worker protocol/runtime coverage, cache keys that include the full
      detection state, and browser shell controls for format and optional frame
      count.
    - Keep scanner control out of the browser mode.
  - Completed 2026-05-23:
    - Added `FrameDetectOptions`, `FrameDetectRect`,
      `FrameDetectResult`, and `v600_detect_frames_rgb16` to the Wasm core.
      The operation accepts raw in-memory RGB16 preview/scan data, runs
      `frames.detectFramesFromImage`, applies the accepted single-small-frame
      fallback and inter-frame rebate suggestion, and returns preview-space
      frame rects plus aspect/rebate metadata.
    - Gated frame-detector helper parallel branches on Wasm targets so the
      browser core uses the same algorithms sequentially without importing
      native `std.Thread` behavior into the single-threaded freestanding build.
    - Added `process-frame-detect` / `frame-detect-result` protocol messages,
      `frameDetectCacheKeyString`, worker runtime dispatch, and
      `WebPreviewClient.detectFramesRgb16`.
    - Added browser shell `Format`, optional `Frames`, and `Auto Detect`
      controls. The shell calls the worker detector and applies the first
      returned frame to the existing numeric/canvas crop controls.
  - Validation 2026-05-23:
    - `zig build wasm-worker-protocol-smoke wasm-worker-runtime-smoke --summary all`
      passed. The worker runtime smoke synthesized the committed
      `axis-35mm-vertical-three-frame` detector case in RGB16, ran it through
      the emitted Wasm core, checked `aspect="24:36"`, checked all three frame
      rects within 12 preview pixels, and confirmed a suggested rebate exists.
    - `zig build wasm-webapp-shell-smoke --summary all` passed. The shell smoke
      verifies `WebPreviewClient.detectFramesRgb16`, cache-key equality, aspect
      reporting, detected frame geometry, and rebate reporting.
    - `zig build wasm-core --summary all` passed after the detector import and
      Wasm threading guards.
  - Remaining caveat:
    - This was a detector and first-shell application slice only. Multi-frame
      browser selection, rotated crop, and export-all behavior are handled by
      the following checkpoint.

- [x] Add browser multi-frame selection, rotated crop, and export-all parity.
  - Use `frame-detect-result.frames` as a browser selection list instead of
    discarding all but the first frame.
  - Preserve per-frame preview-space `cx/cy/w/h/angle`, active selection,
    frame index, and output filenames/metadata for every selected frame.
  - Port or expose an accepted rotated RGB16 crop path for preview/export so
    browser output can honor detector angles and manual rotated selections
    instead of silently forcing axis-aligned rectangles.
  - Add headless checks for:
    - detected frame list round-trip through `WebPreviewClient`;
    - first/active/next selection state and cache-key separation;
    - rotated crop final pixels against native Zig/Python fixture tolerance;
    - export filenames using frame indexes beyond `_01`;
    - export of all selected variants for every selected frame.
  - Completed 2026-05-23:
    - Browser frame selections now preserve nonzero frame angles in radians,
      matching the Python UI and native Zig process model, and the shell exposes
      an explicit Angle control plus a Detected frame selector.
    - Auto Detect stores every returned frame as a selectable browser frame
      instead of applying only the first one. The active frame is used for
      preview/process, and the `All frames` export control exports every
      detected/selected frame with native `_01`, `_02`, ... frame numbering.
    - Added browser-side affine rotated crop helpers for RGB16 and scalar IR
      buffers using the same OpenCV-style transform, reflect boundary handling,
      crop dimensions, and radians-to-transform convention as the accepted
      Python/Zig rotated crop path. Axis-aligned crops keep the fast row-copy
      path.
    - Added `frameSelectionFromDetectedFrame` and
      `exportNativeVariantResults` so multi-frame export orchestration is
      headlessly testable outside the DOM shell.
  - Validation 2026-05-23:
    - `zig build wasm-webapp-shell-smoke wasm-webapp-static-smoke --summary all`
      passed. The shell smoke now checks detected-frame selection conversion,
      RGB16 rotated crop against the Python/Zig rotated-crop fixture with
      `max_abs <= 250` in 16-bit scaled sample space, f32 scalar IR rotated crop
      with `max_abs <= 0.25`, rotated preview filename angle tagging, and
      multi-frame/multi-variant export filenames plus metadata crop state.

- [x] Benchmark browser rotated crop/export on large scan data and decide
  whether crop should move into the Wasm worker.
  - The new affine crop path is behavior-focused and currently runs in the
    browser shell before handing cropped RGB/IR buffers to the Wasm processing
    worker.
  - Measure real scan-sized axis-aligned and rotated crops, preview, and full
    export-all flows before moving it. If crop time is material, add a worker
    protocol operation or fold frame selection into existing process/export
    messages so the heavy crop runs inside the Wasm worker with the same final
    pixel checks.
  - Completed 2026-05-23:
    - Added `test/wasm/webapp_crop_export_bench.mjs` and
      `zig build bench-wasm-webapp-crop-export` for local scan-backed browser
      crop/export timing. The benchmark skips cleanly when gitignored local
      scans are absent and can be pointed at a scan with
      `V600_WASM_BENCH_SCAN=...`.
    - Added optional worker-side RGB16 crop handling to `process-preview` and
      `process-export`. Browser preview/export cache keys still include full
      selected-frame state, but the heavy RGB crop now runs in the Worker and
      reports `worker.crop-rgb16` timing before the Wasm inversion/export call.
      Axis-aligned and rotated crop pixel behavior still routes through the
      same tested browser crop helper.
    - The web UI now passes disposable decoded RGB buffers to the worker for
      preview/export so selected-frame crop work no longer blocks UI state
      handling in the common RGB preview and inverted-export paths.
  - Benchmark evidence 2026-05-23:
    - `V600_WASM_BENCH_SCAN=scans/scan_0006_rgbir_800dpi.tiff zig build bench-wasm-webapp-crop-export --summary all`
      passed. It used two 35mm frames from the Python detector fixture,
      measured axis crop median `2839 us`, rotated crop median `39365 us`,
      `worker.crop-rgb16` export timings `43759 us` and `38660 us`,
      export-all `224686 us`, and decision
      `crop-is-material-and-now-runs-in-worker; consider-wasm-crop-optimization-later`.
    - A direct 3200 DPI run,
      `node test/wasm/webapp_crop_export_bench.mjs zig-out/webapp/v600-wasm-core.wasm --scan scans/scan_0004_rgbir_3200dpi.tiff --max-frames 1 --variant inv-only --crop-repeats 1`,
      measured RGB `5120x24125`, one full-resolution detected frame
      `3063x4600`, axis crop `32838 us`, rotated crop `624732 us`,
      preview `worker.crop-rgb16=622467 us`, export
      `worker.crop-rgb16=667572 us`, export total `1572892 us`, and crop share
      `0.397`.
  - Decision:
    - Crop is too material to run on the browser UI thread. It now runs in the
      browser Worker for RGB preview and inverted RGB16 export. Do not move it
      into the freestanding Wasm core yet; the next useful evidence is whether
      worker-side JS crop remains a bottleneck after the current worker-side
      IR-clean orchestration split.

- [x] Move remaining browser IR-clean export orchestration off the UI thread.
  - `WebPreviewClient.exportIrCleanedRgb16` still performs some heavy
    composition on the caller side: RGB and IR frame crops plus sequencing of
    intermediate buffers.
  - Move the remaining browser IR-clean composition into worker-owned
    operations or a worker-owned image session so `_ir` and `ir_inv` exports do
    not block UI state management on large scans.
  - Keep cache keys explicit and complete. The worker may keep resident decoded
    image buffers, but every result must still be keyed by selected file
    identity, frame geometry, processing config, dust settings, Dmin/render
    state, stock, output variant, and any generated noise identity.
  - [x] Move runtime grain-noise generation into `process-ir-inpaint`.
    - Completed 2026-05-23: `inpaintGrainRgb16WithNoise` can now send a
      `noise_seed` instead of a full `Float64` noise buffer. The worker derives
      deterministic standard-normal noise, reports
      `worker.generate-ir-grain-noise`, and the inpaint cache key records
      `seed:<noise_seed>`.
    - Direct `zig build wasm-webapp-shell-smoke wasm-worker-runtime-smoke wasm-worker-protocol-smoke --summary all`
      passed. The shell smoke verifies that two calls with the same seed produce
      byte-identical grain-aware RGB16 output.
  - [x] Move full-page RGB/IR f32 conversion for browser IR alignment out of
    `WebPreviewClient.exportIrCleanedRgb16`.
    - Completed 2026-05-23: `process-ir-estimate` and `process-ir-align` now
      accept raw scalar buffer descriptors such as `u16` RGB and `u8`/`f32` IR.
      The worker converts non-f32 inputs before calling the accepted f32 Wasm
      exports and reports conversion timing stages.
    - `WebPreviewClient.exportIrCleanedRgb16` now sends the original RGB16/IR
      buffers to the worker for alignment instead of materializing full-page
      f32 RGB and IR buffers on the caller side.
    - Direct `zig build wasm-webapp-shell-smoke wasm-worker-runtime-smoke --summary all`
      passed. The shell smoke verifies worker-side raw `u16` RGB conversion
      produces a translation estimate within `0.05 px` of the f32 fixture path.
  - [x] Move IR-clean RGB and aligned-IR frame crop preparation out of
    `WebPreviewClient.exportIrCleanedRgb16`.
    - Completed 2026-05-23: added `process-ir-clean-crop` /
      `ir-clean-crop-result`. The worker crops the full RGB16 page and aligned
      f32 IR page to the selected frame, returning both buffers with
      `worker.crop-ir-clean-rgb16` and `worker.crop-ir-clean-ir-f32` timings.
    - `WebPreviewClient.exportIrCleanedRgb16` now derives the downstream
      intermediate file identity from the complete crop cache key instead of
      concatenating and hashing cropped RGB/IR buffers on the caller side.
  - [x] Decide whether the remaining async sequencing should become one
    worker-owned `process-ir-clean-export` operation or a worker-owned resident
    image session before checking this item off.
    - Decision 2026-05-23: keep the browser IR-clean export as explicit async
      worker stages for now. The remaining `app_core.mjs` work is request
      sequencing and metadata assembly, while full-page conversion, selected
      RGB/IR crop, grain-noise generation, mask generation, mask resize,
      inpaint, and inversion all execute in the worker/Wasm path. A monolithic
      `process-ir-clean-export` or resident worker image session remains a
      future optimization only if benchmarks show message transfer or repeated
      staging dominates.
    - Direct `zig build wasm-worker-protocol-smoke wasm-worker-runtime-smoke wasm-webapp-shell-smoke --summary all`
      passed after this split.

- [x] Make wasm64 the default browser processing target.
  - Scope:
    - Treat support for image workflows whose resident working set can exceed
      4 GiB as a browser architecture requirement, not as a native-only escape
      hatch.
    - Make the normal `wasm-core`, `wasm-core-smoke`, and `wasm-webapp` build
      paths emit/load `wasm64-freestanding`.
    - Retain `wasm32` only if it remains a trivial optional artifact using the
      same source and worker ABI layer.
    - Update the JS worker and direct Node harness so exported `usize`
      pointers and lengths are passed as `BigInt` for wasm64 and as `Number`
      for wasm32.
    - Do not pretend wasm64 alone solves all large-scan memory problems:
      tiled/streaming TIFF decode, processing, and export remain required
      follow-up work.
  - Completed 2026-05-24:
    - Changed `wasm-core` to target `wasm64-freestanding`.
    - Added optional `wasm32-core` and `wasm32-core-smoke` compatibility steps.
    - Added `v600_wasm_pointer_bits()` to the Wasm ABI and reports
      `pointer_bits` in worker capabilities and smoke JSON.
    - Replaced the worker/direct-smoke signed `>>> 0` allocation normalization
      with pointer-width-aware `usize`/pointer conversion helpers and safe
      JS byte-offset checks.
    - `wasm-webapp` now stages the default wasm64 artifact as
      `zig-out/webapp/v600-wasm-core.wasm`.
  - Validation 2026-05-24:
    - `zig build wasm-core-smoke --summary all` passed and reported
      `pointer_bits=64`.
    - `zig build wasm32-core-smoke --summary all` passed and reported
      `pointer_bits=32`.
    - `zig build wasm-worker-runtime-smoke wasm-webapp-shell-smoke wasm-webapp-static-smoke wasm-webapp --summary all`
      passed against the default wasm64 webapp artifact.
  - Follow-up:
    - Add a tiled/streaming large-scan plan for browser TIFF decode,
      IR-cleaning intermediates, and export writing so Memory64 is used to
      remove the address ceiling, not to justify retaining every intermediate
      full image in memory.

- [x] Pre-commit review pass for the Phase 13 working tree.
  - Scope:
    - Review all uncommitted Phase 13 sources before the first browser/Wasm
      commit and fix anything commit-gating; leave structural refactors to the
      recorded maintenance plan.
  - Completed 2026-07-03:
    - Fixed `EccWork.init` in `src/wasm/core.zig` to `errdefer`-free earlier
      buffers on partial allocation failure so a mid-init OOM cannot leak in
      the long-lived worker Wasm instance.
    - Bounded `ecc_scale` to `(finite, 0.0..1.0]` in
      `validateIrEstimateRequest`; the unbounded value could overflow the
      `@intFromFloat` small-dimension computation in the ReleaseFast Wasm
      artifact where safety traps are disabled.
    - Stopped gitignoring committed test fixtures: root-anchored the
      `frames/` processing-output rule and added `!test/fixtures/**/*.tiff`
      and `!test/fixtures/**/*.tif` negations. Before this fix
      `test/fixtures/processing/frames/` (29 files) and
      `test/fixtures/tiff/*.tiff` existed only locally, so fixture-backed
      frame-detector, TIFF, and browser smoke tests would fail on a fresh
      clone.
  - Validation 2026-07-03:
    - `zig build test --summary all` passed `602/614` with 12 expected skips.
    - `zig build --summary all` and `zig build -Dui=true --summary all`
      passed.
    - `zig build wasm-core-smoke wasm32-core-smoke wasm-worker-protocol-smoke
      wasm-worker-runtime-smoke wasm-webapp-shell-smoke wasm-tiff-reader-smoke
      wasm-webapp-static-smoke wasm-webapp --summary all` passed.
    - `git diff --check` passed.

### Phase 14: Code Maintenance, Tidying, And Refactoring

This phase is behavior-preserving cleanup recorded after the Phase 13
pre-commit review. Parity fixtures and final outputs must not change. Every
step lands as its own commit gated by the standard validation suite:
`zig fmt --check` on touched Zig files, `zig build test --summary all`,
`zig build --summary all`, `zig build -Dui=true --summary all`, the full
`wasm-*` smoke suite, and `git diff --check`. Prefer pure code moves before
rewrites; do not combine a move and a behavior change in one commit.

- [x] 14.1 Low-risk hygiene pass.
  - Delete dead `rgb16ArrayBufferToF32` in `web/app_core.mjs`.
  - Move the test-only demo fixture exports (`rawFixture`,
    `expectedDemoPreview`, `demoRawRgb16Buffer`) out of `web/app_core.mjs`
    into a test-side helper; keep the static-smoke assertion that the app
    does not reference them.
  - Decide the unreachable legacy preview-download surface in
    `web/app_core.mjs` (`rgb16ToPpmBytes`, `rgb8ToPpmBytes`,
    `exportFileStem`, `previewPpmFilename`, `previewMetadataFilename`,
    `buildPreviewExportMetadata`, client `makeIrMaskU8`,
    `inpaintBiharmonicRgb16`): delete, or keep as covered public API with a
    recorded reason. Default is delete; tests covering deleted surface go
    with it.
  - Replace the raw preview cache-key `setStatus` in `web/app.mjs` with
    human-readable status text.
  - Bound `padding` and `grain_padding` in `validateIrInpaintGrainRequest`
    (`src/wasm/core.zig`) so `usize -> i32` casts and the ellipse-span
    radius math cannot overflow in the ReleaseFast Wasm artifact.
  - Add source comments recording that `openCvEllipseSpans` intentionally
    differs from `ir.zig` `ellipseKernelRowSpans` for radius >= 2 (OpenCV
    ellipse vs skimage disk) and that `frameFormatById` accepts 0 as the
    35mm default while JS ids start at 1.
  - Map `error.Overflow` in `statusFromError` to `invalid_dimensions`
    instead of the generic processing error.
  - Raise or scale the fixed 5s per-message timeout in
    `test/wasm/worker_runtime_smoke.mjs` (grain inpaint step can flake on
    slow machines).
  - Document `test/wasm/real_scan_ir_estimate_probe.mjs` as a manual
    diagnostic tool (not a build-step test) where the other harnesses are
    described.
  - Refresh `README.md`: present the Zig native app and the browser webapp
    as the products, the Python tree as the frozen behavior oracle, and the
    current build/run entrypoints.
  - Completed 2026-07-03:
    - Deleted the unreachable browser preview-download surface from
      `web/app_core.mjs` (`rgb16ToPpmBytes`, `rgb8ToPpmBytes`,
      `exportFileStem`, `previewPpmFilename`, `previewMetadataFilename`,
      `buildPreviewExportMetadata`, plus the private
      `frameTagForFilename`/`numberTag` helpers), the dead
      `rgb16ArrayBufferToF32`, the orphaned `defaultIrInpaintOptions`, and
      the `WebPreviewClient.makeIrMaskU8`/`inpaintBiharmonicRgb16` client
      methods that the composed export path never calls. Worker-level
      `process-ir-mask` and `biharmonic-no-grain` coverage remains in
      `test/wasm/worker_runtime_smoke.mjs`; the shell smoke's RGB-mask
      resize section now feeds the known one-pixel mask directly.
    - Moved the 2x2 demo fixture out of the shipped app module into
      `test/wasm/demo_fixture.mjs`; the static smoke's
      "app does not reference demo data" assertion still holds.
    - Replaced the raw preview cache-key `setStatus` in `web/app.mjs` with
      "Preview ready".
    - Bounded `padding`/`grain_padding` at `max_ir_inpaint_padding = 4096`
      in `validateIrInpaintGrainRequest`, mapped checked-multiply
      `error.Overflow` to the `invalid_dimensions` status, and recorded the
      OpenCV-vs-skimage ellipse divergence and the `frameFormatById` zero
      default in source comments.
    - Raised the worker runtime smoke per-message timeout from 5s to 30s.
    - Documented `test/wasm/real_scan_ir_estimate_probe.mjs` as a manual
      diagnostic in `docs/WEBAPP_PORT_PLAN.md` and corrected that doc's
      stale PPM-download claims.
    - Refreshed `README.md` from the Python-era description to the Zig
      CLI/native UI/browser webapp with accurate entrypoints, the platform
      support summary, and the Python tree as frozen oracle.
    - Recorded the surface removal in `docs/PARITY_MANIFEST.md` as the
      "Phase 14 Browser hygiene pass" row.
  - Validation 2026-07-03:
    - `zig fmt --check src/wasm/core.zig` passed.
    - `zig build test --summary all` passed `602/614` with 12 expected
      skips.
    - `zig build wasm-core-smoke wasm32-core-smoke
      wasm-worker-protocol-smoke wasm-worker-runtime-smoke
      wasm-webapp-shell-smoke wasm-tiff-reader-smoke
      wasm-webapp-static-smoke wasm-webapp --summary all` passed 20/20
      steps with all smoke events `status=ok`.
    - `zig build --summary all` and `zig build -Dui=true --summary all`
      passed.
    - `node --check` passed on every touched `.mjs` file and
      `git diff --check` passed.

- [x] 14.2 Shared-core consolidation (Zig) per the Shared-Core Policy in
  `docs/WEBAPP_PORT_PLAN.md`.
  - Make the private `src/processing/ir.zig` helpers `pub` and delete their
    verbatim copies in `src/wasm/core.zig` (~200 lines):
    `resizeNearestMaskU8`, `addClampedLimit`, `roundF32`,
    `labelMaskComponents8`, reflect/bilinear samplers, apply-translation,
    and the mask resize+dilate geometry branch.
  - Move the pure-Zig ports of the native C/C++ helpers out of
    `src/wasm/core.zig` (~750 lines) into `src/processing/` (candidate
    module `ir_pure.zig`, or split `grain.zig`/`ecc.zig`): local grain
    estimate/spectrum, grain synthesis, translation-ECC stack, small DFT
    pair, `areaResizeU8`, `gaussianBlur5Reflect101`,
    `dilateMaskOpenCvEllipse`.
  - Rewire the `!use_native_ir_helpers` fallbacks in `ir.zig` to call the
    pure ports instead of returning failing no-op stubs; native libc builds
    keep the extern OpenCV/SuperLU path unchanged. Then collapse
    `inpaintGrainRgb16WithNoise` into the shared grain-from-noise inpaint
    with a `uint16` value-kind, removing the re-orchestrated copy.
  - Add Zig-level fixture tests for the moved code (grain estimate, grain
    synthesis, ECC estimate, apply-translation) plus `detectFramesRgb16`
    coverage so native-vs-wasm parity does not live only in Node smokes.
  - Reduce the triple ABI declaration between `src/wasm_core.zig` and
    `src/wasm/core.zig` with a comptime export loop or generated status
    wrappers, keeping the extern struct layouts explicit.
  - Consolidate the repeated `!builtin.cpu.arch.isWasm() and
    worker_count > 1` guards in `src/processing/frames.zig`, `ir.zig`, and
    `render.zig`: worker-count helpers already return 1 on Wasm, so the
    architecture check should live in one choke point.
  - Update the `docs/WEBAPP_PORT_PLAN.md` reuse map, which currently claims
    IR mask-resize, grain, and translation-ECC are shared while they are
    facade reimplementations until this step lands.
  - Completed 2026-07-03 across commits `a19da32`, `45b2b39`, `375df1e`,
    `db26958`, `7d7aeb0`, and `40acf06`:
    - Published `ir.zig` helpers (`labelMaskComponents8`, `MaskComponent`,
      `addClampedLimit`, `roundF32`, `resizeNearestMask`, `reflectIndex`,
      genericized `sampleReflectNearest`/`sampleReflectBilinear`/
      `applyTranslation`, and a new `resizeMaskToRgb` extracted from the
      `irCleanRegion` mask-geometry branch) and deleted the verbatim copies
      in `src/wasm/core.zig`.
    - Moved the pure OpenCV-behavior ports (grain estimate/spectrum/
      synthesis, translation-ECC stack, small DFT pair, area resize, 5x5
      Gaussian, OpenCV-ellipse dilate) into `src/processing/ir_pure.zig`
      with `estimateTranslationEccF32` as the plain-typed entry.
    - Rewired the `!use_native_ir_helpers` paths in `ir.zig` to call the
      pure ports instead of failing no-op stubs (`alignIr` now estimates
      with pure ECC on no-libc builds; grain estimate/synthesis dispatch to
      `ir_pure`; `synthesizeGrainFromNoise` gained an allocator parameter).
      SuperLU keeps its failing stub because `biharmonicInpaint` already
      falls back to the pure iterative solver.
    - Collapsed the Wasm `inpaintGrainRgb16WithNoise` re-orchestration into
      the shared `inpaintBiharmonicWithGrainFromNoise` uint16 value-kind
      path; the browser smoke still replays the uint16 grain fixture with
      `ir_grain_inpaint_max_abs=0`.
    - Un-skipped the formerly OpenCV-gated no-libc fixture tests: grain
      estimate, grain synthesis, python-inpaint, and ir-clean fixtures now
      replay exactly against the pure ports; the two alignment fixtures
      assert the pure ECC offset within the accepted `0.05 px` envelope and
      pin the aligned-output envelope (`max_abs <= 150`, `rms <= 45`;
      measured `141.42`/`41.32`, matching the recorded browser evidence).
      Added a native synthetic 35mm detector test mirroring the worker
      smoke scenario (`frame_count_override=3`, film-extent and CLAHE off).
    - Replaced the hand-written `src/wasm_core.zig` export shim with a
      comptime `@export` loop over the C-callconv core ABI functions.
    - Consolidated the scattered `!builtin.cpu.arch.isWasm()` thread guards
      behind `src/processing/parallelism.zig` `enabled`, dropping the
      redundant nested arch checks while preserving comptime branch
      elimination for freestanding Wasm; libc-specific guards
      (`use_native_ir_helpers`, `monotonicNowNs`) intentionally remain
      direct.
    - Refreshed the `docs/WEBAPP_PORT_PLAN.md` reuse map and recorded the
      consolidation as a `docs/PARITY_MANIFEST.md` Phase 14 row.
  - Validation 2026-07-03 (every commit in the series):
    - `zig build test --summary all` finished at `611/615` passed with 4
      expected skips (libtiff-gated scan-parity tests) and zero failures,
      up from `602/614` with 12 skips.
    - `zig build wasm-core-smoke wasm32-core-smoke
      wasm-worker-protocol-smoke wasm-worker-runtime-smoke
      wasm-webapp-shell-smoke wasm-tiff-reader-smoke
      wasm-webapp-static-smoke wasm-webapp --summary all` passed 20/20 with
      byte-identical smoke outputs before and after every step
      (`ir_estimate_tx=9.883345603942871`, `ir_grain_inpaint_max_abs=0`,
      `ir_alignment_max_abs=0.0037903999982518144`).
    - `zig build --summary all` and `zig build -Dui=true --summary all`
      passed; `zig fmt --check` and `git diff --check` passed.

- [ ] 14.3 Browser JS structure.
  - Split `web/app_core.mjs` (2621 lines, ~6 concerns) into focused
    modules: geometry/crop math, cache-input builders, export pipeline
    orchestration, `WebPreviewClient`, and shared utils.
  - Collapse the ~10 near-identical `WebPreviewClient` request methods into
    one generic request helper (~500 lines).
  - Replace the longhand message/cache-key trios in
    `web/worker/protocol.mjs` with an operation registry (~300 lines).
  - Extract a `wasm_abi.mjs` (alloc/free/call/pointer-width/byte-offset
    helpers plus options-struct writers) used by both
    `web/worker/processor.mjs` and `test/wasm/wasm_core_smoke.mjs`; the
    struct byte layouts are currently maintained twice and can drift.
  - Dedupe `isNodeRuntime`/`scalarArrayType` and add
    `test/wasm/helpers.mjs` for the triplicated fixture builders.
  - Add the Shared-Core Policy contract tests that are missing: JS
    `computeDminFromRgb16` against the native dmin percentile fixture, and
    JS cache-key canonicalization against the native contract. Record the
    grain-noise determinism contract (seeded RNG, Box-Muller, flood-fill
    noise sizing) as lockstep-critical with the native inpaint padding.

- [ ] 14.4 Native structural splits (appetite-dependent; pure moves only).
  - `build.zig`: factor the repeated C/C++ object-compilation blocks into a
    helper and make smoke/bench step registration table-driven (native UI
    smokes, the eight `wasm-*` steps, WebGPU step pairs).
  - `src/ui/main.zig` (5443 lines): extract worker lifecycle, event
    dispatch, and render passes into modules.
  - `src/processing/frames.zig` (6266 lines): separate film-format tables
    from detection algorithms from rotation/CLAHE helpers.
  - `src/processing/ir.zig` (5219 lines): after 14.2, isolate the extern-C
    boundary and fallback wiring into a small module.
  - Leave `src/benchmarks/` and `src/tools/` as-is; they are intentional
    build-step executables.
