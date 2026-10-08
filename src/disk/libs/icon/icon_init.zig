// SPDX-License-Identifier: MIT
//! icon.library's ROM tag, its init and its Expunge. Open and Close are
//! exec's standard ones: every opener shares the one base.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const icon = sdk.icon;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("icon_base.zig");
const IconBase = _base.IconBase;
const icon_lvo = @import("icon_lvo.zig");
const _default = @import("default/_default.zig");

pub const LIBRARY_NAME = icon.ICONNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "08.10.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base filled in: dos.library opened, the semaphore and the lock
/// made. Without dos.library, no library: null, and exec frees the base.
/// Nothing is read yet: a default is read when it is first asked for.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base = _base.iconBase(lib);
    const header = lib.*;
    const dos_lib = sys_base.OpenLibrary(sdk.interface.dos.NAME, 0) orelse return null;
    base.* = .{
        .lib = header,
        .sys_base = sys_base,
        .seg_list = seg_list,
        .dos_base = @ptrCast(dos_lib),
    };
    sys_base.InitSemaphore(&base.defaults_lock);
    sys_base.InitLock(&base.users_lock, LIBRARY_NAME, exec.LOCKORDER_DRIVER, 0);
    lib.revision = LIBRARY_REVISION;
    return lib;
}

/// The library goes when nobody has it open. The defaults it kept are
/// let go of - an icon a program still held would keep its picture, but
/// a program that has closed the library has given its icons back - and
/// datatypes.library and dos.library closed, the base freed, the file it
/// was loaded from handed back.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const base = _base.iconBase(lib);
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const sys = base.sys_base;
    const seg_list = base.seg_list;
    _default.forgetAll(base);
    if (base.datatypes_base) |dt| sys.CloseLibrary(@ptrCast(@alignCast(dt)));
    sys.CloseLibrary(@ptrCast(@alignCast(base.dos_base)));
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(IconBase),
    .vectors = &icon_lvo.vectors,
    .vector_count = icon_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it. In `.resident`, which program.ld KEEPs.
pub export const icon_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &icon_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
