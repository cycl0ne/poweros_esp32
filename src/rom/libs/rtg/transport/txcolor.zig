// SPDX-License-Identifier: MPL-2.0
//! TxColor: A command and a run of pixels.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _transport = @import("_transport.zig");

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
/// It may come back before the bytes have gone: `RTGEV_TX_DONE` says when
/// they have, and the bytes must stay put until then.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes stay the caller's, and must stay put until `RTGEV_TX_DONE`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `TxParam`, `AddRtgEventServer`
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
