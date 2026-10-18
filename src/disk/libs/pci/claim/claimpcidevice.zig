// SPDX-License-Identifier: MIT
//! ClaimPCIDevice: a function taken by a driver.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");
const _state = @import("../host/_state.zig");

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
/// PCIDevice (`owner`) until ReleasePCIDevice.
///
/// A function that was reset since the library set it up - its BARs or
/// what it decodes are not what they were - has what the library set up
/// in it written back first, and the library says so on the debug
/// output. A function resets itself where its link goes down and comes
/// back, as it does when its power dips. Otherwise nothing of the
/// function is changed.
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
/// A function reset while a driver has it is the driver's to notice - its
/// registers behind the BARs no longer answer - and ResetPCIDevice puts
/// it back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleasePCIDevice`, `FindPCIClass`, `ResetPCIDevice`
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
    const entry = _host.entryOf(device);
    if (device.header_type == pci.PCI_HEADER_NORMAL and _state.lost(entry, &entry.kept)) {
        sdk.exec.kprintf(sys, "%s: %ld/%ld:%ld.%ld was reset since it was set up; set up again\n", .{ pci.PCINAME, @as(i64, device.segment), @as(i64, device.bus), @as(i64, device.device), @as(i64, device.function) });
        _state.restore(entry, &entry.kept);
    }
    return null;
}
