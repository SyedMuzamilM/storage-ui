const command_registry = @import("../app/commands.zig");
const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const v = @import("components.zig");
const c = v.c;
const matches = Browser.matches;
const commands = @import("../app/commands.zig").items;

pub fn paletteView(self: *const Browser, b: *ui.Ui) !ui.Element {
    const f = b.fluent();
    var panel = f.column()
        .w_px(590)
        .rounded_px(12)
        .bg(c.canvas)
        .overflow_hidden()
        .modal()
        .id(.named("command-palette"))
        .on_capture(b.onInput(Browser.onModalInput));
    panel = panel.child(
        f.row()
            .h_px(44)
            .shrink_0()
            .items_center()
            .px_px(18)
            .child(f.text("Commands")
                .text_color(c.text)
                .text_size(14)
                .grow())
            .child(try v.text(b, "⌘K", c.muted, 12)),
    )
        .child(
            f.div()
                .px_px(14)
                .padding(.{ .left = 14, .right = 14, .bottom = 12 })
                .child(f.view(self.palette_field)
                .id(.named("command-search"))
                .autofocus()),
        )
        .child(try v.rule(b, false));

    var list = f.column()
        .p_px(7)
        .gap_px(2);
    var count: usize = 0;
    const row_limit: usize = @max(3, @min(commands.len, @as(usize, @intFromFloat(@max(141, b.viewport().height - 250) / 47))));
    const first_row = if (self.palette_index >= row_limit) self.palette_index - row_limit + 1 else 0;
    for (commands, 0..) |command, index| {
        if (!matches(command.label, self.palette_query) and !matches(command.detail, self.palette_query)) continue;
        const row_index = count;
        count += 1;
        if (row_index < first_row or row_index >= first_row + row_limit) continue;
        const active = row_index == self.palette_index;
        const enabled = command_registry.enabled(self, command);
        list = list.child(
            f.button(.{ .label = command.label })
                .id(.{ .number = 60_000 + index })
                .flex()
                .h_px(45)
                .shrink_0()
                .items_center()
                .gap_px(12)
                .px_px(12)
                .rounded_px(6)
                .bg(if (active) c.blue else c.canvas)
                .hover_bg(c.hover)
                .opacity(if (enabled) 1 else 0.4)
                .on_click(b.onClickWith(Browser.paletteClick, index))
                .child(try v.icon(b, command.icon, if (active) c.accent else c.muted, 18))
                .child(
                    f.column()
                        .gap_px(3)
                        .grow()
                        .min_w_px(0)
                        .child(try v.text(b, command.label, c.text, 13))
                        .child(try v.text(b, command.detail, c.muted, 11)),
                )
                .child(try v.text(b, command.shortcut, c.muted, 12)),
        );
    }

    if (count == 0) list = list.child(
        f.div()
            .h_px(80)
            .items_center()
            .justify_center()
            .child(try v.text(b, "No matching commands", c.muted, 14)),
    );

    panel = panel.child(list)
        .child(try v.rule(b, false))
        .child(
        f.row()
            .h_px(36)
            .items_center()
            .px_px(18)
            .bg(c.sidebar)
            .child(try v.text(b, "↑ ↓ Navigate       ↵ Run command", c.muted, 11))
            .child(f.div()
                .grow())
            .child(try v.text(b, "Esc to close", c.muted, 11)),
    );

    return f.column()
        .w_full()
        .h_full()
        .bg(.{ .r = 0.15, .g = 0.16, .b = 0.14, .a = 0.3 })
        .items_center()
        .padding(.{ .top = @max(30, b.viewport().height * 0.1) })
        .child(panel)
        .build();
}
