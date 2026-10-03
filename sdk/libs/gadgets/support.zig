// SPDX-License-Identifier: MIT
//! What every gadget class on the disk does the same way: draw itself
//! again when its state changes, lay the ghost over itself when it is
//! disabled, tell its target what changed, and measure text in the font
//! it will be drawn in.

const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
const intuition = @import("../intuition/intuition.zig");
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const IntuitionBase = @import("../../interface/intuition.zig").IntuitionBase;
const GraphicsBase = @import("../../interface/graphics.zig").GraphicsBase;
const Object = classusr.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// The pens a class draws a gadget in: the screen's, with the six that
/// stand for a look taken from a part of the style - the gadget's own
/// style asked first (`StylePens`). With `fill_part`, the fill pen and the
/// fill text pen come from that part instead, at rest: a list's selected
/// line (`PART_SELECTION`), a bar's level (`PART_INDICATOR`). Under the
/// system's default style every pen is the screen's own, so a class that
/// draws with these draws exactly as it did.
pub fn pensFor(ib: *IntuitionBase, dri: *const sc.DrawInfo, own: ?*const intuition.Style, part: u32, fill_part: ?u32) [sc.NUMDRIPENS]Pen {
    const style = intuition.style;
    var pens: [sc.NUMDRIPENS]Pen = undefined;
    ib.StylePens(dri, own, part, &pens);
    if (fill_part) |fp| {
        pens[sc.FILLPEN] = @truncate(ib.GetStyleAttr(dri, own, fp, style.STATE_NORMAL, style.STYLE_Background));
        pens[sc.FILLTEXTPEN] = @truncate(ib.GetStyleAttr(dri, own, fp, style.STATE_NORMAL, style.STYLE_TextPen));
    }
    return pens;
}

/// The ground a gadget is drawn on: its part's background at rest, the
/// gadget's own style asked first. Under the system's default style it is
/// the screen's background pen.
pub fn background(ib: *IntuitionBase, dri: *const sc.DrawInfo, own: ?*const intuition.Style, part: u32) Pen {
    const style = intuition.style;
    return @truncate(ib.GetStyleAttr(dri, own, part, style.STATE_NORMAL, style.STYLE_Background));
}

/// What intuition marks on a gadget - the pointer over it, the input in
/// it (`GFLG_HOVERED`, `GFLG_FOCUSED`) - passed on to a gadget of its own
/// that draws a part of it, before that one is asked to draw: intuition
/// marks the gadget it knows, and the one inside is the class's.
pub fn passMarks(o: *Object, inner: *Object) void {
    const marks = gc.GFLG_HOVERED | gc.GFLG_FOCUSED;
    const held = gc.gadget(inner);
    held.flags = (held.flags & ~marks) | (gc.gadget(o).flags & marks);
}

/// A gadget's own style (`GA_Style`) among `tags` handed on to the gadget
/// inside it, which keeps a copy of its own: a class made of an inner
/// gadget calls this as it is made and as it is set, so the inner one is
/// drawn in its style too.
pub fn passStyle(ib: *IntuitionBase, ub: anytype, tags: ?[*]const TagItem, inner: *Object) void {
    const item = ub.FindTagItem(gc.GA_Style, tags) orelse return;
    const pass = [_]TagItem{ .{ .tag = gc.GA_Style, .data = item.data }, .{} };
    _ = ib.SetAttrsTagList(inner, &pass);
}

/// An image drawn at (`left`, `top`) in a state, in a gadget's own style
/// over its screen's: `DrawImageState` with the style an image drawn from
/// a style is to use (`ImpDraw.style`).
pub fn drawImage(ib: *IntuitionBase, image: *Object, rp: *graphics.RastPort, left: i32, top: i32, state: u32, draw_info: ?*intuition.DrawInfo, own_style: ?*const intuition.Style) void {
    var draw = intuition.imageclass.ImpDraw{
        .method_id = intuition.imageclass.IM_DRAW,
        .rast_port = rp,
        .offset = .{ .x = left, .y = top },
        .state = state,
        .draw_info = draw_info,
        .style = own_style,
    };
    _ = ib.SendMessage(image, @ptrCast(&draw));
}

