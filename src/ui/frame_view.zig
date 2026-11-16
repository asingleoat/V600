//! The Frame view: one frame of the loaded scan at a time, its look edited
//! with a live preview. The preview is the frame cut from the strip
//! preview and rendered as its export is, with the frame's own settings
//! (see frame_preview_worker.zig); edits are the frame's own overrides of
//! processing.toml, saved beside the scan.

const std = @import("std");
const cerealgrain = @import("cerealgrain");
const c = @import("sdl_nuklear.zig").c;
const chrome = @import("chrome.zig");

const layoutRow = chrome.layoutRow;
const tooltip = chrome.tooltip;
const nkBool = chrome.nkBool;
const State = cerealgrain.native_ui.State;
const Key = cerealgrain.processing.frame_adjust.Key;
const preview_worker = cerealgrain.native_ui_frame_preview_worker;
const film_stocks = cerealgrain.processing.film_stocks;
const looks = cerealgrain.processing.looks;

/// The Frame view's preview: its worker, and the texture of the last
/// render shown.
pub const FramePreview = struct {
    worker: preview_worker.Worker,
    texture: ?*c.SDL_Texture = null,
    width: usize = 0,
    height: usize = 0,
    shown: ?preview_worker.Key = null,
    /// The render running, so a changed look waits for it, then starts.
    pending: ?preview_worker.Key = null,
    estimated_dmin: bool = false,
    failed: bool = false,
    /// The screen's gamut: Display P3 when the renderer draws in extended
    /// linear sRGB (macOS), else sRGB.
    screen: cerealgrain.processing.rgb_space.Space = .srgb,
    wide_texture: bool = false,

    pub fn init(allocator: std.mem.Allocator, screen: cerealgrain.processing.rgb_space.Space) FramePreview {
        return .{ .worker = preview_worker.Worker.init(allocator), .screen = screen };
    }

    pub fn deinit(self: *FramePreview) void {
        self.worker.deinit();
        if (self.texture) |texture| c.SDL_DestroyTexture(texture);
        self.texture = null;
    }

    /// Takes a finished render, and starts the next when the frame or its
    /// look changed. Runs every UI frame while the view is shown.
    pub fn update(self: *FramePreview, renderer: *c.SDL_Renderer, model: *const State, proof: ?preview_worker.Proof) !void {
        if (self.worker.take() catch blk: {
            self.failed = true;
            self.pending = null;
            break :blk null;
        }) |result| {
            defer self.worker.allocator.free(result.pixels);
            self.pending = null;
            self.failed = false;
            try self.install(renderer, result);
        }
        var key = wantedKey(model, proof) orelse return;
        key.screen = self.screen;
        if (self.shown) |current| if (current.eql(key)) return;
        if (self.pending != null) return;
        const preview = model.processing_preview.?;
        const source = if (self.worker.hasCrop(key.crop))
            null
        else
            try preview_worker.CropSource.copy(self.worker.allocator, preview.preview_raw, preview.preview_width, preview.preview_height, key.crop.rect);
        if (try self.worker.start(key, source)) self.pending = key;
    }

    fn install(self: *FramePreview, renderer: *c.SDL_Renderer, result: preview_worker.Result) !void {
        const wide = result.key.screen != .srgb;
        if (self.texture == null or self.width != result.width or self.height != result.height or self.wide_texture != wide) {
            if (self.texture) |texture| c.SDL_DestroyTexture(texture);
            self.texture = null;
            self.texture = (if (wide)
                chrome.createExtendedTexture(renderer, result.width, result.height)
            else
                c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGB24, c.SDL_TEXTUREACCESS_STATIC, @intCast(result.width), @intCast(result.height))) orelse
                return error.SdlFrameTextureFailed;
            self.width = result.width;
            self.height = result.height;
            self.wide_texture = wide;
        }
        const pitch: usize = result.width * @as(usize, if (wide) 8 else 3);
        if (!c.SDL_UpdateTexture(self.texture.?, null, result.pixels.ptr, @intCast(pitch))) return error.SdlFrameTextureFailed;
        self.shown = result.key;
        self.estimated_dmin = result.estimated_dmin;
    }

    /// Draws the frame, as large as fits the canvas.
    pub fn render(self: *const FramePreview, renderer: *c.SDL_Renderer, model: *const State) void {
        if (model.process_selection_count == 0) return;
        const texture = self.texture orelse return;
        var out_w: c_int = 0;
        var out_h: c_int = 0;
        _ = c.SDL_GetCurrentRenderOutputSize(renderer, &out_w, &out_h);
        const area = chrome.canvasArea(out_w, out_h);
        const margin: f32 = chrome.runtime_ui_config.metrics().margin;
        const box_w = @as(f32, @floatFromInt(area.w)) - 2.0 * margin;
        const box_h = @as(f32, @floatFromInt(area.h)) - 2.0 * margin;
        if (box_w <= 0 or box_h <= 0) return;
        const scale = @min(box_w / @as(f32, @floatFromInt(self.width)), box_h / @as(f32, @floatFromInt(self.height)));
        const w = @as(f32, @floatFromInt(self.width)) * scale;
        const h = @as(f32, @floatFromInt(self.height)) * scale;
        const rect = c.SDL_FRect{
            .x = @as(f32, @floatCast(area.x)) + margin + (box_w - w) / 2.0,
            .y = @as(f32, @floatCast(area.y)) + margin + (box_h - h) / 2.0,
            .w = w,
            .h = h,
        };
        _ = c.SDL_RenderTexture(renderer, texture, null, &rect);
    }
};

