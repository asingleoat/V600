# NixOS Configuration

Hardware support for the Epson V600 on NixOS: udev rules, patched
epkowa SANE backend with 16-bit and IR support, wrapper scripts.

Not needed for building or running the application (the project's Nix dev
shell handles that). This is for system-level scanner access on Linux.
Custom film LUTs are not applied by these wrappers yet; see `plan.md`.

## Files

    v600-scanner.nix        NixOS module (SANE, udev, packages)
    v600-overlay.nix        nixpkgs overlay (patched epkowa, wrappers)
    patch-epkowa-v600.py    checked source patcher for epkowa
    patch-v600-interpreter-ir.py
                            checked binary patcher for the IR interpreter
    example-configuration.nix

## Installation

Add the overlay and module to your NixOS configuration:

    # configuration.nix
    { config, pkgs, ... }:
    {
      imports = [ /path/to/cerealgrain/nixos/v600-scanner.nix ];

      nixpkgs.overlays = [
        (import /path/to/cerealgrain/nixos/v600-overlay.nix)
      ];

      users.users.yourname.extraGroups = [ "scanner" "lp" ];
    }

Rebuild and re-login:

    sudo nixos-rebuild switch

## Verification

    lsusb | grep -i epson
    # 04b8:013a Seiko Epson Corp. GT-X820

    scanimage-v600 -L
    # device `epkowa:...' is a Epson GT-X820 flatbed scanner

    scanimage-v600-ir -L
    # device `epkowa:...' is a Epson ... flatbed scanner

First `scanimage -L` takes 10-15 seconds. Subsequent calls are
faster. The application caches the device name for 5 minutes.

## What the overlay does

1. Patches epkowa to remove the 8-bit depth cap at high DPI
2. Increases USB buffer sizes for 16-bit data
3. Builds two interpreter variants (normal and IR-patched)
4. Provides `scanimage-v600` and `scanimage-v600-ir` wrappers
   that load the correct interpreter via `LD_PRELOAD`

The source and binary patches are applied by checked-in Python tools with exact
site validation. If nixpkgs changes epkowa or Epson changes the interpreter
binary, the build should fail with a specific patch-site or hash diagnostic
instead of silently producing an unverified scanner stack.

## Supported hardware

Designed for the V600 / GT-X820. May work with other Epson
Perfection V-series scanners (V550, V700, V750, V850) but
untested.
