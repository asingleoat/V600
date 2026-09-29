//! `v600-zig roll ...`: scan a film roll strip by strip. Each strip is one
//! action (preview, film area, roll LUT, full scan), and finished strips are
//! processed in the background while the next one scans.

const std = @import("std");
const builtin = @import("builtin");
const v600 = @import("v600");

const Roll = v600.roll.Roll;
const events = v600.scanner.events;
const film_lut = v600.scanner.film_lut;
const scanner_config = v600.scanner.config;
const processing_config = v600.processing.config;

pub const scans_root = "scans";
pub const frames_root = "frames";
const preview_path = scans_root ++ "/preview.tiff";
const preview_dpi: u32 = 400;

pub fn handle(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    args: *std.process.Args.Iterator,
    stdout: anytype,
) !void {
    const subcommand = args.next() orelse {
        printUsage();
        return error.MissingRollCommand;
    };
    var rest = std.array_list.Managed([]const u8).init(allocator);
    defer rest.deinit();
    while (args.next()) |arg| try rest.append(arg);
    const argv = rest.items;

    if (std.mem.eql(u8, subcommand, "start")) {
        try runStart(allocator, io, argv, stdout);
    } else if (std.mem.eql(u8, subcommand, "use")) {
        if (argv.len != 1) return error.MissingRollName;
        var roll = try Roll.open(allocator, io, scans_root, frames_root, argv[0]);
        defer roll.deinit();
        try setCurrentRoll(allocator, io, roll.name);
        try stdout.print("Current roll: {s}\n", .{roll.name});
    } else if (std.mem.eql(u8, subcommand, "status")) {
        var roll = try openRoll(allocator, io, rollOption(argv));
        defer roll.deinit();
        try printStatus(allocator, io, &roll, stdout);
    } else if (std.mem.eql(u8, subcommand, "scan")) {
        try runScan(allocator, io, environ_map, argv, stdout);
    } else if (std.mem.eql(u8, subcommand, "export")) {
        try runExport(allocator, io, argv, stdout);
    } else if (std.mem.eql(u8, subcommand, "review")) {
        var roll = try openRoll(allocator, io, rollOption(argv));
        defer roll.deinit();
        try roll.writeReviewIndex(io);
        const index = try roll.path(allocator, v600.roll.review_dir_name ++ "/index.html");
        defer allocator.free(index);
        try stdout.print("{s}\n", .{index});
        if (hasFlag(argv, "--open")) openInBrowser(allocator, io, index);
    } else {
        printUsage();
        return error.UnknownRollCommand;
    }
}

pub fn printUsage() void {
    std.debug.print(
        \\usage: v600-zig roll <command>
        \\
        \\commands:
        \\  start NAME [--stock NAME] [--format 35mm|645|6x6|6x7|6x9] [--dpi 800|1600|3200] [--kind rgb+ir|rgb]
        \\                                 create scans/NAME/ and make it the current roll
        \\                                 (defaults: kodak_gold, 35mm, 3200 dpi, rgb+ir)
        \\  use NAME                       make an existing roll current
        \\  status [--roll NAME]           settings, strips, and which are processed
        \\  scan [--roll NAME] [--once] [--no-process]
        \\                                 scan strips one at a time (preview, film area, roll
        \\                                 LUT, full scan) and process each in the background
        \\  export [--roll NAME] [--force] detect and export every strip not yet processed
        \\  review [--roll NAME] [--open]  rewrite the roll's review page and print its path
        \\
        \\Exports go to frames/NAME/ as NAME_sNN_FF.tif (strip NN, frame FF).
        \\
    , .{});
}

