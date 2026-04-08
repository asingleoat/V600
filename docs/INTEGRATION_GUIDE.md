# Epson V600 Combined Overlay Integration Guide

## Overview
This guide explains how to integrate the combined 16-bit + IR scanning overlay into your NixOS configuration.

## Files Created
- `epkowa-combined-overlay.nix` - The main overlay combining both features
- `configuration-example.nix` - Example configuration showing usage
- `test-combined-features.sh` - Test script to verify both features work

## Integration Steps

### 1. Replace Existing Overlays
In your `/home/tim/dotfiles/desktop/nixos/configuration.nix`, replace the current epkowa overlays with:

```nix
nixpkgs.overlays = [
  (import /home/tim/code/16bitV600/epkowa-combined-overlay.nix)
  # ... other overlays ...
];
```

### 2. Update Hardware Configuration
Ensure your hardware.sane configuration includes:

```nix
hardware.sane = {
  enable = true;
  extraBackends = [ 
    pkgs.iscan-gt-x820-bundle
  ];
};
```

### 3. Add Scanner Wrapper
Include the wrapper in system packages:

```nix
environment.systemPackages = with pkgs; [
  scanimage-v600
  # ... other packages ...
];
```

## Usage

### Regular Scanning (with 16-bit support)
```bash
# 16-bit color scan at high resolution
scanimage-v600 --mode Color --depth 16 --resolution 4800 -o scan.pnm

# Standard 8-bit scan
scanimage-v600 --mode Color --depth 8 --resolution 300 -o scan.pnm
```

### IR Scanning
```bash
# IR scan for dust/scratch detection
scanimage-v600 --ir --source 'Transparency Unit' --mode Gray --resolution 800 -o ir_scan.pnm

# IR scan at higher resolution
scanimage-v600 --ir --source 'Transparency Unit' --mode Gray --resolution 1600 -o ir_scan.pnm
```

## Features Included

### 16-bit Scanning Fixes
- Increased USB buffer sizes (256KB/1024KB)
- Fixed 16-bit depth processing in dip-obj.c
- Proper max_request_size implementation

### IR Mode Support
- Binary patches to enable source=3 (TPU+IR)
- Runtime mode selection via environment variable
- Dispatcher that loads appropriate interpreter
- Convenient --ir flag in wrapper script

## Testing
Run the included test script to verify both features:
```bash
/home/tim/code/16bitV600/test-combined-features.sh
```

## Troubleshooting

### Scanner Not Found
- Ensure scanner is connected and powered on
- Check `scanimage -L` output
- Verify user is in `scanner` group

### IR Mode Not Working
- IR requires Transparency Unit, Gray mode, and specific resolutions (800/1600/3200)
- Check that SCAN_IR_MODE environment variable is being set
- Verify dispatcher is loading correct library

### 16-bit Scans Failing
- Some applications may not support 16-bit PNM files
- Try converting with ImageMagick: `convert scan.pnm scan.tiff`

## Technical Details

The overlay works by:
1. Patching epkowa backend for 16-bit buffer sizes
2. Creating two interpreter versions (normal and IR-patched)
3. Using a dispatcher to select interpreter at runtime
4. Providing a wrapper script for convenient usage

Both features are fully compatible and can be used independently or together.