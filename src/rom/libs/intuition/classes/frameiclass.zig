// SPDX-License-Identifier: MPL-2.0
//! frameiclass: a bevelled frame, drawn to whatever size it is asked for.
//!
//! An imageclass image whose drawing is its own: a bevel of the screen's
//! shine and shadow pens, raised or (`IA_Recessed`) sunk, filled with the
//! background pen unless `IA_EdgesOnly`. `IM_DRAWFRAME` draws it to the
//! dimensions in the message rather than the image's own, which is what
//! lets one frame object serve every window border and every button,
//! whatever their size. A selected frame is drawn sunk and filled with the
//! fill pen, as a pressed button is.
//!
//! The pens come from the DrawInfo in the message, or the default ones
//! without it.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const ic = intuition.imageclass;
const sc = intuition.screens;
const pack = utility.pack;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const d = @import("draw.zig");

/// frameiclass's part of an object.
pub const Data = extern struct {
    /// FRAMEF_RECESSED, FRAMEF_EDGES_ONLY.
    flags: u32 = 0,
    frame_type: u32 = ic.FRAME_DEFAULT,
};
const FRAMEF_RECESSED: u32 = 1 << 0;
const FRAMEF_EDGES_ONLY: u32 = 1 << 1;

const pack_table = [_]u32{
    ic.IA_Dummy,
    pack.packBit(ic.IA_Dummy, ic.IA_Recessed, @offsetOf(Data, "flags"), pack.PKCTRL_BIT, FRAMEF_RECESSED),
    pack.packBit(ic.IA_Dummy, ic.IA_EdgesOnly, @offsetOf(Data, "flags"), pack.PKCTRL_BIT, FRAMEF_EDGES_ONLY),
    pack.packEntry(ic.IA_Dummy, ic.IA_FrameType, @offsetOf(Data, "frame_type"), pack.PKCTRL_ULONG),
    pack.PACK_ENDTABLE,
};

/// Make frameiclass, from imageclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.FRAMEICLASS, classusr.IMAGECLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

// How a frame of each kind is drawn, and how much bigger than its contents
// it has to be.
//
// `stroke` is how thick the vertical strokes are - the horizontal ones are
// always one, since a pixel is taller than it is wide on the displays this
// came from and a frame drawn square looks heavy. `inset` is how many
// strokes in the second frame sits, which is what makes a ridge a ridge.
//
// The padding follows from those two: `(inset + 2) * stroke`, doubled for
// the two sides. The two is one stroke to get inside the inner frame and one
// to leave a little air around the contents.

const FrameKind = struct { stroke: i32, inset: i32 };

const kinds = [_]FrameKind{
    .{ .stroke = 1, .inset = 0 }, // FRAME_DEFAULT
    .{ .stroke = 2, .inset = 0 }, // FRAME_BUTTON
    .{ .stroke = 2, .inset = 1 }, // FRAME_RIDGE
    .{ .stroke = 2, .inset = 2 }, // FRAME_ICONDROPBOX
};

/// The strokes are one pixel tall whatever they are wide.
const stroke_height: i32 = 1;

fn kindOf(frame_type: u32) FrameKind {
    return kinds[if (frame_type < kinds.len) frame_type else 0];
}

/// How much wider and taller than its contents a frame of this kind is.
fn padOf(frame_type: u32) struct { width: i32, height: i32 } {
    const k = kindOf(frame_type);
    return .{
        .width = (k.inset + 2) * k.stroke * 2,
        .height = (k.inset + 2) * stroke_height * 2,
    };
}

/// IM_FRAMEBOX: how big this frame must be to sit around `contents`, and
/// where it then goes. The frame is centred on the contents, so what a
/// caller does with the answer is put the contents back in the middle.
fn frameBox(cl: *Class, o: *Object, msg: *ic.ImpFrameBox) usize {
    const fd = classes.instData(Data, cl, o);
    if (msg.flags & ic.FRAMEF_SPECIFY == 0) {
        const pad = padOf(fd.frame_type);
        msg.frame.width = msg.contents.width + pad.width;
        msg.frame.height = msg.contents.height + pad.height;
    }
    msg.frame.left = msg.contents.left - @divTrunc(msg.frame.width - msg.contents.width, 2);
    msg.frame.top = msg.contents.top - @divTrunc(msg.frame.height - msg.contents.height, 2);
    return 1;
}

fn draw(ib: *IntuitionBase, cl: *Class, o: *Object, msg: *ic.ImpDraw) usize {
    const fd = classes.instData(Data, cl, o);
    // imageclass's part: where the box is and how big, unless the message
    // says how big.
    const im = classes.instData(ic.Image, cl.super.?, o);
    const w = if (msg.method_id == ic.IM_DRAWFRAME) msg.dimensions.width else im.width;
    const h = if (msg.method_id == ic.IM_DRAWFRAME) msg.dimensions.height else im.height;
    const x = im.left + msg.offset.x;
    const y = im.top + msg.offset.y;

    const gb = ib.graphics_base;
    const rp = msg.rast_port;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);

    const pens = d.pensOf(msg.draw_info);
    const selected = msg.state == ic.IDS_SELECTED or msg.state == ic.IDS_INACTIVESELECTED;
    const sunk = (fd.flags & FRAMEF_RECESSED != 0) != selected;
    const light = if (sunk) pens[sc.SHADOWPEN] else pens[sc.SHINEPEN];
    const dark = if (sunk) pens[sc.SHINEPEN] else pens[sc.SHADOWPEN];

    // The outer frame, then the inner one a kind with an inset has, sunk
    // the other way round so the two together read as a ridge.
    const k = kindOf(fd.frame_type);
    // The plainest frame's edges each keep clear of the other's corners;
    // every other kind lets them meet on the diagonal.
    const joins: d.Joins = if (fd.frame_type == ic.FRAME_DEFAULT) .none else .angled;
    d.bevel(gb, rp, x, y, w, h, light, dark, k.stroke, joins);
    var dx = k.stroke;
    var dy = stroke_height;
    if (k.inset > 0) {
        dx = k.inset * k.stroke;
        dy = k.inset * stroke_height;
        d.bevel(gb, rp, x + dx, y + dy, w - 2 * dx, h - 2 * dy, dark, light, k.stroke, joins);
        dx += k.stroke;
        dy += stroke_height;
    }
    if (fd.flags & FRAMEF_EDGES_ONLY == 0) {
        const fill = if (selected) pens[sc.FILLPEN] else pens[sc.BACKGROUNDPEN];
        d.box(gb, rp, x + dx, y + dy, w - 2 * dx, h - 2 * dy, fill);
    }
    return 1;
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
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            _ = ib.utility_base.PackStructureTags(classes.instData(Data, cl, @ptrFromInt(made)), &pack_table, new.attr_list);
            return made;
        },
        classusr.OM_SET => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            _ = it.SendSuperMessage(cl, o, msg);
            _ = ib.utility_base.PackStructureTags(classes.instData(Data, cl, o orelse return 0), &pack_table, set.attr_list);
            // Any of its attributes may change how it looks.
            return 1;
        },
        ic.IM_DRAW, ic.IM_DRAWFRAME => return draw(ib, cl, o orelse return 0, @ptrCast(@alignCast(msg))),
        ic.IM_FRAMEBOX => return frameBox(cl, o orelse return 0, @ptrCast(@alignCast(msg))),
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
