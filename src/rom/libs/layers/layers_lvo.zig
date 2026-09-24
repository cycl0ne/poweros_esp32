// SPDX-License-Identifier: MPL-2.0
//! layers.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures at compile time, the slots and the
//! forwarding in the tests at the end.
//!
//! Each wrapper is the slot a caller reaches through the table. It hands
//! the work to the call - a file of its own in the folder for its
//! category - with the library's base first.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const layers = sdk.layers;
const utility = sdk.utility;
const TagItem = sdk.utility.TagItem;
const vec = exec.vec;
const layers_base = @import("layers_base.zig");
const LayersBase = layers_base.LayersBase;

const NewLayerInfo = @import("layerinfo/newlayerinfo.zig").NewLayerInfo;
const DisposeLayerInfo = @import("layerinfo/disposelayerinfo.zig").DisposeLayerInfo;
const CreateLayerTagList = @import("layer/createlayertaglist.zig").CreateLayerTagList;
const DeleteLayer = @import("layer/deletelayer.zig").DeleteLayer;
const UpfrontLayer = @import("layer/upfrontlayer.zig").UpfrontLayer;
const BehindLayer = @import("layer/behindlayer.zig").BehindLayer;
const MoveLayerInFrontOf = @import("layer/movelayerinfrontof.zig").MoveLayerInFrontOf;
const WhichLayer = @import("layer/whichlayer.zig").WhichLayer;
const GetLayerAttrs = @import("layer/getlayerattrs.zig").GetLayerAttrs;
const InstallClipRegion = @import("damage/installclipregion.zig").InstallClipRegion;
const BeginUpdate = @import("damage/beginupdate.zig").BeginUpdate;
const EndUpdate = @import("damage/endupdate.zig").EndUpdate;
const LockLayer = @import("locks/locklayer.zig").LockLayer;
const UnlockLayer = @import("locks/unlocklayer.zig").UnlockLayer;
const LockLayers = @import("locks/locklayers.zig").LockLayers;
const UnlockLayers = @import("locks/unlocklayers.zig").UnlockLayers;
const LockLayerInfo = @import("locks/locklayerinfo.zig").LockLayerInfo;
const UnlockLayerInfo = @import("locks/unlocklayerinfo.zig").UnlockLayerInfo;
const MoveLayer = @import("move/movelayer.zig").MoveLayer;
const SizeLayer = @import("move/sizelayer.zig").SizeLayer;
const MoveSizeLayer = @import("move/movesizelayer.zig").MoveSizeLayer;
const ScrollLayer = @import("super/scrolllayer.zig").ScrollLayer;
const InstallLayerHook = @import("backfill/installlayerhook.zig").InstallLayerHook;
const DoHookClipRects = @import("backfill/dohookcliprects.zig").DoHookClipRects;
const LayersErrorText = @import("errors/layerserrortext.zig").LayersErrorText;

/// Its functions, as the SDK has them (sdk/fd/layers_lib.fd).
const interface = sdk.interface.layers;

/// Each function's offset in the jump table.
const LVO = interface.LVO;

