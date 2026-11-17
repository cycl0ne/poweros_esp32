// SPDX-License-Identifier: MPL-2.0
//! QueueBulk: memory the firmware reads or writes itself, put out.

const sdk = @import("sdk");
const vchiq = sdk.resources.vchiq;
const base = @import("../vchiq_base.zig");
const VchiqBase = base.VchiqBase;
const Service = base.Service;
const queue = @import("../link/_queue.zig");

/// Puts out a bulk transfer, which the firmware does itself.
///
/// SYNOPSIS:
/// ```zig
/// fn QueueBulk(vb: *VchiqBase, service: *VchiqService,
///     bulk: *VchiqBulk) u32
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `service` - as OpenService gave it.
/// - `bulk` - its `data`, `size` and `direction` filled in: for
///   VCHIQBULK_TRANSMIT the bytes the firmware reads, for
///   VCHIQBULK_RECEIVE room for what it writes.
///
/// RESULT:
/// VCHIQERR_OK, and `bulk.done` is signalled once it is done;
/// VCHIQERR_SIZE for no bytes, more than 62 MiB, or memory above
/// 64 GiB; VCHIQERR_BUSY when four bulks of that direction are out on
/// the service, or sixty-four on the queue; VCHIQERR_CLOSED;
/// VCHIQERR_TIMEOUT when the queue was full - and then nothing went out.
///
/// BEHAVIOR:
/// The memory is described to the firmware in a pagelist, its pages by
/// their numbers - it must be one piece, as AllocMem gives it - and is
/// written back from the caches; then a BULK_TX or BULK_RX message goes
/// after the messages before it. The firmware matches it with a transfer
/// of its own on the service: the order of a direction's bulks is the
/// order its transfers come in, which the service's protocol says (an
/// MMAL message, then its bulk). When the firmware is done the
/// resource's task reads what it wrote past the caches and copies over
/// the ends that were not whole cache lines (which the firmware hands
/// over aside), sets `actual` and `result` and signals `done`.
///
/// CONTEXT:
/// - Waits: only while the queue is full.
/// - Interrupts: no.
/// - Locks: the queue's send lock, for the call.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The memory is the firmware's until `done` is signalled: the caller
/// neither reads nor writes it, nor anything else in its first and last
/// 64-byte lines.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WaitBulk`, `SendMessage`
///
/// EXAMPLES:
/// ```zig
/// var bulk: vchiq.VchiqBulk = .{ .data = frame, .size = bytes, .direction = vchiq.VCHIQBULK_RECEIVE };
/// if (vb.QueueBulk(mmal, &bulk) == vchiq.VCHIQERR_OK) _ = vb.WaitBulk(&bulk, 1_000_000);
/// ```
pub fn QueueBulk(vb: *VchiqBase, service: *vchiq.VchiqService, bulk: *vchiq.VchiqBulk) u32 {
    return queue.queueBulk(vb, Service.of(service), bulk);
}
