// SPDX-License-Identifier: MIT
//! usb/aic8800.device: an AICSemi AIC8800 USB Wi-Fi stick, as a wireless
//! network device (sdk/devices/network.zig, sdk/devices/wireless.zig).
//!
//! **Two roles, one stick.** Plugged in, the stick is its boot ROM
//! (A69C:8800): the device gives it its firmware (boot.zig) - read from
//! `DEVS:usb/firmware/aic8800/`, which `scripts/fetch-aic8800.sh`
//! fetches - and starts it, and the stick leaves the bus and comes back
//! as the Wi-Fi (A69C:8801). Only a high-speed port can do that: the
//! boot ROM is left alone on a slower one. The Wi-Fi is brought up to a
//! station (bringup.zig) and runs as unit 0 (radio.zig).
//!
//! **Every transfer runs on the device's worker**, a DOS process, since
//! the firmware is read from files: the bind (on the bus's process) only
//! opens the pipes and hands the worker the stick; the unbind takes its
//! transfers back and waits for the worker to let it go. The unit's
//! requests come to the worker too, on the same signal, except
//! S2_DEVICEQUERY and S2_GETSTATIONADDRESS, answered where they are
//! asked. The unit is there with no stick plugged in: off line, its
//! scans and joins answered or kept for the stick that comes.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const net = sdk.devices.network;
const timer = sdk.devices.timer;
const usb = sdk.usb;
const d = usb.descriptors;
const usbhc = sdk.devices.usbhc;
const usbclass = sdk.devices.usbclass;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const _aic = @import("_aic8800.zig");
const boot_file = @import("boot.zig");
const radio = @import("radio.zig");
const netif = @import("netif.zig");
const AicBase = _aic.AicBase;
const Command = _aic.Command;

pub const DEVICE_NAME = _aic.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "14.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// The worker reads a file and runs the boot sequence, its buffers on
/// its stack; the Wi-Fi's are in its block.
const worker_stack = 16384;
const worker_pri = 5;
/// The DOS process that brings up the interface: it runs a command.
const netif_stack = 8192;
const netif_pri = 4;
/// How long a transfer may wait: out, and an answer in.
const out_timeout_ms = 5000;
const in_timeout_ms = 2000;

/// Where the firmware is, and its files: the firmware, then each patch
/// file for revisions before U03 and for U03 on.
const firmware_dir = "DEVS:usb/firmware/aic8800/";
const name_firmware = firmware_dir ++ "fmacfw.bin";
const names_early = [3][*:0]const u8{ firmware_dir ++ "fw_adid.bin", firmware_dir ++ "fw_patch.bin", firmware_dir ++ "fw_patch_table.bin" };
const names_u03 = [3][*:0]const u8{ firmware_dir ++ "fw_adid_u03.bin", firmware_dir ++ "fw_patch_u03.bin", firmware_dir ++ "fw_patch_table_u03.bin" };

fn say(sys: *ExecBase, comptime text: [:0]const u8) void {
    exec.kprintf(sys, "%s: " ++ text ++ "\n", .{@as([*:0]const u8, DEVICE_NAME)});
}

// --- the worker -------------------------------------------------------------

fn workerMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const base: *AicBase = @ptrCast(@alignCast(me.user_data orelse return));
    const signal = sys.AllocSignal(-1);
    const work = radio.makeWork(base);
    if (signal >= 0 and work != null) {
        base.work_mask = @as(u32, 1) << @intCast(signal);
        sys.Disable();
        for ([_]*exec.MsgPort{ &base.commands, &base.pipes, &base.unit.msg_port }) |port| {
            port.sig_bit = @intCast(signal);
            port.sig_task = me;
            port.flags = exec.PA_SIGNAL;
        }
        sys.Enable();
        base.timer_io = .{};
        base.timer_io.node.message.reply_port = &base.pipes;
        base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.timer_io.node, 0) == 0) base.timer_open = 1;
        radio.openPause(work.?);
        base.worker = me;
        base.ready = 1;
    }
    if (base.starter) |starter| {
        base.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
    }
    if (base.ready == 0) return;
    const radio_work = work.?;
    while (true) {
        // Every port looked at again after any work: one signal serves
        // them all, and a request waiting for its answer may take it from
        // a message that came meanwhile.
        var worked = true;
        while (worked) {
            worked = false;
            while (sys.GetMsg(&base.commands)) |message| {
                const cmd: *Command = @fieldParentPtr("message", message);
                switch (cmd.kind) {
                    .load => loadFirmware(base),
                    .start => radio.start(radio_work),
                    .let_go => {
                        letGo(base);
                        sys.ReplyMsg(&cmd.message);
                    },
                }
                worked = true;
            }
            while (sys.GetMsg(&base.pipes)) |message| {
                _ = radio.replied(radio_work, message);
                worked = true;
            }
            while (sys.GetMsg(&base.unit.msg_port)) |message| {
                radio.request(radio_work, _aic.sanaReq(_aic.requestOf(message)));
                worked = true;
            }
            if (radio.due(radio_work)) worked = true;
        }
        _ = sys.Wait(base.work_mask);
    }
}

