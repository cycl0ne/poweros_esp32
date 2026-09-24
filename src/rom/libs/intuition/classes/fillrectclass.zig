// SPDX-License-Identifier: MPL-2.0
//! fillrectclass: an image that is a box filled with a pattern.
//!
//! The box is filled with `IA_APattern`, a tile 16 pixels wide and
//! `1 << IA_APatSize` rows tall repeated over it, in the draw mode
//! `IA_Mode`: a set bit in `IA_FGPen`, a clear one in `IA_BGPen` under
//! JAM2 and left as it was under JAM1. Without a pattern the whole box is
//! a set bit - one colour. That is what a panel behind something, a rule
//! between two things, or the dithered ground of a requester is made of.
//!
//! `IM_DRAW` fills the image's own box, `IM_DRAWFRAME` one the size the
//! message gives. `IM_ERASE` is imageclass's: the ground put back.

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
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const d = @import("draw.zig");

/// fillrectclass's part of an object; the pattern is imageclass's data.
const Data = extern struct {
    mode: u32 = graphics.DRMD_JAM1,
    pattern_size: u32 = 0,
};

fn imageOf(cl: *Class, o: *Object) *ic.Image {
    return classes.instData(ic.Image, cl.super.?, o);
}

/// Make fillrectclass, from imageclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.FILLRECTCLASS, classusr.IMAGECLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

fn setAttrs(ib: *IntuitionBase, cl: *Class, o: *Object, tags: ?[*]const TagItem) void {
    const own = classes.instData(Data, cl, o);
    var state = tags;
    while (ib.utility_base.NextTagItem(&state)) |item| {
        switch (item.tag) {
            ic.IA_APattern => imageOf(cl, o).data = @ptrFromInt(item.data),
            ic.IA_APatSize => own.pattern_size = @truncate(item.data),
            ic.IA_Mode => own.mode = @truncate(item.data),
            else => {},
        }
    }
}

fn draw(ib: *IntuitionBase, cl: *Class, o: *Object, msg: *ic.ImpDraw) void {
    const gb = ib.graphics_base;
    const image = imageOf(cl, o);
    const own = classes.instData(Data, cl, o);
    const framed = msg.method_id == ic.IM_DRAWFRAME;
    const w = if (framed) msg.dimensions.width else image.width;
    const h = if (framed) msg.dimensions.height else image.height;
    if (w <= 0 or h <= 0) return;
    const x = image.left + msg.offset.x;
    const y = image.top + msg.offset.y;
    const area = graphics.Rect{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h };

    const rp = msg.rast_port;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    gb.SetRPAttrs(rp, &[_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = image.fg_pen },
        .{ .tag = graphics.RPTAG_BPen, .data = image.bg_pen },
        .{ .tag = graphics.RPTAG_DrMd, .data = own.mode },
        .{},
    });
    if (image.data) |pattern| {
        const rows = @as(u32, 1) << @intCast(@min(own.pattern_size, 16));
        gb.BltPattern(rp, pattern, 2, 16, rows, &area);
    } else {
        gb.RectFill(rp, &area);
    }
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
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            setAttrs(ib, cl, @ptrFromInt(made), set.attr_list);
            return made;
        },
        classusr.OM_SET => {
            _ = it.SendSuperMessage(cl, o, msg);
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            setAttrs(ib, cl, o.?, set.attr_list);
            // Anything it is told may change what it draws.
            return 1;
        },
        ic.IM_DRAW, ic.IM_DRAWFRAME => {
            draw(ib, cl, o.?, @ptrCast(@alignCast(msg)));
            return 1;
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
