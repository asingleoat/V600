#!/usr/bin/env python3
"""
Web GUI for the Epson V600 scanner.

Provides a browser-based interface for:
- Preview scanning (low-res TPU transparency area)
- Rectangular area selection on the preview
- Full-resolution scanning of selected area
- RGB and IR modes with auto-incrementing filenames
"""

import argparse
import io
import json
import os
import struct
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

import numpy as np

from scanner import EpsonV600, VALID_RESOLUTIONS, VALID_IR_RESOLUTIONS, detect_film_area

# Global state
scanner = None
scanner_lock = threading.Lock()
preview_jpeg = None
preview_scale = 1.0      # preview pixels per scanner inch
preview_dpi = 200         # preview scan resolution (TPU minimum is 200)
tpu_width_in = 0.0        # TPU area width in inches
tpu_height_in = 0.0       # TPU area height in inches
scan_counter = 1          # auto-incrementing filename counter
output_dir = "."
scanning = False          # True while a scan is in progress
last_preview_arr = None   # raw preview array for film detection
scan_status = ""          # status message for the UI
cancel_requested = False  # set True to abort current scan
config_path = ""          # path to GUI config file


def load_config():
    """Load persisted GUI state from config file."""
    if config_path and os.path.exists(config_path):
        with open(config_path) as f:
            return json.load(f)
    return {}


def save_config(cfg):
    """Save GUI state to config file."""
    if config_path:
        with open(config_path, 'w') as f:
            json.dump(cfg, f, indent=2)


def get_html():
    return r"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Epson V600 Scanner</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background: #1a1a1a; color: #eee; font-family: system-ui, sans-serif; overflow: hidden; }
#toolbar {
    position: fixed; top: 0; left: 0; right: 0; height: 48px; z-index: 100;
    background: #2a2a2a; display: flex; align-items: center; padding: 0 16px; gap: 12px;
    border-bottom: 1px solid #444;
}
#toolbar label { font-size: 13px; color: #aaa; }
#toolbar select, #toolbar button {
    font-size: 13px; padding: 4px 10px; border-radius: 4px; border: 1px solid #555;
    background: #333; color: #eee; cursor: pointer;
}
#toolbar button:hover { background: #444; }
#toolbar button.primary { background: #2d6; color: #111; border-color: #2d6; font-weight: 600; }
#toolbar button.primary:hover { background: #3e7; }
#toolbar button.danger { background: #d44; color: #fff; border-color: #d44; font-weight: 600; }
#toolbar button.danger:hover { background: #e55; }
#toolbar .sep { width: 1px; height: 24px; background: #555; }
#canvas-wrap {
    position: fixed; top: 48px; left: 0; right: 0; bottom: 28px; overflow: hidden;
}
canvas { position: absolute; top: 0; left: 0; cursor: crosshair; }
#status {
    position: fixed; bottom: 0; left: 0; right: 0; height: 28px;
    background: #2a2a2a; border-top: 1px solid #444; padding: 0 16px;
    font-size: 12px; line-height: 28px; color: #888; z-index: 100;
}
#status.busy { color: #fb4; }
.no-preview {
    position: fixed; top: 48px; left: 0; right: 0; bottom: 28px;
    display: flex; align-items: center; justify-content: center;
    color: #666; font-size: 18px;
}
</style>
</head>
<body>
<div id="toolbar">
    <button id="btn-preview" class="primary">Preview</button>
    <label style="cursor:pointer"><input type="checkbox" id="chk-autoselect" checked> Auto-select</label>
    <span class="sep"></span>
    <label>DPI:</label>
    <select id="sel-dpi">
        <option value="800">800</option>
        <option value="1200">1200</option>
        <option value="1600">1600</option>
        <option value="3200" selected>3200</option>
        <option value="6400">6400</option>
    </select>
    <label>Mode:</label>
    <select id="sel-mode">
        <option value="rgb+ir" selected>RGB + IR</option>
        <option value="rgb">RGB only</option>
        <option value="ir">IR only</option>
    </select>
    <span class="sep"></span>
    <button id="btn-scan" class="primary">Scan Selection</button>
    <button id="btn-cancel" class="danger" style="display:none">Cancel</button>
    <span class="sep"></span>
    <span id="scan-info" style="font-size:12px;color:#888"></span>
