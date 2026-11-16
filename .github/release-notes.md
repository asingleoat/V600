A beta of CerealGrain for testers with Epson film scanners. It scans
colour negatives through the transparency unit with infrared dust
removal, finds the frames, inverts them, and exports 16-bit TIFFs, plus
print-sized JPEGs if you ask for them.

## New in v0.1.0

- **Frame view.** Processing is split in two: the Strip view handles the
  scan as a whole (frames, film base, dust and Newton's rings, export),
  and the new Frame view edits one frame's look with a live preview. Each
  frame can have its own look, kept beside the scan and used by every
  export.
- **Looks.** Pastel (now the default: soft contrast, highlights held off
  white, gentle colour), Vivid (richer colour, a little more contrast),
  and Standard (the plain render, the old default). A Strength slider
  blends a frame's look with the default when a preset is the right idea
  but too strong.
- **Colour contrast.** Finds each frame's colourful objects (skin, sky,
  foliage) and spreads their shades apart, aiming for a set
  colourfulness, so muted frames gain colour and colourful ones are left
  alone. Greys stay neutral.
- **Better white balance.** A second pass finds the frame's nearly
  neutral surfaces and takes their remaining colour cast out.
- **Wide gamut.** On the Mac, frames render in Rec. 2020, wide enough for
  a photo printer's colours, and exported TIFFs carry their ICC profile.
  The Frame view and gallery show the full range of a Display P3 screen.
- **Colour-managed printing (Mac).** Print a frame straight from the
  Frame view: CerealGrain converts it with the ICC profile for your
  printer and paper (Epson's own, picked to match the paper) and turns
  the driver's colour adjustment off, with a soft proof to preview the
  print on screen. Built for Epson's EcoTank photo printers; other
  printers whose drivers take raster pages should work too. Also from the
  command line: `cerealgrain print`.

## Downloads

- **CerealGrain-…-macos-arm64.dmg**: the Mac app, for Apple silicon (M1 or
  later) on macOS 14 or later. Open it, drag CerealGrain onto Applications,
  and read `Read Me.txt` beside it first.
- **cerealgrain-linux-x86_64-static.tar.gz**: the command-line tool for any
  x86-64 Linux. Processing and export work anywhere; scanning needs SANE
  with the patched epkowa backend (`nixos/` in this repository).

## First launch on a Mac

The app is not signed by a registered Apple developer, so macOS will not
open it until you allow it once:

1. Open the disk image and drag CerealGrain onto Applications.
2. Open CerealGrain. macOS refuses, saying it could not verify the app.
   Click **Done**, not Move to Trash.
3. Open System Settings > Privacy & Security and scroll down to Security,
   where it says CerealGrain was blocked. Click **Open Anyway** and enter
   your password.
4. Open CerealGrain again and click **Open Anyway** when asked. After that
   it opens normally.

Or, in Terminal, before the first launch:

    xattr -dr com.apple.quarantine /Applications/CerealGrain.app

Most scanners also need Epson's own Mac software for the scanner (Epson
Scan 2), from Epson's support site. The V700 and V750 do not.

## Which scanners

Only the Perfection V600 has been tested. CerealGrain also knows the
V550, V700/V750, V800/V850, V500, V370/V37, V330/V33, 4990, 4870, 4490,
and GT-X970, none of them tried yet. If you have one, please try, in this
order, and say how each step went:

1. Reconnect Scanner in the Scan view, then Preview.
2. A strip in RGB at 800 dpi, then RGB + IR at 800 dpi.
3. Higher resolutions: 1600, 3200, and 6400 dpi.

## Reporting a problem

Send the steps that led there, the version from the window's title bar
(a short code), the newest log in `Pictures/CerealGrain/logs`, and what
this prints in Terminal with the scanner on and CerealGrain closed:

    /Applications/CerealGrain.app/Contents/MacOS/cerealgrain scanner probe

Open an issue on this repository, or send it to whoever pointed you here.
