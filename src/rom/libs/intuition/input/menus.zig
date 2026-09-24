// SPDX-License-Identifier: MPL-2.0
//! The menu session: what intuition's input task does from the moment the
//! menu button goes down over a window that has not trapped it, until the
//! menus are gone again - and the same for a right-Amiga shortcut.
//!
//! **Verify first.** Before anything is shown, the active window is sent
//! IDCMP_MENUVERIFY `MENUHOT` if it asked for it, and every other window on
//! its screen that asked is then sent `MENUWAITING`, one at a time, each
//! through `verify.zig`, so nothing waits for a reply. Meanwhile the events
//! keep coming and
//! are taken here: letting the menu button go gives up, and so does a
//! window that has not answered within three seconds of ticks - the
//! active one's silence stops the menus, another's lets them go ahead. The
//! active window replying with `code` set to anything but `MENUHOT` stops
//! them too, and then the button's release reaches it as IDCMP_MOUSEBUTTONS
//! as it would without menus.
//!
//! **Shown.** The strip's titles are drawn in a layer of their own laid
//! over the screen's bar, and a menu's panel - and an item's panel of
//! subitems - in another in front of everything, each made when it is
//! opened and deleted when it is closed. Layers keep what is under them:
//! a smart-refresh window gets its pixels back, a simple one is told to
//! draw the part again, and a program drawing into a window while a panel
//! covers it draws around the panel rather than over it.
//!
//! Every move finds the title, item and subitem under the pointer,
//! highlights it and opens or closes the panels to match. Letting the
//! button go picks the item under it; the select button pressed while it
//! is held picks each item it is dragged over as well. Picking checks or
//! unchecks a `CHECKIT` item and unchecks the others its `mutual_exclude`
//! names, and chains the item onto the session's picks through
//! `next_select`. At the end the window gets IDCMP_MENUPICK with the first
//! pick, or `MENUNULL` - or, with WA_MenuHelp and the Help key,
//! IDCMP_MENUHELP with what was under the pointer. The windows sent
//! `MENUWAITING` are sent IDCMP_MOUSEBUTTONS `MENUUP`.
//!
//! Everything here runs under the screen list's semaphore, and so does
//! every call that changes a window's menus. A program that changes the
//! strip of a window whose menus are shown ends the session first.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const layers = sdk.layers;
const intuition = sdk.intuition;
const ie = sdk.devices.inputevent;
const mn = intuition.menus;
const wn = intuition.windows;
const sc = intuition.screens;
const ic = intuition.imageclass;
const Menu = mn.Menu;
const MenuItem = mn.MenuItem;
const IntuiText = intuition.IntuiText;
const TagItem = utility.TagItem;
const InputEvent = ie.InputEvent;
const Pen = graphics.Pen;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _screen = @import("../screen/_screen.zig");
const Screen = _screen.Screen;
const _menu = @import("../menu/_menu.zig");
const Box = _menu.Box;
const d = @import("../classes/draw.zig");
const _requester = @import("../requester/_requester.zig");
const verify = @import("verify.zig");

/// The Help key's rawkey code.
const help_key = 0x5F;

/// Where a session is.
pub const Stage = enum(u32) { idle, verify, dmr, shown };

const Purpose = verify.Purpose;
const Answer = verify.Answer;

/// How far the pointer may move between the two presses of a double-click
/// of the menu button, across and down.
const dmr_slack_x = 10;
const dmr_slack_y = 5;

/// How a session that was shown ends.
const Ending = enum { pick, help, cancelled, quiet };

/// One panel shown: its layer, where it is on the screen, and where its
/// items' corner is.
pub const Panel = extern struct {
    layer: ?*layers.Layer = null,
    min_x: i32 = 0,
    min_y: i32 = 0,
    max_x: i32 = -1,
    max_y: i32 = -1,
    /// The screen position the items' boxes are measured from.
    origin_x: i32 = 0,
    origin_y: i32 = 0,

    fn box(p: *const Panel) Box {
        return .{ .min_x = p.min_x, .min_y = p.min_y, .max_x = p.max_x, .max_y = p.max_y };
    }
};

/// The session's state, in the base.
pub const State = extern struct {
    stage: Stage = .idle,
    /// The window whose menus these are: the active one, or the one it
    /// lends its menus from.
    window: ?*Window = null,
    /// The window made active to show another's menus, to go back to at the
    /// end.
    lending_return: ?*Window = null,

    /// Where the next window to be sent `MENUWAITING` is looked for from.
    after: ?*Window = null,

    /// Waiting for the second press of a double-click: when and where the
    /// first was, and whether the button has been let go since.
    dmr_seconds: u32 = 0,
    dmr_micros: u32 = 0,
    dmr_x: i32 = 0,
    dmr_y: i32 = 0,
    released: u8 = 0,
    pad2: [3]u8 = .{ 0, 0, 0 },

    /// MenuDrawn: the menu whose panel is shown, and the item whose
    /// subitems are, as a menu number. MenuSelected: what is under the
    /// pointer. The picks so far, first first.
    drawn: u32 = mn.MENUNULL,
    selected: u32 = mn.MENUNULL,
    options: u32 = mn.MENUNULL,
    /// The select button is held: every item passed over is picked.
    drag_select: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The titles, over the bar, and the two panels.
    strip: ?*layers.Layer = null,
    items: Panel = .{},
    subs: Panel = .{},
};

fn stateOf(ib: *IntuitionBase) *State {
    return &ib.menu;
}

/// Nothing going on, when the base is made.
pub fn init(ib: *IntuitionBase) void {
    ib.menu = .{};
}

/// Whether a session has the input.
pub fn busy(ib: *IntuitionBase) bool {
    return stateOf(ib).stage != .idle;
}

// --- menu numbers, a part at a time -----------------------------------------------------

