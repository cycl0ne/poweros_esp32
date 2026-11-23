// SPDX-License-Identifier: MIT
//! usb/hid.device: USB keyboards, mice and tablets. A class driver
//! (sdk/devices/usbclass.zig): it binds HID interfaces of the boot
//! subclass, and any other HID interface whose report descriptor
//! describes a keyboard or a mouse, and keeps a read outstanding on each
//! one's interrupt endpoint; every report goes to hid.library, which
//! makes it into key-downs and key-ups for keyboard.device and moves, a
//! tablet's places, buttons and the wheel for mouse.device - so a USB
//! keyboard is the system's keyboard with nothing else knowing.
//!
//! **Which report.** A keyboard or a mouse is asked for its report
//! descriptor first, and hid.library reads it (OpenHID): where it
//! describes the interface's report, the interface stays in its report
//! protocol and is read by it - a mouse may send a wider report than the
//! boot one, a keyboard a bit for every key, a receiver a keyboard and a
//! mouse in one, and not every device that says it has the boot protocol
//! switches to it. Where it does not, a boot interface is put in the boot
//! protocol (HIDF_BOOT), and any other is declined: it has no boot report
//! to fall back on. A keyboard's LEDs - Caps Lock's light, following its
//! key - come back from the library as an output report, sent with
//! SET_REPORT.
//!
//! **One task for every keyboard and mouse.** Each bound interface is a
//! `Function`: its pipe, its report, the library's function. The pipes
//! reply to the task's port, and so do the library's sources; the task
//! hands each report to the library and sends the read again.
//!
//! **Binding** runs on the bus's process: the interface checked, its
//! pipe opened, its descriptor read into a function, its protocol and
//! idle rate set and the first read sent. **Unbinding** is a command to
//! the task, since only the task can wait for its pipe's last reply: the
//! read taken back, the pipe closed, the function closed - which lets go
//! of whatever keys or buttons the device still held.
//!
//! The device's own units are none yet: usb.library opens it on
//! `USBCLASS_UNIT_BIND` for its two calls. It stays once loaded while it
//! drives something; with nothing to drive, it may be expunged.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const d = usb.descriptors;
const usbhc = sdk.devices.usbhc;
const usbclass = sdk.devices.usbclass;
const hid = sdk.hid;
const utility = sdk.utility;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const UsbBase = sdk.interface.usb.UsbBase;
const HIDBase = sdk.interface.hid.HIDBase;

pub const DEVICE_NAME = "hid.device";
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 4;
const BUILD_DATE = "23.11.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// The most keyboards and mice at once.
const max_functions = 8;
/// The standard stack: 32 KiB on a 64-bit machine, 16 KiB on a 32-bit one.
const stack_size = 4096 * @sizeOf(usize);
/// The longest report descriptor read.
const max_descriptor = 1024;
/// Above dos's processes, as input.device's sources are: a key is taken
/// while a program computes.
const task_pri = 10;

/// A bound keyboard or mouse.
const Function = struct {
    hb: *HidBase,
    device: *usb.USBDevice,
    interface_number: u8,
    pipe: *usb.USBPipe,
    /// What hid.library reads its reports by, and the hook its output
    /// reports come back through.
    function: ?*hid.HIDFunction = null,
    output_hook: utility.Hook = .{},
    /// The report being read - a packet, the most an interrupt endpoint
    /// of a full-speed device sends at once.
    buffer: [64]u8 = @splat(0),
    /// Whether its read is out.
    reading: bool = false,
};

/// A command to the task: a function to let go of.
const Command = extern struct {
    message: exec.Message = .{},
    function: ?*anyopaque = null,
};

const HidBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    usb_base: ?*UsbBase = null,
    hid_base: ?*HIDBase = null,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The task's ports: the pipes' replies, and commands.
    port: ?*exec.MsgPort = null,
    command_port: ?*exec.MsgPort = null,
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The bound functions, a slot each; changed by the bus's process
    /// (a bind) and the task (an unbind), under the lock.
    functions: [max_functions]?*anyopaque = @splat(null),
    lock: exec.SignalSemaphore = .{},
};

fn hidBase(dev: *exec.Device) *HidBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

