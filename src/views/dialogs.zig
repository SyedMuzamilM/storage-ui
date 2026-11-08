const palette = @import("palette.zig");
const share = @import("share.zig");
const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const types = @import("../models/browser.zig");
const Action = types.Action;
const v = @import("components.zig");
const c = v.c;
const controls = @import("controls.zig");

pub fn modalView(self: *const Browser, b: *ui.Ui) !ui.Element {
    const f = b.fluent();
    if (self.modal == .palette) return palette.paletteView(self, b);
    if (self.modal == .signed_url) return share.signedUrlView(self, b);

    const title: []const u8 = switch (self.modal) {
        .connect => "Connect to S3",
        .upload => "Upload a file",
        .download => "Download object",
        .mkdir => "New folder",
        .delete => "Delete objects?",
        .rename => "Rename object",
        .none, .signed_url, .palette => "",
    };

    var panel = f.column()
        .w_px(500)
        .p_px(24)
        .gap_px(16)
        .rounded_px(12)
        .bg(c.canvas)
        .on_capture(b.onInput(Browser.onModalInput))
        .modal()
        .id(.named("dialog"));
    panel = panel.child(
        f.row()
            .items_center()
            .child(f.text(title)
                .grow()
                .text_color(c.text)
                .text_size(21))
            .child(try controls.actionButton(self, b, "Close", .close, .dismiss, true, true)),
    );

    switch (self.modal) {
        .connect => {
            panel = panel.child(try v.text(b, "AWS S3, Cloudflare R2, MinIO, and compatible services.", c.muted, 13))
                .child(try controls.formField(self, b, "Endpoint", self.endpoint_field))
                .child(try controls.formField(self, b, "Signing region", self.region_field))
                .child(try controls.formField(self, b, "Bucket", self.bucket_field))
                .child(try v.text(b, "Leave bucket empty to list the account's buckets.", c.muted, 12))
                .child(try v.rule(b, false))
                .child(
                    try v.text(
                        b,
                        if (self.has_credentials) "Credentials loaded from your environment." else "Credentials are missing from your environment.",
                        if (self.has_credentials) c.muted else c.danger,
                        13,
                    ),
                )
                .child(try v.text(b, "Use AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.", c.muted, 12));
        },
        .upload => panel = panel.child(try v.text(b, "Upload into the current folder. Existing names are protected.", c.muted, 13))
            .child(try controls.pathPicker(self, b, "Local file path", .choose_source))
            .child(try controls.formField(self, b, "Object name, optional", self.name_field)),
        .download => {
            const directory = self.selection.count() > 1 or (self.selected() != null and self.selected().?.folder);
            if (self.selected()) |o| panel = panel.child(try v.text(b, o.name(self.prefix), c.text, 14));
            const label = if (directory) "Destination folder" else "Save to local file path";
            const help = if (directory)
                "Selected folders keep their relative structure. Existing files are protected."
            else
                "Include a file name. Existing local files are protected.";
            panel = panel.child(try controls.pathPicker(self, b, label, .choose_destination))
                .child(try v.text(b, help, c.muted, 12));
        },
        .rename => panel = panel.child(try controls.formField(self, b, "New file name", self.name_field)),
        .mkdir => panel = panel.child(try controls.formField(self, b, "Folder name", self.name_field)),
        .delete => {
            if (self.selected()) |o| panel = panel.child(try v.text(b, o.name(self.prefix), c.text, 14));
            panel = panel.child(f.textFmt("Delete {d} selected objects from {s}?", .{ self.selection.count(), self.bucket }).text_color(c.text).text_size(13))
                .child(try v.text(b, "Selected folders include every object beneath them.", c.muted, 12));
        },
        .none, .signed_url, .palette => {},
    }

    if (self.modal_error.len > 0) panel = panel.child(try v.text(b, self.modal_error, c.danger, 12));

    var footer = f.row()
        .justify(.end)
        .gap_px(8);
    if (self.modal == .connect) footer = footer.child(try controls.actionButton(self, b, "Use demo", .bucket, .demo, true, false));
    footer = footer.child(try controls.actionButton(self, b, "Cancel", .close, .dismiss, true, false))
        .child(
        f.button(
            .{
                .label = switch (self.modal) {
                    .connect => "Connect",
                    .upload => "Upload",
                    .download => "Download",
                    .mkdir => "Create folder",
                    .delete => "Delete",
                    .rename => "Rename",
                    .none, .signed_url, .palette => "OK",
                },
            },
        )
            .id(.named("confirm"))
            .h_px(34)
            .px_px(18)
            .rounded_px(6)
            .bg(if (self.modal == .delete) c.danger else c.accent)
            .items_center()
            .justify_center()
            .text_color(.white)
            .on_click(b.onClickWith(Browser.onAction, Action.submit)),
    );
    panel = panel.child(footer);

    return f.column()
        .w_full()
        .h_full()
        .bg(.{ .r = 0.15, .g = 0.16, .b = 0.14, .a = 0.3 })
        .items_center()
        .justify_center()
        .child(panel)
        .build();
}
