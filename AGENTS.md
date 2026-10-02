# AGENTS.md

Scanning and film processing for the Epson V600 and related scanners with a
transparency unit. The application is Zig 0.16: a CLI (`v600-zig`), a native
SDL3/Nuklear UI (`v600-ui`), a browser WebAssembly processing webapp built
from the same processing code, and a local scanner companion server that lets
the webapp drive a Linux scanner. The original Python implementation, a work
in progress that drove the port, stays in the tree for reference; the Zig app
has replaced it.

Current state, decisions, and open work: `plan.md`.

## How to work here

- Do what the owner asks. Do not pick up backlog items on your own, and do
  not invent new phases or plans. If you notice other work worth doing, add it
  to the `plan.md` backlog or mention it at the end.
- Keep changes scoped to the task. No drive-by refactors or formatting churn.
- Say exactly what you verified and how: unit tests, Node smokes, a real scan,
  or nothing. Do not claim success from a build or type check alone.
- Docs describe the current state. Do not append evidence logs, dated
  progress notes, or test-count snapshots to docs or `plan.md`; commit
  messages and git history hold that.
- Never run hardware steps unless the owner says the scanner is connected.

### Pseudonym

The project is published under the pseudonym `asingleoat`. Commits and
committed files must not contain the owner's real name, account username, or
personal email. That includes home-directory paths (`/home/<user>/...`,
`/Users/<user>/...`): write `$HOME/...` or repo-relative paths instead. Check
diffs for this before committing.

### Nix and the build environment

- Assume you are inside the project's Nix dev shell and use plain `zig ...`
  commands. OpenCV, libjpeg, SuperLU, libtiff, SDL3, and Nuklear come from
  that shell; outside it the build fails at the C/C++ objects.
- Do not run `nix develop`, `nix-shell`, `nix build`, or `nix flake check` in
  ordinary build/test loops. If a dependency or the Zig version is missing,
  edit `flake.nix`/`shell.nix` if needed, then stop and ask the owner to
  reload the shell.
- No pip, venv, npm, or other package managers. Node is used only to run the
  test harnesses in `test/wasm/`.

## Commands

    zig build --summary all                   # CLI: zig-out/bin/v600-zig
    zig build -Dui=true --summary all         # native UI: zig-out/bin/v600-ui
    zig build -Dui=true run-ui                # run the native UI
    zig build run -- <args>                   # run the CLI
    zig build test --summary all              # Zig unit and fixture tests
    zig build wasm-webapp                     # stage the webapp in zig-out/webapp
    zig build run -- serve                    # companion: serves zig-out/webapp on 127.0.0.1:8433

CLI: `version`, `scanner-contract`,
`scanner devices|probe|preview|scan|usb-reset|smoke|processing-smoke|macos-smoke`,
`processing info|detect|rebate|export`, `roll start|use|status|scan|export|review|check-frames`,
`serve`. Build with `-Doptimize=ReleaseFast` for real scanning sessions;
Debug export is several times slower.

Browser and companion tests are separate Node-driven steps, not part of
`zig build test`: `wasm-core-smoke`, `wasm32-core-smoke`,
`wasm-worker-protocol-smoke`, `wasm-worker-runtime-smoke`,
`wasm-webapp-shell-smoke`, `wasm-tiff-reader-smoke`,
`wasm-webapp-static-smoke`, `companion-smoke`. Headless native UI smokes are
`native-*-smoke` steps under `-Dui=true`. Hardware steps (`scanner-smoke`,
the preview/scan worker smokes) only run with `V600_HARDWARE_SMOKE=1`; their
`*-skip` variants check that they stay off otherwise.

Benchmarks: `zig build -Doptimize=ReleaseFast bench-processing-commands`
(user-visible Process latency), plus `bench-color`, `bench-render-curves`,
`bench-ir-inpaint`, `bench-gpu-readiness`. WebGPU tools need `-Dwebgpu=true`
and the `WGPU_NATIVE_*` environment variables from the `webgpu` dev shell.

