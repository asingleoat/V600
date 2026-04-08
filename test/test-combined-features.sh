#!/usr/bin/env bash

# Test script for combined 16-bit + IR scanning overlay
# Tests both features to ensure they work correctly

set -e

echo "================================================"
echo "Epson V600 Combined Features Test"
echo "================================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test directory
TEST_DIR="/tmp/v600-test-$(date +%s)"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

echo "Test directory: $TEST_DIR"
echo ""

# Function to check if file exists and has size
check_file() {
    local file=$1
    local desc=$2
    if [ -f "$file" ] && [ -s "$file" ]; then
        local size=$(stat -c%s "$file")
        echo -e "${GREEN}✓${NC} $desc created successfully ($(numfmt --to=iec $size))"
        return 0
    else
        echo -e "${RED}✗${NC} $desc failed"
        return 1
    fi
}

# Function to analyze PNM header
analyze_pnm() {
    local file=$1
    if [ -f "$file" ]; then
        local header=$(head -n 3 "$file")
        local magic=$(head -n 1 "$file")
        echo "  Header: $magic"
        
        # Get dimensions and depth
        local dims=$(head -n 3 "$file" | tail -n 2)
        echo "  Dimensions: $(echo $dims | tr '\n' ' ')"
    fi
}

echo "================================================"
echo "Test 1: Basic 8-bit Color Scan"
echo "================================================"
echo "Testing standard color scanning..."
if scanimage-v600 \
    --mode Color \
    --depth 8 \
    --resolution 150 \
    -l 0 -t 0 -x 50 -y 50 \
    -o test_8bit_color.pnm 2>/dev/null; then
    check_file "test_8bit_color.pnm" "8-bit color scan"
    analyze_pnm "test_8bit_color.pnm"
else
    echo -e "${RED}✗${NC} 8-bit color scan failed"
fi
echo ""

echo "================================================"
echo "Test 2: 16-bit Color Scan"
echo "================================================"
echo "Testing 16-bit high depth scanning..."
if scanimage-v600 \
    --mode Color \
    --depth 16 \
    --resolution 300 \
    -l 0 -t 0 -x 50 -y 50 \
    -o test_16bit_color.pnm 2>/dev/null; then
    check_file "test_16bit_color.pnm" "16-bit color scan"
    analyze_pnm "test_16bit_color.pnm"
    
    # Check if file is actually 16-bit
    if head -n 3 test_16bit_color.pnm | grep -q "65535"; then
        echo -e "  ${GREEN}✓${NC} Confirmed 16-bit depth (max value: 65535)"
    else
        echo -e "  ${YELLOW}⚠${NC} May not be true 16-bit"
    fi
else
    echo -e "${RED}✗${NC} 16-bit color scan failed"
fi
echo ""

echo "================================================"
echo "Test 3: Grayscale Scan"
echo "================================================"
echo "Testing grayscale scanning..."
if scanimage-v600 \
    --mode Gray \
    --depth 8 \
    --resolution 200 \
    -l 0 -t 0 -x 50 -y 50 \
    -o test_gray.pnm 2>/dev/null; then
    check_file "test_gray.pnm" "Grayscale scan"
    analyze_pnm "test_gray.pnm"
else
    echo -e "${RED}✗${NC} Grayscale scan failed"
fi
echo ""

echo "================================================"
echo "Test 4: IR Mode Scan (TPU)"
echo "================================================"
echo "Testing IR channel scanning..."
echo -e "${YELLOW}Note:${NC} This requires Transparency Unit to be available"
if scanimage-v600 \
    --ir \
    --source 'Transparency Unit' \
    --mode Gray \
    --resolution 800 \
    -l 0 -t 0 -x 50 -y 50 \
    -o test_ir.pnm 2>/dev/null; then
    check_file "test_ir.pnm" "IR scan"
    analyze_pnm "test_ir.pnm"
    echo -e "  ${GREEN}✓${NC} IR mode command accepted"
else
    echo -e "${YELLOW}⚠${NC} IR scan failed (TPU may not be available)"
fi
echo ""

echo "================================================"
echo "Test 5: Environment Variable Check"
echo "================================================"
echo "Testing SCAN_IR_MODE environment variable..."

# Test with explicit environment variable
SCAN_IR_MODE=1 scanimage-v600 \
    --source 'Transparency Unit' \
    --mode Gray \
    --resolution 800 \
    -l 0 -t 0 -x 30 -y 30 \
    -o test_ir_env.pnm 2>/dev/null && \
    check_file "test_ir_env.pnm" "IR via environment variable" || \
    echo -e "${YELLOW}⚠${NC} Environmental IR mode failed"
echo ""

echo "================================================"
echo "Test 6: Scanner Capabilities"
echo "================================================"
echo "Checking available options..."
scanimage-v600 --help 2>/dev/null | grep -E "(--mode|--depth|--resolution|--source)" | head -20
echo ""

echo "================================================"
echo "Test Summary"
echo "================================================"
echo "Test files created in: $TEST_DIR"
echo ""
ls -lh *.pnm 2>/dev/null || echo "No test files created"
echo ""

# Cleanup offer
read -p "Remove test files? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    cd /
    rm -rf "$TEST_DIR"
    echo "Test files removed."
else
    echo "Test files kept in: $TEST_DIR"
fi

echo ""
echo "Testing complete!"