/// Drawn again, if it is in a window: a change of state that shows.
/// Intuition draws it, soon and on its own task, aside and then onto the
/// window in one copy, so the gadget is never seen half drawn; changes that
/// come before it gets to it are drawn as one.
pub fn redraw(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo) void {
    if (gi == null) return;
    ib.QueueGadgetRefresh(o);
}

/// Tell the gadget's target what changed: `tags`, which the gadget's
/// `GA_ID` should be among. `flags` is `OPUF_INTERIM` while it is still
/// changing.
pub fn notify(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo, tags: [*]const TagItem, flags: u32) void {
    var msg = classusr.OpUpdate{ .method_id = classusr.OM_NOTIFY, .attr_list = tags, .gadget_info = gi, .flags = flags };
    _ = ib.SendMessage(o, @ptrCast(&msg));
}

const ghost_tile = [_]u8{ 0x44, 0x44, 0x11, 0x11 };

/// A disabled gadget's look: every other pixel of `box` in `pen` - the
/// window's block pen - and the pixels between left as they were.
pub fn ghost(gb: *GraphicsBase, rp: *graphics.RastPort, box: gc.Box, pen: Pen) void {
    if (box.width <= 0 or box.height <= 0) return;
    setPen(gb, rp, pen);
    gb.BltPattern(rp, &ghost_tile, 2, 16, 2, &.{
        .min_x = box.left,
        .min_y = box.top,
        .max_x = box.left + box.width,
        .max_y = box.top + box.height,
    });
}

/// A filled rectangle.
pub fn fill(gb: *GraphicsBase, rp: *graphics.RastPort, box: gc.Box, pen: Pen) void {
    if (box.width <= 0 or box.height <= 0) return;
    setPen(gb, rp, pen);
    gb.RectFill(rp, &.{
        .min_x = box.left,
        .min_y = box.top,
        .max_x = box.left + box.width,
        .max_y = box.top + box.height,
    });
}

/// `weight` sixteenths of `a` and the rest of `b`, channel by channel.
///
/// A pen here is a colour and not an index into anything, so a class can
/// shade one - a tab that is not the one in front, a track under a knob
/// - without asking the screen for a pen it has not got.
pub fn mixPens(a: Pen, b: Pen, weight: u32) Pen {
    const of = @min(weight, 16);
    var mixed: Pen = 0;
    var shift: u5 = 0;
    while (true) : (shift += 8) {
        const from: u32 = (a >> shift) & 0xFF;
        const to: u32 = (b >> shift) & 0xFF;
        mixed |= ((from * of + to * (16 - of)) / 16) << shift;
        if (shift == 24) break;
    }
    return mixed;
}

pub fn setPen(gb: *GraphicsBase, rp: *graphics.RastPort, pen: Pen) void {
    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{} };
    gb.SetRPAttrs(rp, &tags);
}

/// The pen and drawing mode a RastPort had before a gadget drew in it.
pub const Saved = struct {
    pen: u32 = 0,
    back_pen: u32 = 0,
    mode: u32 = 0,
    /// The font and the styles drawn over it are in here because a
    /// gadget - or a hook a gadget calls to draw a line its own way - may
    /// set them, and a gadget is only passing through a RastPort that is
    /// the window's. Without them the font of the last thing drawn stays
    /// on, and everything drawn after it in that window comes out in a
    /// font nobody asked for.
    font: usize = 0,
    style: u32 = 0,

    pub fn of(gb: *GraphicsBase, rp: *graphics.RastPort) Saved {
        var saved: Saved = .{};
        const ask = [_]TagItem{
            .{ .tag = graphics.RPTAG_APen, .data = @intFromPtr(&saved.pen) },
            .{ .tag = graphics.RPTAG_BPen, .data = @intFromPtr(&saved.back_pen) },
            .{ .tag = graphics.RPTAG_DrMd, .data = @intFromPtr(&saved.mode) },
            .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&saved.font) },
            .{ .tag = graphics.RPTAG_TextStyle, .data = @intFromPtr(&saved.style) },
            .{},
        };
        gb.GetRPAttrs(rp, &ask);
        return saved;
    }

    pub fn restore(saved: Saved, gb: *GraphicsBase, rp: *graphics.RastPort) void {
        const put = [_]TagItem{
            .{ .tag = graphics.RPTAG_APen, .data = saved.pen },
            .{ .tag = graphics.RPTAG_BPen, .data = saved.back_pen },
            .{ .tag = graphics.RPTAG_DrMd, .data = saved.mode },
            .{ .tag = graphics.RPTAG_Font, .data = saved.font },
            .{ .tag = graphics.RPTAG_TextStyle, .data = saved.style },
            .{},
        };
        gb.SetRPAttrs(rp, &put);
    }
};

