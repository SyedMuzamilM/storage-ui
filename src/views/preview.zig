const std = @import("std");
const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const v = @import("components.zig");
const c = v.c;

pub fn hex(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var offset: usize = 0;
    while (offset < @min(bytes.len, 65536)) : (offset += 16) {
        try output.appendSlice(a, try std.fmt.allocPrint(a, "{x:0>8}  ", .{offset}));
        for (0..16) |column| {
            if (offset + column < bytes.len) try output.appendSlice(a, try std.fmt.allocPrint(a, "{x:0>2} ", .{bytes[offset + column]})) else try output.appendSlice(a, "   ");
        }
        try output.appendSlice(a, " ");
        for (bytes[offset..@min(bytes.len, offset + 16)]) |byte| try output.append(a, if (byte >= 32 and byte < 127) byte else '.');
        try output.append(a, '\n');
    }
    return output.toOwnedSlice(a);
}

pub fn render(self: *const Browser, b: *ui.Ui) !ui.Element {
    const f = b.fluent();
    var panel = f.column()
        .grow()
        .min_h_px(0)
        .gap_px(8)
        .overflow_hidden();
    if (self.busy) return panel.child(try v.text(b, "Loading preview…", c.muted, 13))
        .build();
    if (self.preview.image) |source| {
        var owned = source.clone();
        errdefer owned.deinit();
        const canvas = try b.custom(
            Image,
            .{
                .image = owned,
                .fit = self.preview.fit,
                .zoom = self.preview.zoom,
                .scroll = self.preview.scroll,
            },
            .{ .flex_grow = 1, .min_height = .{ .px = 0 }, .overflow = .hidden },
        );
        panel = panel.child(
            f.row()
                .h_px(30)
                .gap_px(6)
                .items_center()
                .child(try zoomButton(b, "Zoom out", .minus, .out))
                .child(try zoomButton(b, "Fit", .square, .fit))
                .child(try zoomButton(b, "Zoom in", .plus, .in))
                .child(f.textFmt("{d:.0}%", .{self.preview.zoom * 100})
                .text_color(c.muted)
                .text_size(11)),
        )
            .child(f.adopt(canvas)
            .focusable()
            .on_input(b.onInput(imageInput)));
    } else panel = panel.child(f.view(self.preview_field)
        .id(.named("object-preview"))
        .grow()
        .min_h_px(80));
    if (self.preview.truncated) panel = panel.child(try v.text(b, "Preview truncated. Download the object for its full contents.", c.muted, 11));
    return panel.build();
}
const Zoom = enum { in, out, fit };

fn zoomButton(b: *ui.Ui, label: []const u8, glyph: v.Icon, action: Zoom) !ui.Element {
    return b.fluent()
        .button(.{ .label = label })
        .h_px(28)
        .px_px(8)
        .rounded_px(4)
        .hover_bg(c.hover)
        .on_click(b.onClickWith(zoomClick, action))
        .child(try v.icon(b, glyph, c.muted, 14))
        .build();
}

fn zoomClick(self: *Browser, _: *ui.Event(ui.Click), cx: *ui.Context(Browser), action: Zoom) void {
    self.preview.fit = action == .fit;
    self.preview.zoom = switch (action) {
        .in => @min(8, self.preview.zoom * 1.25),
        .out => @max(0.125, self.preview.zoom / 1.25),
        .fit => 1,
    };
    self.preview.scroll = .{};
    cx.notify();
}

fn imageInput(self: *Browser, event: *ui.Event(ui.Input), cx: *ui.Context(Browser)) void {
    switch (event.data) {
        .scroll => |wheel| {
            if (wheel.modifiers.control or wheel.modifiers.command) {
                self.preview.fit = false;
                self.preview.zoom = std.math.clamp(self.preview.zoom * @exp(wheel.y * 0.01), 0.125, 8);
            } else {
                self.preview.scroll.x = @max(0, self.preview.scroll.x - wheel.x);
                self.preview.scroll.y = @max(0, self.preview.scroll.y - wheel.y);
            }
        },
        .pointer_down => |pointer| {
            if (pointer.clicks >= 2) {
                self.preview.fit = true;
                self.preview.scroll = .{};
            } else {
                self.preview.drag = pointer.position;
                event.capturePointer();
            }
        },
        .pointer_move => |pointer| {
            if (self.preview.drag) |previous| {
                self.preview.scroll.x = @max(0, self.preview.scroll.x + previous.x - pointer.position.x);
                self.preview.scroll.y = @max(0, self.preview.scroll.y + previous.y - pointer.position.y);
                self.preview.drag = pointer.position;
            } else return;
        },
        .pointer_up => {
            self.preview.drag = null;
            event.releasePointer();
        },
        else => return,
    }
    event.preventDefault();
    cx.notify();
}
const Image = struct {
    image: ui.graphics.images.Image,
    fit: bool,
    zoom: f32,
    scroll: ui.Point,
    pub const LayoutState = void;
    pub const PrepaintState = void;

    pub fn requestLayout(_: *Image, cx: *ui.LayoutCx) !ui.LayoutResult(void) {
        return .{ .size = cx.available, .state = {} };
    }

    pub fn prepaint(_: *Image, _: *ui.PrepaintCx, _: ui.Rect, _: *void) !void {}

    pub fn paint(self: *Image, cx: *ui.PaintCx, bounds: ui.Rect, _: *void, _: *void) !void {
        try cx.painter.pushClip(bounds);
        defer cx.painter.popClip();
        const size = self.image.size();
        const rect = if (self.fit) bounds else ui.Rect{
            .x = bounds.x + @max(0, (bounds.width - size.width * self.zoom) / 2) - self.scroll.x,
            .y = bounds.y + @max(0, (bounds.height - size.height * self.zoom) / 2) - self.scroll.y,
            .width = size.width * self.zoom,
            .height = size.height * self.zoom,
        };
        try cx.painter.drawImage(self.image, rect, .contain);
    }

    pub fn deinit(self: *Image) void {
        self.image.deinit();
    }
};
