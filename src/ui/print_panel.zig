//! The Frame view's Print section: the printer, its paper, quality, and
//! size, the paper's ICC profile, and the layout; a soft proof of the frame
//! on that paper; and Print This Frame, which exports the frame with its
//! look and sends it, converted to the paper's profile, with the driver's
//! own colour adjustment off. Printers and their PPDs load in a background
//! thread (asking the print system can wait on the network).

const std = @import("std");
const cerealgrain = @import("cerealgrain");
const c = @import("sdl_nuklear.zig").c;
const chrome = @import("chrome.zig");

const layoutRow = chrome.layoutRow;
const tooltip = chrome.tooltip;
const nkBool = chrome.nkBool;
const State = cerealgrain.native_ui.State;
const printing = cerealgrain.printing;
const icc = cerealgrain.processing.icc;
const prints = cerealgrain.processing.print;
const config = cerealgrain.processing.config;
const PrintOrder = cerealgrain.native_ui_print_order.PrintOrder;

/// What the background thread loads.
const Load = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Null loads the printer list; a queue loads its PPD.
    queue: ?[]u8 = null,
    printers: ?[]printing.cups.Destination = null,
    ppd: ?printing.ppd.Ppd = null,
    error_name: []const u8 = "",
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *Load) void {
        self.work() catch |err| {
            self.error_name = @errorName(err);
        };
        self.done.store(true, .release);
    }

    fn work(self: *Load) !void {
        if (self.queue) |queue| {
            const path = try printing.cups.ppdPath(self.allocator, queue);
            defer self.allocator.free(path);
            defer std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.ppd = try printing.ppd.load(self.allocator, self.io, path);
        } else {
            self.printers = try printing.cups.destinations(self.allocator);
        }
    }
};

/// One driver option shown as a pulldown, its choice names ready for
/// Nuklear.
const Pulldown = struct {
    option: *const printing.ppd.Option,
    labels: [][*:0]const u8,
    index: c_int,
};

/// Options shown beside the paper's (the paper is a PPD option too, but
/// gets its own row).
const Profile = struct {
    label: [:0]const u8,
    path: []const u8,
};

pub const Action = enum { none, print };

