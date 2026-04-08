# NixOS Configuration for Epson V600 Scanner

This directory contains NixOS configuration modules to enable full support for the Epson Perfection V600 Photo scanner, including 16-bit color depth scanning at all resolutions and infrared (IR) scanning capabilities.

## Features

- ✅ **16-bit color depth** at all resolutions (300-6400 DPI)
- ✅ **Infrared scanning** for dust/scratch detection
- ✅ **Transparency Unit (TPU)** support for film scanning
- ✅ **Optimized performance** with device caching
- ✅ **Wrapper scripts** for easy command-line usage

## Files

- `v600-scanner.nix` - Main NixOS module for scanner hardware support
- `v600-overlay.nix` - Nixpkgs overlay with patched epkowa backend and wrapper scripts
- `example-configuration.nix` - Example of how to integrate into your system

## Quick Start

### Method 1: Direct Import (Recommended)

Add both the overlay and module to your NixOS configuration:

```nix
# /etc/nixos/configuration.nix
{ config, pkgs, ... }:

{
  # Import the scanner module
  imports = [ 
    ./v600-scanner.nix  # Adjust path as needed
  ];

  # Apply the overlay for patched epkowa and wrapper scripts
  nixpkgs.overlays = [
    (import ./v600-overlay.nix)  # Adjust path as needed
  ];

  # Add your user to scanner group
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
  # Apply the V600 overlay
  nixpkgs.overlays = [
    (import /path/to/v600-overlay.nix)
  ];

  # Enable SANE scanner support
  hardware.sane = {
    enable = true;
    extraBackends = [ pkgs.epkowa ];
  };
  
  # Add epkowa backend to SANE
  environment.etc."sane.d/dll.d/epkowa.conf".text = "epkowa";
  
  # udev rule for V600
  services.udev.extraRules = ''
    # Epson Perfection V600 Photo
    SUBSYSTEM=="usb", ATTRS{idVendor}=="04b8", ATTRS{idProduct}=="013a", MODE="0666", GROUP="scanner", TAG+="uaccess"
  '';
  
  # Scanner utilities
  environment.systemPackages = with pkgs; [
    simple-scan
    xsane
    scanimage-v600     # Color/grayscale wrapper
    scanimage-v600-ir  # IR scanning wrapper
  ];
  
  # Add users to scanner group
  users.users.yourname.extraGroups = [ "scanner" "lp" ];
}
```

## Usage

After rebuilding your NixOS configuration:

```bash
sudo nixos-rebuild switch
```

### GUI Applications

- **Simple Scan** - Basic scanning interface, good for documents
- **XSane** - Advanced interface with film scanning presets

### Command Line

The overlay provides two wrapper scripts:

#### Color/Grayscale Scanning (16-bit capable)
```bash
# Basic scan
scanimage-v600 -o output.tiff

# 16-bit color scan at 3200 DPI
scanimage-v600 --mode Color --depth 16 --resolution 3200 -o scan.tiff

# Film scanning (TPU)
scanimage-v600 --source "Transparency Unit" --mode Color --depth 16 --resolution 3200 -o film.tiff
```

#### Infrared Scanning (for dust/scratch detection)
```bash
# IR scan (requires TPU, grayscale mode, and specific resolutions)
scanimage-v600-ir --source "Transparency Unit" --mode Gray --resolution 1600 -o ir.tiff

# Supported IR resolutions: 800, 1600, 3200 DPI
```

### Python Integration

The V600 GUI application in this repository will automatically detect and use the patched backend when running on Linux/NixOS:

```bash
cd /path/to/V600
python3 gui.py
```

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
# Should show the epkowa version
```

2. Check if wrapper scripts are available:
```bash
which scanimage-v600
which scanimage-v600-ir
```

3. Test with regular scanimage:
```bash
scanimage --device-name epkowa:... --mode Color --depth 16 --resolution 300 -o test.tiff
```

## Technical Details

### What the Overlay Does

1. **Patches epkowa backend** to remove 8-bit limitation at high DPI
2. **Increases buffer sizes** for 16-bit data handling
3. **Creates two interpreter versions**:
   - Normal: Standard color/grayscale scanning
   - IR: Patched for infrared channel access
4. **Provides wrapper scripts** that load the appropriate interpreter

### How It Works

The Epson V600 uses a proprietary interpreter (firmware) that translates SANE commands to hardware operations. The overlay:

1. Downloads the official Epson firmware package
2. Extracts the interpreter binary
3. Creates a patched version for IR support
4. Uses `LD_PRELOAD` to load the appropriate version

### Supported Models

While designed for the V600, this configuration may also work with:
- GT-X820 (same as V600)
- Other Epson Perfection V-series scanners (untested)

## License

The NixOS configuration files are provided as-is for personal use. The Epson firmware and epkowa backend are proprietary software from Seiko Epson Corporation.

## Contributing

If you have improvements or fixes, please submit them to the main V600 repository.