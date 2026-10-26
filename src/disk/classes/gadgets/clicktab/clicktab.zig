// SPDX-License-Identifier: MIT
//! clicktab.gadget: a row of tabs, one of them the one in front.
//!
//! Each tab is a card standing on a line that runs along the bottom of
//! the row. Its edges are the style's for a button (`PART_MAIN`): light
//! on the left and along the top, dark on the right, or one colour for a
//! flat border; its top corners are rounded by the style's radius, or by
//! `tab_radius` where the style keeps its corners square. The tab in
//! front is the whole height of the row, its edges run down through the
//! line and the line is broken between them, so it opens into what is
//! below; the rest stand `tab_lift` lower, on the line. Everything inside
//! the edges is the window's ground, the same as below the line.
//!
//! As a page gadget's `PAGE_Tabs` the row is the top of the page gadget's
//! frame: the line is the frame's top edge, the frame's sides go down
//! from its two ends, and the tab in front opens into the page.
//!
//! The tabs share the row's width: all as wide as the widest of them when
//! there is room for that, else each as wide as its label needs and the
//! room left shared out among them. When they do not all fit, the row
//! starts at `CLICKTAB_FirstShown` and two arrows at the right end move it
//! along a tab at a time; a tab that would not fit whole is not drawn at
//! all, so no tab is ever cut, and the ones shown share the room.
//!
//! A tab is `support.drawOpenBox` open at the bottom; a page gadget's
//! frame is the same box open at the top, so the two are drawn alike.
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
const st = intuition.style;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const ct = gadgets.clicktab;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = ct.CLICKTAB_CLASS,
    .version = 1,
    .revision = 3,
    .date = "26.10.2026",
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

/// Room either side of a tab's label, its edges included.
const tab_margin = 10;
/// How far the tabs that are not in front stand below the row's top.
const tab_lift = 3;
/// The ground between two tabs.
const tab_gap = 2;
/// How far a tab's top corners are rounded under a style whose corners
/// are square.
const tab_radius = 6;
/// Room above and below a label, past the style's padding.
const label_air = 1;
/// How few tabs may be shown before the arrows are no use.
const least_shown = 1;

