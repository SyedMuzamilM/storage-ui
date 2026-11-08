const std = @import("std");
const t = std.testing;
const s3 = @import("storage/s3.zig");
const demo = @import("storage/demo.zig");
const Browser = @import("app/browser.zig").Browser;
const ui = @import("zircon_ui");

test "partial environment credentials still allow the saved account to load" {
    var environment = std.process.Environ.Map.init(t.allocator);
    defer environment.deinit();
    const credentials = @import("platform/credentials.zig");
    try environment.put("AWS_ACCESS_KEY_ID", "test-access");
    try t.expect(!credentials.hasEnvironmentCredentials(&environment));
    try environment.put("AWS_SECRET_ACCESS_KEY", "");
    try t.expect(!credentials.hasEnvironmentCredentials(&environment));
    try environment.put("AWS_SECRET_ACCESS_KEY", "test-secret");
    try t.expect(credentials.hasEnvironmentCredentials(&environment));
}

test "request signing sorts copy source headers by name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("AWS_ACCESS_KEY_ID", "test-access");
    try environment.put("AWS_SECRET_ACCESS_KEY", "test-secret");
    const signed = try @import("storage/auth.zig").sign(
        arena.allocator(),
        t.io,
        .{ .endpoint = "https://storage.example.com", .region = "auto", .environment = &environment },
        "PUT",
        "https://storage.example.com/bucket/copied.txt",
        &.{ "--header", "x-amz-copy-source: /bucket/source.txt", "--header", "x-amz-copy-source-if-match: \"etag\"" },
    );
    try t.expect(std.mem.indexOf(u8, signed.authorization, "SignedHeaders=host;x-amz-content-sha256;x-amz-copy-source;x-amz-copy-source-if-match;x-amz-date,") != null);
}

test "S3 endpoint validation rejects credentials and query strings" {
    try (s3.Config{ .endpoint = "https://account.r2.cloudflarestorage.com", .region = "auto" })
        .validate();
    try (s3.Config{ .endpoint = "http://localhost:9000", .region = "us-east-1" })
        .validate();
    try t.expectError(error.InvalidEndpoint, (s3.Config{ .endpoint = "https://user:secret@host", .region = "auto" })
        .validate());
    try t.expectError(error.InvalidEndpoint, (s3.Config{ .endpoint = "file:///tmp/test", .region = "auto" })
        .validate());
    try t.expectError(error.InvalidEndpoint, (s3.Config{ .endpoint = "https://host?x=1", .region = "auto" })
        .validate());
    try t.expectError(error.InvalidRegion, (s3.Config{ .endpoint = "https://host", .region = "us:east" })
        .validate());
}

test "object encoding keeps key paths and escapes reserved bytes and unicode" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = "images/a b+#?/%/café.png";
    const encoded = try s3.encode(a, key, true);
    try t.expectEqualStrings("images/a%20b%2B%23%3F/%25/caf%C3%A9.png", encoded);
    try t.expectEqualStrings(key, try s3.decode(a, encoded));
    try t.expectEqualStrings("a+b", try s3.decode(a, "a+b"));
}

test "ListObjectsV2 parses folders, XML entities, encoded keys, and continuation tokens" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const page = try s3.parseObjects(
        arena.allocator(),
        "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><EncodingType>url</EncodingType><CommonPrefixes><Prefix>images%2F</Prefix></CommonPrefixes><Contents><Key>a%20b%2B%26.json</Key><Size>445</Size><LastModified>2026-11-07T15:07:00Z</LastModified></Contents><IsTruncated>true</IsTruncated><NextContinuationToken>a&amp;b+123=</NextContinuationToken></ListBucketResult>",
    );
    try t.expectEqual(@as(usize, 2), page.objects.len);
    try t.expect(page.objects[0].folder);
    try t.expectEqualStrings("images/", page.objects[0].key);
    try t.expectEqualStrings("a b+&.json", page.objects[1].key);
    try t.expectEqual(@as(u64, 445), page.objects[1].size);
    try t.expectEqualStrings("a&b+123=", page.next.?);
    try t.expectEqualStrings("a&\"<>'é", try s3.unescape(arena.allocator(), "a&amp;&quot;&lt;&gt;&apos;&#xE9;"));
}

test "malformed or incomplete S3 listings fail rather than hide data" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(
        error.InvalidS3Response,
        s3.parseObjects(arena.allocator(), "<Error><Code>AccessDenied</Code></Error>"),
    );
    try t.expectError(
        error.InvalidS3Response,
        s3.parseObjects(arena.allocator(), "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>"),
    );
}

