// SPDX-License-Identifier: MIT
//! A surface over the inside of a window of intuition's: the swapchain's
//! images are pictures in memory the size of the window inside its
//! border, and showing one waits for the display's next frame and copies
//! it into the window (BltBitMapRastPort) - through the window's layer,
//! so that what covers the window is left alone, and by the board's
//! engine. Copied as the frame starts, a picture is in place before the
//! display reads that part of the screen: the window shows whole
//! pictures, one a frame at most. Where the window is moved, the next
//! picture lands where it is now. The window's layer is held while a
//! picture is copied, as layers.library asks of a task drawing into one:
//! the window cannot be moved or sized part way through.
//!
//! The window itself is not kept, its number is (`WA_Number`): each time
//! it is read or drawn into it is found by the number under the screens'
//! semaphore (`FindWindowNumber`), and its layer taken before that is let
//! go. A window closed under the surface - its program ended, and its
//! windows closed with it, while the queue's task still had a picture to
//! copy - is found gone, never another window opened since in its memory:
//! nothing is copied, and the surface is lost.
//!
//! intuition.library, graphics.library, layers.library and rtg.library
//! are opened as the surface is made, by the task that makes it, and
//! closed as it goes.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const rtg = sdk.rtg;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const layers = sdk.layers;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const PixelFormat = rtg.bitmaps.PixelFormat;
const ExecBase = sdk.interface.exec.ExecBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const LayersBase = sdk.interface.layers.LayersBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const _objects = @import("../_objects.zig");
const _memory = @import("../memory/_memory.zig");
const _swapchain = @import("../swapchain/_swapchain.zig");
const _surface = @import("_surface.zig");
const Surface = _surface.Surface;
const Picture = _surface.Picture;
const Shape = _surface.Shape;

/// What a window's surface keeps.
const Window = struct {
    sys: *ExecBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    lb: *LayersBase,
    rb: *RtgBase,
    /// The window's number, which finds it while it is open.
    number: u32,
    /// The program's RastPort of the window and the layer it draws in:
    /// the inside's, for a GimmeZeroZero window.
    rastport: *graphics.RastPort,
    layer: *layers.Layer,
    /// The screen's pixels, and the board that shows them, whose frames a
    /// picture waits for: null for a screen no board shows.
    format: PixelFormat,
    board: ?*rtg.RtgBoard,
};

/// A picture: its pixels, as the surface BltBitMapRastPort reads, and the
/// block they are in.
const Offscreen = struct {
    surface: rtg.Surface,
    block: [*]u8,
    bytes: usize,
};

/// The part of the window inside its border, in its RastPort.
const Inside = struct {
    left: i32,
    top: i32,
    width: u32,
    height: u32,
};

pub const ops = _surface.Ops{ .copies = true, .shape = &shape, .most = &most, .make = &make, .unmake = &unmake, .show = &show, .close = &close };

/// `surface`'s ops and context set for `window`;
/// error_initialization_failed without the libraries.
pub fn open(sys: *ExecBase, surface: *Surface, window: *intuition.Window) facet.Result {
    const libraries = [4]?*exec.Library{
        sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION),
        sys.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION),
        sys.OpenLibrary(layers.LAYERSNAME, layers.LAYERS_VERSION),
        sys.OpenLibrary(rtg.RTGNAME, 1),
    };
    const missing = for (libraries) |library| {
        if (library == null) break true;
    } else false;
    // An intuition too old to number its windows could not say when this
    // one closes.
    const number: usize = if (missing) 0 else attr(@ptrCast(libraries[0].?), window, wn.WA_Number);
    const kept = (if (number == 0) null else _objects.create(sys, Window)) orelse {
        for (libraries) |library| if (library) |opened| sys.CloseLibrary(opened);
        return if (number == 0) .error_initialization_failed else .error_out_of_host_memory;
    };
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const gb: *GraphicsBase = @ptrCast(libraries[1].?);
    const rastport: *graphics.RastPort = @ptrFromInt(attr(ib, window, wn.WA_RastPort));
    var format: u32 = 0;
    var bitmap: usize = 0;
    gb.GetRPAttrs(rastport, &[_]TagItem{
        .{ .tag = graphics.RPTAG_Format, .data = @intFromPtr(&format) },
        .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(&bitmap) },
        .{},
    });
    const shown: ?*const rtg.RtgBitMap = @ptrFromInt(bitmap);
    kept.* = .{
        .sys = sys,
        .ib = ib,
        .gb = gb,
        .lb = @ptrCast(libraries[2].?),
        .rb = @ptrCast(libraries[3].?),
        .number = @intCast(number),
        .rastport = rastport,
        .layer = @ptrFromInt(attr(ib, window, wn.WA_Layer)),
        .format = @enumFromInt(@as(u8, @intCast(format))),
        .board = if (shown) |screen_bitmap| @ptrCast(@alignCast(screen_bitmap.board)) else null,
    };
    surface.ops = &ops;
    surface.context = kept;
    return .success;
}

fn of(surface: *Surface) *Window {
    return @ptrCast(@alignCast(surface.context.?));
}

