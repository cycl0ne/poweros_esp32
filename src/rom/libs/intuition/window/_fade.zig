// SPDX-License-Identifier: MPL-2.0
//! What a window looks like on a screen whose windows are composed: round
//! corners, a shadow on what is behind it, and fading in as it opens and
//! out as it closes (`IPREFS_WindowCorners`, `IPREFS_WindowShadow`,
//! `IPREFS_WindowFade`). Every one is layers.library's to do; this says
//! which windows have them, and drives the fades.
//!
//! **Which windows**: one with a border that is not a backdrop - what is
//! a window to look at. A borderless one is whatever shape its program
//! draws, and a backdrop is the screen's ground.
//!
//! **A fade's steps are motion.library's**, and an animation belongs to
//! the task that made it and goes when that task ends - which the
//! window's program may do while its window fades. So OpenWindow and
//! CloseWindow, on the program's task, only put the window on the list
//! and wake the input task; the input task makes the animation, which
//! signals it at each step, and sets the layers' opacity there
//! (`step`).
//!
//! **A window closed is gone at once**: its program has nothing more to
//! do with it, and nothing of intuition's knows it. What fades is its
//! layers, left on the display as a ghost (`LATAG_Ghost`) - seen, and not
//! there for the pointer - and deleted by the input task when the fade
//! ends. A screen that closes takes its ghosts with it.
//!
//! **A window put away** (`HideWindow`) fades out the same way, and the
//! fade hides its layers at the end rather than deleting them; brought
//! back (`ShowWindow`) it is shown unseen and fades in. It is away from
//! the moment it is asked for, whatever its picture is still doing: it
//! is not the active window, and nothing of the input reaches it while
//! it fades (`windowAt`). Its layers are not made a ghost, unlike a
//! closed window's: a ghost is out of the walk of the depth order, and
//! that walk is how a program lists a window that is away to bring it
//! back. Asked for the other way round while a fade runs, the fade
//! turns round where it is.
//!
//! **A window put away into another window** - one that has taken the
//! hidden windows of its screen in (`HideControl`), which is what the
//! dock does - does not fade: it **flies** there. Its layers are hidden
//! at once and what flies is a picture of their pixels, stretched by
//! layers.library into a box that walks from the window's own to the
//! taker's (`FlyLayer`), the dock's row. Coming back it grows out of that
//! box again, and its layers are shown as the flight ends. Everything
//! else is the fade's: the same list, the same animation, the same
//! turning round where it is.
//!
//! Everything here is under the screen list's lock (`_window.lock`).

const sdk = @import("sdk");
const exec = sdk.exec;
const layers = sdk.layers;
const motion = sdk.motion;
const intuition = sdk.intuition;
const TagItem = sdk.utility.TagItem;
const Rect = sdk.graphics.Rect;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const Screen = @import("../screen/_screen.zig").Screen;
const _input = @import("../input/_input.zig");
const _transition = @import("../style/_transition.zig");

/// The most each preference may be.
pub const most_corners = 16;
pub const most_shadow = 32;
pub const most_fade = 1000;

/// What the system starts with.
pub const default_corners = 6;
pub const default_shadow = 12;
pub const default_fade = 160;

/// Whether a window of these `WFLG_` flags looks like a window: a border,
/// and not a backdrop.
pub fn framed(flags: u32) bool {
    return flags & (_window.WF_BORDERLESS | _window.WF_BACKDROP) == 0;
}

/// The tags a window of these flags is made with, or given when the
/// preferences change: its corners and its shadow, none for one that is
/// not `framed`. The layers library ignores them where it does not
/// compose.
pub fn lookOf(ib: *IntuitionBase, flags: u32) [3]TagItem {
    const yes = framed(flags);
    return .{
        .{ .tag = layers.LATAG_Corners, .data = if (yes) ib.window_corners else 0 },
        .{ .tag = layers.LATAG_Shadow, .data = if (yes) ib.window_shadow else 0 },
        .{},
    };
}

