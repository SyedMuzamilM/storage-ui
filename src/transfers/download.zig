const std = @import("std");
const ui = @import("zircon_ui");
const s3 = @import("../storage/s3.zig");
const files = @import("files.zig");
const Job = @import("../storage/jobs.zig").Job;
const Outcome = @import("../storage/object_jobs.zig").Outcome;

pub fn one(client: s3.Client, bucket: []const u8, key: []const u8, destination: []const u8) !void {
    if (std.Io.Dir.cwd().openFile(client.io, destination, .{})) |existing| {
        existing.close(client.io);
        return error.PathAlreadyExists;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    const info = try client.head(bucket, key);
    const partial = try files.temporary(client.allocator, client.io, destination);
    const file = try std.Io.Dir.cwd().createFile(client.io, partial, .{ .exclusive = true });
    file.close(client.io);
    defer std.Io.Dir.cwd().deleteFile(client.io, partial) catch {};

    var arguments: std.ArrayList([]const u8) = .empty;
    try arguments.appendSlice(client.allocator, &.{ "--output", partial });
    if (info.etag.len > 0) {
        const condition = try std.fmt.allocPrint(client.allocator, "If-Match: {s}", .{info.etag});
        try arguments.appendSlice(client.allocator, &.{ "--header", condition });
    }
    _ = try client.request("GET", bucket, key, "", arguments.items);

    const downloaded = try std.Io.Dir.cwd().openFile(client.io, partial, .{});
    defer downloaded.close(client.io);
    const size = (try downloaded.stat(client.io)).size;
    if (size != info.size) return error.IncompleteDownload;
    try files.publish(client.io, partial, destination);
}

pub fn group(job: *Job, cancel: *ui.tasks.Cancellation) ![]Outcome {
    const allocator = job.arena.allocator();
    const client: s3.Client = .{ .allocator = allocator, .io = job.io, .config = job.config };
    var outcomes: std.ArrayList(Outcome) = .empty;

    const keys = if (job.demo)
        job.keys
    else
        try @import("../storage/object_jobs.zig").expand(allocator, client, job.bucket, job.keys);

    for (keys, 0..) |key, index| {
        try cancel.check();
        const failure: ?anyerror = block: {
            const relative = files.relative(key, job.prefix) catch |err| break :block err;
            const target = try std.fs.path.join(allocator, &.{ job.path, relative });
            if (std.mem.endsWith(u8, key, "/")) {
                std.Io.Dir.cwd().createDirPath(job.io, target) catch |err| break :block err;
            } else {
                const parent = std.fs.path.dirname(target) orelse return error.InvalidPath;
                std.Io.Dir.cwd().createDirPath(job.io, parent) catch |err| break :block err;
                if (job.demo) {
                    files.save(allocator, job.io, target, job.demo_downloads[index]) catch |err| break :block err;
                } else {
                    one(client, job.bucket, key, target) catch |err| break :block err;
                }
            }
            break :block null;
        };
        try outcomes.append(allocator, .{
            .key = key,
            .success = failure == null,
            .detail = if (failure) |err| @errorName(err) else "",
        });
    }

    return outcomes.toOwnedSlice(allocator);
}
