// SPDX-License-Identifier: MIT
//! iffparse.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const vec = exec.vec;
const IFFParseBase = @import("iffparse_base.zig").IFFParseBase;
const iffparse_init = @import("iffparse_init.zig");

const AllocIFF = @import("handle/allociff.zig").AllocIFF;
const FreeIFF = @import("handle/freeiff.zig").FreeIFF;
const InitIFF = @import("handle/initiff.zig").InitIFF;
const InitIFFasDOS = @import("handle/initiffasdos.zig").InitIFFasDOS;
const InitIFFasClip = @import("handle/initiffasclip.zig").InitIFFasClip;
const OpenIFF = @import("handle/openiff.zig").OpenIFF;
const CloseIFF = @import("handle/closeiff.zig").CloseIFF;
const ParseIFF = @import("parse/parseiff.zig").ParseIFF;
const ReadChunkBytes = @import("chunk/readchunkbytes.zig").ReadChunkBytes;
const ReadChunkRecords = @import("chunk/readchunkrecords.zig").ReadChunkRecords;
const WriteChunkBytes = @import("chunk/writechunkbytes.zig").WriteChunkBytes;
const WriteChunkRecords = @import("chunk/writechunkrecords.zig").WriteChunkRecords;
const PushChunk = @import("chunk/pushchunk.zig").PushChunk;
const PopChunk = @import("chunk/popchunk.zig").PopChunk;
const EntryHandler = @import("handler/entryhandler.zig").EntryHandler;
const ExitHandler = @import("handler/exithandler.zig").ExitHandler;
const PropChunk = @import("handler/propchunk.zig").PropChunk;
const PropChunks = @import("handler/propchunks.zig").PropChunks;
const StopChunk = @import("handler/stopchunk.zig").StopChunk;
const StopChunks = @import("handler/stopchunks.zig").StopChunks;
const CollectionChunk = @import("handler/collectionchunk.zig").CollectionChunk;
const CollectionChunks = @import("handler/collectionchunks.zig").CollectionChunks;
const StopOnExit = @import("handler/stoponexit.zig").StopOnExit;
const FindProp = @import("context/findprop.zig").FindProp;
const FindCollection = @import("context/findcollection.zig").FindCollection;
const FindPropContext = @import("context/findpropcontext.zig").FindPropContext;
const CurrentChunk = @import("context/currentchunk.zig").CurrentChunk;
const ParentChunk = @import("context/parentchunk.zig").ParentChunk;
const AllocLocalItem = @import("item/alloclocalitem.zig").AllocLocalItem;
const FreeLocalItem = @import("item/freelocalitem.zig").FreeLocalItem;
const LocalItemData = @import("item/localitemdata.zig").LocalItemData;
const SetLocalItemPurge = @import("item/setlocalitempurge.zig").SetLocalItemPurge;
const FindLocalItem = @import("item/findlocalitem.zig").FindLocalItem;
const StoreLocalItem = @import("item/storelocalitem.zig").StoreLocalItem;
const StoreItemInContext = @import("item/storeitemincontext.zig").StoreItemInContext;
const OpenClipboard = @import("clip/openclipboard.zig").OpenClipboard;
const CloseClipboard = @import("clip/closeclipboard.zig").CloseClipboard;
const GoodID = @import("id/goodid.zig").GoodID;
const GoodType = @import("id/goodtype.zig").GoodType;
const IDtoStr = @import("id/idtostr.zig").IDtoStr;

/// iffparse.library's interface, as the SDK generates it from
/// sdk/fd/iffparse_lib.fd.
const interface = sdk.interface.iffparse;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("iffparse.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(100_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "iffparse.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("handle/allociff.zig"),
    @embedFile("handle/freeiff.zig"),
    @embedFile("handle/initiff.zig"),
    @embedFile("handle/initiffasdos.zig"),
    @embedFile("handle/initiffasclip.zig"),
    @embedFile("handle/openiff.zig"),
    @embedFile("handle/closeiff.zig"),
    @embedFile("parse/parseiff.zig"),
    @embedFile("chunk/readchunkbytes.zig"),
    @embedFile("chunk/readchunkrecords.zig"),
    @embedFile("chunk/writechunkbytes.zig"),
    @embedFile("chunk/writechunkrecords.zig"),
    @embedFile("chunk/pushchunk.zig"),
    @embedFile("chunk/popchunk.zig"),
    @embedFile("handler/entryhandler.zig"),
    @embedFile("handler/exithandler.zig"),
    @embedFile("handler/propchunk.zig"),
    @embedFile("handler/propchunks.zig"),
    @embedFile("handler/stopchunk.zig"),
    @embedFile("handler/stopchunks.zig"),
    @embedFile("handler/collectionchunk.zig"),
    @embedFile("handler/collectionchunks.zig"),
    @embedFile("handler/stoponexit.zig"),
    @embedFile("context/findprop.zig"),
    @embedFile("context/findcollection.zig"),
    @embedFile("context/findpropcontext.zig"),
    @embedFile("context/currentchunk.zig"),
    @embedFile("context/parentchunk.zig"),
    @embedFile("item/alloclocalitem.zig"),
    @embedFile("item/freelocalitem.zig"),
    @embedFile("item/localitemdata.zig"),
    @embedFile("item/setlocalitempurge.zig"),
    @embedFile("item/findlocalitem.zig"),
    @embedFile("item/storelocalitem.zig"),
    @embedFile("item/storeitemincontext.zig"),
    @embedFile("clip/openclipboard.zig"),
    @embedFile("clip/closeclipboard.zig"),
    @embedFile("id/goodid.zig"),
    @embedFile("id/goodtype.zig"),
    @embedFile("id/idtostr.zig"),
};

