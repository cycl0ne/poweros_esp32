// SPDX-License-Identifier: MIT
//! ClaimPCIDevice: a function taken by a driver.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;

/// A function taken by the driver that is to use it.
///
/// SYNOPSIS:
/// ```zig
/// fn ClaimPCIDevice(base: *PCIBase, device: *pci.PCIDevice, owner: [*:0]const u8) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `device` - from FindPCIDevice or FindPCIClass.
/// - `owner` - the driver's name, as a listing shows it: "xhci.device".
///
/// RESULT:
/// Null when the function is the caller's now; the name of the driver
/// that has it otherwise.
///
/// BEHAVIOR:
/// One driver at a time has a function: the claim is on record in its
/// PCIDevice (`owner`) until ReleasePCIDevice. Nothing of the function
/// is changed.
///
/// CONTEXT:
/// - Waits: yes, for the library's claim lock.
/// - Interrupts: no.
/// - Locks: takes the claim lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `owner` is kept, not copied: it lives as long as the claim.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleasePCIDevice`, `FindPCIClass`
///
/// EXAMPLES:
/// ```zig
/// if (pb.ClaimPCIDevice(function, "xhci.device")) |holder| return fail(holder);
/// ```
pub fn ClaimPCIDevice(base: *PCIBase, device: *pci.PCIDevice, owner: [*:0]const u8) ?[*:0]const u8 {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.claim_lock);
    defer sys.ReleaseSemaphore(&base.claim_lock);
    if (device.owner) |holder| return holder;
    device.owner = owner;
    return null;
}
