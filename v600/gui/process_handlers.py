"""Processing state and HTTP route handlers.

All routes are served under the /process/ prefix (sub_path has prefix stripped).
Gallery routes under /gallery/ are also handled here since they share OUTPUT_DIR.
"""

import io
import json
import math
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urlparse, unquote

import cv2
import numpy as np
import tifffile
from PIL import Image

from scratchndent import align_ir, make_defect_mask, inpaint
from scratchndent.processing.negative import compute_dmin, invert_negative, render_to_display
from scratchndent.processing.frames import (
    detect_frames,
    crop_rotated_rect,
    apply_rotation,
    make_rebate_mask,
    rebate_in_bounds,
    extract_rebate_pixels,
    compute_inter_frame_rebate,
)
from scratchndent.utils import (
    read_tiff_dpi,
    generate_unique_path,
    write_tiff,
    find_images as find_images_util,
)
from scratchndent.calibration.film_stocks import default_kodak_gold_coeffs, default_kodak_portra_coeffs


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

CONFIG_FILE = Path("scratchndent_config.toml")

REFERENCE_DPI = 800

PARAM_DEFAULTS = {
    "ir_threshold": 0.10,
    "ir_hair_sensitivity": 0.10,
    "ir_min_area": 3,
    "ir_dilate_radius": 4,
    "ir_close_radius": 6,
    "ir_blur_size": 301,
    "ir_max_coverage": 0.03,
    "inpaint_padding": 16,
    "render_contrast": 1.4,
    "render_curve_k": 5.0,
    "render_percentile_lo": 0.5,
    "render_percentile_hi": 99.5,
    "exposure_compensation": 0.0,
    "color_temp": 0.0,
    "color_tint": 0.0,
    "preview_size": 8192,
    "clahe_clip": 2.0,
}

DPI_SCALED_PARAMS = {
    "ir_min_area", "ir_dilate_radius", "ir_close_radius",
    "ir_blur_size", "inpaint_padding",
}
DPI_AREA_PARAMS = {"ir_min_area"}

PARAM_COMMENTS = {
    "stock": "Active film stock name",
    "preview_size": "Max preview dimension in pixels",
    "ir_threshold": "Defect detection sensitivity (lower = more aggressive)",
    "ir_hair_sensitivity": "Meijering line filter threshold for hairs/scratches",
    "ir_min_area": "Minimum defect size in pixels at 800 DPI",
    "ir_dilate_radius": "Mask dilation in pixels at 800 DPI",
    "ir_close_radius": "Morphological close in pixels at 800 DPI",
    "ir_blur_size": "Background blur kernel in pixels at 800 DPI",
    "ir_max_coverage": "Sanity cap: max fraction of image flagged as defects",
    "inpaint_padding": "Context padding in pixels at 800 DPI",
    "render_contrast": "S-curve contrast strength: 1.0=linear, 2.0=punchy",
    "render_curve_k": "S-curve steepness multiplier",
    "render_percentile_lo": "Low percentile for display range normalization",
    "render_percentile_hi": "High percentile for display range normalization",
    "exposure_compensation": "Density-domain exposure shift: positive=brighter",
    "color_temp": "Color temperature: positive=warmer, negative=cooler",
    "color_tint": "Color tint: positive=magenta, negative=green",
    "clahe_clip": "CLAHE clip limit for preview contrast enhancement",
    "dmin": "Film base density [R, G, B]",
    "ir_clean": "Enable IR dust/scratch removal",
    "invert": "Enable film negative inversion",
    "preview_inversion": "Show inverted preview instead of CLAHE",
    "aspect": "Last used aspect ratio for frame selection",
}

PARAM_SECTIONS = {
    "ir_threshold": "dust_removal",
    "ir_hair_sensitivity": "dust_removal",
    "ir_min_area": "dust_removal",
    "ir_dilate_radius": "dust_removal",
    "ir_close_radius": "dust_removal",
    "ir_blur_size": "dust_removal",
    "ir_max_coverage": "dust_removal",
    "inpaint_padding": "dust_removal",
    "render_contrast": "render",
    "render_curve_k": "render",
    "render_percentile_lo": "render",
    "render_percentile_hi": "render",
    "exposure_compensation": "render",
    "color_temp": "render",
    "color_tint": "render",
}

BUILTIN_STOCKS = {
    "kodak_gold": {
        "description": "Kodak Gold 200 on Epson V600",
        "coeffs": default_kodak_gold_coeffs().tolist(),
    },
    "kodak_portra": {
        "description": "Kodak Portra 400 on Epson V600",
        "coeffs": default_kodak_portra_coeffs().tolist(),
    },
}

TIFF_EXTS = {".tif", ".tiff"}


