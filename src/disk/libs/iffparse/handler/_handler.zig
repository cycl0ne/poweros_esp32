// SPDX-License-Identifier: MIT
//! The handlers: what the walk does when it enters or leaves a chunk.
//!
//! A handler is a local item like any other - `IFFLCI_ENTRYHANDLER` or
//! `IFFLCI_EXITHANDLER` - whose data is a `ChunkHandler`: a hook and the
//! object to call it with. `ParseIFF` looks one up by the chunk's type
//! and id every time it enters or leaves a chunk, so a handler set on a
//! chunk lasts as long as the chunk it was stored with.
//!
//! Four of them are the library's own, and are what `PropChunk`,
//! `StopChunk`, `CollectionChunk` and `StopOnExit` install. They have no
//! hook of a caller's to point at, so each keeps its own inside its
//! item's data.
//!
//! **A stop is a handler that answers.** `IFF_RETURN2CLIENT` from a
//! handler makes `ParseIFF` answer 0 and leave the walk where it is,
//! which is what stopping at a chunk means; `IFFERR_EOC` from an exit
//! handler is what stopping at the end of one means.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const _handle = @import("../handle/_handle.zig");
const _item = @import("../item/_item.zig");
const IFFParseBase = _base.IFFParseBase;
const Handle = _base.Handle;
const AllocLocalItem = @import("../item/alloclocalitem.zig").AllocLocalItem;
const FreeLocalItem = @import("../item/freelocalitem.zig").FreeLocalItem;
const StoreLocalItem = @import("../item/storelocalitem.zig").StoreLocalItem;
const ReadChunkBytes = @import("../chunk/readchunkbytes.zig").ReadChunkBytes;

/// A handler stored with a chunk: `hook` when the caller gave one, else
/// `entry`, which is one of this file's own.
pub fn installHandler(
    ib: *IFFParseBase,
    iff: *iffparse.IFFHandle,
    form_type: u32,
    id: u32,
    ident: u32,
    position: i32,
    hook: ?*utility.Hook,
    entry: ?utility.hooks.HookFn,
    object: ?*anyopaque,
) i32 {
    const item = AllocLocalItem(ib, form_type, id, ident, @sizeOf(_base.ChunkHandler)) orelse return iffparse.IFFERR_NOMEM;
    const handler: *_base.ChunkHandler = @ptrCast(@alignCast(_item.dataOf(_base.itemOf(item))));
    handler.object = object;
    if (hook) |given| {
        handler.hook = given;
    } else {
        handler.own = .{ .entry = entry.? };
        handler.hook = &handler.own;
    }
    const failed = StoreLocalItem(ib, iff, item, position);
    if (failed != 0) {
        FreeLocalItem(ib, item);
        return failed;
    }
    return 0;
}

/// A handler of the library's own set on the chunk the walk is in.
pub fn installOwn(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, ident: u32, entry: utility.hooks.HookFn) i32 {
    return installHandler(ib, iff, form_type, id, ident, iffparse.IFFSLI_TOP, null, entry, iff);
}

/// The same call for each of `pairs` type-and-id pairs, stopping at the
/// first that fails.
pub fn eachPair(ib: *IFFParseBase, iff: *iffparse.IFFHandle, list: [*]const u32, pairs: i32, one: *const fn (*IFFParseBase, *iffparse.IFFHandle, u32, u32) i32) i32 {
    var i: usize = 0;
    while (i < @as(usize, @intCast(@max(pairs, 0)))) : (i += 1) {
        const failed = one(ib, iff, list[i * 2], list[i * 2 + 1]);
        if (failed != 0) return failed;
    }
    return 0;
}

/// The chunk the walk is in read whole into `into`.
fn bufferChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, size: i32, into: *anyopaque) i32 {
    const got = ReadChunkBytes(ib, iff, into, size);
    if (got == size) return 0;
    return if (got > 0) iffparse.IFFERR_READ else got;
}

// --- the library's own handlers ---------------------------------------------

/// `StopChunk`: the walk stops here and the program is answered.
pub fn stopHere(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    _ = object;
    _ = message;
    return @bitCast(@as(isize, iffparse.IFF_RETURN2CLIENT));
}

/// `StopOnExit`: the walk stops at the end of the chunk.
pub fn stopOnLeaving(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    _ = object;
    _ = message;
    return @bitCast(@as(isize, iffparse.IFFERR_EOC));
}

