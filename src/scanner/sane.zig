const std = @import("std");
const contracts = @import("contracts.zig");
const models = @import("models.zig");

pub const millimeters_per_inch = 25.4;
const safety_margin_mm = 0.1;
const tpu_resolutions = [_]u32{ 400, 800, 1600, 3200 };
const ir_resolutions = [_]u32{ 800, 1600, 3200 };

pub const WrapperAvailability = struct {
    scanimage_v600: bool = false,
    scanimage_v600_ir: bool = false,
};

pub const EnvironmentPlan = struct {
    scan_ir_mode: bool = false,
    lut_file: ?[]const u8 = null,
};

pub const CommandPlan = struct {
    argv: std.ArrayList([]const u8) = .empty,
    owned: std.ArrayList([]u8) = .empty,
    env: EnvironmentPlan = .{},
    effective_dpi: u32,
    original_dpi: u32,
    source: contracts.Source,
    kind: contracts.ScanKind,

    pub fn deinit(self: *CommandPlan, allocator: std.mem.Allocator) void {
        for (self.owned.items) |item| allocator.free(item);
        self.owned.deinit(allocator);
        self.argv.deinit(allocator);
        self.* = undefined;
    }

    fn pushLiteral(self: *CommandPlan, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.argv.append(allocator, value);
    }

    fn pushOwned(self: *CommandPlan, allocator: std.mem.Allocator, value: []u8) !void {
        try self.owned.append(allocator, value);
        try self.argv.append(allocator, value);
    }
};

pub fn planCommand(
    allocator: std.mem.Allocator,
    request: contracts.ScanRequest,
    caps: contracts.ScannerCapabilities,
    wrappers: WrapperAvailability,
) !CommandPlan {
    if (request.kind == .rgb_ir) return error.CombinedScanRequiresRuntime;

    var plan = CommandPlan{
        .effective_dpi = request.dpi,
        .original_dpi = request.dpi,
        .source = if (request.kind == .ir) .tpu else request.source,
        .kind = request.kind,
    };
    errdefer plan.deinit(allocator);

    plan.effective_dpi = effectiveDpiForCaps(request, caps);

    if (request.kind == .ir) {
        if (wrappers.scanimage_v600_ir) {
            try plan.pushLiteral(allocator, "scanimage-v600-ir");
        } else {
            return error.IrWrapperRequired;
        }
    } else if (wrappers.scanimage_v600) {
        try plan.pushLiteral(allocator, "scanimage-v600");
    } else {
        try plan.pushLiteral(allocator, "scanimage");
    }

    if (request.kind == .rgb) if (request.lut_file_path) |lut_path| {
        plan.env.lut_file = lut_path;
    };

    try plan.pushLiteral(allocator, "--device-name");
    try plan.pushLiteral(allocator, caps.device_name);
    try plan.pushLiteral(allocator, "--mode");
    try plan.pushLiteral(allocator, saneMode(request.kind));
    try plan.pushLiteral(allocator, "--source");
    try plan.pushLiteral(allocator, saneSource(plan.source));
    try plan.pushLiteral(allocator, "--resolution");
    try plan.pushOwned(allocator, try std.fmt.allocPrint(allocator, "{d}", .{plan.effective_dpi}));
    try plan.pushLiteral(allocator, "--format");
    try plan.pushLiteral(allocator, "tiff");

    if (request.kind != .ir and request.depth == .sixteen) {
        try plan.pushLiteral(allocator, "--depth");
        try plan.pushLiteral(allocator, "16");
    }

    if (request.area.isExplicit()) {
        try appendArea(allocator, &plan, request.area, caps, plan.source);
    }

    if (request.output_path) |output_path| {
        try plan.pushLiteral(allocator, "-o");
        try plan.pushLiteral(allocator, output_path);
    }

    return plan;
}

/// The resolution a request scans at on the scanner `caps` describes: the
/// V600's Linux resolutions for a V600 or an unknown device, the model's own
/// for any other.
pub fn effectiveDpiForCaps(request: contracts.ScanRequest, caps: contracts.ScannerCapabilities) u32 {
    const model = caps.known_model orelse return effectiveDpiForRequest(request);
    if (model.product_id == models.v600.product_id) return effectiveDpiForRequest(request);
    if (request.kind == .ir) return models.nearestDpi(request.dpi, model.ir_dpis, caps.max_resolution);
    if (request.source == .tpu) return models.nearestDpi(request.dpi, model.tpu_dpis, caps.max_resolution);
    return request.dpi;
}

