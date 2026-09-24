// SPDX-License-Identifier: MPL-2.0
//! rtg.library's ROM tag, and the init routine it names.
//!
//! The tag is a cold-start, auto-init resident; exec builds the library
//! from the InitTable - the jump table is rtg_lvo.zig's - and calls
//! `init`, which opens utility.library and sets up the lists and locks.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const ExecBase = sdk.interface.exec.ExecBase;
const rtg_lvo = @import("rtg_lvo.zig");
const RtgBase = @import("rtg_base.zig").RtgBase;

pub const LIBRARY_NAME = rtg.RTGNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "17.9.2026";
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The utility.library version the tag calls need.
const UTILITY_VERSION = 1;

/// The base around the Library header exec made.
///
/// INPUTS:
/// - `lib` - the Library header.
fn rtgBase(lib: *exec.Library) *RtgBase {
    return @fieldParentPtr("lib", lib);
}

/// LibInit: exec has copied the tag's name, version and ID string into the
/// base. Without utility.library there is no rtg.library - the tag lists
/// are how a board is configured, and they are utility's.
///
/// INPUTS:
/// - `lib` - the library as exec made it.
/// - `seg_list` - unused; a ROM module has none.
/// - `sys_base` - exec, kept in the base.
///
/// RESULT:
/// The library, or null if utility.library could not be opened.
///
/// CONTEXT:
/// Runs on the exec task at cold start, with multitasking live and no
/// Forbid held.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const rb = rtgBase(lib);
    lib.revision = LIBRARY_REVISION;
    rb.sys_base = sys_base;
    rb.utility_base = @ptrCast(sys_base.OpenLibrary(sdk.interface.utility.NAME, UTILITY_VERSION) orelse return null);
    rb.last_error = rtg.errors.RTGERR_OK;
    rb.board_serial = 0;
    sys_base.NewList(&rb.drivers);
    sys_base.NewList(&rb.boards);
    sys_base.NewList(&rb.transports);
    sys_base.InitSemaphore(&rb.driver_lock);
    sys_base.InitSemaphore(&rb.board_lock);
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(RtgBase),
    .vectors = &rtg_lvo.vectors,
    .vector_count = rtg_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 24: after utility.library (103), which it opens, and
/// after the resources a driver needs (dma 70, i2c 35, expander 30), and
/// before any driver, which opens this.
pub export const rtg_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rtg_library_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 24,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
