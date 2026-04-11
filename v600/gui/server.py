"""HTTP server and request handlers for the scanner GUI."""

import argparse
import io
import json
import os
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from socketserver import ThreadingMixIn

import numpy as np
import tifffile
from PIL import Image as PILImage

from v600.config import settings as cfg_mod
from v600.imaging.film import detect_film_area, compute_film_luts
from .html_interface import get_html


class ScannerState:
    """Global state for scanner operations."""
    def __init__(self):
        self.scanner = None
        self.scanner_lock = threading.Lock()
        self.scanner_error = None
        self.preview_jpeg = None
        self.preview_scale = 1.0
        self.preview_dpi = 200
        self.tpu_width_in = 0.0
        self.tpu_height_in = 0.0
        self.scan_counter = 1
        self.output_dir = "."
        self.scanning = False
        self.last_preview_arr = None
        self.scan_status = ""
        self.cancel_requested = False


state = ScannerState()


def load_config():
    return cfg_mod.load_config()


def save_config(updates):
    cfg_mod.save_config(updates)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # silence request logging

    def do_GET(self):
        if self.path == '/':
            html = get_html().encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', len(html))
            self.end_headers()
            self.wfile.write(html)

        elif self.path == '/info':
            preview_w = 0
            preview_h = 0
            if state.last_preview_arr is not None:
                preview_h, preview_w = state.last_preview_arr.shape[:2]
            data = json.dumps({
                'preview_w': preview_w,
                'preview_h': preview_h,
                'tpu_width': state.tpu_width_in,
                'tpu_height': state.tpu_height_in,
                'scan_counter': state.scan_counter,
            })
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data.encode())

        elif self.path == '/detect':
            result = {}
            if state.last_preview_arr is not None:
                area = detect_film_area(
                    state.last_preview_arr, state.preview_dpi,
                    state.tpu_width_in, state.tpu_height_in)
                if area:
                    result = dict(
                        sel_x_in=area[0], sel_y_in=area[1],
                        sel_w_in=area[2], sel_h_in=area[3])
            data = json.dumps(result)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data.encode())

        elif self.path == '/preview':
            if state.preview_jpeg:
                self.send_response(200)
                self.send_header('Content-Type', 'image/jpeg')
                self.send_header('Content-Length', len(state.preview_jpeg))
                self.end_headers()
                self.wfile.write(state.preview_jpeg)
            else:
                self.send_response(404)
                self.end_headers()

        elif self.path == '/config':
            data = json.dumps(load_config())
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data.encode())

        elif self.path == '/scan-status':
            data = json.dumps({'status': state.scan_status, 'scanning': state.scanning})
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data.encode())

        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == '/preview':
            self._handle_preview()
        elif self.path == '/scan':
            length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(length)) if length else {}
            self._handle_scan(body)
        elif self.path == '/cancel':
            state.cancel_requested = True
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            return
        elif self.path == '/config':
            length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(length)) if length else {}
            save_config(body)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
        else:
            self.send_error(404)

    def _handle_preview(self):
        if state.scanner is None:
            error_msg = state.scanner_error or "No scanner connected"
            self.send_response(503)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'error': error_msg,
                'offline': True
            }).encode())
            return

        try:
            with state.scanner_lock:
                start_time = time.time()
                print(f"[{time.time()-start_time:.2f}s] Preview scan started")
                
                caps = state.scanner.get_scanner_capabilities()
                print(f"[{time.time()-start_time:.2f}s] Got capabilities")
                
                state.tpu_width_in = caps['tpu_width_in']
                state.tpu_height_in = caps['tpu_height_in']
                
                print(f"[{time.time()-start_time:.2f}s] TPU dimensions: {state.tpu_width_in:.1f}\" x {state.tpu_height_in:.1f}\"")
                print(f"[{time.time()-start_time:.2f}s] Preview size will be: {int(state.tpu_width_in * state.preview_dpi)} x {int(state.tpu_height_in * state.preview_dpi)} pixels")

                print(f"[{time.time()-start_time:.2f}s] Starting scanner.scan() - TPU area {state.tpu_width_in:.1f}\" x {state.tpu_height_in:.1f}\" at {state.preview_dpi} DPI")
                arr = state.scanner.scan(
                    dpi=state.preview_dpi,
                    x=0, y=0, width=state.tpu_width_in, height=state.tpu_height_in,
                    source='tpu',
                    color=True,
                    depth=8,
                )
                print(f"[{time.time()-start_time:.2f}s] Scan complete: {arr.shape} pixels")

            state.last_preview_arr = arr

            pil_img = PILImage.fromarray(arr)
            buf = io.BytesIO()
            pil_img.save(buf, format='JPEG', quality=85)
            state.preview_jpeg = buf.getvalue()

            self.send_response(200)
            self.send_header('Content-Type', 'image/jpeg')
            self.send_header('Content-Length', len(state.preview_jpeg))
            self.end_headers()
            self.wfile.write(state.preview_jpeg)

        except Exception as e:
            data = json.dumps({'error': str(e)}).encode()
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data)

    def _handle_scan(self, params):
        if state.scanner is None:
            error_msg = state.scanner_error or "No scanner connected"
            self.send_response(503)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'error': error_msg,
                'offline': True
            }).encode())
            return

        try:
            dpi = params.get('dpi', 3200)
            mode = params.get('mode', 'rgb+ir')
            x_in = params.get('x', 0)
            y_in = params.get('y', 0)
            w_in = params.get('w', state.tpu_width_in)
            h_in = params.get('h', state.tpu_height_in)
            
            print(f"DEBUG: Scan request - x:{x_in:.2f}\" y:{y_in:.2f}\" w:{w_in:.2f}\" h:{h_in:.2f}\"")
            print(f"DEBUG: TPU limits - w:{state.tpu_width_in:.2f}\" h:{state.tpu_height_in:.2f}\"")

            state.cancel_requested = False
            scan_start = time.time()

            def _check_cancel():
                return state.cancel_requested

            def _fmt_elapsed():
                e = int(time.time() - scan_start)
                return f"{e//60}m{e%60:02d}s" if e >= 60 else f"{e}s"

            def _fmt_eta(secs):
                s = int(secs)
                return f"{s//60}m{s%60:02d}s" if s >= 60 else f"{s}s"

            lut_r, lut_g, lut_b = None, None, None
            if state.last_preview_arr is not None and w_in > 0 and h_in > 0:
                px = int((state.tpu_width_in - x_in - w_in) * state.preview_dpi)
                py = int(y_in * state.preview_dpi)
                pw = int(w_in * state.preview_dpi)
                ph = int(h_in * state.preview_dpi)
                exposure_mode = params.get('exposure', 'linear')
                print(f"Computing LUTs from preview selection ({pw}x{ph} at ({px},{py}), {exposure_mode})...")
                lut_r, lut_g, lut_b = compute_film_luts(
                    state.last_preview_arr, px, py, pw, ph, mode=exposure_mode)
                if lut_r:
                    print(f"  LUTs computed: R[128]={lut_r[128]} G[128]={lut_g[128]} B[128]={lut_b[128]}")
                else:
                    print("  No film detected, using identity LUTs")

            scan_args = dict(
                dpi=dpi, x=x_in, y=y_in, width=w_in, height=h_in,
                source='tpu', lut_r=lut_r, lut_g=lut_g, lut_b=lut_b,
            )

            if mode == 'rgb+ir':
                filename = f"scan_{state.scan_counter:04d}_rgbir_{dpi}dpi.tiff"
                filepath = os.path.join(state.output_dir, filename)

                ir_dpi = min(dpi, 3200)
                ir_pixel_ratio = (ir_dpi / dpi) ** 2
                rgb_weight = 3.0 / (3.0 + ir_pixel_ratio)
                ir_weight = ir_pixel_ratio / (3.0 + ir_pixel_ratio)

                def _progress_rgb(pct, eta):
                    total_pct = int(pct * rgb_weight)
                    total_eta = eta + eta / max(pct, 1) * 100 * ir_weight
                    state.scan_status = (f"RGB {pct}% — "
                                       f"total {total_pct}%, "
                                       f"ETA {_fmt_eta(total_eta)}, "
                                       f"elapsed {_fmt_elapsed()}")

                def _progress_ir(pct, eta):
                    total_pct = int(100 * rgb_weight + pct * ir_weight)
                    state.scan_status = (f"IR {pct}% — "
                                       f"total {total_pct}%, "
                                       f"ETA {_fmt_eta(eta)}, "
                                       f"elapsed {_fmt_elapsed()}")

                state.scanning = True
                state.scan_status = f"Pass 1/2: Scanning RGB at {dpi} DPI..."
                with state.scanner_lock:
                    rgb = state.scanner.scan(
                        **scan_args, color=True, depth=16, ir=False,
                        progress_cb=_progress_rgb, cancel_cb=_check_cancel,
                    )

                ir_args = dict(scan_args)
                ir_args['dpi'] = ir_dpi
                ir_args['lut_r'] = None
                ir_args['lut_g'] = None
                ir_args['lut_b'] = None
                state.scan_status = f"Pass 2/2: Scanning IR at {ir_dpi} DPI..."
                with state.scanner_lock:
                    ir = state.scanner.scan(
                        **ir_args, color=False, depth=8, ir=True,
                        progress_cb=_progress_ir, cancel_cb=_check_cancel,
                    )

                thumb_h = min(256, rgb.shape[0])
                thumb_scale = thumb_h / rgb.shape[0]
                thumb_w = int(rgb.shape[1] * thumb_scale)
                rgb8 = (rgb >> 8).astype(np.uint8)
                pil_thumb = PILImage.fromarray(rgb8).resize(
                    (thumb_w, thumb_h), PILImage.LANCZOS)
                thumb = np.array(pil_thumb)

                meta = state.scanner._tiff_metadata(dpi, lut_r, lut_g, lut_b)
                ir_meta = state.scanner._tiff_metadata(ir_dpi)

                with tifffile.TiffWriter(filepath) as tw:
                    tw.write(rgb, **meta)
                    tw.write(thumb)
                    tw.write(ir, **ir_meta)

                state.scan_status = f"Saved: {filename}"
                print(f"Saved: {filepath} (RGB {rgb.shape}, IR {ir.shape})")

            else:
                ir_mode = mode == 'ir'
                mode_tag = 'ir' if ir_mode else 'rgb'
                filename = f"scan_{state.scan_counter:04d}_{mode_tag}_{dpi}dpi.tiff"
                filepath = os.path.join(state.output_dir, filename)

                state.scanning = True
                state.scan_status = f"Scanning {mode_tag.upper()} at {dpi} DPI..."

                def _progress_single(pct, eta):
                    state.scan_status = (f"{mode_tag.upper()} {pct}% — "
                                       f"ETA {_fmt_eta(eta)}, "
                                       f"elapsed {_fmt_elapsed()}")

                if ir_mode:
                    scan_args['lut_r'] = None
                    scan_args['lut_g'] = None
                    scan_args['lut_b'] = None

                with state.scanner_lock:
                    state.scanner.scan(
                        **scan_args,
                        color=(not ir_mode),
                        depth=8 if ir_mode else 16,
                        ir=ir_mode,
                        output=filepath,
                        progress_cb=_progress_single,
                        cancel_cb=_check_cancel,
                    )

                state.scan_status = f"Saved: {filename}"

            state.scan_counter += 1
            state.scanning = False

            data = json.dumps({'filename': filename}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data)

        except Exception as e:
            state.scanning = False
            state.scan_status = f"Error: {e}"
            data = json.dumps({'error': str(e)}).encode()
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data)


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def main():
    import sys
    import os
    # Add parent dir to path so we can import scanner from root
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    from scanner import EpsonScanner
    
    parser = argparse.ArgumentParser(description='Epson Scanner GUI')
    parser.add_argument('--port', type=int, default=8432,
                        help='Web server port (default: 8432)')
    parser.add_argument('--output-dir', type=str, default='scans',
                        help='Output directory (default: scans/)')
    args = parser.parse_args()

    state.output_dir = args.output_dir
    os.makedirs(state.output_dir, exist_ok=True)

    cfg_mod.CONFIG_FILE = Path(os.path.join(state.output_dir, "epdaughter_config.toml"))

    global scan_counter
    existing = [f for f in os.listdir(state.output_dir) if f.startswith('scan_') and f.endswith('.tiff')]
    if existing:
        nums = []
        for f in existing:
            try:
                nums.append(int(f.split('_')[1]))
            except (IndexError, ValueError):
                pass
        if nums:
            state.scan_counter = max(nums) + 1

    try:
        state.scanner = EpsonScanner()
        state.scanner.open()
        print("Scanner connected")
    except RuntimeError as e:
        print(f"Warning: {e}")
        print("Starting GUI in offline mode - scanner operations will be disabled")
        state.scanner_error = str(e)
        state.scanner = None
    except Exception as e:
        print(f"Unexpected error initializing scanner: {e}")
        state.scanner_error = str(e)
        state.scanner = None

    server = None
    try:
        server = ThreadedHTTPServer(('127.0.0.1', args.port), Handler)
        url = f'http://127.0.0.1:{args.port}'
        print(f"GUI: {url}")

        import webbrowser
        webbrowser.open(url)

        server.serve_forever()
        
    except KeyboardInterrupt:
        print("\nShutting down...")
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
    finally:
        print("Cleaning up resources...")
        if state.scanner:
            try:
                state.scanner.close()
                print("Scanner released")
            except Exception as e:
                print(f"Error closing scanner: {e}")
        if server:
            try:
                server.shutdown()
                print("Server stopped")
            except Exception as e:
                print(f"Error stopping server: {e}")


if __name__ == '__main__':
    main()