// SPDX-License-Identifier: MIT
//! A DTS core frame's header (ETSI TS 102 114 5.4), and the four ways a
//! stream may hold a frame's bits: 16 bits a word or 14 - the low ones of
//! each, as on an audio CD - big or little end first. `unpack` makes any
//! of them plain bytes, for the rest to read.

const Bits = @import("../aac/bits.zig").Bits;

pub const Format = enum(u8) { be16, le16, be14, le14 };

/// The most bytes a frame's bits take, unpacked.
pub const MOST_BYTES = 16384;

/// The sync word of an extension substream, which may lie between core
/// frames and which this decoder passes over.
const EXTENSION_SYNC = [4]u8{ 0x64, 0x58, 0x20, 0x25 };

/// How many channels each AMODE this decoder knows has.
pub const mode_channels = [10]u8{ 1, 2, 2, 2, 2, 3, 3, 4, 4, 5 };
/// AMODE: the two channels' sum and difference.
pub const SUM_DIFFERENCE = 3;

const rates = [16]u32{ 0, 8000, 16000, 32000, 0, 0, 11025, 22050, 44100, 0, 0, 12000, 24000, 48000, 0, 0 };

pub const Header = struct {
    format: Format = .be16,
    /// Bytes the frame takes in the stream, and its bits unpacked.
    size: u32 = 0,
    bytes: u32 = 0,
    /// Blocks of 32 samples of each channel.
    blocks: u32 = 0,
    rate: u32 = 0,
    /// AMODE.
    mode: u32 = 2,
    /// Whether this decoder can decode it: not an arrangement past 5.1 or
    /// a termination frame cut to a length subframes cannot make.
    decodable: bool = false,
};

/// The fields the decoder wants, after the sync word and what `peek` read.
pub const Fields = struct {
    crc: bool,
    drc: bool,
    /// DSYNC at each subsubframe's end, not only each subframe's.
    sync_each: bool,
    /// The LFE's samples: 0 for none, 1 or 2 for 2 or 4 a subsubframe.
    lfe: u32,
    /// Whether the predictors go on from the frame before.
    history: bool,
    /// The filter of perfect reconstruction.
    perfect: bool,
    /// The step sizes of a lossless frame.
    lossless: bool,
    sum_front: bool,
    sum_surround: bool,
};

fn formatOf(bytes: []const u8) ?Format {
    if (bytes.len < 6) return null;
    const b = bytes;
    if (b[0] == 0x7F and b[1] == 0xFE and b[2] == 0x80 and b[3] == 0x01) return .be16;
    if (b[0] == 0xFE and b[1] == 0x7F and b[2] == 0x01 and b[3] == 0x80) return .le16;
    if (b[0] == 0x1F and b[1] == 0xFF and b[2] == 0xE8 and b[3] == 0x00 and b[4] == 0x07 and b[5] & 0xF0 == 0xF0) return .be14;
    if (b[0] == 0xFF and b[1] == 0x1F and b[2] == 0x00 and b[3] == 0xE8 and b[5] == 0x07 and b[4] & 0xF0 == 0xF0) return .le14;
    return null;
}

/// A frame of the stream's `raw` bytes as plain bytes in `out`: how many.
pub fn unpack(format: Format, raw: []const u8, out: []u8) usize {
    const words = raw.len / 2;
    switch (format) {
        .be16 => {
            const count = @min(raw.len, out.len);
            for (0..count) |i| out[i] = raw[i];
            return count;
        },
        .le16 => {
            const count = @min(words * 2, out.len & ~@as(usize, 1));
            var i: usize = 0;
            while (i < count) : (i += 2) {
                out[i] = raw[i + 1];
                out[i + 1] = raw[i];
            }
            return count;
        },
        .be14, .le14 => {
            var gathered: u32 = 0;
            var held: u5 = 0;
            var made: usize = 0;
            for (0..words) |w| {
                const first = raw[w * 2];
                const second = raw[w * 2 + 1];
                const word: u32 = if (format == .be14) @as(u32, first) << 8 | second else @as(u32, second) << 8 | first;
                gathered = (gathered << 14) | (word & 0x3FFF);
                held += 14;
                while (held >= 8) {
                    held -= 8;
                    if (made == out.len) return made;
                    out[made] = @truncate(gathered >> held);
                    made += 1;
                }
                gathered &= (@as(u32, 1) << held) - 1;
            }
            return made;
        },
    }
}

