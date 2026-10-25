// SPDX-License-Identifier: MPL-2.0
//! The JH7110's own RTC as the clock - the VisionFive 2's: seconds to
//! years in BCD, counted from the board's 32.768 kHz oscillator for as
//! long as the board has power. The board has no cell for it, so a power
//! cut loses the date.
//!
//! **A reset stops it, and keeps the date.** The chip's reset - the
//! watchdog's, which ColdReboot is - puts the always-on domain's clock
//! and reset generator back as a power-on leaves it: the RTC held in
//! reset, and once let go not counting. Its time and date keep what they
//! held as the reset came, and the timebase starts again from nought at
//! that moment. So at the resource's start the date is the one kept plus
//! the timebase's count - plus half a second, since the date kept is the
//! second the reset came in, not its end - and the RTC is set to that
//! and counts on.
//!
//! A power-on leaves registers that hold no date, or by chance one: a
//! digit that is no BCD digit, or a day or a month out of range, is no
//! date. "No date" is kept as day 0, which a reset keeps as it keeps a
//! date.
//!
//!   0x00  CFG        bit 0 counting, bit 3 hours to 24
//!   0x14  IRQ_EVENT  bit 31 written: CFG_TIME and CFG_DATE taken over
//!   0x28  CFG_TIME   the time to set, as TIME has it
//!   0x2C  CFG_DATE   the date to set, as DATE has it
//!   0x3C  TIME       the seconds in bits 0-6, the minutes 7-13, the
//!                    hours 14-20
//!   0x40  DATE       the day in bits 0-5, the month 6-10, the year
//!                    since 2000 11-18
//!
//! It covers 2000 to 2099. Its clocks and resets are the always-on
//! generator's: RTC_APB (clock 10) for its registers, which U-Boot leaves
//! running, and the resets RTC_APB, RTC_CAL and RTC_32K, which a reset
//! holds. The count's own clock, RTC_32K, is the board's oscillator as
//! the chip comes up.
//!
//! The registers and their fields as Linux's driver has them (StarFive's
//! rtc-starfive.c); what a reset leaves, as read from the VisionFive 2.

const sdk = @import("sdk");
const utility = sdk.utility;
const reg = sdk.hardware.mmio.reg;
const system = sdk.hardware.system;
const systimer = sdk.hardware.systimer;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

const CFG: usize = 0x00;
const IRQ_EVENT: usize = 0x14;
const CFG_TIME: usize = 0x28;
const CFG_DATE: usize = 0x2C;
const TIME: usize = 0x3C;
const DATE: usize = 0x40;

const CFG_ENABLE: u32 = 1 << 0;
const CFG_HOURS_24: u32 = 1 << 3;
const EVENT_LOAD: u32 = 1 << 31;

/// How long a date set is waited for in TIME and DATE at the most.
const load_us: u64 = 2000;

/// The time and the date registers.
pub const Registers = struct { time: u32, date: u32 };

/// No date: day 0.
const no_date: Registers = .{ .time = 0, .date = 0 };

fn fromBcd(value: u32) ?u16 {
    const tens = value >> 4;
    const ones = value & 0x0F;
    if (tens > 9 or ones > 9) return null;
    return @intCast(tens * 10 + ones);
}

fn toBcd(value: u16) u32 {
    return @as(u32, value / 10) << 4 | value % 10;
}

/// The date the registers hold, or null for none (see the file's head).
/// The weekday is left 0; Date2Amiga does not read it.
pub fn dateOf(regs: Registers) ?utility.ClockData {
    const date: utility.ClockData = .{
        .sec = fromBcd(regs.time & 0x7F) orelse return null,
        .min = fromBcd(regs.time >> 7 & 0x7F) orelse return null,
        .hour = fromBcd(regs.time >> 14 & 0x7F) orelse return null,
        .mday = fromBcd(regs.date & 0x3F) orelse return null,
        .month = fromBcd(regs.date >> 6 & 0x1F) orelse return null,
        .year = 2000 + (fromBcd(regs.date >> 11 & 0xFF) orelse return null),
    };
    if (date.sec > 59 or date.min > 59 or date.hour > 23) return null;
    if (date.mday < 1 or date.mday > 31 or date.month < 1 or date.month > 12) return null;
    return date;
}

/// The registers for `date`, which lies in 2000 to 2099.
pub fn registersOf(date: utility.ClockData) Registers {
    return .{
        .time = toBcd(date.hour) << 14 | toBcd(date.min) << 7 | toBcd(date.sec),
        .date = toBcd(date.year - 2000) << 11 | toBcd(date.month) << 6 | toBcd(date.mday),
    };
}

/// The registers for `seconds` since 1 January 1978: a date before 2000
/// is no date, one past 2099 the last second of 2099.
pub fn registersAt(ub: *UtilityBase, seconds: u32) Registers {
    var date: utility.ClockData = .{};
    ub.Amiga2Date(seconds, &date);
    if (date.year < 2000) return no_date;
    if (date.year > 2099) date = .{ .sec = 59, .min = 59, .hour = 23, .mday = 31, .month = 12, .year = 2099 };
    return registersOf(date);
}

const resets = [_]u32{ system.AONRST_RTC_APB, system.AONRST_RTC_CAL, system.AONRST_RTC_32K };

/// The RTC clocked and out of reset: false if it did not come out. The
/// generator's words are shared, so they change under Disable.
fn wake(sys: *ExecBase) bool {
    sys.Disable();
    system.clockOn(.aon, system.AONCLK_RTC_APB);
    for (resets) |reset| system.releaseReset(.aon, reset);
    sys.Enable();
    for (resets) |reset| {
        if (!system.waitOutOfReset(.aon, reset)) return false;
    }
    return true;
}

/// Whether the RTC at `base` counts.
pub fn counting(base: usize) bool {
    return reg(base + CFG).* & CFG_ENABLE != 0;
}

/// The time and the date as the RTC has them: read again when the second
/// turned between the two.
pub fn read(base: usize) Registers {
    while (true) {
        const time = reg(base + TIME).*;
        const date = reg(base + DATE).*;
        if (reg(base + TIME).* == time) return .{ .time = time, .date = date };
    }
}

/// The time and the date set, waited for until the RTC has them, and
/// the RTC counting from them - stopped, for no date.
pub fn write(base: usize, regs: Registers) void {
    const cfg = reg(base + CFG);
    cfg.* = cfg.* & ~CFG_ENABLE | CFG_HOURS_24;
    reg(base + CFG_TIME).* = regs.time;
    reg(base + CFG_DATE).* = regs.date;
    reg(base + IRQ_EVENT).* = EVENT_LOAD;
    const until = systimer.uptimeUs() + load_us;
    while (systimer.uptimeUs() < until) {
        if (reg(base + TIME).* == regs.time and reg(base + DATE).* == regs.date) break;
    }
    if (regs.date != no_date.date) cfg.* |= CFG_ENABLE;
}

/// The RTC at `base` at the resource's start: woken; and stopped by a
/// reset with a date kept, set to that date and the time since and
/// counting again. One that counts still saw no reset since it was set,
/// and goes on as it is. False if it would not come out of reset.
pub fn start(sys: *ExecBase, ub: *UtilityBase, base: usize) bool {
    if (!wake(sys)) return false;
    if (counting(base)) return true;
    const kept = dateOf(read(base)) orelse {
        write(base, no_date);
        return true;
    };
    // Half a second for the second the reset came in, half to round.
    const since_reset: u32 = @intCast((systimer.uptimeUs() + 1_000_000) / 1_000_000);
    write(base, registersAt(ub, ub.Date2Amiga(&kept) +| since_reset));
    return true;
}
