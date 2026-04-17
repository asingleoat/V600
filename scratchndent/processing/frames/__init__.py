"""Frame detection and extraction from scanned film."""

from .detection import (
    FORMATS,
    detect_frames,
)

from .extraction import (
    crop_rotated_rect,
    apply_rotation,
    make_rebate_mask,
    rebate_in_bounds,
    extract_rebate_pixels,
    compute_inter_frame_rebate,
)

__all__ = [
    'FORMATS',
    'detect_frames',
    'crop_rotated_rect',
    'apply_rotation',
    'make_rebate_mask',
    'rebate_in_bounds',
    'extract_rebate_pixels',
    'compute_inter_frame_rebate',
]