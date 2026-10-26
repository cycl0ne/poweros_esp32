// SPDX-License-Identifier: MPL-2.0
//! layers.library: windows that share one display buffer.
//!
//! A layer is a rectangle of a display that something draws into without
//! having to know what is in front of it. Every layer of one LayerInfo
//! shares the display's buffer - they are not composed out of buffers of
//! their own, which on this machine would mean a read and a write of the
//! same slow memory for every visible pixel - so what makes a layer a
//! layer is where it may write.
//!
//! **This library never draws.** It works out which pieces of each layer
//! are visible and hands the answer to graphics.library as a `ClipTarget`
//! list on the layer's RastPort. graphics.library walks that list and
//! knows nothing about windows; this library knows nothing about pixels.
//! The one structure they share is the target list itself, which is the
//! same arrangement rtg.library and graphics.library already have.
//!
//! A layer draws in **its own coordinates**: `(0,0)` is its top-left
//! wherever it happens to be, because the offset on to the display rides
//! in the targets rather than in anything the caller has to add.
//!
//! Each call is a file of its own in the folder for its category -
//! layerinfo/, layer/, locks/, damage/, move/, super/, backfill/ and
//! errors/ - and tile/ and smart/ hold the geometry and the keeping of
//! covered pixels, which the calls share, and compose/ the other way of
//! doing it: each layer in a buffer of its own, copied on to the display
//! (`LATAG_Compose`, on the 64-bit machines). The jump table is layers_lvo.zig,
//! the ROM tag and init layers_init.zig, the base layers_base.zig. This
//! file holds the names the rest of the kernel reaches the library by, and
//! the tests of calls working together. Its functions are
//! `sdk/fd/layers_lib.fd` and its types `sdk/libs/layers/`.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const layers = sdk.layers;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const TagItem = sdk.utility.TagItem;

/// layers.library's base (layers_base.zig).
const layers_base = @import("layers_base.zig");
/// layers.library's ROM tag and init routine (layers_init.zig).
const layers_init = @import("layers_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from layers.library.
comptime {
    _ = &layers_init.layers_library_tag;
}

/// The library's base, for the modules that keep a pointer to it.
pub const LayersBase = layers_base.LayersBase;
/// What the library is on exec's list as.
pub const LIBRARY_NAME = layers_init.LIBRARY_NAME;
/// The ROM tag, for the host tests that make the library from it.
pub const layers_library_tag = layers_init.layers_library_tag;
const LIBRARY_VERSION = layers_init.LIBRARY_VERSION;
const LIBRARY_REVISION = layers_init.LIBRARY_REVISION;

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
/// The library's interface as the SDK has it, for the tests' calls.
const interface = sdk.interface.layers;
const info_mod = @import("layerinfo/_layerinfo.zig");
const kexec = @import("../exec/exec.zig");
const kutility = @import("../utility/utility.zig");
const krtg = @import("../rtg/rtg.zig");
const kgraphics = @import("../graphics/graphics.zig");
const rtg = sdk.rtg;
const utility = sdk.utility;
const Rect = graphics.Rect;

test {
    _ = layers_base;
    _ = layers_init;
    _ = @import("layers_lvo.zig");
    _ = @import("backfill/_backfill.zig");
    _ = @import("backfill/dohookcliprects.zig");
    _ = @import("backfill/installlayerhook.zig");
    _ = @import("compose/_compose.zig");
    _ = @import("compose/_effects.zig");
    _ = @import("compose/setlayerattrstaglist.zig");
    _ = @import("damage/beginupdate.zig");
    _ = @import("damage/damagelayer.zig");
    _ = @import("damage/endupdate.zig");
    _ = @import("damage/installclipregion.zig");
    _ = @import("errors/layerserrortext.zig");
    _ = @import("layer/_layer.zig");
    _ = @import("layer/behindlayer.zig");
    _ = @import("layer/createlayertaglist.zig");
    _ = @import("layer/deletelayer.zig");
    _ = @import("layer/getlayerattrs.zig");
    _ = @import("layer/movelayerinfrontof.zig");
    _ = @import("layer/upfrontlayer.zig");
    _ = @import("layer/whichlayer.zig");
    _ = @import("layerinfo/_layerinfo.zig");
    _ = @import("layerinfo/disposelayerinfo.zig");
    _ = @import("layerinfo/newlayerinfo.zig");
    _ = @import("layerinfo/newlayerinfotaglist.zig");
    _ = @import("locks/_locks.zig");
    _ = @import("locks/locklayer.zig");
    _ = @import("locks/locklayerinfo.zig");
    _ = @import("locks/locklayers.zig");
    _ = @import("locks/unlocklayer.zig");
    _ = @import("locks/unlocklayerinfo.zig");
    _ = @import("locks/unlocklayers.zig");
    _ = @import("move/movelayer.zig");
    _ = @import("move/movesizelayer.zig");
    _ = @import("move/sizelayer.zig");
    _ = @import("smart/_smart.zig");
    _ = @import("super/_super.zig");
    _ = @import("super/scrolllayer.zig");
    _ = @import("tile/_tile.zig");
}

fn setUp() !*LayersBase {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    _ = kexec.InitResident(kexec.SysBase, &krtg.rtg_library_tag, null) orelse return error.NoRtg;
    _ = kexec.InitResident(kexec.SysBase, &kgraphics.graphics_library_tag, null) orelse return error.NoGraphics;
    const made = kexec.InitResident(kexec.SysBase, &layers_library_tag, null) orelse return error.NoLayers;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

/// Nothing here expunges itself, so the test gives back every open and
/// frees all four: layers closes rtg, graphics and utility, graphics
/// closes rtg and utility, rtg closes utility.
fn tearDown(lb: *LayersBase) !void {
    const gb: *kgraphics.GraphicsBase = @ptrCast(@alignCast(lb.graphics_base));
    const rb: *krtg.RtgBase = @ptrCast(@alignCast(gb.rtg_base));
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(lb.utility_base));

    kexec.CloseLibrary(kexec.SysBase, &rb.lib);
    kexec.CloseLibrary(kexec.SysBase, &gb.lib);
    kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &lb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &lb.lib);

    kgraphics.freeOwnedForTests(gb);
    kexec.CloseLibrary(kexec.SysBase, &rb.lib);
    kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &gb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &gb.lib);

    kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &rb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &rb.lib);

    kutility.freeForTests(ub);
    try kexec.expectNoLeaks();
}

fn base(lb: *LayersBase) *interface.LayersBase {
    return @ptrCast(lb);
}

fn gbase(lb: *LayersBase) *GraphicsBase {
    return lb.graphics_base;
}

fn pixelAt(surface: *const rtg.Surface, x: u32, y: u32) u16 {
    const at = surface.pixels.? + @as(usize, y) * surface.pitch + x * 2;
    return @as(u16, at[0]) | @as(u16, at[1]) << 8;
}

/// A display of plain memory, and a RastPort on it - which is all
/// NewLayerInfo needs, since it asks the RastPort how big the display is
/// and where its pixels are.
fn display(lb: *LayersBase, surface: *rtg.Surface) !*graphics.RastPort {
    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) }, .{} };
    return gbase(lb).CreateRastPortTagList(&tags) orelse error.NoRastPort;
}

fn fill(lb: *LayersBase, layer: *layers.Layer, pen: graphics.Pen, area: Rect) void {
    var rp: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&rp) }, .{} };
    base(lb).GetLayerAttrs(layer, &ask);
    const set = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{} };
    gbase(lb).SetRPAttrs(@ptrFromInt(rp), &set);
    gbase(lb).RectFill(@ptrFromInt(rp), &area);
}

const red: u16 = 0xF800;
const green: u16 = 0x07E0;
const blue: u16 = 0x001F;

test "layers.library: made from its tag, opened by name, and it stays" {
    const lb = try setUp();
    defer kexec.deinit();

    try testing.expectEqualStrings(LIBRARY_NAME, lb.lib.name());
    try testing.expectEqual(@as(u16, LIBRARY_REVISION), lb.lib.revision);

    const opened = kexec.OpenLibrary(kexec.SysBase, LIBRARY_NAME, 0) orelse return error.NotOpened;
    kexec.CloseLibrary(kexec.SysBase, opened);
    // A closed ROM library stays on the list: its code is in the image.
    try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, LIBRARY_NAME) != null);
    try testing.expect(kexec.OpenLibrary(kexec.SysBase, LIBRARY_NAME, LIBRARY_VERSION + 1) == null);

    try tearDown(lb);
}

test "layers: what is in front takes the pixels, and each draws at its own corner" {
    const lb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 16 * 2]u8 = @splat(0);
    var surface = rtg.Surface{
        .pixels = &pixels,
        .width = 32,
        .height = 16,
        .pitch = 32 * 2,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const screen = try display(lb, &surface);
    const info = base(lb).NewLayerInfo(screen) orelse return error.NoLayerInfo;

    const back_where = Rect{ .min_x = 0, .min_y = 0, .max_x = 20, .max_y = 10 };
    const back_tags = [_]TagItem{ .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&back_where) }, .{} };
    const back = base(lb).CreateLayerTagList(info, &back_tags) orelse return error.NoLayer;

    const front_where = Rect{ .min_x = 12, .min_y = 6, .max_x = 32, .max_y = 16 };
    const front_tags = [_]TagItem{ .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&front_where) }, .{} };
    const front = base(lb).CreateLayerTagList(info, &front_tags) orelse return error.NoLayer;

    // The back layer fills all of itself, in its own coordinates. Only
    // what the front one does not cover lands.
    fill(lb, back, graphics.penRGB(255, 0, 0), .{ .max_x = 20, .max_y = 10 });
    try testing.expectEqual(red, pixelAt(&surface, 5, 3));
    try testing.expectEqual(red, pixelAt(&surface, 15, 3));
    try testing.expectEqual(red, pixelAt(&surface, 5, 8));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 15, 8)); // covered
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 25, 3)); // outside it

    // The front one draws at (0,0) and means its own corner, which is
    // (12,6) on the display.
    fill(lb, front, graphics.penRGB(0, 255, 0), .{ .max_x = 20, .max_y = 10 });
    try testing.expectEqual(green, pixelAt(&surface, 12, 6));
    try testing.expectEqual(green, pixelAt(&surface, 31, 15));
    try testing.expectEqual(red, pixelAt(&surface, 5, 3)); // untouched

    // Which layer a point belongs to is the frontmost one over it.
    try testing.expectEqual(front, base(lb).WhichLayer(info, 15, 8).?);
    try testing.expectEqual(back, base(lb).WhichLayer(info, 5, 3).?);
    try testing.expect(base(lb).WhichLayer(info, 25, 2) == null);

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

test "layers: a smart layer keeps what is covered and gets it back" {
    const lb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 16 * 2]u8 = @splat(0);
    var surface = rtg.Surface{
        .pixels = &pixels,
        .width = 32,
        .height = 16,
        .pitch = 32 * 2,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const screen = try display(lb, &surface);
    const info = base(lb).NewLayerInfo(screen) orelse return error.NoLayerInfo;

    const back_where = Rect{ .min_x = 0, .min_y = 0, .max_x = 20, .max_y = 10 };
    const back_tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&back_where) },
        .{ .tag = layers.LATAG_Refresh, .data = layers.LAYERSMART },
        .{},
    };
    const back = base(lb).CreateLayerTagList(info, &back_tags) orelse return error.NoLayer;

    const front_where = Rect{ .min_x = 12, .min_y = 6, .max_x = 32, .max_y = 16 };
    const front_tags = [_]TagItem{ .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&front_where) }, .{} };
    const front = base(lb).CreateLayerTagList(info, &front_tags) orelse return error.NoLayer;

    // The back layer fills all of itself. What the front one covers does
    // not reach the display - but unlike a simple layer, it is not thrown
    // away either.
    fill(lb, back, graphics.penRGB(255, 0, 0), .{ .max_x = 20, .max_y = 10 });
    try testing.expectEqual(red, pixelAt(&surface, 5, 3));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 15, 8));

    // Take the front one away. The pixels come back on their own, and the
    // layer is not asked to draw anything.
    base(lb).DeleteLayer(front);
    try testing.expectEqual(red, pixelAt(&surface, 15, 8));
    try testing.expectEqual(red, pixelAt(&surface, 19, 9));
    try testing.expectEqual(red, pixelAt(&surface, 12, 6));
    // And nothing outside the layer was touched on the way.
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 20, 8));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 15, 10));

    // A smart layer is never owed a redraw, which is what it is for.
    var flags: u32 = 0;
    const ask_flags = [_]TagItem{ .{ .tag = layers.LATAG_GetFlags, .data = @intFromPtr(&flags) }, .{} };
    base(lb).GetLayerAttrs(back, &ask_flags);
    try testing.expectEqual(@as(u32, 0), flags & layers.LAYERREFRESH);
    try testing.expectEqual(layers.LAYERSMART, flags & layers.LAYERSMART);

    // With the front one gone the back one is frontmost; a new one goes in
    // front of it.
    var in_front: usize = 1;
    const ask_front = [_]TagItem{ .{ .tag = layers.LATAG_GetInFront, .data = @intFromPtr(&in_front) }, .{} };
    base(lb).GetLayerAttrs(back, &ask_front);
    try testing.expectEqual(@as(usize, 0), in_front);
    const again = base(lb).CreateLayerTagList(info, &front_tags) orelse return error.NoLayer;
    base(lb).GetLayerAttrs(back, &ask_front);
    try testing.expectEqual(@intFromPtr(again), in_front);
    base(lb).GetLayerAttrs(again, &ask_front);
    try testing.expectEqual(@as(usize, 0), in_front);

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