/// The stick's transfers taken back, its pipes closed and the stick
/// given up.
fn letGo(base: *AicBase) void {
    const sys = base.sys_base;
    const ub = base.ub();
    radio.stop(radio.workOf(base));
    ub.CloseUSBPipe(base.bulk_in);
    ub.CloseUSBPipe(base.bulk_out);
    ub.CloseUSBPipe(base.msg_out);
    sys.ObtainSemaphore(&base.lock);
    base.bulk_in = null;
    base.bulk_out = null;
    base.msg_out = null;
    base.device = null;
    base.bound = 0;
    sys.ReleaseSemaphore(&base.lock);
}

// --- the boot ROM given its firmware --------------------------------------------

/// The transport boot.zig runs over: the boot ROM's bulk pipes, waited
/// for on the worker.
const Pipes = struct {
    base: *AicBase,

    fn of(context: *anyopaque) *Pipes {
        return @ptrCast(@alignCast(context));
    }

    fn send(context: *anyopaque, bytes: []const u8) bool {
        const base = of(context).base;
        if (@atomicLoad(u8, &base.leaving, .acquire) != 0) return false;
        const io = &base.bulk_out.?.io;
        io.std.data = @constCast(bytes.ptr);
        io.std.length = bytes.len;
        io.std.actual = 0;
        io.flags = usbhc.UHF_ZERO_PACKET;
        io.nak_timeout = out_timeout_ms;
        return base.sys_base.DoIO(&io.std.req) == 0;
    }

    fn receive(context: *anyopaque, into: []u8) ?usize {
        const base = of(context).base;
        if (@atomicLoad(u8, &base.leaving, .acquire) != 0) return null;
        const io = &base.bulk_in.?.io;
        io.std.data = into.ptr;
        io.std.length = into.len;
        io.std.actual = 0;
        io.flags = 0;
        io.nak_timeout = in_timeout_ms;
        if (base.sys_base.DoIO(&io.std.req) != 0) return null;
        return @intCast(io.std.actual);
    }

    fn wait(context: *anyopaque, ms: u32) void {
        const base = of(context).base;
        base.dos_base.?.Delay(@max(ms / 20, 1));
    }

    /// A line of the chip's log, into the system's.
    fn line(context: *anyopaque, text: []const u8) void {
        const base = of(context).base;
        var buffer: [96:0]u8 = @splat(0);
        var length: usize = 0;
        for (text) |char| {
            if (char == 0 or length == buffer.len) break;
            if (char == '\n' or char == '\r') continue;
            buffer[length] = char;
            length += 1;
        }
        if (length == 0) return;
        exec.kprintf(base.sys_base, "%s: firmware: %s\n", .{ @as([*:0]const u8, DEVICE_NAME), @as([*:0]const u8, &buffer) });
    }
};

/// A file read whole into memory of its own: the caller frees it.
fn readFile(base: *AicBase, name: [*:0]const u8) ?[]u8 {
    const sys = base.sys_base;
    const dl = base.dos_base.?;
    const file = dl.Open(name, dos.MODE_OLDFILE) orelse {
        exec.kprintf(sys, "%s: no %s\n", .{ @as([*:0]const u8, DEVICE_NAME), name });
        return null;
    };
    defer _ = dl.Close(file);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.ExamineFH(file, &fib) or fib.size == 0) return null;
    const size: usize = @intCast(fib.size);
    const memory = sys.AllocVec(size, exec.MEMF_ANY) orelse return null;
    const bytes: [*]u8 = @ptrCast(memory);
    if (dl.Read(file, bytes, @intCast(size)) != @as(isize, @intCast(size))) {
        sys.FreeVec(memory);
        return null;
    }
    return bytes[0..size];
}

