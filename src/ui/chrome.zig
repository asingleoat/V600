//! Window chrome and Nuklear plumbing for the native UI: control panel and
//! footer rects, layout rows, theme styling, and SDL-to-Nuklear input
//! translation.

const std = @import("std");
const v600 = @import("v600");
const c = @import("sdl_nuklear.zig").c;
const ui_theme = v600.native_ui_theme;

pub var runtime_ui_config = ui_theme.Config{};
pub var active_control_panel_rect: c.struct_nk_rect = c.struct_nk_rect{ .x = 16.0, .y = 16.0, .w = 520.0, .h = 360.0 };
pub var active_footer_rect: c.struct_nk_rect = c.struct_nk_rect{ .x = 0.0, .y = 704.0, .w = 1024.0, .h = 48.0 };
pub fn controlPanelFlags() c_uint {
    return c.NK_WINDOW_BORDER | c.NK_WINDOW_TITLE;
}

pub fn footerBarFlags() c_uint {
    return c.NK_WINDOW_BORDER | c.NK_WINDOW_NO_SCROLLBAR | c.NK_WINDOW_NO_INPUT;
}

pub fn controlPanelRect() c.struct_nk_rect {
    return active_control_panel_rect;
}

pub fn footerBarRect() c.struct_nk_rect {
    return active_footer_rect;
}

pub fn updateUiChromeRects(window: *c.SDL_Window, model: *const v600.native_ui.State) void {
    var window_w: c_int = 0;
    var window_h: c_int = 0;
    if (!c.SDL_GetWindowSize(window, &window_w, &window_h)) {
        const metrics = runtime_ui_config.metrics();
        window_w = metrics.initialWindowWidth();
        window_h = metrics.initialWindowHeight();
    }
    active_footer_rect = footerBarRectForSize(
        @floatFromInt(@max(window_w, 1)),
        @floatFromInt(@max(window_h, 1)),
    );
    active_control_panel_rect = controlPanelRectForSize(
        @floatFromInt(@max(window_w, 1)),
        @floatFromInt(@max(window_h, 1)),
        model,
    );
}

/// Shows a word-wrapped tooltip when the next widget is hovered. Call it after
/// the widget's layout row and before the widget.
pub fn tooltip(ctx: *c.struct_nk_context, text: []const u8) void {
    if (c.nk_widget_is_hovered(ctx) == 0) return;
    var buffer: [512:0]u8 = undefined;
    const label = std.fmt.bufPrintZ(&buffer, "{s}", .{text[0..@min(text.len, buffer.len)]}) catch return;
    const font = ctx.style.font;
    const width = 360.0 * runtime_ui_config.metrics().scale;
    const line_width = width - 24.0;
    const text_width = font.*.width.?(font.*.userdata, font.*.height, label.ptr, @intCast(label.len));
    const lines = if (text_width <= line_width) 1.0 else @ceil(text_width / line_width) + 1.0;
    if (c.nk_tooltip_begin(ctx, width) == 0) return;
    c.nk_layout_row_dynamic(ctx, lines * (font.*.height + 3.0), 1);
    c.nk_label_wrap(ctx, label.ptr);
    c.nk_tooltip_end(ctx);
}

pub const CanvasArea = struct {
    x: f64,
    y: f64,
    w: c_int,
    h: c_int,
};

/// Where images are fitted: right of the control panel and above the
/// footer, or the whole window above the footer when that leaves too little
/// room (a narrow window).
/// The render output in drawing coordinates: window points, since the
/// render scale is the window's pixel density.
pub fn renderLogicalSize(renderer: *c.SDL_Renderer) ?struct { w: c_int, h: c_int } {
    var out_w: c_int = 0;
    var out_h: c_int = 0;
    if (!c.SDL_GetCurrentRenderOutputSize(renderer, &out_w, &out_h)) return null;
    var scale_x: f32 = 1.0;
    var scale_y: f32 = 1.0;
    if (!c.SDL_GetRenderScale(renderer, &scale_x, &scale_y) or scale_x <= 0.0 or scale_y <= 0.0) return null;
    return .{
        .w = @intFromFloat(@round(@as(f32, @floatFromInt(out_w)) / scale_x)),
        .h = @intFromFloat(@round(@as(f32, @floatFromInt(out_h)) / scale_y)),
    };
}

