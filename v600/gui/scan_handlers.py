"""Scanner state and HTTP route handlers.

All routes are served under the /scan/ prefix. The sub_path parameter
passed to handle_get/handle_post has the prefix already stripped
(e.g. "/scan/preview" arrives as "/preview").
"""

import io
import json
import os
import threading
import time

import numpy as np
from PIL import Image as PILImage
import tifffile

from v600.config import settings as cfg_mod
from v600.imaging.film import detect_film_area, compute_film_luts


class ScannerState:
    """Global state for scanner operations."""
    def __init__(self):
        self.scanner = None
        self.scanner_lock = threading.Lock()
        self.scanner_error = None
        self.scanner_connecting = False
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


def init(scanner, output_dir):
    """Initialize scanner state with an open scanner and output directory."""
    state.scanner = scanner
    state.output_dir = output_dir
    os.makedirs(output_dir, exist_ok=True)

    # Resume scan counter from existing files
    existing = [f for f in os.listdir(output_dir)
                if f.startswith('scan_') and f.endswith('.tiff')]
    if existing:
        nums = []
        for f in existing:
            try:
                nums.append(int(f.split('_')[1]))
            except (IndexError, ValueError):
                pass
        if nums:
            state.scan_counter = max(nums) + 1


def _respond(handler, code, content_type, data):
    try:
        handler.send_response(code)
        handler.send_header('Content-Type', content_type)
        handler.send_header('Content-Length', len(data))
        handler.end_headers()
        handler.wfile.write(data)
    except BrokenPipeError:
        pass


def _respond_json(handler, code, obj):
    _respond(handler, code, 'application/json', json.dumps(obj).encode())


def handle_get(handler, sub_path):
    """Handle GET requests under /scan/."""
    if sub_path == '/':
        from .scan_ui import get_html
        _respond(handler, 200, 'text/html', get_html().encode())

    elif sub_path == '/info':
        preview_w = 0
        preview_h = 0
        if state.last_preview_arr is not None:
            preview_h, preview_w = state.last_preview_arr.shape[:2]
        _respond_json(handler, 200, {
            'preview_w': preview_w,
            'preview_h': preview_h,
            'tpu_width': state.tpu_width_in,
            'tpu_height': state.tpu_height_in,
            'scan_counter': state.scan_counter,
        })

    elif sub_path == '/detect':
        result = {}
        if state.last_preview_arr is not None:
            area = detect_film_area(
                state.last_preview_arr, state.preview_dpi,
                state.tpu_width_in, state.tpu_height_in)
            if area:
                result = dict(
                    sel_x_in=area[0], sel_y_in=area[1],
                    sel_w_in=area[2], sel_h_in=area[3])
        _respond_json(handler, 200, result)

    elif sub_path == '/preview':
        if state.preview_jpeg:
            _respond(handler, 200, 'image/jpeg', state.preview_jpeg)
        else:
            handler.send_error(404)

    elif sub_path == '/config':
        _respond_json(handler, 200, cfg_mod.load_config())

    elif sub_path == '/status':
        _respond_json(handler, 200, {
            'status': state.scan_status,
            'scanning': state.scanning,
            'connecting': state.scanner_connecting,
            'connected': state.scanner is not None,
        })

    else:
        handler.send_error(404)


def handle_post(handler, sub_path):
    """Handle POST requests under /scan/."""
    if sub_path == '/preview':
        _handle_preview(handler)

    elif sub_path == '/start':
        length = int(handler.headers.get('Content-Length', 0))
        body = json.loads(handler.rfile.read(length)) if length else {}
        _handle_scan(handler, body)

    elif sub_path == '/cancel':
        state.cancel_requested = True
        _respond_json(handler, 200, {'ok': True})

    elif sub_path == '/config':
        length = int(handler.headers.get('Content-Length', 0))
        body = json.loads(handler.rfile.read(length)) if length else {}
        cfg_mod.save_config(body)
        _respond_json(handler, 200, {'ok': True})

    else:
        handler.send_error(404)


