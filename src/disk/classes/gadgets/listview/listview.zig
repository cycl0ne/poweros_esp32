// SPDX-License-Identifier: MIT
//! listview.gadget: a scrolling list of an exec `List`'s nodes.
//!
//! The gadget is the list's lines in a sunk frame of frameiclass's, and a
//! scroller.gadget of its own at the right, from the scroller's library,
//! which this one opens (`ClassLibrary`'s `opens`). The scroller is in no
//! window's list: this gadget places it and hands it the input that lands
//! on it; its `ICA_TARGET` is this gadget, which moves the view as it
//! hears the scroller's top. What the scroller does is never reported as
//! this gadget's own.
//!
//! A line is drawn by `LISTVIEW_CallBack` when there is one and it says
//! it drew it, and otherwise as the node's name in the text pen - the
//! selected line, with `LISTVIEW_ShowSelected`, on the fill pen in the
//! fill-text pen - cut at the frame. A line the hook calls disabled is
//! ghosted and cannot be selected.
//!
//! The view moves by blitting the lines that stay (`ScrollRaster`) and
//! drawing the ones that come into it; a view that cannot be blitted, or
//! that moves further than it shows, is drawn whole.
//!
//! A press on a line selects it and holds the gadget: the selection
//! follows the pointer, and with the pointer above or below the list the
//! view moves a line at each timer event, selecting the line that comes
//! in. Let go, the press ends the way that counts, and the selected line
//! is the code.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const icc = intuition.icclass;
const pg = intuition.propgclass;
const sc = intuition.screens;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const sr = gadgets.scroller;
const lv = gadgets.listview;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = lv.LISTVIEW_CLASS,
    .version = 1,
    .date = "25.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
    .opens = &.{sr.SCROLLER_LIBRARY},
});
comptime {
    _ = Library;
}

/// Room between the frame and a line's text, at either side.
const text_margin = 2;

/// listview.gadget's part of an object.
pub const Data = extern struct {
    labels: ?*exec.List = null,
    /// How many lines the list has.
    count: u32 = 0,
    top: u32 = 0,
    selected: u32 = lv.LISTVIEW_NONE,
    read_only: u8 = 0,
    show_selected: u8 = 0,
    /// Held by a press on the list, or on the scroller.
    pressed: u8 = 0,
    in_scroller: u8 = 0,
    /// A line's height as given; 0 for a line of the font.
    item_height: u32 = 0,
    scroll_width: u32 = 16,
    hook: ?*utility.Hook = null,
    scroller: ?*Object = null,
    frame: ?*Object = null,
    /// Made with a size of its own.
    sized: u8 = 0,
    pad: [3]u8 = @splat(0),
};

fn countOf(list: ?*exec.List) u32 {
    const l = list orelse return 0;
    var n: u32 = 0;
    var node = l.first();
    while (node) |it| : (node = it.next()) n += 1;
    return n;
}

// --- where things are -------------------------------------------------------

/// The parts of the gadget's box, relative to it: the framed list, the
/// lines inside the frame, and the scroller.
pub const Parts = struct {
    frame: gc.Box,
    lines: gc.Box,
    scroller: gc.Box,
    /// How tall a line is, and how many whole lines fit.
    line_height: i32,
    visible: u32,
};

fn lineHeight(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) i32 {
    if (own.item_height != 0) return @intCast(own.item_height);
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    defer measure.done(ib);
    return @max(measure.lineHeight(base.graphics_base), 1);
}

fn partsFor(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, size: gc.Box) Parts {
    const sw: i32 = @intCast(own.scroll_width);
    const frame = gc.Box{ .width = @max(size.width - sw, 0), .height = size.height };
    const inset = support.frameInset(base.intuition_base, own.frame.?, if (gi) |info| info.draw_info else g.draw_info);
    const lines = gc.Box{
        .left = inset.left + text_margin,
        .top = inset.top,
        .width = @max(frame.width - inset.width - 2 * text_margin, 0),
        .height = @max(frame.height - inset.height, 0),
    };
    const h = lineHeight(base, own, g, gi);
    return .{
        .frame = frame,
        .lines = lines,
        .scroller = .{ .left = frame.width, .width = @min(sw, size.width), .height = size.height },
        .line_height = h,
        .visible = @intCast(@divTrunc(lines.height, h)),
    };
}

pub fn partsOf(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) Parts {
    const g = gc.gadget(o);
    const b = gc.boxFor(g, gi);
    return partsFor(base, own, g, gi, .{ .width = b.width, .height = b.height });
}