def _load_config_from_disk() -> dict:
    if CONFIG_FILE.exists():
        try:
            import tomllib
            with open(CONFIG_FILE, "rb") as f:
                raw = tomllib.load(f)
            flat = {}
            stocks = {}
            for k, v in raw.items():
                if k == "stocks" and isinstance(v, dict):
                    stocks = v
                elif isinstance(v, dict):
                    flat.update(v)
                else:
                    flat[k] = v
            if stocks:
                flat["_stocks"] = stocks
            return flat
        except Exception:
            pass
    return {}


_CONFIG: dict = _load_config_from_disk()


def load_config() -> dict:
    return _CONFIG


def _format_toml_value(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return f'"{v}"'
    if isinstance(v, list):
        items = ", ".join(_format_toml_value(x) for x in v)
        return f"[{items}]"
    return repr(v)


def save_config(updates: dict) -> None:
    _CONFIG.update(updates)
    cfg = dict(_CONFIG)
    stocks = cfg.pop("_stocks", {})

    lines = ["# scratchndent configuration", ""]

    sectioned_keys = set(PARAM_SECTIONS.keys())
    top_keys = [k for k in cfg if k not in sectioned_keys and k != "_stocks"]
    for k in top_keys:
        comment = PARAM_COMMENTS.get(k)
        if comment:
            lines.append(f"# {comment}")
        lines.append(f"{k} = {_format_toml_value(cfg[k])}")
        lines.append("")

    for section_name in ["dust_removal", "render"]:
        section_keys = [k for k, s in PARAM_SECTIONS.items() if s == section_name]
        if not section_keys:
            continue
        lines.append(f"[{section_name}]")
        for k in section_keys:
            comment = PARAM_COMMENTS.get(k)
            if comment:
                lines.append(f"# {comment}")
            if k in cfg:
                lines.append(f"{k} = {_format_toml_value(cfg[k])}")
            else:
                lines.append(f"# {k} = {_format_toml_value(PARAM_DEFAULTS[k])}")
        lines.append("")

    all_stocks = dict(BUILTIN_STOCKS)
    all_stocks.update(stocks)
    lines.append("# Film stock profiles")
    lines.append("")
    for name, stock_def in all_stocks.items():
        lines.append(f"[stocks.{name}]")
        if "description" in stock_def:
            lines.append(f'description = "{stock_def["description"]}"')
        coeffs = stock_def["coeffs"]
        basis_labels = ["R", "G", "B", "R2", "G2", "B2", "RG", "RB", "GB", "bias"]
        lines.append("coeffs = [")
        for i, row in enumerate(coeffs):
            row_str = ", ".join(f"{v:8.4f}" for v in row)
            lines.append(f"    [{row_str}],  # {basis_labels[i]}")
        lines.append("]")
        lines.append("")

    CONFIG_FILE.write_text("\n".join(lines))


def get_available_stocks() -> dict[str, dict]:
    stocks = dict(BUILTIN_STOCKS)
    cfg = load_config()
    if "_stocks" in cfg:
        stocks.update(cfg["_stocks"])
    return stocks


def get_stock_coeffs(name: str) -> np.ndarray:
    stocks = get_available_stocks()
    if name in stocks:
        return np.array(stocks[name]["coeffs"], dtype=np.float64)
    raise ValueError(f"Unknown film stock '{name}'. Available: {list(stocks.keys())}")


def get_active_stock() -> str | None:
    return load_config().get("stock")


def get_preview_size() -> int:
    return int(load_config().get("preview_size", PARAM_DEFAULTS["preview_size"]))


# ---------------------------------------------------------------------------
# Processing state
# ---------------------------------------------------------------------------

INPUT_PATH: str = ""
INPUT_DIR: Path = Path(".")
OUTPUT_DIR: Path = Path(".")
FULL_IMG: np.ndarray | None = None
FULL_IR: np.ndarray | None = None
FULL_IMG_READY: bool = False
DMIN: np.ndarray | None = None
PREVIEW_JPEG: bytes = b""
PREVIEW_SCALE: float = 1.0
PREVIEW_RAW: np.ndarray | None = None
PREVIEW_SCENE_LINEAR: np.ndarray | None = None
FULL_WIDTH: int = 0
FULL_HEIGHT: int = 0
IMAGE_LIST: list[str] = []
IMAGE_IDX: int = 0
IR_CLEAN: bool = True
LOADING: bool = False
HAS_IR: bool = False
IS_GRAYSCALE: bool = False
PROGRESS: str = ""
REBATE_RECT: dict | None = None
CURRENT_DPI: int | None = None


def init(scan_dir, output_dir):
    """Initialize processing state with input/output directories."""
    global INPUT_DIR, OUTPUT_DIR, IMAGE_LIST, IR_CLEAN, DMIN

    INPUT_DIR = Path(scan_dir)
    OUTPUT_DIR = Path(output_dir)

    cfg = load_config()
    if cfg.get("dmin") and get_active_stock():
        DMIN = np.array(cfg["dmin"], dtype=np.float64)
        print(f"Loaded Dmin from config: R={DMIN[0]:.4f} G={DMIN[1]:.4f} B={DMIN[2]:.4f}")
    IR_CLEAN = cfg.get("ir_clean", True)

    IMAGE_LIST = find_images(INPUT_DIR)
    if IMAGE_LIST:
        switch_to_image(0)
        print(f"Processing: {len(IMAGE_LIST)} image(s) in {INPUT_DIR}")
    else:
        print(f"Processing: no images in {INPUT_DIR} (will rescan on request)")


def set_progress(msg: str) -> None:
    global PROGRESS
    PROGRESS = msg
    print(f"  [{msg}]")


def get_dpi_scale() -> float:
    if CURRENT_DPI and CURRENT_DPI > 0:
        return CURRENT_DPI / REFERENCE_DPI
    return 1.0


def get_param(name: str) -> float | int:
    cfg = load_config()
    raw = cfg[name] if name in cfg else PARAM_DEFAULTS[name]
    if name in DPI_SCALED_PARAMS:
        scale = get_dpi_scale()
        if name in DPI_AREA_PARAMS:
            raw = raw * scale * scale
        else:
            raw = raw * scale
        if name == "ir_blur_size":
            raw = int(raw) | 1
            return raw
    return type(PARAM_DEFAULTS[name])(raw)


# ---------------------------------------------------------------------------
# Image loading and processing
# ---------------------------------------------------------------------------

def load_image(path: str) -> tuple[np.ndarray, np.ndarray | None]:
    ir = None
    if path.lower().endswith((".tif", ".tiff")):
        with tifffile.TiffFile(path) as tif:
            img = tif.pages[0].asarray()
            if len(tif.pages) >= 3:
                ir_page = tif.pages[2].asarray()
                if ir_page.ndim == 2:
                    ir = ir_page
    else:
        img = cv2.imread(path, cv2.IMREAD_UNCHANGED)
        if img is not None and img.ndim == 3:
            img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    if img is None:
        raise ValueError(f"Could not load image: {path}")
    return img, ir


def switch_to_image(idx: int) -> None:
    global INPUT_PATH, FULL_IMG, FULL_IMG_READY, PREVIEW_JPEG, PREVIEW_SCALE
    global IMAGE_IDX, LOADING, FULL_WIDTH, FULL_HEIGHT, HAS_IR, IS_GRAYSCALE, CURRENT_DPI
    global PREVIEW_RAW, PREVIEW_SCENE_LINEAR, FULL_IR
    LOADING = True
    FULL_IMG = None
    FULL_IR = None
    FULL_IMG_READY = False
    IMAGE_IDX = idx
    INPUT_PATH = IMAGE_LIST[idx]

    CURRENT_DPI = read_tiff_dpi(INPUT_PATH)
    print(f"Loading {Path(INPUT_PATH).name} ({idx + 1}/{len(IMAGE_LIST)})...")
    rgb, ir = load_image(INPUT_PATH)
    h, w = rgb.shape[:2]
    FULL_WIDTH, FULL_HEIGHT = w, h
    HAS_IR = ir is not None
    IS_GRAYSCALE = rgb.ndim == 2
    dpi_str = f", {CURRENT_DPI} DPI (scale {get_dpi_scale():.1f}x)" if CURRENT_DPI else ""
    print(f"  Image: {w}x{h}, {rgb.dtype}{dpi_str}")

    ps = get_preview_size()
    preview_scale = min(ps / max(h, w), 1.0) if ps > 0 else 1.0
    if preview_scale < 1.0:
        pw, ph = int(w * preview_scale), int(h * preview_scale)
        small_rgb = cv2.resize(rgb, (pw, ph), interpolation=cv2.INTER_AREA)
    else:
        small_rgb = rgb

    raw = small_rgb
    if raw.ndim == 2:
        raw = cv2.cvtColor(raw, cv2.COLOR_GRAY2RGB)
    PREVIEW_RAW = raw.copy() if raw.dtype == np.uint16 else (raw.astype(np.uint16) * 257)
    PREVIEW_SCENE_LINEAR = None

    print("  Generating quick preview...")
    if small_rgb.dtype == np.uint16:
        preview8 = (small_rgb >> 8).astype(np.uint8)
    else:
        preview8 = small_rgb
    if preview8.ndim == 2:
        preview8 = cv2.cvtColor(preview8, cv2.COLOR_GRAY2RGB)
    gray_raw = cv2.cvtColor(preview8, cv2.COLOR_RGB2GRAY)
    content_mask = gray_raw < 240
    preview8 = 255 - preview8

    if np.count_nonzero(content_mask) > 100:
        for c in range(3):
            ch = preview8[:, :, c]
            lo = np.percentile(ch[content_mask], 1)
            hi = np.percentile(ch[content_mask], 99)
            if hi > lo:
                preview8[:, :, c] = np.clip(
                    (ch.astype(np.float32) - lo) / (hi - lo) * 255, 0, 255
                ).astype(np.uint8)
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    for c in range(3):
        preview8[:, :, c] = clahe.apply(preview8[:, :, c])
    pil_img = Image.fromarray(preview8)
    buf = io.BytesIO()
    pil_img.save(buf, format="JPEG", quality=90)
    PREVIEW_JPEG = buf.getvalue()
    PREVIEW_SCALE = preview_scale

    print(f"  Preview ready ({preview8.shape[1]}x{preview8.shape[0]}, scale={preview_scale:.4f})")
    LOADING = False


def render_inverted_preview() -> bytes | None:
    global PREVIEW_SCENE_LINEAR
    stock = get_active_stock()
    if not stock or PREVIEW_RAW is None or IS_GRAYSCALE:
        return None
    if PREVIEW_SCENE_LINEAR is None:
        t = time.monotonic()
        coeffs = get_stock_coeffs(stock)
        PREVIEW_SCENE_LINEAR = invert_negative(PREVIEW_RAW, dmin=DMIN, coeffs=coeffs)
        print(f"  Inversion preview computed in {time.monotonic()-t:.2f}s")
    t = time.monotonic()
    display = render_to_display(
        PREVIEW_SCENE_LINEAR,
        contrast=get_param("render_contrast"),
        curve_k=get_param("render_curve_k"),
        percentile_lo=get_param("render_percentile_lo"),
        percentile_hi=get_param("render_percentile_hi"),
        exposure_compensation=get_param("exposure_compensation"),
        color_temp=get_param("color_temp"),
        color_tint=get_param("color_tint"),
    )
    print(f"  Render preview in {time.monotonic()-t:.2f}s")
    if display.dtype == np.uint16:
        display8 = (display >> 8).astype(np.uint8)
    else:
        display8 = display
    pil_img = Image.fromarray(display8)
    buf = io.BytesIO()
    pil_img.save(buf, format="JPEG", quality=90)
    return buf.getvalue()


def invalidate_inversion_cache():
    global PREVIEW_SCENE_LINEAR
    PREVIEW_SCENE_LINEAR = None


def ensure_loaded() -> None:
    global FULL_IMG, FULL_IR, FULL_IMG_READY, DMIN, CURRENT_DPI
    if FULL_IMG_READY:
        return
    if CURRENT_DPI is None:
        CURRENT_DPI = read_tiff_dpi(INPUT_PATH)
    set_progress("Loading full-resolution image...")
    rgb, ir = load_image(INPUT_PATH)
    h, w = rgb.shape[:2]
    set_progress(f"Loaded {w}x{h} image")
    FULL_IR = ir
    if get_active_stock() and DMIN is None:
        if REBATE_RECT and rebate_in_bounds(rgb.shape, REBATE_RECT):
            set_progress("Computing Dmin from rebate selection...")
            rebate_rgb = extract_rebate_pixels(rgb, REBATE_RECT)
            DMIN = compute_dmin(rebate_rgb)
        else:
            set_progress("Computing Dmin from full image (no rebate set)...")
            DMIN = compute_dmin(rgb)
    FULL_IMG = rgb
    FULL_IMG_READY = True


def ir_clean_region(rgb_region: np.ndarray, ir_region: np.ndarray) -> np.ndarray:
    rgb_h, rgb_w = rgb_region.shape[:2]
    ir_h, ir_w = ir_region.shape[:2]
    mask_ir = make_defect_mask(
        ir_region,
        threshold=get_param("ir_threshold"),
        hair_sensitivity=get_param("ir_hair_sensitivity"),
        min_area=int(get_param("ir_min_area")),
        dilate_radius=int(get_param("ir_dilate_radius")),
        close_radius=int(get_param("ir_close_radius")),
        blur_size=int(get_param("ir_blur_size")),
        max_coverage=get_param("ir_max_coverage"),
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
    return inpaint(rgb_region, mask, padding=get_param("inpaint_padding"))


def apply_inversion(img: np.ndarray) -> np.ndarray:
    stock = get_active_stock()
    coeffs = get_stock_coeffs(stock) if stock else None
    scene_linear = invert_negative(img, dmin=DMIN, stock=stock or "kodak_gold", coeffs=coeffs)
    return render_to_display(
        scene_linear,
        contrast=get_param("render_contrast"),
        curve_k=get_param("render_curve_k"),
        percentile_lo=get_param("render_percentile_lo"),
        percentile_hi=get_param("render_percentile_hi"),
        exposure_compensation=get_param("exposure_compensation"),
        color_temp=get_param("color_temp"),
        color_tint=get_param("color_tint"),
    )


def rescan_images() -> None:
    global IMAGE_LIST, IMAGE_IDX
    old_current = IMAGE_LIST[IMAGE_IDX] if IMAGE_IDX < len(IMAGE_LIST) else None
    IMAGE_LIST = find_images(INPUT_DIR)
    if old_current and old_current in IMAGE_LIST:
        IMAGE_IDX = IMAGE_LIST.index(old_current)
    elif IMAGE_IDX >= len(IMAGE_LIST):
        IMAGE_IDX = max(0, len(IMAGE_LIST) - 1)


def find_images(path: Path) -> list[str]:
    if path.is_file():
        parent = path.parent
    else:
        parent = path
    return find_images_util(parent)


# ---------------------------------------------------------------------------
# Export pipeline
# ---------------------------------------------------------------------------

def _process_frame(
    frame_idx, rect, rgb_img, aligned_ir, ir_scale_x, ir_scale_y,
    film_stock, stock_coeffs, dmin, outputs, out_paths, base_meta,
) -> dict:
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
        ir_cleaned = ir_clean_region(raw_crop, ir_cropped)
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
            contrast=get_param("render_contrast"),
            curve_k=get_param("render_curve_k"),
            percentile_lo=get_param("render_percentile_lo"),
            percentile_hi=get_param("render_percentile_hi"),
            exposure_compensation=get_param("exposure_compensation"),
            color_temp=get_param("color_temp"),
            color_tint=get_param("color_tint"),
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
                "stock": film_stock, "contrast": get_param("render_contrast"),
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
                "stock": film_stock, "contrast": get_param("render_contrast"),
                "dmin": dmin.tolist() if dmin is not None else None}
        write_tiff(out_paths["inv_only"], out, meta)
        timings["write_inv_only"] = time.monotonic() - t
        written.append(Path(out_paths["inv_only"]).name)

    timings["total"] = time.monotonic() - t0
    shape = (raw_crop.shape[1], raw_crop.shape[0])
    return {"written": written, "timings": timings, "shape": shape}


def handle_export(body: dict) -> dict:
    default_base = Path(INPUT_PATH).stem
    basename = body.get("basename", default_base)
    rects = body.get("rects", [])
    n_rects = len(rects)

    outputs = {
        "ir_neg": body.get("export_ir_neg", False),
        "ir_inv": body.get("export_ir_inv", True),
        "inv_only": body.get("export_inv_only", False),
    }
    need_ir = outputs["ir_neg"] or outputs["ir_inv"]
    need_invert = outputs["ir_inv"] or outputs["inv_only"]

    if not any(outputs.values()):
        return {"message": "No output variants selected", "files": []}

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    t_start = time.monotonic()
    set_progress(f"Preparing export ({n_rects} frame{'s' if n_rects != 1 else ''})...")

    t = time.monotonic()
    ensure_loaded()
    t_load = time.monotonic() - t
    if DMIN is not None:
        print(f"  Dmin: R={DMIN[0]:.4f} G={DMIN[1]:.4f} B={DMIN[2]:.4f}")

    # IR alignment
    aligned_ir, ir_scale_x, ir_scale_y = None, 1.0, 1.0
    t_align = 0.0
    if need_ir and FULL_IR is not None:
        set_progress("Aligning IR channel...")
        t = time.monotonic()
        aligned_ir = align_ir(FULL_IMG, FULL_IR)
        t_align = time.monotonic() - t
        rgb_h, rgb_w = FULL_IMG.shape[:2]
        ir_h, ir_w = aligned_ir.shape[:2]
        ir_scale_x = ir_w / rgb_w
        ir_scale_y = ir_h / rgb_h

    film_stock = get_active_stock() if need_invert else None
    stock_coeffs = get_stock_coeffs(film_stock) if film_stock else None

    # Build frame jobs
    suffixes = {"ir_neg": "_ir", "ir_inv": "", "inv_only": "_inv"}
    frame_jobs = []
    for i, r in enumerate(rects):
        out_paths = {}
        for variant, enabled in outputs.items():
            if enabled:
                suffix = suffixes[variant]
                path = generate_unique_path(OUTPUT_DIR / f"{basename}_{i + 1:02d}{suffix}.tif")
                out_paths[variant] = str(path)
        base_meta = {
            "source": Path(INPUT_PATH).name,
            "rebate_rect": REBATE_RECT,
            "crop": {"cx": r["cx"], "cy": r["cy"], "w": r["w"], "h": r["h"],
                     "angle": r.get("angle", 0)},
        }
        frame_jobs.append((i, r, out_paths, base_meta))

    # Process frames
    set_progress(f"Processing {n_rects} frame{'s' if n_rects != 1 else ''}...")
    all_written = []
    all_timings = [None] * n_rects

    def run_frame(i, r, out_paths, base_meta):
        return _process_frame(
            i, r, FULL_IMG, aligned_ir, ir_scale_x, ir_scale_y,
            film_stock, stock_coeffs, DMIN, outputs, out_paths, base_meta,
        )

    if n_rects == 1:
        i, r, out_paths, base_meta = frame_jobs[0]
        result = run_frame(i, r, out_paths, base_meta)
        all_written.extend(result["written"])
        all_timings[0] = result["timings"]
        for name in result["written"]:
            set_progress(f"Wrote {name}")
    else:
        with ThreadPoolExecutor(max_workers=min(n_rects, 4)) as pool:
            futures = {}
            for i, r, out_paths, base_meta in frame_jobs:
                fut = pool.submit(run_frame, i, r, out_paths, base_meta)
                futures[fut] = i
            for fut in as_completed(futures):
                i = futures[fut]
                result = fut.result()
                all_written.extend(result["written"])
                all_timings[i] = result["timings"]
                for name in result["written"]:
                    set_progress(f"Wrote {name}")

    t_total = time.monotonic() - t_start
    print(f"\n  === Export timing ===")
    print(f"  Load:      {t_load:.2f}s")
    if t_align > 0:
        print(f"  IR align:  {t_align:.2f}s")
    for i, timings in enumerate(all_timings):
        if timings:
            parts = " | ".join(f"{k}: {v:.2f}s" for k, v in timings.items())
            print(f"  Frame {i+1}:   {parts}")
    print(f"  Total:     {t_total:.2f}s\n")

    msg = f"Exported {len(all_written)} file{'s' if len(all_written) != 1 else ''} to {OUTPUT_DIR}/ ({t_total:.1f}s)"
    set_progress(msg)
    return {"message": msg, "files": all_written}


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def _respond(handler, code, content_type, data):
    try:
        handler.send_response(code)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(data)))
        handler.end_headers()
        handler.wfile.write(data)
    except BrokenPipeError:
        pass


