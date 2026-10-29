// SPDX-License-Identifier: MPL-2.0
//! Windows: what the window calls share - the structure behind the SDK's
//! opaque `Window`, its border, its messages and the damage after a change.
//!
//! A window is a layer of its screen's LayerInfo, drawn at its own corner,
//! with a border around the part a program draws in. The border is drawn
//! here, through the window's own RastPort, and each of its pieces is an
//! image: a frameiclass object for the frame outside and the one sunk
//! around the inside, sysiclass objects for the gadgets. It is drawn again
//! whenever the window is activated, deactivated or sized, and - for a
//! simple-refresh window - whenever a part of it is uncovered.
//!
//! **Damage.** Anything that changes what is where on a screen may
//! uncover part of a simple-refresh window, which kept nothing there.
//! After every such change each simple window of the screen is looked at:
//! if it has damage, its border is put back inside the damage, and either
//! the program is told (IDCMP_REFRESHWINDOW, at most one waiting) or, when
//! it did not ask to be, the damage is thrown away.
//!
//! **Messages** are allocated here, put on the window's port, and come
//! back by ReplyMsg to a port inside the window that nothing waits on;
//! they are freed from there the next time the window sends one, and
//! when it closes.
//!
//! **The depth order** has ranks, from the back: backdrop windows, the
//! ordinary ones, those that stay in front (`WA_StayInFront`), and the
//! on-screen keyboard. A window opens, comes to the front and goes to the
//! back among those of its own rank (`toFront`, `toBack`); menus and a
//! gadget's list popped up are layers of no window and go in front of
//! them all.
//!
//! Every window and the active one are guarded by the screen list's
//! semaphore, which nests.
//!
//! **A window is its opener's**: the task that opened it, which its port
//! signals. Each task with windows open has an `Opener` on intuition's
//! list, with an end hook on the task: a task that ends with windows still
//! open - its code returned, it was removed, or killed - has them closed,
//! and a line on the log says so. A window opened inside
//! `BeginSystemMemory` is the system's and has no opener.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const layers = sdk.layers;
const intuition = sdk.intuition;
const sc = intuition.screens;
const wn = intuition.windows;
const ic = intuition.imageclass;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("../screen/_screen.zig");
const Screen = _screen.Screen;
const d = @import("../classes/draw.zig");
const _gadget = @import("../gadget/_gadget.zig");
const ie = sdk.devices.inputevent;

/// What a window is, behind the opaque `sdk.intuition.Window`.
pub const Window = extern struct {
    /// On its screen's list of windows.
    node: exec.MinNode = .{},
    screen: *Screen,
    layer: *layers.Layer,
    /// The layer's: (0,0) is the window's top-left, border included. This
    /// one is the program's - `WA_RastPort` hands it out.
    rp: *graphics.RastPort,
    /// A GimmeZeroZero window's interior: a layer of its own in front of
    /// the outer one, covering the part inside the border, with `(0, 0)` at
    /// that corner. The program draws here and never adds the border widths
    /// itself; the border and its gadgets stay on the outer layer, where
    /// nothing the program draws can reach them.
    ///
    /// Null for an ordinary window, whose one layer is both.
    inner_layer: ?*layers.Layer = null,
    inner_rp: ?*graphics.RastPort = null,
    /// The font the program's text is in: one of the system's fonts
    /// (`WA_SysFont`), held open for the window's life. Null when none
    /// could be opened, and then the text is in the screen's font.
    text_font: ?*graphics.TextFont = null,
    /// A second RastPort onto the same pixels, for the gadgets.
    ///
    /// `ObtainGIRPort` gives this one out, never the program's, so that a
    /// gadget setting a pen, a draw mode or a font cannot disturb what the
    /// program is drawing with - and so that a clip region the program
    /// installed does not clip the gadget, which has nothing to do with it.
    /// Where it draws is taken from the program's afresh on every obtain,
    /// since layers moves the window's pixels about as the display changes.
    /// One to a window is enough: `ObtainGIRPort` holds the layer, so only
    /// one holder at a time can have it.
    gi_rp: ?*graphics.RastPort = null,
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    min_width: i32,
    min_height: i32,
    max_width: i32,
    max_height: i32,
    /// The smallest size the layouts sized by the window said, in the
    /// layout pass that set it, they fit in: more than the window has when
    /// a row of one wrapped, and `fitLayout` grows the window to it. 0
    /// with no such layout.
    layout_width: i32 = 0,
    layout_height: i32 = 0,
    border_left: i32 = 0,
    border_top: i32 = 0,
    border_right: i32 = 0,
    border_bottom: i32 = 0,
    title: ?[*:0]const u8 = null,
    /// What the screen's title bar says while this window is active.
    screen_title: ?[*:0]const u8 = null,
    /// The window's own two pens. They default to the screen's, so a window
    /// that asks for neither looks like the screen it is on.
    detail_pen: Pen = 0,
    block_pen: Pen = 0,
    flags: u32 = 0,
    idcmp: u32 = 0,
    user_port: ?*exec.MsgPort = null,
    /// Its menus: the program's strip, or null.
    menu_strip: ?*intuition.Menu = null,
    /// What a checked item of its menus shows, and what an item's shortcut
    /// does: WA_Checkmark and WA_AmigaKey, or the screen's.
    check_mark: ?*Object = null,
    amiga_key: ?*Object = null,
    /// The window whose menus the menu button shows while this one is
    /// active (LendMenus), or null for its own.
    menu_lend: ?*Window = null,
    /// `WMF_` bits: this library's own, beside `flags`.
    more_flags: u32 = 0,
    /// When it was last made active, in `activations`: 0 for never. The
    /// window that takes the activation back when the active one closes
    /// is the one with the highest number on the screen.
    activated: u32 = 0,
    /// Its number, from `window_numbers` as it opened: no other window
    /// has it while the machine runs, so a program that keeps the number
    /// can ask whether the window is still open (`FindWindowNumber`)
    /// where a pointer might by then be another window's.
    number: u32 = 0,
    /// Its help group: every window with the same number shares gadget
    /// help (`WA_HelpGroup`).
    help_group: u32 = 0,
    /// The requesters up in it, the newest - the one whose gadgets are
    /// pressed - first, linked through each one's `older`; how many.
    first_request: ?*intuition.Requester = null,
    req_count: u32 = 0,
    /// What a double-click of the menu button puts up (SetDMRequest).
    dm_request: ?*intuition.Requester = null,
    /// What BuildEasyRequestArgs made for a requester this window is, for
    /// FreeSysRequest to give back; null for any other window.
    request: ?*anyopaque = null,
    /// Where replied messages come back to: flagged PA_IGNORE, so nothing
    /// is signalled, and emptied the next time the window sends one.
    reply_port: exec.MsgPort = .{ .flags = exec.PA_IGNORE },
    /// Where the zoom gadget flips to, and where it came from. A window
    /// showing the first has `WF_ZOOMED`; the second is where it was when
    /// it was last zoomed, so using the gadget twice puts it back.
    zoom_box: wn.WindowBox = .{ .left = 0, .top = 0, .width = 0, .height = 0 },
    unzoom_box: wn.WindowBox = .{ .left = 0, .top = 0, .width = 0, .height = 0 },
    /// The frame, drawn raised outside and sunk inside.
    frame: ?*Object = null,
    close_image: ?*Object = null,
    depth_image: ?*Object = null,
    zoom_image: ?*Object = null,
    size_image: ?*Object = null,
    /// Its gadgets, linked through each gadget's `next`.
    gadgets: ?*Object = null,
    /// How many IDCMP_MOUSEMOVE messages are out unreplied, and how many
    /// may be. A program slower than the pointer would otherwise have one
    /// allocated per move for as long as the drag lasts.
    mouse_pending: u32 = 0,
    mouse_limit: u32 = wn.DEFAULTMOUSEQUEUE,
    /// The same for a key repeating and for the interim updates a gadget
    /// sends while it is dragged - both arrive as fast as the input does
    /// and both say the same kind of thing over again.
    rpt_pending: u32 = 0,
    rpt_limit: u32 = wn.DEFAULTRPTQUEUE,
    /// Its pointer while it is active: a pointerclass object or null for
    /// the default one, the busy pointer in place of either, or none at
    /// all (`WA_HidePointer`) in place of every one.
    pointer: ?*Object = null,
    pointer_busy: u8 = 0,
    pointer_hidden: u8 = 0,
    /// A change put off with `WA_PointerDelay`: what it will be, and the
    /// ticks left until it is made - 0 when none is waiting.
    deferred_busy: u8 = 0,
    deferred_hidden: u8 = 0,
    deferred_ticks: u8 = 0,
    pad_pointer: [3]u8 = .{ 0, 0, 0 },
    deferred_pointer: ?*Object = null,
    /// How its layer paints a part with nothing in it yet - when it opens,
    /// grows, or is uncovered without keeping what was there: the screen's
    /// background pen, whatever pens the program has set on its RastPort.
    backfill: utility.Hook = .{},
    base: *IntuitionBase,
    /// The task that opened it, closing it when it ends; null for one
    /// opened inside `BeginSystemMemory`, or with no memory to note it.
    opener: ?*Opener = null,
    /// Its way in while it fades in (window/_fade.zig), else null.
    fade: ?*@import("_fade.zig").Fade = null,
};

