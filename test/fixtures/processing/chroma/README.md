Colour contrast fixtures from the browser prototype that `src/processing/chroma.zig`
ports (`filter.mjs`, a JavaScript reference of the filter in its demo page).

- `swatches.rgba`: the input, 32 x 24 straight-alpha sRGB RGBA8, headerless.
- `default.rgba`, `rigid.rgba`, `point.rgba`, `gamut.rgba`, `gain-only.rgba`,
  `identity.rgba`: the prototype's output for each case in `manifest.json`
  (its settings, the number of pixels it changed).
- `manifest.json`: the cases, the colour families the prototype fitted
  (`expectedPeaks`), and pixels that must stay unchanged.

Given the families the prototype fitted, the tests hold both of our filter
paths (f64 and the fast f32 one) within one 8-bit level of these outputs and
to the same changed pixels; byte-for-byte parity with the prototype's
JavaScript math is not a goal. Our fit differs from the prototype's (it is
spatial and weights colours by chroma), so it is not checked against
`expectedPeaks`.
