const std = @import("std");

pub fn temporary(a: std.mem.Allocator, io: std.Io, destination: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}.storage-part-{d}", .{ destination, std.Io.Clock.awake.now(io).nanoseconds });
}

pub fn publish(io: std.Io, partial: []const u8, destination: []const u8) !void {
    try std.Io.Dir.renamePreserve(.cwd(), partial, .cwd(), destination, io);
}

pub fn save(a: std.mem.Allocator, io: std.Io, destination: []const u8, bytes: []const u8) !void {
    const partial = try temporary(a, io, destination);
    try std.Io.Dir.cwd()
        .writeFile(io, .{ .sub_path = partial, .data = bytes, .flags = .{ .exclusive = true } });
    defer std.Io.Dir.cwd()
        .deleteFile(io, partial) catch {};
    try publish(io, partial, destination);
}

pub fn relative(key: []const u8, prefix: []const u8) ![]const u8 {
    const name = if (std.mem.startsWith(u8, key, prefix)) key[prefix.len..] else key;
    if (name.len == 0 or std.fs.path.isAbsolute(name) or std.mem.indexOfAny(u8, name, "\\\x00") != null) return error.UnsafeObjectPath;
    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| if (std.mem.eql(u8, segment, "..") or std.mem.eql(u8, segment, ".")) return error.UnsafeObjectPath;
    return name;
}
