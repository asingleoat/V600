const std = @import("std");
const builtin = @import("builtin");

const app_state = @import("../app_state.zig");
const scanner_contracts = @import("../scanner/contracts.zig");
const scanner_host = @import("../scanner.zig").host;

pub const ScanMode = enum {
    rgb_ir,
    rgb,
    ir,

    pub fn wireValue(self: ScanMode) []const u8 {
        return switch (self) {
            .rgb_ir => "rgb+ir",
            .rgb => "rgb",
            .ir => "ir",
        };
    }

    pub fn label(self: ScanMode) []const u8 {
        return switch (self) {
            .rgb_ir => "RGB + IR",
            .rgb => "RGB",
            .ir => "IR",
        };
    }

    // Linux TPU scans run only at 400, 800, 1600, and 3200 dpi
    // (scanner/sane.zig); anything else would be delivered at a different dpi.
    /// RGB modes go as high as this host's scanner backend allows (6400 on
    /// macOS); IR alone stops at 3200.
    pub fn validDpis(self: ScanMode) []const u32 {
        return switch (self) {
            .rgb_ir, .rgb => &scanner_host.film_dpis,
            .ir => &.{ 800, 1600, 3200 },
        };
    }

    pub fn closestDpi(self: ScanMode, requested: u32) u32 {
        const valid = self.validDpis();
        var closest = valid[0];
        var closest_delta = absDiff(closest, requested);
        for (valid[1..]) |dpi| {
            const delta = absDiff(dpi, requested);
            if (delta < closest_delta) {
                closest = dpi;
                closest_delta = delta;
            }
        }
        return closest;
    }
};

pub const ExposureMode = enum {
    linear,
    affine,

    pub fn wireValue(self: ExposureMode) []const u8 {
        return switch (self) {
            .linear => "linear",
            .affine => "affine",
        };
    }
};

pub const PreviewSelection = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    pub fn isDrawable(self: PreviewSelection) bool {
        return self.w >= 3.0 and self.h >= 3.0;
    }

    pub fn isPersistable(self: PreviewSelection) bool {
        return self.w >= 1.0 and self.h >= 1.0;
    }
};

pub const PreviewScreenRect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    scale: f64,
};

pub const PreviewSelectionEditMode = enum {
    move,
    north_west,
    north,
    north_east,
    east,
    south_east,
    south,
    south_west,
    west,
};

pub const AreaInches = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

pub const ScanSelectionEstimate = struct {
    w_in: f64,
    h_in: f64,
    w_mm: f64,
    h_mm: f64,
    output_width: u64,
    output_height: u64,
    mode: ScanMode,
    data_mb: f64,
    estimated_seconds: u64,
};

pub const DetectFilmAreaOptions = struct {
    /// Clear margin added on every side, so each scan includes clear light
    /// around the strip for frame detection. Medium format strips have no
    /// sprocket holes, so this margin is their only clear area.
    margin_in: f64 = 2.0 / 25.4,
};

pub fn previewSelectionFromDraw(
    start_x: f64,
    start_y: f64,
    current_x: f64,
    current_y: f64,
    preview_width: f64,
    preview_height: f64,
) PreviewSelection {
    const x2 = clampFloat(current_x, 0.0, preview_width);
    const y2 = clampFloat(current_y, 0.0, preview_height);
    return .{
        .x = @min(start_x, x2),
        .y = @min(start_y, y2),
        .w = @abs(x2 - start_x),
        .h = @abs(y2 - start_y),
    };
}

pub fn adjustedPreviewSelection(
    original: PreviewSelection,
    mode: PreviewSelectionEditMode,
    dx: f64,
    dy: f64,
    preview_width: f64,
    preview_height: f64,
) PreviewSelection {
    switch (mode) {
        .move => {
            const w = @min(original.w, preview_width);
            const h = @min(original.h, preview_height);
            return .{
                .x = clampFloat(original.x + dx, 0.0, @max(preview_width - w, 0.0)),
                .y = clampFloat(original.y + dy, 0.0, @max(preview_height - h, 0.0)),
                .w = w,
                .h = h,
            };
        },
        else => {},
    }

    var x = original.x;
    var y = original.y;
    var w = original.w;
    var h = original.h;
    switch (mode) {
        .north_west => {
            x += dx;
            w -= dx;
            y += dy;
            h -= dy;
        },
        .north => {
            y += dy;
            h -= dy;
        },
        .north_east => {
            w += dx;
            y += dy;
            h -= dy;
        },
        .east => w += dx,
        .south_east => {
            w += dx;
            h += dy;
        },
        .south => h += dy,
        .south_west => {
            x += dx;
            w -= dx;
            h += dy;
        },
        .west => {
            x += dx;
            w -= dx;
        },
        .move => unreachable,
    }

    if (w < 0.0) {
        x += w;
        w = -w;
    }
    if (h < 0.0) {
        y += h;
        h = -h;
    }

    x = clampFloat(x, 0.0, preview_width);
    y = clampFloat(y, 0.0, preview_height);
    w = @min(w, @max(preview_width - x, 0.0));
    h = @min(h, @max(preview_height - y, 0.0));
    return .{ .x = x, .y = y, .w = w, .h = h };
}

