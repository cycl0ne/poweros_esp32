// SPDX-License-Identifier: MIT
//! usb/disk.device's shared parts: the base, a unit, a bound interface,
//! and the messages between the device's task and its DOS process.
//!
//! **A unit is a drive**, `DU<n>:`, and outlives the stick in it: an
//! interface bound takes the lowest units free for its logical units, and
//! a stick pulled out leaves its unit free and without a medium. What the
//! medium is - in or not, how often it changed, its size, its write
//! protection - is the task's to write; BeginIO reads the change count
//! and whether a medium is in without asking anyone.
//!
//! **A unit's drives** are the DOS process's: made once, the first time a
//! medium comes into the unit, and kept (`sdk.devices.automount`). The
//! unit carries what its own drive points at - its startup message and
//! environment - so they live as long as the device does, which is as
//! long as the system runs. After that each drive's handler hears of
//! every medium coming and going by its change interrupt
//! (TD_ADDCHANGEINT), which the task causes.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const td = sdk.devices.trackdisk;
const timer = sdk.devices.timer;
const usb = sdk.usb;
const ExecBase = sdk.interface.exec.ExecBase;
const UsbBase = sdk.interface.usb.UsbBase;
const DosBase = sdk.interface.dos.DosBase;
const automount = sdk.devices.automount;
const bot = @import("bot.zig");
const uas = @import("uas.zig");

pub const DEVICE_NAME = "disk.device";

/// The drives there can be, `DU0:` to `DU7:`.
pub const max_units = 8;
/// The logical units one interface may have that get a drive.
pub const max_luns = 4;

/// A drive.
pub const Unit = extern struct {
    /// The unit as exec has it: io_Unit points here.
    unit: exec.Unit = .{},
    number: u32 = 0,
    /// The interface its medium is behind, and its logical unit there;
    /// null while nothing is bound to the unit.
    function: ?*anyopaque = null,
    lun: u8 = 0,
    /// What INQUIRY said: the medium comes out, and the device type.
    removable: bool = false,
    device_type: u8 = 0,
    /// A medium is in.
    present: bool = false,
    /// How often a medium came or went.
    change_num: u32 = 0,
    /// The medium: its block size, its blocks, whether it is protected.
    block_bytes: u32 = 512,
    blocks: u64 align(4) = 0,
    write_protected: bool = false,
    /// The medium in refused SYNCHRONIZE CACHE: it is not asked again
    /// until another one comes in.
    sync_refused: bool = false,
    /// The handlers told when a medium comes or goes: the requests of
    /// TD_ADDCHANGEINT, kept until TD_REMCHANGEINT, under the base's
    /// `change_lock`.
    changes: exec.List = .{},
    /// The DOS process's: a message telling it a medium came into a unit
    /// whose drives are not made yet - `told` while that message is on
    /// its way.
    told: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    tell: exec.Message = .{},
    /// "DU<n>", its own drive's name.
    name: [8]u8 = @splat(0),
    /// Its drives: whether they are made, and what its own points at.
    medium: automount.MediumNode = .{},
};

/// How a bound interface reaches its device: Bulk-Only Transport, or USB
/// Attached SCSI.
pub const Transport = union(enum) {
    bot: bot.Transport,
    uas: uas.Transport,
};

/// A command run over whichever transport the interface speaks: `command`
/// to logical unit `lun`, its data stage `length` bytes into `data` (`in`)
/// or from it, given `ms` to come.
pub fn runOn(transport: *Transport, lun: u8, command: []const u8, data: ?[*]u8, length: u32, in: bool, ms: u32) bot.Result {
    return switch (transport.*) {
        .bot => |*way| bot.run(way, lun, command, data, length, in, ms),
        .uas => |*way| uas.run(way, lun, command, data, length, in, ms),
    };
}

/// The device being let go of: the transport sends nothing after this,
/// and what it waits on is taken back.
pub fn leave(sys: *ExecBase, transport: *Transport) void {
    switch (transport.*) {
        .bot => |*way| {
            @atomicStore(u8, &way.leaving, 1, .release);
            _ = sys.AbortIO(&way.bulk_in.io.std.req);
            _ = sys.AbortIO(&way.bulk_out.io.std.req);
        },
        .uas => |*way| {
            @atomicStore(u8, &way.leaving, 1, .release);
            _ = sys.AbortIO(&way.command.io.std.req);
            _ = sys.AbortIO(&way.status.io.std.req);
            if (way.status_task) |pipe| _ = sys.AbortIO(&pipe.io.std.req);
            _ = sys.AbortIO(&way.data_in.io.std.req);
            _ = sys.AbortIO(&way.data_out.io.std.req);
        },
    }
}

