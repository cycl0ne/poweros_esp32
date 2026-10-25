// SPDX-License-Identifier: MIT
//! SPNEGO ([MS-SPNG], RFC 4178), as much of it as carries NTLMSSP's
//! messages in SESSION_SETUP: a DER wrapper around each.
//!
//! The first message is the GSS-API token around a NegTokenInit that
//! offers NTLMSSP and carries its NEGOTIATE; each one after it is a
//! NegTokenResp carrying the next NTLMSSP message, and the server's
//! answers are NegTokenResps whose responseToken is its CHALLENGE. The
//! server's NegTokenResp may say more - its state, the mechanism it took,
//! a mechListMIC - of which only the state is looked at: a reject ends
//! the logon. With no MIC in the AUTHENTICATE message, no server asks for
//! a mechListMIC.
//!
//! A DER element is a tag, a length - one byte below 128, else 0x8n and n
//! bytes of it - and that many bytes. Lengths are written in the long form
//! whenever they reach 128, which every reader takes.

const wire = @import("wire.zig");
const Writer = wire.Writer;

/// SPNEGO's OID, 1.3.6.1.5.5.2, and NTLMSSP's, 1.3.6.1.4.1.311.2.2.10,
/// as DER writes them.
const oid_spnego = [_]u8{ 0x06, 0x06, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x02 };
const oid_ntlmssp = [_]u8{ 0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0A };

/// negState's values.
pub const accept_completed: u8 = 0;
pub const accept_incomplete: u8 = 1;
pub const reject: u8 = 2;

/// An element begun: its tag written, room for a 3-byte long length kept,
/// to be filled in by `close`.
const Open = struct { at: usize };

fn open(writer: *Writer, tag: u8) Open {
    writer.byte(tag);
    const at = writer.at;
    writer.zeros(3);
    return .{ .at = at };
}

/// The element's length written into the room `open` kept. Below 128 it
/// takes one byte, so what was written after the room moves down.
fn close(writer: *Writer, begun: Open) void {
    if (writer.full) return;
    const content_at = begun.at + 3;
    const length = writer.at - content_at;
    if (length < 128) {
        writer.bytes[begun.at] = @intCast(length);
        // The content two bytes nearer: forwards, which a copy that runs
        // from the start may do.
        var at: usize = 0;
        while (at < length) : (at += 1) writer.bytes[begun.at + 1 + at] = writer.bytes[content_at + at];
        writer.at -= 2;
        return;
    }
    writer.bytes[begun.at] = 0x82;
    writer.bytes[begun.at + 1] = @intCast(length >> 8);
    writer.bytes[begun.at + 2] = @truncate(length);
}

/// The first token: GSS-API's wrapper, NegTokenInit offering NTLMSSP and
/// carrying `token`, its NEGOTIATE. `token` is written by `write`, so it
/// goes in place.
pub fn writeInit(writer: *Writer, write: *const fn (*Writer) void) void {
    const gss = open(writer, 0x60);
    writer.raw(&oid_spnego);
    const init = open(writer, 0xA0);
    const sequence = open(writer, 0x30);
    const mech_types = open(writer, 0xA0);
    const mech_list = open(writer, 0x30);
    writer.raw(&oid_ntlmssp);
    close(writer, mech_list);
    close(writer, mech_types);
    const mech_token = open(writer, 0xA2);
    const octets = open(writer, 0x04);
    write(writer);
    close(writer, octets);
    close(writer, mech_token);
    close(writer, sequence);
    close(writer, init);
    close(writer, gss);
}

/// A NegTokenResp carrying `token` as its responseToken: its first byte's
/// place, for the caller to write the token into after `beginResponse`,
/// then `endResponse`.
pub const Response = struct { resp: Open, sequence: Open, token: Open, octets: Open };

pub fn beginResponse(writer: *Writer) Response {
    const resp = open(writer, 0xA1);
    const sequence = open(writer, 0x30);
    const token = open(writer, 0xA2);
    const octets = open(writer, 0x04);
    return .{ .resp = resp, .sequence = sequence, .token = token, .octets = octets };
}

pub fn endResponse(writer: *Writer, response: Response) void {
    close(writer, response.octets);
    close(writer, response.token);
    close(writer, response.sequence);
    close(writer, response.resp);
}

