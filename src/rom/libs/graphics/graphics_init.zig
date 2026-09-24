// SPDX-License-Identifier: MPL-2.0
//! graphics.library's ROM tag, and the init routine it names.
//!
//! The tag is a cold-start, auto-init resident; exec builds the library
//! from the InitTable - the jump table is graphics_lvo.zig's - and calls
//! `init`, which opens utility.library and rtg.library, makes the region
//! pool, puts the ROM fonts on the list and brings the display up.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const ExecBase = sdk.interface.exec.ExecBase;
const graphics_lvo = @import("graphics_lvo.zig");
const _text = @import("text/_text.zig");
const _display = @import("display/_display.zig");
const GraphicsBase = @import("graphics_base.zig").GraphicsBase;

/// The version of utility.library the tag calls are taken from.
const UTILITY_VERSION = 1;

/// The name it is opened by, and the name in its ROM tag and on exec's
/// library list. The SDK's, so that a caller and the library cannot
/// disagree about it.
pub const LIBRARY_NAME = graphics.GRAPHICSNAME;

/// What a caller passes to OpenLibrary to demand this much of the library.
/// It is 0 while there is nothing to demand: every drawing call raises it,
/// and a caller that needs one asks for the version that brought it.
pub const LIBRARY_VERSION = 0;

/// The build within the version. Set into the base by `init`, since exec
/// copies only the tag's name, version and ID string. 18 is
/// `WritePixelArray` and `WriteLUTPixelArray`: the table grew, and the
/// version stays 0 until there is something to demand of it.
pub const LIBRARY_REVISION = 18;

/// dd.mm.yyyy, the form every module's `$VER:` string uses so that
/// `Version` reads them all the same way.
const BUILD_DATE = "22.9.2026";

/// The `$VER:` string, NUL first so that a scan of the image finds it and
/// `id_string` can start one byte in as a plain C string.
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base a `*Library` is the front of.
///
/// INPUTS:
/// - `lib` - the Library header exec hands a vector, which is the first
///   field of a `GraphicsBase` that `CreateLibrary` allocated.
///
/// RESULT:
/// The whole base. It is a field offset, not a lookup, and cannot fail.
///
/// CONTEXT:
/// Any. It does not touch memory beyond the pointer arithmetic.
fn graphicsBase(lib: *exec.Library) *GraphicsBase {
    return @fieldParentPtr("lib", lib);
}

/// LibInit: fills in what exec's `CreateLibrary` left to the library, and
/// opens the two libraries it cannot work without.
///
/// INPUTS:
/// - `lib` - the new library, with the tag's name, version and ID string
///   already copied in and the jump table already built.
/// - `seg_list` - the segments the module was loaded from, null for one in
///   the ROM. Unused: nothing here is unloaded.
/// - `sys_base` - SysBase, kept in the base and used for every exec call
///   from now on.
///
/// RESULT:
/// The library, which tells exec to keep it and add it to the library
/// list. Null if either utility.library or rtg.library cannot be opened,
/// and exec then frees the base again; an `RTF_AUTOINIT` module that fails
/// is a dead-end Alert, which is the right answer, because a
/// graphics.library that cannot read a tag list or reach a buffer can do
/// nothing at all.
///
/// BEHAVIOR:
/// Both are open for the life of the machine, since this library never
/// expunges. Both are above it at cold start - utility at 103 and rtg at
/// 24, against this library's 20 - so both exist by the time this runs.
///
/// The last step brings the machine's display up (`display/_display.zig`):
/// the drivers are above this library at cold start (21 to 23), so they
/// are on rtg.library's list by now, and the panel's part comes from
/// expansion.library. A machine with no display still gets the library.
/// The View is found when it is used, and asked for again each time,
/// since a board can be deleted (`rastport/_rastport.zig`).
///
/// CONTEXT:
/// - Waits: yes, while a panel is held in reset.
/// - Interrupts: never called from one. exec calls it from `InitResident`.
/// - Forbid: not held. `InitCode` takes no Forbid, and cold start runs on
///   the exec task after `Permit`, with multitasking live.
/// - Process: a Task will do. The exec task runs it, and that is not a
///   process.
/// How much memory the region pool takes at a time. A `RegionRect` is 24
/// bytes here, so this is room for about a hundred and sixty of them -
/// more than a screen full of windows ever needs at once, and small enough
/// that a machine which never draws a region has lost nothing.
const region_puddle = 4096;

/// Init: opens utility.library and rtg.library, makes the region pool,
/// puts the ROM fonts on the list and brings the display up.
///
/// INPUTS:
/// - `lib` - the library as exec made it.
/// - `seg_list` - unused; a ROM module has none.
/// - `sys_base` - exec, kept in the base.
///
/// RESULT:
/// The library, or null if a library could not be opened or there was no
/// memory, with whatever was taken given back.
///
/// CONTEXT:
/// Runs on the exec task at cold start, with multitasking live and no
/// Forbid held.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const gb = graphicsBase(lib);
    lib.revision = LIBRARY_REVISION;
    gb.sys_base = sys_base;
    gb.view = null;

    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, UTILITY_VERSION) orelse
        return null;
    const rtg_lib = sys_base.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        // The first one is given back rather than left open on a base
        // exec is about to free.
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    gb.region_pool = sys_base.CreatePool(exec.MEMF_ANY, region_puddle, 0) orelse {
        sys_base.CloseLibrary(rtg_lib);
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    gb.utility_base = @ptrCast(utility_lib);
    gb.rtg_base = @ptrCast(rtg_lib);
    if (!_text.initFonts(gb)) {
        sys_base.DeletePool(gb.region_pool);
        sys_base.CloseLibrary(rtg_lib);
        sys_base.CloseLibrary(utility_lib);
        return null;
    }
    _display.openDisplay(gb);
    return lib;
}

/// What `RTF_AUTOINIT` hands exec: how big the base is, the jump table to
/// put in front of it, and the routine to finish it with.
const init_table = exec.InitTable{
    .data_size = @sizeOf(GraphicsBase),
    .vectors = &graphics_lvo.vectors,
    .vector_count = graphics_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 20: below rtg.library (24) and its drivers (23 to 21),
/// whose buffers this draws into and whose display it brings up, and
/// above everything that a program reaches it through.
pub export const graphics_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &graphics_library_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 20,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
