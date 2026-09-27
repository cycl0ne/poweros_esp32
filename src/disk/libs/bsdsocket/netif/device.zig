// SPDX-License-Identifier: MIT
//! An interface on a network device (sdk/devices/network.zig): the
//! device opened with the stack's copy calls, reads kept outstanding
//! for IPv4, for ARP and for IPv6, and writes sent as the device takes
//! them.
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
//! **On and off the link.** One S2_ONEVENT is kept waiting on the device
//! for the state the link is not in, so a link that goes away or comes
//! back - by ConfigureInterfaceTagList's IFA_State or by itself - is
//! seen. While it is off, the interface is down: nothing is sent, and a
//! read the device answers with S2ERR_OUTOFSERVICE waits idle instead of
//! going back at once. When it comes back the reads go out again and DHCP
//! renews its lease.
//!
//! **Groups.** The Ethernet groups the interface's IPv6 listens on - all
//! nodes, and each address's solicited-node group - are joined on the
//! device with S2_ADDMULTICASTADDRESS and left with
//! S2_DELMULTICASTADDRESS, one request at a time: `join` and `leave`
//! count the users of each group, and whenever the device's membership
//! differs from what they ask for, the one control request goes out to
//! make one group right, and its answer sends the next.
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
const _ip6 = @import("../ip6/_ip6.zig");

/// The most bytes a read takes: a frame's buffer past its headroom.
const read_bytes: u32 = _frame.buffer_bytes - _frame.headroom;
/// Packets that may wait for a write.
pub const queue_max = 64;
/// Reads and writes at the most, whatever the link.
pub const reads_max = 32;
pub const writes_max = 16;

pub const Kind = enum(u8) { read_ip, read_arp, read_ip6, write, event, control };

/// The Ethernet groups one interface can be in.
pub const groups_max = 8;

/// A group: how many ask for it, and whether the device has it.
pub const Group = extern struct {
    station: [6]u8 = @splat(0),
    users: u8 = 0,
    joined: u8 = 0,
};

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
    /// The device is off its link; the S2_ONEVENT is out.
    offline: u8 = 0,
    event_armed: u8 = 0,
    pad: u8 = 0,
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
    /// The S2_ONEVENT that waits for the link to change.
    event: Request = .{},
    /// The groups asked for, and the request that joins and leaves them;
    /// the group it is out for.
    groups: [groups_max]Group = @splat(.{}),
    control: Request = .{},
    control_group: ?*Group = null,

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
            // A quarter of the reads for ARP, a quarter for IPv6 when the
            // interface speaks it, the rest for IPv4.
            request.kind = if (index % 4 == 3) .read_arp else if (index % 4 == 1 and device.interface.ip6.enabled != 0) .read_ip6 else .read_ip;
            read(stack, request);
        } else {
            request.kind = .write;
            sys.AddTail(&device.idle_writes, &request.req.req.message.node);
        }
    }
    device.event = .{ .req = device.opened, .kind = .event, .device = device };
    device.event.req.req.message.reply_port = port;
    device.event.req.req.message.length = @sizeOf(net.IOSana2Req);
    device.control = .{ .req = device.opened, .kind = .control, .device = device };
    device.control.req.req.message.reply_port = port;
    device.control.req.req.message.length = @sizeOf(net.IOSana2Req);
    watch(stack, device);
    syncGroups(stack, device);
}

// --- groups ----------------------------------------------------------------------

/// One more user of the group at `station`. Under the lock.
pub fn join(stack: *StackBase, device: *Device, station: [6]u8) void {
    const group = for (&device.groups) |*group| {
        if ((group.users != 0 or group.joined != 0) and eqlStation(group.station, station)) break group;
    } else for (&device.groups) |*group| {
        if (group.users == 0 and group.joined == 0) {
            group.* = .{ .station = station };
            break group;
        }
    } else return;
    group.users +|= 1;
    syncGroups(stack, device);
}

/// One user fewer of the group at `station`. Under the lock.
pub fn leave(stack: *StackBase, device: *Device, station: [6]u8) void {
    for (&device.groups) |*group| {
        if (group.users != 0 and eqlStation(group.station, station)) {
            group.users -= 1;
            break;
        }
    }
    syncGroups(stack, device);
}

fn eqlStation(a: [6]u8, b: [6]u8) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// The control request sent for the first group whose membership on the
/// device is not what its users ask, unless it is out already.
fn syncGroups(stack: *StackBase, device: *Device) void {
    if (device.control_group != null or device.going != 0 or device.control.device == null) return;
    const group = for (&device.groups) |*group| {
        if ((group.users != 0) != (group.joined != 0)) break group;
    } else return;
    device.control_group = group;
    const req = &device.control.req;
    req.req.command = if (group.users != 0) net.S2_ADDMULTICASTADDRESS else net.S2_DELMULTICASTADDRESS;
    req.req.flags = 0;
    req.src_addr = @splat(0);
    req.src_addr[0..6].* = group.station;
    device.in_flight += 1;
    stack.sys_base.SendIO(&req.req);
}