pub fn effectiveDpiForRequest(request: contracts.ScanRequest) u32 {
    var effective_dpi = request.dpi;
    const source = if (request.kind == .ir) .tpu else request.source;
    if (source == .tpu) {
        effective_dpi = nearest(request.dpi, &tpu_resolutions);
    }
    if (request.kind == .ir) {
        effective_dpi = nearest(effective_dpi, &ir_resolutions);
    }
    return effective_dpi;
}

fn appendArea(
    allocator: std.mem.Allocator,
    plan: *CommandPlan,
    area: contracts.AreaInches,
    caps: contracts.ScannerCapabilities,
    source: contracts.Source,
) !void {
    const max_width_mm = switch (source) {
        .tpu => caps.tpu_width_in * millimeters_per_inch,
        .flatbed => caps.flatbed_width_in * millimeters_per_inch,
    } - safety_margin_mm;
    const max_height_mm = switch (source) {
        .tpu => caps.tpu_height_in * millimeters_per_inch,
        .flatbed => caps.flatbed_height_in * millimeters_per_inch,
    } - safety_margin_mm;

    const x_mm = clamp(area.x * millimeters_per_inch, 0.0, max_width_mm);
    const y_mm = clamp(area.y * millimeters_per_inch, 0.0, max_height_mm);
    const w_mm = if (area.width) |width|
        @min(width * millimeters_per_inch, max_width_mm - x_mm)
    else
        max_width_mm - x_mm;
    const h_mm = if (area.height) |height|
        @min(height * millimeters_per_inch, max_height_mm - y_mm)
    else
        max_height_mm - y_mm;

    try plan.pushLiteral(allocator, "-l");
    try plan.pushOwned(allocator, try std.fmt.allocPrint(allocator, "{d:.1}", .{x_mm}));
    try plan.pushLiteral(allocator, "-t");
    try plan.pushOwned(allocator, try std.fmt.allocPrint(allocator, "{d:.1}", .{y_mm}));
    try plan.pushLiteral(allocator, "-x");
    try plan.pushOwned(allocator, try std.fmt.allocPrint(allocator, "{d:.1}", .{w_mm}));
    try plan.pushLiteral(allocator, "-y");
    try plan.pushOwned(allocator, try std.fmt.allocPrint(allocator, "{d:.1}", .{h_mm}));
}

pub fn parseCapabilities(help: []const u8) contracts.ScannerCapabilities {
    var caps = contracts.ScannerCapabilities{};
    const default_source: contracts.Source = if (std.mem.indexOf(u8, help, "[Transparency Unit]") != null)
        .tpu
    else
        .flatbed;
    var current_source: contracts.Source = default_source;
    var lines = std.mem.splitScalar(u8, help, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.indexOf(u8, line, "Options specific to device `")) |_| {
            if (between(line, "`", "'")) |name| caps.device_name = name;
        } else if (std.mem.startsWith(u8, line, "--source ")) {
            if (std.mem.indexOf(u8, line, "[Transparency Unit]") != null) {
                current_source = .tpu;
            } else if (std.mem.indexOf(u8, line, "[Flatbed]") != null) {
                current_source = .flatbed;
            }
        } else if (std.mem.startsWith(u8, line, "--resolution ")) {
            caps.max_resolution = maxResolutionInLine(line);
        } else if (std.mem.startsWith(u8, line, "-x 0..")) {
            const inches = parseLimitInches(line) orelse continue;
            if (current_source == .tpu) {
                caps.tpu_width_in = inches;
            } else {
                caps.flatbed_width_in = inches;
            }
        } else if (std.mem.startsWith(u8, line, "-y 0..")) {
            const inches = parseLimitInches(line) orelse continue;
            if (current_source == .tpu) {
                caps.tpu_height_in = inches;
            } else {
                caps.flatbed_height_in = inches;
            }
        }
    }
    return caps;
}