fn withMenu(number: u32, part: u32) u32 {
    return (number & ~@as(u32, 0x1F)) | (part & 0x1F);
}

fn withItem(number: u32, part: u32) u32 {
    return (number & ~(@as(u32, 0x3F) << 5)) | ((part & 0x3F) << 5);
}

fn withSub(number: u32, part: u32) u32 {
    return (number & ~(@as(u32, 0x1F) << 11)) | ((part & 0x1F) << 11);
}

fn stripOf(st: *State) ?*Menu {
    const w = st.window orelse return null;
    return w.menu_strip;
}

// --- starting -----------------------------------------------------------------------------

/// The menu button went down over the active window, which does not trap
/// it: the menus of that window, or of the one it lends them from, once
/// every window that asked has been told.
pub fn menuButton(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    const active = ib.active_window orelse return;
    if (st.stage != .idle) return;
    st.lending_return = null;
    if (active.menu_lend) |lend| {
        st.lending_return = active;
        ib.iface().ActivateWindow(@ptrCast(lend));
    }
    st.window = ib.active_window;
    startVerify(ib, ib.active_window.?, .menus, mn.MENUHOT);
}

/// A key to the active window: true when it was the right-Amiga shortcut of
/// one of its menus' items - or of the menus it borrows - and has been
/// taken for that.
pub fn shortcut(ib: *IntuitionBase, w: *Window, e: *const InputEvent) bool {
    const st = stateOf(ib);
    if (st.stage != .idle) return false;
    if (w.flags & _window.WF_RMBTRAP != 0) return false;
    if (e.qualifier & ie.IEQUALIFIER_RCOMMAND == 0 or e.code & ie.IECODE_UP_PREFIX != 0) return false;
    const kb = ib.keymap_base orelse return false;
    // The character the key makes without the Amiga key, which is what an
    // item's `command` is.
    var plain = e.*;
    plain.qualifier &= ~(ie.IEQUALIFIER_RCOMMAND | ie.IEQUALIFIER_LCOMMAND);
    var text: [8]u8 = undefined;
    if (kb.MapRawKey(&plain, &text, text.len, null) != 1) return false;
    const owner = w.menu_lend orelse w;
    const number = findMenuKey(ib, owner.menu_strip, text[0]);
    if (number == mn.MENUNULL) return false;
    st.lending_return = null;
    if (owner != w) {
        st.lending_return = w;
        ib.iface().ActivateWindow(@ptrCast(owner));
    }
    st.window = owner;
    st.selected = number;
    startVerify(ib, owner, .key, mn.MENUHOT);
    return true;
}

/// The menu number of the item whose `command` is `code`, ignoring case -
/// an item with subitems by its subitems only - or MENUNULL.
fn findMenuKey(ib: *IntuitionBase, strip: ?*Menu, code: u8) u32 {
    if (code == 0) return mn.MENUNULL;
    const ub = ib.utility_base;
    const want = ub.ToUpper(code);
    var menu = strip;
    var menu_number: u32 = 0;
    while (menu) |m| : (menu = m.next_menu) {
        var item = m.first_item;
        var item_number: u32 = 0;
        while (item) |entry| : (item = entry.next_item) {
            if (entry.sub_item) |first_sub| {
                var sub: ?*MenuItem = first_sub;
                var sub_number: u32 = 0;
                while (sub) |each| : (sub = each.next_item) {
                    if (each.command != 0 and ub.ToUpper(each.command) == want) return mn.FULLMENUNUM(menu_number, item_number, sub_number);
                    sub_number += 1;
                }
            } else if (entry.command != 0 and ub.ToUpper(entry.command) == want) {
                return mn.FULLMENUNUM(menu_number, item_number, mn.NOSUB);
            }
            item_number += 1;
        }
        menu_number += 1;
    }
    return mn.MENUNULL;
}

// --- verifying ------------------------------------------------------------------------------

/// Ask `w` for the session: IDCMP_REQVERIFY for the double-click
/// requester, IDCMP_MENUVERIFY for everything else. The answer comes back
/// to `verified`, perhaps at once.
fn startVerify(ib: *IntuitionBase, w: *Window, purpose: Purpose, code: u32) void {
    stateOf(ib).stage = .verify;
    const class = if (purpose == .dmr) wn.IDCMP_REQVERIFY else wn.IDCMP_MENUVERIFY;
    verify.start(ib, w, class, code, purpose);
}

/// A verify of the session's answered: what it was for goes on from here.
pub fn verified(ib: *IntuitionBase, purpose: Purpose, answer: Answer) void {
    const st = stateOf(ib);
    st.stage = .idle;
    switch (purpose) {
        .menus => switch (answer) {
            .cancel => finish(ib),
            .abort => {
                pickNothing(ib);
                finish(ib);
            },
            .ok => {
                st.after = null;
                if (st.window) |w| {
                    if (w.dm_request != null) return startDmr(ib, w);
                }
                nextOther(ib);
            },
        },
        .dmr => {
            // Up, unless the window's verify was given up on; the window is
            // told REQCLEAR when it did not go up, so it knows it will not.
            const w = st.window orelse return finish(ib);
            const up = answer != .abort and w.dm_request != null and
                _requester.put(ib, w, w.dm_request.?, true);
            if (!up) _ = _window.sendWith(ib, w, wn.IDCMP_REQCLEAR, 0, w.dm_request);
            finish(ib);
        },
        .key => {
            if (answer == .ok) {
                if (st.window) |w| {
                    _menu.resetDrawn(w.menu_strip);
                    var first: u32 = mn.MENUNULL;
                    updateOptions(ib, &first, false);
                    _ = _window.sendWith(ib, w, wn.IDCMP_MENUPICK, first, null);
                }
            } else pickNothing(ib);
            finish(ib);
        },
        .others => switch (answer) {
            .abort => {
                pickNothing(ib);
                if (st.window) |w| clearWaiting(ib, w.screen);
                finish(ib);
            },
            else => nextOther(ib),
        },
        .size, .zoom => {},
    }
}

