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
const IntuitionBase = @import("../../interface/intuition.zig").IntuitionBase;
const GraphicsBase = @import("../../interface/graphics.zig").GraphicsBase;
const Object = classusr.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// Drawn again, if it is in a window: a change of state that shows.
pub fn redraw(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const rp = ib.ObtainGIRPort(gi) orelse return;
    defer ib.ReleaseGIRPort(rp);
    var msg = gc.GpRender{ .gadget_info = gi, .rast_port = rp, .redraw = gc.GREDRAW_UPDATE };
    _ = ib.SendMessage(o, @ptrCast(&msg));
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

pub fn setPen(gb: *GraphicsBase, rp: *graphics.RastPort, pen: Pen) void {
    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{} };
    gb.SetRPAttrs(rp, &tags);
}

/// The pen and drawing mode a RastPort had before a gadget drew in it.
pub const Saved = struct {
    pen: u32 = 0,
    mode: u32 = 0,

    pub fn of(gb: *GraphicsBase, rp: *graphics.RastPort) Saved {
        var saved: Saved = .{};
        const ask = [_]TagItem{
            .{ .tag = graphics.RPTAG_APen, .data = @intFromPtr(&saved.pen) },
            .{ .tag = graphics.RPTAG_DrMd, .data = @intFromPtr(&saved.mode) },
            .{},
        };
        gb.GetRPAttrs(rp, &ask);
        return saved;
    }

    pub fn restore(saved: Saved, gb: *GraphicsBase, rp: *graphics.RastPort) void {
        const put = [_]TagItem{
            .{ .tag = graphics.RPTAG_APen, .data = saved.pen },
            .{ .tag = graphics.RPTAG_DrMd, .data = saved.mode },
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
        const run = intuition.IntuiText{ .font = font, .text = text };
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
pub fn drawFrame(ib: *IntuitionBase, frame: *Object, rp: *graphics.RastPort, box: gc.Box, state: u32, draw_info: ?*intuition.DrawInfo) void {
    var draw = intuition.imageclass.ImpDraw{
        .method_id = intuition.imageclass.IM_DRAWFRAME,
        .rast_port = rp,
        .offset = .{ .x = box.left, .y = box.top },
        .state = state,
        .draw_info = draw_info,
        .dimensions = .{ .width = box.width, .height = box.height },
    };
    _ = ib.SendMessage(frame, @ptrCast(&draw));
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
