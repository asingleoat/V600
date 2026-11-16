//! CUPS raster (version 3, uncompressed): the page format printer drivers
//! take from the print system. Sending it ourselves, the colours reach the
//! driver as written, with no conversion on the way, which colour-managed
//! printing needs. Headers follow what macOS's own PDF-to-raster filter
//! writes for the same page, so a driver sees what it is used to.

const std = @import("std");

pub const sync_v3_little = "3SaR";
pub const header_size = 1796;

/// A page in printer points (1/72 in): the paper, and the part of it the
/// raster covers.
pub const Page = struct {
    /// The paper's size.
    width_pt: f64,
    height_pt: f64,
    /// The printable area, lower-left and upper-right from the paper's
    /// lower-left corner. A borderless size covers the whole paper.
    imageable: [4]f64,
    /// Borderless sizes print past the paper's edges by this factor (the
    /// PPD's cupsBorderlessScalingFactor), 1 otherwise.
    borderless_scale: f64 = 1.0,
    dpi: u32,
    /// What the PPD's choices set: some drivers read their print mode from
    /// these (Epson's cupsCompression follows its resolution).
    compression: u32 = 0,
    media_type: u32 = 0,
    /// The PPD's PageSize choice.
    size_name: []const u8 = "",
};

/// The raster's own size and where it lies, in points: a borderless page's
/// raster is the paper scaled up by its factor, centred on it; a bordered
/// one's the printable area.
pub const Geometry = struct {
    width: u32,
    height: u32,
    /// The raster's area on the paper, in points from the lower-left
    /// corner (it may reach past the edges).
    area: [4]f64,
};

pub fn geometry(page: Page) Geometry {
    const dpi: f64 = @floatFromInt(page.dpi);
    if (page.borderless_scale > 1.0) {
        const w = page.width_pt * page.borderless_scale;
        const h = page.height_pt * page.borderless_scale;
        const x0 = (page.width_pt - w) / 2.0;
        const y0 = (page.height_pt - h) / 2.0;
        return .{
            .width = @intFromFloat(@round(w / 72.0 * dpi)),
            .height = @intFromFloat(@round(h / 72.0 * dpi)),
            .area = .{ x0, y0, x0 + w, y0 + h },
        };
    }
    const area = page.imageable;
    return .{
        .width = @intFromFloat(@round((area[2] - area[0]) / 72.0 * dpi)),
        .height = @intFromFloat(@round((area[3] - area[1]) / 72.0 * dpi)),
        .area = area,
    };
}