pub fn parseCombinedCapabilities(flatbed_help: []const u8, tpu_help: []const u8) contracts.ScannerCapabilities {
    var flatbed = parseCapabilities(flatbed_help);
    const tpu = parseCapabilities(tpu_help);
    if (flatbed.device_name.len == 0) flatbed.device_name = tpu.device_name;
    flatbed.max_resolution = @max(flatbed.max_resolution, tpu.max_resolution);
    flatbed.tpu_width_in = tpu.tpu_width_in;
    flatbed.tpu_height_in = tpu.tpu_height_in;
    flatbed.ir_supported = tpu.ir_supported;
    return flatbed;
}

fn saneMode(kind: contracts.ScanKind) []const u8 {
    return switch (kind) {
        .rgb => "Color",
        .gray, .ir => "Gray",
        .rgb_ir => unreachable,
    };
}

fn saneSource(source: contracts.Source) []const u8 {
    return switch (source) {
        .flatbed => "Flatbed",
        .tpu => "Transparency Unit",
    };
}

fn nearest(value: u32, choices: []const u32) u32 {
    var best = choices[0];
    var best_delta = delta(value, best);
    for (choices[1..]) |candidate| {
        const candidate_delta = delta(value, candidate);
        if (candidate_delta < best_delta) {
            best = candidate;
            best_delta = candidate_delta;
        }
    }
    return best;
}

fn delta(a: u32, b: u32) u32 {
    return if (a >= b) a - b else b - a;
}

fn clamp(value: f64, low: f64, high: f64) f64 {
    return @max(low, @min(value, high));
}

fn between(haystack: []const u8, left: []const u8, right: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, haystack, left) orelse return null;
    const body_start = start + left.len;
    const end_rel = std.mem.indexOf(u8, haystack[body_start..], right) orelse return null;
    return haystack[body_start .. body_start + end_rel];
}

fn parseLimitInches(line: []const u8) ?f64 {
    const start = std.mem.indexOf(u8, line, "0..") orelse return null;
    const after = start + 3;
    const end_rel = std.mem.indexOf(u8, line[after..], "mm") orelse return null;
    const mm = std.fmt.parseFloat(f64, line[after .. after + end_rel]) catch return null;
    return mm / millimeters_per_inch;
}

fn maxResolutionInLine(line: []const u8) u32 {
    var max: u32 = 0;
    var cursor: usize = 0;
    while (cursor < line.len) {
        while (cursor < line.len and !std.ascii.isDigit(line[cursor])) cursor += 1;
        const start = cursor;
        while (cursor < line.len and std.ascii.isDigit(line[cursor])) cursor += 1;
        if (cursor > start) {
            const value = std.fmt.parseInt(u32, line[start..cursor], 10) catch 0;
            if (value > max) max = value;
        }
    }
    return max;
}

test "plans RGB TPU scan through wrapper with area and output" {
    const allocator = std.testing.allocator;
    const caps = contracts.ScannerCapabilities{
        .device_name = "epkowa:interpreter:001:017",
        .tpu_width_in = 68.58 / 25.4,
        .tpu_height_in = 242.316 / 25.4,
    };
    const request = contracts.ScanRequest{
        .dpi = 3200,
        .source = .tpu,
        .kind = .rgb,
        .depth = .sixteen,
        .area = .{ .x = 0.1, .y = 0.2, .width = 1.5, .height = 2.0 },
        .output_path = "scan.tiff",
    };

    var plan = try planCommand(allocator, request, caps, .{ .scanimage_v600 = true });
    defer plan.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 3200), plan.effective_dpi);
    try std.testing.expectEqualStrings("scanimage-v600", plan.argv.items[0]);
    try expectArgSequence(plan.argv.items, &.{
        "--device-name", "epkowa:interpreter:001:017",
        "--mode", "Color",
        "--source", "Transparency Unit",
        "--resolution", "3200",
        "--format", "tiff",
        "--depth", "16",
        "-l", "2.5",
        "-t", "5.1",
        "-x", "38.1",
        "-y", "50.8",
        "-o", "scan.tiff",
    });
}

