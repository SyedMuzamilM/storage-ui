const std = @import("std");
const ui = @import("zircon_ui");
const text = @import("zircon_text");
const editing = @import("zircon_editor");
pub const EditorField = struct {
    allocator: std.mem.Allocator,
    document: text.Document,
    editor: editing.Editor,
    readonly: bool = false,

    pub fn init(a: std.mem.Allocator, bytes: []const u8) !EditorField {
        var document = try text.Document.init(a, bytes);
        errdefer document.deinit();
        var editor = try editing.Editor.init(a);
        editor.theme = .light;
        editor.font_size = 13;
        editor.line_height = 21;
        editor.language = .json;
        editor.show_fold_controls = false;
        editor.show_indent_guides = false;
        var snapshot = document.snapshot();
        defer snapshot.deinit();
        editor.synchronize(snapshot);
        return .{ .allocator = a, .document = document, .editor = editor };
    }

    pub fn deinit(self: *EditorField, _: std.mem.Allocator) void {
        self.document.deinit();
        self.editor.deinit();
    }

    pub fn replace(self: *EditorField, cx: *ui.Context(EditorField), bytes: []const u8, readonly: bool) !void {
        var next = try init(self.allocator, bytes);
        next.readonly = readonly;
        self.deinit(self.allocator);
        self.* = next;
        cx.notify();
    }

    pub fn copy(self: *const EditorField, a: std.mem.Allocator, output: *[]u8) !void {
        var snapshot = self.document.snapshot();
        defer snapshot.deinit();
        output.* = try snapshot.copy(a, .{ .start = 0, .end = snapshot.byteLen() });
    }

    pub fn render(self: *const EditorField, b: *ui.Ui) !ui.Element {
        return b.fluent()
            .adopt(try self.editor.render(&self.document, b))
            .id(.named("document-editor"))
            .grow()
            .min_h_px(80)
            .focusable()
            .on_input(b.onInput(input))
            .build();
    }

    fn input(self: *EditorField, event: *ui.Event(ui.Input), cx: *ui.Context(EditorField)) !void {
        if (self.readonly) {
            if (event.data == .text or event.data == .edit) {
                event.preventDefault();
                return;
            }
            if (event.data == .key_down) {
                const key = event.data.key_down;
                if (key.key == .tab) return;
                if (key.key == .enter or key.key == .backspace or key.key == .delete or ((key.modifiers.command or key.modifiers.control) and (key.key == .v or key.key == .x or key.key == .z))) {
                    event.preventDefault();
                    return;
                }
            }
        }
        var outcome = try self.editor.handle(&self.document, event);
        defer if (outcome.change) |*change| change.deinit();
        if (outcome.handled) {
            event.preventDefault();
            cx.notify();
        }
    }
};