/// A display of plain memory with a LayerInfo on it, for the tests that
/// need one and nothing else.
fn scene(lb: *LayersBase, surface: *rtg.Surface, pixels: []u8) !struct { *graphics.RastPort, *layers.LayerInfo } {
    surface.* = .{
        .pixels = pixels.ptr,
        .width = 32,
        .height = 16,
        .pitch = 32 * 2,
        .size_bytes = 32 * 16 * 2,
        .format = .rgb565,
    };
    const screen = try display(lb, surface);
    const info = base(lb).NewLayerInfo(screen) orelse return error.NoLayerInfo;
    return .{ screen, info };
}

fn layerAt(lb: *LayersBase, info: *layers.LayerInfo, where: *const Rect, refresh: usize) !*layers.Layer {
    const tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(where) },
        .{ .tag = layers.LATAG_Refresh, .data = refresh },
        .{},
    };
    return base(lb).CreateLayerTagList(info, &tags) orelse error.NoLayer;
}

fn owed(lb: *LayersBase, layer: *layers.Layer) u32 {
    var flags: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetFlags, .data = @intFromPtr(&flags) }, .{} };
    base(lb).GetLayerAttrs(layer, &ask);
    return flags & layers.LAYERREFRESH;
}

/// A backfill hook that paints the area it is given in blue, so a test can
/// tell it apart from the default and from nothing at all.
fn blueBackFill(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const gb: *GraphicsBase = @ptrCast(@alignCast(hook.data.?));
    const rp: *graphics.RastPort = @ptrCast(@alignCast(object.?));
    const msg: *layers.BackFillMsg = @ptrCast(@alignCast(message.?));
    const pen = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 0, 255) }, .{} };
    gb.SetRPAttrs(rp, &pen);
    gb.RectFill(rp, &msg.area);
    return 0;
}

test "layers: a layer with its own bitmap draws into all of it, and scrolls" {
    const lb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 16 * 2 + 64]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);

    // A bitmap twice the layer's width, so half of it is off the window.
    const bm_tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = 16 },
        .{ .tag = graphics.BMTAG_Height, .data = 8 },
        .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(rtg.bitmaps.PixelFormat.rgb565) },
        .{ .tag = graphics.BMTAG_Clear, .data = 1 },
        .{},
    };
    const sheet = gbase(lb).AllocBitMapTagList(&bm_tags) orelse return error.NoBitMap;

    const where = Rect{ .min_x = 4, .min_y = 4, .max_x = 12, .max_y = 12 };
    const tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&where) },
        .{ .tag = layers.LATAG_Refresh, .data = layers.LAYERSUPER },
        .{ .tag = layers.LATAG_SuperBitMap, .data = @intFromPtr(sheet) },
        .{},
    };
    const layer = base(lb).CreateLayerTagList(info, &tags) orelse return error.NoLayer;

    // The left half of the bitmap is what the window shows; the right half
    // is not on the display at all. Both are drawn in one call, in the
    // bitmap's coordinates.
    fill(lb, layer, graphics.penRGB(255, 0, 0), .{ .max_x = 8, .max_y = 8 });
    fill(lb, layer, graphics.penRGB(0, 255, 0), .{ .min_x = 8, .max_x = 16, .max_y = 8 });
    try testing.expectEqual(red, pixelAt(&surface, 4, 4));
    try testing.expectEqual(red, pixelAt(&surface, 11, 11));
    // The green half went into the bitmap and nowhere near the display.
    var x: u32 = 0;
    while (x < 32) : (x += 1) {
        var y: u32 = 0;
        while (y < 16) : (y += 1) try testing.expect(pixelAt(&surface, x, y) != green);
    }

    // Scrolling the window on to the other half shows it, without the
    // layer drawing anything.
    try testing.expect(base(lb).ScrollLayer(layer, 8, 0));
    try testing.expectEqual(green, pixelAt(&surface, 4, 4));
    try testing.expectEqual(green, pixelAt(&surface, 11, 11));
    var at: graphics.Point = .{};
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetScroll, .data = @intFromPtr(&at) }, .{} };
    base(lb).GetLayerAttrs(layer, &ask);
    try testing.expectEqual(@as(i32, 8), at.x);

    // It stops at the bitmap's edge rather than showing what is not there.
    try testing.expect(base(lb).ScrollLayer(layer, 100, 0));
    base(lb).GetLayerAttrs(layer, &ask);
    try testing.expectEqual(@as(i32, 8), at.x);

    // And back, which finds the red half as it was left.
    try testing.expect(base(lb).ScrollLayer(layer, -8, 0));
    try testing.expectEqual(red, pixelAt(&surface, 4, 4));

    // A layer asking for its own bitmap without giving one is refused.
    var why: i32 = 0;
    const bad = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&where) },
        .{ .tag = layers.LATAG_Refresh, .data = layers.LAYERSUPER },
        .{ .tag = layers.LATAG_ErrorPtr, .data = @intFromPtr(&why) },
        .{},
    };
    try testing.expect(base(lb).CreateLayerTagList(info, &bad) == null);
    try testing.expectEqual(layers.LERR_NO_SUPERBITMAP, why);

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeBitMap(sheet);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

/// A hook that counts the pieces it is offered and adds up their area.
const Tally = struct { calls: u32 = 0, area: i32 = 0 };

fn tallyHook(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const tally: *Tally = @ptrCast(@alignCast(hook.data.?));
    const msg: *layers.BackFillMsg = @ptrCast(@alignCast(message.?));
    tally.calls += 1;
    tally.area += msg.area.width() * msg.area.height();
    return 0;
}

test "layers: the backfill can be changed, the pieces handed over, and what is seen is what is asked" {
    const lb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 16 * 2 + 64]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);

    // A back layer with a corner of it covered, so it has more than one
    // piece to hand over.
    const back_where = Rect{ .max_x = 20, .max_y = 10 };
    const back = try layerAt(lb, info, &back_where, layers.LAYERSIMPLE);
    const front_where = Rect{ .min_x = 12, .min_y = 6, .max_x = 20, .max_y = 10 };
    _ = try layerAt(lb, info, &front_where, layers.LAYERSIMPLE);

    // What the back layer can see is its 20x10 less the 8x4 corner.
    var rp_at: usize = 0;
    const ask_rp = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&rp_at) }, .{} };
    base(lb).GetLayerAttrs(back, &ask_rp);
    const rp: *graphics.RastPort = @ptrFromInt(rp_at);

    var tally = Tally{};
    var hook = utility.Hook{ .entry = &tallyHook, .data = @ptrCast(&tally) };
    base(lb).DoHookClipRects(&hook, rp, &.{ .max_x = 20, .max_y = 10 });
    try testing.expect(tally.calls > 1); // more than one piece
    try testing.expectEqual(@as(i32, 20 * 10 - 8 * 4), tally.area);

    // Asked for less, it hands over less and nothing outside it.
    tally = .{};
    base(lb).DoHookClipRects(&hook, rp, &.{ .max_x = 4, .max_y = 4 });
    try testing.expectEqual(@as(i32, 16), tally.area);

    // The backfill can be changed after the fact, and what was there comes
    // back so it can be put where it was.
    try testing.expectEqual(@as(usize, 0), base(lb).InstallLayerHook(back, layers.LAYERS_NOBACKFILL));
    try testing.expectEqual(layers.LAYERS_NOBACKFILL, base(lb).InstallLayerHook(back, @intFromPtr(&hook)));
    try testing.expectEqual(@intFromPtr(&hook), base(lb).InstallLayerHook(back, 0));

    // A layer hanging off the display can be seen only where the display
    // is, and WhichLayer says so - the rectangle alone would not.
    const over_where = Rect{ .min_x = 24, .min_y = 8, .max_x = 40, .max_y = 24 };
    const over = try layerAt(lb, info, &over_where, layers.LAYERSIMPLE);
    try testing.expectEqual(over, base(lb).WhichLayer(info, 28, 10).?);
    try testing.expect(base(lb).WhichLayer(info, 34, 10) == null); // in it, off the display
    try testing.expect(base(lb).WhichLayer(info, 28, 20) == null);

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

test "layers: the library takes the locks itself, and they nest" {
    const lb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 16 * 2 + 64]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);
    const li: *info_mod.LayerInfo = @ptrCast(@alignCast(info));

    // Every call that rebuilds the tiling takes every layer's lock, so a
    // caller that is already holding them must not be shut out by its own
    // hold. If that were wrong this test would not fail - it would stop.
    base(lb).LockLayers(info);
    try testing.expectEqual(@as(u32, 1), li.locked_all);

    const where = Rect{ .max_x = 10, .max_y = 8 };
    const layer = try layerAt(lb, info, &where, layers.LAYERSIMPLE);
    // It joined a list that is being held, so it has to be holding too:
    // the list is released as a list, and a semaphore on it that was never
    // obtained is one the release cannot account for.
    const l: *info_mod.Layer = @ptrCast(@alignCast(layer));
    try testing.expectEqual(@as(i16, 1), l.lock.nest_count);

    try testing.expect(base(lb).MoveLayer(layer, 2, 2));
    try testing.expect(base(lb).UpfrontLayer(layer));
    try testing.expectEqual(@as(i16, 1), l.lock.nest_count);

    // And the hold is still exactly one deep: what the library took, it
    // gave back.
    try testing.expectEqual(@as(u32, 1), li.locked_all);
    base(lb).UnlockLayers(info);
    try testing.expectEqual(@as(u32, 0), li.locked_all);
    // And the inherited hold went back with it.
    try testing.expectEqual(@as(i16, 0), l.lock.nest_count);

    // A layer's own lock nests the same way, which is what a drawing task
    // holds while it draws - and an update holds it from BeginUpdate to
    // EndUpdate, a level of its own.
    base(lb).LockLayer(layer);
    base(lb).LockLayer(layer);
    try testing.expectEqual(@as(i16, 2), l.lock.nest_count);
    if (base(lb).BeginUpdate(layer)) {
        try testing.expectEqual(@as(i16, 3), l.lock.nest_count);
        base(lb).EndUpdate(layer, true);
    }
    try testing.expectEqual(@as(i16, 2), l.lock.nest_count);
    base(lb).UnlockLayer(layer);
    base(lb).UnlockLayer(layer);
    try testing.expectEqual(@as(i16, 0), l.lock.nest_count);

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

test "layers: a new layer is painted, unless it says not to or says how" {
    const lb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 16 * 2 + 64]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);

    // Something under them, so "left as it was" is visible as itself.
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    gbase(lb).SetRPAttrs(screen, &white);
    gbase(lb).RectFill(screen, &.{ .max_x = 32, .max_y = 16 });
    const was: u16 = 0xFFFF;
    try testing.expectEqual(was, pixelAt(&surface, 1, 1));

    // Nothing said: the layer's own background pen, which is black.
    const plain_where = Rect{ .max_x = 6, .max_y = 6 };
    const plain = try layerAt(lb, info, &plain_where, layers.LAYERSIMPLE);
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 2, 2));

    // Told not to: whatever was there stays, which is what a layer that is
    // about to draw all of itself wants.
    const bare_where = Rect{ .min_x = 10, .max_x = 16, .max_y = 6 };
    const bare_tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&bare_where) },
        .{ .tag = layers.LATAG_BackFill, .data = layers.LAYERS_NOBACKFILL },
        .{},
    };
    const bare = base(lb).CreateLayerTagList(info, &bare_tags) orelse return error.NoLayer;
    try testing.expectEqual(was, pixelAt(&surface, 12, 2));

    // Told how: the hook paints it, through the layer's own RastPort and
    // in the layer's own coordinates.
    var hook = utility.Hook{ .entry = &blueBackFill, .data = @ptrCast(gbase(lb)) };
    const hooked_where = Rect{ .min_x = 20, .max_x = 28, .max_y = 6 };
    const hooked_tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&hooked_where) },
        .{ .tag = layers.LATAG_BackFill, .data = @intFromPtr(&hook) },
        .{},
    };
    const hooked = base(lb).CreateLayerTagList(info, &hooked_tags) orelse return error.NoLayer;
    try testing.expectEqual(blue, pixelAt(&surface, 22, 2));
    try testing.expectEqual(blue, pixelAt(&surface, 27, 5));
    try testing.expectEqual(was, pixelAt(&surface, 28, 2)); // and no further

    _ = plain;
    _ = bare;
    _ = hooked;
    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

