// SPDX-License-Identifier: MIT
//! A removable unit's drives, made by its device when the unit's first
//! medium comes in: what usb/disk.device and sdcard.device both do from
//! their DOS process.
//!
//! **What the first medium gets** (`mountMedium`), in this order:
//! 1. **Nothing**, when a device node on dos's list already opens the
//!    unit - a MountList entry mounted by hand, say - which is the unit's
//!    drive then: one medium has one claimant.
//! 2. **A drive per partition**, when the medium holds a sound
//!    RigidDiskBlock: rdb.library's MountPartition for every partition
//!    not marked PBFF_NOMOUNT, under the partition's name, with a dot
//!    added while the name is taken (`DH0` becomes `DH0.` beside the flash
//!    disk's). A partition whose file system cannot go on the medium is
//!    passed over. The unit gets no drive of its own.
//! 3. **The unit's own drive** otherwise (`DU0`, `SD0`), over the whole
//!    medium, with the file system its first block says
//!    (`sdk.dos.filesystems.wholeMediumChoice`), dotted the same way.
//!    It carries no geometry, so its handler asks the device how large
//!    each medium is.
//!
//! Then each drive's handler is started (`startDrives`), which reads the
//! medium and puts its volume on the list, and the device tells input a
//! disk came (`Input`), so a window showing the device list looks again.
//!
//! **Once per unit.** The drives stay for the system's life with the
//! handlers they got: a medium going takes only its volume, and the next
//! one in the unit is read through the same drives, whatever is on it. A
//! card with another table needs a restart to be mounted as that table
//! says.
//!
//! **Where it runs.** In a DOS process of the device's own: starting a
//! handler waits for the handler, which reads the medium through the
//! device's task, so the task cannot be the one waiting.

const exec = @import("../libs/exec/exec.zig");
const dos = @import("../libs/dos/dos.zig");
const rdb = @import("../libs/rdb/rdb.zig");
const ie = @import("inputevent.zig");
const input_device = @import("input.zig");
const ExecBase = @import("../interface/exec.zig").ExecBase;
const DosBase = @import("../interface/dos.zig").DosBase;
const RDBBase = @import("../interface/rdb.zig").RDBBase;

/// What a unit's own drive's handler is started with.
const handler_stack: u32 = 16384;
const handler_pri: i32 = 5;

/// The most drives one medium gets: a partition for each PartitionBlock
/// a table's first blocks hold, or the unit's own.
pub const max_drives = 16;

/// The rdb.library that has MountPartition.
const rdb_version = 1;
const rdb_revision = 2;

/// What a unit keeps for its drives: whether its first medium has been
/// looked at, and what the unit's own drive points at, which lives as
/// long as the device - for the system's life.
pub const MediumNode = extern struct {
    /// The first medium was looked at: nothing is looked at again.
    node_made: bool = false,
    /// The unit's own drive's startup message and environment.
    startup: dos.FileSysStartupMsg = .{},
    environ: dos.DosEnvec = .{},
};

/// The drives a medium got, by name, to be started.
pub const Drives = struct {
    names: [max_drives]rdb.MountName = undefined,
    count: u32 = 0,

    fn add(drives: *Drives, name: []const u8) void {
        if (drives.count == max_drives) return;
        const into = &drives.names[drives.count];
        into.* = @splat(0);
        @memcpy(into[0..name.len], name);
        drives.count += 1;
    }
};

/// A unit of a device, as its drives are made for it.
pub const Unit = struct {
    /// The device as OpenDevice is given it (`usb/disk.device`).
    device: [*:0]const u8,
    number: u32,
    /// The unit's own drive's name, without the colon (`DU0`).
    name: [*:0]const u8,
    /// The medium's block size, for reading its first block.
    block_bytes: u32,
    medium: *MediumNode,
};

/// A unit's first medium: its drives made and started. Whether a disk
/// came - a drive that has the medium now, which input is to be told of.
/// Nothing is done for a unit whose first medium was looked at already.
///
/// CONTEXT:
/// - Waits: yes, on the device, dos's list and the handlers.
/// - Process: a Process of the device's own, never its task.
pub fn firstMedium(sys: *ExecBase, dl: *DosBase, unit: Unit) bool {
    if (@atomicLoad(bool, &unit.medium.node_made, .acquire)) return false;
    var drives: Drives = .{};
    mountMedium(sys, dl, unit, &drives);
    @atomicStore(bool, &unit.medium.node_made, true, .release);
    startDrives(dl, &drives);
    return drives.count != 0;
}

/// The drives a unit's first medium gets, made and on dos's list, their
/// names in `drives`; nothing started.
pub fn mountMedium(sys: *ExecBase, dl: *DosBase, unit: Unit, drives: *Drives) void {
    if (claimant(dl, unit, drives)) return;
    if (mountTable(sys, unit, drives)) return;
    ownDrive(sys, dl, unit, drives);
}

/// Every drive's handler started: asking dos for its port starts it.
pub fn startDrives(dl: *DosBase, drives: *const Drives) void {
    for (drives.names[0..drives.count]) |*name| {
        var drive: [dos.MAX_DEVICE_NAME + 1:0]u8 = @splat(0);
        const length = lengthOf(name);
        @memcpy(drive[0..length], name[0..length]);
        drive[length] = ':';
        const dp = dl.GetDeviceProc(&drive, null) orelse continue;
        dl.FreeDeviceProc(dp);
    }
}

fn lengthOf(name: *const rdb.MountName) usize {
    var length: usize = 0;
    while (length < name.len and name[length] != 0) length += 1;
    return length;
}

