// SPDX-License-Identifier: MPL-2.0
//! CreateIORequest: a cleared request of a given size, tied to a reply
//! port and marked as already replied, so `CheckIO` on a request that was
//! never sent answers that it is finished.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const MsgPort = sdk.exec.MsgPort;
const IORequest = sdk.exec.IORequest;

/// Allocates a cleared I/O request for a reply port.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateIORequest(base: *ExecBase, reply_port: ?*MsgPort,
///     size: u32) ?*IORequest
/// ```
///
/// SINCE: 1.0. LVO -364.
///
/// INPUTS:
/// - `reply_port` - where replies go. Null answers null, so a failed
///   `CreateMsgPort` may be passed straight in.
/// - `size` - bytes to allocate: `@sizeOf(IORequest)` at least, and **the
///   size the device expects** - `IOStdReq`, `IOExtSer`, whatever its own
///   header is. Too small for an `IORequest`, or past what the length field
///   holds, answers null.
///
/// RESULT:
/// The request, cleared, with its reply port and length set, or null.
///
/// BEHAVIOR:
/// It is marked as replied - "finished" - so `CheckIO` on a fresh request
/// says it is idle rather than outstanding.
///
/// The size is kept in the request, which is what lets `DeleteIORequest`
/// free it without being told again.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `DeleteIORequest`, and its device must be closed
/// first.
///
/// NOTES:
/// Getting the size wrong is the mistake that does not show up here.
/// A device handed a request smaller than its own type writes past the end
/// of the allocation, and what breaks is whatever was next in memory.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteIORequest`, `CreateMsgPort`, `OpenDevice`
///
/// EXAMPLES:
/// ```zig
/// const port = sys.CreateMsgPort() orelse return;
/// defer sys.DeleteMsgPort(port);
/// const io = sys.CreateIORequest(port, @sizeOf(IOStdReq)) orelse return;
/// defer sys.DeleteIORequest(io);
/// ```
pub fn CreateIORequest(base: *ExecBase, reply_port: ?*MsgPort, size: u32) ?*IORequest {
    const port = reply_port orelse return null;
    if (size < @sizeOf(IORequest) or size > 0xFFFF) return null;
    const mem = base.iface().AllocMem(size, sdk.exec.MEMF_CLEAR) orelse return null;
    const io: *IORequest = @ptrCast(@alignCast(mem));
    io.message.node.type = .replymsg;
    io.message.reply_port = port;
    io.message.length = @intCast(size);
    return io;
}
