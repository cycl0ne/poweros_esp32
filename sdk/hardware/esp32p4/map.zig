// SPDX-License-Identifier: MIT
//! The peripherals' base addresses: the high-performance peripherals in
//! two blocks, HPPERIPH0 at 0x5000_0000 and HPPERIPH1 at 0x500C_0000.

const hpperiph1: usize = 0x500C_0000;
/// The LP peripherals that stay on.
const lpaon: usize = 0x5011_0000;

pub const TIMG0: usize = hpperiph1 + 0x2000;
pub const TIMG1: usize = hpperiph1 + 0x3000;

pub const UART0: usize = hpperiph1 + 0xA000;
pub const UART1: usize = hpperiph1 + 0xB000;
pub const UART2: usize = hpperiph1 + 0xC000;
pub const UART3: usize = hpperiph1 + 0xD000;
pub const UART4: usize = hpperiph1 + 0xE000;
pub const USB_SERIAL_JTAG: usize = hpperiph1 + 0x12000;
pub const LP_WDT: usize = lpaon + 0x6000;

/// L2MEM, the internal memory: 768 KiB, where exec's locks take their
/// atomic instructions (in PSRAM they go through exec's guard word).
pub const DRAM_START: usize = 0x4FF0_0000;
pub const DRAM_END: usize = 0x4FFC_0000;
