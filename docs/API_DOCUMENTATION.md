# Epson V600 Scanner API Documentation

## Overview

This document describes how to programmatically control the Epson V600 scanner with 16-bit and IR scanning capabilities on Linux.

## Environment Variable Interface

The IR mode is controlled via environment variables, making it easy to integrate with any programming language.

### `SCAN_IR_MODE`

Controls whether the scanner operates in normal or infrared mode.

- **Values**: `"1"` or `"true"` (case-insensitive) for IR mode; unset or any other value for normal mode
- **Scope**: Process environment
- **Effect**: Causes the interpreter dispatcher to load the IR-patched interpreter

## Direct scanimage Usage

### Basic Examples

```bash
# Normal color scan
scanimage --mode Color --resolution 400 -o color.pnm

# IR scan (set environment variable)
SCAN_IR_MODE=1 scanimage \
  --source 'Transparency Unit' \
  --mode Gray \
  --resolution 800 \
  -o infrared.pnm

# 16-bit color scan
scanimage --mode Color --depth 16 --resolution 2400 -o highbit.pnm
```

### Required Parameters for IR Mode

When `SCAN_IR_MODE=1` is set, you MUST use:
- `--source 'Transparency Unit'`
- `--mode Gray`
- `--resolution` one of: 800, 1600, or 3200

## Python Integration

### Simple Function
```python
import subprocess
import os

def v600_scan(output_file, ir_mode=False, **options):
    """
    Scan with Epson V600
    
    Args:
        output_file: Path to output file
        ir_mode: Enable IR scanning
        **options: Additional scanimage options
    """
    env = os.environ.copy()
    
    if ir_mode:
        env['SCAN_IR_MODE'] = '1'
        # Force IR requirements
        options['source'] = 'Transparency Unit'
        options['mode'] = 'Gray'
        if 'resolution' not in options:
            options['resolution'] = 800
    
    cmd = ['scanimage']
    for key, value in options.items():
        cmd.extend([f'--{key}', str(value)])
    cmd.extend(['-o', output_file])
    
    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"Scan failed: {result.stderr}")
    
    return output_file
```

### Complete Class Implementation
```python
import subprocess
import os
from enum import Enum
from typing import Optional, Dict, Any

class ScanMode(Enum):
    COLOR = "Color"
    GRAY = "Gray"
    LINEART = "Lineart"

class V600Scanner:
    """
    Epson V600 scanner controller with IR support
    """
    
    VALID_IR_RESOLUTIONS = [800, 1600, 3200]
    
    def __init__(self, device: Optional[str] = None):
        """
        Initialize scanner
        
        Args:
            device: Optional device string (auto-detected if None)
        """
        self.device = device or self._find_device()
    
    def _find_device(self) -> str:
        """Auto-detect Epson V600 scanner"""
        result = subprocess.run(
            ['scanimage', '-L'], 
            capture_output=True, 
            text=True
        )
        
        for line in result.stdout.split('\n'):
            if 'V600' in line or 'GT-X820' in line:
                # Extract device string
                device = line.split("'")[1]
                return device
        
        raise RuntimeError("Epson V600 scanner not found")
    
    def scan_ir(self, 
                output_file: str,
                resolution: int = 800,
                x_mm: float = 50,
                y_mm: float = 50,
                offset_x: float = 0,
                offset_y: float = 0) -> str:
        """
        Perform infrared scan for dust/scratch detection
        
        Args:
            output_file: Output filename
            resolution: DPI (must be 800, 1600, or 3200)
            x_mm: Scan width in mm
            y_mm: Scan height in mm
            offset_x: X offset in mm
            offset_y: Y offset in mm
            
        Returns:
            Path to output file
        """
        if resolution not in self.VALID_IR_RESOLUTIONS:
            raise ValueError(f"IR resolution must be one of {self.VALID_IR_RESOLUTIONS}")
        
        env = os.environ.copy()
        env['SCAN_IR_MODE'] = '1'
        
        cmd = [
            'scanimage',
            '--device', self.device,
            '--source', 'Transparency Unit',
            '--mode', 'Gray',
            '--resolution', str(resolution),
            '-l', str(offset_x),
            '-t', str(offset_y),
            '-x', str(x_mm),
            '-y', str(y_mm),
            '--format', 'pnm',
            '-o', output_file
        ]
        
        result = subprocess.run(cmd, env=env, capture_output=True, text=True)
        
        if result.returncode != 0:
            raise RuntimeError(f"IR scan failed: {result.stderr}")
        
        return output_file
    
    def scan_color(self,
                   output_file: str,
                   resolution: int = 400,
                   depth: int = 8,
                   x_mm: float = 50,
                   y_mm: float = 50,
                   offset_x: float = 0,
                   offset_y: float = 0,
                   source: str = "Flatbed") -> str:
        """
        Perform color scan
        
        Args:
            output_file: Output filename
            resolution: DPI
            depth: Bit depth (8 or 16)
            x_mm: Scan width in mm
            y_mm: Scan height in mm
            offset_x: X offset in mm
            offset_y: Y offset in mm
            source: "Flatbed" or "Transparency Unit"
            
        Returns:
            Path to output file
        """
        cmd = [
            'scanimage',
            '--device', self.device,
            '--source', source,
            '--mode', 'Color',
            '--depth', str(depth),
            '--resolution', str(resolution),
            '-l', str(offset_x),
            '-t', str(offset_y),
            '-x', str(x_mm),
            '-y', str(y_mm),
            '--format', 'pnm',
            '-o', output_file
        ]
        
        # No special environment needed for color
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode != 0:
            raise RuntimeError(f"Color scan failed: {result.stderr}")
        
        return output_file

# Usage example
if __name__ == "__main__":
    scanner = V600Scanner()
    
    # IR scan for dust detection
    scanner.scan_ir("dust_scan.pnm", resolution=800, x_mm=100, y_mm=100)
    
    # High-quality 16-bit color scan
    scanner.scan_color("photo.pnm", depth=16, resolution=2400, x_mm=100, y_mm=100)
```

