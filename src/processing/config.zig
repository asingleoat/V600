const std = @import("std");
const film_stocks = @import("film_stocks.zig");

pub const config_file = "scratchndent_config.toml";
pub const reference_dpi: u32 = 800;
pub const tiff_exts = [_][]const u8{ ".tif", ".tiff" };
pub const builtin_stocks = film_stocks.builtin_stocks;

pub const Section = enum {
    dust_removal,
    render,

    pub fn name(self: Section) []const u8 {
        return switch (self) {
            .dust_removal => "dust_removal",
            .render => "render",
        };
    }
};

pub const DpiScale = enum {
    none,
    linear,
    area,
};

pub const Value = union(enum) {
    integer: i64,
    float: f64,
    boolean: bool,
    string: FixedString,
    list: FloatList,

    pub fn expectEqual(self: Value, expected: Value) !void {
        try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(self));
        switch (expected) {
            .integer => |value| try std.testing.expectEqual(value, self.integer),
            .float => |value| try std.testing.expectEqual(value, self.float),
            .boolean => |value| try std.testing.expectEqual(value, self.boolean),
            .string => |value| try std.testing.expectEqualStrings(value.slice(), self.string.slice()),
            .list => |value| {
                try std.testing.expectEqual(value.len, self.list.len);
                for (value.slice(), self.list.slice()) |expected_item, actual_item| {
                    try std.testing.expectEqual(expected_item, actual_item);
                }
            },
        }
    }

    pub fn asFloat(self: Value) f64 {
        return switch (self) {
            .integer => |value| @floatFromInt(value),
            .float => |value| value,
            .boolean => |value| if (value) 1.0 else 0.0,
            .string, .list => 0.0,
        };
    }
};

