//! Opt-in provider checks. Every remote write stays below a new, unique prefix.
const std = @import("std");
const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const s3 = @import("../storage/s3.zig");
const upload = @import("../transfers/upload.zig");
const download = @import("../transfers/download.zig");
const presign = @import("../storage/presign.zig");
const curl = @import("../platform/curl_abi.zig");
const driver = @import("test_driver.zig");

pub fn run(init: std.process.Init, environment: *const std.process.Environ.Map) !void {
    const allocator = init.arena.allocator();
    const bucket = environment.get("S3_BUCKET") orelse return error.MissingBucket;
    const client: s3.Client = .{
        .allocator = allocator,
        .io = init.io,
        .config = .{
            .endpoint = environment.get("S3_ENDPOINT") orelse return error.MissingEndpoint,
            .region = environment.get("AWS_REGION") orelse "auto",
            .environment = environment,
            .session_token = environment.get("AWS_SESSION_TOKEN") != null,
        },
    };
    try client.config.validate();

    const prefix = try std.fmt.allocPrint(allocator, "storage-ui-test-{d}/", .{std.Io.Clock.real.now(init.io).nanoseconds});
    const folder = try std.fmt.allocPrint(allocator, "/tmp/{s}", .{std.mem.trimEnd(u8, prefix, "/")});
    try std.Io.Dir.cwd().createDirPath(init.io, folder);
    defer std.Io.Dir.cwd().deleteTree(init.io, folder) catch {};
    defer cleanup(client, bucket, prefix) catch {
        std.debug.print("Cleanup failed. Remove only the test prefix: {s}\n", .{prefix});
    };
    std.debug.print("Live S3 check in {s}\n", .{prefix});

    const text = "Zig storage UI: Unicode café, spaces, plus +, and hash #.\n";
    const binary = try allocator.alloc(u8, 256 * 1024);
    for (binary, 0..) |*byte, index| byte.* = @truncate(index *% 37);
    const first = try std.fs.path.join(allocator, &.{ folder, "café +#.txt" });
    const second = try std.fs.path.join(allocator, &.{ folder, "binary.bin" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = first, .data = text });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = second, .data = binary });

    var app = try ui.App.init(.{ .allocator = init.gpa });
    defer app.deinit();
    const state = try Browser.init(&app, init.gpa, init.io, environment);
    const window = try app.openWindow(Browser, .{ .visible = false, .width = 1440, .height = 900 }, state);
    const root = try app.windowEntity(Browser, window);
    try app.update(root, Browser.attach, .{});
    try app.update(root, Browser.connectSaved, .{});
    try settle(&app, init.io);
    try require(try app.read(root, connected, .{bucket}), "direct bucket connection");

    try driver.click(&app, window, "New folder");
    try app.update(root, nameField, .{std.mem.trimEnd(u8, prefix, "/")});
    try driver.click(&app, window, "Create folder");
    try settle(&app, init.io);
    try app.update(root, Browser.navigate, .{prefix});
    try settle(&app, init.io);
    try require((try client.head(bucket, prefix)).size == 0, "folder marker creation");

    // The same queue and background jobs serve Finder drops and the file picker.
    try app.update(root, Browser.enqueuePaths, .{ &[_][]const u8{ first, second }, prefix });
    try settle(&app, init.io);
    try require(try app.read(root, uploaded, .{}), "two queued uploads and byte progress");
    const first_key = try std.fmt.allocPrint(allocator, "{s}café +#.txt", .{prefix});
    const second_key = try std.fmt.allocPrint(allocator, "{s}binary.bin", .{prefix});
    try require(std.mem.eql(u8, text, try client.request("GET", bucket, first_key, "", &.{})), "Unicode object content");
    try require(std.mem.eql(u8, binary, try client.request("GET", bucket, second_key, "", &.{})), "binary object content");

    var cancellation: ui.tasks.Cancellation = .{};
    var progress: upload.Progress = .{};
    if (upload.send(allocator, init.io, client.config, bucket, first_key, first, &progress, &cancellation)) |_| {
        return error.RemoteObjectOverwritten;
    } else |err| if (err != error.ObjectAlreadyExists) return err;
    try require(std.mem.eql(u8, text, try client.request("GET", bucket, first_key, "", &.{})), "remote collision protection");

    try driver.click(&app, window, "binary.bin");
    try app.update(root, Browser.act, .{.download});
    const destination = try std.fs.path.join(allocator, &.{ folder, "downloaded.bin" });
    try app.update(root, pathField, .{destination});
    try driver.click(&app, window, "Download");
    try settle(&app, init.io);
    const actual = try std.Io.Dir.cwd().readFileAlloc(init.io, destination, allocator, .limited(binary.len + 1));
    try require(std.mem.eql(u8, binary, actual), "UI download round trip");
    if (download.one(client, bucket, first_key, destination)) |_| {
        return error.LocalFileOverwritten;
    } else |err| if (err != error.PathAlreadyExists) return err;
    const preserved = try std.Io.Dir.cwd().readFileAlloc(init.io, destination, allocator, .limited(binary.len + 1));
    try require(std.mem.eql(u8, binary, preserved), "local collision protection");

    try driver.click(&app, window, "café +#.txt");
    try app.update(root, Browser.act, .{.preview});
    try settle(&app, init.io);
    try require(try app.read(root, previewed, .{text}), "text preview");
    try app.update(root, Browser.act, .{.details});
    try app.update(root, Browser.act, .{.signed_url});
    try require(try app.read(root, sharing, .{}), "signed URL dialog");
    const date = try presign.timestamp(allocator, std.Io.Clock.real.now(init.io).toSeconds());
    const signed = try presign.get(allocator, client.config, bucket, first_key, 300, date);
    try verifySigned(allocator, signed, text);
    try app.update(root, Browser.act, .{.dismiss});
    const put_key = try std.fmt.allocPrint(allocator, "{s}signed-upload.txt", .{prefix});
    const put_url = try presign.url(allocator, client.config, bucket, put_key, 300, date, "PUT");
    try verifyPut(allocator, put_url, text);
    try require(std.mem.eql(u8, text, try client.request("GET", bucket, put_key, "", &.{})), "signed PUT content");

    // Copy and rename through the controller, then independently inspect R2.
    try app.update(root, copySelection, .{});
    const nested = try std.fmt.allocPrint(allocator, "{s}copied/", .{prefix});
    try app.update(root, Browser.navigate, .{nested});
    try settle(&app, init.io);
    try app.update(root, pasteSelection, .{});
    try settle(&app, init.io);
    const copied = try std.fmt.allocPrint(allocator, "{s}café +#.txt", .{nested});
    try require(std.mem.eql(u8, text, try client.request("GET", bucket, copied, "", &.{})), "copy into another folder");
    try driver.click(&app, window, "café +#.txt");
    try app.update(root, renameSelection, .{});
    try app.update(root, nameField, .{"renamed.txt"});
    try driver.click(&app, window, "Rename");
    try settle(&app, init.io);
    const renamed = try std.fmt.allocPrint(allocator, "{s}renamed.txt", .{nested});
    try require(std.mem.eql(u8, text, try client.request("GET", bucket, renamed, "", &.{})), "rename preserves content");
    if (client.head(bucket, copied)) |_| return error.RenameLeftSource else |err| if (err != error.NoSuchKey) return err;

    try app.update(root, Browser.navigate, .{prefix});
    try settle(&app, init.io);
    try app.update(root, Browser.act, .{.select_all});
    try app.update(root, Browser.act, .{.download});
    const group_destination = try std.fs.path.join(allocator, &.{ folder, "group" });
    try app.update(root, pathField, .{group_destination});
    try driver.click(&app, window, "Download");
    try settle(&app, init.io);
    const nested_file = try std.fs.path.join(allocator, &.{ group_destination, "copied", "renamed.txt" });
    try require(std.mem.eql(u8, text, try std.Io.Dir.cwd().readFileAlloc(init.io, nested_file, allocator, .limited(1024))), "folder download preserves structure");

    try app.update(root, Browser.act, .{.delete});
    try driver.click(&app, window, "Delete");
    try settle(&app, init.io);
    try require((try client.objects(bucket, prefix, true)).len == 0, "recursive selected deletion");
    try cleanup(client, bucket, prefix);
    std.debug.print("Live S3 checks passed; temporary remote objects removed.\n", .{});
}

