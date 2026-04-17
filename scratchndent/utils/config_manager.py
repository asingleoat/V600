"""Configuration management for film processing."""

import tomli
import tomli_w
from pathlib import Path
from typing import Any, Dict
import numpy as np

from scratchndent.calibration.film_stocks import (
    default_kodak_gold_coeffs,
    default_kodak_portra_coeffs,
)


# Reference DPI for pixel-based parameters
REFERENCE_DPI = 800

# Default algorithm parameters
PARAM_DEFAULTS = {
    # IR dust/scratch detection (pixel params at 800 DPI reference)
    "ir_threshold": 0.10,
    "ir_hair_sensitivity": 0.10,
    "ir_min_area": 3,              # pixels at 800 DPI
    "ir_dilate_radius": 4,         # pixels at 800 DPI
    "ir_close_radius": 6,          # pixels at 800 DPI
    "ir_blur_size": 301,           # pixels at 800 DPI
    "ir_max_coverage": 0.03,
    
    # Inpainting
    "inpaint_padding": 16,         # pixels at 800 DPI
    
    # Film rendering
    "render_contrast": 1.4,
    "render_curve_k": 5.0,
    "render_percentile_lo": 0.5,
    "render_percentile_hi": 99.5,
    "exposure_compensation": 0.0,
    "color_temp": 0.0,
    "color_tint": 0.0,
    
    # UI / preview
    "preview_size": 8192,       # max dimension for preview source data
    "clahe_clip": 2.0,
}

# Parameters that scale with DPI
DPI_SCALED_PARAMS = {
    "ir_min_area",       # scales as area (DPI ratio squared)
    "ir_dilate_radius",  # scales linearly
    "ir_close_radius",
    "ir_blur_size",
    "inpaint_padding",
}

# Area-based params scale quadratically
DPI_AREA_PARAMS = {"ir_min_area"}

# Built-in film stock definitions
BUILTIN_STOCKS = {
    "kodak_gold": {
        "description": "Kodak Gold 200 on Epson V600",
        "coeffs": default_kodak_gold_coeffs(),
    },
    "kodak_portra": {
        "description": "Kodak Portra 400 on Epson V600",
        "coeffs": default_kodak_portra_coeffs(),
    },
}


class ConfigManager:
    """Manages configuration for film processing."""
    
    def __init__(self, config_file: Path):
        self.config_file = config_file
        self._config = {}
        self._current_dpi = None
        self.load()
    
    def load(self) -> Dict[str, Any]:
        """Load configuration from disk."""
        if self.config_file.exists():
            try:
                with open(self.config_file, "rb") as f:
                    toml_dict = tomli.load(f)
                self._config = toml_dict
            except Exception as e:
                print(f"Warning: Could not load config from {self.config_file}: {e}")
                self._config = {}
        else:
            self._config = {}
        return self._config
    
    def save(self, updates: Dict[str, Any] = None) -> None:
        """Save configuration to disk."""
        if updates:
            self._config.update(updates)
        
        # Write to disk
        try:
            with open(self.config_file, "wb") as f:
                tomli_w.dump(self._config, f)
        except Exception as e:
            print(f"Warning: Could not save config to {self.config_file}: {e}")
    
    def get(self, key: str, default: Any = None) -> Any:
        """Get a configuration value."""
        return self._config.get(key, PARAM_DEFAULTS.get(key, default))
    
    def set_dpi(self, dpi: int) -> None:
        """Set the current scan DPI for parameter scaling."""
        self._current_dpi = dpi
    
    def get_scaled_param(self, name: str) -> float | int:
        """Get a parameter value, scaled for DPI if applicable."""
        value = self.get(name, PARAM_DEFAULTS.get(name))
        
        if name in DPI_SCALED_PARAMS and self._current_dpi:
            scale = self._current_dpi / REFERENCE_DPI
            if name in DPI_AREA_PARAMS:
                scale = scale ** 2  # Area scales quadratically
            
            if isinstance(value, int):
                return max(1, int(value * scale))
            else:
                return value * scale
        
        return value
    
    def get_available_stocks(self) -> Dict[str, Dict]:
        """Get all available film stocks: built-in + config-defined."""
        stocks = dict(BUILTIN_STOCKS)
        
        # Add custom stocks from config
        if "stocks" in self._config:
            for name, stock_cfg in self._config["stocks"].items():
                if "coeffs" in stock_cfg:
                    stocks[name] = {
                        "description": stock_cfg.get("description", f"Custom: {name}"),
                        "coeffs": np.array(stock_cfg["coeffs"]),
                    }
        
        return stocks
    
    def get_stock_coeffs(self, name: str) -> np.ndarray | None:
        """Get polynomial coefficients for a film stock by name."""
        stocks = self.get_available_stocks()
        if name in stocks:
            return stocks[name]["coeffs"]
        return None
    
    def get_active_stock(self) -> str | None:
        """Get the active film stock name."""
        return self._config.get("stock")