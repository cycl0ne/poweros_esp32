// SPDX-License-Identifier: MIT
//! DNS messages (RFC 1035): a question written, and an answer read -
//! nothing here sends or waits.
//!
//! **Reading an answer trusts none of it.** The header must be the
//! answer to our question (its id, QR set); every count is walked one
//! record at a time and stops at the packet's end, not at what the count
//! claims; a name's labels and compression pointers are followed inside
//! the packet only, at most 16 pointers deep and to at most 255 bytes of
//! name, so a loop or a pointer past the end ends the reading; and each
//! record's data length (RDLENGTH) must fit in what is left of the
//! packet before any of it is read.

const _ip = @import("../ip/_ip.zig");

pub const port: u16 = 53;
pub const type_a: u16 = 1;
pub const type_cname: u16 = 5;
pub const type_ptr: u16 = 12;
const class_in: u16 = 1;
pub const name_max = 255;
const jumps_max = 16;

/// Answer codes.
pub const rcode_ok: u8 = 0;
pub const rcode_name_error: u8 = 3;

/// A question for `name` of `kind`, with `id`, into `into`: its length,
/// or 0 when the name does not make a question (too long, an empty
/// label).
pub fn question(into: []u8, id: u16, name: []const u8, kind: u16) usize {
    if (name.len == 0 or name.len > 253 or into.len < 12 + name.len + 2 + 4) return 0;
    @memset(into[0..12], 0);
    _ip.put16(into, 0, id);
    into[2] = 0x01; // RD: recursion desired
    _ip.put16(into, 4, 1);
    var at: usize = 12;
    var label_start: usize = 0;
    var index: usize = 0;
    while (index <= name.len) : (index += 1) {
        if (index == name.len or name[index] == '.') {
            const length = index - label_start;
            if (length == 0 and index == name.len and index > 0) break; // a trailing dot
            if (length == 0 or length > 63) return 0;
            into[at] = @intCast(length);
            @memcpy(into[at + 1 ..][0..length], name[label_start..index]);
            at += 1 + length;
            label_start = index + 1;
        }
    }
    into[at] = 0;
    at += 1;
    _ip.put16(into, at, kind);
    _ip.put16(into, at + 2, class_in);
    return at + 4;
}

/// A name read at `start` in `packet`, dotted, into `into`: where the
/// record goes on after it (past its first pointer, if it had one), or
/// null if it is not a name inside the packet.
pub fn readName(packet: []const u8, start: usize, into: ?*[name_max + 1]u8) ?usize {
    var at = start;
    var after: ?usize = null;
    var jumps: usize = 0;
    var written: usize = 0;
    while (true) {
        if (at >= packet.len) return null;
        const length = packet[at];
        if (length == 0) {
            if (after == null) after = at + 1;
            break;
        }
        if (length & 0xC0 == 0xC0) {
            if (at + 1 >= packet.len) return null;
            jumps += 1;
            if (jumps > jumps_max) return null;
            if (after == null) after = at + 2;
            at = (@as(usize, length & 0x3F) << 8) | packet[at + 1];
            continue;
        }
        if (length & 0xC0 != 0) return null;
        if (at + 1 + length > packet.len) return null;
        if (written + length + 1 > name_max) return null;
        if (into) |text| {
            if (written > 0) {
                text[written] = '.';
                written += 1;
            }
            @memcpy(text[written..][0..length], packet[at + 1 ..][0..length]);
            written += length;
        } else {
            written += length + 1;
        }
        at += 1 + length;
    }
    if (into) |text| text[written] = 0;
    return after;
}

/// What an answer says.
pub const Answer = struct {
    rcode: u8 = 0,
    /// A records, in network order.
    addresses: [8]u32 = @splat(0),
    count: usize = 0,
    /// The name a PTR record gave, or the answer's own name.
    name: [name_max + 1]u8 = @splat(0),
    has_name: bool = false,
    /// The shortest time to live of what was taken, in seconds.
    ttl: u32 = 0xFFFF_FFFF,
};

/// The answer to our question `id` of `kind` read out of `packet`; null
/// if it is not one - another id, not an answer, a record cut short, a
/// name that leads outside.
pub fn answer(packet: []const u8, id: u16, kind: u16) ?Answer {
    if (packet.len < 12) return null;
    if (_ip.get16(packet, 0) != id or packet[2] & 0x80 == 0) return null;
    var result: Answer = .{ .rcode = packet[3] & 0x0F };
    const questions = _ip.get16(packet, 4);
    const answers = _ip.get16(packet, 6);
    var at: usize = 12;
    var index: usize = 0;
    while (index < questions) : (index += 1) {
        at = readName(packet, at, null) orelse return null;
        if (at + 4 > packet.len) return null;
        at += 4;
    }
    index = 0;
    while (index < answers) : (index += 1) {
        at = readName(packet, at, null) orelse return null;
        if (at + 10 > packet.len) return null;
        const record_type = _ip.get16(packet, at);
        const record_class = _ip.get16(packet, at + 2);
        const ttl = _ip.get32(packet, at + 4);
        const length = _ip.get16(packet, at + 8);
        at += 10;
        if (at + length > packet.len) return null;
        const data = packet[at..][0..length];
        if (record_class == class_in and record_type == kind) {
            if (kind == type_a and length == 4 and result.count < result.addresses.len) {
                result.addresses[result.count] = @bitCast(data[0..4].*);
                result.count += 1;
                result.ttl = @min(result.ttl, ttl);
            } else if (kind == type_ptr and !result.has_name) {
                if (readName(packet, at, &result.name) == null) return null;
                result.has_name = true;
                result.ttl = @min(result.ttl, ttl);
            }
        }
        at += length;
    }
    return result;
}
