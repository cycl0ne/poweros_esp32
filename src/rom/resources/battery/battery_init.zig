// SPDX-License-Identifier: MPL-2.0
//! battery.resource's ROM tag, and the init routine it names: the board's
//! battery part read, its lines set up, and the task that measures
//! started.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const battery = sdk.resources.battery;
const ExecBase = sdk.interface.exec.ExecBase;
const battery_lvo = @import("battery_lvo.zig");
const BatteryBase = @import("battery_base.zig").BatteryBase;
const _sense = @import("sense/_sense.zig");
const task = @import("sense/task.zig");

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = battery.BATTERYNAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 0;
const BUILD_DATE = "11.10.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn batteryBase(lib: *exec.Library) *BatteryBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// ResInit: the board's battery part read and its lines set up, and the
/// task that measures started. On a board with nothing to measure the
/// resource is made all the same, and answers that it has nothing; a
/// line it could not set up leaves it the same way, said on the raw port.
///
/// CONTEXT:
/// - Waits: for memory. - Interrupts: no; it runs on the exec task at
///   cold start.
/// - Locks: none needed. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const bb = batteryBase(lib);
    lib.revision = RESOURCE_REVISION;
    bb.sys_base = sys_base;
    bb.wiring = .{};
    bb.expander = null;
    bb.state = .{};
    bb.smoothed_mv = 0;
    bb.stack = null;
    sys_base.NewList(&bb.notify);
    sys_base.InitSemaphore(&bb.lock);
    const wiring = _sense.wiringOf(sys_base);
    if (!wiring.any()) return lib;
    bb.wiring = wiring;
    if (!_sense.setUp(bb) or !task.start(bb)) {
        bb.wiring = .{};
        return lib;
    }
    bb.state.flags = _sense.abilities(wiring);
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(BatteryBase),
    .vectors = &battery_lvo.vectors,
    .vector_count = battery_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 28: after expansion.library, gpio.resource,
/// timer.device and expander.resource (30), which it reads the battery
/// through, and before input.device and the display.
pub export const battery_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &battery_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 28,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
