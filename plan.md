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
- Python: frozen at 2026-04-17; the committed JSON fixtures are the working
  oracle.
- All Zig tests and Node smokes pass in the dev shell. The real-scan
  detection tests need the local `scans/` directory. There is no CI; the
  flake check runs the Zig tests, the UI build, and the hardware-skip smokes.

## Decisions on record

Recorded by agents in the May-July log. Correct anything that is wrong.

- 2026-05-18: use the ambient Nix shell; no Nix evaluations in ordinary
  build/test loops.
- 2026-05-19: the f32 `invert_negative` preview hotspot is deferred.
- 2026-05-23: macOS build, test, and scanner work is paused until it is
  reopened on macOS hardware.
- GPU processing stays opt-in and off by default; measured whole-workflow
  runs were slower than the CPU path.

Recorded as owner decisions but not reconfirmed:

- The render display range uses a sampled percentile (16,384 samples)
  instead of the exact full-image percentile, for previews and exports.
- Mask overlap (IoU/Dice) is the primary acceptance gate for IR detector
  changes. It was used to make f32 adaptive dust the default, but a
  downsampled variant with higher overlap was rejected; see
  `docs/PERFORMANCE_STRATEGY.md`.
- "The project has met and exceeded Python parity for the native-app
  release" (2026-05-23). This was used to defer the legacy `_save_image` PNG
  writer and exact `scanner.py` argparse compatibility, and to close the
  release audit, although no parity-manifest row had been accepted.
- The browser webapp and the scanner companion were started by agents after
  that release claim. No owner request for either is recorded; the earlier
  plan had called the companion "a later design option".

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
  - Job ids restart at 1 on every launch, so `companion_scan_0001.tiff` is
    overwritten across sessions.
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

### Native code cleanup

- Delete dead code: 31 unused aliases in `src/ui/main.zig`, uncalled
  functions (frames, film_formats, tiff, process_cache, linux, macos,
  interpreter, gpu_boundary, ui/state), the `linux.zig` Python-port stubs,
  unused imports, `src/processing/xmp.zig` (not called by the product), and
  test-only `State` methods.
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
  ports: the grain ports replay the fixtures exactly and ECC agrees within
  0.05 px. Needs the owner's OK on that tolerance.

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
- Decide whether the Python tree stays in HEAD or only in history (tag
  48a4c79); the parity map's line references assume it stays.
- One Nix entry point: `shell.nix` and the flake dev shell have drifted
  (Nuklear defined twice, different Python sets). Add `build.zig.zon` with
  `minimum_zig_version`. Expose `nixos/` as flake outputs; fix the `lib.mkIf`
  inside a list and the world-writable `MODE="0666"` in
  `nixos/v600-scanner.nix`; update `nixos/README.md`.
- Flake checks: add the Node smokes and the webapp build; make sure the gate
  builds from git-tracked sources.
- An aggregate `web-test` build step.
- Fixtures: compact the one-number-per-line IR JSON arrays, delete or use the
  14 unreferenced scanner fixtures, correct fixture READMEs, and record how
  fixtures can be regenerated.
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
- Legacy `_save_image` PNG writer and exact `scanner.py` argparse
  compatibility.