test "layers: a moved layer carries its pixels, and a smart one carries the covered ones too" {
    const lb = try setUp();
    defer kexec.deinit();

    // Room to spare behind the display, so a write past it is visible.
    var pixels: [32 * 16 * 2 + 64]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);

    // The back one is smart, and the front one covers its right-hand end.
    const back_where = Rect{ .max_x = 10, .max_y = 8 };
    const back = try layerAt(lb, info, &back_where, layers.LAYERSMART);
    const front_where = Rect{ .min_x = 6, .max_x = 16, .max_y = 8 };
    const front = try layerAt(lb, info, &front_where, layers.LAYERSIMPLE);

    fill(lb, back, graphics.penRGB(255, 0, 0), .{ .max_x = 10, .max_y = 8 });
    fill(lb, front, graphics.penRGB(0, 255, 0), .{ .max_x = 10, .max_y = 8 });
    try testing.expectEqual(red, pixelAt(&surface, 2, 3));
    try testing.expectEqual(green, pixelAt(&surface, 8, 3)); // the front one has it

    // Move the back one clear of the other. Everything it had comes with
    // it - including the part that was covered, which only its own keeping
    // could have supplied.
    try testing.expect(base(lb).MoveLayer(back, 0, 8));
    try testing.expectEqual(red, pixelAt(&surface, 2, 11));
    try testing.expectEqual(red, pixelAt(&surface, 8, 11)); // was covered
    try testing.expectEqual(red, pixelAt(&surface, 9, 15));
    // A smart layer is owed nothing, whatever happens to it.
    try testing.expectEqual(@as(u32, 0), owed(lb, back));
    // And the front one is where it was, untouched.
    try testing.expectEqual(green, pixelAt(&surface, 8, 3));

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

test "layers: a layer moved over a smart one behind it leaves it its own pixels" {
    const lb = try setUp();
    defer kexec.deinit();
    var pixels: [32 * 16 * 2 + 64]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);

    // For each kind of mover: a smart layer behind, the mover beside it and
    // then moved over part of it, then the one behind raised - it must show
    // what it drew, not what was carried over it.
    for ([_]usize{ layers.LAYERSIMPLE, layers.LAYERSMART }) |mode| {
        const back_where = Rect{ .max_x = 10, .max_y = 8 };
        const back = try layerAt(lb, info, &back_where, layers.LAYERSMART);
        const mover_where = Rect{ .min_x = 16, .max_x = 26, .max_y = 8 };
        const mover = try layerAt(lb, info, &mover_where, mode);
        fill(lb, back, graphics.penRGB(255, 0, 0), .{ .max_x = 10, .max_y = 8 });
        fill(lb, mover, graphics.penRGB(0, 255, 0), .{ .max_x = 10, .max_y = 8 });

        try testing.expect(base(lb).MoveLayer(mover, -10, 0));
        try testing.expectEqual(green, pixelAt(&surface, 8, 3));
        try testing.expect(base(lb).UpfrontLayer(back));
        try testing.expectEqual(red, pixelAt(&surface, 8, 3));
        try testing.expectEqual(red, pixelAt(&surface, 9, 7));
        try testing.expectEqual(green, pixelAt(&surface, 12, 3));

        base(lb).DeleteLayer(mover);
        base(lb).DeleteLayer(back);
    }

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

fn rgb565(r: u32, g: u32, b: u32) u16 {
    return @intCast((r >> 3) << 11 | (g >> 2) << 5 | (b >> 3));
}

/// Each layer's picture: its top half one colour, its bottom half another,
/// so a piece of a layer in the wrong place shows as well as a piece of the
/// wrong layer.
const Painted = struct {
    top: [3]u32,
    bottom: [3]u32,

    fn paint(p: Painted, lb: *LayersBase, layer: *layers.Layer, w: i32, h: i32) void {
        fill(lb, layer, graphics.penRGB(@intCast(p.top[0]), @intCast(p.top[1]), @intCast(p.top[2])), .{ .max_x = w, .max_y = @divTrunc(h, 2) });
        fill(lb, layer, graphics.penRGB(@intCast(p.bottom[0]), @intCast(p.bottom[1]), @intCast(p.bottom[2])), .{ .min_y = @divTrunc(h, 2), .max_x = w, .max_y = h });
    }

    fn at(p: Painted, y: i32, h: i32) u16 {
        const c = if (y < @divTrunc(h, 2)) p.top else p.bottom;
        return rgb565(c[0], c[1], c[2]);
    }
};

test "layers: a layer made over a smart one and moved off it gives it back its own pixels" {
    const lb = try setUp();
    defer kexec.deinit();
    var pixels: [32 * 16 * 2 + 64]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);

    // The smart one draws first; then a simple one is made over it, which
    // paints itself at once - after the smart one has put away what it
    // covers, or it would keep the new layer's paint.
    const r0 = Rect{ .max_x = 12, .max_y = 8 };
    const l0 = try layerAt(lb, info, &r0, layers.LAYERSMART);
    fill(lb, l0, graphics.penRGB(255, 0, 0), .{ .max_x = 12, .max_y = 8 });
    const r1 = Rect{ .min_x = 5, .min_y = 2, .max_x = 17, .max_y = 10 };
    const l1 = try layerAt(lb, info, &r1, layers.LAYERSIMPLE);
    try testing.expect(pixelAt(&surface, 5, 2) != red);
    try testing.expect(base(lb).MoveLayer(l1, 3, -1));
    try testing.expectEqual(red, pixelAt(&surface, 5, 2));
    try testing.expectEqual(red, pixelAt(&surface, 7, 7));
    base(lb).DeleteLayer(l1);
    try testing.expectEqual(red, pixelAt(&surface, 11, 7));

    base(lb).DeleteLayer(l0);
    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

test "layers: moved, sized and reordered at random, every pixel is the front layer's" {
    const lb = try setUp();
    defer kexec.deinit();
    var pixels: [32 * 16 * 2 + 64]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);

    const pictures = [_]Painted{
        .{ .top = .{ 255, 0, 0 }, .bottom = .{ 0, 255, 0 } },
        .{ .top = .{ 0, 0, 255 }, .bottom = .{ 255, 255, 0 } },
        .{ .top = .{ 255, 0, 255 }, .bottom = .{ 0, 255, 255 } },
        .{ .top = .{ 255, 255, 255 }, .bottom = .{ 0, 0, 0 } },
    };
    // Two smart layers and two simple ones, interleaved.
    const modes = [_]usize{ layers.LAYERSMART, layers.LAYERSIMPLE, layers.LAYERSMART, layers.LAYERSIMPLE };
    var made: [4]*layers.Layer = undefined;
    var where: [4]Rect = undefined;
    // Front first.
    var order: [4]usize = undefined;
    for (0..4) |i| {
        where[i] = .{ .min_x = @intCast(i * 5), .min_y = @intCast(i * 2), .max_x = @intCast(i * 5 + 12), .max_y = @intCast(i * 2 + 8) };
        made[i] = try layerAt(lb, info, &where[i], modes[i]);
        pictures[i].paint(lb, made[i], 12, 8);
        order[3 - i] = i;
    }

    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rand = prng.random();
    var step: u32 = 0;
    while (step < 1000) : (step += 1) {
        const i = rand.uintLessThan(usize, 4);
        const w = where[i].width();
        const h = where[i].height();
        const op = rand.uintLessThan(u32, 4);
        switch (op) {
            0 => {
                // A move that stays on the display.
                const dx = rand.intRangeAtMost(i32, -where[i].min_x, 32 - where[i].max_x);
                const dy = rand.intRangeAtMost(i32, -where[i].min_y, 16 - where[i].max_y);
                try testing.expect(base(lb).MoveLayer(made[i], dx, dy));
                where[i] = .{ .min_x = where[i].min_x + dx, .min_y = where[i].min_y + dy, .max_x = where[i].max_x + dx, .max_y = where[i].max_y + dy };
            },
            1 => {
                // A size between 4x4 and what fits, then the program draws
                // its picture again for the new size.
                const nw = rand.intRangeAtMost(i32, 4, @min(16, 32 - where[i].min_x));
                const nh = rand.intRangeAtMost(i32, 4, @min(12, 16 - where[i].min_y));
                try testing.expect(base(lb).SizeLayer(made[i], nw - w, nh - h));
                where[i].max_x = where[i].min_x + nw;
                where[i].max_y = where[i].min_y + nh;
                pictures[i].paint(lb, made[i], nw, nh);
            },
            2 => {
                try testing.expect(base(lb).UpfrontLayer(made[i]));
                var k: usize = 0;
                while (order[k] != i) k += 1;
                while (k > 0) : (k -= 1) order[k] = order[k - 1];
                order[0] = i;
            },
            else => {
                try testing.expect(base(lb).BehindLayer(made[i]));
                var k: usize = 0;
                while (order[k] != i) k += 1;
                while (k < 3) : (k += 1) order[k] = order[k + 1];
                order[3] = i;
            },
        }
        // A simple layer owed a redraw gets one, as its program would.
        for (0..4) |j| {
            if (owed(lb, made[j]) == 0) continue;
            if (base(lb).BeginUpdate(made[j])) {
                pictures[j].paint(lb, made[j], where[j].width(), where[j].height());
                base(lb).EndUpdate(made[j], true);
            }
        }
        // Every pixel a layer covers is the frontmost one's.
        var y: i32 = 0;
        while (y < 16) : (y += 1) {
            var x: i32 = 0;
            while (x < 32) : (x += 1) {
                for (order) |j| {
                    const r = where[j];
                    if (x < r.min_x or x >= r.max_x or y < r.min_y or y >= r.max_y) continue;
                    const want = pictures[j].at(y - r.min_y, r.height());
                    const have = pixelAt(&surface, @intCast(x), @intCast(y));
                    if (want != have) {
                        std.debug.print("step {d}: pixel {d},{d} is {x:0>4}, layer {d} wants {x:0>4}\n", .{ step, x, y, have, j, want });
                        return error.TestUnexpectedResult;
                    }
                    break;
                }
            }
        }
    }

    for (made) |l| base(lb).DeleteLayer(l);
    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

test "layers: a layer moving with another goes in the same pass, and neither owes anything for it" {
    const lb = try setUp();
    defer kexec.deinit();
    var pixels: [32 * 16 * 2]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);

    // A window: its border's layer, and its interior's in front of it,
    // moving with it.
    const outer_where = Rect{ .min_x = 2, .min_y = 2, .max_x = 14, .max_y = 10 };
    const outer = try layerAt(lb, info, &outer_where, layers.LAYERSIMPLE);
    const inner_where = Rect{ .min_x = 4, .min_y = 4, .max_x = 12, .max_y = 8 };
    const inner_tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&inner_where) },
        .{ .tag = layers.LATAG_MovesWith, .data = @intFromPtr(outer) },
        .{},
    };
    const inner = base(lb).CreateLayerTagList(info, &inner_tags) orelse return error.NoLayer;
    fill(lb, outer, graphics.penRGB(255, 0, 0), .{ .max_x = 12, .max_y = 8 });
    fill(lb, inner, graphics.penRGB(0, 0, 255), .{ .max_x = 8, .max_y = 4 });

    // Moved further than the border is wide: each would have uncovered the
    // other on the way, and here neither does.
    try testing.expect(base(lb).MoveLayer(outer, 6, 4));
    try testing.expectEqual(Rect{ .min_x = 10, .min_y = 8, .max_x = 18, .max_y = 12 }, boundsOf(lb, inner));
    try testing.expectEqual(@as(u32, 0), owed(lb, outer));
    try testing.expectEqual(@as(u32, 0), owed(lb, inner));
    try testing.expectEqual(red, pixelAt(&surface, 8, 6)); // the border's corner
    try testing.expectEqual(red, pixelAt(&surface, 9, 10)); // its left side
    try testing.expectEqual(blue, pixelAt(&surface, 10, 8)); // the interior's corner
    try testing.expectEqual(blue, pixelAt(&surface, 17, 11));
    try testing.expectEqual(red, pixelAt(&surface, 19, 13)); // the border's far corner

    // Sized, the interior grows with it, and keeps what it had.
    try testing.expect(base(lb).SizeLayer(outer, 4, 2));
    try testing.expectEqual(Rect{ .min_x = 10, .min_y = 8, .max_x = 22, .max_y = 14 }, boundsOf(lb, inner));
    try testing.expectEqual(blue, pixelAt(&surface, 17, 11));

    // Moved on its own, it moves alone.
    try testing.expect(base(lb).MoveLayer(inner, 1, 0));
    try testing.expectEqual(Rect{ .min_x = 8, .min_y = 6, .max_x = 24, .max_y = 16 }, boundsOf(lb, outer));
    try testing.expectEqual(Rect{ .min_x = 11, .min_y = 8, .max_x = 23, .max_y = 14 }, boundsOf(lb, inner));

    // With the layer it moved with gone, it stays, on its own.
    base(lb).DeleteLayer(outer);
    try testing.expect(base(lb).MoveLayer(inner, -1, 0));
    try testing.expectEqual(Rect{ .min_x = 10, .min_y = 8, .max_x = 22, .max_y = 14 }, boundsOf(lb, inner));

    // A layer of another display is not one to move with.
    const other_info = base(lb).NewLayerInfo(screen) orelse return error.NoLayerInfo;
    var why: i32 = 0;
    const stray_tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&inner_where) },
        .{ .tag = layers.LATAG_MovesWith, .data = @intFromPtr(inner) },
        .{ .tag = layers.LATAG_ErrorPtr, .data = @intFromPtr(&why) },
        .{},
    };
    try testing.expect(base(lb).CreateLayerTagList(other_info, &stray_tags) == null);
    try testing.expectEqual(layers.LERR_NOT_DONE, why);

    base(lb).DisposeLayerInfo(other_info);
    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