pub fn textLen(text: [*:0]const u8) u32 {
    var n: u32 = 0;
    while (text[n] != 0) n += 1;
    return n;
}

/// `text` with its top at `top`, in `pen`, over what is there, in the
/// RastPort's font.
pub fn drawText(gb: *GraphicsBase, rp: *graphics.RastPort, left: i32, top: i32, text: [*:0]const u8, pen: Pen) void {
    var baseline: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = pen },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &tags);
    gb.Move(rp, left, top + @as(i32, @intCast(baseline)));
    gb.Text(rp, text, textLen(text));
}

/// The font a gadget is measured in: its window's, when it is asked in
/// one; else the one its `GA_DrawInfo` names; else the default public
/// screen's, which is where a window made without saying opens. `done`
/// lets that screen go again.
pub const Measure = struct {
    font: ?*graphics.TextFont = null,
    screen: ?*intuition.Screen = null,
    draw_info: ?*intuition.DrawInfo = null,

    pub fn of(ib: *IntuitionBase, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) Measure {
        if (gi) |info| if (info.draw_info.font) |font| return .{ .font = font };
        if (g.draw_info) |dri| if (dri.font) |font| return .{ .font = font };
        const screen = ib.LockPubScreen(null) orelse return .{};
        const dri = ib.GetScreenDrawInfo(screen);
        return .{ .font = dri.font, .screen = screen, .draw_info = dri };
    }

    pub fn done(m: Measure, ib: *IntuitionBase) void {
        const screen = m.screen orelse return;
        ib.FreeScreenDrawInfo(screen, m.draw_info.?);
        ib.UnlockPubScreen(null, screen);
    }

    /// How wide `text` is in the font; 0 without one.
    pub fn width(m: Measure, ib: *IntuitionBase, text: [*:0]const u8) i32 {
        const font = m.font orelse return 0;
        const run = intuition.text.plainRun(text, font);
        return ib.IntuiTextLength(&run);
    }

    /// How tall a line of the font is; 8 without one.
    pub fn lineHeight(m: Measure, gb: *GraphicsBase) i32 {
        const font = m.font orelse return 8;
        var extent = graphics.FontExtent{};
        gb.FontExtent(font, &extent);
        return extent.height;
    }
};

// --- a gadget inside a gadget ------------------------------------------------
//
// A class that shows a gadget of another class inside something of its own
// - a frame, a line of text beside it - makes that gadget itself and keeps
// it: the inner gadget is in no window's list, and intuition drives only
// the outer one. The outer one places the inner one before each message
// it hands on, and hands on the input with the pointer moved into the
// inner one's box. The inner one's `ICA_TARGET` is the outer one, which
// hears what changed as an `OM_UPDATE` and tells its own target in its
// own name.

/// Put the inner gadget at `box`, in the window's coordinates. Nothing is
/// drawn.
pub fn place(ib: *IntuitionBase, inner: *Object, box: gc.Box) void {
    const g = gc.gadget(inner);
    if (g.left == box.left and g.top == box.top and g.width == box.width and g.height == box.height) return;
    const tags = [_]TagItem{
        .{ .tag = gc.GA_Left, .data = @bitCast(@as(isize, box.left)) },
        .{ .tag = gc.GA_Top, .data = @bitCast(@as(isize, box.top)) },
        .{ .tag = gc.GA_Width, .data = @bitCast(@as(isize, box.width)) },
        .{ .tag = gc.GA_Height, .data = @bitCast(@as(isize, box.height)) },
        .{},
    };
    _ = ib.SetAttrsTagList(inner, &tags);
}

/// `GM_GOACTIVE` or `GM_HANDLEINPUT` handed to the inner gadget, which sits
/// `at` in the outer one's box: the pointer is moved into its box, and the
/// termination it sets is the outer one's.
pub fn handOnInput(ib: *IntuitionBase, inner: *Object, in: *const gc.GpInput, at: gc.Box) usize {
    var moved = in.*;
    moved.mouse = .{ .x = in.mouse.x - at.left, .y = in.mouse.y - at.top };
    return ib.SendMessage(inner, @ptrCast(&moved));
}

