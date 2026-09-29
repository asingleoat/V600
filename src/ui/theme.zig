const std = @import("std");

pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

pub const ThemeName = enum {
    darkroom,
    lighttable,
    graphite,

    pub fn parse(value: []const u8) ?ThemeName {
        if (std.ascii.eqlIgnoreCase(value, "darkroom")) return .darkroom;
        if (std.ascii.eqlIgnoreCase(value, "lighttable")) return .lighttable;
        if (std.ascii.eqlIgnoreCase(value, "graphite")) return .graphite;
        return null;
    }
};

pub const Palette = struct {
    text: Rgba,
    muted_text: Rgba,
    window: Rgba,
    header: Rgba,
    border: Rgba,
    button: Rgba,
    button_hover: Rgba,
    button_active: Rgba,
    toggle: Rgba,
    toggle_hover: Rgba,
    toggle_cursor: Rgba,
    select: Rgba,
    select_active: Rgba,
    slider: Rgba,
    slider_cursor: Rgba,
    slider_cursor_hover: Rgba,
    property: Rgba,
    edit: Rgba,
    edit_cursor: Rgba,
    scrollbar: Rgba,
    scrollbar_cursor: Rgba,
    tab_header: Rgba,
    background: Rgba,
};

/// Default UI scale: 18 px text. V600_UI_SCALE overrides it.
pub const default_scale: f32 = 1.4;

pub const Config = struct {
    theme: ThemeName = .darkroom,
    scale: f32 = default_scale,

    pub fn fromEnvironment(environ_map: *std.process.Environ.Map) Config {
        var config = Config{};
        if (environ_map.get("V600_UI_THEME")) |value| {
            if (ThemeName.parse(value)) |theme| config.theme = theme;
        }
        if (environ_map.get("V600_UI_SCALE")) |value| {
            config.scale = parseScale(value) catch config.scale;
        }
        return config.normalized();
    }

    pub fn normalized(self: Config) Config {
        return .{
            .theme = self.theme,
            .scale = clampScale(self.scale),
        };
    }

    pub fn metrics(self: Config) Metrics {
        return Metrics.init(self.normalized().scale);
    }

    pub fn palette(self: Config) Palette {
        return switch (self.normalized().theme) {
            .darkroom => .{
                .text = rgb(232, 235, 232),
                .muted_text = rgb(160, 168, 168),
                .window = rgb(25, 28, 31),
                .header = rgb(36, 42, 46),
                .border = rgb(70, 82, 84),
                .button = rgb(42, 49, 52),
                .button_hover = rgb(54, 67, 68),
                .button_active = rgb(73, 94, 91),
                .toggle = rgb(45, 54, 56),
                .toggle_hover = rgb(57, 69, 70),
                .toggle_cursor = rgb(83, 176, 166),
                .select = rgb(46, 65, 65),
                .select_active = rgb(80, 142, 131),
                .slider = rgb(44, 54, 57),
                .slider_cursor = rgb(83, 176, 166),
                .slider_cursor_hover = rgb(231, 169, 82),
                .property = rgb(31, 36, 39),
                .edit = rgb(30, 35, 38),
                .edit_cursor = rgb(231, 169, 82),
                .scrollbar = rgb(30, 35, 38),
                .scrollbar_cursor = rgb(69, 85, 85),
                .tab_header = rgb(33, 39, 43),
                .background = rgb(20, 22, 25),
            },
            .lighttable => .{
                .text = rgb(35, 40, 43),
                .muted_text = rgb(93, 103, 107),
                .window = rgb(234, 236, 233),
                .header = rgb(218, 225, 222),
                .border = rgb(148, 159, 158),
                .button = rgb(217, 223, 220),
                .button_hover = rgb(203, 216, 212),
                .button_active = rgb(185, 208, 201),
                .toggle = rgb(205, 213, 211),
                .toggle_hover = rgb(192, 207, 203),
                .toggle_cursor = rgb(34, 129, 121),
                .select = rgb(194, 217, 212),
                .select_active = rgb(69, 151, 141),
                .slider = rgb(202, 211, 209),
                .slider_cursor = rgb(34, 129, 121),
                .slider_cursor_hover = rgb(177, 102, 48),
                .property = rgb(244, 245, 243),
                .edit = rgb(247, 248, 246),
                .edit_cursor = rgb(177, 102, 48),
                .scrollbar = rgb(211, 217, 215),
                .scrollbar_cursor = rgb(163, 174, 172),
                .tab_header = rgb(224, 229, 226),
                .background = rgb(215, 219, 216),
            },
            .graphite => .{
                .text = rgb(238, 239, 236),
                .muted_text = rgb(167, 170, 169),
                .window = rgb(31, 32, 34),
                .header = rgb(45, 47, 50),
                .border = rgb(81, 84, 88),
                .button = rgb(48, 50, 54),
                .button_hover = rgb(62, 65, 70),
                .button_active = rgb(84, 88, 95),
                .toggle = rgb(51, 53, 57),
                .toggle_hover = rgb(65, 68, 73),
                .toggle_cursor = rgb(196, 144, 83),
                .select = rgb(62, 66, 72),
                .select_active = rgb(116, 91, 61),
                .slider = rgb(50, 53, 58),
                .slider_cursor = rgb(196, 144, 83),
                .slider_cursor_hover = rgb(104, 173, 159),
                .property = rgb(36, 38, 41),
                .edit = rgb(34, 36, 39),
                .edit_cursor = rgb(104, 173, 159),
                .scrollbar = rgb(36, 38, 41),
                .scrollbar_cursor = rgb(76, 80, 86),
                .tab_header = rgb(41, 43, 47),
                .background = rgb(23, 24, 26),
            },
        };
    }
};

