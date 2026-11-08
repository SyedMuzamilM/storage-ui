const std = @import("std");
const Allocator = std.mem.Allocator;

const model = @import("model.zig");
const Config = model.Config;
const Bucket = model.Bucket;
const Object = model.Object;
const encode = @import("url.zig").encode;
const xml = @import("xml.zig");
const tag = xml.tag;
const parseObjects = xml.parseObjects;
const parseBuckets = xml.parseBuckets;

pub const Client = struct {
    allocator: Allocator,
    io: std.Io,
    config: Config,

    pub fn request(self: Client, method: []const u8, bucket: []const u8, key: []const u8, query: []const u8, extra: []const []const u8) ![]const u8 {
        try self.config.validate();
        const a = self.allocator;

        const url = try std.fmt.allocPrint(
            a,
            "{s}/{s}{s}{s}{s}",
            .{
                std.mem.trimEnd(u8, self.config.endpoint, "/"),
                try encode(a, bucket, false),
                if (bucket.len > 0) "/" else "",
                try encode(a, key, true),
                query,
            },
        );
        const signed = try @import("auth.zig").sign(a, self.io, self.config, method, url, extra);
        var environment = try (self.config.environment orelse return error.MissingCredentials).clone(a);
        defer environment.deinit();
        try environment.put("STORAGE_REQUEST_AUTHORIZATION", signed.authorization);

        var args: std.ArrayList([]const u8) = .empty;
        // The transport expands authorization from its environment, never argv.
        try args.appendSlice(
            a,
            &.{
                "/usr/bin/curl",
                "--disable",
                "--silent",
                "--show-error",
                "--fail-with-body",
                "--connect-timeout",
                "10",
                "--max-time",
                "120",
                "--globoff",
                "--path-as-is",
                "--proto",
                "=http,https",
                "--variable",
                "%STORAGE_REQUEST_AUTHORIZATION",
                "--expand-header",
                "Authorization: {{STORAGE_REQUEST_AUTHORIZATION}}",
                "--header",
                try std.fmt.allocPrint(a, "Host: {s}", .{signed.host}),
                "--header",
                try std.fmt.allocPrint(a, "x-amz-date: {s}", .{signed.date}),
                "--header",
                "x-amz-content-sha256: UNSIGNED-PAYLOAD",
                "--request",
                method,
            },
        );
        if (self.config.session_token) try args.appendSlice(
            a,
            &.{
                "--variable",
                "%AWS_SESSION_TOKEN",
                "--expand-header",
                "x-amz-security-token: {{AWS_SESSION_TOKEN}}",
            },
        );
        try args.appendSlice(a, extra);
        try args.appendSlice(a, &.{ "--write-out", "\n__storage_status__%{http_code}", "--url", url });

        const result = try std.process.run(
            a,
            self.io,
            .{
                .argv = args.items,
                .environ_map = &environment,
                .stdout_limit = .limited(32 * 1024 * 1024),
                .stderr_limit = .limited(64 * 1024),
                .timeout = .{ .duration = .{ .raw = .fromSeconds(125), .clock = .awake } },
            },
        );

        const marker = std.mem.lastIndexOf(u8, result.stdout, "\n__storage_status__") orelse return error.S3RequestFailed;
        const payload = result.stdout[0..marker];
        const status = std.fmt.parseInt(u16, result.stdout[marker + "\n__storage_status__".len ..], 10) catch return error.S3RequestFailed;

        if (result.term != .exited or result.term.exited != 0) {
            if (tag(payload, "Code")) |code| {
                if (std.mem.eql(u8, code, "AccessDenied")) return error.AccessDenied;
                if (std.mem.eql(u8, code, "SignatureDoesNotMatch")) return error.SignatureDoesNotMatch;
                if (std.mem.eql(u8, code, "NoSuchBucket")) return error.NoSuchBucket;
                if (std.mem.eql(u8, code, "PreconditionFailed")) return error.ObjectAlreadyExists;
            }
            if (status == 403) return error.AccessDenied;
            if (status == 404) return error.NoSuchKey;
            if (status == 412) return error.ObjectAlreadyExists;
            return error.S3RequestFailed;
        }

        return payload;
    }

    pub const Head = struct {
        size: u64,
        etag: []const u8,
        content_type: []const u8,
    };

    pub fn head(self: Client, bucket: []const u8, key: []const u8) !Head {
        const headers = try self.request("HEAD", bucket, key, "", &.{"--head"});
        return .{
            .size = try std.fmt.parseInt(u64, header(headers, "content-length") orelse return error.InvalidS3Response, 10),
            .etag = header(headers, "etag") orelse "",
            .content_type = header(headers, "content-type") orelse "application/octet-stream",
        };
    }

    pub fn copy(
        self: Client,
        source_bucket: []const u8,
        source_key: []const u8,
        target_bucket: []const u8,
        target_key: []const u8,
        move: bool,
    ) !void {
        const a = self.allocator;
        const source = try self.head(source_bucket, source_key);
        // Refuse an existing destination before copying; retain the conditional
        // header so providers that support it also protect a concurrent writer.
        if (self.head(target_bucket, target_key)) |_| {
            return error.ObjectAlreadyExists;
        } else |err| {
            if (err != error.NoSuchKey) return err;
        }

        const copy_source = try std.fmt.allocPrint(a, "x-amz-copy-source: /{s}/{s}", .{ try encode(a, source_bucket, false), try encode(a, source_key, true) });
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ "--header", copy_source, "--header", "If-None-Match: *" });
        if (source.etag.len > 0) try args.appendSlice(a, &.{
            "--header",
            try std.fmt.allocPrint(a, "x-amz-copy-source-if-match: {s}", .{source.etag}),
        });

        const result = try self.request("PUT", target_bucket, target_key, "", args.items);
        if (std.mem.indexOf(u8, result, "<CopyObjectResult") == null or tag(result, "ETag") == null) return error.CopyResultUnknown;

        if (move) {
            if (source.etag.len == 0) return error.SourceChanged;
            _ = try self.request(
                "DELETE",
                source_bucket,
                source_key,
                "",
                &.{ "--header", try std.fmt.allocPrint(a, "If-Match: {s}", .{source.etag}) },
            );
        }
    }

    pub fn buckets(self: Client) ![]Bucket {
        return parseBuckets(self.allocator, try self.request("GET", "", "", "", &.{}), self.config.region);
    }

    pub fn objects(self: Client, bucket: []const u8, prefix: []const u8, flat: bool) ![]Object {
        var all: std.ArrayList(Object) = .empty;
        var token: ?[]const u8 = null;
        while (true) {
            const query = try std.fmt.allocPrint(
                self.allocator,
                "?list-type=2&encoding-type=url&prefix={s}{s}{s}{s}",
                .{
                    try encode(self.allocator, prefix, false),
                    if (flat) "" else "&delimiter=%2F",
                    if (token != null) "&continuation-token=" else "",
                    if (token) |s| try encode(self.allocator, s, false) else "",
                },
            );
            const page = try parseObjects(self.allocator, try self.request("GET", bucket, "", query, &.{}));
            for (page.objects) |object| if (!std.mem.eql(u8, object.key, prefix)) {
                try all.append(self.allocator, object);
            };
            if (page.next == null) break;
            if (all.items.len > 100_000 or (token != null and std.mem.eql(u8, token.?, page.next.?))) return error.ListingLimitExceeded;
            token = page.next;
        }
        return all.toOwnedSlice(self.allocator);
    }
};

pub fn header(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}
