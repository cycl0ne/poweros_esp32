// SPDX-License-Identifier: MIT
//! AllocPCIVectors: message-signalled interrupts for a function.

const sdk = @import("sdk");
const pci = sdk.pci;
const PCIBase = @import("../pci_base.zig").PCIBase;
const _host = @import("../host/_host.zig");
const _vectors = @import("_vectors.zig");

/// Message-signalled interrupts for a function, MSI-X where it has it,
/// MSI otherwise.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocPCIVectors(base: *PCIBase, device: *pci.PCIDevice, count: u32) u32
/// ```
///
/// SINCE: 2.0. LVO -60.
///
/// INPUTS:
/// - `device` - a function the caller has claimed.
/// - `count` - how many vectors the driver can use, from 1.
///
/// RESULT:
/// How many vectors the function got, 1 to `count`: its vectors 0 to
/// that less one, which AddPCIVectorServer hooks. 0 for none: the host
/// bridge takes no messages, the function sends none, or the bridge's
/// vectors are given to other functions - and the function keeps its
/// INTx line, which AddPCIIntServer hooks.
///
/// BEHAVIOR:
/// The host bridge's vectors are given out in runs. With MSI-X the
/// function gets as many as it has table entries, the driver asks for,
/// and the bridge has free; each entry is written with the bridge's
/// address and its vector, and masked. With MSI it gets the largest
/// power of two of them that is no more than that, aligned to its size,
/// as MSI has the function count them; each vector is masked where the
/// function can mask them one by one. Either way the function's MSI or
/// MSI-X is switched on and its INTx off (PCI_COMMAND_INTX_DISABLE), and
/// `vector_kind` and `vectors` in its PCIDevice say what it has.
///
/// A vector is let through once a server is on it (AddPCIVectorServer),
/// and masked again once none is.
///
/// A function that has vectors already gets no more: the result is how
/// many it has.
///
/// CONTEXT:
/// - Waits: yes, for the library's claim lock.
/// - Interrupts: no.
/// - Locks: takes the claim lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The vectors are the function's until FreePCIVectors or
/// ReleasePCIDevice, which gives them back.
///
/// NOTES:
/// What a function signals with each of its vectors is its own: an NVMe
/// controller one queue each, an xHCI one interrupter each. A driver
/// that asks for one has every event on vector 0.
///
/// The MSI-X table is in one of the function's BARs: where that one was
/// not placed, or its memory is not decoded, MSI is tried.
///
/// BUGS:
/// QEMU's virt machine as the library knows it has no bridge that takes
/// messages: every function there gets 0 and keeps its INTx line.
///
/// SEE ALSO:
/// `AddPCIVectorServer`, `FreePCIVectors`, `AddPCIIntServer`
///
/// EXAMPLES:
/// ```zig
/// if (pb.AllocPCIVectors(function, 1) == 1 and pb.AddPCIVectorServer(function, 0, &unit.server)) return;
/// _ = pb.AddPCIIntServer(function, &unit.server);
/// ```
pub fn AllocPCIVectors(base: *PCIBase, device: *pci.PCIDevice, count: u32) u32 {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.claim_lock);
    defer sys.ReleaseSemaphore(&base.claim_lock);
    return _vectors.allocate(_host.entryOf(device), count);
}