pub const Metrics = struct {
    scale: f32,
    font_size: f32,
    margin: f32,
    window_padding_x: f32,
    window_padding_y: f32,
    widget_spacing_x: f32,
    widget_spacing_y: f32,
    control_panel_width: f32,
    max_panel_width_fraction: f32,
    color_dot_radius: f32,
    rounding: f32,
    border: f32,
    scrollbar_width: f32,

    pub fn init(scale: f32) Metrics {
        const s = clampScale(scale);
        return .{
            .scale = s,
            .font_size = roundToHalf(13.0 * s),
            .margin = rounded(16.0 * s),
            .window_padding_x = rounded(10.0 * s),
            .window_padding_y = rounded(8.0 * s),
            .widget_spacing_x = rounded(6.0 * s),
            .widget_spacing_y = rounded(6.0 * s),
            .control_panel_width = rounded(560.0 * s),
            .max_panel_width_fraction = 0.62,
            .color_dot_radius = rounded(5.0 * s),
            .rounding = rounded(3.0 * s),
            .border = @max(1.0, rounded(1.0 * s)),
            .scrollbar_width = rounded(16.0 * s),
        };
    }

    pub fn row(self: Metrics, base_height: f32) f32 {
        return @max(1.0, rounded(base_height * self.scale));
    }

    pub fn panelHeight(self: Metrics, base_height: f32, window_height: f32) f32 {
        const max_height = @max(self.row(180.0), window_height - self.margin * 2.0);
        return @min(self.row(base_height), max_height);
    }

    pub fn panelWidth(self: Metrics, window_width: f32) f32 {
        const max_width = @max(self.row(300.0), window_width * self.max_panel_width_fraction);
        return @min(self.control_panel_width, @max(self.row(320.0), max_width));
    }

    pub fn initialWindowWidth(self: Metrics) c_int {
        return @intFromFloat(@round(@max(1100.0, 1024.0 * self.scale)));
    }

    pub fn initialWindowHeight(self: Metrics) c_int {
        return @intFromFloat(@round(@max(760.0, 704.0 * self.scale)));
    }
};

pub fn parseScale(value: []const u8) !f32 {
    return clampScale(try std.fmt.parseFloat(f32, value));
}

pub fn clampScale(scale: f32) f32 {
    if (!std.math.isFinite(scale)) return default_scale;
    return @min(1.85, @max(0.85, scale));
}

fn rgb(r: u8, g: u8, b: u8) Rgba {
    return .{ .r = r, .g = g, .b = b };
}

fn rounded(value: f32) f32 {
    return @round(value);
}

fn roundToHalf(value: f32) f32 {
    return @round(value * 2.0) / 2.0;
}

test "native UI theme names and scale config parse without C bindings" {
    try std.testing.expectEqual(ThemeName.darkroom, ThemeName.parse("darkroom").?);
    try std.testing.expectEqual(ThemeName.lighttable, ThemeName.parse("LIGHTTABLE").?);
    try std.testing.expectEqual(ThemeName.graphite, ThemeName.parse("Graphite").?);
    try std.testing.expectEqual(@as(?ThemeName, null), ThemeName.parse("unknown"));
    try std.testing.expectEqual(@as(f32, 0.85), try parseScale("0.5"));
    try std.testing.expectEqual(@as(f32, 1.85), try parseScale("3.0"));
}

test "native UI metrics grow controls and constrain panel to the window" {
    const metrics = (Config{ .scale = 1.25 }).metrics();
    try std.testing.expect(metrics.font_size > 13.0);
    try std.testing.expect(metrics.row(28.0) > 28.0);
    try std.testing.expect(metrics.panelWidth(1000.0) <= 1000.0 * metrics.max_panel_width_fraction + 0.01);
    try std.testing.expectEqual(metrics.row(900.0), metrics.panelHeight(900.0, 1400.0));
    try std.testing.expect(metrics.panelHeight(900.0, 480.0) <= 480.0 - metrics.margin * 2.0 + 0.01);
}
