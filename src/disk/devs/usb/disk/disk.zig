// SPDX-License-Identifier: MIT
//! usb/disk.device: USB sticks, card readers and disks as block devices. A
//! class driver (sdk/devices/usbclass.zig) for mass storage that speaks
//! SCSI over USB Attached SCSI or Bulk-Only Transport, and the block
//! device API (sdk/devices/trackdisk.zig) on its units: unit n is the
//! drive `DU<n>:`.
//!
//!   CMD_READ         io_Length bytes from io_Offset into io_Data; both
//!                    whole blocks of the medium, and on it.
//!   CMD_WRITE        io_Length bytes from io_Data at io_Offset.
//!   CMD_UPDATE       what the stick holds in a cache of its own put on
//!                    its medium (SYNCHRONIZE CACHE), answered once it is
//!                    there; at once by a stick that does not know the
//!                    command.
//!   TDCMD_ERASE,
//!   CMD_CLEAR        answer: a stick erases for itself, and the device
//!                    buffers nothing.
//!   TD_GETGEOMETRY   into io_Data: the medium's block size and blocks,
//!                    and DGF_REMOVABLE.
//!   TD_GETNUMTRACKS  io_Actual: the medium's blocks.
//!   TD_PROTSTATUS    io_Actual: not 0 if the medium is write-protected.
//!   TD_CHANGENUM     io_Actual: how often a medium came or went.
//!   TD_CHANGESTATE   io_Actual: 0 while a medium is in.
//!   TD_ADDCHANGEINT  io_Data an Interrupt, caused whenever a medium comes
//!                    or goes; the request is kept until it comes back as
//!   TD_REMCHANGEINT  which takes it off and answers it.
//!   HD_SCSICMD       a SCSI command to the unit's logical unit, as it is
//!                    (sdk/devices/scsidisk.zig).
//!
//! **Units are drives, not sticks.** An interface bound - a stick, a card
//! reader - takes the lowest free unit for each of its logical units, so
//! a stick pulled out and put back is `DU0:` again, and a reader's two
//! slots are two drives. A unit with nothing bound to it opens all the
//! same and has no medium, as an empty card slot has none: a handler sits
//! on it before a stick is there.
//!
//! **The drives are made by the device**, the first time a medium comes
//! into unit n, and stay (mount.zig, `sdk.devices.automount`): a drive
//! per partition when the stick holds a RigidDiskBlock or a GPT, `DU<n>:`
//! over the whole stick when it holds neither. Nothing USB is loaded at boot where no
//! stick is plugged in, and a node that locks point at is never taken off
//! the list. Nothing in the MountList is needed; an entry there that
//! opens the unit is the unit's drive, used as it is. From then on a
//! medium coming or going causes the handler's change interrupt, and the
//! handler looks.
//!
//! **The work** is the device's task's (task.zig): every transfer, the
//! units' bring-up, and a look at every unit once a second that finds a
//! card going into or out of a reader. BeginIO answers what it knows -
//! the change count, whether a medium is in - and queues the rest, as
//! sdcard.device does. The commands are scsi.zig's, the transports bot.zig
//! and uas.zig.
//!
//! **UAS where the interface has it.** An interface with a UAS setting
//! (protocol 0x62) is driven over UAS - that setting chosen, its four
//! pipes found by their Pipe Usage descriptors, on streams at SuperSpeed
//! - and is one drive, its logical unit 0; else it is driven over
//! Bulk-Only, a drive for each logical unit GET MAX LUN gives.
//!
//! The device's own unit for usb.library is `USBCLASS_UNIT_BIND`, which
//! opens nothing of the drives. It stays once loaded: a handler may sit
//! on any of its units for good.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const usb = sdk.usb;
const d = usb.descriptors;
const td = sdk.devices.trackdisk;
const scsidisk = sdk.devices.scsidisk;
const usbclass = sdk.devices.usbclass;
const usbhc = sdk.devices.usbhc;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const _disk = @import("_disk.zig");
const DiskBase = _disk.DiskBase;
const Function = _disk.Function;
const task_file = @import("task.zig");
const mount = @import("mount.zig");
const bot = @import("bot.zig");
const uas = @import("uas.zig");
const scsi = @import("scsi.zig");

