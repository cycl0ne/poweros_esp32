// SPDX-License-Identifier: MPL-2.0
//! What the text calls share: UTF-8 read a character at a time, strictly
//! - no overlong forms, no surrogates, nothing past U+10FFFF - and the
//! plain characters typesetting's stand for.

const std = @import("std");

/// What `decode` found at the start of the bytes.
pub const Step = struct {
    kind: Kind,
    /// The character, for `.char`.
    char: u32 = 0,
    /// The bytes it took: the character's, or 1 for a broken byte; for
    /// `.short`, the bytes there are.
    length: usize,

    pub const Kind = enum {
        /// A character.
        char,
        /// A byte that starts no character, or a sequence broken off
        /// before its end: the one byte, which a caller takes as it is,
        /// or as `?`.
        broken,
        /// The bytes end inside a sequence that is right so far.
        short,
    };
};

/// The UTF-8 character `bytes` start with; `bytes` holds at least one.
pub fn decode(bytes: []const u8) Step {
    const lead = bytes[0];
    if (lead < 0x80) return .{ .kind = .char, .char = lead, .length = 1 };
    // How many bytes follow, and the range the first of them must be in:
    // what keeps out overlong forms, surrogates and what is past U+10FFFF.
    var follow: usize = 0;
    var low: u8 = 0x80;
    var high: u8 = 0xBF;
    switch (lead) {
        0xC2...0xDF => follow = 1,
        0xE0 => {
            follow = 2;
            low = 0xA0;
        },
        0xE1...0xEC, 0xEE, 0xEF => follow = 2,
        0xED => {
            follow = 2;
            high = 0x9F;
        },
        0xF0 => {
            follow = 3;
            low = 0x90;
        },
        0xF1...0xF3 => follow = 3,
        0xF4 => {
            follow = 3;
            high = 0x8F;
        },
        else => return .{ .kind = .broken, .length = 1 },
    }
    var char: u32 = lead & (@as(u8, 0x3F) >> @intCast(follow));
    var index: usize = 1;
    while (index <= follow) : (index += 1) {
        if (index == bytes.len) return .{ .kind = .short, .length = bytes.len };
        const byte = bytes[index];
        const first = index == 1;
        if (byte < (if (first) low else 0x80) or byte > (if (first) high else 0xBF)) return .{ .kind = .broken, .length = 1 };
        char = char << 6 | (byte & 0x3F);
    }
    return .{ .kind = .char, .char = char, .length = follow + 1 };
}

/// The plain characters a character of typesetting stands for: "" for a
/// mark of no width; null for one that is none of them.
pub fn plain(char: u32) ?[]const u8 {
    return switch (char) {
        0x2018, 0x2019, 0x201A, 0x201B, 0x2032 => "'",
        0x201C, 0x201D, 0x201E, 0x201F, 0x2033 => "\"",
        0x2010...0x2015, 0x2212 => "-",
        0x2026 => "...",
        0x2000...0x200A, 0x202F, 0x205F => " ",
        0x200B...0x200F, 0xFEFF => "",
        else => null,
    };
}

/// The byte order mark, which a text may start with.
pub const byte_order_mark = "\xEF\xBB\xBF";

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "decode: characters of every length, and what is no UTF-8" {
    try testing.expectEqual(Step{ .kind = .char, .char = 'A', .length = 1 }, decode("A"));
    try testing.expectEqual(Step{ .kind = .char, .char = 0xE4, .length = 2 }, decode("\xC3\xA4"));
    try testing.expectEqual(Step{ .kind = .char, .char = 0x20AC, .length = 3 }, decode("\xE2\x82\xAC"));
    try testing.expectEqual(Step{ .kind = .char, .char = 0x1F600, .length = 4 }, decode("\xF0\x9F\x98\x80"));
    try testing.expectEqual(Step{ .kind = .char, .char = 0x10FFFF, .length = 4 }, decode("\xF4\x8F\xBF\xBF"));
    // Cut short: right so far.
    try testing.expectEqual(Step.Kind.short, decode("\xE2\x82").kind);
    try testing.expectEqual(@as(usize, 2), decode("\xE2\x82").length);
    try testing.expectEqual(Step.Kind.short, decode("\xF0").kind);
    // Broken: a stray continuation, an overlong form, a surrogate, past
    // U+10FFFF, a lead whose next byte is no continuation.
    for ([_][]const u8{ "\x80", "\xBF", "\xC0\x80", "\xC1\xBF", "\xE0\x80\x80", "\xED\xA0\x80", "\xF0\x80\x80\x80", "\xF4\x90\x80\x80", "\xF5\x80", "\xFF", "\xC3A", "\xE2\x82A" }) |bytes| {
        const step = decode(bytes);
        try testing.expectEqual(Step.Kind.broken, step.kind);
        try testing.expectEqual(@as(usize, 1), step.length);
    }
}