pub fn detectFilmAreaSelection(
    allocator: std.mem.Allocator,
    preview: []const u8,
    width: usize,
    height: usize,
    channels: usize,
    preview_dpi: u32,
    tpu_width_in: f64,
    tpu_height_in: f64,
    options: DetectFilmAreaOptions,
) !?PreviewSelection {
    if (width == 0 or height == 0 or channels == 0 or preview_dpi == 0) return null;
    if (tpu_width_in <= 0.0 or tpu_height_in <= 0.0) return null;
    const pixel_count = width * height;
    if (preview.len < pixel_count * channels) return error.InvalidPreviewBuffer;

    const gray = try allocator.alloc(f64, pixel_count);
    defer allocator.free(gray);
    for (0..pixel_count) |pixel_index| {
        const offset = pixel_index * channels;
        var sum: f64 = 0.0;
        for (0..channels) |channel_index| {
            sum += @floatFromInt(preview[offset + channel_index]);
        }
        gray[pixel_index] = sum / @as(f64, @floatFromInt(channels));
    }

    const sorted = try allocator.dupe(f64, gray);
    defer allocator.free(sorted);
    std.mem.sort(f64, sorted, {}, lessThanF64);
    const p25 = percentileSorted(sorted, 25.0);
    const p75 = percentileSorted(sorted, 75.0);
    const threshold = (p25 + p75) / 2.0;

    const labels = try allocator.alloc(u32, pixel_count);
    defer allocator.free(labels);
    @memset(labels, 0);
    const queue = try allocator.alloc(usize, pixel_count);
    defer allocator.free(queue);

    var next_label: u32 = 0;
    var largest_size: usize = 0;
    var largest_min_x: usize = 0;
    var largest_max_x: usize = 0;
    var largest_min_y: usize = 0;
    var largest_max_y: usize = 0;

    for (0..pixel_count) |start| {
        if (labels[start] != 0 or gray[start] >= threshold) continue;
        next_label += 1;
        labels[start] = next_label;
        queue[0] = start;
        var head: usize = 0;
        var tail: usize = 1;
        var size: usize = 0;
        var min_x = start % width;
        var max_x = min_x;
        var min_y = start / width;
        var max_y = min_y;

        while (head < tail) {
            const index = queue[head];
            head += 1;
            size += 1;
            const x = index % width;
            const y = index / width;
            min_x = @min(min_x, x);
            max_x = @max(max_x, x);
            min_y = @min(min_y, y);
            max_y = @max(max_y, y);

            if (x > 0) {
                enqueueDarkNeighbor(index - 1, next_label, gray, threshold, labels, queue, &tail);
            }
            if (x + 1 < width) {
                enqueueDarkNeighbor(index + 1, next_label, gray, threshold, labels, queue, &tail);
            }
            if (y > 0) {
                enqueueDarkNeighbor(index - width, next_label, gray, threshold, labels, queue, &tail);
            }
            if (y + 1 < height) {
                enqueueDarkNeighbor(index + width, next_label, gray, threshold, labels, queue, &tail);
            }
        }

        if (size > largest_size) {
            largest_size = size;
            largest_min_x = min_x;
            largest_max_x = max_x;
            largest_min_y = min_y;
            largest_max_y = max_y;
        }
    }

    if (largest_size == 0) return null;
    if (@as(f64, @floatFromInt(largest_size)) < @as(f64, @floatFromInt(pixel_count)) * 0.05) return null;

    const preview_dpi_f: f64 = @floatFromInt(preview_dpi);
    var x_in = @as(f64, @floatFromInt(largest_min_x)) / preview_dpi_f;
    var y_in = @as(f64, @floatFromInt(largest_min_y)) / preview_dpi_f;
    var w_in = @as(f64, @floatFromInt(largest_max_x - largest_min_x)) / preview_dpi_f;
    var h_in = @as(f64, @floatFromInt(largest_max_y - largest_min_y)) / preview_dpi_f;

    const right_in = @min(tpu_width_in, x_in + w_in + options.margin_in);
    const bottom_in = @min(tpu_height_in, y_in + h_in + options.margin_in);
    x_in = @max(0.0, x_in - options.margin_in);
    y_in = @max(0.0, y_in - options.margin_in);
    w_in = right_in - x_in;
    h_in = bottom_in - y_in;

    const width_f: f64 = @floatFromInt(width);
    const height_f: f64 = @floatFromInt(height);
    return .{
        .x = x_in / tpu_width_in * width_f,
        .y = y_in / tpu_height_in * height_f,
        .w = w_in / tpu_width_in * width_f,
        .h = h_in / tpu_height_in * height_f,
    };
}

pub const ScanControls = struct {
    dpi: u32 = 3200,
    mode: ScanMode = .rgb_ir,
    exposure: ExposureMode = .affine,
    autoselect: bool = true,
    selection: ?PreviewSelection = null,
    auto_selection: ?PreviewSelection = null,

    pub fn setMode(self: *ScanControls, mode: ScanMode) void {
        self.mode = mode;
        self.dpi = mode.closestDpi(self.dpi);
    }

    pub fn setDpi(self: *ScanControls, dpi: u32) void {
        self.dpi = self.mode.closestDpi(dpi);
    }

    pub fn setSelection(self: *ScanControls, selection: PreviewSelection) void {
        self.selection = if (selection.isDrawable()) selection else null;
    }

    pub fn setAutoSelection(self: *ScanControls, selection: PreviewSelection) void {
        self.auto_selection = selection;
        self.selection = selection;
    }

    pub fn restoreAutoSelection(self: *ScanControls) bool {
        if (self.auto_selection) |selection| {
            self.selection = selection;
            return true;
        }
        return false;
    }

    pub fn selectionForConfig(self: ScanControls, info: app_state.ScannerInfo) ?AreaInches {
        const selection = self.selection orelse return null;
        if (!selection.isPersistable() or !hasPreviewGeometry(info)) return null;
        return .{
            .x = selection.x / @as(f64, @floatFromInt(info.preview_width)) * info.tpu_width_in,
            .y = selection.y / @as(f64, @floatFromInt(info.preview_height)) * info.tpu_height_in,
            .w = selection.w / @as(f64, @floatFromInt(info.preview_width)) * info.tpu_width_in,
            .h = selection.h / @as(f64, @floatFromInt(info.preview_height)) * info.tpu_height_in,
        };
    }

    pub fn selectionForScanStart(self: ScanControls, info: app_state.ScannerInfo) ?AreaInches {
        const selection = self.selection orelse return null;
        if (!selection.isPersistable() or !hasPreviewGeometry(info)) return null;
        return .{
            .x = info.tpu_width_in - (selection.x + selection.w) / @as(f64, @floatFromInt(info.preview_width)) * info.tpu_width_in,
            .y = selection.y / @as(f64, @floatFromInt(info.preview_height)) * info.tpu_height_in,
            .w = selection.w / @as(f64, @floatFromInt(info.preview_width)) * info.tpu_width_in,
            .h = selection.h / @as(f64, @floatFromInt(info.preview_height)) * info.tpu_height_in,
        };
    }

    pub fn restoreSelectionFromConfig(self: *ScanControls, area: AreaInches, info: app_state.ScannerInfo) bool {
        if (!hasPreviewGeometry(info)) return false;
        self.selection = .{
            .x = area.x / info.tpu_width_in * @as(f64, @floatFromInt(info.preview_width)),
            .y = area.y / info.tpu_height_in * @as(f64, @floatFromInt(info.preview_height)),
            .w = area.w / info.tpu_width_in * @as(f64, @floatFromInt(info.preview_width)),
            .h = area.h / info.tpu_height_in * @as(f64, @floatFromInt(info.preview_height)),
        };
        return true;
    }
};

