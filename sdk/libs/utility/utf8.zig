// SPDX-License-Identifier: MIT
//! UTF-8 a character at a time: what every part of the system that reads
//! a name or a text decodes it with, so that a byte means the same
//! character everywhere.
//!
//! `decode` is strict - no overlong forms, no surrogates, nothing past
//! U+10FFFF - and says what it found: a character, a broken byte, or bytes
//! that end inside a character. `read` is how text is shown and compared:
//! it always answers a character. A byte that is no UTF-8 reads as the
//! Latin-1 character of its value while `broken_reads_latin1` is set,
//! which keeps what is still written in Latin-1 readable; without it a
//! broken sequence is one U+FFFD and the byte that broke it is read again,
//! so a control after it is never swallowed. `encode` writes a character
//! back.
//!
//! These are a few lines that run per character inside drawing and
//! matching loops, where a library call each would cost a jump per
//! character; whole-text work is utility.library's.

/// Whether a byte that is no UTF-8 reads as its Latin-1 character (true)
/// or as U+FFFD (false).
pub const broken_reads_latin1 = true;

/// What stands for a byte that is no UTF-8.
pub const replacement: u32 = 0xFFFD;

/// The largest code point.
pub const last: u32 = 0x10FFFF;

/// The byte order mark, which a text may start with.
pub const byte_order_mark = "\xEF\xBB\xBF";

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
        /// before its end: the one byte.
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

/// A character as `read` found it.
pub const Read = struct {
    char: u32,
    /// The bytes it took, at least 1.
    length: usize,
    /// It stands for bytes that are no UTF-8.
    broken: bool = false,
};

/// The character text shows at the start of `bytes` (at least one): the
/// UTF-8 character there, or for bytes that are no UTF-8 what
/// `broken_reads_latin1` says.
pub fn read(bytes: []const u8) Read {
    return readAs(bytes, broken_reads_latin1);
}

/// `read`, with the reading of broken bytes given: `latin1` reads each as
/// its Latin-1 character, else a broken sequence - its lead and the
/// continuation bytes that followed it - is one U+FFFD.
pub fn readAs(bytes: []const u8, latin1: bool) Read {
    const step = decode(bytes);
    if (step.kind == .char) return .{ .char = step.char, .length = step.length };
    if (latin1) return .{ .char = bytes[0], .length = 1, .broken = true };
    var length: usize = 1;
    if (bytes[0] >= 0xC0) {
        while (length < bytes.len and length < 4 and bytes[length] & 0xC0 == 0x80) length += 1;
    }
    return .{ .char = replacement, .length = length, .broken = true };
}

/// The character `bytes` end with (at least one byte), read as `read`
/// reads it from its start: how text is walked back from its end. The
/// UTF-8 character ending there, when its bytes are all there and whole;
/// else the last byte alone, read as a byte that is no UTF-8 - or, while
/// broken bytes read as U+FFFD, the broken sequence it ends.
pub fn readLast(bytes: []const u8) Read {
    var start = bytes.len - 1;
    while (start > 0 and bytes.len - start < 4 and bytes[start] & 0xC0 == 0x80) start -= 1;
    const found = read(bytes[start..]);
    if (found.length == bytes.len - start) return found;
    return read(bytes[bytes.len - 1 ..]);
}

/// `read` at the start of a NUL-terminated string that is not at its end.
pub fn readZ(text: [*:0]const u8) Read {
    var length: usize = 1;
    while (length < 4 and text[length] != 0) length += 1;
    return read(text[0..length]);
}

/// The character at `bytes[at.*]`, `at` moved past it.
pub fn next(bytes: []const u8, at: *usize) u32 {
    const found = read(bytes[at.*..]);
    at.* += found.length;
    return found.char;
}

/// The bytes a character takes in UTF-8.
pub fn lengthOf(char: u32) usize {
    if (char < 0x80) return 1;
    if (char < 0x800) return 2;
    if (char < 0x10000) return 3;
    return 4;
}

