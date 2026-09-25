// SPDX-License-Identifier: MIT
//! Errno: why the last call failed.

const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;

/// The error number of the opener's last call that failed.
///
/// SYNOPSIS:
/// ```zig
/// fn Errno(base: *SocketBase) i32
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// An `E*` value of sdk.bsdsocket, or 0 if no call has failed yet.
///
/// BEHAVIOR:
/// A call that succeeds leaves it as it was.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// SetErrnoPtr has it written to a variable of the program's as well.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetErrnoPtr`, `SocketBaseTagList`
///
/// EXAMPLES:
/// ```zig
/// if (sb.Socket(bsd.PF_INET, bsd.SOCK_DGRAM, 0) < 0 and sb.Errno() == bsd.EMFILE) return;
/// ```
pub fn Errno(sb: *SocketBase) i32 {
    return sb.errno;
}