pub const PreviewScanPlan = struct {
    request: scanner_contracts.ScanRequest,
    output_path: []const u8,
};

pub const ScanStartPlan = struct {
    request: scanner_contracts.ScanRequest,
    output_path: []const u8,
    cancel_file_path: ?[]const u8 = null,
    preview_selection: ?PreviewSelection = null,
    exposure: ExposureMode = .affine,
    mode: ScanMode = .rgb_ir,
    /// A roll's gamma LUT file, used as is instead of one computed from the
    /// preview; the scan worker does not delete it.
    roll_lut_path: ?[]const u8 = null,
};

pub fn previewScanPlan(info: app_state.ScannerInfo, preview_dpi: u32, output_path: []const u8) ?PreviewScanPlan {
    if (info.tpu_width_in <= 0.0 or info.tpu_height_in <= 0.0) return null;
    return .{
        .request = .{
            .dpi = preview_dpi,
            .source = .tpu,
            .kind = .rgb,
            .depth = .eight,
            .area = .{
                .x = 0.0,
                .y = 0.0,
                .width = info.tpu_width_in,
                .height = info.tpu_height_in,
            },
            .output_path = output_path,
        },
        .output_path = output_path,
    };
}

pub fn scanStartPlan(
    info: app_state.ScannerInfo,
    controls: ScanControls,
    output_path: []const u8,
    cancel_file_path: ?[]const u8,
) ?ScanStartPlan {
    const selection = controls.selection orelse return null;
    if (!selection.isDrawable()) return null;
    const area = controls.selectionForScanStart(info) orelse return null;
    return .{
        .request = .{
            .dpi = controls.dpi,
            .source = .tpu,
            .kind = scanKind(controls.mode),
            .depth = scanDepth(controls.mode),
            .area = .{
                .x = area.x,
                .y = area.y,
                .width = area.w,
                .height = area.h,
            },
            .output_path = output_path,
        },
        .output_path = output_path,
        .cancel_file_path = cancel_file_path,
        .preview_selection = selection,
        .exposure = controls.exposure,
        .mode = controls.mode,
    };
}

pub fn scanSelectionEstimate(controls: ScanControls, info: app_state.ScannerInfo) ?ScanSelectionEstimate {
    const selection = controls.selection orelse return null;
    if (!selection.isPersistable() or !hasPreviewGeometry(info)) return null;

    const w_in = roundToPlaces(selection.w / @as(f64, @floatFromInt(info.preview_width)) * info.tpu_width_in, 2);
    const h_in = roundToPlaces(selection.h / @as(f64, @floatFromInt(info.preview_height)) * info.tpu_height_in, 2);
    const output_width = roundToU64(w_in * @as(f64, @floatFromInt(controls.dpi)));
    const output_height = roundToU64(h_in * @as(f64, @floatFromInt(controls.dpi)));
    const bytes_per_sample: f64 = 2.0;
    const data_mb = switch (controls.mode) {
        .rgb_ir => blk: {
            const ir_dpi = @min(controls.dpi, 3200);
            const ir_w = roundToU64(w_in * @as(f64, @floatFromInt(ir_dpi)));
            const ir_h = roundToU64(h_in * @as(f64, @floatFromInt(ir_dpi)));
            const rgb_bytes = @as(f64, @floatFromInt(output_width)) *
                @as(f64, @floatFromInt(output_height)) * 3.0 * bytes_per_sample;
            const ir_bytes = @as(f64, @floatFromInt(ir_w)) * @as(f64, @floatFromInt(ir_h));
            break :blk (rgb_bytes + ir_bytes) / 1024.0 / 1024.0;
        },
        .rgb => @as(f64, @floatFromInt(output_width)) *
            @as(f64, @floatFromInt(output_height)) * 3.0 * bytes_per_sample / 1024.0 / 1024.0,
        .ir => @as(f64, @floatFromInt(output_width)) *
            @as(f64, @floatFromInt(output_height)) / 1024.0 / 1024.0,
    };
    const passes: f64 = if (controls.mode == .rgb_ir) 2.0 else 1.0;
    return .{
        .w_in = w_in,
        .h_in = h_in,
        .w_mm = roundToPlaces(w_in * 25.4, 1),
        .h_mm = roundToPlaces(h_in * 25.4, 1),
        .output_width = output_width,
        .output_height = output_height,
        .mode = controls.mode,
        .data_mb = roundToPlaces(data_mb, 1),
        // Measured on a V600 over macOS USB: about 1.8 MB/s plus 40 s per
        // pass (a 35 mm strip took 1m45s at 800 dpi and 9m20s at 3200).
        .estimated_seconds = roundToU64(data_mb / 1.8 + passes * 40.0),
    };
}

