// SPDX-License-Identifier: MIT
//! The device's DOS process: the drives' nodes on dos's list.
//!
//! **A unit's drives** are made the first time a medium comes into the
//! unit, by `sdk.devices.automount`: a drive per partition when the stick
//! holds a RigidDiskBlock, named as its table says; otherwise `DU<n>`
//! over the whole stick, with the handler its first block asks for - a
//! posfs label posfs-handler with `POS\0`, a partition table with a posfs
//! partition (type 0x7F) posfs-handler with `POS\1`, anything else
//! fat-handler with `MSH\0`, a partition table first and the volume in
//! its first FAT partition, as sticks are sold. A stick with no table,
//! the volume from its first block, is a MountList entry's with `MSD\0`.
//! A name in use gets a dot added (`DU0.`), and a unit a device node
//! already opens - a MountList entry mounted by hand - gets nothing: that
//! entry is its drive, started like the device's own. The drives stay for
//! as long as the system runs, with the handlers they got: a medium going
//! takes only its volume, and the next one in the unit is read through
//! the same drives.
//!
//! Once the handlers are started, input is told a disk came, so a window
//! showing the device list (the desktop) looks again and finds the
//! volumes. Every change after that a handler hears by its change
//! interrupt (TD_ADDCHANGEINT), and tells input itself.
//!
//! **Why a process of its own.** Starting a handler waits for the
//! handler, which reads the medium through the device's task: the task
//! cannot be the one waiting.

const sdk = @import("sdk");
const td = sdk.devices.trackdisk;
const ie = sdk.devices.inputevent;
const automount = sdk.devices.automount;
const ExecBase = sdk.interface.exec.ExecBase;
const _disk = @import("_disk.zig");
const DiskBase = _disk.DiskBase;
const Unit = _disk.Unit;

pub fn mountProcess(sys: *ExecBase) callconv(.c) void {
    const process = sys.FindTask(null).?;
    const base: *DiskBase = @ptrCast(@alignCast(process.user_data orelse return));
    const port = sys.CreateMsgPort();
    base.mounter = port;
    if (base.starter) |starter| {
        base.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
    }
    const mounter = port orelse return;
    var input = automount.Input{};
    while (true) {
        _ = sys.WaitPort(mounter);
        while (sys.GetMsg(mounter)) |msg| {
            const unit: *Unit = @alignCast(@fieldParentPtr("tell", msg));
            // Cleared before the work, so a change while it is done is
            // told again.
            @atomicStore(u8, &unit.told, 0, .release);
            if (firstMedium(base, unit)) input.announce(sys, ie.IECLASS_DISKINSERTED);
        }
    }
}

/// A unit's first medium: its drives made and started. Whether a disk
/// came - nothing is made for a unit that has its drives, or whose medium
/// went before this came round to it.
fn firstMedium(base: *DiskBase, unit: *Unit) bool {
    const dl = base.dos_base orelse return false;
    if (!unit.present) return false;
    return automount.firstMedium(base.sys_base, dl, .{
        .device = td.USBDISKNAME,
        .number = unit.number,
        .name = @ptrCast(&unit.name),
        .block_bytes = unit.block_bytes,
        .medium = &unit.medium,
    });
}
