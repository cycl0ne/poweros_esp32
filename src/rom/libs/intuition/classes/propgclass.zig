// SPDX-License-Identifier: MPL-2.0
//! propgclass: a container with a knob in it, which is what a slider is.
//!
//! How big the knob is says how much of a thing is in view; where it sits
//! says which part. A program says either in things - how many there are,
//! how many fit, which is first - or as fractions of the container, and the
//! two are kept in step.
//!
//! Dragging the knob moves it with the pointer and tells the gadget's
//! target the new `PGA_Top` as it goes; pressing the container beside the
//! knob moves it by one bodyful towards the press, which leaves one thing
//! of the old view in the new one. The gadget draws a frame round itself
//! unless `PGA_Borderless`, and the knob as a raised box.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const pg = intuition.propgclass;
const sc = intuition.screens;
const ie = sdk.devices.inputevent;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const gadgetclass = @import("gadgetclass.zig");
const _gadget = @import("../gadget/_gadget.zig");
const d = @import("draw.zig");

/// propgclass's part of an object.
pub const Data = extern struct {
    /// AUTOKNOB, FREEHORIZ, FREEVERT, PROPBORDERLESS, PROPNEWLOOK, and
    /// KNOBHIT while the knob is held.
    flags: u16 = pg.AUTOKNOB | pg.FREEVERT,
    pad: u16 = 0,
    /// Where the knob is and how big it is, as fractions.
    horiz_pot: u32 = 0,
    vert_pot: u32 = 0,
    horiz_body: u32 = pg.MAXBODY,
    vert_body: u32 = pg.MAXBODY,
    /// The same thing counted in things: how many there are, how many fit,
    /// which is first. A gadget starts with a count so that a program which
    /// speaks only in fractions still has a `PGA_Top` that follows them;
    /// the two are kept in step from the first moment, in either direction.
    total: u32 = 100,
    visible: u32 = 25,
    top: u32 = 0,
    /// Where in the knob it was taken hold of, so that it does not jump
    /// under the pointer.
    grab_x: i32 = 0,
    grab_y: i32 = 0,
};

/// Make propgclass, from gadgetclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.PROPGCLASS, classusr.GADGETCLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

fn own(cl: *Class, o: *Object) *Data {
    return classes.instData(Data, cl, o);
}

/// The gadget's box, in the window.
fn boxOf(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo) _gadget.Box {
    const g = gadgetclass.gadgetOf(ib, o);
    if (gi) |info| return _gadget.boxIn(g, info.domain_width, info.domain_height);
    return .{ .left = 0, .top = 0, .width = g.width, .height = g.height };
}

/// Where the knob is inside the container, both in the gadget's own
/// coordinates. The container is the box less its frame.
const Knob = struct {
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    /// The container the knob moves in.
    space_left: i32,
    space_top: i32,
    space_width: i32,
    space_height: i32,
};

fn inset(p: *const Data) i32 {
    return if (p.flags & pg.PROPBORDERLESS != 0) 0 else 2;
}

fn knobOf(p: *const Data, b: _gadget.Box) Knob {
    const edge = inset(p);
    const space_w = @max(b.width - 2 * edge, 1);
    const space_h = @max(b.height - 2 * edge, 1);

    var w = space_w;
    var h = space_h;
    if (p.flags & pg.FREEHORIZ != 0) {
        w = @max(pg.KNOBHMIN, @divTrunc(space_w * @as(i32, @intCast(p.horiz_body)), @as(i32, @intCast(pg.MAXBODY))));
        w = @min(w, space_w);
    }
    if (p.flags & pg.FREEVERT != 0) {
        h = @max(pg.KNOBVMIN, @divTrunc(space_h * @as(i32, @intCast(p.vert_body)), @as(i32, @intCast(pg.MAXBODY))));
        h = @min(h, space_h);
    }
    var x: i32 = 0;
    var y: i32 = 0;
    if (p.flags & pg.FREEHORIZ != 0) {
        x = @divTrunc((space_w - w) * @as(i32, @intCast(p.horiz_pot)), @as(i32, @intCast(pg.MAXPOT)));
    }
    if (p.flags & pg.FREEVERT != 0) {
        y = @divTrunc((space_h - h) * @as(i32, @intCast(p.vert_pot)), @as(i32, @intCast(pg.MAXPOT)));
    }
    return .{
        .left = b.left + edge + x,
        .top = b.top + edge + y,
        .width = w,
        .height = h,
        .space_left = b.left + edge,
        .space_top = b.top + edge,
        .space_width = space_w,
        .space_height = space_h,
    };
}

