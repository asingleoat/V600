"""
ScratchNDent - Film scanning post-processing toolkit.

Modules:
- processing.defects: IR-based dust/scratch detection and removal
- processing.negative: Negative film inversion and color processing
- processing.frames: Automatic frame detection and extraction
- calibration: Film stock calibration and measurement
- utils: Utility functions (XMP parsing, etc.)
- web: Web-based user interfaces
"""

__version__ = "2.0.0"

# Import main functions for convenience
from scratchndent.processing.defects import (
    load_tiff,
    align_ir,
    make_defect_mask,
    inpaint,
)

from scratchndent.processing.negative import (
    invert_negative,
    render_to_display,
    compute_dmin,
)

from scratchndent.processing.frames import (
    detect_frames,
    FORMATS as FRAME_FORMATS,
)

__all__ = [
    # Defect removal
    'load_tiff',
    'align_ir',
    'make_defect_mask',
    'inpaint',
    # Negative processing
    'invert_negative',
    'render_to_display',
    'compute_dmin',
    # Frame detection
    'detect_frames',
    'FRAME_FORMATS',
]