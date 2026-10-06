// SPDX-License-Identifier: MIT
//! picture.datatype: what every still picture is, whatever file it came
//! out of.
//!
//! A datatypesclass subclass, and a superclass only: nothing recognises
//! a file as a bare picture. A format's class - ilbm, bmp, png, gif,
//! jpeg - is a subclass of this one, reads its file in `OM_NEW` and
//! hands the rows over with `PDTM_WRITEPIXELARRAY`. From then on the
//! picture is this class's: it keeps it, says how big it is, draws it,
//! scrolls it, scales it and writes it out again.
//!
//! **The picture is kept as pens**, one `graphics.Pen` a pixel, whatever
//! the file held. The screens are true colour, so that is the one shape
//! `WritePixelArray` and its two companions take without converting
//! anything, and a picture converted once when it is read costs nothing
//! on every later redraw. What it costs is four bytes a pixel, so a
//! format class keeps a picture too large for memory smaller
//! (`subclass.shrinkFor`) rather than letting it fail half read.
//!
//! **A picture with coverage is drawn through `BlendPixelArray`** and
//! one without through `WritePixelArray`, and a scaled one through
//! `ScalePixelArray`, which honours coverage by the format it is given.
//! Which of them is used therefore follows from the source mode alone,
//! and the class holds no second copy of anything.
//!
//! The scroll units are pixels (`DTA_VertUnit` and `DTA_HorizUnit` 1),
//! so a scroller gadget driven from `DTA_TopVert` moves the picture a
//! pixel at a time.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const sc = intuition.screens;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const pixels = @import("pixels.zig");
const save = @import("save.zig");
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
///
/// datatypes.library is opened and held because datatypesclass, this
/// class's superclass, is made when that library is first opened and
/// goes with its last close; iffparse.library because `DTM_WRITE`
/// writes an IFF form.
pub const Library = gadgets.ClassLibrary(.{
    .name = pic.PICTUREDTCLASS,
    .version = 1,
    .date = "29.09.2026",
    .super = dtc.DATATYPESCLASS,
    .opens = &.{ datatypes.DATATYPESNAME, sdk.iffparse.IFFPARSENAME },
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// picture.datatype's part of an object.
pub const Data = extern struct {
    /// What the file said the picture is.
    bmh: pic.BitMapHeader = .{},
    /// The picture, one pen a pixel, `bytes_per_row` from one row to the
    /// next. Null until a subclass gives it a size.
    pens: ?[*]graphics.Pen = null,
    bytes_per_row: u32 = 0,
    /// How many pens there is room for, so that a size set twice frees
    /// what it replaces.
    pen_count: u32 = 0,
    /// The palette the file held, kept for writing it out again.
    palette: ?[*]pic.ColorRegister = null,
    num_colors: u32 = 0,
    /// The shape the file held, which is what it is written back as.
    source_mode: u32 = pic.PBPAFMT_RGB,
    /// Where the hot spot is, for a picture that is a pointer.
    grab: graphics.Point = .{},
    screen: ?*intuition.Screen = null,
    /// Drawn to fill the room it is given rather than at its own size.
    scale: u8 = 0,
    pad: [3]u8 = @splat(0),
    /// What the file said the picture was, and how much smaller than
    /// that it is kept. The same as the header's size, and 1, for a
    /// picture that fitted.
    source_width: u32 = 0,
    source_height: u32 = 0,
    shrunk_by: u32 = 1,
};

/// The surface format a kept picture is: a 0xAARRGGBB word stored to
/// memory on this chip is b, g, r, a.
pub const kept_format: u32 = @intFromEnum(sdk.rtg.bitmaps.PixelFormat.bgra32);

/// Whether what the file held carries coverage, which decides between
/// laying the picture down and mixing it in.
pub fn hasCoverage(own: *const Data) bool {
    return own.source_mode == pic.PBPAFMT_RGBA or own.source_mode == pic.PBPAFMT_ARGB or
        own.bmh.masking == pic.mskHasAlpha;
}

/// Room for a picture of the size the header says, and the old one given
/// back. False when there is no memory for it, and the object then has
/// no picture.
pub fn takeRoom(base: *Base, own: *Data) bool {
    const sys = base.sys_base;
    if (own.pens) |old| sys.FreeVec(old);
    own.pens = null;
    own.pen_count = 0;
    own.bytes_per_row = 0;
    const width: u32 = own.bmh.width;
    const height: u32 = own.bmh.height;
    if (width == 0 or height == 0) return false;
    const count = width * height;
    // Four bytes a pixel, and a picture whose size does not fit in a
    // word is one nothing here could hold anyway.
    if (count / width != height or count > (1 << 28)) return false;
    const memory = sys.AllocVec(count * @sizeOf(graphics.Pen), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse
        return false;
    own.pens = @ptrCast(@alignCast(memory));
    own.pen_count = count;
    own.bytes_per_row = width * @sizeOf(graphics.Pen);
    return true;
}

/// The palette copied, and the old one given back.
fn takePalette(base: *Base, own: *Data, from: ?[*]const pic.ColorRegister, count: u32) void {
    const sys = base.sys_base;
    if (own.palette) |old| sys.FreeVec(old);
    own.palette = null;
    own.num_colors = 0;
    const colors = from orelse return;
    if (count == 0) return;
    const memory = sys.AllocVec(count * @sizeOf(pic.ColorRegister), exec.MEMF_ANY) orelse return;
    const into: [*]pic.ColorRegister = @ptrCast(@alignCast(memory));
    @memcpy(into[0..count], colors[0..count]);
    own.palette = into;
    own.num_colors = count;
}

/// What the object tells its superclass about its size, once the header
/// is known: the picture's own size in units of one pixel.
fn tellSize(base: *Base, cl: *Class, o: *Object) void {
    const width: i32 = own_width(cl, o);
    const height: i32 = own_height(cl, o);
    const tags = [_]TagItem{
        .{ .tag = dtc.DTA_NominalHoriz, .data = @bitCast(@as(isize, width)) },
        .{ .tag = dtc.DTA_NominalVert, .data = @bitCast(@as(isize, height)) },
        .{ .tag = dtc.DTA_TotalHoriz, .data = @bitCast(@as(isize, width)) },
        .{ .tag = dtc.DTA_TotalVert, .data = @bitCast(@as(isize, height)) },
        .{ .tag = dtc.DTA_HorizUnit, .data = 1 },
        .{ .tag = dtc.DTA_VertUnit, .data = 1 },
        .{},
    };
    tellSuper(base, cl, o, &tags);
}

fn own_width(cl: *Class, o: *Object) i32 {
    return classes.instData(Data, cl, o).bmh.width;
}

fn own_height(cl: *Class, o: *Object) i32 {
    return classes.instData(Data, cl, o).bmh.height;
}

/// Attributes set on the superclass, which is how this class moves the
/// scroll numbers that live there.
pub fn tellSuper(base: *Base, cl: *Class, o: *Object, tags: [*]const TagItem) void {
    var set = classusr.OpSet{
        .method_id = classusr.OM_SET,
        .attr_list = tags,
        .gadget_info = null,
    };
    _ = base.intuition_base.SendSuperMessage(cl, o, @ptrCast(&set));
}

/// One of the superclass's numbers read back.
pub fn askSuper(base: *Base, cl: *Class, o: *Object, attr: utility.Tag) i32 {
    var storage: usize = 0;
    var get = classusr.OpGet{
        .method_id = classusr.OM_GET,
        .attr_id = attr,
        .storage = &storage,
    };
    if (base.intuition_base.SendSuperMessage(cl, o, @ptrCast(&get)) == 0) return 0;
    return @truncate(@as(isize, @bitCast(storage)));
}

/// The attributes among `tags` that are this class's. Whether the
/// picture's size changed, so that the caller tells the superclass.
fn setAttrs(base: *Base, own: *Data, tags: ?[*]const TagItem, new: bool) bool {
    const ub = base.utility_base;
    var resized = false;
    var colors: ?[*]const pic.ColorRegister = null;
    var color_count: u32 = own.num_colors;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            pic.PDTA_BitMapHeader => {
                const given: ?*const pic.BitMapHeader = @ptrFromInt(item.data);
                if (given) |header| {
                    own.bmh = header.*;
                    resized = true;
                }
            },
            pic.PDTA_ColorRegisters => colors = @ptrFromInt(item.data),
            pic.PDTA_NumColors => color_count = @truncate(item.data),
            pic.PDTA_SourceMode => own.source_mode = @truncate(item.data),
            pic.PDTA_Screen => own.screen = @ptrFromInt(item.data),
            pic.PDTA_Scale => own.scale = @intFromBool(item.data != 0),
            pic.PDTA_SourceWidth => own.source_width = @truncate(item.data),
            pic.PDTA_SourceHeight => own.source_height = @truncate(item.data),
            pic.PDTA_ShrunkBy => own.shrunk_by = @max(@as(u32, @truncate(item.data)), 1),
            pic.PDTA_Grab => {
                const point: ?*const graphics.Point = @ptrFromInt(item.data);
                if (point) |it| own.grab = it.*;
            },
            else => {},
        }
    }
    _ = new;
    // A picture that was not shrunk was read at the size the file said,
    // so that is what it came from.
    if (resized and own.source_width == 0) {
        own.source_width = own.bmh.width;
        own.source_height = own.bmh.height;
    }
    if (colors != null or color_count != own.num_colors) {
        takePalette(base, own, colors orelse own.palette, color_count);
    }
    return resized;
}

fn getAttr(own: *Data, attr: utility.Tag, storage: *usize) bool {
    storage.* = switch (attr) {
        pic.PDTA_BitMapHeader => @intFromPtr(&own.bmh),
        pic.PDTA_ColorRegisters => @intFromPtr(own.palette),
        pic.PDTA_NumColors => own.num_colors,
        pic.PDTA_SourceMode => own.source_mode,
        pic.PDTA_Screen => @intFromPtr(own.screen),
        pic.PDTA_Scale => own.scale,
        pic.PDTA_Grab => @intFromPtr(&own.grab),
        pic.PDTA_Pixels => @intFromPtr(own.pens),
        pic.PDTA_BytesPerRow => own.bytes_per_row,
        pic.PDTA_SourceWidth => if (own.source_width != 0) own.source_width else own.bmh.width,
        pic.PDTA_SourceHeight => if (own.source_height != 0) own.source_height else own.bmh.height,
        pic.PDTA_ShrunkBy => own.shrunk_by,
        else => return false,
    };
    return true;
}

// --- drawing ----------------------------------------------------------------

/// The picture put into `box`, scaled to fill it or laid down at its own
/// size from `left`, `top`. Whatever of the box the picture does not
/// cover is filled with `ground`.
pub fn paint(base: *Base, own: *Data, rp: *graphics.RastPort, box: gc.Box, left: i32, top: i32, ground: graphics.Pen) void {
    const gb = base.graphics_base;
    if (box.width <= 0 or box.height <= 0) return;
    const pens = own.pens orelse {
        gadgets.support.fill(gb, rp, box, ground);
        return;
    };
    const width: i32 = own.bmh.width;
    const height: i32 = own.bmh.height;
    const bytes: [*]const u8 = @ptrCast(pens);

    if (own.scale != 0) {
        const from = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = width, .max_y = height };
        const into = graphics.Rect{
            .min_x = box.left,
            .min_y = box.top,
            .max_x = box.left + box.width,
            .max_y = box.top + box.height,
        };
        gb.ScalePixelArray(rp, bytes, own.bytes_per_row, kept_format, &from, &into);
        return;
    }

    // At its own size: the part starting at (left, top), and the ground
    // wherever the picture runs out.
    //
    // The corner to start at is kept inside the picture. It is asked for
    // from outside - a bar beside the picture moves it, and the numbers
    // that bar works from are only as fresh as the last time the object
    // was laid out - so a corner past the end is a thing that happens,
    // and a picture that answered it by drawing nothing at all would
    // look like a window that had lost its contents.
    const from_x = @min(@max(left, 0), @max(width - box.width, 0));
    const from_y = @min(@max(top, 0), @max(height - box.height, 0));
    const shown_width = @max(@min(width - from_x, box.width), 0);
    const shown_height = @max(@min(height - from_y, box.height), 0);
    if (shown_width > 0 and shown_height > 0) {
        const area = graphics.Rect{
            .min_x = box.left,
            .min_y = box.top,
            .max_x = box.left + shown_width,
            .max_y = box.top + shown_height,
        };
        if (hasCoverage(own)) {
            gadgets.support.fill(gb, rp, .{ .left = box.left, .top = box.top, .width = shown_width, .height = shown_height }, ground);
            gb.BlendPixelArray(rp, bytes, own.bytes_per_row, kept_format, from_x, from_y, &area);
        } else {
            gb.WritePixelArray(rp, bytes, own.bytes_per_row, kept_format, from_x, from_y, &area);
        }
    }
    if (shown_width < box.width) {
        gadgets.support.fill(gb, rp, .{
            .left = box.left + shown_width,
            .top = box.top,
            .width = box.width - shown_width,
            .height = box.height,
        }, ground);
    }
    if (shown_height < box.height) {
        gadgets.support.fill(gb, rp, .{
            .left = box.left,
            .top = box.top + shown_height,
            .width = shown_width,
            .height = box.height - shown_height,
        }, ground);
    }
}

