const std = @import("std");

pub const Source = enum {
    flatbed,
    tpu,
};

pub const ScanKind = enum {
    rgb,
    gray,
    ir,
    rgb_ir,
};

pub const BitDepth = enum(u8) {
    eight = 8,
    sixteen = 16,
};

pub const AreaInches = struct {
    x: f64 = 0.0,
    y: f64 = 0.0,
    width: ?f64 = null,
    height: ?f64 = null,

    pub fn isExplicit(self: AreaInches) bool {
        return self.x != 0.0 or self.y != 0.0 or self.width != null or self.height != null;
    }
};

pub const ScanRequest = struct {
    pub const default_dpi: u32 = 3200;

    dpi: u32 = default_dpi,
    source: Source = .tpu,
    kind: ScanKind = .rgb,
    depth: BitDepth = .sixteen,
    area: AreaInches = .{},
    output_path: ?[]const u8 = null,
    lut_file_path: ?[]const u8 = null,

    pub fn channels(self: ScanRequest) u8 {
        return switch (self.kind) {
            .rgb => 3,
            .gray, .ir => 1,
            .rgb_ir => 4,
        };
    }
};

pub const ScannerCapabilities = struct {
    device_name: []const u8 = "",
    model: []const u8 = "Epson Perfection V600 Photo",
    optical_dpi: u32 = 1200,
    max_resolution: u32 = 6400,
    flatbed_width_in: f64 = 8.5,
    flatbed_height_in: f64 = 11.7,
    tpu_width_in: f64 = 68.58 / 25.4,
    tpu_height_in: f64 = 242.316 / 25.4,
    ir_supported: bool = true,
};

pub const Progress = struct {
    percent: u8,
    eta_seconds: u64,
};

pub const CancelState = enum {
    keep_scanning,
    cancel_requested,
};

pub const TiffPageLayout = struct {
    pub const rgb: usize = 0;
    pub const thumbnail: usize = 1;
    pub const ir: usize = 2;
};

pub const TiffMetadata = struct {
    make: []const u8 = "EPSON",
    model: []const u8 = "Epson Scanner",
    software: []const u8 = "v600-zig",
    dpi: u32,
    custom_luts_applied: bool = false,
};

test "scan request exposes channel count by kind" {
    try std.testing.expectEqual(@as(u8, 3), (ScanRequest{ .kind = .rgb }).channels());
    try std.testing.expectEqual(@as(u8, 1), (ScanRequest{ .kind = .gray }).channels());
    try std.testing.expectEqual(@as(u8, 1), (ScanRequest{ .kind = .ir }).channels());
    try std.testing.expectEqual(@as(u8, 4), (ScanRequest{ .kind = .rgb_ir }).channels());
}

test "explicit area detects any user-provided bound" {
    try std.testing.expect(!(AreaInches{}).isExplicit());
    try std.testing.expect((AreaInches{ .width = 1.0 }).isExplicit());
    try std.testing.expect((AreaInches{ .x = 0.25 }).isExplicit());
}
