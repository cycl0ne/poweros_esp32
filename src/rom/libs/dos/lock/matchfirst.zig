// SPDX-License-Identifier: MPL-2.0
//! MatchFirst: starts a pattern search and finds the first object.

const sdk = @import("sdk");
const dos = sdk.dos;
const utility = sdk.utility;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const single = _lock.single;
const matchAnswer = _lock.matchAnswer;
const findFirst = _lock.findFirst;

/// Starts a pattern search and finds the first object the pattern names.
///
/// SYNOPSIS:
/// ```zig
/// fn MatchFirst(db: *DosBase, pattern: [*:0]const u8, anchor: *dos.AnchorPath) i32
/// ```
///
/// SINCE: 1.0. LVO -336.
///
/// INPUTS:
/// - `pattern` - the pattern, in utility.library's syntax after a literal
///   device part ("RAM:d/#?.txt").
/// - `anchor` - the search's state: ap_BreakBits, ap_Flags and ap_Strlen
///   set by the caller, the rest cleared. When ap_Strlen isn't 0, that many
///   bytes follow the AnchorPath for the full path.
///
/// RESULT:
/// 0 when an object was found: its FileInfoBlock is in ap_Info, and its
/// full path in the buffer when ap_Strlen isn't 0. Otherwise an error, also
/// in IoErr: ERROR_NO_MORE_ENTRIES when nothing matches,
/// ERROR_BUFFER_OVERFLOW when the path was cut to fit (the search goes on),
/// ERROR_BAD_TEMPLATE for a pattern that doesn't parse, ERROR_BREAK when
/// one of ap_BreakBits came, or a handler's error.
///
/// BEHAVIOR:
/// The pattern becomes a chain of levels on the anchor, and the first one
/// is looked for as MatchNext looks. APF_ITSWILD is set when the pattern
/// has a wildcard. "*" and the name of a handler that isn't a file system
/// (NIL:, CON:) give one entry, the name itself. An error other than
/// ERROR_BUFFER_OVERFLOW frees the chain.
///
/// CONTEXT:
/// - Waits: yes, for the handlers' answers.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: a Task will do for a pattern with a device; without one the
///   search starts in the current directory, which only a process has.
///
/// OWNERSHIP:
/// The anchor holds locks and memory until MatchEnd, which the caller calls
/// whatever MatchFirst answered.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MatchNext`, `MatchEnd`, `ParsePattern`
///
/// EXAMPLES:
/// ```zig
/// var anchor: dos.AnchorPath = .{};
/// var rc = dos_lib.MatchFirst("RAM:#?.txt", &anchor);
/// while (rc == 0) : (rc = dos_lib.MatchNext(&anchor)) show(&anchor.info);
/// dos_lib.MatchEnd(&anchor);
/// ```
pub fn MatchFirst(db: *DosBase, pattern: [*:0]const u8, anchor: *dos.AnchorPath) i32 {
    anchor.base = null;
    anchor.last = null;
    anchor.flags &= ~(dos.APF_NOMEMERR | dos.APF_ITSWILD);
    if (db.utility_base.Strcmp(pattern, "*") != 0) {
        if (db.utility_base.Strchr(pattern, ':') == null) return findFirst(db, anchor, pattern);
        var code: i32 = 0;
        const is_fs = _lock.fileSystemOf(db, pattern, &code) orelse return matchAnswer(db, code);
        if (is_fs) return findFirst(db, anchor, pattern);
    }
    return single(db, anchor, pattern[0..db.utility_base.Strlen(pattern)]);
}