/// The next window of the screen after `after` that wants to be told
/// before menus cover it, sent `MENUWAITING`; the menus shown when there is
/// none left.
fn nextOther(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    const menu_window = st.window orelse return finish(ib);
    var node = if (st.after) |after| after.node.succ else menu_window.screen.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const w: *Window = @ptrCast(@alignCast(n));
        if (w == menu_window or w.idcmp & wn.IDCMP_MENUVERIFY == 0) continue;
        st.after = w;
        w.more_flags |= _window.WMF_NEEDMENUCLEAR;
        return startVerify(ib, w, .others, mn.MENUWAITING);
    }
    show(ib);
}

/// Every window sent `MENUWAITING` told the menus are gone.
fn clearWaiting(ib: *IntuitionBase, s: *Screen) void {
    var node = s.windows.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const w: *Window = @ptrCast(@alignCast(n));
        if (w.more_flags & _window.WMF_NEEDMENUCLEAR == 0) continue;
        w.more_flags &= ~_window.WMF_NEEDMENUCLEAR;
        _ = _window.sendWith(ib, w, wn.IDCMP_MOUSEBUTTONS, wn.MENUUP, null);
    }
}

/// The menu window told nothing was picked.
fn pickNothing(ib: *IntuitionBase) void {
    const w = stateOf(ib).window orelse return;
    _ = _window.sendWith(ib, w, wn.IDCMP_MENUPICK, mn.MENUNULL, null);
}

/// Back to no session, and to the window that was active before another's
/// menus were borrowed.
fn finish(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    st.stage = .idle;
    st.window = null;
    st.after = null;
    st.drag_select = 0;
    if (st.lending_return) |back| {
        st.lending_return = null;
        ib.iface().ActivateWindow(@ptrCast(back));
    }
}

// --- shown ------------------------------------------------------------------------------------

/// Everyone has been told: the titles over the bar, and the pointer
/// followed from here.
fn show(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    const w = st.window orelse return finish(ib);
    st.stage = .shown;
    st.drawn = mn.MENUNULL;
    st.selected = mn.MENUNULL;
    st.options = mn.MENUNULL;
    st.drag_select = 0;
    st.items = .{};
    st.subs = .{};
    w.flags |= _window.WF_MENUSTATE;
    _menu.resetDrawn(w.menu_strip);
    if (st.strip == null) drawStrip(ib, w);
    getMenu(ib);
}

/// One event while a session has the input: waiting for a verify, or with
/// the menus shown.
pub fn handle(ib: *IntuitionBase, e: *const InputEvent) void {
    const st = stateOf(ib);
    switch (st.stage) {
        .idle => {},
        .verify => verifying(ib, e),
        .dmr => waitingDmr(ib, e),
        .shown => shown(ib, e),
    }
}

/// The active window has a double-click requester: its titles shown, and
/// the next events watched for a second press of the menu button close by
/// in time and place.
fn startDmr(ib: *IntuitionBase, w: *Window) void {
    const st = stateOf(ib);
    st.stage = .dmr;
    st.dmr_seconds = ib.input.time.secs;
    st.dmr_micros = ib.input.time.micro;
    st.dmr_x = ib.input.x;
    st.dmr_y = ib.input.y;
    st.released = 0;
    drawStrip(ib, w);
}

fn closeStrip(ib: *IntuitionBase, w: *Window) void {
    const st = stateOf(ib);
    if (st.strip) |strip| ib.layers_base.DeleteLayer(strip);
    st.strip = null;
    _window.repairScreen(ib, w.screen);
}

/// Waiting for the second press. It comes: the requester, once the window
/// has answered IDCMP_REQVERIFY. The pointer moves away or the time runs
/// out: the menus, if the button is still held, and nothing if it is not.
fn waitingDmr(ib: *IntuitionBase, e: *const InputEvent) void {
    const st = stateOf(ib);
    const w = st.window orelse return finish(ib);
    switch (e.class) {
        ie.IECLASS_NEWPOINTERPOS => switch (e.code) {
            ie.IECODE_RBUTTON => {
                closeStrip(ib, w);
                return startVerify(ib, w, .dmr, 0);
            },
            ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX => {
                st.released = 1;
                closeStrip(ib, w);
                return;
            },
            else => {},
        },
        ie.IECLASS_TIMER => _window.tick(ib, w),
        else => return,
    }
    const moved = @abs(ib.input.x - st.dmr_x) > dmr_slack_x or @abs(ib.input.y - st.dmr_y) > dmr_slack_y;
    const late = !ib.iface().DoubleClick(st.dmr_seconds, st.dmr_micros, ib.input.time.secs, ib.input.time.micro);
    if (!moved and !late) return;
    if (st.released != 0) {
        pickNothing(ib);
        return finish(ib);
    }
    nextOther(ib);
}

fn verifying(ib: *IntuitionBase, e: *const InputEvent) void {
    switch (e.class) {
        ie.IECLASS_TIMER => {
            if (ib.active_window) |w| _window.tick(ib, w);
            verify.tick(ib);
        },
        // Letting go gives up the menus; a double-click requester is past
        // that.
        ie.IECLASS_NEWPOINTERPOS => if (e.code == ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX and verify.purposeOf(ib) != .dmr) {
            // The user gave up before the menus came.
            if (ib.active_window) |w| _ = _window.sendWith(ib, w, wn.IDCMP_MOUSEBUTTONS, wn.MENUUP, null);
            verify.abort(ib, .abort);
        },
        else => {},
    }
}

