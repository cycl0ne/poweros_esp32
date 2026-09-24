// SPDX-License-Identifier: MPL-2.0
//! itexticlass: an image whose shape is words.
//!
//! `IA_Data` is an `IntuiText`, and the image draws it: every run linked
//! after it too, each at the image's corner plus the run's own offset and
//! in its font when it names one, and all of them in the image's `IA_FGPen`
//! in JAM1 - the runs' own pens and modes are passed over, so a label takes
//! its colour from the image it is. So a label is an image like any other:
//! a gadget's `GA_Image`, or drawn with `DrawImage` beside something else.
//!
//! Without an `IntuiText` it draws nothing. `IM_ERASE` puts `IA_BGPen`
//! over the box, since text has no shape to erase on its own.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const ic = intuition.imageclass;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuiText = intuition.IntuiText;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const d = @import("draw.zig");
const printRuns = @import("../render/_render.zig").printRuns;

fn imageOf(cl: *Class, o: *Object) *ic.Image {
    return classes.instData(ic.Image, cl.super.?, o);
}

/// Make itexticlass, from imageclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.ITEXTICLASS, classusr.IMAGECLASS, null, 0) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

fn draw(ib: *IntuitionBase, cl: *Class, o: *Object, msg: *ic.ImpDraw) void {
    const image = imageOf(cl, o);
    const text: *const IntuiText = @ptrCast(@alignCast(image.data orelse return));
    printRuns(ib, msg.rast_port, text, msg.offset.x + image.left, msg.offset.y + image.top, image.fg_pen);
}

fn erase(ib: *IntuitionBase, cl: *Class, o: *Object, msg: *ic.ImpErase) void {
    const gb = ib.graphics_base;
    const image = imageOf(cl, o);
    const rp = msg.rast_port;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    // IM_ERASEFRAME says how big; IM_ERASE is the image's own size.
    const framed = msg.method_id == ic.IM_ERASEFRAME;
    const w = if (framed) msg.dimensions.width else image.width;
    const h = if (framed) msg.dimensions.height else image.height;
    d.box(gb, rp, msg.offset.x + image.left, msg.offset.y + image.top, w, h, image.bg_pen);
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const it = ib.iface();
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        ic.IM_DRAW, ic.IM_DRAWFRAME => {
            draw(ib, cl, o orelse return 0, @ptrCast(@alignCast(msg)));
            return 1;
        },
        ic.IM_ERASE, ic.IM_ERASEFRAME => {
            erase(ib, cl, o orelse return 0, @ptrCast(@alignCast(msg)));
            return 1;
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
