// SPDX-License-Identifier: MIT
//! scrollgroup.gadget: a gadget larger than its room, seen through it. What
//! a program sees is in sdk/libs/gadgets/scrollgroup.zig; this is how it
//! works.
//!
//! It is a groupgclass group whose one member is the contents. They are
//! laid out at the size they ask for, or the view's where that is larger
//! and they may grow, with their corner where the view's is less how far
//! the view has moved into them. Moving the view moves them, as a group
//! moves its members, and draws the view again.
//!
//! **What lies outside the view is cut off.** A member of a group draws
//! itself at its own box, and here a box may reach past the view. So the
//! view is the clip of everything in the contents (`GA_ClipRect`, which a
//! group hands on to its members and intuition puts in every GadgetInfo it
//! makes for one of them), and every message handed to the contents goes
//! with its GadgetInfo's clip narrowed to the view while it is handled:
//! whatever draws, through whatever RastPort `ObtainGIRPort` gives it,
//! draws on the view alone. Drawn whole, the view holds the RastPort it is
//! given to itself the same way, and has the contents draw themselves with
//! their labels and frames (`GREDRAW_REDRAW`): a view that moved keeps
//! nothing of what it showed.
//!
//! **The scrollers** are its own and in no window's list, placed before
//! every message they are handed, their `ICA_TARGET` this gadget and their
//! `ICA_MAP` turning their top into `SCROLLGROUP_Top` or `SCROLLGROUP_Left`.
//! One shows only while the contents are larger than the view that way.
//! They are made with `GA_Animate` off: a glide of their own would ask
//! intuition to draw a part it never sees, and the view follows a drag at
//! once anyway. Without them (`SCROLLGROUP_Scrollers` false) the view is
//! the whole box, and what the target is told (`tellView`) is what
//! scrollers in the window's border are set from: only what differs from
//! what it was told last, so a bar set from it and telling the view back
//! ends there.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const icc = intuition.icclass;
const pg = intuition.propgclass;
const sc = intuition.screens;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const sr = gadgets.scroller;
const sg = gadgets.scrollgroup;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = sg.SCROLLGROUP_CLASS,
    .version = 1,
    .date = "07.10.2026",
    .super = classusr.GROUPGCLASS,
    .Instance = Data,
    .dispatch = dispatch,
    .opens = &.{sr.SCROLLER_LIBRARY},
});
comptime {
    _ = Library;
}

/// How wide a scroller is, its arrows' buttons as square.
const scroll_size = 16;
/// The least of the view each way: a scroller with its arrows and a
/// little track.
const least_room = 3 * scroll_size;

const top_map = [_]TagItem{ .{ .tag = sr.SCROLLER_Top, .data = sg.SCROLLGROUP_Top }, .{} };
const left_map = [_]TagItem{ .{ .tag = sr.SCROLLER_Top, .data = sg.SCROLLGROUP_Left }, .{} };

const Scrolling = enum(u8) { none, vertical, horizontal };

/// scrollgroup.gadget's part of an object.
pub const Data = extern struct {
    contents: ?*Object = null,
    vertical: ?*Object = null,
    horizontal: ?*Object = null,
    /// How far the view is into the contents, in pixels.
    left: i32 = 0,
    top: i32 = 0,
    /// The contents' size as last laid out; 0 before.
    total_width: i32 = 0,
    total_height: i32 = 0,
    /// Which scrollers show, as last laid out.
    shows_vertical: u8 = 0,
    shows_horizontal: u8 = 0,
    /// The scroller the pointer is working, from the press to the release.
    scrolling: Scrolling = .none,
    /// Scrollers of its own, rather than ones in the window's border.
    scrollers: u8 = 1,
    /// The view as the target was last told it.
    told: View = .{},
};

/// Where the view is and how large it and the contents are, as told.
const View = extern struct {
    left: i32 = -1,
    top: i32 = -1,
    total_width: i32 = -1,
    total_height: i32 = -1,
    width: i32 = -1,
    height: i32 = -1,
};

// --- where things are -------------------------------------------------------

/// The view and the scrollers, relative to the gadget's box.
const Parts = struct { view: gc.Box, vertical: gc.Box, horizontal: gc.Box };

