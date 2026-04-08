# Epson V600 16-bit + IR Scanning for Linux

Complete solution for enabling both 16-bit scanning and infrared (IR) channel support on Epson V600 scanners under Linux using NixOS.

## Features

- **16-bit Color Scanning**: Full 48-bit color depth (16 bits per channel)
- **IR Channel Support**: Access to infrared channel for dust/scratch detection
- **Runtime Mode Selection**: Switch between normal and IR modes without root
- **NixOS Integration**: Clean overlay-based installation

## Quick Start

1. Add the overlay to your NixOS configuration:
```nix
nixpkgs.overlays = [
  (import /path/to/epkowa-combined-overlay.nix)
];
```

2. Use the wrapper for scanning:
```bash
# Regular high-quality scan
scanimage-v600 --mode Color --depth 16 --resolution 4800 -o scan.pnm

# IR scan for dust detection
scanimage-v600 --ir --source 'Transparency Unit' --mode Gray --resolution 800 -o ir.pnm
```

## Files

- `epkowa-combined-overlay.nix` - Main NixOS overlay
- `patch_ir_safe_cli.py` - IR mode binary patcher
- `configuration-example.nix` - Example NixOS configuration
- `test-combined-features.sh` - Feature verification script
- `INTEGRATION_GUIDE.md` - Detailed setup instructions

## How It Works

### 16-bit Scanning
Patches the epkowa SANE backend to:
- Increase USB buffer sizes for high-resolution data
- Fix color depth validation to accept 16-bit samples
- Properly handle 16-bit data in image processing pipeline

### IR Mode
Binary patches the proprietary interpreter (libesintA1.so) to:
- Bypass source=3 validation check
- Change TPU source parameter from 1 to 3 (enabling IR)
- Use runtime dispatcher to select normal or IR interpreter

## Requirements

- Epson V600 scanner
- NixOS Linux
- Transparency Unit (for IR mode)
- iscan-gt-x820-bundle package

## Technical Details

The V600 hardware fully supports IR scanning, but the Linux interpreter lacks proper implementation. This solution:

1. Applies minimal binary patches to enable source=3 (TPU+IR mode)
2. Creates two interpreter versions (normal and IR-patched)
3. Uses a C dispatcher to select the appropriate version at runtime
4. Provides a convenient wrapper script with --ir flag

IR mode requirements:
- Must use Transparency Unit source
- Must use Gray mode
- Resolution must be 800, 1600, or 3200 DPI

## Testing

Run the test script to verify both features:
```bash
./test-combined-features.sh
```

## Credits

Based on extensive reverse engineering of the V600 firmware and ESC/I-2 protocol.