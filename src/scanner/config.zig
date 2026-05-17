const std = @import("std");

pub const file_name = "epdaughter_config.toml";

pub const FixedString = struct {
    bytes: [64]u8 = [_]u8{0} ** 64,
    len: usize = 0,

    pub fn init(comptime value: []const u8) FixedString {
        var result = FixedString{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = value.len;
        return result;
    }

    pub fn set(self: *FixedString, value: []const u8) !void {
        if (value.len > self.bytes.len) return error.StringTooLong;
        @memcpy(self.bytes[0..value.len], value);
        self.len = value.len;
    }

    pub fn slice(self: *const FixedString) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const ScannerConfig = struct {
    dpi: u32 = 3200,
    mode: FixedString = FixedString.init("rgb+ir"),
    autoselect: bool = true,
    sel_x_in: f64 = 0.0,
    sel_y_in: f64 = 0.0,
    sel_w_in: f64 = 0.0,
    sel_h_in: f64 = 0.0,
    detect_pad: f64 = 0.05,
    detect_min_area: f64 = 0.05,
    preview_dpi: u32 = 200,
    port: u16 = 8432,
};

pub const ActiveKeys = struct {
    dpi: bool = false,
    mode: bool = false,
    autoselect: bool = false,
    sel_x_in: bool = false,
    sel_y_in: bool = false,
    sel_w_in: bool = false,
    sel_h_in: bool = false,
    detect_pad: bool = false,
    detect_min_area: bool = false,
    preview_dpi: bool = false,
    port: bool = false,
};

pub const LoadedConfig = struct {
    values: ScannerConfig = .{},
    active: ActiveKeys = .{},

    pub fn apply(self: *LoadedConfig, updates: LoadedConfig) void {
        if (updates.active.dpi) {
            self.values.dpi = updates.values.dpi;
            self.active.dpi = true;
        }
        if (updates.active.mode) {
            self.values.mode = updates.values.mode;
            self.active.mode = true;
        }
        if (updates.active.autoselect) {
            self.values.autoselect = updates.values.autoselect;
            self.active.autoselect = true;
        }
        if (updates.active.sel_x_in) {
            self.values.sel_x_in = updates.values.sel_x_in;
            self.active.sel_x_in = true;
        }
        if (updates.active.sel_y_in) {
            self.values.sel_y_in = updates.values.sel_y_in;
            self.active.sel_y_in = true;
        }
        if (updates.active.sel_w_in) {
            self.values.sel_w_in = updates.values.sel_w_in;
            self.active.sel_w_in = true;
        }
        if (updates.active.sel_h_in) {
            self.values.sel_h_in = updates.values.sel_h_in;
            self.active.sel_h_in = true;
        }
        if (updates.active.detect_pad) {
            self.values.detect_pad = updates.values.detect_pad;
            self.active.detect_pad = true;
        }
        if (updates.active.detect_min_area) {
            self.values.detect_min_area = updates.values.detect_min_area;
            self.active.detect_min_area = true;
        }
        if (updates.active.preview_dpi) {
            self.values.preview_dpi = updates.values.preview_dpi;
            self.active.preview_dpi = true;
        }
        if (updates.active.port) {
            self.values.port = updates.values.port;
            self.active.port = true;
        }
    }
};

const Param = enum {
    dpi,
    mode,
    autoselect,
    sel_x_in,
    sel_y_in,
    sel_w_in,
    sel_h_in,
    detect_pad,
    detect_min_area,
    preview_dpi,
    port,
};

pub fn parseText(text: []const u8) LoadedConfig {
    return parseTextStrict(text) catch .{};
}

fn parseTextStrict(text: []const u8) !LoadedConfig {
    var loaded = LoadedConfig{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return error.InvalidTomlSection;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidTomlLine;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const param = paramByKey(key) orelse continue;
        const value = std.mem.trim(u8, stripInlineComment(line[eq + 1 ..]), " \t");
        try applyValue(&loaded, param, value);
    }
    return loaded;
}

pub fn loadFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !LoadedConfig {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{};
    };
    defer allocator.free(data);
    return parseText(data);
}

pub fn saveFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    updates: LoadedConfig,
) !void {
    var current = try loadFile(allocator, io, path);
    current.apply(updates);
    const data = try serialize(allocator, current);
    defer allocator.free(data);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .truncate = true },
    });
}

