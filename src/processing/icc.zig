//! ICC colour management through Little CMS: the profiles of the render's
//! colour spaces (to embed in exports and to convert from), profiles read
//! from files (printers and their papers), and transforms between them,
//! including soft proofs (how a print looks, shown on screen).

const std = @import("std");

const chroma = @import("chroma.zig");
const color = @import("color.zig");
const rgb_space = @import("rgb_space.zig");

const c = @cImport(@cInclude("lcms2.h"));

pub const Error = error{ IccProfileInvalid, IccProfileCreateFailed, IccTransformFailed, OutOfMemory };

pub const Intent = enum(u32) {
    perceptual = 0,
    relative_colorimetric = 1,
    saturation = 2,
    absolute_colorimetric = 3,

    pub fn label(self: Intent) [:0]const u8 {
        return switch (self) {
            .perceptual => "Perceptual",
            .relative_colorimetric => "Relative colorimetric",
            .saturation => "Saturation",
            .absolute_colorimetric => "Absolute colorimetric",
        };
    }
};

pub fn intentNamed(text: []const u8) ?Intent {
    return std.meta.stringToEnum(Intent, text);
}

pub const DeviceClass = enum { input, display, output, link, abstract, colour_space, named_colour, other };

pub const Profile = struct {
    handle: c.cmsHPROFILE,

    pub fn openFile(path: []const u8) Error!Profile {
        var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (path.len >= buffer.len) return error.IccProfileInvalid;
        @memcpy(buffer[0..path.len], path);
        buffer[path.len] = 0;
        const handle = c.cmsOpenProfileFromFile(&buffer, "r") orelse return error.IccProfileInvalid;
        return .{ .handle = handle };
    }

    pub fn openMemory(data: []const u8) Error!Profile {
        const handle = c.cmsOpenProfileFromMem(data.ptr, @intCast(data.len)) orelse return error.IccProfileInvalid;
        return .{ .handle = handle };
    }

    pub fn deinit(self: Profile) void {
        _ = c.cmsCloseProfile(self.handle);
    }

    /// The profile's description, cut to fit `buffer`.
    pub fn description(self: Profile, buffer: []u8) []const u8 {
        const written = c.cmsGetProfileInfoASCII(self.handle, c.cmsInfoDescription, "en", "US", buffer.ptr, @intCast(buffer.len));
        if (written == 0) return "";
        return std.mem.sliceTo(buffer[0..@min(buffer.len, written)], 0);
    }

    pub fn deviceClass(self: Profile) DeviceClass {
        return switch (c.cmsGetDeviceClass(self.handle)) {
            c.cmsSigInputClass => .input,
            c.cmsSigDisplayClass => .display,
            c.cmsSigOutputClass => .output,
            c.cmsSigLinkClass => .link,
            c.cmsSigAbstractClass => .abstract,
            c.cmsSigColorSpaceClass => .colour_space,
            c.cmsSigNamedColorClass => .named_colour,
            else => .other,
        };
    }

    pub fn isRgb(self: Profile) bool {
        return c.cmsGetColorSpace(self.handle) == c.cmsSigRgbData;
    }

    /// Whether the profile can be converted to (it has the tables for
    /// `intent`, directly or through a fallback Little CMS accepts).
    pub fn supportsOutput(self: Profile, intent: Intent) bool {
        return c.cmsIsIntentSupported(self.handle, @intFromEnum(intent), c.LCMS_USED_AS_OUTPUT) != 0;
    }

    /// The profile serialized, for embedding in a file.
    pub fn serialize(self: Profile, allocator: std.mem.Allocator) Error![]u8 {
        var size: c.cmsUInt32Number = 0;
        if (c.cmsSaveProfileToMem(self.handle, null, &size) == 0) return error.IccProfileCreateFailed;
        const out = try allocator.alloc(u8, size);
        errdefer allocator.free(out);
        if (c.cmsSaveProfileToMem(self.handle, out.ptr, &size) == 0) return error.IccProfileCreateFailed;
        return out;
    }
};

