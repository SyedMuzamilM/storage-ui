const Browser = @import("../app/browser.zig").Browser;
const v = @import("../views/components.zig");
const Action = @import("../models/browser.zig").Action;
pub const Command = struct {
    label: []const u8,
    detail: []const u8,
    shortcut: []const u8 = "",
    icon: v.Icon,
    action: Action,
    needs: enum { none, bucket, object, real_object, selection } = .none,
};
pub const items = [_]Command{
    .{
        .label = "Upload files…",
        .detail = "Choose multiple files to upload into this folder",
        .shortcut = "⌘U",
        .icon = .upload,
        .action = .upload,
        .needs = .bucket,
    },
    .{
        .label = "Download object…",
        .detail = "Save the selected object to your Mac",
        .shortcut = "⌘D",
        .icon = .download,
        .action = .download,
        .needs = .selection,
    },
    .{
        .label = "Create signed URL…",
        .detail = "Share a temporary download link",
        .icon = .copy,
        .action = .signed_url,
        .needs = .real_object,
    },
    .{
        .label = "Copy object key",
        .detail = "Copy the full key within this bucket",
        .icon = .copy,
        .action = .copy_key,
        .needs = .object,
    },
    .{
        .label = "Copy S3 URI",
        .detail = "Copy s3://bucket/object",
        .icon = .copy,
        .action = .copy_s3_uri,
        .needs = .object,
    },
    .{
        .label = "New folder…",
        .detail = "Create a folder in the current location",
        .icon = .folder,
        .action = .mkdir,
        .needs = .bucket,
    },
    .{
        .label = "Refresh folder",
        .detail = "Reload the current objects",
        .shortcut = "⌘R",
        .icon = .refresh,
        .action = .refresh,
        .needs = .bucket,
    },
    .{
        .label = "Toggle flat listing",
        .detail = "Switch between folders and all objects",
        .icon = .layers,
        .action = .flat,
        .needs = .bucket,
    },
    .{
        .label = "Delete object…",
        .detail = "Remove the selected object after confirmation",
        .icon = .trash,
        .action = .delete,
        .needs = .selection,
    },
    .{
        .label = "Show transfers",
        .detail = "View upload progress and transfer history",
        .icon = .history,
        .action = .transfers,
    },
    .{
        .label = "Toggle details",
        .detail = "Show or hide the inspector",
        .icon = .split,
        .action = .inspector,
    },
    .{
        .label = "Connection settings…",
        .detail = "Manage the endpoint, region, and bucket",
        .icon = .settings,
        .action = .connect,
    },
    .{
        .label = "Preview object",
        .detail = "View text, images, or hexadecimal bytes",
        .icon = .search,
        .action = .preview,
        .needs = .object,
    },
    .{
        .label = "Rename object…",
        .detail = "Rename the selected file",
        .icon = .file,
        .action = .rename,
        .needs = .object,
    },
    .{
        .label = "Copy objects",
        .detail = "Copy selected objects for pasting elsewhere",
        .shortcut = "⌘C",
        .icon = .copy,
        .action = .copy,
        .needs = .selection,
    },
    .{
        .label = "Cut objects",
        .detail = "Move selected objects when pasted",
        .shortcut = "⌘X",
        .icon = .copy,
        .action = .cut,
        .needs = .selection,
    },
    .{
        .label = "Paste objects",
        .detail = "Paste into the current folder",
        .shortcut = "⌘V",
        .icon = .copy,
        .action = .paste,
        .needs = .bucket,
    },
    .{
        .label = "Create signed upload URL…",
        .detail = "Generate a temporary PUT link",
        .icon = .upload,
        .action = .signed_put,
        .needs = .real_object,
    },
};

pub fn enabled(self: *const Browser, command: Command) bool {
    if (command.action == .paste and self.clipboard.keys.len == 0) return false;
    if (command.action == .rename and self.selection.count() != 1) return false;
    if (self.busy and command.action != .transfers and command.action != .inspector and command.action != .upload) return false;
    return switch (command.needs) {
        .none => true,
        .bucket => self.bucket.len > 0,
        .object => self.selected() != null and !self.selected().?.folder,
        .selection => self.selection.count() > 0,
        .real_object => !self.demo and self.selection.count() == 1 and self.selected() != null and !self.selected().?.folder,
    };
}
