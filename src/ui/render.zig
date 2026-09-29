//! SDL render layer for the native UI: texture caches, the Nuklear vertex
//! renderer, preview/process/gallery texture presentation, and selection
//! overlay drawing.

const std = @import("std");
const v600 = @import("v600");
const c = @import("sdl_nuklear.zig").c;
const selection_geometry = @import("selection_geometry.zig");
const chrome = @import("chrome.zig");

const ProcessSelectionInteraction = selection_geometry.ProcessSelectionInteraction;
const ProcessScreenPoint = selection_geometry.ProcessScreenPoint;
const processImageRect = selection_geometry.processImageRect;
const selectionLocalToScreen = selection_geometry.selectionLocalToScreen;
const processRotationHandleOffsetPreview = selection_geometry.processRotationHandleOffsetPreview;
const ProcessCache = v600.native_ui_process_cache;
const InvertedPreviewWorker = v600.native_ui_inverted_preview_worker.Worker;
const InvertedPreviewKey = v600.native_ui_inverted_preview_worker.Key;
const InvertedPreviewResult = v600.native_ui_inverted_preview_worker.Result;
const PreviewBuffer = v600.native_ui_preview_worker.PreviewBuffer;

pub const process_selection_line_width: f32 = 3.0;
pub const process_selection_antialias_width: f32 = 1.0;
pub const PreviewTextureCache = struct {
    texture: ?*c.SDL_Texture = null,
    data_ptr: ?[*]const u8 = null,
    width: u32 = 0,
    height: u32 = 0,

    pub fn deinit(self: *PreviewTextureCache) void {
        if (self.texture) |texture| {
            c.SDL_DestroyTexture(texture);
            self.texture = null;
        }
    }

    pub fn textureFor(self: *PreviewTextureCache, renderer: *c.SDL_Renderer, preview: PreviewBuffer) !*c.SDL_Texture {
        if (self.texture) |texture| {
            if (self.data_ptr == preview.data.ptr and self.width == preview.width and self.height == preview.height) {
                return texture;
            }
            c.SDL_DestroyTexture(texture);
            self.texture = null;
        }

        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_RGB24,
            c.SDL_TEXTUREACCESS_STATIC,
            @intCast(preview.width),
            @intCast(preview.height),
        ) orelse return error.SdlPreviewTextureFailed;
        errdefer c.SDL_DestroyTexture(texture);
        const pitch = try std.math.mul(c_int, @intCast(preview.width), 3);
        if (!c.SDL_UpdateTexture(texture, null, preview.data.ptr, pitch)) {
            return error.SdlPreviewTextureUpdateFailed;
        }
        self.texture = texture;
        self.data_ptr = preview.data.ptr;
        self.width = preview.width;
        self.height = preview.height;
        return texture;
    }
};

pub const ProcessPreviewTextureCache = struct {
    texture: ?*c.SDL_Texture = null,
    data_ptr: ?[*]const u8 = null,
    width: usize = 0,
    height: usize = 0,
    used_inverted: bool = false,
    texture_key: ?InvertedPreviewKey = null,
    request_key: ?InvertedPreviewKey = null,

    pub fn deinit(self: *ProcessPreviewTextureCache, allocator: std.mem.Allocator) void {
        self.clearTexture(allocator);
        self.clearRequestKey(allocator);
    }

    pub fn textureFor(
        self: *ProcessPreviewTextureCache,
        renderer: *c.SDL_Renderer,
        allocator: std.mem.Allocator,
        io: std.Io,
        model: *v600.native_ui.State,
        inverted_preview_worker: *InvertedPreviewWorker,
    ) !*c.SDL_Texture {
        const preview = model.processing_preview orelse return error.NoProcessImageLoaded;
        const requested_inverted = model.processing_preview_inversion_enabled;
        const options = model.processingInvertedPreviewOptions();
        const generation = model.processingGeneration();
        if (requested_inverted) {
            try self.maybeStartInvertedRender(renderer, allocator, io, model, preview, generation, options, inverted_preview_worker);
        } else {
            self.clearRequestKey(allocator);
        }

        if (self.texture) |texture| {
            if (self.width == preview.preview_width and self.height == preview.preview_height and
                !self.used_inverted and self.data_ptr == preview.preview_rgb8.ptr)
            {
                return texture;
            }
            if (requested_inverted and self.used_inverted) {
                if (self.texture_key) |key| {
                    if (key.matches(preview, generation, options)) return texture;
                }
            }
            self.clearTexture(allocator);
        }

        const texture = try createProcessRgbTexture(renderer, preview.preview_width, preview.preview_height, preview.preview_rgb8);
        self.texture = texture;
        self.data_ptr = preview.preview_rgb8.ptr;
        self.width = preview.preview_width;
        self.height = preview.preview_height;
        self.used_inverted = false;
        return texture;
    }

    pub fn installInvertedResult(
        self: *ProcessPreviewTextureCache,
        renderer: *c.SDL_Renderer,
        allocator: std.mem.Allocator,
        io: std.Io,
        model: *v600.native_ui.State,
        result: *InvertedPreviewResult,
    ) !bool {
        const preview = model.processing_preview orelse return false;
        const options = model.processingInvertedPreviewOptions();
        if (!model.processing_preview_inversion_enabled or
            !result.key.matches(preview, model.processingGeneration(), options))
        {
            return false;
        }
        const rgb = result.rgb8 orelse return false;
        const expected_len = try std.math.mul(usize, try std.math.mul(usize, preview.preview_width, preview.preview_height), 3);
        if (rgb.len != expected_len) return error.InvalidPreviewBuffer;

        const texture = try createProcessRgbTexture(renderer, preview.preview_width, preview.preview_height, rgb);
        cacheInvertedPreviewResult(allocator, io, model, preview, options, rgb) catch {};
        allocator.free(rgb);
        result.rgb8 = null;
        self.clearTexture(allocator);
        self.clearRequestKey(allocator);
        self.texture = texture;
        self.data_ptr = null;
        self.width = preview.preview_width;
        self.height = preview.preview_height;
        self.used_inverted = true;
        self.texture_key = result.key;
        result.key = InvertedPreviewKey.empty();
        return true;
    }

    pub fn maybeStartInvertedRender(
        self: *ProcessPreviewTextureCache,
        renderer: *c.SDL_Renderer,
        allocator: std.mem.Allocator,
        io: std.Io,
        model: *v600.native_ui.State,
        preview: v600.processing.workflow.QuickPreview,
        generation: usize,
        options: v600.processing.workflow.InvertedPreviewOptions,
        worker: *InvertedPreviewWorker,
    ) !void {
        if (options.stock == null or preview.info.is_grayscale or worker.isRunning()) return;
        if (self.used_inverted) {
            if (self.texture_key) |key| {
                if (key.matches(preview, generation, options)) return;
            }
        }
        if (self.request_key) |key| {
            if (key.matches(preview, generation, options)) return;
        }
        if (try self.installCachedInvertedResult(renderer, allocator, io, model, preview, generation, options)) return;

        var request_key = try InvertedPreviewKey.initCopy(allocator, preview, generation, options);
        errdefer request_key.deinit(allocator);
        if (try worker.start(preview, generation, options)) {
            self.replaceRequestKey(allocator, &request_key);
        } else {
            request_key.deinit(allocator);
        }
    }

    pub fn installCachedInvertedResult(
        self: *ProcessPreviewTextureCache,
        renderer: *c.SDL_Renderer,
        allocator: std.mem.Allocator,
        io: std.Io,
        model: *v600.native_ui.State,
        preview: v600.processing.workflow.QuickPreview,
        generation: usize,
        options: v600.processing.workflow.InvertedPreviewOptions,
    ) !bool {
        var key = invertedPreviewCacheKey(allocator, io, model, preview, options) catch return false;
        defer key.deinit(allocator);
        const rgb = (try model.processing_result_cache.inverted_previews.getClone(allocator, key)) orelse return false;
        defer allocator.free(rgb);
        const expected_len = try std.math.mul(usize, try std.math.mul(usize, preview.preview_width, preview.preview_height), 3);
        if (rgb.len != expected_len) return false;
        var texture_key = try InvertedPreviewKey.initCopy(allocator, preview, generation, options);
        errdefer texture_key.deinit(allocator);
        const texture = try createProcessRgbTexture(renderer, preview.preview_width, preview.preview_height, rgb);
        self.clearTexture(allocator);
        self.clearRequestKey(allocator);
        self.texture = texture;
        self.data_ptr = null;
        self.width = preview.preview_width;
        self.height = preview.preview_height;
        self.used_inverted = true;
        self.texture_key = texture_key;
        texture_key = InvertedPreviewKey.empty();
        return true;
    }

    pub fn replaceRequestKey(
        self: *ProcessPreviewTextureCache,
        allocator: std.mem.Allocator,
        key: *InvertedPreviewKey,
    ) void {
        self.clearRequestKey(allocator);
        self.request_key = key.*;
        key.* = InvertedPreviewKey.empty();
    }

    pub fn clearTexture(self: *ProcessPreviewTextureCache, allocator: std.mem.Allocator) void {
        if (self.texture) |texture| {
            c.SDL_DestroyTexture(texture);
            self.texture = null;
        }
        if (self.texture_key) |*key| {
            key.deinit(allocator);
            self.texture_key = null;
        }
        self.data_ptr = null;
        self.width = 0;
        self.height = 0;
        self.used_inverted = false;
    }

    pub fn clearRequestKey(self: *ProcessPreviewTextureCache, allocator: std.mem.Allocator) void {
        if (self.request_key) |*key| {
            key.deinit(allocator);
            self.request_key = null;
        }
    }
};

