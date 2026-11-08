const std = @import("std");
const s3 = @import("s3.zig");
pub const buckets = [_]s3.Bucket{
    .{ .name = "acme-analytics" },
    .{ .name = "acme-assets" },
    .{ .name = "acme-backups", .region = "us-west-2" },
    .{ .name = "acme-logs", .region = "eu-west-1" },
    .{ .name = "acme-media-archive", .region = "ap-southeast-2" },
    .{ .name = "acme-versioned" },
    .{ .name = "acme-website" },
};
const Record = struct { bucket: []const u8, object: s3.Object, content: []const u8 = "" };
pub const Store = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,

    pub fn init(a: std.mem.Allocator) !Store {
        var self: Store = .{ .allocator = a };
        for (buckets) |bucket| {
            for ([_][]const u8{ "assets/", "backups/", "logs/", "reports/", "tmp/", "website/" }) |key| try self.put(bucket.name, key, "");
            try self.put(
                bucket.name,
                "manifest.json",
                "{\n  \"name\": \"acme-assets\",\n  \"version\": \"1.0.0\",\n  \"description\": \"Shared assets for the Acme workspace\"\n}\n",
            );
            try self.put(
                bucket.name,
                "README.txt",
                "Welcome to your storage workspace.\n\nBrowse a folder, select an object to inspect it, or upload a file.\nThis demo runs entirely in memory. Connect an S3-compatible account to work with your own data.\n",
            );
            try self.put(
                bucket.name,
                "assets/logo.svg",
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\"><rect width=\"64\" height=\"64\" rx=\"12\" fill=\"#52749b\"/></svg>",
            );
            try self.put(bucket.name, "assets/images/cover.txt", "An example nested object.\n");
            try self.put(bucket.name, "reports/november.csv", "date,requests,bytes\n2026-11-07,12840,8402932\n");
            try self.put(
                bucket.name,
                "website/index.html",
                "<!doctype html><html><title>Acme</title><body>Hello, Acme.</body></html>\n",
            );
        }
        return self;
    }

    pub fn put(self: *Store, bucket: []const u8, key: []const u8, content: []const u8) !void {
        const record: Record = .{
            .bucket = try self.allocator.dupe(u8, bucket),
            .object = .{
                .key = try self.allocator.dupe(u8, key),
                .size = content.len,
                .folder = std.mem.endsWith(u8, key, "/"),
                .modified = "2026-11-07T15:07:00Z",
            },
            .content = try self.allocator.dupe(u8, content),
        };
        for (self.records.items) |*r| if (std.mem.eql(u8, r.bucket, bucket) and std.mem.eql(u8, r.object.key, key)) {
            r.* = record;
            return;
        };
        try self.records.append(self.allocator, record);
    }

    pub fn remove(self: *Store, bucket: []const u8, key: []const u8) !void {
        for (self.records.items, 0..) |r, i| if (std.mem.eql(u8, r.bucket, bucket) and std.mem.eql(u8, r.object.key, key)) {
            _ = self.records.orderedRemove(i);
            return;
        };
        return error.NoSuchKey;
    }

    pub fn get(self: *const Store, bucket: []const u8, key: []const u8) ![]const u8 {
        for (self.records.items) |r| if (std.mem.eql(u8, r.bucket, bucket) and std.mem.eql(u8, r.object.key, key)) return r.content;
        return error.NoSuchKey;
    }

    pub fn list(self: *const Store, a: std.mem.Allocator, bucket: []const u8, prefix: []const u8, flat: bool) ![]s3.Object {
        var result: std.ArrayList(s3.Object) = .empty;
        for (self.records.items) |record| {
            if (!std.mem.eql(u8, record.bucket, bucket) or !std.mem.startsWith(u8, record.object.key, prefix) or std.mem.eql(u8, record.object.key, prefix)) continue;
            var object = record.object;
            const relative = object.key[prefix.len..];
            if (!flat) if (std.mem.indexOfScalar(u8, relative, '/')) |slash| {
                object = .{ .key = object.key[0 .. prefix.len + slash + 1], .folder = true };
            };
            var duplicate = false;
            for (result.items) |existing| if (std.mem.eql(u8, existing.key, object.key)) {
                duplicate = true;
                break;
            };
            if (!duplicate) try result.append(a, object);
        }
        return result.toOwnedSlice(a);
    }
};
