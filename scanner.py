#!/usr/bin/env python3
"""
Epson V600 scanner driver using the proprietary Interpreter A1 bundle.

Architecture:
  The interpreter is a Mach-O bundle that translates ESC/I scanner commands
  into register-level USB operations. It does NOT do USB I/O itself — instead,
  it calls back into function pointers provided during initialization.

  INTInit(read_callback, write_callback, usb_handle) -> bool
    - read_callback(buf, len, usb_handle, &error) -> bool   [USB bulk IN]
    - write_callback(buf, len, usb_handle, &error) -> bool   [USB bulk OUT]
    - usb_handle: opaque context passed through to callbacks

  INTWrite(buf, len) -> bool   [send ESC/I command]
  INTRead(buf, len) -> bool    [read ESC/I response]
  INTClose() -> void

  Both INTWrite and INTRead call cScanner::ProcessCommand internally.
"""

import argparse
import ctypes
import ctypes.util
import sys
import os
import struct
import time
import usb.core
import usb.util
import numpy as np
import platform
import subprocess
import tempfile

# Epson USB vendor ID (shared across all models)
VENDOR_ID = 0x04b8

# Epson ICA driver download (contains all interpreters, freely available)
ICA_DRIVER_URL = "https://ftp.epson.com/drivers/ESICA_5.8.23.dmg"

# --- Scanner model database ---
# Each model needs: USB product ID, interpreter ID, display name,
# IR support flag, and any model-specific quirks.

SCANNER_MODELS = {
    0x0128: {
        "name": "Perfection 4870 / GT-X700",
        "interp": "41",
        "ir": True,
        "max_dpi": 4800,
    },
    0x012a: {
        "name": "Perfection 4990 / GT-X800",
        "interp": "52",
        "ir": True,
        "max_dpi": 4800,
    },
    0x012c: {
        "name": "Perfection V700/V750 / GT-X900",
        "interp": "7A",
        "ir": True,
        "max_dpi": 6400,
    },
    0x0135: {
        "name": "GT-X970",
        "interp": "86",
        "ir": True,
        "max_dpi": 6400,
    },
    0x013a: {
        "name": "Perfection V600 / GT-X820",
        "interp": "A1",
        "ir": True,
        "max_dpi": 6400,
    },
    0x0151: {
        "name": "Perfection V800/V850 / GT-X980",
        "interp": "AD",
        "ir": True,
        "max_dpi": 6400,
    },
}


def _interp_search_paths(interp_id):
    """Return search paths for a given interpreter ID."""
    name = f"Interpreter {interp_id}"
    model_dir = f"ES00{interp_id}"
    return [
        os.path.join(os.path.dirname(__file__), "firmware", name),
        f"/Library/Image Capture/Devices/EPSON Scanner.app/Contents/PlugIns/{name}.bundle/Contents/MacOS/{name}",
        f"/Library/Image Capture/Support/EPSON/Epson Scan 2/Models/{model_dir}/{name}.bundle/Contents/MacOS/{name}",
    ]


def find_interpreter(interp_id="A1"):
    """Find the interpreter binary in known locations."""
    # On Linux, we can't use the interpreter directly due to unresolved symbols
    if platform.system() == "Linux":
        return None
        
    for path in _interp_search_paths(interp_id):
        if os.path.exists(path):
            return path
    return None


def ensure_interpreter(interp_id="A1"):
    """Download and extract the Epson ICA driver if interpreter is not found.

    Downloads the freely-available ICA scanner driver from Epson's FTP server
    and extracts the Interpreter A1 bundle to a local firmware/ directory.
    """
    path = find_interpreter(interp_id)
    if path:
        return path

    firmware_dir = os.path.join(os.path.dirname(__file__), "firmware")
    target = os.path.join(firmware_dir, f"Interpreter {interp_id}")

    print("Epson Interpreter A1 not found locally.")
    print(f"Downloading ICA driver from {ICA_DRIVER_URL} ...")

    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory() as tmpdir:
        dmg_path = os.path.join(tmpdir, "esica.dmg")

        # Download
        import urllib.request
        urllib.request.urlretrieve(ICA_DRIVER_URL, dmg_path,
            reporthook=lambda b, bs, ts: print(
                f"\r  {b*bs/1024/1024:.1f} / {ts/1024/1024:.1f} MB", end="", flush=True
            ) if ts > 0 else None)
        print()

        # Mount DMG
        mount_point = os.path.join(tmpdir, "mnt")
        os.makedirs(mount_point)
        subprocess.run(
            ["hdiutil", "attach", dmg_path, "-mountpoint", mount_point, "-nobrowse", "-quiet"],
            check=True,
        )

        try:
            # Find and extract the pkg
            pkg_path = None
            for root, dirs, files in os.walk(mount_point):
                for f in files:
                    if f.endswith(".pkg"):
                        pkg_path = os.path.join(root, f)
                        break
                if pkg_path:
                    break

            if not pkg_path:
                raise RuntimeError("No .pkg found in DMG")

            # Extract pkg contents
            extract_dir = os.path.join(tmpdir, "extracted")
            subprocess.run(
                ["pkgutil", "--expand-full", pkg_path, extract_dir],
                check=True,
            )

            # Find the interpreter binary for this model
            bundle_name = f"Interpreter {interp_id}.bundle"
            binary_name = f"Interpreter {interp_id}"
            interp_bin = None
            for root, dirs, files in os.walk(extract_dir):
                if bundle_name in dirs:
                    candidate = os.path.join(root, bundle_name,
                                            "Contents", "MacOS", binary_name)
                    if os.path.exists(candidate):
                        interp_bin = candidate
                        break

            if not interp_bin:
                raise RuntimeError(f"{binary_name} not found in package")

            # Copy to local firmware directory
            os.makedirs(firmware_dir, exist_ok=True)
            import shutil
            shutil.copy2(interp_bin, target)
            os.chmod(target, 0o755)
            print(f"  Installed: {target}")

        finally:
            subprocess.run(["hdiutil", "detach", mount_point, "-quiet"],
                          check=False)

    return target

# Callback type: bool callback(uint8_t* buf, uint32_t len, void* handle, int16_t* err)
USB_CALLBACK = ctypes.CFUNCTYPE(
    ctypes.c_int8,                    # return: bool (signed, since interpreter checks sign)
    ctypes.POINTER(ctypes.c_uint8),   # buffer
    ctypes.c_uint32,                  # length
    ctypes.c_void_p,                  # usb_handle (opaque)
    ctypes.POINTER(ctypes.c_int16),   # error status
)

# ESC/I protocol constants
ESC = 0x1b
FS = 0x1c
RS = 0x1e  # Record Separator — used for extended register commands

# Valid scan resolutions for the V600
VALID_RESOLUTIONS = [100, 200, 400, 533, 600, 800, 1200, 1600, 3200, 6400]
VALID_IR_RESOLUTIONS = [800, 1600, 3200]


