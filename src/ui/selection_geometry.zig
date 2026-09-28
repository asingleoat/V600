//! Selection interaction geometry for the native UI: scan and Process
//! selection hit-testing, screen/preview coordinate transforms, and drag
//! adjustment math shared by the event handlers, render layer, and smokes.

const std = @import("std");
const v600 = @import("v600");
const c = @import("sdl_nuklear.zig").c;
const chrome = @import("chrome.zig");
const PreviewBuffer = v600.native_ui_preview_worker.PreviewBuffer;

pub const ProcessSelectionEditMode = enum {
    draw_frame,
    draw_rebate,
    move,
    rotate,
    north_west,
    north,
    north_east,
    east,
    south_east,
    south,
    south_west,
    west,
};

pub const ScanSelectionInteraction = struct {
    active: bool = false,
    mode: v600.native_ui.PreviewSelectionEditMode = .move,
    start_x: f64 = 0.0,
    start_y: f64 = 0.0,
    original: v600.native_ui.PreviewSelection = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 },

    pub fn beginDraw(self: *ScanSelectionInteraction, preview_x: f64, preview_y: f64) void {
        self.active = true;
        self.mode = .move;
        self.start_x = preview_x;
        self.start_y = preview_y;
        self.original = .{ .x = preview_x, .y = preview_y, .w = 0.0, .h = 0.0 };
    }

    pub fn beginEdit(
        self: *ScanSelectionInteraction,
        mode: v600.native_ui.PreviewSelectionEditMode,
        preview_x: f64,
        preview_y: f64,
        selection: v600.native_ui.PreviewSelection,
    ) void {
        self.active = true;
        self.mode = mode;
        self.start_x = preview_x;
        self.start_y = preview_y;
        self.original = selection;
    }

    pub fn drawing(self: ScanSelectionInteraction) bool {
        return self.original.w == 0.0 and self.original.h == 0.0;
    }

    pub fn end(self: *ScanSelectionInteraction) void {
        self.active = false;
    }
};

pub const ProcessSelectionTarget = enum {
    frame,
    rebate,
};

pub const ProcessDrawTarget = enum {
    frame,
    rebate,
};

pub const ProcessSelectionInteraction = struct {
    active_target: ?ProcessSelectionTarget = null,
    active_index: ?usize = null,
    mode: ProcessSelectionEditMode = .move,
    pending_draw: ?ProcessDrawTarget = null,
    start_x: f64 = 0.0,
    start_y: f64 = 0.0,
    start_pointer_angle: f64 = 0.0,
    original: v600.native_ui.ProcessSelection = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 },
    rebate_active: bool = false,

    pub fn beginFrame(
        self: *ProcessSelectionInteraction,
        index: usize,
        mode: ProcessSelectionEditMode,
        preview_x: f64,
        preview_y: f64,
        selection: v600.native_ui.ProcessSelection,
    ) void {
        self.active_target = .frame;
        self.active_index = index;
        self.mode = mode;
        self.start_x = preview_x;
        self.start_y = preview_y;
        self.start_pointer_angle = pointerAngleFromSelectionCenter(selection, preview_x, preview_y);
        self.original = selection;
        self.rebate_active = false;
    }

    pub fn beginRebate(
        self: *ProcessSelectionInteraction,
        mode: ProcessSelectionEditMode,
        preview_x: f64,
        preview_y: f64,
        selection: v600.native_ui.ProcessSelection,
    ) void {
        self.active_target = .rebate;
        self.active_index = null;
        self.mode = mode;
        self.start_x = preview_x;
        self.start_y = preview_y;
        self.start_pointer_angle = pointerAngleFromSelectionCenter(selection, preview_x, preview_y);
        self.original = selection;
        self.rebate_active = true;
    }

    pub fn beginDrawFrame(self: *ProcessSelectionInteraction, index: usize, preview_x: f64, preview_y: f64) void {
        self.active_target = .frame;
        self.active_index = index;
        self.mode = .draw_frame;
        self.start_x = preview_x;
        self.start_y = preview_y;
        self.original = .{ .x = preview_x, .y = preview_y, .w = 0.0, .h = 0.0 };
        self.rebate_active = false;
    }

    pub fn beginDrawRebate(self: *ProcessSelectionInteraction, preview_x: f64, preview_y: f64) void {
        self.active_target = .rebate;
        self.active_index = null;
        self.mode = .draw_rebate;
        self.start_x = preview_x;
        self.start_y = preview_y;
        self.original = .{ .x = preview_x, .y = preview_y, .w = 0.0, .h = 0.0 };
        self.rebate_active = true;
    }

    pub fn end(self: *ProcessSelectionInteraction) void {
        self.active_target = null;
        self.active_index = null;
    }
};

