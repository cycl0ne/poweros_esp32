// SPDX-License-Identifier: MIT
//! HCI on a UART (H4): every packet goes with a byte before it that says
//! its kind - 0x01 a command, 0x02 ACL data, 0x03 SCO data, 0x04 an event,
//! 0x05 ISO data - and nothing else marks where one ends and the next
//! begins: its header's length does.
//!
//! **In**, the bytes the line brought are taken into a `Parser` until a
//! packet is whole: its kind byte, its header (an event's 2 bytes, ACL's
//! and ISO's 4, SCO's 3), then as many bytes as the header says. The
//! Broadcom controllers send kinds of their own beside HCI's: a byte of 0,
//! 0x31 or 0x34 alone, and 0x07 with 63 bytes behind it - their
//! diagnostics, which nothing here asks for - and these are passed over.
//! A byte that begins no kind is passed over too, and counted: the line
//! has lost its place, and finds it again at the next packet that starts
//! where a byte is read. A packet longer than a read could ever hold
//! (`MAX_PACKET`) is passed over byte for byte, so that the next starts
//! where it should.
//!
//! **The ring** keeps whole packets nobody has asked for yet, oldest
//! first; when it is full, the bytes wait where they are.
//!
//! Pure: the worker hands in the bytes and takes the packets out, so the
//! host tests run it on bytes alone.

const sdk = @import("sdk");
const hci = sdk.bluetooth.hci;
const hcidev = sdk.devices.hci;

/// The longest packet taken: an ACL packet with 1024 bytes of data, more
/// than the longest event.
pub const MAX_PACKET = hci.HCI_ACL_HDR + 1024;
/// How many whole packets wait to be read.
pub const SLOTS = 8;

/// The headers H4 carries beside the command's and the event's.
const SCO_HDR = 3;
const ISO_HDR = 4;

/// The Broadcom controllers' own kinds: a byte alone, and their
/// diagnostics, a fixed 63 bytes.
const BCM_NULL: u8 = 0x00;
const BCM_TYPE49: u8 = 0x31;
const BCM_TYPE52: u8 = 0x34;
const BCM_LM_DIAG: u8 = 0x07;
const BCM_LM_DIAG_SIZE = 63;

/// The packets a controller sends, put together from its bytes.
pub const Parser = struct {
    /// The packet's kind (HCI_*_PKT), 0 while its kind byte is awaited.
    packet_type: u8 = 0,
    /// Its bytes so far, and whether it is whole and waits to be handed
    /// on.
    have: usize = 0,
    whole: bool = false,
    /// Bytes still to pass over: of a packet too long to take, or of a
    /// kind of the controller's own.
    skip: usize = 0,
    /// The bytes passed over that began no kind: how often the line lost
    /// its place.
    lost: u32 = 0,
    bytes: [MAX_PACKET]u8 = undefined,

    /// The header's length of the packet being put together.
    fn headerLength(parser: *const Parser) usize {
        return switch (parser.packet_type) {
            hcidev.HCI_EVENT_PKT => hci.HCI_EVENT_HDR,
            hcidev.HCI_ACLDATA_PKT => hci.HCI_ACL_HDR,
            hcidev.HCI_SCODATA_PKT => SCO_HDR,
            else => ISO_HDR,
        };
    }

    /// The whole packet's length, once its header is there.
    fn total(parser: *const Parser) usize {
        const b = &parser.bytes;
        return switch (parser.packet_type) {
            hcidev.HCI_EVENT_PKT => hci.HCI_EVENT_HDR + @as(usize, b[1]),
            hcidev.HCI_ACLDATA_PKT => hci.HCI_ACL_HDR + (@as(usize, b[2]) | @as(usize, b[3]) << 8),
            hcidev.HCI_SCODATA_PKT => SCO_HDR + @as(usize, b[2]),
            // ISO's length is 14 bits, two flags above it.
            else => ISO_HDR + ((@as(usize, b[2]) | @as(usize, b[3]) << 8) & 0x3FFF),
        };
    }

    /// The packet, once whole.
    pub fn packet(parser: *const Parser) []const u8 {
        return parser.bytes[0..parser.have];
    }

    /// The packet handed on: the next one starts with its kind byte.
    pub fn clear(parser: *Parser) void {
        parser.packet_type = 0;
        parser.have = 0;
        parser.whole = false;
    }

    /// Everything forgotten, for a line started again.
    pub fn reset(parser: *Parser) void {
        parser.clear();
        parser.skip = 0;
    }

    /// A kind byte read: the packet it begins, or a kind of the
    /// controller's own passed over, or a byte that begins nothing.
    fn begin(parser: *Parser, kind: u8) void {
        switch (kind) {
            hcidev.HCI_EVENT_PKT, hcidev.HCI_ACLDATA_PKT, hcidev.HCI_SCODATA_PKT, hcidev.HCI_ISODATA_PKT => {
                parser.packet_type = kind;
                parser.have = 0;
            },
            BCM_NULL, BCM_TYPE49, BCM_TYPE52 => {},
            BCM_LM_DIAG => parser.skip = BCM_LM_DIAG_SIZE,
            else => parser.lost +%= 1,
        }
    }

    /// Bytes taken until a packet is whole or they run out: how many were
    /// taken.
    pub fn take(parser: *Parser, bytes: []const u8) usize {
        var used: usize = 0;
        while (used < bytes.len and !parser.whole) {
            if (parser.skip > 0) {
                const passed = @min(parser.skip, bytes.len - used);
                parser.skip -= passed;
                used += passed;
                continue;
            }
            if (parser.packet_type == 0) {
                parser.begin(bytes[used]);
                used += 1;
                continue;
            }
            const header = parser.headerLength();
            if (parser.have < header) {
                parser.bytes[parser.have] = bytes[used];
                parser.have += 1;
                used += 1;
                if (parser.have == header) {
                    const length = parser.total();
                    if (length > MAX_PACKET) {
                        parser.skip = length - header;
                        parser.clear();
                    } else if (length == header) {
                        parser.whole = true;
                    }
                }
                continue;
            }
            const length = parser.total();
            const wanted = @min(length - parser.have, bytes.len - used);
            @memcpy(parser.bytes[parser.have..][0..wanted], bytes[used..][0..wanted]);
            parser.have += wanted;
            used += wanted;
            if (parser.have == length) parser.whole = true;
        }
        return used;
    }
};

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
        @memcpy(slot.bytes[0..bytes.len], bytes);
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

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

