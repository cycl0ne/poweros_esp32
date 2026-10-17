// SPDX-License-Identifier: MIT
//! AddPCIIntServer: a server on a function's INTx line.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");

/// A server run whenever a function raises its INTx line.
///
/// SYNOPSIS:
/// ```zig
/// fn AddPCIIntServer(base: *PCIBase, device: *pci.PCIDevice, server: *exec.Interrupt) bool
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `device` - a function the caller has claimed.
/// - `server` - an `Interrupt` whose `code` is an `IntServerFn`, as
///   AddIntServer takes one.
///
/// RESULT:
/// True when the server is on the line; false for a function that has
/// no INTx line (`interrupt_pin` 0).
///
/// BEHAVIOR:
/// Where the host bridge's lines are sources of the interrupt controller
/// of their own (QEMU's), the server goes on the source's chain with
/// AddIntServer. Where the bridge gathers them on one interrupt (the
/// JH7110's), it goes on the library's chain for the line, which the
/// library's own server on the bridge's interrupt runs whenever the
/// bridge has seen the line raised; the bridge's interrupt is hooked
/// with the first server and the line let through.
///
/// Either way the server is run as AddIntServer runs it, with the exec
/// interrupt number the line ends up on, and answers non-zero when the
/// interrupt was its function's: the line may be shared with other
/// functions, whose servers come after.
///
/// CONTEXT:
/// - Waits: no. The server itself must not wait.
/// - Interrupts: safe. It takes Disable.
/// - Locks: takes Disable, which guards the chains.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The `Interrupt` stays the caller's and must outlive its place on the
/// chain: RemPCIIntServer before it goes.
///
/// NOTES:
/// INTx is a level: a server makes its function let go of the line
/// before it answers, or it is run again at once.
///
/// BUGS:
/// MSI and MSI-X are not set up: every function interrupts on its INTx
/// line.
///
/// SEE ALSO:
/// `RemPCIIntServer`, `AddIntServer`
///
/// EXAMPLES:
/// ```zig
/// unit.server = .{ .node = .{ .type = .interrupt, .name = "xhci.device" }, .data = unit, .code = @ptrCast(&intServer) };
/// if (!pb.AddPCIIntServer(function, &unit.server)) return poll(unit);
/// ```
pub fn AddPCIIntServer(_: *PCIBase, device: *pci.PCIDevice, server: *exec.Interrupt) bool {
    const entry = _host.entryOf(device);
    if (entry.root_pin == 0 or device.interrupt == 0) return false;
    _host.addServer(entry, server);
    return true;
}
