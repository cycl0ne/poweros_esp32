// SPDX-License-Identifier: MIT
//! What the icon calls share: an icon made in one block from the text of
//! its fields and its picture, the name of an icon's file, a file read
//! whole, and what kind of thing a name is.
//!
//! **An icon is one block**: `Made` - the picture it holds, the
//! `DiskObject`, a `DrawerData` - then the tool type array, then the
//! strings. `FreeDiskObject` frees the block and lets go of the picture,
//! whatever the program has pointed the fields at meanwhile.
//!
//! **What a name is**, for an icon file without a KIND and for a file
//! without an icon: a volume's root is a disk, any other directory a
//! drawer; a file is a tool when its protection lets it run and it
//! starts as a program does (`PSG1`, what LoadSeg loads), a script when
//! its script bit is set, and anything else a project.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const iconfile = icon.file;
const IconBase = @import("../icon_base.zig").IconBase;
const _picture = @import("../picture/_picture.zig");
const Picture = _picture.Picture;

/// The block an icon is made in, up to its tool types and strings.
pub const Made = extern struct {
    picture: ?*Picture = null,
    object: icon.DiskObject = .{},
    drawer: icon.DrawerData = .{},
};

/// The block an icon the library made is in.
pub fn madeOf(object: *icon.DiskObject) *Made {
    return @fieldParentPtr("object", object);
}

/// The largest icon file read: a picture of `PICTURE_MAX` pixels each way,
/// unpacked, and room over.
const FILE_MAX = 512 * 1024;

