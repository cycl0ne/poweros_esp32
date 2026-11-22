// SPDX-License-Identifier: MIT
//! The packets a controller sends, put together from its endpoints'
//! transfers, and kept until they are read.
//!
//! **Events** come on the interrupt endpoint, a transfer of at most a
//! packet's worth at a time, **ACL data** on the bulk endpoint in
//! transfers that may hold the end of one packet and the start of the
//! next: either way the bytes are taken into an `Assembly` until its
//! header's length is there, and the packet is whole. One longer than a
//! read could ever hold (`MAX_PACKET`) is passed over, byte for byte, so
//! the next starts where it should.
//!
//! **The ring** keeps whole packets nobody has asked for yet. When it is
//! full, the rest of a transfer waits where it is and its endpoint is not
//! asked again until a read has made room: the controller holds what it
//! has meanwhile, and nothing is lost.
//!
//! Pure: the worker hands in the transfers and takes the packets out, so
//! the host tests run it on bytes alone.

const sdk = @import("sdk");
const hci = sdk.bluetooth.hci;
const hcidev = sdk.devices.hci;

/// The longest packet taken: an ACL packet with 1024 bytes of data, more
/// than the longest event.
pub const MAX_PACKET = hci.HCI_ACL_HDR + 1024;
/// How many whole packets wait to be read.
pub const SLOTS = 8;
/// A transfer on the bulk endpoint: four of its packets at high speed.
pub const BULK_SIZE = 2048;
/// A transfer on the interrupt endpoint: at most what its descriptor says
/// a packet holds.
pub const EVENT_SIZE = 64;

/// One packet being put together.
pub const Assembly = struct {
    /// HCI_EVENT_PKT or HCI_ACLDATA_PKT: which header it has.
    packet_type: u8,
    /// Its bytes so far, and whether it is whole and waits to be handed on.
    have: usize = 0,
    whole: bool = false,
    /// Bytes still to pass over of a packet too long to take.
    skip: usize = 0,
    bytes: [MAX_PACKET]u8 = undefined,

    fn headerLength(assembly: *const Assembly) usize {
        return if (assembly.packet_type == hcidev.HCI_EVENT_PKT) hci.HCI_EVENT_HDR else hci.HCI_ACL_HDR;
    }

    /// The whole packet's length, once its header is there.
    fn total(assembly: *const Assembly) usize {
        if (assembly.packet_type == hcidev.HCI_EVENT_PKT) return hci.HCI_EVENT_HDR + @as(usize, assembly.bytes[1]);
        return hci.HCI_ACL_HDR + (@as(usize, assembly.bytes[2]) | @as(usize, assembly.bytes[3]) << 8);
    }

    /// The packet, once whole.
    pub fn packet(assembly: *const Assembly) []const u8 {
        return assembly.bytes[0..assembly.have];
    }

    /// The packet handed on: the next one starts.
    pub fn clear(assembly: *Assembly) void {
        assembly.have = 0;
        assembly.whole = false;
    }
};

/// Bytes of a transfer taken into the assembly until its packet is whole
/// or they run out: how many were taken.
pub fn take(assembly: *Assembly, bytes: []const u8) usize {
    var used: usize = 0;
    while (used < bytes.len and !assembly.whole) {
        if (assembly.skip > 0) {
            const passed = @min(assembly.skip, bytes.len - used);
            assembly.skip -= passed;
            used += passed;
            continue;
        }
        const header = assembly.headerLength();
        if (assembly.have < header) {
            assembly.bytes[assembly.have] = bytes[used];
            assembly.have += 1;
            used += 1;
            if (assembly.have == header) {
                const length = assembly.total();
                if (length > MAX_PACKET) {
                    assembly.skip = length - header;
                    assembly.have = 0;
                } else if (length == header) {
                    assembly.whole = true;
                }
            }
            continue;
        }
        const length = assembly.total();
        const wanted = @min(length - assembly.have, bytes.len - used);
        for (bytes[used..][0..wanted], 0..) |byte, index| assembly.bytes[assembly.have + index] = byte;
        assembly.have += wanted;
        used += wanted;
        if (assembly.have == length) assembly.whole = true;
    }
    return used;
}

/// The whole packets nobody has read yet, oldest first.
pub const Ring = struct {
    slots: [SLOTS]Slot = undefined,
    head: usize = 0,
    count: usize = 0,

    pub const Slot = struct {
        packet_type: u8 = 0,
        length: usize = 0,
        bytes: [MAX_PACKET]u8 = undefined,

        pub fn packet(slot: *const Slot) []const u8 {
            return slot.bytes[0..slot.length];
        }
    };

    pub fn full(ring: *const Ring) bool {
        return ring.count == SLOTS;
    }

    /// The oldest packet; null for none.
    pub fn first(ring: *Ring) ?*Slot {
        if (ring.count == 0) return null;
        return &ring.slots[ring.head];
    }

    /// A packet kept: false when there is no room.
    pub fn put(ring: *Ring, packet_type: u8, bytes: []const u8) bool {
        if (ring.full() or bytes.len > MAX_PACKET) return false;
        const slot = &ring.slots[(ring.head + ring.count) % SLOTS];
        slot.packet_type = packet_type;
        slot.length = bytes.len;
        for (bytes, 0..) |byte, index| slot.bytes[index] = byte;
        ring.count += 1;
        return true;
    }

    /// The oldest packet read.
    pub fn drop(ring: *Ring) void {
        if (ring.count == 0) return;
        ring.head = (ring.head + 1) % SLOTS;
        ring.count -= 1;
    }

    pub fn clear(ring: *Ring) void {
        ring.head = 0;
        ring.count = 0;
    }
};

