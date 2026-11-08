const std = @import("std");
const ui = @import("zircon_ui");
const Browser = @import("app/browser.zig").Browser;
const cli = @import("cli.zig");
const credentials = @import("platform/credentials.zig");

pub fn main(init: std.process.Init) !void {
    var environment = try init.environ_map.clone(init.gpa);
    defer environment.deinit();
    const options = try cli.parse(init, &environment);

    if (options.help) {
        std.debug.print(
            "Storage UI\n  --demo\n  --account-stdin [--remember-account]\n  --inspect\n  --verify-url\n  --test-s3 (creates and removes an isolated test folder)\n  --screenshot PATH [SCENE]\n",
            .{},
        );
        return;
    }

    const saved = if (options.demo) false else try credentials.load(init.gpa, &environment);
    if (options.remember) try credentials.save(init.gpa, &environment);
    if (options.inspect or options.verify_url) return cli.inspect(init, &environment, options.verify_url);
    if (options.test_s3) return @import("testing/live_s3.zig").run(init, &environment);

    var app = try ui.App.init(.{ .allocator = init.gpa });
    defer app.deinit();
    const state = try Browser.init(&app, init.gpa, init.io, &environment);
    const window = try app.openWindow(Browser, .{
        .title = "Storage",
        .chrome = .integrated,
        .width = 1440,
        .height = 900,
        .visible = options.screenshot == null,
        .background = @import("views/components.zig").c.canvas,
    }, state);
    const root = try app.windowEntity(Browser, window);
    try app.update(root, Browser.attach, .{});

    if (!options.demo and (saved or environment.get("S3_AUTOCONNECT") != null)) {
        try app.update(root, Browser.connectSaved, .{});
    }
    if (options.screenshot != null) {
        try cli.capture(&app, window, options);
    } else {
        try app.run();
    }
}
