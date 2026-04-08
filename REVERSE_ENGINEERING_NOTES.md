# Reverse Engineering Notes - Epson V600 16-bit @ 3200 DPI

## Problem Summary
The epkowa backend on Linux has a bug where it fails to scan at 16-bit depth with 3200+ DPI resolution, even though:
1. The hardware supports it (works on macOS)
2. The backend claims to support it (`--depth 8|16`)
3. The ESC/I protocol supports it

## Root Cause
Through reverse engineering, we found that the epkowa backend doesn't properly set the bit depth byte in the FS W (0x1C 0x57) command when resolution >= 3200 DPI.

### FS W Command Structure
```
Offset  Size  Description
0-1     2     Command (0x1C 0x57)
2-5     4     X resolution (little-endian)
6-9     4     Y resolution (little-endian)
10-13   4     X1 coordinate
14-17   4     Y1 coordinate
18-21   4     X2 coordinate
22-25   4     Y2 coordinate
26      1     Color mode (0x02 = Color)
27      1     Bit depth (8 or 16) <- BUG: epkowa forces this to 8 at 3200 DPI
28      1     Source (1 = TPU)
```

## Attempted Solutions

### 1. Direct Interpreter Use (Failed)
- The Linux epkowa interpreter (libesintA1.so) has unresolved symbols
- It's tightly integrated with the epkowa backend
- Can't be used standalone like the macOS version

### 2. epson2 Backend (Failed)  
- Doesn't work with V600 without the interpreter
- Would need to port interpreter support

### 3. Binary Patching (Complex)
- Would need to find and patch the exact location where bit depth is forced to 8
- Risky without source code

### 4. LD_PRELOAD Wrapper (Promising)
- Intercept libusb calls
- Fix the bit depth byte in FS W commands
- Requires compiling a shared library

## USB Protocol Details

### Initialization Sequence
1. Reset: `1B 40` (ESC @)
2. Get Identity: `1C 49` (FS I)
3. Get Status: `1C 53` (FS S)
4. Enable TPU: `1B 19 01` (ESC EM 1)

### 16-bit 3200 DPI Scan Command
```
1C 57                    # FS W command
80 0C 00 00              # 3200 DPI X (0x0C80)
80 0C 00 00              # 3200 DPI Y
[coordinates...]         # Scan area
02                       # Color mode
10                       # 16-bit depth (epkowa sets 08 here!)
01                       # TPU source
```

## Working Workarounds

### For Users
1. **Use 1600 DPI with 16-bit** - Works perfectly
2. **Use 3200 DPI with 8-bit** - Automatic fallback
3. **Scan at 1600 DPI and upscale** - Good quality compromise

### For Developers
1. **Port to macOS for critical work** - Full functionality there
2. **Use raw files at 8-bit, process to 16-bit** - Post-processing solution
3. **Wait for epkowa fix or epson2 improvement** - Long-term solution

## Future Work
1. **Full USB packet protocol reverse engineering** - Implement complete interpreter replacement
2. **Port interpreter support to epson2** - Add V600 support to open-source backend
3. **Binary patch epkowa** - Fix the bit depth bug directly

## Technical Details for Implementation

The interpreter handles:
- USB packet framing and flow control
- Firmware upload on initialization  
- Error correction and retransmission
- Command sequencing and timing
- Data decompression/compression

To fully replace it, we would need to:
1. Capture all USB packets during initialization
2. Understand the packet framing protocol
3. Implement firmware upload sequence
4. Handle all error conditions
5. Implement data transfer protocol

This is a significant engineering effort but would provide full 16-bit support on Linux.