fn shown(ib: *IntuitionBase, e: *const InputEvent) void {
    const st = stateOf(ib);
    switch (e.class) {
        ie.IECLASS_TIMER => if (ib.active_window) |w| _window.tick(ib, w),
        ie.IECLASS_NEWPOINTERPOS => {
            getMenu(ib);
            if (st.drag_select != 0) updateOptions(ib, &st.options, true);
            switch (e.code) {
                ie.IECODE_LBUTTON => {
                    // A new drag: what was toggled before may toggle again.
                    _menu.resetMenu(stripOf(st), ~@as(u32, 0), ~mn.MENUTOGGLED, ~mn.MENUTOGGLED);
                    st.drag_select = 1;
                    updateOptions(ib, &st.options, true);
                },
                ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX => st.drag_select = 0,
                ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX => {
                    updateOptions(ib, &st.options, false);
                    end(ib, .pick);
                },
                else => {},
            }
        },
        ie.IECLASS_RAWKEY => {
            getMenu(ib);
            if (st.drag_select != 0) updateOptions(ib, &st.options, true);
            const w = st.window orelse return;
            if (e.code == help_key and w.more_flags & _window.WMF_MENUHELP != 0) end(ib, .help);
        },
        else => {},
    }
}

/// The menus taken down, the window told how the session ended, and every
/// window that was warned told it is over.
fn end(ib: *IntuitionBase, ending: Ending) void {
    const st = stateOf(ib);
    const w = st.window orelse return finish(ib);
    const selected = st.selected;
    st.selected = mn.MENUNULL;
    w.flags &= ~_window.WF_MENUSTATE;
    if (mn.ITEMNUM(st.drawn) != mn.NOITEM) eraseSub(ib);
    if (mn.MENUNUM(st.drawn) != mn.NOMENU) eraseItem(ib);
    st.drawn = mn.MENUNULL;
    if (st.strip) |strip| ib.layers_base.DeleteLayer(strip);
    st.strip = null;
    _window.repairScreen(ib, w.screen);
    clearWaiting(ib, w.screen);
    switch (ending) {
        .pick => _ = _window.sendWith(ib, w, wn.IDCMP_MENUPICK, st.options, null),
        .cancelled => _ = _window.sendWith(ib, w, wn.IDCMP_MENUPICK, mn.MENUNULL, null),
        .help => _ = _window.sendWith(ib, w, wn.IDCMP_MENUHELP, selected, null),
        .quiet => {},
    }
    finish(ib);
}

/// A menu, item or subitem of `w`'s strip has been enabled or disabled:
/// while its menus are shown, what shows it is painted again - the titles,
/// the panel and the panel of subitems that are open - and the highlight
/// put back where the pointer is, if what is under it can still be picked.
pub fn enablingChanged(ib: *IntuitionBase, w: *Window) void {
    const st = stateOf(ib);
    if (st.stage != .shown or st.window != w) return;
    paintStrip(ib, w);
    highMenu(ib);
    const m = _menu.grabMenu(w.menu_strip, st.drawn) orelse return;
    const menu_off = m.flags & mn.MENUENABLED == 0;
    repaint(ib, w, &st.items, m.first_item, menu_off, false);
    const parent = _menu.grabItem(m, st.drawn) orelse return;
    repaint(ib, w, &st.subs, parent.sub_item, menu_off or parent.flags & mn.ITEMENABLED == 0, true);
}

/// A program is changing `w`'s strip: a session showing it ends first, with
/// nothing picked, since what is under the pointer is about to be
/// something else.
pub fn endFor(ib: *IntuitionBase, w: *Window) void {
    const st = stateOf(ib);
    if (st.stage == .shown and st.window == w) end(ib, .cancelled);
}

/// A window is closing: nothing of the session may point at it afterwards.
pub fn forget(ib: *IntuitionBase, w: *Window) void {
    const st = stateOf(ib);
    // Nobody borrows its menus any more.
    var screen_node = ib.screen_list.head;
    while (screen_node) |sn| : (screen_node = sn.succ) {
        if (sn.succ == null) break;
        const s: *Screen = @ptrCast(@alignCast(sn));
        var node = s.windows.head;
        while (node) |n| : (node = n.succ) {
            if (n.succ == null) break;
            const other: *Window = @ptrCast(@alignCast(n));
            if (other.menu_lend == w) other.menu_lend = null;
        }
    }
    if (st.lending_return == w) st.lending_return = null;
    switch (st.stage) {
        .idle => {},
        .shown => if (st.window == w) {
            end(ib, .quiet);
        },
        .verify => {
            if (st.window == w) {
                // Its own menus: there is no one left to show them to.
                verify.drop(ib);
                clearWaiting(ib, w.screen);
                finish(ib);
            } else if (verify.windowOf(ib) == w) {
                // Only warned: as good as a yes, and the next is asked.
                verify.abort(ib, .ok);
            }
            if (st.after == w) st.after = null;
        },
        .dmr => if (st.window == w) {
            closeStrip(ib, w);
            finish(ib);
        },
    }
}

// --- drawing ------------------------------------------------------------------------------------

/// A layer in front of every other, smart so it keeps what it covers, at a
/// box on the screen. Null without memory.
fn openLayer(ib: *IntuitionBase, s: *Screen, b: Box) ?*layers.Layer {
    if (b.max_x < b.min_x or b.max_y < b.min_y) return null;
    const bounds = graphics.Rect{ .min_x = b.min_x, .min_y = b.min_y, .max_x = b.max_x + 1, .max_y = b.max_y + 1 };
    const tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&bounds) },
        .{ .tag = layers.LATAG_Refresh, .data = layers.LAYERSMART },
        .{ .tag = layers.LATAG_BackFill, .data = layers.LAYERS_NOBACKFILL },
        .{},
    };
    return ib.layers_base.CreateLayerTagList(s.layer_info, &tags);
}