// Every function in LVO is an lvo* function here, with the SDK's
// signature, in its slot.
comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("layers.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(50_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "layers.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`: every
/// call of the table.
const contract_files = [_][]const u8{
    @embedFile("layerinfo/newlayerinfo.zig"),
    @embedFile("layerinfo/disposelayerinfo.zig"),
    @embedFile("layer/createlayertaglist.zig"),
    @embedFile("layer/deletelayer.zig"),
    @embedFile("layer/upfrontlayer.zig"),
    @embedFile("layer/behindlayer.zig"),
    @embedFile("layer/movelayerinfrontof.zig"),
    @embedFile("layer/whichlayer.zig"),
    @embedFile("layer/getlayerattrs.zig"),
    @embedFile("damage/installclipregion.zig"),
    @embedFile("damage/beginupdate.zig"),
    @embedFile("damage/endupdate.zig"),
    @embedFile("locks/locklayer.zig"),
    @embedFile("locks/unlocklayer.zig"),
    @embedFile("locks/locklayers.zig"),
    @embedFile("locks/unlocklayers.zig"),
    @embedFile("locks/locklayerinfo.zig"),
    @embedFile("locks/unlocklayerinfo.zig"),
    @embedFile("move/movelayer.zig"),
    @embedFile("move/sizelayer.zig"),
    @embedFile("move/movesizelayer.zig"),
    @embedFile("super/scrolllayer.zig"),
    @embedFile("backfill/installlayerhook.zig"),
    @embedFile("backfill/dohookcliprects.zig"),
    @embedFile("errors/layerserrortext.zig"),
};

fn lvoNewLayerInfo(lb: *LayersBase, rp: *graphics.RastPort) callconv(.c) ?*layers.LayerInfo {
    return @ptrCast(NewLayerInfo(lb, rp));
}
fn lvoDisposeLayerInfo(lb: *LayersBase, info: ?*layers.LayerInfo) callconv(.c) void {
    DisposeLayerInfo(lb, @ptrCast(@alignCast(info)));
}
fn lvoCreateLayerTagList(lb: *LayersBase, info: *layers.LayerInfo, tags: ?[*]const TagItem) callconv(.c) ?*layers.Layer {
    return @ptrCast(CreateLayerTagList(lb, @ptrCast(@alignCast(info)), tags));
}
fn lvoDeleteLayer(lb: *LayersBase, layer: ?*layers.Layer) callconv(.c) void {
    DeleteLayer(lb, @ptrCast(@alignCast(layer)));
}
fn lvoUpfrontLayer(lb: *LayersBase, layer: *layers.Layer) callconv(.c) bool {
    return UpfrontLayer(lb, @ptrCast(@alignCast(layer)));
}
fn lvoBehindLayer(lb: *LayersBase, layer: *layers.Layer) callconv(.c) bool {
    return BehindLayer(lb, @ptrCast(@alignCast(layer)));
}
fn lvoMoveLayerInFrontOf(lb: *LayersBase, layer: *layers.Layer, other: *layers.Layer) callconv(.c) bool {
    return MoveLayerInFrontOf(lb, @ptrCast(@alignCast(layer)), @ptrCast(@alignCast(other)));
}
fn lvoWhichLayer(lb: *LayersBase, info: *layers.LayerInfo, x: i32, y: i32) callconv(.c) ?*layers.Layer {
    return @ptrCast(WhichLayer(lb, @ptrCast(@alignCast(info)), x, y));
}
fn lvoGetLayerAttrs(lb: *LayersBase, layer: *layers.Layer, tags: ?[*]const TagItem) callconv(.c) void {
    GetLayerAttrs(lb, @ptrCast(@alignCast(layer)), tags);
}
fn lvoInstallClipRegion(lb: *LayersBase, layer: *layers.Layer, region: ?*graphics.Region) callconv(.c) ?*graphics.Region {
    return InstallClipRegion(lb, @ptrCast(@alignCast(layer)), region);
}
fn lvoBeginUpdate(lb: *LayersBase, layer: *layers.Layer) callconv(.c) bool {
    return BeginUpdate(lb, @ptrCast(@alignCast(layer)));
}
fn lvoEndUpdate(lb: *LayersBase, layer: *layers.Layer, done: bool) callconv(.c) void {
    EndUpdate(lb, @ptrCast(@alignCast(layer)), done);
}
fn lvoLockLayer(lb: *LayersBase, layer: *layers.Layer) callconv(.c) void {
    LockLayer(lb, @ptrCast(@alignCast(layer)));
}
fn lvoUnlockLayer(lb: *LayersBase, layer: *layers.Layer) callconv(.c) void {
    UnlockLayer(lb, @ptrCast(@alignCast(layer)));
}
fn lvoLockLayers(lb: *LayersBase, info: *layers.LayerInfo) callconv(.c) void {
    LockLayers(lb, @ptrCast(@alignCast(info)));
}
fn lvoUnlockLayers(lb: *LayersBase, info: *layers.LayerInfo) callconv(.c) void {
    UnlockLayers(lb, @ptrCast(@alignCast(info)));
}
fn lvoLockLayerInfo(lb: *LayersBase, info: *layers.LayerInfo) callconv(.c) void {
    LockLayerInfo(lb, @ptrCast(@alignCast(info)));
}
fn lvoUnlockLayerInfo(lb: *LayersBase, info: *layers.LayerInfo) callconv(.c) void {
    UnlockLayerInfo(lb, @ptrCast(@alignCast(info)));
}
fn lvoMoveLayer(lb: *LayersBase, layer: *layers.Layer, dx: i32, dy: i32) callconv(.c) bool {
    return MoveLayer(lb, @ptrCast(@alignCast(layer)), dx, dy);
}
fn lvoSizeLayer(lb: *LayersBase, layer: *layers.Layer, dw: i32, dh: i32) callconv(.c) bool {
    return SizeLayer(lb, @ptrCast(@alignCast(layer)), dw, dh);
}
fn lvoMoveSizeLayer(lb: *LayersBase, layer: *layers.Layer, dx: i32, dy: i32, dw: i32, dh: i32) callconv(.c) bool {
    return MoveSizeLayer(lb, @ptrCast(@alignCast(layer)), dx, dy, dw, dh);
}
fn lvoScrollLayer(lb: *LayersBase, layer: *layers.Layer, dx: i32, dy: i32) callconv(.c) bool {
    return ScrollLayer(lb, @ptrCast(@alignCast(layer)), dx, dy);
}
fn lvoInstallLayerHook(lb: *LayersBase, layer: *layers.Layer, hook: usize) callconv(.c) usize {
    return InstallLayerHook(lb, @ptrCast(@alignCast(layer)), hook);
}
fn lvoDoHookClipRects(lb: *LayersBase, hook: *utility.Hook, rp: *graphics.RastPort, area: *const graphics.Rect) callconv(.c) void {
    DoHookClipRects(lb, hook, rp, area);
}
fn lvoLayersErrorText(lb: *LayersBase, code: i32) callconv(.c) [*:0]const u8 {
    return LayersErrorText(lb, code);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(layers_base.expunge),
    vec(exec.libExtFunc),
    vec(lvoNewLayerInfo),
    vec(lvoDisposeLayerInfo),
    vec(lvoCreateLayerTagList),
    vec(lvoDeleteLayer),
    vec(lvoUpfrontLayer),
    vec(lvoBehindLayer),
    vec(lvoMoveLayerInFrontOf),
    vec(lvoWhichLayer),
    vec(lvoGetLayerAttrs),
    vec(lvoInstallClipRegion),
    vec(lvoBeginUpdate),
    vec(lvoEndUpdate),
    vec(lvoLockLayer),
    vec(lvoUnlockLayer),
    vec(lvoLockLayers),
    vec(lvoUnlockLayers),
    vec(lvoLockLayerInfo),
    vec(lvoUnlockLayerInfo),
    vec(lvoMoveLayer),
    vec(lvoSizeLayer),
    vec(lvoMoveSizeLayer),
    vec(lvoScrollLayer),
    vec(lvoInstallLayerHook),
    vec(lvoDoHookClipRects),
    vec(lvoLayersErrorText),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 29), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("layers_lvo.zig"), LVO, &.{});
}
