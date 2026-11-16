//! What a print queue's PPD file says about its printer: the options and
//! their choices (paper size, media, quality, colour handling), the paper
//! sizes, the ICC profiles the driver ships, and what each choice sets in the
//! raster page header (its setpagedevice code).

const std = @import("std");

pub const Choice = struct {
    keyword: []const u8,
    label: []const u8,
    /// PostScript the choice runs, often `<</Key value>>setpagedevice`.
    code: []const u8,
};

pub const Option = struct {
    keyword: []const u8,
    label: []const u8,
    default: []const u8,
    choices: []const Choice,

    pub fn choice(self: *const Option, keyword: []const u8) ?*const Choice {
        for (self.choices) |*item| if (std.mem.eql(u8, item.keyword, keyword)) return item;
        return null;
    }

    pub fn choiceIndex(self: *const Option, keyword: []const u8) ?usize {
        for (self.choices, 0..) |item, index| if (std.mem.eql(u8, item.keyword, keyword)) return index;
        return null;
    }
};

pub const Size = struct {
    name: []const u8,
    width_pt: f64,
    height_pt: f64,
    imageable: [4]f64,
};

pub const Profile = struct {
    /// ColorModel.MediaType.Resolution, as the PPD qualifies it.
    qualifier: []const u8,
    label: []const u8,
    path: []const u8,
};

