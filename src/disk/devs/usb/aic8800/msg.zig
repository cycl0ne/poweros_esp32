// SPDX-License-Identifier: MIT
//! What goes over the AIC8800's bulk endpoints: a message to the
//! firmware put into a transfer, and the records a transfer from it
//! holds. Everything little-endian.
//!
//! **A message out** is a 4-byte USB header - the length past its first
//! four bytes in 12 bits, the type 0x11 - a word of nothing, then the
//! message's own header: its id, the task it is for, the task it is
//! from (the host's, 100) and the length of its parameters, which
//! follow. A message's id is its task in the top six bits and its number
//! in that task below (`id`).
//!
//! **A transfer in** holds records, each beginning with its length and a
//! type: a message - a confirmation of a request, or an indication - with
//! the same header as one sent (`Record.message`); a frame received, an
//! 802.11 frame behind a 56-byte header of what the radio saw and four
//! bytes of alignment (`Record.frame`); the status of a frame sent; a line
//! of the firmware's own log. Records follow one another, a message's
//! rounded up to four bytes.

/// The tasks a message is for.
pub const TASK_MM: u16 = 0;
pub const TASK_DBG: u16 = 1;
pub const TASK_SCANU: u16 = 4;
pub const TASK_ME: u16 = 5;
pub const TASK_SM: u16 = 6;
/// The host's task: the `src` of every message sent.
pub const TASK_HOST: u16 = 100;

/// A message's id: its task and its number in it.
pub fn id(task: u16, index: u16) u16 {
    return task << 10 | index;
}

/// The types in a record's third byte.
pub const TYPE_DATA: u8 = 0x01;
pub const TYPE_MESSAGE: u8 = 0x11;
pub const TYPE_TX_STATUS: u8 = 0x12;
pub const TYPE_LOG: u8 = 0x13;

/// The bytes before a message's parameters, sent or received.
pub const header_bytes = 16;
/// The bytes before a received frame's 802.11 header.
pub const frame_header_bytes = 60;

fn put16(into: []u8, at: usize, value: u16) void {
    into[at] = @truncate(value);
    into[at + 1] = @truncate(value >> 8);
}

pub fn get16(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) | @as(u16, bytes[at + 1]) << 8;
}

pub fn get32(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) | @as(u32, bytes[at + 1]) << 8 | @as(u32, bytes[at + 2]) << 16 | @as(u32, bytes[at + 3]) << 24;
}

pub fn put32(into: []u8, at: usize, value: u32) void {
    into[at] = @truncate(value);
    into[at + 1] = @truncate(value >> 8);
    into[at + 2] = @truncate(value >> 16);
    into[at + 3] = @truncate(value >> 24);
}

/// Message `msg_id` for task `dest` with `params` into `into`: how many
/// bytes the transfer is, 0 when it does not fit.
pub fn request(into: []u8, msg_id: u16, dest: u16, params: []const u8) usize {
    const total = header_bytes + params.len;
    if (total > into.len or total - 4 > 0x0FFF) return 0;
    put16(into, 0, @intCast(total - 4));
    into[2] = TYPE_MESSAGE;
    into[3] = 0;
    put32(into, 4, 0);
    put16(into, 8, msg_id);
    put16(into, 10, dest);
    put16(into, 12, TASK_HOST);
    put16(into, 14, @intCast(params.len));
    @memcpy(into[header_bytes..][0..params.len], params);
    return total;
}

/// How messages reach the chip and its transfers come back: the caller's
/// - USB pipes on the stick, a pretend chip in the tests.
pub const Transport = struct {
    context: *anyopaque,
    /// A whole transfer out: whether it went.
    send: *const fn (context: *anyopaque, bytes: []const u8) bool,
    /// One transfer in, into `into`: how many bytes, null when nothing
    /// came in time.
    receive: *const fn (context: *anyopaque, into: []u8) ?usize,
    /// A pause, in milliseconds.
    wait: *const fn (context: *anyopaque, ms: u32) void,
    /// A line of the chip's own log.
    say: *const fn (context: *anyopaque, text: []const u8) void,
};

