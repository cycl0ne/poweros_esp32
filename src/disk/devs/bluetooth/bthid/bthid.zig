// SPDX-License-Identifier: MIT
//! bluetooth/bthid.device: Bluetooth keyboards and mice over BR/EDR. A
//! profile driver (sdk/devices/btprofile.zig): bluetooth.library offers it
//! the HID service of each device this machine is bonded with, and it
//! takes those whose report descriptor - in the service's record -
//! describes a keyboard or a mouse; every report the device sends goes to
//! hid.library, which makes it into key-downs and key-ups for
//! keyboard.device and moves, buttons and the wheel for mouse.device - so
//! a Bluetooth keyboard is the system's keyboard with nothing else
//! knowing.
//!
//! **Its channels.** A HID device is reached over two L2CAP channels,
//! control (PSM 17) and interrupt (PSM 19), each frame beginning with a
//! byte that says what it is (sdk/libs/bluetooth/hidp.zig). The driver
//! opens them, control first, when it is offered a device that has a
//! link - the pairing that bonded it has just ended; after that the
//! device opens them itself whenever it has something to send, as a
//! keyboard does once a key is pressed. So the driver serves both PSMs
//! while it drives a device - only over a bonded device's link encrypted
//! with its bond's key (BTLSF_SECURE) - and closes again a channel of a
//! device it does not drive.
//!
//! **Reports.** An input report on the interrupt channel goes to
//! HIDInput; a keyboard's LEDs come back from hid.library as an output
//! report, sent on the same channel. On the control channel the device's
//! VIRTUAL_CABLE_UNPLUG closes both channels - the bond stays the user's
//! to end - and anything else is let go: the driver asks it nothing. The
//! function hid.library reads the reports by lives while the interrupt
//! channel does: its close lets go of whatever keys or buttons the device
//! still held, and the next channel opens a new function.
//!
//! **One task for every device.** The channels' messages, the listeners'
//! and the commands come to one task, which opens, reads and closes every
//! channel - so no channel is closed under a message being read about it.
//! Binding runs on bluetooth.library's binder: the record's descriptor
//! copied and read into a function, and the task told of the device - it
//! adds the listeners with the first device, and opens the channels where
//! the device has a link. Unbinding is a command to the task, waited for:
//! with BTPU_FORGET - the bond is ending - the device told
//! VIRTUAL_CABLE_UNPLUG first, then its channels closed, interrupt first,
//! and its function; the listeners go with the last device. So the
//! listeners are the task's alone, and nothing is called holding the
//! lock.
//!
//! The device's own units are none: bluetooth.library opens it on
//! `BTPROFILE_UNIT_BIND` for its two calls. It stays once loaded.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const hidp = bluetooth.hidp;
const sdp = bluetooth.sdp;
const l2cap = bluetooth.l2cap;
const btprofile = sdk.devices.btprofile;
const hid = sdk.hid;
const utility = sdk.utility;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const BluetoothBase = sdk.interface.bluetooth.BluetoothBase;
const HIDBase = sdk.interface.hid.HIDBase;

pub const DEVICE_NAME = "bthid.device";
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "23.11.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// The most devices driven at once.
const max_devices = 8;
/// The standard stack: 32 KiB on a 64-bit machine, 16 KiB on a 32-bit one.
const stack_size = 4096 * @sizeOf(usize);
/// The longest report descriptor kept.
const max_descriptor = 1024;
/// Above dos's processes, as input.device's sources are: a key is taken
/// while a program computes.
const task_pri = 10;
/// The longest output report sent, its header and ID included.
const output_most = 18;

/// A device driven: one HID service of a bonded device. Its fields past
/// the binding are the task's alone.
const Hid = struct {
    hb: *BtHidBase,
    /// The device, as the binding names it.
    controller: u32,
    address: bluetooth.BTAddress,
    /// Its report descriptor, from its record: what each new function is
    /// opened with.
    descriptor: [max_descriptor]u8 = undefined,
    descriptor_length: u32 = 0,
    /// Its channels while they are open.
    control: ?*bluetooth.BTChannel = null,
    interrupt: ?*bluetooth.BTChannel = null,
    /// What hid.library reads its reports by - from the binding until the
    /// interrupt channel first closes, then while it is open - and the
    /// hook its output reports come back through.
    function: ?*hid.HIDFunction = null,
    output_hook: utility.Hook = .{},
    /// The command that tells the task of the device, sent once; and the
    /// one that lets go of it where its unbinding cannot wait for it.
    bound: Command = .{ .kind = .bound },
    unbind: Command = .{ .kind = .unbind },
};

