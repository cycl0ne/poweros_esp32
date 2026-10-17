// SPDX-License-Identifier: MPL-2.0
//! No PSRAM: the machine's RAM is one block of DRAM (ram.zig). The names
//! are the ones platform.resource and the shell read.

pub const size: u32 = 0;
pub const vendor: u8 = 0;
pub const base: usize = 0;