/// Where a layer is, in the display's coordinates.
fn boundsOf(lb: *LayersBase, layer: *layers.Layer) Rect {
    var bounds = Rect{};
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetBounds, .data = @intFromPtr(&bounds) }, .{} };
    base(lb).GetLayerAttrs(layer, &ask);
    return bounds;
}

test "layers: a window's two layers among others, moved, sized and reordered at random: every pixel is the front one's" {
    try randomWindow(layers.LAYERSIMPLE);
    try randomWindow(layers.LAYERSMART);
}

/// A window - a border's layer and an interior's moving with it, both of
/// `mode` - among a smart and a simple layer, moved, sized and reordered
/// at random. Every pixel is the frontmost layer's after each step, and
/// the window moved while nothing is in front of it owes nothing.
fn randomWindow(mode: usize) !void {
    const lb = try setUp();
    defer kexec.deinit();
    var pixels: [32 * 16 * 2 + 64]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);
    const border = 2;

    const pictures = [_]Painted{
        .{ .top = .{ 255, 0, 0 }, .bottom = .{ 0, 255, 0 } },
        .{ .top = .{ 0, 0, 255 }, .bottom = .{ 255, 255, 0 } },
        .{ .top = .{ 255, 0, 255 }, .bottom = .{ 0, 255, 255 } },
        .{ .top = .{ 255, 255, 255 }, .bottom = .{ 0, 0, 0 } },
    };
    // 0 the window's border, 1 its interior, 2 and 3 the others.
    var made: [4]*layers.Layer = undefined;
    var where: [4]Rect = undefined;
    where[0] = .{ .min_x = 0, .min_y = 0, .max_x = 12, .max_y = 9 };
    made[0] = try layerAt(lb, info, &where[0], mode);
    where[1] = insetOf(where[0], border);
    const inner_tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&where[1]) },
        .{ .tag = layers.LATAG_Refresh, .data = mode },
        .{ .tag = layers.LATAG_MovesWith, .data = @intFromPtr(made[0]) },
        .{},
    };
    made[1] = base(lb).CreateLayerTagList(info, &inner_tags) orelse return error.NoLayer;
    where[2] = .{ .min_x = 8, .min_y = 3, .max_x = 20, .max_y = 11 };
    made[2] = try layerAt(lb, info, &where[2], layers.LAYERSMART);
    where[3] = .{ .min_x = 16, .min_y = 6, .max_x = 28, .max_y = 14 };
    made[3] = try layerAt(lb, info, &where[3], layers.LAYERSIMPLE);
    for (0..4) |i| pictures[i].paint(lb, made[i], where[i].width(), where[i].height());
    // Front first: the window is one unit, its interior just in front of
    // its border.
    var order = [_]usize{ 3, 2, 0 };

    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rand = prng.random();
    var step: u32 = 0;
    while (step < 1000) : (step += 1) {
        const unit = order[rand.uintLessThan(usize, 3)];
        const i = unit;
        const op = rand.uintLessThan(u32, 4);
        switch (op) {
            0 => {
                // A move that stays on the display.
                const dx = rand.intRangeAtMost(i32, -where[i].min_x, 32 - where[i].max_x);
                const dy = rand.intRangeAtMost(i32, -where[i].min_y, 16 - where[i].max_y);
                try testing.expect(base(lb).MoveLayer(made[i], dx, dy));
                where[i] = .{ .min_x = where[i].min_x + dx, .min_y = where[i].min_y + dy, .max_x = where[i].max_x + dx, .max_y = where[i].max_y + dy };
                if (i == 0) {
                    where[1] = insetOf(where[0], border);
                    // Nothing in front of it: nothing of it was lost.
                    if (order[0] == 0) {
                        try testing.expectEqual(@as(u32, 0), owed(lb, made[0]));
                        try testing.expectEqual(@as(u32, 0), owed(lb, made[1]));
                    }
                }
            },
            1 => {
                // A size between 6x6 and what fits, then the program draws
                // its picture again for the new size.
                const nw = rand.intRangeAtMost(i32, 6, @min(16, 32 - where[i].min_x));
                const nh = rand.intRangeAtMost(i32, 6, @min(12, 16 - where[i].min_y));
                try testing.expect(base(lb).SizeLayer(made[i], nw - where[i].width(), nh - where[i].height()));
                where[i].max_x = where[i].min_x + nw;
                where[i].max_y = where[i].min_y + nh;
                pictures[i].paint(lb, made[i], nw, nh);
                if (i == 0) {
                    where[1] = insetOf(where[0], border);
                    pictures[1].paint(lb, made[1], where[1].width(), where[1].height());
                }
            },
            2 => {
                try testing.expect(base(lb).UpfrontLayer(made[i]));
                if (i == 0) try testing.expect(base(lb).MoveLayerInFrontOf(made[1], made[0]));
                var k: usize = 0;
                while (order[k] != unit) k += 1;
                while (k > 0) : (k -= 1) order[k] = order[k - 1];
                order[0] = unit;
            },
            else => {
                try testing.expect(base(lb).BehindLayer(made[i]));
                if (i == 0) try testing.expect(base(lb).MoveLayerInFrontOf(made[1], made[0]));
                var k: usize = 0;
                while (order[k] != unit) k += 1;
                while (k < 2) : (k += 1) order[k] = order[k + 1];
                order[2] = unit;
            },
        }
        // A layer owed a redraw gets one, as its program would.
        for (0..4) |j| {
            if (owed(lb, made[j]) == 0) continue;
            if (base(lb).BeginUpdate(made[j])) {
                pictures[j].paint(lb, made[j], where[j].width(), where[j].height());
                base(lb).EndUpdate(made[j], true);
            }
        }
        // Every pixel a layer covers is the frontmost one's.
        var y: i32 = 0;
        while (y < 16) : (y += 1) {
            var x: i32 = 0;
            while (x < 32) : (x += 1) {
                const front = frontAt(&order, &where, x, y) orelse continue;
                const r = where[front];
                const want = pictures[front].at(y - r.min_y, r.height());
                const have = pixelAt(&surface, @intCast(x), @intCast(y));
                if (want != have) {
                    std.debug.print("step {d}: pixel {d},{d} is {x:0>4}, layer {d} wants {x:0>4}\n", .{ step, x, y, have, front, want });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }

    for ([_]usize{ 1, 0, 2, 3 }) |i| base(lb).DeleteLayer(made[i]);
    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

/// A rectangle with `by` taken off each side.
fn insetOf(r: Rect, by: i32) Rect {
    return .{ .min_x = r.min_x + by, .min_y = r.min_y + by, .max_x = r.max_x - by, .max_y = r.max_y - by };
}

/// Which layer is in front at (`x`, `y`): the units front first, the
/// window's interior before its border.
fn frontAt(order: []const usize, where: []const Rect, x: i32, y: i32) ?usize {
    for (order) |unit| {
        const candidates: []const usize = if (unit == 0) &.{ 1, 0 } else &.{unit};
        for (candidates) |j| {
            const r = where[j];
            if (x >= r.min_x and x < r.max_x and y >= r.min_y and y < r.max_y) return j;
        }
    }
    return null;
}

test "layers: a simple layer is owed what it could not carry, and what a resize adds" {
    const lb = try setUp();
    defer kexec.deinit();

    // Room to spare behind the display, so a write past it is visible.
    var pixels: [32 * 16 * 2 + 64]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);

    const back_where = Rect{ .max_x = 10, .max_y = 8 };
    const back = try layerAt(lb, info, &back_where, layers.LAYERSIMPLE);
    const front_where = Rect{ .min_x = 6, .max_x = 16, .max_y = 8 };
    _ = try layerAt(lb, info, &front_where, layers.LAYERSIMPLE);

    fill(lb, back, graphics.penRGB(255, 0, 0), .{ .max_x = 10, .max_y = 8 });
    try testing.expectEqual(@as(u32, 0), owed(lb, back));

    // The same move, on a layer that kept nothing. What was visible
    // travels; what was covered is gone and is owed back.
    try testing.expect(base(lb).MoveLayer(back, 0, 8));
    try testing.expectEqual(red, pixelAt(&surface, 2, 11)); // carried
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 8, 11)); // was covered: lost
    try testing.expectEqual(layers.LAYERREFRESH, owed(lb, back));

    // The damage is exactly that part, so a full redraw touches only it.
    try testing.expect(base(lb).BeginUpdate(back));
    fill(lb, back, graphics.penRGB(0, 0, 255), .{ .max_x = 10, .max_y = 8 });
    try testing.expectEqual(blue, pixelAt(&surface, 8, 11));
    try testing.expectEqual(red, pixelAt(&surface, 2, 11)); // not owed, not touched
    base(lb).EndUpdate(back, true);
    try testing.expectEqual(@as(u32, 0), owed(lb, back));

    // Growing it adds room that has never held anything, so that is owed
    // too - and only that.
    try testing.expect(base(lb).SizeLayer(back, 4, 0));
    try testing.expectEqual(layers.LAYERREFRESH, owed(lb, back));
    try testing.expect(base(lb).BeginUpdate(back));
    fill(lb, back, graphics.penRGB(0, 255, 0), .{ .max_x = 14, .max_y = 8 });
    try testing.expectEqual(green, pixelAt(&surface, 12, 11)); // the new part
    try testing.expectEqual(red, pixelAt(&surface, 2, 11)); // the old part kept
    base(lb).EndUpdate(back, true);

    // Hanging off the edge writes nothing past the display. The buffer has
    // room to spare behind it, and a layer whose rectangle runs off the
    // right would spill into it on the last row if the tiling were not cut
    // to the display first.
    try testing.expect(base(lb).MoveLayer(back, 26, 0));
    fill(lb, back, graphics.penRGB(0, 0, 255), .{ .max_x = 14, .max_y = 8 });
    try testing.expectEqual(blue, pixelAt(&surface, 31, 15)); // the part still on it
    for (pixels[32 * 16 * 2 ..]) |b| try testing.expectEqual(@as(u8, 0), b);

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

test "layers: a simple layer's damage covered again is no longer owed, and is owed again when uncovered" {
    const lb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 16 * 2]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);

    const back_where = Rect{ .max_x = 16, .max_y = 8 };
    const back = try layerAt(lb, info, &back_where, layers.LAYERSIMPLE);
    const front_where = Rect{ .min_x = 8, .max_x = 16, .max_y = 8 };
    const front = try layerAt(lb, info, &front_where, layers.LAYERSIMPLE);
    try testing.expectEqual(@as(u32, 0), owed(lb, back));

    // The front one moved off: the back one is owed what it uncovered.
    try testing.expect(base(lb).MoveLayer(front, 0, 8));
    try testing.expectEqual(layers.LAYERREFRESH, owed(lb, back));
    try testing.expectEqual(Rect{ .min_x = 8, .max_x = 16, .max_y = 8 }, damageBounds(lb, back));

    // Half of it covered again before it was drawn: only the other half
    // is owed.
    try testing.expect(base(lb).MoveLayer(front, 4, -8));
    try testing.expectEqual(Rect{ .min_x = 8, .max_x = 12, .max_y = 8 }, damageBounds(lb, back));

    // All of it covered: nothing is owed.
    try testing.expect(base(lb).MoveLayer(front, -4, 0));
    try testing.expectEqual(@as(u32, 0), owed(lb, back));

    // Uncovered again, it is owed again - all of it.
    try testing.expect(base(lb).MoveLayer(front, 0, 8));
    try testing.expectEqual(layers.LAYERREFRESH, owed(lb, back));
    try testing.expectEqual(Rect{ .min_x = 8, .max_x = 16, .max_y = 8 }, damageBounds(lb, back));

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