const Kind = enum(u32) { bound, unbind };

/// A command to the task, about one device: `bound` one-way, `unbind`
/// replied once it is done - or, the device's own, one-way too.
const Command = extern struct {
    message: exec.Message = .{},
    kind: Kind = .bound,
    flags: u32 = 0,
    device: ?*anyopaque = null,
};

const BtHidBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    bt_base: ?*BluetoothBase = null,
    hid_base: ?*HIDBase = null,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The task's ports: the channels' and the listeners' messages, the
    /// commands, and the replies of hid.library's requests.
    port: ?*exec.MsgPort = null,
    command_port: ?*exec.MsgPort = null,
    hid_port: ?*exec.MsgPort = null,
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The listeners on the two PSMs, while it drives a device: the
    /// task's.
    control_listener: ?*bluetooth.BTListener = null,
    interrupt_listener: ?*bluetooth.BTListener = null,
    /// The devices driven, a slot each: added by the binder (a bind),
    /// taken by the task (an unbind), under the lock.
    devices: [max_devices]?*anyopaque = @splat(null),
    lock: exec.SignalSemaphore = .{},
};

fn btHidBase(dev: *exec.Device) *BtHidBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

fn hidOf(raw: ?*anyopaque) ?*Hid {
    return @ptrCast(@alignCast(raw orelse return null));
}

// --- the task ---------------------------------------------------------------------

fn btHidTask(sys: *ExecBase) callconv(.c) void {
    const hb: *BtHidBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    hb.port = sys.CreateMsgPort();
    hb.command_port = sys.CreateMsgPort();
    hb.hid_port = sys.CreateMsgPort();
    started(hb);
    const port = hb.port orelse return;
    const commands = hb.command_port orelse return;
    if (hb.hid_port == null) return;
    while (true) {
        _ = sys.Wait(port.sigMask() | commands.sigMask());
        while (sys.GetMsg(commands)) |message| {
            // Read first: a one-way unbind is in the memory it frees.
            const command: *Command = @fieldParentPtr("message", message);
            const replied = message.reply_port != null;
            const kind = command.kind;
            const flags = command.flags;
            if (hidOf(command.device)) |device| switch (kind) {
                .bound => drive(hb, device),
                .unbind => letGo(hb, device, flags),
            };
            if (replied) sys.ReplyMsg(message);
        }
        while (sys.GetMsg(port)) |message| {
            const told: *bluetooth.BTChannelMessage = @fieldParentPtr("message", message);
            heard(hb, told);
        }
    }
}

fn started(hb: *BtHidBase) void {
    const starter = hb.starter orelse return;
    hb.starter = null;
    hb.sys_base.Signal(starter, @as(u32, 1) << @intCast(hb.start_signal));
}

/// The device driven with this address on this controller.
fn findByAddress(hb: *BtHidBase, controller: u32, address: bluetooth.BTAddress) ?*Hid {
    const sys = hb.sys_base;
    sys.ObtainSemaphoreShared(&hb.lock);
    defer sys.ReleaseSemaphore(&hb.lock);
    for (hb.devices) |slot| {
        const device = hidOf(slot) orelse continue;
        if (device.controller == controller and sameAddress(device.address, address)) return device;
    }
    return null;
}

/// The device whose channel this is.
fn findByChannel(hb: *BtHidBase, channel: *bluetooth.BTChannel) ?*Hid {
    const sys = hb.sys_base;
    sys.ObtainSemaphoreShared(&hb.lock);
    defer sys.ReleaseSemaphore(&hb.lock);
    for (hb.devices) |slot| {
        const device = hidOf(slot) orelse continue;
        if (device.control == channel or device.interrupt == channel) return device;
    }
    return null;
}