pub const ScanPreviewBounds = struct {
    w: f64,
    h: f64,
};

pub const ScanPreviewPoint = struct {
    x: f64,
    y: f64,
};

pub fn scanImageRect(
    renderer: *c.SDL_Renderer,
    preview: ?PreviewBuffer,
    transform: *v600.native_ui.ProcessViewTransform,
) ?v600.native_ui.PreviewScreenRect {
    const image = preview orelse return null;
    var out_w: c_int = 0;
    var out_h: c_int = 0;
    if (!c.SDL_GetCurrentRenderOutputSize(renderer, &out_w, &out_h)) return null;
    transform.ensureFit("scan-preview", @intCast(@max(out_w, 1)), @intCast(@max(out_h, 1)), image.width, image.height);
    return transform.imageRect(image.width, image.height);
}

pub fn scanPreviewBounds(preview: ?PreviewBuffer) ?ScanPreviewBounds {
    const image = preview orelse return null;
    return .{
        .w = @floatFromInt(image.width),
        .h = @floatFromInt(image.height),
    };
}

pub fn screenToScanPreview(
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
) ?ScanPreviewPoint {
    if (screen_x < image_rect.x or screen_y < image_rect.y or
        screen_x > image_rect.x + image_rect.w or screen_y > image_rect.y + image_rect.h)
    {
        return null;
    }
    return screenToScanPreviewUnclamped(image_rect, screen_x, screen_y);
}

pub fn screenToScanPreviewUnclamped(
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
) ScanPreviewPoint {
    return .{
        .x = (screen_x - image_rect.x) / image_rect.scale,
        .y = (screen_y - image_rect.y) / image_rect.scale,
    };
}

pub fn hitScanSelection(
    selection: ?v600.native_ui.PreviewSelection,
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
    preview_x: f64,
    preview_y: f64,
) ?v600.native_ui.PreviewSelectionEditMode {
    const sel = selection orelse return null;
    if (!sel.isDrawable()) return null;
    if (scanSelectionHandleAt(sel, image_rect, screen_x, screen_y)) |mode| return mode;
    if (preview_x >= sel.x and preview_x <= sel.x + sel.w and preview_y >= sel.y and preview_y <= sel.y + sel.h) {
        return .move;
    }
    return null;
}

pub fn scanSelectionHandleAt(
    selection: v600.native_ui.PreviewSelection,
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
) ?v600.native_ui.PreviewSelectionEditMode {
    const x = image_rect.x + selection.x * image_rect.scale;
    const y = image_rect.y + selection.y * image_rect.scale;
    const w = selection.w * image_rect.scale;
    const h = selection.h * image_rect.scale;
    const mx = x + w / 2.0;
    const my = y + h / 2.0;
    const handles = [_]struct {
        x: f64,
        y: f64,
        mode: v600.native_ui.PreviewSelectionEditMode,
    }{
        .{ .x = x, .y = y, .mode = .north_west },
        .{ .x = mx, .y = y, .mode = .north },
        .{ .x = x + w, .y = y, .mode = .north_east },
        .{ .x = x + w, .y = my, .mode = .east },
        .{ .x = x + w, .y = y + h, .mode = .south_east },
        .{ .x = mx, .y = y + h, .mode = .south },
        .{ .x = x, .y = y + h, .mode = .south_west },
        .{ .x = x, .y = my, .mode = .west },
    };
    for (handles) |handle| {
        if (@abs(screen_x - handle.x) <= 8.0 and @abs(screen_y - handle.y) <= 8.0) {
            return handle.mode;
        }
    }
    return null;
}

