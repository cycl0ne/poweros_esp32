// SPDX-License-Identifier: MIT
//! The default icons: one for each kind, one for a script, and one for
//! each group of files datatypes.library knows - each read from
//! `ENV:Sys/def_<name>.info` when that is there and of the right kind,
//! else the one built in. The five kinds have one built in; a script and
//! the groups only have one when a file gives it, and otherwise a
//! project's.
//!
//! **The base keeps what it has read**: a default's picture, the text of
//! its fields, and the date and size of the file they came from. A later
//! call looks at the file again - a lock and an Examine, no read - and
//! reuses all of it while the file is unchanged. A file changed is read
//! again, a file gone falls back to the built-in one. So a drawer of
//! files without icons shares a handful of pictures, however many icons
//! are made from them.
//!
//! The defaults are under a semaphore in the base, since filling one
//! reads a file. No requester is put up for `ENV:` while it is read: a
//! system without it simply has the built-in icons.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const iconfile = icon.file;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const IconBase = @import("../icon_base.zig").IconBase;
const _object = @import("../object/_object.zig");
const _picture = @import("../picture/_picture.zig");
const Picture = _picture.Picture;

/// The defaults by name: the kinds `WBDISK` to `WBGARBAGE` first, in
/// their order, then a script, then the groups of `groups`.
pub const names = [_][]const u8{
    "disk",      "drawer", "tool",     "project", "trashcan",   "script",
    "picture",   "text",   "document", "sound",   "instrument", "music",
    "animation", "movie",
};
pub const count = names.len;

/// Where a script's default is, and the groups' after it.
pub const SCRIPT = 5;
const FIRST_GROUP = 6;
const groups = [_]u32{
    datatypes.GID_PICTURE,    datatypes.GID_TEXT,  datatypes.GID_DOCUMENT,  datatypes.GID_SOUND,
    datatypes.GID_INSTRUMENT, datatypes.GID_MUSIC, datatypes.GID_ANIMATION, datatypes.GID_MOVIE,
};

/// The pictures built in, by kind.
const built_in = [_][]const u8{
    @embedFile("../images/disk.png"),
    @embedFile("../images/drawer.png"),
    @embedFile("../images/tool.png"),
    @embedFile("../images/project.png"),
    @embedFile("../images/trashcan.png"),
};

/// One default as the base keeps it.
pub const Default = extern struct {
    /// Its picture, held by the base; null until it is first asked for.
    picture: ?*Picture = null,
    /// The text of its fields, when it came from a file, in memory of
    /// its own.
    fields: ?[*]u8 = null,
    fields_length: u32 = 0,
    /// It came from `ENV:`; and that file's date and size then.
    from_file: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    date: dos.DateStamp = .{},
    size: u64 align(4) = 0,
};

/// The kind a default's icon has.
pub fn kindOfSlot(slot: usize) u32 {
    return if (slot < built_in.len) @intCast(slot + 1) else icon.WBPROJECT;
}

/// The default `slot` as an icon of its own, without a place; null when
/// there is none - no file gives one and none is built in - or without
/// the memory.
pub fn get(base: *IconBase, slot: usize) ?*icon.DiskObject {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.defaults_lock);
    defer sys.ReleaseSemaphore(&base.defaults_lock);
    refresh(base, slot);
    const entry = &base.defaults[slot];
    const picture = entry.picture orelse return null;
    _picture.hold(base, picture);
    const fields: []const u8 = if (entry.fields) |text| text[0..entry.fields_length] else "";
    const object = _object.make(base, fields, kindOfSlot(slot), picture) orelse return null;
    object.current_x = icon.NO_ICON_POSITION;
    object.current_y = icon.NO_ICON_POSITION;
    return object;
}

/// The default `slot` forgotten, so the next call reads it again.
pub fn forget(base: *IconBase, slot: usize) void {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.defaults_lock);
    defer sys.ReleaseSemaphore(&base.defaults_lock);
    drop(base, &base.defaults[slot]);
}

/// Every default let go of, at the expunge.
pub fn forgetAll(base: *IconBase) void {
    for (&base.defaults) |*entry| drop(base, entry);
}