/// The pot a knob at this place stands at.
fn potAt(at: i32, space: i32, knob: i32) u32 {
    const room = space - knob;
    if (room <= 0) return 0;
    const clamped = @min(@max(at, 0), room);
    return @intCast(@divTrunc(@as(i64, clamped) * pg.MAXPOT, room));
}

/// Which way the knob is free to move decides which pair of fractions the
/// gadget speaks in. A gadget free both ways is read and written
/// horizontally; one free neither way is made vertical when its attributes
/// are taken, so there is always exactly one answer here.
fn horizontal(p: *const Data) bool {
    return p.flags & pg.FREEHORIZ != 0;
}

/// The pots changed: the thing count follows them, since a program may
/// read either. Nothing to count leaves `top` at nothing, which is what
/// `topOf` answers for it.
fn potsChanged(p: *Data) void {
    const pot = if (horizontal(p)) p.horiz_pot else p.vert_pot;
    p.top = pg.topOf(p.total, p.visible, pot);
}

/// The thing count changed: the pots follow it. Only the axis the knob
/// moves along is written - the other pair is the program's to set and is
/// never overwritten with a value worked out for a direction the knob
/// cannot travel in.
fn thingsChanged(p: *Data) void {
    const v = pg.valuesOf(p.total, p.visible, p.top);
    p.top = v.top;
    if (horizontal(p)) {
        p.horiz_pot = v.pot;
        p.horiz_body = v.body;
    } else {
        p.vert_pot = v.pot;
        p.vert_body = v.body;
    }
}

fn render(ib: *IntuitionBase, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, rp: *graphics.RastPort) void {
    const gi_ = gi orelse return;
    const gb = ib.graphics_base;
    const p = own(cl, o);
    // The box is already in the coordinates this RastPort draws in - the
    // domain's - so nothing is added to it. The domain's corner is what a
    // point in the window has taken off it to get here, not an offset to
    // put back on.
    const b = boxOf(ib, o, gi);
    const dri = gi_.draw_info;
    const pens = dri.pens;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    // Drawn last, over everything the gadget shows, whichever way it ends.
    const disabled = gadgetclass.gadgetOf(ib, o).flags & gadgetclass.GFLG_DISABLED != 0;
    defer if (disabled) d.ghost(gb, rp, b.left, b.top, b.width, b.height, gi_.block_pen);

    // The container: what the knob has not got.
    const k = knobOf(p, b);
    if (p.flags & pg.PROPBORDERLESS == 0) {
        d.bevel(gb, rp, b.left, b.top, b.width, b.height, pens[sc.SHADOWPEN], pens[sc.SHINEPEN], 1, .none);
    }
    d.box(gb, rp, k.space_left, k.space_top, k.space_width, k.space_height, pens[sc.BACKGROUNDPEN]);

    // The knob.
    d.box(gb, rp, k.left, k.top, k.width, k.height, pens[sc.FILLPEN]);
    if (p.flags & pg.PROPNEWLOOK != 0 and k.width > 2 and k.height > 2) {
        d.bevel(gb, rp, k.left, k.top, k.width, k.height, pens[sc.SHINEPEN], pens[sc.SHADOWPEN], 1, .none);
    }
}

/// Drawn again, if it is in a window.
fn redraw(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const it = ib.iface();
    const rp = it.ObtainGIRPort(gi) orelse return;
    defer it.ReleaseGIRPort(rp);
    var msg = gc.GpRender{ .gadget_info = gi, .rast_port = rp, .redraw = gc.GREDRAW_UPDATE };
    _ = it.SendMessage(o, @ptrCast(&msg));
}

/// The target told where the slider stands now. `GA_ID` goes with it, so
/// that a program listening to several sliders on one target can tell which
/// of them moved.
fn tell(ib: *IntuitionBase, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, flags: u32) void {
    const p = own(cl, o);
    const h = horizontal(p);
    const tags = [_]TagItem{
        .{ .tag = pg.PGA_Top, .data = p.top },
        .{ .tag = if (h) pg.PGA_HorizPot else pg.PGA_VertPot, .data = if (h) p.horiz_pot else p.vert_pot },
        .{ .tag = gc.GA_ID, .data = gadgetclass.gadgetOf(ib, o).id },
        .{},
    };
    var msg = classusr.OpUpdate{ .method_id = classusr.OM_NOTIFY, .attr_list = &tags, .gadget_info = gi, .flags = flags };
    _ = ib.iface().SendMessage(o, @ptrCast(&msg));
}