/// Null once the window has closed.
fn shape(surface: *Surface) ?Shape {
    const kept = of(surface);
    const held = kept.ib.LockIBase(0);
    defer kept.ib.UnlockIBase(held);
    const window = kept.ib.FindWindowNumber(kept.number) orelse return null;
    const inside = insideOf(kept.ib, window);
    return .{ .width = inside.width, .height = inside.height, .format = _surface.formatOf(kept.format) };
}

/// As many as a swapchain has: they are memory's, not the display's.
fn most(_: *Surface) u32 {
    return _swapchain.max_images;
}

fn make(surface: *Surface, pictures: []Picture) bool {
    const kept = of(surface);
    const now = shape(surface) orelse return false;
    // Rows a cache line apart, as the tiles write them back.
    const pitch = std.mem.alignForward(u32, now.width * 4, _memory.alignment);
    for (pictures, 0..) |*picture, k| {
        const offscreen = allocate(kept.sys, now.width, now.height, pitch, kept.format) orelse {
            unmake(surface, pictures[0..k], null);
            return false;
        };
        picture.* = .{ .pixels = offscreen.surface.pixels.?, .pitch = pitch, .handle = offscreen };
    }
    return true;
}

/// A picture cleared, so that one shown before it is drawn is black.
fn allocate(sys: *ExecBase, width: u32, height: u32, pitch: u32, format: PixelFormat) ?*Offscreen {
    const made = _objects.create(sys, Offscreen) orelse return null;
    const size = @as(usize, pitch) * height;
    // Room to move the pixels up to a cache line: AllocMem's are aligned
    // to its chunks.
    const bytes = size + (_memory.alignment - exec.MEM_BLOCKSIZE);
    const block: [*]u8 = @ptrCast(sys.AllocMem(bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _objects.destroy(sys, made);
        return null;
    });
    const pixels: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(block), _memory.alignment));
    made.* = .{
        .surface = .{ .pixels = pixels, .width = width, .height = height, .pitch = pitch, .size_bytes = size, .format = format },
        .block = block,
        .bytes = bytes,
    };
    return made;
}

/// None is the display's: each goes at once.
fn unmake(surface: *Surface, pictures: []Picture, _: ?u32) void {
    const sys = of(surface).sys;
    for (pictures) |*picture| {
        const offscreen = offscreenOf(picture);
        sys.FreeMem(offscreen.block, offscreen.bytes);
        _objects.destroy(sys, offscreen);
    }
}

/// The display's next frame waited for, and the picture copied into the
/// window with its layer held - as much of it as fits inside the border
/// now, where the window has been made smaller since the swapchain was.
/// False once the window has closed. The layer is taken while the window
/// is held open by the screens' semaphore, which is then let go: a close
/// waits for the layer, and the screens are not held through the copy.
fn show(surface: *Surface, picture: *Picture) bool {
    const kept = of(surface);
    const offscreen = offscreenOf(picture);
    if (kept.board) |board| _ = kept.rb.WaitVBlank(board, 0);
    const held = kept.ib.LockIBase(0);
    const window = kept.ib.FindWindowNumber(kept.number) orelse {
        kept.ib.UnlockIBase(held);
        return false;
    };
    kept.lb.LockLayer(kept.layer);
    defer kept.lb.UnlockLayer(kept.layer);
    const inside = insideOf(kept.ib, window);
    kept.ib.UnlockIBase(held);
    const width = @min(offscreen.surface.width, inside.width);
    const height = @min(offscreen.surface.height, inside.height);
    kept.gb.BltBitMapRastPort(&offscreen.surface, 0, 0, kept.rastport, inside.left, inside.top, @intCast(width), @intCast(height));
    return true;
}

fn close(surface: *Surface) void {
    const kept = of(surface);
    const sys = kept.sys;
    sys.CloseLibrary(@ptrCast(@alignCast(kept.rb)));
    sys.CloseLibrary(@ptrCast(@alignCast(kept.lb)));
    sys.CloseLibrary(@ptrCast(@alignCast(kept.gb)));
    sys.CloseLibrary(@ptrCast(@alignCast(kept.ib)));
    _objects.destroy(sys, kept);
    surface.context = null;
}

/// Where the inside of the window is in its RastPort, and its size: a
/// GimmeZeroZero window's RastPort is the inside's own.
fn insideOf(ib: *IntuitionBase, window: *intuition.Window) Inside {
    var width: usize = 0;
    var height: usize = 0;
    var left: usize = 0;
    var top: usize = 0;
    var flags: usize = 0;
    ib.GetWindowAttrs(window, &[_]TagItem{
        .{ .tag = wn.WA_InnerWidth, .data = @intFromPtr(&width) },
        .{ .tag = wn.WA_InnerHeight, .data = @intFromPtr(&height) },
        .{ .tag = wn.WA_BorderLeft, .data = @intFromPtr(&left) },
        .{ .tag = wn.WA_BorderTop, .data = @intFromPtr(&top) },
        .{ .tag = wn.WA_Flags, .data = @intFromPtr(&flags) },
        .{},
    });
    const own = flags & wn.WFLG_GIMMEZEROZERO != 0;
    return .{
        .left = if (own) 0 else @intCast(left),
        .top = if (own) 0 else @intCast(top),
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

fn attr(ib: *IntuitionBase, window: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} });
    return value;
}

fn offscreenOf(picture: *const Picture) *Offscreen {
    return @ptrCast(@alignCast(picture.handle.?));
}