pub fn invertedPreviewCacheKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: *const v600.native_ui.State,
    preview: v600.processing.workflow.QuickPreview,
    options: v600.processing.workflow.InvertedPreviewOptions,
) !ProcessCache.Key {
    const path = model.currentProcessingImagePathForWorker() orelse return error.NoProcessImageLoaded;
    return ProcessCache.invertedPreviewKey(allocator, io, path, &model.processing_config, .{
        .stock = options.stock,
        .dmin = options.dmin,
        .render_options = options.render_options,
        .invert_request = options.invert_request,
        .preview_width = preview.preview_width,
        .preview_height = preview.preview_height,
        .preview_scale = preview.info.preview_scale,
    });
}

pub fn cacheInvertedPreviewResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: *v600.native_ui.State,
    preview: v600.processing.workflow.QuickPreview,
    options: v600.processing.workflow.InvertedPreviewOptions,
    rgb8: []const u8,
) !void {
    var key = try invertedPreviewCacheKey(allocator, io, model, preview, options);
    defer key.deinit(allocator);
    try model.processing_result_cache.inverted_previews.putClone(allocator, key, rgb8);
}

pub fn createProcessRgbTexture(
    renderer: *c.SDL_Renderer,
    width: usize,
    height: usize,
    rgb: []const u8,
) !*c.SDL_Texture {
    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_RGB24,
        c.SDL_TEXTUREACCESS_STATIC,
        @intCast(width),
        @intCast(height),
    ) orelse return error.SdlProcessTextureFailed;
    errdefer c.SDL_DestroyTexture(texture);
    const pitch = try std.math.mul(c_int, @intCast(width), 3);
    if (!c.SDL_UpdateTexture(texture, null, rgb.ptr, pitch)) {
        return error.SdlProcessTextureUpdateFailed;
    }
    return texture;
}

