#!/usr/bin/env python3
"""Test frame detection against manual ground truth.

Runs detect_frames on scan_0001 and compares to the manually-selected
frame rectangles from the UI.
"""

import sys
import time
import numpy as np
import cv2
import tifffile

from scratchndent.processing.frames.detection import detect_frames

TEST_CASES = [
    {
        "name": "scan_0001 (2-frame strip)",
        "scan": "scans/scan_0001_rgbir_3200dpi.tiff",
        "format": "35mm",
        "n_frames": 2,
        "preview_scale": 0.7201,
        "ground_truth": [
            {"x": 723.3, "y": 1366.7, "w": 2198.1, "h": 3299.0, "angle": 0.0051},
            {"x": 712.8, "y": 4801.1, "w": 2203.9, "h": 3305.8, "angle": 0.0031},
        ],
    },
    {
        "name": "scan_0003 (4-frame strip)",
        "scan": "scans/scan_0003_rgbir_3200dpi.tiff",
        "format": "35mm",
        "n_frames": 4,
        "preview_scale": 0.3871,
        "ground_truth": [
            {"x": 408.2, "y": 735.9, "w": 1183.1, "h": 1773.0, "angle": 0.0030},
            {"x": 402.5, "y": 2585.8, "w": 1181.9, "h": 1774.0, "angle": 0.0034},
            {"x": 390.2, "y": 4434.6, "w": 1178.7, "h": 1774.0, "angle": -0.0007},
            {"x": 379.0, "y": 6288.7, "w": 1186.5, "h": 1778.0, "angle": 0.0014},
        ],
    },
    {
        "name": "scan_0006 (5-frame 800dpi)",
        "scan": "scans/scan_0006_rgbir_800dpi.tiff",
        "format": "35mm",
        "n_frames": 5,
        "preview_scale": 1.0000,
        "ground_truth": [
            {"x": 334.4, "y": 59.1, "w": 764.0, "h": 1145.9, "angle": 0.0304},
            {"x": 303.4, "y": 1257.5, "w": 764.9, "h": 1148.0, "angle": 0.0297},
            {"x": 268.9, "y": 2462.0, "w": 766.1, "h": 1146.0, "angle": 0.0288},
            {"x": 236.8, "y": 3650.6, "w": 766.6, "h": 1148.0, "angle": 0.0263},
            {"x": 209.7, "y": 4851.4, "w": 768.0, "h": 1151.0, "angle": 0.0267},
        ],
    },
    {
        "name": "scan_0004 (5-frame strip)",
        "scan": "scans/scan_0004_rgbir_3200dpi.tiff",
        "format": "35mm",
        "n_frames": 5,
        "preview_scale": 0.3396,
        "ground_truth": [
            {"x": 468.0, "y": 80.1, "w": 1037.3, "h": 1556.0, "angle": 0.0318},
            {"x": 425.8, "y": 1706.5, "w": 1039.2, "h": 1559.0, "angle": 0.0296},
            {"x": 382.7, "y": 3342.0, "w": 1038.1, "h": 1557.0, "angle": 0.0282},
            {"x": 341.7, "y": 4956.4, "w": 1037.8, "h": 1559.0, "angle": 0.0261},
            {"x": 298.9, "y": 6574.7, "w": 1040.7, "h": 1561.1, "angle": 0.0268},
        ],
    },
]


def load_preview(path):
    """Load and downscale to the same preview resolution the UI uses."""
    with tifffile.TiffFile(path) as tif:
        img = tif.pages[0].asarray()
    h, w = img.shape[:2]
    preview_size = 8192
    scale = min(preview_size / max(h, w), 1.0)
    if scale < 1.0:
        pw, ph = int(w * scale), int(h * scale)
        img = cv2.resize(img, (pw, ph), interpolation=cv2.INTER_AREA)
    # Ensure 3-channel uint16
    if img.ndim == 2:
        img = cv2.cvtColor(img, cv2.COLOR_GRAY2RGB)
    if img.dtype != np.uint16:
        img = img.astype(np.uint16) * 257
    return img, scale


