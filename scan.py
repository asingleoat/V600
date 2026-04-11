#!/usr/bin/env python3
"""
Unified entry point for Epson V600 scanner utilities.

Usage:
    scan.py gui [--port PORT] [--output-dir DIR]  # Launch web GUI (default)
    scan.py cli [options]                          # Command-line interface
    scan.py --help                                 # Show help
"""

import argparse
import sys


def main():
    parser = argparse.ArgumentParser(
        description='Epson V600 Scanner Utility',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    # Launch GUI (default):
    %(prog)s
    %(prog)s gui
    %(prog)s gui --port 8080 --output-dir ~/scans
    
    # Command-line scanning:
    %(prog)s cli --dpi 3200 --output scan.tiff
    %(prog)s cli --preview
    %(prog)s cli --dpi 1600 --mode ir --area 0,0,2.7,9.54
        """
    )
    
    subparsers = parser.add_subparsers(dest='command', help='Command to run')
    
    # GUI subcommand
    gui_parser = subparsers.add_parser('gui', help='Launch web-based GUI (default)')
    gui_parser.add_argument('--port', type=int, default=8432,
                           help='Web server port (default: 8432)')
    gui_parser.add_argument('--output-dir', type=str, default='scans',
                           help='Output directory (default: scans/)')
    
    # CLI subcommand
    cli_parser = subparsers.add_parser('cli', help='Command-line interface')
    cli_parser.add_argument('--preview', action='store_true',
                           help='Scan a low-res preview of the TPU area')
    cli_parser.add_argument('--dpi', type=int, default=3200,
                           help='Scan resolution in DPI (default: 3200)')
    cli_parser.add_argument('--mode', choices=['rgb', 'ir', 'rgb+ir'], default='rgb',
                           help='Scan mode (default: rgb)')
    cli_parser.add_argument('--area', type=str,
                           help='Scan area as x,y,width,height in inches (default: full TPU)')
    cli_parser.add_argument('--output', '-o', type=str,
                           help='Output file path (default: auto-generated)')
    cli_parser.add_argument('--source', choices=['tpu', 'flatbed'], default='tpu',
                           help='Scanner source (default: tpu)')
    cli_parser.add_argument('--depth', type=int, choices=[8, 16], default=16,
                           help='Bit depth per channel (default: 16)')
    cli_parser.add_argument('--exposure', choices=['linear', 'affine'], default='linear',
                           help='Exposure mode for film scanning (default: linear)')
    
    # If no arguments provided, default to GUI
    if len(sys.argv) == 1:
        sys.argv.append('gui')
    
    args = parser.parse_args()
    
    if args.command == 'gui' or args.command is None:
        # Launch GUI
        from v600.gui import main as gui_main
        # Pass arguments to GUI
        sys.argv = ['scan.py', '--port', str(args.port if hasattr(args, 'port') else 8432),
                    '--output-dir', args.output_dir if hasattr(args, 'output_dir') else 'scans']
        gui_main()
    
    elif args.command == 'cli':
        # Launch CLI
        run_cli(args)
    
    else:
        parser.print_help()


def run_cli(args):
    """Run command-line scanner interface."""
    from scanner import EpsonScanner
    from v600.imaging.film import detect_film_area, compute_film_luts
    import numpy as np
    import tifffile
    from PIL import Image
    
    try:
        scanner = EpsonScanner()
        scanner.open()
        
        # Get scanner capabilities
        caps = scanner.get_scanner_capabilities()
        tpu_width = caps['tpu_width_in']
        tpu_height = caps['tpu_height_in']
        
        if args.preview:
            # Low-res preview scan
            print("Scanning preview...")
            arr = scanner.scan(
                dpi=200,
                x=0, y=0, width=tpu_width, height=tpu_height,
                source='tpu',
                color=True,
                depth=8
            )
            
            # Save as JPEG
            output = args.output or 'preview.jpg'
            Image.fromarray(arr).save(output, quality=85)
            print(f"Preview saved to {output}")
            
            # Attempt film detection
            area = detect_film_area(arr, 200, tpu_width, tpu_height)
            if area:
                print(f"Film detected at: x={area[0]:.2f}\", y={area[1]:.2f}\", "
                      f"w={area[2]:.2f}\", h={area[3]:.2f}\"")
            
        else:
            # Parse scan area if provided
            if args.area:
                parts = args.area.split(',')
                if len(parts) != 4:
                    print("Error: --area must be x,y,width,height", file=sys.stderr)
                    sys.exit(1)
                x, y, w, h = map(float, parts)
            else:
                x, y, w, h = 0, 0, tpu_width, tpu_height
            
            # Validate DPI for IR mode
            if args.mode in ['ir', 'rgb+ir'] and args.dpi not in [800, 1600, 3200]:
                print(f"Error: IR scanning only supports 800, 1600, or 3200 DPI", file=sys.stderr)
                sys.exit(1)
            
            # Generate output filename if not provided
            if not args.output:
                mode_tag = {'rgb': 'rgb', 'ir': 'ir', 'rgb+ir': 'rgbir'}[args.mode]
                args.output = f"scan_{mode_tag}_{args.dpi}dpi.tiff"
            
            print(f"Scanning {args.mode.upper()} at {args.dpi} DPI...")
            print(f"Area: {w:.2f}\" x {h:.2f}\" at ({x:.2f}\", {y:.2f}\")")
            
            # Compute LUTs if we have a preview (for film exposure optimization)
            lut_r, lut_g, lut_b = None, None, None
            # Note: In a full implementation, we'd load a cached preview here
            
            if args.mode == 'rgb+ir':
                # Scan RGB
                print("Pass 1/2: Scanning RGB...")
                rgb = scanner.scan(
                    dpi=args.dpi,
                    x=x, y=y, width=w, height=h,
                    source=args.source,
                    color=True,
                    depth=16,
                    ir=False,
                    lut_r=lut_r, lut_g=lut_g, lut_b=lut_b
                )
                
                # Scan IR (max 3200 DPI)
                ir_dpi = min(args.dpi, 3200)
                print(f"Pass 2/2: Scanning IR at {ir_dpi} DPI...")
                ir = scanner.scan(
                    dpi=ir_dpi,
                    x=x, y=y, width=w, height=h,
                    source=args.source,
                    color=False,
                    depth=8,
                    ir=True
                )
                
                # Save multi-page TIFF
                meta = scanner._tiff_metadata(args.dpi, lut_r, lut_g, lut_b)
                ir_meta = scanner._tiff_metadata(ir_dpi)
                
                # Generate thumbnail
                thumb_h = min(256, rgb.shape[0])
                thumb_scale = thumb_h / rgb.shape[0]
                thumb_w = int(rgb.shape[1] * thumb_scale)
                rgb8 = (rgb >> 8).astype(np.uint8)
                pil_thumb = Image.fromarray(rgb8).resize(
                    (thumb_w, thumb_h), Image.LANCZOS)
                thumb = np.array(pil_thumb)
                
                with tifffile.TiffWriter(args.output) as tw:
                    tw.write(rgb, **meta)       # page 0: RGB
                    tw.write(thumb)              # page 1: thumbnail
                    tw.write(ir, **ir_meta)      # page 2: IR
                
                print(f"Saved to {args.output} (RGB {rgb.shape}, IR {ir.shape})")
                
            else:
                # Single scan (RGB or IR)
                scanner.scan(
                    dpi=args.dpi,
                    x=x, y=y, width=w, height=h,
                    source=args.source,
                    color=(args.mode == 'rgb'),
                    depth=8 if args.mode == 'ir' else args.depth,
                    ir=(args.mode == 'ir'),
                    output=args.output,
                    lut_r=lut_r if args.mode == 'rgb' else None,
                    lut_g=lut_g if args.mode == 'rgb' else None,
                    lut_b=lut_b if args.mode == 'rgb' else None
                )
                print(f"Saved to {args.output}")
        
        scanner.close()
        
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()