</div>
<div id="no-preview" class="no-preview">Click "Preview" to scan the transparency area</div>
<div id="canvas-wrap" style="display:none">
    <canvas id="canvas"></canvas>
</div>
<div id="status">Ready</div>

<script>
const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');
const wrap = document.getElementById('canvas-wrap');
let img = null;        // preview Image object
let imgW = 0, imgH = 0;
let scale = 1, offsetX = 0, offsetY = 0;

// Selection rectangle in image coordinates (pixels in preview image)
let sel = null;  // {x, y, w, h} or null
let dragging = null; // null, 'draw', 'move', 'resize-XX'
let dragStart = {mx: 0, my: 0, x: 0, y: 0, w: 0, h: 0};

// Resize handles
const HANDLE_SIZE = 8;
const HANDLE_NAMES = ['nw','n','ne','e','se','s','sw','w'];

function resize() {
    canvas.width = wrap.clientWidth;
    canvas.height = wrap.clientHeight;
    draw();
}

function fitImage() {
    if (!img) return;
    const pad = 20;
    const sx = (canvas.width - pad*2) / imgW;
    const sy = (canvas.height - pad*2) / imgH;
    scale = Math.min(sx, sy);
    offsetX = (canvas.width - imgW * scale) / 2;
    offsetY = (canvas.height - imgH * scale) / 2;
}

function imgToScreen(ix, iy) {
    return [ix * scale + offsetX, iy * scale + offsetY];
}
function screenToImg(sx, sy) {
    return [(sx - offsetX) / scale, (sy - offsetY) / scale];
}

function draw() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    if (!img) return;
    ctx.drawImage(img, offsetX, offsetY, imgW * scale, imgH * scale);

    if (sel) {
        const [sx, sy] = imgToScreen(sel.x, sel.y);
        const sw = sel.w * scale;
        const sh = sel.h * scale;

        // Dim outside selection
        ctx.fillStyle = 'rgba(0,0,0,0.5)';
        ctx.fillRect(offsetX, offsetY, imgW * scale, sy - offsetY);
        ctx.fillRect(offsetX, sy, sx - offsetX, sh);
        ctx.fillRect(sx + sw, sy, (offsetX + imgW * scale) - (sx + sw), sh);
        ctx.fillRect(offsetX, sy + sh, imgW * scale, (offsetY + imgH * scale) - (sy + sh));

        // Selection border
        ctx.strokeStyle = '#2d6';
        ctx.lineWidth = 2;
        ctx.strokeRect(sx, sy, sw, sh);

        // Handles
        ctx.fillStyle = '#2d6';
        for (const h of getHandles()) {
            ctx.fillRect(h.sx - HANDLE_SIZE/2, h.sy - HANDLE_SIZE/2, HANDLE_SIZE, HANDLE_SIZE);
        }

        updateScanInfo();
    }
}

function getHandles() {
    if (!sel) return [];
    const [sx, sy] = imgToScreen(sel.x, sel.y);
    const sw = sel.w * scale, sh = sel.h * scale;
    const mx = sx + sw/2, my = sy + sh/2;
    return [
        {name:'nw', sx:sx, sy:sy}, {name:'n', sx:mx, sy:sy},
        {name:'ne', sx:sx+sw, sy:sy}, {name:'e', sx:sx+sw, sy:my},
        {name:'se', sx:sx+sw, sy:sy+sh}, {name:'s', sx:mx, sy:sy+sh},
        {name:'sw', sx:sx, sy:sy+sh}, {name:'w', sx:sx, sy:my},
    ];
}

function hitHandle(mx, my) {
    for (const h of getHandles()) {
        if (Math.abs(mx - h.sx) < HANDLE_SIZE && Math.abs(my - h.sy) < HANDLE_SIZE)
            return h.name;
    }
    return null;
}

function hitSelection(mx, my) {
    if (!sel) return false;
    const [ix, iy] = screenToImg(mx, my);
    return ix >= sel.x && ix <= sel.x + sel.w && iy >= sel.y && iy <= sel.y + sel.h;
}

