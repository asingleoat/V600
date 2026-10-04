CerealGrain (beta)

Scans and processes colour negative film on Epson Perfection film scanners:
scanning with infrared dust removal, frame detection, inversion, and export.

What you need
- A Mac with Apple silicon (M1 or later) on macOS 14 Sonoma or later.
- Epson's own Mac software for your scanner (Epson Scan 2, or Epson's
  scanner driver), installed from Epson's support site. CerealGrain drives
  most models through Epson's driver plugin, which it does not include.

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
- frames/  exported frames
- two .toml settings files

Scanners other than the V600
CerealGrain has only been tested on a Perfection V600. It also knows the
V550, V800/V850, V700/V750, V500, V370/V37, V330/V33, 4990, 4870, 4490, and
GT-X970, but none of them has been tried yet. If you have one, please
report how scanning went, and include what this prints: with the scanner on
and CerealGrain closed, open Terminal, paste this line, and press Return:

  /Applications/CerealGrain.app/Contents/MacOS/cerealgrain scanner probe

Scanners without an infrared channel (the V370 and V330, for example) have
the RGB + IR and IR modes turned off, and so no dust removal.

If the scanner will not open
Quit Epson Scan 2 and any Epson Scanner Monitor running in the menu bar or
in Activity Monitor; only one program can use the scanner at a time.

This is a beta. Please send problems, odd results, and crashes to whoever
gave you this app, with the steps that led there.