pub const GalleryViewTransform = struct {
    scale: f64 = 1.0,
    offset_x: f64 = 0.0,
    offset_y: f64 = 0.0,
    panning: bool = false,
    pan_button: u8 = 0,
    pan_start_x: f64 = 0.0,
    pan_start_y: f64 = 0.0,
    needs_fit: bool = true,
    fitted: bool = false,
    key: ?[]u8 = null,
    output_width: c_int = 0,
    output_height: c_int = 0,
    /// Top-left of the canvas area the image is fitted into.
    area_x: f64 = 0.0,
    area_y: f64 = 0.0,

    pub fn deinit(self: *GalleryViewTransform, allocator: std.mem.Allocator) void {
        if (self.key) |key| {
            allocator.free(key);
            self.key = null;
        }
    }

    pub fn ensureFit(
        self: *GalleryViewTransform,
        allocator: std.mem.Allocator,
        key: []const u8,
        output_width: c_int,
        output_height: c_int,
        image_width: u32,
        image_height: u32,
    ) !void {
        try self.ensureFitIn(allocator, key, 0.0, 0.0, output_width, output_height, image_width, image_height);
    }

    /// Fits into the area at (`area_x`, `area_y`) of the given size.
    pub fn ensureFitIn(
        self: *GalleryViewTransform,
        allocator: std.mem.Allocator,
        key: []const u8,
        area_x: f64,
        area_y: f64,
        output_width: c_int,
        output_height: c_int,
        image_width: u32,
        image_height: u32,
    ) !void {
        const key_changed = self.key == null or !std.mem.eql(u8, self.key.?, key);
        if (!self.needs_fit and !key_changed and self.output_width == output_width and self.output_height == output_height and
            self.area_x == area_x and self.area_y == area_y) return;
        if (key_changed) {
            if (self.key) |old_key| allocator.free(old_key);
            self.key = try allocator.dupe(u8, key);
        }
        self.area_x = area_x;
        self.area_y = area_y;
        self.fit(output_width, output_height, image_width, image_height);
    }

    pub fn fit(self: *GalleryViewTransform, output_width: c_int, output_height: c_int, image_width: u32, image_height: u32) void {
        const out_w = @as(f64, @floatFromInt(@max(output_width, 1)));
        const out_h = @as(f64, @floatFromInt(@max(output_height, 1)));
        const img_w = @as(f64, @floatFromInt(image_width));
        const img_h = @as(f64, @floatFromInt(image_height));
        self.scale = @min(@min(out_w / img_w, out_h / img_h), 1.0);
        self.offset_x = self.area_x + (out_w - img_w * self.scale) / 2.0;
        self.offset_y = self.area_y + (out_h - img_h * self.scale) / 2.0;
        self.output_width = output_width;
        self.output_height = output_height;
        self.needs_fit = false;
        self.fitted = true;
        self.panning = false;
        self.pan_button = 0;
    }

    pub fn requestFit(self: *GalleryViewTransform) void {
        self.needs_fit = true;
    }

    pub fn zoomAt(self: *GalleryViewTransform, x: f64, y: f64, factor: f64) void {
        if (!self.fitted) return;
        self.offset_x = x - (x - self.offset_x) * factor;
        self.offset_y = y - (y - self.offset_y) * factor;
        self.scale *= factor;
    }

    pub fn beginPan(self: *GalleryViewTransform, x: f64, y: f64, button: u8) void {
        if (!self.fitted) return;
        self.panning = true;
        self.pan_button = button;
        self.pan_start_x = x - self.offset_x;
        self.pan_start_y = y - self.offset_y;
    }

    pub fn updatePan(self: *GalleryViewTransform, x: f64, y: f64) void {
        if (!self.panning) return;
        self.offset_x = x - self.pan_start_x;
        self.offset_y = y - self.pan_start_y;
    }

    pub fn endPan(self: *GalleryViewTransform, button: u8) void {
        if (self.pan_button != 0 and self.pan_button != button) return;
        self.panning = false;
        self.pan_button = 0;
    }

    pub fn isFitted(self: GalleryViewTransform) bool {
        return self.fitted and self.scale > 0.0;
    }

    pub fn destination(self: GalleryViewTransform, image_width: u32, image_height: u32) c.SDL_FRect {
        return .{
            .x = @floatCast(self.offset_x),
            .y = @floatCast(self.offset_y),
            .w = @floatCast(@as(f64, @floatFromInt(image_width)) * self.scale),
            .h = @floatCast(@as(f64, @floatFromInt(image_height)) * self.scale),
        };
    }
};

pub const GalleryTextureCache = struct {
    texture: ?*c.SDL_Texture = null,
    key: ?[]u8 = null,
    width: u32 = 0,
    height: u32 = 0,

    pub fn deinit(self: *GalleryTextureCache, allocator: std.mem.Allocator) void {
        if (self.texture) |texture| {
            c.SDL_DestroyTexture(texture);
            self.texture = null;
        }
        if (self.key) |key| {
            allocator.free(key);
            self.key = null;
        }
    }

    pub fn textureFor(
        self: *GalleryTextureCache,
        renderer: *c.SDL_Renderer,
        allocator: std.mem.Allocator,
        model: *const v600.native_ui.State,
    ) !?*c.SDL_Texture {
        const name = model.currentGalleryFileName() orelse return null;
        const path = try std.fs.path.join(allocator, &.{ model.processing.output_dir, name });
        defer allocator.free(path);
        if (self.texture) |texture| {
            if (self.key) |key| {
                if (std.mem.eql(u8, key, path)) return texture;
            }
        }

        self.deinit(allocator);
        var image = try v600.tiff.loadRgbPage(allocator, path);
        defer image.deinit(allocator);
        const rgb = try galleryImageRgb8(allocator, image);
        defer allocator.free(rgb);
        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_RGB24,
            c.SDL_TEXTUREACCESS_STATIC,
            @intCast(image.width),
            @intCast(image.height),
        ) orelse return error.SdlGalleryTextureFailed;
        errdefer c.SDL_DestroyTexture(texture);
        const pitch = try std.math.mul(c_int, @intCast(image.width), 3);
        if (!c.SDL_UpdateTexture(texture, null, rgb.ptr, pitch)) {
            return error.SdlGalleryTextureUpdateFailed;
        }
        self.texture = texture;
        self.key = try allocator.dupe(u8, path);
        self.width = image.width;
        self.height = image.height;
        return texture;
    }
};

pub const gallery_thumb_max_dim = 200;
pub const GalleryThumbnail = struct {
    name: []u8,
    texture: *c.SDL_Texture,
    width: u32,
    height: u32,

    pub fn deinit(self: GalleryThumbnail, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        c.SDL_DestroyTexture(self.texture);
    }
};

