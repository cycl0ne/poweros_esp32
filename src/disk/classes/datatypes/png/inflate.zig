// SPDX-License-Identifier: MIT
//! DEFLATE: the compressed stream a PNG's image data is, unpacked.
//!
//! A stream is blocks, each saying how it is coded: stored bytes, a
//! fixed pair of Huffman codes the format writes down, or a pair the
//! block carries itself. A symbol is either a byte of output or a length
//! that, with a distance, repeats what has already been written - which
//! is why the whole output is one buffer and the repeat reads out of it.
//!
//! **The output buffer is the caller's and its size is known before the
//! stream is read.** A PNG says how big its rows are and how many there
//! are, so there is no growing and no allocation here: a stream that
//! would write past the end is a corrupt stream and says so.
//!
//! **The two codes a block carries are large enough to matter on a
//! stack**: a Huffman code here is six hundred bytes, and a block builds
//! three of them. They live in a `Work` block the caller allocates, so
//! unpacking a picture costs the caller's stack nothing.
//!
//! A code is read a bit at a time, low bit first, and decoded by walking
//! the lengths: for each length in turn, the codes of that length are a
//! run of numbers, so a code falls in that run or the walk goes on to
//! the next length. It needs one small table per code - how many symbols
//! of each length, and the symbols in order - and no decoding table of
//! 2^15 entries.

const std = @import("std");

pub const Error = error{
    /// The stream says something the format does not allow.
    Corrupt,
    /// It ended in the middle of a block.
    Truncated,
    /// It would write more than the caller said there is.
    Overrun,
};

/// How many symbols there are of each kind.
const max_lit_symbols = 288;
const max_dist_symbols = 30;
const max_code_symbols = 19;

/// Extra bits and the length each length symbol stands for, symbols 257
/// to 285.
const length_base = [_]u16{
    3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23,  27,
    31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
};
const length_extra = [_]u3{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
    2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
};

/// The same for the distance symbols, 0 to 29.
const dist_base = [_]u16{
    1,    2,    3,    4,    5,    7,    9,    13,    17,    25,
    33,   49,   65,   97,   129,  193,  257,  385,   513,   769,
    1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
};
const dist_extra = [_]u4{
    0, 0, 0, 0, 1, 1, 2, 2,  3,  3,  4,  4,  5,  5,  6,
    6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
};

