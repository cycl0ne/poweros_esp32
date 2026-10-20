// SPDX-License-Identifier: MIT
//! The device's DOS process: the card's drives on dos's list.
//!
//! **The first card identified** in the slot gets the drives
//! `sdk.devices.automount` makes: a drive per partition when it holds a
//! RigidDiskBlock, named as its table says; with a GPT, those of the
//! table in its PowerOS container and one for each other GPT partition
//! with a FAT or posfs volume (`SD0`, then `SD0P2`); otherwise `SD0` over the whole
//! card, with the handler its first block asks for - posfs-handler for a
//! posfs label (`POS\0`) or a partition table with a posfs partition
//! (`POS\1`), fat-handler with `MSH\0` for anything else, a partition
//! table first and the volume in its first FAT partition, as cards are
//! sold. A name in use gets a dot added (`SD0.`). A drive that opens the
//! slot already - `Mount SD0:` from the MountList, done by hand before -
//! is the card's drive instead, and is started as the device's own would
//! be. The drives stay for as long as the system runs: a card going takes
//! only its volumes, and the next card is read through the same drives.
//!
//! The process looks once when it starts - the task's first look at the
//! slot may have found a card before there was anyone to tell - and then
//! each time the task says a card came while the drives are not made yet.
//! Once the handlers are started, input is told a disk came, so a window
//! showing the device list (the desktop) looks again.
//!
//! **Why a process of its own.** Starting a handler waits for the
//! handler, which reads the card through the device's task: the task
//! cannot be the one waiting.

const sdk = @import("sdk");
const ie = sdk.devices.inputevent;
const automount = sdk.devices.automount;
const ExecBase = sdk.interface.exec.ExecBase;
const card = @import("card.zig");
const _sdcard = @import("_sdcard.zig");
const SdCardBase = _sdcard.SdCardBase;

pub fn mountProcess(sys: *ExecBase) callconv(.c) void {
    const process = sys.FindTask(null).?;
    const sb: *SdCardBase = @ptrCast(@alignCast(process.user_data orelse return));
    const port = sys.CreateMsgPort();
    // Under the lock the task reads the port under: either the task finds
    // the port and tells, or this finds the card the task identified.
    sys.AcquireLock(&sb.change_lock);
    sb.mounter = port;
    const card_in = sb.present != 0;
    sys.ReleaseLock(&sb.change_lock);
    if (sb.starter) |starter| {
        sb.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(sb.start_signal));
    }
    const mounter = port orelse return;
    var input = automount.Input{};
    if (card_in and firstMedium(sb)) input.announce(sys, ie.IECLASS_DISKINSERTED);
    while (true) {
        _ = sys.WaitPort(mounter);
        while (sys.GetMsg(mounter)) |_| {
            // Cleared before the work, so a card identified while it is
            // done is told again.
            @atomicStore(u8, &sb.told, 0, .release);
            if (firstMedium(sb)) input.announce(sys, ie.IECLASS_DISKINSERTED);
        }
    }
}

/// The first card's drives made and started. Whether a disk came -
/// nothing is made once the drives are, or for a card gone before this
/// came round to it.
fn firstMedium(sb: *SdCardBase) bool {
    const dl = sb.dos_base orelse return false;
    if (sb.present == 0) return false;
    return automount.firstMedium(sb.sys_base, dl, .{
        .device = _sdcard.DEVICE_NAME,
        .number = 0,
        .name = _sdcard.DRIVE_NAME,
        .block_bytes = @intCast(card.block_bytes),
        .medium = &sb.medium,
    });
}
