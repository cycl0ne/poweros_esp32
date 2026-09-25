// SPDX-License-Identifier: MIT
//! cycle.gadget: a button that steps through a list of choices.
//!
//! It is a buttongclass that reports when let go over it
//! (`GA_RelVerify`): buttongclass does the pressing, and when a press
//! ends the way that counts this class takes the next choice - the one
//! before with Shift held - wrapping round at either end, makes its number
//! the code of the window's `IDCMP_GADGETUP`, and tells the target
//! `CYCLE_Active` and the gadget's `GA_ID`.
//!
//! It is drawn as a button frame of frameiclass's, raised or pressed with
//! the gadget. Inside, at the left, is the cycle glyph - an arrow going
//! round - then a divider, a line of shadow and one of shine, and the
//! choice centred in what is left, in the text pen (the fill-text pen
//! while pressed). It is as wide as the glyph and its widest choice need,
//! and a line of the font and six pixels high.

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
const cy = gadgets.cycle;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = cy.CYCLE_CLASS,
    .version = 1,
    .date = "25.09.2026",
    .super = classusr.BUTTONGCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// cycle.gadget's part of an object.
const Data = extern struct {
    labels: ?[*]const ?[*:0]const u8 = null,
    /// How many choices there are, and which is shown.
    count: u32 = 0,
    active: u32 = 0,
    /// Its button frame.
    frame: ?*Object = null,
};

/// The glyph's part of the button, divider included.
const glyph_width = 20;
/// Where the glyph starts, from the button's left.
const glyph_left = 6;
/// Room either side of the widest choice.
const text_margin = 8;

/// `CYCLE_Labels` and `CYCLE_Active` among `tags`. True when either was
/// there. Labels with no choice in them are not taken.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    const ub = base.utility_base;
    var changed = false;
    if (ub.FindTagItem(cy.CYCLE_Labels, tags)) |item| {
        const labels: ?[*]const ?[*:0]const u8 = @ptrFromInt(item.data);
        if (labels) |list| {
            var count: u32 = 0;
            while (list[count] != null) count += 1;
            if (count > 0) {
                own.labels = list;
                own.count = count;
                changed = true;
            }
        }
    }
    if (ub.FindTagItem(cy.CYCLE_Active, tags)) |item| {
        own.active = @truncate(item.data);
        changed = true;
    }
    if (own.count > 0 and own.active >= own.count) own.active = own.count - 1;
    return changed;
}

/// The button's size for the gadget's font: its frame round the glyph and
/// the widest choice.
fn nominal(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) gc.Box {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    defer measure.done(ib);
    var widest: i32 = 0;
    for (0..own.count) |i| widest = @max(widest, measure.width(ib, own.labels.?[i].?));
    var contents = ic.Box{ .width = glyph_width + widest + 2 * text_margin, .height = measure.lineHeight(base.graphics_base) };
    var box = ic.Box{};
    var msg = ic.ImpFrameBox{ .contents = &contents, .frame = &box, .draw_info = if (gi) |info| info.draw_info else g.draw_info };
    // A frame that cannot say: room for a bevel all round.
    if (own.frame == null or ib.SendMessage(own.frame, @ptrCast(&msg)) == 0) {
        return .{ .width = contents.width + 8, .height = contents.height + 6 };
    }
    return .{ .width = box.width, .height = box.height };
}