fn partsOf(own: *const Data, b: gc.Box) Parts {
    const across: i32 = if (own.shows_vertical != 0) @min(scroll_size, b.width) else 0;
    const down: i32 = if (own.shows_horizontal != 0) @min(scroll_size, b.height) else 0;
    const width: i32 = @max(b.width - across, 0);
    const height: i32 = @max(b.height - down, 0);
    return .{
        .view = .{ .width = width, .height = height },
        .vertical = .{ .left = width, .width = across, .height = height },
        .horizontal = .{ .top = height, .width = width, .height = down },
    };
}

/// The view as a rectangle in the window: where the contents may draw.
fn viewRect(own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) graphics.Rect {
    const b = gc.boxFor(gc.gadget(o), gi);
    const view = partsOf(own, b).view;
    return .{ .min_x = b.left, .min_y = b.top, .max_x = b.left + view.width, .max_y = b.top + view.height };
}

fn scrollerAt(own: *const Data, parts: Parts, x: i32, y: i32) Scrolling {
    const v = parts.vertical;
    if (own.shows_vertical != 0 and x >= v.left and x < v.left + v.width and y >= v.top and y < v.top + v.height) return .vertical;
    const h = parts.horizontal;
    if (own.shows_horizontal != 0 and x >= h.left and x < h.left + h.width and y >= h.top and y < h.top + h.height) return .horizontal;
    return .none;
}

fn scrollerOf(own: *const Data, which: Scrolling) ?*Object {
    return switch (which) {
        .vertical => own.vertical,
        .horizontal => own.horizontal,
        .none => null,
    };
}

/// An inner gadget put at its part of the box, in the window's coordinates.
fn place(base: *gadgets.Base, inner: *Object, b: gc.Box, at: gc.Box) void {
    support.place(base.intuition_base, inner, .{ .left = b.left + at.left, .top = b.top + at.top, .width = at.width, .height = at.height });
}

/// The furthest the view goes each way.
fn lastLeft(own: *const Data, view: gc.Box) i32 {
    return @max(own.total_width - view.width, 0);
}

fn lastTop(own: *const Data, view: gc.Box) i32 {
    return @max(own.total_height - view.height, 0);
}

// --- the contents -----------------------------------------------------------

/// What the contents ask for, as `which` (`GDOMAIN_*`); their box when they
/// do not answer.
fn contentsDomain(base: *gadgets.Base, own: *const Data, gi: ?*classusr.GadgetInfo, which: u32) gc.Box {
    const contents = own.contents orelse return .{};
    var ask = gc.GpDomain{ .gadget_info = gi, .which = which };
    if (base.intuition_base.SendMessage(contents, @ptrCast(&ask)) == 0) {
        const g = gc.gadget(contents);
        return .{ .width = g.width, .height = g.height };
    }
    return ask.domain;
}

/// The contents put with their corner where the view shows the part it is
/// at. Set without a GadgetInfo: a member moved with one may draw itself
/// on the way, and the view is drawn whole after anyway.
fn moveContents(base: *gadgets.Base, own: *const Data, b: gc.Box) void {
    const contents = own.contents orelse return;
    const tags = [_]TagItem{
        .{ .tag = gc.GA_Left, .data = @bitCast(@as(isize, b.left - own.left)) },
        .{ .tag = gc.GA_Top, .data = @bitCast(@as(isize, b.top - own.top)) },
        .{},
    };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
    _ = base.intuition_base.SendMessage(contents, @ptrCast(&set));
}

/// The contents told what they may draw on: the view, within whatever
/// this gadget may draw on itself.
fn clipContents(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) void {
    const contents = own.contents orelse return;
    const clip = graphics.Rect.intersect(viewRect(own, o, gi), gc.gadget(o).clip);
    const tags = [_]TagItem{ .{ .tag = gc.GA_ClipRect, .data = @intFromPtr(&clip) }, .{} };
    _ = base.intuition_base.SetAttrsTagList(contents, &tags);
}

/// A message for the contents, handed on through the group with its
/// GadgetInfo's clip narrowed to the view while it is handled.
fn toContents(base: *gadgets.Base, cl: *Class, own: *const Data, o: *Object, msg: *classusr.Msg, gi: ?*classusr.GadgetInfo) usize {
    const ib = base.intuition_base;
    const info = gi orelse return ib.SendSuperMessage(cl, o, msg);
    const was = info.clip;
    info.clip = graphics.Rect.intersect(was, viewRect(own, o, info));
    defer info.clip = was;
    return ib.SendSuperMessage(cl, o, msg);
}

// --- the view ---------------------------------------------------------------