/// The render the Frame view should show now, or null with no frame.
pub fn wantedKey(model: *const State, proof: ?preview_worker.Proof) ?preview_worker.Key {
    const preview = model.processing_preview orelse return null;
    if (model.process_selection_count == 0 or preview.preview_raw.len == 0) return null;
    const index = @min(model.frame_view_index, model.process_selection_count - 1);
    const selection = model.process_selections[index];
    if (!(selection.w >= 2.0 and selection.h >= 2.0)) return null;
    const coeffs = stockCoefficients(model);
    return .{
        .crop = .{
            .generation = model.processingGeneration(),
            .raw_ptr = @intFromPtr(preview.preview_raw.ptr),
            .rect = .{
                .cx = selection.x + selection.w / 2.0,
                .cy = selection.y + selection.h / 2.0,
                .w = selection.w,
                .h = selection.h,
                .angle = selection.angle * 180.0 / std.math.pi,
                .rotation = selection.rotation,
            },
            .coeffs = coeffs,
            .dmin = model.processing.dmin,
        },
        .render_options = model.frameRenderOptions(index),
        .proof = proof,
    };
}

/// The active stock's colour coefficients; Kodak Gold without one, as
/// exports invert.
fn stockCoefficients(model: *const State) film_stocks.Coefficients {
    if (model.processing_config.activeStock()) |name| {
        if (model.processing_config.availableStock(name)) |stock| {
            if (stock.has_coeffs) return stock.coeffs;
        }
    }
    return film_stocks.kodak_gold_coeffs;
}

pub const Action = enum { none, export_frame };

const Slider = struct {
    label: [*:0]const u8,
    key: Key,
    min: f32,
    max: f32,
    step: f32,
    help: []const u8,
};