def _respond_json(handler, code, obj):
    _respond(handler, code, "application/json", json.dumps(obj).encode())


# ---------------------------------------------------------------------------
# Route handlers — /process/*
# ---------------------------------------------------------------------------

def handle_get(handler, sub_path):
    """Handle GET requests under /process/."""
    if sub_path == "/":
        html_path = Path(__file__).parent / "extract_ui.html"
        _respond(handler, 200, "text/html", html_path.read_bytes())

    elif sub_path == "/preview":
        _respond(handler, 200, "image/jpeg", PREVIEW_JPEG)

    elif sub_path == "/preview/inverted":
        try:
            jpeg = render_inverted_preview()
        except Exception as e:
            print(f"  ERROR in render_inverted_preview: {e}")
            jpeg = None
        if jpeg:
            _respond(handler, 200, "image/jpeg", jpeg)
        else:
            _respond(handler, 200, "image/jpeg", PREVIEW_JPEG)

    elif sub_path == "/info":
        info = {
            "full_width": FULL_WIDTH,
            "full_height": FULL_HEIGHT,
            "preview_scale": PREVIEW_SCALE,
            "filename": Path(INPUT_PATH).name if INPUT_PATH else "",
            "image_idx": IMAGE_IDX,
            "image_count": len(IMAGE_LIST),
            "loading": LOADING,
            "has_dmin": DMIN is not None,
            "dpi": CURRENT_DPI,
            "dpi_scale": round(get_dpi_scale(), 2),
        }
        _respond_json(handler, 200, info)

    elif sub_path == "/progress":
        _respond_json(handler, 200, {"status": PROGRESS})

    elif sub_path == "/settings":
        cfg = load_config()
        cfg_copy = {k: v for k, v in cfg.items() if k != "_stocks"}
        _respond_json(handler, 200, cfg_copy)

    elif sub_path == "/stocks":
        stocks = get_available_stocks()
        data = {
            "active": get_active_stock(),
            "stocks": {k: v.get("description", k) for k, v in stocks.items()},
        }
        _respond_json(handler, 200, data)

    elif sub_path == "/images":
        rescan_images()
        data = {
            "images": [Path(p).name for p in IMAGE_LIST],
            "current": IMAGE_IDX,
        }
        _respond_json(handler, 200, data)

    else:
        handler.send_error(404)


