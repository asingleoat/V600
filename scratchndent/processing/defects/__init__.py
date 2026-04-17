"""Defect detection and removal for scanned film."""

from .ir_removal import (
    load_tiff,
    align_ir,
    make_defect_mask,
    estimate_local_grain,
    synthesize_grain,
    inpaint,
)

__all__ = [
    'load_tiff',
    'align_ir',
    'make_defect_mask',
    'estimate_local_grain',
    'synthesize_grain',
    'inpaint',
]