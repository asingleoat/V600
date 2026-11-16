//! `cerealgrain print ...`: colour-managed printing of exported frames.

const std = @import("std");
const cerealgrain = @import("cerealgrain");

const printing = cerealgrain.printing;
const icc = cerealgrain.processing.icc;
const prints = cerealgrain.processing.print;

pub fn handle(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: *std.process.Args.Iterator,
    stdout: *std.Io.Writer,
) !void {
    const subcommand = args.next() orelse {
        printUsage();
        return error.MissingPrintCommand;
    };
    if (std.mem.eql(u8, subcommand, "printers")) return listPrinters(allocator, stdout);
    if (std.mem.eql(u8, subcommand, "options")) return showOptions(allocator, io, args, stdout);
    if (std.mem.eql(u8, subcommand, "file")) return printFile(allocator, io, args, stdout);
    printUsage();
    return error.UnknownPrintCommand;
}

fn printUsage() void {
    std.debug.print(
        \\usage: cerealgrain print <command>
        \\
        \\commands:
        \\  printers                       list print queues
        \\  options --printer QUEUE        a printer's papers, qualities, sizes, and profiles
        \\  file TIFF --printer QUEUE      print an exported frame, colour-managed:
        \\      --paper CHOICE             media type (choice or its name)
        \\      --quality CHOICE           print quality
        \\      --resolution CHOICE        raster resolution (360x360dpi, 720x720dpi, ...)
        \\      --page-size NAME           paper size (PageSize choice or its name)
        \\      --option KEY=CHOICE        any other driver option (repeatable)
        \\      --profile FILE             the paper's ICC profile (default: the driver's for the paper)
        \\      --size SIZE                print size (4x6, 8x10, a4, ...), default the printable area
        \\      --fill                     fill the size, trimming the image, instead of fitting it
        \\      --intent INTENT            perceptual, relative_colorimetric (default), saturation, absolute_colorimetric
        \\      --no-bpc                   without black point compensation
        \\      --copies N
        \\      --raster-out FILE          write the page raster to FILE instead of printing
        \\      --ppd FILE                 read the printer's options from FILE instead of the queue
        \\
    , .{});
}

fn listPrinters(allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    const list = try printing.cups.destinations(allocator);
    defer printing.cups.freeDestinations(allocator, list);
    for (list) |dest| {
        try stdout.print("{s}{s}  {s}  {s}\n", .{ dest.name, if (dest.is_default) " (default)" else "", dest.info, dest.make_and_model });
    }
}

const Parsed = struct {
    queue: ?[]const u8 = null,
    ppd_path: ?[]const u8 = null,
    tiff: ?[]const u8 = null,
    paper: ?[]const u8 = null,
    quality: ?[]const u8 = null,
    resolution: ?[]const u8 = null,
    page_size: ?[]const u8 = null,
    options: std.ArrayList([]const u8) = .empty,
    profile: ?[]const u8 = null,
    size: ?[]const u8 = null,
    fill: bool = false,
    intent: icc.Intent = .relative_colorimetric,
    bpc: bool = true,
    copies: u32 = 1,
    raster_out: ?[]const u8 = null,
};

