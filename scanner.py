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

# Scanner USB IDs
VENDOR_ID = 0x04b8
PRODUCT_ID = 0x013a

# Interpreter bundle path
INTERP_PATH = "/Library/Image Capture/Support/EPSON/Epson Scan 2/Models/ES00A1/Interpreter A1.bundle/Contents/MacOS/Interpreter A1"

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

# Valid scan resolutions for the V600
VALID_RESOLUTIONS = [100, 200, 400, 533, 600, 800, 1200, 1600, 3200, 6400]
VALID_IR_RESOLUTIONS = [800, 1600, 3200]


class EpsonV600:
    def __init__(self):
        self.dev = None
        self.ep_in = None
        self.ep_out = None
        self.interp = None
        self._read_cb = None   # prevent GC
        self._write_cb = None  # prevent GC
        self.verbose_usb = False  # trace USB callbacks

    def open(self):
        """Open USB device and initialize interpreter."""
        # Find and configure USB device
        self.dev = usb.core.find(idVendor=VENDOR_ID, idProduct=PRODUCT_ID)
        if self.dev is None:
            raise RuntimeError("Epson V600 not found on USB")

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

        # Load interpreter
        if not os.path.exists(INTERP_PATH):
            raise RuntimeError(f"Interpreter not found: {INTERP_PATH}")

        self.interp = ctypes.CDLL(INTERP_PATH)
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

        # Initialize interpreter — this uploads firmware to the scanner
        print("Initializing scanner (uploading firmware)...")
        result = self.interp.INTInit(
            ctypes.cast(self._read_cb, ctypes.c_void_p),
            ctypes.cast(self._write_cb, ctypes.c_void_p),
            ctypes.c_void_p(0),  # usb_handle - we don't need it, we use self
        )

        if not result:
            usb_err = self.interp.INTGetUSBError()
            int_err = self.interp.INTGetInterpreterError()
            raise RuntimeError(f"INTInit failed: USB err={usb_err}, interp err={int_err}")

        print("Scanner initialized!")
        return True

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

    def close(self):
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
        self._cmd(bytes([ESC, 0x49]))
        return self._read(256)

    def get_status(self):
        """ESC F - Request status."""
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

    def get_extended_status(self):
        """ESC f - Extended status."""
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
             output=None, raw=False):
        """High-level scan function. Returns numpy array.

        dpi: scan resolution (100-6400)
        x, y: offset in inches from top-left
        width, height: scan area in inches (None = full area)
        color: True for RGB, False for grayscale
        depth: 8 or 16 bits per channel
        source: 'flatbed' or 'tpu'
        ir: True to enable infrared channel
        output: output filename (auto-detected format, or None to skip saving)
        """
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

        # Convert inches to scanner pixels at the requested DPI
        # Scanner area units are in optical DPI
        x_pixels = int(x * optical_dpi)
        y_pixels = int(y * optical_dpi)

        if width is None:
            w_pixels = int(max_x - x_pixels)
        else:
            w_pixels = int(width * optical_dpi)

        if height is None:
            h_pixels = int(max_y - y_pixels)
        else:
            h_pixels = int(height * optical_dpi)

        # Scale pixels to requested DPI
        out_w = int(w_pixels * dpi / optical_dpi)
        out_h = int(h_pixels * dpi / optical_dpi)

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
        print(f"  Area: {out_w}x{out_h} pixels ({w_pixels/optical_dpi:.1f}x{h_pixels/optical_dpi:.1f} inches)")
        print(f"  Mode: {'IR' if ir else 'RGB' if color else 'Gray'} {depth}-bit")
        print(f"  Expected size: {expected_size / 1024 / 1024:.1f} MB")

        # Snap DPI to valid resolution
        valid_res = VALID_IR_RESOLUTIONS if ir else VALID_RESOLUTIONS
        if dpi not in valid_res:
            closest = min(valid_res, key=lambda r: abs(r - dpi))
            print(f"  Note: {dpi} dpi not supported{' for IR' if ir else ''}, using {closest} dpi")
            dpi = closest
            # Recalculate output dimensions
            out_w = int(w_pixels * dpi / optical_dpi)
            out_h = int(h_pixels * dpi / optical_dpi)
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

            # ACK for next block (not for last)
            if i < total_blocks - 1:
                self._cmd(bytes([0x06]))

            if (i + 1) % 10 == 0 or i == total_blocks - 1:
                pct = len(raw_data) * 100 // expected_size if expected_size else 0
                print(f"  Block {i+1}/{total_blocks} ({pct}%)")

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

        # White balance for TPU scans (compensate for lamp spectrum)
        if source != 'flatbed' and channels == 3 and not raw:
            arr = self._white_balance(arr, depth)

        # Save if output path specified
        if output:
            self._save_image(arr, output, depth)

        return arr

    def _white_balance(self, arr, depth):
        """White balance for TPU scans: black subtraction + per-channel gain.

        For transmissive scans, the clear background (no film) represents
        maximum light per channel. The TPU lamp has a green-biased spectrum,
        so channels need independent gain correction.

        Steps:
        1. Subtract per-channel black level (dark current / noise floor)
        2. Compute per-channel white reference from brightest pixels
        3. Scale all channels so white reference maps to ~95% of max value
        """
        max_val = 65535 if depth == 16 else 255
        dtype = np.uint16 if depth == 16 else np.uint8

        r = arr[:,:,0].astype(np.float64)
        g = arr[:,:,1].astype(np.float64)
        b = arr[:,:,2].astype(np.float64)

        # Step 1: Black level subtraction (use 0.5th percentile per channel)
        r_black = np.percentile(r, 0.5)
        g_black = np.percentile(g, 0.5)
        b_black = np.percentile(b, 0.5)
        print(f"  Black levels: R={r_black:.0f} G={g_black:.0f} B={b_black:.0f}")

        r = np.maximum(r - r_black, 0)
        g = np.maximum(g - g_black, 0)
        b = np.maximum(b - b_black, 0)

        # Step 2: White reference (per-channel 99.5th percentile)
        # Using per-channel percentiles avoids the problem where combined
        # brightness selects pixels that aren't the true per-channel max
        r_ref = np.percentile(r, 99.5)
        g_ref = np.percentile(g, 99.5)
        b_ref = np.percentile(b, 99.5)

        if min(r_ref, g_ref, b_ref) < 1:
            print("  White balance: skipped (too dark)")
            return arr

        # Step 3: Compute gains to map white reference to 95% of max value
        # Using 95% leaves headroom to avoid hard clipping
        target = 0.95 * max_val
        r_gain = target / r_ref
        g_gain = target / g_ref
        b_gain = target / b_ref
        print(f"  White ref: R={r_ref:.0f} G={g_ref:.0f} B={b_ref:.0f}")
        print(f"  Gains: R×{r_gain:.3f} G×{g_gain:.3f} B×{b_gain:.3f}")

        r_out = np.clip(r * r_gain, 0, max_val).astype(dtype)
        g_out = np.clip(g * g_gain, 0, max_val).astype(dtype)
        b_out = np.clip(b * b_gain, 0, max_val).astype(dtype)
        return np.stack([r_out, g_out, b_out], axis=2)

    def _save_image(self, arr, path, depth):
        """Save image array to file."""
        ext = os.path.splitext(path)[1].lower()
        if ext in ('.tif', '.tiff'):
            import tifffile
            tifffile.imwrite(path, arr)
            print(f"Saved: {path}")
        elif ext == '.png':
            from PIL import Image
            if depth == 16:
                # PIL doesn't handle 16-bit well, use tifffile instead
                import tifffile
                path = path.replace('.png', '.tiff')
                tifffile.imwrite(path, arr)
                print(f"Saved as TIFF (16-bit): {path}")
            else:
                img = Image.fromarray(arr)
                img.save(path)
                print(f"Saved: {path}")
        else:
            import tifffile
            tifffile.imwrite(path, arr)
            print(f"Saved: {path}")


def main():
    parser = argparse.ArgumentParser(description='Epson V600 Scanner')
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
    parser.add_argument('--raw', action='store_true',
                        help='Skip white balance (raw sensor data)')
    parser.add_argument('-o', '--output', type=str, default='scan.tiff',
                        help='Output filename (default: scan.tiff)')
    args = parser.parse_args()

    scanner = EpsonV600()

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
            if es:
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
            raw=args.raw,
        )

    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()
    finally:
        scanner.close()


if __name__ == "__main__":
    main()