/// `PropChunk`: the chunk's contents kept with the FORM or LIST it is
/// in, to be found again with `FindProp`.
pub fn keepProperty(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    _ = message;
    const iff: *iffparse.IFFHandle = @ptrCast(@alignCast(object orelse return 1));
    const h = _base.handleOf(iff);
    const ib = h.base;
    const top = _handle.currentChunk(h) orelse return @bitCast(@as(isize, iffparse.IFFERR_EOF));
    const size = top.public.size;
    const item = AllocLocalItem(ib, top.public.type, top.public.id, iffparse.IFFLCI_PROP, size + @sizeOf(iffparse.StoredProperty)) orelse {
        return @bitCast(@as(isize, iffparse.IFFERR_NOMEM));
    };
    const stored: *iffparse.StoredProperty = @ptrCast(@alignCast(_item.dataOf(_base.itemOf(item))));
    const bytes: [*]u8 = @ptrFromInt(@intFromPtr(stored) + @sizeOf(iffparse.StoredProperty));
    const failed = bufferChunk(ib, iff, size, bytes);
    if (failed != 0) {
        FreeLocalItem(ib, item);
        return @bitCast(@as(isize, failed));
    }
    stored.size = size;
    stored.data = bytes;
    const stowed = StoreLocalItem(ib, iff, item, iffparse.IFFSLI_PROP);
    if (stowed != 0) {
        FreeLocalItem(ib, item);
        return @bitCast(@as(isize, stowed));
    }
    return 0;
}

/// `CollectionChunk`: every such chunk kept, newest first, the ones this
/// context gathered in front of the ones a context further out did.
pub fn keepCollected(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    _ = message;
    const iff: *iffparse.IFFHandle = @ptrCast(@alignCast(object orelse return 1));
    const h = _base.handleOf(iff);
    const ib = h.base;
    const sys = ib.sys_base;
    const top = _handle.currentChunk(h) orelse return @bitCast(@as(isize, iffparse.IFFERR_EOF));
    const size = top.public.size;

    const memory = sys.AllocVec(@sizeOf(iffparse.CollectionItem) + @as(usize, @intCast(@max(size, 0))), exec.MEMF_ANY) orelse {
        return @bitCast(@as(isize, iffparse.IFFERR_NOMEM));
    };
    const gathered: *iffparse.CollectionItem = @ptrCast(@alignCast(memory));
    const bytes: [*]u8 = @ptrFromInt(@intFromPtr(gathered) + @sizeOf(iffparse.CollectionItem));
    gathered.* = .{ .size = size, .data = bytes };
    const failed = bufferChunk(ib, iff, size, bytes);
    if (failed != 0) {
        sys.FreeVec(memory);
        return @bitCast(@as(isize, failed));
    }

    const context = FindPropContext(ib, iff) orelse {
        sys.FreeVec(memory);
        return @bitCast(@as(isize, iffparse.IFFERR_NOSCOPE));
    };
    // The list this context is already gathering into, if it has one;
    // else a new one, which starts where the list of the context
    // further out left off.
    const found: ?*_base.CollectionList = if (_item.findItem(h, top.public.type, top.public.id, iffparse.IFFLCI_COLLECTION)) |at|
        @ptrCast(@alignCast(_item.dataOf(at)))
    else
        null;
    var list = found;
    if (found == null or found.?.context != context) {
        const item = AllocLocalItem(ib, top.public.type, top.public.id, iffparse.IFFLCI_COLLECTION, @sizeOf(_base.CollectionList)) orelse {
            sys.FreeVec(memory);
            return @bitCast(@as(isize, iffparse.IFFERR_NOMEM));
        };
        const made: *_base.CollectionList = @ptrCast(@alignCast(_item.dataOf(_base.itemOf(item))));
        made.* = .{ .context = context, .base = ib, .last_ptr = if (found) |older| older.first else null };
        made.first = made.last_ptr;
        made.purge = .{ .entry = &purgeCollection };
        SetLocalItemPurge(ib, item, &made.purge);
        const stowed = StoreLocalItem(ib, iff, item, iffparse.IFFSLI_PROP);
        if (stowed != 0) {
            FreeLocalItem(ib, item);
            sys.FreeVec(memory);
            return @bitCast(@as(isize, stowed));
        }
        list = made;
    }
    gathered.next = list.?.first;
    list.?.first = gathered;
    return 0;
}

/// A collection let go of: the chunks this context gathered, and then
/// the item itself.
fn purgeCollection(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    _ = message;
    const item: *iffparse.LocalContextItem = @ptrCast(@alignCast(object orelse return 0));
    const private = _base.itemOf(item);
    const list: *_base.CollectionList = @ptrCast(@alignCast(_item.dataOf(private)));
    const sys = list.base.sys_base;
    var at = list.first;
    while (at) |gathered| {
        if (gathered == list.last_ptr) break;
        const next = gathered.next;
        sys.FreeVec(gathered);
        at = next;
    }
    sys.FreeVec(private);
    return 0;
}

const FindPropContext = @import("../context/findpropcontext.zig").FindPropContext;
const SetLocalItemPurge = @import("../item/setlocalitempurge.zig").SetLocalItemPurge;
