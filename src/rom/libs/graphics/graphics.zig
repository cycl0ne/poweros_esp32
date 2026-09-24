// SPDX-License-Identifier: MPL-2.0
//! graphics.library: the layer that draws.
//!
//! It has the display and the RastPort, and no drawing call yet. A caller
//! opens it and asks for a RastPort; with no tags it gets one on the
//! display, and it never touches rtg.library to do so, because this
//! library opens rtg itself.
//!
//! What it will draw into is rtg.library's: a board's display memory,
//! handed out as `RtgBitMap`s and put on the glass with RefreshBitMap.
//! rtg.library deliberately holds no drawing at all - a board offers what
//! its own engine can do and answers RTGERR_NOT_SUPPORTED for the rest -
//! and this is the layer that knows how, in software, when the board does
//! not.
//!
//! Each call is a file of its own in the folder for its category -
//! rastport/, draw/, bitmap/, blit/, text/, area/, region/ and errors/ -
//! and rows/ holds the row moves and fills they all come down to; the ROM
//! fonts are fonts/. The jump table is graphics_lvo.zig, the ROM tag and
//! init graphics_init.zig, the base graphics_base.zig. This file holds the
//! names the rest of the kernel reaches the library by, and the tests of
//! calls working together. Its functions are `sdk/fd/graphics_lib.fd` and
//! its types `sdk/libs/graphics/`.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;

/// graphics.library's base (graphics_base.zig).
const graphics_base = @import("graphics_base.zig");
/// graphics.library's ROM tag and init routine (graphics_init.zig).
const graphics_init = @import("graphics_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from graphics.library.
comptime {
    _ = &graphics_init.graphics_library_tag;
}

/// The library's base, for the modules that keep a pointer to it.
pub const GraphicsBase = graphics_base.GraphicsBase;
/// What the library is on exec's list as.
pub const LIBRARY_NAME = graphics_init.LIBRARY_NAME;
/// The ROM tag, for the host tests that make the library from it.
pub const graphics_library_tag = graphics_init.graphics_library_tag;

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
/// The library's interface as the SDK has it, for the tests' calls.
const interface = sdk.interface.graphics;
const rastport = @import("rastport/_rastport.zig");
const fonts = @import("text/_text.zig");
const regions = @import("region/_region.zig");
const LIBRARY_VERSION = graphics_init.LIBRARY_VERSION;
const LIBRARY_REVISION = graphics_init.LIBRARY_REVISION;

/// The kernel's exec, and the two libraries this one opens, to stand the
/// whole stack up around it.
const kexec = @import("../exec/exec.zig");
const kutility = @import("../utility/utility.zig");
const krtg = @import("../rtg/rtg.zig");
const fake = @import("../rtg_driver/fakeboard/fakeboard.zig");

/// exec on its test RAM, then utility, rtg and graphics from their tags -
/// the cold-start order, which is the order the init needs them in.
fn setUp() !*GraphicsBase {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    _ = kexec.InitResident(kexec.SysBase, &krtg.rtg_library_tag, null) orelse return error.NoRtg;
    const made = kexec.InitResident(kexec.SysBase, &graphics_library_tag, null) orelse return error.NoGraphics;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

/// The library through the SDK's interface, the way a caller reaches it.
fn base(gb: *GraphicsBase) *interface.GraphicsBase {
    return @ptrCast(gb);
}

fn kernelRtg(gb: *GraphicsBase) *krtg.RtgBase {
    return @ptrCast(@alignCast(gb.rtg_base));
}

/// No library here expunges itself, so the test gives back every open and
/// frees all three: graphics closes rtg and utility, rtg closes utility.
fn tearDown(gb: *GraphicsBase) !void {
    const rb = kernelRtg(gb);
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(gb.utility_base));

    // The pool outlives the library on a real machine, since nothing
    // expunges graphics.library; here it has to go back.
    freeOwnedForTests(gb);
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

/// What the library owns and never gives back, since it never expunges -
/// its region pool and its copy of the ROM fonts - freed for a host test
/// that takes it down, this one's and those of the libraries built on it.
pub fn freeOwnedForTests(gb: *GraphicsBase) void {
    gb.sys_base.DeletePool(gb.region_pool);
    gb.sys_base.FreeVec(gb.rom_fonts);
}

/// A surface over memory of the test's own, which no board is behind.
fn memorySurface(pixels: []u8, format: rtg.bitmaps.PixelFormat) rtg.Surface {
    const bytes = rtg.bitmaps.formatBits(format) / 8;
    return .{
        .pixels = pixels.ptr,
        .width = 8,
        .height = 4,
        .pitch = 8 * @max(bytes, 1),
        .size_bytes = pixels.len,
        .format = format,
    };
}

test {
    _ = graphics_base;
    _ = graphics_init;
    _ = @import("graphics_lvo.zig");
    _ = @import("area/_area.zig");
    _ = @import("area/areaarc.zig");
    _ = @import("area/areacircle.zig");
    _ = @import("area/areadraw.zig");
    _ = @import("area/areaellipse.zig");
    _ = @import("area/areaend.zig");
    _ = @import("area/areamove.zig");
    _ = @import("area/initarea.zig");
    _ = @import("bitmap/_bitmap.zig");
    _ = @import("bitmap/allocbitmaptaglist.zig");
    _ = @import("bitmap/freebitmap.zig");
    _ = @import("blit/_blit.zig");
    _ = @import("blit/bitmapscale.zig");
    _ = @import("blit/bltbitmap.zig");
    _ = @import("blit/bltbitmaprastport.zig");
    _ = @import("blit/bltmaskbitmaprastport.zig");
    _ = @import("blit/bltmaskrastport.zig");
    _ = @import("blit/bltpattern.zig");
    _ = @import("blit/bltrastport.zig");
    _ = @import("blit/blttemplate.zig");
    _ = @import("blit/writepixelarray.zig");
    _ = @import("blit/writelutpixelarray.zig");
    _ = @import("blit/scrollraster.zig");
    _ = @import("display/_display.zig");
    _ = @import("draw/_draw.zig");
    _ = @import("draw/draw.zig");
    _ = @import("draw/drawarc.zig");
    _ = @import("draw/drawcircle.zig");
    _ = @import("draw/drawellipse.zig");
    _ = @import("draw/drawhline.zig");
    _ = @import("draw/drawpoly.zig");
    _ = @import("draw/drawrect.zig");
    _ = @import("draw/drawvline.zig");
    _ = @import("draw/move.zig");
    _ = @import("draw/readpixel.zig");
    _ = @import("draw/rectfill.zig");
    _ = @import("draw/writepixel.zig");
    _ = @import("errors/graphicserrortext.zig");
    _ = @import("fonts/pospaz16.zig");
    _ = @import("fonts/pospaz8.zig");
    _ = @import("rastport/_rastport.zig");
    _ = @import("rastport/createrastporttaglist.zig");
    _ = @import("rastport/eraserect.zig");
    _ = @import("rastport/freerastport.zig");
    _ = @import("rastport/getrpattrs.zig");
    _ = @import("rastport/setrpattrs.zig");
    _ = @import("region/_region.zig");
    _ = @import("region/andrectregion.zig");
    _ = @import("region/andregionregion.zig");
    _ = @import("region/clearrectregion.zig");
    _ = @import("region/clearregion.zig");
    _ = @import("region/disposeregion.zig");
    _ = @import("region/newregion.zig");
    _ = @import("region/offsetregion.zig");
    _ = @import("region/orrectregion.zig");
    _ = @import("region/orregionregion.zig");
    _ = @import("region/pointinregion.zig");
    _ = @import("region/regionrectangles.zig");
    _ = @import("region/subregionregion.zig");
    _ = @import("region/xorrectregion.zig");
    _ = @import("region/xorregionregion.zig");
    _ = @import("rows/_rows.zig");
    _ = @import("text/_text.zig");
    _ = @import("text/addfont.zig");
    _ = @import("text/asksoftstyle.zig");
    _ = @import("text/closefont.zig");
    _ = @import("text/fontextent.zig");
    _ = @import("text/openfont.zig");
    _ = @import("text/remfont.zig");
    _ = @import("text/setsoftstyle.zig");
    _ = @import("text/text.zig");
    _ = @import("text/textextent.zig");
    _ = @import("text/textfit.zig");
    _ = @import("text/textlength.zig");
}

test "graphics.library: made from its tag, opened by name, and it stays" {
    const gb = try setUp();
    defer kexec.deinit();

    try testing.expectEqualStrings(LIBRARY_NAME, gb.lib.name());
    try testing.expectEqual(@as(u16, LIBRARY_VERSION), gb.lib.version);
    try testing.expectEqual(@as(u16, LIBRARY_REVISION), gb.lib.revision);
    try testing.expectEqual(kexec.SysBase, @as(*kexec.ExecBase, @ptrCast(@alignCast(gb.sys_base))));

    // The init opened both, and found no display: nothing has made a board.
    try testing.expect(gb.view == null);
    try testing.expectEqualStrings(kutility.LIBRARY_NAME, @as(*kutility.UtilityBase, @ptrCast(@alignCast(gb.utility_base))).lib.name());
    try testing.expectEqualStrings(krtg.LIBRARY_NAME, kernelRtg(gb).lib.name());

    // Open and close through the list, as a program does.
    try testing.expectEqual(&gb.lib, kexec.OpenLibrary(kexec.SysBase, LIBRARY_NAME, LIBRARY_VERSION).?);
    try testing.expectEqual(@as(u16, 1), gb.lib.open_cnt);
    kexec.CloseLibrary(kexec.SysBase, &gb.lib);
    try testing.expectEqual(@as(u16, 0), gb.lib.open_cnt);

    // A closed ROM library is not expunged: the close leaves it on the
    // list, and an expunge of its own accord frees nothing.
    try testing.expect(graphics_base.expunge(&gb.lib) == null);
    try testing.expectEqual(&gb.lib.node, kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, LIBRARY_NAME).?);

    // A version past this one is refused.
    try testing.expect(kexec.OpenLibrary(kexec.SysBase, LIBRARY_NAME, LIBRARY_VERSION + 1) == null);

    try tearDown(gb);
}

test "a pen is a colour, packed once into the surface's format" {
    const red = graphics.penRGB(0xFF, 0x00, 0x00);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), red);
    try testing.expect(graphics.penIsOpaque(red));
    try testing.expect(!graphics.penIsOpaque(graphics.penARGB(0x80, 0xFF, 0, 0)));

    // A 0xAARRGGBB word written to memory here is b, g, r, a.
    try testing.expectEqual(@as(?u32, 0xFFFF_0000), rastport.packPen(.bgra32, red));
    try testing.expectEqual(@as(?u32, 0xFF00_00FF), rastport.packPen(.rgba32, red));
    try testing.expectEqual(@as(?u32, 0xF800), rastport.packPen(.rgb565, red));
    try testing.expectEqual(@as(?u32, 0xFC00), rastport.packPen(.argb1555, red));
    try testing.expectEqual(@as(?u32, 0x7C00), rastport.packPen(.argb1555, graphics.penARGB(0, 0xFF, 0, 0)));
    try testing.expectEqual(@as(?u32, 0xFF_0000), rastport.packPen(.bgr24, red));
    try testing.expectEqual(@as(?u32, 0xFF), rastport.packPen(.rgb24, red));

    // Green and blue land where the format says, not where the pen has them.
    try testing.expectEqual(@as(?u32, 0x07E0), rastport.packPen(.rgb565, graphics.penRGB(0, 0xFF, 0)));
    try testing.expectEqual(@as(?u32, 0x001F), rastport.packPen(.rgb565, graphics.penRGB(0, 0, 0xFF)));

    // Three formats have no mapping until something decides one.
    try testing.expect(rastport.packPen(.indexed8, red) == null);
    try testing.expect(rastport.packPen(.gray8, red) == null);
    try testing.expect(rastport.packPen(.mono1, red) == null);
}

test "a RastPort on plain memory: no board behind it, and it comes back" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [64]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const tag_list = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{},
    };

    const rp = base(gb).CreateRastPortTagList(&tag_list) orelse return error.NoRastPort;
    const port: *rastport.RastPort = @ptrCast(@alignCast(rp));
    try testing.expectEqual(&surface, port.surface);
    // Plain memory, so there is no board and every operation is software.
    try testing.expect(port.bitmap == null);
    // White on black by default, packed for rgb565.
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), port.fg_pen);
    try testing.expectEqual(@as(u32, 0xFF00_0000), port.bg_pen);
    try testing.expectEqual(@as(u32, 0xFFFF), port.fg_packed);
    try testing.expectEqual(@as(u32, 0x0000), port.bg_packed);
    try testing.expectEqual(graphics.DRMD_JAM1, port.draw_mode);
    try testing.expectEqual(@as(i32, 0), port.cp_x);

    base(gb).FreeRastPort(rp);
    try tearDown(gb);
}

test "the tags set the state at birth" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [128]u8 = @splat(0);
    var surface = memorySurface(&pixels, .bgra32);
    const half_red = graphics.penARGB(0x80, 0xFF, 0x00, 0x00);
    const tag_list = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_APen, .data = half_red },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(0, 0, 0xFF) },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_BLEND },
        .{},
    };

    const rp = base(gb).CreateRastPortTagList(&tag_list) orelse return error.NoRastPort;
    const port: *rastport.RastPort = @ptrCast(@alignCast(rp));
    try testing.expectEqual(half_red, port.fg_pen);
    // Not opaque, so it can never be handed to a board's engine.
    try testing.expect(!graphics.penIsOpaque(port.fg_pen));
    try testing.expectEqual(half_red, port.fg_packed);
    try testing.expectEqual(graphics.DRMD_BLEND, port.draw_mode);

    base(gb).FreeRastPort(rp);
    try tearDown(gb);
}

test "a format with no pen mapping is refused, not handed back to fail later" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [32]u8 = @splat(0);
    var surface = memorySurface(&pixels, .indexed8);
    const tag_list = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{},
    };
    try testing.expect(base(gb).CreateRastPortTagList(&tag_list) == null);

    try tearDown(gb);
}

test "no display and no buffer named: no RastPort, and it is not a crash" {
    const gb = try setUp();
    defer kexec.deinit();

    try testing.expect(base(gb).CreateRastPortTagList(null) == null);
    try testing.expect(gb.view == null);
    // Null is allowed and does nothing.
    base(gb).FreeRastPort(null);

    try tearDown(gb);
}