test "layers: DamageLayer owes a layer an area, cut to what a simple one can see, and paints nothing" {
    const lb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 16 * 2]u8 = @splat(0);
    var surface: rtg.Surface = undefined;
    const screen, const info = try scene(lb, &surface, &pixels);

    // Two layers each half covered by one in front of it: a simple one at
    // the top, a smart one below.
    const simple_where = Rect{ .max_x = 16, .max_y = 8 };
    const simple = try layerAt(lb, info, &simple_where, layers.LAYERSIMPLE);
    const smart_where = Rect{ .min_y = 8, .max_x = 16, .max_y = 16 };
    const smart = try layerAt(lb, info, &smart_where, layers.LAYERSMART);
    const cover_where = Rect{ .min_x = 8, .max_x = 16, .max_y = 16 };
    _ = try layerAt(lb, info, &cover_where, layers.LAYERSIMPLE);
    fill(lb, simple, graphics.penRGB(255, 0, 0), .{ .max_x = 16, .max_y = 8 });
    try testing.expectEqual(@as(u32, 0), owed(lb, simple));

    // The simple one is owed only what it can see; the covered part keeps
    // nothing, and is owed when it is uncovered. What is there stays.
    try testing.expect(base(lb).DamageLayer(simple, &.{ .min_x = 2, .min_y = 1, .max_x = 14, .max_y = 6 }));
    try testing.expectEqual(layers.LAYERREFRESH, owed(lb, simple));
    try testing.expectEqual(Rect{ .min_x = 2, .min_y = 1, .max_x = 8, .max_y = 6 }, damageBounds(lb, simple));
    try testing.expectEqual(red, pixelAt(&surface, 3, 2));
    // More than the layer is cut to it.
    try testing.expect(base(lb).DamageLayer(simple, &.{ .min_x = -5, .min_y = -5, .max_x = 100, .max_y = 100 }));
    try testing.expectEqual(Rect{ .max_x = 8, .max_y = 8 }, damageBounds(lb, simple));
    // An update draws it, and then nothing is owed.
    try testing.expect(base(lb).BeginUpdate(simple));
    fill(lb, simple, graphics.penRGB(0, 0, 255), .{ .max_x = 16, .max_y = 8 });
    base(lb).EndUpdate(simple, true);
    try testing.expectEqual(blue, pixelAt(&surface, 3, 2));
    try testing.expectEqual(@as(u32, 0), owed(lb, simple));

    // The smart one keeps what is covered, so that stays owed too.
    try testing.expect(base(lb).DamageLayer(smart, &.{ .min_x = 2, .min_y = 1, .max_x = 14, .max_y = 6 }));
    try testing.expectEqual(layers.LAYERREFRESH, owed(lb, smart));
    try testing.expectEqual(Rect{ .min_x = 2, .min_y = 1, .max_x = 14, .max_y = 6 }, damageBounds(lb, smart));
    // Nothing of it at all: true, and nothing more owed.
    try testing.expect(base(lb).DamageLayer(smart, &.{ .min_x = 20, .max_x = 30, .max_y = 4 }));
    try testing.expectEqual(Rect{ .min_x = 2, .min_y = 1, .max_x = 14, .max_y = 6 }, damageBounds(lb, smart));

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

/// The rectangle around what a layer is owed, in its own coordinates.
fn damageBounds(lb: *LayersBase, layer: *layers.Layer) Rect {
    var damage: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetDamage, .data = @intFromPtr(&damage) }, .{} };
    base(lb).GetLayerAttrs(layer, &ask);
    var pieces: [8]Rect = undefined;
    const count = gbase(lb).RegionRectangles(@ptrFromInt(damage), &pieces, pieces.len);
    if (count == 0) return .{};
    var bounds = pieces[0];
    for (pieces[1..@min(count, pieces.len)]) |piece| {
        bounds.min_x = @min(bounds.min_x, piece.min_x);
        bounds.min_y = @min(bounds.min_y, piece.min_y);
        bounds.max_x = @max(bounds.max_x, piece.max_x);
        bounds.max_y = @max(bounds.max_y, piece.max_y);
    }
    return bounds;
}

test "layers: a layer moved over one being updated: the update and what follows it draw only where it shows" {
    const lb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 16 * 2]u8 = @splat(0);
    var surface = rtg.Surface{
        .pixels = &pixels,
        .width = 32,
        .height = 16,
        .pitch = 32 * 2,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const screen = try display(lb, &surface);
    const info = base(lb).NewLayerInfo(screen) orelse return error.NoLayerInfo;
    const back_where = Rect{ .min_x = 0, .min_y = 0, .max_x = 20, .max_y = 10 };
    const back_tags = [_]TagItem{ .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&back_where) }, .{} };
    const back = base(lb).CreateLayerTagList(info, &back_tags) orelse return error.NoLayer;
    const front_where = Rect{ .min_x = 12, .min_y = 6, .max_x = 32, .max_y = 16 };
    const front_tags = [_]TagItem{ .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&front_where) }, .{} };
    _ = base(lb).CreateLayerTagList(info, &front_tags) orelse return error.NoLayer;
    fill(lb, back, graphics.penRGB(255, 0, 0), .{ .max_x = 20, .max_y = 10 });

    // Raised, it owes the corner (12..20, 6..10). A third layer in front
    // of everything, clear of it for now.
    try testing.expect(base(lb).UpfrontLayer(back));
    const over_where = Rect{ .min_x = 24, .min_y = 0, .max_x = 32, .max_y = 6 };
    const over_tags = [_]TagItem{ .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&over_where) }, .{} };
    const over = base(lb).CreateLayerTagList(info, &over_tags) orelse return error.NoLayer;

    // Its program begins the update - and before it draws, the third one
    // is moved over part of the corner, to (14..22, 4..10).
    try testing.expect(base(lb).BeginUpdate(back));
    try testing.expect(base(lb).MoveLayer(over, -10, 4));
    fill(lb, back, graphics.penRGB(0, 0, 255), .{ .max_x = 20, .max_y = 10 });
    try testing.expectEqual(blue, pixelAt(&surface, 13, 8)); // owed and still showing
    try testing.expect(pixelAt(&surface, 16, 8) != blue); // owed, but covered now
    try testing.expectEqual(red, pixelAt(&surface, 5, 3)); // never owed
    base(lb).EndUpdate(back, true);

    // After it, the whole layer draws again - where it shows now, not
    // where it showed when the update began.
    fill(lb, back, graphics.penRGB(0, 255, 0), .{ .max_x = 20, .max_y = 10 });
    try testing.expectEqual(green, pixelAt(&surface, 5, 3));
    try testing.expectEqual(green, pixelAt(&surface, 13, 8));
    try testing.expect(pixelAt(&surface, 16, 8) != green);
    try testing.expect(pixelAt(&surface, 18, 5) != green);

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

test "layers: raising one damages what it uncovers, and an update draws only that" {
    const lb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 16 * 2]u8 = @splat(0);
    var surface = rtg.Surface{
        .pixels = &pixels,
        .width = 32,
        .height = 16,
        .pitch = 32 * 2,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const screen = try display(lb, &surface);
    const info = base(lb).NewLayerInfo(screen) orelse return error.NoLayerInfo;
    const back_where = Rect{ .min_x = 0, .min_y = 0, .max_x = 20, .max_y = 10 };
    const back_tags = [_]TagItem{ .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&back_where) }, .{} };
    const back = base(lb).CreateLayerTagList(info, &back_tags) orelse return error.NoLayer;
    const front_where = Rect{ .min_x = 12, .min_y = 6, .max_x = 32, .max_y = 16 };
    const front_tags = [_]TagItem{ .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&front_where) }, .{} };
    _ = base(lb).CreateLayerTagList(info, &front_tags) orelse return error.NoLayer;

    fill(lb, back, graphics.penRGB(255, 0, 0), .{ .max_x = 20, .max_y = 10 });

    // A new layer owes nothing: it was about to draw itself anyway.
    var flags: u32 = 0;
    const ask_flags = [_]TagItem{ .{ .tag = layers.LATAG_GetFlags, .data = @intFromPtr(&flags) }, .{} };
    base(lb).GetLayerAttrs(back, &ask_flags);
    try testing.expectEqual(@as(u32, 0), flags & layers.LAYERREFRESH);
    // An update then is narrowed to nothing: what is drawn in it lands
    // nowhere.
    try testing.expect(base(lb).BeginUpdate(back));
    fill(lb, back, graphics.penRGB(0, 0, 255), .{ .max_x = 20, .max_y = 10 });
    try testing.expectEqual(red, pixelAt(&surface, 5, 3));
    base(lb).EndUpdate(back, true);

    // Raising it uncovers the corner the front one had, and nothing kept
    // those pixels - so the layer is owed a redraw of exactly that.
    try testing.expect(base(lb).UpfrontLayer(back));
    base(lb).GetLayerAttrs(back, &ask_flags);
    try testing.expectEqual(layers.LAYERREFRESH, flags & layers.LAYERREFRESH);

    // Inside an update the layer may draw all of itself and only the
    // damage lands.
    try testing.expect(base(lb).BeginUpdate(back));
    fill(lb, back, graphics.penRGB(0, 0, 255), .{ .max_x = 20, .max_y = 10 });
    try testing.expectEqual(blue, pixelAt(&surface, 15, 8)); // the uncovered corner
    try testing.expectEqual(red, pixelAt(&surface, 5, 3)); // was never damaged
    base(lb).EndUpdate(back, true);

    // Once done, there is nothing owed.
    base(lb).GetLayerAttrs(back, &ask_flags);
    try testing.expectEqual(@as(u32, 0), flags & layers.LAYERREFRESH);

    // And with the update over, the whole layer draws again.
    fill(lb, back, graphics.penRGB(0, 255, 0), .{ .max_x = 20, .max_y = 10 });
    try testing.expectEqual(green, pixelAt(&surface, 5, 3));
    try testing.expectEqual(green, pixelAt(&surface, 15, 8));

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

// --- composed --------------------------------------------------------------

const fake = @import("../rtg_driver/fakeboard/fakeboard.zig");
const compose = @import("compose/_compose.zig");

/// A display that is a board's buffer - the test board's, 32 by 16 - and
/// a LayerInfo over it that composes.
const Composed = struct {
    state: *fake.State,
    board: *rtg.RtgBoard,
    bitmap: *rtg.RtgBitMap,
    screen: *graphics.RastPort,
    info: *layers.LayerInfo,

    fn make(lb: *LayersBase) !Composed {
        const rb = lb.rtg_base;
        const state = fake.create(lb.sys_base) orelse return error.NoDriver;
        if (!rb.AddRtgDriver(&state.driver)) return error.NoDriver;
        const empty = [_]TagItem{.{}};
        const board = rb.CreateBoardTagList(fake.DRIVER_NAME, &empty) orelse return error.NoBoard;
        const bitmap = rb.AllocBitMap(board, 32, 16, @intFromEnum(rtg.bitmaps.PixelFormat.rgb565), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse
            return error.NoBitMap;
        @memset(bitmap.pixels.?[0..bitmap.size_bytes], 0);
        const on_board = [_]TagItem{ .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(bitmap) }, .{} };
        const screen = gbase(lb).CreateRastPortTagList(&on_board) orelse return error.NoRastPort;
        const composed = [_]TagItem{ .{ .tag = layers.LATAG_Compose, .data = 1 }, .{} };
        const info = base(lb).NewLayerInfoTagList(screen, &composed) orelse return error.NoLayerInfo;
        return .{ .state = state, .board = board, .bitmap = bitmap, .screen = screen, .info = info };
    }

    fn done(c: Composed, lb: *LayersBase) void {
        const rb = lb.rtg_base;
        base(lb).DisposeLayerInfo(c.info);
        gbase(lb).FreeRastPort(c.screen);
        rb.FreeBitMap(c.bitmap);
        rb.DeleteBoard(c.board);
        _ = rb.RemRtgDriver(&c.state.driver);
        fake.destroy(c.state);
    }

    fn at(c: Composed, x: u32, y: u32) u16 {
        return pixelAt(@ptrCast(c.bitmap), x, y);
    }
};

test "composed: what is covered is kept, and what is uncovered or moved is copied, never owed" {
    const lb = try setUp();
    defer kexec.deinit();
    const c = try Composed.make(lb);
    const info_of: *info_mod.LayerInfo = @ptrCast(@alignCast(c.info));
    try testing.expectEqual(compose.built, info_of.compose);

    const back_where = Rect{ .max_x = 20, .max_y = 10 };
    const back = try layerAt(lb, c.info, &back_where, layers.LAYERSIMPLE);
    const front_where = Rect{ .min_x = 12, .min_y = 6, .max_x = 32, .max_y = 16 };
    const front = try layerAt(lb, c.info, &front_where, layers.LAYERSIMPLE);

    // Each draws all of itself; what the front one covers lands in the
    // back one's buffer and not on the display.
    fill(lb, back, graphics.penRGB(255, 0, 0), .{ .max_x = 20, .max_y = 10 });
    fill(lb, front, graphics.penRGB(0, 255, 0), .{ .max_x = 20, .max_y = 10 });
    try testing.expectEqual(red, c.at(5, 3));
    try testing.expectEqual(green, c.at(15, 8));
    // Drawn while covered, the back one's blue goes into its buffer only.
    fill(lb, back, graphics.penRGB(0, 0, 255), .{ .min_x = 14, .min_y = 7, .max_x = 20, .max_y = 10 });
    try testing.expectEqual(green, c.at(15, 8));

    // Raised, it is copied out of its buffer: nothing owed, nothing lost.
    try testing.expect(base(lb).UpfrontLayer(back));
    try testing.expectEqual(@as(u32, 0), owed(lb, back));
    try testing.expectEqual(blue, c.at(15, 8));
    try testing.expectEqual(red, c.at(12, 6));
    try testing.expectEqual(green, c.at(25, 12));

    // Lowered again, the front one shows all of itself, owing nothing.
    try testing.expect(base(lb).BehindLayer(back));
    try testing.expectEqual(@as(u32, 0), owed(lb, front));
    try testing.expectEqual(green, c.at(15, 8));

    // Moved, a layer takes its pixels with it - a simple one too - and
    // what it leaves is what is behind it, copied out of that one's buffer.
    try testing.expect(base(lb).MoveLayer(front, -12, -6));
    try testing.expectEqual(@as(u32, 0), owed(lb, front));
    try testing.expectEqual(@as(u32, 0), owed(lb, back));
    try testing.expectEqual(green, c.at(0, 0));
    try testing.expectEqual(green, c.at(19, 9));
    // Where no layer is now, the display is left as it was, as when the
    // layers share it: a screen's ground layer is what covers that.
    try testing.expectEqual(green, c.at(25, 12));
    // Moved back off, the back one's covered blue corner is there.
    try testing.expect(base(lb).MoveLayer(front, 12, 6));
    try testing.expectEqual(red, c.at(5, 3));

    // Taken away, the front one leaves the back one whole.
    base(lb).DeleteLayer(front);
    try testing.expectEqual(blue, c.at(15, 8));
    try testing.expectEqual(red, c.at(12, 6));
    try testing.expectEqual(@as(u32, 0), owed(lb, back));

    base(lb).DeleteLayer(back);
    c.done(lb);
    try tearDown(lb);
}