pub const FixedString = struct {
    bytes: [128]u8 = [_]u8{0} ** 128,
    len: usize = 0,

    pub fn init(comptime value: []const u8) FixedString {
        var result = FixedString{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = value.len;
        return result;
    }

    pub fn from(value: []const u8) !FixedString {
        var result = FixedString{};
        try result.set(value);
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

pub const FloatList = struct {
    items: [8]f64 = [_]f64{0.0} ** 8,
    len: usize = 0,

    pub fn init(values: []const f64) !FloatList {
        var result = FloatList{};
        if (values.len > result.items.len) return error.ListTooLong;
        @memcpy(result.items[0..values.len], values);
        result.len = values.len;
        return result;
    }

    pub fn slice(self: *const FloatList) []const f64 {
        return self.items[0..self.len];
    }
};

pub const ParamDefault = struct {
    name: []const u8,
    value: Value,
    section: ?Section = null,
    dpi_scale: DpiScale = .none,
};

pub const ParamComment = struct {
    name: []const u8,
    text: []const u8,
};

pub const Override = struct {
    name: []const u8,
    value: Value,
};

pub const Entry = struct {
    name: FixedString,
    value: Value,

    pub fn init(name: []const u8, value: Value) !Entry {
        return .{ .name = try FixedString.from(name), .value = value };
    }
};

pub const StockProfile = struct {
    name: FixedString,
    description: FixedString = .{},
    has_description: bool = false,
    coeffs: film_stocks.Coefficients = std.mem.zeroes(film_stocks.Coefficients),
    has_coeffs: bool = false,

    pub fn init(name: []const u8) !StockProfile {
        return .{ .name = try FixedString.from(name) };
    }

    pub fn descriptionSlice(self: *const StockProfile) ?[]const u8 {
        return if (self.has_description) self.description.slice() else null;
    }
};

pub const LoadedConfig = struct {
    entries: [32]Entry = undefined,
    len: usize = 0,
    stocks: [8]StockProfile = undefined,
    stock_len: usize = 0,

    pub fn apply(self: *LoadedConfig, updates: []const Override) !void {
        for (updates) |update| try self.set(update.name, update.value);
    }

    pub fn set(self: *LoadedConfig, name: []const u8, new_value: Value) !void {
        for (self.entries[0..self.len]) |*item| {
            if (std.mem.eql(u8, item.name.slice(), name)) {
                item.value = new_value;
                return;
            }
        }
        if (self.len >= self.entries.len) return error.TooManyConfigEntries;
        self.entries[self.len] = try Entry.init(name, new_value);
        self.len += 1;
    }

    pub fn entry(self: *const LoadedConfig, name: []const u8) ?*const Entry {
        for (self.entries[0..self.len]) |*item| {
            if (std.mem.eql(u8, item.name.slice(), name)) return item;
        }
        return null;
    }

    pub fn value(self: *const LoadedConfig, name: []const u8) ?Value {
        const found = self.entry(name) orelse return null;
        return found.value;
    }

    pub fn active(self: *const LoadedConfig, name: []const u8) bool {
        return self.value(name) != null;
    }

    pub fn ensureStock(self: *LoadedConfig, name: []const u8) !usize {
        for (self.stocks[0..self.stock_len], 0..) |stock, index| {
            if (std.mem.eql(u8, stock.name.slice(), name)) return index;
        }
        if (self.stock_len >= self.stocks.len) return error.TooManyStockProfiles;
        self.stocks[self.stock_len] = try StockProfile.init(name);
        self.stock_len += 1;
        return self.stock_len - 1;
    }

    pub fn activeStock(self: *const LoadedConfig) ?[]const u8 {
        const found = self.entry("stock") orelse return null;
        if (std.meta.activeTag(found.value) != .string) return null;
        const stock = found.value.string.slice();
        return if (stock.len == 0) null else stock;
    }

    pub fn savedDmin(self: *const LoadedConfig) ?[3]f64 {
        const found = self.entry("dmin") orelse return null;
        if (std.meta.activeTag(found.value) != .list) return null;
        const values = found.value.list.slice();
        if (values.len < 3) return null;
        return .{ values[0], values[1], values[2] };
    }

    /// Every loaded setting as an override list for getParam, minus the
    /// custom stock table.
    pub fn overrides(self: *const LoadedConfig, out: *[32]Override) []const Override {
        var count: usize = 0;
        for (self.entries[0..self.len]) |*item| {
            const name = item.name.slice();
            if (std.mem.eql(u8, name, "_stocks")) continue;
            out[count] = .{ .name = name, .value = item.value };
            count += 1;
        }
        return out[0..count];
    }

    pub fn customStock(self: *const LoadedConfig, name: []const u8) ?StockProfile {
        for (self.stocks[0..self.stock_len]) |stock| {
            if (std.mem.eql(u8, stock.name.slice(), name)) return stock;
        }
        return null;
    }

    pub fn availableStock(self: *const LoadedConfig, name: []const u8) ?StockProfile {
        if (self.customStock(name)) |stock| {
            if (stock.has_coeffs) return stock;
            if (film_stocks.builtinStock(name)) |builtin| {
                return .{
                    .name = FixedString.from(builtin.name) catch return null,
                    .description = if (stock.has_description)
                        stock.description
                    else
                        FixedString.from(builtin.description) catch return null,
                    .has_description = true,
                    .coeffs = builtin.coeffs,
                    .has_coeffs = true,
                };
            }
            return stock;
        }
        if (film_stocks.builtinStock(name)) |stock| {
            return .{
                .name = FixedString.from(stock.name) catch return null,
                .description = FixedString.from(stock.description) catch return null,
                .has_description = true,
                .coeffs = stock.coeffs,
                .has_coeffs = true,
            };
        }
        return null;
    }
};

pub const defaults = [_]ParamDefault{
    .{ .name = "ir_threshold", .value = .{ .float = 0.10 }, .section = .dust_removal },
    .{ .name = "ir_hair_sensitivity", .value = .{ .float = 0.10 }, .section = .dust_removal },
    .{ .name = "ir_min_area", .value = .{ .integer = 3 }, .section = .dust_removal, .dpi_scale = .area },
    .{ .name = "ir_dilate_radius", .value = .{ .integer = 4 }, .section = .dust_removal, .dpi_scale = .linear },
    .{ .name = "ir_close_radius", .value = .{ .integer = 6 }, .section = .dust_removal, .dpi_scale = .linear },
    .{ .name = "ir_blur_size", .value = .{ .integer = 301 }, .section = .dust_removal, .dpi_scale = .linear },
    .{ .name = "ir_max_coverage", .value = .{ .float = 0.03 }, .section = .dust_removal },
    .{ .name = "inpaint_padding", .value = .{ .integer = 16 }, .section = .dust_removal, .dpi_scale = .linear },
    .{ .name = "render_contrast", .value = .{ .float = 1.4 }, .section = .render },
    .{ .name = "render_curve_k", .value = .{ .float = 5.0 }, .section = .render },
    .{ .name = "render_percentile_lo", .value = .{ .float = 0.5 }, .section = .render },
    .{ .name = "render_percentile_hi", .value = .{ .float = 99.5 }, .section = .render },
    .{ .name = "exposure_compensation", .value = .{ .float = 0.0 }, .section = .render },
    .{ .name = "color_temp", .value = .{ .float = 0.0 }, .section = .render },
    .{ .name = "color_tint", .value = .{ .float = 0.0 }, .section = .render },
    .{ .name = "preview_size", .value = .{ .integer = 8192 } },
    .{ .name = "clahe_clip", .value = .{ .float = 2.0 } },
};

pub const comments = [_]ParamComment{
    .{ .name = "stock", .text = "Active film stock name" },
    .{ .name = "preview_size", .text = "Max preview dimension in pixels" },
    .{ .name = "ir_threshold", .text = "Defect detection sensitivity (lower = more aggressive)" },
    .{ .name = "ir_hair_sensitivity", .text = "Meijering line filter threshold for hairs/scratches" },
    .{ .name = "ir_min_area", .text = "Minimum defect size in pixels at 800 DPI" },
    .{ .name = "ir_dilate_radius", .text = "Mask dilation in pixels at 800 DPI" },
    .{ .name = "ir_close_radius", .text = "Morphological close in pixels at 800 DPI" },
    .{ .name = "ir_blur_size", .text = "Background blur kernel in pixels at 800 DPI" },
    .{ .name = "ir_max_coverage", .text = "Sanity cap: max fraction of image flagged as defects" },
    .{ .name = "inpaint_padding", .text = "Context padding in pixels at 800 DPI" },
    .{ .name = "render_contrast", .text = "S-curve contrast strength: 1.0=linear, 2.0=punchy" },
    .{ .name = "render_curve_k", .text = "S-curve steepness multiplier" },
    .{ .name = "render_percentile_lo", .text = "Low percentile for display range normalization" },
    .{ .name = "render_percentile_hi", .text = "High percentile for display range normalization" },
    .{ .name = "exposure_compensation", .text = "Density-domain exposure shift: positive=brighter" },
    .{ .name = "color_temp", .text = "Color temperature: positive=warmer, negative=cooler" },
    .{ .name = "color_tint", .text = "Color tint: positive=magenta, negative=green" },
    .{ .name = "clahe_clip", .text = "CLAHE clip limit for preview contrast enhancement" },
    .{ .name = "dmin", .text = "Film base density [R, G, B]" },
    .{ .name = "ir_clean", .text = "Enable IR dust/scratch removal" },
    .{ .name = "invert", .text = "Enable film negative inversion" },
    .{ .name = "preview_inversion", .text = "Show inverted preview instead of CLAHE" },
    .{ .name = "aspect", .text = "Last used aspect ratio for frame selection" },
};

pub fn defaultValue(name: []const u8) ?Value {
    for (defaults) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

pub fn parseText(text: []const u8) LoadedConfig {
    return parseTextStrict(text) catch .{};
}

pub fn loadFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !LoadedConfig {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024)) catch |err| {
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
    updates: []const Override,
) !void {
    var current = try loadFile(allocator, io, path);
    try current.apply(updates);
    try saveLoadedFile(allocator, io, path, current);
}

pub fn saveLoadedFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    loaded: LoadedConfig,
) !void {
    const data = try serialize(allocator, loaded);
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

    try out.appendSlice("# scratchndent configuration\n\n");

    for (loaded.entries[0..loaded.len]) |entry| {
        const name = entry.name.slice();
        if (section(name) != null) continue;
        if (std.mem.eql(u8, name, "_stocks")) continue;
        if (comment(name)) |text| try out.print("# {s}\n", .{text});
        try out.print("{s} = ", .{name});
        try appendTomlValue(&out, entry.value);
        try out.appendSlice("\n\n");
    }

    try appendSection(&out, loaded, .dust_removal);
    try appendSection(&out, loaded, .render);
    try appendStocks(&out, loaded);

    return out.toOwnedSlice();
}

pub fn getParam(name: []const u8, current_dpi: ?u32, overrides: []const Override) ?Value {
    const default = defaultValue(name) orelse return null;
    var raw = overrideValue(name, overrides) orelse default;
    if (current_dpi) |dpi| {
        if (dpi > 0) {
            const scale = @as(f64, @floatFromInt(dpi)) / @as(f64, @floatFromInt(reference_dpi));
            switch (dpiScale(name)) {
                .none => {},
                .linear => {
                    const raw_float = raw.asFloat();
                    raw = .{ .float = raw_float * scale };
                },
                .area => {
                    const raw_float = raw.asFloat();
                    raw = .{ .float = raw_float * scale * scale };
                },
            }
            if (std.mem.eql(u8, name, "ir_blur_size")) {
                return .{ .integer = @as(i64, @intFromFloat(@trunc(raw.asFloat()))) | 1 };
            }
        }
    }
    return castLikeDefault(raw, default);
}

pub fn section(name: []const u8) ?Section {
    for (defaults) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.section;
    }
    return null;
}

pub fn dpiScale(name: []const u8) DpiScale {
    for (defaults) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.dpi_scale;
    }
    return .none;
}

