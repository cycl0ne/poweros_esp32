// SPDX-License-Identifier: MIT
//! wpa.library's ROM tag, its init and its Expunge. Open and Close are
//! exec's standard ones: every opener shares the one base, and each
//! handshake is its maker's own.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const wpa = sdk.wpa;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("wpa_base.zig");
const WPABase = _base.WPABase;
const wpa_lvo = @import("wpa_lvo.zig");

pub const LIBRARY_NAME = wpa.WPANAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
pub const BUILD_DATE = "14.10.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base filled in and its lock made; the libraries it needs are
/// opened by the first call that needs them, which runs on a process.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base = _base.wpaBase(lib);
    const header = lib.*;
    base.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list };
    lib.revision = LIBRARY_REVISION;
    sys_base.InitSemaphore(&base.lock);
    return lib;
}

/// The library goes when nobody has it open: the libraries closed, the
/// base freed, and the file it was loaded from handed back.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const base = _base.wpaBase(lib);
    const sys = base.sys_base;
    const seg_list = base.seg_list;
    if (base.crypto_base) |library| sys.CloseLibrary(library.lib());
    if (base.utility_base) |library| sys.CloseLibrary(@ptrCast(@alignCast(library)));
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(WPABase),
    .vectors = &wpa_lvo.vectors,
    .vector_count = wpa_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it. In `.resident`, which program.ld KEEPs.
pub export const wpa_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &wpa_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