// --- the handle -------------------------------------------------------------

fn lvoAllocIFF(ib: *IFFParseBase) callconv(.c) ?*iffparse.IFFHandle {
    return AllocIFF(ib);
}
fn lvoFreeIFF(ib: *IFFParseBase, iff: ?*iffparse.IFFHandle) callconv(.c) void {
    return FreeIFF(ib, iff);
}
fn lvoInitIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle, flags: u32, hook: *utility.Hook) callconv(.c) void {
    return InitIFF(ib, iff, flags, hook);
}
fn lvoInitIFFasDOS(ib: *IFFParseBase, iff: *iffparse.IFFHandle) callconv(.c) void {
    return InitIFFasDOS(ib, iff);
}
fn lvoInitIFFasClip(ib: *IFFParseBase, iff: *iffparse.IFFHandle) callconv(.c) void {
    return InitIFFasClip(ib, iff);
}
fn lvoOpenIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle, rw_mode: i32) callconv(.c) i32 {
    return OpenIFF(ib, iff, rw_mode);
}
fn lvoCloseIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle) callconv(.c) void {
    return CloseIFF(ib, iff);
}
fn lvoParseIFF(ib: *IFFParseBase, iff: *iffparse.IFFHandle, control: i32) callconv(.c) i32 {
    return ParseIFF(ib, iff, control);
}
fn lvoReadChunkBytes(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *anyopaque, bytes: i32) callconv(.c) i32 {
    return ReadChunkBytes(ib, iff, buf, bytes);
}
fn lvoReadChunkRecords(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *anyopaque, record_size: i32, records: i32) callconv(.c) i32 {
    return ReadChunkRecords(ib, iff, buf, record_size, records);
}
fn lvoWriteChunkBytes(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *const anyopaque, bytes: i32) callconv(.c) i32 {
    return WriteChunkBytes(ib, iff, buf, bytes);
}
fn lvoWriteChunkRecords(ib: *IFFParseBase, iff: *iffparse.IFFHandle, buf: *const anyopaque, record_size: i32, records: i32) callconv(.c) i32 {
    return WriteChunkRecords(ib, iff, buf, record_size, records);
}
fn lvoPushChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, size: i32) callconv(.c) i32 {
    return PushChunk(ib, iff, form_type, id, size);
}
fn lvoPopChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle) callconv(.c) i32 {
    return PopChunk(ib, iff);
}
fn lvoEntryHandler(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, position: i32, hook: *utility.Hook, object: ?*anyopaque) callconv(.c) i32 {
    return EntryHandler(ib, iff, form_type, id, position, hook, object);
}
fn lvoExitHandler(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, position: i32, hook: *utility.Hook, object: ?*anyopaque) callconv(.c) i32 {
    return ExitHandler(ib, iff, form_type, id, position, hook, object);
}
fn lvoPropChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) callconv(.c) i32 {
    return PropChunk(ib, iff, form_type, id);
}
fn lvoPropChunks(ib: *IFFParseBase, iff: *iffparse.IFFHandle, list: [*]const u32, pairs: i32) callconv(.c) i32 {
    return PropChunks(ib, iff, list, pairs);
}
fn lvoStopChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) callconv(.c) i32 {
    return StopChunk(ib, iff, form_type, id);
}
fn lvoStopChunks(ib: *IFFParseBase, iff: *iffparse.IFFHandle, list: [*]const u32, pairs: i32) callconv(.c) i32 {
    return StopChunks(ib, iff, list, pairs);
}
fn lvoCollectionChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) callconv(.c) i32 {
    return CollectionChunk(ib, iff, form_type, id);
}
fn lvoCollectionChunks(ib: *IFFParseBase, iff: *iffparse.IFFHandle, list: [*]const u32, pairs: i32) callconv(.c) i32 {
    return CollectionChunks(ib, iff, list, pairs);
}
fn lvoStopOnExit(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) callconv(.c) i32 {
    return StopOnExit(ib, iff, form_type, id);
}
fn lvoFindProp(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) callconv(.c) ?*iffparse.StoredProperty {
    return FindProp(ib, iff, form_type, id);
}
fn lvoFindCollection(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32) callconv(.c) ?*iffparse.CollectionItem {
    return FindCollection(ib, iff, form_type, id);
}
fn lvoFindPropContext(ib: *IFFParseBase, iff: *iffparse.IFFHandle) callconv(.c) ?*iffparse.ContextNode {
    return FindPropContext(ib, iff);
}
fn lvoCurrentChunk(ib: *IFFParseBase, iff: *iffparse.IFFHandle) callconv(.c) ?*iffparse.ContextNode {
    return CurrentChunk(ib, iff);
}
fn lvoParentChunk(ib: *IFFParseBase, context: *iffparse.ContextNode) callconv(.c) ?*iffparse.ContextNode {
    return ParentChunk(ib, context);
}
fn lvoAllocLocalItem(ib: *IFFParseBase, form_type: u32, id: u32, ident: u32, data_size: i32) callconv(.c) ?*iffparse.LocalContextItem {
    return AllocLocalItem(ib, form_type, id, ident, data_size);
}
fn lvoFreeLocalItem(ib: *IFFParseBase, item: ?*iffparse.LocalContextItem) callconv(.c) void {
    return FreeLocalItem(ib, item);
}
fn lvoLocalItemData(ib: *IFFParseBase, item: ?*iffparse.LocalContextItem) callconv(.c) ?*anyopaque {
    return LocalItemData(ib, item);
}
fn lvoSetLocalItemPurge(ib: *IFFParseBase, item: *iffparse.LocalContextItem, hook: *utility.Hook) callconv(.c) void {
    return SetLocalItemPurge(ib, item, hook);
}
fn lvoFindLocalItem(ib: *IFFParseBase, iff: *iffparse.IFFHandle, form_type: u32, id: u32, ident: u32) callconv(.c) ?*iffparse.LocalContextItem {
    return FindLocalItem(ib, iff, form_type, id, ident);
}
fn lvoStoreLocalItem(ib: *IFFParseBase, iff: *iffparse.IFFHandle, item: *iffparse.LocalContextItem, position: i32) callconv(.c) i32 {
    return StoreLocalItem(ib, iff, item, position);
}
fn lvoStoreItemInContext(ib: *IFFParseBase, iff: *iffparse.IFFHandle, item: *iffparse.LocalContextItem, context: *iffparse.ContextNode) callconv(.c) void {
    return StoreItemInContext(ib, iff, item, context);
}
fn lvoOpenClipboard(ib: *IFFParseBase, unit: u32) callconv(.c) ?*iffparse.ClipboardHandle {
    return OpenClipboard(ib, unit);
}
fn lvoCloseClipboard(ib: *IFFParseBase, clip: ?*iffparse.ClipboardHandle) callconv(.c) void {
    return CloseClipboard(ib, clip);
}
fn lvoGoodID(ib: *IFFParseBase, id: u32) callconv(.c) bool {
    return GoodID(ib, id);
}
fn lvoGoodType(ib: *IFFParseBase, form_type: u32) callconv(.c) bool {
    return GoodType(ib, form_type);
}
fn lvoIDtoStr(ib: *IFFParseBase, id: u32, buf: *[5]u8) callconv(.c) [*:0]u8 {
    return IDtoStr(ib, id, buf);
}

