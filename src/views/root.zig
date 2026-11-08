const dialogs = @import("dialogs.zig");
const inspector = @import("inspector.zig");
const objects = @import("objects.zig");
const sidebar = @import("sidebar.zig");
const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const v = @import("components.zig");
const c = v.c;

pub fn render(self: *const Browser, b: *ui.Ui) !ui.Element {
    const f = b.fluent();
    const width = b.viewport().width;
    const details = self.show_inspector and width >= 1120;
    const compact = width < (if (details) @as(f32, 1430) else 1120);
    const main_height = @max(150, b.viewport().height - 119 - if (self.show_transfers) @as(f32, 136) else 0);

    var root = f.column()
        .w_full()
        .h_full()
        .bg(c.canvas)
        .text_color(c.text)
        .on_input(b.onInput(Browser.onInput));
    root = root.child(try @import("chrome.zig")
        .render(self, b))
        .child(try v.rule(b, false));

    var main_row = f.row()
        .h_px(main_height)
        .shrink_0()
        .overflow_hidden()
        .child(try sidebar.sidebarView(self, b, main_height))
        .child(try v.rule(b, true))
        .child(try objects.browserView(self, b, main_height, compact));
    if (details) main_row = main_row.child(try v.rule(b, true))
        .child(try inspector.inspector(self, b));
    root = root.child(main_row)
        .child(try v.rule(b, false));
    root = root.child(try @import("transfers.zig")
        .render(self, b));

    const rows = try self.visible(b);
    root = root.child(try v.rule(b, false))
        .child(
        f.row()
            .h_px(26)
            .shrink_0()
            .items_center()
            .px_px(15)
            .bg(c.sidebar)
            .gap_px(6)
            .child(
                f.textFmt(
                    "{s}   ·   {s}   ·   {d} items{s}",
                    .{
                        if (self.demo) "Demo · in-memory S3" else "S3 compatible",
                        self.effectiveRegion(),
                        rows.len,
                        if (self.object_query.len > 0) " filtered" else "",
                    },
                )
                    .text_color(c.muted)
                    .text_size(11)
                    .grow()
                    .min_w_px(0)
                    .overflow_hidden(),
            )
            .child(try v.text(b, if (self.demo) "Changes stay in this session" else "Connected", c.muted, 11)),
    );

    if (self.modal != .none) return f.stack()
        .w_full()
        .h_full()
        .child(root)
        .child(try dialogs.modalView(self, b))
        .build();
    return root.build();
}
