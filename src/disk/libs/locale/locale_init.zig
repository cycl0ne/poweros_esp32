// SPDX-License-Identifier: MIT
//! locale.library's ROM tag, its init, its Open and its Expunge.
//!
//! The library opens dos.library and utility.library when it is first
//! opened itself: every file is read through dos, and the hooks, the
//! calendar and the settings' pairs are utility's. Its own locale is made
//! at init, and is the default until SetDefaultLocale names another.
//!
//! Expunge gives back the catalogs no one holds - that is what it is
//! asked for when memory runs short - and the library itself only when it
//! is not open and has not stood in front of dos's calls: once it has,
//! dos calls into its code, and it holds itself open for good.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("locale_base.zig");
const LocaleBase = _base.LocaleBase;
const locale_lvo = @import("locale_lvo.zig");
const _locale = @import("locale/_locale.zig");
const _catalog = @import("catalog/_catalog.zig");

pub const LIBRARY_NAME = sdk.locale.LOCALENAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "29.10.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const lb = _base.localeBase(lib);
    const header = lib.*;
    lb.* = .{
        .lib = header,
        .sys_base = sys_base,
        .seg_list = seg_list,
        .dos_base = undefined,
        .utility_base = undefined,
        .default_locale = &lb.builtin,
        .builtin = .{ .public = undefined },
    };
    sys_base.InitSemaphore(&lb.lock);
    lb.catalogs.init(.unknown);
    _locale.makeBuiltin(&lb.builtin);
    lib.revision = LIBRARY_REVISION;
    return lib;
}

fn open(lib: *exec.Library) callconv(.c) ?*exec.Library {
    const lb = _base.localeBase(lib);
    const sys = lb.sys_base;
    if (lib.open_cnt == 0) {
        const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return null;
        const util_lib = sys.OpenLibrary(utility.UTILITYNAME, 0) orelse {
            sys.CloseLibrary(dos_lib);
            return null;
        };
        lb.dos_base = @ptrCast(dos_lib);
        lb.utility_base = @ptrCast(util_lib);
    }
    lib.open_cnt += 1;
    lib.flags &= ~exec.LIBF_DELEXP;
    return lib;
}

fn close(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const lb = _base.localeBase(lib);
    const sys = lb.sys_base;
    if (lib.open_cnt != 0) lib.open_cnt -= 1;
    if (lib.open_cnt != 0) return null;
    sys.CloseLibrary(@ptrCast(@alignCast(lb.utility_base)));
    sys.CloseLibrary(@ptrCast(@alignCast(lb.dos_base)));
    // A delayed expunge is CloseLibrary's, once this has answered.
    return null;
}

fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const lb = _base.localeBase(lib);
    _catalog.flush(lb);
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const sys = lb.sys_base;
    // The default is the library's to give back with it.
    if (!lb.default_locale.builtin) sys.FreeVec(lb.default_locale);
    const seg_list = lb.seg_list;
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const openVector = open;
pub const closeVector = close;
pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(LocaleBase),
    .vectors = &locale_lvo.vectors,
    .vector_count = locale_lvo.vectors.len,
    .init = &init,
};

pub export const locale_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &locale_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
