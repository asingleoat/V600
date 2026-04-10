#!/usr/bin/env python3
"""Create a LUT file for the V600 scanner from computed gamma tables."""

import sys
import tempfile
import os

def create_lut_file(lut_r, lut_g, lut_b, filename=None):
    """
    Create a binary file with 768 bytes of LUT data.
    
    Args:
        lut_r: 256-byte R channel LUT (or None for identity)
        lut_g: 256-byte G channel LUT (or None for identity)
        lut_b: 256-byte B channel LUT (or None for identity)
        filename: Output filename (or None for temp file)
    
    Returns:
        Path to created file
    """
    # Use identity LUTs if None provided
    if lut_r is None:
        lut_r = bytes(range(256))
    if lut_g is None:
        lut_g = bytes(range(256))
    if lut_b is None:
        lut_b = bytes(range(256))
    
    # Validate sizes
    if len(lut_r) != 256 or len(lut_g) != 256 or len(lut_b) != 256:
        raise ValueError("LUTs must be exactly 256 bytes each")
    
    # Create file
    if filename is None:
        fd, filename = tempfile.mkstemp(prefix='v600_luts_', suffix='.bin')
        os.close(fd)
    
    with open(filename, 'wb') as f:
        f.write(lut_r)
        f.write(lut_g)
        f.write(lut_b)
    
    return filename

def test_lut_file():
    """Create a test LUT file with recognizable patterns."""
    # Create test patterns
    # R: Linear with 1.5x gain
    # G: Linear with 1.2x gain  
    # B: Linear with 0.9x gain (slight reduction)
    
    lut_r = bytes(min(255, int(i * 1.5)) for i in range(256))
    lut_g = bytes(min(255, int(i * 1.2)) for i in range(256))
    lut_b = bytes(min(255, int(i * 0.9)) for i in range(256))
    
    filename = create_lut_file(lut_r, lut_g, lut_b, '/tmp/test_luts.bin')
    
    print(f"Created test LUT file: {filename}")
    print(f"  R gain: 1.5x (saturates at i=170)")
    print(f"  G gain: 1.2x (saturates at i=212)")
    print(f"  B gain: 0.9x (never saturates)")
    print()
    print("To test with scanner:")
    print(f"  export V600_LUT_FILE={filename}")
    print(f"  export V600_LUT_VERBOSE=1")
    print(f"  export LD_PRELOAD={os.path.abspath('libesintA1_lut.so')}")
    print(f"  scanimage-v600 --mode Color --depth 16 --resolution 300 -o test.tiff")
    
    return filename

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--test":
        test_lut_file()
    else:
        print("Usage: python3 create_lut_file.py --test")
        print()
        print("Or use from Python:")
        print("  from create_lut_file import create_lut_file")
        print("  path = create_lut_file(lut_r, lut_g, lut_b)")