fn require(condition: bool, label: []const u8) !void {
    if (!condition) {
        std.debug.print("FAIL: {s}\n", .{label});
        return error.LiveS3CheckFailed;
    }
    std.debug.print("PASS: {s}\n", .{label});
}

fn settle(app: *ui.App, io: std.Io) !void {
    const start = std.Io.Clock.awake.now(io).toSeconds();
    while (try app.tasksPending()) {
        if (std.Io.Clock.awake.now(io).toSeconds() - start > 120) return error.LiveS3Timeout;
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    _ = try app.step(0);
}

fn cleanup(client: s3.Client, bucket: []const u8, prefix: []const u8) !void {
    if (!std.mem.startsWith(u8, prefix, "storage-ui-test-") or !std.mem.endsWith(u8, prefix, "/")) return error.InvalidTestPrefix;
    for (try client.objects(bucket, prefix, true)) |object| {
        if (!std.mem.startsWith(u8, object.key, prefix)) return error.UnsafeCleanup;
        _ = try client.request("DELETE", bucket, object.key, "", &.{});
    }
    _ = try client.request("DELETE", bucket, prefix, "", &.{});
}

fn connected(self: *const Browser, bucket: []const u8) bool {
    return !self.demo and !self.busy and std.mem.eql(u8, self.bucket, bucket);
}

fn uploaded(self: *const Browser) bool {
    return self.completed == 2 and self.failed == 0 and self.uploads.items.len == 2 and
        self.progress.sent.load(.acquire) == 256 * 1024 and self.progress.total.load(.acquire) == 256 * 1024;
}

fn previewed(self: *const Browser, text: []const u8) bool {
    return self.preview.open and std.mem.eql(u8, self.preview.bytes, text);
}

fn sharing(self: *const Browser) bool {
    return self.modal == .signed_url and self.signed_url.len > 0;
}

fn nameField(self: *Browser, cx: *ui.Context(Browser), value: []const u8) !void {
    try cx.update(self.name_field, Browser.setField, .{value});
}

fn pathField(self: *Browser, cx: *ui.Context(Browser), value: []const u8) !void {
    try cx.update(self.path_field, Browser.setField, .{value});
}

fn copySelection(self: *Browser, cx: *ui.Context(Browser)) !void {
    _ = try @import("../app/object_actions.zig").handle(self, cx, .copy);
}

fn pasteSelection(self: *Browser, cx: *ui.Context(Browser)) !void {
    _ = try @import("../app/object_actions.zig").handle(self, cx, .paste);
}

fn renameSelection(self: *Browser, cx: *ui.Context(Browser)) !void {
    _ = try @import("../app/object_actions.zig").handle(self, cx, .rename);
}

const SignedResponse = struct {
    expected: []const u8,
    offset: usize = 0,

    fn receive(bytes: [*c]u8, size: usize, count: usize, raw: ?*anyopaque) callconv(.c) usize {
        const self: *SignedResponse = @ptrCast(@alignCast(raw.?));
        const length = size * count;
        if (length > self.expected.len - self.offset) return 0;
        if (!std.mem.eql(u8, bytes[0..length], self.expected[self.offset..][0..length])) return 0;
        self.offset += length;
        return length;
    }
};

const SignedUpload = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn read(destination: [*c]u8, size: usize, count: usize, raw: ?*anyopaque) callconv(.c) usize {
        const self: *SignedUpload = @ptrCast(@alignCast(raw.?));
        const length = @min(size * count, self.bytes.len - self.offset);
        @memcpy(destination[0..length], self.bytes[self.offset..][0..length]);
        self.offset += length;
        return length;
    }
};