/// clicktab.gadget's part of an object.
pub const Data = extern struct {
    labels: ?[*]const ?[*:0]const u8 = null,
    count: u32 = 0,
    current: u32 = 0,
    /// The leftmost tab shown, when they do not all fit.
    first: u32 = 0,
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
                const which: u32 = @truncate(item.data);
                if (which != own.current) changed = true;
                own.current = which;
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

// --- the look -----------------------------------------------------------------

/// What the row is drawn in, from the style's look for a button.
const Look = struct {
    /// The tabs' edges, and the line: as thick as the tops of the tabs.
    edges: support.Edges,
    /// The labels.
    ink: Pen,
    /// The style's room above and below what is inside.
    padding: i32,

    fn of(ib: *IntuitionBase, dri: ?*const intuition.DrawInfo, own_style: ?*const intuition.Style) Look {
        var edges = support.Edges.of(ib, dri, own_style, st.PART_MAIN);
        if (edges.radius == 0) edges.radius = tab_radius;
        return .{
            .edges = edges,
            .ink = @truncate(ib.GetStyleAttr(dri, own_style, st.PART_MAIN, st.STATE_NORMAL, st.STYLE_TextPen)),
            .padding = @intCast(ib.GetStyleAttr(dri, own_style, st.PART_MAIN, st.STATE_NORMAL, st.STYLE_PaddingY)),
        };
    }

    /// How tall the row is for a line of `line` pixels: the label with
    /// room above and below it, the top edge, the line, and the lift.
    fn rowHeight(look: Look, line: i32) i32 {
        return line + 2 * (look.padding + label_air) + 2 * look.edges.y + tab_lift;
    }

    /// How wide each arrow is.
    fn arrowWidth(look: Look, line: i32) i32 {
        return line + 2 * look.edges.x + 4;
    }
};

fn lookFor(base: *gadgets.Base, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) Look {
    return Look.of(base.intuition_base, if (gi) |info| info.draw_info else g.draw_info, g.style);
}

// --- where the tabs are -------------------------------------------------------

/// The tabs of a row, walked from the leftmost one shown: as many as fit
/// whole in `room`, the first always, and the room shared among them.
const Tabs = struct {
    measure: support.Measure,
    own: *const Data,
    /// Where the next tab starts, and which it is.
    x: i32 = 0,
    which: u32,
    /// The tab after the last one shown.
    end: u32,
    /// Every tab this wide, when they all can be as wide as the widest;
    /// else 0, and each this much wider than its label needs.
    equal: i32 = 0,
    extra: i32 = 0,
    /// The pixels left over, one each to the first tabs.
    spare: i32 = 0,
    room: i32,

    const Tab = struct { which: u32, left: i32, width: i32 };

    fn of(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, room: i32) Tabs {
        const ib = base.intuition_base;
        var tabs = Tabs{
            .measure = support.Measure.of(ib, g, gi),
            .own = own,
            .which = own.first,
            .end = own.first,
            .room = room,
        };
        var need: i32 = 0;
        var widest: i32 = 0;
        while (tabs.end < own.count) : (tabs.end += 1) {
            const width = tabs.naturalOf(ib, tabs.end);
            const gap: i32 = if (tabs.end == own.first) 0 else tab_gap;
            if (tabs.end != own.first and need + gap + width > room) break;
            need += gap + width;
            widest = @max(widest, width);
        }
        const shown: i32 = @intCast(tabs.end - own.first);
        if (shown == 0) return tabs;
        const gaps = (shown - 1) * tab_gap;
        if (widest * shown + gaps <= room) {
            tabs.equal = @divTrunc(room - gaps, shown);
            tabs.spare = room - gaps - tabs.equal * shown;
        } else if (need < room) {
            tabs.extra = @divTrunc(room - need, shown);
            tabs.spare = room - need - tabs.extra * shown;
        }
        return tabs;
    }

    /// The width a tab's label needs, with its margins.
    fn naturalOf(tabs: *const Tabs, ib: *IntuitionBase, which: u32) i32 {
        const text = labelAt(tabs.own, which) orelse return 2 * tab_margin;
        return tabs.measure.width(ib, text) + 2 * tab_margin;
    }

    fn next(tabs: *Tabs, ib: *IntuitionBase) ?Tab {
        if (tabs.which >= tabs.end) return null;
        var width = if (tabs.equal != 0) tabs.equal else tabs.naturalOf(ib, tabs.which) + tabs.extra;
        if (tabs.spare > 0) {
            width += 1;
            tabs.spare -= 1;
        }
        // The first tab of a row too narrow for it, cut to the row.
        if (tabs.room > 0) width = @min(width, tabs.room - tabs.x);
        const tab = Tab{ .which = tabs.which, .left = tabs.x, .width = width };
        tabs.x += width + tab_gap;
        tabs.which += 1;
        return tab;
    }

    fn done(tabs: Tabs, ib: *IntuitionBase) void {
        tabs.measure.done(ib);
    }
};

/// What the whole row needs: side by side, each tab as wide as its label
/// needs (`least`) and each as wide as the widest (`even`); and how tall a
/// line of the row's font is.
const Whole = struct { least: i32, even: i32, line: i32 };

fn wholeRow(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) Whole {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    defer measure.done(ib);
    var least: i32 = 0;
    var widest: i32 = 0;
    for (0..own.count) |i| {
        const width = if (own.labels.?[i]) |text| measure.width(ib, text) + 2 * tab_margin else 2 * tab_margin;
        least += width;
        widest = @max(widest, width);
    }
    const count: i32 = @intCast(own.count);
    const gaps = @max(count - 1, 0) * tab_gap;
    return .{ .least = least + gaps, .even = widest * count + gaps, .line = measure.lineHeight(base.graphics_base) };
}

/// How wide each arrow is, and whether the row has any: it has them when
/// the tabs do not all fit in `width`.
fn arrowsFor(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, width: i32) i32 {
    const whole = wholeRow(base, own, g, gi);
    if (whole.least <= width) return 0;
    return lookFor(base, g, gi).arrowWidth(whole.line);
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

/// A tab's label, centred between its edges and the line, cut to fit.
fn drawLabel(gb: *GraphicsBase, rp: *graphics.RastPort, look: Look, text: [*:0]const u8, at: gc.Box, bottom: i32, line: i32, baseline: i32) void {
    var count = support.textLen(text);
    const room = at.width - 2 * look.edges.x - 2;
    if (gb.TextLength(rp, text, count) > room) {
        var extent: graphics.TextExtent = .{};
        count = gb.TextFit(rp, text, count, &extent, null, 1, @max(room, 0), 0);
    }
    const width = gb.TextLength(rp, text, count);
    const inside_top = at.top + look.edges.y;
    const left = at.left + @divTrunc(at.width - width, 2);
    const top = inside_top + @divTrunc(bottom - inside_top - line, 2);
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = look.ink },
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
    const look = Look.of(ib, info.draw_info, g.style);
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    var line: u32 = 0;
    var baseline: u32 = 0;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) },
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);

    // The row stands on the window's ground, as the window paints it, and
    // so does the inside of every tab.
    const row_ground = graphics.Rect{ .min_x = b.left, .min_y = b.top, .max_x = b.left + b.width, .max_y = b.top + b.height };
    gb.EraseRect(rp, &row_ground);
    const edges = look.edges;
    const line_top = b.top + b.height - edges.y;

    const arrows = arrowsFor(base, own, g, info, b.width);
    var tabs = Tabs.of(base, own, g, info, b.width - 2 * arrows);
    defer tabs.done(ib);
    // The tabs behind first, standing on the line; the one in front last,
    // so that its edges run down through the line, which is broken
    // between them.
    var front_at: ?gc.Box = null;
    while (tabs.next(ib)) |tab| {
        const left = b.left + tab.left;
        if (tab.which == own.current) {
            front_at = .{ .left = left, .top = b.top, .width = tab.width, .height = b.height };
            continue;
        }
        const at = gc.Box{ .left = left, .top = b.top + tab_lift, .width = tab.width, .height = line_top - b.top - tab_lift };
        support.drawOpenBox(gb, rp, edges, at, .bottom);
        if (labelAt(own, tab.which)) |text| drawLabel(gb, rp, look, text, at, line_top, @intCast(line), @intCast(baseline));
    }
    if (front_at) |at| {
        support.fill(gb, rp, .{ .left = b.left, .top = line_top, .width = at.left + edges.x - b.left, .height = edges.y }, edges.light);
        const after = at.left + at.width - edges.x;
        support.fill(gb, rp, .{ .left = after, .top = line_top, .width = b.left + b.width - after, .height = edges.y }, edges.light);
        support.drawOpenBox(gb, rp, edges, at, .bottom);
        if (labelAt(own, own.current)) |text| drawLabel(gb, rp, look, text, at, line_top, @intCast(line), @intCast(baseline));
    } else {
        support.fill(gb, rp, .{ .left = b.left, .top = line_top, .width = b.width, .height = edges.y }, edges.light);
    }

    if (arrows != 0) {
        const at = b.left + b.width - 2 * arrows;
        for ([_]u32{ ARROW_BACK, ARROW_FORWARD }, 0..) |which, i| {
            const box = gc.Box{
                .left = at + @as(i32, @intCast(i)) * arrows,
                .top = b.top + tab_lift,
                .width = arrows,
                .height = line_top - b.top - tab_lift,
            };
            support.drawOpenBox(gb, rp, edges, box, .bottom);
            const inside = gc.Box{ .left = box.left + edges.x, .top = box.top + edges.y, .width = box.width - 2 * edges.x, .height = box.height - edges.y };
            support.drawArrow(ib, gb, null, rp, info.draw_info, .{
                .at = inside,
                .vertical = false,
                .forward = which == ARROW_FORWARD,
            });
        }
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// Its size: every tab side by side - as wide as the widest, for the
/// nominal size - and the row's height.
fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const whole = wholeRow(base, own, g, gi);
    const look = lookFor(base, g, gi);
    const height = look.rowHeight(whole.line);
    // The least it can be: one tab and the two arrows that reach the
    // rest.
    const least = @min(whole.least, 2 * look.arrowWidth(whole.line) + 2 * tab_margin + whole.line);
    return switch (which) {
        gc.GDOMAIN_MINIMUM => .{ .width = least, .height = height },
        gc.GDOMAIN_NOMINAL => .{ .width = @max(whole.even, g.given_width), .height = height },
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
