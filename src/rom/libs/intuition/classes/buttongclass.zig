// SPDX-License-Identifier: MPL-2.0
//! buttongclass: a gadget that is pressed and let go.
//!
//! Pressed, it is drawn selected, and while the button is held it follows
//! the pointer: selected over it, not selected off it. Let go over it, it
//! finishes with `GMR_VERIFY`, so a `GA_RelVerify` button sends
//! `IDCMP_GADGETUP`; let go anywhere else, it finishes without. On the way
//! it tells its target its `GA_ID` - on the press and each tick as an
//! interim update, and at the end as a final one, negated when it was let go
//! off the button.
//!
//! Its look is its `GA_Image`, drawn in the state the gadget is in. Without
//! one it makes a frameiclass button frame of its own, sized to the gadget,
//! and draws `GA_Text` centred in it - so a labelled button is one object.
//! A button's image decides where it is hit when it has one of its own
//! (PointInImage); a button with its own frame is hit anywhere in its box.

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
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const gadgetclass = @import("gadgetclass.zig");
const d = @import("draw.zig");

/// buttongclass's part of an object.
pub const Data = extern struct {
    /// The frame it made for itself when it was given no image.
    frame: ?*Object = null,
};

/// Make buttongclass, from gadgetclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.BUTTONGCLASS, classusr.GADGETCLASS, null, @sizeOf(Data)) orelse return null;
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

/// The state its look is drawn in.
///
/// A gadget of a window that is not the active one is drawn in the inactive
/// states, so that a screenful of windows says at a glance which one the
/// keyboard is talking to - the same thing the border colours say. Being
/// disabled is not a state here: the ghost laid over the gadget afterwards
/// says it, whatever its image is.
pub fn state(g: *const gadgetclass.Data, gi: ?*classusr.GadgetInfo) u32 {
    const selected = g.flags & gadgetclass.GFLG_SELECTED != 0;
    const active = windowActive(gi);
    if (selected) return if (active) ic.IDS_SELECTED else ic.IDS_INACTIVESELECTED;
    return if (active) ic.IDS_NORMAL else ic.IDS_INACTIVENORMAL;
}

/// Whether the window this gadget is in is the active one. With nothing to
/// ask, it is taken to be - a gadget drawn outside a window has no other
/// answer.
pub fn windowActive(gi: ?*classusr.GadgetInfo) bool {
    const info = gi orelse return true;
    const w: *const @import("../window/_window.zig").Window = @ptrCast(@alignCast(info.window));
    return w.flags & @import("../window/_window.zig").WF_ACTIVE != 0;
}

