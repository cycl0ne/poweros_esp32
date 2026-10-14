// SPDX-License-Identifier: MIT
//! DeleteHandshake: a key handshake freed.

const sdk = @import("sdk");
const wpa = sdk.wpa;
const WPABase = @import("../wpa_base.zig").WPABase;
const _handshake = @import("_handshake.zig");

/// Frees a key handshake and the keys it held.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteHandshake(base: *WPABase, handshake: ?*wpa.Handshake) void
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `handshake`: from CreateHandshake, or null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The network's key and every key derived from it are wiped before the
/// memory goes back. Null does nothing. The hook is not called.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// The handshake is gone; the hook it was given is the caller's again.
/// The keys the hook installed stay where the driver put them.
///
/// NOTES:
/// Not from inside the handshake's own hook: the call that called the
/// hook still uses the handshake.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateHandshake`
///
/// EXAMPLES:
/// ```zig
/// wb.DeleteHandshake(handshake);
/// handshake = null;
/// ```
pub fn DeleteHandshake(base: *WPABase, handshake: ?*wpa.Handshake) void {
    const session = _handshake.sessionOf(handshake orelse return);
    const bytes: [*]volatile u8 = @ptrCast(session);
    @memset(bytes[0..@sizeOf(_handshake.Session)], 0);
    base.sys_base.FreeVec(session);
}
