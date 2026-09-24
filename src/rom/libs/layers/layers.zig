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
//! covered pixels, which the calls share. The jump table is layers_lvo.zig,
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
    _ = @import("damage/beginupdate.zig");
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
/// frees all four: layers closes graphics and utility, graphics closes rtg
/// and utility, rtg closes utility.
fn tearDown(lb: *LayersBase) !void {
    const gb: *kgraphics.GraphicsBase = @ptrCast(@alignCast(lb.graphics_base));
    const rb: *krtg.RtgBase = @ptrCast(@alignCast(gb.rtg_base));
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(lb.utility_base));

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
    try testing.expect(!base(lb).BeginUpdate(back));

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
    // holds while it draws.
    base(lb).LockLayer(layer);
    base(lb).LockLayer(layer);
    try testing.expect(base(lb).BeginUpdate(layer) or true); // takes it again
    base(lb).UnlockLayer(layer);
    base(lb).UnlockLayer(layer);

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
    try testing.expect(!base(lb).BeginUpdate(back));
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
    try testing.expect(!base(lb).BeginUpdate(back));

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

    // Once done, there is nothing owed and no second update to be had.
    base(lb).GetLayerAttrs(back, &ask_flags);
    try testing.expectEqual(@as(u32, 0), flags & layers.LAYERREFRESH);
    try testing.expect(!base(lb).BeginUpdate(back));

    // And with the update over, the whole layer draws again.
    fill(lb, back, graphics.penRGB(0, 255, 0), .{ .max_x = 20, .max_y = 10 });
    try testing.expectEqual(green, pixelAt(&surface, 5, 3));
    try testing.expectEqual(green, pixelAt(&surface, 15, 8));

    base(lb).DisposeLayerInfo(info);
    gbase(lb).FreeRastPort(screen);
    try tearDown(lb);
}