pub const ProcessPreviewPoint = struct {
    x: f64,
    y: f64,
};

pub const ProcessScreenPoint = struct {
    x: f64,
    y: f64,
};

pub const ProcessPreviewBounds = struct {
    w: f64,
    h: f64,
};

pub const ProcessSelectionHit = struct {
    target: ProcessSelectionTarget,
    index: ?usize,
    mode: ProcessSelectionEditMode,
};

pub fn processImageRect(
    renderer: *c.SDL_Renderer,
    model: *const v600.native_ui.State,
    transform: *v600.native_ui.ProcessViewTransform,
) ?v600.native_ui.PreviewScreenRect {
    const preview = model.processing_preview orelse return null;
    var out_w: c_int = 0;
    var out_h: c_int = 0;
    if (!c.SDL_GetCurrentRenderOutputSize(renderer, &out_w, &out_h)) return null;
    transform.ensureFit(
        model.processing.input_path,
        @intCast(@max(out_w, 1)),
        @intCast(@max(out_h, 1)),
        preview.preview_width,
        preview.preview_height,
    );
    return transform.imageRect(preview.preview_width, preview.preview_height);
}

pub fn processPreviewBounds(model: *const v600.native_ui.State) ?ProcessPreviewBounds {
    const preview = model.processing_preview orelse return null;
    return .{
        .w = @floatFromInt(preview.preview_width),
        .h = @floatFromInt(preview.preview_height),
    };
}

pub fn screenToPreview(
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
) ?ProcessPreviewPoint {
    if (screen_x < image_rect.x or screen_y < image_rect.y or
        screen_x > image_rect.x + image_rect.w or screen_y > image_rect.y + image_rect.h)
    {
        return null;
    }
    return screenToPreviewUnclamped(image_rect, screen_x, screen_y);
}

pub fn screenToPreviewUnclamped(
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
) ProcessPreviewPoint {
    return .{
        .x = (screen_x - image_rect.x) / image_rect.scale,
        .y = (screen_y - image_rect.y) / image_rect.scale,
    };
}

pub fn processSelectionCenter(selection: v600.native_ui.ProcessSelection) ProcessPreviewPoint {
    return .{
        .x = selection.x + selection.w / 2.0,
        .y = selection.y + selection.h / 2.0,
    };
}

pub fn pointerAngleFromSelectionCenter(
    selection: v600.native_ui.ProcessSelection,
    preview_x: f64,
    preview_y: f64,
) f64 {
    const center = processSelectionCenter(selection);
    return std.math.atan2(preview_y - center.y, preview_x - center.x);
}

pub fn selectionLocalToPreview(
    selection: v600.native_ui.ProcessSelection,
    local_x: f64,
    local_y: f64,
) ProcessPreviewPoint {
    const center = processSelectionCenter(selection);
    const cos_a = @cos(selection.angle);
    const sin_a = @sin(selection.angle);
    return .{
        .x = center.x + local_x * cos_a - local_y * sin_a,
        .y = center.y + local_x * sin_a + local_y * cos_a,
    };
}

pub fn selectionLocalToScreen(
    image_rect: v600.native_ui.PreviewScreenRect,
    selection: v600.native_ui.ProcessSelection,
    local_x: f64,
    local_y: f64,
) ProcessScreenPoint {
    const preview = selectionLocalToPreview(selection, local_x, local_y);
    return .{
        .x = image_rect.x + preview.x * image_rect.scale,
        .y = image_rect.y + preview.y * image_rect.scale,
    };
}

