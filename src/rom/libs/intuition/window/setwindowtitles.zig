// SPDX-License-Identifier: MPL-2.0
//! SetWindowTitles: changes a window's title and the screen title it shows
//! while active.

const sdk = @import("sdk");
const wn = sdk.intuition.windows;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("../screen/_screen.zig");
const _window = @import("_window.zig");
const Window = _window.Window;
const WF_ACTIVE = _window.WF_ACTIVE;
const drawBorder = _window.drawBorder;
const lock = _window.lock;
const unlock = _window.unlock;

/// Changes a window's title and the screen title it shows while active.
///
/// SYNOPSIS:
/// ```zig
/// fn SetWindowTitles(ib: *IntuitionBase, window: *Window,
///     window_title: ?[*:0]const u8, screen_title: ?[*:0]const u8) void
/// ```
///
/// SINCE: 0.10. LVO -232.
///
/// INPUTS:
/// - `window` - the window.
/// - `window_title` - what its title bar says; null for nothing, or
///   `TITLE_UNCHANGED` to leave it.
/// - `screen_title` - what the screen's bar says while this window is the
///   active one; null for nothing, or `TITLE_UNCHANGED` to leave it.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A new window title is drawn at once, with the rest of the border. A new
/// screen title is drawn at once when the window is active, and otherwise
/// the next time it is activated.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The strings are not copied: each must stay as it is for as long as the
/// window shows it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenWindowTagList` (`WA_Title`, `WA_ScreenTitle`), `RefreshWindowFrame`
///
/// EXAMPLES:
/// ```zig
/// ib.SetWindowTitles(window, "Saved", wn.TITLE_UNCHANGED);
/// ```
pub fn SetWindowTitles(ib: *IntuitionBase, window: *Window, window_title: ?[*:0]const u8, screen_title: ?[*:0]const u8) void {
    lock(ib);
    defer unlock(ib);
    if (window_title != wn.TITLE_UNCHANGED) {
        window.title = window_title;
        drawBorder(ib, window);
    }
    if (screen_title != wn.TITLE_UNCHANGED) {
        window.screen_title = screen_title;
        if (window.flags & WF_ACTIVE != 0) {
            window.screen.title = screen_title;
            _screen.drawBar(ib, window.screen);
        }
    }
}
