// SPDX-License-Identifier: MPL-2.0
//! MatchPattern: whether a string matches a pattern from `ParsePattern`.

const _pattern = @import("_pattern.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Tells whether a string matches a pattern made by `ParsePattern`.
///
/// SYNOPSIS:
/// ```zig
/// fn MatchPattern(ub: *UtilityBase, pattern: [*:0]const u8, string: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0, UTF-8 since 1.7. LVO -208.
///
/// INPUTS:
/// - `pattern` - the tokens from `ParsePattern`, not the pattern's text.
/// - `string` - the string to match, in UTF-8.
///
/// RESULT:
/// True if the whole string matches. False if it does not, and also on
/// failure, which only IoErr tells apart: `ERROR_TOO_MANY_LEVELS` when the
/// backtracking needs more than 1024 frames, `ERROR_NO_FREE_STORE` without
/// memory for them.
///
/// BEHAVIOR:
/// The string is matched a character at a time, not a byte at a time; a
/// byte of it that is no UTF-8 reads as U+FFFD (sdk.utility.utf8), which
/// `?` takes as it takes any character.
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
/// `ParsePattern`, `MatchPatternNoCase`
///
/// EXAMPLES:
/// ```zig
/// if (ub.MatchPattern(@ptrCast(&tokens), name)) list(name);
/// ```
pub fn MatchPattern(ub: *UtilityBase, pattern: [*:0]const u8, string: [*:0]const u8) bool {
    return _pattern.matchWith(ub, pattern, string, false);
}
