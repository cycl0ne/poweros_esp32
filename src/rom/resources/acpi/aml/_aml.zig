// SPDX-License-Identifier: MPL-2.0
//! The bytecode's reader: a table's bytes read in order, with the
//! encodings every term is made of - opcodes of one byte and the
//! extended ones behind 0x5B, package lengths, name strings and the
//! constants.
//!
//! **Package lengths.** A term that holds others starts with its length,
//! which counts itself: one byte for up to 63, otherwise the first byte's
//! top two bits say how many follow, its low four bits are the lowest of
//! the length, and each following byte adds eight more (`pkgEnd`). The
//! two bits between, which the specification reserves, are not looked
//! at.
//!
//! **Name strings.** `\` or a run of `^`, then no name (a 0), one name of
//! four characters, two behind 0x2E, or a count behind 0x2F and that many
//! (`name`): read in place as a `Path`, never copied.
//!
//! **Bounds.** A reader has an end, the table's or the package's it is
//! in, and nothing it answers reaches past it: a read that would answers
//! null, and the reader stays where it was.

const namespace = @import("../namespace/_namespace.zig");
const Path = namespace.Path;

/// The prefix of the extended opcodes, and where an opcode's code puts
/// the byte behind it.
pub const EXT_PREFIX: u8 = 0x5B;
pub const EXT: u16 = 0x5B00;

/// The opcodes the reader itself knows.
pub const ZERO_OP: u8 = 0x00;
pub const ONE_OP: u8 = 0x01;
pub const BYTE_PREFIX: u8 = 0x0A;
pub const WORD_PREFIX: u8 = 0x0B;
pub const DWORD_PREFIX: u8 = 0x0C;
pub const STRING_PREFIX: u8 = 0x0D;
pub const QWORD_PREFIX: u8 = 0x0E;
pub const DUAL_NAME_PREFIX: u8 = 0x2E;
pub const MULTI_NAME_PREFIX: u8 = 0x2F;
pub const ROOT_CHAR: u8 = '\\';
pub const PARENT_PREFIX: u8 = '^';
pub const ONES_OP: u8 = 0xFF;
pub const REVISION_OP: u16 = EXT | 0x30;

/// What `\_REV`'s neighbour Revision answers: the interpreter's own
/// version of the language.
pub const INTERPRETER_REVISION: u64 = 2;

