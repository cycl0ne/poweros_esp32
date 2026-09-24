// SPDX-License-Identifier: MPL-2.0
//! frbuttonclass: a button that always wears a frame.
//!
//! It behaves as a button does - pressed, followed on and off while held,
//! finishing with `GMR_VERIFY` when it is let go over itself - and it is
//! drawn as a bevelled frame with whatever the gadget shows inside it: its
//! `GA_Image` drawn in the middle, its `GA_Text` centred, or both.
//!
//! A plain button shows its image and nothing else; this one is the button
//! with a frame of its own round it, for a program that wants the frame
//! without making one.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const gadgetclass = @import("gadgetclass.zig");
const _gadget = @import("../gadget/_gadget.zig");
const d = @import("draw.zig");

/// frbuttonclass's part of an object: the frame it draws itself in.
pub const Data = extern struct {
    frame: ?*Object = null,
};

/// Make frbuttonclass, from buttongclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.FRBUTTONCLASS, classusr.BUTTONGCLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

fn textLen(s: [*:0]const u8) u32 {
    var n: u32 = 0;
    while (s[n] != 0) n += 1;
    return n;
}

/// The state its look is drawn in - buttongclass's rule, which it is a
/// kind of: a gadget of a window that is not active is drawn as such.
const state = @import("buttongclass.zig").state;

fn render(ib: *IntuitionBase, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, rp: *graphics.RastPort) void {
    const gi_ = gi orelse return;
    const gb = ib.graphics_base;
    const it = ib.iface();
    const g = gadgetclass.gadgetOf(ib, o);
    const own = classes.instData(Data, cl, o);
    const b = _gadget.boxIn(g, gi_.domain_width, gi_.domain_height);
    const dri = gi_.draw_info;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    // Drawn last, over everything the gadget shows, whichever way it ends.
    defer if (g.flags & gadgetclass.GFLG_DISABLED != 0) d.ghost(gb, rp, b.left, b.top, b.width, b.height, gi_.block_pen);

    // The frame first, then what the gadget shows inside it.
    if (own.frame) |frame| {
        var draw = ic.ImpDraw{
            .method_id = ic.IM_DRAWFRAME,
            .rast_port = rp,
            .offset = .{ .x = b.left, .y = b.top },
            .state = state(g, gi),
            .draw_info = dri,
            .dimensions = .{ .width = b.width, .height = b.height },
        };
        _ = it.SendMessage(frame, @ptrCast(&draw));
    }
    if (g.image) |image| {
        var width: usize = 0;
        var height: usize = 0;
        _ = ib.iface().GetAttr(ic.IA_Width, image, &width);
        _ = ib.iface().GetAttr(ic.IA_Height, image, &height);
        it.DrawImageState(
            rp,
            image,
            b.left + @divTrunc(b.width - @as(i32, @intCast(width)), 2),
            b.top + @divTrunc(b.height - @as(i32, @intCast(height)), 2),
            state(g, gi),
            dri,
        );
    }
    const text = g.text orelse return;
    const n = textLen(text);
    var height: u32 = 0;
    var baseline: u32 = 0;
    const metric = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{},
    };
    gb.GetRPAttrs(rp, &metric);
    const width: i32 = @intCast(gb.TextLength(rp, text, n));
    const pens = dri.pens;
    const ink = if (g.flags & gadgetclass.GFLG_SELECTED != 0) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN];
    d.pen(gb, rp, ink);
    gb.Move(rp, b.left + @divTrunc(b.width - width, 2), b.top + @divTrunc(b.height - @as(i32, @intCast(height)), 2) + @as(i32, @intCast(baseline)));
    gb.Text(rp, text, n);
}

/// Drawn again, if it is in a window. Every class refreshes what it drew
/// itself: a superclass will not do it for a subclass, since the message it
/// answered was not addressed to the object's true class.
fn redraw(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const it = ib.iface();
    const rp = it.ObtainGIRPort(gi) orelse return;
    defer it.ReleaseGIRPort(rp);
    var msg = gc.GpRender{ .gadget_info = gi, .rast_port = rp, .redraw = gc.GREDRAW_UPDATE };
    _ = it.SendMessage(o, @ptrCast(&msg));
}

/// A framed button made without a size is its frame round what it shows:
/// its image, or else its label in the DrawInfo's font (the ROM's default
/// font without one). With neither it keeps the size it was given.
fn sizeToContents(ib: *IntuitionBase, cl: *Class, o: *Object, frame: *Object) void {
    const it = ib.iface();
    const g = gadgetclass.gadgetOf(ib, o);
    var contents = ic.Box{};
    if (g.image) |image| {
        var width: usize = 0;
        var height: usize = 0;
        _ = it.GetAttr(ic.IA_Width, image, &width);
        _ = it.GetAttr(ic.IA_Height, image, &height);
        contents.width = @intCast(width);
        contents.height = @intCast(height);
    } else if (g.text) |text| {
        const gb = ib.graphics_base;
        const given: ?*graphics.TextFont = if (g.draw_info) |dri| dri.font else null;
        const font = given orelse gb.OpenFont(graphics.POSPAZNAME, ib.font_height) orelse return;
        defer if (given == null) gb.CloseFont(font);
        const run = intuition.IntuiText{ .font = font, .text = text };
        var extent = graphics.FontExtent{};
        gb.FontExtent(font, &extent);
        contents.width = it.IntuiTextLength(&run);
        contents.height = extent.height;
    } else return;

    var box = ic.Box{};
    var msg = ic.ImpFrameBox{ .contents = &contents, .frame = &box, .draw_info = g.draw_info };
    if (it.SendMessage(frame, @ptrCast(&msg)) == 0) return;
    const tags = [_]TagItem{
        .{ .tag = gc.GA_Width, .data = @intCast(box.width) },
        .{ .tag = gc.GA_Height, .data = @intCast(box.height) },
        .{},
    };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
    _ = it.SendSuperMessage(cl, o, @ptrCast(&set));
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const it = ib.iface();
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = it.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
            const frame = it.NewObjectTagList(ib.frame_class, null, &tags) orelse {
                // Given up on through the superclass, not through the
                // object's own class: our instance data is not set up yet,
                // and our own disposal would read it.
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = it.SendSuperMessage(cl, obj, &gone);
                return 0;
            };
            classes.instData(Data, cl, obj).frame = frame;
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const ub = ib.utility_base;
            const sized = ub.FindTagItem(gc.GA_Width, new.attr_list) != null or
                ub.FindTagItem(gc.GA_Height, new.attr_list) != null;
            if (!sized) sizeToContents(ib, cl, obj, frame);
            return made;
        },
        classusr.OM_DISPOSE => {
            it.DisposeObject(classes.instData(Data, cl, o orelse return 0).frame);
            return it.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const changed = it.SendSuperMessage(cl, o, msg);
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                redraw(ib, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        gc.GM_HITTEST => {
            // Its frame is its shape, so anywhere in the box is a hit.
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const g = gadgetclass.gadgetOf(ib, o.?);
            const b = if (ht.gadget_info) |info|
                _gadget.boxIn(g, info.domain_width, info.domain_height)
            else
                _gadget.Box{ .left = 0, .top = 0, .width = g.width, .height = g.height };
            return if (ht.mouse.x >= 0 and ht.mouse.y >= 0 and ht.mouse.x < b.width and ht.mouse.y < b.height) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            render(ib, cl, o.?, r.gadget_info, r.rast_port);
            return 0;
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
