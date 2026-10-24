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
- Python: frozen at 2026-04-17, kept for reference only. Its fixtures are
  now regression baselines. A 2026-09-28 check found that the native UI
  covers every scanning, GUI, and processing workflow the Python app had;
  the smaller gaps it found have since been closed.
- All Zig tests and UI smokes pass in the dev shell. The real-scan
  detection tests need the local `scans/` directory. GitHub Actions
  (`.github/workflows/build.yml`) runs the Zig tests on macOS and builds the
  app's zip and the static Linux CLI on every push; the flake check runs the
  Zig tests, the UI build, and the hardware-skip smokes.

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

Confirmed by the owner, 2026-10-24:

- With no film stock selected, exports invert as Kodak Gold. The stock
  profiles are an eyeballed starting point, so Gold is as good a default as
  any.
- An Intel Mac build is low priority.
- Trash is the one-click way to remove a scan or export, into the system
  Trash; Delete, smaller beside it, asks first.
- Dust removal stays on for deeply underexposed frames: with the coarse
  fill grain their fills blend in (KODAKGOLD_200_3), so no suggestion to
  turn it off for now.
- The native app is the product. The browser webapp and the scanner
  companion that let it scan are dropped; they are in git history (tag
  `webapp-final`).

Recorded in the May-July log; correct anything that is wrong:

- 2026-05-18: use the ambient Nix shell; no Nix evaluations in ordinary
  build/test loops.
- 2026-05-19: the f32 `invert_negative` preview hotspot is deferred.
- 2026-05-23: macOS work paused; reopened 2026-09-28 to scan from a Mac.
- GPU processing stays opt-in and off by default; measured whole-workflow
  runs were slower than the CPU path.

## Backlog

### Bugs

- The Newton's rings check misses the rings in underexposed, noisy frames:
  KODAKGOLD_200_3 s05_03, and KODAKGOLD_200_2 s05_01, which the owner
  judges out of reach for an inexpensive check. Its threshold also leaves
  the weakest plain rings (KODAKGOLD_200_2 s04_04) unflagged, for a margin
  above the faint ones (owner's call). The owner's verdicts to
  judge changes against (other frames are unreviewed): visible rings in
  KODAKGOLD_200_0 s01_01, s01_03, s02_03, s03_03; KODAKGOLD_200_1 s01_02,
  s01_03, s01_04; KODAKGOLD_200_2 s02_04, s04_04, s05_04; KODAKGOLD_200_3
  s02_04, s03_05, s04_03, s04_04, s05_02; KODAKGOLD_200_120_0 s03_02
  (faint, but plain). Faint or none: KODAKGOLD_200_0 s01_04, s04_03;
  KODAKGOLD_200_1 s01_06; KODAKGOLD_200_2 s01_06 (leader), s02_03, s03_03;
  KODAKGOLD_200_3 s03_04; KODAKPORTRA_400_0 s01_02; UNKNOWNSTOCK_0 s05_01
  (leader).
- Newton's ring reduction leaves some rings, and a mark: a small vivid
  spot where a fibre lies at a ring centre (KODAKGOLD_200_3 s02_04: the fit
  stays off the fibre and the dust removal fills it in from ringed
  surroundings); the faint centre disc of KODAKGOLD_200_2 s02_04; the
  middle of contact-ring systems and of irregular IR rings, where the fine
  pass does not run. Also left:
  rings within 0.29 mm of strong picture edges, and rings whose
  centres score under the warning level, often beside strong picture
  content (the ring by the peony in KODAKGOLD_200_2 s05_04 scores 0.029).
  Weighting the score away from picture edges inflates ring-free frames'
  scores, so it is not the fix. The Process view's preview does
  not show the reduction.
- IR dust fills in textured picture still read as smooth patches
  (KODAKGOLD_200_0 s04_03, the patch in the green wall): the fills
  reproduce grain, not picture texture, and that frame's flattest tiles
  are sky, whose coarse grain is weaker than its midtones'. Copying texture
  from a clean nearby patch (a healing brush: the source plus the
  biharmonic fill of the difference at the edge) would carry both. Fills
  that bridge a bright object and a dark background show some dark speckle
  in the dark part (KODAKGOLD_200_2 s02_03). The fills' finest grain runs
  10-20% strong at 6400 dpi, from the coarse octaves' overlap with it.

- Colour tuning has no repeatable check on real frames, the way framing has
  `roll check-frames`: a `roll check-colour` reporting casts per tone band,
  channel density ratios, and dust-fill statistics would replace the
  one-off scripts used so far.
- The Kodak Portra balance comes from two frames; re-measure it once more
  Portra is scanned.
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
  - Above 3% coverage the cap drops all cleaning for the frame.
  - Faint surface dust is missed: a speck must lie 25 local standard
    deviations below its IR background, about 70 levels on the 8-bit
    3200 dpi IR. A speck 14 levels deep, 7 times the pixel noise, in the
    sky of KODAKGOLD_200_120_0 strip 1 frame 2 passed the ratio test but
    not that one. `ir_threshold` sets both tests and moves them opposite
    ways.
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
  _2, strip 1). Needs a per-frame evidence test before dropping frames, and
  edge strength is not it: those blank frames' edges are 0.01-0.02 of the
  strip's typical edge, but real frames reach as low as 0.10-0.18
  (KODAKGOLD_200_0 strip 4 frame 5, placed by hand; KODAKGOLD_200_3 strip
  2 frame 1). Picture content inside the frame may tell them apart.

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
- Remove the reference paths only the removed benchmark comparisons used:
  benchmark-only `invertNegative*` variants in `inversion.zig`. The f64
  adaptive dust detector stays as the reference for `f32_down4_coarse`.