/// `bytes` handed in `size` bytes at a time, as the line brings them: the
/// packets that came whole, their kinds and lengths.
fn feed(parser: *Parser, bytes: []const u8, size: usize, kinds: []u8, lengths: []usize) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        const piece = bytes[at..@min(at + size, bytes.len)];
        var used: usize = 0;
        while (used < piece.len) {
            used += parser.take(piece[used..]);
            if (parser.whole) {
                kinds[count] = parser.packet_type;
                lengths[count] = parser.packet().len;
                count += 1;
                parser.clear();
            }
        }
        at += piece.len;
    }
    return count;
}

test "an event and ACL data come apart by their kind bytes, a byte at a time or all at once" {
    // Command Complete for HCI_Reset, then an ACL packet of 5 bytes, then
    // an event of its header alone.
    const stream = [_]u8{
        0x04, 0x0E, 0x04, 0x01, 0x03, 0x0C, 0x00,
        0x02, 0x01, 0x20, 0x05, 0x00, 1,    2,
        3,    4,    5,    0x04, 0x10, 0x00,
    };
    for ([_]usize{ 1, 3, stream.len }) |size| {
        var parser = Parser{};
        var kinds: [4]u8 = undefined;
        var lengths: [4]usize = undefined;
        try testing.expectEqual(@as(usize, 3), feed(&parser, &stream, size, &kinds, &lengths));
        try testing.expectEqualSlices(u8, &.{ hcidev.HCI_EVENT_PKT, hcidev.HCI_ACLDATA_PKT, hcidev.HCI_EVENT_PKT }, kinds[0..3]);
        try testing.expectEqualSlices(usize, &.{ 6, 9, 2 }, lengths[0..3]);
        try testing.expectEqual(@as(u32, 0), parser.lost);
    }
    // The event's bytes, without its kind byte.
    var parser = Parser{};
    _ = parser.take(&stream);
    try testing.expectEqualSlices(u8, stream[1..7], parser.packet());
}

test "SCO's header is three bytes and ISO's length fourteen bits" {
    const stream = [_]u8{
        0x03, 0x01, 0x00, 0x02, 0xAA, 0xBB,
        0x05, 0x02, 0x00, 0x03, 0xC0, 7,
        8,    9,
    };
    var parser = Parser{};
    var kinds: [4]u8 = undefined;
    var lengths: [4]usize = undefined;
    try testing.expectEqual(@as(usize, 2), feed(&parser, &stream, 4, &kinds, &lengths));
    try testing.expectEqualSlices(u8, &.{ hcidev.HCI_SCODATA_PKT, hcidev.HCI_ISODATA_PKT }, kinds[0..2]);
    try testing.expectEqualSlices(usize, &.{ 5, 7 }, lengths[0..2]);
}

test "the controller's own kinds are passed over, and a stray byte is counted" {
    var stream: [1 + 1 + 1 + 64 + 1 + 4]u8 = undefined;
    stream[0] = BCM_NULL;
    stream[1] = BCM_TYPE49;
    stream[2] = BCM_TYPE52;
    stream[3] = BCM_LM_DIAG;
    // A diagnostic's 63 bytes, which hold what looks like kind bytes.
    @memset(stream[4..67], hcidev.HCI_EVENT_PKT);
    stream[67] = 0x99;
    stream[68..72].* = .{ 0x04, 0x13, 0x01, 0x01 };
    var parser = Parser{};
    var kinds: [4]u8 = undefined;
    var lengths: [4]usize = undefined;
    try testing.expectEqual(@as(usize, 1), feed(&parser, &stream, 16, &kinds, &lengths));
    try testing.expectEqual(hcidev.HCI_EVENT_PKT, kinds[0]);
    try testing.expectEqual(@as(usize, 3), lengths[0]);
    try testing.expectEqual(@as(u32, 1), parser.lost);
}

test "a packet too long to be taken is passed over, and the next starts after it" {
    var stream: [1 + 4 + 2000 + 1 + 4 + 3]u8 = @splat(0x55);
    stream[0..5].* = .{ 0x02, 0x01, 0x20, 0xD0, 0x07 };
    stream[2005..2010].* = .{ 0x02, 0x02, 0x20, 3, 0 };
    var parser = Parser{};
    var kinds: [4]u8 = undefined;
    var lengths: [4]usize = undefined;
    try testing.expectEqual(@as(usize, 1), feed(&parser, &stream, 64, &kinds, &lengths));
    try testing.expectEqual(@as(usize, 7), lengths[0]);
    try testing.expectEqual(@as(u32, 0), parser.lost);
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