/// The page header for 8-bit RGB, chunky, as cups_page_header2_t lays it
/// out (little-endian, the sync word saying so).
pub fn header(page: Page) [header_size]u8 {
    var h: [header_size]u8 = @splat(0);
    const g = geometry(page);
    const borderless = page.borderless_scale > 1.0;
    const put = struct {
        fn int(buffer: *[header_size]u8, offset: usize, value: u32) void {
            std.mem.writeInt(u32, buffer[offset..][0..4], value, .little);
        }
        fn float(buffer: *[header_size]u8, offset: usize, value: f64) void {
            std.mem.writeInt(u32, buffer[offset..][0..4], @bitCast(@as(f32, @floatCast(value))), .little);
        }
    };
    const page_w = if (borderless) page.width_pt * page.borderless_scale else page.width_pt;
    const page_h = if (borderless) page.height_pt * page.borderless_scale else page.height_pt;
    put.int(&h, 276, page.dpi); // HWResolution
    put.int(&h, 280, page.dpi);
    const bbox = if (borderless) [4]f64{ 0, 0, page_w, page_h } else page.imageable;
    for (bbox, 0..) |v, i| put.int(&h, 284 + 4 * i, @intFromFloat(@floor(v))); // ImagingBoundingBox
    put.int(&h, 312, @intFromFloat(@floor(bbox[0]))); // Margins
    put.int(&h, 316, @intFromFloat(@floor(bbox[1])));
    put.int(&h, 340, 1); // NumCopies
    put.int(&h, 352, @intFromFloat(@floor(page_w))); // PageSize
    put.int(&h, 356, @intFromFloat(@floor(page_h)));
    put.int(&h, 380, page.media_type); // cupsMediaType
    put.int(&h, 404, page.compression); // cupsCompression
    put.int(&h, 372, g.width); // cupsWidth
    put.int(&h, 376, g.height); // cupsHeight
    put.int(&h, 384, 8); // cupsBitsPerColor
    put.int(&h, 388, 24); // cupsBitsPerPixel
    put.int(&h, 392, g.width * 3); // cupsBytesPerLine
    put.int(&h, 396, 0); // cupsColorOrder: chunky
    put.int(&h, 400, 1); // cupsColorSpace: RGB
    put.int(&h, 420, 3); // cupsNumColors
    put.float(&h, 424, page.borderless_scale); // cupsBorderlessScalingFactor
    put.float(&h, 428, page.width_pt); // cupsPageSize
    put.float(&h, 432, page.height_pt);
    const imaging = if (borderless) [4]f64{ 0, 0, page.width_pt, page.height_pt } else page.imageable;
    for (imaging, 0..) |v, i| put.float(&h, 436 + 4 * i, v); // cupsImagingBBox
    put.int(&h, 452, 1); // cupsInteger[0], as macOS's filter sets it
    const name_len = @min(page.size_name.len, 63);
    @memcpy(h[1732..][0..name_len], page.size_name[0..name_len]); // cupsPageSizeName
    return h;
}

/// Writes one 8-bit RGB page: the sync word (once per stream, with
/// `first`), the header, then `rows`, which must hold the raster's every
/// row, top first.
pub fn writePage(writer: *std.Io.Writer, page: Page, rows: []const u8, first: bool) !void {
    const g = geometry(page);
    if (rows.len != @as(usize, g.width) * g.height * 3) return error.RasterSizeMismatch;
    if (first) try writer.writeAll(sync_v3_little);
    const h = header(page);
    try writer.writeAll(&h);
    try writer.writeAll(rows);
}

test "headers match what macOS's filter writes for the same pages" {
    // US Letter at 360 dpi with the ET-8500's 8.4 pt margins: cgpdftoraster
    // gave a 2976 x 3876 raster, bounding box 8 8 603 783.
    const letter = Page{ .width_pt = 612, .height_pt = 792, .imageable = .{ 8.4, 8.4, 603.6, 783.6 }, .dpi = 360 };
    const g = geometry(letter);
    try std.testing.expectEqual(@as(u32, 2976), g.width);
    try std.testing.expectEqual(@as(u32, 3876), g.height);
    const h = header(letter);
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, h[284..288], .little));
    try std.testing.expectEqual(@as(u32, 603), std.mem.readInt(u32, h[292..296], .little));
    try std.testing.expectEqual(@as(u32, 8928), std.mem.readInt(u32, h[392..396], .little));
    // Borderless Letter, scaled by 1.03: 630 x 815 pt, 3152 x 4079 px.
    const borderless = Page{ .width_pt = 612, .height_pt = 792, .imageable = .{ 0, 0, 612, 792 }, .borderless_scale = 1.03, .dpi = 360 };
    const gb = geometry(borderless);
    try std.testing.expectEqual(@as(u32, 3152), gb.width);
    try std.testing.expectEqual(@as(u32, 4079), gb.height);
    const hb = header(borderless);
    try std.testing.expectEqual(@as(u32, 630), std.mem.readInt(u32, hb[352..356], .little));
    try std.testing.expectEqual(@as(u32, 815), std.mem.readInt(u32, hb[356..360], .little));
    try std.testing.expectEqual(@as(f32, 612), @as(f32, @bitCast(std.mem.readInt(u32, hb[428..432], .little))));
}