/// The S2_ONEVENT sent, for the state the link is not in now.
fn watch(stack: *StackBase, device: *Device) void {
    const req = &device.event.req;
    req.req.command = net.S2_ONEVENT;
    req.req.flags = 0;
    req.wire_error = if (device.offline != 0) net.S2EVENT_ONLINE else net.S2EVENT_OFFLINE;
    device.event_armed = 1;
    device.in_flight += 1;
    stack.sys_base.SendIO(&req.req);
}

/// The link on or off: the interface up or down with it, and on the way
/// up DHCP renewing. Under the lock.
pub fn setLink(stack: *StackBase, device: *Device, online: bool) void {
    if (online == (device.offline == 0)) return;
    const interface = device.interface;
    device.offline = @intFromBool(!online);
    interface.up = @intFromBool(online);
    if (online) @import("../dhcp/_dhcp.zig").linkUp(stack, interface);
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
    req.packet_type = packetType(request.kind);
    req.data = frame;
    req.data_length = read_bytes;
    device.in_flight += 1;
    sys.SendIO(&req.req);
}

/// The reads that waited for a frame, sent now that frames may be free.
pub fn retryReads(stack: *StackBase, device: *Device) void {
    const sys = stack.sys_base;
    if (device.going != 0 or device.offline != 0) return;
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
    if (device.going != 0 or device.offline != 0) {
        interface.dropped += 1;
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

/// The packet type a read of `kind` takes.
fn packetType(kind: Kind) u16 {
    return switch (kind) {
        .read_arp => _arp.ethertype,
        .read_ip6 => _ip6.ethertype,
        else => _ip.ethertype,
    };
}

fn write(stack: *StackBase, request: *Request, frame: *Frame) void {
    const device = request.device.?;
    request.frame = frame;
    const req = &request.req;
    const broadcast = for (frame.link_address) |octet| {
        if (octet != 0xFF) break false;
    } else true;
    const group = frame.link_address[0] & 1 != 0;
    req.req.command = if (broadcast) net.S2_BROADCAST else if (group) net.S2_MULTICAST else exec.CMD_WRITE;
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
    if (request.kind == .control) {
        const group = device.control_group.?;
        device.control_group = null;
        const joining = request.req.req.command == net.S2_ADDMULTICASTADDRESS;
        // A group the device refuses is not asked for again until its
        // users change.
        group.joined = @intFromBool(joining);
        if (device.going != 0) return;
        return syncGroups(stack, device);
    }
    if (request.kind == .event) {
        device.event_armed = 0;
        if (device.going != 0) return;
        // A device that cannot tell of events is not asked again.
        if (request.req.req.err != 0) return;
        if (request.req.wire_error & net.S2EVENT_OFFLINE != 0) setLink(stack, device, false);
        if (request.req.wire_error & net.S2EVENT_ONLINE != 0) setLink(stack, device, true);
        return watch(stack, device);
    }
    const frame = request.frame.?;
    request.frame = null;
    const req = &request.req;
    switch (request.kind) {
        .read_ip, .read_arp, .read_ip6 => {
            if (req.req.err != 0 or device.going != 0) {
                stack.frames.give(sys, frame);
                if (req.req.err == net.S2ERR_OUTOFSERVICE) setLink(stack, device, false);
            } else {
                _netif.receive(stack, interface, frame, req.src_addr[0..6], req.dst_addr[0..6], packetType(request.kind), now);
            }
            if (device.going != 0) return;
            if (device.offline != 0) return sys.AddTail(&device.idle_reads, &request.req.req.message.node);
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
        .event, .control => unreachable,
    }
}

/// Every request still in flight taken back, on the stack task, without
/// the lock: a read is aborted, a write let finish - the last thing sent,
/// a DHCP release, should reach the wire - and each waited for, its frame
/// handed back under the lock. What waited in the queue goes too.
pub fn drain(stack: *StackBase, device: *Device) void {
    const sys = stack.sys_base;
    for (device.requests[0 .. device.reads + device.writes]) |*request| {
        if (request.frame == null) continue;
        if (request.kind != .write) _ = sys.AbortIO(&request.req.req);
        _ = sys.WaitIO(&request.req.req);
    }
    if (device.event_armed != 0) {
        _ = sys.AbortIO(&device.event.req.req);
        _ = sys.WaitIO(&device.event.req.req);
        device.event_armed = 0;
    }
    if (device.control_group != null) {
        _ = sys.WaitIO(&device.control.req.req);
        device.control_group = null;
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
