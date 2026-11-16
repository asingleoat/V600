//! RGB colour spaces the render can work in: their primaries, and the
//! matrices between them, CIE XYZ, and Oklab's cone space. All share the D65
//! white, so no chromatic adaptation is needed between them.
//!
//! The render's three channels are the film's, and which primaries they are
//! taken to have sets how saturated the film's colours can come out: in sRGB
//! a colour the film recorded beyond sRGB lands on sRGB's edge; in a wider
//! space it keeps going, for screens that show it and papers that print it.

const std = @import("std");

pub const Space = enum {
    srgb,
    display_p3,
    adobe_rgb,
    rec2020,

    pub fn label(self: Space) [:0]const u8 {
        return switch (self) {
            .srgb => "sRGB",
            .display_p3 => "Display P3",
            .adobe_rgb => "Adobe RGB (1998)",
            .rec2020 => "Rec. 2020",
        };
    }

    /// The `render_primaries` config value.
    pub fn name(self: Space) []const u8 {
        return @tagName(self);
    }
};

pub fn named(text: []const u8) ?Space {
    if (std.mem.eql(u8, text, "auto")) return platform_default;
    return std.meta.stringToEnum(Space, text);
}

/// `auto`: on macOS, Rec. 2020, the one of these spaces that holds an
/// inkjet photo printer's gamut (an Epson ET-8500's glossy papers reach
/// past Display P3 in yellow and from cyan to blue, and past Adobe RGB in
/// yellow and blue); elsewhere sRGB, until printing comes there too.
pub const platform_default: Space = if (@import("builtin").os.tag == .macos) .rec2020 else .srgb;

pub const Matrix = [3][3]f64;

/// Red, green, and blue chromaticities (x, y).
pub fn primaries(space: Space) [3][2]f64 {
    return switch (space) {
        .srgb => .{ .{ 0.64, 0.33 }, .{ 0.30, 0.60 }, .{ 0.15, 0.06 } },
        .display_p3 => .{ .{ 0.680, 0.320 }, .{ 0.265, 0.690 }, .{ 0.150, 0.060 } },
        .adobe_rgb => .{ .{ 0.64, 0.33 }, .{ 0.21, 0.71 }, .{ 0.15, 0.06 } },
        .rec2020 => .{ .{ 0.708, 0.292 }, .{ 0.170, 0.797 }, .{ 0.131, 0.046 } },
    };
}

pub const d65 = [2]f64{ 0.3127, 0.3290 };

/// Linear RGB to XYZ (Y of white 1).
pub fn toXyz(space: Space) Matrix {
    const p = primaries(space);
    var m: Matrix = undefined;
    for (0..3) |column| {
        const x = p[column][0];
        const y = p[column][1];
        m[0][column] = x / y;
        m[1][column] = 1.0;
        m[2][column] = (1.0 - x - y) / y;
    }
    const white = [3]f64{ d65[0] / d65[1], 1.0, (1.0 - d65[0] - d65[1]) / d65[1] };
    const scale = multiplyVector(invert(m), white);
    for (0..3) |row| {
        for (0..3) |column| m[row][column] *= scale[column];
    }
    return m;
}

/// Linear RGB in `from` to linear RGB in `to`.
pub fn conversion(from: Space, to: Space) Matrix {
    if (from == to) return identity;
    return multiply(invert(toXyz(to)), toXyz(from));
}

/// Luminance of linear RGB: the Y row of `toXyz`. sRGB keeps Rec. 709's
/// rounded weights, which the render has always used.
pub fn luminanceWeights(space: Space) [3]f64 {
    if (space == .srgb) return .{ 0.2126, 0.7152, 0.0722 };
    return toXyz(space)[1];
}

/// Linear RGB to Oklab's LMS cone responses, and back. sRGB takes Oklab's
/// published matrices exactly; the others go through them from sRGB.
pub const Lms = struct {
    to_lms: Matrix,
    from_lms: Matrix,
};

const srgb_to_lms = Matrix{
    .{ 0.4122214708, 0.5363325363, 0.0514459929 },
    .{ 0.2119034982, 0.6806995451, 0.1073969566 },
    .{ 0.0883024619, 0.2817188376, 0.6299787005 },
};
const lms_to_srgb = Matrix{
    .{ 4.0767416621, -3.3077115913, 0.2309699292 },
    .{ -1.2684380046, 2.6097574011, -0.3413193965 },
    .{ -0.0041960863, -0.7034186147, 1.707614701 },
};

pub fn lms(space: Space) Lms {
    if (space == .srgb) return .{ .to_lms = srgb_to_lms, .from_lms = lms_to_srgb };
    return .{
        .to_lms = multiply(srgb_to_lms, conversion(space, .srgb)),
        .from_lms = multiply(conversion(.srgb, space), lms_to_srgb),
    };
}

pub const identity = Matrix{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };

pub fn multiply(a: Matrix, b: Matrix) Matrix {
    var m: Matrix = undefined;
    for (0..3) |row| {
        for (0..3) |column| {
            m[row][column] = a[row][0] * b[0][column] + a[row][1] * b[1][column] + a[row][2] * b[2][column];
        }
    }
    return m;
}

pub fn multiplyVector(m: Matrix, v: [3]f64) [3]f64 {
    return .{
        m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
        m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
        m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
    };
}

pub fn invert(m: Matrix) Matrix {
    const c00 = m[1][1] * m[2][2] - m[1][2] * m[2][1];
    const c01 = m[1][2] * m[2][0] - m[1][0] * m[2][2];
    const c02 = m[1][0] * m[2][1] - m[1][1] * m[2][0];
    const det = m[0][0] * c00 + m[0][1] * c01 + m[0][2] * c02;
    const inv = 1.0 / det;
    return .{
        .{ c00 * inv, (m[0][2] * m[2][1] - m[0][1] * m[2][2]) * inv, (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * inv },
        .{ c01 * inv, (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * inv, (m[0][2] * m[1][0] - m[0][0] * m[1][2]) * inv },
        .{ c02 * inv, (m[0][1] * m[2][0] - m[0][0] * m[2][1]) * inv, (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * inv },
    };
}

test "spaces map white to white and sRGB matches its published matrices" {
    for (std.enums.values(Space)) |space| {
        const white = multiplyVector(conversion(space, .srgb), .{ 1, 1, 1 });
        for (white) |v| try std.testing.expectApproxEqAbs(@as(f64, 1.0), v, 1e-9);
        const weights = luminanceWeights(space);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), weights[0] + weights[1] + weights[2], 1e-3);
        // White has Oklab lightness 1 in every space.
        const cone = multiplyVector(lms(space).to_lms, .{ 1, 1, 1 });
        for (cone) |v| try std.testing.expectApproxEqAbs(@as(f64, 1.0), v, 2e-4);
        const back = multiply(lms(space).from_lms, lms(space).to_lms);
        for (0..3) |row| for (0..3) |column| try std.testing.expectApproxEqAbs(identity[row][column], back[row][column], 1e-6);
    }
    // sRGB's own matrix from its primaries, against the standard's.
    const srgb = toXyz(.srgb);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4124), srgb[0][0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7152), srgb[1][1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9505), srgb[2][2], 1e-4);
    // Display P3's pure green lies outside sRGB.
    const green = multiplyVector(conversion(.display_p3, .srgb), .{ 0, 1, 0 });
    try std.testing.expect(green[0] < 0.0 and green[2] < 0.0);
}
