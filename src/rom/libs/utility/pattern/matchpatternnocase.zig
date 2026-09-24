// SPDX-License-Identifier: MPL-2.0
//! MatchPatternNoCase: whether a string matches a pattern from
//! `ParsePatternNoCase`, without case.

const _pattern = @import("_pattern.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Tells whether a string matches a pattern made by `ParsePatternNoCase`,
/// without regard to case.
///
/// SYNOPSIS:
/// ```zig
/// fn MatchPatternNoCase(ub: *UtilityBase, pattern: [*:0]const u8, string: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -212.
///
/// INPUTS:
/// - `pattern` - the tokens from `ParsePatternNoCase`.
/// - `string` - the string to match.
///
/// RESULT:
/// True if the whole string matches. False if it does not, and also on
/// failure, which only IoErr tells apart: `ERROR_TOO_MANY_LEVELS` when the
/// backtracking needs more than 1024 frames, `ERROR_NO_FREE_STORE` without
/// memory for them.
///
/// BEHAVIOR:
/// Each character of the string goes through `ToUpper` before it is
/// compared, so the pattern must be upper case as well, which is what
/// `ParsePatternNoCase` makes it.
///
/// Every way the pattern can match is tried, backtracking on a stack of
/// frames rather than the machine's: 16 on the caller's stack, then chunks
/// of 64 from `AllocVec`, all given back before it returns. A repeated
/// group takes at most three frames a character, so a name of 255
/// characters always fits.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It may allocate.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do; only a process gets the IoErr.
///
/// OWNERSHIP:
/// Nothing is kept: the frames taken are given back before it returns. The
/// tokens are only read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParsePatternNoCase`, `MatchPattern`
///
/// EXAMPLES:
/// ```zig
/// if (ub.MatchPatternNoCase(@ptrCast(&tokens), name)) list(name);
/// ```
pub fn MatchPatternNoCase(ub: *UtilityBase, pattern: [*:0]const u8, string: [*:0]const u8) bool {
    return _pattern.matchWith(ub, pattern, string, true);
}