/// A message about a channel: a device's channel to a listener, a frame,
/// a channel's end. Replied - a frame once it is read, since its bytes are
/// the library's until then - before anything closes the channel.
fn heard(hb: *BtHidBase, told: *bluetooth.BTChannelMessage) void {
    const sys = hb.sys_base;
    const channel = told.channel orelse return sys.ReplyMsg(&told.message);
    switch (told.kind) {
        bluetooth.BTCM_OPENED => {
            sys.ReplyMsg(&told.message);
            opened(hb, channel);
        },
        bluetooth.BTCM_DATA => {
            const device = findByChannel(hb, channel);
            var unplugged = false;
            if (device) |driven| {
                if (told.data) |data| unplugged = frame(hb, driven, channel, data[0..told.length]);
            }
            sys.ReplyMsg(&told.message);
            if (unplugged) unplug(hb, device.?);
        },
        bluetooth.BTCM_CLOSED => {
            sys.ReplyMsg(&told.message);
            closed(hb, channel);
        },
        else => sys.ReplyMsg(&told.message),
    }
}

/// A device's channel to one of the listeners: kept where it is a device
/// driven - in place of one it had, whose function goes with it - and
/// closed again where it is not.
fn opened(hb: *BtHidBase, channel: *bluetooth.BTChannel) void {
    const bt = hb.bt_base.?;
    const device = findByAddress(hb, channel.controller, channel.address) orelse {
        say(hb, "%s: %02x:%02x:%02x:%02x:%02x:%02x is no device it drives: its channel closed\n", channel.address, .{});
        return bt.CloseBTChannel(channel);
    };
    switch (channel.psm) {
        l2cap.PSM_HID_CONTROL => {
            if (device.control) |old| bt.CloseBTChannel(old);
            device.control = channel;
        },
        l2cap.PSM_HID_INTERRUPT => {
            if (device.interrupt) |old| {
                bt.CloseBTChannel(old);
                endFunction(hb, device);
            }
            device.interrupt = channel;
            startFunction(hb, device);
            say(hb, "%s: %02x:%02x:%02x:%02x:%02x:%02x connected\n", device.address, .{});
        },
        else => bt.CloseBTChannel(channel),
    }
}

/// A channel the device or its link ended: let go of - the interrupt
/// channel's function with it - and given back.
fn closed(hb: *BtHidBase, channel: *bluetooth.BTChannel) void {
    if (findByChannel(hb, channel)) |device| {
        if (device.control == channel) device.control = null;
        if (device.interrupt == channel) {
            device.interrupt = null;
            endFunction(hb, device);
            say(hb, "%s: %02x:%02x:%02x:%02x:%02x:%02x disconnected\n", device.address, .{});
        }
    }
    hb.bt_base.?.CloseBTChannel(channel);
}

/// One frame of a device's: an input report to hid.library; true for the
/// device's VIRTUAL_CABLE_UNPLUG on the control channel, which the
/// caller acts on once it has replied.
fn frame(hb: *BtHidBase, device: *Hid, channel: *bluetooth.BTChannel, data: []const u8) bool {
    if (data.len == 0) return false;
    const kind = data[0] & hidp.HIDP_TYPE_MASK;
    const parameter = data[0] & hidp.HIDP_PARAM_MASK;
    if (channel == device.interrupt) {
        if (kind != hidp.HIDP_DATA or parameter != hidp.HIDP_REPORT_INPUT or data.len < 2) return false;
        // The report as its descriptor lays it out: its ID first where it
        // has one, as over USB.
        if (device.function) |function| hb.hid_base.?.HIDInput(function, data.ptr + 1, @intCast(data.len - 1));
        return false;
    }
    return kind == hidp.HIDP_CONTROL and parameter == hidp.HIDP_CTRL_VIRTUAL_CABLE_UNPLUG;
}

/// The device's VIRTUAL_CABLE_UNPLUG: its channels closed. The bond is
/// the user's to end.
fn unplug(hb: *BtHidBase, device: *Hid) void {
    closeChannels(hb, device);
    say(hb, "%s: %02x:%02x:%02x:%02x:%02x:%02x unplugged itself; its bond is kept\n", device.address, .{});
}