pub fn comment(name: []const u8) ?[]const u8 {
    for (comments) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.text;
    }
    return null;
}

fn overrideValue(name: []const u8, overrides: []const Override) ?Value {
    for (overrides) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

fn castLikeDefault(raw: Value, default: Value) Value {
    return switch (default) {
        .integer => .{ .integer = @as(i64, @intFromFloat(@trunc(raw.asFloat()))) },
        .float => .{ .float = raw.asFloat() },
        .boolean => .{ .boolean = raw.asFloat() != 0.0 },
        .string, .list => raw,
    };
}

pub fn isTiffExtension(ext: []const u8) bool {
    for (tiff_exts) |candidate| {
        if (std.mem.eql(u8, candidate, ext)) return true;
    }
    return false;
}

const ParseSection = enum {
    top,
    dust_removal,
    render,
    stocks,
};

fn parseTextStrict(text: []const u8) !LoadedConfig {
    var loaded = LoadedConfig{};
    var current_section: ParseSection = .top;
    var current_stock_index: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (isSectionHeader(line)) {
            const name = line[1 .. line.len - 1];
            current_stock_index = null;
            current_section = if (std.mem.eql(u8, name, "dust_removal"))
                .dust_removal
            else if (std.mem.eql(u8, name, "render"))
                .render
            else if (std.mem.startsWith(u8, name, "stocks.")) blk: {
                current_stock_index = try loaded.ensureStock(name["stocks.".len..]);
                break :blk .stocks;
            } else .top;
            continue;
        }
        if (line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (current_section == .stocks) {
            const stock_index = current_stock_index orelse continue;
            const value = std.mem.trim(u8, stripInlineComment(line[eq + 1 ..]), " \t");
            if (std.mem.eql(u8, key, "description")) {
                try loaded.stocks[stock_index].description.set(try parseTomlString(value));
                loaded.stocks[stock_index].has_description = true;
            } else if (std.mem.eql(u8, key, "coeffs")) {
                try parseStockCoeffs(&lines, &loaded.stocks[stock_index], value);
            }
            continue;
        }
        if (!shouldLoadKey(current_section, key)) continue;
        const value = std.mem.trim(u8, stripInlineComment(line[eq + 1 ..]), " \t");
        try loaded.set(key, try parseTomlValue(value));
    }
    return loaded;
}

fn isSectionHeader(line: []const u8) bool {
    return line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']';
}

fn shouldLoadKey(current_section: ParseSection, key: []const u8) bool {
    return switch (current_section) {
        .stocks => false,
        .dust_removal => section(key) == .dust_removal,
        .render => section(key) == .render,
        .top => !std.mem.eql(u8, key, "coeffs") and !std.mem.eql(u8, key, "description"),
    };
}

fn parseStockCoeffs(lines: anytype, stock: *StockProfile, first_value: []const u8) !void {
    if (!std.mem.eql(u8, first_value, "[")) return error.InvalidStockCoefficients;

    var row_index: usize = 0;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == ']') break;
        if (row_index >= film_stocks.basis_len) return error.InvalidStockCoefficients;

        const row_text = std.mem.trim(u8, stripInlineComment(line), " \t,");
        if (row_text.len == 0) continue;
        const row = try parseTomlFloatList(row_text);
        if (row.len != film_stocks.channel_count) return error.InvalidStockCoefficients;
        for (row.slice(), 0..) |value, channel| {
            stock.coeffs[row_index][channel] = value;
        }
        row_index += 1;
    }

    if (row_index != film_stocks.basis_len) return error.InvalidStockCoefficients;
    stock.has_coeffs = true;
}

