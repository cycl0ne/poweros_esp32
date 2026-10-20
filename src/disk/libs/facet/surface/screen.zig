// SPDX-License-Identifier: MIT
//! A surface over a screen of intuition's: the swapchain's first image is
//! the screen's own buffer, the rest are buffers AllocScreenBuffer makes
//! in the display's memory, and showing one is ChangeScreenBuffer - which
//! returns when the display has taken it up at the start of a frame.
//!
//! intuition.library and rtg.library are opened as the surface is made,
//! by the task that makes it, and closed as it goes.

const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const rtg = sdk.rtg;
const intuition = sdk.intuition;
const sc = intuition.screens;
const ExecBase = sdk.interface.exec.ExecBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const _objects = @import("../_objects.zig");
const _surface = @import("_surface.zig");
const Surface = _surface.Surface;
const Picture = _surface.Picture;
const Shape = _surface.Shape;

/// RefreshRect came with this revision of rtg.library.
const rtg_revision = 5;

/// What a screen's surface keeps.
const Screen = struct {
    sys: *ExecBase,
    ib: *IntuitionBase,
    rb: *RtgBase,
    screen: *intuition.Screen,
    /// The screen's own buffer: its bitmap is the screen's.
    own: *sc.ScreenBuffer,
};

pub const ops = _surface.Ops{ .shape = &shape, .most = &most, .make = &make, .unmake = &unmake, .show = &show, .close = &close };

/// `surface`'s ops and context set for `screen`; error_initialization_failed
/// without intuition.library or a new enough rtg.library.
pub fn open(sys: *ExecBase, surface: *Surface, screen: *intuition.Screen) facet.Result {
    const intuition_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse return .error_initialization_failed;
    const rtg_lib = sys.OpenLibrary(rtg.RTGNAME, 1) orelse {
        sys.CloseLibrary(intuition_lib);
        return .error_initialization_failed;
    };
    const ib: *IntuitionBase = @ptrCast(intuition_lib);
    const made = made: {
        if (rtg_lib.revision < rtg_revision) break :made null;
        const kept = _objects.create(sys, Screen) orelse break :made null;
        const own = ib.AllocScreenBuffer(screen, sc.SB_SCREEN_BITMAP) orelse {
            _objects.destroy(sys, kept);
            break :made null;
        };
        kept.* = .{ .sys = sys, .ib = ib, .rb = @ptrCast(rtg_lib), .screen = screen, .own = own };
        break :made kept;
    } orelse {
        sys.CloseLibrary(rtg_lib);
        sys.CloseLibrary(intuition_lib);
        return .error_initialization_failed;
    };
    surface.ops = &ops;
    surface.context = made;
    return .success;
}

fn of(surface: *Surface) *Screen {
    return @ptrCast(@alignCast(surface.context.?));
}

fn shape(surface: *Surface) ?Shape {
    const bitmap = of(surface).own.bitmap;
    return .{
        .width = bitmap.width,
        .height = bitmap.height,
        .format = _surface.formatOf(bitmap.format),
    };
}

/// As many as the display's memory holds pictures, the screen's own one
/// of them.
fn most(surface: *Surface) u32 {
    const board: *rtg.RtgBoard = @ptrCast(@alignCast(of(surface).own.bitmap.board orelse return 1));
    return @max(board.info.buffers, 1);
}

fn make(surface: *Surface, pictures: []Picture) bool {
    const screen = of(surface);
    for (pictures, 0..) |*picture, k| {
        const buffer = if (k == 0) screen.own else screen.ib.AllocScreenBuffer(screen.screen, 0) orelse {
            unmake(surface, pictures[0..k], null);
            return false;
        };
        const bitmap = buffer.bitmap;
        picture.* = .{
            .pixels = bitmap.pixels.?,
            .pitch = bitmap.pitch,
            .handle = buffer,
            .display = .{ .rb = screen.rb, .bitmap = bitmap },
            .shown = k == 0,
        };
    }
    return true;
}

/// The screen's own buffer shown again first where another is, so none
/// goes while the display reads it.
fn unmake(surface: *Surface, pictures: []Picture, shown: ?u32) void {
    const screen = of(surface);
    if (shown) |index| if (index != 0) {
        while (!screen.ib.ChangeScreenBuffer(screen.screen, screen.own)) _ = screen.rb.WaitVBlank(boardOf(screen), 0);
    };
    for (pictures[@min(1, pictures.len)..]) |*picture| screen.ib.FreeScreenBuffer(screen.screen, bufferOf(picture));
}

/// ChangeScreenBuffer, again at the next frame while the screen's menus
/// are up; a frame waited for where the display did not flip to it.
fn show(surface: *Surface, picture: *Picture) bool {
    const screen = of(surface);
    const buffer = bufferOf(picture);
    const was_showing = buffer.bitmap.flags & rtg.bitmaps.RTGBMF_SHOWING != 0;
    while (!screen.ib.ChangeScreenBuffer(screen.screen, buffer)) _ = screen.rb.WaitVBlank(boardOf(screen), 0);
    const flipped = !was_showing and buffer.bitmap.flags & rtg.bitmaps.RTGBMF_SHOWING != 0;
    if (!flipped) _ = screen.rb.WaitVBlank(boardOf(screen), 0);
    return true;
}

fn close(surface: *Surface) void {
    const screen = of(surface);
    const sys = screen.sys;
    screen.ib.FreeScreenBuffer(screen.screen, screen.own);
    sys.CloseLibrary(@ptrCast(@alignCast(screen.rb)));
    sys.CloseLibrary(@ptrCast(@alignCast(screen.ib)));
    _objects.destroy(sys, screen);
    surface.context = null;
}

fn bufferOf(picture: *const Picture) *sc.ScreenBuffer {
    return @ptrCast(@alignCast(picture.handle.?));
}

fn boardOf(screen: *const Screen) *rtg.RtgBoard {
    return @ptrCast(@alignCast(screen.own.bitmap.board.?));
}
