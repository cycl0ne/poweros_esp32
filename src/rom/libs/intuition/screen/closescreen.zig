// SPDX-License-Identifier: MPL-2.0
//! CloseScreen: closes a screen.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const lock = _screen.lock;
const setPen = _screen.setPen;
const showFront = _screen.showFront;
const unlock = _screen.unlock;

/// Closes a screen.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseScreen(ib: *IntuitionBase, screen: ?*Screen) bool
/// ```
///
/// SINCE: 0.4. LVO -100.
///
/// INPUTS:
/// - `screen` - the screen, or null.
///
/// RESULT:
/// True when it closed, or `screen` was null. False, with the screen still
/// open, while a public screen is locked by anyone.
///
/// BEHAVIOR:
/// Its bar and LayerInfo go, and a font the screen opened for itself is
/// closed. Its display shows the screen behind it, or - when it was the
/// last - goes black. The buffer it drew in is given back to the display's
/// memory for another screen.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no; it frees memory.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// On true, the screen and everything read out of it - its RastPort,
/// LayerInfo and DrawInfo - are gone.
///
/// NOTES:
/// - It will refuse while windows are open on it, once there are windows.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenScreenTagList`, `UnlockPubScreen`
///
/// EXAMPLES:
/// ```zig
/// if (!ib.CloseScreen(screen)) return; // still locked by someone
/// ```
pub fn CloseScreen(ib: *IntuitionBase, screen: ?*Screen) bool {
    const s = screen orelse return true;
    const gb = ib.graphics_base;
    lock(ib);
    defer unlock(ib);
    if (s.pub_node.visitor_count != 0 or !s.windows.isEmpty()) return false;
    ib.sys_base.Remove(@ptrCast(&s.node));
    if (s.public) ib.sys_base.Remove(&s.pub_node.node);
    if (ib.default_pub == s) ib.default_pub = null;
    ib.iface().DisposeObject(s.draw_info.check_mark);
    ib.iface().DisposeObject(s.draw_info.amiga_key);
    ib.iface().DisposeObject(s.depth_image);

    // Its bar goes with the LayerInfo. The display shows its next screen,
    // or - this being its last - its home, left black rather than showing
    // a screen that is no longer there. A buffer of its own goes once it
    // is not shown.
    ib.layers_base.DisposeLayerInfo(s.layer_info);
    s.shown = s.bitmap;
    showFront(ib, s.board, s.home);
    if (s.own_bitmap) {
        gb.FreeRastPort(s.rp);
        if (ib.rtg_base) |rb| rb.FreeBitMap(s.bitmap);
    } else {
        setPen(ib, s.rp, graphics.penRGB(0, 0, 0));
        gb.RectFill(s.rp, &.{ .max_x = s.width, .max_y = s.height });
        gb.FreeRastPort(s.rp);
    }
    if (s.own_font) gb.CloseFont(s.font);
    ib.sys_base.FreeMem(s, @sizeOf(Screen));
    return true;
}