/// The pots from where the knob has been dragged to.
fn dragTo(p: *Data, k: Knob, x: i32, y: i32) bool {
    var moved = false;
    if (p.flags & pg.FREEHORIZ != 0) {
        const pot = potAt(x - p.grab_x - k.space_left, k.space_width, k.width);
        if (pot != p.horiz_pot) {
            p.horiz_pot = pot;
            moved = true;
        }
    }
    if (p.flags & pg.FREEVERT != 0) {
        const pot = potAt(y - p.grab_y - k.space_top, k.space_height, k.height);
        if (pot != p.vert_pot) {
            p.vert_pot = pot;
            moved = true;
        }
    }
    return moved;
}

/// A press beside the knob: a page towards it, on each axis the press is
/// beyond the knob on. A press level with the knob on one axis leaves that
/// axis alone, so a knob free both ways moves only the way it was asked.
fn page(p: *Data, k: Knob, x: i32, y: i32) bool {
    var moved = false;
    if (p.flags & pg.FREEVERT != 0) {
        const way: i64 = if (y < k.top) -1 else if (y >= k.top + k.height) 1 else 0;
        const to = @as(i64, p.vert_pot) + way * pageStep(p.vert_body);
        const pot: u32 = @intCast(@min(@max(to, 0), @as(i64, pg.MAXPOT)));
        if (pot != p.vert_pot) {
            p.vert_pot = pot;
            moved = true;
        }
    }
    if (p.flags & pg.FREEHORIZ != 0) {
        const way: i64 = if (x < k.left) -1 else if (x >= k.left + k.width) 1 else 0;
        const to = @as(i64, p.horiz_pot) + way * pageStep(p.horiz_body);
        const pot: u32 = @intCast(@min(@max(to, 0), @as(i64, pg.MAXPOT)));
        if (pot != p.horiz_pot) {
            p.horiz_pot = pot;
            moved = true;
        }
    }
    return moved;
}

/// How far a page moves the pot: what makes the thing at the bottom of the
/// view the one at its top. The body is the view less one thing over all
/// but one, so the step is the body over what the body leaves,
/// `body / (1 - body)` in sixteen-bit fractions; a knob of half the
/// container or more steps to the end.
fn pageStep(body: u32) i64 {
    if (body >= 0x8000) return pg.MAXPOT;
    return @divTrunc(@as(i64, body) << 16, @as(i64, 0xFFFF) - body);
}

