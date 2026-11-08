const std = @import("std");
const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const types = @import("../models/browser.zig");
const Action = types.Action;
const Sort = types.Sort;
const v = @import("components.zig");
const c = v.c;
const controls = @import("controls.zig");

pub fn headerCell(self: *const Browser, b: *ui.Ui, label: []const u8, order: Sort, width: f32) !ui.Element {
    const f = b.fluent();
    return f.button(.{ .label = label })
        .id(.{ .number = 4000 + @as(u64, @backingInt(order)) })
        .flex()
        .items_center()
        .gap_px(4)
        .h_px(34)
        .when(width > 0, .{ .width = ui.Length{ .px = width }, .flex_shrink = @as(f32, 0) })
        .when(width == 0, .{ .flex_grow = @as(f32, 1), .min_width = ui.Length{ .px = 0 } })
        .hover_bg(c.hover)
        .on_click(b.onClickWith(Browser.sortClick, order))
        .child(try v.text(b, label, c.muted, 13))
        .child(
            if (self.sort == order) try v.icon(b, if (self.descending) .chevron_down else .upload, c.muted, 12) else try f.div()
                .w_px(0)
                .build(),
        )
        .build();
}

pub fn browserView(self: *const Browser, b: *ui.Ui, height: f32, compact: bool) !ui.Element {
    const f = b.fluent();
    const rows = try self.visible(b);
    const viewport = @max(36, height - 87 - (if (self.selection.count() > 1) @as(f32, 36) else 0) - if (self.message.len > 0) @as(f32, 36) else 0);
    var center = f.column()
        .grow()
        .min_w_px(260)
        .overflow_hidden()
        .when(self.drop_active and self.drop_folder == null, .{ .background = c.blue });
    var location = f.row()
        .h_px(50)
        .shrink_0()
        .items_center()
        .gap_px(8)
        .px_px(16);
    if (self.prefix.len > 0) location = location.child(try controls.actionButton(self, b, "Back to parent folder", .chevron_left, .parent, !self.busy, true));
    location = location.child(try v.icon(b, if (self.drop_active) .upload else .bucket, if (self.drop_active) c.accent else c.muted, 17))
        .child(
        f.text(self.bucket)
            .text_size(15)
            .text_color(c.text)
            .shrink_0()
            .max_w(.{ .px = if (compact) 150 else 230 })
            .overflow_hidden(),
    );
    if (self.prefix.len > 0) location = location.child(try v.icon(b, .chevron_right, c.muted, 12))
        .child(f.text(self.prefix)
        .text_color(c.muted)
        .text_size(13)
        .min_w_px(0)
        .overflow_hidden());
    location = location.child(f.div()
        .grow()
        .min_w_px(0))
        .child(
            f.div()
                .w_px(if (compact) 180 else 230)
                .shrink_0()
                .child(f.view(self.object_filter)
                .id(.named("object-filter"))),
        )
        .child(try controls.actionButton(self, b, if (self.flat) "Folders" else "Flat", .layers, .flat, !self.busy, compact));
    center = center.child(location)
        .child(try v.rule(b, false));
    var head = f.row()
        .h_px(35)
        .shrink_0()
        .items_center()
        .px_px(16)
        .gap_px(10);
    head = head.child(
        f.button(.{ .label = "Select all" })
            .w_px(20)
            .h_px(30)
            .shrink_0()
            .items_center()
            .justify_center()
            .on_click(b.onClickWith(Browser.onAction, Action.select_all))
            .child(try v.icon(b, if (self.selection.count() > 0) .square_checked else .square, c.muted, 16)),
    )
        .child(try headerCell(self, b, "Name", .name, 0))
        .child(try headerCell(self, b, "Size", .size, 80));
    if (!compact) head = head.child(f.text("Type")
        .w_px(100)
        .shrink_0()
        .text_size(13)
        .text_color(c.muted))
        .child(try headerCell(self, b, "Modified", .modified, 138));
    center = center.child(head)
        .child(try v.rule(b, false));
    var list = f.column()
        .h_px(viewport)
        .shrink_0()
        .overflow_hidden()
        .scroll_y_px(self.scroll.offset)
        .on_input(b.onInput(Browser.onScroll));
    if (rows.len == 0) {
        list = list.child(
            f.column()
                .h_px(@min(280, viewport))
                .items_center()
                .justify_center()
                .gap_px(12)
                .child(try v.icon(b, .folder_open, c.folder, 36))
                .child(
                    try v.text(
                        b,
                        if (self.object_query.len > 0) "No matching objects" else if (self.bucket.len == 0) "No buckets available" else "This folder is empty",
                        c.text,
                        16,
                    ),
                )
                .child(
                try v.text(
                    b,
                    if (self.object_query.len > 0) "Try a different filter." else "Upload a file or create a folder to get started.",
                    c.muted,
                    13,
                ),
            ),
        );
    } else {
        const range = try ui.controls.visibleRows(rows.len, 36, self.scroll.offset, viewport, 2);
        list = list.child(f.div()
            .h_px(@as(f32, @floatFromInt(range.start)) * 36)
            .shrink_0());
        for (rows[range.start..range.end]) |index| list = list.child(try objectRow(self, b, index, compact));
        list = list.child(f.div()
            .h_px(@as(f32, @floatFromInt(rows.len - range.end)) * 36)
            .shrink_0());
    }
    center = center.child(list);
    if (self.selection.count() > 1) center = center.child(
        f.row()
            .h_px(36)
            .shrink_0()
            .items_center()
            .gap_px(8)
            .px_px(12)
            .bg(c.blue)
            .child(f.textFmt("{d} selected", .{self.selection.count()})
                .grow()
                .text_color(c.accent)
                .text_size(12))
            .child(try controls.actionButton(self, b, "Download", .download, .download, true, true))
            .child(try controls.actionButton(self, b, "Copy", .copy, .copy, true, true))
            .child(try controls.actionButton(self, b, "Delete", .trash, .delete, true, true))
            .child(try controls.actionButton(self, b, "Clear selection", .close, .clear_selection, true, true)),
    );
    if (self.message.len > 0) center = center.child(
        f.row()
            .h_px(36)
            .shrink_0()
            .items_center()
            .gap_px(8)
            .px_px(16)
            .bg(c.sidebar)
            .child(try v.icon(b, .info, c.accent, 14))
            .child(try v.text(b, self.message, c.text, 12)),
    );
    return center.build();
}

