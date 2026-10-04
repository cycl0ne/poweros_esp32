// SPDX-License-Identifier: MIT
//! truetype.library's ROM tag, its init and its Expunge. Open and Close
//! are exec's standard ones: every opener shares the one base.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const truetype_lvo = @import("truetype_lvo.zig");

pub const LIBRARY_NAME = sdk.truetype.TRUETYPENAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "28.09.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const tb = _base.trueTypeBase(lib);
    const header = lib.*;
    tb.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list };
    lib.revision = LIBRARY_REVISION;
    return lib;
}

fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const tb = _base.trueTypeBase(lib);
    const sys = tb.sys_base;
    const seg_list = tb.seg_list;
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(TrueTypeBase),
    .vectors = &truetype_lvo.vectors,
    .vector_count = truetype_lvo.vectors.len,
    .init = &init,
};

pub export const truetype_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &truetype_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
