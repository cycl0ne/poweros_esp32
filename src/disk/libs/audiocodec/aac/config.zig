// SPDX-License-Identifier: MIT
//! What an AAC stream is: an ADTS frame's header, before each frame of a
//! `.aac` file or a station's stream; an MP4's AudioSpecificConfig, once
//! for the track; and the program config element either may hold for the
//! channels.
//!
//! **An ADTS header** is 7 bytes - 9 with a CRC: twelve 1 bits, the
//! version, layer 0, whether a CRC follows, the profile (the object type
//! less one), the rate's index, the channel configuration, the frame's
//! length with its header, and how many raw data blocks less one.
//!
//! **An AudioSpecificConfig** names the object type - 2 for AAC-LC, 5 and
//! 29 for HE-AAC, which put SBR (and PS) over an LC core - the rate's
//! index or the rate itself, the channel configuration, and for an HE-AAC
//! type the rate of what SBR makes and the core's own type. Then the
//! core's GASpecificConfig: whether frames are 960 samples, a delay for a
//! core coder, and a PCE when the configuration is 0.
//!
//! Only the LC core is decoded: an HE-AAC stream plays at the core's
//! rate.

const tables = @import("tables.zig");
const Bits = @import("bits.zig").Bits;

pub const LC: u8 = 2;

pub const Config = struct {
    /// The object type of the core, the rate's index into the band
    /// tables, the rate, the channels.
    object_type: u8 = 0,
    rate_index: u8 = 0,
    rate: u32 = 0,
    channels: u8 = 0,
};

pub const Error = error{ Corrupt, Unsupported };

/// An ADTS frame's header, as its first seven bytes say.
pub const Adts = struct {
    config: Config,
    /// The frame's length with its header, the header's own, and the raw
    /// data blocks it holds.
    length: u32,
    header: u32,
    blocks: u32,
    protected: bool,
};

/// The header at the front of `bytes`, or null when there is none: no
/// syncword, a layer other than 0, a reserved rate, a length shorter than
/// the header.
pub fn adts(bytes: []const u8) ?Adts {
    if (bytes.len < 7) return null;
    if (bytes[0] != 0xFF or (bytes[1] & 0xF6) != 0xF0) return null;
    const protected = bytes[1] & 1 == 0;
    const profile = bytes[2] >> 6;
    const rate_index = (bytes[2] >> 2) & 0xF;
    if (rate_index > 12) return null;
    const channels = ((bytes[2] & 1) << 2) | (bytes[3] >> 6);
    const length = (@as(u32, bytes[3] & 3) << 11) | (@as(u32, bytes[4]) << 3) | (bytes[5] >> 5);
    const header: u32 = if (protected) 9 else 7;
    if (length < header) return null;
    return .{
        .config = .{
            .object_type = profile + 1,
            .rate_index = rate_index,
            .rate = tables.sample_rates[rate_index],
            .channels = channels,
        },
        .length = length,
        .header = header,
        .blocks = (bytes[6] & 3) + 1,
        .protected = protected,
    };
}

/// Whether two headers are of one stream: the same version, profile,
/// rate and channels.
pub fn sameStream(a: []const u8, b: []const u8) bool {
    return (a[1] & 0xF8) == (b[1] & 0xF8) and (a[2] & 0xFD) == (b[2] & 0xFD) and (a[3] & 0xC0) == (b[3] & 0xC0);
}

/// An AudioSpecificConfig, as an MP4's `esds` holds it.
pub fn audioSpecific(bytes: []const u8) Error!Config {
    var bits: Bits = .{ .bytes = bytes };
    var out: Config = .{};
    var object_type = objectType(&bits);
    rateOf(&bits, &out);
    out.channels = @intCast(bits.read(4));
    if (object_type == 5 or object_type == 29) {
        // SBR's rate, then the core's type.
        var sbr: Config = .{};
        rateOf(&bits, &sbr);
        object_type = objectType(&bits);
    }
    out.object_type = object_type;
    if (object_type != LC) return error.Unsupported;
    // GASpecificConfig.
    if (bits.bit()) return error.Unsupported; // frames of 960
    if (bits.bit()) bits.skip(14); // a core coder's delay
    _ = bits.bit(); // the extension flag, nothing for LC
    if (out.channels == 0) out.channels = try programConfig(&bits);
    if (bits.overrun()) return error.Corrupt;
    if (out.rate == 0) return error.Corrupt;
    return out;
}

