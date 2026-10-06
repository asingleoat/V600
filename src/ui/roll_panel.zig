//! The Scan view's roll controls: start or reopen a roll, scan a strip in one
//! click (preview, film area, roll LUT, scan), and export finished strips in
//! the background while the next one scans.

const std = @import("std");
const builtin = @import("builtin");
const cerealgrain = @import("cerealgrain");
const c = @import("sdl_nuklear.zig").c;
const chrome = @import("chrome.zig");

const Roll = cerealgrain.roll.Roll;
const PreviewBuffer = cerealgrain.native_ui_preview_worker.PreviewBuffer;
const film_lut = cerealgrain.scanner.film_lut;
const layoutRow = chrome.layoutRow;
const drawText = chrome.drawText;
const nkBool = chrome.nkBool;
const tooltip = chrome.tooltip;

const allocator = std.heap.page_allocator;
const formats = [_][]const u8{ "35mm", "645", "6x6", "6x7", "6x9" };
pub const preview_output = "/tmp/cerealgrain-native-preview.tiff";
pub const cancel_file = ".zig-cache/cerealgrain-native-scan.cancel";

pub const RollPanel = struct {
    io: std.Io,
    scans_root: []const u8,
    frames_root: []const u8,
    config_path: []const u8,
    processing_config_path: []const u8,
    default_input_dir: []const u8,
    default_output_dir: []const u8,
    active: ?Roll = null,
    processor: ?*cerealgrain.roll.Processor = null,
    /// A closed roll's exporter finishing its strip in progress; rolls
    /// cannot be opened until it has, so two big exports never overlap.
    finishing: ?*cerealgrain.roll.Processor = null,
    finishing_name_buffer: [64]u8 = undefined,
    finishing_name_len: usize = 0,
    /// Queued strips Close Roll or quitting dropped; they export when the
    /// roll is next opened.
    dropped_strips: usize = 0,
    /// Bumped whenever a roll opens, so the Process view can follow its
    /// format and rotation.
    generation: usize = 0,
    /// The Process view image whose saved frames were last loaded.
    synced_image_buffer: [std.fs.max_path_bytes]u8 = undefined,
    synced_image_len: usize = 0,
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
    /// Backs the footer status after a background export finishes.
    status_buffer: [256]u8 = undefined,
    notice: []const u8 = "",
    // Written by the processing thread.
    result_mutex: std.Io.Mutex = .init,
    result_buffer: [256]u8 = undefined,
    result_len: usize = 0,
    completed: std.atomic.Value(usize) = .init(0),
    seen_completed: usize = 0,

    pub fn init(io: std.Io, model: *const cerealgrain.native_ui.State, config_path: []const u8, processing_config_path: []const u8) RollPanel {
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
    pub fn restore(self: *RollPanel, model: *cerealgrain.native_ui.State) void {
        const loaded = cerealgrain.scanner.config.loadFile(allocator, self.io, self.config_path) catch return;
        if (!loaded.active.roll or loaded.values.roll.len == 0) return;
        self.activate(model, loaded.values.roll.slice()) catch |err| {
            self.setNotice("Could not reopen roll {s}: {s}", .{ loaded.values.roll.slice(), @errorName(err) });
        };
    }

    pub fn deinit(self: *RollPanel, model: *cerealgrain.native_ui.State) void {
        self.close(model, false, true);
        if (self.finishing) |processor| processor.finish();
        self.finishing = null;
        self.freeNames();
    }

    pub fn isActive(self: *const RollPanel) bool {
        return self.active != null;
    }

    /// Draws the roll section at the top of the Scan view.
    pub fn draw(self: *RollPanel, ctx: *c.struct_nk_context, model: *cerealgrain.native_ui.State, preview: ?PreviewBuffer) void {
        layoutRow(ctx, 24.0, 1);
        c.nk_label(ctx, "Roll", c.NK_TEXT_LEFT);
        if (self.active) |*roll| {
            var summary_buffer: [256]u8 = undefined;
            const summary = std.fmt.bufPrint(&summary_buffer, "{s}: {s}, {s}, {d} dpi {s}, {d} strip{s}", .{
                roll.name,
                roll.stock,
                roll.format,
                roll.dpi,
                cerealgrain.roll.kindName(roll.kind),
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
            if (c.nk_button_label(ctx, "Close Roll") != 0 and !busy) self.closeRoll(model);
            if (busy) c.nk_widget_disable_end(ctx);
            _ = preview;
            if (busy) {
                layoutRow(ctx, 22.0, 1);
                drawText(ctx, "Scan Strip and Close Roll wait for the scan in progress.");
            }

            const pending = if (self.processor) |processor| processor.pending() else 0;
            var status_buffer: [320]u8 = undefined;
            layoutRow(ctx, 22.0, 1);
            if (pending != 0) {
                var progress_buffer: [256]u8 = undefined;
                const progress = self.processor.?.status(&progress_buffer) orelse "starting";
                const queued = pending -| 1;
                var queued_buffer: [48]u8 = undefined;
                const queued_text = if (queued == 0) "" else std.fmt.bufPrint(&queued_buffer, "; {d} more queued", .{queued}) catch "";
                drawText(ctx, std.fmt.bufPrint(&status_buffer, "Exporting {s}{s}", .{ progress, queued_text }) catch "Exporting...");
            } else {
                drawText(ctx, self.lastResult(&status_buffer));
            }
            if (self.notice.len != 0) {
                layoutRow(ctx, 22.0, 1);
                drawText(ctx, self.notice);
            }
            return;
        }

        const finishing = self.finishing != null;
        if (self.finishing) |processor| {
            var line_buffer: [320]u8 = undefined;
            var progress_buffer: [256]u8 = undefined;
            const progress = processor.status(&progress_buffer) orelse "finishing";
            layoutRow(ctx, 22.0, 1);
            drawText(ctx, std.fmt.bufPrint(&line_buffer, "Still exporting {s}: {s}", .{ self.finishing_name_buffer[0..self.finishing_name_len], progress }) catch "Still exporting the closed roll");
            layoutRow(ctx, 22.0, 1);
            drawText(ctx, "Opening or starting a roll waits until that export is done.");
            if (self.dropped_strips != 0) {
                layoutRow(ctx, 22.0, 1);
                drawText(ctx, std.fmt.bufPrint(&line_buffer, "{d} queued strip{s} will export when that roll is opened again.", .{ self.dropped_strips, if (self.dropped_strips == 1) "" else "s" }) catch "");
            }
        }
        if (finishing) c.nk_widget_disable_begin(ctx);
        if (self.names.len != 0) {
            layoutRow(ctx, 22.0, 1);
            c.nk_label(ctx, "Open a roll:", c.NK_TEXT_LEFT);
            for (self.names) |name| {
                layoutRow(ctx, 24.0, 1);
                if (chrome.optionClicked(ctx, name, false) and !finishing) {
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
        var stock_buffer: [16]cerealgrain.native_ui.ProcessStockChoice = undefined;
        if (model.processingStocksInfo(&stock_buffer)) |info| {
            for (info.stocks, 0..) |stock, index| {
                if (index % 3 == 0) layoutRow(ctx, 24.0, @intCast(@min(3, info.stocks.len - index)));
                const selected = std.mem.eql(u8, self.new_stock[0..self.new_stock_len], stock.name);
                tooltip(ctx, if (stock.description.len != 0) stock.description else stock.name);
                if (chrome.optionClicked(ctx, stock.name, selected) and stock.name.len <= self.new_stock.len) {
                    @memcpy(self.new_stock[0..stock.name.len], stock.name);
                    self.new_stock_len = stock.name.len;
                }
            }
        } else |_| {}
        layoutRow(ctx, 26.0, formats.len);
        for (formats, 0..) |format, index| {
            if (chrome.optionClicked(ctx, format, self.new_format == index)) self.new_format = index;
        }
        layoutRow(ctx, 22.0, 1);
        c.nk_label(ctx, "Strips use the Mode and DPI below; change them any time.", c.NK_TEXT_LEFT);
        layoutRow(ctx, 30.0, 1);
        if (c.nk_button_label(ctx, "Start Roll") != 0 and !finishing) self.startRoll(model);
        if (finishing) c.nk_widget_disable_end(ctx);
        if (self.notice.len != 0) {
            layoutRow(ctx, 22.0, 1);
            drawText(ctx, self.notice);
        }
    }

    fn startRoll(self: *RollPanel, model: *cerealgrain.native_ui.State) void {
        const name = std.mem.trim(u8, self.new_name[0..@intCast(self.new_name_len)], " ");
        const settings = cerealgrain.roll.Settings{
            .stock = self.new_stock[0..self.new_stock_len],
            .format = formats[self.new_format],
            .dpi = model.scan_controls.dpi,
            .kind = if (model.scan_controls.mode == .rgb) .rgb else .rgb_ir,
        };
        var roll = Roll.create(allocator, self.io, self.scans_root, self.frames_root, name, settings) catch |err| {
            self.setNotice("Could not start roll: {s}", .{switch (err) {
                error.InvalidRollName => "use letters, digits, '.', '_', or '-'",
                error.RollExists => "a roll with that name exists; open it instead",
                error.InvalidRollSettings => "choose RGB or RGB + IR at one of the listed DPIs",
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
    pub fn openRoll(self: *RollPanel, model: *cerealgrain.native_ui.State, name: []const u8) !void {
        self.refreshNames();
        try self.activate(model, name);
    }

    fn activate(self: *RollPanel, model: *cerealgrain.native_ui.State, name: []const u8) !void {
        self.close(model, true, true);
        var roll = try Roll.open(allocator, self.io, self.scans_root, self.frames_root, name);
        errdefer roll.deinit();
        std.Io.Dir.cwd().createDirPath(self.io, roll.frames_dir) catch {};
        const processor = try cerealgrain.roll.Processor.start(self.io, self.scans_root, self.frames_root, roll.name, .{}, onProcessed, self);
        self.active = roll;
        self.processor = processor;
        self.generation += 1;
        self.synced_image_len = 0;
        self.notice = "";
        self.result_len = 0;
        const active = &self.active.?;
        model.setProcessingDirectories(allocator, self.io, active.dir, active.frames_dir);
        applyRollControls(model, active);
        self.saveCurrent(active.name);
        // The Process view works on this roll's strips with its film stock.
        if (cerealgrain.processing.config.FixedString.from(active.stock)) |stock| {
            const updates = [_]cerealgrain.processing.config.Override{.{ .name = "stock", .value = .{ .string = stock } }};
            model.saveProcessingSettings(allocator, self.io, self.processing_config_path, &updates) catch {};
        } else |_| {}

        // Export strips never exported, or whose saved frames changed since
        // (including strips a Close Roll or quit dropped from the queue).
        var strips = active.listStrips(self.io) catch return;
        defer strips.deinit(allocator);
        self.strip_count = strips.paths.len;
        for (strips.paths) |strip| {
            if (active.needsExport(self.io, strip)) processor.enqueue(strip) catch {};
        }
    }

    /// Stops background exports (finishing the strip in progress) and goes
    /// back to plain scans.
    /// The Close Roll button: returns at once, leaving a strip in progress
    /// to finish in the background.
    pub fn closeRoll(self: *RollPanel, model: *cerealgrain.native_ui.State) void {
        self.close(model, true, false);
    }

    /// With `wait` false, a strip still exporting finishes in the
    /// background (`finishing`) instead of blocking the UI thread.
    fn close(self: *RollPanel, model: *cerealgrain.native_ui.State, save: bool, wait: bool) void {
        if (self.processor) |processor| {
            self.dropped_strips = processor.dropPending();
            if (wait or processor.pending() == 0) {
                processor.finish();
            } else {
                processor.requestStop();
                self.finishing = processor;
                const name = if (self.active) |*roll| roll.name else "";
                self.finishing_name_len = @min(name.len, self.finishing_name_buffer.len);
                @memcpy(self.finishing_name_buffer[0..self.finishing_name_len], name[0..self.finishing_name_len]);
            }
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

    /// Mode and DPI chosen while a roll is open apply to its next strips.
    /// A roll needs RGB, so IR alone reverts to the roll's mode.
    pub fn syncControls(self: *RollPanel, model: *cerealgrain.native_ui.State) void {
        const roll = &(self.active orelse return);
        if (model.scan_controls.mode == .ir) {
            applyRollControls(model, roll);
            self.notice = "A roll scans RGB or RGB + IR; IR alone is for single scans.";
            return;
        }
        const kind: cerealgrain.scanner.contracts.ScanKind = if (model.scan_controls.mode == .rgb) .rgb else .rgb_ir;
        if (kind == roll.kind and model.scan_controls.dpi == roll.dpi) return;
        roll.kind = kind;
        roll.dpi = model.scan_controls.dpi;
        roll.save(self.io) catch |err| {
            self.setNotice("Could not save the roll's new settings: {s}", .{@errorName(err)});
            return;
        };
        self.setNotice("Next strips scan at {d} dpi {s}.", .{ roll.dpi, if (kind == .rgb) "RGB" else "RGB + IR" });
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
    pub fn scanStrip(self: *RollPanel, model: *cerealgrain.native_ui.State) void {
        self.startStrip(model);
    }

    fn startStrip(self: *RollPanel, model: *cerealgrain.native_ui.State) void {
        const roll = &(self.active orelse return);
        applyRollControls(model, roll);
        model.scan_controls.autoselect = true;
        self.notice = "";
        if (model.queuePreviewScan(preview_output)) self.strip_pending = true;
    }

    /// Call after each preview finishes; continues a Scan Strip click.
    pub fn afterPreview(self: *RollPanel, model: *cerealgrain.native_ui.State, preview: ?PreviewBuffer) void {
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
    pub fn queueStrip(self: *RollPanel, model: *cerealgrain.native_ui.State, preview: ?PreviewBuffer) void {
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
                        self.setNotice("No roll LUT yet ({s}); this strip gets its own LUT from the preview.", .{@errorName(err)});
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
    fn rollLut(self: *RollPanel, roll: *Roll, buffer: PreviewBuffer, selection: cerealgrain.native_ui.PreviewSelection) ![]u8 {
        const film_selection = film_lut.Selection{ .x = selection.x, .y = selection.y, .w = selection.w, .h = selection.h };
        const width: usize = @intCast(buffer.width);
        const height: usize = @intCast(buffer.height);
        const channels: usize = @intCast(buffer.samples_per_pixel);
        const first_strip = roll.lut_white == null;
        if (first_strip) {
            const computed = try film_lut.computeFilmLuts(allocator, buffer.data, width, height, channels, film_selection, cerealgrain.roll.lut_options);
            _ = try roll.adoptLut(self.io, computed) orelse return error.NoFilmForLut;
        } else if (film_lut.computeFilmLuts(allocator, buffer.data, width, height, channels, film_selection, cerealgrain.roll.fit_options)) |own| {
            // Advisory only: the roll LUT applies either way.
            if (!roll.checkLutFit(own).ok()) {
                self.notice = "This strip's film falls outside the roll LUT and will clip a little; a different film may need its own roll.";
            }
        } else |_| {}
        return roll.path(allocator, cerealgrain.roll.lut_name);
    }

    /// Call after polling the scan worker, with whether a scan just finished.
    pub fn afterScanPoll(self: *RollPanel, model: *cerealgrain.native_ui.State, finished: bool) void {
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

    /// Refreshes the gallery after background exports finish, and ends a
    /// Scan Strip click whose preview was cancelled or never ran.
    pub fn poll(self: *RollPanel, model: *cerealgrain.native_ui.State) void {
        if (self.strip_pending) {
            if (model.scanner.cancel_requested) {
                self.strip_pending = false;
                self.notice = "Cancelled; the strip will not be scanned after the preview.";
            } else if (!model.scannerWorkActive()) {
                self.strip_pending = false;
                if (self.notice.len == 0) self.notice = "The preview did not run; the strip was not scanned.";
            }
        }
        if (self.finishing) |processor| {
            if (processor.stopped()) {
                processor.finish();
                self.finishing = null;
                const name = self.finishing_name_buffer[0..self.finishing_name_len];
                if (self.dropped_strips == 0) {
                    self.setNotice("{s}'s last export finished; rolls can be opened again.", .{name});
                } else {
                    self.setNotice("{s}'s last export finished; rolls can be opened again. {d} queued strip{s} will export when {s} is opened again.", .{ name, self.dropped_strips, if (self.dropped_strips == 1) "" else "s", name });
                }
                self.dropped_strips = 0;
            }
        }
        const completed = self.completed.load(.acquire);
        if (completed == self.seen_completed) return;
        self.seen_completed = completed;
        _ = model.refreshGalleryFiles(allocator, self.io) catch {};
        const text = self.lastResult(&self.status_buffer);
        model.setStatus(text);
    }

    fn onProcessed(context: ?*anyopaque, done: cerealgrain.roll.Processor.Done) void {
        const self: *RollPanel = @ptrCast(@alignCast(context.?));
        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        const name = std.fs.path.stem(std.fs.path.basename(done.strip));
        var writer = std.Io.Writer.fixed(&self.result_buffer);
        if (done.outcome) |outcome| {
            writer.print("{s}: {d} frame{s}{s} exported, Dmin from {s}", .{
                name,
                outcome.frames,
                if (outcome.frames == 1) "" else "s",
                if (outcome.manual) " placed by hand" else "",
                outcome.dmin_source,
            }) catch {};
            if (outcome.ring_frames.len != 0) {
                writer.writeAll(". ") catch {};
                cerealgrain.processing.newton_rings.writeWarning(&writer, outcome.ring_frames) catch {};
            }
        } else {
            writer.print("{s}: export failed ({s})", .{ name, @errorName(done.err orelse error.Unknown) }) catch {};
        }
        self.result_len = writer.buffered().len;
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

    /// Called each frame once the app has been asked to quit: queued strips
    /// are dropped, the one in progress finishes, and the status line says
    /// what the app is waiting for. True once no export is running.
    pub fn stopForQuit(self: *RollPanel, model: *cerealgrain.native_ui.State) bool {
        var waiting_for: ?*cerealgrain.roll.Processor = null;
        for ([_]?*cerealgrain.roll.Processor{ self.processor, self.finishing }) |maybe| {
            const processor = maybe orelse continue;
            self.dropped_strips += processor.dropPending();
            processor.requestStop();
            if (processor.pending() != 0 and !processor.stopped()) waiting_for = processor;
        }
        const processor = waiting_for orelse return true;
        var progress_buffer: [256]u8 = undefined;
        const progress = processor.status(&progress_buffer) orelse "finishing";
        var dropped_buffer: [96]u8 = undefined;
        const dropped = if (self.dropped_strips == 0) "" else std.fmt.bufPrint(&dropped_buffer, "; {d} queued strip{s} will export when the roll is opened again", .{ self.dropped_strips, if (self.dropped_strips == 1) "" else "s" }) catch "";
        const text = std.fmt.bufPrint(&self.status_buffer, "Quitting when this export finishes: {s}{s}", .{ progress, dropped }) catch "Quitting when the roll export finishes";
        model.setStatus(text);
        return false;
    }

    /// The strip number when `path` is one of the open roll's strip scans.
    pub fn stripNumberOf(self: *const RollPanel, path: []const u8) ?usize {
        const roll = &(self.active orelse return null);
        const dir = std.fs.path.dirname(path) orelse return null;
        if (!std.mem.eql(u8, dir, roll.dir)) return null;
        return cerealgrain.roll.stripNumber(path);
    }

    /// `<roll>_sNN`, the names a strip's frames export under.
    pub fn stripExportName(self: *const RollPanel, buffer: []u8, number: usize) []const u8 {
        const roll = &(self.active orelse return "");
        return std.fmt.bufPrint(buffer, "{s}_s{d:0>2}", .{ roll.name, number }) catch "";
    }

    /// Saves the Process view's frames (and rebate, if one is set) as the
    /// strip's framing and re-exports the strip in the background under the
    /// roll's names, replacing its earlier exports. Later re-exports keep
    /// using these frames.
    pub fn exportFramedStrip(self: *RollPanel, model: *cerealgrain.native_ui.State, strip_path: []const u8) !void {
        const processor = self.processor orelse return error.NoOpenRoll;
        const count = try self.saveFraming(model, strip_path);
        try processor.enqueue(strip_path);
        self.setNotice("{s}: exporting {d} hand-placed frame{s} in the background", .{
            std.fs.path.stem(std.fs.path.basename(strip_path)),
            count,
            if (count == 1) "" else "s",
        });
        model.setStatus(self.notice);
    }

    /// Writes the Process view's frames as the strip's framing file.
    fn saveFraming(self: *RollPanel, model: *cerealgrain.native_ui.State, strip_path: []const u8) !usize {
        const roll = &(self.active orelse return error.NoOpenRoll);
        var framing = cerealgrain.native_ui.ProcessFraming{};
        const rects = try model.processExportRects(&framing.frames);
        if (rects.len == 0) return error.NoFrameSelections;
        framing.count = rects.len;
        if (model.processing.rebate_rect) |r| {
            framing.rebate = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .angle = r.angle };
        }
        try roll.saveFraming(self.io, strip_path, .{ .frames = rects, .rebate = framing.rebate });
        model.markProcessFramingSaved(framing);
        return rects.len;
    }

    /// Call each frame: when the Process view moves to another image, hands
    /// it that strip's saved frames (if it is one of the open roll's strips
    /// and has them), to show instead of its first auto-detect.
    pub fn syncSavedFraming(self: *RollPanel, model: *cerealgrain.native_ui.State) void {
        const path = model.currentProcessingImagePathForWorker() orelse "";
        if (std.mem.eql(u8, path, self.synced_image_buffer[0..self.synced_image_len])) return;
        self.synced_image_len = @min(path.len, self.synced_image_buffer.len);
        @memcpy(self.synced_image_buffer[0..self.synced_image_len], path[0..self.synced_image_len]);
        model.setProcessSavedFraming(self.loadSavedFraming(path));
    }

    fn loadSavedFraming(self: *RollPanel, path: []const u8) ?cerealgrain.native_ui.ProcessFraming {
        const roll = &(self.active orelse return null);
        if (self.stripNumberOf(path) == null) return null;
        const owned = (roll.loadFraming(self.io, path) catch |err| {
            self.setNotice("Could not read the saved frames for {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
            return null;
        }) orelse return null;
        defer owned.deinit(roll.allocator);
        var framing = cerealgrain.native_ui.ProcessFraming{ .rebate = owned.rebate };
        framing.count = @min(owned.frames.len, framing.frames.len);
        @memcpy(framing.frames[0..framing.count], owned.frames[0..framing.count]);
        return framing;
    }

    /// Call each frame after `settleProcessEdits`: saves hand edits (and
    /// undos) of an open-roll strip's frames, and says so.
    pub fn saveFramingIfEdited(self: *RollPanel, model: *cerealgrain.native_ui.State) void {
        if (!model.process_framing_dirty) return;
        const path = model.currentProcessingImagePathForWorker() orelse return;
        if (self.stripNumberOf(path) == null or model.processing.loading) {
            model.process_framing_dirty = false;
            return;
        }
        const name = std.fs.path.stem(std.fs.path.basename(path));
        const count = self.saveFraming(model, path) catch |err| {
            model.process_framing_dirty = false;
            self.setNotice("Frames for {s} not saved: {s}", .{ name, switch (err) {
                error.NoFrameSelections => "no frames are selected",
                else => @errorName(err),
            } });
            model.setStatus(self.notice);
            return;
        };
        self.setNotice("Saved {d} frame{s} for {s}; Export Strip Frames re-exports with them", .{ count, if (count == 1) "" else "s", name });
        model.setStatus(self.notice);
    }

    fn openReview(self: *RollPanel) void {
        const roll = &(self.active orelse return);
        roll.writeReviewIndex(self.io) catch {};
        const index = roll.path(allocator, cerealgrain.roll.review_dir_name ++ "/index.html") catch return;
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
        var updates = cerealgrain.scanner.config.LoadedConfig{};
        updates.values.roll.set(name) catch return;
        updates.active.roll = true;
        cerealgrain.scanner.config.saveFile(allocator, self.io, self.config_path, updates) catch {};
    }

    fn refreshNames(self: *RollPanel) void {
        self.freeNames();
        self.names = cerealgrain.roll.listRolls(allocator, self.io, self.scans_root) catch &.{};
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
fn applyRollControls(model: *cerealgrain.native_ui.State, roll: *const Roll) void {
    model.scan_controls.setMode(if (roll.kind == .rgb) .rgb else .rgb_ir);
    model.scan_controls.setDpi(roll.dpi);
}
