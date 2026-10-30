// SPDX-License-Identifier: MIT
//! AAC's Huffman codes decoded by looking them up: the codewords of the
//! scale factors and of the eleven spectral codebooks (`tables.zig`) made
//! into tables when the library is compiled.
//!
//! **A table** is looked up by the next `first` bits: a codeword that
//! short is found there at once - with its value and its length, so the
//! entry is repeated for every ending it can have. The longer codewords
//! that begin with the same `first` bits share a second table, looked up
//! by as many bits more as the longest of them has. Two lookups at most.
//!
//! **A spectral codebook** codes four values a codeword (books 1 to 4) or
//! two (5 to 11), each the codeword's number taken apart in its base: -1
//! to 1 in books 1 and 2, 0 to 2 in 3 and 4, -4 to 4 in 5 and 6, 0 to 7
//! in 7 and 8, 0 to 12 in 9 and 10, 0 to 16 in 11 - where 16 says an
//! escape follows. The books without signs have a sign bit after the
//! codeword for each value that is not 0.

const tables = @import("tables.zig");
const Bits = @import("bits.zig").Bits;

pub const Entry = struct {
    /// A codeword's value - or, with `sub` bits more to look up, where
    /// its second table starts.
    value: u16,
    /// The codeword's whole length; 0 for bits that begin none.
    length: u8,
    sub: u8,
};

/// The lookup table of a code: `first` bits, then the second tables.
pub fn Table(comptime first: u5, comptime size: usize) type {
    return struct {
        entries: [size]Entry,

        /// The next codeword's value, read; null for bits that are none.
        pub fn decode(t: *const @This(), bits: *Bits) ?u16 {
            const e = t.entries[bits.peek(first)];
            if (e.sub == 0) {
                if (e.length == 0) return null;
                bits.skip(e.length);
                return e.value;
            }
            const rest = bits.peek(first + @as(u5, @intCast(e.sub))) & ((@as(u32, 1) << @intCast(e.sub)) - 1);
            const second = t.entries[e.value + rest];
            if (second.length == 0) return null;
            bits.skip(second.length);
            return second.value;
        }
    };
}

/// How many bits more each second table is looked up by, for the codes
/// whose first `first` bits are its index; 0 for none.
fn extraBits(comptime codes: anytype, comptime lengths: []const u8, comptime first: u5) [1 << first]u8 {
    var extra: [1 << first]u8 = @splat(0);
    for (codes, lengths) |code, length| {
        if (length <= first) continue;
        const prefix = code >> (length - first);
        extra[prefix] = @max(extra[prefix], length - first);
    }
    return extra;
}

fn tableSize(comptime codes: anytype, comptime lengths: []const u8, comptime first: u5) usize {
    var size: usize = 1 << first;
    for (extraBits(codes, lengths, first)) |extra| {
        if (extra != 0) size += @as(usize, 1) << extra;
    }
    return size;
}

/// The table of a code. Every slot a codeword fills is filled once: a
/// code whose words are not free of each other's beginnings does not
/// compile.
pub fn make(comptime codes: anytype, comptime lengths: []const u8, comptime first: u5) Table(first, tableSize(codes, lengths, first)) {
    @setEvalBranchQuota(200_000);
    const size = tableSize(codes, lengths, first);
    var entries: [size]Entry = @splat(.{ .value = 0, .length = 0, .sub = 0 });
    const extra = extraBits(codes, lengths, first);
    var start: [1 << first]u16 = @splat(0);
    var next: usize = 1 << first;
    for (extra, 0..) |bits, prefix| {
        if (bits == 0) continue;
        entries[prefix] = .{ .value = next, .length = 0, .sub = bits };
        start[prefix] = next;
        next += @as(usize, 1) << bits;
    }
    for (codes, lengths, 0..) |code, length, value| {
        var base: usize = undefined;
        var count: usize = undefined;
        if (length <= first) {
            base = @as(usize, code) << (first - length);
            count = @as(usize, 1) << (first - length);
        } else {
            const rest = length - first;
            const prefix = code >> rest;
            const low = code & ((1 << rest) - 1);
            base = start[prefix] + (@as(usize, low) << (extra[prefix] - rest));
            count = @as(usize, 1) << (extra[prefix] - rest);
        }
        for (entries[base..][0..count]) |*slot| {
            if (slot.length != 0 or slot.sub != 0) @compileError("two codewords begin alike");
            slot.* = .{ .value = value, .length = length, .sub = 0 };
        }
    }
    return .{ .entries = entries };
}