def handle_post(handler, sub_path):
    """Handle POST requests under /process/."""
    global REBATE_RECT, DMIN

    if sub_path == "/export":
        length = int(handler.headers.get("Content-Length", 0))
        body = json.loads(handler.rfile.read(length))
        result = handle_export(body)
        _respond_json(handler, 200, result)

    elif sub_path == "/switch":
        length = int(handler.headers.get("Content-Length", 0))
        body = json.loads(handler.rfile.read(length))
        idx = body.get("idx", 0)
        if 0 <= idx < len(IMAGE_LIST):
            switch_to_image(idx)
            _respond_json(handler, 200, {
                "full_width": FULL_WIDTH, "full_height": FULL_HEIGHT,
                "preview_scale": PREVIEW_SCALE,
                "filename": Path(INPUT_PATH).name,
                "image_idx": IMAGE_IDX,
                "image_count": len(IMAGE_LIST),
            })
        else:
            _respond_json(handler, 400, {"error": "Invalid index"})

    elif sub_path == "/rebate":
        length = int(handler.headers.get("Content-Length", 0))
        body = json.loads(handler.rfile.read(length))
        REBATE_RECT = {
            "x": float(body["x"]),
            "y": float(body["y"]),
            "w": float(body["w"]),
            "h": float(body["h"]),
            "angle": float(body.get("angle", 0.0)),
        }
        print(f"  Rebate set: x={REBATE_RECT['x']:.0f} y={REBATE_RECT['y']:.0f} "
              f"w={REBATE_RECT['w']:.0f} h={REBATE_RECT['h']:.0f}")
        if get_active_stock():
            if FULL_IMG is not None:
                src_img = FULL_IMG
            else:
                print(f"  Reading rebate region from {Path(INPUT_PATH).name}...")
                with tifffile.TiffFile(INPUT_PATH) as tif:
                    src_img = tif.pages[0].asarray()
            rebate_rgb = extract_rebate_pixels(src_img, REBATE_RECT)
            DMIN = compute_dmin(rebate_rgb)
            invalidate_inversion_cache()
            print(f"  Dmin updated: R={DMIN[0]:.4f} G={DMIN[1]:.4f} B={DMIN[2]:.4f}")
            save_config({"dmin": DMIN.tolist()})
        _respond_json(handler, 200, {
            "ok": True,
            "dmin": DMIN.tolist() if DMIN is not None else None,
        })

    elif sub_path == "/settings":
        length = int(handler.headers.get("Content-Length", 0))
        body = json.loads(handler.rfile.read(length))
        save_config(body)
        if "stock" in body:
            invalidate_inversion_cache()
        _respond_json(handler, 200, {"ok": True})

    elif sub_path == "/auto-detect":
        length = int(handler.headers.get("Content-Length", 0))
        body = json.loads(handler.rfile.read(length))
        fmt = body.get("format", "35mm_strip_6")
        n_override = body.get("n_frames")
        try:
            if PREVIEW_RAW is not None:
                result = detect_frames(PREVIEW_RAW, fmt, n_frames=n_override)
                for i, f in enumerate(result["frames"]):
                    fw = f["w"] / PREVIEW_SCALE
                    fh = f["h"] / PREVIEW_SCALE
                    print(f"    Frame {i+1}: {fw:.0f}x{fh:.0f}px, "
                          f"rotation {math.degrees(f['angle']):+.2f} deg")
                rebate = compute_inter_frame_rebate(result["frames"])
                if rebate is not None:
                    rw_full = rebate["w"] / PREVIEW_SCALE
                    rh_full = rebate["h"] / PREVIEW_SCALE
                    print(f"    Suggested rebate: {rw_full:.0f}x{rh_full:.0f}px")
                _respond_json(handler, 200, {
                    "ok": True,
                    "frames": result["frames"],
                    "aspect": result["aspect"],
                    "rebate": rebate,
                })
            else:
                _respond_json(handler, 400, {"error": "No image loaded"})
        except Exception as e:
            print(f"  Auto-detect error: {e}")
            _respond_json(handler, 500, {"error": str(e)})

    elif sub_path == "/debug/selections":
        length = int(handler.headers.get("Content-Length", 0))
        body = json.loads(handler.rfile.read(length))
        sels = body.get("selections", [])
        print(f"\n  === Selections ({len(sels)} frames) ===")
        for i, s in enumerate(sels):
            print(f"  Frame {i+1}: x={s['x']:.1f} y={s['y']:.1f} "
                  f"w={s['w']:.1f} h={s['h']:.1f} angle={s.get('angle',0):.4f}")
        _respond_json(handler, 200, {"ok": True})

    elif sub_path == "/trash":
        _scan_trash(handler)

    elif sub_path == "/delete":
        _scan_delete(handler)

    else:
        handler.send_error(404)