/// What a server's NegTokenResp says.
pub const Answer = struct {
    /// negState, or null when it has none.
    state: ?u8 = null,
    /// responseToken, or empty when it has none.
    token: []const u8 = &.{},
};

/// A DER element read: its tag and its content.
const Element = struct { tag: u8, content: []const u8 };

/// The element at the start of `bytes`, and where the next one starts.
fn element(bytes: []const u8, rest: *[]const u8) ?Element {
    if (bytes.len < 2) return null;
    const tag = bytes[0];
    var length: usize = bytes[1];
    var at: usize = 2;
    if (length >= 0x80) {
        const count = length & 0x7F;
        if (count == 0 or count > 3 or bytes.len < 2 + count) return null;
        length = 0;
        for (bytes[2..][0..count]) |byte| length = (length << 8) | byte;
        at += count;
    }
    if (bytes.len - at < length) return null;
    rest.* = bytes[at + length ..];
    return .{ .tag = tag, .content = bytes[at..][0..length] };
}

/// The server's NegTokenResp, or null when `bytes` are none. A
/// NegTokenInit (a server's first word, in its NEGOTIATE answer) is not
/// one.
pub fn parseResponse(bytes: []const u8) ?Answer {
    var rest: []const u8 = undefined;
    const outer = element(bytes, &rest) orelse return null;
    if (outer.tag != 0xA1) return null;
    const sequence = element(outer.content, &rest) orelse return null;
    if (sequence.tag != 0x30) return null;
    var answer: Answer = .{};
    var fields = sequence.content;
    while (fields.len > 0) {
        const field = element(fields, &fields) orelse return null;
        var inner_rest: []const u8 = undefined;
        const inner = element(field.content, &inner_rest) orelse return null;
        switch (field.tag) {
            // negState: ENUMERATED.
            0xA0 => if (inner.tag == 0x0A and inner.content.len == 1) {
                answer.state = inner.content[0];
            },
            // responseToken: OCTET STRING.
            0xA2 => if (inner.tag == 0x04) {
                answer.token = inner.content;
            },
            else => {},
        }
    }
    return answer;
}

const testing = @import("std").testing;

fn writeFour(writer: *Writer) void {
    writer.raw("NTLM");
}

test "the first token is GSS-API's wrapper around a NegTokenInit offering NTLMSSP" {
    var room: [128]u8 = undefined;
    var writer: Writer = .{ .bytes = &room };
    writeInit(&writer, &writeFour);
    const expected = [_]u8{
        0x60, 0x24, 0x06, 0x06, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x02,
        0xA0, 0x1A, 0x30, 0x18, 0xA0, 0x0E, 0x30, 0x0C, 0x06, 0x0A,
        0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0A,
        0xA2, 0x06, 0x04, 0x04, 'N',  'T',  'L',  'M',
    };
    try testing.expectEqualSlices(u8, &expected, writer.written());
}

test "a NegTokenResp written with a long token reads back" {
    var room: [512]u8 = undefined;
    var writer: Writer = .{ .bytes = &room };
    const response = beginResponse(&writer);
    var token: [300]u8 = undefined;
    for (&token, 0..) |*byte, at| byte.* = @truncate(at);
    writer.raw(&token);
    endResponse(&writer, response);
    // The long forms: 0x82 and two bytes, at every level.
    try testing.expectEqual(@as(u8, 0xA1), room[0]);
    try testing.expectEqual(@as(u8, 0x82), room[1]);
    const answer = parseResponse(writer.written()).?;
    try testing.expectEqual(@as(?u8, null), answer.state);
    try testing.expectEqualSlices(u8, &token, answer.token);
}

test "a server's NegTokenResp: its state and its token" {
    const bytes = [_]u8{
        0xA1, 0x1A, 0x30, 0x18, 0xA0, 0x03, 0x0A, 0x01, 0x01, 0xA1,
        0x0C, 0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37,
        0x02, 0x02, 0x0A, 0xA2, 0x03, 0x04, 0x01, 0x7F,
    };
    const answer = parseResponse(&bytes).?;
    try testing.expectEqual(@as(?u8, accept_incomplete), answer.state);
    try testing.expectEqualSlices(u8, &.{0x7F}, answer.token);
    try testing.expect(parseResponse(bytes[0..10]) == null);
    // A NegTokenInit is not an answer.
    try testing.expect(parseResponse(&.{ 0x60, 0x00 }) == null);
}
