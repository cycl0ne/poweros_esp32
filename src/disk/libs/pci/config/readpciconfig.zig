// SPDX-License-Identifier: MIT
//! ReadPCIConfig: a register of a function's configuration space.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");
const _config = @import("_config.zig");

/// A register of a function's configuration space, read.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadPCIConfig(base: *PCIBase, device: *pci.PCIDevice, offset: u32, size: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `device` - from FindPCIDevice or FindPCIClass.
/// - `offset` - where in its 4 KiB (PCI_*), a multiple of `size`.
/// - `size` - 1, 2 or 4 bytes.
///
/// RESULT:
/// The register's value; all ones for a size or an offset that is not
/// one, as a function that is not there answers.
///
/// BEHAVIOR:
/// One read of the register, as wide as asked: a register that changes
/// when it is read - a status that is cleared - is read once.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is kept.
///
/// NOTES:
/// What the library hides of a bridge's own - the JH7110 root port's
/// BAR0 and BAR1 - reads 0.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WritePCIConfig`
///
/// EXAMPLES:
/// ```zig
/// const command = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
/// ```
pub fn ReadPCIConfig(_: *PCIBase, device: *pci.PCIDevice, offset: u32, size: u32) u32 {
    if (!_config.sound(offset, size)) return 0xFFFF_FFFF;
    const entry = _host.entryOf(device);
    return _host.read(entry.host, _host.addressOf(device), offset, size);
}
