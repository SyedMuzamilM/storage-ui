const std = @import("std");
const ui = @import("zircon_ui");
const Browser = @import("app/browser.zig").Browser;
const credentials = @import("platform/credentials.zig");
const s3 = @import("storage/s3.zig");
const presign = @import("storage/presign.zig");
const curl = @import("platform/curl_abi.zig");

pub const Scene = enum {
    browser,
    folder,
    object,
    connection,
    upload,
    palette,
    transfers,
    narrow,
    preview,
};

pub const Options = struct {
    screenshot: ?[]const u8 = null,
    scene: Scene = .browser,
    inspect: bool = false,
    verify_url: bool = false,
    test_s3: bool = false,
    remember: bool = false,
    demo: bool = false,
    help: bool = false,
};

pub fn parse(init: std.process.Init, environment: *std.process.Environ.Map) !Options {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var options: Options = .{};
    var index: usize = 1;

    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--account-stdin")) {
            var buffer: [16384]u8 = undefined;
            var reader = std.Io.File.stdin().reader(init.io, &buffer);
            const line = try reader.interface.takeDelimiterExclusive('\n');
            const parsed = try std.json.parseFromSlice(
                credentials.Account,
                init.arena.allocator(),
                line,
                .{},
            );
            try credentials.apply(environment, parsed.value);
        } else if (std.mem.eql(u8, argument, "--screenshot")) {
            index += 1;
            if (index == arguments.len) return error.ExpectedScreenshotPath;
            options.screenshot = arguments[index];

            if (index + 1 < arguments.len and !std.mem.startsWith(u8, arguments[index + 1], "--")) {
                index += 1;
                options.scene = std.meta.stringToEnum(Scene, arguments[index]) orelse return error.InvalidScene;
            }
        } else if (std.mem.eql(u8, argument, "--inspect")) {
            options.inspect = true;
        } else if (std.mem.eql(u8, argument, "--verify-url")) {
            options.verify_url = true;
        } else if (std.mem.eql(u8, argument, "--test-s3")) {
            options.test_s3 = true;
        } else if (std.mem.eql(u8, argument, "--remember-account")) {
            options.remember = true;
        } else if (std.mem.eql(u8, argument, "--demo")) {
            options.demo = true;
        } else if (std.mem.eql(u8, argument, "--help")) {
            options.help = true;
        } else {
            return error.UnknownArgument;
        }
    }

    return options;
}

pub fn inspect(init: std.process.Init, environment: *const std.process.Environ.Map, verify: bool) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
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

    const buckets = if (environment.get("S3_BUCKET")) |name|
        try allocator.dupe(s3.Bucket, &.{.{ .name = name, .region = client.config.region }})
    else
        try client.buckets();

    for (buckets) |bucket| {
        if (verify) return verifyUrl(client, bucket.name);
        const objects = try client.objects(bucket.name, "", false);
        std.debug.print("Bucket {s}: {d} root entries\n", .{ bucket.name, objects.len });

        for (objects[0..@min(objects.len, 12)]) |object| {
            std.debug.print("  {s}{s}  {d} B\n", .{
                if (object.folder) "folder " else "object ",
                object.key,
                object.size,
            });
        }
    }
}

fn verifyUrl(client: s3.Client, bucket: []const u8) !void {
    const objects = try client.objects(bucket, "", true);
    for (objects) |object| {
        if (object.folder) continue;
        const date = try presign.timestamp(client.allocator, std.Io.Clock.real.now(client.io).toSeconds());
        const url = try presign.get(client.allocator, client.config, bucket, object.key, 300, date);
        const easy = curl.curl_easy_init() orelse return error.CurlInitFailed;
        defer curl.curl_easy_cleanup(easy);
        const terminated = try client.allocator.dupeSentinel(u8, url, 0);
        if (curl.curl_easy_setopt(easy, curl.CURLOPT_URL, terminated.ptr) != 0 or
            curl.curl_easy_setopt(easy, curl.CURLOPT_RANGE, @as([*:0]const u8, "0-0")) != 0 or
            curl.curl_easy_setopt(easy, curl.CURLOPT_WRITEFUNCTION, &discardResponse) != 0 or
            curl.curl_easy_setopt(easy, curl.CURLOPT_TIMEOUT, @as(c_long, 20)) != 0) return error.CurlOptionFailed;

        const result = curl.curl_easy_perform(easy);
        var status: c_long = 0;
        _ = curl.curl_easy_getinfo(easy, curl.CURLINFO_RESPONSE_CODE, &status);
        if (result != curl.CURLE_OK or (status != 206 and status != 200)) return error.SignedUrlVerificationFailed;
        std.debug.print("Signed URL accepted, HTTP {d}. No remote data changed.\n", .{status});
        return;
    }
    return error.NoObjectsToVerify;
}

fn discardResponse(_: [*c]u8, size: usize, count: usize, _: ?*anyopaque) callconv(.c) usize {
    return size * count;
}

pub fn capture(app: *ui.App, window: ui.WindowHandle, options: Options) !void {
    const driver = @import("testing/test_driver.zig");
    const root = try app.windowEntity(Browser, window);
    try settle(app);

    switch (options.scene) {
        .browser => {},
        .folder => try driver.click(app, window, "assets"),
        .object => try driver.click(app, window, "manifest.json"),
        .connection => try driver.click(app, window, "Account"),
        .upload => try app.update(root, Browser.showUploadForm, .{}),
        .palette => try driver.click(app, window, "Commands"),
        .transfers => try driver.click(app, window, "Transfer history"),
        .narrow => try app.dispatch(window, .{ .resize = .{ .width = 980, .height = 640 } }),
        .preview => {
            try driver.click(app, window, "manifest.json");
            try driver.click(app, window, "Preview object");
        },
    }

    try settle(app);
    try (try app.window(window)).snapshot(options.screenshot.?);
}

fn settle(app: *ui.App) !void {
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    _ = try app.step(0);
}
