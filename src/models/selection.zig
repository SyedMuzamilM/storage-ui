const std = @import("std");
pub const Selection = struct {
    indices: std.AutoHashMapUnmanaged(usize, void) = .empty,
    primary: ?usize = null,
    anchor: ?usize = null,

    pub fn contains(self: *const Selection, index: usize) bool {
        return self.indices.contains(index);
    }

    pub fn count(self: *const Selection) usize {
        return self.indices.count();
    }

    pub fn clear(self: *Selection) void {
        self.indices.clearRetainingCapacity();
        self.primary = null;
        self.anchor = null;
    }

    pub fn add(self: *Selection, a: std.mem.Allocator, index: usize) !void {
        try self.indices.put(a, index, {});
        self.primary = index;
        if (self.anchor == null) self.anchor = index;
    }

    pub fn replace(self: *Selection, a: std.mem.Allocator, index: usize) !void {
        self.clear();
        try self.add(a, index);
    }

    pub fn toggle(self: *Selection, a: std.mem.Allocator, index: usize) !void {
        if (!self.indices.remove(index)) {
            try self.add(a, index);
            return;
        }
        if (self.primary == index) {
            var it = self.indices.keyIterator();
            self.primary = if (it.next()) |key| key.* else null;
        }
        if (self.indices.count() == 0) self.anchor = null;
    }

    pub fn range(self: *Selection, a: std.mem.Allocator, index: usize) !void {
        const anchor = self.anchor orelse index;
        self.indices.clearRetainingCapacity();
        for (@min(anchor, index)..@max(anchor, index) + 1) |i| try self.indices.put(a, i, {});
        self.primary = index;
        self.anchor = anchor;
    }
};
