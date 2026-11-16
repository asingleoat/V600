# AGENTS.md

CerealGrain: scanning and film processing for the Epson V600 and related
scanners with a transparency unit. The application is Zig 0.16: a CLI
(`cerealgrain`) and a native SDL3/Nuklear UI (`cerealgrain-ui`). The
original Python implementation, a work in progress that drove the port, stays
in the tree for reference; the Zig app has replaced it.

Current state, decisions, and open work: `plan.md`.

## How to work here

- Do what the owner asks. Do not pick up backlog items on your own, and do
  not invent new phases or plans. If you notice other work worth doing, add it
  to the `plan.md` backlog or mention it at the end.
- Keep changes scoped to the task. No drive-by refactors or formatting churn.
- Say exactly what you verified and how: unit tests, UI smokes, a real
  scan, or nothing. Do not claim success from a build or type check alone.
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
  commands. libjpeg, libtiff, libdeflate, Little CMS, SDL3, and Nuklear
  come from that shell; outside it the build fails at the C libraries.
- Do not run `nix develop`, `nix-shell`, `nix build`, or `nix flake check` in
  ordinary build/test loops. If a dependency or the Zig version is missing,
  edit `flake.nix` (the one dev shell; `shell.nix` only loads it), then stop
  and ask the owner to reload the shell.
- No pip, venv, npm, or other package managers.

## Commands

    zig build --summary all                   # CLI: zig-out/bin/cerealgrain
    zig build -Dui=true --summary all         # native UI: zig-out/bin/cerealgrain-ui
    zig build -Dui=true run-ui                # run the native UI
    zig build run -- <args>                   # run the CLI
    zig build test --summary all              # Zig unit and fixture tests
    zig build app-bundle                      # macOS: zig-out/CerealGrain.app and a .dmg to share
    nix build .#cli-static                    # x86-64 Linux: a fully static CLI in result/bin

GitHub Actions (`.github/workflows/build.yml`) runs the Zig tests on macOS
and builds the app's disk image and the static Linux CLI on every push; a
pushed `v*` tag publishes them as a GitHub pre-release.

CLI: `version`, `scanner-contract`,
`scanner devices|probe|preview|scan|usb-reset|smoke|processing-smoke|macos-smoke`,
`processing info|detect|rebate|export`,
`roll start|use|status|scan|export|review|check-frames`,
`print printers|options|file` (`print file --raster-out FILE` writes the
page instead of printing it). Build with
`-Doptimize=ReleaseFast` for real scanning sessions; Debug export is several
times slower.

Headless native UI smokes are `native-*-smoke` steps under `-Dui=true`. Hardware steps (`scanner-smoke`, the
preview/scan worker smokes) only run with `CEREALGRAIN_HARDWARE_SMOKE=1`;
their `*-skip` variants check that they stay off otherwise.

Benchmarks: `zig build -Doptimize=ReleaseFast bench-processing-commands`
(user-visible Process latency), plus `bench-color`,
`bench-ir-inpaint`, `bench-gpu-readiness`. WebGPU tools need `-Dwebgpu=true`
and the `WGPU_NATIVE_*` environment variables from the `webgpu` dev shell.

Test data: four frame-detection tests run against real scans in the
gitignored `scans/` directory (`scan_0001`, `0003`, `0004`, `0006`) and skip
when they are absent, which they are in a fresh clone. The Linux scan path
shells out to ImageMagick `magick` and `tiffcp`, and the fake `scanimage`
scripts in the scanner tests use `magick` too.