/// The header of the frame at the front of `bytes`, null if there is none.
pub fn peek(bytes: []const u8) ?Header {
    const format = formatOf(bytes) orelse return null;
    if (bytes.len < 16) return null;
    var head: [14]u8 = undefined;
    _ = unpack(format, bytes[0..16], &head);
    var b: Bits = .{ .bytes = &head };
    b.skip(32);
    const normal = b.bit();
    const deficit = b.read(5);
    b.skip(1); // CPF
    const blocks = b.read(7) + 1;
    const size = b.read(14) + 1;
    const mode = b.read(6);
    const rate = rates[b.read(4)];
    b.skip(5); // RATE
    const reserved = b.bit();
    b.skip(4 + 3 + 1 + 1); // DYNF, TIMEF, AUXF, HDCD, EXT_AUDIO_ID, EXT_AUDIO, ASPF
    const lfe = b.read(2);
    if (blocks < 6 or size < 96 or rate == 0 or reserved or lfe == 3 or mode >= 16) return null;
    if (normal and (deficit != 31 or blocks & 7 != 0)) return null;
    return .{
        .format = format,
        .size = switch (format) {
            .be16, .le16 => size,
            .be14, .le14 => (size * 8 + 13) / 14 * 2,
        },
        .bytes = size,
        .blocks = blocks,
        .rate = rate,
        .mode = mode,
        .decodable = deficit == 31 and blocks & 7 == 0 and mode < mode_channels.len,
    };
}

/// Whether `bytes` begins with an extension substream.
pub fn isExtension(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    for (EXTENSION_SYNC, bytes[0..4]) |a, b| {
        if (a != b) return false;
    }
    return true;
}

/// The whole header of a frame's unpacked bits, read: null if it says what
/// no frame should.
pub fn read(b: *Bits) ?Fields {
    b.skip(32 + 1 + 5);
    const crc = b.bit();
    b.skip(7 + 14 + 6 + 4);
    const rate = b.read(5);
    b.skip(1);
    const drc = b.bit();
    b.skip(1 + 1 + 1 + 3 + 1); // TIMEF, AUXF, HDCD, EXT_AUDIO_ID, EXT_AUDIO
    const sync_each = b.bit();
    const lfe = b.read(2);
    const history = b.bit();
    if (crc) b.skip(16);
    const perfect = b.bit();
    b.skip(4 + 2); // VERNUM, CHIST
    const resolution = b.read(3);
    const sum_front = b.bit();
    const sum_surround = b.bit();
    b.skip(4); // DIALNORM
    if (resolution == 4 or resolution == 7) return null;
    return .{
        .crc = crc,
        .drc = drc,
        .sync_each = sync_each,
        .lfe = lfe,
        .history = history,
        .perfect = perfect,
        .lossless = rate == 0x1F,
        .sum_front = sum_front,
        .sum_surround = sum_surround,
    };
}

const expectEqual = @import("std").testing.expectEqual;

test "the four forms of a frame's first bytes" {
    // A stereo 48 kHz frame's header: 512 samples, 2013 bytes, its LFE none.
    const plain = [_]u8{ 0x7F, 0xFE, 0x80, 0x01, 0xFC, 0x3C, 0x7D, 0xC0, 0xB5, 0xE0, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const h = peek(&plain).?;
    try expectEqual(Format.be16, h.format);
    try expectEqual(@as(u32, 16), h.blocks);
    try expectEqual(@as(u32, 2), h.mode);
    try expectEqual(@as(u32, 48000), h.rate);
    try expectEqual(h.bytes, h.size);
    try expectEqual(true, h.decodable);

    var swapped: [18]u8 = undefined;
    for (0..9) |i| {
        swapped[i * 2] = plain[i * 2 + 1];
        swapped[i * 2 + 1] = plain[i * 2];
    }
    const little = peek(&swapped).?;
    try expectEqual(Format.le16, little.format);
    try expectEqual(h.bytes, little.bytes);
    try expectEqual(h.rate, little.rate);

    // The same bits, 14 to a word.
    var fourteen: [18]u8 = undefined;
    var bits: Bits = .{ .bytes = &plain };
    for (0..9) |i| {
        var word = bits.read(14);
        if (word & 0x2000 != 0) word |= 0xC000; // its sign, as such a stream has
        fourteen[i * 2] = @truncate(word >> 8);
        fourteen[i * 2 + 1] = @truncate(word);
    }
    const packed14 = peek(&fourteen).?;
    try expectEqual(Format.be14, packed14.format);
    try expectEqual(h.bytes, packed14.bytes);
    try expectEqual((h.bytes * 8 + 13) / 14 * 2, packed14.size);
    var back: [14]u8 = undefined;
    _ = unpack(.be14, fourteen[0..16], &back);
    for (plain[0..14], back) |a, c| try expectEqual(a, c);
}

test "what is not a frame's header" {
    try expectEqual(@as(?Header, null), peek(&[_]u8{0} ** 18));
    // A sync word and a normal frame of 17 blocks: no frame is.
    const odd = [_]u8{ 0x7F, 0xFE, 0x80, 0x01, 0xFC, 0x40, 0x7D, 0xC0, 0xB5, 0xE0, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try expectEqual(@as(?Header, null), peek(&odd));
}
