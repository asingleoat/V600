"""Frame extraction and manipulation utilities."""

from __future__ import annotations
import math
from typing import Optional, Dict, Any, Tuple, List
import cv2
import numpy as np
from numpy.typing import NDArray


def crop_rotated_rect(
    img: NDArray[Any],
    cx: float, cy: float,
    w: float, h: float,
    angle_deg: float,
) -> NDArray[Any]:
    """Crop a rotated rectangle from the full-resolution image.
    
    Parameters are in full-image pixel coordinates.
    angle_deg: rotation in degrees (clockwise).
    """
    img_h, img_w = img.shape[:2]
    
    # Compute bounding box of the rotated rect to extract a sub-region first,
    # avoiding warpAffine on the full (potentially >32767px) image.
    diag = math.hypot(w, h) / 2
    margin = int(math.ceil(diag)) + 4
    x0 = max(int(cx) - margin, 0)
    y0 = max(int(cy) - margin, 0)
    x1 = min(int(cx) + margin, img_w)
    y1 = min(int(cy) + margin, img_h)
    sub = img[y0:y1, x0:x1]
    local_cx = cx - x0
    local_cy = cy - y0
    
    pad = 2
    out_w = int(math.ceil(w)) + pad * 2
    out_h = int(math.ceil(h)) + pad * 2
    
    # Rotate the image opposite to the selection angle so the selected
    # region becomes axis-aligned. OpenCV positive = CCW, UI positive = CW,
    # so we pass angle_deg directly (UI CW → OpenCV CCW = correct undo).
    M = cv2.getRotationMatrix2D((local_cx, local_cy), angle_deg, 1.0)
    M[0, 2] += out_w / 2 - local_cx
    M[1, 2] += out_h / 2 - local_cy
    
    rotated = cv2.warpAffine(sub, M, (out_w, out_h),
                             flags=cv2.INTER_LINEAR,
                             borderMode=cv2.BORDER_REFLECT)
    
    return rotated[pad:pad + int(h), pad:pad + int(w)]


def apply_rotation(img: NDArray[Any], rotation: int) -> NDArray[Any]:
    """Apply 90-degree rotation based on EXIF-style orientation.
    
    Args:
        img: Input image
        rotation: 0, 90, 180, or 270 degrees
    
    Returns:
        Rotated image
    """
    if rotation == 90:
        return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    elif rotation == 180:
        return cv2.rotate(img, cv2.ROTATE_180)
    elif rotation == 270:
        return cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE)
    return img


def make_rebate_mask(h: int, w: int, rebate_rect: Optional[Dict[str, Any]]) -> Optional[NDArray[np.bool_]]:
    """Build a boolean mask from the rebate rectangle, if set.
    
    Args:
        h: Image height
        w: Image width
        rebate_rect: Dict with x, y, width, height keys (or None)
    
    Returns:
        Boolean mask array or None
    """
    if not rebate_rect or rebate_rect.get("width", 0) <= 0:
        return None
    
    mask = np.zeros((h, w), dtype=bool)
    x0 = int(rebate_rect["x"])
    y0 = int(rebate_rect["y"])
    x1 = x0 + int(rebate_rect["width"])
    y1 = y0 + int(rebate_rect["height"])
    
    # Clip to image bounds
    x0 = max(0, x0)
    y0 = max(0, y0)
    x1 = min(w, x1)
    y1 = min(h, y1)
    
    if x1 > x0 and y1 > y0:
        mask[y0:y1, x0:x1] = True
    
    return mask


def rebate_in_bounds(shape: Tuple[int, ...], rect: Dict[str, Any]) -> bool:
    """Check if a rotated rebate rect's center sits within an image.
    
    Args:
        shape: Image shape (h, w, ...)
        rect: Dict with x, y, w, h keys (and optional angle for rotation)
    
    Returns:
        True if rect's center is within image bounds
    """
    h, w = shape[:2]
    cx = rect["x"] + rect["w"] / 2
    cy = rect["y"] + rect["h"] / 2
    return 0 <= cx < w and 0 <= cy < h


def extract_rebate_pixels(img: NDArray[Any], rect: Dict[str, Any]) -> NDArray[Any]:
    """Extract the rotated rebate region as an array.
    
    Args:
        img: Source image
        rect: Dict with x, y, w, h, and optional angle (radians)
    
    Returns:
        Extracted region as array
    """
    cx = rect["x"] + rect["w"] / 2
    cy = rect["y"] + rect["h"] / 2
    angle_deg = math.degrees(rect.get("angle", 0.0))
    return crop_rotated_rect(img, cx, cy, rect["w"], rect["h"], angle_deg)


def compute_inter_frame_rebate(frames: List[Dict[str, Any]]) -> Optional[Dict[str, float]]:
    """Pick an inter-frame gap and return a suggested rebate rect.

    The inter-frame gap on a 35mm strip is unexposed orange film base --
    exactly what we want for a Dmin sample. Picking the middle gap
    (least likely to have edge artifacts) and shrinking slightly in
    both axes keeps the rebate clear of frame content edges and the
    sprocket hole region just outside the cross-strip frame dimension.

    Returns {cx, cy, w, h, angle} in the same coordinate space as the
    input frames, or None if there are fewer than 2 frames.
    """
    if len(frames) < 2:
        return None

    # Pick the middle gap (index = first frame of the central pair)
    gap_idx = (len(frames) - 1) // 2
    f0 = frames[gap_idx]
    f1 = frames[gap_idx + 1]

    # Strip orientation: the line connecting the two frame centers
    # runs along the strip axis. The dominant axis tells us whether
    # the strip is vertical (frames stacked along y) or horizontal.
    dcx = f1["cx"] - f0["cx"]
    dcy = f1["cy"] - f0["cy"]
    is_vertical = abs(dcy) > abs(dcx)

    # Gap center: midpoint of the two frame centers along the strip axis
    gap_cx = (f0["cx"] + f1["cx"]) / 2
    gap_cy = (f0["cy"] + f1["cy"]) / 2

    pitch = math.hypot(dcx, dcy)
    if is_vertical:
        f_strip_dim = (f0["h"] + f1["h"]) / 2
        f_cross_dim = (f0["w"] + f1["w"]) / 2
    else:
        f_strip_dim = (f0["w"] + f1["w"]) / 2
        f_cross_dim = (f0["h"] + f1["h"]) / 2

    gap_strip_size = pitch - f_strip_dim
    if gap_strip_size <= 0:
        return None

    # Shrink to stay clear of frame content at the gap's strip-axis
    # boundaries and avoid the sprocket-hole region just outside the
    # frame's cross dimension. The shrink fractions are intentionally
    # generous on the strip axis (the gap is small to begin with --
    # ~2mm for 35mm) and modest on the cross axis (the cross dimension
    # is the full frame width).
    strip_margin = max(gap_strip_size * 0.2, 2.0)
    cross_margin = f_cross_dim * 0.1
    rebate_strip_dim = max(gap_strip_size - 2 * strip_margin, 1.0)
    rebate_cross_dim = max(f_cross_dim - 2 * cross_margin, 1.0)

    # Use the average angle of the two flanking frames
    angle = (f0["angle"] + f1["angle"]) / 2

    if is_vertical:
        rebate_w = rebate_cross_dim
        rebate_h = rebate_strip_dim
    else:
        rebate_w = rebate_strip_dim
        rebate_h = rebate_cross_dim

    return {
        "cx": float(gap_cx),
        "cy": float(gap_cy),
        "w": float(rebate_w),
        "h": float(rebate_h),
        "angle": float(angle),
    }