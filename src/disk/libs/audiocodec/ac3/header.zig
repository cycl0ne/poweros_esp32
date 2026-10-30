// SPDX-License-Identifier: MIT
//! A syncframe's header: its sync info and its bit stream info, AC-3's
//! (bsid up to 10) or E-AC-3's (11 to 16), told apart by the bsid both
//! keep 40 bits in.
//!
//! **AC-3** says its size by a code, the bit rate's, and the sample rate
//! (a bsid of 9 or 10 halves it, or quarters it); a frame always holds
//! six blocks of 256 samples. **E-AC-3** says its size in words, and
//! holds one, two, three or six blocks; its frames are independent -
//! they make a program's sound - or dependent, adding channels to the
//! independent frame before them, and a stream may carry several
//! programs, each its own substream.
//!
//! What a decoder of two channels needs of the rest is the mix levels:
//! how loud the centre and the surrounds go into left and right. The
//! other fields - dialogue level, heavy compression, languages, time
//! codes, mixing data for other programs - are read past.

const tables = @import("tables.zig");
const Bits = @import("../aac/bits.zig").Bits;

/// The kinds of frame: E-AC-3's own, and one converted from AC-3 - as an
/// AC-3 frame is counted.
pub const INDEPENDENT: u32 = 0;
pub const DEPENDENT: u32 = 1;
pub const CONVERTED: u32 = 2;

pub const Header = struct {
    eac3: bool = false,
    bsid: u32 = 0,
    kind: u32 = CONVERTED,
    substream: u32 = 0,
    /// The frame's bytes.
    size: u32 = 0,
    /// The sample rate's code and how far a lower rate is shifted down
    /// from it; the rate.
    sr_code: u32 = 0,
    sr_shift: u32 = 0,
    rate: u32 = 0,
    blocks: u32 = 6,
    /// The audio coding mode (acmod) and whether an LFE channel follows.
    mode: u32 = 0,
    lfe: bool = false,
    bitrate: u32 = 0,
    /// The centre's and the surrounds' levels in a mix to two channels,
    /// as indices into `tables.gain_levels`: -4.5 and -6 dB unless the
    /// stream says.
    center_mix: u32 = 5,
    surround_mix: u32 = 6,
};

/// The header of the frame the bytes begin with - its sync info and the
/// bit stream info's first fields, which 8 bytes hold - or null when they
/// begin none.
pub fn peek(bytes: []const u8) ?Header {
    if (bytes.len < 8 or bytes[0] != 0x0B or bytes[1] != 0x77) return null;
    var bits: Bits = .{ .bytes = bytes[0..8] };
    return sync(&bits);
}

/// The frame's header read whole: its bit stream info too, `bits` left
/// where the frame's own data begins. Null when it is none.
pub fn read(bits: *Bits) ?Header {
    var h = sync(bits) orelse return null;
    if (h.eac3) {
        if (!eac3Info(bits, &h)) return null;
    } else ac3Info(bits, &h);
    if (bits.overrun()) return null;
    return h;
}

/// Whether a frame's bytes are as its encoder wrote them: the CRC-16 of
/// all but the sync word - its last check word, crc2, at the end - comes
/// to 0.
pub fn intact(bytes: []const u8) bool {
    var crc: u16 = 0;
    for (bytes[2..]) |byte| crc = (crc << 8) ^ crc_table[(crc >> 8) ^ byte];
    return crc == 0;
}

/// x^16 + x^15 + x^2 + 1, the high bit first.
const crc_table: [256]u16 = table: {
    @setEvalBranchQuota(4000);
    var t: [256]u16 = undefined;
    for (&t, 0..) |*entry, i| {
        var crc: u16 = @as(u16, i) << 8;
        for (0..8) |_| crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x8005 else crc << 1;
        entry.* = crc;
    }
    break :table t;
};

