# Cross-Platform Support

What runs where, and what each missing platform needs.

## Support matrix

| Platform | Scanner | Processing CLI | Native UI | Packaging |
| --- | --- | --- | --- | --- |
| Linux | SANE via patched epkowa; exercised on a V600 | Yes | SDL3/Nuklear | `packages.cli`, `packages.ui` |
| macOS | Epson Interpreter bundle over libusb; exercised on a V600 | Yes (arm64) | SDL3/Nuklear (arm64) | `zig build app-bundle` (CerealGrain.app, ad hoc signed) |
| Windows | Not planned | Not wired | Not wired | Not wired |
| Browser | Through the Linux companion (`cerealgrain serve`) only | Webapp (Wasm); checked in Chrome and Chromium | Browser UI in `web/` | `zig build wasm-webapp` |

Linux hardware steps run only with `CEREALGRAIN_HARDWARE_SMOKE=1`. See
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
  (first TPU pass, or when the LUTs change), FS G, block reads with cancel and
  progress, an interpreter reinit (every pass; see `docs/SCANNER_INTERNALS.md`),
  and a horizontal mirror for the transparency unit.
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
./zig-out/bin/cerealgrain scanner devices
CEREALGRAIN_MACOS_HARDWARE_SMOKE=1 ./zig-out/bin/cerealgrain scanner macos-smoke   # identity probe
./zig-out/bin/cerealgrain scanner preview        # film area + scans/preview.tiff.lut.bin
./zig-out/bin/cerealgrain scanner scan --kind rgb+ir --dpi 3200 --x .. --y .. --width .. --height .. \
    --lut-file scans/preview.tiff.lut.bin
```

Measured: a 400 dpi preview takes 30 s; RGB+IR of a 35 mm strip takes 1 min
45 s at 800 dpi, 9 min 20 s at 3200 dpi (0.9 GB peak memory), and 15 min 30 s
at 6400 dpi with IR at 3200 (a 3.3 GB file). Time follows the strip's length
in scan lines, not its data size; see `passSeconds` in
`src/ui/scan_workflow.zig`. Opening the connection takes well under a
second.

### Sharing the app

`zig build app-bundle`, on a Mac in the dev shell and with no other options,
builds the UI on its own (ReleaseFast, stripped, for the oldest Apple Silicon
CPU and macOS 14), then `scripts/macos_app_bundle.sh` assembles
`zig-out/CerealGrain.app` and
`zig-out/CerealGrain-<version>-<build>-macos-arm64.zip`: the
app plus `Read Me.txt` (`scripts/macos_app_readme.txt`) for testers.

- The libraries the UI loads from Nix (28, about 48 MB; the zip is about
  19 MB) are copied into `Contents/Frameworks` and their load commands
  pointed there. The step fails if a reference into `/nix/store` or the
  build machine's home directory remains.
- Signing is ad hoc: no Apple account and no identity in the signature. A
  Developer ID would need a paid membership and would put the account
  holder's legal name in every signature; testers approve the app once
  instead (System Settings, Privacy & Security, Open Anyway).
- macOS 14 is the newest minimum among the Nix libraries. Intel Macs would
  need an `x86_64-darwin` build.
- Testers install Epson's own software for their scanner, for its
  Interpreter bundle. The bundle also carries the CLI
  (`Contents/MacOS/cerealgrain`), so testers can send `scanner probe`
  output.
- Started from the bundle, the app keeps scans, exports, and both configs in
  `~/Pictures/CerealGrain`; `CEREALGRAIN_DATA_DIR` sets that folder for any
  run. From a checkout it uses the working directory.

## Scanner models

`src/scanner/models.zig` lists the Epson film scanners the app knows, from
Epson's own ICA driver tables (`EPSON Scanner.app`, `ModelInfo.plist` and
`ResolutionInfo.plist`): USB product IDs, interpreters, and resolutions. Only
the V600 has been tested; the others are a best effort for beta testers.

| Model | USB ID | Transport | Film dpi | IR |
| --- | --- | --- | --- | --- |
| Perfection V600 / GT-X820 | `0x013a` | Interpreter A1 | 800-6400 | yes, tested |
| Perfection V550 | `0x013b` | Interpreter EB | 800-6400 | if the scanner reports it |
| Perfection V800 / V850 | `0x0151` | Interpreter FE | 800-6400 | if reported |
| Perfection V500 / GT-X770 | `0x0130` | Interpreter 7C | 800-6400 | if reported |
| Perfection 4490 / GT-X750 | `0x0119` | Interpreter 54 | 1200-4800 | if reported |
| Perfection V370 / V37 | `0x014a` | Interpreter DD | 2400, 4800 | no |
| Perfection V330 / V33 | `0x0142` | Interpreter AD | 2400, 4800 | no |
| Perfection V700 / V750 / GT-X900 | `0x012c` | ESC/I, no interpreter | 800-6400 | if reported |
| GT-X970 | `0x0135` | ESC/I, no interpreter | 800-6400 | if reported |
| Perfection 4990 / GT-X800 | `0x012a` | ESC/I, no interpreter | 1200-4800 | if reported |
| Perfection 4870 / GT-X700 | `0x0128` | ESC/I, no interpreter | 1200-4800 | if reported |

Every model gets:
- Scan area, maximum resolution, and IR capability from the scanner's own
  identity (FS I).
- Resolutions snapped to the model's list, capped by that maximum. The UI
  offers only those, and turns off the IR modes, saying why, on a scanner
  without IR.
- Its model name in TIFF and sidecar metadata, and a note in the UI when it
  is untested.

What stays V600-only, or is a guess:
- The TPU calibration and gamma-table program: direct RS register writes
  captured from a V600. Other models scan without them, so without film
  LUTs; their files say no LUT was applied. Without that calibration a V600
  shows a strong green cast; another model may need its own sequence, which
  only a USB capture of Epson Scan on that model can provide.
- The IR challenge (ESC # with the XOR key) was captured on a V600. On
  another model a refusal fails the IR pass instead of scanning on.
- Resolutions for the 4800 dpi models and the interpreter-less ones are
  read from Epson's tables or assumed. A resolution the scanner rejects
  fails the pass with `ScanParametersRejected`.
- Interpreter-less models get ESC/I straight over the bulk endpoints
  (`macos.DirectEscI`): the byte stream the interpreters emulate. Untried.
- Linux: the `scanimage-v600` wrappers preload the V600's interpreter, so
  only a V600, or a device whose SANE line names no model, uses them and
  gets IR. Other models scan RGB through plain `scanimage` with whichever
  backend lists them (epkowa with Epson's plugin for the model, or epson2).
  The NixOS udev rule covers every listed USB ID.
- The Perfection V39 was in the Python model table, but it has no
  transparency unit, so it is left out.

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