fn runStart(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, stdout: anytype) !void {
    if (argv.len == 0 or std.mem.startsWith(u8, argv[0], "--")) return error.MissingRollName;
    var settings = v600.roll.Settings{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        index += 1;
        if (index >= argv.len) return error.MissingRollOptionValue;
        const value = argv[index];
        if (std.mem.eql(u8, arg, "--stock")) {
            settings.stock = value;
        } else if (std.mem.eql(u8, arg, "--format")) {
            settings.format = value;
        } else if (std.mem.eql(u8, arg, "--dpi")) {
            settings.dpi = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--kind")) {
            settings.kind = v600.roll.kindFromName(value) orelse return error.InvalidRollSettings;
        } else {
            return error.UnknownRollOption;
        }
    }

    const loaded = try processing_config.loadFile(allocator, io, processing_config.config_file);
    if (loaded.availableStock(settings.stock) == null) {
        std.debug.print("Unknown film stock {s}. Built in: ", .{settings.stock});
        for (processing_config.builtin_stocks, 0..) |stock, stock_index| {
            std.debug.print("{s}{s}", .{ if (stock_index == 0) "" else ", ", stock.name });
        }
        std.debug.print("; custom stocks come from {s}.\n", .{processing_config.config_file});
        return error.UnknownFilmStock;
    }

    var roll = try Roll.create(allocator, io, scans_root, frames_root, argv[0], settings);
    defer roll.deinit();
    try setCurrentRoll(allocator, io, roll.name);
    try stdout.print("Roll {s}: {s}, {s}, {d} dpi {s}. Scans go to {s}/, exports to {s}/.\n", .{
        roll.name,
        roll.stock,
        roll.format,
        roll.dpi,
        v600.roll.kindName(roll.kind),
        roll.dir,
        roll.frames_dir,
    });
    try stdout.print("Next: v600-zig roll scan\n", .{});
}

fn printStatus(allocator: std.mem.Allocator, io: std.Io, roll: *const Roll, stdout: anytype) !void {
    try stdout.print("Roll {s}: {s}, {s}, {d} dpi {s}\n", .{ roll.name, roll.stock, roll.format, roll.dpi, v600.roll.kindName(roll.kind) });
    try stdout.print("LUT: {s}\n", .{if (roll.lut_white != null) "fixed by the first strip" else "not set yet"});
    if (roll.dmin) |dmin| try stdout.print("Dmin: {d:.3} / {d:.3} / {d:.3}\n", .{ dmin[0], dmin[1], dmin[2] });
    var strips = try roll.listStrips(io);
    defer strips.deinit(allocator);
    if (strips.paths.len == 0) try stdout.print("No strips yet.\n", .{});
    for (strips.paths) |strip| {
        try stdout.print("  {s}  {s}\n", .{ std.fs.path.basename(strip), if (roll.isProcessed(io, strip)) "processed" else "not processed" });
    }
}

fn runExport(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, stdout: anytype) !void {
    var roll = try openRoll(allocator, io, rollOption(argv));
    defer roll.deinit();
    const force = hasFlag(argv, "--force");
    var strips = try roll.listStrips(io);
    defer strips.deinit(allocator);
    var processed: usize = 0;
    for (strips.paths) |strip| {
        if (!force and roll.isProcessed(io, strip)) continue;
        const started = nowSeconds(io);
        const outcome = roll.processStrip(io, strip, .{}) catch |err| {
            try stdout.print("{s}: failed ({s})\n", .{ std.fs.path.basename(strip), @errorName(err) });
            try stdout.flush();
            continue;
        };
        defer outcome.deinit(allocator);
        processed += 1;
        try printOutcome(stdout, strip, outcome, nowSeconds(io) - started);
        try stdout.flush();
    }
    try stdout.print("{d} strip{s} processed. Review: {s}/{s}/index.html\n", .{
        processed,
        if (processed == 1) "" else "s",
        roll.dir,
        v600.roll.review_dir_name,
    });
}

fn printOutcome(stdout: anytype, strip: []const u8, outcome: v600.roll.StripOutcome, seconds: i64) !void {
    try stdout.print("{s}: {d} frame{s} exported, Dmin from {s} ({d}s)\n", .{
        std.fs.path.basename(strip),
        outcome.files.len,
        if (outcome.files.len == 1) "" else "s",
        outcome.dmin_source,
        seconds,
    });
}

