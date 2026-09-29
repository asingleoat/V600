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
- macOS: scanning works on a V600 from Apple Silicon through Epson's
  Interpreter bundle over libusb, with per-channel gamma LUTs fitted to the
  film. CLI, native UI, and tests build there.
- Rolls: `v600-zig roll ...` and the Scan view's roll controls scan a film
  roll strip by strip (preview, film area, one LUT per roll, full scan) and
  export each strip in the background with a review page. Exercised on the
  V600 from the CLI and the UI's Scan Strip at 800 dpi.
- Windows: not wired.
- Browser webapp: processing and export in WebAssembly, built from the same
  Zig processing code. Node smokes plus a manual headless Chrome/Chromium
  check; Firefox and Safari untried.
- Scanner companion (`v600-zig serve`): lets the webapp scan through a Linux
  host. Tested only against a fake `scanimage`; has known bugs (below).
- Python: frozen at 2026-04-17, kept for reference only. Its fixtures are
  now regression baselines. A 2026-09-28 check found that the native UI
  covers every scanning, GUI, and processing workflow the Python app had;
  the smaller gaps it found have since been closed.
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
- 2026-05-23: macOS work paused; reopened 2026-09-28 to scan from a Mac.
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
  hardware with a non-identity LUT. Applying them also means writing tag
  50001 so loaders linearize (the macOS backend does). The frozen Python has
  a related break: `v600/core/backends/sane.py` looks for `lut_dispatcher.c`
  next to itself.
- Linux scans come out with about gamma 1.8 applied, macOS scans linear:
  film-base Dmin of one Gold 200 strip was 0.28/0.42/0.60 on Linux and
  0.50/0.76/1.09 on macOS, a ratio of 1.8. The epkowa backend's default
  gamma is the likely cause; `sane.zig` passes no gamma option. Processing
  treats both as linear, so Linux densities are compressed. Decide which to
  standardize on (the film profiles are hand-tuned either way).
- A saved Dmin does not carry across LUT scans outside a roll: linearization
  scales each channel so its white point is 65535, a per-LUT density offset.
  Within a roll every strip shares one LUT, so the roll's Dmin fallback
  holds; a Dmin saved from another roll or plain scan is off by the
  difference in LUT gains.
- Linux scans are not written atomically (scanimage and tiffcp write the
  final path directly); the macOS backend writes `<name>.partial` and
  renames.
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
- With no film stock selected, exports still invert with `kodak_gold`
  (`film_stock orelse "kodak_gold"` in `src/processing/export.zig`). Python
  had no inversion without a stock. Decide which is intended.
- The image list ignores symlinked TIFFs (`tiff.findImages` accepts only
  regular files), so a scan folder of symlinks shows "No scan TIFFs found".
- Passing test runs print about 130 JSON scanner timing events on stderr,
  which makes `zig build test` print a misleading `failed command:` line.

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

- Features the native app has and the webapp lacks: custom stocks, output
  rotation, manual rebate selection, settings persistence, multi-image
  browsing, the embedded metadata tag, and preview or LUT scans through the
  companion (details in `docs/WEBAPP.md`).
- After auto-detect sets the rebate Dmin, the preview is not re-rendered
  until Update Preview is pressed.

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
- A full 3200 dpi roll through `roll scan` or Scan Strip; the hardware runs
  so far used 800 dpi strips.
- A live scan through the webapp Scan tab and the companion.

### Parked

- Windows builds and scanner support.
- Browser WebGPU; a WebUSB scanner driver (research only).
- Tiled or streaming processing for very large browser scans.
- GPU `render_to_display`.
- The f32 `invert_negative` preview hotspot.
