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
//!   TD_CHANGENUM     io_Actual: 0, it never changed.
//!   TD_CHANGESTATE   io_Actual: 0, a medium is in.
//!
//! **Bringing it up.** The first open makes the device: pci.library is
//! opened, which brings up the board's PCI Express ports, and the
//! device's task claims every NVM Express function there (class
//! 0x010802), brings each controller up and makes a unit of each of its
//! namespaces (controller.zig). A unit that has no namespace does not
//! open. A namespace whose blocks carry metadata, or are not 512 bytes to
//! 4 KiB, is left out.
//!
//! **The work** is the task's (task.zig): reads and writes in pieces of
//! the controller's largest transfer, several out at once, straight into
//! and out of the caller's pages. BeginIO answers what it knows - the
//! geometry, the protection, the change count - and queues the rest.
//!
//! **The drives** are made once the device is up, by a DOS process of
//! its own (mount.zig): a drive per partition where a namespace holds a
//! RigidDiskBlock, `NV<n>` over the whole namespace otherwise - unless a
//! MountList entry mounted by hand opens the unit already, which is then
//! its drive.
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
const DEVICE_REVISION = 2;
const BUILD_DATE = "18.10.2026";
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
    switch (io.command) {
        exec.CMD_READ, exec.CMD_WRITE, exec.CMD_UPDATE, td.TDCMD_TRIM => return queue(base, io),
        td.TDCMD_ERASE, exec.CMD_CLEAR => {},
        td.TD_GETGEOMETRY => if (req.data) |data| {
            _nvme.geometry(unit, @ptrCast(@alignCast(data)));
        } else {
            io.err = exec.IOERR_BADADDRESS;
        },
        td.TD_GETNUMTRACKS => req.actual = unit.blocks,
        td.TD_PROTSTATUS, td.TD_CHANGENUM, td.TD_CHANGESTATE => req.actual = 0,
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
    base.pci_base = @ptrCast(sys_base.OpenLibrary(pci.PCINAME, 2) orelse return null);

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
    // Last: nothing after this fails, so the process never runs on a base
    // that is freed.
    if (base.unit_count != 0) startMounter(base);
    return dev;
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
/// the file from DEVS: and hands this tag to InitResident.
export const nvme_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&nvme_device_tag),
        .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
        .version = DEVICE_VERSION,
        .pri = 0,
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
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20;
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;

test {
    _ = @import("prp.zig");
    _ = @import("dsm.zig");
    _ = @import("regs.zig");
}
