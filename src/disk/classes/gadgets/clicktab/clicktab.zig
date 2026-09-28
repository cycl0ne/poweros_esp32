// SPDX-License-Identifier: MIT
//! clicktab.gadget: a row of tabs, one of them the one in front.
//!
//! Each tab is a frameiclass button frame with its label in it. The tab
//! in front is drawn raised and over the whole height of the row; the
//! rest are drawn pressed and a little lower, so that the row reads as
//! one card in front of the others.
//!
//! The tabs are laid out from the left, each as wide as its label needs.
//! When they do not all fit, the row starts at `CLICKTAB_FirstShown` and
//! two arrows at the right end move it along a tab at a time; a tab that
//! would not fit whole is not drawn at all, so no tab is ever cut.
//!
//! A press marks the tab under it; let go over the same tab, that tab is
//! the one in front, its number is the code of the window's
//! `IDCMP_GADGETUP`, and the target hears `CLICKTAB_Current`. Let go
//! somewhere else, nothing changes.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const ct = gadgets.clicktab;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = ct.CLICKTAB_CLASS,
    .version = 1,
    .date = "28.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// No tab under the pointer.
const NONE: u32 = 0xFFFF_FFFF;
/// Which arrow, if any.
const ARROW_BACK: u32 = 0xFFFF_FFFE;
const ARROW_FORWARD: u32 = 0xFFFF_FFFD;

/// Room either side of a tab's label.
const tab_margin = 10;
/// How far the tabs that are not in front sit below the row's top.
const tab_lift = 2;
/// How few tabs may be shown before the arrows are no use.
const least_shown = 1;

/// clicktab.gadget's part of an object.
pub const Data = extern struct {
    labels: ?[*]const ?[*:0]const u8 = null,
    count: u32 = 0,
    current: u32 = 0,
    /// The leftmost tab shown, when they do not all fit.
    first: u32 = 0,
    /// The tab a press is being held on, `NONE` for none.
    pressed: u32 = NONE,
    /// The pointer is on the tab the press began on.
    over: u8 = 0,
    pad: [3]u8 = @splat(0),
    /// The tabs' and the arrows' frame.
    frame: ?*Object = null,
};

fn labelAt(own: *const Data, which: u32) ?[*:0]const u8 {
    if (which >= own.count) return null;
    return own.labels.?[which];
}

/// The attributes among `tags`: whether what the row shows changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    const ub = base.utility_base;
    var changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            ct.CLICKTAB_Labels => {
                const labels: ?[*]const ?[*:0]const u8 = @ptrFromInt(item.data);
                own.labels = labels;
                own.count = 0;
                if (labels) |list| while (list[own.count] != null) {
                    own.count += 1;
                };
                own.first = 0;
                changed = true;
            },
            ct.CLICKTAB_Current => {
                own.current = @truncate(item.data);
                changed = true;
            },
            ct.CLICKTAB_FirstShown => {
                own.first = @truncate(item.data);
                changed = true;
            },
            else => {},
        }
    }
    if (own.count == 0) {
        own.current = 0;
        own.first = 0;
    } else {
        if (own.current >= own.count) own.current = own.count - 1;
        if (own.first >= own.count) own.first = own.count - 1;
    }
    return changed;
}

/// The target told which tab is in front.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const tags = [_]TagItem{
        .{ .tag = ct.CLICKTAB_Current, .data = own.current },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

// --- where the tabs are -----------------------------------------------------

/// The tabs of a row, walked from the leftmost one shown: each as wide as
/// its label needs, and only while there is room for the whole of it.
const Tabs = struct {
    measure: support.Measure,
    own: *const Data,
    /// The width the tabs have, the arrows' room already taken off.
    room: i32,
    /// Where the next tab starts, and which it is.
    x: i32 = 0,
    which: u32,

    const Tab = struct { which: u32, left: i32, width: i32 };

    fn of(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, room: i32) Tabs {
        return .{
            .measure = support.Measure.of(base.intuition_base, g, gi),
            .own = own,
            .room = room,
            .which = own.first,
        };
    }

    fn widthOf(t: *const Tabs, ib: *IntuitionBase, which: u32) i32 {
        const text = labelAt(t.own, which) orelse return 0;
        return t.measure.width(ib, text) + 2 * tab_margin;
    }

    fn next(t: *Tabs, ib: *IntuitionBase) ?Tab {
        if (t.which >= t.own.count) return null;
        const width = t.widthOf(ib, t.which);
        // The first tab shown is always drawn, however narrow the row is;
        // after it, only tabs that fit whole.
        if (t.x != 0 and t.x + width > t.room) return null;
        const tab = Tab{ .which = t.which, .left = t.x, .width = width };
        t.x += width;
        t.which += 1;
        return tab;
    }

    fn done(t: Tabs, ib: *IntuitionBase) void {
        t.measure.done(ib);
    }
};