/// The boot ROM's revision read, its files read, the firmware given it
/// and started: the stick leaves the bus after.
fn loadFirmware(base: *AicBase) void {
    const sys = base.sys_base;
    var pipes = Pipes{ .base = base };
    var boot: boot_file.Boot = .{ .transport = .{
        .context = &pipes,
        .send = Pipes.send,
        .receive = Pipes.receive,
        .wait = Pipes.wait,
        .say = Pipes.line,
    } };
    const rev = boot.revision() catch {
        say(sys, "the boot ROM does not answer");
        return;
    };
    exec.kprintf(sys, "%s: boot ROM, chip revision %x.%x\n", .{ @as([*:0]const u8, DEVICE_NAME), @as(u32, rev.chip), @as(u32, rev.sub) });
    const names = if (rev.chip == boot_file.REV_U03) names_u03 else names_early;
    const files: [4]?[]u8 = .{ readFile(base, name_firmware), readFile(base, names[0]), readFile(base, names[1]), readFile(base, names[2]) };
    defer for (files) |file| if (file) |bytes| sys.FreeVec(bytes.ptr);
    for (files) |file| if (file == null) return;
    boot.load(rev, .{ .firmware = files[0].?, .adid = files[1].?, .patch = files[2].?, .patch_table = files[3].? }) catch |failure| {
        exec.kprintf(sys, "%s: loading the firmware failed: %s\n", .{ @as([*:0]const u8, DEVICE_NAME), @as([*:0]const u8, @errorName(failure)) });
        return;
    };
    say(sys, "firmware started; the stick comes back as the Wi-Fi");
}

// --- the class driver's calls -----------------------------------------------

/// The boot ROM's interface: its bulk pipes opened and the worker handed
/// the stick. The Wi-Fi's interfaces are said in the log, not taken yet.
fn bind(base: *AicBase, binding: *usb.USBBinding) bool {
    const sys = base.sys_base;
    const ub = base.usb_base orelse return false;
    const device = binding.device.?;
    const interface = binding.interface.?;
    if (device.descriptor.product_id == _aic.PRODUCT_WIFI) {
        // The Wi-Fi is the vendor's own interface; the others are
        // Bluetooth's.
        if (interface.interface_class != d.USB_CLASS_VENDOR_SPEC) return false;
        return bindWifi(base, binding, device, interface);
    }
    if (device.speed != usbhc.USB_SPEED_HIGH) {
        say(sys, "the stick needs a high-speed port");
        return false;
    }
    const in = ub.FindUSBEndpoint(device, interface, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_BULK) orelse return false;
    const out = ub.FindUSBEndpoint(device, interface, d.USB_DIR_OUT, d.USB_ENDPOINT_XFER_BULK) orelse return false;
    sys.ObtainSemaphore(&base.lock);
    const free = base.bound == 0;
    if (free) base.bound = 1;
    sys.ReleaseSemaphore(&base.lock);
    if (!free) return false;
    const bulk_in = ub.OpenUSBPipe(device, in.endpoint_address, &base.pipes);
    const bulk_out = ub.OpenUSBPipe(device, out.endpoint_address, &base.pipes);
    if (bulk_in == null or bulk_out == null) {
        ub.CloseUSBPipe(bulk_in);
        ub.CloseUSBPipe(bulk_out);
        sys.ObtainSemaphore(&base.lock);
        base.bound = 0;
        sys.ReleaseSemaphore(&base.lock);
        return false;
    }
    base.device = device;
    base.bulk_in = bulk_in;
    base.bulk_out = bulk_out;
    @atomicStore(u8, &base.leaving, 0, .release);
    binding.driver_data = base;
    binding.unit = 0;
    base.load = .{ .kind = .load };
    base.load.message.length = @sizeOf(Command);
    sys.PutMsg(&base.commands, &base.load.message);
    return true;
}

