// SPDX-License-Identifier: MIT
//! StopBTDiscovery: a controller's discovery ended.

const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Ends a controller's discovery now.
///
/// SYNOPSIS:
/// ```zig
/// fn StopBTDiscovery(base: *BluetoothBase, controller: u32) void
/// ```
///
/// SINCE: 1.2. LVO -52.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for every controller.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Whatever part of it runs is taken back from the controller - LE's
/// scan turned off, the inquiry cancelled, the name being asked for too
/// - and BTCF_DISCOVERING cleared; whoever asked with AddBTNotify is
/// told. The devices found stay in the list ObtainBTDevices answers. A
/// controller that does not look, or that is not there, is left as it
/// is.
///
/// CONTEXT:
/// - Waits: yes, for the library's task.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartBTDiscovery`, `ObtainBTDevices`
///
/// EXAMPLES:
/// ```zig
/// bt.StopBTDiscovery(bluetooth.BT_ALL_CONTROLLERS);
/// ```
pub fn StopBTDiscovery(base: *BluetoothBase, controller: u32) void {
    var command = _task.Command{ .kind = .stop, .controller = controller };
    _ = _task.tell(base, &command);
}
