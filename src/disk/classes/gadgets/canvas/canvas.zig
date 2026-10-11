// SPDX-License-Identifier: MIT
//! canvas.gadget: a bitmap a program draws into, shown by the gadget.
//!
//! `OM_NEW` makes the bitmap (`AllocBitMapTagList`, cleared, in the
//! display's format) and a RastPort onto it; `OM_DISPOSE` frees both.
//! `GM_RENDER` puts the bitmap into the gadget's box in one move
//! (`BltBitMapRastPort`), cut to the box, and fills what the picture does
//! not cover with the background. A program's drawing reaches the window
//! when the gadget is next drawn, which `QueueGadgetRefresh` asks for.
//!
//! A press goes active and every move after it, and the release, tell the
//! target the pointer's place in the picture.
//!
//! `OM_SET` of `CANVAS_Width` or `CANVAS_Height` makes the picture anew at
//! the new size (0: the gadget's box, from the GadgetInfo when there is
//! one): a new bitmap, what fits of the old picture blitted into it and
//! the rest cleared, and a new RastPort that draws as the old one did - its
//! font, pens, draw mode and style. The old ones go at once, which is safe
//! from intuition's drawing because `SetGadgetAttrsTagList` and every
//! `GM_RENDER` intuition sends hold intuition's lock; the program, which
//! draws without one, is the one that asked, and reads the new RastPort
//! after. What the gadget asks a layout for (`GM_DOMAIN`) stays the size
//! it was made with, so following its box never makes it ask for more.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const style = intuition.style;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const cv = gadgets.canvas;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = cv.CANVAS_CLASS,
    .version = 2,
    .date = "11.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// canvas.gadget's part of an object.
pub const Data = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    /// The size it was made with: what it asks a layout for.
    nominal_width: u32 = 0,
    nominal_height: u32 = 0,
    bitmap: ?*sdk.rtg.Surface = null,
    rast_port: ?*graphics.RastPort = null,
    /// Where the pointer was last told to be.
    last_x: i32 = 0,
    last_y: i32 = 0,
};

const default_width = 160;
const default_height = 120;

/// A bitmap of `width` by `height` in the display's format, cleared, and
/// a RastPort onto it; null with no memory.
fn makePicture(gb: *GraphicsBase, width: u32, height: u32) ?struct { bitmap: *sdk.rtg.Surface, rast_port: *graphics.RastPort } {
    const bitmap = gb.AllocBitMapTagList(&[_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = width },
        .{ .tag = graphics.BMTAG_Height, .data = height },
        .{ .tag = graphics.BMTAG_Clear, .data = 1 },
        .{},
    }) orelse return null;
    const rast_port = gb.CreateRastPortTagList(&[_]TagItem{ .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(bitmap) }, .{} }) orelse {
        gb.FreeBitMap(bitmap);
        return null;
    };
    return .{ .bitmap = bitmap, .rast_port = rast_port };
}