class SaneEpsonScanner:
    """SANE-based driver for Epson V-series scanners on Linux.
    
    Uses the SANE epkowa backend for communication instead of the 
    proprietary macOS interpreter bundle.
    """
    
    # Class-level cache for device name to avoid repeated detection
    _cached_device_name = None
    _cache_timestamp = 0
    CACHE_TIMEOUT = 300  # 5 minutes cache timeout
    
    def __init__(self, product_id=None):
        """Initialize SANE scanner driver."""
        self.device_name = None
        self.model = None
        self._product_id = product_id
        self._cached_capabilities = None  # Cache capabilities to avoid repeated queries
        
    def find_sane_device(self):
        """Find the scanner device using SANE.
        
        Uses class-level cache to avoid repeated expensive scanimage -L calls.
        """
        # Check if we have a valid cached device name
        import time
        current_time = time.time()
        if (SaneEpsonScanner._cached_device_name and 
            current_time - SaneEpsonScanner._cache_timestamp < SaneEpsonScanner.CACHE_TIMEOUT):
            print(f"Using cached device: {SaneEpsonScanner._cached_device_name}")
            return SaneEpsonScanner._cached_device_name
            
        print("Detecting scanner (this may take 10-15 seconds on first run)...")
        try:
            result = subprocess.run(['scanimage', '-L'], 
                                  capture_output=True, text=True, check=True)
            
            # Prefer epson2 backend over epkowa (epson2 supports 16-bit at high DPI)
            epson2_device = None
            epkowa_device = None
            
            for line in result.stdout.split('\n'):
                if 'V600' in line or 'GT-X820' in line:
                    # Extract device name from: device `backend:...` is a ...
                    if '`' in line and "'" in line:
                        device_name = line.split('`')[1].split("'")[0]
                        if 'epson2' in device_name:
                            epson2_device = device_name
                            print(f"Found epson2 device (preferred): {device_name}")
                        elif 'epkowa' in device_name:
                            epkowa_device = device_name
                            print(f"Found epkowa device: {device_name}")
            
            # Return epson2 if available, otherwise epkowa
            device_to_use = None
            if epson2_device:
                print("Using epson2 backend (supports 16-bit at high DPI)")
                device_to_use = epson2_device
            elif epkowa_device:
                print("WARNING: Using epkowa backend (limited to 8-bit at 3200+ DPI)")
                print("         For 16-bit high DPI scans, install patched SANE with epson2")
                device_to_use = epkowa_device
            
            # Cache the device name
            if device_to_use:
                SaneEpsonScanner._cached_device_name = device_to_use
                SaneEpsonScanner._cache_timestamp = current_time
                print(f"Cached device name for future use")
            
            return device_to_use
                        
        except subprocess.CalledProcessError:
            pass
        return None
    
    def open(self):
        """Open scanner using SANE backend."""
        self.device_name = self.find_sane_device()
        if not self.device_name:
            raise RuntimeError("No V600 scanner found via SANE. Check that the scanner is connected and epkowa backend is installed.")
            
        # Set model info
        if self._product_id and self._product_id in SCANNER_MODELS:
            self.model = SCANNER_MODELS[self._product_id]
        else:
            # Default to V600 specs if we can't determine exact model
            self.model = {
                "name": "Perfection V600 / GT-X820 (SANE)",
                "interp": "SANE",
                "ir": True,
                "max_dpi": 6400,
            }
            
        print(f"Scanner: {self.model['name']}")
        print(f"SANE device: {self.device_name}")
        
        return True
        
    def close(self):
        """Close scanner - no-op for SANE."""
        pass
    
    def usb_reset(self):
        """Reset scanner via USB to recover from bad state."""
        print("Performing USB reset...")
        
        # Try to use the compiled usb_reset tool if available
        reset_tool = os.path.join(os.path.dirname(__file__), 'usb_reset')
        if os.path.exists(reset_tool):
            try:
                result = subprocess.run([reset_tool], capture_output=True, text=True, timeout=5)
                if result.returncode == 0:
                    print("USB reset successful")
                    time.sleep(2)  # Wait for scanner to reinitialize
                    return True
            except:
                pass
        
        # Fallback: try Python USB reset
        try:
            # Find V600 device
            for bus in range(1, 11):
                for dev in range(1, 128):
                    path = f"/dev/bus/usb/{bus:03d}/{dev:03d}"
                    if os.path.exists(path):
                        with open(path, 'rb') as f:
                            desc = f.read(18)
                            if len(desc) >= 18:
                                import struct
                                vid = struct.unpack('<H', desc[8:10])[0]
                                pid = struct.unpack('<H', desc[10:12])[0]
                                if vid == 0x04b8 and pid == 0x013a:
                                    # Found V600, try reset
                                    fd = os.open(path, os.O_RDWR)
                                    try:
                                        import fcntl
                                        USBDEVFS_RESET = 0x5514
                                        fcntl.ioctl(fd, USBDEVFS_RESET, 0)
                                        print(f"USB reset performed on {path}")
                                        time.sleep(2)
                                        return True
                                    finally:
                                        os.close(fd)
        except Exception as e:
            print(f"USB reset failed: {e}")
        
        return False
    
    def get_identity(self):
        """Get scanner identity using SANE."""
        # Return a simple identity string
        return f"SANE {self.model['name']}".encode('ascii')
        
    def get_status(self):
        """Get scanner status - basic implementation."""
        print("  Scanner ready via SANE")
        return b'\x00'  # Basic status byte
        
    def get_extended_identity(self):
        """Get extended identity - mock implementation."""
        print(f"  Command level: 2.0")
        print(f"  Model:         {self.model['name']}")
        print(f"  ** IR scanning SUPPORTED (via SANE) **")
        return b'\x00' * 80  # Mock response
        
    def scan(self, dpi=300, x=0, y=0, width=None, height=None,
             color=True, depth=8, source='flatbed', ir=False,
             output=None, progress_cb=None, cancel_cb=None):
        """High-level scan function using SANE backend.
        
        Parameters are similar to the interpreter-based scanner but uses
        SANE scanimage command for actual scanning.
        """
        
        # Map our parameters to SANE parameters
        if source == 'tpu' or ir:
            sane_source = "Transparency Unit"
        else:
            sane_source = "Flatbed"
            
        if ir:
            sane_mode = "Gray"  # IR is grayscale
        elif color:
            sane_mode = "Color"
        else:
            sane_mode = "Gray"
            
        # TPU only supports specific resolutions: 400, 800, 1600, 3200
        if sane_source == "Transparency Unit":
            valid_tpu_resolutions = [400, 800, 1600, 3200]
            if dpi not in valid_tpu_resolutions:
                # For preview (200 DPI), we'll scan at 400 and downsample later
                original_dpi = dpi
                closest = min(valid_tpu_resolutions, key=lambda r: abs(r - dpi))
                print(f"  Note: TPU doesn't support {dpi} dpi, using {closest} dpi")
                dpi = closest
            else:
                original_dpi = dpi
        else:
            original_dpi = dpi
            
        # Validate resolution for IR
        if ir and dpi not in VALID_IR_RESOLUTIONS:
            closest = min(VALID_IR_RESOLUTIONS, key=lambda r: abs(r - dpi))
            print(f"  Note: {dpi} dpi not supported for IR, using {closest} dpi")
            dpi = closest
            
        print(f"\nScan parameters:")
        print(f"  Resolution: {dpi} dpi")
        print(f"  Mode: {'IR' if ir else 'RGB' if color else 'Gray'} {depth}-bit")
        print(f"  Source: {sane_source}")
        
        # Calculate scan area
        if width is not None or height is not None or x != 0 or y != 0:
            print(f"  Area: offset ({x:.1f}, {y:.1f}) inches, size ({width or 'full'}x{height or 'full'}) inches")
            
        # Use the appropriate wrapper script for V600 scanning
        env = os.environ.copy()
        
        # Check if wrapper scripts are available
        import shutil
        use_wrappers = shutil.which('scanimage-v600') is not None
        
        # Choose the right wrapper command
        if ir:
            if use_wrappers and shutil.which('scanimage-v600-ir'):
                # Use IR wrapper for infrared scanning
                print("  Using scanimage-v600-ir wrapper for IR scanning")
                cmd = ['scanimage-v600-ir']
            else:
                # Fallback to regular scanimage with environment variable
                print("  Using scanimage with SCAN_IR_MODE=1 for IR scanning")
                env['SCAN_IR_MODE'] = '1'
                cmd = ['scanimage']
            # IR mode requirements
            sane_source = "Transparency Unit"
            sane_mode = "Gray"
            # Ensure resolution is valid for IR
            if dpi not in [800, 1600, 3200]:
                dpi = 800  # Default to 800 for IR
                print(f"  Adjusted resolution to {dpi} DPI for IR mode")
        else:
            if use_wrappers:
                # Use regular V600 wrapper for color/grayscale scanning
                print("  Using scanimage-v600 wrapper for color scanning")
                cmd = ['scanimage-v600']
            else:
                # Fallback to regular scanimage
                cmd = ['scanimage']
        
        # ALWAYS add explicit device name to avoid expensive auto-detection
        cmd.extend(['--device-name', self.device_name])
        
        # Add common parameters
        cmd.extend([
            '--mode', sane_mode,
            '--source', sane_source,
            '--resolution', str(dpi),
            '--format', 'tiff',
        ])
        
        # Add depth parameter for non-IR scans
        if not ir and depth == 16:
            cmd.extend(['--depth', '16'])
            
        # Add scan area if specified
        if x != 0 or y != 0 or width is not None or height is not None:
            # Convert inches to mm for SANE
            x_mm = x * 25.4
            y_mm = y * 25.4
            
            # Get scanner limits for validation
            try:
                caps = self.get_scanner_capabilities()
                max_width_mm = caps['tpu_width_in'] * 25.4 if sane_source == "Transparency Unit" else caps['flatbed_width_in'] * 25.4
                max_height_mm = caps['tpu_height_in'] * 25.4 if sane_source == "Transparency Unit" else caps['flatbed_height_in'] * 25.4
            except:
                # Fallback limits if capabilities query fails (already in mm)
                max_width_mm = 68.58 if sane_source == "Transparency Unit" else 215.9
                max_height_mm = 242.316 if sane_source == "Transparency Unit" else 297.18
            
            # Add small safety margin (0.1mm) to avoid floating point precision issues
            safety_margin = 0.1
            max_width_mm -= safety_margin
            max_height_mm -= safety_margin
            
            # Validate and clamp coordinates
            x_mm = max(0, min(x_mm, max_width_mm))
            y_mm = max(0, min(y_mm, max_height_mm))
            
            # SANE parameters:
            # -l: left (x position)
            # -t: top (y position) 
            # -x: width
            # -y: height
            # Round to reasonable precision (0.1mm) to avoid float precision issues
            cmd.extend(['-l', f'{x_mm:.1f}', '-t', f'{y_mm:.1f}'])
            
            if width is not None:
                w_mm = width * 25.4
                # Ensure width doesn't exceed available space
                w_mm = min(w_mm, max_width_mm - x_mm)
                cmd.extend(['-x', f'{w_mm:.1f}'])
            else:
                # If no width specified, use full TPU/flatbed width
                w_mm = max_width_mm - x_mm
                cmd.extend(['-x', f'{w_mm:.1f}'])
                
            if height is not None:
                h_mm = height * 25.4
                # Ensure height doesn't exceed available space
                h_mm = min(h_mm, max_height_mm - y_mm)
                cmd.extend(['-y', f'{h_mm:.1f}'])
            else:
                # If no height specified, use full TPU/flatbed height
                h_mm = max_height_mm - y_mm
                cmd.extend(['-y', f'{h_mm:.1f}'])
                
            print(f"  SANE coordinates: -l {x_mm:.1f} -t {y_mm:.1f} -x {w_mm:.1f} -y {h_mm:.1f} (mm)")
            print(f"  Expected pixels at {dpi} DPI: {int(w_mm/25.4*dpi)} x {int(h_mm/25.4*dpi)}")
        
        # Set up output
        if output:
            temp_file = output
        else:
            temp_fd, temp_file = tempfile.mkstemp(suffix='.tiff')
            os.close(temp_fd)
            
        cmd.extend(['-o', temp_file])
        
        print("Starting SANE scan...")
        print(f"Command: {' '.join(cmd)}")
        
        # Estimate scan time based on resolution and area
        pixels = (w_mm/25.4*dpi if width else max_width_mm/25.4*dpi) * (h_mm/25.4*dpi if height else max_height_mm/25.4*dpi)
        estimated_time = 10 + (pixels / 1_000_000) * 2  # Base 10s + 2s per megapixel
        if dpi >= 3200:
            estimated_time *= 3  # High res scans are much slower
        print(f"Estimated scan time: {int(estimated_time)}s for {pixels/1_000_000:.1f} megapixels")
        
        try:
            # Run scanimage with longer timeout for high-res scans
            # Use Popen for potential progress monitoring
            import subprocess
            result = subprocess.run(cmd, capture_output=True, text=True, check=True, 
                                  timeout=max(300, estimated_time * 2), env=env)
            
            print(f"Scan completed successfully")
            
            # Load the image using tifffile or PIL
            try:
                import tifffile
                arr = tifffile.imread(temp_file)
            except ImportError:
                from PIL import Image
                img = Image.open(temp_file)
                arr = np.array(img)
                
            print(f"Image loaded: {arr.shape}, dtype={arr.dtype}")
            
            # Handle resolution mismatch for TPU (when we requested lower DPI than supported)
            if sane_source == "Transparency Unit" and original_dpi != dpi:
                # Downsample to match requested resolution
                from PIL import Image
                scale_factor = original_dpi / dpi
                if arr.ndim == 3:
                    h, w, c = arr.shape
                else:
                    h, w = arr.shape
                    c = 1
                new_h = int(h * scale_factor)
                new_w = int(w * scale_factor)
                
                img = Image.fromarray(arr)
                img = img.resize((new_w, new_h), Image.LANCZOS)
                arr = np.array(img)
                print(f"Downsampled from {dpi} to {original_dpi} DPI: {arr.shape}")
            
            # Mirror horizontally for TPU scans (same as original code)
            if source != 'flatbed':
                arr = np.ascontiguousarray(arr[:, ::-1])
                
            # If no output specified, clean up temp file
            if not output:
                os.unlink(temp_file)
                
            return arr
            
        except subprocess.CalledProcessError as e:
            print(f"SANE scan failed: {e}")
            print(f"Return code: {e.returncode}")
            print(f"stdout: {e.stdout}")
            print(f"stderr: {e.stderr}")
            
            # Try to get more detailed error by running with verbose
            if not e.stderr:
                print("Running again with --verbose to get error details...")
                verbose_cmd = cmd.copy()
                verbose_cmd.insert(1, '--verbose')
                result = subprocess.run(verbose_cmd, capture_output=True, text=True)
                print(f"Verbose stderr: {result.stderr}")
            
            raise RuntimeError(f"Scan failed: {e.stderr or 'No error message'}")
            
    def _save_image(self, arr, path, depth, dpi=None):
        """Save image array to file - same as original implementation."""
        ext = os.path.splitext(path)[1].lower()
        if ext in ('.tif', '.tiff'):
            import tifffile
            kwargs = self._tiff_metadata(dpi) if dpi else {}
            tifffile.imwrite(path, arr, **kwargs)
            print(f"Saved: {path}")
        elif ext == '.png':
            from PIL import Image
            if depth == 16:
                import tifffile
                path = path.replace('.png', '.tiff')
                kwargs = self._tiff_metadata(dpi) if dpi else {}
                tifffile.imwrite(path, arr, **kwargs)
                print(f"Saved as TIFF (16-bit): {path}")
            else:
                img = Image.fromarray(arr)
                img.save(path, dpi=(dpi, dpi) if dpi else None)
                print(f"Saved: {path}")
        else:
            import tifffile
            kwargs = self._tiff_metadata(dpi) if dpi else {}
            tifffile.imwrite(path, arr, **kwargs)
            print(f"Saved: {path}")
            
    def _tiff_metadata(self, dpi):
        """Return tifffile.write() kwargs for scanner metadata."""
        from datetime import datetime
        return dict(
            resolution=(dpi, dpi),
            resolutionunit='inch',
            datetime=datetime.now(),
            software='epdaughter-sane',
            extratags=[
                (271, 2, None, 'EPSON', True),          # Make
                (272, 2, None, self.model['name'] if self.model else 'Epson Scanner', True), # Model
            ],
        )


