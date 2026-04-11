#!/usr/bin/env python3
"""
Web GUI for the Epson V600 scanner.

Provides a browser-based interface for:
- Preview scanning (low-res TPU transparency area)
- Rectangular area selection on the preview
- Full-resolution scanning of selected area
- RGB and IR modes with auto-incrementing filenames
"""

from v600.gui import main

if __name__ == '__main__':
    main()