fn render(base: *Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const gb = base.graphics_base;
    const own = classes.instData(Data, cl, o);
    const saved = gadgets.support.Saved.of(gb, r.rast_port);
    defer saved.restore(gb, r.rast_port);
    const box = gc.boxFor(gc.gadget(o), info);
    paint(base, own, r.rast_port, box, askSuper(base, cl, o, dtc.DTA_TopHoriz), askSuper(base, cl, o, dtc.DTA_TopVert), gadgets.support.background(base.intuition_base, info.draw_info, gc.gadget(o).style, intuition.style.PART_MAIN));
}

/// How much of the picture is seen in the box it was given, which is
/// what a scroller round it reads.
fn layOut(base: *Base, cl: *Class, o: *Object, lay: *gc.GpLayout) void {
    const info = lay.gadget_info orelse return;
    const own = classes.instData(Data, cl, o);
    const box = gc.boxFor(gc.gadget(o), info);
    const width: i32 = own.bmh.width;
    const height: i32 = own.bmh.height;
    // Scaled, all of it is always seen, whatever size the box is.
    const seen_width = if (own.scale != 0) width else @min(box.width, width);
    const seen_height = if (own.scale != 0) height else @min(box.height, height);
    const top_horiz = @max(0, @min(askSuper(base, cl, o, dtc.DTA_TopHoriz), width - seen_width));
    const top_vert = @max(0, @min(askSuper(base, cl, o, dtc.DTA_TopVert), height - seen_height));
    const tags = [_]TagItem{
        .{ .tag = dtc.DTA_VisibleHoriz, .data = @bitCast(@as(isize, seen_width)) },
        .{ .tag = dtc.DTA_VisibleVert, .data = @bitCast(@as(isize, seen_height)) },
        .{ .tag = dtc.DTA_TopHoriz, .data = @bitCast(@as(isize, top_horiz)) },
        .{ .tag = dtc.DTA_TopVert, .data = @bitCast(@as(isize, top_vert)) },
        .{},
    };
    tellSuper(base, cl, o, &tags);
}