test "with a display: no tags finds the View, and the buffer it is showing" {
    const gb = try setUp();
    defer kexec.deinit();

    const rb = kernelRtg(gb);
    const rbi: *sdk.interface.rtg.RtgBase = @ptrCast(rb);
    const state = fake.create(rb.sys_base) orelse return error.NoDriver;
    try testing.expect(rbi.AddRtgDriver(&state.driver));

    const empty = [_]TagItem{.{}};
    const board = rbi.CreateBoardTagList(fake.DRIVER_NAME, &empty) orelse return error.NoBoard;
    const bm = rbi.AllocBitMap(
        board,
        8,
        4,
        @intFromEnum(rtg.bitmaps.PixelFormat.rgb565),
        rtg.bitmaps.RTGBMF_DISPLAYABLE,
    ) orelse return error.NoBitMap;
    try testing.expectEqual(rtg.errors.RTGERR_OK, rbi.ShowBitMap(board, bm, 0, 0));

    // No tags at all: the first board rtg lists, and what it is showing.
    const rp = base(gb).CreateRastPortTagList(null) orelse return error.NoRastPort;
    const port: *rastport.RastPort = @ptrCast(@alignCast(rp));
    try testing.expectEqual(board, gb.view.?);
    try testing.expectEqual(bm, port.bitmap.?);
    // The board's buffer arrives as a surface by pointer: same address.
    try testing.expectEqual(@intFromPtr(bm), @intFromPtr(port.surface));

    // Naming the board reaches the same buffer.
    const by_board = [_]TagItem{
        .{ .tag = graphics.RPTAG_Board, .data = @intFromPtr(board) },
        .{},
    };
    const rp2 = base(gb).CreateRastPortTagList(&by_board) orelse return error.NoRastPort;
    try testing.expectEqual(bm, @as(*rastport.RastPort, @ptrCast(@alignCast(rp2))).bitmap.?);

    base(gb).FreeRastPort(rp);
    base(gb).FreeRastPort(rp2);
    rbi.FreeBitMap(bm);
    rbi.DeleteBoard(board);
    _ = rbi.RemRtgDriver(&state.driver);
    fake.destroy(state);
    try tearDown(gb);
}

/// A RastPort on a memory surface of the test's own, so the software path
/// can be looked at pixel by pixel.
fn onMemory(gb: *GraphicsBase, surface: *rtg.Surface, extra: ?[*]const TagItem) !*rastport.RastPort {
    var tag_list = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) },
        .{ .tag = sdk.utility.TAG_MORE, .data = 0 },
    };
    tag_list[1] = if (extra) |more|
        .{ .tag = sdk.utility.TAG_MORE, .data = @intFromPtr(more) }
    else
        .{};
    const rp = base(gb).CreateRastPortTagList(&tag_list) orelse return error.NoRastPort;
    return @ptrCast(@alignCast(rp));
}

/// The pixel at (x, y) of an rgb565 surface, read a byte at a time as the
/// library writes it - a surface's rows are aligned to nothing in
/// particular, and a buffer of test bytes to less than that.
fn pixelAt(surface: *const rtg.Surface, x: u32, y: u32) u16 {
    const at = surface.pixels.? + @as(usize, y) * surface.pitch + x * 2;
    return @as(u16, at[0]) | @as(u16, at[1]) << 8;
}

test "RectFill: half-open, so max is one past the last pixel" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const red = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 0, 0) }, .{} };
    const rp = try onMemory(gb, &surface, &red);

    base(gb).RectFill(@ptrCast(rp), &.{ .min_x = 1, .min_y = 1, .max_x = 3, .max_y = 3 });

    // Four pixels, and the row and column at max are not among them.
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 1, 1));
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 2, 2));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 3, 3));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 0, 1));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 1, 0));

    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "RectFill: clipped to the surface, and a clip only ever narrows" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    const rp = try onMemory(gb, &surface, &white);

    // Reaching past every edge writes what is inside and nothing else.
    base(gb).RectFill(@ptrCast(rp), &.{ .min_x = -10, .min_y = -10, .max_x = 100, .max_y = 100 });
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 0, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 7, 3));

    // Entirely outside draws nothing, which is an answer and not an error.
    var clean: [8 * 4 * 2]u8 = @splat(0);
    var other = memorySurface(&clean, .rgb565);
    const rp2 = try onMemory(gb, &other, &white);
    base(gb).RectFill(@ptrCast(rp2), &.{ .min_x = 20, .min_y = 20, .max_x = 30, .max_y = 30 });
    for (clean) |byte| try testing.expectEqual(@as(u8, 0), byte);

    // A clip narrows; one bigger than the surface is clamped to it.
    var third: [8 * 4 * 2]u8 = @splat(0);
    var inside = memorySurface(&third, .rgb565);
    const clip = graphics.Rect{ .min_x = 2, .min_y = 1, .max_x = 4, .max_y = 2 };
    const clipped = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) },
        .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) },
        .{},
    };
    const rp3 = try onMemory(gb, &inside, &clipped);
    base(gb).RectFill(@ptrCast(rp3), &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 });
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&inside, 2, 1));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&inside, 3, 1));
    try testing.expectEqual(@as(u16, 0), pixelAt(&inside, 1, 1));
    try testing.expectEqual(@as(u16, 0), pixelAt(&inside, 2, 2));

    base(gb).FreeRastPort(@ptrCast(rp));
    base(gb).FreeRastPort(@ptrCast(rp2));
    base(gb).FreeRastPort(@ptrCast(rp3));
    try tearDown(gb);
}

/// A buffer of a board's, for the batch tests: a real `RtgBitMap` over
/// `pixels`, with no board behind it. graphics.library clears the rows it
/// gathered as it hands them on, and the refresh then fails for want of
/// a board, so a cleared span is what says they were handed on - which
/// is all these tests need to see.
fn boardBitMap(pixels: []u8, width: u32, height: u32) rtg.RtgBitMap {
    return .{
        .pixels = pixels.ptr,
        .width = width,
        .height = height,
        .pitch = width * 2,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
}

/// A RastPort drawing into `bm`, as a window's is.
fn onBitMap(gb: *GraphicsBase, bm: *rtg.RtgBitMap, extra: ?[*]const TagItem) !*rastport.RastPort {
    var tag_list = [_]TagItem{
        .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(bm) },
        .{ .tag = sdk.utility.TAG_MORE, .data = 0 },
    };
    tag_list[1] = if (extra) |more|
        .{ .tag = sdk.utility.TAG_MORE, .data = @intFromPtr(more) }
    else
        .{};
    const rp = base(gb).CreateRastPortTagList(&tag_list) orelse return error.NoRastPort;
    return @ptrCast(@alignCast(rp));
}

test "BeginDraw, EndDraw: what is drawn between them goes to the display once" {
    const gb = try setUp();
    var pixels: [8 * 8 * 2]u8 = @splat(0);
    var bm = boardBitMap(&pixels, 8, 8);
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    const rp = try onBitMap(gb, &bm, &white);
    const gfx = base(gb);

    // Without a batch, each call hands its rows on where it stands, and
    // nothing is left gathered.
    gfx.RectFill(@ptrCast(rp), &.{ .min_x = 0, .min_y = 1, .max_x = 8, .max_y = 2 });
    try testing.expectEqual(@as(u32, 0), bm.dirty_end);

    // With one, two calls on rows that do not touch gather into one span
    // from the first row written to the last, and nothing has gone yet.
    gfx.BeginDraw(@ptrCast(rp));
    try testing.expectEqual(@as(u32, 1), bm.held);
    gfx.RectFill(@ptrCast(rp), &.{ .min_x = 0, .min_y = 1, .max_x = 8, .max_y = 2 });
    try testing.expectEqual(@as(u32, 1), bm.dirty_top);
    try testing.expectEqual(@as(u32, 2), bm.dirty_end);
    gfx.RectFill(@ptrCast(rp), &.{ .min_x = 0, .min_y = 5, .max_x = 8, .max_y = 6 });
    try testing.expectEqual(@as(u32, 1), bm.dirty_top);
    try testing.expectEqual(@as(u32, 6), bm.dirty_end);

    // The end of it hands the span on, which is what clears it.
    gfx.EndDraw(@ptrCast(rp));
    try testing.expectEqual(@as(u32, 0), bm.held);
    try testing.expectEqual(@as(u32, 0), bm.dirty_end);

    gfx.FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "BeginDraw, EndDraw: pieces far apart are not welded together" {
    const gb = try setUp();
    // Tall enough that two pieces can be far apart in it.
    var pixels: [8 * 64 * 2]u8 = @splat(0);
    var bm = boardBitMap(&pixels, 8, 64);
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    const rp = try onBitMap(gb, &bm, &white);
    const gfx = base(gb);

    gfx.BeginDraw(@ptrCast(rp));
    gfx.RectFill(@ptrCast(rp), &.{ .min_x = 0, .min_y = 1, .max_x = 8, .max_y = 2 });
    try testing.expectEqual(@as(u32, 1), bm.dirty_top);
    try testing.expectEqual(@as(u32, 2), bm.dirty_end);

    // A piece a few rows off joins it: the rows between are worth
    // carrying rather than sending twice.
    gfx.RectFill(@ptrCast(rp), &.{ .min_x = 0, .min_y = 6, .max_x = 8, .max_y = 7 });
    try testing.expectEqual(@as(u32, 1), bm.dirty_top);
    try testing.expectEqual(@as(u32, 7), bm.dirty_end);

    // One far away does not. What was gathered goes - which is what
    // clears it - and the far piece is what is gathered now.
    gfx.RectFill(@ptrCast(rp), &.{ .min_x = 0, .min_y = 50, .max_x = 8, .max_y = 51 });
    try testing.expectEqual(@as(u32, 50), bm.dirty_top);
    try testing.expectEqual(@as(u32, 51), bm.dirty_end);

    gfx.EndDraw(@ptrCast(rp));
    try testing.expectEqual(@as(u32, 0), bm.dirty_end);

    gfx.FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "BeginDraw, EndDraw: they nest, and nothing goes until the last" {
    const gb = try setUp();
    var pixels: [8 * 8 * 2]u8 = @splat(0);
    var bm = boardBitMap(&pixels, 8, 8);
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    const rp = try onBitMap(gb, &bm, &white);
    const gfx = base(gb);

    gfx.BeginDraw(@ptrCast(rp));
    gfx.BeginDraw(@ptrCast(rp));
    try testing.expectEqual(@as(u32, 2), bm.held);
    gfx.RectFill(@ptrCast(rp), &.{ .min_x = 0, .min_y = 2, .max_x = 8, .max_y = 3 });

    // The inner end is not the end.
    gfx.EndDraw(@ptrCast(rp));
    try testing.expectEqual(@as(u32, 1), bm.held);
    try testing.expectEqual(@as(u32, 3), bm.dirty_end);

    gfx.EndDraw(@ptrCast(rp));
    try testing.expectEqual(@as(u32, 0), bm.held);
    try testing.expectEqual(@as(u32, 0), bm.dirty_end);

    // One more end than there were beginnings does nothing.
    gfx.EndDraw(@ptrCast(rp));
    try testing.expectEqual(@as(u32, 0), bm.held);

    gfx.FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "BeginDraw, EndDraw: a batch is the buffer's, so another RastPort joins it" {
    const gb = try setUp();
    var pixels: [8 * 8 * 2]u8 = @splat(0);
    var bm = boardBitMap(&pixels, 8, 8);
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    const rp = try onBitMap(gb, &bm, &white);
    // A second RastPort on the same buffer, as the one intuition lends a
    // gadget to render with is.
    const other = try onBitMap(gb, &bm, &white);
    const gfx = base(gb);

    gfx.BeginDraw(@ptrCast(rp));
    // Drawn through the other one, and still gathered rather than sent.
    gfx.RectFill(@ptrCast(other), &.{ .min_x = 0, .min_y = 4, .max_x = 8, .max_y = 5 });
    try testing.expectEqual(@as(u32, 4), bm.dirty_top);
    try testing.expectEqual(@as(u32, 5), bm.dirty_end);
    gfx.EndDraw(@ptrCast(rp));
    try testing.expectEqual(@as(u32, 0), bm.dirty_end);

    gfx.FreeRastPort(@ptrCast(rp));
    gfx.FreeRastPort(@ptrCast(other));
    try tearDown(gb);
}

test "BeginDraw, EndDraw: a refresh from outside the batch leaves what it gathered" {
    const gb = try setUp();
    var pixels: [8 * 8 * 2]u8 = @splat(0);
    var bm = boardBitMap(&pixels, 8, 8);
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    const rp = try onBitMap(gb, &bm, &white);
    const gfx = base(gb);

    gfx.BeginDraw(@ptrCast(rp));
    gfx.RectFill(@ptrCast(rp), &.{ .min_x = 0, .min_y = 4, .max_x = 8, .max_y = 5 });

    // Someone else hands a row of the same buffer on by hand. That is
    // theirs; the batch's rows are still to go.
    _ = gb.rtg_base.RefreshBitMap(&bm, 0, 1);
    try testing.expectEqual(@as(u32, 4), bm.dirty_top);
    try testing.expectEqual(@as(u32, 5), bm.dirty_end);

    gfx.EndDraw(@ptrCast(rp));
    try testing.expectEqual(@as(u32, 0), bm.dirty_end);

    gfx.FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "BeginDraw, EndDraw: nothing drawn sends nothing, and plain memory is untouched" {
    const gb = try setUp();
    var pixels: [8 * 8 * 2]u8 = @splat(0);
    var bm = boardBitMap(&pixels, 8, 8);
    const rp = try onBitMap(gb, &bm, null);
    const gfx = base(gb);

    // A batch with no drawing in it leaves nothing gathered and sends
    // nothing.
    gfx.BeginDraw(@ptrCast(rp));
    gfx.EndDraw(@ptrCast(rp));
    try testing.expectEqual(@as(u32, 0), bm.held);
    try testing.expectEqual(@as(u32, 0), bm.dirty_end);

    // A RastPort on plain memory has no buffer to hand rows to, so the
    // two calls do nothing at all and drawing still works.
    var plain: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&plain, .rgb565);
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    const memory_rp = try onMemory(gb, &surface, &white);
    gfx.BeginDraw(@ptrCast(memory_rp));
    gfx.RectFill(@ptrCast(memory_rp), &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 1 });
    gfx.EndDraw(@ptrCast(memory_rp));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 0, 0));

    gfx.FreeRastPort(@ptrCast(rp));
    gfx.FreeRastPort(@ptrCast(memory_rp));
    try tearDown(gb);
}

