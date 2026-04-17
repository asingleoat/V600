# V600

Scanning and film processing for the Epson V600 and related scanners.
Drives the hardware for 16-bit RGB and infrared acquisition via
transparency unit, then processes the scans: automatic frame detection,
IR-based dust/scratch removal, calibrated negative inversion with
per-stock color profiles.

Single application, browser-based UI, runs on Linux and macOS.

## Getting started

Requires [Nix](https://nixos.org/download/).

    git clone <repo> && cd V600
    nix-shell
    ./scan.py

A window opens at `http://127.0.0.1:8432`. The scanner UI is at
`/scan/`, the film processing UI at `/process/`, and the export
gallery at `/gallery/`.

Pass `--browser` to open in the default browser instead of the
native window.

## Scanner setup

### Linux

Install the NixOS module from `nixos/v600-scanner.nix` for udev
rules and the patched epkowa SANE backend. See `nixos/README.md`.

### macOS

The Epson ICA interpreter is downloaded automatically on first run.
Connect the scanner via USB.

## Usage

    ./scan.py                       # launch GUI (default)
    ./scan.py gui --browser         # open in browser
    ./scan.py gui --port 9000       # custom port
    ./scan.py cli --dpi 3200        # command-line scan
    ./scan.py cli --preview         # low-res preview
    ./scan.py cli --mode rgb+ir     # RGB + infrared

Scans go to `scans/`, processed frames to `frames/`.

## Project layout

    scanner.py              scanner hardware driver (SANE on Linux, interpreter on macOS)
    scan.py                 entry point
    v600/
      core/                 scanner constants, backends
      config/               scanner configuration (TOML)
      imaging/              film detection, LUT computation
      gui/                  HTTP server, HTML interfaces
    scratchndent/
      config.py             processing configuration (TOML)
      export.py             frame export pipeline
      calibration/          film stock profiles, density measurement
      processing/
        defects/            IR dust/scratch detection and inpainting
        frames/             automatic frame detection and extraction
        negative/           negative inversion, color transforms, rendering
      utils/                TIFF I/O, XMP parsing

## Documentation

- [Scanner internals](docs/SCANNER_INTERNALS.md) — ESC/I protocol,
  interpreter ABI, USB packet format, TPU calibration, IR
  challenge-response, gamma LUT protocol, epkowa/epson2 patches
- [Film stock profiles](docs/FILM_STOCK_PROFILES.md) — polynomial
  calibration format, built-in presets, how to create custom profiles
- [NixOS setup](nixos/README.md) — hardware configuration, patched
  epkowa backend