pub fn formatScanSelectionEstimate(
    buffer: []u8,
    controls: ScanControls,
    info: app_state.ScannerInfo,
) !?[]const u8 {
    const estimate = scanSelectionEstimate(controls, info) orelse return null;
    var time_buffer: [32]u8 = undefined;
    const time = try formatEstimateSeconds(&time_buffer, estimate.estimated_seconds);
    return try std.fmt.bufPrint(
        buffer,
        "{d:.2}\" x {d:.2}\" ({d:.1} x {d:.1} mm) -> {d}x{d}px {s} ({d:.1} MB, {s})",
        .{
            estimate.w_in,
            estimate.h_in,
            estimate.w_mm,
            estimate.h_mm,
            estimate.output_width,
            estimate.output_height,
            scanEstimateModeLabel(estimate.mode),
            estimate.data_mb,
            time,
        },
    );
}

pub fn scanOutputFilename(buffer: []u8, controls: ScanControls, scan_counter: usize) ![]u8 {
    return try std.fmt.bufPrint(
        buffer,
        "scan_{d:0>4}_{s}_{d}dpi.tiff",
        .{ scan_counter, scanModeTag(controls.mode), controls.dpi },
    );
}

pub fn scanOutputPath(buffer: []u8, output_dir: []const u8, controls: ScanControls, scan_counter: usize) ![]u8 {
    var filename_buffer: [128]u8 = undefined;
    const filename = try scanOutputFilename(&filename_buffer, controls, scan_counter);
    if (output_dir.len == 0) {
        return try std.fmt.bufPrint(buffer, "{s}", .{filename});
    }
    if (std.mem.endsWith(u8, output_dir, "/")) {
        return try std.fmt.bufPrint(buffer, "{s}{s}", .{ output_dir, filename });
    }
    return try std.fmt.bufPrint(buffer, "{s}/{s}", .{ output_dir, filename });
}

pub const RgbIrProgressWeights = struct {
    ir_dpi: u32,
    rgb_weight: f64,
    ir_weight: f64,
};

pub fn handleScanFormatElapsed(buffer: []u8, elapsed_seconds: f64) ![]u8 {
    return formatSeconds(buffer, elapsed_seconds);
}

pub fn handleScanFormatEta(buffer: []u8, eta_seconds: f64) ![]u8 {
    return formatSeconds(buffer, eta_seconds);
}

pub fn handleScanInitialStatus(buffer: []u8, mode: ScanMode, dpi: u32) ![]u8 {
    return switch (mode) {
        .rgb_ir => std.fmt.bufPrint(buffer, "Pass 1/2: Scanning RGB at {d} DPI...", .{dpi}),
        .rgb => std.fmt.bufPrint(buffer, "Scanning RGB at {d} DPI...", .{dpi}),
        .ir => std.fmt.bufPrint(buffer, "Scanning IR at {d} DPI...", .{dpi}),
    };
}

pub fn handleScanRgbIrSecondPassStatus(buffer: []u8, dpi: u32) ![]u8 {
    return std.fmt.bufPrint(buffer, "Pass 2/2: Scanning IR at {d} DPI...", .{rgbIrProgressWeights(dpi).ir_dpi});
}

pub fn handleScanRgbProgressStatus(
    buffer: []u8,
    dpi: u32,
    percent: u8,
    eta_seconds: f64,
    elapsed_seconds: f64,
) ![]u8 {
    const weights = rgbIrProgressWeights(dpi);
    const total_pct: u64 = @intFromFloat(@as(f64, @floatFromInt(percent)) * weights.rgb_weight);
    const total_eta = rgbIrTotalEtaSeconds(dpi, percent, eta_seconds);
    var eta_buffer: [32]u8 = undefined;
    var elapsed_buffer: [32]u8 = undefined;
    const eta = try handleScanFormatEta(&eta_buffer, total_eta);
    const elapsed = try handleScanFormatElapsed(&elapsed_buffer, elapsed_seconds);
    return std.fmt.bufPrint(
        buffer,
        "RGB {d}%, total {d}%, ETA {s}, elapsed {s}",
        .{ percent, total_pct, eta, elapsed },
    );
}

pub fn handleScanIrProgressStatus(
    buffer: []u8,
    dpi: u32,
    percent: u8,
    eta_seconds: f64,
    elapsed_seconds: f64,
) ![]u8 {
    const weights = rgbIrProgressWeights(dpi);
    const total_pct: u64 = @intFromFloat(100.0 * weights.rgb_weight + @as(f64, @floatFromInt(percent)) * weights.ir_weight);
    var eta_buffer: [32]u8 = undefined;
    var elapsed_buffer: [32]u8 = undefined;
    const eta = try handleScanFormatEta(&eta_buffer, eta_seconds);
    const elapsed = try handleScanFormatElapsed(&elapsed_buffer, elapsed_seconds);
    return std.fmt.bufPrint(
        buffer,
        "IR {d}%, total {d}%, ETA {s}, elapsed {s}",
        .{ percent, total_pct, eta, elapsed },
    );
}

pub fn handleScanSingleProgressStatus(
    buffer: []u8,
    mode: ScanMode,
    percent: u8,
    eta_seconds: f64,
    elapsed_seconds: f64,
) ![]u8 {
    const mode_tag = switch (mode) {
        .rgb_ir, .rgb => "RGB",
        .ir => "IR",
    };
    var eta_buffer: [32]u8 = undefined;
    var elapsed_buffer: [32]u8 = undefined;
    const eta = try handleScanFormatEta(&eta_buffer, eta_seconds);
    const elapsed = try handleScanFormatElapsed(&elapsed_buffer, elapsed_seconds);
    return std.fmt.bufPrint(
        buffer,
        "{s} {d}%, ETA {s}, elapsed {s}",
        .{ mode_tag, percent, eta, elapsed },
    );
}

pub fn handleScanSavedStatus(buffer: []u8, output_path: []const u8) ![]u8 {
    return std.fmt.bufPrint(buffer, "Saved: {s}", .{std.fs.path.basename(output_path)});
}

