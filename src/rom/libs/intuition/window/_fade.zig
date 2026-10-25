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
//! Everything here is under the screen list's lock (`_window.lock`).

const sdk = @import("sdk");
const exec = sdk.exec;
const layers = sdk.layers;
const motion = sdk.motion;
const intuition = sdk.intuition;
const TagItem = sdk.utility.TagItem;
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
fn composed(ib: *IntuitionBase, layer: *layers.Layer) bool {
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
    /// Its screen closed: the layers went with it, and only the
    /// animation is left to end.
    gone: bool = false,
};

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
    fade.turned = fade.animation != null;
    // Nothing is meant for it any more; and it paints nothing, its window
    // being gone with the hook that painted it.
    const lb = ib.layers_base;
    _ = lb.SetLayerAttrsTagList(w.layer, &[_]TagItem{ .{ .tag = layers.LATAG_Ghost, .data = 1 }, .{} });
    _ = lb.InstallLayerHook(w.layer, layers.LAYERS_NOBACKFILL);
    if (w.inner_layer) |inner| _ = lb.InstallLayerHook(inner, layers.LAYERS_NOBACKFILL);
    _input.wakeFades(ib);
    return true;
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
        if (fade.to == 255) {
            if (fade.now != 255) setOpacity(ib, fade.layer, 255);
            if (fade.window) |w| w.fade = null;
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
        if (value != fade.now) {
            fade.now = @intCast(value);
            setOpacity(ib, fade.layer, value);
        }
        if (!running) {
            fade.now = fade.to;
            finish(ib, fade);
        }
    }
}
