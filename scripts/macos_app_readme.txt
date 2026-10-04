V600 (beta)

Scans and processes colour negative film on an Epson Perfection V600:
scanning with infrared dust removal, frame detection, inversion, and export.

What you need
- A Mac with Apple silicon (M1 or later) on macOS 14 Sonoma or later.
- Epson's own Mac software for the Perfection V600 (Epson Scan 2, or Epson's
  scanner driver), installed from Epson's support site. V600 drives the
  scanner through Epson's driver plugin, which it does not include.

First launch
1. Move V600.app to Applications.
2. Open it. The app is not signed by a registered developer, so macOS will
   refuse the first time.
3. Open System Settings > Privacy & Security, scroll down, click "Open
   Anyway" next to V600, and confirm. (On macOS 14 you can instead
   Control-click the app, choose Open, and confirm.)

Where your files go
Everything lives in the Pictures folder under V600:
- scans/   the scans, as 16-bit TIFFs (rolls get a folder each)
- frames/  exported frames
- two .toml settings files

If the scanner will not open
Quit Epson Scan 2 and any Epson Scanner Monitor running in the menu bar or
in Activity Monitor; only one program can use the scanner at a time.

This is a beta. Please send problems, odd results, and crashes to whoever
gave you this app, with the steps that led there.
