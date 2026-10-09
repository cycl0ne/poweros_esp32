// SPDX-License-Identifier: MIT
//! The interrupt sources, by number: what exec's AddIntServer and
//! SetIntVector take. Their names come with the interrupt matrix's driver.

/// The number of sources: interrupt numbers are 0 to INTB_COUNT - 1.
pub const INTB_COUNT: u32 = 132;
