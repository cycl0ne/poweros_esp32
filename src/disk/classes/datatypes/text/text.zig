// SPDX-License-Identifier: MIT
//! text.datatype: what every piece of text is, whatever file it came out
//! of.
//!
//! A datatypesclass subclass, and a superclass only: nothing recognises
//! a file as bare text. A format's class - ascii, markdown - reads its
//! file, builds the text and the runs it is made of, and hands both over
//! with `TDTM_SETTEXT`. From then on the text is this class's: it breaks
//! it into lines for the room it is given, draws them, scrolls them,
//! lets a stretch be marked with the pointer and puts what is marked on
//! the clipboard.
//!
//! **Text is runs, not characters.** A run is a stretch drawn one way: a
//! font, a style, a pen, and where it leads when it is pressed. Plain
//! text is one run a line; a marked-up document is several. Everything
//! that differs between formats is in the runs, so a new format is a
//! reader and nothing else.
//!
//! **A line is measured before there is anything to draw into.** The
//! object keeps a RastPort of no display for the purpose, because laying
//! out happens on the layout process, which may not hold a window's
//! layer while it works.
//!
//! The scroll units are pixels both ways: a heading's line is taller
//! than a line of prose, and a unit that is sometimes eight rows and
//! sometimes sixteen is no unit at all.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const iffparse = sdk.iffparse;
const datatypes = sdk.datatypes;
const subclass = datatypes.subclass;
const dtc = datatypes.datatypesclass;
const tdc = datatypes.textclass;
const _text = @import("_text.zig");
const layout = @import("layout.zig");
const render = @import("render.zig");
const mark = @import("mark.zig");
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;
const Class = classes.Class;
const Object = classes.Object;
const Base = gadgets.Base;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
///
/// datatypes.library is opened and held because datatypesclass, this
/// class's superclass, is made when that library is first opened;
/// iffparse.library because `DTM_COPY` writes an IFF form.
pub const Library = gadgets.ClassLibrary(.{
    .name = tdc.TEXTDTCLASS,
    .version = 1,
    .date = "29.09.2026",
    .super = dtc.DATATYPESCLASS,
    .opens = &.{ datatypes.DATATYPESNAME, iffparse.IFFPARSENAME },
    .Instance = _text.Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

pub const Data = _text.Data;

/// How far in from the box's edge the text is drawn.
const margin = 2;

/// The attributes among `tags` that are this class's. Whether the text
/// has to be laid out again.
fn setAttrs(base: *Base, own: *Data, tags: ?[*]const TagItem) bool {
    const ub = base.utility_base;
    var again = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        const value: i32 = @truncate(@as(isize, @bitCast(item.data)));
        switch (item.tag) {
            tdc.TDTA_WordWrap => {
                own.wrap = @intFromBool(item.data != 0);
                again = true;
            },
            tdc.TDTA_IndentWidth => {
                own.indent_width = @max(value, 0);
                again = true;
            },
            tdc.TDTA_MarkStart => own.mark_start = @min(@as(u32, @truncate(item.data)), own.buffer_len),
            tdc.TDTA_MarkEnd => own.mark_end = @min(@as(u32, @truncate(item.data)), own.buffer_len),
            else => {},
        }
    }
    return again;
}

fn getAttr(own: *Data, attr: utility.Tag, storage: *usize) bool {
    storage.* = switch (attr) {
        tdc.TDTA_Buffer => @intFromPtr(own.buffer),
        tdc.TDTA_BufferLen => own.buffer_len,
        tdc.TDTA_Pieces => @intFromPtr(own.pieces),
        tdc.TDTA_NumPieces => own.piece_count,
        tdc.TDTA_NumLines => own.line_count,
        tdc.TDTA_WordWrap => own.wrap,
        tdc.TDTA_IndentWidth => @bitCast(@as(isize, own.indent_width)),
        tdc.TDTA_MarkStart => own.mark_start,
        tdc.TDTA_MarkEnd => own.mark_end,
        tdc.TDTA_Link => @intFromPtr(&own.link),
        else => return false,
    };
    return true;
}

/// The text and its runs taken over from a format's class.
fn takeText(base: *Base, cl: *Class, o: *Object, msg: *tdc.TdtSetText) usize {
    const own = classes.instData(Data, cl, o);
    _text.freeText(base, own);
    own.buffer = msg.buffer;
    own.buffer_len = msg.buffer_len;
    own.pieces = msg.pieces;
    own.piece_count = msg.piece_count;
    own.mark_start = 0;
    own.mark_end = 0;
    if (msg.text_attr) |attr| {
        _text.closeFonts(base, own);
        _text.openFonts(base, own, attr);
    }
    // Laid out once at its full length, so that the object knows what
    // size it would like to be before it is given a box.
    _ = layout.layOut(base, own, 0);
    tellSize(base, cl, o, 0, 0);
    return 1;
}

/// How big a window of text looks right: as much of it as there is, and
/// no more than a page.
///
/// A document is any length, and a window opened at the length of one
/// would fill the screen and then be clamped to it. What it is measured
/// in is the font it is drawn in, so the page is the same page whatever
/// size that font is.
const page_columns = 72;
const page_rows = 24;

fn nominalSize(base: *Base, own: *const Data) struct { width: i32, height: i32 } {
    const rp = own.measure orelse return .{ .width = own.widest, .height = layout.totalHeight(own) };
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(_text.fontOf(own, tdc.TDFONT_NORMAL)) },
        .{},
    };
    base.graphics_base.SetRPAttrs(rp, &tags);
    var width: u32 = 8;
    var height: u32 = 8;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontWidth, .data = @intFromPtr(&width) },
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{},
    };
    base.graphics_base.GetRPAttrs(rp, &ask);
    return .{
        .width = @min(own.widest, page_columns * @as(i32, @intCast(@max(width, 1)))),
        .height = @min(layout.totalHeight(own), page_rows * @as(i32, @intCast(@max(height, 1)))),
    };
}

