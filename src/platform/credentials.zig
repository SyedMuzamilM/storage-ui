const std = @import("std");
const ui = @import("zircon_ui");

pub const Account = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: []const u8 = "",
    endpoint: []const u8,
    region: []const u8,
    bucket: []const u8,
};

pub fn load(allocator: std.mem.Allocator, environment: *std.process.Environ.Map) !bool {
    if (hasEnvironmentCredentials(environment)) return false;
    if (comptime ui.testing.native == void) return false else {
        const bytes = native.read(allocator) orelse return false;
        defer {
            @memset(bytes, 0);
            allocator.free(bytes);
        }
        const parsed = try std.json.parseFromSlice(Account, allocator, bytes, .{});
        defer parsed.deinit();
        try apply(environment, parsed.value);
        return true;
    }
}

pub fn hasEnvironmentCredentials(environment: *const std.process.Environ.Map) bool {
    const access = environment.get("AWS_ACCESS_KEY_ID") orelse return false;
    const secret = environment.get("AWS_SECRET_ACCESS_KEY") orelse return false;
    return access.len > 0 and secret.len > 0;
}

pub fn save(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) !void {
    if (comptime ui.testing.native == void) return error.NativeKeychainUnavailable else {
        const account: Account = .{
            .access_key_id = environment.get("AWS_ACCESS_KEY_ID") orelse return error.MissingCredentials,
            .secret_access_key = environment.get("AWS_SECRET_ACCESS_KEY") orelse return error.MissingCredentials,
            .session_token = environment.get("AWS_SESSION_TOKEN") orelse "",
            .endpoint = environment.get("S3_ENDPOINT") orelse return error.InvalidEndpoint,
            .region = environment.get("AWS_REGION") orelse "us-east-1",
            .bucket = environment.get("S3_BUCKET") orelse "",
        };
        const bytes = try std.json.Stringify.valueAlloc(allocator, account, .{});
        defer {
            @memset(bytes, 0);
            allocator.free(bytes);
        }
        try native.write(bytes);
    }
}

pub fn apply(environment: *std.process.Environ.Map, account: Account) !void {
    try environment.put("AWS_ACCESS_KEY_ID", account.access_key_id);
    try environment.put("AWS_SECRET_ACCESS_KEY", account.secret_access_key);
    if (account.session_token.len > 0) try environment.put("AWS_SESSION_TOKEN", account.session_token);
    try environment.put("S3_ENDPOINT", account.endpoint);
    try environment.put("AWS_REGION", account.region);
    try environment.put("S3_BUCKET", account.bucket);
    try environment.put("S3_AUTOCONNECT", "1");
}

const native = if (ui.testing.native == void) struct {} else struct {
    const objc = ui.testing.native.objc;
    const Id = objc.Id;
    extern "c" var kSecClass: Id;
    extern "c" var kSecClassGenericPassword: Id;
    extern "c" var kSecAttrService: Id;
    extern "c" var kSecAttrAccount: Id;
    extern "c" var kSecAttrAccess: Id;
    extern "c" var kSecValueData: Id;
    extern "c" var kSecReturnData: Id;
    extern "c" var kSecUseAuthenticationUI: Id;
    extern "c" var kSecUseAuthenticationUIFail: Id;
    extern "c" fn SecItemCopyMatching(Id, *Id) i32;
    extern "c" fn SecItemUpdate(Id, Id) i32;
    extern "c" fn SecItemAdd(Id, ?*Id) i32;
    extern "c" fn SecAccessCreate(Id, Id, *Id) i32;

    fn dictionary() Id {
        return objc.send(Id, objc.class("NSMutableDictionary"), "dictionary", .{});
    }

    fn set(target: Id, key: Id, value: Id) void {
        objc.send(void, target, "setObject:forKey:", .{ value, key });
    }

    fn query() Id {
        const result = dictionary();
        set(result, kSecClass, kSecClassGenericPassword);
        set(result, kSecAttrService, objc.string("dev.storage-ui.native-account"));
        set(result, kSecAttrAccount, objc.string("default"));
        return result;
    }

    fn read(allocator: std.mem.Allocator) ?[]u8 {
        const pool = objc.Pool.init();
        defer pool.deinit();
        const request = query();
        set(request, kSecReturnData, objc.send(Id, objc.class("NSNumber"), "numberWithBool:", .{true}));
        set(request, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
        var result: Id = null;
        if (SecItemCopyMatching(request, &result) != 0) return null;
        defer objc.release(result);
        const length = objc.send(usize, result, "length", .{});
        const pointer = objc.send(?[*]const u8, result, "bytes", .{}) orelse return null;
        return allocator.dupe(u8, pointer[0..length]) catch null;
    }

    fn write(bytes: []const u8) !void {
        const pool = objc.Pool.init();
        defer pool.deinit();
        const data = objc.send(Id, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, bytes.len });
        const request = query();
        const attributes = dictionary();
        set(attributes, kSecValueData, data);
        // Refresh the trusted executable when a development build changes.
        var access: Id = null;
        if (SecAccessCreate(objc.string("Storage S3 account"), null, &access) != 0) return error.KeychainSaveFailed;
        defer objc.release(access);
        set(attributes, kSecAttrAccess, access);
        const status = SecItemUpdate(request, attributes);
        if (status == -25300) {
            set(request, kSecValueData, data);
            set(request, kSecAttrAccess, access);
            if (SecItemAdd(request, null) != 0) return error.KeychainSaveFailed;
        } else if (status != 0) {
            return error.KeychainSaveFailed;
        }
    }
};