fn parseTomlValue(value: []const u8) !Value {
    if (value.len == 0) return error.InvalidTomlValue;
    if (value[0] == '"') return .{ .string = try FixedString.from(try parseTomlString(value)) };
    if (std.mem.eql(u8, value, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, value, "false")) return .{ .boolean = false };
    if (value[0] == '[') return .{ .list = try parseTomlFloatList(value) };
    if (std.mem.indexOfAny(u8, value, ".eE") != null) {
        return .{ .float = try std.fmt.parseFloat(f64, value) };
    }
    return .{ .integer = try std.fmt.parseInt(i64, value, 10) };
}

fn parseTomlString(value: []const u8) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        return error.InvalidTomlString;
    }
    return value[1 .. value.len - 1];
}

fn parseTomlFloatList(value: []const u8) !FloatList {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return error.InvalidTomlList;
    var result = FloatList{};
    var items = std.mem.splitScalar(u8, value[1 .. value.len - 1], ',');
    while (items.next()) |raw_item| {
        const item = std.mem.trim(u8, raw_item, " \t");
        if (item.len == 0) continue;
        if (result.len >= result.items.len) return error.ListTooLong;
        result.items[result.len] = try std.fmt.parseFloat(f64, item);
        result.len += 1;
    }
    return result;
}

