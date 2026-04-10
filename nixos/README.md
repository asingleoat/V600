# NixOS Configuration for V600 Scanner

## Files

- `v600-scanner.nix` - NixOS module for scanner hardware support
- `v600-overlay.nix` - Nixpkgs overlay with patched epkowa and wrapper scripts
- `example-configuration.nix` - Example integration

## Installation

### Method 1: Direct Import

Add the overlay and module to your configuration:

```nix
# /etc/nixos/configuration.nix
{ config, pkgs, ... }:

{
  imports = [ 
    /path/to/V600/nixos/v600-scanner.nix
  ];

  nixpkgs.overlays = [
    (import /path/to/V600/nixos/v600-overlay.nix)
  ];

  users.users.yourname = {
    extraGroups = [ "scanner" "lp" ];
  };
}
```

### Method 2: Inline Configuration

If you prefer to keep everything in one file:

```nix
{ config, pkgs, ... }:

{
  nixpkgs.overlays = [
    (import /path/to/v600-overlay.nix)
  ];

  hardware.sane = {
    enable = true;
    extraBackends = [ pkgs.epkowa ];
  };
  
  environment.etc."sane.d/dll.d/epkowa.conf".text = "epkowa";
  
  services.udev.extraRules = ''
    # Epson Perfection V600 Photo
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="013a", MODE="0666", GROUP="scanner", TAG+="uaccess"
  '';
  
  environment.systemPackages = with pkgs; [
    simple-scan
    xsane
    scanimage-v600     # Color/grayscale wrapper
    scanimage-v600-ir  # IR scanning wrapper
  ];
  
  users.users.yourname.extraGroups = [ "scanner" "lp" ];
}
```

Then rebuild:
```bash
sudo nixos-rebuild switch
```

## Usage

### Command Line Wrappers

The overlay provides two wrapper scripts:

```bash
# Basic scan
scanimage-v600 -o output.tiff

# 16-bit color scan at 3200 DPI
scanimage-v600 --mode Color --depth 16 --resolution 3200 -o scan.tiff

# Film scanning (TPU)
scanimage-v600 --source "Transparency Unit" --mode Color --depth 16 --resolution 3200 -o film.tiff

# IR scan (requires TPU, grayscale mode, and specific resolutions)
scanimage-v600-ir --source "Transparency Unit" --mode Gray --resolution 1600 -o ir.tiff
# Supported IR resolutions: 800, 1600, 3200 DPI
```

### GUI Applications

- **Simple Scan** - Basic scanning interface
- **XSane** - Advanced interface with film scanning presets

## Troubleshooting

### Scanner Not Detected

1. Check USB connection:
```bash
lsusb | grep -i epson
# Should show: Bus xxx Device xxx: ID 04b8:013a Seiko Epson Corp. GT-X820 [Perfection V600 Photo]
```

2. Test scanner detection:
```bash
scanimage -L
# Should show: device `epkowa:...' is a Epson GT-X820 flatbed scanner
```

3. Check permissions:
```bash
groups
# Should include 'scanner'
```

### Slow Initial Detection

The first `scanimage -L` call takes 10-15 seconds. This is normal. The Python GUI caches the device name for 5 minutes to avoid repeated slow detections.

### 16-bit Scanning Issues

If 16-bit scanning doesn't work:

1. Verify the overlay is applied:
```bash
nix-instantiate --eval -E '(import <nixpkgs> {}).epkowa.version'
```

2. Check if wrapper scripts are available:
```bash
which scanimage-v600
which scanimage-v600-ir
```

## Technical Details

### What the Overlay Does

1. Patches epkowa backend to remove 8-bit limitation at high DPI
2. Increases buffer sizes for 16-bit data handling
3. Creates two interpreter versions:
   - Normal: Standard color/grayscale scanning
   - IR: Patched for infrared channel access
4. Provides wrapper scripts that load the appropriate interpreter via `LD_PRELOAD`

### Supported Models

While designed for the V600, this configuration may also work with:
- GT-X820 (same as V600)
- Other Epson Perfection V-series scanners (untested)