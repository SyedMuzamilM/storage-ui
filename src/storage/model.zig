const std = @import("std");

pub const Bucket = struct {
    name: []const u8,
    region: []const u8 = "us-east-1",
};

pub const Object = struct {
    key: []const u8,
    size: u64 = 0,
    modified: []const u8 = "",
    folder: bool = false,

    pub fn name(self: Object, prefix: []const u8) []const u8 {
        const relative = if (std.mem.startsWith(u8, self.key, prefix)) self.key[prefix.len..] else self.key;
        return if (self.folder) std.mem.trimEnd(u8, relative, "/") else relative;
    }
};

pub const Config = struct {
    endpoint: []const u8,
    region: []const u8,
    session_token: bool = false,
    environment: ?*const std.process.Environ.Map = null,

    pub fn validate(self: Config) !void {
        const uri = std.Uri.parse(self.endpoint) catch return error.InvalidEndpoint;
        const supported_scheme = std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "https");
        const has_credentials = uri.user != null or uri.password != null;
        const has_suffix = uri.query != null or uri.fragment != null;
        if (!supported_scheme or uri.host == null or has_credentials or has_suffix) {
            return error.InvalidEndpoint;
        }
        if (self.region.len == 0) return error.InvalidRegion;
        for (self.region) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidRegion;
    }
};