test "RectFill: a pen that is not opaque is composed with what is under it" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);

    // Red underneath, opaque.
    const red = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 0, 0) }, .{} };
    const under = try onMemory(gb, &surface, &red);
    base(gb).RectFill(@ptrCast(under), &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 });
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 0, 0));

    // Half-covering blue over it: neither red nor blue comes out.
    const half_blue = graphics.penARGB(0x80, 0, 0, 255);
    const shade = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = half_blue },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_BLEND },
        .{},
    };
    const over = try onMemory(gb, &surface, &shade);
    base(gb).RectFill(@ptrCast(over), &.{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 });

    const mixed = pixelAt(&surface, 0, 0);
    try testing.expect(mixed != 0xF800); // not the red that was there
    try testing.expect(mixed != 0x001F); // and not the blue either
    try testing.expect(mixed >> 11 != 0); // some red left
    try testing.expect(mixed & 0x1F != 0); // some blue arrived
    // Outside the fill the red is untouched.
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 5, 0));

    // Under .copy the pen is written whatever its alpha.
    const copied = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = half_blue }, .{} };
    const plain = try onMemory(gb, &surface, &copied);
    base(gb).RectFill(@ptrCast(plain), &.{ .min_x = 5, .min_y = 0, .max_x = 6, .max_y = 1 });
    try testing.expectEqual(@as(u16, 0x001F), pixelAt(&surface, 5, 0));

    base(gb).FreeRastPort(@ptrCast(under));
    base(gb).FreeRastPort(@ptrCast(over));
    base(gb).FreeRastPort(@ptrCast(plain));
    try tearDown(gb);
}

test "RectFill: the board's engine takes an opaque pen, and nothing else" {
    const gb = try setUp();
    defer kexec.deinit();

    const rb = kernelRtg(gb);
    const rbi: *sdk.interface.rtg.RtgBase = @ptrCast(rb);
    const state = fake.create(rb.sys_base) orelse return error.NoDriver;
    try testing.expect(rbi.AddRtgDriver(&state.driver));
    const empty = [_]TagItem{.{}};
    const brd = rbi.CreateBoardTagList(fake.DRIVER_NAME, &empty) orelse return error.NoBoard;
    const bm = rbi.AllocBitMap(brd, 8, 4, @intFromEnum(rtg.bitmaps.PixelFormat.rgb565), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse
        return error.NoBitMap;

    const green = graphics.penRGB(0, 255, 0);
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(bm) },
        .{ .tag = graphics.RPTAG_APen, .data = green },
        .{},
    };
    const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;

    const before = state.log.fills;
    base(gb).RectFill(rp, &.{ .min_x = 1, .min_y = 0, .max_x = 5, .max_y = 2 });
    // The engine did it, and got the rectangle as width and height.
    try testing.expectEqual(before + 1, state.log.fills);
    try testing.expectEqual(@as(i32, 1), state.log.last_rect.x);
    try testing.expectEqual(@as(i32, 4), state.log.last_rect.width);
    try testing.expectEqual(@as(i32, 2), state.log.last_rect.height);
    // And the rows it touched were handed on.
    try testing.expectEqual(@as(u32, 2), state.log.last_refresh_rows);

    // A pen that is not opaque cannot go to an engine that takes a colour
    // word, so it is composed here even though this board has one.
    const shade = [_]TagItem{
        .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(bm) },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penARGB(0x40, 0, 0, 255) },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_BLEND },
        .{},
    };
    const soft = base(gb).CreateRastPortTagList(&shade) orelse return error.NoRastPort;
    const fills = state.log.fills;
    base(gb).RectFill(soft, &.{ .min_x = 1, .min_y = 0, .max_x = 5, .max_y = 2 });
    try testing.expectEqual(fills, state.log.fills);

    base(gb).FreeRastPort(rp);
    base(gb).FreeRastPort(soft);
    rbi.FreeBitMap(bm);
    rbi.DeleteBoard(brd);
    _ = rbi.RemRtgDriver(&state.driver);
    fake.destroy(state);
    try tearDown(gb);
}

test "a pen survives a trip into a surface's format and back" {
    for ([_]rtg.bitmaps.PixelFormat{ .bgra32, .rgba32, .rgb24, .bgr24, .rgb565, .argb1555 }) |format| {
        for ([_]graphics.Pen{
            graphics.penRGB(0, 0, 0),
            graphics.penRGB(255, 255, 255),
            graphics.penRGB(255, 0, 0),
            graphics.penRGB(0, 255, 0),
            graphics.penRGB(0, 0, 255),
        }) |pen| {
            const packed_value = rastport.packPen(format, pen).?;
            // All-ones in a narrow channel has to come back as 0xFF, or a
            // pixel read out and written back would drift.
            try testing.expectEqual(pen, rastport.unpackPen(format, packed_value));
        }
    }
}

test "SetRPAttrs: what makes a RastPort also changes one" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const rp = try onMemory(gb, &surface, null);

    // The pen and its packed copy move together, or the drawing path
    // would keep writing the old colour.
    const blue = graphics.penRGB(0, 0, 255);
    const change = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = blue },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_BLEND },
        .{},
    };
    base(gb).SetRPAttrs(@ptrCast(rp), &change);
    try testing.expectEqual(blue, rp.fg_pen);
    try testing.expectEqual(@as(u32, 0x001F), rp.fg_packed);
    try testing.expectEqual(graphics.DRMD_BLEND, rp.draw_mode);

    base(gb).RectFill(@ptrCast(rp), &.{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 });
    try testing.expectEqual(@as(u16, 0x001F), pixelAt(&surface, 0, 0));

    // A clip set afterwards is clamped, exactly as one set at birth is.
    const big = graphics.Rect{ .min_x = -5, .min_y = -5, .max_x = 500, .max_y = 500 };
    const wide = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&big) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &wide);
    try testing.expectEqual(@as(i32, 0), rp.clip.min_x);
    try testing.expectEqual(@as(i32, 8), rp.clip.max_x);
    try testing.expectEqual(@as(i32, 4), rp.clip.max_y);

    // The buffer is not the RastPort's to change, and a tag it does not
    // know is passed over rather than refused.
    var other: [32]u8 = @splat(0);
    var elsewhere = memorySurface(&other, .rgb565);
    const moved = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&elsewhere) },
        .{ .tag = sdk.utility.TAG_USER + 999_999, .data = 1 },
        .{},
    };
    base(gb).SetRPAttrs(@ptrCast(rp), &moved);
    try testing.expectEqual(&surface, rp.surface);

    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "GetRPAttrs: ti_Data is where the answer goes" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const clip = graphics.Rect{ .min_x = 1, .min_y = 1, .max_x = 5, .max_y = 3 };
    const made = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 0, 0) },
        .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) },
        .{},
    };
    const rp = try onMemory(gb, &surface, &made);

    var pen: graphics.Pen = 0;
    var mode: u32 = 99;
    var format: u32 = 99;
    var got_clip: graphics.Rect = .{};
    var bounds: graphics.Rect = .{};
    var bitmap: usize = 12345;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = @intFromPtr(&pen) },
        .{ .tag = graphics.RPTAG_DrMd, .data = @intFromPtr(&mode) },
        .{ .tag = graphics.RPTAG_Format, .data = @intFromPtr(&format) },
        .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&got_clip) },
        .{ .tag = graphics.RPTAG_Bounds, .data = @intFromPtr(&bounds) },
        .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(&bitmap) },
        .{},
    };
    base(gb).GetRPAttrs(@ptrCast(rp), &ask);

    try testing.expectEqual(graphics.penRGB(255, 0, 0), pen);
    try testing.expectEqual(@as(u32, graphics.DRMD_JAM1), mode);
    try testing.expectEqual(@as(u32, @intFromEnum(rtg.bitmaps.PixelFormat.rgb565)), format);
    try testing.expectEqual(clip, got_clip);
    // The bounds are the surface's whole rectangle - the only way to find
    // out how big a display is.
    try testing.expectEqual(graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 }, bounds);
    // Plain memory has no board behind it.
    try testing.expectEqual(@as(usize, 0), bitmap);

    // A null ti_Data is passed over rather than written through.
    const null_data = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = 0 }, .{} };
    base(gb).GetRPAttrs(@ptrCast(rp), &null_data);

    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

/// A backfill hook for the erase tests: it paints green and remembers what
/// it was asked to paint.
const Filler = struct {
    var calls: u32 = 0;
    var asked: graphics.Rect = .{};

    fn paint(hook: *sdk.utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        const gb: *interface.GraphicsBase = @ptrCast(@alignCast(hook.data.?));
        const rp: *graphics.RastPort = @ptrCast(@alignCast(object.?));
        const msg: *graphics.BackFillMsg = @ptrCast(@alignCast(message.?));
        calls += 1;
        asked = msg.area;
        const green = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 255, 0) }, .{} };
        gb.SetRPAttrs(rp, &green);
        gb.RectFill(rp, &msg.area);
        return 0;
    }
};

test "EraseRect: the hook, the background pen, or nothing at all" {
    const gb = try setUp();
    defer kexec.deinit();
    const it = base(gb);

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const red = [_]TagItem{ .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(255, 0, 0) }, .{} };
    const rp = try onMemory(gb, &surface, &red);
    const area = graphics.Rect{ .min_x = 1, .min_y = 1, .max_x = 4, .max_y = 3 };

    // Nothing said how, so the RastPort's own background pen - and only
    // inside the rectangle asked for.
    it.EraseRect(@ptrCast(rp), &area);
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 2, 2));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 0, 0));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 4, 2));

    // A hook of the caller's: asked once, for exactly that area, and what
    // it paints is what lands.
    Filler.calls = 0;
    var hook = sdk.utility.Hook{ .entry = &Filler.paint, .data = it };
    const with_hook = [_]TagItem{ .{ .tag = graphics.RPTAG_BackFill, .data = @intFromPtr(&hook) }, .{} };
    it.SetRPAttrs(@ptrCast(rp), &with_hook);
    it.EraseRect(@ptrCast(rp), &area);
    try testing.expectEqual(@as(u32, 1), Filler.calls);
    try testing.expectEqual(area, Filler.asked);
    try testing.expectEqual(@as(u16, 0x07E0), pixelAt(&surface, 2, 2));

    // And it reads back as it was set.
    var back: usize = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_BackFill, .data = @intFromPtr(&back) }, .{} };
    it.GetRPAttrs(@ptrCast(rp), &ask);
    try testing.expectEqual(@intFromPtr(&hook), back);

    // Asked for nothing: the hook is not called and no pixel is written.
    Filler.calls = 0;
    const none = [_]TagItem{ .{ .tag = graphics.RPTAG_BackFill, .data = graphics.BACKFILL_NONE }, .{} };
    it.SetRPAttrs(@ptrCast(rp), &none);
    it.EraseRect(@ptrCast(rp), &area);
    try testing.expectEqual(@as(u32, 0), Filler.calls);
    try testing.expectEqual(@as(u16, 0x07E0), pixelAt(&surface, 2, 2)); // as the hook left it

    // A RastPort left in COMPLEMENT still gets a plain backfill, and keeps
    // the pen and the mode it had: an erase is passing through.
    const odd = [_]TagItem{
        .{ .tag = graphics.RPTAG_BackFill, .data = 0 },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 0, 255) },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_COMPLEMENT },
        .{},
    };
    it.SetRPAttrs(@ptrCast(rp), &odd);
    it.EraseRect(@ptrCast(rp), &area);
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 2, 2));
    var pen_now: usize = 0;
    var mode_now: usize = 0;
    const ask2 = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = @intFromPtr(&pen_now) },
        .{ .tag = graphics.RPTAG_DrMd, .data = @intFromPtr(&mode_now) },
        .{},
    };
    it.GetRPAttrs(@ptrCast(rp), &ask2);
    try testing.expectEqual(@as(usize, graphics.penRGB(0, 0, 255)), pen_now);
    try testing.expectEqual(@as(usize, graphics.DRMD_COMPLEMENT), mode_now);

    it.FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "AllocBitMap: memory of one's own, and its format from a friend" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const screen = try onMemory(gb, &surface, null);

    const tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = 6 },
        .{ .tag = graphics.BMTAG_Height, .data = 3 },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(screen) },
        .{ .tag = graphics.BMTAG_Clear, .data = 1 },
        .{},
    };
    const bm = base(gb).AllocBitMapTagList(&tags) orelse return error.NoBitMap;

    try testing.expectEqual(@as(u32, 6), bm.width);
    try testing.expectEqual(@as(u32, 3), bm.height);
    // The friend's format, so the two can be moved between as they are.
    try testing.expectEqual(rtg.bitmaps.PixelFormat.rgb565, bm.format);
    try testing.expect(bm.pitch >= 12);
    // Cleared, and the pixels are behind the header on a line boundary.
    try testing.expectEqual(@as(usize, 0), @intFromPtr(bm.pixels.?) % 64);
    try testing.expect(@intFromPtr(bm.pixels.?) > @intFromPtr(bm));
    for (bm.pixels.?[0..bm.size_bytes]) |byte| try testing.expectEqual(@as(u8, 0), byte);

    // Nothing without a size, and nothing in a format no pen fits.
    const no_size = [_]TagItem{ .{ .tag = graphics.BMTAG_Width, .data = 4 }, .{} };
    try testing.expect(base(gb).AllocBitMapTagList(&no_size) == null);
    const bad = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = 4 },
        .{ .tag = graphics.BMTAG_Height, .data = 4 },
        .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(rtg.bitmaps.PixelFormat.indexed8) },
        .{},
    };
    try testing.expect(base(gb).AllocBitMapTagList(&bad) == null);

    base(gb).FreeBitMap(bm);
    base(gb).FreeBitMap(null);
    base(gb).FreeRastPort(@ptrCast(screen));
    try tearDown(gb);
}