/// How wide all the tabs are together, and how tall a line of the row's
/// font is.
const Whole = struct { width: i32, line: i32 };

fn wholeRow(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) Whole {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    defer measure.done(ib);
    var width: i32 = 0;
    for (0..own.count) |i| {
        const text = own.labels.?[i] orelse continue;
        width += measure.width(ib, text) + 2 * tab_margin;
    }
    return .{ .width = width, .line = measure.lineHeight(base.graphics_base) };
}

/// What the frame takes round a tab's label.
fn frameRoom(base: *gadgets.Base, own: *const Data, dri: ?*intuition.DrawInfo) gc.Box {
    const frame = own.frame orelse return .{ .left = 2, .top = 2, .width = 4, .height = 4 };
    return support.frameInset(base.intuition_base, frame, dri);
}

/// How wide each arrow is, and whether the row has any: it has them when
/// the tabs do not all fit in `width`.
fn arrowsFor(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, width: i32) i32 {
    const whole = wholeRow(base, own, g, gi);
    if (whole.width <= width) return 0;
    return whole.line + frameRoom(base, own, if (gi) |info| info.draw_info else g.draw_info).width;
}

/// What the pointer is over: a tab, an arrow, or nothing.
fn hitAt(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo, x: i32, y: i32) u32 {
    const ib = base.intuition_base;
    const g = gc.gadget(o);
    const b = gc.boxFor(g, gi);
    if (!support.inside(x, y, b.width, b.height)) return NONE;
    const arrows = arrowsFor(base, own, g, gi, b.width);
    if (arrows != 0 and x >= b.width - 2 * arrows) {
        return if (x < b.width - arrows) ARROW_BACK else ARROW_FORWARD;
    }
    var tabs = Tabs.of(base, own, g, gi, b.width - 2 * arrows);
    defer tabs.done(ib);
    while (tabs.next(ib)) |tab| {
        if (x >= tab.left and x < tab.left + tab.width) return tab.which;
    }
    return NONE;
}

// --- drawing ----------------------------------------------------------------

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const g = gc.gadget(o);
    const own = classes.instData(Data, cl, o);
    const b = gc.boxFor(g, info);
    const pens = info.draw_info.pens;
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    support.fill(gb, rp, b, pens[sc.BACKGROUNDPEN]);

    const arrows = arrowsFor(base, own, g, info, b.width);
    var tabs = Tabs.of(base, own, g, info, b.width - 2 * arrows);
    defer tabs.done(ib);
    var line: u32 = 0;
    var baseline: u32 = 0;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) },
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);
    while (tabs.next(ib)) |tab| {
        const front = tab.which == own.current;
        const held = own.pressed == tab.which and own.over != 0;
        const lift: i32 = if (front) 0 else tab_lift;
        const at = gc.Box{ .left = b.left + tab.left, .top = b.top + lift, .width = tab.width, .height = b.height - lift };
        if (own.frame) |frame| {
            support.drawFrame(ib, frame, rp, at, if (front and !held) ic.IDS_NORMAL else ic.IDS_SELECTED, info.draw_info);
        }
        const text = labelAt(own, tab.which) orelse continue;
        const width = gb.TextLength(rp, text, support.textLen(text));
        const left = at.left + @divTrunc(at.width - width, 2);
        const top = at.top + @divTrunc(at.height - @as(i32, @intCast(line)), 2);
        support.drawText(gb, rp, left, top, text, pens[sc.TEXTPEN]);
    }
    if (arrows != 0) {
        const at = b.left + b.width - 2 * arrows;
        for ([_]u32{ ARROW_BACK, ARROW_FORWARD }, 0..) |which, i| {
            support.drawArrow(ib, gb, own.frame, rp, info.draw_info, .{
                .at = .{ .left = at + @as(i32, @intCast(i)) * arrows, .top = b.top + tab_lift, .width = arrows, .height = b.height - tab_lift },
                .vertical = false,
                .forward = which == ARROW_FORWARD,
                .pressed = own.pressed == which and own.over != 0,
            });
        }
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// Its size: every tab side by side, the frame round each, and a line of
/// the font with the lift above it.
fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const whole = wholeRow(base, own, g, gi);
    const room = frameRoom(base, own, if (gi) |info| info.draw_info else g.draw_info);
    const height = whole.line + room.height + tab_lift;
    // The least it can be: one tab and the two arrows that reach the
    // rest.
    const least = @min(whole.width, (whole.line + room.width) * 2 + 2 * tab_margin + room.width);
    return switch (which) {
        gc.GDOMAIN_MINIMUM => .{ .width = least, .height = height },
        gc.GDOMAIN_NOMINAL => .{ .width = @max(whole.width, g.given_width), .height = height },
        else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = height },
    };
}

