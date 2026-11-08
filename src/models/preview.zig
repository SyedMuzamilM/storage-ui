const ui = @import("zircon_ui");
pub const Preview = struct {
    open: bool = false,
    bytes: []u8 = &.{},
    image: ?ui.graphics.images.Image = null,
    fit: bool = true,
    zoom: f32 = 1,
    scroll: ui.Point = .{},
    drag: ?ui.Point = null,
    truncated: bool = false,
};
