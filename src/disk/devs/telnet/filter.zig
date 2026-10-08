// SPDX-License-Identifier: MIT
//! The Telnet protocol (RFC 854, 857, 858, 1073) taken off a connection's
//! bytes as they come, in pieces cut anywhere: what is left is what was
//! typed. The options it is asked about are answered here too, into the
//! reply it hands back for the connection.
//!
//! **Options.** The unit offers ECHO and SUPPRESS-GO-AHEAD from its side
//! and asks for SUPPRESS-GO-AHEAD and NAWS - the window's size - from the
//! client (`offer`), and holds them as on. From then on an answer goes
//! only where a state changes - a DO for what is on, a WILL agreed to, is
//! not answered - which is what keeps two ends from answering each other
//! for ever (RFC 1143). Any other option is refused, once, as it is
//! asked.
//!
//! **The window's size** comes as a subnegotiation, `IAC SB NAWS` and the
//! columns and rows in two bytes each (a 255 among them doubled), `IAC
//! SE`; again whenever the window changes. Any other subnegotiation is
//! passed over.

pub const iac: u8 = 255;
pub const dont: u8 = 254;
pub const do: u8 = 253;
pub const wont: u8 = 252;
pub const will: u8 = 251;
pub const sb: u8 = 250;
pub const interrupt: u8 = 244;
pub const brk: u8 = 243;
pub const se: u8 = 240;

pub const option_echo: u8 = 1;
pub const option_sga: u8 = 3;
pub const option_naws: u8 = 31;

const ctrl_c: u8 = 0x03;
const cr: u8 = '\r';

/// The bytes a reply holds at the most: three per option answered.
pub const reply_max = 48;

pub const Reply = struct {
    bytes: [reply_max]u8 = undefined,
    length: usize = 0,

    fn put(reply: *Reply, verb: u8, option: u8) void {
        if (reply.length + 3 > reply.bytes.len) return;
        reply.bytes[reply.length..][0..3].* = .{ iac, verb, option };
        reply.length += 3;
    }
};

pub const Filter = struct {
    state: State = .data,
    /// The verb of an option being read.
    verb: u8 = 0,
    /// What this end does (ECHO, SGA), and what the client does (SGA,
    /// NAWS).
    echo: bool = false,
    sga: bool = false,
    client_sga: bool = false,
    client_naws: bool = false,
    /// A subnegotiation being read: its option, and its first bytes.
    sub_option: u8 = 0,
    sub_bytes: [4]u8 = @splat(0),
    sub_length: u8 = 0,
    /// The client's window, as NAWS last said it; 0 until it has.
    columns: u16 = 0,
    rows: u16 = 0,

    const State = enum { data, command, option, cr, sub_start, sub, sub_iac };

    /// The opening offer, and the options held on from now.
    pub fn offer(filter: *Filter, reply: *Reply) void {
        reply.put(will, option_echo);
        reply.put(will, option_sga);
        reply.put(do, option_sga);
        reply.put(do, option_naws);
        filter.echo = true;
        filter.sga = true;
        filter.client_sga = true;
        filter.client_naws = true;
    }

    /// The data in `input` written to `out` - which is at least as long -
    /// and the answers it calls for added to `reply`: how many bytes of
    /// data.
    pub fn feed(filter: *Filter, input: []const u8, out: []u8, reply: *Reply) usize {
        var count: usize = 0;
        for (input) |byte| {
            switch (filter.state) {
                .data => {
                    if (byte == iac) {
                        filter.state = .command;
                        continue;
                    }
                    out[count] = byte;
                    count += 1;
                    if (byte == cr) filter.state = .cr;
                },
                .cr => {
                    // CR LF and CR NUL are one CR; anything else stands.
                    filter.state = .data;
                    if (byte == '\n' or byte == 0) continue;
                    if (byte == iac) {
                        filter.state = .command;
                        continue;
                    }
                    out[count] = byte;
                    count += 1;
                    if (byte == cr) filter.state = .cr;
                },
                .command => {
                    filter.state = .data;
                    switch (byte) {
                        iac => {
                            out[count] = iac;
                            count += 1;
                        },
                        interrupt, brk => {
                            out[count] = ctrl_c;
                            count += 1;
                        },
                        will, wont, do, dont => {
                            filter.verb = byte;
                            filter.state = .option;
                        },
                        sb => filter.state = .sub_start,
                        else => {},
                    }
                },
                .option => {
                    filter.state = .data;
                    filter.answer(filter.verb, byte, reply);
                },
                .sub_start => {
                    filter.sub_option = byte;
                    filter.sub_length = 0;
                    filter.state = .sub;
                },
                .sub => {
                    if (byte == iac) {
                        filter.state = .sub_iac;
                    } else {
                        filter.subByte(byte);
                    }
                },
                .sub_iac => {
                    if (byte == se) {
                        filter.state = .data;
                        filter.subEnded();
                    } else {
                        // IAC IAC: a 255 among the data.
                        filter.state = .sub;
                        if (byte == iac) filter.subByte(byte);
                    }
                },
            }
        }
        return count;
    }

    fn subByte(filter: *Filter, byte: u8) void {
        if (filter.sub_length < filter.sub_bytes.len) filter.sub_bytes[filter.sub_length] = byte;
        filter.sub_length +|= 1;
    }

    /// A subnegotiation whole: NAWS's size kept, anything else passed over.
    fn subEnded(filter: *Filter) void {
        if (filter.sub_option != option_naws or filter.sub_length != 4 or !filter.client_naws) return;
        const bytes = filter.sub_bytes;
        filter.columns = @as(u16, bytes[0]) << 8 | bytes[1];
        filter.rows = @as(u16, bytes[2]) << 8 | bytes[3];
    }

    fn answer(filter: *Filter, verb: u8, option: u8, reply: *Reply) void {
        switch (verb) {
            do => switch (option) {
                option_echo => if (!filter.echo) {
                    filter.echo = true;
                    reply.put(will, option);
                },
                option_sga => if (!filter.sga) {
                    filter.sga = true;
                    reply.put(will, option);
                },
                else => reply.put(wont, option),
            },
            dont => switch (option) {
                option_echo => if (filter.echo) {
                    filter.echo = false;
                    reply.put(wont, option);
                },
                option_sga => if (filter.sga) {
                    filter.sga = false;
                    reply.put(wont, option);
                },
                else => {},
            },
            will => switch (option) {
                option_sga => if (!filter.client_sga) {
                    filter.client_sga = true;
                    reply.put(do, option);
                },
                option_naws => if (!filter.client_naws) {
                    filter.client_naws = true;
                    reply.put(do, option);
                },
                else => reply.put(dont, option),
            },
            wont => switch (option) {
                option_sga => if (filter.client_sga) {
                    filter.client_sga = false;
                    reply.put(dont, option);
                },
                option_naws => if (filter.client_naws) {
                    filter.client_naws = false;
                    filter.columns = 0;
                    filter.rows = 0;
                    reply.put(dont, option);
                },
                else => {},
            },
            else => {},
        }
    }
};

