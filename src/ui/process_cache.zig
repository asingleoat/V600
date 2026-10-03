const std = @import("std");

const app_state = @import("../app_state.zig");
const processing_config = @import("../processing/config.zig");
const processing_export = @import("../processing/export.zig");
const processing_frames = @import("../processing/frames.zig");
const processing_render = @import("../processing/render.zig");
const processing_webgpu = @import("../processing/webgpu.zig");
const processing_workflow = @import("../processing/workflow.zig");
const tiff = @import("../tiff.zig");

pub const schema_version: u32 = 1;

pub const Operation = enum(u8) {
    rgb_page,
    quick_preview,
    auto_detect,
    rebate_dmin,
    inverted_preview,
    export_outputs,
};

pub const ImageIdentityInput = struct {
    path: []const u8,
    size_bytes: ?u64 = null,
    mtime_ns: ?i64 = null,
};

pub const ImageIdentity = struct {
    path: []u8,
    size_bytes: ?u64 = null,
    mtime_ns: ?i64 = null,

    pub fn init(allocator: std.mem.Allocator, input: ImageIdentityInput) !ImageIdentity {
        return .{
            .path = try allocator.dupe(u8, input.path),
            .size_bytes = input.size_bytes,
            .mtime_ns = input.mtime_ns,
        };
    }

    pub fn deinit(self: *ImageIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.path = &.{};
    }

    pub fn clone(self: ImageIdentity, allocator: std.mem.Allocator) !ImageIdentity {
        return init(allocator, .{
            .path = self.path,
            .size_bytes = self.size_bytes,
            .mtime_ns = self.mtime_ns,
        });
    }

    pub fn eql(self: ImageIdentity, other: ImageIdentity) bool {
        return std.mem.eql(u8, self.path, other.path) and
            optionalU64Equal(self.size_bytes, other.size_bytes) and
            optionalI64Equal(self.mtime_ns, other.mtime_ns);
    }
};

pub const KeyInput = struct {
    operation: Operation,
    image: ImageIdentityInput,
    config_state: []const u8 = &.{},
    operation_state: []const u8 = &.{},
};

pub const Key = struct {
    operation: Operation,
    image: ImageIdentity,
    fingerprint: u128,

    pub fn init(allocator: std.mem.Allocator, input: KeyInput) !Key {
        var image = try ImageIdentity.init(allocator, input.image);
        errdefer image.deinit(allocator);
        return .{
            .operation = input.operation,
            .image = image,
            .fingerprint = fingerprintKeyInput(input),
        };
    }

    pub fn deinit(self: *Key, allocator: std.mem.Allocator) void {
        self.image.deinit(allocator);
        self.fingerprint = 0;
    }

    pub fn clone(self: Key, allocator: std.mem.Allocator) !Key {
        return .{
            .operation = self.operation,
            .image = try self.image.clone(allocator),
            .fingerprint = self.fingerprint,
        };
    }

    pub fn eql(self: Key, other: Key) bool {
        return self.operation == other.operation and
            self.fingerprint == other.fingerprint;
    }

    pub fn hash(self: Key) u128 {
        return self.fingerprint;
    }
};

pub const ByteEntry = struct {
    key: Key,
    payload: []u8,

    fn deinit(self: *ByteEntry, allocator: std.mem.Allocator) void {
        self.key.deinit(allocator);
        allocator.free(self.payload);
        self.payload = &.{};
    }
};

pub const ByteResultCache = struct {
    entries: std.array_list.Managed(ByteEntry),

    pub fn init(allocator: std.mem.Allocator) ByteResultCache {
        return .{ .entries = std.array_list.Managed(ByteEntry).init(allocator) };
    }

    pub fn deinit(self: *ByteResultCache) void {
        const allocator = self.entries.allocator;
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit();
    }

    pub fn clear(self: *ByteResultCache) void {
        const allocator = self.entries.allocator;
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.clearRetainingCapacity();
    }

    pub fn get(self: *const ByteResultCache, key: Key) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (entry.key.eql(key)) return entry.payload;
        }
        return null;
    }

    pub fn put(self: *ByteResultCache, key: Key, payload: []const u8) !void {
        const allocator = self.entries.allocator;
        for (self.entries.items) |*entry| {
            if (!entry.key.eql(key)) continue;
            const owned_payload = try allocator.dupe(u8, payload);
            allocator.free(entry.payload);
            entry.payload = owned_payload;
            return;
        }

        var owned_key = try key.clone(allocator);
        errdefer owned_key.deinit(allocator);
        const owned_payload = try allocator.dupe(u8, payload);
        errdefer allocator.free(owned_payload);
        try self.entries.append(.{ .key = owned_key, .payload = owned_payload });
    }
};

pub const quick_preview_cache_capacity: usize = 4;
pub const rgb_page_cache_capacity: usize = 2;
pub const dmin_cache_capacity: usize = 16;
pub const auto_detect_cache_capacity: usize = 8;
pub const inverted_preview_cache_capacity: usize = 4;
pub const default_rgb_page_cache_budget_bytes: usize = 1024 * 1024 * 1024;

pub const QuickPreviewEntry = struct {
    key: Key,
    preview: processing_workflow.QuickPreview,

    fn deinit(self: *QuickPreviewEntry, allocator: std.mem.Allocator) void {
        self.key.deinit(allocator);
        self.preview.deinit(allocator);
    }
};

pub const QuickPreviewCache = struct {
    entries: [quick_preview_cache_capacity]?QuickPreviewEntry = [_]?QuickPreviewEntry{null} ** quick_preview_cache_capacity,
    next_slot: usize = 0,

    pub fn deinit(self: *QuickPreviewCache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }

    pub fn clear(self: *QuickPreviewCache, allocator: std.mem.Allocator) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*present| {
                present.deinit(allocator);
                entry.* = null;
            }
        }
        self.next_slot = 0;
    }

    pub fn getClone(
        self: *const QuickPreviewCache,
        allocator: std.mem.Allocator,
        key: Key,
    ) !?processing_workflow.QuickPreview {
        for (&self.entries) |*entry| {
            if (entry.*) |present| {
                if (present.key.eql(key)) return try cloneQuickPreview(allocator, present.preview);
            }
        }
        return null;
    }

    pub fn putClone(
        self: *QuickPreviewCache,
        allocator: std.mem.Allocator,
        key: Key,
        preview: processing_workflow.QuickPreview,
    ) !void {
        var owned_key = try key.clone(allocator);
        errdefer owned_key.deinit(allocator);
        var owned_preview = try cloneQuickPreview(allocator, preview);
        errdefer owned_preview.deinit(allocator);

        for (&self.entries) |*entry| {
            if (entry.*) |*present| {
                if (!present.key.eql(key)) continue;
                present.deinit(allocator);
                entry.* = .{ .key = owned_key, .preview = owned_preview };
                return;
            }
        }

        const slot = self.next_slot % self.entries.len;
        if (self.entries[slot]) |*present| present.deinit(allocator);
        self.entries[slot] = .{ .key = owned_key, .preview = owned_preview };
        self.next_slot = (slot + 1) % self.entries.len;
    }
};

pub const RgbPageEntry = struct {
    key: Key,
    page: tiff.RgbPageWithMetadata,
    bytes: usize,
    last_used: u64,

    fn deinit(self: *RgbPageEntry, allocator: std.mem.Allocator) void {
        self.key.deinit(allocator);
        self.page.deinit(allocator);
        self.bytes = 0;
        self.last_used = 0;
    }
};

