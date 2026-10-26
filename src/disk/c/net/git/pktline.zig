// SPDX-License-Identifier: MIT
//! pkt-lines, how git's protocol frames what it says: four hex digits of
//! length - their own four counted - and the data, at most 65516 bytes
//! of it. `0000` is a flush, `0001` a delimiter and `0002` the end of a
//! response (protocol version 2).
//!
//! **A reader** takes its bytes from a source - an answer's body, an SSH
//! channel - as they come, and hands out one packet at a time, its data
//! in the reader's buffer until the next.

const _git = @import("_git.zig");

/// The most data one packet carries.
pub const data_most = 65516;
/// The room a reader needs: the longest packet's data.
pub const buffer_bytes = data_most;

pub const flush = "0000";
pub const delim = "0001";
pub const response_end = "0002";

pub const Kind = enum { data, flush, delim, response_end };

/// What a packet's four digits say: its kind, and for data how many
/// bytes follow; null when they are no length.
pub fn lengthOf(head: *const [4]u8) ?struct { kind: Kind, length: usize } {
    var value: usize = 0;
    for (head) |char| {
        const nibble: usize = switch (char) {
            '0'...'9' => char - '0',
            'a'...'f' => char - 'a' + 10,
            'A'...'F' => char - 'A' + 10,
            else => return null,
        };
        value = value * 16 + nibble;
    }
    return switch (value) {
        0 => .{ .kind = .flush, .length = 0 },
        1 => .{ .kind = .delim, .length = 0 },
        2 => .{ .kind = .response_end, .length = 0 },
        3 => null,
        else => if (value - 4 > data_most) null else .{ .kind = .data, .length = value - 4 },
    };
}

/// `data` as one packet into `out`.
pub fn put(out: *_git.Out, data: []const u8) void {
    if (data.len > data_most) {
        out.overflow = true;
        return;
    }
    const length = data.len + 4;
    const digits = "0123456789abcdef";
    out.put(&.{ digits[length >> 12], digits[length >> 8 & 15], digits[length >> 4 & 15], digits[length & 15] });
    out.put(data);
}

/// A packet made of pieces, written as one: `want <id>\n` and the like.
pub fn putParts(out: *_git.Out, parts: []const []const u8) void {
    var length: usize = 0;
    for (parts) |part| length += part.len;
    if (length > data_most) {
        out.overflow = true;
        return;
    }
    const total = length + 4;
    const digits = "0123456789abcdef";
    out.put(&.{ digits[total >> 12], digits[total >> 8 & 15], digits[total >> 4 & 15], digits[total & 15] });
    for (parts) |part| out.put(part);
}

/// Where a reader's bytes come from.
pub const Source = struct {
    context: *anyopaque,
    /// Bytes into `into`: how many, 0 at the end, below 0 a failure.
    read: *const fn (context: *anyopaque, into: []u8) i32,
};

/// What a reader hands out.
pub const Packet = struct {
    kind: Kind,
    /// The data, in the reader's buffer until the next packet.
    data: []u8 = &.{},
};

pub const Error = enum { none, failed, ended, malformed };

pub const Reader = struct {
    source: Source,
    /// At least `buffer_bytes`.
    buffer: []u8,
    /// Bytes read past what was asked for, waiting for the next read:
    /// `ahead[ahead_at..][0..ahead_length]`.
    ahead: [512]u8 = undefined,
    ahead_at: usize = 0,
    ahead_length: usize = 0,
    /// Why `next` answered null.
    failure: Error = .none,
    /// The source's own code, for `failed`.
    code: i32 = 0,

    /// The next packet; null at the source's end or when something
    /// failed (`failure`).
    pub fn next(reader: *Reader) ?Packet {
        var head: [4]u8 = undefined;
        if (!reader.fill(&head, true)) return null;
        const length = lengthOf(&head) orelse {
            reader.failure = .malformed;
            return null;
        };
        if (length.kind != .data) return .{ .kind = length.kind };
        if (!reader.fill(reader.buffer[0..length.length], false)) return null;
        return .{ .kind = .data, .data = reader.buffer[0..length.length] };
    }

    /// `into` filled from what waits and then the source. An end before
    /// any byte of a packet's head is the source's end; anywhere else it
    /// cuts a packet short.
    fn fill(reader: *Reader, into: []u8, at_head: bool) bool {
        var at: usize = 0;
        while (at < into.len) {
            if (reader.ahead_length > 0) {
                const count = @min(into.len - at, reader.ahead_length);
                @memcpy(into[at..][0..count], reader.ahead[reader.ahead_at..][0..count]);
                reader.ahead_at += count;
                reader.ahead_length -= count;
                at += count;
                continue;
            }
            // Small reads go through `ahead`, so a source that hands
            // over more than was asked for keeps nothing back.
            const want = into.len - at;
            if (want < reader.ahead.len) {
                const got = reader.source.read(reader.source.context, &reader.ahead);
                if (!reader.took(got, at_head and at == 0)) return false;
                reader.ahead_at = 0;
                reader.ahead_length = @intCast(got);
            } else {
                const got = reader.source.read(reader.source.context, into[at..]);
                if (!reader.took(got, at_head and at == 0)) return false;
                at += @intCast(got);
            }
        }
        return true;
    }

    fn took(reader: *Reader, got: i32, clean_end: bool) bool {
        if (got < 0) {
            reader.failure = .failed;
            reader.code = got;
            return false;
        }
        if (got == 0) {
            reader.failure = if (clean_end) .ended else .malformed;
            return false;
        }
        return true;
    }

    /// The bytes that wait in the reader, read past the last packet: what
    /// follows the packets on the same source (a pack after v0's NAK)
    /// takes them first.
    pub fn leftOver(reader: *Reader) []const u8 {
        return reader.ahead[reader.ahead_at..][0..reader.ahead_length];
    }

    /// The bytes `leftOver` answered, gone.
    pub fn dropLeftOver(reader: *Reader) void {
        reader.ahead_length = 0;
    }
};

/// A packet's data without the line feed that ends a text line.
pub fn line(data: []const u8) []const u8 {
    if (data.len > 0 and data[data.len - 1] == '\n') return data[0 .. data.len - 1];
    return data;
}