canvas.addEventListener('mousedown', e => {
    const mx = e.offsetX, my = e.offsetY;

    // Check handles first
    const handle = hitHandle(mx, my);
    if (handle) {
        dragging = 'resize-' + handle;
        dragStart = {mx, my, x: sel.x, y: sel.y, w: sel.w, h: sel.h};
        return;
    }

    // Check move
    if (hitSelection(mx, my)) {
        dragging = 'move';
        dragStart = {mx, my, x: sel.x, y: sel.y, w: sel.w, h: sel.h};
        return;
    }

    // Start new selection
    const [ix, iy] = screenToImg(mx, my);
    if (ix >= 0 && ix <= imgW && iy >= 0 && iy <= imgH) {
        sel = {x: ix, y: iy, w: 0, h: 0};
        dragging = 'draw';
        dragStart = {mx, my, x: ix, y: iy, w: 0, h: 0};
    }
});

canvas.addEventListener('mousemove', e => {
    const mx = e.offsetX, my = e.offsetY;

    if (!dragging) {
        // Update cursor
        const handle = hitHandle(mx, my);
        if (handle) {
            const cursors = {nw:'nw-resize',n:'n-resize',ne:'ne-resize',e:'e-resize',
                             se:'se-resize',s:'s-resize',sw:'sw-resize',w:'w-resize'};
            canvas.style.cursor = cursors[handle];
        } else if (hitSelection(mx, my)) {
            canvas.style.cursor = 'move';
        } else {
            canvas.style.cursor = 'crosshair';
        }
        return;
    }

    const dx = (mx - dragStart.mx) / scale;
    const dy = (my - dragStart.my) / scale;

    if (dragging === 'draw') {
        const x2 = Math.max(0, Math.min(imgW, dragStart.x + dx));
        const y2 = Math.max(0, Math.min(imgH, dragStart.y + dy));
        sel.x = Math.min(dragStart.x, x2);
        sel.y = Math.min(dragStart.y, y2);
        sel.w = Math.abs(x2 - dragStart.x);
        sel.h = Math.abs(y2 - dragStart.y);
    } else if (dragging === 'move') {
        sel.x = Math.max(0, Math.min(imgW - sel.w, dragStart.x + dx));
        sel.y = Math.max(0, Math.min(imgH - sel.h, dragStart.y + dy));
    } else if (dragging.startsWith('resize-')) {
        const dir = dragging.slice(7);
        let {x, y, w, h} = dragStart;
        if (dir.includes('w')) { x += dx; w -= dx; }
        if (dir.includes('e')) { w += dx; }
        if (dir.includes('n')) { y += dy; h -= dy; }
        if (dir.includes('s')) { h += dy; }
        // Normalize negative dimensions
        if (w < 0) { x += w; w = -w; }
        if (h < 0) { y += h; h = -h; }
        // Clamp to image
        x = Math.max(0, x); y = Math.max(0, y);
        w = Math.min(imgW - x, w); h = Math.min(imgH - y, h);
        sel = {x, y, w, h};
    }
    draw();
});

canvas.addEventListener('mouseup', () => {
    if (dragging === 'draw' && sel && (sel.w < 3 || sel.h < 3)) {
        sel = null; // too small, cancel
    }
    dragging = null;
    draw();
});

// Zoom with scroll wheel
canvas.addEventListener('wheel', e => {
    e.preventDefault();
    const mx = e.offsetX, my = e.offsetY;
    const [ix, iy] = screenToImg(mx, my);
    const factor = e.deltaY < 0 ? 1.15 : 1/1.15;
    scale *= factor;
    offsetX = mx - ix * scale;
    offsetY = my - iy * scale;
    draw();
}, {passive: false});

// Delete selection with Escape
document.addEventListener('keydown', e => {
    if (e.key === 'Escape' || e.key === 'Delete') {
        sel = null;
        draw();
    }
});

