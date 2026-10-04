//! Epson Perfection film scanners the app knows, from Epson's own ICA driver
//! tables (`EPSON Scanner.app`, `ModelInfo.plist` and `ResolutionInfo.plist`):
//! USB product IDs, interpreter IDs, and resolutions. Only the V600 has been
//! tested; the others are a best effort for beta testers to try.
const std = @import("std");

pub const Transport = union(enum) {
    /// Epson's proprietary interpreter, by ID: "A1" is `Interpreter A1`.
    interpreter: []const u8,
    /// The scanner speaks ESC/I itself, straight over USB.
    native,
};

pub const Model = struct {
    product_id: u16,
    name: []const u8,
    /// Substrings of a SANE device line (`scanimage -L`) that name the model.
    sane_names: []const []const u8,
    transport: Transport,
    /// Transparency-unit resolutions offered for film scans, smallest first.
    film_dpis: []const u32,
    /// Resolutions a transparency-unit request snaps to, preview included.
    tpu_dpis: []const u32,
    /// IR resolutions, when the scanner has an IR channel.
    ir_dpis: []const u32,
    /// The model can have an IR channel; the scanner's own identity (FS I)
    /// says whether this one does (the V800 and V850 share an ID).
    infrared: bool,
    /// The TPU calibration and gamma-table upload captured from a V600 (direct
    /// RS register writes) apply. Never sent to other hardware.
    v600_tpu_program: bool,
    tested: bool,

    pub fn interpreterId(self: *const Model) ?[]const u8 {
        return switch (self.transport) {
            .interpreter => |id| id,
            .native => null,
        };
    }

    pub fn maxIrDpi(self: *const Model) u32 {
        return self.ir_dpis[self.ir_dpis.len - 1];
    }
};

// 6400 dpi models: the V600's resolutions, which Epson's tables list for
// the V550 and V500 too. 4800 dpi models use what their tables list for both
// reflective and transmissive sources (Epson's source codes are ambiguous).
const dpis_6400_film = [_]u32{ 800, 1600, 3200, 6400 };
const dpis_6400_tpu = [_]u32{ 400, 800, 1600, 3200, 6400 };
const dpis_6400_ir = [_]u32{ 800, 1600, 3200 };
const dpis_4800_film = [_]u32{ 1200, 2400, 4800 };
const dpis_4800_tpu = [_]u32{ 300, 600, 1200, 2400, 4800 };
const dpis_4800_ir = [_]u32{ 1200, 2400 };
const dpis_lid_film = [_]u32{ 2400, 4800 };
const dpis_lid_tpu = [_]u32{ 300, 2400, 4800 };

pub const v600 = Model{
    .product_id = 0x013a,
    .name = "Epson Perfection V600 / GT-X820",
    .sane_names = &.{ "V600", "GT-X820" },
    .transport = .{ .interpreter = "A1" },
    .film_dpis = &dpis_6400_film,
    .tpu_dpis = &dpis_6400_tpu,
    .ir_dpis = &dpis_6400_ir,
    .infrared = true,
    .v600_tpu_program = true,
    .tested = true,
};