/// A device just bound: the listeners added with the first, and its
/// channels opened where it has a link - its pairing has just ended.
fn drive(hb: *BtHidBase, device: *Hid) void {
    if (!listen(hb)) say(hb, "%s: %02x:%02x:%02x:%02x:%02x:%02x: PSMs 17 and 19 are served already - its own channels are refused\n", device.address, .{});
    if (linked(hb.bt_base.?, device)) connect(hb, device);
}

/// The device's channels opened from this side, control, then interrupt.
fn connect(hb: *BtHidBase, device: *Hid) void {
    const bt = hb.bt_base.?;
    const port = hb.port.?;
    if (device.control == null) {
        var channel: ?*bluetooth.BTChannel = null;
        const result = bt.OpenBTChannel(device.controller, &device.address, l2cap.PSM_HID_CONTROL, port, &channel);
        if (result != 0) return say(hb, "%s: %02x:%02x:%02x:%02x:%02x:%02x: its control channel not opened (%ld)\n", device.address, .{@as(i64, result)});
        device.control = channel;
    }
    if (device.interrupt == null) {
        var channel: ?*bluetooth.BTChannel = null;
        const result = bt.OpenBTChannel(device.controller, &device.address, l2cap.PSM_HID_INTERRUPT, port, &channel);
        if (result != 0) {
            say(hb, "%s: %02x:%02x:%02x:%02x:%02x:%02x: its interrupt channel not opened (%ld)\n", device.address, .{@as(i64, result)});
            return closeChannels(hb, device);
        }
        device.interrupt = channel;
        startFunction(hb, device);
        say(hb, "%s: %02x:%02x:%02x:%02x:%02x:%02x connected\n", device.address, .{});
    }
}

/// Both channels closed, the interrupt one first, and its function.
fn closeChannels(hb: *BtHidBase, device: *Hid) void {
    const bt = hb.bt_base.?;
    if (device.interrupt) |channel| {
        device.interrupt = null;
        bt.CloseBTChannel(channel);
    }
    endFunction(hb, device);
    if (device.control) |channel| {
        device.control = null;
        bt.CloseBTChannel(channel);
    }
}

/// A device let go of, on the task: told VIRTUAL_CABLE_UNPLUG where its
/// bond is ending (BTPU_FORGET), its channels and function closed, its
/// slot freed - and the listeners taken away with the last one.
fn letGo(hb: *BtHidBase, device: *Hid, flags: u32) void {
    const sys = hb.sys_base;
    const bt = hb.bt_base.?;
    if (flags & bluetooth.BTPU_FORGET != 0) {
        if (device.control) |channel| {
            const unplugging = [_]u8{hidp.HIDP_CONTROL | hidp.HIDP_CTRL_VIRTUAL_CABLE_UNPLUG};
            _ = bt.SendBTChannel(channel, &unplugging, unplugging.len);
        }
    }
    closeChannels(hb, device);
    sys.ObtainSemaphore(&hb.lock);
    var left: usize = 0;
    for (&hb.devices) |*slot| {
        if (hidOf(slot.*) == device) slot.* = null;
        if (slot.* != null) left += 1;
    }
    sys.ReleaseSemaphore(&hb.lock);
    say(hb, "%s: %02x:%02x:%02x:%02x:%02x:%02x let go of\n", device.address, .{});
    sys.FreeMem(device, @sizeOf(Hid));
    // The listeners go with the last device. What they leave on the port
    // is read as a device's channel it does not drive: closed.
    if (left == 0) {
        bt.RemBTListener(hb.interrupt_listener);
        bt.RemBTListener(hb.control_listener);
        hb.interrupt_listener = null;
        hb.control_listener = null;
    }
}

/// A function opened from the device's descriptor where it has none.
fn startFunction(hb: *BtHidBase, device: *Hid) void {
    if (device.function != null) return;
    device.function = openFunction(hb, device);
}

/// Its function closed: whatever the device held let go of.
fn endFunction(hb: *BtHidBase, device: *Hid) void {
    const function = device.function orelse return;
    device.function = null;
    hb.hid_base.?.CloseHID(function);
}

