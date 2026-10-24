A beta of CerealGrain for testers with Epson film scanners. It scans
colour negatives through the transparency unit with infrared dust
removal, finds the frames, inverts them, and exports 16-bit TIFFs, plus
print-sized JPEGs if you ask for them.

## Downloads

- **CerealGrain-…-macos-arm64.dmg**: the Mac app, for Apple silicon (M1 or
  later) on macOS 14 or later. Open it, drag CerealGrain onto Applications,
  and read `Read Me.txt` beside it first.
- **cerealgrain-linux-x86_64-static.tar.gz**: the command-line tool for any
  x86-64 Linux. Processing and export work anywhere; scanning needs SANE
  with the patched epkowa backend (`nixos/` in this repository).

## First launch on a Mac

The app is not signed by a registered Apple developer, so macOS refuses
it the first time. Open System Settings > Privacy & Security, click
"Open Anyway" next to CerealGrain, and confirm.

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