/// A task with windows open: how many, and the end hook that closes them
/// should it end first. Made with its first window, freed with its last.
pub const Opener = extern struct {
    node: exec.MinNode = .{},
    hook: exec.TaskEndHook,
    ib: *IntuitionBase,
    task: *exec.Task,
    windows: u32 = 0,
};

/// A window just opened noted as its opener's: the running task's Opener
/// found, or made and its end hook put on. Nothing for a task inside
/// `BeginSystemMemory`, whose windows are the system's, nor when there is
/// no memory for an Opener - the window is then left when its task ends,
/// as any window was. The caller holds intuition's lock.
///
/// INPUTS:
/// - `ib` - intuition: its openers.
/// - `w` - the window, opened.
pub fn noteOpener(ib: *IntuitionBase, w: *Window) void {
    const sys = ib.sys_base;
    const task = sys.FindTask(null).?;
    if (task.system_memory_nest != 0) return;
    const opener = findOpener(ib, task) orelse made: {
        const memory = sys.AllocMem(@sizeOf(Opener), exec.MEMF_SYSTEM | exec.MEMF_CLEAR) orelse return;
        const made: *Opener = @ptrCast(@alignCast(memory));
        made.* = .{ .hook = .{ .code = &openerEnded }, .ib = ib, .task = task };
        sys.AddTaskEndHook(task, &made.hook);
        sys.AddTail(@ptrCast(&ib.openers), @ptrCast(&made.node));
        break :made made;
    };
    opener.windows += 1;
    w.opener = opener;
}

/// A window that closes taken off its opener's count, and the Opener freed
/// with its last window - its end hook taken off the task. The caller
/// holds intuition's lock.
///
/// INPUTS:
/// - `ib` - intuition: its openers.
/// - `w` - the window, closing.
pub fn dropOpener(ib: *IntuitionBase, w: *Window) void {
    const opener = w.opener orelse return;
    w.opener = null;
    opener.windows -= 1;
    if (opener.windows != 0) return;
    const sys = ib.sys_base;
    sys.RemTaskEndHook(&opener.hook);
    sys.Remove(@ptrCast(&opener.node));
    sys.FreeMem(opener, @sizeOf(Opener));
}

fn findOpener(ib: *IntuitionBase, task: *exec.Task) ?*Opener {
    var node = ib.openers.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const opener: *Opener = @ptrCast(@alignCast(n));
        if (opener.task == task) return opener;
    }
    return null;
}

/// A window of `opener`'s still open, on any screen, or null.
fn windowOf(ib: *IntuitionBase, opener: *Opener) ?*Window {
    var screens = ib.screen_list.head;
    while (screens) |sn| : (screens = sn.succ) {
        if (sn.succ == null) break;
        const s: *Screen = @ptrCast(@alignCast(sn));
        var node = s.windows.head;
        while (node) |n| : (node = n.succ) {
            if (n.succ == null) break;
            const w: *Window = @ptrCast(@alignCast(n));
            if (w.opener == opener) return w;
        }
    }
    return null;
}

/// The end hook of a task with windows open: each one closed, through
/// `CloseWindow` as the task would have, then the Opener freed, and a line
/// on the log. A window is taken from its opener before it is closed, so
/// the close does not count it down again.
fn openerEnded(sys_base: *sdk.interface.exec.ExecBase, task: *exec.Task, hook: *exec.TaskEndHook) callconv(.c) void {
    const opener: *Opener = @fieldParentPtr("hook", hook);
    const ib = opener.ib;
    var closed: u32 = 0;
    while (true) {
        lock(ib);
        const w = windowOf(ib, opener) orelse {
            sys_base.Remove(@ptrCast(&opener.node));
            unlock(ib);
            break;
        };
        w.opener = null;
        unlock(ib);
        ib.iface().CloseWindow(@ptrCast(w));
        closed += 1;
    }
    sys_base.FreeMem(opener, @sizeOf(Opener));
    if (closed == 0) return;
    exec.kprintf(sys_base, "intuition: task \"%.32s\" #%u ended with %u window%s open - closed\n", .{
        task.name().ptr,
        task.id,
        closed,
        @as([*:0]const u8, if (closed == 1) "" else "s"),
    });
}

// A window's flags are the SDK's `WFLG_`, so that the word `WA_Flags`
// carries means here what it says on the tag. These are the short names the
// code reads with; the two at the end are this library's own business and
// sit where no settable bit does.
/// The layer a program draws in: its own for a GimmeZeroZero window, the
/// only one there is for any other.
pub fn innerLayer(w: *const Window) *layers.Layer {
    return w.inner_layer orelse w.layer;
}

/// The RastPort that goes with it.
pub fn innerRastPort(w: *const Window) *graphics.RastPort {
    return w.inner_rp orelse w.rp;
}

/// Where the interior begins, in the window's own coordinates: the border
/// for a GimmeZeroZero window, nothing for any other, since for those the
/// two are the same place.
pub fn innerOrigin(w: *const Window) struct { x: i32, y: i32 } {
    if (w.inner_layer == null) return .{ .x = 0, .y = 0 };
    return .{ .x = w.border_left, .y = w.border_top };
}

/// How big a part of a window is.
pub const Size = struct { width: i32, height: i32 };

/// The room a program has to draw in: the interior for a GimmeZeroZero
/// window, the whole window for any other, since for those a gadget's box
/// is measured against the window itself.
pub fn innerSize(w: *const Window) Size {
    if (w.inner_layer == null) return .{ .width = w.width, .height = w.height };
    return .{
        .width = w.width - w.border_left - w.border_right,
        .height = w.height - w.border_top - w.border_bottom,
    };
}