test "plans full-area RGB TPU scan without explicit area arguments" {
    const allocator = std.testing.allocator;
    const caps = contracts.ScannerCapabilities{ .device_name = "epkowa:interpreter:001:017" };
    const request = contracts.ScanRequest{
        .dpi = 400,
        .source = .tpu,
        .kind = .rgb,
        .depth = .sixteen,
        .output_path = "full.tiff",
    };

    var plan = try planCommand(allocator, request, caps, .{ .scanimage_v600 = true });
    defer plan.deinit(allocator);

    try expectArgSequence(plan.argv.items, &.{
        "--device-name", "epkowa:interpreter:001:017",
        "--mode", "Color",
        "--source", "Transparency Unit",
        "--resolution", "400",
        "--format", "tiff",
        "--depth", "16",
        "-o", "full.tiff",
    });
    try std.testing.expect(!containsArg(plan.argv.items, "-l"));
    try std.testing.expect(!containsArg(plan.argv.items, "-t"));
    try std.testing.expect(!containsArg(plan.argv.items, "-x"));
    try std.testing.expect(!containsArg(plan.argv.items, "-y"));
}

test "clamps oversized selected-area RGB TPU scan to scanner bounds" {
    const allocator = std.testing.allocator;
    const caps = contracts.ScannerCapabilities{
        .device_name = "epkowa:interpreter:001:017",
        .tpu_width_in = 68.58 / 25.4,
        .tpu_height_in = 242.316 / 25.4,
    };
    const request = contracts.ScanRequest{
        .dpi = 400,
        .source = .tpu,
        .kind = .rgb,
        .depth = .sixteen,
        .area = .{ .width = 100.0, .height = 100.0 },
        .output_path = "clamped.tiff",
    };

    var plan = try planCommand(allocator, request, caps, .{ .scanimage_v600 = true });
    defer plan.deinit(allocator);

    try expectArgSequence(plan.argv.items, &.{
        "-l", "0.0",
        "-t", "0.0",
        "-x", "68.5",
        "-y", "242.2",
        "-o", "clamped.tiff",
    });
}

test "rejects IR scan without the verified V600 IR wrapper" {
    const allocator = std.testing.allocator;
    const caps = contracts.ScannerCapabilities{ .device_name = "epkowa:interpreter:001:017" };
    const request = contracts.ScanRequest{
        .dpi = 400,
        .source = .tpu,
        .kind = .ir,
        .depth = .eight,
    };

    try std.testing.expectError(error.IrWrapperRequired, planCommand(allocator, request, caps, .{}));
}

test "plans selected-area IR scan through V600 IR wrapper" {
    const allocator = std.testing.allocator;
    const caps = contracts.ScannerCapabilities{ .device_name = "epkowa:interpreter:001:017" };
    const request = contracts.ScanRequest{
        .dpi = 400,
        .source = .flatbed,
        .kind = .ir,
        .depth = .eight,
        .area = .{ .x = 0.1, .y = 0.1, .width = 1.0, .height = 1.0 },
        .output_path = "ir.tiff",
    };

    var plan = try planCommand(allocator, request, caps, .{ .scanimage_v600_ir = true });
    defer plan.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 800), plan.effective_dpi);
    try std.testing.expect(!plan.env.scan_ir_mode);
    try std.testing.expectEqualStrings("scanimage-v600-ir", plan.argv.items[0]);
    try expectArgSequence(plan.argv.items, &.{
        "--mode", "Gray",
        "--source", "Transparency Unit",
        "--resolution", "800",
        "-l", "2.5",
        "-t", "2.5",
        "-x", "25.4",
        "-y", "25.4",
        "-o", "ir.tiff",
    });
    try std.testing.expect(!containsArg(plan.argv.items, "--depth"));
}

test "computes effective DPI for RGB and IR requests" {
    try std.testing.expectEqual(@as(u32, 400), effectiveDpiForRequest(.{
        .dpi = 200,
        .source = .tpu,
        .kind = .rgb,
    }));
    try std.testing.expectEqual(@as(u32, 800), effectiveDpiForRequest(.{
        .dpi = 400,
        .source = .flatbed,
        .kind = .ir,
    }));
    try std.testing.expectEqual(@as(u32, 1600), effectiveDpiForRequest(.{
        .dpi = 1600,
        .source = .tpu,
        .kind = .ir,
    }));
}

