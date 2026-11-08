const std = @import("std");
const ui = @import("zircon_ui");

pub const c = struct {
    pub const canvas = ui.Color.rgb(0xfbfaf8);
    pub const sidebar = ui.Color.rgb(0xf2f1ec);
    pub const line = ui.Color.rgb(0xe5e3de);
    pub const text = ui.Color.rgb(0x292a27);
    pub const muted = ui.Color.rgb(0x787971);
    pub const accent = ui.Color.rgb(0x4d7199);
    pub const folder = ui.Color.rgb(0x7898ba);
    pub const selected = ui.Color.rgb(0xe3e2d9);
    pub const hover = ui.Color.rgb(0xeeede7);
    pub const blue = ui.Color.rgb(0xe8eff7);
    pub const danger = ui.Color.rgb(0xa64c43);
};

pub const Icon = enum {
    minus,
    warning,
    commands,
    copy,
    bucket,
    info,
    layers,
    upload,
    download,
    folder,
    folder_open,
    file,
    code,
    search,
    plus,
    close,
    chevron_down,
    chevron_left,
    chevron_right,
    refresh,
    settings,
    split,
    square,
    square_checked,
    trash,
    history,
    check,
    more,
};

pub fn icon(b: *ui.Ui, name: Icon, color: ui.Color, size: f32) !ui.Element {
    if (name == .bucket or name == .info or name == .layers or name == .trash) {
        return b.custom(Glyph, .{ .name = name, .color = color, .size = size }, .{
            .width = .{ .px = size },
            .height = .{ .px = size },
            .flex_shrink = 0,
        });
    }

    const shared: ui.controls.icons.Name = switch (name) {
        .upload => .arrow_up,
        .download => .arrow_down,
        .bucket, .info, .layers, .trash => unreachable,
        inline else => |v| @field(ui.controls.icons.Name, @tagName(v)),
    };
    return ui.controls.icons.element(b, shared, color, size);
}

pub fn text(b: *ui.Ui, value: []const u8, color: ui.Color, size: f32) !ui.Element {
    return b.fluent()
        .text(value)
        .text_color(color)
        .text_size(size)
        .min_w_px(0)
        .overflow_hidden()
        .build();
}

pub fn rule(b: *ui.Ui, vertical: bool) !ui.Element {
    return b.fluent()
        .div()
        .bg(c.line)
        .shrink_0()
        .when(vertical, .{ .width = ui.Length{ .px = 1 } })
        .when(!vertical, .{ .height = ui.Length{ .px = 1 } })
        .build();
}

pub fn sizeText(a: std.mem.Allocator, size: u64) ![]const u8 {
    if (size < 1024) return std.fmt.allocPrint(a, "{d} B", .{size});
    const n: f64 = @floatFromInt(size);
    if (size < 1024 * 1024) return std.fmt.allocPrint(a, "{d:.1} KB", .{n / 1024});
    if (size < 1024 * 1024 * 1024) return std.fmt.allocPrint(a, "{d:.1} MB", .{n / (1024 * 1024)});
    return std.fmt.allocPrint(a, "{d:.1} GB", .{n / (1024 * 1024 * 1024)});
}

pub fn fileType(key: []const u8, folder: bool) []const u8 {
    if (folder) return "Folder";
    const ext = std.fs.path.extension(key);
    inline for (.{
        .{ ".json", "JSON file" },
        .{ ".txt", "Text file" },
        .{ ".svg", "SVG image" },
        .{ ".png", "PNG image" },
        .{ ".jpg", "JPEG image" },
        .{ ".csv", "CSV file" },
        .{ ".html", "HTML file" },
        .{ ".pdf", "PDF file" },
    }) |pair| if (std.ascii.eqlIgnoreCase(ext, pair[0])) return pair[1];
    return "Object";
}

const Glyph = struct {
    name: Icon,
    color: ui.Color,
    size: f32,

    pub const LayoutState = void;
    pub const PrepaintState = void;

    pub fn requestLayout(self: *Glyph, _: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = .{ .width = self.size, .height = self.size }, .state = {} };
    }

    pub fn prepaint(_: *Glyph, _: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {}

    fn line(self: *Glyph, p: *ui.graphics.Painter, r: ui.Rect, x1: f32, y1: f32, x2: f32, y2: f32) !void {
        const s = self.size / 24;
        try p.strokeLine(.{ .x = r.x + x1 * s, .y = r.y + y1 * s }, .{ .x = r.x + x2 * s, .y = r.y + y2 * s }, self.color, 1.6 * s);
    }

    pub fn paint(self: *Glyph, cx: *ui.PaintCx, r: ui.Rect, _: *void, _: *void) !void {
        const p = cx.painter;
        switch (self.name) {
            .bucket => {
                for ([_]f32{ 5, 11, 18 }) |y| {
                    for (0..24) |i| {
                        const t: f32 = @as(f32, @floatFromInt(i)) * std.math.pi * 2 / 24;
                        const u: f32 = @as(f32, @floatFromInt(i + 1)) * std.math.pi * 2 / 24;
                        if (y != 5 and i >= 12) continue;
                        try self.line(p, r, 12 + @cos(t) * 8, y + @sin(t) * 3, 12 + @cos(u) * 8, y + @sin(u) * 3);
                    }
                }
                try self.line(p, r, 4, 5, 4, 18);
                try self.line(p, r, 20, 5, 20, 18);
            },
            .info => {
                for (0..32) |i| {
                    const t: f32 = @as(f32, @floatFromInt(i)) * std.math.pi * 2 / 32;
                    const u: f32 = @as(f32, @floatFromInt(i + 1)) * std.math.pi * 2 / 32;
                    try self.line(p, r, 12 + @cos(t) * 9, 12 + @sin(t) * 9, 12 + @cos(u) * 9, 12 + @sin(u) * 9);
                }
                try self.line(p, r, 12, 10, 12, 17);
                try self.line(p, r, 12, 6.5, 12, 7.5);
            },
            .layers => {
                for ([_]f32{ 0, 5, 10 }) |y| {
                    try self.line(p, r, 3, 8 + y, 12, 12 + y);
                    try self.line(p, r, 12, 12 + y, 21, 8 + y);
                }
                try self.line(p, r, 3, 8, 12, 3);
                try self.line(p, r, 12, 3, 21, 8);
            },
            .trash => {
                try self.line(p, r, 4, 6, 20, 6);
                try self.line(p, r, 9, 3, 15, 3);
                try self.line(p, r, 6, 6, 7, 21);
                try self.line(p, r, 7, 21, 17, 21);
                try self.line(p, r, 17, 21, 18, 6);
                try self.line(p, r, 10, 10, 10, 17);
                try self.line(p, r, 14, 10, 14, 17);
            },
            else => {},
        }
    }
};