test "composed: sized, a layer keeps what fits, paints what it gained, and a simple one is owed that" {
    const lb = try setUp();
    defer kexec.deinit();
    const c = try Composed.make(lb);

    const where = Rect{ .min_x = 2, .min_y = 2, .max_x = 10, .max_y = 8 };
    const simple = try layerAt(lb, c.info, &where, layers.LAYERSIMPLE);
    fill(lb, simple, graphics.penRGB(255, 0, 0), .{ .max_x = 8, .max_y = 6 });

    try testing.expect(base(lb).SizeLayer(simple, 4, 2));
    try testing.expectEqual(red, c.at(2, 2));
    try testing.expectEqual(red, c.at(9, 7));
    // The gain is painted in the background pen, 0, and owed.
    try testing.expectEqual(@as(u16, 0), c.at(13, 9));
    try testing.expectEqual(layers.LAYERREFRESH, owed(lb, simple));
    try testing.expect(base(lb).BeginUpdate(simple));
    fill(lb, simple, graphics.penRGB(0, 255, 0), .{ .max_x = 12, .max_y = 8 });
    base(lb).EndUpdate(simple, true);
    try testing.expectEqual(red, c.at(9, 7)); // was not owed
    try testing.expectEqual(green, c.at(13, 9));
    try testing.expectEqual(green, c.at(4, 9));

    // Smaller again, what is left keeps its pixels and nothing is owed.
    try testing.expect(base(lb).SizeLayer(simple, -6, -4));
    try testing.expectEqual(@as(u32, 0), owed(lb, simple));
    try testing.expectEqual(red, c.at(7, 5));

    base(lb).DeleteLayer(simple);
    c.done(lb);
    try tearDown(lb);
}

test "composed: a picture shown in a layer is copied from where it is, and left in the layer when let go" {
    const lb = try setUp();
    defer kexec.deinit();
    const c = try Composed.make(lb);

    const back_where = Rect{ .min_x = 2, .min_y = 2, .max_x = 22, .max_y = 12 };
    const back = try layerAt(lb, c.info, &back_where, layers.LAYERSMART);
    fill(lb, back, graphics.penRGB(255, 0, 0), .{ .max_x = 20, .max_y = 10 });
    var composed: u32 = 0;
    base(lb).GetLayerAttrs(back, &[_]TagItem{ .{ .tag = layers.LATAG_GetComposed, .data = @intFromPtr(&composed) }, .{} });
    try testing.expectEqual(@as(u32, @intFromBool(compose.built)), composed);
    if (!compose.built) {
        base(lb).DeleteLayer(back);
        c.done(lb);
        return tearDown(lb);
    }

    // A green picture, 8 by 4, shown at (4,2) of the layer: on the
    // display from (6,4), the layer red around it.
    var pixels: [8 * 4]u16 = @splat(green);
    const picture = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = 8, .height = 4, .pitch = 8 * 2, .size_bytes = @sizeOf(@TypeOf(pixels)), .format = .rgb565 };
    const area = Rect{ .min_x = 4, .min_y = 2, .max_x = 20, .max_y = 10 };
    try testing.expect(base(lb).ShowLayerPicture(back, &picture, &area));
    try testing.expectEqual(green, c.at(6, 4));
    try testing.expectEqual(green, c.at(13, 7));
    try testing.expectEqual(red, c.at(14, 7));
    try testing.expectEqual(red, c.at(6, 8));
    try testing.expectEqual(red, c.at(5, 4));

    // Drawn under it, the layer stays hidden there; a layer in front
    // covers it, and taken away shows the picture again, never asking.
    fill(lb, back, graphics.penRGB(0, 0, 255), .{ .max_x = 20, .max_y = 10 });
    try testing.expectEqual(green, c.at(8, 5));
    try testing.expectEqual(blue, c.at(5, 4));
    const front_where = Rect{ .min_x = 0, .min_y = 0, .max_x = 10, .max_y = 6 };
    const front = try layerAt(lb, c.info, &front_where, layers.LAYERSIMPLE);
    fill(lb, front, graphics.penRGB(255, 0, 0), .{ .max_x = 10, .max_y = 6 });
    try testing.expectEqual(red, c.at(8, 5));
    base(lb).DeleteLayer(front);
    try testing.expectEqual(green, c.at(8, 5));
    try testing.expectEqual(@as(u32, 0), owed(lb, back));

    // A picture changed under the layer shows when it is shown again.
    @memset(&pixels, blue);
    try testing.expect(base(lb).ShowLayerPicture(back, &picture, &area));
    try testing.expectEqual(blue, c.at(8, 5));

    // Let go of, it is in the layer, and goes with it as it moves.
    @memset(&pixels, green);
    try testing.expect(base(lb).ShowLayerPicture(back, &picture, &area));
    try testing.expect(base(lb).ShowLayerPicture(back, null, null));
    @memset(&pixels, 0);
    try testing.expect(base(lb).MoveLayer(back, 4, 2));
    try testing.expectEqual(green, c.at(10, 6));
    try testing.expectEqual(blue, c.at(9, 6));

    // In another format, it is not shown.
    const other = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = 4, .height = 4, .pitch = 8 * 2, .size_bytes = @sizeOf(@TypeOf(pixels)), .format = .bgra32 };
    try testing.expect(!base(lb).ShowLayerPicture(back, &other, &area));

    base(lb).DeleteLayer(back);
    c.done(lb);
    try tearDown(lb);
}

/// A layer of a composed LayerInfo, with what it looks like.
fn lookingLayer(lb: *LayersBase, info: *layers.LayerInfo, where: *const Rect, corners: usize, shadow: usize, opacity: usize) !*layers.Layer {
    const tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(where) },
        .{ .tag = layers.LATAG_Corners, .data = corners },
        .{ .tag = layers.LATAG_Shadow, .data = shadow },
        .{ .tag = layers.LATAG_Opacity, .data = opacity },
        .{},
    };
    return base(lb).CreateLayerTagList(info, &tags) orelse error.NoLayer;
}

fn setLook(lb: *LayersBase, layer: *layers.Layer, tag: utility.Tag, value: usize) bool {
    const tags = [_]TagItem{ .{ .tag = tag, .data = value }, .{} };
    return base(lb).SetLayerAttrsTagList(layer, &tags);
}

/// An RGB565 pixel's red, green and blue, eight bits each.
fn channels(pixel: u16) [3]u32 {
    const r: u32 = pixel >> 11;
    const g: u32 = pixel >> 5 & 0x3F;
    const b: u32 = pixel & 0x1F;
    return .{ r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2 };
}

test "cornerCut: a corner of six is cut 4, 2, 1, 1 deep, and none past it" {
    const want = [_]u32{ 4, 2, 1, 1, 0, 0, 0 };
    for (want, 0..) |cut, row| try testing.expectEqual(cut, layers.cornerCut(6, @intCast(row)));
    try testing.expectEqual(@as(u32, 0), layers.cornerCut(0, 0));
    try testing.expectEqual(@as(u32, 0), layers.cornerCut(1, 0));
    try testing.expectEqual(@as(u32, 3), layers.cornerRadius(6, 20, 6));
}

test "composed: round corners show what is behind, and a point there is the layer's behind" {
    const lb = try setUp();
    defer kexec.deinit();
    const c = try Composed.make(lb);
    if (!compose.built) {
        c.done(lb);
        return tearDown(lb);
    }
    const all = Rect{ .max_x = 32, .max_y = 16 };
    const back = try layerAt(lb, c.info, &all, layers.LAYERSIMPLE);
    fill(lb, back, graphics.penRGB(255, 0, 0), all);
    const front_where = Rect{ .min_x = 4, .min_y = 2, .max_x = 28, .max_y = 14 };
    const front = try lookingLayer(lb, c.info, &front_where, 6, 0, 255);
    fill(lb, front, graphics.penRGB(0, 255, 0), .{ .max_x = 24, .max_y = 12 });

    // Row 0 of each corner loses four pixels, row 1 two, rows 2 and 3 one.
    try testing.expectEqual(red, c.at(4, 2));
    try testing.expectEqual(red, c.at(7, 2));
    try testing.expectEqual(green, c.at(8, 2));
    try testing.expectEqual(red, c.at(5, 3));
    try testing.expectEqual(green, c.at(6, 3));
    try testing.expectEqual(red, c.at(4, 5));
    try testing.expectEqual(green, c.at(4, 6));
    try testing.expectEqual(red, c.at(27, 13));
    try testing.expectEqual(green, c.at(23, 13));
    try testing.expect(base(lb).WhichLayer(c.info, 4, 2) == back);
    try testing.expect(base(lb).WhichLayer(c.info, 8, 2) == front);

    // Drawn into the back one there, it shows; moved, the corners go with
    // the layer; squared, they are the layer's again.
    fill(lb, back, graphics.penRGB(0, 0, 255), all);
    try testing.expectEqual(blue, c.at(4, 2));
    try testing.expectEqual(green, c.at(8, 2));
    try testing.expect(base(lb).MoveLayer(front, 2, 1));
    try testing.expectEqual(blue, c.at(6, 3));
    try testing.expectEqual(green, c.at(10, 3));
    try testing.expectEqual(blue, c.at(4, 6));
    try testing.expect(setLook(lb, front, layers.LATAG_Corners, 0));
    try testing.expectEqual(green, c.at(6, 3));

    base(lb).DeleteLayer(front);
    base(lb).DeleteLayer(back);
    c.done(lb);
    try tearDown(lb);
}

test "composed: a shadow darkens what is behind, once, and goes with the layer" {
    const lb = try setUp();
    defer kexec.deinit();
    const c = try Composed.make(lb);
    if (!compose.built) {
        c.done(lb);
        return tearDown(lb);
    }
    const white: u16 = 0xFFFF;
    const all = Rect{ .max_x = 32, .max_y = 16 };
    const back = try layerAt(lb, c.info, &all, layers.LAYERSIMPLE);
    fill(lb, back, graphics.penRGB(255, 255, 255), all);
    const front_where = Rect{ .min_x = 8, .min_y = 2, .max_x = 20, .max_y = 8 };
    const front = try lookingLayer(lb, c.info, &front_where, 0, 3, 255);
    fill(lb, front, graphics.penRGB(0, 255, 0), .{ .max_x = 12, .max_y = 6 });

    // Just below the layer it is darker than further out, and nothing out
    // of its reach is touched; the layer itself is not darkened.
    const near = channels(c.at(14, 8))[0];
    const far = channels(c.at(14, 10))[0];
    try testing.expect(near < 255);
    try testing.expect(near < far);
    try testing.expectEqual(white, c.at(0, 15));
    try testing.expectEqual(white, c.at(30, 1));
    try testing.expectEqual(green, c.at(8, 2));

    // Shown again, it is the same: darkened once, not twice.
    try testing.expect(setLook(lb, front, layers.LATAG_Shadow, 3));
    try testing.expectEqual(near, channels(c.at(14, 8))[0]);
    // Drawn into behind it, the shadow is on what was drawn.
    fill(lb, back, graphics.penRGB(255, 255, 255), all);
    try testing.expectEqual(near, channels(c.at(14, 8))[0]);
    try testing.expectEqual(white, c.at(0, 15));

    // Moved, it leaves white behind and darkens where it goes.
    try testing.expect(base(lb).MoveLayer(front, 0, 6));
    try testing.expectEqual(white, c.at(14, 3));
    try testing.expectEqual(white, c.at(7, 4));
    try testing.expectEqual(near, channels(c.at(14, 14))[0]);
    // Taken off, it leaves no shadow.
    try testing.expect(setLook(lb, front, layers.LATAG_Shadow, 0));
    try testing.expectEqual(white, c.at(14, 14));

    base(lb).DeleteLayer(front);
    base(lb).DeleteLayer(back);
    c.done(lb);
    try tearDown(lb);
}

