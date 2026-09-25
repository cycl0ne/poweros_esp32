// SPDX-License-Identifier: MIT
//! gradientslider.gadget: a slider whose container is a gradient.
//!
//! A gadgetclass gadget. The box has a button bevel round it; two pixels
//! in across and one down is the container, framed a pixel wide in the
//! background pen. Inside the frame is the gradient: the pens of
//! `GRAD_PenArray` spread evenly from one end to the other, each shading
//! into the next. It is worked out a pixel at a time into a picture of the
//! container's size, made again only when that size or the pens change,
//! and put down around the knob. With fewer than two pens the container is
//! one colour - the first pen, or the background pen with none.
//!
//! The knob is `GRAD_KnobPixels` long, across the container: framed in the
//! background pen, filled in the block pen, and in the fill pen while it
//! is dragged; a slider with no pens has a plain knob in the shadow pen.
//! A value `v` puts it `v / GRAD_MaxVal` of the way along what the
//! container leaves it, rounded.
//!
//! A press further than a couple of pixels before or after the knob moves
//! the value by `GRAD_SkipVal` and ends at once; on the knob, it is held
//! where it was taken and follows the pointer. The value is told to the
//! target at every change and once more when the press ends; let go, or
//! the right button - which puts the value back - ends the press the way
//! that counts.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const pg = intuition.propgclass;
const sc = intuition.screens;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const gs = gadgets.gradientslider;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = gs.GRAD_CLASS,
    .version = 1,
    .date = "25.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// The container, in from the bevel; its frame; how near the knob a press
/// still takes it.
const inset_w = 2;
const inset_h = 1;
const border = 1;
const knob_slop = 2;
/// A slider's size as it looks right: long, and as thick.
const nominal_length = 100;
const nominal_thickness = 16;

/// gradientslider.gadget's part of an object.
pub const Data = extern struct {
    current: i32 = 0,
    /// The value when a press began, for the right button.
    saved: i32 = 0,
    max: i32 = 0xFFFF,
    skip: i32 = 0x1111,
    knob_pixels: i32 = 5,
    vertical: u8 = 0,
    sized: u8 = 0,
    pad: [2]u8 = @splat(0),
    pens: ?[*]const Pen = null,
    pen_count: u32 = 0,
    /// Where the pointer took hold of the knob, from its start.
    mouse_offset: i32 = 0,
    /// The gradient inside the container's frame, a pen per pixel, and its
    /// size and the pens it was worked out from.
    picture: ?[*]Pen = null,
    picture_width: i32 = 0,
    picture_height: i32 = 0,
    picture_pens: ?[*]const Pen = null,
    picture_count: u32 = 0,
    /// The button bevel round the box.
    frame: ?*Object = null,
};

// --- where things are -------------------------------------------------------

/// The container, and the knob in it, from the box's corner; and where the
/// knob is along the container.
pub const Layout = struct {
    container: gc.Box,
    knob: gc.Box,
    /// How long the container is along the slider, how long the knob, and
    /// how far along it the knob starts.
    range: i32,
    span: i32,
    pos: i32,

    pub fn of(own: *const Data, width: i32, height: i32) Layout {
        const container = gc.Box{ .left = inset_w, .top = inset_h, .width = width - 2 * inset_w, .height = height - 2 * inset_h };
        var layout = Layout{ .container = container, .knob = container, .range = 0, .span = 0, .pos = 0 };
        const size = if (own.vertical != 0) container.height else container.width;
        if (size <= 0 or own.max <= 0) return layout;
        layout.range = size;
        layout.span = @min(own.knob_pixels, size);
        const free = layout.range - layout.span;
        const value: i64 = @max(0, @min(own.current, own.max));
        layout.pos = @intCast(@divTrunc(value * free + @divTrunc(own.max, 2), own.max));
        if (own.vertical != 0) {
            layout.knob.top += layout.pos;
            layout.knob.height = layout.span;
        } else {
            layout.knob.left += layout.pos;
            layout.knob.width = layout.span;
        }
        return layout;
    }
};

fn layoutOf(own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) Layout {
    const b = gc.boxFor(gc.gadget(o), gi);
    return Layout.of(own, b.width, b.height);
}

/// The value a knob dragged to `mouse` - the pointer less where it was
/// taken hold of - stands for.
pub fn valueAt(own: *const Data, layout: Layout, mouse: i32) i32 {
    const free = layout.range - layout.span;
    if (own.max <= 0 or free <= 0) return 0;
    const at: i64 = @max(0, @min(mouse - own.mouse_offset, free));
    return @intCast(@divTrunc(at * own.max + @divTrunc(free, 2), free));
}

