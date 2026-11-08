const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const types = @import("../models/browser.zig");
const Action = types.Action;
const v = @import("components.zig");
const c = v.c;
const controls = @import("controls.zig");

pub fn signedUrlView(self: *const Browser, b: *ui.Ui) !ui.Element {
    const f = b.fluent();
    var panel = f.column()
        .w_px(580)
        .p_px(24)
        .gap_px(18)
        .rounded_px(12)
        .bg(c.canvas)
        .modal()
        .id(.named("signed-url-dialog"))
        .on_capture(b.onInput(Browser.onModalInput));
    panel = panel.child(
        f.row()
            .items_center()
            .child(
                f.text(
                    if (@import("std").mem.eql(u8, self.signed_method, "PUT")) "Create an upload link" else "Share a download link",
                )
                    .text_color(c.text)
                    .text_size(21)
                    .grow(),
            )
            .child(try controls.actionButton(self, b, "Close", .close, .dismiss, true, true)),
    );
    if (self.selected()) |object| panel = panel.child(
        f.row()
            .gap_px(8)
            .child(try v.icon(b, .file, c.muted, 18))
            .child(try v.text(b, object.name(self.prefix), c.text, 14)),
    );
    panel = panel.child(
        try v.text(
            b,
            if (@import("std").mem.eql(u8, self.signed_method, "PUT")) "Anyone with this link can upload to this object key until it expires." else "Anyone with this link can download this object until it expires.",
            c.muted,
            13,
        ),
    );
    var expiry = f.row()
        .gap_px(6)
        .items_center()
        .child(try v.text(b, "Expires in", c.muted, 12));
    inline for (.{
        .{ @as(u32, 300), "5 min" },
        .{ @as(u32, 900), "15 min" },
        .{ @as(u32, 3600), "1 hour" },
        .{ @as(u32, 86400), "24 hours" },
        .{ @as(u32, 604800), "7 days" },
    }) |choice| {
        expiry = expiry.child(
            f.button(.{ .label = choice[1] })
                .h_px(30)
                .px_px(10)
                .rounded_px(5)
                .bg(if (self.signed_expires == choice[0]) c.blue else c.sidebar)
                .text_color(if (self.signed_expires == choice[0]) c.accent else c.text)
                .on_click(b.onClickWith(Browser.expiryClick, choice[0])),
        );
    }
    panel = panel.child(expiry)
        .child(f.view(self.url_field)
            .id(.named("signed-url-field"))
            .on_capture(b.onInput(Browser.urlReadOnly)))
        .child(
        f.row()
            .justify(.end)
            .gap_px(8)
            .child(try controls.actionButton(self, b, "Cancel", .close, .dismiss, true, false))
            .child(
            f.button(.{ .label = "Copy signed URL" })
                .h_px(36)
                .px_px(18)
                .rounded_px(6)
                .bg(c.accent)
                .items_center()
                .justify_center()
                .text_color(.white)
                .on_click(b.onClickWith(Browser.onAction, Action.copy_url)),
        ),
    );
    return f.column()
        .w_full()
        .h_full()
        .bg(.{ .r = 0.15, .g = 0.16, .b = 0.14, .a = 0.3 })
        .items_center()
        .justify_center()
        .child(panel)
        .build();
}
