# Native UI verification notes

The SDL3/Nuklear UI must keep a clear split between automated headless checks
and manual real-window inspection. Headless checks are required for every native
UI checkpoint, but they do not replace a human screenshot pass on a real display.

## Ambient shell rule

Run these commands from the conversation's ambient nix shell. Do not run
`nix develop`, `nix-shell`, `nix build`, or `nix flake check` for routine UI
checks. If a dependency is missing, stop and ask for the shell or `flake.nix` to
be updated.

## Headless gates

Use direct Zig commands:

```sh
zig build test --summary all
zig build -Dui=true --summary all
env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true ui-smoke --summary all
env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true --summary all run-ui -- --preview-render-smoke
env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true --summary all run-ui -- --gallery-render-smoke
env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true --summary all run-ui -- --gallery-interaction-smoke
env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true --summary all run-ui -- --gallery-shortcut-smoke
env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software zig build -Dui=true --summary all run-ui -- --gallery-confirm-smoke
env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software V600_UI_THEME=graphite V600_UI_SCALE=1.45 zig build -Dui=true run-ui -- --process-render-smoke
```

These prove that the UI executable builds, one frame can render through SDL
dummy, Nuklear draw commands produce non-background pixels, preview/gallery
textures can be created from fixture data, and gallery interaction handlers
execute without a display.

They do not prove real-window readability, OS compositor behavior, actual
pointer feel, monitor scaling, or whether controls visually overlap at common
desktop sizes.

## Recent cache verification

2026-05-20 native Process result-cache work used the same direct UI gates:

```sh
zig build -Dui=true --summary all
SDL_VIDEODRIVER=dummy zig build -Dui=true run-ui -- --process-render-smoke
```

The Process render smoke exercises the async inverted-preview path with
`preview_inversion` enabled, so the semantic inverted-preview RGB8 cache is
compiled through the SDL texture layer while the smoke still waits for an
inverted texture before passing.

## Manual window pass

Launch the real UI from the ambient shell:

```sh
zig build -Dui=true run-ui
```

Capture screenshots with the desktop screenshot tool already available in the
session. Do not add a screenshot dependency just for this check.

Theme and scale can be exercised without changing source:

```sh
V600_UI_THEME=lighttable V600_UI_SCALE=1.35 zig build -Dui=true run-ui
zig build -Dui=true run-ui -- --ui-theme graphite --ui-scale 1.45
```

Valid theme names are `darkroom`, `lighttable`, and `graphite`.

Required screenshots:

- Scan view at the default window size.
- Scan view at `--ui-scale 1.0` and `--ui-scale 1.45`.
- Scan view after resizing narrower and wider.
- Process view with enough vertical space for the full control panel.
- Process view constrained to a shorter window where scrolling is actually
  required.
- Gallery view with at least two exported TIFFs in `frames/`.
- Gallery confirmation prompt for Trash.
- Gallery confirmation prompt for Delete.
- Gallery view after wheel zoom and middle-button pan.
- Footer status bar in Scan, Process while a worker/export is active, and
  Gallery.

Required manual checks:

- Top navigation switches between Scan, Process, and Gallery.
- Text fits inside the Nuklear window at default scale, `1.0`, and `1.45`.
- Scan controls remain readable and do not overlap the preview image.
- The footer stays pinned to the bottom of the SDL window, the control panel is
  constrained above it, and status/progress text is not duplicated in the tab
  bodies.
- Control-panel scrollbars are absent when the active view content fits inside
  the parent window and appear only when the panel is constrained by window
  height or long image/selection lists.
- Wheel input over the image area zooms/pans only the image; wheel input over
  the footer does not scroll the control panel; wheel input over the control
  panel scrolls the panel only when the panel needs scrolling.
- Gallery thumbnails show real exported image content, not blank placeholders.
- The active gallery thumbnail is visually distinguishable.
- Trash/Delete do not mutate files before Confirm.
- Cancel leaves the gallery file list unchanged.
- ArrowLeft and ArrowRight wrap gallery selection.
- Delete and Backspace request trash confirmation.
- Wheel zooms around the cursor, middle-button drag pans, double-click refits,
  and resizing refits.

Record the date, OS/display environment, commands run, screenshot paths, and any
visual defects in `plan.md` under the checkpoint that required the manual pass.

## Current status

As of 2026-05-19, the native UI has headless SDL dummy verification for preview,
Process, gallery, theme, scale, and footer status-bar paths. A partial
real-display screenshot pass was captured through the local LightDM/Xorg
session at `DISPLAY=:0`; see `plan.md` for the exact screenshot paths and
findings. Release acceptance is still pending because the current automated X
session kept the SDL window at `1918x2158` despite resize requests, so the
required narrower/wider resized-window screenshots and manual pointer-feel
checks still need to be completed from a graphical session that permits window
resizing.