/// The furthest the top goes: the last view that is full.
fn lastTop(own: *const Data, visible: u32) u32 {
    return if (own.count > visible) own.count - visible else 0;
}

/// The scroller put where it belongs, and its place in the gadget's box.
fn placeScroller(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) gc.Box {
    const b = gc.boxFor(gc.gadget(o), gi);
    const at = partsOf(base, own, o, gi).scroller;
    support.place(base.intuition_base, own.scroller.?, .{ .left = b.left + at.left, .top = b.top + at.top, .width = at.width, .height = at.height });
    return at;
}

/// The scroller told the count and the top; drawn at once in a window,
/// where it is put in its place first.
fn putScroller(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const parts = partsOf(base, own, o, gi);
    if (gi != null) _ = placeScroller(base, own, o, gi);
    const tags = [_]TagItem{
        .{ .tag = sr.SCROLLER_Total, .data = own.count },
        .{ .tag = sr.SCROLLER_Visible, .data = parts.visible },
        .{ .tag = sr.SCROLLER_Top, .data = own.top },
        .{},
    };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags, .gadget_info = gi };
    _ = base.intuition_base.SendMessage(own.scroller.?, @ptrCast(&set));
}

// --- drawing ----------------------------------------------------------------

fn isDisabled(base: *gadgets.Base, own: *const Data, node: *exec.Node, line: u32) bool {
    const hook = own.hook orelse return false;
    var msg = lv.LVDrawMsg{ .method_id = lv.LV_ISDISABLED, .line = line };
    return base.utility_base.CallHookPkt(hook, node, @ptrCast(&msg)) == lv.LVCB_DISABLED;
}

/// One line, `line` of the list, drawn in its place: by the hook if it
/// will, else its name; ghosted when disabled.
fn drawLine(base: *gadgets.Base, own: *const Data, rp: *graphics.RastPort, info: *classusr.GadgetInfo, origin: gc.Box, parts: Parts, line: u32, node: ?*exec.Node) void {
    const gb = base.graphics_base;
    const pens = info.draw_info.pens;
    const row: i32 = @intCast(line - own.top);
    // The whole width inside the frame, margins included, so a selected
    // line's ground reaches the frame.
    const at = gc.Box{
        .left = origin.left + parts.lines.left - text_margin,
        .top = origin.top + parts.lines.top + row * parts.line_height,
        .width = parts.lines.width + 2 * text_margin,
        .height = parts.line_height,
    };
    const n = node orelse {
        support.fill(gb, rp, at, pens[sc.BACKGROUNDPEN]);
        return;
    };
    const disabled = isDisabled(base, own, n, line);
    const selected = own.show_selected != 0 and line == own.selected;
    if (own.hook) |hook| {
        var msg = lv.LVDrawMsg{
            .rast_port = rp,
            .draw_info = info.draw_info,
            .bounds = .{ .min_x = at.left, .min_y = at.top, .max_x = at.left + at.width, .max_y = at.top + at.height },
            .state = if (disabled)
                (if (selected) lv.LVR_SELECTEDDISABLED else lv.LVR_NORMALDISABLED)
            else if (selected) lv.LVR_SELECTED else lv.LVR_NORMAL,
            .line = line,
        };
        if (base.utility_base.CallHookPkt(hook, n, @ptrCast(&msg)) == lv.LVCB_OK) return;
    }
    support.fill(gb, rp, at, if (selected) pens[sc.FILLPEN] else pens[sc.BACKGROUNDPEN]);
    if (n.name) |name| {
        var count = support.textLen(name);
        if (gb.TextLength(rp, name, count) > parts.lines.width) {
            var extent: graphics.TextExtent = .{};
            count = gb.TextFit(rp, name, count, &extent, null, 1, @max(parts.lines.width, 0), 0);
        }
        var baseline: u32 = 0;
        var height: u32 = 0;
        const ask = [_]TagItem{
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
            .{},
        };
        gb.GetRPAttrs(rp, &ask);
        const tags = [_]TagItem{
            .{ .tag = graphics.RPTAG_APen, .data = if (selected) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN] },
            .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
            .{},
        };
        gb.SetRPAttrs(rp, &tags);
        const top = at.top + @divTrunc(at.height - @as(i32, @intCast(height)), 2);
        gb.Move(rp, at.left + text_margin, top + @as(i32, @intCast(baseline)));
        gb.Text(rp, name, count);
    }
    if (disabled) support.ghost(gb, rp, at, info.block_pen);
}