pub const vectors = [_]*const anyopaque{
    vec(iffparse_init.openVector),
    vec(iffparse_init.closeVector),
    vec(iffparse_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoAllocIFF),
    vec(lvoFreeIFF),
    vec(lvoInitIFF),
    vec(lvoInitIFFasDOS),
    vec(lvoInitIFFasClip),
    vec(lvoOpenIFF),
    vec(lvoCloseIFF),
    vec(lvoParseIFF),
    vec(lvoReadChunkBytes),
    vec(lvoReadChunkRecords),
    vec(lvoWriteChunkBytes),
    vec(lvoWriteChunkRecords),
    vec(lvoPushChunk),
    vec(lvoPopChunk),
    vec(lvoEntryHandler),
    vec(lvoExitHandler),
    vec(lvoPropChunk),
    vec(lvoPropChunks),
    vec(lvoStopChunk),
    vec(lvoStopChunks),
    vec(lvoCollectionChunk),
    vec(lvoCollectionChunks),
    vec(lvoStopOnExit),
    vec(lvoFindProp),
    vec(lvoFindCollection),
    vec(lvoFindPropContext),
    vec(lvoCurrentChunk),
    vec(lvoParentChunk),
    vec(lvoAllocLocalItem),
    vec(lvoFreeLocalItem),
    vec(lvoLocalItemData),
    vec(lvoSetLocalItemPurge),
    vec(lvoFindLocalItem),
    vec(lvoStoreLocalItem),
    vec(lvoStoreItemInContext),
    vec(lvoOpenClipboard),
    vec(lvoCloseClipboard),
    vec(lvoGoodID),
    vec(lvoGoodType),
    vec(lvoIDtoStr),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("iffparse_lvo.zig"), LVO, &.{});
}
