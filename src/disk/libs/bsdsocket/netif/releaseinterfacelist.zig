// SPDX-License-Identifier: MIT
//! ReleaseInterfaceList: a list ObtainInterfaceList made, freed.

const sdk = @import("sdk");
const exec = sdk.exec;
const _base = @import("../bsdsocket_base.zig");
const SocketBase = _base.SocketBase;

/// A list of interface names freed.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseInterfaceList(base: *SocketBase, list: ?*List) void
/// ```
///
/// SINCE: 1.0. LVO -144.
///
/// INPUTS:
/// - `list` - what ObtainInterfaceList answered, or null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The list and its nodes are one block, freed at once.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list is gone; its names with it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainInterfaceList`
///
/// EXAMPLES:
/// ```zig
/// sb.ReleaseInterfaceList(list);
/// ```
pub fn ReleaseInterfaceList(sb: *SocketBase, list: ?*exec.List) void {
    sb.sys_base.FreeVec(list);
}
