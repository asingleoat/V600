# V600 plan

Current state, decisions on record, and open work. This file replaces the
11,000-line rewrite plan and verification log kept during the May-July 2026
Zig port; that history is in git (`git show f3fb3e3:plan.md`, tags
`zig-port-mvp` and `pre-wasm-checkpoint`).

Agents: work on what the owner asks, not on the next backlog item. Add new
findings to the backlog; do not add phases or progress logs here.

## Current state

As of 2026-09-28, on branch `zig-rewrite`:

- Zig CLI and native SDL3/Nuklear UI cover scanning, frame detection,
  inversion, IR dust removal, export, and the gallery. Linux scanning was
  exercised on a V600 in May 2026.
- macOS: scanner protocol code exists and is replay-tested; there is no USB
  transport and the CLI refuses the backend. Paused.
- Windows: not wired.
- Browser webapp: processing and export in WebAssembly, built from the same
  Zig processing code. Tested only with Node harnesses; never run in a real
  browser.
- Scanner companion (`v600-zig serve`): lets the webapp scan through a Linux
  host. Tested only against a fake `scanimage`; has known bugs (below).
- Python: frozen at 2026-04-17, kept for reference only. Its fixtures are
  now regression baselines. A 2026-09-28 check found that the native UI
  covers every scanning, GUI, and processing workflow the Python app had;
  the gaps are listed under "Missing from the Python app".
- All Zig tests and Node smokes pass in the dev shell. The real-scan
  detection tests need the local `scans/` directory. There is no CI; the
  flake check runs the Zig tests, the UI build, and the hardware-skip smokes.

## Decisions

Confirmed by the owner, 2026-09-28:

- Python parity is not a requirement. The Python app was a work in progress
  that drove the port; the Zig app may change behavior, defaults, and
  thresholds to improve results. Fixture tests are regression baselines and
  are updated deliberately when output changes on purpose.
- The render display range uses a sampled percentile (16,384 samples) for
  previews and exports, for performance.

Recorded in the May-July log; correct anything that is wrong:

- 2026-05-18: use the ambient Nix shell; no Nix evaluations in ordinary
  build/test loops.
- 2026-05-19: the f32 `invert_negative` preview hotspot is deferred.
- 2026-05-23: macOS build, test, and scanner work is paused until it is
  reopened on macOS hardware.
- GPU processing stays opt-in and off by default; measured whole-workflow
  runs were slower than the CPU path.

Open:

- The browser webapp and the scanner companion were started by agents; no
  owner request for either is recorded. Keep, park, or drop?

## Backlog

### Bugs

- Linux custom film LUTs are not applied, but scans are marked as if they
  were. `src/scanner/linux.zig` sets `V600_LUT_FILE` and writes
  `custom_luts_applied=true` and TIFF tag 50000; nothing installed reads the
  variable (only the unbuilt `lut_dispatcher.c` shim does). Decide whether to
  package the shim in `nixos/` or stop setting the marker, then verify on
  hardware with a non-identity LUT. The frozen Python has a related break:
  `v600/core/backends/sane.py` looks for `lut_dispatcher.c` next to itself.
- Companion (`src/companion.zig`):
  - `startScan` returns on error while holding the job mutex, leaving it
    locked and the job stuck in `running`.
  - No Origin or Host check: any web page can POST to start or cancel a
    scan, and DNS rebinding could read scan files.
  - `/api/devices` runs `scanimage -L` on the accept thread and blocks the
    server; the Scan tab calls it every time it is opened, even mid-scan.
  - Terminal job status is set before the final status line is appended, and
    `startScan` joins the previous job thread while holding the lock it
    needs.
  - No LUT or preview scans. Scan-request parsing is a separate copy of the
    CLI's, and the aliases have drifted (`rgb_ir` vs `rgbir`; both accept
    `rgb+ir`).
- Webapp: see the known issues in `docs/WEBAPP.md`.
- Flaky test: a native UI scanner-worker test failed once with
  `TestUnexpectedResult` in 22 direct runs of the test binary.
- Passing test runs print about 130 JSON scanner timing events on stderr,
  which makes `zig build test` print a misleading `failed command:` line.

### Missing from the Python app

Native UI (scanning):

- Progress shows only a per-pass percentage; Python showed ETA, elapsed
  time, the combined RGB+IR total, and the ETA in the window title. The ETA
  formatters in `src/ui/scan_workflow.zig` exist but nothing calls them.
- No choice of scan and export directories (Python had `--scan-dir` and
  `--output-dir`); the UI uses `scans/` and `frames/` under the launch
  directory.
- No sound when a scan finishes.
- The TPU dpi list offers 1200 and 6400, which the scanner delivers at 800
  and 3200. Python resampled to the requested dpi; Zig names the file and
  estimates sizes for the requested dpi but delivers the native one.
- No `scanimage` timeout; a hung scan waits until cancelled.
- The IR page of RGB+IR files lacks Make/Model/Software/DateTime.
- The scan preview cannot be zoomed.

Native UI (processing), smaller:

- Export variant checkboxes are not saved when toggled.
- Prev/Next do not rescan the image folder for new scans.
- No frame labels, rebate label, fills, or cursor changes on the canvas; no
  tooltips on controls.

CLI (`v600-zig processing`):

- `export` ignores `scratchndent_config.toml` (defaults only), takes dpi only
  from `--dpi` instead of the TIFF, estimates Dmin per crop unless `--dmin`
  is given (so colour varies between frames) and never uses the Dmin saved
  by `rebate`, and accepts built-in stocks only.
- `detect` runs at full resolution and lacks the one-small-frame fallback.
- No preview command and no automatic output name for `scanner scan`.