pub fn serialize(allocator: std.mem.Allocator, loaded: LoadedConfig) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try appendSection(&out, "scan", loaded, &.{ .dpi, .mode, .autoselect });
    try appendSection(&out, "selection", loaded, &.{ .sel_x_in, .sel_y_in, .sel_w_in, .sel_h_in });
    try appendSection(&out, "detection", loaded, &.{ .detect_pad, .detect_min_area });
    try appendSection(&out, "preview", loaded, &.{.preview_dpi});
    try appendSection(&out, "server", loaded, &.{.port});

    return out.toOwnedSlice();
}

fn appendSection(
    out: *std.array_list.Managed(u8),
    section: []const u8,
    loaded: LoadedConfig,
    params: []const Param,
) !void {
    try out.print("\n[{s}]\n", .{section});
    for (params) |param| try appendParam(out, loaded, param);
}

fn appendParam(out: *std.array_list.Managed(u8), loaded: LoadedConfig, param: Param) !void {
    try out.print("{s}{s} = ", .{ if (isActive(loaded.active, param)) "" else "# ", keyName(param) });
    try appendTomlValue(out, loaded.values, param);
    try out.print("  # {s}\n", .{comment(param)});
}

fn appendTomlValue(out: *std.array_list.Managed(u8), values: ScannerConfig, param: Param) !void {
    switch (param) {
        .dpi => try out.print("{d}", .{values.dpi}),
        .mode => try out.print("\"{s}\"", .{values.mode.slice()}),
        .autoselect => try out.print("{s}", .{if (values.autoselect) "true" else "false"}),
        .sel_x_in => try appendFloat(out, values.sel_x_in),
        .sel_y_in => try appendFloat(out, values.sel_y_in),
        .sel_w_in => try appendFloat(out, values.sel_w_in),
        .sel_h_in => try appendFloat(out, values.sel_h_in),
        .detect_pad => try appendFloat(out, values.detect_pad),
        .detect_min_area => try appendFloat(out, values.detect_min_area),
        .preview_dpi => try out.print("{d}", .{values.preview_dpi}),
        .port => try out.print("{d}", .{values.port}),
    }
}

fn appendFloat(out: *std.array_list.Managed(u8), value: f64) !void {
    if (value == @floor(value)) {
        try out.print("{d:.1}", .{value});
    } else {
        try out.print("{d}", .{value});
    }
}

fn applyValue(loaded: *LoadedConfig, param: Param, value: []const u8) !void {
    switch (param) {
        .dpi => {
            loaded.values.dpi = try std.fmt.parseInt(u32, value, 10);
            loaded.active.dpi = true;
        },
        .mode => {
            try loaded.values.mode.set(try parseTomlString(value));
            loaded.active.mode = true;
        },
        .autoselect => {
            loaded.values.autoselect = try parseTomlBool(value);
            loaded.active.autoselect = true;
        },
        .sel_x_in => {
            loaded.values.sel_x_in = try std.fmt.parseFloat(f64, value);
            loaded.active.sel_x_in = true;
        },
        .sel_y_in => {
            loaded.values.sel_y_in = try std.fmt.parseFloat(f64, value);
            loaded.active.sel_y_in = true;
        },
        .sel_w_in => {
            loaded.values.sel_w_in = try std.fmt.parseFloat(f64, value);
            loaded.active.sel_w_in = true;
        },
        .sel_h_in => {
            loaded.values.sel_h_in = try std.fmt.parseFloat(f64, value);
            loaded.active.sel_h_in = true;
        },
        .detect_pad => {
            loaded.values.detect_pad = try std.fmt.parseFloat(f64, value);
            loaded.active.detect_pad = true;
        },
        .detect_min_area => {
            loaded.values.detect_min_area = try std.fmt.parseFloat(f64, value);
            loaded.active.detect_min_area = true;
        },
        .preview_dpi => {
            loaded.values.preview_dpi = try std.fmt.parseInt(u32, value, 10);
            loaded.active.preview_dpi = true;
        },
        .port => {
            loaded.values.port = try std.fmt.parseInt(u16, value, 10);
            loaded.active.port = true;
        },
    }
}

