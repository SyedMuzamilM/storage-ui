const std = @import("std");
const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const s3 = @import("../storage/s3.zig");
const v = @import("../views/components.zig");
const Input = ui.controls.TextInput;
const types = @import("../models/browser.zig");
const Action = types.Action;
const Sort = types.Sort;
const commands = @import("commands.zig").items;
const setField = Browser.setField;
const errorText = Browser.errorText;
const matches = Browser.matches;

pub fn refresh(self: *Browser, cx: *ui.Context(Browser)) !void {
    if (self.demo) {
        try self.loadDemo();
        cx.notify();
    } else try self.start(cx, .list, "", "");
}

pub fn navigate(self: *Browser, cx: *ui.Context(Browser), prefix: []const u8) !void {
    if (self.busy) return;
    self.prefix = try self.keep(prefix);
    self.object_query = "";
    try cx.update(self.object_filter, setField, .{""});
    try self.refresh(cx);
}

pub fn bucketClick(self: *Browser, _: *ui.Event(ui.Click), cx: *ui.Context(Browser), index: usize) !void {
    if (self.busy or index >= self.buckets.len) return;
    self.bucket = try self.keep(self.buckets[index].name);
    if (!self.demo) self.region = try self.keep(self.buckets[index].region);
    try self.navigate(cx, "");
}

pub fn objectClick(self: *Browser, event: *ui.Event(ui.Click), cx: *ui.Context(Browser), index: usize) !void {
    if (self.busy) return;
    self.preview.open = false;
    if (event.data.modifiers.shift) try self.selection.range(self.arena.allocator(), index) else try self.selection.toggle(self.arena.allocator(), index);
    cx.notify();
}

pub fn openObject(self: *Browser, event: *ui.Event(ui.Click), cx: *ui.Context(Browser), index: usize) !void {
    if (self.busy or index >= self.objects.len) return;
    self.preview.open = false;
    const modifiers = event.data.modifiers;
    if (modifiers.command or modifiers.control or modifiers.shift) return objectClick(self, event, cx, index);
    if (self.objects[index].folder) try self.navigate(cx, self.objects[index].key) else {
        try self.selection.replace(self.arena.allocator(), index);
        cx.notify();
    }
}

pub fn sortClick(self: *Browser, _: *ui.Event(ui.Click), cx: *ui.Context(Browser), order: Sort) void {
    if (self.sort == order) self.descending = !self.descending else {
        self.sort = order;
        self.descending = false;
    }
    self.sortObjects();
    self.selection.clear();
    cx.notify();
}

pub fn onAction(self: *Browser, event: *ui.Event(ui.Click), cx: *ui.Context(Browser), action: Action) !void {
    const handled = @import("object_actions.zig")
        .handle(self, cx, action) catch |err| {
        self.message = errorText(err);
        cx.notify();
        return;
    };
    if (handled) return;
    if (action == .upload and self.modal != .upload) {
        if (self.bucket.len == 0 or (self.busy and self.pending != .upload)) return;
        const surface = event._surface orelse return;
        const paths = surface.chooseFiles(self.allocator) catch |err| {
            if (err == error.NativeDialogUnavailable) return self.act(cx, .upload);
            self.message = errorText(err);
            cx.notify();
            return;
        };
        defer {
            for (paths) |path| self.allocator.free(path);
            self.allocator.free(paths);
        }
        try self.enqueuePaths(cx, paths, self.prefix);
        return;
    }
    if (action == .copy_key or action == .copy_s3_uri or action == .copy_url) {
        var lines: std.ArrayList(u8) = .empty;
        if (action == .copy_url) {
            try lines.appendSlice(self.arena.allocator(), self.signed_url);
        } else {
            for (self.objects, 0..) |object, index| {
                if (!self.selection.contains(index)) continue;
                if (lines.items.len > 0) try lines.append(self.arena.allocator(), '\n');
                const value = if (action == .copy_key)
                    object.key
                else
                    try std.fmt.allocPrint(self.arena.allocator(), "s3://{s}/{s}", .{ self.bucket, object.key });
                try lines.appendSlice(self.arena.allocator(), value);
            }
        }
        const value = lines.items;
        if (value.len == 0) return;
        try event.writeClipboard(value);
        self.message = if (action == .copy_url) "Signed URL copied" else "Copied to clipboard";
        if (self.modal == .palette or self.modal == .signed_url) self.modal = .none;
        cx.notify();
        return;
    }
    if (action == .choose_source or action == .choose_destination) {
        if (self.busy) return;
        const surface = event._surface orelse return;
        const path = surface.choosePath(self.allocator, if (action == .choose_source) .file else .folder) catch |err| {
            self.modal_error = errorText(err);
            cx.notify();
            return;
        };
        if (path) |chosen| {
            defer self.allocator.free(chosen);
            const object = self.selected();
            const single_file = self.selection.count() == 1 and object != null and !object.?.folder;
            const full = if (action == .choose_destination and single_file)
                try std.fs.path.join(self.arena.allocator(), &.{ chosen, std.fs.path.basename(object.?.key) })
            else
                chosen;
            try cx.update(self.path_field, setField, .{full});
        }
        return;
    }
    try self.act(cx, action);
}