pub const RgbPageCache = struct {
    entries: [rgb_page_cache_capacity]?RgbPageEntry = [_]?RgbPageEntry{null} ** rgb_page_cache_capacity,
    memory_budget_bytes: usize = default_rgb_page_cache_budget_bytes,
    resident_bytes: usize = 0,
    access_counter: u64 = 0,

    pub fn deinit(self: *RgbPageCache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }

    pub fn clear(self: *RgbPageCache, allocator: std.mem.Allocator) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*present| {
                present.deinit(allocator);
                entry.* = null;
            }
        }
        self.resident_bytes = 0;
        self.access_counter = 0;
    }

    pub fn setMemoryBudget(self: *RgbPageCache, allocator: std.mem.Allocator, bytes: usize) void {
        self.memory_budget_bytes = bytes;
        while (self.resident_bytes > self.memory_budget_bytes) {
            if (!self.evictLeastRecent(allocator)) break;
        }
    }

    pub fn getClone(
        self: *RgbPageCache,
        allocator: std.mem.Allocator,
        key: Key,
    ) !?tiff.RgbPageWithMetadata {
        for (&self.entries) |*entry| {
            if (entry.*) |*present| {
                if (!present.key.eql(key)) continue;
                present.last_used = self.nextAccess();
                return try cloneRgbPageWithMetadata(allocator, present.page);
            }
        }
        return null;
    }

    pub fn putClone(
        self: *RgbPageCache,
        allocator: std.mem.Allocator,
        key: Key,
        page: tiff.RgbPageWithMetadata,
    ) !bool {
        var owned_page = try cloneRgbPageWithMetadata(allocator, page);
        errdefer owned_page.deinit(allocator);
        return try self.putOwned(allocator, key, &owned_page);
    }

    pub fn putOwned(
        self: *RgbPageCache,
        allocator: std.mem.Allocator,
        key: Key,
        page: *tiff.RgbPageWithMetadata,
    ) !bool {
        const bytes = page.rgb.data.len;
        if (bytes > self.memory_budget_bytes) return false;

        var owned_key = try key.clone(allocator);
        errdefer owned_key.deinit(allocator);

        if (self.findEntry(key)) |index| {
            if (self.entries[index]) |*present| {
                self.resident_bytes -= present.bytes;
                present.deinit(allocator);
            }
            self.entries[index] = null;
        }

        while (self.resident_bytes + bytes > self.memory_budget_bytes) {
            if (!self.evictLeastRecent(allocator)) return false;
        }

        const slot = self.emptySlot() orelse blk: {
            if (!self.evictLeastRecent(allocator)) return false;
            break :blk self.emptySlot() orelse return false;
        };

        self.entries[slot] = .{
            .key = owned_key,
            .page = page.*,
            .bytes = bytes,
            .last_used = self.nextAccess(),
        };
        page.* = undefined;
        self.resident_bytes += bytes;
        return true;
    }

    fn findEntry(self: *const RgbPageCache, key: Key) ?usize {
        for (&self.entries, 0..) |*entry, index| {
            if (entry.*) |present| {
                if (present.key.eql(key)) return index;
            }
        }
        return null;
    }

    fn emptySlot(self: *const RgbPageCache) ?usize {
        for (&self.entries, 0..) |*entry, index| {
            if (entry.* == null) return index;
        }
        return null;
    }

    fn evictLeastRecent(self: *RgbPageCache, allocator: std.mem.Allocator) bool {
        var candidate: ?usize = null;
        var oldest: u64 = 0;
        for (&self.entries, 0..) |*entry, index| {
            if (entry.*) |present| {
                if (candidate == null or present.last_used < oldest) {
                    candidate = index;
                    oldest = present.last_used;
                }
            }
        }
        const index = candidate orelse return false;
        if (self.entries[index]) |*present| {
            self.resident_bytes -= present.bytes;
            present.deinit(allocator);
        }
        self.entries[index] = null;
        return true;
    }

    fn nextAccess(self: *RgbPageCache) u64 {
        self.access_counter +%= 1;
        return self.access_counter;
    }
};

pub const DminEntry = struct {
    key: Key,
    dmin: [3]f64,
    last_used: u64,

    fn deinit(self: *DminEntry, allocator: std.mem.Allocator) void {
        self.key.deinit(allocator);
        self.last_used = 0;
    }
};

pub const DminCache = struct {
    entries: [dmin_cache_capacity]?DminEntry = [_]?DminEntry{null} ** dmin_cache_capacity,
    access_counter: u64 = 0,

    pub fn deinit(self: *DminCache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }

    pub fn clear(self: *DminCache, allocator: std.mem.Allocator) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*present| {
                present.deinit(allocator);
                entry.* = null;
            }
        }
        self.access_counter = 0;
    }

    pub fn get(self: *DminCache, key: Key) ?[3]f64 {
        for (&self.entries) |*entry| {
            if (entry.*) |*present| {
                if (!present.key.eql(key)) continue;
                present.last_used = self.nextAccess();
                return present.dmin;
            }
        }
        return null;
    }

    pub fn put(self: *DminCache, allocator: std.mem.Allocator, key: Key, dmin: [3]f64) !void {
        var owned_key = try key.clone(allocator);
        errdefer owned_key.deinit(allocator);
        if (self.findEntry(key)) |index| {
            if (self.entries[index]) |*present| present.deinit(allocator);
            self.entries[index] = .{ .key = owned_key, .dmin = dmin, .last_used = self.nextAccess() };
            return;
        }
        const slot = self.emptySlot() orelse blk: {
            _ = self.evictLeastRecent(allocator);
            break :blk self.emptySlot() orelse return error.ProcessDminCacheFull;
        };
        self.entries[slot] = .{ .key = owned_key, .dmin = dmin, .last_used = self.nextAccess() };
    }

    fn findEntry(self: *const DminCache, key: Key) ?usize {
        for (&self.entries, 0..) |*entry, index| {
            if (entry.*) |present| {
                if (present.key.eql(key)) return index;
            }
        }
        return null;
    }

    fn emptySlot(self: *const DminCache) ?usize {
        for (&self.entries, 0..) |*entry, index| {
            if (entry.* == null) return index;
        }
        return null;
    }

    fn evictLeastRecent(self: *DminCache, allocator: std.mem.Allocator) bool {
        var candidate: ?usize = null;
        var oldest: u64 = 0;
        for (&self.entries, 0..) |*entry, index| {
            if (entry.*) |present| {
                if (candidate == null or present.last_used < oldest) {
                    candidate = index;
                    oldest = present.last_used;
                }
            }
        }
        const index = candidate orelse return false;
        if (self.entries[index]) |*present| present.deinit(allocator);
        self.entries[index] = null;
        return true;
    }

    fn nextAccess(self: *DminCache) u64 {
        self.access_counter +%= 1;
        return self.access_counter;
    }
};

pub const AutoDetectCachedResult = struct {
    result: processing_workflow.AutoDetectResult,
    full_rebate: ?app_state.RebateRect = null,
    dmin: ?[3]f64 = null,

    pub fn deinit(self: *AutoDetectCachedResult, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.full_rebate = null;
        self.dmin = null;
    }
};

pub const AutoDetectEntry = struct {
    key: Key,
    cached: AutoDetectCachedResult,
    last_used: u64,

    fn deinit(self: *AutoDetectEntry, allocator: std.mem.Allocator) void {
        self.key.deinit(allocator);
        self.cached.deinit(allocator);
        self.last_used = 0;
    }
};

pub const AutoDetectCache = struct {
    entries: [auto_detect_cache_capacity]?AutoDetectEntry = [_]?AutoDetectEntry{null} ** auto_detect_cache_capacity,
    access_counter: u64 = 0,

    pub fn deinit(self: *AutoDetectCache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }

    pub fn clear(self: *AutoDetectCache, allocator: std.mem.Allocator) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*present| {
                present.deinit(allocator);
                entry.* = null;
            }
        }
        self.access_counter = 0;
    }

    pub fn getClone(
        self: *AutoDetectCache,
        allocator: std.mem.Allocator,
        key: Key,
    ) !?AutoDetectCachedResult {
        for (&self.entries) |*entry| {
            if (entry.*) |*present| {
                if (!present.key.eql(key)) continue;
                present.last_used = self.nextAccess();
                return try cloneAutoDetectCachedResult(allocator, present.cached);
            }
        }
        return null;
    }

    pub fn putClone(
        self: *AutoDetectCache,
        allocator: std.mem.Allocator,
        key: Key,
        cached: AutoDetectCachedResult,
    ) !void {
        var owned_key = try key.clone(allocator);
        errdefer owned_key.deinit(allocator);
        var owned_cached = try cloneAutoDetectCachedResult(allocator, cached);
        errdefer owned_cached.deinit(allocator);
        if (self.findEntry(key)) |index| {
            if (self.entries[index]) |*present| present.deinit(allocator);
            self.entries[index] = .{ .key = owned_key, .cached = owned_cached, .last_used = self.nextAccess() };
            return;
        }
        const slot = self.emptySlot() orelse blk: {
            _ = self.evictLeastRecent(allocator);
            break :blk self.emptySlot() orelse return error.ProcessAutoDetectCacheFull;
        };
        self.entries[slot] = .{ .key = owned_key, .cached = owned_cached, .last_used = self.nextAccess() };
    }

    fn findEntry(self: *const AutoDetectCache, key: Key) ?usize {
        for (&self.entries, 0..) |*entry, index| {
            if (entry.*) |present| {
                if (present.key.eql(key)) return index;
            }
        }
        return null;
    }

    fn emptySlot(self: *const AutoDetectCache) ?usize {
        for (&self.entries, 0..) |*entry, index| {
            if (entry.* == null) return index;
        }
        return null;
    }

    fn evictLeastRecent(self: *AutoDetectCache, allocator: std.mem.Allocator) bool {
        var candidate: ?usize = null;
        var oldest: u64 = 0;
        for (&self.entries, 0..) |*entry, index| {
            if (entry.*) |present| {
                if (candidate == null or present.last_used < oldest) {
                    candidate = index;
                    oldest = present.last_used;
                }
            }
        }
        const index = candidate orelse return false;
        if (self.entries[index]) |*present| present.deinit(allocator);
        self.entries[index] = null;
        return true;
    }

    fn nextAccess(self: *AutoDetectCache) u64 {
        self.access_counter +%= 1;
        return self.access_counter;
    }
};