/// `data` as it goes out, 255 doubled, into `out` (twice as long at the
/// most): how many bytes.
pub fn escape(data: []const u8, out: []u8) usize {
    var count: usize = 0;
    for (data) |byte| {
        out[count] = byte;
        count += 1;
        if (byte == iac) {
            out[count] = iac;
            count += 1;
        }
    }
    return count;
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

/// `input` fed in two pieces, cut at `cut`.
fn run(filter: *Filter, input: []const u8, cut: usize, reply: *Reply) ![]const u8 {
    const State = struct {
        var out: [128]u8 = undefined;
    };
    var count = filter.feed(input[0..cut], &State.out, reply);
    count += filter.feed(input[cut..], State.out[count..], reply);
    return State.out[0..count];
}

test "commands out of the data, cut anywhere" {
    const input = "ab\xff\xffc\r\nd\r\x00e\xff\xf4f\xff\xfa\x18\x01\xff\xff\xff\xf0g\xff\xf1h\rx";
    var cut: usize = 0;
    while (cut <= input.len) : (cut += 1) {
        var filter: Filter = .{};
        var reply: Reply = .{};
        const got = try run(&filter, input, cut, &reply);
        try testing.expectEqualStrings("ab\xffc\rd\re\x03fgh\rx", got);
        try testing.expectEqual(@as(usize, 0), reply.length);
    }
}

test "options: the offer, agreement unanswered, changes answered, the rest refused" {
    var filter: Filter = .{};
    var reply: Reply = .{};
    filter.offer(&reply);
    try testing.expectEqualSlices(u8, &.{ iac, will, option_echo, iac, will, option_sga, iac, do, option_sga, iac, do, option_naws }, reply.bytes[0..reply.length]);
    reply = .{};
    var out: [16]u8 = undefined;
    // The client agrees: nothing to say.
    _ = filter.feed(&.{ iac, do, option_echo, iac, do, option_sga, iac, will, option_sga }, &out, &reply);
    try testing.expectEqual(@as(usize, 0), reply.length);
    // It will send its window's size, as asked: nothing to say; it asks
    // for the terminal type: refused.
    _ = filter.feed(&.{ iac, will, option_naws, iac, do, 24 }, &out, &reply);
    try testing.expectEqualSlices(u8, &.{ iac, wont, 24 }, reply.bytes[0..reply.length]);
    reply = .{};
    // It does not want the echo: agreed once, and not again.
    _ = filter.feed(&.{ iac, dont, option_echo, iac, dont, option_echo }, &out, &reply);
    try testing.expectEqualSlices(u8, &.{ iac, wont, option_echo }, reply.bytes[0..reply.length]);
    try testing.expect(!filter.echo);
}

test "the window's size: NAWS read, cut anywhere, a 255 doubled, again when it changes" {
    const input = "a\xff\xfa\x1f\x00\x50\x00\x18\xff\xf0b\xff\xfa\x1f\x00\xff\xff\x00\x30\xff\xf0c\xff\xfa\x18\x00x\xff\xf0";
    var cut: usize = 0;
    while (cut <= input.len) : (cut += 1) {
        var filter: Filter = .{};
        var reply: Reply = .{};
        filter.offer(&reply);
        const got = try run(&filter, input, cut, &reply);
        try testing.expectEqualStrings("abc", got);
        // 80 by 24 first, then 255 by 48; the terminal type's passed over.
        try testing.expectEqual(@as(u16, 255), filter.columns);
        try testing.expectEqual(@as(u16, 48), filter.rows);
    }
    var filter: Filter = .{};
    var reply: Reply = .{};
    filter.offer(&reply);
    var out: [16]u8 = undefined;
    _ = filter.feed("\xff\xfa\x1f\x00\x50\x00\x18\xff\xf0", &out, &reply);
    try testing.expectEqual(@as(u16, 80), filter.columns);
    // The client stops sending its size: none known.
    reply = .{};
    _ = filter.feed(&.{ iac, wont, option_naws }, &out, &reply);
    try testing.expectEqual(@as(u16, 0), filter.columns);
    try testing.expectEqualSlices(u8, &.{ iac, dont, option_naws }, reply.bytes[0..reply.length]);
}

test "255 goes out doubled" {
    var out: [8]u8 = undefined;
    const count = escape("a\xffb", &out);
    try testing.expectEqualSlices(u8, "a\xff\xffb", out[0..count]);
}