/// The tab taken: the one in front from now on, drawn and told.
fn take(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo, which: u32) void {
    if (which >= own.count or which == own.current) return;
    own.current = which;
    tell(base, own, o, gi);
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = ib.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, obj);
            own.* = .{};
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            _ = setAttrs(base, own, new.attr_list);
            const ub = base.utility_base;
            const sized = ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null;
            const size = domain(base, own, gc.gadget(obj), null, gc.GDOMAIN_NOMINAL);
            const tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = if (sized) utility.TAG_DONE else gc.GA_Width, .data = @intCast(size.width) },
                .{ .tag = gc.GA_Height, .data = @intCast(size.height) },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            ib.DisposeObject(own.frame);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, classes.instData(Data, cl, o.?), set.attr_list)) changed = 1;
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                support.redraw(ib, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                ct.CLICKTAB_Current => get.storage.* = own.current,
                ct.CLICKTAB_FirstShown => get.storage.* = own.first,
                ct.CLICKTAB_NumLabels => get.storage.* = own.count,
                ct.CLICKTAB_Labels => get.storage.* = @intFromPtr(own.labels),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(base, classes.instData(Data, cl, o.?), gc.gadget(o.?), ask.gadget_info, ask.which);
            return 1;
        },
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const what = hitAt(base, own, o.?, ht.gadget_info, ht.mouse.x, ht.mouse.y);
            return if (what == NONE) 0 else gc.GMR_GADGETHIT;
        },
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        // The key takes the next tab, and the one before with a Shift key
        // held, round at either end.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            if (!gc.keyIsFor(o.?, k)) return gc.GMKR_NOTHING;
            const own = classes.instData(Data, cl, o.?);
            if (own.count == 0) return gc.GMKR_DONE;
            const shift = ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT;
            const wanted = if (k.qualifier & shift != 0)
                (if (own.current == 0) own.count - 1 else own.current - 1)
            else
                (if (own.current + 1 >= own.count) 0 else own.current + 1);
            take(base, own, o.?, k.gadget_info, wanted);
            k.termination.* = @intCast(own.current);
            support.redraw(ib, o.?, k.gadget_info);
            return gc.GMKR_VERIFY;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (in.event == null) return gc.GMR_NOREUSE;
            const what = hitAt(base, own, o.?, in.gadget_info, in.mouse.x, in.mouse.y);
            if (what == NONE) return gc.GMR_NOREUSE;
            // An arrow moves the row along at once, and is done with.
            if (what == ARROW_BACK or what == ARROW_FORWARD) {
                const was = own.first;
                if (what == ARROW_BACK) {
                    if (own.first > 0) own.first -= 1;
                } else if (own.first + least_shown < own.count) own.first += 1;
                if (own.first != was) support.redraw(ib, o.?, in.gadget_info);
                return gc.GMR_NOREUSE;
            }
            own.pressed = what;
            own.over = 1;
            support.redraw(ib, o.?, in.gadget_info);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const e = in.event orelse return gc.GMR_MEACTIVE;
            if (own.pressed == NONE) return gc.GMR_NOREUSE;
            const what = hitAt(base, own, o.?, in.gadget_info, in.mouse.x, in.mouse.y);
            const over: u8 = @intFromBool(what == own.pressed);
            if (over != own.over) {
                own.over = over;
                support.redraw(ib, o.?, in.gadget_info);
            }
            if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
                const which = own.pressed;
                own.pressed = NONE;
                own.over = 0;
                if (over == 0) {
                    support.redraw(ib, o.?, in.gadget_info);
                    return gc.GMR_NOREUSE;
                }
                take(base, own, o.?, in.gadget_info, which);
                support.redraw(ib, o.?, in.gadget_info);
                in.termination.* = @intCast(own.current);
                return gc.GMR_NOREUSE | gc.GMR_VERIFY;
            }
            return gc.GMR_MEACTIVE;
        },
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.pressed != NONE) {
                own.pressed = NONE;
                own.over = 0;
                support.redraw(ib, o.?, gone.gadget_info);
            }
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
