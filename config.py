"""Configuration management for epdaughter scanner.

Uses TOML format with self-documenting comments. All known parameters
are written to the config file — active values uncommented, defaults
commented out — so the file serves as its own reference.
"""

import os
from pathlib import Path

# Default config location (overridden by --output-dir in GUI)
CONFIG_FILE = Path("epdaughter_config.toml")

# --- Parameter schema ---

PARAM_DEFAULTS = {
    # Scan settings
    "dpi": 3200,
    "mode": "rgb+ir",
    "autoselect": True,

    # Selection area (inches)
    "sel_x_in": 0.0,
    "sel_y_in": 0.0,
    "sel_w_in": 0.0,
    "sel_h_in": 0.0,

    # Film detection
    "detect_pad": 0.05,
    "detect_min_area": 0.05,

    # Preview
    "preview_dpi": 200,

    # GUI server
    "port": 8432,
}

PARAM_SECTIONS = {
    "dpi": "scan",
    "mode": "scan",
    "autoselect": "scan",

    "sel_x_in": "selection",
    "sel_y_in": "selection",
    "sel_w_in": "selection",
    "sel_h_in": "selection",

    "detect_pad": "detection",
    "detect_min_area": "detection",

    "preview_dpi": "preview",

    "port": "server",
}

PARAM_COMMENTS = {
    "dpi": "Scan resolution (800, 1200, 1600, 3200, 6400)",
    "mode": "Scan mode: rgb+ir, rgb, ir",
    "autoselect": "Auto-detect film area on preview",

    "sel_x_in": "Selection X offset (inches)",
    "sel_y_in": "Selection Y offset (inches)",
    "sel_w_in": "Selection width (inches)",
    "sel_h_in": "Selection height (inches)",

    "detect_pad": "Padding around detected film area (fraction of smaller dimension)",
    "detect_min_area": "Minimum region size for detection (fraction of image)",

    "preview_dpi": "Preview scan resolution (minimum 200 for TPU)",

    "port": "Web GUI server port",
}


def load_config() -> dict:
    """Load config from TOML file, returning a flat dict."""
    if not CONFIG_FILE.exists():
        return {}
    try:
        import tomllib
        with open(CONFIG_FILE, "rb") as f:
            raw = tomllib.load(f)
        # Flatten sections
        flat = {}
        for k, v in raw.items():
            if isinstance(v, dict):
                flat.update(v)
            else:
                flat[k] = v
        return flat
    except Exception:
        return {}


def save_config(updates: dict) -> None:
    """Merge updates into the TOML config file with comments.

    All known parameters are included — active values uncommented,
    defaults commented out — so the file is self-documenting.
    """
    cfg = load_config()
    cfg.update(updates)

    # Group by section
    sections: dict[str, list[str]] = {}
    unsectioned = []
    for key in PARAM_DEFAULTS:
        section = PARAM_SECTIONS.get(key)
        if section:
            sections.setdefault(section, []).append(key)
        else:
            unsectioned.append(key)

    lines = []
    for key in unsectioned:
        lines.append(_format_param(key, cfg))

    for section, keys in sections.items():
        lines.append(f"\n[{section}]")
        for key in keys:
            lines.append(_format_param(key, cfg))

    lines.append("")  # trailing newline
    CONFIG_FILE.write_text("\n".join(lines))


def _format_param(key: str, cfg: dict) -> str:
    """Format a single parameter as a TOML line, commented if at default."""
    comment = PARAM_COMMENTS.get(key, "")
    default = PARAM_DEFAULTS[key]
    value = cfg.get(key, default)
    active = key in cfg

    val_str = _to_toml(value)
    prefix = "" if active else "# "
    comment_str = f"  # {comment}" if comment else ""
    return f"{prefix}{key} = {val_str}{comment_str}"


def _to_toml(value) -> str:
    """Convert a Python value to TOML representation."""
    if isinstance(value, bool):
        return "true" if value else "false"
    elif isinstance(value, str):
        return f'"{value}"'
    elif isinstance(value, float):
        return f"{value}"
    elif isinstance(value, int):
        return str(value)
    elif isinstance(value, list):
        return "[" + ", ".join(_to_toml(v) for v in value) + "]"
    return str(value)


def get_param(name: str):
    """Get a parameter value: config overrides defaults."""
    cfg = load_config()
    if name in cfg:
        default = PARAM_DEFAULTS.get(name)
        if default is not None:
            return type(default)(cfg[name])
        return cfg[name]
    return PARAM_DEFAULTS.get(name)
