// SPDX-License-Identifier: MIT
//! IdentifyAudio: what some sound is, by its first bytes.

const sdk = @import("sdk");
const ac = sdk.audiocodec;
const AudioCodecBase = @import("../audiocodec_base.zig").AudioCodecBase;
const _identify = @import("_identify.zig");

/// Says what some sound is.
///
/// SYNOPSIS:
/// ```zig
/// fn IdentifyAudio(base: *AudioCodecBase, bytes: [*]const u8, length: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `bytes`, `length`: the first bytes of it - `AUDIO_IDENTIFY_BYTES` are
///   enough.
///
/// RESULT:
/// ACODEC_WAV, ACODEC_MP3, ACODEC_FLAC, ACODEC_VORBIS, ACODEC_AAC (SINCE
/// 1.6), or ACODEC_UNKNOWN.
///
/// BEHAVIOR:
/// A RIFF header naming WAVE is a WAV. "fLaC" is a FLAC, alone or behind
/// an ID3v2 tag that ends among the bytes given. An Ogg page whose first
/// packet is Vorbis's header is ACODEC_VORBIS, FLAC's is ACODEC_FLAC (and
/// refused when it is opened); another, such as Opus, is unknown. An MP4
/// - its first box an `ftyp` - is ACODEC_AAC, as is an ADTS header the
/// next one agrees with, alone or behind an ID3v2 tag; an MP4 whose sound
/// is not AAC is refused when it is opened - since 1.7 it is decoded when
/// it is MP3, FLAC or Vorbis. A Matroska file's first bytes say nothing
/// of what it holds: it is ACODEC_UNKNOWN, and opened all the same (SINCE
/// 1.7). Any other ID3v2 tag is an MP3, and so are
/// MPEG audio frames: a header that can be, followed by others at the
/// distances it gives - one header-like run of bytes alone is not enough.
/// An MP3 of layer I or II is identified as one, and refused when it is
/// opened.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenAudioStream`
///
/// EXAMPLES:
/// ```zig
/// if (acb.IdentifyAudio(&head, got) == ac.ACODEC_UNKNOWN) return;
/// ```
pub fn IdentifyAudio(_: *AudioCodecBase, bytes: [*]const u8, length: u32) u32 {
    return _identify.identify(bytes[0..length]);
}