fn runScan(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    argv: []const []const u8,
    stdout: anytype,
) !void {
    var roll = try openRoll(allocator, io, rollOption(argv));
    defer roll.deinit();
    const once = hasFlag(argv, "--once");
    const process = !hasFlag(argv, "--no-process");

    events.echo_to_stderr = false;
    defer events.echo_to_stderr = true;
    var progress = ProgressLine{};
    const runtime = v600.scanner.host.Runtime{
        .allocator = allocator,
        .io = io,
        .environ_map = environ_map,
        .event_sink = progress.sink(),
    };

    const processor: ?*Processor = if (process) try Processor.start(io, roll.name) else null;
    defer if (processor) |worker| worker.finish(stdout);

    try stdout.print("Roll {s}: {s}, {s}, {d} dpi {s}.\n", .{ roll.name, roll.stock, roll.format, roll.dpi, v600.roll.kindName(roll.kind) });
    try stdout.flush();
    var stdin_buffer: [256]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    while (true) {
        const number = try v600.tiff.nextScanNumber(io, roll.dir, v600.roll.strip_prefix);
        if (!once) {
            try stdout.print("Load strip {d} and press Enter (q to finish): ", .{number});
            try stdout.flush();
            const line = (stdin_reader.interface.takeDelimiter('\n') catch null) orelse break;
            const answer = std.mem.trim(u8, line, " \t\r");
            if (std.mem.eql(u8, answer, "q") or std.mem.eql(u8, answer, "quit")) break;
        }
        progress.strip = number;
        const started = nowSeconds(io);
        const strip_path = scanStrip(allocator, io, &roll, runtime, stdout) catch |err| {
            progress.finishLine();
            try stdout.print("Strip {d} failed: {s}\n", .{ number, @errorName(err) });
            if (builtin.os.tag == .macos and busyError(err)) try stdout.print("{s}\n", .{v600.scanner.interpreter_runtime.busy_hint});
            try stdout.flush();
            if (once) return err;
            continue;
        };
        progress.finishLine();
        const seconds: u64 = @intCast(@max(0, nowSeconds(io) - started));
        try stdout.print("Strip {d} saved: {s} ({d}m{d:0>2}s).{s}\n", .{
            number,
            strip_path,
            seconds / 60,
            seconds % 60,
            if (processor != null) " Processing it in the background." else "",
        });
        try stdout.flush();
        notify(allocator, io, number);
        if (processor) |worker| {
            worker.enqueue(allocator, strip_path);
        } else {
            allocator.free(strip_path);
        }
        if (once) break;
    }
}

/// Preview, find the film, apply the roll LUT, and scan the next strip.
/// Returns the strip's path, which the caller frees.
fn scanStrip(
    allocator: std.mem.Allocator,
    io: std.Io,
    roll: *Roll,
    runtime: v600.scanner.host.Runtime,
    stdout: anytype,
) ![]u8 {
    var preview = try scanPreview(allocator, io, runtime);
    defer preview.deinit(allocator);
    const area = preview.area orelse return error.NoFilmFound;
    const selection = preview.selection.?;
    try stdout.print("Film area: x {d:.3}, y {d:.3}, {d:.3} x {d:.3} in\n", .{ area.x, area.y, area.w, area.h });
    try stdout.flush();

    // The interpreter backend applies gamma LUTs; the Linux path does not.
    var lut_file: ?[]u8 = null;
    defer if (lut_file) |file| allocator.free(file);
    if (builtin.os.tag == .macos) {
        const film_selection = film_lut.Selection{ .x = selection.x, .y = selection.y, .w = selection.w, .h = selection.h };
        const image = preview.image;
        const computed = try film_lut.computeFilmLuts(allocator, image.data, image.width, image.height, image.samples_per_pixel, film_selection, v600.roll.lut_options);
        const first_strip = roll.lut_white == null;
        if (try roll.adoptLut(io, computed)) |_| {
            lut_file = try roll.path(allocator, v600.roll.lut_name);
            if (!first_strip) {
                const own = try film_lut.computeFilmLuts(allocator, image.data, image.width, image.height, image.samples_per_pixel, film_selection, v600.roll.fit_options);
                const fit = roll.checkLutFit(own);
                if (!fit.ok()) try printFitWarning(stdout, fit);
            }
        }
    }

    const strip_path = try roll.nextStripPath(io);
    errdefer allocator.free(strip_path);
    try runtime.scan(.{
        .request = .{
            .dpi = roll.dpi,
            .source = .tpu,
            .kind = roll.kind,
            .depth = .sixteen,
            .area = .{ .x = area.x, .y = area.y, .width = area.w, .height = area.h },
            .output_path = strip_path,
            .lut_file_path = lut_file,
        },
        .output_path = strip_path,
    });
    return strip_path;
}

fn printFitWarning(stdout: anytype, fit: v600.roll.LutFit) !void {
    const names = [_][]const u8{ "red", "green", "blue" };
    for (0..3) |channel| {
        if (fit.dense_clipped[channel]) try stdout.print("Warning: this strip's densest {s} is beyond the roll LUT; some highlights will clip.\n", .{names[channel]});
        if (fit.base_clipped[channel]) try stdout.print("Warning: this strip's film base in {s} is brighter than the roll LUT's white point and will clip.\n", .{names[channel]});
    }
    try stdout.print("Consider starting a new roll for strips cut from a different film.\n", .{});
}