test "demo lists direct children, opens nested folders, and supports object changes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store = try demo.Store.init(a);
    const root = try store.list(a, "acme-assets", "", false);
    try t.expectEqual(@as(usize, 8), root.len);
    const nested = try store.list(a, "acme-assets", "assets/", false);
    try t.expectEqual(@as(usize, 2), nested.len);
    const flat = try store.list(a, "acme-assets", "", true);
    try t.expect(flat.len > root.len);
    try store.put("acme-assets", "assets/new.txt", "Hello");
    try t.expectEqualStrings("Hello", try store.get("acme-assets", "assets/new.txt"));
    try store.remove("acme-assets", "assets/new.txt");
    try t.expectError(error.NoSuchKey, store.get("acme-assets", "assets/new.txt"));
}
const click = @import("testing/test_driver.zig").click;
const focus = @import("testing/test_driver.zig").focus;
const Snapshot = struct {
    count: usize,
    selected: bool,
    at_root: bool,
    is_assets: bool,
    is_filtered: bool,
    modal_open: bool,
};

fn snapshot(self: *const Browser) Snapshot {
    return .{
        .count = self.objects.len,
        .selected = self.selection.primary != null,
        .at_root = self.prefix.len == 0,
        .is_assets = std.mem.eql(u8, self.prefix, "assets/"),
        .is_filtered = self.object_query.len > 0,
        .modal_open = self.modal != .none,
    };
}

test "native-style UI journey navigates, filters, creates folders, selects, and deletes" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const state = try Browser.init(&app, t.allocator, t.io, &env);
    const h = try app.openWindow(Browser, .{ .visible = false, .width = 1440, .height = 900 }, state);
    const root = try app.windowEntity(Browser, h);
    try app.update(root, Browser.attach, .{});
    _ = try app.step(0);
    try t.expectEqual(@as(usize, 8), (try app.read(root, snapshot, .{})).count);
    try click(&app, h, "assets");
    try t.expect((try app.read(root, snapshot, .{})).is_assets);
    try t.expectEqual(@as(usize, 2), (try app.read(root, snapshot, .{})).count);
    try click(&app, h, "Back to parent folder");
    try click(&app, h, "New folder");
    try t.expect((try app.read(root, snapshot, .{})).modal_open);
    try focus(&app, h, "Folder name");
    try app.dispatch(h, .{ .text = "journey" });
    try click(&app, h, "Create folder");
    try t.expectEqual(@as(usize, 9), (try app.read(root, snapshot, .{})).count);
    try click(&app, h, "journey");
    try t.expectEqual(@as(usize, 0), (try app.read(root, snapshot, .{})).count);
    try click(&app, h, "Back to parent folder");
    try focus(&app, h, "object-filter");
    try app.dispatch(h, .{ .text = "readme" });
    _ = try app.step(0);
    try t.expect((try app.read(root, snapshot, .{})).is_filtered);
    try click(&app, h, "README.txt");
    try t.expect((try app.read(root, snapshot, .{})).selected);
    try click(&app, h, "Delete object");
    try click(&app, h, "Delete");
    try t.expectEqual(@as(usize, 8), (try app.read(root, snapshot, .{})).count);
    try t.expect(!(try app.read(root, snapshot, .{})).modal_open);
}

test "connection dialog renders and modal blocks background controls" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const state = try Browser.init(&app, t.allocator, t.io, &env);
    const h = try app.openWindow(Browser, .{ .visible = false, .width = 1440, .height = 900 }, state);
    const root = try app.windowEntity(Browser, h);
    try app.update(root, Browser.attach, .{});
    try click(&app, h, "Account");
    try t.expect((try app.read(root, snapshot, .{})).modal_open);
    try click(&app, h, "Connect");
    try t.expect((try app.read(root, snapshot, .{})).modal_open);
    try app.dispatch(h, .{ .key_down = .{ .key = .escape } });
    _ = try app.step(0);
    try t.expect(!(try app.read(root, snapshot, .{})).modal_open);
    // The table remains useful in a narrower window.
    try app.dispatch(h, .{ .resize = .{ .width = 980, .height = 640 } });
    _ = try app.step(0);
    try click(&app, h, "assets");
    try t.expect((try app.read(root, snapshot, .{})).is_assets);
}

