// SPDX-License-Identifier: MIT
//! GetMediaTrack: what a track is.

const sdk = @import("sdk");
const media = sdk.media;
const MediaBase = @import("../media_base.zig").MediaBase;
const _file = @import("_file.zig");

/// Says what a track of a container file is.
///
/// SYNOPSIS:
/// ```zig
/// fn GetMediaTrack(base: *MediaBase, file: *media.MediaFile, track: u32, info: *media.MediaTrack) i32
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `file`: an open file.
/// - `track`: which, from 0 to the info's `tracks` less one.
/// - `info`: where it goes.
///
/// RESULT:
/// MERR_OK, or MERR_NOTRACK - and `info` is left as it is - for a number
/// past the last.
///
/// BEHAVIOR:
/// Its kind and codec (MTRACK_*, MCODEC_*) - a codec the library does not
/// know is MCODEC_UNKNOWN, its packets handed out all the same - its
/// number in the file, how many packets it has, its timescale, the
/// priming before what it presents and how much it presents in that
/// timescale (its first edit, or iTunes's note for sound without one),
/// how long it lasts in microseconds; a picture's size and its frames a
/// second times 1000; a sound's rate, channels and coded bits; the bits a
/// second it averages, its largest packet; the setup its codec wants -
/// the avcC or hvcC record, the AudioSpecificConfig - its language and
/// its handler's name.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// `info` is the caller's; the setup it points to is the file's, good
/// until it is closed.
///
/// NOTES:
/// For sound counted in its rate - nearly every file - `delay` and
/// `length` are frames of samples: an AAC encoder's priming is 1024 or
/// 2112, which a decoder decodes and does not play.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetMediaInfo`, `ReadMediaPacket`
///
/// EXAMPLES:
/// ```zig
/// var track: media.MediaTrack = .{};
/// if (mb.GetMediaTrack(film, info.audio, &track) != media.MERR_OK) return;
/// if (track.codec != media.MCODEC_AAC) return;
/// ```
pub fn GetMediaTrack(_: *MediaBase, file: *media.MediaFile, track: u32, info: *media.MediaTrack) i32 {
    const own = _file.fileOf(file);
    if (track >= own.track_count) return media.MERR_NOTRACK;
    info.* = own.tracks[track].info;
    return media.MERR_OK;
}
