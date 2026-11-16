//! A colour-managed print: an exported frame (any RGB TIFF with its ICC
//! profile) laid out on the page, resampled in linear light, converted to
//! the printer's profile for its paper, and written as the raster the
//! driver takes, so the driver's own colour adjustment can stay off.

const std = @import("std");

const icc = @import("../processing/icc.zig");
const parallelism = @import("../processing/parallelism.zig");
const rgb_space = @import("../processing/rgb_space.zig");
const tiff = @import("../tiff.zig");
const raster = @import("raster.zig");

/// The space prints are laid out in: linear Rec. 2020, wide enough for any
/// source the app writes.
const working: rgb_space.Space = .rec2020;

/// An image to print, in linear light in the working space.
pub const Source = struct {
    pixels: []f32,
    width: usize,
    height: usize,

    /// An RGB TIFF's first page, through its embedded ICC profile (sRGB
    /// when it has none).
    pub fn loadTiff(allocator: std.mem.Allocator, path: []const u8) !Source {
        const image = try tiff.loadRgbPage(allocator, path);
        defer image.deinit(allocator);
        if (image.samples_per_pixel != 3) return error.PrintSourceNotRgb;
        const embedded = try tiff.readIccProfile(allocator, path);
        defer if (embedded) |bytes| allocator.free(bytes);
        const profile = if (embedded) |bytes|
            try icc.Profile.openMemory(bytes)
        else
            try icc.spaceProfile(.srgb, .srgb_curve);
        defer profile.deinit();
        if (!profile.isRgb()) return error.PrintSourceNotRgb;
        const linear = try icc.spaceProfile(working, .linear);
        defer linear.deinit();
        const format: icc.Format = switch (image.bits_per_sample) {
            8 => .rgb_u8,
            16 => .rgb_u16,
            else => return error.PrintSourceDepthUnsupported,
        };
        const transform = try icc.Transform.init(profile, format, linear, .rgb_f32, .{ .intent = .relative_colorimetric, .black_point_compensation = false });
        defer transform.deinit();
        const width: usize = image.width;
        const height: usize = image.height;
        const pixels = try allocator.alloc(f32, width * height * 3);
        errdefer allocator.free(pixels);
        const Rows = struct {
            transform: icc.Transform,
            data: []const u8,
            pixels: []f32,
            width: usize,
            format: icc.Format,

            fn run(self: @This(), start: usize, end: usize) void {
                const out = self.pixels[start * self.width * 3 .. end * self.width * 3];
                switch (self.format) {
                    .rgb_u16 => {
                        const samples: []align(1) const u16 = std.mem.bytesAsSlice(u16, self.data);
                        self.transform.apply(samples[start * self.width * 3 .. end * self.width * 3], out, (end - start) * self.width);
                    },
                    else => self.transform.apply(self.data[start * self.width * 3 .. end * self.width * 3], out, (end - start) * self.width),
                }
            }
        };
        try parallelism.forRowBands(allocator, height, Rows{ .transform = transform, .data = image.data, .pixels = pixels, .width = width, .format = format }, Rows.run);
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    pub fn deinit(self: Source, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const Placement = struct {
    /// The print's sides, short and long, in inches: the image is fitted
    /// inside, turned to match. Null takes the whole printable area.
    size_in: ?[2]f64 = null,
    /// Fill that box, trimming the image's edges, instead of fitting it.
    fill: bool = false,
};

/// Where the image lands.
pub const Layout = struct {
    /// The printed image on the paper, points from its lower-left corner.
    rect: [4]f64,
    /// The image is turned a quarter for its long side to run along the
    /// paper's.
    turned: bool,
    /// The share of the image's width and height printed (below 1 when
    /// filling trims it).
    kept: [2]f64,
    /// The print's size in inches.
    size_in: [2]f64,
    /// Source pixels per printed inch, along the image's width.
    source_ppi: f64,
    /// The requested size did not fit the printable area and was shrunk.
    shrunk: bool,
};

pub fn layout(page: raster.Page, width: usize, height: usize, placement: Placement) Layout {
    // Borderless, the driver crops the raster's overscan at the paper's
    // edges, so the whole layout scales up by it, as macOS's filter does.
    const borderless = page.borderless_scale > 1.0;
    const overscan = if (borderless) page.borderless_scale else 1.0;
    const area: [4]f64 = if (borderless) raster.geometry(page).area else page.imageable;
    const area_w = area[2] - area[0];
    const area_h = area[3] - area[1];
    const image_landscape = width > height;
    const paper_landscape = page.width_pt > page.height_pt;
    const turned = image_landscape != paper_landscape and width != height;
    const img_w: f64 = @floatFromInt(if (turned) height else width);
    const img_h: f64 = @floatFromInt(if (turned) width else height);
    var box_w = area_w;
    var box_h = area_h;
    if (placement.size_in) |sides| {
        // The box's long side along the paper's long side.
        const long = sides[1] * 72.0 * overscan;
        const short = sides[0] * 72.0 * overscan;
        if (paper_landscape) {
            box_w = long;
            box_h = short;
        } else {
            box_w = short;
            box_h = long;
        }
    }
    var shrunk = false;
    if (box_w > area_w + 0.5 or box_h > area_h + 0.5) {
        const s = @min(area_w / box_w, area_h / box_h);
        box_w *= s;
        box_h *= s;
        shrunk = true;
    }
    const fit_scale = @min(box_w / img_w, box_h / img_h);
    const fill_scale = @max(box_w / img_w, box_h / img_h);
    const scale = if (placement.fill) fill_scale else fit_scale;
    const print_w = if (placement.fill) box_w else img_w * scale;
    const print_h = if (placement.fill) box_h else img_h * scale;
    const kept = [2]f64{ @min(1.0, print_w / (img_w * scale)), @min(1.0, print_h / (img_h * scale)) };
    const x0 = area[0] + (area_w - print_w) / 2.0;
    const y0 = area[1] + (area_h - print_h) / 2.0;
    return .{
        .rect = .{ x0, y0, x0 + print_w, y0 + print_h },
        .turned = turned,
        .kept = if (turned) .{ kept[1], kept[0] } else kept,
        .size_in = .{ print_w / 72.0 / overscan, print_h / 72.0 / overscan },
        .source_ppi = 72.0 * overscan / scale,
        .shrunk = shrunk,
    };
}

pub const Settings = struct {
    page: raster.Page,
    placement: Placement = .{},
    /// The printer's ICC profile for the paper, used with the driver's
    /// colour adjustment off.
    profile: icc.Profile,
    color: icc.Options = .{ .intent = .relative_colorimetric, .black_point_compensation = true },
};

const band_rows = 512;

/// Writes the page as CUPS raster to `sink` (anything with
/// `write([]const u8) !void`), a band of rows at a time.
pub fn writeRaster(allocator: std.mem.Allocator, source: *const Source, settings: Settings, sink: anytype) !void {
    const page = settings.page;
    const g = raster.geometry(page);
    const placed = layout(page, source.width, source.height, settings.placement);
    const linear = try icc.spaceProfile(working, .linear);
    defer linear.deinit();
    const transform = try icc.Transform.init(linear, .rgb_f32, settings.profile, .rgb_f32, settings.color);
    defer transform.deinit();

    try sink.write(raster.sync_v3_little);
    const header = raster.header(page);
    try sink.write(&header);

    const dpi: f64 = @floatFromInt(page.dpi);
    // The image's rectangle in raster pixels (y down from the raster's top).
    const rect = [4]f64{
        (placed.rect[0] - g.area[0]) / 72.0 * dpi,
        (g.area[3] - placed.rect[3]) / 72.0 * dpi,
        (placed.rect[2] - g.area[0]) / 72.0 * dpi,
        (g.area[3] - placed.rect[1]) / 72.0 * dpi,
    };
    const width: usize = g.width;
    const band = try allocator.alloc(u8, width * 3 * band_rows);
    defer allocator.free(band);
    var row: usize = 0;
    while (row < g.height) : (row += band_rows) {
        const rows: usize = @min(band_rows, g.height - row);
        const Band = struct {
            source: *const Source,
            placed: Layout,
            rect: [4]f64,
            transform: icc.Transform,
            out: []u8,
            width: usize,
            first_row: usize,

            fn run(self: @This(), start: usize, end: usize) void {
                var scratch: [2][4096 * 3]f32 = undefined;
                for (start..end) |r| {
                    const line = self.out[r * self.width * 3 ..][0 .. self.width * 3];
                    @memset(line, 255);
                    const y = @as(f64, @floatFromInt(self.first_row + r)) + 0.5;
                    if (y < self.rect[1] or y >= self.rect[3]) continue;
                    const x_lo: usize = @intFromFloat(@max(0.0, @ceil(self.rect[0] - 0.5)));
                    const x_hi: usize = @min(self.width, @as(usize, @intFromFloat(@max(0.0, @ceil(self.rect[2] - 0.5)))));
                    var x = x_lo;
                    while (x < x_hi) {
                        const n: usize = @min(4096, x_hi - x);
                        for (0..n) |i| {
                            const px = @as(f64, @floatFromInt(x + i)) + 0.5;
                            const rgb = sample(self.source, self.placed, self.rect, px, y);
                            scratch[0][i * 3 ..][0..3].* = rgb;
                        }
                        self.transform.apply(scratch[0][0 .. n * 3], scratch[1][0 .. n * 3], n);
                        for (0..n * 3) |i| {
                            const noise = ditherNoise(self.first_row + r, x * 3 + i);
                            const v = std.math.clamp(scratch[1][i], 0.0, 1.0) * 255.0 + noise;
                            line[x * 3 + i] = @intFromFloat(std.math.clamp(@floor(v), 0.0, 255.0));
                        }
                        x += n;
                    }
                }
            }
        };
        const ctx = Band{
            .source = source,
            .placed = placed,
            .rect = rect,
            .transform = transform,
            .out = band,
            .width = width,
            .first_row = row,
        };
        try parallelism.forRowBands(allocator, rows, ctx, Band.run);
        try sink.write(band[0 .. rows * width * 3]);
    }
}

/// The image at raster position (px, py), in linear light: a tent filter
/// as wide as a printed pixel's footprint on the image (at least a source
/// pixel), so downscaling averages and upscaling interpolates.
fn sample(source: *const Source, placed: Layout, rect: [4]f64, px: f64, py: f64) [3]f32 {
    const turned = placed.turned;
    const img_w: f64 = @floatFromInt(if (turned) source.height else source.width);
    const img_h: f64 = @floatFromInt(if (turned) source.width else source.height);
    // Position in the (turned) image, with the trimmed share centred.
    const fx = (px - rect[0]) / (rect[2] - rect[0]);
    const fy = (py - rect[1]) / (rect[3] - rect[1]);
    const kept_x = if (turned) placed.kept[1] else placed.kept[0];
    const kept_y = if (turned) placed.kept[0] else placed.kept[1];
    const u = ((1.0 - kept_x) / 2.0 + fx * kept_x) * img_w;
    const v = ((1.0 - kept_y) / 2.0 + fy * kept_y) * img_h;
    const step_u = kept_x * img_w / (rect[2] - rect[0]);
    const step_v = kept_y * img_h / (rect[3] - rect[1]);
    const ru = @max(1.0, step_u);
    const rv = @max(1.0, step_v);
    var acc = [3]f64{ 0, 0, 0 };
    var total: f64 = 0.0;
    const u_lo: i64 = @intFromFloat(@floor(u - ru));
    const u_hi: i64 = @intFromFloat(@ceil(u + ru));
    const v_lo: i64 = @intFromFloat(@floor(v - rv));
    const v_hi: i64 = @intFromFloat(@ceil(v + rv));
    var j = v_lo;
    while (j <= v_hi) : (j += 1) {
        const wv = 1.0 - @abs(@as(f64, @floatFromInt(j)) + 0.5 - v) / rv;
        if (wv <= 0.0) continue;
        const jj: usize = @intCast(std.math.clamp(j, 0, @as(i64, @intFromFloat(img_h)) - 1));
        var i = u_lo;
        while (i <= u_hi) : (i += 1) {
            const wu = 1.0 - @abs(@as(f64, @floatFromInt(i)) + 0.5 - u) / ru;
            if (wu <= 0.0) continue;
            const ii: usize = @intCast(std.math.clamp(i, 0, @as(i64, @intFromFloat(img_w)) - 1));
            // A turned image is the source a quarter turn clockwise.
            const sx = if (turned) jj else ii;
            const sy = if (turned) source.height - 1 - ii else jj;
            const p = source.pixels[(sy * source.width + sx) * 3 ..][0..3];
            const w = wu * wv;
            acc[0] += w * p[0];
            acc[1] += w * p[1];
            acc[2] += w * p[2];
            total += w;
        }
    }
    return .{ @floatCast(acc[0] / total), @floatCast(acc[1] / total), @floatCast(acc[2] / total) };
}

/// Uniform 0..1 noise per sample, so 8-bit steps do not band.
fn ditherNoise(row: usize, column: usize) f32 {
    var z: u64 = (@as(u64, row) << 32) ^ @as(u64, column);
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    z ^= z >> 31;
    return @as(f32, @floatFromInt(z >> 40)) / @as(f32, 1 << 24);
}

test "a frame is fitted on the page, turned to match, and resampled in linear light" {
    const allocator = std.testing.allocator;
    // Letter at 360 dpi with 8.4 pt margins; a landscape 60 x 40 image of
    // mid grey, 8x10 in: turned, 8 in wide.
    const page = raster.Page{ .width_pt = 612, .height_pt = 792, .imageable = .{ 8.4, 8.4, 603.6, 783.6 }, .dpi = 36 };
    const placed = layout(page, 60, 40, .{ .size_in = .{ 8, 10 } });
    // Turned, 2:3 fitted inside 8 x 10: 6.67 x 10 in.
    try std.testing.expect(placed.turned);
    try std.testing.expectApproxEqAbs(@as(f64, 20.0 / 3.0), placed.size_in[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), placed.size_in[1], 1e-9);
    try std.testing.expect(!placed.shrunk);
    const filled = layout(page, 60, 40, .{ .size_in = .{ 8, 10 }, .fill = true });
    try std.testing.expectApproxEqAbs(@as(f64, 8.0), filled.size_in[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), filled.size_in[1], 1e-9);

    var pixels: [60 * 40 * 3]f32 = undefined;
    @memset(&pixels, 0.18);
    const source = Source{ .pixels = &pixels, .width = 60, .height = 40 };
    const profile = try icc.spaceProfile(.srgb, .srgb_curve);
    defer profile.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const Sink = struct {
        list: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        pub fn write(self: @This(), bytes: []const u8) !void {
            try self.list.appendSlice(self.allocator, bytes);
        }
    };
    try writeRaster(allocator, &source, .{ .page = page, .placement = .{ .size_in = .{ 8, 10 }, .fill = true }, .profile = profile }, Sink{ .list = &out, .allocator = allocator });
    const g = raster.geometry(page);
    try std.testing.expectEqual(4 + raster.header_size + @as(usize, g.width) * g.height * 3, out.items.len);
    const rows = out.items[4 + raster.header_size ..];
    // The page's middle is 18% grey in sRGB (118), dithered within a level;
    // its corner is paper white.
    const middle = rows[(g.height / 2 * g.width + g.width / 2) * 3];
    try std.testing.expect(middle >= 117 and middle <= 119);
    try std.testing.expectEqual(@as(u8, 255), rows[0]);

    // A page wider than a row's conversion chunk prints across its width.
    const strip = raster.Page{ .width_pt = 612, .height_pt = 20, .imageable = .{ 0, 0, 612, 20 }, .dpi = 720 };
    out.clearRetainingCapacity();
    try writeRaster(allocator, &source, .{ .page = strip, .placement = .{ .fill = true }, .profile = profile }, Sink{ .list = &out, .allocator = allocator });
    const wide = raster.geometry(strip);
    try std.testing.expect(wide.width > 4096);
    const line = out.items[4 + raster.header_size + (wide.height / 2) * wide.width * 3 ..][0 .. wide.width * 3];
    for (0..wide.width) |x| try std.testing.expect(line[x * 3] < 200);
}

const cups = @import("cups.zig");
const ppd = @import("ppd.zig");
const setup = @import("setup.zig");

/// A print to make: the queue, the driver choices (paper, quality, size;
/// the driver's colour adjustment is turned off on top of them), the
/// paper's profile, and the layout.
pub const Request = struct {
    queue: []const u8,
    choices: []const setup.Chosen = &.{},
    /// An ICC profile file for the paper; null takes the driver's profile
    /// that matches the chosen paper.
    profile_path: ?[]const u8 = null,
    placement: Placement = .{},
    color: icc.Options = .{ .intent = .relative_colorimetric, .black_point_compensation = true },
    copies: u32 = 1,
    /// Read the printer's options from this PPD instead of the queue's.
    ppd_path: ?[]const u8 = null,
};

/// A request resolved against the printer's PPD.
pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    file: ppd.Ppd,
    /// Every choice the job sends, the colour-off one included.
    chosen: []const setup.Chosen,
    color_off: ?setup.Chosen,
    page: raster.Page,
    profile_path: []const u8,
    profile_label: []const u8,

    pub fn deinit(self: *Prepared) void {
        self.file.deinit();
        self.arena.deinit();
    }
};

pub fn prepare(allocator: std.mem.Allocator, io: std.Io, request: Request) !Prepared {
    var file = if (request.ppd_path) |path|
        try ppd.load(allocator, io, path)
    else blk: {
        const path = try cups.ppdPath(allocator, request.queue);
        defer allocator.free(path);
        defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
        break :blk try ppd.load(allocator, io, path);
    };
    errdefer file.deinit();
    if (!file.takesRaster()) return error.PrinterTakesNoRaster;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var chosen: std.ArrayList(setup.Chosen) = .empty;
    for (request.choices) |choice| {
        const option = file.option(choice.keyword) orelse return error.PrintOptionUnknown;
        _ = option.choice(choice.choice) orelse return error.PrintChoiceUnknown;
        try chosen.append(a, .{ .keyword = try a.dupe(u8, choice.keyword), .choice = try a.dupe(u8, choice.choice) });
    }
    const color_off = setup.colorOff(&file);
    if (color_off) |off| {
        for (chosen.items) |*item| {
            if (std.mem.eql(u8, item.keyword, off.keyword)) item.choice = off.choice;
        } else try chosen.append(a, off);
    }
    const page = try setup.page(&file, chosen.items);

    var profile_path: []const u8 = undefined;
    var profile_label: []const u8 = undefined;
    if (request.profile_path) |path| {
        profile_path = try a.dupe(u8, path);
        profile_label = std.fs.path.basename(profile_path);
    } else {
        const media = setup.mediaOption(&file) orelse return error.PrintNoProfile;
        const media_choice = setup.choiceFor(&file, chosen.items, media.keyword) orelse return error.PrintNoProfile;
        const label = (media.choice(media_choice) orelse return error.PrintNoProfile).label;
        const index = setup.suggestProfile(file.profiles, label) orelse return error.PrintNoProfile;
        profile_path = file.profiles[index].path;
        profile_label = file.profiles[index].label;
    }
    return .{
        .arena = arena,
        .file = file,
        .chosen = chosen.items,
        .color_off = color_off,
        .page = page,
        .profile_path = profile_path,
        .profile_label = profile_label,
    };
}

/// Writes the page's raster to `path`, for checking a print without
/// printing it.
pub fn writeFile(allocator: std.mem.Allocator, io: std.Io, prepared: *const Prepared, source: *const Source, request: Request, path: []const u8) !void {
    const profile = try icc.Profile.openFile(prepared.profile_path);
    defer profile.deinit();
    const out = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer out.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = out.writer(io, &buffer);
    const Sink = struct {
        writer: *std.Io.Writer,
        pub fn write(self: @This(), bytes: []const u8) !void {
            try self.writer.writeAll(bytes);
        }
    };
    try writeRaster(allocator, source, .{ .page = prepared.page, .placement = request.placement, .profile = profile, .color = request.color }, Sink{ .writer = &writer.interface });
    try writer.interface.flush();
}

/// Sends the print to the queue; returns the job's id.
pub fn submit(allocator: std.mem.Allocator, prepared: *const Prepared, source: *const Source, request: Request, title: []const u8) !i32 {
    const profile = try icc.Profile.openFile(prepared.profile_path);
    defer profile.deinit();
    var options: std.ArrayList(cups.JobOption) = .empty;
    defer options.deinit(allocator);
    for (prepared.chosen) |item| try options.append(allocator, .{ .name = item.keyword, .value = item.choice });
    var copies_buffer: [16]u8 = undefined;
    try options.append(allocator, .{ .name = "copies", .value = try std.fmt.bufPrint(&copies_buffer, "{d}", .{request.copies}) });
    var submission = try cups.Submission.create(allocator, request.queue, title, options.items, "application/vnd.cups-raster");
    const Sink = struct {
        submission: *cups.Submission,
        pub fn write(self: @This(), bytes: []const u8) !void {
            try self.submission.write(bytes);
        }
    };
    writeRaster(allocator, source, .{ .page = prepared.page, .placement = request.placement, .profile = profile, .color = request.color }, Sink{ .submission = &submission }) catch |err| {
        submission.cancel();
        return err;
    };
    return submission.finish();
}
