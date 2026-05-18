# Render Transform Closed Form

This document describes the current Zig preview/export display transform as
closed-form scalar expressions for one pixel, assuming global calibration values
have already been selected.

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

The display range is global for the image, not per pixel:

```text
lo = robust low luminance percentile
hi = robust high luminance percentile
A = 1 / (hi - lo)
B = -lo / (hi - lo)
```

Current default display options:

```text
contrast = 1.4
curve_k = 5.0
exposure_compensation = 0.0
color_temp = 0.0
color_tint = 0.0
```

So default contrast strength is:

```text
k = (contrast - 1) * curve_k = 2.0
```

## Negative Inversion

Normalize raw transmittance and convert to net density:

```text
t_r = max(r0 / L, eps)
t_g = max(g0 / L, eps)
t_b = max(b0 / L, eps)

d_r = max(-log10(t_r) - dmin_r, 0)
d_g = max(-log10(t_g) - dmin_g, 0)
d_b = max(-log10(t_b) - dmin_b, 0)
```

Equivalently, for positive raw values above the epsilon floor:

```text
d_c = max(log10(L) - log10(raw_c) - dmin_c, 0)
```

## Built-In Linear Stock Transform

The built-in stocks currently use only linear density terms. For Kodak Gold:

```text
s_r = max( 1.20*d_r - 0.10*d_g + 0.00*d_b, 0)
s_g = max(-0.04*d_r + 0.90*d_g - 0.04*d_b, 0)
s_b = max( 0.00*d_r - 0.06*d_g + 1.02*d_b, 0)
```

For Kodak Portra:

```text
s_r = max( 1.15*d_r - 0.08*d_g + 0.00*d_b, 0)
s_g = max(-0.03*d_r + 0.93*d_g + 0.00*d_b, 0)
s_b = max( 0.00*d_r - 0.04*d_g + 1.00*d_b, 0)
```

In matrix form:

```text
s_c = max(sum_j M[c,j] * d_j, 0)
```

where `c` is output channel and `j` is density channel.

## General Custom Stock Transform

Custom stock profiles may use the full quadratic basis:

```text
basis = [
  d_r,
  d_g,
  d_b,
  d_r*d_r,
  d_g*d_g,
  d_b*d_b,
  d_r*d_g,
  d_r*d_b,
  d_g*d_b,
  1
]

s_c = max(sum_i coeff[i,c] * basis[i], 0)
```

## Display Range Selection

For each pixel in the image, luminance is:

```text
Y = 0.2126*s_r + 0.7152*s_g + 0.0722*s_b
```

Only `Y > 0.001` participates in the robust display range. The current fast
path estimates the low/high percentiles from a deterministic `f32` sample. Exact
mode sorts all positive `f64` luminance values. Once `lo` and `hi` are fixed,
the per-pixel transform below is local and closed form.

## Per-Channel Display Transform

For one scene-linear channel `s`:

```text
x0 = clamp(A*s + B, 0, 1)
```

Optional color balance, if enabled:

```text
r_mul0 = 1 + 0.5*color_temp
b_mul0 = 1 - 0.5*color_temp
g_mul0 = 1 - 0.5*color_tint

lum_scale = 0.2126*r_mul0 + 0.7152*g_mul0 + 0.0722*b_mul0

m_r = r_mul0 / lum_scale
m_g = g_mul0 / lum_scale
m_b = b_mul0 / lum_scale

x1_c = max(x0_c * m_c, 0)
```

For current default preview/export settings:

```text
m_r = m_g = m_b = 1
x1 = x0
```

Optional exposure, if enabled:

```text
gamma = 1 / (1 + exposure_compensation)
x2 = x1^gamma
```

For current default preview/export settings:

```text
gamma = 1
x2 = x1
```

Contrast curve:

```text
sigma_k(x) = 1 / (1 + exp(-k*(x - 0.5)))

curve_lo = sigma_k(0)
curve_hi = sigma_k(1)

C_k(x) = (sigma_k(x) - curve_lo) / (curve_hi - curve_lo)
```

For current defaults:

```text
k = 2
sigma_2(x) = 1 / (1 + exp(1 - 2*x))

C_2(x) = (sigma_2(x) - sigma_2(0)) / (sigma_2(1) - sigma_2(0))
```

Final display unit value:

```text
y = clamp(C_k(x2), 0, 1)
```

## Final Quantization Targets

Export-shaped display output:

```text
u16 = floor(65535 * y)
```

Preview output:

```text
u8 = floor(65535 * y) >> 8
```

Equivalent preview interpretation:

```text
u8 = floor(floor(65535 * y) / 256)
```

## Fully Inlined Default Preview Form

For current default preview settings with a built-in linear stock:

```text
D_j(raw_j) = max(-log10(max(raw_j / 65535, 1e-8)) - dmin_j, 0)

S_c = max(sum_j M[c,j] * D_j(raw_j), 0)

X_c = clamp(A*S_c + B, 0, 1)

Y_c = C_2(X_c)

u8_c = floor(65535 * clamp(Y_c, 0, 1)) >> 8
```

The corresponding export-shaped target is:

```text
u16_c = floor(65535 * clamp(Y_c, 0, 1))
```

## Optimization Targets

The most isolated approximation target is:

```text
C_k(x), where x in [0, 1]
```

For default settings this is specifically:

```text
C_2(x)
```

For final-output accuracy tests, compare:

```text
Q8(C_2(x))  against exact preview output
Q16(C_2(x)) against exact export-shaped output
```

where:

```text
Q8(z)  = floor(65535 * clamp(z, 0, 1)) >> 8
Q16(z) = floor(65535 * clamp(z, 0, 1))
```

A second independent target is the raw `u16` density conversion:

```text
D_j(raw_j) = max(log10(65535) - log10(raw_j) - dmin_j, 0)
```

for `raw_j > 0`, with the existing epsilon floor for zero or tiny values.

That target is naturally a `u16 -> f32/f64 density` lookup table, because the
input domain has only 65536 possible raw values.