fn render(ib: *IntuitionBase, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, rp: *graphics.RastPort) void {
    const gi_ = gi orelse return;
    const gb = ib.graphics_base;
    const it = ib.iface();
    const g = gadgetclass.gadgetOf(ib, o);
    const own = classes.instData(Data, cl, o);
    const b = @import("../gadget/_gadget.zig").boxIn(g, gi_.domain_width, gi_.domain_height);
    const dri = gi_.draw_info;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    // Drawn last, over everything the gadget shows, whichever way it ends.
    defer if (g.flags & gadgetclass.GFLG_DISABLED != 0) d.ghost(gb, rp, b.left, b.top, b.width, b.height, gi_.block_pen);

    if (g.image) |image| {
        it.DrawImageState(rp, image, b.left, b.top, state(g, gi), dri);
        return;
    }
    const frame = own.frame orelse return;
    var draw = ic.ImpDraw{
        .method_id = ic.IM_DRAWFRAME,
        .rast_port = rp,
        .offset = .{ .x = b.left, .y = b.top },
        .state = state(g, gi),
        .draw_info = dri,
        .dimensions = .{ .width = b.width, .height = b.height },
    };
    _ = it.SendMessage(frame, @ptrCast(&draw));

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

/// Drawn again, if it is in a window: a change of state that shows.
fn redraw(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const it = ib.iface();
    const rp = it.ObtainGIRPort(gi) orelse return;
    defer it.ReleaseGIRPort(rp);
    var msg = gc.GpRender{ .gadget_info = gi, .rast_port = rp, .redraw = gc.GREDRAW_UPDATE };
    _ = it.SendMessage(o, @ptrCast(&msg));
}

/// The target told the button's ID.
fn tell(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo, id: i32, flags: u32) void {
    const tags = [_]TagItem{ .{ .tag = gc.GA_ID, .data = @bitCast(@as(isize, id)) }, .{} };
    var msg = classusr.OpUpdate{ .method_id = classusr.OM_NOTIFY, .attr_list = &tags, .gadget_info = gi, .flags = flags };
    _ = ib.iface().SendMessage(o, @ptrCast(&msg));
}

/// A button is as big as what it shows, so being given an image resizes it
/// to that image - and being given none leaves it with nothing to be a
/// button around, which is a box of nothing until something says otherwise.
fn sizeToImage(ib: *IntuitionBase, o: *Object) void {
    const g = gadgetclass.gadgetOf(ib, o);
    var width: usize = 0;
    var height: usize = 0;
    if (g.image) |image| {
        _ = ib.iface().GetAttr(ic.IA_Width, image, &width);
        _ = ib.iface().GetAttr(ic.IA_Height, image, &height);
    }
    const size = [_]TagItem{
        .{ .tag = gc.GA_Width, .data = width },
        .{ .tag = gc.GA_Height, .data = height },
        .{},
    };
    _ = ib.iface().SetAttrsTagList(o, &size);
}

fn hitTest(ib: *IntuitionBase, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, x: i32, y: i32) bool {
    const g = gadgetclass.gadgetOf(ib, o);
    if (classes.instData(Data, cl, o).frame != null) {
        const b = if (gi) |info|
            @import("../gadget/_gadget.zig").boxIn(g, info.domain_width, info.domain_height)
        else
            @import("../gadget/_gadget.zig").Box{ .left = 0, .top = 0, .width = g.width, .height = g.height };
        return x >= 0 and y >= 0 and x < b.width and y < b.height;
    }
    // No image either: the whole box is the button, which is what
    // `PointInImage` answers when it is given nothing to test against.
    return ib.iface().PointInImage(x, y, g.image);
}

fn isRelease(e: ?*const ie.InputEvent) bool {
    const ev = e orelse return false;
    return ev.class == ie.IECLASS_NEWPOINTERPOS and ev.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX;
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
            // A button with nothing to show draws itself a frame, so that
            // one made with only a `GA_Text` is still a button to look at.
            // Only for a plain button: a subclass that wears a frame of its
            // own makes it itself, and two would be one too many.
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const sized = ib.utility_base.FindTagItem(gc.GA_Width, new.attr_list) != null or
                ib.utility_base.FindTagItem(gc.GA_Height, new.attr_list) != null;
            // A plain button is what it shows. A subclass sizes itself: a
            // framed button is its frame round what it shows.
            const plain = classes.objectClass(obj) == cl;
            if (plain and !sized and gadgetclass.gadgetOf(ib, obj).image != null) sizeToImage(ib, obj);
            if (classes.objectClass(obj) == cl and gadgetclass.gadgetOf(ib, obj).image == null) {
                const tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
                const frame = it.NewObjectTagList(ib.frame_class, null, &tags) orelse {
                    it.DisposeObject(obj);
                    return 0;
                };
                classes.instData(Data, cl, obj).frame = frame;
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            it.DisposeObject(classes.instData(Data, cl, o orelse return 0).frame);
            return it.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const changed = it.SendSuperMessage(cl, o, msg);
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            // A new image is a new size: the button is what it shows.
            if (classes.objectClass(o.?) == cl and ib.utility_base.FindTagItem(gc.GA_Image, set.attr_list) != null) sizeToImage(ib, o.?);
            // The true class draws what changed; a subclass does its own.
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                redraw(ib, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            return if (hitTest(ib, cl, o.?, ht.gadget_info, ht.mouse.x, ht.mouse.y)) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            render(ib, cl, o.?, r.gadget_info, r.rast_port);
            return 0;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            const g = gadgetclass.gadgetOf(ib, o.?);
            // A toggle turns over; anything else is selected for as long as
            // the button is held.
            if (g.activation & gadgetclass.GACT_TOGGLESELECT != 0) {
                g.flags ^= gadgetclass.GFLG_SELECTED;
            } else {
                g.flags |= gadgetclass.GFLG_SELECTED;
            }
            redraw(ib, o.?, in.gadget_info);
            tell(ib, o.?, in.gadget_info, @bitCast(g.id), classusr.OPUF_INTERIM);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const g = gadgetclass.gadgetOf(ib, o.?);
            const toggle = g.activation & gadgetclass.GACT_TOGGLESELECT != 0;
            var ht = gc.GpHitTest{ .gadget_info = in.gadget_info, .mouse = in.mouse };
            const over = it.SendMessage(o.?, @ptrCast(&ht)) == gc.GMR_GADGETHIT;
            // A plain button shows whether letting go now would count; a
            // toggle has already said what it is and does not flicker under
            // the pointer.
            if (!toggle and over != (g.flags & gadgetclass.GFLG_SELECTED != 0)) {
                g.flags ^= gadgetclass.GFLG_SELECTED;
                redraw(ib, o.?, in.gadget_info);
            }
            const id: i32 = @bitCast(g.id);
            if (isRelease(in.event)) {
                if (!toggle and g.flags & gadgetclass.GFLG_SELECTED != 0) {
                    g.flags &= ~gadgetclass.GFLG_SELECTED;
                    redraw(ib, o.?, in.gadget_info);
                }
                tell(ib, o.?, in.gadget_info, if (over) id else -id, 0);
                return if (over) gc.GMR_NOREUSE | gc.GMR_VERIFY else gc.GMR_NOREUSE;
            }
            if (in.event) |e| {
                if (e.class == ie.IECLASS_TIMER) tell(ib, o.?, in.gadget_info, if (over) id else -id, classusr.OPUF_INTERIM);
            }
            return gc.GMR_MEACTIVE;
        },
        gc.GM_GOINACTIVE => {
            // Taken away while pressed: drawn let go.
            const gi: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const g = gadgetclass.gadgetOf(ib, o.?);
            if (gi.abort != 0 and g.flags & gadgetclass.GFLG_SELECTED != 0) {
                g.flags &= ~gadgetclass.GFLG_SELECTED;
                redraw(ib, o.?, gi.gadget_info);
            }
            return 0;
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