/// The transport's pipes closed.
pub fn closePipes(ub: *UsbBase, transport: *Transport) void {
    switch (transport.*) {
        .bot => |*way| {
            ub.CloseUSBPipe(way.bulk_in);
            ub.CloseUSBPipe(way.bulk_out);
        },
        .uas => |*way| {
            ub.CloseUSBPipe(way.command);
            ub.CloseUSBPipe(way.status);
            ub.CloseUSBPipe(way.status_task);
            ub.CloseUSBPipe(way.data_in);
            ub.CloseUSBPipe(way.data_out);
        },
    }
}

/// A bound interface: its way to the device, and its logical units'
/// drives.
pub const Function = struct {
    transport: Transport,
    units: [max_luns]?*Unit = @splat(null),
    lun_count: u8 = 0,
    /// The command that hands it to the task to bring up.
    bring_up: Command = .{},
    /// What INQUIRY, READ CAPACITY, MODE SENSE and REQUEST SENSE answer
    /// into.
    scratch: [64]u8 = @splat(0),
};

/// A command to the task.
pub const Command = extern struct {
    message: exec.Message = .{},
    kind: Kind = .bring_up,
    function: ?*anyopaque = null,

    pub const Kind = enum(u32) { bring_up, let_go };
};

pub const DiskBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    usb_base: ?*UsbBase = null,
    dos_base: ?*DosBase = null,
    /// The task that runs every command on every unit, and its stack.
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// Its ports: the units' requests, commands, the pipes' replies, the
    /// timer's.
    requests: ?*exec.MsgPort = null,
    commands: ?*exec.MsgPort = null,
    pipes: ?*exec.MsgPort = null,
    timer_port: ?*exec.MsgPort = null,
    timer_io: timer.TimeRequest = .{},
    /// The poll's timer is out.
    polling: bool = false,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The DOS process's port: units whose medium changed.
    mounter: ?*exec.MsgPort = null,
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad2: [3]u8 = .{ 0, 0, 0 },
    /// Who is bound to which unit: written by a bind (the bus's process)
    /// and the task.
    lock: exec.SignalSemaphore = .{},
    /// The units' change interrupts: BeginIO takes them from any task,
    /// the task walks them.
    change_lock: exec.Lock = .{},
    units: [max_units]Unit = @splat(.{}),
};

pub fn diskBase(dev: *exec.Device) *DiskBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

pub fn unitOf(io: *exec.IORequest) *Unit {
    return @alignCast(@fieldParentPtr("unit", io.unit.?));
}

pub fn baseOf(io: *exec.IORequest) *DiskBase {
    return diskBase(io.device.?);
}

pub fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @alignCast(@fieldParentPtr("req", io));
}

pub fn requestOf(msg: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", msg);
}

pub fn functionOf(unit: *const Unit) ?*Function {
    return @ptrCast(@alignCast(unit.function orelse return null));
}

/// A unit's geometry: a run of blocks, as a card's is.
pub fn geometry(unit: *const Unit, into: *td.DriveGeometry) void {
    into.* = .{
        .sector_size = unit.block_bytes,
        .total_sectors = unit.blocks,
        .cylinders = @truncate(unit.blocks),
        .cyl_sectors = 1,
        .heads = 1,
        .track_sectors = 1,
        .buf_mem_type = exec.MEMF_ANY,
        .device_type = unit.device_type,
        // Every unit's medium comes out: a stick with the whole device.
        .flags = td.DGF_REMOVABLE,
        .erase_size = 0,
        .write_size = unit.block_bytes,
        .map_base = 0,
    };
}

/// Whether `length` bytes from `offset` are whole blocks of the medium.
pub fn inside(unit: *const Unit, offset: u64, length: u64) bool {
    const size = unit.block_bytes;
    if (offset % size != 0 or length % size != 0) return false;
    const total = unit.blocks * size;
    return offset <= total and length <= total - offset;
}