/// One record of a transfer in.
pub const Record = union(enum) {
    /// A confirmation or an indication.
    message: struct { id: u16, dest: u16, src: u16, params: []const u8 },
    /// A frame received: the radio's header, then the 802.11 frame.
    frame: struct { header: []const u8, frame: []const u8 },
    /// What became of a frame sent: its status word and the index it was
    /// sent with.
    tx_status: struct { status: u32, index: u32 },
    /// A line of the firmware's own log.
    log: []const u8,
    /// A record of a type nothing here reads.
    other,
};

/// The records of a transfer in, one at a time.
pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn next(reader: *Reader) ?Record {
        const rest = reader.bytes[reader.at..];
        if (rest.len < 4) return null;
        const length: usize = get16(rest, 0) & 0x0FFF;
        const kind = rest[2];
        if (length == 0) return null;
        if (kind & 0x10 == 0) {
            const total = frame_header_bytes + length;
            if (total > rest.len) return null;
            reader.at += total;
            return .{ .frame = .{ .header = rest[0 .. frame_header_bytes - 4], .frame = rest[frame_header_bytes..total] } };
        }
        const total = 4 + length;
        if (total > rest.len) return null;
        reader.at += (total + 3) & ~@as(usize, 3);
        const body = rest[0..total];
        return switch (kind & 0x7F) {
            TYPE_MESSAGE => blk: {
                if (body.len < header_bytes) break :blk .other;
                const params_len = @min(get16(body, 10), body.len - header_bytes);
                break :blk .{ .message = .{
                    .id = get16(body, 4),
                    .dest = get16(body, 6),
                    .src = get16(body, 8),
                    .params = body[header_bytes..][0..params_len],
                } };
            },
            TYPE_TX_STATUS => if (body.len >= 12) .{ .tx_status = .{ .status = get32(body, 4), .index = get32(body, 8) } } else .other,
            TYPE_LOG => .{ .log = body[4..] },
            else => .other,
        };
    }
};

// --- tests --------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "a request: the USB header, the message header, the parameters" {
    var out: [64]u8 = undefined;
    const params = [_]u8{ 0x00, 0x00, 0x50, 0x40 };
    const length = request(&out, id(TASK_DBG, 0), TASK_DBG, &params);
    try testing.expectEqual(@as(usize, 20), length);
    try testing.expectEqualSlices(u8, &.{
        16, 0, 0x11, 0, 0, 0, 0, 0, // length past the first four, type, a word of nothing
        0x00, 0x04, 0x01, 0x00, 100, 0, 4, 0, // DBG_MEM_READ_REQ for TASK_DBG from the host, 4 bytes
        0x00, 0x00, 0x50, 0x40,
    }, out[0..length]);
}

test "a transfer of a log line and a confirmation, records rounded to four" {
    var in: [64]u8 = @splat(0);
    // A log line of 3 bytes: rounded to 8.
    in[0] = 3;
    in[2] = TYPE_LOG | 0x80;
    @memcpy(in[4..7], "hi\n");
    // DBG_MEM_READ_CFM: memaddr, memdata.
    const at = 8;
    put16(&in, at, 12 + 8);
    in[at + 2] = TYPE_MESSAGE;
    put16(&in, at + 4, id(TASK_DBG, 1));
    put16(&in, at + 6, TASK_HOST);
    put16(&in, at + 8, TASK_DBG);
    put16(&in, at + 10, 8);
    put32(&in, at + 16, 0x40500000);
    put32(&in, at + 20, 0x00070000);
    var reader = Reader{ .bytes = in[0 .. at + 24] };
    const first = reader.next().?;
    try testing.expectEqualStrings("hi\n", first.log);
    const second = reader.next().?.message;
    try testing.expectEqual(id(TASK_DBG, 1), second.id);
    try testing.expectEqual(@as(u32, 0x00070000), get32(second.params, 4));
    try testing.expect(reader.next() == null);
}

test "a frame record: the radio's header, then the 802.11 frame" {
    var in: [96]u8 = @splat(0);
    put16(&in, 0, 24);
    in[2] = 0;
    in[60] = 0x08; // a data frame's frame control
    var reader = Reader{ .bytes = in[0 .. 60 + 24] };
    const frame = reader.next().?.frame;
    try testing.expectEqual(@as(usize, 24), frame.frame.len);
    try testing.expectEqual(@as(u8, 0x08), frame.frame[0]);
    try testing.expect(reader.next() == null);
}
