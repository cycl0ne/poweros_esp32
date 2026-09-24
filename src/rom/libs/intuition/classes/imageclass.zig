// SPDX-License-Identifier: MPL-2.0
//! imageclass: a box that draws itself - a shape one bit to a pixel,
//! stencilled in two pens.
//!
//! The attributes are packed into the instance data with utility.library's
//! PackStructureTags and read back with UnpackStructureTags, all but the
//! shape's pointer: a pack table holds fields of 32 bits at most. A pointer
//! is 32 bits on the machine, but 64 on the development PC that runs the
//! host tests, where a pack entry would keep half of it.
//!
//! Drawing borrows the caller's RastPort and gives it back as it was: the
//! pens and the draw mode are read before and put back after, since a
//! RastPort is the caller's state and an image is only passing through.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const ic = intuition.imageclass;
const pack = utility.pack;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Image = ic.Image;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const draw_mod = @import("draw.zig");
const save = draw_mod.save;
const restore = draw_mod.restore;

/// Make imageclass, from rootclass, and put it on the public list. Null
/// if there was no memory or no rootclass.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.IMAGECLASS, classusr.ROOTCLASS, null, @sizeOf(Image)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

/// Every attribute but IA_Data, which is a pointer.
const pack_table = [_]u32{
    ic.IA_Dummy,
    pack.packEntry(ic.IA_Dummy, ic.IA_Left, @offsetOf(Image, "left"), pack.PKCTRL_LONG),
    pack.packEntry(ic.IA_Dummy, ic.IA_Top, @offsetOf(Image, "top"), pack.PKCTRL_LONG),
    pack.packEntry(ic.IA_Dummy, ic.IA_Width, @offsetOf(Image, "width"), pack.PKCTRL_LONG),
    pack.packEntry(ic.IA_Dummy, ic.IA_Height, @offsetOf(Image, "height"), pack.PKCTRL_LONG),
    pack.packEntry(ic.IA_Dummy, ic.IA_FGPen, @offsetOf(Image, "fg_pen"), pack.PKCTRL_ULONG),
    pack.packEntry(ic.IA_Dummy, ic.IA_BGPen, @offsetOf(Image, "bg_pen"), pack.PKCTRL_ULONG),
    pack.PACK_ENDTABLE,
};

fn setAttrs(ib: *IntuitionBase, im: *Image, tags: ?[*]const TagItem) void {
    _ = ib.utility_base.PackStructureTags(im, &pack_table, tags);
    if (ib.utility_base.FindTagItem(ic.IA_Data, tags)) |item| im.data = @ptrFromInt(item.data);
    if (ib.utility_base.FindTagItem(ic.IA_NextImage, tags)) |item| im.next = @ptrFromInt(item.data);
}

fn getAttr(ib: *IntuitionBase, im: *Image, get: *classusr.OpGet) usize {
    if (get.attr_id == ic.IA_Data) {
        get.storage.* = @intFromPtr(im.data);
        return 1;
    }
    if (get.attr_id == ic.IA_NextImage) {
        get.storage.* = @intFromPtr(im.next);
        return 1;
    }
    const one = [_]TagItem{ .{ .tag = get.attr_id, .data = @intFromPtr(get.storage) }, .{} };
    return ib.utility_base.UnpackStructureTags(im, &pack_table, &one);
}