Environment variables: `CEREALGRAIN_HARDWARE_SMOKE`,
`CEREALGRAIN_MACOS_HARDWARE_SMOKE`, `CEREALGRAIN_PROCESSING_GPU` (opt-in
WebGPU processing in the native UI), `CEREALGRAIN_UI_THEME`,
`CEREALGRAIN_UI_SCALE`, `CEREALGRAIN_UI_WIDE_GAMUT` (`0` keeps the macOS
screen sRGB), `CEREALGRAIN_SCANNER_DEVICE_CACHE`,
`CEREALGRAIN_DATA_DIR` (the UI's folder for scans, exports, and configs).

## Layout

    build.zig               build, test, smoke, and benchmark steps
    src/
      main.zig              CLI entry
      root.zig              the `v600` module: scanner, processing, tiff, UI state
      roll.zig, roll_cli.zig rolls: strips of one film roll, roll LUT,
                            background export, review page; `roll` CLI
      printing/, print_cli.zig colour-managed printing: CUPS (libcups
                            loaded at run time), PPDs, CUPS raster, print
                            jobs; `print` CLI
      tiff.zig              libtiff wrapper: page layout, metadata tags
      scanner/              Linux SANE runtime (linux.zig, sane.zig), macOS
                            interpreter runtime (interpreter_runtime.zig,
                            usb.zig, macos.zig, interpreter.zig), events,
                            config, LUTs
      processing/           frame detection, inversion, IR cleaning, render,
                            export, workflow, config; a C helper for
                            libjpeg; optional WebGPU
      ui/                   headless UI state and workers; SDL3/Nuklear
                            front end in main.zig, render.zig, chrome.zig,
                            roll_panel.zig
      benchmarks/, tools/   benchmark and WebGPU tool executables
    test/
      fixtures/             committed regression fixtures, originally Python-generated
    nixos/                  NixOS module and overlay: udev, patched epkowa backend
    scanner.py, scan.py, v600/, scratchndent/, test_detect.py
                            original Python implementation (reference only)

Dependency direction: `ui` imports `roll`, `printing`, `processing`,
`scanner`, and `tiff`; `roll` imports `processing`, `scanner`, and `tiff`;
`printing` imports `processing` and `tiff`; `processing` and
`scanner` import only `tiff`. Keep it that way. `processing` and `scanner`
must not import each other or UI code. `clock.zig` (the monotonic clock) is a
leaf any of them may import.

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
  supplies USB callbacks over libusb (`scanner/interpreter_runtime.zig`),
  or sends ESC/I straight over USB to a model without an interpreter.
  `scanner.host` picks the runtime for the build target.
- Models: `scanner/models.zig`, from Epson's ICA driver tables (USB IDs,
  interpreters, resolutions). Only the V600 is tested. The facts below are
  the V600's; other models take their resolutions from the table, IR only
  where the scanner reports it, and never the V600's TPU program or
  wrappers. See `docs/CROSS_PLATFORM.md` (Scanner models).
- Linux RGB TPU scans of a V600 use the `scanimage-v600` wrapper; IR scans
  require `scanimage-v600-ir` (installed by `nixos/`). Plain `scanimage`
  with `SCAN_IR_MODE=1` is not a supported fallback. IR and RGB+IR device
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
  fit, and one more when it fits with every frame showing an edge (0.3 of
  the strip's typical edge), since some cameras space frames closer than
  the format's pitch (a disposable's six 35mm frames run cut end to cut
  end, 37.7 mm apart). Across the strip, the frame width is measured per strip within the
  format's band (35mm 2%, 120 4%), so the aspect comes from the film. Each
  frame's angle comes from its edges, sought the way round they turn, then
  is pulled toward the strip's (the median of the frames): frames turn
  about 0.1 degree against each other beyond the strip's own rotation, so
  a frame moves the more the less certain its edges are, and one more than
  1 degree off, or without an angle, takes the strip's.
  The Dmin rebate goes in a gap between frames and never overlaps one: the
  middle gap, else the nearest gap whose rebate clears every frame, else
  none. Roll export drops a detected rebate that overlaps hand-placed
  frames. 35mm and 6x7 are measured against the owner's frames; 645, 6x6,
  and 6x9 take the 120 settings unchecked.
- Judge frame detection only on real scans against frames the owner
  verified: `roll check-frames` (frames placed by hand, plus exports the
  owner verified via `--verified`) before and after every change, and the
  real-scan tests. Do not test or tune framing on synthetic strips.
