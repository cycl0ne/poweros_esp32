// SPDX-License-Identifier: MIT
//! usb/bluetooth.device's worker: a DOS process that owns every bound
//! controller's transfers.
//!
//! **A controller started** (the bind's command): its buffers made or
//! cleared, its chip's setup run where it needs one (mediatek.zig), its
//! two endpoints in read, and the unit offered to bluetooth.library -
//! which opens it, and from then on sends it the packets and reads the
//! controller's.
//!
//! **Packets out**: a command goes on the control endpoint as a class
//! request (0x20, 0, 0, 0), ACL data on the bulk endpoint, one of each
//! out at a time and each in the order it came; a write is answered once
//! its transfer has gone.
//!
//! **Packets in**: the endpoints' transfers are put together into packets
//! (transport.zig) and kept in the ring until a read takes them, oldest
//! first. A ring that is full stops the endpoint until a read makes room.
//!
//! **A controller let go** (the unbind's command): its transfers taken
//! back, every request it holds answered HCIERR_DETACHED, the unit taken
//! from bluetooth.library, the pipes closed. Requests that come after are
//! answered HCIERR_DETACHED where they are sent.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const usb = sdk.usb;
const d = usb.descriptors;
const usbhc = sdk.devices.usbhc;
const hcidev = sdk.devices.hci;
const timer = sdk.devices.timer;
const bluetooth = sdk.bluetooth;
const ExecBase = sdk.interface.exec.ExecBase;
const _bt = @import("_bluetooth.zig");
const transport = @import("transport.zig");
const mediatek = @import("mediatek.zig");
const BtBase = _bt.BtBase;
const Unit = _bt.Unit;

/// Where a MediaTek chip's firmware files are.
const firmware_dir = "DEVS:usb/firmware/mediatek/";
/// Endpoint errors in a row before the controller is given up.
const most_errors = 8;

fn name() [*:0]const u8 {
    return _bt.DEVICE_NAME;
}

// --- the process -----------------------------------------------------------

pub fn workerMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const base: *BtBase = @ptrCast(@alignCast(me.user_data orelse return));
    const signal = sys.AllocSignal(-1);
    if (signal >= 0) {
        base.work_mask = @as(u32, 1) << @intCast(signal);
        sys.Disable();
        for ([_]*exec.MsgPort{ &base.commands, &base.pipes }) |port| listen(port, me, signal);
        for (&base.units) |*unit| listen(&unit.unit.msg_port, me, signal);
        sys.Enable();
        base.timer_port = sys.CreateMsgPort();
        if (base.timer_port) |port| {
            base.timer_io = .{};
            base.timer_io.node.message.reply_port = port;
            base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
            if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.timer_io.node, 0) == 0) base.timer_open = 1;
        }
        base.worker = me;
        base.ready = 1;
    }
    if (base.starter) |starter| {
        base.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
    }
    if (base.ready == 0) return;
    while (true) {
        // Every port looked at again after any work: one signal serves
        // them all.
        var worked = true;
        while (worked) {
            worked = false;
            while (sys.GetMsg(&base.commands)) |message| {
                command(base, @fieldParentPtr("message", message));
                worked = true;
            }
            while (sys.GetMsg(&base.pipes)) |message| {
                replied(base, _bt.requestOf(message));
                worked = true;
            }
            for (&base.units) |*unit| {
                while (sys.GetMsg(&unit.unit.msg_port)) |message| {
                    request(base, unit, _bt.requestOf(message));
                    worked = true;
                }
            }
        }
        _ = sys.Wait(base.work_mask);
    }
}

fn listen(port: *exec.MsgPort, task: *exec.Task, signal: i8) void {
    port.sig_bit = @intCast(signal);
    port.sig_task = task;
    port.flags = exec.PA_SIGNAL;
}

fn command(base: *BtBase, cmd: *_bt.Command) void {
    const unit = &base.units[cmd.unit];
    switch (cmd.kind) {
        .start => start(base, unit),
        .let_go => {
            letGo(base, unit);
            base.sys_base.ReplyMsg(&cmd.message);
        },
    }
}

fn leaving(unit: *Unit) bool {
    return @atomicLoad(u8, &unit.leaving, .acquire) != 0;
}

// --- a controller started ------------------------------------------------------

