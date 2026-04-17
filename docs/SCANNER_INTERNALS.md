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

## Per-Channel Gain Control via Gamma LUTs

The scanner applies an 8-bit lookup table (gamma LUT) to each color channel
before producing the 16-bit output. By uploading custom LUTs, we get
independent per-channel gain/exposure control. This is used for film scanning
to optimize dynamic range for the film content rather than the clear background.

### How Gamma LUTs Work

Each LUT is 256 bytes. Input is the 8-bit sensor value (0-255), output is
the 8-bit transformed value. The scanner then interpolates to produce 16-bit
output — consecutive LUT entries produce ~256 steps in 16-bit space, but the
sensor has higher resolution than 8 bits, so the scanner interpolates between
LUT entries, producing genuine intermediate 16-bit values (not just multiples
of 256).

**Identity LUT** (default, for preview scans):
```
[0, 1, 2, 3, ..., 255]
```

**Gain LUT** (for film scans — affine stretch):
Given a black point `B` and white point `W` from the film content:
```python
scale = 255.0 / (W - B)
lut = bytes(min(255, max(0, int((i - B) * scale))) for i in range(256))
```
This maps sensor values below B to 0, B-W to 0-255, and above W to 255
(clipping the bright background, which we don't care about for film).

### LUT Upload Protocol (RS 0x84)

Three LUTs are uploaded via RS register-write commands, one per channel.
This happens **before** the rest of the calibration sequence, over direct
USB (bypassing the interpreter).

**All communication uses bulk endpoints: OUT=0x02, IN=0x81.**

```
=== R Channel LUT (address 0x1ffc) ===
OUT: 1e 84                                    # RS REG_WRITE
IN:  06                                        # ACK
OUT: 03 00 fc 1f 02 00 01 00                  # 8-byte header
OUT: <256 bytes R LUT data>                   # the lookup table
IN:  06                                        # ACK

=== G Channel LUT (address 0x1ffd) ===
OUT: 1e 84                                    # RS REG_WRITE
IN:  06                                        # ACK
OUT: 03 00 fd 1f 02 00 01 00                  # 8-byte header
OUT: <256 bytes G LUT data>                   # the lookup table
IN:  06                                        # ACK

=== B Channel LUT (address 0x1ffe) ===
OUT: 1e 84                                    # RS REG_WRITE
IN:  06                                        # ACK
OUT: 03 00 fe 1f 02 00 01 00                  # 8-byte header
OUT: <256 bytes B LUT data>                   # the lookup table
IN:  06                                        # ACK
```

The header format is:
```
Byte 0: 0x03     (register write type: gamma LUT)
Byte 1: 0x00     (reserved)
Byte 2: address  (0xfc=R, 0xfd=G, 0xfe=B)
Byte 3: 0x1f     (address high byte — combined address is 0x1ffc/fd/fe)
Byte 4: 0x02     (data type)
Byte 5: 0x00     (reserved)
Byte 6: 0x01     (block count)
Byte 7: 0x00     (reserved)
```

Note: the header and LUT data are sent as **two separate USB writes**
after the ACK to the RS 0x84 command, but before the final ACK. The
scanner ACKs once after receiving both the header and the data.

### Verified by USB Capture

The file `lut_capturexhc1.pcapng` contains a capture of a complete scan
with sentinel LUT values:
- R LUT: all `DE AD` repeating (256 bytes)
- G LUT: all `BE EF` repeating (256 bytes)
- B LUT: all `CA FE` repeating (256 bytes)

These sentinel patterns are clearly visible in the capture at packets
188-216 and confirm that the protocol works exactly as documented above.

### Computing Optimal Film LUTs

For film scanning, LUTs are computed from the 8-bit preview scan:

1. **Select** the film area in the preview
2. **Threshold** using Otsu's method to separate dark film pixels from
   bright background (clear TPU areas, sprocket holes, film borders)
3. **Per channel**, find the 0.5th percentile (black point) and 99.5th
   percentile (white point) of the film-only pixels
4. **Build affine LUT**: `output = clamp((input - black) / (white - black) * 255, 0, 255)`

This stretches the film's actual value range to fill the full 0-255 LUT
output, maximizing the scanner's effective dynamic range for the film
content. Background pixels that were bright (above the white point) clip
to 255, which is expected and harmless.

### When to Use Custom vs Identity LUTs

- **Preview scans**: Always identity LUTs — you need to see the full
  unmodified image to select the film area
- **Full-resolution RGB scans**: Custom LUTs computed from the preview
  selection — optimizes exposure for the film content
- **IR scans**: Always identity LUTs — IR is monochrome and doesn't
  need per-channel gain compensation

### Complete Annotated Protocol Trace

This is the full USB traffic for a TPU scan with custom LUTs, captured
from a V600 on macOS. All commands use the RS prefix (0x1E) sent directly
to USB bulk endpoints (not through the interpreter's INTWrite).

Phase 1: Gamma LUT upload
```
OUT: 1e 84           # RS REG_WRITE
IN:  06              # ACK
OUT: 03 00 fc 1f 02 00 01 00    # R LUT header
OUT: <256 bytes>     # R LUT data
IN:  06              # ACK

OUT: 1e 84           # RS REG_WRITE
IN:  06              # ACK
OUT: 03 00 fd 1f 02 00 01 00    # G LUT header
OUT: <256 bytes>     # G LUT data
IN:  06              # ACK

OUT: 1e 84           # RS REG_WRITE
IN:  06              # ACK
OUT: 03 00 fe 1f 02 00 01 00    # B LUT header
OUT: <256 bytes>     # B LUT data
IN:  06              # ACK
```

Phase 2: TPU calibration setup
```
OUT: 1e a2           # TPU_MODE
IN:  06              # ACK
OUT: 02              # TPU active
IN:  06              # ACK

OUT: 1e 25           # CAL_FLAG
IN:  06              # ACK
OUT: 02              # enable calibration
IN:  06              # ACK

OUT: 1e 5a           # TIMING
IN:  06              # ACK
OUT: 00 00 00 00     # timing config
IN:  06              # ACK

OUT: 1e 11           # PASS_MODE
IN:  06              # ACK
OUT: 03              # scan pass mode
IN:  06              # ACK

OUT: 1e 31           # GAINS (per-channel analog gain — has no actual effect,
IN:  06              #        but must be sent for the calibration sequence)
OUT: 80 00 80 00 80 00 00 00 1e 1e 1e 00
IN:  06              # ACK

OUT: 1e 21           # CCD_CFG
IN:  06              # ACK
OUT: 80 16 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
IN:  06              # ACK

OUT: 1e 84           # REG_WRITE (gain table)
IN:  06              # ACK
OUT: 07 00 00 00 00 00 01 00     # header: type=0x07
OUT: 00 00 00 00                 # 256 bytes: first 16 are CCD config,
     28 00 c0 39                 #   R CCD exposure
     c8 00 c0 39                 #   G CCD exposure
     90 01 00 10                 #   B CCD exposure
     ff ff ff ff ...             #   rest is 0xFF padding
IN:  06              # ACK

OUT: 1e 22           # CCD_CFG2
IN:  06              # ACK
OUT: 00 00 00 00 00 00 80 16 00 00 00 00
IN:  06              # ACK

OUT: 1e 41           # AFE_CFG
IN:  06              # ACK
OUT: 8f 0c 0f 0e 96 00 00 00 01 01 08 00 00 00 00 00 80 80 96 00 00 00
IN:  06              # ACK

OUT: 1e 42           # AFE_CFG2
IN:  06              # ACK
OUT: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
IN:  06              # ACK

OUT: 1e 43           # AFE_GAINS
IN:  06              # ACK
OUT: 00 80 00 80 00 80 09 78 ec 79 f2 7a 00 00 00 00 00 00
IN:  06              # ACK

OUT: 1e 01           # SCAN_CFG
IN:  06              # ACK
OUT: 30 05 00 00 80 00 ff 00 ff 00 02 00
IN:  06              # ACK

OUT: 1e 05           # TRIGGER_CAL
IN:  06              # ACK
```

Phase 3: Scan parameters and start
```
OUT: 1e 53           # GET_PARAMS (read current state)
IN:  <42 bytes>      # current scanning parameters

OUT: 1e 57           # SET_PARAMS (FS W equivalent)
IN:  06              # ACK
OUT: <42 bytes>      # DPI, area, color mode, depth, source, etc.
IN:  06              # ACK

OUT: 1e 47           # START_SCAN (FS G equivalent)
IN:  <scan data>     # blocks of pixel data + status bytes
```

Note: After the scan completes, the interpreter must be reinitialized
(INTClose + INTInit) because the direct USB RS commands have desynchronized
the interpreter's internal USB state machine.

## Notes for Linux-Specific Issues

1. **Interpreter binary format**: The macOS interpreter is Mach-O. Linux needs an ELF .so version. Check Epson's Linux scanner packages (iscan, imagescan).

2. **USB permissions**: Add udev rules or run as root. The interpreter's USB callbacks need unrestricted bulk endpoint access.

3. **Callback ABI**: Same x86-64 System V calling convention on both macOS and Linux. ctypes.CFUNCTYPE works identically.

4. **USB timeouts**: We use 10,000ms for interpreter operations, 5,000ms for direct RS commands. Linux libusb may handle timeouts slightly differently.

5. **Scanner Monitor**: On macOS, Epson Scanner Monitor may claim the USB device. On Linux, equivalent is `epsond` or `saned`. Kill before connecting.

## epkowa 8-bit Depth Bug

The epkowa SANE backend has a bug where it forces 8-bit depth at
3200+ DPI, even though the hardware, protocol, and backend's own
`--help` output all claim 16-bit support.

Root cause: in `dip-obj.c`, there is a hardcoded check:

    require (8 == buf->ctx.depth);

This is called in the image processing pipeline when resolution
>= 3200. It aborts the scan if depth is 16.

The fix (in the patched epkowa overlay) changes this to:

    require (8 == depth || 16 == depth);

The FS W command byte at offset 27 (depth field) is correctly set
to 16 by the backend — the bug is only in the post-scan processing
path that validates the depth after data has already been received.

## SANE epson2 IR Patch

The epson2 SANE backend has better open-source 16-bit support but
lacks working IR mode for the V600. Six bugs were identified and
patched:

1. **IR depth was 1-bit (lineart) instead of 8-bit (mono)** —
   scanner NAKs depth=1, so IR scans failed immediately

2. **IR enable (ESC #) was called before scan params (FS W)** —
   challenge-response could use stale parameter data

3. **IR enable return value was ignored** — failures were silent

4. **No minimum DPI check for IR** — scanner NAKs <800 DPI with
   a confusing error

5. **TPU color profiles were dead code** — `if (0)` prevented the
   profile path from ever executing; changed to
   `if (s->hw->use_extension)`

6. **GT-X820 missing from IR model list** — IR mode option wasn't
   exposed to users of this scanner model

### Building patched sane-backends from source

    git clone https://gitlab.com/sane-project/backends.git sane-backends
    cd sane-backends
    git apply ../sane-epson2-ir-fixes.patch
    ./configure --prefix=$PWD/../sane-local CPPFLAGS="-DSANE_FRAME_IR"
    make -j$(nproc)
    make install

Test with:

    export LD_LIBRARY_PATH=$PWD/../sane-local/lib
    export SANE_CONFIG_DIR=$PWD/../sane-local/etc/sane.d
    ../sane-local/bin/scanimage -L

Set `SANE_DEBUG_EPSON2=10` for verbose protocol logging.