- Several strips side by side in one scan (two 35mm strips on the V600's
  glass): the detector first separates the strips (`processing/strips.zig`).
  Film is darker than the light through clear glass (a second Otsu split,
  among the brighter pixels, between film base and glass), so each strip is
  its own region however close they lie; a strip's region is at least a
  quarter of the largest, 2.5 times longer than wide, and with the scan's
  scale 0.6 of the format's strip width. Each strip is cut out with 2 mm
  round it, the other strips painted over as clear glass, and detected on
  its own; frames list strip by strip, left to right, and the rebate goes
  in the first strip's gaps. A strip whose outer side the scan's border
  cuts off (two 35mm strips are 70 mm, the V600's transparency unit
  68.6 mm) is centred from a line fitted to its inner edge and the format's
  strip width, at that line's angle. A scan with one strip goes through
  unchanged. Auto-select takes every film region at least a quarter the
  largest, so the strips scan in one pass.
- A 35mm strip's two perforation rows (clear holes 2.79 mm across and
  1.98 mm along, centres 28.16 mm apart, `processing/perforations.zig`)
  bound its frames: a frame reaching within 0.05 mm of the holes' inner
  edges moves back between them, or narrows. On thin film the holes'
  edges are the strongest near a frame. The rows do not place frames:
  the frame is fixed to the camera body and the film wanders in the gate,
  so on the owner's strips hand-placed frames sit up to 0.36 mm off the
  rows' midline and about 0.2 degrees off their angle; frames keep their
  own edges' position and angle. (Hiding the holes from the edge search
  instead of bounding frames measured slightly worse against the owner's
  frames, since a picture edge right by the holes fell inside the hidden
  band.)
- In a roll, each strip's export records its frames' length
  (`frame_length_mm` in the `.processed.json`). A strip whose frames come
  out more than 2% off the median of the roll's other strips is detected
  again at that length, within 1%: one camera exposed the roll, and on
  underexposed film the frames' ends barely show (KODAKGOLD_200_3 strip 5
  fitted 34.45 mm against the roll's 36.4).
- If detection returns exactly one frame covering less than 30% of the
  image, treat it as a failure and fall back to a full-image frame.
- The `exact_aspect` processing setting (the Strip view's "Exact aspect",
  `processing detect --exact-aspect`; roll exports follow the setting)
  trims each detected frame about its center to the format's exact aspect,
  for prints: the largest such rectangle inside the frame the camera
  exposed. The rebate is placed from the untrimmed frames, the full-image
  fallback is never trimmed, and `roll check-frames` always measures the
  detector's own frames.

### Processing

- Input is 16-bit RGB plus optional IR. IR is usually scanned at lower
  resolution (1:2 or 1:4) and must be aligned before use.
