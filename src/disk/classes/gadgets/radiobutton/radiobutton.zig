// SPDX-License-Identifier: MIT
//! radiobutton.gadget: a column of choices of which one is on.
//!
//! The whole column is one gadgetclass gadget. It finds which line a
//! press is on, and a press on a line that is not the one on makes it the
//! one: drawn so at once, reported at once - the press ends the gadget
//! with `GMR_VERIFY`, so the window hears `IDCMP_GADGETUP` with the line's
//! number as the code - and told to the target as `RADIO_Active` and the
//! gadget's `GA_ID`. A press on the line already on ends it saying
//! nothing.
//!
//! Each line is sysiclass's `MXIMAGE`, sized to the font - a line of it
//! and a pixel high - and the choice's text to its right, in the text
//! pen. Lines are the taller of the mark and the font apart, and
//! `RADIO_Spacing` more. Disabled, the ghost goes over the whole column.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const rb = gadgets.radiobutton;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = rb.RADIO_CLASS,
    .version = 1,
    .date = "25.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// radiobutton.gadget's part of an object.
const Data = extern struct {
    labels: ?[*]const ?[*:0]const u8 = null,
    /// How many choices there are, and which is on.
    count: u32 = 0,
    active: u32 = 0,
    /// Pixels between lines, beyond the line itself.
    spacing: i32 = 1,
    /// The mark: sysiclass's MXIMAGE, at the size of `mark`.
    image: ?*Object = null,
    mark: gc.Box = .{},
};

/// Between a mark and its text.
const text_gap = 6;

/// The mark for a font whose lines are `line` high: a pixel more, and the
/// image's 17 by 9 kept.
fn markSize(line: i32) gc.Box {
    const height = line + 1;
    return .{ .width = @divTrunc(17 * height + 4, 9), .height = height };
}

/// How the column is laid out in a font: the mark, how far apart the
/// lines are, how tall the text is, and how wide the whole column is.
const Lines = struct {
    mark: gc.Box,
    pitch: i32,
    text_height: i32,
    width: i32,

    fn of(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) Lines {
        const ib = base.intuition_base;
        const measure = support.Measure.of(ib, g, gi);
        defer measure.done(ib);
        const text_height = measure.lineHeight(base.graphics_base);
        const mark = markSize(text_height);
        var widest: i32 = 0;
        for (0..own.count) |i| widest = @max(widest, measure.width(ib, own.labels.?[i].?));
        return .{
            .mark = mark,
            .pitch = @max(mark.height, text_height) + own.spacing,
            .text_height = text_height,
            .width = mark.width + text_gap + widest,
        };
    }

    /// The column's height: every line, and the spacing between them.
    fn height(lines: Lines, count: u32) i32 {
        return @as(i32, @intCast(count)) * lines.pitch - (lines.pitch - @max(lines.mark.height, lines.text_height));
    }
};

/// The image at the size of the mark, made again when that has changed.
fn fitImage(base: *gadgets.Base, own: *Data, mark: gc.Box) void {
    if (own.image != null and mark.width == own.mark.width and mark.height == own.mark.height) return;
    const size = [_]TagItem{
        .{ .tag = ic.IA_Width, .data = @intCast(mark.width) },
        .{ .tag = ic.IA_Height, .data = @intCast(mark.height) },
        .{},
    };
    if (own.image) |image| {
        _ = base.intuition_base.SetAttrsTagList(image, &size);
    } else {
        const tags = [_]TagItem{
            .{ .tag = ic.SYSIA_Which, .data = ic.MXIMAGE },
            .{ .tag = utility.TAG_MORE, .data = @intFromPtr(&size) },
        };
        own.image = base.intuition_base.NewObjectTagList(null, classusr.SYSICLASS, &tags);
    }
    own.mark = mark;
}

