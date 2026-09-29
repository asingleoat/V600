# Cross-Platform Support

What runs where, and what each missing platform needs.

## Support matrix

| Platform | Scanner | Processing CLI | Native UI | Packaging |
| --- | --- | --- | --- | --- |
| Linux | SANE via patched epkowa; exercised on a V600 | Yes | SDL3/Nuklear | `packages.cli`, `packages.ui` |
| macOS | Epson Interpreter bundle over libusb; fake-tested, hardware bring-up pending | Yes (arm64) | SDL3/Nuklear (arm64) | Built from the dev shell only |
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

Built and tested on Apple Silicon (macOS 26) from `nix develop`: the CLI,
the native UI, and `zig build test`. Scanning works on a V600: identity
probe, preview with film-area detection, RGB+IR at 800, 3200, and 6400 dpi, scans
with film gamma LUTs, and the native UI's preview and scan workers.

How it works (`src/scanner/interpreter_runtime.zig`, `usb.zig`, `macos.zig`,
`interpreter.zig`), following the Python driver:

- libusb finds the first supported Epson product ID, claims interface 0, and
  binds the bulk endpoints.
- Epson's proprietary Interpreter bundle is loaded at runtime with `dlopen`
  and initialized with NULL-handle USB callbacks; `INTInit` uploads firmware
  (about 10 s). One connection is shared per process and reopened after any
  failure or cancel.
- Each pass: FS I identity, ESC @ reset, the IR challenge for IR passes, FS W
  parameters, TPU calibration and gamma LUT upload over direct RS commands
  (first TPU pass, or when the LUTs change, then an interpreter reinit), FS G,
  block reads with cancel and progress, and a horizontal mirror for the
  transparency unit.
- Gamma LUTs stretch each RGB channel between the film strip's own black and
  white points (computed from the preview), so the film fills the 16-bit
  range. The LUT is stored in tag 50001 and inverted on load; see
  `docs/SCANNER_INTERNALS.md`. IR passes use identity LUTs.
- The interpreter's output is linear. The Linux epkowa path delivers data
  with about gamma 1.8 applied (Dmin ratio 1.8 on the same strip); see
  `plan.md`.
- RGB+IR runs a 16-bit RGB pass and an 8-bit IR pass (at most 3200 dpi) and
  writes RGB, thumbnail, and IR pages in-process with libtiff; no `magick` or
  `tiffcp`. TPU resolutions snap to 400/800/1600/3200/6400; 6400 is
  macOS-only (Linux stops at 3200). IR stays at 800/1600/3200, so RGB+IR at
  6400 scans its IR pass at 3200.
- `scanner usb-reset` is Linux-only.

Constraints:

- Build per architecture (`aarch64-darwin`, `x86_64-darwin`); universal
  binaries are not needed. Linux cross-compilation does not count as macOS
  verification.
- The Epson Interpreter bundle is proprietary and host-installed; never
  vendor it. It is found at
  `/Library/Image Capture/Devices/EPSON Scanner.app/Contents/PlugIns/Interpreter A1.bundle/Contents/MacOS/Interpreter A1`
  or
  `/Library/Image Capture/Support/EPSON/Epson Scan 2/Models/ES00A1/Interpreter A1.bundle/Contents/MacOS/Interpreter A1`.
  The app never downloads it.
- Epson Scanner Monitor or another vendor service may claim the USB device;
  stop it if opening the scanner fails with a busy or access error.
- WebGPU on macOS would use Metal through optional packaging, never required
  for the CPU build.

Hardware bring-up, with the scanner attached:

```sh
zig build --summary all
./zig-out/bin/v600-zig scanner devices
V600_MACOS_HARDWARE_SMOKE=1 ./zig-out/bin/v600-zig scanner macos-smoke   # identity probe
./zig-out/bin/v600-zig scanner preview        # film area + scans/preview.tiff.lut.bin
./zig-out/bin/v600-zig scanner scan --kind rgb+ir --dpi 3200 --x .. --y .. --width .. --height .. \
    --lut-file scans/preview.tiff.lut.bin
```

Measured: a 400 dpi preview takes 30 s; RGB+IR of a 35 mm strip takes 1 min
45 s at 800 dpi, 9 min 20 s at 3200 dpi (0.9 GB peak memory), and 15 min 30 s
at 6400 dpi with IR at 3200 (a 3.3 GB file). Time follows the strip's length
in scan lines, not its data size; see `passSeconds` in
`src/ui/scan_workflow.zig`. Opening the connection takes well under a
second.

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
