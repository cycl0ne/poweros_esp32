// SPDX-License-Identifier: MPL-2.0
//! layers.library's ROM tag, and the init routine it names.
//!
//! The tag is a cold-start, auto-init resident at priority 19, under
//! graphics.library, which the init opens along with utility.library.
//! exec builds the library from the InitTable - the jump table is
//! layers_lvo.zig's - and calls `init`.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const layers = sdk.layers;
const ExecBase = sdk.interface.exec.ExecBase;
const layers_lvo = @import("layers_lvo.zig");
const LayersBase = @import("layers_base.zig").LayersBase;

/// The version of utility.library the tag calls are taken from.
const UTILITY_VERSION = 1;

/// The name it is opened by, and the name in its ROM tag and on exec's
/// library list. The SDK's, so a caller and the library cannot disagree.
pub const LIBRARY_NAME = layers.LAYERSNAME;

/// What a caller passes to OpenLibrary. 0 while the simple refresh is all
/// there is: a caller that needs more asks for the version that brought
/// it.
pub const LIBRARY_VERSION = 0;

/// The build within the version. Set into the base by `init`, since exec
/// copies only the tag's name, version and ID string.
pub const LIBRARY_REVISION = 1;

/// dd.mm.yyyy, the form every module's `$VER:` string uses.
const BUILD_DATE = "18.9.2026";

/// The `$VER:` string, NUL first so a scan of the image finds it.
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base around the Library header exec made.
///
/// INPUTS:
/// - `lib` - the Library header exec made.
fn layersBase(lib: *exec.Library) *LayersBase {
    return @fieldParentPtr("lib", lib);
}

/// Open the libraries this one is built on and keep them.
///
/// It opens no display and makes no LayerInfo: at cold start there may be
/// no board yet, and a machine with no display should still be able to
/// have this library on the list.
///
/// INPUTS:
/// - `lib` - the library as exec made it.
/// - `seg_list` - unused; a ROM module has none.
/// - `sys_base` - exec, kept in the base.
///
/// RESULT:
/// The library, or null if utility.library or graphics.library could not
/// be opened.
///
/// CONTEXT:
/// Runs on the exec task at cold start, with multitasking live and no
/// Forbid held.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const lb = layersBase(lib);
    lib.revision = LIBRARY_REVISION;
    lb.sys_base = sys_base;

    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, UTILITY_VERSION) orelse
        return null;
    const graphics_lib = sys_base.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse {
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    lb.utility_base = @ptrCast(utility_lib);
    lb.graphics_base = @ptrCast(graphics_lib);
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(LayersBase),
    .vectors = &layers_lvo.vectors,
    .vector_count = layers_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 19: under graphics.library (20), which it opens, and so
/// under rtg.library (24) and its drivers as well.
pub export const layers_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &layers_library_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 19,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