/// The interior's size whether or not it is a layer of its own - what
/// `WA_InnerWidth` and `WA_InnerHeight` answer.
pub fn interior(w: *const Window) Size {
    return .{
        .width = w.width - w.border_left - w.border_right,
        .height = w.height - w.border_top - w.border_bottom,
    };
}

pub const WF_CLOSE = wn.WFLG_CLOSEGADGET;
pub const WF_DEPTH = wn.WFLG_DEPTHGADGET;
pub const WF_SIZE = wn.WFLG_SIZEGADGET;
pub const WF_DRAG = wn.WFLG_DRAGBAR;
pub const WF_SIZE_BRIGHT = wn.WFLG_SIZEBRIGHT;
pub const WF_SIZE_BBOTTOM = wn.WFLG_SIZEBBOTTOM;
pub const WF_BACKDROP = wn.WFLG_BACKDROP;
pub const WF_SIMPLE = wn.WFLG_SIMPLE_REFRESH;
pub const WF_SUPER = wn.WFLG_SUPER_BITMAP;
pub const WF_BORDERLESS = wn.WFLG_BORDERLESS;
pub const WF_NOCARE = wn.WFLG_NOCAREREFRESH;
pub const WF_ACTIVE = wn.WFLG_WINDOWACTIVE;
pub const WF_RMBTRAP = wn.WFLG_RMBTRAP;
pub const WF_REPORTMOUSE = wn.WFLG_REPORTMOUSE;
pub const WF_GZZ = wn.WFLG_GIMMEZEROZERO;
pub const WF_ZOOMED = wn.WFLG_ZOOMED;
pub const WF_NOACTIVATE = wn.WFLG_NOACTIVATE;
pub const WF_HASZOOM = wn.WFLG_HASZOOM;
pub const WF_MENUSTATE = wn.WFLG_MENUSTATE;
pub const WF_INREQUEST = wn.WFLG_INREQUEST;
/// WA_MenuHelp: the Help key ends a menu session with IDCMP_MENUHELP.
pub const WMF_MENUHELP: u32 = 1 << 0;
/// It was sent IDCMP_MENUVERIFY `MENUWAITING`, and is owed a `MENUUP` when
/// the menus are gone.
pub const WMF_NEEDMENUCLEAR: u32 = 1 << 1;
/// Opened on a public screen found by name or as the default: it holds a
/// visit to the screen until it closes.
pub const WMF_VISITOR: u32 = 1 << 2;
/// Gadget help is on for it (`HelpControl`).
pub const WMF_GADGETHELP: u32 = 1 << 3;
/// Its port is the program's (`WA_UserPort` given at open), shared with
/// its other windows: only its own messages are taken off, and the port
/// stays.
pub const WMF_SHARED_PORT: u32 = 1 << 4;
/// It stays in front of every ordinary window (`WA_StayInFront`).
pub const WMF_STAYINFRONT: u32 = 1 << 5;
/// It is intuition's own and in front even of the windows that stay in
/// front: the on-screen keyboard (`WA_Above`).
pub const WMF_ABOVE: u32 = 1 << 6;

/// intuition.library's own tag, not in the SDK: true opens a window in
/// front of every other, those that stay in front included, and keeps it
/// there. Only the on-screen keyboard is opened with it.
pub const WA_Above = wn.WA_Dummy + 0x1FF;
/// Inside BeginRefresh, so EndRefresh has an update to end.
pub const WF_IN_REFRESH = wn.WFLG_WINDOWREFRESH;
/// An IDCMP_INTUITICKS is waiting; no second is sent until it is replied.
pub const WF_TICK_SENT = wn.WFLG_WINDOWTICKED;

/// An IDCMP_REFRESHWINDOW is waiting; no second is sent until BeginRefresh.
/// This library's own, on a bit no program may set.
pub const WF_REFRESH_SENT: u32 = 0x40000000;
/// IDCMP_CHANGEWINDOW when the depth order changes as well. The reference
/// keeps this in a second word of its own; one word is enough here.
pub const WF_NOTIFYDEPTH: u32 = 0x80000000;

/// The title bar's height on a screen whose font is `font_height` rows:
/// the font with a row of ground above it and two below. It is the
/// height of every gadget in the bar as well, and of the sizing gadget
/// in the corner, which is what makes the corner square with the bar.
pub fn barHeight(font_height: u32) i32 {
    return @as(i32, @intCast(font_height)) + 3;
}

/// The widths of the gadgets drawn in the bar and in the corner, each
/// given as a proportion of that height.
///
/// A pixel on these panels is square, so the shape a gadget is drawn in
/// is the shape of its two numbers. The sizing gadget is a fifth wider
/// than it is tall. The bar's gadgets have two shapes, and `wide`
/// (`IPREFS_WideGadgets`) picks one: narrow, the close gadget is 15 by
/// 11 and the depth and zoom gadgets 18 by 11, about as wide as they are
/// tall, their drawings squeezed across by a quarter; wide, they are 20
/// by 11 and 24 by 11, the grids their drawings are laid out on in
/// sysiclass, so a drawing is scaled the same across as down. Taking
/// them from the bar's height rather than fixing them in pixels keeps
/// the shapes whatever font the screen is opened with; at an eight-row
/// font the bar is 11 rows and the bar's gadgets are those numbers to
/// the pixel.
pub fn sizeWidth(font_height: u32) i32 {
    return @divTrunc(barHeight(font_height) * 13, 11);
}

pub fn closeWidth(font_height: u32, wide: bool) i32 {
    const columns: i32 = if (wide) 20 else 15;
    return @divTrunc(barHeight(font_height) * columns, 11);
}

pub fn depthWidth(font_height: u32, wide: bool) i32 {
    const columns: i32 = if (wide) 24 else 18;
    return @divTrunc(barHeight(font_height) * columns, 11);
}

/// The zoom gadget is the depth gadget's size, and sits beside it.
pub fn zoomWidth(font_height: u32, wide: bool) i32 {
    return depthWidth(font_height, wide);
}

/// Whether the bar's gadgets are wide now (`IPREFS_WideGadgets`).
pub fn wideGadgets(ib: *const IntuitionBase) bool {
    return ib.wide_gadgets != 0;
}

/// The same for a window, from the font its screen was opened with.
pub fn sizeBoxOf(w: *const Window) struct { width: i32, height: i32 } {
    const rows = w.screen.font.image.height;
    return .{ .width = sizeWidth(rows), .height = barHeight(rows) };
}

/// The close gadget's width for a window, the same way, in the shape the
/// system has now.
pub fn closeWidthOf(w: *const Window) i32 {
    return closeWidth(w.screen.font.image.height, wideGadgets(w.base));
}

/// The depth gadget's, and the zoom gadget's.
pub fn depthWidthOf(w: *const Window) i32 {
    return depthWidth(w.screen.font.image.height, wideGadgets(w.base));
}

/// Where the depth gadget sits in a window's title bar, and the zoom
/// gadget beside it: the left edge each is drawn at and hit from, one
/// column narrower than its image. The image reaches that column further
/// left, into the groove where the bar ends, so the depth gadget's last
/// column is the window's right edge and the zoom gadget's last column is
/// the depth gadget's groove. A zoom gadget with no depth gadget takes
/// the depth gadget's place.
pub fn depthLeft(w: *const Window) i32 {
    return w.width - depthWidthOf(w) + 1;
}

