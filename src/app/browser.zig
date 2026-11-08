const std = @import("std");
const ui = @import("zircon_ui");
const s3 = @import("../storage/s3.zig");
const demo_module = @import("../storage/demo.zig");
const types = @import("../models/browser.zig");
const Input = ui.controls.TextInput;
const c = @import("../views/components.zig").c;
const jobs = @import("../storage/jobs.zig");
const Modal = types.Modal;
const Sort = types.Sort;
const Upload = types.Upload;
const Transfer = types.Transfer;

pub const Browser = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    listing: *std.heap.ArenaAllocator,
    demo_store: demo_module.Store,
    demo: bool = true,
    preview: @import("../models/preview.zig").Preview = .{},
    active_job: ?ui.tasks.Handle = null,
    preview_field: ui.Entity(@import("../views/editor_field.zig").EditorField),
    endpoint: []const u8,
    region: []const u8,
    initial_bucket: []const u8,
    has_credentials: bool,
    environment: *std.process.Environ.Map,
    session_token: bool,
    buckets: []s3.Bucket = &.{},
    objects: []s3.Object = &.{},
    bucket: []const u8 = "acme-assets",
    prefix: []const u8 = "",
    listed_bucket: []const u8 = "acme-assets",
    listed_prefix: []const u8 = "",
    listed_region: []const u8 = "us-east-1",
    listed_flat: bool = false,
    bucket_query: []const u8 = "",
    object_query: []const u8 = "",
    bucket_filter: ui.Entity(Input),
    object_filter: ui.Entity(Input),
    endpoint_field: ui.Entity(Input),
    region_field: ui.Entity(Input),
    bucket_field: ui.Entity(Input),
    path_field: ui.Entity(Input),
    name_field: ui.Entity(Input),
    palette_field: ui.Entity(Input),
    url_field: ui.Entity(Input),
    palette_query: []const u8 = "",
    palette_index: usize = 0,
    signed_url: []const u8 = "",
    signed_expires: u32 = 3600,
    signed_method: []const u8 = "GET",
    uploads: std.ArrayList(Upload) = .empty,
    upload_cursor: usize = 0,
    active_upload: ?usize = null,
    progress: *@import("../transfers/upload.zig").Progress,
    transfer_started: i64 = 0,
    progress_speed: u64 = 0,
    progress_sent: u64 = 0,
    progress_total: u64 = 0,
    drop_active: bool = false,
    drop_folder: ?usize = null,
    clipboard: @import("../models/clipboard.zig").Clipboard = .{},
    selection: @import("../models/selection.zig").Selection = .{},
    sort: Sort = .name,
    descending: bool = false,
    flat: bool = false,
    show_inspector: bool = true,
    show_transfers: bool = false,
    scroll: ui.controls.Scroll = .{},
    bucket_scroll: ui.controls.Scroll = .{},
    modal: Modal = .none,
    message: []const u8 = "",
    modal_error: []const u8 = "",
    busy: bool = false,
    pending: jobs.Kind = .list,
    pending_key: []const u8 = "",
    pending_path: []const u8 = "",
    completed: usize = 0,
    failed: usize = 0,
    history: std.ArrayList(Transfer) = .empty,

    pub fn keep(self: *const Browser, value: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, value);
    }

    pub fn init(app: *ui.App, a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Browser {
        const arena = try a.create(std.heap.ArenaAllocator);
        arena.* = .init(a);
        errdefer {
            arena.deinit();
            a.destroy(arena);
        }
        const listing = try a.create(std.heap.ArenaAllocator);
        listing.* = .init(a);
        errdefer {
            listing.deinit();
            a.destroy(listing);
        }

        const p = arena.allocator();
        const endpoint = try p.dupe(u8, env.get("S3_ENDPOINT") orelse "https://s3.us-east-1.amazonaws.com");
        const region = try p.dupe(u8, env.get("AWS_REGION") orelse env.get("AWS_DEFAULT_REGION") orelse "us-east-1");
        const bucket = try p.dupe(u8, env.get("S3_BUCKET") orelse "");
        const environment = try p.create(std.process.Environ.Map);
        environment.* = try env.clone(p);
        const progress = try p.create(@import("../transfers/upload.zig").Progress);
        progress.* = .{};
        const EditorField = @import("../views/editor_field.zig").EditorField;
        var self: Browser = .{
            .preview_field = try app.createEntity(EditorField, try EditorField.init(a, "")),
            .allocator = a,
            .io = io,
            .arena = arena,
            .listing = listing,
            .demo_store = try demo_module.Store.init(p),
            .endpoint = endpoint,
            .region = region,
            .initial_bucket = bucket,
            .environment = environment,
            .has_credentials = env.get("AWS_ACCESS_KEY_ID") != null and env.get("AWS_SECRET_ACCESS_KEY") != null,
            .session_token = env.get("AWS_SESSION_TOKEN") != null,
            .progress = progress,
            .palette_field = try field(app, a, "", "Search commands…", .search),
            .url_field = try field(app, a, "", "Signed download URL", null),
            .bucket_filter = try field(app, a, "", "Filter buckets", .search),
            .object_filter = try field(app, a, "", "Filter this folder", .search),
            .endpoint_field = try field(app, a, endpoint, "https://s3.example.com", null),
            .region_field = try field(app, a, region, "us-east-1", null),
            .bucket_field = try field(app, a, bucket, "Optional bucket name", null),
            .path_field = try field(app, a, "", "/absolute/path/to/file", null),
            .name_field = try field(app, a, "", "Folder name", null),
        };

        try self.loadDemo();
        return self;
    }

    pub fn field(app: *ui.App, a: std.mem.Allocator, value: []const u8, placeholder: []const u8, icon: ?ui.controls.icons.Name) !ui.Entity(Input) {
        var input = try Input.init(a, value);
        errdefer input.deinit(a);
        input.placeholder = placeholder;
        input.font_size = 14;
        input.height = 32;
        input.leading_icon = icon;
        input.appearance = .{
            .background = .rgb(0xffffff),
            .foreground = c.text,
            .placeholder = c.muted,
            .selection = c.blue,
            .caret = c.accent,
            .border = .rgb(0xcdcdc5),
            .focus_border = c.accent,
        };
        return app.createEntity(Input, input);
    }

    pub fn deinit(self: *Browser, a: std.mem.Allocator) void {
        if (self.preview.image) |*image| image.deinit();
        a.free(self.preview.bytes);
        self.listing.deinit();
        a.destroy(self.listing);
        self.arena.deinit();
        a.destroy(self.arena);
    }

    pub fn attach(self: *Browser, cx: *ui.Context(Browser)) !void {
        try cx.app.watchExternal(cx.owner, progressChanged);
        _ = try cx.observe(self.palette_field, paletteChanged);
        _ = try cx.observe(self.bucket_filter, filtersChanged);
        _ = try cx.observe(self.object_filter, filtersChanged);
        cx.notify();
    }

    pub fn connectSaved(self: *Browser, cx: *ui.Context(Browser)) !void {
        self.demo = false;
        self.prefix = "";
        try self.start(cx, .connect, "", "");
    }

    pub fn filtersChanged(self: *Browser, cx: *ui.Context(Browser), _: ui.Entity(Input)) !void {
        self.bucket_query = try self.readField(cx, self.bucket_filter);
        self.object_query = try self.readField(cx, self.object_filter);
        self.scroll.offset = 0;
        self.bucket_scroll.offset = 0;
        self.selection.clear();
        cx.notify();
    }

    pub fn readField(self: *Browser, cx: *ui.Context(Browser), handle: ui.Entity(Input)) ![]const u8 {
        var value: []u8 = undefined;
        try cx.read(handle, Input.copy, .{ self.arena.allocator(), &value });
        return value;
    }

    pub fn setField(input: *Input, cx: *ui.Context(Input), value: []const u8) !void {
        input.bytes.clearRetainingCapacity();
        try input.bytes.appendSlice(input.allocator, value);
        input.anchor = value.len;
        input.cursor = value.len;
        input.revision +%= 1;
        input.marked = null;
        cx.notify();
    }

    pub fn loadDemo(self: *Browser) !void {
        _ = self.listing.reset(.retain_capacity);
        const a = self.listing.allocator();
        self.buckets = try a.dupe(s3.Bucket, &demo_module.buckets);
        self.objects = try self.demo_store.list(a, self.bucket, self.prefix, self.flat);
        self.sortObjects();
        self.selection.clear();
        self.preview.open = false;
        self.scroll.offset = 0;
        self.recordListing();
    }

    pub fn recordListing(self: *Browser) void {
        self.listed_bucket = self.bucket;
        self.listed_prefix = self.prefix;
        self.listed_region = self.region;
        self.listed_flat = self.flat;
    }

    pub fn effectiveRegion(self: *const Browser) []const u8 {
        if (self.demo) for (self.buckets) |bucket| {
            if (std.mem.eql(u8, bucket.name, self.bucket)) return bucket.region;
        };
        return self.region;
    }

    pub fn less(self: *const Browser, lhs: s3.Object, rhs: s3.Object) bool {
        if (lhs.folder != rhs.folder) return lhs.folder;
        const order = switch (self.sort) {
            .name => std.ascii.orderIgnoreCase(lhs.key, rhs.key),
            .size => std.math.order(lhs.size, rhs.size),
            .modified => std.mem.order(u8, lhs.modified, rhs.modified),
        };
        return if (self.descending) order == .gt else order == .lt;
    }

    pub fn sortObjects(self: *Browser) void {
        std.mem.sort(s3.Object, self.objects, self, less);
    }

    pub fn matches(value: []const u8, query: []const u8) bool {
        if (query.len == 0) return true;
        if (query.len > value.len) return false;
        for (0..value.len - query.len + 1) |i| if (std.ascii.eqlIgnoreCase(value[i..][0..query.len], query)) return true;
        return false;
    }

    pub fn selected(self: *const Browser) ?s3.Object {
        return if (self.selection.primary) |i| if (i < self.objects.len) self.objects[i] else null else null;
    }

    pub fn visible(self: *const Browser, b: *ui.Ui) ![]usize {
        var indices: std.ArrayList(usize) = .empty;
        for (self.objects, 0..) |object, i| if (matches(object.name(self.prefix), self.object_query)) {
            try indices.append(b.allocator(), i);
        };
        return indices.toOwnedSlice(b.allocator());
    }

    pub fn errorText(err: anyerror) []const u8 {
        return switch (err) {
            error.Canceled => "Canceled",
            error.ExpectedRegularFile => "Choose regular files to upload. Folder uploads are not enabled in this version.",
            error.IncompleteDownload => "The download was incomplete. The destination file was not created.",
            error.CannotPasteIntoSource => "Choose a destination outside the selected source folder.",
            error.CopyResultUnknown => "The copy result could not be confirmed. The source was kept; refresh before trying again.",
            error.SourceChanged => "The source changed. Refresh before trying the operation again.",
            error.AccessDenied => "Access denied. Check the account's bucket permissions.",
            error.SignatureDoesNotMatch => "Signature mismatch. Check credentials, endpoint, and region.",
            error.ObjectAlreadyExists => "An object with this name already exists. Choose another name.",
            error.NoSuchBucket => "Bucket not found. Check its name and endpoint.",
            error.InvalidEndpoint => "Enter an HTTP or HTTPS endpoint without credentials or a query.",
            error.InvalidRegion => "Enter a valid signing region, such as us-east-1.",
            error.PathAlreadyExists => "A file already exists at this path. Choose a new destination.",
            error.FileNotFound => "File not found. Enter the full local file path.",
            error.S3RequestFailed => "S3 request failed. Check the endpoint, region, credentials, and network.",
            error.BucketPaginationUnsupported => "This account needs a bucket name. Connect to a specific bucket.",
            error.ListingLimitExceeded => "Listing exceeded 100,000 objects. Open a narrower folder.",
            else => @errorName(err),
        };
    }

    pub const refresh = @import("actions.zig").refresh;
    pub const navigate = @import("actions.zig").navigate;
    pub const bucketClick = @import("actions.zig").bucketClick;
    pub const objectClick = @import("actions.zig").objectClick;
    pub const openObject = @import("actions.zig").openObject;
    pub const sortClick = @import("actions.zig").sortClick;
    pub const onAction = @import("actions.zig").onAction;
    pub const act = @import("actions.zig").act;
    pub const submit = @import("actions.zig").submit;
    pub const showUploadForm = @import("actions.zig").showUploadForm;
    pub const showSignedUrl = @import("actions.zig").showSignedUrl;
    pub const expiryClick = @import("actions.zig").expiryClick;
    pub const urlReadOnly = @import("actions.zig").urlReadOnly;
    pub const paletteClick = @import("actions.zig").paletteClick;
    pub const paletteChanged = @import("actions.zig").paletteChanged;
    pub const start = @import("transfers.zig").start;
    pub const complete = @import("transfers.zig").complete;
    pub const addTransfer = @import("transfers.zig").addTransfer;
    pub const progressChanged = @import("transfers.zig").progressChanged;
    pub const enqueuePaths = @import("transfers.zig").enqueuePaths;
    pub const startNextUpload = @import("transfers.zig").startNextUpload;
    pub const finishUpload = @import("transfers.zig").finishUpload;
    pub const folderDrop = @import("transfers.zig").folderDrop;
    pub const onBucketScroll = @import("input.zig").onBucketScroll;
    pub const onScroll = @import("input.zig").onScroll;
    pub const onInput = @import("input.zig").onInput;
    pub const onModalInput = @import("input.zig").onModalInput;
    pub const render = @import("../views/root.zig").render;
};
