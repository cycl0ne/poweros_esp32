// SPDX-License-Identifier: MIT
//! bluetooth.library's ROM tag, its init and its Expunge. Open and Close
//! are exec's standard ones: every opener shares the one base. While the
//! task runs it holds the library open, so the library cannot go under
//! it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("bluetooth_base.zig");
const BluetoothBase = _base.BluetoothBase;
const bluetooth_lvo = @import("bluetooth_lvo.zig");

pub const LIBRARY_NAME = bluetooth.BLUETOOTHNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
pub const BUILD_DATE = "22.11.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base filled in, its lists and locks made. The task is started by
/// the first controller added.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base = _base.bluetoothBase(lib);
    const header = lib.*;
    base.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list };
    lib.revision = LIBRARY_REVISION;
    base.controllers.init(.unknown);
    base.notify.init(.unknown);
    sys_base.InitSemaphore(&base.lock);
    sys_base.InitSemaphore(&base.start_lock);
    sys_base.InitSemaphore(&base.notify_lock);
    return lib;
}

/// The library goes when nobody has it open - the task, which holds it
/// open, has ended by then: dos.library closed, the base freed, and the
/// file it was loaded from handed back.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const base = _base.bluetoothBase(lib);
    const sys = base.sys_base;
    const seg_list = base.seg_list;
    if (base.dos) |library| sys.CloseLibrary(@ptrCast(@alignCast(library)));
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(BluetoothBase),
    .vectors = &bluetooth_lvo.vectors,
    .vector_count = bluetooth_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it. In `.resident`, which program.ld KEEPs.
pub export const bluetooth_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &bluetooth_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
