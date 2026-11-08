const std = @import("std");
const ui = @import("zircon_ui");
const Browser = @import("browser.zig").Browser;
const Action = @import("../models/browser.zig").Action;

pub fn handle(self: *Browser, cx: *ui.Context(Browser), action: Action) !bool {
    if (self.busy) return false;

    switch (action) {
        .copy, .cut => {
            var keys: std.ArrayList([]const u8) = .empty;
            for (self.objects, 0..) |object, i| if (self.selection.contains(i)) {
                try keys.append(self.arena.allocator(), try self.keep(object.key));
            };

            self.clipboard = .{
                .bucket = try self.keep(self.bucket),
                .prefix = try self.keep(self.prefix),
                .keys = try keys.toOwnedSlice(self.arena.allocator()),
                .move = action == .cut,
            };
            self.message = try std.fmt.allocPrint(
                self.arena.allocator(),
                "{d} objects ready to {s}",
                .{ self.clipboard.keys.len, if (action == .cut) "move" else "copy" },
            );
        },
        .paste => {
            if (self.clipboard.keys.len == 0) return true;
            if (self.demo) try pasteDemo(self) else try self.start(cx, if (self.clipboard.move) .move else .copy, "", "");
        },
        .rename => {
            const object = self.selected() orelse return true;
            if (object.folder or self.selection.count() != 1) return true;
            self.modal = .rename;
            self.modal_error = "";
            try cx.update(self.name_field, Browser.setField, .{std.fs.path.basename(object.key)});
        },
        else => return false,
    }
    cx.notify();

    return true;
}

pub fn pasteDemo(self: *Browser) !void {
    const a = self.arena.allocator();
    var keys: std.ArrayList([]const u8) = .empty;
    for (self.clipboard.keys) |key| {
        if (std.mem.eql(u8, self.clipboard.bucket, self.bucket) and std.mem.endsWith(u8, key, "/") and std.mem.startsWith(u8, self.prefix, key)) return error.CannotPasteIntoSource;
        if (std.mem.endsWith(u8, key, "/")) for (try self.demo_store.list(a, self.clipboard.bucket, key, true)) |object| {
            try keys.append(a, object.key);
        };
        try keys.append(a, key);
    }

    var successes: usize = 0;
    var failures: usize = 0;
    for (keys.items) |key| {
        const relative = if (std.mem.startsWith(u8, key, self.clipboard.prefix)) key[self.clipboard.prefix.len..] else key;
        const target = try std.fmt.allocPrint(a, "{s}{s}", .{ self.prefix, relative });
        const content = self.demo_store.get(self.clipboard.bucket, key) catch {
            continue;
        };
        if (self.demo_store.get(self.bucket, target)) |_| {
            failures += 1;
            continue;
        } else |_| {}
        try self.demo_store.put(self.bucket, target, content);
        if (self.clipboard.move) try self.demo_store.remove(self.clipboard.bucket, key);
        successes += 1;
    }

    try self.loadDemo();
    self.message = try std.fmt.allocPrint(a, "{d} copied; {d} existing names skipped", .{ successes, failures });
}

pub fn deleteDemo(self: *Browser) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    for (self.objects, 0..) |entry, index| {
        if (!self.selection.contains(index)) continue;
        if (entry.folder) {
            for (try self.demo_store.list(self.arena.allocator(), self.bucket, entry.key, true)) |child| {
                try keys.append(self.arena.allocator(), child.key);
            }
        }
        try keys.append(self.arena.allocator(), entry.key);
    }
    for (keys.items) |key| {
        self.demo_store.remove(self.bucket, key) catch |err| {
            if (err != error.NoSuchKey) return err;
        };
    }
    try self.loadDemo();
}