pub fn previewToSelectionLocal(
    selection: v600.native_ui.ProcessSelection,
    preview_x: f64,
    preview_y: f64,
) ProcessPreviewPoint {
    const center = processSelectionCenter(selection);
    const dx = preview_x - center.x;
    const dy = preview_y - center.y;
    const cos_a = @cos(selection.angle);
    const sin_a = @sin(selection.angle);
    return .{
        .x = dx * cos_a + dy * sin_a,
        .y = -dx * sin_a + dy * cos_a,
    };
}

pub fn previewDeltaToSelectionLocal(angle: f64, dx: f64, dy: f64) ProcessPreviewPoint {
    const cos_a = @cos(angle);
    const sin_a = @sin(angle);
    return .{
        .x = dx * cos_a + dy * sin_a,
        .y = -dx * sin_a + dy * cos_a,
    };
}

pub fn processRotationHandleOffsetPreview(image_rect: v600.native_ui.PreviewScreenRect) f64 {
    if (image_rect.scale <= 0.0) return 0.0;
    return 28.0 / image_rect.scale;
}

pub fn hitProcessSelection(
    model: *const v600.native_ui.State,
    interaction: *const ProcessSelectionInteraction,
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
    preview_x: f64,
    preview_y: f64,
) ?ProcessSelectionHit {
    var index = model.process_selection_count;
    while (index > 0) {
        index -= 1;
        const selection = model.process_selections[index];
        if (processSelectionHandleAt(selection, image_rect, screen_x, screen_y)) |mode| {
            return .{ .target = .frame, .index = index, .mode = mode };
        }
        const local = previewToSelectionLocal(selection, preview_x, preview_y);
        if (@abs(local.x) <= selection.w / 2.0 and @abs(local.y) <= selection.h / 2.0) {
            return .{ .target = .frame, .index = index, .mode = .move };
        }
    }
    if (model.process_rebate_rect) |rebate| {
        if (interaction.rebate_active) {
            if (processSelectionHandleAt(rebate, image_rect, screen_x, screen_y)) |mode| {
                return .{ .target = .rebate, .index = null, .mode = mode };
            }
        }
        const local = previewToSelectionLocal(rebate, preview_x, preview_y);
        if (@abs(local.x) <= rebate.w / 2.0 and @abs(local.y) <= rebate.h / 2.0) {
            return .{ .target = .rebate, .index = null, .mode = .move };
        }
    }
    return null;
}

pub fn processSelectionHandleAt(
    selection: v600.native_ui.ProcessSelection,
    image_rect: v600.native_ui.PreviewScreenRect,
    screen_x: f64,
    screen_y: f64,
) ?ProcessSelectionEditMode {
    if (selection.w <= 0.0 or selection.h <= 0.0) return null;
    const half_w = selection.w / 2.0;
    const half_h = selection.h / 2.0;
    const rotate_y = -half_h - processRotationHandleOffsetPreview(image_rect);
    const rotate_bottom_y = half_h + processRotationHandleOffsetPreview(image_rect);
    const rotate_left_x = -half_w - processRotationHandleOffsetPreview(image_rect);
    const rotate_right_x = half_w + processRotationHandleOffsetPreview(image_rect);
    const handles = [_]struct {
        local_x: f64,
        local_y: f64,
        mode: ProcessSelectionEditMode,
    }{
        .{ .local_x = 0.0, .local_y = rotate_y, .mode = .rotate },
        .{ .local_x = 0.0, .local_y = rotate_bottom_y, .mode = .rotate },
        .{ .local_x = rotate_left_x, .local_y = 0.0, .mode = .rotate },
        .{ .local_x = rotate_right_x, .local_y = 0.0, .mode = .rotate },
        .{ .local_x = -half_w, .local_y = -half_h, .mode = .north_west },
        .{ .local_x = 0.0, .local_y = -half_h, .mode = .north },
        .{ .local_x = half_w, .local_y = -half_h, .mode = .north_east },
        .{ .local_x = half_w, .local_y = 0.0, .mode = .east },
        .{ .local_x = half_w, .local_y = half_h, .mode = .south_east },
        .{ .local_x = 0.0, .local_y = half_h, .mode = .south },
        .{ .local_x = -half_w, .local_y = half_h, .mode = .south_west },
        .{ .local_x = -half_w, .local_y = 0.0, .mode = .west },
    };
    for (handles) |handle| {
        const point = selectionLocalToScreen(image_rect, selection, handle.local_x, handle.local_y);
        const tolerance: f64 = if (handle.mode == .rotate) 10.0 else 8.0;
        if (@abs(screen_x - point.x) <= tolerance and @abs(screen_y - point.y) <= tolerance) {
            return handle.mode;
        }
    }
    return null;
}