pub const InvertedPreviewEntry = struct {
    key: Key,
    rgb8: []u8,
    last_used: u64,

    fn deinit(self: *InvertedPreviewEntry, allocator: std.mem.Allocator) void {
        self.key.deinit(allocator);
        allocator.free(self.rgb8);
        self.rgb8 = &.{};
        self.last_used = 0;
    }
};

pub const InvertedPreviewCache = struct {
    entries: [inverted_preview_cache_capacity]?InvertedPreviewEntry = [_]?InvertedPreviewEntry{null} ** inverted_preview_cache_capacity,
    access_counter: u64 = 0,

    pub fn deinit(self: *InvertedPreviewCache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }

    pub fn clear(self: *InvertedPreviewCache, allocator: std.mem.Allocator) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*present| {
                present.deinit(allocator);
                entry.* = null;
            }
        }
        self.access_counter = 0;
    }

    pub fn getClone(
        self: *InvertedPreviewCache,
        allocator: std.mem.Allocator,
        key: Key,
    ) !?[]u8 {
        for (&self.entries) |*entry| {
            if (entry.*) |*present| {
                if (!present.key.eql(key)) continue;
                present.last_used = self.nextAccess();
                return try allocator.dupe(u8, present.rgb8);
            }
        }
        return null;
    }

    pub fn putClone(
        self: *InvertedPreviewCache,
        allocator: std.mem.Allocator,
        key: Key,
        rgb8: []const u8,
    ) !void {
        var owned_key = try key.clone(allocator);
        errdefer owned_key.deinit(allocator);
        const owned_rgb8 = try allocator.dupe(u8, rgb8);
        errdefer allocator.free(owned_rgb8);
        if (self.findEntry(key)) |index| {
            if (self.entries[index]) |*present| present.deinit(allocator);
            self.entries[index] = .{ .key = owned_key, .rgb8 = owned_rgb8, .last_used = self.nextAccess() };
            return;
        }
        const slot = self.emptySlot() orelse blk: {
            _ = self.evictLeastRecent(allocator);
            break :blk self.emptySlot() orelse return error.ProcessInvertedPreviewCacheFull;
        };
        self.entries[slot] = .{ .key = owned_key, .rgb8 = owned_rgb8, .last_used = self.nextAccess() };
    }

    fn findEntry(self: *const InvertedPreviewCache, key: Key) ?usize {
        for (&self.entries, 0..) |*entry, index| {
            if (entry.*) |present| {
                if (present.key.eql(key)) return index;
            }
        }
        return null;
    }

    fn emptySlot(self: *const InvertedPreviewCache) ?usize {
        for (&self.entries, 0..) |*entry, index| {
            if (entry.* == null) return index;
        }
        return null;
    }

    fn evictLeastRecent(self: *InvertedPreviewCache, allocator: std.mem.Allocator) bool {
        var candidate: ?usize = null;
        var oldest: u64 = 0;
        for (&self.entries, 0..) |*entry, index| {
            if (entry.*) |present| {
                if (candidate == null or present.last_used < oldest) {
                    candidate = index;
                    oldest = present.last_used;
                }
            }
        }
        const index = candidate orelse return false;
        if (self.entries[index]) |*present| present.deinit(allocator);
        self.entries[index] = null;
        return true;
    }

    fn nextAccess(self: *InvertedPreviewCache) u64 {
        self.access_counter +%= 1;
        return self.access_counter;
    }
};

pub const ProcessResultCache = struct {
    quick_previews: QuickPreviewCache = .{},
    rgb_pages: RgbPageCache = .{},
    dmins: DminCache = .{},
    auto_detects: AutoDetectCache = .{},
    inverted_previews: InvertedPreviewCache = .{},

    pub fn deinit(self: *ProcessResultCache, allocator: std.mem.Allocator) void {
        self.quick_previews.deinit(allocator);
        self.rgb_pages.deinit(allocator);
        self.dmins.deinit(allocator);
        self.auto_detects.deinit(allocator);
        self.inverted_previews.deinit(allocator);
    }

    pub fn clear(self: *ProcessResultCache, allocator: std.mem.Allocator) void {
        self.quick_previews.clear(allocator);
        self.rgb_pages.clear(allocator);
        self.dmins.clear(allocator);
        self.auto_detects.clear(allocator);
        self.inverted_previews.clear(allocator);
    }
};

pub fn cloneQuickPreview(
    allocator: std.mem.Allocator,
    preview: processing_workflow.QuickPreview,
) !processing_workflow.QuickPreview {
    const raw = try allocator.dupe(u16, preview.preview_raw);
    errdefer allocator.free(raw);
    const rgb8 = try allocator.dupe(u8, preview.preview_rgb8);
    errdefer allocator.free(rgb8);
    const jpeg = try allocator.dupe(u8, preview.jpeg);
    return .{
        .info = preview.info,
        .preview_width = preview.preview_width,
        .preview_height = preview.preview_height,
        .preview_raw = raw,
        .preview_rgb8 = rgb8,
        .jpeg = jpeg,
    };
}

pub fn imageIdentityFromFile(io: std.Io, path: []const u8) ImageIdentityInput {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        return .{ .path = path };
    };
    if (stat.kind != .file) return .{ .path = path };
    return .{
        .path = path,
        .size_bytes = stat.size,
        .mtime_ns = std.math.cast(i64, stat.mtime.nanoseconds),
    };
}

pub fn cloneRgbPageWithMetadata(
    allocator: std.mem.Allocator,
    page: tiff.RgbPageWithMetadata,
) !tiff.RgbPageWithMetadata {
    const data = try allocator.dupe(u8, page.rgb.data);
    return .{
        .rgb = .{
            .width = page.rgb.width,
            .height = page.rgb.height,
            .samples_per_pixel = page.rgb.samples_per_pixel,
            .bits_per_sample = page.rgb.bits_per_sample,
            .data = data,
        },
        .dpi = page.dpi,
        .ir = page.ir,
    };
}

pub fn cloneAutoDetectResult(
    allocator: std.mem.Allocator,
    result: processing_workflow.AutoDetectResult,
) !processing_workflow.AutoDetectResult {
    const frames = try allocator.dupe(processing_frames.FrameRect, result.frames);
    return .{
        .frames = frames,
        .aspect = result.aspect,
        .rebate = result.rebate,
    };
}

pub fn cloneAutoDetectCachedResult(
    allocator: std.mem.Allocator,
    cached: AutoDetectCachedResult,
) !AutoDetectCachedResult {
    var result = try cloneAutoDetectResult(allocator, cached.result);
    errdefer result.deinit(allocator);
    return .{
        .result = result,
        .full_rebate = cached.full_rebate,
        .dmin = cached.dmin,
    };
}

