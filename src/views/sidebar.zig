const std = @import("std");
const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const types = @import("../models/browser.zig");
const Action = types.Action;
const v = @import("components.zig");
const c = v.c;
const controls = @import("controls.zig");
const matches = Browser.matches;

pub fn sidebarView(self: *const Browser, b: *ui.Ui, height: f32) !ui.Element {
    const f = b.fluent();
    var side = f.column()
        .w_px(286)
        .shrink_0()
        .bg(c.sidebar)
        .p_px(12)
        .gap_px(8)
        .overflow_hidden();
    side = side.child(
        f.row()
            .items_center()
            .h_px(32)
            .padding(.{ .left = 6 })
            .child(f.textFmt("BUCKETS  {d}", .{self.buckets.len})
                .grow()
                .text_color(c.muted)
                .text_size(12))
            .child(try controls.actionButton(self, b, "Connect account", .plus, .connect, !self.busy, true)),
    );
    side = side.child(f.view(self.bucket_filter)
        .id(.named("bucket-filter")));
    const list_height = @max(80, height - 300);
    var list = f.column()
        .h_px(list_height)
        .shrink_0()
        .overflow_hidden()
        .scroll_y_px(self.bucket_scroll.offset)
        .on_input(b.onInput(Browser.onBucketScroll));
    for (self.buckets, 0..) |bucket, i| {
        if (!matches(bucket.name, self.bucket_query)) continue;
        const active = std.mem.eql(u8, bucket.name, self.bucket);
        list = list.child(
            f.button(.{ .label = bucket.name })
                .id(.{ .number = 100 + i })
                .h_px(34)
                .shrink_0()
                .flex()
                .items_center()
                .gap_px(8)
                .rounded_px(6)
                .hover_bg(c.hover)
                .when(active, .{ .background = c.selected })
                .on_click(b.onClickWith(Browser.bucketClick, i))
                .child(f.div()
                    .w_px(2)
                    .h_px(20)
                    .rounded_px(1)
                    .bg(if (active) c.accent else c.sidebar))
                .child(try v.icon(b, .bucket, if (active) c.accent else c.muted, 16))
                .child(f.text(bucket.name)
                    .grow()
                    .min_w_px(0)
                    .overflow_hidden()
                    .text_size(14)
                    .text_color(c.text))
                .child(f.text(bucket.region)
                .text_size(11)
                .text_color(c.muted)
                .shrink_0()
                .padding(.{ .right = 6 })),
        );
    }
    side = side.child(list)
        .child(f.div()
        .grow());
    side = side.child(
        f.text("WORKSPACE")
            .shrink_0()
            .text_size(11)
            .text_color(c.muted)
            .padding(.{ .left = 7, .top = 8, .bottom = 3 }),
    );
    side = side.child(try sideAction(self, b, "Transfers", .refresh, .transfers));
    side = side.child(try sideAction(self, b, "Connections", .settings, .connect));
    side = side.child(
        f.row()
            .items_center()
            .h_px(30)
            .gap_px(8)
            .padding(.{ .left = 9 })
            .child(f.div()
                .w_px(6)
                .h_px(6)
                .rounded_px(3)
                .bg(if (self.demo) c.muted else .rgb(0x6c9070)))
            .child(f.text(if (self.demo) "Demo workspace" else "S3 compatible")
            .text_size(11)
            .text_color(c.muted)),
    );
    return side.build();
}

pub fn sideAction(self: *const Browser, b: *ui.Ui, label: []const u8, glyph: v.Icon, action: Action) !ui.Element {
    _ = self;
    return b.fluent()
        .button(.{ .label = label })
        .id(.{ .number = 3000 + @as(u64, @backingInt(action)) })
        .flex()
        .h_px(32)
        .shrink_0()
        .items_center()
        .gap_px(10)
        .px_px(8)
        .rounded_px(5)
        .hover_bg(c.hover)
        .on_click(b.onClickWith(Browser.onAction, action))
        .child(try v.icon(b, glyph, c.muted, 17))
        .child(try v.text(b, label, c.text, 14))
        .build();
}