test "BltRastPort: what was covered can be kept and put back" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const red = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 0, 0) }, .{} };
    const screen = try onMemory(gb, &surface, &red);
    base(gb).RectFill(@ptrCast(screen), &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 });

    // Somewhere to keep a 4x2 corner of it.
    const tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = 4 },
        .{ .tag = graphics.BMTAG_Height, .data = 2 },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(screen) },
        .{},
    };
    const saved = base(gb).AllocBitMapTagList(&tags) orelse return error.NoBitMap;
    const saved_tags = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(saved) }, .{} };
    const saved_rp = base(gb).CreateRastPortTagList(&saved_tags) orelse return error.NoRastPort;

    const box = graphics.Rect{ .min_x = 2, .min_y = 1, .max_x = 6, .max_y = 3 };
    base(gb).BltRastPort(@ptrCast(screen), saved_rp, &box, 0, 0);
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(saved, 0, 0));
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(saved, 3, 1));

    // Draw over the screen, then put the kept part back.
    const blue = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 0, 255) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(screen), &blue);
    base(gb).RectFill(@ptrCast(screen), &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 });
    try testing.expectEqual(@as(u16, 0x001F), pixelAt(&surface, 2, 1));

    base(gb).BltRastPort(saved_rp, @ptrCast(screen), &.{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 2 }, 2, 1);
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 2, 1));
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 5, 2));
    // Only where it was put back: the rest is still blue.
    try testing.expectEqual(@as(u16, 0x001F), pixelAt(&surface, 1, 1));
    try testing.expectEqual(@as(u16, 0x001F), pixelAt(&surface, 6, 2));

    base(gb).FreeRastPort(saved_rp);
    base(gb).FreeBitMap(saved);
    base(gb).FreeRastPort(@ptrCast(screen));
    try tearDown(gb);
}

test "BltRastPort: clipped by the destination, and safe over itself" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    const rp = try onMemory(gb, &surface, &white);
    base(gb).RectFill(@ptrCast(rp), &.{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 1 });

    // Over itself, moving right and down: a memmove, not a memcpy.
    base(gb).BltRastPort(@ptrCast(rp), @ptrCast(rp), &.{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 1 }, 1, 1);
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 1, 1));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 2, 1));

    // Landing past the edge writes only what fits, and nothing at all when
    // none of it does.
    base(gb).BltRastPort(@ptrCast(rp), @ptrCast(rp), &.{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 1 }, 7, 3);
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 7, 3));
    base(gb).BltRastPort(@ptrCast(rp), @ptrCast(rp), &.{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 1 }, 20, 20);

    // A different format is refused rather than half-converted.
    var other: [8 * 4 * 4]u8 = @splat(0);
    var wide = memorySurface(&other, .bgra32);
    const wide_rp = try onMemory(gb, &wide, null);
    base(gb).BltRastPort(@ptrCast(rp), @ptrCast(wide_rp), &.{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 1 }, 0, 0);
    for (other) |byte| try testing.expectEqual(@as(u8, 0), byte);

    base(gb).FreeRastPort(@ptrCast(rp));
    base(gb).FreeRastPort(@ptrCast(wide_rp));
    try tearDown(gb);
}

test "Move and Draw: both ends drawn, and the point follows the line" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    const rp = try onMemory(gb, &surface, &white);

    // A horizontal run: both ends are drawn, so 0..3 is four pixels.
    base(gb).Move(@ptrCast(rp), 0, 0);
    base(gb).Draw(@ptrCast(rp), 3, 0);
    for (0..4) |x| try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, @intCast(x), 0));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 4, 0));
    // The point is where the line ended.
    try testing.expectEqual(@as(i32, 3), rp.cp_x);

    // A diagonal, and the point follows it again.
    base(gb).Draw(@ptrCast(rp), 6, 3);
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 6, 3));
    try testing.expectEqual(@as(i32, 6), rp.cp_x);
    try testing.expectEqual(@as(i32, 3), rp.cp_y);

    // One place, one pixel.
    base(gb).Move(@ptrCast(rp), 7, 0);
    base(gb).Draw(@ptrCast(rp), 7, 0);
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 7, 0));

    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "Draw: clipped at the edges, and the point moves even when nothing does" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    const rp = try onMemory(gb, &surface, &white);

    // From well outside to well outside, straight through: what is inside
    // is drawn and nothing runs off the end of a row.
    base(gb).Move(@ptrCast(rp), -20, 2);
    base(gb).Draw(@ptrCast(rp), 40, 2);
    for (0..8) |x| try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, @intCast(x), 2));
    // The row above and below are untouched, so nothing wrapped.
    for (0..8) |x| try testing.expectEqual(@as(u16, 0), pixelAt(&surface, @intCast(x), 1));

    // Entirely outside draws nothing, and the point still moves - it is
    // where the next Draw starts from, not where this one reached.
    base(gb).Move(@ptrCast(rp), -50, -50);
    base(gb).Draw(@ptrCast(rp), -10, -40);
    try testing.expectEqual(@as(i32, -10), rp.cp_x);
    try testing.expectEqual(@as(i32, -40), rp.cp_y);
    for (0..8) |x| try testing.expectEqual(@as(u16, 0), pixelAt(&surface, @intCast(x), 0));

    // A clip narrows a line as it narrows a fill.
    const clip = graphics.Rect{ .min_x = 2, .min_y = 0, .max_x = 5, .max_y = 4 };
    const narrowed = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &narrowed);
    base(gb).Move(@ptrCast(rp), 0, 0);
    base(gb).Draw(@ptrCast(rp), 7, 0);
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 1, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 2, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 4, 0));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 5, 0));

    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "RPTAG_Cursor reads and writes the current point" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const rp = try onMemory(gb, &surface, null);

    const put = graphics.Point{ .x = 5, .y = 2 };
    const set = [_]TagItem{ .{ .tag = graphics.RPTAG_Cursor, .data = @intFromPtr(&put) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &set);
    try testing.expectEqual(@as(i32, 5), rp.cp_x);

    base(gb).Move(@ptrCast(rp), 1, 3);
    var got: graphics.Point = .{};
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_Cursor, .data = @intFromPtr(&got) }, .{} };
    base(gb).GetRPAttrs(@ptrCast(rp), &ask);
    try testing.expectEqual(graphics.Point{ .x = 1, .y = 3 }, got);

    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "what went wrong: in the RastPort, and through a pointer when there is none" {
    const gb = try setUp();
    defer kexec.deinit();

    // A creation call has no RastPort to put it in, so it writes through.
    var why: i32 = 12345;
    const no_display = [_]TagItem{
        .{ .tag = graphics.RPTAG_ErrorPtr, .data = @intFromPtr(&why) },
        .{},
    };
    try testing.expect(base(gb).CreateRastPortTagList(&no_display) == null);
    try testing.expectEqual(graphics.GERR_NO_DISPLAY, why);

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var bad = memorySurface(&pixels, .indexed8);
    const unpackable = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&bad) },
        .{ .tag = graphics.RPTAG_ErrorPtr, .data = @intFromPtr(&why) },
        .{},
    };
    try testing.expect(base(gb).CreateRastPortTagList(&unpackable) == null);
    try testing.expectEqual(graphics.GERR_BAD_FORMAT, why);

    // A call that worked says so, so what is read is the call just made.
    var surface = memorySurface(&pixels, .rgb565);
    const good = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_ErrorPtr, .data = @intFromPtr(&why) },
        .{},
    };
    const rp = base(gb).CreateRastPortTagList(&good) orelse return error.NoRastPort;
    try testing.expectEqual(graphics.GERR_OK, why);

    // A bitmap reports the same way, through its own tag.
    var bm_why: i32 = 0;
    const no_size = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = 4 },
        .{ .tag = graphics.BMTAG_ErrorPtr, .data = @intFromPtr(&bm_why) },
        .{},
    };
    try testing.expect(base(gb).AllocBitMapTagList(&no_size) == null);
    try testing.expectEqual(graphics.GERR_BAD_SIZE, bm_why);

    // A blit across two formats did nothing, and now says why.
    var wide_pixels: [8 * 4 * 4]u8 = @splat(0);
    var wide = memorySurface(&wide_pixels, .bgra32);
    const wide_rp = try onMemory(gb, &wide, null);
    base(gb).BltRastPort(@ptrCast(wide_rp), rp, &.{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 1 }, 0, 0);

    var err: i32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_LastError, .data = @intFromPtr(&err) }, .{} };
    base(gb).GetRPAttrs(@ptrCast(rp), &ask);
    try testing.expectEqual(graphics.GERR_BAD_FORMAT, err);

    // Reading it does not clear it: GetRPAttrs is the one call that leaves
    // it alone, or a read would be no read at all.
    err = 0;
    base(gb).GetRPAttrs(@ptrCast(rp), &ask);
    try testing.expectEqual(graphics.GERR_BAD_FORMAT, err);

    // The next call that works clears it.
    base(gb).RectFill(@ptrCast(rp), &.{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 });
    base(gb).GetRPAttrs(@ptrCast(rp), &ask);
    try testing.expectEqual(graphics.GERR_OK, err);

    // Every code has words, and one that does not exist still has some.
    try testing.expectEqualStrings("out of memory", std.mem.span(base(gb).GraphicsErrorText(graphics.GERR_NO_MEMORY)));
    try testing.expectEqualStrings("unknown error", std.mem.span(base(gb).GraphicsErrorText(-9999)));

    base(gb).FreeRastPort(@ptrCast(rp));
    base(gb).FreeRastPort(@ptrCast(wide_rp));
    try tearDown(gb);
}

/// The area of a region as its rectangles claim it: the sum of theirs.
fn claimedArea(region: *graphics.Region) i32 {
    const r: *regions.Region = @ptrCast(@alignCast(region));
    var total: i32 = 0;
    var at = r.head;
    while (at) |piece| : (at = piece.next) {
        total += piece.bounds.width() * piece.bounds.height();
    }
    return total;
}

/// The area as the region actually answers for it: every point in a grid
/// big enough to hold it, asked one at a time.
fn walkedArea(gb: *GraphicsBase, region: *graphics.Region, size: i32) i32 {
    var total: i32 = 0;
    var y: i32 = -2;
    while (y < size) : (y += 1) {
        var x: i32 = -2;
        while (x < size) : (x += 1) {
            if (base(gb).PointInRegion(region, x, y)) total += 1;
        }
    }
    return total;
}

/// The invariant that matters: the rectangles of a region never overlap.
///
/// If two of them did, the area they claim between them would be more than
/// the number of points actually inside. Checking it after every operation
/// is worth more than any number of examples, because overlap is the one
/// way a region can be wrong while looking right.
fn expectDisjoint(gb: *GraphicsBase, region: *graphics.Region, size: i32) !void {
    try testing.expectEqual(walkedArea(gb, region, size), claimedArea(region));
}

test "regions: a rectangle at a time, and never two covering one point" {
    const gb = try setUp();
    defer kexec.deinit();

    const region = base(gb).NewRegion() orelse return error.NoRegion;
    // Empty: nothing is inside and it claims nothing.
    try testing.expect(!base(gb).PointInRegion(region, 0, 0));
    try testing.expectEqual(@as(i32, 0), claimedArea(region));

    try testing.expect(base(gb).OrRectRegion(region, &.{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 }));
    try testing.expectEqual(@as(i32, 16), claimedArea(region));
    try testing.expect(base(gb).PointInRegion(region, 3, 3));
    // Half-open: the far edge is outside.
    try testing.expect(!base(gb).PointInRegion(region, 4, 0));
    try expectDisjoint(gb, region, 12);

    // Overlapping the first: the shared part must be counted once.
    try testing.expect(base(gb).OrRectRegion(region, &.{ .min_x = 2, .min_y = 2, .max_x = 6, .max_y = 6 }));
    try testing.expectEqual(@as(i32, 28), claimedArea(region));
    try expectDisjoint(gb, region, 12);

    // A hole through the middle of both.
    try testing.expect(base(gb).ClearRectRegion(region, &.{ .min_x = 1, .min_y = 1, .max_x = 5, .max_y = 5 }));
    try testing.expect(!base(gb).PointInRegion(region, 3, 3));
    try testing.expect(base(gb).PointInRegion(region, 0, 0));
    try testing.expect(base(gb).PointInRegion(region, 5, 5));
    try expectDisjoint(gb, region, 12);

    base(gb).DisposeRegion(region);
    base(gb).DisposeRegion(null);
    try tearDown(gb);
}

test "regions: and, sub and xor, against a rectangle and against a region" {
    const gb = try setUp();
    defer kexec.deinit();

    const a = base(gb).NewRegion() orelse return error.NoRegion;
    try testing.expect(base(gb).OrRectRegion(a, &.{ .min_x = 0, .min_y = 0, .max_x = 6, .max_y = 6 }));
    try testing.expect(base(gb).AndRectRegion(a, &.{ .min_x = 2, .min_y = 2, .max_x = 8, .max_y = 4 }));
    // What is left is only the overlap.
    try testing.expectEqual(@as(i32, 8), claimedArea(a));
    try testing.expect(base(gb).PointInRegion(a, 2, 2));
    try testing.expect(!base(gb).PointInRegion(a, 1, 2));
    try testing.expect(!base(gb).PointInRegion(a, 2, 4));
    try expectDisjoint(gb, a, 12);

    // Xor with a rectangle overlapping half of it: the shared half goes,
    // the rest of the rectangle arrives.
    try testing.expect(base(gb).XorRectRegion(a, &.{ .min_x = 4, .min_y = 2, .max_x = 10, .max_y = 4 }));
    try testing.expect(base(gb).PointInRegion(a, 2, 2));
    try testing.expect(!base(gb).PointInRegion(a, 4, 2));
    try testing.expect(base(gb).PointInRegion(a, 9, 3));
    try expectDisjoint(gb, a, 14);

    // Region against region.
    const b = base(gb).NewRegion() orelse return error.NoRegion;
    try testing.expect(base(gb).OrRectRegion(b, &.{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 }));
    const c = base(gb).NewRegion() orelse return error.NoRegion;
    try testing.expect(base(gb).OrRectRegion(c, &.{ .min_x = 2, .min_y = 0, .max_x = 6, .max_y = 2 }));

    try testing.expect(base(gb).SubRegionRegion(c, b));
    try testing.expect(!base(gb).PointInRegion(b, 3, 1));
    try testing.expect(base(gb).PointInRegion(b, 1, 1));
    try testing.expect(base(gb).PointInRegion(b, 3, 3));
    try expectDisjoint(gb, b, 10);

    try testing.expect(base(gb).OrRegionRegion(c, b));
    try testing.expect(base(gb).PointInRegion(b, 3, 1));
    try testing.expect(base(gb).PointInRegion(b, 5, 1));
    try expectDisjoint(gb, b, 10);

    try testing.expect(base(gb).AndRegionRegion(c, b));
    // Only what both hold.
    try testing.expectEqual(@as(i32, 8), claimedArea(b));
    try testing.expect(base(gb).PointInRegion(b, 5, 1));
    try testing.expect(!base(gb).PointInRegion(b, 1, 1));
    try expectDisjoint(gb, b, 10);

    base(gb).DisposeRegion(a);
    base(gb).DisposeRegion(b);
    base(gb).DisposeRegion(c);
    try tearDown(gb);
}