/// The device's descriptor handed to hid.library: its sources replying to
/// the task's port for them, its output reports sent through the
/// device's hook; null where it describes nothing the library drives.
fn openFunction(hb: *BtHidBase, device: *Hid) ?*hid.HIDFunction {
    const tags = [_]utility.TagItem{
        .{ .tag = hid.HIDA_ReplyPort, .data = @intFromPtr(hb.hid_port.?) },
        .{ .tag = hid.HIDA_OutputHook, .data = @intFromPtr(&device.output_hook) },
        .{ .tag = utility.TAG_DONE, .data = 0 },
    };
    return hb.hid_base.?.OpenHID(&device.descriptor, device.descriptor_length, &tags);
}

/// An output report from hid.library - the keyboard's LEDs - sent as DATA
/// on the interrupt channel, after its ID where it has one; a report of
/// another kind as SET_REPORT on the control channel. On the task, within
/// HIDInput.
fn sendOutput(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const device: *Hid = @ptrCast(@alignCast(hook.data.?));
    const output: *const hid.HIDOutputMessage = @ptrCast(@alignCast(message.?));
    const report_kind: u8 = @intCast(output.kind & hidp.HIDP_PARAM_MASK);
    const on_interrupt = report_kind == hidp.HIDP_REPORT_OUTPUT;
    const channel = (if (on_interrupt) device.interrupt else device.control) orelse return 0;
    var bytes: [output_most]u8 = undefined;
    bytes[0] = (if (on_interrupt) hidp.HIDP_DATA else hidp.HIDP_SET_REPORT) | report_kind;
    var length: usize = 1;
    if (output.id != 0) {
        bytes[1] = output.id;
        length = 2;
    }
    const count = @min(output.length, output_most - length);
    @memcpy(bytes[length..][0..count], output.data[0..count]);
    length += count;
    _ = device.hb.bt_base.?.SendBTChannel(channel, &bytes, @intCast(@min(length, channel.mtu_out)));
    return 0;
}

fn sameAddress(one: bluetooth.BTAddress, other: bluetooth.BTAddress) bool {
    if (one.kind != other.kind) return false;
    for (one.bytes, other.bytes) |mine, theirs| {
        if (mine != theirs) return false;
    }
    return true;
}

/// A line in the log about a device: the driver's name and the address,
/// most significant first, then `rest`.
fn say(hb: *BtHidBase, comptime format: [:0]const u8, address: bluetooth.BTAddress, rest: anytype) void {
    const bytes = address.bytes;
    const name: [*:0]const u8 = DEVICE_NAME;
    exec.kprintf(hb.sys_base, format, .{ name, @as(u32, bytes[5]), @as(u32, bytes[4]), @as(u32, bytes[3]), @as(u32, bytes[2]), @as(u32, bytes[1]), @as(u32, bytes[0]) } ++ rest);
}

// --- the profile driver's calls -----------------------------------------------------

/// A HID service taken: one over BR/EDR whose record's report descriptor
/// describes a keyboard or a mouse, or both; the rest declined. The
/// contract is btprofile's (sdk/fd/btprofile_lib.fd).
///
/// INPUTS:
/// - `hb` - the driver's base.
/// - `binding` - the device and the service offered.
pub fn BTProfileBind(hb: *BtHidBase, binding: *bluetooth.BTBinding) bool {
    const sys = hb.sys_base;
    const bt = hb.bt_base orelse return false;
    const service = binding.service orelse return false;
    if (service.flags & bluetooth.BTSF_SDP == 0 or service.class16 != hidp.UUID_HID) return false;
    const descriptor = descriptorOf(bt, service) orelse return false;
    if (descriptor.len > max_descriptor) return false;

    const memory = sys.AllocMem(@sizeOf(Hid), exec.MEMF_CLEAR) orelse return false;
    const device: *Hid = @ptrCast(@alignCast(memory));
    device.* = .{ .hb = hb, .controller = binding.controller, .address = binding.address };
    @memcpy(device.descriptor[0..descriptor.len], descriptor);
    device.descriptor_length = @intCast(descriptor.len);
    device.output_hook = .{ .entry = &sendOutput, .data = device };
    device.bound.device = device;
    device.bound.message.length = @sizeOf(Command);
    const function = openFunction(hb, device) orelse {
        sys.FreeMem(memory, @sizeOf(Hid));
        return false;
    };
    device.function = function;

    sys.ObtainSemaphore(&hb.lock);
    var slot_index: ?usize = null;
    for (hb.devices, 0..) |slot, index| {
        if (slot == null) slot_index = index;
    }
    if (slot_index) |index| hb.devices[index] = device;
    sys.ReleaseSemaphore(&hb.lock);
    const free_slot = slot_index orelse {
        say(hb, "%s: %02x:%02x:%02x:%02x:%02x:%02x not driven: %ld devices are already\n", device.address, .{@as(i64, max_devices)});
        hb.hid_base.?.CloseHID(function);
        sys.FreeMem(memory, @sizeOf(Hid));
        return false;
    };
    binding.driver_data = device;
    binding.unit = @intCast(free_slot);
    const what: [*:0]const u8 = if (function.flags & hid.HIDF_KEYBOARD != 0 and function.flags & (hid.HIDF_MOUSE | hid.HIDF_TABLET) != 0)
        "a keyboard and a mouse"
    else if (function.flags & hid.HIDF_KEYBOARD != 0) "a keyboard" else if (function.flags & hid.HIDF_TABLET != 0) "a tablet" else "a mouse";
    say(hb, "%s: %02x:%02x:%02x:%02x:%02x:%02x driven: %s\n", device.address, .{what});
    sys.PutMsg(hb.command_port.?, &device.bound.message);
    return true;
}