test "composed: drawn under a shadow, it is darkened again in a call for each part of the shadow, not for each row" {
    const lb = try setUp();
    defer kexec.deinit();
    const c = try Composed.make(lb);
    if (!compose.built) {
        c.done(lb);
        return tearDown(lb);
    }
    const all = Rect{ .max_x = 32, .max_y = 16 };
    const back = try layerAt(lb, c.info, &all, layers.LAYERSIMPLE);
    const front_where = Rect{ .min_x = 8, .min_y = 2, .max_x = 20, .max_y = 8 };
    const front = try lookingLayer(lb, c.info, &front_where, 0, 3, 255);
    fill(lb, back, graphics.penRGB(255, 255, 255), all);
    const near = channels(c.at(14, 8))[0];
    try testing.expect(near < 255);

    // The shadow reaches from 5,0 to 23,12. What of it the back one shows
    // is above the front one - two corners and the top between them -
    // beside it, two corners a side, and below it - two corners and the
    // bottom: ten parts, each laid in one call.
    const log = &c.state.log;
    const blends = log.blends;
    const rects = log.blend_rects;
    fill(lb, back, graphics.penRGB(255, 255, 255), all);
    try testing.expectEqual(@as(u32, 10), log.blends - blends);
    try testing.expectEqual(@as(u32, 0), log.blend_rects - rects);
    try testing.expectEqual(near, channels(c.at(14, 8))[0]);
    // The bottom is darker nearer the layer.
    try testing.expect(channels(c.at(14, 8))[0] < channels(c.at(14, 11))[0]);

    base(lb).DeleteLayer(front);
    base(lb).DeleteLayer(back);
    c.done(lb);
    try tearDown(lb);
}

test "composed: a layer seen through is laid over what is behind, and a ghost is not pointed at" {
    const lb = try setUp();
    defer kexec.deinit();
    const c = try Composed.make(lb);
    if (!compose.built) {
        c.done(lb);
        return tearDown(lb);
    }
    const all = Rect{ .max_x = 32, .max_y = 16 };
    const back = try layerAt(lb, c.info, &all, layers.LAYERSIMPLE);
    fill(lb, back, graphics.penRGB(255, 0, 0), all);
    const front_where = Rect{ .min_x = 8, .min_y = 4, .max_x = 24, .max_y = 12 };
    const front = try lookingLayer(lb, c.info, &front_where, 0, 0, 0);

    // Unseen, then drawn: still unseen until it is shown again.
    fill(lb, front, graphics.penRGB(0, 255, 0), .{ .max_x = 16, .max_y = 8 });
    try testing.expectEqual(red, c.at(10, 6));
    try testing.expect(base(lb).WhichLayer(c.info, 10, 6) == front);

    // Half way: half of each.
    try testing.expect(setLook(lb, front, layers.LATAG_Opacity, 128));
    const half = channels(c.at(10, 6));
    try testing.expect(half[0] > 96 and half[0] < 160);
    try testing.expect(half[1] > 96 and half[1] < 160);
    // Drawn into behind it, that waits for the next step, and outside
    // it shows at once.
    fill(lb, back, graphics.penRGB(0, 0, 255), all);
    try testing.expectEqual(blue, c.at(2, 2));
    try testing.expectEqual(half, channels(c.at(10, 6)));
    try testing.expect(setLook(lb, front, layers.LATAG_Opacity, 128));
    const over_blue = channels(c.at(10, 6));
    try testing.expect(over_blue[0] < 32 and over_blue[2] > 96);

    // All the way, it is itself, and covers.
    try testing.expect(setLook(lb, front, layers.LATAG_Opacity, 255));
    try testing.expectEqual(green, c.at(10, 6));
    fill(lb, front, graphics.penRGB(255, 255, 255), .{ .max_x = 16, .max_y = 8 });
    try testing.expectEqual(@as(u16, 0xFFFF), c.at(10, 6));

    // A ghost is seen, and a point on it is the layer's behind.
    try testing.expect(setLook(lb, front, layers.LATAG_Ghost, 1));
    try testing.expect(base(lb).WhichLayer(c.info, 10, 6) == back);
    var in_front: usize = 1;
    base(lb).GetLayerAttrs(back, &[_]TagItem{ .{ .tag = layers.LATAG_GetInFront, .data = @intFromPtr(&in_front) }, .{} });
    try testing.expectEqual(@as(usize, 0), in_front);
    try testing.expectEqual(@as(u16, 0xFFFF), c.at(10, 6));

    // Not composed, there is nothing to set.
    base(lb).DeleteLayer(front);
    try testing.expectEqual(blue, c.at(10, 6));
    base(lb).DeleteLayer(back);
    c.done(lb);
    try tearDown(lb);
}

test "composed: a layer with its own bitmap draws in it, and scrolling only moves what is copied" {
    const lb = try setUp();
    defer kexec.deinit();
    const c = try Composed.make(lb);

    const bm_tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = 16 },
        .{ .tag = graphics.BMTAG_Height, .data = 8 },
        .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(rtg.bitmaps.PixelFormat.rgb565) },
        .{ .tag = graphics.BMTAG_Clear, .data = 1 },
        .{},
    };
    const sheet = gbase(lb).AllocBitMapTagList(&bm_tags) orelse return error.NoBitMap;
    const where = Rect{ .min_x = 4, .min_y = 4, .max_x = 12, .max_y = 12 };
    const tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&where) },
        .{ .tag = layers.LATAG_Refresh, .data = layers.LAYERSUPER },
        .{ .tag = layers.LATAG_SuperBitMap, .data = @intFromPtr(sheet) },
        .{},
    };
    const layer = base(lb).CreateLayerTagList(c.info, &tags) orelse return error.NoLayer;

    fill(lb, layer, graphics.penRGB(255, 0, 0), .{ .max_x = 8, .max_y = 8 });
    fill(lb, layer, graphics.penRGB(0, 255, 0), .{ .min_x = 8, .max_x = 16, .max_y = 8 });
    // The bitmap has all of it, the shown half and the other.
    try testing.expectEqual(red, pixelAt(sheet, 0, 0));
    try testing.expectEqual(green, pixelAt(sheet, 15, 7));
    try testing.expectEqual(red, c.at(4, 4));
    try testing.expectEqual(@as(u16, 0), c.at(12, 4));

    try testing.expect(base(lb).ScrollLayer(layer, 8, 0));
    try testing.expectEqual(green, c.at(4, 4));
    try testing.expectEqual(green, c.at(11, 11));
    try testing.expect(base(lb).ScrollLayer(layer, -8, 0));
    try testing.expectEqual(red, c.at(11, 11));

    base(lb).DeleteLayer(layer);
    gbase(lb).FreeBitMap(sheet);
    c.done(lb);
    try tearDown(lb);
}

test "composed: a drawing is copied as one job and handed on to the board once, in however many pieces it is seen" {
    const lb = try setUp();
    defer kexec.deinit();
    const c = try Composed.make(lb);
    if (!compose.built) {
        c.done(lb);
        return tearDown(lb);
    }
    const all = Rect{ .max_x = 32, .max_y = 16 };
    const back = try layerAt(lb, c.info, &all, layers.LAYERSIMPLE);
    const log = &c.state.log;

    // Round corners make a layer a stack of rows of pieces.
    const round = try lookingLayer(lb, c.info, &all, 6, 0, 255);
    var before = log.refreshed;
    var jobs = log.copy_jobs;
    var copies = log.copies;
    fill(lb, round, graphics.penRGB(255, 0, 0), all);
    try testing.expectEqual(@as(u32, 1), log.refreshed - before);
    try testing.expectEqual(red, c.at(16, 8));
    // Its pieces were copied together, the engine asked once.
    try testing.expectEqual(@as(u32, 1), log.copy_jobs - jobs);
    try testing.expect(log.copies - copies > 4);
    base(lb).DeleteLayer(round);

    // A layer in the middle, with a shadow, leaves the back one a frame
    // of four pieces, some of them darkened.
    const middle_where = Rect{ .min_x = 8, .min_y = 4, .max_x = 20, .max_y = 10 };
    const middle = try lookingLayer(lb, c.info, &middle_where, 0, 3, 255);
    before = log.refreshed;
    jobs = log.copy_jobs;
    copies = log.copies;
    fill(lb, back, graphics.penRGB(0, 0, 255), all);
    try testing.expectEqual(@as(u32, 1), log.refreshed - before);
    try testing.expectEqual(blue, c.at(0, 0));
    try testing.expectEqual(blue, c.at(31, 15));
    try testing.expectEqual(@as(u32, 1), log.copy_jobs - jobs);
    try testing.expectEqual(@as(u32, 4), log.copies - copies);
    base(lb).DeleteLayer(middle);

    // Two strips far apart are two, not the whole display between them.
    const wide_where = Rect{ .min_x = 2, .max_x = 30, .max_y = 16 };
    const wide = try layerAt(lb, c.info, &wide_where, layers.LAYERSIMPLE);
    before = log.refreshed;
    fill(lb, back, graphics.penRGB(0, 255, 0), all);
    try testing.expectEqual(@as(u32, 2), log.refreshed - before);
    try testing.expectEqual(green, c.at(0, 8));
    try testing.expectEqual(green, c.at(31, 8));
    base(lb).DeleteLayer(wide);

    base(lb).DeleteLayer(back);
    c.done(lb);
    try tearDown(lb);
}

test "composed: asked for on plain memory, the layers share the display as without it" {
    const lb = try setUp();
    defer kexec.deinit();
    var pixels: [32 * 16 * 2]u8 = @splat(0);
    var surface = rtg.Surface{ .pixels = &pixels, .width = 32, .height = 16, .pitch = 32 * 2, .size_bytes = pixels.len, .format = .rgb565 };
    const screen = try display(lb, &surface);
    const composed = [_]TagItem{ .{ .tag = layers.LATAG_Compose, .data = 1 }, .{} };
    const info = base(lb).NewLayerInfoTagList(screen, &composed) orelse return error.NoLayerInfo;
    const info_of: *info_mod.LayerInfo = @ptrCast(@alignCast(info));
    try testing.expect(!info_of.compose);

    const where = Rect{ .max_x = 8, .max_y = 8 };
    const layer = try layerAt(lb, info, &where, layers.LAYERSIMPLE);
    fill(lb, layer, graphics.penRGB(255, 0, 0), .{ .max_x = 8, .max_y = 8 });
    try testing.expectEqual(red, pixelAt(&surface, 3, 3));

    base(lb).DeleteLayer(layer);
    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}

test "composed: moved, sized and reordered at random, every pixel is the front layer's, and nothing is owed but what a size gains" {
    const lb = try setUp();
    defer kexec.deinit();
    const c = try Composed.make(lb);

    const pictures = [_]Painted{
        .{ .top = .{ 255, 0, 0 }, .bottom = .{ 0, 255, 0 } },
        .{ .top = .{ 0, 0, 255 }, .bottom = .{ 255, 255, 0 } },
        .{ .top = .{ 255, 0, 255 }, .bottom = .{ 0, 255, 255 } },
        .{ .top = .{ 255, 255, 255 }, .bottom = .{ 0, 0, 0 } },
    };
    const modes = [_]usize{ layers.LAYERSMART, layers.LAYERSIMPLE, layers.LAYERSMART, layers.LAYERSIMPLE };
    var made: [4]*layers.Layer = undefined;
    var where: [4]Rect = undefined;
    var order: [4]usize = undefined;
    for (0..4) |i| {
        where[i] = .{ .min_x = @intCast(i * 5), .min_y = @intCast(i * 2), .max_x = @intCast(i * 5 + 12), .max_y = @intCast(i * 2 + 8) };
        made[i] = try layerAt(lb, c.info, &where[i], modes[i]);
        pictures[i].paint(lb, made[i], 12, 8);
        order[3 - i] = i;
    }

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    var step: u32 = 0;
    while (step < 1000) : (step += 1) {
        const i = rand.uintLessThan(usize, 4);
        const w = where[i].width();
        const h = where[i].height();
        const op = rand.uintLessThan(u32, 4);
        switch (op) {
            0 => {
                // Off the display too: a composed layer has all of itself.
                const dx = rand.intRangeAtMost(i32, -where[i].min_x - 4, 36 - where[i].max_x);
                const dy = rand.intRangeAtMost(i32, -where[i].min_y - 4, 20 - where[i].max_y);
                try testing.expect(base(lb).MoveLayer(made[i], dx, dy));
                where[i] = .{ .min_x = where[i].min_x + dx, .min_y = where[i].min_y + dy, .max_x = where[i].max_x + dx, .max_y = where[i].max_y + dy };
            },
            1 => {
                const nw = rand.intRangeAtMost(i32, 4, 16);
                const nh = rand.intRangeAtMost(i32, 4, 12);
                try testing.expect(base(lb).SizeLayer(made[i], nw - w, nh - h));
                where[i].max_x = where[i].min_x + nw;
                where[i].max_y = where[i].min_y + nh;
                // The program draws its picture again for the new size, as
                // NEWSIZE has it do; a simple one through the update.
                if (owed(lb, made[i]) != 0 and base(lb).BeginUpdate(made[i])) base(lb).EndUpdate(made[i], true);
                pictures[i].paint(lb, made[i], nw, nh);
            },
            2 => {
                try testing.expect(base(lb).UpfrontLayer(made[i]));
                var k: usize = 0;
                while (order[k] != i) k += 1;
                while (k > 0) : (k -= 1) order[k] = order[k - 1];
                order[0] = i;
            },
            else => {
                try testing.expect(base(lb).BehindLayer(made[i]));
                var k: usize = 0;
                while (order[k] != i) k += 1;
                while (k < 3) : (k += 1) order[k] = order[k + 1];
                order[3] = i;
            },
        }
        for (0..4) |j| try testing.expectEqual(@as(u32, 0), owed(lb, made[j]));
        var y: i32 = 0;
        while (y < 16) : (y += 1) {
            var x: i32 = 0;
            while (x < 32) : (x += 1) {
                for (order) |j| {
                    const r = where[j];
                    if (x < r.min_x or x >= r.max_x or y < r.min_y or y >= r.max_y) continue;
                    const want = pictures[j].at(y - r.min_y, r.height());
                    const have = c.at(@intCast(x), @intCast(y));
                    if (want != have) {
                        std.debug.print("step {d}: pixel {d},{d} is {x:0>4}, layer {d} wants {x:0>4}\n", .{ step, x, y, have, j, want });
                        return error.TestUnexpectedResult;
                    }
                    break;
                }
            }
        }
    }

    for (made) |l| base(lb).DeleteLayer(l);
    c.done(lb);
    try tearDown(lb);
}