fn stripInlineComment(value: []const u8) []const u8 {
    var in_string = false;
    var escaped = false;
    var bracket_depth: usize = 0;
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
        if (!in_string and ch == '[') bracket_depth += 1;
        if (!in_string and ch == ']' and bracket_depth > 0) bracket_depth -= 1;
        if (!in_string and bracket_depth == 0 and ch == '#') return value[0..i];
    }
    return value;
}

fn appendSection(out: *std.array_list.Managed(u8), loaded: LoadedConfig, section_value: Section) !void {
    try out.print("[{s}]\n", .{section_value.name()});
    for (defaults) |entry| {
        if (entry.section != section_value) continue;
        if (comment(entry.name)) |text| try out.print("# {s}\n", .{text});
        if (loaded.value(entry.name)) |value| {
            try out.print("{s} = ", .{entry.name});
            try appendTomlValue(out, value);
            try out.append('\n');
        } else {
            try out.print("# {s} = ", .{entry.name});
            try appendTomlValue(out, entry.value);
            try out.append('\n');
        }
    }
    try out.append('\n');
}

fn appendStocks(out: *std.array_list.Managed(u8), loaded: LoadedConfig) !void {
    try out.appendSlice("# Film stock profiles\n\n");

    var wrote_stock = false;
    for (builtin_stocks) |stock| {
        if (wrote_stock) try out.append('\n');
        if (loaded.customStock(stock.name)) |custom| {
            if (custom.has_coeffs) {
                try appendCustomStock(out, custom);
            } else {
                try appendBuiltinStock(out, stock);
            }
        } else {
            try appendBuiltinStock(out, stock);
        }
        wrote_stock = true;
    }

    for (loaded.stocks[0..loaded.stock_len]) |stock| {
        if (isBuiltinStockName(stock.name.slice())) continue;
        if (!stock.has_coeffs) continue;
        if (wrote_stock) try out.append('\n');
        try appendCustomStock(out, stock);
        wrote_stock = true;
    }
}

fn appendBuiltinStock(out: *std.array_list.Managed(u8), stock: film_stocks.BuiltinStock) !void {
    try out.print("[stocks.{s}]\n", .{stock.name});
    try out.print("description = \"{s}\"\n", .{stock.description});
    try appendCoeffRows(out, stock.coeffs);
}

fn appendCustomStock(out: *std.array_list.Managed(u8), stock: StockProfile) !void {
    try out.print("[stocks.{s}]\n", .{stock.name.slice()});
    if (stock.descriptionSlice()) |description| {
        try out.print("description = \"{s}\"\n", .{description});
    }
    try appendCoeffRows(out, stock.coeffs);
}

fn appendCoeffRows(out: *std.array_list.Managed(u8), coeffs: film_stocks.Coefficients) !void {
    try out.appendSlice("coeffs = [\n");
    for (coeffs, 0..) |row, i| {
        try out.print("    [", .{});
        for (row, 0..) |value, channel| {
            if (channel > 0) try out.appendSlice(", ");
            try out.print("{d:8.4}", .{value});
        }
        try out.print("],  # {s}\n", .{film_stocks.basis_labels[i]});
    }
    try out.appendSlice("]\n");
}

