// SPDX-License-Identifier: MPL-2.0
//! The BCM2712's own temperature sensor, in its AVS monitor: one
//! register, which the chip keeps up to date by itself - nothing to start.
//! Its low 10 bits are the last conversion, and bits 10 and 16 say there
//! is one. A conversion is 450 - 0.55 * code degrees Celsius: the
//! coefficients of Linux's cpu-thermal zone for the BCM2712, which its
//! driver (bcm2711_thermal.c) reads the same register with.
//!
//! Its limits: hot at 80 degrees, where the VideoCore's firmware begins
//! to slow the cores, as Raspberry Pi documents it; critical at 110, the
//! zone's critical trip.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;

/// AVS_RO_TEMP_STATUS, from the monitor's start.
const TEMP_STATUS: usize = 0x200;
const VALID: u32 = (1 << 16) | (1 << 10);
const CODE_MASK: u32 = 0x3FF;

/// The conversion's slope and offset, in thousandths of a degree.
const slope: i32 = -550;
const offset: i32 = 450_000;

/// The limits, in thousandths of a degree.
pub const hot: i32 = 80_000;
pub const critical: i32 = 110_000;

/// The last conversion in thousandths of a degree; null while there is
/// none.
pub fn read(base: usize) ?i32 {
    const status = reg(base + TEMP_STATUS).*;
    if (status & VALID == 0) return null;
    return millicelsius(status & CODE_MASK);
}

/// A conversion in thousandths of a degree.
pub fn millicelsius(code: u32) i32 {
    return slope * @as(i32, @intCast(code)) + offset;
}
