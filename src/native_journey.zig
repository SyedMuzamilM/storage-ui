const std = @import("std");
const ui = @import("zircon_ui");
const Browser = @import("app/browser.zig").Browser;
const driver = @import("testing/test_driver.zig");
const objc = ui.testing.native.objc;
const Id = objc.Id;
const Sel = *opaque {};
extern "c" fn objc_allocateClassPair(Id, [*:0]const u8, usize) Id;
extern "c" fn objc_registerClassPair(Id) void;
extern "c" fn class_addMethod(Id, Sel, *const anyopaque, [*:0]const u8) bool;
extern "c" fn sel_registerName([*:0]const u8) Sel;
var board: Id = null;
var location: objc.CGPoint = .{};

fn pasteboard(_: Id, _: Sel) callconv(.c) Id {
    return board;
}

fn dragLocation(_: Id, _: Sel) callconv(.c) objc.CGPoint {
    return location;
}

fn expect(ok: bool) !void {
    if (!ok) return error.NativeJourneyFailed;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const folder = try std.fmt.allocPrint(a, "/tmp/storage-native-{d}", .{std.Io.Clock.real.now(init.io).nanoseconds});
    try std.Io.Dir.cwd()
        .createDirPath(init.io, folder);
    defer std.Io.Dir.cwd()
        .deleteTree(init.io, folder) catch {};
    const first = try std.fs.path.join(a, &.{ folder, "native-a.txt" });
    const second = try std.fs.path.join(a, &.{ folder, "native-b.txt" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = first, .data = "Native drop A" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = second, .data = "Native drop B" });
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("AWS_ACCESS_KEY_ID", "test-access");
    try env.put("AWS_SECRET_ACCESS_KEY", "test-secret");
    try env.put("S3_ENDPOINT", "https://storage.example.com");
    var app = try ui.App.init(.{ .allocator = init.gpa });
    defer app.deinit();
    const value = try Browser.init(&app, init.gpa, init.io, &env);
    const h = try app.openWindow(Browser, .{ .visible = false, .chrome = .integrated, .width = 1440, .height = 900 }, value);
    const root = try app.windowEntity(Browser, h);
    try app.update(root, Browser.attach, .{});
    _ = try app.step(0);
    const frame = &(try app.window(h)).frames.committed;
    var point: objc.CGPoint = .{};
    for (frame.nodes.items, 0..) |node, i| if (node.kind == .button and std.mem.eql(u8, node.kind.button.label, "assets")) {
        const r = frame.bounds[i];
        point = .{ .x = r.x + 25, .y = r.y + r.height / 2 };
        break;
    };
    const application = objc.send(Id, objc.class("NSApplication"), "sharedApplication", .{});
    const window = objc.send(Id, objc.send(Id, application, "windows", .{}), "lastObject", .{});
    const view = objc.send(Id, window, "contentView", .{});
    location = objc.send(objc.CGPoint, view, "convertPoint:toView:", .{ point, @as(Id, null) });
    board = objc.send(Id, objc.class("NSPasteboard"), "pasteboardWithUniqueName", .{});
    const urls = [_]Id{
        objc.send(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.string(first)}),
        objc.send(Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.string(second)}),
    };
    const native_urls = objc.send(Id, objc.class("NSArray"), "arrayWithObjects:count:", .{ &urls, @as(usize, urls.len) });
    try expect(objc.send(bool, board, "writeObjects:", .{native_urls}));
    const cls = objc_allocateClassPair(objc.class("NSObject"), "StorageDropJourney", 0) orelse return error.NativeClassFailed;
    try expect(class_addMethod(cls, sel_registerName("draggingPasteboard"), @ptrCast(&pasteboard), "@@:"));
    try expect(class_addMethod(cls, sel_registerName("draggingLocation"), @ptrCast(&dragLocation), "{CGPoint=dd}@:"));
    objc_registerClassPair(cls);
    const sender = objc.send(Id, cls, "new", .{});
    defer objc.release(sender);
    try expect(objc.send(usize, view, "draggingEntered:", .{sender}) == 1);
    _ = try app.step(0);
    try expect(objc.send(bool, view, "performDragOperation:", .{sender}));
    while (try app.tasksPending()) {
        _ = try app.step(0);
        std.atomic.spinLoopHint();
    }
    _ = try app.step(0);
    const Read = struct {
        fn uploaded(self: *const Browser) bool {
            const bytes = self.demo_store.get("acme-assets", "assets/native-b.txt") catch return false;
            return self.completed == 2 and self.failed == 0 and std.mem.eql(u8, bytes, "Native drop B");
        }

        fn signing(self: *Browser, cx: *ui.Context(Browser)) void {
            self.demo = false;
            cx.notify();
        }
    };
    try expect(try app.read(root, Read.uploaded, .{}));
    try (try app.window(h))
        .snapshot("/tmp/storage-ui-native-drop.png");
    try driver.click(&app, h, "Commands");
    try (try app.window(h))
        .snapshot("/tmp/storage-ui-palette.png");
    try app.dispatch(h, .{ .key_down = .{ .key = .escape } });
    _ = try app.step(0);
    try driver.click(&app, h, "manifest.json");
    try app.update(root, Read.signing, .{});
    _ = try app.step(0);
    try driver.click(&app, h, "Create signed URL");
    try (try app.window(h))
        .snapshot("/tmp/storage-ui-share.png");

    const surface = (try app.window(h)).surface orelse return error.MissingNativeSurface;
    const previous_clipboard = try surface.ops.clipboard_read(surface.context, a);
    defer surface.ops.clipboard_write(surface.context, previous_clipboard) catch {};
    try driver.click(&app, h, "Copy signed URL");
    const copied_url = try surface.ops.clipboard_read(surface.context, a);
    try expect(std.mem.startsWith(u8, copied_url, "https://storage.example.com/acme-assets/manifest.json?"));
    try expect(std.mem.indexOf(u8, copied_url, "X-Amz-Signature=") != null);
    std.debug.print(
        "Native journey passed: AppKit file drops, multi-file upload queue, palette, signed URL dialog, and clipboard copy.\n",
        .{},
    );
}
