// SPDX-License-Identifier: MIT
//! asl.library's ROM tag, its init, its Open and its Expunge.
//!
//! The library opens what a requester is built from when it is first
//! opened itself - dos, intuition, graphics, utility and the gadget
//! classes - so that a program hears at `OpenLibrary` that a requester
//! cannot be built, rather than at the request. It closes them again when
//! the last opener has gone.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const intuition = sdk.intuition;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("asl_base.zig");
const AslBase = _base.AslBase;
const asl_lvo = @import("asl_lvo.zig");

pub const LIBRARY_NAME = sdk.asl.ASLNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "28.09.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const ab = _base.aslBase(lib);
    const header = lib.*;
    ab.* = .{
        .lib = header,
        .sys_base = sys_base,
        .seg_list = seg_list,
        .dos_base = undefined,
        .intuition_base = undefined,
        .graphics_base = undefined,
        .utility_base = undefined,
    };
    ab.requesters.init();
    lib.revision = LIBRARY_REVISION;
    return lib;
}

/// What the library needs closed again, in the order it opened them.
fn closeAll(ab: *AslBase, how_many: usize) void {
    const sys = ab.sys_base;
    var i = how_many;
    while (i > 0) {
        i -= 1;
        sys.CloseLibrary(ab.classes[i]);
        ab.classes[i] = null;
    }
}

/// The first opener brings up everything a requester is built from.
fn open(lib: *exec.Library) callconv(.c) ?*exec.Library {
    const ab = _base.aslBase(lib);
    const sys = ab.sys_base;
    if (lib.open_cnt == 0) {
        const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return null;
        const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
            sys.CloseLibrary(dos_lib);
            return null;
        };
        const gfx_lib = sys.OpenLibrary(sdk.graphics.GRAPHICSNAME, 0) orelse {
            sys.CloseLibrary(int_lib);
            sys.CloseLibrary(dos_lib);
            return null;
        };
        const util_lib = sys.OpenLibrary(utility.UTILITYNAME, 0) orelse {
            sys.CloseLibrary(gfx_lib);
            sys.CloseLibrary(int_lib);
            sys.CloseLibrary(dos_lib);
            return null;
        };
        ab.dos_base = @ptrCast(dos_lib);
        ab.intuition_base = @ptrCast(int_lib);
        ab.graphics_base = @ptrCast(gfx_lib);
        ab.utility_base = @ptrCast(util_lib);
        for (_base.class_libraries, 0..) |name, i| {
            ab.classes[i] = sys.OpenLibrary(name, 0) orelse {
                closeAll(ab, i);
                sys.CloseLibrary(util_lib);
                sys.CloseLibrary(gfx_lib);
                sys.CloseLibrary(int_lib);
                sys.CloseLibrary(dos_lib);
                return null;
            };
        }
    }
    lib.open_cnt += 1;
    lib.flags &= ~exec.LIBF_DELEXP;
    return lib;
}

/// The last opener lets go of them again.
fn close(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const ab = _base.aslBase(lib);
    const sys = ab.sys_base;
    if (lib.open_cnt != 0) lib.open_cnt -= 1;
    if (lib.open_cnt != 0) return null;
    closeAll(ab, _base.class_libraries.len);
    if (ab.diskfont_base) |df| {
        sys.CloseLibrary(@ptrCast(@alignCast(df)));
        ab.diskfont_base = null;
    }
    sys.CloseLibrary(@ptrCast(@alignCast(ab.utility_base)));
    sys.CloseLibrary(@ptrCast(@alignCast(ab.graphics_base)));
    sys.CloseLibrary(@ptrCast(@alignCast(ab.intuition_base)));
    sys.CloseLibrary(@ptrCast(@alignCast(ab.dos_base)));
    if (lib.flags & exec.LIBF_DELEXP == 0) return null;
    return expunge(lib);
}

fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    // A requester still out points at this base, so it holds the library
    // as surely as an opener does.
    const ab = _base.aslBase(lib);
    if (lib.open_cnt != 0 or !ab.requesters.isEmpty()) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const sys = ab.sys_base;
    const seg_list = ab.seg_list;
    if (lib.node.pred != null) sys.Remove(&lib.node);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const openVector = open;
pub const closeVector = close;
pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(AslBase),
    .vectors = &asl_lvo.vectors,
    .vector_count = asl_lvo.vectors.len,
    .init = &init,
};

pub export const asl_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &asl_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
