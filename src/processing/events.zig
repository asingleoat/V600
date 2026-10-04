const std = @import("std");

pub const schema = "cerealgrain.processing.event.v1";

pub const EventName = enum {
    export_start,
    export_progress,
    file_written,
    export_complete,
    export_cancelled,
    processing_error,
};

pub const ExportStartEvent = struct {
    frame_count: usize,
    output_dir: []const u8,
};

pub const ExportProgressEvent = struct {
    message: []const u8,
};

pub const FileWrittenEvent = struct {
    file: []const u8,
};

pub const ExportCompleteEvent = struct {
    file_count: usize,
    output_dir: []const u8,
};

pub const ExportCancelledEvent = struct {
    detail: []const u8,
};

pub const ProcessingErrorEvent = struct {
    operation: []const u8,
    detail: []const u8,
};

pub fn eventName(value: EventName) []const u8 {
    return switch (value) {
        .export_start => "export-start",
        .export_progress => "export-progress",
        .file_written => "file-written",
        .export_complete => "export-complete",
        .export_cancelled => "export-cancelled",
        .processing_error => "processing-error",
    };
}

pub fn writeExportStart(out: anytype, event: ExportStartEvent) !void {
    try begin(out, .export_start);
    try writeUsizeField(out, "frame_count", event.frame_count);
    try writeStringField(out, "output_dir", event.output_dir);
    try out.print("}}\n", .{});
}

pub fn writeExportProgress(out: anytype, event: ExportProgressEvent) !void {
    try begin(out, .export_progress);
    try writeStringField(out, "message", event.message);
    try out.print("}}\n", .{});
}

pub fn writeFileWritten(out: anytype, event: FileWrittenEvent) !void {
    try begin(out, .file_written);
    try writeStringField(out, "file", event.file);
    try out.print("}}\n", .{});
}

pub fn writeExportComplete(out: anytype, event: ExportCompleteEvent) !void {
    try begin(out, .export_complete);
    try writeUsizeField(out, "file_count", event.file_count);
    try writeStringField(out, "output_dir", event.output_dir);
    try out.print("}}\n", .{});
}

pub fn writeExportCancelled(out: anytype, event: ExportCancelledEvent) !void {
    try begin(out, .export_cancelled);
    try writeStringField(out, "detail", event.detail);
    try out.print("}}\n", .{});
}

pub fn writeProcessingError(out: anytype, event: ProcessingErrorEvent) !void {
    try begin(out, .processing_error);
    try writeStringField(out, "operation", event.operation);
    try writeStringField(out, "detail", event.detail);
    try out.print("}}\n", .{});
}

pub fn emitExportStart(event: ExportStartEvent) void {
    var out = DebugWriter{};
    writeExportStart(&out, event) catch {};
}

pub fn emitExportProgress(event: ExportProgressEvent) void {
    var out = DebugWriter{};
    writeExportProgress(&out, event) catch {};
}

pub fn emitFileWritten(event: FileWrittenEvent) void {
    var out = DebugWriter{};
    writeFileWritten(&out, event) catch {};
}

pub fn emitExportComplete(event: ExportCompleteEvent) void {
    var out = DebugWriter{};
    writeExportComplete(&out, event) catch {};
}

pub fn emitExportCancelled(event: ExportCancelledEvent) void {
    var out = DebugWriter{};
    writeExportCancelled(&out, event) catch {};
}

pub fn emitProcessingError(event: ProcessingErrorEvent) void {
    var out = DebugWriter{};
    writeProcessingError(&out, event) catch {};
}

fn begin(out: anytype, name: EventName) !void {
    try out.print("{{\"event\":", .{});
    try writeJsonString(out, eventName(name));
    try out.print(",\"schema\":", .{});
    try writeJsonString(out, schema);
}

fn writeStringField(out: anytype, name: []const u8, value: []const u8) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":", .{});
    try writeJsonString(out, value);
}

fn writeUsizeField(out: anytype, name: []const u8, value: usize) !void {
    try out.print(",", .{});
    try writeJsonString(out, name);
    try out.print(":{d}", .{value});
}

fn writeJsonString(out: anytype, value: []const u8) !void {
    try out.print("\"", .{});
    for (value) |byte| {
        switch (byte) {
            '"' => try out.print("\\\"", .{}),
            '\\' => try out.print("\\\\", .{}),
            '\n' => try out.print("\\n", .{}),
            '\r' => try out.print("\\r", .{}),
            '\t' => try out.print("\\t", .{}),
            else => try out.print("{c}", .{byte}),
        }
    }
    try out.print("\"", .{});
}

const DebugWriter = struct {
    pub fn print(_: *DebugWriter, comptime fmt: []const u8, args: anytype) !void {
        std.debug.print(fmt, args);
    }
};

const BufferWriter = struct {
    buffer: *std.array_list.Managed(u8),

    pub fn print(self: *BufferWriter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.buffer.allocator, fmt, args);
        defer self.buffer.allocator.free(text);
        try self.buffer.appendSlice(text);
    }
};

test "processing event names are stable" {
    try std.testing.expectEqualStrings("export-start", eventName(.export_start));
    try std.testing.expectEqualStrings("export-progress", eventName(.export_progress));
    try std.testing.expectEqualStrings("file-written", eventName(.file_written));
    try std.testing.expectEqualStrings("export-complete", eventName(.export_complete));
    try std.testing.expectEqualStrings("export-cancelled", eventName(.export_cancelled));
    try std.testing.expectEqualStrings("processing-error", eventName(.processing_error));
}

test "processing export events serialize as JSONL" {
    const allocator = std.testing.allocator;
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var out = BufferWriter{ .buffer = &buffer };
    try writeExportStart(&out, .{ .frame_count = 2, .output_dir = "frames" });
    try writeExportProgress(&out, .{ .message = "Processing 2 frames..." });
    try writeFileWritten(&out, .{ .file = "roll_01.tif" });
    try writeExportComplete(&out, .{ .file_count = 1, .output_dir = "frames" });
    try writeExportCancelled(&out, .{ .detail = "cancel file observed" });
    try std.testing.expectEqualStrings(
        \\{"event":"export-start","schema":"cerealgrain.processing.event.v1","frame_count":2,"output_dir":"frames"}
        \\{"event":"export-progress","schema":"cerealgrain.processing.event.v1","message":"Processing 2 frames..."}
        \\{"event":"file-written","schema":"cerealgrain.processing.event.v1","file":"roll_01.tif"}
        \\{"event":"export-complete","schema":"cerealgrain.processing.event.v1","file_count":1,"output_dir":"frames"}
        \\{"event":"export-cancelled","schema":"cerealgrain.processing.event.v1","detail":"cancel file observed"}
        \\
    , buffer.items);
}
