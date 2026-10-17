// SPDX-License-Identifier: MIT
//! FindPCIClass: a function by what it is.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;

/// The next function of a class.
///
/// SYNOPSIS:
/// ```zig
/// fn FindPCIClass(base: *PCIBase, previous: ?*pci.PCIDevice, class_code: u32, mask: u32) ?*pci.PCIDevice
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `previous` - where to go on from; null: from the first function.
/// - `class_code` - class, subclass and programming interface, PCI's
///   24-bit class code (PCI_CLASS_*).
/// - `mask` - the bits of it that are compared: PCI_CLASS_MASK for all,
///   0xFF0000 for the class alone.
///
/// RESULT:
/// The function, or null when no more are.
///
/// BEHAVIOR:
/// As FindPCIDevice, in the same order: a function whose class code and
/// `class_code` agree in every bit of `mask`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The function is the library's.
///
/// NOTES:
/// The nth function a driver finds of its class is the unit n it gives
/// that function: xhci.device's units are the xHCI functions in order.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindPCIDevice`, `ClaimPCIDevice`
///
/// EXAMPLES:
/// ```zig
/// const xhci = pb.FindPCIClass(null, pci.PCI_CLASS_SERIAL_USB_XHCI, pci.PCI_CLASS_MASK) orelse return;
/// ```
pub fn FindPCIClass(base: *PCIBase, previous: ?*pci.PCIDevice, class_code: u32, mask: u32) ?*pci.PCIDevice {
    var next = if (previous) |it| it.next else base.first;
    while (next) |it| : (next = it.next) {
        if (it.class_code & mask == class_code & mask) return it;
    }
    return null;
}