/// The glyph, in `pen`: an arrow going round, `height` tall at `left`,
/// `top`.
fn drawGlyph(gb: *GraphicsBase, rp: *graphics.RastPort, left: i32, top: i32, height: i32, pen: graphics.Pen) void {
    const points = [_][2]i32{
        .{ 7, 0 },          .{ 7, 5 },          .{ 5, 3 },          .{ 10, 3 },
        .{ 8, 5 },          .{ 8, 1 },          .{ 7, 0 },          .{ 1, 0 },
        .{ 0, 1 },          .{ 0, height - 2 }, .{ 1, height - 1 }, .{ 1, 1 },
        .{ 1, height - 1 }, .{ 7, height - 1 }, .{ 7, height - 2 }, .{ 8, height - 2 },
    };
    support.setPen(gb, rp, pen);
    gb.Move(rp, left + points[0][0], top + points[0][1]);
    for (points[1..]) |p| gb.Draw(rp, left + p[0], top + p[1]);
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, rp: *graphics.RastPort) void {
    const info = gi orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const g = gc.gadget(o);
    const own = classes.instData(Data, cl, o);
    const b = gc.boxFor(g, gi);
    const pens = info.draw_info.pens;
    const selected = g.flags & gc.GFLG_SELECTED != 0;
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);

    if (own.frame) |frame| {
        var draw = ic.ImpDraw{
            .method_id = ic.IM_DRAWFRAME,
            .rast_port = rp,
            .offset = .{ .x = b.left, .y = b.top },
            .state = if (selected) ic.IDS_SELECTED else ic.IDS_NORMAL,
            .draw_info = info.draw_info,
            .dimensions = .{ .width = b.width, .height = b.height },
        };
        _ = ib.SendMessage(frame, @ptrCast(&draw));
    }
    const ink = if (selected) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN];

    // The glyph, never shorter than 9, in the middle of the height.
    const glyph_height = @max(b.height - 5, 9);
    drawGlyph(gb, rp, b.left + glyph_left, b.top + @divTrunc(b.height - glyph_height, 2), glyph_height, ink);
    // The divider: shadow, then shine.
    support.setPen(gb, rp, pens[sc.SHADOWPEN]);
    gb.Move(rp, b.left + glyph_width, b.top + 2);
    gb.Draw(rp, b.left + glyph_width, b.top + b.height - 3);
    support.setPen(gb, rp, pens[sc.SHINEPEN]);
    gb.Move(rp, b.left + glyph_width + 1, b.top + 2);
    gb.Draw(rp, b.left + glyph_width + 1, b.top + b.height - 3);

    // The choice, in the middle of what is left.
    if (own.count > 0) {
        const text = own.labels.?[own.active].?;
        const width = gb.TextLength(rp, text, support.textLen(text));
        var line: u32 = 0;
        const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) }, .{} };
        gb.GetRPAttrs(rp, &ask);
        const room_left = b.left + glyph_width + 2;
        const room = b.width - glyph_width - 2;
        const x = room_left + @divTrunc(room - @as(i32, @intCast(width)), 2);
        const y = b.top + @divTrunc(b.height - @as(i32, @intCast(line)), 2);
        support.drawText(gb, rp, x, y, text, ink);
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// The next choice, or the one before, round at either end.
fn step(own: *Data, back: bool) void {
    if (own.count == 0) return;
    if (back) {
        own.active = if (own.active == 0) own.count - 1 else own.active - 1;
    } else {
        own.active = if (own.active + 1 >= own.count) 0 else own.active + 1;
    }
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
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            // Nothing to show, or nothing to show it in: no gadget.
            if (own.count == 0 or own.frame == null) {
                ib.DisposeObject(own.frame);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            // Reported when let go over it; made without a size, as big
            // as its choices need.
            const ub = base.utility_base;
            const sized = ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null;
            const size = nominal(base, own, gc.gadget(obj), null);
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
            ib.DisposeObject(classes.instData(Data, cl, o orelse return 0).frame);
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
                cy.CYCLE_Active => get.storage.* = own.active,
                cy.CYCLE_Labels => get.storage.* = @intFromPtr(own.labels),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        // Its frame round the glyph and the widest choice, at the least;
        // that or the size it was made with as it looks right; as wide as
        // there is room at the most, and no taller than it looks right.
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const g = gc.gadget(o.?);
            const size = nominal(base, classes.instData(Data, cl, o.?), g, ask.gadget_info);
            ask.domain = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => .{ .width = size.width, .height = size.height },
                gc.GDOMAIN_NOMINAL => .{ .width = @max(size.width, g.given_width), .height = @max(size.height, g.given_height) },
                else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = @max(size.height, g.given_height) },
            };
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
        // Let go over it: the next choice, which is the code.
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const result = ib.SendSuperMessage(cl, o, msg);
            if (result & gc.GMR_VERIFY == 0) return result;
            const own = classes.instData(Data, cl, o.?);
            const shift = ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT;
            const back = if (in.event) |e| e.qualifier & shift != 0 else false;
            step(own, back);
            in.termination.* = @intCast(own.active);
            support.redraw(ib, o.?, in.gadget_info);
            const tags = [_]TagItem{
                .{ .tag = cy.CYCLE_Active, .data = own.active },
                .{ .tag = gc.GA_ID, .data = gc.gadget(o.?).id },
                .{},
            };
            support.notify(ib, o.?, in.gadget_info, &tags, 0);
            return result;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
