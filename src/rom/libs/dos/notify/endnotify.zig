// SPDX-License-Identifier: MPL-2.0
//! EndNotify: a watch StartNotify began, ended.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("../lock/_lock.zig");
const packets = @import("../packet/_packet.zig");
const startnotify = @import("startnotify.zig");
const NotifyRequest = dos.notify.NotifyRequest;

/// Ends a watch: the program is told of the object no more.
///
/// SYNOPSIS:
/// ```zig
/// fn EndNotify(db: *DosBase, request: *NotifyRequest) void
/// ```
///
/// SINCE: 1.3. LVO -560.
///
/// INPUTS:
/// - `request` - one StartNotify took.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The handler drops the request and takes back its messages still on
/// the program's port; one the program has taken already it frees when it
/// is replied - so reply what was taken, before or after. dos frees the
/// request's `full_name`. A request StartNotify did not take is left
/// alone.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `request` is the program's to free, or to start again.
///
/// NOTES:
/// No signal comes after EndNotify returns; one sent before may still be
/// set.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartNotify`
///
/// EXAMPLES:
/// ```zig
/// dos_lib.EndNotify(&request);
/// ```
pub fn EndNotify(db: *DosBase, request: *NotifyRequest) void {
    const port = request.handler orelse return;
    _ = packets.exchange(db.sys_base, port, @intFromEnum(dos.ActionCode.remove_notify), .{ _lock.asArg(request), 0, 0, 0, 0 });
    startnotify.dropName(db, request);
    request.handler = null;
}