pub fn zoomLeft(w: *const Window) i32 {
    const right = if (w.flags & WF_DEPTH != 0) depthLeft(w) else w.width;
    return right - depthWidthOf(w) + 1;
}
pub const side_border = 4;
pub const bottom_border = 2;

/// How much of a window's width stays on its screen when it may hang past
/// the edges (`IPREFS_OffScreen`): enough to take hold of it again.
pub const off_screen_keep = 64;
/// How much of its height stays above the bottom when it has no title bar.
pub const off_screen_keep_rows = 16;

/// Where a window `width` by `height` may stand on its screen, as near
/// `left`, `top` as it may: wholly on the screen, or - while windows may
/// hang past its edges (`IPREFS_OffScreen`) - past the left, right and
/// bottom edges with its top never above the screen's, `off_screen_keep`
/// of its width across and its title bar's height above the bottom.
///
/// INPUTS:
/// - `ib` - the library, for the setting.
/// - `w` - the window: its screen and its title bar's height.
/// - `left`, `top` - the place asked for, on the screen.
/// - `width`, `height` - its size there, already within the screen's.
pub fn legalPlace(ib: *IntuitionBase, w: *const Window, left: i32, top: i32, width: i32, height: i32) struct { left: i32, top: i32 } {
    const s = w.screen;
    if (ib.off_screen == 0) return .{
        .left = @max(@min(left, s.width - width), 0),
        .top = @max(@min(top, s.height - height), 0),
    };
    const keep_x = @min(width, off_screen_keep);
    const keep_y = @min(height, if (w.border_top > 0) w.border_top else off_screen_keep_rows);
    return .{
        .left = @max(@min(left, s.width - keep_x), keep_x - width),
        .top = @max(@min(top, s.height - keep_y), 0),
    };
}

fn textLen(s: [*:0]const u8) u32 {
    var n: u32 = 0;
    while (s[n] != 0) n += 1;
    return n;
}

/// The window grown to what its layouts said in the last layout pass they
/// need, when that is more than it has - a row that wraps went deeper as
/// the window got narrower, or the window was squeezed onto its screen -
/// as far as its largest size and the screen let it - and no smaller than
/// that from then on: the smallest size the layout set was the size the
/// window had. A window that fits is left alone.
pub fn fitLayout(ib: *IntuitionBase, window: *Window) void {
    const need_width = window.layout_width;
    const need_height = window.layout_height;
    const width = @max(window.width, need_width);
    const height = @max(window.height, need_height);
    if (width == window.width and height == window.height) return;
    ib.iface().ChangeWindowBox(@ptrCast(window), window.left, window.top, width, height);
    _ = ib.iface().WindowLimits(@ptrCast(window), @min(need_width, window.width), @min(need_height, window.height), 0, 0);
}

pub fn lock(ib: *IntuitionBase) void {
    ib.sys_base.ObtainSemaphore(&ib.screen_lock);
}

pub fn unlock(ib: *IntuitionBase) void {
    ib.sys_base.ReleaseSemaphore(&ib.screen_lock);
}

/// The border, from its pieces, and the gadgets that live in it.
///
/// Each of its four strips is drawn into a bitmap of its own first and
/// put on the window in one blit, so every pixel changes once, to what it
/// ends up as. Drawn in place, the fill would wipe the title and the
/// gadgets before they are drawn again, and while the window is being
/// sized - a redraw for every step of the pointer - they flicker. A strip's
/// RastPort draws in the window's own coordinates and sends what falls in
/// the strip to its bitmap, so the border and its gadgets draw there
/// exactly as they would on the window. Without the memory for a strip it
/// is all drawn in place after all. Only the part of a strip that shows
/// through the window's clipping is drawn - none of one that is covered,
/// or outside the damage an update is narrowed to.
pub fn drawBorder(ib: *IntuitionBase, w: *Window) void {
    if (w.flags & WF_BORDERLESS != 0) return;
    const gb = ib.graphics_base;
    ib.layers_base.LockLayer(w.layer);
    defer ib.layers_base.UnlockLayer(w.layer);

    var font: usize = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&font) }, .{} };
    gb.GetRPAttrs(w.rp, &ask);
    const inner_top = w.border_top;
    const inner_bottom = w.height - w.border_bottom;
    const strips = [_]graphics.Rect{
        .{ .min_x = 0, .min_y = 0, .max_x = w.width, .max_y = inner_top },
        .{ .min_x = 0, .min_y = inner_bottom, .max_x = w.width, .max_y = w.height },
        .{ .min_x = 0, .min_y = inner_top, .max_x = w.border_left, .max_y = inner_bottom },
        .{ .min_x = w.width - w.border_right, .min_y = inner_top, .max_x = w.width, .max_y = inner_bottom },
    };
    for (strips) |strip| {
        if (strip.max_x <= strip.min_x or strip.max_y <= strip.min_y) continue;
        const shown = shownPart(gb, w.rp, strip) orelse continue;
        if (drawStrip(ib, w, shown, font)) continue;
        paintBorder(ib, w, w.rp);
        drawBorderGadgets(ib, w, w.rp);
        return;
    }
}

/// The box around what of `area`, in the RastPort's own coordinates, gets
/// through its clip list; null when none of it does. A RastPort without
/// one clips nothing.
fn shownPart(gb: *sdk.interface.graphics.GraphicsBase, rp: *graphics.RastPort, area: graphics.Rect) ?graphics.Rect {
    var list: usize = 0;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipTargets, .data = @intFromPtr(&list) }, .{} });
    if (list == 0) return area;
    var shown: ?graphics.Rect = null;
    var target: ?*const graphics.ClipTarget = @ptrFromInt(list);
    while (target) |each| : (target = each.next) {
        const meet = graphics.Rect.intersect(each.rect, area);
        if (meet.isEmpty()) continue;
        shown = if (shown) |box| .{
            .min_x = @min(box.min_x, meet.min_x),
            .min_y = @min(box.min_y, meet.min_y),
            .max_x = @max(box.max_x, meet.max_x),
            .max_y = @max(box.max_y, meet.max_y),
        } else meet;
    }
    return shown;
}

/// One strip of the border, drawn off the window and put on it; false when
/// there was no memory to do it that way.
fn drawStrip(ib: *IntuitionBase, w: *Window, strip: graphics.Rect, font: usize) bool {
    const gb = ib.graphics_base;
    const width = strip.max_x - strip.min_x;
    const height = strip.max_y - strip.min_y;
    const tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = @intCast(width) },
        .{ .tag = graphics.BMTAG_Height, .data = @intCast(height) },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(w.rp) },
        .{},
    };
    const surface = gb.AllocBitMapTagList(&tags) orelse return false;
    defer gb.FreeBitMap(surface);
    var target = graphics.ClipTarget{ .rect = strip, .surface = surface, .dx = -strip.min_x, .dy = -strip.min_y };
    const whole = graphics.Rect{ .max_x = w.width, .max_y = w.height };
    // Its own surface is the display's, as a window's RastPort's is: what
    // bounds its clip and says its format. Every write goes to the target.
    const on = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = w.screen.surface },
        .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&whole) },
        .{ .tag = graphics.RPTAG_ClipTargets, .data = @intFromPtr(&target) },
        .{ .tag = graphics.RPTAG_Font, .data = font },
        .{},
    };
    const rp = gb.CreateRastPortTagList(&on) orelse return false;
    defer gb.FreeRastPort(rp);
    paintBorder(ib, w, rp);
    drawBorderGadgets(ib, w, rp);
    gb.BltBitMapRastPort(surface, 0, 0, w.rp, strip.min_x, strip.min_y, width, height);
    return true;
}

