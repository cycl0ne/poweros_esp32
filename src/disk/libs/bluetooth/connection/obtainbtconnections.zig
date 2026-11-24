// SPDX-License-Identifier: MIT
//! ObtainBTConnections: the links of a controller, as they are now.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _controller = @import("../controller/_controller.zig");
const _task = @import("../task/_task.zig");
const _connection = @import("_connection.zig");

/// Lists a controller's links to devices: a copy of each as it is at the
/// moment of the call.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainBTConnections(base: *BluetoothBase, controller: u32) ?*exec.List
/// ```
///
/// SINCE: 1.3. LVO -72.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for every controller's, one controller's after the other's.
///
/// RESULT:
/// A list of `bluetooth.BTConnection` nodes - empty for no link or no
/// such controller - or null without memory.
///
/// BEHAVIOR:
/// The links are those that are up - made by ConnectBTDevice, or by a
/// device that paged the controller - and those being ended: each with
/// the device's address, what sort of link it is (BTLF_*: since 1.4 also
/// whether it is authenticated, to a device with a bond, being paired),
/// the controller's handle for it, LE's parameters, how long it has been
/// up, and the device's name and class where they are known. A link
/// being made is not listed until it is up - over LE, since 1.6, until
/// the device has answered on it. Since 1.22 an LE link also has the
/// device's identity, where it links from a private address its bond's
/// key resolves - a link of a bonded device's is BTLF_BONDED so too - and
/// the address this side made it from: its public or its private one.
///
/// Each node is a copy, its name with it: nothing the library does later
/// reaches it.
///
/// CONTEXT:
/// - Waits: yes, for the controllers' lock, which the task holds while it
///   takes a packet.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list and its nodes are the caller's, given back whole with
/// ReleaseBTConnections.
///
/// NOTES:
/// A controller keeps up to 8 links.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseBTConnections`, `ConnectBTDevice`, `DisconnectBTDevice`,
/// `AddBTNotify`
///
/// EXAMPLES:
/// ```zig
/// const list = bt.ObtainBTConnections(bluetooth.BT_ALL_CONTROLLERS) orelse return;
/// defer bt.ReleaseBTConnections(list);
/// var it = list.iterator();
/// while (it.next()) |node| {
///     const link: *bluetooth.BTConnection = @fieldParentPtr("node", node);
///     _ = link.flags & bluetooth.BTLF_LE;
/// }
/// ```
pub fn ObtainBTConnections(base: *BluetoothBase, controller: u32) ?*exec.List {
    const sys = base.sys_base;
    sys.ObtainSemaphoreShared(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    var count: usize = 0;
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const kept = _controller.fromNode(node);
        if (controller != bluetooth.BT_ALL_CONTROLLERS and kept.id != controller) continue;
        for (&kept.layer.connections) |*connection| {
            if (_connection.listed(connection)) count += 1;
        }
    }
    const size = @sizeOf(exec.List) + count * @sizeOf(_connection.Entry);
    const memory = sys.AllocVec(size, exec.MEMF_CLEAR) orelse return null;
    const list: *exec.List = @ptrCast(@alignCast(memory));
    list.init(.unknown);
    const entries: [*]_connection.Entry = @ptrFromInt(@intFromPtr(memory) + @sizeOf(exec.List));
    const now = _task.clock(sys);
    var index: usize = 0;
    it = base.controllers.iterator();
    while (it.next()) |node| {
        const kept = _controller.fromNode(node);
        if (controller != bluetooth.BT_ALL_CONTROLLERS and kept.id != controller) continue;
        for (&kept.layer.connections) |*connection| {
            if (!_connection.listed(connection)) continue;
            const entry = &entries[index];
            index += 1;
            entry.* = .{};
            _connection.describe(kept.id, &kept.layer, connection, entry, now);
            sys.AddTail(list, &entry.public.node);
        }
    }
    return list;
}