/// The radius a window's corners are cut at: 0 for square ones - a
/// window that is not `framed`, or not composed - as layers.library works
/// it out from the preference and the window's size.
pub fn radiusOf(ib: *IntuitionBase, w: *Window) u32 {
    if (ib.window_corners == 0 or !framed(w.flags) or !composed(ib, w.layer)) return 0;
    return layers.cornerRadius(ib.window_corners, @intCast(w.width), @intCast(w.height));
}

/// Whether a layer is composed, and so can look like anything.
pub fn composed(ib: *IntuitionBase, layer: *layers.Layer) bool {
    var yes: u32 = 0;
    ib.layers_base.GetLayerAttrs(layer, &[_]TagItem{ .{ .tag = layers.LATAG_GetComposed, .data = @intFromPtr(&yes) }, .{} });
    return yes != 0;
}

/// Whether a window opening with these flags fades in: its layers are
/// made unseen, and `fadeIn` shows them.
pub fn fades(ib: *IntuitionBase, flags: u32) bool {
    return ib.window_fade != 0 and framed(flags) and _input.fadeSignal(ib) != null;
}

/// A window on its way in or out.
pub const Fade = struct {
    node: exec.MinNode = .{},
    screen: *Screen,
    /// Its layer, and its inside's (a GimmeZeroZero window's), which
    /// moves with it and is set with it (`LATAG_MovesWith`).
    layer: *layers.Layer,
    inner: ?*layers.Layer,
    /// The window while it is open; null once it has closed and the
    /// layers are a ghost's.
    window: ?*Window,
    /// The input task's, made by `step`; null until then.
    animation: ?*motion.Animation = null,
    /// How much the layers cover now, and where it is going: 255 in, 0
    /// out.
    now: u8,
    to: u8,
    /// It has turned since its animation was made: closed while it came.
    turned: bool = false,
    /// What the end of a fade out means: the layers hidden, the window
    /// being put away (`HideWindow`), or deleted, the window having
    /// closed.
    hides: bool = false,
    /// Its screen closed: the layers went with it, and only the
    /// animation is left to end.
    gone: bool = false,
    /// Where it flies: its own box, and the box of the window that takes
    /// the hidden windows of the screen in. `cell` is empty when it does
    /// not fly but fades, which is every window on a screen with no such
    /// window.
    home: Rect = .{},
    cell: Rect = .{},

    /// Whether it flies rather than fades.
    fn flies(fade: *const Fade) bool {
        return !fade.cell.isEmpty();
    }
};

/// Where a window is, in its screen's coordinates.
fn boxOf(w: *const Window) Rect {
    return .{ .min_x = w.left, .min_y = w.top, .max_x = w.left + w.width, .max_y = w.top + w.height };
}

/// Where a window flies from, and to. Both empty where nothing flies,
/// and then it fades.
const Flight = struct { home: Rect = .{}, cell: Rect = .{} };

/// Where a window put away flies to, and from: the box of the window
/// that has taken the hidden windows of the screen in (`HideControl`),
/// and the window's own. Nowhere where nothing flies - no such window on
/// the screen, or the window being that window itself - and then it
/// fades instead.
fn flightOf(w: *const Window) Flight {
    const host = w.screen.hide_host orelse return .{};
    if (host == w) return .{};
    const home = boxOf(w);
    const cell = boxOf(host);
    if (home.isEmpty() or cell.isEmpty()) return .{};
    return .{ .home = home, .cell = cell };
}

/// Where the picture of a flying window is at `value`: its own box at
/// 255, the box it flies into at 0, and between the two on the way.
fn boxAt(fade: *const Fade, value: u32) Rect {
    const at: i32 = @intCast(value);
    const from = fade.cell;
    const to = fade.home;
    return .{
        .min_x = from.min_x + @divTrunc((to.min_x - from.min_x) * at, 255),
        .min_y = from.min_y + @divTrunc((to.min_y - from.min_y) * at, 255),
        .max_x = from.max_x + @divTrunc((to.max_x - from.max_x) * at, 255),
        .max_y = from.max_y + @divTrunc((to.max_y - from.max_y) * at, 255),
    };
}

/// The picture of a flying window shown where `value` puts it.
fn flyTo(ib: *IntuitionBase, fade: *Fade, value: u32) void {
    const box = boxAt(fade, value);
    _ = ib.layers_base.FlyLayer(fade.layer, &box);
}