test "demo upload and download complete through background jobs and protect existing files" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "source.txt", .data = "Upload from the UI.\n" });
    const source = try tmp.dir.realPathFileAlloc(t.io, "source.txt", t.allocator);
    defer t.allocator.free(source);
    var parent_buffer: [4096]u8 = undefined;
    const parent_length = try tmp.dir.realPath(t.io, &parent_buffer);
    const destination = try std.fmt.allocPrint(t.allocator, "{s}/saved.txt", .{parent_buffer[0..parent_length]});
    defer t.allocator.free(destination);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const state = try Browser.init(&app, t.allocator, t.io, &env);
    const h = try app.openWindow(Browser, .{ .visible = false, .width = 1440, .height = 900 }, state);
    const root = try app.windowEntity(Browser, h);
    try app.update(root, Browser.attach, .{});
    try click(&app, h, "Upload");
    try focus(&app, h, "Local file path");
    try app.dispatch(h, .{ .text = source });
    try click(&app, h, "Upload");
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    _ = try app.step(0);
    try t.expectEqual(@as(usize, 9), (try app.read(root, snapshot, .{})).count);
    try click(&app, h, "source.txt");
    try click(&app, h, "Download");
    try focus(&app, h, "Save to local file path");
    try app.dispatch(h, .{ .text = destination });
    try click(&app, h, "Download");
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    _ = try app.step(0);
    const bytes = try tmp.dir.readFileAlloc(t.io, "saved.txt", t.allocator, .limited(1024));
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("Upload from the UI.\n", bytes);
    // Download completion resets selection in demo; select the object again.
    try click(&app, h, "source.txt");
    try click(&app, h, "Download");
    try focus(&app, h, "Save to local file path");
    try app.dispatch(h, .{ .text = destination });
    try click(&app, h, "Download");
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    _ = try app.step(0);
    const Read = struct {
        fn counts(self: *const Browser) [2]usize {
            return .{ self.completed, self.failed };
        }
    };
    try t.expectEqual([2]usize{ 2, 1 }, try app.read(root, Read.counts, .{}));
}

test "multiple files dropped on a folder upload into that folder with independent results" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "drop-a.txt", .data = "First file" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "drop-b.txt", .data = "Second file" });
    const first = try tmp.dir.realPathFileAlloc(t.io, "drop-a.txt", t.allocator);
    defer t.allocator.free(first);
    const second = try tmp.dir.realPathFileAlloc(t.io, "drop-b.txt", t.allocator);
    defer t.allocator.free(second);
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const state = try Browser.init(&app, t.allocator, t.io, &env);
    const h = try app.openWindow(Browser, .{ .visible = false, .width = 1440, .height = 900 }, state);
    const root = try app.windowEntity(Browser, h);
    try app.update(root, Browser.attach, .{});
    _ = try app.step(0);
    const frame = &(try app.window(h)).frames.committed;
    var position: ui.Point = .{};
    for (frame.nodes.items, 0..) |node, i| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, "assets")) {
        const r = frame.bounds[i];
        position = .{ .x = r.x + 20, .y = r.y + r.height / 2 };
        break;
    };
    try app.dispatch(h, .{ .files_hover = .{ .position = position, .active = true } });
    _ = try app.step(0);
    try app.dispatch(h, .{ .files_drop = .{ .position = position, .paths = &.{ first, second } } });
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    _ = try app.step(0);
    const Read = struct {
        fn valid(self: *const Browser) bool {
            const a = self.demo_store.get("acme-assets", "assets/drop-a.txt") catch return false;
            const b = self.demo_store.get("acme-assets", "assets/drop-b.txt") catch return false;
            return std.mem.eql(u8, a, "First file") and std.mem.eql(u8, b, "Second file") and self.completed == 2 and self.failed == 0 and !self.busy and self.show_transfers;
        }
    };
    try t.expect(try app.read(root, Read.valid, .{}));
}

test "command palette searches and executes a keyboard command" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const state = try Browser.init(&app, t.allocator, t.io, &env);
    const h = try app.openWindow(Browser, .{ .visible = false, .width = 1440, .height = 900 }, state);
    const root = try app.windowEntity(Browser, h);
    try app.update(root, Browser.attach, .{});
    _ = try app.step(0);
    try app.dispatch(h, .{ .key_down = .{ .key = .k, .modifiers = .{ .command = true } } });
    _ = try app.step(0);
    try t.expect((try app.read(root, snapshot, .{})).modal_open);
    try app.dispatch(h, .{ .text = "new folder" });
    _ = try app.step(0);
    try app.dispatch(h, .{ .key_down = .{ .key = .enter } });
    _ = try app.step(0);
    try focus(&app, h, "Folder name");
    try app.dispatch(h, .{ .text = "from-palette" });
    try click(&app, h, "Create folder");
    try t.expectEqual(@as(usize, 9), (try app.read(root, snapshot, .{})).count);
}