pub const GalleryThumbnailCache = struct {
    output_dir: ?[]u8 = null,
    entries: []GalleryThumbnail = &.{},

    pub fn deinit(self: *GalleryThumbnailCache, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.entries = &.{};
        if (self.output_dir) |output_dir| {
            allocator.free(output_dir);
            self.output_dir = null;
        }
    }

    pub fn sync(
        self: *GalleryThumbnailCache,
        allocator: std.mem.Allocator,
        output_dir: []const u8,
        files: []const []const u8,
    ) !void {
        if (self.output_dir == null or !std.mem.eql(u8, self.output_dir.?, output_dir)) {
            self.deinit(allocator);
            self.output_dir = try allocator.dupe(u8, output_dir);
        }

        var index: usize = 0;
        while (index < self.entries.len) {
            if (containsGalleryName(files, self.entries[index].name)) {
                index += 1;
                continue;
            }
            self.entries[index].deinit(allocator);
            self.entries[index] = self.entries[self.entries.len - 1];
            self.entries = try resizeThumbnailEntries(allocator, self.entries, self.entries.len - 1);
        }
    }

    pub fn imageFor(
        self: *GalleryThumbnailCache,
        renderer: *c.SDL_Renderer,
        allocator: std.mem.Allocator,
        output_dir: []const u8,
        name: []const u8,
    ) !c.struct_nk_image {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return nkImageForTexture(entry.texture, entry.width, entry.height);
            }
        }

        const path = try std.fs.path.join(allocator, &.{ output_dir, name });
        defer allocator.free(path);
        var image = try v600.tiff.loadRgbPage(allocator, path);
        defer image.deinit(allocator);
        const rgb = try galleryImageRgb8(allocator, image);
        defer allocator.free(rgb);
        const dimensions = thumbnailDimensions(image.width, image.height);
        const resized = try v600.processing.frames.resizeImageArea(
            allocator,
            rgb,
            @intCast(image.width),
            @intCast(image.height),
            3,
            8,
            @intCast(dimensions.width),
            @intCast(dimensions.height),
        );
        defer allocator.free(resized);
        const texture = c.SDL_CreateTexture(
            renderer,
            c.SDL_PIXELFORMAT_RGB24,
            c.SDL_TEXTUREACCESS_STATIC,
            @intCast(dimensions.width),
            @intCast(dimensions.height),
        ) orelse return error.SdlGalleryThumbnailTextureFailed;
        errdefer c.SDL_DestroyTexture(texture);
        const pitch = try std.math.mul(c_int, @intCast(dimensions.width), 3);
        if (!c.SDL_UpdateTexture(texture, null, resized.ptr, pitch)) {
            return error.SdlGalleryThumbnailTextureUpdateFailed;
        }

        const entry = GalleryThumbnail{
            .name = try allocator.dupe(u8, name),
            .texture = texture,
            .width = dimensions.width,
            .height = dimensions.height,
        };
        errdefer entry.deinit(allocator);
        try self.append(allocator, entry);
        return nkImageForTexture(texture, dimensions.width, dimensions.height);
    }

    pub fn append(self: *GalleryThumbnailCache, allocator: std.mem.Allocator, entry: GalleryThumbnail) !void {
        const next = try allocator.alloc(GalleryThumbnail, self.entries.len + 1);
        @memcpy(next[0..self.entries.len], self.entries);
        next[self.entries.len] = entry;
        allocator.free(self.entries);
        self.entries = next;
    }
};

pub fn resizeThumbnailEntries(
    allocator: std.mem.Allocator,
    entries: []GalleryThumbnail,
    len: usize,
) ![]GalleryThumbnail {
    const next = try allocator.alloc(GalleryThumbnail, len);
    @memcpy(next, entries[0..len]);
    allocator.free(entries);
    return next;
}

pub const ThumbnailDimensions = struct {
    width: u32,
    height: u32,
};

pub fn thumbnailDimensions(width: u32, height: u32) ThumbnailDimensions {
    const max_dim = @max(width, height);
    if (max_dim <= gallery_thumb_max_dim) {
        return .{ .width = width, .height = height };
    }
    const scale = @as(f64, @floatFromInt(gallery_thumb_max_dim)) / @as(f64, @floatFromInt(max_dim));
    return .{
        .width = @max(@as(u32, 1), @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(width)) * scale)))),
        .height = @max(@as(u32, 1), @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(height)) * scale)))),
    };
}

pub fn nkImageForTexture(texture: *c.SDL_Texture, width: u32, height: u32) c.struct_nk_image {
    return c.nk_subimage_handle(
        c.nk_handle_ptr(texture),
        @intCast(width),
        @intCast(height),
        c.nk_rect(0, 0, @floatFromInt(width), @floatFromInt(height)),
    );
}

pub const UiVertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: c.SDL_FColor,
};

