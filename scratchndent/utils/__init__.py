"""Utility functions for film processing."""

from .xmp_parser import (
    parse_negadoctor_params,
    extract_negadoctor_from_xmp,
    parse_sigmoid_params,
    extract_sigmoid_from_xmp,
    extract_channelmixer_from_xmp,
)

from .config_manager import (
    ConfigManager,
    PARAM_DEFAULTS,
    REFERENCE_DPI,
)

from .io import (
    read_tiff_dpi,
    write_tiff,
    load_tiff_pages,
    find_images,
    generate_unique_path,
)

__all__ = [
    # XMP parsing
    'parse_negadoctor_params',
    'extract_negadoctor_from_xmp',
    'parse_sigmoid_params',
    'extract_sigmoid_from_xmp',
    'extract_channelmixer_from_xmp',
    # Config management
    'ConfigManager',
    'PARAM_DEFAULTS',
    'REFERENCE_DPI',
    # I/O utilities
    'read_tiff_dpi',
    'write_tiff',
    'load_tiff_pages',
    'find_images',
    'generate_unique_path',
]