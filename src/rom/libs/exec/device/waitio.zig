// SPDX-License-Identifier: MPL-2.0
//! WaitIO: waits until a device is done with a request, and takes the reply
//! off the port. A request finished quickly has nothing to wait for; one
//! the device kept is waited for until its node says it was replied. The
//! IOF_QUICK protocol this rests on is described in doio.zig.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const IORequest = sdk.exec.IORequest;

/// Waits until a device is done with a request, and takes it back.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitIO(base: *ExecBase, io: *IORequest) i32
/// ```
///
/// SINCE: 1.0. LVO -336.
///
/// INPUTS:
/// - `io` - a request from `SendIO`, or one already finished.
///
/// RESULT:
/// The request's error. `IOERR_NOREPLYPORT` if it was not finished and has
/// no port to wait on.
///
/// BEHAVIOR:
/// A request still marked `IOF_QUICK` was finished inside BeginIO, so there
/// is nothing to wait for and the error is read straight out.
///
/// Otherwise it waits on the reply port until the request is replied, and
/// **takes it off the port**, which is what makes the request the caller's
/// again. A reply arriving between the check and the wait leaves the signal
/// set, so the wait returns at once rather than missing it.
///
/// CONTEXT:
/// - Waits: yes, unless the request is already finished.
/// - Interrupts: no.
/// - Forbid: no. It waits.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The request and its buffers are the caller's again and may be reused or
/// freed.
///
/// NOTES:
/// It waits on the port's signal alone, so a task that must also hear
/// Ctrl-C waits with `Wait` on the whole mask first and calls this only to
/// collect - which is the shape in `SendIO`'s example.
///
/// Other requests on the same port are left alone, so one port serves many
/// requests.
///
/// The node type is read through a volatile pointer because it is written
/// by the device - from an interrupt, in the usual case - and nothing in
/// the loop would otherwise make the compiler read it again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendIO`, `CheckIO`, `AbortIO`, `Wait`
///
/// EXAMPLES:
/// ```zig
/// const err = sys.WaitIO(@ptrCast(io));
/// ```
pub fn WaitIO(base: *ExecBase, io: *IORequest) i32 {
    if (io.flags & sdk.exec.IOF_QUICK != 0) return io.err;
    const port = io.message.reply_port orelse {
        io.err = sdk.exec.IOERR_NOREPLYPORT;
        return io.err;
    };
    const node_type: *volatile sdk.exec.NodeType = &io.message.node.type;
    const sys = base.iface();
    sys.Disable();
    while (node_type.* != .replymsg) {
        // A reply between Enable and Wait leaves the signal set: Wait
        // returns at once.
        sys.Enable();
        _ = sys.Wait(port.sigMask());
        sys.Disable();
    }
    sys.Remove(&io.message.node);
    sys.Enable();
    return io.err;
}
