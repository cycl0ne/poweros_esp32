// SPDX-License-Identifier: MIT
//! SYSTIMER's registers: two 52-bit counters (units) at a fixed 16 MHz -
//! the crystal's 40 MHz through a divider of 2.5 - and three alarms
//! (targets) that compare against a unit, once or at a period. The same
//! block, register for register, as the ESP32-S3's. Its clock and reset
//! are HP_SYS_CLKRST's (`system`); the ROM leaves it counting.
//!
//! Names and numbers, and `readUnit0`, which is the register handshake
//! that reading a unit takes. All `inline`.

const map = @import("map.zig");
const mmio = @import("mmio.zig");

/// The rate every unit counts at.
pub const SYSTIMER_HZ = 16_000_000;

pub const CONF: usize = map.SYSTIMER + 0x00;
pub const UNIT0_OP: usize = map.SYSTIMER + 0x04;
pub const TARGET0_HI: usize = map.SYSTIMER + 0x1C;
pub const TARGET0_LO: usize = map.SYSTIMER + 0x20;
pub const TARGET0_CONF: usize = map.SYSTIMER + 0x34;
pub const TARGET1_CONF: usize = map.SYSTIMER + 0x38;
pub const TARGET2_CONF: usize = map.SYSTIMER + 0x3C;
pub const UNIT0_VALUE_HI: usize = map.SYSTIMER + 0x40;
pub const UNIT0_VALUE_LO: usize = map.SYSTIMER + 0x44;
pub const COMP0_LOAD: usize = map.SYSTIMER + 0x50;
pub const COMP1_LOAD: usize = map.SYSTIMER + 0x54;
pub const COMP2_LOAD: usize = map.SYSTIMER + 0x58;
pub const INT_ENA: usize = map.SYSTIMER + 0x64;
pub const INT_RAW: usize = map.SYSTIMER + 0x68;
pub const INT_CLR: usize = map.SYSTIMER + 0x6C;
pub const INT_ST: usize = map.SYSTIMER + 0x70;
/// The block's version, and what it reads after reset.
pub const DATE: usize = map.SYSTIMER + 0xFC;
pub const DATE_RESET: u32 = 0x0220_1073;

// CONF: which alarms run.
pub const CONF_TARGET2_WORK_EN: u32 = 1 << 22;
pub const CONF_TARGET1_WORK_EN: u32 = 1 << 23;
pub const CONF_TARGET0_WORK_EN: u32 = 1 << 24;

// UNIT0_OP: latch the count, then wait until the latched value is valid.
pub const UNIT0_OP_VALUE_VALID: u32 = 1 << 29;
pub const UNIT0_OP_UPDATE: u32 = 1 << 30;

/// TARGETn_HI: the top 20 bits of a 52-bit count.
pub const VALUE_HI_MASK: u32 = 0xF_FFFF;

// TARGETn_CONF: the period (bits 0-25), periodic rather than once, and
// which unit it compares against (bit 31: unit 1).
pub const TARGET_PERIOD_MODE: u32 = 1 << 30;

// INT_*: one bit per alarm.
pub const INT_TARGET0: u32 = 1 << 0;
pub const INT_TARGET1: u32 = 1 << 1;
pub const INT_TARGET2: u32 = 1 << 2;

/// Unit 0's count in microseconds: the time since the chip came up.
pub inline fn uptimeUs() u64 {
    return readUnit0() / (SYSTIMER_HZ / 1_000_000);
}

/// Wait `us` microseconds without giving the CPU away: the wait for code
/// that may not Wait - holding a spinlock, before timer.device, in the
/// boot.
pub inline fn spinUs(us: u64) void {
    const until = uptimeUs() + us;
    while (uptimeUs() < until) {}
}

/// Unit 0's count, in 1/16 us. The latch is given up to a thousand polls,
/// so a unit that is not running answers what it last held rather than
/// hanging.
pub inline fn readUnit0() u64 {
    mmio.reg(UNIT0_OP).* = UNIT0_OP_UPDATE;
    var spins: u32 = 0;
    while (mmio.reg(UNIT0_OP).* & UNIT0_OP_VALUE_VALID == 0 and spins < 1000) : (spins += 1) {}
    const hi: u64 = mmio.reg(UNIT0_VALUE_HI).* & VALUE_HI_MASK;
    const lo: u64 = mmio.reg(UNIT0_VALUE_LO).*;
    return hi << 32 | lo;
}
