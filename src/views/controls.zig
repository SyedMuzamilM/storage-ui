const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const types = @import("../models/browser.zig");
const Action = types.Action;
const Input = ui.controls.TextInput;
const v = @import("components.zig");
const c = v.c;
const controls = @import("controls.zig");

pub fn actionButton(self: *const Browser, b: *ui.Ui, label: []const u8, glyph: v.Icon, action: Action, enabled: bool, icon_only: bool) !ui.Element {
    const f = b.fluent();
    const color = if (enabled) c.text else ui.Color.rgb(0xc3c3bd);
    var button = f.button(.{ .label = label, .tooltip = label, .tooltip_colors = .{ c.sidebar, c.text, c.line } })
        .flex()
        .items_center()
        .gap_px(7)
        .h_px(32)
        .shrink_0()
        .px_px(if (icon_only) 8 else 10)
        .rounded_px(5)
        .hover_bg(if (enabled) c.hover else c.canvas)
        .on_click(b.onClickWith(Browser.onAction, action));
    button = button.child(try v.icon(b, glyph, color, 17));
    if (!icon_only) button = button.child(try v.text(b, label, color, 14));
    _ = self;
    return button.opacity(if (enabled) 1 else 0.65)
        .build();
}

pub fn stat(b: *ui.Ui, label: []const u8, value: []const u8) !ui.Element {
    const f = b.fluent();
    return f.row()
        .h_px(27)
        .items_center()
        .gap_px(8)
        .child(f.text(label)
            .w_px(100)
            .shrink_0()
            .text_size(13)
            .text_color(c.muted))
        .child(f.text(value)
            .grow()
            .min_w_px(0)
            .text_size(14)
            .text_color(c.text)
            .overflow_hidden())
        .build();
}

pub fn formField(_: *const Browser, b: *ui.Ui, label: []const u8, field_handle: ui.Entity(Input)) !ui.Element {
    const f = b.fluent();
    return f.column()
        .gap_px(6)
        .child(try v.text(b, label, c.text, 13))
        .child(f.view(field_handle)
            .id(.{ .string = label }))
        .build();
}

pub fn pathPicker(self: *const Browser, b: *ui.Ui, label: []const u8, action: Action) !ui.Element {
    const f = b.fluent();
    return f.column()
        .gap_px(6)
        .child(try v.text(b, label, c.text, 13))
        .child(
            f.row()
                .gap_px(8)
                .items_center()
                .child(f.view(self.path_field)
                    .id(.{ .string = label })
                    .grow()
                    .min_w_px(0))
                .child(
                try actionButton(self, b, if (action == .choose_source) "Browse…" else "Choose folder…", .folder_open, action, true, false),
            ),
        )
        .build();
}
