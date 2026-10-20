// SPDX-License-Identifier: MPL-2.0
//! RtaErrorText: An RTAERR_ code in words.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;

/// An error code in words.
///
/// SYNOPSIS:
/// ```zig
/// fn RtaErrorText(rb: *RtaBase, error_code: i32) [*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `error_code` - an `RTAERR_` code.
///
/// RESULT:
/// A short sentence, lower case, with no full stop: "unknown error" for a
/// code the library does not have.
///
/// BEHAVIOR:
/// A constant string for each code.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The string is the library's, never freed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RtaLastError`
///
/// EXAMPLES:
/// ```zig
/// io.printf("no output: %s\n", .{rb.RtaErrorText(code)});
/// ```
pub fn RtaErrorText(_: *RtaBase, error_code: i32) [*:0]const u8 {
    return switch (error_code) {
        err.RTAERR_OK => "no error",
        err.RTAERR_NO_DRIVER => "no such sound driver",
        err.RTAERR_BAD_TAGS => "the output was not told enough to come up",
        err.RTAERR_NO_MEMORY => "not enough memory",
        err.RTAERR_NOT_SUPPORTED => "the output does not do that",
        err.RTAERR_NO_OUTPUT => "the output is not there",
        err.RTAERR_IN_USE => "something else has it",
        err.RTAERR_BAD_ARG => "the arguments do not make sense",
        err.RTAERR_NOT_RUNNING => "the output is not playing",
        err.RTAERR_BAD_MODE => "the output has no such mode",
        err.RTAERR_IO => "the part did not answer on its bus",
        err.RTAERR_NO_INPUT => "the way in is not there",
        else => "unknown error",
    };
}
