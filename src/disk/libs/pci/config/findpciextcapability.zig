// SPDX-License-Identifier: MIT
//! FindPCIExtCapability: where a PCI Express function's extended
//! capability is.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");
const scan = @import("../scan/scan.zig");

/// Where a PCI Express function's extended capability is, on the list
/// from 0x100 of its 4 KiB.
///
/// SYNOPSIS:
/// ```zig
/// fn FindPCIExtCapability(base: *PCIBase, device: *pci.PCIDevice, id: u32, after: u32) u32
/// ```
///
/// SINCE: 2.0. LVO -56.
///
/// INPUTS:
/// - `device` - from FindPCIDevice or FindPCIClass.
/// - `id` - the extended capability's ID (PCI_EXT_CAP_ID_*).
/// - `after` - 0 for the first with that ID; where one was found, for the
///   next after it.
///
/// RESULT:
/// Where the capability's header is in the function's configuration
/// space - its ID in the low 16 bits, its version, and the next one's
/// offset in the top 12; 0 for none.
///
/// BEHAVIOR:
/// The list is followed from 0x100, or from the capability at `after`.
/// A function without the PCI Express capability has no extended space
/// (`express_type` PCI_EXP_TYPE_NONE) and none; one whose extended space
/// reads all ones or nothing has none either.
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
/// The list holds what the function has, Advanced Error Reporting, its
/// serial number (PCI_EXT_CAP_ID_DSN), the resizable BAR, L1 substates,
/// and vendor specific ones among them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindPCICapability`, `ReadPCIConfig`
///
/// EXAMPLES:
/// ```zig
/// const dsn = pb.FindPCIExtCapability(function, pci.PCI_EXT_CAP_ID_DSN, 0);
/// if (dsn != 0) low = pb.ReadPCIConfig(function, dsn + 4, 4);
/// ```
pub fn FindPCIExtCapability(_: *PCIBase, device: *pci.PCIDevice, id: u32, after: u32) u32 {
    if (device.express_type == pci.PCI_EXP_TYPE_NONE) return 0;
    if (id > 0xFFFF or (after != 0 and (after < pci.PCI_CFG_SPACE_SIZE or after >= pci.PCI_CFG_SPACE_EXP_SIZE))) return 0;
    const entry = _host.entryOf(device);
    const space = _host.Space{ .host = entry.host };
    return scan.findExtCapability(space, _host.addressOf(device), @intCast(id), after) orelse 0;
}
