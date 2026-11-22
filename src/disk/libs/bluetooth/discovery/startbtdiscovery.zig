// SPDX-License-Identifier: MIT
//! StartBTDiscovery: a controller made to look for the devices around.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Makes a controller look for the devices around it: LE's advertisers,
/// then the BR/EDR devices that answer an inquiry, then the names not
/// yet heard.
///
/// SYNOPSIS:
/// ```zig
/// fn StartBTDiscovery(base: *BluetoothBase, controller: u32, seconds: u32) i32
/// ```
///
/// SINCE: 1.2. LVO -48.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for every controller that is up and on.
/// - `seconds` - how long the first two parts take together, from 2 to
///   60; 0 for about ten.
///
/// RESULT:
/// 0 once it looks; BTERR_NOCONTROLLER for no such controller,
/// BTERR_NOTUP for one that is not up (or, with BT_ALL_CONTROLLERS, when
/// none is), BTERR_OFF for one that is off (or, with BT_ALL_CONTROLLERS,
/// when every one that is up is), BTERR_UNSUPPORTED
/// for one that can neither scan LE's advertising nor inquire,
/// BTERR_NOMEM when its commands could not be queued. With
/// BT_ALL_CONTROLLERS, the first failure of any.
///
/// BEHAVIOR:
/// The devices the controller found before are forgotten, and it looks
/// in three parts, one after the other:
///
/// - LE's advertising listened to, actively - every advertiser asked for
///   its scan response, which often has its name - for a third of the
///   time;
/// - an inquiry for the rest: the BR/EDR devices that are visible answer,
///   with their signal and, from a controller that has extended results,
///   their names and services;
/// - each BR/EDR device that has said no complete name asked for it, the
///   strongest first, up to ten seconds each.
///
/// A controller without LE, or without BR/EDR, gives all of the time to
/// the part it has. Each device found, and each name, is in the list
/// ObtainBTDevices answers as soon as it is heard, and whoever asked with
/// AddBTNotify is told; BTCF_DISCOVERING is set on the controller until
/// the last part is over. A controller that looks already goes on as it
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
/// NOTES:
/// Two controllers that look at the same time can miss each other: one
/// that inquires has little of its radio left for answering inquiries.
/// The names take longer where many devices have not said theirs.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StopBTDiscovery`, `ObtainBTDevices`, `AddBTNotify`
///
/// EXAMPLES:
/// ```zig
/// if (bt.StartBTDiscovery(0, 10) != 0) return;
/// // ... Wait for the notify's signal, then ObtainBTDevices(0).
/// ```
pub fn StartBTDiscovery(base: *BluetoothBase, controller: u32, seconds: u32) i32 {
    var command = _task.Command{ .kind = .discover, .controller = controller, .time_ms = seconds *| 1000 };
    if (!_task.tell(base, &command)) return bluetooth.BTERR_NOCONTROLLER;
    return command.result;
}
