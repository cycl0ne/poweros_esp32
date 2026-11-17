// SPDX-License-Identifier: MPL-2.0
//! The screens follow the machine's display.
//!
//! The first board rtg.library lists is the machine's display, and it
//! need not stay the same board: a driver loaded from the disk makes a
//! board that is listed before the one the firmware's picture was shown
//! by, and that one may be gone with it; the settings may make another
//! board the first. The input task is told whenever something about the
//! boards changed, and where the first board is not the one a screen is
//! on, the screen is moved (`follow`):
//!
//! - what the old board shows is taken down, so that none of its buffers
//!   is in use;
//! - the screen's buffers are given to the first board (`RehomeBitMap`):
//!   the handles stay, so every RastPort, layer and window of the screen
//!   draws where it drew, and nothing is drawn again;
//! - the first board is put in the mode nearest the front screen's size,
//!   where no screen was on it before, and shows its screens. A screen
//!   of another size than the mode is shown scaled, on a board that
//!   scales, until its owner opens it again;
//! - the pointer goes to the board the front screen is on.
//!
//! A screen whose buffers the first board has no room for stays where it
//! is: on a board that is gone it is not seen until it is closed.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;

/// Every screen that is not on the first board moved to it.
///
/// INPUTS:
/// - `ib` - the library.
///
/// CONTEXT:
/// On the input task, told by rtg.library that the boards changed. It
/// takes the screens' lock and each moved screen's layers; a show may
/// wait for a frame.
pub fn follow(ib: *IntuitionBase) void {
    const rb = ib.rtg_base orelse return;
    const first = rb.NextBoard(null) orelse return;
    _screen.lock(ib);
    defer _screen.unlock(ib);

    // The first board's home, before anything moves: its screens' where
    // it has screens, else the picture it shows, else the first moved
    // screen's.
    const had_screens = _screen.frontOn(ib, first) != null;
    var home: ?*rtg.RtgBitMap = if (_screen.frontOn(ib, first)) |on_first| on_first.home else rb.BoardDisplayBitMap(first);
    var front_moved: ?*Screen = null;

    var node = ib.screen_list.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const s: *Screen = @ptrCast(@alignCast(n));
        if (s.board == first) continue;
        // Nothing of the old board's is shown while its buffers go.
        _ = rb.ShowBitMap(s.board, null);
        ib.layers_base.LockLayerInfo(s.layer_info);
        defer ib.layers_base.UnlockLayerInfo(s.layer_info);

        const old_home = s.home;
        if (rb.RehomeBitMap(s.bitmap, first) != rtg.errors.RTGERR_OK) continue;
        if (s.shown != s.bitmap and rb.RehomeBitMap(s.shown, first) != rtg.errors.RTGERR_OK) s.shown = s.bitmap;
        // The row shown above it is as wide as its display: made again
        // when it is needed.
        _screen.dropBlank(ib, s);
        s.board = first;
        if (home == null) {
            // The display's home goes with its first screen.
            if (old_home != s.bitmap and rb.RehomeBitMap(old_home, first) == rtg.errors.RTGERR_OK) {
                home = old_home;
            } else {
                home = s.bitmap;
            }
        }
        // A screen that drew in its old display's home has a buffer of
        // its own from now on, where the home is another.
        if (!s.own_bitmap and s.bitmap != home.?) s.own_bitmap = true;
        if (s.own_bitmap and s.bitmap == home.?) s.own_bitmap = false;
        s.home = home.?;
        if (front_moved == null) front_moved = s;
    }
    const moved = front_moved orelse return;

    // A display no screen was on is put in the mode nearest the screen
    // that now is: its own size where the board has it.
    if (!had_screens) {
        const any = rtg.RTG_ANY;
        var mode: rtg.RtgMode = .{};
        const id = rb.BestBoardMode(first, @intCast(moved.width), @intCast(moved.height), any, any, &mode);
        if (id != 0) _ = rb.ShowBoard(first, id, null, 0);
    }
    // Shown whatever was up before: the display's bands are other now.
    ib.banded = true;
    _screen.showFront(ib, first, home.?);
    @import("../input/pointer.zig").update(ib);
}