/// Lines `first` up to `end` of those shown.
fn drawLines(base: *gadgets.Base, own: *const Data, o: *Object, rp: *graphics.RastPort, info: *classusr.GadgetInfo, first: u32, end: u32) void {
    const b = gc.boxFor(gc.gadget(o), info);
    const parts = partsOf(base, own, o, info);
    const last = @min(end, own.top + parts.visible);
    var node: ?*exec.Node = if (own.labels) |list| lv.nodeAt(list, first) else null;
    var line = first;
    while (line < last) : (line += 1) {
        drawLine(base, own, rp, info, b, parts, line, node);
        if (node) |n| node = n.next();
    }
    // What is left below the last whole line.
    const used: i32 = @as(i32, @intCast(parts.visible)) * parts.line_height;
    support.fill(base.graphics_base, rp, .{
        .left = b.left + parts.lines.left - text_margin,
        .top = b.top + parts.lines.top + used,
        .width = parts.lines.width + 2 * text_margin,
        .height = parts.lines.height - used,
    }, info.draw_info.pens[sc.BACKGROUNDPEN]);
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const own = classes.instData(Data, cl, o);
    const saved = support.Saved.of(gb, r.rast_port);
    defer saved.restore(gb, r.rast_port);
    const b = gc.boxFor(gc.gadget(o), info);
    const parts = partsOf(base, own, o, info);
    support.drawFrame(ib, own.frame.?, r.rast_port, .{ .left = b.left, .top = b.top, .width = parts.frame.width, .height = parts.frame.height }, ic.IDS_NORMAL, info.draw_info);
    drawLines(base, own, o, r.rast_port, info, own.top, own.top + parts.visible);
    // The count in the scroller follows the size the list is drawn at.
    putScroller(base, own, o, null);
    _ = placeScroller(base, own, o, info);
    _ = ib.SendMessage(own.scroller.?, @ptrCast(r));
    if (gc.gadget(o).flags & gc.GFLG_DISABLED != 0) support.ghost(gb, r.rast_port, b, info.block_pen);
}

/// Some lines drawn again, if it is in a window.
fn redrawLines(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, first: u32, end: u32) void {
    const info = gi orelse return;
    const ib = base.intuition_base;
    const rp = ib.ObtainGIRPort(gi) orelse return;
    defer ib.ReleaseGIRPort(rp);
    const saved = support.Saved.of(base.graphics_base, rp);
    defer saved.restore(base.graphics_base, rp);
    drawLines(base, own, o, rp, info, first, end);
}

/// A line drawn again, if it is shown.
fn redrawLine(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, line: u32) void {
    if (line == lv.LISTVIEW_NONE or line < own.top) return;
    redrawLines(base, own, o, gi, line, line + 1);
}

/// The view moved to `top`: the lines that stay blitted, the ones that
/// come in drawn, and the scroller told - unless it is the one that moved.
fn scrollTo(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo, wanted: u32, tell_scroller: bool) void {
    const parts = partsOf(base, own, o, gi);
    const top = @min(wanted, lastTop(own, parts.visible));
    if (top == own.top) return;
    const was = own.top;
    own.top = top;
    if (tell_scroller) putScroller(base, own, o, gi);
    const info = gi orelse return;
    const ib = base.intuition_base;
    const rp = ib.ObtainGIRPort(gi) orelse return;
    defer ib.ReleaseGIRPort(rp);
    const saved = support.Saved.of(base.graphics_base, rp);
    defer saved.restore(base.graphics_base, rp);
    const moved: u32 = if (top > was) top - was else was - top;
    const b = gc.boxFor(gc.gadget(o), info);
    const shown: i32 = @as(i32, @intCast(parts.visible)) * parts.line_height;
    const area = graphics.Rect{
        .min_x = b.left + parts.lines.left - text_margin,
        .min_y = b.top + parts.lines.top,
        .max_x = b.left + parts.lines.left + parts.lines.width + text_margin,
        .max_y = b.top + parts.lines.top + shown,
    };
    const dy = (@as(i32, @intCast(top)) - @as(i32, @intCast(was))) * parts.line_height;
    if (moved < parts.visible and base.graphics_base.ScrollRaster(rp, 0, dy, &area)) {
        if (top > was) {
            drawLines(base, own, o, rp, info, top + parts.visible - moved, top + parts.visible);
        } else {
            drawLines(base, own, o, rp, info, top, top + moved);
        }
        return;
    }
    drawLines(base, own, o, rp, info, top, top + parts.visible);
}