const render_sliders = [_]Slider{
    .{ .label = "Contrast", .key = .render_contrast, .min = 1.0, .max = 3.0, .step = 0.05, .help = "Contrast of the display curve through 18% grey. 1 is gentle; higher values deepen shadows and brighten highlights" },
    .{ .label = "Crosstalk", .key = .dye_crosstalk, .min = 0.0, .max = 0.5, .step = 0.02, .help = "Dye crosstalk to undo: the scan sees each dye partly through the others, which mutes colour. Higher values restore more colour" },
    .{ .label = "Black %", .key = .render_percentile_lo, .min = 0.0, .max = 5.0, .step = 0.1, .help = "Percentile of each channel used as its black point for automatic white balance. Higher values ignore more dark outliers" },
    .{ .label = "White %", .key = .render_percentile_hi, .min = 95.0, .max = 100.0, .step = 0.1, .help = "Percentile of each channel used as its white point for automatic white balance. Lower values ignore more bright outliers such as specular highlights" },
    .{ .label = "Highlights", .key = .render_highlight_target, .min = 0.0, .max = 0.98, .step = 0.01, .help = "Where automatic exposure puts the frame's highlights (its 99th percentile of lightness, 0 to 1): 0.84 keeps skies airy but off white. It moves exposure at most two stops from the usual automatic exposure. 0 instead puts the frame's average at 18% grey" },
    .{ .label = "Exposure", .key = .exposure_compensation, .min = -3.0, .max = 3.0, .step = 0.1, .help = "Exposure in stops on top of automatic exposure (which places the highlights, or the average, as above). Positive values brighten" },
};

const balance_sliders = [_]Slider{
    .{ .label = "Temp", .key = .color_temp, .min = -1.0, .max = 1.0, .step = 0.05, .help = "Color temperature, from blue to yellow. 0 is neutral. Same as the horizontal axis of the pad above" },
    .{ .label = "Tint", .key = .color_tint, .min = -1.0, .max = 1.0, .step = 0.05, .help = "Tint, from green to magenta. 0 is neutral. Same as the vertical axis of the pad above" },
};

const contrast_sliders = [_]Slider{
    .{ .label = "Local", .key = .color_contrast_gain, .min = 0.0, .max = 0.5, .step = 0.05, .help = "How much chroma differences between shades near each colour's centre grow. 0 keeps them as they are" },
    .{ .label = "Boost", .key = .color_contrast_boost, .min = 0.0, .max = 0.8, .step = 0.05, .help = "How much the frame's main colours gain chroma, each shade along its own hue, so greys and other colours keep theirs. 0 keeps each colour's saturation" },
    .{ .label = "Hue pull", .key = .color_cohesion_hue, .min = 0.0, .max = 1.0, .step = 0.05, .help = "How far each shade's hue moves toward its colour's. Higher makes each colour more even in hue" },
    .{ .label = "Chroma pull", .key = .color_cohesion_chroma, .min = 0.0, .max = 1.0, .step = 0.05, .help = "How far each shade's chroma moves toward its colour's, outside the core" },
};

