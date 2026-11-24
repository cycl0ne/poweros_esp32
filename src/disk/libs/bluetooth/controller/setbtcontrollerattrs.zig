// SPDX-License-Identifier: MIT
//! SetBTControllerAttrs: a controller's settings changed.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const utility = sdk.utility;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Changes what a controller does: whether it is on, the name it shows
/// others, whether they find it.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBTControllerAttrs(base: *BluetoothBase, controller: u32, tags: ?[*]const utility.TagItem) i32
/// ```
///
/// SINCE: 1.2. LVO -44.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for every controller that is up.
/// - `tags` - what is to change; a tag not given leaves its setting as
///   it is:
///   - `BTCA_Powered` (bool) - on, or off: off, it answers nobody and
///     looks for nothing, and a discovery it runs is stopped.
///   - `BTCA_Name` ([*:0]const u8) - the name it shows others, UTF-8, cut
///     to 247 bytes (whole characters); an empty one, or null, gives it
///     the machine's again (`ENVARC:Sys/net/hostname`, or "PowerOS").
///   - `BTCA_Visible` (u32) - found by others who look - inquiries
///     answered, and advertising over LE - for that many seconds; 0 for
///     not at all, BT_VISIBLE_ALWAYS until told otherwise.
///
/// RESULT:
/// 0 once it is done; BTERR_NOCONTROLLER for no such controller,
/// BTERR_NOTUP for one that is not up (or, with BT_ALL_CONTROLLERS, when
/// none is), BTERR_UNSUPPORTED for visible asked of a controller that can
/// neither answer inquiries nor advertise, BTERR_NOMEM when its commands
/// could not be queued. With
/// BT_ALL_CONTROLLERS, the first failure of any.
///
/// BEHAVIOR:
/// The controller is told at once: Write Scan Enable for on and visible -
/// pages answered while it is on, inquiries too while it is visible -
/// Write Local Name and its extended inquiry response for the name. The
/// call returns once the commands are queued, not when they are answered.
///
/// Over LE it advertises while it is on and visible, so that a device may
/// link to it: its name, and that it is a computer, every 100 to 150 ms
/// from its public address. It makes way for a scan or a link it cannot
/// advertise beside - LE Read Supported States says which - and goes on
/// after, BTCF_ADVERTISING set while it advertises; a name changed is
/// advertised at once. Since 1.22 a controller made hidden takes a new
/// private address over LE (BTController's `private_address`). Since
/// 1.24 a controller hidden goes on advertising over LE while a bond
/// says a device was given this machine's identity - from its private
/// address, saying nothing, every second or so, BTCF_ADVERTISING set - so
/// that such a device finds it and links to it; a link from a device that
/// resolves to no bond is ended at once.
///
/// On, visible until told otherwise and the name are kept for the
/// controller's next start, by its address: in
/// `ENVARC:Sys/bluetooth/<address>/` (`settings`, `name`). Visible for a
/// time is not: it ends at its time, and a start ends it.
///
/// Whoever asked with AddBTNotify is told, and BTController's `flags`,
/// `visible_left` and `name` say what it does now.
///
/// CONTEXT:
/// - Waits: yes, for the library's task, which writes the settings'
///   files before it answers.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The tags and the name are the caller's: the name is copied.
///
/// NOTES:
/// A controller without settings of its own is on and not visible. Visible
/// advertises over LE since 1.16.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainBTControllers`, `StartBTDiscovery`, `AddBTNotify`
///
/// EXAMPLES:
/// ```zig
/// // Found by others for two minutes.
/// _ = bt.SetBTControllerAttrs(0, &[_]utility.TagItem{
///     .{ .tag = bluetooth.BTCA_Visible, .data = 120 },
///     .{},
/// });
/// ```
pub fn SetBTControllerAttrs(base: *BluetoothBase, controller: u32, tags: ?[*]const utility.TagItem) i32 {
    var wanted: _task.Wanted = .{};
    var list = tags;
    while (base.utility_base.NextTagItem(&list)) |item| {
        switch (item.tag) {
            bluetooth.BTCA_Powered => {
                wanted.which |= _task.WANT_POWERED;
                wanted.powered = @intFromBool(item.data != 0);
            },
            bluetooth.BTCA_Name => {
                wanted.which |= _task.WANT_NAME;
                wanted.name = if (item.data != 0) @ptrFromInt(item.data) else "";
            },
            bluetooth.BTCA_Visible => {
                wanted.which |= _task.WANT_VISIBLE;
                wanted.visible = @truncate(item.data);
            },
            else => {},
        }
    }
    var command = _task.Command{ .kind = .set, .controller = controller, .wanted = wanted };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOCONTROLLER;
    return command.result;
}
