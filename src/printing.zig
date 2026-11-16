//! Colour-managed printing: the app converts each frame to the printer's
//! ICC profile for its paper and sends the driver raster with its own
//! colour adjustment off.

const std = @import("std");

pub const cups = @import("printing/cups.zig");
pub const job = @import("printing/job.zig");
pub const ppd = @import("printing/ppd.zig");
pub const raster = @import("printing/raster.zig");
pub const setup = @import("printing/setup.zig");

test {
    std.testing.refAllDecls(@This());
}
