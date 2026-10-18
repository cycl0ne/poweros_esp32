// SPDX-License-Identifier: MIT
//! FindPCIDevice: a function by its vendor and device.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;

/// The next function made by a vendor, as a device.
///
/// SYNOPSIS:
/// ```zig
/// fn FindPCIDevice(base: *PCIBase, previous: ?*pci.PCIDevice, vendor: u32, device: u32) ?*pci.PCIDevice
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `previous` - where to go on from; null: from the first function.
/// - `vendor` - its vendor ID, or PCI_ANY.
/// - `device` - its device ID, or PCI_ANY.
///
/// RESULT:
/// The function, or null when no more are.
///
/// BEHAVIOR:
/// The functions are in the order the library found them: the board's
/// host bridges one after the other, and behind each its buses in the
/// order they were walked, deep first. With PCI_ANY for both every
/// function comes, bridges too.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed: the chain does not change once the library is
///   open.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The function is the library's, there for as long as the library is
/// open; a driver claims it with ClaimPCIDevice before it uses it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindPCIClass`, `ClaimPCIDevice`
///
/// EXAMPLES:
/// ```zig
/// var it = pb.FindPCIDevice(null, pci.PCI_ANY, pci.PCI_ANY);
/// while (it) |function| : (it = pb.FindPCIDevice(function, pci.PCI_ANY, pci.PCI_ANY)) {
///     list(function);
/// }
/// ```
pub fn FindPCIDevice(base: *PCIBase, previous: ?*pci.PCIDevice, vendor: u32, device: u32) ?*pci.PCIDevice {
    var next = if (previous) |it| it.next else base.first;
    while (next) |it| : (next = it.next) {
        if ((vendor == pci.PCI_ANY or it.vendor_id == vendor) and (device == pci.PCI_ANY or it.device_id == device)) return it;
    }
    return null;
}
