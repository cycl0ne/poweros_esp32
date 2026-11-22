// SPDX-License-Identifier: MIT
//! bluetooth/cyw43455bt.device: the Bluetooth of the Infineon CYW43455 on
//! the Raspberry Pi 4 Model B - a controller of its own beside the chip's
//! Wi-Fi, on the BCM2711's mini UART (miniuart.zig) - as an HCI unit
//! (sdk/devices/hci.zig) for bluetooth.library. It is in DEVS:bluetooth/,
//! and the board's system tag list says whether there is one and how it
//! is wired (a PARTKIND_BLUETOOTH part with CHIP_CYW43455); a board
//! without one gets no device.
//!
//! **Loaded by the stack**: bluetooth.library opens every unit the board
//! has a controller for at its first open from a process, which loads the
//! device. Its init starts the worker (worker.zig), which sets the
//! controller up - its power, its line's rate, its patch, its address -
//! and the open answers HCIERR_NOTREADY meanwhile; the worker then offers
//! the unit with `AddBTController("bluetooth/cyw43455bt.device", 0)`, and
//! the unit opens. A controller that could not be set up is offered all
//! the same, and its unit answers IOERR_OPENFAIL.
//!
//! HCICMD_QUERY is answered at once, in the caller's task; CMD_READ,
//! CMD_WRITE and CMD_FLUSH go to the worker. The device stays once it is
//! loaded: its worker owns the line.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const hcidev = sdk.devices.hci;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const devices = expansion.devices;
const videocore = sdk.hardware.videocore;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const _bt = @import("_cyw43455bt.zig");
const worker = @import("worker.zig");
const miniuart = @import("miniuart.zig");
const BtBase = _bt.BtBase;

pub const DEVICE_NAME = _bt.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "22.11.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// The worker reads the patch into memory of its own; its stack holds
/// little.
const worker_stack = 16384;
const worker_pri = 5;

// --- the device -----------------------------------------------------------

/// What the unit is: a UART at its rate, the chip and its patch.
fn query(base: *BtBase, io: *exec.IORequest) void {
    const req = _bt.hciReq(io);
    if (req.std.data == null or req.std.length < @sizeOf(hcidev.HCIInfo)) {
        io.err = exec.IOERR_BADLENGTH;
        return;
    }
    const info: *hcidev.HCIInfo = @ptrCast(@alignCast(req.std.data.?));
    info.* = .{
        .bus = hcidev.HCIBUS_UART,
        .baud = base.baud,
        .chip = if (base.chip[0] != 0) @ptrCast(&base.chip) else null,
        .firmware = if (base.firmware[0] != 0) @ptrCast(&base.firmware) else null,
    };
    req.std.actual = @sizeOf(hcidev.HCIInfo);
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const base = _bt.btBase(dev);
    const sys = base.sys_base;
    if (io.unit == null) {
        io.err = exec.IOERR_NOCMD;
        return sys.ReplyIO(io);
    }
    io.err = 0;
    switch (io.command) {
        hcidev.HCICMD_QUERY => query(base, io),
        exec.CMD_READ, exec.CMD_WRITE, exec.CMD_FLUSH => {
            if (io.message.reply_port == null) {
                io.err = exec.IOERR_NOREPLYPORT;
                io.flags |= exec.IOF_QUICK;
            } else {
                // Answered by the worker: not quick.
                io.flags &= ~exec.IOF_QUICK;
                return sys.PutMsg(&base.unit.msg_port, &io.message);
            }
        },
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

/// The request found where it waits - on the unit's port for the worker,
/// among the reads, among the writes not yet sent - taken off and
/// answered as aborted. A write being sent goes on to its end.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const base = _bt.btBase(dev);
    const sys = base.sys_base;
    if (io.unit == null) return -1;
    sys.Disable();
    for ([_]*exec.List{ &base.unit.msg_port.msg_list, &base.reads, &base.writes }) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            const message: *exec.Message = @fieldParentPtr("node", node);
            if (_bt.requestOf(message) != io) continue;
            sys.Remove(node);
            sys.Enable();
            io.err = exec.IOERR_ABORTED;
            sys.ReplyIO(io);
            return 0;
        }
    }
    sys.Enable();
    return -1;
}

/// Unit 0, the board's controller: open once it is set up, HCIERR_NOTREADY
/// while it is being, IOERR_OPENFAIL once that has failed.
fn openDevice(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const base = _bt.btBase(dev);
    if (unit_number != 0) return exec.IOERR_OPENFAIL;
    if (@atomicLoad(u8, &base.failed, .acquire) != 0) return exec.IOERR_OPENFAIL;
    if (@atomicLoad(u8, &base.ready, .acquire) == 0) return hcidev.HCIERR_NOTREADY;
    if (io.message.length != 0 and io.message.length < @sizeOf(hcidev.IOHciReq)) return exec.IOERR_BADLENGTH;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    base.unit.open_cnt += 1;
    io.unit = &base.unit;
    return 0;
}

