// SPDX-License-Identifier: MPL-2.0
//! ReplyIO: the device's side - finishes a request. A request asked for
//! quickly and still marked quick was answered inside BeginIO and is not
//! replied; any other is replied to its port. The IOF_QUICK protocol this
//! rests on is described in doio.zig.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const IORequest = sdk.exec.IORequest;

/// For a device: finishes a request and sends it back.
///
/// SYNOPSIS:
/// ```zig
/// fn ReplyIO(base: *ExecBase, io: *IORequest) void
/// ```
///
/// SINCE: 1.0. LVO -340.
///
/// INPUTS:
/// - `io` - the request the device has finished, its error already set.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A request still marked `IOF_QUICK` was finished inside BeginIO and needs
/// no reply - the caller is reading the error directly - so nothing is
/// sent. Any other goes back to its reply port.
///
/// That single test is what lets a device write one ending for both paths.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: **safe, and that is what it is for.** A device's interrupt
///   finishes the request the task started.
/// - Forbid: not needed.
/// - Process: a Task will do; an interrupt will do.
///
/// OWNERSHIP:
/// The request goes back to whoever sent it and the device must not touch
/// it again.
///
/// NOTES:
/// This is a device's call, not a caller's. A request must not be finished
/// twice, which is what a device's own done flag is for.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DoIO`, `SendIO`, `ReplyMsg`
///
/// EXAMPLES:
/// ```zig
/// io.err = 0;
/// sys.ReplyIO(io);
/// ```
pub fn ReplyIO(base: *ExecBase, io: *IORequest) void {
    if (io.flags & sdk.exec.IOF_QUICK != 0) return;
    base.iface().ReplyMsg(&io.message);
}
