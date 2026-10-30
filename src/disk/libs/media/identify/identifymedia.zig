// SPDX-License-Identifier: MIT
//! IdentifyMedia: what kind of container some bytes begin.

const sdk = @import("sdk");
const media = sdk.media;
const MediaBase = @import("../media_base.zig").MediaBase;
const mp4 = @import("../mp4/_mp4.zig");

/// Says what kind of container a file is, by its first bytes.
///
/// SYNOPSIS:
/// ```zig
/// fn IdentifyMedia(base: *MediaBase, bytes: [*]const u8, length: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `bytes`: the first bytes of the file.
/// - `length`: how many; `MEDIA_IDENTIFY_BYTES` are enough.
///
/// RESULT:
/// MEDIA_MP4, or MEDIA_UNKNOWN.
///
/// BEHAVIOR:
/// An MP4 begins with a box: its size - 8 at least, or 1 for a size of 64
/// bits after it - and a kind one begins with: ISO's `ftyp`, or
/// QuickTime's `moov`, `mdat`, `wide`, `free`, `skip`, `pnot`. What
/// OpenMedia then reads may still turn out to be no MP4.
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
/// `OpenMedia`
///
/// EXAMPLES:
/// ```zig
/// if (mb.IdentifyMedia(&first, got) == media.MEDIA_MP4) playFilm(name);
/// ```
pub fn IdentifyMedia(_: *MediaBase, bytes: [*]const u8, length: u32) u32 {
    return if (mp4.identify(bytes[0..length])) media.MEDIA_MP4 else media.MEDIA_UNKNOWN;
}
