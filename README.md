# CerealGrain

Scanning and film processing for the Epson V600 and related scanners.
Drives the hardware for 16-bit RGB and infrared acquisition via
transparency unit, then processes the scans: automatic frame detection,
IR-based dust/scratch removal, calibrated negative inversion with
per-stock color profiles.

The application is written in Zig: a scanner and processing CLI
(`cerealgrain`), a native SDL3/Nuklear UI (`cerealgrain-ui`), and a browser
WebAssembly processing webapp built from the same processing code. The
original Python implementation, a work in progress that drove the port,
stays in-tree for reference.

## Getting started

Requires [Nix](https://nixos.org/download/).

    git clone <repo> cerealgrain && cd cerealgrain
    nix develop                        # or nix-shell
    zig build -Dui=true run-ui         # native scan/process/gallery UI
    zig build run -- scanner devices   # or drive the CLI directly

Browser webapp, processing scan TIFFs you already have:

    zig build wasm-webapp
    python3 -m http.server 8433 --bind 127.0.0.1 --directory zig-out/webapp

then open `http://127.0.0.1:8433/`. To scan from the browser as well, serve
it with the scanner companion on the Linux machine the scanner is attached
to (see `docs/SCANNER_COMPANION.md`):

    zig build wasm-webapp && zig build run -- serve

## Platform support

- Linux: scanner through the patched epkowa SANE backend, processing CLI,
  and native UI. Scanning has been exercised on a V600.
- macOS: scanner through Epson's Interpreter bundle over libusb, with
  per-channel gamma LUTs fitted to the film; CLI and native UI. Scanning has
  been exercised on a V600 from Apple Silicon. `zig build app-bundle` makes a
  CerealGrain.app and a zip to share (Apple Silicon, macOS 14 or later).
- Other Epson film scanners (V550, V800/V850, V700/V750, V500, V370, V330,
  4990, 4870, 4490, GT-X970) are known but untested; see
  `docs/CROSS_PLATFORM.md`.
- Browser: checked in Chrome and Chromium (older browsers without Wasm
  memory64 get a wasm32 build). Scanning from it needs the companion on a
  Linux host.

See `docs/CROSS_PLATFORM.md`.

## Scanner setup (Linux)

Install the NixOS module from `nixos/v600-scanner.nix` for udev
rules and the patched epkowa SANE backend. See `nixos/README.md`.

## Usage

    zig build --summary all             # build the CLI (zig-out/bin/cerealgrain)
    zig build -Dui=true --summary all   # build the native UI (zig-out/bin/cerealgrain-ui)
    zig build test --summary all        # unit and fixture tests

    cerealgrain scanner devices                          # list scanners
    cerealgrain scanner preview                          # TPU preview; prints the film area
                                                      # and writes its LUTs (macOS)
    cerealgrain scanner scan --source tpu --kind rgb+ir --dpi 3200 \
        --x IN --y IN --width IN --height IN \
        [--lut-file scans/preview.tiff.lut.bin]       # scans/scan_NNNN_rgbir_3200dpi.tiff
    cerealgrain processing detect --input scans/scan.tiff  # frames, rebate, and its Dmin (saved)
    cerealgrain processing export --input scans/scan.tiff \
        --frame CX,CY,W,H[,ANGLE_DEG]                 # inverted/IR-cleaned TIFFs
    cerealgrain serve                                    # scanner companion for the webapp

Scanning a roll strip by strip (each strip: preview, film area, one LUT
for the whole roll, full scan; finished strips export in the background):

    cerealgrain roll start gold200-a --stock kodak_gold  # scans/gold200-a/, current roll
    cerealgrain roll scan                                # Enter per strip, q to finish
    cerealgrain roll status | export [--force] | review [--open]
    cerealgrain roll check-frames [--verified 1,2]       # detection vs frames placed by hand

Exports land in `frames/<roll>/<roll>_sNN_FF.tif` (strip NN, frame FF), and
`scans/<roll>/review/index.html` shows each strip with its detected frames.
Each export is the IR-cleaned positive with the scan's DPI and date. 35mm,
6x7, and 6x9 frames are turned to landscape (the `rotation` in `roll.json`,
clockwise degrees; `roll start --rotation` sets it).
To fix a strip's framing, open it in the Process view with its roll open
(the view takes the roll's format and rotation) and adjust the frames. Edits
save to `strip_NN_….tiff.frames.json` once they settle, Undo Frames (Cmd+Z)
steps back through edits and auto-detects, and reopening the strip shows the
saved frames. Export Strip Frames queues the strip to re-export with them
under the roll's names; later exports reuse them (delete the file to go back
to detection). Strips export one at a time in the order queued. Opening a
roll exports any strip never exported or whose saved frames changed since
its export, including strips that Close Roll or quitting dropped from the
queue.
The native UI's Scan view does the same: start or open a roll, then press
Scan Strip for each strip. Build with `-Doptimize=ReleaseFast` for real
sessions; Debug export is several times slower.

Scans go to `scans/`, processed frames to `frames/`, relative to the
directory the app starts in. The native UI takes `--scan-dir DIR` and
`--output-dir DIR` to use other directories. Hardware smoke steps are
opt-in via `CEREALGRAIN_HARDWARE_SMOKE=1` and never run implicitly.

## Project layout

    build.zig               build, test, smoke, benchmark, and webapp steps
    src/
      main.zig              CLI entry point
      companion.zig         scanner companion server for the webapp
      scanner/              Linux SANE backend; macOS interpreter backend
      processing/           frame detection, inversion, IR cleaning, render, export
      ui/                   SDL3/Nuklear native UI, workers, process cache
      wasm/                 browser WebAssembly processing core
      benchmarks/, tools/   benchmarks and WebGPU tools
    web/                    browser webapp, worker, protocol, TIFF I/O
    test/
      fixtures/             regression fixtures, originally Python-generated
      wasm/                 Node harnesses for the Wasm core, webapp, and companion
    nixos/                  NixOS module and overlay for the scanner
    scanner.py, scan.py, v600/, scratchndent/
                            original Python implementation (reference only)

## Documentation

- [Plan](plan.md) — current state, decisions, backlog
- [Cross-platform](docs/CROSS_PLATFORM.md) — support matrix, macOS
  and Windows requirements
- [Python port map](docs/PYTHON_PORT_MAP.md) — where each Python
  function landed in Zig (historical)
- [Performance](docs/PERFORMANCE_STRATEGY.md) — optimization rules,
  current numbers, GPU status
- [Webapp](docs/WEBAPP.md) and [worker protocol](docs/WEBAPP_WORKER_PROTOCOL.md)
- [Scanner companion](docs/SCANNER_COMPANION.md) — local server that
  lets the webapp scan
- [Scanner internals](docs/SCANNER_INTERNALS.md) — ESC/I protocol,
  interpreter ABI, USB packet format, TPU calibration, IR
  challenge-response, gamma LUT protocol, epkowa/epson2 patches
- [Film stock profiles](docs/FILM_STOCK_PROFILES.md) — polynomial
  calibration format, built-in presets, how to create custom profiles
- [TIFF handling](docs/TIFF_STRATEGY.md), [render transform](docs/RENDER_TRANSFORM_CLOSED_FORM.md),
  [native UI verification](docs/NATIVE_UI_VERIFICATION.md)
- [NixOS setup](nixos/README.md) — hardware configuration, patched
  epkowa backend
