//! Mouse cursor shapes for the image canvases: crosshair over the image, move
//! over a selection, resize over edge handles, pointer over rotation handles.

const cerealgrain = @import("cerealgrain");
const c = @import("sdl_nuklear.zig").c;
const selection_geometry = @import("selection_geometry.zig");

pub const Shape = enum {
    default,
    crosshair,
    move,
    pointer,
    resize_ns,
    resize_ew,
    resize_nwse,
    resize_nesw,

    fn system(self: Shape) c.SDL_SystemCursor {
        return switch (self) {
            .default => c.SDL_SYSTEM_CURSOR_DEFAULT,
            .crosshair => c.SDL_SYSTEM_CURSOR_CROSSHAIR,
            .move => c.SDL_SYSTEM_CURSOR_MOVE,
            .pointer => c.SDL_SYSTEM_CURSOR_POINTER,
            .resize_ns => c.SDL_SYSTEM_CURSOR_NS_RESIZE,
            .resize_ew => c.SDL_SYSTEM_CURSOR_EW_RESIZE,
            .resize_nwse => c.SDL_SYSTEM_CURSOR_NWSE_RESIZE,
            .resize_nesw => c.SDL_SYSTEM_CURSOR_NESW_RESIZE,
        };
    }
};

var cursors = [_]?*c.SDL_Cursor{null} ** @typeInfo(Shape).@"enum".fields.len;
var current: Shape = .default;

pub fn set(shape: Shape) void {
    if (shape == current) return;
    const slot = &cursors[@intFromEnum(shape)];
    if (slot.* == null) slot.* = c.SDL_CreateSystemCursor(shape.system());
    const cursor = slot.* orelse return;
    if (c.SDL_SetCursor(cursor)) current = shape;
}

pub fn deinit() void {
    for (&cursors) |*slot| {
        if (slot.*) |cursor| c.SDL_DestroyCursor(cursor);
        slot.* = null;
    }
}

pub fn forScanEdit(mode: cerealgrain.native_ui.PreviewSelectionEditMode) Shape {
    return switch (mode) {
        .move => .move,
        .north, .south => .resize_ns,
        .east, .west => .resize_ew,
        .north_west, .south_east => .resize_nwse,
        .north_east, .south_west => .resize_nesw,
    };
}

pub fn forProcessEdit(mode: selection_geometry.ProcessSelectionEditMode) Shape {
    return switch (mode) {
        .draw_frame, .draw_rebate => .crosshair,
        .move => .move,
        .rotate => .pointer,
        .north, .south => .resize_ns,
        .east, .west => .resize_ew,
        .north_west, .south_east => .resize_nwse,
        .north_east, .south_west => .resize_nesw,
    };
}
