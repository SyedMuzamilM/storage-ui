//! SigV4 request signing. Canonical headers sort by name, never by full line.
const std = @import("std");
const Config = @import("model.zig").Config;
const encode = @import("url.zig").encode;
const decode = @import("url.zig").decode;
const presign = @import("presign.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Signed = struct {
    authorization: []const u8,
    date: []const u8,
    host: []const u8,
};

const Header = struct {
    name: []const u8,
    value: []const u8,

    fn less(_: void, left: Header, right: Header) bool {
        const order = std.mem.order(u8, left.name, right.name);
        return if (order == .eq) std.mem.order(u8, left.value, right.value) == .lt else order == .lt;
    }
};

pub fn sign(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    method: []const u8,
    url: []const u8,
    extra: []const []const u8,
) !Signed {
    const environment = config.environment orelse return error.MissingCredentials;
    const access = environment.get("AWS_ACCESS_KEY_ID") orelse return error.MissingCredentials;
    const secret = environment.get("AWS_SECRET_ACCESS_KEY") orelse return error.MissingCredentials;
    const date = try presign.timestamp(allocator, std.Io.Clock.real.now(io).toSeconds());
    const start = (std.mem.indexOf(u8, url, "://") orelse return error.InvalidEndpoint) + 3;
    const path_start = std.mem.indexOfScalarPos(u8, url, start, '/') orelse return error.InvalidEndpoint;
    const host = try std.ascii.allocLowerString(allocator, url[start..path_start]);
    const query_start = std.mem.indexOfScalarPos(u8, url, path_start, '?') orelse url.len;

    var headers: std.ArrayList(Header) = .empty;
    try headers.appendSlice(allocator, &.{
        .{ .name = "host", .value = host },
        .{ .name = "x-amz-content-sha256", .value = "UNSIGNED-PAYLOAD" },
        .{ .name = "x-amz-date", .value = date },
    });
    if (environment.get("AWS_SESSION_TOKEN")) |token| {
        try headers.append(allocator, .{ .name = "x-amz-security-token", .value = token });
    }
    for (extra, 0..) |argument, index| {
        if (!std.mem.eql(u8, argument, "--header")) continue;
        if (index + 1 >= extra.len) return error.InvalidHeader;
        const line = extra[index + 1];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        try headers.append(allocator, .{
            .name = try std.ascii.allocLowerString(allocator, line[0..colon]),
            .value = try normalize(allocator, line[colon + 1 ..]),
        });
    }
    std.mem.sort(Header, headers.items, {}, Header.less);

    var canonical_headers: std.ArrayList(u8) = .empty;
    var names: std.ArrayList(u8) = .empty;
    for (headers.items, 0..) |header, index| {
        if (index > 0) {
            if (std.mem.eql(u8, headers.items[index - 1].name, header.name)) return error.DuplicateHeader;
            try names.append(allocator, ';');
        }
        try names.appendSlice(allocator, header.name);
        try canonical_headers.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{s}:{s}\n", .{ header.name, header.value }));
    }

    const query = if (query_start < url.len) try canonicalQuery(allocator, url[query_start + 1 ..]) else "";
    const canonical = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n{s}\n{s}\nUNSIGNED-PAYLOAD", .{
        method,
        url[path_start..query_start],
        query,
        canonical_headers.items,
        names.items,
    });
    var digest: [32]u8 = undefined;
    Sha256.hash(canonical, &digest, .{});
    const scope = try std.fmt.allocPrint(allocator, "{s}/{s}/s3/aws4_request", .{ date[0..8], config.region });
    const to_sign = try std.fmt.allocPrint(allocator, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ date, scope, std.fmt.bytesToHex(digest, .lower) });

    const initial = try std.fmt.allocPrint(allocator, "AWS4{s}", .{secret});
    var date_key: [32]u8 = undefined;
    Hmac.create(&date_key, date[0..8], initial);
    var region_key: [32]u8 = undefined;
    Hmac.create(&region_key, config.region, &date_key);
    var service_key: [32]u8 = undefined;
    Hmac.create(&service_key, "s3", &region_key);
    var signing_key: [32]u8 = undefined;
    Hmac.create(&signing_key, "aws4_request", &service_key);
    var signature: [32]u8 = undefined;
    Hmac.create(&signature, to_sign, &signing_key);

    return .{
        .host = host,
        .date = date,
        .authorization = try std.fmt.allocPrint(
            allocator,
            "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
            .{ access, scope, names.items, std.fmt.bytesToHex(signature, .lower) },
        ),
    };
}

fn normalize(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, value, " \t");
    while (words.next()) |word| {
        if (result.items.len > 0) try result.append(allocator, ' ');
        try result.appendSlice(allocator, word);
    }
    return result.toOwnedSlice(allocator);
}

fn canonicalQuery(allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
    var entries: std.ArrayList(Header) = .empty;
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = try encode(allocator, try decode(allocator, pair[0..equals]), false);
        const value = if (equals < pair.len) try encode(allocator, try decode(allocator, pair[equals + 1 ..]), false) else "";
        try entries.append(allocator, .{ .name = key, .value = value });
    }
    std.mem.sort(Header, entries.items, {}, Header.less);
    var encoded: std.ArrayList([]const u8) = .empty;
    for (entries.items) |entry| {
        try encoded.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.name, entry.value }));
    }
    return std.mem.join(allocator, "&", encoded.items);
}

test "canonical query sorts parameter names before their values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const query = try canonicalQuery(arena.allocator(), "a-z=1&a=z&a=a&encoded=caf%C3%A9%20%2B");
    try std.testing.expectEqualStrings("a=a&a=z&a-z=1&encoded=caf%C3%A9%20%2B", query);
}
