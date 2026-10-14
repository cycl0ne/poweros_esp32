// SPDX-License-Identifier: MIT
//! The stick's frames, to and from Ethernet's: a frame sent becomes a
//! transfer out (`outgoing`), and a frame the radio received becomes the
//! Ethernet frames it carries (`Incoming`).
//!
//! **A frame out** is the Ethernet frame without its header, behind a
//! 4-byte USB header - its whole length, padding and header included, in
//! 12 bits, and the type 1 - and a 28-byte descriptor: the payload's
//! length, a word asking for the frame's status (an EAPOL frame's), the
//! two addresses and the type the header had, the queue and the traffic
//! class, the station interface and the access point's station number.
//! The transfer is padded to four bytes. The firmware makes the 802.11
//! frame of it and encrypts it.
//!
//! **A frame in** is an 802.11 data frame, decrypted, behind the radio's
//! 56-byte header (msg.zig gives it as a record). The header says whether
//! it is to be passed up and how it was protected; the frame's own header
//! says which addresses are whose, whether it is a QoS frame and whether
//! its body is an A-MSDU. Its body is an LLC/SNAP header with the type,
//! then the packet - behind the cipher's header, which the radio leaves
//! in place - or, in an A-MSDU, subframes of their own: two addresses, a
//! length, LLC/SNAP and the packet, each padded to four bytes but the
//! last.

const msg = @import("msg.zig");

/// The USB header and the descriptor in front of a frame out.
pub const out_header_bytes = 4 + desc_bytes;
pub const desc_bytes = 28;
/// Ethernet's header: two addresses and the type.
pub const ether_header_bytes = 14;
/// The USB type of a frame out.
const TYPE_FRAME_OUT: u8 = 0x01;

/// The hardware queues, by access category.
pub const QUEUE_BK: u8 = 0;
pub const QUEUE_BE: u8 = 1;
pub const QUEUE_VI: u8 = 2;
pub const QUEUE_VO: u8 = 3;

/// A frame's status asked for: the firmware answers with a record of
/// type 0x12 carrying `index`.
pub fn statusWord(index: u8) u32 {
    return 0x8000_0000 | @as(u32, index);
}

/// The Ethernet frame `ether` as a transfer out into `into`, from the
/// station interface `vif` to the access point `sta`: how many bytes, 0
/// when it is too short or does not fit. `status` asks for the frame's
/// status (`statusWord`), 0 for none.
pub fn outgoing(into: []u8, ether: []const u8, vif: u8, sta: u8, status: u32) usize {
    if (ether.len < ether_header_bytes) return 0;
    const payload = ether[ether_header_bytes..];
    const length = out_header_bytes + payload.len;
    const total = (length + 3) & ~@as(usize, 3);
    if (total > into.len or total > 0x0FFF) return 0;
    into[0] = @truncate(total);
    into[1] = @truncate(total >> 8);
    into[2] = TYPE_FRAME_OUT;
    into[3] = 0;
    const desc = into[4..][0..desc_bytes];
    desc[0] = @truncate(payload.len);
    desc[1] = @truncate(payload.len >> 8);
    desc[2] = 0;
    desc[3] = 0;
    msg.put32(desc, 4, status);
    @memcpy(desc[8..14], ether[0..6]);
    @memcpy(desc[14..20], ether[6..12]);
    // The type as it stands in the frame, network order.
    desc[20] = ether[12];
    desc[21] = ether[13];
    desc[22] = QUEUE_BE;
    desc[23] = 0;
    desc[24] = vif;
    desc[25] = sta;
    desc[26] = 0;
    desc[27] = 0;
    @memcpy(into[out_header_bytes..][0..payload.len], payload);
    @memset(into[length..total], 0);
    return total;
}

// --- frames in ----------------------------------------------------------------------

/// The radio header's words this file reads.
const off_status = 36;
const off_flags = 48;
/// The flags: an 802.11 frame the firmware passes up whole (a management
/// frame), one to pass up at all.
const FLAG_80211: u32 = 1 << 1;
const FLAG_UPLOAD: u32 = 1 << 6;

/// How the radio decrypted the frame, and so the cipher header it left.
const DECR_NONE = 0;
const DECR_WEP = 1;
const DECR_WAPI = 7;

