// SPDX-License-Identifier: MIT
//! nvme.device: NVM Express SSDs on PCI Express as block devices - the
//! block device API (sdk/devices/trackdisk.zig) on each namespace of
//! each controller pci.library finds. Unit 0 is the first namespace of
//! the first controller, as `NV0:` would be.
//!
//!   CMD_READ         io_Length bytes from io_Offset into io_Data; both
//!                    whole blocks of the namespace, and on it.
//!   CMD_WRITE        io_Length bytes from io_Data at io_Offset.
//!   CMD_UPDATE       what the controller holds in its volatile write
//!                    cache put on the medium (Flush); at once where it
//!                    has no such cache.
//!   TDCMD_TRIM       io_Length bytes from io_Offset deallocated (Dataset
//!                    Management): the controller may forget them, and
//!                    they read as it says - IOERR_NOCMD where it cannot.
//!   TDCMD_ERASE,
//!   CMD_CLEAR        answered: an SSD erases for itself, and the device
//!                    buffers nothing.
//!   TD_GETGEOMETRY   into io_Data: the namespace's block size and
//!                    blocks.
//!   TD_GETNUMTRACKS  io_Actual: its blocks.
//!   TD_PROTSTATUS    io_Actual: 0, it is writable.
//!   TD_CHANGENUM     io_Actual: 0; 1 once its controller is given up.
//!   TD_CHANGESTATE   io_Actual: 0, a medium is in; 1 once its
//!                    controller is given up, which takes the medium.
//!
//! A unit whose controller was given up (task.zig) answers every other
//! command TDERR_NoCard, as a drive with no medium in it.
//!
//! **Bringing it up.** The first open makes the device: pci.library is
//! opened, which brings up the board's PCI Express ports, and the
//! device's task claims every NVM Express function there (class
//! 0x010802), brings each controller up and makes a unit of each of its
//! namespaces (controller.zig). A unit that has no namespace does not
//! open. A namespace whose blocks carry metadata, or are not 512 bytes to
//! 4 KiB, is left out.
//!
//! **In the ROM** the device is made at cold start instead, so that the
//! machine can start from an SSD: its init makes pci.library from the
//! library's ROM tag where nothing has made it yet - ramlib, which
//! otherwise would, comes after dos - and once the controllers are up
//! reads each namespace's RigidDiskBlock, or the table in its GPT's
//! PowerOS container, and hands its partitions to expansion.library as
//! boot nodes (`sdk.expansion.bootdisk`): a bootable one at its
//! de_BootPri, the others at -128, all of them mounted when dos takes
//! the nodes.
//!
//! **The work** is the task's (task.zig): reads and writes in pieces of
//! the controller's largest transfer, several out at once, straight into
//! and out of the caller's pages. BeginIO answers what it knows - the
//! geometry, the protection, the change count - and queues the rest.
//!
//! **The drives** are made once the device is up, by a DOS process of
//! its own (mount.zig): a drive per partition where a namespace holds a
//! RigidDiskBlock or a GPT, `NV<n>` over the whole namespace otherwise - unless a
//! device node opens the unit already - a boot node, or a MountList
//! entry mounted by hand - which is then its drive. The ROM's copy, made
//! before dos, starts the process at its first open once dos is up.
//!
//! The device stays once made: it owns its task, its controllers'
//! interrupts and the memory they read and write.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const pci = sdk.pci;
const td = sdk.devices.trackdisk;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const _nvme = @import("_nvme.zig");
const NvmeBase = _nvme.NvmeBase;
const task_file = @import("task.zig");
const mount = @import("mount.zig");

pub const DEVICE_NAME = _nvme.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 6;
const BUILD_DATE = "26.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// The task: a transfer and a log line deep, nothing recursive.
const task_stack = 8192;
/// Beside the handlers, as sdcard.device's is: a file system waits on it.
const task_pri = 5;
/// The mount process: below the handlers it starts, as sdcard.device's.
const mount_stack = 8192;
const mount_pri = 4;

// --- the device ---------------------------------------------------------------------

/// Whether `io` can wait: it will be replied, so it needs a reply port.
fn canWait(io: *exec.IORequest) bool {
    if (io.message.reply_port != null) return true;
    io.err = exec.IOERR_NOREPLYPORT;
    io.flags |= exec.IOF_QUICK;
    return false;
}

