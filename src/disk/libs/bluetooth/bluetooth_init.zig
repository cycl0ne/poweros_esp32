// SPDX-License-Identifier: MIT
//! bluetooth.library's ROM tag, its init, its Open and its Expunge. Close
//! is exec's standard one, and so is Open but for its first time on a
//! process, which adds the board's own controllers (controller/board.zig):
//! every opener shares the one base. While the task runs it holds the
//! library open, so the library cannot go under it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("bluetooth_base.zig");
const BluetoothBase = _base.BluetoothBase;
const bluetooth_lvo = @import("bluetooth_lvo.zig");
const board = @import("controller/board.zig");
const profile_drivers = @import("profile/drivers.zig");

pub const LIBRARY_NAME = bluetooth.BLUETOOTHNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 21;
pub const BUILD_DATE = "24.11.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base filled in, utility.library opened, its lists and locks
/// made; without utility.library there is no library. The task is
/// started by the first controller added.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base = _base.bluetoothBase(lib);
    const header = lib.*;
    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    base.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list, .utility_base = @ptrCast(utility_lib) };
    lib.revision = LIBRARY_REVISION;
    base.controllers.init(.unknown);
    base.notify.init(.unknown);
    base.agents.init(.unknown);
    base.listeners.init(.unknown);
    base.records.init(.unknown);
    base.binder_queue.init(.message);
    base.bindings.init(.unknown);
    base.channel_messages.init(.unknown);
    sys_base.InitSemaphore(&base.lock);
    sys_base.InitSemaphore(&base.start_lock);
    sys_base.InitSemaphore(&base.notify_lock);
    sys_base.InitSemaphore(&base.agents_lock);
    sys_base.InitSemaphore(&base.listeners_lock);
    sys_base.InitSemaphore(&base.records_lock);
    sys_base.InitSemaphore(&base.binder_lock);
    return lib;
}

/// exec's standard Open; the first one on a process adds the board's own
/// controllers before it answers, so that its opener lists them. It runs
/// under the library's lock, which the devices those controllers are on
/// take only from tasks of their own, never in their Open.
fn open(lib: *exec.Library, version: u32) callconv(.c) ?*exec.Library {
    const opened = exec.libOpen(lib, version);
    board.look(_base.bluetoothBase(lib));
    return opened;
}

pub const openVector = open;

/// The library goes when nobody has it open - the task and the binder,
/// which hold it open, have ended by then: the profile drivers' table
/// freed, dos.library, crypto.library and utility.library closed, the
/// base freed, and the file it was loaded from handed back.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const base = _base.bluetoothBase(lib);
    const sys = base.sys_base;
    const seg_list = base.seg_list;
    // The binder has ended: it holds the library open while it runs.
    profile_drivers.release(base);
    if (base.dos) |library| sys.CloseLibrary(@ptrCast(@alignCast(library)));
    if (base.crypto) |library| sys.CloseLibrary(@ptrCast(@alignCast(library)));
    sys.CloseLibrary(@ptrCast(@alignCast(base.utility_base)));
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