test "regions: the rectangles read back out, counted and in order" {
    const gb = try setUp();
    defer kexec.deinit();

    const region = base(gb).NewRegion().?;
    // An empty region has none, which is also how to ask whether it is.
    try testing.expectEqual(@as(u32, 0), base(gb).RegionRectangles(region, null, 0));

    // Put them in bottom-up and right-to-left, so the order out cannot be
    // the order in.
    _ = base(gb).OrRectRegion(region, &.{ .min_x = 40, .min_y = 20, .max_x = 50, .max_y = 30 });
    _ = base(gb).OrRectRegion(region, &.{ .min_x = 10, .min_y = 20, .max_x = 20, .max_y = 30 });
    _ = base(gb).OrRectRegion(region, &.{ .min_x = 0, .min_y = 0, .max_x = 5, .max_y = 5 });

    const count = base(gb).RegionRectangles(region, null, 0);
    try testing.expectEqual(@as(u32, 3), count);

    var out: [3]graphics.Rect = undefined;
    try testing.expectEqual(count, base(gb).RegionRectangles(region, &out, out.len));
    // Sorted by the top edge, then by the left.
    try testing.expectEqual(@as(i32, 0), out[0].min_y);
    try testing.expectEqual(@as(i32, 10), out[1].min_x);
    try testing.expectEqual(@as(i32, 40), out[2].min_x);

    // Asking for fewer than there are still answers how many there are,
    // and writes the first ones **in order** - not whichever happened to
    // be at the head of the list, which is what a caller with room for one
    // is asking for.
    var one: [1]graphics.Rect = .{.{ .min_x = -1 }};
    try testing.expectEqual(@as(u32, 3), base(gb).RegionRectangles(region, &one, 1));
    try testing.expectEqual(@as(i32, 0), one[0].min_x);
    try testing.expectEqual(@as(i32, 0), one[0].min_y);
    var two: [2]graphics.Rect = undefined;
    try testing.expectEqual(@as(u32, 3), base(gb).RegionRectangles(region, &two, 2));
    try testing.expectEqual(@as(i32, 0), two[0].min_y);
    try testing.expectEqual(@as(i32, 10), two[1].min_x);
    // And none at all is legal: it is how the count is asked for.
    try testing.expectEqual(@as(u32, 3), base(gb).RegionRectangles(region, &one, 0));

    base(gb).DisposeRegion(region);
    try tearDown(gb);
}

test "regions: offset moves all of it, and clear leaves it usable" {
    const gb = try setUp();
    defer kexec.deinit();

    const region = base(gb).NewRegion() orelse return error.NoRegion;
    try testing.expect(base(gb).OrRectRegion(region, &.{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }));
    try testing.expect(base(gb).OrRectRegion(region, &.{ .min_x = 4, .min_y = 4, .max_x = 6, .max_y = 6 }));
    const before = claimedArea(region);

    base(gb).OffsetRegion(region, 3, 1);
    try testing.expectEqual(before, claimedArea(region));
    try testing.expect(base(gb).PointInRegion(region, 3, 1));
    try testing.expect(!base(gb).PointInRegion(region, 0, 0));
    try testing.expect(base(gb).PointInRegion(region, 7, 5));
    try expectDisjoint(gb, region, 14);

    // An empty region takes an offset without minding, and stays empty.
    base(gb).ClearRegion(region);
    try testing.expectEqual(@as(i32, 0), claimedArea(region));
    base(gb).OffsetRegion(region, 100, 100);
    try testing.expect(!base(gb).PointInRegion(region, 100, 100));

    // And it can be built up again afterwards.
    try testing.expect(base(gb).OrRectRegion(region, &.{ .min_x = 1, .min_y = 1, .max_x = 3, .max_y = 3 }));
    try testing.expectEqual(@as(i32, 4), claimedArea(region));
    try expectDisjoint(gb, region, 8);

    base(gb).DisposeRegion(region);
    try tearDown(gb);
}

test "a clip region cuts every drawing call, and nothing above it changed" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    const rp = try onMemory(gb, &surface, &white);

    // Two squares with a gap between them.
    const region = base(gb).NewRegion() orelse return error.NoRegion;
    try testing.expect(base(gb).OrRectRegion(region, &.{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }));
    try testing.expect(base(gb).OrRectRegion(region, &.{ .min_x = 5, .min_y = 0, .max_x = 7, .max_y = 2 }));
    const install = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRegion, .data = @intFromPtr(region) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &install);

    // A fill over everything lands only inside the region.
    base(gb).RectFill(@ptrCast(rp), &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 });
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 0, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 6, 1));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 3, 0)); // the gap
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 0, 2)); // below it

    // A line across the gap is cut by it too - the same iterator, so it
    // needed no change of its own.
    const red = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 0, 0) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &red);
    base(gb).Move(@ptrCast(rp), 0, 1);
    base(gb).Draw(@ptrCast(rp), 7, 1);
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 1, 1));
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 6, 1));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 3, 1));

    // Taking the region away again leaves the clip rectangle alone.
    const off = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRegion, .data = 0 }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &off);
    var held: usize = 1;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRegion, .data = @intFromPtr(&held) }, .{} };
    base(gb).GetRPAttrs(@ptrCast(rp), &ask);
    try testing.expectEqual(@as(usize, 0), held);
    base(gb).RectFill(@ptrCast(rp), &.{ .min_x = 3, .min_y = 3, .max_x = 4, .max_y = 4 });
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 3, 3));

    base(gb).DisposeRegion(region);
    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

/// How many pixels of a surface are not black.
fn litCount(surface: *const rtg.Surface) u32 {
    var n: u32 = 0;
    var y: u32 = 0;
    while (y < surface.height) : (y += 1) {
        var x: u32 = 0;
        while (x < surface.width) : (x += 1) {
            if (pixelAt(surface, x, y) != 0) n += 1;
        }
    }
    return n;
}

test "pixels: written, read back, and clipped" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const red = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 0, 0) }, .{} };
    const rp = try onMemory(gb, &surface, &red);

    base(gb).WritePixel(@ptrCast(rp), 2, 1);
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 2, 1));

    // Read gives the colour back, through the format and out again.
    var pen: graphics.Pen = 0;
    try testing.expect(base(gb).ReadPixel(@ptrCast(rp), 2, 1, &pen));
    try testing.expectEqual(graphics.penRGB(255, 0, 0), pen);

    // Outside the surface is false, and what was there is left alone.
    pen = 0x1234;
    try testing.expect(!base(gb).ReadPixel(@ptrCast(rp), 99, 1, &pen));
    try testing.expectEqual(@as(graphics.Pen, 0x1234), pen);

    // A clip stops a write but not a read: a clip says what may be
    // written, and putting back what was covered needs to read it.
    const clip = graphics.Rect{ .min_x = 4, .min_y = 0, .max_x = 8, .max_y = 4 };
    const narrow = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &narrow);
    base(gb).WritePixel(@ptrCast(rp), 0, 0);
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 0, 0));
    try testing.expect(base(gb).ReadPixel(@ptrCast(rp), 2, 1, &pen));
    try testing.expectEqual(graphics.penRGB(255, 0, 0), pen);

    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "clip targets: one call, two surfaces, and window coordinates" {
    const gb = try setUp();
    defer kexec.deinit();

    // A screen, and somewhere to keep the part of a window that is covered.
    var screen_pixels: [16 * 8 * 2]u8 = @splat(0);
    var screen = rtg.Surface{
        .pixels = &screen_pixels,
        .width = 16,
        .height = 8,
        .pitch = 16 * 2,
        .size_bytes = screen_pixels.len,
        .format = .rgb565,
    };
    var kept_pixels: [8 * 4 * 2]u8 = @splat(0);
    var kept = rtg.Surface{
        .pixels = &kept_pixels,
        .width = 8,
        .height = 4,
        .pitch = 8 * 2,
        .size_bytes = kept_pixels.len,
        .format = .rgb565,
    };

    // A window 8 wide and 4 high, sitting at (8,2) on the screen, whose
    // right-hand half is covered by something in front of it. Its left
    // half goes to the screen and its right half is kept instead - and it
    // draws in its own coordinates either way, which is what the offsets
    // are for.
    var covered = graphics.ClipTarget{
        .rect = .{ .min_x = 4, .min_y = 0, .max_x = 8, .max_y = 4 },
        .surface = &kept,
        .dx = -4,
        .dy = 0,
    };
    var on_screen = graphics.ClipTarget{
        .rect = .{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 },
        .surface = &screen,
        .dx = 8,
        .dy = 2,
        .next = &covered,
    };

    const window = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 };
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 0, 0) },
        .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&window) },
        .{ .tag = graphics.RPTAG_ClipTargets, .data = @intFromPtr(&on_screen) },
        .{},
    };
    const rp = try onMemory(gb, &screen, &tags);

    // One call, filling the whole window in its own coordinates.
    base(gb).RectFill(@ptrCast(rp), &window);

    // The visible half landed on the screen where the window sits.
    var y: u32 = 0;
    while (y < 8) : (y += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) {
            const inside = x >= 8 and x < 12 and y >= 2 and y < 6;
            const want: u16 = if (inside) 0xF800 else 0;
            try testing.expectEqual(want, pixelAt(&screen, x, y));
        }
    }
    // The covered half went to the other surface, at its own corner - and
    // nothing of it reached the screen, which is the whole point.
    y = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 8) : (x += 1) {
            const want: u16 = if (x < 4) 0xF800 else 0;
            try testing.expectEqual(want, pixelAt(&kept, x, y));
        }
    }

    // A pixel written in window coordinates goes wherever that part of the
    // window is, and reading it back comes from the same place.
    const green = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 255, 0) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &green);
    base(gb).WritePixel(@ptrCast(rp), 6, 3);
    try testing.expectEqual(@as(u16, 0x07E0), pixelAt(&kept, 2, 3));
    base(gb).WritePixel(@ptrCast(rp), 1, 1);
    try testing.expectEqual(@as(u16, 0x07E0), pixelAt(&screen, 9, 3));

    var pen: graphics.Pen = 0;
    try testing.expect(base(gb).ReadPixel(@ptrCast(rp), 6, 3, &pen));
    try testing.expectEqual(graphics.penRGB(0, 255, 0), pen);

    // The point-at-a-time path the curves take finds its target the same
    // way: this circle crosses the join and both halves get some of it.
    const blue = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 0, 255) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &blue);
    base(gb).DrawCircle(@ptrCast(rp), 4, 2, 2);
    var on_left: u32 = 0;
    var on_right: u32 = 0;
    for (0..4) |ry| {
        for (0..4) |rx| {
            if (pixelAt(&screen, @intCast(rx + 8), @intCast(ry + 2)) == 0x001F) on_left += 1;
            if (pixelAt(&kept, @intCast(rx), @intCast(ry)) == 0x001F) on_right += 1;
        }
    }
    try testing.expect(on_left > 0);
    try testing.expect(on_right > 0);

    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "runs and outlines: every edge once, and no corner twice" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    const rp = try onMemory(gb, &surface, &white);

    base(gb).DrawHLine(@ptrCast(rp), 1, 0, 3);
    try testing.expectEqual(@as(u32, 3), litCount(&surface));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 3, 0));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 4, 0));

    base(gb).DrawVLine(@ptrCast(rp), 7, 1, 3);
    try testing.expectEqual(@as(u32, 6), litCount(&surface));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 7, 3));

    // A length of nothing draws nothing.
    base(gb).DrawHLine(@ptrCast(rp), 0, 0, 0);
    base(gb).DrawVLine(@ptrCast(rp), 0, 0, -5);
    try testing.expectEqual(@as(u32, 6), litCount(&surface));

    // An outline: 4x3 has 2*4 + 2*(3-2) = 10 pixels, and each exactly
    // once - which COMPLEMENT below depends on.
    @memset(&pixels, 0);
    base(gb).DrawRect(@ptrCast(rp), &.{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 3 });
    try testing.expectEqual(@as(u32, 10), litCount(&surface));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 1, 1)); // hollow

    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "draw modes: JAM2 lays down both pens, COMPLEMENT undoes itself" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [16 * 4 * 2]u8 = @splat(0);
    var surface = rtg.Surface{
        .pixels = &pixels,
        .width = 16,
        .height = 4,
        .pitch = 32,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    // Every other pixel drawn, foreground red, background blue.
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 0, 0) },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(0, 0, 255) },
        .{ .tag = graphics.RPTAG_LinePattern, .data = 0xAAAA },
        .{},
    };
    const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;

    // JAM1: the clear bits draw nothing at all.
    base(gb).DrawHLine(rp, 0, 0, 8);
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 0, 0));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 1, 0));
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 2, 0));

    // JAM2: the clear bits draw the background instead.
    const jam2 = [_]TagItem{
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM2 },
        .{ .tag = graphics.RPTAG_LinePattern, .data = 0xAAAA },
        .{},
    };
    base(gb).SetRPAttrs(rp, &jam2);
    base(gb).DrawHLine(rp, 0, 1, 8);
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 0, 1));
    try testing.expectEqual(@as(u16, 0x001F), pixelAt(&surface, 1, 1));

    // INVERSVID swaps which bit means which pen.
    const inverse = [_]TagItem{
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM2 | graphics.DRMD_INVERSVID },
        .{ .tag = graphics.RPTAG_LinePattern, .data = 0xAAAA },
        .{},
    };
    base(gb).SetRPAttrs(rp, &inverse);
    base(gb).DrawHLine(rp, 0, 2, 8);
    try testing.expectEqual(@as(u16, 0x001F), pixelAt(&surface, 0, 2));
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 1, 2));

    // COMPLEMENT: drawing the same thing twice puts the surface back, which
    // is the whole use of it.
    const complement = [_]TagItem{
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_COMPLEMENT },
        .{ .tag = graphics.RPTAG_LinePattern, .data = graphics.LINE_SOLID },
        .{},
    };
    base(gb).SetRPAttrs(rp, &complement);
    const before = litCount(&surface);
    base(gb).DrawRect(rp, &.{ .min_x = 0, .min_y = 0, .max_x = 6, .max_y = 4 });
    try testing.expect(litCount(&surface) != before);
    base(gb).SetRPAttrs(rp, &complement);
    base(gb).DrawRect(rp, &.{ .min_x = 0, .min_y = 0, .max_x = 6, .max_y = 4 });
    try testing.expectEqual(before, litCount(&surface));

    base(gb).FreeRastPort(rp);
    try tearDown(gb);
}

