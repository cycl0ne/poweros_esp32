// SPDX-License-Identifier: MIT
//! clicktab.gadget: a row of tabs, one of them the one in front.
//!
//! The row is drawn as a strip of cards rather than a row of buttons. A
//! line runs along the bottom of the whole row and is broken under the
//! tab that is in front, so that tab opens into what is below it; the
//! rest sit a little lower, on the line, in a slightly darker ground
//! and a slightly dimmer ink. The one in front carries a bar of the
//! screen's fill colour along its top, which is what the eye finds
//! first.
//!
//! The pens are mixed for the shades (`support.mixPens`): a pen here is
//! a colour and not an index, so the row shades the screen's own
//! background and text rather than asking for colours the screen may
//! not have.
//!
//! The tabs are laid out from the left, each as wide as its label needs.
//! When they do not all fit, the row starts at `CLICKTAB_FirstShown` and
//! two arrows at the right end move it along a tab at a time; a tab that
//! would not fit whole is not drawn at all, so no tab is ever cut.
//!
//! A press on a tab makes it the one in front at once - its page shows
//! while the button is still down - its number is the code of the
//! window's `IDCMP_GADGETUP`, and the target hears `CLICKTAB_Current`.

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
    .revision = 2,
    .date = "03.10.2026",
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
const tab_lift = 3;
/// How thick the bar along the top of the tab in front is.
const accent_height = 3;
/// Sixteenths of the background left in the ground of a tab that is not
/// in front, and of the text pen left in its ink.
const idle_ground_mix = 13;
const idle_ink_mix = 10;
/// How few tabs may be shown before the arrows are no use.
const least_shown = 1;