pub fn handleScanErrorStatus(buffer: []u8, detail: []const u8) ![]u8 {
    return std.fmt.bufPrint(buffer, "Error: {s}", .{detail});
}

pub fn rgbIrTotalEtaSeconds(dpi: u32, rgb_percent: u8, rgb_eta_seconds: f64) f64 {
    const safe_percent = @max(rgb_percent, 1);
    return rgb_eta_seconds + rgb_eta_seconds / @as(f64, @floatFromInt(safe_percent)) * 100.0 * rgbIrProgressWeights(dpi).ir_weight;
}

pub fn rgbIrProgressWeights(dpi: u32) RgbIrProgressWeights {
    const ir_dpi = @min(dpi, 3200);
    const ratio = @as(f64, @floatFromInt(ir_dpi)) / @as(f64, @floatFromInt(dpi));
    const ir_pixel_ratio = ratio * ratio;
    return .{
        .ir_dpi = ir_dpi,
        .rgb_weight = 3.0 / (3.0 + ir_pixel_ratio),
        .ir_weight = ir_pixel_ratio / (3.0 + ir_pixel_ratio),
    };
}

fn scanKind(mode: ScanMode) scanner_contracts.ScanKind {
    return switch (mode) {
        .rgb_ir => .rgb_ir,
        .rgb => .rgb,
        .ir => .ir,
    };
}

fn scanDepth(mode: ScanMode) scanner_contracts.BitDepth {
    return switch (mode) {
        .rgb_ir, .rgb => .sixteen,
        .ir => .eight,
    };
}

fn scanModeTag(mode: ScanMode) []const u8 {
    return switch (mode) {
        .rgb_ir => "rgbir",
        .rgb => "rgb",
        .ir => "ir",
    };
}

fn hasPreviewGeometry(info: app_state.ScannerInfo) bool {
    return info.preview_width > 0 and
        info.preview_height > 0 and
        info.tpu_width_in > 0.0 and
        info.tpu_height_in > 0.0;
}

fn absDiff(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

fn clampFloat(value: f64, min_value: f64, max_value: f64) f64 {
    return @min(@max(value, min_value), max_value);
}

fn enqueueDarkNeighbor(
    index: usize,
    label: u32,
    gray: []const f64,
    threshold: f64,
    labels: []u32,
    queue: []usize,
    tail: *usize,
) void {
    if (labels[index] != 0 or gray[index] >= threshold) return;
    labels[index] = label;
    queue[tail.*] = index;
    tail.* += 1;
}

fn percentileSorted(data: []const f64, percentile: f64) f64 {
    if (data.len == 0) return 0.0;
    if (data.len == 1) return data[0];
    const position = (@as(f64, @floatFromInt(data.len - 1)) * percentile) / 100.0;
    const lower: usize = @intFromFloat(@floor(position));
    const upper: usize = @intFromFloat(@ceil(position));
    if (lower == upper) return data[lower];
    const fraction = position - @as(f64, @floatFromInt(lower));
    return data[lower] * (1.0 - fraction) + data[upper] * fraction;
}

fn lessThanF64(_: void, lhs: f64, rhs: f64) bool {
    return lhs < rhs;
}

fn formatSeconds(buffer: []u8, seconds: f64) ![]u8 {
    const whole_seconds: u64 = @intFromFloat(seconds);
    if (whole_seconds >= 60) {
        return std.fmt.bufPrint(buffer, "{d}m{d:0>2}s", .{ whole_seconds / 60, whole_seconds % 60 });
    }
    return std.fmt.bufPrint(buffer, "{d}s", .{whole_seconds});
}

fn formatEstimateSeconds(buffer: []u8, seconds: u64) ![]u8 {
    if (seconds >= 60) {
        return std.fmt.bufPrint(buffer, "~{d}m{d:0>2}s", .{ seconds / 60, seconds % 60 });
    }
    return std.fmt.bufPrint(buffer, "~{d}s", .{seconds});
}

fn scanEstimateModeLabel(mode: ScanMode) []const u8 {
    return switch (mode) {
        .rgb_ir => "RGB+IR",
        .rgb => "RGB",
        .ir => "IR",
    };
}

fn roundToPlaces(value: f64, comptime places: u8) f64 {
    comptime var factor: f64 = 1.0;
    inline for (0..places) |_| factor *= 10.0;
    return @round(value * factor) / factor;
}

fn roundToU64(value: f64) u64 {
    return @intFromFloat(@round(value));
}

test "scan controls preserve browser mode dpi choices" {
    var controls = ScanControls{};
    try std.testing.expectEqual(@as(u32, 3200), controls.dpi);
    try std.testing.expectEqual(ScanMode.rgb_ir, controls.mode);
    try std.testing.expectEqualStrings("rgb+ir", controls.mode.wireValue());
    try std.testing.expectEqualStrings("affine", controls.exposure.wireValue());
    try std.testing.expect(controls.autoselect);

    controls.setDpi(1200);
    try std.testing.expectEqual(@as(u32, 800), controls.dpi);

    controls.setMode(.rgb);
    controls.setDpi(1200);
    try std.testing.expectEqual(@as(u32, 800), controls.dpi);

    controls.setDpi(6400);
    // RGB goes to 6400 where the backend allows it (the macOS interpreter).
    const rgb_max: u32 = if (builtin.os.tag == .macos) 6400 else 3200;
    try std.testing.expectEqual(rgb_max, controls.dpi);
    controls.setMode(.ir);
    try std.testing.expectEqual(@as(u32, 3200), controls.dpi);
}

test "scan controls convert preview selections to config and mirrored scan area" {
    const info = app_state.ScannerInfo{
        .preview_width = 1000,
        .preview_height = 500,
        .tpu_width_in = 10.0,
        .tpu_height_in = 5.0,
        .scan_counter = 1,
    };
    var controls = ScanControls{};
    controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });

    const config_area = controls.selectionForConfig(info).?;
    try std.testing.expectApproxEqAbs(1.0, config_area.x, 0.0);
    try std.testing.expectApproxEqAbs(0.5, config_area.y, 0.0);
    try std.testing.expectApproxEqAbs(2.0, config_area.w, 0.0);
    try std.testing.expectApproxEqAbs(1.0, config_area.h, 0.0);

    const scan_area = controls.selectionForScanStart(info).?;
    try std.testing.expectApproxEqAbs(7.0, scan_area.x, 0.0);
    try std.testing.expectApproxEqAbs(0.5, scan_area.y, 0.0);
    try std.testing.expectApproxEqAbs(2.0, scan_area.w, 0.0);
    try std.testing.expectApproxEqAbs(1.0, scan_area.h, 0.0);
}