/// The superclass told how much there is and how much of it shows.
fn tellSize(base: *Base, cl: *Class, o: *Object, seen_width: i32, seen_height: i32) void {
    const own = classes.instData(Data, cl, o);
    const height = layout.totalHeight(own);
    const page = nominalSize(base, own);
    const tags = [_]TagItem{
        .{ .tag = dtc.DTA_NominalHoriz, .data = @bitCast(@as(isize, page.width + 2 * margin)) },
        .{ .tag = dtc.DTA_NominalVert, .data = @bitCast(@as(isize, page.height + 2 * margin)) },
        .{ .tag = dtc.DTA_TotalHoriz, .data = @bitCast(@as(isize, own.widest)) },
        .{ .tag = dtc.DTA_TotalVert, .data = @bitCast(@as(isize, height)) },
        .{ .tag = dtc.DTA_HorizUnit, .data = 1 },
        .{ .tag = dtc.DTA_VertUnit, .data = 1 },
        .{ .tag = if (seen_width > 0) dtc.DTA_VisibleHoriz else utility.TAG_IGNORE, .data = @bitCast(@as(isize, seen_width)) },
        .{ .tag = if (seen_height > 0) dtc.DTA_VisibleVert else utility.TAG_IGNORE, .data = @bitCast(@as(isize, seen_height)) },
        .{},
    };
    subclass.superTell(base.intuition_base, cl, o, &tags);
}

/// The box the text is drawn in: the gadget's, inside the margin.
fn textBox(o: *Object, info: *classusr.GadgetInfo) gc.Box {
    const box = gc.boxFor(gc.gadget(o), info);
    return .{
        .left = box.left + margin,
        .top = box.top + margin,
        .width = @max(box.width - 2 * margin, 0),
        .height = @max(box.height - 2 * margin, 0),
    };
}

/// Laid out for the room the object now has, and the superclass told
/// what came of it.
fn layOutFor(base: *Base, cl: *Class, o: *Object, info: *classusr.GadgetInfo) void {
    const own = classes.instData(Data, cl, o);
    const box = textBox(o, info);
    if (own.wrap != 0 and box.width != own.laid_for) {
        _ = layout.layOut(base, own, box.width);
    }
    const height = layout.totalHeight(own);
    const top_vert = @max(0, @min(askSuper(base, cl, o, dtc.DTA_TopVert), height - box.height));
    const top_horiz = @max(0, @min(askSuper(base, cl, o, dtc.DTA_TopHoriz), own.widest - box.width));
    tellSize(base, cl, o, @min(box.width, own.widest), @min(box.height, height));
    const tags = [_]TagItem{
        .{ .tag = dtc.DTA_TopVert, .data = @bitCast(@as(isize, top_vert)) },
        .{ .tag = dtc.DTA_TopHoriz, .data = @bitCast(@as(isize, top_horiz)) },
        .{},
    };
    subclass.superTell(base.intuition_base, cl, o, &tags);
}

fn askSuper(base: *Base, cl: *Class, o: *Object, attr: utility.Tag) i32 {
    return @truncate(@as(isize, @bitCast(subclass.superAsk(base.intuition_base, cl, o, attr))));
}

