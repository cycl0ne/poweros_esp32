// SPDX-License-Identifier: MIT
//! GoodID: whether four characters may name a chunk.

const sdk = @import("sdk");
const _base = @import("../iffparse_base.zig");
const _parse = @import("../parse/_parse.zig");
const IFFParseBase = _base.IFFParseBase;

/// Says whether four characters may name a chunk.
///
/// SYNOPSIS:
/// ```zig
/// fn GoodID(ib: *IFFParseBase, id: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -168.
///
/// INPUTS:
/// - `id` - four characters as a number, the first in the highest byte.
///
/// RESULT:
/// True when every character is printable - space to `~` - and the
/// first is not a space, unless the id is `ID_NULL`, which is four
/// spaces and is allowed.
///
/// BEHAVIOR:
/// The library checks every id it reads and every id it is given to
/// write, so a program rarely needs this call; it is here for one that
/// builds an id from text and wants to know before it tries.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// Leading spaces are refused because an id is read as text: `" CAT"`
/// and `"CAT "` would otherwise both look like a group of forms.
///
/// SEE ALSO:
/// `GoodType`, `IDtoStr`
///
/// EXAMPLES:
/// ```zig
/// if (!ip.GoodID(id)) return error.NotAChunkName;
/// ```
pub fn GoodID(ib: *IFFParseBase, id: u32) bool {
    _ = ib;
    return _parse.goodID(id);
}
