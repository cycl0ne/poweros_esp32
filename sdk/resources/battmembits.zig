// SPDX-License-Identifier: MIT
//! Which of battmem.resource's bits hold what: each setting's first bit
//! and how many it takes, for ReadBattMem and WriteBattMem. A setting
//! nobody wrote reads as 0, so 0 is each one's default.

/// The system's time zone, as dos.timezone.pack makes it (0 is UTC): the
/// rule the system clock keeps local time by, for the file systems that
/// write a moment with its offset from UTC (exFAT). `C:SetClock ZONE`
/// writes it from ENVARC:Sys/timezone. Read into a u64 it is the number.
pub const BATTMEM_ZONE_ADDR: u32 = 0;
pub const BATTMEM_ZONE_LEN: u32 = 64;
