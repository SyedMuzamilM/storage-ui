const std = @import("std");
const s3 = @import("s3.zig");
const Sha = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub fn timestamp(a: std.mem.Allocator, seconds: i64) ![]const u8 {
    if (seconds < 0) return error.InvalidTime;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year = epoch.getEpochDay()
        .calculateYearDay();
    const month = year.calculateMonthDay();
    const day = epoch.getDaySeconds();
    return std.fmt.allocPrint(
        a,
        "{d}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z",
        .{
            year.year,
            @backingInt(month.month),
            @as(u16, month.day_index) + 1,
            day.getHoursIntoDay(),
            day.getMinutesIntoHour(),
            day.getSecondsIntoMinute(),
        },
    );
}

pub fn get(a: std.mem.Allocator, config: s3.Config, bucket: []const u8, key: []const u8, expires: u32, date: []const u8) ![]const u8 {
    return url(a, config, bucket, key, expires, date, "GET");
}

pub fn url(
    a: std.mem.Allocator,
    config: s3.Config,
    bucket: []const u8,
    key: []const u8,
    expires: u32,
    date: []const u8,
    method: []const u8,
) ![]const u8 {
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "PUT")) return error.InvalidMethod;
    try config.validate();
    if (expires == 0 or expires > 604800) return error.InvalidExpiry;
    if (date.len != 16) return error.InvalidTime;

    const env = config.environment orelse return error.MissingCredentials;
    const access = env.get("AWS_ACCESS_KEY_ID") orelse return error.MissingCredentials;
    const secret = env.get("AWS_SECRET_ACCESS_KEY") orelse return error.MissingCredentials;

    const start = (std.mem.indexOf(u8, config.endpoint, "://") orelse return error.InvalidEndpoint) + 3;
    const authority_end = std.mem.indexOfScalarPos(u8, config.endpoint, start, '/') orelse config.endpoint.len;
    const authority = try a.dupe(u8, config.endpoint[start..authority_end]);
    for (authority) |*ch| ch.* = std.ascii.toLower(ch.*);
    const path = try std.fmt.allocPrint(
        a,
        "{s}/{s}/{s}",
        .{
            std.mem.trimEnd(u8, config.endpoint[authority_end..], "/"),
            try s3.encode(a, bucket, false),
            try s3.encode(a, key, true),
        },
    );

    const scope = try std.fmt.allocPrint(a, "{s}/{s}/s3/aws4_request", .{ date[0..8], config.region });
    const credential = try std.fmt.allocPrint(a, "{s}/{s}", .{ access, scope });
    const token = if (env.get("AWS_SESSION_TOKEN")) |s| try std.fmt.allocPrint(a, "&X-Amz-Security-Token={s}", .{try s3.encode(a, s, false)}) else "";
    const query = try std.fmt.allocPrint(
        a,
        "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential={s}&X-Amz-Date={s}&X-Amz-Expires={d}{s}&X-Amz-SignedHeaders=host",
        .{ try s3.encode(a, credential, false), date, expires, token },
    );

    const canonical = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\nhost:{s}\n\nhost\nUNSIGNED-PAYLOAD", .{ method, path, query, authority });
    var digest: [32]u8 = undefined;
    Sha.hash(canonical, &digest, .{});
    const to_sign = try std.fmt.allocPrint(a, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ date, scope, std.fmt.bytesToHex(digest, .lower) });

    const initial_key = try std.fmt.allocPrint(a, "AWS4{s}", .{secret});
    var date_key: [32]u8 = undefined;
    Hmac.create(&date_key, date[0..8], initial_key);
    var region_key: [32]u8 = undefined;
    Hmac.create(&region_key, config.region, &date_key);
    var service_key: [32]u8 = undefined;
    Hmac.create(&service_key, "s3", &region_key);
    var signing_key: [32]u8 = undefined;
    Hmac.create(&signing_key, "aws4_request", &service_key);
    var signature: [32]u8 = undefined;
    Hmac.create(&signature, to_sign, &signing_key);

    return std.fmt.allocPrint(
        a,
        "{s}://{s}{s}?{s}&X-Amz-Signature={s}",
        .{
            config.endpoint[0 .. start - 3],
            authority,
            path,
            query,
            std.fmt.bytesToHex(signature, .lower),
        },
    );
}
