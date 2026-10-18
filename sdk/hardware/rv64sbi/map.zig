// SPDX-License-Identifier: MIT
//! Where the peripherals both machines have are: the same on QEMU's virt
//! and on the JH7110.

/// The platform interrupt controller.
pub const PLIC: usize = 0x0C00_0000;
/// The first UART, the console: a 16550 on QEMU, the DesignWare APB UART
/// (16550-compatible) on the JH7110.
pub const UART0: usize = 0x1000_0000;

/// Where RAM may be on either machine: from the JH7110's start
/// (0x4000_0000) to well past the end of the largest either has. Every
/// address in it that is RAM takes atomic instructions.
pub const DRAM_START: usize = 0x4000_0000;
pub const DRAM_END: usize = 0x10_0000_0000;
