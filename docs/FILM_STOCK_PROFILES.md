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

### Stage 4: Stock Transform

This is where the film stock profile is applied. The net density goes
through a second-order polynomial in density space:

    balanced = poly_features(net_density) @ coefficients

The built-in profiles use only the diagonal: each channel's density scaled
to green's contrast, measured on real scans (see Built-in Profiles).

### Stage 5: Display Rendering

The balanced densities are rendered per frame (details and formulas in
`docs/RENDER_TRANSFORM_CLOSED_FORM.md`):

1. Automatic white balance: red and blue are mapped onto green's density
   scale through each channel's own black and white points.
2. The film's characteristic curve is inverted, a straight line of slope
   `film_gamma` (0.55) with a toe of width `film_toe`, giving log exposure.
3. Dye crosstalk is undone: colour differences in log exposure grow by
   1 / (1 - `dye_crosstalk`).
4. Automatic exposure puts the frame's log-average luminance at 18% grey;
   exposure compensation (stops) and temperature/tint are gains on that
   scene-linear light.
5. A log-logistic display curve through 18% grey (`render_contrast`), then
   sRGB encoding.

These are render settings, not part of the stock profile.

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
    R   [  1.3021,  0.00,   0.00 ]    # row 0
    G   [  0.00,    1.00,   0.00 ]    # row 1
    B   [  0.00,    0.00,   0.8203 ]  # row 2
    R^2 [  0.00,    0.00,   0.00 ]    # row 3
    ...                               # rows 4-9 zero
```

(Example: the built-in Kodak Gold 200 profile on an Epson V600)

The output for each pixel is:

    R_out = 1.3021*R
    G_out = G
    B_out = 0.8203*B

### What Each Coefficient Group Does

**Diagonal linear terms** (rows 0-2, on-diagonal: R->R, G->G, B->B):
These scale each channel's density to equalize contrast differences.
After Dmin subtraction, the channels have different density ranges for
the same scene, because the scanner's filters don't match the film's dye
absorption peaks equally. On the owner's Kodak Gold scans red's range is
about 0.77 of green's and blue's about 1.22, so R->R is 1.30 and B->B 0.82.
With automatic white balance on, each frame's own alignment supersedes
this; it is the balance left with it off.

**Off-diagonal linear terms** (rows 0-2, off-diagonal: G->R, R->G, etc.):
These would correct for dye coupling channel by channel. The built-in
profiles leave them at zero: rendering undoes dye crosstalk uniformly
(`dye_crosstalk`), and per-pair values would need a calibration target.

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

Film stock profiles are stored in `scratchndent_config.toml`. Saving writes
each built-in profile commented out, for reference, the same way settings
left at their defaults are written:

```toml
# [stocks.kodak_gold]
# description = "Kodak Gold 200 on Epson V600"
# coeffs = [
#     [  1.3021,   0.0000,   0.0000],  # R
#     [  0.0000,   1.0000,   0.0000],  # G
#     [  0.0000,   0.0000,   0.8203],  # B
#     [  0.0000,   0.0000,   0.0000],  # R2
#     [  0.0000,   0.0000,   0.0000],  # G2
#     [  0.0000,   0.0000,   0.0000],  # B2
#     [  0.0000,   0.0000,   0.0000],  # RG
#     [  0.0000,   0.0000,   0.0000],  # RB
#     [  0.0000,   0.0000,   0.0000],  # GB
#     [  0.0000,   0.0000,   0.0000],  # bias
# ]
```

Each row is one basis term. The three values are the contribution of
that term to the R, G, B output channels respectively.

To customize a built-in, uncomment its section and edit it; the edited
section then overrides the compiled profile. A live section whose values
equal the built-in, or one of its earlier versions (older saves wrote the
built-ins out live), is not a customization: the stock follows the
compiled profile and the next save comments it out again.

Custom `[stocks.*]` profiles in `scratchndent_config.toml` are the way to add
stocks. The native app parses, lists, and re-serializes them; there is no
profile editor. The browser webapp supports only the built-in stocks.

## Built-in Profiles

### Kodak Gold 200

Channel balance only: R->R 1.3021, G->G 1, B->B 0.8203. Measured on the
owner's V600 scans as each frame's red and blue density range (0.5th to
99.5th percentile, after Dmin) over green's, the median per roll, then the
median over the five normally exposed Gold rolls (84 frames): red 0.768,
blue 1.219. The ratios vary between rolls (red 0.70 to 0.84, blue 1.14 to
1.43), which is why rendering also aligns the channels per frame. Earlier
guessed matrices (the Python profile and its retune) are retired: a live
copy of one in a config loads as the built-in.

### Kodak Portra 400

Channel balance only: R->R 1.3532, G->G 1, B->B 0.8681, measured the same
way from the owner's single Portra strip (two frames), so rough.

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
few calibration patches. Fitting exists only in the Python code; it has not
been ported to Zig.

## Code References

| | Zig | Python |
| --- | --- | --- |
| Polynomial basis and coefficients | `src/processing/film_stocks.zig` | `scratchndent/calibration/film_stocks.py` |
| Density conversion and Dmin | `src/processing/measurement.zig` | `scratchndent/calibration/measurement.py` |
| Inversion pipeline | `src/processing/inversion.zig` | `scratchndent/processing/negative/inversion.py` |
| Display rendering | `src/processing/render.zig` | `scratchndent/processing/negative/render.py` |
| Config storage | `src/processing/config.zig` | `scratchndent/config.py` |
