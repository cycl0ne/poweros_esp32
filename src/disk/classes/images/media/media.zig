// SPDX-License-Identifier: MIT
//! media.image: the pictures of a player's controls, drawn to any size
//! (`sdk.images.media`).
//!
//! An imageclass subclass whose one attribute is which picture it is.
//! It draws in the largest square that fits the box it is given, in the
//! middle, with smooth edges, through a `shapes.Painter` - the pictures
//! themselves are in `glyphs.zig`. Its ink is the text pen on the ground,
//! the fill-text pen on a selected button's fill. The painter's buffer is
//! made for each drawing and given back after it; without the memory for
//! it nothing is drawn.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const ic = intuition.imageclass;
const sc = intuition.screens;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const shapes = gadgets.shapes;
const media = sdk.images.media;
const glyphs = @import("glyphs.zig");
const TagItem = utility.TagItem;
const Class = classes.Class;
const Object = classes.Object;

pub const Data = extern struct {
    glyph: u32 = media.MEDIA_NONE,
};

pub const Library = gadgets.ClassLibrary(.{
    .name = media.MEDIA_CLASS,
    .version = 1,
    .revision = 1,
    .date = "28.10.2026",
    .super = classusr.IMAGECLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// How big an image is that was made without a size.
const default_size = 24;

/// Whether `state` is one of the disabled ones.
fn disabled(state: u32) bool {
    return switch (state) {
        ic.IDS_DISABLED, ic.IDS_INACTIVEDISABLED, ic.IDS_SELECTEDDISABLED => true,
        else => false,
    };
}

/// Whether `state` is drawn on a selected button's fill.
fn selected(state: u32) bool {
    return state == ic.IDS_SELECTED or state == ic.IDS_INACTIVESELECTED;
}

/// The ink and the ground a picture is drawn in: the text pen on the
/// background, or the fill-text pen on the fill.
pub fn lookOf(dri: ?*const sc.DrawInfo, state: u32) shapes.Look {
    const look = shapes.Look.of(dri, disabled(state));
    if (!selected(state)) return look;
    const info = dri orelse return look;
    return .{ .ink = info.pens[sc.FILLTEXTPEN], .ground = info.pens[sc.FILLPEN], .disabled = false };
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
            const ub = base.utility_base;
            own.* = .{ .glyph = @truncate(ub.GetTagData(media.MEDIA_Glyph, media.MEDIA_NONE, new.attr_list)) };
            // Square, and not imageclass's own size, unless it was given one.
            const image = classes.instData(ic.Image, cl.super.?, obj);
            if (ub.FindTagItem(ic.IA_Width, new.attr_list) == null) image.width = default_size;
            if (ub.FindTagItem(ic.IA_Height, new.attr_list) == null) image.height = default_size;
            return made;
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (base.utility_base.FindTagItem(media.MEDIA_Glyph, set.attr_list)) |item| {
                classes.instData(Data, cl, o.?).glyph = @truncate(item.data);
                changed = 1;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            if (get.attr_id != media.MEDIA_Glyph) return ib.SendSuperMessage(cl, o, msg);
            get.storage.* = classes.instData(Data, cl, o.?).glyph;
            return 1;
        },
        ic.IM_DRAW, ic.IM_DRAWFRAME => {
            const draw: *ic.ImpDraw = @ptrCast(@alignCast(msg));
            const image = classes.instData(ic.Image, cl.super.?, o.?);
            const framed = msg.method_id == ic.IM_DRAWFRAME;
            const width = if (framed) draw.dimensions.width else image.width;
            const height = if (framed) draw.dimensions.height else image.height;
            const size = @min(width, height);
            if (size < 4) return 1;
            const gb = base.graphics_base;
            const rp = draw.rast_port;
            const saved = support.Saved.of(gb, rp);
            defer saved.restore(gb, rp);
            gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 1 }, .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} });
            defer gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 0 }, .{} });
            // Centred in a box that is not square.
            const frame = shapes.Frame{
                .gb = gb,
                .rp = rp,
                .x = draw.offset.x + image.left + @divTrunc(width - size, 2),
                .y = draw.offset.y + image.top + @divTrunc(height - size, 2),
                .size = size,
                .pens = shapes.Pens.of(draw.draw_info),
            };
            var painter = shapes.Painter.begin(frame, lookOf(draw.draw_info, draw.state));
            defer painter.end();
            glyphs.draw(&painter, classes.instData(Data, cl, o.?).glyph);
            return 1;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