/// The target told where the view is and how large it and the contents
/// are, when any of it is not what it was told last. Nothing reaches a
/// window's program without the window.
fn tellView(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    if (gi == null) return;
    const view = partsOf(own, gc.boxFor(gc.gadget(o), gi)).view;
    const now = View{ .left = own.left, .top = own.top, .total_width = own.total_width, .total_height = own.total_height, .width = view.width, .height = view.height };
    if (base.utility_base.CompareMem(&now, &own.told, @sizeOf(View)) == 0) return;
    own.told = now;
    const tags = [_]TagItem{
        .{ .tag = sg.SCROLLGROUP_Top, .data = @intCast(now.top) },
        .{ .tag = sg.SCROLLGROUP_Left, .data = @intCast(now.left) },
        .{ .tag = sg.SCROLLGROUP_TotalWidth, .data = @intCast(now.total_width) },
        .{ .tag = sg.SCROLLGROUP_TotalHeight, .data = @intCast(now.total_height) },
        .{ .tag = sg.SCROLLGROUP_VisibleWidth, .data = @intCast(now.width) },
        .{ .tag = sg.SCROLLGROUP_VisibleHeight, .data = @intCast(now.height) },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

/// The scrollers told how much there is, how much shows and where the view
/// is - and drawn at once in a window, where they are put in their place
/// first. One that does not show is told and not drawn.
fn putScrollers(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const ib = base.intuition_base;
    const b = gc.boxFor(gc.gadget(o), gi);
    const parts = partsOf(own, b);
    const sides = [_]struct { scroller: ?*Object, shows: u8, at: gc.Box, total: i32, visible: i32, top: i32 }{
        .{ .scroller = own.vertical, .shows = own.shows_vertical, .at = parts.vertical, .total = own.total_height, .visible = parts.view.height, .top = own.top },
        .{ .scroller = own.horizontal, .shows = own.shows_horizontal, .at = parts.horizontal, .total = own.total_width, .visible = parts.view.width, .top = own.left },
    };
    for (sides) |side| {
        const scroller = side.scroller orelse continue;
        if (side.shows != 0) place(base, scroller, b, side.at);
        const tags = [_]TagItem{
            .{ .tag = sr.SCROLLER_Total, .data = @intCast(@max(side.total, 1)) },
            .{ .tag = sr.SCROLLER_Visible, .data = @intCast(@max(side.visible, 1)) },
            .{ .tag = sr.SCROLLER_Top, .data = @intCast(@max(side.top, 0)) },
            .{},
        };
        var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags, .gadget_info = if (side.shows != 0) gi else null };
        _ = ib.SendMessage(scroller, @ptrCast(&set));
    }
}

/// The view moved to `left` and `top`, held to the contents: the contents
/// moved under it and the view drawn again. `tell_scrollers`: the move did
/// not come from them, so they are put where it went. Whether it moved.
fn scrollTo(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo, left: i32, top: i32, tell_scrollers: bool) bool {
    // Before it is laid out there is nothing to hold it to: kept, and
    // held when it is.
    if (own.total_width == 0 and own.total_height == 0) {
        own.left = @max(left, 0);
        own.top = @max(top, 0);
        return false;
    }
    const b = gc.boxFor(gc.gadget(o), gi);
    const view = partsOf(own, b).view;
    const new_left = @min(@max(left, 0), lastLeft(own, view));
    const new_top = @min(@max(top, 0), lastTop(own, view));
    if (new_left == own.left and new_top == own.top) return false;
    own.left = new_left;
    own.top = new_top;
    moveContents(base, own, b);
    if (tell_scrollers) putScrollers(base, own, o, gi);
    support.redraw(base.intuition_base, o, gi);
    tellView(base, own, o, gi);
    return true;
}

/// Laid out in its box: which scrollers show, the contents' size and
/// place, what they may draw on, and the scrollers told. Nothing is
/// drawn.
fn layout(base: *gadgets.Base, own: *Data, o: *Object, lay: *gc.GpLayout) void {
    const ib = base.intuition_base;
    const info = lay.gadget_info orelse return;
    const b = gc.boxFor(gc.gadget(o), info);
    const nominal = contentsDomain(base, own, info, gc.GDOMAIN_NOMINAL);
    const most = contentsDomain(base, own, info, gc.GDOMAIN_MAXIMUM);
    // A scroller each way the contents are larger than the view. One
    // taking its room can make the other needed, never the other way, so
    // a few rounds settle it.
    own.shows_vertical = 0;
    own.shows_horizontal = 0;
    if (own.scrollers != 0) for (0..3) |_| {
        const view = partsOf(own, b).view;
        own.shows_vertical = @intFromBool(nominal.height > view.height);
        own.shows_horizontal = @intFromBool(nominal.width > view.width);
    };
    const view = partsOf(own, b).view;
    // As large as they ask for, and as large as the view where they may
    // grow to it.
    own.total_width = @max(nominal.width, @min(view.width, most.width));
    own.total_height = @max(nominal.height, @min(view.height, most.height));
    own.left = @min(@max(own.left, 0), lastLeft(own, view));
    own.top = @min(@max(own.top, 0), lastTop(own, view));
    if (own.contents) |contents| {
        // Written rather than set, as a layout writes its children's box:
        // set, it would be the size they ask for from then on.
        const g = gc.gadget(contents);
        g.flags &= ~gc.GFLG_RELATIVE;
        g.width = own.total_width;
        g.height = own.total_height;
        moveContents(base, own, b);
        _ = ib.SendMessage(contents, @ptrCast(lay));
    }
    clipContents(base, own, o, info);
    putScrollers(base, own, o, null);
    tellView(base, own, o, info);
}

/// The view drawn: the window's ground, the contents held to it, then the
/// scrollers beside it.
fn render(base: *gadgets.Base, own: *Data, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    const g = gc.gadget(o);
    const b = gc.boxFor(g, info);
    const parts = partsOf(own, b);
    const view = viewRect(own, o, info);

    var was: graphics.Rect = .{};
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&was) }, .{} });
    const held = graphics.Rect.intersect(was, view);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&held) }, .{} });
    gb.EraseRect(rp, &view);
    if (own.contents) |contents| {
        const outer = info.clip;
        info.clip = graphics.Rect.intersect(outer, view);
        defer info.clip = outer;
        var whole = gc.GpRender{ .gadget_info = info, .rast_port = rp, .redraw = gc.GREDRAW_REDRAW };
        _ = ib.SendMessage(contents, @ptrCast(&whole));
    }
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&was) }, .{} });

    putScrollers(base, own, o, null);
    if (own.shows_vertical != 0) if (own.vertical) |scroller| {
        place(base, scroller, b, parts.vertical);
        _ = ib.SendMessage(scroller, @ptrCast(r));
    };
    if (own.shows_horizontal != 0) if (own.horizontal) |scroller| {
        place(base, scroller, b, parts.horizontal);
        _ = ib.SendMessage(scroller, @ptrCast(r));
    };
    // The corner the two leave between them.
    if (own.shows_vertical != 0 and own.shows_horizontal != 0) {
        support.fill(gb, rp, .{ .left = b.left + parts.vertical.left, .top = b.top + parts.horizontal.top, .width = parts.vertical.width - 1, .height = parts.horizontal.height - 1 }, info.draw_info.pens[sc.BACKGROUNDPEN]);
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// The input handed to a scroller, placed first.
fn toScroller(base: *gadgets.Base, own: *const Data, o: *Object, in: *gc.GpInput, which: Scrolling) usize {
    const scroller = scrollerOf(own, which) orelse return gc.GMR_NOREUSE;
    const b = gc.boxFor(gc.gadget(o), in.gadget_info);
    const parts = partsOf(own, b);
    const at = if (which == .vertical) parts.vertical else parts.horizontal;
    place(base, scroller, b, at);
    return support.handOnInput(base.intuition_base, scroller, in, at);
}

/// The wheel over a part of the contents that took none of it: three
/// lines a notch, down the contents, or across them with Shift or a wheel
/// that turns that way. A plain wheel moves the only way there is to move.
fn wheel(base: *gadgets.Base, own: *Data, o: *Object, wh: *const gc.GpWheel) usize {
    const ib = base.intuition_base;
    // Which ways there is anything to move to: the contents larger than
    // the view, whoever's scrollers show it.
    const view = partsOf(own, gc.boxFor(gc.gadget(o), wh.gadget_info)).view;
    const can_down = own.total_height > view.height;
    const can_across = own.total_width > view.width;
    var down = wh.down;
    var across = wh.across;
    if (!can_down and across == 0) {
        across = down;
        down = 0;
    }
    if (!can_down) down = 0;
    if (!can_across) across = 0;
    if (down == 0 and across == 0) return 0;
    const measure = support.Measure.of(ib, gc.gadget(o), wh.gadget_info);
    defer measure.done(ib);
    const line: i32 = @max(measure.lineHeight(base.graphics_base), 1);
    _ = scrollTo(base, own, o, wh.gadget_info, own.left + 3 * line * across, own.top + 3 * line * down, true);
    // Taken at either end too: the wheel was meant for this view.
    return 1;
}

/// What the scroll group asks for: the contents' size as they look right,
/// and a scroller's width beside them - a view given less height than
/// they need has a scroller down its side, and without that room would
/// need one along its bottom as well; as small as its scrollers allow at
/// the least, and no limit.
fn domain(base: *gadgets.Base, own: *const Data, ask: *const gc.GpDomain) gc.Box {
    return switch (ask.which) {
        gc.GDOMAIN_MINIMUM => blk: {
            const least = contentsDomain(base, own, ask.gadget_info, gc.GDOMAIN_MINIMUM);
            const width: i32 = @min(least.width, least_room);
            const height: i32 = @min(least.height, least_room);
            break :blk .{ .width = width, .height = height };
        },
        gc.GDOMAIN_NOMINAL => blk: {
            const nominal = contentsDomain(base, own, ask.gadget_info, gc.GDOMAIN_NOMINAL);
            const beside: i32 = if (own.scrollers != 0) scroll_size else 0;
            const width: i32 = @min(nominal.width + beside, gc.GDOMAIN_UNLIMITED);
            const height: i32 = @min(nominal.height, gc.GDOMAIN_UNLIMITED);
            break :blk .{ .width = width, .height = height };
        },
        else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = gc.GDOMAIN_UNLIMITED },
    };
}