/// The gadgets that live in the border, drawn through `rp`, which draws in
/// the window's own coordinates - as every such gadget is measured.
fn drawBorderGadgets(ib: *IntuitionBase, w: *Window, rp: *graphics.RastPort) void {
    const it = ib.iface();
    var next = w.gadgets;
    while (next) |o| : (next = @import("../classes/gadgetclass.zig").gadgetOf(ib, o).next) {
        if (!_gadget.inBorder(ib, w, o)) continue;
        var gi = _gadget.infoFor(ib, w, o);
        var msg = intuition.gadgetclass.GpRender{ .gadget_info = &gi, .rast_port = rp, .redraw = intuition.gadgetclass.GREDRAW_REDRAW };
        _ = it.SendMessage(o, @ptrCast(&msg));
    }
}

/// The border drawn through `rp`, in the window's own coordinates: the
/// window's RastPort, or one that sends what falls in a strip to its
/// bitmap and drops the rest - or a gadget's picture kept aside, which is
/// what a gadget in the border is drawn over (`_gadget.renderAside`).
pub fn paintBorder(ib: *IntuitionBase, w: *Window, rp: *graphics.RastPort) void {
    const gb = ib.graphics_base;
    const it = ib.iface();
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    // The bar was sized for the screen's font, whatever the window's
    // text is in.
    graphics.SetFont(gb, rp, w.screen.font);

    const dri = &w.screen.draw_info;
    const active = w.flags & WF_ACTIVE != 0;
    // The border is the title bar's part, a window that is not active its
    // own: the strips in its background, the title in its text colour.
    const bar = if (active) sdk.intuition.style.PART_TITLE else ic.PART_TITLE_INACTIVE;
    const fill: Pen = @truncate(it.GetStyleAttr(dri, null, bar, sdk.intuition.style.STATE_NORMAL, sdk.intuition.style.STYLE_Background));
    const ink: Pen = @truncate(it.GetStyleAttr(dri, null, bar, sdk.intuition.style.STATE_NORMAL, sdk.intuition.style.STYLE_TextPen));
    const state: u32 = if (active) ic.IDS_NORMAL else ic.IDS_INACTIVENORMAL;
    const inner_w = w.width - w.border_left - w.border_right;
    const inner_h = w.height - w.border_top - w.border_bottom;

    // The four strips, then the frame raised around the outside and sunk
    // around the inside.
    d.box(gb, rp, 0, 0, w.width, w.border_top, fill);
    d.box(gb, rp, 0, w.border_top, w.border_left, inner_h, fill);
    d.box(gb, rp, w.width - w.border_right, w.border_top, w.border_right, inner_h, fill);
    d.box(gb, rp, 0, w.height - w.border_bottom, w.width, w.border_bottom, fill);
    if (w.frame) |frame| {
        const raised = [_]TagItem{ .{ .tag = ic.IA_Recessed, .data = 0 }, .{} };
        _ = it.SetAttrsTagList(frame, &raised);
        var outside = ic.ImpDraw{
            .method_id = ic.IM_DRAWFRAME,
            .rast_port = rp,
            .state = state,
            .draw_info = dri,
            .dimensions = .{ .width = w.width, .height = w.height },
        };
        _ = it.SendMessage(frame, @ptrCast(&outside));
        const sunk = [_]TagItem{ .{ .tag = ic.IA_Recessed, .data = 1 }, .{} };
        _ = it.SetAttrsTagList(frame, &sunk);
        var inside = ic.ImpDraw{
            .method_id = ic.IM_DRAWFRAME,
            .rast_port = rp,
            .offset = .{ .x = w.border_left - 1, .y = w.border_top - 1 },
            .state = state,
            .draw_info = dri,
            .dimensions = .{ .width = inner_w + 2, .height = inner_h + 2 },
        };
        _ = it.SendMessage(frame, @ptrCast(&inside));
    }

    // The title, then the gadgets over its ends.
    if (w.title) |title| {
        var font_height: u32 = 0;
        var baseline: u32 = 0;
        const metric = [_]TagItem{
            .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&font_height) },
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{},
        };
        gb.GetRPAttrs(rp, &metric);
        d.pen(gb, rp, ink);
        const x: i32 = if (w.close_image != null) closeWidthOf(w) + 4 else 4;
        const y = @divTrunc(w.border_top - @as(i32, @intCast(font_height)), 2) + @as(i32, @intCast(baseline));
        gb.Move(rp, x, y);
        gb.Text(rp, title, textLen(title));
    }
    if (w.close_image) |image| it.DrawImageState(rp, image, 0, 0, state, dri);
    if (w.depth_image) |image| it.DrawImageState(rp, image, depthLeft(w), 0, state, dri);
    if (w.zoom_image) |image| it.DrawImageState(rp, image, zoomLeft(w), 0, state, dri);
    if (w.size_image) |image| {
        const box = sizeBoxOf(w);
        it.DrawImageState(rp, image, w.width - box.width, w.height - box.height, state, dri);
    }
    roundCorners(ib, w, rp);
}

/// The frame's outline along a window's round corners, over whatever the
/// border and its gadgets drew there: the pixels of each row next to the
/// ones the layer cuts away (`layers.cornerCut`), in the outline's pens -
/// a corner's upper rows in its top or bottom edge's, the rest in its
/// side's. Nothing inside the border is drawn.
fn roundCorners(ib: *IntuitionBase, w: *Window, rp: *graphics.RastPort) void {
    const radius = @import("_fade.zig").radiusOf(ib, w);
    if (radius == 0) return;
    const gb = ib.graphics_base;
    const it = ib.iface();
    const dri = &w.screen.draw_info;
    const st = sdk.intuition.style;
    const kind = it.GetStyleAttr(dri, null, ic.PART_WINDOW_BORDER, st.STATE_NORMAL, st.STYLE_Border);
    if (kind == st.BORDER_NONE) return;
    const flat = kind == st.BORDER_FLAT;
    const light: Pen = @truncate(it.GetStyleAttr(dri, null, ic.PART_WINDOW_BORDER, st.STATE_NORMAL, if (flat) st.STYLE_BorderPen else st.STYLE_ShinePen));
    const dark: Pen = @truncate(it.GetStyleAttr(dri, null, ic.PART_WINDOW_BORDER, st.STATE_NORMAL, if (flat) st.STYLE_BorderPen else st.STYLE_ShadowPen));
    const shine, const shade = if (kind == st.BORDER_RECESSED) .{ dark, light } else .{ light, dark };
    const inside = graphics.Rect{
        .min_x = w.border_left,
        .min_y = w.border_top,
        .max_x = w.width - w.border_right,
        .max_y = w.height - w.border_bottom,
    };
    var row: u32 = 1;
    while (row < radius) : (row += 1) {
        const before: i32 = @intCast(layers.cornerCut(radius, row - 1));
        if (before == 0) break;
        const from: i32 = @intCast(layers.cornerCut(radius, row));
        const to = @max(before, from + 1);
        const along = row * 2 < radius;
        const y: i32 = @intCast(row);
        // Top left, top right, bottom left, bottom right.
        const runs = [4]struct { x: i32, y: i32, pen: Pen }{
            .{ .x = from, .y = y, .pen = shine },
            .{ .x = w.width - to, .y = y, .pen = if (along) shine else shade },
            .{ .x = from, .y = w.height - 1 - y, .pen = if (along) shade else shine },
            .{ .x = w.width - to, .y = w.height - 1 - y, .pen = shade },
        };
        for (runs) |run| {
            const piece = graphics.Rect{ .min_x = run.x, .min_y = run.y, .max_x = run.x + (to - from), .max_y = run.y + 1 };
            if (!graphics.Rect.intersect(piece, inside).isEmpty()) continue;
            d.box(gb, rp, piece.min_x, piece.min_y, piece.width(), 1, run.pen);
        }
    }
}