- Order: transmittance, density, Dmin subtraction (from a rebate selection,
  or the full image as fallback), film stock transform (channel balance in
  density), then per frame: automatic white balance (red and blue onto
  green's density scale through each channel's own black and white points;
  `auto_white_balance`, default 1), characteristic-curve inversion
  (`film_gamma` 0.55, softplus toe `film_toe` 0.25) to log exposure, dye
  crosstalk undone (`dye_crosstalk` 0.2), automatic exposure (log-average to
  18% grey, plus compensation in stops; temperature/tint as gains), a
  log-logistic display curve through 18% grey (`render_contrast` 1.8), sRGB.
  With `render_highlight_target` (0 = off) automatic exposure instead puts
  the frame's 99th percentile of display lightness (Oklab L) at the target,
  bisected on the measured samples, within two stops of the log-average's
  exposure; compensation still applies on top.
  Then neutral white balance (`neutral_white_balance`, default 1, the
  Frame view's "Neutral WB"; before temperature/tint, which stay a
  deliberate cast on top): the render measures its own nearly neutral
  surfaces (Oklab chroma under 0.07, narrowing to 0.035 over five passes;
  lightness 0.25-0.92; nothing clipped) and takes their average cast out
  by channel gains at constant luminance, at most half a stop, only half
  of each step along blue-yellow (pale skies, haze, and sunsets read as
  nearly neutral). A frame with under 3% nearly neutral is left alone.
  The render's three channels take the primaries of `render_primaries`
  (srgb, display_p3, adobe_rgb, rec2020; `processing/rgb_space.zig`): how
  saturated the film's colours can come out. The default, `auto`, is
  Rec. 2020 on macOS, the only one of them holding the ET-8500's glossy
  papers' gamut (they pass Display P3 in yellow and from cyan to blue,
  Adobe RGB in yellow and blue, measured through Epson's profiles), and
  sRGB elsewhere. Exposure, white balance, and colour contrast measure luminance and
  Oklab in that space; exports are written in it, 16-bit with the sRGB
  curve, and embed its ICC profile (`processing/icc.zig`, Little CMS);
  print copies get sRGB, colours beyond it brought in at the same Oklab
  lightness and hue. On macOS the UI's renderer draws in extended linear
  sRGB (Metal's half-float layer, which ColorSync shows across a Display P3
  panel; `ui/chrome.zig` createRenderer): the Frame view's preview and soft
  proof, and the gallery's wide exports (through their embedded profile),
  fill Display P3 the same way, as half-float textures; the Strip view's
  preview and the UI's own colours stay sRGB. Elsewhere, or when the
  renderer refuses, every screen image is sRGB.
  Scene contrast is kept, not stretched per frame. A frame crop's white
  balance and exposure are measured on its inner 95% each way, clear of
  film-border slivers. Formulas: `docs/RENDER_TRANSFORM_CLOSED_FORM.md`.
