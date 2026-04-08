# Epson V600 Scanner Driver

Complete driver and GUI for the Epson Perfection V600 Photo scanner with full 16-bit color depth and infrared (IR) scanning support on both macOS and Linux.

## Features

- ✅ **Cross-platform**: Works on macOS and Linux (NixOS tested)
- ✅ **16-bit color depth** at all resolutions (up to 6400 DPI)
- ✅ **Infrared scanning** for dust/scratch detection
- ✅ **Film scanning** with automatic detection and cropping
- ✅ **Web GUI** for easy scanning with live preview
- ✅ **Gain calibration** for optimal dynamic range
- ✅ **Performance optimized** with device caching on Linux

## Quick Start

### macOS

1. Install Epson ICA driver (will be auto-downloaded if not present)
2. Run the GUI:
```bash
python3 gui.py
```
3. Open browser to http://localhost:5001

### Linux/NixOS

1. Add the NixOS configuration (see `nixos/README.md`)
2. Run the GUI:
```bash
python3 gui.py
```
3. Open browser to http://localhost:5001

### Command Line

```bash
# Basic scan
python3 scanner.py --dpi 300 -o scan.tiff

# 16-bit film scan
python3 scanner.py --tpu --depth 16 --dpi 3200 -o film.tiff

# IR scan for dust detection
python3 scanner.py --ir --tpu --dpi 1600 -o infrared.tiff
```

## Documentation

- [`nixos/README.md`](nixos/README.md) - NixOS setup and configuration
- [`docs/API_DOCUMENTATION.md`](docs/API_DOCUMENTATION.md) - Programming interface
- [`docs/INTEGRATION_GUIDE.md`](docs/INTEGRATION_GUIDE.md) - Integration with existing systems
- [`LINUX_STATUS.md`](LINUX_STATUS.md) - Linux support status
- [`TESTING.md`](TESTING.md) - Test procedures

## Project Structure

```
V600/
├── scanner.py          # Core scanner driver (cross-platform)
├── gui.py             # Web-based GUI
├── server.py          # Flask backend server
├── nixos/             # NixOS configuration modules
│   ├── v600-scanner.nix    # Hardware configuration
│   ├── v600-overlay.nix    # Patched epkowa with 16-bit/IR
│   └── README.md           # NixOS setup guide
├── docs/              # Additional documentation
├── test/              # Test scripts
├── firmware/          # Interpreter binaries (auto-downloaded)
└── static/            # Web GUI assets
```

## Requirements

### macOS
- Python 3.8+
- NumPy, Pillow, Flask, pyusb, tifffile, scipy
- Epson ICA Scanner Driver (auto-downloaded)

### Linux
- NixOS recommended (see `nixos/README.md`)
- SANE with epkowa backend
- Python dependencies same as macOS

## How It Works

### macOS
Uses the proprietary Epson Interpreter bundle to translate ESC/I-2 commands into USB operations. The interpreter is loaded as a dynamic library and provides low-level scanner control.

### Linux
Uses SANE (Scanner Access Now Easy) with a patched epkowa backend that removes the 8-bit limitation at high DPI. Includes wrapper scripts that use `LD_PRELOAD` to load patched interpreters for IR support.

## Technical Details

The scanner uses the ESC/I-2 protocol with extensions:
- `FS W` command sets scanning parameters with 64-byte blocks
- `RS` commands control hardware registers for gain calibration
- IR mode requires special authentication sequence (`ESC #`)
- TPU calibration uses AFE gain and CCD timing parameters

## Known Issues

- Initial scanner detection on Linux takes 10-15 seconds (cached for 5 minutes)
- IR scanning only works at 800, 1600, or 3200 DPI
- Some applications may not support 16-bit PNM files (use TIFF instead)

## License

This project is for personal use. The Epson firmware and epkowa backend are proprietary software from Seiko Epson Corporation.

## Contributing

Contributions welcome! Please test changes on your hardware before submitting PRs.

## Credits

- Epson Interpreter analysis and protocol documentation
- SANE epson2 backend for protocol reference
- Community patches for 16-bit scanning support