pub const NuklearRenderer = struct {
    renderer: *c.SDL_Renderer,
    font_texture: ?*c.SDL_Texture = null,
    null_texture: c.struct_nk_draw_null_texture = undefined,

    pub fn init(renderer: *c.SDL_Renderer) NuklearRenderer {
        return .{ .renderer = renderer };
    }

    /// Replaces the font atlas texture. It is sampled nearest: the pixel
    /// font is baked to land 1:1 on device pixels.
    pub fn setFontTexture(self: *NuklearRenderer, atlas_pixels: *const anyopaque, width: c_int, height: c_int) !void {
        const texture = c.SDL_CreateTexture(
            self.renderer,
            c.SDL_PIXELFORMAT_RGBA32,
            c.SDL_TEXTUREACCESS_STATIC,
            width,
            height,
        ) orelse return error.NuklearFontTextureFailed;
        errdefer c.SDL_DestroyTexture(texture);
        if (!c.SDL_UpdateTexture(texture, null, atlas_pixels, width * 4)) {
            return error.NuklearFontTextureUpdateFailed;
        }
        _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_NEAREST);
        if (self.font_texture) |old| c.SDL_DestroyTexture(old);
        self.font_texture = texture;
    }

    pub fn deinit(self: *NuklearRenderer) void {
        if (self.font_texture) |texture| c.SDL_DestroyTexture(texture);
    }

    pub fn render(self: *NuklearRenderer, ctx: *c.struct_nk_context) !void {
        var cmds: c.struct_nk_buffer = undefined;
        var vertices: c.struct_nk_buffer = undefined;
        var elements: c.struct_nk_buffer = undefined;
        c.nk_buffer_init_default(&cmds);
        defer c.nk_buffer_free(&cmds);
        c.nk_buffer_init_default(&vertices);
        defer c.nk_buffer_free(&vertices);
        c.nk_buffer_init_default(&elements);
        defer c.nk_buffer_free(&elements);

        const layout = [_]c.struct_nk_draw_vertex_layout_element{
            .{ .attribute = c.NK_VERTEX_POSITION, .format = c.NK_FORMAT_FLOAT, .offset = @offsetOf(UiVertex, "position") },
            .{ .attribute = c.NK_VERTEX_TEXCOORD, .format = c.NK_FORMAT_FLOAT, .offset = @offsetOf(UiVertex, "uv") },
            .{ .attribute = c.NK_VERTEX_COLOR, .format = c.NK_FORMAT_R32G32B32A32_FLOAT, .offset = @offsetOf(UiVertex, "color") },
            .{ .attribute = c.NK_VERTEX_ATTRIBUTE_COUNT, .format = c.NK_FORMAT_COUNT, .offset = 0 },
        };
        const config = c.struct_nk_convert_config{
            .global_alpha = 1.0,
            .line_AA = c.NK_ANTI_ALIASING_ON,
            .shape_AA = c.NK_ANTI_ALIASING_ON,
            .circle_segment_count = 22,
            .arc_segment_count = 22,
            .curve_segment_count = 22,
            .tex_null = self.null_texture,
            .vertex_layout = &layout,
            .vertex_size = @sizeOf(UiVertex),
            .vertex_alignment = @alignOf(UiVertex),
        };
        const convert_result = c.nk_convert(ctx, &cmds, &vertices, &elements, &config);
        if (convert_result != c.NK_CONVERT_SUCCESS) return error.NuklearConvertFailed;

        const vertex_bytes = c.nk_buffer_total(&vertices);
        const element_bytes = c.nk_buffer_total(&elements);
        if (vertex_bytes == 0 or element_bytes == 0) return;
        const vertex_count: c_int = @intCast(vertex_bytes / @sizeOf(UiVertex));
        const vertices_ptr: [*]const UiVertex = @ptrCast(@alignCast(c.nk_buffer_memory_const(&vertices)));
        const elements_ptr: [*]const c.nk_draw_index = @ptrCast(@alignCast(c.nk_buffer_memory_const(&elements)));

        var element_offset: usize = 0;
        var command = c.nk__draw_begin(ctx, &cmds);
        while (command != null) : (command = c.nk__draw_next(command, &cmds, ctx)) {
            const cmd = command.?;
            if (cmd.*.elem_count == 0) continue;
            const clip = c.SDL_Rect{
                .x = @intFromFloat(@max(0.0, @floor(cmd.*.clip_rect.x))),
                .y = @intFromFloat(@max(0.0, @floor(cmd.*.clip_rect.y))),
                .w = @intFromFloat(@max(0.0, @ceil(cmd.*.clip_rect.w))),
                .h = @intFromFloat(@max(0.0, @ceil(cmd.*.clip_rect.h))),
            };
            _ = c.SDL_SetRenderClipRect(self.renderer, &clip);
            const texture: ?*c.SDL_Texture = if (cmd.*.texture.ptr) |ptr|
                @ptrCast(@alignCast(ptr))
            else
                null;
            _ = c.SDL_RenderGeometryRaw(
                self.renderer,
                texture,
                &vertices_ptr[0].position[0],
                @sizeOf(UiVertex),
                &vertices_ptr[0].color,
                @sizeOf(UiVertex),
                &vertices_ptr[0].uv[0],
                @sizeOf(UiVertex),
                vertex_count,
                elements_ptr + element_offset,
                @intCast(cmd.*.elem_count),
                @sizeOf(c.nk_draw_index),
            );
            element_offset += cmd.*.elem_count;
        }
        _ = c.SDL_SetRenderClipRect(self.renderer, null);
    }
};

pub fn renderPreviewTexture(
    renderer: *c.SDL_Renderer,
    cache: *PreviewTextureCache,
    preview: ?PreviewBuffer,
    model: *const v600.native_ui.State,
    transform: *v600.native_ui.ProcessViewTransform,
    sweep: ?v600.native_ui_scan_sweep.Sweep,
    now_ms: u64,
) void {
    const image = preview orelse return;
    const rect = selection_geometry.scanImageRect(renderer, preview, transform) orelse return;
    const texture = cache.textureFor(renderer, image) catch return;
    const dst = c.SDL_FRect{
        .x = @floatCast(rect.x),
        .y = @floatCast(rect.y),
        .w = @floatCast(rect.w),
        .h = @floatCast(rect.h),
    };
    _ = c.SDL_RenderTexture(renderer, texture, null, &dst);
    renderSelectionOverlay(renderer, rect, model.scan_controls.selection);
    if (sweep) |line| renderScanSweep(renderer, rect, line, now_ms);
}

/// A glowing line where the scanner is reading, with a short trail behind
/// it and the part not yet read dimmed. Cyan for RGB, red for the IR pass;
/// before any lines arrive it pulses at the top of the area.
pub fn renderScanSweep(
    renderer: *c.SDL_Renderer,
    image_rect: v600.native_ui.PreviewScreenRect,
    sweep: v600.native_ui_scan_sweep.Sweep,
    now_ms: u64,
) void {
    const area = if (sweep.area) |sel| v600.native_ui.PreviewScreenRect{
        .x = image_rect.x + sel.x * image_rect.scale,
        .y = image_rect.y + sel.y * image_rect.scale,
        .w = sel.w * image_rect.scale,
        .h = sel.h * image_rect.scale,
        .scale = image_rect.scale,
    } else image_rect;
    if (area.w < 1.0 or area.h < 1.0) return;

    const color: [3]u8 = if (sweep.ir_pass) .{ 255, 90, 70 } else .{ 80, 210, 255 };
    const seconds = @as(f64, @floatFromInt(now_ms)) / 1000.0;
    const pulse = 0.5 + 0.5 * @sin(seconds * std.math.tau * 0.8);
    const line_y = area.y + area.h * std.math.clamp(sweep.fraction, 0.0, 1.0);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 90);
    const unread = c.SDL_FRect{
        .x = @floatCast(area.x),
        .y = @floatCast(line_y),
        .w = @floatCast(area.w),
        .h = @floatCast(area.y + area.h - line_y),
    };
    _ = c.SDL_RenderFillRect(renderer, &unread);

    if (!sweep.waiting) {
        const trail_px = 28.0;
        const rows: usize = @intFromFloat(@max(0.0, @min(trail_px, line_y - 1.5 - area.y)));
        for (0..rows) |row| {
            const t = @as(f64, @floatFromInt(row)) / trail_px;
            const alpha: u8 = @intFromFloat(110.0 * (1.0 - t) * (1.0 - t));
            _ = c.SDL_SetRenderDrawColor(renderer, color[0], color[1], color[2], alpha);
            const rect = c.SDL_FRect{
                .x = @floatCast(area.x),
                .y = @floatCast(line_y - 1.5 - @as(f64, @floatFromInt(row + 1))),
                .w = @floatCast(area.w),
                .h = 1.0,
            };
            _ = c.SDL_RenderFillRect(renderer, &rect);
        }
    }

    const line_alpha: u8 = @intFromFloat(if (sweep.waiting) 80.0 + 150.0 * pulse else 200.0 + 55.0 * pulse);
    _ = c.SDL_SetRenderDrawColor(renderer, color[0], color[1], color[2], line_alpha);
    const line = c.SDL_FRect{
        .x = @floatCast(area.x),
        .y = @floatCast(line_y - 1.5),
        .w = @floatCast(area.w),
        .h = 3.0,
    };
    _ = c.SDL_RenderFillRect(renderer, &line);
    const core: [3]u8 = if (sweep.ir_pass) .{ 255, 225, 215 } else .{ 225, 250, 255 };
    _ = c.SDL_SetRenderDrawColor(renderer, core[0], core[1], core[2], line_alpha);
    const core_line = c.SDL_FRect{
        .x = @floatCast(area.x),
        .y = @floatCast(line_y - 0.5),
        .w = @floatCast(area.w),
        .h = 1.0,
    };
    _ = c.SDL_RenderFillRect(renderer, &core_line);
}

