# Render Transform Closed Form

This document describes the current Zig preview/export display transform as
closed-form scalar expressions for one pixel, once the per-image values (each
channel's black and white point and the exposure key) have been measured.

The useful algebraic optimization targets are the final quantized forms:

- preview: final `u8`
- export-shaped display output: final `u16`

Floating-point differences below one final integer LSB are not meaningful for
these targets.

## Inputs And Constants

Raw scanner RGB for one pixel:

```text
r0, g0, b0 in [0, 65535]
L = 65535
eps = 1e-8
dmin = [dmin_r, dmin_g, dmin_b]
```

Current default display options:

```text
contrast = 1.8              display curve exponent
percentile_lo = 0.5         each channel's black point
percentile_hi = 99.5        each channel's white point
exposure_compensation = 0   stops
color_temp = 0
color_tint = 0
auto_white_balance = 1
film_gamma = 0.55           density per decade of exposure
film_toe = 0.25             decades of exposure
dye_crosstalk = 0.2
```

## Negative Inversion

Normalize raw transmittance and convert to net density:

```text
t_c = max(c0 / L, eps)
d_c = max(-log10(t_c) - dmin_c, 0)
```

## Stock Channel Balance

The built-in stocks are diagonal: each channel's net density scaled to
green's contrast, measured on the owner's scans (see
`docs/FILM_STOCK_PROFILES.md`). For Kodak Gold:

```text
s_r = 1.3021 * d_r
s_g = d_g
s_b = 0.8203 * d_b
```

Custom stock profiles may use the full quadratic basis:

```text
basis = [d_r, d_g, d_b, d_r^2, d_g^2, d_b^2, d_r*d_g, d_r*d_b, d_g*d_b, 1]
s_c = max(sum_i coeff[i,c] * basis[i], 0)
```

## Per-Image Measurements

Pixels with `Y = 0.2126*s_r + 0.7152*s_g + 0.0722*s_b > 0.001` take part. The
fast path uses a deterministic stratified sample (16,384 pixels by default);
exact mode uses every pixel. When the image is one frame crop (exports), only
its inner 95% in each direction is measured, leaving out the slivers of film
border a crop takes in; previews of a whole strip measure everything.

Each channel's black and white point are its own percentiles:

```text
lo_c = percentile(s_c, percentile_lo)
hi_c = percentile(s_c, percentile_hi)
```

Automatic white balance moves red and blue onto green's density scale through
those points, `w` of the way (green is unchanged):

```text
k_c = (hi_g - lo_g) / (hi_c - lo_c)
a_c = 1 + w*(k_c - 1)
o_c = w*(lo_g - k_c*lo_c)
```

## Per-Pixel Transform

Aligned density, then log10 exposure through the inverted characteristic
curve, a straight line of slope `film_gamma` with a softplus toe of width
`film_toe`:

```text
u_c = a_c*s_c + o_c
x_c = film_toe * ln(expm1(max(u_c, 1e-9) / (film_gamma*film_toe)))
```

The forward curve is `u = film_gamma*film_toe*ln(1 + exp(x/film_toe))`: far
above the toe `x = u / film_gamma`.

Dye crosstalk: colour differences around the pixel's mean log exposure grow
by `g = 1 / (1 - dye_crosstalk)`:

```text
m = (x_r + x_g + x_b) / 3
x'_c = m + g*(x_c - m)
```

Exposure and temperature/tint are log10 offsets, so gains on scene-linear
light. The exposure puts the log-average luminance of the measured pixels at
18% grey:

```text
key = mean over pixels of log10(0.2126*10^x'_r + 0.7152*10^x'_g + 0.0722*10^x'_b)
e = log10(0.18) - key + exposure_compensation*log10(2)

t = 0.15*color_temp, n = 0.15*color_tint
shift = [t, -n, -t]
f_c = e + shift_c - (0.2126*shift_r + 0.7152*shift_g + 0.0722*shift_b)

E_c = 10^(x'_c + f_c)
```

Display curve, a log-logistic through 18% grey (18% scene light displays as
18% light), then sRGB encoding:

```text
p = contrast
K = 0.18 * (1/0.18 - 1)^(1/p)
y_c = srgb(E_c^p / (E_c^p + K^p))
```

`y` comes from an 8192-entry table over `x'_c + f_c` in [-8, 4] decades with
linear interpolation; below the table it is 0 and above it the table's last
value.

## Final Quantization Targets

```text
u16 = floor(65535 * clamp(y, 0, 1))
u8  = floor(65535 * clamp(y, 0, 1)) >> 8
```

## Optimization Targets

The per-pixel work is the toe inversion (one `expm1` and one `log` per
channel), the crosstalk mix, and one table lookup per channel. The table
already covers the display curve and sRGB encoding exactly enough for `u16`.

A separate target is the raw `u16` density conversion:

```text
d_c = max(log10(65535) - log10(raw_c) - dmin_c, 0)
```

for `raw_c > 0`, with the epsilon floor for zero or tiny values. That is
naturally a `u16 -> f32/f64` lookup table, because the input domain has only
65536 values.
