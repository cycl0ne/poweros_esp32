// SPDX-License-Identifier: MPL-2.0
//! DisplayBeep: flashes a screen.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const layers = sdk.layers;
const rtg = sdk.rtg;
const sc = sdk.intuition.screens;
const TagItem = sdk.utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("../screen/_screen.zig");
const Screen = _screen.Screen;
const _misc = @import("_misc.zig");

/// How long a screen shows the other way round.
const flash_us = 100_000;

/// Flashes a screen, to draw the eye without a requester.
///
/// SYNOPSIS:
/// ```zig
/// fn DisplayBeep(ib: *IntuitionBase, screen: ?*Screen) void
/// ```
///
/// SINCE: 0.14. LVO -408.
///
/// INPUTS:
/// - `screen` - the screen, or null for every screen that is shown.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// For a tenth of a second the display shows, in place of the screen, a
/// picture of one colour - the screen's background pen turned about, dark
/// for a light one and light for a dark one - and then the screen again.
/// Both changes are flips at a frame's start, so the whole display flashes
/// at once and nothing of the screen is drawn over. Only a screen in front
/// of its display flashes: one behind has nothing seen to flash. When the
/// display's memory has no room for the picture, only the screen's title
/// bar flashes.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and a tenth of a second.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// It is for something that needs noticing and not answering.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DisplayAlert`
///
/// EXAMPLES:
/// ```zig
/// ib.DisplayBeep(null); // a key with nothing bound to it
/// ```
pub fn DisplayBeep(ib: *IntuitionBase, screen: ?*Screen) void {
    _screen.lock(ib);
    defer _screen.unlock(ib);
    if (screen) |s| return flash(ib, s);
    var node = ib.screen_list.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        flash(ib, @ptrCast(@alignCast(n)));
    }
}

/// A colour turned about the way a flash wants it: each of its parts made
/// dark where it was light and light where it was dark, so a grey - which
/// a plain complement leaves almost as it was - changes too.
fn turned(pen: graphics.Pen) graphics.Pen {
    var out: graphics.Pen = pen & 0xFF00_0000;
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const part = (pen >> shift) & 0xFF;
        const new: graphics.Pen = if (part > 0x88) 0x55 else 0xCC;
        out |= new << shift;
    }
    return out;
}

/// One screen flashed, if it is the one shown.
fn flash(ib: *IntuitionBase, s: *Screen) void {
    if (_screen.frontOn(ib, s.board) != s) return;
    const gb = ib.graphics_base;
    const rb = ib.rtg_base orelse return;
    const colour = turned(s.pens[sc.BACKGROUNDPEN]);
    const shown = s.shown;
    const picture = rb.AllocBitMap(s.board, shown.width, shown.height, @intFromEnum(shown.format), rtg.bitmaps.RTGBMF_DISPLAYABLE) orelse
        return flashBar(ib, s, colour);
    defer rb.FreeBitMap(picture);
    const on = [_]TagItem{
        .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(picture) },
        .{ .tag = graphics.RPTAG_APen, .data = colour },
        .{},
    };
    const rp = gb.CreateRastPortTagList(&on) orelse return flashBar(ib, s, colour);
    defer gb.FreeRastPort(rp);
    gb.RectFill(rp, &.{ .max_x = @intCast(shown.width), .max_y = @intCast(shown.height) });
    _ = rb.ShowBitMap(s.board, picture, 0, 0);
    _misc.wait(ib, flash_us);
    _ = rb.ShowBitMap(s.board, shown, 0, 0);
}

/// Only the title bar flashed, and drawn again: all that can be when there
/// is no room for a picture of the whole display.
fn flashBar(ib: *IntuitionBase, s: *Screen, colour: graphics.Pen) void {
    const bar = s.bar orelse return;
    var where: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&where) }, .{} };
    ib.layers_base.GetLayerAttrs(bar, &ask);
    if (where == 0) return;
    const rp: *graphics.RastPort = @ptrFromInt(where);
    ib.layers_base.LockLayer(bar);
    _screen.setPen(ib, rp, colour);
    ib.graphics_base.RectFill(rp, &.{ .max_x = s.width, .max_y = s.bar_height });
    ib.layers_base.UnlockLayer(bar);
    _misc.wait(ib, flash_us);
    _screen.drawBar(ib, s);
}
