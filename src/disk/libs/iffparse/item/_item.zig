// SPDX-License-Identifier: MIT
//! Local items: what is kept with a chunk for as long as the walk is
//! inside it.
//!
//! An item is `Item` - its public head, its purge hook - with its own
//! bytes straight after, which is what `LocalItemData` answers. The
//! library keeps three kinds of its own, named by `ident`: a stored
//! property (`IFFLCI_PROP`), a collection (`IFFLCI_COLLECTION`) and a
//! handler (`IFFLCI_ENTRYHANDLER`, `IFFLCI_EXITHANDLER`). A program may
//! keep items of its own with any other `ident`.
//!
//! An item goes when the chunk it was stored with is left. Going means
//! being freed, unless it was given a purge hook, which is called
//! instead and frees the item itself - which is how a collection frees
//! the chunks it gathered.

const sdk = @import("sdk");
const exec = sdk.exec;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;
const Handle = _base.Handle;
const Item = _base.Item;

/// An item let go of: its purge hook if it has one, else freed.
pub fn purgeItem(ib: *IFFParseBase, item: *Item) i32 {
    const hook = item.purge_hook orelse {
        ib.sys_base.FreeVec(item);
        return 0;
    };
    var command: i32 = iffparse.IFFCMD_PURGELCI;
    return @truncate(@as(isize, @bitCast(ib.utility_base.CallHookPkt(hook, &item.public, &command))));
}

/// Where an item's own bytes start.
pub fn dataOf(item: *Item) *anyopaque {
    return @ptrFromInt(@intFromPtr(item) + @sizeOf(Item));
}

/// The nearest `form_type`.`id`.`ident` item, from the chunk the walk is
/// in outwards.
pub fn findItem(h: *Handle, form_type: u32, id: u32, ident: u32) ?*Item {
    var nodes = _base.Walk.over(&h.stack);
    while (nodes.next()) |node| {
        const cn: *_base.Node = @ptrCast(@alignCast(node));
        var items = _base.Walk.over(&cn.local_items);
        while (items.next()) |at| {
            const item: *Item = @ptrCast(@alignCast(at));
            if (item.public.ident == ident and item.public.id == id and item.public.type == form_type) return item;
        }
    }
    return null;
}

/// The data of the nearest such item, or null when there is none.
pub fn findItemData(h: *Handle, form_type: u32, id: u32, ident: u32) ?*anyopaque {
    return dataOf(findItem(h, form_type, id, ident) orelse return null);
}

/// A node's items all let go of, and the node freed. It must already be
/// off the stack.
pub fn freeContextNode(ib: *IFFParseBase, node: *_base.Node) void {
    const sys = ib.sys_base;
    while (sys.RemHead(@ptrCast(&node.local_items))) |at| {
        _ = purgeItem(ib, @ptrCast(@alignCast(at)));
    }
    sys.FreeVec(node);
}

/// An empty context node, its item list ready. Null for no memory.
pub fn allocContextNode(ib: *IFFParseBase) ?*_base.Node {
    const memory = ib.sys_base.AllocVec(@sizeOf(_base.Node), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const node: *_base.Node = @ptrCast(@alignCast(memory));
    node.* = .{};
    node.local_items.init();
    return node;
}
