#!/bin/bash
# Test script for the unified dispatcher

set -e

echo "=== V600 Unified Dispatcher Test ==="
echo

# Find the base interpreter
BASE_INTERP="${V600_BASE_INTERPRETER:-}"
if [ -z "$BASE_INTERP" ]; then
    echo "Warning: V600_BASE_INTERPRETER not set"
    echo "Set V600_BASE_INTERPRETER to point to libesintA1.so.2.0.1"
    echo "For NixOS users, this should be something like:"
    echo "  export V600_BASE_INTERPRETER=/nix/store/...-v600-base-interpreter/lib/libesintA1.so.2.0.1"
fi

# Set up environment for the dispatcher
export V600_BASE_INTERPRETER="$BASE_INTERP"
export V600_VERBOSE=1
DISPATCHER="$(dirname $0)/libesintA1_unified.so"

if [ ! -f "$DISPATCHER" ]; then
    echo "Building unified dispatcher..."
    gcc -shared -fPIC -o "$DISPATCHER" "$(dirname $0)/unified_dispatcher.c" -ldl
fi

echo "Dispatcher: $DISPATCHER"
echo "Base interpreter: ${V600_BASE_INTERPRETER:-auto-detect}"
echo

# Test 1: Normal mode
echo "=== Test 1: Normal scanning mode ==="
unset SCAN_IR_MODE
unset V600_LUT_FILE
export LD_PRELOAD="$DISPATCHER"

# Would run: scanimage -L
echo "Would run: scanimage -L"
echo "(Set LD_PRELOAD=$DISPATCHER)"
echo

# Test 2: IR mode
echo "=== Test 2: IR scanning mode ==="
export SCAN_IR_MODE=1
echo "Would run: SCAN_IR_MODE=1 scanimage --source 'Transparency Unit' --mode Gray --resolution 800 -o test_ir.pnm"
echo

# Test 3: Custom LUTs
echo "=== Test 3: Custom LUT mode ==="
unset SCAN_IR_MODE

# Create test LUTs
python3 - << 'PYTHON'
import sys
import os

# Create test LUTs with recognizable pattern
lut_r = bytes(min(255, int(i * 1.5)) for i in range(256))  # 1.5x gain
lut_g = bytes(min(255, int(i * 1.2)) for i in range(256))  # 1.2x gain
lut_b = bytes(min(255, int(i * 0.9)) for i in range(256))  # 0.9x gain

with open('/tmp/test_luts_unified.bin', 'wb') as f:
    f.write(lut_r + lut_g + lut_b)

print("Created test LUTs at /tmp/test_luts_unified.bin")
print(f"  R: 1.5x gain")
print(f"  G: 1.2x gain")
print(f"  B: 0.9x gain")
PYTHON

export V600_LUT_FILE=/tmp/test_luts_unified.bin
echo "Would run: V600_LUT_FILE=/tmp/test_luts_unified.bin scanimage --mode Color --depth 16 --resolution 300 -o test.tiff"
echo

# Test 4: Combined IR + LUTs
echo "=== Test 4: IR mode with custom LUTs ==="
export SCAN_IR_MODE=1
export V600_LUT_FILE=/tmp/test_luts_unified.bin
echo "Would run: SCAN_IR_MODE=1 V600_LUT_FILE=/tmp/test_luts_unified.bin scanimage --source 'Transparency Unit' --mode Gray --resolution 800 -o test_ir_lut.pnm"
echo

echo "=== Usage Summary ==="
echo
echo "The unified dispatcher supports all modes via environment variables:"
echo "  Normal:     (no special environment)"
echo "  IR:         SCAN_IR_MODE=1"
echo "  Custom LUT: V600_LUT_FILE=/path/to/luts.bin"
echo "  Verbose:    V600_VERBOSE=1"
echo
echo "Set LD_PRELOAD=$DISPATCHER before running scanimage"
echo "Or use the wrapper: scanimage-v600 (when installed via NixOS overlay)"