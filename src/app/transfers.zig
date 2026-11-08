const std = @import("std");
const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const s3 = @import("../storage/s3.zig");
const jobs = @import("../storage/jobs.zig");
const Input = ui.controls.TextInput;
const errorText = Browser.errorText;

pub fn start(self: *Browser, cx: *ui.Context(Browser), kind: jobs.Kind, key: []const u8, path: []const u8) !void {
    if (self.busy) return;

    const arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(std.heap.page_allocator);
    errdefer {
        arena.deinit();
        std.heap.page_allocator.destroy(arena);
    }

    const a = arena.allocator();
    const environment = try a.create(std.process.Environ.Map);
    environment.* = try self.environment.clone(a);

    var selected: std.ArrayList([]const u8) = .empty;
    var contents: std.ArrayList([]const u8) = .empty;
    const directory_download = kind == .download and (self.selection.count() > 1 or (self.selected() != null and self.selected().?.folder));
    if (kind == .delete or kind == .download) for (self.objects, 0..) |object, index| {
        if (!self.selection.contains(index)) continue;
        if (self.demo and directory_download) {
            if (object.folder) {
                for (try self.demo_store.list(a, self.bucket, object.key, true)) |child| {
                    try selected.append(a, try a.dupe(u8, child.key));
                    try contents.append(a, try a.dupe(u8, self.demo_store.get(self.bucket, child.key) catch ""));
                }
            }
            try contents.append(a, try a.dupe(u8, self.demo_store.get(self.bucket, object.key) catch ""));
        }
        try selected.append(a, try a.dupe(u8, object.key));
    };
    if (kind == .copy or kind == .move) for (self.clipboard.keys) |source_key| try selected.append(a, try a.dupe(u8, source_key));

    const job: jobs.Job = .{
        .arena = arena,
        .io = self.io,
        .kind = kind,
        .config = .{
            .endpoint = try a.dupe(u8, self.endpoint),
            .region = try a.dupe(u8, self.region),
            .session_token = self.session_token,
            .environment = environment,
        },
        .bucket = try a.dupe(u8, if (kind == .connect) self.initial_bucket else self.bucket),
        .prefix = try a.dupe(u8, self.prefix),
        .key = try a.dupe(u8, key),
        .keys = try selected.toOwnedSlice(a),
        .source_bucket = try a.dupe(u8, if (kind == .copy or kind == .move) self.clipboard.bucket else self.bucket),
        .source_prefix = try a.dupe(u8, self.clipboard.prefix),
        .destination_key = try a.dupe(u8, if (kind == .rename) path else ""),
        .path = try a.dupe(u8, path),
        .flat = self.flat,
        .demo = self.demo,
        .directory_download = directory_download,
        .demo_downloads = try contents.toOwnedSlice(a),
        .progress = if (kind == .upload or kind == .download) self.progress else null,
        .demo_content = if (self.demo and !directory_download and (kind == .download or kind == .preview)) try a.dupe(u8, try self.demo_store.get(self.bucket, key)) else "",
    };

    self.active_job = try cx.spawn(jobs.Job, job, complete);
    self.transfer_started = std.Io.Clock.awake.now(self.io).toMilliseconds();
    self.progress_speed = 0;
    self.pending = kind;
    self.pending_key = try self.keep(key);
    self.pending_path = try self.keep(path);
    self.busy = true;
    self.message = "";
    self.modal = .none;
    self.modal_error = "";
    cx.notify();
}

