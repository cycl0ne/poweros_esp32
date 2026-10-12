// SPDX-License-Identifier: MIT
//! usb/ecm.device's own state: the base, a link per unit, and the link's
//! side of the unit (sdk/devices/network/unit.zig) - the adapter under
//! it, its packet filter, and the frames going in and out.
//!
//! **An adapter on a link** is set by its bind (the bus's process) and
//! taken up by the task: `bound` says the link is spoken for, `attached`
//! that the task drives it. Everything past the bind runs on the task -
//! the reads, the writes, the notifications, the filter - so no lock
//! guards an attached adapter's pipes; `leaving`, set by the unbind,
//! keeps the task from sending anything more before it lets go.
//!
//! **Frames in**: one bulk read always out while the unit runs, into a
//! buffer the largest frame fits; it ends at the frame's last, short
//! packet. **Frames out**: one bulk write at a time, of a frame the unit
//! builds; it is padded to Ethernet's shortest, and ended by a
//! zero-length packet when it fills its last.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const ethernet = net.ethernet;
const timer = sdk.devices.timer;
const usb = sdk.usb;
const d = usb.descriptors;
const usbhc = sdk.devices.usbhc;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UsbBase = sdk.interface.usb.UsbBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TimerBase = sdk.interface.timer.TimerBase;
const unit_file = net.unit;
const cdc = @import("cdc.zig");

pub const DEVICE_NAME = "ecm.device";

/// The adapters there can be at once.
pub const max_units = 2;
/// A frame's buffer: the largest frame, rounded up to whole packets.
pub const frame_buffer = 1536;
/// Ethernet's shortest frame without its checksum.
const frame_min = 60;
/// A notification's header and the most data one carries here.
const notify_bytes = 16;

pub const Unit = unit_file.Unit(Link);

/// A command from a bind or an unbind to the task.
pub const Command = extern struct {
    message: exec.Message = .{},
    kind: Kind = .start,
    link: ?*Link = null,

    pub const Kind = enum(u32) { start, let_go };
};