test "curves: circles, ellipses, arcs and polygons" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 32 * 2]u8 = @splat(0);
    var surface = rtg.Surface{
        .pixels = &pixels,
        .width = 32,
        .height = 32,
        .pitch = 64,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) },
        .{},
    };
    const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;

    // A circle passes through its four cardinal points and nowhere near
    // its middle.
    base(gb).DrawCircle(rp, 16, 16, 10);
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 26, 16));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 6, 16));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 16, 26));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 16, 16));

    // An ellipse reaches further one way than the other.
    @memset(&pixels, 0);
    base(gb).DrawEllipse(rp, 16, 16, 12, 5);
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 28, 16));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 16, 21));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 16, 26));

    // A quarter arc, 0 to 90, is up and to the right - and nowhere else.
    @memset(&pixels, 0);
    base(gb).DrawArc(rp, 16, 16, 10, 0, 90);
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 26, 16));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 16, 6));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 6, 16));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 16, 26));
    // An arc of nothing draws nothing.
    const lit = litCount(&surface);
    base(gb).DrawArc(rp, 16, 16, 10, 45, 45);
    try testing.expectEqual(lit, litCount(&surface));

    // A polygon, closed by repeating its first point, leaves the current
    // point where it started.
    @memset(&pixels, 0);
    const corners = [_]graphics.Point{
        .{ .x = 26, .y = 6 }, .{ .x = 26, .y = 26 }, .{ .x = 6, .y = 26 }, .{ .x = 6, .y = 6 },
    };
    base(gb).Move(rp, 6, 6);
    base(gb).DrawPoly(rp, corners.len, &corners);
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 16, 6));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 26, 16));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 16, 26));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 16, 16));
    var at: graphics.Point = .{};
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_Cursor, .data = @intFromPtr(&at) }, .{} };
    base(gb).GetRPAttrs(rp, &ask);
    try testing.expectEqual(graphics.Point{ .x = 6, .y = 6 }, at);

    // Everything above is clipped like everything else.
    const clip = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 16, .max_y = 32 };
    const half = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) }, .{} };
    base(gb).SetRPAttrs(rp, &half);
    @memset(&pixels, 0);
    base(gb).DrawCircle(rp, 16, 16, 10);
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 26, 16));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 6, 16));

    base(gb).FreeRastPort(rp);
    try tearDown(gb);
}

test "curves are clipped to a region a piece at a time, and the walk is remembered" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    var surface = memorySurface(&pixels, .rgb565);
    const red = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 0, 0) }, .{} };
    const rp = try onMemory(gb, &surface, &red);

    // Two separate rectangles with a gap between them, so a curve crossing
    // the gap has to find its way back and forth between the pieces - and
    // the piece it last landed in is no help for the first point after a
    // crossing, which is what makes this worth testing.
    const region = base(gb).NewRegion().?;
    _ = base(gb).OrRectRegion(region, &.{ .min_x = 0, .min_y = 0, .max_x = 3, .max_y = 4 });
    _ = base(gb).OrRectRegion(region, &.{ .min_x = 5, .min_y = 0, .max_x = 8, .max_y = 4 });
    const clip = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRegion, .data = @intFromPtr(region) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &clip);

    base(gb).DrawCircle(@ptrCast(rp), 4, 2, 3);

    // Nothing in the gap, whatever the circle wanted.
    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 3, y));
        try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 4, y));
    }
    // And something in each of the two pieces, or the test proves nothing.
    var left: u32 = 0;
    var right: u32 = 0;
    y = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 3) : (x += 1) {
            if (pixelAt(&surface, x, y) != 0) left += 1;
            if (pixelAt(&surface, x + 5, y) != 0) right += 1;
        }
    }
    try testing.expect(left > 0);
    try testing.expect(right > 0);

    // Taking the region off must take what was remembered of it with it,
    // or a point outside the old pieces would still be answered from one.
    const none = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRegion, .data = 0 }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &none);
    base(gb).WritePixel(@ptrCast(rp), 3, 1);
    try testing.expect(pixelAt(&surface, 3, 1) != 0);

    base(gb).DisposeRegion(region);
    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "areas: a filled shape, a hole in it, and room given back" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 32 * 2]u8 = @splat(0);
    var surface = rtg.Surface{
        .pixels = &pixels,
        .width = 32,
        .height = 32,
        .pitch = 64,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) },
        .{},
    };
    const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;

    // Corners before InitArea have nowhere to go, and say so.
    try testing.expect(!base(gb).AreaMove(rp, 0, 0));
    var err: i32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_LastError, .data = @intFromPtr(&err) }, .{} };
    base(gb).GetRPAttrs(rp, &ask);
    try testing.expectEqual(graphics.GERR_NO_MEMORY, err);

    try testing.expect(base(gb).InitArea(rp, 512));
    // A corner with no shape begun is the caller's slip.
    try testing.expect(!base(gb).AreaDraw(rp, 1, 1));

    // A solid square.
    try testing.expect(base(gb).AreaMove(rp, 8, 8));
    try testing.expect(base(gb).AreaDraw(rp, 24, 8));
    try testing.expect(base(gb).AreaDraw(rp, 24, 24));
    try testing.expect(base(gb).AreaDraw(rp, 8, 24));
    try testing.expect(base(gb).AreaEnd(rp));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 16, 16));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 9, 9));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 4, 16));

    // The same square with a circle inside it: even-odd makes the circle a
    // hole, with nothing said about which way round either was wound.
    @memset(&pixels, 0);
    try testing.expect(base(gb).AreaMove(rp, 6, 6));
    try testing.expect(base(gb).AreaDraw(rp, 26, 6));
    try testing.expect(base(gb).AreaDraw(rp, 26, 26));
    try testing.expect(base(gb).AreaDraw(rp, 6, 26));
    try testing.expect(base(gb).AreaCircle(rp, 16, 16, 6));
    try testing.expect(base(gb).AreaEnd(rp));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 16, 16)); // the hole
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 8, 8)); // the corner

    // A filled ellipse reaches further one way than the other.
    @memset(&pixels, 0);
    try testing.expect(base(gb).AreaEllipse(rp, 16, 16, 12, 4));
    try testing.expect(base(gb).AreaEnd(rp));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 16, 16));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 26, 16));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 16, 26));

    // A wedge from 0 to 90 is up and to the right of the middle.
    @memset(&pixels, 0);
    try testing.expect(base(gb).AreaArc(rp, 16, 16, 10, 0, 90));
    try testing.expect(base(gb).AreaEnd(rp));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 20, 12));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 12, 20));

    // Nothing collected fills nothing, and is not a failure.
    try testing.expect(base(gb).AreaEnd(rp));

    // Filling is clipped like everything else.
    @memset(&pixels, 0);
    const clip = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 16, .max_y = 32 };
    const half = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) }, .{} };
    base(gb).SetRPAttrs(rp, &half);
    try testing.expect(base(gb).AreaMove(rp, 4, 4));
    try testing.expect(base(gb).AreaDraw(rp, 28, 4));
    try testing.expect(base(gb).AreaDraw(rp, 28, 28));
    try testing.expect(base(gb).AreaDraw(rp, 4, 28));
    try testing.expect(base(gb).AreaEnd(rp));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 10, 16));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 20, 16));

    // Room runs out rather than being overrun.
    try testing.expect(base(gb).InitArea(rp, 4));
    try testing.expect(base(gb).AreaMove(rp, 0, 0));
    try testing.expect(base(gb).AreaDraw(rp, 1, 0));
    try testing.expect(base(gb).AreaDraw(rp, 1, 1));
    try testing.expect(base(gb).AreaDraw(rp, 0, 1));
    try testing.expect(!base(gb).AreaDraw(rp, 0, 2));
    base(gb).GetRPAttrs(rp, &ask);
    try testing.expectEqual(graphics.GERR_BAD_SIZE, err);

    // 0 gives the room back, and the RastPort takes whatever is left with
    // it - which expectNoLeaks is what checks.
    try testing.expect(base(gb).InitArea(rp, 0));
    try testing.expect(base(gb).InitArea(rp, 16));
    try testing.expect(base(gb).AreaMove(rp, 0, 0));

    base(gb).FreeRastPort(rp);
    try tearDown(gb);
}

test "fonts: two Pospaz in the ROM, told apart by height" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [64 * 16 * 2]u8 = @splat(0);
    var surface = rtg.Surface{
        .pixels = &pixels,
        .width = 64,
        .height = 16,
        .pitch = 128,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(0, 0, 255) },
        .{},
    };
    const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;

    // No font is not an error: nothing is drawn and the width is 0.
    try testing.expectEqual(@as(i32, 0), base(gb).TextLength(rp, "abc", 3));
    base(gb).Move(rp, 0, 8);
    base(gb).Text(rp, "abc", 3);
    try testing.expectEqual(@as(u32, 0), litCount(&surface));

    // A height that is not there is null, and a name that is not there.
    try testing.expect(base(gb).OpenFont(graphics.POSPAZNAME, 10) == null);
    try testing.expect(base(gb).OpenFont("nosuch.font", 8) == null);

    const font = base(gb).OpenFont(graphics.POSPAZNAME, 8) orelse return error.NoFont;
    const use = [_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) }, .{} };
    base(gb).SetRPAttrs(rp, &use);

    var height: u32 = 0;
    var width: u32 = 0;
    var baseline: u32 = 0;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{ .tag = graphics.RPTAG_FontWidth, .data = @intFromPtr(&width) },
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{},
    };
    base(gb).GetRPAttrs(rp, &ask);
    try testing.expectEqual(@as(u32, 8), height);
    try testing.expectEqual(@as(u32, 8), width);
    try testing.expectEqual(@as(u32, 6), baseline);
    try testing.expectEqual(@as(i32, 24), base(gb).TextLength(rp, "abc", 3));

    // Pospaz 16 is Pospaz 8 twice as tall: the same columns, every row
    // drawn twice.
    const sixteen = base(gb).OpenFont(graphics.POSPAZNAME, 16) orelse return error.NoFont;
    const use16 = [_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(sixteen) }, .{} };
    base(gb).SetRPAttrs(rp, &use16);
    base(gb).GetRPAttrs(rp, &ask);
    try testing.expectEqual(@as(u32, 16), height);
    try testing.expectEqual(@as(u32, 8), width);
    try testing.expectEqual(@as(u32, 13), baseline);
    const eight_rows: [*]const u16 = @as(*fonts.TextFont, @ptrCast(@alignCast(font))).rows;
    const sixteen_rows: [*]const u16 = @as(*fonts.TextFont, @ptrCast(@alignCast(sixteen))).rows;
    const glyph_a = ('A' - 32);
    for (0..8) |row| {
        try testing.expectEqual(eight_rows[glyph_a * 8 + row], sixteen_rows[glyph_a * 16 + 2 * row]);
        try testing.expectEqual(eight_rows[glyph_a * 8 + row], sixteen_rows[glyph_a * 16 + 2 * row + 1]);
    }
    try testing.expect(base(gb).OpenFont(graphics.POSPAZNAME, 9) == null);
    try testing.expect(base(gb).OpenFont(graphics.POSPAZNAME, 11) == null);
    base(gb).CloseFont(sixteen);
    base(gb).CloseFont(null);

    base(gb).SetRPAttrs(rp, &use);
    base(gb).FreeRastPort(rp);
    base(gb).CloseFont(font);
    try tearDown(gb);
}

test "text: ink, paper, styles and the baseline" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [64 * 16 * 2]u8 = @splat(0);
    var surface = rtg.Surface{
        .pixels = &pixels,
        .width = 64,
        .height = 16,
        .pitch = 128,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const font = base(gb).OpenFont(graphics.POSPAZNAME, 8) orelse return error.NoFont;
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(0, 0, 255) },
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) },
        .{},
    };
    const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;

    // JAM1: ink only, and the point ends past the last letter.
    base(gb).Move(rp, 0, 6);
    base(gb).Text(rp, "A", 1);
    const inked = litCount(&surface);
    try testing.expect(inked > 0);
    var at: graphics.Point = .{};
    const where = [_]TagItem{ .{ .tag = graphics.RPTAG_Cursor, .data = @intFromPtr(&at) }, .{} };
    base(gb).GetRPAttrs(rp, &where);
    try testing.expectEqual(@as(i32, 8), at.x);
    // The point is the baseline, so the glyph sits above it: row 6 is the
    // baseline and nothing is drawn below the font's last row.
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 0, 8));

    // JAM2: the paper goes down too, so every pixel of the cell is
    // covered - which is what makes text over a picture readable.
    @memset(&pixels, 0);
    const jam2 = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM2 }, .{} };
    base(gb).SetRPAttrs(rp, &jam2);
    base(gb).Move(rp, 0, 6);
    base(gb).Text(rp, "A", 1);
    try testing.expectEqual(@as(u32, 64), litCount(&surface)); // 8 by 8, all of it
    try testing.expect(pixelAt(&surface, 0, 0) == 0x001F or pixelAt(&surface, 0, 0) == 0xFFFF);

    // Bold widens by one and draws more.
    @memset(&pixels, 0);
    const plain = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
    base(gb).SetRPAttrs(rp, &plain);
    base(gb).Move(rp, 0, 6);
    base(gb).Text(rp, "A", 1);
    const thin = litCount(&surface);
    @memset(&pixels, 0);
    const bold = [_]TagItem{ .{ .tag = graphics.RPTAG_TextStyle, .data = graphics.FSF_BOLD }, .{} };
    base(gb).SetRPAttrs(rp, &bold);
    try testing.expectEqual(@as(i32, 9), base(gb).TextLength(rp, "A", 1));
    base(gb).Move(rp, 0, 6);
    base(gb).Text(rp, "A", 1);
    try testing.expect(litCount(&surface) > thin);

    // Underlined puts a run along the bottom of the whole string.
    @memset(&pixels, 0);
    const under = [_]TagItem{ .{ .tag = graphics.RPTAG_TextStyle, .data = graphics.FSF_UNDERLINED }, .{} };
    base(gb).SetRPAttrs(rp, &under);
    base(gb).Move(rp, 0, 6);
    base(gb).Text(rp, "AB", 2);
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 0, 7));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 15, 7));

    // And text is clipped like everything else.
    @memset(&pixels, 0);
    const plain2 = [_]TagItem{ .{ .tag = graphics.RPTAG_TextStyle, .data = graphics.FS_NORMAL }, .{} };
    base(gb).SetRPAttrs(rp, &plain2);
    const clip = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 16 };
    const narrow = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) }, .{} };
    base(gb).SetRPAttrs(rp, &narrow);
    base(gb).Move(rp, 0, 6);
    base(gb).Text(rp, "AAAA", 4);
    var x: u32 = 8;
    while (x < 32) : (x += 1) {
        var y: u32 = 0;
        while (y < 8) : (y += 1) try testing.expectEqual(@as(u16, 0), pixelAt(&surface, x, y));
    }

    base(gb).FreeRastPort(rp);
    base(gb).CloseFont(font);
    try tearDown(gb);
}

