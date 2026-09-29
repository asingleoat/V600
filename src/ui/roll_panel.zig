//! The Scan view's roll controls: start or reopen a roll, scan a strip in one
//! click (preview, film area, roll LUT, scan), and export finished strips in
//! the background while the next one scans.

const std = @import("std");
const builtin = @import("builtin");
const v600 = @import("v600");
const c = @import("sdl_nuklear.zig").c;
const chrome = @import("chrome.zig");

const Roll = v600.roll.Roll;
const PreviewBuffer = v600.native_ui_preview_worker.PreviewBuffer;
const film_lut = v600.scanner.film_lut;
const layoutRow = chrome.layoutRow;
const drawText = chrome.drawText;
const nkBool = chrome.nkBool;
const tooltip = chrome.tooltip;

const allocator = std.heap.page_allocator;
const formats = [_][]const u8{ "35mm", "645", "6x6", "6x7", "6x9" };
pub const preview_output = "/tmp/v600-native-preview.tiff";
pub const cancel_file = ".zig-cache/v600-native-scan.cancel";

pub const RollPanel = struct {
    io: std.Io,
    scans_root: []const u8,
    frames_root: []const u8,
    config_path: []const u8,
    processing_config_path: []const u8,
    default_input_dir: []const u8,
    default_output_dir: []const u8,
    active: ?Roll = null,
    processor: ?*v600.roll.Processor = null,
    names: [][]u8 = &.{},
    strip_count: usize = 0,
    new_name: [64]u8 = undefined,
    new_name_len: c_int = 0,
    /// Where the name field was last drawn, for the typing smoke's click.
    name_field_rect: c.struct_nk_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    new_stock: [64]u8 = undefined,
    new_stock_len: usize = 0,
    new_format: usize = 0,
    strip_pending: bool = false,
    scanning_strip: ?[]u8 = null,
    /// The queued scan plan points at this until the scan worker copies it.
    strip_lut_path: ?[]u8 = null,
    notice_buffer: [320]u8 = undefined,
    notice: []const u8 = "",
    // Written by the processing thread.
    result_mutex: std.Io.Mutex = .init,
    result_buffer: [256]u8 = undefined,
    result_len: usize = 0,
    completed: std.atomic.Value(usize) = .init(0),
    seen_completed: usize = 0,

    pub fn init(io: std.Io, model: *const v600.native_ui.State, config_path: []const u8, processing_config_path: []const u8) RollPanel {
        var panel = RollPanel{
            .io = io,
            .scans_root = model.scanner.output_dir,
            .frames_root = model.processing.output_dir,
            .config_path = config_path,
            .processing_config_path = processing_config_path,
            .default_input_dir = model.processing.input_dir,
            .default_output_dir = model.processing.output_dir,
        };
        const stock = "kodak_gold";
        @memcpy(panel.new_stock[0..stock.len], stock);
        panel.new_stock_len = stock.len;
        panel.refreshNames();
        return panel;
    }

    /// Reopens the roll named in the scanner config, if any.
    pub fn restore(self: *RollPanel, model: *v600.native_ui.State) void {
        const loaded = v600.scanner.config.loadFile(allocator, self.io, self.config_path) catch return;
        if (!loaded.active.roll or loaded.values.roll.len == 0) return;
        self.activate(model, loaded.values.roll.slice()) catch |err| {
            self.setNotice("Could not reopen roll {s}: {s}", .{ loaded.values.roll.slice(), @errorName(err) });
        };
    }

    pub fn deinit(self: *RollPanel, model: *v600.native_ui.State) void {
        self.close(model, false);
        self.freeNames();
    }

    pub fn isActive(self: *const RollPanel) bool {
        return self.active != null;
    }

    /// Draws the roll section at the top of the Scan view.
    pub fn draw(self: *RollPanel, ctx: *c.struct_nk_context, model: *v600.native_ui.State, preview: ?PreviewBuffer) void {
        layoutRow(ctx, 24.0, 1);
        c.nk_label(ctx, "Roll", c.NK_TEXT_LEFT);
        if (self.active) |*roll| {
            var summary_buffer: [256]u8 = undefined;
            const summary = std.fmt.bufPrint(&summary_buffer, "{s}: {s}, {s}, {d} dpi {s}, {d} strip{s}", .{
                roll.name,
                roll.stock,
                roll.format,
                roll.dpi,
                v600.roll.kindName(roll.kind),
                self.strip_count,
                if (self.strip_count == 1) "" else "s",
            }) catch roll.name;
            layoutRow(ctx, 22.0, 1);
            drawText(ctx, summary);

            const busy = model.scannerWorkActive() or self.strip_pending or self.scanning_strip != null;
            layoutRow(ctx, 30.0, 3);
            if (busy) c.nk_widget_disable_begin(ctx);
            tooltip(ctx, "Preview, find the film, and scan it as the roll's next strip. It is exported in the background.");
            if (c.nk_button_label(ctx, "Scan Strip") != 0 and !busy) self.startStrip(model);
            if (busy) c.nk_widget_disable_end(ctx);
            if (c.nk_button_label(ctx, "Open Review") != 0) self.openReview();
            if (busy) c.nk_widget_disable_begin(ctx);
            if (c.nk_button_label(ctx, "Close Roll") != 0 and !busy) self.close(model, true);
            if (busy) c.nk_widget_disable_end(ctx);
            _ = preview;

            const pending = if (self.processor) |processor| processor.pending() else 0;
            var status_buffer: [320]u8 = undefined;
            layoutRow(ctx, 22.0, 1);
            if (pending != 0) {
                drawText(ctx, std.fmt.bufPrint(&status_buffer, "Exporting {d} strip{s}...", .{ pending, if (pending == 1) "" else "s" }) catch "Exporting...");
            } else {
                drawText(ctx, self.lastResult(&status_buffer));
            }
            if (self.notice.len != 0) {
                layoutRow(ctx, 22.0, 1);
                drawText(ctx, self.notice);
            }
            return;
        }

        if (self.names.len != 0) {
            layoutRow(ctx, 22.0, 1);
            c.nk_label(ctx, "Open a roll:", c.NK_TEXT_LEFT);
            for (self.names) |name| {
                layoutRow(ctx, 24.0, 1);
                if (c.nk_option_text(ctx, name.ptr, @intCast(name.len), 0) != 0) {
                    self.activate(model, name) catch |err| self.setNotice("Could not open roll {s}: {s}", .{ name, @errorName(err) });
                    return;
                }
            }
        }
        layoutRow(ctx, 22.0, 1);
        c.nk_label(ctx, "New roll name:", c.NK_TEXT_LEFT);
        layoutRow(ctx, 28.0, 1);
        self.name_field_rect = c.nk_widget_bounds(ctx);
        _ = c.nk_edit_string(ctx, c.NK_EDIT_FIELD, &self.new_name, &self.new_name_len, @intCast(self.new_name.len), c.nk_filter_default);
        var stock_buffer: [16]v600.native_ui.ProcessStockChoice = undefined;
        if (model.processingStocksInfo(&stock_buffer)) |info| {
            for (info.stocks, 0..) |stock, index| {
                if (index % 3 == 0) layoutRow(ctx, 24.0, @intCast(@min(3, info.stocks.len - index)));
                const selected = std.mem.eql(u8, self.new_stock[0..self.new_stock_len], stock.name);
                tooltip(ctx, if (stock.description.len != 0) stock.description else stock.name);
                if (c.nk_option_text(ctx, stock.name.ptr, @intCast(stock.name.len), nkBool(selected)) != 0 and stock.name.len <= self.new_stock.len) {
                    @memcpy(self.new_stock[0..stock.name.len], stock.name);
                    self.new_stock_len = stock.name.len;
                }
            }
        } else |_| {}
        layoutRow(ctx, 26.0, formats.len);
        for (formats, 0..) |format, index| {
            if (c.nk_option_text(ctx, format.ptr, @intCast(format.len), nkBool(self.new_format == index)) != 0) self.new_format = index;
        }
        layoutRow(ctx, 30.0, 1);
        if (c.nk_button_label(ctx, "Start Roll") != 0) self.startRoll(model);
        if (self.notice.len != 0) {
            layoutRow(ctx, 22.0, 1);
            drawText(ctx, self.notice);
        }
    }

    fn startRoll(self: *RollPanel, model: *v600.native_ui.State) void {
        const name = std.mem.trim(u8, self.new_name[0..@intCast(self.new_name_len)], " ");
        const settings = v600.roll.Settings{
            .stock = self.new_stock[0..self.new_stock_len],
            .format = formats[self.new_format],
            .dpi = model.scan_controls.dpi,
            .kind = if (model.scan_controls.mode == .rgb) .rgb else .rgb_ir,
        };
        var roll = Roll.create(allocator, self.io, self.scans_root, self.frames_root, name, settings) catch |err| {
            self.setNotice("Could not start roll: {s}", .{switch (err) {
                error.InvalidRollName => "use letters, digits, '.', '_', or '-'",
                error.RollExists => "a roll with that name exists; open it instead",
                error.InvalidRollSettings => "choose 800, 1600, or 3200 dpi and RGB or RGB + IR",
                else => @errorName(err),
            }});
            return;
        };
        roll.deinit();
        self.new_name_len = 0;
        self.refreshNames();
        self.activate(model, name) catch |err| self.setNotice("Could not open roll {s}: {s}", .{ name, @errorName(err) });
    }

    /// Opens an existing roll, as clicking it in the list does.
    pub fn openRoll(self: *RollPanel, model: *v600.native_ui.State, name: []const u8) !void {
        self.refreshNames();
        try self.activate(model, name);
    }

    fn activate(self: *RollPanel, model: *v600.native_ui.State, name: []const u8) !void {
        self.close(model, true);
        var roll = try Roll.open(allocator, self.io, self.scans_root, self.frames_root, name);
        errdefer roll.deinit();
        std.Io.Dir.cwd().createDirPath(self.io, roll.frames_dir) catch {};
        const processor = try v600.roll.Processor.start(self.io, self.scans_root, self.frames_root, roll.name, .{}, onProcessed, self);
        self.active = roll;
        self.processor = processor;
        self.notice = "";
        self.result_len = 0;
        const active = &self.active.?;
        model.setProcessingDirectories(allocator, self.io, active.dir, active.frames_dir);
        applyRollControls(model, active);
        self.saveCurrent(active.name);
        // The Process view works on this roll's strips with its film stock.
        if (v600.processing.config.FixedString.from(active.stock)) |stock| {
            const updates = [_]v600.processing.config.Override{.{ .name = "stock", .value = .{ .string = stock } }};
            model.saveProcessingSettings(allocator, self.io, self.processing_config_path, &updates) catch {};
        } else |_| {}

        // Export strips an earlier session scanned but did not finish.
        var strips = active.listStrips(self.io) catch return;
        defer strips.deinit(allocator);
        self.strip_count = strips.paths.len;
        for (strips.paths) |strip| {
            if (!active.isProcessed(self.io, strip)) processor.enqueue(strip) catch {};
        }
    }

    /// Stops background exports (finishing the strip in progress) and goes
    /// back to plain scans.
    fn close(self: *RollPanel, model: *v600.native_ui.State, save: bool) void {
        if (self.processor) |processor| {
            processor.dropPending();
            processor.finish();
            self.processor = null;
        }
        if (self.active) |*roll| {
            model.setProcessingDirectories(allocator, self.io, self.default_input_dir, self.default_output_dir);
            roll.deinit();
            self.active = null;
            if (save) self.saveCurrent("");
        }
        if (self.scanning_strip) |strip| allocator.free(strip);
        self.scanning_strip = null;
        self.freeStripLutPath();
        self.strip_pending = false;
    }

    /// True once no export is queued or running and at least one finished.
    pub fn exportsFinished(self: *RollPanel) bool {
        const processor = self.processor orelse return false;
        return self.completed.load(.acquire) != 0 and processor.pending() == 0;
    }

    /// A Scan Strip click still waiting for its preview or scan.
    pub fn stripInFlight(self: *const RollPanel) bool {
        return self.strip_pending or self.scanning_strip != null;
    }

    /// What Scan Strip does.
    pub fn scanStrip(self: *RollPanel, model: *v600.native_ui.State) void {
        self.startStrip(model);
    }

    fn startStrip(self: *RollPanel, model: *v600.native_ui.State) void {
        const roll = &(self.active orelse return);
        applyRollControls(model, roll);
        model.scan_controls.autoselect = true;
        self.notice = "";
        if (model.queuePreviewScan(preview_output)) self.strip_pending = true;
    }

    /// Call after each preview finishes; continues a Scan Strip click.
    pub fn afterPreview(self: *RollPanel, model: *v600.native_ui.State, preview: ?PreviewBuffer) void {
        if (!self.strip_pending) return;
        self.strip_pending = false;
        if (!model.preview_ready) {
            self.notice = "The preview failed; the strip was not scanned.";
            return;
        }
        if (model.scan_controls.selection == null) {
            self.notice = "No film found on the preview. Load the strip and try again.";
            return;
        }
        self.queueStrip(model, preview);
    }

    /// Scans the current selection as the roll's next strip. Scan Selection
    /// calls this while a roll is open.
    pub fn queueStrip(self: *RollPanel, model: *v600.native_ui.State, preview: ?PreviewBuffer) void {
        const roll = &(self.active orelse return);
        const selection = model.scan_controls.selection orelse {
            self.notice = "Draw a selection rectangle first.";
            return;
        };
        applyRollControls(model, roll);

        // The interpreter backend applies gamma LUTs; the Linux path does not.
        self.freeStripLutPath();
        var lut_path: ?[]u8 = null;
        if (builtin.os.tag == .macos) {
            if (preview) |buffer| {
                if (buffer.bits_per_sample == 8 and buffer.samples_per_pixel >= 3) {
                    lut_path = self.rollLut(roll, buffer, selection) catch |err| blk: {
                        self.setNotice("Roll LUT unavailable ({s}); scanning without one.", .{@errorName(err)});
                        break :blk null;
                    };
                }
            }
        }

        const strip_path = roll.nextStripPath(self.io) catch |err| {
            if (lut_path) |path| allocator.free(path);
            self.setNotice("No strip path: {s}", .{@errorName(err)});
            return;
        };
        if (model.queueStripScan(strip_path, cancel_file, lut_path)) {
            self.scanning_strip = strip_path;
            self.strip_lut_path = lut_path;
        } else {
            allocator.free(strip_path);
            if (lut_path) |path| allocator.free(path);
        }
    }

    fn freeStripLutPath(self: *RollPanel) void {
        if (self.strip_lut_path) |path| allocator.free(path);
        self.strip_lut_path = null;
    }

    /// The roll LUT's path, creating the LUT from this preview on the first
    /// strip; warns when this strip's film falls outside it.
    fn rollLut(self: *RollPanel, roll: *Roll, buffer: PreviewBuffer, selection: v600.native_ui.PreviewSelection) ![]u8 {
        const film_selection = film_lut.Selection{ .x = selection.x, .y = selection.y, .w = selection.w, .h = selection.h };
        const width: usize = @intCast(buffer.width);
        const height: usize = @intCast(buffer.height);
        const channels: usize = @intCast(buffer.samples_per_pixel);
        const first_strip = roll.lut_white == null;
        const computed = try film_lut.computeFilmLuts(allocator, buffer.data, width, height, channels, film_selection, v600.roll.lut_options);
        _ = try roll.adoptLut(self.io, computed) orelse return error.NoFilmForLut;
        if (!first_strip) {
            const own = try film_lut.computeFilmLuts(allocator, buffer.data, width, height, channels, film_selection, v600.roll.fit_options);
            if (!roll.checkLutFit(own).ok()) {
                self.notice = "This strip's film falls outside the roll LUT and will clip a little; a different film may need its own roll.";
            }
        }
        return roll.path(allocator, v600.roll.lut_name);
    }

    /// Call after polling the scan worker, with whether a scan just finished.
    pub fn afterScanPoll(self: *RollPanel, model: *v600.native_ui.State, finished: bool) void {
        const strip = self.scanning_strip orelse return;
        if (finished) {
            if (self.processor) |processor| processor.enqueue(strip) catch |err| {
                self.setNotice("Could not queue the strip for export: {s}", .{@errorName(err)});
            };
            self.strip_count += 1;
            _ = model.refreshProcessingImageList(allocator, self.io) catch {};
        } else if (model.scannerWorkActive()) {
            return;
        }
        allocator.free(strip);
        self.scanning_strip = null;
        self.freeStripLutPath();
    }

    /// Refreshes the gallery after background exports finish.
    pub fn poll(self: *RollPanel, model: *v600.native_ui.State) void {
        const completed = self.completed.load(.acquire);
        if (completed == self.seen_completed) return;
        self.seen_completed = completed;
        _ = model.refreshGalleryFiles(allocator, self.io) catch {};
    }

    fn onProcessed(context: ?*anyopaque, done: v600.roll.Processor.Done) void {
        const self: *RollPanel = @ptrCast(@alignCast(context.?));
        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        const name = std.fs.path.stem(std.fs.path.basename(done.strip));
        const text = if (done.outcome) |outcome|
            std.fmt.bufPrint(&self.result_buffer, "{s}: {d} frame{s} exported, Dmin from {s}", .{
                name,
                outcome.files.len,
                if (outcome.files.len == 1) "" else "s",
                outcome.dmin_source,
            }) catch ""
        else
            std.fmt.bufPrint(&self.result_buffer, "{s}: export failed ({s})", .{ name, @errorName(done.err orelse error.Unknown) }) catch "";
        self.result_len = text.len;
        _ = self.completed.fetchAdd(1, .release);
    }

    fn lastResult(self: *RollPanel, buffer: []u8) []const u8 {
        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        if (self.result_len == 0) return "Exports: frames of each strip go to the roll's frames folder.";
        const len = @min(self.result_len, buffer.len);
        @memcpy(buffer[0..len], self.result_buffer[0..len]);
        return buffer[0..len];
    }

    fn openReview(self: *RollPanel) void {
        const roll = &(self.active orelse return);
        roll.writeReviewIndex(self.io) catch {};
        const index = roll.path(allocator, v600.roll.review_dir_name ++ "/index.html") catch return;
        defer allocator.free(index);
        const opener = if (builtin.os.tag == .macos) "open" else "xdg-open";
        const result = std.process.run(allocator, self.io, .{ .argv = &.{ opener, index } }) catch |err| {
            self.setNotice("Could not open the review page: {s}", .{@errorName(err)});
            return;
        };
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    fn saveCurrent(self: *RollPanel, name: []const u8) void {
        var updates = v600.scanner.config.LoadedConfig{};
        updates.values.roll.set(name) catch return;
        updates.active.roll = true;
        v600.scanner.config.saveFile(allocator, self.io, self.config_path, updates) catch {};
    }

    fn refreshNames(self: *RollPanel) void {
        self.freeNames();
        self.names = v600.roll.listRolls(allocator, self.io, self.scans_root) catch &.{};
    }

    fn freeNames(self: *RollPanel) void {
        for (self.names) |name| allocator.free(name);
        if (self.names.len != 0) allocator.free(self.names);
        self.names = &.{};
    }

    fn setNotice(self: *RollPanel, comptime fmt: []const u8, args: anytype) void {
        self.notice = std.fmt.bufPrint(&self.notice_buffer, fmt, args) catch "";
    }
};

/// A roll fixes the scan mode and resolution.
fn applyRollControls(model: *v600.native_ui.State, roll: *const Roll) void {
    model.scan_controls.setMode(if (roll.kind == .rgb) .rgb else .rgb_ir);
    model.scan_controls.setDpi(roll.dpi);
}
