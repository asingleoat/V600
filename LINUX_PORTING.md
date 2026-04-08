# Linux Porting Guide for epdaughter

## Architecture Overview

The scanner driver has three communication layers:

1. **Interpreter layer** (INTWrite/INTRead) — a proprietary Epson shared library that translates ESC/I commands into USB register operations. We load it via ctypes and provide USB I/O callbacks.

2. **ESC/I layer** (ESC 0x1B, FS 0x1C) — standard Epson scanner commands for scan setup and data transfer. These go through the interpreter.

3. **RS layer** (RS 0x1E) — direct register-level commands sent to USB bulk endpoints, bypassing the interpreter. Used for TPU hardware calibration.

## USB Device Setup

- Vendor ID: `0x04b8` (Epson)
- Product IDs:
  - `0x0128` — Perfection 4870 / GT-X700 (Interpreter 41)
  - `0x012a` — Perfection 4990 / GT-X800 (Interpreter 52)
  - `0x012c` — Perfection V700/V750 / GT-X900 (Interpreter 7A)
  - `0x0135` — GT-X970 (Interpreter 86)
  - `0x013a` — Perfection V600 / GT-X820 (Interpreter A1) **[tested]**
  - `0x0151` — Perfection V800/V850 / GT-X980 (Interpreter AD)
- Interface: `(0, 0)` — configuration 0, alternate setting 0
- Endpoints: 2 bulk — one IN (0x81), one OUT (0x02)

On Linux, pyusb with libusb1 backend should work. You may need udev rules for non-root access:

```
# /etc/udev/rules.d/99-epson-scanner.rules
SUBSYSTEM=="usb", ATTR{idVendor}=="04b8", MODE="0666"
```

Kernel driver detach: Linux's `usb-storage` or other kernel drivers may claim the device. pyusb's `detach_kernel_driver(0)` handles this. Our code already wraps this in try/except.

## Interpreter Binary

### What It Is

A native shared library (Mach-O bundle on macOS, ELF .so on Linux) that:
- Accepts ESC/I commands via `INTWrite(buf, len)`
- Returns responses via `INTRead(buf, len)`
- Internally translates commands into USB register read/write operations
- Calls back into our USB I/O functions for actual USB communication
- During `INTInit`, uploads firmware to the scanner hardware

### Exported Functions

```c
// Initialize — uploads firmware, registers callbacks
// Returns: 1=success, 0=failure
uint8_t INTInit(void* read_cb, void* write_cb, void* usb_handle);

// Send ESC/I command
uint8_t INTWrite(uint8_t* buf, uint32_t len);

// Read ESC/I response
uint8_t INTRead(uint8_t* buf, uint32_t len);

// Cleanup
void INTClose(void);

// Error codes
int16_t INTGetUSBError(void);
int32_t INTGetInterpreterError(void);
```

### Callback Signature

Both read and write callbacks have the same signature:

```c
typedef int8_t (*usb_callback_t)(
    uint8_t* buf,      // data buffer
    uint32_t len,      // byte count
    void* handle,      // opaque context (passed from INTInit, we use NULL)
    int16_t* err       // output: error code (0=ok, -1=error)
);
```

**Read callback**: Read `len` bytes from USB bulk IN endpoint into `buf`.
**Write callback**: Write `len` bytes from `buf` to USB bulk OUT endpoint.

Return 1 for success, 0 for failure. Set `*err` to 0 on success, -1 on error.

### ctypes Setup (Python)

```python
import ctypes

USB_CALLBACK = ctypes.CFUNCTYPE(
    ctypes.c_int8,                    # return: 1=success, 0=failure
    ctypes.POINTER(ctypes.c_uint8),   # buffer
    ctypes.c_uint32,                  # length
    ctypes.c_void_p,                  # usb_handle
    ctypes.POINTER(ctypes.c_int16),   # error output
)

interp = ctypes.CDLL("/path/to/interpreter.so")

interp.INTInit.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
interp.INTInit.restype = ctypes.c_uint8

interp.INTWrite.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.c_uint32]
interp.INTWrite.restype = ctypes.c_uint8

interp.INTRead.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.c_uint32]
interp.INTRead.restype = ctypes.c_uint8

interp.INTClose.argtypes = []
interp.INTClose.restype = None
```

**Critical**: Store callback references in persistent variables to prevent garbage collection:

```python
read_cb = USB_CALLBACK(my_read_function)
write_cb = USB_CALLBACK(my_write_function)
# These MUST stay alive for the lifetime of the interpreter session
```

### Finding the Interpreter on Linux

The macOS interpreter is a Mach-O binary and **will not work on Linux**. You need the Linux ELF version. Options:

