const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const Action = @import("../models/browser.zig").Action;
const v = @import("components.zig");
const c = v.c;
const controls = @import("controls.zig");

pub fn render(self: *const Browser, b: *ui.Ui) !ui.Element {
    const f = b.fluent();
    const width = b.viewport().width;
    var toolbar = f.row()
        .h_px(54)
        .shrink_0()
        .items_center()
        .gap_px(4)
        .padding(.{ .left = 12, .right = 14 })
        .drag_region();
    toolbar = toolbar.child(
        try controls.actionButton(self, b, "Upload", .upload, .upload, (!self.busy or self.pending == .upload) and self.bucket.len > 0, false),
    )
        .child(
            try controls.actionButton(self, b, "Download", .download, .download, !self.busy and self.selection.count() > 0, false),
        )
        .child(try controls.actionButton(self, b, "New folder", .plus, .mkdir, !self.busy and self.bucket.len > 0, false))
        .child(f.div()
            .w_px(1)
            .h_px(20)
            .bg(c.line)
            .margin(.{ .left = 9, .right = 9 }))
        .child(
            try controls.actionButton(self, b, "Delete object", .trash, .delete, !self.busy and self.selection.count() > 0, true),
        )
        .child(try controls.actionButton(self, b, "Refresh", .refresh, .refresh, !self.busy, true))
        .child(f.div()
        .grow());
    if (self.busy) {
        const status = switch (self.pending) {
            .upload => "Uploading…",
            .download => "Downloading…",
            else => "Loading…",
        };
        toolbar = toolbar.child(try v.text(b, status, c.muted, 12));
    }
    toolbar = toolbar.child(try controls.actionButton(self, b, "Commands", .commands, .palette, true, width < 1200))
        .child(try controls.actionButton(self, b, "Toggle details", .split, .inspector, true, true));
    const account = f.row()
        .w_px(286)
        .h_px(54)
        .shrink_0()
        .bg(c.sidebar)
        .padding(.{ .left = 88, .right = 12 })
        .items_center()
        .drag_region()
        .child(
        f.button(.{ .label = "Account" })
            .id(.named("account"))
            .grow()
            .min_w_px(0)
            .flex()
            .items_center()
            .gap_px(9)
            .h_px(42)
            .rounded_px(6)
            .hover_bg(c.hover)
            .on_click(b.onClickWith(Browser.onAction, Action.connect))
            .child(
                f.div()
                    .w_px(27)
                    .h_px(28)
                    .shrink_0()
                    .bg(c.selected)
                    .rounded_px(6)
                    .items_center()
                    .justify_center()
                    .child(try v.text(b, if (self.demo) "D" else "S", c.text, 13)),
            )
            .child(
                f.column()
                    .grow()
                    .min_w_px(0)
                    .gap_px(2)
                    .child(
                        f.text(if (self.demo) "Demo · in-memory" else "S3 connection")
                            .text_size(13)
                            .text_color(c.text)
                            .overflow_hidden(),
                    )
                    .child(f.text(self.effectiveRegion())
                    .text_size(11)
                    .text_color(c.muted)
                    .overflow_hidden()),
            )
            .child(try v.icon(b, .chevron_down, c.muted, 13)),
    );
    return f.row()
        .h_px(54)
        .shrink_0()
        .child(account)
        .child(try v.rule(b, true))
        .child(toolbar.grow())
        .build();
}