// --- the gradient -------------------------------------------------------------

fn channel(pen: Pen, shift: u5) i64 {
    return @intCast((pen >> shift) & 0xFF);
}

/// The colour `along` of `length` from the start of the pens' run: the
/// two pens either side of it, mixed.
pub fn shade(pens: [*]const Pen, count: u32, along: i32, length: i32) Pen {
    if (count == 1 or length <= 1) return pens[0];
    // Where along the run of count - 1 steps, in 256ths of a step.
    const steps: i64 = count - 1;
    const at: i64 = @divTrunc(@as(i64, along) * steps * 256, length - 1);
    const index: usize = @intCast(@min(@divTrunc(at, 256), steps - 1));
    const frac: i64 = at - @as(i64, @intCast(index)) * 256;
    const a = pens[index];
    const b = pens[index + 1];
    var out: Pen = 0xFF000000;
    for ([_]u5{ 16, 8, 0 }) |shift| {
        const mixed = channel(a, shift) + @divTrunc((channel(b, shift) - channel(a, shift)) * frac, 256);
        out |= @as(Pen, @intCast(mixed)) << shift;
    }
    return out;
}

/// The gradient inside the container's frame, worked out again when its
/// size or pens have changed. Null without memory, or with no pens.
fn pictureFor(base: *gadgets.Base, own: *Data, width: i32, height: i32) ?[*]Pen {
    const pens = own.pens orelse return null;
    if (own.pen_count == 0 or width <= 0 or height <= 0) return null;
    if (own.picture) |picture| {
        if (own.picture_width == width and own.picture_height == height and own.picture_pens == own.pens and own.picture_count == own.pen_count) return picture;
        base.sys_base.FreeVec(picture);
        own.picture = null;
    }
    const bytes: usize = @intCast(@as(i64, width) * height * @sizeOf(Pen));
    const picture: [*]Pen = @ptrCast(@alignCast(base.sys_base.AllocVec(bytes, exec.MEMF_ANY) orelse return null));
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        var x: i32 = 0;
        while (x < width) : (x += 1) {
            const along = if (own.vertical != 0) y else x;
            const length = if (own.vertical != 0) height else width;
            picture[@intCast(y * width + x)] = shade(pens, own.pen_count, along, length);
        }
    }
    own.picture = picture;
    own.picture_width = width;
    own.picture_height = height;
    own.picture_pens = own.pens;
    own.picture_count = own.pen_count;
    return picture;
}

// --- drawing ------------------------------------------------------------------

fn frameLines(gb: *sdk.interface.graphics.GraphicsBase, rp: *graphics.RastPort, box: gc.Box, pen: Pen) void {
    if (box.width <= 0 or box.height <= 0) return;
    support.setPen(gb, rp, pen);
    gb.DrawRect(rp, &.{ .min_x = box.left, .min_y = box.top, .max_x = box.left + box.width, .max_y = box.top + box.height });
}

