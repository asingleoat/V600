//! A print's setup from the printer's PPD: the page the chosen options
//! make, the driver option that turns its own colour adjustment off, the
//! options that pick the paper and the quality, and which of the driver's
//! ICC profiles fits the chosen paper.

const std = @import("std");

const ppd = @import("ppd.zig");
const raster = @import("raster.zig");

pub const Chosen = struct {
    keyword: []const u8,
    choice: []const u8,
};

/// The choice made for `keyword`: from `chosen`, else the PPD's default.
pub fn choiceFor(file: *const ppd.Ppd, chosen: []const Chosen, keyword: []const u8) ?[]const u8 {
    for (chosen) |item| if (std.mem.eql(u8, item.keyword, keyword)) return item.choice;
    const option = file.option(keyword) orelse return null;
    return option.default;
}

/// The page the choices make: the paper size, what every chosen choice's
/// code sets (resolution, borderless scaling, Epson's print mode), and the
/// raster's format, which must be 8-bit RGB.
pub fn page(file: *const ppd.Ppd, chosen: []const Chosen) !raster.Page {
    var device = ppd.PageDevice{};
    for (file.options) |*option| {
        const keyword = choiceFor(file, chosen, option.keyword) orelse continue;
        const choice = option.choice(keyword) orelse continue;
        device.apply(choice.code);
    }
    const size_name = choiceFor(file, chosen, "PageSize") orelse return error.PrintNoPageSize;
    const size = file.size(size_name) orelse return error.PrintNoPageSize;
    if (device.color_space) |space| if (space != 1) return error.PrinterNotRgb;
    if (device.bits_per_color) |bits| if (bits != 8) return error.PrinterNotRgb;
    const dpi: u32 = if (device.resolution) |r| r[0] else resolutionFromName(choiceFor(file, chosen, "Resolution")) orelse 300;
    return .{
        .width_pt = size.width_pt,
        .height_pt = size.height_pt,
        .imageable = size.imageable,
        .borderless_scale = device.borderless_scale orelse 1.0,
        .dpi = dpi,
        .compression = device.compression orelse 0,
        .media_type = device.media_type orelse 0,
        .size_name = size.name,
    };
}

fn resolutionFromName(name: ?[]const u8) ?u32 {
    const text = name orelse return null;
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return std.fmt.parseInt(u32, text[0..end], 10) catch null;
}

/// The choice that turns the driver's own colour adjustment off, which an
/// ICC-converted print needs: one named for it ("Off (No Color
/// Adjustment)", "No Color Matching", ...). Null when the PPD has none.
pub fn colorOff(file: *const ppd.Ppd) ?Chosen {
    const phrases = [_][]const u8{ "no color adjustment", "no colour adjustment", "no color management", "no color matching", "no colour management", "no color correction" };
    for (file.options) |option| {
        for (option.choices) |choice| {
            var lower: [256]u8 = undefined;
            const label = std.ascii.lowerString(lower[0..@min(lower.len, choice.label.len)], choice.label[0..@min(lower.len, choice.label.len)]);
            for (phrases) |phrase| {
                if (std.mem.indexOf(u8, label, phrase) != null) return .{ .keyword = option.keyword, .choice = choice.keyword };
            }
        }
    }
    return null;
}

/// The option that picks the paper: MediaType, or one labelled for it.
pub fn mediaOption(file: *const ppd.Ppd) ?*const ppd.Option {
    if (file.option("MediaType")) |option| return option;
    return labelled(file, &.{ "media type", "paper type" });
}

/// Every option that picks the paper (drivers may have a standard
/// MediaType beside their own, with the same choices): a paper choice is
/// set on each that has it.
pub fn paperOptions(file: *const ppd.Ppd, buffer: []*const ppd.Option) []*const ppd.Option {
    var count: usize = 0;
    for (file.options) |*option| {
        if (count == buffer.len) break;
        var lower: [128]u8 = undefined;
        const n = @min(lower.len, option.label.len);
        const label = std.ascii.lowerString(lower[0..n], option.label[0..n]);
        if (std.mem.eql(u8, option.keyword, "MediaType") or std.mem.eql(u8, label, "media type") or std.mem.eql(u8, label, "paper type")) {
            buffer[count] = option;
            count += 1;
        }
    }
    return buffer[0..count];
}