pub fn renderProcessTexture(
    renderer: *c.SDL_Renderer,
    io: std.Io,
    cache: *ProcessPreviewTextureCache,
    inverted_preview_worker: *InvertedPreviewWorker,
    model: *v600.native_ui.State,
    interaction: *const ProcessSelectionInteraction,
    transform: *v600.native_ui.ProcessViewTransform,
) void {
    if (model.processing.loading or model.processing_preview == null) return;
    const rect = processImageRect(renderer, model, transform) orelse return;
    const texture = cache.textureFor(renderer, std.heap.page_allocator, io, model, inverted_preview_worker) catch return;
    const dst = c.SDL_FRect{
        .x = @floatCast(rect.x),
        .y = @floatCast(rect.y),
        .w = @floatCast(rect.w),
        .h = @floatCast(rect.h),
    };
    _ = c.SDL_RenderTexture(renderer, texture, null, &dst);
    renderProcessSelections(renderer, rect, model, interaction);
}

pub fn renderGalleryTexture(
    renderer: *c.SDL_Renderer,
    cache: *GalleryTextureCache,
    transform: *GalleryViewTransform,
    model: *v600.native_ui.State,
    allocator: std.mem.Allocator,
) void {
    const texture = cache.textureFor(renderer, allocator, model) catch |err| {
        setGalleryUiError(model, err);
        return;
    } orelse return;
    const out = chrome.renderLogicalSize(renderer) orelse return;
    const key = cache.key orelse return;
    const area = chrome.canvasArea(out.w, out.h);
    transform.ensureFitIn(allocator, key, area.x, area.y, area.w, area.h, cache.width, cache.height) catch |err| {
        setGalleryUiError(model, err);
        return;
    };
    const dst = transform.destination(cache.width, cache.height);
    _ = c.SDL_RenderTexture(renderer, texture, null, &dst);
}

pub fn galleryImageRgb8(allocator: std.mem.Allocator, image: v600.tiff.Image) ![]u8 {
    const pixels = try std.math.mul(usize, image.width, image.height);
    const samples = try std.math.mul(usize, pixels, 3);
    const out = try allocator.alloc(u8, samples);
    errdefer allocator.free(out);

    if (image.samples_per_pixel == 3 and image.bits_per_sample == 8) {
        @memcpy(out, image.data[0..samples]);
        return out;
    }
    if (image.samples_per_pixel == 3 and image.bits_per_sample == 16) {
        for (0..samples) |sample| {
            out[sample] = image.data[sample * 2 + 1];
        }
        return out;
    }
    if (image.samples_per_pixel == 1 and image.bits_per_sample == 8) {
        for (0..pixels) |pixel| {
            const value = image.data[pixel];
            out[pixel * 3 + 0] = value;
            out[pixel * 3 + 1] = value;
            out[pixel * 3 + 2] = value;
        }
        return out;
    }
    if (image.samples_per_pixel == 1 and image.bits_per_sample == 16) {
        for (0..pixels) |pixel| {
            const value = image.data[pixel * 2 + 1];
            out[pixel * 3 + 0] = value;
            out[pixel * 3 + 1] = value;
            out[pixel * 3 + 2] = value;
        }
        return out;
    }
    return error.UnsupportedGalleryImage;
}

pub fn renderSelectionOverlay(
    renderer: *c.SDL_Renderer,
    image_rect: v600.native_ui.PreviewScreenRect,
    selection: ?v600.native_ui.PreviewSelection,
) void {
    const sel = selection orelse return;
    if (!sel.isDrawable()) return;
    const x = image_rect.x + sel.x * image_rect.scale;
    const y = image_rect.y + sel.y * image_rect.scale;
    const w = sel.w * image_rect.scale;
    const h = sel.h * image_rect.scale;
    if (w <= 0.0 or h <= 0.0) return;

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 128);
    const dim_rects = [_]c.SDL_FRect{
        .{ .x = @floatCast(image_rect.x), .y = @floatCast(image_rect.y), .w = @floatCast(image_rect.w), .h = @floatCast(y - image_rect.y) },
        .{ .x = @floatCast(image_rect.x), .y = @floatCast(y), .w = @floatCast(x - image_rect.x), .h = @floatCast(h) },
        .{ .x = @floatCast(x + w), .y = @floatCast(y), .w = @floatCast((image_rect.x + image_rect.w) - (x + w)), .h = @floatCast(h) },
        .{ .x = @floatCast(image_rect.x), .y = @floatCast(y + h), .w = @floatCast(image_rect.w), .h = @floatCast((image_rect.y + image_rect.h) - (y + h)) },
    };
    _ = c.SDL_RenderFillRects(renderer, &dim_rects, @intCast(dim_rects.len));

    _ = c.SDL_SetRenderDrawColor(renderer, 34, 221, 102, 255);
    const border = c.SDL_FRect{ .x = @floatCast(x), .y = @floatCast(y), .w = @floatCast(w), .h = @floatCast(h) };
    _ = c.SDL_RenderRect(renderer, &border);
    renderSelectionHandles(renderer, x, y, w, h);
}