pub fn configStateBytes(
    allocator: std.mem.Allocator,
    loaded: *const processing_config.LoadedConfig,
) ![]u8 {
    var builder = StateBuilder.init(allocator);
    errdefer builder.deinit();

    try builder.tag("config");
    try builder.appendU32(schema_version);

    var entry_indices: [32]usize = undefined;
    const entries = sortedEntryIndices(loaded, &entry_indices);
    try builder.appendUsize(entries.len);
    for (entries) |index| {
        const entry = loaded.entries[index];
        try builder.appendString(entry.name.slice());
        try appendConfigValue(&builder, entry.value);
    }

    var stock_indices: [8]usize = undefined;
    const stocks = sortedStockIndices(loaded, &stock_indices);
    try builder.appendUsize(stocks.len);
    for (stocks) |index| {
        const stock = loaded.stocks[index];
        try builder.appendString(stock.name.slice());
        try builder.appendBool(stock.has_description);
        if (stock.has_description) try builder.appendString(stock.description.slice());
        try builder.appendBool(stock.has_coeffs);
        if (stock.has_coeffs) {
            for (stock.coeffs) |row| {
                for (row) |value| try builder.appendF64(value);
            }
        }
    }

    return builder.finish();
}

pub fn rgbPageStateBytes(allocator: std.mem.Allocator) ![]u8 {
    var builder = StateBuilder.init(allocator);
    errdefer builder.deinit();
    try builder.tag("rgb_page");
    return builder.finish();
}

pub fn rgbPageKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !Key {
    const operation_state = try rgbPageStateBytes(allocator);
    defer allocator.free(operation_state);
    return Key.init(allocator, .{
        .operation = .rgb_page,
        .image = imageIdentityFromFile(io, path),
        .operation_state = operation_state,
    });
}

pub fn quickPreviewStateBytes(
    allocator: std.mem.Allocator,
    preview_size: i64,
) ![]u8 {
    var builder = StateBuilder.init(allocator);
    errdefer builder.deinit();
    try builder.tag("quick_preview");
    try builder.appendI64(preview_size);
    return builder.finish();
}

pub const AutoDetectState = struct {
    options: processing_workflow.AutoDetectOptions = .{},
    scale_percent: f64 = 0.0,
    output_rotation: i32 = 270,
    preview_width: usize = 0,
    preview_height: usize = 0,
    preview_scale: f64 = 1.0,
};

pub fn autoDetectStateBytes(
    allocator: std.mem.Allocator,
    state: AutoDetectState,
) ![]u8 {
    var builder = StateBuilder.init(allocator);
    errdefer builder.deinit();
    try builder.tag("auto_detect");
    try builder.appendOptionalString(state.options.format);
    try builder.appendOptionalUsize(state.options.n_frames);
    try builder.appendBool(state.options.detect_film_extent);
    try builder.appendBool(state.options.apply_clahe);
    try builder.appendF64(state.scale_percent);
    try builder.appendI32(state.output_rotation);
    try builder.appendUsize(state.preview_width);
    try builder.appendUsize(state.preview_height);
    try builder.appendF64(state.preview_scale);
    return builder.finish();
}

pub fn autoDetectKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    loaded: *const processing_config.LoadedConfig,
    state: AutoDetectState,
) !Key {
    const config_state = try configStateBytes(allocator, loaded);
    defer allocator.free(config_state);
    const operation_state = try autoDetectStateBytes(allocator, state);
    defer allocator.free(operation_state);
    return Key.init(allocator, .{
        .operation = .auto_detect,
        .image = imageIdentityFromFile(io, path),
        .config_state = config_state,
        .operation_state = operation_state,
    });
}

pub fn rebateDminStateBytes(
    allocator: std.mem.Allocator,
    rect: app_state.RebateRect,
) ![]u8 {
    var builder = StateBuilder.init(allocator);
    errdefer builder.deinit();
    try builder.tag("rebate_dmin");
    try appendRebateRect(&builder, rect);
    return builder.finish();
}

pub fn rebateDminKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    loaded: *const processing_config.LoadedConfig,
    rect: app_state.RebateRect,
) !Key {
    const config_state = try configStateBytes(allocator, loaded);
    defer allocator.free(config_state);
    const operation_state = try rebateDminStateBytes(allocator, rect);
    defer allocator.free(operation_state);
    return Key.init(allocator, .{
        .operation = .rebate_dmin,
        .image = imageIdentityFromFile(io, path),
        .config_state = config_state,
        .operation_state = operation_state,
    });
}

pub const InvertedPreviewState = struct {
    stock: ?[]const u8 = null,
    dmin: ?[3]f64 = null,
    render_options: processing_render.RenderToDisplayOptions = .{},
    invert_request: processing_webgpu.Request = .{},
    preview_width: usize = 0,
    preview_height: usize = 0,
    preview_scale: f64 = 1.0,
};

pub fn invertedPreviewStateBytes(
    allocator: std.mem.Allocator,
    state: InvertedPreviewState,
) ![]u8 {
    var builder = StateBuilder.init(allocator);
    errdefer builder.deinit();
    try builder.tag("inverted_preview");
    try builder.appendOptionalString(state.stock);
    try builder.appendOptionalDmin(state.dmin);
    try appendRenderOptions(&builder, state.render_options);
    try appendGpuRequest(&builder, state.invert_request);
    try builder.appendUsize(state.preview_width);
    try builder.appendUsize(state.preview_height);
    try builder.appendF64(state.preview_scale);
    return builder.finish();
}

pub fn invertedPreviewKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    loaded: *const processing_config.LoadedConfig,
    state: InvertedPreviewState,
) !Key {
    const config_state = try configStateBytes(allocator, loaded);
    defer allocator.free(config_state);
    const operation_state = try invertedPreviewStateBytes(allocator, state);
    defer allocator.free(operation_state);
    return Key.init(allocator, .{
        .operation = .inverted_preview,
        .image = imageIdentityFromFile(io, path),
        .config_state = config_state,
        .operation_state = operation_state,
    });
}

pub const ExportState = struct {
    output_dir: []const u8,
    basename: []const u8,
    rects: []const processing_export.FrameRect,
    outputs: processing_export.OutputSelection = .{},
    active_stock: ?[]const u8 = null,
    dmin: ?[3]f64 = null,
    rebate_rect: ?processing_frames.RebateOriginRect = null,
    current_dpi: ?u32 = null,
    invert_request: processing_webgpu.Request = .{},
};

pub fn exportStateBytes(
    allocator: std.mem.Allocator,
    state: ExportState,
) ![]u8 {
    var builder = StateBuilder.init(allocator);
    errdefer builder.deinit();
    try builder.tag("export_outputs");
    try builder.appendString(state.output_dir);
    try builder.appendString(state.basename);
    try appendOutputSelection(&builder, state.outputs);
    try builder.appendOptionalString(state.active_stock);
    try builder.appendOptionalDmin(state.dmin);
    try builder.appendOptionalU32(state.current_dpi);
    try appendGpuRequest(&builder, state.invert_request);
    try builder.appendBool(state.rebate_rect != null);
    if (state.rebate_rect) |rect| try appendRebateOriginRect(&builder, rect);
    try builder.appendUsize(state.rects.len);
    for (state.rects) |rect| try appendFrameRect(&builder, rect);
    return builder.finish();
}

