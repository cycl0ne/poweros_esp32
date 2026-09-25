// SPDX-License-Identifier: MPL-2.0
//! AllocScreenBuffer: one more buffer for a screen to show.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const sc = sdk.intuition.screens;
const TagItem = sdk.utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const lock = _screen.lock;
const unlock = _screen.unlock;

/// Makes one more buffer for a screen to show.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocScreenBuffer(ib: *IntuitionBase, screen: *Screen, flags: u32) ?*ScreenBuffer
/// ```
///
/// SINCE: 0.14. LVO -396.
///
/// INPUTS:
/// - `screen` - the screen.
/// - `flags` - `SB_SCREEN_BITMAP` for the screen's own buffer, else 0 or
///   `SB_COPY_BITMAP` for a new one.
///
/// RESULT:
/// The buffer, or null: no memory, or no room in the display's memory for
/// another picture.
///
/// BEHAVIOR:
/// A new buffer is a picture the screen's size in its display's memory,
/// black - or a copy of the screen's own with `SB_COPY_BITMAP` - with a
/// RastPort over the whole of it. With `SB_SCREEN_BITMAP` nothing is
/// allocated: the buffer is the screen's own, the one its bar, windows and
/// menus are drawn in, and its RastPort the screen's. Two buffers, drawn
/// and shown in turn with `ChangeScreenBuffer`, are double buffering.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer is the caller's, to give back with `FreeScreenBuffer` before
/// the screen closes.
///
/// NOTES:
/// A display's memory holds a few pictures, and each open screen takes
/// one: on a display with room for two, one screen and one more buffer is
/// all there is.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ChangeScreenBuffer`, `FreeScreenBuffer`
///
/// EXAMPLES:
/// ```zig
/// const front = ib.AllocScreenBuffer(screen, sc.SB_SCREEN_BITMAP) orelse return;
/// const back = ib.AllocScreenBuffer(screen, 0) orelse return;
/// ```
pub fn AllocScreenBuffer(ib: *IntuitionBase, screen: *Screen, flags: u32) ?*sc.ScreenBuffer {
    const gb = ib.graphics_base;
    const rb = ib.rtg_base orelse return null;
    lock(ib);
    defer unlock(ib);
    const memory = ib.sys_base.AllocMem(@sizeOf(sc.ScreenBuffer), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const sb: *sc.ScreenBuffer = @ptrCast(@alignCast(memory));
    if (flags & sc.SB_SCREEN_BITMAP != 0) {
        sb.* = .{ .bitmap = screen.bitmap, .rast_port = screen.rp, .flags = flags };
        return sb;
    }
    const own = screen.bitmap;
    const bitmap = rb.AllocBitMap(screen.board, own.width, own.height, @intFromEnum(own.format), rtg.bitmaps.RTGBMF_DISPLAYABLE | rtg.bitmaps.PIXMAPF_SCREEN) orelse {
        ib.sys_base.FreeMem(memory, @sizeOf(sc.ScreenBuffer));
        return null;
    };
    const pixels = bitmap.pixels.?;
    if (flags & sc.SB_COPY_BITMAP != 0) {
        _ = gb.BltBitMap(@ptrCast(own), 0, 0, @ptrCast(bitmap), 0, 0, @intCast(own.width), @intCast(own.height));
    } else {
        @memset(pixels[0 .. @as(usize, bitmap.pitch) * bitmap.height], 0);
    }
    // Written behind the cache's back: handed on before it can be shown.
    _ = rb.RefreshBitMap(bitmap, 0, 0);
    const on = [_]TagItem{ .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(bitmap) }, .{} };
    const rp = gb.CreateRastPortTagList(&on) orelse {
        rb.FreeBitMap(bitmap);
        ib.sys_base.FreeMem(memory, @sizeOf(sc.ScreenBuffer));
        return null;
    };
    graphics.SetFont(gb, rp, screen.font);
    sb.* = .{ .bitmap = bitmap, .rast_port = rp, .flags = flags };
    return sb;
}
