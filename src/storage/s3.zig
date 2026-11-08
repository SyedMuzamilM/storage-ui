//! Public S3 storage interface. Transport, parsing, and signing have separate modules.
pub const Bucket = @import("model.zig").Bucket;
pub const Object = @import("model.zig").Object;
pub const Config = @import("model.zig").Config;
pub const Client = @import("client.zig").Client;
pub const encode = @import("url.zig").encode;
pub const decode = @import("url.zig").decode;
pub const tag = @import("xml.zig").tag;
pub const unescape = @import("xml.zig").unescape;
pub const Page = @import("xml.zig").Page;
pub const parseObjects = @import("xml.zig").parseObjects;
pub const parseBuckets = @import("xml.zig").parseBuckets;