/// The Wi-Fi's interface: its endpoint in, its first out for frames and
/// its second for messages, opened, and the worker handed the stick.
fn bindWifi(base: *AicBase, binding: *usb.USBBinding, device: *usb.USBDevice, interface: *const d.InterfaceDescriptor) bool {
    const sys = base.sys_base;
    const ub = base.ub();
    var in: ?u8 = null;
    var outs: [2]?u8 = .{ null, null };
    var at: ?*const d.DescriptorHeader = @ptrCast(interface);
    while (ub.NextUSBDescriptor(device, at, 0)) |next| : (at = next) {
        if (next.descriptor_type == d.USB_DT_INTERFACE) break;
        if (next.descriptor_type != d.USB_DT_ENDPOINT) continue;
        const endpoint: *const d.EndpointDescriptor = @ptrCast(next);
        if (endpoint.attributes & 3 != d.USB_ENDPOINT_XFER_BULK) continue;
        if (endpoint.endpoint_address & d.USB_DIR_IN != 0) {
            if (in == null) in = endpoint.endpoint_address;
        } else if (outs[0] == null) {
            outs[0] = endpoint.endpoint_address;
        } else if (outs[1] == null) {
            outs[1] = endpoint.endpoint_address;
        }
    }
    if (in == null or outs[0] == null) {
        describe(base, device, interface);
        return false;
    }
    sys.ObtainSemaphore(&base.lock);
    const free = base.bound == 0;
    if (free) base.bound = 1;
    sys.ReleaseSemaphore(&base.lock);
    if (!free) return false;
    const bulk_in = ub.OpenUSBPipe(device, in.?, &base.pipes);
    const bulk_out = ub.OpenUSBPipe(device, outs[0].?, &base.pipes);
    const msg_out = if (outs[1]) |address| ub.OpenUSBPipe(device, address, &base.pipes) else null;
    if (bulk_in == null or bulk_out == null or (outs[1] != null and msg_out == null)) {
        ub.CloseUSBPipe(bulk_in);
        ub.CloseUSBPipe(bulk_out);
        ub.CloseUSBPipe(msg_out);
        sys.ObtainSemaphore(&base.lock);
        base.bound = 0;
        sys.ReleaseSemaphore(&base.lock);
        return false;
    }
    base.device = device;
    base.bulk_in = bulk_in;
    base.bulk_out = bulk_out;
    base.msg_out = msg_out;
    @atomicStore(u8, &base.leaving, 0, .release);
    binding.driver_data = base;
    binding.unit = 0;
    base.load = .{ .kind = .start };
    base.load.message.length = @sizeOf(Command);
    sys.PutMsg(&base.commands, &base.load.message);
    return true;
}

/// One of the Wi-Fi's interfaces and its endpoints, in the log.
fn describe(base: *AicBase, device: *usb.USBDevice, interface: *const d.InterfaceDescriptor) void {
    const sys = base.sys_base;
    const ub = base.ub();
    exec.kprintf(sys, "%s: Wi-Fi interface %u, class %x/%x/%x, %u endpoints\n", .{
        @as([*:0]const u8, DEVICE_NAME),
        @as(u32, interface.interface_number),
        @as(u32, interface.interface_class),
        @as(u32, interface.interface_subclass),
        @as(u32, interface.interface_protocol),
        @as(u32, interface.num_endpoints),
    });
    var at: ?*const d.DescriptorHeader = @ptrCast(interface);
    while (ub.NextUSBDescriptor(device, at, 0)) |next| : (at = next) {
        if (next.descriptor_type == d.USB_DT_INTERFACE) break;
        if (next.descriptor_type != d.USB_DT_ENDPOINT) continue;
        const endpoint: *const d.EndpointDescriptor = @ptrCast(next);
        exec.kprintf(sys, "%s:   endpoint %x, attributes %x, %u bytes\n", .{
            @as([*:0]const u8, DEVICE_NAME),
            @as(u32, endpoint.endpoint_address),
            @as(u32, endpoint.attributes),
            @as(u32, endpoint.max_packet_size),
        });
    }
}

/// The stick let go of: its transfers taken back at once, then the worker
/// waited for while it closes the pipes.
fn unbind(base: *AicBase, binding: *usb.USBBinding) void {
    const sys = base.sys_base;
    if (binding.driver_data == null) return;
    @atomicStore(u8, &base.leaving, 1, .release);
    if (base.bulk_in) |pipe| _ = sys.AbortIO(&pipe.io.std.req);
    if (base.bulk_out) |pipe| _ = sys.AbortIO(&pipe.io.std.req);
    if (base.msg_out) |pipe| _ = sys.AbortIO(&pipe.io.std.req);
    const reply = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(reply);
    var cmd = Command{ .kind = .let_go };
    cmd.message.reply_port = reply;
    cmd.message.length = @sizeOf(Command);
    sys.PutMsg(&base.commands, &cmd.message);
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
    binding.driver_data = null;
}

