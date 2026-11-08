const std = @import("std");
const ui = @import("zircon_ui");
const s3 = @import("s3.zig");
const jobs = @import("jobs.zig");

pub const Outcome = struct {
    key: []const u8,
    success: bool,
    detail: []const u8 = "",
};

pub fn expand(a: std.mem.Allocator, client: s3.Client, bucket: []const u8, keys: []const []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (keys) |key| {
        if (std.mem.endsWith(u8, key, "/")) {
            for (try client.objects(bucket, key, true)) |object| {
                const entry = try seen.getOrPut(a, object.key);
                if (!entry.found_existing) try result.append(a, object.key);
            }
        }
        const entry = try seen.getOrPut(a, key);
        if (!entry.found_existing) try result.append(a, key);
    }
    return result.toOwnedSlice(a);
}

pub fn mutate(job: *jobs.Job, cancel: *ui.tasks.Cancellation) ![]Outcome {
    const a = job.arena.allocator();
    const client: s3.Client = .{ .allocator = a, .io = job.io, .config = job.config };
    const source = if (job.source_bucket.len > 0) job.source_bucket else job.bucket;
    const selected = if (job.keys.len > 0) job.keys else &[_][]const u8{job.key};
    if (job.kind == .copy or job.kind == .move) for (selected) |key| {
        if (std.mem.eql(u8, source, job.bucket) and std.mem.endsWith(u8, key, "/") and std.mem.startsWith(u8, job.prefix, key)) return error.CannotPasteIntoSource;
    };
    const keys = try expand(a, client, source, selected);
    var result: std.ArrayList(Outcome) = .empty;
    for (keys) |key| {
        try cancel.check();
        const failure: ?anyerror = blk: {
            if (job.kind == .delete) {
                _ = client.request("DELETE", source, key, "", &.{}) catch |err| break :blk err;
            } else {
                const target = if (job.kind == .rename) job.destination_key else try std.fmt.allocPrint(
                    a,
                    "{s}{s}",
                    .{
                        job.prefix,
                        if (std.mem.startsWith(u8, key, job.source_prefix)) key[job.source_prefix.len..] else key,
                    },
                );
                client.copy(source, key, job.bucket, target, job.kind == .move or job.kind == .rename) catch |err| break :blk err;
            }
            break :blk null;
        };
        try result.append(a, .{
            .key = key,
            .success = failure == null,
            .detail = if (failure) |err| @errorName(err) else "",
        });
    }
    return result.toOwnedSlice(a);
}
