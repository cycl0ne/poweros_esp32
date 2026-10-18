// SPDX-License-Identifier: MIT
//! RemPCIIntServer: a server taken off a function's INTx line.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");

/// A server taken off a function's INTx line.
///
/// SYNOPSIS:
/// ```zig
/// fn RemPCIIntServer(base: *PCIBase, device: *pci.PCIDevice, server: *exec.Interrupt) void
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `device` - the function AddPCIIntServer put it on.
/// - `server` - the server.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The server is off its chain when this returns and is not run again.
/// Where the bridge gathers the lines, a line with no server left is
/// masked, and the bridge's interrupt let go once no line has one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It takes Disable.
/// - Locks: takes Disable.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The `Interrupt` is the caller's again.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddPCIIntServer`
///
/// EXAMPLES:
/// ```zig
/// pb.RemPCIIntServer(function, &unit.server);
/// ```
pub fn RemPCIIntServer(_: *PCIBase, device: *pci.PCIDevice, server: *exec.Interrupt) void {
    const entry = _host.entryOf(device);
    if (entry.root_pin == 0 or device.interrupt == 0) return;
    _host.remServer(entry, server);
}
