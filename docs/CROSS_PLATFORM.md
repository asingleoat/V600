# Cross-Platform Build And Release Plan

This document records the platform constraints for the Zig rewrite. It is a
planning and verification checklist, not a claim that every platform is already
live-tested.

## Global Invariants

- Target Zig is 0.16.0.
- Use the ambient project nix shell for ordinary development commands. Do not
  re-enter Nix for normal Zig build/test iterations.
- Nix owns native dependencies. Do not add pip, npm, vcpkg manifests, or ad hoc
  install instructions without an explicit project decision.
- Linux is the only platform with current live scanner evidence.
- macOS scanner work must be replay-tested on Linux first, then live-tested on
  macOS with the scanner attached.
- Windows is a UI and processing target only until a scanner backend is
  explicitly designed.
- The native UI target is SDL3 plus Nuklear. Future GPU acceleration targets
  WebGPU through nixpkgs `wgpu-native` first, with CPU fallback preserved and a
  backend boundary that can support Google Dawn later if needed.
- Browser distribution is planned as a processing webapp first: a narrow
  Zig/Wasm processing core plus a browser-native UI shell and Web Worker
  runtime. Direct browser scanner control is not a version-one web target, and
  SDL3/Nuklear through Emscripten is a research spike rather than the first
  shipping path. See `docs/WEBAPP_PORT_PLAN.md`.

## macOS Build Plan And SDK Constraints

macOS work is officially paused as of 2026-05-23 by user direction. Keep this
section as the reopening checklist for a future macOS hardware session, but do
not select macOS-only build, SDK, bundle, USB, or scanner validation work in the
autonomous loop until the user explicitly reopens it.

Supported flake systems are `aarch64-darwin` and `x86_64-darwin`. Validate them
on real macOS hosts; do not treat Linux cross-compilation as macOS proof because
the Apple SDK, SDL windowing, dynamic bundle loading, and USB behavior all need
host validation.

Build sequence on macOS:

1. Enter or reload the project shell from the flake on the macOS host.
2. Verify `zig version` reports `0.16.0`.
3. Run `zig build test --summary all`.
4. Run `zig build --summary all`.
5. Run `zig build -Dui=true --summary all`.
6. Run the no-hardware smoke skips:
   `zig build scanner-smoke-skip scanner-processing-smoke-skip --summary all`
   and
   `zig build -Dui=true native-preview-worker-smoke-skip native-scan-worker-smoke-skip --summary all`.
7. Package only after direct Zig gates pass:
   `nix build path:.#cli path:.#ui --no-link --print-build-logs`.

SDK and dependency constraints:

- Use nixpkgs unstable with Zig 0.16.0, SDL3, libtiff, libjpeg, OpenCV, SuperLU,
  and the local Nuklear header package.
- Rely on the Apple SDK supplied by the active Nix stdenv. Do not add a second
  SDK discovery path in `build.zig`.
- Build per architecture. Universal binaries are not required for version one.
- The Epson Interpreter bundle is proprietary and host-installed. Do not vendor
  or copy it into the repo or Nix store by default.
- Dynamic loading of the Epson bundle must happen at runtime from documented
  search paths, including:
  `/Library/Image Capture/Devices/EPSON Scanner.app/Contents/PlugIns/Interpreter A1.bundle/Contents/MacOS/Interpreter A1`
  and
  `/Library/Image Capture/Support/EPSON/Epson Scan 2/Models/ES00A1/Interpreter A1.bundle/Contents/MacOS/Interpreter A1`.
- If Epson Scanner Monitor or another vendor service claims the USB device,
  stop it before live scanner validation.
- Future WebGPU work on macOS must use the Metal backend through optional
  native WebGPU packaging. Do not make Metal/WebGPU required for the CPU UI
  build.

Current macOS scanner gaps:

- `src/scanner/macos.zig` contains replay-tested interpreter path generation,
  `find_interpreter` filesystem probing, interpreter callbacks, direct
  RS/register-write, interpreter command ACKs, identity/status reads, write-only
  setup commands, FS W parameter upload, IR challenge enablement, gamma upload,
  TPU calibration shell, FS I capability conversion, pre-hardware scan
  parameter planning, Python scanner model table/fallback selection,
  first OUT/first IN endpoint selection, Epson bundle symbol binding, and
  scanner data block reading. It also contains a replay-tested FS G
  start-extended-scan exchange against a fake interpreter.
- Runtime bundle loading, USB device open/claim, interface/endpoint binding,
  and full macOS scanner runtime execution remain to be completed. The CLI now
  has an explicit host backend switch, but the interpreter branch intentionally
  returns unsupported until the live macOS runtime exists.