/// The option that picks print quality, or else the resolution.
pub fn qualityOption(file: *const ppd.Ppd) ?*const ppd.Option {
    return labelled(file, &.{"print quality"}) orelse file.option("Resolution");
}

fn labelled(file: *const ppd.Ppd, labels: []const []const u8) ?*const ppd.Option {
    for (file.options) |*option| {
        var lower: [128]u8 = undefined;
        const n = @min(lower.len, option.label.len);
        const label = std.ascii.lowerString(lower[0..n], option.label[0..n]);
        for (labels) |wanted| if (std.mem.eql(u8, label, wanted)) return option;
    }
    return null;
}

/// The words that tell papers apart: lower case, hyphens dropped, without
/// the ones every paper name has.
fn paperWords(text: []const u8, buffer: *[16][24]u8, lengths: *[16]usize) usize {
    const stop = [_][]const u8{ "paper", "photo", "epson", "series", "the", "for", "and", "of" };
    var count: usize = 0;
    var words = std.mem.tokenizeAny(u8, text, " /()-_,.");
    outer: while (words.next()) |word| {
        if (count == buffer.len) break;
        var n: usize = 0;
        for (word) |ch| {
            if (n == buffer[count].len) break;
            buffer[count][n] = std.ascii.toLower(ch);
            n += 1;
        }
        for (stop) |s| if (std.mem.eql(u8, buffer[count][0..n], s)) continue :outer;
        if (n < 2) continue;
        lengths[count] = n;
        count += 1;
    }
    return count;
}

/// The driver profile that best matches a paper (by the words in their
/// names), or null when none shares a word with it. Words every profile
/// has (the printer's model) do not count.
pub fn suggestProfile(profiles: []const ppd.Profile, paper: []const u8) ?usize {
    var paper_words: [16][24]u8 = undefined;
    var paper_lengths: [16]usize = undefined;
    // "Semi-Gloss" and "Semigloss" are one word.
    var joined: [256]u8 = undefined;
    const paper_joined = joinHyphens(paper, &joined);
    const paper_count = paperWords(paper_joined, &paper_words, &paper_lengths);
    var best: ?usize = null;
    var best_score: i32 = 0;
    for (profiles, 0..) |profile, index| {
        var words: [16][24]u8 = undefined;
        var lengths: [16]usize = undefined;
        var profile_joined: [256]u8 = undefined;
        const count = paperWords(joinHyphens(profile.label, &profile_joined), &words, &lengths);
        var score: i32 = 0;
        var first_matched = false;
        var first_seen = false;
        for (0..count) |w| {
            const word = words[w][0..lengths[w]];
            if (inEvery(profiles, word)) continue;
            var found = false;
            for (0..paper_count) |p| {
                if (std.mem.eql(u8, paper_words[p][0..paper_lengths[p]], word)) found = true;
            }
            if (!first_seen) {
                first_seen = true;
                first_matched = found and paper_count > 0 and std.mem.eql(u8, paper_words[0][0..paper_lengths[0]], word);
            }
            score += if (found) 10 else -3;
        }
        if (first_matched) score += 1;
        if (score > best_score) {
            best_score = score;
            best = index;
        }
    }
    return best;
}

fn joinHyphens(text: []const u8, buffer: *[256]u8) []const u8 {
    var n: usize = 0;
    for (text) |ch| {
        if (ch == '-') continue;
        if (n == buffer.len) break;
        buffer[n] = ch;
        n += 1;
    }
    return buffer[0..n];
}