def _handle_preview(handler):
    if state.scanner is None:
        if state.scanner_connecting:
            _respond_json(handler, 503, {'error': 'Scanner connecting, please wait...', 'offline': True})
        else:
            error_msg = state.scanner_error or "No scanner connected"
            _respond_json(handler, 503, {'error': error_msg, 'offline': True})
        return

    try:
        with state.scanner_lock:
            start_time = time.time()
            print(f"[{time.time()-start_time:.2f}s] Preview scan started")

            caps = state.scanner.get_scanner_capabilities()
            state.tpu_width_in = caps['tpu_width_in']
            state.tpu_height_in = caps['tpu_height_in']

            print(f"[{time.time()-start_time:.2f}s] TPU: {state.tpu_width_in:.1f}\" x {state.tpu_height_in:.1f}\"")

            arr = state.scanner.scan(
                dpi=state.preview_dpi,
                x=0, y=0, width=state.tpu_width_in, height=state.tpu_height_in,
                source='tpu', color=True, depth=8,
            )
            print(f"[{time.time()-start_time:.2f}s] Scan complete: {arr.shape}")

        state.last_preview_arr = arr

        pil_img = PILImage.fromarray(arr)
        buf = io.BytesIO()
        pil_img.save(buf, format='JPEG', quality=85)
        state.preview_jpeg = buf.getvalue()

        _respond(handler, 200, 'image/jpeg', state.preview_jpeg)

    except Exception as e:
        _respond_json(handler, 500, {'error': str(e)})


def _handle_scan(handler, params):
    if state.scanner is None:
        if state.scanner_connecting:
            _respond_json(handler, 503, {'error': 'Scanner connecting, please wait...', 'offline': True})
        else:
            error_msg = state.scanner_error or "No scanner connected"
            _respond_json(handler, 503, {'error': error_msg, 'offline': True})
        return

    try:
        dpi = params.get('dpi', 3200)
        mode = params.get('mode', 'rgb+ir')
        x_in = params.get('x', 0)
        y_in = params.get('y', 0)
        w_in = params.get('w', state.tpu_width_in)
        h_in = params.get('h', state.tpu_height_in)

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

        # Compute LUTs from preview selection
        lut_r, lut_g, lut_b = None, None, None
        if state.last_preview_arr is not None and w_in > 0 and h_in > 0:
            px = int((state.tpu_width_in - x_in - w_in) * state.preview_dpi)
            py = int(y_in * state.preview_dpi)
            pw = int(w_in * state.preview_dpi)
            ph = int(h_in * state.preview_dpi)
            exposure_mode = params.get('exposure', 'linear')
            print(f"Computing LUTs ({pw}x{ph} at ({px},{py}), {exposure_mode})...")
            lut_r, lut_g, lut_b = compute_film_luts(
                state.last_preview_arr, px, py, pw, ph, mode=exposure_mode)
            if lut_r:
                print(f"  LUTs: R[128]={lut_r[128]} G[128]={lut_g[128]} B[128]={lut_b[128]}")
            else:
                print("  No film detected, identity LUTs")

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
                state.scan_status = (f"RGB {pct}% — total {total_pct}%, "
                                     f"ETA {_fmt_eta(total_eta)}, elapsed {_fmt_elapsed()}")

            def _progress_ir(pct, eta):
                total_pct = int(100 * rgb_weight + pct * ir_weight)
                state.scan_status = (f"IR {pct}% — total {total_pct}%, "
                                     f"ETA {_fmt_eta(eta)}, elapsed {_fmt_elapsed()}")

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
                                     f"ETA {_fmt_eta(eta)}, elapsed {_fmt_elapsed()}")

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

        _respond_json(handler, 200, {'filename': filename})

    except Exception as e:
        state.scanning = False
        state.scan_status = f"Error: {e}"
        _respond_json(handler, 500, {'error': str(e)})
