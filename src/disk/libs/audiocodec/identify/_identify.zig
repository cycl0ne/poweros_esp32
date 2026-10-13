// SPDX-License-Identifier: MIT
//! What some sound is, by its first bytes: a RIFF WAVE header; an ID3v2
//! tag, which only an MP3 starts with; or MPEG audio frames, one that can
//! be followed by others that agree with it.

const sdk = @import("sdk");
const ac = sdk.audiocodec;
const _stream = @import("../stream/_stream.zig");
const layer3 = @import("../mp3/layer3.zig");

pub fn identify(bytes: []const u8) u32 {
    if (bytes.len >= 12 and _stream.same(bytes, "RIFF") and _stream.same(bytes[8..], "WAVE")) return ac.ACODEC_WAV;
    if (bytes.len >= 10 and _stream.same(bytes, "ID3")) return ac.ACODEC_MP3;
    if (layer3.startsStream(bytes)) return ac.ACODEC_MP3;
    return ac.ACODEC_UNKNOWN;
}
