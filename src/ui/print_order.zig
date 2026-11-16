//! A print to make once a frame's export is written: the printer, its
//! driver choices, the paper's profile, and the layout, held in fixed
//! buffers so the export worker can take a copy.

const std = @import("std");

const icc = @import("../processing/icc.zig");
const printing = @import("../printing.zig");

fn Fixed(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *@This(), text: []const u8) !void {
            if (text.len > capacity) return error.PrintSettingTooLong;
            @memcpy(self.bytes[0..text.len], text);
            self.len = text.len;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const max_choices = 16;

pub const PrintOrder = struct {
    queue: Fixed(256) = .{},
    keywords: [max_choices]Fixed(64) = undefined,
    choices: [max_choices]Fixed(64) = undefined,
    choice_count: usize = 0,
    /// Empty takes the driver's profile for the chosen paper.
    profile_path: Fixed(std.fs.max_path_bytes) = .{},
    placement: printing.job.Placement = .{},
    color: icc.Options = .{},
    copies: u32 = 1,

    pub fn addChoice(self: *PrintOrder, keyword: []const u8, choice: []const u8) !void {
        if (self.choice_count == max_choices) return error.TooManyPrintChoices;
        var k: Fixed(64) = .{};
        var v: Fixed(64) = .{};
        try k.set(keyword);
        try v.set(choice);
        self.keywords[self.choice_count] = k;
        self.choices[self.choice_count] = v;
        self.choice_count += 1;
    }

    /// The request, its choices in `buffer`.
    pub fn request(self: *const PrintOrder, buffer: *[max_choices]printing.setup.Chosen) printing.job.Request {
        for (0..self.choice_count) |i| buffer[i] = .{ .keyword = self.keywords[i].slice(), .choice = self.choices[i].slice() };
        return .{
            .queue = self.queue.slice(),
            .choices = buffer[0..self.choice_count],
            .profile_path = if (self.profile_path.len == 0) null else self.profile_path.slice(),
            .placement = self.placement,
            .color = self.color,
            .copies = self.copies,
        };
    }
};

/// The positive to print among an export's files: the dust-cleaned one
/// (no suffix) before the plain inversion (`_inv`); never the negative.
pub fn positiveTiff(files: []const []const u8) ?[]const u8 {
    var fallback: ?[]const u8 = null;
    for (files) |file| {
        if (!std.mem.endsWith(u8, file, ".tif")) continue;
        if (std.mem.endsWith(u8, file, "_ir.tif")) continue;
        if (std.mem.endsWith(u8, file, "_inv.tif")) {
            if (fallback == null) fallback = file;
            continue;
        }
        return file;
    }
    return fallback;
}

/// Prints `tiff_path` as `order` says; returns the job's id.
pub fn run(allocator: std.mem.Allocator, io: std.Io, order: *const PrintOrder, tiff_path: []const u8) !i32 {
    var buffer: [max_choices]printing.setup.Chosen = undefined;
    const request = order.request(&buffer);
    var prepared = try printing.job.prepare(allocator, io, request);
    defer prepared.deinit();
    const source = try printing.job.Source.loadTiff(allocator, tiff_path);
    defer source.deinit(allocator);
    return printing.job.submit(allocator, &prepared, &source, request, std.fs.path.basename(tiff_path));
}

test "the dust-cleaned positive is printed, else the plain one" {
    try std.testing.expectEqualStrings("a_01.tif", positiveTiff(&.{ "a_01_ir.tif", "a_01_inv.tif", "a_01.tif", "a_01_8x10_360dpi.jpg" }).?);
    try std.testing.expectEqualStrings("a_01_inv.tif", positiveTiff(&.{ "a_01_ir.tif", "a_01_inv.tif" }).?);
    try std.testing.expect(positiveTiff(&.{"a_01_ir.tif"}) == null);
}