test "plans V600 LUT file environment for RGB scans only" {
    const allocator = std.testing.allocator;
    const caps = contracts.ScannerCapabilities{ .device_name = "epkowa:interpreter:001:017" };
    const rgb_request = contracts.ScanRequest{
        .dpi = 400,
        .source = .tpu,
        .kind = .rgb,
        .depth = .sixteen,
        .lut_file_path = "/tmp/cerealgrain-luts.bin",
        .output_path = "rgb.tiff",
    };
    var rgb_plan = try planCommand(allocator, rgb_request, caps, .{ .scanimage_v600 = true });
    defer rgb_plan.deinit(allocator);
    try std.testing.expectEqualStrings("/tmp/cerealgrain-luts.bin", rgb_plan.env.lut_file.?);

    var ir_request = rgb_request;
    ir_request.kind = .ir;
    ir_request.depth = .eight;
    var ir_plan = try planCommand(allocator, ir_request, caps, .{ .scanimage_v600_ir = true });
    defer ir_plan.deinit(allocator);
    try std.testing.expect(ir_plan.env.lut_file == null);
}

test "rejects RGB plus IR command planning outside runtime orchestration" {
    const allocator = std.testing.allocator;
    const request = contracts.ScanRequest{ .kind = .rgb_ir };
    try std.testing.expectError(error.CombinedScanRequiresRuntime, planCommand(allocator, request, .{}, .{}));
}

test "parses live-style TPU capability help" {
    const help =
        \\Options specific to device `epkowa:interpreter:001:017':
        \\    --resolution 400|800|1600|3200dpi [400]
        \\    -x 0..68.58mm [68.58]
        \\        Width of scan-area.
        \\    -y 0..242.316mm [242.316]
        \\        Height of scan-area.
        \\    --source Flatbed|Transparency Unit [Transparency Unit]
        \\
    ;
    const caps = parseCapabilities(help);
    try std.testing.expectEqualStrings("epkowa:interpreter:001:017", caps.device_name);
    try std.testing.expectEqual(@as(u32, 3200), caps.max_resolution);
    try std.testing.expectApproxEqAbs(68.58 / 25.4, caps.tpu_width_in, 0.0001);
    try std.testing.expectApproxEqAbs(242.316 / 25.4, caps.tpu_height_in, 0.0001);
}

test "combines flatbed and TPU capability help like the Python scanner layer" {
    const flatbed_help =
        \\Options specific to device `epkowa:interpreter:001:017':
        \\    --resolution 400|800|1600|3200dpi [400]
        \\    -x 0..215.9mm [215.9]
        \\    -y 0..297.18mm [297.18]
        \\    --source Flatbed|Transparency Unit [Flatbed]
        \\
    ;
    const tpu_help =
        \\Options specific to device `epkowa:interpreter:001:017':
        \\    --resolution 400|800|1600|3200dpi [400]
        \\    -x 0..68.58mm [68.58]
        \\    -y 0..242.316mm [242.316]
        \\    --source Flatbed|Transparency Unit [Transparency Unit]
        \\
    ;
    const caps = parseCombinedCapabilities(flatbed_help, tpu_help);
    try std.testing.expectApproxEqAbs(215.9 / 25.4, caps.flatbed_width_in, 0.0001);
    try std.testing.expectApproxEqAbs(297.18 / 25.4, caps.flatbed_height_in, 0.0001);
    try std.testing.expectApproxEqAbs(68.58 / 25.4, caps.tpu_width_in, 0.0001);
    try std.testing.expectApproxEqAbs(242.316 / 25.4, caps.tpu_height_in, 0.0001);
}

fn expectArgSequence(argv: []const []const u8, sequence: []const []const u8) !void {
    var cursor: usize = 0;
    for (sequence) |expected| {
        while (cursor < argv.len and !std.mem.eql(u8, argv[cursor], expected)) {
            cursor += 1;
        }
        if (cursor >= argv.len) {
            std.debug.print("missing arg: {s}\nargv:\n", .{expected});
            for (argv) |arg| std.debug.print("  {s}\n", .{arg});
            return error.MissingArgument;
        }
        cursor += 1;
    }
}

fn containsArg(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}
