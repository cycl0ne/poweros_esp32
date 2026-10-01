// SPDX-License-Identifier: MPL-2.0
//! frameiclass: a frame, drawn to whatever size it is asked for.
//!
//! An imageclass image whose look is its screen's style: each frame kind is
//! a part of a style (`ic.PART_FRAME_PLAIN`, `style.PART_MAIN`,
//! `style.PART_GROUP`, `ic.PART_FRAME_DROPBOX`) and the image's state is
//! the part's state, so a frame is drawn by `DrawPart` and looks however
//! the style says that part looks. `IA_Recessed` turns its border the other
//! way and `IA_EdgesOnly` leaves its inside alone. `IM_DRAWFRAME` draws it
//! to the dimensions in the message rather than the image's own, which is
//! what lets one frame object serve every window border and every button,
//! whatever their size.
//!
//! With no style anywhere - the system's default alone - a frame is a
//! bevel of the screen's shine and shadow pens filled with its background
//! pen, and a selected one is sunk and filled with the fill pen, as a
//! pressed button is: the default is written to be the look frames always
//! had.
//!
//! How much bigger a frame is than what it holds (`IM_FRAMEBOX`) is the
//! style's border and padding, measured by `DrawPart` without drawing.

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
const graphics = sdk.graphics;
const style = intuition.style;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _style = @import("../style/_style.zig");

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

/// The part of a style a frame kind is drawn as. A kind this class does
/// not know is a plain frame.
fn partOf(frame_type: u32) u32 {
    return switch (frame_type) {
        ic.FRAME_BUTTON => style.PART_MAIN,
        ic.FRAME_RIDGE => style.PART_GROUP,
        ic.FRAME_ICONDROPBOX => ic.PART_FRAME_DROPBOX,
        else => ic.PART_FRAME_PLAIN,
    };
}

/// IM_FRAMEBOX: how big this frame must be to sit around `contents`, and
/// where it then goes. The frame is centred on the contents, so what a
/// caller does with the answer is put the contents back in the middle.
fn frameBox(ib: *IntuitionBase, cl: *Class, o: *Object, msg: *ic.ImpFrameBox) usize {
    const fd = classes.instData(Data, cl, o);
    if (msg.flags & ic.FRAMEF_SPECIFY == 0) {
        // The border and the padding, as DrawPart finds them, measured on a
        // box large enough that nothing is cut short.
        const probe = graphics.Rect{ .max_x = 4096, .max_y = 4096 };
        var inside: graphics.Rect = undefined;
        ib.iface().DrawPart(null, msg.draw_info, null, partOf(fd.frame_type), style.STATE_NORMAL, 0, &probe, &inside);
        msg.frame.width = msg.contents.width + probe.width() - inside.width();
        msg.frame.height = msg.contents.height + probe.height() - inside.height();
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

    var flags: u32 = 0;
    if (fd.flags & FRAMEF_RECESSED != 0) flags |= style.DPF_INVERT;
    if (fd.flags & FRAMEF_EDGES_ONLY != 0) flags |= style.DPF_EDGES_ONLY;
    const box = graphics.Rect{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h };
    ib.iface().DrawPart(msg.rast_port, msg.draw_info, null, partOf(fd.frame_type), _style.statesOfImage(msg.state), flags, &box, null);
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
        ic.IM_FRAMEBOX => return frameBox(ib, cl, o orelse return 0, @ptrCast(@alignCast(msg))),
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