// --- the device -----------------------------------------------------------

/// The commands the worker answers: the unit's that wait or change
/// it, and the wireless ones.
fn queued(cmd: u16) bool {
    if (radio.isWireless(cmd)) return true;
    return switch (cmd) {
        exec.CMD_READ,
        exec.CMD_WRITE,
        exec.CMD_FLUSH,
        net.S2_CONFIGINTERFACE,
        net.S2_ADDMULTICASTADDRESS,
        net.S2_DELMULTICASTADDRESS,
        net.S2_MULTICAST,
        net.S2_BROADCAST,
        net.S2_TRACKTYPE,
        net.S2_UNTRACKTYPE,
        net.S2_GETTYPESTATS,
        net.S2_GETSPECIALSTATS,
        net.S2_GETGLOBALSTATS,
        net.S2_ONEVENT,
        net.S2_READORPHAN,
        net.S2_ONLINE,
        net.S2_OFFLINE,
        => true,
        else => false,
    };
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const base = _aic.aicBase(dev);
    if (io.unit == null) {
        io.err = exec.IOERR_NOCMD;
        return base.sys_base.ReplyIO(io);
    }
    const req = _aic.sanaReq(io);
    io.err = 0;
    // S2_ONEVENT carries its mask here; every other request is told of a
    // wire error only if there is one.
    if (io.command != net.S2_ONEVENT) req.wire_error = 0;
    switch (io.command) {
        net.S2_DEVICEQUERY => base.net.query(req),
        net.S2_GETSTATIONADDRESS => base.net.stationAddress(req),
        else => if (queued(io.command)) {
            // It will be replied, so it needs a reply port, and it is not
            // quick I/O.
            if (io.message.reply_port == null) {
                io.err = exec.IOERR_NOREPLYPORT;
                io.flags |= exec.IOF_QUICK;
            } else {
                io.flags &= ~exec.IOF_QUICK;
                return base.sys_base.PutMsg(&base.unit.msg_port, &io.message);
            }
        } else {
            io.err = exec.IOERR_NOCMD;
        },
    }
    base.sys_base.ReplyIO(io);
}

/// A request the worker hasn't taken yet, or one waiting in the unit - a
/// read, a write, an event - is taken back and answered as aborted. One
/// being sent, or a scan, can't be stopped.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const base = _aic.aicBase(dev);
    const sys = base.sys_base;
    if (io.unit == null) return -1;
    sys.Disable();
    var it = base.unit.msg_port.msg_list.iterator();
    while (it.next()) |node| {
        const message: *exec.Message = @fieldParentPtr("node", node);
        if (_aic.requestOf(message) != io) continue;
        sys.Remove(node);
        sys.Enable();
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    sys.Enable();
    return if (base.net.abort(_aic.sanaReq(io))) 0 else -1;
}

/// usb.library's open for the class calls has no unit; every other opener
/// gets its record from unit 0, stick or not.
fn openDevice(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const base = _aic.aicBase(dev);
    if (unit_number == usbclass.USBCLASS_UNIT_BIND) {
        dev.open_cnt += 1;
        dev.flags &= ~exec.LIBF_DELEXP;
        io.unit = null;
        return 0;
    }
    if (unit_number != 0 or base.ready == 0) return exec.IOERR_OPENFAIL;
    if (io.message.length != 0 and io.message.length < @sizeOf(net.IOSana2Req)) return exec.IOERR_BADLENGTH;
    const refused = base.net.open(_aic.sanaReq(io), flags, base.utility.?);
    if (refused != 0) return refused;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    base.unit.open_cnt += 1;
    io.unit = &base.unit;
    return 0;
}