1. **Epson's Linux packages** — Check if `imagescan` or `iscan` packages include interpreter .so files
2. **Extract from Epson's .deb/.rpm packages** — Available from Epson's Linux download page
3. **The ICA macOS package** — Contains Mach-O binaries only, not usable on Linux

Search paths on Linux:
```
./firmware/Interpreter {ID}
/usr/lib/epson/interpreter/Interpreter {ID}
/opt/epson/Interpreter {ID}
```

The interpreter ID (e.g., "A1" for V600) maps to the scanner model — see the product ID table above.

## Scan Flow

### Minimal Scan Sequence

```
1. INTInit(read_cb, write_cb, NULL)     — upload firmware (~10s)
2. ESC @ (0x1b 0x40)                    — reset scanner
   → expect ACK (0x06)
3. FS W (0x1c 0x57)                     — set scan parameters
   → expect ACK
   → send 64-byte parameter block
   → expect ACK
4. FS G (0x1c 0x47)                     — start scan
   → read 14-byte response (STX + status + block info)
5. For each block:
   → INTRead(block_size + 1)            — data + status byte
   → send ACK (0x06) for next block
6. ESC @ (reset)                        — cleanup
```

### FS W Parameter Block (64 bytes)

```
Offset  Size  Field
0-3     u32   Main resolution (DPI, little-endian)
4-7     u32   Sub resolution (same as main)
8-11    u32   X offset (pixels at scan DPI)
12-15   u32   Y offset (pixels at scan DPI)
16-19   u32   Width (pixels at scan DPI)
20-23   u32   Height (pixels at scan DPI)
24      u8    Color mode: 0x00=mono, 0x13=RGB byte-seq
25      u8    Depth: 8 or 16
26      u8    Source: 0=flatbed, 1=TPU, 3=TPU+IR
27      u8    Scan mode: 0=normal, 1=preview
28      u8    Block lines (0=default)
29      u8    Gamma: 0x03=linear
30-63         Reserved (zeros)
```

### FS G Response (14 bytes)

```
Offset  Size  Field
0       u8    STX (0x02)
1       u8    Status (0x80=fatal, 0x40=not ready)
2-5     u32   Block size (bytes)
6-9     u32   Block count
10-13   u32   Last block size (0 if no partial block)
```

Total blocks = block_count + (1 if last_block_size > 0).
Each block read returns block_size+1 bytes (last byte is status).

## TPU Calibration (RS Commands)

Without this sequence, TPU scans have a massive green color cast because the analog front-end (AFE) gains are not calibrated for the TPU lamp spectrum.

RS commands use prefix byte `0x1E` and go **directly to USB bulk endpoints**, NOT through INTWrite/INTRead. The protocol is:

```
Write to bulk OUT: [0x1E, subcmd]
Read from bulk IN:  [0x06]          (ACK)
(if data payload)
Write to bulk OUT: [data...]
Read from bulk IN:  [0x06]          (ACK)
```

### Full Calibration Sequence

```python
# Upload linear gamma tables (identity LUT, 256 bytes each for R/G/B)
for addr in [0xfc, 0xfd, 0xfe]:  # R, G, B gamma table addresses
    RS 0x84 → ACK
    write header: [0x03, 0x00, addr, 0x1f, 0x02, 0x00, 0x01, 0x00]
    write data:   [0x00, 0x01, 0x02, ..., 0xff]  (256 bytes linear ramp)
    → ACK

# Enable TPU mode
RS 0xA2 → ACK → [0x02] → ACK

# Set calibration flag
RS 0x25 → ACK → [0x02] → ACK

# Timing config
RS 0x5A → ACK → [0x00, 0x00, 0x00, 0x00] → ACK

# Scan pass mode
RS 0x11 → ACK → [0x03] → ACK

# Per-channel gain and offset
RS 0x31 → ACK → [
    0x80, 0x00,   # R gain (128, nominal)
    0x80, 0x00,   # G gain
    0x80, 0x00,   # B gain
    0x00, 0x00,   # reserved
    0x1e, 0x1e, 0x1e,  # R/G/B offsets (30 each)
    0x00          # reserved
] → ACK

# CCD configuration
RS 0x21 → ACK → [
    0x80, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00
] → ACK

# Gain/shading register write
RS 0x84 → ACK
write header: [0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
write data (256 bytes): [
    0x00, 0x00, 0x00, 0x00,
    0x28, 0x00, 0xc0, 0x39,   # R CCD
    0xc8, 0x00, 0xc0, 0x39,   # G CCD
    0x90, 0x01, 0x00, 0x10,   # B CCD
    0xff × 240                  # padding
] → ACK

# Secondary CCD config
RS 0x22 → ACK → [
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x80, 0x16, 0x00, 0x00, 0x00, 0x00
] → ACK

# AFE configuration
RS 0x41 → ACK → [
    0x8f, 0x0c, 0x0f, 0x0e, 0x96, 0x00, 0x00, 0x00,
    0x01, 0x01, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x80, 0x80, 0x96, 0x00, 0x00, 0x00
] → ACK

# AFE config extended
RS 0x42 → ACK → [24 zero bytes] → ACK

# Per-channel AFE gains and exposure
RS 0x43 → ACK → [
    0x00, 0x80,   # R gain
    0x00, 0x80,   # G gain
    0x00, 0x80,   # B gain
    0x09, 0x78,   # R exposure (30729)
    0xec, 0x79,   # G exposure (31212)
    0xf2, 0x7a,   # B exposure (31474)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00
] → ACK

# Scan start configuration
RS 0x01 → ACK → [
    0x30, 0x05, 0x00, 0x00,
    0x80, 0x00,
    0xff, 0x00, 0xff, 0x00,
    0x02, 0x00
] → ACK

# Trigger calibration
RS 0x05 → ACK
```

