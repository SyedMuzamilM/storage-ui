const std = @import("std");
const ui = @import("zircon_ui");

pub fn click(app: *ui.App, handle: ui.WindowHandle, label: []const u8) !void {
    _ = try app.step(0);
    const frame = &(try app.window(handle)).frames.committed;
    var index = frame.nodes.items.len;
    while (index > 0) {
        index -= 1;
        const i = index;
        const node = frame.nodes.items[i];
        if (!(node.kind == .button and std.mem.eql(u8, node.kind.button.label, label))) continue;
        const r = frame.bounds[i];
        const p: ui.Point = .{ .x = r.x + r.width / 2, .y = r.y + r.height / 2 };
        try app.dispatch(handle, .{ .pointer_down = .{ .position = p } });
        try app.dispatch(handle, .{ .pointer_up = .{ .position = p } });
        _ = try app.step(0);
        return;
    }
    return error.ButtonNotFound;
}

pub fn focus(app: *ui.App, handle: ui.WindowHandle, key: []const u8) !void {
    _ = try app.step(0);
    const frame = &(try app.window(handle)).frames.committed;
    for (frame.nodes.items, 0..) |node, i| if (node.key != null and node.key.? == .string and std.mem.eql(u8, node.key.?.string, key)) {
        const r = frame.bounds[i];
        const p: ui.Point = .{ .x = r.x + 12, .y = r.y + r.height / 2 };
        try app.dispatch(handle, .{ .pointer_down = .{ .position = p } });
        try app.dispatch(handle, .{ .pointer_up = .{ .position = p } });
        return;
    };
    return error.FieldNotFound;
}
