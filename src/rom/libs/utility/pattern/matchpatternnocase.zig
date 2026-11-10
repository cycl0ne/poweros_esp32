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
/// SINCE: 1.0, UTF-8 since 1.7. LVO -212.
///
/// INPUTS:
/// - `pattern` - the tokens from `ParsePatternNoCase` or `ParsePattern`.
/// - `string` - the string to match, in UTF-8.
///
/// RESULT:
/// True if the whole string matches. False if it does not, and also on
/// failure, which only IoErr tells apart: `ERROR_TOO_MANY_LEVELS` when the
/// backtracking needs more than 1024 frames, `ERROR_NO_FREE_STORE` without
/// memory for them.
///
/// BEHAVIOR:
/// A character of the string matches one of the pattern when the two
/// fold to the same by Unicode's simple case folding: `Ä` matches `ä`,
/// `Σ` matches `ς`. Both sides are folded, so the tokens of `ParsePattern`
/// match without case as well as those of `ParsePatternNoCase`. The
/// string is matched a character at a time, as `MatchPattern` says.
///
/// Every way the pattern can match is tried, backtracking on a stack of
/// frames rather than the machine's: 16 on the caller's stack, then chunks
/// of 64 from `AllocVec`, all given back before it returns. A repeated
/// group takes at most three frames a character, so a name of 255
/// bytes always fits.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It may allocate.
/// - Locks: none taken, none needed.
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
