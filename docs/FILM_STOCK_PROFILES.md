# Film Stock Profiles

## Overview

Film stock profiles calibrate the conversion from raw scanner density values
to scene-linear RGB. Different film stocks have different dye chemistries,
different orange mask densities, and different responses to scanner
illumination. A profile encodes these characteristics as a polynomial
transform in the density domain, allowing accurate color reproduction from
any supported film+scanner combination.

## The Problem

A flatbed scanner like the Epson V600 illuminates the film with white light
and measures the transmitted intensity through three broadband color filters
(R, G, B). These filters don't align with the film's three dye layers:

- The **cyan** dye (controlling red light) absorbs some green too
- The **magenta** dye (controlling green) absorbs some red and blue
- The **yellow** dye (controlling blue) absorbs some green

This means the scanner's R channel reads a mix of cyan and magenta dye
absorption. A simple per-channel inversion produces color shifts because
the channels are coupled.

On top of this, color negative film has an **orange mask** (a deliberate
tinted base layer) that adds a constant density offset in every channel.
This offset differs per channel and per film stock.

A film stock profile corrects for both the orange mask (via Dmin
subtraction) and the dye coupling (via the polynomial transform).

## Inversion Pipeline

Raw scanner data goes through these stages to produce a positive image:

### Stage 1: Transmittance

Convert raw 16-bit scanner values to optical transmittance (fraction of
light transmitted through the film):

    T = raw / 65535

Values near 1.0 = clear film (lots of light through), near 0.0 = dense
film (little light through).

### Stage 2: Optical Density

Convert transmittance to optical density via the Beer-Lambert law:

    D = -log10(T)

