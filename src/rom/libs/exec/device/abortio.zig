// SPDX-License-Identifier: MPL-2.0
//! AbortIO: asks a request's device to stop working on it. The device
//! decides what that means; the request is replied as usual, and still has
//! to be waited for.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const IORequest = sdk.exec.IORequest;

/// Asks a device to stop a request it is working on.
///
/// SYNOPSIS:
/// ```zig
/// fn AbortIO(_: *ExecBase, io: *IORequest) i32
/// ```
///
/// SINCE: 1.0. LVO -348.
///
/// INPUTS:
/// - `io` - a request from `SendIO`.
///
/// RESULT:
/// 0 if the device took the request back, or its own error if it could not.
/// `IOERR_OPENFAIL` if the device is not open.
///
/// BEHAVIOR:
/// It **asks**. A device that can abort replies the request with
/// `IOERR_ABORTED`; one that cannot - a transfer already under way in
/// hardware - answers an error and the request finishes normally.
///
/// Either way **the request must still be collected with `WaitIO`**: this
/// does not take it back, it only asks for it to end sooner. That is the
/// step most easily forgotten, and skipping it leaves a request outstanding
/// on a port whose owner has moved on.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no; the device's AbortIO may do anything.
/// - Forbid: no.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands here. `WaitIO` is what gives the request back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendIO`, `WaitIO`, `CloseDevice`
///
/// EXAMPLES:
/// ```zig
/// _ = sys.AbortIO(@ptrCast(io));
/// _ = sys.WaitIO(@ptrCast(io)); // still owed
/// ```
pub fn AbortIO(_: *ExecBase, io: *IORequest) i32 {
    const dev = io.device orelse return sdk.exec.IOERR_OPENFAIL;
    return dev.vector(sdk.exec.AbortIOFn, sdk.exec.DEV_ABORTIO)(dev, io);
}
