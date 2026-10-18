// SPDX-License-Identifier: MIT
//! FreePCIVectors: a function's message-signalled interrupts given back.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");
const _vectors = @import("_vectors.zig");

/// A function's message-signalled interrupts given back, and its INTx
/// line on again.
///
/// SYNOPSIS:
/// ```zig
/// fn FreePCIVectors(base: *PCIBase, device: *pci.PCIDevice) void
/// ```
///
/// SINCE: 2.0. LVO -64.
///
/// INPUTS:
/// - `device` - a function the caller has claimed.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The function's MSI or MSI-X is switched off - MSI-X with every vector
/// masked - and its INTx back on. A server still on one of its vectors
/// is taken off and not run again. The host bridge's vectors are free
/// for the next function, and `vectors` in the PCIDevice is 0 again.
/// Nothing happens to a function that has none.
///
/// CONTEXT:
/// - Waits: yes, for the library's claim lock.
/// - Interrupts: no.
/// - Locks: takes the claim lock, and Disable.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The servers that were on the vectors are the caller's again.
///
/// NOTES:
/// ReleasePCIDevice gives them back too.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocPCIVectors`, `RemPCIVectorServer`
///
/// EXAMPLES:
/// ```zig
/// pb.RemPCIVectorServer(function, 0, &unit.server);
/// pb.FreePCIVectors(function);
/// ```
pub fn FreePCIVectors(base: *PCIBase, device: *pci.PCIDevice) void {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.claim_lock);
    defer sys.ReleaseSemaphore(&base.claim_lock);
    _vectors.free(_host.entryOf(device));
}
