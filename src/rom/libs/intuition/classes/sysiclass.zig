// SPDX-License-Identifier: MPL-2.0
//! sysiclass: the system's own images - what goes on a window's border
//! gadgets.
//!
//! Each image is a list of vectors - filled and outlined rectangles and
//! polygons, each in one of the screen's pens and for some of the three
//! states (normal, selected, in an inactive window) - on a design grid:
//! close 20 by 11, depth and zoom 24 by 11, size 18 by 10. The vectors are
//! scaled to the size the image is asked to be, so the gadgets fit a
//! border whatever height a font makes it.
//!
//! An image is drawn once per state into a bitmap of its own - the ground
//! (the fill pen in an active border, the background pen in an inactive
//! one), the vectors, and the image's edge - and blitted from there each
//! time it is drawn. So drawing it costs a blit, and the polygon fills
//! work in a RastPort of the image's own rather than borrowing the
//! caller's.
//!
//! Two more are for menus: the tick a checked item shows (`MENUCHECK`,
//! 15 by 8) and the Amiga key before an item's shortcut (`AMIGAKEY`, on a
//! 45 by 15 grid, 23 by 8 unless asked otherwise; a screen asks for sizes
//! that follow its font), drawn in the bar pens
//! on the panel's ground with no edge.
//!
//! The edge follows where the image sits: raised on its own for the size
//! gadget in the corner; for close, at the left of the title bar, raised
//! with a line of shine down its right side where the bar begins; for
//! depth and zoom, at the right, with a line of shadow down its left side,
//! and placed one pixel into the bar's groove.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const ic = intuition.imageclass;
const sc = intuition.screens;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const d = @import("draw.zig");

// --- the vectors ------------------------------------------------------------------

/// The three states an image is drawn for.
const NORMAL = 0;
const SELECTED = 1;
const INACTIVE = 2;
const S_N: u8 = 1 << NORMAL;
const S_S: u8 = 1 << SELECTED;
const S_I: u8 = 1 << INACTIVE;

const Shape = enum { fill_rect, line_rect, fill_poly, line_poly };

/// One vector: a shape, the pen it is in, the states it is drawn for, and
/// its points on the design grid - rectangles as x1,y1,x2,y2 corners
/// (both included), polygons as x,y pairs.
const Vector = struct {
    shape: Shape,
    pen: usize,
    states: u8,
    points: []const u8,
};

/// Where the image sits, which decides its edge: a border gadget's, or
/// none for one on a menu panel.
const Edge = enum { left_of_bar, right_of_bar, corner, in_menu, in_screen_bar };

const Design = struct {
    /// The grid the vectors are on.
    width: i32,
    height: i32,
    edge: Edge,
    vectors: []const Vector,
    /// How big it is when nothing says otherwise, when that is not the
    /// grid's size.
    natural_width: i32 = 0,
    natural_height: i32 = 0,
};

const wdepth1 = [_]u8{ 5, 2, 15, 6 };
const wdepth2 = [_]u8{ 5, 2, 15, 2, 15, 4, 9, 4, 9, 6, 5, 6, 5, 2 };
const wdepth3 = [_]u8{ 9, 4, 19, 8 };
const wzoom1 = [_]u8{ 7, 2, 11, 5 };
const wzoom2 = [_]u8{ 6, 2, 18, 8, 6, 2, 12, 5, 7, 2, 11, 5 };
const wclose1 = [_]u8{ 7, 3, 11, 7 };
const sdepth1 = [_]u8{ 4, 2, 14, 6 };
const sdepth2 = [_]u8{ 4, 2, 14, 2, 14, 4, 8, 4, 8, 6, 4, 6, 4, 2 };
const sdepth3 = [_]u8{ 8, 4, 18, 8 };
const wsize1 = [_]u8{ 4, 7, 14, 7, 14, 2, 13, 2, 4, 6, 4, 7 };
const mcheck1 = [_]u8{ 14, 0, 12, 0, 6, 6, 5, 6, 3, 4, 0, 4, 1, 4, 4, 7, 6, 7, 13, 0 };
const mamiga1 = [_]u8{ 6, 0, 38, 0, 44, 2, 44, 12, 38, 14, 6, 14, 0, 12, 0, 2, 6, 0 };
const mamiga2 = [_]u8{ 16, 12, 16, 11, 12, 11, 28, 3, 30, 3, 30, 11, 28, 11, 28, 12, 38, 12, 38, 11, 34, 11, 34, 2, 27, 2, 9, 11, 6, 11, 6, 12, 16, 12 };
const mamiga3 = [_]u8{ 14, 9, 30, 10 };