test "scan selection estimate counts 8-bit IR at up to 3200 dpi and the measured scan rate" {
    const info = app_state.ScannerInfo{
        .preview_width = 1000,
        .preview_height = 500,
        .tpu_width_in = 10.0,
        .tpu_height_in = 5.0,
        .scan_counter = 1,
    };
    var controls = ScanControls{};
    controls.selection = .{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 };

    var buffer: [192]u8 = undefined;
    controls.mode = .rgb_ir;
    controls.dpi = 6400;
    try std.testing.expectEqualStrings(
        "2.00\" x 1.00\" (50.8 x 25.4 mm) -> 12800x6400px RGB+IR (488.3 MB, ~5m51s)",
        (try formatScanSelectionEstimate(&buffer, controls, info)).?,
    );

    controls.mode = .rgb;
    controls.dpi = 6400;
    try std.testing.expectEqualStrings(
        "2.00\" x 1.00\" (50.8 x 25.4 mm) -> 12800x6400px RGB (468.8 MB, ~5m00s)",
        (try formatScanSelectionEstimate(&buffer, controls, info)).?,
    );

    controls.mode = .ir;
    controls.dpi = 6400;
    try std.testing.expectEqualStrings(
        "2.00\" x 1.00\" (50.8 x 25.4 mm) -> 12800x6400px IR (78.1 MB, ~1m23s)",
        (try formatScanSelectionEstimate(&buffer, controls, info)).?,
    );

    controls.setMode(.ir);
    controls.setDpi(6400);
    try std.testing.expectEqual(@as(u32, 3200), controls.dpi);
    try std.testing.expectEqualStrings(
        "2.00\" x 1.00\" (50.8 x 25.4 mm) -> 6400x3200px IR (19.5 MB, ~51s)",
        (try formatScanSelectionEstimate(&buffer, controls, info)).?,
    );
}

test "scan selection estimate updates with selection mode and dpi" {
    const info = app_state.ScannerInfo{
        .preview_width = 1000,
        .preview_height = 500,
        .tpu_width_in = 10.0,
        .tpu_height_in = 5.0,
        .scan_counter = 1,
    };
    var controls = ScanControls{};
    controls.selection = .{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 };

    var initial_buffer: [192]u8 = undefined;
    const initial = try std.testing.allocator.dupe(u8, (try formatScanSelectionEstimate(&initial_buffer, controls, info)).?);
    defer std.testing.allocator.free(initial);

    controls.selection = .{ .x = 100.0, .y = 50.0, .w = 300.0, .h = 100.0 };
    var resized_buffer: [192]u8 = undefined;
    const resized = try std.testing.allocator.dupe(u8, (try formatScanSelectionEstimate(&resized_buffer, controls, info)).?);
    defer std.testing.allocator.free(resized);
    try std.testing.expect(!std.mem.eql(u8, initial, resized));

    controls.setMode(.rgb);
    controls.setDpi(6400);
    var mode_buffer: [192]u8 = undefined;
    const mode_changed = (try formatScanSelectionEstimate(&mode_buffer, controls, info)).?;
    try std.testing.expect(!std.mem.eql(u8, resized, mode_changed));

    controls.selection = null;
    try std.testing.expect((try formatScanSelectionEstimate(&mode_buffer, controls, info)) == null);
}

test "scan controls restore saved and auto-detected selections" {
    const info = app_state.ScannerInfo{
        .preview_width = 1000,
        .preview_height = 500,
        .tpu_width_in = 10.0,
        .tpu_height_in = 5.0,
        .scan_counter = 1,
    };
    var controls = ScanControls{};
    try std.testing.expect(controls.restoreSelectionFromConfig(.{ .x = 1.0, .y = 0.5, .w = 2.0, .h = 1.0 }, info));
    var selection = controls.selection.?;
    try std.testing.expectApproxEqAbs(100.0, selection.x, 0.0);
    try std.testing.expectApproxEqAbs(50.0, selection.y, 0.0);
    try std.testing.expectApproxEqAbs(200.0, selection.w, 0.0);
    try std.testing.expectApproxEqAbs(100.0, selection.h, 0.0);

    controls.setSelection(.{ .x = 1.0, .y = 1.0, .w = 2.0, .h = 2.0 });
    try std.testing.expect(controls.selection == null);

    controls.setAutoSelection(.{ .x = 10.0, .y = 20.0, .w = 30.0, .h = 40.0 });
    controls.setSelection(.{ .x = 200.0, .y = 210.0, .w = 220.0, .h = 230.0 });
    try std.testing.expect(controls.restoreAutoSelection());
    selection = controls.selection.?;
    try std.testing.expectApproxEqAbs(10.0, selection.x, 0.0);
    try std.testing.expectApproxEqAbs(20.0, selection.y, 0.0);
    try std.testing.expectApproxEqAbs(30.0, selection.w, 0.0);
    try std.testing.expectApproxEqAbs(40.0, selection.h, 0.0);
}