pub fn act(self: *Browser, cx: *ui.Context(Browser), action: Action) !void {
    switch (action) {
        .preview => {
            const object = self.selected() orelse return;
            if (!object.folder) try self.start(cx, .preview, object.key, "");
        },
        .details => self.preview.open = false,
        .cancel_transfer => {
            if (self.active_job) |handle| try cx.app.cancelTask(handle);
        },
        .retry_transfer => {
            if (self.busy) return;
            var index = self.uploads.items.len;
            while (index > 0) {
                index -= 1;
                const item = self.uploads.items[index];
                if (item.status != .failed and item.status != .canceled) continue;
                var retry = item;
                retry.status = .queued;
                retry.detail = "";
                try self.uploads.append(self.arena.allocator(), retry);
                try self.startNextUpload(cx);
                break;
            }
        },
        .palette => {
            self.modal = .palette;
            self.palette_query = "";
            self.palette_index = 0;
            try cx.update(self.palette_field, setField, .{""});
        },
        .signed_url, .signed_put => {
            self.signed_method = if (action == .signed_put) "PUT" else "GET";
            try self.showSignedUrl(cx);
        },
        .dismiss => {
            self.modal = .none;
            self.modal_error = "";
        },
        .inspector => self.show_inspector = !self.show_inspector,
        .transfers => self.show_transfers = !self.show_transfers,
        .clear_selection => self.selection.clear(),
        .select_all => {
            var visible_count: usize = 0;
            var selected_count: usize = 0;
            for (self.objects, 0..) |object, i| if (matches(object.name(self.prefix), self.object_query)) {
                visible_count += 1;
                if (self.selection.contains(i)) selected_count += 1;
            };
            self.selection.clear();
            if (selected_count != visible_count) for (self.objects, 0..) |object, i| if (matches(object.name(self.prefix), self.object_query)) {
                try self.selection.add(self.arena.allocator(), i);
            };
        },
        else => {
            if (self.busy) return;
            switch (action) {
                .connect => {
                    self.modal = .connect;
                    self.modal_error = "";
                },
                .demo => {
                    self.demo = true;
                    self.bucket = "acme-assets";
                    self.prefix = "";
                    self.modal = .none;
                    self.message = "";
                    try self.loadDemo();
                },
                .refresh => try self.refresh(cx),
                .parent => {
                    const trimmed = std.mem.trimEnd(u8, self.prefix, "/");
                    const parent = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| trimmed[0 .. slash + 1] else "";
                    try self.navigate(cx, parent);
                },
                .flat => {
                    self.flat = !self.flat;
                    try self.refresh(cx);
                },
                .mkdir => {
                    if (self.bucket.len == 0) return;
                    self.modal = .mkdir;
                    self.modal_error = "";
                    try cx.update(self.name_field, setField, .{""});
                },
                .upload => {
                    if (self.bucket.len == 0) return;
                    self.modal = .upload;
                    self.modal_error = "";
                    try cx.update(self.path_field, setField, .{""});
                    try cx.update(self.name_field, setField, .{""});
                },
                .download, .delete => {
                    if (self.selected() == null) return;
                    self.modal = if (action == .download) .download else .delete;
                    self.modal_error = "";
                    try cx.update(self.path_field, setField, .{""});
                },
                .submit => self.submit(cx) catch |err| {
                    self.modal_error = errorText(err);
                },
                else => {},
            }
        },
    }
    cx.notify();
}

