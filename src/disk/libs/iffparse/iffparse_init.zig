// SPDX-License-Identifier: MIT
//! iffparse.library's ROM tag, its init, its Open and its Expunge.
//!
//! The library opens dos.library and utility.library when it is first
//! opened itself: the file stream reads and writes through dos, and
//! every hook is called through utility. clipboard.device is not opened
//! here, because only a program that asks for the clipboard needs it,
//! and `OpenClipboard` opens it per handle.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;
const iffparse_lvo = @import("iffparse_lvo.zig");

pub const LIBRARY_NAME = sdk.iffparse.IFFPARSENAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "29.09.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const ib = _base.iffBase(lib);
    const header = lib.*;
    ib.* = .{
        .lib = header,
        .sys_base = sys_base,
        .seg_list = seg_list,
        .dos_base = undefined,
        .utility_base = undefined,
    };
    lib.revision = LIBRARY_REVISION;
    return lib;
}

fn open(lib: *exec.Library) callconv(.c) ?*exec.Library {
    const ib = _base.iffBase(lib);
    const sys = ib.sys_base;
    if (lib.open_cnt == 0) {
        const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return null;
        const util_lib = sys.OpenLibrary(utility.UTILITYNAME, 0) orelse {
            sys.CloseLibrary(dos_lib);
            return null;
        };
        ib.dos_base = @ptrCast(dos_lib);
        ib.utility_base = @ptrCast(util_lib);
    }
    lib.open_cnt += 1;
    lib.flags &= ~exec.LIBF_DELEXP;
    return lib;
}

fn close(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const ib = _base.iffBase(lib);
    const sys = ib.sys_base;
    if (lib.open_cnt != 0) lib.open_cnt -= 1;
    if (lib.open_cnt != 0) return null;
    sys.CloseLibrary(@ptrCast(@alignCast(ib.utility_base)));
    sys.CloseLibrary(@ptrCast(@alignCast(ib.dos_base)));
    if (lib.flags & exec.LIBF_DELEXP == 0) return null;
    return expunge(lib);
}

fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const ib = _base.iffBase(lib);
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const sys = ib.sys_base;
    const seg_list = ib.seg_list;
    if (lib.node.pred != null) sys.Remove(&lib.node);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const openVector = open;
pub const closeVector = close;
pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(IFFParseBase),
    .vectors = &iffparse_lvo.vectors,
    .vector_count = iffparse_lvo.vectors.len,
    .init = &init,
};

pub export const iffparse_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &iffparse_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