/// The Frame view's panel: the frame picker, the frame's look, and export.
pub fn drawPanel(
    ctx: *c.struct_nk_context,
    model: *State,
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    preview: *const FramePreview,
    export_active: bool,
) Action {
    const count = model.process_selection_count;
    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Frames", c.NK_TEXT_LEFT);
    if (model.processing_preview == null) {
        chrome.drawWrappedText(ctx, "No scan loaded. Choose one in the Strip tab.");
        return .none;
    }
    if (count == 0) {
        chrome.drawWrappedText(ctx, "This scan has no frames yet. Detect or draw them in the Strip tab.");
        return .none;
    }
    if (model.frame_view_index >= count) model.frame_view_index = count - 1;
    const index = model.frame_view_index;

    layoutRow(ctx, 28.0, 3);
    if (c.nk_button_label(ctx, "Prev") != 0 and index > 0) model.frame_view_index -= 1;
    var position_buffer: [32]u8 = undefined;
    chrome.drawText(ctx, std.fmt.bufPrint(&position_buffer, "Frame {d} of {d}", .{ index + 1, count }) catch "");
    if (c.nk_button_label(ctx, "Next") != 0 and index + 1 < count) model.frame_view_index += 1;
    for (0..count) |frame| {
        var label_buffer: [48]u8 = undefined;
        const own = !model.process_frame_adjustments[frame].isEmpty();
        const label = std.fmt.bufPrintZ(&label_buffer, "Frame {d}{s}", .{ frame + 1, if (own) "  (own look)" else "" }) catch continue;
        layoutRow(ctx, 22.0, 1);
        var selected = nkBool(frame == model.frame_view_index);
        if (c.nk_selectable_label(ctx, label.ptr, c.NK_TEXT_LEFT, &selected) != 0) model.frame_view_index = frame;
    }
    if (preview.estimated_dmin) {
        chrome.drawWrappedText(ctx, "No Dmin is set, so this preview estimates the film base from the frame itself; exports measure it from the whole scan. Set a rebate in the Strip tab for both to agree.");
    }

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Look", c.NK_TEXT_LEFT);
    layoutRow(ctx, 28.0, @intCast(looks.all.len + 1));
    c.nk_label(ctx, "Preset:", c.NK_TEXT_LEFT);
    for (looks.all) |look| {
        tooltip(ctx, look.description);
        if (c.nk_button_label(ctx, look.name.ptr) != 0) {
            model.process_frame_adjustments[index] = look.adjustments();
            model.process_adjustments_dirty = true;
        }
    }
    drawSlider(ctx, model, index, .{ .label = "Strength", .key = .look_mix, .min = 0.0, .max = 1.0, .step = 0.05, .help = "How strongly this frame's own look applies, from the default look (0) to all of it (1). Each setting goes part way; highlight placement and colour contrast fade in what they do. Keeps its value when you pick another preset" });
    var own_buffer: [256]u8 = undefined;
    chrome.drawWrappedText(ctx, ownSettingsText(&own_buffer, model, index));
    for (render_sliders) |slider| drawSlider(ctx, model, index, slider);

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Color Balance", c.NK_TEXT_LEFT);
    drawSlider(ctx, model, index, .{ .label = "Auto WB", .key = .auto_white_balance, .min = 0.0, .max = 1.0, .step = 0.05, .help = "Automatic white balance for the frame: gives every channel its own black and white point so neutral shadows and highlights come out neutral. 1 = full, 0 = off (for scenes whose darkest and brightest parts are not neutral, like sunsets)" });
    drawSlider(ctx, model, index, .{ .label = "Neutral WB", .key = .neutral_white_balance, .min = 0.0, .max = 1.0, .step = 0.05, .help = "Then finds the frame's nearly neutral surfaces (greys, whites, glass) and takes their remaining colour cast out, keeping brightness. 1 = full, 0 = off. Frames with little that is nearly neutral are left alone" });
    var temp: f32 = @floatCast(model.frameSetting(index, .color_temp));
    var tint: f32 = @floatCast(model.frameSetting(index, .color_tint));
    if (colorPad(ctx, &temp, &tint)) {
        model.setFrameSetting(index, .color_temp, kept(temp));
        model.setFrameSetting(index, .color_tint, kept(tint));
    }
    for (balance_sliders) |slider| drawSlider(ctx, model, index, slider);

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Color Contrast", c.NK_TEXT_LEFT);
    layoutRow(ctx, 24.0, 1);
    tooltip(ctx, "Finds the frame's colourful objects (skin, sky, foliage) and spreads the shades of each apart in chroma around a richer centre, keeping hue and lightness. Greys are left alone");
    var contrast_on = nkBool(model.frameSetting(index, .color_contrast) != 0.0);
    if (c.nk_checkbox_label(ctx, "Color contrast", &contrast_on) != 0) {
        model.setFrameSetting(index, .color_contrast, if (contrast_on != 0) 1.0 else 0.0);
    }
    // Shown whether on or off, so the checkbox compares the two in place.
    {
        var families: c_int = @intFromFloat(@round(model.frameSetting(index, .color_contrast_families)));
        const families_before = families;
        layoutRow(ctx, 26.0, 1);
        tooltip(ctx, "The most colours to find in the frame, the most common kept. Fewer leaves the rarer colours to the pull of the main ones, or alone when far from them");
        c.nk_property_int(ctx, "Colors", 1, &families, 12, 1, 1);
        if (families != families_before) model.setFrameSetting(index, .color_contrast_families, @floatFromInt(families));
        drawSlider(ctx, model, index, contrast_sliders[0]);
        drawSlider(ctx, model, index, contrast_sliders[1]);
        var target = shown(model.frameSetting(index, .color_contrast_target) * 1000.0);
        const target_before = target;
        layoutRow(ctx, 26.0, 1);
        tooltip(ctx, "The colourfulness to aim for, in thousandths of Oklab chroma (the frame's 90th percentile): the boost rises only as far as needed to reach it, and never past Boost. A muted frame gets more, an already colourful one none. 0 always applies Boost");
        c.nk_property_float(ctx, "Target", 0.0, &target, 150.0, 1.0, 0.25);
        if (@abs(target - target_before) > 0.000001) model.setFrameSetting(index, .color_contrast_target, @round(@as(f64, target)) / 1000.0);
        var core = shown(model.frameSetting(index, .color_contrast_radius) * 1000.0);
        const core_before = core;
        layoutRow(ctx, 26.0, 1);
        tooltip(ctx, "Size of the region about each colour's centre whose chroma differences grow, in thousandths of Oklab. It shrinks where colours crowd each other or the greys");
        c.nk_property_float(ctx, "Core", 0.0, &core, 80.0, 1.0, 0.25);
        if (@abs(core - core_before) > 0.000001) model.setFrameSetting(index, .color_contrast_radius, @round(@as(f64, core)) / 1000.0);
        drawSlider(ctx, model, index, contrast_sliders[2]);
        drawSlider(ctx, model, index, contrast_sliders[3]);
    }

    layoutRow(ctx, 28.0, 3);
    tooltip(ctx, "Give this frame the default look again (processing.toml's settings)");
    if (c.nk_button_label(ctx, "Reset Frame") != 0) {
        model.process_frame_adjustments[index] = .{};
        model.process_adjustments_dirty = true;
    }
    tooltip(ctx, "Give every frame of this scan this frame's own settings");
    if (c.nk_button_label(ctx, "Copy to All") != 0) {
        for (model.process_frame_adjustments[0..count]) |*other| other.* = model.process_frame_adjustments[index];
        model.process_adjustments_dirty = true;
    }
    tooltip(ctx, "Make this frame's own settings, at its strength, the defaults for every frame without its own, here and in other scans. Highlight placement the defaults lack is saved at full strength");
    if (c.nk_button_label(ctx, "Make Default") != 0) {
        makeDefault(model, allocator, io, config_path, index) catch |err| {
            var status_buffer: [96]u8 = undefined;
            model.setStatus(std.fmt.bufPrint(&status_buffer, "Could not save the defaults: {s}", .{@errorName(err)}) catch "Could not save the defaults");
        };
    }

    layoutRow(ctx, 24.0, 1);
    c.nk_label(ctx, "Export", c.NK_TEXT_LEFT);
    chrome.drawWrappedText(ctx, "Writes this frame alone, with its look, as the Strip tab's export would, replacing its earlier file.");
    layoutRow(ctx, 30.0, 1);
    if (export_active) {
        c.nk_label(ctx, "Exporting...", c.NK_TEXT_LEFT);
    } else if (c.nk_button_label(ctx, "Export This Frame") != 0) {
        return .export_frame;
    }
    return .none;
}