/// The scale factors' code: a difference from the band before, 60 for
/// none.
pub const scalefactor = make(tables.scalefactor_codes, &tables.scalefactor_bits, 9);

/// What a spectral codebook codes.
pub const Book = struct {
    /// Values a codeword, and whether they carry their signs.
    dimension: u8,
    signed: bool,
    /// The base the codeword's number is written in, and what is added to
    /// each digit.
    base: u8,
    offset: i8,
};

pub const books = [11]Book{
    .{ .dimension = 4, .signed = true, .base = 3, .offset = -1 },
    .{ .dimension = 4, .signed = true, .base = 3, .offset = -1 },
    .{ .dimension = 4, .signed = false, .base = 3, .offset = 0 },
    .{ .dimension = 4, .signed = false, .base = 3, .offset = 0 },
    .{ .dimension = 2, .signed = true, .base = 9, .offset = -4 },
    .{ .dimension = 2, .signed = true, .base = 9, .offset = -4 },
    .{ .dimension = 2, .signed = false, .base = 8, .offset = 0 },
    .{ .dimension = 2, .signed = false, .base = 8, .offset = 0 },
    .{ .dimension = 2, .signed = false, .base = 13, .offset = 0 },
    .{ .dimension = 2, .signed = false, .base = 13, .offset = 0 },
    .{ .dimension = 2, .signed = false, .base = 17, .offset = 0 },
};

/// Each codebook's values, by codeword number: the four, or the two and
/// two zeros.
fn valuesOf(comptime book: Book, comptime count: usize) [count][4]i8 {
    var out: [count][4]i8 = undefined;
    for (0..count) |number| {
        var rest = number;
        var digits: [4]i8 = @splat(0);
        var i: usize = book.dimension;
        while (i > 0) {
            i -= 1;
            digits[i] = @as(i8, @intCast(rest % book.base)) + book.offset;
            rest /= book.base;
        }
        out[number] = digits;
    }
    return out;
}

fn SpectralTable(comptime index: usize) type {
    const codes = tables.spectral_codes[index];
    const lengths = tables.spectral_bits[index];
    return struct {
        pub const table = make(codes[0..].*, lengths, 8);
        pub const values = valuesOf(books[index], codes.len);
    };
}

pub const spectral = .{
    SpectralTable(0), SpectralTable(1), SpectralTable(2),  SpectralTable(3),
    SpectralTable(4), SpectralTable(5), SpectralTable(6),  SpectralTable(7),
    SpectralTable(8), SpectralTable(9), SpectralTable(10),
};

/// The next codeword of spectral codebook `book` (1 to 11), read: its
/// values, without their signs yet in the books that have none.
pub fn spectralValues(book: u8, bits: *Bits) ?*const [4]i8 {
    inline for (spectral, 1..) |codebook, number| {
        if (book == number) {
            const value = codebook.table.decode(bits) orelse return null;
            return &codebook.values[value];
        }
    }
    return null;
}

test "every codeword decodes to its value" {
    const std = @import("std");
    var buffer: [8]u8 = undefined;
    for (tables.scalefactor_codes, tables.scalefactor_bits, 0..) |code, length, value| {
        const word: u64 = @as(u64, code) << @intCast(64 - @as(u32, length));
        std.mem.writeInt(u64, &buffer, word, .big);
        var bits: Bits = .{ .bytes = &buffer };
        try std.testing.expectEqual(@as(?u16, @intCast(value)), scalefactor.decode(&bits));
        try std.testing.expectEqual(@as(usize, length), bits.at);
    }
    inline for (0..11) |index| {
        const codes = tables.spectral_codes[index];
        const lengths = tables.spectral_bits[index];
        for (codes, lengths, 0..) |code, length, value| {
            const word: u64 = @as(u64, code) << @intCast(64 - @as(u32, length));
            std.mem.writeInt(u64, &buffer, word, .big);
            var bits: Bits = .{ .bytes = &buffer };
            const got = spectralValues(index + 1, &bits).?;
            try std.testing.expectEqual(&spectral[index].values[value], got);
            try std.testing.expectEqual(@as(usize, length), bits.at);
        }
    }
    // Book 7's codeword 63 is the two values 7 and 7.
    try std.testing.expectEqualSlices(i8, &.{ 7, 7, 0, 0 }, &spectral[6].values[63]);
    // Book 1's codeword 0 is four times -1.
    try std.testing.expectEqualSlices(i8, &.{ -1, -1, -1, -1 }, &spectral[0].values[0]);
}
