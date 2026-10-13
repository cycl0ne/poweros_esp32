// SPDX-License-Identifier: MIT
//! AudioErrorText: what an error code means.

const sdk = @import("sdk");
const ac = sdk.audiocodec;
const AudioCodecBase = @import("../audiocodec_base.zig").AudioCodecBase;

/// Says what an error code means.
///
/// SYNOPSIS:
/// ```zig
/// fn AudioErrorText(base: *AudioCodecBase, code: i32) [*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `code`: an ACERR_*.
///
/// RESULT:
/// A sentence for a person, never null: "unknown error" for a code the
/// library does not have.
///
/// BEHAVIOR:
/// None beyond the result.
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
/// `OpenAudioStream`, `DecodeAudio`, `SeekAudio`
///
/// EXAMPLES:
/// ```zig
/// _ = Printf(dl, "%s\n", .{acb.AudioErrorText(err)});
/// ```
pub fn AudioErrorText(_: *AudioCodecBase, code: i32) [*:0]const u8 {
    return switch (code) {
        ac.ACERR_OK => "no error",
        ac.ACERR_NOMEMORY => "not enough memory",
        ac.ACERR_OPEN => "the file could not be opened",
        ac.ACERR_UNKNOWN => "not a kind of sound the library knows",
        ac.ACERR_UNSUPPORTED => "a form of it the library does not decode",
        ac.ACERR_READ => "it could not be read",
        ac.ACERR_CORRUPT => "it is damaged",
        ac.ACERR_NOSEEK => "it cannot move to another place",
        else => "unknown error",
    };
}