pub fn complete(self: *Browser, cx: *ui.Context(Browser), result: anyerror!jobs.Result) !void {
    self.busy = false;
    self.active_job = null;

    const output = result catch |err| {
        try recordFailure(self, cx, errorText(err));
        return;
    };
    if (self.pending == .preview) {
        if (self.preview.image) |*image| image.deinit();
        self.allocator.free(self.preview.bytes);
        self.preview.bytes = try self.allocator.dupe(u8, output.content);
        self.preview.image = ui.graphics.images.Image.load(self.allocator, output.content) catch null;
        self.preview.open = true;
        self.preview.fit = true;
        self.preview.zoom = 1;
        self.preview.scroll = .{};
        self.preview.truncated = output.content.len >= 1048576;
        const display = if (std.unicode.utf8ValidateSlice(output.content)) output.content else try @import("../views/preview.zig")
            .hex(self.arena.allocator(), output.content);
        try cx.update(self.preview_field, @import("../views/editor_field.zig").EditorField.replace, .{ display, true });
        cx.notify();
        return;
    }

    if (output.items.len == 0 and (self.pending == .upload or self.pending == .download)) {
        self.completed += 1;
        try self.addTransfer(self.pending_key, if (self.pending == .upload) "Uploaded" else "Downloaded", false);
    }

    if (self.demo and self.pending != .download) {
        if (self.pending == .upload) try self.demo_store.put(self.bucket, self.pending_key, output.content);
        try self.loadDemo();
    } else if (self.pending != .download and output.listing_ok) {
        // Preserve the bucket list while replacing just the object page.
        const saved_buckets = try self.arena.allocator()
            .alloc(s3.Bucket, if (self.pending == .connect) output.buckets.len else self.buckets.len);
        for (if (self.pending == .connect) output.buckets else self.buckets, saved_buckets) |bucket, *dest| dest.* = .{ .name = try self.keep(bucket.name), .region = try self.keep(bucket.region) };
        _ = self.listing.reset(.retain_capacity);
        const a = self.listing.allocator();
        self.buckets = try a.dupe(s3.Bucket, saved_buckets);
        self.objects = try a.alloc(s3.Object, output.objects.len);
        for (output.objects, self.objects) |object, *dest| dest.* = .{
            .key = try a.dupe(u8, object.key),
            .size = object.size,
            .modified = try a.dupe(u8, object.modified),
            .folder = object.folder,
        };
        self.bucket = try self.keep(output.bucket);
        self.sortObjects();
        self.selection.clear();
        self.preview.open = false;
        self.scroll.offset = 0;
        self.recordListing();
    }

    self.message = switch (self.pending) {
        .upload => "Upload completed",
        .download => "Download completed",
        .mkdir => "Folder created",
        .delete => "Object deleted",
        .connect => "Connected",
        .list => "",
        .preview => "",
        .copy => "Copied objects",
        .move => "Moved objects",
        .rename => "Object renamed",
    };
    if (output.items.len > 0) {
        var succeeded: usize = 0;
        for (output.items) |item| {
            if (item.success) {
                succeeded += 1;
                if (self.pending == .download) self.completed += 1;
            } else self.failed += 1;
            try self.addTransfer(item.key, if (item.success) "Completed" else item.detail, !item.success);
        }
        self.message = try std.fmt.allocPrint(self.arena.allocator(), "{d} objects completed; {d} failed", .{ succeeded, output.items.len - succeeded });
    }
    if (self.pending == .upload) try self.finishUpload(cx, false);
    if (!output.listing_ok) self.message = "Saved to S3. Refresh failed; use Refresh to reload the folder.";
    cx.notify();
}

fn recordFailure(self: *Browser, cx: *ui.Context(Browser), message: []const u8) !void {
    self.message = try self.keep(message);
    if (self.pending == .connect) {
        self.demo = true;
        self.bucket = "acme-assets";
        self.prefix = "";
        try self.loadDemo();
    }
    if (self.pending == .list) {
        self.bucket = self.listed_bucket;
        self.prefix = self.listed_prefix;
        self.region = self.listed_region;
        self.flat = self.listed_flat;
    }
    if (self.pending == .upload or self.pending == .download) {
        if (!std.mem.eql(u8, message, "Canceled")) self.failed += 1;
        try self.addTransfer(self.pending_key, self.message, !std.mem.eql(u8, message, "Canceled"));
    }
    if (self.pending == .upload) try self.finishUpload(cx, true);
    cx.notify();
}

pub fn addTransfer(self: *Browser, name: []const u8, detail: []const u8, failed: bool) !void {
    try self.history.append(self.arena.allocator(), .{ .name = try self.keep(name), .detail = try self.keep(detail), .failed = failed });
}