fn isBuiltinStockName(name: []const u8) bool {
    return film_stocks.builtinStock(name) != null;
}

fn appendTomlValue(out: *std.array_list.Managed(u8), value: Value) !void {
    switch (value) {
        .integer => |item| try out.print("{d}", .{item}),
        .float => |item| try appendPythonFloat(out, item),
        .boolean => |item| try out.appendSlice(if (item) "true" else "false"),
        .string => |item| try out.print("\"{s}\"", .{item.slice()}),
        .list => |items| {
            try out.append('[');
            for (items.slice(), 0..) |item, i| {
                if (i > 0) try out.appendSlice(", ");
                try appendPythonFloat(out, item);
            }
            try out.append(']');
        },
    }
}

fn appendPythonFloat(out: *std.array_list.Managed(u8), value: f64) !void {
    if (value == @floor(value)) {
        try out.print("{d:.1}", .{value});
    } else {
        try out.print("{d}", .{value});
    }
}

test "preserves processing config default order, values, and types" {
    try std.testing.expectEqual(@as(u32, 800), reference_dpi);
    try std.testing.expectEqual(@as(usize, 17), defaults.len);
    try std.testing.expectEqualStrings("scratchndent_config.toml", config_file);

    try defaultValue("ir_threshold").?.expectEqual(.{ .float = 0.10 });
    try defaultValue("ir_hair_sensitivity").?.expectEqual(.{ .float = 0.10 });
    try defaultValue("ir_min_area").?.expectEqual(.{ .integer = 3 });
    try defaultValue("ir_dilate_radius").?.expectEqual(.{ .integer = 4 });
    try defaultValue("ir_close_radius").?.expectEqual(.{ .integer = 6 });
    try defaultValue("ir_blur_size").?.expectEqual(.{ .integer = 301 });
    try defaultValue("ir_max_coverage").?.expectEqual(.{ .float = 0.03 });
    try defaultValue("inpaint_padding").?.expectEqual(.{ .integer = 16 });
    try defaultValue("render_contrast").?.expectEqual(.{ .float = 1.4 });
    try defaultValue("render_curve_k").?.expectEqual(.{ .float = 5.0 });
    try defaultValue("render_percentile_lo").?.expectEqual(.{ .float = 0.5 });
    try defaultValue("render_percentile_hi").?.expectEqual(.{ .float = 99.5 });
    try defaultValue("exposure_compensation").?.expectEqual(.{ .float = 0.0 });
    try defaultValue("color_temp").?.expectEqual(.{ .float = 0.0 });
    try defaultValue("color_tint").?.expectEqual(.{ .float = 0.0 });
    try defaultValue("preview_size").?.expectEqual(.{ .integer = 8192 });
    try defaultValue("clahe_clip").?.expectEqual(.{ .float = 2.0 });

    try std.testing.expect(defaultValue("stock") == null);
}

test "preserves processing config sections and comments" {
    try std.testing.expectEqual(Section.dust_removal, section("ir_threshold").?);
    try std.testing.expectEqual(Section.dust_removal, section("inpaint_padding").?);
    try std.testing.expectEqual(Section.render, section("render_contrast").?);
    try std.testing.expectEqual(Section.render, section("color_tint").?);
    try std.testing.expect(section("preview_size") == null);

    try std.testing.expectEqualStrings("dust_removal", Section.dust_removal.name());
    try std.testing.expectEqualStrings("render", Section.render.name());
    try std.testing.expectEqual(@as(usize, 23), comments.len);
    try std.testing.expectEqualStrings("Active film stock name", comment("stock").?);
    try std.testing.expectEqualStrings("Film base density [R, G, B]", comment("dmin").?);
    try std.testing.expectEqualStrings("Show inverted preview instead of CLAHE", comment("preview_inversion").?);
    try std.testing.expect(comment("missing") == null);
}

