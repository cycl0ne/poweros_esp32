// SPDX-License-Identifier: MIT
//! FindProp: a property chunk that was kept.

const sdk = @import("sdk");
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _item = @import("../item/_item.zig");
const IFFParseBase = _base.IFFParseBase;

/// Answers a property chunk that was kept.
///
/// SYNOPSIS:
/// ```zig
/// fn FindProp(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) ?*iffparse.StoredProperty
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `iff` - an open handle.
/// - `form_type`, `id` - the chunk, as they were given to `PropChunk`.
///
/// RESULT:
/// Its contents - `size` bytes at `data` - or null when no such chunk
/// was kept where the walk now is.
///
/// BEHAVIOR:
/// The nearest one counts: a property kept on the `FORM` the walk is in
/// hides one of the same name kept on the `PROP` of the `LIST` outside
/// it, which is how a list gives its forms defaults they may override.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes are the library's and go when the walk leaves the chunk
/// they were kept on. What is wanted after that is copied out.
///
/// NOTES:
/// The bytes are the chunk's as they lie in the file, so numbers wider
/// than a byte are big-endian and the caller turns them round.
///
/// SEE ALSO:
/// `PropChunk`, `FindCollection`, `FindLocalItem`
///
/// EXAMPLES:
/// ```zig
/// const header = ip.FindProp(iff, ip.MakeID("ILBM"), ip.MakeID("BMHD")) orelse return;
/// const bytes = header.data.?;
/// const width = @as(u16, bytes[0]) << 8 | bytes[1];
/// ```
pub fn FindProp(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) ?*iffparse.StoredProperty {
    _ = ib;
    const data = _item.findItemData(_base.handleOf(iff), form_type, id, iffparse.IFFLCI_PROP) orelse return null;
    return @ptrCast(@alignCast(data));
}
