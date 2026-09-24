// SPDX-License-Identifier: MPL-2.0
//! SendIO: a request to its device, without waiting. The device replies it
//! to the request's port when done; `WaitIO` or `CheckIO` finds out when.
//! The IOF_QUICK protocol this rests on is described in doio.zig.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const IORequest = sdk.exec.IORequest;

/// Starts an I/O request and returns at once.
///
/// SYNOPSIS:
/// ```zig
/// fn SendIO(_: *ExecBase, io: *IORequest) void
/// ```
///
/// SINCE: 1.0. LVO -332.
///
/// INPUTS:
/// - `io` - a request on an open device, with a reply port.
///
/// RESULT:
/// Nothing. What happened is learned from `WaitIO` or `CheckIO`.
///
/// BEHAVIOR:
/// `IOF_QUICK` is **cleared**, so the device always replies and the request
/// always comes back to its port - even one the device could have finished
/// at once. That is what makes the request waitable beside everything else
/// the task is waiting for.
///
/// With no device open the request is left marked quick with
/// `IOERR_OPENFAIL`, so the `WaitIO` that follows answers that immediately
/// instead of waiting for a reply that will never come.
///
/// CONTEXT:
/// - Waits: no. That is the point of it.
/// - Interrupts: no.
/// - Forbid: no; the device's BeginIO may do anything.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The request and its buffers belong to the device from here until it is
/// collected. Neither may be touched or freed in between - a request on the
/// stack of a function that returns is the mistake this invites.
///
/// NOTES:
/// Every `SendIO` owes a `WaitIO` or an `AbortIO` then a `WaitIO`. A
/// request left outstanding cannot be freed and its device cannot be
/// closed.
///
/// With no device open the request is left marked quick with
/// `IOERR_OPENFAIL`, so the `WaitIO` that follows answers at once instead
/// of waiting for a reply that can never come.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WaitIO`, `CheckIO`, `AbortIO`, `DoIO`
///
/// EXAMPLES:
/// ```zig
/// sys.SendIO(@ptrCast(io));
/// const got = sys.Wait(port_mask | exec.SIGBREAKF_CTRL_C);
/// if (got & exec.SIGBREAKF_CTRL_C != 0) _ = sys.AbortIO(@ptrCast(io));
/// _ = sys.WaitIO(@ptrCast(io));
/// ```
pub fn SendIO(_: *ExecBase, io: *IORequest) void {
    io.err = sdk.exec.IOERR_OPENFAIL;
    const dev = io.device orelse {
        io.flags = sdk.exec.IOF_QUICK;
        return;
    };
    io.flags = 0;
    dev.vector(sdk.exec.BeginIOFn, sdk.exec.DEV_BEGINIO)(dev, io);
}
