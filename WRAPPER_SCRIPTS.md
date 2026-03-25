# V600 Scanner Wrapper Scripts

## Overview

The Epson V600 scanner on Linux now uses two wrapper scripts that properly configure the scanner for different scanning modes:

- `scanimage-v600` - For regular color and grayscale scanning
- `scanimage-v600-ir` - For infrared (IR) scanning

These wrappers pass through all standard scanimage flags while ensuring the scanner is properly configured for each mode.

## Usage

### Color Scanning (RGB)
```bash
scanimage-v600 \
  --source 'Transparency Unit' \
  --mode Color \
  --resolution 3200 \
  --depth 16 \
  -o color_scan.tiff
```

### Infrared Scanning (IR)
```bash
scanimage-v600-ir \
  --source 'Transparency Unit' \
  --mode Gray \
  --resolution 800 \
  -o ir_scan.tiff
```

## Parameters

Both scripts accept all standard scanimage parameters:

- `--source` - Either 'Flatbed' or 'Transparency Unit'
- `--mode` - Color, Gray, or Lineart (IR only supports Gray)
- `--resolution` - DPI value
  - Color: 400, 800, 1600, 3200, 6400
  - IR: 800, 1600, 3200
- `--depth` - Bit depth (8 or 16)
- `-l`, `-t`, `-x`, `-y` - Scan area coordinates in mm
- `-o` - Output file path
- `--format` - Output format (tiff, pnm, etc.)

## IR Mode Requirements

When using `scanimage-v600-ir`:
- Must use `--source 'Transparency Unit'`
- Must use `--mode Gray`
- Resolution must be 800, 1600, or 3200 DPI

## Integration with scanner.py

The `scanner.py` script automatically detects and uses these wrapper scripts when available:

```python
# Automatic wrapper selection
scanner = EpsonScanner()
scanner.open()

# For color scanning - uses scanimage-v600
scanner.scan(dpi=3200, depth=16, color=True, source='tpu', ir=False)

# For IR scanning - uses scanimage-v600-ir  
scanner.scan(dpi=800, depth=8, color=False, source='tpu', ir=True)
```

If the wrapper scripts are not found, scanner.py falls back to:
- Regular `scanimage` command
- Sets `SCAN_IR_MODE=1` environment variable for IR mode (if 16bitV600 backend is installed)

## Testing

Test that the wrappers are working:

```bash
# Check if wrappers are in PATH
which scanimage-v600
which scanimage-v600-ir

# Test color scan
scanimage-v600 --source 'Transparency Unit' --mode Color --resolution 400 -o test_color.tiff

# Test IR scan
scanimage-v600-ir --source 'Transparency Unit' --mode Gray --resolution 800 -o test_ir.tiff
```

## Installation

The wrapper scripts should be installed in a directory in your PATH (e.g., `/usr/local/bin/` or `~/.local/bin/`).

### NixOS
If using NixOS with the 16bitV600 overlay, the wrappers are automatically provided.

### Manual Installation
1. Copy the wrapper scripts to a PATH directory
2. Make them executable: `chmod +x scanimage-v600*`
3. Ensure the underlying scanimage and interpreter libraries are properly configured

## Troubleshooting

### Wrappers not found
- Check they're in PATH: `echo $PATH`
- Verify executable: `ls -l $(which scanimage-v600)`

### IR scan produces regular grayscale
- Ensure using `scanimage-v600-ir` (not `scanimage-v600`)
- Verify Transparency Unit is selected
- Check resolution is 800, 1600, or 3200

### Scanner not detected
- Run `scanimage -L` to list devices
- Check USB connection
- Ensure user is in scanner group: `groups $USER`