pub const DEVICE_NAME = _disk.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 7;
const BUILD_DATE = "20.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// The task: a transfer's DoIO and a log line deep, nothing recursive.
const task_stack = 6144;
/// Beside the handlers, as sdcard.device's is: a file system waits on it.
const task_pri = 5;
/// The DOS process starts handlers and asks them, through dos.
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
fn queue(base: *DiskBase, io: *exec.IORequest) void {
    if (!canWait(io)) return base.sys_base.ReplyIO(io);
    io.flags &= ~exec.IOF_QUICK;
    base.sys_base.PutMsg(base.requests.?, &io.message);
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const base = _disk.diskBase(dev);
    io.err = 0;
    // usb.library's open has no drive to ask.
    if (io.unit == null) {
        io.err = exec.IOERR_NOCMD;
        return base.sys_base.ReplyIO(io);
    }
    const unit = _disk.unitOf(io);
    const req = _disk.stdReq(io);
    req.actual = 0;
    switch (io.command) {
        // Everything that speaks to the stick waits, so it goes to the task.
        exec.CMD_READ,
        exec.CMD_WRITE,
        exec.CMD_UPDATE,
        td.TD_GETGEOMETRY,
        td.TD_GETNUMTRACKS,
        td.TD_PROTSTATUS,
        scsidisk.HD_SCSICMD,
        => return queue(base, io),
        td.TDCMD_ERASE, exec.CMD_CLEAR => {},
        // A handler's change interrupt: kept, and not answered, until the
        // same request comes back as TD_REMCHANGEINT.
        td.TD_ADDCHANGEINT => if (req.data == null) {
            io.err = exec.IOERR_BADADDRESS;
        } else {
            const sys = base.sys_base;
            // Kept, so in progress: CheckIO and WaitIO go by the type.
            io.flags &= ~exec.IOF_QUICK;
            io.message.node.type = .message;
            sys.AcquireLock(&base.change_lock);
            sys.AddTail(&unit.changes, &io.message.node);
            sys.ReleaseLock(&base.change_lock);
            return;
        },
        td.TD_REMCHANGEINT => {
            const sys = base.sys_base;
            sys.AcquireLock(&base.change_lock);
            _ = takeChange(base, unit, io);
            sys.ReleaseLock(&base.change_lock);
        },
        // What the device knows without asking: a handler asks these
        // between packets and must not be made to wait for them.
        td.TD_CHANGENUM => req.actual = unit.change_num,
        td.TD_CHANGESTATE => req.actual = @intFromBool(!unit.present),
        else => io.err = exec.IOERR_NOCMD,
    }
    base.sys_base.ReplyIO(io);
}

/// `io` off the unit's change interrupts, if it is on them; whether it
/// was. The lock is held.
fn takeChange(base: *DiskBase, unit: *_disk.Unit, io: *exec.IORequest) bool {
    var it = unit.changes.iterator();
    while (it.next()) |node| {
        if (_disk.requestOf(@fieldParentPtr("node", node)) != io) continue;
        base.sys_base.Remove(node);
        return true;
    }
    return false;
}

/// A request the task has not taken yet is taken off its queue and
/// replied, and so is a change interrupt; one the task is busy with
/// cannot be stopped.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const base = _disk.diskBase(dev);
    const sys = base.sys_base;
    if (io.unit != null) {
        sys.AcquireLock(&base.change_lock);
        const was_change = takeChange(base, _disk.unitOf(io), io);
        sys.ReleaseLock(&base.change_lock);
        if (was_change) {
            io.err = exec.IOERR_ABORTED;
            sys.ReplyIO(io);
            return 0;
        }
    }
    if (!sys.RemoveMsg(base.requests.?, &io.message)) return -1;
    io.err = exec.IOERR_ABORTED;
    sys.ReplyIO(io);
    return 0;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const base = _disk.diskBase(dev);
    // usb.library's open, for the two class calls: none of the drives.
    if (unit_number == usbclass.USBCLASS_UNIT_BIND) {
        dev.open_cnt += 1;
        dev.flags &= ~exec.LIBF_DELEXP;
        io.unit = null;
        return 0;
    }
    if (unit_number >= _disk.max_units) return td.TDERR_BadUnitNum;
    const unit = &base.units[unit_number];
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    unit.unit.open_cnt += 1;
    io.unit = &unit.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    if (io.unit != null) {
        _ = abortIO(dev, io);
        _disk.unitOf(io).unit.open_cnt -= 1;
    }
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: a handler may sit on any of its units for good.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

// --- the class driver's calls -------------------------------------------------------

