# V600 Zig Rewrite Plan

This project is moving from a mature Python version one implementation to a
function-by-function Zig rewrite. The Python code is now the frozen behavior
oracle. The rewrite succeeds only when the Zig implementation reaches full
behavior parity for scanner operation, processing, export, configuration, and
UI workflows.

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
12. Keep changes scoped. Avoid unrelated refactors, formatting churn, and broad
   rewrites unless the current checklist item requires them.
13. Prefer headless tests and replay fixtures first; run hardware and GUI tests
   only when the environment actually supports them.
14. Avoid redundant Nix evaluations. Assume the conversation is already running
    inside the ambient project nix shell. For ordinary code/test checkpoints,
    build only with direct `zig ...` commands and Zig's local build graph. Do
    not wrap normal builds, tests, UI smokes, scanner commands, or formatting
    in `nix develop`, `nix-shell`, `nix build`, or `nix flake check` unless the
    current checklist item explicitly changes Nix/dependency/package wiring or
    the user explicitly asks for a Nix command.
15. If a new dependency, changed dependency, missing native library, stale Zig
    version, or other shell-environment problem means the ambient nix shell is
    no longer sufficient, stop and ask the human to update or re-open the nix
    shell. Do not run Nix commands to repair or refresh the environment
    yourself.
16. Treat items marked `PENDING USER UPDATE` as parked external blockers, not
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
- Linux IR scans should route through `scanimage-v600-ir` when available, or
  fall back to `scanimage` with `SCAN_IR_MODE=1`.
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

- [ ] Re-benchmark preview after f32 density LUT adoption and select the next
      hotspot.
  - Current expectation: first-use inverted preview is now roughly split between
    f32 density-LUT inversion (`74063 us` including LUT build) and display
    rendering/range work (full preview `146687 us`).
  - Before changing algorithms, add or run a benchmark that reports the current
    f32 inversion, f32 render range/LUT, and output write costs in one command.

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

- [ ] Refresh Linux live scanner release smoke evidence.
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

- [ ] Refresh Linux Nix package and no-hardware check gates.
  - Covers release checklist items 7 and 8.
  - Required commands:
    - `nix build path:.#cli path:.#ui --no-link --print-build-logs`
    - `nix build path:.#checks.x86_64-linux.zig-tests --no-link --print-build-logs`
  - Blocked 2026-05-18: the user explicitly directed agents to avoid redundant
    Nix evaluations and to rely on the ambient shell for ordinary work. Do not
    run these release gates until the user explicitly authorizes release-time
    Nix validation or asks for a packaging refresh.

- [ ] Record macOS direct build/test evidence on a macOS host.
  - Covers release checklist item 10.
  - Blocked 2026-05-18: current machine is Linux. This remains parked under the
    `PENDING USER UPDATE` macOS policy until the user says a macOS host is
    available.

- [x] Keep macOS live scanner support explicitly deferred from the release claim.
  - Covers release checklist item 11 for the current Linux-hosted audit.
  - Evidence: `docs/CROSS_PLATFORM.md` records macOS scanner support as planned
    through Epson Interpreter, replay-tested only, with live build/scanner
    validation pending. The parked `PENDING USER UPDATE: Add live macOS scanner
    smoke tests` item in this plan requires a macOS scanner host and Epson
    Interpreter bundle before live scanner support can be claimed.
  - Completion decision: checked only as an explicit deferral, not as live
    macOS scanner support.

- [ ] Record native UI real-display screenshot verification.
  - Covers release checklist item 12.
  - Required workflows: scan, process, gallery, confirmation, and pan/zoom.
  - Use `docs/NATIVE_UI_VERIFICATION.md` as the checklist. Headless SDL dummy
    smokes are useful but not sufficient for this release item.
  - Required evidence before checking off: date, display environment, command,
    screenshot paths, viewport/window sizes, and visual defects or explicit
    "no defect observed" notes.

- [ ] Final parity manifest and generated-output hygiene audit.
  - Covers release checklist items 1, 2, and 15 after all other Phase 12 work.
  - Required checks:
    - every selectable `plan.md` item is checked or has a user-approved release
      deferral/blocker;
    - every applicable `docs/PARITY_MANIFEST.md` row is `parity-accepted` or
      has an explicit release-approved deferred/blocker reason;
    - `git status --short` contains only intended source/docs/fixture changes,
      not generated scans, frames, configs, TIFF/PNG/JPEG outputs, or temporary
      smoke files.
  - Completion decision: leave unchecked until all unblocked Phase 12 evidence
    has been refreshed.
