// SPDX-License-Identifier: MIT
//! PEM: certificates as people pass them around - base64 between
//! `-----BEGIN CERTIFICATE-----` and `-----END CERTIFICATE-----` lines,
//! as many as a file holds, and anything outside them (comments,
//! headers) ignored.

const begin = "-----BEGIN CERTIFICATE-----";
const end = "-----END CERTIFICATE-----";

/// The certificates of a PEM text, one after another, each decoded into
/// the caller's buffer.
pub const Blocks = struct {
    text: []const u8,

    pub fn of(text: []const u8) Blocks {
        return .{ .text = text };
    }

    /// The next certificate's DER, decoded into `buffer`; null when there
    /// is none, or it does not fit, or is not base64.
    pub fn next(blocks: *Blocks, buffer: []u8) ?[]u8 {
        const start = find(blocks.text, begin) orelse return null;
        const after = blocks.text[start + begin.len ..];
        const stop = find(after, end) orelse return null;
        blocks.text = after[stop + end.len ..];
        return decode(after[0..stop], buffer);
    }
};

fn find(text: []const u8, word: []const u8) ?usize {
    if (text.len < word.len) return null;
    var at: usize = 0;
    while (at + word.len <= text.len) : (at += 1) {
        var same = true;
        for (word, 0..) |char, index| {
            if (text[at + index] != char) {
                same = false;
                break;
            }
        }
        if (same) return at;
    }
    return null;
}

fn value(char: u8) ?u32 {
    return switch (char) {
        'A'...'Z' => char - 'A',
        'a'...'z' => char - 'a' + 26,
        '0'...'9' => char - '0' + 52,
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

/// Base64 into `out`, white space skipped and `=` ending it; the bytes,
/// or null for anything else or too little room.
pub fn decode(text: []const u8, out: []u8) ?[]u8 {
    var bits: u32 = 0;
    var count: u32 = 0;
    var written: usize = 0;
    var ended = false;
    for (text) |char| {
        switch (char) {
            ' ', '\t', '\r', '\n' => continue,
            '=' => {
                ended = true;
                continue;
            },
            else => {},
        }
        if (ended) return null;
        bits = bits << 6 | (value(char) orelse return null);
        count += 6;
        if (count >= 8) {
            count -= 8;
            if (written == out.len) return null;
            out[written] = @truncate(bits >> @intCast(count));
            written += 1;
        }
    }
    return out[0..written];
}