/// A character as UTF-8 into `into`; the bytes it took. A surrogate or a
/// value past U+10FFFF is written as U+FFFD.
pub fn encode(char: u32, into: *[4]u8) usize {
    const code = if (char > last or (char >= 0xD800 and char <= 0xDFFF)) replacement else char;
    if (code < 0x80) {
        into[0] = @intCast(code);
        return 1;
    }
    if (code < 0x800) {
        into[0] = @intCast(0xC0 | (code >> 6));
        into[1] = @intCast(0x80 | (code & 0x3F));
        return 2;
    }
    if (code < 0x10000) {
        into[0] = @intCast(0xE0 | (code >> 12));
        into[1] = @intCast(0x80 | ((code >> 6) & 0x3F));
        into[2] = @intCast(0x80 | (code & 0x3F));
        return 3;
    }
    into[0] = @intCast(0xF0 | (code >> 18));
    into[1] = @intCast(0x80 | ((code >> 12) & 0x3F));
    into[2] = @intCast(0x80 | ((code >> 6) & 0x3F));
    into[3] = @intCast(0x80 | (code & 0x3F));
    return 4;
}

/// How many of `bytes` a cut to at most `limit` bytes keeps without ending
/// inside a character: `limit`, or less when a UTF-8 character starts
/// before it and ends after it - a whole one, or one right so far where
/// `bytes` end. Bytes that are no UTF-8 are characters of one byte and
/// are cut anywhere, so Latin-1 text is cut where it is asked to be.
pub fn cut(bytes: []const u8, limit: usize) usize {
    if (limit >= bytes.len) return bytes.len;
    var start = limit;
    while (start > 0 and limit - start < 3 and bytes[start] & 0xC0 == 0x80) start -= 1;
    if (start == limit) return limit;
    const step = decode(bytes[start..]);
    if (step.kind != .broken and start + step.length > limit) return start;
    return limit;
}

/// `bytes` into `into`, as many whole characters as fit: the length
/// copied.
pub fn copyCut(bytes: []const u8, into: []u8) usize {
    const length = cut(bytes, into.len);
    @memcpy(into[0..length], bytes[0..length]);
    return length;
}

/// Latin-1 `bytes` as UTF-8 into `into`, as many whole characters as
/// fit: the length written.
pub fn fromLatin1(bytes: []const u8, into: []u8) usize {
    var length: usize = 0;
    for (bytes) |char| {
        if (char < 0x80) {
            if (length + 1 > into.len) break;
            into[length] = char;
            length += 1;
        } else {
            if (length + 2 > into.len) break;
            into[length] = 0xC0 | char >> 6;
            into[length + 1] = 0x80 | (char & 0x3F);
            length += 2;
        }
    }
    return length;
}

/// Text from elsewhere that does not say what it is written in, as UTF-8
/// into `into`: as it is when the whole of it is UTF-8, else read as
/// Latin-1, which older text from such places is in. As many whole
/// characters as fit; the length written.
pub fn fromForeign(bytes: []const u8, into: []u8) usize {
    return if (valid(bytes)) copyCut(bytes, into) else fromLatin1(bytes, into);
}

/// Whether `bytes` are UTF-8 from first to last.
pub fn valid(bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        const step = decode(bytes[at..]);
        if (step.kind != .char) return false;
        at += step.length;
    }
    return true;
}

/// Whether `bytes` make text `textOf` takes: any bytes while a byte that is
/// no UTF-8 reads as its Latin-1 character, else only UTF-8. A file system
/// that keeps names in another encoding asks this before it reads one.
pub fn readable(bytes: []const u8) bool {
    return broken_reads_latin1 or valid(bytes);
}

/// The text `bytes` make, in UTF-8: what a file system keeps a name it is
/// given as. Bytes that are UTF-8 are their own text, answered as they
/// are; others are written out into `into` as `read` reads them while a
/// byte that is no UTF-8 reads as its Latin-1 character, and refused
/// (null) once it does not. Null too when what is written out does not
/// fit `into`.
pub fn textOf(bytes: []const u8, into: []u8) ?[]const u8 {
    if (valid(bytes)) return bytes;
    if (!broken_reads_latin1) return null;
    var length: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        var one: [4]u8 = undefined;
        const taken = encode(next(bytes, &at), &one);
        if (length + taken > into.len) return null;
        @memcpy(into[length..][0..taken], one[0..taken]);
        length += taken;
    }
    return into[0..length];
}
