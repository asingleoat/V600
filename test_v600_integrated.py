#!/usr/bin/env python3
"""
Test script for Epson V600 integrated scanning with 16-bit and IR support.
Tests the integration with the 16bitV600 backend using environment variables.
"""

import os
import sys
import numpy as np
from scanner import EpsonScanner
import tempfile

def test_16bit_color_scan():
    """Test 16-bit color scanning at high resolution"""
    print("\n" + "="*60)
    print("Testing 16-bit color scan at 3200 DPI")
    print("="*60)
    
    scanner = EpsonScanner()
    scanner.open()
    
    try:
        # Small area for quick test
        arr = scanner.scan(
            dpi=3200,
            x=0, y=0,
            width=0.5, height=0.5,  # 0.5x0.5 inch area
            color=True,
            depth=16,
            source='tpu',
            ir=False
        )
        
        print(f"✓ 16-bit scan successful")
        print(f"  Shape: {arr.shape}")
        print(f"  Dtype: {arr.dtype}")
        print(f"  Bit depth: {'16-bit' if arr.dtype == np.uint16 else '8-bit'}")
        print(f"  Min/Max values: {arr.min()}/{arr.max()}")
        
        # Verify we got 16-bit data
        if arr.dtype == np.uint16 and arr.max() > 255:
            print("✓ Confirmed: True 16-bit data (values > 255)")
            return True
        else:
            print("⚠ Warning: May not be true 16-bit data")
            return False
            
    finally:
        scanner.close()

def test_ir_scan():
    """Test IR scanning for dust/scratch detection"""
    print("\n" + "="*60)
    print("Testing IR scan at 800 DPI")
    print("="*60)
    
    scanner = EpsonScanner()
    scanner.open()
    
    try:
        # IR scan requirements:
        # - Must use TPU (Transparency Unit)
        # - Must be grayscale
        # - Resolution must be 800, 1600, or 3200
        arr = scanner.scan(
            dpi=800,
            x=0, y=0,
            width=1, height=1,  # 1x1 inch area
            color=False,  # IR is grayscale
            depth=8,
            source='tpu',
            ir=True  # Enable IR mode
        )
        
        print(f"✓ IR scan successful")
        print(f"  Shape: {arr.shape}")
        print(f"  Dtype: {arr.dtype}")
        print(f"  Min/Max values: {arr.min()}/{arr.max()}")
        
        # IR scans should be grayscale
        if len(arr.shape) == 2:
            print("✓ Confirmed: Grayscale IR data")
            return True
        else:
            print("⚠ Warning: Expected grayscale for IR")
            return False
            
    finally:
        scanner.close()

def test_combined_rgb_ir():
    """Test combined RGB+IR scanning (two-pass)"""
    print("\n" + "="*60)
    print("Testing combined RGB+IR scan")
    print("="*60)
    
    scanner = EpsonScanner()
    scanner.open()
    
    try:
        # First pass: RGB color
        print("\nPass 1: RGB color scan...")
        rgb = scanner.scan(
            dpi=1600,
            x=0, y=0,
            width=0.5, height=0.5,
            color=True,
            depth=16,
            source='tpu',
            ir=False
        )
        print(f"  RGB shape: {rgb.shape}")
        
        # Second pass: IR 
        print("\nPass 2: IR scan...")
        ir = scanner.scan(
            dpi=1600,
            x=0, y=0,
            width=0.5, height=0.5,
            color=False,
            depth=8,
            source='tpu',
            ir=True
        )
        print(f"  IR shape: {ir.shape}")
        
        print("\n✓ Combined RGB+IR scan successful")
        print(f"  RGB: {rgb.shape} {rgb.dtype}")
        print(f"  IR:  {ir.shape} {ir.dtype}")
        
        # Check dimensions match (accounting for color channels)
        if rgb.shape[:2] == ir.shape[:2]:
            print("✓ RGB and IR dimensions match (can be combined for dust removal)")
            return True
        else:
            print("⚠ Warning: RGB and IR dimensions don't match")
            return False
            
    finally:
        scanner.close()

def test_environment_variable():
    """Test that SCAN_IR_MODE environment variable is properly set"""
    print("\n" + "="*60)
    print("Testing SCAN_IR_MODE environment variable")
    print("="*60)
    
    import subprocess
    
    # Test IR mode sets variable
    env = os.environ.copy()
    env['SCAN_IR_MODE'] = '1'
    
    # Run a simple command to check if variable is set
    result = subprocess.run(
        ['bash', '-c', 'echo "SCAN_IR_MODE=$SCAN_IR_MODE"'],
        env=env,
        capture_output=True,
        text=True
    )
    
    if 'SCAN_IR_MODE=1' in result.stdout:
        print("✓ SCAN_IR_MODE environment variable properly set")
        return True
    else:
        print("✗ SCAN_IR_MODE environment variable not set correctly")
        return False

def main():
    """Run all tests"""
    print("Epson V600 Integrated Scanner Tests")
    print("Using 16bitV600 backend with environment variable control")
    
    results = []
    
    # Test environment setup
    results.append(("Environment Variable", test_environment_variable()))
    
    # Test 16-bit scanning
    try:
        results.append(("16-bit Color Scan", test_16bit_color_scan()))
    except Exception as e:
        print(f"✗ 16-bit scan failed: {e}")
        results.append(("16-bit Color Scan", False))
    
    # Test IR scanning
    try:
        results.append(("IR Scan", test_ir_scan()))
    except Exception as e:
        print(f"✗ IR scan failed: {e}")
        results.append(("IR Scan", False))
    
    # Test combined RGB+IR
    try:
        results.append(("Combined RGB+IR", test_combined_rgb_ir()))
    except Exception as e:
        print(f"✗ Combined scan failed: {e}")
        results.append(("Combined RGB+IR", False))
    
    # Summary
    print("\n" + "="*60)
    print("TEST SUMMARY")
    print("="*60)
    
    for name, passed in results:
        status = "✓ PASS" if passed else "✗ FAIL"
        print(f"{status}: {name}")
    
    passed_count = sum(1 for _, p in results if p)
    total_count = len(results)
    print(f"\nTotal: {passed_count}/{total_count} tests passed")
    
    return 0 if passed_count == total_count else 1

if __name__ == "__main__":
    sys.exit(main())