/// A mass storage interface of SCSI taken - over UAS where it has a
/// setting for it, else over Bulk-Only: its pipes opened, the lowest free
/// units given to its logical units, and the task handed it to bring up;
/// anything else declined. The contract is usbclass's
/// (sdk/fd/usbclass_lib.fd).
///
/// INPUTS:
/// - `base` - the driver's base.
/// - `binding` - the device and the interface offered.
pub fn USBClassBind(base: *DiskBase, binding: *usb.USBBinding) bool {
    const sys = base.sys_base;
    const ub = base.usb_base orelse return false;
    const device = binding.device.?;
    const interface = binding.interface.?;
    if (interface.interface_class != d.USB_CLASS_MASS_STORAGE or
        interface.interface_subclass != d.MSC_SUBCLASS_SCSI) return false;
    const pipes = base.pipes orelse return false;

    const memory = sys.AllocMem(@sizeOf(Function), exec.MEMF_CLEAR) orelse return false;
    const function: *Function = @ptrCast(@alignCast(memory));
    const transport = uasOf(sys, ub, device, interface.interface_number, pipes) orelse
        (if (interface.interface_protocol == d.MSC_PROTOCOL_BULK_ONLY) botOf(sys, ub, device, interface, pipes) else null) orelse
        {
            sys.FreeMem(memory, @sizeOf(Function));
            return false;
        };
    function.* = .{ .transport = transport };

    // The lowest free units, one for each logical unit there is room for:
    // a UAS interface's logical unit 0.
    const luns: u8 = switch (transport) {
        .bot => @min(maxLun(ub, device, interface.interface_number) + 1, _disk.max_luns),
        .uas => 1,
    };
    sys.ObtainSemaphore(&base.lock);
    var lun: u8 = 0;
    for (&base.units) |*unit| {
        if (lun == luns) break;
        if (unit.function != null) continue;
        unit.function = function;
        unit.lun = lun;
        unit.present = false;
        function.units[lun] = unit;
        lun += 1;
    }
    sys.ReleaseSemaphore(&base.lock);
    function.lun_count = lun;
    if (lun == 0) {
        _disk.closePipes(ub, &function.transport);
        sys.FreeMem(memory, @sizeOf(Function));
        return false;
    }
    binding.driver_data = function;
    binding.unit = function.units[0].?.number;
    function.bring_up = .{ .kind = .bring_up, .function = function };
    function.bring_up.message.length = @sizeOf(_disk.Command);
    sys.PutMsg(base.commands.?, &function.bring_up.message);
    return true;
}

/// Bulk-Only to the interface: its bulk pair's pipes. Null without them.
fn botOf(sys: *ExecBase, ub: *sdk.interface.usb.UsbBase, device: *usb.USBDevice, interface: *const usb.InterfaceDescriptor, port: *exec.MsgPort) ?_disk.Transport {
    const in = ub.FindUSBEndpoint(device, interface, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_BULK) orelse return null;
    const out = ub.FindUSBEndpoint(device, interface, d.USB_DIR_OUT, d.USB_ENDPOINT_XFER_BULK) orelse return null;
    const bulk_in = ub.OpenUSBPipe(device, in.endpoint_address, port) orelse return null;
    const bulk_out = ub.OpenUSBPipe(device, out.endpoint_address, port) orelse {
        ub.CloseUSBPipe(bulk_in);
        return null;
    };
    return .{ .bot = .{
        .sys = sys,
        .ub = ub,
        .device = device,
        .interface_number = interface.interface_number,
        .bulk_in = bulk_in,
        .bulk_out = bulk_out,
    } };
}