/// Onto the task's queue; it will be replied, so not quick I/O.
fn queue(base: *NvmeBase, io: *exec.IORequest) void {
    if (!canWait(io)) return base.sys_base.ReplyIO(io);
    io.flags &= ~exec.IOF_QUICK;
    base.sys_base.PutMsg(base.requests.?, &io.message);
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const base = _nvme.nvmeBase(dev);
    io.err = 0;
    const unit = _nvme.unitOf(io);
    const req = _nvme.stdReq(io);
    req.actual = 0;
    if (unit.gone() and io.command != td.TD_CHANGENUM and io.command != td.TD_CHANGESTATE) {
        io.err = td.TDERR_NoCard;
        return base.sys_base.ReplyIO(io);
    }
    switch (io.command) {
        exec.CMD_READ, exec.CMD_WRITE, exec.CMD_UPDATE, td.TDCMD_TRIM => return queue(base, io),
        td.TDCMD_ERASE, exec.CMD_CLEAR => {},
        td.TD_GETGEOMETRY => if (req.data) |data| {
            _nvme.geometry(unit, @ptrCast(@alignCast(data)));
        } else {
            io.err = exec.IOERR_BADADDRESS;
        },
        td.TD_GETNUMTRACKS => req.actual = unit.blocks,
        td.TD_PROTSTATUS => req.actual = 0,
        td.TD_CHANGENUM, td.TD_CHANGESTATE => req.actual = @intFromBool(unit.gone()),
        else => io.err = exec.IOERR_NOCMD,
    }
    base.sys_base.ReplyIO(io);
}

/// A request the task has not taken yet is taken off its queue and
/// replied; one the task is busy with cannot be stopped.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const base = _nvme.nvmeBase(dev);
    const sys = base.sys_base;
    if (!sys.RemoveMsg(base.requests.?, &io.message)) return -1;
    io.err = exec.IOERR_ABORTED;
    sys.ReplyIO(io);
    return 0;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const base = _nvme.nvmeBase(dev);
    if (unit_number >= base.unit_count) return td.TDERR_BadUnitNum;
    // The ROM's copy started before dos: its DOS process is started by
    // the first opener that finds dos up.
    if (in_rom and base.dos_base == null) startMounter(base);
    const unit = &base.units[unit_number];
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    unit.unit.open_cnt += 1;
    io.unit = &unit.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    _ = abortIO(dev, io);
    _nvme.unitOf(io).unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: it owns its task, the controllers' interrupts and
/// the memory they use, and a file system may sit on it.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

// --- the start ----------------------------------------------------------------------

/// pci.library opened, the units numbered, the task started and waited
/// for until the controllers are up. Null when the task cannot start.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _nvme.nvmeBase(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;
    for (&base.units, 0..) |*unit, number| unit.* = .{ .number = @intCast(number) };
    base.pci_base = @ptrCast(openPci(sys_base) orelse return null);

    const signal = sys_base.AllocSignal(-1);
    if (signal < 0) return null;
    defer sys_base.FreeSignal(signal);
    base.start_signal = signal;

    const stack = sys_base.AllocMem(task_stack, exec.MEMF_CLEAR) orelse return null;
    base.stack = stack;
    base.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + task_stack,
    };
    base.starter = sys_base.FindTask(null);
    _ = sys_base.AddTask(&base.task, &task_file.nvmeTask, null);
    _ = sys_base.Wait(@as(u32, 1) << @intCast(signal));
    // Without its port the task has ended; without units it stays, and
    // every open is refused.
    if (base.requests == null) return null;
    if (in_rom) bootPartitions(base, dev);
    // Last: nothing after this fails, so the process never runs on a base
    // that is freed. The ROM's copy has no dos to start it with yet: its
    // first opener starts it (`open`).
    if (!in_rom and base.unit_count != 0) startMounter(base);
    return dev;
}

/// pci.library, opened. The ROM's copy is made at cold start, before
/// ramlib, which makes a library the ROM has when it is first opened: the
/// library is made from its ROM tag here then, as ramlib would.
fn openPci(sys: *ExecBase) ?*exec.Library {
    if (sys.OpenLibrary(pci.PCINAME, 2)) |lib| return lib;
    if (!in_rom) return null;
    const tag = sys.FindResident(pci.PCINAME) orelse return null;
    if (tag.version < 2 or tag.type != .library) return null;
    _ = sys.InitResident(tag, null) orelse return null;
    return sys.OpenLibrary(pci.PCINAME, 2);
}

