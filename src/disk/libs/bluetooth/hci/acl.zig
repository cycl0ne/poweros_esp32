// SPDX-License-Identifier: MIT
//! A controller's ACL data: L2CAP's frames cut into ACL packets for it,
//! and put together again from the packets it hands up; its buffers
//! shared out among the links.
//!
//! **Its buffers.** The controller holds `acl_packets` ACL packets for
//! sending over BR/EDR, each of up to `acl_mtu` bytes of data, and LE's
//! own where it has them (`le_packets`, `le_mtu`) - otherwise LE's links
//! share BR/EDR's. A packet given it holds a buffer until Number Of
//! Completed Packets says it is sent, or until its link is down: then
//! every buffer its link's packets held is free again.
//!
//! **Each link its share.** A link whose device stops taking packets -
//! one switched off or out of range, until the link is lost - keeps the
//! buffers its packets hold, and its frames wait. So a link holds at
//! most an even share of its pool among the links up in it, rounded up,
//! and queues at most an even share of the layer's queue among all the
//! links up, and every link that is up keeps one of each for itself: a
//! link takes a buffer while it holds none, and another while it holds
//! less than its share and more are free than the other links of its
//! pool that hold none; its frames take the queue's places the same
//! way. A link that sends without pause takes all it may, and keeps it
//! should its device then stop: the share is what it leaves the others.
//! With six buffers and three links up, it holds two, and the link that
//! carries sound - a packet every 21 ms or so - has two to send with
//! while the controller still tries the link that has stopped; one is
//! too few for that pace.
//!
//! **Sent in turn.** The links with frames queued take turns, a packet
//! each, from the link after the one whose packet went last. A link's
//! frames go in their order, each cut into packets as long as the
//! controller takes - the first marked as a frame's start, flushable
//! over BR/EDR and not over LE, the others as going on - and its next
//! frame begins once the last packet of this one has gone. A link that
//! goes down takes its frames not yet sent with it.
//!
//! **Put together.** A link puts one frame together at a time: its first
//! packet starts it, those that go on add to it until it has the length
//! its L2CAP header says, and it goes up to L2CAP (l2cap/_l2cap.zig). A
//! frame longer than FRAME_MOST is let go whole, as is a packet that goes
//! on a frame not begun.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const l2cap = bluetooth.l2cap;
const hcidev = sdk.devices.hci;
const _hci = @import("_hci.zig");
const Hci = _hci.Hci;
const connections = @import("connections.zig");
const Connection = connections.Connection;
const _l2cap = @import("../l2cap/_l2cap.zig");

/// The longest payload of a frame taken or sent, and the room for a
/// frame with its header.
pub const FRAME_MOST: usize = 1024;
pub const FRAME_ROOM: usize = l2cap.L2CAP_HDR + FRAME_MOST;
/// The most data an ACL packet the layer sends carries - less where the
/// controller takes less. The task's writes have room for it.
pub const PACKET_MOST: usize = 1024;
/// How many frames wait to be sent: every link's signalling and the
/// channels' frames share the places, each link up taking its share of
/// them at most and keeping one for itself.
pub const OUT = 8;

/// A free place's handle: never a link's.
const FREE: u16 = 0xFFFF;

/// A frame waiting to be sent: its link, its place in the link's order,
/// and how much of it has gone.
pub const Out = struct {
    handle: u16 = FREE,
    order: u64 = 0,
    length: usize = 0,
    sent: usize = 0,
    bytes: [FRAME_ROOM]u8 = undefined,
};

/// The buffers a link's packets take: BR/EDR's, or LE's own.
const Pool = struct {
    credits: *u16,
    most: u16,
    mtu: usize,
};

fn poolOf(layer: *Hci, le: bool) Pool {
    if (le and layer.le_own) return .{ .credits = &layer.le_credits, .most = layer.le_packets, .mtu = layer.le_mtu };
    return .{ .credits = &layer.acl_credits, .most = layer.acl_packets, .mtu = layer.acl_mtu };
}

/// Every frame let go and every buffer forgotten: the controller is
/// reset, and says again what it has.
pub fn reset(layer: *Hci) void {
    for (&layer.out) |*frame| frame.handle = FREE;
    layer.out_count = 0;
    layer.acl_credits = 0;
    layer.le_credits = 0;
}

/// The controller's buffers as Read Buffer Size and LE Read Buffer Size
/// answered them, all free.
pub fn buffersRead(layer: *Hci) void {
    layer.acl_credits = layer.acl_packets;
    layer.le_credits = if (layer.le_own) layer.le_packets else 0;
}