/// What a tag list says, into the instance data: whether anything changed.
fn takeTags(p: *Data, tags: ?[*]const TagItem, ib: *IntuitionBase) bool {
    const counts_were = .{ p.total, p.visible, p.top };
    var changed = false;
    var things = false;
    var pots = false;
    var axis = false;
    var state = tags;
    while (ib.utility_base.NextTagItem(&state)) |item| {
        switch (item.tag) {
            pg.PGA_Freedom => {
                // Both brackets are needed: `&` and `|` share one
                // precedence here, so without them the whole word would be
                // masked down to the freedom bits and every other flag lost.
                const freedom = pg.FREEHORIZ | pg.FREEVERT;
                p.flags = (p.flags & ~freedom) | (@as(u16, @truncate(item.data)) & freedom);
                axis = true;
                changed = true;
            },
            pg.PGA_Borderless => {
                if (item.data != 0) p.flags |= pg.PROPBORDERLESS else p.flags &= ~pg.PROPBORDERLESS;
                changed = true;
            },
            pg.PGA_NewLook => {
                if (item.data != 0) p.flags |= pg.PROPNEWLOOK else p.flags &= ~pg.PROPNEWLOOK;
                changed = true;
            },
            pg.PGA_HorizPot => {
                p.horiz_pot = @min(@as(u32, @truncate(item.data)), pg.MAXPOT);
                pots = true;
            },
            pg.PGA_VertPot => {
                p.vert_pot = @min(@as(u32, @truncate(item.data)), pg.MAXPOT);
                pots = true;
            },
            pg.PGA_HorizBody => {
                p.horiz_body = @min(@as(u32, @truncate(item.data)), pg.MAXBODY);
                changed = true;
            },
            pg.PGA_VertBody => {
                p.vert_body = @min(@as(u32, @truncate(item.data)), pg.MAXBODY);
                changed = true;
            },
            pg.PGA_Total => {
                p.total = @truncate(item.data);
                things = true;
            },
            pg.PGA_Visible => {
                p.visible = @truncate(item.data);
                things = true;
            },
            pg.PGA_Top => {
                p.top = @truncate(item.data);
                things = true;
            },
            else => {},
        }
    }
    // A knob that may move neither way is a knob that cannot be used, and
    // every reader below has to have one axis to answer with. Give it the
    // vertical one.
    if (p.flags & (pg.FREEHORIZ | pg.FREEVERT) == 0) p.flags |= pg.FREEVERT;

    // Things win over fractions when both are given: they are the truth
    // and the fractions are worked out from them.
    // Counts told again as they were change nothing: the knob stays where
    // it is, which matters while it is being dragged and a target answers
    // with the top it was just told.
    if (things and (p.total != counts_were[0] or p.visible != counts_were[1] or p.top != counts_were[2])) {
        thingsChanged(p);
        return true;
    }
    if (pots) {
        potsChanged(p);
        return true;
    }
    // A knob told only which way it may now move says its counts again on
    // that axis - but never over fractions the same list just set.
    if (axis) {
        thingsChanged(p);
        return true;
    }
    return changed;
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
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const p = own(cl, obj);
            p.* = .{};
            // The starting counts made into fractions before the caller's
            // attributes are read, so a gadget is in step with itself
            // whichever of the two the caller then speaks in - and so that
            // one given neither has a knob of a believable size.
            thingsChanged(p);
            _ = takeTags(p, set.attr_list, ib);
            return made;
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const changed = it.SendSuperMessage(cl, o, msg);
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const mine = takeTags(own(cl, o.?), set.attr_list, ib);
            if ((changed != 0 or mine) and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                redraw(ib, o.?, set.gadget_info);
                return 0;
            }
            return if (mine) 1 else changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            const into = get.storage;
            switch (get.attr_id) {
                pg.PGA_Freedom => into.* = p.flags & (pg.FREEHORIZ | pg.FREEVERT),
                pg.PGA_Borderless => into.* = @intFromBool(p.flags & pg.PROPBORDERLESS != 0),
                pg.PGA_NewLook => into.* = @intFromBool(p.flags & pg.PROPNEWLOOK != 0),
                pg.PGA_HorizPot => into.* = p.horiz_pot,
                pg.PGA_VertPot => into.* = p.vert_pot,
                pg.PGA_HorizBody => into.* = p.horiz_body,
                pg.PGA_VertBody => into.* = p.vert_body,
                pg.PGA_Total => into.* = p.total,
                pg.PGA_Visible => into.* = p.visible,
                pg.PGA_Top => into.* = p.top,
                else => return it.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const b = boxOf(ib, o.?, ht.gadget_info);
            return if (ht.mouse.x >= 0 and ht.mouse.y >= 0 and ht.mouse.x < b.width and ht.mouse.y < b.height) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            render(ib, cl, o.?, r.gadget_info, r.rast_port);
            return 0;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            const p = own(cl, o.?);
            const b = boxOf(ib, o.?, in.gadget_info);
            const k = knobOf(p, b);
            // The mouse is in the gadget's coordinates; the knob is in the
            // box's, which start at the same place.
            const x = in.mouse.x + b.left;
            const y = in.mouse.y + b.top;
            if (x >= k.left and x < k.left + k.width and y >= k.top and y < k.top + k.height) {
                p.flags |= pg.KNOBHIT;
                p.grab_x = x - k.left;
                p.grab_y = y - k.top;
                tell(ib, cl, o.?, in.gadget_info, classusr.OPUF_INTERIM);
                return gc.GMR_MEACTIVE;
            }
            // Beside the knob: one bodyful that way, and done. Holding it
            // does it once, as a press does.
            if (page(p, k, x, y)) {
                potsChanged(p);
                redraw(ib, o.?, in.gadget_info);
                tell(ib, cl, o.?, in.gadget_info, 0);
            }
            return gc.GMR_NOREUSE | gc.GMR_VERIFY;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            const b = boxOf(ib, o.?, in.gadget_info);
            const k = knobOf(p, b);
            const x = in.mouse.x + b.left;
            const y = in.mouse.y + b.top;
            const release = if (in.event) |e|
                e.class == ie.IECLASS_NEWPOINTERPOS and e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX
            else
                false;
            if (dragTo(p, k, x, y)) {
                potsChanged(p);
                redraw(ib, o.?, in.gadget_info);
                if (!release) tell(ib, cl, o.?, in.gadget_info, classusr.OPUF_INTERIM);
            }
            if (release) {
                p.flags &= ~pg.KNOBHIT;
                tell(ib, cl, o.?, in.gadget_info, 0);
                return gc.GMR_NOREUSE | gc.GMR_VERIFY;
            }
            return gc.GMR_MEACTIVE;
        },
        gc.GM_GOINACTIVE => {
            own(cl, o.?).flags &= ~pg.KNOBHIT;
            return 0;
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