pub fn canvasArea(out_w: c_int, out_h: c_int) CanvasArea {
    const margin: c_int = @intFromFloat(runtime_ui_config.metrics().margin);
    const panel = controlPanelRect();
    const footer = footerBarRect();
    const bottom: c_int = @max(1, @min(out_h, @as(c_int, @intFromFloat(footer.y))));
    const left: c_int = @intFromFloat(panel.x + panel.w);
    const beside = out_w - left - 2 * margin;
    if (beside < 240 or beside * 10 < out_w * 3) {
        return .{ .x = 0.0, .y = 0.0, .w = @max(1, out_w), .h = bottom };
    }
    return .{
        .x = @floatFromInt(left + margin),
        .y = @floatFromInt(margin),
        .w = beside,
        .h = @max(1, bottom - 2 * margin),
    };
}

pub fn footerBarHeight() f32 {
    return runtime_ui_config.metrics().row(46.0);
}

pub fn footerBarRectForSize(window_w: f32, window_h: f32) c.struct_nk_rect {
    const height = @min(footerBarHeight(), @max(1.0, window_h));
    return c.nk_rect(
        0.0,
        @max(0.0, window_h - height),
        @max(1.0, window_w),
        height,
    );
}

pub fn controlPanelRectForSize(window_w: f32, window_h: f32, model: *const v600.native_ui.State) c.struct_nk_rect {
    const metrics = runtime_ui_config.metrics();
    const available_w = @max(80.0, window_w - metrics.margin * 2.0);
    const width = @min(metrics.panelWidth(window_w), available_w);
    const available_h = @max(1.0, window_h - footerBarHeight() - metrics.margin * 3.0);
    return c.nk_rect(
        metrics.margin,
        metrics.margin,
        width,
        @min(metrics.row(controlPanelBaseHeight(model)), available_h),
    );
}

pub fn controlPanelBaseHeight(model: *const v600.native_ui.State) f32 {
    return switch (model.active_view) {
        // Tall enough for the roll section and every scan control; the
        // panel is capped at the space above the footer.
        .scan => 760.0,
        .gallery => 330.0,
        .process => 940.0 +
            @as(f32, @floatFromInt(@min(model.processing_images.paths.len, 16))) * 24.0 +
            @as(f32, @floatFromInt(@min(model.process_selection_count, 12))) * 50.0,
    };
}

pub fn layoutRow(ctx: *c.struct_nk_context, base_height: f32, columns: c_int) void {
    c.nk_layout_row_dynamic(ctx, runtime_ui_config.metrics().row(base_height), columns);
}

pub fn layoutRowStatic(ctx: *c.struct_nk_context, base_height: f32, base_width: c_int, columns: c_int) void {
    const metrics = runtime_ui_config.metrics();
    c.nk_layout_row_static(
        ctx,
        metrics.row(base_height),
        @intFromFloat(@round(@as(f32, @floatFromInt(base_width)) * metrics.scale)),
        columns,
    );
}

