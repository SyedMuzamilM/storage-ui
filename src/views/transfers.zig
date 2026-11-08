const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const Action = @import("../models/browser.zig").Action;
const v = @import("components.zig");
const c = v.c;

pub fn render(self: *const Browser, b: *ui.Ui) !ui.Element {
    const f = b.fluent();
    var panel = f.column()
        .shrink_0();
    const active: usize = if (self.busy and (self.pending == .upload or self.pending == .download)) 1 else 0;
    panel = panel.child(
        f.button(.{ .label = "Transfer history" })
            .id(.named("transfer-bar"))
            .h_px(36)
            .shrink_0()
            .flex()
            .items_center()
            .gap_px(10)
            .px_px(16)
            .hover_bg(c.hover)
            .on_click(b.onClickWith(Browser.onAction, Action.transfers))
            .child(try v.icon(b, if (self.show_transfers) .chevron_down else .chevron_right, c.muted, 13))
            .child(try v.text(b, "Transfers", c.text, 13))
            .child(
            f.textFmt("{d} active   ·   {d} completed   ·   {d} failed", .{ active, self.completed, self.failed })
                .text_color(c.muted)
                .text_size(12),
        ),
    );
    if (self.show_transfers) {
        var history = f.column()
            .h_px(136)
            .shrink_0()
            .p_px(12)
            .gap_px(6)
            .bg(c.sidebar)
            .overflow_hidden();
        if (active > 0 and self.pending == .download) {
            history = history.child(
                f.row()
                    .h_px(24)
                    .gap_px(10)
                    .items_center()
                    .child(try v.icon(b, .download, c.accent, 15))
                    .child(try v.text(b, self.pending_key, c.text, 12))
                    .child(try v.text(b, "Downloading…", c.muted, 12)),
            );
        }

        if (active > 0 and self.pending == .upload) {
            const percent: u64 = if (self.progress_total == 0) 0 else @min(
                100,
                @as(
                    u64,
                    @intFromFloat(@as(f64, @floatFromInt(self.progress_sent)) / @as(f64, @floatFromInt(self.progress_total)) * 100),
                ),
            );
            history = history.child(
                f.row()
                    .gap_px(10)
                    .items_center()
                    .h_px(24)
                    .shrink_0()
                    .child(try v.icon(b, if (self.pending == .download) .download else .upload, c.accent, 15))
                    .child(f.text(self.pending_key)
                        .grow()
                        .min_w_px(0)
                        .text_color(c.text)
                        .text_size(12)
                        .overflow_hidden())
                    .child(
                    f.textFmt(
                        "{s} of {s}   {d}%   {s}/s",
                        .{
                            try v.sizeText(b.allocator(), self.progress_sent),
                            try v.sizeText(b.allocator(), self.progress_total),
                            percent,
                            try v.sizeText(b.allocator(), self.progress_speed),
                        },
                    )
                        .text_color(c.muted)
                        .text_size(12),
                ),
            );
            history = history.child(
                f.div()
                    .h_px(4)
                    .shrink_0()
                    .bg(c.line)
                    .rounded_px(2)
                    .child(f.div()
                    .w(.{ .percent = @floatFromInt(percent) })
                    .h_px(4)
                    .rounded_px(2)
                    .bg(c.accent)),
            );
            if (self.upload_cursor + 1 < self.uploads.items.len) {
                const next = self.uploads.items[self.upload_cursor + 1];
                history = history.child(
                    f.row()
                        .h_px(20)
                        .shrink_0()
                        .gap_px(8)
                        .items_center()
                        .child(try v.icon(b, .history, c.muted, 13))
                        .child(
                            f.textFmt("Next: {s}", .{next.key})
                                .grow()
                                .min_w_px(0)
                                .text_color(c.muted)
                                .text_size(11)
                                .overflow_hidden(),
                        )
                        .child(
                        f.textFmt("{d} queued", .{self.uploads.items.len - self.upload_cursor - 1})
                            .text_color(c.muted)
                            .text_size(11),
                    ),
                );
            }
        }
        if (active > 0 and self.pending == .upload) history = history.child(
            try @import("controls.zig")
                .actionButton(self, b, "Cancel current transfer", .close, .cancel_transfer, true, true),
        );
        if (active == 0) for (self.uploads.items) |item| if (item.status == .failed or item.status == .canceled) {
            history = history.child(
                try @import("controls.zig")
                    .actionButton(self, b, "Retry last failed upload", .refresh, .retry_transfer, true, false),
            );
            break;
        };
        if (self.history.items.len == 0 and active == 0) history = history.child(try v.text(b, "No transfers yet. Upload or download an object to start.", c.muted, 12));
        const n = @min(self.history.items.len, if (active > 0) @as(usize, 0) else 3);
        for (0..n) |i| {
            const transfer = self.history.items[self.history.items.len - 1 - i];
            history = history.child(
                f.row()
                    .h_px(23)
                    .shrink_0()
                    .gap_px(10)
                    .items_center()
                    .child(try v.icon(b, if (transfer.failed) .close else .check, if (transfer.failed) c.danger else c.accent, 15))
                    .child(f.text(transfer.name)
                        .w_px(280)
                        .text_color(c.text)
                        .text_size(12)
                        .overflow_hidden())
                    .child(try v.text(b, transfer.detail, if (transfer.failed) c.danger else c.muted, 12)),
            );
        }
        panel = panel.child(history);
    }
    return panel.build();
}