/// One unit: the adapter under it and the requests' side above.
pub const Link = extern struct {
    /// The exec unit the openers' requests name; its port is the task's
    /// work queue for this link.
    unit: exec.Unit = .{},
    base: ?*EcmBase = null,
    /// The adapter: its device, its pipes, its address, and the control
    /// interface it was bound on. Set by the bind.
    device: ?*usb.USBDevice = null,
    bulk_in: ?*usb.USBPipe = null,
    bulk_out: ?*usb.USBPipe = null,
    notify: ?*usb.USBPipe = null,
    address: ethernet.Address = @splat(0),
    control_number: u8 = 0,
    /// Spoken for by a bind (under the base's `lock`); driven by the task;
    /// being let go of (no transfer is sent after it).
    bound: u8 = 0,
    attached: u8 = 0,
    leaving: u8 = 0,
    /// The read, the notification read are out; the unit runs.
    reading: u8 = 0,
    notifying: u8 = 0,
    running: u8 = 0,
    /// The packet filter the unit wants, and the one the adapter has (0:
    /// none told it yet).
    filter_wanted: u16 = cdc.PACKET_DIRECTED | cdc.PACKET_BROADCAST,
    filter_set: u16 = 0,
    /// The unit's interface has been asked for (netif.zig): at its first
    /// adapter, once.
    asked: u8 = 0,
    /// The write being sent.
    writing: ?*net.IOSana2Req = null,
    start: Command = .{},
    /// What asks the DOS process for the unit's interface.
    tell: exec.Message = .{},
    in_buffer: [frame_buffer]u8 = @splat(0),
    out_buffer: [frame_buffer]u8 = @splat(0),
    notify_buffer: [notify_bytes]u8 = @splat(0),
    /// The requests' side.
    net: Unit,

    // --- the unit's link --------------------------------------------------

    /// What a full-speed bus carries, the most an adapter on it moves.
    pub const bps: u64 = 12_000_000;

    /// The adapter keeps its own address: CDC-ECM has no request to give
    /// it another, and it passes up the frames sent to its own.
    pub fn setStation(link: *Link, address: *const ethernet.Address) void {
        _ = link;
        _ = address;
    }

    /// The filter noted, and the task told: an opener asking for every
    /// frame changes it on its own task, and only the task talks to the
    /// adapter.
    pub fn setFilter(link: *Link, groups: []const unit_file.Group, promiscuous: bool) void {
        var joined = false;
        for (groups) |group| {
            if (group.users != 0) joined = true;
        }
        @atomicStore(u16, &link.filter_wanted, cdc.packetFilter(joined, promiscuous), .release);
        const base = link.base orelse return;
        base.sys_base.Signal(&base.task, base.work_mask);
    }

    /// The first read out, or the read taken back.
    pub fn setRunning(link: *Link, on: bool) void {
        if (!on) {
            link.running = 0;
            link.takeBack(link.bulk_in, &link.reading);
            return;
        }
        if (link.attached == 0) return;
        link.running = 1;
        link.read();
    }

    /// The next write waiting, sent - one at a time; its answer sends the
    /// one after.
    pub fn startWrites(link: *Link) void {
        if (link.writing != null or link.running == 0 or link.attached == 0) return;
        if (@atomicLoad(u8, &link.leaving, .acquire) != 0) return;
        const pipe = link.bulk_out.?;
        while (link.net.nextWrite()) |req| {
            var length = link.net.buildFrame(req, &link.out_buffer);
            if (length == 0) continue;
            if (length < frame_min) {
                @memset(link.out_buffer[length..frame_min], 0);
                length = frame_min;
            }
            link.writing = req;
            const io = &pipe.io;
            io.std.data = &link.out_buffer;
            io.std.length = length;
            io.std.actual = 0;
            io.flags = usbhc.UHF_ZERO_PACKET;
            io.nak_timeout = 0;
            link.base.?.sys_base.SendIO(&io.std.req);
            return;
        }
    }

    pub fn now(link: *Link) timer.TimeVal {
        var time: timer.TimeVal = .{};
        const base = link.base.?;
        if (base.timer_open != 0) {
            const timer_base: *TimerBase = @ptrCast(@alignCast(base.timer_io.node.device.?));
            timer_base.GetSysTime(&time);
        }
        return time;
    }

    // --- the task's side ---------------------------------------------------

    /// The adapter the bind set taken up: its address the unit's, its
    /// notifications read - or, with no endpoint for them, its carrier
    /// up at once - and, for the unit's first, its interface asked for.
    pub fn attach(link: *Link) void {
        const base = link.base.?;
        if (link.asked == 0) if (base.adder) |port| {
            link.asked = 1;
            link.tell = .{ .length = @sizeOf(exec.Message) };
            base.sys_base.PutMsg(port, &link.tell);
        };
        // A unit given no address of its own runs with the adapter's.
        const own = sameAddress(&link.net.station, &link.net.factory);
        link.net.factory = link.address;
        if (own) link.net.station = link.address;
        link.filter_set = 0;
        link.attached = 1;
        link.refilter();
        if (link.notify == null) return link.net.setCarrier(true);
        link.notifyRead();
    }

    /// The adapter let go of: everything of it taken back, the write being
    /// sent failed, the unit off line, the pipes closed and the link free.
    pub fn letGo(link: *Link, ub: *UsbBase) void {
        const base = link.base.?;
        const sys = base.sys_base;
        link.attached = 0;
        link.takeBack(link.notify, &link.notifying);
        if (link.writing) |req| {
            _ = sys.AbortIO(&link.bulk_out.?.io.std.req);
            _ = sys.WaitIO(&link.bulk_out.?.io.std.req);
            link.writing = null;
            link.net.written(req, false);
        }
        link.net.setCarrier(false);
        link.setRunning(false);
        ub.CloseUSBPipe(link.bulk_in);
        ub.CloseUSBPipe(link.bulk_out);
        ub.CloseUSBPipe(link.notify);
        link.bulk_in = null;
        link.bulk_out = null;
        link.notify = null;
        link.device = null;
        sys.ObtainSemaphore(&base.lock);
        link.bound = 0;
        sys.ReleaseSemaphore(&base.lock);
    }

    /// A pipe's request out taken back and waited for.
    fn takeBack(link: *Link, pipe: ?*usb.USBPipe, out: *u8) void {
        if (out.* == 0) return;
        const sys = link.base.?.sys_base;
        _ = sys.AbortIO(&pipe.?.io.std.req);
        _ = sys.WaitIO(&pipe.?.io.std.req);
        out.* = 0;
    }

    /// A pipe's answer: a frame to the unit, a write answered, a
    /// notification read - and the next one sent. False if it is none of
    /// this link's.
    pub fn replied(link: *Link, ub: *UsbBase, msg: *exec.Message) bool {
        if (link.attached == 0) return false;
        if (msg == &link.bulk_in.?.io.std.req.message) {
            link.reading = 0;
            const io = &link.bulk_in.?.io;
            switch (io.std.req.err) {
                0 => if (io.std.actual > 0) link.net.receive(link.in_buffer[0..@min(io.std.actual, frame_buffer)]),
                usbhc.UHIOERR_STALL => _ = ub.ClearUSBStall(link.bulk_in.?),
                else => {},
            }
            if (!gone(io.std.req.err) and link.running != 0) link.read();
            return true;
        }
        if (msg == &link.bulk_out.?.io.std.req.message) {
            const io = &link.bulk_out.?.io;
            if (io.std.req.err == usbhc.UHIOERR_STALL) _ = ub.ClearUSBStall(link.bulk_out.?);
            if (link.writing) |req| {
                link.writing = null;
                link.net.written(req, io.std.req.err == 0);
            }
            link.startWrites();
            return true;
        }
        const pipe = link.notify orelse return false;
        if (msg != &pipe.io.std.req.message) return false;
        link.notifying = 0;
        if (pipe.io.std.req.err == 0) {
            const report = link.notify_buffer[0..@min(pipe.io.std.actual, notify_bytes)];
            if (cdc.connection(report)) |up| link.net.setCarrier(up);
        }
        if (!gone(pipe.io.std.req.err)) link.notifyRead();
        return true;
    }

    fn gone(err: i8) bool {
        return err == usbhc.UHIOERR_DETACHED or err == exec.IOERR_ABORTED;
    }

    /// The next frame read.
    fn read(link: *Link) void {
        if (link.reading != 0 or @atomicLoad(u8, &link.leaving, .acquire) != 0) return;
        const io = &link.bulk_in.?.io;
        io.std.data = &link.in_buffer;
        io.std.length = frame_buffer;
        io.std.actual = 0;
        io.flags = 0;
        io.nak_timeout = 0;
        link.reading = 1;
        link.base.?.sys_base.SendIO(&io.std.req);
    }

    /// The next notification asked for.
    fn notifyRead(link: *Link) void {
        if (link.notifying != 0 or @atomicLoad(u8, &link.leaving, .acquire) != 0) return;
        const io = &link.notify.?.io;
        io.std.data = &link.notify_buffer;
        io.std.length = @min(@max(io.max_packet, 1), notify_bytes);
        io.std.actual = 0;
        link.notifying = 1;
        link.base.?.sys_base.SendIO(&io.std.req);
    }

    /// The packet filter the unit wants told the adapter, if it has
    /// another.
    pub fn refilter(link: *Link) void {
        if (link.attached == 0 or @atomicLoad(u8, &link.leaving, .acquire) != 0) return;
        const wanted = @atomicLoad(u16, &link.filter_wanted, .acquire);
        if (wanted == link.filter_set) return;
        const base = link.base.?;
        const setup = usb.SetupPacket{
            .request_type = d.USB_DIR_OUT | d.USB_TYPE_CLASS | d.USB_RECIP_INTERFACE,
            .request = d.CDC_REQ_SET_ETHERNET_PACKET_FILTER,
            .value = wanted,
            .index = link.control_number,
            .length = 0,
        };
        // An adapter that refuses it keeps its own filter: directed and
        // broadcast frames at least, which is what a unit needs.
        _ = base.ub().DoUSBControl(link.device.?, &setup, null, null);
        link.filter_set = wanted;
    }
};

