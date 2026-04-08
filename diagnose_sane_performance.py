#!/usr/bin/env python3
"""
Diagnose SANE performance issues with the Epson V600 scanner.
Measures timing for each step of the scanning process.
"""

import time
import subprocess
import os
import sys

def time_command(description, command, env=None):
    """Execute a command and measure its runtime."""
    print(f"\n{description}...")
    start = time.time()
    try:
        result = subprocess.run(
            command, 
            capture_output=True, 
            text=True,
            env=env or os.environ,
            timeout=30
        )
        elapsed = time.time() - start
        print(f"  ✓ Completed in {elapsed:.2f}s")
        if result.returncode != 0:
            print(f"  ⚠ Exit code: {result.returncode}")
            if result.stderr:
                print(f"  stderr: {result.stderr[:200]}")
        return elapsed, result
    except subprocess.TimeoutExpired:
        elapsed = time.time() - start
        print(f"  ✗ Timed out after {elapsed:.2f}s")
        return elapsed, None
    except Exception as e:
        elapsed = time.time() - start
        print(f"  ✗ Failed after {elapsed:.2f}s: {e}")
        return elapsed, None

def main():
    print("=" * 60)
    print("SANE Performance Diagnostic for Epson V600")
    print("=" * 60)
    
    total_start = time.time()
    timings = {}
    
    # 1. Basic scanimage -L (lists all devices)
    print("\n1. Device Detection")
    print("-" * 40)
    
    t, result = time_command(
        "scanimage -L (list all SANE devices)",
        ["scanimage", "-L"]
    )
    timings["scanimage -L"] = t
    
    # Extract device name if found
    device_name = None
    if result and result.stdout:
        for line in result.stdout.split('\n'):
            if 'epkowa' in line or 'epson' in line:
                # Extract device name from: device `name' is a ...
                if '`' in line and "'" in line:
                    device_name = line.split('`')[1].split("'")[0]
                    print(f"  Found device: {device_name}")
                    break
    
    if not device_name:
        print("  ⚠ No Epson scanner found!")
        device_name = "epkowa:interpreter:001:007"  # Fallback
        print(f"  Using fallback: {device_name}")
    
    # 2. Device-specific help (gets capabilities)
    print("\n2. Device Capabilities Query")
    print("-" * 40)
    
    t, _ = time_command(
        f"scanimage --device {device_name} --help",
        ["scanimage", f"--device={device_name}", "--help"]
    )
    timings["device --help"] = t
    
    # 3. Quick parameter query
    print("\n3. Parameter Query Tests")
    print("-" * 40)
    
    # Test getting specific parameters
    for param in ["--resolution", "--mode", "--source"]:
        t, result = time_command(
            f"Query {param} options",
            ["scanimage", f"--device={device_name}", "--help"],
            env={**os.environ, "SANE_DEBUG_DLL": "0"}  # Disable debug output
        )
        # We're just timing the help command multiple times to see consistency
    
    # 4. Scan initialization timing
    print("\n4. Scan Initialization (dry run)")
    print("-" * 40)
    
    # Try a minimal scan that we'll cancel immediately
    t, _ = time_command(
        "Initialize scan (1x1mm test area)",
        ["timeout", "2", "scanimage", 
         f"--device={device_name}",
         "--mode", "Color",
         "--resolution", "400",
         "-x", "1", "-y", "1",
         "-o", "/dev/null"]
    )
    timings["scan init"] = t
    
    # 5. Test with different backends if available
    print("\n5. Backend Comparison")
    print("-" * 40)
    
    # Test dll loading
    t, result = time_command(
        "List loaded SANE backends",
        ["scanimage", "-L"],
        env={**os.environ, "SANE_DEBUG_DLL": "128"}
    )
    
    if result and result.stderr:
        # Count how many backends are being loaded
        backend_loads = result.stderr.count("dlopen")
        dll_loads = result.stderr.count("sane_init")
        print(f"  Loaded {backend_loads} backend libraries")
        print(f"  Initialized {dll_loads} backends")
    
    # 6. Test wrapper scripts if available
    print("\n6. Wrapper Script Performance")
    print("-" * 40)
    
    import shutil
    if shutil.which('scanimage-v600'):
        t, _ = time_command(
            "scanimage-v600 --help",
            ["scanimage-v600", "--help"]
        )
        timings["wrapper --help"] = t
    else:
        print("  Wrapper scripts not found")
    
    # 7. Python import timing
    print("\n7. Python Scanner Module Import")
    print("-" * 40)
    
    start = time.time()
    try:
        from scanner import EpsonScanner
        elapsed = time.time() - start
        print(f"  ✓ Import completed in {elapsed:.2f}s")
        timings["python import"] = elapsed
        
        # Test scanner initialization
        print("\n8. Python Scanner Initialization")
        print("-" * 40)
        
        start = time.time()
        scanner = EpsonScanner()
        elapsed = time.time() - start
        print(f"  ✓ EpsonScanner() in {elapsed:.2f}s")
        timings["python init"] = elapsed
        
        start = time.time()
        scanner.open()
        elapsed = time.time() - start
        print(f"  ✓ scanner.open() in {elapsed:.2f}s")
        timings["python open"] = elapsed
        
        scanner.close()
        
    except Exception as e:
        elapsed = time.time() - start
        print(f"  ✗ Failed after {elapsed:.2f}s: {e}")
    
    # Summary
    print("\n" + "=" * 60)
    print("TIMING SUMMARY")
    print("=" * 60)
    
    for operation, duration in timings.items():
        print(f"{operation:.<30} {duration:>6.2f}s")
    
    total_time = time.time() - total_start
    print("-" * 40)
    print(f"{'Total diagnostic time':.<30} {total_time:>6.2f}s")
    
    # Recommendations
    print("\n" + "=" * 60)
    print("ANALYSIS & RECOMMENDATIONS")
    print("=" * 60)
    
    if timings.get("scanimage -L", 0) > 5:
        print("⚠ Device detection is slow (>5s)")
        print("  Recommendations:")
        print("  - Disable unused SANE backends in /etc/sane.d/dll.conf")
        print("  - Keep only 'epkowa' or 'epson2' enabled")
        print("  - Use explicit device name to skip detection")
    
    if timings.get("device --help", 0) > 3:
        print("⚠ Capability query is slow (>3s)")
        print("  Recommendations:")
        print("  - Cache device capabilities after first query")
        print("  - Consider using hardcoded scanner parameters")
    
    if timings.get("scan init", 0) > 2:
        print("⚠ Scan initialization is slow (>2s)")
        print("  Recommendations:")
        print("  - Check USB connection (USB 2.0 vs 3.0)")
        print("  - Verify scanner firmware is responsive")
    
    print("\nTo optimize SANE:")
    print("1. Edit /etc/sane.d/dll.conf to disable unused backends")
    print("2. Set SANE_DEFAULT_DEVICE environment variable")
    print("3. Use explicit device names instead of auto-detection")
    print("4. Consider using wrapper scripts that cache device info")

if __name__ == "__main__":
    main()