// SPDX-License-Identifier: MIT
//! battmem.resource: a few hundred bits of settings that are there before
//! any file can be read, and that whoever cannot read a file can read -
//! a file system handler, which would wait on itself if the file were on
//! its own volume. Get its base with OpenResource(BATTMEMNAME); its
//! functions are in sdk/interface/battmem.zig, and which bits hold what is
//! battmembits.zig.
//!
//! The bits are kept where a reset leaves them: the ESP32-S3's RTC slow
//! memory, the ESP32-P4's LP RAM. A power-on clears them there, and on a
//! chip with no such memory (the rv64sbi machines) every start does: what
//! should outlive that is kept in a file as well, and the startup
//! sequence writes it here (`C:SetClock ZONE` for the time zone). Bits
//! nobody wrote are 0.

/// The resource's name, for OpenResource.
pub const BATTMEMNAME = "battmem.resource";

/// How many bits it keeps: 56 bytes' worth on every chip.
pub const BATTMEM_BITS: u32 = 448;

/// What ReadBattMem and WriteBattMem answer: 0 when done, or this when
/// the bits asked for run past BATTMEM_BITS - and then nothing is done.
pub const BATTMEMERR_RANGE: u32 = 1;

/// The resource's base, with its functions.
pub const BattMemBase = @import("../interface/battmem.zig").BattMemBase;