/// The slot of the group datatypes.library says the file `lock` is on is
/// in; null when it is in none of them or datatypes.library is not there.
pub fn groupSlot(base: *IconBase, lock: *dos.FileLock) ?usize {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.defaults_lock);
    if (base.datatypes_tried == 0) {
        base.datatypes_tried = 1;
        if (sys.OpenLibrary(sdk.interface.datatypes.NAME, 1)) |lib| base.datatypes_base = @ptrCast(lib);
    }
    const dt = base.datatypes_base;
    sys.ReleaseSemaphore(&base.defaults_lock);
    const library = dt orelse return null;
    const kind = library.ObtainDataTypeA(dtc.DTST_FILE, lock, null) orelse return null;
    defer library.ReleaseDataType(kind);
    for (groups, 0..) |group, index| {
        if (kind.header.group_id == group) return FIRST_GROUP + index;
    }
    return null;
}

/// A default brought up to date with its file in `ENV:`, or with the one
/// built in. Under the semaphore.
fn refresh(base: *IconBase, slot: usize) void {
    const sys = base.sys_base;
    const dl = base.dos_base;
    const entry = &base.defaults[slot];

    var path: [64]u8 = undefined;
    const name = pathOf(&path, "ENV:Sys/def_", names[slot], ".info");
    const old_window = quiet(base);
    defer loud(base, old_window);

    if (dl.Lock(name, dos.SHARED_LOCK)) |lock| {
        const fib_memory = sys.AllocVec(@sizeOf(dos.FileInfoBlock), exec.MEMF_ANY | exec.MEMF_CLEAR);
        defer if (fib_memory) |memory| sys.FreeVec(memory);
        const examined = if (fib_memory) |memory| dl.Examine(lock, @ptrCast(@alignCast(memory))) else false;
        dl.UnLock(lock);
        if (examined) {
            const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(fib_memory.?));
            if (entry.from_file != 0 and entry.date.eql(fib.date) and entry.size == fib.size) return;
            if (readFile(base, slot, name, fib)) return;
        }
    }
    // No file, or one that does not do: the built-in one, if there is.
    if (entry.from_file != 0) drop(base, entry);
    if (entry.picture == null and slot < built_in.len) {
        entry.picture = _picture.make(base, built_in[slot]) catch null;
    }
}

/// The default `slot` taken from the file `name`, which `fib` describes:
/// whether it did. A file of another kind does not.
fn readFile(base: *IconBase, slot: usize, name: [*:0]const u8, fib: *const dos.FileInfoBlock) bool {
    const sys = base.sys_base;
    const read = _object.readWhole(base, name);
    const bytes = switch (read) {
        .got => |got| got,
        .failed => return false,
    };
    defer sys.FreeVec(bytes.ptr);
    const fields = (iconfile.fieldsOf(bytes) catch return false) orelse "";
    if (_object.kindIn(fields)) |kind| {
        if (kind != kindOfSlot(slot)) return false;
    }
    const picture = _picture.make(base, bytes) catch return false;
    var copy: ?[*]u8 = null;
    if (fields.len > 0) {
        const memory = sys.AllocVec(fields.len, exec.MEMF_ANY) orelse {
            _picture.release(base, picture);
            return false;
        };
        copy = @ptrCast(memory);
        @memcpy(copy.?[0..fields.len], fields);
    }
    const entry = &base.defaults[slot];
    drop(base, entry);
    entry.* = .{
        .picture = picture,
        .fields = copy,
        .fields_length = @intCast(fields.len),
        .from_file = 1,
        .date = fib.date,
        .size = fib.size,
    };
    return true;
}

/// A default let go of: its picture, its fields.
fn drop(base: *IconBase, entry: *Default) void {
    if (entry.picture) |picture| _picture.release(base, picture);
    if (entry.fields) |text| base.sys_base.FreeVec(text);
    entry.* = .{};
}

/// `ENV:Sys/def_<name>.info` and the like, into `into`.
pub fn pathOf(into: *[64]u8, head: []const u8, name: []const u8, tail: []const u8) [*:0]const u8 {
    var at: usize = 0;
    for ([_][]const u8{ head, name, tail }) |part| {
        @memcpy(into[at..][0..part.len], part);
        at += part.len;
    }
    into[at] = 0;
    return @ptrCast(into);
}

/// No requester for the caller's process while `ENV:` is looked at: what
/// it had before.
fn quiet(base: *IconBase) ?*anyopaque {
    const task = base.sys_base.FindTask(null) orelse return null;
    if (task.node.type != .process) return null;
    const process: *dos.Process = @ptrCast(task);
    const old = process.window_ptr;
    process.window_ptr = @ptrFromInt(~@as(usize, 0));
    return old;
}

fn loud(base: *IconBase, old: ?*anyopaque) void {
    const task = base.sys_base.FindTask(null) orelse return;
    if (task.node.type != .process) return;
    const process: *dos.Process = @ptrCast(task);
    process.window_ptr = old;
}