def _scan_trash(handler):
    if IMAGE_IDX >= len(IMAGE_LIST):
        _respond_json(handler, 400, {"error": "No image loaded"})
        return
    path = Path(IMAGE_LIST[IMAGE_IDX])
    trash_dir = path.parent / ".trash"
    trash_dir.mkdir(exist_ok=True)
    dest = trash_dir / path.name
    n = 1
    while dest.exists():
        dest = trash_dir / f"{path.stem}_{n}{path.suffix}"
        n += 1
    path.rename(dest)
    print(f"  Trashed scan: {path.name} -> .trash/{dest.name}")
    rescan_images()
    _respond_json(handler, 200, {"ok": True, "message": f"Moved {path.name} to trash"})


def _scan_delete(handler):
    if IMAGE_IDX >= len(IMAGE_LIST):
        _respond_json(handler, 400, {"error": "No image loaded"})
        return
    path = Path(IMAGE_LIST[IMAGE_IDX])
    name = path.name
    path.unlink()
    print(f"  Deleted scan: {name}")
    rescan_images()
    _respond_json(handler, 200, {"ok": True, "message": f"Deleted {name}"})


# ---------------------------------------------------------------------------
# Gallery route handlers — /gallery/*
# ---------------------------------------------------------------------------

def handle_gallery_get(handler, sub_path):
    """Handle GET requests under /gallery/."""
    if sub_path == "/":
        html_path = Path(__file__).parent / "gallery.html"
        _respond(handler, 200, "text/html", html_path.read_bytes())

    elif sub_path == "/list":
        export_files = sorted(
            p.name for p in OUTPUT_DIR.iterdir()
            if p.is_file() and p.suffix.lower() in TIFF_EXTS
        ) if OUTPUT_DIR.exists() else []
        _respond_json(handler, 200, {"files": export_files})

    elif sub_path.startswith("/thumb/"):
        name = unquote(sub_path[len("/thumb/"):])
        _serve_export_jpeg(handler, name, max_dim=200)

    elif sub_path.startswith("/full/"):
        name = unquote(sub_path[len("/full/"):])
        _serve_export_jpeg(handler, name, max_dim=0)

    else:
        handler.send_error(404)