def compare(detected, ground_truth, preview_scale, gt_preview):
    """Compare detected frames to ground truth, print diagnostics."""
    print(f"\n{'='*60}")
    print(f"  COMPARISON: {len(detected)} detected vs {len(ground_truth)} ground truth")
    print(f"{'='*60}")

    for i, gt in enumerate(ground_truth):
        print(f"\n  Ground truth frame {i+1}:")
        print(f"    cx={gt['cx']:.0f}  cy={gt['cy']:.0f}  "
              f"w={gt['w']:.0f}  h={gt['h']:.0f}")

        if i < len(detected):
            det = detected[i]
            # detected frames are in preview coords: {cx, cy, w, h, angle}
            # convert to full-res for comparison
            dcx = det["cx"] / preview_scale
            dcy = det["cy"] / preview_scale
            dw = det["w"] / preview_scale
            dh = det["h"] / preview_scale
            dangle = det["angle"]

            dx = dcx - gt["cx"]
            dy = dcy - gt["cy"]
            dw_err = dw - gt["w"]
            dh_err = dh - gt["h"]

            # Ground truth angle from preview-coord selections
            gt_angle = gt_preview[i]["angle"]
            angle_err_deg = np.degrees(dangle - gt_angle)

            print(f"  Detected frame {i+1}:")
            print(f"    cx={dcx:.0f}  cy={dcy:.0f}  "
                  f"w={dw:.0f}  h={dh:.0f}  "
                  f"angle={np.degrees(dangle):+.3f} deg")
            print(f"  Error:")
            print(f"    cx: {dx:+.0f}px   cy: {dy:+.0f}px   "
                  f"w: {dw_err:+.0f}px   h: {dh_err:+.0f}px   "
                  f"angle: {angle_err_deg:+.3f} deg")

            # Score: RMS of center offset and dimension error
            rms = np.sqrt(dx**2 + dy**2 + dw_err**2 + dh_err**2)
            print(f"    RMS error: {rms:.0f}px")
        else:
            print(f"  ** NO DETECTION FOR THIS FRAME **")

    print()


def gt_to_full(gt_preview, preview_scale):
    """Convert ground truth from preview top-left coords to full-res center coords."""
    out = []
    for gt in gt_preview:
        out.append({
            "cx": (gt["x"] + gt["w"] / 2) / preview_scale,
            "cy": (gt["y"] + gt["h"] / 2) / preview_scale,
            "w":  gt["w"] / preview_scale,
            "h":  gt["h"] / preview_scale,
        })
    return out


def run_test(tc):
    scan = tc["scan"]
    fmt = tc["format"]
    n_frames = tc.get("n_frames")
    preview_scale = tc["preview_scale"]
    gt_full = gt_to_full(tc["ground_truth"], preview_scale)

    print(f"Loading {scan}...")
    img, scale = load_preview(scan)
    print(f"Preview: {img.shape[1]}x{img.shape[0]}, scale={scale:.4f}")

    t0 = time.monotonic()
    result = detect_frames(img, fmt, n_frames=n_frames)
    elapsed = time.monotonic() - t0

    frames = result["frames"]
    aspect = result.get("aspect")

    print(f"\nDetected {len(frames)} frames (aspect {aspect}) in {elapsed:.2f}s")
    for i, f in enumerate(frames):
        fw = f["w"] / scale
        fh = f["h"] / scale
        print(f"  Frame {i+1}: {fw:.0f}x{fh:.0f}px full-res, "
              f"angle {np.degrees(f['angle']):+.3f} deg")

    compare(frames, gt_full, scale, tc["ground_truth"])


def main():
    # Run specific test if given as arg, otherwise all
    which = sys.argv[1] if len(sys.argv) > 1 else None
    for tc in TEST_CASES:
        if which and which not in tc["scan"]:
            continue
        print(f"\n{'#'*60}")
        print(f"# {tc['name']}")
        print(f"{'#'*60}\n")
        run_test(tc)


if __name__ == "__main__":
    main()
