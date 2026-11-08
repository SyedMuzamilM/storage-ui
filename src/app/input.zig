const ui = @import("zircon_ui");
const Browser = @import("../app/browser.zig").Browser;
const v = @import("../views/components.zig");
const c = v.c;
const Input = ui.controls.TextInput;
const types = @import("../models/browser.zig");
const Action = types.Action;
const commands = @import("commands.zig").items;
const matches = Browser.matches;

pub fn onBucketScroll(self: *Browser, e: *ui.Event(ui.Input), cx: *ui.Context(Browser)) void {
    if (e.data == .scroll) {
        var count: usize = 0;
        for (self.buckets) |bucket| if (matches(bucket.name, self.bucket_query)) {
            count += 1;
        };
        self.bucket_scroll.wheel(e.data.scroll.y, @as(f32, @floatFromInt(count)) * 34, e.bounds.height);
        e.preventDefault();
        cx.notify();
    }
}

pub fn onScroll(self: *Browser, e: *ui.Event(ui.Input), cx: *ui.Context(Browser)) void {
    if (e.data == .scroll) {
        var count: usize = 0;
        for (self.objects) |object| if (matches(object.name(self.prefix), self.object_query)) {
            count += 1;
        };
        self.scroll.wheel(e.data.scroll.y, @as(f32, @floatFromInt(count)) * 36, e.bounds.height);
        e.preventDefault();
        cx.notify();
    }
}

pub fn onInput(self: *Browser, e: *ui.Event(ui.Input), cx: *ui.Context(Browser)) !void {
    if (e.prevented) return;
    if (e.data == .files_hover) {
        self.drop_active = e.data.files_hover.active;
        self.drop_folder = null;
        cx.notify();
        return;
    }
    if (e.data == .files_drop) {
        self.drop_active = false;
        self.drop_folder = null;
        try self.enqueuePaths(cx, e.data.files_drop.paths, self.prefix);
        return;
    }
    if (e.data != .key_down) return;
    const key = e.data.key_down;
    if (key.key == .escape) {
        if (self.modal == .none) self.selection.clear() else try self.act(cx, .dismiss);
        cx.notify();
        e.preventDefault();
        return;
    }
    if ((key.modifiers.command or key.modifiers.control) and key.key == .k) {
        try self.act(cx, .palette);
        e.preventDefault();
        return;
    }
    if (self.modal != .none) return;
    if (key.modifiers.command or key.modifiers.control) {
        switch (key.key) {
            .a => try self.act(cx, .select_all),
            .c, .x, .v => {
                var click_event: ui.Event(ui.Click) = .{ .data = .{}, ._surface = e._surface };
                const action: Action = switch (key.key) {
                    .c => .copy,
                    .x => .cut,
                    else => .paste,
                };
                try self.onAction(&click_event, cx, action);
            },
            .r => try self.act(cx, .refresh),
            .u => {
                var click_event: ui.Event(ui.Click) = .{ .data = .{}, ._surface = e._surface };
                try self.onAction(&click_event, cx, .upload);
            },
            .d => try self.act(cx, .download),
            else => return,
        }
        e.preventDefault();
    } else if (key.key == .enter) {
        if (self.selected()) |object| if (object.folder) {
            try self.navigate(cx, object.key);
            e.preventDefault();
        };
    } else if (key.key == .backspace and self.prefix.len > 0) {
        try self.act(cx, .parent);
        e.preventDefault();
    }
}

pub fn onModalInput(self: *Browser, e: *ui.Event(ui.Input), cx: *ui.Context(Browser)) !void {
    if (e.data != .key_down) return;
    const key = e.data.key_down;
    if (key.key == .escape or ((key.modifiers.command or key.modifiers.control) and key.key == .k)) {
        try self.act(cx, .dismiss);
        e.preventDefault();
        e.stopPropagation();
        return;
    }
    if (self.modal != .palette) return;
    var filtered: [commands.len]usize = undefined;
    var count: usize = 0;
    for (commands, 0..) |command, i| if (matches(command.label, self.palette_query) or matches(command.detail, self.palette_query)) {
        filtered[count] = i;
        count += 1;
    };
    switch (key.key) {
        .down => self.palette_index = if (count == 0) 0 else (self.palette_index + 1) % count,
        .up => self.palette_index = if (count == 0) 0 else (self.palette_index + count - 1) % count,
        .enter => if (count > 0) {
            var click_event: ui.Event(ui.Click) = .{ .data = .{}, ._surface = e._surface };
            try self.paletteClick(&click_event, cx, filtered[@min(self.palette_index, count - 1)]);
        },
        else => return,
    }
    e.preventDefault();
    e.stopPropagation();
    cx.notify();
}