/// A flight ended: nothing of it is on the display any more, and the
/// fade is a plain one from here on.
fn endFlight(ib: *IntuitionBase, fade: *Fade) void {
    if (!fade.flies()) return;
    fade.cell = .{};
    _ = ib.layers_base.FlyLayer(fade.layer, &Rect{});
}

/// The layers' opacity set: the inside's goes with it.
fn setOpacity(ib: *IntuitionBase, layer: *layers.Layer, value: u32) void {
    _ = ib.layers_base.SetLayerAttrsTagList(layer, &[_]TagItem{ .{ .tag = layers.LATAG_Opacity, .data = value }, .{} });
}

/// A window just opened, its layers unseen, put on its way in. Without
/// the memory, or a layer that is not composed, it is shown at once.
pub fn fadeIn(ib: *IntuitionBase, w: *Window) void {
    const sys = ib.sys_base;
    if (!composed(ib, w.layer)) return;
    const memory = sys.AllocVec(@sizeOf(Fade), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return setOpacity(ib, w.layer, 255);
    // The system's: it may outlive the program that opened the window.
    _ = sys.SetMemOwner(memory, null);
    const fade: *Fade = @ptrCast(@alignCast(memory));
    fade.* = .{ .screen = w.screen, .layer = w.layer, .inner = w.inner_layer, .window = w, .now = 0, .to = 255 };
    w.fade = fade;
    sys.AddTail(@ptrCast(&ib.fades), @ptrCast(&fade.node));
    _input.wakeFades(ib);
}

/// A window closing: its layers left to fade out as a ghost's. True when
/// they are, and the caller does not delete them; false when the window
/// does not fade, or there was no memory.
pub fn fadeOut(ib: *IntuitionBase, w: *Window) bool {
    const sys = ib.sys_base;
    const fade: *Fade = w.fade orelse made: {
        // A window that is away is not seen: there is nothing to fade,
        // and its layers go at once.
        if (w.more_flags & _window.WMF_HIDDEN != 0) return false;
        if (!fades(ib, w.flags) or !composed(ib, w.layer)) return false;
        const memory = sys.AllocVec(@sizeOf(Fade), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
        _ = sys.SetMemOwner(memory, null);
        const made: *Fade = @ptrCast(@alignCast(memory));
        made.* = .{ .screen = w.screen, .layer = w.layer, .inner = w.inner_layer, .window = w, .now = 255, .to = 255 };
        sys.AddTail(@ptrCast(&ib.fades), @ptrCast(&made.node));
        break :made made;
    };
    w.fade = null;
    fade.window = null;
    fade.to = 0;
    fade.hides = false;
    fade.turned = fade.animation != null;
    if (fade.flies()) {
        // It was flying into the dock, or out of it, when its program
        // closed it: the picture goes off the display at once, and all
        // that is left of its way out is the layers going at the next
        // step - its pixels were never on the display to fade.
        endFlight(ib, fade);
        fade.now = 0;
    }
    // Nothing is meant for it any more; and it paints nothing, its window
    // being gone with the hook that painted it.
    const lb = ib.layers_base;
    _ = lb.SetLayerAttrsTagList(w.layer, &[_]TagItem{ .{ .tag = layers.LATAG_Ghost, .data = 1 }, .{} });
    _ = lb.InstallLayerHook(w.layer, layers.LAYERS_NOBACKFILL);
    if (w.inner_layer) |inner| _ = lb.InstallLayerHook(inner, layers.LAYERS_NOBACKFILL);
    _input.wakeFades(ib);
    return true;
}

/// A window being put away (`HideWindow`): its layers fade out, and the
/// fade hides them when it ends. True when that is under way and the
/// caller leaves the layers to the fade; false when the window does not
/// fade - the caller hides them itself, as it always did.
pub fn hiding(ib: *IntuitionBase, w: *Window) bool {
    const sys = ib.sys_base;
    if (w.fade) |fade| {
        // One on its way in, or back out of the dock, is turned round
        // where it is: a fade from the cover it has now, a flight from
        // the size it has now. A window already on its way in when it is
        // put away fades rather than flies: there is nothing to gain from
        // a picture jumping to full size to fly from there.
        fade.to = 0;
        fade.hides = true;
        fade.turned = fade.animation != null;
        _input.wakeFades(ib);
        return true;
    }
    if (!fades(ib, w.flags) or !composed(ib, w.layer)) return false;
    const memory = sys.AllocVec(@sizeOf(Fade), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    // The system's: it may outlive the program that opened the window.
    _ = sys.SetMemOwner(memory, null);
    const fade: *Fade = @ptrCast(@alignCast(memory));
    const flight = flightOf(w);
    fade.* = .{
        .screen = w.screen,
        .layer = w.layer,
        .inner = w.inner_layer,
        .window = w,
        .now = 255,
        .to = 0,
        .hides = true,
        .home = flight.home,
        .cell = flight.cell,
    };
    w.fade = fade;
    sys.AddTail(@ptrCast(&ib.fades), @ptrCast(&fade.node));
    if (fade.flies()) {
        // A window that flies is off the display from here: its layers
        // are hidden and what it covered is repaired, and what flies is
        // a picture of the pixels they keep for it. Drawn at full size
        // here, so nothing of it blinks out before the first step.
        _window.hideLayers(ib, w, true);
        _window.repairScreen(ib, w.screen);
        flyTo(ib, fade, 255);
    }
    // The layers of a window that fades are not made a ghost: a ghost is
    // out of the walk of the depth order (`LATAG_GetInFront`), and that
    // walk is how a program lists a window that is away in order to bring
    // it back. Seen and out of reach is intuition's own doing -
    // `windowAt` passes over a window that is away, whatever its picture
    // is still doing.
    _input.wakeFades(ib);
    return true;
}

/// What `ShowWindow` has left to do, a window being brought back:
/// `turned` - nothing, the way back being under way already: a fade that
/// was putting it away turned round where it is, its layers never having
/// been hidden, or a flight out of the dock, which shows them as it ends;
/// `fades` - its layers are to be shown by the caller and are unseen, a
/// fade in under way; `at_once` - shown as they always were.
pub const Showing = enum { turned, fades, at_once };

pub fn showing(ib: *IntuitionBase, w: *Window) Showing {
    const sys = ib.sys_base;
    if (w.fade) |fade| {
        if (!fade.hides) return .at_once;
        fade.hides = false;
        fade.to = 255;
        fade.turned = fade.animation != null;
        _input.wakeFades(ib);
        return .turned;
    }
    if (!fades(ib, w.flags) or !composed(ib, w.layer)) return .at_once;
    const memory = sys.AllocVec(@sizeOf(Fade), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return .at_once;
    _ = sys.SetMemOwner(memory, null);
    const fade: *Fade = @ptrCast(@alignCast(memory));
    const flight = flightOf(w);
    fade.* = .{
        .screen = w.screen,
        .layer = w.layer,
        .inner = w.inner_layer,
        .window = w,
        .now = 0,
        .to = 255,
        .home = flight.home,
        .cell = flight.cell,
    };
    w.fade = fade;
    sys.AddTail(@ptrCast(&ib.fades), @ptrCast(&fade.node));
    _input.wakeFades(ib);
    if (fade.flies()) {
        // It comes out of the box it went into: a picture of its pixels
        // grows out of there while its layers stay hidden, and the end of
        // the flight shows them where they have been all along.
        flyTo(ib, fade, 0);
        return .turned;
    }
    // Unseen before it is shown, so nothing of it flashes up at once.
    setOpacity(ib, w.layer, 0);
    return .fades;
}

/// A screen closing: its ghosts go with its LayerInfo, and their fades
/// end. The input task gives back what is left of them.
pub fn forgetScreen(ib: *IntuitionBase, s: *Screen) void {
    var at = ib.fades.head;
    while (at) |node| : (at = node.succ) {
        if (node.succ == null) break;
        const fade: *Fade = @ptrCast(@alignCast(node));
        if (fade.screen == s) fade.gone = true;
    }
    _input.wakeFades(ib);
}

/// A window's way in or out ended: one come in is all there, one gone out
/// has its layers deleted. The animation and the fade are given back.
fn finish(ib: *IntuitionBase, fade: *Fade) void {
    const sys = ib.sys_base;
    if (!fade.gone) {
        // A picture on the display goes first, and the display is put
        // right where it was.
        const flew = fade.flies();
        endFlight(ib, fade);
        if (fade.to == 255) {
            if (fade.window) |w| {
                w.fade = null;
                // Flown home: its layers are shown again where they have
                // been all along, and what it covers is drawn again.
                if (flew) {
                    _window.hideLayers(ib, w, false);
                    _window.repairScreen(ib, w.screen);
                }
            }
            if (!flew and fade.now != 255) setOpacity(ib, fade.layer, 255);
        } else if (fade.hides) {
            // Put away: the layers are hidden rather than deleted, and
            // left at full cover, which is how they come back. A window
            // that flew had them hidden as it set off.
            if (fade.window) |w| {
                w.fade = null;
                if (!flew) {
                    _window.hideLayers(ib, w, true);
                    setOpacity(ib, fade.layer, 255);
                    _window.repairScreen(ib, w.screen);
                }
            }
        } else {
            if (fade.inner) |inner| ib.layers_base.DeleteLayer(inner);
            ib.layers_base.DeleteLayer(fade.layer);
        }
    }
    if (fade.animation) |animation| _transition.motionOf(ib).?.DeleteAnimation(animation);
    sys.Remove(@ptrCast(&fade.node));
    sys.FreeVec(fade);
}

/// The fades seen to, on the input task, woken by one of them: each new
/// one's animation made and started, each turned one's made again from
/// where it is, each step's opacity set, each one ended finished.
pub fn step(ib: *IntuitionBase) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    const signal = _input.fadeSignal(ib) orelse return;
    var at = ib.fades.head;
    while (at) |node| {
        if (node.succ == null) break;
        at = node.succ;
        const fade: *Fade = @ptrCast(@alignCast(node));
        if (fade.gone) {
            finish(ib, fade);
            continue;
        }
        const mb = _transition.motionOf(ib) orelse {
            fade.now = fade.to;
            finish(ib, fade);
            continue;
        };
        if (fade.turned) {
            fade.turned = false;
            if (fade.animation) |animation| mb.DeleteAnimation(animation);
            fade.animation = null;
        }
        const animation = fade.animation orelse made: {
            // As long as the whole way takes, for the part of it left.
            const left: u32 = if (fade.to > fade.now) fade.to - fade.now else fade.now - fade.to;
            const settings = [_]TagItem{
                .{ .tag = motion.ANIM_From, .data = fade.now },
                .{ .tag = motion.ANIM_To, .data = fade.to },
                .{ .tag = motion.ANIM_Duration, .data = @max(1, ib.window_fade * left / 255) },
                .{ .tag = motion.ANIM_Easing, .data = motion.EASE_OUT },
                .{ .tag = motion.ANIM_Rate, .data = 60 },
                .{ .tag = motion.ANIM_Signal, .data = signal },
                .{},
            };
            const made = mb.CreateAnimationTagList(&settings) orelse {
                fade.now = fade.to;
                finish(ib, fade);
                continue;
            };
            fade.animation = made;
            mb.StartAnimation(made);
            break :made made;
        };
        const raw: i32 = @truncate(@as(isize, @bitCast(mb.GetAnimationAttr(animation, motion.ANIM_Value))));
        const value: u32 = @intCast(@max(0, @min(255, raw)));
        const running = mb.GetAnimationAttr(animation, motion.ANIM_Running) != 0;
        if (fade.flies()) {
            // Every step draws the picture again: it is on the display,
            // not in the arrangement, so whatever was shown over it in
            // the meantime is drawn over again here.
            fade.now = @intCast(value);
            flyTo(ib, fade, value);
        } else if (value != fade.now) {
            fade.now = @intCast(value);
            setOpacity(ib, fade.layer, value);
        }
        if (!running) {
            fade.now = fade.to;
            finish(ib, fade);
        }
    }
}
