// SPDX-License-Identifier: MIT
//! GetDTableSize: the size of the opener's descriptor table.

const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;

/// How many sockets the opener may have open at once.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDTableSize(base: *SocketBase) i32
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The size of the descriptor table: 64, unless SocketBaseTagList's
/// `SBTC_DTABLESIZE` changed it.
///
/// BEHAVIOR:
/// Descriptors run from 0 to one less than this.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SocketBaseTagList`, `Socket`
///
/// EXAMPLES:
/// ```zig
/// const most = sb.GetDTableSize();
/// ```
pub fn GetDTableSize(sb: *SocketBase) i32 {
    return @intCast(sb.table_size);
}