- `ensure_interpreter` download/extract behavior is policy-blocked until a
  human decides whether Zig should ever fetch, mount, extract, or cache the
  proprietary Epson ICA driver automatically. A manual-only readiness helper is
  replay-tested: it can report a found interpreter, missing manual install, or
  unsupported Linux host without downloading anything.
- `src/main.zig` dispatches scanner CLI commands through the host backend
  selector. macOS scanner CLI smoke cannot be considered live until the
  interpreter branch is wired to bundle loading and USB endpoints.
- `scanner macos-smoke` is present as a future live-smoke entrypoint. Without
  `V600_MACOS_HARDWARE_SMOKE=1` it skips without touching hardware; with the
  gate enabled on Linux it refuses with `UnsupportedPlatform` before touching
  hardware; with the gate enabled on macOS it currently reports unsupported
  until the interpreter runtime is wired.

Live macOS scanner validation, once the gaps above are closed:

1. Confirm the V600 is attached and visible to the macOS USB stack.
2. Confirm the Interpreter A1 bundle path is discoverable.
3. Run replay tests first with `zig build test --summary all`.
4. Run a gated probe or identity command with `V600_HARDWARE_SMOKE=1`.
5. Run the smallest practical RGB TPU scan to `/tmp/v600-macos-rgb-smoke.tiff`.
6. Run the smallest practical IR scan to `/tmp/v600-macos-ir-smoke.tiff`.
7. Record command lines, host architecture, macOS version, interpreter path,
   output paths, TIFF metadata, and any Epson/USB services that had to be
   stopped.

## Windows Build Plan

Windows is a future native UI and processing target. It is not a scanner target
for version one.

Planned scope:

- Build the SDL3/Nuklear native UI.
- Run processing-only workflows over existing TIFFs.
- Run gallery browsing, export viewing, config parsing, numeric fixtures, and
  non-hardware tests.
- Keep scanner commands disabled or explicitly unsupported until a Windows
  scanner backend is designed and accepted.

Required work before Windows can be claimed:

1. Add a Windows target to the flake or document a Nix-supported cross-build
   path for the C dependencies.
2. Split scanner runtime selection so Windows builds do not instantiate the
   Linux SANE runtime.
3. Keep libtiff, libjpeg, OpenCV, SuperLU, SDL3, and Nuklear dependency wiring
   inside Nix or stop for an explicit dependency-policy decision.
4. Audit path handling, temporary-file naming, delete/trash behavior, and config
   paths for Windows semantics.
5. Add Windows CI or a real Windows host validation pass before calling the UI
   supported.
6. Add WebGPU D3D12 planning only after CPU UI and processing parity are
   stable.

Windows validation commands, once available:

- `zig build test --summary all`
- `zig build --summary all`
- `zig build -Dui=true --summary all`
- `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all`
- Native UI smoke on a Windows display host

## Browser/Wasm Distribution Plan

The browser target is a future processing distribution target, not a scanner
target. The accepted first product shape is:

- a Wasm-safe Zig processing core with no filesystem, scanner, native-thread,
  SDL, OpenCV, SuperLU, libtiff, libjpeg, or `wgpu-native` dependency in the
  first checkpoint;
- a browser-native UI shell that owns file pickers, canvas presentation,
  downloads, Web Worker lifecycle, cache keys, cancellation, and browser
  persistence;
- optional browser WebGPU through `navigator.gpu`, with CPU Wasm fallback and
  downloaded output comparisons before UI/export integration;
- native scanner control kept in the desktop app, or later exposed through a
  small local native companion if browser scanner workflows become a product
  requirement.

`docs/WEBAPP_PORT_PLAN.md` is the canonical roadmap. It records current native
portability blockers, product modes, build strategy, WebGPU adapter boundaries,
testing surfaces, and the first implementation checkpoint. Do not add
Emscripten, Node, Playwright, or browser package tooling without updating Nix
files and asking the human to reload the shell.

Current implementation checkpoint:

- `pre-wasm-checkpoint` tags the source immediately before browser/Wasm source
  work.
- `zig build wasm-core --summary all` builds
  `zig-out/bin/v600-wasm-core.wasm` from the default
  `wasm64-freestanding` processing core. `zig build wasm32-core-smoke` remains
  an optional compatibility check while it stays trivial.
- The first exported operation is
  `v600_preview_invert_u16_to_u8`, backed by explicit allocator/free exports
  and final `u8 RGB` preview output.