/// What the object needs of a display: its own size, in as much colour
/// as it has, and it can be scaled and scrolled.
fn frameBox(cl: *Class, o: *Object, frame: *dtc.DtFrameBox) void {
    const own = classes.instData(Data, cl, o);
    const want = frame.frame_info;
    want.* = frame.contents_info.*;
    want.width = own.bmh.width;
    want.height = own.bmh.height;
    want.depth = own.bmh.depth;
    want.red_bits = 8;
    want.green_bits = 8;
    want.blue_bits = 8;
    want.flags = dtc.FIF_SCALABLE | dtc.FIF_SCROLLABLE;
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
            if (setAttrs(base, own, new.attr_list, true)) {
                if (!takeRoom(base, own)) {
                    ib.DisposeObject(obj);
                    return 0;
                }
                tellSize(base, cl, obj);
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            const sys = base.sys_base;
            if (own.pens) |it| sys.FreeVec(it);
            if (own.palette) |it| sys.FreeVec(it);
            own.pens = null;
            own.palette = null;
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, own, set.attr_list, false)) {
                _ = takeRoom(base, own);
                tellSize(base, cl, o.?);
                changed = 1;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (getAttr(own, get.attr_id, get.storage)) return 1;
            return ib.SendSuperMessage(cl, o, msg);
        },
        pic.PDTM_WRITEPIXELARRAY => return pixels.write(base, cl, o.?, @ptrCast(@alignCast(msg))),
        pic.PDTM_READPIXELARRAY => return pixels.read(base, cl, o.?, @ptrCast(@alignCast(msg))),
        pic.PDTM_SCALE => {
            const ask: *pic.PdtScale = @ptrCast(@alignCast(msg));
            if (!pixels.scale(base, cl, o.?, ask.new_width, ask.new_height)) return 0;
            tellSize(base, cl, o.?);
            return 1;
        },
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        // A picture is looked at, not worked: a press goes through it to
        // the window, which is what lets a window object drag it.
        gc.GM_HITTEST => return 0,
        dtc.DTM_PROCLAYOUT, dtc.DTM_ASYNCLAYOUT => {
            layOut(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 1;
        },
        dtc.DTM_FRAMEBOX => {
            frameBox(cl, o.?, @ptrCast(@alignCast(msg)));
            return 1;
        },
        dtc.DTM_DRAW => {
            const draw: *dtc.DtDraw = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const gb = base.graphics_base;
            const saved = gadgets.support.Saved.of(gb, draw.rast_port);
            defer saved.restore(gb, draw.rast_port);
            paint(base, own, draw.rast_port, .{
                .left = draw.left,
                .top = draw.top,
                .width = draw.width,
                .height = draw.height,
            }, draw.top_horiz, draw.top_vert, 0xFF000000);
            return 1;
        },
        dtc.DTM_WRITE => return save.write(base, cl, o.?, @ptrCast(@alignCast(msg))),
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
