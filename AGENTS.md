# AGENTS.md

Film scanning and post-processing application for Epson V600 and related
flatbed scanners with transparency units. Single Python codebase, browser
UI, runs on Linux and macOS.

## Quick reference

    Entry point:    ./scan.py
    Server:         http://127.0.0.1:8432
    Scanner driver: scanner.py (SANE on Linux, Epson interpreter on macOS)
    Config file:    scratchndent_config.toml (gitignored, generated at runtime)
    Test suite:     python test_detect.py (requires scan TIFFs in scans/)
    Dependencies:   nix-shell (shell.nix)
    Type checker:   basedpyright

## What you can and cannot do without hardware

**Can do** (pure computation, no scanner or nix needed):
- Edit any Python module
- Run `basedpyright` for type checking (if installed)
- Read and reason about frame detection, color science, config logic
- Modify HTML/JS/CSS in gui files
- Refactor imports, extract modules, clean dead code

**Cannot do** (requires nix-shell + scanner hardware):
- Run `scan.py` or the HTTP server
- Run `test_detect.py` (needs TIFF files in `scans/`, which are gitignored)
- Test scanner communication
- Validate pywebview/Qt windowing

**Cannot do** (requires nix-shell but no hardware):
- Run processing-only code paths (numpy, opencv, tifffile, numba)
- Import any project module (dependencies come from nix)

If you can't run code, say so. Don't claim success based on type-checking alone.

## Project layout

```
scan.py                 Entry point (gui/cli subcommands)
scanner.py              Hardware driver (platform-dispatched)
shell.nix               Nix dev environment

v600/
  core/
    constants.py        Scanner models, resolutions, capabilities
    backends/sane.py    SANE backend (Linux)
  config/settings.py    Scanner config (TOML persistence)
  imaging/
    film.py             Film area detection, LUT computation
    lut.py              Binary LUT file creation (768 bytes)
  gui/
    server.py           Threaded HTTP server, route dispatch, pywebview
    scan_handlers.py    /scan/* routes + ScannerState
    process_handlers.py /process/* and /gallery/* routes
    scan_ui.py          Scanner UI (HTML embedded in Python)
    extract_ui.html     Processing UI
    gallery.html        Export gallery UI

scratchndent/
  config.py             Processing config (TOML), DPI scaling, film stocks
  export.py             Export pipeline (crop, IR clean, invert, write)
  calibration/
    film_stocks.py      Polynomial density transforms, stock coefficients
    measurement.py      Transmittance and density computation
  processing/
    defects/ir_removal.py   IR-based dust/scratch detection + inpainting
    frames/detection.py     Frame edge detection (DTW, gradient product)
    frames/extraction.py    Rotated rect crop, rebate extraction
    negative/
      color_transforms.py   Color space matrices, negadoctor, sigmoid (numba)
      inversion.py          Density-domain inversion pipeline
      render.py             Tone mapping, gamut mapping, sRGB output
  utils/
    io.py               TIFF I/O with metadata
    xmp_parser.py       darktable XMP sidecar parsing

docs/
  SCANNER_INTERNALS.md  ESC/I protocol, interpreter ABI, IR, gamma LUTs
  FILM_STOCK_PROFILES.md  Polynomial calibration format and presets

nixos/                  NixOS module, overlay, udev rules
```

## Architecture

### Server routing