fn start(base: *BtBase, unit: *Unit) void {
    const sys = base.sys_base;
    if (leaving(unit)) return;
    const buffers = unit.buffers orelse made: {
        const memory = sys.AllocVec(@sizeOf(transport.Buffers), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse {
            exec.kprintf(sys, "%s: no memory for unit %u\n", .{ name(), unit.number });
            return;
        };
        const made: *transport.Buffers = @ptrCast(@alignCast(memory));
        made.events.assembly.packet_type = hcidev.HCI_EVENT_PKT;
        made.acl.assembly.packet_type = hcidev.HCI_ACLDATA_PKT;
        unit.buffers = made;
        break :made made;
    };
    buffers.reset();
    if (unit.vendor == _bt.VENDOR_MEDIATEK and !setUpMediaTek(base, unit)) return;
    if (leaving(unit)) return;
    unit.errors = 0;
    @atomicStore(u8, &unit.ready, 1, .release);
    drain(base, unit, .events);
    drain(base, unit, .acl);
    offer(base, unit);
}

/// The unit offered to bluetooth.library, which is opened for it.
fn offer(base: *BtBase, unit: *Unit) void {
    const sys = base.sys_base;
    if (base.bt_base == null) {
        base.bt_base = @ptrCast(sys.OpenLibrary(bluetooth.BLUETOOTHNAME, 1));
        if (base.bt_base == null) {
            exec.kprintf(sys, "%s: unit %u is ready, but there is no %s\n", .{ name(), unit.number, @as([*:0]const u8, bluetooth.BLUETOOTHNAME) });
            return;
        }
    }
    const result = base.bt_base.?.AddBTController(_bt.OPEN_NAME, unit.number);
    if (result != 0) {
        exec.kprintf(sys, "%s: bluetooth.library did not take unit %u (%ld)\n", .{ name(), unit.number, @as(i64, result) });
        return;
    }
    unit.added = 1;
}

// --- the MediaTek setup -----------------------------------------------------------

/// What mediatek.zig's sequence runs over: the device's control endpoint,
/// waited for, and the worker's timer.
const Link = struct {
    base: *BtBase,
    unit: *Unit,

    fn of(context: *anyopaque) *Link {
        return @ptrCast(@alignCast(context));
    }

    fn control(context: *anyopaque, setup: *const d.SetupPacket, data: ?[*]u8) ?usize {
        const link = of(context);
        var actual: u32 = 0;
        const failure = link.base.ub().DoUSBControl(link.unit.device.?, setup, data, &actual);
        if (failure != 0) return null;
        return actual;
    }

    fn pause(context: *anyopaque, micros: u32) void {
        pauseFor(of(context).base, micros);
    }

    fn isLeaving(context: *anyopaque) bool {
        return leaving(of(context).unit);
    }

    fn port(link: *Link) mediatek.Port {
        return .{ .context = link, .control = control, .pause = pause, .leaving = isLeaving };
    }
};

/// At least `micros` waited: on the timer, or on DOS's ticks without it.
fn pauseFor(base: *BtBase, micros: u32) void {
    const sys = base.sys_base;
    if (base.timer_open == 0) return base.dos_base.?.Delay(@max(micros / 20_000, 1));
    base.timer_io.node.command = timer.TR_ADDREQUEST;
    base.timer_io.time = .{ .secs = micros / 1_000_000, .micro = micros % 1_000_000 };
    _ = sys.DoIO(&base.timer_io.node);
}

/// A file read whole into memory of its own: the caller frees it.
fn readFile(base: *BtBase, path: [*:0]const u8) ?[]u8 {
    const sys = base.sys_base;
    const dl = base.dos_base.?;
    var length: usize = 0;
    const bytes = dl.ReadFile(path, ~@as(usize, 0), exec.MEMF_ANY, &length) orelse {
        exec.kprintf(sys, "%s: no %s\n", .{ name(), path });
        return null;
    };
    if (length == 0) {
        sys.FreeVec(bytes);
        return null;
    }
    return bytes[0..length];
}

fn failed(base: *BtBase, unit: *Unit, comptime what: [:0]const u8, failure: mediatek.Failure) void {
    if (failure == error.Leaving) return;
    exec.kprintf(base.sys_base, "%s: unit %u: " ++ what ++ ": %s\n", .{ name(), unit.number, @as([*:0]const u8, @errorName(failure)) });
}

/// The chip asked which it is, given its firmware and its Bluetooth
/// switched on: false when it could not be.
fn setUpMediaTek(base: *BtBase, unit: *Unit) bool {
    const sys = base.sys_base;
    var link = Link{ .base = base, .unit = unit };
    const port = link.port();
    const chip = mediatek.identify(port) catch |failure| {
        failed(base, unit, "the chip does not say which it is", failure);
        return false;
    };
    _ = mediatek.chipName(&unit.chip, chip);
    if (!mediatek.supported(chip)) {
        exec.kprintf(sys, "%s: unit %u: no setup for the %s\n", .{ name(), unit.number, @as([*:0]const u8, @ptrCast(&unit.chip)) });
        return false;
    }
    var path: [firmware_dir.len + 48]u8 = undefined;
    @memcpy(path[0..firmware_dir.len], firmware_dir);
    const length = mediatek.fileName(path[firmware_dir.len..], chip);
    const file_name = path[firmware_dir.len..][0..length];
    const file = readFile(base, @ptrCast(&path)) orelse return false;
    defer sys.FreeVec(file.ptr);
    const sent = mediatek.load(port, file) catch |failure| {
        failed(base, unit, "the firmware was not taken", failure);
        return false;
    };
    // What HCICMD_QUERY says: the file, and when it was built.
    var at: usize = 0;
    for ([_][]const u8{ file_name, " (", mediatek.buildTime(file), ")" }) |part| {
        for (part) |char| {
            if (at == unit.firmware.len - 1) break;
            unit.firmware[at] = char;
            at += 1;
        }
    }
    unit.firmware[at] = 0;
    if (sent == 0) {
        exec.kprintf(sys, "%s: unit %u: the %s has its firmware already\n", .{ name(), unit.number, @as([*:0]const u8, @ptrCast(&unit.chip)) });
    } else {
        exec.kprintf(sys, "%s: unit %u: the %s given %s, %u sections\n", .{ name(), unit.number, @as([*:0]const u8, @ptrCast(&unit.chip)), @as([*:0]const u8, @ptrCast(&unit.firmware)), sent });
    }
    return true;
}

// --- the opener's requests ---------------------------------------------------------

fn answer(base: *BtBase, io: *exec.IORequest, failure: i8) void {
    io.err = failure;
    base.sys_base.ReplyIO(io);
}

/// A request the worker took from the unit's port.
fn request(base: *BtBase, unit: *Unit, io: *exec.IORequest) void {
    const sys = base.sys_base;
    if (leaving(unit) or @atomicLoad(u8, &unit.ready, .acquire) == 0) return answer(base, io, hcidev.HCIERR_DETACHED);
    io.message.node.type = .message;
    switch (io.command) {
        exec.CMD_READ => {
            sys.Disable();
            sys.AddTail(&unit.reads, &io.message.node);
            sys.Enable();
            deliver(base, unit);
        },
        exec.CMD_WRITE => {
            const req = _bt.hciReq(io);
            const length = req.std.length;
            const fits = switch (req.packet_type) {
                hcidev.HCI_COMMAND_PKT => length >= 3 and length <= 3 + 255,
                hcidev.HCI_ACLDATA_PKT => length >= 4 and length <= transport.MAX_PACKET,
                else => false,
            };
            if (!fits or req.std.data == null) return answer(base, io, hcidev.HCIERR_PACKET);
            sys.Disable();
            sys.AddTail(&unit.writes, &io.message.node);
            sys.Enable();
            sendWrites(base, unit);
        },
        exec.CMD_FLUSH => {
            flushReads(base, unit, exec.IOERR_ABORTED);
            answer(base, io, 0);
        },
        else => answer(base, io, exec.IOERR_NOCMD),
    }
}

/// Every read waiting answered with `failure`.
fn flushReads(base: *BtBase, unit: *Unit, failure: i8) void {
    const sys = base.sys_base;
    while (true) {
        sys.Disable();
        const node = sys.RemHead(&unit.reads);
        sys.Enable();
        const taken = node orelse return;
        const message: *exec.Message = @fieldParentPtr("node", taken);
        answer(base, _bt.requestOf(message), failure);
    }
}

/// The packets waiting handed to the reads waiting, oldest to oldest; a
/// read too short for its packet is answered HCIERR_TOOLONG and the
/// packet kept. Room made in the ring takes the endpoints on.
fn deliver(base: *BtBase, unit: *Unit) void {
    const sys = base.sys_base;
    const buffers = unit.buffers orelse return;
    var dropped = false;
    while (buffers.ring.first()) |slot| {
        sys.Disable();
        const node = sys.RemHead(&unit.reads);
        sys.Enable();
        const taken = node orelse break;
        const message: *exec.Message = @fieldParentPtr("node", taken);
        const io = _bt.requestOf(message);
        const req = _bt.hciReq(io);
        const packet = slot.packet();
        req.packet_type = slot.packet_type;
        req.std.actual = packet.len;
        if (req.std.length < packet.len or req.std.data == null) {
            answer(base, io, hcidev.HCIERR_TOOLONG);
            continue;
        }
        const into: [*]u8 = @ptrCast(req.std.data.?);
        @memcpy(into[0..packet.len], packet);
        answer(base, io, 0);
        buffers.ring.drop();
        dropped = true;
    }
    if (dropped) {
        drain(base, unit, .events);
        drain(base, unit, .acl);
    }
}

// --- packets out ---------------------------------------------------------------------

/// The first command waiting goes on the control endpoint and the first
/// ACL packet on the bulk one, each when its pipe is free.
fn sendWrites(base: *BtBase, unit: *Unit) void {
    const sys = base.sys_base;
    if (leaving(unit)) return;
    var command_io: ?*exec.IORequest = null;
    var acl_io: ?*exec.IORequest = null;
    sys.Disable();
    var it = unit.writes.iterator();
    while (it.next()) |node| {
        const message: *exec.Message = @fieldParentPtr("node", node);
        const io = _bt.requestOf(message);
        const is_command = _bt.hciReq(io).packet_type == hcidev.HCI_COMMAND_PKT;
        if (is_command and unit.command_out == null and command_io == null) {
            command_io = io;
        } else if (!is_command and unit.acl_sending == null and acl_io == null) {
            acl_io = io;
        }
    }
    if (command_io) |io| {
        sys.Remove(&io.message.node);
        unit.command_out = io;
    }
    if (acl_io) |io| {
        sys.Remove(&io.message.node);
        unit.acl_sending = io;
    }
    sys.Enable();
    if (command_io) |io| {
        const req = _bt.hciReq(io);
        const pipe = &unit.control.?.io;
        pipe.setup = .{
            .request_type = d.USB_DIR_OUT | d.USB_TYPE_CLASS | d.USB_RECIP_DEVICE,
            .request = 0,
            .value = 0,
            .index = 0,
            .length = @intCast(req.std.length),
        };
        pipe.std.data = req.std.data;
        pipe.std.length = req.std.length;
        pipe.std.actual = 0;
        pipe.flags = 0;
        sys.SendIO(&pipe.std.req);
    }
    if (acl_io) |io| {
        const req = _bt.hciReq(io);
        const pipe = &unit.acl_out.?.io;
        pipe.std.data = req.std.data;
        pipe.std.length = req.std.length;
        pipe.std.actual = 0;
        pipe.flags = 0;
        sys.SendIO(&pipe.std.req);
    }
}

/// A write's transfer back: the write answered, the next sent.
fn written(base: *BtBase, unit: *Unit, slot: *?*exec.IORequest, pipe: *usb.USBPipe) void {
    const io = slot.* orelse return;
    slot.* = null;
    const failure = pipe.io.std.req.err;
    _bt.hciReq(io).std.actual = pipe.io.std.actual;
    answer(base, io, if (failure == 0) 0 else if (leaving(unit)) hcidev.HCIERR_DETACHED else hcidev.HCIERR_SEND);
    sendWrites(base, unit);
}

// --- packets in ----------------------------------------------------------------------

const Endpoint = enum { events, acl };

fn inOf(buffers: *transport.Buffers, endpoint: Endpoint) *transport.In {
    return switch (endpoint) {
        .events => &buffers.events,
        .acl => &buffers.acl,
    };
}

fn pipeOf(unit: *Unit, endpoint: Endpoint) *usb.USBPipe {
    return switch (endpoint) {
        .events => unit.events_in.?,
        .acl => unit.acl_in.?,
    };
}

/// The room an endpoint's transfer fills: the events' a packet of the
/// endpoint's at a time.
fn roomOf(unit: *Unit, buffers: *transport.Buffers, endpoint: Endpoint) []u8 {
    return switch (endpoint) {
        .events => buffers.event_room[0..@min(@max(pipeOf(unit, .events).io.max_packet, 1), transport.EVENT_SIZE)],
        .acl => &buffers.bulk_room,
    };
}

/// What an endpoint's last transfer brought taken into packets and the
/// ring, as far as the ring has room; once all of it is taken, the
/// endpoint asked again.
fn drain(base: *BtBase, unit: *Unit, endpoint: Endpoint) void {
    const buffers = unit.buffers orelse return;
    const in = inOf(buffers, endpoint);
    if (in.out or leaving(unit)) return;
    const room = roomOf(unit, buffers, endpoint);
    while (true) {
        if (in.assembly.whole) {
            if (!buffers.ring.put(in.assembly.packet_type, in.assembly.packet())) return;
            in.assembly.clear();
        }
        if (in.offset >= in.length) break;
        in.offset += transport.take(&in.assembly, room[in.offset..in.length]);
    }
    const io = &pipeOf(unit, endpoint).io;
    io.std.data = room.ptr;
    io.std.length = room.len;
    io.std.actual = 0;
    io.flags = 0;
    in.length = 0;
    in.offset = 0;
    in.out = true;
    base.sys_base.SendIO(&io.std.req);
}

/// An endpoint's transfer back.
fn came(base: *BtBase, unit: *Unit, endpoint: Endpoint) void {
    const buffers = unit.buffers orelse return;
    const in = inOf(buffers, endpoint);
    const pipe = pipeOf(unit, endpoint);
    in.out = false;
    if (leaving(unit)) return;
    const failure = pipe.io.std.req.err;
    if (failure != 0) {
        if (failure == exec.IOERR_ABORTED or failure == usbhc.UHIOERR_DETACHED) return;
        unit.errors += 1;
        if (unit.errors > most_errors) {
            exec.kprintf(base.sys_base, "%s: unit %u: its endpoint %x keeps failing (%ld)\n", .{ name(), unit.number, @as(u32, pipe.io.endpoint), @as(i64, failure) });
            return;
        }
        if (failure == usbhc.UHIOERR_STALL) _ = base.ub().ClearUSBStall(pipe);
        return drain(base, unit, endpoint);
    }
    unit.errors = 0;
    in.length = @min(pipe.io.std.actual, roomOf(unit, buffers, endpoint).len);
    in.offset = 0;
    drain(base, unit, endpoint);
    deliver(base, unit);
}

/// A pipe's request back: whose it is.
fn replied(base: *BtBase, io: *exec.IORequest) void {
    for (&base.units) |*unit| {
        if (unit.events_in) |pipe| if (io == &pipe.io.std.req) return came(base, unit, .events);
        if (unit.acl_in) |pipe| if (io == &pipe.io.std.req) return came(base, unit, .acl);
        if (unit.control) |pipe| if (io == &pipe.io.std.req) return written(base, unit, &unit.command_out, pipe);
        if (unit.acl_out) |pipe| if (io == &pipe.io.std.req) return written(base, unit, &unit.acl_sending, pipe);
    }
}

// --- a controller let go ----------------------------------------------------------------

/// A pipe's request taken back if it is out.
fn takeBack(base: *BtBase, pipe: ?*usb.USBPipe, out: bool) void {
    const sys = base.sys_base;
    const taken = pipe orelse return;
    if (!out) return;
    _ = sys.AbortIO(&taken.io.std.req);
    _ = sys.WaitIO(&taken.io.std.req);
}

fn letGo(base: *BtBase, unit: *Unit) void {
    const sys = base.sys_base;
    const ub = base.ub();
    @atomicStore(u8, &unit.leaving, 1, .release);
    @atomicStore(u8, &unit.ready, 0, .release);
    if (unit.buffers) |buffers| {
        takeBack(base, unit.events_in, buffers.events.out);
        takeBack(base, unit.acl_in, buffers.acl.out);
        buffers.events.out = false;
        buffers.acl.out = false;
    }
    takeBack(base, unit.control, unit.command_out != null);
    takeBack(base, unit.acl_out, unit.acl_sending != null);
    // Every request it holds answered, so that the stack's close waits for
    // none of them.
    for ([_]*?*exec.IORequest{ &unit.command_out, &unit.acl_sending }) |slot| {
        if (slot.*) |io| answer(base, io, hcidev.HCIERR_DETACHED);
        slot.* = null;
    }
    flushReads(base, unit, hcidev.HCIERR_DETACHED);
    while (true) {
        sys.Disable();
        const node = sys.RemHead(&unit.writes);
        sys.Enable();
        const taken = node orelse break;
        const message: *exec.Message = @fieldParentPtr("node", taken);
        answer(base, _bt.requestOf(message), hcidev.HCIERR_DETACHED);
    }
    while (sys.GetMsg(&unit.unit.msg_port)) |message| answer(base, _bt.requestOf(message), hcidev.HCIERR_DETACHED);
    if (unit.added != 0) {
        unit.added = 0;
        base.bt_base.?.RemBTController(_bt.OPEN_NAME, unit.number);
    }
    ub.CloseUSBPipe(unit.control);
    ub.CloseUSBPipe(unit.events_in);
    ub.CloseUSBPipe(unit.acl_in);
    ub.CloseUSBPipe(unit.acl_out);
    sys.ObtainSemaphore(&base.lock);
    unit.control = null;
    unit.events_in = null;
    unit.acl_in = null;
    unit.acl_out = null;
    unit.device = null;
    unit.bound = 0;
    sys.ReleaseSemaphore(&base.lock);
}
