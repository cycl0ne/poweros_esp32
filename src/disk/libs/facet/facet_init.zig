// SPDX-License-Identifier: MIT
//! facet.library's ROM tag, its init and its Expunge. Open and Close are
//! exec's standard ones: every opener shares the one base.
//!
//! The init only fills in the base: what draws is described when a
//! program makes an instance, and everything else is made by the program
//! from that. The library goes when nobody has it open and no instance is
//! left: a device's queue runs the library's code on a task of its own,
//! which may outlast the program's hold on the library.

const std = @import("std");
const facet_version = @import("facet_version.zig");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("facet_base.zig");
const FacetBase = _base.FacetBase;
const facet_lvo = @import("facet_lvo.zig");

pub const LIBRARY_NAME = facet.FACETNAME;
pub const LIBRARY_VERSION = facet_version.LIBRARY_VERSION;
pub const LIBRARY_REVISION = facet_version.LIBRARY_REVISION;
const BUILD_DATE = "03.11.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base filled in.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base = _base.facetBase(lib);
    const header = lib.*;
    base.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list };
    sys_base.InitSemaphore(&base.v3d_lock);
    sys_base.InitSemaphore(&base.modules_lock);
    base.clock.node.message.length = @sizeOf(timer.TimeRequest);
    base.clock_open = sys_base.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.clock.node, 0) == 0;
    lib.revision = LIBRARY_REVISION;
    return lib;
}

/// The library goes when nobody has it open and every instance is gone:
/// the base freed, and the file it was loaded from handed back.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const base = _base.facetBase(lib);
    if (lib.open_cnt != 0 or @atomicLoad(u32, &base.instances, .monotonic) != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const sys = base.sys_base;
    const seg_list = base.seg_list;
    for (base.modules[0..base.module_count]) |module| sys.CloseLibrary(module.?);
    if (base.clock_open) sys.CloseDevice(&base.clock.node);
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(FacetBase),
    .vectors = &facet_lvo.vectors,
    .vector_count = facet_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it - ramlib loads the file and hands this tag to
/// InitResident. In `.resident`, which program.ld KEEPs.
pub export const facet_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &facet_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
