const std = @import("std");
const ui = @import("zircon_ui");
const s3 = @import("s3.zig");

pub const Kind = enum { connect, list, upload, download, mkdir, delete, preview, copy, move, rename };

pub const Result = struct {
    buckets: []s3.Bucket = &.{},
    objects: []s3.Object = &.{},
    bucket: []const u8 = "",
    content: []const u8 = "",
    listing_ok: bool = true,
    items: []@import("object_jobs.zig").Outcome = &.{},
};

pub const Job = struct {
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    kind: Kind,
    config: s3.Config,
    bucket: []const u8,
    prefix: []const u8,
    key: []const u8 = "",
    keys: []const []const u8 = &.{},
    source_bucket: []const u8 = "",
    source_prefix: []const u8 = "",
    destination_key: []const u8 = "",
    path: []const u8 = "",
    demo: bool = false,
    demo_content: []const u8 = "",
    demo_downloads: []const []const u8 = &.{},
    directory_download: bool = false,
    flat: bool = false,
    progress: ?*@import("../transfers/upload.zig").Progress = null,

    pub const Output = Result;

    pub fn run(self: *Job, cancel: *ui.tasks.Cancellation) !Result {
        try cancel.check();
        const a = self.arena.allocator();
        if (self.kind == .download and self.directory_download) return .{ .items = try @import("../transfers/download.zig").group(self, cancel) };
        if (self.demo) {
            switch (self.kind) {
                .upload => {
                    const content = try std.Io.Dir.cwd()
                        .readFileAlloc(self.io, self.path, a, .limited(32 * 1024 * 1024));
                    if (self.progress) |progress| {
                        progress.total.store(content.len, .release);
                        progress.sent.store(content.len, .release);
                        ui.App.wake();
                    }
                    return .{ .content = content };
                },
                .preview => return .{ .content = try a.dupe(u8, self.demo_content) },
                .download => try @import("../transfers/files.zig")
                    .save(a, self.io, self.path, self.demo_content),
                else => {},
            }
            return .{};
        }
        const client: s3.Client = .{ .allocator = a, .io = self.io, .config = self.config };
        var bucket = self.bucket;
        var buckets: []s3.Bucket = &.{};
        var outcomes: []@import("object_jobs.zig").Outcome = &.{};
        switch (self.kind) {
            .connect => {
                if (bucket.len == 0) {
                    buckets = try client.buckets();
                    if (buckets.len > 0) bucket = buckets[0].name;
                } else buckets = try a.dupe(s3.Bucket, &.{.{ .name = bucket, .region = self.config.region }});
            },
            .upload => {
                if (self.progress) |progress| {
                    try @import("../transfers/upload.zig").send(a, self.io, self.config, bucket, self.key, self.path, progress, cancel);
                } else {
                    _ = try client.request("PUT", bucket, self.key, "", &.{ "--header", "If-None-Match: *", "--upload-file", self.path });
                }
            },
            .mkdir => {
                _ = try client.request("PUT", bucket, self.key, "", &.{ "--header", "Content-Length: 0" });
            },
            .delete, .copy, .move, .rename => outcomes = try @import("object_jobs.zig")
                .mutate(self, cancel),
            .download => {
                try @import("../transfers/download.zig").one(client, bucket, self.key, self.path);
                return .{};
            },
            .preview => return .{
                .content = try client.request("GET", bucket, self.key, "", &.{ "--range", "0-1048575" }),
            },
            .list => {},
        }
        try cancel.check();
        var listing_ok = true;
        const objects: []s3.Object = if (bucket.len > 0) client.objects(bucket, self.prefix, self.flat) catch |err| blk: {
            switch (self.kind) {
                .upload, .mkdir, .delete, .copy, .move, .rename => {
                    listing_ok = false;
                    break :blk &.{};
                },
                else => return err,
            }
        } else &.{};
        return .{
            .buckets = buckets,
            .bucket = bucket,
            .objects = objects,
            .listing_ok = listing_ok,
            .items = outcomes,
        };
    }

    pub fn discard(_: *Job, _: Result) void {}

    pub fn deinit(self: *Job, _: std.mem.Allocator) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self.arena);
    }
};