/// The sync info, and what of the bit stream info comes before its
/// mix levels.
fn sync(bits: *Bits) ?Header {
    const at = bits.at / 8;
    if (bits.bytes.len < at + 8 or bits.read(16) != 0x0B77) return null;
    var h: Header = .{};
    h.bsid = bits.bytes[at + 5] >> 3;
    if (h.bsid > 16) return null;
    if (h.bsid <= 10) {
        bits.skip(16); // crc1
        h.sr_code = bits.read(2);
        if (h.sr_code == 3) return null;
        const code = bits.read(6);
        if (code > 37) return null;
        bits.skip(5 + 3); // bsid, bsmod
        h.mode = bits.read(3);
        if (h.mode == 2) {
            bits.skip(2); // dsurmod
        } else {
            if (h.mode & 1 != 0 and h.mode != 1) h.center_mix = tables.center_levels[bits.read(2)];
            if (h.mode & 4 != 0) h.surround_mix = tables.surround_levels[bits.read(2)];
        }
        h.lfe = bits.bit();
        h.sr_shift = @max(h.bsid, 8) - 8;
        h.rate = tables.rates[h.sr_code] >> @intCast(h.sr_shift);
        h.bitrate = @as(u32, tables.bitrates[code >> 1]) * 1000 >> @intCast(h.sr_shift);
        h.size = @as(u32, tables.frame_words[code][h.sr_code]) * 2;
        return h;
    }
    h.eac3 = true;
    h.kind = bits.read(2);
    if (h.kind == 3) return null;
    h.substream = bits.read(3);
    h.size = (bits.read(11) + 1) * 2;
    if (h.size < 7) return null;
    h.sr_code = bits.read(2);
    if (h.sr_code == 3) {
        const half = bits.read(2);
        if (half == 3) return null;
        h.rate = tables.rates[half] / 2;
        h.sr_shift = 1;
    } else {
        h.blocks = ([4]u32{ 1, 2, 3, 6 })[bits.read(2)];
        h.rate = tables.rates[h.sr_code];
    }
    h.mode = bits.read(3);
    h.lfe = bits.bit();
    h.bitrate = @intCast(@as(u64, 8) * h.size * h.rate / (h.blocks * 256));
    return h;
}

/// The rest of AC-3's bit stream info: the dual-mono program's second
/// set of fields, and the alternate syntax of bsid 6 (Annex D), whose
/// first extra field gives the Lo/Ro levels the mix uses.
fn ac3Info(bits: *Bits, h: *Header) void {
    for (0..programs(h)) |_| {
        bits.skip(5); // dialnorm
        if (bits.bit()) bits.skip(8); // compr
        if (bits.bit()) bits.skip(8); // langcod
        if (bits.bit()) bits.skip(7); // mixlevel, roomtyp
    }
    bits.skip(2); // copyrightb, origbs
    if (h.bsid == 6) {
        if (bits.bit()) {
            bits.skip(2 + 3 + 3); // dmixmod, ltrtcmixlev, ltrtsurmixlev
            h.center_mix = bits.read(3);
            h.surround_mix = @max(3, bits.read(3));
        }
        if (bits.bit()) bits.skip(2 + 2 + 1 + 8 + 1);
    } else {
        if (bits.bit()) bits.skip(14); // timecod1
        if (bits.bit()) bits.skip(14); // timecod2
    }
    additional(bits);
}

