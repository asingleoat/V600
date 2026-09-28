# Cross-Platform Support

What runs where, and what each missing platform needs.

## Support matrix

| Platform | Scanner | Processing CLI | Native UI | Packaging |
| --- | --- | --- | --- | --- |
| Linux | SANE via patched epkowa; exercised on a V600 | Yes | SDL3/Nuklear | `packages.cli`, `packages.ui` |
| macOS | Paused. Protocol code replay-tested only; no USB transport | Untested | Untested | Flake systems listed, never built on a Mac |
| Windows | Not planned | Not wired | Not wired | Not wired |
| Browser | Through the Linux companion (`v600-zig serve`) only | Webapp (Wasm); checked in Chrome and Chromium | Browser UI in `web/` | `zig build wasm-webapp` |

Linux hardware steps run only with `V600_HARDWARE_SMOKE=1`. See
`docs/WEBAPP.md` for the browser app and `docs/SCANNER_COMPANION.md` for the
companion.

## Constraints for every platform

- Zig 0.16.0. Native dependencies (libtiff, libjpeg, OpenCV, SuperLU, SDL3,
  Nuklear, optional `wgpu-native`) come from Nix; no other package managers.
- No default build or check path may require WebGPU or scanner hardware.
- GPU acceleration targets WebGPU through nixpkgs `wgpu-native`, behind a
  backend boundary that could later use Google Dawn. CPU stays the default.

## macOS

Paused since 2026-05-23 until work resumes on macOS hardware. This section
is the checklist for when it does.

What exists: `src/scanner/macos.zig` and `src/scanner/interpreter.zig`
implement interpreter search paths, Epson bundle symbol binding, USB
callbacks, RS/register writes, command ACKs, identity and status reads,
FS W parameter upload, IR challenge enablement, gamma upload, TPU calibration,
FS I capability parsing, scan parameter planning, model selection, endpoint
selection, and FS G scan start. All of it is tested against fakes only.

What is missing:

- Runtime bundle loading, USB device open/claim, interface and endpoint
  binding, and the live scan runtime. The CLI refuses the interpreter
  backend until these exist.
- A decision on `ensure_interpreter`: whether the app should ever download,
  mount, or cache Epson's proprietary ICA driver. Today only a manual
  readiness check exists.

Constraints:

- Build per architecture (`aarch64-darwin`, `x86_64-darwin`); universal
  binaries are not needed. Use the Apple SDK from the Nix stdenv. Linux
  cross-compilation does not count as macOS verification.
- The Epson Interpreter bundle is proprietary and host-installed; never
  vendor it. Load it at runtime from:
  `/Library/Image Capture/Devices/EPSON Scanner.app/Contents/PlugIns/Interpreter A1.bundle/Contents/MacOS/Interpreter A1`
  or
  `/Library/Image Capture/Support/EPSON/Epson Scan 2/Models/ES00A1/Interpreter A1.bundle/Contents/MacOS/Interpreter A1`.
- Epson Scanner Monitor or another vendor service may claim the USB device;
  stop it before live tests.
- WebGPU on macOS would use Metal through optional packaging, never required
  for the CPU build.

Bring-up sequence on a Mac:

```sh
zig version                                   # 0.16.0
zig build test --summary all
zig build --summary all
zig build -Dui=true --summary all
zig build scanner-smoke-skip scanner-processing-smoke-skip macos-scanner-smoke-skip
zig build -Dui=true native-preview-worker-smoke-skip native-scan-worker-smoke-skip
```

Then, with the scanner attached and the gaps above closed: confirm the V600
is visible on USB and the bundle path resolves, run a gated identity probe,
then the smallest RGB TPU scan and the smallest IR scan. Record host
architecture, macOS version, interpreter path, and any services that had to
be stopped.

## Windows

Not planned as a scanner target. A Windows build would be for the native UI
and processing over existing TIFFs, and needs:

1. A Windows target in the flake or a Nix-supported cross build for the C
   dependencies.
2. Scanner runtime selection that does not instantiate the Linux SANE
   runtime; scanner commands report unsupported.
3. A review of path handling, temp files, delete/trash, and config paths for
   Windows semantics.
4. A real Windows host or CI run before calling it supported.

## Browser

The webapp processes scan files in WebAssembly and scans only through the
companion running on a Linux host. It has been checked by hand in headless
Chrome 145 and Chromium 129 (wasm32 fallback); Firefox and Safari are
untried.
Details and known gaps: `docs/WEBAPP.md`. Direct browser scanner control
(WebUSB) is a research idea only.