/// The backfill hook: `area` of the layer in the screen's background pen,
/// through the layer's RastPort, which is handed back as it was.
pub fn backfill(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const w: *Window = @ptrCast(@alignCast(hook.data.?));
    const rp: *graphics.RastPort = @ptrCast(object orelse return 0);
    const msg: *layers.BackFillMsg = @ptrCast(@alignCast(message orelse return 0));
    const gb = w.base.graphics_base;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    d.pen(gb, rp, w.screen.pens[sc.BACKGROUNDPEN]);
    gb.RectFill(rp, &msg.area);
    return 0;
}

/// A message freed, and what it carried: IDCMP_IDCMPUPDATE's tag list is
/// the message's.
pub fn freeMessage(ib: *IntuitionBase, m: *exec.Message) void {
    const im: *wn.IntuiMessage = @ptrCast(@alignCast(m));
    if (im.class == wn.IDCMP_IDCMPUPDATE) ib.utility_base.FreeTagItems(@ptrCast(@alignCast(im.iaddress)));
    ib.sys_base.FreeMem(m, @sizeOf(wn.IntuiMessage));
}

/// Replied messages back where they came from: freed. A tick coming back
/// lets the next one be sent.
pub fn reclaim(ib: *IntuitionBase, w: *Window) void {
    while (ib.sys_base.GetMsg(&w.reply_port)) |m| {
        const im: *wn.IntuiMessage = @ptrCast(@alignCast(m));
        if (im.class == wn.IDCMP_INTUITICKS) w.flags &= ~WF_TICK_SENT;
        allowAgain(w, im);
        freeMessage(ib, m);
    }
}

/// Tell the program, if it asked to be told about this. The message carries
/// where the pointer is in the window, and the qualifiers and time of the
/// input event being handled.
pub fn send(ib: *IntuitionBase, w: *Window, class: u32, code: u32) void {
    _ = sendWith(ib, w, class, code, null);
}

/// As `send`, with an address; false when nothing was sent - the window
/// does not listen for the class, or there was no memory.
/// Which of a window's queues a message counts against, if any. A message
/// that says the same kind of thing as the one before it - the pointer has
/// moved again, the key is still down, the knob is still being dragged - is
/// held to a few outstanding at a time; everything else is news and is
/// always sent.
pub const Queue = enum { none, mouse, repeat };

/// Whether one more of this kind may go out, counting it if so.
fn allow(w: *Window, queue: Queue) bool {
    switch (queue) {
        .none => return true,
        .mouse => {
            if (w.mouse_pending >= w.mouse_limit) return false;
            w.mouse_pending += 1;
        },
        .repeat => {
            if (w.rpt_pending >= w.rpt_limit) return false;
            w.rpt_pending += 1;
        },
    }
    return true;
}

/// One of these come back: the window may send another of its kind.
fn allowAgain(w: *Window, m: *const wn.IntuiMessage) void {
    switch (queueOf(m.class, m.qualifier)) {
        .none => {},
        .mouse => if (w.mouse_pending > 0) {
            w.mouse_pending -= 1;
        },
        .repeat => if (w.rpt_pending > 0) {
            w.rpt_pending -= 1;
        },
    }
}

/// A message's queue, worked out from what it is. An interim update and a
/// repeated key are marked by `IEQUALIFIER_REPEAT`, which is the only thing
/// that tells them from the real one when they come back.
fn queueOf(class: u32, qualifier: u32) Queue {
    if (class == wn.IDCMP_MOUSEMOVE) return .mouse;
    const repeating = qualifier & ie.IEQUALIFIER_REPEAT != 0;
    if (!repeating) return .none;
    if (class == wn.IDCMP_RAWKEY or class == wn.IDCMP_VANILLAKEY or class == wn.IDCMP_IDCMPUPDATE) return .repeat;
    return .none;
}

pub fn sendWith(ib: *IntuitionBase, w: *Window, class: u32, code: u32, address: ?*anyopaque) bool {
    return sendQueued(ib, w, class, code, address, ib.input.qualifier);
}

fn sendQueued(ib: *IntuitionBase, w: *Window, class: u32, code: u32, address: ?*anyopaque, qualifier: u32) bool {
    return post(ib, w, class, code, address, qualifier, &w.reply_port) != null;
}