### Important: Reinit After RS Commands

After sending RS commands, the interpreter's USB state is desynchronized. Before the next ESC/I command, you MUST call:

```python
interp.INTClose()
interp.INTInit(read_cb, write_cb, NULL)
```

This re-uploads firmware (~10s). It only needs to happen once per session — the calibration persists in scanner hardware across reinits.

## IR Scanning

### Challenge-Response Protocol (ESC #)

Required before scanning with source=3 (TPU+IR). Minimum 800 DPI.

```python
# Step 1: Read current scanning parameters
send:  FS S (0x1c 0x53)
read:  64 bytes (current parameter block)

# Step 2: XOR first 32 bytes with hardcoded key
XOR_KEY = bytes([
    0xCA, 0xFB, 0x77, 0x71, 0x20, 0x16, 0xDA, 0x09,
    0x5F, 0x57, 0x09, 0x12, 0x04, 0x83, 0x76, 0x77,
    0x3C, 0x73, 0x9C, 0xBE, 0x7A, 0xE0, 0x52, 0xE2,
    0x90, 0x0D, 0xFF, 0x9A, 0xEF, 0x4C, 0x2C, 0x81,
])
response = bytes(key[i] ^ params[i] for i in range(32))

# Step 3: Send challenge-response
send:  ESC # (0x1b 0x23) → ACK
send:  response (32 bytes) → ACK
```

### IR Scan Parameters

- Source code: 3 (TPU + IR)
- Color mode: 0x00 (mono — single channel)
- Valid DPI: 800, 1600, 3200 only
- Output: 1 channel grayscale (8-bit or 16-bit)
- Clear background appears bright (254-255 in 8-bit)
- Dust/scratches appear dark (they block infrared)

## Data Format

Scan data is raw interleaved RGB (or mono) pixels, row by row:

- **8-bit RGB**: `R G B R G B ...` (3 bytes/pixel)
- **16-bit RGB**: `Rl Rh Gl Gh Bl Bh ...` (6 bytes/pixel, little-endian)
- **8-bit mono**: `G G G ...` (1 byte/pixel)
- **16-bit mono**: `Gl Gh Gl Gh ...` (2 bytes/pixel, little-endian)

Block size = one scanline × bytes_per_pixel (usually).

## FS I Response Format (80 bytes)

Query with `FS I` (0x1c 0x49). The response contains scanner capabilities:

```
Offset  Size  Field
0-1     2     Command level (ASCII, e.g. "D1")
4-7     u32   Optical DPI (6400 for V600)
8-11    u32   Minimum DPI
12-15   u32   Maximum DPI
16-19   u32   Max pixels per line
20-23   u32   Flatbed width (in optical DPI pixels)
24-27   u32   Flatbed height (in optical DPI pixels)
28-31   u32   ADF width (0 if no ADF)
32-35   u32   ADF height
36-39   u32   TPU width (in optical DPI pixels)
40-43   u32   TPU height (in optical DPI pixels)
44      u8    Capabilities: bit 1 (0x02) = IR supported, bit 7 (0x80) = push button
46-61   16    Model name (ASCII, null-padded)
66      u8    Input bit depth
67      u8    Max output bit depth
```

To convert TPU area to inches: `tpu_width_in = tpu_width / optical_dpi`.
All FS W coordinates are in **scan DPI** pixels, not optical DPI.

## Additional Commands from USB Capture

These are sent by Epson Scan 2 but not all are required for basic scanning:

### Polling / Status

- `ESC ETX` (0x1b 0x03) — Status poll. Response is 2 bytes: `[0x18, status]`
  - Status `0x01` = idle/ready
  - Status `0x81` = busy (after reset, firmware uploading)
  - Epson Scan 2 sends this repeatedly while waiting for scanner to be ready

- `RS 0x85` — Scanner status query. Response is 1 byte: `0x00` = ready

### Pre-scan Queries