test "blits: a template stencilled, a pattern tiled, a mask letting through" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [16 * 8 * 2]u8 = @splat(0);
    var surface = rtg.Surface{
        .pixels = &pixels,
        .width = 16,
        .height = 8,
        .pitch = 32,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(0, 0, 255) },
        .{},
    };
    const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;

    // A 4x4 shape: the left half of each row set.
    const shape = [_]u8{ 0xF0, 0xF0, 0xF0, 0xF0 };

    // JAM1: the clear half is left alone.
    base(gb).BltTemplate(@ptrCast(rp), &shape, 1, 0, 0, &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 });
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 0, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 3, 3));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 4, 0));

    // JAM2: the clear half takes the background pen.
    @memset(&pixels, 0);
    const jam2 = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM2 }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &jam2);
    base(gb).BltTemplate(@ptrCast(rp), &shape, 1, 0, 0, &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 });
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 0, 0));
    try testing.expectEqual(@as(u16, 0x001F), pixelAt(&surface, 4, 0));

    // A clipped template is cut, not slid: the part that lands is the part
    // of the shape that belongs there.
    @memset(&pixels, 0);
    const jam1 = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &jam1);
    const clip = graphics.Rect{ .min_x = 2, .min_y = 0, .max_x = 16, .max_y = 8 };
    const narrow = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &narrow);
    base(gb).BltTemplate(@ptrCast(rp), &shape, 1, 0, 0, &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 });
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 1, 0)); // clipped away
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 2, 0)); // still shape
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 4, 0)); // still clear half

    // A pattern is anchored to the surface, so two rectangles of it line
    // up where they meet rather than each starting afresh.
    @memset(&pixels, 0);
    const all = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 16, .max_y = 8 };
    const wide = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&all) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &wide);
    // A 2x2 checker: one pixel of each row set, alternating.
    const tile = [_]u8{ 0x80, 0x40 };
    base(gb).BltPattern(@ptrCast(rp), &tile, 1, 2, 2, &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 });
    base(gb).BltPattern(@ptrCast(rp), &tile, 1, 2, 2, &.{ .min_x = 8, .min_y = 0, .max_x = 16, .max_y = 4 });
    // The same phase either side of the join, because both are measured
    // from the surface and not from their own rectangle.
    try testing.expectEqual(pixelAt(&surface, 0, 0), pixelAt(&surface, 8, 0));
    try testing.expectEqual(pixelAt(&surface, 1, 0), pixelAt(&surface, 9, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 0, 0));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 1, 0));
    // A tile of no size is refused rather than dividing by it.
    base(gb).BltPattern(@ptrCast(rp), &tile, 1, 0, 2, &all);
    var err: i32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_LastError, .data = @intFromPtr(&err) }, .{} };
    base(gb).GetRPAttrs(@ptrCast(rp), &ask);
    try testing.expectEqual(graphics.GERR_BAD_SIZE, err);

    // A masked blit lets through only what the mask covers.
    @memset(&pixels, 0);
    var from_pixels: [16 * 8 * 2]u8 = @splat(0);
    var from = rtg.Surface{
        .pixels = &from_pixels,
        .width = 16,
        .height = 8,
        .pitch = 32,
        .size_bytes = from_pixels.len,
        .format = .rgb565,
    };
    const red = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 0, 0) }, .{} };
    const src = try onMemory(gb, &from, &red);
    base(gb).RectFill(@ptrCast(src), &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 });

    base(gb).BltMaskRastPort(@ptrCast(src), @ptrCast(rp), &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 }, 0, 0, &shape, 1);
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 0, 0));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 4, 0)); // the mask said no

    base(gb).FreeRastPort(@ptrCast(src));
    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}

test "bitmap blits: no state on the source side, and a stretch" {
    const gb = try setUp();
    defer kexec.deinit();

    var from_pixels: [8 * 4 * 2]u8 = @splat(0);
    var from = memorySurface(&from_pixels, .rgb565);
    var to_pixels: [16 * 8 * 2]u8 = @splat(0);
    var to = rtg.Surface{
        .pixels = &to_pixels,
        .width = 16,
        .height = 8,
        .pitch = 32,
        .size_bytes = to_pixels.len,
        .format = .rgb565,
    };

    // Paint the source through a RastPort, then move it with none - the
    // source of a blit has no drawing state, which is the point of these.
    const red = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 0, 0) }, .{} };
    const painter = try onMemory(gb, &from, &red);
    base(gb).RectFill(@ptrCast(painter), &.{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 2 });
    base(gb).FreeRastPort(@ptrCast(painter));

    // Surface to surface: no clip, no mode, nothing handed on.
    try testing.expectEqual(graphics.GERR_OK, base(gb).BltBitMap(&from, 0, 0, &to, 2, 1, 4, 2));
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&to, 2, 1));
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&to, 5, 2));
    try testing.expectEqual(@as(u16, 0), pixelAt(&to, 6, 1));
    // What falls off the far side is simply not moved.
    try testing.expectEqual(graphics.GERR_OK, base(gb).BltBitMap(&from, 0, 0, &to, 14, 6, 4, 2));
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&to, 15, 6));
    // Two formats are refused, and say so: there is no RastPort to ask.
    var other_pixels: [8 * 4 * 4]u8 = @splat(0);
    var other = memorySurface(&other_pixels, .bgra32);
    try testing.expectEqual(graphics.GERR_BAD_FORMAT, base(gb).BltBitMap(&other, 0, 0, &to, 0, 0, 2, 2));

    // Into a RastPort: the clip decides what lands.
    @memset(&to_pixels, 0);
    const clip = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 8 };
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&to) },
        .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) },
        .{},
    };
    const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;
    base(gb).BltBitMapRastPort(&from, 0, 0, rp, 2, 0, 4, 2);
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&to, 3, 0));
    try testing.expectEqual(@as(u16, 0), pixelAt(&to, 4, 0)); // clipped

    // A format it would have to convert is refused rather than half done.
    var wide_pixels: [8 * 4 * 4]u8 = @splat(0);
    var wide = memorySurface(&wide_pixels, .bgra32);
    base(gb).BltBitMapRastPort(&wide, 0, 0, rp, 0, 0, 2, 2);
    var err: i32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_LastError, .data = @intFromPtr(&err) }, .{} };
    base(gb).GetRPAttrs(rp, &ask);
    try testing.expectEqual(graphics.GERR_BAD_FORMAT, err);

    // Through a mask: only what it covers.
    @memset(&to_pixels, 0);
    const all = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 16, .max_y = 8 };
    const open = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&all) }, .{} };
    base(gb).SetRPAttrs(rp, &open);
    const mask = [_]u8{ 0xC0, 0xC0 }; // the left two columns of each row
    base(gb).BltMaskBitMapRastPort(&from, 0, 0, rp, 0, 0, 4, 2, &mask, 1);
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&to, 0, 0));
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&to, 1, 1));
    try testing.expectEqual(@as(u16, 0), pixelAt(&to, 2, 0)); // the mask said no

    // Stretched: a 4x2 patch fills 8x4, so each source pixel covers four.
    @memset(&to_pixels, 0);
    base(gb).BitMapScale(&from, &.{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 2 }, rp, &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 });
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&to, 0, 0));
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&to, 7, 3));
    try testing.expectEqual(@as(u16, 0), pixelAt(&to, 8, 0));
    // An empty rectangle either way is refused rather than divided by.
    base(gb).BitMapScale(&from, &.{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 2 }, rp, &.{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 4 });
    base(gb).GetRPAttrs(rp, &ask);
    try testing.expectEqual(graphics.GERR_BAD_SIZE, err);

    base(gb).FreeRastPort(rp);
    try tearDown(gb);
}

test "measuring text: the room it takes, and how much of it fits" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [64 * 16 * 2]u8 = @splat(0);
    var surface = rtg.Surface{
        .pixels = &pixels,
        .width = 64,
        .height = 16,
        .pitch = 128,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) }, .{} };
    const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;

    // With no font there is no room and nothing fits - and it says so,
    // because drawing nothing when asked to draw is a failure and not an
    // answer. Opening a font does not put it on a RastPort.
    var room: graphics.TextExtent = .{ .width = 99, .height = 99 };
    base(gb).TextExtent(rp, "abc", 3, &room);
    try testing.expectEqual(@as(i32, 0), room.width);
    var why: i32 = 0;
    const ask_why = [_]TagItem{ .{ .tag = graphics.RPTAG_LastError, .data = @intFromPtr(&why) }, .{} };
    base(gb).GetRPAttrs(rp, &ask_why);
    try testing.expectEqual(graphics.GERR_NO_FONT, why);
    base(gb).Move(rp, 0, 8);
    base(gb).Text(rp, "abc", 3);
    base(gb).GetRPAttrs(rp, &ask_why);
    try testing.expectEqual(graphics.GERR_NO_FONT, why);
    try testing.expectEqualStrings("the RastPort has no font set", std.mem.span(base(gb).GraphicsErrorText(why)));
    try testing.expectEqual(@as(u32, 0), base(gb).TextFit(rp, "abc", 3, &room, null, graphics.TEXT_FORWARD, 100, 100));

    const font = base(gb).OpenFont(graphics.POSPAZNAME, 8) orelse return error.NoFont;
    const use = [_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) }, .{} };
    base(gb).SetRPAttrs(rp, &use);

    base(gb).TextExtent(rp, "abcd", 4, &room);
    try testing.expectEqual(@as(i32, 32), room.width);
    try testing.expectEqual(@as(i32, 8), room.height);
    // Relative to the point: up by the baseline, down by the rest, and
    // half-open so the height is a subtraction.
    try testing.expectEqual(@as(i32, -6), room.extent.min_y);
    try testing.expectEqual(@as(i32, 2), room.extent.max_y);
    try testing.expectEqual(room.height, room.extent.max_y - room.extent.min_y);
    try testing.expectEqual(room.width, room.extent.max_x - room.extent.min_x);
    // The same number TextLength gives, because they measure one thing.
    try testing.expectEqual(base(gb).TextLength(rp, "abcd", 4), room.width);

    // Room for two and a half characters fits two, and says how wide they
    // are rather than how wide the room was.
    try testing.expectEqual(@as(u32, 2), base(gb).TextFit(rp, "abcd", 4, &room, null, graphics.TEXT_FORWARD, 20, 0));
    try testing.expectEqual(@as(i32, 16), room.width);
    // Room for all of it fits all of it and no more.
    try testing.expectEqual(@as(u32, 4), base(gb).TextFit(rp, "abcd", 4, &room, null, graphics.TEXT_FORWARD, 1000, 0));
    // A font taller than the room fits nothing: half a letter is not a
    // letter that fits.
    try testing.expectEqual(@as(u32, 0), base(gb).TextFit(rp, "abcd", 4, &room, null, graphics.TEXT_FORWARD, 1000, 4));
    try testing.expectEqual(@as(i32, 0), room.width);

    // A box to fit inside, and a width given outright that narrows it.
    const box = graphics.TextExtent{ .width = 24, .height = 16 };
    try testing.expectEqual(@as(u32, 3), base(gb).TextFit(rp, "abcd", 4, &room, &box, graphics.TEXT_FORWARD, 0, 0));
    try testing.expectEqual(@as(u32, 1), base(gb).TextFit(rp, "abcd", 4, &room, &box, graphics.TEXT_FORWARD, 8, 0));

    // A taller font needs a taller box for the same string.
    const low_box = graphics.TextExtent{ .width = 24, .height = 12 };
    try testing.expectEqual(@as(u32, 3), base(gb).TextFit(rp, "abcd", 4, &room, &low_box, graphics.TEXT_FORWARD, 0, 0));
    const sixteen = base(gb).OpenFont(graphics.POSPAZNAME, 16) orelse return error.NoFont;
    const use16 = [_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(sixteen) }, .{} };
    base(gb).SetRPAttrs(rp, &use16);
    try testing.expectEqual(@as(u32, 0), base(gb).TextFit(rp, "abcd", 4, &room, &low_box, graphics.TEXT_FORWARD, 0, 0));
    try testing.expectEqual(@as(u32, 3), base(gb).TextFit(rp, "abcd", 4, &room, &box, graphics.TEXT_FORWARD, 0, 0));

    base(gb).CloseFont(sixteen);
    base(gb).FreeRastPort(rp);
    base(gb).CloseFont(font);
    try tearDown(gb);
}

/// How many pixels of a surface are exactly this colour.
fn countOf(surface: *const rtg.Surface, colour: u16) u32 {
    var n: u32 = 0;
    var y: u32 = 0;
    while (y < surface.height) : (y += 1) {
        var x: u32 = 0;
        while (x < surface.width) : (x += 1) {
            if (pixelAt(surface, x, y) == colour) n += 1;
        }
    }
    return n;
}