pub const Preview = struct {
    image: v600.tiff.Image,
    /// Film area in preview pixels, with the clear margin.
    selection: ?v600.native_ui.PreviewSelection,
    /// The same area in the inch coordinates a scan takes.
    area: ?v600.native_ui.ScanAreaInches,

    pub fn deinit(self: *Preview, allocator: std.mem.Allocator) void {
        self.image.deinit(allocator);
    }
};

/// Scans the whole transparency unit at 400 dpi, 8-bit, to `scans/preview.tiff`
/// and finds the film area.
pub fn scanPreview(allocator: std.mem.Allocator, io: std.Io, runtime: v600.scanner.host.Runtime) !Preview {
    try std.Io.Dir.cwd().createDirPath(io, scans_root);
    try runtime.scan(.{
        .request = .{ .dpi = preview_dpi, .source = .tpu, .kind = .rgb, .depth = .eight },
        .output_path = preview_path,
    });
    return loadPreview(allocator, preview_path);
}

pub fn loadPreview(allocator: std.mem.Allocator, path: []const u8) !Preview {
    const image = try v600.tiff.loadRgbPage(allocator, path);
    errdefer image.deinit(allocator);
    const dpi: f64 = @floatFromInt(v600.scanner.sane.effectiveDpiForRequest(.{ .dpi = preview_dpi, .source = .tpu }));
    const info = v600.app_state.ScannerInfo{
        .preview_width = image.width,
        .preview_height = image.height,
        .tpu_width_in = @as(f64, @floatFromInt(image.width)) / dpi,
        .tpu_height_in = @as(f64, @floatFromInt(image.height)) / dpi,
        .scan_counter = 0,
    };
    const selection = try v600.native_ui.detectFilmAreaSelection(
        allocator,
        image.data,
        image.width,
        image.height,
        image.samples_per_pixel,
        @intFromFloat(dpi),
        info.tpu_width_in,
        info.tpu_height_in,
        .{},
    );
    const controls = v600.native_ui.ScanControls{ .selection = selection };
    return .{ .image = image, .selection = selection, .area = controls.selectionForScanStart(info) };
}

/// One-line scan progress on stderr.
const ProgressLine = struct {
    strip: usize = 0,
    pass: []const u8 = "",
    dpi: u32 = 0,
    open: bool = false,

    fn sink(self: *ProgressLine) events.Sink {
        return .{ .context = self, .emit = emit };
    }

    fn emit(context: *anyopaque, event: events.Event) void {
        const self: *ProgressLine = @ptrCast(@alignCast(context));
        switch (event) {
            .scan_start => |start| {
                self.finishLine();
                self.pass = switch (start.kind) {
                    .ir => "IR",
                    .gray => "gray",
                    else => if (start.effective_dpi == preview_dpi and start.requested_dpi == preview_dpi) "preview" else "RGB",
                };
                self.dpi = start.effective_dpi;
                std.debug.print("Strip {d}: {s} {d} dpi...", .{ self.strip, self.pass, self.dpi });
                self.open = true;
            },
            .progress => |progress| {
                std.debug.print("\rStrip {d}: {s} {d} dpi {d:>3}%", .{ self.strip, self.pass, self.dpi, progress.percent });
                self.open = true;
            },
            .scan_complete, .scan_error, .scan_cancelled => self.finishLine(),
            else => {},
        }
    }

    fn finishLine(self: *ProgressLine) void {
        if (self.open) std.debug.print("\n", .{});
        self.open = false;
    }
};