/// A frame on channel `cid` of the link queued, `payload` after its
/// header, and sent as far as the controller takes it: false when the
/// link is not up, the payload is too long or the link's share of the
/// queue is full.
pub fn send(layer: *Hci, connection: *const Connection, cid: u16, payload: []const u8) bool {
    if (connection.state != .up) return false;
    if (payload.len > FRAME_MOST or !roomFor(layer, connection)) return false;
    const frame = for (&layer.out) |*place| {
        if (place.handle == FREE) break place;
    } else return false;
    frame.handle = connection.handle;
    frame.order = layer.out_order;
    layer.out_order += 1;
    frame.length = l2cap.L2CAP_HDR + payload.len;
    frame.sent = 0;
    frame.bytes[0] = @truncate(payload.len);
    frame.bytes[1] = @truncate(payload.len >> 8);
    frame.bytes[2] = @truncate(cid);
    frame.bytes[3] = @truncate(cid >> 8);
    @memcpy(frame.bytes[l2cap.L2CAP_HDR..][0..payload.len], payload);
    layer.out_count += 1;
    pump(layer);
    return true;
}

/// Whether a frame of the link's may be queued: while it has none
/// queued, into any place free; another while it has fewer than its
/// share of the places queued and more are free than the other links up
/// that have none queued.
fn roomFor(layer: *Hci, connection: *const Connection) bool {
    const free = OUT - layer.out_count;
    if (free == 0) return false;
    const mine = queued(layer, connection.handle);
    if (mine == 0) return true;
    var links: usize = 1;
    var keeping: usize = 0;
    for (&layer.connections) |*other| {
        if (other == connection or other.state != .up) continue;
        links += 1;
        if (queued(layer, other.handle) == 0) keeping += 1;
    }
    return mine < share(OUT, links) and free > keeping;
}

/// An even share of `most` among `links`, rounded up.
fn share(most: usize, links: usize) usize {
    return (most + links - 1) / links;
}

/// How many of the link's frames are queued.
fn queued(layer: *const Hci, handle: u16) usize {
    var count: usize = 0;
    for (&layer.out) |*frame| {
        if (frame.handle == handle) count += 1;
    }
    return count;
}

/// The queue's frames sent, a packet at a time, while the controller has
/// buffers the links may take and the transport takes the packets: on a
/// new frame, on buffers given back, on a link down, and once the
/// transport takes packets again. A frame whose link is gone, or whose
/// buffers the controller has not said, is let go.
pub fn pump(layer: *Hci) void {
    for (&layer.out) |*frame| {
        if (frame.handle == FREE) continue;
        const connection = connections.byHandle(layer, frame.handle) orelse {
            letGo(layer, frame);
            continue;
        };
        if (poolOf(layer, connection.le).mtu == 0) letGo(layer, frame);
    }
    while (nextTurn(layer)) |turn| {
        const frame = turn.frame;
        const connection = turn.connection;
        const pool = poolOf(layer, connection.le);
        const piece = @min(frame.length - frame.sent, pool.mtu, PACKET_MOST);
        const boundary: u16 = if (frame.sent != 0) hci.ACL_CONTINUING else if (connection.le) hci.ACL_START_NO_FLUSH else hci.ACL_START;
        const head = frame.handle | boundary << hci.ACL_BOUNDARY_SHIFT;
        const packet = &layer.acl_packet;
        packet[0] = @truncate(head);
        packet[1] = @truncate(head >> 8);
        packet[2] = @truncate(piece);
        packet[3] = @truncate(piece >> 8);
        @memcpy(packet[hci.HCI_ACL_HDR..][0..piece], frame.bytes[frame.sent..][0..piece]);
        if (!layer.port.send(layer.port.context, hcidev.HCI_ACLDATA_PKT, packet[0 .. hci.HCI_ACL_HDR + piece])) return;
        pool.credits.* -= 1;
        connection.outstanding += 1;
        layer.out_turn = turn.index;
        frame.sent += piece;
        if (frame.sent == frame.length) letGo(layer, frame);
    }
}

/// A link's turn: its place in the table, and its frame that goes on.
const Turn = struct {
    index: u8,
    connection: *Connection,
    frame: *Out,
};

/// Whose packet goes next: the first link - from the one after the link
/// whose packet went last - with a frame queued and a buffer it may
/// take, and its oldest frame; null for none.
fn nextTurn(layer: *Hci) ?Turn {
    if (layer.out_count == 0) return null;
    for (1..connections.CONNECTIONS + 1) |step| {
        const index: u8 = @intCast((layer.out_turn + step) % connections.CONNECTIONS);
        const connection = &layer.connections[index];
        if (connection.state != .up and connection.state != .disconnecting) continue;
        const frame = oldest(layer, connection.handle) orelse continue;
        if (!mayTake(layer, connection)) continue;
        return .{ .index = index, .connection = connection, .frame = frame };
    }
    return null;
}