/// `GM_HITTEST` handed to the inner gadget, as `handOnInput`.
pub fn handOnHitTest(ib: *IntuitionBase, inner: *Object, ht: *const gc.GpHitTest, at: gc.Box) usize {
    var moved = ht.*;
    moved.mouse = .{ .x = ht.mouse.x - at.left, .y = ht.mouse.y - at.top };
    return ib.SendMessage(inner, @ptrCast(&moved));
}

/// Whether a point, relative to a box of `width` by `height`, is in it.
pub fn inside(x: i32, y: i32, width: i32, height: i32) bool {
    return x >= 0 and y >= 0 and x < width and y < height;
}

/// What a frame needs round a box: how far in from the frame's edges the
/// box sits on each side, as a frame image's `IM_FRAMEBOX` answers it.
pub fn frameInset(ib: *IntuitionBase, frame: *Object, draw_info: ?*intuition.DrawInfo) gc.Box {
    var contents = intuition.imageclass.Box{ .width = 100, .height = 100 };
    var box = intuition.imageclass.Box{};
    var msg = intuition.imageclass.ImpFrameBox{ .contents = &contents, .frame = &box, .draw_info = draw_info };
    if (ib.SendMessage(frame, @ptrCast(&msg)) == 0) return .{ .left = 2, .top = 2, .width = 4, .height = 4 };
    // `width` and `height` here are what the frame adds in all.
    return .{ .left = -box.left, .top = -box.top, .width = box.width - 100, .height = box.height - 100 };
}

/// A frame image drawn round `box`, in a state.
pub fn drawFrame(ib: *IntuitionBase, frame: *Object, rp: *graphics.RastPort, box: gc.Box, state: u32, draw_info: ?*intuition.DrawInfo, own_style: ?*const intuition.Style) void {
    var draw = intuition.imageclass.ImpDraw{
        .method_id = intuition.imageclass.IM_DRAWFRAME,
        .rast_port = rp,
        .offset = .{ .x = box.left, .y = box.top },
        .state = state,
        .draw_info = draw_info,
        .dimensions = .{ .width = box.width, .height = box.height },
        .style = own_style,
    };
    _ = ib.SendMessage(frame, @ptrCast(&draw));
}

// --- arrows -----------------------------------------------------------------
//
// The stepping arrows of a scroller and of a number field are the same
// button: a frame with a triangle in it, pressed while it is held. They
// are here so that both draw the one arrow.

/// The triangle of an arrow button: where it starts across the way the
/// arrow points and along it, how wide its base and its tip are, and how
/// many rows it takes from the tip to the base.
pub const Triangle = struct {
    across_at: i32,
    along_at: i32,
    tip: i32,
    base: i32,
    rows: i32,

    /// The width of row `row`, counted from the tip.
    pub fn widthAt(t: Triangle, row: i32) i32 {
        return t.tip + 2 * row;
    }

    /// Where row `row` starts across the way the arrow points.
    pub fn startAt(t: Triangle, row: i32) i32 {
        return t.across_at + @divTrunc(t.base - t.widthAt(row), 2);
    }
};

/// The triangle for a button `at` big, pointing along its height when
/// `vertical`; null when the button is too small for one.
///
/// Every row is the same width either side of the middle, and the pixels
/// left over at the two edges of the button are the same number, which is
/// what makes the arrow look placed in the button rather than pushed to
/// one side. Keeping it so needs the triangle and the room it sits in to
/// have the same parity, since a triangle centred in a room of the other
/// parity has one pixel more at one edge than at the other. So the tip is
/// one pixel wide in an odd room and two in an even one and the rows grow
/// by two, which makes every row the room's parity; and a row more or
/// fewer does the same along the way the arrow points, without touching
/// the width.
pub fn triangleIn(at: gc.Box, vertical: bool) ?Triangle {
    const across_room = if (vertical) at.width else at.height;
    const along_room = if (vertical) at.height else at.width;
    if (across_room < 5 or along_room < 4) return null;
    const tip: i32 = 2 - @mod(across_room, 2);
    // About half the button's smaller side.
    const wanted = @max(@divTrunc(@min(at.width, at.height), 2), tip + 2);
    var steps = @max(@divTrunc(wanted - tip + 1, 2), 1);
    if (@mod(along_room - steps - 1, 2) != 0) steps += 1;
    // Two at a time, so that what is taken off keeps the parity.
    while (steps > 2 and (tip + 2 * steps > across_room - 2 or steps + 1 > along_room - 2)) steps -= 2;
    if (tip + 2 * steps > across_room - 2 or steps + 1 > along_room - 2) return null;
    const base = tip + 2 * steps;
    const rows = steps + 1;
    return .{
        .across_at = (if (vertical) at.left else at.top) + @divTrunc(across_room - base, 2),
        .along_at = (if (vertical) at.top else at.left) + @divTrunc(along_room - rows, 2),
        .tip = tip,
        .base = base,
        .rows = rows,
    };
}

