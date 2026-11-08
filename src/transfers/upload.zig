const std = @import("std");
const ui = @import("zircon_ui");
const s3 = @import("../storage/s3.zig");
const curl = @import("../platform/curl_abi.zig");
pub const Progress = struct {
    sent: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),

    pub fn reset(self: *Progress) void {
        self.sent.store(0, .release);
        self.total.store(0, .release);
    }
};
const Transfer = struct {
    file: std.Io.File,
    io: std.Io,
    cancel: *ui.tasks.Cancellation,
    progress: *Progress,
    failed_read: bool = false,

    fn read(buffer: [*c]u8, size: usize, count: usize, raw: ?*anyopaque) callconv(.c) usize {
        const self: *Transfer = @ptrCast(@alignCast(raw.?));
        if (self.cancel.isCanceled()) return curl.CURL_READFUNC_ABORT;
        return self.file.readStreaming(self.io, &.{buffer[0 .. size * count]}) catch {
            self.failed_read = true;
            return curl.CURL_READFUNC_ABORT;
        };
    }

    fn discard(_: [*c]u8, size: usize, count: usize, _: ?*anyopaque) callconv(.c) usize {
        return size * count;
    }

    fn update(raw: ?*anyopaque, _: curl.curl_off_t, _: curl.curl_off_t, total: curl.curl_off_t, sent: curl.curl_off_t) callconv(.c) c_int {
        const self: *Transfer = @ptrCast(@alignCast(raw.?));
        if (self.cancel.isCanceled()) return 1;
        const previous = self.progress.sent.swap(@intCast(@max(0, sent)), .acq_rel);
        self.progress.total.store(@intCast(@max(0, total)), .release);
        if (previous != @as(u64, @intCast(@max(0, sent)))) ui.App.wake();
        return 0;
    }
};

pub fn send(
    a: std.mem.Allocator,
    io: std.Io,
    config: s3.Config,
    bucket: []const u8,
    key: []const u8,
    path: []const u8,
    progress: *Progress,
    cancel: *ui.tasks.Cancellation,
) !void {
    try config.validate();
    const env = config.environment orelse return error.MissingCredentials;

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.ExpectedRegularFile;

    progress.total.store(stat.size, .release);
    var transfer: Transfer = .{ .file = file, .io = io, .cancel = cancel, .progress = progress };

    const easy = curl.curl_easy_init() orelse return error.CurlInitFailed;
    defer curl.curl_easy_cleanup(easy);

    const url = try std.fmt.allocPrintSentinel(
        a,
        "{s}/{s}/{s}",
        .{
            std.mem.trimEnd(u8, config.endpoint, "/"),
            try s3.encode(a, bucket, false),
            try s3.encode(a, key, true),
        },
        0,
    );
    const signed = try @import("../storage/auth.zig").sign(a, io, config, "PUT", url, &.{ "--header", "If-None-Match: *" });
    var headers: ?*curl.curl_slist = null;
    defer curl.curl_slist_free_all(headers);
    try appendHeader(&headers, "If-None-Match: *");
    try appendHeader(&headers, "x-amz-content-sha256: UNSIGNED-PAYLOAD");
    try appendHeader(&headers, (try std.fmt.allocPrintSentinel(a, "Host: {s}", .{signed.host}, 0)).ptr);
    try appendHeader(&headers, (try std.fmt.allocPrintSentinel(a, "x-amz-date: {s}", .{signed.date}, 0)).ptr);
    try appendHeader(&headers, (try std.fmt.allocPrintSentinel(a, "Authorization: {s}", .{signed.authorization}, 0)).ptr);
    if (env.get("AWS_SESSION_TOKEN")) |token| {
        try appendHeader(&headers, (try std.fmt.allocPrintSentinel(a, "x-amz-security-token: {s}", .{token}, 0)).ptr);
    }

    try set(easy, curl.CURLOPT_URL, url.ptr);
    try set(easy, curl.CURLOPT_HTTPHEADER, headers);
    try set(easy, curl.CURLOPT_UPLOAD, @as(c_long, 1));
    try set(easy, curl.CURLOPT_INFILESIZE_LARGE, @as(curl.curl_off_t, @intCast(stat.size)));
    try set(easy, curl.CURLOPT_READFUNCTION, &Transfer.read);
    try set(easy, curl.CURLOPT_READDATA, @as(*anyopaque, @ptrCast(&transfer)));
    try set(easy, curl.CURLOPT_WRITEFUNCTION, &Transfer.discard);
    try set(easy, curl.CURLOPT_XFERINFOFUNCTION, &Transfer.update);
    try set(easy, curl.CURLOPT_XFERINFODATA, @as(*anyopaque, @ptrCast(&transfer)));
    try set(easy, curl.CURLOPT_NOPROGRESS, @as(c_long, 0));
    try set(easy, curl.CURLOPT_NOSIGNAL, @as(c_long, 1));
    try set(easy, curl.CURLOPT_PATH_AS_IS, @as(c_long, 1));
    try set(easy, curl.CURLOPT_CONNECTTIMEOUT, @as(c_long, 10));
    try set(easy, curl.CURLOPT_TIMEOUT, @as(c_long, 3600));

    const result = curl.curl_easy_perform(easy);
    if (cancel.isCanceled()) return error.Canceled;
    if (transfer.failed_read) return error.FileReadFailed;
    if (result != curl.CURLE_OK) return error.UploadFailed;
    var code: c_long = 0;
    _ = curl.curl_easy_getinfo(easy, curl.CURLINFO_RESPONSE_CODE, &code);
    if (code == 412) return error.ObjectAlreadyExists;
    if (code == 403) return error.AccessDenied;
    if (code < 200 or code >= 300) return error.UploadFailed;

    progress.sent.store(stat.size, .release);
    ui.App.wake();
}

fn set(easy: ?*curl.CURL, option: curl.CURLoption, value: anytype) !void {
    if (curl.curl_easy_setopt(easy, option, value) != curl.CURLE_OK) return error.CurlOptionFailed;
}

fn appendHeader(headers: *?*curl.curl_slist, value: [*:0]const u8) !void {
    headers.* = curl.curl_slist_append(headers.*, value) orelse return error.OutOfMemory;
}