pub const Reader = struct {
    /// The whole table, and where reading is and must stop.
    code: []const u8,
    at: usize,
    end: usize,

    /// A reader of the table `code` from its first term, past the header.
    pub fn of(code: []const u8, start: usize) Reader {
        return .{ .code = code, .at = start, .end = code.len };
    }

    /// The same table, between `at` and `end`.
    pub fn within(reader: Reader, at: usize, end: usize) Reader {
        return .{ .code = reader.code, .at = at, .end = end };
    }

    pub fn atEnd(reader: *const Reader) bool {
        return reader.at >= reader.end;
    }

    pub fn peek(reader: *const Reader) ?u8 {
        return if (reader.at < reader.end) reader.code[reader.at] else null;
    }

    pub fn byte(reader: *Reader) ?u8 {
        const value = reader.peek() orelse return null;
        reader.at += 1;
        return value;
    }

    /// `size` bytes, little-endian, as a number.
    pub fn number(reader: *Reader, comptime size: usize) ?u64 {
        if (reader.end - reader.at < size) return null;
        var value: u64 = 0;
        var index: usize = size;
        while (index > 0) {
            index -= 1;
            value = value << 8 | reader.code[reader.at + index];
        }
        reader.at += size;
        return value;
    }

    /// The next opcode: one byte, or 0x5B and the one behind it as
    /// `EXT | byte`. The reader is left past it.
    pub fn opcode(reader: *Reader) ?u16 {
        const first = reader.peek() orelse return null;
        if (first != EXT_PREFIX) {
            reader.at += 1;
            return first;
        }
        if (reader.end - reader.at < 2) return null;
        const second = reader.code[reader.at + 1];
        reader.at += 2;
        return EXT | second;
    }

    /// The next opcode, the reader left where it is.
    pub fn peekOpcode(reader: *const Reader) ?u16 {
        var copy = reader.*;
        return copy.opcode();
    }

    /// A package length: where the package it starts ends, which must be
    /// within the reader's end. Null where it is not.
    pub fn pkgEnd(reader: *Reader) ?usize {
        const start = reader.at;
        const lead = reader.peek() orelse return null;
        const follow: usize = lead >> 6;
        if (reader.end - reader.at < 1 + follow) return null;
        var length: usize = undefined;
        if (follow == 0) {
            length = lead & 0x3F;
        } else {
            length = lead & 0x0F;
            var index: usize = 0;
            while (index < follow) : (index += 1) {
                length |= @as(usize, reader.code[start + 1 + index]) << @intCast(4 + 8 * index);
            }
        }
        if (length < 1 + follow) return null;
        const end = start + length;
        if (end > reader.end) return null;
        reader.at = start + 1 + follow;
        return end;
    }

    /// A length in a package length's encoding, which a field list uses
    /// for a field's width in bits: its value, ending nothing. Null where
    /// the reader's end comes first.
    pub fn lengthValue(reader: *Reader) ?u32 {
        const lead = reader.peek() orelse return null;
        const follow: usize = lead >> 6;
        if (reader.end - reader.at < 1 + follow) return null;
        var length: u32 = if (follow == 0) lead & 0x3F else lead & 0x0F;
        var index: usize = 0;
        while (index < follow) : (index += 1) {
            length |= @as(u32, reader.code[reader.at + 1 + index]) << @intCast(4 + 8 * index);
        }
        reader.at += 1 + follow;
        return length;
    }

    /// A name string, read in place. Null where the bytes are not one.
    pub fn name(reader: *Reader) ?Path {
        const start = reader.at;
        var path: Path = .{};
        if (reader.peek() == ROOT_CHAR) {
            path.root = true;
            reader.at += 1;
        } else while (reader.peek() == PARENT_PREFIX) {
            if (path.parents == 255) return reader.fail(start);
            path.parents += 1;
            reader.at += 1;
        }
        const first = reader.peek() orelse return reader.fail(start);
        var count: usize = 1;
        if (first == ZERO_OP) {
            reader.at += 1;
            path.count = 0;
            return path;
        } else if (first == DUAL_NAME_PREFIX) {
            reader.at += 1;
            count = 2;
        } else if (first == MULTI_NAME_PREFIX) {
            reader.at += 1;
            count = reader.byte() orelse return reader.fail(start);
            if (count == 0) return reader.fail(start);
        } else if (!namespace.isLead(first)) {
            return reader.fail(start);
        }
        if (reader.end - reader.at < count * 4) return reader.fail(start);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const segment = reader.code[reader.at + index * 4 ..][0..4];
            if (!namespace.isLead(segment[0])) return reader.fail(start);
            for (segment[1..]) |char| if (!namespace.isNameChar(char)) return reader.fail(start);
        }
        path.count = @intCast(count);
        path.segments = reader.code[reader.at..].ptr;
        reader.at += count * 4;
        return path;
    }

    fn fail(reader: *Reader, start: usize) ?Path {
        reader.at = start;
        return null;
    }

    /// Whether the next byte starts a name string.
    pub fn atName(reader: *const Reader) bool {
        const first = reader.peek() orelse return false;
        return first == ROOT_CHAR or first == PARENT_PREFIX or first == DUAL_NAME_PREFIX or
            first == MULTI_NAME_PREFIX or namespace.isLead(first);
    }

    /// A string's bytes, to the NUL behind them, which is read too. Null
    /// where the reader's end comes first.
    pub fn string(reader: *Reader) ?[]const u8 {
        var at = reader.at;
        while (at < reader.end) : (at += 1) {
            if (reader.code[at] == 0) {
                const text = reader.code[reader.at..at];
                reader.at = at + 1;
                return text;
            }
        }
        return null;
    }

    /// An integer constant at the reader - Zero, One, Ones, a number
    /// behind its prefix, Revision - as wide as `bits` allows. Null, and
    /// the reader left where it was, where the next term is something
    /// else.
    pub fn constant(reader: *Reader, bits: u8) ?u64 {
        const start = reader.at;
        const code = reader.opcode() orelse return null;
        const value: u64 = switch (code) {
            ZERO_OP => 0,
            ONE_OP => 1,
            ONES_OP => ~@as(u64, 0),
            BYTE_PREFIX => reader.number(1),
            WORD_PREFIX => reader.number(2),
            DWORD_PREFIX => reader.number(4),
            QWORD_PREFIX => reader.number(8),
            REVISION_OP => INTERPRETER_REVISION,
            else => null,
        } orelse {
            reader.at = start;
            return null;
        };
        return if (bits == 32) value & 0xFFFF_FFFF else value;
    }
};

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "package lengths of one to four bytes, each ending where it says" {
    const code = [_]u8{ 0x05, 1, 2, 3, 4 } ++ [_]u8{0} ** 3;
    var reader = Reader.of(&code, 0);
    try testing.expectEqual(@as(?usize, 5), reader.pkgEnd());
    try testing.expectEqual(@as(usize, 1), reader.at);
    // 0x4A 0x01: 0xA | 0x01 << 4 = 26 bytes.
    var long: [26]u8 = @splat(0);
    long[0] = 0x4A;
    long[1] = 0x01;
    reader = Reader.of(&long, 0);
    try testing.expectEqual(@as(?usize, 26), reader.pkgEnd());
    try testing.expectEqual(@as(usize, 2), reader.at);
    // Past the end: nothing, and the reader where it was.
    long[1] = 0x02;
    reader = Reader.of(&long, 0);
    try testing.expectEqual(@as(?usize, null), reader.pkgEnd());
    try testing.expectEqual(@as(usize, 0), reader.at);
}