const StateBuilder = struct {
    out: std.array_list.Managed(u8),

    fn init(allocator: std.mem.Allocator) StateBuilder {
        return .{ .out = std.array_list.Managed(u8).init(allocator) };
    }

    fn deinit(self: *StateBuilder) void {
        self.out.deinit();
    }

    fn finish(self: *StateBuilder) ![]u8 {
        return self.out.toOwnedSlice();
    }

    fn tag(self: *StateBuilder, value: []const u8) !void {
        try self.appendString(value);
    }

    fn appendBool(self: *StateBuilder, value: bool) !void {
        try self.out.append(if (value) 1 else 0);
    }

    fn appendU8(self: *StateBuilder, value: u8) !void {
        try self.out.append(value);
    }

    fn appendU32(self: *StateBuilder, value: u32) !void {
        var buffer: [4]u8 = undefined;
        std.mem.writeInt(u32, &buffer, value, .little);
        try self.out.appendSlice(&buffer);
    }

    fn appendOptionalU32(self: *StateBuilder, value: ?u32) !void {
        try self.appendBool(value != null);
        if (value) |present| try self.appendU32(present);
    }

    fn appendU64(self: *StateBuilder, value: u64) !void {
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, &buffer, value, .little);
        try self.out.appendSlice(&buffer);
    }

    fn appendI32(self: *StateBuilder, value: i32) !void {
        var buffer: [4]u8 = undefined;
        std.mem.writeInt(i32, &buffer, value, .little);
        try self.out.appendSlice(&buffer);
    }

    fn appendI64(self: *StateBuilder, value: i64) !void {
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(i64, &buffer, value, .little);
        try self.out.appendSlice(&buffer);
    }

    fn appendUsize(self: *StateBuilder, value: usize) !void {
        try self.appendU64(@intCast(value));
    }

    fn appendOptionalUsize(self: *StateBuilder, value: ?usize) !void {
        try self.appendBool(value != null);
        if (value) |present| try self.appendUsize(present);
    }

    fn appendF64(self: *StateBuilder, value: f64) !void {
        const bits: u64 = @bitCast(value);
        try self.appendU64(bits);
    }

    fn appendString(self: *StateBuilder, value: []const u8) !void {
        try self.appendUsize(value.len);
        try self.out.appendSlice(value);
    }

    fn appendOptionalString(self: *StateBuilder, value: ?[]const u8) !void {
        try self.appendBool(value != null);
        if (value) |present| try self.appendString(present);
    }

    fn appendOptionalDmin(self: *StateBuilder, value: ?[3]f64) !void {
        try self.appendBool(value != null);
        if (value) |present| {
            for (present) |channel| try self.appendF64(channel);
        }
    }
};

fn appendConfigValue(builder: *StateBuilder, value: processing_config.Value) !void {
    switch (value) {
        .integer => |present| {
            try builder.appendU8(0);
            try builder.appendI64(present);
        },
        .float => |present| {
            try builder.appendU8(1);
            try builder.appendF64(present);
        },
        .boolean => |present| {
            try builder.appendU8(2);
            try builder.appendBool(present);
        },
        .string => |present| {
            try builder.appendU8(3);
            try builder.appendString(present.slice());
        },
        .list => |present| {
            try builder.appendU8(4);
            try builder.appendUsize(present.len);
            for (present.slice()) |item| try builder.appendF64(item);
        },
    }
}

fn appendRenderOptions(builder: *StateBuilder, options: processing_render.RenderToDisplayOptions) !void {
    try builder.appendF64(options.contrast);
    try builder.appendF64(options.percentile_lo);
    try builder.appendF64(options.percentile_hi);
    try builder.appendF64(options.exposure_compensation);
    try builder.appendF64(options.color_temp);
    try builder.appendF64(options.color_tint);
    try builder.appendF64(options.auto_white_balance);
    try builder.appendF64(options.film_gamma);
    try builder.appendF64(options.film_toe);
    try builder.appendF64(options.dye_crosstalk);
    try builder.appendUsize(options.percentile_sample_limit);
}

fn appendGpuRequest(builder: *StateBuilder, request: processing_webgpu.Request) !void {
    try builder.appendU8(@intFromEnum(request.backend));
    try builder.appendU8(@intFromEnum(request.fallback));
}

fn appendOutputSelection(builder: *StateBuilder, outputs: processing_export.OutputSelection) !void {
    try builder.appendBool(outputs.ir_neg);
    try builder.appendBool(outputs.ir_inv);
    try builder.appendBool(outputs.inv_only);
}

fn appendFrameRect(builder: *StateBuilder, rect: processing_export.FrameRect) !void {
    try builder.appendF64(rect.cx);
    try builder.appendF64(rect.cy);
    try builder.appendF64(rect.w);
    try builder.appendF64(rect.h);
    try builder.appendF64(rect.angle);
    try builder.appendI32(rect.rotation);
}

fn appendRebateRect(builder: *StateBuilder, rect: app_state.RebateRect) !void {
    try builder.appendF64(rect.x);
    try builder.appendF64(rect.y);
    try builder.appendF64(rect.w);
    try builder.appendF64(rect.h);
    try builder.appendF64(rect.angle);
}

fn appendRebateOriginRect(builder: *StateBuilder, rect: processing_frames.RebateOriginRect) !void {
    try builder.appendF64(rect.x);
    try builder.appendF64(rect.y);
    try builder.appendF64(rect.w);
    try builder.appendF64(rect.h);
    try builder.appendF64(rect.angle);
}

fn sortedEntryIndices(
    loaded: *const processing_config.LoadedConfig,
    out: *[32]usize,
) []usize {
    for (0..loaded.len) |index| out[index] = index;
    insertionSortConfigEntries(loaded, out[0..loaded.len]);
    return out[0..loaded.len];
}

fn sortedStockIndices(
    loaded: *const processing_config.LoadedConfig,
    out: *[8]usize,
) []usize {
    for (0..loaded.stock_len) |index| out[index] = index;
    insertionSortConfigStocks(loaded, out[0..loaded.stock_len]);
    return out[0..loaded.stock_len];
}

fn insertionSortConfigEntries(loaded: *const processing_config.LoadedConfig, indices: []usize) void {
    var index: usize = 1;
    while (index < indices.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and bytesLess(
            loaded.entries[indices[cursor]].name.slice(),
            loaded.entries[indices[cursor - 1]].name.slice(),
        )) : (cursor -= 1) {
            std.mem.swap(usize, &indices[cursor], &indices[cursor - 1]);
        }
    }
}

fn insertionSortConfigStocks(loaded: *const processing_config.LoadedConfig, indices: []usize) void {
    var index: usize = 1;
    while (index < indices.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and bytesLess(
            loaded.stocks[indices[cursor]].name.slice(),
            loaded.stocks[indices[cursor - 1]].name.slice(),
        )) : (cursor -= 1) {
            std.mem.swap(usize, &indices[cursor], &indices[cursor - 1]);
        }
    }
}

fn bytesLess(a: []const u8, b: []const u8) bool {
    const len = @min(a.len, b.len);
    for (a[0..len], b[0..len]) |left, right| {
        if (left == right) continue;
        return left < right;
    }
    return a.len < b.len;
}

fn optionalU64Equal(a: ?u64, b: ?u64) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

fn optionalI64Equal(a: ?i64, b: ?i64) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

fn fingerprintKeyInput(input: KeyInput) u128 {
    var result = fnv128_offset;
    hashU32(&result, schema_version);
    hashU8(&result, @intFromEnum(input.operation));
    hashString(&result, input.image.path);
    hashOptionalU64(&result, input.image.size_bytes);
    hashOptionalI64(&result, input.image.mtime_ns);
    hashString(&result, input.config_state);
    hashString(&result, input.operation_state);
    return result;
}

const fnv128_offset: u128 = 144066263297769815596495629667062367629;
const fnv128_prime: u128 = 309485009821345068724781371;

fn hashBytes(hash: *u128, bytes: []const u8) void {
    for (bytes) |byte| {
        hash.* ^= byte;
        hash.* *%= fnv128_prime;
    }
}

fn hashString(hash: *u128, value: []const u8) void {
    hashU64(hash, @intCast(value.len));
    hashBytes(hash, value);
}

fn hashU8(hash: *u128, value: u8) void {
    hashBytes(hash, &.{value});
}

fn hashU32(hash: *u128, value: u32) void {
    var buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &buffer, value, .little);
    hashBytes(hash, &buffer);
}

fn hashU64(hash: *u128, value: u64) void {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, value, .little);
    hashBytes(hash, &buffer);
}

fn hashI64(hash: *u128, value: i64) void {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(i64, &buffer, value, .little);
    hashBytes(hash, &buffer);
}

fn hashOptionalU64(hash: *u128, value: ?u64) void {
    hashU8(hash, if (value == null) 0 else 1);
    if (value) |present| hashU64(hash, present);
}

fn hashOptionalI64(hash: *u128, value: ?i64) void {
    hashU8(hash, if (value == null) 0 else 1);
    if (value) |present| hashI64(hash, present);
}

fn sampleConfig() !processing_config.LoadedConfig {
    var loaded = processing_config.LoadedConfig{};
    try loaded.set("stock", .{ .string = try processing_config.FixedString.from("kodak_gold") });
    try loaded.set("render_contrast", .{ .float = 1.4 });
    try loaded.set("preview_size", .{ .integer = 8192 });
    try loaded.set("dmin", .{ .list = try processing_config.FloatList.init(&.{ 0.1, 0.2, 0.3 }) });
    const stock_index = try loaded.ensureStock("custom_test");
    loaded.stocks[stock_index].description = try processing_config.FixedString.from("Custom test stock");
    loaded.stocks[stock_index].has_description = true;
    loaded.stocks[stock_index].coeffs[0][0] = 1.0;
    loaded.stocks[stock_index].coeffs[1][1] = 1.0;
    loaded.stocks[stock_index].coeffs[2][2] = 1.0;
    loaded.stocks[stock_index].has_coeffs = true;
    return loaded;
}