function updateScanInfo() {
    const info = document.getElementById('scan-info');
    if (!sel || sel.w < 1 || sel.h < 1) {
        info.textContent = '';
        return;
    }
    // Convert preview pixels to inches
    fetch('/info').then(r => r.json()).then(data => {
        const wIn = (sel.w / data.preview_w * data.tpu_width).toFixed(2);
        const hIn = (sel.h / data.preview_h * data.tpu_height).toFixed(2);
        const dpi = parseInt(document.getElementById('sel-dpi').value);
        const outW = Math.round(wIn * dpi);
        const outH = Math.round(hIn * dpi);
        const mode = document.getElementById('sel-mode').value;
        const ch = mode === 'ir' ? 1 : 3;
        const modeLabel = mode === 'rgb+ir' ? 'RGB+IR' : mode.toUpperCase();
        // Estimate data size: RGB is 3ch×16bit, IR is 1ch×16bit
        // For RGB+IR at 6400 DPI, IR scans at 3200 (1/4 the pixels)
        const irDpi = Math.min(dpi, 3200);
        const irW = Math.round(wIn * irDpi), irH = Math.round(hIn * irDpi);
        let dataMb;
        if (mode === 'rgb+ir') {
            dataMb = (outW * outH * 3 * 2 + irW * irH * 1 * 2) / 1024 / 1024;
        } else {
            dataMb = outW * outH * ch * 2 / 1024 / 1024;
        }
        const totalMb = dataMb.toFixed(1);
        // Estimate scan time: ~5 MB/s throughput + ~8s calibration overhead per pass
        const passes = mode === 'rgb+ir' ? 2 : 1;
        const estSecs = Math.round(dataMb / 5 + passes * 8);
        const estStr = fmtTime(estSecs);
        const wMm = (wIn * 25.4).toFixed(1);
        const hMm = (hIn * 25.4).toFixed(1);
        info.textContent = `${wIn}" x ${hIn}" (${wMm} x ${hMm} mm) → ${outW}x${outH}px ${modeLabel} (${totalMb} MB, ${estStr})`;
    });
}

function playDing() {
    try {
        const ctx = new AudioContext();
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.frequency.value = 880;
        osc.type = 'sine';
        gain.gain.setValueAtTime(0.3, ctx.currentTime);
        gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.5);
        osc.start(ctx.currentTime);
        osc.stop(ctx.currentTime + 0.5);
    } catch(e) {}
}

function fmtTime(secs) {
    secs = Math.round(secs);
    if (secs < 60) return `~${secs}s`;
    return `~${Math.floor(secs/60)}m${(secs%60).toString().padStart(2,'0')}s`;
}

function setStatus(msg, busy) {
    const el = document.getElementById('status');
    el.textContent = msg;
    el.className = busy ? 'busy' : '';
}

function setButtonsEnabled(enabled) {
    document.getElementById('btn-preview').disabled = !enabled;
    document.getElementById('btn-scan').disabled = !enabled;
    document.getElementById('btn-scan').style.display = enabled ? '' : 'none';
    document.getElementById('btn-cancel').style.display = enabled ? 'none' : '';
}

// Preview button
document.getElementById('btn-preview').addEventListener('click', async () => {
    setStatus('Scanning preview...', true);
    setButtonsEnabled(false);
    try {
        const resp = await fetch('/preview', {method: 'POST'});
        if (!resp.ok) {
            const err = await resp.json();
            setStatus('Preview failed: ' + err.error, false);
            setButtonsEnabled(true);
            return;
        }
        const blob = await resp.blob();
        const url = URL.createObjectURL(blob);
        img = new Image();
        img.onload = async () => {
            imgW = img.naturalWidth;
            imgH = img.naturalHeight;
            document.getElementById('no-preview').style.display = 'none';
            wrap.style.display = 'block';
            resize();
            fitImage();
            sel = null;

            // Auto-detect film area if enabled
            if (document.getElementById('chk-autoselect').checked) {
                try {
                    const det = await (await fetch('/detect')).json();
                    if (det.sel_x_in !== undefined) {
                        const info = await (await fetch('/info')).json();
                        sel = {
                            x: det.sel_x_in / info.tpu_width * info.preview_w,
                            y: det.sel_y_in / info.tpu_height * info.preview_h,
                            w: det.sel_w_in / info.tpu_width * info.preview_w,
                            h: det.sel_h_in / info.tpu_height * info.preview_h,
                        };
                        saveConfig();
                        setStatus('Film area detected. Adjust selection if needed.', false);
                    } else {
                        setStatus('No film detected. Draw a rectangle manually.', false);
                    }
                } catch(e) {
                    setStatus('Auto-detect failed. Draw a rectangle manually.', false);
                }
            } else {
                applyPendingSelection();
                setStatus('Preview ready. Draw a rectangle to select scan area.', false);
            }

            draw();
            setButtonsEnabled(true);
        };
        img.src = url;
    } catch(e) {
        setStatus('Preview failed: ' + e.message, false);
        setButtonsEnabled(true);
    }
});

