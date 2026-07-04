//! Film format tables and format-derived helpers shared by frame
//! detection, the CLI, the native UI, and the browser Wasm core.

const std = @import("std");

pub const FilmFormat = struct {
    name: []const u8,
    frame_mm: [2]f64,
    pitch_mm: f64,
    strip_width_mm: f64,
    description: []const u8,

    pub fn frameWidthMm(self: FilmFormat) f64 {
        return self.frame_mm[0];
    }

    pub fn frameHeightMm(self: FilmFormat) f64 {
        return self.frame_mm[1];
    }

    pub fn narrowMm(self: FilmFormat) f64 {
        return @min(self.frame_mm[0], self.frame_mm[1]);
    }

    pub fn wideMm(self: FilmFormat) f64 {
        return @max(self.frame_mm[0], self.frame_mm[1]);
    }

    pub fn gapMm(self: FilmFormat) f64 {
        return self.pitch_mm - self.wideMm();
    }

    pub fn pitchRatio(self: FilmFormat) f64 {
        return self.strip_width_mm / self.wideMm();
    }

    pub fn physicalAspect(self: FilmFormat) f64 {
        return self.frame_mm[0] / self.frame_mm[1];
    }
};

pub const format_35mm: FilmFormat = .{
    .name = "35mm",
    .frame_mm = .{ 36.0, 24.0 },
    .pitch_mm = 38.0,
    .strip_width_mm = 35.0,
    .description = "35mm (135 film)",
};

pub const format_645: FilmFormat = .{
    .name = "645",
    .frame_mm = .{ 56.0, 41.5 },
    .pitch_mm = 60.0,
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
    if (std.mem.eql(u8, format.name, "645")) return if (is_vertical) "41.5:56" else "56:41.5";
    if (std.mem.eql(u8, format.name, "6x6")) return "56:56";
    if (std.mem.eql(u8, format.name, "6x7")) return if (is_vertical) "56:69" else "69:56";
    if (std.mem.eql(u8, format.name, "6x9")) return if (is_vertical) "56:84" else "84:56";
    return if (is_vertical) "narrow:wide" else "wide:narrow";
}