fn closeDevice(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const base = _bt.btBase(dev);
    if (io.unit != null) base.unit.open_cnt -= 1;
    io.unit = null;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: its worker owns the line.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// The board's Bluetooth part - the line, its interrupt, the controller's
/// address - and the firmware's mailbox, into the base: false if the
/// board has none, wires it where this cannot drive it, or there is no
/// memory for the mailbox's messages.
fn findPart(sys: *ExecBase, base: *BtBase) bool {
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return false;
    defer sys.CloseLibrary(utility_lib);
    const utility: *UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_BLUETOOTH, st.CHIP_CYW43455) orelse return false;
    if (utility.GetTagData(st.PART_Bus, st.BUS_NONE, part.tags) != st.BUS_UART) return false;
    base.line = miniuart.lineOf(utility, part.tags) orelse {
        exec.kprintf(sys, "%s: the board's Bluetooth is wired where this cannot drive it\n", .{DEVICE_NAME});
        return false;
    };
    base.irq = @truncate(utility.GetTagData(st.PART_Irq, 0, part.tags));
    const address = utility.GetTagData(st.PART_StationAddress, 0, part.tags);
    if (address != 0) base.address = @as(*const [6]u8, @ptrFromInt(address)).*;
    const firmware = eb.FindBoardPart(null, st.PARTKIND_FIRMWARE, st.CHIP_RPI_FIRMWARE) orelse {
        exec.kprintf(sys, "%s: the board's firmware mailbox is not found\n", .{DEVICE_NAME});
        return false;
    };
    const mailbox = utility.GetTagData(st.PART_Address, 0, firmware.tags);
    if (mailbox == 0) return false;
    const memory = sys.AllocMem(mail_bytes, exec.MEMF_DMA | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return false;
    base.mail_memory = memory;
    const buffer = videocore.bufferIn(memory) orelse return false;
    base.line.mailbox = mailbox;
    base.line.mail = @intFromPtr(buffer);
    return true;
}

/// The mailbox's messages: two buffers' room, so that one is aligned.
const mail_bytes = 2 * videocore.buffer_bytes;

/// What init took given back: the device is not made, and exec frees the
/// base.
fn giveBack(sys: *ExecBase, base: *BtBase) ?*exec.Device {
    if (base.buffers) |buffers| sys.FreeVec(buffers);
    base.buffers = null;
    if (base.dos_base) |dos_base| sys.CloseLibrary(@ptrCast(@alignCast(dos_base)));
    base.dos_base = null;
    if (base.mail_memory) |memory| sys.FreeMem(memory, mail_bytes);
    base.mail_memory = null;
    return null;
}

/// exec has copied the tag's name, version and ID string into the base.
/// A board without the controller gets no device at all: null, before
/// anything is taken. Otherwise the worker is started, which sets the
/// controller up; this waits only until it runs.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _bt.btBase(dev);
    base.sys_base = sys;
    base.seg_list = seg_list;
    if (!findPart(sys, base)) return giveBack(sys, base);
    base.dos_base = @ptrCast(sys.OpenLibrary(dos.DOSNAME, 0) orelse return giveBack(sys, base));
    const memory = sys.AllocVec(@sizeOf(_bt.Buffers), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return giveBack(sys, base);
    const buffers: *_bt.Buffers = @ptrCast(@alignCast(memory));
    buffers.* = .{};
    base.buffers = buffers;
    // PA_IGNORE until the worker has a signal for it: the unit opens only
    // once the worker has set the controller up.
    base.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    base.unit.msg_port.msg_list.init(.message);
    base.reads.init(.message);
    base.writes.init(.message);
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return giveBack(sys, base);
    defer sys.FreeSignal(signal);
    base.start_signal = signal;
    base.starter = sys.FindTask(null);
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&worker.workerMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(@as([*:0]const u8, DEVICE_NAME)) },
        .{ .tag = dos.NP_StackSize, .data = worker_stack },
        .{ .tag = dos.NP_Priority, .data = @as(usize, @bitCast(@as(isize, worker_pri))) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(base) },
        .{},
    };
    if (base.dos_base.?.CreateNewProc(&tags) == null) {
        base.starter = null;
        return giveBack(sys, base);
    }
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (base.running == 0) return giveBack(sys, base);
    return dev;
}

/// The six standard vectors, nothing past AbortIO.
const vectors = [_]*const anyopaque{
    vec(openDevice),
    vec(closeDevice),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(BtBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// What the device speaks, for ObtainDeviceUnits (expansion.library),
/// and where its units come from: a unit per CYW43455 Bluetooth the board
/// lists, which is one - unit 0, the one `openDevice` takes.
const device_speaks = [_]u32{ devices.DEVIF_HCI, 0 };

/// No flags but AUTOINIT and DEVICEINFO: the device is on the disk, in
/// DEVS:bluetooth/, made when bluetooth.library opens it, and its tag read
/// from the file without loading it.
export const cyw43455bt_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&cyw43455bt_device_tag),
        .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
        .version = DEVICE_VERSION,
        .pri = 0,
        .type = .device,
        .name = DEVICE_NAME,
        .id_string = DEVICE_VERSION_STRING[1..],
        .init = &init_table,
    },
    .speaks = &device_speaks,
    .unit_part = st.PARTKIND_BLUETOOTH,
    .unit_chip = st.CHIP_CYW43455,
};

/// A device is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20;
}

export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
