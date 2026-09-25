// SPDX-License-Identifier: MPL-2.0
//! ShowTitle: a screen's title bar in front of its backdrop windows, or
//! behind them.

const sdk = @import("sdk");
const layers = sdk.layers;
const TagItem = sdk.utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const _window = @import("../window/_window.zig");
const lock = _screen.lock;
const unlock = _screen.unlock;

/// Puts a screen's title bar in front of its backdrop windows, or behind
/// them.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowTitle(ib: *IntuitionBase, screen: *Screen, show: bool) void
/// ```
///
/// SINCE: 0.14. LVO -392.
///
/// INPUTS:
/// - `screen` - the screen.
/// - `show` - true for the bar in front of the backdrop windows, false for
///   it behind them.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A backdrop window covering the whole screen hides the bar when it is
/// behind, and the bar shows over the window when it is in front. Ordinary
/// windows are always in front of the bar. A backdrop window opened later
/// goes where the bar leaves room for it: behind a bar that is shown, in
/// front of one that is not. A screen without a bar is left as it is.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// A program filling the screen with a backdrop window hides the bar this
/// way and shows it again when the menu button is held.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenScreenTagList` (`SA_ShowTitle`), `OpenWindowTagList` (`WA_Backdrop`)
///
/// EXAMPLES:
/// ```zig
/// ib.ShowTitle(screen, false);
/// ```
pub fn ShowTitle(ib: *IntuitionBase, screen: *Screen, show: bool) void {
    lock(ib);
    defer unlock(ib);
    const bar = screen.bar orelse return;
    const ground = screen.ground orelse return;
    screen.show_title = show;
    const lb = ib.layers_base;
    // What the bar uncovers of a simple-refresh window is repaired, as any
    // change of depth is.
    defer _window.repairScreen(ib, screen);
    if (!show) {
        _ = lb.MoveLayerInFrontOf(bar, ground);
        return;
    }
    // In front of the frontmost layer that belongs to a backdrop window:
    // walked forward from the ground, the backdrop windows' layers come
    // first, then the bar or the first ordinary window.
    var last = ground;
    var at: ?*layers.Layer = inFront(ib, ground);
    while (at) |layer| : (at = inFront(ib, layer)) {
        if (layer == bar) continue;
        if (!ofBackdrop(screen, layer)) break;
        last = layer;
    }
    _ = lb.MoveLayerInFrontOf(bar, last);
}

fn inFront(ib: *IntuitionBase, layer: *layers.Layer) ?*layers.Layer {
    var next: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetInFront, .data = @intFromPtr(&next) }, .{} };
    ib.layers_base.GetLayerAttrs(layer, &ask);
    return @ptrFromInt(next);
}

/// Whether a layer is a backdrop window's: its own, its interior, or one of
/// its requesters'.
fn ofBackdrop(screen: *Screen, layer: *layers.Layer) bool {
    var node = screen.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const w: *_window.Window = @ptrCast(@alignCast(n));
        if (w.flags & _window.WF_BACKDROP == 0) continue;
        if (w.layer == layer or w.inner_layer == layer) return true;
        var req = w.first_request;
        while (req) |r| : (req = r.older) {
            if (r.layer == layer) return true;
        }
    }
    return false;
}
