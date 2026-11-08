// SPDX-License-Identifier: MPL-2.0
//! The battery-backed clock an x86-64 machine has had since the PC
//! (CHIP_MC146818): two registers in the I/O port space - an index and
//! the byte it names - behind which sit the seconds, the minutes, the
//! hours, the date and a handful of settings, kept by a cell while the
//! machine is off.
//!
//! **It is read as it is set up, not as it is assumed.** The part keeps
//! its figures either as plain numbers or two digits to a byte, and its
//! hours either around the clock or twice twelve with a flag for the
//! afternoon; which it does is in one of its own registers, and the
//! firmware chose it. The year is two digits, and which century they
//! belong to is in a register of its own whose index the firmware's
//! tables name (`PART_Century`); a machine whose tables name none is
//! taken to be in this one.
//!
//! **A read is never taken while the clock is counting.** The part marks
//! the moment it is carrying a second over, and what is read during it
//! may be half the old time and half the new; so a read waits for that
//! mark to clear and then reads everything twice, and takes it only when
//! the two agree.

const sdk = @import("sdk");
const utility = sdk.utility;

/// The two ports: the register to be reached, and the register itself.
pub const INDEX_PORT: u16 = 0x70;
const DATA_PORT: u16 = 0x71;

/// The registers, by their index.
const SECONDS = 0x00;
const MINUTES = 0x02;
const HOURS = 0x04;
const WEEKDAY = 0x06;
const DAY = 0x07;
const MONTH = 0x08;
const YEAR = 0x09;
const STATUS_A = 0x0A;
const STATUS_B = 0x0B;

/// Status A, bit 7: the clock is carrying a second over just now.
const UPDATING: u8 = 1 << 7;
/// Status B: the hours go round once and not twice; the figures are plain
/// numbers and not two digits to a byte; and the clock is stopped, which
/// is how it is set.
const HOURS_24: u8 = 1 << 1;
const BINARY: u8 = 1 << 2;
const STOPPED: u8 = 1 << 7;
/// Twice-twelve hours mark the afternoon in the high bit of the hour.
const AFTERNOON: u8 = 1 << 7;

/// How long a read waits for the clock to finish carrying a second over,
/// and how many times it reads everything to get two readings that agree.
/// The carry takes under two milliseconds and the port is read in
/// microseconds, so neither bound is ever reached on a clock that works -
/// they are there so that a clock that does not answer stops the read
/// rather than the machine.
const patience: u32 = 1_000_000;
const tries: u32 = 4;

/// Which century a two-digit year is in, where the tables name no
/// register for it.
const this_century: u32 = 2000;

/// What the clock holds, as it holds it.
pub const Registers = struct {
    second: u8 = 0,
    minute: u8 = 0,
    hour: u8 = 0,
    day: u8 = 0,
    month: u8 = 0,
    year: u8 = 0,
    century: u8 = 0,
};

fn read8(index: u8) u8 {
    const mmio = sdk.hardware.mmio;
    mmio.out8(INDEX_PORT, index);
    return mmio.in8(DATA_PORT);
}

fn write8(index: u8, value: u8) void {
    const mmio = sdk.hardware.mmio;
    mmio.out8(INDEX_PORT, index);
    mmio.out8(DATA_PORT, value);
}

/// Whether two readings are the same, which is how a read knows the
/// clock did not count between them.
fn same(a: Registers, b: Registers) bool {
    return a.second == b.second and a.minute == b.minute and a.hour == b.hour and
        a.day == b.day and a.month == b.month and a.year == b.year and a.century == b.century;
}

/// Two digits to a byte, as a number.
fn fromPacked(value: u8) u8 {
    return (value >> 4) * 10 + (value & 0x0F);
}

/// A number, as two digits to a byte.
fn toPacked(value: u8) u8 {
    return (value / 10) << 4 | (value % 10);
}

