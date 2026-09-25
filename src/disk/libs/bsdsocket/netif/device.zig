// SPDX-License-Identifier: MIT
//! An interface on a network device (sdk/devices/network.zig): the
//! device opened with the stack's copy calls, reads kept outstanding
//! for IPv4 and for ARP, and writes sent as the device takes them.
//!
//! **Frames go straight to the device and back.** Every read carries an
//! empty frame as its data; the device's task copies a packet into it
//! (`copyIn`) and answers the read, and the stack task hands the frame up
//! and sends the read again with a new one. A write carries the frame of
//! the packet, which the device copies out (`copyOut`) on its task; the
//! frame is given back when the write is answered. So a received packet
//! is copied once, and the stack never touches the device's memory.
//!
//! **A bounded number in flight.** `reads` reads and `writes` writes per
//! interface, set from the link's speed; a packet that finds every write
//! in flight waits in the interface's queue, up to `queue_max`, and
//! beyond that is refused with `ENOBUFS`. A read that finds no frame free
//! waits idle until one is.
//!
//! All the answers come to the stack task's port, where `complete` takes
//! them under the lock.

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const net = sdk.devices.network;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _frame = @import("../frame/_frame.zig");
const Frame = _frame.Frame;
const _netif = @import("_netif.zig");
const Interface = _netif.Interface;
const _ip = @import("../ip/_ip.zig");
const _arp = @import("../arp/_arp.zig");

/// The most bytes a read takes: a frame's buffer past its headroom.
const read_bytes: u32 = _frame.buffer_bytes - _frame.headroom;
/// Packets that may wait for a write.
pub const queue_max = 64;
/// Reads and writes at the most, whatever the link.
pub const reads_max = 32;
pub const writes_max = 16;

pub const Kind = enum(u8) { read_ip, read_arp, write };

/// One request to the device, and what it carries.
pub const Request = extern struct {
    req: net.IOSana2Req = .{},
    kind: Kind = .write,
    pad: [3]u8 = .{ 0, 0, 0 },
    device: ?*Device = null,
    frame: ?*Frame = null,
};

pub const Device = extern struct {
    interface: *Interface,
    /// The request the device was opened with: the device, the unit and
    /// the stack's buffer cookie every other request copies.
    opened: net.IOSana2Req = .{},
    requests: [reads_max + writes_max]Request = @splat(.{}),
    reads: u32 = 0,
    writes: u32 = 0,
    /// The writes not in flight, and the reads waiting for a frame.
    idle_writes: exec.List = .{},
    idle_reads: exec.List = .{},
    /// Packets waiting for a write.
    queue: exec.List = .{},
    queued: u32 = 0,
    /// Requests the device has and has not answered yet.
    in_flight: u32 = 0,
    /// Being taken down: nothing more is sent.
    going: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// What the device said its link is: the most bytes of one packet,
    /// its speed, and the Ethernet address it runs with.
    mtu: u32 = 0,
    bps_low: u32 = 0,
    bps_high: u32 = 0,
    station: [6]u8 = @splat(0),
    pad2: [2]u8 = .{ 0, 0 },
    /// The device's name and unit, as the interface was added with them.
    name: [64]u8 = @splat(0),
    unit: u32 = 0,

    pub fn bps(link: *const Device) u64 {
        return @as(u64, link.bps_high) << 32 | link.bps_low;
    }
};

// --- the copy calls -------------------------------------------------------------

/// A received packet into the stack's frame; on the device's task.
fn copyIn(to: ?*anyopaque, from: ?*const anyopaque, length: u32) callconv(.c) bool {
    const frame: *Frame = @ptrCast(@alignCast(to orelse return false));
    const bytes: [*]const u8 = @ptrCast(from orelse return false);
    if (length > read_bytes) return false;
    frame.start = _frame.headroom;
    frame.length = length;
    @memcpy(frame.buffer[_frame.headroom..][0..length], bytes[0..length]);
    return true;
}

/// A packet to send out of the stack's frame; on the device's task.
fn copyOut(to: ?*anyopaque, from: ?*const anyopaque, length: u32) callconv(.c) bool {
    const bytes: [*]u8 = @ptrCast(to orelse return false);
    const frame: *Frame = @ptrCast(@alignCast(@constCast(from orelse return false)));
    if (length > frame.length) return false;
    @memcpy(bytes[0..length], frame.bytes()[0..length]);
    return true;
}

/// The tag list the device is opened with.
pub fn bufferTags() [3]sdk.utility.TagItem {
    return .{
        .{ .tag = net.S2_CopyToBuff, .data = @intFromPtr(&copyIn) },
        .{ .tag = net.S2_CopyFromBuff, .data = @intFromPtr(&copyOut) },
        .{},
    };
}

// --- in flight ----------------------------------------------------------------

fn requestOf(node: *exec.Node) *Request {
    const message: *exec.Message = @fieldParentPtr("node", node);
    const io: *exec.IORequest = @fieldParentPtr("message", message);
    const req: *net.IOSana2Req = @alignCast(@fieldParentPtr("req", io));
    return @fieldParentPtr("req", req);
}

