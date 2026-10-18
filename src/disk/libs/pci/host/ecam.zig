// SPDX-License-Identifier: MIT
//! A host bridge that is nothing but its configuration space and its
//! windows (CHIP_PCI_ECAM): QEMU's "pci-host-ecam-generic", which the
//! emulator has set up before the machine starts. There is nothing to
//! bring up and nothing hidden.
//!
//! Its slots' INTA to INTD are four sources of the interrupt controller
//! from PART_Irq on, rotated by the slot's number - slot 1's INTA is the
//! second, its INTD the first - as the emulator's interrupt map has
//! them, and the PCI-to-PCI bridge architecture's rotation is.

const _host = @import("_host.zig");
const Host = _host.Host;

/// The source line `root_pin` of slot `root_device` is wired to.
pub fn interruptOf(host: *const Host, root_device: u8, root_pin: u8) u32 {
    return host.irq + (@as(u32, root_device) + root_pin - 1) % 4;
}