const depth_design = Design{ .width = 24, .height = 11, .edge = .right_of_bar, .vectors = &.{
    .{ .shape = .fill_rect, .pen = sc.BACKGROUNDPEN, .states = S_N | S_S, .points = &wdepth1 },
    .{ .shape = .line_poly, .pen = sc.SHADOWPEN, .states = S_N | S_S | S_I, .points = &wdepth2 },
    .{ .shape = .fill_rect, .pen = sc.SHINEPEN, .states = S_N | S_S, .points = &wdepth3 },
    .{ .shape = .line_rect, .pen = sc.SHADOWPEN, .states = S_N | S_S | S_I, .points = &wdepth3 },
    .{ .shape = .line_rect, .pen = sc.SHADOWPEN, .states = S_S, .points = &wdepth1 },
} };
// A screen's depth gadget: the screen behind outlined, the one in front
// filled, on the background pen in a box of its own.
const sdepth_design = Design{ .width = 23, .height = 11, .edge = .in_screen_bar, .vectors = &.{
    .{ .shape = .line_poly, .pen = sc.SHADOWPEN, .states = S_N | S_S | S_I, .points = &sdepth2 },
    .{ .shape = .fill_rect, .pen = sc.SHINEPEN, .states = S_N | S_S, .points = &sdepth3 },
    .{ .shape = .line_rect, .pen = sc.SHADOWPEN, .states = S_N | S_S | S_I, .points = &sdepth3 },
    .{ .shape = .line_rect, .pen = sc.SHADOWPEN, .states = S_S, .points = &sdepth1 },
} };
const zoom_design = Design{ .width = 24, .height = 11, .edge = .right_of_bar, .vectors = &.{
    .{ .shape = .fill_rect, .pen = sc.SHINEPEN, .states = S_N, .points = &wzoom1 },
    .{ .shape = .fill_rect, .pen = sc.SHINEPEN, .states = S_S, .points = &wzoom2 },
    .{ .shape = .fill_rect, .pen = sc.FILLPEN, .states = S_S, .points = &wzoom1 },
    .{ .shape = .line_rect, .pen = sc.SHADOWPEN, .states = S_N | S_S | S_I, .points = &wzoom2 },
} };
const close_design = Design{ .width = 20, .height = 11, .edge = .left_of_bar, .vectors = &.{
    .{ .shape = .fill_rect, .pen = sc.SHINEPEN, .states = S_N, .points = &wclose1 },
    .{ .shape = .fill_rect, .pen = sc.BACKGROUNDPEN, .states = S_S, .points = &wclose1 },
    .{ .shape = .line_rect, .pen = sc.SHADOWPEN, .states = S_N | S_S | S_I, .points = &wclose1 },
} };
const size_design = Design{ .width = 18, .height = 10, .edge = .corner, .vectors = &.{
    .{ .shape = .fill_poly, .pen = sc.SHINEPEN, .states = S_N | S_S, .points = &wsize1 },
    .{ .shape = .line_poly, .pen = sc.SHADOWPEN, .states = S_N | S_S | S_I, .points = &wsize1 },
} };

// The two a menu panel shows, on the panel's own ground. Both are drawn
// the same whatever the state: a panel has no pressed or inactive look.
const S_ALL = S_N | S_S | S_I;
const menucheck_design = Design{ .width = 15, .height = 8, .edge = .in_menu, .vectors = &.{
    .{ .shape = .fill_poly, .pen = sc.BARDETAILPEN, .states = S_ALL, .points = &mcheck1 },
} };
const amigakey_design = Design{ .width = 45, .height = 15, .edge = .in_menu, .natural_width = 23, .natural_height = 8, .vectors = &.{
    .{ .shape = .fill_poly, .pen = sc.BARDETAILPEN, .states = S_ALL, .points = &mamiga1 },
    .{ .shape = .fill_poly, .pen = sc.BARBLOCKPEN, .states = S_ALL, .points = &mamiga2 },
    .{ .shape = .fill_rect, .pen = sc.BARBLOCKPEN, .states = S_ALL, .points = &mamiga3 },
} };

