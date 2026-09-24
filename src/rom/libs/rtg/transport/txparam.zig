// SPDX-License-Identifier: MPL-2.0
//! TxParam: A command and its parameters to the part.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _transport = @import("_transport.zig");

/// Sends a command and its parameters to the part on a bus.
///
/// SYNOPSIS:
/// ```zig
/// fn TxParam(_: *RtgBase, io: *rtg.RtgTransport, cmd: i32, param: ?*const anyopaque, size: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -180.
///
/// INPUTS:
/// - `io` - the transport.
/// - `cmd` - the command; below zero sends the parameters alone.
/// - `param` - the parameter bytes, or null.
/// - `size` - how many.
///
/// RESULT:
/// `RTGERR_OK`, `RTGERR_NOT_SUPPORTED` for a transport that cannot send,
/// or what the driver answered: `RTGERR_IO`, `RTGERR_TIMEOUT`.
///
/// BEHAVIOR:
/// The driver's own send, handed straight through.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The bytes stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `TxColor`, `RxParam`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.TxParam(io, 0x29, null, 0);
/// ```
pub fn TxParam(_: *RtgBase, io: *rtg.RtgTransport, cmd: i32, param: ?*const anyopaque, size: u32) i32 {
    const ops = io.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const tx = ops.tx_param orelse return err.RTGERR_NOT_SUPPORTED;
    return tx(io, cmd, param, size);
}