/// The LLC/SNAP header a packet's type follows.
const snap = [_]u8{ 0xAA, 0xAA, 0x03, 0x00, 0x00, 0x00 };
const snap_bytes = 8;

/// The Ethernet frames a received 802.11 data frame carries, one at a
/// time: its own packet, or each of its A-MSDU's.
pub const Incoming = struct {
    /// The addresses its packets go to and come from (an A-MSDU's
    /// subframes have their own).
    destination: [6]u8 = @splat(0),
    source: [6]u8 = @splat(0),
    /// The body: a single packet's LLC/SNAP header on, or the A-MSDU.
    body: []const u8 = &.{},
    amsdu: bool = false,
    at: usize = 0,
    done: bool = false,

    /// The data frame of record `frame` behind the radio's `header`, null
    /// when it is nothing to pass up.
    pub fn of(header: []const u8, frame: []const u8) ?Incoming {
        if (header.len < off_flags + 4 or frame.len < 24) return null;
        const flags = msg.get32(header, off_flags);
        if (flags & FLAG_UPLOAD == 0 or flags & FLAG_80211 != 0) return null;
        // A data frame, with data in it.
        if (frame[0] & 0x0C != 0x08 or frame[0] & 0x40 != 0) return null;
        var at: usize = 24;
        var amsdu = false;
        if (frame[0] & 0x80 != 0) {
            if (frame.len < 26) return null;
            amsdu = frame[24] & 0x80 != 0;
            at += 2;
            if (frame[1] & 0x80 != 0) at += 4;
        }
        // Fragments are not put together: an access point fragments
        // nothing a station's packets need.
        if (frame[1] & 0x04 != 0 or frame[22] & 0x0F != 0) return null;
        var incoming = Incoming{ .amsdu = amsdu };
        switch (frame[1] & 0x03) {
            // From the access point: to addr1, from addr3.
            2 => {
                @memcpy(&incoming.destination, frame[4..10]);
                @memcpy(&incoming.source, frame[16..22]);
            },
            // To it - another station's, seen on the way: to addr3,
            // from addr2.
            1 => {
                @memcpy(&incoming.destination, frame[16..22]);
                @memcpy(&incoming.source, frame[10..16]);
            },
            0 => {
                @memcpy(&incoming.destination, frame[4..10]);
                @memcpy(&incoming.source, frame[10..16]);
            },
            else => return null,
        }
        const decrypted: u32 = (msg.get32(header, off_status) >> 2) & 0x07;
        at += switch (decrypted) {
            DECR_NONE => 0,
            DECR_WEP => 4,
            DECR_WAPI => 18,
            else => 8,
        };
        if (at > frame.len) return null;
        incoming.body = frame[at..];
        return incoming;
    }

    /// The next Ethernet frame into `into`: its length, null when there
    /// are no more. One that does not fit, or is not LLC/SNAP, is passed
    /// over.
    pub fn next(incoming: *Incoming, into: []u8) ?usize {
        while (!incoming.done) {
            if (!incoming.amsdu) {
                incoming.done = true;
                return ethernet(into, &incoming.destination, &incoming.source, incoming.body);
            }
            // A subframe: its addresses, its length, its body.
            const rest = incoming.body[incoming.at..];
            if (rest.len < ether_header_bytes) {
                incoming.done = true;
                return null;
            }
            const length = @as(usize, rest[12]) << 8 | rest[13];
            if (ether_header_bytes + length > rest.len) {
                incoming.done = true;
                return null;
            }
            const body = rest[ether_header_bytes..][0..length];
            incoming.at += (ether_header_bytes + length + 3) & ~@as(usize, 3);
            if (incoming.at >= incoming.body.len) incoming.done = true;
            if (ethernet(into, rest[0..6], rest[6..12], body)) |made| return made;
        }
        return null;
    }
};

/// An Ethernet frame from two addresses and an LLC/SNAP body: its
/// length, null if the body is not one or the frame does not fit.
fn ethernet(into: []u8, destination: *const [6]u8, source: *const [6]u8, body: []const u8) ?usize {
    if (body.len < snap_bytes) return null;
    for (snap, body[0..snap.len]) |want, have| {
        if (want != have) return null;
    }
    const payload = body[snap_bytes..];
    const length = ether_header_bytes + payload.len;
    if (length > into.len) return null;
    @memcpy(into[0..6], destination);
    @memcpy(into[6..12], source);
    into[12] = body[6];
    into[13] = body[7];
    @memcpy(into[ether_header_bytes..][0..payload.len], payload);
    return length;
}