fn verifyPut(allocator: std.mem.Allocator, url: []const u8, bytes: []const u8) !void {
    const easy = curl.curl_easy_init() orelse return error.CurlInitFailed;
    defer curl.curl_easy_cleanup(easy);
    const terminated = try allocator.dupeSentinel(u8, url, 0);
    var source: SignedUpload = .{ .bytes = bytes };
    var response: SignedResponse = .{ .expected = "" };
    if (curl.curl_easy_setopt(easy, curl.CURLOPT_URL, terminated.ptr) != 0 or
        curl.curl_easy_setopt(easy, curl.CURLOPT_UPLOAD, @as(c_long, 1)) != 0 or
        curl.curl_easy_setopt(easy, curl.CURLOPT_INFILESIZE_LARGE, @as(curl.curl_off_t, @intCast(bytes.len))) != 0 or
        curl.curl_easy_setopt(easy, curl.CURLOPT_READFUNCTION, &SignedUpload.read) != 0 or
        curl.curl_easy_setopt(easy, curl.CURLOPT_READDATA, @as(*anyopaque, @ptrCast(&source))) != 0 or
        curl.curl_easy_setopt(easy, curl.CURLOPT_WRITEFUNCTION, &SignedResponse.receive) != 0 or
        curl.curl_easy_setopt(easy, curl.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&response))) != 0 or
        curl.curl_easy_setopt(easy, curl.CURLOPT_TIMEOUT, @as(c_long, 30)) != 0) return error.CurlOptionFailed;

    const result = curl.curl_easy_perform(easy);
    var status: c_long = 0;
    _ = curl.curl_easy_getinfo(easy, curl.CURLINFO_RESPONSE_CODE, &status);
    try require(result == 0 and status == 200 and source.offset == bytes.len, "signed PUT URL");
}

fn verifySigned(allocator: std.mem.Allocator, url: []const u8, expected: []const u8) !void {
    const easy = curl.curl_easy_init() orelse return error.CurlInitFailed;
    defer curl.curl_easy_cleanup(easy);
    const terminated = try allocator.dupeSentinel(u8, url, 0);
    var response: SignedResponse = .{ .expected = expected };
    if (curl.curl_easy_setopt(easy, curl.CURLOPT_URL, terminated.ptr) != 0 or
        curl.curl_easy_setopt(easy, curl.CURLOPT_WRITEFUNCTION, &SignedResponse.receive) != 0 or
        curl.curl_easy_setopt(easy, curl.CURLOPT_WRITEDATA, @as(*anyopaque, @ptrCast(&response))) != 0 or
        curl.curl_easy_setopt(easy, curl.CURLOPT_TIMEOUT, @as(c_long, 30)) != 0) return error.CurlOptionFailed;

    const result = curl.curl_easy_perform(easy);
    var status: c_long = 0;
    _ = curl.curl_easy_getinfo(easy, curl.CURLINFO_RESPONSE_CODE, &status);
    try require(result == 0 and status == 200 and response.offset == expected.len, "signed GET URL and exact content");
}