Webapp: see the missing features in `docs/WEBAPP.md`; the most significant
are the missing dust-removal controls and DPI scaling, and Dmin staying at
placeholder values when no rebate is detected.

### Native code cleanup

- Delete dead code: 31 unused aliases in `src/ui/main.zig`, uncalled
  functions (frames, film_formats, tiff, process_cache, linux, macos,
  interpreter, gpu_boundary, ui/state), the `linux.zig` Python-port stubs,
  unused imports, and test-only `State` methods. Also the ports of Python
  code that was dead in Python too: `src/processing/xmp.zig` (darktable XMP),
  `negadoctor`, the darktable sigmoid and CAT16 paths in `color.zig`,
  `sigmoidTonemap`/`applySrgbGamma`, `makeRebateMask`, and the unused
  rebate-mask and dark/light inputs to `inversion.zig`. Check the WebGPU
  `apply_sigmoid` kernel, which depends on the sigmoid code.
- Remove rejected experiments: the `AdaptiveDustPrecision` variants and
  approximate blurs in `ir.zig`, benchmark-only `invertNegative*` variants,
  and concluded tradeoff cases in `src/benchmarks/processing_commands.zig`
  (verdicts in `docs/PERFORMANCE_STRATEGY.md`).
- Decide WebGPU's future: keep and trim (the adapter setup is copied five
  times), or move it to a branch (~3.7k lines).
- Shared helpers: `monotonicNowNs` (14 copies), JSON string escaping (5),
  spinlocks (3), small numeric helpers.
- A generic job type for the six UI workers and a generic LRU for the four
  caches in `src/ui/process_cache.zig`.
- Move the smoke harness out of `src/ui/main.zig`; wire or delete the smoke
  modes that are not build steps.
- Finish the file splits the July pass left partial: `frames.zig` (drop the
  alias facade, move stranded helpers), `ir.zig` (move the native/pure
  dispatch into `ir_native.zig`), `ui/main.zig`, `ui/state.zig`,
  `processing/workflow.zig`.
- Collapse `*Timed`/`*Breakdown` function pairs into optional timing
  outputs.
- Layering: one scan-request parser in `scanner/contracts.zig` shared by the
  CLI and companion, LUT generation out of `ui/scan_worker.zig` into
  the scanner layer (so the companion can use it), gallery operations out of
  `processing/export.zig`, one TOML lexer for both configs,
  `selection_geometry.zig` into the root module so it can be unit-tested.
- Build C/C++ with `addCSourceFiles`/`linkLibCpp` instead of `sh -c "c++
  ..."`, so optimize flags and header dependencies apply.
- Consider replacing `opencv_ir.cpp` and `opencv_ecc.cpp` with the pure Zig
  ports, which the webapp already uses: the grain ports replay the fixtures
  exactly and ECC agrees within 0.05 px. That would remove the OpenCV
  dependency from IR cleaning.

### Webapp cleanup

- The SHA-256 cache-key layer is computed but never used as a cache: delete
  it or build the cache.
- Exporting both IR variants for N frames recomputes the full-strip IR
  alignment and cleaning per variant per frame.
- Call the Zig rotated crop, area resize, and grain sizing through Wasm
  instead of the JS reimplementations; the JS preview downscale differs from
  native at non-integer scales.
- One source for ABI facts (struct layouts, status names, enum ids) instead
  of hand copies in `web/worker/wasm_abi.mjs`, `web/config.mjs`, and
  `src/wasm/core.zig`.
- Table-driven worker handlers; drop the protocol alias exports and the
  duplicated `isNodeRuntime`/`scalarArrayType`/`bufferToFloat32` helpers.
- Decode the input TIFF once per load, not on every action.

### Repo, Nix, tests

- Remove orphaned files once the LUT decision is made: `lut_dispatcher.c`,
  `unified_dispatcher.c`, `test_unified_dispatcher.sh`, `scripts/`,
  `lut_capturexhc1.pcapng` (cited by `docs/SCANNER_INTERNALS.md`),
  `test/test-combined-features.sh`.
- With parity dropped, decide whether the Python tree stays in HEAD or only
  in history (commit 48a4c79). `docs/PYTHON_PORT_MAP.md` line references
  would then point at that commit.
- One Nix entry point: `shell.nix` and the flake dev shell have drifted
  (Nuklear defined twice, different Python sets). Add `build.zig.zon` with
  `minimum_zig_version`. Expose `nixos/` as flake outputs; fix the `lib.mkIf`
  inside a list and the world-writable `MODE="0666"` in
  `nixos/v600-scanner.nix`; update `nixos/README.md`.
- Flake checks: add the Node smokes and the webapp build; make sure the gate
  builds from git-tracked sources.
- An aggregate `web-test` build step.
- Fixtures: compact the one-number-per-line IR JSON arrays, delete or use the
  14 unreferenced scanner fixtures, and update the fixture READMEs, which
  still describe the fixtures as Python oracles.
- `.gitignore`: anchor the image rules to output directories, drop dead
  entries, add `result*` and `.direnv/`.

### Needs the scanner

- Verify custom LUT application on Linux (after the LUT fix).
- A live scan through the webapp Scan tab and the companion.

### Parked

- macOS scanner runtime: USB transport, interpreter bundle loading, live
  tests. See `docs/CROSS_PLATFORM.md`.
- Windows builds and scanner support.
- Browser WebGPU; a WebUSB scanner driver (research only).
- Tiled or streaming processing for very large browser scans.
- GPU `render_to_display`.
- The f32 `invert_negative` preview hotspot.
