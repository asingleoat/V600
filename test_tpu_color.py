#!/usr/bin/env python3
"""Test TPU color correction to fix green cast."""

from scanner import EpsonV600, FS, ESC
import struct
import numpy as np
import tifffile

scanner = EpsonV600()
scanner.open()

DPI = 400
WIDTH = 400
HEIGHT = 400

def do_tpu_scan(source, film_type, color_corr, label, filename):
    scanner.reset()

    buf = bytearray(64)
    struct.pack_into('<I', buf, 0, DPI)
    struct.pack_into('<I', buf, 4, DPI)
    struct.pack_into('<I', buf, 16, WIDTH)
    struct.pack_into('<I', buf, 20, HEIGHT)
    buf[24] = 0x13    # color byte sequence
    buf[25] = 8       # 8-bit depth
    buf[26] = source  # source
    buf[29] = 0x03    # gamma
    buf[31] = color_corr  # color correction
    buf[37] = film_type   # film type

    if not scanner._cmd_ack(bytes([FS, 0x57])):
        print(f"  {label}: FS W fail"); return
    if not scanner._cmd_ack(bytes(buf)):
        print(f"  {label}: params NAK"); return

    scanner._cmd(bytes([FS, 0x47]))
    resp = scanner._read(14)
    if resp is None or resp[0] != 0x02:
        print(f"  {label}: FS G fail"); return

    block_size = struct.unpack_from('<I', resp, 2)[0]
    block_count = struct.unpack_from('<I', resp, 6)[0]
    last_block = struct.unpack_from('<I', resp, 10)[0]
    total_blocks = block_count + (1 if last_block else 0)

    all_data = bytearray()
    for i in range(total_blocks):
        sz = last_block if (i == total_blocks - 1 and last_block) else block_size
        chunk = scanner._read(sz + 1)
        if chunk is None:
            break
        all_data.extend(chunk[:-1])
        if i < total_blocks - 1:
            scanner._cmd(bytes([0x06]))

    arr = np.frombuffer(bytes(all_data[:WIDTH*HEIGHT*3]), dtype=np.uint8).reshape(HEIGHT, WIDTH, 3)

    # Analyze RGB channels
    r_mean = arr[:,:,0].mean()
    g_mean = arr[:,:,1].mean()
    b_mean = arr[:,:,2].mean()
    print(f"  {label}: R={r_mean:.1f} G={g_mean:.1f} B={b_mean:.1f}")

    tifffile.imwrite(filename, arr)
    print(f"  Saved: {filename}")

# Test various combinations
print("=== TPU color tests at 400 DPI ===\n")

# Source 1 (TPU), no correction
do_tpu_scan(1, 0, 0, "src=1 film=0 cc=0", "tpu_s1_f0_cc0.tiff")

# Source 1, auto color correction
do_tpu_scan(1, 0, 1, "src=1 film=0 cc=1", "tpu_s1_f0_cc1.tiff")

# Source 1, film type 1 (negative)
do_tpu_scan(1, 1, 0, "src=1 film=1 cc=0", "tpu_s1_f1_cc0.tiff")

# Source 1, film type 1, auto correction
do_tpu_scan(1, 1, 1, "src=1 film=1 cc=1", "tpu_s1_f1_cc1.tiff")

# Source 4 (different TPU mode), no correction
do_tpu_scan(4, 0, 0, "src=4 film=0 cc=0", "tpu_s4_f0_cc0.tiff")

# Source 4, auto color correction
do_tpu_scan(4, 0, 1, "src=4 film=0 cc=1", "tpu_s4_f0_cc1.tiff")

# Source 4, film type 1, auto correction
do_tpu_scan(4, 1, 1, "src=4 film=1 cc=1", "tpu_s4_f1_cc1.tiff")

scanner.close()