/// The selection moved to `line`: the old line and the new drawn again.
fn select(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo, line: u32) void {
    if (line == own.selected) return;
    const was = own.selected;
    own.selected = line;
    if (own.show_selected == 0) return;
    redrawLine(base, own, o, gi, was);
    redrawLine(base, own, o, gi, line);
}

/// The line under a point in the gadget's box, if it is one that can be
/// selected.
fn lineAt(base: *gadgets.Base, own: *const Data, parts: Parts, y: i32) ?u32 {
    if (own.count == 0) return null;
    const row = @divFloor(y - parts.lines.top, parts.line_height);
    const clamped: i64 = @max(0, @min(row, @as(i64, parts.visible) - 1));
    const line: u32 = @intCast(@min(@as(i64, own.top) + clamped, @as(i64, own.count) - 1));
    if (own.labels) |list| if (lv.nodeAt(list, line)) |node| {
        if (isDisabled(base, own, node, line)) return null;
    };
    return line;
}

/// The target told the selection.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const tags = [_]TagItem{
        .{ .tag = lv.LISTVIEW_Selected, .data = own.selected },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

// --- attributes -------------------------------------------------------------

/// What `tags` asked for: everything drawn again (`whole`), the view at
/// a top, or a line made visible.
const Change = struct { whole: bool = false, top: ?u32 = null, visible: ?u32 = null };

fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool) Change {
    const ub = base.utility_base;
    var change = Change{};
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            lv.LISTVIEW_Labels => {
                if (item.data == lv.LISTVIEW_DETACH) {
                    own.labels = null;
                    own.count = 0;
                } else {
                    own.labels = @ptrFromInt(item.data);
                    own.count = countOf(own.labels);
                    own.top = 0;
                    own.selected = lv.LISTVIEW_NONE;
                }
                change.whole = true;
            },
            lv.LISTVIEW_Top => change.top = @truncate(item.data),
            lv.LISTVIEW_MakeVisible => change.visible = @truncate(item.data),
            lv.LISTVIEW_Selected => {
                const line: u32 = @truncate(item.data);
                own.selected = if (line < own.count) line else lv.LISTVIEW_NONE;
                change.whole = true;
            },
            else => if (new) switch (item.tag) {
                lv.LISTVIEW_ReadOnly => own.read_only = @intFromBool(item.data != 0),
                lv.LISTVIEW_ShowSelected => own.show_selected = @intFromBool(item.data != 0),
                lv.LISTVIEW_ItemHeight => own.item_height = @truncate(item.data),
                lv.LISTVIEW_CallBack => own.hook = @ptrFromInt(item.data),
                lv.LISTVIEW_ScrollWidth => own.scroll_width = @truncate(item.data),
                else => {},
            },
        }
    }
    return change;
}

/// The top that makes `line` shown, moving as little as it can.
fn topShowing(own: *const Data, line: u32, visible: u32) u32 {
    if (line < own.top) return line;
    if (visible > 0 and line >= own.top + visible) return line - visible + 1;
    return own.top;
}

fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const h = lineHeight(base, own, g, gi);
    const inset = support.frameInset(base.intuition_base, own.frame.?, if (gi) |info| info.draw_info else g.draw_info);
    const sw: i32 = @intCast(own.scroll_width);
    const across = inset.width + 2 * text_margin + sw;
    return switch (which) {
        gc.GDOMAIN_MINIMUM => .{ .width = across + 40, .height = inset.height + 3 * h },
        gc.GDOMAIN_NOMINAL => if (own.sized != 0)
            .{ .width = g.given_width, .height = g.given_height }
        else
            .{ .width = across + 160, .height = inset.height + 6 * h },
        else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = gc.GDOMAIN_UNLIMITED },
    };
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
            const change = setAttrs(base, own, new.attr_list, true);
            const frame_tags = [_]TagItem{
                .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON },
                .{ .tag = ic.IA_Recessed, .data = 1 },
                .{},
            };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            const scroller_tags = [_]TagItem{
                .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
                .{ .tag = sr.SCROLLER_Arrows, .data = own.scroll_width },
                .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(obj) },
                .{},
            };
            if (own.frame != null) own.scroller = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &scroller_tags);
            if (own.scroller == null) {
                ib.DisposeObject(own.frame);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            // Reported when a press on the list ends; made without a size,
            // as big as it looks right.
            const ub = base.utility_base;
            own.sized = @intFromBool(ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null);
            const size = domain(base, own, gc.gadget(obj), null, gc.GDOMAIN_NOMINAL);
            const tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = if (own.sized != 0) utility.TAG_DONE else gc.GA_Width, .data = @intCast(size.width) },
                .{ .tag = gc.GA_Height, .data = @intCast(size.height) },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            const parts = partsOf(base, own, obj, null);
            if (change.top) |top| own.top = @min(top, lastTop(own, parts.visible));
            if (change.visible) |line| own.top = @min(topShowing(own, line, parts.visible), lastTop(own, parts.visible));
            putScroller(base, own, obj, null);
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            ib.DisposeObject(own.scroller);
            ib.DisposeObject(own.frame);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const ub = base.utility_base;
            // The scroller moving: the view follows it.
            if (msg.method_id == classusr.OM_UPDATE) if (ub.FindTagItem(sr.SCROLLER_Top, set.attr_list)) |item| {
                scrollTo(base, own, o.?, set.gadget_info, @truncate(item.data), false);
                return 0;
            };
            var changed = ib.SendSuperMessage(cl, o, msg);
            const change = setAttrs(base, own, set.attr_list, false);
            const parts = partsOf(base, own, o.?, set.gadget_info);
            var top = own.top;
            if (change.top) |wanted| top = wanted;
            if (change.visible) |line| top = topShowing(own, line, parts.visible);
            if (change.whole) {
                own.top = @min(top, lastTop(own, parts.visible));
                putScroller(base, own, o.?, set.gadget_info);
                changed = 1;
            } else if (top != own.top) {
                scrollTo(base, own, o.?, set.gadget_info, top, true);
            }
            if (ub.FindTagItem(gc.GA_Disabled, set.attr_list)) |item| {
                const tags = [_]TagItem{ .{ .tag = gc.GA_Disabled, .data = item.data }, .{} };
                _ = ib.SetAttrsTagList(own.scroller, &tags);
            }
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
                lv.LISTVIEW_Labels => get.storage.* = @intFromPtr(own.labels),
                lv.LISTVIEW_Top => get.storage.* = own.top,
                lv.LISTVIEW_Selected => get.storage.* = own.selected,
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
            const b = gc.boxFor(gc.gadget(o.?), ht.gadget_info);
            return if (support.inside(ht.mouse.x, ht.mouse.y, b.width, b.height)) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            const own = classes.instData(Data, cl, o.?);
            const parts = partsOf(base, own, o.?, in.gadget_info);
            if (in.mouse.x >= parts.scroller.left) {
                const at = placeScroller(base, own, o.?, in.gadget_info);
                const result = support.handOnInput(ib, own.scroller.?, in, at);
                // The scroller's own ending is not the list's to report.
                if (result == gc.GMR_MEACTIVE) own.in_scroller = 1;
                return result & ~gc.GMR_VERIFY;
            }
            if (own.read_only != 0) return gc.GMR_NOREUSE;
            const line = lineAt(base, own, parts, in.mouse.y) orelse return gc.GMR_NOREUSE;
            select(base, own, o.?, in.gadget_info, line);
            own.pressed = 1;
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.in_scroller != 0) {
                const at = placeScroller(base, own, o.?, in.gadget_info);
                const result = support.handOnInput(ib, own.scroller.?, in, at);
                if (result != gc.GMR_MEACTIVE) own.in_scroller = 0;
                return result & ~gc.GMR_VERIFY;
            }
            const e = in.event orelse return gc.GMR_MEACTIVE;
            const parts = partsOf(base, own, o.?, in.gadget_info);
            if (e.class == ie.IECLASS_NEWPOINTERPOS and e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
                own.pressed = 0;
                if (own.selected == lv.LISTVIEW_NONE) return gc.GMR_NOREUSE;
                in.termination.* = @bitCast(own.selected);
                tell(base, own, o.?, in.gadget_info);
                return gc.GMR_NOREUSE | gc.GMR_VERIFY;
            }
            // Past the top or the bottom: a line at each tick.
            const above = in.mouse.y < parts.lines.top;
            const below = in.mouse.y >= parts.lines.top + @as(i32, @intCast(parts.visible)) * parts.line_height;
            if (above or below) {
                if (e.class == ie.IECLASS_TIMER) {
                    if (above and own.top > 0) scrollTo(base, own, o.?, in.gadget_info, own.top - 1, true);
                    if (below) scrollTo(base, own, o.?, in.gadget_info, own.top + 1, true);
                }
            }
            if (lineAt(base, own, parts, in.mouse.y)) |line| select(base, own, o.?, in.gadget_info, line);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            own.pressed = 0;
            if (own.in_scroller != 0) {
                own.in_scroller = 0;
                _ = placeScroller(base, own, o.?, gone.gadget_info);
                return ib.SendMessage(own.scroller.?, msg);
            }
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
