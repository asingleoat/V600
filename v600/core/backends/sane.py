"""SANE backend for Epson V600 scanner on Linux."""

import os
import subprocess
import tempfile
import time
from datetime import datetime
import numpy as np
import tifffile
from PIL import Image

from v600.imaging.lut import create_lut_file
from v600.core.constants import SCANNER_MODELS, VALID_RESOLUTIONS, VALID_IR_RESOLUTIONS

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
                print("Using epkowa backend (patched for 16-bit and IR support)")
                device_to_use = epkowa_device
            
            # Cache the device name
            if device_to_use:
                SaneEpsonScanner._cached_device_name = device_to_use
                SaneEpsonScanner._cache_timestamp = current_time
                print("Cached device name for future use")
            
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
            except Exception:
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
        print("  Command level: 2.0")
        print(f"  Model:         {self.model['name']}")
        print("  ** IR scanning SUPPORTED (via SANE) **")
        return b'\x00' * 80  # Mock response
        
    def scan(self, dpi=300, x=0, y=0, width=None, height=None,
             color=True, depth=8, source='flatbed', ir=False,
             output=None, progress_cb=None, cancel_cb=None,
             lut_r=None, lut_g=None, lut_b=None):
        """High-level scan function using SANE backend.
        
        Parameters are similar to the interpreter-based scanner but uses
        SANE scanimage command for actual scanning.
        """
        
        # Handle custom LUTs if provided
        lut_file = None
        lut_dispatcher = None
        if any(lut is not None for lut in (lut_r, lut_g, lut_b)):
            try:
                # Create LUT file for dispatcher to read
                from v600.imaging.lut import create_lut_file
                lut_file = create_lut_file(lut_r, lut_g, lut_b)
                
                # Check if LUT dispatcher is available, compile if needed
                lut_dispatcher = os.path.join(os.path.dirname(__file__), 'libesintA1_lut.so')
                lut_dispatcher_src = os.path.join(os.path.dirname(__file__), 'lut_dispatcher.c')
                
                if not os.path.exists(lut_dispatcher) and os.path.exists(lut_dispatcher_src):
                    # Try to compile the dispatcher
                    print("  Compiling LUT dispatcher...")
                    import subprocess
                    try:
                        result = subprocess.run(
                            ['gcc', '-shared', '-fPIC', '-o', lut_dispatcher, lut_dispatcher_src, '-ldl'],
                            capture_output=True,
                            text=True,
                            check=True
                        )
                        print("  LUT dispatcher compiled successfully")
                    except subprocess.CalledProcessError as e:
                        print(f"  Warning: Failed to compile LUT dispatcher: {e.stderr}")
                        lut_dispatcher = None
                    except FileNotFoundError:
                        print("  Warning: gcc not found, cannot compile LUT dispatcher")
                        lut_dispatcher = None
                
                if os.path.exists(lut_dispatcher):
                    print("  Using custom LUTs via dispatcher")
                else:
                    print("  Note: LUT dispatcher not available, LUTs will be metadata only")
                    lut_dispatcher = None
            except (ImportError, Exception) as e:
                print(f"  Note: Custom LUTs provided but could not set up: {e}")
                print("        LUTs will be computed and stored as metadata only")
                lut_file = None
                lut_dispatcher = None
        
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
            
        print("\nScan parameters:")
        print(f"  Resolution: {dpi} dpi")
        print(f"  Mode: {'IR' if ir else 'RGB' if color else 'Gray'} {depth}-bit")
        print(f"  Source: {sane_source}")
        
        # Calculate scan area
        if width is not None or height is not None or x != 0 or y != 0:
            print(f"  Area: offset ({x:.1f}, {y:.1f}) inches, size ({width or 'full'}x{height or 'full'}) inches")
            
        # Use the appropriate wrapper script for V600 scanning
        env = os.environ.copy()
        
        # Add LUT support if dispatcher is available
        if lut_file and lut_dispatcher:
            env['V600_LUT_FILE'] = lut_file
            env['V600_LUT_VERBOSE'] = '1'
            # Prepend our dispatcher to LD_PRELOAD
            existing_preload = env.get('LD_PRELOAD', '')
            env['LD_PRELOAD'] = lut_dispatcher + (':' + existing_preload if existing_preload else '')
        
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
            except Exception:
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
            
            print("Scan completed successfully")
            
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
                new_h = int(h * scale_factor)
                new_w = int(w * scale_factor)
                
                img = Image.fromarray(arr)
                img = img.resize((new_w, new_h), Image.LANCZOS)
                arr = np.array(img)
                print(f"Downsampled from {dpi} to {original_dpi} DPI: {arr.shape}")
            
            # Mirror horizontally for TPU scans (same as original code)
            if source != 'flatbed':
                arr = np.ascontiguousarray(arr[:, ::-1])
                
            # Save with LUT metadata if output specified
            if output:
                self._save_image(arr, output, depth, dpi=dpi, lut_r=lut_r, lut_g=lut_g, lut_b=lut_b)
            else:
                # Clean up temp file if no output specified
                os.unlink(temp_file)
            
            # Clean up LUT file if we created one
            if lut_file and os.path.exists(lut_file):
                try:
                    os.unlink(lut_file)
                except Exception:
                    pass  # Don't fail if cleanup fails
                
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
            
    def _save_image(self, arr, path, depth, dpi=None, lut_r=None, lut_g=None, lut_b=None):
        """Save image array to file - same as original implementation."""
        ext = os.path.splitext(path)[1].lower()
        if ext in ('.tif', '.tiff'):
            import tifffile
            kwargs = self._tiff_metadata(dpi, lut_r, lut_g, lut_b) if dpi else {}
            tifffile.imwrite(path, arr, **kwargs)
            print(f"Saved: {path}")
        elif ext == '.png':
            from PIL import Image
            if depth == 16:
                import tifffile
                path = path.replace('.png', '.tiff')
                kwargs = self._tiff_metadata(dpi, lut_r, lut_g, lut_b) if dpi else {}
                tifffile.imwrite(path, arr, **kwargs)
                print(f"Saved as TIFF (16-bit): {path}")
            else:
                img = Image.fromarray(arr)
                img.save(path, dpi=(dpi, dpi) if dpi else None)
                print(f"Saved: {path}")
        else:
            import tifffile
            kwargs = self._tiff_metadata(dpi, lut_r, lut_g, lut_b) if dpi else {}
            tifffile.imwrite(path, arr, **kwargs)
            print(f"Saved: {path}")
            
    def _tiff_metadata(self, dpi, lut_r=None, lut_g=None, lut_b=None):
        """Return tifffile.write() kwargs for scanner metadata."""
        from datetime import datetime
        tags = [
            (271, 2, None, 'EPSON', True),          # Make
            (272, 2, None, self.model['name'] if self.model else 'Epson Scanner', True), # Model
        ]
        # Add LUT metadata if custom LUTs were used
        if lut_r and lut_g and lut_b:
            # Store a marker that custom LUTs were applied
            tags.append((50000, 2, None, 'Custom film LUTs applied', True))
        return dict(
            resolution=(dpi, dpi),
            resolutionunit='inch',
            datetime=datetime.now(),
            software='epdaughter-sane',
            extratags=tags
        )


