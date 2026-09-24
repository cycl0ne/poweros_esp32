// SPDX-License-Identifier: MPL-2.0
//! SetWildStar: makes `*` a wildcard for the patterns parsed from now on,
//! or a plain character again.

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Makes `*` a wildcard, or a plain character again, for the patterns
/// parsed from now on.
///
/// SYNOPSIS:
/// ```zig
/// fn SetWildStar(ub: *UtilityBase, on: bool) bool
/// ```
///
/// SINCE: 1.0. LVO -216.
///
/// INPUTS:
/// - `on` - true makes `*` match any string, as `#?` does.
///
/// RESULT:
/// The setting before the call.
///
/// BEHAVIOR:
/// The setting is the library's, for every task: it changes how everyone's
/// patterns parse. Patterns parsed already keep their tokens. It is off
/// when the system starts.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It is one store.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// A program that changes the setting should put it back, which is what
/// the result is for.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParsePattern`, `ParsePatternNoCase`
///
/// EXAMPLES:
/// ```zig
/// const old = ub.SetWildStar(true);
/// defer _ = ub.SetWildStar(old);
/// ```
pub fn SetWildStar(ub: *UtilityBase, on: bool) bool {
    const old = ub.wild_star;
    ub.wild_star = on;
    return old;
}
