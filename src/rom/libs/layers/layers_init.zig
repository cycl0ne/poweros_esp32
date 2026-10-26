// SPDX-License-Identifier: MPL-2.0
//! layers.library's ROM tag, and the init routine it names.
//!
//! The tag is a cold-start, auto-init resident at priority 19, under
//! graphics.library, which the init opens along with utility.library and
//! rtg.library.
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
/// 6: a composed LayerInfo - NewLayerInfoTagList, LATAG_Compose.
/// 7: a layer's RastPort carries the layer's lock (RPTAG_Lock), so every
/// drawing call through it holds the layer while it draws; a picture
/// shown over part of a composed layer, not copied into it
/// (ShowLayerPicture, LATAG_GetComposed).
/// 9: a drawing in a composed layer is handed on to the board once, as
/// the box around the pieces it is seen in, not once for each piece.
/// 10: a shadow's top and bottom darkened a strip of 64 columns at a
/// time, not a row at a time.
/// 11: the pieces of a composed layer copied on to the display as one job
/// of the board's engine (rtg's CopyRects), not one a piece.
/// 12: a composed layer with no buffer of its own (LATAG_NoBuffer), only
/// what its backfill paints wherever it is seen; InstallLayerHook shows
/// it again.
/// 13: RefillLayer - part of a layer painted again by its backfill, for a
/// program whose hook paints what it shows.
pub const LIBRARY_REVISION = 13;

/// dd.mm.yyyy, the form every module's `$VER:` string uses.
const BUILD_DATE = "26.10.2026";

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
/// The library, or null if utility.library, graphics.library or
/// rtg.library could not be opened.
///
/// CONTEXT:
/// Runs on the exec task at cold start, with multitasking started.
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
    const rtg_lib = sys_base.OpenLibrary(sdk.rtg.RTGNAME, sdk.rtg.RTG_VERSION) orelse {
        sys_base.CloseLibrary(graphics_lib);
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    lb.utility_base = @ptrCast(utility_lib);
    lb.graphics_base = @ptrCast(graphics_lib);
    lb.rtg_base = @ptrCast(rtg_lib);
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(LayersBase),
    .vectors = &layers_lvo.vectors,
    .vector_count = layers_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 19: under graphics.library (20) and rtg.library (24),
/// which it opens, and so under rtg's drivers as well.
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