/// IM_DRAW: the shape stencilled in the pens. A background pen with no
/// coverage at all leaves the clear bits alone (JAM1); any other draws
/// them (JAM2); and a pen that is not opaque is composed (BLEND).
fn draw(ib: *IntuitionBase, im: *Image, d: *ic.ImpDraw) usize {
    const bits = im.data orelse return 1;
    if (im.width <= 0 or im.height <= 0) return 1;
    const gb = ib.graphics_base;
    const rp = d.rast_port;
    const saved = save(gb, rp);
    defer restore(gb, rp, saved);

    var mode: graphics.DrawMode = if (im.bg_pen >> 24 == 0) graphics.DRMD_JAM1 else graphics.DRMD_JAM2;
    const clear_counts = mode == graphics.DRMD_JAM2 and !graphics.penIsOpaque(im.bg_pen);
    if (!graphics.penIsOpaque(im.fg_pen) or clear_counts) mode |= graphics.DRMD_BLEND;
    const set = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = im.fg_pen },
        .{ .tag = graphics.RPTAG_BPen, .data = im.bg_pen },
        .{ .tag = graphics.RPTAG_DrMd, .data = mode },
        .{},
    };
    gb.SetRPAttrs(rp, &set);

    const x = im.left + d.offset.x;
    const y = im.top + d.offset.y;
    const pitch: u32 = @intCast(@divTrunc(im.width + 7, 8));
    gb.BltTemplate(rp, bits, pitch, 0, 0, &.{ .min_x = x, .min_y = y, .max_x = x + im.width, .max_y = y + im.height });
    return 1;
}

/// IM_ERASE: the image's box put back to whatever belongs there.
///
/// Not a rectangle of the background pen - `EraseRect`, which paints the way
/// the RastPort says its empty parts are painted. Inside a window that is
/// the window's own ground, pattern and all, so a picture taken off a window
/// leaves what was behind it rather than a flat patch that only matches by
/// luck.
fn erase(ib: *IntuitionBase, im: *Image, e: *ic.ImpErase) void {
    const gb = ib.graphics_base;
    const width = if (e.method_id == ic.IM_ERASEFRAME) e.dimensions.width else im.width;
    const height = if (e.method_id == ic.IM_ERASEFRAME) e.dimensions.height else im.height;
    const x = im.left + e.offset.x;
    const y = im.top + e.offset.y;
    gb.EraseRect(e.rast_port, &.{ .min_x = x, .min_y = y, .max_x = x + width, .max_y = y + height });
}

/// IM_HITTEST: whether the point is in the box - the image's own, or for
/// IM_HITFRAME one of the message's size at the image's corner.
fn hitTest(im: *Image, h: *ic.ImpHitTest) usize {
    const width = if (h.method_id == ic.IM_HITFRAME) h.dimensions.width else im.width;
    const height = if (h.method_id == ic.IM_HITFRAME) h.dimensions.height else im.height;
    const p = h.point;
    const inside = p.x >= im.left and p.x < im.left + width and p.y >= im.top and p.y < im.top + height;
    return @intFromBool(inside);
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
            const im = classes.instData(Image, cl, @ptrFromInt(made));
            // An image is something to see until told otherwise: a size,
            // and a pen to draw its shape in.
            im.* = .{ .width = 80, .height = 40, .fg_pen = graphics.penRGB(0, 0, 0) };
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            setAttrs(ib, im, new.attr_list);
            return made;
        },
        classusr.OM_SET => {
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            setAttrs(ib, classes.instData(Image, cl, o orelse return 0), new.attr_list);
            return 1;
        },
        classusr.OM_GET => {
            return getAttr(ib, classes.instData(Image, cl, o orelse return 0), @ptrCast(@alignCast(msg)));
        },
        ic.IM_DRAW => {
            return draw(ib, classes.instData(Image, cl, o orelse return 0), @ptrCast(@alignCast(msg)));
        },
        ic.IM_DRAWFRAME => {
            // One size is all an imageclass image has, so a frame is drawn
            // as itself - asked of the object's own class, so a subclass
            // that draws itself is the one that answers.
            const frame: *ic.ImpDraw = @ptrCast(@alignCast(msg));
            var as_draw = frame.*;
            as_draw.method_id = ic.IM_DRAW;
            return it.SendMessage(o, @ptrCast(&as_draw));
        },
        ic.IM_ERASE, ic.IM_ERASEFRAME => {
            erase(ib, classes.instData(Image, cl, o orelse return 0), @ptrCast(@alignCast(msg)));
            return 1;
        },
        ic.IM_HITTEST, ic.IM_HITFRAME => {
            return hitTest(classes.instData(Image, cl, o orelse return 0), @ptrCast(@alignCast(msg)));
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
