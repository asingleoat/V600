CerealGrain (beta)

Scans and processes colour negative film on Epson Perfection film scanners:
scanning with infrared dust removal, frame detection, inversion, and export.

What you need
- A Mac with Apple silicon (M1 or later) on macOS 14 Sonoma or later.
- For most models, Epson's own Mac software for your scanner (Epson Scan 2,
  or Epson's scanner driver), installed from Epson's support site.
  CerealGrain drives these models through Epson's driver plugin, which it
  does not include. The V700 and V750 are the exception: CerealGrain talks
  to them directly and needs no Epson software.

First launch
1. Move CerealGrain.app to Applications.
2. Open it. The app is not signed by a registered developer, so macOS will
   refuse the first time.
3. Open System Settings > Privacy & Security, scroll down, click "Open
   Anyway" next to CerealGrain, and confirm. (On macOS 14 you can instead
   Control-click the app, choose Open, and confirm.)

Where your files go
Everything lives in the Pictures folder under CerealGrain:
- scans/   the scans, as 16-bit TIFFs (rolls get a folder each)
- frames/  exported frames, plus print-sized JPEGs when you pick a print
           size under Export
- logs/    a log of each launch (the last 20), to send with a report
- two .toml settings files

Scanning a roll
In the Scan view, Start Roll names the roll and sets its film and format;
strips scan at the Mode and DPI chosen below it. Scan Strip then previews,
finds the strip on the preview, and scans it as the roll's next strip;
finished strips export in the background to frames/<roll>/. Open Review
shows them.

Holders with several strips (V700, V750, V800, V850)
Scan Strip finds one strip per preview, the largest. To scan a holder full
of strips: Start Roll, click Preview once, draw a rectangle around one strip
on the preview, and click Scan Selection; then draw around the next strip
and click Scan Selection again, without a new preview.

Exported frames are turned for strips loaded as in the V600's holder. If
yours come out turned the wrong way, open the strip in the Process view,
pick the right Rotate for its frames, and click Export Strip Frames. For a
whole roll, set "rotation" (0, 90, 180, or 270 degrees clockwise) in
scans/<roll>/roll.json with CerealGrain closed, before scanning.

Scanners other than the V600
CerealGrain has only been tested on a Perfection V600. It also knows the
V550, V800/V850, V700/V750, V500, V370/V37, V330/V33, 4990, 4870, 4490, and
GT-X970, but none of them has been tried yet; the V700 and V750, which
CerealGrain talks to without Epson's plugin, least of all. If you have one,
please try, in this order, and report how each step went:
1. Reconnect Scanner in the Scan view, then Preview.
2. A strip in RGB at 800 dpi, then RGB + IR at 800 dpi.
3. Higher resolutions: 1600, 3200, and 6400 dpi.

With each report, include the newest file in Pictures/CerealGrain/logs,
and what this prints: with the scanner on and CerealGrain closed, open
Terminal, paste this line, and press Return:

  /Applications/CerealGrain.app/Contents/MacOS/cerealgrain scanner probe

Scanners without an infrared channel (the V370 and V330, for example) have
the RGB + IR and IR modes turned off, and so no dust removal.

If the scanner will not open
Quit Epson Scan 2 and any Epson Scanner Monitor running in the menu bar or
in Activity Monitor; only one program can use the scanner at a time.

This is a beta. Please send problems, odd results, and crashes to whoever
gave you this app, with the steps that led there and the newest log. Find
the version to give in the window's title bar (a short code such as
3f2a9c1).

Licenses
CerealGrain is free software under the MIT license. It includes libraries by
others under their own licenses; the Licenses folder has them all, and
Licenses/README.md says which is which.
