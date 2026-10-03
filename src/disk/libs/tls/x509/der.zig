// SPDX-License-Identifier: MIT
//! DER, the encoding certificates are written in: each value a tag, a
//! length and as many bytes of contents, a constructed value's contents
//! being values again.
//!
//! Read strictly, as DER is defined and as a certificate must be: a tag
//! of one byte (the high-tag-number form is never used in X.509), a
//! definite length in its shortest form, and nothing past the end of the
//! value it is in. Anything else is not a certificate, and the reader
//! answers null rather than guess. Nothing is copied: every value is a
//! slice of the bytes it was read from.

/// The tags X.509 uses.
pub const BOOLEAN: u8 = 0x01;
pub const INTEGER: u8 = 0x02;
pub const BIT_STRING: u8 = 0x03;
pub const OCTET_STRING: u8 = 0x04;
pub const NULL: u8 = 0x05;
pub const OID: u8 = 0x06;
pub const UTC_TIME: u8 = 0x17;
pub const GENERALIZED_TIME: u8 = 0x18;
pub const SEQUENCE: u8 = 0x30;
pub const SET: u8 = 0x31;

/// A context-specific tag: [n], primitive or constructed.
pub fn context(number: u5, constructed: bool) u8 {
    return 0x80 | (if (constructed) @as(u8, 0x20) else 0) | number;
}

/// One value: its tag, its contents, and the whole of it as encoded.
pub const Element = struct {
    tag: u8,
    contents: []const u8,
    whole: []const u8,
};

/// The values one after another in `data`.
pub const Reader = struct {
    data: []const u8,

    pub fn of(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn atEnd(reader: *const Reader) bool {
        return reader.data.len == 0;
    }

    /// The tag of the next value, without taking it; null at the end.
    pub fn peek(reader: *const Reader) ?u8 {
        return if (reader.data.len == 0) null else reader.data[0];
    }

    /// The next value; null at the end, or for one that is not good DER.
    pub fn next(reader: *Reader) ?Element {
        const data = reader.data;
        if (data.len < 2) return null;
        const tag = data[0];
        if (tag & 0x1F == 0x1F) return null; // the long tag form
        var length: usize = data[1];
        var header: usize = 2;
        if (length & 0x80 != 0) {
            const count = length & 0x7F;
            // No indefinite length, and no more than four bytes of one.
            if (count == 0 or count > 4 or data.len < 2 + count) return null;
            length = 0;
            for (data[2 .. 2 + count]) |byte| length = length << 8 | byte;
            // The shortest form: a long form only past 127, no zero first.
            if (length < 0x80 or data[2] == 0) return null;
            header += count;
        }
        if (data.len - header < length) return null;
        const whole = data[0 .. header + length];
        reader.data = data[header + length ..];
        return .{ .tag = tag, .contents = whole[header..], .whole = whole };
    }

    /// The next value if it has `tag`; null, with the reader where it
    /// was, for anything else - which is how an OPTIONAL field is read.
    pub fn expect(reader: *Reader, tag: u8) ?Element {
        if (reader.peek() != tag) return null;
        return reader.next();
    }
};

/// The contents of a value of `tag` that is the whole of `data`; null if
/// `data` is anything else or has bytes after it.
pub fn only(data: []const u8, tag: u8) ?[]const u8 {
    var reader = Reader.of(data);
    const element = reader.expect(tag) orelse return null;
    if (!reader.atEnd()) return null;
    return element.contents;
}

/// A BIT STRING's bits, when they are whole bytes (no unused bits): what
/// a key and a signature are.
pub fn bitStringBytes(contents: []const u8) ?[]const u8 {
    if (contents.len == 0 or contents[0] != 0) return null;
    return contents[1..];
}

/// A BOOLEAN's value: DER writes true as FF and nothing else.
pub fn boolean(contents: []const u8) ?bool {
    if (contents.len != 1) return null;
    return switch (contents[0]) {
        0x00 => false,
        0xFF => true,
        else => null,
    };
}

/// A small non-negative INTEGER's value; null for a negative one, one
/// not in its shortest form, or one past 32 bits.
pub fn smallInteger(contents: []const u8) ?u32 {
    if (contents.len == 0 or contents.len > 5) return null;
    if (contents[0] & 0x80 != 0) return null;
    if (contents.len > 1 and contents[0] == 0 and contents[1] & 0x80 == 0) return null;
    var value: u64 = 0;
    for (contents) |byte| value = value << 8 | byte;
    if (value > 0xFFFF_FFFF) return null;
    return @intCast(value);
}

/// Whether two byte strings are the same.
pub fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
