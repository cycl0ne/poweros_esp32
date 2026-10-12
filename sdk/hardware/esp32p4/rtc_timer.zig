// SPDX-License-Identifier: MIT
//! The RTC timer, LP_TIMER's main timer: a 48-bit count of the LP slow
//! clock's cycles, in the low-power domain, so it goes on counting
//! through every reset short of a power-on - a software reset, a
//! watchdog's, a Guru's. The slow clock is the chip's internal RC
//! oscillator, about 136 kHz and not exact: the count's rate is found by
//! timing it against the system timer.
//!
//! LP RAM - 32 KiB at 0x5010_8000 - keeps through the same resets;
//! `clock_memory` is the part of it a clock that runs on this count keeps
//! its reckoning in.
//!
//! From ESP-IDF v6.1's hal/rtc_timer_ll.h and soc/lp_timer_reg.h.

const map = @import("map.zig");
const reg = @import("mmio.zig").reg;

/// LP_TIMER_UPDATE: writing MAIN_TIMER_UPDATE copies the count into
/// MAIN_BUF0_LOW and MAIN_BUF0_HIGH.
const UPDATE: usize = map.LP_TIMER + 0x10;
const MAIN_TIMER_UPDATE: u32 = 1 << 28;
const MAIN_BUF0_LOW: usize = map.LP_TIMER + 0x14;
/// The count's top 16 bits.
const MAIN_BUF0_HIGH: usize = map.LP_TIMER + 0x18;

/// The count now.
pub fn count() u64 {
    reg(UPDATE).* = MAIN_TIMER_UPDATE;
    const low = reg(MAIN_BUF0_LOW).*;
    const high = reg(MAIN_BUF0_HIGH).* & 0xFFFF;
    return @as(u64, high) << 32 | low;
}

/// LP RAM past its first 4 KiB, which the last words of a Guru keep: 64
/// bytes for the clock's reckoning.
pub const clock_memory: usize = 0x5010_9000;
pub const clock_memory_size: usize = 64;
