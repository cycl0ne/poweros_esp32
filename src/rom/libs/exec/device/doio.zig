// SPDX-License-Identifier: MPL-2.0
//! DoIO: a request to its device, and back when it is done. It asks for a
//! quick answer; a device that cannot give one clears `IOF_QUICK`, and
//! DoIO waits for the reply instead.
//!
//! **The whole I/O protocol turns on IOF_QUICK**, and this is where it is
//! described for all of the I/O calls. DoIO sets it to ask for a quick
//! answer. A device that finishes the request inside BeginIO leaves it set
//! and sends no reply; a device that finishes it later clears it, keeps the
//! request - usually on its unit's port - and replies it when done. That
//! one bit is how WaitIO tells whether there is anything to wait for, and
//! how ReplyIO tells whether there is anything to send.
//!
//! DoIO and SendIO leave the request's node type alone, so a device that
//! keeps a request must mark it as a message, which PutMsg does. Without
//! that, WaitIO reads a request replied the last time round as already
//! done. The same field lets a device see that a request it has been handed
//! is still in use.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const IORequest = sdk.exec.IORequest;

/// Does one I/O request and waits for it to finish.
///
/// SYNOPSIS:
/// ```zig
/// fn DoIO(base: *ExecBase, io: *IORequest) i32
/// ```
///
/// SINCE: 1.0. LVO -328.
///
/// INPUTS:
/// - `io` - a request on an open device, with its command and arguments
///   filled in.
///
/// RESULT:
/// The request's error: 0 for success, a negative `IOERR_*` or a device's
/// own code otherwise. `IOERR_OPENFAIL` if the device is not open.
///
/// BEHAVIOR:
/// It asks for a quick answer by setting `IOF_QUICK`, and the device
/// decides:
///
/// **Finished inside BeginIO.** The flag is still set, no message was sent,
/// and the error is read straight out of the request. Nothing waits and
/// nothing is queued - which is what lets a short transfer cost no more
/// than a function call.
///
/// **Finished later.** The device cleared the flag and kept the request,
/// and this waits with `WaitIO`.
///
/// The error starts as `IOERR_OPENFAIL`, so a device that answers without
/// setting it reports failure rather than a false success.
///
/// CONTEXT:
/// - Waits: **usually** - only a request the device finished inside BeginIO
///   comes back without waiting, and which those are is the device's to
///   say, not the caller's to rely on.
/// - Interrupts: no. It may wait.
/// - Forbid: no. It may wait, and a device's work may reach a handler.
/// - Process: a Task will do, unless the device wants more.
///
/// OWNERSHIP:
/// The request is the device's until this returns, and the caller's again
/// afterwards. Its buffers must stay put and untouched for that time.
///
/// NOTES:
/// The request needs a reply port for the slow path. A request with none
/// that the device does not finish quickly cannot be waited for.
///
/// The error starts as `IOERR_OPENFAIL`, so a device that answers without
/// setting it reports a failure rather than a false success.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendIO`, `WaitIO`, `CheckIO`, `AbortIO`
///
/// EXAMPLES:
/// ```zig
/// io.command = CMD_WRITE;
/// io.data = buf.ptr;
/// io.length = buf.len;
/// if (sys.DoIO(@ptrCast(io)) != 0) return error.WriteFailed;
/// ```
pub fn DoIO(base: *ExecBase, io: *IORequest) i32 {
    io.err = sdk.exec.IOERR_OPENFAIL;
    const dev = io.device orelse return sdk.exec.IOERR_OPENFAIL;
    io.flags = sdk.exec.IOF_QUICK;
    dev.vector(sdk.exec.BeginIOFn, sdk.exec.DEV_BEGINIO)(dev, io);
    if (io.flags & sdk.exec.IOF_QUICK == 0) return base.iface().WaitIO(io);
    return io.err;
}