fn functionOf(raw: ?*anyopaque) ?*Function {
    return @ptrCast(@alignCast(raw orelse return null));
}

// --- the task ---------------------------------------------------------------------

fn hidTask(sys: *ExecBase) callconv(.c) void {
    const hb: *HidBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    hb.port = sys.CreateMsgPort();
    hb.command_port = sys.CreateMsgPort();
    started(hb);
    const port = hb.port orelse return;
    const commands = hb.command_port orelse return;
    while (true) {
        _ = sys.Wait(port.sigMask() | commands.sigMask());
        while (sys.GetMsg(commands)) |msg| {
            const command: *Command = @ptrCast(@alignCast(msg));
            if (functionOf(command.function)) |function| letGo(hb, function);
            sys.ReplyMsg(msg);
        }
        while (sys.GetMsg(port)) |msg| {
            const req: *usbhc.IOUsbHC = @ptrCast(@alignCast(msg));
            const function = findFunction(hb, req) orelse continue;
            function.reading = false;
            took(hb, function);
        }
    }
}

fn started(hb: *HidBase) void {
    const starter = hb.starter orelse return;
    hb.starter = null;
    hb.sys_base.Signal(starter, @as(u32, 1) << @intCast(hb.start_signal));
}

/// The function whose pipe's request this is.
fn findFunction(hb: *HidBase, req: *usbhc.IOUsbHC) ?*Function {
    const sys = hb.sys_base;
    sys.ObtainSemaphoreShared(&hb.lock);
    defer sys.ReleaseSemaphore(&hb.lock);
    for (hb.functions) |slot| {
        const function = functionOf(slot) orelse continue;
        if (&function.pipe.io == req) return function;
    }
    return null;
}

/// A report came: its events handed on, and the next read sent.
fn took(hb: *HidBase, function: *Function) void {
    const sys = hb.sys_base;
    const ub = hb.usb_base.?;
    const io = &function.pipe.io;
    switch (io.std.req.err) {
        0 => {
            const got: usize = @min(@as(usize, @intCast(io.std.actual)), function.buffer.len);
            hb.hid_base.?.HIDInput(function.function.?, &function.buffer, @intCast(got));
        },
        usbhc.UHIOERR_DETACHED, exec.IOERR_ABORTED => return,
        usbhc.UHIOERR_STALL => _ = ub.ClearUSBStall(function.pipe),
        else => {},
    }
    read(sys, function);
}

/// One packet: an interrupt endpoint sends a report a packet, so a read
/// of more would wait for a second report to fill it.
fn read(sys: *ExecBase, function: *Function) void {
    const io = &function.pipe.io;
    io.std.data = &function.buffer;
    io.std.length = @min(@max(io.max_packet, 1), function.buffer.len);
    function.reading = true;
    sys.SendIO(&io.std.req);
}

/// The longest output report sent, its ID included.
const output_most = 16;

/// An output report from hid.library - the keyboard's LEDs - sent with
/// SET_REPORT: after the report's ID where it has one. On the task, within
/// HIDInput.
fn sendOutput(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const function: *Function = @ptrCast(@alignCast(hook.data.?));
    const output: *const hid.HIDOutputMessage = @ptrCast(@alignCast(message.?));
    const ub = function.hb.usb_base.?;
    var bytes: [output_most]u8 = undefined;
    var length: usize = 0;
    if (output.id != 0) {
        bytes[0] = output.id;
        length = 1;
    }
    const count = @min(output.length, output_most - length);
    @memcpy(bytes[length..][0..count], output.data[0..count]);
    length += count;
    const setup = usb.SetupPacket{
        .request_type = d.USB_DIR_OUT | d.USB_TYPE_CLASS | d.USB_RECIP_INTERFACE,
        .request = d.HID_REQ_SET_REPORT,
        .value = @as(u16, output.kind) << 8 | output.id,
        .index = function.interface_number,
        .length = @intCast(length),
    };
    _ = ub.DoUSBControl(function.device, &setup, &bytes, null);
    return 0;
}