pub const Encoding = enum {
    /// Linear light, for converting from the render's float output.
    linear,
    /// sRGB's transfer curve, as the render encodes every file it writes.
    srgb_curve,
};

/// The profile of `space` with its primaries, D65 white, and `encoding`.
pub fn spaceProfile(space: rgb_space.Space, encoding: Encoding) Error!Profile {
    const p = rgb_space.primaries(space);
    const white = c.cmsCIExyY{ .x = rgb_space.d65[0], .y = rgb_space.d65[1], .Y = 1.0 };
    const triple = c.cmsCIExyYTRIPLE{
        .Red = .{ .x = p[0][0], .y = p[0][1], .Y = 1.0 },
        .Green = .{ .x = p[1][0], .y = p[1][1], .Y = 1.0 },
        .Blue = .{ .x = p[2][0], .y = p[2][1], .Y = 1.0 },
    };
    // sRGB's curve as ICC parametric type 4: Y = (aX + b)^g above d, cX below.
    const srgb_parameters = [_]f64{ 2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045 };
    const curve = switch (encoding) {
        .linear => c.cmsBuildGamma(null, 1.0),
        .srgb_curve => c.cmsBuildParametricToneCurve(null, 4, &srgb_parameters),
    } orelse return error.IccProfileCreateFailed;
    defer c.cmsFreeToneCurve(curve);
    var curves = [3]?*c.cmsToneCurve{ curve, curve, curve };
    const handle = c.cmsCreateRGBProfile(&white, &triple, @ptrCast(&curves)) orelse return error.IccProfileCreateFailed;
    const profile = Profile{ .handle = handle };
    errdefer profile.deinit();
    var name_buffer: [64]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buffer, "{s}{s}", .{ space.label(), if (encoding == .linear) " linear" else "" }) catch unreachable;
    const mlu = c.cmsMLUalloc(null, 1) orelse return error.IccProfileCreateFailed;
    defer c.cmsMLUfree(mlu);
    if (c.cmsMLUsetASCII(mlu, "en", "US", name.ptr) == 0) return error.IccProfileCreateFailed;
    if (c.cmsWriteTag(handle, c.cmsSigProfileDescriptionTag, mlu) == 0) return error.IccProfileCreateFailed;
    return profile;
}

/// The serialized profile of `space` as the render encodes it, for files.
pub fn spaceProfileBytes(allocator: std.mem.Allocator, space: rgb_space.Space) Error![]u8 {
    const profile = try spaceProfile(space, .srgb_curve);
    defer profile.deinit();
    return profile.serialize(allocator);
}

/// RGB pixel layouts the transforms read and write.
pub const Format = enum {
    rgb_f32,
    rgb_u8,
    rgb_u16,

    fn lcms(self: Format) c.cmsUInt32Number {
        return switch (self) {
            .rgb_f32 => c.TYPE_RGB_FLT,
            .rgb_u8 => c.TYPE_RGB_8,
            .rgb_u16 => c.TYPE_RGB_16,
        };
    }
};

pub const Options = struct {
    intent: Intent = .relative_colorimetric,
    black_point_compensation: bool = true,
};