def handle_gallery_post(handler, sub_path):
    """Handle POST requests under /gallery/."""
    if sub_path.startswith("/trash/"):
        name = unquote(sub_path[len("/trash/"):])
        _gallery_trash(handler, name)
    elif sub_path.startswith("/delete/"):
        name = unquote(sub_path[len("/delete/"):])
        _gallery_delete(handler, name)
    else:
        handler.send_error(404)


def _gallery_resolve(handler, name: str) -> Path | None:
    path = OUTPUT_DIR / name
    if not path.exists() or not path.is_file():
        _respond_json(handler, 404, {"error": "File not found"})
        return None
    if OUTPUT_DIR not in path.resolve().parents and path.resolve() != OUTPUT_DIR:
        _respond_json(handler, 403, {"error": "Access denied"})
        return None
    return path


def _gallery_trash(handler, name: str):
    path = _gallery_resolve(handler, name)
    if path is None:
        return
    trash_dir = OUTPUT_DIR / ".trash"
    trash_dir.mkdir(exist_ok=True)
    dest = trash_dir / path.name
    n = 1
    while dest.exists():
        dest = trash_dir / f"{path.stem}_{n}{path.suffix}"
        n += 1
    path.rename(dest)
    print(f"  Trashed: {path.name} -> .trash/{dest.name}")
    _respond_json(handler, 200, {"ok": True, "message": f"Moved {path.name} to trash"})


def _gallery_delete(handler, name: str):
    path = _gallery_resolve(handler, name)
    if path is None:
        return
    path.unlink()
    print(f"  Deleted: {path.name}")
    _respond_json(handler, 200, {"ok": True, "message": f"Deleted {path.name}"})


def _serve_export_jpeg(handler, name: str, max_dim: int = 2400):
    path = OUTPUT_DIR / name
    if not path.exists() or not path.is_file():
        _respond(handler, 404, "text/plain", b"Not found")
        return
    try:
        with tifffile.TiffFile(str(path)) as tif:
            img = tif.pages[0].asarray()
        if img.dtype == np.uint16:
            img = (img >> 8).astype(np.uint8)
        h, w = img.shape[:2]
        scale = min(max_dim / max(h, w), 1.0) if max_dim > 0 else 1.0
        if scale < 1.0:
            img = cv2.resize(img, (int(w * scale), int(h * scale)),
                             interpolation=cv2.INTER_AREA)
        pil_img = Image.fromarray(img)
        buf = io.BytesIO()
        pil_img.save(buf, format="JPEG", quality=85)
        _respond(handler, 200, "image/jpeg", buf.getvalue())
    except Exception as e:
        _respond(handler, 500, "text/plain", str(e).encode())
