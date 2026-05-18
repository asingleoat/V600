const std = @import("std");
const v600 = @import("v600");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const allow_no_adapter = if (init.environ_map.get("V600_WEBGPU_SMOKE_ALLOW_NO_ADAPTER")) |value|
        std.mem.eql(u8, value, "1")
    else
        false;

    try v600.processing.webgpu.runAdapterDeviceSmoke(stdout, .{
        .allow_no_adapter = allow_no_adapter,
    });
}
