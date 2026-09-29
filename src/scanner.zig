const std = @import("std");
const builtin = @import("builtin");

pub const contracts = @import("scanner/contracts.zig");
pub const config = @import("scanner/config.zig");
pub const events = @import("scanner/events.zig");
pub const film_lut = @import("scanner/film_lut.zig");
pub const lut = @import("scanner/lut.zig");
pub const linux = @import("scanner/linux.zig");
pub const macos = @import("scanner/macos.zig");
pub const sane = @import("scanner/sane.zig");
pub const interpreter = @import("scanner/interpreter.zig");
pub const interpreter_runtime = @import("scanner/interpreter_runtime.zig");
pub const usb = @import("scanner/usb.zig");

/// The scanner runtime for this host: SANE subprocesses on Linux, the Epson
/// interpreter over libusb on macOS. Both expose `Runtime`, `ScanOptions`,
/// `Device`, `freeDevices`, `film_dpis`, and `effectiveDpiForRequest`.
pub const host = if (builtin.os.tag == .macos) interpreter_runtime else linux;

pub const BackendKind = enum {
    sane,
    interpreter,
};

pub fn backendKindForOs(os_tag: std.Target.Os.Tag) BackendKind {
    return switch (os_tag) {
        .linux => .sane,
        else => .interpreter,
    };
}

pub fn backendKindForCurrentHost() BackendKind {
    return backendKindForOs(builtin.os.tag);
}

test {
    _ = contracts;
    _ = config;
    _ = events;
    _ = film_lut;
    _ = lut;
    _ = linux;
    _ = macos;
    _ = sane;
    _ = interpreter;
    // Links libusb, which only macOS builds provide.
    if (comptime builtin.os.tag == .macos) _ = interpreter_runtime;
}

test "scanner backend dispatch matches Python EpsonScanner init platform split" {
    try std.testing.expectEqual(BackendKind.sane, backendKindForOs(.linux));
    try std.testing.expectEqual(BackendKind.interpreter, backendKindForOs(.macos));
    try std.testing.expectEqual(BackendKind.interpreter, backendKindForOs(.windows));
}