pub const Transform = struct {
    handle: c.cmsHTRANSFORM,

    /// From `source` (as `in`) to `destination` (as `out`). Safe to apply
    /// from several threads at once.
    pub fn init(source: Profile, in: Format, destination: Profile, out: Format, options: Options) Error!Transform {
        const flags = baseFlags(options);
        const handle = c.cmsCreateTransform(source.handle, in.lcms(), destination.handle, out.lcms(), @intFromEnum(options.intent), flags) orelse return error.IccTransformFailed;
        return .{ .handle = handle };
    }

    /// From `source` to `display`, as `printer` would render it with
    /// `options`: the soft proof. With `paper_white` the display shows the
    /// paper's own white and black (absolute colorimetric); without, the
    /// paper's white maps to the display's.
    pub fn initProof(source: Profile, in: Format, display: Profile, out: Format, printer: Profile, options: Options, paper_white: bool) Error!Transform {
        const flags = baseFlags(options) | c.cmsFLAGS_SOFTPROOFING;
        const proof_intent: Intent = if (paper_white) .absolute_colorimetric else .relative_colorimetric;
        const handle = c.cmsCreateProofingTransform(
            source.handle,
            in.lcms(),
            display.handle,
            out.lcms(),
            printer.handle,
            @intFromEnum(options.intent),
            @intFromEnum(proof_intent),
            flags,
        ) orelse return error.IccTransformFailed;
        return .{ .handle = handle };
    }

    fn baseFlags(options: Options) c.cmsUInt32Number {
        var flags: c.cmsUInt32Number = c.cmsFLAGS_NOCACHE | c.cmsFLAGS_HIGHRESPRECALC;
        if (options.black_point_compensation) flags |= c.cmsFLAGS_BLACKPOINTCOMPENSATION;
        return flags;
    }

    pub fn deinit(self: Transform) void {
        c.cmsDeleteTransform(self.handle);
    }

    /// Converts `pixels` pixels; the slices are in the transform's formats.
    pub fn apply(self: Transform, input: anytype, output: anytype, pixels: usize) void {
        std.debug.assert(input.len >= pixels * 3 and output.len >= pixels * 3);
        c.cmsDoTransform(self.handle, input.ptr, output.ptr, @intCast(pixels));
    }
};

test "a space's profile round-trips through bytes and converts as its matrices do" {
    const allocator = std.testing.allocator;
    const bytes = try spaceProfileBytes(allocator, .display_p3);
    defer allocator.free(bytes);
    const p3 = try Profile.openMemory(bytes);
    defer p3.deinit();
    var name: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Display P3", p3.description(&name));
    try std.testing.expect(p3.isRgb());

    const p3_linear = try spaceProfile(.display_p3, .linear);
    defer p3_linear.deinit();
    const srgb_linear = try spaceProfile(.srgb, .linear);
    defer srgb_linear.deinit();
    const transform = try Transform.init(p3_linear, .rgb_f32, srgb_linear, .rgb_f32, .{ .intent = .relative_colorimetric, .black_point_compensation = false });
    defer transform.deinit();
    const input = [_]f32{ 0.2, 0.5, 0.3, 0.7, 0.6, 0.65 };
    var output: [6]f32 = undefined;
    transform.apply(&input, &output, 2);
    const m = rgb_space.conversion(.display_p3, .srgb);
    for (0..2) |pixel| {
        const expected = rgb_space.multiplyVector(m, .{ input[pixel * 3], input[pixel * 3 + 1], input[pixel * 3 + 2] });
        for (0..3) |channel| try std.testing.expectApproxEqAbs(expected[channel], output[pixel * 3 + channel], 2e-3);
    }

    // The encoded profile's curve is sRGB's.
    const srgb = try spaceProfile(.srgb, .srgb_curve);
    defer srgb.deinit();
    const encode = try Transform.init(srgb_linear, .rgb_f32, srgb, .rgb_f32, .{ .black_point_compensation = false });
    defer encode.deinit();
    const grey = [_]f32{ 0.18, 0.18, 0.18 };
    var encoded: [3]f32 = undefined;
    encode.apply(&grey, &encoded, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4613), encoded[0], 2e-3);
}

