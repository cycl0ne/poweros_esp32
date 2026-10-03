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

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = cv.CANVAS_CLASS,
    .version = 1,
    .date = "02.10.2026",
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
    bitmap: ?*sdk.rtg.Surface = null,
    rast_port: ?*graphics.RastPort = null,
    /// Where the pointer was last told to be.
    last_x: i32 = 0,
    last_y: i32 = 0,
};

const default_width = 160;
const default_height = 120;

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
            own.width = @max(@as(u32, @truncate(ub.GetTagData(cv.CANVAS_Width, given_w, new.attr_list))), 1);
            own.height = @max(@as(u32, @truncate(ub.GetTagData(cv.CANVAS_Height, given_h, new.attr_list))), 1);
            own.bitmap = gb.AllocBitMapTagList(&[_]TagItem{
                .{ .tag = graphics.BMTAG_Width, .data = own.width },
                .{ .tag = graphics.BMTAG_Height, .data = own.height },
                .{ .tag = graphics.BMTAG_Clear, .data = 1 },
                .{},
            });
            if (own.bitmap) |bitmap| {
                own.rast_port = gb.CreateRastPortTagList(&[_]TagItem{ .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(bitmap) }, .{} });
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
                gc.GDOMAIN_NOMINAL => .{ .width = @intCast(own.width), .height = @intCast(own.height) },
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