/// As `sendWith`, with the qualifier given and the reply going to
/// `reply_port`: the message, or null when nothing was sent. A caller that
/// waits for the reply names its own port, and frees the message with
/// `freeMessage` when it comes back.
pub fn post(ib: *IntuitionBase, w: *Window, class: u32, code: u32, address: ?*anyopaque, qualifier: u32, reply_port: *exec.MsgPort) ?*wn.IntuiMessage {
    const port = w.user_port orelse return null;
    if (w.idcmp & class == 0) return null;
    reclaim(ib, w);
    if (!allow(w, queueOf(class, qualifier))) return null;
    // intuition's own, taken back after the reply (reclaim): the system's,
    // whichever task's action sent it.
    const memory = ib.sys_base.AllocMem(@sizeOf(wn.IntuiMessage), exec.MEMF_ANY | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const m: *wn.IntuiMessage = @ptrCast(@alignCast(memory));
    const in = &ib.input;
    m.* = .{
        .msg = .{ .reply_port = reply_port, .length = @sizeOf(wn.IntuiMessage) },
        .class = class,
        .code = code,
        .qualifier = qualifier,
        .iaddress = address,
        .mouse_x = in.x - w.left,
        .mouse_y = in.y - w.top,
        .seconds = in.time.secs,
        .micros = in.time.micro,
        .window = @ptrCast(w),
    };
    ib.sys_base.PutMsg(port, &m.msg);
    return m;
}

/// IDCMP_IDCMPUPDATE with a tag list the message now owns; false when it
/// was not sent and the list is still the caller's.
pub fn sendUpdate(ib: *IntuitionBase, w: *Window, tags: [*]TagItem, interim: bool) bool {
    const qualifier = ib.input.qualifier | if (interim) ie.IEQUALIFIER_REPEAT else 0;
    // The one way an update says what the message's code is.
    const special = ib.utility_base.FindTagItem(intuition.icclass.ICSPECIAL_CODE, tags);
    const code: u32 = if (special) |item| @truncate(item.data) else 0;
    return sendQueued(ib, w, wn.IDCMP_IDCMPUPDATE, code, tags, qualifier);
}

/// IDCMP_INTUITICKS, unless the last one has not been replied yet.
pub fn tick(ib: *IntuitionBase, w: *Window) void {
    if (w.idcmp & wn.IDCMP_INTUITICKS == 0) return;
    reclaim(ib, w);
    if (w.flags & WF_TICK_SENT != 0) return;
    w.flags |= WF_TICK_SENT;
    send(ib, w, wn.IDCMP_INTUITICKS, 0);
}

/// Every open window, each screen's in turn, for a walk that has to see
/// them all.
pub fn eachWindow(ib: *IntuitionBase, context: anytype, comptime visit: fn (@TypeOf(context), *Window) void) void {
    var screen_node = ib.screen_list.head;
    while (screen_node) |sn| : (screen_node = sn.succ) {
        if (sn.succ == null) break;
        const s: *Screen = @ptrCast(@alignCast(sn));
        var node = s.windows.head;
        while (node) |n| : (node = n.succ) {
            if (n.succ == null) break;
            visit(context, @ptrCast(@alignCast(n)));
        }
    }
}

/// Whether some window of a help group has gadget help on.
pub fn groupHasHelp(ib: *IntuitionBase, group: u32) bool {
    const Seen = struct { group: u32, on: bool = false };
    var seen = Seen{ .group = group };
    eachWindow(ib, &seen, struct {
        fn visit(context: *Seen, w: *Window) void {
            if (w.help_group == context.group and w.more_flags & WMF_GADGETHELP != 0) context.on = true;
        }
    }.visit);
    return seen.on;
}

/// The border gadgets, for `drawGadget`.
pub const Gadget = enum { close, depth, zoom, size };

/// One border gadget drawn pressed or not, where it sits.
pub fn drawGadget(ib: *IntuitionBase, w: *Window, which: Gadget, pressed: bool) void {
    const image = switch (which) {
        .close => w.close_image,
        .depth => w.depth_image,
        .zoom => w.zoom_image,
        .size => w.size_image,
    } orelse return;
    const x: i32 = switch (which) {
        .close => 0,
        .depth => depthLeft(w),
        .zoom => zoomLeft(w),
        .size => w.width - sizeBoxOf(w).width,
    };
    const y: i32 = if (which == .size) w.height - sizeBoxOf(w).height else 0;
    const active = w.flags & WF_ACTIVE != 0;
    const state: u32 = if (pressed)
        (if (active) ic.IDS_SELECTED else ic.IDS_INACTIVESELECTED)
    else
        (if (active) ic.IDS_NORMAL else ic.IDS_INACTIVENORMAL);
    ib.layers_base.LockLayer(w.layer);
    defer ib.layers_base.UnlockLayer(w.layer);
    ib.iface().DrawImageState(w.rp, image, x, y, state, &w.screen.draw_info);
}

/// Take a window's port away, with every message still waiting on it.
/// A port the program shares between its windows keeps the others'
/// messages and stays the program's: this window's are found on it and
/// taken off one by one. The caller holds intuition's lock, which every
/// message is posted under, so the queue changes under the walk only by
/// what the program takes off it - and it is the program that is here.
pub fn dropPort(ib: *IntuitionBase, w: *Window) void {
    const port = w.user_port orelse return;
    if (w.more_flags & WMF_SHARED_PORT != 0) {
        var node = port.msg_list.head;
        while (node) |n| {
            const following = n.succ;
            const im: *wn.IntuiMessage = @ptrCast(@alignCast(n));
            if (following != null and @intFromPtr(im.window) == @intFromPtr(w)) {
                if (ib.sys_base.RemoveMsg(port, &im.msg)) freeMessage(ib, &im.msg);
            }
            node = following;
        }
        w.more_flags &= ~WMF_SHARED_PORT;
    } else {
        while (ib.sys_base.GetMsg(port)) |m| freeMessage(ib, m);
        ib.sys_base.DeleteMsgPort(port);
    }
    w.user_port = null;
    w.flags &= ~WF_REFRESH_SENT;
}

/// After anything that may have uncovered part of a window on this
/// screen: its border back, and the program told or the damage dropped.
///
/// A window is repaired when it has damage, whatever its refresh. A
/// smart-refresh window has none as a rule, because layers keeps what is
/// covered and puts it back - but where it could not keep those pixels
/// the layer hands out damage instead, and that window needs its border
/// and its gadgets again exactly as a simple one does.
pub fn repairScreen(ib: *IntuitionBase, s: *Screen) void {
    repairScreenAfter(ib, s, null);
}

/// `repairScreen`, after `drawn` has had its border and every gadget of
/// its room drawn whole, as a size draws them: its damage is not drawn
/// over again, only its program told or the damage dropped.
pub fn repairScreenAfter(ib: *IntuitionBase, s: *Screen, drawn: ?*Window) void {
    const lb = ib.layers_base;
    @import("../screen/_screen.zig").settleGround(ib, s);
    var node = s.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const w: *Window = @ptrCast(@alignCast(n));
        var damage: usize = 0;
        const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetDamage, .data = @intFromPtr(&damage) }, .{} };
        lb.GetLayerAttrs(w.layer, &ask);
        if (damage == 0 or ib.graphics_base.RegionRectangles(@ptrFromInt(damage), null, 0) == 0) continue;

        if (!lb.BeginUpdate(w.layer)) continue;
        if (w != drawn) {
            drawBorder(ib, w);
            _gadget.renderAll(ib, w);
        }
        const tell = w.flags & WF_NOCARE == 0 and w.user_port != null and w.idcmp & wn.IDCMP_REFRESHWINDOW != 0;
        lb.EndUpdate(w.layer, !tell);
        if (tell and w.flags & WF_REFRESH_SENT == 0) {
            w.flags |= WF_REFRESH_SENT;
            send(ib, w, wn.IDCMP_REFRESHWINDOW, 0);
        }
        // Whatever the window asked for: a console on it draws the text
        // again, and it is not the window's program.
        @import("../input/_input.zig").windowEvent(ib, w, ie.IECLASS_EVENT, ie.IECODE_REFRESHWINDOW);
    }
    // A simple-refresh requester uncovered is drawn again where it was.
    node = s.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        @import("../requester/_requester.zig").repair(ib, @ptrCast(@alignCast(n)));
    }
}

/// Which screen a window is to open on, and whether it was locked here.
const Target = struct { screen: *Screen, locked: bool };

pub fn targetScreen(ib: *IntuitionBase, tags: ?[*]const TagItem) ?Target {
    const ub = ib.utility_base;
    const custom = ub.GetTagData(wn.WA_CustomScreen, 0, tags);
    if (custom != 0) return .{ .screen = @ptrFromInt(custom), .locked = false };
    const public = ub.GetTagData(wn.WA_PubScreen, 0, tags);
    if (public != 0) return .{ .screen = @ptrFromInt(public), .locked = false };
    const name: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(wn.WA_PubScreenName, 0, tags));
    if (ib.iface().LockPubScreen(name)) |s| return .{ .screen = @ptrCast(@alignCast(s)), .locked = true };
    // The screen it asked for by name is not there. A window may say it
    // would rather open on the default one than not open at all.
    if (name == null or ub.GetTagData(wn.WA_PubScreenFallBack, 0, tags) == 0) return null;
    const s = ib.iface().LockPubScreen(null) orelse return null;
    return .{ .screen = @ptrCast(@alignCast(s)), .locked = true };
}

pub fn flagIf(ub: *sdk.interface.utility.UtilityBase, tag: utility.Tag, tags: ?[*]const TagItem, flag: u32) u32 {
    return if (ub.GetTagData(tag, 0, tags) != 0) flag else 0;
}

