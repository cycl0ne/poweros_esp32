// SPDX-License-Identifier: MIT
//! CloseUSBPipe: a pipe let go of.

const sdk = @import("sdk");
const usb = sdk.usb;
const UsbBase = @import("../usb_base.zig").UsbBase;

/// Closes a pipe.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseUSBPipe(base: *UsbBase, pipe: ?*usb.USBPipe) void
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `pipe` - from OpenUSBPipe, with nothing outstanding; null does
///   nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The pipe's memory is given back. A transfer still outstanding must be
/// aborted (AbortIO, WaitIO) first.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pipe is gone.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenUSBPipe`
///
/// EXAMPLES:
/// ```zig
/// _ = sys.AbortIO(&pipe.io.std.req);
/// _ = sys.WaitIO(&pipe.io.std.req);
/// ub.CloseUSBPipe(pipe);
/// ```
pub fn CloseUSBPipe(base: *UsbBase, pipe: ?*usb.USBPipe) void {
    const gone = pipe orelse return;
    base.sys_base.FreeMem(gone, @sizeOf(usb.USBPipe));
}
