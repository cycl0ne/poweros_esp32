// SPDX-License-Identifier: MPL-2.0
//! The PCF8563 (and the BM8563, the same chip to a driver) as the clock:
//! seconds to years in BCD from register 0x02 on, read and written in one
//! transfer each through i2c.device.
//!
//!   0x00  control 1    STOP (bit 5) halts the clock; TESTC, TEST1
//!   0x01  control 2    the alarm's and the timer's interrupts
//!   0x02  seconds      VL (bit 7): the cell ran low, the date is not to
//!                      be trusted
//!   0x03  minutes
//!   0x04  hours        24-hour
//!   0x05  day          1 to 31
//!   0x06  weekday      0 (Sunday) to 6
//!   0x07  month        1 to 12; C (bit 7) set for the years from 2000
//!   0x08  year         0 to 99
//!
//! The clock covers 1978 to 2099: a date outside it, a VL bit, or a digit
//! that is no BCD digit is no date.

const sdk = @import("sdk");
const exec = sdk.exec;
const i2c = sdk.devices.i2c;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const BattClockBase = @import("../battclock_base.zig").BattClockBase;

/// The chip's address on the bus.
pub const default_address: u32 = 0x51;

const REG_CONTROL1: u8 = 0x00;
const REG_SECONDS: u8 = 0x02;
const SECONDS_VL: u8 = 1 << 7;
const MONTH_CENTURY: u8 = 1 << 7;

/// The date registers, 0x02 to 0x08.
pub const Registers = [7]u8;

fn fromBcd(value: u8) ?u16 {
    const tens = value >> 4;
    const ones = value & 0x0F;
    if (tens > 9 or ones > 9) return null;
    return @as(u16, tens) * 10 + ones;
}

fn toBcd(value: u16) u8 {
    return @intCast((value / 10) << 4 | (value % 10));
}

/// The date the registers hold, or null for none (see the file's head).
/// The weekday is the chip's; Date2Amiga does not read it.
pub fn dateOf(regs: Registers) ?utility.ClockData {
    if (regs[0] & SECONDS_VL != 0) return null;
    const year = (fromBcd(regs[6]) orelse return null) + @as(u16, if (regs[5] & MONTH_CENTURY != 0) 2000 else 1900);
    const date: utility.ClockData = .{
        .sec = fromBcd(regs[0] & 0x7F) orelse return null,
        .min = fromBcd(regs[1] & 0x7F) orelse return null,
        .hour = fromBcd(regs[2] & 0x3F) orelse return null,
        .mday = fromBcd(regs[3] & 0x3F) orelse return null,
        .wday = regs[4] & 0x07,
        .month = fromBcd(regs[5] & 0x1F) orelse return null,
        .year = year,
    };
    if (date.year < 1978 or date.sec > 59 or date.min > 59 or date.hour > 23) return null;
    if (date.mday < 1 or date.mday > 31 or date.month < 1 or date.month > 12) return null;
    return date;
}

/// The registers for `date`, VL clear. `date` lies in 1978 to 2099.
pub fn registersOf(date: utility.ClockData) Registers {
    const century: u8 = if (date.year >= 2000) MONTH_CENTURY else 0;
    return .{
        toBcd(date.sec),
        toBcd(date.min),
        toBcd(date.hour),
        toBcd(date.mday),
        @intCast(date.wday),
        toBcd(date.month) | century,
        toBcd(date.year % 100),
    };
}

/// A transfer with the chip: `command` (CMD_WRITE, or I2CCMD_WRITEREAD
/// with `register` sent first) on i2c.device's unit, `bytes` the data.
/// False when the device does not open or the chip does not answer.
fn transfer(cb: *BattClockBase, command: u16, register: ?*const u8, bytes: []u8) bool {
    const sys = cb.sys_base;
    const port = sys.CreateMsgPort() orelse return false;
    defer sys.DeleteMsgPort(port);
    var io: i2c.IOExtI2C = .{};
    io.req.req.message.reply_port = port;
    io.req.req.message.length = @sizeOf(i2c.IOExtI2C);
    if (sys.OpenDevice(i2c.DEVICE_NAME, cb.i2c_unit, &io.req.req, 0) != 0) return false;
    defer sys.CloseDevice(&io.req.req);
    io.req.req.command = command;
    io.address = @intCast(cb.i2c_address);
    io.req.data = bytes.ptr;
    io.req.length = bytes.len;
    if (register) |first| {
        io.wr_data = @constCast(first);
        io.wr_length = 1;
    }
    return sys.DoIO(&io.req.req) == 0;
}

/// Whether the chip answers at its address.
pub fn answers(cb: *BattClockBase) bool {
    var regs: Registers = undefined;
    return transfer(cb, i2c.I2CCMD_WRITEREAD, &REG_SECONDS, &regs);
}

/// The date registers as the chip has them; null when it does not answer.
pub fn read(cb: *BattClockBase) ?Registers {
    var regs: Registers = undefined;
    if (!transfer(cb, i2c.I2CCMD_WRITEREAD, &REG_SECONDS, &regs)) return null;
    return regs;
}

/// The date registers written in one go.
pub fn write(cb: *BattClockBase, regs: Registers) void {
    var bytes: [1 + regs.len]u8 = undefined;
    bytes[0] = REG_SECONDS;
    @memcpy(bytes[1..], &regs);
    _ = transfer(cb, exec.CMD_WRITE, null, &bytes);
}

/// The clock running and its test modes, alarm and timer interrupts off:
/// both control registers cleared.
pub fn restart(cb: *BattClockBase) void {
    var bytes = [_]u8{ REG_CONTROL1, 0, 0 };
    _ = transfer(cb, exec.CMD_WRITE, null, &bytes);
}
