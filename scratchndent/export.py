"""Frame export pipeline — crop, IR clean, invert, write TIFF.

Orchestrates scratchndent processing functions into a complete export
workflow. Used by the HTTP server and potentially CLI tools.
"""

import time
from pathlib import Path

import cv2
import numpy as np

from scratchndent import (
    align_ir,
    make_defect_mask,
    inpaint,
)
from scratchndent.processing.negative import invert_negative, render_to_display
from scratchndent.processing.frames import crop_rotated_rect, apply_rotation
from scratchndent.utils import write_tiff
from scratchndent.config import get_param, get_active_stock, get_stock_coeffs


def ir_clean_region(
    rgb_region: np.ndarray,
    ir_region: np.ndarray,
    current_dpi: int | None = None,
) -> np.ndarray:
    """Detect defects at IR resolution, inpaint at RGB resolution."""
    rgb_h, rgb_w = rgb_region.shape[:2]
    ir_h, ir_w = ir_region.shape[:2]
    mask_ir = make_defect_mask(
        ir_region,
        threshold=get_param("ir_threshold", current_dpi),
        hair_sensitivity=get_param("ir_hair_sensitivity", current_dpi),
        min_area=int(get_param("ir_min_area", current_dpi)),
        dilate_radius=int(get_param("ir_dilate_radius", current_dpi)),
        close_radius=int(get_param("ir_close_radius", current_dpi)),
        blur_size=int(get_param("ir_blur_size", current_dpi)),
        max_coverage=get_param("ir_max_coverage", current_dpi),
    )
    n_defects = np.count_nonzero(mask_ir)
    if n_defects == 0:
        return rgb_region
    if rgb_h != ir_h or rgb_w != ir_w:
        mask = cv2.resize(mask_ir, (rgb_w, rgb_h), interpolation=cv2.INTER_NEAREST)
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
        mask = cv2.dilate(mask, kernel)
    else:
        mask = mask_ir
    n_final = np.count_nonzero(mask)
    print(f"    {n_defects} defect pixels (IR) -> {n_final} pixels (RGB)")
    return inpaint(rgb_region, mask, padding=get_param("inpaint_padding", current_dpi))


def apply_inversion(
    img: np.ndarray,
    dmin: np.ndarray | None = None,
    current_dpi: int | None = None,
) -> np.ndarray:
    """Full inversion pipeline: negative -> scene-linear -> display-ready."""
    stock = get_active_stock()
    coeffs = get_stock_coeffs(stock) if stock else None
    scene_linear = invert_negative(img, dmin=dmin, stock=stock or "kodak_gold", coeffs=coeffs)
    return render_to_display(
        scene_linear,
        contrast=get_param("render_contrast", current_dpi),
        curve_k=get_param("render_curve_k", current_dpi),
        percentile_lo=get_param("render_percentile_lo", current_dpi),
        percentile_hi=get_param("render_percentile_hi", current_dpi),
        exposure_compensation=get_param("exposure_compensation", current_dpi),
        color_temp=get_param("color_temp", current_dpi),
        color_tint=get_param("color_tint", current_dpi),
    )


def process_frame(
    frame_idx: int,
    rect: dict,
    rgb_img: np.ndarray,
    aligned_ir: np.ndarray | None,
    ir_scale_x: float,
    ir_scale_y: float,
    film_stock: str | None,
    stock_coeffs: np.ndarray | None,
    dmin: np.ndarray | None,
    outputs: dict,
    out_paths: dict,
    base_meta: dict,
    current_dpi: int | None = None,
) -> dict:
    """Process and export a single frame with multiple output variants.

    outputs: dict with keys "ir_neg", "ir_inv", "inv_only" -> bool
    out_paths: dict with same keys -> file path strings
    """
    timings = {}
    t0 = time.monotonic()
    written = []

    cx, cy, w, h = rect["cx"], rect["cy"], rect["w"], rect["h"]
    angle = rect.get("angle", 0)
    rotation = rect.get("rotation", 0)

    need_ir = outputs.get("ir_neg") or outputs.get("ir_inv")
    need_invert_clean = outputs.get("ir_inv")
    need_invert_raw = outputs.get("inv_only")

    t = time.monotonic()
    raw_crop = crop_rotated_rect(rgb_img, cx, cy, w, h, angle)
    timings["crop"] = time.monotonic() - t

    ir_cleaned = None
    if need_ir and aligned_ir is not None:
        t = time.monotonic()
        ir_cropped = crop_rotated_rect(
            aligned_ir,
            cx * ir_scale_x, cy * ir_scale_y,
            w * ir_scale_x, h * ir_scale_y,
            angle,
        )
        ir_cleaned = ir_clean_region(raw_crop, ir_cropped, current_dpi)
        timings["ir_clean"] = time.monotonic() - t
    elif need_ir:
        ir_cleaned = raw_crop

    def _invert(img):
        t = time.monotonic()
        scene_linear = invert_negative(
            img, dmin=dmin, coeffs=stock_coeffs, stock=film_stock or "kodak_gold",
        )
        result = render_to_display(
            scene_linear,
            contrast=get_param("render_contrast", current_dpi),
            curve_k=get_param("render_curve_k", current_dpi),
            percentile_lo=get_param("render_percentile_lo", current_dpi),
            percentile_hi=get_param("render_percentile_hi", current_dpi),
            exposure_compensation=get_param("exposure_compensation", current_dpi),
            color_temp=get_param("color_temp", current_dpi),
            color_tint=get_param("color_tint", current_dpi),
        )
        return result, time.monotonic() - t

    if outputs.get("ir_neg") and ir_cleaned is not None:
        t = time.monotonic()
        out = apply_rotation(ir_cleaned, rotation)
        meta = {**base_meta, "variant": "ir_cleaned"}
        write_tiff(out_paths["ir_neg"], out, meta)
        timings["write_ir_neg"] = time.monotonic() - t
        written.append(Path(out_paths["ir_neg"]).name)

    if need_invert_clean and ir_cleaned is not None:
        inverted, t_inv = _invert(ir_cleaned)
        timings["invert"] = t_inv
        t = time.monotonic()
        out = apply_rotation(inverted, rotation)
        meta = {**base_meta, "variant": "ir_cleaned_inverted",
                "stock": film_stock,
                "contrast": get_param("render_contrast", current_dpi),
                "dmin": dmin.tolist() if dmin is not None else None}
        write_tiff(out_paths["ir_inv"], out, meta)
        timings["write_ir_inv"] = time.monotonic() - t
        written.append(Path(out_paths["ir_inv"]).name)

    if need_invert_raw:
        inverted, t_inv = _invert(raw_crop)
        timings.setdefault("invert", t_inv)
        t = time.monotonic()
        out = apply_rotation(inverted, rotation)
        meta = {**base_meta, "variant": "inverted",
                "stock": film_stock,
                "contrast": get_param("render_contrast", current_dpi),
                "dmin": dmin.tolist() if dmin is not None else None}
        write_tiff(out_paths["inv_only"], out, meta)
        timings["write_inv_only"] = time.monotonic() - t
        written.append(Path(out_paths["inv_only"]).name)

    timings["total"] = time.monotonic() - t0
    shape = (raw_crop.shape[1], raw_crop.shape[0])
    return {"written": written, "timings": timings, "shape": shape}