/// The container around the knob and the knob, and with `whole` the bevel
/// and the container's frame too. Every pixel once, so a dragged knob does
/// not flicker.
fn draw(base: *gadgets.Base, own: *Data, o: *Object, rp: *graphics.RastPort, info: *classusr.GadgetInfo, whole: bool) void {
    const gb = base.graphics_base;
    const pens = info.draw_info.pens;
    const g = gc.gadget(o);
    const b = gc.boxFor(g, info);
    const layout = Layout.of(own, b.width, b.height);
    const saved_rp = support.Saved.of(gb, rp);
    defer saved_rp.restore(gb, rp);
    const at = struct {
        fn box(origin: gc.Box, part: gc.Box) gc.Box {
            return .{ .left = origin.left + part.left, .top = origin.top + part.top, .width = part.width, .height = part.height };
        }
    }.box;

    const coloured = own.pen_count > 0;
    if (whole) {
        if (own.frame) |frame| support.drawFrame(base.intuition_base, frame, rp, b, ic.IDS_NORMAL, info.draw_info);
        frameLines(gb, rp, at(b, layout.container), pens[sc.BACKGROUNDPEN]);
    }
    // What of the container the knob leaves, before it and after it.
    var inner = layout.container;
    if (coloured) inner = .{ .left = inner.left + border, .top = inner.top + border, .width = inner.width - 2 * border, .height = inner.height - 2 * border };
    const picture = pictureFor(base, own, inner.width, inner.height);
    const knob = layout.knob;
    const pieces: [2]gc.Box = if (own.vertical != 0) .{
        .{ .left = inner.left, .top = inner.top, .width = inner.width, .height = knob.top - inner.top },
        .{ .left = inner.left, .top = knob.top + knob.height, .width = inner.width, .height = inner.top + inner.height - (knob.top + knob.height) },
    } else .{
        .{ .left = inner.left, .top = inner.top, .width = knob.left - inner.left, .height = inner.height },
        .{ .left = knob.left + knob.width, .top = inner.top, .width = inner.left + inner.width - (knob.left + knob.width), .height = inner.height },
    };
    for (pieces) |piece| {
        if (piece.width <= 0 or piece.height <= 0) continue;
        if (picture) |pixels| {
            gb.WritePixelArray(
                rp,
                @ptrCast(pixels),
                @intCast(inner.width * @sizeOf(Pen)),
                @intFromEnum(sdk.rtg.bitmaps.PixelFormat.bgra32),
                piece.left - inner.left,
                piece.top - inner.top,
                &.{ .min_x = b.left + piece.left, .min_y = b.top + piece.top, .max_x = b.left + piece.left + piece.width, .max_y = b.top + piece.top + piece.height },
            );
        } else {
            support.fill(gb, rp, at(b, piece), if (coloured) own.pens.?[0] else pens[sc.BACKGROUNDPEN]);
        }
    }

    // The knob: a plain box without pens; else framed, and filled as it is
    // held or not.
    if (!coloured) {
        support.fill(gb, rp, at(b, knob), pens[sc.SHADOWPEN]);
    } else {
        frameLines(gb, rp, at(b, knob), pens[sc.BACKGROUNDPEN]);
        const fill = if (g.flags & gc.GFLG_SELECTED != 0) pens[sc.FILLPEN] else pens[sc.BLOCKPEN];
        support.fill(gb, rp, .{ .left = b.left + knob.left + border, .top = b.top + knob.top + border, .width = knob.width - 2 * border, .height = knob.height - 2 * border }, fill);
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// Drawn again, if it is in a window.
fn redraw(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo, whole: bool) void {
    const info = gi orelse return;
    const ib = base.intuition_base;
    const rp = ib.ObtainGIRPort(gi) orelse return;
    defer ib.ReleaseGIRPort(rp);
    draw(base, own, o, rp, info, whole);
}

fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, final: bool) void {
    const tags = [_]TagItem{
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{ .tag = gs.GRAD_CurVal, .data = @intCast(own.current) },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, if (final) 0 else classusr.OPUF_INTERIM);
}

// --- attributes ---------------------------------------------------------------

/// The attributes among `tags`: whether anything that shows changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool) bool {
    const ub = base.utility_base;
    const was_current = own.current;
    const was_max = own.max;
    var pens_changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        const value: i32 = @truncate(@as(isize, @bitCast(item.data)));
        switch (item.tag) {
            pg.PGA_Freedom => if (new) {
                own.vertical = @intFromBool(item.data & pg.FREEVERT != 0);
            },
            gs.GRAD_MaxVal => {
                own.max = value;
                own.current = @max(0, @min(own.current, own.max));
            },
            gs.GRAD_CurVal => own.current = @max(0, @min(value, own.max)),
            gs.GRAD_SkipVal => own.skip = value,
            gs.GRAD_KnobPixels => if (new) {
                own.knob_pixels = @max(value, 1);
            },
            gs.GRAD_PenArray => {
                // Given again, the colours may have changed in place: the
                // gradient is worked out anew.
                own.picture_pens = null;
                own.pens = @ptrFromInt(item.data);
                own.pen_count = 0;
                if (own.pens) |pens| {
                    while (pens[own.pen_count] != gs.GRAD_PEN_END) own.pen_count += 1;
                }
                pens_changed = true;
            },
            else => {},
        }
    }
    return pens_changed or own.current != was_current or own.max != was_max;
}

// --- input ----------------------------------------------------------------------