pub fn renderProcessSelections(
    renderer: *c.SDL_Renderer,
    image_rect: v600.native_ui.PreviewScreenRect,
    model: *const v600.native_ui.State,
    interaction: *const ProcessSelectionInteraction,
) void {
    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
    for (model.process_selections[0..model.process_selection_count], 0..) |selection, index| {
        const active = if (model.process_active_selection) |active_index| active_index == index else index == 0;
        const color = if (active)
            sdlColor(34, 221, 102, 255)
        else
            sdlColor(34, 160, 221, 220);
        renderProcessSelectionRect(renderer, image_rect, selection, active, color, 0.08);
        if (active) {
            var label_buffer: [48]u8 = undefined;
            const scale = @max(model.processing.preview_scale, 0.000001);
            const label = std.fmt.bufPrintZ(&label_buffer, "#{d}: {d}x{d}", .{
                index + 1,
                @as(i64, @intFromFloat(@round(selection.w / scale))),
                @as(i64, @intFromFloat(@round(selection.h / scale))),
            }) catch continue;
            renderSelectionLabel(renderer, image_rect, selection, label, color);
        }
    }
    if (model.process_rebate_rect) |rebate| {
        const color = sdlColor(255, 184, 77, 255);
        renderProcessSelectionRect(renderer, image_rect, rebate, interaction.rebate_active, color, 0.15);
        renderSelectionLabel(renderer, image_rect, rebate, "rebate (Dmin)", color);
    }
}

/// Draws a label centered over a (possibly rotated) selection, above its
/// topmost corner and clear of its handles, or below it when there is no room.
fn renderSelectionLabel(
    renderer: *c.SDL_Renderer,
    image_rect: v600.native_ui.PreviewScreenRect,
    selection: v600.native_ui.ProcessSelection,
    label: [:0]const u8,
    color: c.SDL_FColor,
) void {
    const corners = processSelectionScreenCorners(image_rect, selection);
    var top = corners[0].y;
    var bottom = corners[0].y;
    var center_x: f64 = 0.0;
    for (corners) |corner| {
        top = @min(top, corner.y);
        bottom = @max(bottom, corner.y);
        center_x += corner.x / @as(f64, @floatFromInt(corners.len));
    }
    const margin = 28.0;
    const y = if (top - margin >= 0.0) top - margin else bottom + margin / 2.0;
    renderCanvasLabel(renderer, label, center_x, y, color, true);
}

fn renderCanvasLabel(renderer: *c.SDL_Renderer, text: [:0]const u8, x: f64, y: f64, color: c.SDL_FColor, centered: bool) void {
    const text_scale = @max(1.0, @round(chrome.runtime_ui_config.metrics().scale * 1.5));
    const width = @as(f64, @floatFromInt(text.len)) * c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * text_scale;
    const left = if (centered) x - width / 2.0 else x;
    var base_x: f32 = 1.0;
    var base_y: f32 = 1.0;
    _ = c.SDL_GetRenderScale(renderer, &base_x, &base_y);
    _ = c.SDL_SetRenderScale(renderer, base_x * text_scale, base_y * text_scale);
    defer _ = c.SDL_SetRenderScale(renderer, base_x, base_y);
    _ = c.SDL_SetRenderDrawColorFloat(renderer, color.r, color.g, color.b, color.a);
    _ = c.SDL_RenderDebugText(renderer, @floatCast(left / text_scale), @floatCast(y / text_scale), text.ptr);
}

pub fn renderProcessSelectionRect(
    renderer: *c.SDL_Renderer,
    image_rect: v600.native_ui.PreviewScreenRect,
    selection: v600.native_ui.ProcessSelection,
    show_handles: bool,
    color: c.SDL_FColor,
    fill_alpha: f32,
) void {
    if (selection.w <= 0.0 or selection.h <= 0.0) return;
    const corners = processSelectionScreenCorners(image_rect, selection);
    var fill = color;
    fill.a = fill_alpha;
    const fill_vertices = [_]c.SDL_Vertex{
        sdlVertex(corners[0].x, corners[0].y, fill),
        sdlVertex(corners[1].x, corners[1].y, fill),
        sdlVertex(corners[2].x, corners[2].y, fill),
        sdlVertex(corners[3].x, corners[3].y, fill),
    };
    const fill_indices = [_]c_int{ 0, 1, 2, 0, 2, 3 };
    _ = c.SDL_RenderGeometry(renderer, null, &fill_vertices, fill_vertices.len, &fill_indices, fill_indices.len);
    for (0..corners.len) |index| {
        const next = (index + 1) % corners.len;
        renderAntialiasedLine(
            renderer,
            corners[index].x,
            corners[index].y,
            corners[next].x,
            corners[next].y,
            process_selection_line_width,
            process_selection_antialias_width,
            color,
        );
    }
    _ = c.SDL_SetRenderDrawColor(
        renderer,
        @intFromFloat(@round(color.r * 255.0)),
        @intFromFloat(@round(color.g * 255.0)),
        @intFromFloat(@round(color.b * 255.0)),
        @intFromFloat(@round(color.a * 255.0)),
    );
    if (show_handles) renderProcessSelectionHandles(renderer, image_rect, selection);
}

pub fn renderAntialiasedLine(
    renderer: *c.SDL_Renderer,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    width: f32,
    aa_width: f32,
    color: c.SDL_FColor,
) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= 0.000001) return;

    const nx = -dy / len;
    const ny = dx / len;
    const half = @max(@as(f64, @floatCast(width)) * 0.5, 0.5);
    const aa = @max(@as(f64, @floatCast(aa_width)), 0.0);
    renderLineQuad(renderer, x0, y0, x1, y1, nx, ny, -half, half, color, color);
    if (aa > 0.0) {
        var transparent = color;
        transparent.a = 0.0;
        renderLineQuad(renderer, x0, y0, x1, y1, nx, ny, half, half + aa, color, transparent);
        renderLineQuad(renderer, x0, y0, x1, y1, nx, ny, -half - aa, -half, transparent, color);
    }
}

