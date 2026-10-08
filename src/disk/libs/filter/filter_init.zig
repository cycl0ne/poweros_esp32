// SPDX-License-Identifier: MIT
//! filter.library's ROM tag, its init and its Expunge. Open and Close are
//! exec's standard ones: every opener shares the one base.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const filter = sdk.filter;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("filter_base.zig");
const FilterBase = _base.FilterBase;
const filter_lvo = @import("filter_lvo.zig");
const _hook = @import("hook/_hook.zig");

pub const LIBRARY_NAME = filter.FILTERNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "08.10.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base filled in: utility.library and timer.device opened, the lock
/// and the hooks made. Without utility.library, no library: null, and exec
/// frees the base; without timer.device (the host tests), the time is the
/// test's.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base = _base.filterBase(lib);
    const header = lib.*;
    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    base.* = .{
        .lib = header,
        .sys_base = sys_base,
        .seg_list = seg_list,
        .utility_base = @ptrCast(utility_lib),
    };
    base.clock.node.message.length = @sizeOf(timer.TimeRequest);
    base.clock_open = @intFromBool(sys_base.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.clock.node, 0) == 0);
    sys_base.InitLock(&base.lock, LIBRARY_NAME, exec.LOCKORDER_DRIVER, 0);
    _hook.make(base);
    lib.revision = LIBRARY_REVISION;
    return lib;
}

/// The library goes when nobody has it open and no rules are in force:
/// while they are, bsdsocket.library calls its code. Then utility.library
/// and timer.device are closed, the base freed, and the file it was
/// loaded from handed back.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const base = _base.filterBase(lib);
    if (lib.open_cnt != 0 or base.hooked != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const sys = base.sys_base;
    const seg_list = base.seg_list;
    if (base.clock_open != 0) sys.CloseDevice(&base.clock.node);
    sys.CloseLibrary(@ptrCast(@alignCast(base.utility_base)));
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(FilterBase),
    .vectors = &filter_lvo.vectors,
    .vector_count = filter_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it. In `.resident`, which program.ld KEEPs.
pub export const filter_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &filter_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
