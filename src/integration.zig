const std = @import("std");
const ui = @import("zircon_ui");
const s3 = @import("storage/s3.zig");
const jobs = @import("storage/jobs.zig");

fn expect(ok: bool) !void {
    if (!ok) return error.IntegrationAssertionFailed;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.ExpectedFixtureEndpointAndDirectory;
    const config: s3.Config = .{
        .endpoint = args[1],
        .region = "us-east-1",
        .session_token = true,
        .environment = init.environ_map,
    };
    const client: s3.Client = .{ .allocator = a, .io = init.io, .config = config };
    const buckets = try client.buckets();
    try expect(buckets.len == 1 and std.mem.eql(u8, buckets[0].name, "acme-test"));
    const objects = try client.objects("acme-test", "", false);
    try expect(objects.len == 3);
    try expect(objects[0].folder and std.mem.eql(u8, objects[2].key, "second +&.txt"));
    const key = "nested/café +%#.txt";
    const local = try std.fmt.allocPrint(a, "{s}/upload.txt", .{args[2]});
    const saved = try std.fmt.allocPrint(a, "{s}/download.txt", .{args[2]});
    const body = "A signed upload with Unicode in its object key.\n";
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = local, .data = body });
    var cancellation: ui.tasks.Cancellation = .{};
    var progress: @import("transfers/upload.zig").Progress = .{};
    var job: jobs.Job = .{
        .progress = &progress,
        .arena = &arena,
        .io = init.io,
        .kind = .upload,
        .config = config,
        .bucket = "acme-test",
        .prefix = "",
        .key = key,
        .path = local,
    };
    _ = try job.run(&cancellation);
    try expect(progress.sent.load(.acquire) == body.len and progress.total.load(.acquire) == body.len);
    if (job.run(&cancellation)) |_| return error.OverwroteRemoteObject else |err| try expect(err == error.ObjectAlreadyExists);
    try expect(std.mem.eql(u8, body, try client.request("GET", "acme-test", key, "", &.{})));
    const signed = try @import("storage/presign.zig")
        .get(a, config, "acme-test", key, 3600, "20261108T120000Z");
    const signed_result = try std.process.run(a, init.io, .{
        .argv = &.{
            "/usr/bin/curl",
            "--disable",
            "--fail",
            "--silent",
            "--globoff",
            "--url",
            signed,
        },
    });
    try expect(
        signed_result.term == .exited and signed_result.term.exited == 0 and std.mem.eql(u8, body, signed_result.stdout),
    );
    try client.copy("acme-test", key, "acme-test", "copied.txt", false);
    try expect(std.mem.eql(u8, body, try client.request("GET", "acme-test", "copied.txt", "", &.{})));
    if (client.copy("acme-test", key, "acme-test", "copied.txt", false)) |_| {
        return error.OverwroteCopyDestination;
    } else |err| try expect(err == error.ObjectAlreadyExists);
    if (client.copy("acme-test", key, "acme-test", "uncertain-copy.txt", true)) |_| {
        return error.AcceptedAmbiguousCopy;
    } else |err| try expect(err == error.CopyResultUnknown);
    try expect(std.mem.eql(u8, body, try client.request("GET", "acme-test", key, "", &.{})));
    try client.copy("acme-test", "copied.txt", "acme-test", "moved.txt", true);
    try expect(std.mem.eql(u8, body, try client.request("GET", "acme-test", "moved.txt", "", &.{})));
    job.kind = .download;
    job.path = saved;
    _ = try job.run(&cancellation);
    try expect(std.mem.eql(u8, body, try std.Io.Dir.cwd().readFileAlloc(init.io, saved, a, .limited(1024))));
    if (job.run(&cancellation)) |_| return error.OverwroteExistingFile else |err| try expect(err == error.PathAlreadyExists);
    job.kind = .mkdir;
    job.key = "new folder/";
    _ = try job.run(&cancellation);
    job.kind = .delete;
    job.key = key;
    _ = try job.run(&cancellation);
    if (client.request("GET", "acme-test", "denied", "", &.{})) |_| return error.MissingAccessDenied else |err| try expect(err == error.AccessDenied);
    // Exercise the entity-owned job and completion path through real UI controls.
    const Browser = @import("app/browser.zig").Browser;
    const driver = @import("testing/test_driver.zig");
    var env = try init.environ_map.clone(a);
    defer env.deinit();
    try env.put("S3_ENDPOINT", args[1]);
    try env.put("S3_BUCKET", "acme-test");
    var app = try ui.App.init(.{ .allocator = init.gpa });
    defer app.deinit();
    const state = try Browser.init(&app, init.gpa, init.io, &env);
    const h = try app.openWindow(Browser, .{ .visible = false, .width = 1440, .height = 900 }, state);
    const root = try app.windowEntity(Browser, h);
    try app.update(root, Browser.attach, .{});
    try driver.click(&app, h, "Account");
    try driver.click(&app, h, "Connect");
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    _ = try app.step(0);
    const Read = struct {
        fn connected(self: *const Browser) bool {
            return !self.demo and !self.busy and self.objects.len == 3 and std.mem.eql(u8, self.bucket, "acme-test");
        }
    };
    try expect(try app.read(root, Read.connected, .{}));
    try driver.click(&app, h, "nested");
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    _ = try app.step(0);
    const Restored = struct {
        fn valid(self: *const Browser) bool {
            return self.prefix.len == 0 and self.objects.len == 3 and std.mem.indexOf(u8, self.message, "Access denied") != null;
        }
    };
    try expect(try app.read(root, Restored.valid, .{}));
    try driver.click(&app, h, "New folder");
    try driver.focus(&app, h, "Folder name");
    try app.dispatch(h, .{ .text = "ui-folder" });
    try driver.click(&app, h, "Create folder");
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    _ = try app.step(0);
    try expect(try app.read(root, Read.connected, .{}));
    try driver.click(&app, h, "New folder");
    try driver.focus(&app, h, "Folder name");
    try app.dispatch(h, .{ .text = "saved-but-refresh-fails" });
    try driver.click(&app, h, "Create folder");
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    _ = try app.step(0);
    const Saved = struct {
        fn valid(self: *const Browser) bool {
            return !self.busy and self.objects.len == 3 and std.mem.indexOf(u8, self.message, "Saved to S3") != null;
        }
    };
    try expect(try app.read(root, Saved.valid, .{}));
}