/// The order the block's own code lengths are written in.
const length_order = [_]u5{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// What unpacking a stream needs besides the stream itself: the codes a
/// block carries, which are too large to stand on a stack.
pub const Work = struct {
    lit: Huffman = .{},
    dist: Huffman = .{},
    code: Huffman = .{},
    lengths: [max_lit_symbols + max_dist_symbols + 2]u8 = @splat(0),
};

/// One Huffman code: how many symbols there are of each length, and the
/// symbols themselves in the order the lengths put them.
const Huffman = struct {
    count: [16]u16 = @splat(0),
    symbol: [max_lit_symbols]u16 = @splat(0),

    /// The code the given lengths describe. A length of 0 means the
    /// symbol is not in the code.
    fn build(lengths: []const u8) Error!Huffman {
        var it = Huffman{};
        for (lengths) |length| it.count[length] += 1;
        it.count[0] = 0;
        // A code is complete when every leaf is used; fewer is allowed
        // only for a code of one symbol, which the format permits.
        var left: i32 = 1;
        for (1..16) |length| {
            left <<= 1;
            left -= it.count[length];
            if (left < 0) return Error.Corrupt;
        }
        var offset: [16]u16 = @splat(0);
        for (1..15) |length| offset[length + 1] = offset[length] + it.count[length];
        for (lengths, 0..) |length, symbol| {
            if (length == 0) continue;
            it.symbol[offset[length]] = @intCast(symbol);
            offset[length] += 1;
        }
        return it;
    }
};

/// A stream being read: where the bits come from, and where the bytes go.
pub const Stream = struct {
    from: []const u8,
    /// The next byte to take bits out of, and how many of its bits are
    /// gone.
    at: usize = 0,
    bit: u4 = 0,
    into: []u8,
    /// How much of `into` has been written, which is also where a
    /// repeat counts back from.
    done: usize = 0,

    fn takeBit(self: *Stream) Error!u32 {
        if (self.at >= self.from.len) return Error.Truncated;
        const value: u32 = (self.from[self.at] >> @truncate(self.bit)) & 1;
        self.bit += 1;
        if (self.bit == 8) {
            self.bit = 0;
            self.at += 1;
        }
        return value;
    }

    fn takeBits(self: *Stream, count: u5) Error!u32 {
        var value: u32 = 0;
        var i: u5 = 0;
        while (i < count) : (i += 1) value |= try self.takeBit() << i;
        return value;
    }

    /// The next symbol of a code, low bit first.
    fn takeSymbol(self: *Stream, code: *const Huffman) Error!u16 {
        var value: u32 = 0;
        var first: u32 = 0;
        var index: u32 = 0;
        var length: u5 = 1;
        while (length < 16) : (length += 1) {
            value |= try self.takeBit();
            const count = code.count[length];
            if (value - first < count) return code.symbol[index + (value - first)];
            index += count;
            first = (first + count) << 1;
            value <<= 1;
        }
        return Error.Corrupt;
    }

    fn put(self: *Stream, byte: u8) Error!void {
        if (self.done >= self.into.len) return Error.Overrun;
        self.into[self.done] = byte;
        self.done += 1;
    }
};

/// The whole stream unpacked into `into`. How many bytes it wrote.
///
/// A stream that ends before its last block does, or that would write
/// more than `into` holds, is an error and what was written so far is
/// whatever the stream said.
pub fn inflate(work: *Work, from: []const u8, into: []u8) Error!usize {
    var stream = Stream{ .from = from, .into = into };
    while (true) {
        const last = try stream.takeBit();
        const kind = try stream.takeBits(2);
        switch (kind) {
            0 => try stored(&stream),
            1 => try coded(&stream, &fixed_lit, &fixed_dist),
            2 => {
                try blockCodes(&stream, work);
                try coded(&stream, &work.lit, &work.dist);
            },
            else => return Error.Corrupt,
        }
        if (last != 0) break;
    }
    return stream.done;
}

/// A block of bytes as they are: the rest of the byte dropped, then a
/// length and its complement.
fn stored(stream: *Stream) Error!void {
    if (stream.bit != 0) {
        stream.bit = 0;
        stream.at += 1;
    }
    if (stream.at + 4 > stream.from.len) return Error.Truncated;
    const length: usize = @as(usize, stream.from[stream.at]) | @as(usize, stream.from[stream.at + 1]) << 8;
    const check: usize = @as(usize, stream.from[stream.at + 2]) | @as(usize, stream.from[stream.at + 3]) << 8;
    if (length != (~check & 0xFFFF)) return Error.Corrupt;
    stream.at += 4;
    if (stream.at + length > stream.from.len) return Error.Truncated;
    if (stream.done + length > stream.into.len) return Error.Overrun;
    @memcpy(stream.into[stream.done..][0..length], stream.from[stream.at..][0..length]);
    stream.at += length;
    stream.done += length;
}

/// The two codes a block carries itself.
fn blockCodes(stream: *Stream, work: *Work) Error!void {
    const lit_count = try stream.takeBits(5) + 257;
    const dist_count = try stream.takeBits(5) + 1;
    const code_count = try stream.takeBits(4) + 4;
    if (lit_count > max_lit_symbols or dist_count > max_dist_symbols + 2) return Error.Corrupt;

    var code_lengths: [max_code_symbols]u8 = @splat(0);
    for (0..code_count) |i| code_lengths[length_order[i]] = @intCast(try stream.takeBits(3));
    work.code = try Huffman.build(&code_lengths);

    // The two codes' lengths are written as one run, with symbols that
    // repeat the last length or a run of zeroes.
    const lengths = &work.lengths;
    @memset(lengths, 0);
    const total = lit_count + dist_count;
    var i: usize = 0;
    while (i < total) {
        const symbol = try stream.takeSymbol(&work.code);
        if (symbol < 16) {
            lengths[i] = @intCast(symbol);
            i += 1;
            continue;
        }
        var repeat: usize = 0;
        var value: u8 = 0;
        switch (symbol) {
            16 => {
                if (i == 0) return Error.Corrupt;
                value = lengths[i - 1];
                repeat = 3 + try stream.takeBits(2);
            },
            17 => repeat = 3 + try stream.takeBits(3),
            18 => repeat = 11 + try stream.takeBits(7),
            else => return Error.Corrupt,
        }
        if (i + repeat > total) return Error.Corrupt;
        while (repeat > 0) : (repeat -= 1) {
            lengths[i] = value;
            i += 1;
        }
    }
    if (lengths[256] == 0) return Error.Corrupt;
    work.lit = try Huffman.build(lengths[0..lit_count]);
    work.dist = try Huffman.build(lengths[lit_count..total]);
}

/// A block of symbols: bytes, and lengths that repeat what came before.
fn coded(stream: *Stream, lit: *const Huffman, dist: *const Huffman) Error!void {
    while (true) {
        const symbol = try stream.takeSymbol(lit);
        if (symbol < 256) {
            try stream.put(@truncate(symbol));
            continue;
        }
        if (symbol == 256) return;
        const length_index = symbol - 257;
        if (length_index >= length_base.len) return Error.Corrupt;
        const length = length_base[length_index] + try stream.takeBits(length_extra[length_index]);
        const dist_symbol = try stream.takeSymbol(dist);
        if (dist_symbol >= dist_base.len) return Error.Corrupt;
        const distance = dist_base[dist_symbol] + try stream.takeBits(dist_extra[dist_symbol]);
        if (distance > stream.done) return Error.Corrupt;
        var back = stream.done - distance;
        var left = length;
        // Copied a byte at a time on purpose: a repeat may reach into
        // what it is itself writing, which is how a run is coded.
        while (left > 0) : (left -= 1) {
            try stream.put(stream.into[back]);
            back += 1;
        }
    }
}

/// The pair of codes the format writes down, built once at compile time.
const fixed_lit = buildFixedLit();
const fixed_dist = buildFixedDist();

fn buildFixedLit() Huffman {
    @setEvalBranchQuota(20000);
    var lengths: [max_lit_symbols]u8 = undefined;
    for (0..144) |i| lengths[i] = 8;
    for (144..256) |i| lengths[i] = 9;
    for (256..280) |i| lengths[i] = 7;
    for (280..288) |i| lengths[i] = 8;
    return Huffman.build(&lengths) catch unreachable;
}

fn buildFixedDist() Huffman {
    @setEvalBranchQuota(20000);
    const lengths: [30]u8 = @splat(5);
    return Huffman.build(&lengths) catch unreachable;
}

/// A zlib stream: the two-byte header, the deflate stream, and the
/// checksum of what came out. How many bytes it wrote.
///
/// The checksum is read and compared, because a picture decoded from a
/// damaged file looks like a bug in the decoder.
pub fn uncompress(work: *Work, from: []const u8, into: []u8) Error!usize {
    if (from.len < 6) return Error.Truncated;
    const method = from[0] & 0x0F;
    const check: u16 = @as(u16, from[0]) << 8 | from[1];
    // Deflate, a window no larger than 32k, no preset dictionary, and
    // the header's own check.
    if (method != 8 or (from[0] >> 4) > 7 or from[1] & 0x20 != 0 or check % 31 != 0) return Error.Corrupt;
    const written = try inflate(work, from[2 .. from.len - 4], into);
    const tail = from[from.len - 4 ..];
    const said: u32 = @as(u32, tail[0]) << 24 | @as(u32, tail[1]) << 16 |
        @as(u32, tail[2]) << 8 | tail[3];
    if (adler32(into[0..written]) != said) return Error.Corrupt;
    return written;
}

/// The checksum a zlib stream ends with.
pub fn adler32(bytes: []const u8) u32 {
    var low: u32 = 1;
    var high: u32 = 0;
    for (bytes) |byte| {
        low = (low + byte) % 65521;
        high = (high + low) % 65521;
    }
    return high << 16 | low;
}

const testing = std.testing;

test "a stored block comes back as it is" {
    // 0x01: last block, stored; then the length and its complement.
    const stream = [_]u8{ 0x01, 0x05, 0x00, 0xFA, 0xFF, 'h', 'e', 'l', 'l', 'o' };
    var work = Work{};
    var into: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try inflate(&work, &stream, &into));
    try testing.expectEqualStrings("hello", into[0..5]);
}

