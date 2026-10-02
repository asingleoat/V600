# Frame Detection Fixtures

These fixtures pin deterministic pieces of the frozen Python frame detection
pipeline so they run headlessly without scanner hardware or gitignored scan
TIFFs. Where frames land is judged only on real scans against frames the
owner verified: `roll check-frames` on rolls with hand framings, and the
real-scan tests, which use `test-detect-ground-truth.json` and skip when the
gitignored TIFFs are absent. No fixture here stands in for film: the ones
left pin image operations (grayscale, CLAHE, rotation, morphology, crops)
and coordinate conversions.

`detection-gray-preprocess-smoke.json` stores the scanner-preview grayscale
conversion and optional inversion semantics used before frame detection,
including Python's special uint16 RGB mean/truncate behavior.

`clahe-8bit-smoke.json` stores OpenCV CLAHE output for deterministic 8-bit
input patterns, including the detector's 8x8 tile-grid shape.

`film-extent-close-binary-smoke.json` stores direct OpenCV
`cv2.morphologyEx(..., MORPH_CLOSE, square_kernel)` output for small binary
masks. Zig may implement the all-ones square close with separable sliding
windows for speed, but this fixture keeps the behavior pinned to the Python
OpenCV operation.

`rotation-back-transform-smoke.json` stores the expanded rotation matrix,
inverse affine transform, and final frame center/angle back-transform used
after Python detects frames in a rotation-corrected image.

`expanded-rotation-resample-smoke.json` stores `cv2.warpAffine` output for a
small expanded grayscale rotation with replicate borders.

`rotated-rect-crop-*.json` stores grayscale numeric output from
`crop_rotated_rect` for a small synthetic image.

`preview-coordinate-scaling-*.json` stores the browser/process-handler
conversion between preview coordinates and full-resolution export coordinates.

`test-detect-ground-truth.json` stores the manual `test_detect.py` frame
rectangles, their full-resolution `gt_to_full` conversion, and the RMS/angle
comparison semantics used by that test. The conversion test does not load the
large gitignored scan TIFFs; the real-scan detection tests do, when present,
and require detection within 0.5 mm, 1% of the size, and 0.15 degrees of these
rectangles.

`test-detect-python-output.json` stores frozen Python `detect_frames` output for
the four real scans referenced by `test_detect.py`: `scan_0001`, `scan_0003`,
`scan_0004`, and `scan_0006`. The webapp crop-export benchmark crops these
rectangles; the Zig detector no longer matches it exactly, since 35mm frames are
placed by a fixed-length fit rather than Python's pitch alignment.
