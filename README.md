# V600

Scanning and film processing for the Epson V600 and related scanners.
Drives the hardware for 16-bit RGB and infrared acquisition via
transparency unit, then processes the scans: automatic frame detection,
IR-based dust/scratch removal, calibrated negative inversion with
per-stock color profiles.

The application is written in Zig: a scanner and processing CLI
(`v600-zig`), a native SDL3/Nuklear UI (`v600-ui`), and a browser
WebAssembly processing webapp built from the same processing core.
The original Python implementation stays in-tree as the frozen
behavior oracle for the port; `docs/PARITY_MANIFEST.md` tracks the
function-by-function parity evidence.

## Getting started

Requires [Nix](https://nixos.org/download/).

    git clone <repo> && cd V600
    nix develop                        # or nix-shell
    zig build -Dui=true run-ui         # native scan/process/gallery UI
    zig build run -- scanner devices   # or drive the CLI directly

Browser processing webapp (processes existing scan TIFFs; no scanner
control in the browser):

    zig build wasm-webapp
    python3 -m http.server 8433 --bind 127.0.0.1 --directory zig-out/webapp

then open `http://127.0.0.1:8433/`.

## Platform support

Linux is fully supported: scanner through the patched epkowa SANE
backend, processing CLI, and native UI, all live-tested on V600
hardware. macOS support is paused until the interpreter USB runtime is
wired (replay-tested only). The browser webapp covers processing on any
platform with a modern browser. See `docs/CROSS_PLATFORM.md` for the
full matrix.

## Scanner setup (Linux)

Install the NixOS module from `nixos/v600-scanner.nix` for udev
rules and the patched epkowa SANE backend. See `nixos/README.md`.

## Usage

    zig build --summary all             # build the CLI (zig-out/bin/v600-zig)
    zig build -Dui=true --summary all   # build the native UI (zig-out/bin/v600-ui)
    zig build test --summary all        # unit + fixture tests

    v600-zig scanner devices                          # list SANE devices
    v600-zig scanner scan --out scans/scan.tiff \
        --source tpu --kind rgb+ir --dpi 3200         # real scanner pass
    v600-zig processing detect --input scans/scan.tiff
    v600-zig processing export --input scans/scan.tiff \
        --frame CX,CY,W,H[,ANGLE_DEG]                 # inverted/IR-cleaned TIFFs

Scans go to `scans/`, processed frames to `frames/`. Hardware smoke
steps are opt-in via `V600_HARDWARE_SMOKE=1` and never run implicitly.

## Project layout

    build.zig               build, test, smoke, benchmark, and webapp steps
    src/
      main.zig              CLI entry point
      scanner/              SANE (Linux) and future macOS interpreter backends
      processing/           frame detection, inversion, IR cleaning, render, export
      ui/                   SDL3/Nuklear native UI, workers, process cache
      wasm/                 browser WebAssembly processing core (shared algorithms)
    web/                    browser webapp shell, worker, protocol, TIFF I/O
    test/
      fixtures/             committed parity fixtures (Python-oracle outputs)
      wasm/                 Node harnesses for the Wasm core, worker, and webapp
    scanner.py, scan.py, v600/, scratchndent/
                            frozen Python reference implementation (oracle)

## Documentation

- [Cross-platform plan](docs/CROSS_PLATFORM.md) — platform support
  matrix, macOS/Windows/browser build plans, release checklist
- [Parity manifest](docs/PARITY_MANIFEST.md) — Python-to-Zig parity
  evidence, validation gates
- [Webapp port plan](docs/WEBAPP_PORT_PLAN.md) — browser distribution
  scope, shared-core policy, worker/WebGPU strategy
- [Scanner internals](docs/SCANNER_INTERNALS.md) — ESC/I protocol,
  interpreter ABI, USB packet format, TPU calibration, IR
  challenge-response, gamma LUT protocol, epkowa/epson2 patches
- [Film stock profiles](docs/FILM_STOCK_PROFILES.md) — polynomial
  calibration format, built-in presets, how to create custom profiles
- [NixOS setup](nixos/README.md) — hardware configuration, patched
  epkowa backend