- `RS 0xE1` — Unknown config command. Data: `[0x0b, 0x00, 0x0c, 0x4c, 0x00, 0x00]`
- `RS 0x9F` — Query command. Response: 1 byte (0x10 observed)
- `ESC 0x13` — Extended identity. Response: 28 bytes ASCII model string "EPSON   GT-X820         1.10"
- `RS 0xA1` — TPU capability query. Response: 1 byte (0x0b observed)
- `RS 0x65` — Extension status. Response: 1 byte (0x00 observed)
- `RS 0xE2` — Hardware query. ACK, then send 2-byte subcommand, receive 4-byte response:
  - Subcommand `[0x05, 0x00]` → response `[0xd1, 0x00, 0x00, 0x00]`
  - Subcommand `[0x10, 0x00]` → response `[0x00, 0x00, 0x00, 0x00]`

### Pre-calibration (before RS 0xA2)

- `RS 0x86` — Read calibration status. Response: 4 bytes
  - `[0x00, 0x00, 0x00, 0x00]` = not yet calibrated
  - `[0x96, 0x05, 0x00, 0x00]` = calibrated (after RS 0x05 trigger)
- `RS 0x25` with data `[0x00]` — Reset calibration flag (sent before gamma upload)

### Shading Correction Table (RS 0x84 with header 0x05)

Between FS W and the calibration sequence, Epson Scan 2 uploads a 1536-byte shading correction table:

```
RS 0x84 → ACK
Header: [0x05, 0x00, 0x00, 0x01, 0x02, 0x00, 0x06, 0x00]
Data:   1536 bytes (per-pixel correction values)
```

This is followed by `RS 0x01` with different data than the calibration sequence:
```
RS 0x01 → ACK → [0x96, 0x02, 0x00, 0x00, 0x00, 0x00, 0xff, 0x01, 0xff, 0x00, 0x10, 0x00]
```

Then `RS 0x05` triggers the first calibration pass.

### FS W via RS Prefix

Note: Epson Scan 2 sends FS W as `RS W` (0x1e 0x57), not `FS W` (0x1c 0x57).
Both prefixes (0x1c and 0x1e) work for FS commands in our testing, but the
USB capture shows Epson Scan 2 consistently uses 0x1e for everything.

### FS S Response (42 bytes, not 64)

The FS S (0x1e 0x53) response in the capture is 42 bytes, not the 64 bytes
described in some ESC/I documentation. The first 42 bytes match the FS W
parameter block layout. Our code reads 64 bytes which works (extra bytes are zero).

## TPU Mirror

TPU scans must be horizontally mirrored for correct orientation when film is
placed matte-side down against the glass (for sharpest results / least Newton rings).
We apply `arr[:, ::-1]` to all TPU scan output.

In the GUI, the preview shows the mirrored image. Selection coordinates must be
un-mirrored when sent to the scanner: `scanner_x = tpu_width - (display_x + display_w)`.

## Coordinate Pitfall

FS I returns TPU area dimensions in **optical DPI** pixels (e.g., 6400 DPI).
FS W expects all coordinates (x, y, w, h) in **scan DPI** pixels.

```python
# WRONG: mixing coordinate systems
x_pixels = int(x_inches * optical_dpi)  # 6400 DPI
w_pixels = int(w_inches * scan_dpi)     # 400 DPI

# CORRECT: all in scan DPI
x_pixels = int(x_inches * scan_dpi)
w_pixels = int(w_inches * scan_dpi)
```

## Valid Resolutions

The interpreter validates DPI and NAKs invalid values. Known valid resolutions:
- **General**: 100, 200, 400, 533, 600, 800, 1200, 1600, 3200, 6400
- **IR only**: 800, 1600, 3200
- **TPU minimum**: 200 DPI (100 DPI is rejected for TPU source)

## Complete USB Packet Trace

The raw USB packet trace from a full Epson Scan 2 session (connect + preview scan)
is available in `xhc0-initial-connect.pcapng`. This can be parsed with the Python
script used in development — see git history for the pcapng parser.

## Notes for Linux-Specific Issues

1. **Interpreter binary format**: The macOS interpreter is Mach-O. Linux needs an ELF .so version. Check Epson's Linux scanner packages (iscan, imagescan).

2. **USB permissions**: Add udev rules or run as root. The interpreter's USB callbacks need unrestricted bulk endpoint access.

3. **Callback ABI**: Same x86-64 System V calling convention on both macOS and Linux. ctypes.CFUNCTYPE works identically.

4. **USB timeouts**: We use 10,000ms for interpreter operations, 5,000ms for direct RS commands. Linux libusb may handle timeouts slightly differently.

5. **Scanner Monitor**: On macOS, Epson Scanner Monitor may claim the USB device. On Linux, equivalent is `epsond` or `saned`. Kill before connecting.