/// `RADIO_Labels` (made only), `RADIO_Spacing` (made only) and
/// `RADIO_Active` among `tags`. True when the choice that is on was set.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool) bool {
    const ub = base.utility_base;
    if (new) {
        if (ub.FindTagItem(rb.RADIO_Labels, tags)) |item| {
            const labels: ?[*]const ?[*:0]const u8 = @ptrFromInt(item.data);
            if (labels) |list| {
                var count: u32 = 0;
                while (list[count] != null) count += 1;
                own.labels = list;
                own.count = count;
            }
        }
        if (ub.FindTagItem(rb.RADIO_Spacing, tags)) |item| own.spacing = @max(@as(i32, @bitCast(@as(u32, @truncate(item.data)))), 0);
    }
    var changed = false;
    if (ub.FindTagItem(rb.RADIO_Active, tags)) |item| {
        own.active = @truncate(item.data);
        changed = true;
    }
    if (own.count > 0 and own.active >= own.count) own.active = own.count - 1;
    return changed;
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, rp: *graphics.RastPort) void {
    const info = gi orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const g = gc.gadget(o);
    const own = classes.instData(Data, cl, o);
    const lines = Lines.of(base, own, g, gi);
    fitImage(base, own, lines.mark);
    const image = own.image orelse return;
    const b = gc.boxFor(g, gi);
    const pens = info.draw_info.pens;
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);

    // The ground first: a ghost from being disabled goes with it.
    support.fill(gb, rp, b, pens[sc.BACKGROUNDPEN]);
    const line_height = @max(lines.mark.height, lines.text_height);
    for (0..own.count) |i| {
        const top = b.top + @as(i32, @intCast(i)) * lines.pitch;
        const state = if (i == own.active) ic.IDS_SELECTED else ic.IDS_NORMAL;
        ib.DrawImageState(rp, image, b.left, top + @divTrunc(line_height - lines.mark.height, 2), state, info.draw_info);
        const text_top = top + @divTrunc(line_height - lines.text_height, 2);
        support.drawText(gb, rp, b.left + lines.mark.width + text_gap, text_top, own.labels.?[i].?, pens[sc.TEXTPEN]);
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
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
            _ = setAttrs(base, own, new.attr_list, true);
            const g = gc.gadget(obj);
            const lines = Lines.of(base, own, g, null);
            if (own.count > 0) fitImage(base, own, lines.mark);
            // No choices, or no mark to show them with: no gadget.
            if (own.count == 0 or own.image == null) {
                ib.DisposeObject(own.image);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            // Reported as it is pressed; made without a size, as big as
            // its lines.
            const ub = base.utility_base;
            const sized = ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null;
            const tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = if (sized) utility.TAG_DONE else gc.GA_Width, .data = @intCast(lines.width) },
                .{ .tag = gc.GA_Height, .data = @intCast(lines.height(own.count)) },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            return made;
        },
        classusr.OM_DISPOSE => {
            ib.DisposeObject(classes.instData(Data, cl, o orelse return 0).image);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, classes.instData(Data, cl, o.?), set.attr_list, false)) changed = 1;
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                support.redraw(ib, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            if (get.attr_id == rb.RADIO_Active) {
                get.storage.* = classes.instData(Data, cl, o.?).active;
                return 1;
            }
            return ib.SendSuperMessage(cl, o, msg);
        },
        // Its lines, at the least and as it looks right; as wide as there
        // is room at the most, and no taller.
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const lines = Lines.of(base, own, gc.gadget(o.?), ask.gadget_info);
            const height = lines.height(own.count);
            ask.domain = if (ask.which == gc.GDOMAIN_MAXIMUM)
                .{ .width = gc.GDOMAIN_UNLIMITED, .height = height }
            else
                .{ .width = lines.width, .height = height };
            return 1;
        },
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const b = gc.boxFor(gc.gadget(o.?), ht.gadget_info);
            const hit = ht.mouse.x >= 0 and ht.mouse.y >= 0 and ht.mouse.x < b.width and ht.mouse.y < b.height;
            return if (hit) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            render(base, cl, o.?, r.gadget_info, r.rast_port);
            return 0;
        },
        // The line pressed: the one that is on now, unless it was.
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            const own = classes.instData(Data, cl, o.?);
            const lines = Lines.of(base, own, gc.gadget(o.?), in.gadget_info);
            if (in.mouse.y < 0 or own.count == 0) return gc.GMR_NOREUSE;
            const line: u32 = @min(@as(u32, @intCast(@divTrunc(in.mouse.y, lines.pitch))), own.count - 1);
            if (line == own.active) return gc.GMR_NOREUSE;
            own.active = line;
            support.redraw(ib, o.?, in.gadget_info);
            const tags = [_]TagItem{
                .{ .tag = rb.RADIO_Active, .data = line },
                .{ .tag = gc.GA_ID, .data = gc.gadget(o.?).id },
                .{},
            };
            support.notify(ib, o.?, in.gadget_info, &tags, 0);
            in.termination.* = @intCast(line);
            return gc.GMR_NOREUSE | gc.GMR_VERIFY;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