/// The report descriptor in a HID record's descriptor list: the first of
/// its descriptors of the report's type, within the record.
fn descriptorOf(bt: *BluetoothBase, service: *const bluetooth.BTService) ?[]const u8 {
    const record = service.record orelse return null;
    var list: bluetooth.BTDataElement = .{};
    if (!bt.FindBTServiceAttribute(record, service.record_length, hidp.ATTR_HID_DESCRIPTOR_LIST, &list)) return null;
    if (list.kind != sdp.DE_SEQUENCE) return null;
    const items = list.data orelse return null;
    var at: u32 = 0;
    while (at < list.length) {
        var entry: bluetooth.BTDataElement = .{};
        if (!bt.NextBTDataElement(items + at, list.length - at, &entry)) return null;
        at += entry.whole;
        if (entry.kind != sdp.DE_SEQUENCE) continue;
        const parts = entry.data orelse continue;
        var kind: bluetooth.BTDataElement = .{};
        if (!bt.NextBTDataElement(parts, entry.length, &kind)) continue;
        if (kind.kind != sdp.DE_UINT or kind.value != hidp.HID_DESCRIPTOR_REPORT) continue;
        var bytes: bluetooth.BTDataElement = .{};
        if (!bt.NextBTDataElement(parts + kind.whole, entry.length - kind.whole, &bytes)) continue;
        if (bytes.kind != sdp.DE_TEXT) continue;
        const data = bytes.data orelse continue;
        return data[0..bytes.length];
    }
    return null;
}

/// The listeners on both PSMs, added where they are not: false where
/// either PSM is served by someone else - neither is kept then.
fn listen(hb: *BtHidBase) bool {
    if (hb.control_listener != null and hb.interrupt_listener != null) return true;
    const bt = hb.bt_base.?;
    const port = hb.port.?;
    const control = bt.AddBTListener(l2cap.PSM_HID_CONTROL, port, bluetooth.BTLSF_SECURE);
    const interrupt = bt.AddBTListener(l2cap.PSM_HID_INTERRUPT, port, bluetooth.BTLSF_SECURE);
    if (control == null or interrupt == null) {
        bt.RemBTListener(control);
        bt.RemBTListener(interrupt);
        return false;
    }
    hb.control_listener = control;
    hb.interrupt_listener = interrupt;
    return true;
}

/// Whether the device has a link to its controller.
fn linked(bt: *BluetoothBase, device: *const Hid) bool {
    const list = bt.ObtainBTConnections(device.controller) orelse return false;
    defer bt.ReleaseBTConnections(list);
    var it = list.iterator();
    while (it.next()) |node| {
        const connection: *const bluetooth.BTConnection = @fieldParentPtr("node", node);
        if (sameAddress(connection.address, device.address)) return true;
    }
    return false;
}

