// SPDX-License-Identifier: MPL-2.0
//! battmem.resource: a few hundred bits of settings that are there before
//! any file can be read, and that a file system handler can read without
//! a packet - the time zone, which it cannot read from a file on its own
//! volume without waiting on itself.
//!
//! The bits are kept in the chip's memory that a reset leaves alone - the
//! ESP32-S3's RTC slow memory, the ESP32-P4's LP RAM, in the 64 bytes
//! after battclock.resource's (sdk.hardware.rtc_timer.batt_memory) - with
//! a check sum, so that what a power-on leaves there is taken for no bits
//! at all. A chip with no such memory (the rv64sbi and AArch64 machines)
//! keeps them in the base, from 0 at each start. Which bits hold what is
//! sdk.resources.battmembits.
//!
//! Each call is a file of its own under `bits/`. The jump table is
//! battmem_lvo.zig, the ROM tag and init battmem_init.zig, the base
//! battmem_base.zig. This file holds the names the rest of the kernel
//! reaches the resource by.

const sdk = @import("sdk");
const battmem_base = @import("battmem_base.zig");
const battmem_init = @import("battmem_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from battmem.resource.
comptime {
    _ = &battmem_init.battmem_resource_tag;
}

/// The resource's base.
pub const BattMemBase = battmem_base.BattMemBase;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = battmem_init.RESOURCE_NAME;

test {
    _ = @import("battmem_lvo.zig");
    _ = @import("bits/_bits.zig");
}