// --- the dispatcher ---------------------------------------------------------

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const ub = base.utility_base;
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
            // A group is made as big as its members make it, which is
            // nothing yet; a scroll group given a size has that size.
            const g = gc.gadget(obj);
            if (ub.FindTagItem(gc.GA_Width, new.attr_list) orelse ub.FindTagItem(gc.GA_RelWidth, new.attr_list)) |item| g.width = @bitCast(@as(u32, @truncate(item.data)));
            if (ub.FindTagItem(gc.GA_Height, new.attr_list) orelse ub.FindTagItem(gc.GA_RelHeight, new.attr_list)) |item| g.height = @bitCast(@as(u32, @truncate(item.data)));
            const vertical_tags = [_]TagItem{
                .{ .tag = gc.GA_Animate, .data = 0 },
                .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
                .{ .tag = sr.SCROLLER_Arrows, .data = scroll_size },
                .{ .tag = icc.ICA_TARGET, .data = made },
                .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&top_map) },
                .{},
            };
            const horizontal_tags = [_]TagItem{
                .{ .tag = gc.GA_Animate, .data = 0 },
                .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
                .{ .tag = sr.SCROLLER_Arrows, .data = scroll_size },
                .{ .tag = icc.ICA_TARGET, .data = made },
                .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&left_map) },
                .{},
            };
            own.scrollers = @intFromBool(ub.GetTagData(sg.SCROLLGROUP_Scrollers, 1, new.attr_list) != 0);
            if (own.scrollers != 0) {
                own.vertical = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &vertical_tags);
                own.horizontal = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &horizontal_tags);
            }
            if (own.scrollers != 0 and (own.vertical == null or own.horizontal == null)) {
                ib.DisposeObject(own.vertical);
                ib.DisposeObject(own.horizontal);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            if (ub.GetTagData(sg.SCROLLGROUP_Contents, 0, new.attr_list) != 0) {
                const contents: *Object = @ptrFromInt(ub.GetTagData(sg.SCROLLGROUP_Contents, 0, new.attr_list));
                // A group grows round a member as it joins. A scroll
                // group's box is the layout's to give, so the one it had
                // is put back.
                const was_width = g.width;
                const was_height = g.height;
                var on = classusr.OpMember{ .method_id = classusr.OM_ADDMEMBER, .object = contents };
                if (ib.SendSuperMessage(cl, obj, @ptrCast(&on)) != 0) own.contents = contents;
                g.width = was_width;
                g.height = was_height;
            }
            own.left = @max(@as(i32, @bitCast(@as(u32, @truncate(ub.GetTagData(sg.SCROLLGROUP_Left, 0, new.attr_list))))), 0);
            own.top = @max(@as(i32, @bitCast(@as(u32, @truncate(ub.GetTagData(sg.SCROLLGROUP_Top, 0, new.attr_list))))), 0);
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            ib.DisposeObject(own.vertical);
            ib.DisposeObject(own.horizontal);
            own.vertical = null;
            own.horizontal = null;
            // The contents are the group's member, and go with it.
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const changed = ib.SendSuperMessage(cl, o, msg);
            // A clip from outside reaches the contents through the group as
            // it is; theirs is the view within it.
            if (ub.FindTagItem(gc.GA_ClipRect, set.attr_list) != null) clipContents(base, own, o.?, set.gadget_info);
            var left = own.left;
            var top = own.top;
            var asked = false;
            if (ub.FindTagItem(sg.SCROLLGROUP_Left, set.attr_list)) |item| {
                left = @bitCast(@as(u32, @truncate(item.data)));
                asked = true;
            }
            if (ub.FindTagItem(sg.SCROLLGROUP_Top, set.attr_list)) |item| {
                top = @bitCast(@as(u32, @truncate(item.data)));
                asked = true;
            }
            // A scroller that moved is where the view goes already.
            if (asked and scrollTo(base, own, o.?, set.gadget_info, left, top, msg.method_id != classusr.OM_UPDATE)) return 1;
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                sg.SCROLLGROUP_Top => get.storage.* = @intCast(own.top),
                sg.SCROLLGROUP_Left => get.storage.* = @intCast(own.left),
                sg.SCROLLGROUP_Contents => get.storage.* = @intFromPtr(own.contents),
                sg.SCROLLGROUP_TotalWidth => get.storage.* = @intCast(own.total_width),
                sg.SCROLLGROUP_TotalHeight => get.storage.* = @intCast(own.total_height),
                sg.SCROLLGROUP_VisibleWidth, sg.SCROLLGROUP_VisibleHeight => {
                    const view = partsOf(own, gc.boxFor(gc.gadget(o.?), null)).view;
                    get.storage.* = @intCast(if (get.attr_id == sg.SCROLLGROUP_VisibleWidth) view.width else view.height);
                },
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(base, classes.instData(Data, cl, o.?), ask);
            return 1;
        },
        gc.GM_LAYOUT => {
            layout(base, classes.instData(Data, cl, o.?), o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        gc.GM_RENDER => {
            render(base, classes.instData(Data, cl, o.?), o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        // A scroller, or what of the contents shows; nothing hidden behind
        // the scrollers or past the view is there to be pressed.
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const parts = partsOf(own, gc.boxFor(gc.gadget(o.?), ht.gadget_info));
            if (scrollerAt(own, parts, ht.mouse.x, ht.mouse.y) != .none) return gc.GMR_GADGETHIT;
            if (!support.inside(ht.mouse.x, ht.mouse.y, parts.view.width, parts.view.height)) return 0;
            return toContents(base, cl, own, o.?, msg, ht.gadget_info);
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (in.event != null) {
                const parts = partsOf(own, gc.boxFor(gc.gadget(o.?), in.gadget_info));
                const which = scrollerAt(own, parts, in.mouse.x, in.mouse.y);
                if (which != .none) {
                    const result = toScroller(base, own, o.?, in, which);
                    if (result == gc.GMR_MEACTIVE) own.scrolling = which;
                    return result & ~gc.GMR_VERIFY;
                }
            }
            return toContents(base, cl, own, o.?, msg, in.gadget_info);
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.scrolling != .none) {
                const result = toScroller(base, own, o.?, in, own.scrolling);
                if (result != gc.GMR_MEACTIVE) own.scrolling = .none;
                return result & ~gc.GMR_VERIFY;
            }
            return toContents(base, cl, own, o.?, msg, in.gadget_info);
        },
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.scrolling != .none) {
                const scroller = scrollerOf(own, own.scrolling).?;
                own.scrolling = .none;
                _ = ib.SendMessage(scroller, msg);
                return 0;
            }
            return toContents(base, cl, own, o.?, msg, gone.gadget_info);
        },
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            return toContents(base, cl, classes.instData(Data, cl, o.?), o.?, msg, k.gadget_info);
        },
        // The contents first - a slider in them takes the wheel - and the
        // view where they take none.
        gc.GM_WHEEL => {
            const wh: *gc.GpWheel = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const parts = partsOf(own, gc.boxFor(gc.gadget(o.?), wh.gadget_info));
            if (support.inside(wh.mouse.x, wh.mouse.y, parts.view.width, parts.view.height)) {
                const taken = toContents(base, cl, own, o.?, msg, wh.gadget_info);
                if (taken != 0) return taken;
            }
            return wheel(base, own, o.?, wh);
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
