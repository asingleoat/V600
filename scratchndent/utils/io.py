"""File I/O utilities for TIFF handling."""

from __future__ import annotations
from pathlib import Path
from typing import Any, Optional, Tuple, List, Dict
import tifffile
import numpy as np
from numpy.typing import NDArray


def read_tiff_dpi(path: str) -> Optional[int]:
    """Read DPI from TIFF XResolution tag. Returns None if not available."""
    try:
        with tifffile.TiffFile(path) as tif:
            page = tif.pages[0]
            if hasattr(page, 'tags') and 'XResolution' in page.tags:
                res_tag = page.tags['XResolution'].value
                if res_tag and len(res_tag) >= 2 and res_tag[1] != 0:
                    dpi = int(res_tag[0] / res_tag[1])
                    return dpi
    except Exception:
        pass
    return None


def write_tiff(path: str, img: NDArray[Any], meta: Dict[str, Any]) -> None:
    """Write a TIFF with metadata.
    
    If meta contains non-TIFF standard keys, they are stored as JSON in extratag 65000.
    """
    import json
    
    # Extract any non-standard metadata for extratags
    if meta:
        meta_json = json.dumps(meta)
        tifffile.imwrite(path, img, extratags=[
            (65000, 's', 0, meta_json, True),
        ])
    else:
        tifffile.imwrite(path, img)


def load_tiff_pages(path: str) -> Tuple[NDArray[Any], Optional[NDArray[Any]]]:
    """Load RGB and optional IR from multi-page TIFF.
    
    Returns:
        (rgb, ir) where ir may be None if not present
    """
    with tifffile.TiffFile(path) as tif:
        if len(tif.pages) >= 3:
            # Multi-page TIFF: RGB, thumbnail, IR
            rgb = tif.pages[0].asarray()
            ir = tif.pages[2].asarray() if len(tif.pages) > 2 else None
        else:
            # Single page
            rgb = tif.pages[0].asarray()
            ir = None
    
    return rgb, ir


def find_images(directory: Path) -> List[str]:
    """Find all TIFF files in a directory, sorted by name."""
    if not directory.is_dir():
        return []
    
    tiffs = []
    for ext in ["*.tif", "*.tiff", "*.TIF", "*.TIFF"]:
        tiffs.extend(directory.glob(ext))
    
    # Sort by name
    tiffs = sorted(tiffs, key=lambda p: p.name.lower())
    
    return [str(p) for p in tiffs]


def generate_unique_path(base_path: Path) -> Path:
    """Generate a unique path by appending a counter if needed."""
    if not base_path.exists():
        return base_path
    
    stem = base_path.stem
    suffix = base_path.suffix
    parent = base_path.parent
    
    counter = 2
    while True:
        new_path = parent / f"{stem}_{counter:03d}{suffix}"
        if not new_path.exists():
            return new_path
        counter += 1
        if counter > 999:
            raise ValueError(f"Could not find unique name for {base_path}")