/// The link's frame queued first - the one partly sent, where there is
/// one; null for none.
fn oldest(layer: *Hci, handle: u16) ?*Out {
    var found: ?*Out = null;
    for (&layer.out) |*frame| {
        if (frame.handle != handle) continue;
        if (found == null or frame.order < found.?.order) found = frame;
    }
    return found;
}

/// Whether the link may take a buffer of its pool: one while it holds
/// none; another while it holds fewer than its share of the pool and
/// more are free than the other links up in its pool that hold none.
fn mayTake(layer: *Hci, connection: *const Connection) bool {
    const pool = poolOf(layer, connection.le);
    if (pool.credits.* == 0) return false;
    if (connection.outstanding == 0) return true;
    var links: usize = 1;
    var keeping: u16 = 0;
    for (&layer.connections) |*other| {
        if (other == connection or other.state != .up) continue;
        if (poolOf(layer, other.le).credits != pool.credits) continue;
        links += 1;
        if (other.outstanding == 0) keeping += 1;
    }
    return connection.outstanding < share(pool.most, links) and pool.credits.* > keeping;
}

fn letGo(layer: *Hci, frame: *Out) void {
    frame.handle = FREE;
    layer.out_count -= 1;
}

/// Number Of Completed Packets: the buffers of the packets the
/// controller has sent given back, a link at a time - each handle and its
/// count together, one link after the other.
pub fn completedPackets(layer: *Hci, params: []const u8) void {
    if (params.len < 1) return;
    const links: usize = params[0];
    for (0..links) |index| {
        const at = 1 + index * 4;
        if (at + 4 > params.len) break;
        const handle = _hci.le16(params[at..][0..2]) & hci.ACL_HANDLE_MASK;
        const sent = _hci.le16(params[at + 2 ..][0..2]);
        const connection = connections.byHandle(layer, handle) orelse continue;
        const given = @min(sent, connection.outstanding);
        connection.outstanding -= given;
        giveBack(layer, connection.le, given);
    }
    pump(layer);
}

/// A link that is down: the buffers its packets held free again, its
/// frames not yet sent let go.
pub fn released(layer: *Hci, connection: *Connection) void {
    giveBack(layer, connection.le, connection.outstanding);
    connection.outstanding = 0;
    for (&layer.out) |*frame| {
        if (frame.handle == connection.handle) letGo(layer, frame);
    }
}

fn giveBack(layer: *Hci, le: bool, count: u16) void {
    const pool = poolOf(layer, le);
    pool.credits.* = @min(pool.credits.* +| count, pool.most);
}

/// An ACL packet the controller handed up, from its header on: added to
/// its link's frame, which goes up to L2CAP once it is whole.
pub fn received(layer: *Hci, bytes: []const u8) void {
    if (bytes.len < hci.HCI_ACL_HDR) return;
    const head = _hci.le16(bytes[0..2]);
    const handle = head & hci.ACL_HANDLE_MASK;
    const boundary = (head >> hci.ACL_BOUNDARY_SHIFT) & 0x3;
    const length = @min(_hci.le16(bytes[2..4]), bytes.len - hci.HCI_ACL_HDR);
    const data = bytes[hci.HCI_ACL_HDR..][0..length];
    const connection = connections.byHandle(layer, handle) orelse return;
    // Data from the device: it has answered on the link.
    if (!connection.heard) connections.established(layer, connection);
    if (boundary == hci.ACL_CONTINUING) {
        if (connection.frame_dropping or connection.frame_have == 0) return;
    } else {
        connection.frame_have = 0;
        connection.frame_dropping = false;
    }
    if (data.len > connection.frame.len - connection.frame_have) return drop(connection);
    @memcpy(connection.frame[connection.frame_have..][0..data.len], data);
    connection.frame_have += data.len;
    if (connection.frame_have < l2cap.L2CAP_HDR) return;
    const whole = l2cap.L2CAP_HDR + @as(usize, _hci.le16(connection.frame[0..2]));
    if (whole > connection.frame.len or connection.frame_have > whole) return drop(connection);
    if (connection.frame_have < whole) return;
    connection.frame_have = 0;
    _l2cap.received(layer, connection, connection.frame[0..whole]);
}

/// The frame being put together let go, and the packets that go on it
/// until the next one starts.
fn drop(connection: *Connection) void {
    connection.frame_have = 0;
    connection.frame_dropping = true;
}