/// clicktab.gadget's part of an object.
pub const Data = extern struct {
    labels: ?[*]const ?[*:0]const u8 = null,
    count: u32 = 0,
    current: u32 = 0,
    /// The leftmost tab shown, when they do not all fit.
    first: u32 = 0,
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
fn frameRoom(base: *gadgets.Base, own: *const Data, dri: ?*intuition.DrawInfo, own_style: ?*const intuition.Style) gc.Box {
    const frame = own.frame orelse return .{ .left = 2, .top = 2, .width = 4, .height = 4 };
    return support.frameInset(base.intuition_base, frame, dri, own_style);
}

/// How wide each arrow is, and whether the row has any: it has them when
/// the tabs do not all fit in `width`.
fn arrowsFor(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, width: i32) i32 {
    const whole = wholeRow(base, own, g, gi);
    if (whole.width <= width) return 0;
    return whole.line + frameRoom(base, own, if (gi) |info| info.draw_info else g.draw_info, g.style).width;
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

/// One tab: its ground, its edges and its label. The tab in front is the
/// full height of the row and its bottom edge is not drawn, so it opens
/// into what is below; the rest sit `tab_lift` lower and end on the
/// row's line.
fn drawTab(base: *gadgets.Base, own: *const Data, rp: *graphics.RastPort, dri: *intuition.DrawInfo, at: gc.Box, which: u32, line: i32, baseline: i32) void {
    const gb = base.graphics_base;
    const styled = support.pensFor(base.intuition_base, dri, null, sdk.intuition.style.PART_MAIN, sdk.intuition.style.PART_SELECTION);
    const pens: [*]const graphics.Pen = &styled;
    const front = which == own.current;
    const edge = support.mixPens(pens[sc.SHADOWPEN], pens[sc.BACKGROUNDPEN], 9);
    const ground = if (front) pens[sc.BACKGROUNDPEN] else support.mixPens(pens[sc.BACKGROUNDPEN], pens[sc.SHADOWPEN], idle_ground_mix);
    const ink = if (front) pens[sc.TEXTPEN] else support.mixPens(pens[sc.TEXTPEN], pens[sc.BACKGROUNDPEN], idle_ink_mix);

    support.fill(gb, rp, at, ground);
    support.setPen(gb, rp, edge);
    gb.DrawVLine(rp, at.left, at.top, at.height);
    gb.DrawVLine(rp, at.left + at.width - 1, at.top, at.height);
    if (front) {
        // The bar along the top, drawn over the edges rather than under
        // them: it is what the eye is meant to find first.
        support.fill(gb, rp, .{ .left = at.left, .top = at.top, .width = at.width, .height = accent_height }, pens[sc.FILLPEN]);
    } else {
        gb.DrawHLine(rp, at.left, at.top, at.width);
    }

    const text = labelAt(own, which) orelse return;
    var count = support.textLen(text);
    const room = at.width - 4;
    if (gb.TextLength(rp, text, count) > room) {
        var extent: graphics.TextExtent = .{};
        count = gb.TextFit(rp, text, count, &extent, null, 1, @max(room, 0), 0);
    }
    const width = gb.TextLength(rp, text, count);
    const left = at.left + @divTrunc(at.width - width, 2);
    const top = at.top + @divTrunc(at.height - line, 2);
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = ink },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &tags);
    gb.Move(rp, left, top + baseline);
    gb.Text(rp, text, count);
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const g = gc.gadget(o);
    const own = classes.instData(Data, cl, o);
    const b = gc.boxFor(g, info);
    const styled = support.pensFor(ib, info.draw_info, g.style, sdk.intuition.style.PART_MAIN, sdk.intuition.style.PART_SELECTION);
    const pens: [*]const graphics.Pen = &styled;
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    // The row stands on the window's ground, as the window paints it; only
    // the tabs are drawn in the style's look.
    const row_ground = graphics.Rect{ .min_x = b.left, .min_y = b.top, .max_x = b.left + b.width, .max_y = b.top + b.height };
    gb.EraseRect(rp, &row_ground);

    // The line along the bottom of the whole row. Every tab is drawn
    // over it, and the one in front covers its part of it.
    const edge = support.mixPens(pens[sc.SHADOWPEN], info.draw_info.pens[sc.BACKGROUNDPEN], 9);
    support.setPen(gb, rp, edge);
    gb.DrawHLine(rp, b.left, b.top + b.height - 1, b.width);

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
    // The tab in front last, so that it stands over its neighbours'
    // edges as a card in front of them would.
    var front_at: ?gc.Box = null;
    while (tabs.next(ib)) |tab| {
        const front = tab.which == own.current;
        const lift: i32 = if (front) 0 else tab_lift;
        const at = gc.Box{
            .left = b.left + tab.left,
            .top = b.top + lift,
            .width = tab.width,
            .height = b.height - lift - (if (front) @as(i32, 0) else 1),
        };
        if (front) {
            front_at = at;
        } else {
            drawTab(base, own, rp, info.draw_info, at, tab.which, @intCast(line), @intCast(baseline));
        }
    }
    if (front_at) |at| drawTab(base, own, rp, info.draw_info, at, own.current, @intCast(line), @intCast(baseline));

    if (arrows != 0) {
        const at = b.left + b.width - 2 * arrows;
        const ground = support.mixPens(pens[sc.BACKGROUNDPEN], pens[sc.SHADOWPEN], idle_ground_mix);
        for ([_]u32{ ARROW_BACK, ARROW_FORWARD }, 0..) |which, i| {
            const box = gc.Box{
                .left = at + @as(i32, @intCast(i)) * arrows,
                .top = b.top + tab_lift,
                .width = arrows,
                .height = b.height - tab_lift - 1,
            };
            support.fill(gb, rp, box, ground);
            support.setPen(gb, rp, edge);
            gb.DrawVLine(rp, box.left, box.top, box.height);
            gb.DrawHLine(rp, box.left, box.top, box.width);
            support.setPen(gb, rp, pens[sc.TEXTPEN]);
            support.drawArrow(ib, gb, null, rp, info.draw_info, .{
                .at = box,
                .vertical = false,
                .forward = which == ARROW_FORWARD,
            });
        }
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// Its size: every tab side by side, the frame round each, and a line of
/// the font with the lift above it.
fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const whole = wholeRow(base, own, g, gi);
    const room = frameRoom(base, own, if (gi) |info| info.draw_info else g.draw_info, g.style);
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
            take(base, own, o.?, in.gadget_info, what);
            support.redraw(ib, o.?, in.gadget_info);
            in.termination.* = @intCast(own.current);
            return gc.GMR_NOREUSE | gc.GMR_VERIFY;
        },
        // A press is done with as it is pressed: nothing is held.
        gc.GM_HANDLEINPUT => return gc.GMR_NOREUSE,
        gc.GM_GOINACTIVE => return 0,
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