fn rastPortOf(ib: *IntuitionBase, layer: *layers.Layer) ?*graphics.RastPort {
    var where: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&where) }, .{} };
    ib.layers_base.GetLayerAttrs(layer, &ask);
    return @ptrFromInt(where);
}

/// A box inverted: what a highlight is, and what undoes it.
fn complement(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32, w: i32, h: i32) void {
    if (w <= 0 or h <= 0) return;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    const mode = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_COMPLEMENT }, .{} };
    gb.SetRPAttrs(rp, &mode);
    gb.RectFill(rp, &.{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h });
}

/// The titles, in a layer over the screen's bar: the bar's fill and trim
/// line, each title in the detail pen, a disabled one ghosted.
fn drawStrip(ib: *IntuitionBase, w: *Window) void {
    const st = stateOf(ib);
    const s = w.screen;
    if (s.bar_height <= 0) return;
    st.strip = openLayer(ib, s, .{ .min_x = 0, .min_y = 0, .max_x = s.width - 1, .max_y = s.bar_height - 1 });
    paintStrip(ib, w);
}

/// The titles' face, in the layer the strip already has.
fn paintStrip(ib: *IntuitionBase, w: *Window) void {
    const st = stateOf(ib);
    const s = w.screen;
    const gb = ib.graphics_base;
    const layer = st.strip orelse return;
    const rp = rastPortOf(ib, layer) orelse return;
    ib.layers_base.LockLayer(layer);
    defer ib.layers_base.UnlockLayer(layer);
    graphics.SetFont(gb, rp, s.font);
    d.box(gb, rp, 0, 0, s.width, s.bar_height - 1, s.pens[sc.BARBLOCKPEN]);
    d.box(gb, rp, 0, s.bar_height - 1, s.width, 1, s.pens[sc.BARTRIMPEN]);
    var menu = w.menu_strip;
    while (menu) |m| : (menu = m.next_menu) {
        const name = m.name orelse continue;
        var title = IntuiText{
            .front_pen = s.pens[sc.BARDETAILPEN],
            .draw_mode = graphics.DRMD_JAM1,
            .left = _screen.bar_left,
            .top = _screen.bar_border,
            .font = s.font,
            .text = name,
        };
        ib.iface().PrintIText(rp, &title, m.left, 0);
        if (m.flags & mn.MENUENABLED == 0) d.ghost(gb, rp, _screen.bar_left + m.left, 0, m.width, s.bar_height - 1, s.pens[sc.BARBLOCKPEN]);
    }
}

/// The title under MenuSelected inverted, or put back.
fn highMenu(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    const w = st.window orelse return;
    const m = _menu.grabMenu(w.menu_strip, st.selected) orelse return;
    if (m.flags & mn.MENUENABLED == 0) return;
    const layer = st.strip orelse return;
    const rp = rastPortOf(ib, layer) orelse return;
    ib.layers_base.LockLayer(layer);
    defer ib.layers_base.UnlockLayer(layer);
    complement(ib.graphics_base, rp, _screen.bar_border + m.left, 0, m.width, w.screen.bar_height - 1);
}

/// A panel's layer opened at `b` on the screen, with its items' corner at
/// (`origin_x`, `origin_y`) - moved right with it when it would start left
/// of the screen - and cut at the screen's other edges.
fn openPanel(ib: *IntuitionBase, panel: *Panel, s: *Screen, b: Box, origin_x: i32, origin_y: i32) void {
    var at = b;
    var ox = origin_x;
    if (at.min_x < 0) {
        ox -= at.min_x;
        at.max_x -= at.min_x;
        at.min_x = 0;
    }
    at.min_y = @max(at.min_y, 0);
    at.max_x = @min(at.max_x, s.width - 1);
    at.max_y = @min(at.max_y, s.height - 1);
    panel.* = .{
        .layer = openLayer(ib, s, at),
        .min_x = at.min_x,
        .min_y = at.min_y,
        .max_x = at.max_x,
        .max_y = at.max_y,
        .origin_x = ox,
        .origin_y = origin_y,
    };
}

fn closePanel(ib: *IntuitionBase, panel: *Panel) void {
    if (panel.layer) |layer| ib.layers_base.DeleteLayer(layer);
    panel.* = .{};
}

