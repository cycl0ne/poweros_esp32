// SPDX-License-Identifier: MIT
//! command.image: the pictures of a program's commands, drawn in colour
//! to any size (`sdk.images.command`).
//!
//! An imageclass subclass whose one attribute is which picture it is.
//! It draws in the largest square that fits the box it is given, in the
//! middle, with smooth edges, through a `shapes.Painter` - the pictures
//! themselves are in `glyphs.zig`.
//!
//! The painter lays its layers into a picture of the square (`into`),
//! which is put down with one `BlendPixelArray` and kept: drawn again at
//! the same size, in the same pens and the same state, the image puts the
//! kept picture down and paints nothing - a window being sized draws its
//! tool buttons at every step. A new size, glyph or look paints it anew;
//! `OM_DISPOSE` gives it back. Without the memory for one the picture is
//! painted straight on, as it always was - and so it is while another
//! task is drawing the same image: the kept picture is one task's at a
//! time, tried for and never waited on, so a drawing holding a window's
//! lock never waits for one that wants it.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const ic = intuition.imageclass;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const shapes = gadgets.shapes;
const command = sdk.images.command;
const exec = sdk.exec;
const glyphs = @import("glyphs.zig");
const TagItem = utility.TagItem;
const Class = classes.Class;
const Object = classes.Object;
const rtg = sdk.rtg;
const Pen = graphics.Pen;

pub const Data = extern struct {
    glyph: u32 = command.CMD_NONE,
    /// The picture last painted, and what it was painted as: its size, its
    /// glyph, the ink and ground of the look and whether it was disabled.
    kept: ?*rtg.Surface = null,
    kept_size: i32 = 0,
    kept_glyph: u32 = command.CMD_NONE,
    kept_ink: Pen = 0,
    kept_ground: Pen = 0,
    kept_disabled: u32 = 0,
    /// Held while the kept picture is painted and put down.
    lock: exec.SignalSemaphore = .{},
};

pub const Library = gadgets.ClassLibrary(.{
    .name = command.COMMAND_CLASS,
    .version = 1,
    .revision = 5,
    .date = "29.10.2026",
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
            own.* = .{ .glyph = @truncate(ub.GetTagData(command.COMMAND_Glyph, command.CMD_NONE, new.attr_list)) };
            base.sys_base.InitSemaphore(&own.lock);
            // Square, and not imageclass's own size, unless it was given one.
            const image = classes.instData(ic.Image, cl.super.?, obj);
            if (ub.FindTagItem(ic.IA_Width, new.attr_list) == null) image.width = default_size;
            if (ub.FindTagItem(ic.IA_Height, new.attr_list) == null) image.height = default_size;
            return made;
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (base.utility_base.FindTagItem(command.COMMAND_Glyph, set.attr_list)) |item| {
                classes.instData(Data, cl, o.?).glyph = @truncate(item.data);
                changed = 1;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            if (get.attr_id != command.COMMAND_Glyph) return ib.SendSuperMessage(cl, o, msg);
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
            const own = classes.instData(Data, cl, o.?);
            const look = shapes.Look.of(draw.draw_info, disabled(draw.state));
            const mine = base.sys_base.AttemptSemaphore(&own.lock);
            defer if (mine) base.sys_base.ReleaseSemaphore(&own.lock);
            const picture = (if (mine) keptFor(gb, own, size, look) else null) orelse {
                var painter = shapes.Painter.begin(frame, look);
                defer painter.end();
                glyphs.draw(&painter, own.glyph);
                return 1;
            };
            gb.BlendPixelArray(rp, picture.pixels.?, picture.pitch, @intFromEnum(rtg.PixelFormat.bgra32), 0, 0, &.{
                .min_x = frame.x,
                .min_y = frame.y,
                .max_x = frame.x + size,
                .max_y = frame.y + size,
            });
            return 1;
        },
        classusr.OM_DISPOSE => {
            if (o) |obj| {
                const own = classes.instData(Data, cl, obj);
                base.graphics_base.FreeBitMap(own.kept);
                own.kept = null;
            }
            return ib.SendSuperMessage(cl, o, msg);
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}

/// The picture of the image at `size` in `look`, painted when what was
/// kept is not that one; null without the memory for one.
fn keptFor(gb: *sdk.interface.graphics.GraphicsBase, own: *Data, size: i32, look: shapes.Look) ?*rtg.Surface {
    const look_disabled: u32 = @intFromBool(look.disabled);
    if (own.kept) |picture| {
        if (own.kept_size == size and own.kept_glyph == own.glyph and own.kept_ink == look.ink and
            own.kept_ground == look.ground and own.kept_disabled == look_disabled) return picture;
    }
    if (own.kept_size != size) {
        gb.FreeBitMap(own.kept);
        own.kept = null;
        own.kept_size = 0;
    }
    const picture = own.kept orelse gb.AllocBitMapTagList(&[_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = @intCast(size) },
        .{ .tag = graphics.BMTAG_Height, .data = @intCast(size) },
        .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(rtg.PixelFormat.bgra32) },
        .{},
    }) orelse return null;
    own.kept = picture;
    own.kept_size = size;
    // Painted from nothing: every pixel clear, the layers laid over it.
    const bytes: [*]u8 = @ptrCast(picture.pixels.?);
    @memset(bytes[0 .. @as(usize, picture.pitch) * @as(usize, @intCast(size))], 0);
    const frame = shapes.Frame{ .gb = gb, .rp = undefined, .x = 0, .y = 0, .size = size, .pens = .{} };
    var painter = shapes.Painter.begin(frame, look);
    painter.into = picture;
    glyphs.draw(&painter, own.glyph);
    own.kept_glyph = own.glyph;
    own.kept_ink = look.ink;
    own.kept_ground = look.ground;
    own.kept_disabled = look_disabled;
    return picture;
}