/// Processes finished strips one at a time on a background thread.
const Processor = struct {
    const allocator = std.heap.smp_allocator;

    io: std.Io,
    roll_name: []u8,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    queue: std.array_list.Managed([]u8),
    closing: bool = false,
    busy: bool = false,
    thread: std.Thread = undefined,

    fn start(io: std.Io, roll_name: []const u8) !*Processor {
        const self = try allocator.create(Processor);
        errdefer allocator.destroy(self);
        self.* = .{
            .io = io,
            .roll_name = try allocator.dupe(u8, roll_name),
            .queue = std.array_list.Managed([]u8).init(allocator),
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Queues a copy of `strip_path` and frees the original with
    /// `path_allocator`, which made it.
    fn enqueue(self: *Processor, path_allocator: std.mem.Allocator, strip_path: []u8) void {
        defer path_allocator.free(strip_path);
        const owned = allocator.dupe(u8, strip_path) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.queue.append(owned) catch {
            allocator.free(owned);
            return;
        };
        self.condition.signal(self.io);
    }

    /// Waits for queued strips, then stops the thread.
    fn finish(self: *Processor, stdout: anytype) void {
        self.mutex.lockUncancelable(self.io);
        const pending = self.queue.items.len + @intFromBool(self.busy);
        self.closing = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        if (pending != 0) {
            stdout.print("Waiting for {d} strip{s} to finish processing...\n", .{ pending, if (pending == 1) "" else "s" }) catch {};
            stdout.flush() catch {};
        }
        self.thread.join();
        stdout.print("Review: {s}/{s}/{s}/index.html\n", .{ scans_root, self.roll_name, v600.roll.review_dir_name }) catch {};
        stdout.flush() catch {};
        self.queue.deinit();
        allocator.free(self.roll_name);
        allocator.destroy(self);
    }

    fn run(self: *Processor) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.queue.items.len == 0 and !self.closing) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.queue.items.len == 0) {
                self.mutex.unlock(self.io);
                return;
            }
            const strip = self.queue.orderedRemove(0);
            self.busy = true;
            self.mutex.unlock(self.io);

            self.process(strip);
            allocator.free(strip);

            self.mutex.lockUncancelable(self.io);
            self.busy = false;
            self.mutex.unlock(self.io);
        }
    }

    fn process(self: *Processor, strip: []const u8) void {
        // A fresh Roll per strip picks up the Dmin earlier strips recorded.
        var roll = Roll.open(allocator, self.io, scans_root, frames_root, self.roll_name) catch |err| {
            std.debug.print("\n[processing] {s}: cannot open roll ({s})\n", .{ std.fs.path.basename(strip), @errorName(err) });
            return;
        };
        defer roll.deinit();
        const started = nowSeconds(self.io);
        const outcome = roll.processStrip(self.io, strip, .{}) catch |err| {
            std.debug.print("\n[processing] {s}: failed ({s})\n", .{ std.fs.path.basename(strip), @errorName(err) });
            return;
        };
        defer outcome.deinit(allocator);
        std.debug.print("\n[processing] {s}: {d} frame{s} exported, Dmin from {s} ({d}s)\n", .{
            std.fs.path.basename(strip),
            outcome.files.len,
            if (outcome.files.len == 1) "" else "s",
            outcome.dmin_source,
            nowSeconds(self.io) - started,
        });
    }
};

fn openRoll(allocator: std.mem.Allocator, io: std.Io, name: ?[]const u8) !Roll {
    if (name) |roll_name| return Roll.open(allocator, io, scans_root, frames_root, roll_name);
    const config_path = scans_root ++ "/" ++ scanner_config.file_name;
    const loaded = try scanner_config.loadFile(allocator, io, config_path);
    if (!loaded.active.roll or loaded.values.roll.len == 0) {
        std.debug.print("No current roll: start one with `v600-zig roll start NAME` or pass --roll NAME.\n", .{});
        return error.NoCurrentRoll;
    }
    return Roll.open(allocator, io, scans_root, frames_root, loaded.values.roll.slice());
}

fn setCurrentRoll(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, scans_root);
    var updates = scanner_config.LoadedConfig{};
    try updates.values.roll.set(name);
    updates.active.roll = true;
    try scanner_config.saveFile(allocator, io, scans_root ++ "/" ++ scanner_config.file_name, updates);
}

fn rollOption(argv: []const []const u8) ?[]const u8 {
    for (argv, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--roll") and index + 1 < argv.len) return argv[index + 1];
    }
    return null;
}

fn hasFlag(argv: []const []const u8, flag: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

fn busyError(err: anyerror) bool {
    return err == error.ScannerBusy or err == error.ScannerAccessDenied;
}

/// Terminal bell plus, on macOS, a notification with a sound.
fn notify(allocator: std.mem.Allocator, io: std.Io, strip: usize) void {
    std.debug.print("\x07", .{});
    if (builtin.os.tag != .macos) return;
    const script = std.fmt.allocPrint(allocator, "display notification \"Strip {d} scanned. Load the next strip.\" with title \"V600\" sound name \"Glass\"", .{strip}) catch return;
    defer allocator.free(script);
    const result = std.process.run(allocator, io, .{ .argv = &.{ "osascript", "-e", script } }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn openInBrowser(allocator: std.mem.Allocator, io: std.Io, path: []const u8) void {
    const opener = if (builtin.os.tag == .macos) "open" else "xdg-open";
    const result = std.process.run(allocator, io, .{ .argv = &.{ opener, path } }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn nowSeconds(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}
