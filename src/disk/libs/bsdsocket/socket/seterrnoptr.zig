// SPDX-License-Identifier: MIT
//! SetErrnoPtr: where else the error number is written.

const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;

/// A variable of the program's that gets the error number of every call
/// that fails, besides Errno().
///
/// SYNOPSIS:
/// ```zig
/// fn SetErrnoPtr(base: *SocketBase, errno_pointer: ?*anyopaque, size: u32) void
/// ```
///
/// SINCE: 1.0. LVO -84.
///
/// INPUTS:
/// - `errno_pointer` - the variable, or null for none.
/// - `size` - its bytes: 1, 2 or 4.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Another size, or null, stops the writing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The variable must stay while the base is open, or until it is changed.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Errno`, `SocketBaseTagList`
///
/// EXAMPLES:
/// ```zig
/// var errno: i32 = 0;
/// sb.SetErrnoPtr(&errno, @sizeOf(i32));
/// ```
pub fn SetErrnoPtr(sb: *SocketBase, errno_pointer: ?*anyopaque, size: u32) void {
    const usable = errno_pointer != null and (size == 1 or size == 2 or size == 4);
    sb.errno_pointer = if (usable) errno_pointer else null;
    sb.errno_size = if (usable) size else 0;
}