pub fn submit(self: *Browser, cx: *ui.Context(Browser)) !void {
    switch (self.modal) {
        .connect => {
            if (!self.has_credentials) {
                self.modal_error = "Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, then restart Storage.";
                return;
            }
            const config: s3.Config = .{
                .endpoint = try self.readField(cx, self.endpoint_field),
                .region = try self.readField(cx, self.region_field),
            };
            try config.validate();
            self.endpoint = config.endpoint;
            self.region = config.region;
            self.initial_bucket = try self.readField(cx, self.bucket_field);
            self.prefix = "";
            self.demo = false;
            try self.start(cx, .connect, "", "");
        },
        .rename => {
            const object = self.selected() orelse return;
            const name = std.mem.trim(u8, try self.readField(cx, self.name_field), " ");
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
                self.modal_error = "Enter a file name without slashes.";
                return;
            }
            const parent = if (std.mem.lastIndexOfScalar(u8, object.key, '/')) |slash| object.key[0 .. slash + 1] else "";
            const target = try std.fmt.allocPrint(self.arena.allocator(), "{s}{s}", .{ parent, name });
            if (std.mem.eql(u8, target, object.key)) {
                self.modal = .none;
                return;
            }
            if (self.demo) {
                if (self.demo_store.get(self.bucket, target)) |_| {
                    self.modal_error = "An object with this name already exists.";
                    return;
                } else |_| {}
                const content = try self.demo_store.get(self.bucket, object.key);
                try self.demo_store.put(self.bucket, target, content);
                try self.demo_store.remove(self.bucket, object.key);
                try self.loadDemo();
                self.modal = .none;
            } else try self.start(cx, .rename, object.key, target);
        },
        .mkdir => {
            const name = std.mem.trim(u8, try self.readField(cx, self.name_field), " /");
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
                self.modal_error = "Enter a single folder name.";
                return;
            }
            const key = try std.fmt.allocPrint(self.arena.allocator(), "{s}{s}/", .{ self.prefix, name });
            for (self.objects) |object| if (std.mem.eql(u8, object.key, key)) {
                self.modal_error = "A folder with this name already exists.";
                return;
            };
            if (self.demo) {
                try self.demo_store.put(self.bucket, key, "");
                try self.loadDemo();
                self.modal = .none;
            } else try self.start(cx, .mkdir, key, "");
        },
        .upload => {
            const path = try self.readField(cx, self.path_field);
            if (!std.fs.path.isAbsolute(path)) {
                self.modal_error = "Enter the full absolute path to a local file.";
                return;
            }
            const entered = std.mem.trim(u8, try self.readField(cx, self.name_field), " ");
            const name = if (entered.len == 0) std.fs.path.basename(path) else entered;
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
                self.modal_error = "Enter an object name without slashes.";
                return;
            }
            const key = try std.fmt.allocPrint(self.arena.allocator(), "{s}{s}", .{ self.prefix, name });
            for (self.objects) |object| if (std.mem.eql(u8, object.key, key)) {
                self.modal_error = "An object with this name exists. Choose another name.";
                return;
            };
            try self.start(cx, .upload, key, path);
        },
        .download => {
            const object = self.selected() orelse return;
            const path = try self.readField(cx, self.path_field);
            if (!std.fs.path.isAbsolute(path)) {
                self.modal_error = if (self.selection.count() > 1 or object.folder)
                    "Enter a full destination folder path."
                else
                    "Enter a full destination path, including the file name.";
                return;
            }
            try self.start(cx, .download, object.key, path);
        },
        .delete => {
            const object = self.selected() orelse return;
            if (self.demo) {
                try @import("object_actions.zig").deleteDemo(self);
                self.modal = .none;
                self.message = "Objects deleted";
            } else try self.start(cx, .delete, object.key, "");
        },
        .none, .signed_url, .palette => {},
    }
}

pub fn showUploadForm(self: *Browser, cx: *ui.Context(Browser)) void {
    self.modal = .upload;
    cx.notify();
}

pub fn showSignedUrl(self: *Browser, cx: *ui.Context(Browser)) !void {
    const object = self.selected() orelse return;
    if (self.demo or object.folder or self.selection.count() != 1) return;
    const a = self.arena.allocator();
    self.signed_url = try @import("../storage/presign.zig")
        .url(
        a,
        .{
            .endpoint = self.endpoint,
            .region = self.region,
            .environment = self.environment,
        },
        self.bucket,
        object.key,
        self.signed_expires,
        try @import("../storage/presign.zig")
            .timestamp(a, std.Io.Clock.real.now(self.io).toSeconds()),
        self.signed_method,
    );
    try cx.update(self.url_field, setField, .{self.signed_url});
    self.modal = .signed_url;
    self.modal_error = "";
    cx.notify();
}

pub fn expiryClick(self: *Browser, _: *ui.Event(ui.Click), cx: *ui.Context(Browser), seconds: u32) !void {
    self.signed_expires = seconds;
    try self.showSignedUrl(cx);
}

pub fn urlReadOnly(_: *Browser, event: *ui.Event(ui.Input), _: *ui.Context(Browser)) void {
    const block = switch (event.data) {
        .text, .edit, .unmark => true,
        .key_down => |key| key.key == .backspace or key.key == .delete or ((key.modifiers.command or key.modifiers.control) and (key.key == .v or key.key == .x)),
        else => false,
    };
    if (block) {
        event.preventDefault();
        event.stopPropagation();
    }
}

pub fn paletteClick(self: *Browser, event: *ui.Event(ui.Click), cx: *ui.Context(Browser), index: usize) !void {
    if (index >= commands.len or !@import("commands.zig")
        .enabled(self, commands[index])) return;
    self.modal = .none;
    try self.onAction(event, cx, commands[index].action);
}

pub fn paletteChanged(self: *Browser, cx: *ui.Context(Browser), _: ui.Entity(Input)) !void {
    self.palette_query = try self.readField(cx, self.palette_field);
    self.palette_index = 0;
    cx.notify();
}
