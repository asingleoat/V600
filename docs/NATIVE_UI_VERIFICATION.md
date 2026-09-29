# Native UI Verification

How to check the SDL3/Nuklear UI. Headless smokes catch crashes and blank
renders; they do not replace looking at the real window.

## Headless smokes

Build steps (run with `-Dui=true`): `ui-smoke`, `native-scanner-connect-smoke`,
`native-process-worker-smoke`, `native-process-dump-smoke`,
`native-process-export-smoke`, `native-roll-smoke` (opening a roll points
the Scan and Process views at it), and the hardware-skip checks
`native-preview-worker-smoke-skip`, `native-scan-worker-smoke-skip`,
`native-roll-strip-smoke-skip`.

With the scanner connected, `V600_HARDWARE_SMOKE=1 v600-ui --roll-strip-smoke`
clicks Scan Strip in a temporary 800 dpi roll and waits until the strip is
exported.

More smoke modes exist as `v600-ui` flags but are not build steps:

```sh
env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software \
  zig build -Dui=true run-ui -- --process-render-smoke
```

Other flags: `--preview-render-smoke`, `--scan-interaction-smoke`,
`--process-interaction-smoke`, `--process-selector-smoke`,
`--process-confirm-smoke`, `--process-worker-screenshot-smoke`,
`--gallery-render-smoke`, `--gallery-interaction-smoke`,
`--gallery-shortcut-smoke`, `--gallery-confirm-smoke`,
`--gallery-trash-prompt-smoke`, `--gallery-delete-prompt-smoke`.

Add `--screenshot PATH` to any smoke to save the last rendered frame as a
BMP, for looking at a change without a display.

These show that the UI builds, a frame renders through the SDL dummy driver
with non-background pixels, preview and gallery textures load from fixture
data, and interaction handlers run. They do not show readability, pointer
feel, monitor scaling, or overlapping controls.

## Manual pass

```sh
zig build -Dui=true run-ui
V600_UI_THEME=lighttable V600_UI_SCALE=1.35 zig build -Dui=true run-ui
zig build -Dui=true run-ui -- --ui-theme graphite --ui-scale 1.45
```

Themes: `darkroom`, `lighttable`, `graphite`.

Look at:

- Scan, Process, and Gallery at the default size, at scale `1.0` and `1.45`,
  and after resizing narrower, wider, and shorter.
- Gallery with at least two exports in `frames/`, including the Trash and
  Delete confirmations and wheel zoom plus middle-button pan.
- The footer status bar in each view, including Process while a worker or
  export is running.

Check that:

- Top navigation switches views; text fits at every scale; scan controls do
  not cover the preview.
- The footer stays at the bottom, the control panel sits above it, and
  status text is not repeated in the view bodies.
- Control-panel scrollbars appear only when the panel is actually
  constrained.
- Wheel over the image zooms or pans only the image; wheel over the footer
  does nothing; wheel over the panel scrolls it only when needed.
- Gallery thumbnails show real content and the active one stands out.
- Trash and Delete change nothing before Confirm; Cancel leaves the list
  unchanged.
- ArrowLeft/ArrowRight wrap the gallery selection; Delete and Backspace ask
  to trash.
- Wheel zooms around the cursor, middle-drag pans, double-click and resizing
  refit.

## Status

On 2026-05-23 an agent captured screenshots of these views on the Linux
desktop (xmonad, which tiles windows, so requested window sizes were not
honored) and judged them free of obvious overlap or layout defects. No owner-reviewed
pass against this checklist is recorded.
