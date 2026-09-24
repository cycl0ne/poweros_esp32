// SPDX-License-Identifier: MPL-2.0
//! ramlib.library's ROM tag, and the init routine it names: dos opened,
//! the loading process started, and the module put in front of exec's
//! two open calls.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const ramlib = @import("ramlib.zig");
const ramlib_lvo = @import("ramlib_lvo.zig");
const RamLibBase = @import("ramlib_base.zig").RamLibBase;
const server = ramlib.server;
const openLibrary = ramlib.openLibrary;
const openDevice = ramlib.openDevice;

pub const LIBRARY_NAME = "ramlib.library";
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "17.9.2026";
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// What the process is called, and how much stack a load needs: LoadSeg
/// reads a file through a handler, which is the deepest this goes.
const PROCESS_NAME = "ramlib";
const PROCESS_STACK = 8192;

fn ramLibBase(lib: *exec.Library) *RamLibBase {
    return @fieldParentPtr("lib", lib);
}

/// LibInit: dos is on the list by now - its own init is what starts the
/// after-DOS residents - so this can open it, start its process and step
/// in front of exec.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const rlb = ramLibBase(lib);
    lib.revision = LIBRARY_REVISION;
    rlb.sys_base = sys_base;
    rlb.dos_base = @ptrCast(sys_base.OpenLibrary(dos.DOSNAME, 0) orelse return null);
    sys_base.NewList(&rlb.loaded);
    sys_base.InitSemaphore(&rlb.lock);

    // The process is handed the base as its tc_UserData, there before it
    // first runs.
    const tag_list = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&server) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(PROCESS_NAME) },
        .{ .tag = dos.NP_StackSize, .data = PROCESS_STACK },
        .{ .tag = dos.NP_Priority, .data = 0 },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(rlb) },
        .{},
    };
    rlb.process = rlb.dos_base.CreateNewProc(&tag_list);
    if (rlb.process == null) {
        sys_base.CloseLibrary(&rlb.dos_base.lib().*);
        return null;
    }

    patch(rlb);
    sdk.exec.kprintf(sys_base, "ramlib.library: in front of OpenLibrary and OpenDevice\n", .{});
    return lib;
}

/// In front of exec's two open calls, once the process is there to do the
/// loading. Nothing else is touched: closing is exec's own business, and
/// what a loaded module costs is given back when it is flushed, which
/// nothing does yet. A replaced vector is called with exec's arguments on
/// whatever task is opening something, so the base it needs is kept where
/// exec is: `SetRamLib`, set with the patch.
fn patch(rlb: *RamLibBase) void {
    const sys = rlb.sys_base;
    const base: *exec.Library = @ptrCast(@alignCast(sys));
    sys.Forbid();
    defer sys.Permit();
    sys.SetRamLib(@ptrCast(rlb));
    rlb.old_open_library = sys.SetFunction(base, sdk.interface.exec.LVO.OpenLibrary, @ptrCast(&openLibrary));
    rlb.old_open_device = sys.SetFunction(base, sdk.interface.exec.LVO.OpenDevice, @ptrCast(&openDevice));
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(RamLibBase),
    .vectors = &ramlib_lvo.vectors,
    .vector_count = ramlib_lvo.vectors.len,
    .init = &init,
};

/// After dos, which it opens and cannot live without, and last among the
/// after-DOS residents: anything else there may want a library of its own,
/// and by then this is in place to find it.
pub export const ramlib_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &ramlib_library_tag,
    .flags = exec.RTF_AFTERDOS | exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = -100,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