/// The requests made ready once the device is open: each a copy of the
/// opened one answering to `port`, the reads sent, the writes idle.
/// Under the lock.
pub fn start(stack: *StackBase, device: *Device, port: *exec.MsgPort) void {
    const sys = stack.sys_base;
    device.idle_writes.init(.unknown);
    device.idle_reads.init(.unknown);
    device.queue.init(.unknown);
    for (device.requests[0 .. device.reads + device.writes], 0..) |*request, index| {
        request.* = .{ .req = device.opened, .device = device };
        request.req.req.message.reply_port = port;
        request.req.req.message.length = @sizeOf(net.IOSana2Req);
        if (index < device.reads) {
            // A quarter of the reads for ARP, the rest for IPv4.
            request.kind = if (index % 4 == 3) .read_arp else .read_ip;
            read(stack, request);
        } else {
            request.kind = .write;
            sys.AddTail(&device.idle_writes, &request.req.req.message.node);
        }
    }
}

/// `request` sent to read the next packet of its type, with a new frame;
/// idle if there is none.
fn read(stack: *StackBase, request: *Request) void {
    const sys = stack.sys_base;
    const device = request.device.?;
    const frame = stack.frames.take(sys) orelse {
        sys.AddTail(&device.idle_reads, &request.req.req.message.node);
        return;
    };
    request.frame = frame;
    const req = &request.req;
    req.req.command = exec.CMD_READ;
    req.req.flags = 0;
    req.packet_type = if (request.kind == .read_arp) _arp.ethertype else _ip.ethertype;
    req.data = frame;
    req.data_length = read_bytes;
    device.in_flight += 1;
    sys.SendIO(&req.req);
}

/// The reads that waited for a frame, sent now that frames may be free.
pub fn retryReads(stack: *StackBase, device: *Device) void {
    const sys = stack.sys_base;
    if (device.going != 0) return;
    while (sys.RemHead(&device.idle_reads)) |node| {
        const request = requestOf(node);
        read(stack, request);
        if (request.frame == null) return;
    }
}

/// The interface's link: `frame` sent to the station `to`, or queued for
/// the next write the device answers.
pub fn transmit(stack: *StackBase, interface: *Interface, frame: *Frame, to: *const [6]u8, packet_type: u16) i32 {
    const sys = stack.sys_base;
    const device: *Device = @ptrCast(@alignCast(interface.device.?));
    if (device.going != 0) {
        stack.frames.give(sys, frame);
        return bsd.ENETDOWN;
    }
    frame.link_address = to.*;
    frame.link_type = packet_type;
    if (sys.RemHead(&device.idle_writes)) |node| {
        write(stack, requestOf(node), frame);
        return 0;
    }
    if (device.queued == queue_max) {
        interface.dropped += 1;
        stack.frames.give(sys, frame);
        return bsd.ENOBUFS;
    }
    sys.AddTail(&device.queue, &frame.node);
    device.queued += 1;
    return 0;
}

fn write(stack: *StackBase, request: *Request, frame: *Frame) void {
    const device = request.device.?;
    request.frame = frame;
    const req = &request.req;
    const broadcast = for (frame.link_address) |octet| {
        if (octet != 0xFF) break false;
    } else true;
    req.req.command = if (broadcast) net.S2_BROADCAST else exec.CMD_WRITE;
    req.req.flags = 0;
    req.dst_addr = @splat(0);
    req.dst_addr[0..6].* = frame.link_address;
    req.packet_type = frame.link_type;
    req.data = frame;
    req.data_length = frame.length;
    device.in_flight += 1;
    stack.sys_base.SendIO(&req.req);
}

/// A request the device answered, on the stack task, under the lock.
pub fn complete(stack: *StackBase, node: *exec.Node, now: u64) void {
    const sys = stack.sys_base;
    const request = requestOf(node);
    const device = request.device.?;
    const interface = device.interface;
    device.in_flight -= 1;
    const frame = request.frame.?;
    request.frame = null;
    const req = &request.req;
    switch (request.kind) {
        .read_ip, .read_arp => {
            if (req.req.err != 0 or device.going != 0) {
                stack.frames.give(sys, frame);
            } else {
                interface.received += 1;
                if (request.kind == .read_arp) {
                    _arp.input(stack, interface, frame, now);
                } else {
                    const packet = frame.bytes();
                    if (packet.len >= _ip.header_bytes) {
                        _arp.heard(stack, interface, _ip.get32(packet, 12), req.src_addr[0..6]);
                    }
                    _ip.input(stack, interface, frame);
                }
            }
            if (device.going != 0) return;
            read(stack, request);
        },
        .write => {
            if (req.req.err != 0) interface.dropped += 1;
            stack.frames.give(sys, frame);
            if (device.going != 0) return;
            if (sys.RemHead(&device.queue)) |waiting| {
                device.queued -= 1;
                write(stack, request, @fieldParentPtr("node", waiting));
            } else {
                sys.AddTail(&device.idle_writes, &request.req.req.message.node);
            }
        },
    }
}

/// Every request still in flight taken back, on the stack task, without
/// the lock: each is aborted and waited for, and its frame handed back
/// under the lock. What waited in the queue goes too.
pub fn drain(stack: *StackBase, device: *Device) void {
    const sys = stack.sys_base;
    for (device.requests[0 .. device.reads + device.writes]) |*request| {
        if (request.frame == null) continue;
        _ = sys.AbortIO(&request.req.req);
        _ = sys.WaitIO(&request.req.req);
    }
    const held = @import("../lock/_lock.zig").take(stack);
    defer @import("../lock/_lock.zig").give(stack, held);
    for (device.requests[0 .. device.reads + device.writes]) |*request| {
        if (request.frame) |frame| stack.frames.give(sys, frame);
        request.frame = null;
    }
    while (sys.RemHead(&device.queue)) |node| stack.frames.give(sys, @fieldParentPtr("node", node));
    device.queued = 0;
    device.in_flight = 0;
}