/// One arrow button: where it is, which way it points, and whether it is
/// drawn pressed.
pub const Arrow = struct {
    /// The button's box, in the coordinates the RastPort is drawn in.
    at: gc.Box,
    /// It points along its height rather than across it.
    vertical: bool = false,
    /// It points down or right rather than up or left.
    forward: bool = false,
    pressed: bool = false,
};

/// An arrow drawn: `frame`, a frameiclass button image, round it, and a
/// triangle pointing the way it steps - drawn a row at a time, a column
/// at a time for the arrows that point across, rather than as a filled
/// polygon, whose edges belong to one side and not the other. Without a
/// frame it is the triangle alone, which is what a mark on a button is.
pub fn drawArrow(ib: *IntuitionBase, gb: *GraphicsBase, frame: ?*Object, rp: *graphics.RastPort, draw_info: ?*intuition.DrawInfo, arrow: Arrow) void {
    if (frame) |image| drawFrame(ib, image, rp, arrow.at, if (arrow.pressed) ic.IDS_SELECTED else ic.IDS_NORMAL, draw_info, null);
    const dri = draw_info orelse return;
    setPen(gb, rp, if (arrow.pressed) dri.pens[sc.FILLTEXTPEN] else dri.pens[sc.TEXTPEN]);
    const triangle = triangleIn(arrow.at, arrow.vertical) orelse return;
    var row: i32 = 0;
    while (row < triangle.rows) : (row += 1) {
        // An arrow that points back has its tip first, one that points
        // forward has it last.
        const grown = if (arrow.forward) triangle.rows - 1 - row else row;
        const width = triangle.widthAt(grown);
        const start = triangle.startAt(grown);
        if (arrow.vertical) gb.DrawHLine(rp, start, triangle.along_at + row, width) else gb.DrawVLine(rp, triangle.along_at + row, start, width);
    }
}

// --- numbers as text ------------------------------------------------------------

const ExecBase = @import("../../interface/exec.zig").ExecBase;

/// Where RawDoFmt's characters go: a buffer, cut short when it is full.
const Collect = struct {
    into: []u8,
    len: usize = 0,

    fn put(c: u8, data: ?*anyopaque) callconv(.c) void {
        const collect: *Collect = @ptrCast(@alignCast(data.?));
        if (c == 0 or collect.len + 1 >= collect.into.len) return;
        collect.into[collect.len] = c;
        collect.len += 1;
    }
};

/// A RawDoFmt `format` written with the values in `stream` - an extern
/// struct laid out as the format reads them - into `into`,
/// NUL-terminated and cut to fit.
pub fn formatInto(sys: *ExecBase, format: [*:0]const u8, stream: *const anyopaque, into: []u8) [*:0]const u8 {
    var collect = Collect{ .into = into };
    _ = sys.RawDoFmt(format, stream, &Collect.put, &collect);
    into[collect.len] = 0;
    return @ptrCast(into.ptr);
}

/// `value` written through a RawDoFmt `format` that takes one number -
/// `%ld` or `%d` - into `into`, NUL-terminated and cut to fit. The value
/// is in the data stream as 64 bits, whose low 32 are first: a `%d` reads
/// those, a `%ld` all of them.
pub fn formatNumber(sys: *ExecBase, format: [*:0]const u8, value: i64, into: []u8) [*:0]const u8 {
    var collect = Collect{ .into = into };
    const stream = value;
    _ = sys.RawDoFmt(format, &stream, &Collect.put, &collect);
    into[collect.len] = 0;
    return @ptrCast(into.ptr);
}
