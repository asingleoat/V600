"""Constants for Epson V600 scanner."""

# Scanner models (USB product ID -> info)
SCANNER_MODELS = {
    0x0142: {"name": "Perfection V39", "interp": "A2", "ir": False, "max_dpi": 4800},
    0x014b: {"name": "Perfection V850", "interp": "A3", "ir": True, "max_dpi": 6400},
    0x013a: {"name": "Perfection V600 / GT-X820", "interp": "A1", "ir": True, "max_dpi": 6400},
    0x0143: {"name": "Perfection V550", "interp": "A1", "ir": False, "max_dpi": 6400},
    0x0130: {"name": "Perfection V700 / V750", "interp": "AZ", "ir": True, "max_dpi": 6400},
}

# Valid scanning resolutions (DPI)
VALID_RESOLUTIONS = [75, 100, 150, 200, 240, 266, 300, 320, 350, 360, 400, 480,
                     600, 720, 800, 1200, 1600, 2400, 3200, 4800, 6400, 9600, 12800]

# Valid resolutions for IR scanning (hardware limitation)
VALID_IR_RESOLUTIONS = [800, 1600, 3200]

# Default scanner capabilities (used as fallback)
DEFAULT_CAPABILITIES = {
    'optical_dpi': 6400,
    'max_dpi': 12800,
    'tpu_width_in': 2.7,
    'tpu_height_in': 9.54,
    'flatbed_width_in': 8.5,
    'flatbed_height_in': 11.7,
    'has_tpu': True,
    'has_ir': True,
    'max_depth': 16
}