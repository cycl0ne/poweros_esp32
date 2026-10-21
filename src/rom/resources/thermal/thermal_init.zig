// SPDX-License-Identifier: MPL-2.0
//! thermal.resource's ROM tag, and the init routine it names: the board's
//! sensors found and started, and the task that reads them started.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const thermal = sdk.resources.thermal;
const ExecBase = sdk.interface.exec.ExecBase;
const thermal_lvo = @import("thermal_lvo.zig");
const ThermalBase = @import("thermal_base.zig").ThermalBase;
const _sense = @import("sense/_sense.zig");
const task = @import("sense/task.zig");

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = thermal.THERMALNAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 0;
const BUILD_DATE = "21.10.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn thermalBase(lib: *exec.Library) *ThermalBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// ResInit: the board's sensors found and started, each one's name and
/// limits stored, and the task that reads started. On a board without a
/// sensor the resource is made all the same, and answers that it has
/// none.
///
/// CONTEXT:
/// - Waits: for memory. - Interrupts: no; it runs on the exec task at
///   cold start.
/// - Locks: none needed. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const tb = thermalBase(lib);
    lib.revision = RESOURCE_REVISION;
    tb.sys_base = sys_base;
    tb.sensors = @splat(.{});
    tb.units = 0;
    tb.states = @splat(.{});
    tb.stack = null;
    sys_base.NewList(&tb.notify);
    sys_base.InitSemaphore(&tb.lock);
    _sense.find(tb);
    for (tb.sensors[0..tb.units], tb.states[0..tb.units]) |sensor, *state| {
        state.* = .{ .hot_millicelsius = sensor.hot, .critical_millicelsius = sensor.critical, .name = sensor.name };
    }
    if (tb.units != 0) _ = task.start(tb);
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(ThermalBase),
    .vectors = &thermal_lvo.vectors,
    .vector_count = thermal_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 28: after expansion.library, which it finds the sensors
/// through, and timer.device, which its task waits with.
pub export const thermal_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &thermal_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 28,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