Single `http.server` with `ThreadingMixIn`. Routes dispatched by prefix:

    /           → redirect to /scan/
    /scan/*     → scan_handlers.handle_get / handle_post
    /process/*  → process_handlers.handle_get / handle_post
    /gallery/*  → process_handlers (same module)

Each handler module owns its state as module-level globals.

### Scanner init

Non-blocking. Server starts immediately, scanner connects in a background
thread. UI polls `/scan/status` until `connected: true`. If connection
fails, `scanner_error` is set and the UI shows a message.

### Processing pipeline

    Raw TIFF (16-bit RGB + IR) → transmittance → density
    → Dmin subtraction (from rebate) → polynomial stock transform
    → scene-linear RGB → tone map → sRGB display

IR channel used for defect detection: threshold → dilate → inpaint.

### Frame detection

Edge-based detection along the strip axis:
1. Sum columns (or rows) to get 1D intensity profile
2. DTW alignment to expected frame pitch from format spec
3. Gradient-based edge snapping with Gaussian weighting
4. Size-consistency correction (reject frames deviating >30% from expected)
5. First/last frame fix using median pitch from interior frames
6. Cross-strip positioning via paired gradient product
7. Per-frame angle from Theil-Sen fit of edge positions

Formats: 35mm (24x36mm, 38mm pitch), 645 (56x42mm, 60mm pitch),
6x6 (56x56mm, 60mm pitch).

### Config system

Two independent config systems:

1. **Scanner config** (`v600/config/settings.py`): DPI, mode, area, port.
   File: `epdaughter_config.toml`.

2. **Processing config** (`scratchndent/config.py`): dust removal params,
   render settings, color, film stock. File: `scratchndent_config.toml`.

Both use TOML with section-based organization and self-documenting comments.
Parameters are DPI-scaled at access time via `get_param(name, current_dpi)`.

## Coding conventions

### Python

- Python 3.10+ syntax. Use `X | None` not `Optional[X]`.
- snake_case everywhere. UPPER_CASE for module constants. PascalCase for classes only.
- Type annotations on all function signatures.
- Docstrings: Google style, triple double quotes. Module docstrings explain purpose and relationships.
- Imports: stdlib → third-party → local, grouped with blank lines.
- No frameworks. stdlib `http.server`, raw numpy/opencv, manual TOML serialization.
- Section dividers in large files:
  ```python
  # ---------------------------------------------------------------------------
  # Section name
  # ---------------------------------------------------------------------------
  ```
- Sparse inline comments. Only where intent isn't obvious from the code.
- No defensive programming for internal interfaces. Validate at system boundaries only.

### JavaScript (embedded in HTML)

- `const`/`let`, no `var`.
- camelCase for all identifiers.
- `async`/`await` for fetch.
- Arrow functions for callbacks.
- No build step, no bundler, no framework. Vanilla JS with canvas.

### Error handling

- HTTP handlers catch `Exception` at the top level, return JSON `{"error": "..."}`.
- `BrokenPipeError` silently swallowed in response helpers (expected).
- Scanner errors stored in state, surfaced to UI via status endpoint.
- Processing errors returned as JSON to the frontend, displayed in status bar.

## Key patterns

### HTTP handler structure

```python
def handle_get(handler, sub_path):
    if sub_path == "/":
        _respond(handler, 200, "text/html", data)
    elif sub_path == "/status":
        _respond_json(handler, 200, {"connected": True})
    else:
        handler.send_error(404)

def handle_post(handler, sub_path, body):
    ...
```

### DPI scaling

Processing parameters are defined at reference 800 DPI. At runtime:
```python
scale = current_dpi / REFERENCE_DPI
# Linear params (radii, sizes): multiply by scale
# Area params (min_area): multiply by scale^2
```

### Film stock coefficients

10-term quadratic polynomial in density space:
```
basis = [R, G, B, R², G², B², RG, RB, GB, 1]
output_channel = dot(coefficients[channel], basis)
```

Stored in `scratchndent/calibration/film_stocks.py` as 3x10 numpy arrays.

## Things to watch out for

1. **State is module globals.** `process_handlers.py` uses `FULL_IMG`, `ALIGNED_IR`,
   `CURRENT_DPI` etc. as module-level state. Don't assume you can instantiate
   multiple processing sessions.

2. **Preview coordinates vs full-res.** Frame detection runs on a downscaled
   preview. All frame rects (`cx, cy, w, h, angle`) are in preview pixel coords.
   Scale by `1/preview_scale` to get full-res coords.

3. **IR alignment.** The IR channel is typically scanned at lower resolution
   than RGB (1:2 or 1:4). `align_ir()` handles upscaling and registration.
   Never assume IR and RGB are the same dimensions.

4. **TIFF page layout.** Multi-page TIFFs from this scanner: page 0 = RGB,
   page 2 = IR (page 1 may be a thumbnail). Don't assume sequential.

5. **Config is loaded once.** `load_config()` reads from disk only on first
   call. After that, `_CONFIG` is the in-memory dict. `save_config()` merges
   and persists. Don't bypass this by reading TOML directly.

6. **numba JIT.** `color_transforms.py` uses `@njit(parallel=True)`. First
   call compiles. Don't add Python objects or unsupported types to njit
   functions.

7. **No pip, no venv.** All dependencies come from `nix-shell`. Don't add
   `requirements.txt` or `setup.py`. The nix shell is the build system.

8. **Gitignored outputs.** `scans/`, `frames/`, `*.tiff`, `*.png`,
   `scratchndent_config.toml` are all gitignored. Don't reference them
   as if they'll exist in a fresh clone.

9. **Platform split in scanner.py.** Linux uses SANE (subprocess to
   `scanimage` or direct `sane` library). macOS uses a proprietary Epson
   `.so` loaded via ctypes with USB I/O callbacks. These are completely
   different code paths.

10. **Single-frame fallback.** If detection returns exactly 1 frame covering
    <30% of the image, it's treated as a detection failure and replaced with
    a full-image frame. Don't remove this guard.

## Testing

### Frame detection (test_detect.py)

Requires TIFF scans in `scans/` (gitignored). Run:
```
python test_detect.py              # all 4 test cases
python test_detect.py scan_0001    # specific scan
```

Compares detected frame rects against manual ground truth. Reports per-frame
RMS error in pixels. Current baseline: <30px RMS on all test cases.

Ground truth is in preview coordinates (top-left origin, `x, y, w, h, angle`).
The test converts to center coords for comparison.

### Type checking

```
basedpyright v600/ scratchndent/
```

### Manual testing

Start the server and exercise all three UIs:
- `/scan/` — preview, selection, scan (needs hardware)
- `/process/` — load TIFF, auto-detect, adjust params, export
- `/gallery/` — view exports, trash/delete

## File modification guidelines

- Don't add files unless strictly necessary. Prefer editing existing modules.
- Don't add docstrings or type annotations to code you didn't change.
- Don't add error handling for impossible cases.
- Don't refactor surrounding code when fixing a bug.
- Don't create abstractions for one-off operations.
- Don't add comments that restate what the code does.
- Keep the dependency on nix-shell. Don't add pip/poetry/conda alternatives.
- HTML files are self-contained. No external CSS/JS dependencies.
- When extracting code to a new module, update `__init__.py` exports.
