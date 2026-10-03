Small JSON numeric oracle fixtures for floating-point parity tests.

Each fixture records:

- the operation under test;
- the frozen Python oracle source or generation note;
- the exact command or script description used to create the values;
- the input tensor shape;
- optional `expected_shape` when an operation reduces or expands the data;
- absolute and relative tolerances plus the reason for those tolerances;
- flat row-major `input` and `expected` arrays.

Use these fixtures for small deterministic arrays. Large image data should stay
outside git unless explicitly approved.

`real-scan-negative-to-positive-scan-0006-crop.json` stores only an 8x8 RGB
crop sampled from local `scans/scan_0006_rgbir_800dpi.tiff`; it does not commit
the scanner TIFF. It pins the raw-negative to rendered-positive path: the
Python inversion (Dmin and the Python Gold profile) and, since the display
transform was replaced, the Zig render's output. The `render-to-display-*`
fixtures likewise keep their Python inputs with expected values from the
current Zig display transform.