pub fn adjustedProcessSelection(
    original: v600.native_ui.ProcessSelection,
    mode: ProcessSelectionEditMode,
    dx: f64,
    dy: f64,
    bounds_w: f64,
    bounds_h: f64,
    aspect: ?f64,
) v600.native_ui.ProcessSelection {
    const min_size = @max(@min(@min(bounds_w, bounds_h), 20.0), 0.1);
    switch (mode) {
        .move => {
            const w = @min(original.w, bounds_w);
            const h = @min(original.h, bounds_h);
            const x = clampFloat(original.x + dx, 0.0, @max(bounds_w - w, 0.0));
            const y = clampFloat(original.y + dy, 0.0, @max(bounds_h - h, 0.0));
            return .{ .x = x, .y = y, .w = w, .h = h, .angle = original.angle, .rotation = original.rotation };
        },
        .rotate => return original,
        .draw_frame, .draw_rebate => return original,
        else => {},
    }

    var left = -original.w / 2.0;
    var top = -original.h / 2.0;
    var right = original.w / 2.0;
    var bottom = original.h / 2.0;
    switch (mode) {
        .north_west => {
            left += dx;
            top += dy;
        },
        .north => top += dy,
        .north_east => {
            right += dx;
            top += dy;
        },
        .east => right += dx,
        .south_east => {
            right += dx;
            bottom += dy;
        },
        .south => bottom += dy,
        .south_west => {
            left += dx;
            bottom += dy;
        },
        .west => left += dx,
        .move, .rotate, .draw_frame, .draw_rebate => unreachable,
    }

    if (right - left < min_size) {
        switch (mode) {
            .west, .north_west, .south_west => left = right - min_size,
            else => right = left + min_size,
        }
    }
    if (bottom - top < min_size) {
        switch (mode) {
            .north, .north_west, .north_east => top = bottom - min_size,
            else => bottom = top + min_size,
        }
    }

    if (aspect) |ratio| {
        if (ratio > 0.0) {
            var width = right - left;
            var height = bottom - top;
            if (mode == .north or mode == .south) {
                width = height * ratio;
            } else {
                height = width / ratio;
            }
            width = @max(width, min_size);
            height = @max(height, min_size);
            const center_y = (top + bottom) / 2.0;
            switch (mode) {
                .west, .north_west, .south_west => left = right - width,
                else => right = left + width,
            }
            switch (mode) {
                .north, .north_west, .north_east => top = bottom - height,
                .south, .south_west, .south_east => bottom = top + height,
                .east, .west => {
                    top = center_y - height / 2.0;
                    bottom = center_y + height / 2.0;
                },
                .move, .rotate, .draw_frame, .draw_rebate => unreachable,
            }
        }
    }

    const max_w = @max(bounds_w, min_size);
    const max_h = @max(bounds_h, min_size);
    var new_w = @min(right - left, max_w);
    var new_h = @min(bottom - top, max_h);
    new_w = @max(new_w, min_size);
    new_h = @max(new_h, min_size);

    const local_center_x = (left + right) / 2.0;
    const local_center_y = (top + bottom) / 2.0;
    const original_center = processSelectionCenter(original);
    const cos_a = @cos(original.angle);
    const sin_a = @sin(original.angle);
    const unclamped_center_x = original_center.x + local_center_x * cos_a - local_center_y * sin_a;
    const unclamped_center_y = original_center.y + local_center_x * sin_a + local_center_y * cos_a;
    const center_x = clampSpanCenter(unclamped_center_x, new_w, bounds_w);
    const center_y = clampSpanCenter(unclamped_center_y, new_h, bounds_h);

    return .{
        .x = center_x - new_w / 2.0,
        .y = center_y - new_h / 2.0,
        .w = new_w,
        .h = new_h,
        .angle = original.angle,
        .rotation = original.rotation,
    };
}

