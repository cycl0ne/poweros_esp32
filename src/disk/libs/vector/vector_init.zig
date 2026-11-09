// SPDX-License-Identifier: MIT
//! vector.library's ROM tag, its init and its Expunge. Open and Close are
//! exec's standard ones: every opener shares the one base.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("vector_base.zig");
const VectorBase = _base.VectorBase;
const vector_lvo = @import("vector_lvo.zig");

pub const LIBRARY_NAME = sdk.vector.VECTORNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "09.11.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const vb = _base.vectorBase(lib);
    const header = lib.*;
    vb.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list };
    lib.revision = LIBRARY_REVISION;
    return lib;
}

fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const vb = _base.vectorBase(lib);
    const sys = vb.sys_base;
    const seg_list = vb.seg_list;
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(VectorBase),
    .vectors = &vector_lvo.vectors,
    .vector_count = vector_lvo.vectors.len,
    .init = &init,
};

pub export const vector_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &vector_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