/// Whether a device node already opens the unit; its name goes in
/// `drives`, so it is started like the unit's own.
fn claimant(dl: *DosBase, unit: Unit, drives: *Drives) bool {
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    const list = dl.LockDosList(flags) orelse return false;
    defer dl.UnLockDosList(flags);
    var entry = dl.NextDosEntry(list, dos.LDF_DEVICES);
    while (entry) |node| : (entry = dl.NextDosEntry(node, dos.LDF_DEVICES)) {
        const startup = dos.filehandler.startupOf(node.misc.handler.startup) orelse continue;
        if (!dos.filehandler.opensUnit(startup, unit.device, unit.number)) continue;
        drives.add(nameOf(node.name));
        return true;
    }
    return false;
}

fn nameOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0 and length < dos.MAX_DEVICE_NAME) length += 1;
    return text[0..length];
}

/// The medium's partitions mounted, when it holds a sound RigidDiskBlock.
/// Whether it does: such a medium gets no drive of its own, even when
/// none of its partitions could be mounted.
fn mountTable(sys: *ExecBase, unit: Unit, drives: *Drives) bool {
    const lib = sys.OpenLibrary(rdb.RDBNAME, rdb_version) orelse return false;
    defer sys.CloseLibrary(lib);
    if (lib.version == rdb_version and lib.revision < rdb_revision) return false;
    const rb: *RDBBase = @ptrCast(lib);
    const handle = rb.OpenRDB(unit.device, unit.number, null) orelse return false;
    defer rb.CloseRDB(handle);
    if (handle.flags & rdb.RDBF_FOUND == 0) return false;
    var part = rb.NextPartition(handle, null);
    while (part) |partition| : (part = rb.NextPartition(handle, partition)) {
        if (partition.block.flags & dos.hardblocks.PBFF_NOMOUNT != 0) continue;
        var name: rdb.MountName = undefined;
        if (rb.MountPartition(handle, partition, &name, 0) != rdb.RDBERR_OK) continue;
        drives.add(nameOf(&name));
    }
    return true;
}

/// The unit's own drive over the whole medium, with the file system its
/// first block says, under the unit's name or that name dotted.
fn ownDrive(sys: *ExecBase, dl: *DosBase, unit: Unit, drives: *Drives) void {
    const choice = probe(sys, unit);
    const medium = unit.medium;
    medium.environ = .{ .dos_type = choice.dos_type };
    medium.startup = .{ .unit = unit.number, .device = unit.device, .environ = &medium.environ };
    var text: rdb.MountName = @splat(0);
    const base_name = nameOf(unit.name);
    @memcpy(text[0..base_name.len], base_name);
    var length = base_name.len;
    while (true) {
        const node = dl.MakeDosEntry(&text, dos.DLT_DEVICE) orelse return;
        node.misc.handler.handler = choice.handler;
        node.misc.handler.stack_size = handler_stack;
        node.misc.handler.priority = handler_pri;
        node.misc.handler.startup = @intFromPtr(&medium.startup);
        if (dl.AddDosEntry(node)) break;
        dl.FreeDosEntry(node);
        if (length == dos.MAX_DEVICE_NAME) return;
        text[length] = '.';
        length += 1;
    }
    drives.add(text[0..length]);
}

/// What the medium's first block says it holds; what a block that cannot
/// be read gives, too, when the device cannot be opened.
fn probe(sys: *ExecBase, unit: Unit) dos.filesystems.Choice {
    const unread = dos.filesystems.wholeMediumChoice("");
    const port = sys.CreateMsgPort() orelse return unread;
    defer sys.DeleteMsgPort(port);
    var io: exec.IOStdReq = .{ .req = .{ .message = .{ .reply_port = port, .length = @sizeOf(exec.IOStdReq) } } };
    if (sys.OpenDevice(unit.device, unit.number, &io.req, 0) != 0) return unread;
    defer sys.CloseDevice(&io.req);
    const memory = sys.AllocVec(unit.block_bytes, exec.MEMF_ANY) orelse return unread;
    defer sys.FreeVec(memory);
    io.req.command = exec.CMD_READ;
    io.offset = 0;
    io.length = unit.block_bytes;
    io.data = memory;
    if (sys.DoIO(&io.req) != 0) return unread;
    return dos.filesystems.wholeMediumChoice(@as([*]const u8, @ptrCast(memory))[0..unit.block_bytes]);
}

/// input.device, for telling it a disk came or went: opened the first
/// time, and kept.
pub const Input = struct {
    port: ?*exec.MsgPort = null,
    io: exec.IOStdReq = .{},
    open: bool = false,
    event: ie.InputEvent = .{},

    /// An event of `class` (IECLASS_DISKINSERTED, IECLASS_DISKREMOVED)
    /// written to input.
    pub fn announce(input: *Input, sys: *ExecBase, class: u32) void {
        if (!input.open) {
            const port = input.port orelse sys.CreateMsgPort() orelse return;
            input.port = port;
            input.io = .{};
            input.io.req.message.reply_port = port;
            input.io.req.message.length = @sizeOf(exec.IOStdReq);
            if (sys.OpenDevice(input_device.INPUTNAME, 0, &input.io.req, 0) != 0) return;
            input.open = true;
        }
        input.event = .{ .class = class };
        input.io.req.command = input_device.IND_WRITEEVENT;
        input.io.length = @sizeOf(ie.InputEvent);
        input.io.data = @ptrCast(&input.event);
        _ = sys.DoIO(&input.io.req);
    }
};
