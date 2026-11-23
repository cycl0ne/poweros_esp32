// SPDX-License-Identifier: MIT
//! ObtainBTBonds: the bonds as they are now.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _controller = @import("../controller/_controller.zig");
const _pairing = @import("_pairing.zig");
const _profile = @import("../profile/_profile.zig");

/// Lists the bonds of a controller, or of every controller.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainBTBonds(base: *BluetoothBase, controller: u32) ?*exec.List
/// ```
///
/// SINCE: 1.4. LVO -96.
///
/// INPUTS:
/// - `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS.
///
/// RESULT:
/// A list of BTBond, empty for none; null without memory.
///
/// BEHAVIOR:
/// Each bond the device's address, its name and class of device as they
/// were at its pairing, the kind of its key and its size, and whether its
/// pairing was confirmed (BTBF_AUTHENTICATED), made with Secure
/// Connections (BTBF_SECURE) or with a PIN (BTBF_LEGACY). An LE bond's
/// address is an LE one - the device's identity where it gave it, with
/// the key that resolves its private addresses (BTBF_IDENTITY) - its key
/// kind 0. Since 1.9 each names the profile drivers its device's services
/// are bound to (BTBond.drivers). A controller's bonds are there once it
/// has read them, as it comes up.
///
/// CONTEXT:
/// - Waits: yes, for the controllers' lock.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The list and its nodes are the caller's until ReleaseBTBonds; they do
/// not change.
///
/// NOTES:
/// The keys are not listed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseBTBonds`, `PairBTDevice`, `UnpairBTDevice`
///
/// EXAMPLES:
/// ```zig
/// const list = bt.ObtainBTBonds(bluetooth.BT_ALL_CONTROLLERS) orelse return;
/// defer bt.ReleaseBTBonds(list);
/// var it = list.iterator();
/// while (it.next()) |node| {
///     const bond: *bluetooth.BTBond = @fieldParentPtr("node", node);
///     _ = bond.address;
/// }
/// ```
pub fn ObtainBTBonds(base: *BluetoothBase, controller: u32) ?*exec.List {
    const sys = base.sys_base;
    sys.ObtainSemaphoreShared(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    var count: usize = 0;
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const kept = _controller.fromNode(node);
        if (controller != bluetooth.BT_ALL_CONTROLLERS and kept.id != controller) continue;
        for (&kept.layer.bonds) |*bond| {
            if (_pairing.listed(bond)) count += 1;
        }
    }
    const size = @sizeOf(exec.List) + count * @sizeOf(_pairing.Entry);
    const memory = sys.AllocVec(size, exec.MEMF_CLEAR) orelse return null;
    const list: *exec.List = @ptrCast(@alignCast(memory));
    list.init(.unknown);
    const entries: [*]_pairing.Entry = @ptrFromInt(@intFromPtr(memory) + @sizeOf(exec.List));
    var index: usize = 0;
    it = base.controllers.iterator();
    while (it.next()) |node| {
        const kept = _controller.fromNode(node);
        if (controller != bluetooth.BT_ALL_CONTROLLERS and kept.id != controller) continue;
        for (&kept.layer.bonds) |*bond| {
            if (!_pairing.listed(bond)) continue;
            const entry = &entries[index];
            index += 1;
            entry.* = .{};
            _pairing.describe(kept.id, bond, entry);
            _profile.driversOf(base, kept.id, bond.address, &entry.drivers);
            sys.AddTail(list, &entry.public.node);
        }
    }
    return list;
}
