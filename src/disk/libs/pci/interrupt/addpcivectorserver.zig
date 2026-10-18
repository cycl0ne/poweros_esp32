// SPDX-License-Identifier: MIT
//! AddPCIVectorServer: a server on one of a function's vectors.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");
const _vectors = @import("_vectors.zig");

/// A server run whenever a function signals one of its vectors.
///
/// SYNOPSIS:
/// ```zig
/// fn AddPCIVectorServer(base: *PCIBase, device: *pci.PCIDevice, vector: u32, server: *exec.Interrupt) bool
/// ```
///
/// SINCE: 2.0. LVO -68.
///
/// INPUTS:
/// - `device` - a function the caller has claimed, with vectors from
///   AllocPCIVectors.
/// - `vector` - which of them, from 0.
/// - `server` - an `Interrupt` whose `code` is an `IntServerFn`, as
///   AddIntServer takes one.
///
/// RESULT:
/// True when the server is on the vector; false for a vector the
/// function was not given.
///
/// BEHAVIOR:
/// The server goes on the vector's chain, which the host bridge's
/// interrupt runs whenever the function's message for the vector has
/// come - after the bridge's note of it is cleared, so a message that
/// comes while the servers run is seen again. The vector is let through
/// at the function once it has its first server, and the bridge's
/// interrupt hooked.
///
/// The server is run as AddIntServer runs it, with the bridge's exec
/// interrupt number, and answers non-zero when it handled the message;
/// the servers after it on the vector are not run then.
///
/// CONTEXT:
/// - Waits: no. The server itself must not wait.
/// - Interrupts: safe. It takes Disable.
/// - Locks: takes Disable, which guards the chains.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The `Interrupt` stays the caller's and must outlive its place on the
/// chain: RemPCIVectorServer before it goes.
///
/// NOTES:
/// A message is an edge, not a level: the function sends it once, and
/// the server need not quieten anything for it to stop. What the event
/// was is the function's to say - its own registers, its queues.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocPCIVectors`, `RemPCIVectorServer`, `AddPCIIntServer`
///
/// EXAMPLES:
/// ```zig
/// unit.server = .{ .node = .{ .type = .interrupt, .name = "nvme.device" }, .data = unit, .code = @ptrCast(&queueServer) };
/// if (!pb.AddPCIVectorServer(function, 0, &unit.server)) return poll(unit);
/// ```
pub fn AddPCIVectorServer(_: *PCIBase, device: *pci.PCIDevice, vector: u32, server: *exec.Interrupt) bool {
    if (vector >= device.vectors) return false;
    const entry = _host.entryOf(device);
    _host.addVectorServer(entry.host, @intCast(entry.vector_base + vector), server);
    _vectors.mask(entry, vector, false);
    return true;
}