test "config state serialization is canonical and includes every active entry" {
    const allocator = std.testing.allocator;
    var first = processing_config.LoadedConfig{};
    try first.set("stock", .{ .string = try processing_config.FixedString.from("kodak_gold") });
    try first.set("render_contrast", .{ .float = 1.4 });

    var second = processing_config.LoadedConfig{};
    try second.set("render_contrast", .{ .float = 1.4 });
    try second.set("stock", .{ .string = try processing_config.FixedString.from("kodak_gold") });

    const first_bytes = try configStateBytes(allocator, &first);
    defer allocator.free(first_bytes);
    const second_bytes = try configStateBytes(allocator, &second);
    defer allocator.free(second_bytes);
    try std.testing.expectEqualSlices(u8, first_bytes, second_bytes);

    try second.set("render_contrast", .{ .float = 1.5 });
    const changed_bytes = try configStateBytes(allocator, &second);
    defer allocator.free(changed_bytes);
    try std.testing.expect(!std.mem.eql(u8, first_bytes, changed_bytes));
}

test "config state serialization includes custom stock coefficients" {
    const allocator = std.testing.allocator;
    var config_a = try sampleConfig();
    var config_b = config_a;
    config_b.stocks[0].coeffs[0][0] = 1.01;

    const bytes_a = try configStateBytes(allocator, &config_a);
    defer allocator.free(bytes_a);
    const bytes_b = try configStateBytes(allocator, &config_b);
    defer allocator.free(bytes_b);
    try std.testing.expect(!std.mem.eql(u8, bytes_a, bytes_b));
}

test "process cache key equality requires exact image config and operation state" {
    const allocator = std.testing.allocator;
    var config = try sampleConfig();
    const config_bytes = try configStateBytes(allocator, &config);
    defer allocator.free(config_bytes);
    const state_bytes = try quickPreviewStateBytes(allocator, 8192);
    defer allocator.free(state_bytes);

    var key = try Key.init(allocator, .{
        .operation = .quick_preview,
        .image = .{ .path = "scans/scan_0004.tiff", .size_bytes = 1234, .mtime_ns = 55 },
        .config_state = config_bytes,
        .operation_state = state_bytes,
    });
    defer key.deinit(allocator);
    var same = try key.clone(allocator);
    defer same.deinit(allocator);
    try std.testing.expect(key.eql(same));
    try std.testing.expectEqual(key.hash(), same.hash());

    var changed_path = try Key.init(allocator, .{
        .operation = .quick_preview,
        .image = .{ .path = "scans/other.tiff", .size_bytes = 1234, .mtime_ns = 55 },
        .config_state = config_bytes,
        .operation_state = state_bytes,
    });
    defer changed_path.deinit(allocator);
    try std.testing.expect(!key.eql(changed_path));

    var changed_mtime = try Key.init(allocator, .{
        .operation = .quick_preview,
        .image = .{ .path = "scans/scan_0004.tiff", .size_bytes = 1234, .mtime_ns = 56 },
        .config_state = config_bytes,
        .operation_state = state_bytes,
    });
    defer changed_mtime.deinit(allocator);
    try std.testing.expect(!key.eql(changed_mtime));

    const other_state = try quickPreviewStateBytes(allocator, 4096);
    defer allocator.free(other_state);
    var changed_state = try Key.init(allocator, .{
        .operation = .quick_preview,
        .image = .{ .path = "scans/scan_0004.tiff", .size_bytes = 1234, .mtime_ns = 55 },
        .config_state = config_bytes,
        .operation_state = other_state,
    });
    defer changed_state.deinit(allocator);
    try std.testing.expect(!key.eql(changed_state));
}

test "inverted preview state changes when render dmin or gpu request changes" {
    const allocator = std.testing.allocator;
    const base = try invertedPreviewStateBytes(allocator, .{
        .stock = "kodak_gold",
        .dmin = .{ 0.1, 0.2, 0.3 },
        .render_options = .{ .contrast = 1.4 },
        .invert_request = .{},
        .preview_width = 100,
        .preview_height = 50,
        .preview_scale = 0.5,
    });
    defer allocator.free(base);

    const changed_dmin = try invertedPreviewStateBytes(allocator, .{
        .stock = "kodak_gold",
        .dmin = .{ 0.1, 0.2, 0.31 },
        .render_options = .{ .contrast = 1.4 },
        .invert_request = .{},
        .preview_width = 100,
        .preview_height = 50,
        .preview_scale = 0.5,
    });
    defer allocator.free(changed_dmin);
    try std.testing.expect(!std.mem.eql(u8, base, changed_dmin));

    const changed_render = try invertedPreviewStateBytes(allocator, .{
        .stock = "kodak_gold",
        .dmin = .{ 0.1, 0.2, 0.3 },
        .render_options = .{ .contrast = 1.41 },
        .invert_request = .{},
        .preview_width = 100,
        .preview_height = 50,
        .preview_scale = 0.5,
    });
    defer allocator.free(changed_render);
    try std.testing.expect(!std.mem.eql(u8, base, changed_render));

    const changed_gpu = try invertedPreviewStateBytes(allocator, .{
        .stock = "kodak_gold",
        .dmin = .{ 0.1, 0.2, 0.3 },
        .render_options = .{ .contrast = 1.4 },
        .invert_request = .{ .backend = .webgpu, .fallback = .allow_cpu },
        .preview_width = 100,
        .preview_height = 50,
        .preview_scale = 0.5,
    });
    defer allocator.free(changed_gpu);
    try std.testing.expect(!std.mem.eql(u8, base, changed_gpu));
}

test "auto detect and export state encode operation-specific controls" {
    const allocator = std.testing.allocator;
    const auto_a = try autoDetectStateBytes(allocator, .{
        .options = .{ .format = "35mm", .n_frames = 6 },
        .scale_percent = 0.0,
        .output_rotation = 270,
        .preview_width = 100,
        .preview_height = 50,
        .preview_scale = 0.5,
    });
    defer allocator.free(auto_a);
    const auto_b = try autoDetectStateBytes(allocator, .{
        .options = .{ .format = "35mm", .n_frames = 5 },
        .scale_percent = 0.0,
        .output_rotation = 270,
        .preview_width = 100,
        .preview_height = 50,
        .preview_scale = 0.5,
    });
    defer allocator.free(auto_b);
    try std.testing.expect(!std.mem.eql(u8, auto_a, auto_b));

    const rects = [_]processing_export.FrameRect{
        .{ .cx = 10.0, .cy = 20.0, .w = 30.0, .h = 40.0, .angle = 1.0, .rotation = 270 },
    };
    const export_a = try exportStateBytes(allocator, .{
        .output_dir = "frames",
        .basename = "frame",
        .rects = &rects,
        .outputs = .{ .ir_inv = true, .inv_only = false },
    });
    defer allocator.free(export_a);
    const export_b = try exportStateBytes(allocator, .{
        .output_dir = "frames",
        .basename = "frame",
        .rects = &rects,
        .outputs = .{ .ir_inv = true, .inv_only = true },
    });
    defer allocator.free(export_b);
    try std.testing.expect(!std.mem.eql(u8, export_a, export_b));
}