// Scan button
document.getElementById('btn-scan').addEventListener('click', async () => {
    if (!sel || sel.w < 3 || sel.h < 3) {
        setStatus('Draw a selection rectangle first.', false);
        return;
    }

    const dpi = parseInt(document.getElementById('sel-dpi').value);
    const mode = document.getElementById('sel-mode').value;

    const modeLabel = mode === 'rgb+ir' ? 'RGB+IR' : mode.toUpperCase();
    setStatus(`Scanning ${modeLabel} at ${dpi} DPI...`, true);
    setButtonsEnabled(false);

    // Poll status while scanning
    const defaultTitle = document.title;
    const pollId = setInterval(async () => {
        try {
            const r = await fetch('/scan-status');
            const d = await r.json();
            if (d.status) {
                setStatus(d.status, true);
                // Extract ETA or percentage for tab title
                const etaMatch = d.status.match(/ETA ([^,]+)/);
                const pctMatch = d.status.match(/total (\d+%)/);
                if (etaMatch) {
                    document.title = `${etaMatch[1]} — Scanner`;
                } else if (pctMatch) {
                    document.title = `${pctMatch[1]} — Scanner`;
                }
            }
        } catch(e) {}
    }, 500);

    try {
        const info = await (await fetch('/info')).json();
        const xIn = sel.x / info.preview_w * info.tpu_width;
        const yIn = sel.y / info.preview_h * info.tpu_height;
        const wIn = sel.w / info.preview_w * info.tpu_width;
        const hIn = sel.h / info.preview_h * info.tpu_height;

        const resp = await fetch('/scan', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({dpi, mode, x: xIn, y: yIn, w: wIn, h: hIn})
        });
        clearInterval(pollId);
        document.title = defaultTitle;
        const result = await resp.json();
        if (result.error) {
            setStatus('Scan failed: ' + result.error, false);
        } else {
            setStatus('Saved: ' + result.filename, false);
            playDing();
        }
    } catch(e) {
        clearInterval(pollId);
        document.title = defaultTitle;
        setStatus('Scan failed: ' + e.message, false);
    }
    setButtonsEnabled(true);
});

// Cancel button
document.getElementById('btn-cancel').addEventListener('click', async () => {
    try {
        await fetch('/cancel', {method: 'POST'});
        setStatus('Cancelling...', true);
    } catch(e) {}
});

// Update info when DPI or mode changes
document.getElementById('sel-dpi').addEventListener('change', () => {
    updateScanInfo();
    // Update DPI options based on mode
    syncDpiOptions();
});
document.getElementById('sel-mode').addEventListener('change', () => {
    syncDpiOptions();
    updateScanInfo();
});

function syncDpiOptions() {
    const mode = document.getElementById('sel-mode').value;
    const dpiSel = document.getElementById('sel-dpi');
    const irOnly = [800, 1600, 3200];
    const rgbOnly = [800, 1200, 1600, 3200, 6400];
    const rgbIr = [800, 1600, 3200, 6400]; // 6400 OK: IR scanned at 3200 and upscaled
    const valid = mode === 'rgb' ? rgbOnly : mode === 'ir' ? irOnly : rgbIr;
    const curVal = parseInt(dpiSel.value);

    dpiSel.innerHTML = '';
    for (const d of valid) {
        const opt = document.createElement('option');
        opt.value = d; opt.textContent = d;
        dpiSel.appendChild(opt);
    }
    // Restore or pick closest
    if (valid.includes(curVal)) {
        dpiSel.value = curVal;
    } else {
        const closest = valid.reduce((a,b) => Math.abs(b-curVal) < Math.abs(a-curVal) ? b : a);
        dpiSel.value = closest;
    }
}

