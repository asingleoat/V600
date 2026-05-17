Export pipeline fixtures.

`process-frame-scan-0006-patch.json` is generated from the frozen Python
`scratchndent.export.process_frame` path using a compact RGB patch from
`scans/scan_0006_rgbir_800dpi.tiff`. The fixture commits the source patch, so
the Zig test does not require the gitignored scan file at runtime.

The fixture exercises the Python `aligned_ir is None` fallback with all three
output variants enabled: `ir_neg`, `ir_inv`, and `inv_only`. The raw negative
TIFF is expected to match exactly. The inverted outputs use the existing
render-pipeline tolerance of +/-2 uint16 code values because the lower-level
real-scan inversion fixture already admits that numeric tolerance.
