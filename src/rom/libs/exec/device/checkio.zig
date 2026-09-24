// SPDX-License-Identifier: MPL-2.0
//! CheckIO: whether a device is done with a request, without waiting.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const IORequest = sdk.exec.IORequest;

/// Asks whether a device is done with a request, without waiting.
///
/// SYNOPSIS:
/// ```zig
/// fn CheckIO(_: *ExecBase, io: *IORequest) ?*IORequest
/// ```
///
/// SINCE: 1.0. LVO -344.
///
/// INPUTS:
/// - `io` - a request from `SendIO`.
///
/// RESULT:
/// The request if the device is done with it, null if it is still working.
///
/// BEHAVIOR:
/// **A non-null answer does not make the request the caller's again.** It
/// is still on the reply port, and `WaitIO` is what takes it off - which
/// after a successful check returns at once. Reusing a request on the
/// strength of this alone leaves it on a port it is no longer on terms
/// with.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads two fields.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. `WaitIO` is still owed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WaitIO`, `SendIO`, `AbortIO`
///
/// EXAMPLES:
/// ```zig
/// if (sys.CheckIO(@ptrCast(io)) != null) {
///     _ = sys.WaitIO(@ptrCast(io)); // returns at once, and collects it
/// }
/// ```
pub fn CheckIO(_: *ExecBase, io: *IORequest) ?*IORequest {
    if (io.message.node.type == .replymsg or io.flags & sdk.exec.IOF_QUICK != 0) return io;
    return null;
}
