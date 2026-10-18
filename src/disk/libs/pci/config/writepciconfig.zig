// SPDX-License-Identifier: MIT
//! WritePCIConfig: a register of a function's configuration space set.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");
const _config = @import("_config.zig");

/// A register of a function's configuration space, written.
///
/// SYNOPSIS:
/// ```zig
/// fn WritePCIConfig(base: *PCIBase, device: *pci.PCIDevice, offset: u32, size: u32, value: u32) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `device` - a function the caller has claimed.
/// - `offset` - where in its 4 KiB (PCI_*), a multiple of `size`.
/// - `size` - 1, 2 or 4 bytes.
/// - `value` - what is written, its low `size` bytes.
///
/// RESULT:
/// Nothing. A size or an offset that is not one writes nothing.
///
/// BEHAVIOR:
/// One write of the register, as wide as asked: the bytes beside it are
/// not touched, so a status's write-one-to-clear bits stay as they are
/// when its command is written.
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
/// The BARs and a bridge's bus numbers and windows are the library's, set
/// as it walked the buses; a driver that moves them is on its own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadPCIConfig`, `ClaimPCIDevice`
///
/// EXAMPLES:
/// ```zig
/// const command = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
/// pb.WritePCIConfig(function, pci.PCI_COMMAND, 2, command | pci.PCI_COMMAND_MASTER);
/// ```
pub fn WritePCIConfig(_: *PCIBase, device: *pci.PCIDevice, offset: u32, size: u32, value: u32) void {
    if (!_config.sound(offset, size)) return;
    const entry = _host.entryOf(device);
    _host.write(entry.host, _host.addressOf(device), offset, size, value);
}