/// A device let go of, by the task, and waited for - where a port to wait
/// on cannot be made, only sent. The contract is btprofile's
/// (sdk/fd/btprofile_lib.fd).
///
/// INPUTS:
/// - `hb` - the driver's base.
/// - `binding` - what BTProfileBind took.
/// - `flags` - BTPU_*.
pub fn BTProfileUnbind(hb: *BtHidBase, binding: *bluetooth.BTBinding, flags: u32) void {
    const sys = hb.sys_base;
    const device = hidOf(binding.driver_data) orelse return;
    binding.driver_data = null;
    const reply = sys.CreateMsgPort() orelse {
        // Sent alone: the task reads nothing of the binding.
        device.unbind = .{ .kind = .unbind, .flags = flags, .device = device };
        device.unbind.message.length = @sizeOf(Command);
        return sys.PutMsg(hb.command_port.?, &device.unbind.message);
    };
    defer sys.DeleteMsgPort(reply);
    var command = Command{ .kind = .unbind, .flags = flags, .device = device };
    command.message.reply_port = reply;
    command.message.length = @sizeOf(Command);
    sys.PutMsg(hb.command_port.?, &command.message);
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
}

fn lvoBTProfileBind(hb: *BtHidBase, binding: *bluetooth.BTBinding) callconv(.c) bool {
    return BTProfileBind(hb, binding);
}
fn lvoBTProfileUnbind(hb: *BtHidBase, binding: *bluetooth.BTBinding, flags: u32) callconv(.c) void {
    return BTProfileUnbind(hb, binding, flags);
}

comptime {
    const interface = sdk.interface.btprofile;
    if (!exec.libraries.sameSignature(@TypeOf(&lvoBTProfileBind), interface.Fn.BTProfileBind) or
        !exec.libraries.sameSignature(@TypeOf(&lvoBTProfileUnbind), interface.Fn.BTProfileUnbind))
        @compileError("bthid.device: a profile call does not match the SDK's type");
}

// --- the device -------------------------------------------------------------------

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    io.err = exec.IOERR_NOCMD;
    btHidBase(dev).sys_base.ReplyIO(io);
}

fn abortIO(_: *exec.Device, _: *exec.IORequest) callconv(.c) i32 {
    return -1;
}

/// Only bluetooth.library's open, on `BTPROFILE_UNIT_BIND`: the device has
/// no units of its own.
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    if (unit_number != btprofile.BTPROFILE_UNIT_BIND) return exec.IOERR_OPENFAIL;
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

/// bluetooth.library and hid.library opened, and the task started and
/// waited for.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const hb = btHidBase(dev);
    hb.sys_base = sys_base;
    hb.seg_list = seg_list;
    hb.devices = @splat(null);
    sys_base.InitSemaphore(&hb.lock);
    hb.bt_base = @ptrCast(sys_base.OpenLibrary(bluetooth.BLUETOOTHNAME, 1) orelse return null);
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
    _ = sys_base.AddTask(&hb.task, &btHidTask, null);
    _ = sys_base.Wait(@as(u32, 1) << @intCast(signal));
    sys_base.FreeSignal(signal);
    if (hb.port == null or hb.command_port == null or hb.hid_port == null) return null;
    return dev;
}

/// The libraries init opened, closed where it cannot go on before the
/// task is started: null, init's answer then.
fn closeLibraries(hb: *BtHidBase) ?*exec.Device {
    const sys = hb.sys_base;
    if (hb.hid_base) |lib| sys.CloseLibrary(@ptrCast(@alignCast(lib)));
    if (hb.bt_base) |lib| sys.CloseLibrary(@ptrCast(@alignCast(lib)));
    return null;
}

/// The jump table: the six standard vectors, then the profile driver's
/// two.
const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
    vec(lvoBTProfileBind),
    vec(lvoBTProfileUnbind),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(BtHidBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

const speaks = [_]u32{ devices.DEVIF_BTPROFILE, 0 };

/// What it drives: the HID service over BR/EDR.
const matches = [_]btprofile.BTMatch{
    .{ .over = btprofile.BTMATCH_BREDR, .class16 = hidp.UUID_HID },
    .{},
};

/// AUTOINIT and DEVICEINFO: made when bluetooth.library opens it, and its
/// match table read from the file without loading it.
export const bthid_device_tag: btprofile.ResidentBTProfile linksection(".resident") = .{
    .device = .{
        .resident = .{
            .match_tag = @ptrCast(&bthid_device_tag),
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