fn handle(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput, active: bool) usize {
    const g = gc.gadget(o);
    const layout = layoutOf(own, o, in.gadget_info);
    const was_selected = g.flags & gc.GFLG_SELECTED != 0;
    const was_current = own.current;
    const was_pos = layout.pos;
    var result: usize = gc.GMR_MEACTIVE;
    var value = own.current;

    if (!active) {
        // The press: beside the knob a skip, on it a hold.
        own.saved = own.current;
        const inset: i32 = if (own.vertical != 0) inset_h else inset_w;
        const mouse = if (own.vertical != 0) in.mouse.y else in.mouse.x;
        if (mouse - inset + knob_slop < layout.pos) {
            value -= own.skip;
            result = gc.GMR_NOREUSE | gc.GMR_VERIFY;
        } else if (mouse - inset - knob_slop >= layout.pos + layout.span) {
            value += own.skip;
            result = gc.GMR_NOREUSE | gc.GMR_VERIFY;
        } else {
            own.mouse_offset = mouse - layout.pos;
            g.flags |= gc.GFLG_SELECTED;
        }
    } else if (in.event) |e| {
        if (e.class == ie.IECLASS_NEWPOINTERPOS) {
            if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
                g.flags &= ~gc.GFLG_SELECTED;
                result = gc.GMR_NOREUSE | gc.GMR_VERIFY;
            } else if (e.code == ie.IECODE_RBUTTON) {
                // The menu button: back as it was.
                value = own.saved;
                g.flags &= ~gc.GFLG_SELECTED;
                result = gc.GMR_NOREUSE | gc.GMR_VERIFY;
            } else if (g.flags & gc.GFLG_SELECTED != 0) {
                value = valueAt(own, layout, if (own.vertical != 0) in.mouse.y else in.mouse.x);
            }
        }
    }
    own.current = @max(0, @min(value, own.max));

    const moved = own.current != was_current;
    const after = layoutOf(own, o, in.gadget_info);
    if (moved and after.pos != was_pos or (g.flags & gc.GFLG_SELECTED != 0) != was_selected) redraw(base, own, o, in.gadget_info, false);
    const final = result != gc.GMR_MEACTIVE;
    if (moved or final) tell(base, own, o, in.gadget_info, final);
    return result;
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
            own.* = .{};
            _ = setAttrs(base, own, new.attr_list, true);
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags) orelse {
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            };
            const ub = base.utility_base;
            own.sized = @intFromBool(ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null);
            const across: usize = if (own.vertical != 0) nominal_thickness else nominal_length;
            const down: usize = if (own.vertical != 0) nominal_length else nominal_thickness;
            const tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = if (own.sized != 0) utility.TAG_DONE else gc.GA_Width, .data = across },
                .{ .tag = gc.GA_Height, .data = down },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            if (own.picture) |picture| base.sys_base.FreeVec(picture);
            ib.DisposeObject(own.frame);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, own, set.attr_list, false)) changed = 1;
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                redraw(base, own, o.?, set.gadget_info, true);
                return 0;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                gs.GRAD_CurVal => get.storage.* = @intCast(own.current),
                gs.GRAD_MaxVal => get.storage.* = @intCast(own.max),
                gs.GRAD_SkipVal => get.storage.* = @intCast(own.skip),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        // Long and thin: as it was made, or else the nominal size; as long
        // as there is room at the most.
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const g = gc.gadget(o.?);
            const thickness: i32 = if (own.sized != 0) (if (own.vertical != 0) g.given_width else g.given_height) else nominal_thickness;
            const length: i32 = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => 2 * inset_w + own.knob_pixels + 8,
                gc.GDOMAIN_NOMINAL => if (own.sized != 0) (if (own.vertical != 0) g.given_height else g.given_width) else nominal_length,
                else => gc.GDOMAIN_UNLIMITED,
            };
            ask.domain = if (own.vertical != 0) .{ .width = thickness, .height = length } else .{ .width = length, .height = thickness };
            return 1;
        },
        gc.GM_HITTEST => return gc.GMR_GADGETHIT,
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            const info = r.gadget_info orelse return 0;
            draw(base, classes.instData(Data, cl, o.?), o.?, r.rast_port, info, r.redraw == gc.GREDRAW_REDRAW);
            return 0;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            return handle(base, classes.instData(Data, cl, o.?), o.?, in, false);
        },
        gc.GM_HANDLEINPUT => return handle(base, classes.instData(Data, cl, o.?), o.?, @ptrCast(@alignCast(msg)), true),
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const g = gc.gadget(o.?);
            if (g.flags & gc.GFLG_SELECTED != 0) {
                g.flags &= ~gc.GFLG_SELECTED;
                redraw(base, own, o.?, gone.gadget_info, false);
            }
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
