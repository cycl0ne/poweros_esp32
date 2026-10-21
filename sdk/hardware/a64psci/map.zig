// SPDX-License-Identifier: MIT
//! Where the peripherals are when the board says nothing else: QEMU's
//! virt. The kernel takes the board's addresses as it starts.

/// The GIC's distributor and CPU interface.
pub const GICD: usize = 0x0800_0000;
pub const GICC: usize = 0x0801_0000;
/// The first UART, the console: a PL011.
pub const UART0: usize = 0x0900_0000;

/// Where RAM may be on either machine: from the bottom of the address
/// space - the BCM2712's starts at 0 - to well past the end of the
/// largest either has. The MMU maps every address in it that is RAM as
/// normal memory, which takes atomic instructions.
pub const DRAM_START: usize = 0x0000_0000;
pub const DRAM_END: usize = 0x10_0000_0000;
