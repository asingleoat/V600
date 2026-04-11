"""LUT creation and manipulation utilities."""

import os
import tempfile


def create_lut_file(lut_r, lut_g, lut_b):
    """Create a temporary file with LUT data that the dispatcher can read.
    
    Format: 768 bytes (256 * 3 channels) - R[256] + G[256] + B[256]
    
    Args:
        lut_r: 256-byte LUT for red channel, or None for identity
        lut_g: 256-byte LUT for green channel, or None for identity
        lut_b: 256-byte LUT for blue channel, or None for identity
    
    Returns:
        Path to temporary file containing the LUT data
    """
    # Create temp file that will be deleted after scanning
    fd, path = tempfile.mkstemp(prefix='v600_luts_', suffix='.bin')
    
    with os.fdopen(fd, 'wb') as f:
        # Write R, G, B LUTs consecutively
        # Use identity LUT (0-255) if None provided
        f.write(lut_r if lut_r is not None else bytes(range(256)))
        f.write(lut_g if lut_g is not None else bytes(range(256)))
        f.write(lut_b if lut_b is not None else bytes(range(256)))
    
    return path