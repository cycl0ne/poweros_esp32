// SPDX-License-Identifier: MIT
//! MediaErrorText: what an error code means.

const sdk = @import("sdk");
const media = sdk.media;
const MediaBase = @import("../media_base.zig").MediaBase;

/// Says what an error code means, in words.
///
/// SYNOPSIS:
/// ```zig
/// fn MediaErrorText(base: *MediaBase, code: i32) [*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `code`: an MERR_* code.
///
/// RESULT:
/// A sentence fragment, lower case, no full stop: "the track has no more
/// packets".
///
/// BEHAVIOR:
/// A code it does not know is "unknown error".
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Locks: none.
/// - Process: a task will do.
///
/// OWNERSHIP:
/// The text is the library's, and does not change.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenMedia`, `ReadMediaPacket`
///
/// EXAMPLES:
/// ```zig
/// _ = Printf(dl, "%s\n", .{mb.MediaErrorText(err)});
/// ```
pub fn MediaErrorText(_: *MediaBase, code: i32) [*:0]const u8 {
    return switch (code) {
        media.MERR_OK => "no error",
        media.MERR_NOMEMORY => "not enough memory",
        media.MERR_OPEN => "the file could not be opened",
        media.MERR_UNKNOWN => "not a kind of file the library knows",
        media.MERR_UNSUPPORTED => "a form of it the library does not read",
        media.MERR_READ => "it could not be read",
        media.MERR_CORRUPT => "it is damaged",
        media.MERR_NOSEEK => "it cannot move to another place",
        media.MERR_END => "the track has no more packets",
        media.MERR_NOTRACK => "there is no such track",
        else => "unknown error",
    };
}