pub const PrintPanel = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    load: ?*Load = null,
    thread: ?std.Thread = null,
    status: []const u8 = "",
    printers: []printing.cups.Destination = &.{},
    printer_labels: [][*:0]const u8 = &.{},
    printer_index: c_int = 0,
    requested: bool = false,
    ppd: ?printing.ppd.Ppd = null,
    ppd_queue: ?[]u8 = null,
    arena: std.heap.ArenaAllocator,
    paper: ?Pulldown = null,
    paper_others: []*const printing.ppd.Option = &.{},
    quality: ?Pulldown = null,
    resolution: ?Pulldown = null,
    page_size: ?Pulldown = null,
    profiles: []Profile = &.{},
    profile_labels: [][*:0]const u8 = &.{},
    /// 0 picks the driver's profile for the paper.
    profile_index: c_int = 0,
    layout_index: c_int = 0,
    fill: bool = false,
    perceptual: bool = false,
    bpc: bool = true,
    copies: c_int = 1,
    soft_proof: bool = false,
    paper_white: bool = false,
    /// Where the Paper pulldown was drawn, and its rows' height (the UI
    /// smoke clicks them).
    paper_rect: c.struct_nk_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    item_height: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) PrintPanel {
        return .{ .allocator = allocator, .io = io, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *PrintPanel) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.load) |load| self.freeLoad(load);
        self.dropPpd();
        self.freePrinters();
        self.arena.deinit();
    }

    fn freePrinters(self: *PrintPanel) void {
        if (self.printers.len > 0) printing.cups.freeDestinations(self.allocator, self.printers);
        for (self.printer_labels) |label| self.allocator.free(std.mem.span(label));
        if (self.printer_labels.len > 0) self.allocator.free(self.printer_labels);
        self.printers = &.{};
        self.printer_labels = &.{};
    }

    fn dropPpd(self: *PrintPanel) void {
        if (self.ppd) |*file| file.deinit();
        self.ppd = null;
        if (self.ppd_queue) |queue| self.allocator.free(queue);
        self.ppd_queue = null;
        _ = self.arena.reset(.free_all);
        self.paper = null;
        self.quality = null;
        self.resolution = null;
        self.page_size = null;
        self.paper_others = &.{};
        self.profiles = &.{};
        self.profile_labels = &.{};
    }

    fn freeLoad(self: *PrintPanel, load: *Load) void {
        if (load.queue) |queue| self.allocator.free(queue);
        if (load.printers) |list| printing.cups.freeDestinations(self.allocator, list);
        if (load.ppd) |*file| file.deinit();
        self.allocator.destroy(load);
        self.load = null;
    }

    fn startLoad(self: *PrintPanel, queue: ?[]const u8) void {
        if (self.load != null) return;
        const load = self.allocator.create(Load) catch return;
        load.* = .{ .allocator = self.allocator, .io = self.io };
        if (queue) |name| load.queue = self.allocator.dupe(u8, name) catch {
            self.allocator.destroy(load);
            return;
        };
        self.thread = std.Thread.spawn(.{}, Load.run, .{load}) catch {
            self.freeLoad(load);
            return;
        };
        self.load = load;
        self.status = if (queue == null) "Looking for printers..." else "Reading the printer's options...";
    }

    /// Takes finished loads and starts the next. Every UI frame while the
    /// Frame view shows.
    pub fn update(self: *PrintPanel, model: *const State) void {
        if (self.load) |load| {
            if (!load.done.load(.acquire)) return;
            self.thread.?.join();
            self.thread = null;
            if (load.error_name.len > 0) {
                self.status = if (std.mem.eql(u8, load.error_name, "CupsUnavailable")) "Printing needs CUPS, which was not found." else "Could not read the printer's options.";
            } else if (load.printers) |list| {
                self.freePrinters();
                self.printers = list;
                load.printers = null;
                self.labelPrinters(model);
                self.status = if (list.len == 0) "No printers are set up." else "";
            } else if (load.ppd) |file| {
                self.dropPpd();
                self.ppd = file;
                load.ppd = null;
                self.ppd_queue = load.queue;
                load.queue = null;
                self.status = "";
                self.preparePpd(model) catch {
                    self.status = "Could not read the printer's options.";
                };
            }
            self.freeLoad(load);
        }
        if (!self.requested) {
            self.requested = true;
            self.restore(model);
            self.startLoad(null);
            return;
        }
        // The chosen printer's PPD, once.
        const queue = self.queueName() orelse return;
        if (self.ppd_queue) |loaded| if (std.mem.eql(u8, loaded, queue)) return;
        if (self.load == null and std.mem.eql(u8, self.status, "")) self.startLoad(queue);
    }

    /// The layout and colour choices saved in processing.toml.
    fn restore(self: *PrintPanel, model: *const State) void {
        if (savedString(model, "print_layout")) |name| {
            if (prints.sizeIndex(name)) |i| self.layout_index = @intCast(i + 1);
        }
        self.fill = model.processing_config.flag("print_fill");
        self.perceptual = model.processing_config.flag("print_perceptual");
        if (model.processing_config.value("print_black_point")) |value| self.bpc = value.asFloat() != 0.0;
    }

    fn labelPrinters(self: *PrintPanel, model: *const State) void {
        const labels = self.allocator.alloc([*:0]const u8, self.printers.len) catch return;
        for (self.printers, labels) |printer, *label| {
            const owned: [:0]const u8 = self.allocator.dupeZ(u8, printer.info) catch "";
            label.* = owned.ptr;
        }
        self.printer_labels = labels;
        self.printer_index = 0;
        if (savedString(model, "print_printer")) |saved| {
            for (self.printers, 0..) |printer, i| if (std.mem.eql(u8, printer.name, saved)) {
                self.printer_index = @intCast(i);
            };
        }
    }

    pub fn queueName(self: *const PrintPanel) ?[]const u8 {
        if (self.printers.len == 0) return null;
        return self.printers[@intCast(self.printer_index)].name;
    }

    fn preparePpd(self: *PrintPanel, model: *const State) !void {
        const file = &self.ppd.?;
        const a = self.arena.allocator();
        if (printing.setup.mediaOption(file)) |option| self.paper = try pulldown(a, option, savedString(model, "print_paper"));
        var others: [4]*const printing.ppd.Option = undefined;
        self.paper_others = try a.dupe(*const printing.ppd.Option, printing.setup.paperOptions(file, &others));
        if (printing.setup.qualityOption(file)) |option| {
            if (!std.mem.eql(u8, option.keyword, "Resolution")) self.quality = try pulldown(a, option, savedString(model, "print_quality"));
        }
        if (file.option("Resolution")) |option| self.resolution = try pulldown(a, option, savedString(model, "print_resolution"));
        if (file.option("PageSize")) |option| self.page_size = try pulldown(a, option, savedString(model, "print_page_size"));

        // The driver's profiles, then any other RGB printer profiles
        // installed with ColorSync.
        var list: std.ArrayList(Profile) = .empty;
        for (file.profiles) |profile| try list.append(a, .{ .label = try a.dupeZ(u8, profile.label), .path = profile.path });
        try appendColorSyncProfiles(a, self.io, &list);
        self.profiles = list.items;
        const labels = try a.alloc([*:0]const u8, list.items.len + 1);
        labels[0] = "For the paper";
        for (list.items, labels[1..]) |profile, *label| label.* = profile.label.ptr;
        self.profile_labels = labels;
        self.profile_index = 0;
        if (savedString(model, "print_profile")) |saved| {
            for (list.items, 0..) |profile, i| if (std.mem.eql(u8, profile.label, saved)) {
                self.profile_index = @intCast(i + 1);
            };
        }
    }

    /// The profile in use: the chosen one, or the driver's for the paper.
    pub fn activeProfile(self: *const PrintPanel) ?Profile {
        if (self.profile_index > 0) return self.profiles[@intCast(self.profile_index - 1)];
        const file = &(self.ppd orelse return null);
        const paper = self.paper orelse return null;
        const label = paper.option.choices[@intCast(paper.index)].label;
        const index = printing.setup.suggestProfile(file.profiles, label) orelse return null;
        return .{ .label = "", .path = file.profiles[index].path };
    }

    /// Picks the first paper the driver has a profile for (the UI smoke's
    /// soft proof); false when there is none.
    pub fn choosePaperWithProfile(self: *PrintPanel) bool {
        const file = &(self.ppd orelse return false);
        const paper = &(self.paper orelse return false);
        for (paper.option.choices, 0..) |choice, i| {
            if (printing.setup.suggestProfile(file.profiles, choice.label) != null) {
                paper.index = @intCast(i);
                return true;
            }
        }
        return false;
    }

    pub fn proofIntent(self: *const PrintPanel) icc.Options {
        return .{ .intent = if (self.perceptual) .perceptual else .relative_colorimetric, .black_point_compensation = self.bpc };
    }

    /// The print as chosen, for the export worker.
    pub fn order(self: *const PrintPanel) !PrintOrder {
        var result = PrintOrder{};
        try result.queue.set(self.queueName() orelse return error.NoPrinter);
        if (self.paper) |paper| {
            const choice = paper.option.choices[@intCast(paper.index)].keyword;
            for (self.paper_others) |option| if (option.choice(choice) != null) try result.addChoice(option.keyword, choice);
        }
        inline for (.{ "quality", "resolution", "page_size" }) |name| {
            if (@field(self, name)) |item| try result.addChoice(item.option.keyword, item.option.choices[@intCast(item.index)].keyword);
        }
        if (self.profile_index > 0) try result.profile_path.set(self.profiles[@intCast(self.profile_index - 1)].path);
        if (self.layout_index > 0) {
            const size = prints.sizes[@intCast(self.layout_index - 1)];
            result.placement.size_in = .{ size.short_in, size.long_in };
        }
        result.placement.fill = self.fill;
        result.color = self.proofIntent();
        result.copies = @intCast(self.copies);
        return result;
    }

    /// Draws the section; `.print` when Print This Frame is pressed.
    pub fn draw(self: *PrintPanel, ctx: *c.struct_nk_context, model: *State, allocator: std.mem.Allocator, config_path: []const u8, busy: bool, frame_aspect: f64) Action {
        layoutRow(ctx, 24.0, 1);
        c.nk_label(ctx, "Print", c.NK_TEXT_LEFT);
        if (self.status.len > 0) chrome.drawWrappedText(ctx, self.status);
        if (self.printers.len == 0) return .none;
        const metrics = chrome.runtime_ui_config.metrics();
        const item_height: c_int = @intFromFloat(metrics.row(24.0));
        const wide = c.nk_vec2(metrics.row(320.0), metrics.row(360.0));

        // Pulldowns carry no tooltip: a window has one popup, and a
        // tooltip over a pulldown takes it, so the list never opens. Their
        // labels carry the help instead.
        layoutRow(ctx, 28.0, 2);
        tooltip(ctx, "The printer to send to");
        c.nk_label(ctx, "Printer", c.NK_TEXT_LEFT);
        const printer = c.nk_combo(ctx, self.printer_labels.ptr, @intCast(self.printer_labels.len), self.printer_index, item_height, wide);
        if (printer != self.printer_index) {
            self.printer_index = printer;
            self.dropPpd();
            self.save(model, allocator, config_path, "print_printer", self.queueName().?);
        }
        const file = &(self.ppd orelse {
            if (self.load != null) chrome.drawWrappedText(ctx, "Reading the printer's options...");
            return .none;
        });
        if (!file.takesRaster()) {
            chrome.drawWrappedText(ctx, "This printer's driver does not take raster, which colour-managed printing sends. Print the exported file from another app.");
            return .none;
        }

        if (self.paper) |*paper| self.drawPulldown(ctx, model, allocator, config_path, paper, "Paper", "print_paper", "The paper in the printer: the driver prints for it, and its ICC profile converts the frame", item_height, wide);
        if (self.quality) |*quality| self.drawPulldown(ctx, model, allocator, config_path, quality, "Quality", "print_quality", "The driver's print quality", item_height, wide);
        if (self.resolution) |*resolution| self.drawPulldown(ctx, model, allocator, config_path, resolution, "Resolution", "print_resolution", "The resolution the frame is sent at; the driver's own presets use 720 dpi for photos", item_height, wide);
        if (self.page_size) |*page_size| self.drawPulldown(ctx, model, allocator, config_path, page_size, "Paper size", "print_page_size", "The sheet's size; borderless sizes print to the edges", item_height, wide);

        layoutRow(ctx, 28.0, 2);
        tooltip(ctx, "How large to print the frame: the whole printable area, or a print size, the frame fitted inside it uncropped (or filling it, below)");
        c.nk_label(ctx, "Print size", c.NK_TEXT_LEFT);
        const layout = c.nk_combo(ctx, &layout_labels, layout_labels.len, self.layout_index, item_height, wide);
        if (layout != self.layout_index) {
            self.layout_index = layout;
            self.save(model, allocator, config_path, "print_layout", if (layout == 0) "page" else prints.sizes[@intCast(layout - 1)].name);
        }
        layoutRow(ctx, 24.0, 1);
        tooltip(ctx, "Fill the print size, trimming the frame's edges, instead of fitting it whole");
        var fill = nkBool(self.fill);
        if (c.nk_checkbox_label(ctx, "Fill (trim edges)", &fill) != 0) {
            self.fill = fill != 0;
            self.saveFlag(model, allocator, config_path, "print_fill", self.fill);
        }

        layoutRow(ctx, 28.0, 2);
        tooltip(ctx, "The ICC profile for this printer, ink, and paper. \"For the paper\" takes the driver's profile matching the chosen paper");
        c.nk_label(ctx, "Profile", c.NK_TEXT_LEFT);
        const chosen_profile = c.nk_combo(ctx, self.profile_labels.ptr, @intCast(self.profile_labels.len), self.profile_index, item_height, wide);
        if (chosen_profile != self.profile_index) {
            self.profile_index = chosen_profile;
            self.save(model, allocator, config_path, "print_profile", if (chosen_profile == 0) "" else self.profiles[@intCast(chosen_profile - 1)].label);
        }
        const in_use = self.activeProfile();
        if (self.profile_index == 0) {
            var buffer: [256]u8 = undefined;
            chrome.drawWrappedText(ctx, if (in_use) |p| std.fmt.bufPrint(&buffer, "Using {s}", .{std.fs.path.stem(p.path)}) catch "" else "No driver profile matches this paper: choose one.");
        }
        layoutRow(ctx, 24.0, 2);
        tooltip(ctx, "Perceptual compresses every colour into the paper's range, keeping their relations; off (relative colorimetric) keeps colours the paper can print exactly and clips the rest");
        var perceptual = nkBool(self.perceptual);
        if (c.nk_checkbox_label(ctx, "Perceptual", &perceptual) != 0) {
            self.perceptual = perceptual != 0;
            self.saveFlag(model, allocator, config_path, "print_perceptual", self.perceptual);
        }
        tooltip(ctx, "Black point compensation: maps the frame's black to the paper's deepest black, so shadows keep their detail");
        var bpc = nkBool(self.bpc);
        if (c.nk_checkbox_label(ctx, "Black point", &bpc) != 0) {
            self.bpc = bpc != 0;
            self.saveFlag(model, allocator, config_path, "print_black_point", self.bpc);
        }

        layoutRow(ctx, 24.0, 2);
        tooltip(ctx, "Preview the frame as it will print on this paper with this profile");
        var proof = nkBool(self.soft_proof);
        if (c.nk_checkbox_label(ctx, "Soft proof", &proof) != 0) self.soft_proof = proof != 0;
        tooltip(ctx, "In the soft proof, show the paper's own white and black instead of the screen's");
        var paper_white = nkBool(self.paper_white);
        if (c.nk_checkbox_label(ctx, "Paper white", &paper_white) != 0) self.paper_white = paper_white != 0;

        if (printing.setup.colorOff(file) == null) {
            chrome.drawWrappedText(ctx, "No driver setting to turn its own colour adjustment off was found; the print may be adjusted twice.");
        }
        if (self.pageSummary(file, frame_aspect)) |summary| chrome.drawWrappedText(ctx, summary);

        layoutRow(ctx, 30.0, 2);
        c.nk_property_int(ctx, "Copies", 1, &self.copies, 99, 1, 1);
        if (busy) {
            c.nk_label(ctx, "Exporting...", c.NK_TEXT_LEFT);
        } else {
            tooltip(ctx, "Exports this frame with its look, then sends it to the printer, converted to the paper's profile");
            if (c.nk_button_label(ctx, "Print This Frame") != 0) {
                if (in_use == null) {
                    model.setStatus("Choose a profile for this paper first");
                    return .none;
                }
                return .print;
            }
        }
        return .none;
    }

    var summary_buffer: [160]u8 = undefined;

    fn pageSummary(self: *const PrintPanel, file: *const printing.ppd.Ppd, frame_aspect: f64) ?[]const u8 {
        var chosen: [3]printing.setup.Chosen = undefined;
        var count: usize = 0;
        inline for (.{ "resolution", "page_size" }) |name| {
            if (@field(self, name)) |item| {
                chosen[count] = .{ .keyword = item.option.keyword, .choice = item.option.choices[@intCast(item.index)].keyword };
                count += 1;
            }
        }
        const page = printing.setup.page(file, chosen[0..count]) catch return null;
        const order_value = self.order() catch return null;
        const width: usize = @intFromFloat(@round(1000.0 * @max(frame_aspect, 1.0 / 1000.0)));
        const placed = printing.job.layout(page, width, 1000, order_value.placement);
        return std.fmt.bufPrint(&summary_buffer, "Prints {d:.2} x {d:.2} in on a {d:.2} x {d:.2} in sheet{s}{s}.", .{
            placed.size_in[0],
            placed.size_in[1],
            page.width_pt / 72.0,
            page.height_pt / 72.0,
            if (placed.turned) ", turned" else "",
            if (placed.shrunk) ", shrunk to the printable area" else "",
        }) catch null;
    }

    fn drawPulldown(
        self: *PrintPanel,
        ctx: *c.struct_nk_context,
        model: *State,
        allocator: std.mem.Allocator,
        config_path: []const u8,
        item: *Pulldown,
        label: [*:0]const u8,
        setting: []const u8,
        help: []const u8,
        item_height: c_int,
        size: c.struct_nk_vec2,
    ) void {
        layoutRow(ctx, 28.0, 2);
        tooltip(ctx, help);
        c.nk_label(ctx, label, c.NK_TEXT_LEFT);
        if (std.mem.eql(u8, setting, "print_paper")) {
            self.paper_rect = c.nk_widget_bounds(ctx);
            self.item_height = @floatFromInt(item_height);
        }
        const index = c.nk_combo(ctx, item.labels.ptr, @intCast(item.labels.len), item.index, item_height, size);
        if (index != item.index) {
            item.index = index;
            self.save(model, allocator, config_path, setting, item.option.choices[@intCast(index)].keyword);
        }
    }

    fn saveFlag(self: *PrintPanel, model: *State, allocator: std.mem.Allocator, config_path: []const u8, name: []const u8, value: bool) void {
        const updates = [_]config.Override{.{ .name = name, .value = .{ .boolean = value } }};
        model.saveProcessingSettings(allocator, self.io, config_path, &updates) catch {};
    }

    fn save(self: *PrintPanel, model: *State, allocator: std.mem.Allocator, config_path: []const u8, name: []const u8, value: []const u8) void {
        const fixed = config.FixedString.from(value) catch return;
        const updates = [_]config.Override{.{ .name = name, .value = .{ .string = fixed } }};
        model.saveProcessingSettings(allocator, self.io, config_path, &updates) catch {};
    }
};

