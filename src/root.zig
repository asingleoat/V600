const std = @import("std");

/// The commit the program was built from: git's short hash, with "-dirty"
/// for uncommitted changes (see build.zig).
pub const version = @import("build_options").version;
pub const scanner = @import("scanner.zig");
pub const processing = @import("processing.zig");
pub const app_state = @import("app_state.zig");
pub const native_ui = @import("ui/state.zig");
pub const native_ui_connect_worker = @import("ui/connect_worker.zig");
pub const native_ui_preview_worker = @import("ui/preview_worker.zig");
pub const native_ui_scan_worker = @import("ui/scan_worker.zig");
pub const native_ui_process_worker = @import("ui/process_worker.zig");
pub const native_ui_process_export_worker = @import("ui/process_export_worker.zig");
pub const native_ui_inverted_preview_worker = @import("ui/inverted_preview_worker.zig");
pub const native_ui_process_cache = @import("ui/process_cache.zig");
pub const native_ui_theme = @import("ui/theme.zig");
pub const native_ui_scan_sweep = @import("ui/scan_sweep.zig");
pub const tiff = @import("tiff.zig");
pub const companion = @import("companion.zig");
pub const roll = @import("roll.zig");

test {
    std.testing.refAllDecls(@This());
}