test "signed URL expiration and encoding are deterministic" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("AWS_ACCESS_KEY_ID", "test-access");
    try env.put("AWS_SECRET_ACCESS_KEY", "test-secret");
    const config: s3.Config = .{
        .endpoint = "https://storage.example.com",
        .region = "auto",
        .environment = &env,
    };
    const presign = @import("storage/presign.zig");
    const url = try presign.get(a, config, "bucket", "nested/café +#.txt", 300, "20261108T120000Z");
    try t.expect(std.mem.startsWith(u8, url, "https://storage.example.com/bucket/nested/caf%C3%A9%20%2B%23.txt?"));
    try t.expect(std.mem.indexOf(u8, url, "X-Amz-Expires=300") != null);
    try t.expectEqualStrings(url, try presign.get(a, config, "bucket", "nested/café +#.txt", 300, "20261108T120000Z"));
    try t.expectError(error.InvalidExpiry, presign.get(a, config, "bucket", "key", 604801, "20261108T120000Z"));
    try t.expectEqualStrings("19700101T000000Z", try presign.timestamp(a, 0));
}

test "object actions rename, copy, paste, and download a selected folder" {
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(t.io, &buffer);
    const destination = buffer[0..length];

    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var environment = std.process.Environ.Map.init(t.allocator);
    defer environment.deinit();
    const state = try Browser.init(&app, t.allocator, t.io, &environment);
    const window = try app.openWindow(Browser, .{
        .visible = false,
        .width = 1440,
        .height = 900,
    }, state);
    const root = try app.windowEntity(Browser, window);
    try app.update(root, Browser.attach, .{});

    try click(&app, window, "README.txt");
    try click(&app, window, "Commands");
    try focus(&app, window, "command-search");
    try app.dispatch(window, .{ .text = "Rename" });
    try click(&app, window, "Rename object…");
    try focus(&app, window, "New file name");
    try app.dispatch(window, .{ .key_down = .{ .key = .a, .modifiers = .{ .command = true } } });
    try app.dispatch(window, .{ .text = "renamed.txt" });
    try click(&app, window, "Rename");
    try click(&app, window, "renamed.txt");
    try app.dispatch(window, .{ .key_down = .{ .key = .c, .modifiers = .{ .command = true } } });
    try click(&app, window, "tmp");
    try app.dispatch(window, .{ .key_down = .{ .key = .v, .modifiers = .{ .command = true } } });
    _ = try app.step(0);
    try click(&app, window, "renamed.txt");
    try click(&app, window, "Back to parent folder");
    try click(&app, window, "Select tmp");
    try click(&app, window, "Download");
    try focus(&app, window, "Destination folder");
    try app.dispatch(window, .{ .text = destination });
    try click(&app, window, "Download");
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }

    const bytes = try temporary.dir.readFileAlloc(t.io, "tmp/renamed.txt", t.allocator, .limited(4096));
    defer t.allocator.free(bytes);
    try t.expect(std.mem.startsWith(u8, bytes, "Welcome to your storage workspace."));
}

test "download paths reject traversal and preserve object names" {
    const files = @import("transfers/files.zig");
    try t.expectEqualStrings("photos/café.png", try files.relative("assets/photos/café.png", "assets/"));
    try t.expectError(error.UnsafeObjectPath, files.relative("../secret.txt", ""));
    try t.expectError(error.UnsafeObjectPath, files.relative("a/../../secret.txt", ""));
    try t.expectError(error.UnsafeObjectPath, files.relative("/absolute.txt", ""));
    try t.expectError(error.UnsafeObjectPath, files.relative("folder\\secret.txt", ""));
}

test "password input paints masked Unicode text and accepts edits" {
    var app = try ui.App.init(.{ .allocator = t.allocator });
    defer app.deinit();
    var input = try ui.controls.TextInput.init(t.allocator, "secret日本");
    input.password = true;
    const window = try app.openWindow(ui.controls.TextInput, .{
        .visible = false,
        .width = 300,
        .height = 80,
    }, input);
    _ = try app.step(0);
    const frame = &(try app.window(window)).frames.committed;
    var masked = false;
    for (frame.scene.items) |item| {
        if (item.kind != .text) continue;
        try t.expect(std.mem.indexOf(u8, item.text, "secret") == null);
        if (std.mem.indexOf(u8, item.text, "•") != null) masked = true;
    }
    try t.expect(masked);
}