fn designOf(which: u32) ?*const Design {
    return switch (which) {
        ic.DEPTHIMAGE => &depth_design,
        ic.ZOOMIMAGE => &zoom_design,
        ic.SIZEIMAGE => &size_design,
        ic.CLOSEIMAGE => &close_design,
        ic.SDEPTHIMAGE => &sdepth_design,
        ic.MENUCHECK => &menucheck_design,
        ic.AMIGAKEY => &amigakey_design,
        else => null,
    };
}

/// A design coordinate at the size drawn, rounded to the nearest.
fn scale(design: i32, size: i32, c: i32) i32 {
    return @divTrunc(@divTrunc(design - 1, 2) + (size - 1) * c, design - 1);
}

// --- the class --------------------------------------------------------------------

/// `which` before SYSIA_Which says: no image at all.
const no_image: u32 = ~@as(u32, 0);

/// sysiclass's part of an object.
pub const Data = extern struct {
    /// SYSIA_Which. None until it is given: an image made without saying
    /// which is refused, as one this class has no design for is.
    which: u32 = no_image,
    /// SYSIA_DrawInfo, or null for the default pens.
    draw_info: ?*sc.DrawInfo = null,
    /// SYSIA_Pens: pens of its own, in place of the DrawInfo's.
    pens: ?[*]const Pen = null,
    /// Each state as drawn, at `drawn_width` by `drawn_height`; null until
    /// it is first wanted.
    drawn: [3]?*rtg.Surface = .{ null, null, null },
    drawn_width: i32 = 0,
    drawn_height: i32 = 0,
};

/// Make sysiclass, from imageclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.SYSICLASS, classusr.IMAGECLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

fn move(gb: *GraphicsBase, rp: *graphics.RastPort, x: i32, y: i32) void {
    gb.Move(rp, x, y);
}

/// The edge of a box `w` by `h` at `tx`: shine along the top and left and
/// shadow along the bottom and right when raised, the other way round
/// when pressed.
fn edge3d(gb: *GraphicsBase, rp: *graphics.RastPort, pens: [*]const Pen, raised: bool, tx: i32, w: i32, h: i32) void {
    const upper = if (raised) pens[sc.SHINEPEN] else pens[sc.SHADOWPEN];
    const lower = if (raised) pens[sc.SHADOWPEN] else pens[sc.SHINEPEN];
    d.pen(gb, rp, upper);
    gb.Move(rp, tx + w - 1, 0);
    gb.Draw(rp, tx, 0);
    gb.Draw(rp, tx, h - 2);
    d.pen(gb, rp, lower);
    gb.Move(rp, tx, h - 1);
    gb.Draw(rp, tx + w - 1, h - 1);
    gb.Draw(rp, tx + w - 1, 1);
}

fn dot(gb: *GraphicsBase, rp: *graphics.RastPort, value: Pen, x: i32, y: i32) void {
    d.pen(gb, rp, value);
    gb.WritePixel(rp, x, y);
}

fn line(gb: *GraphicsBase, rp: *graphics.RastPort, value: Pen, x: i32, y0: i32, y1: i32) void {
    d.pen(gb, rp, value);
    gb.Move(rp, x, y0);
    gb.Draw(rp, x, y1);
}