- Decide WebGPU's future: keep and trim (the adapter setup is copied five
  times), or move it to a branch (~3.7k lines).
- Shared helpers: JSON string escaping (5 copies), spinlocks (3), small
  numeric helpers.
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
- Layering: LUT generation out of `ui/scan_worker.zig` into the scanner
  layer, gallery operations out of
  `processing/export.zig`, one TOML lexer for both configs,
  `selection_geometry.zig` into the root module so it can be unit-tested.
- Build C/C++ with `addCSourceFiles`/`linkLibCpp` instead of `sh -c "c++
  ..."`, so optimize flags and header dependencies apply.
- Replace `opencv_ir.cpp` (grain estimation and synthesis) with the pure Zig
  ports in `ir_pure.zig`, which the webapp used and which replay the
  fixtures exactly; they need a real FFT first (theirs is a direct DFT,
  about a second per fill region); it also indexes with 32-bit ints, which per-frame sizes stay under
  for now (a 6x9 frame at 6400 dpi is about 0.9 billion samples). ECC
  alignment already moved to Zig.

### Repo, Nix, tests

- Remove orphaned files once the LUT decision is made: `lut_dispatcher.c`,
  `unified_dispatcher.c`, `test_unified_dispatcher.sh`, the Python files in
  `scripts/` (the macOS app bundle script there stays),
  `lut_capturexhc1.pcapng` (cited by `docs/SCANNER_INTERNALS.md`),
  `test/test-combined-features.sh`.
- macOS app bundle: no icon yet. Intel Macs would need an `x86_64-darwin`
  build (low priority).
- The macOS app is ad hoc signed, so testers must allow it in Privacy &
  Security on first launch; notarization needs a paid Apple Developer
  account.
- Other scanner models, from testers' reports: the resolutions each accepts
  (the 4800 dpi and interpreter-less ones are guesses), whether IR and the
  IR challenge work beyond the V600, whether their film scans need a TPU
  calibration sequence like the V600's (a USB capture of Epson Scan on the
  model), and whether the interpreter-less ESC/I path runs at all. The
  scan area comes from the scanner, but some defaults follow the V600:
  auto-select takes the largest film region on the preview (one strip of a
  holder with several side by side), a roll's default frame rotation
  assumes strips loaded as in the V600's holder, and scan-time estimates
  use the V600's line times.
- With parity dropped, decide whether the Python tree stays in HEAD or only
  in history (commit 48a4c79). `docs/PYTHON_PORT_MAP.md` line references
  would then point at that commit.
- One Nix entry point: `shell.nix` and the flake dev shell have drifted
  (Nuklear defined twice, different Python sets); the Linux checkout's
  direnv uses `shell.nix`, so making it load the flake's shell needs the
  owner to reload there. Add `build.zig.zon` with `minimum_zig_version`.
- Flake checks: make sure the gate builds from git-tracked sources.

### Needs the scanner

- Verify custom LUT application on Linux (after the LUT fix).
- A full 3200 dpi roll through `roll scan` or Scan Strip; the hardware runs
  so far used 800 dpi strips.
- 6400 dpi RGB on Linux. The hardware supports it and the `scanimage-v600`
  wrapper and patched epkowa backend claim 16-bit up to 6400, but the Zig
  SANE path stops at 3200 (`sane.zig` TPU list, `linux.zig` `film_dpis`).
  Try a 6400 `scanimage-v600` scan; if epkowa or the interpreter rejects or
  degrades it, patch them in `nixos/` as was done for IR. Then add 6400 to
  both lists; RGB+IR keeps IR at 3200 as on macOS.

### Parked

- Windows builds and scanner support.
- GPU `render_to_display`.
- The f32 `invert_negative` preview hotspot.