test "preserves processing config DPI scaling classes and TIFF extensions" {
    try std.testing.expectEqual(DpiScale.area, dpiScale("ir_min_area"));
    try std.testing.expectEqual(DpiScale.linear, dpiScale("ir_dilate_radius"));
    try std.testing.expectEqual(DpiScale.linear, dpiScale("ir_close_radius"));
    try std.testing.expectEqual(DpiScale.linear, dpiScale("ir_blur_size"));
    try std.testing.expectEqual(DpiScale.linear, dpiScale("inpaint_padding"));
    try std.testing.expectEqual(DpiScale.none, dpiScale("render_contrast"));
    try std.testing.expectEqual(DpiScale.none, dpiScale("missing"));

    try std.testing.expect(isTiffExtension(".tif"));
    try std.testing.expect(isTiffExtension(".tiff"));
    try std.testing.expect(!isTiffExtension(".TIFF"));
    try std.testing.expect(!isTiffExtension(".png"));
}

test "scales processing params with Python get_param semantics" {
    try getParam("ir_dilate_radius", 1600, &.{}).?.expectEqual(.{ .integer = 8 });
    try getParam("ir_close_radius", 400, &.{}).?.expectEqual(.{ .integer = 3 });
    try getParam("inpaint_padding", 400, &.{}).?.expectEqual(.{ .integer = 8 });

    try getParam("ir_min_area", 1600, &.{}).?.expectEqual(.{ .integer = 12 });
    try getParam("ir_min_area", 400, &.{}).?.expectEqual(.{ .integer = 0 });

    try getParam("ir_blur_size", 1600, &.{}).?.expectEqual(.{ .integer = 603 });
    try getParam("ir_blur_size", 400, &.{}).?.expectEqual(.{ .integer = 151 });

    try getParam("render_contrast", 1600, &.{}).?.expectEqual(.{ .float = 1.4 });
    try getParam("ir_dilate_radius", null, &.{}).?.expectEqual(.{ .integer = 4 });
    try getParam("ir_dilate_radius", 0, &.{}).?.expectEqual(.{ .integer = 4 });
    try std.testing.expect(getParam("missing", 800, &.{}) == null);
}

test "casts processing param overrides back to default value types" {
    const overrides = [_]Override{
        .{ .name = "ir_min_area", .value = .{ .integer = 5 } },
        .{ .name = "ir_dilate_radius", .value = .{ .float = 2.75 } },
        .{ .name = "render_contrast", .value = .{ .integer = 2 } },
        .{ .name = "ir_blur_size", .value = .{ .integer = 302 } },
    };

    try getParam("ir_min_area", 1600, &overrides).?.expectEqual(.{ .integer = 20 });
    try getParam("ir_dilate_radius", 800, &overrides).?.expectEqual(.{ .integer = 2 });
    try getParam("render_contrast", 800, &overrides).?.expectEqual(.{ .float = 2.0 });
    try getParam("ir_blur_size", null, &overrides).?.expectEqual(.{ .integer = 302 });
    try getParam("ir_blur_size", 800, &overrides).?.expectEqual(.{ .integer = 303 });
}

