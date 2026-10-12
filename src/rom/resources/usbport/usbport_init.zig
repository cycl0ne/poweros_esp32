// SPDX-License-Identifier: MPL-2.0
//! usbport.resource's ROM tag, and the init routine it names: every port
//! without a holder, with the controller the chip starts it with.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const usbport = sdk.resources.usbport;
const ExecBase = sdk.interface.exec.ExecBase;
const usbport_lvo = @import("usbport_lvo.zig");
const UsbPortBase = @import("usbport_base.zig").UsbPortBase;

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = usbport.USBPORTNAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 0;
const BUILD_DATE = "12.10.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn usbPortBase(lib: *exec.Library) *UsbPortBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// ResInit: no bidders and no holders. The ports are left as the chip
/// started them: nothing is switched before somebody bids.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no; it runs on the exec task at cold start.
/// - Locks: none needed. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const pb = usbPortBase(lib);
    lib.revision = RESOURCE_REVISION;
    pb.sys_base = sys_base;
    for (&pb.bidders) |*list| sys_base.NewList(list);
    pb.holder = @splat(null);
    sys_base.InitLock(&pb.lock, RESOURCE_NAME, exec.LOCKORDER_DRIVER, 0);
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(UsbPortBase),
    .vectors = &usbport_lvo.vectors,
    .vector_count = usbport_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 88: after gpio.resource (90), and before usbserial.device,
/// which bids for its port as it starts.
pub export const usbport_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &usbport_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 88,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