- `zig build wasm-core-smoke --summary all` loads the emitted Wasm module in
  Node, exercises the exported buffer ABI, validates final `u8 RGB` output, and
  checks invalid-dimension and invalid-stock errors.
- `docs/WEBAPP_WORKER_PROTOCOL.md`, `web/worker/protocol.mjs`, and
  `zig build wasm-worker-protocol-smoke --summary all` define and verify the
  first headless worker protocol, including full-state preview cache keys,
  cancellation, timing, error messages, and stale-result rejection.
- `web/worker/processor.mjs` and
  `zig build wasm-worker-runtime-smoke --summary all` run the first actual
  browser/Node-compatible Worker loop against the emitted Wasm core.
- `web/index.html` plus `web/app*.mjs` provide the first browser processing
  shell for raw RGB16 inputs, backed by the Wasm worker and verified by
  `zig build wasm-webapp-shell-smoke --summary all`.
- `web/tiff.mjs` adds the first browser scan-file import path for
  uncompressed classic TIFF RGB16 pages with optional IR page detection,
  verified by `zig build wasm-tiff-reader-smoke --summary all`.
- The browser shell currently supports render/Dmin/sample controls, TIFF
  import/export, native export variant naming, first-slice frame autodetect,
  multi-frame detected-frame selection, rotated RGB16/IR crops, export-all
  detected frames, and IR-cleaned `_ir`/`ir_inv` exports when TIFF IR pages are
  present. Large-scan crop/export benchmarking showed RGB crop is material, so
  RGB preview and inverted-export crop now run in the worker and report
  `worker.crop-rgb16`. IR-clean export now keeps full-page alignment
  conversion, selected RGB/IR crop preparation, grain-noise generation, mask
  generation, inpaint, and inversion in worker/Wasm stages; the browser caller
  owns async sequencing and metadata assembly.

## Platform Support Matrix

| Platform | Scanner | Processing CLI | Native UI | Packaging | Notes |
| --- | --- | --- | --- | --- | --- |
| Linux | Supported through SANE, live-tested on V600 | Supported | Supported through SDL3/Nuklear | `packages.cli`, `packages.ui` | Hardware smokes require `V600_HARDWARE_SMOKE=1`. |
| macOS | Paused until user reopens on macOS hardware; replay-tested only | Planned | Planned through SDL3/Nuklear | Flake systems listed, live build paused | Requires host Epson bundle and runtime USB binding work. |
| Windows | Not planned for version one | Planned | Planned through SDL3/Nuklear | Not wired | Scanner commands must stay unsupported until a backend exists. |
| Browser/Wasm | Local companion server (`v600-zig serve`) exposes the native scanner stack over loopback HTTP; browser-only WebUSB remains a recorded research track | Processing webapp implemented | Browser-native shell first; SDL3/Nuklear/Emscripten spike only | `zig build wasm-webapp` staging; companion serves it | Wasm core and browser WebGPU plan are documented in `docs/WEBAPP_PORT_PLAN.md`; the companion protocol in `docs/SCANNER_COMPANION.md`. |

## Release Checklist

Before declaring the Zig rewrite version-one replacement complete:

1. Every `plan.md` item is checked with evidence.
2. Every applicable row in `docs/PARITY_MANIFEST.md` is `parity-accepted` or
   has an explicit deferred/blocker reason approved for release.
3. `zig build test --summary all` passes from the ambient shell.
4. `zig build --summary all` passes from the ambient shell.
5. `zig build -Dui=true --summary all` passes from the ambient shell.
6. `zig build -Doptimize=ReleaseFast bench-gpu-readiness --summary all` passes.
7. Linux `nix build path:.#cli path:.#ui --no-link --print-build-logs` passes.
8. Linux `nix build path:.#checks.x86_64-linux.zig-tests --no-link --print-build-logs`
   passes without scanner hardware.
9. Linux live scanner smoke evidence is refreshed for RGB, IR, RGB+IR, metadata,
   LUT, preview worker, scan worker, and scanner-to-processing workflow.
10. macOS direct build/test evidence is recorded on a macOS host, or macOS is
    explicitly paused outside the current release claim until the user reopens
    the work on macOS hardware.
11. macOS live scanner evidence is recorded if macOS scanner support is included
    in the release claim; otherwise macOS scanner support remains explicitly
    deferred.
12. Native UI real-display screenshot verification is recorded for scan,
    process, gallery, confirmation, and pan/zoom workflows.
13. No default build path requires WebGPU.
14. No default check path requires scanner hardware.
15. `scratchndent_config.toml`, scanner config files, scans, frames, TIFF/PNG/JPEG
    outputs, and temporary smoke files remain untracked/generated outputs.
