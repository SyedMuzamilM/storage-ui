pub const Clipboard = struct {
    bucket: []const u8 = "",
    prefix: []const u8 = "",
    keys: []const []const u8 = &.{},
    move: bool = false,
};