/// The clock's registers once it is not carrying a second over, read
/// twice to the same answer. `century` is the index of the century's
/// register, 0 where there is none. Null where the clock never settles.
pub fn read(century: u8) ?Registers {
    var last: ?Registers = null;
    var left: u32 = tries;
    while (left > 0) : (left -= 1) {
        var waited: u32 = 0;
        while (read8(STATUS_A) & UPDATING != 0) : (waited += 1) {
            if (waited == patience) return null;
        }
        const now: Registers = .{
            .second = read8(SECONDS),
            .minute = read8(MINUTES),
            .hour = read8(HOURS),
            .day = read8(DAY),
            .month = read8(MONTH),
            .year = read8(YEAR),
            .century = if (century != 0) read8(century) else 0,
        };
        if (last) |before| {
            if (same(before, now)) return now;
        }
        last = now;
    }
    return null;
}

/// The date the registers hold, in the settings the clock is in. Null
/// where they hold no date at all - a clock with no cell, or none there.
pub fn dateOf(regs: Registers, status_b: u8) ?utility.ClockData {
    const plain = status_b & BINARY != 0;
    const afternoon = status_b & HOURS_24 == 0 and regs.hour & AFTERNOON != 0;
    const hour_bits = if (status_b & HOURS_24 != 0) regs.hour else regs.hour & ~AFTERNOON;

    var hour: u32 = if (plain) hour_bits else fromPacked(hour_bits);
    if (status_b & HOURS_24 == 0) {
        // Twelve means midnight before noon and noon after it.
        if (hour == 12) hour = 0;
        if (afternoon) hour += 12;
    }
    const second: u32 = if (plain) regs.second else fromPacked(regs.second);
    const minute: u32 = if (plain) regs.minute else fromPacked(regs.minute);
    const day: u32 = if (plain) regs.day else fromPacked(regs.day);
    const month: u32 = if (plain) regs.month else fromPacked(regs.month);
    const years: u32 = if (plain) regs.year else fromPacked(regs.year);
    const century: u32 = if (regs.century == 0)
        this_century
    else
        @as(u32, if (plain) regs.century else fromPacked(regs.century)) * 100;

    if (second > 59 or minute > 59 or hour > 23) return null;
    if (day == 0 or day > 31 or month == 0 or month > 12 or years > 99) return null;
    return .{
        .sec = @intCast(second),
        .min = @intCast(minute),
        .hour = @intCast(hour),
        .mday = @intCast(day),
        .month = @intCast(month),
        .year = @intCast(century + years),
        .wday = 0,
    };
}

/// `date` into the clock, in the settings it is in: it is stopped while
/// its registers are written, so that it cannot carry a second over
/// between two of them, and started again afterwards. The weekday is
/// written too, since something else may read it, and the date's own
/// count of it is 0 for Sunday where this part counts from 1.
pub fn write(date: utility.ClockData, status_b: u8, century: u8) void {
    const plain = status_b & BINARY != 0;
    const twice = status_b & HOURS_24 == 0;
    var hour: u8 = @intCast(date.hour);
    var mark: u8 = 0;
    if (twice) {
        mark = if (hour >= 12) AFTERNOON else 0;
        hour = @intCast(if (hour % 12 == 0) 12 else hour % 12);
    }
    write8(STATUS_B, status_b | STOPPED);
    putNumber(SECONDS, @intCast(date.sec), plain);
    putNumber(MINUTES, @intCast(date.min), plain);
    write8(HOURS, (if (plain) hour else toPacked(hour)) | mark);
    putNumber(WEEKDAY, @intCast(date.wday + 1), plain);
    putNumber(DAY, @intCast(date.mday), plain);
    putNumber(MONTH, @intCast(date.month), plain);
    putNumber(YEAR, @intCast(date.year % 100), plain);
    if (century != 0) putNumber(century, @intCast(date.year / 100), plain);
    write8(STATUS_B, status_b & ~STOPPED);
}

/// One register written as the clock keeps its figures: a plain number,
/// or two digits to a byte.
fn putNumber(index: u8, value: u8, plain: bool) void {
    write8(index, if (plain) value else toPacked(value));
}

/// How the clock keeps its figures: status B, which the firmware set up
/// and which nothing here changes.
pub fn settings() u8 {
    return read8(STATUS_B);
}