fn closeDevice(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const base = _aic.aicBase(dev);
    if (io.unit != null) {
        base.net.close(_aic.sanaReq(io));
        base.unit.open_cnt -= 1;
    }
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: it owns its worker.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// The libraries opened, the unit made - without a stick, so without a
/// carrier - and the worker started; this waits until it is ready.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _aic.aicBase(dev);
    base.sys_base = sys;
    base.seg_list = seg_list;
    sys.InitSemaphore(&base.lock);
    base.usb_base = @ptrCast(sys.OpenLibrary(usb.USBNAME, 1) orelse return null);
    base.dos_base = @ptrCast(sys.OpenLibrary(dos.DOSNAME, 0) orelse return null);
    base.utility = @ptrCast(sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null);
    // PA_IGNORE until the worker has a signal for them: whatever comes in
    // while the device starts is queued, and the worker takes it then.
    for ([_]*exec.MsgPort{ &base.commands, &base.pipes }) |port| {
        port.* = .{ .flags = exec.PA_IGNORE };
        port.msg_list.init(.message);
    }
    base.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    base.unit.msg_port.msg_list.init(.message);
    const factory: [6]u8 = @splat(0);
    base.net.init(sys, base, &factory);
    base.net.setCarrier(false);
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return null;
    defer sys.FreeSignal(signal);
    base.start_signal = signal;
    base.starter = sys.FindTask(null);
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&workerMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(@as([*:0]const u8, DEVICE_NAME)) },
        .{ .tag = dos.NP_StackSize, .data = worker_stack },
        .{ .tag = dos.NP_Priority, .data = @as(usize, @bitCast(@as(isize, worker_pri))) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(base) },
        .{},
    };
    if (base.dos_base.?.CreateNewProc(&tags) == null) {
        base.starter = null;
        return null;
    }
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (base.ready == 0) return null;

    const netif_tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&netif.netifProcess) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(@as([*:0]const u8, "aic8800.device interface")) },
        .{ .tag = dos.NP_StackSize, .data = netif_stack },
        .{ .tag = dos.NP_Priority, .data = @as(usize, @bitCast(@as(isize, netif_pri))) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(base) },
        .{},
    };
    base.starter = sys.FindTask(null);
    if (base.dos_base.?.CreateNewProc(&netif_tags) == null) {
        base.starter = null;
        return null;
    }
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (base.adder == null) return null;
    return dev;
}

fn lvoUSBClassBind(base: *AicBase, binding: *usb.USBBinding) callconv(.c) bool {
    return bind(base, binding);
}
fn lvoUSBClassUnbind(base: *AicBase, binding: *usb.USBBinding) callconv(.c) void {
    unbind(base, binding);
}

comptime {
    const interface = sdk.interface.usbclass;
    if (!exec.libraries.sameSignature(@TypeOf(&lvoUSBClassBind), interface.Fn.USBClassBind) or
        !exec.libraries.sameSignature(@TypeOf(&lvoUSBClassUnbind), interface.Fn.USBClassUnbind))
        @compileError("aic8800.device: a class call does not match the SDK's type");
}

/// The six standard vectors, then the class driver's two.
const vectors = [_]*const anyopaque{
    vec(openDevice),
    vec(closeDevice),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
    vec(lvoUSBClassBind),
    vec(lvoUSBClassUnbind),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(AicBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

const speaks = [_]u32{ devices.DEVIF_SANA2, devices.DEVIF_USBCLASS, 0 };

/// The stick, as its boot ROM and as the Wi-Fi.
const matches = [_]usbclass.USBMatch{
    .{ .fields = usbclass.USBMATCH_VENDOR | usbclass.USBMATCH_PRODUCT, .vendor_id = _aic.VENDOR, .product_id = _aic.PRODUCT_BOOT },
    .{ .fields = usbclass.USBMATCH_VENDOR | usbclass.USBMATCH_PRODUCT, .vendor_id = _aic.VENDOR, .product_id = _aic.PRODUCT_WIFI },
    .{},
};

const labels = [_][*:0]const u8{"Wi-Fi 0"};

export const aic8800_device_tag: usbclass.ResidentUSBClass linksection(".resident") = .{
    .device = .{
        .resident = .{
            .match_tag = @ptrCast(&aic8800_device_tag),
            .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
            .version = DEVICE_VERSION,
            .pri = 0,
            .type = .device,
            .name = DEVICE_NAME,
            .id_string = DEVICE_VERSION_STRING[1..],
            .init = &init_table,
        },
        .speaks = &speaks,
        .units = 1,
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

export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