fn drawSlider(ctx: *c.struct_nk_context, model: *State, index: usize, slider: Slider) void {
    var value = shown(model.frameSetting(index, slider.key));
    const before = value;
    layoutRow(ctx, 26.0, 1);
    tooltip(ctx, slider.help);
    c.nk_property_float(ctx, slider.label, slider.min, &value, slider.max, slider.step, slider.step * 0.25);
    if (@abs(value - before) > 0.000001) model.setFrameSetting(index, slider.key, kept(value));
}

/// A setting as a property shows it: Nuklear cuts the digits off rather
/// than rounding, so 1.8 (1.7999999 in f32) would read 1.79.
fn shown(value: f64) f32 {
    return @floatCast(value + 0.00001);
}

/// A property's value as the setting keeps it: to four decimals.
fn kept(value: f32) f64 {
    return @round(@as(f64, value) * 10000.0) / 10000.0;
}

/// Which settings the frame has of its own, as a sentence.
fn ownSettingsText(buffer: []u8, model: *const State, index: usize) []const u8 {
    const adjustments = &model.process_frame_adjustments[index];
    if (adjustments.isEmpty()) return "This frame uses the default look. Changing a setting gives it its own.";
    for (looks.all) |look| {
        if (std.meta.eql(adjustments.values, look.adjustments().values)) {
            return std.fmt.bufPrint(buffer, "This frame uses the {s} look. Reset Frame returns it to the default.", .{look.name}) catch "";
        }
    }
    var stream = std.Io.Writer.fixed(buffer);
    stream.writeAll("This frame's own:") catch return "";
    var first = true;
    for (adjustments.values, 0..) |value, key_index| {
        if (value == null) continue;
        stream.print("{s} {s}", .{ if (first) "" else ",", settingName(@enumFromInt(key_index)) }) catch break;
        first = false;
    }
    stream.writeAll(". The rest follow the defaults.") catch {};
    return stream.buffered();
}

