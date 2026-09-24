// SPDX-License-Identifier: MPL-2.0
//! RxParam: Send a command and read `size` bytes back, with nothing
//! else reaching the bus in between.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _transport = @import("_transport.zig");

/// Sends a command and reads bytes back from the part on a bus.
///
/// SYNOPSIS:
/// ```zig
/// fn RxParam(_: *RtgBase, io: *rtg.RtgTransport, cmd: i32, buffer: ?*anyopaque, size: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -188.
///
/// INPUTS:
/// - `io` - the transport.
/// - `cmd` - the command.
/// - `buffer` - where the answer goes.
/// - `size` - how many bytes to read.
///
/// RESULT:
/// `RTGERR_OK`, `RTGERR_NOT_SUPPORTED`, or what the driver answered.
///
/// BEHAVIOR:
/// Nothing else reaches the bus between the command and the answer.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The buffer is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `TxParam`
///
/// EXAMPLES:
/// ```zig
/// var id: [3]u8 = undefined;
/// _ = rb.RxParam(io, 0x04, &id, id.len);
/// ```
pub fn RxParam(_: *RtgBase, io: *rtg.RtgTransport, cmd: i32, buffer: ?*anyopaque, size: u32) i32 {
    const ops = io.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const rx = ops.rx_param orelse return err.RTGERR_NOT_SUPPORTED;
    return rx(io, cmd, buffer, size);
}