fn objectType(bits: *Bits) u8 {
    const kind: u8 = @intCast(bits.read(5));
    return if (kind == 31) @intCast(32 + bits.read(6)) else kind;
}

/// A rate's index, or 15 and the rate itself - whose band tables are
/// those of the nearest rate below it.
fn rateOf(bits: *Bits, out: *Config) void {
    const index: u8 = @intCast(bits.read(4));
    if (index != 15) {
        if (index > 12) return;
        out.rate_index = index;
        out.rate = tables.sample_rates[index];
        return;
    }
    out.rate = bits.read(24);
    const floors = [_]u32{ 92017, 75132, 55426, 46009, 37566, 27713, 23004, 18783, 13856, 11502, 9391 };
    out.rate_index = 11;
    for (floors, 0..) |floor, i| {
        if (out.rate >= floor) {
            out.rate_index = @intCast(i);
            break;
        }
    }
}

/// A program config element: its channels - each front, side and back
/// element one or two, each LFE one - with the rest passed over.
pub fn programConfig(bits: *Bits) Error!u8 {
    bits.skip(4 + 2 + 4); // its tag, the object type, the rate
    const front = bits.read(4);
    const side = bits.read(4);
    const back = bits.read(4);
    const lfe = bits.read(2);
    const data = bits.read(3);
    const coupling = bits.read(4);
    if (bits.bit()) bits.skip(4); // a mono mixdown
    if (bits.bit()) bits.skip(4); // a stereo mixdown
    if (bits.bit()) bits.skip(3); // a matrix mixdown
    var channels: u32 = 0;
    for (0..front + side + back) |_| {
        channels += if (bits.bit()) 2 else 1;
        bits.skip(4);
    }
    channels += lfe;
    bits.skip(4 * (lfe + data));
    bits.skip(5 * coupling);
    bits.alignByte();
    bits.skip(8 * bits.read(8)); // the comment
    if (bits.overrun()) return error.Corrupt;
    if (channels == 0 or channels > 2) return error.Unsupported;
    return @intCast(channels);
}

test "an ADTS header and an AudioSpecificConfig" {
    const std = @import("std");
    // LC, 48 kHz, stereo, 371 bytes, no CRC, one block.
    const header = [_]u8{ 0xFF, 0xF1, 0x4C, 0x80, 0x2E, 0x7F, 0xFC };
    const h = adts(&header).?;
    try std.testing.expectEqual(@as(u8, 2), h.config.object_type);
    try std.testing.expectEqual(@as(u32, 48000), h.config.rate);
    try std.testing.expectEqual(@as(u8, 2), h.config.channels);
    try std.testing.expectEqual(@as(u32, 371), h.length);
    try std.testing.expectEqual(@as(u32, 7), h.header);
    try std.testing.expectEqual(@as(u32, 1), h.blocks);
    // An MP3 frame's header is none.
    try std.testing.expect(adts(&.{ 0xFF, 0xFB, 0x90, 0x64, 0, 0, 0 }) == null);

    // LC, 44.1 kHz, mono, and the extension saying no SBR.
    const lc = try audioSpecific(&.{ 0x12, 0x08, 0x56, 0xE5, 0x00 });
    try std.testing.expectEqual(@as(u32, 44100), lc.rate);
    try std.testing.expectEqual(@as(u8, 1), lc.channels);
    // HE-AAC: type 5, a core at 24 kHz in stereo, SBR at 48 kHz, LC.
    const he = try audioSpecific(&.{ 0x2B, 0x11, 0x88, 0x00 });
    try std.testing.expectEqual(@as(u32, 24000), he.rate);
    try std.testing.expectEqual(@as(u8, 2), he.channels);
    try std.testing.expectEqual(@as(u8, 2), he.object_type);
    // AAC Main is refused.
    try std.testing.expectError(error.Unsupported, audioSpecific(&.{ 0x0A, 0x10 }));
}