pub const models = [_]Model{
    v600,
    .{
        .product_id = 0x013b,
        .name = "Epson Perfection V550",
        .sane_names = &.{"V550"},
        .transport = .{ .interpreter = "EB" },
        .film_dpis = &dpis_6400_film,
        .tpu_dpis = &dpis_6400_tpu,
        .ir_dpis = &dpis_6400_ir,
        .infrared = true,
        .v600_tpu_program = false,
        .tested = false,
    },
    .{
        .product_id = 0x0151,
        .name = "Epson Perfection V800 / V850",
        .sane_names = &.{ "V800", "V850", "GT-X980" },
        .transport = .{ .interpreter = "FE" },
        .film_dpis = &dpis_6400_film,
        .tpu_dpis = &dpis_6400_tpu,
        .ir_dpis = &dpis_6400_ir,
        .infrared = true,
        .v600_tpu_program = false,
        .tested = false,
    },
    .{
        .product_id = 0x012c,
        .name = "Epson Perfection V700 / V750 / GT-X900",
        .sane_names = &.{ "V700", "V750", "GT-X900" },
        .transport = .native,
        .film_dpis = &dpis_6400_film,
        .tpu_dpis = &dpis_6400_tpu,
        .ir_dpis = &dpis_6400_ir,
        .infrared = true,
        .v600_tpu_program = false,
        .tested = false,
    },
    .{
        .product_id = 0x0135,
        .name = "Epson GT-X970",
        .sane_names = &.{"GT-X970"},
        .transport = .native,
        .film_dpis = &dpis_6400_film,
        .tpu_dpis = &dpis_6400_tpu,
        .ir_dpis = &dpis_6400_ir,
        .infrared = true,
        .v600_tpu_program = false,
        .tested = false,
    },
    .{
        .product_id = 0x0130,
        .name = "Epson Perfection V500 / GT-X770",
        .sane_names = &.{ "V500", "GT-X770" },
        .transport = .{ .interpreter = "7C" },
        .film_dpis = &dpis_6400_film,
        .tpu_dpis = &dpis_6400_tpu,
        .ir_dpis = &dpis_6400_ir,
        .infrared = true,
        .v600_tpu_program = false,
        .tested = false,
    },
    .{
        .product_id = 0x012a,
        .name = "Epson Perfection 4990 / GT-X800",
        .sane_names = &.{ "4990", "GT-X800" },
        .transport = .native,
        .film_dpis = &dpis_4800_film,
        .tpu_dpis = &dpis_4800_tpu,
        .ir_dpis = &dpis_4800_ir,
        .infrared = true,
        .v600_tpu_program = false,
        .tested = false,
    },
    .{
        .product_id = 0x0128,
        .name = "Epson Perfection 4870 / GT-X700",
        .sane_names = &.{ "4870", "GT-X700" },
        .transport = .native,
        .film_dpis = &dpis_4800_film,
        .tpu_dpis = &dpis_4800_tpu,
        .ir_dpis = &dpis_4800_ir,
        .infrared = true,
        .v600_tpu_program = false,
        .tested = false,
    },
    .{
        .product_id = 0x0119,
        .name = "Epson Perfection 4490 / GT-X750",
        .sane_names = &.{ "4490", "GT-X750" },
        .transport = .{ .interpreter = "54" },
        .film_dpis = &dpis_4800_film,
        .tpu_dpis = &dpis_4800_tpu,
        .ir_dpis = &dpis_4800_ir,
        .infrared = true,
        .v600_tpu_program = false,
        .tested = false,
    },
    .{
        .product_id = 0x014a,
        .name = "Epson Perfection V370 / V37",
        .sane_names = &.{ "V370", "V37", "GT-F740", "GT-S640" },
        .transport = .{ .interpreter = "DD" },
        .film_dpis = &dpis_lid_film,
        .tpu_dpis = &dpis_lid_tpu,
        .ir_dpis = &dpis_6400_ir,
        .infrared = false,
        .v600_tpu_program = false,
        .tested = false,
    },
    .{
        .product_id = 0x0142,
        .name = "Epson Perfection V330 / V33",
        .sane_names = &.{ "V330", "V33", "GT-F730", "GT-S630" },
        .transport = .{ .interpreter = "AD" },
        .film_dpis = &dpis_lid_film,
        .tpu_dpis = &dpis_lid_tpu,
        .ir_dpis = &dpis_6400_ir,
        .infrared = false,
        .v600_tpu_program = false,
        .tested = false,
    },
};

pub const epson_vendor_id: u16 = 0x04b8;

pub fn forProductId(product_id: u16) ?*const Model {
    for (&models) |*model| {
        if (model.product_id == product_id) return model;
    }
    return null;
}