pub fn progressChanged(self: *Browser, cx: *ui.Context(Browser)) void {
    const sent = self.progress.sent.load(.acquire);
    const total = self.progress.total.load(.acquire);
    if (sent == self.progress_sent and total == self.progress_total) return;
    const elapsed = @max(1, std.Io.Clock.awake.now(self.io).toMilliseconds() - self.transfer_started);
    self.progress_speed = @intFromFloat(@as(f64, @floatFromInt(sent)) * 1000 / @as(f64, @floatFromInt(elapsed)));
    self.progress_sent = sent;
    self.progress_total = total;
    cx.notify();
}

pub fn enqueuePaths(self: *Browser, cx: *ui.Context(Browser), paths: []const []const u8, prefix: []const u8) !void {
    if (self.bucket.len == 0 or (self.busy and self.pending != .upload)) return;
    for (paths) |path| {
        if (!std.fs.path.isAbsolute(path)) continue;
        const key = try std.fmt.allocPrint(self.arena.allocator(), "{s}{s}", .{ prefix, std.fs.path.basename(path) });
        var duplicate = false;
        for (self.objects) |object| if (std.mem.eql(u8, object.key, key)) {
            duplicate = true;
            break;
        };
        for (self.uploads.items[self.upload_cursor..]) |upload| if (std.mem.eql(u8, upload.key, key)) {
            duplicate = true;
            break;
        };
        if (duplicate) {
            self.failed += 1;
            try self.addTransfer(key, "An object with this name already exists", true);
            continue;
        }
        var bytes: u64 = 0;
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch null;
        if (file) |f| {
            defer f.close(self.io);
            const file_info = f.stat(self.io) catch null;
            if (file_info) |s| bytes = s.size;
        }
        try self.uploads.append(self.arena.allocator(), .{ .path = try self.keep(path), .key = key, .bytes = bytes });
    }
    self.show_transfers = true;
    self.modal = .none;
    self.drop_active = false;
    self.drop_folder = null;
    if (!self.busy) try self.startNextUpload(cx);
    cx.notify();
}

pub fn startNextUpload(self: *Browser, cx: *ui.Context(Browser)) !void {
    if (self.upload_cursor >= self.uploads.items.len) {
        self.active_upload = null;
        return;
    }
    self.active_upload = self.upload_cursor;
    self.uploads.items[self.upload_cursor].status = .uploading;
    self.progress.reset();
    self.progress_sent = 0;
    self.progress_total = self.uploads.items[self.upload_cursor].bytes;
    const upload = self.uploads.items[self.upload_cursor];
    try self.start(cx, .upload, upload.key, upload.path);
}

pub fn finishUpload(self: *Browser, cx: *ui.Context(Browser), failed: bool) !void {
    if (self.active_upload) |index| {
        self.uploads.items[index].status = if (failed and std.mem.eql(u8, self.message, "Canceled")) .canceled else if (failed) .failed else .complete;
        self.uploads.items[index].detail = try self.keep(self.message);
        self.upload_cursor = index + 1;
        self.active_upload = null;
        try self.startNextUpload(cx);
    }
}

pub fn folderDrop(self: *Browser, event: *ui.Event(ui.Input), cx: *ui.Context(Browser), index: usize) !void {
    if (index >= self.objects.len) return;
    if (event.data != .pointer_down and !self.objects[index].folder) return;
    switch (event.data) {
        .pointer_down => |pointer| {
            if (pointer.button != .secondary) return;
            try self.selection.replace(self.arena.allocator(), index);
            try self.act(cx, .palette);
        },
        .files_hover => |hover| {
            self.drop_active = hover.active;
            self.drop_folder = if (hover.active) index else null;
            cx.notify();
        },
        .files_drop => |drop| {
            try self.enqueuePaths(cx, drop.paths, self.objects[index].key);
        },
        else => return,
    }
    event.stopPropagation();
    event.preventDefault();
}