fn draw(base: *Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const own = classes.instData(Data, cl, o);
    const gb = base.graphics_base;
    const saved = support.Saved.of(gb, r.rast_port);
    defer saved.restore(gb, r.rast_port);
    const whole = gc.boxFor(gc.gadget(o), info);
    support.fill(gb, r.rast_port, whole, info.draw_info.pens[intuition.screens.BACKGROUNDPEN]);
    render.paint(base, own, info, r.rast_port, textBox(o, info), askSuper(base, cl, o, dtc.DTA_TopHoriz), askSuper(base, cl, o, dtc.DTA_TopVert));
}

/// Where a pointer event fell in the text. The event says where it is
/// in the gadget's box, so what is left is the margin and how far the
/// view has been scrolled.
fn placeIn(base: *Base, cl: *Class, o: *Object, where: graphics.Point) struct { x: i32, y: i32 } {
    return .{
        .x = where.x - margin + askSuper(base, cl, o, dtc.DTA_TopHoriz),
        .y = where.y - margin + askSuper(base, cl, o, dtc.DTA_TopVert),
    };
}

fn handleInput(base: *Base, cl: *Class, o: *Object, input: *gc.GpInput) u32 {
    const info = input.gadget_info orelse return gc.GMR_NOREUSE;
    const own = classes.instData(Data, cl, o);
    const event = input.event orelse return gc.GMR_MEACTIVE;
    const at = placeIn(base, cl, o, input.mouse);

    if (event.class == ie.IECLASS_RAWMOUSE and event.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
        mark.release(own, at.x, at.y);
        support.redraw(base.intuition_base, o, info);
        input.termination.* = 0;
        return gc.GMR_NOREUSE | gc.GMR_VERIFY;
    }
    if (mark.drag(base, own, at.x, at.y)) support.redraw(base.intuition_base, o, info);
    return gc.GMR_MEACTIVE;
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
            own.measure = base.graphics_base.CreateRastPortTagList(null) orelse {
                ib.DisposeObject(obj);
                return 0;
            };
            const attr: ?*const graphics.TextAttr = @ptrFromInt(subclass.superAsk(ib, cl, obj, dtc.DTA_TextAttr));
            _text.openFonts(base, own, attr);
            _ = setAttrs(base, own, new.attr_list);
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            _text.freeText(base, own);
            _text.closeFonts(base, own);
            base.graphics_base.FreeRastPort(own.measure);
            own.measure = null;
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, own, set.attr_list)) {
                own.laid_for = -1;
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
        tdc.TDTM_SETTEXT => return takeText(base, cl, o.?, @ptrCast(@alignCast(msg))),
        gc.GM_RENDER => {
            draw(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        gc.GM_HITTEST => return gc.GMR_GADGETHIT,
        gc.GM_GOACTIVE => {
            const input: *gc.GpInput = @ptrCast(@alignCast(msg));
            const info = input.gadget_info orelse return gc.GMR_NOREUSE;
            const own = classes.instData(Data, cl, o.?);
            const at = placeIn(base, cl, o.?, input.mouse);
            mark.press(base, own, at.x, at.y);
            support.redraw(ib, o.?, info);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => return handleInput(base, cl, o.?, @ptrCast(@alignCast(msg))),
        dtc.DTM_PROCLAYOUT, dtc.DTM_ASYNCLAYOUT => {
            const lay: *gc.GpLayout = @ptrCast(@alignCast(msg));
            const info = lay.gadget_info orelse return 0;
            layOutFor(base, cl, o.?, info);
            return 1;
        },
        dtc.DTM_FRAMEBOX => {
            const frame: *dtc.DtFrameBox = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            frame.frame_info.* = frame.contents_info.*;
            frame.frame_info.width = @intCast(@max(own.widest, 0));
            frame.frame_info.height = @intCast(@max(layout.totalHeight(own), 0));
            frame.frame_info.flags = dtc.FIF_SCROLLABLE;
            return 1;
        },
        dtc.DTM_SELECT => {
            const pick: *dtc.DtSelect = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            own.mark_start = @min(@as(u32, @intCast(@max(pick.select.min_x, 0))), own.buffer_len);
            own.mark_end = @min(@as(u32, @intCast(@max(pick.select.max_x, 0))), own.buffer_len);
            return 1;
        },
        dtc.DTM_CLEARSELECTED => {
            const own = classes.instData(Data, cl, o.?);
            own.mark_start = 0;
            own.mark_end = 0;
            return 1;
        },
        dtc.DTM_COPY => {
            const own = classes.instData(Data, cl, o.?);
            const ip: *IFFParseBase = @ptrCast(base.opened[1] orelse return 0);
            return @intFromBool(mark.copy(own, ip));
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
