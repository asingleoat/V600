//! libusb bulk transport for the interpreter backend. Finds a supported
//! Epson scanner, claims interface 0, and exposes its bulk endpoints as a
//! `macos.UsbIo` for the interpreter callbacks and the direct RS commands.

const std = @import("std");
const builtin = @import("builtin");

const macos = @import("macos.zig");
const models = @import("models.zig");

/// libusb is linked only on macOS, the one host that uses this transport.
pub const available = builtin.os.tag == .macos;

const c = if (available) @cImport(@cInclude("libusb.h")) else struct {};

pub const OpenError = error{
    UsbUnavailable,
    UsbInitFailed,
    ScannerNotFound,
    ScannerAccessDenied,
    ScannerBusy,
    ScannerOpenFailed,
    MissingBulkEndpoints,
};

pub const Found = struct {
    product_id: u16,
    bus: u8,
    address: u8,
};

pub const Device = struct {
    context: *c.libusb_context,
    handle: *c.libusb_device_handle,
    product_id: u16,
    endpoints: macos.UsbEndpointPair,

    /// Opens the first supported Epson scanner, or the one with `product_id`.
    pub fn open(product_id: ?u16) OpenError!Device {
        if (!available) return error.UsbUnavailable;

        var context: ?*c.libusb_context = null;
        if (c.libusb_init(&context) != 0) return error.UsbInitFailed;
        errdefer c.libusb_exit(context);

        var list: [*c]?*c.libusb_device = undefined;
        const count = c.libusb_get_device_list(context, &list);
        if (count < 0) return error.UsbInitFailed;
        defer c.libusb_free_device_list(list, 1);

        const device, const found_product_id = findScanner(list[0..@intCast(count)], product_id) orelse
            return error.ScannerNotFound;

        var handle: ?*c.libusb_device_handle = null;
        switch (c.libusb_open(device, &handle)) {
            0 => {},
            c.LIBUSB_ERROR_ACCESS => return error.ScannerAccessDenied,
            else => return error.ScannerOpenFailed,
        }
        errdefer c.libusb_close(handle);

        // Python's pyusb set_configuration(); skip it when configuration 1
        // is already active, which macOS may refuse to set again.
        var configuration: c_int = 0;
        if (c.libusb_get_configuration(handle, &configuration) != 0 or configuration != 1) {
            _ = c.libusb_set_configuration(handle, 1);
        }
        switch (c.libusb_claim_interface(handle, 0)) {
            0 => {},
            c.LIBUSB_ERROR_ACCESS => return error.ScannerAccessDenied,
            c.LIBUSB_ERROR_BUSY => return error.ScannerBusy,
            else => return error.ScannerOpenFailed,
        }
        errdefer _ = c.libusb_release_interface(handle, 0);

        const endpoints = try bulkEndpoints(device);
        return .{
            .context = context.?,
            .handle = handle.?,
            .product_id = found_product_id,
            .endpoints = endpoints,
        };
    }

    pub fn close(self: *Device) void {
        _ = c.libusb_release_interface(self.handle, 0);
        c.libusb_close(self.handle);
        c.libusb_exit(self.context);
        self.* = undefined;
    }

    pub fn io(self: *Device) macos.UsbIo {
        return .{ .context = self, .readFn = bulkRead, .writeFn = bulkWrite };
    }
};

/// Lists the supported Epson scanners on the bus without opening them.
pub fn listScanners(allocator: std.mem.Allocator) ![]Found {
    if (!available) return error.UsbUnavailable;

    var context: ?*c.libusb_context = null;
    if (c.libusb_init(&context) != 0) return error.UsbInitFailed;
    defer c.libusb_exit(context);

    var list: [*c]?*c.libusb_device = undefined;
    const count = c.libusb_get_device_list(context, &list);
    if (count < 0) return error.UsbInitFailed;
    defer c.libusb_free_device_list(list, 1);

    var found = std.array_list.Managed(Found).init(allocator);
    errdefer found.deinit();
    for (list[0..@intCast(count)]) |maybe_device| {
        const device = maybe_device orelse continue;
        const pid = supportedProductId(device) orelse continue;
        try found.append(.{
            .product_id = pid,
            .bus = c.libusb_get_bus_number(device),
            .address = c.libusb_get_device_address(device),
        });
    }
    return found.toOwnedSlice();
}

fn findScanner(devices: []?*c.libusb_device, wanted: ?u16) ?struct { *c.libusb_device, u16 } {
    for (devices) |maybe_device| {
        const device = maybe_device orelse continue;
        const pid = supportedProductId(device) orelse continue;
        if (wanted) |wanted_pid| {
            if (pid != wanted_pid) continue;
        }
        return .{ device, pid };
    }
    return null;
}

fn supportedProductId(device: *c.libusb_device) ?u16 {
    var descriptor: c.libusb_device_descriptor = undefined;
    if (c.libusb_get_device_descriptor(device, &descriptor) != 0) return null;
    if (descriptor.idVendor != models.epson_vendor_id) return null;
    if (models.forProductId(descriptor.idProduct) == null) return null;
    return descriptor.idProduct;
}

fn bulkEndpoints(device: *c.libusb_device) OpenError!macos.UsbEndpointPair {
    var config: ?*c.libusb_config_descriptor = null;
    if (c.libusb_get_active_config_descriptor(device, &config) != 0) return error.MissingBulkEndpoints;
    defer c.libusb_free_config_descriptor(config);

    const cfg = config.?;
    if (cfg.bNumInterfaces == 0) return error.MissingBulkEndpoints;
    const interface = cfg.interface[0];
    if (interface.num_altsetting == 0) return error.MissingBulkEndpoints;
    const setting = interface.altsetting[0];

    var addresses: [32]u8 = undefined;
    var len: usize = 0;
    for (setting.endpoint[0..setting.bNumEndpoints]) |endpoint| {
        if ((endpoint.bmAttributes & 0x03) != c.LIBUSB_TRANSFER_TYPE_BULK) continue;
        if (len == addresses.len) break;
        addresses[len] = endpoint.bEndpointAddress;
        len += 1;
    }
    return macos.selectEndpointPair(addresses[0..len]) orelse error.MissingBulkEndpoints;
}

fn bulkRead(context: *anyopaque, buffer: []u8, timeout_ms: u32) macos.UsbTransferError!usize {
    const device: *Device = @ptrCast(@alignCast(context));
    if (buffer.len > std.math.maxInt(c_int)) return error.UsbReadFailed;
    var transferred: c_int = 0;
    const rc = c.libusb_bulk_transfer(
        device.handle,
        device.endpoints.in_address,
        buffer.ptr,
        @intCast(buffer.len),
        &transferred,
        timeout_ms,
    );
    if (rc != 0) return error.UsbReadFailed;
    return @intCast(transferred);
}

fn bulkWrite(context: *anyopaque, data: []const u8, timeout_ms: u32) macos.UsbTransferError!void {
    const device: *Device = @ptrCast(@alignCast(context));
    if (data.len > std.math.maxInt(c_int)) return error.UsbWriteFailed;
    var offset: usize = 0;
    while (offset < data.len) {
        var transferred: c_int = 0;
        const rc = c.libusb_bulk_transfer(
            device.handle,
            device.endpoints.out_address,
            @constCast(data[offset..].ptr),
            @intCast(data.len - offset),
            &transferred,
            timeout_ms,
        );
        if (rc != 0) return error.UsbWriteFailed;
        if (transferred <= 0) return error.UsbWriteFailed;
        offset += @intCast(transferred);
    }
}