pub fn applyNuklearStyle(ctx: *c.struct_nk_context, config: ui_theme.Config) void {
    const palette = config.palette();
    var colors: [c.NK_COLOR_COUNT]c.struct_nk_color = undefined;
    for (&colors) |*color| color.* = nkColor(palette.window);
    setStyleColor(&colors, c.NK_COLOR_TEXT, palette.text);
    setStyleColor(&colors, c.NK_COLOR_WINDOW, palette.window);
    setStyleColor(&colors, c.NK_COLOR_HEADER, palette.header);
    setStyleColor(&colors, c.NK_COLOR_BORDER, palette.border);
    setStyleColor(&colors, c.NK_COLOR_BUTTON, palette.button);
    setStyleColor(&colors, c.NK_COLOR_BUTTON_HOVER, palette.button_hover);
    setStyleColor(&colors, c.NK_COLOR_BUTTON_ACTIVE, palette.button_active);
    setStyleColor(&colors, c.NK_COLOR_TOGGLE, palette.toggle);
    setStyleColor(&colors, c.NK_COLOR_TOGGLE_HOVER, palette.toggle_hover);
    setStyleColor(&colors, c.NK_COLOR_TOGGLE_CURSOR, palette.toggle_cursor);
    setStyleColor(&colors, c.NK_COLOR_SELECT, palette.select);
    setStyleColor(&colors, c.NK_COLOR_SELECT_ACTIVE, palette.select_active);
    setStyleColor(&colors, c.NK_COLOR_SLIDER, palette.slider);
    setStyleColor(&colors, c.NK_COLOR_SLIDER_CURSOR, palette.slider_cursor);
    setStyleColor(&colors, c.NK_COLOR_SLIDER_CURSOR_HOVER, palette.slider_cursor_hover);
    setStyleColor(&colors, c.NK_COLOR_SLIDER_CURSOR_ACTIVE, palette.slider_cursor_hover);
    setStyleColor(&colors, c.NK_COLOR_PROPERTY, palette.property);
    setStyleColor(&colors, c.NK_COLOR_EDIT, palette.edit);
    setStyleColor(&colors, c.NK_COLOR_EDIT_CURSOR, palette.edit_cursor);
    setStyleColor(&colors, c.NK_COLOR_COMBO, palette.property);
    setStyleColor(&colors, c.NK_COLOR_SCROLLBAR, palette.scrollbar);
    setStyleColor(&colors, c.NK_COLOR_SCROLLBAR_CURSOR, palette.scrollbar_cursor);
    setStyleColor(&colors, c.NK_COLOR_SCROLLBAR_CURSOR_HOVER, palette.button_hover);
    setStyleColor(&colors, c.NK_COLOR_SCROLLBAR_CURSOR_ACTIVE, palette.button_active);
    setStyleColor(&colors, c.NK_COLOR_TAB_HEADER, palette.tab_header);
    setStyleColor(&colors, c.NK_COLOR_KNOB, palette.slider);
    setStyleColor(&colors, c.NK_COLOR_KNOB_CURSOR, palette.slider_cursor);
    setStyleColor(&colors, c.NK_COLOR_KNOB_CURSOR_HOVER, palette.slider_cursor_hover);
    setStyleColor(&colors, c.NK_COLOR_KNOB_CURSOR_ACTIVE, palette.slider_cursor_hover);
    c.nk_style_from_table(ctx, &colors);

    const metrics = config.metrics();
    ctx.*.style.window.padding = c.nk_vec2(metrics.window_padding_x, metrics.window_padding_y);
    ctx.*.style.window.spacing = c.nk_vec2(metrics.widget_spacing_x, metrics.widget_spacing_y);
    ctx.*.style.window.scrollbar_size = c.nk_vec2(metrics.scrollbar_width, metrics.scrollbar_width);
    ctx.*.style.window.rounding = metrics.rounding;
    ctx.*.style.window.border = metrics.border;
    ctx.*.style.button.padding = c.nk_vec2(metrics.row(6.0), metrics.row(3.0));
    ctx.*.style.button.rounding = metrics.rounding;
    ctx.*.style.button.border = metrics.border;
    ctx.*.style.edit.padding = c.nk_vec2(metrics.row(5.0), metrics.row(3.0));
    ctx.*.style.edit.rounding = metrics.rounding;
    ctx.*.style.edit.border = metrics.border;
    ctx.*.style.property.padding = c.nk_vec2(metrics.row(5.0), metrics.row(3.0));
    ctx.*.style.property.rounding = metrics.rounding;
    ctx.*.style.property.border = metrics.border;
    ctx.*.style.slider.padding = c.nk_vec2(metrics.row(5.0), metrics.row(3.0));
    ctx.*.style.slider.rounding = metrics.rounding;
    ctx.*.style.slider.cursor_size = c.nk_vec2(metrics.row(16.0), metrics.row(16.0));
    ctx.*.style.scrollv.padding = c.nk_vec2(0.0, 0.0);
    ctx.*.style.scrollv.rounding = metrics.rounding;
    ctx.*.style.scrollv.border = metrics.border;
}

