# Linux Support Status for Epson V600

## Current State ✅ FULLY WORKING

The Epson V600 scanner is **fully functional** on Linux with complete 16-bit color depth support at all resolutions up to 6400 DPI.

### Supported Features
- ✅ **16-bit color depth at all resolutions** (300-6400 DPI) 
- ✅ RGB color scanning
- ✅ IR channel scanning (for dust/scratch removal)
- ✅ TPU (Transparency Unit) for film scanning  
- ✅ Flatbed scanning
- ✅ Auto film area detection
- ✅ Web GUI interface
- ✅ Cross-platform support (Linux and macOS)

## Solution Implemented

The 16-bit limitation in the original epkowa backend has been resolved using a patched version from the community (hean01/iscan) that removes the 8-bit restriction at high DPI resolutions.

### Backend Options

1. **epson2 backend** (recommended if available)
   - Open source SANE backend
   - Native 16-bit support at all resolutions
   - May require additional configuration for V600

2. **epkowa backend** (patched version)
   - Proprietary Epson backend 
   - Patched to enable 16-bit at 3200+ DPI
   - Fully functional with the V600

## Installation & Usage

The scanner.py script automatically detects the platform and uses the appropriate backend.

### Wrapper Scripts (Recommended)

Linux users should use the provided wrapper scripts for best results:
- `scanimage-v600` - For color/grayscale scanning
- `scanimage-v600-ir` - For infrared scanning

These wrappers are automatically detected and used by scanner.py when available.

### Usage Examples

```bash
# Start the web GUI (recommended)
python3 gui.py

# Command-line scanning
python3 scanner.py --resolution 3200 --depth 16 --mode rgb --output scan.tiff

# Direct wrapper usage
scanimage-v600 --source 'Transparency Unit' --mode Color --resolution 3200 --depth 16 -o scan.tiff
scanimage-v600-ir --source 'Transparency Unit' --mode Gray --resolution 800 -o ir_scan.tiff

# Test scanner capabilities
python3 test_scan_capabilities.py
```

### Platform Detection

- **macOS**: Uses the proprietary Interpreter A1 bundle from Epson ICA driver
- **Linux**: Uses SANE with the best available backend (epson2 or patched epkowa)

## Technical Details

The original epkowa backend had a hardcoded limitation that forced 8-bit depth at resolutions >= 3200 DPI. This was due to a `require (8 == buf->ctx.depth)` check in the dip-obj.c file.

The patched version changes these checks to accept both 8 and 16-bit:
```c
require (8 == depth || 16 == depth);
```

## Files

### Core Scripts
- `scanner.py` - Main scanner driver with dual platform support
- `gui.py` - Web-based GUI interface
- `config.py` - Configuration management
- `epson_commands.py` - ESC/I-2 protocol implementation

### Utilities
- `usb_reset.c` - USB reset tool for recovering from scanner errors
- `reset_scanner.sh` - Script wrapper for scanner reset

### Documentation
- `REVERSE_ENGINEERING_NOTES.md` - Protocol documentation
- `TESTING.md` - Test procedures and validation