pub fn rotatedProcessSelection(
    original: v600.native_ui.ProcessSelection,
    start_pointer_angle: f64,
    preview_x: f64,
    preview_y: f64,
) v600.native_ui.ProcessSelection {
    var adjusted = original;
    const current_pointer_angle = pointerAngleFromSelectionCenter(original, preview_x, preview_y);
    adjusted.angle = normalizeAngle(original.angle + current_pointer_angle - start_pointer_angle);
    return adjusted;
}

pub fn normalizeAngle(angle: f64) f64 {
    var normalized = angle;
    const tau = std.math.tau;
    while (normalized > std.math.pi) normalized -= tau;
    while (normalized <= -std.math.pi) normalized += tau;
    return normalized;
}

pub fn clampSpanCenter(value: f64, span: f64, bounds: f64) f64 {
    if (bounds <= 0.0) return 0.0;
    if (span >= bounds) return bounds / 2.0;
    const half = span / 2.0;
    return clampFloat(value, half, bounds - half);
}

pub fn clampFloat(value: f64, min_value: f64, max_value: f64) f64 {
    return @min(@max(value, min_value), max_value);
}

pub fn imagePointOutsideUiChrome(
    image_rect: v600.native_ui.PreviewScreenRect,
    ratio_x: f64,
    ratio_y: f64,
) ?ProcessScreenPoint {
    const min_x = image_rect.x + 20.0;
    const max_x = image_rect.x + image_rect.w - 20.0;
    const min_y = image_rect.y + 20.0;
    const max_y = image_rect.y + image_rect.h - 20.0;
    if (min_x > max_x or min_y > max_y) return null;

    const x = clampFloat(image_rect.x + image_rect.w * ratio_x, min_x, max_x);
    var y = clampFloat(image_rect.y + image_rect.h * ratio_y, min_y, max_y);
    if (chrome.pointInFooterBar(x, y)) {
        const footer = chrome.footerBarRect();
        y = clampFloat(@as(f64, @floatCast(footer.y)) - 24.0, min_y, max_y);
    }
    if (!chrome.pointInUiChrome(x, y)) return .{ .x = x, .y = y };

    const panel = chrome.controlPanelRect();
    const gap = 24.0;
    const candidates = [_]ProcessScreenPoint{
        .{ .x = clampFloat(@as(f64, @floatCast(panel.x + panel.w)) + gap, min_x, max_x), .y = y },
        .{ .x = clampFloat(@as(f64, @floatCast(panel.x)) - gap, min_x, max_x), .y = y },
        .{ .x = x, .y = clampFloat(@as(f64, @floatCast(panel.y + panel.h)) + gap, min_y, max_y) },
        .{ .x = x, .y = clampFloat(@as(f64, @floatCast(panel.y)) - gap, min_y, max_y) },
    };
    for (candidates) |candidate| {
        if (candidate.x >= min_x and candidate.x <= max_x and
            candidate.y >= min_y and candidate.y <= max_y and
            !chrome.pointInUiChrome(candidate.x, candidate.y))
        {
            return candidate;
        }
    }
    return null;
}
