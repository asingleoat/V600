# TIFF Handling

Native TIFF I/O goes through libtiff, wrapped by `src/tiff.zig`; there is no
custom TIFF parser. Processing code works on plain Zig buffers and never sees
libtiff handles. The browser has its own small reader/writer in
`web/tiff.mjs`, because libtiff is not available in the Wasm build.

## Semantics

These follow the Python `scratchndent/utils/io.py` (`read_tiff_dpi`,
`load_tiff_pages`, `write_tiff`, `find_images`, `generate_unique_path`) and
the scanner `_tiff_metadata` helpers.

- `readDpi` reads page 0 `XResolution` and returns integer dpi, or `null`
  when the tag is missing, malformed, or has a zero denominator.
- Scanner RGB+IR files: page 0 is RGB, page 2 is IR, page 1 may be a
  thumbnail and is never IR. Single-page files have no IR. RGB and IR pages
  can differ in size and bit depth.
- Scanner metadata: Make, Model, Software, X/YResolution, ResolutionUnit,
  DateTime (`writeScannerMetadata`). Tag 50000 marks custom scanner LUTs; on
  Linux it is currently set even though the LUTs are not applied (see
  `plan.md`).
- Scanner gamma LUT: private BYTE tag 50001 on the RGB page holds the
  768-byte LUT (R, G, B) the scanner applied, written by the macOS backend.
  The RGB page loaders invert it (`linearizeRgb16`, mirrored in
  `web/tiff.mjs`), so processing always sees linear data. Without the tag
  the data is used as is.
- Export metadata is JSON in private ASCII tag 65000
  (`readExportMetadataJson`).
- Exported frames are lossless Deflate (level 6, horizontal predictor, 4 MiB
  strips; 8- and 16-bit strips are compressed on all cores with libdeflate
  and handed to libtiff raw), about 20-30% smaller than raw, and carry the
  scan's resolution and DateTime (`readDateTime`). Scans and other writes are
  uncompressed; the webapp's `tiff.mjs` reads only uncompressed files, so it
  opens scans but not native exports. `writeImage` can write BigTIFF, but no
  caller enables it, so exports over 4 GiB would fail. `writeScanPages`
  (macOS scans) switches to BigTIFF past about 3.75 GiB and writes 4 MiB
  strips.
- `findImages` and `generateUniquePath` handle directory listing and
  collision-free export names.

## Remaining shell-outs

The Linux scan runtime still uses external tools for three steps:
ImageMagick `magick` for the RGB+IR thumbnail page and for the horizontal TPU
mirror, and `tiffcp` to combine the RGB, thumbnail, and IR pages
(`src/scanner/linux.zig`). All three could move to libtiff.

## Fixtures

- `test/fixtures/tiff/rgb-thumb-ir.tiff` and `.json`: 16-bit RGB page 0,
  8-bit thumbnail page 1, 8-bit IR page 2, written with Python `tifffile` and
  read back with `load_tiff_pages`/`read_tiff_dpi`.
- `test/fixtures/tiff/export-metadata.tiff` and `.json`: written by Python
  `write_tiff` with representative `process_frame` metadata in tag 65000.