fn parseTomlBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidTomlBool;
}

fn parseTomlString(value: []const u8) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        return error.InvalidTomlString;
    }
    return value[1 .. value.len - 1];
}

fn stripInlineComment(value: []const u8) []const u8 {
    var in_string = false;
    var escaped = false;
    for (value, 0..) |ch, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_string and ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch == '"') {
            in_string = !in_string;
            continue;
        }
        if (!in_string and ch == '#') return value[0..i];
    }
    return value;
}

fn paramByKey(key: []const u8) ?Param {
    if (std.mem.eql(u8, key, "dpi")) return .dpi;
    if (std.mem.eql(u8, key, "mode")) return .mode;
    if (std.mem.eql(u8, key, "autoselect")) return .autoselect;
    if (std.mem.eql(u8, key, "sel_x_in")) return .sel_x_in;
    if (std.mem.eql(u8, key, "sel_y_in")) return .sel_y_in;
    if (std.mem.eql(u8, key, "sel_w_in")) return .sel_w_in;
    if (std.mem.eql(u8, key, "sel_h_in")) return .sel_h_in;
    if (std.mem.eql(u8, key, "detect_pad")) return .detect_pad;
    if (std.mem.eql(u8, key, "detect_min_area")) return .detect_min_area;
    if (std.mem.eql(u8, key, "preview_dpi")) return .preview_dpi;
    if (std.mem.eql(u8, key, "port")) return .port;
    return null;
}

fn keyName(param: Param) []const u8 {
    return switch (param) {
        .dpi => "dpi",
        .mode => "mode",
        .autoselect => "autoselect",
        .sel_x_in => "sel_x_in",
        .sel_y_in => "sel_y_in",
        .sel_w_in => "sel_w_in",
        .sel_h_in => "sel_h_in",
        .detect_pad => "detect_pad",
        .detect_min_area => "detect_min_area",
        .preview_dpi => "preview_dpi",
        .port => "port",
    };
}

fn comment(param: Param) []const u8 {
    return switch (param) {
        .dpi => "Scan resolution (800, 1200, 1600, 3200, 6400)",
        .mode => "Scan mode: rgb+ir, rgb, ir",
        .autoselect => "Auto-detect film area on preview",
        .sel_x_in => "Selection X offset (inches)",
        .sel_y_in => "Selection Y offset (inches)",
        .sel_w_in => "Selection width (inches)",
        .sel_h_in => "Selection height (inches)",
        .detect_pad => "Padding around detected film area (fraction of smaller dimension)",
        .detect_min_area => "Minimum region size for detection (fraction of image)",
        .preview_dpi => "Preview scan resolution (minimum 200 for TPU)",
        .port => "Web GUI server port",
    };
}

fn isActive(active: ActiveKeys, param: Param) bool {
    return switch (param) {
        .dpi => active.dpi,
        .mode => active.mode,
        .autoselect => active.autoselect,
        .sel_x_in => active.sel_x_in,
        .sel_y_in => active.sel_y_in,
        .sel_w_in => active.sel_w_in,
        .sel_h_in => active.sel_h_in,
        .detect_pad => active.detect_pad,
        .detect_min_area => active.detect_min_area,
        .preview_dpi => active.preview_dpi,
        .port => active.port,
    };
}

test "default scanner config values match Python settings defaults" {
    const loaded = LoadedConfig{};
    try std.testing.expectEqual(@as(u32, 3200), loaded.values.dpi);
    try std.testing.expectEqualStrings("rgb+ir", loaded.values.mode.slice());
    try std.testing.expect(loaded.values.autoselect);
    try std.testing.expectEqual(@as(f64, 0.0), loaded.values.sel_x_in);
    try std.testing.expectEqual(@as(f64, 0.05), loaded.values.detect_pad);
    try std.testing.expectEqual(@as(u32, 200), loaded.values.preview_dpi);
    try std.testing.expectEqual(@as(u16, 8432), loaded.values.port);
    try std.testing.expect(!loaded.active.dpi);
}

