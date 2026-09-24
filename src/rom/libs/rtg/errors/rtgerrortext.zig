// SPDX-License-Identifier: MPL-2.0
//! RtgErrorText: An error in words.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;

/// Says what an `RTGERR_` code means, in words.
///
/// SYNOPSIS:
/// ```zig
/// fn RtgErrorText(_: *RtgBase, error_code: i32) [*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -204.
///
/// INPUTS:
/// - `error_code` - the code.
///
/// RESULT:
/// The text; "unknown error" for a code it does not know, never null.
///
/// BEHAVIOR:
/// The text is the library's, so a program built against an older SDK
/// still prints something true about a newer code.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The text is read-only.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RtgLastError`
///
/// EXAMPLES:
/// ```zig
/// report(rb.RtgErrorText(code));
/// ```
pub fn RtgErrorText(_: *RtgBase, error_code: i32) [*:0]const u8 {
    return switch (error_code) {
        err.RTGERR_OK => "no error",
        err.RTGERR_NO_DRIVER => "no such display driver",
        err.RTGERR_BAD_TAGS => "the board was not told enough to come up",
        err.RTGERR_NO_MEMORY => "not enough memory",
        err.RTGERR_NOT_SUPPORTED => "the board does not do that",
        err.RTGERR_NO_DISPLAY => "there is no display",
        err.RTGERR_IN_USE => "something still has it",
        err.RTGERR_BAD_ARG => "the arguments do not make sense",
        err.RTGERR_BOUNDS => "outside the buffer",
        err.RTGERR_TIMEOUT => "the display did not answer in time",
        err.RTGERR_NO_MODE => "the board is in no mode yet",
        err.RTGERR_BAD_FORMAT => "not a pixel format this can do",
        err.RTGERR_BAD_MODE => "the board has no such mode",
        err.RTGERR_NOT_DISPLAYABLE => "that buffer cannot be displayed",
        err.RTGERR_IO => "the bus did not answer",
        err.RTGERR_UNDERRUN => "the bus ran ahead of its data",
        else => "unknown error",
    };
}