/// The rest of E-AC-3's bit stream info (E2.2.2): false for a reserved
/// value.
fn eac3Info(bits: *Bits, h: *Header) bool {
    bits.skip(5); // bsid
    for (0..programs(h)) |_| {
        bits.skip(5); // dialnorm
        if (bits.bit()) bits.skip(8); // compr
    }
    if (h.kind == DEPENDENT and bits.bit()) bits.skip(16); // chanmap
    if (bits.bit()) {
        // Mixing metadata.
        if (h.mode > 2) {
            bits.skip(2); // dmixmod
            if (h.mode & 1 != 0) {
                bits.skip(3); // ltrtcmixlev
                h.center_mix = bits.read(3);
            }
            if (h.mode & 4 != 0) {
                bits.skip(3); // ltrtsurmixlev
                h.surround_mix = @max(3, bits.read(3));
            }
        }
        if (h.lfe and bits.bit()) bits.skip(5); // lfemixlevcod
        if (h.kind == INDEPENDENT) {
            for (0..programs(h)) |_| {
                if (bits.bit()) bits.skip(6); // pgmscl
            }
            if (bits.bit()) bits.skip(6); // extpgmscl
            switch (bits.read(2)) {
                1 => bits.skip(5),
                2 => bits.skip(12),
                3 => bits.skip((bits.read(5) + 2) * 8),
                else => {},
            }
            if (h.mode < 2) {
                for (0..programs(h)) |_| {
                    if (bits.bit()) bits.skip(8 + 6); // panmean, paninfo
                }
            }
            if (bits.bit()) {
                for (0..h.blocks) |_| {
                    if (h.blocks == 1 or bits.bit()) bits.skip(5); // blkmixcfginfo
                }
            }
        }
    }
    if (bits.bit()) {
        // Informational metadata.
        bits.skip(3 + 2); // bsmod, copyrightb, origbs
        if (h.mode == 2) bits.skip(2 + 2); // dsurmod, dheadphonmod
        if (h.mode >= 6) bits.skip(2); // dsurexmod
        for (0..programs(h)) |_| {
            if (bits.bit()) bits.skip(8); // mixlevel, roomtyp, adconvtyp
        }
        if (h.sr_code != 3) bits.skip(1); // sourcefscod
    }
    if (h.kind == INDEPENDENT and h.blocks != 6) bits.skip(1); // convsync
    if (h.kind == CONVERTED and (h.blocks == 6 or bits.bit())) bits.skip(6); // frmsizecod
    additional(bits);
    return true;
}

/// Additional bit stream info: passed over.
fn additional(bits: *Bits) void {
    if (bits.bit()) bits.skip((bits.read(6) + 1) * 8);
}

/// Dual mono (1+1) has two programs' fields where the others have one.
fn programs(h: *const Header) usize {
    return if (h.mode == 0) 2 else 1;
}

const std = @import("std");

test "an AC-3 header: 48 kHz, 448 kbit/s, 3/2 with LFE" {
    // syncword, crc1, fscod 0 + frmsizecod 30, bsid 8 + bsmod 0, acmod 7,
    // cmixlev 1, surmixlev 1, lfeon 1.
    const bytes = [_]u8{ 0x0B, 0x77, 0x12, 0x34, 0x1E, 0x40, 0xEB, 0x00 };
    const h = peek(&bytes).?;
    try std.testing.expect(!h.eac3);
    try std.testing.expectEqual(@as(u32, 48000), h.rate);
    try std.testing.expectEqual(@as(u32, 448000), h.bitrate);
    try std.testing.expectEqual(@as(u32, 1792), h.size);
    try std.testing.expectEqual(@as(u32, 7), h.mode);
    try std.testing.expect(h.lfe);
    try std.testing.expectEqual(@as(u32, 5), h.center_mix);
    try std.testing.expectEqual(@as(u32, 6), h.surround_mix);
}

test "an E-AC-3 header: an independent frame of six blocks" {
    // syncword, strmtyp 0, substreamid 0, frmsiz 447, fscod 0,
    // numblkscod 3, acmod 2, lfeon 0, bsid 16.
    const bytes = [_]u8{ 0x0B, 0x77, 0x01, 0xBF, 0x34, 0x80, 0x00, 0x00 };
    const h = peek(&bytes).?;
    try std.testing.expect(h.eac3);
    try std.testing.expectEqual(INDEPENDENT, h.kind);
    try std.testing.expectEqual(@as(u32, 896), h.size);
    try std.testing.expectEqual(@as(u32, 6), h.blocks);
    try std.testing.expectEqual(@as(u32, 2), h.mode);
    try std.testing.expectEqual(@as(u32, 224000), h.bitrate);
}
