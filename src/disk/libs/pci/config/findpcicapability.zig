// SPDX-License-Identifier: MIT
//! FindPCICapability: where a function's capability is.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");
const scan = @import("../scan/scan.zig");

/// Where a function's capability is, on the list its configuration space
/// starts at PCI_CAPABILITY_LIST.
///
/// SYNOPSIS:
/// ```zig
/// fn FindPCICapability(base: *PCIBase, device: *pci.PCIDevice, id: u32, after: u32) u32
/// ```
///
/// SINCE: 2.0. LVO -52.
///
/// INPUTS:
/// - `device` - from FindPCIDevice or FindPCIClass.
/// - `id` - the capability's ID (PCI_CAP_ID_*).
/// - `after` - 0 for the first with that ID; where one was found, for the
///   next after it.
///
/// RESULT:
/// Where the capability starts in the function's configuration space -
/// its ID byte, the next one's pointer after it; 0 for none.
///
/// BEHAVIOR:
/// The list is followed as the function has it, from PCI_CAPABILITY_LIST
/// or from the capability at `after`: a function whose status says it
/// has no list has none, and a list that runs in a circle ends after the
/// 48 a configuration space has room for.
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
/// A function may have more than one capability with an ID - vendor
/// specific ones (PCI_CAP_ID_VNDR) most of all: `after` goes through
/// them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindPCIExtCapability`, `ReadPCIConfig`
///
/// EXAMPLES:
/// ```zig
/// const pm = pb.FindPCICapability(function, pci.PCI_CAP_ID_PM, 0);
/// if (pm != 0) power = pb.ReadPCIConfig(function, pm + pci.PCI_PM_CTRL, 2);
/// ```
pub fn FindPCICapability(_: *PCIBase, device: *pci.PCIDevice, id: u32, after: u32) u32 {
    if (id > 0xFF or after >= pci.PCI_CFG_SPACE_SIZE) return 0;
    const entry = _host.entryOf(device);
    const space = _host.Space{ .host = entry.host };
    return scan.findCapability(space, _host.addressOf(device), @intCast(id), after) orelse 0;
}