/// A function let go of, on the task: its read taken back, its pipe and
/// the library's function closed, its slot freed.
fn letGo(hb: *HidBase, function: *Function) void {
    const sys = hb.sys_base;
    const ub = hb.usb_base.?;
    if (function.reading) {
        _ = sys.AbortIO(&function.pipe.io.std.req);
        _ = sys.WaitIO(&function.pipe.io.std.req);
        function.reading = false;
    }
    ub.CloseUSBPipe(function.pipe);
    hb.hid_base.?.CloseHID(function.function);
    sys.ObtainSemaphore(&hb.lock);
    for (&hb.functions) |*slot| {
        if (functionOf(slot.*) == function) slot.* = null;
    }
    sys.ReleaseSemaphore(&hb.lock);
    sys.FreeMem(function, @sizeOf(Function));
}

// --- the class driver's calls -------------------------------------------------------

/// A HID interface taken: one of the boot subclass, keyboard or mouse,
/// and any other whose report descriptor describes a mouse - a tablet,
/// say - or a keyboard, or both; the rest declined. The contract is usbclass's
/// (sdk/fd/usbclass_lib.fd).
///
/// INPUTS:
/// - `hb` - the driver's base.
/// - `binding` - the device and the interface offered.
pub fn USBClassBind(hb: *HidBase, binding: *usb.USBBinding) bool {
    const sys = hb.sys_base;
    const ub = hb.usb_base orelse return false;
    const device = binding.device.?;
    const interface = binding.interface.?;
    if (interface.interface_class != d.USB_CLASS_HID) return false;
    const boot = interface.interface_subclass == d.HID_SUBCLASS_BOOT;
    const boot_kind: u32 = if (!boot) 0 else switch (interface.interface_protocol) {
        d.HID_PROTOCOL_KEYBOARD => hid.HIDBOOT_KEYBOARD,
        d.HID_PROTOCOL_MOUSE => hid.HIDBOOT_MOUSE,
        else => return false,
    };
    const endpoint = ub.FindUSBEndpoint(device, interface, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_INT) orelse return false;
    const port = hb.port orelse return false;

    var slot_index: ?usize = null;
    for (hb.functions, 0..) |slot, i| {
        if (slot == null) slot_index = i;
    }
    const free_slot = slot_index orelse return false;

    const memory = sys.AllocMem(@sizeOf(Function), exec.MEMF_CLEAR) orelse return false;
    const function: *Function = @ptrCast(@alignCast(memory));
    const number = interface.interface_number;
    const pipe = ub.OpenUSBPipe(device, endpoint.endpoint_address, port) orelse {
        sys.FreeMem(memory, @sizeOf(Function));
        return false;
    };
    function.* = .{ .hb = hb, .device = device, .interface_number = number, .pipe = pipe };
    function.output_hook = .{ .entry = &sendOutput, .data = function };
    // By its own report where its descriptor describes one, else the boot
    // protocol - which only a boot interface has.
    const opened = openFunction(hb, function, device, interface, boot_kind) orelse {
        ub.CloseUSBPipe(pipe);
        sys.FreeMem(memory, @sizeOf(Function));
        return false;
    };
    function.function = opened;
    if (boot) {
        const report_protocol: u16 = if (opened.flags & hid.HIDF_BOOT == 0) 1 else 0;
        const protocol = usb.SetupPacket{ .request_type = d.USB_DIR_OUT | d.USB_TYPE_CLASS | d.USB_RECIP_INTERFACE, .request = d.HID_REQ_SET_PROTOCOL, .value = report_protocol, .index = number, .length = 0 };
        _ = ub.DoUSBControl(device, &protocol, null, null);
    }
    // A report only when something changes.
    const idle = usb.SetupPacket{ .request_type = d.USB_DIR_OUT | d.USB_TYPE_CLASS | d.USB_RECIP_INTERFACE, .request = d.HID_REQ_SET_IDLE, .value = 0, .index = number, .length = 0 };
    _ = ub.DoUSBControl(device, &idle, null, null);

    sys.ObtainSemaphore(&hb.lock);
    hb.functions[free_slot] = function;
    sys.ReleaseSemaphore(&hb.lock);
    binding.driver_data = function;
    binding.unit = @intCast(free_slot);
    read(sys, function);
    return true;
}