/// A panel's face: its fill, its edge, and each item - its text or image,
/// its checkmark when checked, its shortcut at the right after the Amiga
/// key, lined up with every other shortcut of the panel, and a ghost over
/// it when it, or the whole panel, cannot be picked.
fn paint(ib: *IntuitionBase, w: *Window, panel: *const Panel, first: ?*MenuItem, disabled: bool) void {
    const layer = panel.layer orelse return;
    const rp = rastPortOf(ib, layer) orelse return;
    const gb = ib.graphics_base;
    const it = ib.iface();
    const s = w.screen;
    const detail = s.pens[sc.BARDETAILPEN];
    const block = s.pens[sc.BARBLOCKPEN];
    ib.layers_base.LockLayer(layer);
    defer ib.layers_base.UnlockLayer(layer);
    graphics.SetFont(gb, rp, s.font);

    const width = panel.max_x - panel.min_x + 1;
    const height = panel.max_y - panel.min_y + 1;
    d.box(gb, rp, 0, 0, width, height, block);
    // The edge: two pixels at the sides, one along the top and bottom.
    d.box(gb, rp, 0, 0, 2, height, detail);
    d.box(gb, rp, width - 2, 0, 2, height, detail);
    d.box(gb, rp, 2, 0, width - 4, 1, detail);
    d.box(gb, rp, 2, height - 1, width - 4, 1, detail);

    // How far in from the right the shortcuts' characters start: the
    // widest of them, so they line up.
    var indent: i32 = 0;
    var item = first;
    while (item) |entry| : (item = entry.next_item) {
        if (entry.item_fill == null or entry.flags & mn.COMMSEQ == 0) continue;
        const chars = [2]u8{ entry.command, 0 };
        const key = keyRun(&chars, fontOf(entry));
        indent = @max(indent, _menu.textWidth(ib, w, &key));
    }

    item = first;
    while (item) |entry| : (item = entry.next_item) {
        const left = panel.origin_x + entry.left - panel.min_x;
        const top = panel.origin_y + entry.top - panel.min_y;
        var fill_top = top;
        if (entry.item_fill) |fill| {
            if (entry.flags & mn.ITEMTEXT != 0) {
                const run: *const IntuiText = @ptrCast(@alignCast(fill));
                fill_top = top + run.top;
                it.PrintIText(rp, run, left, top);
            } else {
                fill_top = top + _menu.imageBox(ib, @ptrCast(fill)).min_y;
                it.DrawImage(rp, @ptrCast(fill), left, top);
            }
        }
        if (entry.flags & mn.CHECKIT != 0 and entry.flags & mn.CHECKED != 0) it.DrawImage(rp, w.check_mark, left, fill_top);
        if (entry.flags & mn.COMMSEQ != 0) {
            const font = fontOf(entry);
            const chars = [2]u8{ entry.command, 0 };
            var key = keyRun(&chars, font);
            const at = left + entry.width - indent - 2;
            const baseline = _menu.metric(ib, w, font).baseline;
            const key_height = _menu.imageHeight(ib, w.amiga_key);
            it.DrawImage(rp, w.amiga_key, at - _menu.imageWidth(ib, w.amiga_key) - 2, fill_top + @max(0, baseline - (key_height - 1)));
            key.front_pen = detail;
            key.left = at;
            key.top = fill_top;
            it.PrintIText(rp, &key, 0, 0);
        }
        if (disabled or entry.flags & mn.ITEMENABLED == 0) d.ghost(gb, rp, left, top, entry.width, entry.height, block);
    }
}

/// The font an item's text is in, which its shortcut is shown in too; null
/// for the screen's.
fn fontOf(item: *const MenuItem) ?*graphics.TextFont {
    if (item.flags & mn.ITEMTEXT == 0) return null;
    const run: *const IntuiText = @ptrCast(@alignCast(item.item_fill orelse return null));
    return run.font;
}

/// An item's shortcut character as a run of its own.
fn keyRun(chars: *const [2]u8, font: ?*graphics.TextFont) IntuiText {
    return .{ .draw_mode = graphics.DRMD_JAM1, .font = font, .text = @ptrCast(chars) };
}

/// The panel of the menu a number names, opened just under the bar at its
/// title and painted.
fn drawItem(ib: *IntuitionBase, number: u32) void {
    const st = stateOf(ib);
    const w = st.window orelse return;
    const m = _menu.grabMenu(w.menu_strip, number) orelse return;
    const s = w.screen;
    const origin_x = _screen.bar_left + m.left;
    const origin_y = s.bar_height;
    const panel = Box{ .min_x = m.jazz_x, .min_y = m.jazz_y, .max_x = m.beat_x, .max_y = m.beat_y };
    openPanel(ib, &st.items, s, panel.offset(origin_x, origin_y), origin_x, origin_y);
    paint(ib, w, &st.items, m.first_item, m.flags & mn.MENUENABLED == 0);
    m.flags |= mn.MIDRAWN;
    st.drawn = withMenu(st.drawn, mn.MENUNUM(number));
}

/// The panel of subitems of the item a number names, from that item's
/// corner, touching it at least at one corner.
fn drawSub(ib: *IntuitionBase, number: u32) void {
    const st = stateOf(ib);
    const w = st.window orelse return;
    const m = _menu.grabMenu(w.menu_strip, number) orelse return;
    const item = _menu.grabItem(m, number) orelse return;
    const reach = Box{ .min_x = item.width - 1, .min_y = item.height - 1, .max_x = 0, .max_y = 0 };
    const panel = _menu.boxer(ib, w, item.sub_item, reach, true);
    const origin_x = st.items.origin_x + item.left;
    const origin_y = st.items.origin_y + item.top;
    openPanel(ib, &st.subs, w.screen, panel.offset(origin_x, origin_y), origin_x, origin_y);
    paint(ib, w, &st.subs, item.sub_item, m.flags & mn.MENUENABLED == 0 or item.flags & mn.ITEMENABLED == 0);
    item.flags |= mn.ISDRAWN;
    st.drawn = withItem(st.drawn, mn.ITEMNUM(number));
}

/// The menu's panel taken away, and what it covered put back.
fn eraseItem(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    const w = st.window orelse return;
    closePanel(ib, &st.items);
    _window.repairScreen(ib, w.screen);
    if (_menu.grabMenu(w.menu_strip, st.drawn)) |m| m.flags &= ~mn.MIDRAWN;
    st.drawn = withMenu(st.drawn, mn.NOMENU);
}

/// The panel of subitems taken away.
fn eraseSub(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    const w = st.window orelse return;
    closePanel(ib, &st.subs);
    _window.repairScreen(ib, w.screen);
    if (_menu.grabItem(_menu.grabMenu(w.menu_strip, st.drawn), st.drawn)) |item| item.flags &= ~mn.ISDRAWN;
    st.drawn = withItem(st.drawn, mn.NOITEM);
}

