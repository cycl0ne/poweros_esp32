// SPDX-License-Identifier: MPL-2.0
//! TxColor: A command and a run of pixels.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;

/// Sends a command and a run of pixels to the part on a bus.
///
/// SYNOPSIS:
/// ```zig
/// fn TxColor(_: *RtgBase, io: *rtg.RtgTransport, cmd: i32, color: ?*const anyopaque, size: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -184.
///
/// INPUTS:
/// - `io` - the transport.
/// - `cmd` - the command.
/// - `color` - the pixel bytes.
/// - `size` - how many.
///
/// RESULT:
/// `RTGERR_OK`, `RTGERR_NOT_SUPPORTED`, or what the driver answered -
/// `RTGERR_UNDERRUN` among them: every byte went out, but some of them
/// were not the ones given.
///
/// BEHAVIOR:
/// It comes back when the bytes have gone: the bus has been waited for.
///
/// CONTEXT:
/// - Waits: yes, for the bus.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes stay the caller's, and are no longer read when this returns.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `TxParam`, `RxParam`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.TxColor(io, 0x2C, row.ptr, row.len);
/// ```
pub fn TxColor(_: *RtgBase, io: *rtg.RtgTransport, cmd: i32, color: ?*const anyopaque, size: u32) i32 {
    const ops = io.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const tx = ops.tx_color orelse return err.RTGERR_NOT_SUPPORTED;
    return tx(io, cmd, color, size);
}