// --- Config persistence ---
// Selection is stored in inches (not preview pixels) so it survives across previews
function saveConfig() {
    if (!sel || sel.w < 1 || sel.h < 1) return;
    fetch('/info').then(r => r.json()).then(data => {
        if (!data.preview_w) return;
        const cfg = {
            sel_x_in: sel.x / data.preview_w * data.tpu_width,
            sel_y_in: sel.y / data.preview_h * data.tpu_height,
            sel_w_in: sel.w / data.preview_w * data.tpu_width,
            sel_h_in: sel.h / data.preview_h * data.tpu_height,
            dpi: parseInt(document.getElementById('sel-dpi').value),
            mode: document.getElementById('sel-mode').value,
            autoselect: document.getElementById('chk-autoselect').checked,
        };
        fetch('/config', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify(cfg),
        });
    });
}

function restoreConfig() {
    fetch('/config').then(r => r.json()).then(cfg => {
        if (cfg.autoselect !== undefined) {
            document.getElementById('chk-autoselect').checked = cfg.autoselect;
        }
        if (cfg.mode) {
            document.getElementById('sel-mode').value = cfg.mode;
            syncDpiOptions();
        }
        if (cfg.dpi) {
            const dpiSel = document.getElementById('sel-dpi');
            for (const opt of dpiSel.options) {
                if (parseInt(opt.value) === cfg.dpi) { dpiSel.value = cfg.dpi; break; }
            }
        }
        // Selection restored after preview loads (needs preview dimensions)
        if (cfg.sel_x_in !== undefined) {
            window._pendingSelection = cfg;
        }
    });
}

function applyPendingSelection() {
    const cfg = window._pendingSelection;
    if (!cfg || !img) return;
    fetch('/info').then(r => r.json()).then(data => {
        if (!data.preview_w) return;
        sel = {
            x: cfg.sel_x_in / data.tpu_width * data.preview_w,
            y: cfg.sel_y_in / data.tpu_height * data.preview_h,
            w: cfg.sel_w_in / data.tpu_width * data.preview_w,
            h: cfg.sel_h_in / data.tpu_height * data.preview_h,
        };
        window._pendingSelection = null;
        draw();
    });
}

// Save on selection change
canvas.addEventListener('mouseup', () => {
    if (sel && sel.w >= 3 && sel.h >= 3) saveConfig();
});
document.getElementById('sel-dpi').addEventListener('change', saveConfig);
document.getElementById('sel-mode').addEventListener('change', saveConfig);
document.getElementById('chk-autoselect').addEventListener('change', saveConfig);

// Restore on page load
restoreConfig();

// Load cached preview if available
fetch('/preview').then(resp => {
    if (!resp.ok) return;
    return resp.blob();
}).then(blob => {
    if (!blob) return;
    const url = URL.createObjectURL(blob);
    img = new Image();
    img.onload = () => {
        imgW = img.naturalWidth;
        imgH = img.naturalHeight;
        document.getElementById('no-preview').style.display = 'none';
        wrap.style.display = 'block';
        resize();
        fitImage();
        applyPendingSelection();
        draw();
        setStatus('Preview loaded. Draw a rectangle to select scan area.', false);
    };
    img.src = url;
});

