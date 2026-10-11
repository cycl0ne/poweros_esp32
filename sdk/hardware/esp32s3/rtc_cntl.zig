// SPDX-License-Identifier: MIT
//! RTC_CNTL's registers that the system uses: the chip's software reset,
//! and the software stall of core 1.
//!
//! Only names and numbers: nothing here touches the hardware.

const map = @import("map.zig");

pub const OPTIONS0: usize = map.RTC_CNTL + 0x00;
/// The second half of each core's software stall.
pub const SW_CPU_STALL: usize = map.RTC_CNTL + 0xBC;

// OPTIONS0
/// Resets the whole chip, both cores and every peripheral.
pub const OPTIONS0_SW_SYS_RST: u32 = 1 << 31;
/// Core 1's software stall, with SW_CPU_STALL's field: stalled while the
/// two hold 0x86 between them, so clearing either lets it run.
pub const OPTIONS0_SW_STALL_APPCPU_C0: u32 = 0x3 << 0;
// SW_CPU_STALL
pub const SW_STALL_APPCPU_C1: u32 = 0x3F << 20;
