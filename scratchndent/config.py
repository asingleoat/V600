"""Processing configuration management.

TOML-based config with self-documenting comments, DPI-scaled parameters,
and built-in film stock profiles. Config is loaded once at import time
and updated in memory; save_config() persists to disk.
"""

from pathlib import Path

import numpy as np

from scratchndent.calibration.film_stocks import default_kodak_gold_coeffs, default_kodak_portra_coeffs


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


# ---------------------------------------------------------------------------
# Config I/O
# ---------------------------------------------------------------------------

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
    """Return the in-memory config (no disk read)."""
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
    """Merge updates into in-memory config and persist to disk."""
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


# ---------------------------------------------------------------------------
# Param accessors
# ---------------------------------------------------------------------------

def get_param(name: str, current_dpi: int | None = None) -> float | int:
    """Get a parameter value, optionally scaled for the scan's DPI."""
    cfg = load_config()
    raw = cfg[name] if name in cfg else PARAM_DEFAULTS[name]
    if name in DPI_SCALED_PARAMS and current_dpi and current_dpi > 0:
        scale = current_dpi / REFERENCE_DPI
        if name in DPI_AREA_PARAMS:
            raw = raw * scale * scale
        else:
            raw = raw * scale
        if name == "ir_blur_size":
            return int(raw) | 1
    return type(PARAM_DEFAULTS[name])(raw)


def get_available_stocks() -> dict[str, dict]:
    """Get all available film stocks: built-in + config-defined."""
    stocks = dict(BUILTIN_STOCKS)
    cfg = load_config()
    if "_stocks" in cfg:
        stocks.update(cfg["_stocks"])
    return stocks


def get_stock_coeffs(name: str) -> np.ndarray:
    """Get polynomial coefficients for a film stock by name."""
    stocks = get_available_stocks()
    if name in stocks:
        return np.array(stocks[name]["coeffs"], dtype=np.float64)
    raise ValueError(f"Unknown film stock '{name}'. Available: {list(stocks.keys())}")


def get_active_stock() -> str | None:
    """Get the active film stock name from config, or None."""
    return load_config().get("stock")


def get_preview_size() -> int:
    """Get the max preview dimension from config."""
    return int(load_config().get("preview_size", PARAM_DEFAULTS["preview_size"]))