Test data: four frame-detection tests run against real scans in the
gitignored `scans/` directory (`scan_0001`, `0003`, `0004`, `0006`) and skip
when they are absent, which they are in a fresh clone. The Linux scan path
shells out to ImageMagick `magick` and `tiffcp`, and the fake `scanimage`
scripts in the scanner tests and `companion-smoke` use `magick` too.

Environment variables: `V600_HARDWARE_SMOKE`, `V600_MACOS_HARDWARE_SMOKE`,
`V600_PROCESSING_GPU` (opt-in WebGPU processing in the native UI),
`V600_UI_THEME`, `V600_UI_SCALE`, `V600_SCANNER_DEVICE_CACHE`.

## Layout

    build.zig               build, test, smoke, benchmark, and webapp steps
    src/
      main.zig              CLI entry
      root.zig              the `v600` module: scanner, processing, tiff, UI state
      companion.zig         scanner companion HTTP server (`serve`)
      roll.zig, roll_cli.zig rolls: strips of one film roll, roll LUT,
                            background export, review page; `roll` CLI
      tiff.zig              libtiff wrapper: page layout, metadata tags
      scanner/              Linux SANE runtime (linux.zig, sane.zig), macOS
                            interpreter runtime (interpreter_runtime.zig,
                            usb.zig, macos.zig, interpreter.zig), events,
                            config, LUTs
      processing/           frame detection, inversion, IR cleaning, render,
                            export, workflow, config; C/C++ helpers for
                            OpenCV, libjpeg, SuperLU; optional WebGPU
      ui/                   headless UI state and workers; SDL3/Nuklear
                            front end in main.zig, render.zig, chrome.zig,
                            roll_panel.zig
      wasm/, wasm_core.zig  browser core: C-ABI exports over src/processing
      benchmarks/, tools/   benchmark and WebGPU tool executables
    web/                    browser app: ES modules, no bundler
      worker/               Wasm worker, message protocol, ABI layer
    test/
      fixtures/             committed regression fixtures, originally Python-generated
      wasm/                 Node harnesses for the Wasm core, worker, webapp, companion
    nixos/                  NixOS module and overlay: udev, patched epkowa backend
    scanner.py, scan.py, v600/, scratchndent/, test_detect.py
                            original Python implementation (reference only)

Dependency direction: `ui` imports `roll`, `processing`, `scanner`, and
`tiff`; `roll` imports `processing`, `scanner`, and `tiff`; `processing` and
`scanner` import only `tiff`; `companion` imports `scanner`. Keep it that
way. `processing` and `scanner` must not import each other or UI
code.

## Behavior changes and the Python code

- The Zig app is the product. Python parity is not a requirement: changes
  that improve results, including new defaults and threshold tweaks, are
  expected.
- Do not change the Python code. It has been frozen since 2026-04-17 and is
  kept only as a reference for how things used to work.
- The fixture tests in `test/fixtures/` were generated from the Python code
  and now serve as regression baselines. When you change output on purpose,
  update the affected expectations in the same commit and state what changed
  at the output (`max_abs`, RMS, mask overlap, frame geometry). Never loosen
  a tolerance just to make a test pass.
- Measure behavior changes on the real scans in `scans/` where possible, not
  only on fixtures, and say what you looked at.
- `docs/PYTHON_PORT_MAP.md` records where each Python function landed. It is
  historical and does not need updating.

## Performance rules

- Performance work keeps user-visible results the same unless the change is
  meant to improve them. Approximations (sampling, f32, lookup tables,
  downsampling) are fine when the speedup is worth the measured difference
  at the final surface: `u8` preview pixels, `u16` export pixels, masks,
  frame geometry, or metadata. Report `max_abs`, RMS, or mismatch counts.
- Benchmark with `-Doptimize=ReleaseFast` against the current Zig path.
  Record the command, input, dimensions, time, speedup, and error metric in
  the commit message; update the current-numbers table in
  `docs/PERFORMANCE_STRATEGY.md` only when a headline number changes.