- Colour contrast (`color_contrast`, off unless true: the Frame view's
  "Color contrast", `processing export --color-contrast on`; roll exports
  follow it) is the render's last step, on display light before it is
  quantized (`processing/chroma.zig`). Each image's colourful objects are
  fitted as up to twelve families in Oklab a,b, on a copy of the measured
  region 256 px on its long side (each pixel the mean of 2x2 points):
  three passes of edge-preserving smoothing (7x7, range 0.03 in Oklab)
  average colours within objects but not across their edges; a pixel counts
  by the square of its chroma (over 0.05) plus the square of its a,b
  distance from its surround (a box mean a tenth of the long side each way,
  over 0.03), so families sit on colourful objects, and on small ones
  unlike their setting (brown hair against rock and sky), rather than a
  frame's near-grey general tones; and only if it lies in a patch of its
  colour at least 2x2 pixels across, so lone specks count for nothing.
  Families are peaks of that histogram (smoothed 0.012) at chroma 0.034 or
  more, down to 1% of the tallest (a hillside's fireweed came to 1.5%). `color_contrast_families` (default 12) keeps only the tallest.
  A colour belongs to a family by a Gaussian of its distance from the
  centre (sigma 0.044), shared out only where families overlap. Its chroma
  grows along its own hue by the share it belongs (`color_contrast_boost`
  0.3), it is pulled toward the family's centre in hue and chroma
  (`color_cohesion_hue` 0.7, `color_cohesion_chroma` 0.55), and inside a
  core about the centre (`color_contrast_radius` 0.025, shrunk to clear
  neighbouring families and the greys) chroma differences grow
  (`color_contrast_gain` 0.4), at constant hue and lightness. Greys stay
  neutral: the boost and the pull fade in with a colour's own chroma, from
  nothing at 0.015 to full at 0.04, and the boost never moves a colour
  toward another hue, so toggling colour contrast leaves a frame's white
  balance alone. With a colourfulness target (`color_contrast_target`, 0 =
  off: the 90th percentile of the frame's chroma), the filter measures its
  own output on the fitting image and bisects for the boost, between none
  and `color_contrast_boost`, that reaches it: a muted frame gets up to the
  boost, an already colourful one none (it never takes colour away).
  Colours pushed out of gamut lose chroma at constant lightness. The math follows a browser prototype, except its boost and
  pull, which moved near-greys toward the families' hues (a cast);
  `test/fixtures/processing/chroma/` holds the prototype's output. The preview fits the whole strip, exports each frame.
- Film stocks are 3x10 quadratic polynomials in density space with basis
  `[R, G, B, R^2, G^2, B^2, RG, RB, GB, 1]`. See
  `docs/FILM_STOCK_PROFILES.md`.
- IR defects: threshold, dilate/close, coverage cap, inpaint. Inpainting
  fills each defect with a biharmonic fill of the picture (a low-pass of
  the clean pixels around it) plus synthetic grain matched to the
  surround's level and spectrum. The fills' linear systems are solved
  directly by our own solver (`processing/fill_solver.zig`): nested
  dissection on the pixel grid, then multifrontal LDL^T, or LU without
  pivoting for fills by the image edge, whose reflected stencils are not
  symmetric.
- Newton's rings: exports of scans with IR check each frame
  (`processing/newton_rings.zig`; `processing rings` runs it alone) and
  name frames with strong rings in the export message, the roll panel,
  `roll` output, and the review page. The check runs right after IR
  alignment, ahead of the frames, so while a roll scans its warning
  reaches the roll panel (kept until dismissed or the roll closes) and
  `roll scan` within seconds, while the strip may still be on the
  scanner. The narrow-band IR shows interference
  fringes wherever the film nears the glass, which is normal with the film
  flat on the bed, so the IR only says where to look. Visible rings, around
  a dust speck or where the film bows onto the glass, are the same gap seen
  at the dyes' wavelengths: red-minus-green density runs 1.3-1.8 cycles per
  IR fringe, which picture content does not. The check finds IR ring
  centres by radial symmetry over the whole frame, fits red-minus-green
  along rays from each as a sinusoid of a multiple of the IR fringe phase,
  and scores the variance explained at 1.3-1.8 above that 0.3 either side.
  Warns at 0.06. With the `reduce_newton_rings` setting (on unless set
  off: the Strip view's "Reduce Newton's rings", `processing export
  --reduce-rings`; roll exports follow it) the same pass, before any frame
  is written, subtracts the rings in density about every centre scoring at
  the warning level, in two passes. Each runs along 2048 rays: a local
  least-squares fit of each channel's density to a level, a gradient, and
  a sinusoid of the centre's ratio times the IR phase, kept where it beats
  chance (the residual over the window's independent pixels), at least
  0.29 mm from picture edges, clear of IR defects (dust and their
  shoulders), and within the IR phases where the rings show round the
  whole system (plus four fringes). Near a centre only steps across the
  radius count as edges, and steps by IR defects not at all: the speck
  holding the film off sits mid-rings. The coarse pass (the check's
  1067 dpi grid, a 0.29 mm window) takes the rings out to 6 mm; a fine pass
  at 3200 dpi (0.06 mm window, a stricter gate, fading out from 0.6 to
  1 mm), about the point the IR rings centre on, takes the middle of the
  system, whose rings are too fine for the coarse one. It runs only where
  the IR phase climbs steadily out from that point (0.92 of steps; small
  dust bullseyes reach 0.99): on irregular IR rings it adds rings. No
  high-pass first:
  its halos by edges read as rings. The score gate matters: run on every
  centre, or on centres just under the warning level, the fit takes
  picture (a cloud's texture) for rings. Sizes are in millimetres of film. Tune and judge
  both only on real scans, through real exports and their change maps,
  against the frames the owner reviewed (listed in `plan.md`), never on
  synthetic rings.
- Parameters are defined at 800 dpi. Linear parameters scale by
  `dpi / 800`, area parameters by `(dpi / 800)^2`, at the dpi of the image
  they act on: the defect mask's sizes by the IR page's dpi (6400 dpi RGB
  has a 3200 dpi IR pass), inpaint padding by the RGB's. Grain is told
  from the picture at a fixed 2.5 px: a wider low-pass takes picture edges
  for grain. The synthetic grain is one field shared by the channels,
  scaled to the surround's channel-mean grain: it errs toward too little
  colour, since colour noise shows where luma grain passes as film.
- At 2.5 px the fills' grain leaves out the coarser grain the eye sees at
  high dpi (2.5 px is 80 microns at 800 dpi, 10 at 6400), which left smooth
  patches. Above 800 dpi each fill also gets one octave of coarser grain
  per doubling (2.5-5, 5-10, 10-20 px at 6400): each octave's share of the
  fine grain is measured once per frame on the flattest of up to 256 tiles
  (flatness judged an octave coarser still, so the measured bands are not
  picked for being low), and synthesized from its own noise, weighted
  through the Gaussian bands' overlap so that measured the same way each
  comes out at its share. Near the surround's edges a plain standard
  deviation overstates grain, so the fill's fine grain is then measured
  from the median absolute deviation, and the grain follows the fill's own
  level (grain grows as transmittance to a power fitted per frame).
  Textured picture around a fill is not grain and is not reproduced.

### Config and files

- Two separate TOML configs, `scanner.toml` (in the scan folder) and
  `processing.toml`. Both are gitignored and generated at runtime.
  Saves merge into the existing file; go through the config layer, not raw
  TOML reads.
- Scans go to `scans/`, exports to `frames/`; both are gitignored. These and
  both configs resolve from the working directory; the macOS app bundle
  works in `~/Pictures/CerealGrain`, and `CEREALGRAIN_DATA_DIR` sets the
  folder. Started there without a terminal, the UI writes its stderr
  (scanner events, errors) to `logs/cerealgrain-<UTC time>.log`, keeping the
  last 20, for beta testers to send. A roll uses `scans/<roll>/`
  (`roll.json`, `roll.lut.bin`, `strip_NN_*.tiff`, hand-placed framing in
  `strip_NN_*.tiff.frames.json`, `review/`) and
  `frames/<roll>/<roll>_sNN_FF.tif`; the current roll is the `[roll]` key in
  the scanner config.
- The UI works on a loaded scan in two views. Strip: the scan as a whole
  (its frames, the rebate and Dmin, film stock, dust removal, exporting its
  frames). Frame: one frame at a time, its look (contrast, exposure,
  colour balance, colour contrast) previewed live: the frame cut from the
  strip preview and rendered as its export is (`ui/frame_view.zig`,
  `ui/frame_preview_worker.zig`), with Export This Frame. A frame's look is
  its own overrides of processing.toml's render settings, kept beside the
  scan by the frames' order in `<scan>.adjust.json`
  (`processing/frame_adjust.zig`); every export path applies them (the
  Strip and Frame views, `processing export`, roll exports), and a roll
  strip whose looks changed since its export counts as needing one.
  Built-in looks (`processing/looks.zig`, the Frame view's Preset buttons)
  are complete sets of those settings (unnamed ones at the built-in
  defaults, so a look does not depend on processing.toml): Pastel
  (highlights at 0.84, soft contrast, a warm cast, colour contrast with a
  0.052 colourfulness target), fitted to the colour signature of a
  reference photograph on the owner's frames, and Vivid (contrast 2.0,
  highlights at 0.90, crosstalk 0.25, colour contrast with a 0.085 target),
  chosen by the owner from renders. Applying one replaces the frame's own
  settings. A frame's Strength (`look_mix`, a frame setting only, 1 unless
  set) blends its own look with the default look
  (`workflow.mixLook`): settings that vary smoothly go part way;
  highlight placement moves exposure part way from the log-average's
  toward it (`highlight_mix`), and colour contrast the default lacks
  scales its boost, local contrast, and pulls up from none. Make Default
  saves the frame's look at its strength.
- Print copies: with the `print_size` and `print_dpi` processing settings
  (the Strip view's Export pulldowns, `processing export --print SIZE
  --print-dpi DPI`; roll exports follow them), each positive TIFF gets an
  8-bit sRGB JPEG beside it, `<tiff stem>_<size>_<dpi>dpi.jpg`, with its DPI
  in the JFIF header. The frame is fitted inside the print uncropped, turned
  like the frame, and area-averaged in linear light; never upscaled, so a
  frame with too few pixels keeps them at the DPI that fits. The copy takes
  the frame's true aspect, not its whole-pixel crop's, so exact-aspect frames
  give exact-aspect copies. Sizes are common lab prints and the paper Epson's
  EcoTank photo printers take; resolutions are 300 dpi (labs) and 360 or 720
  (Epson's printer drivers).
- Printing (macOS for now; `printing/`, the Frame view's Print section,
  `cerealgrain print file`): the app converts the frame to the printer's
  ICC profile for the chosen paper and sends CUPS raster to the queue,
  with the driver's own colour adjustment turned off (a PPD choice named
  for it, Epson's "Off (No Color Adjustment)"), so nothing converts the
  colours again. The UI exports the frame with its look first and prints
  that TIFF; any RGB TIFF prints through its embedded profile. The frame
  is laid out in linear Rec. 2020: fitted inside the print size uncropped
  (or filling it, trimmed), turned to the paper, resampled with a tent
  filter, converted with the chosen intent (relative colorimetric with
  black point compensation by default), and dithered to 8 bits. The page
  header follows what macOS's own PDF filter writes for the same choices
  (resolution, paper size, borderless overscan by
  cupsBorderlessScalingFactor, and what each choice's setpagedevice code
  sets, Epson's cupsCompression per resolution): `cupsfilter -m
  application/vnd.cups-raster` on any PDF shows it. The paper's profile
  defaults to the driver's that matches the paper's name; ColorSync's
  installed printer profiles are offered too. Soft proof previews the
  frame through the profile, optionally on the paper's own white.
  libcups is loaded at run time, so no build links it. Drivers that take
  no raster, or no 8-bit RGB, are refused. Never send a job to a real
  printer unless the owner asks; `--raster-out` and the smoke check
  without printing.
- TIFF metadata: make, model, software, resolution, datetime. Custom tag
  50000 marks scanner custom LUTs; BYTE tag 50001 holds the applied LUT,
  which the RGB loaders invert; tag 65000 holds export metadata JSON.
  Positives embed the ICC profile of the space they are in.
- macOS gamma LUTs clip clear areas by design (both points come from the
  film strip), so scans need clear margins for frame detection; auto-select
  adds 2 mm per side.

## Conventions

- Zig 0.16 `std.Io` style. Tests live in `test` blocks next to the code;
  fixture-backed tests load JSON from `test/fixtures/`.
- Comments only where intent is not obvious from the code.
- Validate at system boundaries (CLI args, files, scanner output); no
  defensive checks on internal calls.
- The version is the commit: build.zig reads git's short hash, with
  `-dirty` for uncommitted changes to tracked files, on every build
  (`cerealgrain version`, the window title, the probe output, and every
  TIFF's Software tag). Nix builds pass `-Dversion`. Nothing is bumped by
  hand.
- Licenses: ours is MIT (`LICENSE`); `third_party/` holds the license texts
  of every library the macOS app and the static CLI ship, indexed in its
  README. A newly shipped library needs its license there, and
  `zig build app-bundle` fails until `license_dir` in
  `scripts/macos_app_bundle.sh` maps it.

## Docs

- `plan.md`: current state, decisions, backlog.
- `docs/PYTHON_PORT_MAP.md`: where each Python function landed in Zig
  (historical).
- `docs/PERFORMANCE_STRATEGY.md`: optimization policy and current numbers.
- `docs/CROSS_PLATFORM.md`: platform support and the macOS/Windows plans.
- `docs/SCANNER_INTERNALS.md`: ESC/I protocol, interpreter ABI, TPU
  calibration, IR, gamma LUTs, epkowa patches.
- `docs/TIFF_STRATEGY.md`, `docs/FILM_STOCK_PROFILES.md`,
  `docs/RENDER_TRANSFORM_CLOSED_FORM.md`, `docs/NATIVE_UI_VERIFICATION.md`.
