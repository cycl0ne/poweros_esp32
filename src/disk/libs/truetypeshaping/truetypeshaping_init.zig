// SPDX-License-Identifier: MIT
//! truetypeshaping.library's ROM tag, its init and its Expunge. Open and
//! Close are exec's standard ones: every opener shares the one base. The
//! init opens truetype.library for the base - revision 4 of it, the
//! first that hands out a font's tables - and fails without it; Expunge
//! closes it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;
const _base = @import("truetypeshaping_base.zig");
const TrueTypeShapingBase = _base.TrueTypeShapingBase;
const truetypeshaping_lvo = @import("truetypeshaping_lvo.zig");

pub const LIBRARY_NAME = sdk.truetypeshaping.TRUETYPESHAPINGNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "11.11.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The revision of truetype.library 1 that has `FontTable`.
const table_revision = 4;

fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const sb = _base.trueTypeShapingBase(lib);
    const opened = sys_base.OpenLibrary(sdk.interface.truetype.NAME, sdk.truetype.TRUETYPE_VERSION) orelse return null;
    if (opened.version == sdk.truetype.TRUETYPE_VERSION and opened.revision < table_revision) {
        sys_base.CloseLibrary(opened);
        return null;
    }
    const truetype_base: *TrueTypeBase = @ptrCast(@alignCast(opened));
    const header = lib.*;
    sb.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list, .truetype_base = truetype_base };
    lib.revision = LIBRARY_REVISION;
    return lib;
}

fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const sb = _base.trueTypeShapingBase(lib);
    const sys = sb.sys_base;
    const seg_list = sb.seg_list;
    sys.CloseLibrary(sb.truetype_base.lib());
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(TrueTypeShapingBase),
    .vectors = &truetypeshaping_lvo.vectors,
    .vector_count = truetypeshaping_lvo.vectors.len,
    .init = &init,
};

pub export const truetypeshaping_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &truetypeshaping_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