const layout_labels = blk: {
    var labels: [prints.sizes.len + 1][*:0]const u8 = undefined;
    labels[0] = "Printable area";
    for (prints.sizes, 1..) |size, i| labels[i] = size.label.ptr;
    break :blk labels;
};

fn pulldown(a: std.mem.Allocator, option: *const printing.ppd.Option, saved: ?[]const u8) !Pulldown {
    const labels = try a.alloc([*:0]const u8, option.choices.len);
    for (option.choices, labels) |choice, *label| label.* = (try a.dupeZ(u8, choice.label)).ptr;
    const wanted = saved orelse option.default;
    const index = option.choiceIndex(wanted) orelse option.choiceIndex(option.default) orelse 0;
    return .{ .option = option, .labels = labels, .index = @intCast(index) };
}

fn savedString(model: *const State, name: []const u8) ?[]const u8 {
    const value = model.processing_config.value(name) orelse return null;
    return switch (value) {
        .string => |*text| if (text.len == 0) null else text.slice(),
        else => null,
    };
}

/// RGB output (printer) profiles installed for ColorSync, by description.
fn appendColorSyncProfiles(a: std.mem.Allocator, io: std.Io, list: *std.ArrayList(Profile)) !void {
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = std.c.getenv("HOME");
    const user_dir = if (home) |h| std.fmt.bufPrint(&home_buffer, "{s}/Library/ColorSync/Profiles", .{std.mem.span(h)}) catch null else null;
    const dirs = [_]?[]const u8{ user_dir, "/Library/ColorSync/Profiles" };
    for (dirs) |maybe| {
        const dir_path = maybe orelse continue;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".icc") and !std.mem.endsWith(u8, entry.name, ".icm")) continue;
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, entry.name });
            const opened = icc.Profile.openFile(path) catch continue;
            defer opened.deinit();
            if (opened.deviceClass() != .output or !opened.isRgb()) continue;
            var name_buffer: [256]u8 = undefined;
            const description = opened.description(&name_buffer);
            const known = for (list.items) |existing| {
                if (std.mem.eql(u8, existing.label, description)) break true;
            } else false;
            if (!known) try list.append(a, .{ .label = try a.dupeZ(u8, if (description.len > 0) description else entry.name), .path = path });
        }
    }
}