test "scan preview selection draw move and resize mirror browser canvas math" {
    var selection = previewSelectionFromDraw(20.0, 30.0, 80.0, 70.0, 100.0, 90.0);
    try std.testing.expectApproxEqAbs(20.0, selection.x, 0.0);
    try std.testing.expectApproxEqAbs(30.0, selection.y, 0.0);
    try std.testing.expectApproxEqAbs(60.0, selection.w, 0.0);
    try std.testing.expectApproxEqAbs(40.0, selection.h, 0.0);
    try std.testing.expect(selection.isDrawable());

    selection = previewSelectionFromDraw(20.0, 30.0, -10.0, 120.0, 100.0, 90.0);
    try std.testing.expectApproxEqAbs(0.0, selection.x, 0.0);
    try std.testing.expectApproxEqAbs(30.0, selection.y, 0.0);
    try std.testing.expectApproxEqAbs(20.0, selection.w, 0.0);
    try std.testing.expectApproxEqAbs(60.0, selection.h, 0.0);

    selection = adjustedPreviewSelection(.{ .x = 20.0, .y = 30.0, .w = 60.0, .h = 40.0 }, .move, 30.0, 25.0, 100.0, 90.0);
    try std.testing.expectApproxEqAbs(40.0, selection.x, 0.0);
    try std.testing.expectApproxEqAbs(50.0, selection.y, 0.0);
    try std.testing.expectApproxEqAbs(60.0, selection.w, 0.0);
    try std.testing.expectApproxEqAbs(40.0, selection.h, 0.0);

    selection = adjustedPreviewSelection(.{ .x = 20.0, .y = 30.0, .w = 60.0, .h = 40.0 }, .south_east, 15.0, 10.0, 100.0, 90.0);
    try std.testing.expectApproxEqAbs(20.0, selection.x, 0.0);
    try std.testing.expectApproxEqAbs(30.0, selection.y, 0.0);
    try std.testing.expectApproxEqAbs(75.0, selection.w, 0.0);
    try std.testing.expectApproxEqAbs(50.0, selection.h, 0.0);

    selection = adjustedPreviewSelection(.{ .x = 20.0, .y = 30.0, .w = 60.0, .h = 40.0 }, .north_west, 75.0, 50.0, 100.0, 90.0);
    try std.testing.expectApproxEqAbs(80.0, selection.x, 0.0);
    try std.testing.expectApproxEqAbs(70.0, selection.y, 0.0);
    try std.testing.expectApproxEqAbs(15.0, selection.w, 0.0);
    try std.testing.expectApproxEqAbs(10.0, selection.h, 0.0);

    const tiny = previewSelectionFromDraw(10.0, 10.0, 12.0, 12.0, 100.0, 90.0);
    try std.testing.expect(!tiny.isDrawable());
}

test "scan preview film-area detection selects the largest dark region plus a clear margin" {
    var preview = [_]u8{200} ** (10 * 6 * 3);
    var y: usize = 1;
    while (y <= 4) : (y += 1) {
        var x: usize = 2;
        while (x <= 6) : (x += 1) {
            const offset = (y * 10 + x) * 3;
            preview[offset] = 20;
            preview[offset + 1] = 20;
            preview[offset + 2] = 20;
        }
    }

    const selection = (try detectFilmAreaSelection(
        std.testing.allocator,
        &preview,
        10,
        6,
        3,
        10,
        1.0,
        0.6,
        .{ .margin_in = 0.08 },
    )).?;
    // The dark block spans 0.2-0.6 in across and 0.1-0.4 in down at 10 dpi;
    // the margin adds 0.08 in per side, clamped to the bed (0.6 in tall).
    try std.testing.expectApproxEqAbs(1.2, selection.x, 0.000001);
    try std.testing.expectApproxEqAbs(0.2, selection.y, 0.000001);
    try std.testing.expectApproxEqAbs(5.6, selection.w, 0.000001);
    try std.testing.expectApproxEqAbs(4.6, selection.h, 0.000001);
}

test "scan preview film-area detection rejects tiny dark components" {
    var preview = [_]u8{200} ** (10 * 10);
    preview[11] = 20;
    preview[12] = 20;
    preview[21] = 20;
    preview[22] = 20;

    const selection = try detectFilmAreaSelection(
        std.testing.allocator,
        &preview,
        10,
        10,
        1,
        10,
        1.0,
        1.0,
        .{},
    );
    try std.testing.expect(selection == null);
}

test "preview scan plan matches browser preview request shape" {
    const info = app_state.ScannerInfo{
        .preview_width = 0,
        .preview_height = 0,
        .tpu_width_in = 2.7,
        .tpu_height_in = 9.54,
        .scan_counter = 1,
    };
    const plan = previewScanPlan(info, 200, "/tmp/v600-preview.tiff").?;
    try std.testing.expectEqual(@as(u32, 200), plan.request.dpi);
    try std.testing.expectEqual(scanner_contracts.Source.tpu, plan.request.source);
    try std.testing.expectEqual(scanner_contracts.ScanKind.rgb, plan.request.kind);
    try std.testing.expectEqual(scanner_contracts.BitDepth.eight, plan.request.depth);
    try std.testing.expectApproxEqAbs(0.0, plan.request.area.x, 0.0);
    try std.testing.expectApproxEqAbs(0.0, plan.request.area.y, 0.0);
    try std.testing.expectApproxEqAbs(2.7, plan.request.area.width.?, 0.0);
    try std.testing.expectApproxEqAbs(9.54, plan.request.area.height.?, 0.0);
    try std.testing.expectEqualStrings("/tmp/v600-preview.tiff", plan.output_path);
    try std.testing.expectEqualStrings("/tmp/v600-preview.tiff", plan.request.output_path.?);

    const missing = app_state.ScannerInfo{
        .preview_width = 0,
        .preview_height = 0,
        .tpu_width_in = 0.0,
        .tpu_height_in = 0.0,
        .scan_counter = 1,
    };
    try std.testing.expect(previewScanPlan(missing, 200, "/tmp/v600-preview.tiff") == null);
}

