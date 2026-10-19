// SPDX-License-Identifier: MIT
//! The device's DOS process: the units' drives on dos's list, once.
//!
//! **Each unit** gets the drives `sdk.devices.automount` makes: a drive
//! per partition when the namespace holds a RigidDiskBlock, named as its
//! table says, with the file system the table brings when the ROM has
//! none of its own; with a GPT, those of the table in its PowerOS
//! container and one for each other GPT partition with a FAT or posfs
//! volume (`NV0`, then `NV0P2`); otherwise `NV<n>` over the whole namespace, with the
//! handler its first block asks for. A name in use gets a dot added
//! (`DH0.`). A unit a device node already opens - a MountList entry
//! mounted by hand before BindDrivers - gets nothing: that entry is its
//! drive, and is started like the device's own.
//!
//! An SSD does not change, so the process looks once, tells input a disk
//! came when one did - so a window showing the device list (the desktop)
//! looks again - and ends.
//!
//! **Why a process of its own.** Starting a handler waits for the
//! handler, which reads the SSD through the device's task; and reading
//! the table opens the device, which is on exec's list only once its init
//! is done.

const sdk = @import("sdk");
const ie = sdk.devices.inputevent;
const automount = sdk.devices.automount;
const ExecBase = sdk.interface.exec.ExecBase;
const _nvme = @import("_nvme.zig");
const NvmeBase = _nvme.NvmeBase;

/// A unit's own drive, without the colon.
const drive_names = [_][*:0]const u8{ "NV0", "NV1", "NV2", "NV3", "NV4", "NV5", "NV6", "NV7" };

comptime {
    if (drive_names.len != _nvme.max_units) @compileError("a drive name for each unit");
}

pub fn mountProcess(sys: *ExecBase) callconv(.c) void {
    const process = sys.FindTask(null).?;
    const base: *NvmeBase = @ptrCast(@alignCast(process.user_data orelse return));
    // The device's init waits for this; nothing is opened before, as the
    // device is not on the list until init returns.
    if (base.starter) |starter| {
        base.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
    }
    const dl = base.dos_base orelse return;
    var came = false;
    for (base.units[0..base.unit_count]) |*unit| {
        if (automount.firstMedium(sys, dl, .{
            .device = _nvme.DEVICE_NAME,
            .number = unit.number,
            .name = drive_names[unit.number],
            .block_bytes = unit.blockBytes(),
            .medium = &unit.medium,
        })) came = true;
    }
    if (!came) return;
    var input = automount.Input{};
    input.announce(sys, ie.IECLASS_DISKINSERTED);
    input.end(sys);
}
