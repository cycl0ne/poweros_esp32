// SPDX-License-Identifier: MPL-2.0
//! ParsePattern: makes a pattern into tokens for `MatchPattern`.

const _pattern = @import("_pattern.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Turns a pattern into the tokens `MatchPattern` works on.
///
/// SYNOPSIS:
/// ```zig
/// fn ParsePattern(ub: *UtilityBase, source: [*:0]const u8, dest: [*]u8, size: usize) isize
/// ```
///
/// SINCE: 1.0. LVO -200.
///
/// INPUTS:
/// - `source` - the pattern.
/// - `dest` - where the tokens go.
/// - `size` - the bytes at `dest`. `sdk.utility.parsedSize(len)` for a
///   pattern of `len` characters is always enough.
///
/// RESULT:
/// 1 if the pattern has wildcards, 0 if it is a plain name (the escapes
/// resolved), -1 on failure. On failure IoErr is `ERROR_BAD_TEMPLATE` for
/// a pattern that does not parse - unbalanced groups, a class without its
/// `]`, a byte 0x80-0x8B - or `ERROR_LINE_TOO_LONG` when `dest` is too
/// small, and `dest` holds an empty pattern.
///
/// BEHAVIOR:
/// The syntax:
///
/// - `?` - any one character.
/// - `#x` - any number of `x`, where `x` is one character, class or group;
///   `#?` is any string.
/// - `*` - any string, when `SetWildStar` has made it a wildcard; otherwise
///   itself.
/// - `(a|b|c)` - one of the alternatives, which may be empty.
/// - `~x` - anything `x` does not match. A `~` at the end is itself.
/// - `[abc]`, `[a-z]`, `[~a-z]` - a class. A `-` first or last is itself.
/// - `%` - nothing, the empty string.
/// - `'x` - `x` itself.
///
/// A pattern that parses leaves IoErr as it was.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. A failure is reported in the IoErr of whichever
///   process was interrupted.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do; only a process gets the IoErr.
///
/// OWNERSHIP:
/// Nothing is allocated. The tokens are the caller's, and any number of
/// tasks may match against them at once: matching never writes them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MatchPattern`, `ParsePatternNoCase`, `SetWildStar`
///
/// EXAMPLES:
/// ```zig
/// var tokens: [sdk.utility.parsedSize(64)]u8 = undefined;
/// if (ub.ParsePattern(pattern, &tokens, tokens.len) < 0) return error.BadPattern;
/// if (ub.MatchPattern(@ptrCast(&tokens), name)) list(name);
/// ```
pub fn ParsePattern(ub: *UtilityBase, source: [*:0]const u8, dest: [*]u8, size: usize) isize {
    return _pattern.parseWith(ub, source, dest, size, false);
}
