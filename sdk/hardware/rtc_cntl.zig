// SPDX-License-Identifier: MIT
//! RTC_CNTL's registers that the system uses: the chip's software reset.
//!
//! Only names and numbers: nothing here touches the hardware.

const map = @import("map.zig");

pub const OPTIONS0: usize = map.RTC_CNTL + 0x00;

// OPTIONS0
/// Resets the whole chip, both cores and every peripheral.
pub const OPTIONS0_SW_SYS_RST: u32 = 1 << 31;