fn sameAddress(a: *const ethernet.Address, b: *const ethernet.Address) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// The device's base: a link per unit, and the task that runs them all.
pub const EcmBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// What the device was loaded from, for its expunge to hand back.
    seg_list: ?*anyopaque = null,
    usb_base: ?*UsbBase = null,
    /// utility.library, for the tag lists OpenDevice is handed.
    utility: ?*UtilityBase = null,
    /// dos.library, and the DOS process that brings up the units'
    /// interfaces (netif.zig), by its port.
    dos_base: ?*DosBase = null,
    adder: ?*exec.MsgPort = null,
    /// The task every request, every pipe's answer and every bind runs
    /// on: the openers' copy calls run only there.
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The one signal every port raises for the task.
    work_mask: u32 = 0,
    /// The pipes' answers, and the binds' commands.
    pipes: exec.MsgPort = .{},
    commands: exec.MsgPort = .{},
    /// For the system time a unit goes online at.
    timer_io: timer.TimeRequest = .{},
    timer_open: u8 = 0,
    /// The task is ready for requests.
    ready: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    /// The task that started this one, and the signal it waits on until
    /// the task takes requests.
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad2: [3]u8 = .{ 0, 0, 0 },
    /// Which links are bound: taken by the binds and the task.
    lock: exec.SignalSemaphore = .{},
    links: [max_units]Link,

    pub fn ub(base: *EcmBase) *UsbBase {
        return base.usb_base.?;
    }

    pub fn unitNumber(base: *EcmBase, link: *const Link) u32 {
        for (&base.links, 0..) |*each, number| if (each == link) return @intCast(number);
        return 0;
    }
};

pub fn ecmBase(dev: *exec.Device) *EcmBase {
    return @fieldParentPtr("dev", dev);
}

/// The link of the request's unit.
pub fn linkOf(io: *exec.IORequest) *Link {
    return @fieldParentPtr("unit", io.unit.?);
}

pub fn sanaReq(io: *exec.IORequest) *net.IOSana2Req {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a message on a port belongs to.
pub fn requestOf(msg: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", msg);
}
