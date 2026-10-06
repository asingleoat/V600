# CerealGrain plan

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
  film. CLI, native UI, and tests build there. `zig build app-bundle`
  makes a shareable, ad hoc signed CerealGrain.app (Apple Silicon, macOS 14+)
  that works in `~/Pictures/CerealGrain`.
- Other Epson film scanners: ten more models are in `scanner/models.zig`
  from Epson's driver tables, untested and awaiting beta testers' reports
  (`docs/CROSS_PLATFORM.md`, Scanner models).
- Rolls: `cerealgrain roll ...` and the Scan view's roll controls scan a film
  roll strip by strip (preview, film area, one LUT per roll, full scan) and
  export each strip in the background with a review page. Exercised on the
  V600 from the CLI and the UI's Scan Strip at 800 dpi.
- Linux: `nix build .#cli-static` makes a fully static x86-64 CLI (musl);
  the native UI is not static.
- Windows: not wired.
- Browser webapp: processing and export in WebAssembly, built from the same
  Zig processing code. Node smokes plus a manual headless Chrome/Chromium
  check; Firefox and Safari untried.
- Scanner companion (`cerealgrain serve`): lets the webapp scan through a Linux
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
- Dust removal covers only defects on the film when it is scanned. Dust on
  the film plane at exposure time is part of the picture (dark specks in
  the positive, invisible to the IR); removing it belongs in downstream
  image editing, not in scanning or scan processing. (2026-10-02)
- Frame orientation stays manual (per roll, edited by hand): whether a frame
  is portrait or landscape needs the picture's content recognized, which is
  more trouble than it is worth to automate. (2026-10-02)
- UNKNOWNSTOCK_0 is from a disposable camera whose film stock is unknown; it
  keeps the Kodak Gold profile and automatic white balance handles its
  balance (its blue range is about green's, against Gold's 1.2x). (2026-10-02)

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

