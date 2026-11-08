const std = @import("std");
const Allocator = std.mem.Allocator;

const Bucket = @import("model.zig").Bucket;
const Object = @import("model.zig").Object;
const decode = @import("url.zig").decode;

pub fn tag(xml: []const u8, comptime name: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, xml, "<" ++ name ++ ">") orelse return null) + name.len + 2;
    const end = std.mem.indexOfPos(u8, xml, start, "</" ++ name ++ ">") orelse return null;
    return xml[start..end];
}

pub fn unescape(a: Allocator, xml: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < xml.len) : (i += 1) {
        if (xml[i] != '&') {
            try out.append(a, xml[i]);
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, xml, i, ';') orelse return error.InvalidXml;
        const entity = xml[i + 1 .. end];
        const named = std.StaticStringMap(u8).initComptime(.{
            .{ "amp", '&' },
            .{ "lt", '<' },
            .{ "gt", '>' },
            .{ "quot", '"' },
            .{ "apos", '\'' },
        });
        if (named.get(entity)) |byte| {
            try out.append(a, byte);
        } else if (std.mem.startsWith(u8, entity, "#")) {
            const hex = std.mem.startsWith(u8, entity, "#x");
            const cp = try std.fmt.parseInt(u21, entity[if (hex) 2 else 1..], if (hex) 16 else 10);
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &buf);
            try out.appendSlice(a, buf[0..n]);
        } else return error.InvalidXml;
        i = end;
    }
    return out.toOwnedSlice(a);
}

pub const Page = struct { objects: []Object, next: ?[]const u8 };

pub fn parseObjects(a: Allocator, xml: []const u8) !Page {
    if (std.mem.indexOf(u8, xml, "<ListBucketResult") == null) return error.InvalidS3Response;
    const encoded = if (tag(xml, "EncodingType")) |s| std.mem.eql(u8, s, "url") else false;
    var items: std.ArrayList(Object) = .empty;
    var rest = xml;
    while (tag(rest, "CommonPrefixes")) |block| {
        const raw = try unescape(a, tag(block, "Prefix") orelse return error.InvalidS3Response);
        try items.append(a, .{ .key = if (encoded) try decode(a, raw) else raw, .folder = true });
        rest = rest[(std.mem.indexOf(u8, rest, "</CommonPrefixes>") orelse unreachable) + "</CommonPrefixes>".len ..];
    }
    rest = xml;
    while (tag(rest, "Contents")) |block| {
        const raw = try unescape(a, tag(block, "Key") orelse return error.InvalidS3Response);
        const key = if (encoded) try decode(a, raw) else raw;
        try items.append(
            a,
            .{
                .key = key,
                .size = try std.fmt.parseInt(u64, tag(block, "Size") orelse return error.InvalidS3Response, 10),
                .modified = try a.dupe(u8, tag(block, "LastModified") orelse ""),
                .folder = std.mem.endsWith(u8, key, "/"),
            },
        );
        rest = rest[(std.mem.indexOf(u8, rest, "</Contents>") orelse unreachable) + "</Contents>".len ..];
    }
    const next = if (tag(xml, "NextContinuationToken")) |s| try unescape(a, s) else null;
    if (tag(xml, "IsTruncated")) |s| if (std.mem.eql(u8, s, "true") and next == null) return error.InvalidS3Response;
    return .{ .objects = try items.toOwnedSlice(a), .next = next };
}

pub fn parseBuckets(a: Allocator, xml: []const u8, region: []const u8) ![]Bucket {
    if (std.mem.indexOf(u8, xml, "<ListAllMyBucketsResult") == null) return error.InvalidS3Response;
    var items: std.ArrayList(Bucket) = .empty;
    var rest = xml;
    while (tag(rest, "Bucket")) |block| {
        try items.append(
            a,
            .{
                .name = try unescape(a, tag(block, "Name") orelse return error.InvalidS3Response),
                .region = try a.dupe(u8, tag(block, "BucketRegion") orelse region),
            },
        );
        rest = rest[(std.mem.indexOf(u8, rest, "</Bucket>") orelse unreachable) + "</Bucket>".len ..];
    }
    // Avoid silently presenting the first page as a complete bucket list.
    if (tag(xml, "ContinuationToken") != null) return error.BucketPaginationUnsupported;
    return items.toOwnedSlice(a);
}