pub fn renderLineQuad(
    renderer: *c.SDL_Renderer,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    nx: f64,
    ny: f64,
    offset_a: f64,
    offset_b: f64,
    color_a: c.SDL_FColor,
    color_b: c.SDL_FColor,
) void {
    const vertices = [_]c.SDL_Vertex{
        sdlVertex(x0 + nx * offset_a, y0 + ny * offset_a, color_a),
        sdlVertex(x1 + nx * offset_a, y1 + ny * offset_a, color_a),
        sdlVertex(x1 + nx * offset_b, y1 + ny * offset_b, color_b),
        sdlVertex(x0 + nx * offset_b, y0 + ny * offset_b, color_b),
    };
    const indices = [_]c_int{ 0, 1, 2, 0, 2, 3 };
    _ = c.SDL_RenderGeometry(renderer, null, &vertices, @intCast(vertices.len), &indices, @intCast(indices.len));
}

pub fn sdlVertex(x: f64, y: f64, color: c.SDL_FColor) c.SDL_Vertex {
    return .{
        .position = .{ .x = @floatCast(x), .y = @floatCast(y) },
        .color = color,
        .tex_coord = .{ .x = 0.0, .y = 0.0 },
    };
}

pub fn sdlColor(r: u8, g: u8, b: u8, a: u8) c.SDL_FColor {
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = @as(f32, @floatFromInt(a)) / 255.0,
    };
}

pub fn renderSelectionHandles(renderer: *c.SDL_Renderer, x: f64, y: f64, w: f64, h: f64) void {
    const handle_size = 8.0;
    const half = handle_size / 2.0;
    const mx = x + w / 2.0;
    const my = y + h / 2.0;
    const points = [_][2]f64{
        .{ x, y },      .{ mx, y },        .{ x + w, y },
        .{ x + w, my }, .{ x + w, y + h }, .{ mx, y + h },
        .{ x, y + h },  .{ x, my },
    };
    var rects: [points.len]c.SDL_FRect = undefined;
    for (points, 0..) |point, i| {
        rects[i] = .{
            .x = @floatCast(point[0] - half),
            .y = @floatCast(point[1] - half),
            .w = @floatCast(handle_size),
            .h = @floatCast(handle_size),
        };
    }
    _ = c.SDL_RenderFillRects(renderer, &rects, @intCast(rects.len));
}

pub fn processSelectionScreenCorners(
    image_rect: v600.native_ui.PreviewScreenRect,
    selection: v600.native_ui.ProcessSelection,
) [4]ProcessScreenPoint {
    const half_w = selection.w / 2.0;
    const half_h = selection.h / 2.0;
    return .{
        selectionLocalToScreen(image_rect, selection, -half_w, -half_h),
        selectionLocalToScreen(image_rect, selection, half_w, -half_h),
        selectionLocalToScreen(image_rect, selection, half_w, half_h),
        selectionLocalToScreen(image_rect, selection, -half_w, half_h),
    };
}

pub fn renderProcessSelectionHandles(
    renderer: *c.SDL_Renderer,
    image_rect: v600.native_ui.PreviewScreenRect,
    selection: v600.native_ui.ProcessSelection,
) void {
    const handle_size = 8.0;
    const half_handle = handle_size / 2.0;
    const half_w = selection.w / 2.0;
    const half_h = selection.h / 2.0;
    const resize_points = [_]ProcessScreenPoint{
        selectionLocalToScreen(image_rect, selection, -half_w, -half_h),
        selectionLocalToScreen(image_rect, selection, 0.0, -half_h),
        selectionLocalToScreen(image_rect, selection, half_w, -half_h),
        selectionLocalToScreen(image_rect, selection, half_w, 0.0),
        selectionLocalToScreen(image_rect, selection, half_w, half_h),
        selectionLocalToScreen(image_rect, selection, 0.0, half_h),
        selectionLocalToScreen(image_rect, selection, -half_w, half_h),
        selectionLocalToScreen(image_rect, selection, -half_w, 0.0),
    };
    var rects: [resize_points.len]c.SDL_FRect = undefined;
    for (resize_points, 0..) |point, i| {
        rects[i] = .{
            .x = @floatCast(point.x - half_handle),
            .y = @floatCast(point.y - half_handle),
            .w = @floatCast(handle_size),
            .h = @floatCast(handle_size),
        };
    }
    _ = c.SDL_RenderFillRects(renderer, &rects, @intCast(rects.len));

    const offset = processRotationHandleOffsetPreview(image_rect);
    const rotate_points = [_]struct {
        base_x: f64,
        base_y: f64,
        handle_x: f64,
        handle_y: f64,
    }{
        .{ .base_x = 0.0, .base_y = -half_h, .handle_x = 0.0, .handle_y = -half_h - offset },
        .{ .base_x = 0.0, .base_y = half_h, .handle_x = 0.0, .handle_y = half_h + offset },
        .{ .base_x = -half_w, .base_y = 0.0, .handle_x = -half_w - offset, .handle_y = 0.0 },
        .{ .base_x = half_w, .base_y = 0.0, .handle_x = half_w + offset, .handle_y = 0.0 },
    };
    for (rotate_points) |points| {
        const base = selectionLocalToScreen(image_rect, selection, points.base_x, points.base_y);
        const handle = selectionLocalToScreen(image_rect, selection, points.handle_x, points.handle_y);
        _ = c.SDL_RenderLine(
            renderer,
            @floatCast(base.x),
            @floatCast(base.y),
            @floatCast(handle.x),
            @floatCast(handle.y),
        );
        const rotate_rect = c.SDL_FRect{
            .x = @floatCast(handle.x - 5.0),
            .y = @floatCast(handle.y - 5.0),
            .w = 10.0,
            .h = 10.0,
        };
        _ = c.SDL_RenderRect(renderer, &rotate_rect);
    }
}

pub fn containsGalleryName(files: []const []const u8, name: []const u8) bool {
    for (files) |file| {
        if (std.mem.eql(u8, file, name)) return true;
    }
    return false;
}

pub fn setGalleryUiError(model: *v600.native_ui.State, err: anyerror) void {
    model.setStatus(switch (err) {
        error.NoGalleryFileSelected => "No exports found",
        error.FileNotFound => "File not found",
        error.AccessDenied => "Access denied",
        error.InvalidGalleryImageIndex => "Invalid index",
        else => @errorName(err),
    });
}
