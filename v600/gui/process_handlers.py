"""Processing state and HTTP route handlers.

All routes are served under the /process/ prefix (sub_path has prefix stripped).
Gallery routes under /gallery/ are also handled here since they share OUTPUT_DIR.
"""

import io
import json
import math
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import unquote

import cv2
import numpy as np
import tifffile
from PIL import Image

from scratchndent import align_ir
from scratchndent.processing.negative import compute_dmin, invert_negative, render_to_display
from scratchndent.processing.frames import (
    detect_frames,
    rebate_in_bounds,
    extract_rebate_pixels,
    compute_inter_frame_rebate,
)
from scratchndent.utils import read_tiff_dpi, generate_unique_path, find_images as find_images_util
from scratchndent.config import (
    CONFIG_FILE, TIFF_EXTS, REFERENCE_DPI,
    load_config, save_config, get_param,
    get_available_stocks, get_stock_coeffs, get_active_stock, get_preview_size,
)
from scratchndent.export import process_frame, apply_inversion


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
    dpi_str = f", {CURRENT_DPI} DPI (scale {CURRENT_DPI / REFERENCE_DPI:.1f}x)" if CURRENT_DPI else ""
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
        return process_frame(
            i, r, FULL_IMG, aligned_ir, ir_scale_x, ir_scale_y,
            film_stock, stock_coeffs, DMIN, outputs, out_paths, base_meta,
            current_dpi=CURRENT_DPI,
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
            "dpi_scale": round(CURRENT_DPI / REFERENCE_DPI, 2) if CURRENT_DPI else 1.0,
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
                frames = result["frames"]

                # Sanity check: for single-frame detections, verify the
                # frame covers a reasonable portion of the image. Single-
                # frame scans (e.g. a pre-cropped TIFF) lack the inter-
                # frame gaps that detection relies on, producing junk.
                # Fall back to selecting the whole image in that case.
                if len(frames) == 1:
                    ph, pw = PREVIEW_RAW.shape[:2]
                    f = frames[0]
                    area_ratio = (f["w"] * f["h"]) / (pw * ph)
                    if area_ratio < 0.3:
                        print(f"    Single frame covers only {area_ratio:.0%} of image, "
                              f"falling back to full-image selection")
                        frames = [{
                            "cx": pw / 2.0,
                            "cy": ph / 2.0,
                            "w": float(pw),
                            "h": float(ph),
                            "angle": 0.0,
                        }]
                        _respond_json(handler, 200, {
                            "ok": True,
                            "frames": frames,
                            "aspect": result["aspect"],
                            "rebate": None,
                        })
                        return

                for i, f in enumerate(frames):
                    fw = f["w"] / PREVIEW_SCALE
                    fh = f["h"] / PREVIEW_SCALE
                    print(f"    Frame {i+1}: {fw:.0f}x{fh:.0f}px, "
                          f"rotation {math.degrees(f['angle']):+.2f} deg")
                rebate = compute_inter_frame_rebate(frames)
                if rebate is not None:
                    rw_full = rebate["w"] / PREVIEW_SCALE
                    rh_full = rebate["h"] / PREVIEW_SCALE
                    print(f"    Suggested rebate: {rw_full:.0f}x{rh_full:.0f}px")
                _respond_json(handler, 200, {
                    "ok": True,
                    "frames": frames,
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
