// SPDX-License-Identifier: MPL-2.0
//! ps2.resource's start: the ROM tag, and the init that looks for the
//! keyboard controller and starts the task behind it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("ps2_base.zig");
const ps2Base = _base.ps2Base;
const port = @import("port/_port.zig");
const task = @import("input/task.zig");

pub const RESOURCE_NAME = "ps2.resource";
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 0;
const BUILD_DATE = "14.11.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The controller looked for and set up, and its task started. The
/// resource is there on a machine without the controller too: it then
/// says so, and nothing runs.
///
/// INPUTS:
/// - `lib` - the base exec made from the init table.
/// - `seg_list` - null: a module in the ROM has no segments.
/// - `sys_base` - SysBase, kept in the base.
///
/// RESULT:
/// The base.
///
/// CONTEXT:
/// - Waits: for its task to have started.
/// - Interrupts: no; it runs on the exec task at cold start.
/// - Locks: none needed. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const pb = ps2Base(lib);
    lib.revision = RESOURCE_REVISION;
    pb.sys_base = sys_base;
    pb.controller = false;
    pb.pointer = false;
    pb.wheel = false;
    pb.head = 0;
    pb.tail = 0;
    pb.lost = 0;
    pb.stack = null;
    pb.byte_signal = 0;
    pb.starter = null;
    const found = port.setUp();
    pb.controller = found.controller;
    pb.pointer = found.pointer;
    pb.wheel = found.wheel;
    if (!found.controller) {
        exec.kprintf(sys_base, "%s: this machine has no keyboard controller at its ports\n", .{@as([*:0]const u8, RESOURCE_NAME)});
        return lib;
    }
    if (!task.start(pb)) {
        exec.kprintf(sys_base, "%s: its task could not be started\n", .{@as([*:0]const u8, RESOURCE_NAME)});
        return lib;
    }
    exec.kprintf(sys_base, "%s: a keyboard%s\n", .{
        @as([*:0]const u8, RESOURCE_NAME),
        @as([*:0]const u8, if (!found.pointer) ", no pointing device" else if (found.wheel) " and a pointing device with a wheel" else " and a pointing device"),
    });
    return lib;
}

/// A resource with no calls of its own: it is on exec's list to say that
/// the controller is driven, and its base is where its state is. A base
/// has one vector at least, so its one slot is the reserved function,
/// which answers nothing.
const vectors = [_]*const anyopaque{exec.vec(exec.libExtFunc)};

const init_table = exec.InitTable{
    .data_size = @sizeOf(_base.Ps2Base),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// After keyboard.device and mouse.device, which its task opens.
pub export const ps2_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &ps2_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 20,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