/// An item shown highlighted, or put back, by its `HIGH` mode - and its
/// `HIGHITEM` turned over to say which it now is.
fn highGrunt(ib: *IntuitionBase, w: *Window, rp: *graphics.RastPort, item: *MenuItem, left: i32, top: i32) void {
    const gb = ib.graphics_base;
    switch (item.flags & mn.HIGHFLAGS) {
        mn.HIGHCOMP => complement(gb, rp, left, top, item.width, item.height),
        mn.HIGHBOX => {
            // A frame four pixels wide at the sides and two along the top
            // and bottom, around the box.
            const x = left - 4;
            const y = top - 2;
            const fw = item.width + 8;
            const fh = item.height + 4;
            complement(gb, rp, x, y, 4, fh);
            complement(gb, rp, x + fw - 4, y, 4, fh);
            complement(gb, rp, x + 4, y, fw - 8, 2);
            complement(gb, rp, x + 4, y + fh - 2, fw - 8, 2);
        },
        mn.HIGHIMAGE => {
            const highlighted = item.flags & mn.HIGHITEM != 0;
            const fill = if (highlighted) item.item_fill else item.select_fill;
            if (item.flags & mn.ITEMTEXT != 0) {
                graphics.SetFont(gb, rp, w.screen.font);
                ib.iface().PrintIText(rp, @ptrCast(@alignCast(fill)), left, top);
            } else {
                const state: u32 = if (highlighted) ic.IDS_NORMAL else ic.IDS_SELECTED;
                ib.iface().DrawImageState(rp, @ptrCast(fill), left, top, state, null);
            }
        },
        else => {},
    }
    item.flags ^= mn.HIGHITEM;
}

/// The item - or with `sub` the subitem - under MenuSelected highlighted
/// or put back, when its panel is shown and it can be picked.
fn highPrime(ib: *IntuitionBase, sub: bool) void {
    const st = stateOf(ib);
    const w = st.window orelse return;
    const m = _menu.grabMenu(w.menu_strip, st.selected) orelse return;
    if (m.flags & mn.MENUENABLED == 0) return;
    var item = _menu.grabItem(m, st.selected) orelse return;
    if (item.flags & mn.ITEMENABLED == 0) return;
    var panel = &st.items;
    if (sub) {
        item = _menu.grabSub(item, st.selected) orelse return;
        if (item.flags & mn.ITEMENABLED == 0) return;
        panel = &st.subs;
    }
    const layer = panel.layer orelse return;
    const rp = rastPortOf(ib, layer) orelse return;
    ib.layers_base.LockLayer(layer);
    defer ib.layers_base.UnlockLayer(layer);
    highGrunt(ib, w, rp, item, panel.origin_x + item.left - panel.min_x, panel.origin_y + item.top - panel.min_y);
}

fn highItem(ib: *IntuitionBase) void {
    highPrime(ib, false);
}

fn highSub(ib: *IntuitionBase) void {
    highPrime(ib, true);
}

// --- following the pointer ------------------------------------------------------------------

/// Which title the pointer is on, or NOMENU.
fn hitMenu(ib: *IntuitionBase) u32 {
    const st = stateOf(ib);
    const w = st.window orelse return mn.NOMENU;
    const x = ib.input.x - _screen.bar_border;
    const y = ib.input.y;
    if (y < 0 or y >= w.screen.bar_height - 1) return mn.NOMENU;
    var number: u32 = 0;
    var menu = w.menu_strip;
    while (menu) |m| : (menu = m.next_menu) {
        if (x >= m.left and x < m.left + m.width) return number;
        number += 1;
    }
    return mn.NOMENU;
}

/// Which item of the shown panel - or with `sub`, subitem - the pointer is
/// on, or NOITEM.
fn hitGrunt(ib: *IntuitionBase, sub: bool) u32 {
    const st = stateOf(ib);
    const w = st.window orelse return mn.NOITEM;
    const m = _menu.grabMenu(w.menu_strip, st.drawn) orelse return mn.NOITEM;
    var x = ib.input.x - st.items.origin_x;
    var y = ib.input.y - st.items.origin_y;
    var item = m.first_item;
    if (sub) {
        const parent = _menu.grabItem(m, st.drawn) orelse return mn.NOITEM;
        x -= parent.left;
        y -= parent.top;
        item = parent.sub_item;
    }
    var number: u32 = 0;
    while (item) |entry| : (item = entry.next_item) {
        if (x >= entry.left and x < entry.left + entry.width and y >= entry.top and y < entry.top + entry.height) return number;
        number += 1;
    }
    return mn.NOITEM;
}

fn hitItem(ib: *IntuitionBase) u32 {
    return hitGrunt(ib, false);
}

fn hitSub(ib: *IntuitionBase) u32 {
    const number = hitGrunt(ib, true);
    return if (number == mn.NOITEM) mn.NOSUB else number;
}