pub fn setStyleColor(colors: *[c.NK_COLOR_COUNT]c.struct_nk_color, index: c_int, color: ui_theme.Rgba) void {
    colors[@as(usize, @intCast(index))] = nkColor(color);
}

pub fn nkColor(color: ui_theme.Rgba) c.struct_nk_color {
    return c.nk_rgba(color.r, color.g, color.b, color.a);
}

pub fn setRendererColor(renderer: *c.SDL_Renderer, color: ui_theme.Rgba) void {
    _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
}

pub fn feedNuklearInput(ctx: *c.struct_nk_context, event: c.SDL_Event) void {
    switch (event.type) {
        c.SDL_EVENT_MOUSE_MOTION => {
            c.nk_input_motion(ctx, mouseCoord(event.motion.x), mouseCoord(event.motion.y));
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
            if (nkButtonFromSdl(event.button.button)) |button| {
                c.nk_input_button(
                    ctx,
                    button,
                    mouseCoord(event.button.x),
                    mouseCoord(event.button.y),
                    nkBool(event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN),
                );
            }
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            if (!controlPanelShouldReceiveWheel(event)) return;
            // Use SDL's values as they come: with macOS natural scrolling
            // they are already flipped, so the panel scrolls like other apps.
            c.nk_input_scroll(ctx, c.nk_vec2(event.wheel.x, event.wheel.y));
        },
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
            const down = event.type == c.SDL_EVENT_KEY_DOWN;
            // Cmd (macOS) or Ctrl chords; a key's release always clears the
            // chord it could have started, whatever modifiers remain held.
            const chord = (event.key.mod & (c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL)) != 0;
            if (nkChordFromSdl(event.key.key, (event.key.mod & c.SDL_KMOD_SHIFT) != 0)) |key| {
                if (chord or !down) c.nk_input_key(ctx, key, nkBool(down and chord));
                if (chord) return;
            }
            if (nkKeyFromSdl(event.key.key)) |key| {
                c.nk_input_key(ctx, key, nkBool(down));
            }
        },
        c.SDL_EVENT_TEXT_INPUT => {
            const text = event.text.text orelse return;
            feedNuklearText(ctx, std.mem.span(text));
        },
        else => {},
    }
}

/// Typed text, which SDL sends only while text input is started (see
/// `syncTextInput`).
pub fn feedNuklearText(ctx: *c.struct_nk_context, text: []const u8) void {
    const view = std.unicode.Utf8View.init(text) catch return;
    var codepoints = view.iterator();
    while (codepoints.nextCodepoint()) |codepoint| c.nk_input_unicode(ctx, codepoint);
}

/// NK_PROPERTY_EDIT from `enum nk_property_status`, which nuklear.h 4.12
/// declares only in its implementation section.
const nk_property_edit: c_int = 1;

/// Whether a text field or a number field in edit mode has keyboard focus.
/// Nuklear keeps this per window (`ctx.text_edit` is shared scratch space
/// that every field overwrites) and drops focus from fields that stop being
/// drawn.
pub fn textEditing(ctx: *const c.struct_nk_context) bool {
    var window = ctx.begin;
    while (window) |win| : (window = win.*.next) {
        if (win.*.edit.active != 0) return true;
        if (win.*.property.active != 0 and win.*.property.state == nk_property_edit) return true;
    }
    return false;
}