/// One state of a design, drawn at `w` by `h` into `rp`, whose room for
/// filled shapes the caller has made.
fn render(gb: *GraphicsBase, rp: *graphics.RastPort, design: *const Design, state: usize, w: i32, h: i32, pens: [*]const Pen) void {
    // The ground: a menu panel's own for an image on one; the background
    // pen for one in a box of its own - a screen's depth gadget - and in an
    // inactive window border; the fill pen in an active one.
    const ground = if (design.edge == .in_menu)
        pens[sc.BARBLOCKPEN]
    else if (design.edge == .in_screen_bar or state == INACTIVE)
        pens[sc.BACKGROUNDPEN]
    else
        pens[sc.FILLPEN];
    d.box(gb, rp, 0, 0, w, h, ground);

    const mask: u8 = @as(u8, 1) << @intCast(state);
    for (design.vectors) |v| {
        if (v.states & mask == 0) continue;
        d.pen(gb, rp, pens[v.pen]);
        const p = v.points;
        switch (v.shape) {
            .fill_rect, .line_rect => {
                var i: usize = 0;
                while (i + 3 < p.len) : (i += 4) {
                    const r = graphics.Rect{
                        .min_x = scale(design.width, w, p[i]),
                        .min_y = scale(design.height, h, p[i + 1]),
                        .max_x = scale(design.width, w, p[i + 2]) + 1,
                        .max_y = scale(design.height, h, p[i + 3]) + 1,
                    };
                    if (v.shape == .fill_rect) gb.RectFill(rp, &r) else gb.DrawRect(rp, &r);
                }
            },
            .fill_poly => {
                _ = gb.AreaMove(rp, scale(design.width, w, p[0]), scale(design.height, h, p[1]));
                var i: usize = 2;
                while (i + 1 < p.len) : (i += 2) {
                    _ = gb.AreaDraw(rp, scale(design.width, w, p[i]), scale(design.height, h, p[i + 1]));
                }
                _ = gb.AreaEnd(rp);
            },
            .line_poly => {
                gb.Move(rp, scale(design.width, w, p[0]), scale(design.height, h, p[1]));
                var i: usize = 2;
                while (i + 1 < p.len) : (i += 2) {
                    gb.Draw(rp, scale(design.width, w, p[i]), scale(design.height, h, p[i + 1]));
                }
            },
        }
    }

    // The edge, by where the image sits.
    const raised = state != SELECTED;
    switch (design.edge) {
        .in_menu => {},
        .in_screen_bar => edge3d(gb, rp, pens, raised, 0, w, h),
        .corner => {
            edge3d(gb, rp, pens, raised, 0, w, h);
            dot(gb, rp, pens[sc.SHADOWPEN], w - 1, 0);
        },
        .left_of_bar => {
            edge3d(gb, rp, pens, raised, 0, w - 1, h);
            dot(gb, rp, pens[sc.SHINEPEN], 0, h - 1);
            // The bar begins to its right: a line of shine, with the
            // window's border carried on at its ends.
            line(gb, rp, pens[sc.SHINEPEN], w - 1, 1, h - 2);
            dot(gb, rp, pens[sc.SHINEPEN], w - 1, 0);
            dot(gb, rp, pens[sc.SHADOWPEN], w - 1, h - 1);
        },
        .right_of_bar => {
            edge3d(gb, rp, pens, raised, 1, w - 1, h);
            // The bar ends to its left: a line of shadow.
            line(gb, rp, pens[sc.SHADOWPEN], 0, 1, h - 2);
            dot(gb, rp, pens[sc.SHINEPEN], 0, 0);
            dot(gb, rp, pens[sc.SHADOWPEN], 0, h - 1);
        },
    }
}

/// Every state drawn gone, so the next draw starts again.
fn forget(ib: *IntuitionBase, sd: *Data) void {
    for (&sd.drawn) |*s| {
        ib.graphics_base.FreeBitMap(s.*);
        s.* = null;
    }
}

/// A state of the image as a bitmap in the destination's format, drawn if
/// it is not yet or the image's size has changed. Null without memory.
fn stateImage(ib: *IntuitionBase, sd: *Data, design: *const Design, state: usize, w: i32, h: i32, friend: *graphics.RastPort, dri: ?*sc.DrawInfo) ?*rtg.Surface {
    const gb = ib.graphics_base;
    if (sd.drawn_width != w or sd.drawn_height != h) {
        forget(ib, sd);
        sd.drawn_width = w;
        sd.drawn_height = h;
    }
    if (sd.drawn[state]) |s| return s;

    const tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = @intCast(w) },
        .{ .tag = graphics.BMTAG_Height, .data = @intCast(h) },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(friend) },
        .{},
    };
    const surface = gb.AllocBitMapTagList(&tags) orelse return null;
    const on = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) }, .{} };
    const rp = gb.CreateRastPortTagList(&on) orelse {
        gb.FreeBitMap(surface);
        return null;
    };
    defer gb.FreeRastPort(rp);
    // Room for the largest filled polygon of any design, and a margin.
    if (!gb.InitArea(rp, 20)) {
        gb.FreeBitMap(surface);
        return null;
    }
    render(gb, rp, design, state, w, h, sd.pens orelse d.pensOf(dri));
    _ = gb.InitArea(rp, 0);
    sd.drawn[state] = surface;
    return surface;
}

