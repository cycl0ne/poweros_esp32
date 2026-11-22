// SPDX-License-Identifier: MIT
//! ObtainBTControllers: the controllers as they are now.

const sdk = @import("sdk");
const exec = sdk.exec;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _controller = @import("_controller.zig");

/// Lists the controllers: a copy of each as it is at the moment of the
/// call.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainBTControllers(base: *BluetoothBase) ?*exec.List
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// A list of `bluetooth.BTController` nodes in the order they were added
/// - empty when there is none - or null without memory.
///
/// BEHAVIOR:
/// Each node is a copy, its strings with it: what it says does not change
/// after the call, and nothing the library does later reaches it. A
/// controller seen between two of its packets: a bring-up half done shows
/// what it has read so far.
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
/// ReleaseBTControllers.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseBTControllers`, `AddBTNotify`
///
/// EXAMPLES:
/// ```zig
/// const list = bt.ObtainBTControllers() orelse return;
/// defer bt.ReleaseBTControllers(list);
/// var it = list.iterator();
/// while (it.next()) |node| {
///     const controller: *bluetooth.BTController = @fieldParentPtr("node", node);
///     _ = controller.address;
/// }
/// ```
pub fn ObtainBTControllers(base: *BluetoothBase) ?*exec.List {
    const sys = base.sys_base;
    sys.ObtainSemaphoreShared(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    var count: usize = 0;
    var it = base.controllers.iterator();
    while (it.next()) |_| count += 1;
    const size = @sizeOf(exec.List) + count * @sizeOf(_controller.Entry);
    const memory = sys.AllocVec(size, exec.MEMF_CLEAR) orelse return null;
    const list: *exec.List = @ptrCast(@alignCast(memory));
    list.init(.unknown);
    const entries: [*]_controller.Entry = @ptrFromInt(@intFromPtr(memory) + @sizeOf(exec.List));
    var index: usize = 0;
    it = base.controllers.iterator();
    while (it.next()) |node| : (index += 1) {
        const entry = &entries[index];
        entry.* = .{};
        _controller.describe(_controller.fromNode(node), entry);
        sys.AddTail(list, &entry.public.node);
    }
    return list;
}
