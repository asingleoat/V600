//! Built-in looks: named sets of a frame's own render settings
//! (frame_adjust.zig) for the UI to apply to frames.

const std = @import("std");

const config = @import("config.zig");
const frame_adjust = @import("frame_adjust.zig");

pub const Setting = struct { key: frame_adjust.Key, value: f64 };

pub const Look = struct {
    name: [:0]const u8,
    description: []const u8,
    settings: []const Setting,

    /// The look as a frame's own settings, every one of them: those it
    /// does not name take Standard's, not the defaults (which are Pastel's)
    /// or processing.toml's, so a look comes out the same whatever those
    /// are. The frame's strength is left as it is.
    pub fn adjustments(self: Look) frame_adjust.Adjustments {
        var result = frame_adjust.Adjustments{};
        for (standard.settings) |setting| result.set(setting.key, setting.value);
        for (self.settings) |setting| result.set(setting.key, setting.value);
        return result;
    }
};

/// The plain render: contrast 1.8 through 18% grey, automatic exposure to
/// an 18% log-average, white balance from black and white points and
/// neutral surfaces, no cast, no colour contrast. The defaults before
/// Pastel, and what every look starts from.
pub const standard = Look{
    .name = "Standard",
    .description = "The plain render: medium contrast, automatic exposure to an 18% average, neutral colour, no colour contrast",
    .settings = &.{
        .{ .key = .render_contrast, .value = 1.8 },
        .{ .key = .dye_crosstalk, .value = 0.2 },
        .{ .key = .render_percentile_lo, .value = 0.5 },
        .{ .key = .render_percentile_hi, .value = 99.5 },
        .{ .key = .exposure_compensation, .value = 0.0 },
        .{ .key = .render_highlight_target, .value = 0.0 },
        .{ .key = .auto_white_balance, .value = 1.0 },
        .{ .key = .neutral_white_balance, .value = 1.0 },
        .{ .key = .film_gamma, .value = 0.55 },
        .{ .key = .film_toe, .value = 0.25 },
        .{ .key = .color_temp, .value = 0.0 },
        .{ .key = .color_tint, .value = 0.0 },
        .{ .key = .color_contrast, .value = 0.0 },
        .{ .key = .color_contrast_families, .value = 12.0 },
        .{ .key = .color_contrast_target, .value = 0.0 },
        .{ .key = .color_contrast_gain, .value = 0.4 },
        .{ .key = .color_contrast_boost, .value = 0.3 },
        .{ .key = .color_contrast_radius, .value = 0.025 },
        .{ .key = .color_cohesion_hue, .value = 0.7 },
        .{ .key = .color_cohesion_chroma, .value = 0.55 },
    },
};

/// Muted, airy colour: soft contrast and highlights held off white
/// (0.84), a warm cast, and colour contrast that lifts muted frames to a
/// pastel colourfulness without adding to colourful ones. Fitted to the
/// colour signature of a reference photograph on the owner's frames.
pub const pastel = Look{
    .name = "Pastel",
    .description = "Muted, airy colour: soft contrast, highlights held off white, and colour contrast that brings muted frames up to a pastel colourfulness without adding to colourful ones",
    .settings = &.{
        .{ .key = .render_contrast, .value = 1.02 },
        .{ .key = .dye_crosstalk, .value = 0.05 },
        .{ .key = .render_percentile_lo, .value = 3.7 },
        .{ .key = .render_percentile_hi, .value = 96.7 },
        .{ .key = .exposure_compensation, .value = 0.0 },
        .{ .key = .render_highlight_target, .value = 0.84 },
        .{ .key = .auto_white_balance, .value = 0.99 },
        .{ .key = .film_gamma, .value = 0.6 },
        .{ .key = .film_toe, .value = 0.23 },
        .{ .key = .color_temp, .value = 0.26 },
        .{ .key = .color_tint, .value = -0.08 },
        .{ .key = .color_contrast, .value = 1.0 },
        .{ .key = .color_contrast_gain, .value = 0.5 },
        .{ .key = .color_contrast_boost, .value = 0.15 },
        .{ .key = .color_contrast_radius, .value = 0.035 },
        .{ .key = .color_cohesion_hue, .value = 0.85 },
        .{ .key = .color_cohesion_chroma, .value = 0.3 },
        .{ .key = .color_contrast_target, .value = 0.052 },
    },
};

/// Richer colour and a little more contrast, still true to life:
/// highlights at 0.90 (which also keeps bright skin from clipping), no
/// colour cast, and colour contrast that lifts muted frames toward a
/// vivid colourfulness without adding to colourful ones.
pub const vivid = Look{
    .name = "Vivid",
    .description = "Richer colour and a little more contrast, still true to life: highlights held just below white, no colour cast, and colour contrast that lifts muted frames without adding to colourful ones",
    .settings = &.{
        .{ .key = .render_contrast, .value = 2.0 },
        .{ .key = .dye_crosstalk, .value = 0.25 },
        .{ .key = .render_highlight_target, .value = 0.90 },
        .{ .key = .color_contrast, .value = 1.0 },
        .{ .key = .color_contrast_gain, .value = 0.4 },
        .{ .key = .color_contrast_boost, .value = 0.3 },
        .{ .key = .color_contrast_radius, .value = 0.03 },
        .{ .key = .color_cohesion_hue, .value = 0.5 },
        .{ .key = .color_cohesion_chroma, .value = 0.3 },
        .{ .key = .color_contrast_target, .value = 0.085 },
    },
};

pub const all = [_]Look{ pastel, vivid, standard };

test "a look sets every setting, the ones it does not name to Standard's, whatever the defaults" {
    const adjustments = vivid.adjustments();
    try std.testing.expectEqual(@as(?f64, 0.90), adjustments.get(.render_highlight_target));
    try std.testing.expectEqual(@as(?f64, 0.0), adjustments.get(.color_temp));
    try std.testing.expectEqual(@as(?f64, 0.55), adjustments.get(.film_gamma));
    try std.testing.expectEqual(@as(?f64, 12.0), adjustments.get(.color_contrast_families));
    try std.testing.expectEqual(@as(?f64, 0.26), pastel.adjustments().get(.color_temp));
    for (all) |look| try std.testing.expectEqual(@as(?f64, 1.0), look.adjustments().get(.neutral_white_balance));
    // Pastel is the default look: the built-in defaults are its settings.
    for (pastel.settings) |setting| {
        const default = config.defaultValue(@tagName(setting.key)).?;
        try std.testing.expectApproxEqAbs(setting.value, default.asFloat(), 1e-12);
    }
}