/// The model a SANE device line names, if any.
pub fn forSaneLine(line: []const u8) ?*const Model {
    for (&models) |*model| {
        for (model.sane_names) |name| {
            if (std.mem.indexOf(u8, line, name) != null) return model;
        }
    }
    return null;
}

/// Whether any known model scans film at `dpi`.
pub fn isFilmDpi(dpi: u32) bool {
    for (models) |model| {
        if (std.mem.indexOfScalar(u32, model.film_dpis, dpi) != null) return true;
    }
    return false;
}

/// The entry of `candidates` nearest `dpi`, never above `max` unless every
/// entry is.
pub fn nearestDpi(dpi: u32, candidates: []const u32, max: u32) u32 {
    var best: ?u32 = null;
    for (candidates) |candidate| {
        if (candidate > max and best != null) continue;
        const better = if (best) |current|
            absDiff(candidate, dpi) < absDiff(current, dpi)
        else
            true;
        if (better) best = candidate;
    }
    return best.?;
}

fn absDiff(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

test "models are found by USB product ID and by SANE device line" {
    try std.testing.expectEqualStrings("A1", forProductId(0x013a).?.interpreterId().?);
    try std.testing.expectEqualStrings("FE", forProductId(0x0151).?.interpreterId().?);
    try std.testing.expect(forProductId(0x012c).?.interpreterId() == null);
    try std.testing.expect(forProductId(0x9999) == null);

    try std.testing.expectEqual(@as(u16, 0x013a), forSaneLine("device `epkowa:interpreter:001:017' is a Epson Perfection V600 Photo flatbed scanner").?.product_id);
    try std.testing.expectEqual(@as(u16, 0x013a), forSaneLine("device `epson2:libusb:001:005' is a Epson GT-X820 flatbed scanner").?.product_id);
    try std.testing.expectEqual(@as(u16, 0x012c), forSaneLine("device `epson2:libusb:002:003' is a Epson GT-X900 flatbed scanner").?.product_id);
    try std.testing.expectEqual(@as(u16, 0x0119), forSaneLine("device `epkowa:interpreter:001:004' is a Epson Perfection 4490 flatbed scanner").?.product_id);
    try std.testing.expectEqual(@as(u16, 0x014a), forSaneLine("device `epkowa:interpreter:001:004' is a Epson Perfection V370 flatbed scanner").?.product_id);
    try std.testing.expect(forSaneLine("device `pixma:04A91234' is a Canon CanoScan") == null);
}

test "every model lists resolutions, and only the V600 runs the V600's TPU program" {
    var product_ids: [models.len]u16 = undefined;
    for (models, 0..) |model, index| {
        try std.testing.expect(model.film_dpis.len > 0 and model.tpu_dpis.len > 0 and model.ir_dpis.len > 0);
        for (model.film_dpis) |dpi| try std.testing.expect(std.mem.indexOfScalar(u32, model.tpu_dpis, dpi) != null);
        try std.testing.expectEqual(model.product_id == 0x013a, model.v600_tpu_program);
        try std.testing.expectEqual(model.product_id == 0x013a, model.tested);
        for (product_ids[0..index]) |earlier| try std.testing.expect(earlier != model.product_id);
        product_ids[index] = model.product_id;
    }
}

test "resolutions snap to the nearest supported one, capped by the scanner's maximum" {
    try std.testing.expectEqual(@as(u32, 400), nearestDpi(200, v600.tpu_dpis, 6400));
    try std.testing.expectEqual(@as(u32, 6400), nearestDpi(5000, v600.tpu_dpis, 6400));
    try std.testing.expectEqual(@as(u32, 3200), nearestDpi(6400, v600.tpu_dpis, 3200));
    try std.testing.expectEqual(@as(u32, 300), nearestDpi(400, &dpis_lid_tpu, 4800));
    try std.testing.expectEqual(@as(u32, 2400), nearestDpi(3200, &dpis_lid_tpu, 4800));
    try std.testing.expect(isFilmDpi(4800) and isFilmDpi(3200) and !isFilmDpi(1000));
}
