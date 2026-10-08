// SPDX-License-Identifier: MPL-2.0
//! BeginDrag: a picture dragged with the pointer.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const drag = @import("drag.zig");

/// Starts dragging a picture with the pointer, over every window.
///
/// SYNOPSIS:
/// ```zig
/// fn BeginDrag(ib: *IntuitionBase, window: *Window, image: *const rtg.Surface, hot_x: u32, hot_y: u32) bool
/// ```
///
/// SINCE: 0.34. LVO -512.
///
/// INPUTS:
/// - `window` - the window the drag starts in: its screen is where the
///   picture is shown.
/// - `image` - the picture: a surface in `rgba32`, `bgra32` or
///   `argb1555`, at most `RTG_OVERLAY_MAX` pixels each way - an icon, or
///   a few drawn together.
/// - `hot_x`, `hot_y` - the pixel of the picture that sits at the
///   pointer's point: where it was taken hold of.
///
/// RESULT:
/// True while the picture follows the pointer; false when another drag
/// is on, the display cannot lay a picture over itself, or the picture
/// will not do (too large, no alpha).
///
/// BEHAVIOR:
/// The display lays the picture over everything on the way to the glass,
/// under the pointer, as it lays the pointer: windows go on drawing under
/// it, nothing waits for it, and it moves with every pointer move without
/// the program doing anything. Its coverage is shown as a pattern of
/// dots, so a soft edge or a picture made see-through keeps its look. It
/// is shown on a touch panel too, where the pointer itself is not. The
/// program goes on hearing the pointer as before - `IDCMP_MOUSEMOVE` with
/// `WFLG_REPORTMOUSE`, the button let go as `IDCMP_MOUSEBUTTONS` - and
/// ends the drag with `EndDrag` when it is let go.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and while the display
///   converts the picture.
/// - Interrupts: no. It allocates.
/// - Locks: none needed; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The picture is read and not kept: it may be freed when the call
/// returns.
///
/// NOTES:
/// One drag at a time on the whole system. A window closed while it
/// drags ends the drag.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EndDrag`, rtg.library's `SetBoardOverlay`
///
/// EXAMPLES:
/// ```zig
/// const picture = rtg.Surface{ .pixels = icon.pixels, .width = icon.width, .height = icon.height, .pitch = icon.width * 4, .format = .rgba32 };
/// if (ib.BeginDrag(window, &picture, 24, 24)) {
///     // ... until the button is let go ...
///     const target = ib.EndDrag(window, 0);
///     _ = target;
/// }
/// ```
pub fn BeginDrag(ib: *IntuitionBase, window: *Window, image: *const rtg.Surface, hot_x: u32, hot_y: u32) bool {
    _window.lock(ib);
    defer _window.unlock(ib);
    const st = &ib.drag;
    if (st.window != null) return false;
    const rb = ib.rtg_base orelse return false;
    const board = window.screen.board;
    if (rb.SetBoardOverlay(board, image, hot_x, hot_y) != rtg.errors.RTGERR_OK) return false;
    st.* = .{
        .window = window,
        .board = board,
        .start_x = board.overlay_x,
        .start_y = board.overlay_y,
    };
    return true;
}
