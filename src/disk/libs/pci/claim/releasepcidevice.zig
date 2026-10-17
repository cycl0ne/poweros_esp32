// SPDX-License-Identifier: MIT
//! ReleasePCIDevice: a claimed function given back.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");

/// A claimed function given back, its bus mastering off.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleasePCIDevice(base: *PCIBase, device: *pci.PCIDevice) void
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `device` - a function the caller claimed.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The claim is taken off the record, and the function's bus mastering
/// switched off: what it was set up to move into memory cannot reach
/// memory a driver no longer holds. Its memory decoding stays on.
///
/// CONTEXT:
/// - Waits: yes, for the library's claim lock.
/// - Interrupts: no.
/// - Locks: takes the claim lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The function is free for the next driver.
///
/// NOTES:
/// Its interrupt servers are the driver's to take off first
/// (RemPCIIntServer).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ClaimPCIDevice`
///
/// EXAMPLES:
/// ```zig
/// pb.RemPCIIntServer(function, &server);
/// pb.ReleasePCIDevice(function);
/// ```
pub fn ReleasePCIDevice(base: *PCIBase, device: *pci.PCIDevice) void {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.claim_lock);
    defer sys.ReleaseSemaphore(&base.claim_lock);
    const entry = _host.entryOf(device);
    const at = _host.addressOf(device);
    const command = _host.read(entry.host, at, pci.PCI_COMMAND, 2);
    _host.write(entry.host, at, pci.PCI_COMMAND, 2, command & ~@as(u32, pci.PCI_COMMAND_MASTER));
    device.owner = null;
}