fn draw(ib: *IntuitionBase, cl: *Class, o: *Object, msg: *ic.ImpDraw) usize {
    const sd = classes.instData(Data, cl, o);
    const im = classes.instData(ic.Image, cl.super.?, o);
    // OM_NEW refused anything with no design, so there is one.
    const design = designOf(sd.which) orelse return 0;
    if (im.width < 4 or im.height < 4) return 0;
    const state: usize = switch (msg.state) {
        ic.IDS_SELECTED, ic.IDS_INACTIVESELECTED => SELECTED,
        ic.IDS_INACTIVENORMAL, ic.IDS_INACTIVEDISABLED => INACTIVE,
        else => NORMAL,
    };
    // Nowhere to prepare it: say so rather than report a picture that was
    // never put down.
    const image = stateImage(ib, sd, design, state, im.width, im.height, msg.rast_port, sd.draw_info orelse msg.draw_info) orelse return 0;
    ib.graphics_base.BltBitMapRastPort(image, 0, 0, msg.rast_port, im.left + msg.offset.x, im.top + msg.offset.y, im.width, im.height);
    return 1;
}

fn setAttrs(ib: *IntuitionBase, sd: *Data, tags: ?[*]const TagItem) void {
    const ub = ib.utility_base;
    sd.which = @intCast(ub.GetTagData(ic.SYSIA_Which, sd.which, tags));
    if (ub.FindTagItem(ic.SYSIA_DrawInfo, tags)) |item| sd.draw_info = @ptrFromInt(item.data);
    if (ub.FindTagItem(ic.SYSIA_Pens, tags)) |item| sd.pens = @ptrFromInt(item.data);
    // New pens or a new image: what was drawn is out of date.
    forget(ib, sd);
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
            const obj: *Object = @ptrFromInt(made);
            const sd = classes.instData(Data, cl, obj);
            sd.* = .{};
            setAttrs(ib, sd, new.attr_list);

            // An image this class has no design for is one it could only
            // draw as nothing, so it refuses to be made at all. A caller
            // hears that it asked for something that is not here; the
            // alternative is an object that answers every call and leaves
            // the display blank.
            const design = designOf(sd.which) orelse {
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = it.SendSuperMessage(cl, obj, &gone);
                return 0;
            };

            const im = classes.instData(ic.Image, cl.super.?, obj);
            // How big it is, unless the caller said: a system image has a
            // size of its own, which is what makes it that image rather
            // than a stretched copy of it.
            const ub = ib.utility_base;
            if (ub.FindTagItem(ic.IA_Width, new.attr_list) == null) im.width = if (design.natural_width != 0) design.natural_width else design.width;
            if (ub.FindTagItem(ic.IA_Height, new.attr_list) == null) im.height = if (design.natural_height != 0) design.natural_height else design.height;
            // Depth and zoom reach one pixel into the title bar's groove.
            if (sd.which == ic.DEPTHIMAGE or sd.which == ic.ZOOMIMAGE) im.left = -1;
            return made;
        },
        classusr.OM_SET => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            setAttrs(ib, classes.instData(Data, cl, o orelse return 0), set.attr_list);
            return it.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_DISPOSE => {
            forget(ib, classes.instData(Data, cl, o orelse return 0));
            return it.SendSuperMessage(cl, o, msg);
        },
        ic.IM_DRAW, ic.IM_DRAWFRAME => return draw(ib, cl, o orelse return 0, @ptrCast(@alignCast(msg))),
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
