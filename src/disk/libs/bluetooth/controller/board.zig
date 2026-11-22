// SPDX-License-Identifier: MIT
//! The board's own controllers - a radio's Bluetooth on one of the chip's
//! UARTs, PARTKIND_BLUETOOTH - added once, at the library's first open
//! from a process. A controller that is plugged in is offered by its
//! driver; one on the board is there from the start, and nothing would
//! offer it before its device is loaded. expansion.library lists the
//! units of every device that speaks DEVIF_HCI for a part of the board
//! (ObtainDeviceUnits), and each is added as a driver adds one: opening
//! it loads its device, which starts setting the controller up and
//! answers HCIERR_NOTREADY, and the controller waits on the list,
//! BTCS_OPENING, until the device offers it with AddBTController.

const sdk = @import("sdk");
const exec = sdk.exec;
const expansion = sdk.expansion;
const devices = expansion.devices;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _task = @import("../task/_task.zig");

/// Every unit of a device that speaks DEVIF_HCI for a part of the board
/// added, the first time this is asked on a process - a task cannot read
/// DEVS:, and asks again at its next open.
pub fn look(base: *BluetoothBase) void {
    const sys = base.sys_base;
    if (base.board_looked != 0) return;
    const me = sys.FindTask(null) orelse return;
    if (me.node.type != .process) return;
    base.board_looked = 1;
    const library = sys.OpenLibrary(expansion.EXPANSIONNAME, 0) orelse return;
    defer sys.CloseLibrary(library);
    const eb: *ExpansionBase = @ptrCast(library);
    const list = eb.ObtainDeviceUnits(devices.DEVIF_HCI, null) orelse return;
    defer eb.ReleaseDeviceUnits(list);
    var it = list.iterator();
    while (it.next()) |node| {
        const unit: *const devices.DeviceUnit = @fieldParentPtr("node", node);
        const name = unit.node.name orelse continue;
        var command = _task.Command{ .kind = .add, .device_name = name, .unit = unit.unit };
        _ = _task.ask(base, &command);
    }
}
