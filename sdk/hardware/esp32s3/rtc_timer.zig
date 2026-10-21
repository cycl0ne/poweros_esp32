// SPDX-License-Identifier: MIT
//! The RTC timer: a 48-bit count of the RTC slow clock's cycles, in the
//! RTC domain, so it goes on counting through every reset short of a
//! power-on - a software reset, a watchdog's, a Guru's. The slow clock is
//! the chip's internal RC oscillator, about 136 kHz and not exact: the
//! count's rate is found by timing it against the system timer.
//!
//! RTC slow memory - 8 KiB at 0x5000_0000 - keeps through the same resets;
//! `clock_memory` is the part of it a clock that runs on this count keeps
//! its reckoning in, `batt_memory` the part battmem.resource keeps its
//! bits in.
//!
//! From ESP-IDF v6.1's hal/rtc_timer_ll.h and soc/rtc_cntl_reg.h.

const map = @import("map.zig");
const reg = @import("mmio.zig").reg;

/// RTC_CNTL_TIME_UPDATE: writing TIME_UPDATE copies the count into
/// TIME_LOW0 and TIME_HIGH0.
const TIME_UPDATE: usize = map.RTC_CNTL + 0x0C;
const TIME_UPDATE_BIT: u32 = 1 << 31;
const TIME_LOW0: usize = map.RTC_CNTL + 0x10;
/// The count's top 16 bits.
const TIME_HIGH0: usize = map.RTC_CNTL + 0x14;

/// The count now.
pub fn count() u64 {
    reg(TIME_UPDATE).* = TIME_UPDATE_BIT;
    const low = reg(TIME_LOW0).*;
    const high = reg(TIME_HIGH0).* & 0xFFFF;
    return @as(u64, high) << 32 | low;
}

/// RTC slow memory past its first 4 KiB, which the last words of a
/// Guru keep: 64 bytes for the clock's reckoning.
pub const clock_memory: usize = 0x5000_1000;
pub const clock_memory_size: usize = 64;

/// The 64 bytes after the clock's: battmem.resource's bits.
pub const batt_memory: usize = 0x5000_1040;
pub const batt_memory_size: usize = 64;