/// RGB pixels (8 or 16 bits, in `profile`) as 8-bit sRGB for a screen:
/// colours beyond sRGB come in at the same Oklab lightness and hue, as the
/// render's own screen output does.
pub fn toScreenSrgb8(allocator: std.mem.Allocator, data: []const u8, bits: u16, pixel_count: usize, profile: Profile) Error![]u8 {
    const linear_srgb = try spaceProfile(.srgb, .linear);
    defer linear_srgb.deinit();
    const format: Format = if (bits == 16) .rgb_u16 else .rgb_u8;
    const transform = try Transform.init(profile, format, linear_srgb, .rgb_f32, .{ .intent = .relative_colorimetric, .black_point_compensation = false });
    defer transform.deinit();
    const out = try allocator.alloc(u8, pixel_count * 3);
    errdefer allocator.free(out);
    var encode: [4097]u8 = undefined;
    for (&encode, 0..) |*entry, i| entry.* = @intFromFloat(@round(255.0 * color.linearToSrgbValue(@as(f64, @floatFromInt(i)) / 4096.0)));
    var linear: [1024 * 3]f32 = undefined;
    var start: usize = 0;
    while (start < pixel_count) : (start += 1024) {
        const n = @min(@as(usize, 1024), pixel_count - start);
        if (bits == 16) {
            const samples: []align(1) const u16 = std.mem.bytesAsSlice(u16, data);
            transform.apply(samples[start * 3 ..][0 .. n * 3], linear[0 .. n * 3], n);
        } else {
            transform.apply(data[start * 3 ..][0 .. n * 3], linear[0 .. n * 3], n);
        }
        for (0..n) |i| {
            const fitted = chroma.fitPixel(&chroma.srgb_lms, linear[i * 3 ..][0..3].*);
            inline for (0..3) |k| out[(start + i) * 3 + k] = encode[@intFromFloat(@round(fitted[k] * 4096.0))];
        }
    }
    return out;
}

/// RGB pixels (8 or 16 bits, in `profile`) as linear light in `screen`'s
/// gamut, colours beyond it brought in as toScreenSrgb8 does.
pub fn toScreenLinear(allocator: std.mem.Allocator, data: []const u8, bits: u16, pixel_count: usize, profile: Profile, screen: rgb_space.Space) Error![]f32 {
    const linear_screen = try spaceProfile(screen, .linear);
    defer linear_screen.deinit();
    const format: Format = if (bits == 16) .rgb_u16 else .rgb_u8;
    const transform = try Transform.init(profile, format, linear_screen, .rgb_f32, .{ .intent = .relative_colorimetric, .black_point_compensation = false });
    defer transform.deinit();
    const out = try allocator.alloc(f32, pixel_count * 3);
    errdefer allocator.free(out);
    if (bits == 16) {
        const samples: []align(1) const u16 = std.mem.bytesAsSlice(u16, data);
        transform.apply(samples[0 .. pixel_count * 3], out, pixel_count);
    } else {
        transform.apply(data[0 .. pixel_count * 3], out, pixel_count);
    }
    const lms = chroma.Lms.of(screen);
    for (0..pixel_count) |i| {
        const fitted = chroma.fitPixel(&lms, out[i * 3 ..][0..3].*);
        out[i * 3 ..][0..3].* = .{ fitted[0], fitted[1], fitted[2] };
    }
    return out;
}

/// Whether a profile is sRGB as the app writes it, so its pixels show as
/// they are.
pub fn isSrgb(profile: Profile) bool {
    var buffer: [64]u8 = undefined;
    return std.mem.eql(u8, profile.description(&buffer), "sRGB");
}

test "wide-gamut pixels come to screen sRGB within its gamut, sRGB ones as they are" {
    const allocator = std.testing.allocator;
    const p3 = try spaceProfile(.display_p3, .srgb_curve);
    defer p3.deinit();
    // Pure P3 green, and a P3 grey.
    const data = [_]u8{ 0, 255, 0, 119, 119, 119 };
    const out = try toScreenSrgb8(allocator, &data, 8, 2, p3);
    defer allocator.free(out);
    // Held at its Oklab hue, P3's green lands on sRGB's edge a little
    // toward cyan (1, 247, 79).
    try std.testing.expect(out[1] > 200 and out[0] < 20 and out[2] < 120);
    for (out[3..6]) |v| try std.testing.expect(@abs(@as(i32, v) - 119) <= 1);
    const srgb = try spaceProfile(.srgb, .srgb_curve);
    defer srgb.deinit();
    try std.testing.expect(isSrgb(srgb) and !isSrgb(p3));
}
