pub const Modal = enum { none, connect, upload, download, mkdir, delete, rename, signed_url, palette };

pub const Action = enum {
    connect,
    demo,
    upload,
    download,
    mkdir,
    delete,
    refresh,
    parent,
    flat,
    inspector,
    transfers,
    dismiss,
    submit,
    clear_selection,
    choose_source,
    choose_destination,
    palette,
    signed_url,
    signed_put,
    copy_url,
    copy_key,
    copy_s3_uri,
    select_all,
    copy,
    cut,
    paste,
    rename,
    preview,
    details,
    cancel_transfer,
    retry_transfer,
};

pub const Sort = enum { name, size, modified };

pub const Upload = struct {
    path: []const u8,
    key: []const u8,
    bytes: u64 = 0,
    status: enum { queued, uploading, complete, failed, canceled } = .queued,
    detail: []const u8 = "",
};

pub const Transfer = struct {
    name: []const u8,
    detail: []const u8,
    failed: bool = false,
};