// --- tests --------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "a frame out: the USB header, the descriptor, the payload, padded" {
    var ether: [14 + 5]u8 = undefined;
    @memcpy(ether[0..6], &[_]u8{ 1, 2, 3, 4, 5, 6 });
    @memcpy(ether[6..12], &[_]u8{ 7, 8, 9, 10, 11, 12 });
    ether[12] = 0x08;
    ether[13] = 0x00;
    @memcpy(ether[14..], "hello");
    var out: [64]u8 = undefined;
    const length = outgoing(&out, &ether, 0, 3, 0);
    try testing.expectEqual(@as(usize, 40), length);
    try testing.expectEqualSlices(u8, &.{ 40, 0, 0x01, 0 }, out[0..4]);
    try testing.expectEqual(@as(u16, 5), msg.get16(&out, 4));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, out[12..18]);
    try testing.expectEqualSlices(u8, &.{ 7, 8, 9, 10, 11, 12 }, out[18..24]);
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x00 }, out[24..26]);
    try testing.expectEqual(@as(u8, 3), out[29]);
    try testing.expectEqualStrings("hello", out[32..37]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, out[37..40]);
}

fn radioHeader(decrypted: u32) [56]u8 {
    var header: [56]u8 = @splat(0);
    msg.put32(&header, off_flags, FLAG_UPLOAD);
    msg.put32(&header, off_status, decrypted << 2);
    return header;
}

test "a QoS data frame from the access point, CCMP: Ethernet's" {
    const header = radioHeader(3);
    var frame: [26 + 8 + 8 + 4]u8 = @splat(0);
    frame[0] = 0x88;
    frame[1] = 0x42; // from DS, protected
    @memcpy(frame[4..10], &[_]u8{ 1, 1, 1, 1, 1, 1 });
    @memcpy(frame[16..22], &[_]u8{ 3, 3, 3, 3, 3, 3 });
    @memcpy(frame[34..40], &snap);
    frame[40] = 0x08;
    frame[41] = 0x06;
    @memcpy(frame[42..46], "ping");
    var incoming = Incoming.of(&header, &frame).?;
    var out: [64]u8 = undefined;
    const length = incoming.next(&out).?;
    try testing.expectEqual(@as(usize, 18), length);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 3, 0x08, 0x06 }, out[0..14]);
    try testing.expectEqualStrings("ping", out[14..18]);
    try testing.expect(incoming.next(&out) == null);
}

test "an A-MSDU: each subframe its own frame" {
    const header = radioHeader(0);
    var frame: [26 + 2 * 24]u8 = @splat(0);
    frame[0] = 0x88;
    frame[1] = 0x02;
    frame[24] = 0x80;
    var at: usize = 26;
    for ([_]u8{ 'a', 'b' }) |mark| {
        @memset(frame[at..][0..6], mark);
        @memset(frame[at + 6 ..][0..6], 9);
        frame[at + 13] = 8 + 2;
        @memcpy(frame[at + 14 ..][0..6], &snap);
        frame[at + 21] = 0x00;
        frame[at + 20] = 0x08;
        frame[at + 22] = mark;
        frame[at + 23] = mark;
        at += 24;
    }
    var incoming = Incoming.of(&header, frame[0..at]).?;
    var out: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 16), incoming.next(&out).?);
    try testing.expectEqual(@as(u8, 'a'), out[0]);
    try testing.expectEqual(@as(u8, 'a'), out[14]);
    try testing.expectEqual(@as(usize, 16), incoming.next(&out).?);
    try testing.expectEqual(@as(u8, 'b'), out[0]);
    try testing.expect(incoming.next(&out) == null);
}

test "a frame not to pass up, and a null frame, are nothing" {
    var header = radioHeader(0);
    var frame: [40]u8 = @splat(0);
    frame[0] = 0x08;
    frame[1] = 0x02;
    msg.put32(&header, off_flags, 0);
    try testing.expect(Incoming.of(&header, &frame) == null);
    header = radioHeader(0);
    frame[0] = 0x48;
    try testing.expect(Incoming.of(&header, &frame) == null);
}
