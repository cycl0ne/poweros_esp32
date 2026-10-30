// SPDX-License-Identifier: MIT
//! VideoErrorText: what an error code means.

const sdk = @import("sdk");
const vc = sdk.videocodec;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;

/// Says what an error code means, in words.
///
/// SYNOPSIS:
/// ```zig
/// fn VideoErrorText(base: *VideoCodecBase, code: i32) [*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `code`: a VCERR_* code.
///
/// RESULT:
/// A sentence fragment, lower case, no full stop: "nothing here decodes
/// its pictures".
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
/// `OpenVideoStream`, `DecodeVideoFrame`
///
/// EXAMPLES:
/// ```zig
/// _ = Printf(dl, "%s\n", .{vcb.VideoErrorText(err)});
/// ```
pub fn VideoErrorText(_: *VideoCodecBase, code: i32) [*:0]const u8 {
    return switch (code) {
        vc.VCERR_OK => "no error",
        vc.VCERR_NOMEMORY => "not enough memory",
        vc.VCERR_OPEN => "the file could not be opened",
        vc.VCERR_UNKNOWN => "not a film the library knows",
        vc.VCERR_UNSUPPORTED => "a form of it the library does not play",
        vc.VCERR_READ => "it could not be read",
        vc.VCERR_CORRUPT => "it is damaged",
        vc.VCERR_NOSEEK => "it cannot move to another place",
        vc.VCERR_END => "it has no more frames",
        vc.VCERR_NOCODEC => "nothing here decodes its pictures",
        vc.VCERR_BUSY => "the decoder is busy",
        vc.VCERR_NOSOUND => "it has no sound",
        else => "unknown error",
    };
}
