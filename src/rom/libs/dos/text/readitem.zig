// SPDX-License-Identifier: MPL-2.0
//! ReadItem: the next word, or quoted string, of a command line.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _text = @import("_text.zig");
const readItem = _text.readItem;
const rd = dos.rdargs;

/// Reads the next item of a command line into a buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadItem(db: *DosBase, buffer: [*]u8, maxchars: i32, csource: ?*dos.CSource) i32
/// ```
///
/// SINCE: 1.0. LVO -464.
///
/// INPUTS:
/// - `buffer` - where the item goes, ended with a NUL.
/// - `maxchars` - the buffer's size, the NUL included.
/// - `csource` - the text to read; null, or one without a buffer, reads
///   Input().
///
/// RESULT:
/// ITEM_UNQUOTED or ITEM_QUOTED with the item in `buffer`; ITEM_NOTHING
/// at the line's end; ITEM_EQUAL for a '=' where an item should start;
/// ITEM_ERROR when the item doesn't fit, a quote isn't closed, or
/// `maxchars` is below 1.
///
/// BEHAVIOR:
/// Blanks before the item are skipped. An unquoted item ends at a blank,
/// a '=' or a ';', which starts a comment. In a quoted one "*E" is an
/// escape, "*N" a newline, and '*' before anything else is that
/// character. The blank after an item is read; the line's end, a ';' or the
/// input's end is put back for the next reader.
///
/// CONTEXT:
/// - Waits: yes, when it reads Input().
/// - Interrupts: no.
/// - Forbid: never under Forbid.
/// - Process: a Process for Input(); a Task will do with a CSource.
///
/// OWNERSHIP:
/// Nothing is allocated. The buffer and the CSource are the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadArgs`, `FindArg`
///
/// EXAMPLES:
/// ```zig
/// var word: [64]u8 = undefined;
/// var cs: dos.CSource = .{ .buffer = line, .length = line_len };
/// while (dos_lib.ReadItem(&word, word.len, &cs) > 0) {
///     // word holds the next item
/// }
/// ```
pub fn ReadItem(db: *DosBase, buffer: [*]u8, maxchars: i32, csource: ?*dos.CSource) i32 {
    if (maxchars < 1) return rd.ITEM_ERROR;
    return readItem(db, null, buffer, maxchars, csource);
}