/// UAS to interface `interface_number`, if it has a UAS setting whose
/// Pipe Usage descriptors name its four pipes: the pipes opened - the
/// status and data pipes on streams at SuperSpeed, the status pipe's on
/// the task management function's too - and the setting chosen
/// (SET_INTERFACE) where it is not the first. Null without one, or when a
/// pipe or the setting cannot be had.
fn uasOf(sys: *ExecBase, ub: *sdk.interface.usb.UsbBase, device: *usb.USBDevice, interface_number: u8, port: *exec.MsgPort) ?_disk.Transport {
    var previous: ?*const usb.InterfaceDescriptor = null;
    const setting = while (ub.FindUSBInterface(device, previous, d.USB_CLASS_MASS_STORAGE, d.MSC_SUBCLASS_SCSI, d.MSC_PROTOCOL_UAS)) |found| : (previous = found) {
        if (found.interface_number == interface_number) break found;
    } else return null;
    const config = device.config orelse return null;
    const after = @intFromPtr(setting) - @intFromPtr(config) + setting.length;
    if (after > device.config_length) return null;
    const names = uas.pipesOf(config[after..device.config_length]);
    if (!names.complete()) return null;

    const streams = device.speed == usbhc.USB_SPEED_SUPER;
    var opened: [5]?*usb.USBPipe = @splat(null);
    opened[0] = ub.OpenUSBPipe(device, names.command, port);
    if (streams) {
        opened[1] = ub.OpenUSBStreamPipe(device, names.status, uas.command_tag, port);
        opened[2] = ub.OpenUSBStreamPipe(device, names.status, uas.task_tag, port);
        opened[3] = ub.OpenUSBStreamPipe(device, names.data_in, uas.command_tag, port);
        opened[4] = ub.OpenUSBStreamPipe(device, names.data_out, uas.command_tag, port);
    } else {
        opened[1] = ub.OpenUSBPipe(device, names.status, port);
        opened[3] = ub.OpenUSBPipe(device, names.data_in, port);
        opened[4] = ub.OpenUSBPipe(device, names.data_out, port);
    }
    const missing = opened[0] == null or opened[1] == null or opened[3] == null or opened[4] == null or (streams and opened[2] == null);
    if (!missing and setting.alternate_setting != 0) {
        const setup = usb.SetupPacket{
            .request_type = d.USB_DIR_OUT | d.USB_RECIP_INTERFACE,
            .request = d.USB_REQ_SET_INTERFACE,
            .value = setting.alternate_setting,
            .index = interface_number,
            .length = 0,
        };
        if (ub.DoUSBControl(device, &setup, null, null) == 0) return transportOf(sys, ub, device, opened, streams);
    } else if (!missing) {
        return transportOf(sys, ub, device, opened, streams);
    }
    for (opened) |pipe| ub.CloseUSBPipe(pipe);
    return null;
}

fn transportOf(sys: *ExecBase, ub: *sdk.interface.usb.UsbBase, device: *usb.USBDevice, opened: [5]?*usb.USBPipe, streams: bool) _disk.Transport {
    return .{ .uas = .{
        .sys = sys,
        .ub = ub,
        .device = device,
        .command = opened[0].?,
        .status = opened[1].?,
        .status_task = opened[2],
        .data_in = opened[3].?,
        .data_out = opened[4].?,
        .streams = streams,
    } };
}

/// The highest logical unit number (GET MAX LUN); 0 for a device that
/// refuses the question, as one with a single unit may.
fn maxLun(ub: *sdk.interface.usb.UsbBase, device: *usb.USBDevice, interface_number: u8) u8 {
    var answer: u8 = 0;
    const setup = usb.SetupPacket{
        .request_type = d.USB_DIR_IN | d.USB_TYPE_CLASS | d.USB_RECIP_INTERFACE,
        .request = d.MSC_REQ_GET_MAX_LUN,
        .value = 0,
        .index = interface_number,
        .length = 1,
    };
    var actual: u32 = 0;
    if (ub.DoUSBControl(device, &setup, &answer, &actual) != 0 or actual != 1) return 0;
    return @min(answer, 15);
}

/// An interface let go of, by the task, and waited for: its units lose
/// their medium, its pipes close. The contract is usbclass's
/// (sdk/fd/usbclass_lib.fd).
///
/// INPUTS:
/// - `base` - the driver's base.
/// - `binding` - what USBClassBind took.
pub fn USBClassUnbind(base: *DiskBase, binding: *usb.USBBinding) void {
    const sys = base.sys_base;
    const raw = binding.driver_data orelse return;
    const function: *Function = @ptrCast(@alignCast(raw));
    // The device has gone, or the bus stops: a transfer the task waits on
    // is taken back now, and the task sends none after it.
    _disk.leave(sys, &function.transport);
    const reply = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(reply);
    var command = _disk.Command{ .kind = .let_go, .function = raw };
    command.message.reply_port = reply;
    command.message.length = @sizeOf(_disk.Command);
    sys.PutMsg(base.commands.?, &command.message);
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
    binding.driver_data = null;
}

fn lvoUSBClassBind(base: *DiskBase, binding: *usb.USBBinding) callconv(.c) bool {
    return USBClassBind(base, binding);
}
fn lvoUSBClassUnbind(base: *DiskBase, binding: *usb.USBBinding) callconv(.c) void {
    return USBClassUnbind(base, binding);
}