/// A namespace's blocks, as `bootdisk` reads them: one at a time, through
/// the device's own BeginIO, into a block of the init's.
const NamespaceDisk = struct {
    sys: *ExecBase,
    io: *exec.IOStdReq,
    block: []u8,

    pub fn readBlock(disk: NamespaceDisk, number: u32, into: []u8) bool {
        if (into.len > disk.block.len) return false;
        disk.io.req.command = exec.CMD_READ;
        disk.io.data = disk.block.ptr;
        disk.io.length = disk.block.len;
        disk.io.offset = @as(u64, number) * disk.block.len;
        if (disk.sys.DoIO(&disk.io.req) != 0) return false;
        @memcpy(into, disk.block[0..into.len]);
        return true;
    }
};

/// The partitions each namespace's RigidDiskBlock names, or the table in
/// its GPT's PowerOS container, handed to expansion.library as boot
/// nodes: dos takes them as soon as the cold start reaches it. A
/// namespace with neither has none, and gets its drives from the DOS
/// process.
fn bootPartitions(base: *NvmeBase, dev: *exec.Device) void {
    const sys = base.sys_base;
    const port = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(port);
    for (base.units[0..base.unit_count]) |*unit| {
        const bytes = unit.blockBytes();
        const memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return;
        defer sys.FreeVec(memory);
        var io: exec.IOStdReq = .{ .req = .{
            .message = .{ .reply_port = port, .length = @sizeOf(exec.IOStdReq) },
            .device = dev,
            .unit = &unit.unit,
        } };
        const disk = NamespaceDisk{ .sys = sys, .io = &io, .block = @as([*]u8, @ptrCast(memory))[0..bytes] };
        sdk.expansion.bootdisk.mountPartitions(sys, DEVICE_NAME, unit.number, disk, bytes, 0);
    }
}

/// The DOS process that makes the units' drives, started and waited for
/// until it runs. Without dos.library or the process the device serves
/// all the same, and a unit is mounted by hand (a MountList entry).
fn startMounter(base: *NvmeBase) void {
    const sys = base.sys_base;
    const dl: *DosBase = @ptrCast(sys.OpenLibrary(dos.DOSNAME, 0) orelse return);
    base.dos_base = dl;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return;
    defer sys.FreeSignal(signal);
    base.start_signal = signal;
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&mount.mountProcess) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(@as([*:0]const u8, "nvme.device mount")) },
        .{ .tag = dos.NP_StackSize, .data = mount_stack },
        .{ .tag = dos.NP_Priority, .data = @as(usize, @bitCast(@as(isize, mount_pri))) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(base) },
        .{},
    };
    base.starter = sys.FindTask(null);
    if (dl.CreateNewProc(&tags) == null) {
        base.starter = null;
        return;
    }
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
}

/// The jump table: the six standard vectors.
const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(NvmeBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

const speaks = [_]u32{ devices.DEVIF_BLOCK, 0 };

const labels = [_][*:0]const u8{ "NV0:", "NV1:", "NV2:", "NV3:", "NV4:", "NV5:", "NV6:", "NV7:" };

/// AUTOINIT and DEVICEINFO: made when something opens it - ramlib loads
/// the file from DEVS: and hands this tag to InitResident - and opened by
/// BindDrivers, as ObtainDeviceUnits lists it. In the ROM it is a
/// cold-start device too: before dos.library (-128), which takes its
/// boot nodes, and after timer.device (50), whose timer its task waits
/// on, beside sdcard.device.
export const nvme_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&nvme_device_tag),
        .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO | if (in_rom) exec.RTF_COLDSTART else 0,
        .version = DEVICE_VERSION,
        .pri = if (in_rom) 30 else 0,
        .type = .device,
        .name = DEVICE_NAME,
        .id_string = DEVICE_VERSION_STRING[1..],
        .init = &init_table,
    },
    .speaks = &speaks,
    .units = _nvme.max_units,
    .unit_labels = &labels,
};

/// A device is not a command.
fn programEntry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20;
}

/// The "$VER:" string, which `Version <file>` looks for.
const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;

/// Whether this is the ROM's copy: the kernel's root lists the ROM's
/// modules, a program's does not.
const in_rom = @hasDecl(@import("root"), "rom_modules");

// The file's entry and its version string, which only the file has: in
// the ROM there is no file, and every module the ROM takes from the disk
// would bring its own by the same names.
comptime {
    if (!in_rom) {
        @export(&programEntry, .{ .name = "_program_entry" });
        @export(&version_tag, .{ .name = "version_tag" });
    }
}

test {
    _ = @import("prp.zig");
    _ = @import("dsm.zig");
    _ = @import("regs.zig");
}
