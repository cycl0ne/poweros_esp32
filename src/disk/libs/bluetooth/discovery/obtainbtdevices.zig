// SPDX-License-Identifier: MIT
//! ObtainBTDevices: the devices a controller found, as they are now.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _controller = @import("../controller/_controller.zig");
const _task = @import("../task/_task.zig");
const _discovery = @import("_discovery.zig");

/// Lists the devices a controller found: a copy of each as it is at the
/// moment of the call.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainBTDevices(base: *BluetoothBase, controller: u32) ?*exec.List
/// ```
///
/// SINCE: 1.2. LVO -56.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
///   for every controller's, one controller's after the other's.
///
/// RESULT:
/// A list of `bluetooth.BTDevice` nodes - empty when nothing was found or
/// there is no such controller - or null without memory.
///
/// BEHAVIOR:
/// The devices are those of the controller's last discovery
/// (StartBTDiscovery), kept until its next begins: each with its address,
/// how it was heard (BTDF_*), its signal, and what it said of itself -
/// its name, class of device, services, appearance, maker - and how long
/// ago it was last heard. A device heard both ways, BR/EDR and LE from
/// the same public address, is one node. A discovery still running shows
/// what it has heard so far: a name may come later, and the list again
/// then has it.
///
/// Each node is a copy, its name with it: what it says does not change
/// after the call, and nothing the library does later reaches it.
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
/// ReleaseBTDevices.
///
/// NOTES:
/// A controller keeps up to 64 devices; when more are heard it keeps
/// those heard strongest.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseBTDevices`, `StartBTDiscovery`, `AddBTNotify`
///
/// EXAMPLES:
/// ```zig
/// const list = bt.ObtainBTDevices(0) orelse return;
/// defer bt.ReleaseBTDevices(list);
/// var it = list.iterator();
/// while (it.next()) |node| {
///     const found: *bluetooth.BTDevice = @fieldParentPtr("node", node);
///     _ = found.rssi;
/// }
/// ```
pub fn ObtainBTDevices(base: *BluetoothBase, controller: u32) ?*exec.List {
    const sys = base.sys_base;
    sys.ObtainSemaphoreShared(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    var count: usize = 0;
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const kept = _controller.fromNode(node);
        if (controller != bluetooth.BT_ALL_CONTROLLERS and kept.id != controller) continue;
        for (&kept.layer.devices) |*device| {
            if (device.used) count += 1;
        }
    }
    const size = @sizeOf(exec.List) + count * @sizeOf(_discovery.Entry);
    const memory = sys.AllocVec(size, exec.MEMF_CLEAR) orelse return null;
    const list: *exec.List = @ptrCast(@alignCast(memory));
    list.init(.unknown);
    const entries: [*]_discovery.Entry = @ptrFromInt(@intFromPtr(memory) + @sizeOf(exec.List));
    const now = _task.clock(sys);
    var index: usize = 0;
    it = base.controllers.iterator();
    while (it.next()) |node| {
        const kept = _controller.fromNode(node);
        if (controller != bluetooth.BT_ALL_CONTROLLERS and kept.id != controller) continue;
        for (&kept.layer.devices) |*device| {
            if (!device.used) continue;
            const entry = &entries[index];
            index += 1;
            entry.* = .{};
            _discovery.describe(kept.id, device, entry, now);
            sys.AddTail(list, &entry.public.node);
        }
    }
    return list;
}
