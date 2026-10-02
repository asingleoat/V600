//! Film format tables and format-derived helpers shared by frame
//! detection, the CLI, the native UI, and the browser Wasm core.

const std = @import("std");

pub const FilmFormat = struct {
    name: []const u8,
    /// Frame size across the strip (the film's width), then along it. The
    /// long side is along the strip except for 645.
    frame_mm: [2]f64,
    /// Frame start to frame start along the strip.
    pitch_mm: f64,
    strip_width_mm: f64,
    description: []const u8,
    /// Least and most film cameras leave between neighbouring frames; the
    /// gap varies frame to frame. Formats with one are placed by a
    /// fixed-length fit (`fitFramesAlongStrip`); the others by pitch
    /// alignment, until hand-placed frames show the fit works for them too.
    gap_range_mm: ?[2]f64 = null,
    /// How far, as a fraction, a camera's frame may run wider or narrower
    /// across the strip than the format's; the fit measures the width within
    /// it. Bounded by the nearest other edge the same way round outside the
    /// frame.
    width_variation: f64 = 0.0,

    pub fn acrossMm(self: FilmFormat) f64 {
        return self.frame_mm[0];
    }

    pub fn alongMm(self: FilmFormat) f64 {
        return self.frame_mm[1];
    }

    pub fn gapMm(self: FilmFormat) f64 {
        return self.pitch_mm - self.alongMm();
    }

    pub fn pitchRatio(self: FilmFormat) f64 {
        return self.strip_width_mm / self.alongMm();
    }
};

pub const format_35mm: FilmFormat = .{
    .name = "35mm",
    .frame_mm = .{ 24.0, 36.0 },
    .pitch_mm = 38.0,
    .strip_width_mm = 35.0,
    .description = "35mm (135 film)",
    .gap_range_mm = .{ 0.2, 6.0 },
    // A line along the strip lies about 0.5 mm outside the frame, inside
    // the perforations; gates vary about 1%.
    .width_variation = 0.02,
};

pub const format_645: FilmFormat = .{
    .name = "645",
    .frame_mm = .{ 56.0, 41.5 },
    // Cameras leave 3-4 mm between frames (15-16 frames per 120 roll).
    .pitch_mm = 45.0,
    .strip_width_mm = 61.5,
    .description = "645 medium format",
};

pub const format_6x6: FilmFormat = .{
    .name = "6x6",
    .frame_mm = .{ 56.0, 56.0 },
    .pitch_mm = 60.0,
    .strip_width_mm = 61.5,
    .description = "6x6 medium format",
};

pub const format_6x7: FilmFormat = .{
    .name = "6x7",
    .frame_mm = .{ 56.0, 69.0 },
    .pitch_mm = 73.0,
    .strip_width_mm = 61.5,
    .description = "6x7 medium format",
    // Hand-placed frames show 3-8 mm between frames.
    .gap_range_mm = .{ 0.5, 12.0 },
    // The film's edge lies about 2.75 mm outside the frame.
    .width_variation = 0.04,
};

pub const format_6x9: FilmFormat = .{
    .name = "6x9",
    .frame_mm = .{ 56.0, 84.0 },
    .pitch_mm = 88.0,
    .strip_width_mm = 61.5,
    .description = "6x9 medium format",
};

pub const formats = [_]FilmFormat{
    format_35mm,
    format_645,
    format_6x6,
    format_6x7,
    format_6x9,
};

pub fn formatByName(name: []const u8) ?FilmFormat {
    for (formats) |format| {
        if (std.mem.eql(u8, format.name, name)) return format;
    }
    return null;
}

pub fn detectFramesAspect(format: FilmFormat, is_vertical: bool) []const u8 {
    if (std.mem.eql(u8, format.name, "35mm")) return if (is_vertical) "24:36" else "36:24";
    if (std.mem.eql(u8, format.name, "645")) return if (is_vertical) "56:41.5" else "41.5:56";
    if (std.mem.eql(u8, format.name, "6x6")) return "56:56";
    if (std.mem.eql(u8, format.name, "6x7")) return if (is_vertical) "56:69" else "69:56";
    if (std.mem.eql(u8, format.name, "6x9")) return if (is_vertical) "56:84" else "84:56";
    return if (is_vertical) "narrow:wide" else "wide:narrow";
}
