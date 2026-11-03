// SPDX-License-Identifier: MIT
//! Where the machine's fixed parts are. Almost nothing on this machine is
//! fixed - what is behind the PCI bridge moves from board to board, and the
//! interrupt controllers' addresses are in the firmware's tables - so this
//! holds only the few addresses that have been in the same place since the
//! architecture had them, and the addresses the controllers are at unless
//! the tables say otherwise. The kernel takes the board's and the tables'
//! figures as it starts.

/// The serial ports, as I/O ports rather than addresses: the first is the
/// console unless the board says another.
pub const COM1: u16 = 0x3F8;
pub const COM2: u16 = 0x2F8;
pub const COM3: u16 = 0x3E8;
pub const COM4: u16 = 0x2E8;

/// The clock every one of them divides, fixed since the part was a
/// separate chip: 1.8432 MHz, which with the divisor 1 gives 115200 baud.
pub const UART_CLOCK_HZ: u32 = 1_843_200;

/// The reset control register, in the port space: the way to restart the
/// machine without the firmware's help.
pub const RESET_CONTROL: u16 = 0x0CF9;

/// Where a core's own interrupt controller is mapped unless a model
/// register says otherwise, and where the machine's is unless the
/// firmware's tables say otherwise.
pub const LAPIC: usize = 0xFEE0_0000;
pub const IOAPIC: usize = 0xFEC0_0000;

/// Where RAM may be: from the bottom of the address space to well past the
/// end of what any machine this runs on has. The kernel maps what the
/// firmware called memory, and nothing else, as memory.
pub const DRAM_START: usize = 0x0000_0000;
pub const DRAM_END: usize = 0x1_0000_0000_0000;