/// An icon of `kind` from the text of its fields and its picture, whose
/// user it becomes. Null without the memory, with IoErr saying so and the
/// picture let go of.
pub fn make(base: *IconBase, fields: []const u8, kind: u32, picture: ?*Picture) ?*icon.DiskObject {
    const sys = base.sys_base;
    var types: usize = 0;
    var string_bytes: usize = 0;
    var walk = iconfile.Fields{ .text = fields };
    while (walk.next()) |field| switch (field.key) {
        .tool => string_bytes += field.value.len + 1,
        .type => {
            types += 1;
            string_bytes += field.value.len + 1;
        },
        else => {},
    };

    const array_at = @sizeOf(Made);
    const strings_at = array_at + if (types > 0) (types + 1) * @sizeOf(?[*:0]const u8) else 0;
    const memory = sys.AllocVec(strings_at + string_bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        if (picture) |held| _picture.release(base, held);
        _ = base.dos_base.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    const bytes: [*]u8 = @ptrCast(memory);
    const made: *Made = @ptrCast(@alignCast(memory));
    made.* = .{ .picture = picture };
    const object = &made.object;
    object.kind = kind;
    if (picture) |held| object.image = &held.image;
    if (kind == icon.WBDISK or kind == icon.WBDRAWER or kind == icon.WBGARBAGE) object.drawer_data = &made.drawer;

    const array: [*]?[*:0]const u8 = @ptrCast(@alignCast(bytes + array_at));
    var strings = Strings{ .bytes = bytes + strings_at };
    var type_at: usize = 0;
    walk = .{ .text = fields };
    while (walk.next()) |field| switch (field.key) {
        .kind => {},
        .at => if (iconfile.numbers(2, field.value)) |place| {
            object.current_x = place[0];
            object.current_y = place[1];
        },
        .tool => object.default_tool = if (field.value.len == 0) null else strings.copy(field.value),
        .type => {
            array[type_at] = strings.copy(field.value);
            type_at += 1;
        },
        .stack => if (iconfile.number(field.value)) |size| {
            if (size > 0) object.stack_size = @intCast(size);
        },
        .window => if (iconfile.numbers(4, field.value)) |box| {
            made.drawer.left = box[0];
            made.drawer.top = box[1];
            made.drawer.width = box[2];
            made.drawer.height = box[3];
        },
        .scroll => if (iconfile.numbers(2, field.value)) |offset| {
            made.drawer.current_x = offset[0];
            made.drawer.current_y = offset[1];
        },
        .view => if (iconfile.viewOf(field.value)) |view| {
            made.drawer.view_modes = view;
        },
        .show => if (iconfile.showOf(field.value)) |show| {
            made.drawer.flags = show;
        },
    };
    if (types > 0) {
        array[types] = null;
        object.tool_types = array;
    }
    return object;
}

const Strings = struct {
    bytes: [*]u8,
    at: usize = 0,

    fn copy(strings: *Strings, value: []const u8) [*:0]const u8 {
        const start = strings.bytes + strings.at;
        @memcpy(start[0..value.len], value);
        start[value.len] = 0;
        strings.at += value.len + 1;
        return @ptrCast(start);
    }
};

/// The kind the fields say, when they say one.
pub fn kindIn(fields: []const u8) ?u32 {
    var walk = iconfile.Fields{ .text = fields };
    while (walk.next()) |field| {
        if (field.key == .kind) return iconfile.kindOf(field.value);
    }
    return null;
}

/// The name of `name`'s icon file, in memory the caller frees with
/// FreeVec: `<name>.info`, and `<volume>:Disk.info` for a name that is a
/// volume, a device or an assign. Null when the name is too long for
/// one, or without the memory, with IoErr saying which.
pub fn infoName(base: *IconBase, name: [*:0]const u8) ?[*:0]u8 {
    const sys = base.sys_base;
    const dl = base.dos_base;
    var length: usize = 0;
    while (name[length] != 0) length += 1;
    const part = dl.FilePart(name);
    var part_length: usize = 0;
    while (part[part_length] != 0) part_length += 1;
    if (part_length > icon.ICON_NAME_MAX) {
        _ = dl.SetIoErr(dos.ERROR_INVALID_COMPONENT_NAME);
        return null;
    }
    const tail: []const u8 = if (length > 0 and name[length - 1] == ':') "Disk.info" else ".info";
    const memory = sys.AllocVec(length + tail.len + 1, exec.MEMF_ANY) orelse {
        _ = dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    const into: [*]u8 = @ptrCast(memory);
    @memcpy(into[0..length], name[0..length]);
    @memcpy(into[length..][0..tail.len], tail);
    into[length + tail.len] = 0;
    return @ptrCast(into);
}

/// What reading a file whole came to.
pub const Read = union(enum) {
    /// The bytes, in memory the caller frees with FreeVec.
    got: []u8,
    /// Why not, as IoErr says it.
    failed: i32,
};

/// The file `path` read whole.
pub fn readWhole(base: *IconBase, path: [*:0]const u8) Read {
    const sys = base.sys_base;
    const dl = base.dos_base;
    const file = dl.Open(path, dos.MODE_OLDFILE) orelse return .{ .failed = dl.IoErr() };
    defer _ = dl.Close(file);
    // A seek answers where the file was, so the size is what the seek
    // back to the beginning hands over.
    if (dl.Seek(file, 0, dos.OFFSET_END) < 0) return .{ .failed = dl.IoErr() };
    const size = dl.Seek(file, 0, dos.OFFSET_BEGINNING);
    if (size <= 0) return .{ .failed = dos.ERROR_OBJECT_WRONG_TYPE };
    if (size > FILE_MAX) return .{ .failed = dos.ERROR_OBJECT_TOO_LARGE };
    const length: usize = @intCast(size);
    const memory = sys.AllocVec(length, exec.MEMF_ANY) orelse return .{ .failed = dos.ERROR_NO_FREE_STORE };
    const bytes: [*]u8 = @ptrCast(memory);
    if (dl.Read(file, bytes, size) != size) {
        const failure = dl.IoErr();
        sys.FreeVec(memory);
        return .{ .failed = if (failure != 0) failure else dos.ERROR_OBJECT_WRONG_TYPE };
    }
    return .{ .got = bytes[0..length] };
}

/// What a name is, for its icon.
pub const Nature = enum { disk, drawer, tool, script, project };

/// What `name` is; null when there is no such thing.
pub fn natureOf(base: *IconBase, name: [*:0]const u8) ?Nature {
    const sys = base.sys_base;
    const dl = base.dos_base;
    const lock = dl.Lock(name, dos.SHARED_LOCK) orelse return null;
    defer dl.UnLock(lock);
    const memory = sys.AllocVec(@sizeOf(dos.FileInfoBlock), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    defer sys.FreeVec(memory);
    const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(memory));
    if (!dl.Examine(lock, fib)) return null;
    if (fib.dir_entry_type > 0) {
        const parent = dl.ParentDir(lock) orelse return .disk;
        dl.UnLock(parent);
        return .drawer;
    }
    if (fib.protection & dos.FIBF_SCRIPT != 0) return .script;
    if (fib.protection & dos.FIBF_EXECUTE == 0 and startsAsProgram(base, lock)) return .tool;
    return .project;
}

/// Whether the file starts as a program does.
fn startsAsProgram(base: *IconBase, lock: *dos.FileLock) bool {
    const dl = base.dos_base;
    const copy = dl.DupLock(lock) orelse return false;
    const file = dl.OpenFromLock(copy) orelse {
        dl.UnLock(copy);
        return false;
    };
    defer _ = dl.Close(file);
    var start: [4]u8 = undefined;
    if (dl.Read(file, &start, start.len) != start.len) return false;
    return same(&start, &dos.loadfile.MAGIC);
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// The kind an icon of a name of this nature has.
pub fn kindOf(nature: Nature) u32 {
    return switch (nature) {
        .disk => icon.WBDISK,
        .drawer => icon.WBDRAWER,
        .tool => icon.WBTOOL,
        .script, .project => icon.WBPROJECT,
    };
}