- Sort image-sized arrays with non-quadratic algorithms.
- GPU paths stay opt-in with a CPU fallback and default off. Report cold and
  warm timings separately.
- Scanner startup is slow. Do not add blocking probes, `scanimage -L`, or
  `scanimage --help` calls on startup or scan paths; prefer cached
  capabilities and lazy connection.
- Image processing reachable from the native UI runs in worker threads on
  copied inputs. UI code draws and dispatches; it does not implement
  algorithms.
- The native UI thread never waits on long work (exports, scans, joining a
  busy thread). Whenever an action is unavailable or the app is waiting, the
  UI says why on screen: what it is waiting for and how far that has got.

## Domain notes

The scanner, TIFF, and coordinate facts below are hard constraints. The frame
detection and processing details describe current behavior; change them
deliberately, not by accident.

### Scanner

- Linux and macOS scanner paths are separate. Linux drives SANE through
  `scanimage` subprocesses; macOS loads Epson's interpreter library and
  supplies USB callbacks over libusb (`scanner/interpreter_runtime.zig`).
  `scanner.host` picks the runtime for the build target.
- Linux RGB TPU scans use the `scanimage-v600` wrapper; IR scans require
  `scanimage-v600-ir` (installed by `nixos/`). Plain `scanimage` with
  `SCAN_IR_MODE=1` is not a supported fallback. IR and RGB+IR device
  selection must use an `epkowa` / `epkowa:interpreter` device, never a
  cached `epson2` one.
- Sources are `Transparency Unit` and `Flatbed`. TPU resolutions: 400, 800,
  1600, 3200 dpi, plus 6400 dpi on the macOS interpreter path. IR
  resolutions: 800, 1600, 3200 dpi; IR is grayscale, and RGB+IR at 6400
  scans its IR pass at 3200. Non-IR 16-bit scans pass `--depth 16`.
- SANE scan areas are in millimetres (`-l -t -x -y`), clamped to the source
  geometry with a 0.1 mm margin.
- TPU scans are mirrored horizontally after capture; keep the final
  orientation identical to Python.
- Combined RGB+IR TIFFs: page 0 is RGB, page 2 is IR, page 1 may be a
  thumbnail. Do not assume sequential pages or equal RGB/IR dimensions.
- Progress, cancellation, and errors are structured JSONL events
  (`src/scanner/events.zig`); cancellation must stop the running scan and
  report a cancellation error.
- macOS: direct RS commands bypass the interpreter and can desynchronize it,
  so reinitialize afterwards. IR enablement uses the 32-byte XOR challenge
  key. TPU calibration order follows the captured traces. See
  `docs/SCANNER_INTERNALS.md`.

### Frame detection

- Detection runs on a downscaled preview; frame rects `(cx, cy, w, h, angle)`
  are in preview coordinates. Full-resolution coordinates scale by
  `1 / preview_scale`.
- Formats, frame across x along the strip: 35mm 24x36 mm, 38 mm pitch; 645
  56x41.5 mm, 45 mm pitch; 6x6 56x56 mm, 60 mm pitch; 6x7 56x69 mm, 73 mm
  pitch; 6x9 56x84 mm, 88 mm pitch. 645 is the one format whose long side
  runs across the strip.
- Pipeline: along the strip, edge evidence from seven bands across it
  (each position takes its three strongest bands, since a frame boundary
  often shows only where the pictures either side are bright), smoothed
  by 0.3 mm and scored by direction (brightness rises entering a frame and
  falls leaving it), with nothing taken from the film's cut ends or beyond
  them. A dynamic-program fit at the scan's DPI scale (the film's measured
  width when there is no DPI) places one frame length per strip within 6%
  of the format's (cameras differ), with gaps in the format's range that
  may differ between every pair of frames (35mm 0.2-6 mm, 120 0.5-12 mm),
  then a soft pull toward the strip's usual gap for frames whose edges
  barely show; fewer frames when the strip's length promised more than
  fit. Across the strip, the frame width is measured per strip within the
  format's band (35mm 2%, 120 4%), so the aspect comes from the film. Each
  frame's angle comes from its edges, sought the way round they turn,
  with angles more than 1 degree off the strip's median replaced by it.
  The Dmin rebate goes in a gap between frames and never overlaps one: the
  middle gap, else the nearest gap whose rebate clears every frame, else
  none. Roll export drops a detected rebate that overlaps hand-placed
  frames. 35mm and 6x7 are measured against the owner's frames; 645, 6x6,
  and 6x9 take the 120 settings unchecked.