/// A ground that is not one colour: each row of the display its own, so a
/// piece painted in the wrong place, or not painted again, shows.
fn rowsBackFill(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const gb: *GraphicsBase = @ptrCast(@alignCast(hook.data.?));
    const rp: *graphics.RastPort = @ptrCast(@alignCast(object.?));
    const msg: *layers.BackFillMsg = @ptrCast(@alignCast(message.?));
    var y = msg.area.min_y;
    while (y < msg.area.max_y) : (y += 1) {
        const v: u8 = @intCast(@mod(y * 16, 256));
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(v, 255 - v, 128) }, .{} });
        gb.RectFill(rp, &.{ .min_x = msg.area.min_x, .min_y = y, .max_x = msg.area.max_x, .max_y = y + 1 });
    }
    return 0;
}

/// What `rowsBackFill` paints row `y` of the display in.
fn rowColour(y: i32) u16 {
    const v: u32 = @intCast(@mod(y * 16, 256));
    return rgb565(v, 255 - v, 128);
}

/// A screen's ground: the whole display at the back, painted by `hook`,
/// with or without a buffer of its own.
fn groundLayer(lb: *LayersBase, info: *layers.LayerInfo, hook: *utility.Hook, buffer: bool) !*layers.Layer {
    const all = Rect{ .max_x = 32, .max_y = 16 };
    const tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&all) },
        .{ .tag = layers.LATAG_Backdrop, .data = 1 },
        .{ .tag = layers.LATAG_BackFill, .data = @intFromPtr(hook) },
        .{ .tag = layers.LATAG_NoBuffer, .data = @intFromBool(!buffer) },
        .{},
    };
    return base(lb).CreateLayerTagList(info, &tags) orelse error.NoLayer;
}

test "composed: a layer with no buffer is its backfill, painted wherever it is seen, and darkened once" {
    const lb = try setUp();
    defer kexec.deinit();
    const c = try Composed.make(lb);
    if (!compose.built) {
        c.done(lb);
        return tearDown(lb);
    }
    var rows = utility.Hook{ .entry = &rowsBackFill, .data = gbase(lb) };
    const ground = try groundLayer(lb, c.info, &rows, false);
    const inside: *info_mod.Layer = @ptrCast(@alignCast(ground));
    try testing.expect(inside.own == null);
    try testing.expect(inside.through != null);
    for (0..16) |y| for (0..32) |x| try testing.expectEqual(rowColour(@intCast(y)), c.at(@intCast(x), @intCast(y)));

    // Drawn into, it lands nowhere: the ground is its hook.
    fill(lb, ground, graphics.penRGB(255, 0, 0), .{ .max_x = 32, .max_y = 16 });
    try testing.expectEqual(rowColour(5), c.at(5, 5));

    // A window with a shadow over it darkens it, once.
    const where = Rect{ .min_x = 8, .min_y = 2, .max_x = 20, .max_y = 8 };
    const front = try lookingLayer(lb, c.info, &where, 0, 3, 255);
    fill(lb, front, graphics.penRGB(0, 255, 0), .{ .max_x = 12, .max_y = 6 });
    try testing.expectEqual(green, c.at(8, 2));
    const near = c.at(14, 8);
    try testing.expect(channels(near)[1] < channels(rowColour(8))[1]);
    try testing.expectEqual(rowColour(15), c.at(0, 15));
    try testing.expect(setLook(lb, front, layers.LATAG_Shadow, 3));
    try testing.expectEqual(near, c.at(14, 8));

    // Moved away, what it covered and darkened is painted again.
    try testing.expect(base(lb).MoveLayer(front, 0, 6));
    try testing.expectEqual(rowColour(3), c.at(14, 3));
    try testing.expectEqual(rowColour(4), c.at(7, 4));
    try testing.expectEqual(green, c.at(8, 8));

    // A new hook shows it again at once, the window and its shadow over it
    // as before.
    var blue_hook = utility.Hook{ .entry = &blueBackFill, .data = gbase(lb) };
    try testing.expectEqual(@intFromPtr(&rows), base(lb).InstallLayerHook(ground, @intFromPtr(&blue_hook)));
    try testing.expectEqual(blue, c.at(0, 0));
    try testing.expectEqual(green, c.at(8, 8));
    try testing.expect(channels(c.at(14, 14))[2] < 255);
    try testing.expectEqual(blue, c.at(0, 15));
    // It cannot show nothing: asked to, it is its background pen.
    try testing.expectEqual(@intFromPtr(&blue_hook), base(lb).InstallLayerHook(ground, layers.LAYERS_NOBACKFILL));
    try testing.expectEqual(@as(u16, 0), c.at(0, 0));
    try testing.expectEqual(@as(usize, 0), base(lb).InstallLayerHook(ground, @intFromPtr(&blue_hook)));

    // Taken away, the window leaves the ground whole.
    base(lb).DeleteLayer(front);
    for (0..16) |y| for (0..32) |x| try testing.expectEqual(blue, c.at(@intCast(x), @intCast(y)));

    base(lb).DeleteLayer(ground);
    c.done(lb);
    try tearDown(lb);
}

/// A second display on a `Composed`'s board, its layers composed too.
const Twin = struct {
    bitmap: *rtg.RtgBitMap,
    screen: *graphics.RastPort,
    info: *layers.LayerInfo,

    fn make(lb: *LayersBase, c: Composed) !Twin {
        const rb = lb.rtg_base;
        const bitmap = rb.AllocBitMap(c.board, 32, 16, @intFromEnum(rtg.bitmaps.PixelFormat.rgb565), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse
            return error.NoBitMap;
        @memset(bitmap.pixels.?[0..bitmap.size_bytes], 0);
        const on_board = [_]TagItem{ .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(bitmap) }, .{} };
        const screen = gbase(lb).CreateRastPortTagList(&on_board) orelse return error.NoRastPort;
        const composed = [_]TagItem{ .{ .tag = layers.LATAG_Compose, .data = 1 }, .{} };
        const info = base(lb).NewLayerInfoTagList(screen, &composed) orelse return error.NoLayerInfo;
        return .{ .bitmap = bitmap, .screen = screen, .info = info };
    }

    fn done(t: Twin, lb: *LayersBase) void {
        base(lb).DisposeLayerInfo(t.info);
        gbase(lb).FreeRastPort(t.screen);
        lb.rtg_base.FreeBitMap(t.bitmap);
    }

    fn at(t: Twin, x: u32, y: u32) u16 {
        return pixelAt(@ptrCast(t.bitmap), x, y);
    }
};

test "composed: a ground with no buffer looks as one with a buffer does, whatever moves over it" {
    const lb = try setUp();
    defer kexec.deinit();
    const c = try Composed.make(lb);
    if (!compose.built) {
        c.done(lb);
        return tearDown(lb);
    }
    const t = try Twin.make(lb, c);
    var rows = utility.Hook{ .entry = &rowsBackFill, .data = gbase(lb) };
    // The same scene twice: on `c` the ground has no buffer, on `t` it has.
    const bare = try groundLayer(lb, c.info, &rows, false);
    const kept = try groundLayer(lb, t.info, &rows, true);
    try testing.expect(@as(*info_mod.Layer, @ptrCast(@alignCast(kept))).own != null);

    const pictures = [_]Painted{
        .{ .top = .{ 255, 0, 0 }, .bottom = .{ 0, 255, 0 } },
        .{ .top = .{ 0, 0, 255 }, .bottom = .{ 255, 255, 0 } },
        .{ .top = .{ 255, 255, 255 }, .bottom = .{ 0, 0, 0 } },
    };
    var on_c: [3]*layers.Layer = undefined;
    var on_t: [3]*layers.Layer = undefined;
    var where: [3]Rect = undefined;
    for (0..3) |i| {
        where[i] = .{ .min_x = @intCast(i * 7), .min_y = @intCast(i * 3), .max_x = @intCast(i * 7 + 12), .max_y = @intCast(i * 3 + 8) };
        // Shadows of one size: a shadow's picture is kept for each size,
        // and the test's memory is small.
        on_c[i] = try lookingLayer(lb, c.info, &where[i], i, 2, 255);
        on_t[i] = try lookingLayer(lb, t.info, &where[i], i, 2, 255);
        pictures[i].paint(lb, on_c[i], 12, 8);
        pictures[i].paint(lb, on_t[i], 12, 8);
    }

    var prng = std.Random.DefaultPrng.init(0x6A0D);
    const rand = prng.random();
    var step: u32 = 0;
    while (step < 400) : (step += 1) {
        const i = rand.uintLessThan(usize, 3);
        const op = rand.uintLessThan(u32, 7);
        // One step, the same on both displays.
        const dx = rand.intRangeAtMost(i32, -where[i].min_x - 4, 36 - where[i].max_x);
        const dy = rand.intRangeAtMost(i32, -where[i].min_y - 4, 20 - where[i].max_y);
        const nw = rand.intRangeAtMost(i32, 6, 16);
        const nh = rand.intRangeAtMost(i32, 4, 12);
        const value: usize = rand.uintAtMost(u8, 255);
        for ([_]*[3]*layers.Layer{ &on_c, &on_t }) |made| {
            const layer = made[i];
            switch (op) {
                0 => try testing.expect(base(lb).MoveLayer(layer, dx, dy)),
                1 => {
                    try testing.expect(base(lb).SizeLayer(layer, nw - where[i].width(), nh - where[i].height()));
                    if (owed(lb, layer) != 0 and base(lb).BeginUpdate(layer)) base(lb).EndUpdate(layer, true);
                    pictures[i].paint(lb, layer, nw, nh);
                },
                2 => try testing.expect(base(lb).UpfrontLayer(layer)),
                3 => try testing.expect(base(lb).BehindLayer(layer)),
                4 => try testing.expect(setLook(lb, layer, layers.LATAG_Opacity, if (value < 128) value else 255)),
                5 => try testing.expect(setLook(lb, layer, layers.LATAG_Shadow, value % 2 * 2)),
                else => try testing.expect(setLook(lb, layer, layers.LATAG_Corners, value % 5)),
            }
        }
        switch (op) {
            0 => where[i] = .{ .min_x = where[i].min_x + dx, .min_y = where[i].min_y + dy, .max_x = where[i].max_x + dx, .max_y = where[i].max_y + dy },
            1 => {
                where[i].max_x = where[i].min_x + nw;
                where[i].max_y = where[i].min_y + nh;
            },
            else => {},
        }
        // Both as asked: nothing went without for want of memory.
        for (on_c, on_t) |one, other| {
            const a: *info_mod.Layer = @ptrCast(@alignCast(one));
            const b: *info_mod.Layer = @ptrCast(@alignCast(other));
            try testing.expectEqual(a.shadow, b.shadow);
            try testing.expectEqual(a.opacity, b.opacity);
        }
        for (0..16) |y| for (0..32) |x| {
            const want = t.at(@intCast(x), @intCast(y));
            const have = c.at(@intCast(x), @intCast(y));
            if (want != have) {
                std.debug.print("step {d}, op {d}: pixel {d},{d} is {x:0>4} without a buffer, {x:0>4} with\n", .{ step, op, x, y, have, want });
                return error.TestUnexpectedResult;
            }
        };
    }

    for (on_c) |l| base(lb).DeleteLayer(l);
    for (on_t) |l| base(lb).DeleteLayer(l);
    base(lb).DeleteLayer(bare);
    base(lb).DeleteLayer(kept);
    t.done(lb);
    c.done(lb);
    try tearDown(lb);
}
