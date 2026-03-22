#!/usr/bin/env python3
"""
Test IR scanning by sending raw ESC/I commands directly over USB,
bypassing the interpreter. The interpreter is still used for firmware upload.
"""

from scanner import EpsonV600, FS, ESC
import struct
import usb.core
import time

scanner = EpsonV600()
scanner.open()

# Now bypass the interpreter and talk directly to the scanner
ep_out = scanner.ep_out
ep_in = scanner.ep_in

def raw_write(data, timeout=5000):
    """Send data directly to scanner USB endpoint."""
    ep_out.write(data, timeout=timeout)

def raw_read(size, timeout=5000):
    """Read from scanner USB endpoint."""
    try:
        data = ep_in.read(size, timeout=timeout)
        return bytes(data)
    except usb.core.USBTimeoutError:
        return None

def raw_cmd_ack(data, name=""):
    """Send command and expect ACK."""
    raw_write(data)
    resp = raw_read(1)
    if resp is None:
        print(f"  {name}: timeout")
        return False
    if resp[0] == 0x06:
        print(f"  {name}: ACK")
        return True
    if resp[0] == 0x15:
        print(f"  {name}: NAK")
        return False
    print(f"  {name}: 0x{resp[0]:02x}")
    return True

# Step 1: Reset via raw USB
print("=== Raw USB reset ===")
raw_cmd_ack(bytes([ESC, 0x40]), "ESC @")

# Step 2: Get identity to verify raw comms work
print("\n=== Raw FS I (extended identity) ===")
raw_write(bytes([FS, 0x49]))
eid = raw_read(80)
if eid:
    model = eid[46:62].decode('ascii', errors='replace').rstrip('\x00 ')
    cap1 = eid[44]
    print(f"  Model: {model}, cap=0x{cap1:02x}")
    print(f"  IR supported: {bool(cap1 & 0x02)}")
else:
    print("  No response!")

# Step 3: Read current params via raw FS S
print("\n=== Raw FS S (read params) ===")
raw_write(bytes([FS, 0x53]))
params = raw_read(64)
if params:
    dpi = struct.unpack_from('<I', params, 0)[0]
    print(f"  Params: dpi={dpi} color=0x{params[24]:02x} depth={params[25]} source={params[26]}")
    hex_str = " ".join(f"{b:02x}" for b in params[:32])
    print(f"  Raw first 32: {hex_str}")
else:
    print("  No response!")

# Step 4: Try setting params with source=3 via raw FS W
print("\n=== Raw FS W with source=3 ===")
raw_cmd_ack(bytes([FS, 0x57]), "FS W")

buf = bytearray(64)
struct.pack_into('<I', buf, 0, 400)
struct.pack_into('<I', buf, 4, 400)
struct.pack_into('<I', buf, 8, 0)
struct.pack_into('<I', buf, 12, 0)
struct.pack_into('<I', buf, 16, 100)
struct.pack_into('<I', buf, 20, 10)
buf[24] = 0x13  # color
buf[25] = 8
buf[26] = 3     # TPU + IR
buf[27] = 0
buf[28] = 0
buf[29] = 0x03
raw_cmd_ack(bytes(buf), "Params (source=3)")

# Step 5: Also try the IR enable via raw USB
print("\n=== Raw ESC # (IR enable) ===")
# First reset and set params with source=1 (TPU)
raw_cmd_ack(bytes([ESC, 0x40]), "ESC @ reset")

# Read params for XOR challenge
raw_write(bytes([FS, 0x53]))
params = raw_read(64)
if params:
    xor_key = bytes([
        0xCA, 0xFB, 0x77, 0x71, 0x20, 0x16, 0xDA, 0x09,
        0x5F, 0x57, 0x09, 0x12, 0x04, 0x83, 0x76, 0x77,
        0x3C, 0x73, 0x9C, 0xBE, 0x7A, 0xE0, 0x52, 0xE2,
        0x90, 0x0D, 0xFF, 0x9A, 0xEF, 0x4C, 0x2C, 0x81,
    ])
    response = bytes(xor_key[i] ^ params[i] for i in range(32))
    hex_str = " ".join(f"{b:02x}" for b in response)
    print(f"  XOR response: {hex_str}")

    raw_cmd_ack(bytes([ESC, 0x23]), "ESC #")
    raw_cmd_ack(response, "IR challenge")

    # Now try source=3 after IR enable
    print("\n=== After IR enable: FS W source=3 ===")
    raw_cmd_ack(bytes([FS, 0x57]), "FS W")
    raw_cmd_ack(bytes(buf), "Params (source=3)")

    # Also try source=1 and see if scan has 4 channels
    print("\n=== After IR enable: FS W source=1, then scan ===")
    buf[26] = 1  # source=1 (TPU)
    raw_cmd_ack(bytes([FS, 0x57]), "FS W")
    raw_cmd_ack(bytes(buf), "Params (source=1)")

    # Start scan
    raw_write(bytes([FS, 0x47]))
    scan_resp = raw_read(14)
    if scan_resp and scan_resp[0] == 0x02:
        block_size = struct.unpack_from('<I', scan_resp, 2)[0]
        block_count = struct.unpack_from('<I', scan_resp, 6)[0]
        last_block = struct.unpack_from('<I', scan_resp, 10)[0]
        print(f"  Scan: block_size={block_size} ({block_size/100:.1f} bytes/pixel), count={block_count}, last={last_block}")
        # Read first block
        chunk = raw_read(block_size + 1)
        if chunk:
            hex_str = " ".join(f"{b:02x}" for b in chunk[:24])
            print(f"  Data: {hex_str}")
        # Cancel
        raw_cmd_ack(bytes([ESC, 0x40]), "Cancel/reset")
    else:
        print(f"  FS G failed: {scan_resp}")

scanner.close()
