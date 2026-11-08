const std = @import("std");
const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const v = @import("components.zig");
const c = v.c;
const controls = @import("controls.zig");

pub fn inspector(self: *const Browser, b: *ui.Ui) !ui.Element {
    const f = b.fluent();
    if (self.preview.open) return f.column()
        .w_px(350)
        .shrink_0()
        .overflow_hidden()
        .child(
            f.row()
                .h_px(50)
                .shrink_0()
                .items_center()
                .px_px(12)
                .child(f.text("Preview")
                    .grow()
                    .text_size(14)
                    .text_color(c.text))
                .child(try controls.actionButton(self, b, "Details", .info, .details, true, true)),
        )
        .child(try @import("preview.zig")
            .render(self, b))
        .build();
    const object = self.selected();
    var panel = f.column()
        .w_px(310)
        .shrink_0()
        .overflow_hidden();
    panel = panel.child(
        f.row()
            .h_px(50)
            .shrink_0()
            .items_center()
            .gap_px(9)
            .px_px(20)
            .child(try v.icon(b, .info, c.accent, 17))
            .child(try v.text(b, "Details", c.text, 13))
            .child(f.div()
                .grow())
            .child(try controls.actionButton(self, b, "Hide details", .close, .inspector, true, true)),
    )
        .child(try v.rule(b, false));
    var content = f.column()
        .p_px(20)
        .gap_px(15);
    const name = if (object) |o| o.name(self.prefix) else if (self.prefix.len > 0) std.fs.path.basename(std.mem.trimEnd(u8, self.prefix, "/")) else self.bucket;
    content = content.child(
        f.row()
            .items_center()
            .gap_px(12)
            .child(
                f.div()
                    .w_px(46)
                    .h_px(46)
                    .rounded_px(10)
                    .bg(c.sidebar)
                    .items_center()
                    .justify_center()
                    .child(try v.icon(b, if (object != null and !object.?.folder) .file else .folder_open, c.muted, 26)),
            )
            .child(
            f.column()
                .grow()
                .min_w_px(0)
                .gap_px(3)
                .child(f.text(name)
                    .text_size(16)
                    .text_color(c.text)
                    .overflow_hidden())
                .child(try v.text(b, if (object) |o| if (o.folder) "Folder" else "Object" else "Current folder", c.muted, 13)),
        ),
    );
    var stats = f.column()
        .gap_px(1);
    if (object) |o| {
        stats = stats.child(try controls.stat(b, "Type", v.fileType(o.key, o.folder)));
        if (!o.folder) stats = stats.child(try controls.stat(b, "Size", try v.sizeText(b.allocator(), o.size)))
            .child(try controls.stat(b, "Modified", if (o.modified.len >= 10) o.modified[0..10] else o.modified));
    } else {
        var folders: usize = 0;
        var bytes: u64 = 0;
        for (self.objects) |o| {
            if (o.folder) folders += 1 else bytes +|= o.size;
        }
        stats = stats.child(try controls.stat(b, "Items", try std.fmt.allocPrint(b.allocator(), "{d}", .{self.objects.len})))
            .child(try controls.stat(b, "Folders", try std.fmt.allocPrint(b.allocator(), "{d}", .{folders})))
            .child(try controls.stat(b, "Objects", try std.fmt.allocPrint(b.allocator(), "{d}", .{self.objects.len - folders})))
            .child(try controls.stat(b, "Total size", try v.sizeText(b.allocator(), bytes)));
    }
    const region = self.effectiveRegion();
    stats = stats.child(try controls.stat(b, "Region", region))
        .child(try controls.stat(b, "Account", if (self.demo) "Demo · in-memory S3" else "S3 compatible"));
    content = content.child(stats);
    if (object) |o| {
        if (!o.folder) content = content.child(try controls.actionButton(self, b, "Preview object", .search, .preview, !self.busy, false));
        content = content.child(try v.rule(b, false))
            .child(try v.text(b, "Object key", c.muted, 12))
            .child(f.text(o.key)
            .text_size(12)
            .text_color(c.text)
            .overflow_hidden()
            .h_px(20));
        if (o.folder) content = content.child(
            f.button(.{ .label = "Open folder" })
                .h_px(32)
                .rounded_px(5)
                .bg(c.blue)
                .items_center()
                .justify_center()
                .on_click(b.onClickWith(Browser.openObject, self.selection.primary.?))
                .child(try v.text(b, "Open folder", c.accent, 13)),
        ) else content = content.child(try controls.actionButton(self, b, "Create signed URL", .copy, .signed_url, !self.demo, false))
            .child(
            f.row()
                .gap_px(8)
                .child(try controls.actionButton(self, b, "Download", .download, .download, !self.busy, false))
                .child(try controls.actionButton(self, b, "Delete", .trash, .delete, !self.busy, true)),
        );
    }
    return panel.child(content)
        .build();
}