comptime {
    const interface = sdk.interface.usbclass;
    if (!exec.libraries.sameSignature(@TypeOf(&lvoUSBClassBind), interface.Fn.USBClassBind) or
        !exec.libraries.sameSignature(@TypeOf(&lvoUSBClassUnbind), interface.Fn.USBClassUnbind))
        @compileError("disk.device: a class call does not match the SDK's type");
}

// --- the start ----------------------------------------------------------------------

/// usb.library and dos.library opened, the units named, the task and the
/// DOS process started and waited for. Null when either cannot start.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _disk.diskBase(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;
    sys_base.InitSemaphore(&base.lock);
    sys_base.InitLock(&base.change_lock, DEVICE_NAME, exec.LOCKORDER_DRIVER, 0);
    for (&base.units, 0..) |*unit, number| {
        unit.* = .{ .number = @intCast(number) };
        unit.changes.init(.message);
        @memcpy(unit.name[0..2], "DU");
        unit.name[2] = '0' + @as(u8, @intCast(number));
    }
    base.usb_base = @ptrCast(sys_base.OpenLibrary(usb.USBNAME, 1) orelse return null);
    base.dos_base = @ptrCast(sys_base.OpenLibrary(dos.DOSNAME, 0) orelse return null);

    const signal = sys_base.AllocSignal(-1);
    if (signal < 0) return null;
    defer sys_base.FreeSignal(signal);
    base.start_signal = signal;
    const wake = @as(u32, 1) << @intCast(signal);

    const stack = sys_base.AllocMem(task_stack, exec.MEMF_CLEAR) orelse return null;
    base.stack = stack;
    base.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + task_stack,
    };
    base.starter = sys_base.FindTask(null);
    _ = sys_base.AddTask(&base.task, &task_file.diskTask, null);
    _ = sys_base.Wait(wake);
    if (base.requests == null or base.commands == null or base.pipes == null or base.timer_port == null) return null;

    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&mount.mountProcess) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(@as([*:0]const u8, "disk.device mount")) },
        .{ .tag = dos.NP_StackSize, .data = mount_stack },
        .{ .tag = dos.NP_Priority, .data = @as(usize, @bitCast(@as(isize, mount_pri))) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(base) },
        .{},
    };
    base.starter = sys_base.FindTask(null);
    if (base.dos_base.?.CreateNewProc(&tags) == null) {
        base.starter = null;
        return null;
    }
    _ = sys_base.Wait(wake);
    if (base.mounter == null) return null;
    return dev;
}

/// The jump table: the six standard vectors, then the class driver's two.
const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
    vec(lvoUSBClassBind),
    vec(lvoUSBClassUnbind),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(DiskBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

const speaks = [_]u32{ devices.DEVIF_BLOCK, devices.DEVIF_USBCLASS, 0 };

const labels = [_][*:0]const u8{ "DU0:", "DU1:", "DU2:", "DU3:", "DU4:", "DU5:", "DU6:", "DU7:" };

/// What it drives: mass storage, SCSI over Bulk-Only or UAS - an
/// interface whose first setting is either.
const matches = [_]usbclass.USBMatch{
    .{
        .fields = usbclass.USBMATCH_CLASS | usbclass.USBMATCH_SUBCLASS | usbclass.USBMATCH_PROTOCOL,
        .interface_class = d.USB_CLASS_MASS_STORAGE,
        .interface_subclass = d.MSC_SUBCLASS_SCSI,
        .interface_protocol = d.MSC_PROTOCOL_BULK_ONLY,
    },
    .{
        .fields = usbclass.USBMATCH_CLASS | usbclass.USBMATCH_SUBCLASS | usbclass.USBMATCH_PROTOCOL,
        .interface_class = d.USB_CLASS_MASS_STORAGE,
        .interface_subclass = d.MSC_SUBCLASS_SCSI,
        .interface_protocol = d.MSC_PROTOCOL_UAS,
    },
    .{},
};

/// AUTOINIT and DEVICEINFO: made when usb.library opens it, and its match
/// table read from the file without loading it.
export const disk_device_tag: usbclass.ResidentUSBClass linksection(".resident") = .{
    .device = .{
        .resident = .{
            .match_tag = @ptrCast(&disk_device_tag),
            .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
            .version = DEVICE_VERSION,
            .pri = 0,
            .type = .device,
            .name = DEVICE_NAME,
            .id_string = DEVICE_VERSION_STRING[1..],
            .init = &init_table,
        },
        .speaks = &speaks,
        .units = _disk.max_units,
        .unit_labels = &labels,
    },
    .matches = &matches,
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
    _ = bot;
    _ = uas;
    _ = scsi;
}
