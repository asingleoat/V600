# Zig TIFF Strategy

The rewrite will use libtiff through Nix for native TIFF reading, metadata
inspection, page loading, and export writing. We will not write a custom TIFF
parser.

## Decision

- Use libtiff as the native TIFF backend for Zig.
- Add libtiff to build/check/package inputs when Zig code first imports or
  links it. It is already present in the development shell.
- Keep scanner-produced TIFF pass-through simple until native TIFF wrappers are
  in place.
- Treat ImageMagick, `tiffcp`, `tiffset`, and ExifTool in the current scanner
  runtime as transitional tools. They are acceptable for early scanner parity,
  but Phase 2 should replace page composition, metadata reads, and metadata
  writes with libtiff-backed code where practical.
- Support both classic TIFF and BigTIFF. Use BigTIFF for writes when projected
  image data can exceed the classic 4 GiB limit.

## Python Oracle

Primary Python references:

- `scratchndent/utils/io.py:read_tiff_dpi`
- `scratchndent/utils/io.py:write_tiff`
- `scratchndent/utils/io.py:load_tiff_pages`
- `scratchndent/utils/io.py:find_images`
- `scratchndent/utils/io.py:generate_unique_path`
- `scanner.py:_tiff_metadata`
- `scanner.py:_save_image`
- `v600/core/backends/sane.py:_tiff_metadata`
- `v600/core/backends/sane.py:_save_image`
- `v600/gui/process_handlers.py` TIFF page loading behavior
- `v600/gui/scan_handlers.py` RGB+IR multi-page write behavior

## Required Semantics

- `read_tiff_dpi` reads page 0 `XResolution` and returns integer DPI when
  numerator and denominator are present and denominator is nonzero.
- Missing, malformed, or unreadable DPI metadata returns `null`, matching the
  Python `None` fallback.
- RGB+IR scanner files preserve page 0 as RGB and page 2 as IR. Page 1 may be
  a thumbnail and should not be treated as IR.
- Single-page TIFFs load RGB from page 0 and return no IR page.
- Do not assume RGB and IR pages have identical geometry or bit depth.
- Preserve standard scanner metadata tags: Make, Model, Software,
  X/YResolution, ResolutionUnit, DateTime, and custom LUT marker behavior.
- Preserve export metadata behavior: non-standard metadata is serialized as
  JSON in private extratag `65000`.
- Default writes should be uncompressed unless Python-oracle evidence says a
  specific path uses compression.

## Implementation Direction

Create a small Zig TIFF wrapper rather than exposing libtiff calls throughout
the application. The wrapper should own these responsibilities:

- Open/close TIFF files safely.
- Enumerate pages/directories.
- Read page dimensions, samples per pixel, bits per sample, sample format,
  photometric interpretation, planar configuration, orientation, and resolution.
- Read page pixels into typed buffers used by processing code.
- Read page 0 DPI with Python-compatible fallback behavior.
- Load `(rgb, ir)` using the page 0/page 2 convention.
- Write scanner/export TIFFs with standard tags and private metadata tags.
- Select BigTIFF for large output.

Keep image-processing code independent from libtiff handles. It should consume
plain Zig buffers and metadata structs.

## Nix Direction

When the first native TIFF wrapper lands:

- Add `pkgs.libtiff` to package build inputs, not only the dev shell.
- Add `pkgs.pkg-config` if using pkg-config for include/link flags.
- Keep `pkgs.imagemagick` in checks while scanner mirror/thumbnail transition
  tests still use it. ExifTool is no longer required for scanner metadata
  writing now that native private tags are covered by libtiff tests.
- Ensure `nix flake check path:.` exercises libtiff-backed tests without
  scanner hardware.

## Test Plan

Use small committed TIFF fixtures only. Do not commit full-resolution scanner
outputs.

Required headless tests:

- DPI read: normal rational, missing tag, zero denominator or malformed tag.
- Page loading: single-page RGB, three-page RGB/thumbnail/IR, and RGB/IR pages
  with different dimensions.
- Metadata read/write: Make, Model, Software, X/YResolution, ResolutionUnit,
  DateTime tolerance if dynamic, custom LUT marker, and extratag `65000`.
- Scanner metadata integration should prefer `src/tiff.zig:writeScannerMetadata`
  over shelling out to `tiffset` or ExifTool.
- Pixel loading: 8-bit gray, 8-bit RGB, 16-bit gray, 16-bit RGB.
- Unique path and image discovery remain filesystem tests, not libtiff tests.

Fixture generation should record the Python `tifffile` command used to create
the oracle file and the expected metadata/page observations.

Current committed page-layout fixture:

- `test/fixtures/tiff/rgb-thumb-ir.tiff`
- `test/fixtures/tiff/rgb-thumb-ir.json`

This fixture is generated with Python `tifffile` and observed through
`scratchndent.utils.io.load_tiff_pages`/`read_tiff_dpi`. It covers 16-bit RGB
page 0, ignored 8-bit RGB thumbnail page 1, and 8-bit grayscale IR page 2.

Current committed export-metadata fixture:

- `test/fixtures/tiff/export-metadata.tiff`
- `test/fixtures/tiff/export-metadata.json`

This fixture is generated through Python `scratchndent.utils.io.write_tiff`
with representative `process_frame` metadata. Zig must preserve and inspect
the exact private ASCII tag `65000` JSON before any native export pipeline can
claim metadata parity.
