// SPDX-License-Identifier: MPL-2.0
//! battclock.resource's ROM tag, and the init routine it names: the clock
//! chosen - the board's clock chip, the JH7110's RTC or the Raspberry
//! Pi's, else the chip's RTC timer - and the system time set from it.

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
const jh7110rtc = @import("source/jh7110rtc.zig");
const rpirtc = @import("source/rpirtc.zig");

/// The ESP32s have an RTC timer that counts through a reset; the JH7110
/// has an RTC of its own, which the board lists; so does a Raspberry Pi,
/// behind its firmware.
const has_rtc_timer = sdk.hardware.chip == .esp32s3 or sdk.hardware.chip == .esp32p4;
const has_jh7110_rtc = sdk.hardware.chip == .rv64sbi;
const has_rpi_rtc = sdk.hardware.chip == .a64psci;

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = sdk.resources.battclock.BATTCLOCKNAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 1;
const BUILD_DATE = "25.10.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn battClockBase(lib: *exec.Library) *BattClockBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// The board's clock, when it lists one: a PCF8563 on an I2C bus, its
/// bus and address into the base; or the JH7110's RTC, its registers'
/// address; or the Raspberry Pi's, the VideoCore's mailbox. Which chip it
/// is - CHIP_NONE for none.
fn findChip(cb: *BattClockBase) u32 {
    const sys = cb.sys_base;
    const ub = cb.utility_base orelse return st.CHIP_NONE;
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return st.CHIP_NONE;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_RTC, st.CHIP_ANY) orelse return st.CHIP_NONE;
    const chip: u32 = @truncate(ub.GetTagData(st.PART_Chip, st.CHIP_NONE, part.tags));
    switch (chip) {
        st.CHIP_PCF8563 => {
            if (ub.GetTagData(st.PART_Bus, st.BUS_I2C, part.tags) != st.BUS_I2C) return st.CHIP_NONE;
            cb.i2c_unit = @truncate(ub.GetTagData(st.PART_BusUnit, 0, part.tags));
            cb.i2c_address = @truncate(ub.GetTagData(st.PART_Address, pcf8563.default_address, part.tags));
        },
        st.CHIP_JH7110_RTC, st.CHIP_RPI_RTC => {
            cb.rtc_address = @intCast(ub.GetTagData(st.PART_Address, 0, part.tags));
            if (cb.rtc_address == 0) return st.CHIP_NONE;
        },
        else => return st.CHIP_NONE,
    }
    return chip;
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
/// that lists a PCF8563 that answers keeps the date there; one that lists
/// the JH7110's RTC keeps it there, the RTC set at once to the date a
/// reset kept and the time since (source/jh7110rtc.zig); one that lists
/// the Raspberry Pi's keeps it there if the firmware answers, its
/// messages in a buffer of MEMF_DMA; otherwise the ESP32s' RTC timer
/// does, its slow clock measured and its reckoning carried over. With
/// none, the resource is made all the same, and its calls find no
/// clock.
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
    cb.rtc_address = 0;
    cb.rtc_buffer = 0;
    cb.period = 0;
    cb.start_count = 0;
    cb.start_ticks = 0;
    sys_base.InitSemaphore(&cb.lock);
    cb.utility_base = @ptrCast(sys_base.OpenLibrary(sdk.interface.utility.NAME, 1));

    switch (findChip(cb)) {
        st.CHIP_PCF8563 => {
            cb.clock = _base.CLOCK_PCF8563;
            if (!pcf8563.answers(cb)) {
                exec.kprintf(sys_base, "%s: no pcf8563 at 0x%x on i2c unit %u\n", .{ RESOURCE_NAME, cb.i2c_address, cb.i2c_unit });
                cb.clock = _base.CLOCK_NONE;
            }
        },
        st.CHIP_JH7110_RTC => if (comptime has_jh7110_rtc) {
            if (jh7110rtc.start(sys_base, cb.utility_base.?, cb.rtc_address)) {
                cb.clock = _base.CLOCK_JH7110_RTC;
            } else {
                exec.kprintf(sys_base, "%s: the jh7110 rtc stays in reset\n", .{RESOURCE_NAME});
            }
        },
        st.CHIP_RPI_RTC => if (comptime has_rpi_rtc) startRpi(cb),
        else => {},
    }
    if (comptime has_rtc_timer) {
        if (cb.clock == _base.CLOCK_NONE) {
            if (rtctimer.measure(sys_base)) |measured| {
                cb.clock = _base.CLOCK_RTC_TIMER;
                cb.period = measured.period;
                cb.start_count = measured.first.count;
                cb.start_ticks = measured.first.ticks;
                rtctimer.start(cb.period);
            }
        }
    }
    if (cb.clock != _base.CLOCK_NONE) setSystemTime(cb);
    return lib;
}

/// The Raspberry Pi's RTC taken if its firmware answers, its buffer kept
/// for good; said in the log if it does not.
fn startRpi(cb: *BattClockBase) void {
    const sys = cb.sys_base;
    const memory = sys.AllocMem(rpirtc.buffer_bytes * 2, exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return;
    const buffer = rpirtc.bufferIn(memory) orelse {
        sys.FreeMem(memory, rpirtc.buffer_bytes * 2);
        exec.kprintf(sys, "%s: no memory the firmware reaches\n", .{RESOURCE_NAME});
        return;
    };
    if (rpirtc.read(sys, cb.rtc_address, buffer) == null) {
        sys.FreeMem(memory, rpirtc.buffer_bytes * 2);
        exec.kprintf(sys, "%s: the firmware does not answer for its rtc\n", .{RESOURCE_NAME});
        return;
    }
    cb.rtc_buffer = @intFromPtr(buffer);
    cb.clock = _base.CLOCK_RPI_RTC;
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