pub fn objectRow(self: *const Browser, b: *ui.Ui, index: usize, compact: bool) !ui.Element {
    const f = b.fluent();
    const object = self.objects[index];
    const chosen = self.selection.contains(index);
    var row = f.row()
        .on_input(b.onInputWith(Browser.folderDrop, index))
        .h_px(36)
        .shrink_0()
        .items_center()
        .gap_px(10)
        .px_px(16)
        .when(chosen or self.drop_folder == index, .{ .background = c.blue })
        .hover_bg(c.hover);
    row = row.child(
        f.button(.{
            .label = try std.fmt.allocPrint(b.allocator(), "Select {s}", .{object.name(self.prefix)}),
        })
            .id(.{ .number = 10_000 + index })
            .w_px(20)
            .h_px(30)
            .shrink_0()
            .items_center()
            .justify_center()
            .on_click(b.onClickWith(Browser.objectClick, index))
            .child(try v.icon(b, if (chosen) .square_checked else .square, if (chosen) c.accent else .rgb(0xcacbc5), 16))
            .opacity(if (chosen) 1 else 0.6),
    );
    const glyph: v.Icon = if (object.folder) .folder else if (std.mem.endsWith(u8, object.key, ".json")) .code else .file;
    row = row.child(
        f.button(.{ .label = object.name(self.prefix) })
            .id(.{ .number = 200_000 + index })
            .flex()
            .items_center()
            .gap_px(9)
            .h_px(36)
            .grow()
            .min_w_px(0)
            .overflow_hidden()
            .on_click(b.onClickWith(Browser.openObject, index))
            .child(try v.icon(b, glyph, if (object.folder) c.folder else c.muted, 19))
            .child(f.text(object.name(self.prefix))
            .text_size(14)
            .text_color(c.text)
            .min_w_px(0)
            .overflow_hidden()),
    );
    row = row.child(
        f.row()
            .w_px(80)
            .shrink_0()
            .justify(.end)
            .child(try v.text(b, if (object.folder) "" else try v.sizeText(b.allocator(), object.size), c.muted, 13)),
    );
    if (!compact) {
        const modified = if (object.modified.len >= 16) try std.fmt.allocPrint(b.allocator(), "{s} {s}", .{ object.modified[0..10], object.modified[11..16] }) else object.modified;
        row = row.child(
            f.text(v.fileType(object.key, object.folder))
                .w_px(100)
                .shrink_0()
                .text_color(c.muted)
                .text_size(13)
                .overflow_hidden(),
        )
            .child(
            f.text(if (object.folder) "" else modified)
                .w_px(138)
                .shrink_0()
                .text_color(c.muted)
                .text_size(12)
                .overflow_hidden(),
        );
    }
    return row.build();
}