test "serializes empty scanner config exactly like Python save_config empty update" {
    const allocator = std.testing.allocator;
    const expected = try readFixture(allocator, "test/fixtures/scanner/config/default-save.toml");
    defer allocator.free(expected);
    const actual = try serialize(allocator, .{});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "parses flattened Python scanner config fixture and merges defaults" {
    const allocator = std.testing.allocator;
    const fixture = try readFixture(allocator, "test/fixtures/scanner/config/partial-save.toml");
    defer allocator.free(fixture);
    const loaded = parseText(fixture);
    try std.testing.expect(loaded.active.dpi);
    try std.testing.expect(loaded.active.mode);
    try std.testing.expect(loaded.active.autoselect);
    try std.testing.expect(loaded.active.sel_w_in);
    try std.testing.expect(!loaded.active.preview_dpi);
    try std.testing.expectEqual(@as(u32, 1600), loaded.values.dpi);
    try std.testing.expectEqualStrings("ir", loaded.values.mode.slice());
    try std.testing.expect(!loaded.values.autoselect);
    try std.testing.expectEqual(@as(f64, 1.25), loaded.values.sel_w_in);
    try std.testing.expectEqual(@as(u32, 200), loaded.values.preview_dpi);
}

test "round trips Python scanner config fixture without changing comments or active keys" {
    const allocator = std.testing.allocator;
    const expected = try readFixture(allocator, "test/fixtures/scanner/config/partial-save.toml");
    defer allocator.free(expected);
    const loaded = parseText(expected);
    const actual = try serialize(allocator, loaded);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "scanner config merge preserves existing active values and active default-valued updates" {
    const allocator = std.testing.allocator;
    const expected = try readFixture(allocator, "test/fixtures/scanner/config/merged-save.toml");
    defer allocator.free(expected);
    const partial = try readFixture(allocator, "test/fixtures/scanner/config/partial-save.toml");
    defer allocator.free(partial);
    var loaded = parseText(partial);
    var updates = LoadedConfig{};
    updates.values.preview_dpi = 400;
    updates.active.preview_dpi = true;
    updates.values.sel_w_in = 0.0;
    updates.active.sel_w_in = true;
    loaded.apply(updates);
    const actual = try serialize(allocator, loaded);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "scanner config file load and save merge existing Python TOML" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const partial = try readFixture(allocator, "test/fixtures/scanner/config/partial-save.toml");
    defer allocator.free(partial);
    const expected = try readFixture(allocator, "test/fixtures/scanner/config/merged-save.toml");
    defer allocator.free(expected);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = partial });

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], file_name });
    defer allocator.free(path);

    var updates = LoadedConfig{};
    updates.values.preview_dpi = 400;
    updates.active.preview_dpi = true;
    updates.values.sel_w_in = 0.0;
    updates.active.sel_w_in = true;
    try saveFile(allocator, std.testing.io, path, updates);

    const loaded = try loadFile(allocator, std.testing.io, path);
    try std.testing.expect(loaded.active.preview_dpi);
    try std.testing.expect(loaded.active.sel_w_in);
    try std.testing.expectEqual(@as(u32, 1600), loaded.values.dpi);
    try std.testing.expectEqual(@as(u32, 400), loaded.values.preview_dpi);
    try std.testing.expectEqual(@as(f64, 0.0), loaded.values.sel_w_in);

    const actual = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(4096));
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "malformed scanner config loads as defaults like Python load_config exception path" {
    const loaded = parseText(
        \\[scan]
        \\dpi = not-a-number
        \\
    );
    try std.testing.expectEqual(@as(u32, 3200), loaded.values.dpi);
    try std.testing.expect(!loaded.active.dpi);
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(4096));
}
