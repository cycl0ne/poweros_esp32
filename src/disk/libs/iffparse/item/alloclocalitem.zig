// SPDX-License-Identifier: MIT
//! AllocLocalItem: a local item made.

const sdk = @import("sdk");
const exec = sdk.exec;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;

/// Makes a local item with room for its own bytes.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocLocalItem(ib: *IFFParseBase, form_type: u32, id: u32, ident: u32, data_size: i32) ?*iffparse.LocalContextItem
/// ```
///
/// SINCE: 1.0. LVO -132.
///
/// INPUTS:
/// - `form_type`, `id` - the chunk the item is about.
/// - `ident` - what kind of item it is. The library's own are
///   `IFFLCI_PROP`, `IFFLCI_COLLECTION`, `IFFLCI_ENTRYHANDLER` and
///   `IFFLCI_EXITHANDLER`; a program uses any other four characters.
/// - `data_size` - bytes of its own, which `LocalItemData` answers with.
///
/// RESULT:
/// The item, or null for no memory.
///
/// BEHAVIOR:
/// The item is not stored anywhere yet: `StoreLocalItem` puts it with a
/// chunk, and until then it is the caller's to free.
///
/// Its bytes come back cleared.
///
/// CONTEXT:
/// - Waits: for memory.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until it is stored, and the library's after: a stored
/// item goes when the walk leaves the chunk it was stored with.
///
/// NOTES:
/// This is how a program keeps something of its own alongside a chunk -
/// what it has read so far of a form, say - without a list of its own to
/// walk and clean up.
///
/// SEE ALSO:
/// `StoreLocalItem`, `FreeLocalItem`, `LocalItemData`, `FindLocalItem`
///
/// EXAMPLES:
/// ```zig
/// const item = ip.AllocLocalItem(ip.MakeID("ILBM"), ip.MakeID("BMHD"), MY_IDENT, @sizeOf(MyState)) orelse return;
/// const mine: *MyState = @ptrCast(@alignCast(ip.LocalItemData(item).?));
/// ```
pub fn AllocLocalItem(ib: *IFFParseBase, form_type: u32, id: u32, ident: u32, data_size: i32) ?*iffparse.LocalContextItem {
    const bytes: usize = @intCast(@max(data_size, 0));
    const memory = ib.sys_base.AllocVec(@sizeOf(_base.Item) + bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const item: *_base.Item = @ptrCast(@alignCast(memory));
    item.* = .{};
    item.public.type = form_type;
    item.public.id = id;
    item.public.ident = ident;
    return &item.public;
}
