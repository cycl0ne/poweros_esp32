// SPDX-License-Identifier: MIT
//! http.library's ROM tag, its init and its Expunge. Open and Close are
//! exec's standard ones: every opener shares the one base.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const http = sdk.http;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("http_base.zig");
const HttpBase = _base.HttpBase;
const http_lvo = @import("http_lvo.zig");

pub const LIBRARY_NAME = http.HTTPNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 1;
const BUILD_DATE = "26.10.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";
/// What a client sends as its User-Agent unless told otherwise.
pub const USER_AGENT = "PowerOS-http.library/" ++ std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION });

/// The base filled in: utility.library opened, the semaphore made.
/// Without utility.library, no library: null, and exec frees the base.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base = _base.httpBase(lib);
    const header = lib.*;
    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, 0) orelse return null;
    base.* = .{
        .lib = header,
        .sys_base = sys_base,
        .seg_list = seg_list,
        .utility_base = @ptrCast(utility_lib),
    };
    sys_base.InitSemaphore(&base.lock);
    lib.revision = LIBRARY_REVISION;
    return lib;
}

/// The library goes when nobody has it open: the libraries it opened
/// closed, the base freed, and the file it was loaded from handed back.
/// A client still about is its program's to delete, and a program that
/// has the library open keeps it.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const base = _base.httpBase(lib);
    const sys = base.sys_base;
    const seg_list = base.seg_list;
    if (base.tls_base) |library| sys.CloseLibrary(library.lib());
    if (base.compression_base) |library| sys.CloseLibrary(library.lib());
    sys.CloseLibrary(@ptrCast(@alignCast(base.utility_base)));
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(HttpBase),
    .vectors = &http_lvo.vectors,
    .vector_count = http_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it - ramlib loads the file and hands this tag to
/// InitResident. In `.resident`, which program.ld KEEPs.
pub export const http_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &http_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