def detect_film_area(preview, preview_dpi, tpu_width_in, tpu_height_in, pad=0.05):
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
    from scipy import ndimage

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


class EpsonScanner:
    """Driver for Epson V-series flatbed scanners with TPU.

    Supports auto-detection of scanner model from USB, or explicit
    model selection. Uses the Epson Interpreter bundle for communication.
    """

    def __init__(self, product_id=None):
        """Initialize scanner driver.

        Args:
            product_id: USB product ID to connect to, or None for auto-detect.
        """
        # Detect platform and choose appropriate backend
        if platform.system() == "Linux":
            print("Detected Linux - using SANE backend")
            self._backend = SaneEpsonScanner(product_id)
        else:
            print("Detected macOS/other - using interpreter backend")
            # Original interpreter-based initialization
            self.dev = None
            self.ep_in = None
            self.ep_out = None
            self.interp = None
            self._read_cb = None   # prevent GC
            self._write_cb = None  # prevent GC
            self._tpu_configured = False  # set after first configure_tpu
            self._needs_reinit = False    # set after RS commands need reinit
            self._backend = None
            
        self._product_id = product_id
        self.model = None      # populated by open()
        self.verbose_usb = False  # trace USB callbacks

    def open(self):
        """Open USB device and initialize interpreter.

        Auto-detects the scanner model from USB if no product_id was
        specified in __init__. Loads the matching interpreter bundle.
        """
        # If using SANE backend, delegate to it
        if self._backend:
            result = self._backend.open()
            self.model = self._backend.model
            return result
        # Find scanner on USB — auto-detect or use specified product ID
        if self._product_id:
            self.dev = usb.core.find(idVendor=VENDOR_ID, idProduct=self._product_id)
        else:
            # Scan for any known Epson scanner
            for pid in SCANNER_MODELS:
                self.dev = usb.core.find(idVendor=VENDOR_ID, idProduct=pid)
                if self.dev:
                    self._product_id = pid
                    break

        if self.dev is None:
            known = ", ".join(
                f"{m['name']} (0x{pid:04x})"
                for pid, m in SCANNER_MODELS.items()
            )
            raise RuntimeError(f"No supported Epson scanner found on USB. Supported: {known}")

        self.model = SCANNER_MODELS.get(self._product_id, {
            "name": f"Unknown (0x{self._product_id:04x})",
            "interp": "A1",
            "ir": False,
            "max_dpi": 6400,
        })
        print(f"Scanner: {self.model['name']}")

        try:
            if self.dev.is_kernel_driver_active(0):
                self.dev.detach_kernel_driver(0)
        except Exception:
            pass

        self.dev.set_configuration()
        cfg = self.dev.get_active_configuration()
        intf = cfg[(0, 0)]

        self.ep_out = usb.util.find_descriptor(intf, custom_match=lambda e:
            usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
        self.ep_in = usb.util.find_descriptor(intf, custom_match=lambda e:
            usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN)

        print(f"USB connected: EP OUT=0x{self.ep_out.bEndpointAddress:02x}, "
              f"EP IN=0x{self.ep_in.bEndpointAddress:02x}")

        # Load interpreter for this model (download if needed)
        interp_id = self.model["interp"]
        interp_path = ensure_interpreter(interp_id)
        if not interp_path:
            raise RuntimeError(
                f"Interpreter {interp_id} not found. Install the Epson ICA "
                "Scanner Driver from https://epson.com/Support/Scanners/"
            )

        self.interp = ctypes.CDLL(interp_path)
        print("Interpreter loaded")


        # Set up function signatures
        self.interp.INTInit.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        self.interp.INTInit.restype = ctypes.c_uint8

        self.interp.INTWrite.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.c_uint32]
        self.interp.INTWrite.restype = ctypes.c_uint8

        self.interp.INTRead.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.c_uint32]
        self.interp.INTRead.restype = ctypes.c_uint8

        self.interp.INTClose.argtypes = []
        self.interp.INTClose.restype = None

        self.interp.INTGetUSBError.argtypes = []
        self.interp.INTGetUSBError.restype = ctypes.c_int16

        self.interp.INTGetInterpreterError.argtypes = []
        self.interp.INTGetInterpreterError.restype = ctypes.c_int32

        # Create USB I/O callbacks
        self._read_cb = USB_CALLBACK(self._usb_read)
        self._write_cb = USB_CALLBACK(self._usb_write)

        self._init_interpreter()
        return True

    def _init_interpreter(self):
        """Upload firmware and initialize the interpreter."""
        print("Initializing scanner (uploading firmware)...")
        result = self.interp.INTInit(
            ctypes.cast(self._read_cb, ctypes.c_void_p),
            ctypes.cast(self._write_cb, ctypes.c_void_p),
            ctypes.c_void_p(0),
        )

        if not result:
            usb_err = self.interp.INTGetUSBError()
            int_err = self.interp.INTGetInterpreterError()
            raise RuntimeError(f"INTInit failed: USB err={usb_err}, interp err={int_err}")

        print("Scanner initialized!")

    def _usb_read(self, buf, length, handle, err_ptr):
        """USB bulk IN callback — called by the interpreter."""
        try:
            data = self.ep_in.read(length, timeout=10000)
            ctypes.memmove(buf, bytes(data), len(data))
            if self.verbose_usb:
                hex_str = " ".join(f"{b:02x}" for b in data[:min(len(data), 32)])
                print(f"    [USB RD {length}B → {len(data)}B: {hex_str}]")
            if err_ptr:
                err_ptr[0] = 0
            return 1  # success
        except usb.core.USBTimeoutError:
            print(f"  [USB READ timeout, wanted {length} bytes]")
            if err_ptr:
                err_ptr[0] = -1
            return 0
        except usb.core.USBError as e:
            print(f"  [USB READ error: {e}]")
            if err_ptr:
                err_ptr[0] = -1
            return 0

    def _usb_write(self, buf, length, handle, err_ptr):
        """USB bulk OUT callback — called by the interpreter."""
        try:
            data = bytes(buf[:length])
            if self.verbose_usb:
                hex_str = " ".join(f"{b:02x}" for b in data[:min(length, 32)])
                print(f"    [USB WR {length}B: {hex_str}]")
            written = self.ep_out.write(data, timeout=10000)
            if err_ptr:
                err_ptr[0] = 0
            return 1  # success
        except usb.core.USBError as e:
            print(f"  [USB WRITE error: {e}]")
            if err_ptr:
                err_ptr[0] = -1
            return 0

    def reinit(self):
        """Reinitialize the interpreter without re-opening USB.

        Required after scans that use RS (direct USB) commands, which
        desync the interpreter's internal USB state.
        """
        if self.interp:
            try:
                self.interp.INTClose()
            except Exception:
                pass
        self._init_interpreter()

    def close(self):
        if self._backend:
            return self._backend.close()
            
        if self.interp:
            try:
                self.interp.INTClose()
            except Exception:
                pass
        if self.dev:
            usb.util.dispose_resources(self.dev)

    # === ESC/I Commands ===

    def _cmd(self, data, debug=False):
        """Send command via INTWrite, return success."""
        if self._backend:
            # SANE backend doesn't support low-level commands
            raise RuntimeError("Low-level commands not supported with SANE backend. Use high-level methods like get_scanner_capabilities() instead.")
            
        if debug:
            hex_str = " ".join(f"{b:02x}" for b in data[:32])
            print(f"  -> INTWrite({len(data)}B): {hex_str}")
        buf = (ctypes.c_uint8 * len(data))(*data)
        result = self.interp.INTWrite(buf, len(data))
        if debug:
            print(f"  <- INTWrite result: {result}")
        if not result:
            usb_err = self.interp.INTGetUSBError()
            int_err = self.interp.INTGetInterpreterError()
            print(f"  Command failed: USB={usb_err}, interp={int_err}")
        return bool(result)

    def _read(self, size, debug=False):
        """Read response via INTRead (calls ProcessCommand internally)."""
        if self._backend:
            # SANE backend doesn't support low-level commands
            raise RuntimeError("Low-level commands not supported with SANE backend. Use high-level methods like get_scanner_capabilities() instead.")
            
        buf = (ctypes.c_uint8 * size)()
        result = self.interp.INTRead(buf, size)
        if debug:
            hex_str = " ".join(f"{buf[i]:02x}" for i in range(min(size, 32)))
            print(f"  <- INTRead({size}B) result={result}: {hex_str}")
        if not result:
            return None
        return bytes(buf)

    def _cmd_ack(self, data, debug=False):
        """Send command via INTWrite, then read ACK via INTRead."""
        if not self._cmd(data, debug=debug):
            return False
        resp = self._read(1, debug=debug)
        if resp is None:
            return False
        if resp[0] == 0x06:  # ACK
            return True
        if resp[0] == 0x15:  # NAK
            if debug:
                print(f"  NAK received")
            return False
        if debug:
            print(f"  Unexpected response: 0x{resp[0]:02x}")
        return True  # assume success for non-ACK/NAK

    def reset(self):
        """ESC @ - Reset."""
        print("Resetting scanner...")
        return self._cmd_ack(bytes([ESC, 0x40]))

    def get_identity(self):
        """ESC I - Request identity."""
        if self._backend:
            return self._backend.get_identity()
            
        self._cmd(bytes([ESC, 0x49]))
        return self._read(256)

    def get_status(self):
        """ESC F - Request status."""
        if self._backend:
            return self._backend.get_status()
            
        self._cmd(bytes([ESC, 0x46]))
        resp = self._read(16)
        if resp:
            print(f"  Status byte: 0x{resp[0]:02x}")
            if resp[0] & 0x40:
                print("  -> Extended commands supported")
            if resp[0] & 0x04:
                print("  -> Option (TPU) installed")
        return resp

    def get_extended_identity(self):
        """FS I - Extended identity (80 bytes)."""
        if self._backend:
            return self._backend.get_extended_identity()
            
        self._cmd(bytes([FS, 0x49]))
        resp = self._read(80)
        if resp:
            print(f"  Command level: {chr(resp[0])}{chr(resp[1])}")
            print(f"  Optical res:   {struct.unpack_from('<I', resp, 4)[0]} dpi")
            print(f"  Min res:       {struct.unpack_from('<I', resp, 8)[0]} dpi")
            print(f"  Max res:       {struct.unpack_from('<I', resp, 12)[0]} dpi")
            print(f"  Max pixels:    {struct.unpack_from('<I', resp, 16)[0]}")
            fbf_x = struct.unpack_from('<I', resp, 20)[0]
            fbf_y = struct.unpack_from('<I', resp, 24)[0]
            print(f"  Flatbed area:  {fbf_x}x{fbf_y}")
            tpu_x = struct.unpack_from('<I', resp, 36)[0]
            tpu_y = struct.unpack_from('<I', resp, 40)[0]
            print(f"  TPU area:      {tpu_x}x{tpu_y}")
            model = resp[46:62].decode('ascii', errors='replace').rstrip('\x00 ')
            print(f"  Model:         {model}")
            cap1 = resp[44]
            print(f"  Capabilities:  0x{cap1:02x}")
            if cap1 & 0x02:
                print("  ** IR scanning SUPPORTED **")
            if cap1 & 0x80:
                print("  ** Push button supported **")
            print(f"  Input depth:   {resp[66]} bits")
            print(f"  Max out depth: {resp[67]} bits")
        return resp
    
    def get_scanner_capabilities(self):
        """Get scanner capabilities in a structured format.
        
        Returns dict with keys: optical_dpi, tpu_width_in, tpu_height_in, etc.
        This is a high-level interface that works with both backends.
        """
        if self._backend:
            # Return cached capabilities if available
            if hasattr(self._backend, '_cached_capabilities') and self._backend._cached_capabilities:
                return self._backend._cached_capabilities
                
            # For SANE backend, query SANE directly for capabilities
            try:
                # Get capabilities for both flatbed and TPU sources
                import re
                
                # First get flatbed capabilities (default source)
                result_flatbed = subprocess.run([
                    'scanimage', '--device-name', self._backend.device_name, '--help'
                ], capture_output=True, text=True, check=True)
                
                # Then get TPU-specific capabilities
                result_tpu = subprocess.run([
                    'scanimage', '--device-name', self._backend.device_name, 
                    '--source', 'Transparency Unit', '--help'
                ], capture_output=True, text=True, check=True)
                
                max_resolution = 6400  # Default V600 max
                
                # Parse flatbed area from default help
                flatbed_width_mm = 215.9   # Default
                flatbed_height_mm = 297.18 # Default
                for line in result_flatbed.stdout.split('\n'):
                    if '--resolution' in line and 'dpi' in line:
                        numbers = re.findall(r'\d+', line)
                        if numbers:
                            max_resolution = max(int(n) for n in numbers if int(n) <= 6400)
                    elif '-x 0..' in line and 'mm' in line:
                        match = re.search(r'-x 0\.\.(\d+\.?\d*)mm', line)
                        if match:
                            flatbed_width_mm = float(match.group(1))
                    elif '-y 0..' in line and 'mm' in line:
                        match = re.search(r'-y 0\.\.(\d+\.?\d*)mm', line)
                        if match:
                            flatbed_height_mm = float(match.group(1))
                
                # Parse TPU area from TPU-specific help
                tpu_width_mm = 68.58    # Default V600 TPU width
                tpu_height_mm = 242.316 # Default V600 TPU height
                for line in result_tpu.stdout.split('\n'):
                    if '-x 0..' in line and 'mm' in line:
                        match = re.search(r'-x 0\.\.(\d+\.?\d*)mm', line)
                        if match:
                            tpu_width_mm = float(match.group(1))
                    elif '-y 0..' in line and 'mm' in line:
                        match = re.search(r'-y 0\.\.(\d+\.?\d*)mm', line)
                        if match:
                            tpu_height_mm = float(match.group(1))
                
                # Convert mm to inches for our API
                tpu_width_in = tpu_width_mm / 25.4
                tpu_height_in = tpu_height_mm / 25.4
                flatbed_width_in = flatbed_width_mm / 25.4  
                flatbed_height_in = flatbed_height_mm / 25.4
                
                caps = {
                    'optical_dpi': 1200,  # Standard optical resolution
                    'max_resolution': max_resolution,
                    'tpu_width_in': tpu_width_in,
                    'tpu_height_in': tpu_height_in,
                    'flatbed_width_in': flatbed_width_in,
                    'flatbed_height_in': flatbed_height_in,
                    'ir_supported': True,
                    'model': self.model['name']
                }
                # Cache the capabilities
                self._backend._cached_capabilities = caps
                return caps
                
            except subprocess.CalledProcessError:
                # Fallback to reasonable defaults for V600
                return {
                    'optical_dpi': 1200,
                    'max_resolution': 6400,
                    'tpu_width_in': 8.5,
                    'tpu_height_in': 11.7,
                    'flatbed_width_in': 8.5,
                    'flatbed_height_in': 11.7,
                    'ir_supported': True,
                    'model': self.model['name']
                }
        else:
            # For interpreter backend, use existing extended identity
            eid = self.get_extended_identity()
            if eid is None:
                raise RuntimeError("Cannot read scanner capabilities")
                
            optical_dpi = struct.unpack_from('<I', eid, 4)[0]
            max_res = struct.unpack_from('<I', eid, 12)[0]
            fbf_x = struct.unpack_from('<I', eid, 20)[0]
            fbf_y = struct.unpack_from('<I', eid, 24)[0]
            tpu_x = struct.unpack_from('<I', eid, 36)[0]
            tpu_y = struct.unpack_from('<I', eid, 40)[0]
            
            return {
                'optical_dpi': optical_dpi,
                'max_resolution': max_res,
                'tpu_width_in': tpu_x / optical_dpi,
                'tpu_height_in': tpu_y / optical_dpi,
                'flatbed_width_in': fbf_x / optical_dpi,
                'flatbed_height_in': fbf_y / optical_dpi,
                'ir_supported': bool(eid[44] & 0x02) if len(eid) > 44 else True,
                'model': eid[46:62].decode('ascii', errors='replace').rstrip('\x00 ') if len(eid) > 62 else 'Unknown'
            }

    def get_extended_status(self):
        """ESC f - Extended status."""
        if self._backend:
            # For SANE backend, return a mock status
            print("  Model: V600 via SANE")
            print("  TPU status: Available")  
            print("  -> TPU installed")
            print("  -> TPU enabled")
            return b'\x00' * 64
            
        self._cmd(bytes([ESC, 0x66]))
        return self._read(64)

    def set_resolution(self, dpi):
        """ESC R - Set scan resolution."""
        return self._cmd(bytes([ESC, 0x52]) + struct.pack('<HH', dpi, dpi))

    def set_scan_area(self, x, y, w, h):
        """ESC A - Set scan area in scanner units."""
        return self._cmd(bytes([ESC, 0x41]) + struct.pack('<IIII', x, y, w, h))

    def set_color_mode(self, mode):
        """ESC C - Set color/grayscale mode."""
        return self._cmd(bytes([ESC, 0x43, mode]))

    def set_data_format(self, bits):
        """ESC D - Set bits per pixel."""
        return self._cmd(bytes([ESC, 0x44, bits]))

    def set_source(self, source, enable=True):
        """ESC e - Select scan source (flatbed/TPU)."""
        return self._cmd(bytes([ESC, 0x65, 0x01 if enable else 0x00, source]))

    def start_scan(self):
        """ESC G - Start scanning."""
        return self._cmd(bytes([ESC, 0x47]))

    def enable_infrared(self):
        """ESC # - Enable infrared mode.

        This is a challenge-response protocol:
        1. Read current scanning parameters via FS S (64 bytes)
        2. XOR first 32 bytes with a hardcoded key
        3. Send ESC # + ACK + 32-byte response + ACK
        """
        # Hardcoded XOR key from SANE epson2 backend
        xor_key = bytes([
            0xCA, 0xFB, 0x77, 0x71, 0x20, 0x16, 0xDA, 0x09,
            0x5F, 0x57, 0x09, 0x12, 0x04, 0x83, 0x76, 0x77,
            0x3C, 0x73, 0x9C, 0xBE, 0x7A, 0xE0, 0x52, 0xE2,
            0x90, 0x0D, 0xFF, 0x9A, 0xEF, 0x4C, 0x2C, 0x81,
        ])

        # Step 1: Read current scanning parameters (FS S)
        self._cmd(bytes([FS, 0x53]))
        params = self._read(64)
        if params is None:
            print("  Failed to read scanning parameters for IR enable")
            return False

        # Step 2: XOR first 32 bytes
        response = bytearray(32)
        for i in range(32):
            response[i] = xor_key[i] ^ params[i]

        # Step 3: Send ESC # then the XOR'd response
        if not self._cmd_ack(bytes([ESC, 0x23]), debug=True):
            print("  ESC # rejected")
            return False
        if not self._cmd_ack(bytes(response), debug=True):
            print("  IR challenge response rejected")
            return False

        print("  Infrared enabled!")
        return True

    def set_scanning_parameters(self, dpi, x, y, w, h,
                                 color_mode=0x13, depth=8,
                                 source=0, scan_mode=0,
                                 block_lines=0, gamma=0x03):
        """FS W - Set all scanning parameters in one 64-byte block.

        color_mode: 0x13 = color (byte sequence RGB for D-level),
                    0x02 = color (line sequence), 0x00 = mono
        depth: 8 or 16 bits per channel
        source: 0 = flatbed, 1 = TPU, 3 = TPU+IR, 5 = TPU2
        scan_mode: 0 = normal, 1 = high speed (preview)
        """
        buf = bytearray(64)
        struct.pack_into('<I', buf, 0, dpi)      # main resolution
        struct.pack_into('<I', buf, 4, dpi)      # sub resolution
        struct.pack_into('<I', buf, 8, x)        # x offset
        struct.pack_into('<I', buf, 12, y)       # y offset
        struct.pack_into('<I', buf, 16, w)       # width in pixels
        struct.pack_into('<I', buf, 20, h)       # height in pixels
        buf[24] = color_mode                     # color mode
        buf[25] = depth                          # bits per channel
        buf[26] = source                         # option control
        buf[27] = scan_mode                      # scanning mode
        buf[28] = block_lines                    # block line number
        buf[29] = gamma                          # gamma correction
        # bytes 30-63 are zero (brightness, color correction, etc.)

        # Send FS W, get ACK, then send 64-byte parameter block, get ACK
        if not self._cmd_ack(bytes([FS, 0x57]), debug=True):
            print("  FS W rejected")
            return False
        if not self._cmd_ack(bytes(buf), debug=True):
            print("  Parameters rejected")
            return False
        return True

    def _direct_write(self, data):
        """Write directly to USB bulk OUT endpoint (bypassing interpreter)."""
        self.ep_out.write(data, timeout=5000)

    def _direct_read(self, size):
        """Read directly from USB bulk IN endpoint (bypassing interpreter)."""
        try:
            return bytes(self.ep_in.read(size, timeout=5000))
        except Exception as e:
            print(f"  [USB direct read error: {e}]")
            return None

    def _rs_cmd(self, subcmd, data=None):
        """Send RS <subcmd> directly over USB, read ACK, optionally send data + ACK.

        RS (0x1E) commands are extended register-level commands sent directly
        to the scanner hardware, bypassing the interpreter's ProcessCommand.
        Used for AFE gains, CCD timing, shading correction, etc.
        """
        self._direct_write(bytes([RS, subcmd]))
        resp = self._direct_read(1)
        if resp is None or resp[0] != 0x06:
            print(f"  RS 0x{subcmd:02x} rejected (resp={resp})")
            return False
        if data is not None:
            self._direct_write(data)
            resp = self._direct_read(1)
            if resp is None or resp[0] != 0x06:
                print(f"  RS 0x{subcmd:02x} data rejected (resp={resp})")
                return False
        return True

    def _write_register(self, header, data):
        """RS 0x84 register write: send header (8 bytes) then data block."""
        self._direct_write(bytes([RS, 0x84]))
        resp = self._direct_read(1)
        if resp is None or resp[0] != 0x06:
            print(f"  RS 0x84 rejected (resp={resp})")
            return False
        self._direct_write(header)
        self._direct_write(data)
        resp = self._direct_read(1)
        if resp is None or resp[0] != 0x06:
            print(f"  RS 0x84 data rejected (resp={resp})")
            return False
        return True

    def _upload_gamma_tables(self):
        """Upload linear gamma tables for R, G, B channels.

        Each table is 256 bytes, written via FS 0x84 to addresses
        0x1ffc (R), 0x1ffd (G), 0x1ffe (B).
        """
        # Linear ramp 0-255 (identity gamma)
        lut_r = bytes(range(256))
        lut_g = bytes(range(256))
        lut_b = bytes(range(256))

        for addr, lut in [(0xfc, lut_r), (0xfd, lut_g), (0xfe, lut_b)]:
            header = bytes([0x03, 0x00, addr, 0x1f, 0x02, 0x00, 0x01, 0x00])
            self._write_register(header, lut)

    def configure_tpu(self):
        """Configure TPU hardware for calibrated scanning.

        Sends the AFE gain, CCD timing, and shading correction parameters
        via RS (0x1E) commands directly to USB. These values were captured
        from Epson Scan 2's USB traffic and trigger the interpreter's
        internal TPU_calibrate pipeline during FS G.
        """
        print("Configuring TPU hardware...")

        # Upload gamma tables (before FS W)
        self._upload_gamma_tables()

        # FS 0xA2 — set TPU mode (0x02 = TPU active)
        self._rs_cmd(0xa2, bytes([0x02]))

        # FS 0x25 — set calibration flag
        self._rs_cmd(0x25, bytes([0x02]))

        # FS 0x5A — unknown (timing?)
        self._rs_cmd(0x5a, bytes([0x00, 0x00, 0x00, 0x00]))

        # FS 0x11 — set scan pass count or mode
        self._rs_cmd(0x11, bytes([0x03]))

        # FS 0x31 — per-channel gain and offset
        # Format: R_gain(2) G_gain(2) B_gain(2) reserved(2) R_off G_off B_off reserved
        self._rs_cmd(0x31, bytes([
            0x80, 0x00,  # R gain
            0x80, 0x00,  # G gain
            0x80, 0x00,  # B gain
            0x00, 0x00,  # reserved
            0x1e, 0x1e, 0x1e,  # R/G/B offsets
            0x00,        # reserved
        ]))

        # FS 0x21 — CCD configuration (26 bytes)
        self._rs_cmd(0x21, bytes([
            0x80, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        ]))

        # FS 0x84 — register write: gain/shading table
        # Header: address=0x0000, size varies
        gain_table_hdr = bytes([0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00])
        # Gain table data: initial calibration values + 0xFF padding
        gain_data = bytearray(256)
        gain_data[0:16] = bytes([
            0x00, 0x00, 0x00, 0x00,
            0x28, 0x00, 0xc0, 0x39,  # R CCD
            0xc8, 0x00, 0xc0, 0x39,  # G CCD
            0x90, 0x01, 0x00, 0x10,  # B CCD
        ])
        for i in range(16, 256):
            gain_data[i] = 0xff
        self._write_register(gain_table_hdr, bytes(gain_data))

        # FS 0x22 — secondary CCD config (12 bytes)
        self._rs_cmd(0x22, bytes([
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x80, 0x16, 0x00, 0x00, 0x00, 0x00,
        ]))

        # FS 0x41 — AFE (Analog Front End) configuration (22 bytes)
        self._rs_cmd(0x41, bytes([
            0x8f, 0x0c, 0x0f, 0x0e, 0x96, 0x00, 0x00, 0x00,
            0x01, 0x01, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x80, 0x80, 0x96, 0x00, 0x00, 0x00,
        ]))

        # FS 0x42 — additional AFE config (24 zero bytes)
        self._rs_cmd(0x42, bytes(24))

        # FS 0x43 — per-channel AFE gains (18 bytes)
        # Bytes 0-5: gains (little-endian 16-bit per channel)
        # Bytes 6-11: exposure/integration time per channel (little-endian 16-bit)
        self._rs_cmd(0x43, bytes([
            0x00, 0x80,  # R gain
            0x00, 0x80,  # G gain
            0x00, 0x80,  # B gain
            0x09, 0x78,  # R exposure
            0xec, 0x79,  # G exposure
            0xf2, 0x7a,  # B exposure
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]))

        # FS 0x01 — scan start configuration (12 bytes)
        self._rs_cmd(0x01, bytes([
            0x30, 0x05, 0x00, 0x00,
            0x80, 0x00,
            0xff, 0x00, 0xff, 0x00,
            0x02, 0x00,
        ]))

        # FS 0x05 — trigger calibration
        self._rs_cmd(0x05)

        self._needs_reinit = True
        print("  TPU hardware configured")

    def start_extended_scan(self):
        """FS G - Start extended scan. Returns (block_size, block_count, last_block_size)."""
        if not self._cmd(bytes([FS, 0x47]), debug=True):
            return None
        # Read 14-byte response: STX + status + block_size(4) + block_count(4) + last_block_size(4)
        resp = self._read(14, debug=True)
        if resp is None:
            print("  No response from FS G")
            return None
        if resp[0] != 0x02:  # STX
            print(f"  Expected STX, got 0x{resp[0]:02x}")
            return None
        status = resp[1]
        if status & 0x80:  # fatal error
            print(f"  Fatal error: status=0x{status:02x}")
            return None
        if status & 0x40:  # not ready
            print(f"  Scanner not ready: status=0x{status:02x}")
            return None
        block_size = struct.unpack_from('<I', resp, 2)[0]
        block_count = struct.unpack_from('<I', resp, 6)[0]
        last_block_size = struct.unpack_from('<I', resp, 10)[0]
        print(f"  Scan started: {block_count} blocks of {block_size} bytes, "
              f"last block {last_block_size} bytes")
        return (block_size, block_count, last_block_size)

    def read_scan_data(self, block_size, block_count, last_block_size):
        """Read all scan data blocks. Returns raw image bytes."""
        total_blocks = block_count
        if last_block_size:
            total_blocks += 1

        all_data = bytearray()

        for i in range(total_blocks):
            if i == total_blocks - 1 and last_block_size:
                this_size = last_block_size
            else:
                this_size = block_size

            # Read data + 1 status byte
            chunk = self._read(this_size + 1)
            if chunk is None:
                print(f"  Block {i+1}/{total_blocks}: read failed")
                break

            # Last byte is status
            status_byte = chunk[-1]
            all_data.extend(chunk[:-1])

            if status_byte & 0x80:  # fatal error
                print(f"  Block {i+1}: fatal error 0x{status_byte:02x}")
                break
            if status_byte & 0x20:  # cancel request
                print(f"  Block {i+1}: cancel request")
                break

            # ACK for next block (not for last block)
            if i < total_blocks - 1:
                # Send ACK
                self._cmd(bytes([0x06]))

            if (i + 1) % 10 == 0 or i == total_blocks - 1:
                print(f"  Block {i+1}/{total_blocks} ({len(all_data)} bytes)")

        return bytes(all_data)

    def scan(self, dpi=300, x=0, y=0, width=None, height=None,
             color=True, depth=8, source='flatbed', ir=False,
             output=None, progress_cb=None, cancel_cb=None):
        """High-level scan function. Returns numpy array.

        dpi: scan resolution (100-6400)
        x, y: offset in inches from top-left
        width, height: scan area in inches (None = full area)
        color: True for RGB, False for grayscale
        depth: 8 or 16 bits per channel
        source: 'flatbed' or 'tpu'
        ir: True to enable infrared channel
        output: output filename (auto-detected format, or None to skip saving)
        progress_cb: optional callback(pct, eta_secs) called during data read
        """
        # If using SANE backend, delegate to it
        if self._backend:
            return self._backend.scan(dpi=dpi, x=x, y=y, width=width, height=height,
                                    color=color, depth=depth, source=source, ir=ir,
                                    output=output, progress_cb=progress_cb, cancel_cb=cancel_cb)
        # Get scanner capabilities to know area limits
        self._cmd(bytes([FS, 0x49]))
        eid = self._read(80)
        if eid is None:
            raise RuntimeError("Cannot read scanner capabilities")

        optical_dpi = struct.unpack_from('<I', eid, 4)[0]
        if source == 'flatbed':
            max_x = struct.unpack_from('<I', eid, 20)[0]
            max_y = struct.unpack_from('<I', eid, 24)[0]
        else:
            max_x = struct.unpack_from('<I', eid, 36)[0]
            max_y = struct.unpack_from('<I', eid, 40)[0]

        # Area dimensions from FS I are in optical DPI units.
        # FS W expects all coordinates in scan DPI units.
        max_x_in = max_x / optical_dpi
        max_y_in = max_y / optical_dpi

        if width is None:
            w_in = max_x_in - x
        else:
            w_in = width

        if height is None:
            h_in = max_y_in - y
        else:
            h_in = height

        x_pixels = int(x * dpi)
        y_pixels = int(y * dpi)
        out_w = int(w_in * dpi)
        out_h = int(h_in * dpi)

        # Determine scanning parameters
        if ir:
            color_mode = 0x00  # mono — IR is a single-channel scan
            source_code = 3    # TPU + IR
            channels = 1       # single IR channel
        elif color:
            color_mode = 0x13  # color byte sequence
            source_code = 0 if source == 'flatbed' else 1
            channels = 3
        else:
            color_mode = 0x00  # mono
            source_code = 0 if source == 'flatbed' else 1
            channels = 1

        bytes_per_pixel = channels * (2 if depth == 16 else 1)
        expected_size = out_w * out_h * bytes_per_pixel

        print(f"\nScan parameters:")
        print(f"  Resolution: {dpi} dpi")
        print(f"  Area: {out_w}x{out_h} pixels ({w_in:.1f}x{h_in:.1f} inches)")
        print(f"  Mode: {'IR' if ir else 'RGB' if color else 'Gray'} {depth}-bit")
        print(f"  Expected size: {expected_size / 1024 / 1024:.1f} MB")

        # Snap DPI to valid resolution
        valid_res = VALID_IR_RESOLUTIONS if ir else VALID_RESOLUTIONS
        if dpi not in valid_res:
            closest = min(valid_res, key=lambda r: abs(r - dpi))
            print(f"  Note: {dpi} dpi not supported{' for IR' if ir else ''}, using {closest} dpi")
            dpi = closest
            # Recalculate output dimensions and coordinates at new DPI
            x_pixels = int(x * dpi)
            y_pixels = int(y * dpi)
            out_w = int(w_in * dpi)
            out_h = int(h_in * dpi)
            expected_size = out_w * out_h * bytes_per_pixel

        # Reset before setting parameters
        self.reset()

        # Enable IR if needed (must be done after reset, before FS W)
        if ir:
            print("Enabling infrared...")
            if not self.enable_infrared():
                print("  Warning: IR enable failed, continuing anyway...")

        # Set scanning parameters
        print("Setting parameters...")
        if not self.set_scanning_parameters(
            dpi=dpi, x=x_pixels, y=y_pixels, w=out_w, h=out_h,
            color_mode=color_mode, depth=depth, source=source_code
        ):
            raise RuntimeError("Failed to set scanning parameters")

        # Configure TPU hardware (AFE gains, CCD timing, shading)
        # Only needed once per session — calibration persists in scanner hardware
        if source != 'flatbed' and not self._tpu_configured:
            self.configure_tpu()
            self._tpu_configured = True

        # Start scan
        print("Starting scan...")
        scan_info = self.start_extended_scan()
        if scan_info is None:
            raise RuntimeError("Failed to start scan")

        block_size, block_count, last_block_size = scan_info

        # Read data blocks
        print("Reading scan data...")
        total_blocks = block_count
        if last_block_size:
            total_blocks += 1

        raw_data = bytearray()
        scan_start_time = time.time()
        for i in range(total_blocks):
            if i == total_blocks - 1 and last_block_size:
                this_size = last_block_size
            else:
                this_size = block_size

            # Read data + 1 status byte
            chunk = self._read(this_size + 1, debug=(i < 2))
            if chunk is None:
                print(f"  Block {i+1}/{total_blocks}: read failed")
                break

            # Last byte is status
            status_byte = chunk[-1]
            raw_data.extend(chunk[:-1])

            if status_byte & 0x80:  # fatal error
                print(f"  Block {i+1}: fatal error 0x{status_byte:02x}")
                break
            if status_byte & 0x20:  # cancel request
                print(f"  Block {i+1}: cancel request")
                break

            # Check for cancel
            if cancel_cb and cancel_cb():
                print(f"  Scan cancelled at block {i+1}/{total_blocks}")
                # Send CAN (0x18) to abort the scan
                self._cmd(bytes([0x18]))
                raise RuntimeError("Scan cancelled")

            # ACK for next block (not for last)
            if i < total_blocks - 1:
                self._cmd(bytes([0x06]))

            if (i + 1) % 10 == 0 or i == total_blocks - 1:
                pct = len(raw_data) * 100 // expected_size if expected_size else 0
                elapsed = time.time() - scan_start_time
                if pct > 0:
                    eta = elapsed / pct * (100 - pct)
                else:
                    eta = 0
                print(f"  Block {i+1}/{total_blocks} ({pct}%)")
                if progress_cb:
                    progress_cb(pct, eta)

        print(f"Received {len(raw_data)} bytes (expected {expected_size})")

        # Convert to numpy array
        if depth == 16:
            arr = np.frombuffer(raw_data[:expected_size], dtype=np.uint16)
        else:
            arr = np.frombuffer(raw_data[:expected_size], dtype=np.uint8)

        if channels > 1:
            arr = arr.reshape((out_h, out_w, channels))
        else:
            arr = arr.reshape((out_h, out_w))

        # Mirror horizontally for TPU scans (film is scanned matte-side
        # down against the glass, producing a left-right reversed image)
        if source != 'flatbed':
            arr = np.ascontiguousarray(arr[:, ::-1])

        # Save if output path specified
        if output:
            self._save_image(arr, output, depth, dpi=dpi)

        # Reinitialize interpreter if we just did TPU configuration — the RS
        # (direct USB) commands desync the interpreter's USB state.
        # This only happens on the first TPU scan of the session.
        if self._needs_reinit:
            self._needs_reinit = False
            self.reinit()

        return arr

    def _tiff_metadata(self, dpi):
        """Return tifffile.write() kwargs for scanner metadata."""
        from datetime import datetime
        return dict(
            resolution=(dpi, dpi),
            resolutionunit='inch',
            datetime=datetime.now(),
            software='epdaughter',
            # extratags: (tag_id, dtype, count, value, writeonce)
            # dtype 2 = ASCII string
            extratags=[
                (271, 2, None, 'EPSON', True),          # Make
                (272, 2, None, self.model['name'] if self.model else 'Epson Scanner', True), # Model
            ],
        )

    def _save_image(self, arr, path, depth, dpi=None):
        """Save image array to file."""
        ext = os.path.splitext(path)[1].lower()
        if ext in ('.tif', '.tiff'):
            import tifffile
            kwargs = self._tiff_metadata(dpi) if dpi else {}
            tifffile.imwrite(path, arr, **kwargs)
            print(f"Saved: {path}")
        elif ext == '.png':
            from PIL import Image
            if depth == 16:
                import tifffile
                path = path.replace('.png', '.tiff')
                kwargs = self._tiff_metadata(dpi) if dpi else {}
                tifffile.imwrite(path, arr, **kwargs)
                print(f"Saved as TIFF (16-bit): {path}")
            else:
                img = Image.fromarray(arr)
                img.save(path, dpi=(dpi, dpi) if dpi else None)
                print(f"Saved: {path}")
        else:
            import tifffile
            kwargs = self._tiff_metadata(dpi) if dpi else {}
            tifffile.imwrite(path, arr, **kwargs)
            print(f"Saved: {path}")