test "text is assembled before it is drawn, so a lean is not erased" {
    const gb = try setUp();
    defer kexec.deinit();

    const font = base(gb).OpenFont(graphics.POSPAZNAME, 8) orelse return error.NoFont;
    var one: [64 * 16 * 2]u8 = @splat(0);
    var two: [64 * 16 * 2]u8 = @splat(0);
    var plain = rtg.Surface{ .pixels = &one, .width = 64, .height = 16, .pitch = 128, .size_bytes = one.len, .format = .rgb565 };
    var papered = rtg.Surface{ .pixels = &two, .width = 64, .height = 16, .pitch = 128, .size_bytes = two.len, .format = .rgb565 };

    const white = graphics.penRGB(255, 255, 255);
    const blue = graphics.penRGB(0, 0, 255);

    // The same italic string twice: once with no paper behind it, once
    // with. Every pixel of ink in the first must be ink in the second.
    //
    // Drawn a glyph at a time that does not hold: an italic glyph leans
    // out of its cell, and the next character's paper would land on the
    // lean of the one before it. Assembled into a strip first, the run is
    // one shape and the overlap is an OR.
    for ([_]struct { surface: *rtg.Surface, mode: graphics.DrawMode }{
        .{ .surface = &plain, .mode = graphics.DRMD_JAM1 },
        .{ .surface = &papered, .mode = graphics.DRMD_JAM2 },
    }) |each| {
        const tags = [_]TagItem{
            .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(each.surface) },
            .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) },
            .{ .tag = graphics.RPTAG_APen, .data = white },
            .{ .tag = graphics.RPTAG_BPen, .data = blue },
            .{ .tag = graphics.RPTAG_TextStyle, .data = graphics.FSF_ITALIC },
            .{ .tag = graphics.RPTAG_DrMd, .data = each.mode },
            .{},
        };
        const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;
        base(gb).Move(rp, 1, 9);
        base(gb).Text(rp, "MMMM", 4);
        base(gb).FreeRastPort(rp);
    }

    const ink_plain = countOf(&plain, 0xFFFF);
    const ink_papered = countOf(&papered, 0xFFFF);
    try testing.expect(ink_plain > 0);
    try testing.expectEqual(ink_plain, ink_papered);

    base(gb).CloseFont(font);
    try tearDown(gb);
}

test "a scroll reads through the clip, so a window moves its own pixels" {
    const gb = try setUp();
    defer kexec.deinit();

    // A display of 16x8 with a window of 8x4 at (4,2) on it, which is a
    // clip target: the RastPort draws at its own corner.
    var display_pixels: [16 * 8 * 2]u8 = @splat(0);
    var display = rtg.Surface{
        .pixels = &display_pixels,
        .width = 16,
        .height = 8,
        .pitch = 32,
        .size_bytes = display_pixels.len,
        .format = .rgb565,
    };
    var target = graphics.ClipTarget{
        .rect = .{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 },
        .surface = &display,
        .dx = 4,
        .dy = 2,
    };
    const clip = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 };
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&display) },
        .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) },
        .{ .tag = graphics.RPTAG_ClipTargets, .data = @intFromPtr(&target) },
        .{},
    };
    const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;

    // A row of its own colour in each of the window's four rows.
    const pens = [_]u32{ graphics.penRGB(255, 0, 0), graphics.penRGB(0, 255, 0), graphics.penRGB(0, 0, 255), graphics.penRGB(255, 255, 255) };
    for (pens, 0..) |pen, row| {
        const one = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{} };
        base(gb).SetRPAttrs(rp, &one);
        base(gb).RectFill(rp, &.{ .min_x = 0, .min_y = @intCast(row), .max_x = 8, .max_y = @intCast(row + 1) });
    }
    const red = pixelAt(&display, 4, 2);
    const green = pixelAt(&display, 4, 3);
    const blue = pixelAt(&display, 4, 4);

    // Up by one row: what was the second row is the first.
    try testing.expect(base(gb).ScrollRaster(rp, 0, 1, &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 }));
    try testing.expectEqual(green, pixelAt(&display, 4, 2));
    try testing.expectEqual(blue, pixelAt(&display, 4, 3));
    // The display outside the window is untouched: the pixels were read
    // through the target and not off the surface at those coordinates.
    try testing.expectEqual(@as(u16, 0), pixelAt(&display, 0, 0));
    try testing.expectEqual(@as(u16, 0), pixelAt(&display, 12, 2));

    // Down by one, which reads its rows from the end.
    try testing.expect(base(gb).ScrollRaster(rp, 0, -1, &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 }));
    try testing.expectEqual(green, pixelAt(&display, 4, 3));

    // Covered: a window kept in two places moves both halves, and each
    // half comes from where it is kept.
    var kept_pixels: [4 * 4 * 2]u8 = @splat(0);
    var kept = rtg.Surface{
        .pixels = &kept_pixels,
        .width = 4,
        .height = 4,
        .pitch = 8,
        .size_bytes = kept_pixels.len,
        .format = .rgb565,
    };
    var right = graphics.ClipTarget{
        .rect = .{ .min_x = 4, .min_y = 0, .max_x = 8, .max_y = 4 },
        .surface = &kept,
        .dx = -4,
        .dy = 0,
    };
    target.rect = .{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 };
    target.next = &right;
    for (pens, 0..) |pen, row| {
        const one = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{} };
        base(gb).SetRPAttrs(rp, &one);
        base(gb).RectFill(rp, &.{ .min_x = 0, .min_y = @intCast(row), .max_x = 8, .max_y = @intCast(row + 1) });
    }
    try testing.expectEqual(red, pixelAt(&kept, 0, 0));
    try testing.expect(base(gb).ScrollRaster(rp, 0, 1, &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 }));
    try testing.expectEqual(green, pixelAt(&display, 4, 2)); // the half on the display
    try testing.expectEqual(green, pixelAt(&kept, 0, 0)); // the half that is kept

    // What nothing kept cannot be moved, and then nothing is: the caller
    // is told so and draws it again.
    target.next = null;
    const was = pixelAt(&display, 4, 2);
    try testing.expect(!base(gb).ScrollRaster(rp, 0, 1, &.{ .min_x = 0, .min_y = 0, .max_x = 8, .max_y = 4 }));
    try testing.expectEqual(was, pixelAt(&display, 4, 2));

    base(gb).FreeRastPort(rp);
    try tearDown(gb);
}

test "the font list: added, found, and refused while it is open" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [32 * 16 * 2]u8 = @splat(0);
    var surface = rtg.Surface{ .pixels = &pixels, .width = 32, .height = 16, .pitch = 64, .size_bytes = pixels.len, .format = .rgb565 };
    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) }, .{} };
    const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;

    // A font of the test's own, over the glyphs of one that is there.
    const borrowed = base(gb).OpenFont(graphics.POSPAZNAME, 8) orelse return error.NoFont;
    var mine = fonts.TextFont{
        .name = "test.font",
        .width = 8,
        .height = 8,
        .baseline = 6,
        .first_char = 32,
        .count = 225,
        .rows = @as(*fonts.TextFont, @ptrCast(@alignCast(borrowed))).rows,
        .open_count = 0,
    };
    base(gb).CloseFont(borrowed);

    // Not on the list, so not found.
    try testing.expect(base(gb).OpenFont("test.font", 8) == null);
    try testing.expect(base(gb).AddFont(@ptrCast(&mine)));
    // Twice is refused rather than putting it on twice.
    try testing.expect(!base(gb).AddFont(@ptrCast(&mine)));

    const found = base(gb).OpenFont("test.font", 8) orelse return error.NoFont;
    try testing.expectEqual(@as(*graphics.TextFont, @ptrCast(&mine)), found);
    // Open, so it cannot be taken away from under whoever has it.
    try testing.expect(!base(gb).RemFont(found));
    base(gb).CloseFont(found);
    try testing.expect(base(gb).RemFont(@ptrCast(&mine)));
    try testing.expect(base(gb).OpenFont("test.font", 8) == null);
    // The ROM's two are untouched by all of that.
    try testing.expect(base(gb).OpenFont(graphics.POSPAZNAME, 16) != null);

    // What a font is, and which styles are left to ask for.
    var what: graphics.FontExtent = .{};
    const sixteen = base(gb).OpenFont(graphics.POSPAZNAME, 16).?;
    base(gb).FontExtent(sixteen, &what);
    try testing.expectEqual(@as(i32, 8), what.width);
    try testing.expectEqual(@as(i32, 16), what.height);
    try testing.expectEqual(@as(i32, 13), what.baseline);
    try testing.expectEqual(graphics.FS_NORMAL, what.style);
    try testing.expectEqual(what.height, what.extent.max_y - what.extent.min_y);
    base(gb).CloseFont(sixteen);
    base(gb).CloseFont(sixteen);

    // A font drawn extended: extending it again is not on offer.
    mine.style = graphics.FSF_EXTENDED;
    base(gb).FontExtent(@ptrCast(&mine), &what);
    try testing.expectEqual(graphics.FSF_EXTENDED, what.style);
    const use_mine = [_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&mine) }, .{} };
    base(gb).SetRPAttrs(rp, &use_mine);
    const offered = base(gb).AskSoftStyle(rp);
    try testing.expectEqual(@as(u32, 0), offered & graphics.FSF_EXTENDED);
    try testing.expect(offered & graphics.FSF_BOLD != 0);

    // Asking for extended on a font that already is changes nothing, and
    // does not widen it twice.
    const before = base(gb).TextLength(rp, "ab", 2);
    try testing.expectEqual(@as(u32, 0), base(gb).SetSoftStyle(rp, graphics.FSF_EXTENDED, 0xFF));
    try testing.expectEqual(before, base(gb).TextLength(rp, "ab", 2));
    // And enable keeps out what the caller will not allow.
    try testing.expectEqual(graphics.FSF_BOLD, base(gb).SetSoftStyle(rp, graphics.FSF_BOLD | graphics.FSF_ITALIC, graphics.FSF_BOLD));

    base(gb).FreeRastPort(rp);
    try tearDown(gb);
}

test "WritePixelArray: a picture put down as it is, converted, clipped and cut; WriteLUTPixelArray through a table" {
    const gb = try setUp();
    defer kexec.deinit();

    var pixels: [16 * 8 * 2]u8 = @splat(0);
    var surface = rtg.Surface{
        .pixels = &pixels,
        .width = 16,
        .height = 8,
        .pitch = 32,
        .size_bytes = pixels.len,
        .format = .rgb565,
    };
    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) }, .{} };
    const rp = base(gb).CreateRastPortTagList(&tags) orelse return error.NoRastPort;
    var err: i32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_LastError, .data = @intFromPtr(&err) }, .{} };

    // In the surface's own format: the rows as they are, from (1, 0) of a
    // picture three wide.
    const same = [_]u16{ 0x1111, 0x2222, 0x3333, 0x4444, 0x5555, 0x6666 };
    base(gb).WritePixelArray(@ptrCast(rp), @ptrCast(&same), 6, @intFromEnum(rtg.bitmaps.PixelFormat.rgb565), 1, 0, &.{ .min_x = 4, .min_y = 2, .max_x = 6, .max_y = 4 });
    try testing.expectEqual(@as(u16, 0x2222), pixelAt(&surface, 4, 2));
    try testing.expectEqual(@as(u16, 0x3333), pixelAt(&surface, 5, 2));
    try testing.expectEqual(@as(u16, 0x5555), pixelAt(&surface, 4, 3));
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 6, 2));

    // From rgba32 - bytes r, g, b, a - converted to each pixel's rgb565.
    const rgba = [_]u8{ 0xFF, 0, 0, 0xFF, 0, 0xFF, 0, 0xFF, 0, 0, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0xFF };
    base(gb).WritePixelArray(@ptrCast(rp), &rgba, 16, @intFromEnum(rtg.bitmaps.PixelFormat.rgba32), 0, 0, &.{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 1 });
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 0, 0));
    try testing.expectEqual(@as(u16, 0x07E0), pixelAt(&surface, 1, 0));
    // Its alpha is not used: a pixel of no coverage goes down all the same.
    try testing.expectEqual(@as(u16, 0x001F), pixelAt(&surface, 2, 0));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 3, 0));

    // Clipped at the front: cut, not slid - the picture's second pixel
    // lands on the clip's first column.
    @memset(&pixels, 0);
    const clip = graphics.Rect{ .min_x = 1, .min_y = 0, .max_x = 16, .max_y = 8 };
    const narrow = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&clip) }, .{} };
    base(gb).SetRPAttrs(@ptrCast(rp), &narrow);
    base(gb).WritePixelArray(@ptrCast(rp), &rgba, 16, @intFromEnum(rtg.bitmaps.PixelFormat.rgba32), 0, 0, &.{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 1 });
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 0, 0));
    try testing.expectEqual(@as(u16, 0x07E0), pixelAt(&surface, 1, 0));

    // A format with no colours is refused, and nothing is written.
    base(gb).WritePixelArray(@ptrCast(rp), &rgba, 16, @intFromEnum(rtg.bitmaps.PixelFormat.indexed8), 0, 0, &.{ .min_x = 8, .min_y = 0, .max_x = 12, .max_y = 1 });
    base(gb).GetRPAttrs(@ptrCast(rp), &ask);
    try testing.expectEqual(graphics.GERR_BAD_FORMAT, err);
    try testing.expectEqual(@as(u16, 0), pixelAt(&surface, 8, 0));

    // Colour numbers through a table: two rows of four, from the second.
    var table: [256]graphics.Pen = @splat(graphics.penRGB(0, 0, 0));
    table[1] = graphics.penRGB(255, 0, 0);
    table[2] = graphics.penRGB(0, 255, 0);
    table[3] = graphics.penRGB(255, 255, 255);
    const chunky = [_]u8{ 9, 9, 9, 9, 0, 1, 2, 3 };
    base(gb).WriteLUTPixelArray(@ptrCast(rp), &chunky, 4, &table, 0, 1, &.{ .min_x = 4, .min_y = 5, .max_x = 8, .max_y = 6 });
    base(gb).GetRPAttrs(@ptrCast(rp), &ask);
    try testing.expectEqual(graphics.GERR_OK, err);
    try testing.expectEqual(@as(u16, 0x0000), pixelAt(&surface, 4, 5));
    try testing.expectEqual(@as(u16, 0xF800), pixelAt(&surface, 5, 5));
    try testing.expectEqual(@as(u16, 0x07E0), pixelAt(&surface, 6, 5));
    try testing.expectEqual(@as(u16, 0xFFFF), pixelAt(&surface, 7, 5));
    // A new table, the same numbers: the palette changed.
    table[1] = graphics.penRGB(0, 0, 255);
    base(gb).WriteLUTPixelArray(@ptrCast(rp), &chunky, 4, &table, 0, 1, &.{ .min_x = 4, .min_y = 5, .max_x = 8, .max_y = 6 });
    try testing.expectEqual(@as(u16, 0x001F), pixelAt(&surface, 5, 5));

    base(gb).FreeRastPort(@ptrCast(rp));
    try tearDown(gb);
}