/// One endpoint in: its transfer's room, what came, how much of it has
/// been taken, and the packet being put together from it.
pub const In = struct {
    /// Whether a transfer is out on the endpoint.
    out: bool = false,
    /// What the last transfer brought, and how much of it is taken.
    length: usize = 0,
    offset: usize = 0,
    assembly: Assembly,
};

/// A unit's buffers: its two endpoints in, the transfers' rooms, the ring,
/// and the room for the setup's control transfers.
pub const Buffers = struct {
    events: In = .{ .assembly = .{ .packet_type = hcidev.HCI_EVENT_PKT } },
    acl: In = .{ .assembly = .{ .packet_type = hcidev.HCI_ACLDATA_PKT } },
    ring: Ring = .{},
    event_room: [EVENT_SIZE]u8 = undefined,
    bulk_room: [BULK_SIZE]u8 = undefined,
    /// A control transfer's data: a command out, an answer in.
    control: [hci.HCI_COMMAND_HDR + hci.HCI_MAX_PARAMS]u8 = undefined,

    /// Everything forgotten, for a controller plugged in anew.
    pub fn reset(buffers: *Buffers) void {
        for ([_]*In{ &buffers.events, &buffers.acl }) |in| {
            in.out = false;
            in.length = 0;
            in.offset = 0;
            in.assembly.clear();
            in.assembly.skip = 0;
        }
        buffers.ring.clear();
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

/// `bytes` handed in as transfers of `size` bytes: the packets that came
/// whole, as their lengths, into `lengths`.
fn feed(assembly: *Assembly, bytes: []const u8, size: usize, lengths: []usize) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        const transfer = bytes[at..@min(at + size, bytes.len)];
        var used: usize = 0;
        while (used < transfer.len) {
            used += take(assembly, transfer[used..]);
            if (assembly.whole) {
                lengths[count] = assembly.packet().len;
                count += 1;
                assembly.clear();
            }
        }
        at += transfer.len;
    }
    return count;
}

test "an event in packets of the interrupt endpoint is put together whole" {
    var assembly = Assembly{ .packet_type = hcidev.HCI_EVENT_PKT };
    var event: [2 + 68]u8 = undefined;
    event[0] = hci.HCI_EV_COMMAND_COMPLETE;
    event[1] = 68;
    for (event[2..], 0..) |*byte, index| byte.* = @truncate(index);
    var lengths: [4]usize = undefined;
    try testing.expectEqual(@as(usize, 1), feed(&assembly, &event, 16, &lengths));
    try testing.expectEqual(@as(usize, 70), lengths[0]);
    // An event of its header alone is whole with it.
    try testing.expectEqual(@as(usize, 1), feed(&assembly, &.{ hci.HCI_EV_HARDWARE_ERROR, 0 }, 16, &lengths));
    try testing.expectEqual(@as(usize, 2), lengths[0]);
}

test "ACL packets that share a transfer, and one split over two, come apart" {
    var assembly = Assembly{ .packet_type = hcidev.HCI_ACLDATA_PKT };
    var stream: [4 + 10 + 4 + 600]u8 = @splat(0xAA);
    stream[0..4].* = .{ 0x01, 0x20, 10, 0 };
    stream[14..18].* = .{ 0x01, 0x20, 0x58, 0x02 };
    var lengths: [4]usize = undefined;
    try testing.expectEqual(@as(usize, 2), feed(&assembly, &stream, 512, &lengths));
    try testing.expectEqual(@as(usize, 14), lengths[0]);
    try testing.expectEqual(@as(usize, 604), lengths[1]);
    var check = Assembly{ .packet_type = hcidev.HCI_ACLDATA_PKT };
    _ = take(&check, &stream);
    try testing.expectEqualSlices(u8, stream[0..14], check.packet());
}

test "a packet too long to be taken is passed over, and the next starts after it" {
    var assembly = Assembly{ .packet_type = hcidev.HCI_ACLDATA_PKT };
    var stream: [4 + 2000 + 4 + 3]u8 = @splat(0x55);
    stream[0..4].* = .{ 0x01, 0x20, 0xD0, 0x07 };
    stream[2004..2008].* = .{ 0x02, 0x20, 3, 0 };
    var lengths: [4]usize = undefined;
    try testing.expectEqual(@as(usize, 1), feed(&assembly, &stream, 64, &lengths));
    try testing.expectEqual(@as(usize, 7), lengths[0]);
}

test "the ring keeps packets oldest first, and takes none when full" {
    var ring = Ring{};
    var index: u8 = 0;
    while (index < SLOTS) : (index += 1) try testing.expect(ring.put(hcidev.HCI_EVENT_PKT, &.{ 0x0E, 1, index }));
    try testing.expect(ring.full());
    try testing.expect(!ring.put(hcidev.HCI_EVENT_PKT, &.{ 0x0E, 1, 99 }));
    try testing.expectEqual(@as(u8, 0), ring.first().?.packet()[2]);
    ring.drop();
    try testing.expect(ring.put(hcidev.HCI_ACLDATA_PKT, &.{ 1, 2, 0, 0 }));
    var seen: usize = 0;
    while (ring.first()) |slot| : (ring.drop()) {
        if (seen < SLOTS - 1) {
            try testing.expectEqual(@as(u8, @intCast(seen + 1)), slot.packet()[2]);
        } else {
            try testing.expectEqual(hcidev.HCI_ACLDATA_PKT, slot.packet_type);
        }
        seen += 1;
    }
    try testing.expectEqual(@as(usize, SLOTS), seen);
}
