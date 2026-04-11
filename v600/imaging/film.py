"""Film detection and LUT computation for Epson V600 scanner."""

import numpy as np
from scipy import ndimage


def detect_film_area(preview, preview_dpi, tpu_width_in, tpu_height_in, pad=0.0125):
    """Detect the film area in a preview scan image.

    Finds the largest dark region (film is darker than the clear TPU
    background) and returns its bounding box in inches with padding.

    Args:
        preview: numpy array (H, W, 3) uint8 or uint16 preview image
        preview_dpi: DPI of the preview scan
        tpu_width_in: TPU area width in inches
        tpu_height_in: TPU area height in inches
        pad: fractional padding to add around the detected area (default 5%)

    Returns:
        (x_in, y_in, w_in, h_in) tuple in inches, or None if no film detected
    """
    # Convert to grayscale float
    if preview.ndim == 3:
        gray = preview.astype(np.float32).mean(axis=2)
    else:
        gray = preview.astype(np.float32)

    # Threshold: midpoint between 25th and 75th percentile
    # This works because the histogram is bimodal (dark film + bright background)
    p25 = np.percentile(gray, 25)
    p75 = np.percentile(gray, 75)
    thresh = (p25 + p75) / 2
    dark_mask = gray < thresh

    # Find connected components, pick the largest
    labeled, n_features = ndimage.label(dark_mask)
    if n_features == 0:
        return None

    sizes = ndimage.sum(dark_mask, labeled, range(1, n_features + 1))
    largest = np.argmax(sizes) + 1

    # Reject if the largest region is too small (< 5% of image)
    if sizes[largest - 1] < dark_mask.size * 0.05:
        return None

    largest_mask = labeled == largest

    # Bounding box
    rows = np.any(largest_mask, axis=1)
    cols = np.any(largest_mask, axis=0)
    rmin, rmax = np.where(rows)[0][[0, -1]]
    cmin, cmax = np.where(cols)[0][[0, -1]]

    # Convert to inches
    x_in = cmin / preview_dpi
    y_in = rmin / preview_dpi
    w_in = (cmax - cmin) / preview_dpi
    h_in = (rmax - rmin) / preview_dpi

    # Add padding (fixed amount based on the smaller dimension)
    pad_amt = min(w_in, h_in) * pad
    pad_w = pad_amt
    pad_h = pad_amt
    x_in = max(0, x_in - pad_w)
    y_in = max(0, y_in - pad_h)
    w_in = min(tpu_width_in - x_in, w_in + 2 * pad_w)
    h_in = min(tpu_height_in - y_in, h_in + 2 * pad_h)

    return (x_in, y_in, w_in, h_in)


def compute_film_luts(preview, sel_x, sel_y, sel_w, sel_h,
                      lo_pct=0.5, hi_pct=99.5, bg_threshold=0.7,
                      mode='affine'):
    """Compute per-channel LUTs optimized for film dynamic range.

    Analyzes the selected area of an 8-bit preview scan, excludes bright
    background pixels (clear TPU areas), and computes per-channel LUTs
    that stretch the film's value range to fill the full 0-255 output.

    Args:
        preview: numpy array (H, W, 3) uint8 preview image
        sel_x, sel_y, sel_w, sel_h: selection rectangle in pixels
        lo_pct: low percentile for black point (default 0.5%)
        hi_pct: high percentile for white point (default 99.5%)
        bg_threshold: fraction of max value above which pixels are
            considered background and excluded (default 0.7 = 70%)
        mode: 'affine' subtracts black level and scales (max dynamic range),
              'linear' scales only using the white point (preserves zero)

    Returns:
        (lut_r, lut_g, lut_b) tuple of 256-byte LUTs, or (None, None, None)
        if the selection has insufficient film pixels.
    """
    # Extract selection
    x, y = int(sel_x), int(sel_y)
    w, h = int(sel_w), int(sel_h)
    crop = preview[y:y+h, x:x+w]

    if crop.size == 0:
        return (None, None, None)

    # Mask out bright background (clear areas where light passes unobstructed)
    # Use Otsu's method to find the optimal threshold between the bimodal
    # distribution of dark film pixels and bright background pixels
    gray = crop.astype(np.float32).mean(axis=2)
    max_val = 255 if crop.dtype == np.uint8 else 65535

    # Otsu threshold on the gray values
    hist, bin_edges = np.histogram(gray.ravel(), bins=256, range=(0, max_val))
    bin_centers = (bin_edges[:-1] + bin_edges[1:]) / 2
    total = hist.sum()
    if total == 0:
        return (None, None, None)
    # Otsu: find threshold that minimizes intra-class variance
    best_thresh = max_val * bg_threshold  # fallback
    best_var = -1
    cum_sum = 0
    cum_mean = 0
    global_mean = (hist * bin_centers).sum() / total
    for i in range(1, 256):
        cum_sum += hist[i-1]
        cum_mean += hist[i-1] * bin_centers[i-1]
        if cum_sum == 0 or cum_sum == total:
            continue
        w0 = cum_sum / total
        w1 = 1 - w0
        m0 = cum_mean / cum_sum
        m1 = (global_mean * total - cum_mean) / (total - cum_sum)
        var = w0 * w1 * (m0 - m1) ** 2
        if var > best_var:
            best_var = var
            best_thresh = bin_centers[i]

    film_mask = gray < best_thresh
    print(f"  LUT threshold: {best_thresh:.0f} (Otsu)")

    film_pixels = film_mask.sum()
    if film_pixels < 100:
        print(f"  LUT: insufficient film pixels ({film_pixels}), using identity")
        return (None, None, None)

    luts = []
    for ch in range(3):
        ch_name = "RGB"[ch]
        ch_data = crop[:, :, ch][film_mask].astype(np.float32)

        # Percentile-based black and white points
        black = np.percentile(ch_data, lo_pct)
        white = np.percentile(ch_data, hi_pct)

        if white <= black + 1:
            print(f"  LUT {ch_name}: degenerate range ({black:.0f}-{white:.0f}), using identity")
            luts.append(None)
            continue

        if mode == 'affine':
            # output = clamp((input - black) / (white - black) * 255, 0, 255)
            scale = 255.0 / (white - black)
            lut = bytes(min(255, max(0, int((i - black) * scale))) for i in range(256))
        else:
            # output = clamp(input * 255 / white, 0, 255)
            # Preserves zero — no black subtraction, just linear gain
            scale = 255.0 / white
            lut = bytes(min(255, int(i * scale)) for i in range(256))

        print(f"  LUT {ch_name}: black={black:.1f} white={white:.1f} "
              f"gain={scale:.2f}x {mode} ({film_pixels} film pixels)")
        luts.append(lut)

    return tuple(luts)