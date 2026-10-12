// SPDX-License-Identifier: MPL-2.0
//! battclock.resource's ROM tag, and the init routine it names: the clock
//! chosen - the board's clock chip, else the chip's RTC timer - and the
//! system time set from it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const st = sdk.expansion.systemtags;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const battclock_lvo = @import("battclock_lvo.zig");
const _base = @import("battclock_base.zig");
const BattClockBase = _base.BattClockBase;
const rtctimer = @import("source/rtctimer.zig");
const pcf8563 = @import("source/pcf8563.zig");

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = sdk.resources.battclock.BATTCLOCKNAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 0;
const BUILD_DATE = "12.10.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn battClockBase(lib: *exec.Library) *BattClockBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// The board's clock chip, when it lists a PCF8563 on an I2C bus: its
/// bus and address into the base. False for none.
fn findChip(cb: *BattClockBase) bool {
    const sys = cb.sys_base;
    const ub = cb.utility_base orelse return false;
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_RTC, st.CHIP_PCF8563) orelse return false;
    if (ub.GetTagData(st.PART_Bus, st.BUS_I2C, part.tags) != st.BUS_I2C) return false;
    cb.i2c_unit = @truncate(ub.GetTagData(st.PART_BusUnit, 0, part.tags));
    cb.i2c_address = @truncate(ub.GetTagData(st.PART_Address, pcf8563.default_address, part.tags));
    return true;
}

/// The system time set to the clock's date, through timer.device.
fn setSystemTime(cb: *BattClockBase) void {
    const sys = cb.sys_base;
    const seconds = @as(*sdk.interface.battclock.BattClockBase, @ptrCast(&cb.lib)).ReadBattClock();
    const port = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(port);
    var request: timer.TimeRequest = .{};
    request.node.message.reply_port = port;
    request.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(timer.TIMERNAME, timer.UNIT_MICROHZ, &request.node, 0) != 0) return;
    defer sys.CloseDevice(&request.node);
    request.node.command = timer.TR_SETSYSTIME;
    request.time = .{ .secs = seconds, .micro = 0 };
    _ = sys.DoIO(&request.node);
}

/// ResInit: the clock chosen and the system time set from it. A board
/// that lists a PCF8563 that answers keeps the date there; otherwise the
/// chip's RTC timer does, its slow clock measured and its reckoning
/// carried over. With neither, the resource is made all the same, and
/// its calls find no clock.
///
/// CONTEXT:
/// - Waits: yes, for i2c.device and timer.device, and about 8 ms for the
///   slow clock's measurement. - Interrupts: no; it runs on the exec task
///   at cold start.
/// - Locks: none needed. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const cb = battClockBase(lib);
    lib.revision = RESOURCE_REVISION;
    cb.sys_base = sys_base;
    cb.clock = _base.CLOCK_NONE;
    cb.i2c_unit = 0;
    cb.i2c_address = 0;
    cb.period = 0;
    cb.start_count = 0;
    cb.start_ticks = 0;
    sys_base.InitSemaphore(&cb.lock);
    cb.utility_base = @ptrCast(sys_base.OpenLibrary(sdk.interface.utility.NAME, 1));

    if (findChip(cb)) {
        cb.clock = _base.CLOCK_PCF8563;
        if (!pcf8563.answers(cb)) {
            exec.kprintf(sys_base, "%s: no pcf8563 at 0x%x on i2c unit %u\n", .{ RESOURCE_NAME, cb.i2c_address, cb.i2c_unit });
            cb.clock = _base.CLOCK_NONE;
        }
    }
    if (cb.clock == _base.CLOCK_NONE) {
        if (rtctimer.measure(sys_base)) |measured| {
            cb.clock = _base.CLOCK_RTC_TIMER;
            cb.period = measured.period;
            cb.start_count = measured.first.count;
            cb.start_ticks = measured.first.ticks;
            rtctimer.start(cb.period);
        }
    }
    if (cb.clock != _base.CLOCK_NONE) setSystemTime(cb);
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(BattClockBase),
    .vectors = &battclock_lvo.vectors,
    .vector_count = battclock_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 34: after timer.device (50), which it sets the system
/// time on, and i2c.device (35), which a clock chip is reached through;
/// before the file systems, which stamp files with the date.
pub export const battclock_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &battclock_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 34,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