fn settingName(key: Key) []const u8 {
    return switch (key) {
        .render_contrast => "contrast",
        .dye_crosstalk => "crosstalk",
        .render_percentile_lo => "black point",
        .render_percentile_hi => "white point",
        .exposure_compensation => "exposure",
        .render_highlight_target => "highlights",
        .auto_white_balance => "auto white balance",
        .neutral_white_balance => "neutral white balance",
        .film_gamma => "film gamma",
        .film_toe => "film toe",
        .color_temp => "temperature",
        .color_tint => "tint",
        .color_contrast => "colour contrast",
        .color_contrast_families => "colours",
        .color_contrast_target => "colourfulness target",
        .color_contrast_gain => "local contrast",
        .color_contrast_boost => "boost",
        .color_contrast_radius => "core",
        .color_cohesion_hue => "hue pull",
        .color_cohesion_chroma => "chroma pull",
        .look_mix => "strength",
    };
}

/// Saves the frame's own settings as processing.toml's, and drops them
/// from the frame, which now looks the same by default.
fn makeDefault(model: *State, allocator: std.mem.Allocator, io: std.Io, config_path: []const u8, index: usize) !void {
    const adjustments = bakedStrength(model, index);
    if (adjustments.isEmpty()) return;
    var buffer: [cerealgrain.processing.frame_adjust.max_overrides]cerealgrain.processing.config.Override = undefined;
    const updates = adjustments.overrides(&.{}, &buffer);
    try model.saveProcessingSettings(allocator, io, config_path, updates);
    model.process_frame_adjustments[index] = .{};
    model.process_adjustments_dirty = true;
}