test "byte result cache returns hits only for exact semantic keys" {
    const allocator = std.testing.allocator;
    var cache = ByteResultCache.init(allocator);
    defer cache.deinit();

    var config = try sampleConfig();
    const config_bytes = try configStateBytes(allocator, &config);
    defer allocator.free(config_bytes);
    const state_bytes = try quickPreviewStateBytes(allocator, 8192);
    defer allocator.free(state_bytes);

    var key = try Key.init(allocator, .{
        .operation = .quick_preview,
        .image = .{ .path = "scan.tiff", .size_bytes = 100, .mtime_ns = 10 },
        .config_state = config_bytes,
        .operation_state = state_bytes,
    });
    defer key.deinit(allocator);
    try cache.put(key, "cached-preview");
    try std.testing.expectEqualStrings("cached-preview", cache.get(key).?);

    const miss_state = try quickPreviewStateBytes(allocator, 4096);
    defer allocator.free(miss_state);
    var miss_key = try Key.init(allocator, .{
        .operation = .quick_preview,
        .image = .{ .path = "scan.tiff", .size_bytes = 100, .mtime_ns = 10 },
        .config_state = config_bytes,
        .operation_state = miss_state,
    });
    defer miss_key.deinit(allocator);
    try std.testing.expect(cache.get(miss_key) == null);

    try cache.put(key, "updated-preview");
    try std.testing.expectEqualStrings("updated-preview", cache.get(key).?);
}

test "quick preview cache clones hits and misses on semantic key changes" {
    const allocator = std.testing.allocator;
    var cache = QuickPreviewCache{};
    defer cache.deinit(allocator);

    var config = try sampleConfig();
    const config_bytes = try configStateBytes(allocator, &config);
    defer allocator.free(config_bytes);
    const state_bytes = try quickPreviewStateBytes(allocator, 8192);
    defer allocator.free(state_bytes);

    var key = try Key.init(allocator, .{
        .operation = .quick_preview,
        .image = .{ .path = "scan.tiff", .size_bytes = 100, .mtime_ns = 10 },
        .config_state = config_bytes,
        .operation_state = state_bytes,
    });
    defer key.deinit(allocator);

    var preview = try fakeQuickPreview(allocator, 4, 3);
    defer preview.deinit(allocator);
    try cache.putClone(allocator, key, preview);
    preview.preview_raw[0] = 999;

    var hit = (try cache.getClone(allocator, key)).?;
    defer hit.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 0), hit.preview_raw[0]);
    hit.preview_raw[0] = 777;

    var second_hit = (try cache.getClone(allocator, key)).?;
    defer second_hit.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 0), second_hit.preview_raw[0]);

    const miss_state = try quickPreviewStateBytes(allocator, 4096);
    defer allocator.free(miss_state);
    var miss_key = try Key.init(allocator, .{
        .operation = .quick_preview,
        .image = .{ .path = "scan.tiff", .size_bytes = 100, .mtime_ns = 10 },
        .config_state = config_bytes,
        .operation_state = miss_state,
    });
    defer miss_key.deinit(allocator);
    try std.testing.expect((try cache.getClone(allocator, miss_key)) == null);
}

test "RGB page cache owns pages and evicts by memory budget" {
    const allocator = std.testing.allocator;
    var cache = RgbPageCache{ .memory_budget_bytes = 21 };
    defer cache.deinit(allocator);

    var key_a = try rgbPageTestKey(allocator, "scan-a.tiff", 10, 1);
    defer key_a.deinit(allocator);
    var key_b = try rgbPageTestKey(allocator, "scan-b.tiff", 10, 2);
    defer key_b.deinit(allocator);
    var key_c = try rgbPageTestKey(allocator, "scan-c.tiff", 4, 3);
    defer key_c.deinit(allocator);

    var page_a = try fakeRgbPage(allocator, 3, 3);
    try std.testing.expect(try cache.putOwned(allocator, key_a, &page_a));
    try std.testing.expectEqual(@as(usize, 9), cache.resident_bytes);
    var hit_a = (try cache.getClone(allocator, key_a)).?;
    defer hit_a.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), hit_a.rgb.data[0]);
    hit_a.rgb.data[0] = 99;
    var second_hit_a = (try cache.getClone(allocator, key_a)).?;
    defer second_hit_a.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), second_hit_a.rgb.data[0]);

    var page_b = try fakeRgbPage(allocator, 3, 3);
    try std.testing.expect(try cache.putOwned(allocator, key_b, &page_b));
    var after_b_hit_a = (try cache.getClone(allocator, key_a)).?;
    defer after_b_hit_a.deinit(allocator);

    var page_c = try fakeRgbPage(allocator, 4, 3);
    try std.testing.expect(try cache.putOwned(allocator, key_c, &page_c));
    try std.testing.expect((try cache.getClone(allocator, key_b)) == null);
    var retained_a = (try cache.getClone(allocator, key_a)).?;
    defer retained_a.deinit(allocator);
}

test "RGB page cache refuses pages larger than memory budget" {
    const allocator = std.testing.allocator;
    var cache = RgbPageCache{ .memory_budget_bytes = 4 };
    defer cache.deinit(allocator);

    var key = try rgbPageTestKey(allocator, "huge.tiff", 16, 1);
    defer key.deinit(allocator);
    var page = try fakeRgbPage(allocator, 5, 1);
    defer page.deinit(allocator);
    try std.testing.expect(!(try cache.putOwned(allocator, key, &page)));
    try std.testing.expectEqual(@as(usize, 0), cache.resident_bytes);
}

test "RGB page key changes when file metadata changes" {
    const allocator = std.testing.allocator;
    var key_a = try rgbPageTestKey(allocator, "scan.tiff", 100, 10);
    defer key_a.deinit(allocator);
    var key_b = try rgbPageTestKey(allocator, "scan.tiff", 101, 10);
    defer key_b.deinit(allocator);
    var key_c = try rgbPageTestKey(allocator, "scan.tiff", 100, 11);
    defer key_c.deinit(allocator);

    try std.testing.expect(!key_a.eql(key_b));
    try std.testing.expect(!key_a.eql(key_c));
}

test "Dmin cache uses compact semantic fingerprints and evicts least recently used" {
    const allocator = std.testing.allocator;
    var cache = DminCache{};
    defer cache.deinit(allocator);

    var keys: [dmin_cache_capacity + 1]Key = undefined;
    for (&keys, 0..) |*key, index| {
        var path_buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "scan-{d}.tiff", .{index});
        key.* = try rebateDminTestKey(allocator, path, 100 + index, @intCast(index));
    }
    defer {
        for (&keys) |*key| key.deinit(allocator);
    }

    try cache.put(allocator, keys[0], .{ 0.1, 0.2, 0.3 });
    try std.testing.expectEqual(@as(u128, keys[0].fingerprint), keys[0].hash());
    const hit = cache.get(keys[0]).?;
    try std.testing.expectApproxEqAbs(0.2, hit[1], 0.0);

    try cache.put(allocator, keys[0], .{ 0.4, 0.5, 0.6 });
    try std.testing.expectApproxEqAbs(0.4, cache.get(keys[0]).?[0], 0.0);

    for (keys[1..dmin_cache_capacity]) |key| {
        try cache.put(allocator, key, .{ 1.0, 2.0, 3.0 });
    }
    _ = cache.get(keys[0]);
    try cache.put(allocator, keys[dmin_cache_capacity], .{ 9.0, 9.0, 9.0 });
    try std.testing.expect(cache.get(keys[1]) == null);
    try std.testing.expect(cache.get(keys[0]) != null);
}

test "Dmin key changes when image metadata or rebate rectangle changes" {
    const allocator = std.testing.allocator;
    var key_a = try rebateDminTestKeyWithRect(
        allocator,
        "scan.tiff",
        100,
        10,
        .{ .x = 1.0, .y = 2.0, .w = 3.0, .h = 4.0, .angle = 0.0 },
    );
    defer key_a.deinit(allocator);
    var key_b = try rebateDminTestKeyWithRect(
        allocator,
        "scan.tiff",
        101,
        10,
        .{ .x = 1.0, .y = 2.0, .w = 3.0, .h = 4.0, .angle = 0.0 },
    );
    defer key_b.deinit(allocator);
    var key_c = try rebateDminTestKeyWithRect(
        allocator,
        "scan.tiff",
        100,
        10,
        .{ .x = 1.0, .y = 2.0, .w = 3.1, .h = 4.0, .angle = 0.0 },
    );
    defer key_c.deinit(allocator);

    try std.testing.expect(!key_a.eql(key_b));
    try std.testing.expect(!key_a.eql(key_c));
}