- The Newton's rings check's threshold awaits the owner's review of the
  frames it flags that nobody has looked at: KODAKGOLD_200_1 s01_04,
  KODAKGOLD_200_3 s02_04, s03_05, s05_02, s04_04, s04_03, and
  KODAKGOLD_200_0 s01_01, s02_03 (and, just under the threshold,
  KODAKGOLD_200_2 s04_04). Owner-confirmed rings it flags:
  KODAKGOLD_200_0 s01_03, s03_03, KODAKGOLD_200_1 s01_02, s01_03,
  KODAKGOLD_200_2 s02_04, s05_04, KODAKGOLD_200_120_0 s03_02. It misses
  KODAKGOLD_200_3 s05_03, underexposed and noisy; KODAKGOLD_200_2 s05_01
  is too noisy for an inexpensive check (owner's call). Confirmed
  ring-free, and not flagged: KODAKGOLD_200_0 s04_03, KODAKPORTRA_400_0
  s01_02, and two leader frames (KODAKGOLD_200_2 s01_06, UNKNOWNSTOCK_0
  s05_01); KODAKGOLD_200_2 s02_03 has a faint ring the owner finds
  unobjectionable, and is not flagged.
- IR dust removal leaves over-smooth patches in KODAKGOLD_200_2 s02_03
  (owner review): inpainted areas without enough synthetic grain.

- Colour tuning has no repeatable check on real frames, the way framing has
  `roll check-frames`: a `roll check-colour` reporting casts per tone band,
  channel density ratios, and dust-fill statistics would replace the
  one-off scripts used so far.
- The Kodak Portra balance comes from two frames; re-measure it once more
  Portra is scanned.
- Export speed on macOS: SuperLU's BLAS there is an OpenBLAS with one lock
  around its buffer pool, so dust fills run at most four solves at once (a
  6x7 frame's fills take 6.1 s, against 2.0 s on 16 Linux threads). SuperLU
  on Accelerate or its internal BLAS would lift that, at a rounding-level
  change to the fills.
- `companion-smoke` fails on macOS: its fake `scanimage` drives the Linux
  scanner path. It should skip there.
- IR dust removal, open points from its audit:
  - Alignment applies whatever translation ECC returns:
    `AlignOptions.max_offset` is never used and the correlation is not
    checked, so a failed fit would move the whole mask off the dust.
  - The hair detector runs at a fixed quarter of the IR's resolution with
    ridge widths of 1-8 px there, so it does not follow the IR's dpi (it
    suits a 3200 dpi IR pass).
  - Closing merges specks closer than twice its radius (0.38 mm) into one
    fill; it could close hair detections only.
  - Dense picture areas show in the IR (the dyes absorb some infrared) and
    can pass the threshold, so real detail gets filled (foliage on
    KODAKGOLD_200_0 strip 1). Removing the IR's correlation with the red
    channel before thresholding would stop it.
  - Synthetic grain's size mix is off after inversion: its finest part is
    about 1.25x the surround's and its 1-4 px part about half
    (KODAKGOLD_200_0 strip 1 frame 4). Strength and spectrum are measured
    on the negative, before inversion.
  - Above 3% coverage the cap drops all cleaning for the frame.
  - Faint surface dust is missed: a speck must lie 25 local standard
    deviations below its IR background, about 70 levels on the 8-bit
    3200 dpi IR. A speck 14 levels deep, 7 times the pixel noise, in the
    sky of KODAKGOLD_200_120_0 strip 1 frame 2 passed the ratio test but
    not that one. `ir_threshold` sets both tests and moves them opposite
    ways.
- `cerealgrain-ui --process-interaction-smoke` (not a build step) fails with
  ProcessInteractionSmokeFailed.
- Loading an image, auto-detect, and export in the Process view copy the
  cached RGB page on the UI thread before starting their worker
  (`getCachedRgbPage`, `rgb_pages.getClone`). Pages over the 1 GiB cache
  budget (6400 dpi strips) are never cached, so this bites at 3200 dpi and
  below: a pause of a second or so per action. Sharing the cached page
  read-only with workers (reference-counted) would remove the copy.
- Medium-format frame detection is weak on real strips. The first real 6x7
  strip (6400 dpi, two frames) got frame 2 right but cut frame 1 to
  60x49 mm, missing picture on the left and bottom, and its rebate box
  overlapped the bottom of frame 1. Every format moved off the DTW pitch
  alignment to a fixed-length fit (one frame length per strip, gaps within
  the format's `gap_range_mm`, width measured within `width_variation`,
  scale from the scan's DPI). 35mm and 6x7 are measured with `roll
  check-frames` against the owner's frames: KODAKGOLD_200_0 (hand framings
  on strips 3-5, verified exports of strips 1-2) and KODAKGOLD_200_120_0
  (hand framings on strips 1, 3, 4, 5). Hand frames are drawn at a locked
  aspect, so their widths are approximate (the 6x7 gate is wider than the
  56:69 lock); measured widths were checked by eye against the picture
  edges. 645, 6x6, and 6x9 use the 6x7 settings unchecked: measure them
  once strips in those formats are hand-framed.
- A 35mm strip with blank film at one end gets an extra frame on the blank
  part: the frame count comes from the strip's length (KODAKGOLD_200_1 and
  _2, strip 1). Needs a per-frame evidence test before dropping frames.

- Linux custom film LUTs are not applied, but scans are marked as if they
  were. `src/scanner/linux.zig` sets `CEREALGRAIN_LUT_FILE` and writes
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
- Replace `opencv_ir.cpp` (grain estimation and synthesis) with the pure Zig
  ports, which the webapp already uses and which replay the fixtures
  exactly; it also indexes with 32-bit ints, which per-frame sizes stay under
  for now (a 6x9 frame at 6400 dpi is about 0.9 billion samples). ECC
  alignment already moved to Zig.

### Webapp cleanup

- Features the native app has and the webapp lacks: custom stocks, output
  rotation, manual rebate selection, settings persistence, multi-image
  browsing, the embedded metadata tag, exact-aspect frames, print copies,
  and preview or LUT scans through the companion (details in
  `docs/WEBAPP.md`).
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
  `unified_dispatcher.c`, `test_unified_dispatcher.sh`, the Python files in
  `scripts/` (the macOS app bundle script there stays),
  `lut_capturexhc1.pcapng` (cited by `docs/SCANNER_INTERNALS.md`),
  `test/test-combined-features.sh`.
- macOS app bundle: no icon yet, and Intel Macs would need an
  `x86_64-darwin` build.
- Other scanner models, from testers' reports: the resolutions each accepts
  (the 4800 dpi and interpreter-less ones are guesses), whether IR and the
  IR challenge work beyond the V600, whether their film scans need a TPU
  calibration sequence like the V600's (a USB capture of Epson Scan on the
  model), and whether the interpreter-less ESC/I path runs at all.
- Some UI worker tests (`src/ui/process_worker.zig`) load `processing.toml`
  from the working directory, so a test run reads the developer's own
  config at the repo root; they should use a temporary config.
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
- 6400 dpi RGB on Linux. The hardware supports it and the `scanimage-v600`
  wrapper and patched epkowa backend claim 16-bit up to 6400, but the Zig
  SANE path stops at 3200 (`sane.zig` TPU list, `linux.zig` `film_dpis`).
  Try a 6400 `scanimage-v600` scan; if epkowa or the interpreter rejects or
  degrades it, patch them in `nixos/` as was done for IR. Then add 6400 to
  both lists; RGB+IR keeps IR at 3200 as on macOS.

### Parked

- Windows builds and scanner support.
- Browser WebGPU; a WebUSB scanner driver (research only).
- Tiled or streaming processing for very large browser scans.
- GPU `render_to_display`.
- The f32 `invert_negative` preview hotspot.