pub const Ppd = struct {
    arena: std.heap.ArenaAllocator,
    nickname: []const u8,
    manufacturer: []const u8,
    options: []const Option,
    sizes: []const Size,
    profiles: []const Profile,
    /// The MIME types the queue's own filters take.
    filter_inputs: []const []const u8,

    pub fn deinit(self: *Ppd) void {
        self.arena.deinit();
    }

    pub fn option(self: *const Ppd, keyword: []const u8) ?*const Option {
        for (self.options) |*item| if (std.mem.eql(u8, item.keyword, keyword)) return item;
        return null;
    }

    pub fn size(self: *const Ppd, name: []const u8) ?Size {
        for (self.sizes) |item| if (std.mem.eql(u8, item.name, name)) return item;
        return null;
    }

    /// Whether the driver takes CUPS raster, which colour-managed printing
    /// sends.
    pub fn takesRaster(self: *const Ppd) bool {
        for (self.filter_inputs) |input| if (std.mem.eql(u8, input, "application/vnd.cups-raster")) return true;
        return false;
    }
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Ppd {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(text);
    return parse(allocator, text);
}

/// One `*Keyword Option/Label: value` statement; value keeps its quotes off.
const Statement = struct {
    keyword: []const u8,
    option: []const u8,
    label: []const u8,
    value: []const u8,
};

const Statements = struct {
    text: []const u8,
    position: usize = 0,

    fn next(self: *Statements) ?Statement {
        while (self.position < self.text.len) {
            const line_start = self.position;
            const line_end = std.mem.indexOfScalarPos(u8, self.text, line_start, '\n') orelse self.text.len;
            self.position = @min(self.text.len, line_end + 1);
            const line = std.mem.trimEnd(u8, self.text[line_start..line_end], "\r");
            if (line.len < 2 or line[0] != '*' or line[1] == '%') continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const head = line[1..colon];
            const space = std.mem.indexOfScalar(u8, head, ' ');
            const keyword = if (space) |at| head[0..at] else head;
            var option: []const u8 = "";
            var label: []const u8 = "";
            if (space) |at| {
                const spec = std.mem.trim(u8, head[at + 1 ..], " ");
                if (std.mem.indexOfScalar(u8, spec, '/')) |slash| {
                    option = spec[0..slash];
                    label = spec[slash + 1 ..];
                } else option = spec;
            }
            var value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (value.len > 0 and value[0] == '"') {
                // A quoted value runs to its closing quote, across lines.
                const open = line_start + (@intFromPtr(value.ptr) - @intFromPtr(line.ptr)) + 1;
                const close = std.mem.indexOfScalarPos(u8, self.text, open, '"') orelse self.text.len;
                value = self.text[open..close];
                const after = std.mem.indexOfScalarPos(u8, self.text, @min(self.text.len, close + 1), '\n') orelse self.text.len;
                self.position = @min(self.text.len, after + 1);
            }
            return .{ .keyword = keyword, .option = option, .label = label, .value = value };
        }
        return null;
    }
};

/// Translation strings write characters as `<hex>`.
fn decodeLabel(allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < label.len) {
        if (label[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, label, i, '>')) |close| {
                var j = i + 1;
                while (j + 1 < close) : (j += 2) {
                    const byte = std.fmt.parseInt(u8, label[j .. j + 2], 16) catch break;
                    try out.append(allocator, byte);
                } else {
                    i = close + 1;
                    continue;
                }
            }
        }
        try out.append(allocator, label[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn parseNumbers(comptime n: usize, text: []const u8) ?[n]f64 {
    var out: [n]f64 = undefined;
    var words = std.mem.tokenizeAny(u8, text, " \t");
    for (&out) |*value| {
        value.* = std.fmt.parseFloat(f64, words.next() orelse return null) catch return null;
    }
    return out;
}

pub fn parse(backing: std.mem.Allocator, text: []const u8) !Ppd {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var nickname: []const u8 = "";
    var manufacturer: []const u8 = "";
    var defaults: std.StringHashMapUnmanaged([]const u8) = .empty;
    var options: std.ArrayList(Option) = .empty;
    var choices: std.ArrayList(std.ArrayList(Choice)) = .empty;
    var dimensions: std.StringArrayHashMapUnmanaged([2]f64) = .empty;
    var imageable: std.StringHashMapUnmanaged([4]f64) = .empty;
    var profiles: std.ArrayList(Profile) = .empty;
    var filter_inputs: std.ArrayList([]const u8) = .empty;

    var statements = Statements{ .text = text };
    while (statements.next()) |s| {
        // Translations (*fr.Keyword) and anything else localized.
        if (std.mem.indexOfScalar(u8, s.keyword, '.') != null) continue;
        if (std.mem.eql(u8, s.keyword, "NickName")) {
            nickname = try allocator.dupe(u8, s.value);
        } else if (std.mem.eql(u8, s.keyword, "Manufacturer")) {
            manufacturer = try allocator.dupe(u8, s.value);
        } else if (std.mem.eql(u8, s.keyword, "OpenUI")) {
            const name = std.mem.trimStart(u8, s.option, "*");
            try options.append(allocator, .{
                .keyword = try allocator.dupe(u8, name),
                .label = try decodeLabel(allocator, if (s.label.len > 0) s.label else name),
                .default = "",
                .choices = &.{},
            });
            try choices.append(allocator, .empty);
        } else if (std.mem.startsWith(u8, s.keyword, "Default") and s.option.len == 0) {
            try defaults.put(allocator, try allocator.dupe(u8, s.keyword["Default".len..]), try allocator.dupe(u8, s.value));
        } else if (std.mem.eql(u8, s.keyword, "PaperDimension")) {
            if (parseNumbers(2, s.value)) |v| try dimensions.put(allocator, try allocator.dupe(u8, s.option), v);
        } else if (std.mem.eql(u8, s.keyword, "ImageableArea")) {
            if (parseNumbers(4, s.value)) |v| try imageable.put(allocator, try allocator.dupe(u8, s.option), v);
        } else if (std.mem.eql(u8, s.keyword, "cupsICCProfile")) {
            try profiles.append(allocator, .{
                .qualifier = try allocator.dupe(u8, s.option),
                .label = try decodeLabel(allocator, s.label),
                .path = try allocator.dupe(u8, s.value),
            });
        } else if (std.mem.eql(u8, s.keyword, "cupsFilter") or std.mem.eql(u8, s.keyword, "cupsFilter2")) {
            var words = std.mem.tokenizeScalar(u8, s.value, ' ');
            if (words.next()) |input| try filter_inputs.append(allocator, try allocator.dupe(u8, input));
        } else if (s.option.len > 0) {
            for (options.items, 0..) |item, index| {
                if (!std.mem.eql(u8, item.keyword, s.keyword)) continue;
                try choices.items[index].append(allocator, .{
                    .keyword = try allocator.dupe(u8, s.option),
                    .label = try decodeLabel(allocator, if (s.label.len > 0) s.label else s.option),
                    .code = try allocator.dupe(u8, s.value),
                });
                break;
            }
        }
    }

    for (options.items, choices.items) |*item, list| {
        item.choices = list.items;
        item.default = defaults.get(item.keyword) orelse if (list.items.len > 0) list.items[0].keyword else "";
    }
    var sizes: std.ArrayList(Size) = .empty;
    var it = dimensions.iterator();
    while (it.next()) |entry| {
        const dims = entry.value_ptr.*;
        try sizes.append(allocator, .{
            .name = entry.key_ptr.*,
            .width_pt = dims[0],
            .height_pt = dims[1],
            .imageable = imageable.get(entry.key_ptr.*) orelse .{ 0, 0, dims[0], dims[1] },
        });
    }
    return .{
        .arena = arena,
        .nickname = nickname,
        .manufacturer = manufacturer,
        .options = options.items,
        .sizes = sizes.items,
        .profiles = profiles.items,
        .filter_inputs = filter_inputs.items,
    };
}

/// What a choice's setpagedevice code sets that the raster header carries.
pub const PageDevice = struct {
    resolution: ?[2]u32 = null,
    page_size: ?[2]f64 = null,
    borderless_scale: ?f64 = null,
    compression: ?u32 = null,
    media_type: ?u32 = null,
    color_space: ?u32 = null,
    bits_per_color: ?u32 = null,

    /// Reads the keys it knows from `code`; later choices override earlier.
    pub fn apply(self: *PageDevice, code: []const u8) void {
        // Names start at '/', which may follow a value with no space
        // ("null/cupsBorderlessScalingFactor").
        var words = Words{ .inner = std.mem.tokenizeAny(u8, code, " \t\r\n<>[]") };
        while (words.next()) |word| {
            if (word.len < 2 or word[0] != '/') continue;
            const key = word[1..];
            if (std.mem.eql(u8, key, "HWResolution")) {
                const x = parseUnsigned(words.next()) orelse continue;
                const y = parseUnsigned(words.next()) orelse continue;
                self.resolution = .{ x, y };
            } else if (std.mem.eql(u8, key, "PageSize")) {
                const w = parseFloat(words.next()) orelse continue;
                const h = parseFloat(words.next()) orelse continue;
                self.page_size = .{ w, h };
            } else if (std.mem.eql(u8, key, "cupsBorderlessScalingFactor")) {
                self.borderless_scale = parseFloat(words.next()) orelse continue;
            } else if (std.mem.eql(u8, key, "cupsCompression")) {
                self.compression = parseUnsigned(words.next()) orelse continue;
            } else if (std.mem.eql(u8, key, "cupsMediaType")) {
                self.media_type = parseUnsigned(words.next()) orelse continue;
            } else if (std.mem.eql(u8, key, "cupsColorSpace")) {
                self.color_space = parseUnsigned(words.next()) orelse continue;
            } else if (std.mem.eql(u8, key, "cupsBitsPerColor")) {
                self.bits_per_color = parseUnsigned(words.next()) orelse continue;
            }
        }
    }

    const Words = struct {
        inner: std.mem.TokenIterator(u8, .any),
        rest: []const u8 = "",

        fn next(self: *Words) ?[]const u8 {
            if (self.rest.len == 0) self.rest = self.inner.next() orelse return null;
            const end = std.mem.indexOfScalarPos(u8, self.rest, 1, '/') orelse self.rest.len;
            const word = self.rest[0..end];
            self.rest = self.rest[end..];
            return word;
        }
    };

    fn parseUnsigned(word: ?[]const u8) ?u32 {
        return std.fmt.parseInt(u32, std.mem.trimEnd(u8, word orelse return null, ">"), 10) catch null;
    }

    fn parseFloat(word: ?[]const u8) ?f64 {
        return std.fmt.parseFloat(f64, word orelse return null) catch null;
    }
};

test "a PPD's options, sizes, profiles, and page device settings" {
    const text =
        \\*PPD-Adobe: "4.3"
        \\*NickName: "EPSON ET-8500 Series"
        \\*Manufacturer: "EPSON"
        \\*cupsFilter: "application/vnd.cups-raster 0 /Library/rastertoescpII"
        \\*cupsICCProfile ..3/EPSON ET-8500 Premium Glossy: "/Library/Premium Glossy.icc"
        \\*APPrinterPreset Preset_1/Photo: "
        \\*EPIJ_Medi 92
        \\*Resolution 720x720dpi"
        \\*End
        \\*OpenUI *EPIJ_Medi/Media Type: PickOne
        \\*DefaultEPIJ_Medi: 0
        \\*EPIJ_Medi 0/Plain Paper <2F> Bright White Paper: ""
        \\*EPIJ_Medi 13/Premium Photo Paper Glossy: ""
        \\*CloseUI: *EPIJ_Medi
        \\*fr.EPIJ_Medi 13/Papier photo glacé Premium: ""
        \\*OpenUI *Resolution/Resolution: PickOne
        \\*DefaultResolution: 360x360dpi
        \\*Resolution 360x360dpi/360x360dpi: "<</HWResolution[360 360]/cupsCompression 2>>setpagedevice"
        \\*Resolution 720x720dpi/720x720dpi: "<</HWResolution[720 720]/cupsCompression 3>>setpagedevice"
        \\*CloseUI: *Resolution
        \\*OpenUI *PageSize: PickOne
        \\*DefaultPageSize: Letter
        \\*PageSize Letter.NMgn/US Letter (Borderless): "<</PageSize[612.00 792.00]/ImagingBBox null/cupsBorderlessScalingFactor 1.03>>setpagedevice"
        \\*CloseUI: *PageSize
        \\*PaperDimension Letter.NMgn/US Letter (Borderless): "612.00 792.00"
        \\*ImageableArea Letter.NMgn/US Letter (Borderless): "0.00 0.00 612.00 792.00"
        \\
    ;
    var ppd = try parse(std.testing.allocator, text);
    defer ppd.deinit();
    try std.testing.expectEqualStrings("EPSON ET-8500 Series", ppd.nickname);
    try std.testing.expect(ppd.takesRaster());
    const media = ppd.option("EPIJ_Medi").?;
    try std.testing.expectEqualStrings("Media Type", media.label);
    try std.testing.expectEqual(@as(usize, 2), media.choices.len);
    try std.testing.expectEqualStrings("Plain Paper / Bright White Paper", media.choices[0].label);
    try std.testing.expectEqualStrings("0", media.default);
    try std.testing.expectEqualStrings("/Library/Premium Glossy.icc", ppd.profiles[0].path);
    try std.testing.expectEqualStrings("EPSON ET-8500 Premium Glossy", ppd.profiles[0].label);
    const letter = ppd.size("Letter.NMgn").?;
    try std.testing.expectEqual(@as(f64, 612), letter.width_pt);

    var device = PageDevice{};
    device.apply(ppd.option("Resolution").?.choice("720x720dpi").?.code);
    device.apply(ppd.option("PageSize").?.choice("Letter.NMgn").?.code);
    try std.testing.expectEqual([2]u32{ 720, 720 }, device.resolution.?);
    try std.testing.expectEqual(@as(u32, 3), device.compression.?);
    try std.testing.expectEqual(@as(f64, 1.03), device.borderless_scale.?);
    try std.testing.expectEqual([2]f64{ 612, 792 }, device.page_size.?);
}
