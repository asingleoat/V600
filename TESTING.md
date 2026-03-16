# Testing SANE epson2 IR patch on Linux

## Prerequisites

- Epson V600 (GT-X820) connected via USB
- sane-backends source (clone from gitlab or use the included patch)
- Build deps: `libusb-1.0-dev libjpeg-dev libtiff-dev libpng-dev autoconf automake libtool pkg-config`

## Build

```sh
# Clone sane-backends if you don't have it
git clone https://gitlab.com/sane-project/backends.git sane-backends
cd sane-backends

# Apply our patch
git apply ../sane-epson2-ir-fixes.patch

# Build with IR support
./configure --prefix=$PWD/../sane-local CPPFLAGS="-DSANE_FRAME_IR"
make -j$(nproc)
make install
```

## Test 1: Scanner detection

```sh
export LD_LIBRARY_PATH=$PWD/../sane-local/lib
export SANE_CONFIG_DIR=$PWD/../sane-local/etc/sane.d

# Should show the V600 / GT-X820
../sane-local/bin/scanimage -L
```

## Test 2: Flatbed scan (sanity check)

```sh
../sane-local/bin/scanimage \
  --device 'epson2:libusb:XXX:YYY' \
  --resolution 300 \
  --mode Color \
  --format=tiff \
  > flatbed_test.tiff
```

## Test 3: TPU color scan (16-bit)

```sh
../sane-local/bin/scanimage \
  --device 'epson2:libusb:XXX:YYY' \
  --resolution 400 \
  --mode Color \
  --depth 16 \
  --source 'Transparency' \
  --format=tiff \
  > tpu_color_test.tiff
```

Check that the image has reasonable color balance (no extreme green cast).

## Test 4: IR scan (the main thing we're testing)

```sh
../sane-local/bin/scanimage \
  --device 'epson2:libusb:XXX:YYY' \
  --resolution 800 \
  --mode Infrared \
  --source 'Transparency' \
  --format=tiff \
  > ir_test.tiff
```

Expected: mono 8-bit image where clear background is near white (254-255)
and dust/scratches appear as dark spots.

Valid IR resolutions: 800, 1600, 3200 only.

## Test 5: IR below 800 DPI (should fail cleanly)

```sh
../sane-local/bin/scanimage \
  --device 'epson2:libusb:XXX:YYY' \
  --resolution 300 \
  --mode Infrared \
  --source 'Transparency' \
  --format=tiff \
  > /dev/null
```

Expected: clean error message, not a hang or crash.

## What the patch fixes

1. **IR depth was 1-bit (lineart) instead of 8-bit (mono)** — scanner NAKs depth=1, so IR scans failed immediately
2. **IR enable (ESC #) was called before scan params (FS W)** — challenge-response could use stale data
3. **IR enable return value was ignored** — failures were silent
4. **No minimum DPI check for IR** — scanner NAKs <800 DPI with confusing error
5. **TPU color profiles were dead code** — `if (0)` → `if (s->hw->use_extension)`
6. **GT-X820 missing from IR model list** — IR mode wasn't exposed to users

## Debugging

Set `SANE_DEBUG_EPSON2=10` for verbose protocol logging:

```sh
SANE_DEBUG_EPSON2=10 ../sane-local/bin/scanimage ...
```