test "serializes empty processing config exactly like Python save_config empty update" {
    const allocator = std.testing.allocator;
    const expected = try readFixture(allocator, "test/fixtures/processing/config/default-save.toml");
    defer allocator.free(expected);
    const actual = try serialize(allocator, .{});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "serializes partial processing config exactly like Python save_config updates" {
    const allocator = std.testing.allocator;
    const expected = try readFixture(allocator, "test/fixtures/processing/config/partial-save.toml");
    defer allocator.free(expected);
    var loaded = LoadedConfig{};
    try loaded.apply(&partialProcessingUpdates);
    const actual = try serialize(allocator, loaded);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "parses and merges processing config preserving Python insertion order" {
    const allocator = std.testing.allocator;
    const partial = try readFixture(allocator, "test/fixtures/processing/config/partial-save.toml");
    defer allocator.free(partial);
    const expected = try readFixture(allocator, "test/fixtures/processing/config/merged-save.toml");
    defer allocator.free(expected);

    var loaded = parseText(partial);
    try loaded.apply(&mergeProcessingUpdates);
    try loaded.value("stock").?.expectEqual(.{ .string = FixedString.init("kodak_portra") });
    try loaded.value("preview_size").?.expectEqual(.{ .integer = 8192 });
    try loaded.value("dmin").?.expectEqual(.{ .list = try FloatList.init(&.{ 0.1, 0.2, 0.3 }) });
    try loaded.value("invert").?.expectEqual(.{ .boolean = false });

    const actual = try serialize(allocator, loaded);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "parses and preserves config-defined film stock profiles" {
    const allocator = std.testing.allocator;
    const expected = try readFixture(allocator, "test/fixtures/processing/config/custom-stock-save.toml");
    defer allocator.free(expected);

    const loaded = parseText(expected);
    try loaded.value("stock").?.expectEqual(.{ .string = FixedString.init("custom_c41") });
    try std.testing.expectEqual(@as(usize, 3), loaded.stock_len);

    const custom = loaded.availableStock("custom_c41").?;
    try std.testing.expectEqualStrings("Custom C-41 test profile", custom.descriptionSlice().?);
    try std.testing.expect(custom.has_coeffs);
    try std.testing.expectEqual(@as(f64, 1.01), custom.coeffs[0][0]);
    try std.testing.expectEqual(@as(f64, 0.06), custom.coeffs[1][2]);
    try std.testing.expectEqual(@as(f64, 0.30), custom.coeffs[9][2]);

    const gold = loaded.availableStock("kodak_gold").?;
    try std.testing.expectEqualStrings("Kodak Gold 200 on Epson V600", gold.descriptionSlice().?);
    try std.testing.expectEqual(@as(f64, 1.20), gold.coeffs[0][0]);
    try std.testing.expect(loaded.availableStock("missing") == null);

    const actual = try serialize(allocator, loaded);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "incomplete built-in stock profiles fall back to compiled coefficients" {
    const allocator = std.testing.allocator;
    var loaded = LoadedConfig{};
    const stock_index = try loaded.ensureStock("kodak_gold");
    try loaded.stocks[stock_index].description.set("Runtime profile without coefficients");
    loaded.stocks[stock_index].has_description = true;

    const gold = loaded.availableStock("kodak_gold").?;
    try std.testing.expect(gold.has_coeffs);
    try std.testing.expectEqualStrings("Runtime profile without coefficients", gold.descriptionSlice().?);
    try std.testing.expectEqual(@as(f64, 1.20), gold.coeffs[0][0]);
    try std.testing.expectEqual(@as(f64, -0.06), gold.coeffs[1][2]);

    const actual = try serialize(allocator, loaded);
    defer allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "Runtime profile without coefficients") == null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "[  1.2000,  -0.0400,   0.0000],  # R") != null);
}

test "processing config file save persists Python-style merge" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const partial = try readFixture(allocator, "test/fixtures/processing/config/partial-save.toml");
    defer allocator.free(partial);
    const expected = try readFixture(allocator, "test/fixtures/processing/config/merged-save.toml");
    defer allocator.free(expected);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = config_file, .data = partial });

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], config_file });
    defer allocator.free(path);
    try saveFile(allocator, std.testing.io, path, &mergeProcessingUpdates);

    const loaded = try loadFile(allocator, std.testing.io, path);
    try loaded.value("stock").?.expectEqual(.{ .string = FixedString.init("kodak_portra") });
    try loaded.value("color_tint").?.expectEqual(.{ .float = -0.25 });

    const actual = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024));
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "malformed processing config loads as empty like Python load exception path" {
    const loaded = parseText(
        \\[dust_removal]
        \\ir_threshold = not-a-number
        \\
    );
    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

const partialProcessingUpdates = [_]Override{
    .{ .name = "stock", .value = .{ .string = FixedString.init("kodak_gold") } },
    .{ .name = "preview_size", .value = .{ .integer = 4096 } },
    .{ .name = "ir_threshold", .value = .{ .float = 0.2 } },
    .{ .name = "ir_min_area", .value = .{ .integer = 5 } },
    .{ .name = "render_contrast", .value = .{ .float = 1.6 } },
    .{ .name = "dmin", .value = .{ .list = .{ .items = .{ 0.1, 0.2, 0.3, 0.0, 0.0, 0.0, 0.0, 0.0 }, .len = 3 } } },
    .{ .name = "preview_inversion", .value = .{ .boolean = true } },
};

const mergeProcessingUpdates = [_]Override{
    .{ .name = "preview_size", .value = .{ .integer = 8192 } },
    .{ .name = "ir_blur_size", .value = .{ .integer = 151 } },
    .{ .name = "color_tint", .value = .{ .float = -0.25 } },
    .{ .name = "invert", .value = .{ .boolean = false } },
    .{ .name = "stock", .value = .{ .string = FixedString.init("kodak_portra") } },
};

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(128 * 1024));
}