Density is proportional to the amount of dye present. Higher density =
more dye = darker film = brighter original scene (it's a negative).
Typical values range from ~0.3 (clear film base) to ~3.0 (deep shadows
in the original scene).

### Stage 3: Dmin Subtraction

Remove the film base density (Dmin). The unexposed film base has a
non-zero density due to the orange mask and film substrate:

    net_density = max(D - Dmin, 0)

Dmin is measured from the **rebate** (the unexposed strip between or
beside frames). Typical Dmin values for Kodak Gold 200:

    R: ~0.29    G: ~0.42    B: ~0.60

After Dmin subtraction, fully unexposed film reads as (0, 0, 0) and
the remaining density represents actual scene information.

### Stage 4: Polynomial Transform

This is where the film stock profile is applied. The net density is
transformed through a second-order polynomial to correct for dye
coupling and channel sensitivity differences:

    scene_linear = poly_features(net_density) @ coefficients

This is the core of what a film stock profile encodes.

### Stage 5: Display Rendering

The scene-linear values are then rendered for display through
percentile normalization, color temperature/tint adjustments, exposure
compensation, and an S-curve for contrast. This stage is controlled by
user-facing sliders, not the film stock profile.

## The Polynomial Transform

### Basis Terms

The polynomial uses a 10-term second-order basis built from the three
density channels:

| Index | Term | What it represents |
|-------|------|--------------------|
| 0 | R | Red channel density (cyan dye absorption) |
| 1 | G | Green channel density (magenta dye absorption) |
| 2 | B | Blue channel density (yellow dye absorption) |
| 3 | R^2 | Red nonlinearity (highlight compression in red) |
| 4 | G^2 | Green nonlinearity |
| 5 | B^2 | Blue nonlinearity |
| 6 | R*G | Red-green dye coupling |
| 7 | R*B | Red-blue dye coupling |
| 8 | G*B | Green-blue dye coupling |
| 9 | 1 | Constant bias (residual offset after Dmin subtraction) |

### Coefficient Matrix

The coefficients are a 10x3 matrix. Each row corresponds to a basis
term; each column to an output channel (R, G, B):

```
          R_out    G_out    B_out
    R   [  1.20,  -0.04,   0.00 ]    # row 0
    G   [ -0.10,   0.90,  -0.06 ]    # row 1
    B   [  0.00,  -0.04,   1.02 ]    # row 2
    R^2 [  0.00,   0.00,   0.00 ]    # row 3
    G^2 [  0.00,   0.00,   0.00 ]    # row 4
    B^2 [  0.00,   0.00,   0.00 ]    # row 5
    RG  [  0.00,   0.00,   0.00 ]    # row 6
    RB  [  0.00,   0.00,   0.00 ]    # row 7
    GB  [  0.00,   0.00,   0.00 ]    # row 8
    1   [  0.00,   0.00,   0.00 ]    # row 9
```

(Example: Kodak Gold 200 on Epson V600)

The output for each pixel is:

    R_out = 1.20*R - 0.10*G + 0.00*B + 0.00*R^2 + ... + 0.00
    G_out = -0.04*R + 0.90*G - 0.04*B + ...
    B_out = 0.00*R - 0.06*G + 1.02*B + ...

### What Each Coefficient Group Does

**Diagonal linear terms** (rows 0-2, on-diagonal: R->R, G->G, B->B):
These scale each channel's density to equalize sensitivity differences.
After Dmin subtraction, different channels have different density ranges
because the scanner's spectral filters don't match the film dye
absorption peaks equally. For example, Kodak Gold's R channel has a
narrower density range than G after Dmin subtraction, so R->R is 1.20
(boosted) while G->G is 0.90 (reduced).

**Off-diagonal linear terms** (rows 0-2, off-diagonal: G->R, R->G, etc.):
These correct for dye coupling. A negative G->R coefficient (-0.10)
means "subtract some of the green-channel density from the red output."
This compensates for the scanner's red filter picking up some magenta
dye absorption that belongs to the green channel. These are kept small
to avoid introducing shadow color artifacts.

**Quadratic terms** (rows 3-5: R^2, G^2, B^2):
These correct for nonlinear dye response. Film dyes have a characteristic
curve where density increases non-linearly with exposure. The quadratic
terms model the curvature of this response. For most scanner+stock
combinations the linear terms dominate and these are zero or near-zero.

**Cross terms** (rows 6-8: R*G, R*B, G*B):
These model interactions between dye layers. For example, a non-zero
R*G term means the coupling between red and green channels is itself
density-dependent (stronger at high density than low). These are
typically small for well-separated dye sets.

**Bias** (row 9):
A constant offset added to the output. Compensates for any residual
systematic error after Dmin subtraction (e.g., if the rebate area
isn't perfectly representative of the film base). Usually zero for
well-calibrated profiles.

## TOML Storage Format

Film stock profiles are stored in `scratchndent_config.toml`:

```toml
[stocks.kodak_gold]
description = "Kodak Gold 200 on Epson V600"
coeffs = [
    [  1.2000,  -0.0400,   0.0000],  # R    (linear)
    [ -0.1000,   0.9000,  -0.0600],  # G    (linear)
    [  0.0000,  -0.0400,   1.0200],  # B    (linear)
    [  0.0000,   0.0000,   0.0000],  # R2   (quadratic)
    [  0.0000,   0.0000,   0.0000],  # G2   (quadratic)
    [  0.0000,   0.0000,   0.0000],  # B2   (quadratic)
    [  0.0000,   0.0000,   0.0000],  # RG   (cross)
    [  0.0000,   0.0000,   0.0000],  # RB   (cross)
    [  0.0000,   0.0000,   0.0000],  # GB   (cross)
    [  0.0000,   0.0000,   0.0000],  # bias (constant)
]
```

Each row is one basis term. The three values are the contribution of
that term to the R, G, B output channels respectively.

## Built-in Profiles

### Kodak Gold 200

wild guess for Gold 200 scanned on an Epson V600 at 3200-6400 DPI.

Gold has a strong orange mask (high Dmin, especially in B). The
cross-channel coupling is significant (0.91-0.97 correlation between
channels), requiring the off-diagonal corrections. The R channel needs
a 1.20x boost because its usable density range is compressed by the
mask.

### Kodak Portra 400

wild guess for Portra 400 on the same scanner. Portra has a less aggressive
orange mask, better channel separation, and wider exposure latitude.
The corrections are gentler: diagonal terms are closer to 1.0 and the
off-diagonal terms are smaller.

## Creating a Custom Profile

### Manual Tuning

The most practical approach. Start from the identity coefficients
(diagonal 1.0, everything else 0.0) and adjust:

1. **Set Dmin first.** Scan a strip with visible rebate (unexposed film
   edge). Use the rebate selection tool to set Dmin from the orange area.

2. **Adjust diagonal terms.** If reds look weak, increase row 0 col 0.
   If greens are too strong, decrease row 1 col 1. Aim for neutral grays
   in areas you know were neutral in the scene.

3. **Adjust cross-channel terms.** If you see a green cast in shadows,
   try a small negative G->R (row 1, col 0). Keep these below ~0.15
   to avoid artifacts.

4. **Quadratic terms** are rarely needed for manual tuning. Leave at zero
   unless you see clear highlight/shadow color shifts that the linear
   terms can't fix.

### Automated Fitting

If you have a scan of a calibration target (e.g., an IT8 chart shot on
the film stock), you can use `fit_density_transform()`:

```python
from scratchndent.calibration.film_stocks import fit_density_transform

# measured: Nx3 net density values from scanned target patches
# target: Nx3 known scene-linear values of those patches
coeffs = fit_density_transform(measured, target, regularization=1e-4)
```

This uses ridge regression to find the least-squares optimal polynomial
mapping. The regularization parameter prevents overfitting when you have
few calibration patches.

## Code References

- **Polynomial basis & coefficients:** `scratchndent/calibration/film_stocks.py`
- **Density conversion & Dmin:** `scratchndent/calibration/measurement.py`
- **Inversion pipeline:** `scratchndent/processing/negative/inversion.py`
- **Display rendering:** `scratchndent/processing/negative/render.py`
- **Config storage:** `scratchndent/config.py`