/// A sysiclass image the size of one border gadget.
pub fn gadgetImage(ib: *IntuitionBase, s: *Screen, which: u32, width: i32, height: i32) ?*Object {
    const tags = [_]TagItem{
        .{ .tag = ic.SYSIA_Which, .data = which },
        .{ .tag = ic.SYSIA_DrawInfo, .data = @intFromPtr(&s.draw_info) },
        .{ .tag = ic.IA_Width, .data = @intCast(width) },
        .{ .tag = ic.IA_Height, .data = @intCast(height) },
        .{},
    };
    return ib.iface().NewObjectTagList(ib.sys_class, null, &tags);
}

pub fn disposeParts(ib: *IntuitionBase, w: *Window) void {
    const it = ib.iface();
    it.DisposeObject(w.frame);
    it.DisposeObject(w.close_image);
    it.DisposeObject(w.depth_image);
    it.DisposeObject(w.zoom_image);
    it.DisposeObject(w.size_image);
}

/// A window whose place in the depth order has changed, told so if it asked
/// to hear about that as well as about being moved and sized.
pub fn depthChanged(ib: *IntuitionBase, w: *Window) void {
    if (w.flags & WF_NOTIFYDEPTH == 0) return;
    send(ib, w, wn.IDCMP_CHANGEWINDOW, 0);
}

/// A window's rank in the depth order, from the back.
pub const Rank = enum(u8) { backdrop, ordinary, stays, above };

/// The rank of a window with these `flags` and `more_flags`. A backdrop
/// window is one whatever else it asks for.
pub fn rankFrom(flags: u32, more_flags: u32) Rank {
    if (flags & WF_BACKDROP != 0) return .backdrop;
    if (more_flags & WMF_ABOVE != 0) return .above;
    if (more_flags & WMF_STAYINFRONT != 0) return .stays;
    return .ordinary;
}

pub fn rankOf(w: *const Window) Rank {
    return rankFrom(w.flags, w.more_flags);
}

/// Whether a window on `s` ranks higher than `rank`.
pub fn outranked(s: *Screen, rank: Rank) bool {
    var node = s.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const w: *Window = @ptrCast(@alignCast(n));
        if (@intFromEnum(rankOf(w)) > @intFromEnum(rank)) return true;
    }
    return false;
}

/// `w` in front of every window of its rank and behind every window of a
/// higher one. Under the screen semaphore; the caller puts its interior
/// and its requesters back in front of it.
pub fn toFront(ib: *IntuitionBase, w: *Window) void {
    const lb = ib.layers_base;
    const place: Place = switch (rankOf(w)) {
        // layers keeps a backdrop layer behind every ordinary one, and
        // nothing ranks above the keyboard.
        .backdrop, .above => .none,
        .ordinary => placeBehind(ib, w, .stays),
        .stays => placeBehind(ib, w, .above),
    };
    switch (place) {
        .none => _ = lb.UpfrontLayer(w.layer),
        .there => {},
        .in_front_of => |layer| _ = lb.MoveLayerInFrontOf(w.layer, layer),
    }
}

/// `w` behind every window of its rank and in front of every window of a
/// lower one. Under the screen semaphore, as `toFront`.
pub fn toBack(ib: *IntuitionBase, w: *Window) void {
    const lb = ib.layers_base;
    const rank = rankOf(w);
    // layers puts a layer behind the ordinary ones and in front of the
    // backdrops: the back of these two ranks.
    if (rank == .backdrop or rank == .ordinary) {
        _ = lb.BehindLayer(w.layer);
        return;
    }
    switch (placeBehind(ib, w, rank)) {
        // The only one of its rank or higher: in front of every lower
        // one, which is where it is.
        .none, .there => {},
        .in_front_of => |layer| _ = lb.MoveLayerInFrontOf(w.layer, layer),
    }
}

/// Where `placeBehind` found a window's place.
const Place = union(enum) {
    /// No other window of the rank, or of a higher one.
    none,
    /// The window is just behind the first of them already.
    there,
    /// Just in front of this layer, which is just behind the first of them.
    in_front_of: *layers.Layer,
};

/// Where `w` goes to be just behind the backmost window, not `w`, of
/// `rank` or higher: walked forward from the screen's ground, the layer
/// before the first that is such a window's. `w`'s own layers - its
/// interior, its requesters - are passed over. The ranks being in order,
/// every layer behind that one is a window's of a lower rank or of none.
fn placeBehind(ib: *IntuitionBase, w: *Window, rank: Rank) Place {
    const s = w.screen;
    // The layer before the one looked at, null when that was `w`'s own.
    var last: ?*layers.Layer = null;
    var at: ?*layers.Layer = s.ground;
    while (at) |layer| : (at = layerInFront(ib, layer)) {
        if (layer == w.layer or layer == w.inner_layer or @import("../requester/_requester.zig").owns(w, layer)) {
            last = null;
            continue;
        }
        if (windowOfLayer(s, layer)) |other| {
            if (@intFromEnum(rankOf(other)) >= @intFromEnum(rank)) {
                return if (last) |behind| .{ .in_front_of = behind } else .there;
            }
        }
        last = layer;
    }
    return .none;
}

/// The layer immediately in front of `layer`, or null for the frontmost.
pub fn layerInFront(ib: *IntuitionBase, layer: *layers.Layer) ?*layers.Layer {
    var next: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetInFront, .data = @intFromPtr(&next) }, .{} };
    ib.layers_base.GetLayerAttrs(layer, &ask);
    return @ptrFromInt(next);
}

/// The window on `s` a layer is part of: its own, its interior, or one of
/// its requesters'. Null for a layer of no window - the screen's bar and
/// ground, a menu, a gadget's list popped up.
pub fn windowOfLayer(s: *Screen, layer: *layers.Layer) ?*Window {
    var node = s.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const w: *Window = @ptrCast(@alignCast(n));
        if (w.layer == layer or w.inner_layer == layer or @import("../requester/_requester.zig").owns(w, layer)) return w;
    }
    return null;
}

pub fn activate(ib: *IntuitionBase, w: *Window) void {
    const old = ib.active_window;
    if (old == w) return;
    // A window that never takes the activation (`WA_NoActivate`).
    if (w.flags & WF_NOACTIVATE != 0) return;
    ib.active_window = w;
    ib.activations +%= 1;
    w.activated = ib.activations;
    // Only the screen with the active window shows anything but its own
    // title: one the active window leaves goes back to its default, and the
    // new one shows what its window asked for.
    if (old) |o| {
        const s = o.screen;
        if (s != w.screen and s.title != s.default_title) {
            s.title = s.default_title;
            _screen.drawBar(ib, s);
        }
    }
    if (w.screen.title != w.screen_title) {
        w.screen.title = w.screen_title;
        _screen.drawBar(ib, w.screen);
    }
    if (old) |o| {
        // A popup goes when its window stops being the active one.
        const requests = @import("../requester/_requester.zig");
        if (requests.popupOf(o)) |popup| _ = requests.take(ib, o, popup, true, sdk.intuition.gadgetclass.POPDOWN_DISMISSED);
        o.flags &= ~WF_ACTIVE;
        drawBorder(ib, o);
        send(ib, o, wn.IDCMP_INACTIVEWINDOW, 0);
        @import("../input/_input.zig").windowEvent(ib, o, ie.IECLASS_INACTIVEWINDOW, 0);
    }
    w.flags |= WF_ACTIVE;
    drawBorder(ib, w);
    @import("../input/pointer.zig").update(ib);
    send(ib, w, wn.IDCMP_ACTIVEWINDOW, 0);
    @import("../input/_input.zig").windowEvent(ib, w, ie.IECLASS_ACTIVEWINDOW, 0);
}
