// SPDX-License-Identifier: MIT
//! ReadMediaPacket: a track's next packet.

const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const MediaBase = @import("../media_base.zig").MediaBase;
const _file = @import("_file.zig");
const File = _file.File;
const Track = _file.Track;

/// Hands out a track's next packet, as it is coded.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadMediaPacket(base: *MediaBase, file: *media.MediaFile, track: u32, packet: *media.MediaPacket) i32
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `file`: an open file.
/// - `track`: which track, as GetMediaTrack numbers them.
/// - `packet`: where it goes.
///
/// RESULT:
/// MERR_OK; MERR_END after the track's last packet; MERR_NOTRACK,
/// MERR_READ, MERR_NOMEMORY, MERR_CORRUPT, MERR_NOSEEK for a packet
/// behind what a read function has read, or MERR_UNSUPPORTED for a
/// Matroska track packed in a way the library does not unpack, or
/// encrypted. Only with MERR_OK is `packet` filled in.
///
/// BEHAVIOR:
/// The packet the track's cursor is at - its first after OpenMedia, the
/// one a seek found after SeekMedia - and the cursor on to the next, in
/// the order they are decoded. Its bytes, its size, whether a decoder can
/// start at it (MPKT_KEY), when it is due and when it is decoded in
/// microseconds from the start of what the file presents - below 0 for
/// priming - how long it lasts, its number in the track, and its decode
/// time in the track's own ticks. The bytes are read with the rest of
/// their chunk, as far as the track's buffer holds them, so the packets
/// after it come out of the buffer.
///
/// A Matroska track walks the clusters from where it is to its next
/// block, past the other tracks', reading the file in runs into its
/// buffer; the frames of a block laced are handed out one at a time, the
/// time of each after the first from how long the track says a frame
/// lasts (SINCE 1.2).
///
/// A track whose frames are packed has them handed out unpacked (SINCE
/// 1.8): the bytes each frame begins with put back where the track is
/// stripped of them (ContentCompAlgo 3), and the frame unpacked by
/// compression.library where it is packed with zlib (ContentCompAlgo 0,
/// which mkvmerge has written subtitle tracks with for years, and which
/// a board without compression.library on its disk answers
/// MERR_UNSUPPORTED for). A track packed any other way, or encrypted,
/// answers MERR_UNSUPPORTED before its first packet.
///
/// CONTEXT:
/// - Waits: yes, on the file, and while another task reads another track
///   of it.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process for a file; a task will do with MDA_ReadFunc.
///
/// OWNERSHIP:
/// The bytes are the library's, good until the next ReadMediaPacket or
/// SeekMedia on the same track, or CloseMedia.
///
/// NOTES:
/// Two tasks may each read a track of their own at once - the sound and
/// the picture of a film; the file is read by one of them at a time. One
/// track is read by one task at a time.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SeekMedia`, `GetMediaTrack`
///
/// EXAMPLES:
/// ```zig
/// var packet: media.MediaPacket = .{};
/// while (mb.ReadMediaPacket(film, info.video, &packet) == media.MERR_OK) {
///     decode(packet.data.?[0..packet.size], packet.pts);
/// }
/// ```
pub fn ReadMediaPacket(_: *MediaBase, file: *media.MediaFile, track: u32, packet: *media.MediaPacket) i32 {
    const own = _file.fileOf(file);
    if (track >= own.track_count) return media.MERR_NOTRACK;
    return _file.moduleOf(own).?.ReadContainerPacket(own, track, packet);
}
