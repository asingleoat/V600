# TIFF Fixtures

These fixtures pin Python `scratchndent.utils.io` TIFF semantics for the Zig
port. They are intentionally tiny and should stay committed.

`rgb-thumb-ir.tiff` was generated with Python `tifffile` in the Nix shell:

```python
from pathlib import Path
import numpy as np
import tifffile

path = Path("test/fixtures/tiff/rgb-thumb-ir.tiff")
rgb = np.array([
    [[1000, 1001, 1002], [1010, 1011, 1012]],
    [[1020, 1021, 1022], [1030, 1031, 1032]],
], dtype=np.uint16)
thumb = np.array([[[9, 8, 7], [6, 5, 4]]], dtype=np.uint8)
ir = np.array([[31, 32, 33], [34, 35, 36]], dtype=np.uint8)

with tifffile.TiffWriter(path, bigtiff=False) as tif:
    tif.write(rgb, photometric="rgb", planarconfig="CONTIG",
              compression=None, resolution=(800, 800),
              resolutionunit="INCH", metadata=None, description=None)
    tif.write(thumb, photometric="rgb", planarconfig="CONTIG",
              compression=None, metadata=None, description=None)
    tif.write(ir, photometric="minisblack",
              compression=None, metadata=None, description=None)
```

The expected observations are recorded in `rgb-thumb-ir.json`. Python
`load_tiff_pages` returns page 0 as RGB, page 2 as IR, and ignores page 1.

`export-metadata.tiff` was generated through Python
`scratchndent.utils.io.write_tiff` with representative `process_frame` export
metadata. Its private ASCII tag `65000` is recorded in
`export-metadata.json` and should remain byte-for-byte compatible with
Python's `json.dumps` output.

`scanner-lut.tiff` is a 36 x 1 RGB16 page carrying a scanner gamma LUT in
private BYTE tag `50001`, written with Python `tifffile` from
`scanner-lut-linearize.json`:

```python
tifffile.imwrite(path, rgb, photometric="rgb", resolution=(800, 800),
                 resolutionunit="inch",
                 extratags=[(50001, "B", 768, bytes(fixture["lut"]), True)])
```

`scanner-lut-linearize.json` holds the LUT, raw samples per channel, and the
linearized values computed with `numpy.interp` over the LUT's rising knots
(knot k at sensor value 256 k and output 257 lut[k], scaled so the white knot
is 65535). Both `src/tiff.zig` and `web/tiff.mjs` must match it to within 1.
