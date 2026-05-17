IR processing fixtures.

The alignment fixtures keep only compact IR and expected aligned arrays.
Tests reconstruct matching RGB inputs from the deterministic pattern used to
generate the Python oracle values, then verify 1:2 and 1:4 RGB:IR scale cases
through Python's OpenCV ECC translation path and SciPy reflect/bilinear final
shift.

`meijering-line-detection-smoke.json` covers the line/hair branch from
`make_defect_mask`: OpenCV area downscale, 99.9 percentile normalization,
`skimage.filters.meijering(sigmas=range(1, 9), black_ridges=False)`, nearest
upsampling, and the final sigma gate.

`estimate-local-grain-smoke.json` covers the first helper used by Python
`inpaint`: OpenCV ellipse dilation for the surround mask, OpenCV Gaussian blur
with sigma 2.5, per-channel grain standard deviation, Hanning-windowed FFT
power spectra, radial averaging, clean-fraction compensation, and spectrum
normalization.

`synthesize-grain-from-noise-smoke.json` and
`synthesize-grain-fallback-from-noise-smoke.json` cover the deterministic
portion of Python `synthesize_grain` with `np.random.randn` monkeypatched to
recorded per-channel noise arrays. They verify both measured-spectrum and
fallback 1/f amplitude filters, FFT/ifft shaping, standard-deviation
normalization, per-channel grain scaling, and float32 output storage.

`biharmonic-inpaint-smoke.json` covers
`skimage.restoration.inpaint_biharmonic(..., channel_axis=-1)` for a compact
RGB mask. The Zig path builds the same radius-2 biharmonic linear system and
solves it densely for small regions.

`inpaint-biharmonic-grain-uint16-smoke.json` covers the higher-level Python
`inpaint` loop over two uint16 defect components with `np.random.randn`
monkeypatched to recorded noise planes. It verifies component order, full-image
padded ROIs, evolving result-buffer reads, local grain measurement, biharmonic
signal repair, spectral grain synthesis, uint16 clipping/casting, and masked
ROI writeback.

`ir-clean-region-uint16-smoke.json` covers the same-resolution
`scratchndent.export.ir_clean_region` path with explicit defect-mask options:
`make_defect_mask` output is asserted exactly, then the captured-noise inpaint
path is compared against the Python cleaned RGB output.

`ir-clean-region-resize-uint16-smoke.json` covers the RGB:IR size-mismatch
branch from `ir_clean_region`: the IR mask is generated at IR dimensions,
nearest-resized to RGB dimensions, dilated with the Python 3x3 ellipse kernel,
and then passed through the same captured-noise inpaint path.
