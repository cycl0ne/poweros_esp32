// SPDX-License-Identifier: MIT
//! GetMediaInfo: what a file is.

const sdk = @import("sdk");
const media = sdk.media;
const MediaBase = @import("../media_base.zig").MediaBase;
const _file = @import("_file.zig");

/// Says what a container file is.
///
/// SYNOPSIS:
/// ```zig
/// fn GetMediaInfo(base: *MediaBase, file: *media.MediaFile, info: *media.MediaInfo) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `file`: an open file.
/// - `info`: where it goes.
///
/// RESULT:
/// None: `info` is filled in.
///
/// BEHAVIOR:
/// Its kind (MEDIA_MP4), how many tracks it has, how long it lasts - the
/// longest track, or what the file says, in microseconds - whether its
/// tracks can seek, the first track of pictures and of sound, and the
/// title, the artist and the album its tags name, cut at 63 characters.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// `info` is the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetMediaTrack`, `GetMediaAttrs`
///
/// EXAMPLES:
/// ```zig
/// var info: media.MediaInfo = .{};
/// mb.GetMediaInfo(film, &info);
/// if (info.video == ~@as(u32, 0)) return; // no pictures
/// ```
pub fn GetMediaInfo(_: *MediaBase, file: *media.MediaFile, info: *media.MediaInfo) void {
    info.* = _file.fileOf(file).info;
}
