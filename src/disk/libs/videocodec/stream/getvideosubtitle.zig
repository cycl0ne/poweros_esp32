// SPDX-License-Identifier: MIT
//! GetVideoSubtitle: what a film's subtitles show at a time.

const sdk = @import("sdk");
const vc = sdk.videocodec;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("_stream.zig");
const _subtitle = @import("../subtitle/_subtitle.zig");

/// Says what the chosen subtitles show at a time: lines of text, or a
/// picture.
///
/// SYNOPSIS:
/// ```zig
/// fn GetVideoSubtitle(base: *VideoCodecBase, stream: *vc.VideoStream, time: i64, subtitle: *vc.VideoSubtitle) i32
/// ```
///
/// SINCE: 1.3. LVO -68.
///
/// INPUTS:
/// - `stream`: what OpenVideoStream made.
/// - `time`: the time of the frame being shown, in microseconds.
/// - `subtitle`: where what shows goes.
///
/// RESULT:
/// VCERR_OK, `subtitle` filled in; or VCERR_END when nothing shows - no
/// subtitles chosen, none at this time - and `subtitle` is cleared.
///
/// BEHAVIOR:
/// The subtitles are read ahead of the film by a process of the
/// library's, so the call does not wait on the file: a subtitle not yet
/// read - just after a seek, on a slow disk - is not shown; after a seek
/// they are read from five seconds before, for the lines still showing.
/// Text is
/// UTF-8, its lines apart by `\n`: SubRip's tags and SubStation Alpha's
/// codes are taken out, and of SubStation Alpha only the dialogue is kept
/// - signs placed on the picture and drawings are left out. Lines that
/// show at once come one under another, in the order they began;
/// VSUB_ITALIC says that all of it is in italics. A Blu-ray's picture
/// (PGS) comes as `pixels`, fitted to the film's size where the disc's
/// is another, and shows until the next; a picture is handed out before
/// text. `start` and `end` say from when up to when it shows the same:
/// a program draws it again only when they change. `end` is
/// `std.math.maxInt(i64)` while the track has not said.
///
/// CONTEXT:
/// - Waits: no - but a stream whose subtitles could not get a process of
///   their own reads the file here.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// `subtitle` is the caller's; the text and the pixels are the library's,
/// good until the call is made again, SeekVideo or SelectVideoTrack moves
/// the film, or it is closed. Called by the task that decodes the
/// pictures.
///
/// NOTES:
/// Asked about each frame shown, as a player does, it reads ahead
/// ten seconds at most.
///
/// BUGS:
/// A subtitle that began more than five seconds before the place a seek
/// lands on is missed there.
///
/// SEE ALSO:
/// `SelectVideoTrack`, `GetVideoTrack`, `VCA_Subtitles`
///
/// EXAMPLES:
/// ```zig
/// var shown: vc.VideoSubtitle = .{};
/// if (vcb.GetVideoSubtitle(film, frame.time, &shown) == vc.VCERR_OK and
///     (shown.start != last.start or shown.end != last.end)) drawSubtitle(&shown);
/// ```
pub fn GetVideoSubtitle(_: *VideoCodecBase, stream: *vc.VideoStream, time: i64, subtitle: *vc.VideoSubtitle) i32 {
    const s = _stream.of(stream);
    const reader = s.subtitles orelse {
        subtitle.* = .{};
        return vc.VCERR_END;
    };
    return _subtitle.subtitle(reader, time, subtitle);
}
