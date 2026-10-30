// SPDX-License-Identifier: MIT
//! GetVideoStreamAttrs: a film's tags.

const sdk = @import("sdk");
const vc = sdk.videocodec;
const utility = sdk.utility;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("_stream.zig");

/// Answers media.library's tags for a film: its names, its cover, its
/// chapters.
///
/// SYNOPSIS:
/// ```zig
/// fn GetVideoStreamAttrs(base: *VideoCodecBase, stream: *vc.VideoStream, tags: ?[*]const utility.TagItem) u32
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `stream`: what OpenVideoStream made.
/// - `tags`: media.library's `MDA_*` tags, each with where its answer
///   goes.
///
/// RESULT:
/// How many of the tags were answered.
///
/// BEHAVIOR:
/// They are media.library's GetMediaAttrs on the film, as it is: the
/// title, the artist and the rest at full length, the year, the chapters.
/// A cover is not kept: `MDA_Picture` answers null.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// Texts and the chapters are the film's, good until the stream is
/// closed.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetVideoStreamInfo`, media.library's `GetMediaAttrs`
///
/// EXAMPLES:
/// ```zig
/// var chapters: u32 = 0;
/// _ = vcb.GetVideoStreamAttrs(film, &[_]utility.TagItem{
///     .{ .tag = media.MDA_Chapters, .data = @intFromPtr(&chapters) },
///     .{},
/// });
/// ```
pub fn GetVideoStreamAttrs(_: *VideoCodecBase, stream: *vc.VideoStream, tags: ?[*]const utility.TagItem) u32 {
    const s = _stream.of(stream);
    return s.mb.GetMediaAttrs(s.file, tags);
}
