// SPDX-License-Identifier: MIT
//! SeekMedia: a track moved to a packet a decoder can start at.

const sdk = @import("sdk");
const media = sdk.media;
const MediaBase = @import("../media_base.zig").MediaBase;
const _file = @import("_file.zig");
const cursor = @import("../mp4/cursor.zig");
const blocks = @import("../mkv/blocks.zig");

/// Moves a track to the packet a decoder can start at, at or before a
/// time.
///
/// SYNOPSIS:
/// ```zig
/// fn SeekMedia(base: *MediaBase, file: *media.MediaFile, track: u32, time: i64) i32
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `file`: an open file.
/// - `track`: which track.
/// - `time`: microseconds from the start of what the file presents.
///
/// RESULT:
/// MERR_OK; MERR_NOTRACK; MERR_NOSEEK for a file read through
/// MDA_ReadFunc.
///
/// BEHAVIOR:
/// The packet decoded last at or before `time` is found in the track's
/// times - the first when `time` is before them all, the last when it is
/// past them - and from it the last one a decoder can start at (MPKT_KEY):
/// for pictures the key frame before it, for sound that packet itself.
/// The next ReadMediaPacket on the track hands that packet out; its `pts`
/// says where the track landed. The other tracks stay where they are.
///
/// A Matroska track starts at the last cue point at or before the time -
/// of its own where it has any, else of any track. A track of pictures
/// with cues of its own lands on the block it names; sound, and a track
/// without cues of its own, walks on from there to its last block at or
/// before the time (SINCE 1.2). A file without cues is walked from its
/// first cluster.
///
/// CONTEXT:
/// - Waits: no for an MP4; on the file for a Matroska file, which it
///   reads.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the one that reads the track: a task will do for an MP4, a
///   Matroska file wants a process.
///
/// OWNERSHIP:
/// The last packet handed out of the track is gone.
///
/// NOTES:
/// A film is moved by moving its pictures first, then its sound to the
/// time the picture's key frame landed on. A sound decoder that overlaps
/// its packets - AAC - wants the packet before the one it plays from, to
/// begin.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadMediaPacket`
///
/// EXAMPLES:
/// ```zig
/// _ = mb.SeekMedia(film, info.video, 90 * 1_000_000); // a minute and a half in
/// ```
pub fn SeekMedia(_: *MediaBase, file: *media.MediaFile, track: u32, time: i64) i32 {
    const own = _file.fileOf(file);
    if (track >= own.track_count) return media.MERR_NOTRACK;
    if (!_file.seekable(own)) return media.MERR_NOSEEK;
    const t = &own.tracks[track];
    if (own.info.kind == media.MEDIA_MKV) return blocks.seek(own, t, time);
    const ticks = _file.ticksOf(time - t.empty_us, t.info.timescale) + t.media_start;
    const sample = cursor.sampleAt(&t.tables, @intCast(@max(ticks, 0)));
    cursor.moveTo(&t.tables, &t.at, t.tables.keyAtOrBefore(sample));
    return media.MERR_OK;
}