/// The frame's own settings at its strength, as plain settings (for Make
/// Default): each part way from the default's, as the render mixes them.
/// Highlight placement the defaults lack has no part-way setting, and keeps
/// the frame's.
fn bakedStrength(model: *const State, index: usize) cerealgrain.processing.frame_adjust.Adjustments {
    var own = model.process_frame_adjustments[index];
    const mix = own.mix();
    own.set(.look_mix, null);
    if (mix >= 1.0) return own;
    const default_contrast_on = model.configSetting(.color_contrast) != 0.0;
    for (std.enums.values(Key)) |key| {
        const value = own.get(key) orelse continue;
        const default = model.configSetting(key);
        const mixed = switch (key) {
            .color_contrast, .color_contrast_families, .look_mix => value,
            .render_highlight_target => if (default > 0.0) default + mix * (value - default) else value,
            .color_contrast_target => if (default > 0.0 and value > 0.0) default + mix * (value - default) else value,
            .color_contrast_gain, .color_contrast_boost, .color_cohesion_hue, .color_cohesion_chroma => if (default_contrast_on) default + mix * (value - default) else mix * value,
            else => default + mix * (value - default),
        };
        own.set(key, mixed);
    }
    return own;
}

/// The colour pad is being dragged (UI thread only).
var pad_dragging = false;

/// A pad for temperature (across) and tint (down); true when dragged.
fn colorPad(ctx: *c.struct_nk_context, temp: *f32, tint: *f32) bool {
    layoutRow(ctx, 88.0, 1);
    tooltip(ctx, "Drag the point to adjust color balance. Horizontal: temperature, blue to yellow. Vertical: tint, green to magenta. The center is neutral");
    var bounds: c.struct_nk_rect = undefined;
    if (c.nk_widget(&bounds, ctx) == c.NK_WIDGET_INVALID) return false;

    const canvas = c.nk_window_get_canvas(ctx);
    c.nk_fill_rect_multi_color(canvas, bounds, c.nk_rgb(60, 95, 170), c.nk_rgb(70, 150, 80), c.nk_rgb(195, 170, 55), c.nk_rgb(170, 75, 165));
    c.nk_stroke_rect(canvas, bounds, 2.0, 1.0, c.nk_rgb(85, 88, 96));
    c.nk_stroke_rect(canvas, c.nk_rect(bounds.x + bounds.w * 0.5, bounds.y, 1.0, bounds.h), 0.0, 1.0, c.nk_rgb(210, 210, 210));
    c.nk_stroke_rect(canvas, c.nk_rect(bounds.x, bounds.y + bounds.h * 0.5, bounds.w, 1.0), 0.0, 1.0, c.nk_rgb(210, 210, 210));

    const dot_x = bounds.x + ((temp.* + 1.0) * 0.5) * bounds.w;
    const dot_y = bounds.y + ((tint.* + 1.0) * 0.5) * bounds.h;
    const dot_radius = chrome.runtime_ui_config.metrics().color_dot_radius;
    const dot = c.nk_rect(dot_x - dot_radius, dot_y - dot_radius, dot_radius * 2.0, dot_radius * 2.0);
    c.nk_fill_circle(canvas, dot, c.nk_rgb(245, 245, 245));
    c.nk_stroke_circle(canvas, dot, 1.0, c.nk_rgb(20, 20, 24));

    // A drag starts only with a press on the pad, so a click elsewhere that
    // moves the layout (and the pad under the pointer) does not grab it.
    const input = &ctx.*.input;
    if (c.nk_input_is_mouse_down(input, c.NK_BUTTON_LEFT) == 0) {
        pad_dragging = false;
        return false;
    }
    if (c.nk_input_is_mouse_click_down_in_rect(input, c.NK_BUTTON_LEFT, bounds, 1) != 0) pad_dragging = true;
    if (!pad_dragging) return false;
    const before_temp = temp.*;
    const before_tint = tint.*;
    const mx = @min(bounds.x + bounds.w, @max(bounds.x, input.mouse.pos.x));
    const my = @min(bounds.y + bounds.h, @max(bounds.y, input.mouse.pos.y));
    temp.* = ((mx - bounds.x) / bounds.w) * 2.0 - 1.0;
    tint.* = ((my - bounds.y) / bounds.h) * 2.0 - 1.0;
    return @abs(temp.* - before_temp) > 0.000001 or @abs(tint.* - before_tint) > 0.000001;
}