fn parseArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !Parsed {
    var parsed = Parsed{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--printer")) {
            parsed.queue = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--ppd")) {
            parsed.ppd_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--paper")) {
            parsed.paper = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--quality")) {
            parsed.quality = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--resolution")) {
            parsed.resolution = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--page-size")) {
            parsed.page_size = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--option")) {
            try parsed.options.append(allocator, args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--profile")) {
            parsed.profile = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--size")) {
            parsed.size = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--fill")) {
            parsed.fill = true;
        } else if (std.mem.eql(u8, arg, "--intent")) {
            parsed.intent = icc.intentNamed(args.next() orelse return error.MissingValue) orelse return error.InvalidIntent;
        } else if (std.mem.eql(u8, arg, "--no-bpc")) {
            parsed.bpc = false;
        } else if (std.mem.eql(u8, arg, "--copies")) {
            parsed.copies = try std.fmt.parseInt(u32, args.next() orelse return error.MissingValue, 10);
            if (parsed.copies == 0 or parsed.copies > 99) return error.InvalidCopies;
        } else if (std.mem.eql(u8, arg, "--raster-out")) {
            parsed.raster_out = args.next() orelse return error.MissingValue;
        } else if (arg.len > 0 and arg[0] != '-' and parsed.tiff == null) {
            parsed.tiff = arg;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }
    return parsed;
}

fn loadPpd(allocator: std.mem.Allocator, io: std.Io, parsed: Parsed) !printing.ppd.Ppd {
    if (parsed.ppd_path) |path| return printing.ppd.load(allocator, io, path);
    const queue = parsed.queue orelse return error.MissingPrinter;
    const path = try printing.cups.ppdPath(allocator, queue);
    defer allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    return printing.ppd.load(allocator, io, path);
}

fn showOptions(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator, stdout: *std.Io.Writer) !void {
    var parsed = try parseArgs(allocator, args);
    defer parsed.options.deinit(allocator);
    var file = try loadPpd(allocator, io, parsed);
    defer file.deinit();
    try stdout.print("{s}: {s}\n", .{ file.nickname, if (file.takesRaster()) "takes CUPS raster (colour-managed printing works)" else "does not take CUPS raster" });
    if (printing.setup.colorOff(&file)) |off| {
        const option = file.option(off.keyword).?;
        try stdout.print("driver colour adjustment off: {s}={s} ({s}: {s})\n", .{ off.keyword, off.choice, option.label, option.choice(off.choice).?.label });
    } else try stdout.print("driver colour adjustment off: no option found; set it with --option\n", .{});
    if (printing.setup.mediaOption(&file)) |media| {
        try stdout.print("\npapers ({s}):\n", .{media.keyword});
        for (media.choices) |choice| {
            const suggestion = printing.setup.suggestProfile(file.profiles, choice.label);
            try stdout.print("  {s}  {s}{s}{s}\n", .{ choice.keyword, choice.label, if (suggestion != null) "  -> " else "", if (suggestion) |i| file.profiles[i].label else "" });
        }
    }
    if (file.option("Resolution")) |resolution| {
        try stdout.print("\nresolutions (Resolution, default {s}):\n", .{resolution.default});
        for (resolution.choices) |choice| try stdout.print("  {s}\n", .{choice.keyword});
    }
    if (printing.setup.qualityOption(&file)) |quality| {
        try stdout.print("\nqualities ({s}):\n", .{quality.keyword});
        for (quality.choices) |choice| try stdout.print("  {s}  {s}\n", .{ choice.keyword, choice.label });
    }
    if (file.option("PageSize")) |sizes| {
        try stdout.print("\npaper sizes (PageSize, default {s}):\n", .{sizes.default});
        for (sizes.choices) |choice| try stdout.print("  {s}  {s}\n", .{ choice.keyword, choice.label });
    }
    try stdout.print("\nprofiles:\n", .{});
    for (file.profiles) |profile| try stdout.print("  {s}  {s}\n", .{ profile.label, profile.path });
}

/// A choice of `option` by its keyword or its name.
fn findChoice(option: *const printing.ppd.Option, wanted: []const u8) ?[]const u8 {
    for (option.choices) |choice| if (std.mem.eql(u8, choice.keyword, wanted)) return choice.keyword;
    for (option.choices) |choice| if (std.ascii.eqlIgnoreCase(choice.label, wanted)) return choice.keyword;
    return null;
}

fn printFile(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator, stdout: *std.Io.Writer) !void {
    var parsed = try parseArgs(allocator, args);
    defer parsed.options.deinit(allocator);
    const tiff_path = parsed.tiff orelse return error.MissingInput;
    const queue = parsed.queue orelse return error.MissingPrinter;

    // The choices by keyword, read against the PPD.
    var file = try loadPpd(allocator, io, parsed);
    defer file.deinit();
    var choices: std.ArrayList(printing.setup.Chosen) = .empty;
    defer choices.deinit(allocator);
    if (parsed.paper) |paper| {
        const option = printing.setup.mediaOption(&file) orelse return error.PrinterHasNoPaperOption;
        const choice = findChoice(option, paper) orelse return error.UnknownPaper;
        var buffer: [4]*const printing.ppd.Option = undefined;
        for (printing.setup.paperOptions(&file, &buffer)) |each| {
            if (each.choice(choice) != null) try choices.append(allocator, .{ .keyword = each.keyword, .choice = choice });
        }
    }
    if (parsed.resolution) |resolution| {
        const option = file.option("Resolution") orelse return error.PrinterHasNoResolution;
        try choices.append(allocator, .{ .keyword = "Resolution", .choice = findChoice(option, resolution) orelse return error.UnknownResolution });
    }
    if (parsed.quality) |quality| {
        const option = printing.setup.qualityOption(&file) orelse return error.PrinterHasNoQualityOption;
        try choices.append(allocator, .{ .keyword = option.keyword, .choice = findChoice(option, quality) orelse return error.UnknownQuality });
    }
    if (parsed.page_size) |name| {
        const option = file.option("PageSize") orelse return error.PrinterHasNoPageSize;
        try choices.append(allocator, .{ .keyword = "PageSize", .choice = findChoice(option, name) orelse return error.UnknownPageSize });
    }
    for (parsed.options.items) |text| {
        const eq = std.mem.indexOfScalar(u8, text, '=') orelse return error.InvalidOption;
        try choices.append(allocator, .{ .keyword = text[0..eq], .choice = text[eq + 1 ..] });
    }
    var placement = printing.job.Placement{ .fill = parsed.fill };
    if (parsed.size) |name| {
        if (!std.mem.eql(u8, name, "page")) {
            const size = prints.sizeNamed(name) orelse return error.UnknownPrintSize;
            placement.size_in = .{ size.short_in, size.long_in };
        }
    }
    const request = printing.job.Request{
        .queue = queue,
        .choices = choices.items,
        .profile_path = parsed.profile,
        .placement = placement,
        .color = .{ .intent = parsed.intent, .black_point_compensation = parsed.bpc },
        .copies = parsed.copies,
        .ppd_path = parsed.ppd_path,
    };
    var prepared = try printing.job.prepare(allocator, io, request);
    defer prepared.deinit();
    const source = try printing.job.Source.loadTiff(allocator, tiff_path);
    defer source.deinit(allocator);
    const placed = printing.job.layout(prepared.page, source.width, source.height, placement);

    try stdout.print("printer: {s}\n", .{queue});
    for (prepared.chosen) |item| {
        const option = prepared.file.option(item.keyword).?;
        try stdout.print("  {s}: {s}\n", .{ option.label, option.choice(item.choice).?.label });
    }
    if (prepared.color_off == null) try stdout.print("  warning: no driver option to turn its colour adjustment off was found\n", .{});
    try stdout.print("profile: {s}\n  {s}\n", .{ prepared.profile_label, prepared.profile_path });
    try stdout.print("intent: {s}{s}\n", .{ request.color.intent.label(), if (request.color.black_point_compensation) ", black point compensation" else "" });
    try stdout.print("page: {d:.2} x {d:.2} in at {d} dpi{s}\n", .{ prepared.page.width_pt / 72.0, prepared.page.height_pt / 72.0, prepared.page.dpi, if (prepared.page.borderless_scale > 1.0) ", borderless" else "" });
    try stdout.print("print: {d:.2} x {d:.2} in{s}, {d:.0} ppi from the file{s}\n", .{ placed.size_in[0], placed.size_in[1], if (placed.turned) ", turned" else "", placed.source_ppi, if (placed.shrunk) " (shrunk to fit the printable area)" else "" });
    try stdout.flush();

    if (parsed.raster_out) |path| {
        try printing.job.writeFile(allocator, io, &prepared, &source, request, path);
        try stdout.print("wrote {s}\n", .{path});
        return;
    }
    const id = try printing.job.submit(allocator, &prepared, &source, request, std.fs.path.basename(tiff_path));
    try stdout.print("sent: job {d} on {s}\n", .{ id, queue });
}
