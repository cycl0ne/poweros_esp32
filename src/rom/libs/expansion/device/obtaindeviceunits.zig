// SPDX-License-Identifier: MPL-2.0
//! ObtainDeviceUnits: every unit of the devices that speak a command set.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;
const _device = @import("_device.zig");

/// Every unit of every device that speaks `speaks`, on this board.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainDeviceUnits(eb: *ExpansionBase, speaks: u32, tags: ?[*]const utility.TagItem) ?*exec.List
/// ```
///
/// SINCE: 1.2. LVO -40.
///
/// INPUTS:
/// - `speaks` - the command set asked for, DEVIF_*
///   (sdk/libs/expansion/devices.zig); 0 for every device that says what
///   it speaks.
/// - `tags` - none are read yet: null.
///
/// RESULT:
/// A list of `DeviceUnit` nodes, one per unit - empty when there is none -
/// to be given back with ReleaseDeviceUnits; null without the memory for
/// it.
///
/// BEHAVIOR:
/// A device is listed when its ROM tag is a `ResidentDevice` (RTF_DEVICEINFO)
/// that names `speaks` among its command sets: the ROM's devices, read
/// where their tags are, and the files in DEVS: and its drawers - all but
/// `handlers` - read for their tag from the file's bytes. Nothing is
/// opened, loaded or started to find out. A device both in the ROM and in
/// DEVS: is listed once, the higher version and revision.
///
/// Its units: with a part kind (`unit_part`), one per part of that kind
/// and chip (`unit_chip`) on the board, numbered by the part's
/// PART_BusUnit - or the part's place among its kind - and labelled by its
/// PART_Label; without, units 0 to `units` - 1, labelled by the device's
/// own labels. A device whose units come and go - a connection each -
/// counts none, and is not listed. A node's
/// `node.name` is what OpenDevice takes: the ROM device's name, or the
/// path under DEVS: of a file ("usb/acm.device"). The devices come by
/// name, each one's units in order.
///
/// CONTEXT:
/// - Waits: yes, for the files it reads, and for memory.
/// - Interrupts: no.
/// - Locks: none taken.
/// - Process: needed for DEVS:; called from a Task, it lists the ROM's
///   devices alone.
///
/// OWNERSHIP:
/// The list and its nodes are the caller's until ReleaseDeviceUnits; the
/// nodes are a snapshot, and a device added or removed later is not in
/// them.
///
/// NOTES:
/// It reads every file in DEVS: and its drawers each time: ask once and
/// keep the answer for as long as it is needed. A unit listed is one the
/// board has; whether it is free is the device's to say when it is
/// opened.
///
/// BUGS:
/// At most 48 devices are listed, with 32 units each and labels for the
/// first eight counted ones. A unit that comes and goes while the system
/// runs - a USB adapter - is listed by the parts the board was built
/// with, not by what is plugged in.
///
/// SEE ALSO:
/// `ReleaseDeviceUnits`, `FindBoardPart`, sdk/libs/expansion/devices.zig
///
/// EXAMPLES:
/// ```zig
/// const list = eb.ObtainDeviceUnits(devices.DEVIF_SERIAL, null) orelse return;
/// defer eb.ReleaseDeviceUnits(list);
/// var it = list.iterator();
/// while (it.next()) |node| {
///     const unit: *const devices.DeviceUnit = @ptrCast(@alignCast(node));
///     _ = Printf(dl, "%s %lu\n", .{ unit.node.name.?, unit.unit });
/// }
/// ```
pub fn ObtainDeviceUnits(eb: *ExpansionBase, speaks: u32, tags: ?[*]const utility.TagItem) ?*exec.List {
    _ = tags;
    const sys = eb.sys_base;
    const block = sys.AllocVec(@sizeOf(_device.Gathered), exec.MEMF_CLEAR) orelse return null;
    defer sys.FreeVec(block);
    const gathered: *_device.Gathered = @ptrCast(@alignCast(block));
    gathered.* = .{};
    _device.fromRom(sys, gathered, speaks);
    if (sys.FindTask(null).?.node.type == .process) _device.fromDisk(sys, gathered, speaks);
    _device.sortByName(gathered);

    const memory = sys.AllocVec(@sizeOf(exec.List), exec.MEMF_CLEAR) orelse return null;
    const list: *exec.List = @ptrCast(@alignCast(memory));
    sys.NewList(list);
    if (!_device.makeUnits(eb, gathered, list)) {
        while (sys.RemHead(list)) |node| sys.FreeVec(node);
        sys.FreeVec(memory);
        return null;
    }
    return list;
}