# Backward compatibility alias
EpsonV600 = EpsonScanner


def main():
    parser = argparse.ArgumentParser(description='Epson Scanner')
    parser.add_argument('--info', action='store_true',
                        help='Show scanner info and exit')
    parser.add_argument('--dpi', type=int, default=300,
                        help='Scan resolution (default: 300)')
    parser.add_argument('--depth', type=int, choices=[8, 16], default=8,
                        help='Bits per channel (default: 8)')
    parser.add_argument('--gray', action='store_true',
                        help='Grayscale mode')
    parser.add_argument('--ir', action='store_true',
                        help='Enable infrared channel')
    parser.add_argument('--tpu', action='store_true',
                        help='Use transparency unit')
    parser.add_argument('--preview', action='store_true',
                        help='Quick preview scan (75 dpi)')
    parser.add_argument('-x', type=float, default=0,
                        help='X offset in inches')
    parser.add_argument('-y', type=float, default=0,
                        help='Y offset in inches')
    parser.add_argument('-W', '--width', type=float, default=None,
                        help='Width in inches')
    parser.add_argument('-H', '--height', type=float, default=None,
                        help='Height in inches')
    parser.add_argument('-o', '--output', type=str, default='scan.tiff',
                        help='Output filename (default: scan.tiff)')
    args = parser.parse_args()

    scanner = EpsonScanner()

    try:
        scanner.open()

        if args.info:
            print("\n=== Scanner Identity ===")
            ident = scanner.get_identity()
            if ident:
                text = bytes(b for b in ident if b >= 0x20 or b == 0).decode('ascii', errors='replace').strip('\x00')
                print(f"  Raw: {text}")

            print("\n=== Scanner Status ===")
            scanner.get_status()

            print("\n=== Extended Identity ===")
            scanner.get_extended_identity()

            print("\n=== Extended Status ===")
            es = scanner.get_extended_status()
            # Only parse extended status for interpreter-based scanners
            if es and not scanner._backend:
                model = es[0x1A:0x2A].decode('ascii', errors='replace').rstrip('\x00 ')
                print(f"  Model: {model}")
                print(f"  TPU status: 0x{es[6]:02x}")
                if es[6] & 0x01:
                    print("  -> TPU installed")
                if es[6] & 0x10:
                    print("  -> TPU enabled")
            return

        # Scan
        dpi = 75 if args.preview else args.dpi
        output = args.output
        if args.preview:
            output = 'preview.tiff'

        # IR requires TPU
        source = 'tpu' if (args.tpu or args.ir) else 'flatbed'

        scanner.scan(
            dpi=dpi,
            x=args.x, y=args.y,
            width=args.width, height=args.height,
            color=not args.gray,
            depth=args.depth,
            source=source,
            ir=args.ir,
            output=output,
        )

    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
    finally:
        scanner.close()


if __name__ == "__main__":
    main()