/// The interface's report descriptor read and handed to hid.library: the
/// function it makes - its sources replying to the task's port, its
/// output reports sent through `function`'s hook - or null where the
/// interface is nothing the library drives. A descriptor that cannot be
/// read leaves a boot interface its boot report.
fn openFunction(hb: *HidBase, function: *Function, device: *usb.USBDevice, interface: *const d.InterfaceDescriptor, boot_kind: u32) ?*hid.HIDFunction {
    const sys = hb.sys_base;
    const ub = hb.usb_base.?;
    const lib = hb.hid_base.?;
    const tags = [_]utility.TagItem{
        .{ .tag = hid.HIDA_Boot, .data = boot_kind },
        .{ .tag = hid.HIDA_ReplyPort, .data = @intFromPtr(hb.port.?) },
        .{ .tag = hid.HIDA_OutputHook, .data = @intFromPtr(&function.output_hook) },
        .{ .tag = utility.TAG_DONE, .data = 0 },
    };
    const length = reportDescriptorLength(ub, device, interface);
    if (length == 0) return lib.OpenHID(null, 0, &tags);
    const memory = sys.AllocMem(length, 0) orelse return null;
    defer sys.FreeMem(memory, length);
    const setup = usb.SetupPacket{
        .request_type = d.USB_DIR_IN | d.USB_TYPE_STANDARD | d.USB_RECIP_INTERFACE,
        .request = d.USB_REQ_GET_DESCRIPTOR,
        .value = @as(u16, d.USB_DT_REPORT) << 8,
        .index = interface.interface_number,
        .length = @intCast(length),
    };
    var actual: u32 = 0;
    if (ub.DoUSBControl(device, &setup, memory, &actual) != 0) return lib.OpenHID(null, 0, &tags);
    return lib.OpenHID(@ptrCast(memory), @min(actual, length), &tags);
}

/// The length of the interface's report descriptor, from the HID
/// descriptor that follows it in the configuration; at most
/// `max_descriptor`, 0 when it has none.
fn reportDescriptorLength(ub: *UsbBase, device: *usb.USBDevice, interface: *const d.InterfaceDescriptor) u32 {
    var at: ?*const d.DescriptorHeader = @ptrCast(interface);
    while (ub.NextUSBDescriptor(device, at, 0)) |next| {
        if (next.descriptor_type == d.USB_DT_INTERFACE) return 0;
        if (next.descriptor_type == d.USB_DT_HID and next.length >= 9) {
            // bNumDescriptors at 5, then a type and a length each.
            const bytes: [*]const u8 = @ptrCast(next);
            var index: usize = 0;
            while (index < bytes[5] and 6 + index * 3 + 2 < next.length) : (index += 1) {
                const entry = bytes + 6 + index * 3;
                if (entry[0] != d.USB_DT_REPORT) continue;
                const length = @as(u32, entry[1]) | @as(u32, entry[2]) << 8;
                return @min(length, max_descriptor);
            }
            return 0;
        }
        at = next;
    }
    return 0;
}

/// A bound keyboard or mouse let go of, by the task, and waited for. The
/// contract is usbclass's (sdk/fd/usbclass_lib.fd).
///
/// INPUTS:
/// - `hb` - the driver's base.
/// - `binding` - what USBClassBind took.
pub fn USBClassUnbind(hb: *HidBase, binding: *usb.USBBinding) void {
    const sys = hb.sys_base;
    const function = functionOf(binding.driver_data) orelse return;
    const reply = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(reply);
    var command = Command{ .function = function };
    command.message.reply_port = reply;
    command.message.length = @sizeOf(Command);
    sys.PutMsg(hb.command_port.?, &command.message);
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
    binding.driver_data = null;
}

fn lvoUSBClassBind(hb: *HidBase, binding: *usb.USBBinding) callconv(.c) bool {
    return USBClassBind(hb, binding);
}
fn lvoUSBClassUnbind(hb: *HidBase, binding: *usb.USBBinding) callconv(.c) void {
    return USBClassUnbind(hb, binding);
}

