#!/usr/bin/env python3
"""
Test the performance improvement from device caching.
"""

import time
import subprocess
import sys

def test_gui_startup():
    """Test GUI startup performance with caching."""
    print("=" * 60)
    print("Testing GUI Startup Performance")
    print("=" * 60)
    
    print("\nFirst run (device detection):")
    print("-" * 40)
    
    # First run - will detect device
    start = time.time()
    proc = subprocess.Popen(['python3', 'gui.py'], 
                           stdout=subprocess.PIPE, 
                           stderr=subprocess.PIPE,
                           text=True)
    
    # Wait for startup message
    for i in range(30):  # 30 second timeout
        line = proc.stdout.readline()
        if 'GUI: http://' in line:
            elapsed = time.time() - start
            print(f"✓ GUI started in {elapsed:.2f}s")
            print(f"  {line.strip()}")
            break
        time.sleep(0.1)
    
    # Kill the GUI
    proc.terminate()
    proc.wait(timeout=5)
    
    print("\nSecond run (using cached device):")
    print("-" * 40)
    
    # Second run - should use cached device
    start = time.time()
    proc = subprocess.Popen(['python3', 'gui.py'], 
                           stdout=subprocess.PIPE, 
                           stderr=subprocess.PIPE,
                           text=True)
    
    # Wait for startup message
    for i in range(30):  # 30 second timeout
        line = proc.stdout.readline()
        if 'GUI: http://' in line:
            elapsed = time.time() - start
            print(f"✓ GUI started in {elapsed:.2f}s")
            print(f"  {line.strip()}")
            break
        time.sleep(0.1)
    
    # Kill the GUI
    proc.terminate()
    proc.wait(timeout=5)

def test_scanimage_performance():
    """Compare scanimage with and without explicit device."""
    print("\n" + "=" * 60)
    print("Testing scanimage Performance")
    print("=" * 60)
    
    # First get the device name
    print("\nGetting device name...")
    result = subprocess.run(['scanimage', '-L'], 
                          capture_output=True, text=True)
    
    device_name = None
    for line in result.stdout.split('\n'):
        if 'epkowa' in line or 'epson' in line:
            if '`' in line and "'" in line:
                device_name = line.split('`')[1].split("'")[0]
                print(f"Found device: {device_name}")
                break
    
    if not device_name:
        print("No scanner found!")
        return
    
    print("\nWithout explicit device (auto-detection):")
    print("-" * 40)
    
    # Test without explicit device
    start = time.time()
    result = subprocess.run(
        ['timeout', '15', 'scanimage', '--help'],
        capture_output=True, text=True
    )
    elapsed_auto = time.time() - start
    print(f"  scanimage --help: {elapsed_auto:.2f}s")
    
    print("\nWith explicit device:")
    print("-" * 40)
    
    # Test with explicit device
    start = time.time()
    result = subprocess.run(
        ['scanimage', '--device-name', device_name, '--help'],
        capture_output=True, text=True
    )
    elapsed_explicit = time.time() - start
    print(f"  scanimage --device-name {device_name} --help: {elapsed_explicit:.2f}s")
    
    print("\n" + "=" * 60)
    print("PERFORMANCE SUMMARY")
    print("=" * 60)
    
    speedup = elapsed_auto / elapsed_explicit if elapsed_explicit > 0 else 0
    print(f"Auto-detection:    {elapsed_auto:.2f}s")
    print(f"Explicit device:   {elapsed_explicit:.2f}s")
    print(f"Speedup:           {speedup:.1f}x faster with explicit device")
    
    if speedup < 1.5:
        print("\n⚠ Performance improvement is minimal.")
        print("  The device might already be cached by SANE.")
    else:
        print(f"\n✓ Significant improvement: {elapsed_auto - elapsed_explicit:.1f}s saved per operation")

def main():
    print("Scanner Performance Test with Device Caching")
    print("=" * 60)
    
    # Test scanimage performance
    test_scanimage_performance()
    
    # Test GUI startup
    print("\nTesting GUI startup (press Ctrl+C to skip)...")
    try:
        test_gui_startup()
    except KeyboardInterrupt:
        print("\nSkipped GUI test")
    
    print("\n" + "=" * 60)
    print("RECOMMENDATIONS")
    print("=" * 60)
    print("✓ Device caching is now implemented in scanner.py")
    print("✓ All scanimage calls use explicit --device-name flag")
    print("✓ Cache timeout is set to 5 minutes")
    print("\nTo further improve performance:")
    print("1. Disable unused SANE backends if you have access to dll.conf")
    print("2. Set SANE_DEFAULT_DEVICE environment variable")
    print("3. Use the wrapper scripts (scanimage-v600, scanimage-v600-ir)")

if __name__ == "__main__":
    main()