fn inEvery(profiles: []const ppd.Profile, word: []const u8) bool {
    if (profiles.len < 2) return false;
    for (profiles) |profile| {
        var words: [16][24]u8 = undefined;
        var lengths: [16]usize = undefined;
        var joined: [256]u8 = undefined;
        const count = paperWords(joinHyphens(profile.label, &joined), &words, &lengths);
        var found = false;
        for (0..count) |w| if (std.mem.eql(u8, words[w][0..lengths[w]], word)) {
            found = true;
        };
        if (!found) return false;
    }
    return true;
}

test "Epson's papers find their profiles and the driver's colour adjustment turns off" {
    const names = [_][]const u8{ "Standard", "Ultra Glossy", "Premium Glossy", "Premium Semigloss", "Premium Luster", "Photo Glossy", "Matte", "Velvet Fine Art", "Photo Quality Ink Jet", "sRGB Profile" };
    var profiles: [names.len]ppd.Profile = undefined;
    var labels: [names.len][64]u8 = undefined;
    for (names, 0..) |name, i| {
        const label = try std.fmt.bufPrint(&labels[i], "EPSON ET-8500 L8160 Series {s}", .{name});
        profiles[i] = .{ .qualifier = "", .label = if (i == names.len - 1) name else label, .path = "" };
    }
    const cases = [_]struct { []const u8, ?usize }{
        .{ "Ultra Premium Photo Paper Glossy", 1 },
        .{ "Premium Photo Paper Glossy", 2 },
        .{ "Photo Paper Glossy", 5 },
        .{ "Premium Photo Paper Semi-Gloss", 3 },
        .{ "Ultra Premium Photo Paper Luster", 4 },
        .{ "Premium Presentation Paper Matte", 6 },
        .{ "Velvet Fine Art Paper", 7 },
        .{ "Envelope", null },
    };
    for (cases) |case| try std.testing.expectEqual(case[1], suggestProfile(&profiles, case[0]));

    const text =
        \\*OpenUI *EPIJ_CMat/Color Settings: PickOne
        \\*DefaultEPIJ_CMat: 0
        \\*EPIJ_CMat 0/Manual Settings: ""
        \\*EPIJ_CMat 3/Off (No Color Adjustment): ""
        \\*CloseUI: *EPIJ_CMat
        \\*OpenUI *EPIJ_Medi/Media Type: PickOne
        \\*DefaultEPIJ_Medi: 0
        \\*EPIJ_Medi 0/Plain Paper: ""
        \\*CloseUI: *EPIJ_Medi
        \\*OpenUI *PageSize: PickOne
        \\*DefaultPageSize: Letter
        \\*PageSize Letter/US Letter: "<</PageSize[612.00 792.00]/ImagingBBox null>>setpagedevice"
        \\*CloseUI: *PageSize
        \\*OpenUI *Resolution: PickOne
        \\*DefaultResolution: 360x360dpi
        \\*Resolution 360x360dpi/360x360dpi: "<</HWResolution[360 360]/cupsCompression 2>>setpagedevice"
        \\*Resolution 720x720dpi/720x720dpi: "<</HWResolution[720 720]/cupsCompression 3>>setpagedevice"
        \\*CloseUI: *Resolution
        \\*PaperDimension Letter/US Letter: "612.00 792.00"
        \\*ImageableArea Letter/US Letter: "8.40 8.40 603.60 783.60"
        \\
    ;
    var file = try ppd.parse(std.testing.allocator, text);
    defer file.deinit();
    const off = colorOff(&file).?;
    try std.testing.expectEqualStrings("EPIJ_CMat", off.keyword);
    try std.testing.expectEqualStrings("3", off.choice);
    try std.testing.expectEqualStrings("EPIJ_Medi", mediaOption(&file).?.keyword);
    const letter = try page(&file, &.{.{ .keyword = "Resolution", .choice = "720x720dpi" }});
    try std.testing.expectEqual(@as(u32, 720), letter.dpi);
    try std.testing.expectEqual(@as(u32, 3), letter.compression);
    try std.testing.expectEqual(@as(f64, 8.4), letter.imageable[0]);
}