test "name strings of each form, read in place" {
    const code = "\\_SB_" ++ "^^" ++ "\x2EPCI0LPC0" ++ "\x2F\x03_SB_PCI0XHC0" ++ "\x00" ++ "1BAD";
    var reader = Reader.of(code, 0);
    var path = reader.name().?;
    try testing.expect(path.root);
    try testing.expectEqual(@as(u8, 1), path.count);
    try testing.expectEqual(namespace.nameOf("_SB"), path.segment(0));
    path = reader.name().?;
    try testing.expectEqual(@as(u8, 2), path.parents);
    try testing.expectEqual(@as(u8, 2), path.count);
    try testing.expectEqual(namespace.nameOf("LPC0"), path.segment(1));
    path = reader.name().?;
    try testing.expectEqual(@as(u8, 3), path.count);
    try testing.expectEqual(namespace.nameOf("XHC0"), path.segment(2));
    path = reader.name().?;
    try testing.expectEqual(@as(u8, 0), path.count);
    const before = reader.at;
    try testing.expectEqual(@as(?Path, null), reader.name());
    try testing.expectEqual(before, reader.at);
}

test "constants, as wide as the namespace's integers" {
    const code = [_]u8{ 0x00, 0x01, 0xFF, 0x0A, 0x12, 0x0B, 0x34, 0x12, 0x0C, 0x78, 0x56, 0x34, 0x12, 0x0E, 1, 2, 3, 4, 5, 6, 7, 8, 0x5B, 0x30, 0x70 };
    var reader = Reader.of(&code, 0);
    try testing.expectEqual(@as(?u64, 0), reader.constant(64));
    try testing.expectEqual(@as(?u64, 1), reader.constant(64));
    try testing.expectEqual(@as(?u64, 0xFFFF_FFFF), reader.constant(32));
    try testing.expectEqual(@as(?u64, 0x12), reader.constant(64));
    try testing.expectEqual(@as(?u64, 0x1234), reader.constant(64));
    try testing.expectEqual(@as(?u64, 0x12345678), reader.constant(64));
    try testing.expectEqual(@as(?u64, 0x0807060504030201), reader.constant(64));
    try testing.expectEqual(@as(?u64, INTERPRETER_REVISION), reader.constant(64));
    try testing.expectEqual(@as(?u64, null), reader.constant(64));
    try testing.expectEqual(@as(?u8, 0x70), reader.peek());
}