test "scan start plan mirrors browser scan-start request shape" {
    const info = app_state.ScannerInfo{
        .preview_width = 1000,
        .preview_height = 500,
        .tpu_width_in = 10.0,
        .tpu_height_in = 5.0,
        .scan_counter = 1,
    };
    var controls = ScanControls{};
    controls.setSelection(.{ .x = 100.0, .y = 50.0, .w = 200.0, .h = 100.0 });

    var filename_buffer: [128]u8 = undefined;
    const filename = try scanOutputFilename(&filename_buffer, controls, 1);
    try std.testing.expectEqualStrings("scan_0001_rgbir_3200dpi.tiff", filename);

    var path_buffer: [256]u8 = undefined;
    const path = try scanOutputPath(&path_buffer, "scans", controls, 1);
    try std.testing.expectEqualStrings("scans/scan_0001_rgbir_3200dpi.tiff", path);

    const plan = scanStartPlan(info, controls, path, ".zig-cache/v600-scan.cancel").?;
    try std.testing.expectEqual(@as(u32, 3200), plan.request.dpi);
    try std.testing.expectEqual(scanner_contracts.Source.tpu, plan.request.source);
    try std.testing.expectEqual(scanner_contracts.ScanKind.rgb_ir, plan.request.kind);
    try std.testing.expectEqual(scanner_contracts.BitDepth.sixteen, plan.request.depth);
    try std.testing.expectApproxEqAbs(7.0, plan.request.area.x, 0.0);
    try std.testing.expectApproxEqAbs(0.5, plan.request.area.y, 0.0);
    try std.testing.expectApproxEqAbs(2.0, plan.request.area.width.?, 0.0);
    try std.testing.expectApproxEqAbs(1.0, plan.request.area.height.?, 0.0);
    try std.testing.expectEqualStrings(path, plan.output_path);
    try std.testing.expectEqualStrings(path, plan.request.output_path.?);
    try std.testing.expectEqualStrings(".zig-cache/v600-scan.cancel", plan.cancel_file_path.?);
    try std.testing.expectEqual(ExposureMode.affine, plan.exposure);
    try std.testing.expectApproxEqAbs(100.0, plan.preview_selection.?.x, 0.0);

    controls.setMode(.ir);
    controls.setDpi(1600);
    const ir_filename = try scanOutputFilename(&filename_buffer, controls, 12);
    try std.testing.expectEqualStrings("scan_0012_ir_1600dpi.tiff", ir_filename);
    const ir_plan = scanStartPlan(info, controls, ir_filename, null).?;
    try std.testing.expectEqual(scanner_contracts.ScanKind.ir, ir_plan.request.kind);
    try std.testing.expectEqual(scanner_contracts.BitDepth.eight, ir_plan.request.depth);

    controls.selection = null;
    try std.testing.expect(scanStartPlan(info, controls, path, null) == null);

    controls.selection = .{ .x = 100.0, .y = 50.0, .w = 2.0, .h = 100.0 };
    try std.testing.expect(scanStartPlan(info, controls, path, null) == null);
}

test "handle scan status helpers mirror python nested functions" {
    var buffer: [160]u8 = undefined;

    try std.testing.expectEqualStrings("0s", try handleScanFormatElapsed(&buffer, 0.0));
    try std.testing.expectEqualStrings("59s", try handleScanFormatElapsed(&buffer, 59.9));
    try std.testing.expectEqualStrings("1m05s", try handleScanFormatElapsed(&buffer, 65.2));
    try std.testing.expectEqualStrings("2m05s", try handleScanFormatEta(&buffer, 125.9));

    try std.testing.expectEqualStrings(
        "Pass 1/2: Scanning RGB at 6400 DPI...",
        try handleScanInitialStatus(&buffer, .rgb_ir, 6400),
    );
    try std.testing.expectEqualStrings(
        "Pass 2/2: Scanning IR at 3200 DPI...",
        try handleScanRgbIrSecondPassStatus(&buffer, 6400),
    );
    try std.testing.expectEqualStrings(
        "Scanning RGB at 3200 DPI...",
        try handleScanInitialStatus(&buffer, .rgb, 3200),
    );
    try std.testing.expectEqualStrings(
        "Scanning IR at 1600 DPI...",
        try handleScanInitialStatus(&buffer, .ir, 1600),
    );

    const weights = rgbIrProgressWeights(6400);
    try std.testing.expectEqual(@as(u32, 3200), weights.ir_dpi);
    try std.testing.expectApproxEqAbs(0.9230769230769231, weights.rgb_weight, 0.000000000001);
    try std.testing.expectApproxEqAbs(0.07692307692307693, weights.ir_weight, 0.000000000001);

    try std.testing.expectEqualStrings(
        "RGB 37%, total 34%, ETA 2m32s, elapsed 1m05s",
        try handleScanRgbProgressStatus(&buffer, 6400, 37, 125.9, 65.2),
    );
    try std.testing.expectEqualStrings(
        "IR 37%, total 95%, ETA 2m05s, elapsed 1m05s",
        try handleScanIrProgressStatus(&buffer, 6400, 37, 125.9, 65.2),
    );
    try std.testing.expectEqualStrings(
        "RGB 37%, ETA 2m05s, elapsed 1m05s",
        try handleScanSingleProgressStatus(&buffer, .rgb, 37, 125.9, 65.2),
    );
    try std.testing.expectEqualStrings(
        "IR 37%, ETA 2m05s, elapsed 1m05s",
        try handleScanSingleProgressStatus(&buffer, .ir, 37, 125.9, 65.2),
    );
    try std.testing.expectEqualStrings(
        "Saved: scan_0001_rgbir_3200dpi.tiff",
        try handleScanSavedStatus(&buffer, "scans/scan_0001_rgbir_3200dpi.tiff"),
    );
    try std.testing.expectEqualStrings(
        "Error: scan failed",
        try handleScanErrorStatus(&buffer, "scan failed"),
    );
}
