// SPDX-License-Identifier: MIT
//! CloseClipboard: a clipboard handle given back.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;

/// Gives a clipboard handle back.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseClipboard(ib: *IFFParseBase, clip: ?*iffparse.ClipboardHandle) void
/// ```
///
/// SINCE: 1.0. LVO -164.
///
/// INPUTS:
/// - `clip` - a handle from `OpenClipboard`; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The device is closed and the two signals go back to the task. Any IFF
/// handle using it must have been closed first (`CloseIFF`), since that
/// is what finishes the writing.
///
/// CONTEXT:
/// - Waits: for clipboard.device to close.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do - the one that opened it.
///
/// OWNERSHIP:
/// The handle goes.
///
/// NOTES:
/// The signals belong to the task that opened the handle, so it is that
/// task that closes it.
///
/// SEE ALSO:
/// `OpenClipboard`, `CloseIFF`
///
/// EXAMPLES:
/// ```zig
/// ip.CloseIFF(iff);
/// ip.CloseClipboard(clip);
/// ```
pub fn CloseClipboard(ib: *IFFParseBase, clip: ?*iffparse.ClipboardHandle) void {
    const handle = clip orelse return;
    const sys = ib.sys_base;
    sys.CloseDevice(&handle.req.io.req);
    sys.FreeSignal(@intCast(handle.port.sig_bit));
    sys.FreeSignal(@intCast(handle.satisfy_port.sig_bit));
    sys.FreeVec(handle);
}
