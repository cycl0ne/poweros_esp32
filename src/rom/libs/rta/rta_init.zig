// SPDX-License-Identifier: MPL-2.0
//! rta.library's ROM tag, and the init routine it names.
//!
//! The tag is a cold-start, auto-init resident; exec builds the library
//! from the InitTable - the jump table is rta_lvo.zig's - and calls
//! `init`, which opens utility.library and sets up the lists and locks.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const ExecBase = sdk.interface.exec.ExecBase;
const rta_lvo = @import("rta_lvo.zig");
const RtaBase = @import("rta_base.zig").RtaBase;

pub const LIBRARY_NAME = rta.RTANAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 5;
const BUILD_DATE = "20.10.2026";
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
fn rtaBase(lib: *exec.Library) *RtaBase {
    return @fieldParentPtr("lib", lib);
}

/// LibInit: exec has copied the tag's name, version and ID string into the
/// base. Without utility.library there is no rta.library - a sink is made
/// from a tag list, and tag lists are utility's.
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
/// Runs on the exec task at cold start, with multitasking started.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const rb = rtaBase(lib);
    lib.revision = LIBRARY_REVISION;
    rb.sys_base = sys_base;
    rb.utility_base = @ptrCast(sys_base.OpenLibrary(sdk.interface.utility.NAME, UTILITY_VERSION) orelse return null);
    rb.last_error = rta.errors.RTAERR_OK;
    rb.serial = 0;
    sys_base.NewList(&rb.drivers);
    sys_base.NewList(&rb.sinks);
    sys_base.NewList(&rb.transports);
    sys_base.NewList(&rb.sources);
    sys_base.InitSemaphore(&rb.driver_lock);
    sys_base.InitSemaphore(&rb.sink_lock);
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(RtaBase),
    .vectors = &rta_lvo.vectors,
    .vector_count = rta_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 33: after utility.library (103) and expansion.library
/// (102), and before the sound drivers (31, 32), which join it at their
/// own init and make their sinks and sources there, and before
/// audio.device (26), which plays through them and records from them.
pub export const rta_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rta_library_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 33,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