/// The picture made anew at `width` by `height`, what fits of the old one
/// kept and its RastPort's font, pens, draw mode and style carried over.
/// False with no memory: the picture stays as it was.
fn resize(gb: *GraphicsBase, own: *Data, width: u32, height: u32) bool {
    if (width == own.width and height == own.height) return true;
    const picture = makePicture(gb, width, height) orelse return false;
    if (own.bitmap) |old| {
        _ = gb.BltBitMap(old, 0, 0, picture.bitmap, 0, 0, @intCast(@min(width, own.width)), @intCast(@min(height, own.height)));
    }
    if (own.rast_port) |old| {
        var font: usize = 0;
        var front: u32 = 0;
        var back: u32 = 0;
        var mode: u32 = 0;
        var text_style: u32 = 0;
        gb.GetRPAttrs(old, &[_]TagItem{
            .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&font) },
            .{ .tag = graphics.RPTAG_APen, .data = @intFromPtr(&front) },
            .{ .tag = graphics.RPTAG_BPen, .data = @intFromPtr(&back) },
            .{ .tag = graphics.RPTAG_DrMd, .data = @intFromPtr(&mode) },
            .{ .tag = graphics.RPTAG_TextStyle, .data = @intFromPtr(&text_style) },
            .{},
        });
        gb.SetRPAttrs(picture.rast_port, &[_]TagItem{
            .{ .tag = graphics.RPTAG_Font, .data = font },
            .{ .tag = graphics.RPTAG_APen, .data = front },
            .{ .tag = graphics.RPTAG_BPen, .data = back },
            .{ .tag = graphics.RPTAG_DrMd, .data = mode },
            .{ .tag = graphics.RPTAG_TextStyle, .data = text_style },
            .{},
        });
        gb.FreeRastPort(old);
    }
    if (own.bitmap) |old| gb.FreeBitMap(old);
    own.bitmap = picture.bitmap;
    own.rast_port = picture.rast_port;
    own.width = width;
    own.height = height;
    return true;
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const own = classes.instData(Data, cl, o);
    const g = gc.gadget(o);
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    const b = gc.boxFor(g, info);
    const ground = support.background(base.intuition_base, info.draw_info, g.style, style.PART_MAIN);
    const shown_w: i32 = @min(@as(i32, @intCast(own.width)), b.width);
    const shown_h: i32 = @min(@as(i32, @intCast(own.height)), b.height);
    if (own.bitmap) |bitmap| {
        gb.BltBitMapRastPort(bitmap, 0, 0, rp, b.left, b.top, shown_w, shown_h);
    } else {
        support.fill(gb, rp, .{ .left = b.left, .top = b.top, .width = shown_w, .height = shown_h }, ground);
    }
    if (shown_w < b.width) support.fill(gb, rp, .{ .left = b.left + shown_w, .top = b.top, .width = b.width - shown_w, .height = b.height }, ground);
    if (shown_h < b.height) support.fill(gb, rp, .{ .left = b.left, .top = b.top + shown_h, .width = shown_w, .height = b.height - shown_h }, ground);
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// The target told where the pointer is in the picture, and the place
/// kept to be read.
fn tell(base: *gadgets.Base, own: *Data, o: *Object, in: *const gc.GpInput, flags: u32) void {
    own.last_x = in.mouse.x;
    own.last_y = in.mouse.y;
    const tags = [_]TagItem{
        .{ .tag = cv.CANVAS_X, .data = @bitCast(@as(isize, in.mouse.x)) },
        .{ .tag = cv.CANVAS_Y, .data = @bitCast(@as(isize, in.mouse.y)) },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, in.gadget_info, &tags, flags);
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const gb = base.graphics_base;
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
            const ub = base.utility_base;
            const given_w: u32 = if (ub.FindTagItem(gc.GA_Width, new.attr_list)) |item| @truncate(item.data) else default_width;
            const given_h: u32 = if (ub.FindTagItem(gc.GA_Height, new.attr_list)) |item| @truncate(item.data) else default_height;
            // 0, as left out: the gadget's own size.
            const asked_w: u32 = @truncate(ub.GetTagData(cv.CANVAS_Width, 0, new.attr_list));
            const asked_h: u32 = @truncate(ub.GetTagData(cv.CANVAS_Height, 0, new.attr_list));
            own.width = @max(if (asked_w != 0) asked_w else given_w, 1);
            own.height = @max(if (asked_h != 0) asked_h else given_h, 1);
            own.nominal_width = own.width;
            own.nominal_height = own.height;
            if (makePicture(gb, own.width, own.height)) |picture| {
                own.bitmap = picture.bitmap;
                own.rast_port = picture.rast_port;
            }
            if (own.rast_port == null) {
                // No picture to hand out: the gadget is not made.
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendMessage(obj, &gone);
                return 0;
            }
            if (ub.FindTagItem(gc.GA_Width, new.attr_list) == null and ub.FindTagItem(gc.GA_Height, new.attr_list) == null) {
                const tags = [_]TagItem{
                    .{ .tag = gc.GA_Width, .data = own.width },
                    .{ .tag = gc.GA_Height, .data = own.height },
                    .{},
                };
                var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
                _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            }
            return made;
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const changed = ib.SendSuperMessage(cl, o, msg);
            const ub = base.utility_base;
            const width_item = ub.FindTagItem(cv.CANVAS_Width, set.attr_list);
            const height_item = ub.FindTagItem(cv.CANVAS_Height, set.attr_list);
            if (width_item == null and height_item == null) return changed;
            const own = classes.instData(Data, cl, o.?);
            // 0: the box the gadget has now.
            const g = gc.gadget(o.?);
            const box = if (set.gadget_info) |info| gc.boxFor(g, info) else gc.Box{ .width = g.width, .height = g.height };
            const width: u32 = if (width_item) |item| (if (item.data != 0) @truncate(item.data) else @intCast(@max(box.width, 1))) else own.width;
            const height: u32 = if (height_item) |item| (if (item.data != 0) @truncate(item.data) else @intCast(@max(box.height, 1))) else own.height;
            if (!resize(gb, own, width, height)) return changed;
            ib.QueueGadgetRefresh(o.?);
            return changed;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            if (own.rast_port) |rp| gb.FreeRastPort(rp);
            if (own.bitmap) |bitmap| gb.FreeBitMap(bitmap);
            own.rast_port = null;
            own.bitmap = null;
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                cv.CANVAS_RastPort => get.storage.* = @intFromPtr(own.rast_port),
                cv.CANVAS_BitMap => get.storage.* = @intFromPtr(own.bitmap),
                cv.CANVAS_Width => get.storage.* = own.width,
                cv.CANVAS_Height => get.storage.* = own.height,
                cv.CANVAS_X => get.storage.* = @bitCast(@as(isize, own.last_x)),
                cv.CANVAS_Y => get.storage.* = @bitCast(@as(isize, own.last_y)),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            ask.domain = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => .{ .width = 16, .height = 16 },
                gc.GDOMAIN_NOMINAL => .{ .width = @intCast(own.nominal_width), .height = @intCast(own.nominal_height) },
                else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = gc.GDOMAIN_UNLIMITED },
            };
            return 1;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            tell(base, classes.instData(Data, cl, o.?), o.?, in, classusr.OPUF_INTERIM);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const e = in.event orelse return gc.GMR_MEACTIVE;
            if (e.class != ie.IECLASS_NEWPOINTERPOS) return gc.GMR_MEACTIVE;
            if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
                tell(base, classes.instData(Data, cl, o.?), o.?, in, 0);
                return gc.GMR_NOREUSE | gc.GMR_VERIFY;
            }
            tell(base, classes.instData(Data, cl, o.?), o.?, in, classusr.OPUF_INTERIM);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
