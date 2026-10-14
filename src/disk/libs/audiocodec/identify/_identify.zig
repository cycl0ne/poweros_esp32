// SPDX-License-Identifier: MIT
//! What some sound is, by its first bytes: a RIFF WAVE header; "fLaC",
//! alone or behind an ID3v2 tag; an Ogg page whose first packet names
//! Vorbis or FLAC; an ID3v2 tag in front of anything else, which only an
//! MP3 has; or MPEG audio frames, one that can be followed by others that
//! agree with it.

const sdk = @import("sdk");
const ac = sdk.audiocodec;
const _stream = @import("../stream/_stream.zig");
const layer3 = @import("../mp3/layer3.zig");

pub fn identify(bytes: []const u8) u32 {
    if (bytes.len >= 12 and _stream.same(bytes, "RIFF") and _stream.same(bytes[8..], "WAVE")) return ac.ACODEC_WAV;
    if (_stream.same(bytes, "fLaC")) return ac.ACODEC_FLAC;
    if (_stream.same(bytes, "OggS")) return oggKind(bytes);
    if (bytes.len >= 10 and _stream.same(bytes, "ID3")) {
        const size = id3Size(bytes);
        if (bytes.len >= size + 4 and _stream.same(bytes[size..], "fLaC")) return ac.ACODEC_FLAC;
        return ac.ACODEC_MP3;
    }
    if (layer3.startsStream(bytes)) return ac.ACODEC_MP3;
    return ac.ACODEC_UNKNOWN;
}

/// What an Ogg stream carries, by its first packet: Vorbis's header, or
/// FLAC's mapping of itself into Ogg.
fn oggKind(bytes: []const u8) u32 {
    if (bytes.len < 27) return ac.ACODEC_UNKNOWN;
    const body = 27 + @as(usize, bytes[26]);
    if (bytes.len < body + 7) return ac.ACODEC_UNKNOWN;
    const first = bytes[body..];
    if (first[0] == 1 and _stream.same(first[1..], "vorbis")) return ac.ACODEC_VORBIS;
    if (first[0] == 0x7F and _stream.same(first[1..], "FLAC")) return ac.ACODEC_FLAC;
    return ac.ACODEC_UNKNOWN;
}

/// An ID3v2 tag's whole length: its header, its body, its footer.
fn id3Size(bytes: []const u8) usize {
    const body = @as(usize, bytes[6] & 0x7F) << 21 | @as(usize, bytes[7] & 0x7F) << 14 | @as(usize, bytes[8] & 0x7F) << 7 | (bytes[9] & 0x7F);
    const footer: usize = if (bytes[5] & 0x10 != 0) 10 else 0;
    return 10 + body + footer;
}
