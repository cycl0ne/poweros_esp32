// SPDX-License-Identifier: MIT
//! RemPCIVectorServer: a server taken off one of a function's vectors.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");
const _vectors = @import("_vectors.zig");

/// A server taken off one of a function's vectors.
///
/// SYNOPSIS:
/// ```zig
/// fn RemPCIVectorServer(base: *PCIBase, device: *pci.PCIDevice, vector: u32, server: *exec.Interrupt) void
/// ```
///
/// SINCE: 2.0. LVO -72.
///
/// INPUTS:
/// - `device` - the function AddPCIVectorServer put it on.
/// - `vector` - the vector it put it on.
/// - `server` - the server.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The server is off the vector's chain when this returns and is not
/// run again. A vector with no server left is masked at the function,
/// and the host bridge's interrupt let go once nothing is on it.
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
/// The vector stays the function's: AddPCIVectorServer may put a server
/// on it again. FreePCIVectors gives it back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddPCIVectorServer`, `FreePCIVectors`
///
/// EXAMPLES:
/// ```zig
/// pb.RemPCIVectorServer(function, 0, &unit.server);
/// ```
pub fn RemPCIVectorServer(_: *PCIBase, device: *pci.PCIDevice, vector: u32, server: *exec.Interrupt) void {
    if (vector >= device.vectors) return;
    const entry = _host.entryOf(device);
    _host.remVectorServer(entry.host, @intCast(entry.vector_base + vector), server);
    if (!_vectors.hasServer(entry, vector)) _vectors.mask(entry, vector, true);
}
