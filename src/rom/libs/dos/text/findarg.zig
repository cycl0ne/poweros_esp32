// SPDX-License-Identifier: MPL-2.0
//! FindArg: which item of a template a keyword names.

const DosBase = @import("../dos_base.zig").DosBase;

/// Finds which item of a template a keyword names.
///
/// SYNOPSIS:
/// ```zig
/// fn FindArg(db: *DosBase, template: [*:0]const u8, keyword: [*:0]const u8) i32
/// ```
///
/// SINCE: 1.0. LVO -468.
///
/// INPUTS:
/// - `template` - a ReadArgs template.
/// - `keyword` - the word to look for.
///
/// RESULT:
/// The item's number, from 0; -1 when no item has that name.
///
/// BEHAVIOR:
/// Every alias of every item counts ("Q=QUIET/S" is found by "q" and by
/// "quiet"), case ignored; the modifiers after '/' are not part of a name.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadArgs`, `ReadItem`
///
/// EXAMPLES:
/// ```zig
/// const n = dos_lib.FindArg("FROM/M/A,TO/A,Q=QUIET/S", "quiet"); // 2
/// ```
pub fn FindArg(db: *DosBase, template: [*:0]const u8, keyword: [*:0]const u8) i32 {
    const ub = db.utility_base;
    const wlen = db.utility_base.Strlen(keyword);
    var t = template;
    var argno: i32 = 0;
    while (true) {
        var wp: usize = 0;
        var c: u8 = undefined;
        while (true) {
            c = t[0];
            t += 1;
            if (c == 0) return if (wp == wlen) argno else -1;
            if (c == ',' or c == '=' or c == '/') {
                if (wp == wlen) return argno;
                break;
            }
            if (ub.ToUpper(c) != ub.ToUpper(keyword[wp])) {
                // Not this one: on to the next alias or item.
                c = t[0];
                t += 1;
                if (c == 0) return -1;
                break;
            }
            wp += 1;
        }
        while (true) {
            if (c == '=') break;
            if (c == ',') {
                argno += 1;
                break;
            }
            c = t[0];
            t += 1;
            if (c == 0) return -1;
        }
    }
}