comptime {
    const interface = sdk.interface.usbclass;
    if (!exec.libraries.sameSignature(@TypeOf(&lvoUSBClassBind), interface.Fn.USBClassBind) or
        !exec.libraries.sameSignature(@TypeOf(&lvoUSBClassUnbind), interface.Fn.USBClassUnbind))
        @compileError("hid.device: a class call does not match the SDK's type");
}

// --- the device -------------------------------------------------------------------

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    io.err = exec.IOERR_NOCMD;
    hidBase(dev).sys_base.ReplyIO(io);
}

fn abortIO(_: *exec.Device, _: *exec.IORequest) callconv(.c) i32 {
    return -1;
}

/// Only usb.library's open, on `USBCLASS_UNIT_BIND`: the device has no
/// units of its own yet.
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    if (unit_number != usbclass.USBCLASS_UNIT_BIND) return exec.IOERR_OPENFAIL;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    io.unit = null;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    _ = io;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: its task has no way to end yet.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// usb.library and hid.library opened, and the task started and waited
/// for.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const hb = hidBase(dev);
    hb.sys_base = sys_base;
    hb.seg_list = seg_list;
    hb.functions = @splat(null);
    sys_base.InitSemaphore(&hb.lock);
    hb.usb_base = @ptrCast(sys_base.OpenLibrary(usb.USBNAME, 1) orelse return null);
    hb.hid_base = @ptrCast(sys_base.OpenLibrary(hid.HIDNAME, 1) orelse return closeLibraries(hb));
    const stack = sys_base.AllocMem(stack_size, exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return closeLibraries(hb);
    hb.stack = stack;
    hb.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    const signal = sys_base.AllocSignal(-1);
    if (signal < 0) {
        sys_base.FreeMem(stack, stack_size);
        return closeLibraries(hb);
    }
    hb.starter = sys_base.FindTask(null);
    hb.start_signal = signal;
    _ = sys_base.AddTask(&hb.task, &hidTask, null);
    _ = sys_base.Wait(@as(u32, 1) << @intCast(signal));
    sys_base.FreeSignal(signal);
    if (hb.port == null or hb.command_port == null) return null;
    return dev;
}

/// The libraries init opened, closed where it cannot go on before the
/// task is started: null, init's answer then.
fn closeLibraries(hb: *HidBase) ?*exec.Device {
    const sys = hb.sys_base;
    if (hb.hid_base) |lib| sys.CloseLibrary(@ptrCast(@alignCast(lib)));
    if (hb.usb_base) |lib| sys.CloseLibrary(@ptrCast(@alignCast(lib)));
    return null;
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
    .data_size = @sizeOf(HidBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

const speaks = [_]u32{ devices.DEVIF_USBCLASS, 0 };

/// What it drives: the boot keyboards and mice.
const matches = [_]usbclass.USBMatch{
    .{ .fields = usbclass.USBMATCH_CLASS | usbclass.USBMATCH_SUBCLASS | usbclass.USBMATCH_PROTOCOL, .interface_class = d.USB_CLASS_HID, .interface_subclass = d.HID_SUBCLASS_BOOT, .interface_protocol = d.HID_PROTOCOL_KEYBOARD },
    .{ .fields = usbclass.USBMATCH_CLASS | usbclass.USBMATCH_SUBCLASS | usbclass.USBMATCH_PROTOCOL, .interface_class = d.USB_CLASS_HID, .interface_subclass = d.HID_SUBCLASS_BOOT, .interface_protocol = d.HID_PROTOCOL_MOUSE },
    // Any other HID interface: its report descriptor decides.
    .{ .fields = usbclass.USBMATCH_CLASS, .interface_class = d.USB_CLASS_HID },
    .{},
};

/// AUTOINIT and DEVICEINFO: made when usb.library opens it, and its match
/// table read from the file without loading it.
export const hid_device_tag: usbclass.ResidentUSBClass linksection(".resident") = .{
    .device = .{
        .resident = .{
            .match_tag = @ptrCast(&hid_device_tag),
            .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
            .version = DEVICE_VERSION,
            .pri = 0,
            .type = .device,
            .name = DEVICE_NAME,
            .id_string = DEVICE_VERSION_STRING[1..],
            .init = &init_table,
        },
        .speaks = &speaks,
        .units = 0,
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
