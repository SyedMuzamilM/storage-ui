const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn encode(a: Allocator, value: []const u8, keep_slash: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        const unreserved = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.~", c) != null;
        if (unreserved or (keep_slash and c == '/')) {
            try out.append(a, c);
        } else {
            try out.appendSlice(a, &.{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
    return out.toOwnedSlice(a);
}

pub fn decode(a: Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '%') {
            if (i + 2 >= value.len) return error.InvalidEncoding;
            try out.append(a, std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch return error.InvalidEncoding);
            i += 2;
        } else try out.append(a, value[i]);
    }
    return out.toOwnedSlice(a);
}
