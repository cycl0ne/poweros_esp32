// SPDX-License-Identifier: MPL-2.0
//! utility.library's ROM tag, and the init routine it names.
//!
//! The tag is a cold-start, auto-init resident at priority 103, so the
//! library is made before the other cold-start residents that use it.
//! exec builds it from the InitTable - the jump table is utility_lvo.zig's
//! - and calls `init`, which keeps SysBase and makes the root name space.
//! The library never goes: its Expunge refuses.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility_lvo = @import("utility_lvo.zig");

const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = @import("utility_base.zig").UtilityBase;
const TagItem = sdk.utility.TagItem;
const ANO_NameSpace = sdk.utility.ANO_NameSpace;

/// What the library is on exec's list as, and what `OpenLibrary` finds it by.
pub const LIBRARY_NAME = "utility.library";
/// The version programs ask `OpenLibrary` for.
const LIBRARY_VERSION = 1;
/// The revision within the version, set by `init`.
const LIBRARY_REVISION = 0;
const BUILD_DATE = "15.9.2026";
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// Init: keeps SysBase and makes the root name space, a named object with
/// an empty name and a name space.
///
/// INPUTS:
/// - `lib` - the library as exec made it, with the tag's name, version and
///   ID string copied in.
/// - `seg_list` - unused; a ROM module has none.
/// - `sys_base` - exec, kept in the base and called through for the life of
///   the library.
///
/// RESULT:
/// The library, or null without memory for the root name space.
///
/// CONTEXT:
/// Runs on the exec task at cold start, with multitasking live and no
/// Forbid held. The jump table exists already, so the root name space is
/// made through it.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const ub: *UtilityBase = @fieldParentPtr("lib", lib);
    lib.revision = LIBRARY_REVISION;
    ub.sys_base = sys_base;
    ub.wild_star = false;
    const tags = [_]TagItem{ .{ .tag = ANO_NameSpace, .data = 1 }, .{} };
    ub.master_space = ub.iface().AllocNamedObjectA("", &tags) orelse return null;
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(UtilityBase),
    .vectors = &utility_lvo.vectors,
    .vector_count = utility_lvo.vectors.len,
    .init = &init,
};

/// The ROM tag: a cold-start, auto-init library at priority 103.
pub export const utility_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &utility_library_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 103,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
