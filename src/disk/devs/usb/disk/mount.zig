// SPDX-License-Identifier: MIT
//! The device's DOS process: the drives' nodes on dos's list.
//!
//! **A unit's node** is made the first time a medium comes into the unit:
//! `DU<n>` on the device list, as a MountList entry would make it - a
//! handler, a startup message naming this device and the unit - and its
//! handler started at once, which reads the medium and puts its volume on
//! the list. Which handler is the first medium's to say (`probe`): a posfs
//! label in its first block gives posfs-handler with `POS\0` (the whole
//! medium is the volume), a partition table with a posfs partition (type
//! 0x7F) posfs-handler with `POS\1`; anything else - a FAT stick, or one
//! that cannot be read - fat-handler with `MSH\0`: the whole medium, with
//! a partition table first and the volume in its first FAT partition, as
//! sticks and cards are sold and as `SD0:`'s is. So the node carries no
//! geometry, and a stick formatted here gets the same. One with no table,
//! the volume from its first block, is a MountList entry's with
//! `MSD\0`, which then stands for the unit. The node stays for as long as
//! the system runs, with the handler it got: a medium going takes only
//! its volume, and the next one in the unit is read by that handler. A
//! node of that name already there - a MountList's, mounted by hand - is
//! left as it is and told like the device's own.
//!
//! Once its handler is started, input is told a disk came, so a window
//! showing the device list (the desktop) looks again and finds the
//! volume. Every change after that the handler hears by its change
//! interrupt (TD_ADDCHANGEINT), and tells input itself.
//!
//! **Why a process of its own.** Starting a handler waits for the
//! handler, which reads the medium through the device's task: the task
//! cannot be the one waiting.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const td = sdk.devices.trackdisk;
const ie = sdk.devices.inputevent;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const posfs = dos.posfs;
const _disk = @import("_disk.zig");
const DiskBase = _disk.DiskBase;
const Unit = _disk.Unit;

/// The handler a drive is mounted with unless its first medium is
/// posfs's, and what it is started with.
const handler_name = "fat-handler";
const handler_stack: u32 = 16384;
const handler_pri: i32 = 5;

/// The handler a unit's node gets, and the DosType it is started with.
const Choice = struct { handler: [*:0]const u8, dos_type: u32 };

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
    var input = Input{};
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

/// A unit's first medium: its node made and its handler started, which
/// reads the medium and puts its volume on the list. Whether it was -
/// nothing is made for a unit that has its node, or whose medium went
/// before this came round to it.
fn firstMedium(base: *DiskBase, unit: *Unit) bool {
    const dl = base.dos_base orelse return false;
    if (@atomicLoad(bool, &unit.node_made, .acquire) or !unit.present) return false;
    makeNode(dl, unit, probe(base.sys_base, unit));
    @atomicStore(bool, &unit.node_made, true, .release);
    var name: [16:0]u8 = @splat(0);
    const length = nameLength(unit);
    @memcpy(name[0..length], unit.name[0..length]);
    name[length] = ':';
    // Asking dos for the handler's port starts the handler.
    const dp = dl.GetDeviceProc(&name, null) orelse return false;
    dl.FreeDeviceProc(dp);
    return true;
}

fn nameLength(unit: *const Unit) usize {
    var length: usize = 0;
    while (length < unit.name.len and unit.name[length] != 0) length += 1;
    return length;
}

/// What the medium in a unit holds, read from its first block: a posfs
/// volume from that block on, a partition table with a posfs partition,
/// or - anything else, or a block that cannot be read - what fat-handler
/// reads, which says itself what is wrong with a medium it cannot.
fn probe(sys: *ExecBase, unit: *Unit) Choice {
    const fat_choice: Choice = .{ .handler = handler_name, .dos_type = dos.ID_MSDOS_DISK_HD };
    const port = sys.CreateMsgPort() orelse return fat_choice;
    defer sys.DeleteMsgPort(port);
    var io: exec.IOStdReq = .{ .req = .{ .message = .{ .reply_port = port, .length = @sizeOf(exec.IOStdReq) } } };
    if (sys.OpenDevice(td.USBDISKNAME, unit.number, &io.req, 0) != 0) return fat_choice;
    defer sys.CloseDevice(&io.req);
    const bytes = unit.block_bytes;
    const memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return fat_choice;
    defer sys.FreeVec(memory);
    io.req.command = exec.CMD_READ;
    io.offset = 0;
    io.length = bytes;
    io.data = memory;
    if (sys.DoIO(&io.req) != 0) return fat_choice;
    const first_block = @as([*]const u8, @ptrCast(memory))[0..bytes];
    if (posfs.table.isLabel(first_block)) return .{ .handler = posfs.HANDLER_NAME, .dos_type = posfs.ID_POSFS_DISK };
    if (posfs.table.volumeIn(first_block) != null) return .{ .handler = posfs.HANDLER_NAME, .dos_type = posfs.ID_POSFS_MBR };
    return fat_choice;
}

/// `DU<n>` on the device list, with what its handler is started with.
fn makeNode(dl: *DosBase, unit: *Unit, choice: Choice) void {
    const node = dl.MakeDosEntry(@ptrCast(&unit.name), dos.DLT_DEVICE) orelse return;
    unit.environ = .{ .dos_type = choice.dos_type };
    unit.startup = .{ .unit = unit.number, .device = td.USBDISKNAME, .environ = &unit.environ };
    node.misc.handler.handler = choice.handler;
    node.misc.handler.stack_size = handler_stack;
    node.misc.handler.priority = handler_pri;
    node.misc.handler.startup = @intFromPtr(&unit.startup);
    // A node of the name already there is someone's own mount, and is
    // the drive from now on.
    if (!dl.AddDosEntry(node)) dl.FreeDosEntry(node);
}

/// input.device, for telling it a disk came or went: opened the first
/// time, and kept.
const Input = struct {
    port: ?*exec.MsgPort = null,
    io: exec.IOStdReq = .{},
    open: bool = false,
    event: ie.InputEvent = .{},

    fn announce(input: *Input, sys: *ExecBase, class: u32) void {
        if (!input.open) {
            const port = input.port orelse sys.CreateMsgPort() orelse return;
            input.port = port;
            input.io = .{};
            input.io.req.message.reply_port = port;
            input.io.req.message.length = @sizeOf(exec.IOStdReq);
            if (sys.OpenDevice(sdk.devices.input.INPUTNAME, 0, &input.io.req, 0) != 0) return;
            input.open = true;
        }
        input.event = .{ .class = class };
        input.io.req.command = sdk.devices.input.IND_WRITEEVENT;
        input.io.length = @sizeOf(ie.InputEvent);
        input.io.data = @ptrCast(&input.event);
        _ = sys.DoIO(&input.io.req);
    }
};