/// SDL3 sends text events only between SDL_StartTextInput and
/// SDL_StopTextInput; run them while a Nuklear field is being edited.
pub fn syncTextInput(window: *c.SDL_Window, editing: bool, active: *bool) void {
    if (editing == active.*) return;
    _ = if (editing) c.SDL_StartTextInput(window) else c.SDL_StopTextInput(window);
    active.* = editing;
}

/// Lets text fields copy, cut, and paste through the system clipboard.
pub fn installClipboard(ctx: *c.struct_nk_context) void {
    ctx.clip.copy = clipboardCopy;
    ctx.clip.paste = clipboardPaste;
}

fn clipboardCopy(_: c.nk_handle, text: [*c]const u8, len: c_int) callconv(.c) void {
    if (text == null or len <= 0) return;
    const allocator = std.heap.c_allocator;
    const copy = allocator.allocSentinel(u8, @intCast(len), 0) catch return;
    defer allocator.free(copy);
    @memcpy(copy, text[0..@intCast(len)]);
    _ = c.SDL_SetClipboardText(copy.ptr);
}

fn clipboardPaste(_: c.nk_handle, edit: [*c]c.struct_nk_text_edit) callconv(.c) void {
    const text: [*c]u8 = @ptrCast(c.SDL_GetClipboardText() orelse return);
    defer c.SDL_free(text);
    const len = std.mem.len(text);
    if (len != 0) _ = c.nk_textedit_paste(edit, text, @intCast(len));
}

/// A radio option that reports only the click selecting it. Nuklear's
/// nk_option_* return the option's state, which is also true on every frame
/// an already selected option is drawn.
pub fn optionClicked(ctx: *c.struct_nk_context, label: []const u8, active: bool) bool {
    return c.nk_option_text(ctx, label.ptr, @intCast(label.len), nkBool(active)) != 0 and !active;
}

pub fn nkButtonFromSdl(button: u8) ?c_uint {
    return switch (button) {
        c.SDL_BUTTON_LEFT => c.NK_BUTTON_LEFT,
        c.SDL_BUTTON_MIDDLE => c.NK_BUTTON_MIDDLE,
        c.SDL_BUTTON_RIGHT => c.NK_BUTTON_RIGHT,
        else => null,
    };
}

/// Text-editing chords on Cmd (macOS) or Ctrl.
pub fn nkChordFromSdl(key: c.SDL_Keycode, shift: bool) ?c_uint {
    return switch (key) {
        c.SDLK_A => c.NK_KEY_TEXT_SELECT_ALL,
        c.SDLK_C => c.NK_KEY_COPY,
        c.SDLK_X => c.NK_KEY_CUT,
        c.SDLK_V => c.NK_KEY_PASTE,
        c.SDLK_Z => if (shift) c.NK_KEY_TEXT_REDO else c.NK_KEY_TEXT_UNDO,
        else => null,
    };
}

pub fn nkKeyFromSdl(key: c.SDL_Keycode) ?c_uint {
    return switch (key) {
        c.SDLK_LSHIFT, c.SDLK_RSHIFT => c.NK_KEY_SHIFT,
        c.SDLK_DELETE => c.NK_KEY_DEL,
        c.SDLK_BACKSPACE => c.NK_KEY_BACKSPACE,
        c.SDLK_LEFT => c.NK_KEY_LEFT,
        c.SDLK_RIGHT => c.NK_KEY_RIGHT,
        c.SDLK_ESCAPE => c.NK_KEY_TEXT_RESET_MODE,
        c.SDLK_RETURN, c.SDLK_KP_ENTER => c.NK_KEY_ENTER,
        c.SDLK_HOME => c.NK_KEY_TEXT_LINE_START,
        c.SDLK_END => c.NK_KEY_TEXT_LINE_END,
        else => null,
    };
}

pub fn mouseCoord(value: f32) c_int {
    return @intFromFloat(@round(value));
}

