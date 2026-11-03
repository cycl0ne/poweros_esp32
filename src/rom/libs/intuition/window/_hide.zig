// SPDX-License-Identifier: MPL-2.0
//! The hide gadget, and the window that takes in the hidden windows of a
//! screen.
//!
//! Putting a window away is only worth something where something shows
//! the way back, so the fourth gadget in a window's title bar is there
//! only on a screen where a window has said it takes the hidden ones in
//! (`HideControl`) - the dock's own window, where there is a dock. That
//! one window gives three things at once: the screen the gadget belongs
//! on, so a program with a screen of its own is not given a gadget
//! nobody would answer; the place a window goes to, which the animation
//! will fly towards once there is one; and the way back, since the host
//! giving up, closing its window or ending brings every hidden window of
//! the screen back and takes the gadgets off again.
//!
//! The host never carries the gadget itself: a dock put away would take
//! the way back with it.

const sdk = @import("sdk");
const ic = sdk.intuition.imageclass;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const Screen = @import("../screen/_screen.zig").Screen;

/// Whether a window may carry the hide gadget as its screen stands now:
/// the screen has a host, this window is not it, it has a title bar to
/// put the gadget in and room there for one more, and it has not said it
/// would rather not be put away (`WA_HideGadget`, which a system
/// requester says of itself). The on-screen keyboard is left out as
/// intuition's own.
pub fn mayCarry(w: *const Window) bool {
    const host = w.screen.hide_host orelse return false;
    if (host == w) return false;
    if (!_window.hasBar(w)) return false;
    if (w.more_flags & (_window.WMF_NOHIDE | _window.WMF_ABOVE) != 0) return false;
    return fits(w);
}

/// Whether the title bar has room for one more gadget beside the ones
/// already in it: a gadget that sits on top of its neighbours is worse
/// than no gadget, as it is for the zoom gadget at `OpenWindow`.
fn fits(w: *const Window) bool {
    var taken = _window.depthWidthOf(w);
    if (w.flags & _window.WF_CLOSE != 0) taken += _window.closeWidthOf(w);
    if (w.flags & _window.WF_DEPTH != 0) taken += _window.depthWidthOf(w);
    if (w.flags & _window.WF_HASZOOM != 0) taken += _window.depthWidthOf(w);
    return taken <= w.width;
}

/// The gadget put on a window that may have one, and its border drawn
/// again with it. A window that has one already is left as it is, and one
/// there was no memory for simply goes without: a window is worth having
/// without its fourth gadget.
pub fn put(ib: *IntuitionBase, w: *Window) void {
    if (w.hide_image != null or !mayCarry(w)) return;
    w.hide_image = _window.gadgetImage(ib, w.screen, ic.HIDEIMAGE, _window.depthWidthOf(w), w.border_top);
    if (w.hide_image == null) return;
    _window.drawBorder(ib, w);
}

/// The gadget taken off a window, and its border drawn again without it.
/// A press on it that has not been let go reaches nothing: the release
/// finds another part of the window where the gadget was.
pub fn take(ib: *IntuitionBase, w: *Window) void {
    const image = w.hide_image orelse return;
    w.hide_image = null;
    ib.iface().DisposeObject(image);
    _window.drawBorder(ib, w);
}

/// Every window of a screen looked over: the gadget put on those that may
/// have one now, taken off those that may not.
pub fn refit(ib: *IntuitionBase, s: *Screen) void {
    var node = s.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const w: *Window = @ptrCast(@alignCast(n));
        if (mayCarry(w)) put(ib, w) else take(ib, w);
    }
}

/// What `HideControl` does, with intuition's lock already held: the window
/// made its screen's host and the gadgets put on, or the hosting given up
/// again. False when another window of the screen already takes them.
pub fn control(ib: *IntuitionBase, w: *Window, on: bool) bool {
    const s = w.screen;
    if (!on) {
        if (s.hide_host == w) release(ib, s);
        return true;
    }
    if (s.hide_host) |held| return held == w;
    s.hide_host = w;
    w.more_flags |= _window.WMF_HIDEHOST;
    refit(ib, s);
    return true;
}

/// The screen left with no host - it gave the hosting up, its window is
/// closing, or its task ended: every hidden window of the screen shown
/// again where it stood, and every hide gadget taken off, since nothing
/// would answer one now. The caller holds intuition's lock.
pub fn release(ib: *IntuitionBase, s: *Screen) void {
    const host = s.hide_host orelse return;
    s.hide_host = null;
    host.more_flags &= ~_window.WMF_HIDEHOST;
    var node = s.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const w: *Window = @ptrCast(@alignCast(n));
        take(ib, w);
        if (w.more_flags & _window.WMF_HIDDEN != 0) ib.iface().ShowWindow(@ptrCast(w));
    }
}