test "a run is coded as a repeat of itself" {
    // Sixty 'a's, which the coder writes as one byte and a repeat that
    // reads out of what it is itself writing.
    const stream = [_]u8{
        0x78, 0x9c, 0x4b, 0x4c, 0x24, 0x1f, 0x00, 0x00, 0xb5, 0xc0, 0x16, 0xbd,
    };
    var work = Work{};
    var into: [64]u8 = undefined;
    const written = try uncompress(&work, &stream, &into);
    try testing.expectEqual(@as(usize, 60), written);
    for (into[0..written]) |byte| try testing.expectEqual(@as(u8, 'a'), byte);
}

test "a block with its own codes" {
    const stream = [_]u8{
        0x78, 0xda, 0x2d, 0x8d, 0xdb, 0x11, 0xc3, 0x20, 0x0c, 0x04, 0x5b, 0xb9,
        0xd4, 0xe1, 0x6a, 0x20, 0x16, 0xa0, 0x04, 0x23, 0x9b, 0xa7, 0xa1, 0xfa,
        0x68, 0x3c, 0xf9, 0xde, 0xbd, 0xbd, 0x1a, 0x08, 0x57, 0xe3, 0xf7, 0x17,
        0x36, 0xcb, 0x48, 0x70, 0x72, 0xe3, 0xd3, 0x8e, 0xb3, 0x40, 0x3a, 0x65,
        0x54, 0xc5, 0xd1, 0xac, 0x89, 0x5d, 0xfc, 0x86, 0xd3, 0xa8, 0x77, 0x4c,
        0x58, 0x95, 0x06, 0xd7, 0x00, 0xc7, 0x9d, 0x14, 0x2d, 0x4a, 0x88, 0x7c,
        0x35, 0xc9, 0xba, 0xf5, 0x65, 0x43, 0x90, 0x81, 0x4e, 0x37, 0x27, 0x1f,
        0xe7, 0x3f, 0xbf, 0x1b, 0x57, 0xb1, 0xc8, 0x66, 0x53, 0x9e, 0x83, 0xd7,
        0x0f, 0xbe, 0x65, 0x2c, 0xbd,
    };
    var work = Work{};
    var into: [256]u8 = undefined;
    const written = try uncompress(&work, &stream, &into);
    try testing.expectEqualStrings(
        "the quick brown fox jumps over the lazy dog; pack my box with five " ++
            "dozen liquor jugs; how vexingly quick daft zebras jump!",
        into[0..written],
    );
}

test "a truncated stream says so" {
    const stream = [_]u8{ 0x01, 0x05, 0x00, 0xFA, 0xFF, 'h', 'e' };
    var work = Work{};
    var into: [16]u8 = undefined;
    try testing.expectError(Error.Truncated, inflate(&work, &stream, &into));
}

test "more than there is room for says so" {
    const stream = [_]u8{ 0x01, 0x05, 0x00, 0xFA, 0xFF, 'h', 'e', 'l', 'l', 'o' };
    var work = Work{};
    var into: [3]u8 = undefined;
    try testing.expectError(Error.Overrun, inflate(&work, &stream, &into));
}