pub fn pointInRect(rect: c.struct_nk_rect, x: f64, y: f64) bool {
    const left: f64 = @floatCast(rect.x);
    const top: f64 = @floatCast(rect.y);
    const right: f64 = @floatCast(rect.x + rect.w);
    const bottom: f64 = @floatCast(rect.y + rect.h);
    return x >= left and x <= right and y >= top and y <= bottom;
}

pub fn pointInControlPanel(x: f64, y: f64) bool {
    return pointInRect(controlPanelRect(), x, y);
}

pub fn pointInFooterBar(x: f64, y: f64) bool {
    return pointInRect(footerBarRect(), x, y);
}

pub fn pointInUiChrome(x: f64, y: f64) bool {
    return pointInControlPanel(x, y) or pointInFooterBar(x, y);
}

pub fn controlPanelShouldReceiveWheel(event: c.SDL_Event) bool {
    if (event.type != c.SDL_EVENT_MOUSE_WHEEL) return false;
    return pointInControlPanel(
        @as(f64, @floatCast(event.wheel.mouse_x)),
        @as(f64, @floatCast(event.wheel.mouse_y)),
    );
}

pub fn assertControlPanelPolicy() !void {
    if ((controlPanelFlags() & c.NK_WINDOW_MOVABLE) != 0) return error.ControlPanelIsMovable;
    if ((footerBarFlags() & c.NK_WINDOW_MOVABLE) != 0) return error.FooterBarIsMovable;
    if ((footerBarFlags() & c.NK_WINDOW_NO_INPUT) == 0) return error.FooterBarAcceptsInput;
    const rect = controlPanelRect();
    const left: f64 = @floatCast(rect.x);
    const top: f64 = @floatCast(rect.y);
    const right: f64 = @floatCast(rect.x + rect.w);
    const bottom: f64 = @floatCast(rect.y + rect.h);
    if (!pointInControlPanel(left + 1.0, top + 1.0)) return error.ControlPanelHitPolicyMismatch;
    if (!pointInControlPanel(right, bottom)) return error.ControlPanelHitPolicyMismatch;
    if (pointInControlPanel(left - 1.0, top + 1.0)) return error.ControlPanelHitPolicyMismatch;
    if (pointInControlPanel(right + 1.0, bottom + 1.0)) return error.ControlPanelHitPolicyMismatch;

    var event: c.SDL_Event = undefined;
    event.type = c.SDL_EVENT_MOUSE_WHEEL;
    event.wheel.mouse_x = @floatCast(left + 1.0);
    event.wheel.mouse_y = @floatCast(top + 1.0);
    if (!controlPanelShouldReceiveWheel(event)) return error.ControlPanelWheelPolicyMismatch;
    event.wheel.mouse_x = @floatCast(right + 1.0);
    event.wheel.mouse_y = @floatCast(bottom + 1.0);
    if (controlPanelShouldReceiveWheel(event)) return error.ControlPanelWheelPolicyMismatch;

    const footer = footerBarRect();
    const footer_left: f64 = @floatCast(footer.x);
    const footer_top: f64 = @floatCast(footer.y);
    const footer_right: f64 = @floatCast(footer.x + footer.w);
    const footer_bottom: f64 = @floatCast(footer.y + footer.h);
    if (!pointInFooterBar(footer_left + 1.0, footer_top + 1.0)) return error.FooterBarHitPolicyMismatch;
    if (!pointInUiChrome(footer_right - 1.0, footer_bottom - 1.0)) return error.FooterBarHitPolicyMismatch;
    event.wheel.mouse_x = @floatCast(footer_left + 1.0);
    event.wheel.mouse_y = @floatCast(footer_top + 1.0);
    if (controlPanelShouldReceiveWheel(event)) return error.FooterBarWheelPolicyMismatch;
}

pub fn nkBool(value: bool) c.nk_bool {
    return if (value) 1 else 0;
}

pub fn drawText(ctx: *c.struct_nk_context, text: []const u8) void {
    c.nk_text(ctx, text.ptr, @intCast(text.len), c.NK_TEXT_LEFT);
}
