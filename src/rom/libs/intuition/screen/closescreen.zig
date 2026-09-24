// SPDX-License-Identifier: MPL-2.0
//! CloseScreen: closes a screen.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const lock = _screen.lock;
const setPen = _screen.setPen;
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
/// Its bar and LayerInfo go, the display is left black, and a font the
/// screen opened for itself is closed.
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
    if (s.visitors != 0 or !s.windows.isEmpty()) return false;
    ib.sys_base.Remove(@ptrCast(&s.node));
    ib.iface().DisposeObject(s.draw_info.check_mark);
    ib.iface().DisposeObject(s.draw_info.amiga_key);

    // Its bar goes with the LayerInfo, and the display is left black
    // rather than showing a screen that is no longer there.
    ib.layers_base.DisposeLayerInfo(s.layer_info);
    setPen(ib, s.rp, graphics.penRGB(0, 0, 0));
    gb.RectFill(s.rp, &.{ .max_x = s.width, .max_y = s.height });
    gb.FreeRastPort(s.rp);
    if (s.own_font) gb.CloseFont(s.font);
    ib.sys_base.FreeMem(s, @sizeOf(Screen));
    return true;
}
