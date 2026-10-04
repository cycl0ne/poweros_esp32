// SPDX-License-Identifier: MPL-2.0
//! CloseDevice: hands a request back to its device's Close and clears the
//! request, so it cannot be used or closed again.

const sdk = @import("sdk");
const _library = @import("../library/_library.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const IORequest = sdk.exec.IORequest;

/// Closes a request's device.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseDevice(base: *ExecBase, io: *IORequest) void
/// ```
///
/// SINCE: 1.0. LVO -324.
///
/// INPUTS:
/// - `io` - a request that was opened. One whose open failed, or that was
///   closed already, does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The device and unit fields are cleared, so closing twice is safe and a
/// closed request cannot be sent by mistake - `DoIO` on one answers
/// `IOERR_OPENFAIL` rather than calling into a device that is not open.
///
/// **Every request started must be finished first.** A device asked to
/// close while it still holds a request has no way to give it back.
///
/// As `CloseLibrary`: the Close vector runs inside the device's own lock,
/// and a device whose last close leaves it marked to go is expunged by
/// exec there and then.
///
/// CONTEXT:
/// - Waits: for the device's lock while another task holds it, and a
///   device's own Close may.
/// - Interrupts: no. It takes semaphores.
/// - Locks: takes the device's own lock, and exec's library list at an expunge,
///   both semaphores; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The open count is given up. The request itself is still the caller's and
/// is freed with `DeleteIORequest`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenDevice`, `AbortIO`, `DeleteIORequest`
///
/// EXAMPLES:
/// ```zig
/// defer sys.CloseDevice(io);
/// ```
pub fn CloseDevice(base: *ExecBase, io: *IORequest) void {
    const sys = base.iface();
    const dev = io.device orelse return;
    sys.ObtainSemaphore(&dev.lock);
    _ = dev.vector(sdk.exec.DevCloseFn, sdk.exec.LIB_CLOSE)(dev, io);
    io.device = null;
    io.unit = null;
    if (dev.open_cnt == 0 and dev.flags & sdk.exec.LIBF_DELEXP != 0) {
        // Gives the lock back, or takes it with the device. The seglist of
        // a device that went is dropped: nothing here unloads.
        _ = _library.expungeHeld(base, dev, &base.device_list);
        return;
    }
    sys.ReleaseSemaphore(&dev.lock);
}