window.addEventListener('resize', resize);
resize();
</script>
</body>
</html>"""


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
            data = json.dumps({
                'preview_w': int(tpu_width_in * preview_dpi) if preview_jpeg else 0,
                'preview_h': int(tpu_height_in * preview_dpi) if preview_jpeg else 0,
                'tpu_width': tpu_width_in,
                'tpu_height': tpu_height_in,
                'scan_counter': scan_counter,
            })
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data.encode())

        elif self.path == '/detect':
            result = {}
            if last_preview_arr is not None:
                area = detect_film_area(
                    last_preview_arr, preview_dpi,
                    tpu_width_in, tpu_height_in)
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
            if preview_jpeg:
                self.send_response(200)
                self.send_header('Content-Type', 'image/jpeg')
                self.send_header('Content-Length', len(preview_jpeg))
                self.end_headers()
                self.wfile.write(preview_jpeg)
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
            data = json.dumps({'status': scan_status, 'scanning': scanning})
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
            global cancel_requested
            cancel_requested = True
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            return
        elif self.path == '/config':
            length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(length)) if length else {}
            cfg = load_config()
            cfg.update(body)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
        else:
            self.send_error(404)

    def _handle_preview(self):
        global preview_jpeg, preview_dpi, tpu_width_in, tpu_height_in, last_preview_arr

        try:
            with scanner_lock:
                # Read TPU area dimensions
                scanner._cmd(bytes([0x1c, 0x49]))
                eid = scanner._read(80)
                if eid is None:
                    raise RuntimeError("Cannot read scanner identity")

                optical_dpi = struct.unpack_from('<I', eid, 4)[0]
                tpu_x = struct.unpack_from('<I', eid, 36)[0]
                tpu_y = struct.unpack_from('<I', eid, 40)[0]
                tpu_width_in = tpu_x / optical_dpi
                tpu_height_in = tpu_y / optical_dpi

                # Low-res preview scan of entire TPU area
                arr = scanner.scan(
                    dpi=preview_dpi,
                    source='tpu',
                    color=True,
                    depth=8,
                )

            last_preview_arr = arr

            # Convert to JPEG
            from PIL import Image
            pil_img = Image.fromarray(arr)
            buf = io.BytesIO()
            pil_img.save(buf, format='JPEG', quality=85)
            preview_jpeg = buf.getvalue()

            self.send_response(200)
            self.send_header('Content-Type', 'image/jpeg')
            self.send_header('Content-Length', len(preview_jpeg))
            self.end_headers()
            self.wfile.write(preview_jpeg)

        except Exception as e:
            data = json.dumps({'error': str(e)}).encode()
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data)

    def _handle_scan(self, params):
        global scan_counter, scanning, scan_status

        try:
            dpi = params.get('dpi', 3200)
            mode = params.get('mode', 'rgb+ir')
            x_in = params.get('x', 0)
            y_in = params.get('y', 0)
            w_in = params.get('w', tpu_width_in)
            h_in = params.get('h', tpu_height_in)

            global cancel_requested
            cancel_requested = False
            scan_start = time.time()

            def _check_cancel():
                return cancel_requested

            def _fmt_elapsed():
                e = int(time.time() - scan_start)
                return f"{e//60}m{e%60:02d}s" if e >= 60 else f"{e}s"

            def _fmt_eta(secs):
                s = int(secs)
                return f"{s//60}m{s%60:02d}s" if s >= 60 else f"{s}s"

            scan_args = dict(
                dpi=dpi, x=x_in, y=y_in, width=w_in, height=h_in,
                source='tpu',
            )

            if mode == 'rgb+ir':
                filename = f"scan_{scan_counter:04d}_rgbir_{dpi}dpi.tiff"
                filepath = os.path.join(output_dir, filename)

                # Compute relative weights for total progress
                # RGB is 3 channels, IR is 1 channel (possibly at lower DPI)
                ir_dpi = min(dpi, 3200)
                ir_pixel_ratio = (ir_dpi / dpi) ** 2
                rgb_weight = 3.0 / (3.0 + ir_pixel_ratio)
                ir_weight = ir_pixel_ratio / (3.0 + ir_pixel_ratio)

                def _progress_rgb(pct, eta):
                    global scan_status
                    total_pct = int(pct * rgb_weight)
                    total_eta = eta + eta / max(pct, 1) * 100 * ir_weight
                    scan_status = (f"RGB {pct}% — "
                                   f"total {total_pct}%, "
                                   f"ETA {_fmt_eta(total_eta)}, "
                                   f"elapsed {_fmt_elapsed()}")

                def _progress_ir(pct, eta):
                    global scan_status
                    total_pct = int(100 * rgb_weight + pct * ir_weight)
                    scan_status = (f"IR {pct}% — "
                                   f"total {total_pct}%, "
                                   f"ETA {_fmt_eta(eta)}, "
                                   f"elapsed {_fmt_elapsed()}")

                # Pass 1: RGB 16-bit
                scanning = True
                scan_status = f"Pass 1/2: Scanning RGB at {dpi} DPI..."
                with scanner_lock:
                    rgb = scanner.scan(
                        **scan_args, color=True, depth=16, ir=False,
                        progress_cb=_progress_rgb, cancel_cb=_check_cancel,
                    )

                # Pass 2: IR mono (max 3200 DPI — upscale if needed)
                ir_args = dict(scan_args)
                ir_args['dpi'] = ir_dpi
                scan_status = f"Pass 2/2: Scanning IR at {ir_dpi} DPI..."
                with scanner_lock:
                    ir = scanner.scan(
                        **ir_args, color=False, depth=16, ir=True,
                        progress_cb=_progress_ir, cancel_cb=_check_cancel,
                    )

                # Upscale IR to match RGB dimensions if needed
                if ir.shape != rgb.shape[:2]:
                    import cv2
                    ir = cv2.resize(ir, (rgb.shape[1], rgb.shape[0]),
                                    interpolation=cv2.INTER_LANCZOS4)

                # Write multi-page TIFF (SilverFast format):
                #   page 0: RGB 16-bit (H, W, 3)
                #   page 1: thumbnail (small RGB)
                #   page 2: IR 16-bit grayscale (H, W)
                import tifffile
                from PIL import Image as PILImage

                # Generate thumbnail (page 1)
                thumb_h = min(256, rgb.shape[0])
                thumb_scale = thumb_h / rgb.shape[0]
                thumb_w = int(rgb.shape[1] * thumb_scale)
                rgb8 = (rgb >> 8).astype(np.uint8)
                pil_thumb = PILImage.fromarray(rgb8).resize(
                    (thumb_w, thumb_h), PILImage.LANCZOS)
                thumb = np.array(pil_thumb)

                meta = scanner._tiff_metadata(dpi)
                ir_meta = scanner._tiff_metadata(ir_dpi)

                with tifffile.TiffWriter(filepath) as tw:
                    tw.write(rgb, **meta)       # page 0: RGB
                    tw.write(thumb)              # page 1: thumbnail
                    tw.write(ir, **ir_meta)      # page 2: IR

                scan_status = f"Saved: {filename}"
                print(f"Saved: {filepath} (RGB {rgb.shape}, IR {ir.shape})")

            else:
                ir_mode = mode == 'ir'
                mode_tag = 'ir' if ir_mode else 'rgb'
                filename = f"scan_{scan_counter:04d}_{mode_tag}_{dpi}dpi.tiff"
                filepath = os.path.join(output_dir, filename)

                scanning = True
                scan_status = f"Scanning {mode_tag.upper()} at {dpi} DPI..."

                def _progress_single(pct, eta):
                    global scan_status
                    scan_status = (f"{mode_tag.upper()} {pct}% — "
                                   f"ETA {_fmt_eta(eta)}, "
                                   f"elapsed {_fmt_elapsed()}")

                with scanner_lock:
                    scanner.scan(
                        **scan_args,
                        color=(not ir_mode),
                        depth=16,
                        ir=ir_mode,
                        output=filepath,
                        progress_cb=_progress_single,
                        cancel_cb=_check_cancel,
                    )

                scan_status = f"Saved: {filename}"

            scan_counter += 1
            scanning = False

            data = json.dumps({'filename': filename}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data)

        except Exception as e:
            scanning = False
            scan_status = f"Error: {e}"
            data = json.dumps({'error': str(e)}).encode()
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(data)


def main():
    global scanner, output_dir, config_path

    parser = argparse.ArgumentParser(description='Epson V600 Scanner GUI')
    parser.add_argument('--port', type=int, default=8432,
                        help='Web server port (default: 8432)')
    parser.add_argument('--output-dir', type=str, default='scans',
                        help='Output directory (default: scans/)')
    args = parser.parse_args()

    output_dir = args.output_dir
    os.makedirs(output_dir, exist_ok=True)

    config_path = os.path.join(output_dir, ".scanner_config.json")

    # Find existing scan files to set counter
    global scan_counter
    existing = [f for f in os.listdir(output_dir) if f.startswith('scan_') and f.endswith('.tiff')]
    if existing:
        nums = []
        for f in existing:
            try:
                nums.append(int(f.split('_')[1]))
            except (IndexError, ValueError):
                pass
        if nums:
            scan_counter = max(nums) + 1

    # Initialize scanner
    scanner = EpsonV600()
    scanner.open()
    print(f"Scanner connected")

    # Start threaded server (allows status polling during scans)
    class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
        daemon_threads = True

    server = ThreadedHTTPServer(('127.0.0.1', args.port), Handler)
    url = f'http://127.0.0.1:{args.port}'
    print(f"GUI: {url}")

    # Open browser
    import webbrowser
    webbrowser.open(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        scanner.close()


if __name__ == '__main__':
    main()