test "Dmin public key includes full processing config state" {
    const allocator = std.testing.allocator;
    var config_a = try sampleConfig();
    var config_b = config_a;
    try config_b.set("render_contrast", .{ .float = 1.55 });
    const rect: app_state.RebateRect = .{ .x = 1.0, .y = 2.0, .w = 3.0, .h = 4.0, .angle = 0.0 };

    var key_a = try rebateDminKey(allocator, std.testing.io, "scans/missing-dmin-config.tiff", &config_a, rect);
    defer key_a.deinit(allocator);
    var key_b = try rebateDminKey(allocator, std.testing.io, "scans/missing-dmin-config.tiff", &config_b, rect);
    defer key_b.deinit(allocator);
    try std.testing.expect(!key_a.eql(key_b));
}

test "auto detect cache clones hits and includes full config state" {
    const allocator = std.testing.allocator;
    var cache = AutoDetectCache{};
    defer cache.deinit(allocator);

    var config_a = try sampleConfig();
    var config_b = config_a;
    try config_b.set("render_contrast", .{ .float = 1.55 });
    const state: AutoDetectState = .{
        .options = .{ .format = "35mm", .n_frames = 6 },
        .scale_percent = 0.5,
        .output_rotation = 270,
        .preview_width = 100,
        .preview_height = 50,
        .preview_scale = 0.5,
    };
    var key = try autoDetectKey(allocator, std.testing.io, "scans/missing-auto-cache.tiff", &config_a, state);
    defer key.deinit(allocator);
    var changed_config = try autoDetectKey(allocator, std.testing.io, "scans/missing-auto-cache.tiff", &config_b, state);
    defer changed_config.deinit(allocator);
    try std.testing.expect(!key.eql(changed_config));

    var result = try fakeAutoDetectResult(allocator);
    defer result.deinit(allocator);
    try cache.putClone(allocator, key, .{
        .result = result,
        .full_rebate = .{ .x = 1.0, .y = 2.0, .w = 3.0, .h = 4.0, .angle = 0.0 },
        .dmin = .{ 0.1, 0.2, 0.3 },
    });
    result.frames[0].cx = 99.0;

    var hit = (try cache.getClone(allocator, key)).?;
    defer hit.deinit(allocator);
    try std.testing.expectApproxEqAbs(8.0, hit.result.frames[0].cx, 0.0);
    try std.testing.expectApproxEqAbs(0.2, hit.dmin.?[1], 0.0);
    hit.result.frames[0].cx = 77.0;

    var second_hit = (try cache.getClone(allocator, key)).?;
    defer second_hit.deinit(allocator);
    try std.testing.expectApproxEqAbs(8.0, second_hit.result.frames[0].cx, 0.0);
    try std.testing.expect((try cache.getClone(allocator, changed_config)) == null);
}

test "inverted preview cache clones hits and misses on semantic render state" {
    const allocator = std.testing.allocator;
    var cache = InvertedPreviewCache{};
    defer cache.deinit(allocator);

    var config = try sampleConfig();
    const state: InvertedPreviewState = .{
        .stock = "kodak_gold",
        .dmin = .{ 0.1, 0.2, 0.3 },
        .render_options = .{ .contrast = 1.4 },
        .invert_request = .{},
        .preview_width = 100,
        .preview_height = 50,
        .preview_scale = 0.5,
    };
    var key = try invertedPreviewKey(allocator, std.testing.io, "scans/missing-inverted-cache.tiff", &config, state);
    defer key.deinit(allocator);
    try cache.putClone(allocator, key, &.{ 1, 2, 3, 4, 5, 6 });

    var hit = (try cache.getClone(allocator, key)).?;
    defer allocator.free(hit);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, hit);
    hit[0] = 99;
    const second_hit = (try cache.getClone(allocator, key)).?;
    defer allocator.free(second_hit);
    try std.testing.expectEqual(@as(u8, 1), second_hit[0]);

    var changed_render = try invertedPreviewKey(allocator, std.testing.io, "scans/missing-inverted-cache.tiff", &config, .{
        .stock = "kodak_gold",
        .dmin = .{ 0.1, 0.2, 0.3 },
        .render_options = .{ .contrast = 1.5 },
        .invert_request = .{},
        .preview_width = 100,
        .preview_height = 50,
        .preview_scale = 0.5,
    });
    defer changed_render.deinit(allocator);
    try std.testing.expect((try cache.getClone(allocator, changed_render)) == null);

    var changed_dmin = try invertedPreviewKey(allocator, std.testing.io, "scans/missing-inverted-cache.tiff", &config, .{
        .stock = "kodak_gold",
        .dmin = .{ 0.1, 0.2, 0.31 },
        .render_options = .{ .contrast = 1.4 },
        .invert_request = .{},
        .preview_width = 100,
        .preview_height = 50,
        .preview_scale = 0.5,
    });
    defer changed_dmin.deinit(allocator);
    try std.testing.expect((try cache.getClone(allocator, changed_dmin)) == null);

    var changed_config = config;
    try changed_config.set("render_contrast", .{ .float = 1.55 });
    var config_key = try invertedPreviewKey(allocator, std.testing.io, "scans/missing-inverted-cache.tiff", &changed_config, state);
    defer config_key.deinit(allocator);
    try std.testing.expect((try cache.getClone(allocator, config_key)) == null);
}

fn fakeQuickPreview(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
) !processing_workflow.QuickPreview {
    const samples = width * height * 3;
    const raw = try allocator.alloc(u16, samples);
    errdefer allocator.free(raw);
    for (raw, 0..) |*sample, index| sample.* = @intCast(index);
    const rgb8 = try allocator.alloc(u8, samples);
    errdefer allocator.free(rgb8);
    for (rgb8, 0..) |*sample, index| sample.* = @intCast(index % 256);
    const jpeg = try allocator.alloc(u8, 0);
    return .{
        .info = .{
            .width = width * 2,
            .height = height * 2,
            .has_ir = false,
            .is_grayscale = false,
            .dpi = 800,
            .preview_scale = 0.5,
            .rgb_samples_per_pixel = 3,
            .rgb_bits_per_sample = 16,
        },
        .preview_width = width,
        .preview_height = height,
        .preview_raw = raw,
        .preview_rgb8 = rgb8,
        .jpeg = jpeg,
    };
}

fn fakeAutoDetectResult(allocator: std.mem.Allocator) !processing_workflow.AutoDetectResult {
    const frames = try allocator.alloc(processing_frames.FrameRect, 1);
    frames[0] = .{ .cx = 8.0, .cy = 6.0, .w = 4.0, .h = 3.0, .angle = 0.0 };
    return .{
        .frames = frames,
        .aspect = "35mm",
        .rebate = .{ .cx = 2.0, .cy = 2.0, .w = 1.0, .h = 1.0, .angle = 0.0 },
    };
}

fn fakeRgbPage(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
) !tiff.RgbPageWithMetadata {
    const len = @as(usize, width) * @as(usize, height);
    const data = try allocator.alloc(u8, len);
    for (data, 0..) |*sample, index| sample.* = @intCast(index % 256);
    return .{
        .rgb = .{
            .width = width,
            .height = height,
            .samples_per_pixel = 1,
            .bits_per_sample = 8,
            .data = data,
        },
        .dpi = 800,
        .ir = null,
    };
}

fn rgbPageTestKey(
    allocator: std.mem.Allocator,
    path: []const u8,
    size_bytes: u64,
    mtime_ns: i64,
) !Key {
    const state = try rgbPageStateBytes(allocator);
    defer allocator.free(state);
    return Key.init(allocator, .{
        .operation = .rgb_page,
        .image = .{ .path = path, .size_bytes = size_bytes, .mtime_ns = mtime_ns },
        .operation_state = state,
    });
}

fn rebateDminTestKey(
    allocator: std.mem.Allocator,
    path: []const u8,
    size_bytes: u64,
    mtime_ns: i64,
) !Key {
    return rebateDminTestKeyWithRect(
        allocator,
        path,
        size_bytes,
        mtime_ns,
        .{ .x = 1.0, .y = 2.0, .w = 3.0, .h = 4.0, .angle = 0.0 },
    );
}

fn rebateDminTestKeyWithRect(
    allocator: std.mem.Allocator,
    path: []const u8,
    size_bytes: u64,
    mtime_ns: i64,
    rect: app_state.RebateRect,
) !Key {
    const state = try rebateDminStateBytes(allocator, rect);
    defer allocator.free(state);
    return Key.init(allocator, .{
        .operation = .rebate_dmin,
        .image = .{ .path = path, .size_bytes = size_bytes, .mtime_ns = mtime_ns },
        .operation_state = state,
    });
}