/// What is under the pointer now: MenuSelected brought up to date, the
/// highlights moved and the panels opened and closed to match.
fn getMenu(ib: *IntuitionBase) void {
    const st = stateOf(ib);
    const w = st.window orelse return;
    const itempanel_of = mn.MENUNUM(st.drawn);
    const subpanel_of = mn.ITEMNUM(st.drawn);
    const sel_menu = mn.MENUNUM(st.selected);
    const sel_item = mn.ITEMNUM(st.selected);
    const sel_sub = mn.SUBNUM(st.selected);

    if (subpanel_of != mn.NOITEM) {
        const new_sub = hitSub(ib);
        if (new_sub != mn.NOSUB) {
            if (new_sub != sel_sub) {
                if (sel_sub != mn.NOSUB) highSub(ib);
                st.selected = withSub(st.selected, new_sub);
                highSub(ib);
            }
            return;
        }
        if (sel_sub != mn.NOSUB) {
            highSub(ib);
            st.selected = withSub(st.selected, mn.NOSUB);
        }
        // Inside the panel of subitems, between them: nothing changes.
        if (st.subs.box().contains(ib.input.x, ib.input.y)) return;
    }

    if (itempanel_of != mn.NOMENU) {
        const new_item = hitItem(ib);
        if (new_item != mn.NOITEM) {
            if (new_item != sel_item) {
                if (sel_item != mn.NOITEM) {
                    if (subpanel_of != mn.NOITEM) eraseSub(ib);
                    highItem(ib);
                }
                st.selected = withItem(st.selected, new_item);
                highItem(ib);
                const item = _menu.grabItem(_menu.grabMenu(w.menu_strip, sel_menu), mn.FULLMENUNUM(sel_menu, new_item, mn.NOSUB));
                if (item) |entry| {
                    if (entry.sub_item != null) {
                        drawSub(ib, mn.FULLMENUNUM(sel_menu, new_item, 0));
                        const new_sub = hitSub(ib);
                        if (new_sub != mn.NOSUB) {
                            st.selected = withSub(st.selected, new_sub);
                            highSub(ib);
                        }
                    }
                }
            }
            return;
        }
        // Off the panel: an item without subitems stops being highlighted;
        // one with them stays, so the pointer can reach them.
        if (sel_item != mn.NOITEM and subpanel_of == mn.NOITEM) {
            highItem(ib);
            st.selected = withItem(st.selected, mn.NOITEM);
        }
    }

    const new_menu = hitMenu(ib);
    if (new_menu != mn.NOMENU) {
        if (subpanel_of != mn.NOITEM) {
            eraseSub(ib);
            highItem(ib);
        }
        if (new_menu != sel_menu) {
            if (itempanel_of != mn.NOMENU) {
                eraseItem(ib);
                highMenu(ib);
            }
            st.selected = withMenu(st.selected, new_menu);
            highMenu(ib);
            drawItem(ib, new_menu);
        }
        st.selected = withSub(st.selected, mn.NOSUB);
        st.selected = withItem(st.selected, mn.NOITEM);
    }
}

// --- picking --------------------------------------------------------------------------------------

/// MenuSelected picked, if it can be: a whole path of enabled menu, item
/// and subitem, not an item with subitems, not a title alone. A `CHECKIT`
/// item is checked, or unchecked with `MENUTOGGLE`, once per drag; the
/// item goes to the end of the chain starting at `first`; the items its
/// `mutual_exclude` names are unchecked. With `redraw` a panel whose
/// checkmarks changed is painted again.
fn updateOptions(ib: *IntuitionBase, first: *u32, redraw: bool) void {
    const st = stateOf(ib);
    const w = st.window orelse return;
    const it = ib.iface();
    const number = st.selected;
    if (number == mn.MENUNULL or mn.ITEMNUM(number) == mn.NOITEM) return;
    const strip = w.menu_strip;
    const m = _menu.grabMenu(strip, number) orelse return;
    if (m.flags & mn.MENUENABLED == 0) return;
    var pick = _menu.grabItem(m, number) orelse return;
    if (pick.flags & mn.ITEMENABLED == 0) return;
    if (mn.SUBNUM(number) == mn.NOSUB) {
        if (pick.sub_item != null) return;
    } else {
        pick = _menu.grabSub(pick, number) orelse return;
        if (pick.flags & mn.ITEMENABLED == 0) return;
    }

    var changed = false;
    if (pick.flags & mn.CHECKIT != 0) {
        // Once a drag has turned it over, passing it again leaves it.
        if (pick.flags & mn.MENUTOGGLED != 0) return;
        if (pick.flags & mn.CHECKED != 0) {
            if (pick.flags & mn.MENUTOGGLE != 0) pick.flags &= ~mn.CHECKED;
        } else {
            pick.flags |= mn.CHECKED;
        }
        pick.flags |= mn.MENUTOGGLED;
        changed = true;
    }

    // Onto the end of the chain, taken out of wherever it was in it.
    chain: {
        if (first.* == mn.MENUNULL) {
            first.* = number;
            pick.next_select = mn.MENUNULL;
            break :chain;
        }
        var at = it.ItemAddress(strip, first.*) orelse break :chain;
        if (first.* == number) {
            if (at.next_select == mn.MENUNULL) break :chain;
            first.* = at.next_select;
        }
        while (true) {
            if (at.next_select == number) at.next_select = pick.next_select;
            if (at.next_select == mn.MENUNULL) break;
            at = it.ItemAddress(strip, at.next_select) orelse break;
        }
        at.next_select = number;
        pick.next_select = mn.MENUNULL;
    }

    // The others of its panel it rules out, by place.
    var exclude = pick.mutual_exclude;
    const plane_first = if (mn.SUBNUM(number) == mn.NOSUB)
        it.ItemAddress(strip, mn.FULLMENUNUM(mn.MENUNUM(number), 0, mn.NOSUB))
    else
        it.ItemAddress(strip, mn.FULLMENUNUM(mn.MENUNUM(number), mn.ITEMNUM(number), 0));
    var other = plane_first;
    while (other) |entry| : (other = entry.next_item) {
        if (exclude & 1 != 0 and entry.flags & mn.CHECKIT != 0 and entry.flags & mn.CHECKED != 0) {
            entry.flags &= ~mn.CHECKED;
            changed = true;
        }
        exclude >>= 1;
    }

    if (!redraw or !changed) return;
    if (mn.SUBNUM(number) == mn.NOSUB) {
        repaint(ib, w, &st.items, m.first_item, m.flags & mn.MENUENABLED == 0, false);
    } else {
        const parent = _menu.grabItem(m, number) orelse return;
        repaint(ib, w, &st.subs, parent.sub_item, parent.flags & mn.ITEMENABLED == 0, true);
    }
}

/// A shown panel painted again, its highlight put back on the item under
/// the pointer.
fn repaint(ib: *IntuitionBase, w: *Window, panel: *const Panel, first: ?*MenuItem, disabled: bool, sub: bool) void {
    var item = first;
    while (item) |entry| : (item = entry.next_item) entry.flags &= ~mn.HIGHITEM;
    paint(ib, w, panel, first, disabled);
    highPrime(ib, sub);
}
