#!/usr/bin/env python3
"""
Test the SANE epson2 scan flow for IR mode using our interpreter transport.

This validates the fixes to the SANE backend by reproducing the exact
command sequence that sane_start() would issue after our patches:

1. Set scanning parameters (FS W) with correct depth and source
2. Enable infrared (ESC # challenge-response) AFTER params are set
3. Start scan (FS G)
4. Read data

This is the corrected order — the old SANE code did step 2 before step 1,
causing the challenge-response to use stale parameters.
"""

from scanner import EpsonV600, FS, ESC, VALID_IR_RESOLUTIONS
import struct
import numpy as np

scanner = EpsonV600()
scanner.open()

DPI = 800  # minimum IR resolution
WIDTH = 100
HEIGHT = 50

print(f"=== Testing SANE IR flow (corrected order) ===")
print(f"  DPI={DPI}, {WIDTH}x{HEIGHT}, mono 8-bit, source=3 (IR)")
print()

# Step 1: Reset
print("1. Reset (ESC @)")
scanner.reset()

# Step 2: Set scanning parameters FIRST (the fix!)
print("2. Set scanning parameters (FS W)")
buf = bytearray(64)
struct.pack_into('<I', buf, 0, DPI)
struct.pack_into('<I', buf, 4, DPI)
struct.pack_into('<I', buf, 16, WIDTH)
struct.pack_into('<I', buf, 20, HEIGHT)
buf[24] = 0x00   # mono (IR is single-channel)
buf[25] = 8      # depth = 8 (was incorrectly 1 in old SANE)
buf[26] = 3      # source = 3 (TPU + IR)
buf[29] = 0x03   # gamma

ok1 = scanner._cmd_ack(bytes([FS, 0x57]))
ok2 = scanner._cmd_ack(bytes(buf))
print(f"   FS W: {ok1}, params: {ok2}")
if not (ok1 and ok2):
    print("   FAILED - parameters rejected")
    scanner.close()
    exit(1)

# Step 3: Enable infrared AFTER params (the fix!)
print("3. Enable infrared (ESC #) - after params are set")
ir_ok = scanner.enable_infrared()
if not ir_ok:
    print("   FAILED - IR enable rejected")
    scanner.close()
    exit(1)

# Step 4: Start scan
print("4. Start scan (FS G)")
scanner._cmd(bytes([FS, 0x47]))
resp = scanner._read(14)
if resp is None or resp[0] != 0x02:
    print(f"   FAILED - FS G error")
    scanner.close()
    exit(1)

block_size = struct.unpack_from('<I', resp, 2)[0]
block_count = struct.unpack_from('<I', resp, 6)[0]
last_block = struct.unpack_from('<I', resp, 10)[0]
total_blocks = block_count + (1 if last_block else 0)
print(f"   block_size={block_size}, blocks={total_blocks}")
print(f"   bytes/pixel={block_size/WIDTH:.1f} (expect 1.0 for mono 8-bit)")

# Step 5: Read data
all_data = bytearray()
for i in range(total_blocks):
    sz = last_block if (i == total_blocks - 1 and last_block) else block_size
    chunk = scanner._read(sz + 1)
    if chunk is None:
        print(f"   Block {i+1} failed")
        break
    all_data.extend(chunk[:-1])
    if i < total_blocks - 1:
        scanner._cmd(bytes([0x06]))

expected = WIDTH * HEIGHT * 1  # mono 8-bit
print(f"   Received {len(all_data)} bytes (expected {expected})")

arr = np.frombuffer(bytes(all_data[:expected]), dtype=np.uint8).reshape(HEIGHT, WIDTH)
print(f"   Stats: min={arr.min()}, max={arr.max()}, mean={arr.mean():.1f}")

# Verify it looks like IR data (clear background should be near 255)
if arr.max() >= 240:
    print("\n   SUCCESS - IR data looks valid (bright background)")
else:
    print(f"\n   WARNING - max value only {arr.max()}, expected near 255 for clear background")

print()

# Also test the OLD (broken) order to confirm it fails
print("=== Testing OLD SANE flow (broken order) ===")
print("  IR enable BEFORE params - should fail challenge-response")
print()

scanner.reset()

# Old order: enable IR first (WRONG)
print("1. Enable infrared FIRST (old broken order)")
ir_ok_old = scanner.enable_infrared()
print(f"   IR enable result: {ir_ok_old}")

print("2. Set scanning parameters AFTER IR enable")
buf2 = bytearray(64)
struct.pack_into('<I', buf2, 0, DPI)
struct.pack_into('<I', buf2, 4, DPI)
struct.pack_into('<I', buf2, 16, WIDTH)
struct.pack_into('<I', buf2, 20, HEIGHT)
buf2[24] = 0x00
buf2[25] = 8
buf2[26] = 3
buf2[29] = 0x03

ok1 = scanner._cmd_ack(bytes([FS, 0x57]))
ok2 = scanner._cmd_ack(bytes(buf2))
print(f"   FS W: {ok1}, params: {ok2}")

if ok1 and ok2:
    print("3. Start scan")
    scanner._cmd(bytes([FS, 0x47]))
    resp2 = scanner._read(14)
    if resp2 and resp2[0] == 0x02:
        bs2 = struct.unpack_from('<I', resp2, 2)[0]
        print(f"   Scan started (block_size={bs2}, bytes/pixel={bs2/WIDTH:.1f})")
        print("   NOTE: Old order also worked - IR enable doesn't depend on param order")
        # Cancel scan
        scanner._cmd(bytes([0x18]))  # CAN
    else:
        print("   FS G failed - old order breaks the scan")
else:
    print("   Params rejected after early IR enable")

scanner.close()