- Judge frame detection only on real scans against frames the owner
  verified: `roll check-frames` (frames placed by hand, plus exports the
  owner verified via `--verified`) before and after every change, and the
  real-scan tests. Do not test or tune framing on synthetic strips.
- If detection returns exactly one frame covering less than 30% of the
  image, treat it as a failure and fall back to a full-image frame.

### Processing

- Input is 16-bit RGB plus optional IR. IR is usually scanned at lower
  resolution (1:2 or 1:4) and must be aligned before use.
- Order: transmittance, density, Dmin subtraction (from a rebate selection,
  or the full image as fallback), film stock transform, scene-linear RGB,
  tone map, gamut map, sRGB.
- Film stocks are 3x10 quadratic polynomials in density space with basis
  `[R, G, B, R^2, G^2, B^2, RG, RB, GB, 1]`. See
  `docs/FILM_STOCK_PROFILES.md`.
- IR defects: threshold, dilate/close, coverage cap, inpaint.
- Parameters are defined at 800 dpi. Linear parameters scale by
  `dpi / 800`, area parameters by `(dpi / 800)^2`.

### Config and files

- Two separate TOML configs: scanner `epdaughter_config.toml`, processing
  `scratchndent_config.toml`. Both are gitignored and generated at runtime.
  Saves merge into the existing file; go through the config layer, not raw
  TOML reads.
- Scans go to `scans/`, exports to `frames/`; both are gitignored. A roll
  uses `scans/<roll>/` (`roll.json`, `roll.lut.bin`, `strip_NN_*.tiff`,
  hand-placed framing in `strip_NN_*.tiff.frames.json`, `review/`) and
  `frames/<roll>/<roll>_sNN_FF.tif`; the current roll is the `[roll]` key in
  the scanner config.
- TIFF metadata: make, model, software, resolution, datetime. Custom tag
  50000 marks scanner custom LUTs; BYTE tag 50001 holds the applied LUT,
  which the RGB loaders invert; tag 65000 holds export metadata JSON.
- macOS gamma LUTs clip clear areas by design (both points come from the
  film strip), so scans need clear margins for frame detection; auto-select
  adds 2 mm per side.

## Conventions

- Zig 0.16 `std.Io` style. Tests live in `test` blocks next to the code;
  fixture-backed tests load JSON from `test/fixtures/`.
- Comments only where intent is not obvious from the code.
- Validate at system boundaries (CLI args, HTTP requests, files, scanner
  output); no defensive checks on internal calls.
- `web/` is plain ES modules loaded directly by the browser: `const`/`let`,
  camelCase, `async`/`await`, no framework, no build step.

## Docs

- `plan.md`: current state, decisions, backlog.
- `docs/PYTHON_PORT_MAP.md`: where each Python function landed in Zig
  (historical).
- `docs/PERFORMANCE_STRATEGY.md`: optimization policy and current numbers.
- `docs/CROSS_PLATFORM.md`: platform support and the macOS/Windows plans.
- `docs/WEBAPP.md`, `docs/WEBAPP_WORKER_PROTOCOL.md`: browser app and worker
  protocol.
- `docs/SCANNER_COMPANION.md`: companion server API.
- `docs/SCANNER_INTERNALS.md`: ESC/I protocol, interpreter ABI, TPU
  calibration, IR, gamma LUTs, epkowa patches.
- `docs/TIFF_STRATEGY.md`, `docs/FILM_STOCK_PROFILES.md`,
  `docs/RENDER_TRANSFORM_CLOSED_FORM.md`, `docs/NATIVE_UI_VERIFICATION.md`.
