// SPDX-License-Identifier: MIT
//! usb.library's ROM tag, its init and its Expunge. Open and Close are
//! exec's standard ones: every opener shares the one base.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("usb_base.zig");
const UsbBase = _base.UsbBase;
const usb_lvo = @import("usb_lvo.zig");
const _bind = @import("bind/_bind.zig");

pub const LIBRARY_NAME = usb.USBNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 12;
const BUILD_DATE = "25.10.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base filled in: its lists and their locks. Nothing starts.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base = _base.usbBase(lib);
    const header = lib.*;
    base.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list };
    lib.revision = LIBRARY_REVISION;
    sys_base.NewList(&base.devices);
    sys_base.NewList(&base.notify);
    sys_base.InitSemaphore(&base.devices_lock);
    sys_base.InitSemaphore(&base.bus_lock);
    sys_base.InitSemaphore(&base.drivers_lock);
    sys_base.InitSemaphore(&base.notify_lock);
    return lib;
}

/// The library goes when nobody has it open - a running bus holds it
/// open - the drivers' table, dos and utility let go, the base freed and
/// the file it was loaded from handed back.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const base = _base.usbBase(lib);
    const sys = base.sys_base;
    const seg_list = base.seg_list;
    _bind.forget(base);
    if (base.dos) |dos_base| sys.CloseLibrary(dos_base.lib());
    if (base.utility) |utility_base| sys.CloseLibrary(utility_base.lib());
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(UsbBase),
    .vectors = &usb_lvo.vectors,
    .vector_count = usb_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it. In `.resident`, which program.ld KEEPs.
pub export const usb_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &usb_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..],
    .init = &init_table,
};