## Shell Script Integration

```bash
#!/bin/bash

# Function to perform IR scan
scan_ir() {
    local output=$1
    local resolution=${2:-800}
    
    SCAN_IR_MODE=1 scanimage \
        --source 'Transparency Unit' \
        --mode Gray \
        --resolution $resolution \
        -o "$output"
}

# Function to perform color scan
scan_color() {
    local output=$1
    local depth=${2:-8}
    local resolution=${3:-400}
    
    scanimage \
        --mode Color \
        --depth $depth \
        --resolution $resolution \
        -o "$output"
}

# Usage
scan_ir "infrared.pnm" 1600
scan_color "photo.pnm" 16 2400
```

## C/C++ Integration

```c
#include <stdlib.h>
#include <stdio.h>

int scan_v600_ir(const char* output_file, int resolution) {
    // Set environment variable
    setenv("SCAN_IR_MODE", "1", 1);
    
    char cmd[512];
    snprintf(cmd, sizeof(cmd), 
        "scanimage --source 'Transparency Unit' --mode Gray "
        "--resolution %d -o %s",
        resolution, output_file);
    
    int result = system(cmd);
    
    // Unset for next scan
    unsetenv("SCAN_IR_MODE");
    
    return result;
}
```

## Node.js Integration

```javascript
const { exec } = require('child_process');
const { promisify } = require('util');
const execAsync = promisify(exec);

async function scanIR(outputFile, resolution = 800) {
    const env = { ...process.env, SCAN_IR_MODE: '1' };
    
    const cmd = `scanimage \
        --source 'Transparency Unit' \
        --mode Gray \
        --resolution ${resolution} \
        -o ${outputFile}`;
    
    try {
        await execAsync(cmd, { env });
        return outputFile;
    } catch (error) {
        throw new Error(`IR scan failed: ${error.stderr}`);
    }
}

async function scanColor(outputFile, depth = 8, resolution = 400) {
    const cmd = `scanimage \
        --mode Color \
        --depth ${depth} \
        --resolution ${resolution} \
        -o ${outputFile}`;
    
    try {
        await execAsync(cmd);
        return outputFile;
    } catch (error) {
        throw new Error(`Color scan failed: ${error.stderr}`);
    }
}
```

## Technical Details

### How It Works

1. **Environment Check**: The dispatcher library (`libesintA1.so`) checks `SCAN_IR_MODE` at runtime
2. **Library Selection**: Based on the variable, it loads:
   - `libesintA1_normal.so` - Standard scanning
   - `libesintA1_ir.so` - IR-patched version
3. **Hardware Control**: The IR version sends `source=3` to hardware (TPU+IR mode)

### Why Environment Variables?

- **Language agnostic**: Works with any programming language
- **Process isolation**: Each scan process can have different settings
- **No configuration files**: No persistent state to manage
- **Thread safe**: Each process has its own environment

### Debugging

Enable debug output to see which interpreter is loaded:
```bash
SCAN_IR_MODE=1 scanimage --source 'Transparency Unit' --mode Gray --resolution 800 2>&1 | grep V600
# Output: [V600] IR mode enabled
```

## Limitations

1. **IR Mode Requirements**:
   - Only works with Transparency Unit (not flatbed)
   - Only grayscale mode supported
   - Resolution must be exactly 800, 1600, or 3200 DPI

2. **Hardware**:
   - Only tested on Epson V600 / GT-X820
   - May work on V550 (same interpreter binary)

3. **Operating System**:
   - Requires NixOS with the custom overlay
   - Or manual installation of patched interpreter

## Troubleshooting

### IR scan produces regular grayscale
- Ensure `SCAN_IR_MODE=1` is set
- Verify Transparency Unit is selected
- Check resolution is 800, 1600, or 3200

### Scanner not found
- Check scanner is connected and powered
- Run `scanimage -L` to list devices
- Ensure user is in `scanner` group

### 16-bit scans fail
- Some applications don't support 16-bit PNM
- Convert with: `convert scan.pnm scan.tiff`

## See Also

- [INTEGRATION_GUIDE.md](INTEGRATION_GUIDE.md) - NixOS setup instructions
- [V600_COMBINED_README.md](V600_COMBINED_README.md) - General overview
- [test-combined-features.sh](test-combined-features.sh) - Test script examples